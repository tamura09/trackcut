import Foundation

/// An editing session saved to a file: the source audio files, the tracks and the album tags. The audio
/// itself is not copied into the project.
public struct Project: Codable, Equatable, Sendable {
    public static let fileExtension = "trackcut"
    /// Version of the file format. Files of a later version are refused rather than read in part.
    public static let currentVersion = 1

    /// Where an audio file of the source is
    public struct SourceFile: Codable, Equatable, Sendable {
        /// Absolute path
        public var path: String
        /// Path relative to the folder of the project, so the two can be moved together. nil when there is
        /// no relative path (e.g. on another volume).
        public var relativePath: String?

        /// Where the file may be, most likely first: next to the project as it was when it was saved, then
        /// at its absolute path
        public func candidates(projectURL: URL) -> [URL] {
            var candidates: [URL] = []
            if let relativePath {
                candidates.append(URL(fileURLWithPath: relativePath,
                                      relativeTo: projectURL.deletingLastPathComponent()).standardizedFileURL)
            }
            candidates.append(URL(fileURLWithPath: path))
            return candidates
        }
    }

    public var version = Project.currentVersion
    /// The audio files, played one after another as one timeline
    public var sources: [SourceFile]
    /// Tags shared by the whole album
    public var album: AudioTags
    public var tracks: [Track]

    public init(sources: [URL], savedAt projectURL: URL, album: AudioTags, tracks: [Track]) {
        self.sources = sources.map {
            SourceFile(path: $0.standardizedFileURL.path,
                       relativePath: Self.relativePath(of: $0, from: projectURL.deletingLastPathComponent()))
        }
        self.album = album
        self.tracks = tracks
    }

    public init(contentsOf url: URL) throws {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        // Read the version on its own first, so a newer file gets a clear error instead of a decoding one
        struct Header: Decodable { var version: Int }
        guard let version = try? decoder.decode(Header.self, from: data).version else {
            throw ProjectError.unreadable
        }
        guard version <= Self.currentVersion else { throw ProjectError.newerVersion }
        do {
            self = try decoder.decode(Project.self, from: data)
        } catch {
            throw ProjectError.unreadable
        }
        guard !sources.isEmpty else { throw ProjectError.unreadable }
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The tracks, made to fit a source of `duration` seconds (see fitted(to:minLength:)). A hand-edited
    /// file, or a source replaced by a shorter one, could break the rules the editor relies on, such as
    /// distinct IDs.
    public func tracks(fitting duration: Double, minLength: Double) -> [Track] {
        tracks.fitted(to: duration, minLength: minLength)
    }

    private static func relativePath(of file: URL, from directory: URL) -> String? {
        let fileParts = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let dirParts = directory.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let common = zip(fileParts, dirParts).prefix { $0 == $1 }.count
        // Paths on different volumes (with only "/" or "/Volumes" in common) have no useful relative path
        guard common > 1, !(fileParts[1] == "Volumes" && common < 3) else { return nil }
        let ups = Array(repeating: "..", count: dirParts.count - common)
        return (ups + fileParts[common...]).joined(separator: "/")
    }
}

public enum ProjectError: LocalizedError {
    case unreadable
    case newerVersion

    public var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "The project file is damaged or not a TrackCut project.")
        case .newerVersion: String(localized: "The project was saved by a newer version of TrackCut. Update TrackCut to open it.")
        }
    }
}
