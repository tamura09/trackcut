import AVFoundation
import Testing
@testable import TrackCutCore

/// 3 s tone -> 2 s silence -> 3 s tone -> 2 s silence -> 3 s tone (13 s in total)
private func makeTestWAV(in dir: URL, sampleRate: Double = 44_100, channels: Int = 2,
                         name: String = "source.wav") throws -> URL {
    let url = dir.appendingPathComponent(name)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
        AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let pattern: [(seconds: Double, tone: Bool)] = [(3, true), (2, false), (3, true), (2, false), (3, true)]
    for part in pattern {
        let frames = AVAudioFrameCount(part.seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for ch in 0..<channels {
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

/// A 1-second stereo 64-bit float WAV. AVAudioFile cannot write one (it writes Float32 instead),
/// so the file is assembled by hand.
private func makeFloat64WAV(in dir: URL) throws -> URL {
    let frames = 44_100, channels = 2, bytesPerSample = 8
    var data = Data()
    func le32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) } }
    func le16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) } }
    let dataSize = frames * channels * bytesPerSample
    data.append(Data("RIFF".utf8)); le32(4 + 8 + 16 + 8 + dataSize); data.append(Data("WAVE".utf8))
    data.append(Data("fmt ".utf8)); le32(16)
    le16(3) // WAVE_FORMAT_IEEE_FLOAT
    le16(channels); le32(44_100); le32(44_100 * channels * bytesPerSample)
    le16(channels * bytesPerSample); le16(bytesPerSample * 8)
    data.append(Data("data".utf8)); le32(dataSize)
    for i in 0..<frames {
        let v = 0.5 * sin(Double(i) * 2 * .pi * 440 / 44_100)
        for _ in 0..<channels { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
    }
    let url = dir.appendingPathComponent("float64.wav")
    try data.write(to: url)
    return url
}

/// Bit depths the lossless encoders do not support map to the nearest supported depth above them.
@Test(arguments: [(ExportFormat.alac, 32), (.flac, 24), (.sameAsSource, 64)])
func float64SourceKeepsTheHighestSupportedDepth(format: ExportFormat, expectedBits: Int) async throws {
    let dir = try makeTempDir()
    let url = try makeFloat64WAV(in: dir)
    #expect(try SourceAudioInfo(url: url).bitDepth == 64)

    let out = try await AudioExporter.export(
        source: url, segments: [ExportSegment(start: 0, end: 1, fileBaseName: "out")], format: format, to: dir)[0]
    #expect(try SourceAudioInfo(url: out).bitDepth == expectedBits)
}

@Test func fadeCurvesRiseFromSilenceToFullLevel() {
    for curve in FadeCurve.allCases {
        #expect(curve.gain(0) == 0)
        #expect(abs(curve.gain(1) - 1) < 1e-12)
        let gains = stride(from: 0.0, through: 1.0, by: 0.01).map(curve.gain)
        #expect(zip(gains, gains.dropFirst()).allSatisfy { $0 <= $1 }, "\(curve)")
    }
}

@Test func overlappingFadesAreShortenedInProportion() {
    let envelope = FadeEnvelope(length: 3, fadeIn: Fade(duration: 2), fadeOut: Fade(duration: 4, curve: .sCurve))
    #expect(abs(envelope.fadeIn.duration - 1) < 1e-12)
    #expect(abs(envelope.fadeOut.duration - 2) < 1e-12)
    #expect(envelope.fadeOut.curve == .sCurve)
    #expect(envelope.gain(at: 0) == 0)
    #expect(abs(envelope.gain(at: 1) - 1) < 1e-12)
    #expect(abs(envelope.gain(at: 0.5) - 0.5) < 1e-12)
    #expect(envelope.gain(at: 3) == 0)
    #expect(FadeEnvelope(length: 3, fadeIn: Fade(), fadeOut: Fade()).isFlat)
}

/// Channel 0 of a file as Float32
private func readSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

@Test func exportAppliesFadesAndLeavesTheRestBitExact() async throws {
    let dir = try makeTempDir()
    let source = try makeTestWAV(in: dir)
    let sampleRate = 44_100
    let plain = try await AudioExporter.export(
        source: source, segments: [ExportSegment(start: 0, end: 3, fileBaseName: "plain")], format: .wav, to: dir)[0]
    let faded = try await AudioExporter.export(
        source: source,
        segments: [ExportSegment(start: 0, end: 3, fileBaseName: "faded",
                                 fadeIn: Fade(duration: 1), fadeOut: Fade(duration: 0.5, curve: .equalPower))],
        format: .wav, to: dir)[0]
    let a = try readSamples(plain)
    let b = try readSamples(faded)
    #expect(a.count == 3 * sampleRate && b.count == a.count)

    // 16-bit output: allow for one rounding step on top of the gain
    let lsb: Float = 1.0 / 32_768
    #expect(b.first == 0)
    #expect(b.last == 0)
    for k in stride(from: 0, to: sampleRate, by: 997) {
        let expected = a[k] * Float(k) / Float(sampleRate)
        #expect(abs(b[k] - expected) <= lsb, "fade-in frame \(k)")
    }
    let outFrames = sampleRate / 2
    let outStart = a.count - outFrames
    for k in stride(from: outStart, to: a.count, by: 499) {
        let progress = Double(a.count - 1 - k) / Double(outFrames)
        let expected = a[k] * Float(sin(progress * .pi / 2))
        #expect(abs(b[k] - expected) <= lsb, "fade-out frame \(k)")
    }
    #expect(Array(a[sampleRate..<outStart]) == Array(b[sampleRate..<outStart]))
}

@Test func fadedSegmentsOfAnAACSourceAreReencoded() async throws {
    let dir = try makeTempDir()
    let wav = try makeTestWAV(in: dir)
    let aac = try await AudioExporter.export(
        source: wav, segments: [ExportSegment(start: 0, end: 13, fileBaseName: "aac")], format: .aac, to: dir)[0]
    let cut = try await AudioExporter.export(
        source: aac,
        segments: [ExportSegment(start: 0, end: 3, fileBaseName: "faded", fadeIn: Fade(duration: 2))],
        format: .sameAsSource, to: dir)[0]
    #expect(cut.pathExtension == "m4a")

    let samples = try readSamples(cut)
    func rms(_ range: Range<Int>) -> Float {
        sqrt(samples[range].reduce(0) { $0 + $1 * $1 } / Float(range.count))
    }
    // The first 0.1 s is at most 5% of full level, while 2.5 s in is past the fade
    #expect(rms(0..<4_410) < rms(110_250..<114_660) * 0.1)
}

@Test func editingAShortenedFadeKeepsTheOtherAsApplied() {
    // 4 s + 4 s of fades on a track that is now 5 s long: both are applied at 2.5 s
    var track = Track(start: 0, fadeIn: Fade(duration: 4), fadeOut: Fade(duration: 4))
    track.setFadeDuration(.start, 2, trackLength: 5)
    #expect(track.fadeIn.duration == 2)
    #expect(track.fadeOut.duration == 2.5)
    // Limited by the other fade
    track.setFadeDuration(.start, 4, trackLength: 5)
    #expect(track.fadeIn.duration == 2.5)
    #expect(track.fadeOut.duration == 2.5)
}

@Test func replacingSplitsKeepsFadesWhereTheyAreInTheFile() {
    let old = [
        Track(start: 0, title: "A", isEnabled: false, fadeIn: Fade(duration: 2), fadeOut: Fade(duration: 3)),
        Track(start: 30, title: "B", fadeIn: Fade(duration: 1, curve: .sCurve), fadeOut: Fade(duration: 5)),
    ]
    let new = old.replacingSplits(with: [50, 10, 30.05], tolerance: 0.1)
    #expect(new.map(\.start) == [0, 10, 30.05, 50])
    // Names, export selection and IDs by position in the list
    #expect(new.map(\.title) == ["A", "B", "", ""])
    #expect(new.map(\.isEnabled) == [false, true, true, true])
    #expect(new[0].id == old[0].id && new[1].id == old[1].id)
    // Start and end of the file
    #expect(new[0].fadeIn.duration == 2)
    #expect(new[3].fadeOut.duration == 5)
    // The split point at 30 s is kept (30.05 s), so are the fades on both sides of it
    #expect(new[1].fadeOut.duration == 3)
    #expect(new[2].fadeIn == Fade(duration: 1, curve: .sCurve))
    // New split points get no fades
    #expect(!new[0].fadeOut.isEnabled && !new[1].fadeIn.isEnabled)
    #expect(!new[2].fadeOut.isEnabled && !new[3].fadeIn.isEnabled)

    // One track with a fade-out at the end of the file, split into three
    let single = [Track(start: 0, fadeOut: Fade(duration: 5))].replacingSplits(with: [10, 20], tolerance: 0.1)
    #expect(single.map(\.fadeOut.duration) == [0, 0, 5])
}

// MARK: - Source info and export options

@Test func sourceInfoDescribesTheFile() throws {
    let dir = try makeTempDir()
    let info = try SourceAudioInfo(url: try makeTestWAV(in: dir))
    #expect(info.codecName == "PCM")
    #expect(info.sampleRate == 44_100)
    #expect(info.bitDepth == 16)
    #expect(info.channelCount == 2)
    #expect(abs(info.duration - 13) < 0.001)
    #expect(info.bitRate == 44_100 * 16 * 2)
    #expect(info.fileSize.map { $0 > 13 * 44_100 * 4 } == true)
}

private func exportAll(_ source: URL, as format: ExportFormat, options: ExportOptions, name: String) async throws -> URL {
    try await AudioExporter.export(
        source: source, segments: [ExportSegment(start: 0, end: 13, fileBaseName: name)], format: format,
        options: options, to: source.deletingLastPathComponent())[0]
}

@Test func aacIsEncodedAtTheChosenBitRate() async throws {
    let dir = try makeTempDir()
    let wav = try makeTestWAV(in: dir)
    let low = try SourceAudioInfo(url: try await exportAll(wav, as: .aac, options: ExportOptions(aacBitRate: 96_000), name: "low"))
    let high = try SourceAudioInfo(url: try await exportAll(wav, as: .aac, options: ExportOptions(aacBitRate: 320_000), name: "high"))
    #expect(low.isAAC && high.isAAC)
    // The encoder is VBR, so only roughly
    #expect(low.bitRate.map { $0 < 140_000 } == true, "\(String(describing: low.bitRate))")
    #expect(high.bitRate.map { $0 > 200_000 } == true, "\(String(describing: high.bitRate))")

    // An AAC source is re-encoded at the chosen rate rather than cut as is
    let again = try SourceAudioInfo(url: try await exportAll(dir.appendingPathComponent("high.m4a"), as: .aac,
                                                            options: ExportOptions(aacBitRate: 96_000), name: "again"))
    #expect(again.bitRate.map { $0 < 140_000 } == true)
}

/// Mono AAC tops out below 320 kbps. The encoder gets the nearest rate it accepts instead of failing.
@Test func aacBitRateIsLimitedToWhatTheEncoderAccepts() async throws {
    let dir = try makeTempDir()
    let mono = try makeTestWAV(in: dir, channels: 1)
    let out = try await exportAll(mono, as: .aac, options: ExportOptions(aacBitRate: 320_000), name: "mono")
    #expect(try SourceAudioInfo(url: out).channelCount == 1)
}

@Test func exportConvertsTheSampleRate() async throws {
    let dir = try makeTempDir()
    let wav = try makeTestWAV(in: dir)
    let out = try await exportAll(wav, as: .flac, options: ExportOptions(bitDepth: 24, sampleRate: 48_000), name: "48k")
    let info = try SourceAudioInfo(url: out)
    #expect(info.sampleRate == 48_000)
    #expect(info.bitDepth == 24)
    #expect(abs(info.duration - 13) < 0.01)

    // The tone is still there and silence is still silent
    let samples = try readSamples(out)
    func peak(_ seconds: ClosedRange<Double>) -> Float {
        samples[Int(seconds.lowerBound * 48_000)..<Int(seconds.upperBound * 48_000)].map(abs).max() ?? 0
    }
    #expect(abs(peak(1...2) - 0.5) < 0.01)
    #expect(peak(3.5...4.5) < 0.001)
}

@Test(arguments: [(96_000.0, 48_000.0), (88_200, 44_100), (44_100, 44_100)])
func aacLimitsTheSampleRateTo48kHz(source: Double, expected: Double) async throws {
    let dir = try makeTempDir()
    let wav = try makeTestWAV(in: dir, sampleRate: source)
    let out = try await exportAll(wav, as: .aac, options: ExportOptions(), name: "aac")
    #expect(try SourceAudioInfo(url: out).sampleRate == expected)
}

@Test func sameAsSourceIgnoresTheOptions() async throws {
    let dir = try makeTempDir()
    let wav = try makeTestWAV(in: dir)
    let out = try await exportAll(wav, as: .sameAsSource, options: ExportOptions(bitDepth: 24, sampleRate: 48_000),
                                  name: "same")
    let info = try SourceAudioInfo(url: out)
    #expect(info.sampleRate == 44_100)
    #expect(info.bitDepth == 16)
}

@Test func chosenBitDepthOfAFloatSourceIsInteger() async throws {
    let dir = try makeTempDir()
    let float64 = try makeFloat64WAV(in: dir)
    let out = try await AudioExporter.export(
        source: float64, segments: [ExportSegment(start: 0, end: 1, fileBaseName: "out")], format: .wav,
        options: ExportOptions(bitDepth: 24), to: dir)[0]
    let info = try SourceAudioInfo(url: out)
    #expect(info.bitDepth == 24)
    #expect(!info.isFloat)
}

// MARK: - Projects

@Test func projectRoundTripsAndFindsAMovedSource() throws {
    let dir = try makeTempDir()
    let audioDir = dir.appendingPathComponent("audio")
    try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
    let source = try makeTestWAV(in: audioDir)
    let projectURL = dir.appendingPathComponent("Live.trackcut")
    let tracks = [Track(start: 0, title: "Intro", fadeIn: Fade(duration: 1.5, curve: .sCurve)),
                  Track(start: 4, title: "Song", artist: "Guest", isEnabled: false)]
    let project = Project(sources: [source], savedAt: projectURL, album: AudioTags(album: "Live", date: "2024"),
                          tracks: tracks)
    #expect(project.sources[0].relativePath == "audio/source.wav")
    try project.write(to: projectURL)
    #expect(try Project(contentsOf: projectURL) == project)

    // Move the project and its audio together: the relative path finds the audio first
    let moved = dir.appendingPathComponent("moved")
    try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: audioDir, to: moved.appendingPathComponent("audio"))
    try FileManager.default.moveItem(at: projectURL, to: moved.appendingPathComponent("Live.trackcut"))
    let candidates = try Project(contentsOf: moved.appendingPathComponent("Live.trackcut"))
        .sources[0].candidates(projectURL: moved.appendingPathComponent("Live.trackcut"))
    #expect(candidates.first?.path == moved.appendingPathComponent("audio/source.wav").standardizedFileURL.path)
    #expect(candidates.last?.path == source.standardizedFileURL.path)
}

@Test func projectRefusesNewerAndDamagedFiles() throws {
    let dir = try makeTempDir()
    let newer = dir.appendingPathComponent("newer.trackcut")
    try Data(#"{"version": 99}"#.utf8).write(to: newer)
    #expect { try Project(contentsOf: newer) } throws: { ($0 as? ProjectError) == .newerVersion }
    let damaged = dir.appendingPathComponent("damaged.trackcut")
    try Data(#"{"version": 1, "tracks": 3}"#.utf8).write(to: damaged)
    #expect { try Project(contentsOf: damaged) } throws: { ($0 as? ProjectError) == .unreadable }
}

@Test func projectTracksAreFittedToTheSource() {
    var project = Project(sources: [URL(fileURLWithPath: "/a.wav")], savedAt: URL(fileURLWithPath: "/p.trackcut"),
                          album: AudioTags(), tracks: [])
    project.tracks = [Track(start: 5, title: "B"), Track(start: 0.5, title: "A"), Track(start: 5.05, title: "Too close"),
                      Track(start: 20, title: "Past the end")]
    // B is too short to keep, so "Too close" takes over its start; the last one starts past the end
    #expect(project.tracks(fitting: 13, minLength: 0.1).map(\.title) == ["A", "Too close"])
    #expect(project.tracks(fitting: 13, minLength: 0.1).map(\.start) == [0, 5])
    project.tracks = []
    #expect(project.tracks(fitting: 13, minLength: 0.1).count == 1)

    // Repeated IDs (a copied entry in a hand-edited file) are made distinct
    let copied = Track(start: 0, title: "Copy")
    project.tracks = [copied, { var t = copied; t.start = 4; return t }()]
    let fitted = project.tracks(fitting: 13, minLength: 0.1)
    #expect(fitted.count == 2)
    #expect(Set(fitted.map(\.id)).count == 2)
}

/// A file of a few milliseconds gets no track of its own: the next file's track starts where it does
@Test func tracksForVeryShortFilesAreDropped() {
    let tracks = [Track(start: 0, title: "Blip"), Track(start: 0.02, title: "Song"), Track(start: 9.98, title: "Tail")]
    let fitted = tracks.fitted(to: 10, minLength: 0.1)
    #expect(fitted.map(\.title) == ["Song"])
    #expect(fitted[0].start == 0)
}

// MARK: - Several files as one source

@Test func audioFilesInAFolderAreInFinderOrder() throws {
    let dir = try makeTempDir()
    for name in ["10 Ten.wav", "2 Two.flac", "1 One.m4a", "notes.txt", ".hidden.wav", "Cover.jpg"] {
        try Data().write(to: dir.appendingPathComponent(name))
    }
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
    #expect(try AudioSource.audioFiles(in: dir).map(\.lastPathComponent) == ["1 One.m4a", "2 Two.flac", "10 Ten.wav"])
}

@Test func joinedFilesAreReadAsOneTimelineBitExact() async throws {
    let dir = try makeTempDir()
    let a = try makeTestWAV(in: dir, name: "a.wav")
    let b = try makeTestWAV(in: dir, name: "b.wav")
    let source = try AudioSource(urls: [a, b])
    #expect(source.totalFrames == 2 * 13 * 44_100)
    #expect(source.fileStarts == [0, 13])

    // 2 s on each side of the join
    let out = try await AudioExporter.export(
        source: source, segments: [ExportSegment(start: 11, end: 15, fileBaseName: "across")], format: .wav,
        to: dir.appendingPathComponent("out", isDirectory: true).creatingDirectory())[0]
    let joined = try readSamples(out)
    let original = try readSamples(a)
    #expect(joined.count == 4 * 44_100)
    #expect(Array(joined[0..<88_200]) == Array(original[(11 * 44_100)..<(13 * 44_100)]))
    #expect(Array(joined[88_200...]) == Array(original[0..<(2 * 44_100)]))

    let peaks = try WaveformAnalyzer.analyze(source)
    #expect(abs(peaks.duration - 26) < 0.001)
    // The gaps inside each file are found; the join itself has no silence
    #expect(SilenceDetector.splitPoints(in: peaks, thresholdDB: -50, minDuration: 1).count == 4)
}

/// A mono 48 kHz file after a stereo 44.1 kHz one: the timeline takes 48 kHz stereo and converts the first
@Test func filesOfDifferentFormatsAreConvertedInPlace() async throws {
    let dir = try makeTempDir()
    let a = try makeTestWAV(in: dir, sampleRate: 44_100, channels: 2, name: "a.wav")
    let b = try makeTestWAV(in: dir, sampleRate: 48_000, channels: 1, name: "b.wav")
    let source = try AudioSource(urls: [a, b])
    #expect(source.sampleRate == 48_000)
    #expect(source.channelCount == 2)
    #expect(source.totalFrames == 2 * 13 * 48_000)

    let peaks = try WaveformAnalyzer.analyze(source)
    #expect(abs(peaks.duration - 26) < 0.001)
    // Each gap of each file is where it should be: 3-5 s and 8-10 s into each file
    let gaps = SilenceDetector.silences(in: peaks, thresholdDB: -50, minDuration: 1)
    let expected: [ClosedRange<Double>] = [3...5, 8...10, 16...18, 21...23]
    #expect(gaps.count == 4)
    for (gap, want) in zip(gaps, expected) {
        #expect(abs(gap.lowerBound - want.lowerBound) < 0.01 && abs(gap.upperBound - want.upperBound) < 0.01, "\(gap)")
    }

    let out = try await AudioExporter.export(
        source: source, segments: [ExportSegment(start: 0, end: 26, fileBaseName: "all")], format: .sameAsSource,
        to: dir.appendingPathComponent("out", isDirectory: true).creatingDirectory())[0]
    let info = try SourceAudioInfo(url: out)
    #expect(info.sampleRate == 48_000)
    #expect(info.channelCount == 2)
    #expect(abs(info.duration - 26) < 0.001)

    // Starting in the middle of the converted file keeps the timing: its tone stops at 3 s, 1 s in
    let part = try await AudioExporter.export(
        source: source, segments: [ExportSegment(start: 2, end: 4, fileBaseName: "part")], format: .wav,
        to: dir.appendingPathComponent("out", isDirectory: true))[0]
    let samples = try readSamples(part)
    #expect(samples.count == 2 * 48_000)
    let toneEnd = samples.lastIndex { abs($0) > 0.01 }!
    #expect(abs(Double(toneEnd) / 48_000 - 1) < 0.005, "\(toneEnd)")
}

@Test func aacInsideOneFileIsCutAsIs() async throws {
    let dir = try makeTempDir()
    let wav = try makeTestWAV(in: dir)
    let aac = try await AudioExporter.export(
        source: wav, segments: [ExportSegment(start: 0, end: 13, fileBaseName: "aac")], format: .aac, to: dir)[0]
    let source = try AudioSource(urls: [aac, aac])
    let inside = ExportSegment(start: source.fileStarts[1] + 1, end: source.fileStarts[1] + 3, fileBaseName: "inside")
    let across = ExportSegment(start: source.fileStarts[1] - 1, end: source.fileStarts[1] + 1, fileBaseName: "across")
    // Only the segment within one file is cut without re-encoding
    #expect(AudioExporter.passthroughFile(for: inside, in: source)?.startFrame == source.files[1].startFrame)
    #expect(AudioExporter.passthroughFile(for: across, in: source) == nil)

    let outDir = try dir.appendingPathComponent("out", isDirectory: true).creatingDirectory()
    let urls = try await AudioExporter.export(source: source, segments: [inside, across], format: .sameAsSource, to: outDir)
    for url in urls {
        let file = try AVAudioFile(forReading: url)
        #expect(abs(Double(file.length) / file.processingFormat.sampleRate - 2) < 0.1, "\(url.lastPathComponent)")
    }
}

/// Review: with an AAC file first and a 96 kHz file after it, "same as source" re-encoded the second at
/// 96 kHz, which AAC cannot do
@Test func aacFirstJoinedWithA96kHzFileExportsAsSource() async throws {
    let dir = try makeTempDir()
    let wav = try makeTestWAV(in: dir)
    let aac = try await AudioExporter.export(
        source: wav, segments: [ExportSegment(start: 0, end: 13, fileBaseName: "aac")], format: .aac, to: dir)[0]
    let hiRes = try makeTestWAV(in: dir, sampleRate: 96_000, name: "hires.wav")
    let source = try AudioSource(urls: [aac, hiRes])
    #expect(source.sampleRate == 96_000)

    let inAAC = ExportSegment(start: 1, end: 3, fileBaseName: "in-aac")
    let inHiRes = ExportSegment(start: source.fileStarts[1] + 1, end: source.fileStarts[1] + 3, fileBaseName: "in-hires")
    // The AAC file is still cut as is, in its own time, though the timeline has another rate
    #expect(AudioExporter.passthroughFile(for: inAAC, in: source) != nil)

    let outDir = try dir.appendingPathComponent("out", isDirectory: true).creatingDirectory()
    let urls = try await AudioExporter.export(source: source, segments: [inAAC, inHiRes], format: .sameAsSource,
                                              to: outDir)
    let infos = try urls.map { try SourceAudioInfo(url: $0) }
    #expect(infos.allSatisfy { $0.isAAC })
    #expect(infos.map(\.sampleRate) == [44_100, 48_000])
    #expect(infos.allSatisfy { abs($0.duration - 2) < 0.1 })
}

/// Review: a file that delivers fewer frames than it reported was not padded, so the files after it moved
@Test func aFileShorterThanReportedIsPaddedWithSilence() throws {
    let dir = try makeTempDir()
    let wav = try makeTestWAV(in: dir)
    let real = try AudioSource(url: wav)
    let extra: AVAudioFramePosition = 10_000
    let file = real.files[0]
    let claimed = AudioSource.File(url: file.url, info: file.info, length: file.length + extra, startFrame: 0,
                                   frameCount: file.frameCount + extra)
    let source = AudioSource(files: [claimed], sampleRate: real.sampleRate, channelCount: real.channelCount)
    let reader = try SourceReader(source: source, commonFormat: .pcmFormatFloat32)

    for range in [file.length - 1_000 ..< file.length + extra, file.length + 10 ..< file.length + 500] {
        var frames = 0
        try reader.read(range) { frames += Int($0.frameLength) }
        #expect(frames == range.count)
    }
}

/// Review: joining a stereo file with a 5.1 file failed: a format above stereo needs a channel layout
@Test func stereoJoinedWithSurroundTakesTheSurroundLayout() async throws {
    let dir = try makeTempDir()
    let stereo = try makeTestWAV(in: dir, name: "stereo.wav")
    let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A)!
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channelLayout: layout)
    var settings = format.settings
    settings[AVLinearPCMBitDepthKey] = 16
    settings[AVLinearPCMIsFloatKey] = false
    settings[AVLinearPCMIsNonInterleaved] = false
    settings[AVLinearPCMIsBigEndianKey] = false
    let surroundURL = dir.appendingPathComponent("surround.wav")
    do {
        let file = try AVAudioFile(forWriting: surroundURL, settings: settings, commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for ch in 0..<6 {
            for i in 0..<48_000 { buffer.floatChannelData![ch][i] = 0.25 * sin(Float(i) * 2 * .pi * 440 / 48_000) }
        }
        try file.write(from: buffer)
    }

    let source = try AudioSource(urls: [stereo, surroundURL])
    #expect(source.channelCount == 6)
    let peaks = try WaveformAnalyzer.analyze(source)
    #expect(abs(peaks.duration - 14) < 0.001)
    let out = try await AudioExporter.export(
        source: source, segments: [ExportSegment(start: 12, end: 14, fileBaseName: "across")], format: .wav,
        to: dir.appendingPathComponent("out", isDirectory: true).creatingDirectory())[0]
    let info = try SourceAudioInfo(url: out)
    #expect(info.channelCount == 6)
    #expect(abs(info.duration - 2) < 0.001)
}

private extension URL {
    func creatingDirectory() throws -> URL {
        try FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}

// MARK: - Rearranging files

/// Three files of 10, 20 and 30 s. Tracks: A at 0, B at 5 (runs on into file 2), C at 12, D at 30 (file 3).
private let arrangementTracks = [
    Track(start: 0, title: "A"),
    Track(start: 5, title: "B", fadeOut: Fade(duration: 2)),
    Track(start: 12, title: "C"),
    Track(start: 30, title: "D"),
]

private func arranged(_ order: [Int?], lengths: [Double]) -> [Track] {
    let newStarts = lengths.indices.map { lengths[..<$0].reduce(0, +) }
    return FileArrangement.tracks(arrangementTracks, oldStarts: [0, 10, 30], order: order, newStarts: newStarts,
                                  tolerance: 0.1) { Track(start: 0, title: "new \($0)") }
}

@Test func unchangedArrangementKeepsTheTracks() {
    #expect(arranged([0, 1, 2], lengths: [10, 20, 30]) == arrangementTracks)
}

@Test func movedFilesTakeTheirTracksAlong() {
    // File 3 first: B still runs from file 1 into file 2, which stay together
    let tracks = arranged([2, 0, 1], lengths: [30, 10, 20])
    #expect(tracks.map(\.title) == ["D", "A", "B", "C"])
    #expect(tracks.map(\.start) == [0, 30, 35, 42])
}

@Test func separatedFilesSplitTheTrackBetweenThem() {
    // File 2 first: B is cut where file 2 started, and the part in file 2 moves with it
    let tracks = arranged([1, 0, 2], lengths: [20, 10, 30])
    #expect(tracks.map(\.title) == ["", "C", "A", "B", "D"])
    #expect(tracks.map(\.start) == [0, 2, 20, 25, 30])
    // B's fade-out was at the end of what it covered, which is now the new part's end
    #expect(tracks[0].fadeOut.duration == 2)
    #expect(!tracks[3].fadeOut.isEnabled)
}

@Test func removedAndAddedFiles() {
    // File 2 removed, a new file added at the end
    let tracks = arranged([0, 2, nil], lengths: [10, 30, 5])
    #expect(tracks.map(\.title) == ["A", "B", "D", "new 2"])
    #expect(tracks.map(\.start) == [0, 5, 10, 40])
}

/// PR #9 review: the part of an excluded track split off at a file boundary was exported
@Test func splitPartsKeepTheExportSelection() {
    let tracks = [Track(start: 0, title: "A"), Track(start: 5, title: "Excluded", artist: "Guest", isEnabled: false)]
    let result = FileArrangement.tracks(tracks, oldStarts: [0, 10], order: [1, 0], newStarts: [0, 20],
                                        tolerance: 0.1) { _ in Track(start: 0) }
    #expect(result.map(\.start) == [0, 20, 25])
    #expect(result.map(\.isEnabled) == [false, true, false])
    // and the artist, which would otherwise fall back to the album's
    #expect(result[0].artist == "Guest")
}

/// PR #9 review: starts far below zero survived fitting and crashed the time display
@Test func fittingMovesStartsIntoTheSource() {
    let fitted = [Track(start: -1e20), Track(start: -1e19), Track(start: 0), Track(start: 1e9)]
        .fitted(to: 13, minLength: 0.1)
    #expect(fitted.count == 1)
    #expect(fitted[0].start == 0)
}

/// PR #9 review: re-encoded segments of joined AAC files were written at 256 kbps whatever the source's rate
@Test func reencodedJoinedAACKeepsAboutTheSourceBitRate() async throws {
    let dir = try makeTempDir()
    let wav = try makeTestWAV(in: dir)
    let aac = try await AudioExporter.export(
        source: wav, segments: [ExportSegment(start: 0, end: 13, fileBaseName: "aac")], format: .aac,
        options: ExportOptions(aacBitRate: 96_000), to: dir)[0]
    let source = try AudioSource(urls: [aac, aac])
    let out = try await AudioExporter.export(
        source: source, segments: [ExportSegment(start: 0, end: 13, fileBaseName: "faded", fadeIn: Fade(duration: 2))],
        format: .sameAsSource, to: dir.appendingPathComponent("out", isDirectory: true).creatingDirectory())[0]
    let bitRate = try #require(try SourceAudioInfo(url: out).bitRate)
    #expect(bitRate < 140_000, "\(bitRate)")
}

/// PR #9 review: a float WAV joined with an integer one was exported as integer PCM
@Test func joinedSourceStaysFloatingPointWhenAFileIs() throws {
    let dir = try makeTempDir()
    let float64 = try makeFloat64WAV(in: dir)
    let int16 = try makeTestWAV(in: dir)
    #expect(try AudioSource(urls: [float64, int16]).info.isFloat)
    #expect(try AudioSource(urls: [int16, float64]).info.isFloat)
    #expect(try !AudioSource(urls: [int16, int16]).info.isFloat)
}

/// PR #9 review: once one file needed converting, every file was read as Float32, rounding 32-bit samples
@Test func filesReadAsTheyAreKeepEveryBitNextToConvertedOnes() async throws {
    let dir = try makeTempDir()
    let url = dir.appendingPathComponent("int32.wav")
    let samples: [Int32] = [0x4000_0001, -0x4000_0001, 0x7FFF_FFFF, 1, -1, 0x1234_5679]
    do {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000.0, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for ch in 0..<2 { for i in 0..<48_000 { buffer.int32ChannelData![ch][i] = samples[i % samples.count] } }
        try file.write(from: buffer)
    }
    // The 44.1 kHz file is converted; the 48 kHz one is not
    let source = try AudioSource(urls: [url, try makeTestWAV(in: dir)])
    let reader = try SourceReader(source: source, commonFormat: .pcmFormatInt32)
    var read: [Int32] = []
    try reader.read(0..<48_000) { buffer in
        read += (0..<Int(buffer.frameLength)).map { buffer.int32ChannelData![0][$0] }
    }
    #expect(read == (0..<48_000).map { samples[$0 % samples.count] })
    // and the converted file still comes through
    var converted = 0
    try reader.read(48_000..<96_000) { converted += Int($0.frameLength) }
    #expect(converted == 48_000)
}

/// PR #9 review: a 32-bit integer file joined with a Float32 one was rounded to Float32
@Test func deepIntegerFilesNextToFloatOnesAreExportedAsFloat64() async throws {
    let dir = try makeTempDir()
    func write(_ name: String, bits: Int, isFloat: Bool, _ fill: (AVAudioPCMBuffer) -> Void) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: bits, AVLinearPCMIsFloatKey: isFloat, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: isFloat ? .pcmFormatFloat32 : .pcmFormatInt32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_410)!
        buffer.frameLength = 4_410
        fill(buffer)
        try file.write(from: buffer)
        return url
    }
    let samples: [Int32] = [0x4000_0001, -0x4000_0001, 0x7FFF_FFFF, 1]
    let int32 = try write("int32.wav", bits: 32, isFloat: false) { buffer in
        for i in 0..<4_410 { buffer.int32ChannelData![0][i] = samples[i % samples.count] }
    }
    let float32 = try write("float32.wav", bits: 32, isFloat: true) { buffer in
        for i in 0..<4_410 { buffer.floatChannelData![0][i] = 0.25 }
    }
    let source = try AudioSource(urls: [float32, int32])
    #expect(source.info.isFloat && source.info.bitDepth == 64)

    let out = try await AudioExporter.export(
        source: source, segments: [ExportSegment(start: 0.1, end: 0.2, fileBaseName: "int-part")],
        format: .sameAsSource, to: dir.appendingPathComponent("out", isDirectory: true).creatingDirectory())[0]
    let file = try AVAudioFile(forReading: out, commonFormat: .pcmFormatFloat64, interleaved: false)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_410)!
    try file.read(into: buffer)
    #expect(buffer.frameLength == 4_410)
    // The segment starts 4410 frames into the integer file, a multiple of the pattern's length
    let doubles = buffer.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Double.self)
    let values = (0..<Int(buffer.frameLength)).map { Int64(doubles[$0] * 2_147_483_648) }
    #expect(values == (0..<4_410).map { Int64(samples[$0 % samples.count]) })
}
