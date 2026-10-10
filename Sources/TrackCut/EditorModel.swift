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

    var canRemoveSelectedSplit: Bool {
        (index(of: selectedTrackID) ?? 0) > 0
    }

    func addSplit(at time: Double) {
        guard peaks != nil,
              time > Self.minTrackLength, time < duration - Self.minTrackLength,
              !tracks.contains(where: { abs($0.start - time) < Self.minTrackLength })
        else { return }
        let track = Track(start: time)
        let i = tracks.firstIndex { $0.start > time } ?? tracks.endIndex
        tracks.insert(track, at: i)
        selectedTrackID = track.id
    }

    /// Removes a split point (the track is merged into the previous one)
    func removeSplit(_ id: Track.ID) {
        guard let i = index(of: id), i > 0 else { return }
        tracks.remove(at: i)
        selectedTrackID = tracks[i - 1].id
    }

    func removeSelectedSplit() {
        if let id = selectedTrackID { removeSplit(id) }
    }

    func moveSplit(_ id: Track.ID, to time: Double) {
        guard let i = index(of: id), i > 0 else { return }
        let lower = tracks[i - 1].start + Self.minTrackLength
        let upper = end(ofTrackAt: i) - Self.minTrackLength
        tracks[i].start = min(max(time, lower), upper)
    }

    /// Replaces all split points. Titles, artists and the export selection are carried over by position.
    func applySplits(_ times: [Double]) {
        let old = tracks
        tracks = ([0] + times.sorted()).enumerated().map { i, start in
            guard i < old.count else { return Track(start: start) }
            return Track(start: start, title: old[i].title, artist: old[i].artist, isEnabled: old[i].isEnabled)
        }
        selectedTrackID = tracks.first?.id
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
                                 fileBaseName: String(format: "%02d ", i + 1) + displayTitle(at: i), tags: tags)
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
