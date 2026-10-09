import AVFoundation
import Testing
@testable import TrackCutCore

/// 3 s tone -> 2 s silence -> 3 s tone -> 2 s silence -> 3 s tone (13 s in total)
private func makeTestWAV(in dir: URL, sampleRate: Double = 44_100) throws -> URL {
    let url = dir.appendingPathComponent("source.wav")
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let pattern: [(seconds: Double, tone: Bool)] = [(3, true), (2, false), (3, true), (2, false), (3, true)]
    for part in pattern {
        let frames = AVAudioFrameCount(part.seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<2 {
            let p = buffer.floatChannelData![ch]
            for i in 0..<Int(frames) {
                p[i] = part.tone ? 0.5 * sin(Float(i) * 2 * .pi * 440 / Float(sampleRate)) : 0
            }
        }
        try file.write(from: buffer)
    }
    file.close()
    return url
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func analyzeAndDetectSilence() throws {
    let dir = try makeTempDir()
    let url = try makeTestWAV(in: dir)
    let peaks = try WaveformAnalyzer.analyze(url: url)
    #expect(abs(peaks.duration - 13) < 0.01)
    #expect(peaks.maxs.max()! > 0.49)

    let splits = SilenceDetector.splitPoints(in: peaks, thresholdDB: -50, minDuration: 1)
    #expect(splits.count == 2)
    #expect(abs(splits[0] - 4) < 0.05)
    #expect(abs(splits[1] - 9) < 0.05)
}

private func tags(_ n: Int) -> AudioTags {
    AudioTags(title: "曲 \(n) – Ünïcode", artist: "アーティスト", album: "アルバム名", albumArtist: "Various",
              date: "2024", genre: "Jazz", trackNumber: n, trackTotal: 3)
}

@Test(arguments: [ExportFormat.sameAsSource, .wav, .flac, .alac, .aac])
func exportSegments(format: ExportFormat) async throws {
    let dir = try makeTempDir()
    let url = try makeTestWAV(in: dir)
    let segments = [
        ExportSegment(start: 0, end: 4, fileBaseName: "01 First", tags: tags(1)),
        ExportSegment(start: 4, end: 9, fileBaseName: "02 Se/cond", tags: tags(2)),
        ExportSegment(start: 9, end: 13, fileBaseName: "03 Third", tags: tags(3)),
    ]
    let outDir = dir.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let urls = try await AudioExporter.export(source: url, segments: segments, format: format, to: outDir)

    #expect(urls.count == 3)
    #expect(urls[1].lastPathComponent.hasPrefix("02 Se-cond."))
    // No temporary files are left behind
    #expect(try FileManager.default.contentsOfDirectory(atPath: outDir.path).sorted() == urls.map(\.lastPathComponent).sorted())

    for (segment, out) in zip(segments, urls) {
        let file = try AVAudioFile(forReading: out)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        // Allow for AAC priming
        let tolerance = format == .aac ? 0.1 : 0.001
        #expect(abs(seconds - (segment.end - segment.start)) < tolerance, "\(out.lastPathComponent): \(seconds)s")

        var expected = segment.tags!
        if out.pathExtension == "wav" {
            // WAV INFO has no album artist / track total
            expected.albumArtist = ""
            expected.trackTotal = nil
        }
        let actual = await TagReader.read(from: out)
        #expect(actual == expected, "\(out.lastPathComponent)")
    }
}

@Test func aacPassthroughWritesTags() async throws {
    let dir = try makeTempDir()
    let wav = try makeTestWAV(in: dir)
    let aac = try await AudioExporter.export(
        source: wav, segments: [ExportSegment(start: 0, end: 13, fileBaseName: "aac")], format: .aac, to: dir)
    let cut = try await AudioExporter.export(
        source: aac[0], segments: [ExportSegment(start: 4, end: 9, fileBaseName: "aac-cut", tags: tags(2))],
        format: .sameAsSource, to: dir)
    #expect(await TagReader.read(from: cut[0]) == tags(2))
}

@Test func flacTagsCanBeRewritten() async throws {
    let dir = try makeTempDir()
    let wav = try makeTestWAV(in: dir)
    let flac = try await AudioExporter.export(
        source: wav, segments: [ExportSegment(start: 0, end: 13, fileBaseName: "f", tags: tags(1))],
        format: .flac, to: dir)[0]
    try await TagWriter.write(AudioTags(title: "Second"), to: flac)
    #expect(await TagReader.read(from: flac) == AudioTags(title: "Second"))
    let file = try AVAudioFile(forReading: flac)
    #expect(file.length == 13 * 44_100)
}

@Test func losslessRoundTripKeepsBitDepth() async throws {
    let dir = try makeTempDir()
    let wav = try makeTestWAV(in: dir)
    let flacURLs = try await AudioExporter.export(
        source: wav, segments: [ExportSegment(start: 0, end: 13, fileBaseName: "all")], format: .flac, to: dir)
    let flacInfo = try SourceAudioInfo(url: flacURLs[0])
    #expect(flacInfo.formatID == kAudioFormatFLAC)
    #expect(flacInfo.bitDepth == 16)

    let alacURLs = try await AudioExporter.export(
        source: wav, segments: [ExportSegment(start: 0, end: 13, fileBaseName: "all")], format: .alac, to: dir)
    let alacInfo = try SourceAudioInfo(url: alacURLs[0])
    #expect(alacInfo.formatID == kAudioFormatAppleLossless)
    #expect(alacInfo.bitDepth == 16)

    // FLAC source with "same as source" -> FLAC output
    let again = try await AudioExporter.export(
        source: flacURLs[0], segments: [ExportSegment(start: 1, end: 2, fileBaseName: "part")],
        format: .sameAsSource, to: dir)
    #expect(again[0].pathExtension == "flac")

    // AAC source with "same as source" -> passthrough
    let aac = try await AudioExporter.export(
        source: wav, segments: [ExportSegment(start: 0, end: 13, fileBaseName: "aac")], format: .aac, to: dir)
    let cut = try await AudioExporter.export(
        source: aac[0], segments: [ExportSegment(start: 4, end: 9, fileBaseName: "aac-cut")],
        format: .sameAsSource, to: dir)
    let cutFile = try AVAudioFile(forReading: cut[0])
    #expect(abs(Double(cutFile.length) / cutFile.processingFormat.sampleRate - 5) < 0.1)
}

@Test func timeFormat() {
    #expect(TimeFormat.string(185.42) == "3:05.42")
    #expect(TimeFormat.string(3723.5) == "1:02:03.50")
    #expect(TimeFormat.string(65, fractionDigits: 0) == "1:05")
}
