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

    /// Creates a route with no points yet. Editing fills it in.
    func insert(_ route: Route) throws {
        var route = route
        route.createdAt = .now
        route.updatedAt = .now
        try database.writer.write { db in try route.insert(db) }
    }

    /// Replaces a route's points and leaves its header alone.
    ///
    /// This is what every edit of the line goes through. The editor works
    /// on an in-memory copy of the points while the sidebar may be renaming
    /// or recolouring the same route, and `save(_ detail:)` would write the
    /// editor's stale copy of the header over that change.
    func replacePoints(routeID: String, with points: [RoutePoint]) throws {
        try database.writer.write { db in
            guard var route = try Route.fetchOne(db, key: routeID) else { return }
            route.updatedAt = .now
            try route.update(db)

            try RoutePoint.filter(Column("route_id") == routeID).deleteAll(db)
            for (index, point) in points.enumerated() {
                var point = point
                point.id = nil
                point.routeID = routeID
                point.seq = index
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

    /// Removes some tracks and writes others in one transaction: a split,
    /// a join or a simplification, which must not leave the library with
    /// both halves or neither if the app dies between two writes.
    func replaceTracks(deleting ids: [String], inserting details: [TrackDetail]) throws {
        try database.writer.write { db in
            for id in ids { _ = try Track.deleteOne(db, key: id) }
            for detail in details {
                var track = detail.track
                track.updatedAt = .now
                try track.save(db)
                for (index, point) in detail.points.enumerated() {
                    var point = point
                    point.id = nil
                    point.trackID = track.id
                    point.seq = index
                    try point.insert(db)
                }
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
    func importGPX(_ document: GPXDocument, into listID: String? = nil) throws -> GPXImportResult {
        try database.writer.write { db in
            var ids: [String] = []
            var importedWaypoints: [String: [String]] = [:]
            var importedRoutes: [String: [String]] = [:]
            var importedTracks: [String: [String]] = [:]

            for var waypoint in document.waypoints {
                waypoint.listID = listID
                try waypoint.insert(db)
                ids.append(waypoint.id)
                importedWaypoints[waypoint.name, default: []].append(waypoint.id)
            }

            // Anything arriving without a colour gets one, counting on from
            // what is already in the library so two imports in a row do not
            // both start at magenta. A file that names its own colour keeps
            // it: that is the author's choice and ours to preserve.
            var nextColor = try Route.fetchCount(db) + Track.fetchCount(db)

            for detail in document.routes {
                var route = detail.route
                route.listID = listID
                if ItemColor.named(route.color) == nil {
                    route.color = ItemColor.default(for: nextColor).name
                    nextColor += 1
                }
                try route.insert(db)
                ids.append(route.id)
                importedRoutes[route.name, default: []].append(route.id)
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
                if ItemColor.named(track.color) == nil {
                    track.color = ItemColor.default(for: nextColor).name
                    nextColor += 1
                }
                try track.insert(db)
                ids.append(track.id)
                importedTracks[track.name, default: []].append(track.id)
                for (index, point) in detail.points.enumerated() {
                    var point = point
                    point.id = nil
                    point.trackID = track.id
                    point.seq = index
                    try point.insert(db)
                }
            }

            try Self.file(document, importedWaypointIDs: importedWaypoints,
                          routeIDs: importedRoutes, trackIDs: importedTracks, in: db)

            return GPXImportResult(count: GPXImportCount(waypoints: document.waypoints.count,
                                                         routes: document.routes.count,
                                                         tracks: document.tracks.count),
                                   ids: ids)
        }
    }

    /// Recreates the document's lists, parents before children, and files
    /// the members it names in them, matched by name among the items this
    /// import just made and never against the rest of the library. A name
    /// in two lists lands in the first; an item can be in one list here.
    /// An item nobody names stays where `listID` put it.
    private static func file(_ document: GPXDocument,
                             importedWaypointIDs: [String: [String]],
                             routeIDs: [String: [String]],
                             trackIDs: [String: [String]],
                             in db: Database) throws {
        guard !document.lists.isEmpty else { return }
        var idByName: [String: String] = [:]
        var pending = document.lists
        var order = try LibraryList.fetchCount(db)
        // Each pass creates the lists whose parent exists; a list whose
        // parent is never created goes to the top rather than nowhere.
        while !pending.isEmpty {
            let ready = pending.filter { $0.parent == nil || idByName[$0.parent!] != nil }
            let batch = ready.isEmpty ? pending.map { var l = $0; l.parent = nil; return l } : ready
            for imported in batch {
                let list = LibraryList(name: imported.name, parentID: imported.parent.flatMap { idByName[$0] },
                                       sortOrder: order)
                order += 1
                try list.insert(db)
                idByName[imported.name] = list.id
            }
            let done = Set(batch.map(\.name))
            pending.removeAll { done.contains($0.name) }
        }

        var filed: Set<String> = []
        func file(_ table: String, _ names: [String], _ ids: [String: [String]], listID: String) throws {
            for name in names {
                guard let id = ids[name]?.first(where: { !filed.contains($0) }) else { continue }
                filed.insert(id)
                try db.execute(sql: "UPDATE \(table) SET list_id = ? WHERE id = ?", arguments: [listID, id])
            }
        }
        for imported in document.lists {
            guard let listID = idByName[imported.name] else { continue }
            try file("waypoints", imported.members.waypoints, importedWaypointIDs, listID: listID)
            try file("routes", imported.members.routes, routeIDs, listID: listID)
            try file("tracks", imported.members.tracks, trackIDs, listID: listID)
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

    /// Recolours a route or a track.
    ///
    /// Writes the header only. The points are untouched, which `save` makes
    /// safe — an `INSERT OR REPLACE` here would cascade them away.
    func setColor(_ color: ItemColor, forRoute id: String) throws {
        try database.writer.write { db in
            guard var route = try Route.fetchOne(db, key: id) else { return }
            route.color = color.name
            route.updatedAt = .now
            try route.update(db)
        }
    }

    func setMode(_ mode: RoutingMode, forRoute id: String) throws {
        try database.writer.write { db in
            guard var route = try Route.fetchOne(db, key: id) else { return }
            route.mode = mode
            route.updatedAt = .now
            try route.update(db)
        }
    }

    func setColor(_ color: ItemColor, forTrack id: String) throws {
        try database.writer.write { db in
            guard var track = try Track.fetchOne(db, key: id) else { return }
            track.color = color.name
            track.updatedAt = .now
            try track.update(db)
        }
    }

    /// Renames a route, track or waypoint.
    ///
    /// Header-only, which `save` makes safe; an `INSERT OR REPLACE` here
    /// would cascade a route's points away.
    func rename(_ id: String, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        try database.writer.write { db in
            if var route = try Route.fetchOne(db, key: id) {
                route.name = trimmed
                route.updatedAt = .now
                try route.update(db)
            } else if var track = try Track.fetchOne(db, key: id) {
                track.name = trimmed
                track.updatedAt = .now
                try track.update(db)
            } else if var waypoint = try Waypoint.fetchOne(db, key: id) {
                waypoint.name = trimmed
                waypoint.updatedAt = .now
                try waypoint.update(db)
            } else if var list = try LibraryList.fetchOne(db, key: id) {
                list.name = trimmed
                list.updatedAt = .now
                try list.update(db)
            }
        }
    }

    /// Writes a route's header and leaves its points alone: the inspector's
    /// fields, name and notes and colour, none of which touch the line.
    /// `update`, not `save`, so a route that has gone meanwhile is not
    /// re-created from a stale copy.
    func update(_ route: Route) throws {
        var route = route
        route.updatedAt = .now
        try database.writer.write { db in try route.update(db) }
    }

    /// The same for a track.
    func update(_ track: Track) throws {
        var track = track
        track.updatedAt = .now
        try database.writer.write { db in try track.update(db) }
    }

    // MARK: - Lists

    /// Files items into a list, or with nil takes them out of whichever
    /// list they were in. One statement per table rather than a lookup per
    /// id: the ids may be any mix of the three kinds, and an id no table
    /// knows matches nothing.
    func file(_ ids: [String], in listID: String?) throws {
        guard !ids.isEmpty else { return }
        try database.writer.write { db in
            for table in ["waypoints", "routes", "tracks"] {
                try db.execute(sql: """
                    UPDATE \(table) SET list_id = ?, updated_at = ?
                    WHERE id IN (\(databaseQuestionMarks(count: ids.count)))
                    """, arguments: [listID, Date.now] + StatementArguments(ids))
            }
        }
    }

    /// Moves a list under another, or with nil to the top. A list cannot
    /// go under itself or under one of its own descendants; that would
    /// detach the whole branch from the tree, and the request is ignored.
    func setParent(_ parentID: String?, forList id: String) throws {
        try database.writer.write { db in
            guard var list = try LibraryList.fetchOne(db, key: id) else { return }
            var ancestor = parentID
            while let current = ancestor {
                if current == id { return }
                ancestor = try LibraryList.fetchOne(db, key: current)?.parentID
            }
            list.parentID = parentID
            list.updatedAt = .now
            try list.update(db)
        }
    }

    /// Sets a waypoint's Garmin symbol; nil for none. Header-only, like
    /// `rename`, and the name is stored verbatim for the same reason the
    /// reader keeps it: it is the device's vocabulary, not ours.
    func setSymbol(_ symbol: String?, forWaypoint id: String) throws {
        try database.writer.write { db in
            guard var waypoint = try Waypoint.fetchOne(db, key: id) else { return }
            waypoint.symbol = symbol
            waypoint.updatedAt = .now
            try waypoint.update(db)
        }
    }

    /// Takes items off the map or puts them back, whichever kind each is.
    /// `updated_at` is left alone: hiding is a view of the library, not an
    /// edit to it, and a sort by date should not shuffle for it.
    func setHidden(_ hidden: Bool, forIDs ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try database.writer.write { db in
            for table in ["routes", "tracks", "waypoints"] {
                let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
                try db.execute(sql: "UPDATE \(table) SET is_hidden = ? WHERE id IN (\(marks))",
                               arguments: StatementArguments([hidden] + ids))
            }
        }
    }

    // MARK: - Backup and restore

    /// Writes the whole library to a file, consistent as of this moment.
    ///
    /// `VACUUM INTO` is SQLite's own copy: a transaction-consistent image
    /// of every page, compacted, written by the engine rather than by
    /// copying a file another connection may be writing. It refuses to
    /// run inside a transaction, hence the bare connection.
    func backup(to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try database.writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
    }

    /// Replaces everything in the library with the contents of a backup.
    ///
    /// The backup is copied aside and migrated first, so a file from an
    /// older build comes up to this schema before its rows are read, and
    /// the user's own file is never touched. Then one transaction: the
    /// backup attached, every table emptied and refilled from it, in an
    /// order that satisfies the foreign keys. Row by row through the
    /// engine rather than swapping files underneath an open pool, so the
    /// observations see one change and the app carries on.
    func restore(from url: URL) throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftcamp-restore-\(UUID().uuidString)", isDirectory: true)
        let copy = staging.appendingPathComponent("backup.sqlite")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: url, to: copy)
        // Migrates on open, and refuses a file that is not a library.
        _ = try AppDatabase(url: copy)

        try database.writer.writeWithoutTransaction { db in
            try db.execute(sql: "ATTACH DATABASE ? AS backup", arguments: [copy.path])
            defer { try? db.execute(sql: "DETACH DATABASE backup") }
            try db.inTransaction {
                // Lists reference their parents in no particular row
                // order, so the check waits for the commit.
                try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
                let tables = ["route_points", "routes", "track_points", "tracks", "waypoints", "lists"]
                for table in tables {
                    try db.execute(sql: "DELETE FROM \(table)")
                }
                for table in tables.reversed() {
                    try db.execute(sql: "INSERT INTO \(table) SELECT * FROM backup.\(table)")
                }
                return .commit
            }
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
