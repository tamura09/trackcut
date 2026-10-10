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
    /// Channel count of the timeline: the highest of the files. Mono files are copied to every channel.
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

    /// Whether some file differs from the timeline's format and has to be converted as it is read. When
    /// false, every file's samples are read as they are.
    var needsConversion: Bool {
        files.contains { $0.info.sampleRate != sampleRate || $0.info.channelCount != channelCount }
    }

    /// The format a "same as source" export follows: the first file's codec, with the highest bit depth
    /// of the lossless files (floating point if any of them is) and the timeline's sample rate and channel
    /// count
    public var info: SourceAudioInfo {
        let first = files[0].info
        guard files.count > 1 else { return first }
        let lossless = files.filter(\.info.isLossless)
        let bitDepth = lossless.map(\.info.bitDepth).max() ?? first.bitDepth
        // The highest bit rate of the AAC files: what re-encoded AAC is written at by default
        let aacBitRate = files.filter(\.info.isAAC).compactMap(\.info.bitRate).max()
        return SourceAudioInfo(formatID: first.formatID, bitDepth: bitDepth,
                               isFloat: lossless.contains(where: \.info.isFloat),
                               sampleRate: sampleRate, channelCount: channelCount, duration: duration, bitRate: aacBitRate,
                               fileSize: files.compactMap(\.info.fileSize).reduce(0, +))
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
            if file.info.sampleRate == source.sampleRate && file.info.channelCount == source.channelCount {
                try readDirectly(file, local, buffer: buffer, body)
            } else {
                try readConverted(file, local, buffer: buffer, body)
            }
        }
    }

    private func readDirectly(_ file: AudioSource.File, _ range: Range<AVAudioFramePosition>,
                              buffer: AVAudioPCMBuffer, _ body: (AVAudioPCMBuffer) throws -> Void) throws {
        let input = try AVAudioFile(forReading: file.url, commonFormat: processingFormat.commonFormat, interleaved: false)
        var delivered = 0
        if range.lowerBound < input.length {
            input.framePosition = range.lowerBound
            var remaining = min(range.count, Int(input.length - range.lowerBound))
            while remaining > 0 {
                try Task.checkCancellation()
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(Int(buffer.frameCapacity), remaining)))
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
