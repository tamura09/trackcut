import AVFoundation

/// Downsampled waveform for drawing and silence detection. One bin is about 2 ms.
public struct WaveformPeaks: Sendable {
    public let sampleRate: Double
    public let binFrames: Int
    public let totalFrames: Int64
    /// Minimum / maximum / RMS across all channels
    public let mins: [Float]
    public let maxs: [Float]
    public let rms: [Float]

    public var count: Int { mins.count }
    public var binDuration: Double { Double(binFrames) / sampleRate }
    public var duration: Double { Double(totalFrames) / sampleRate }
}

extension WaveformPeaks {
    /// The peaks of each file of `source` (analyzed on their own, at their own rate) placed where the files
    /// are on its timeline. Joining is quick, so a source whose files are rearranged needs no new analysis.
    /// Bins that do not line up with the timeline's are combined from the file bins they overlap, which
    /// is exact to within one bin.
    public static func joined(_ parts: [WaveformPeaks], in source: AudioSource) -> WaveformPeaks {
        precondition(parts.count == source.files.count, "one set of peaks per file")
        let sampleRate = source.sampleRate
        let binFrames = max(1, Int(sampleRate / 500))
        let totalFrames = source.totalFrames
        let binCount = Int((totalFrames + Int64(binFrames) - 1) / Int64(binFrames))
        var mins = [Float](repeating: 0, count: binCount)
        var maxs = [Float](repeating: 0, count: binCount)
        var squares = [Float](repeating: 0, count: binCount)
        /// Frames that have gone into each bin, for combining bins that two files share
        var weights = [Float](repeating: 0, count: binCount)

        func add(_ j: Int, lo: Float, hi: Float, meanSquare: Float, frames: Float) {
            if weights[j] == 0 {
                mins[j] = lo
                maxs[j] = hi
            } else {
                mins[j] = min(mins[j], lo)
                maxs[j] = max(maxs[j], hi)
            }
            squares[j] += meanSquare * frames
            weights[j] += frames
        }

        for (file, part) in zip(source.files, parts) where part.count > 0 {
            let start = Int(file.startFrame), end = Int(file.startFrame + file.frameCount)
            let firstBin = start / binFrames
            let lastBin = min(binCount, (end + binFrames - 1) / binFrames)
            if part.sampleRate == sampleRate, part.binFrames == binFrames, start % binFrames == 0 {
                // Lined up: the file's bins are the timeline's
                for j in firstBin..<lastBin where j - firstBin < part.count {
                    let k = j - firstBin
                    let frames = Float(min(binFrames, end - j * binFrames))
                    add(j, lo: part.mins[k], hi: part.maxs[k], meanSquare: part.rms[k] * part.rms[k], frames: frames)
                }
                continue
            }
            let fileBinDuration = part.binDuration
            for j in firstBin..<lastBin {
                let from = max(start, j * binFrames), to = min(end, (j + 1) * binFrames)
                guard to > from else { continue }
                // The bin's stretch in seconds into the file, and the file bins covering it
                let t0 = Double(from - start) / sampleRate, t1 = Double(to - start) / sampleRate
                let k0 = min(part.count - 1, Int(t0 / fileBinDuration))
                let k1 = min(part.count, max(k0 + 1, Int((t1 / fileBinDuration).rounded(.up))))
                var lo = part.mins[k0], hi = part.maxs[k0], sum: Float = 0
                for k in k0..<k1 {
                    lo = min(lo, part.mins[k])
                    hi = max(hi, part.maxs[k])
                    sum += part.rms[k] * part.rms[k]
                }
                add(j, lo: lo, hi: hi, meanSquare: sum / Float(k1 - k0), frames: Float(to - from))
            }
        }
        let rms = zip(squares, weights).map { $1 > 0 ? sqrt($0 / $1) : 0 }
        return WaveformPeaks(sampleRate: sampleRate, binFrames: binFrames, totalFrames: totalFrames,
                             mins: mins, maxs: maxs, rms: rms)
    }
}

public enum WaveformAnalyzer {
    /// Analyzes one file at its own sample rate
    public static func analyze(url: URL, progress: (Double) -> Void = { _ in }) throws -> WaveformPeaks {
        try analyzeTimeline(AudioSource(url: url), progress: progress)
    }

    /// Analyzes each file of `source` and joins the results (see WaveformPeaks.joined)
    public static func analyze(_ source: AudioSource, progress: (Double) -> Void = { _ in }) throws -> WaveformPeaks {
        let total = max(source.duration, 0.001)
        var done = 0.0
        var parts: [WaveformPeaks] = []
        for file in source.files {
            let length = file.info.duration
            parts.append(try analyze(url: file.url) { progress((done + $0 * length) / total) })
            done += length
        }
        return .joined(parts, in: source)
    }

    private static func analyzeTimeline(_ source: AudioSource, progress: (Double) -> Void) throws -> WaveformPeaks {
        let reader = try SourceReader(source: source, commonFormat: .pcmFormatFloat32)
        let sampleRate = source.sampleRate
        let channels = source.channelCount
        let totalFrames = source.totalFrames
        let binFrames = max(1, Int(sampleRate / 500))

        let expectedBins = Int(totalFrames / Int64(binFrames)) + 1
        var mins = [Float](); mins.reserveCapacity(expectedBins)
        var maxs = [Float](); maxs.reserveCapacity(expectedBins)
        var rms = [Float](); rms.reserveCapacity(expectedBins)
        var readFrames: Int64 = 0
        // Bins span buffer and file boundaries, so the running bin is carried between buffers
        var lo: Float = 0, hi: Float = 0, sum: Float = 0, binCount = 0

        func closeBin() {
            mins.append(lo)
            maxs.append(hi)
            rms.append(sqrt(sum / Float(binCount * channels)))
            lo = 0; hi = 0; sum = 0; binCount = 0
        }

        try reader.read(0..<totalFrames, chunkFrames: AVAudioFrameCount(binFrames * 2048)) { buffer in
            let n = Int(buffer.frameLength)
            guard let data = buffer.floatChannelData else { throw AudioError.unsupportedFormat }
            var i = 0
            while i < n {
                let end = min(i + binFrames - binCount, n)
                for ch in 0..<channels {
                    let p = data[ch]
                    for j in i..<end {
                        let v = p[j]
                        if v < lo { lo = v }
                        if v > hi { hi = v }
                        sum += v * v
                    }
                }
                binCount += end - i
                if binCount == binFrames { closeBin() }
                i = end
            }
            readFrames += Int64(n)
            progress(min(1, Double(readFrames) / Double(max(totalFrames, 1))))
        }
        if binCount > 0 { closeBin() }

        return WaveformPeaks(sampleRate: sampleRate, binFrames: binFrames, totalFrames: readFrames,
                             mins: mins, maxs: maxs, rms: rms)
    }
}

public enum SilenceDetector {
    /// Silent gaps between tracks (silence touching the start or end of the file is ignored)
    public static func silences(in peaks: WaveformPeaks, thresholdDB: Double, minDuration: Double) -> [ClosedRange<Double>] {
        let threshold = Float(pow(10, thresholdDB / 20))
        let minBins = max(1, Int(minDuration / peaks.binDuration))
        var result: [ClosedRange<Double>] = []
        var runStart: Int?

        peaks.rms.withUnsafeBufferPointer { rms in
            for i in 0...rms.count {
                let silent = i < rms.count && rms[i] < threshold
                if silent {
                    if runStart == nil { runStart = i }
                } else if let s = runStart {
                    runStart = nil
                    let touchesEdge = s == 0 || i == rms.count
                    if !touchesEdge && i - s >= minBins {
                        result.append(Double(s) * peaks.binDuration ... Double(i) * peaks.binDuration)
                    }
                }
            }
        }
        return result
    }

    /// Uses the middle of each silent gap as a split point
    public static func splitPoints(in peaks: WaveformPeaks, thresholdDB: Double, minDuration: Double) -> [Double] {
        silences(in: peaks, thresholdDB: thresholdDB, minDuration: minDuration)
            .map { ($0.lowerBound + $0.upperBound) / 2 }
    }
}

public enum AudioError: LocalizedError {
    case bufferAllocationFailed
    case unsupportedFormat
    case exportSessionUnavailable
    case outputIsSource(String)

    public var errorDescription: String? {
        switch self {
        case .bufferAllocationFailed: String(localized: "Could not allocate an audio buffer.")
        case .unsupportedFormat: String(localized: "This audio format is not supported.")
        case .exportSessionUnavailable: String(localized: "Could not create an export session.")
        case .outputIsSource(let name):
            String(localized: "The export would overwrite the source file “\(name)”. Choose another folder.")
        }
    }
}
