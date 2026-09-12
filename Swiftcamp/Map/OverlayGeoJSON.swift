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

    /// The handles. Via points only — shaping points are geometry, not
    /// something the user can grab, and drawing them would put thousands of
    /// dots on a route that has three.
    static func viaPoints(_ routes: [RouteDetail], selected: Set<String> = []) -> FeatureCollection {
        FeatureCollection(features: routes.flatMap { detail in
            detail.viaPoints.map { point in
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
                                               selected: selected.contains(handle(detail.route.id, point.seq))))
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

    static func waypoints(_ waypoints: [Waypoint], selected: Set<String> = []) -> FeatureCollection {
        FeatureCollection(features: waypoints.map { waypoint in
            Feature(geometry: .point(waypoint.coordinate),
                    properties: Properties(id: waypoint.id,
                                           name: waypoint.name,
                                           selected: selected.contains(waypoint.id)))
        })
    }

    /// Identifies one via point. A route id alone is not enough and a row id
    /// is not stable across a save, which rewrites every point.
    static func handle(_ routeID: String, _ seq: Int) -> String { "\(routeID)#\(seq)" }

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
    }
}
