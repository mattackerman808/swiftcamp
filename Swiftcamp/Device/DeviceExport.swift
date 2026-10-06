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

    /// The point limit Garmin publishes for a track on its automotive and
    /// outdoor units.
    static let garminTrackLimit = 10_000

    static let defaultsKeys = (strip: "exportStripShapingPoints", limit: "exportLimitTracks")

    /// As remembered between sends.
    static var stored: DeviceExport {
        let defaults = UserDefaults.standard
        return DeviceExport(stripShapingPoints: defaults.bool(forKey: defaultsKeys.strip),
                            trackPointLimit: defaults.object(forKey: defaultsKeys.limit) == nil
                                || defaults.bool(forKey: defaultsKeys.limit) ? garminTrackLimit : nil)
    }

    func apply(to document: GPXDocument) -> GPXDocument {
        var out = document
        if stripShapingPoints {
            out.routes = out.routes.map { Self.strippingShapingPoints($0) }
        }
        if let limit = trackPointLimit {
            out.tracks = out.tracks.map { $0.points.count > limit ? $0.simplified(atMost: limit) : $0 }
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
