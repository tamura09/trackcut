import Foundation

/// One track. It ends where the next track starts (the last track ends at the end of the file).
public struct Track: Identifiable, Hashable, Sendable {
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
