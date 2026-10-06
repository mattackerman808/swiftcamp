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
    /// The path between two consecutive points as routed, inclusive of
    /// both ends. The first and last vertex are where each point landed on
    /// the road, which is not always where it was dropped; `Snap` decides
    /// whether the point follows. Empty means a straight line, on which
    /// nothing lands anywhere.
    typealias LegShaper = (Coordinate, Coordinate) -> [Coordinate]

    /// A straight line, which is a leg with no interior points at all.
    static let straight: LegShaper = { _, _ in [] }

    /// A shaper that answers straight for any leg longer than `metres`
    /// as the crow flies, and asks `shaper` for the rest.
    ///
    /// For drag previews. The engine cannot route incrementally, so a
    /// preview of a cross-country leg repeats a half-second search on
    /// every mouse move and the pointer runs a second ahead of the line.
    /// Above the limit the leg follows the pointer straight and is routed
    /// once, on release; below it, live re-routing stays.
    static func straightBeyond(_ metres: Double, _ shaper: @escaping LegShaper) -> LegShaper {
        { a, b in GeoMath.distance(a, b) > metres ? [] : shaper(a, b) }
    }

    /// Whether a point moves to where its leg landed on the road.
    enum Snap: Equatable, Sendable {
        /// However far. BaseCamp's rule: a road route wants its stops on
        /// the road, and a drop in a field meant the road beside it.
        case always
        /// Only when the landing is this close, in metres. A near miss
        /// lands on the track; a deliberate point in the scrub stays put.
        case within(Double)
        case never

        func allows(_ metres: Double) -> Bool {
            switch self {
            case .always: true
            case .within(let limit): metres <= limit
            case .never: false
            }
        }
    }
}

extension RoutePoint {
    /// A stop that is a waypoint: its position, name and symbol, pinned
    /// so no re-route moves a campsite onto the road, and linked so a
    /// change to the waypoint reaches the route. `seq` is set by whoever
    /// places it.
    init(stopAt waypoint: Waypoint, routeID: String) {
        self.init(routeID: routeID, seq: 0, lat: waypoint.lat, lon: waypoint.lon,
                  name: waypoint.name, symbol: waypoint.symbol,
                  isVia: true, isPinned: true, waypointID: waypoint.id)
    }

    /// Takes the waypoint's name, symbol and position, for a point linked
    /// to it. Says whether anything changed, so a caller can skip a write.
    @discardableResult
    mutating func follow(_ waypoint: Waypoint) -> Bool {
        let before = self
        name = waypoint.name
        symbol = waypoint.symbol
        lat = waypoint.lat
        lon = waypoint.lon
        return self != before
    }
}

extension RouteDetail {
    // MARK: - Editing

    /// Positions of the points made from `waypointID`. One, normally; a
    /// loop that starts and ends at the same campsite has two.
    func indices(ofWaypoint waypointID: String) -> [Int] {
        points.indices.filter { points[$0].waypointID == waypointID }
    }

    /// Takes a changed waypoint's name, symbol and position onto every
    /// point linked to it, routing the legs either side of one that moved.
    /// Says whether anything changed.
    @discardableResult
    mutating func follow(_ waypoint: Waypoint,
                         snap: RouteEditing.Snap = .never,
                         shape: RouteEditing.LegShaper = RouteEditing.straight) -> Bool {
        var changed = false
        for i in indices(ofWaypoint: waypoint.id) {
            let moved = points[i].coordinate != waypoint.coordinate
            guard points[i].follow(waypoint) else { continue }
            changed = true
            if moved {
                reshape(leg: i - 1, snap: snap, shape)
                reshape(leg: i, snap: snap, shape)
            }
        }
        return changed
    }

    /// Adds a point at the end: a via point, or with `isVia` false a
    /// shaping point, which bends the route without being a stop.
    mutating func appendVia(_ coordinate: Coordinate,
                            name: String? = nil,
                            isVia: Bool = true,
                            isPinned: Bool = false,
                            snap: RouteEditing.Snap = .never,
                            shape: RouteEditing.LegShaper = RouteEditing.straight) {
        insert(RoutePoint(routeID: route.id, seq: points.count,
                          lat: coordinate.lat, lon: coordinate.lon, name: name,
                          isVia: isVia, isPinned: isPinned),
               at: points.count, snap: snap, shape)
    }

    /// Adds a waypoint at the end as a stop: its position, name and
    /// symbol, pinned there, and linked so it follows the waypoint.
    mutating func appendVia(_ waypoint: Waypoint,
                            snap: RouteEditing.Snap = .never,
                            shape: RouteEditing.LegShaper = RouteEditing.straight) {
        insert(RoutePoint(stopAt: waypoint, routeID: route.id), at: points.count, snap: snap, shape)
    }

    /// Puts a waypoint into the route as a stop before point `index`, or
    /// at the end for `points.count`. Dropping it on the first stop makes
    /// it the new start, which splitting a leg could never do.
    mutating func insertVia(_ waypoint: Waypoint,
                            before index: Int,
                            snap: RouteEditing.Snap = .never,
                            shape: RouteEditing.LegShaper = RouteEditing.straight) {
        insert(RoutePoint(stopAt: waypoint, routeID: route.id),
               at: max(0, min(index, points.count)), snap: snap, shape)
    }

    /// Puts `point` at position `index`, 0 through `points.count`, and
    /// routes the leg into it and the leg out of it. Every other way of
    /// adding a point comes through here.
    private mutating func insert(_ point: RoutePoint, at index: Int,
                                 snap: RouteEditing.Snap, _ shape: RouteEditing.LegShaper) {
        points.insert(point, at: index)
        resequence()
        reshape(leg: index - 1, snap: snap, shape)
        reshape(leg: index, snap: snap, shape)
    }

    /// Moves the points at `source` to sit before the point now at
    /// `destination`, which is how a list reports a drag of its rows, and
    /// `IndexSet` because that is what it hands over.
    ///
    /// Only a leg whose two ends are no longer the neighbours they were is
    /// routed again. A road leg is a search of the graph and a write of
    /// thousands of vertices, and a stop dragged from fourth to second
    /// changes three legs of a twenty-stop route, not twenty.
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int,
                       snap: RouteEditing.Snap = .never,
                       shape: RouteEditing.LegShaper = RouteEditing.straight) {
        guard source.allSatisfy(points.indices.contains), (0...points.count).contains(destination) else { return }
        // `seq` is the position before the move while the array is the
        // position after, which is exactly the comparison that says
        // whether a leg survived: the geometry on a point describes the
        // leg to what *was* its successor.
        points.move(fromOffsets: source, toOffset: destination)
        var stale: [Int] = []
        for i in points.indices {
            let next = i + 1 < points.count ? points[i + 1].seq : nil
            if next != points[i].seq + 1 {
                points[i].geometry = nil
                if next != nil { stale.append(i) }
            }
        }
        resequence()
        reshape(legs: stale, snap: snap, shape: shape)
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
                            isVia: Bool = true,
                            snap: RouteEditing.Snap = .never,
                            shape: RouteEditing.LegShaper = RouteEditing.straight) {
        guard leg >= 0, leg < points.count - 1 else {
            appendVia(coordinate, isVia: isVia, snap: snap, shape: shape)
            return
        }
        insert(RoutePoint(routeID: route.id, seq: leg + 1,
                          lat: coordinate.lat, lon: coordinate.lon, isVia: isVia),
               at: leg + 1, snap: snap, shape)
    }

    /// Moves via point `index`, reshaping the leg into it and the leg out of it.
    mutating func moveVia(at index: Int,
                          to coordinate: Coordinate,
                          snap: RouteEditing.Snap = .never,
                          shape: RouteEditing.LegShaper = RouteEditing.straight) {
        guard points.indices.contains(index) else { return }
        points[index].lat = coordinate.lat
        points[index].lon = coordinate.lon
        reshape(leg: index - 1, snap: snap, shape)
        reshape(leg: index, snap: snap, shape)
    }

    /// Routes every leg afresh, for a change of mode. BaseCamp recalculates
    /// on a profile change too: a route whose legs were found one way and
    /// whose mode says another is a lie.
    mutating func reshapeAll(snap: RouteEditing.Snap, shape: RouteEditing.LegShaper) {
        guard points.count > 1 else { return }
        reshape(legs: Array(0..<(points.count - 1)), snap: snap, shape: shape)
    }

    /// Routes the legs named, in order.
    mutating func reshape(legs: [Int], snap: RouteEditing.Snap, shape: RouteEditing.LegShaper) {
        for leg in legs {
            reshape(leg: leg, snap: snap, shape)
        }
    }

    /// The legs that are straight lines: not yet routed, or routed and
    /// refused. The last point leads nowhere and is never a leg.
    var straightLegs: [Int] {
        guard points.count > 1 else { return [] }
        return (0..<(points.count - 1)).filter { points[$0].geometry == nil }
    }

    /// Drops every leg's road, leaving straight lines, for a change of
    /// mode: the roads are found again under the new one.
    mutating func straightenAll() {
        for i in points.indices { points[i].geometry = nil }
    }

    /// Makes point `index` a via point or a shaping point.
    ///
    /// Nothing about the line changes: both kinds sit on the road and
    /// shape it. The difference is on the device, which announces a via
    /// point as a stop and passes a shaping point in silence, and in the
    /// sidebar, where only via points carry names.
    mutating func setVia(at index: Int, _ isVia: Bool) {
        guard points.indices.contains(index) else { return }
        points[index].isVia = isVia
        if !isVia { points[index].name = nil }
    }

    /// Renames via point `index`. A shaping point has no name to give.
    mutating func rename(at index: Int, to name: String?) {
        guard points.indices.contains(index), points[index].isVia else { return }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        points[index].name = trimmed.isEmpty ? nil : trimmed
    }

    /// Removes via point `index`. Its neighbours are joined by a fresh leg.
    mutating func removeVia(at index: Int,
                            snap: RouteEditing.Snap = .never,
                            shape: RouteEditing.LegShaper = RouteEditing.straight) {
        guard points.indices.contains(index) else { return }
        points.remove(at: index)
        resequence()
        reshape(leg: index - 1, snap: snap, shape)
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

    /// Recomputes the geometry stored on point `leg`, which is the path to
    /// `leg + 1`, and moves either end onto the road it landed on when the
    /// snap rule allows. The last point leads nowhere and carries none.
    ///
    /// An end that does not move keeps its landing as the first or last
    /// vertex of the leg, so the line still reaches the road and the spur
    /// from the point runs to exactly where the routing began.
    private mutating func reshape(leg: Int, snap: RouteEditing.Snap, _ shape: RouteEditing.LegShaper) {
        guard points.indices.contains(leg) else { return }
        guard leg < points.count - 1 else {
            points[leg].geometry = nil
            return
        }
        let path = shape(points[leg].coordinate, points[leg + 1].coordinate)
        guard let start = path.first, let end = path.last, path.count >= 2 else {
            points[leg].geometry = nil
            return
        }

        var geometry = Array(path.dropFirst().dropLast())
        if !land(leg, on: start, snap) { geometry.insert(start, at: 0) }
        if !land(leg + 1, on: end, snap) { geometry.append(end) }
        points[leg].geometry = geometry.isEmpty ? nil : geometry
    }

    /// Moves point `index` onto `landing` if the rule allows, and says so.
    /// A point already there counts as moved: keeping a vertex a metre
    /// from the point would put a duplicate on every junction.
    private mutating func land(_ index: Int, on landing: Coordinate, _ snap: RouteEditing.Snap) -> Bool {
        let metres = GeoMath.distance(points[index].coordinate, landing)
        guard metres < 1 || (snap.allows(metres) && !points[index].isPinned) else { return false }
        points[index].lat = landing.lat
        points[index].lon = landing.lon
        return true
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
