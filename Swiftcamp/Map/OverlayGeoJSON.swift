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
                                                  color: GarminColor.hex(detail.route.color)))
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
                Feature(geometry: .lineString(segment),
                        properties: Properties(id: detail.track.id,
                                               name: detail.track.name,
                                               color: GarminColor.hex(detail.track.color)))
            }
        })
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

/// Garmin's `DisplayColor` vocabulary, as hex.
///
/// Most of their names happen to be CSS colour names, so passing them
/// straight through would usually work — but `DarkYellow` is not one, and an
/// unparseable colour in a data-driven paint expression fails the whole
/// layer, not just the one feature. Mapping explicitly and returning nil for
/// anything unrecognised makes the fallback in the style do its job.
enum GarminColor {
    private static let table = [
        "black": "#000000",
        "darkred": "#8b0000",
        "darkgreen": "#006400",
        "darkyellow": "#808000",   // not a CSS name, which is the whole point
        "darkblue": "#00008b",
        "darkmagenta": "#8b008b",
        "darkcyan": "#008b8b",
        "lightgray": "#d3d3d3",
        "darkgray": "#a9a9a9",
        "red": "#ff0000",
        "green": "#008000",
        "yellow": "#ffff00",
        "blue": "#0000ff",
        "magenta": "#ff00ff",
        "cyan": "#00ffff",
        "white": "#ffffff",
    ]

    static func hex(_ name: String?) -> String? {
        guard let name else { return nil }
        // `Transparent` is in Garmin's list and means "do not draw". Falling
        // back to the default colour is wrong, but an invisible route the
        // user cannot find is worse.
        return table[name.lowercased()]
    }
}
