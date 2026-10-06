import Foundation
import GRDB

/// The library: every waypoint, track and route the user owns, in one SQLite
/// file.
///
/// Swiftcamp is a library app, not a document app — the same shape BaseCamp
/// has. GPX is an interchange format that comes in and goes out; it is never
/// the save format, because a round trip through GPX silently drops anything
/// GPX cannot express.
///
/// ## Migrations are append-only
///
/// Add a new `registerMigration("vN")` block for every schema change and
/// never edit a registered one. A user's file may already have applied the
/// old version, and the migrator only moves forward.
final class AppDatabase: Sendable {
    /// The process-wide library.
    ///
    /// Fatal on failure, following the tachbase precedent: there is no useful
    /// degraded mode for a library app whose library will not open, and
    /// carrying an optional database through every call site to model a case
    /// that means "quit" is worse than quitting.
    static let shared: AppDatabase = {
        do { return try AppDatabase(url: defaultURL()) } catch {
            fatalError("could not open the library at \(String(describing: try? defaultURL())): \(error)")
        }
    }()

    let writer: any DatabaseWriter

    // MARK: - Construction

    convenience init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try self.init(writer: DatabasePool(path: url.path, configuration: Self.configuration))
    }

    /// An empty library in memory, for tests.
    ///
    /// A `DatabaseQueue` rather than a pool because SQLite gives each pool
    /// connection its own private in-memory database, so a pool here would
    /// have readers that could not see what the writer wrote.
    static func inMemory() throws -> AppDatabase {
        try AppDatabase(writer: DatabaseQueue(configuration: configuration))
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// `~/Library/Application Support/<bundle id>/swiftcamp.sqlite`.
    ///
    /// Deliberately not tachbase's `Library/NoCloud/`. That name is an iOS
    /// convention for a directory the system will not reclaim under storage
    /// pressure and iCloud will not back up, and neither pressure exists on
    /// a Mac. Application Support is where a Mac app's own data belongs.
    /// `-SwiftcampLibrary <path>` points this somewhere else.
    ///
    /// Not a user-facing feature. It exists so the snapshot harness can run
    /// against a scratch file: without it, every automated check of what the
    /// map draws would write into the developer's real library and leave
    /// test routes behind in it.
    static func defaultURL() throws -> URL {
        if let override = UserDefaults.standard.string(forKey: "SwiftcampLibrary") {
            return URL(fileURLWithPath: override)
        }

        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil,
                                                  create: true)
        let id = Bundle.main.bundleIdentifier ?? "com.swiftcamp.app.mac"
        return support
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("swiftcamp.sqlite")
    }

    private static var configuration: Configuration {
        var config = Configuration()

        // SQLite ships with foreign keys OFF. Every cascade in the schema
        // below is inert without this.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        // tachbase sets no busy timeout because exactly one iOS process ever
        // touches its file. A Mac app can be launched twice, and the second
        // instance would otherwise take SQLITE_BUSY on the first contended
        // write rather than waiting the moment out.
        config.busyMode = .timeout(5)

        return config
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1_library") { db in
            // Lists are BaseCamp's folders. `parent_id` makes them a tree.
            try db.create(table: "lists") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("parent_id", .text).references("lists", onDelete: .cascade)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "lists_on_parent", on: "lists", columns: ["parent_id"])

            // `list_id` nulls rather than cascades on every item table below.
            // Deleting a folder in BaseCamp does not destroy what was filed
            // in it; the items fall back to the top of the collection. A
            // cascade here would turn tidying up into data loss.
            try db.create(table: "waypoints") { t in
                t.primaryKey("id", .text)
                t.column("list_id", .text).references("lists", onDelete: .setNull)
                t.column("name", .text).notNull()
                t.column("lat", .double).notNull()
                t.column("lon", .double).notNull()
                t.column("elevation", .double)
                t.column("symbol", .text)
                t.column("comment", .text)
                // Not `desc`, which is a SQL keyword. GRDB quotes identifiers,
                // but the first hand-written query that forgets to would fail
                // in a way that reads as a syntax error somewhere else.
                t.column("description_text", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "waypoints_on_list", on: "waypoints", columns: ["list_id"])

            try db.create(table: "tracks") { t in
                t.primaryKey("id", .text)
                t.column("list_id", .text).references("lists", onDelete: .setNull)
                t.column("name", .text).notNull()
                t.column("color", .text)
                t.column("comment", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "tracks_on_list", on: "tracks", columns: ["list_id"])

            // A recorded track is hundreds of thousands of points, so these
            // are rows rather than a blob: the map needs to draw a window of
            // them and the profile needs to scan them.
            try db.create(table: "track_points") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("track_id", .text).notNull()
                    .references("tracks", onDelete: .cascade)
                t.column("seq", .integer).notNull()
                t.column("lat", .double).notNull()
                t.column("lon", .double).notNull()
                t.column("elevation", .double)
                t.column("time", .datetime)
            }
            try db.create(index: "track_points_on_track_seq", on: "track_points",
                          columns: ["track_id", "seq"], unique: true)

            try db.create(table: "routes") { t in
                t.primaryKey("id", .text)
                t.column("list_id", .text).references("lists", onDelete: .setNull)
                t.column("name", .text).notNull()
                t.column("color", .text)
                t.column("comment", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "routes_on_list", on: "routes", columns: ["list_id"])

            // The load-bearing table.
            //
            // A route is via points plus the shaped path between them, and
            // the two are different things. `is_via` marks a point the user
            // placed and named; `geometry` carries the polyline running from
            // it to the next one. Today that polyline is a straight line.
            // When road snapping lands it is the road, and nothing above this
            // column changes — which is the whole reason snapping can be
            // added later without a rewrite.
            //
            // Garmin's format draws the same distinction: `rtept` is a via
            // point and the `gpxx:rpt` list inside its extension is exactly
            // this geometry. Dropping it is what makes a route that looks
            // right on screen import wrong on the device.
            //
            // Stored as JSON rather than shredded into rows because nothing
            // ever queries inside it — the only consumer hands it to the
            // renderer. Same rule tachbase states for `static_geojson.data`.
            try db.create(table: "route_points") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("route_id", .text).notNull()
                    .references("routes", onDelete: .cascade)
                t.column("seq", .integer).notNull()
                t.column("lat", .double).notNull()
                t.column("lon", .double).notNull()
                t.column("name", .text)
                t.column("symbol", .text)
                t.column("is_via", .boolean).notNull().defaults(to: true)
                t.column("geometry", .text)
            }
            try db.create(index: "route_points_on_route_seq", on: "route_points",
                          columns: ["route_id", "seq"], unique: true)
        }

        // A GPX track is a list of *segments*, and the break between them is
        // real: the recorder lost signal, or the rider stopped and started
        // again. Flattening them into one list of points draws a straight
        // line across the gap, which on a touring map is a road that does
        // not exist.
        //
        // A new migration rather than an edit to v1, even though v1 has not
        // shipped to anyone. The rule earns its keep by being unconditional.
        m.registerMigration("v2_track_segments") { db in
            try db.alter(table: "track_points") { t in
                t.add(column: "segment", .integer).notNull().defaults(to: 0)
            }
        }

        // Garmin's activity profile, per route: which ways its legs may use
        // and whether a dropped point moves onto one. Text rather than an
        // integer so a database opened in a debugger reads as words, and so
        // adding a mode never renumbers the others. Every existing route is
        // a road route, which is what it was routed as.
        m.registerMigration("v3_route_mode") { db in
            try db.alter(table: "routes") { t in
                t.add(column: "mode", .text).notNull().defaults(to: "road")
            }
        }

        // A via point made from a waypoint keeps the waypoint's position
        // through every re-route; see RoutePoint.isPinned. Routing now
        // happens after the edit is written, so the exception has to be
        // on the row rather than in the call that made the point.
        m.registerMigration("v4_pinned_points") { db in
            try db.alter(table: "route_points") { t in
                t.add(column: "is_pinned", .boolean).notNull().defaults(to: false)
            }
        }

        // The zūmo's route settings, per route: what the legs optimise
        // for and what they avoid. JSON so the next preference is a field
        // in `RoutePreferences` and not a migration; `{}` rather than
        // NULL so every row decodes, each missing field at its default.
        m.registerMigration("v5_route_preferences") { db in
            try db.alter(table: "routes") { t in
                t.add(column: "preferences", .text).notNull().defaults(to: "{}")
            }
        }

        // A via point made from a waypoint remembers which, so the route
        // follows the waypoint when it is moved or renamed, and the sidebar
        // can draw its symbol. `SET NULL` rather than cascade: deleting a
        // waypoint must not take a stop out of a route, only the link.
        // SQLite allows a foreign key on an added column only when its
        // default is NULL, which this one's is.
        m.registerMigration("v6_point_waypoints") { db in
            try db.alter(table: "route_points") { t in
                t.add(column: "waypoint_id", .text).references("waypoints", onDelete: .setNull)
            }
            try db.create(index: "route_points_on_waypoint", on: "route_points", columns: ["waypoint_id"])
        }

        return m
    }

    /// Number of applied migrations, which is the schema version.
    ///
    /// Monotonic because migrations are append-only, so a file with a higher
    /// count came from a newer build and cannot be opened by this one.
    func appliedMigrationCount() throws -> Int {
        try writer.read { db in try Self.migrator.appliedIdentifiers(db).count }
    }
}
