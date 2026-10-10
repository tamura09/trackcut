import Foundation

/// Shape of a fade's gain curve
public enum FadeCurve: String, CaseIterable, Identifiable, Sendable {
    case linear, equalPower, sCurve, exponential

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .linear: String(localized: "Linear")
        case .equalPower: String(localized: "Equal Power")
        case .sCurve: String(localized: "S-Curve")
        case .exponential: String(localized: "Exponential")
        }
    }

    /// Gain of a fade-in at `progress` (0 where the fade starts, 1 where it ends). A fade-out uses the same
    /// curve mirrored in time, so it starts at 1 and ends at 0.
    public func gain(_ progress: Double) -> Double {
        let x = min(max(progress, 0), 1)
        switch self {
        case .linear: return x
        case .equalPower: return sin(x * .pi / 2)
        case .sCurve: return (1 - cos(x * .pi)) / 2
        case .exponential: return x * x
        }
    }
}

/// A fade at the start (fade-in) or the end (fade-out) of a track. A duration of 0 means no fade.
public struct Fade: Hashable, Sendable {
    public var duration: Double
    public var curve: FadeCurve

    public init(duration: Double = 0, curve: FadeCurve = .linear) {
        self.duration = duration
        self.curve = curve
    }

    public var isEnabled: Bool { duration > 0 }
}

/// Which end of a track a fade belongs to
public enum FadeEdge: Sendable {
    /// Fade-in at the start of the track
    case start
    /// Fade-out at the end of the track
    case end
}

/// Gain over one segment with a fade at each end
public struct FadeEnvelope: Sendable, Equatable {
    public let length: Double
    /// The fades as they are applied. When the two together are longer than the segment, both are
    /// shortened in proportion so they meet instead of overlapping.
    public let fadeIn: Fade
    public let fadeOut: Fade

    public init(length: Double, fadeIn: Fade, fadeOut: Fade) {
        let length = max(length, 0)
        var inDuration = max(fadeIn.duration, 0)
        var outDuration = max(fadeOut.duration, 0)
        if inDuration + outDuration > length {
            let scale = length / (inDuration + outDuration)
            inDuration *= scale
            outDuration *= scale
        }
        self.length = length
        self.fadeIn = Fade(duration: inDuration, curve: fadeIn.curve)
        self.fadeOut = Fade(duration: outDuration, curve: fadeOut.curve)
    }

    public var isFlat: Bool { !fadeIn.isEnabled && !fadeOut.isEnabled }

    /// Gain at `time` seconds from the start of the segment
    public func gain(at time: Double) -> Double {
        var gain = 1.0
        if fadeIn.isEnabled, time < fadeIn.duration {
            gain *= fadeIn.curve.gain(time / fadeIn.duration)
        }
        if fadeOut.isEnabled, time > length - fadeOut.duration {
            gain *= fadeOut.curve.gain((length - time) / fadeOut.duration)
        }
        return gain
    }
}
