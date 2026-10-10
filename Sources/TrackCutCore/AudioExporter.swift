import AVFoundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case sameAsSource, wav, flac, alac, aac

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sameAsSource: "元のファイルと同じ"
        case .wav: "WAV"
        case .flac: "FLAC"
        case .alac: "Apple Lossless (m4a)"
        case .aac: "AAC 256kbps (m4a)"
        }
    }
}

public struct ExportSegment: Sendable {
    public var start: Double
    public var end: Double
    /// File name without the extension
    public var fileBaseName: String
    /// No tags are written when nil
    public var tags: AudioTags?
    public var fadeIn: Fade
    public var fadeOut: Fade

    public init(start: Double, end: Double, fileBaseName: String, tags: AudioTags? = nil,
                fadeIn: Fade = Fade(), fadeOut: Fade = Fade()) {
        self.start = start
        self.end = end
        self.fileBaseName = fileBaseName
        self.tags = tags
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    public var envelope: FadeEnvelope {
        FadeEnvelope(length: end - start, fadeIn: fadeIn, fadeOut: fadeOut)
    }
}

/// Format information of the source file
public struct SourceAudioInfo: Sendable {
    public let formatID: AudioFormatID
    public let bitDepth: Int
    public let isFloat: Bool
    public let sampleRate: Double
    public let channelCount: Int

    public init(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let asbd = file.fileFormat.streamDescription.pointee
        formatID = asbd.mFormatID
        sampleRate = file.fileFormat.sampleRate
        channelCount = Int(file.fileFormat.channelCount)

        switch asbd.mFormatID {
        case kAudioFormatLinearPCM:
            bitDepth = Int(asbd.mBitsPerChannel)
            isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        case kAudioFormatFLAC, kAudioFormatAppleLossless:
            // mFormatFlags holds the source bit depth (kAppleLosslessFormatFlag_*BitSourceData)
            switch asbd.mFormatFlags {
            case 2: bitDepth = 20
            case 3: bitDepth = 24
            case 4: bitDepth = 32
            default: bitDepth = 16
            }
            isFloat = false
        default:
            bitDepth = 16
            isFloat = false
        }
    }

    var isAAC: Bool {
        [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
         kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD].contains(formatID)
    }

    var isLossless: Bool {
        [kAudioFormatLinearPCM, kAudioFormatFLAC, kAudioFormatAppleLossless].contains(formatID)
    }
}

enum ResolvedFormat: Equatable {
    case pcm(bits: Int, isFloat: Bool)
    case flac(bits: Int)
    case alac(bits: Int)
    case aac
    /// Cuts AAC without re-encoding
    case aacPassthrough

    var fileExtension: String {
        switch self {
        case .pcm: "wav"
        case .flac: "flac"
        case .alac, .aac, .aacPassthrough: "m4a"
        }
    }

    init(_ format: ExportFormat, source: SourceAudioInfo) {
        let bits = source.isLossless ? source.bitDepth : 16
        // FLAC supports 16/20/24 bit, ALAC 16/20/24/32 bit. Other depths go to the nearest supported depth
        // above them, or the highest one (e.g. 64-bit float becomes 24-bit FLAC / 32-bit ALAC).
        let flacBits = [16, 20, 24].first { $0 >= bits } ?? 24
        let alacBits = [16, 20, 24, 32].first { $0 >= bits } ?? 32

        switch format {
        case .sameAsSource:
            switch source.formatID {
            case kAudioFormatLinearPCM: self = .pcm(bits: bits, isFloat: source.isFloat)
            case kAudioFormatFLAC: self = .flac(bits: flacBits)
            case kAudioFormatAppleLossless: self = .alac(bits: alacBits)
            default: self = source.isAAC ? .aacPassthrough : .pcm(bits: 16, isFloat: false)
            }
        case .wav: self = .pcm(bits: bits, isFloat: source.isFloat && source.formatID == kAudioFormatLinearPCM)
        case .flac: self = .flac(bits: flacBits)
        case .alac: self = .alac(bits: alacBits)
        case .aac: self = source.isAAC ? .aacPassthrough : .aac
        }
    }

    func settings(sampleRate: Double, channels: Int, layout: AVAudioChannelLayout?) -> [String: Any] {
        var s: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        switch self {
        case .pcm(let bits, let isFloat):
            s[AVFormatIDKey] = kAudioFormatLinearPCM
            s[AVLinearPCMBitDepthKey] = bits
            s[AVLinearPCMIsFloatKey] = isFloat
            s[AVLinearPCMIsBigEndianKey] = false
            s[AVLinearPCMIsNonInterleaved] = false
        case .aac, .aacPassthrough:
            s[AVFormatIDKey] = kAudioFormatMPEG4AAC
            s[AVEncoderBitRateKey] = 256_000
        case .flac, .alac:
            preconditionFailure("FLAC / ALAC は ExtAudioFileWriter で書き出す")
        }
        if channels > 2, let layout {
            s[AVChannelLayoutKey] = Self.channelLayoutData(layout)
        }
        return s
    }

    /// AudioChannelLayout ends in a variable-length array of channel descriptions, so copying
    /// MemoryLayout<AudioChannelLayout>.size would keep only the first one.
    static func channelLayoutData(_ layout: AVAudioChannelLayout) -> Data {
        let count = Int(layout.layout.pointee.mNumberChannelDescriptions)
        let size = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
            + max(count, 1) * MemoryLayout<AudioChannelDescription>.stride
        return Data(bytes: layout.layout, count: size)
    }
}

/// Common interface for output files
private protocol AudioSink {
    func write(_ buffer: AVAudioPCMBuffer) throws
    /// Finishes the file. Throws if it could not be completed.
    func close() throws
}

// AVAudioFile.close() reports no errors, so it satisfies close() throws as is.
extension AVAudioFile: AudioSink {
    func write(_ buffer: AVAudioPCMBuffer) throws { try write(from: buffer) }
}

/// Writes the formats AVAudioFile gets wrong, with an explicit stream description:
/// - FLAC / ALAC: AVAudioFile's encoders ignore the requested bit depth and always write 24 bit, so
///   mFormatFlags carries the source bit depth
/// - 64-bit float WAV: AVAudioFile writes Float32 when asked for 64-bit float
private final class ExtAudioFileWriter: AudioSink {
    private var ref: ExtAudioFileRef?

    static func handles(_ format: ResolvedFormat) -> Bool {
        switch format {
        case .flac, .alac, .pcm(bits: 64, isFloat: true): true
        default: false
        }
    }

    init(url: URL, format: ResolvedFormat, clientFormat: AVAudioFormat) throws {
        let sampleRate = clientFormat.sampleRate
        let channels = clientFormat.channelCount
        let fileType: AudioFileTypeID
        var asbd: AudioStreamBasicDescription
        switch format {
        case .flac(let bits), .alac(let bits):
            let isFLAC = if case .flac = format { true } else { false }
            fileType = isFLAC ? kAudioFileFLACType : kAudioFileM4AType
            let flags: AudioFormatFlags = switch bits {
            case 20: kAppleLosslessFormatFlag_20BitSourceData
            case 24: kAppleLosslessFormatFlag_24BitSourceData
            case 32: kAppleLosslessFormatFlag_32BitSourceData
            default: kAppleLosslessFormatFlag_16BitSourceData
            }
            asbd = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: isFLAC ? kAudioFormatFLAC : kAudioFormatAppleLossless,
                mFormatFlags: flags, mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
                mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0)
        case .pcm(bits: 64, isFloat: true):
            fileType = kAudioFileWAVEType
            let bytesPerFrame = 8 * channels
            asbd = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
                mChannelsPerFrame: channels, mBitsPerChannel: 64, mReserved: 0)
        default:
            preconditionFailure("\(format) is written with AVAudioFile")
        }
        try Self.check(ExtAudioFileCreateWithURL(url as CFURL, fileType, &asbd, clientFormat.channelLayout?.layout,
                                                 AudioFileFlags.eraseFile.rawValue, &ref))
        var client = clientFormat.streamDescription.pointee
        try Self.check(ExtAudioFileSetProperty(ref!, kExtAudioFileProperty_ClientDataFormat,
                                               UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client))
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let ref else { return }
        try Self.check(ExtAudioFileWrite(ref, buffer.frameLength, buffer.audioBufferList))
    }

    /// ExtAudioFileDispose flushes the last packets and the file header, so its result decides whether
    /// the file is complete.
    func close() throws {
        guard let ref else { return }
        self.ref = nil
        try Self.check(ExtAudioFileDispose(ref))
    }

    deinit { try? close() }

    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

public enum AudioExporter {
    public static func outputURLs(source: URL, segments: [ExportSegment], format: ExportFormat,
                                  directory: URL) throws -> [URL] {
        let resolved = ResolvedFormat(format, source: try SourceAudioInfo(url: source))
        return segments.map {
            directory.appendingPathComponent(FileNameSanitizer.sanitize($0.fileBaseName))
                .appendingPathExtension(resolved.fileExtension)
        }
    }

    /// Writes each segment to its own file. An existing file with the same name is replaced only once
    /// the new one is complete.
    public static func export(source: URL, segments: [ExportSegment], format: ExportFormat, to directory: URL,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [URL] {
        let info = try SourceAudioInfo(url: source)
        let resolved = ResolvedFormat(format, source: info)
        // Fades change the audio, so a faded segment of an AAC source is re-encoded instead of cut as is.
        let formats = segments.map { segment in
            resolved == .aacPassthrough && !segment.envelope.isFlat ? ResolvedFormat.aac : resolved
        }
        if formats.contains(.aac) && info.sampleRate > 48_000 {
            throw AudioError.unsupportedSampleRateForAAC(info.sampleRate)
        }
        let urls = try outputURLs(source: source, segments: segments, format: format, directory: directory)
        // An existing output is replaced once its new file is complete. If that output were the source,
        // the replace would destroy it, so refuse before anything is written.
        if let clash = urls.first(where: { FileIdentity.isSameFile($0, source) }) {
            throw AudioError.outputIsSource(clash.lastPathComponent)
        }
        let totalDuration = max(segments.reduce(0) { $0 + ($1.end - $1.start) }, 0.001)
        var doneDuration = 0.0

        for ((segment, url), segmentFormat) in zip(zip(segments, urls), formats) {
            try Task.checkCancellation()
            // Write to a hidden file next to the output and move it into place only once it is complete,
            // so a cancelled or failed export leaves an existing file untouched.
            let temp = directory.appendingPathComponent(".trackcut-\(UUID().uuidString)")
                .appendingPathExtension(url.pathExtension)
            let base = doneDuration
            let segmentDuration = segment.end - segment.start
            let report: @Sendable (Double) -> Void = { fraction in
                progress((base + fraction * segmentDuration) / totalDuration)
            }
            do {
                if segmentFormat == .aacPassthrough {
                    try await exportPassthrough(source: source, segment: segment, sampleRate: info.sampleRate, to: temp)
                } else {
                    try transcode(source: source, segment: segment, format: segmentFormat, to: temp, progress: report)
                    if let tags = segment.tags {
                        try await TagWriter.write(tags, to: temp)
                    }
                }
                // Writing the tags does not check for cancellation, so check once more before touching the
                // existing file.
                try Task.checkCancellation()
                if FileManager.default.fileExists(atPath: url.path) {
                    _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
                } else {
                    try FileManager.default.moveItem(at: temp, to: url)
                }
            } catch {
                try? FileManager.default.removeItem(at: temp)
                throw error
            }
            doneDuration += segmentDuration
            progress(doneDuration / totalDuration)
        }
        return urls
    }

    private static func transcode(source: URL, segment: ExportSegment, format: ResolvedFormat, to url: URL,
                                  progress: (Double) -> Void) throws {
        // The default processing format is Float32, whose 24-bit mantissa rounds 32-bit integer samples.
        // Read those (and 64-bit float) in a format that holds them exactly.
        let commonFormat: AVAudioCommonFormat = switch format {
        case .pcm(bits: 32, isFloat: false), .alac(bits: 32): .pcmFormatInt32
        case .pcm(bits: 64, isFloat: true): .pcmFormatFloat64
        default: .pcmFormatFloat32
        }
        let input = try AVAudioFile(forReading: source, commonFormat: commonFormat, interleaved: false)
        let processing = input.processingFormat
        let sampleRate = processing.sampleRate
        let output: AudioSink
        switch format {
        case _ where ExtAudioFileWriter.handles(format):
            output = try ExtAudioFileWriter(url: url, format: format, clientFormat: processing)
        default:
            output = try AVAudioFile(
                forWriting: url,
                settings: format.settings(sampleRate: sampleRate, channels: Int(processing.channelCount),
                                          layout: processing.channelLayout),
                commonFormat: processing.commonFormat,
                interleaved: processing.isInterleaved)
        }
        // Close explicitly once everything is written so that an error while finishing the file fails the
        // export. The defer only cleans up after an earlier error.
        var isClosed = false
        defer { if !isClosed { try? output.close() } }

        let startFrame = max(0, AVAudioFramePosition((segment.start * sampleRate).rounded()))
        let endFrame = min(input.length, AVAudioFramePosition((segment.end * sampleRate).rounded()))
        guard endFrame > startFrame else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processing, frameCapacity: 65_536) else {
            throw AudioError.bufferAllocationFailed
        }

        input.framePosition = startFrame
        let total = endFrame - startFrame
        let fades = FrameFades(segment.envelope, sampleRate: sampleRate, frameCount: total)
        var remaining = total
        while remaining > 0 {
            try Task.checkCancellation()
            let n = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
            try input.read(into: buffer, frameCount: n)
            if buffer.frameLength == 0 { break }
            fades.apply(to: buffer, offset: total - remaining)
            try output.write(buffer)
            remaining -= Int64(buffer.frameLength)
            progress(Double(total - remaining) / Double(total))
        }
        isClosed = true
        try output.close()
    }

    private static func exportPassthrough(source: URL, segment: ExportSegment, sampleRate: Double,
                                          to url: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw AudioError.exportSessionUnavailable
        }
        let timescale = CMTimeScale(sampleRate)
        session.timeRange = CMTimeRange(
            start: CMTime(value: CMTimeValue((segment.start * sampleRate).rounded()), timescale: timescale),
            end: CMTime(value: CMTimeValue((segment.end * sampleRate).rounded()), timescale: timescale))
        if let tags = segment.tags {
            session.metadata = M4ATags.metadataItems(tags)
        }
        try await session.export(to: url, as: .m4a)
    }
}

/// A segment's fades counted in frames
struct FrameFades {
    let frameCount: Int64
    let inFrames: Int64
    let outFrames: Int64
    let inCurve: FadeCurve
    let outCurve: FadeCurve

    init(_ envelope: FadeEnvelope, sampleRate: Double, frameCount: Int64) {
        self.frameCount = frameCount
        inFrames = min(frameCount, Int64((envelope.fadeIn.duration * sampleRate).rounded()))
        outFrames = min(frameCount, Int64((envelope.fadeOut.duration * sampleRate).rounded()))
        inCurve = envelope.fadeIn.curve
        outCurve = envelope.fadeOut.curve
    }

    /// Gain of frame `frame` of the segment. The first frame of a fade-in and the last frame of a
    /// fade-out are silent.
    func gain(_ frame: Int64) -> Double {
        var gain = 1.0
        if frame < inFrames {
            gain *= inCurve.gain(Double(frame) / Double(inFrames))
        }
        if frame >= frameCount - outFrames {
            gain *= outCurve.gain(Double(frameCount - 1 - frame) / Double(outFrames))
        }
        return gain
    }

    /// Scales the frames of `buffer` that fall inside a fade. `offset` is the segment frame that the
    /// buffer starts at. Frames outside the fades are left untouched, so they stay bit-exact.
    func apply(to buffer: AVAudioPCMBuffer, offset: Int64) {
        let n = Int64(buffer.frameLength)
        let fadeInEnd = min(n, max(0, inFrames - offset))
        let fadeOutStart = max(fadeInEnd, min(n, max(0, frameCount - outFrames - offset)))
        for range in [0..<fadeInEnd, fadeOutStart..<n] where !range.isEmpty {
            let gains = range.map { gain(offset + $0) }
            Self.scale(buffer, frames: Int(range.lowerBound), gains: gains)
        }
    }

    private static func scale(_ buffer: AVAudioPCMBuffer, frames start: Int, gains: [Double]) {
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = audioBuffer.mData else { continue }
            let stride = Int(audioBuffer.mNumberChannels)
            func scale<Sample>(_: Sample.Type, _ apply: (Sample, Double) -> Sample) {
                let samples = data.assumingMemoryBound(to: Sample.self)
                for (i, gain) in gains.enumerated() {
                    for c in 0..<stride {
                        let index = (start + i) * stride + c
                        samples[index] = apply(samples[index], gain)
                    }
                }
            }
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32: scale(Float.self) { $0 * Float($1) }
            case .pcmFormatFloat64: scale(Double.self) { $0 * $1 }
            // The gain never exceeds 1, so the rounded result stays in range.
            case .pcmFormatInt32: scale(Int32.self) { Int32((Double($0) * $1).rounded()) }
            case .pcmFormatInt16: scale(Int16.self) { Int16((Double($0) * $1).rounded()) }
            default: break
            }
        }
    }
}
