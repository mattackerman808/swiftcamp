import CoreGraphics
import Foundation
import ImageIO

/// Elevation at a point, from the same Terrarium DEM the hillshade draws.
///
/// Tiles are 512 pixels at zoom 12, about 20 m a pixel at this latitude,
/// and each pixel is `R * 256 + G + B / 256 - 32768` metres. Decoded tiles
/// are kept, a few dozen at a megabyte each, and the WebP bytes are kept
/// on disk under Caches so the next profile over the same hills costs no
/// fetch. Bilinear between the four nearest pixels, which is what makes
/// a profile a line rather than a staircase.
actor TerrainSampler {
    static let shared = TerrainSampler(archive: PMTilesArchive(url: BasemapSource.terrainArchiveURL))

    private let archive: PMTilesArchive
    private var decoded: [TileKey: Tile] = [:]
    private var recent: [TileKey] = []
    private let keep = 48
    private let cacheFolder: URL

    struct TileKey: Hashable { var z: Int, x: Int, y: Int }

    /// RGB, one row after another, top row first, as ImageIO draws it.
    struct Tile {
        var size: Int
        var rgb: [UInt8]

        func metres(_ col: Int, _ row: Int) -> Double {
            let o = (row * size + col) * 4
            return Double(rgb[o]) * 256 + Double(rgb[o + 1]) + Double(rgb[o + 2]) / 256 - 32768
        }
    }

    init(archive: PMTilesArchive) {
        self.archive = archive
        cacheFolder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Swiftcamp/terrain/\(archive.url.lastPathComponent)", isDirectory: true)
    }

    /// Metres above sea level, or nil outside the archive or where a tile
    /// could not be read.
    func elevation(at coordinate: Coordinate) async -> Double? {
        guard let header = try? await archive.open(),
              coordinate.lat >= header.minLat, coordinate.lat <= header.maxLat,
              coordinate.lon >= header.minLon, coordinate.lon <= header.maxLon else { return nil }
        let z = Int(header.maxZoom)
        let pixel = Self.pixel(of: coordinate, zoom: z)
        let key = TileKey(z: z, x: Int(pixel.x) / Self.tileSize, y: Int(pixel.y) / Self.tileSize)
        guard let tile = await self.tile(key) else { return nil }

        // Bilinear between the four pixels around the point, clamped to
        // the tile so a point on its edge reads that edge twice rather
        // than fetching the neighbour for a quarter of a pixel.
        let fx = pixel.x - Double(key.x * Self.tileSize) - 0.5
        let fy = pixel.y - Double(key.y * Self.tileSize) - 0.5
        let x0 = max(0, min(Self.tileSize - 1, Int(fx.rounded(.down))))
        let y0 = max(0, min(Self.tileSize - 1, Int(fy.rounded(.down))))
        let x1 = min(Self.tileSize - 1, x0 + 1), y1 = min(Self.tileSize - 1, y0 + 1)
        let tx = max(0, min(1, fx - Double(x0))), ty = max(0, min(1, fy - Double(y0)))
        let top = tile.metres(x0, y0) * (1 - tx) + tile.metres(x1, y0) * tx
        let bottom = tile.metres(x0, y1) * (1 - tx) + tile.metres(x1, y1) * tx
        return top * (1 - ty) + bottom * ty
    }

    /// Elevations along a path, one per coordinate, nil where unknown.
    func elevations(along path: [Coordinate]) async -> [Double?] {
        var out: [Double?] = []
        out.reserveCapacity(path.count)
        for coordinate in path { out.append(await elevation(at: coordinate)) }
        return out
    }

    static let tileSize = 512

    /// Web Mercator pixel coordinates at a zoom, in a 512-pixel grid.
    static func pixel(of c: Coordinate, zoom: Int) -> (x: Double, y: Double) {
        let n = Double(1 << zoom) * Double(tileSize)
        let lat = c.lat * .pi / 180
        return ((c.lon + 180) / 360 * n,
                (1 - log(tan(lat) + 1 / cos(lat)) / .pi) / 2 * n)
    }

    // MARK: - Tiles

    private func tile(_ key: TileKey) async -> Tile? {
        if let tile = decoded[key] {
            recent.removeAll { $0 == key }
            recent.append(key)
            return tile
        }
        guard let bytes = await bytes(for: key), let tile = Self.decode(bytes) else { return nil }
        decoded[key] = tile
        recent.append(key)
        while recent.count > keep, let oldest = recent.first {
            recent.removeFirst()
            decoded[oldest] = nil
        }
        return tile
    }

    private func bytes(for key: TileKey) async -> Data? {
        let file = cacheFolder.appendingPathComponent("\(key.z)-\(key.x)-\(key.y).webp")
        if let data = try? Data(contentsOf: file) { return data }
        do {
            guard let data = try await archive.tile(z: key.z, x: key.x, y: key.y) else { return nil }
            try? FileManager.default.createDirectory(at: cacheFolder, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            return data
        } catch {
            NSLog("[Swiftcamp] terrain tile %d/%d/%d: %@", key.z, key.x, key.y, error.localizedDescription)
            return nil
        }
    }

    /// WebP to pixels through ImageIO. Drawn into a bitmap context, whose
    /// buffer comes out top row first for an image drawn this way; the
    /// tile over Longs Peak had its summit at exactly the row the
    /// projection predicted, with no flip.
    static func decode(_ data: Data) -> Tile? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width == tileSize, image.height == tileSize else { return nil }
        var rgb = [UInt8](repeating: 0, count: tileSize * tileSize * 4)
        let drawn = rgb.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: tileSize, height: tileSize,
                                          bitsPerComponent: 8, bytesPerRow: tileSize * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: tileSize, height: tileSize))
            return true
        }
        return drawn ? Tile(size: tileSize, rgb: rgb) : nil
    }

    /// Terrarium's formula, for a test to pin.
    static func metres(r: UInt8, g: UInt8, b: UInt8) -> Double {
        Double(r) * 256 + Double(g) + Double(b) / 256 - 32768
    }
}

extension BasemapSource {
    /// The terrain archive as a plain URL, for a reader of our own.
    static var terrainArchiveURL: URL { URL(string: "\(cdnBase)/\(terrainArchive)")! }
}
