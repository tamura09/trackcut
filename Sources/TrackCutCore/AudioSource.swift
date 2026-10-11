import AVFoundation

/// One or more audio files played one after another as a single timeline. Files whose sample rate or
/// channel count differ from the timeline's are converted as they are read.
public struct AudioSource: Sendable, Equatable {
    public static let supportedExtensions: Set<String> = ["flac", "m4a", "wav"]

    public struct File: Sendable, Equatable {
        public let url: URL
        public let info: SourceAudioInfo
        /// Frames in the file, at its own sample rate
        public let length: AVAudioFramePosition
        /// Where the file starts in the timeline, in timeline frames
        public let startFrame: AVAudioFramePosition
        /// Length of the file in timeline frames
        public let frameCount: AVAudioFramePosition
    }

    public let files: [File]
    /// Sample rate of the timeline: the highest of the files, so none of them loses detail
    public let sampleRate: Double
    /// Channel count of the timeline: the highest of the files. Other files' channels are placed by their
    /// layout, and a mono file plays on the left and right channels (see SourceReader.channelMap).
    public let channelCount: Int

    public init(url: URL) throws {
        try self.init(urls: [url])
    }

    public init(urls: [URL]) throws {
        self.init(files: try urls.map { ($0, try SourceAudioInfo(url: $0)) })
    }

    /// A source of files whose format has already been read, e.g. those of another source
    public init(files: [(url: URL, info: SourceAudioInfo)]) {
        precondition(!files.isEmpty, "a source has at least one file")
        let sampleRate = files.map(\.info.sampleRate).max()!
        var placed: [File] = []
        var position: AVAudioFramePosition = 0
        for (url, info) in files {
            let length = AVAudioFramePosition((info.duration * info.sampleRate).rounded())
            let frameCount = info.sampleRate == sampleRate
                ? length : AVAudioFramePosition((Double(length) * sampleRate / info.sampleRate).rounded())
            placed.append(File(url: url, info: info, length: length, startFrame: position, frameCount: frameCount))
            position += frameCount
        }
        self.init(files: placed, sampleRate: sampleRate, channelCount: files.map(\.info.channelCount).max()!)
    }

    init(files: [File], sampleRate: Double, channelCount: Int) {
        self.files = files
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public var urls: [URL] { files.map(\.url) }

    /// The file at timeline frame `frame` (the last file for a frame at or past the end)
    func file(at frame: AVAudioFramePosition) -> File? {
        files.last { $0.startFrame <= frame } ?? files.first
    }
    public var totalFrames: AVAudioFramePosition { files.last.map { $0.startFrame + $0.frameCount } ?? 0 }
    public var duration: Double { Double(totalFrames) / sampleRate }

    /// Start of each file in seconds on the timeline
    public var fileStarts: [Double] { files.map { Double($0.startFrame) / sampleRate } }

    /// The format a "same as source" export follows: the first file's codec, with the highest bit depth
    /// of the lossless files (floating point if any of them is, 64-bit when that is needed to hold a deeper
    /// integer file exactly) and the timeline's sample rate and channel count
    public var info: SourceAudioInfo {
        let first = files[0].info
        guard files.count > 1 else { return first }
        let lossless = files.filter(\.info.isLossless)
        let isFloat = lossless.contains(where: \.info.isFloat)
        var bitDepth = lossless.map(\.info.bitDepth).max() ?? first.bitDepth
        // Float32 holds integers of up to 24 bits exactly; deeper integer files next to float ones need Float64
        if isFloat, bitDepth < 64, lossless.contains(where: { !$0.info.isFloat && $0.info.bitDepth > 24 }) {
            bitDepth = 64
        }
        // The highest bit rate of the AAC files: what re-encoded AAC is written at by default
        let aacBitRate = files.filter(\.info.isAAC).compactMap(\.info.bitRate).max()
        return SourceAudioInfo(formatID: first.formatID, bitDepth: bitDepth,
                               isFloat: isFloat,
                               sampleRate: sampleRate, channelCount: channelCount, duration: duration, bitRate: aacBitRate,
                               fileSize: files.compactMap(\.info.fileSize).reduce(0, +),
                               hasLosslessAudio: !lossless.isEmpty)
    }

    /// The supported audio files directly inside `folder` (not in subfolders), in the order Finder lists them
    public static func audioFiles(in folder: URL) throws -> [URL] {
        try FileManager.default
            .contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

/// Reads a stretch of an AudioSource's timeline in one format, across file boundaries
final class SourceReader {
    let source: AudioSource
    /// Format of the buffers handed out: non-interleaved, at the timeline's rate and channel count
    let processingFormat: AVAudioFormat

    /// `commonFormat` is the sample format of the buffers. Files that need no conversion are read in it
    /// directly, so they keep every bit; converted files are read as Float32 and converted to it.
    init(source: AudioSource, commonFormat: AVAudioCommonFormat) throws {
        self.source = source
        let common = commonFormat
        // The first file's layout, when it has the timeline's channel count (layouts matter above stereo)
        let firstFormat = try AVAudioFile(forReading: source.files[0].url, commonFormat: common, interleaved: false)
            .processingFormat
        if Int(firstFormat.channelCount) == source.channelCount, firstFormat.sampleRate == source.sampleRate {
            processingFormat = firstFormat
        } else if let format = try Self.format(common, for: source) {
            processingFormat = format
        } else {
            throw AudioError.unsupportedFormat
        }
    }

    /// A format at the timeline's rate and channel count. Above stereo a format needs a channel layout:
    /// that of a file with the timeline's channel count.
    private static func format(_ common: AVAudioCommonFormat, for source: AudioSource) throws -> AVAudioFormat? {
        let channels = AVAudioChannelCount(source.channelCount)
        guard channels > 2 else {
            return AVAudioFormat(commonFormat: common, sampleRate: source.sampleRate, channels: channels, interleaved: false)
        }
        let layout = try source.files.first { $0.info.channelCount == source.channelCount }
            .flatMap { try AVAudioFile(forReading: $0.url).processingFormat.channelLayout }
            ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels))
        guard let layout else { return nil }
        return AVAudioFormat(commonFormat: common, sampleRate: source.sampleRate, interleaved: false, channelLayout: layout)
    }

    /// Reads timeline frames `range` and passes them to `body` in buffers of at most `chunkFrames` frames.
    /// A buffer is only valid during the call.
    func read(_ range: Range<AVAudioFramePosition>, chunkFrames: AVAudioFrameCount = 65_536,
              _ body: (AVAudioPCMBuffer) throws -> Void) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: chunkFrames) else {
            throw AudioError.bufferAllocationFailed
        }
        for file in source.files {
            let fileRange = file.startFrame..<(file.startFrame + file.frameCount)
            let overlap = range.clamped(to: fileRange)
            guard !overlap.isEmpty else { continue }
            let local = (overlap.lowerBound - file.startFrame)..<(overlap.upperBound - file.startFrame)
            // A file at the timeline's rate needs at most its channels mapped, which is done here without
            // touching the samples; only a different rate goes through a converter (and Float32)
            if file.info.sampleRate == source.sampleRate {
                try readDirectly(file, local, buffer: buffer, body)
            } else {
                try readConverted(file, local, buffer: buffer, body)
            }
        }
    }

    private func readDirectly(_ file: AudioSource.File, _ range: Range<AVAudioFramePosition>,
                              buffer: AVAudioPCMBuffer, _ body: (AVAudioPCMBuffer) throws -> Void) throws {
        // Core Audio converts integer samples to Float64 by way of Float32, which rounds 32-bit samples. So an
        // integer file is read as Int32 and widened here.
        let widensIntegers = processingFormat.commonFormat == .pcmFormatFloat64 && file.info.isLossless && !file.info.isFloat
        let input = try AVAudioFile(forReading: file.url,
                                    commonFormat: widensIntegers ? .pcmFormatInt32 : processingFormat.commonFormat,
                                    interleaved: false)
        // Read into a buffer of the file's own format when its samples or channels have to be mapped
        let channelMap = Self.channelMap(from: input.processingFormat, to: processingFormat)
        let mapped = widensIntegers || channelMap != Array(0..<Int(processingFormat.channelCount))
        let fileBuffer = mapped ? AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: buffer.frameCapacity) : nil
        if mapped, fileBuffer == nil { throw AudioError.bufferAllocationFailed }
        var delivered = 0
        if range.lowerBound < input.length {
            input.framePosition = range.lowerBound
            var remaining = min(range.count, Int(input.length - range.lowerBound))
            while remaining > 0 {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(Int(buffer.frameCapacity), remaining))
                if let fileBuffer {
                    try input.read(into: fileBuffer, frameCount: count)
                    Self.map(fileBuffer, into: buffer, channels: channelMap)
                } else {
                    try input.read(into: buffer, frameCount: count)
                }
                if buffer.frameLength == 0 { break }
                remaining -= Int(buffer.frameLength)
                delivered += Int(buffer.frameLength)
                try body(buffer)
            }
        }
        // Whatever the file does not deliver is silence, so the files after it stay in place
        try pad(range.count - delivered, buffer: buffer, body)
    }

    /// Reads a file whose sample rate or channel count differs, converting it to the processing format
    private func readConverted(_ file: AudioSource.File, _ range: Range<AVAudioFramePosition>,
                               buffer: AVAudioPCMBuffer, _ body: (AVAudioPCMBuffer) throws -> Void) throws {
        let input = try AVAudioFile(forReading: file.url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let converter = AVAudioConverter(from: input.processingFormat, to: processingFormat),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_384)
        else { throw AudioError.unsupportedFormat }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        let ratio = file.info.sampleRate / source.sampleRate
        input.framePosition = min(input.length, AVAudioFramePosition((Double(range.lowerBound) * ratio).rounded()))
        var remaining = range.count
        var inputEnded = false
        var readError: Error?
        while remaining > 0 {
            try Task.checkCancellation()
            buffer.frameLength = 0
            let capacity = AVAudioFrameCount(min(Int(buffer.frameCapacity), remaining))
            guard let out = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: capacity) else {
                throw AudioError.bufferAllocationFailed
            }
            var conversionError: NSError?
            let status = converter.convert(to: out, error: &conversionError) { _, inputStatus in
                // Reading at the end of the file throws, so stop before it
                if inputEnded || input.framePosition >= input.length {
                    inputEnded = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try input.read(into: inBuffer)
                } catch {
                    readError = error
                    inBuffer.frameLength = 0
                }
                if inBuffer.frameLength == 0 {
                    inputEnded = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if let readError { throw readError }
            if status == .error { throw conversionError ?? AudioError.unsupportedFormat }
            if out.frameLength == 0 { break }
            remaining -= Int(out.frameLength)
            try body(out)
            if status == .endOfStream { break }
        }
        try pad(remaining, buffer: buffer, body)
    }

    /// For each channel of `target`, the channel of `source` that goes into it, or nil for silence. Channels
    /// are matched by their place in the layouts (a 5.1 file may put the centre first), so a stereo file's
    /// left channel lands on the left speaker. A mono file goes to the left and right speakers, or to every
    /// channel when the target has neither. Channels whose labels do not tell them apart (none, unknown,
    /// unused, or the same label twice) are matched in order, and a format onto its own layout is unchanged.
    static func channelMap(from source: AVAudioFormat, to target: AVAudioFormat) -> [Int?] {
        let sourceLabels = labels(of: source), targetLabels = labels(of: target)
        let sourceCount = Int(source.channelCount)
        let inOrder = targetLabels.indices.map { $0 < sourceCount ? $0 : nil }
        if sourceLabels == targetLabels { return inOrder }
        if sourceCount == 1 {
            let speakers: Set<AudioChannelLabel> = [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
            let hasSpeakers = targetLabels.contains { speakers.contains($0) }
            return targetLabels.map { !hasSpeakers || speakers.contains($0) ? 0 : nil }
        }
        let vague: Set<AudioChannelLabel> = [kAudioChannelLabel_Unknown, kAudioChannelLabel_Unused]
        func telling(_ labels: [AudioChannelLabel]) -> Bool {
            Set(labels).count == labels.count && !labels.contains(where: vague.contains)
        }
        guard telling(sourceLabels), telling(targetLabels) else { return inOrder }
        let byLabel = targetLabels.map { label in sourceLabels.firstIndex(of: label) }
        // Layouts that share no labels (e.g. discrete channels) are matched in order
        return byLabel.allSatisfy({ $0 == nil }) ? inOrder : byLabel
    }

    /// The label of each channel of `format`. Mono and stereo formats without a layout are taken as mono
    /// and left/right; a layout that cannot be read gives discrete channels.
    private static func labels(of format: AVAudioFormat) -> [AudioChannelLabel] {
        let count = Int(format.channelCount)
        let labels = layoutLabels(of: format)
        return labels.count == count ? labels : (0..<count).map { kAudioChannelLabel_Discrete_0 + AudioChannelLabel($0) }
    }

    private static func layoutLabels(of format: AVAudioFormat) -> [AudioChannelLabel] {
        let count = Int(format.channelCount)
        guard let layout = format.channelLayout else {
            return count == 1 ? [kAudioChannelLabel_Mono]
                : count == 2 ? [kAudioChannelLabel_Left, kAudioChannelLabel_Right]
                : (0..<count).map { kAudioChannelLabel_Discrete_0 + AudioChannelLabel($0) }
        }
        var tag = layout.layoutTag
        var size: UInt32 = 0
        // Expand a layout given by its tag into one channel description per channel
        guard tag != kAudioChannelLayoutTag_UseChannelDescriptions,
              AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag, UInt32(MemoryLayout.size(ofValue: tag)),
                                         &tag, &size) == noErr
        else {
            return descriptions(layout.layout).prefix(count).map(\.mChannelLabel)
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { raw.deallocate() }
        guard AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag, UInt32(MemoryLayout.size(ofValue: tag)),
                                     &tag, &size, raw) == noErr
        else { return (0..<count).map { kAudioChannelLabel_Discrete_0 + AudioChannelLabel($0) } }
        return descriptions(raw.assumingMemoryBound(to: AudioChannelLayout.self)).prefix(count).map(\.mChannelLabel)
    }

    private static func descriptions(_ layout: UnsafePointer<AudioChannelLayout>) -> [AudioChannelDescription] {
        let count = Int(layout.pointee.mNumberChannelDescriptions)
        let offset = MemoryLayout<AudioChannelLayout>.offset(of: \.mChannelDescriptions)!
        let base = (UnsafeRawPointer(layout) + offset).assumingMemoryBound(to: AudioChannelDescription.self)
        return (0..<count).map { base[$0] }
    }

    /// Copies a file's samples into a buffer of the processing format, exactly: Int32 samples are widened
    /// to Float64 when the target is Float64, and channels go where `channels` (see channelMap) says.
    private static func map(_ source: AVAudioPCMBuffer, into target: AVAudioPCMBuffer, channels: [Int?]) {
        let frames = Int(source.frameLength)
        target.frameLength = source.frameLength
        let from = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let to = UnsafeMutableAudioBufferListPointer(target.mutableAudioBufferList)
        let widens = source.format.commonFormat == .pcmFormatInt32 && target.format.commonFormat == .pcmFormatFloat64
        for channel in 0..<Int(target.format.channelCount) {
            guard let out = to[channel].mData else { continue }
            let bytes = Int(to[channel].mDataByteSize)
            guard channel < channels.count, let input = channels[channel], let data = from[input].mData else {
                memset(out, 0, bytes)
                continue
            }
            if widens {
                let samples = data.assumingMemoryBound(to: Int32.self)
                let doubles = out.assumingMemoryBound(to: Double.self)
                for i in 0..<frames { doubles[i] = Double(samples[i]) / 2_147_483_648 }
            } else {
                memcpy(out, data, min(bytes, Int(from[input].mDataByteSize)))
            }
        }
    }

    private func pad(_ frames: Int, buffer: AVAudioPCMBuffer, _ body: (AVAudioPCMBuffer) throws -> Void) throws {
        var remaining = frames
        while remaining > 0 {
            let n = min(Int(buffer.frameCapacity), remaining)
            buffer.frameLength = AVAudioFrameCount(n)
            for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                if let data = audioBuffer.mData { memset(data, 0, Int(audioBuffer.mDataByteSize)) }
            }
            remaining -= n
            try body(buffer)
        }
    }
}
