import Compression
import Foundation

/// Just enough of the zip format to take two files out of a BaseCamp
/// backup, which is a plain zip of BaseCamp's Application Support folder
/// under a `.backup` name.
///
/// Read from the central directory rather than by walking local headers,
/// because a zip written by a streaming tool leaves the local sizes zero
/// and puts the real ones in a descriptor after the data; the central
/// directory always has them. Only what is asked for is inflated, since a
/// backup can carry photos and map files the library has no use for.
struct ZipArchive {
    struct Entry {
        let path: String
        let method: UInt16
        let compressedSize: Int
        let size: Int
        let localHeaderOffset: Int
    }

    enum Failure: LocalizedError {
        case notAZip
        case unsupported(String)
        case damaged(String)

        var errorDescription: String? {
            switch self {
            case .notAZip: "The file is not a zip archive."
            case .unsupported(let why): "The archive uses \(why), which Swiftcamp cannot read."
            case .damaged(let path): "\(path) in the archive is damaged."
            }
        }
    }

    let data: Data
    let entries: [Entry]

    static func looksLikeZip(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4).elementsEqual([0x50, 0x4B, 0x03, 0x04])
    }

    init(data: Data) throws {
        self.data = data
        guard Self.looksLikeZip(data), let end = Self.endOfCentralDirectory(in: data) else { throw Failure.notAZip }
        let count = Int(data.le16(end + 10))
        var offset = Int(data.le32(end + 16))
        if count == 0xFFFF || offset == 0xFFFF_FFFF { throw Failure.unsupported("the zip64 extension") }

        var entries: [Entry] = []
        for _ in 0..<count {
            guard offset + 46 <= data.count, data.le32(offset) == 0x0201_4B50 else { throw Failure.notAZip }
            let nameLength = Int(data.le16(offset + 28))
            let extraLength = Int(data.le16(offset + 30))
            let commentLength = Int(data.le16(offset + 32))
            guard offset + 46 + nameLength <= data.count else { throw Failure.notAZip }
            let nameBytes = data[(data.startIndex + offset + 46)..<(data.startIndex + offset + 46 + nameLength)]
            // Bit 11 says UTF-8; without it the name is CP437, which for
            // the ASCII paths BaseCamp writes is the same bytes. Older .NET
            // writers on Windows separate with backslashes against the
            // specification, so both are read as a folder.
            let path = String(decoding: nameBytes, as: UTF8.self).replacingOccurrences(of: "\\", with: "/")
            entries.append(Entry(path: path,
                                 method: data.le16(offset + 10),
                                 compressedSize: Int(data.le32(offset + 20)),
                                 size: Int(data.le32(offset + 24)),
                                 localHeaderOffset: Int(data.le32(offset + 42))))
            offset += 46 + nameLength + extraLength + commentLength
        }
        self.entries = entries
    }

    /// The end record sits in the last 22 bytes plus up to 64 KB of
    /// archive comment, so search backwards for its signature.
    private static func endOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowest = max(0, data.count - 22 - 0xFFFF)
        for offset in stride(from: data.count - 22, through: lowest, by: -1)
        where data.le32(offset) == 0x0605_4B50 {
            return offset
        }
        return nil
    }

    func contents(of entry: Entry) throws -> Data {
        let header = entry.localHeaderOffset
        guard header + 30 <= data.count, data.le32(header) == 0x0403_4B50 else { throw Failure.damaged(entry.path) }
        if data.le16(header + 6) & 1 != 0 { throw Failure.unsupported("encryption") }
        let start = header + 30 + Int(data.le16(header + 26)) + Int(data.le16(header + 28))
        guard start + entry.compressedSize <= data.count else { throw Failure.damaged(entry.path) }
        let stored = data[(data.startIndex + start)..<(data.startIndex + start + entry.compressedSize)]

        switch entry.method {
        case 0:
            return Data(stored)
        case 8:
            // COMPRESSION_ZLIB is raw DEFLATE, RFC 1951, with no zlib
            // header, which is exactly what a zip stores.
            guard entry.size > 0 else { return Data() }
            var output = Data(count: entry.size)
            let written = output.withUnsafeMutableBytes { out in
                stored.withUnsafeBytes { input in
                    compression_decode_buffer(out.bindMemory(to: UInt8.self).baseAddress!, entry.size,
                                              input.bindMemory(to: UInt8.self).baseAddress!, entry.compressedSize,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            guard written == entry.size else { throw Failure.damaged(entry.path) }
            return output
        default:
            throw Failure.unsupported("compression method \(entry.method)")
        }
    }
}

private extension Data {
    func le16(_ offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func le32(_ offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16 | UInt32(self[i + 3]) << 24
    }
}
