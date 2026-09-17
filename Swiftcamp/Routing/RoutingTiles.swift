import Foundation

/// Valhalla's tile grid and file layout, so the app can name and fetch a
/// tile without asking the engine.
///
/// Three levels, each a grid of square tiles over the whole world counted
/// row by row from the south-west corner: 4° highways, 1° arterials, 0.25°
/// local streets. A tile's file is its level, then its id zero-padded to a
/// multiple of three digits and split in threes, so level 2 id 750537 is
/// `2/000/750/537`. Ported from `GraphTile::FileSuffix` in graphtile.cc and
/// pinned by `RoutingTilesTests` against ids the engine was seen to fetch.
enum RoutingTiles {
    struct Level: Equatable, Sendable {
        let index: Int
        /// Tile edge, in degrees.
        let size: Double

        var columns: Int { Int((360 / size).rounded()) }
        var rows: Int { Int((180 / size).rounded()) }
    }

    static let highways = Level(index: 0, size: 4)
    static let arterials = Level(index: 1, size: 1)
    static let local = Level(index: 2, size: 0.25)
    static let levels = [highways, arterials, local]

    /// The tile covering a coordinate.
    static func id(of coordinate: Coordinate, level: Level) -> Int {
        let column = Int(floor((coordinate.lon + 180) / level.size))
        let row = Int(floor((coordinate.lat + 90) / level.size))
        return row * level.columns + column
    }

    /// Every tile at a level that a box touches, west to east then south
    /// to north.
    static func ids(in box: BoundingBox, level: Level) -> [Int] {
        let west = max(0, Int(floor((box.west + 180) / level.size)))
        let east = min(level.columns - 1, Int(floor((box.east + 180) / level.size)))
        let south = max(0, Int(floor((box.south + 90) / level.size)))
        let north = min(level.rows - 1, Int(floor((box.north + 90) / level.size)))
        guard west <= east, south <= north else { return [] }

        var out: [Int] = []
        for row in south...north {
            for column in west...east {
                out.append(row * level.columns + column)
            }
        }
        return out
    }

    /// The tile's path under the graph, without a suffix.
    static func path(level: Level, id: Int) -> String {
        let maxID = level.columns * level.rows - 1
        var digits = String(maxID).count
        if digits % 3 != 0 { digits += 3 - digits % 3 }

        let text = String(id)
        let padded = String(repeating: "0", count: max(0, digits - text.count)) + text
        var groups: [String] = []
        var start = padded.startIndex
        while start < padded.endIndex {
            let end = padded.index(start, offsetBy: 3)
            groups.append(String(padded[start..<end]))
            start = end
        }
        return "\(level.index)/" + groups.joined(separator: "/")
    }
}
