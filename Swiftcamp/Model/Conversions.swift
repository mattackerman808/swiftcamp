import Foundation

/// A route from a track, and a track from a route: the two conversions
/// BaseCamp offers and riders lean on.
///
/// **Track from route** is how a rider defeats a device's re-routing. A
/// route is a set of stops and the device's own idea of the road between
/// them, which it is free to recalculate on import or on a missed turn. A
/// track is just a line, and a navigator draws it exactly. Riders who have
/// been re-routed off the road they planned convert every route before a
/// trip.
///
/// **Route from track** is the other direction: a ride someone recorded, or
/// a line drawn elsewhere, becomes something the device can navigate. The
/// route keeps the track's exact shape as its legs' geometry, so what goes
/// to the device is the line that was recorded, not a re-route between a
/// handful of points. A few of the track's points survive as shaping points
/// to give the line handles; dragging one re-routes only its two legs.
extension TrackDetail {
    /// Every coordinate of the route's shaped path as one segment. A route
    /// has no gaps in it, so neither does the track.
    init(fromRoute detail: RouteDetail) {
        let track = Track(listID: detail.route.listID,
                          name: detail.route.name,
                          color: detail.route.color,
                          comment: detail.route.comment)
        self.init(track: track, points: detail.path.enumerated().map { seq, c in
            TrackPoint(trackID: track.id, seq: seq, lat: c.lat, lon: c.lon)
        })
    }
}

extension RouteDetail {
    /// How many points of a track survive as handles on the route made
    /// from it, at most. Enough to grab the line anywhere on a day's ride,
    /// few enough that the dots do not become the line.
    static let handlesFromTrack = 50

    /// The track's shape as a route: first and last fixes as via points,
    /// the survivors of a simplification between them as shaping points,
    /// and the stretch of track between each pair stored as that leg's
    /// geometry, so nothing about the line changes.
    ///
    /// Segments are joined. A route cannot have a gap, and a track whose
    /// recording paused at lunch is still one ride.
    init(fromTrack detail: TrackDetail, mode: RoutingMode) {
        let route = Route(listID: detail.track.listID,
                          name: detail.track.name,
                          color: detail.track.color,
                          comment: detail.track.comment,
                          mode: mode)
        let path = detail.points.sorted { $0.seq < $1.seq }.map(\.coordinate)
        guard path.count >= 2 else {
            self.init(route: route, points: path.enumerated().map { seq, c in
                RoutePoint(routeID: route.id, seq: seq, lat: c.lat, lon: c.lon)
            })
            return
        }

        // A hundred metres to start with: on a road it keeps every real
        // bend and drops the GPS wander along a straight.
        var kept = Simplify.indices(of: path, tolerance: 100, atMost: Self.handlesFromTrack)

        // No two handles on consecutive fixes. A leg with nothing between
        // its ends stores no geometry, and a leg with no geometry is one the
        // router fills in; a sharp bend two fixes long would be re-routed
        // on the road while the rest of the line stayed the recording.
        // Dropping the second handle loses nothing: the fix it sat on
        // becomes the first vertex of the previous leg.
        var compact = [kept[0]]
        for i in kept.dropFirst() where i > compact[compact.count - 1] + 1 {
            compact.append(i)
        }
        let last = path.count - 1
        if compact[compact.count - 1] != last {
            // The last fix is always the route's end. A handle on the fix
            // before it gives way rather than the end.
            if compact.count > 1, compact[compact.count - 1] == last - 1 { compact.removeLast() }
            compact.append(last)
        }
        kept = compact
        var points: [RoutePoint] = []
        for (n, i) in kept.enumerated() {
            let isEnd = n == 0 || n == kept.count - 1
            var point = RoutePoint(routeID: route.id, seq: n, lat: path[i].lat, lon: path[i].lon,
                                   isVia: isEnd)
            if n + 1 < kept.count {
                let between = path[(i + 1)..<kept[n + 1]]
                point.geometry = between.isEmpty ? nil : Array(between)
            }
            points.append(point)
        }
        self.init(route: route, points: points)
    }
}
