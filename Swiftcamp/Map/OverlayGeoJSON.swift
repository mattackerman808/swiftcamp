import Foundation

/// Turns library content into the GeoJSON the overlay sources in `MapStyle`
/// expect.
///
/// Pure and platform-free, so it is testable without a renderer and the same
/// output would feed MapLibre Native if iOS ever happens.
enum OverlayGeoJSON {
    // MARK: - Building

    /// One `LineString` per route, along the shaped path.
    ///
    /// The path, not the via points: a route whose geometry follows a road
    /// must draw the road. Once snapping lands that is the only difference
    /// between this and a straight line, and nothing here changes.
    static func routeLines(_ routes: [RouteDetail]) -> FeatureCollection {
        FeatureCollection(features: routes.compactMap { detail in
            let path = detail.path
            guard path.count > 1 else { return nil }
            return Feature(geometry: .lineString(path),
                           properties: Properties(id: detail.route.id,
                                                  name: detail.route.name,
                                                  color: ItemColor.hex(detail.route.color)))
        })
    }

    /// The handles: every route point, via and shaping alike, since both
    /// can be grabbed. The road geometry between them is not a handle; a
    /// Colorado leg carries thousands of vertices and drawing a grabbable
    /// dot on each would be unusable.
    static func handles(_ routes: [RouteDetail], selected: Set<String> = []) -> FeatureCollection {
        FeatureCollection(features: routes.flatMap { detail in
            let distances = detail.distancesFromStart()
            return detail.points.sorted { $0.seq < $1.seq }.map { point in
                Feature(geometry: .point(point.coordinate),
                        properties: Properties(id: detail.route.id,
                                               seq: point.seq,
                                               name: point.name,
                                               // Carried so a handle is
                                               // ringed in its own route's
                                               // colour. Where two routes
                                               // cross, a ring that matches
                                               // neither says nothing about
                                               // which one it belongs to.
                                               color: ItemColor.hex(detail.route.color),
                                               selected: selected.contains(handle(detail.route.id, point.seq)),
                                               // The style draws a shaping
                                               // point smaller and solid,
                                               // so a stop and a bend read
                                               // differently at a glance.
                                               via: point.isVia,
                                               // For the readout under the
                                               // pointer. The geometry the
                                               // renderer hands back from a
                                               // hit is quantised to the
                                               // tile grid, so the exact
                                               // position travels as data.
                                               lat: point.lat,
                                               lon: point.lon,
                                               distance: distances[point.seq]))
            }
        })
    }

    /// One `LineString` per *segment*, not per track. A break in the
    /// recording is a break in the line; joining them draws a road that does
    /// not exist.
    static func trackLines(_ tracks: [TrackDetail]) -> FeatureCollection {
        FeatureCollection(features: tracks.flatMap { detail in
            detail.segments.filter { $0.count > 1 }.map { segment in
                Feature(geometry: .lineString(thinned(segment)),
                        properties: Properties(id: detail.track.id,
                                               name: detail.track.name,
                                               color: ItemColor.hex(detail.track.color)))
            }
        })
    }

    /// How many points of one segment are worth drawing.
    ///
    /// A day's recording is a few hundred thousand fixes, most of them a
    /// metre or two apart. At any zoom a touring map is used at, thousands of
    /// them land on the same pixel, so handing the renderer all of them buys
    /// nothing and costs a multi-megabyte push and a line that is slow to pan.
    private static let maxPointsPerSegment = 4_000

    /// Evenly thins a segment for display.
    ///
    /// Display only. The stored track keeps every point, and export writes
    /// every point — thinning what leaves the app would quietly degrade the
    /// user's own recording, which is theirs and not ours to round off.
    ///
    /// Evenly rather than by Douglas-Peucker: this runs on every overlay
    /// rebuild, the input is already dense, and the last point is kept
    /// explicitly so a thinned line still ends where the ride ended.
    static func thinned(_ path: [Coordinate], limit: Int = maxPointsPerSegment) -> [Coordinate] {
        guard path.count > limit, limit > 1 else { return path }

        let step = Int((Double(path.count) / Double(limit)).rounded(.up))
        var out = stride(from: 0, to: path.count, by: step).map { path[$0] }
        if let last = path.last, out.last != last { out.append(last) }
        return out
    }

    /// The pin for a search result, or nothing.
    static func searchPin(_ result: SearchResult?) -> FeatureCollection {
        FeatureCollection(features: result.map {
            [Feature(geometry: .point($0.coordinate),
                     properties: Properties(name: $0.name, lat: $0.coordinate.lat, lon: $0.coordinate.lon,
                                            icon: SymbolCatalog.search.image,
                                            anchor: SymbolCatalog.search.anchor))]
        } ?? [])
    }

    /// Each waypoint carries the sprite image for its Garmin symbol and
    /// where that image sits on the place. Decided here rather than in the
    /// style so an unknown symbol resolves to the generic marker once, in
    /// Swift, instead of naming an image the sprite does not have.
    static func waypoints(_ waypoints: [Waypoint], selected: Set<String> = []) -> FeatureCollection {
        FeatureCollection(features: waypoints.map { waypoint in
            let symbol = SymbolCatalog.entry(for: waypoint.symbol)
            return Feature(geometry: .point(waypoint.coordinate),
                           properties: Properties(id: waypoint.id,
                                                  name: waypoint.name,
                                                  selected: selected.contains(waypoint.id),
                                                  lat: waypoint.lat,
                                                  lon: waypoint.lon,
                                                  icon: symbol.image,
                                                  anchor: symbol.anchor))
        })
    }

    /// Identifies one via point. A route id alone is not enough and a row id
    /// is not stable across a save, which rewrites every point.
    static func handle(_ routeID: String, _ seq: Int) -> String { "\(routeID)#\(seq)" }

    /// The inverse, for a selection that holds a handle. Route ids are
    /// UUIDs and never contain `#`, so the last one is the separator.
    static func parseHandle(_ id: String) -> (routeID: String, seq: Int)? {
        guard let hash = id.lastIndex(of: "#"),
              let seq = Int(id[id.index(after: hash)...]) else { return nil }
        return (String(id[..<hash]), seq)
    }

    // MARK: - Types

    struct FeatureCollection: Codable, Equatable {
        var type = "FeatureCollection"
        var features: [Feature]

        func json() throws -> String {
            let encoder = JSONEncoder()
            // Stable key order, so a push that changes nothing produces
            // identical bytes and can be skipped without comparing structures.
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(self), as: UTF8.self)
        }
    }

    struct Feature: Codable, Equatable {
        var type = "Feature"
        var geometry: Geometry
        var properties: Properties
    }

    /// Only the two shapes the overlay draws. GeoJSON has seven; carrying the
    /// rest would be code with no caller.
    enum Geometry: Codable, Equatable {
        case point(Coordinate)
        case lineString([Coordinate])

        private enum CodingKeys: String, CodingKey { case type, coordinates }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .point(let coordinate):
                try c.encode("Point", forKey: .type)
                try c.encode(coordinate, forKey: .coordinates)
            case .lineString(let path):
                try c.encode("LineString", forKey: .type)
                try c.encode(path, forKey: .coordinates)
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(String.self, forKey: .type) {
            case "Point":
                self = .point(try c.decode(Coordinate.self, forKey: .coordinates))
            case "LineString":
                self = .lineString(try c.decode([Coordinate].self, forKey: .coordinates))
            case let other:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c,
                                                       debugDescription: "unsupported geometry \(other)")
            }
        }
    }

    /// What the style's expressions read, and what a click needs to identify
    /// what was hit. Every field is optional so it is omitted rather than
    /// written as null, which keeps a long feature collection smaller.
    struct Properties: Codable, Equatable {
        var id: String?
        var seq: Int?
        var name: String?
        var color: String?
        var selected: Bool?
        var via: Bool?
        var lat: Double?
        var lon: Double?
        /// Metres from the start of the route, for route points.
        var distance: Double?
        /// Sprite image and its anchor, for waypoints and the search pin.
        var icon: String?
        var anchor: String?
    }
}
