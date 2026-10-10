import AVFoundation
import Combine
import os
import TrackCutCore

@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false
    /// Length of the loaded source in seconds
    private(set) var duration: Double = 0
    /// Called when the loaded source cannot be played
    var onLoadError: ((Error) -> Void)?

    private var player: AVPlayer?
    private var timer: Timer?
    /// Identifies the latest load(), so a slower earlier one does not replace it
    private var loadID = UUID()

    /// Plays the files of `source` one after another, as one composition. The composition is put together
    /// asynchronously; the playhead can be moved in the meantime and playback starts from there once it is
    /// ready.
    func load(_ source: AudioSource) {
        stop()
        player = nil
        duration = source.duration
        currentTime = 0
        let id = UUID()
        loadID = id
        Task {
            do {
                let item = try await Self.makeItem(source)
                guard loadID == id else { return }
                let player = AVPlayer(playerItem: item)
                player.actionAtItemEnd = .pause
                // A seek made before the item is ready to play can be dropped, which would leave the player at 0
                // while the playhead shows another time. So the player is used only once it is ready.
                await Self.waitUntilLoaded(item)
                guard loadID == id else { return }
                if item.status == .failed { throw item.error ?? AudioError.unsupportedFormat }
                self.player = player
                seek(to: currentTime)
            } catch {
                guard loadID == id else { return }
                onLoadError?(error)
            }
        }
    }

    /// Waits until `item`, which must be attached to a player, is ready to play or has failed. (The values of
    /// a Combine publisher of the status do not deliver the change, so this observes it directly.)
    private static func waitUntilLoaded(_ item: AVPlayerItem) async {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        var observation: NSKeyValueObservation?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
                guard item.status != .unknown,
                      resumed.withLock({ wasResumed in defer { wasResumed = true }; return !wasResumed })
                else { return }
                continuation.resume()
            }
        }
        observation?.invalidate()
    }

    /// Whether the loaded source can be played (see load)
    var isReady: Bool { player != nil }

    /// The files placed at their timeline positions (see AudioSource), so the player's time is the
    /// editor's time
    private static func makeItem(_ source: AudioSource) async throws -> AVPlayerItem {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio,
                                                      preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw AudioError.unsupportedFormat }
        for file in source.files {
            // The asset is kept in a variable: a track does not keep its asset alive, and inserting a track
            // whose asset is gone fails
            let asset = AVURLAsset(url: file.url)
            guard let fileTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                throw AudioError.unsupportedFormat
            }
            let available = try await fileTrack.load(.timeRange)
            let length = CMTime(value: file.length, timescale: CMTimeScale(file.info.sampleRate))
            let range = CMTimeRange(start: available.start, duration: CMTimeMinimum(length, available.duration))
            try track.insertTimeRange(range, of: fileTrack,
                                      at: CMTime(value: file.startFrame, timescale: CMTimeScale(source.sampleRate)))
            withExtendedLifetime(asset) {}
        }
        return AVPlayerItem(asset: composition)
    }

    func play() {
        guard let player else { return }
        if currentTime >= duration { seek(to: 0) }
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        if let player { currentTime = min(duration, max(0, player.currentTime().seconds)) }
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func stop() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func seek(to time: Double) {
        let t = min(max(0, time), duration)
        currentTime = t
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 96_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard let player else { return }
        let time = player.currentTime().seconds
        if time.isFinite { currentTime = min(duration, max(0, time)) }
        // The player pauses itself at the end of the composition
        if player.rate == 0 {
            isPlaying = false
            stopTimer()
        }
    }
}
