import Compression
import Foundation

/// The PMTiles v3 container, read by byte range: enough of it to find one
/// tile in the terrain archive the map already streams.
///
/// MapLibre reads these archives for the map, in the web view on macOS
/// and natively on iOS, and neither can hand a tile's pixels back to
/// Swift. An elevation profile needs the pixels, so this is the same
/// reader in a hundred lines: a fixed header, a root directory, leaf
/// directories the root points into, and tile data, all addressed by
/// offsets in the header and fetched with HTTP range requests. The
/// numbers here were checked against the real archive in Python before
/// a line of this was written, Longs Peak coming out at 4,344 m.
enum PMTiles {
    /// The first 127 bytes of every archive.
    struct Header: Equatable, Sendable {
        static let length = 127

        var rootOffset: UInt64, rootLength: UInt64
        var metadataOffset: UInt64, metadataLength: UInt64
        var leafOffset: UInt64, leafLength: UInt64
        var tileDataOffset: UInt64, tileDataLength: UInt64
        var clustered: Bool
        /// 0 unknown, 1 none, 2 gzip, 3 brotli, 4 zstd.
        var internalCompression: UInt8
        var tileCompression: UInt8
        /// 1 MVT, 2 PNG, 3 JPEG, 4 WebP, 5 AVIF. The terrain archive is
        /// WebP, which this reader learnt by fetching a tile and finding
        /// RIFF where it expected a PNG signature.
        var tileType: UInt8
        var minZoom: UInt8, maxZoom: UInt8
        var minLon: Double, minLat: Double, maxLon: Double, maxLat: Double

        init(_ data: Data) throws {
            guard data.count >= Self.length, data.prefix(7) == Data("PMTiles".utf8), data[data.startIndex + 7] == 3
            else { throw PMTilesError.notAnArchive }
            func u64(_ at: Int) -> UInt64 {
                (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[data.startIndex + at + $1]) << (8 * UInt64($1)) }
            }
            func i32(_ at: Int) -> Int32 {
                Int32(bitPattern: (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[data.startIndex + at + $1]) << (8 * UInt32($1)) })
            }
            rootOffset = u64(8); rootLength = u64(16)
            metadataOffset = u64(24); metadataLength = u64(32)
            leafOffset = u64(40); leafLength = u64(48)
            tileDataOffset = u64(56); tileDataLength = u64(64)
            clustered = data[data.startIndex + 96] == 1
            internalCompression = data[data.startIndex + 97]
            tileCompression = data[data.startIndex + 98]
            tileType = data[data.startIndex + 99]
            minZoom = data[data.startIndex + 100]
            maxZoom = data[data.startIndex + 101]
            minLon = Double(i32(102)) / 1e7; minLat = Double(i32(106)) / 1e7
            maxLon = Double(i32(110)) / 1e7; maxLat = Double(i32(114)) / 1e7
        }
    }

    /// One directory entry: a tile id, where its data is relative to the
    /// tile data section, how long it is, and how many consecutive ids it
    /// stands for. A run length of zero means the entry points at a leaf
    /// directory rather than a tile.
    struct Entry: Equatable, Sendable {
        var tileID: UInt64
        var offset: UInt64
        var length: UInt32
        var runLength: UInt32

        var isLeaf: Bool { runLength == 0 }
    }

    // MARK: - Tile ids

    /// The Hilbert-curve id of a tile, as the spec numbers them: every
    /// tile of the zooms above first, then the tile's place on the curve
    /// at its own zoom. The spec's own examples pin it: z0 is 0, the four
    /// tiles of z1 are 1 through 4 in curve order, and z2 begins at 5.
    static func tileID(z: Int, x: Int, y: Int) -> UInt64 {
        var acc: UInt64 = 0
        for zoom in 0..<z { acc += UInt64(1) << (2 * UInt64(zoom)) }
        let n = 1 << z
        var x = x, y = y
        var d: UInt64 = 0
        var s = n >> 1
        while s > 0 {
            let rx = (x & s) != 0 ? 1 : 0
            let ry = (y & s) != 0 ? 1 : 0
            d += UInt64(s) * UInt64(s) * UInt64((3 * rx) ^ ry)
            if ry == 0 {
                if rx == 1 {
                    x = n - 1 - x
                    y = n - 1 - y
                }
                swap(&x, &y)
            }
            s >>= 1
        }
        return acc + d
    }

    // MARK: - Directories

    /// A directory, after decompression: a count, then the ids as deltas,
    /// the run lengths, the lengths, and the offsets, each as a varint,
    /// with a zero offset meaning "right after the previous entry".
    static func decodeDirectory(_ data: Data) throws -> [Entry] {
        var reader = VarintReader(data)
        let count = Int(try reader.next())
        var entries = [Entry](repeating: Entry(tileID: 0, offset: 0, length: 0, runLength: 0), count: count)
        var last: UInt64 = 0
        for i in 0..<count {
            last += try reader.next()
            entries[i].tileID = last
        }
        for i in 0..<count { entries[i].runLength = UInt32(clamping: try reader.next()) }
        for i in 0..<count { entries[i].length = UInt32(clamping: try reader.next()) }
        for i in 0..<count {
            let offset = try reader.next()
            if offset == 0, i > 0 {
                entries[i].offset = entries[i - 1].offset + UInt64(entries[i - 1].length)
            } else {
                entries[i].offset = offset &- 1
            }
        }
        return entries
    }

    /// The entry that covers a tile id, in a directory sorted by id: the
    /// last entry at or before it, if the id falls inside its run or it
    /// is a leaf to descend into.
    static func find(_ tileID: UInt64, in entries: [Entry]) -> Entry? {
        var low = 0, high = entries.count - 1
        var best: Entry?
        while low <= high {
            let mid = (low + high) / 2
            if entries[mid].tileID <= tileID {
                best = entries[mid]
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let best else { return nil }
        if best.isLeaf { return best }
        return tileID < best.tileID + UInt64(best.runLength) ? best : nil
    }

    struct VarintReader {
        private let data: Data
        private var index: Int

        init(_ data: Data) {
            self.data = data
            index = data.startIndex
        }

        mutating func next() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard index < data.endIndex, shift < 64 else { throw PMTilesError.corruptDirectory }
                let byte = data[index]
                index += 1
                result |= UInt64(byte & 0x7f) << shift
                if byte < 0x80 { return result }
                shift += 7
            }
        }
    }

    // MARK: - Compression

    /// Inflates a gzip member: the ten-byte header and its optional
    /// fields skipped, then raw DEFLATE, which is what Apple's
    /// `COMPRESSION_ZLIB` speaks. The output size is not known up front,
    /// so this streams into a growing buffer rather than guessing.
    static func gunzip(_ data: Data) throws -> Data {
        guard data.count >= 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else {
            throw PMTilesError.notGzip
        }
        let flags = data[data.startIndex + 3]
        var start = data.startIndex + 10
        if flags & 0x04 != 0 {
            let extra = Int(data[start]) | Int(data[start + 1]) << 8
            start += 2 + extra
        }
        if flags & 0x08 != 0 { while data[start] != 0 { start += 1 }; start += 1 }
        if flags & 0x10 != 0 { while data[start] != 0 { start += 1 }; start += 1 }
        if flags & 0x02 != 0 { start += 2 }
        let deflated = data[start..<(data.endIndex - 8)]
        return try inflate(deflated)
    }

    private static func inflate(_ deflated: Data) throws -> Data {
        var out = Data()
        let chunk = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { buffer.deallocate() }
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw PMTilesError.notGzip
        }
        defer { compression_stream_destroy(streamPointer) }
        try deflated.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            streamPointer.pointee.src_ptr = source.bindMemory(to: UInt8.self).baseAddress!
            streamPointer.pointee.src_size = source.count
            while true {
                streamPointer.pointee.dst_ptr = buffer
                streamPointer.pointee.dst_size = chunk
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                out.append(buffer, count: chunk - streamPointer.pointee.dst_size)
                if status == COMPRESSION_STATUS_END { return }
                guard status == COMPRESSION_STATUS_OK else { throw PMTilesError.notGzip }
            }
        }
        return out
    }
}

enum PMTilesError: LocalizedError {
    case notAnArchive
    case notGzip
    case corruptDirectory
    case fetchFailed(Int)

    var errorDescription: String? {
        switch self {
        case .notAnArchive: "not a PMTiles archive"
        case .notGzip: "a directory that is not gzip"
        case .corruptDirectory: "a directory that does not parse"
        case .fetchFailed(let status): "the archive answered \(status)"
        }
    }
}

/// One archive on a server, with its directories remembered once read.
///
/// An actor: directories are fetched on first use and kept, and two
/// profiles asked for at once must not both fetch the root.
actor PMTilesArchive {
    let url: URL
    private(set) var header: PMTiles.Header?
    private var root: [PMTiles.Entry] = []
    private var leaves: [UInt64: [PMTiles.Entry]] = [:]
    private let session: URLSession

    /// A name of our own: the CDN sits behind bot protection that refuses
    /// a bare client, which a 403 on the first leaf fetch taught.
    static let userAgent = "Swiftcamp/1.0 (macOS)"

    init(url: URL) {
        self.url = url
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    /// The header, fetched on first use.
    func open() async throws -> PMTiles.Header {
        if let header { return header }
        let header = try PMTiles.Header(try await fetch(offset: 0, length: UInt64(PMTiles.Header.length)))
        guard header.internalCompression == 2 || header.internalCompression == 1 else {
            throw PMTilesError.notGzip
        }
        self.header = header
        root = try await directory(at: header.rootOffset, length: header.rootLength, header: header)
        return header
    }

    /// One tile's bytes, or nil where the archive has none.
    func tile(z: Int, x: Int, y: Int) async throws -> Data? {
        let header = try await open()
        let id = PMTiles.tileID(z: z, x: x, y: y)
        var entries = root
        // At most a few levels: the root points at leaves, and a leaf at
        // tiles; a leaf pointing at another leaf is allowed and rare.
        for _ in 0..<4 {
            guard let entry = PMTiles.find(id, in: entries) else { return nil }
            guard entry.isLeaf else {
                return try await fetch(offset: header.tileDataOffset + entry.offset, length: UInt64(entry.length))
            }
            if let known = leaves[entry.offset] {
                entries = known
            } else {
                let leaf = try await directory(at: header.leafOffset + entry.offset, length: UInt64(entry.length), header: header)
                leaves[entry.offset] = leaf
                entries = leaf
            }
        }
        return nil
    }

    private func directory(at offset: UInt64, length: UInt64, header: PMTiles.Header) async throws -> [PMTiles.Entry] {
        let raw = try await fetch(offset: offset, length: length)
        return try PMTiles.decodeDirectory(header.internalCompression == 2 ? try PMTiles.gunzip(raw) : raw)
    }

    private func fetch(offset: UInt64, length: UInt64) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 || http.statusCode == 200 else {
            throw PMTilesError.fetchFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return data
    }
}
