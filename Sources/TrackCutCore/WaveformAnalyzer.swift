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

public enum WaveformAnalyzer {
    public static func analyze(url: URL, progress: (Double) -> Void = { _ in }) throws -> WaveformPeaks {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channels = Int(format.channelCount)
        let totalFrames = file.length
        let binFrames = max(1, Int(sampleRate / 500))
        let chunkFrames = AVAudioFrameCount(binFrames * 2048)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw AudioError.bufferAllocationFailed
        }

        let expectedBins = Int(totalFrames / Int64(binFrames)) + 1
        var mins = [Float](); mins.reserveCapacity(expectedBins)
        var maxs = [Float](); maxs.reserveCapacity(expectedBins)
        var rms = [Float](); rms.reserveCapacity(expectedBins)
        var readFrames: Int64 = 0

        while file.framePosition < totalFrames {
            if Task.isCancelled { throw CancellationError() }
            try file.read(into: buffer, frameCount: chunkFrames)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let data = buffer.floatChannelData else { throw AudioError.unsupportedFormat }

            var i = 0
            while i < n {
                let end = min(i + binFrames, n)
                var lo: Float = 0, hi: Float = 0, sum: Float = 0
                for ch in 0..<channels {
                    let p = data[ch]
                    for j in i..<end {
                        let v = p[j]
                        if v < lo { lo = v }
                        if v > hi { hi = v }
                        sum += v * v
                    }
                }
                mins.append(lo)
                maxs.append(hi)
                rms.append(sqrt(sum / Float((end - i) * channels)))
                i = end
            }
            readFrames += Int64(n)
            progress(min(1, Double(readFrames) / Double(max(totalFrames, 1))))
        }

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
    case unsupportedSampleRateForAAC(Double)
    case exportSessionUnavailable

    public var errorDescription: String? {
        switch self {
        case .bufferAllocationFailed: "オーディオバッファを確保できませんでした。"
        case .unsupportedFormat: "このオーディオ形式には対応していません。"
        case .unsupportedSampleRateForAAC(let rate): "AAC は \(Int(rate)) Hz に対応していません（48 kHz 以下のみ）。"
        case .exportSessionUnavailable: "書き出しセッションを作成できませんでした。"
        }
    }
}
