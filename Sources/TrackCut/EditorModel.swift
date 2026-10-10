import AppKit
import Combine
import TrackCutCore
import UniformTypeIdentifiers

@MainActor
final class EditorModel: ObservableObject {
    static let supportedExtensions: Set<String> = ["flac", "m4a", "wav"]
    static let minVisibleDuration = 0.5
    static let minTrackLength = 0.1

    @Published private(set) var sourceURL: URL?
    @Published private(set) var peaks: WaveformPeaks?
    @Published private(set) var loadingProgress: Double?
    @Published var tracks: [Track] = []
    @Published var selectedTrackID: Track.ID?
    /// Tags shared by the whole album (only album / artist / albumArtist / date / genre are used)
    @Published var albumTags = AudioTags()
    @Published private(set) var visibleStart: Double = 0
    @Published private(set) var visibleDuration: Double = 1
    @Published var errorMessage: String?

    static let shared = EditorModel()

    let player = PlayerModel()
    /// The window's undo manager, which the Edit menu and ⌘Z use. Set by the detail waveform view.
    weak var undoManager: UndoManager?
    private var loadTask: Task<Void, Never>?
    /// Identifies the latest open(). Results from earlier loads are dropped by comparing against it;
    /// the URL is not enough because the same file can be opened again while it is still loading.
    private var loadID = UUID()
    private var cancellables = Set<AnyCancellable>()

    var duration: Double { peaks?.duration ?? 0 }

    private init() {
        player.$currentTime
            .sink { [weak self] t in MainActor.assumeIsolated { self?.followPlayhead(t) } }
            .store(in: &cancellables)
    }

    // MARK: - File

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            open(url)
        }
    }

    func open(_ url: URL) {
        guard Self.supportedExtensions.contains(url.pathExtension.lowercased()) else {
            errorMessage = "対応形式は FLAC / M4A / WAV です: \(url.lastPathComponent)"
            return
        }
        do {
            try player.load(url)
        } catch {
            errorMessage = "開けませんでした: \(error.localizedDescription)"
            return
        }
        // Only cancel the previous analysis once the new file has opened. Cancelling first would
        // leave the window stuck on the progress view when the new file fails to open.
        loadTask?.cancel()
        undoManager?.removeAllActions()
        let id = UUID()
        loadID = id
        sourceURL = url
        peaks = nil
        tracks = []
        selectedTrackID = nil
        albumTags = AudioTags()
        loadingProgress = 0

        Task { [weak self] in
            let source = await TagReader.read(from: url)
            self?.applySourceTags(source, loadID: id)
        }

        loadTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let peaks = try WaveformAnalyzer.analyze(url: url) { p in
                    Task { @MainActor in
                        if self?.loadID == id, self?.peaks == nil { self?.loadingProgress = p }
                    }
                }
                await self?.finishLoading(peaks: peaks, loadID: id)
            } catch is CancellationError {
            } catch {
                await self?.failLoading(error: error, loadID: id)
            }
        }
    }

    private func finishLoading(peaks: WaveformPeaks, loadID id: UUID) {
        guard loadID == id else { return }
        self.peaks = peaks
        loadingProgress = nil
        tracks = [Track(start: 0)]
        selectedTrackID = tracks.first?.id
        zoomToFit()
    }

    /// Fills in the source file's tags, but only for fields the user has not filled yet
    private func applySourceTags(_ source: AudioTags, loadID id: UUID) {
        guard loadID == id else { return }
        if albumTags.album.isEmpty { albumTags.album = source.album }
        if albumTags.artist.isEmpty { albumTags.artist = source.artist }
        if albumTags.albumArtist.isEmpty { albumTags.albumArtist = source.albumArtist }
        if albumTags.date.isEmpty { albumTags.date = source.date }
        if albumTags.genre.isEmpty { albumTags.genre = source.genre }
    }

    private func failLoading(error: Error, loadID id: UUID) {
        guard loadID == id else { return }
        loadingProgress = nil
        sourceURL = nil
        errorMessage = "波形を読み込めませんでした: \(error.localizedDescription)"
    }

    // MARK: - Undo

    /// The part of the state that undo restores
    struct Snapshot {
        var tracks: [Track]
        var selectedTrackID: Track.ID?
    }

    var snapshot: Snapshot { Snapshot(tracks: tracks, selectedTrackID: selectedTrackID) }

    /// Runs `change` as one undoable step
    func performUndoable(_ actionName: String, _ change: () -> Void) {
        let before = snapshot
        change()
        registerUndo(actionName, restoring: before)
    }

    /// Registers an undo step that goes back to `before`, if anything changed since. Used directly for
    /// edits made over several events, such as dragging a split point.
    func registerUndo(_ actionName: String, restoring before: Snapshot) {
        guard before.tracks != tracks, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { model in
            model.restore(before, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }

    private var continuousEditStart: Snapshot?

    /// Starts an edit made over several events (a drag, a slider). endContinuousEdit registers it as one step.
    func beginContinuousEdit() {
        continuousEditStart = snapshot
    }

    func endContinuousEdit(_ actionName: String) {
        if let start = continuousEditStart { registerUndo(actionName, restoring: start) }
        continuousEditStart = nil
    }

    private func restore(_ target: Snapshot, actionName: String) {
        let current = snapshot
        // Titles and artists are typed into text fields, which keep their own undo while editing, so an
        // undo of a split keeps the names typed since then.
        let names = Dictionary(uniqueKeysWithValues: current.tracks.map { ($0.id, ($0.title, $0.artist)) })
        tracks = target.tracks.map { track in
            var track = track
            if let (title, artist) = names[track.id] {
                track.title = title
                track.artist = artist
            }
            return track
        }
        selectedTrackID = target.selectedTrackID
        registerUndo(actionName, restoring: current)
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

    func displayTitle(at index: Int) -> String {
        let title = tracks[index].title.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? "Track \(index + 1)" : title
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
        performUndoable("分割") {
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
        performUndoable("分割点を削除") {
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
        performUndoable("分割点を移動") {
            moveSplit(tracks[i].id, to: tracks[i].start + seconds)
        }
    }

    /// Replaces all split points. See replacingSplits(with:tolerance:) for what is carried over.
    func applySplits(_ times: [Double]) {
        performUndoable("無音区間で分割") {
            tracks = tracks.replacingSplits(with: times, tolerance: Self.minTrackLength)
            selectedTrackID = tracks.first?.id
        }
    }

    func setEnabled(_ isEnabled: Bool, for id: Track.ID) {
        guard let i = index(of: id), tracks[i].isEnabled != isEnabled else { return }
        performUndoable(isEnabled ? "書き出しに含める" : "書き出しから外す") {
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
        performUndoable(edge.actionName + "のカーブ") {
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
        performUndoable(edge.actionName + "を解除") {
            setFadeDuration(edge, 0, ofTrackAt: i)
        }
    }

    /// Copies the fades of the given track to every track. Tracks too short for both are not limited here:
    /// FadeEnvelope shortens both fades in proportion, so neither is lost.
    func applyFadesToAllTracks(from i: Int) {
        let fadeIn = tracks[i].fadeIn, fadeOut = tracks[i].fadeOut
        performUndoable("フェードをすべてのトラックに適用") {
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

    func exportSegments() -> [ExportSegment] {
        tracks.indices.compactMap { i in
            guard tracks[i].isEnabled else { return nil }
            var tags = albumTags
            tags.title = displayTitle(at: i)
            tags.trackNumber = i + 1
            tags.trackTotal = tracks.count
            if !tracks[i].artist.trimmingCharacters(in: .whitespaces).isEmpty {
                tags.artist = tracks[i].artist
            }
            return ExportSegment(start: tracks[i].start, end: end(ofTrackAt: i),
                                 fileBaseName: String(format: "%02d ", i + 1) + displayTitle(at: i), tags: tags,
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
    var actionName: String { self == .start ? "フェードイン" : "フェードアウト" }
}
