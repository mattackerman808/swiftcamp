import Foundation

/// A point on the earth.
///
/// Deliberately not `CLLocationCoordinate2D`: that type is not `Codable`,
/// not `Equatable`, and carries a CoreLocation dependency into the GPX
/// reader and the store, neither of which has anything to do with the
/// device's location.
struct Coordinate: Hashable, Sendable {
    var lat: Double
    var lon: Double

    init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }
}

/// Encoded as a two-element array in GeoJSON order, `[lon, lat]`, not as an
/// object with named keys.
///
/// A single route's shaping geometry runs to thousands of points and is
/// stored as JSON in one column, so the difference between `[-105.5,40.3]`
/// and `{"lat":40.3,"lon":-105.5}` is most of the column. The order is the
/// one GeoJSON uses, longitude first, so the same array can be handed to the
/// renderer without a transform — and because inventing a different order
/// for the same shape is how a map ends up drawing the Indian Ocean.
extension Coordinate: Codable {
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        lon = try c.decode(Double.self)
        lat = try c.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(lon)
        try c.encode(lat)
    }
}

/// The rectangle enclosing a set of points.
///
/// No antimeridian handling. A box spanning 180 degrees would need to be two
/// boxes, and a touring app whose data is North American will not meet one —
/// but a route from Anadyr to Nome would frame the entire planet, so this is
/// a limitation rather than a definition.
struct BoundingBox: Equatable, Sendable {
    var west: Double
    var south: Double
    var east: Double
    var north: Double

    /// Spelled out because the failable initializer below suppresses the
    /// synthesized one, and the map reports its view as four edges.
    init(west: Double, south: Double, east: Double, north: Double) {
        self.west = west
        self.south = south
        self.east = east
        self.north = north
    }

    init?(_ coordinates: some Collection<Coordinate>) {
        guard let first = coordinates.first else { return nil }
        west = first.lon; east = first.lon
        south = first.lat; north = first.lat

        for c in coordinates.dropFirst() {
            west = min(west, c.lon); east = max(east, c.lon)
            south = min(south, c.lat); north = max(north, c.lat)
        }
    }

    /// True when everything landed on one spot, so there is no rectangle to
    /// fit and fitting one anyway zooms to the renderer's maximum.
    var isDegenerate: Bool {
        east - west < 1e-9 && north - south < 1e-9
    }

    var center: Coordinate {
        Coordinate(lat: (south + north) / 2, lon: (west + east) / 2)
    }
}

/// Great-circle math.
///
/// One copy, on purpose. tachbase ended up with four implementations of
/// great-circle bearing, three of them accidental duplicates, and documents
/// the mess it caused when two of them disagreed.
enum GeoMath {
    /// WGS-84 mean radius, metres.
    static let earthRadius: Double = 6_371_008.8

    /// Great-circle distance in metres.
    ///
    /// Haversine rather than a flat-earth approximation. A touring route leg
    /// is routinely hundreds of kilometres, which is exactly where the flat
    /// approximation starts under-reading.
    static func distance(_ a: Coordinate, _ b: Coordinate) -> Double {
        let φ1 = a.lat * .pi / 180, φ2 = b.lat * .pi / 180
        let dφ = (b.lat - a.lat) * .pi / 180
        let dλ = (b.lon - a.lon) * .pi / 180

        let h = sin(dφ / 2) * sin(dφ / 2)
            + cos(φ1) * cos(φ2) * sin(dλ / 2) * sin(dλ / 2)
        return 2 * earthRadius * atan2(sqrt(h), sqrt(1 - h))
    }

    /// Length of a polyline in metres.
    static func length(_ path: [Coordinate]) -> Double {
        guard path.count > 1 else { return 0 }
        return zip(path, path.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    /// Initial bearing in degrees true, 0 at north, clockwise.
    static func bearing(from a: Coordinate, to b: Coordinate) -> Double {
        let φ1 = a.lat * .pi / 180, φ2 = b.lat * .pi / 180
        let dλ = (b.lon - a.lon) * .pi / 180

        let y = sin(dλ) * cos(φ2)
        let x = cos(φ1) * sin(φ2) - sin(φ1) * cos(φ2) * cos(dλ)
        return wrap360(atan2(y, x) * 180 / .pi)
    }

    /// Degrees normalised into `0..<360`.
    ///
    /// `truncatingRemainder` keeps the sign of the dividend, so it alone
    /// returns negative values for westerly bearings.
    static func wrap360(_ degrees: Double) -> Double {
        let r = degrees.truncatingRemainder(dividingBy: 360)
        return r < 0 ? r + 360 : r
    }
}
