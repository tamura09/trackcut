import AVFoundation

public enum ExportFormat: String, CaseIterable, Identifiable, Sendable {
    case sameAsSource, wav, flac, alac, aac

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sameAsSource: String(localized: "Same as Source")
        case .wav: "WAV"
        case .flac: "FLAC"
        case .alac: "Apple Lossless (m4a)"
        case .aac: "AAC (m4a)"
        }
    }

    /// Bit depths offered for this format besides the source's own. Empty when the depth is not
    /// a choice (AAC, or "same as source").
    public var bitDepths: [Int] {
        switch self {
        case .wav, .flac, .alac: [16, 24]
        case .sameAsSource, .aac: []
        }
    }

    /// Sample rates offered for this format besides the source's own. Empty for "same as source".
    public var sampleRates: [Double] {
        switch self {
        case .wav, .flac, .alac: [44_100, 48_000, 88_200, 96_000, 176_400, 192_000]
        case .aac: [44_100, 48_000]
        case .sameAsSource: []
        }
    }
}

/// Output settings besides the format. They apply to the formats that offer them (see ExportFormat) and
/// are ignored for "same as source", which keeps everything as it is in the source.
public struct ExportOptions: Sendable, Equatable {
    /// Bit depth of WAV, FLAC and ALAC output. nil keeps the source's depth.
    public var bitDepth: Int?
    /// nil keeps the source's rate. AAC is limited to 48 kHz, so a higher source rate becomes 44.1 kHz
    /// when it is a multiple of it, and 48 kHz otherwise.
    public var sampleRate: Double?
    /// Bit rate of AAC output, in bits per second
    public var aacBitRate: Int

    public static let aacBitRates = [96_000, 128_000, 160_000, 192_000, 256_000, 320_000]

    public init(bitDepth: Int? = nil, sampleRate: Double? = nil, aacBitRate: Int = 256_000) {
        self.bitDepth = bitDepth
        self.sampleRate = sampleRate
        self.aacBitRate = aacBitRate
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
public struct SourceAudioInfo: Sendable, Equatable {
    public let formatID: AudioFormatID
    /// Bits per sample. Lossy formats have none and report 16.
    public let bitDepth: Int
    public let isFloat: Bool
    public let sampleRate: Double
    public let channelCount: Int
    /// Length in seconds
    public let duration: Double
    /// Average bit rate of the audio data in bits per second, nil if the file does not tell
    public let bitRate: Int?
    /// Size of the whole file in bytes, tags included
    public let fileSize: Int64?

    init(formatID: AudioFormatID, bitDepth: Int, isFloat: Bool, sampleRate: Double, channelCount: Int,
         duration: Double, bitRate: Int?, fileSize: Int64?) {
        self.formatID = formatID
        self.bitDepth = bitDepth
        self.isFloat = isFloat
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.duration = duration
        self.bitRate = bitRate
        self.fileSize = fileSize
    }

    public init(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let asbd = file.fileFormat.streamDescription.pointee
        formatID = asbd.mFormatID
        sampleRate = file.fileFormat.sampleRate
        channelCount = Int(file.fileFormat.channelCount)
        duration = Double(file.length) / file.fileFormat.sampleRate
        bitRate = Self.readBitRate(url)
        fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0.map(Int64.init) }

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

    private static func readBitRate(_ url: URL) -> Int? {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr, let fileID else { return nil }
        defer { AudioFileClose(fileID) }
        var bitRate: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioFileGetProperty(fileID, kAudioFilePropertyBitRate, &size, &bitRate) == noErr, bitRate > 0
        else { return nil }
        return Int(bitRate)
    }

    public var isAAC: Bool {
        [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
         kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD].contains(formatID)
    }

    public var isLossless: Bool {
        [kAudioFormatLinearPCM, kAudioFormatFLAC, kAudioFormatAppleLossless].contains(formatID)
    }

    /// Name of the codec, e.g. "FLAC" or "AAC"
    public var codecName: String {
        switch formatID {
        case kAudioFormatLinearPCM: "PCM"
        case kAudioFormatFLAC: "FLAC"
        case kAudioFormatAppleLossless: "Apple Lossless"
        case kAudioFormatMPEG4AAC: "AAC"
        case kAudioFormatMPEG4AAC_HE: "HE-AAC"
        case kAudioFormatMPEG4AAC_HE_V2: "HE-AAC v2"
        case kAudioFormatMPEG4AAC_LD: "AAC-LD"
        case kAudioFormatMPEG4AAC_ELD: "AAC-ELD"
        default:
            // A four-character code such as 'opus'
            String(bytes: withUnsafeBytes(of: formatID.bigEndian) { Array($0) }, encoding: .ascii) ?? "\(formatID)"
        }
    }

    /// The bit rate a re-encoded AAC segment of this source is written at: the source's own, rounded to
    /// the nearest offered rate
    var aacBitRate: Int {
        guard let bitRate else { return 256_000 }
        return ExportOptions.aacBitRates.min { abs($0 - bitRate) < abs($1 - bitRate) }!
    }
}

enum ResolvedFormat: Equatable {
    case pcm(bits: Int, isFloat: Bool)
    case flac(bits: Int)
    case alac(bits: Int)
    case aac(bitRate: Int)
    /// Cuts AAC without re-encoding
    case aacPassthrough

    var fileExtension: String {
        switch self {
        case .pcm: "wav"
        case .flac: "flac"
        case .alac, .aac, .aacPassthrough: "m4a"
        }
    }

    init(_ format: ExportFormat, source: SourceAudioInfo, options: ExportOptions = ExportOptions()) {
        let sourceBits = source.isLossless ? source.bitDepth : 16
        let bits = format == .sameAsSource ? sourceBits : options.bitDepth ?? sourceBits
        // A chosen depth is always an integer one
        let isFloat = bits == sourceBits && source.isFloat && source.formatID == kAudioFormatLinearPCM
        // WAV stores whole bytes. FLAC supports 16/20/24 bit, ALAC 16/20/24/32 bit. Other depths go to the
        // nearest supported depth above them, or the highest one (e.g. 64-bit float becomes 24-bit FLAC /
        // 32-bit ALAC).
        let wavBits = (bits + 7) / 8 * 8
        let flacBits = [16, 20, 24].first { $0 >= bits } ?? 24
        let alacBits = [16, 20, 24, 32].first { $0 >= bits } ?? 32

        switch format {
        case .sameAsSource:
            switch source.formatID {
            case kAudioFormatLinearPCM: self = .pcm(bits: wavBits, isFloat: isFloat)
            case kAudioFormatFLAC: self = .flac(bits: flacBits)
            case kAudioFormatAppleLossless: self = .alac(bits: alacBits)
            default: self = source.isAAC ? .aacPassthrough : .pcm(bits: 16, isFloat: false)
            }
        case .wav: self = .pcm(bits: wavBits, isFloat: isFloat)
        case .flac: self = .flac(bits: flacBits)
        case .alac: self = .alac(bits: alacBits)
        // A chosen bit rate means a new encoding, even for an AAC source
        case .aac: self = .aac(bitRate: options.aacBitRate)
        }
    }

    /// The sample rate asked for: the source's, or the chosen one
    static func requestedSampleRate(_ format: ExportFormat, source: SourceAudioInfo, options: ExportOptions) -> Double {
        format == .sameAsSource ? source.sampleRate : options.sampleRate ?? source.sampleRate
    }

    /// The rate a file of this format is written at when `rate` is asked for. AAC goes up to 48 kHz, so a
    /// higher rate becomes 44.1 kHz when it is a multiple of it, and 48 kHz otherwise.
    func sampleRate(for rate: Double) -> Double {
        guard case .aac = self, rate > 48_000 else { return rate }
        return rate.truncatingRemainder(dividingBy: 44_100) == 0 ? 44_100 : 48_000
    }
}

/// Writes the output file with Extended Audio File Services, which converts from the format the source is
/// read in to the output format, sample rate included. The stream description is given explicitly because
/// AVAudioFile gets some formats wrong:
/// - FLAC / ALAC: AVAudioFile's encoders ignore the requested bit depth and always write 24 bit, so
///   mFormatFlags carries the bit depth to write
/// - 64-bit float WAV: AVAudioFile writes Float32 when asked for 64-bit float
private final class AudioFileWriter {
    private var ref: ExtAudioFileRef?

    init(url: URL, format: ResolvedFormat, sampleRate: Double, clientFormat: AVAudioFormat) throws {
        let channels = clientFormat.channelCount
        let fileType: AudioFileTypeID
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = sampleRate
        asbd.mChannelsPerFrame = channels
        switch format {
        case .pcm(let bits, let isFloat):
            fileType = kAudioFileWAVEType
            asbd.mFormatID = kAudioFormatLinearPCM
            // 8-bit WAV is unsigned
            asbd.mFormatFlags = kAudioFormatFlagIsPacked
                | (isFloat ? kAudioFormatFlagIsFloat : bits > 8 ? kAudioFormatFlagIsSignedInteger : 0)
            asbd.mBitsPerChannel = UInt32(bits)
            asbd.mBytesPerFrame = UInt32(bits / 8) * channels
            asbd.mBytesPerPacket = asbd.mBytesPerFrame
            asbd.mFramesPerPacket = 1
        case .flac(let bits), .alac(let bits):
            let isFLAC = if case .flac = format { true } else { false }
            fileType = isFLAC ? kAudioFileFLACType : kAudioFileM4AType
            asbd.mFormatID = isFLAC ? kAudioFormatFLAC : kAudioFormatAppleLossless
            asbd.mFormatFlags = switch bits {
            case 20: kAppleLosslessFormatFlag_20BitSourceData
            case 24: kAppleLosslessFormatFlag_24BitSourceData
            case 32: kAppleLosslessFormatFlag_32BitSourceData
            default: kAppleLosslessFormatFlag_16BitSourceData
            }
        case .aac:
            fileType = kAudioFileM4AType
            asbd.mFormatID = kAudioFormatMPEG4AAC
            asbd.mFramesPerPacket = 1024
        case .aacPassthrough:
            preconditionFailure("AAC passthrough is cut with AVAssetExportSession")
        }
        try Self.check(ExtAudioFileCreateWithURL(url as CFURL, fileType, &asbd, clientFormat.channelLayout?.layout,
                                                 AudioFileFlags.eraseFile.rawValue, &ref))
        var client = clientFormat.streamDescription.pointee
        try Self.check(ExtAudioFileSetProperty(ref!, kExtAudioFileProperty_ClientDataFormat,
                                               UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client))
        try configureConverter(format: format, resamples: sampleRate != clientFormat.sampleRate)
    }

    /// Sets the AAC bit rate and the resampling quality on the converter between the two formats
    private func configureConverter(format: ResolvedFormat, resamples: Bool) throws {
        guard let ref else { return }
        let bitRate: Int? = if case .aac(let bitRate) = format { bitRate } else { nil }
        guard bitRate != nil || resamples else { return }
        var converter: AudioConverterRef?
        var size = UInt32(MemoryLayout<AudioConverterRef?>.size)
        try Self.check(ExtAudioFileGetProperty(ref, kExtAudioFileProperty_AudioConverter, &size, &converter))
        guard let converter else { return }

        if resamples {
            var complexity = kAudioConverterSampleRateConverterComplexity_Mastering
            var quality = kAudioConverterQuality_Max
            try Self.check(AudioConverterSetProperty(converter, kAudioConverterSampleRateConverterComplexity,
                                                     UInt32(MemoryLayout.size(ofValue: complexity)), &complexity))
            try Self.check(AudioConverterSetProperty(converter, kAudioConverterSampleRateConverterQuality,
                                                     UInt32(MemoryLayout.size(ofValue: quality)), &quality))
        }
        if let bitRate {
            var value = UInt32(Self.applicableBitRate(bitRate, converter: converter))
            try Self.check(AudioConverterSetProperty(converter, kAudioConverterEncodeBitRate,
                                                     UInt32(MemoryLayout.size(ofValue: value)), &value))
        }
        // The converter takes the new settings only once its configuration is set again. Setting a null
        // configuration does that without changing anything else.
        var config: UnsafeRawPointer?
        try Self.check(ExtAudioFileSetProperty(ref, kExtAudioFileProperty_ConverterConfig,
                                               UInt32(MemoryLayout<UnsafeRawPointer?>.size), &config))
    }

    /// The encoder accepts only some bit rates, depending on the sample rate and the channel count (mono
    /// tops out well below 320 kbps). Picks the nearest one it accepts.
    private static func applicableBitRate(_ bitRate: Int, converter: AudioConverterRef) -> Int {
        var size: UInt32 = 0
        guard AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates, &size, nil) == noErr,
              size > 0 else { return bitRate }
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        guard AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates, &size, &ranges) == noErr
        else { return bitRate }
        let rates = ranges.flatMap { [Int($0.mMinimum), Int($0.mMaximum)] }.filter { $0 > 0 }
        if ranges.contains(where: { Double(bitRate) >= $0.mMinimum && Double(bitRate) <= $0.mMaximum }) {
            return bitRate
        }
        return rates.min { abs($0 - bitRate) < abs($1 - bitRate) } ?? bitRate
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
    /// Sample rate the files are written at
    public static func outputSampleRate(source: SourceAudioInfo, format: ExportFormat, options: ExportOptions) -> Double {
        ResolvedFormat(format, source: source, options: options)
            .sampleRate(for: ResolvedFormat.requestedSampleRate(format, source: source, options: options))
    }

    public static func outputURLs(source: URL, segments: [ExportSegment], format: ExportFormat,
                                  directory: URL) throws -> [URL] {
        try outputURLs(source: AudioSource(url: source), segments: segments, format: format, directory: directory)
    }

    /// The files `export` writes. The options do not change the file names.
    public static func outputURLs(source: AudioSource, segments: [ExportSegment], format: ExportFormat,
                                  directory: URL) -> [URL] {
        let resolved = ResolvedFormat(format, source: source.info)
        return segments.map {
            directory.appendingPathComponent(FileNameSanitizer.sanitize($0.fileBaseName))
                .appendingPathExtension(resolved.fileExtension)
        }
    }

    public static func export(source: URL, segments: [ExportSegment], format: ExportFormat,
                              options: ExportOptions = ExportOptions(), to directory: URL,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [URL] {
        try await export(source: AudioSource(url: source), segments: segments, format: format, options: options,
                         to: directory, progress: progress)
    }

    /// Writes each segment to its own file. An existing file with the same name is replaced only once
    /// the new one is complete. Segments are in seconds on the source's timeline and may span files.
    public static func export(source: AudioSource, segments: [ExportSegment], format: ExportFormat,
                              options: ExportOptions = ExportOptions(), to directory: URL,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [URL] {
        let info = source.info
        let resolved = ResolvedFormat(format, source: info, options: options)
        let sampleRate = ResolvedFormat.requestedSampleRate(format, source: info, options: options)
        // An AAC source is cut as is only where it can be: a segment within one AAC file and without fades
        // (which change the audio). Other segments are re-encoded at about the bit rate of the AAC file they
        // start in, or of the source's AAC files.
        let formats = segments.map { segment -> ResolvedFormat in
            guard resolved == .aacPassthrough else { return resolved }
            if segment.envelope.isFlat, passthroughFile(for: segment, in: source) != nil { return resolved }
            let file = source.file(at: AVAudioFramePosition((segment.start * source.sampleRate).rounded()))
            return .aac(bitRate: file.map { $0.info.isAAC ? $0.info.aacBitRate : info.aacBitRate } ?? info.aacBitRate)
        }
        let urls = outputURLs(source: source, segments: segments, format: format, directory: directory)
        // An existing output is replaced once its new file is complete. If that output were a source file,
        // the replace would destroy it, so refuse before anything is written.
        if let clash = urls.first(where: { url in source.urls.contains { FileIdentity.isSameFile(url, $0) } }) {
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
                if segmentFormat == .aacPassthrough, let file = passthroughFile(for: segment, in: source) {
                    try await exportPassthrough(file, segment: segment, timeline: source, to: temp)
                } else {
                    // A re-encoded AAC segment of a joined source may come from a file above 48 kHz
                    try transcode(source: source, segment: segment, format: segmentFormat,
                                  sampleRate: segmentFormat.sampleRate(for: sampleRate), to: temp, progress: report)
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

    /// The AAC file a segment lies entirely within, if any. It is cut from that file in the file's own
    /// time, so it may have another rate than the timeline.
    static func passthroughFile(for segment: ExportSegment, in source: AudioSource) -> AudioSource.File? {
        let start = AVAudioFramePosition((segment.start * source.sampleRate).rounded())
        let end = AVAudioFramePosition((segment.end * source.sampleRate).rounded())
        return source.files.first {
            $0.info.isAAC && start >= $0.startFrame && end <= $0.startFrame + $0.frameCount
        }
    }

    private static func transcode(source: AudioSource, segment: ExportSegment, format: ResolvedFormat,
                                  sampleRate outputRate: Double, to url: URL, progress: (Double) -> Void) throws {
        // The default processing format is Float32, whose 24-bit mantissa rounds 32-bit integer samples.
        // Read those (and 64-bit float) in a format that holds them exactly.
        let commonFormat: AVAudioCommonFormat = switch format {
        case .pcm(bits: 32, isFloat: false), .alac(bits: 32): .pcmFormatInt32
        case .pcm(bits: 64, isFloat: true): .pcmFormatFloat64
        default: .pcmFormatFloat32
        }
        let reader = try SourceReader(source: source, commonFormat: commonFormat)
        let processing = reader.processingFormat
        let sampleRate = processing.sampleRate
        let output = try AudioFileWriter(url: url, format: format, sampleRate: outputRate, clientFormat: processing)
        // Close explicitly once everything is written so that an error while finishing the file fails the
        // export. The defer only cleans up after an earlier error.
        var isClosed = false
        defer { if !isClosed { try? output.close() } }

        let startFrame = max(0, AVAudioFramePosition((segment.start * sampleRate).rounded()))
        let endFrame = min(source.totalFrames, AVAudioFramePosition((segment.end * sampleRate).rounded()))
        guard endFrame > startFrame else { return }

        let total = endFrame - startFrame
        let fades = FrameFades(segment.envelope, sampleRate: sampleRate, frameCount: total)
        var done: Int64 = 0
        try reader.read(startFrame..<endFrame) { buffer in
            fades.apply(to: buffer, offset: done)
            try output.write(buffer)
            done += Int64(buffer.frameLength)
            progress(Double(done) / Double(total))
        }
        isClosed = true
        try output.close()
    }

    /// Cuts a segment out of one AAC file without re-encoding
    private static func exportPassthrough(_ file: AudioSource.File, segment: ExportSegment, timeline: AudioSource,
                                          to url: URL) async throws {
        let asset = AVURLAsset(url: file.url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw AudioError.exportSessionUnavailable
        }
        // The segment in the file's own frames
        let fileStart = Double(file.startFrame) / timeline.sampleRate
        let rate = file.info.sampleRate
        let timescale = CMTimeScale(rate)
        let start = min(file.length, AVAudioFramePosition(((segment.start - fileStart) * rate).rounded()))
        let end = min(file.length, AVAudioFramePosition(((segment.end - fileStart) * rate).rounded()))
        session.timeRange = CMTimeRange(start: CMTime(value: max(0, start), timescale: timescale),
                                        end: CMTime(value: end, timescale: timescale))
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
