import Foundation

/// The edits a route can take, as pure functions over its points.
///
/// Every operation that changes a leg asks `LegShaper` for the path between
/// the two via points it now joins. Today the answer is always "nothing",
/// which the renderer draws as a straight line. When Valhalla lands the
/// answer is the road, and this file is the only place that has to learn it:
/// the store, the overlay and the GPX writer consume `geometry` and never
/// compute it.
///
/// Indices here are positions in `points`, and every edit renumbers `seq` to
/// match, so the `seq` a map click reports is also the index to edit. That
/// holds because `LibraryStore.save` assigns `seq` from array order, so a
/// route read back from the store is already in this shape.
enum RouteEditing {
    /// The path between two consecutive via points, exclusive of both ends.
    typealias LegShaper = (Coordinate, Coordinate) -> [Coordinate]

    /// A straight line, which is a leg with no interior points at all.
    static let straight: LegShaper = { _, _ in [] }
}

extension RouteDetail {
    // MARK: - Editing

    /// Adds a via point at the end.
    mutating func appendVia(_ coordinate: Coordinate,
                            name: String? = nil,
                            shape: RouteEditing.LegShaper = RouteEditing.straight) {
        points.append(RoutePoint(routeID: route.id, seq: points.count,
                                 lat: coordinate.lat, lon: coordinate.lon, name: name))
        resequence()
        reshape(leg: points.count - 2, shape)
    }

    /// Splits leg `leg`, which runs from via point `leg` to `leg + 1`, with
    /// a new via point.
    ///
    /// The clicked coordinate is used as given rather than projected onto
    /// the line, because with straight legs it is already on the line to
    /// within a pixel, and once legs follow roads the shaper moves it onto
    /// the road anyway.
    mutating func insertVia(_ coordinate: Coordinate,
                            inLeg leg: Int,
                            shape: RouteEditing.LegShaper = RouteEditing.straight) {
        guard leg >= 0, leg < points.count - 1 else {
            appendVia(coordinate, shape: shape)
            return
        }
        points.insert(RoutePoint(routeID: route.id, seq: leg + 1,
                                 lat: coordinate.lat, lon: coordinate.lon),
                      at: leg + 1)
        resequence()
        reshape(leg: leg, shape)
        reshape(leg: leg + 1, shape)
    }

    /// Moves via point `index`, reshaping the leg into it and the leg out of it.
    mutating func moveVia(at index: Int,
                          to coordinate: Coordinate,
                          shape: RouteEditing.LegShaper = RouteEditing.straight) {
        guard points.indices.contains(index) else { return }
        points[index].lat = coordinate.lat
        points[index].lon = coordinate.lon
        reshape(leg: index - 1, shape)
        reshape(leg: index, shape)
    }

    /// Removes via point `index`. Its neighbours are joined by a fresh leg.
    mutating func removeVia(at index: Int,
                            shape: RouteEditing.LegShaper = RouteEditing.straight) {
        guard points.indices.contains(index) else { return }
        points.remove(at: index)
        resequence()
        reshape(leg: index - 1, shape)
    }

    /// Turns the route around.
    ///
    /// Geometry travels with the leg, not the point: the path stored on via
    /// point `i` leads to `i + 1`, so after reversal it belongs, reversed, to
    /// what was `i + 1`. Reversing the points alone would leave every leg's
    /// shape attached to the wrong end and the line would draw as a zigzag
    /// between roads.
    mutating func reverse() {
        let sorted = points.sorted { $0.seq < $1.seq }
        var reversed = Array(sorted.reversed())
        for i in reversed.indices {
            // New point `i` was old point `n - 1 - i`. The leg leaving it
            // now is the old leg that arrived at it, which was stored on old
            // point `n - 2 - i`, which is new point `i + 1`.
            let next = i + 1
            reversed[i].geometry = next < sorted.count
                ? sorted[sorted.count - 2 - i].geometry.map { Array($0.reversed()) }
                : nil
        }
        points = reversed
        resequence()
    }

    // MARK: - Hit testing

    /// Which leg a point on the line is nearest to, or nil for a route with
    /// no legs.
    ///
    /// Measured against the shaped path, not the via points, because the
    /// user clicked on the line they can see, and once legs follow roads the
    /// straight line between two via points may be nowhere near it.
    func nearestLeg(to coordinate: Coordinate) -> Int? {
        let sorted = points.sorted { $0.seq < $1.seq }
        guard sorted.count > 1 else { return nil }

        var best: (leg: Int, distance: Double)?
        for leg in 0..<(sorted.count - 1) {
            let polyline = [sorted[leg].coordinate] + (sorted[leg].geometry ?? []) + [sorted[leg + 1].coordinate]
            for (a, b) in zip(polyline, polyline.dropFirst()) {
                let d = GeoMath.distance(coordinate, toSegment: a, b)
                if best == nil || d < best!.distance { best = (leg, d) }
            }
        }
        return best?.leg
    }

    // MARK: - Invariants

    private mutating func resequence() {
        for i in points.indices { points[i].seq = i }
    }

    /// Recomputes the geometry stored on via point `leg`, which is the path
    /// to `leg + 1`. The last point leads nowhere and carries none.
    private mutating func reshape(leg: Int, _ shape: RouteEditing.LegShaper) {
        guard points.indices.contains(leg) else { return }
        guard leg < points.count - 1 else {
            points[leg].geometry = nil
            return
        }
        let path = shape(points[leg].coordinate, points[leg + 1].coordinate)
        points[leg].geometry = path.isEmpty ? nil : path
    }
}

extension GeoMath {
    /// Distance in metres from a point to a line segment.
    ///
    /// Flat-earth, deliberately, unlike everything else in `GeoMath`. This is
    /// hit testing for a click: the segment is at most a few screen widths
    /// long and the answer only has to rank candidates, so an equirectangular
    /// projection about the point is exact enough and a great-circle
    /// cross-track formula would be slower for nothing.
    static func distance(_ p: Coordinate, toSegment a: Coordinate, _ b: Coordinate) -> Double {
        let scale = Double.pi / 180 * earthRadius
        let k = cos(p.lat * .pi / 180)

        let ax = (a.lon - p.lon) * k * scale, ay = (a.lat - p.lat) * scale
        let bx = (b.lon - p.lon) * k * scale, by = (b.lat - p.lat) * scale
        let dx = bx - ax, dy = by - ay
        let lengthSquared = dx * dx + dy * dy

        // Where along the segment the perpendicular from p lands, clamped
        // to the ends so a point past either end measures to that end.
        let t = lengthSquared == 0 ? 0 : max(0, min(1, -(ax * dx + ay * dy) / lengthSquared))
        let x = ax + t * dx, y = ay + t * dy
        return (x * x + y * y).squareRoot()
    }
}
