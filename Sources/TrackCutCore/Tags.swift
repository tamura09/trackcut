import AVFoundation

/// Tags to write or read. Empty strings and nil values are not written.
public struct AudioTags: Sendable, Equatable {
    public var title = ""
    public var artist = ""
    public var album = ""
    public var albumArtist = ""
    public var date = ""
    public var genre = ""
    public var trackNumber: Int?
    public var trackTotal: Int?

    public init(title: String = "", artist: String = "", album: String = "", albumArtist: String = "",
                date: String = "", genre: String = "", trackNumber: Int? = nil, trackTotal: Int? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.date = date
        self.genre = genre
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
    }
}

private func clean(_ s: String) -> String? {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

public enum TagWriter {
    /// Writes tags to a freshly exported file. The format is chosen by the file extension.
    public static func write(_ tags: AudioTags, to url: URL) async throws {
        switch url.pathExtension.lowercased() {
        case "flac": try FLACTags.write(tags, to: url)
        case "wav": try WAVTags.write(tags, to: url)
        case "m4a": try await M4ATags.write(tags, to: url)
        default: break
        }
    }
}

public enum TagReader {
    /// Returns empty tags when the file cannot be read
    public static func read(from url: URL) async -> AudioTags {
        switch url.pathExtension.lowercased() {
        case "flac": (try? FLACTags.read(from: url)) ?? AudioTags()
        case "wav": (try? WAVTags.read(from: url)) ?? AudioTags()
        case "m4a": (try? await M4ATags.read(from: url)) ?? AudioTags()
        default: AudioTags()
        }
    }
}

public enum TagError: LocalizedError {
    case invalidFile(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFile(let detail): String(localized: "Could not write the tags: \(detail)")
        }
    }
}

// MARK: - Byte helpers

private extension Data {
    mutating func appendLE32(_ value: Int) {
        let v = UInt32(value)
        append(contentsOf: [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)])
    }

    func le32(at offset: Int) -> Int {
        let i = startIndex + offset
        return Int(self[i]) | Int(self[i + 1]) << 8 | Int(self[i + 2]) << 16 | Int(self[i + 3]) << 24
    }

    func ascii(at offset: Int, count: Int) -> String {
        let i = startIndex + offset
        return String(decoding: self[i..<i + count], as: UTF8.self)
    }
}

/// Writes to a temporary file, then replaces the original
private func replaceFile(_ url: URL, writing body: (FileHandle) throws -> Void) throws {
    let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
    guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
        throw TagError.invalidFile(String(localized: "Cannot create a temporary file"))
    }
    do {
        let handle = try FileHandle(forWritingTo: temp)
        try body(handle)
        try handle.close()
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    } catch {
        try? FileManager.default.removeItem(at: temp)
        throw error
    }
}

// MARK: - FLAC (Vorbis comment)

enum FLACTags {
    private struct Block {
        var type: UInt8
        var body: Data
    }

    private static let vorbisCommentType: UInt8 = 4
    private static let paddingType: UInt8 = 1

    static func fields(_ tags: AudioTags) -> [(String, String)] {
        [
            ("TITLE", tags.title), ("ARTIST", tags.artist), ("ALBUM", tags.album),
            ("ALBUMARTIST", tags.albumArtist), ("DATE", tags.date), ("GENRE", tags.genre),
            ("TRACKNUMBER", tags.trackNumber.map(String.init) ?? ""),
            ("TRACKTOTAL", tags.trackTotal.map(String.init) ?? ""),
        ].compactMap { key, value in clean(value).map { (key, $0) } }
    }

    static func write(_ tags: AudioTags, to url: URL) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let (blocks, audioOffset) = try parse(data)

        var comment = Data()
        let vendor = Data("TrackCut".utf8)
        comment.appendLE32(vendor.count)
        comment.append(vendor)
        let fields = fields(tags)
        comment.appendLE32(fields.count)
        for (key, value) in fields {
            let entry = Data("\(key)=\(value)".utf8)
            comment.appendLE32(entry.count)
            comment.append(entry)
        }

        // Drop any existing Vorbis comment / padding and insert the new comment right after STREAMINFO
        var newBlocks = blocks.filter { $0.type != vorbisCommentType && $0.type != paddingType }
        newBlocks.insert(Block(type: vorbisCommentType, body: comment), at: min(1, newBlocks.count))

        var header = Data("fLaC".utf8)
        for (i, block) in newBlocks.enumerated() {
            let isLast = i == newBlocks.count - 1
            let length = block.body.count
            guard length < 1 << 24 else { throw TagError.invalidFile(String(localized: "The metadata is too large")) }
            header.append(block.type | (isLast ? 0x80 : 0))
            header.append(contentsOf: [UInt8(length >> 16 & 0xFF), UInt8(length >> 8 & 0xFF), UInt8(length & 0xFF)])
            header.append(block.body)
        }

        try replaceFile(url) { handle in
            try handle.write(contentsOf: header)
            try handle.write(contentsOf: data[(data.startIndex + audioOffset)...])
        }
    }

    static func read(from url: URL) throws -> AudioTags {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        var tags = AudioTags()
        guard let block = try parse(data).blocks.first(where: { $0.type == vorbisCommentType }) else { return tags }
        let body = block.body
        guard body.count >= 4 else { return tags }
        var offset = 4 + body.le32(at: 0)
        guard offset + 4 <= body.count else { return tags }
        let count = body.le32(at: offset)
        offset += 4
        for _ in 0..<count {
            guard offset + 4 <= body.count else { break }
            let length = body.le32(at: offset)
            offset += 4
            guard offset + length <= body.count else { break }
            let entry = String(decoding: body[(body.startIndex + offset)..<(body.startIndex + offset + length)], as: UTF8.self)
            offset += length
            guard let eq = entry.firstIndex(of: "=") else { continue }
            let value = String(entry[entry.index(after: eq)...])
            switch entry[..<eq].uppercased() {
            case "TITLE": tags.title = value
            case "ARTIST": tags.artist = value
            case "ALBUM": tags.album = value
            case "ALBUMARTIST", "ALBUM ARTIST": tags.albumArtist = value
            case "DATE", "YEAR": tags.date = value
            case "GENRE": tags.genre = value
            case "TRACKNUMBER":
                // Also accepts the "3/12" form
                let parts = value.split(separator: "/")
                tags.trackNumber = parts.first.flatMap { Int($0) }
                if parts.count > 1 { tags.trackTotal = Int(parts[1]) }
            case "TRACKTOTAL", "TOTALTRACKS": tags.trackTotal = Int(value)
            default: break
            }
        }
        return tags
    }

    /// The metadata blocks and the offset where the audio frames start
    private static func parse(_ data: Data) throws -> (blocks: [Block], audioOffset: Int) {
        var offset = 0
        // Skip a leading ID3v2 tag if present
        if data.count >= 10, data.ascii(at: 0, count: 3) == "ID3" {
            let s = data.startIndex
            let size = Int(data[s + 6]) << 21 | Int(data[s + 7]) << 14 | Int(data[s + 8]) << 7 | Int(data[s + 9])
            offset = 10 + size
        }
        guard data.count >= offset + 4, data.ascii(at: offset, count: 4) == "fLaC" else {
            throw TagError.invalidFile(String(localized: "Not a FLAC file"))
        }
        offset += 4

        var blocks: [Block] = []
        while true {
            guard offset + 4 <= data.count else { throw TagError.invalidFile(String(localized: "The FLAC metadata is corrupt")) }
            let s = data.startIndex + offset
            let head = data[s]
            let length = Int(data[s + 1]) << 16 | Int(data[s + 2]) << 8 | Int(data[s + 3])
            guard offset + 4 + length <= data.count else { throw TagError.invalidFile(String(localized: "The FLAC metadata is corrupt")) }
            blocks.append(Block(type: head & 0x7F, body: Data(data[(s + 4)..<(s + 4 + length)])))
            offset += 4 + length
            if head & 0x80 != 0 { break }
        }
        return (blocks, offset)
    }
}

// MARK: - WAV (LIST/INFO)

enum WAVTags {
    // There is no standard INFO field for the album artist
    static func fields(_ tags: AudioTags) -> [(String, String)] {
        [
            ("INAM", tags.title), ("IART", tags.artist), ("IPRD", tags.album),
            ("ICRD", tags.date), ("IGNR", tags.genre),
            ("ITRK", tags.trackNumber.map(String.init) ?? ""),
        ].compactMap { id, value in clean(value).map { (id, $0) } }
    }

    /// For freshly exported files. Appends a LIST/INFO chunk and updates the RIFF size.
    static func write(_ tags: AudioTags, to url: URL) throws {
        let fields = fields(tags)
        guard !fields.isEmpty else { return }

        var info = Data("INFO".utf8)
        for (id, value) in fields {
            var v = Data(value.utf8)
            v.append(0)
            info.append(Data(id.utf8))
            info.appendLE32(v.count)
            info.append(v)
            if v.count % 2 == 1 { info.append(0) }
        }
        var chunk = Data("LIST".utf8)
        chunk.appendLE32(info.count)
        chunk.append(info)

        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 12), header.count == 12,
              header.ascii(at: 0, count: 4) == "RIFF", header.ascii(at: 8, count: 4) == "WAVE"
        else {
            // RF64 (over 4 GB) and other variants are not supported
            throw TagError.invalidFile(String(localized: "Not a RIFF/WAVE file"))
        }
        var end = Int(try handle.seekToEnd())
        if end % 2 == 1 {
            try handle.write(contentsOf: Data([0]))
            end += 1
        }
        guard end + chunk.count - 8 <= Int(UInt32.max) else { throw TagError.invalidFile(String(localized: "The file is too large")) }
        try handle.write(contentsOf: chunk)
        try handle.seek(toOffset: 4)
        var size = Data()
        size.appendLE32(end + chunk.count - 8)
        try handle.write(contentsOf: size)
    }

    static func read(from url: URL) throws -> AudioTags {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var tags = AudioTags()
        guard let header = try handle.read(upToCount: 12), header.count == 12,
              header.ascii(at: 0, count: 4) == "RIFF" else { return tags }
        var offset: UInt64 = 12
        let fileSize = try handle.seekToEnd()

        while offset + 8 <= fileSize {
            try handle.seek(toOffset: offset)
            guard let chunkHeader = try handle.read(upToCount: 8), chunkHeader.count == 8 else { break }
            let id = chunkHeader.ascii(at: 0, count: 4)
            let size = chunkHeader.le32(at: 4)
            // read(upToCount:) returns less than size when the file is truncated.
            if id == "LIST", size >= 4, size < 1 << 20, let body = try handle.read(upToCount: size),
               body.count >= 4, body.ascii(at: 0, count: 4) == "INFO" {
                var p = 4
                while p + 8 <= body.count {
                    let subID = body.ascii(at: p, count: 4)
                    let subSize = body.le32(at: p + 4)
                    guard p + 8 + subSize <= body.count else { break }
                    let raw = body[(body.startIndex + p + 8)..<(body.startIndex + p + 8 + subSize)]
                    let value = String(decoding: raw, as: UTF8.self)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
                    switch subID {
                    case "INAM": tags.title = value
                    case "IART": tags.artist = value
                    case "IPRD": tags.album = value
                    case "ICRD": tags.date = value
                    case "IGNR": tags.genre = value
                    case "ITRK": tags.trackNumber = Int(value)
                    default: break
                    }
                    p += 8 + subSize + (subSize & 1)
                }
            }
            offset += 8 + UInt64(size) + UInt64(size & 1)
        }
        return tags
    }
}

// MARK: - M4A (iTunes metadata)

enum M4ATags {
    static func metadataItems(_ tags: AudioTags) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        func add(_ identifier: AVMetadataIdentifier, _ value: String) {
            guard let value = clean(value) else { return }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            items.append(item)
        }
        add(.iTunesMetadataSongName, tags.title)
        add(.iTunesMetadataArtist, tags.artist)
        add(.iTunesMetadataAlbum, tags.album)
        add(.iTunesMetadataAlbumArtist, tags.albumArtist)
        add(.iTunesMetadataReleaseDate, tags.date)
        add(.iTunesMetadataUserGenre, tags.genre)

        if let number = tags.trackNumber {
            // trkn: [0, 0, number (2 bytes BE), total (2 bytes BE), 0, 0]
            let total = tags.trackTotal ?? 0
            let bytes: [UInt8] = [0, 0, UInt8(number >> 8 & 0xFF), UInt8(number & 0xFF),
                                  UInt8(total >> 8 & 0xFF), UInt8(total & 0xFF), 0, 0]
            let item = AVMutableMetadataItem()
            item.identifier = .iTunesMetadataTrackNumber
            item.value = Data(bytes) as NSData
            item.dataType = kCMMetadataBaseDataType_RawData as String
            items.append(item)
        }
        return items
    }

    /// Re-exports with passthrough to attach the tags
    static func write(_ tags: AudioTags, to url: URL) async throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).m4a")
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw AudioError.exportSessionUnavailable
        }
        session.metadata = metadataItems(tags)
        do {
            try await session.export(to: temp, as: .m4a)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    static func read(from url: URL) async throws -> AudioTags {
        var tags = AudioTags()
        let items = try await AVURLAsset(url: url).load(.metadata)
        for item in items {
            guard let identifier = item.identifier else { continue }
            switch identifier {
            case .iTunesMetadataTrackNumber:
                if let data = try await item.load(.dataValue), data.count >= 6 {
                    let b = [UInt8](data)
                    tags.trackNumber = Int(b[2]) << 8 | Int(b[3])
                    let total = Int(b[4]) << 8 | Int(b[5])
                    tags.trackTotal = total > 0 ? total : nil
                }
                continue
            default:
                break
            }
            guard let value = try await item.load(.stringValue) else { continue }
            switch identifier {
            case .iTunesMetadataSongName, .commonIdentifierTitle: tags.title = value
            case .iTunesMetadataArtist, .commonIdentifierArtist: tags.artist = value
            case .iTunesMetadataAlbum, .commonIdentifierAlbumName: tags.album = value
            case .iTunesMetadataAlbumArtist: tags.albumArtist = value
            case .iTunesMetadataReleaseDate: tags.date = value
            case .iTunesMetadataUserGenre, .iTunesMetadataPredefinedGenre: tags.genre = value
            default: break
            }
        }
        return tags
    }
}
