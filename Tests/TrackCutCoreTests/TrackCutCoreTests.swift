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
    // Rounding up carries into the minutes and hours
    #expect(TimeFormat.string(59.996) == "1:00.00")
    #expect(TimeFormat.string(3599.996) == "1:00:00.00")
    #expect(TimeFormat.string(59.6, fractionDigits: 0) == "1:00")
    #expect(TimeFormat.string(119.96, fractionDigits: 1) == "2:00.0")
}

@Test func exportRefusesToOverwriteTheSource() async throws {
    let dir = try makeTempDir()
    // The default APFS volume is case-insensitive, so "Song.wav" is the same file as "Song.WAV".
    let source = dir.appendingPathComponent("Song.WAV")
    try FileManager.default.moveItem(at: try makeTestWAV(in: dir), to: source)
    let before = try Data(contentsOf: source)

    await #expect(throws: AudioError.self) {
        try await AudioExporter.export(
            source: source, segments: [ExportSegment(start: 0, end: 4, fileBaseName: "Song")],
            format: .wav, to: dir)
    }
    #expect(try Data(contentsOf: source) == before)
}

@Test func truncatedTagsDoNotCrash() async throws {
    let dir = try makeTempDir()

    // FLAC whose Vorbis comment block has a 2-byte body
    var flac = Data("fLaC".utf8)
    flac.append(contentsOf: [0x00, 0x00, 0x00, 34])
    flac.append(Data(count: 34))
    flac.append(contentsOf: [0x84, 0x00, 0x00, 2, 0, 0])
    let flacURL = dir.appendingPathComponent("short.flac")
    try flac.write(to: flacURL)
    #expect(await TagReader.read(from: flacURL) == AudioTags())

    // WAV ending in a LIST chunk that claims 100 bytes but has only 2
    var wav = Data("RIFF".utf8)
    wav.append(contentsOf: [14, 0, 0, 0])
    wav.append(Data("WAVELIST".utf8))
    wav.append(contentsOf: [100, 0, 0, 0])
    wav.append(Data("IN".utf8))
    let wavURL = dir.appendingPathComponent("short.wav")
    try wav.write(to: wavURL)
    #expect(await TagReader.read(from: wavURL) == AudioTags())
}

@Test(arguments: [ExportFormat.sameAsSource, .alac])
func int32SourceKeepsEverySample(format: ExportFormat) async throws {
    let dir = try makeTempDir()
    let url = dir.appendingPathComponent("int32.wav")
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    // Values a Float32 round trip cannot represent exactly
    let samples: [Int32] = [0x4000_0001, -0x4000_0001, 0x7FFF_FFFF, 1, -1, 0x1234_5679]
    do {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        for i in 0..<44_100 { buffer.int32ChannelData![0][i] = samples[i % samples.count] }
        try file.write(from: buffer)
        file.close()
    }

    let out = try await AudioExporter.export(
        source: url, segments: [ExportSegment(start: 0, end: 1, fileBaseName: "out")], format: format, to: dir)[0]
    let file = try AVAudioFile(forReading: out, commonFormat: .pcmFormatInt32, interleaved: false)
    #expect(file.length == 44_100)
    // Int32 reads can return fewer frames than requested, so read until the end.
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100)!
    var read: [Int32] = []
    while file.framePosition < file.length {
        try file.read(into: buffer)
        if buffer.frameLength == 0 { break }
        read += (0..<Int(buffer.frameLength)).map { buffer.int32ChannelData![0][$0] }
    }
    #expect(read.count == 44_100)
    #expect(read == (0..<44_100).map { samples[$0 % samples.count] })
}

/// When an export is cancelled
enum CancelPoint: CaseIterable, Sendable {
    /// after the first chunk of audio is written
    case firstChunk
    /// after all audio is written, while the tags are being written
    case afterAudio
}

@Test(arguments: [ExportFormat.wav, .flac, .aac], CancelPoint.allCases)
func cancelledOverwriteKeepsTheExistingFile(format: ExportFormat, cancelAt: CancelPoint) async throws {
    let dir = try makeTempDir()
    let source = try makeTestWAV(in: dir)
    let outDir = dir.appendingPathComponent("out")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let segments = [ExportSegment(start: 0, end: 13, fileBaseName: "01 All", tags: tags(1))]
    let existing = try AudioExporter.outputURLs(source: source, segments: segments, format: format,
                                                directory: outDir)[0]
    let previous = Data("previous export".utf8)
    try previous.write(to: existing)

    // The first progress report comes after the first chunk is written, and the one at 100% after the
    // last, right before the tags are written.
    let task = Task {
        try await AudioExporter.export(source: source, segments: segments, format: format, to: outDir) { p in
            if cancelAt == .firstChunk || p >= 1 {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
    }
    await #expect(throws: CancellationError.self) { try await task.value }

    #expect(try Data(contentsOf: existing) == previous)
    #expect(try FileManager.default.contentsOfDirectory(atPath: outDir.path) == [existing.lastPathComponent])
}

@Test func channelLayoutDataKeepsEveryDescription() throws {
    let count = 3
    let descriptionsOffset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
    let size = descriptionsOffset + count * MemoryLayout<AudioChannelDescription>.stride
    let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioChannelLayout>.alignment)
    defer { raw.deallocate() }
    raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    let layout = raw.assumingMemoryBound(to: AudioChannelLayout.self)
    layout.pointee.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions
    layout.pointee.mNumberChannelDescriptions = UInt32(count)
    let labels = [kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center]
    let descriptions = (raw + descriptionsOffset).assumingMemoryBound(to: AudioChannelDescription.self)
    for i in 0..<count { descriptions[i].mChannelLabel = labels[i] }

    let data = ResolvedFormat.channelLayoutData(AVAudioChannelLayout(layout: layout))
    #expect(data.count == size)
    let decoded: [AudioChannelLabel] = data.withUnsafeBytes { bytes in
        guard bytes.count >= size else { return [] }
        let base = (bytes.baseAddress! + descriptionsOffset).assumingMemoryBound(to: AudioChannelDescription.self)
        return (0..<count).map { base[$0].mChannelLabel }
    }
    #expect(decoded == labels)
}
