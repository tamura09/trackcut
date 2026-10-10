import Foundation

/// Moves tracks along when the files of a source are reordered, removed or added to
public enum FileArrangement {
    /// The tracks for the files in a new order. `order` lists, for each file of the new arrangement, its
    /// index in the old one, or nil for a file that is new; `newStarts` are where the new arrangement's
    /// files start.
    ///
    /// Each track moves with the file it starts in, so its audio stays the same. Where two files that were
    /// next to each other are no longer, a track running from one into the other is split at the start of
    /// the second file first (a track starting within `tolerance` seconds of it is moved onto it instead).
    /// Tracks of removed files are dropped, and each new file gets the track `newFileTrack` makes for it.
    /// Tracks may come out shorter than the editor allows (next to a very short file); see
    /// fitted(to:minLength:).
    public static func tracks(_ tracks: [Track], oldStarts: [Double], order: [Int?], newStarts: [Double],
                              tolerance: Double, newFileTrack: (Int) -> Track) -> [Track] {
        precondition(order.count == newStarts.count, "one start per file")
        var tracks = tracks.sorted { $0.start < $1.start }
        // Split where the files on both sides of a boundary are no longer together
        for j in oldStarts.indices.dropFirst() {
            if let p = order.firstIndex(of: j), p > 0, order[p - 1] == j - 1 { continue }
            let boundary = oldStarts[j]
            // The track at 0 stays there, even next to a file shorter than the tolerance
            if let i = tracks.indices.first(where: {
                abs(tracks[$0].start - boundary) <= tolerance && ($0 > 0 || tracks[$0].start == boundary)
            }) {
                tracks[i].start = boundary
                continue
            }
            guard let i = tracks.firstIndex(where: { $0.start > boundary }) ?? (tracks.isEmpty ? nil : tracks.endIndex),
                  i > 0
            else { continue }
            // As when splitting by hand: the fade-out stays at the end of the range, in the new part
            // It is still part of the same track, so it keeps that track's artist and whether it is exported
            var part = Track(start: boundary, artist: tracks[i - 1].artist, isEnabled: tracks[i - 1].isEnabled)
            part.fadeOut = tracks[i - 1].fadeOut
            tracks[i - 1].fadeOut = Fade(curve: part.fadeOut.curve)
            tracks.insert(part, at: i)
        }
        // Each track's file and its offset into it
        let placed = tracks.map { track -> (file: Int, offset: Double, track: Track) in
            let file = oldStarts.lastIndex { $0 <= track.start + 1e-9 } ?? 0
            return (file, track.start - oldStarts[file], track)
        }
        var result: [Track] = []
        for (p, slot) in order.enumerated() {
            guard let file = slot else {
                var track = newFileTrack(p)
                track.start = newStarts[p]
                result.append(track)
                continue
            }
            for item in placed where item.file == file {
                var track = item.track
                track.start = newStarts[p] + item.offset
                result.append(track)
            }
        }
        return result
    }
}
