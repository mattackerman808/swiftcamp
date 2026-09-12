import Foundation
import GRDB

/// Reads and writes the library.
///
/// A value type holding the database, constructed at the call site, which is
/// tachbase's store pattern and keeps there from being a second long-lived
/// object beside `AppDatabase`.
///
/// ## Observation, not notifications
///
/// Reads come back as `ValueObservation`s so a view re-renders when its rows
/// change, whoever changed them. This is the one place Swiftcamp deliberately
/// does not follow tachbase, which reloads views from a global notification
/// gated on row count. That design is documented in its own source twice: as
/// a post-mortem of a 4,000-per-second update storm, and as a bug where a
/// change that kept the row count identical never refreshed the list at all.
struct LibraryStore: Sendable {
    var database: AppDatabase

    init(_ database: AppDatabase = .shared) {
        self.database = database
    }

    // MARK: - Reading

    func lists() throws -> [LibraryList] {
        try database.writer.read { db in
            try LibraryList.order(Column("sort_order"), Column("name")).fetchAll(db)
        }
    }

    func routes() throws -> [Route] {
        try database.writer.read { db in
            try Route.order(Column("name")).fetchAll(db)
        }
    }

    func waypoints() throws -> [Waypoint] {
        try database.writer.read { db in
            try Waypoint.order(Column("name")).fetchAll(db)
        }
    }

    func tracks() throws -> [Track] {
        try database.writer.read { db in
            try Track.order(Column("name")).fetchAll(db)
        }
    }

    func routeDetail(id: String) throws -> RouteDetail? {
        try database.writer.read { db in try Self.routeDetail(db, id: id) }
    }

    func trackPoints(trackID: String) throws -> [TrackPoint] {
        try database.writer.read { db in
            try TrackPoint
                .filter(Column("track_id") == trackID)
                .order(Column("seq"))
                .fetchAll(db)
        }
    }

    private static func routeDetail(_ db: Database, id: String) throws -> RouteDetail? {
        guard let route = try Route.fetchOne(db, key: id) else { return nil }
        let points = try RoutePoint
            .filter(Column("route_id") == id)
            .order(Column("seq"))
            .fetchAll(db)
        return RouteDetail(route: route, points: points)
    }

    // MARK: - Observing

    func observeRoutes() -> ValueObservation<ValueReducers.Fetch<[Route]>> {
        ValueObservation.tracking { db in try Route.order(Column("name")).fetchAll(db) }
    }

    func observeWaypoints() -> ValueObservation<ValueReducers.Fetch<[Waypoint]>> {
        ValueObservation.tracking { db in try Waypoint.order(Column("name")).fetchAll(db) }
    }

    func observeTracks() -> ValueObservation<ValueReducers.Fetch<[Track]>> {
        ValueObservation.tracking { db in try Track.order(Column("name")).fetchAll(db) }
    }

    func observeLists() -> ValueObservation<ValueReducers.Fetch<[LibraryList]>> {
        ValueObservation.tracking { db in
            try LibraryList.order(Column("sort_order"), Column("name")).fetchAll(db)
        }
    }

    /// Tracks one route and everything hanging off it, so a drag of a single
    /// via point re-renders the map without the sidebar's route list also
    /// deciding it changed.
    func observeRouteDetail(id: String) -> ValueObservation<ValueReducers.Fetch<RouteDetail?>> {
        ValueObservation.tracking { db in try Self.routeDetail(db, id: id) }
    }

    // MARK: - Writing

    func save(_ list: LibraryList) throws {
        var list = list
        list.updatedAt = .now
        try database.writer.write { db in try list.save(db) }
    }

    func save(_ waypoint: Waypoint) throws {
        var waypoint = waypoint
        waypoint.updatedAt = .now
        try database.writer.write { db in try waypoint.save(db) }
    }

    /// Writes a route and replaces its points, in one transaction.
    ///
    /// `save` rather than an `INSERT OR REPLACE` on the parent row, and this
    /// is not a style preference. `INSERT OR REPLACE` deletes the conflicting
    /// row before inserting, which fires `route_points`' `ON DELETE CASCADE`
    /// and takes the route's geometry with it. tachbase shipped exactly that
    /// bug: a save that also rewrote the points hid the damage by putting
    /// them straight back, so the loss only surfaced on the next edit that
    /// touched the header alone, and the route vanished for no visible
    /// reason. GRDB's `save` updates in place, so the parent row keeps its
    /// identity and the children survive.
    func save(_ detail: RouteDetail) throws {
        var route = detail.route
        route.updatedAt = .now

        try database.writer.write { db in
            try route.save(db)

            // Points are replaced wholesale rather than diffed. A route is
            // tens of via points and the edit that reaches here has usually
            // reordered or resequenced them, which makes a diff more code
            // for no measurable win.
            try RoutePoint.filter(Column("route_id") == route.id).deleteAll(db)
            for (index, point) in detail.points.enumerated() {
                var point = point
                point.id = nil          // let SQLite assign, these are new rows
                point.routeID = route.id
                point.seq = index       // array order is the order, always
                try point.insert(db)
            }
        }
    }

    /// Writes a track and replaces its points, in one transaction.
    func save(_ track: Track, points: [TrackPoint]) throws {
        var track = track
        track.updatedAt = .now

        try database.writer.write { db in
            try track.save(db)
            try TrackPoint.filter(Column("track_id") == track.id).deleteAll(db)
            for (index, point) in points.enumerated() {
                var point = point
                point.id = nil
                point.trackID = track.id
                point.seq = index
                try point.insert(db)
            }
        }
    }

    // MARK: - GPX

    /// Adds everything in a GPX file to the library, in one transaction.
    ///
    /// Import adds; it never replaces. Opening the same file twice really
    /// does produce two copies, because GPX carries no stable identifier for
    /// anything in it and there is nothing to match an existing route
    /// against. Guessing by name would silently overwrite a route the user
    /// had edited, which is worse than a duplicate they can see and delete.
    @discardableResult
    func importGPX(_ document: GPXDocument, into listID: String? = nil) throws -> GPXImportCount {
        try database.writer.write { db in
            for var waypoint in document.waypoints {
                waypoint.listID = listID
                try waypoint.insert(db)
            }

            for detail in document.routes {
                var route = detail.route
                route.listID = listID
                try route.insert(db)
                for (index, point) in detail.points.enumerated() {
                    var point = point
                    point.id = nil
                    point.routeID = route.id
                    point.seq = index
                    try point.insert(db)
                }
            }

            for detail in document.tracks {
                var track = detail.track
                track.listID = listID
                try track.insert(db)
                for (index, point) in detail.points.enumerated() {
                    var point = point
                    point.id = nil
                    point.trackID = track.id
                    point.seq = index
                    try point.insert(db)
                }
            }

            return GPXImportCount(waypoints: document.waypoints.count,
                                  routes: document.routes.count,
                                  tracks: document.tracks.count)
        }
    }

    /// Gathers named items into a document ready to write out.
    ///
    /// Takes explicit id lists rather than a list id, because what the user
    /// selects in the sidebar and what they want in the file are the same
    /// thing, and a folder is only one of the ways to select it.
    func exportGPX(waypointIDs: [String] = [],
                   routeIDs: [String] = [],
                   trackIDs: [String] = []) throws -> GPXDocument {
        try database.writer.read { db in
            var document = GPXDocument(time: .now)

            document.waypoints = try Waypoint.filter(keys: waypointIDs).fetchAll(db)

            for id in routeIDs {
                if let detail = try Self.routeDetail(db, id: id) { document.routes.append(detail) }
            }

            for id in trackIDs {
                guard let track = try Track.fetchOne(db, key: id) else { continue }
                let points = try TrackPoint
                    .filter(Column("track_id") == id)
                    .order(Column("seq"))
                    .fetchAll(db)
                document.tracks.append(TrackDetail(track: track, points: points))
            }

            return document
        }
    }

    // MARK: - Deleting

    func deleteRoute(id: String) throws {
        _ = try database.writer.write { db in try Route.deleteOne(db, key: id) }
    }

    func deleteTrack(id: String) throws {
        _ = try database.writer.write { db in try Track.deleteOne(db, key: id) }
    }

    func deleteWaypoint(id: String) throws {
        _ = try database.writer.write { db in try Waypoint.deleteOne(db, key: id) }
    }

    /// Deleting a folder unfiles what was in it rather than destroying it;
    /// the schema's `ON DELETE SET NULL` is what makes that true.
    func deleteList(id: String) throws {
        _ = try database.writer.write { db in try LibraryList.deleteOne(db, key: id) }
    }
}
