import AVFoundation
import Combine

@MainActor
final class PlayerModel: ObservableObject {
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var isPlaying = false

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL) throws {
        stop()
        let player = try AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
        self.player = player
        currentTime = 0
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        if let player { currentTime = player.currentTime }
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func stop() {
        player?.stop()
        isPlaying = false
        stopTimer()
    }

    func seek(to time: Double) {
        guard let player else { return }
        let t = min(max(0, time), player.duration)
        player.currentTime = t
        currentTime = t
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
        currentTime = player.currentTime
        if !player.isPlaying {
            isPlaying = false
            stopTimer()
        }
    }
}
