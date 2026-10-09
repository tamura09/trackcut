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

    public init(start: Double, end: Double, fileBaseName: String, tags: AudioTags? = nil) {
        self.start = start
        self.end = end
        self.fileBaseName = fileBaseName
        self.tags = tags
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
        // FLAC supports 16/20/24 bit, ALAC 16/20/24/32 bit
        let flacBits = bits <= 16 ? 16 : (bits == 20 ? 20 : 24)
        let alacBits = [16, 20, 24, 32].contains(bits) ? bits : 16

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

/// AVAudioFile's FLAC / ALAC encoders ignore the requested bit depth and always write 24 bit,
/// so ExtAudioFile is used to set mFormatFlags (the source bit depth) directly.
private final class ExtAudioFileWriter: AudioSink {
    private var ref: ExtAudioFileRef?

    init(url: URL, format: ResolvedFormat, clientFormat: AVAudioFormat) throws {
        let formatID: AudioFormatID
        let fileType: AudioFileTypeID
        let bits: Int
        switch format {
        case .flac(let b): (formatID, fileType, bits) = (kAudioFormatFLAC, kAudioFileFLACType, b)
        case .alac(let b): (formatID, fileType, bits) = (kAudioFormatAppleLossless, kAudioFileM4AType, b)
        default: preconditionFailure()
        }
        let flags: AudioFormatFlags = switch bits {
        case 20: kAppleLosslessFormatFlag_20BitSourceData
        case 24: kAppleLosslessFormatFlag_24BitSourceData
        case 32: kAppleLosslessFormatFlag_32BitSourceData
        default: kAppleLosslessFormatFlag_16BitSourceData
        }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: clientFormat.sampleRate, mFormatID: formatID, mFormatFlags: flags,
            mBytesPerPacket: 0, mFramesPerPacket: 0, mBytesPerFrame: 0,
            mChannelsPerFrame: clientFormat.channelCount, mBitsPerChannel: 0, mReserved: 0)
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
        if resolved == .aac && info.sampleRate > 48_000 {
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

        for (segment, url) in zip(segments, urls) {
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
                if resolved == .aacPassthrough {
                    try await exportPassthrough(source: source, segment: segment, sampleRate: info.sampleRate, to: temp)
                } else {
                    try transcode(source: source, segment: segment, format: resolved, to: temp, progress: report)
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
        case .flac, .alac:
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
        var remaining = total
        while remaining > 0 {
            try Task.checkCancellation()
            let n = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
            try input.read(into: buffer, frameCount: n)
            if buffer.frameLength == 0 { break }
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
