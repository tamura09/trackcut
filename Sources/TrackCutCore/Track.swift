import Foundation

/// One track. It ends where the next track starts (the last track ends at the end of the file).
public struct Track: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var start: Double
    public var title: String
    /// Falls back to the album's artist when empty
    public var artist: String
    public var isEnabled: Bool
    /// Fade at the start of the track
    public var fadeIn: Fade
    /// Fade at the end of the track
    public var fadeOut: Fade

    public init(id: UUID = UUID(), start: Double, title: String = "", artist: String = "", isEnabled: Bool = true,
                fadeIn: Fade = Fade(), fadeOut: Fade = Fade()) {
        self.id = id
        self.start = start
        self.title = title
        self.artist = artist
        self.isEnabled = isEnabled
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }
}

extension Track {
    public func fade(_ edge: FadeEdge) -> Fade {
        edge == .start ? fadeIn : fadeOut
    }

    /// Sets the length of one fade, limited so the two fades do not overlap. The other fade is first set
    /// to the length it is applied with (see FadeEnvelope), so editing one fade never changes the other.
    public mutating func setFadeDuration(_ edge: FadeEdge, _ duration: Double, trackLength: Double) {
        let envelope = FadeEnvelope(length: trackLength, fadeIn: fadeIn, fadeOut: fadeOut)
        fadeIn.duration = envelope.fadeIn.duration
        fadeOut.duration = envelope.fadeOut.duration
        let other = edge == .start ? fadeOut.duration : fadeIn.duration
        let clamped = min(max(duration, 0), max(envelope.length - other, 0))
        switch edge {
        case .start: fadeIn.duration = clamped
        case .end: fadeOut.duration = clamped
        }
    }
}

extension Array where Element == Track {
    /// The tracks made to fit a source of `duration` seconds: in order, the first starting at 0, each at
    /// least `minLength` long, and with distinct IDs. A track too short to keep (e.g. one for a file of a
    /// few milliseconds) is dropped and the track after it takes over its start; one too close to the end
    /// is dropped and the track before it runs to the end.
    public func fitted(to duration: Double, minLength: Double) -> [Track] {
        var result: [Track] = []
        var ids = Set<Track.ID>()
        // Starts outside the source (a hand-edited project) are moved into it first
        let clamped = map { track in
            var track = track
            track.start = Swift.min(Swift.max(track.start, 0), Swift.max(duration, 0))
            return track
        }
        for var track in clamped.sorted(by: { $0.start < $1.start }) {
            if !ids.insert(track.id).inserted {
                track = Track(start: track.start, title: track.title, artist: track.artist, isEnabled: track.isEnabled,
                              fadeIn: track.fadeIn, fadeOut: track.fadeOut)
                ids.insert(track.id)
            }
            if let last = result.last, track.start - last.start < minLength {
                track.start = last.start
                result.removeLast()
            }
            result.append(track)
        }
        while result.count > 1, result[result.count - 1].start > duration - minLength {
            let last = result.removeLast()
            result[result.count - 1].fadeOut = last.fadeOut
        }
        guard !result.isEmpty else { return [Track(start: 0)] }
        result[0].start = 0
        return result
    }

    /// The tracks split at `times` instead. Titles, artists, the export selection and IDs are carried over by
    /// position in the list. Fades stay where they are in the file: the fade-in at the start and the
    /// fade-out at the end of the file, and the fades on both sides of a split point that is kept (one
    /// within `tolerance` seconds of a new one). Other fades are dropped.
    public func replacingSplits(with times: [Double], tolerance: Double) -> [Track] {
        guard let first, let last else { return [] }
        var result = ([0] + times.sorted()).enumerated().map { i, start in
            guard i < count else { return Track(start: start) }
            var track = self[i]
            track.start = start
            track.fadeIn = Fade()
            track.fadeOut = Fade()
            return track
        }
        result[0].fadeIn = first.fadeIn
        result[result.count - 1].fadeOut = last.fadeOut
        for j in indices.dropFirst() {
            guard let k = result.indices.dropFirst().first(where: { abs(result[$0].start - self[j].start) <= tolerance })
            else { continue }
            result[k].fadeIn = self[j].fadeIn
            result[k - 1].fadeOut = self[j - 1].fadeOut
        }
        return result
    }
}

public enum TimeFormat {
    /// e.g. 3:05.42 / 1:02:03.50
    public static func string(_ seconds: Double, fractionDigits: Int = 2) -> String {
        // Round the whole value first and split it with integers, so that rounding up
        // (59.996 -> 60.00) carries into the minutes and hours instead of showing 0:60.00.
        var scale = 1
        for _ in 0..<fractionDigits { scale *= 10 }
        let units = Int((max(0, seconds) * Double(scale)).rounded())
        let totalSeconds = units / scale
        let hours = totalSeconds / 3600
        let minutes = totalSeconds % 3600 / 60
        var secString = String(format: "%02d", totalSeconds % 60)
        if fractionDigits > 0 {
            secString += "." + String(format: "%0\(fractionDigits)d", units % scale)
        }
        if hours > 0 {
            return String(format: "%d:%02d:", hours, minutes) + secString
        }
        return "\(minutes):" + secString
    }
}

public enum FileIdentity {
    /// Whether two URLs point to the same file on disk. Unlike comparing URLs, this sees through
    /// case-insensitive volumes, Unicode normalization and symbolic links. False if either file is missing.
    public static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let idA = try? a.resourceValues(forKeys: key).fileResourceIdentifier,
              let idB = try? b.resourceValues(forKeys: key).fileResourceIdentifier
        else { return false }
        return idA.isEqual(idB)
    }
}

public enum FileNameSanitizer {
    public static func sanitize(_ name: String) -> String {
        var result = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix(".") { result = "_" + result.dropFirst() }
        return result.isEmpty ? "untitled" : result
    }
}
