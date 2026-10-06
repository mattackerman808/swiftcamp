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
struct DeviceExport: Equatable, Sendable {
    var stripShapingPoints = false
    var trackPointLimit: Int? = garminTrackLimit
    var roadDetail: RoadDetail = .full

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
        /// Every vertex, as routed.
        case full
        /// The bends that matter, within a couple of hundred metres of
        /// the road, which still holds the unit to the planned road at
        /// every junction that could go another way.
        case sparse
        /// Stops and shaping points only; the unit finds the road.
        case none

        var title: String {
            switch self {
            case .full: "Every bend"
            case .sparse: "Key bends"
            case .none: "Stops only"
            }
        }

        /// Metres a dropped vertex may sit from the line kept.
        static let sparseTolerance = 200.0
    }

    /// The point limit Garmin publishes for a track on its automotive and
    /// outdoor units.
    static let garminTrackLimit = 10_000

    static let defaultsKeys = (strip: "exportStripShapingPoints", limit: "exportLimitTracks", road: "exportRoadDetail")

    /// As remembered between sends.
    static var stored: DeviceExport {
        let defaults = UserDefaults.standard
        return DeviceExport(stripShapingPoints: defaults.bool(forKey: defaultsKeys.strip),
                            trackPointLimit: defaults.object(forKey: defaultsKeys.limit) == nil
                                || defaults.bool(forKey: defaultsKeys.limit) ? garminTrackLimit : nil,
                            roadDetail: RoadDetail(rawValue: defaults.string(forKey: defaultsKeys.road) ?? "") ?? .full)
    }

    func apply(to document: GPXDocument) -> GPXDocument {
        var out = document
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
        var out = detail
        for i in out.points.indices {
            guard let road = out.points[i].geometry, !road.isEmpty else { continue }
            switch level {
            case .full:
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
