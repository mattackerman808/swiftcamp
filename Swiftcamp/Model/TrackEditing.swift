import Foundation

/// The edits a track can take, as pure functions over its points: what
/// BaseCamp's track menu offers, minus moving single fixes, which nobody
/// does to a day's recording.
///
/// Every result is a new track with a new id. A recording is the rider's
/// own evidence of where they went, so an edit makes a track beside it
/// rather than rewriting it; the caller decides whether the original
/// goes, and undo brings it back whole.
extension TrackDetail {
    /// The same line ridden the other way: the points in reverse, the
    /// segments renumbered so the last recorded becomes the first.
    func inverted() -> TrackDetail {
        var out = fresh(name: track.name)
        let sorted = points.sorted { $0.seq < $1.seq }
        let lastSegment = sorted.last?.segment ?? 0
        out.points = sorted.reversed().enumerated().map { seq, point in
            var p = point
            p.id = nil
            p.trackID = out.track.id
            p.seq = seq
            p.segment = lastSegment - point.segment
            return p
        }
        return out
    }

    /// Two tracks from one, cut at point `index`: the first ends there and
    /// the second begins there, so the ride is still covered end to end
    /// with no gap where the cut was. Nil for a cut at either end, which
    /// would leave a track of one point.
    func split(at index: Int) -> (TrackDetail, TrackDetail)? {
        let sorted = points.sorted { $0.seq < $1.seq }
        guard index > 0, index < sorted.count - 1 else { return nil }
        var first = fresh(name: "\(track.name) 1")
        var second = fresh(name: "\(track.name) 2")
        first.points = Self.renumber(Array(sorted[...index]), for: first.track.id)
        second.points = Self.renumber(Array(sorted[index...]), for: second.track.id)
        return (first, second)
    }

    /// One track from several, in the order given: each one's points
    /// follow the last as fresh segments, so the line still breaks
    /// between rides rather than drawing a straight run from one day's
    /// end to the next day's start. Named after the first.
    func joined(with others: [TrackDetail]) -> TrackDetail {
        var out = fresh(name: track.name)
        var combined: [TrackPoint] = []
        var segmentBase = 0
        for detail in [self] + others {
            let sorted = detail.points.sorted { $0.seq < $1.seq }
            guard let first = sorted.first else { continue }
            let lowest = sorted.map(\.segment).min() ?? first.segment
            for point in sorted {
                var p = point
                p.segment = segmentBase + (point.segment - lowest)
                combined.append(p)
            }
            segmentBase = (combined.last?.segment ?? 0) + 1
        }
        out.points = Self.renumber(combined, for: out.track.id)
        return out
    }

    /// The same line with at most `count` fixes, the survivors chosen so
    /// every dropped fix lies within a few metres of the line through its
    /// neighbours; see `Simplify`. Each fix keeps its time and elevation.
    /// Garmin units take 10,000 points per track, which is what this is
    /// for; a track already small enough comes back as a copy.
    ///
    /// Each segment is simplified on its own with its share of the limit,
    /// so a segment is never left as a single fix, which draws nothing;
    /// the breaks stay where the recorder put them.
    func simplified(atMost count: Int) -> TrackDetail {
        guard points.count > count else { return joined(with: []) }
        var out = fresh(name: track.name)
        let sorted = points.sorted { $0.seq < $1.seq }
        let bySegment = Dictionary(grouping: sorted, by: \.segment).sorted { $0.key < $1.key }
        var kept: [TrackPoint] = []
        for (_, segment) in bySegment {
            // Two at least, so a segment is still a line and not a dot;
            // a track of hundreds of one-fix segments may end up over
            // the limit by that much, which is the recorder's doing.
            let budget = max(2, count * segment.count / sorted.count)
            for i in Simplify.indices(of: segment.map(\.coordinate), tolerance: 2, atMost: budget) {
                kept.append(segment[i])
            }
        }
        out.points = Self.renumber(kept, for: out.track.id)
        return out
    }

    /// The fix nearest a spot, by position in `points` sorted by `seq`:
    /// where a click on the line lands, for splitting there.
    func nearestPointIndex(to coordinate: Coordinate) -> Int? {
        let sorted = points.sorted { $0.seq < $1.seq }
        var best: (index: Int, distance: Double)?
        for (i, point) in sorted.enumerated() {
            let d = GeoMath.distance(coordinate, point.coordinate)
            if best == nil || d < best!.distance { best = (i, d) }
        }
        return best?.index
    }

    /// A header like this one's under a new id, with no points yet.
    private func fresh(name: String) -> TrackDetail {
        TrackDetail(track: Track(listID: track.listID, name: name, color: track.color, comment: track.comment),
                    points: [])
    }

    private static func renumber(_ points: [TrackPoint], for trackID: String) -> [TrackPoint] {
        points.enumerated().map { seq, point in
            var p = point
            p.id = nil
            p.trackID = trackID
            p.seq = seq
            return p
        }
    }
}

/// What a recording says about the ride: BaseCamp's track statistics.
///
/// Elapsed and moving time need timestamps, and ascent needs elevations;
/// a track drawn by hand or made from a route has neither, and reports
/// only its length. Metres and seconds, like everything below the UI.
struct TrackStatistics: Equatable, Sendable {
    var distance: Double
    var elapsed: TimeInterval?
    var moving: TimeInterval?
    var ascent: Double?
    var descent: Double?

    /// Over the time spent moving, which is the number a rider compares
    /// between days; the overall average counts lunch.
    var movingSpeed: Double? {
        guard let moving, moving > 0 else { return nil }
        return distance / moving
    }

    /// Slower than this between two fixes counts as stopped. Half a metre
    /// a second is a GPS wandering in a parking lot, not a motorcycle
    /// moving.
    static let stoppedBelow = 0.5

    /// A climb or descent smaller than this is noise. A consumer GPS
    /// reports elevation to a few metres and jitters by that much sitting
    /// still, and summing every jitter made a flat ride into a mountain.
    static let elevationNoise = 5.0

    init(_ detail: TrackDetail) {
        let sorted = detail.points.sorted { $0.seq < $1.seq }
        var distance = 0.0
        var moving = 0.0
        var sawTime = false
        var ascent = 0.0, descent = 0.0
        var reference: Double?
        var previous: TrackPoint?

        for point in sorted {
            if let elevation = point.elevation {
                if let ref = reference {
                    if elevation - ref >= Self.elevationNoise {
                        ascent += elevation - ref
                        reference = elevation
                    } else if ref - elevation >= Self.elevationNoise {
                        descent += ref - elevation
                        reference = elevation
                    }
                } else {
                    reference = elevation
                }
            }
            defer { previous = point }
            // Across a segment break the recorder was off, and the gap is
            // not a ride; the stored length counts the same way.
            guard let previous, previous.segment == point.segment else { continue }
            let metres = GeoMath.distance(previous.coordinate, point.coordinate)
            distance += metres
            // By magnitude: an inverted track runs its clock backwards,
            // and the ride took as long either way.
            if let a = previous.time, let b = point.time {
                let seconds = abs(b.timeIntervalSince(a))
                sawTime = true
                if seconds > 0, metres / seconds >= Self.stoppedBelow { moving += seconds }
            }
        }

        self.distance = distance
        let times = sorted.compactMap(\.time)
        if let first = times.min(), let last = times.max(), sawTime {
            elapsed = last.timeIntervalSince(first)
            self.moving = moving
        }
        if reference != nil {
            self.ascent = ascent
            self.descent = descent
        }
    }
}
