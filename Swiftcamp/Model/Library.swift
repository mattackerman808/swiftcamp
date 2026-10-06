import Foundation
import GRDB

/// The library's record types.
///
/// ## Identifiers are UUID strings, not `UUID`
///
/// GRDB stores a `UUID` as a 16-byte blob, which is compact and completely
/// unreadable from `sqlite3`. Being able to open the file and look at it is
/// part of why GRDB was chosen over SwiftData in the first place, so these
/// are `String` columns holding a UUID's string form. `newID()` is the only
/// place one is minted.
///
/// ## Column names
///
/// Swift is camelCase and the schema is snake_case, bridged once on
/// `LibraryRecord` rather than by naming Swift properties after columns the
/// way tachbase does, or by hand-writing `CodingKeys` on six types.
protocol LibraryRecord: Codable, FetchableRecord, PersistableRecord {}

extension LibraryRecord {
    static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .custom { key in ColumnNaming.column(for: key.stringValue) }
    }

    static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .custom { column in ColumnKey(stringValue: ColumnNaming.property(for: column)) }
    }
}

/// Converts between camelCase properties and snake_case columns.
///
/// The stock `.convertToSnakeCase` / `.convertFromSnakeCase` pair is **not**
/// symmetric over a trailing acronym, and this schema is full of them.
/// `routeID` encodes to `route_id` and `route_id` decodes back to `routeId`,
/// which is a different key.
///
/// The half of that which hurts is the silent half. A non-optional property
/// throws "key not found" and you find it immediately; an optional one
/// simply reads back `nil`, so a waypoint saved into a folder comes out
/// unfiled and nothing anywhere reports a problem.
///
/// These two functions are inverse over every name in the schema, which
/// `ColumnNamingTests` pins down.
enum ColumnNaming {
    /// `listID` to `list_id`, `descriptionText` to `description_text`.
    ///
    /// A run of capitals is one word, so `ID` becomes `_id` rather than
    /// `_i_d`.
    static func column(for property: String) -> String {
        var out = ""
        var characters = Array(property)
        var i = 0
        while i < characters.count {
            guard characters[i].isUppercase else {
                out.append(characters[i])
                i += 1
                continue
            }
            var run = ""
            while i < characters.count, characters[i].isUppercase {
                run.append(characters[i])
                i += 1
            }
            out.append("_")
            out.append(run.lowercased())
        }
        return out
    }

    /// `list_id` to `listID`, `description_text` to `descriptionText`.
    ///
    /// A segment that is exactly `id` capitalises whole, which is the case
    /// the stock strategy gets wrong.
    static func property(for column: String) -> String {
        let parts = column.split(separator: "_").map(String.init)
        guard let first = parts.first else { return column }
        return parts.dropFirst().reduce(first) { out, part in
            out + (part == "id" ? "ID" : part.capitalized)
        }
    }
}

/// A `CodingKey` built from a string, which the decoding strategy needs and
/// the standard library does not provide.
struct ColumnKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// A fresh identifier.
func newID() -> String { UUID().uuidString }

// MARK: - Lists

/// A folder. BaseCamp calls these lists, and they nest.
struct LibraryList: LibraryRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "lists"

    var id: String = newID()
    var name: String
    var parentID: String?
    var sortOrder: Int = 0
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

// MARK: - Waypoints

/// A single named point. Standalone `<wpt>` in GPX.
struct Waypoint: LibraryRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "waypoints"

    var id: String = newID()
    var listID: String?
    var name: String
    var lat: Double
    var lon: Double
    var elevation: Double?
    /// Garmin symbol name, e.g. `Flag, Blue`. Carried through verbatim on
    /// import rather than mapped to an internal enum: the set is large,
    /// device-specific, and losing an unrecognised one would quietly change
    /// what the user sees on their GPS after a round trip.
    var symbol: String?
    var comment: String?
    var descriptionText: String?
    /// Kept off the map. See `Visibility`.
    var isHidden: Bool = false
    var createdAt: Date = .now
    var updatedAt: Date = .now

    var coordinate: Coordinate { Coordinate(lat: lat, lon: lon) }
}

// MARK: - Tracks

/// A recorded breadcrumb trail. `<trk>` in GPX.
struct Track: LibraryRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "tracks"

    var id: String = newID()
    var listID: String?
    var name: String
    var color: String?
    var comment: String?
    /// Kept off the map. See `Visibility`.
    var isHidden: Bool = false
    var createdAt: Date = .now
    var updatedAt: Date = .now
}

/// One fix in a track.
///
/// Rows rather than a blob on the parent, unlike route geometry, because a
/// recorded track runs to hundreds of thousands of points and both the map
/// and any future elevation profile need to read a window of them.
struct TrackPoint: LibraryRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "track_points"

    /// Assigned by SQLite. Track points have no identity worth preserving
    /// across a rewrite, unlike via points, which the user names and drags.
    var id: Int64?
    var trackID: String
    var seq: Int
    /// Which `<trkseg>` this point came from. Points are numbered across the
    /// whole track, so `seq` stays a single ordering and this only says
    /// where the line breaks.
    var segment: Int = 0
    var lat: Double
    var lon: Double
    var elevation: Double?
    var time: Date?

    var coordinate: Coordinate { Coordinate(lat: lat, lon: lon) }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Routes

/// A planned route. `<rte>` in GPX.
struct Route: LibraryRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "routes"

    var id: String = newID()
    var listID: String?
    var name: String
    /// Garmin's `gpxx:DisplayColor`, e.g. `Magenta`. Same reasoning as
    /// `Waypoint.symbol`: a name from their vocabulary, carried verbatim.
    var color: String?
    var comment: String?
    var mode: RoutingMode = .road
    /// What the legs optimise for and what they keep off. Stored as JSON
    /// in one column: nothing queries inside it, and a new preference
    /// should not need a migration.
    var preferences: RoutePreferences = RoutePreferences()
    /// Kept off the map. See `Visibility`.
    var isHidden: Bool = false
    var createdAt: Date = .now
    var updatedAt: Date = .now

    /// Everything that changes how a leg is routed, as one string, so a
    /// routing answer can be told stale and a refused leg remembered
    /// against the settings that refused it.
    var routingKey: String { "\(mode.rawValue):\(preferences.key)" }
}

/// What a route's legs optimise for, and which kinds of road they keep
/// off. The zūmo's own route settings, kept on the route rather than in a
/// preference so a library can hold a fast commute and a Sunday ride.
///
/// `prefer` is Garmin's calculation mode with the curvy setting split in
/// two, because one level of curvy was measured to be too coarse: on the
/// Estes Park to Boulder leg the router either stayed on US 36 or went
/// over the Peak to Peak Highway, with nothing between. Some Curves takes
/// the canyon road when it costs a few minutes; Many Curves goes looking
/// for the ride.
struct RoutePreferences: Codable, Hashable, Sendable {
    enum Preference: String, Codable, CaseIterable, Sendable {
        case fasterTime, shorterDistance, someCurves, manyCurves

        var title: String {
            switch self {
            case .fasterTime: "Faster Time"
            case .shorterDistance: "Shorter Distance"
            case .someCurves: "Some Curves"
            case .manyCurves: "Many Curves"
            }
        }

        /// Garmin's `trp:CalculationMode`, which a zūmo honours on
        /// import. Both curvy levels are its one Curvy Roads.
        var garminCalculationMode: String {
            switch self {
            case .fasterTime: "FasterTime"
            case .shorterDistance: "ShorterDistance"
            case .someCurves, .manyCurves: "CurvyRoads"
            }
        }

        /// Valhalla's `use_curvature`, from the patched motorcycle
        /// costing. Measured on the Colorado graph: below 0.45 the Estes
        /// Park to Boulder leg stays on US 36 with a small change of
        /// canyon, above it the router takes the Peak to Peak Highway.
        var curvature: Double {
            switch self {
            case .fasterTime, .shorterDistance: 0
            case .someCurves: 0.4
            case .manyCurves: 1
            }
        }
    }

    var prefer: Preference = .fasterTime
    var avoidHighways = false
    var avoidTolls = false
    var avoidFerries = false

    init() {}

    /// Every field optional in the JSON, so a route written before a
    /// preference existed reads with the default for it rather than
    /// failing to decode at all.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        prefer = try c.decodeIfPresent(Preference.self, forKey: .prefer) ?? .fasterTime
        avoidHighways = try c.decodeIfPresent(Bool.self, forKey: .avoidHighways) ?? false
        avoidTolls = try c.decodeIfPresent(Bool.self, forKey: .avoidTolls) ?? false
        avoidFerries = try c.decodeIfPresent(Bool.self, forKey: .avoidFerries) ?? false
    }

    /// The avoided kinds by name, in a fixed order, for the file and the
    /// sidebar.
    var avoided: [String] {
        [avoidHighways ? "highways" : nil, avoidTolls ? "tolls" : nil, avoidFerries ? "ferries" : nil]
            .compactMap { $0 }
    }

    /// Sets the avoided kinds from their names; unknown words are ignored.
    mutating func setAvoided(_ names: [String]) {
        avoidHighways = names.contains("highways")
        avoidTolls = names.contains("tolls")
        avoidFerries = names.contains("ferries")
    }

    var key: String { prefer.rawValue + ":" + avoided.joined(separator: ",") }

    /// The `UserDefaults` key holding the preferences a new route starts
    /// with, as JSON.
    static let defaultKey = "defaultRoutePreferences"

    static var stored: RoutePreferences {
        guard let data = UserDefaults.standard.data(forKey: defaultKey),
              let prefs = try? JSONDecoder().decode(RoutePreferences.self, from: data) else { return RoutePreferences() }
        return prefs
    }

    func store() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.defaultKey)
    }
}

/// How a route's legs are found, and where a dropped point lands.
///
/// Garmin's activity profile by another name. It lives on the route rather
/// than in a setting because a library holds both kinds of ride, and it
/// travels in the file as the trip's transportation mode so a device
/// recalculates the way the planner did rather than the way it feels like.
enum RoutingMode: String, Codable, CaseIterable, Sendable {
    /// Paved ways the map knows, and a dropped point moves onto the
    /// nearest one however far. What BaseCamp and Google Maps do.
    case road
    /// Any way the map knows, unpaved and tracks included. A dropped point
    /// moves onto a way only when one is close, so a near miss lands on
    /// the track and a deliberate point in the scrub stays put with a
    /// straight leg to the nearest way.
    case adventure
    /// Straight lines between points and no routing at all: Garmin's
    /// off-road profile, for a trail no map knows.
    case direct

    var title: String {
        switch self {
        case .road: "Road"
        case .adventure: "Adventure"
        case .direct: "Direct"
        }
    }

    /// The `UserDefaults` key for the mode a new route starts in.
    static let defaultKey = "defaultRoutingMode"
}

/// A point along a route.
///
/// The distinction this type exists to carry: `isVia` marks a point the user
/// placed and can name and drag, and `geometry` is the shaped path running
/// from it to the next via point. Today that path is a straight line. When
/// road snapping lands it is the road, and nothing above this type changes.
///
/// Garmin draws the same line. An `<rtept>` is a via point, and the
/// `<gpxx:rpt>` list inside its extension is precisely this geometry — which
/// is why a BaseCamp route arrives on a device following the road the
/// planner chose rather than being re-routed from scratch.
struct RoutePoint: LibraryRecord, Identifiable, Hashable, Sendable {
    static let databaseTableName = "route_points"

    var id: Int64?
    var routeID: String
    var seq: Int
    var lat: Double
    var lon: Double
    var name: String?
    var symbol: String?
    var isVia: Bool = true
    /// Stays where it was placed whatever the route's mode: a via point
    /// made from a waypoint is a campsite or a trailhead, not a spot on
    /// the road, and the leg runs to the road from there as BaseCamp draws
    /// it. Every other point moves onto the road its legs landed on.
    var isPinned: Bool = false
    /// The waypoint this via point was made from, when it was. BaseCamp's
    /// route points *are* waypoints, which is how a renamed or moved
    /// campsite moves the route that visits it; here the point keeps its
    /// own copy of the name, symbol and position and follows the waypoint
    /// through this link. Nulled when the waypoint is deleted, so the
    /// route keeps its stop and loses only the connection. Not in the GPX:
    /// Garmin's format has no such reference, and a `<rtept>` with the
    /// waypoint's name and symbol is the convention instead.
    var waypointID: String?
    /// Stored as JSON in one column because nothing ever queries inside it;
    /// the only consumer hands it to the renderer. `Coordinate` encodes as
    /// `[lon, lat]`, so this is compact and already GeoJSON-shaped.
    var geometry: [Coordinate]?

    var coordinate: Coordinate { Coordinate(lat: lat, lon: lon) }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// A track and its points.
struct TrackDetail: Identifiable, Hashable, Sendable {
    var track: Track
    var points: [TrackPoint]

    var id: String { track.id }

    /// One polyline per segment, so the renderer never joins across a gap
    /// where the recording stopped.
    var segments: [[Coordinate]] {
        Dictionary(grouping: points.sorted { $0.seq < $1.seq }, by: \.segment)
            .sorted { $0.key < $1.key }
            .map { $0.value.map(\.coordinate) }
    }

    var length: Double { segments.reduce(0) { $0 + GeoMath.length($1) } }

    var bounds: BoundingBox? { BoundingBox(points.map(\.coordinate)) }
}

/// A route and its points, which is the only useful unit above the store.
struct RouteDetail: Identifiable, Hashable, Sendable {
    var route: Route
    var points: [RoutePoint]

    var id: String { route.id }

    /// Every coordinate the route passes through, via points and shaping
    /// geometry interleaved in order.
    ///
    /// One canonical flattening, which everything downstream — the map line,
    /// the length, a future elevation profile — goes through. tachbase names
    /// the equivalent function as the thing that stops consumers from each
    /// deriving a slightly different path.
    var path: [Coordinate] {
        points.sorted { $0.seq < $1.seq }.flatMap { point -> [Coordinate] in
            // The via point itself, then whatever leads away from it. The
            // next via point supplies its own coordinate, so geometry must
            // not repeat it or every junction gets a duplicate vertex.
            [point.coordinate] + (point.geometry ?? [])
        }
    }

    var viaPoints: [RoutePoint] {
        points.filter(\.isVia).sorted { $0.seq < $1.seq }
    }

    /// Length in metres along the shaped path, not via point to via point.
    var length: Double { GeoMath.length(path) }

    /// How far along the road each point is, in metres from the start,
    /// keyed by `seq`. What a rider planning fuel and lunch wants beside a
    /// stop, in the sidebar and under the pointer alike.
    func distancesFromStart() -> [Int: Double] {
        let sorted = points.sorted { $0.seq < $1.seq }
        var out: [Int: Double] = [:]
        var travelled = 0.0
        for (i, point) in sorted.enumerated() {
            out[point.seq] = travelled
            if i + 1 < sorted.count {
                travelled += GeoMath.length([point.coordinate] + (point.geometry ?? []) + [sorted[i + 1].coordinate])
            }
        }
        return out
    }

    /// Over the shaped path, not the via points: a route that loops well off
    /// the straight line between two stops must still fit on screen whole.
    var bounds: BoundingBox? { BoundingBox(path) }
}
