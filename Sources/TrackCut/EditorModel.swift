import AppKit
import Combine
import SwiftUI
import TrackCutCore
import UniformTypeIdentifiers

@MainActor
final class EditorModel: ObservableObject {
    static let minVisibleDuration = 0.5
    static let minTrackLength = 0.1

    /// The audio files being edited, as one timeline
    @Published private(set) var source: AudioSource?
    /// Files waiting for the user to confirm their order before they are joined (see FilesSheet)
    @Published var filesToJoin: [URL]?
    /// The project file being edited, nil until the work is saved as a project or one is opened
    @Published private(set) var projectURL: URL?
    @Published private(set) var peaks: WaveformPeaks?
    @Published private(set) var loadingProgress: Double?
    @Published var tracks: [Track] = [] {
        didSet { exportNumbers = Self.exportNumbers(of: tracks) }
    }
    /// The number each track is exported under (see exportNumber), kept with the tracks so that rows and
    /// labels do not count again
    private var exportNumbers: [Int?] = []
    @Published var selectedTrackID: Track.ID?
    /// Tags shared by the whole album (only album / artist / albumArtist / date / genre are used)
    @Published var albumTags = AudioTags()
    @Published private(set) var visibleStart: Double = 0
    @Published private(set) var visibleDuration: Double = 1
    @Published var errorMessage: String?

    static let shared = EditorModel()

    let player = PlayerModel()
    /// The editor window. Set by the detail waveform view.
    weak var window: NSWindow? {
        didSet {
            undoManager = window?.undoManager
            // A window opened again after it was closed shows the unsaved changes it still has
            window?.isDocumentEdited = hasUnsavedChanges
        }
    }
    /// The window's undo manager, which the Edit menu and ⌘Z use. Tests set one of their own.
    weak var undoManager: UndoManager?
    private var loadTask: Task<Void, Never>?
    /// Identifies the latest open(). Results from earlier loads are dropped by comparing against it;
    /// the URL is not enough because the same file can be opened again while it is still loading.
    private var loadID = UUID()
    /// Waveform peaks and tags of the files opened since the work was opened, by path. Rearranging the
    /// files (and undoing that) joins these again instead of analyzing the files again.
    private var filePeaks: [String: WaveformPeaks] = [:]
    private var fileTags: [String: AudioTags] = [:]
    /// Progress of analyzing files being added, nil when none are
    @Published private(set) var addingProgress: Double?
    /// The state as last saved or opened. hasUnsavedChanges compares against it.
    private var savedState: EditState?
    private var cancellables = Set<AnyCancellable>()

    var duration: Double { peaks?.duration ?? 0 }

    /// The app uses `shared`; tests make their own
    init() {
        player.onLoadError = { [weak self] error in
            self?.errorMessage = String(localized: "Could not play the file: \(error.localizedDescription)")
        }
        player.$currentTime
            .sink { [weak self] t in MainActor.assumeIsolated { self?.followPlayhead(t) } }
            .store(in: &cancellables)
        // A text field has finished editing. Delivered on the next pass so the binding has its final value.
        NotificationCenter.default.publisher(for: NSControl.textDidEndEditingNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { _ = self?.commitTextEdits() } }
            .store(in: &cancellables)
    }

    // MARK: - File

    static let projectType = UTType(filenameExtension: Project.fileExtension, conformingTo: .json) ?? .json
    static let audioTypes = AudioSource.supportedExtensions.compactMap { UTType(filenameExtension: $0) }

    /// The first source file
    var sourceURL: URL? { source?.urls.first }

    /// Name of the work: the project's, the audio file's, or the folder of joined files
    var displayName: String {
        if let projectURL { return projectURL.deletingPathExtension().lastPathComponent }
        guard let source else { return "TrackCut" }
        return source.files.count == 1 ? source.urls[0].lastPathComponent : Self.folderName(of: source.urls)
    }

    private static func folderName(of urls: [URL]) -> String {
        urls[0].deletingLastPathComponent().lastPathComponent
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.audioTypes + [Self.projectType, .folder]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose an audio file, a project, or several audio files or a folder to join")
        if panel.runModal() == .OK {
            openAfterConfirming(panel.urls)
        }
    }

    private var pendingOpenURLs: [URL] = []

    /// A file opened from Finder. Files opened together arrive one at a time, so they are collected for a
    /// moment and opened together.
    func receiveOpenedURL(_ url: URL) {
        pendingOpenURLs.append(url)
        guard pendingOpenURLs.count == 1 else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            let urls = pendingOpenURLs
            pendingOpenURLs = []
            openAfterConfirming(urls)
        }
    }

    /// Opens files the user chose, after asking what to do with unsaved changes
    func openAfterConfirming(_ urls: [URL]) {
        guard !urls.isEmpty, confirmDiscardingChanges() else { return }
        open(urls)
    }

    /// Opens an audio file, a project, or several audio files or a folder of them to be joined, replacing the
    /// current work without asking. Several files are first shown for the user to confirm their order.
    func open(_ urls: [URL]) {
        if urls.count == 1 {
            open(urls[0])
            return
        }
        let audio = Self.audioFiles(in: urls)
        switch audio.count {
        case 0: errorMessage = String(localized: "Supported formats are FLAC, M4A and WAV")
        case 1: openAudio(audio)
        default: filesToJoin = audio
        }
    }

    /// Opens an audio file, a project or a folder, replacing the current work without asking
    func open(_ url: URL) {
        if url.pathExtension.lowercased() == Project.fileExtension {
            openProject(url)
        } else if Self.isFolder(url) {
            openFolder(url)
        } else {
            openAudio([url])
        }
    }

    /// Whether `url` is a folder. Asks the file system, since a folder's URL need not end in a slash.
    static func isFolder(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func openFolder(_ url: URL) {
        let files: [URL]
        do {
            files = try AudioSource.audioFiles(in: url)
        } catch {
            errorMessage = String(localized: "Could not open the folder: \(error.localizedDescription)")
            return
        }
        switch files.count {
        case 0: errorMessage = String(localized: "“\(url.lastPathComponent)” has no FLAC, M4A or WAV files.")
        case 1: openAudio(files)
        default: filesToJoin = files
        }
    }

    /// Opens audio files as one timeline, in the given order
    func join(_ urls: [URL]) {
        openAudio(urls)
    }

    private func openAudio(_ urls: [URL], project: Project? = nil, projectURL: URL? = nil) {
        if let unsupported = urls.first(where: { !AudioSource.supportedExtensions.contains($0.pathExtension.lowercased()) }) {
            errorMessage = String(localized: "Supported formats are FLAC, M4A and WAV: \(unsupported.lastPathComponent)")
            return
        }
        let source: AudioSource
        do {
            source = try AudioSource(urls: urls)
        } catch {
            errorMessage = String(localized: "Could not open the file: \(error.localizedDescription)")
            return
        }
        player.load(source)
        // Only cancel the previous analysis once the new file has opened. Cancelling first would
        // leave the window stuck on the progress view when the new file fails to open.
        loadTask?.cancel()
        undoManager?.removeAllActions()
        textEditOrigins = [:]
        filePeaks = [:]
        fileTags = [:]
        addingProgress = nil
        let id = UUID()
        loadID = id
        self.source = source
        self.projectURL = projectURL
        savedState = nil
        peaks = nil
        tracks = []
        selectedTrackID = nil
        albumTags = project?.album ?? AudioTags()
        loadingProgress = 0

        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let analyzed = try await Self.analyze(source.files) { p in
                    Task { @MainActor in
                        if self?.loadID == id, self?.peaks == nil { self?.loadingProgress = p }
                    }
                }
                await self?.finishLoading(analyzed, project: project, loadID: id)
            } catch is CancellationError {
            } catch {
                await self?.failLoading(error: error, loadID: id)
            }
        }
    }

    /// Peaks and tags of files, analyzed one by one. `progress` covers all of them.
    nonisolated private static func analyze(_ files: [AudioSource.File], progress: @escaping (Double) -> Void)
        async throws -> [(path: String, peaks: WaveformPeaks, tags: AudioTags)] {
        let total = max(files.reduce(0) { $0 + $1.info.duration }, 0.001)
        var done = 0.0
        var result: [(path: String, peaks: WaveformPeaks, tags: AudioTags)] = []
        for file in files {
            let tags = await TagReader.read(from: file.url)
            let base = done, length = file.info.duration
            let peaks = try WaveformAnalyzer.analyze(url: file.url) { progress((base + $0 * length) / total) }
            result.append((path(of: file.url), peaks, tags))
            done += length
        }
        return result
    }

    nonisolated private static func path(of url: URL) -> String { url.standardizedFileURL.path }

    /// The source's peaks, joined from those of its files
    private func joinedPeaks(_ source: AudioSource) -> WaveformPeaks? {
        let parts = source.urls.compactMap { filePeaks[Self.path(of: $0)] }
        return parts.count == source.files.count ? .joined(parts, in: source) : nil
    }

    private func finishLoading(_ analyzed: [(path: String, peaks: WaveformPeaks, tags: AudioTags)], project: Project?,
                               loadID id: UUID) {
        guard loadID == id, let source else { return }
        for file in analyzed {
            filePeaks[file.path] = file.peaks
            fileTags[file.path] = file.tags
        }
        guard let peaks = joinedPeaks(source) else { return }
        self.peaks = peaks
        loadingProgress = nil
        // A project has tags of its own
        if let project {
            tracks = project.tracks(fitting: peaks.duration, minLength: Self.minTrackLength)
        } else {
            albumTags = Self.albumTags(from: analyzed.map(\.tags))
            tracks = initialTracks(source: source)
        }
        selectedTrackID = tracks.first?.id
        // A project whose audio was found somewhere else has its new location to save
        savedState = EditState(sourcePaths: project.map { $0.sources.map(\.path) } ?? Self.paths(of: source),
                               tracks: tracks, albumTags: albumTags)
        zoomToFit()
    }

    /// The album-wide tags of the source files: each field as the files have it, or empty where they
    /// disagree. Files without a value for a field do not count.
    static func albumTags(from fileTags: [AudioTags]) -> AudioTags {
        func common(_ keyPath: KeyPath<AudioTags, String>) -> String {
            let values = Set(fileTags.map { $0[keyPath: keyPath] }.filter { !$0.isEmpty })
            return values.count == 1 ? values.first! : ""
        }
        return AudioTags(artist: common(\.artist), album: common(\.album), albumArtist: common(\.albumArtist),
                         date: common(\.date), genre: common(\.genre))
    }

    /// One track for the whole of a single file. Joined files start out as one track each (see fileTrack).
    private func initialTracks(source: AudioSource) -> [Track] {
        guard source.files.count > 1 else { return [Track(start: 0)] }
        // A file too short for a track of its own (see fitted) gives its start to the next one
        let names = Self.titles(fromFileNames: source.urls)
        return zip(zip(source.urls, names), source.fileStarts).map { file, start in
            var track = fileTrack(file.0, nameTitle: file.1)
            track.start = start
            return track
        }
        .fitted(to: source.duration, minLength: Self.minTrackLength)
    }

    /// The track a joined file starts out as: named after its title tag (or `nameTitle`, its name without a
    /// leading track number), with its artist where it differs from the album's
    private func fileTrack(_ url: URL, nameTitle: String) -> Track {
        let tags = fileTags[Self.path(of: url)] ?? AudioTags()
        let title = tags.title.isEmpty ? nameTitle : tags.title
        let artist = tags.artist == albumTags.artist ? "" : tags.artist
        return Track(start: 0, title: title, artist: artist)
    }

    // MARK: - Arranging files

    /// A file in a new arrangement of the source
    enum FileSlot: Equatable {
        /// A file of the current source, by its index
        case existing(Int)
        case added(URL)
    }

    /// Whether files can be added or rearranged now: not while added files are still being analyzed, whose
    /// arrangement is applied once they are
    var canArrangeFiles: Bool { peaks != nil && addingProgress == nil }

    func presentAddFilesPanel() {
        guard let source, canArrangeFiles else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.audioTypes + [.folder]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = String(localized: "Choose audio files or folders to add after the current ones")
        guard panel.runModal() == .OK else { return }
        let added = Self.audioFiles(in: panel.urls)
        guard !added.isEmpty else { return }
        arrangeFiles(source.files.indices.map(FileSlot.existing) + added.map(FileSlot.added), of: source)
    }

    /// The audio files among `urls`, with folders replaced by the files in them. Files chosen together come
    /// in no particular order, so they are put in Finder's.
    static func audioFiles(in urls: [URL]) -> [URL] {
        var audio: [URL] = []
        for url in urls {
            if isFolder(url) {
                audio += (try? AudioSource.audioFiles(in: url)) ?? []
            } else if AudioSource.supportedExtensions.contains(url.pathExtension.lowercased()) {
                audio.append(url)
            }
        }
        if !urls.contains(where: isFolder) {
            audio.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        return audio
    }

    /// Puts the source's files in a new arrangement as one undoable step: tracks move with their files (see
    /// FileArrangement), tracks of removed files go, and each added file gets a track of its own. Added
    /// files are analyzed first, in the background. `base` is the source the slots' indices refer to; if
    /// the files have changed since (e.g. while the arrange sheet was open), nothing is changed.
    func arrangeFiles(_ slots: [FileSlot], of base: AudioSource) {
        guard let source, !slots.isEmpty else { return }
        guard source == base, canArrangeFiles else {
            errorMessage = String(localized: "The files changed in the meantime. Arrange them again.")
            return
        }
        // The files already open keep the format read when they were opened; only added files are read
        var files: [(url: URL, info: SourceAudioInfo)] = []
        do {
            for slot in slots {
                switch slot {
                case .existing(let i): files.append((source.files[i].url, source.files[i].info))
                case .added(let url): files.append((url, try SourceAudioInfo(url: url)))
                }
            }
        } catch {
            errorMessage = String(localized: "Could not open the file: \(error.localizedDescription)")
            return
        }
        let newSource = AudioSource(files: files)
        var seen = Set(filePeaks.keys)
        let missing = newSource.files.filter { seen.insert(Self.path(of: $0.url)).inserted }
        guard !missing.isEmpty else {
            applyArrangement(slots, newSource)
            return
        }
        let id = loadID
        addingProgress = 0
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let analyzed = try await Self.analyze(missing) { p in
                    Task { @MainActor in if self?.loadID == id, self?.addingProgress != nil { self?.addingProgress = p } }
                }
                await self?.finishAdding(analyzed, slots: slots, newSource: newSource, from: source, loadID: id)
            } catch {
                await self?.failAdding(error, loadID: id)
            }
        }
    }

    private func finishAdding(_ analyzed: [(path: String, peaks: WaveformPeaks, tags: AudioTags)], slots: [FileSlot],
                              newSource: AudioSource, from oldSource: AudioSource, loadID id: UUID) {
        guard loadID == id else { return }
        addingProgress = nil
        for file in analyzed {
            filePeaks[file.path] = file.peaks
            fileTags[file.path] = file.tags
        }
        // The slots refer to the files as they were when the files were chosen
        guard source == oldSource else {
            errorMessage = String(localized: "The files changed in the meantime. Arrange them again.")
            return
        }
        applyArrangement(slots, newSource)
    }

    private func failAdding(_ error: Error, loadID id: UUID) {
        guard loadID == id else { return }
        addingProgress = nil
        errorMessage = String(localized: "Could not read the waveform: \(error.localizedDescription)")
    }

    private func applyArrangement(_ slots: [FileSlot], _ newSource: AudioSource) {
        guard let source else { return }
        let order = slots.map { slot -> Int? in
            if case .existing(let i) = slot { return i }
            return nil
        }
        // Names of the added files, judged together (see titles(fromFileNames:))
        let added = order.indices.filter { order[$0] == nil }
        let names = Dictionary(uniqueKeysWithValues: zip(added, Self.titles(fromFileNames: added.map { newSource.urls[$0] })))
        performUndoable(String(localized: "Arrange Files")) {
            tracks = FileArrangement.tracks(tracks, oldStarts: source.fileStarts, order: order,
                                            newStarts: newSource.fileStarts, tolerance: Self.minTrackLength) { p in
                fileTrack(newSource.urls[p], nameTitle: names[p] ?? newSource.urls[p].deletingPathExtension().lastPathComponent)
            }
            .fitted(to: newSource.duration, minLength: Self.minTrackLength)
            setSource(newSource)
            if index(of: selectedTrackID) == nil { selectedTrackID = tracks.first?.id }
        }
    }

    /// Switches to a source whose files have all been analyzed, keeping the playhead where it was
    private func setSource(_ newSource: AudioSource) {
        guard newSource != source, let joined = joinedPeaks(newSource) else { return }
        let time = player.currentTime
        source = newSource
        peaks = joined
        player.load(newSource)
        player.seek(to: min(time, newSource.duration))
        setVisible(start: visibleStart, duration: visibleDuration)
    }

    /// The names of files without their extension and leading track number: "01 Song.flac", "1-02 Song.flac",
    /// "2. Song.flac" and "3 - Song.flac" all become "Song". A number followed by just a space may be part
    /// of the title ("99 Luftballons", "7 Rings"), so it is taken for a track number only when every file
    /// starts with one and they count up by one, as in a folder of album tracks.
    static func titles(fromFileNames urls: [URL]) -> [String] {
        struct Parsed { let number: Int; let title: String; let isMarked: Bool }
        let pattern = #/^(\d+)(?:-(\d+))?(\.\s*|\s*-\s*|_+\s*|\s+)(.+)$/#
        let names = urls.map { $0.deletingPathExtension().lastPathComponent }
        let parsed = names.map { name -> Parsed? in
            guard let match = name.wholeMatch(of: pattern), let number = Int(match.2 ?? match.1) else { return nil }
            // Zero padding, a disc number or a separator other than a space mark a track number
            let isMarked = (match.1.count > 1 && match.1.hasPrefix("0")) || match.2 != nil
                || !match.3.allSatisfy(\.isWhitespace)
            return Parsed(number: number, title: String(match.4), isMarked: isMarked)
        }
        let numbers = parsed.compactMap { $0?.number }
        let counted = names.count > 1 && numbers.count == names.count && zip(numbers, numbers.dropFirst()).allSatisfy { $1 == $0 + 1 }
        return zip(names, parsed).map { name, parsed in
            guard let parsed, parsed.isMarked || counted else { return name }
            return parsed.title
        }
    }

    private func failLoading(error: Error, loadID id: UUID) {
        guard loadID == id else { return }
        loadingProgress = nil
        source = nil
        projectURL = nil
        errorMessage = String(localized: "Could not read the waveform: \(error.localizedDescription)")
    }

    // MARK: - Project

    /// What a project saves, for telling whether there are unsaved changes
    struct EditState: Equatable {
        var sourcePaths: [String]
        var tracks: [Track]
        var albumTags: AudioTags
    }

    private static func paths(of source: AudioSource) -> [String] {
        source.urls.map(\.standardizedFileURL.path)
    }

    private var editState: EditState {
        EditState(sourcePaths: source.map(Self.paths) ?? [], tracks: tracks, albumTags: albumTags)
    }

    /// Whether the work differs from the project as last saved or opened (or from the audio files as
    /// opened, when they have not been saved as a project yet)
    var hasUnsavedChanges: Bool {
        guard let savedState, peaks != nil else { return false }
        return savedState != editState
    }

    private func openProject(_ url: URL) {
        let project: Project
        do {
            project = try Project(contentsOf: url)
        } catch {
            errorMessage = String(localized: "Could not open the project: \(error.localizedDescription)")
            return
        }
        var audio: [URL] = []
        for file in project.sources {
            guard let found = file.candidates(projectURL: url).first(where: { FileManager.default.fileExists(atPath: $0.path) })
                    ?? locateMissingSource(file)
            else { return }
            audio.append(found)
        }
        openAudio(audio, project: project, projectURL: url)
    }

    /// Asks the user to find an audio file of a project that is no longer where it was saved
    private func locateMissingSource(_ file: Project.SourceFile) -> URL? {
        let name = URL(fileURLWithPath: file.path).lastPathComponent
        let alert = NSAlert()
        alert.messageText = String(localized: "The audio file “\(name)” of this project was not found.")
        alert.informativeText = file.path
        alert.addButton(withTitle: String(localized: "Locate…"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.audioTypes
        panel.message = String(localized: "Choose the audio file “\(name)”")
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Saves to the current project file, or asks where to save the first time. Returns whether it saved.
    @discardableResult
    func saveProject() -> Bool {
        guard let projectURL else { return saveProjectAs() }
        return writeProject(to: projectURL)
    }

    @discardableResult
    func saveProjectAs() -> Bool {
        guard let sourceURL, peaks != nil else { return false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.canCreateDirectories = true
        panel.directoryURL = (projectURL ?? sourceURL).deletingLastPathComponent()
        panel.nameFieldStringValue = displayName.replacingOccurrences(
            of: "." + sourceURL.pathExtension, with: "", options: [.anchored, .backwards])
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return writeProject(to: url)
    }

    func writeProject(to url: URL) -> Bool {
        guard let source else { return false }
        do {
            try Project(sources: source.urls, savedAt: url, album: albumTags, tracks: tracks).write(to: url)
        } catch {
            errorMessage = String(localized: "Could not save the project: \(error.localizedDescription)")
            return false
        }
        projectURL = url
        savedState = editState
        return true
    }

    /// Asks whether to save unsaved changes before they would be lost. Returns false if the user cancels
    /// (or saving fails), and true when the work may be replaced.
    func confirmDiscardingChanges() -> Bool {
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = projectURL.map {
            String(localized: "Do you want to save the changes to “\($0.deletingPathExtension().lastPathComponent)”?")
        } ?? String(localized: "Do you want to save this work as a project?")
        alert.informativeText = String(localized: "Your changes will be lost if you don’t save them.")
        alert.addButton(withTitle: String(localized: "Save…"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Don’t Save"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveProject()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    // MARK: - Undo

    /// The part of the state that undo restores
    struct Snapshot {
        var tracks: [Track]
        var selectedTrackID: Track.ID?
        /// The files and their order
        var source: AudioSource?
    }

    var snapshot: Snapshot { Snapshot(tracks: tracks, selectedTrackID: selectedTrackID, source: source) }

    /// Runs `change` as one undoable step
    func performUndoable(_ actionName: String, _ change: () -> Void) {
        let committedText = finishTextEditing()
        let before = snapshot
        change()
        registerUndo(actionName, restoring: before, separateFromText: committedText)
    }

    /// Registers an undo step that goes back to `before`, if anything changed since. Used directly for
    /// edits made over several events, such as dragging a split point. `separateFromText` keeps text edits
    /// committed earlier in the same event out of this step: the undo manager groups everything
    /// registered during one event into one step.
    func registerUndo(_ actionName: String, restoring before: Snapshot, separateFromText: Bool = false) {
        guard before.tracks != tracks || before.source != source, let undoManager else { return }
        if separateFromText, undoManager.groupsByEvent, undoManager.groupingLevel == 1 {
            undoManager.endUndoGrouping()
            undoManager.beginUndoGrouping()
        }
        undoManager.registerUndo(withTarget: self) { model in
            model.restore(before, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    private var continuousEditStart: Snapshot?

    /// Starts an edit made over several events (a drag, a slider). endContinuousEdit registers it as one step.
    func beginContinuousEdit() {
        finishTextEditing()
        continuousEditStart = snapshot
    }

    func endContinuousEdit(_ actionName: String) {
        if let start = continuousEditStart { registerUndo(actionName, restoring: start) }
        continuousEditStart = nil
    }

    private func restore(_ target: Snapshot, actionName: String) {
        let current = snapshot
        // Titles and artists have undo steps of their own (see setText), so an undo of a split leaves them
        // as they are. The snapshot can hold names typed after it was taken but committed only later.
        let names = Dictionary(current.tracks.map { ($0.id, ($0.title, $0.artist)) }, uniquingKeysWith: { first, _ in first })
        tracks = target.tracks.map { track in
            var track = track
            if let (title, artist) = names[track.id] {
                track.title = title
                track.artist = artist
            }
            return track
        }
        if let targetSource = target.source { setSource(targetSource) }
        selectedTrackID = target.selectedTrackID
        registerUndo(actionName, restoring: current)
    }

    // MARK: - Text

    /// A text field's value in the model
    enum TextTarget: Hashable {
        case track(Track.ID, WritableKeyPath<Track, String>)
        case album(WritableKeyPath<AudioTags, String>)

        var actionName: String {
            switch self {
            case .track(_, \Track.title): String(localized: "Change Title")
            case .track: String(localized: "Change Artist")
            case .album: String(localized: "Change Album Info")
            }
        }
    }

    /// Values from before the text edits in progress. Each becomes one undo step when its field ends
    /// editing: the field editor's own undo is gone by then.
    private var textEditOrigins: [TextTarget: String] = [:]

    func text(_ target: TextTarget) -> String {
        switch target {
        case .track(let id, let keyPath): index(of: id).map { tracks[$0][keyPath: keyPath] } ?? ""
        case .album(let keyPath): albumTags[keyPath: keyPath]
        }
    }

    /// Sets a value as it is typed. See commitTextEdits for undo.
    func setText(_ value: String, for target: TextTarget) {
        if textEditOrigins[target] == nil { textEditOrigins[target] = text(target) }
        assign(value, to: target)
    }

    func textBinding(_ target: TextTarget) -> Binding<String> {
        Binding(get: { self.text(target) }, set: { self.setText($0, for: target) })
    }

    /// Registers the finished text edits for undo, one step per field. Called when a text field ends editing,
    /// and before other edits. Returns whether anything was registered.
    @discardableResult
    func commitTextEdits() -> Bool {
        let origins = textEditOrigins
        textEditOrigins = [:]
        var registered = false
        for (target, original) in origins where text(target) != original {
            registerTextUndo(target, restoring: original)
            registered = true
        }
        return registered
    }

    /// Ends editing in the text field being typed into, if any, and registers its edit for undo. Run before
    /// other edits: they may remove the track the text belongs to, and while the field is still editing,
    /// ⌘Z would undo its typing instead of the registered steps. Returns whether anything was registered.
    @discardableResult
    private func finishTextEditing() -> Bool {
        // Only with typed text pending, so that a text field committing its own value (the fade length)
        // is not asked to end editing from inside its commit
        guard !textEditOrigins.isEmpty else { return false }
        if let window, window.firstResponder is NSText {
            window.makeFirstResponder(nil)
        }
        return commitTextEdits()
    }

    /// Undo restores only this one value, so it stays correct whatever was undone around it
    private func registerTextUndo(_ target: TextTarget, restoring value: String) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            let current = model.text(target)
            model.assign(value, to: target)
            model.registerTextUndo(target, restoring: current)
        }
        undoManager.setActionName(target.actionName)
    }

    private func assign(_ value: String, to target: TextTarget) {
        switch target {
        case .track(let id, let keyPath):
            if let i = index(of: id) { tracks[i][keyPath: keyPath] = value }
        case .album(let keyPath):
            albumTags[keyPath: keyPath] = value
        }
    }

    // MARK: - Tracks

    func index(of id: Track.ID?) -> Int? {
        tracks.firstIndex { $0.id == id }
    }

    func trackIndex(containing time: Double) -> Int? {
        tracks.lastIndex { $0.start <= time } ?? (tracks.isEmpty ? nil : 0)
    }

    func end(ofTrackAt index: Int) -> Double {
        index + 1 < tracks.count ? tracks[index + 1].start : duration
    }

    /// The title, or the one the track is exported under when it has none: "Track" and its export number.
    /// Not localized, as it ends up in the file names and tags.
    func displayTitle(at index: Int) -> String {
        let title = tracks[index].title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? defaultTitle(at: index) : title
    }

    func defaultTitle(at index: Int) -> String {
        exportNumber(ofTrackAt: index).map { "Track \($0)" } ?? "Track"
    }

    /// Selection from the track list. Moves the playhead to the start of the track.
    func selectTrack(_ id: Track.ID?, seek: Bool) {
        selectedTrackID = id
        guard seek, let i = index(of: id) else { return }
        player.seek(to: tracks[i].start)
        reveal(tracks[i].start)
    }

    func selectTrack(containing time: Double) {
        if let i = trackIndex(containing: time) { selectedTrackID = tracks[i].id }
    }

    var selectedIndex: Int? { index(of: selectedTrackID) }

    var canRemoveSelectedSplit: Bool {
        (selectedIndex ?? 0) > 0
    }

    func addSplit(at time: Double) {
        guard peaks != nil,
              time > Self.minTrackLength, time < duration - Self.minTrackLength,
              !tracks.contains(where: { abs($0.start - time) < Self.minTrackLength })
        else { return }
        performUndoable(String(localized: "Split")) {
            var track = Track(start: time)
            let i = tracks.firstIndex { $0.start > time } ?? tracks.endIndex
            // The fade-out stays at the end of the original range, which now belongs to the new track
            if i > 0 {
                track.fadeOut = tracks[i - 1].fadeOut
                tracks[i - 1].fadeOut = Fade(curve: track.fadeOut.curve)
            }
            tracks.insert(track, at: i)
            selectedTrackID = track.id
        }
    }

    /// Removes a split point (the track is merged into the previous one, which takes over its fade-out)
    func removeSplit(_ id: Track.ID) {
        guard let i = index(of: id), i > 0 else { return }
        performUndoable(String(localized: "Delete Split Point")) {
            tracks[i - 1].fadeOut = tracks[i].fadeOut
            tracks.remove(at: i)
            selectedTrackID = tracks[i - 1].id
        }
    }

    func removeSelectedSplit() {
        if let id = selectedTrackID { removeSplit(id) }
    }

    /// Moves a split point without registering undo. Callers register one step for the whole drag.
    func moveSplit(_ id: Track.ID, to time: Double) {
        guard let i = index(of: id), i > 0 else { return }
        let lower = tracks[i - 1].start + Self.minTrackLength
        let upper = end(ofTrackAt: i) - Self.minTrackLength
        tracks[i].start = min(max(time, lower), upper)
    }

    /// Moves the split point at the start of the selected track by `seconds`
    func nudgeSelectedSplit(by seconds: Double) {
        guard let i = selectedIndex, i > 0 else { return }
        performUndoable(String(localized: "Move Split Point")) {
            moveSplit(tracks[i].id, to: tracks[i].start + seconds)
        }
    }

    /// Replaces all split points. See replacingSplits(with:tolerance:) for what is carried over.
    func applySplits(_ times: [Double]) {
        performUndoable(String(localized: "Split at Silences")) {
            tracks = tracks.replacingSplits(with: times, tolerance: Self.minTrackLength)
            selectedTrackID = tracks.first?.id
        }
    }

    func setEnabled(_ isEnabled: Bool, for id: Track.ID) {
        guard let i = index(of: id), tracks[i].isEnabled != isEnabled else { return }
        performUndoable(isEnabled ? String(localized: "Include in Export") : String(localized: "Exclude from Export")) {
            tracks[i].isEnabled = isEnabled
        }
    }

    func toggleSelectedEnabled() {
        guard let i = selectedIndex else { return }
        setEnabled(!tracks[i].isEnabled, for: tracks[i].id)
    }

    // MARK: - Fades

    func fade(_ edge: FadeEdge, ofTrackAt i: Int) -> Fade {
        tracks[i].fade(edge)
    }

    /// The fades of a track as they are applied, shortened when the track is shorter than both together
    func envelope(ofTrackAt i: Int) -> FadeEnvelope {
        FadeEnvelope(length: end(ofTrackAt: i) - tracks[i].start, fadeIn: tracks[i].fadeIn, fadeOut: tracks[i].fadeOut)
    }

    /// Sets a fade's length without registering undo (see Track.setFadeDuration)
    func setFadeDuration(_ edge: FadeEdge, _ duration: Double, ofTrackAt i: Int) {
        tracks[i].setFadeDuration(edge, duration, trackLength: end(ofTrackAt: i) - tracks[i].start)
    }

    func setFadeCurve(_ edge: FadeEdge, _ curve: FadeCurve, ofTrackAt i: Int) {
        performUndoable(edge.curveActionName) {
            switch edge {
            case .start: tracks[i].fadeIn.curve = curve
            case .end: tracks[i].fadeOut.curve = curve
            }
        }
    }

    /// Fades the track under `time` in from its start up to `time`, or out from `time` to its end
    func setFade(_ edge: FadeEdge, at time: Double) {
        guard let i = trackIndex(containing: time) else { return }
        performUndoable(edge.actionName) {
            let duration = edge == .start ? time - tracks[i].start : end(ofTrackAt: i) - time
            setFadeDuration(edge, duration, ofTrackAt: i)
            selectedTrackID = tracks[i].id
        }
    }

    func removeFade(_ edge: FadeEdge, ofTrackAt i: Int) {
        performUndoable(edge.removeActionName) {
            setFadeDuration(edge, 0, ofTrackAt: i)
        }
    }

    /// Copies the fades of the given track to every track. Tracks too short for both are not limited here:
    /// FadeEnvelope shortens both fades in proportion, so neither is lost.
    func applyFadesToAllTracks(from i: Int) {
        let fadeIn = tracks[i].fadeIn, fadeOut = tracks[i].fadeOut
        performUndoable(String(localized: "Apply Fades to All Tracks")) {
            for j in tracks.indices {
                tracks[j].fadeIn = fadeIn
                tracks[j].fadeOut = fadeOut
            }
        }
    }

    // MARK: - Playhead

    func seek(to time: Double) {
        player.seek(to: time)
        selectTrack(containing: player.currentTime)
        reveal(player.currentTime)
    }

    func seek(by seconds: Double) {
        seek(to: player.currentTime + seconds)
    }

    /// Selects the previous / next track and moves the playhead to its start. Going back from the middle
    /// of a track returns to its start first.
    func selectAdjacentTrack(_ offset: Int) {
        guard let current = trackIndex(containing: player.currentTime) ?? selectedIndex else { return }
        var target = current + offset
        if offset < 0, player.currentTime - tracks[current].start > 1 { target = current }
        guard tracks.indices.contains(target) else { return }
        selectTrack(tracks[target].id, seek: true)
    }

    /// Number of the track at `index` among the exported tracks, nil if it is not exported. Excluded tracks
    /// leave no gap: the tracks after them move up.
    func exportNumber(ofTrackAt index: Int) -> Int? {
        exportNumbers.indices.contains(index) ? exportNumbers[index] : nil
    }

    private static func exportNumbers(of tracks: [Track]) -> [Int?] {
        var next = 1
        return tracks.map { track in
            guard track.isEnabled else { return nil }
            defer { next += 1 }
            return next
        }
    }

    func exportSegments() -> [ExportSegment] {
        let total = exportNumbers.compactMap { $0 }.count
        return tracks.indices.compactMap { i in
            guard let number = exportNumber(ofTrackAt: i) else { return nil }
            var tags = albumTags
            tags.title = displayTitle(at: i)
            tags.trackNumber = number
            tags.trackTotal = total
            if !tracks[i].artist.trimmingCharacters(in: .whitespaces).isEmpty {
                tags.artist = tracks[i].artist
            }
            return ExportSegment(start: tracks[i].start, end: end(ofTrackAt: i),
                                 fileBaseName: String(format: "%02d ", number) + displayTitle(at: i), tags: tags,
                                 fadeIn: tracks[i].fadeIn, fadeOut: tracks[i].fadeOut)
        }
    }

    // MARK: - Visible range

    func zoom(by factor: Double, around anchor: Double) {
        guard duration > 0 else { return }
        let newDuration = min(max(visibleDuration * factor, Self.minVisibleDuration), duration)
        let ratio = (anchor - visibleStart) / visibleDuration
        setVisible(start: anchor - ratio * newDuration, duration: newDuration)
    }

    func zoom(by factor: Double) {
        zoom(by: factor, around: visibleStart + visibleDuration / 2)
    }

    func zoomToFit() {
        setVisible(start: 0, duration: max(duration, Self.minVisibleDuration))
    }

    /// Fits the selected track in the view with a little margin on both sides
    func zoomToSelectedTrack() {
        guard let i = selectedIndex else { return }
        let start = tracks[i].start, length = end(ofTrackAt: i) - start
        setVisible(start: start - length * 0.05, duration: max(length * 1.1, Self.minVisibleDuration))
    }

    func pan(by seconds: Double) {
        setVisible(start: visibleStart + seconds, duration: visibleDuration)
    }

    func centerVisible(on time: Double) {
        setVisible(start: time - visibleDuration / 2, duration: visibleDuration)
    }

    /// Scrolls the visible range if the given time is outside of it
    func reveal(_ time: Double) {
        if time < visibleStart || time > visibleStart + visibleDuration {
            setVisible(start: time - visibleDuration * 0.1, duration: visibleDuration)
        }
    }

    private func setVisible(start: Double, duration newDuration: Double) {
        let d = min(newDuration, max(duration, Self.minVisibleDuration))
        visibleDuration = d
        visibleStart = min(max(0, start), max(0, duration - d))
    }

    private func followPlayhead(_ time: Double) {
        guard player.isPlaying, peaks != nil else { return }
        if time > visibleStart + visibleDuration || time < visibleStart {
            setVisible(start: time - visibleDuration * 0.02, duration: visibleDuration)
        }
    }
}

extension FadeEdge {
    /// Header of the fade's inspector section
    var title: String { self == .start ? String(localized: "Fade-In") : String(localized: "Fade-Out") }
    var actionName: String { self == .start ? String(localized: "Fade In") : String(localized: "Fade Out") }
    var curveActionName: String {
        self == .start ? String(localized: "Change Fade-In Curve") : String(localized: "Change Fade-Out Curve")
    }
    var removeActionName: String {
        self == .start ? String(localized: "Remove Fade-In") : String(localized: "Remove Fade-Out")
    }
}
