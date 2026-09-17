import Foundation

/// One GPX file's contents, in the library's own types.
///
/// There is no separate GPX object model. The record types were shaped
/// around what GPX carries — `Waypoint.symbol` is a Garmin symbol name,
/// `Route.color` is a `gpxx:DisplayColor`, `RoutePoint.geometry` is a
/// `gpxx:rpt` list — so a parallel hierarchy would be the same fields twice
/// with a translation layer between them, which is where fidelity gets lost.
struct GPXDocument: Equatable, Sendable {
    /// The `creator` attribute, which is required by the schema. Garmin
    /// devices have been known to care what it says.
    var creator: String = GPX.creator
    var name: String?
    var descriptionText: String?
    var time: Date?

    var waypoints: [Waypoint] = []
    var routes: [RouteDetail] = []
    var tracks: [TrackDetail] = []

    var isEmpty: Bool { waypoints.isEmpty && routes.isEmpty && tracks.isEmpty }
}

/// Constants shared by the reader and the writer.
enum GPX {
    static let creator = "Swiftcamp"

    static let namespace = "http://www.topografix.com/GPX/1/1"

    /// GPX 1.0. Read but never written.
    ///
    /// Plenty of files in the wild are still 1.0 — it is what older Garmin
    /// units and a lot of web sites emit. Accepting it costs one extra
    /// namespace in a comparison; refusing it would mean a user's existing
    /// library will not open.
    static let legacyNamespace = "http://www.topografix.com/GPX/1/0"

    /// Garmin's `GpxExtensions` v3. The one that matters: it carries route
    /// shaping points, display colour, and waypoint display mode.
    static let garminExtensions = "http://www.garmin.com/xmlschemas/GpxExtensions/v3"

    /// Garmin's `TripExtensions`. It says which route points are stops and
    /// which only shape the road: a `trp:ViaPoint` is announced by the
    /// device, a `trp:ShapingPoint` is passed in silence. BaseCamp writes
    /// one or the other into every `<rtept>`, and a route exported without
    /// them arrives with every bend announced as a destination.
    static let garminTripExtensions = "http://www.garmin.com/xmlschemas/TripExtensions/v1"

    /// Swiftcamp's own, for what Garmin's vocabulary cannot say. Today that
    /// is one word: whether a motorcycling route is road or adventure,
    /// which the trip's transportation mode does not distinguish. A device
    /// or BaseCamp skips it as a namespace it does not know, exactly as
    /// this reader skips theirs.
    static let swiftcampExtensions = "http://swiftcamp.app/xmlschemas/GpxExtensions/v1"

    /// Garmin's `TrackPointExtension`, for per-point sensor data.
    ///
    /// Recognised so the reader can skip it knowingly rather than trip over
    /// it. Heart rate and cadence are not touring data and are not stored.
    static let garminTrackPointExtensions = "http://www.garmin.com/xmlschemas/TrackPointExtension/v1"

    static func isGPXNamespace(_ uri: String?) -> Bool {
        uri == namespace || uri == legacyNamespace
    }
}

enum GPXError: LocalizedError, Equatable {
    case notGPX
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .notGPX:
            return "This file is not GPX."
        case .malformed(let detail):
            return "This GPX file could not be read: \(detail)"
        }
    }
}

/// A one-line description of what is in a GPX file.
///
/// Exists for the device browser. A folder of archived track logs named
/// `4.gpx` and `18.gpx` tells the rider nothing at all; when each one covers
/// a specific few days and a specific distance, it becomes their history.
struct GPXSummary: Equatable, Sendable {
    var tracks = 0
    var routes = 0
    var waypoints = 0
    var start: Date?
    var end: Date?
    /// Metres, along tracks and the shaped path of routes.
    var distance: Double = 0

    var isEmpty: Bool { tracks == 0 && routes == 0 && waypoints == 0 }
}

extension GPXDocument {
    var summary: GPXSummary {
        var out = GPXSummary(tracks: tracks.count,
                             routes: routes.count,
                             waypoints: waypoints.count)

        let times = tracks.flatMap { $0.points.compactMap(\.time) }
        out.start = times.min() ?? time
        out.end = times.max() ?? time

        out.distance = tracks.reduce(0) { $0 + $1.length }
                     + routes.reduce(0) { $0 + $1.length }
        return out
    }
}

/// What an import added, and what it is called.
///
/// The ids are here so the window can frame what just arrived. Importing a
/// route and being left looking at wherever the map already was is the
/// version of this feature that makes a user think nothing happened.
struct GPXImportResult: Sendable {
    var count: GPXImportCount
    var ids: [String]
}

/// What an import added, for the message shown afterwards.
struct GPXImportCount: Equatable, Sendable {
    var waypoints = 0
    var routes = 0
    var tracks = 0

    var total: Int { waypoints + routes + tracks }
    var isEmpty: Bool { total == 0 }
}
