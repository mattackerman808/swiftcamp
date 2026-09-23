import Foundation

/// Line simplification: which points of a path are worth keeping.
///
/// Ramer–Douglas–Peucker, answering in indices rather than coordinates so a
/// caller can keep whatever else travels with the point: a track fix's time
/// and elevation, or the stretch of track between two survivors, which is
/// what a route made from a track stores as each leg's shape.
///
/// Recursive on the index range, with the split point found by the
/// flat-earth segment distance in `GeoMath`. That distance is hit-testing
/// math and is documented as good to a few screen widths; a track's
/// consecutive fixes are metres apart, so it is exact enough here too.
enum Simplify {
    /// Indices of the points to keep, in order, first and last always
    /// among them. Every dropped point lies within `tolerance` metres of
    /// the line through its surviving neighbours.
    static func indices(of path: [Coordinate], tolerance: Double) -> [Int] {
        guard path.count > 2 else { return Array(path.indices) }
        var keep = [0]
        divide(path, from: 0, to: path.count - 1, tolerance: tolerance, into: &keep)
        keep.append(path.count - 1)
        return keep
    }

    /// Indices of at most `count` points, found by raising the tolerance
    /// until the survivors fit. Doubling from `tolerance`: a handful of
    /// passes over a day's track, each cheaper than a sort of it.
    ///
    /// For a route's handles rather than for a device's point limit. A leg
    /// carries the whole track between two survivors, so nothing is lost by
    /// keeping few of them; too many is only a line the user cannot grab
    /// between the dots.
    static func indices(of path: [Coordinate], tolerance: Double, atMost count: Int) -> [Int] {
        var tolerance = tolerance
        var kept = indices(of: path, tolerance: tolerance)
        while kept.count > max(count, 2) {
            tolerance *= 2
            kept = indices(of: path, tolerance: tolerance)
        }
        return kept
    }

    /// The points kept, for a caller that wants the line itself.
    static func path(_ path: [Coordinate], tolerance: Double) -> [Coordinate] {
        indices(of: path, tolerance: tolerance).map { path[$0] }
    }

    /// Appends to `keep` every interior index of `from...to` that survives,
    /// in order. The ends are the caller's.
    private static func divide(_ path: [Coordinate], from: Int, to: Int, tolerance: Double,
                               into keep: inout [Int]) {
        guard to - from > 1 else { return }
        var farthest = from
        var farthestDistance = 0.0
        for i in (from + 1)..<to {
            let d = GeoMath.distance(path[i], toSegment: path[from], path[to])
            if d > farthestDistance {
                farthest = i
                farthestDistance = d
            }
        }
        guard farthestDistance > tolerance else { return }
        divide(path, from: from, to: farthest, tolerance: tolerance, into: &keep)
        keep.append(farthest)
        divide(path, from: farthest, to: to, tolerance: tolerance, into: &keep)
    }
}
