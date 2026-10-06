import Foundation

/// What a device gets, as distinct from what the library holds: the same
/// document with the two edits BaseCamp offers on the way out.
///
/// **Shaping points stripped.** A zūmo honours `trp:ShapingPoint` and
/// passes one in silence, but an older unit, or one on old firmware,
/// reads every `<rtept>` as a stop and announces each bend as a
/// destination. The road is kept whole: a shaping point's position and
/// the leg leaving it fold into the previous stop's `gpxx:rpt` list, so
/// the device still follows the line that was planned.
///
/// **Tracks limited.** Garmin units take ten thousand points per track
/// and either refuse or truncate a longer one, which on a day's recording
/// of a few hundred thousand fixes means losing the afternoon. Thinning
/// keeps the line within a couple of metres; see `TrackDetail.simplified`.
///
/// **A track beside an off-road route.** A unit routes again on its own
/// map, so a leg along a forest road or trail that map lacks is quietly
/// moved onto roads it has. The route still imports and still looks like
/// a route; it just goes somewhere else. A track is a line the unit draws
/// whatever its map holds, so an Adventure or Direct route also goes out
/// as the track of its planned line, and the rider follows that where the
/// two disagree. Road routes stay on paved ways the unit's map has, and
/// get none: a second line on every road trip would be clutter.
struct DeviceExport: Equatable, Sendable {
    var stripShapingPoints = false
    var trackPointLimit: Int? = garminTrackLimit
    var roadDetail: RoadDetail = .shaping
    var tracksForOffRoadRoutes = true

    /// How much of each leg's road goes into its `gpxx:rpt` list.
    ///
    /// A unit re-routes between every consecutive road point with its own
    /// map, so one point on a road that map lacks, or on a one-way it
    /// disagrees with, fails the whole import as "not routable with the
    /// maps on this device". Our road is OpenStreetMap's, every vertex of
    /// it, 26,800 points on a route across the country; BaseCamp sends a
    /// fraction of that. Fewer points means fewer chances to disagree,
    /// and none means the unit plans its own road between the stops.
    enum RoadDetail: String, CaseIterable, Sendable {
        /// Every vertex, as routed. Works when every one lands on a road
        /// the unit knows, which a 17-mile route did and a 2,600-mile one
        /// never will; see `shaping`, the default.
        case full
        /// The bends that matter, within a couple of hundred metres of
        /// the road, which still holds the unit to the planned road at
        /// every junction that could go another way.
        case sparse
        /// Stops and shaping points only; the unit finds the road.
        case none
        /// The key bends as shaping points, `trp:ShapingPoint` entries
        /// the unit snaps to its own roads and routes between, with no
        /// road list at all. A road point has to sit exactly on a road
        /// the unit knows and one miss fails the import, which a zūmo
        /// XT3 did at 26,800 points and again at 992; a shaping point a
        /// few metres off is harmless. This is how MyRouteApp and
        /// Kurviger hold a Garmin to a planned road.
        case shaping

        var title: String {
            switch self {
            case .full: "Every bend"
            case .sparse: "Key bends"
            case .shaping: "Key bends as shaping points"
            case .none: "Stops only"
            }
        }

        /// Metres a dropped vertex may sit from the line kept.
        static let sparseTolerance = 200.0
        /// For shaping points, which cost the unit a calculation each:
        /// coarser, and no more than this many on a route.
        static let shapingTolerance = 1_000.0
        static let shapingLimit = 100
    }

    /// The point limit Garmin publishes for a track on its automotive and
    /// outdoor units.
    static let garminTrackLimit = 10_000

    static let defaultsKeys = (strip: "exportStripShapingPoints", limit: "exportLimitTracks", road: "exportRoadDetail",
                               offRoadTracks: "exportOffRoadTracks")

    /// As remembered between sends.
    static var stored: DeviceExport {
        let defaults = UserDefaults.standard
        return DeviceExport(stripShapingPoints: defaults.bool(forKey: defaultsKeys.strip),
                            trackPointLimit: defaults.object(forKey: defaultsKeys.limit) == nil
                                || defaults.bool(forKey: defaultsKeys.limit) ? garminTrackLimit : nil,
                            roadDetail: RoadDetail(rawValue: defaults.string(forKey: defaultsKeys.road) ?? "") ?? .shaping,
                            tracksForOffRoadRoutes: defaults.object(forKey: defaultsKeys.offRoadTracks) == nil
                                || defaults.bool(forKey: defaultsKeys.offRoadTracks))
    }

    /// Whether a route's legs may leave the roads a unit's map is sure to
    /// have. Adventure takes tracks and trails, and Direct takes no road
    /// at all, so the unit would re-route either onto pavement.
    static func isOffRoad(_ detail: RouteDetail) -> Bool {
        detail.route.mode != .road
    }

    func apply(to document: GPXDocument) -> GPXDocument {
        var out = document
        // Before the road is thinned: the track is the line as planned,
        // every vertex, which is the point of sending it.
        if tracksForOffRoadRoutes {
            out.tracks += out.routes.filter(Self.isOffRoad).filter { !$0.points.isEmpty }.map(TrackDetail.init(fromRoute:))
        }
        if stripShapingPoints {
            out.routes = out.routes.map { Self.strippingShapingPoints($0) }
        }
        if roadDetail != .full {
            out.routes = out.routes.map { Self.thinningRoad($0, to: roadDetail) }
        }
        if let limit = trackPointLimit {
            out.tracks = out.tracks.map { $0.points.count > limit ? $0.simplified(atMost: limit) : $0 }
        }
        return out
    }

    /// The route with each leg's road thinned, or dropped. The points
    /// themselves are untouched: they are where the rider wants to go.
    static func thinningRoad(_ detail: RouteDetail, to level: RoadDetail) -> RouteDetail {
        if level == .shaping { return shapingPoints(detail) }
        var out = detail
        for i in out.points.indices {
            guard let road = out.points[i].geometry, !road.isEmpty else { continue }
            switch level {
            case .full, .shaping:
                break
            case .none:
                out.points[i].geometry = nil
            case .sparse:
                // Simplified with the leg's two ends in the line, so a
                // bend right after a stop is measured against the stop
                // and not against the first road vertex.
                let next = i + 1 < out.points.count ? out.points[i + 1].coordinate : road[road.count - 1]
                let line = [out.points[i].coordinate] + road + [next]
                let kept = Simplify.indices(of: line, tolerance: RoadDetail.sparseTolerance)
                    .filter { $0 > 0 && $0 < line.count - 1 }
                    .map { line[$0] }
                out.points[i].geometry = kept.isEmpty ? nil : kept
            }
        }
        return out
    }

    /// The route's bends as shaping points between its stops, the road
    /// lists dropped. The whole route's road is simplified as one line
    /// under one budget, so a long leg gets more of the points than a
    /// short one; existing shaping points count as bends like any other.
    static func shapingPoints(_ detail: RouteDetail) -> RouteDetail {
        let sorted = detail.points.sorted { $0.seq < $1.seq }
        guard sorted.count >= 2 else { return detail }
        // Every vertex of the line, tagged with the stop it belongs to:
        // the stop itself, then its road.
        var line: [Coordinate] = []
        var owner: [Int] = []
        var stopAt: [Int: RoutePoint] = [:]
        for (i, point) in sorted.enumerated() {
            if point.isVia || i == 0 || i == sorted.count - 1 {
                stopAt[line.count] = point
            }
            line.append(point.coordinate)
            owner.append(i)
            for c in point.geometry ?? [] {
                line.append(c)
                owner.append(i)
            }
        }
        let stops = Set(stopAt.keys)
        var kept = Set(Simplify.indices(of: line, tolerance: RoadDetail.shapingTolerance,
                                        atMost: RoadDetail.shapingLimit + stops.count))
        kept.formUnion(stops)
        var points: [RoutePoint] = []
        for index in kept.sorted() {
            if let stop = stopAt[index] {
                var p = stop
                p.isVia = true
                p.geometry = nil
                points.append(p)
            } else {
                points.append(RoutePoint(routeID: detail.route.id, seq: 0, lat: line[index].lat, lon: line[index].lon,
                                         isVia: false))
            }
        }
        for i in points.indices { points[i].seq = i }
        var out = detail
        out.points = points
        return out
    }

    /// The route with only its stops, each carrying the whole road to the
    /// next stop. A route that begins or ends with a shaping point keeps
    /// that point as a stop, since a route needs its two ends.
    static func strippingShapingPoints(_ detail: RouteDetail) -> RouteDetail {
        let sorted = detail.points.sorted { $0.seq < $1.seq }
        guard sorted.count > 2 else { return detail }
        var kept: [RoutePoint] = []
        for (i, point) in sorted.enumerated() {
            let isEnd = i == 0 || i == sorted.count - 1
            if point.isVia || isEnd || kept.isEmpty {
                var stop = point
                stop.isVia = true
                kept.append(stop)
            } else {
                // Its position becomes a vertex of the road leaving the
                // stop before it, followed by whatever led away from it.
                var road = kept[kept.count - 1].geometry ?? []
                road.append(point.coordinate)
                road.append(contentsOf: point.geometry ?? [])
                kept[kept.count - 1].geometry = road
            }
        }
        for i in kept.indices { kept[i].seq = i }
        var out = detail
        out.points = kept
        return out
    }
}
