import Foundation

/// The ruler: what a run of clicks on the map measures. BaseCamp's
/// measuring tool, which reports distance and heading between points.
struct Measurement: Equatable, Sendable {
    var points: [Coordinate] = []

    /// Along every leg, in metres.
    var total: Double { GeoMath.length(points) }

    /// The last leg's length and its initial bearing, true, in degrees.
    var lastLeg: (distance: Double, bearing: Double)? {
        guard points.count >= 2 else { return nil }
        let a = points[points.count - 2], b = points[points.count - 1]
        return (GeoMath.distance(a, b), GeoMath.bearing(from: a, to: b))
    }

    /// Straight from the first point to the last, which is what a rider
    /// comparing a loop to the crow wants beside the total.
    var direct: Double? {
        guard let first = points.first, let last = points.last, points.count >= 2 else { return nil }
        return GeoMath.distance(first, last)
    }

    mutating func add(_ coordinate: Coordinate) { points.append(coordinate) }

    /// Takes the last point back, as Delete does.
    mutating func removeLast() { if !points.isEmpty { points.removeLast() } }
}
