import Foundation

/// Height along a line: what BaseCamp draws under a route or a track.
///
/// Built from a track's own recording when it has one, since the
/// altimeter rode the road, and from the DEM for a route or a track that
/// was drawn rather than ridden. Metres along and metres up, like
/// everything below the UI.
struct ElevationProfile: Equatable, Sendable {
    struct Sample: Equatable, Sendable {
        var distance: Double
        var elevation: Double
    }

    var samples: [Sample]
    var ascent: Double
    var descent: Double

    var length: Double { samples.last?.distance ?? 0 }
    var minimum: Double { samples.map(\.elevation).min() ?? 0 }
    var maximum: Double { samples.map(\.elevation).max() ?? 0 }

    init(samples: [Sample]) {
        self.samples = samples
        let climb = Self.climb(samples.map(\.elevation))
        ascent = climb.ascent
        descent = climb.descent
    }

    /// Where to sample a path so a profile is smooth and cheap: every
    /// `step` metres along it, the vertices themselves included, and no
    /// more than `limit` points however long the ride.
    ///
    /// A DEM pixel is twenty metres, so sampling finer than that reads
    /// the same pixel twice; a cross-country route at that spacing is a
    /// hundred thousand lookups, which is why there is a ceiling.
    static func stations(along path: [Coordinate], step: Double = 30, limit: Int = 4_000)
        -> [(distance: Double, coordinate: Coordinate)] {
        guard let first = path.first else { return [] }
        let length = GeoMath.length(path)
        let step = max(step, length / Double(limit))
        var out: [(Double, Coordinate)] = [(0, first)]
        var travelled = 0.0
        var nextAt = step
        for (a, b) in zip(path, path.dropFirst()) {
            let leg = GeoMath.distance(a, b)
            guard leg > 0 else { continue }
            while nextAt < travelled + leg {
                let t = (nextAt - travelled) / leg
                out.append((nextAt, Coordinate(lat: a.lat + (b.lat - a.lat) * t, lon: a.lon + (b.lon - a.lon) * t)))
                nextAt += step
            }
            travelled += leg
        }
        if let last = path.last, out.last!.0 < travelled {
            out.append((travelled, last))
        }
        return out.map { (distance: $0.0, coordinate: $0.1) }
    }

    /// A profile from the stations and the heights found at them, with
    /// the unknown ones skipped: a gap in the DEM is a gap in the line,
    /// not a dive to zero.
    static func make(stations: [(distance: Double, coordinate: Coordinate)], elevations: [Double?]) -> ElevationProfile {
        var samples: [Sample] = []
        for (station, elevation) in zip(stations, elevations) {
            if let elevation { samples.append(Sample(distance: station.distance, elevation: elevation)) }
        }
        return ElevationProfile(samples: samples)
    }

    /// A profile from a track's own fixes, where every one has a height.
    /// Nil when fewer than two do, which sends the caller to the DEM.
    static func recorded(_ detail: TrackDetail) -> ElevationProfile? {
        let sorted = detail.points.sorted { $0.seq < $1.seq }
        var samples: [Sample] = []
        var travelled = 0.0
        var previous: TrackPoint?
        for point in sorted {
            if let previous, previous.segment == point.segment {
                travelled += GeoMath.distance(previous.coordinate, point.coordinate)
            }
            if let elevation = point.elevation {
                samples.append(Sample(distance: travelled, elevation: elevation))
            }
            previous = point
        }
        return samples.count >= 2 ? ElevationProfile(samples: samples) : nil
    }

    /// Climb and descent through a noise gate, the one `TrackStatistics`
    /// uses: a rise or fall smaller than five metres is a GPS or a DEM
    /// jittering, and counting every one made a flat ride a mountain.
    static func climb(_ elevations: [Double], noise: Double = TrackStatistics.elevationNoise) -> (ascent: Double, descent: Double) {
        var ascent = 0.0, descent = 0.0
        var reference: Double?
        for elevation in elevations {
            guard let ref = reference else {
                reference = elevation
                continue
            }
            if elevation - ref >= noise {
                ascent += elevation - ref
                reference = elevation
            } else if ref - elevation >= noise {
                descent += ref - elevation
                reference = elevation
            }
        }
        return (ascent, descent)
    }
}
