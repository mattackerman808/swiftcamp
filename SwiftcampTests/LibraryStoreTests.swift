import GRDB
import XCTest
@testable import Swiftcamp

/// Record round trips and the store's write semantics.
///
/// The round-trip tests are load-bearing beyond their apparent triviality:
/// Swift is camelCase and the schema is snake_case, bridged by GRDB's column
/// strategies rather than by hand-written keys. A property whose name does
/// not convert the way the column is spelled fails here rather than silently
/// reading back nil in the app.
final class LibraryStoreTests: XCTestCase {
    private var store: LibraryStore!

    override func setUpWithError() throws {
        store = LibraryStore(try AppDatabase.inMemory())
    }

    // MARK: - Round trips

    func testWaypointRoundTrips() throws {
        let wpt = Waypoint(name: "Estes Park",
                           lat: 40.3772,
                           lon: -105.5217,
                           elevation: 2293.0,
                           symbol: "Flag, Blue",
                           comment: "fuel",
                           descriptionText: "east entrance")
        try store.save(wpt)

        let read = try XCTUnwrap(try store.waypoints().first)
        XCTAssertEqual(read.id, wpt.id)
        XCTAssertEqual(read.name, "Estes Park")
        XCTAssertEqual(read.lat, 40.3772, accuracy: 1e-9)
        XCTAssertEqual(read.lon, -105.5217, accuracy: 1e-9)
        XCTAssertEqual(read.elevation, 2293.0)
        XCTAssertEqual(read.symbol, "Flag, Blue")
        XCTAssertEqual(read.comment, "fuel")
        XCTAssertEqual(read.descriptionText, "east entrance")
    }

    /// The symbol is the device's vocabulary and is stored verbatim; nil
    /// takes it away rather than writing a name for "none".
    func testWaypointSymbolChanges() throws {
        let wpt = Waypoint(name: "Fuel", lat: 40.0, lon: -105.0, symbol: "Flag, Blue")
        try store.save(wpt)

        try store.setSymbol("Gas Station", forWaypoint: wpt.id)
        XCTAssertEqual(try store.waypoints().first?.symbol, "Gas Station")

        try store.setSymbol(nil, forWaypoint: wpt.id)
        XCTAssertNil(try store.waypoints().first?.symbol)

        try store.setSymbol("Summit", forWaypoint: "no-such-id")
        XCTAssertEqual(try store.waypoints().count, 1)
    }

    func testWaypointFilesIntoAList() throws {
        let list = LibraryList(name: "Colorado 2026")
        try store.save(list)
        try store.save(Waypoint(listID: list.id, name: "Estes Park", lat: 40.37, lon: -105.52))

        XCTAssertEqual(try store.waypoints().first?.listID, list.id,
                       "listID must map to the list_id column")
    }

    /// Shaping geometry survives the JSON column, in order and in the
    /// compact `[lon, lat]` encoding.
    func testRouteGeometryRoundTrips() throws {
        let route = Route(name: "Trail Ridge Road", color: "Magenta")
        let shaping = [Coordinate(lat: 40.371, lon: -105.521),
                       Coordinate(lat: 40.372, lon: -105.523)]
        let detail = RouteDetail(route: route, points: [
            RoutePoint(routeID: route.id, seq: 0, lat: 40.3772, lon: -105.5217,
                       name: "Estes Park", geometry: shaping),
            RoutePoint(routeID: route.id, seq: 1, lat: 40.4000, lon: -105.7500,
                       name: "Grand Lake"),
        ])
        try store.save(detail)

        let read = try XCTUnwrap(try store.routeDetail(id: route.id))
        XCTAssertEqual(read.route.color, "Magenta")
        XCTAssertEqual(read.points.count, 2)
        XCTAssertEqual(read.points[0].name, "Estes Park")
        XCTAssertEqual(read.points[0].geometry, shaping)
        XCTAssertNil(read.points[1].geometry)
    }

    func testGeometryIsStoredAsCompactGeoJSONPairs() throws {
        let route = Route(name: "One leg")
        try store.save(RouteDetail(route: route, points: [
            RoutePoint(routeID: route.id, seq: 0, lat: 40.5, lon: -105.5,
                       geometry: [Coordinate(lat: 41.25, lon: -106.75)]),
        ]))

        let json = try store.database.writer.read { db in
            try String.fetchOne(db, sql: "SELECT geometry FROM route_points LIMIT 1")
        }
        // Longitude first, the order GeoJSON uses and the renderer expects.
        XCTAssertEqual(json, "[[-106.75,41.25]]")
    }

    // MARK: - Write semantics

    /// The bug this guards against is specific. `INSERT OR REPLACE` on the
    /// parent deletes the conflicting row, which cascades the points away.
    /// tachbase shipped it, and it only showed up on a save that did not
    /// also rewrite the children — exactly this shape.
    func testSavingARouteHeaderKeepsItsPoints() throws {
        let route = Route(name: "Trail Ridge Road")
        let points = [
            RoutePoint(routeID: route.id, seq: 0, lat: 40.37, lon: -105.52),
            RoutePoint(routeID: route.id, seq: 1, lat: 40.40, lon: -105.75),
        ]
        try store.save(RouteDetail(route: route, points: points))

        // A header-only edit: rename, same points read back and written out.
        var renamed = try XCTUnwrap(try store.routeDetail(id: route.id))
        renamed.route.name = "Trail Ridge"
        try store.save(renamed)

        let read = try XCTUnwrap(try store.routeDetail(id: route.id))
        XCTAssertEqual(read.route.name, "Trail Ridge")
        XCTAssertEqual(read.points.count, 2, "the points must survive a header edit")
    }

    /// Array position is the order. Sequence numbers exist only at the
    /// database boundary and are assigned on write, so a caller that
    /// reorders an array never has to renumber anything.
    func testSaveRenumbersFromArrayOrder() throws {
        let route = Route(name: "Reordered")
        try store.save(RouteDetail(route: route, points: [
            RoutePoint(routeID: route.id, seq: 99, lat: 40.0, lon: -105.0, name: "first"),
            RoutePoint(routeID: route.id, seq: 7, lat: 41.0, lon: -106.0, name: "second"),
        ]))

        let read = try XCTUnwrap(try store.routeDetail(id: route.id))
        XCTAssertEqual(read.points.map(\.seq), [0, 1])
        XCTAssertEqual(read.points.map(\.name), ["first", "second"])
    }

    func testDeletingARouteTakesItsPoints() throws {
        let route = Route(name: "Doomed")
        try store.save(RouteDetail(route: route, points: [
            RoutePoint(routeID: route.id, seq: 0, lat: 40.0, lon: -105.0),
        ]))

        try store.deleteRoute(id: route.id)

        XCTAssertTrue(try store.routes().isEmpty)
        let orphans = try store.database.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM route_points") ?? -1
        }
        XCTAssertEqual(orphans, 0)
    }

    func testDeletingAListUnfilesRatherThanDestroys() throws {
        let list = LibraryList(name: "Colorado 2026")
        try store.save(list)
        try store.save(Waypoint(listID: list.id, name: "Estes Park", lat: 40.37, lon: -105.52))

        try store.deleteList(id: list.id)

        let read = try XCTUnwrap(try store.waypoints().first)
        XCTAssertNil(read.listID)
    }

    // MARK: - Derived geometry

    /// The one canonical flattening every consumer goes through: via point,
    /// then the geometry leading away from it, then the next via point.
    func testPathInterleavesViaPointsAndShapingGeometry() throws {
        let route = Route(name: "Trail Ridge Road")
        let detail = RouteDetail(route: route, points: [
            RoutePoint(routeID: route.id, seq: 0, lat: 40.0, lon: -105.0,
                       geometry: [Coordinate(lat: 40.1, lon: -105.1),
                                  Coordinate(lat: 40.2, lon: -105.2)]),
            RoutePoint(routeID: route.id, seq: 1, lat: 40.3, lon: -105.3),
        ])

        XCTAssertEqual(detail.path, [
            Coordinate(lat: 40.0, lon: -105.0),
            Coordinate(lat: 40.1, lon: -105.1),
            Coordinate(lat: 40.2, lon: -105.2),
            Coordinate(lat: 40.3, lon: -105.3),
        ])
    }

    /// Distance along the road, not as the crow flies, and measured from
    /// the start so the last point reads as the route's length.
    func testDistancesFromStartFollowTheShapedPath() throws {
        let route = Route(name: "Detour")
        let detail = RouteDetail(route: route, points: [
            RoutePoint(routeID: route.id, seq: 0, lat: 40.0, lon: -105.0,
                       geometry: [Coordinate(lat: 41.0, lon: -105.0)]),
            RoutePoint(routeID: route.id, seq: 1, lat: 40.0, lon: -104.9),
            RoutePoint(routeID: route.id, seq: 2, lat: 40.0, lon: -104.8),
        ])
        let distances = detail.distancesFromStart()

        XCTAssertEqual(distances[0], 0)
        XCTAssertEqual(try XCTUnwrap(distances[1]),
                       GeoMath.length([Coordinate(lat: 40.0, lon: -105.0), Coordinate(lat: 41.0, lon: -105.0),
                                       Coordinate(lat: 40.0, lon: -104.9)]), accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(distances[2]), detail.length, accuracy: 0.001)
    }

    func testLengthFollowsTheShapedPathNotTheViaPoints() throws {
        let route = Route(name: "Detour")
        // Two via points a short way apart, with geometry that loops well
        // north of the straight line between them.
        let detail = RouteDetail(route: route, points: [
            RoutePoint(routeID: route.id, seq: 0, lat: 40.0, lon: -105.0,
                       geometry: [Coordinate(lat: 41.0, lon: -105.0)]),
            RoutePoint(routeID: route.id, seq: 1, lat: 40.0, lon: -104.9),
        ])

        let straight = GeoMath.distance(Coordinate(lat: 40.0, lon: -105.0),
                                        Coordinate(lat: 40.0, lon: -104.9))
        XCTAssertGreaterThan(detail.length, straight * 10,
                             "length must follow the geometry, not the via points")
    }

    // MARK: - Renaming

    func testRenamingWorksForEachKind() throws {
        let route = Route(name: "Untitled")
        try store.save(RouteDetail(route: route, points: [
            RoutePoint(routeID: route.id, seq: 0, lat: 40.0, lon: -105.0),
            RoutePoint(routeID: route.id, seq: 1, lat: 40.5, lon: -105.5),
        ]))
        let track = Track(name: "Track")
        try store.save(track, points: [
            TrackPoint(trackID: track.id, seq: 0, segment: 0, lat: 40, lon: -105),
        ])
        let waypoint = Waypoint(name: "Waypoint", lat: 40, lon: -105)
        try store.save(waypoint)

        try store.rename(route.id, to: "Trail Ridge Road")
        try store.rename(track.id, to: "Sunday ride")
        try store.rename(waypoint.id, to: "Estes Park")

        XCTAssertEqual(try store.routes().first?.name, "Trail Ridge Road")
        XCTAssertEqual(try store.tracks().first?.name, "Sunday ride")
        XCTAssertEqual(try store.waypoints().first?.name, "Estes Park")
    }

    /// A track called nothing is unfindable in a sidebar and exports as a
    /// file with no name, so an empty rename is ignored rather than obeyed.
    func testAnEmptyNameIsRefused() throws {
        let track = Track(name: "Track")
        try store.save(track, points: [])

        try store.rename(track.id, to: "   ")

        XCTAssertEqual(try store.tracks().first?.name, "Track")
    }

    /// Renaming writes the header only. An INSERT OR REPLACE here would
    /// cascade the route's points away.
    func testRenamingARouteKeepsItsPoints() throws {
        let route = Route(name: "Untitled")
        try store.save(RouteDetail(route: route, points: [
            RoutePoint(routeID: route.id, seq: 0, lat: 40.0, lon: -105.0,
                       geometry: [Coordinate(lat: 40.1, lon: -105.1)]),
            RoutePoint(routeID: route.id, seq: 1, lat: 40.5, lon: -105.5),
        ]))

        try store.rename(route.id, to: "Trail Ridge Road")

        let read = try XCTUnwrap(try store.routeDetail(id: route.id))
        XCTAssertEqual(read.points.count, 2)
        XCTAssertEqual(read.points[0].geometry?.count, 1)
    }

    // MARK: - Lists

    func testFilingMovesAnyMixOfKindsAndNilUnfiles() throws {
        let list = LibraryList(name: "Rockies")
        try store.save(list)
        let wpt = Waypoint(name: "Estes", lat: 40, lon: -105)
        try store.save(wpt)
        let route = Route(name: "Loop")
        try store.insert(route)
        let track = Track(name: "Ride")
        try store.save(track, points: [])

        try store.file([wpt.id, route.id, track.id, "no-such-id"], in: list.id)
        XCTAssertEqual(try store.waypoints().first?.listID, list.id)
        XCTAssertEqual(try store.routes().first?.listID, list.id)
        XCTAssertEqual(try store.tracks().first?.listID, list.id)

        try store.file([route.id], in: nil)
        XCTAssertNil(try store.routes().first?.listID)
        XCTAssertEqual(try store.waypoints().first?.listID, list.id, "the others stay filed")
    }

    func testRenamingAList() throws {
        let list = LibraryList(name: "Old")
        try store.save(list)
        try store.rename(list.id, to: "  New  ")
        XCTAssertEqual(try store.lists().first?.name, "New")
    }

    func testNestingRefusesACycle() throws {
        let a = LibraryList(name: "A"), b = LibraryList(name: "B"), c = LibraryList(name: "C")
        try store.save(a); try store.save(b); try store.save(c)
        try store.setParent(a.id, forList: b.id)
        try store.setParent(b.id, forList: c.id)
        func parent(_ id: String) throws -> String? { try store.lists().first { $0.id == id }?.parentID }
        XCTAssertEqual(try parent(c.id), b.id)

        try store.setParent(c.id, forList: a.id)
        XCTAssertNil(try parent(a.id), "A under C would put A under itself")
        try store.setParent(a.id, forList: a.id)
        XCTAssertNil(try parent(a.id))

        try store.setParent(nil, forList: c.id)
        XCTAssertNil(try parent(c.id))
    }

    func testUpdatingARouteHeaderKeepsItsPoints() throws {
        let route = Route(name: "Loop")
        try store.save(RouteDetail(route: route, points: [
            RoutePoint(routeID: route.id, seq: 0, lat: 40, lon: -105),
            RoutePoint(routeID: route.id, seq: 1, lat: 41, lon: -105),
        ]))
        var header = try XCTUnwrap(try store.routes().first)
        header.comment = "fuel at Granby"
        header.color = "Red"
        try store.update(header)

        let read = try XCTUnwrap(try store.routeDetail(id: route.id))
        XCTAssertEqual(read.route.comment, "fuel at Granby")
        XCTAssertEqual(read.route.color, "Red")
        XCTAssertEqual(read.points.count, 2)
    }

    func testUpdatingATrackHeaderKeepsItsPoints() throws {
        let track = Track(name: "Ride")
        try store.save(track, points: [TrackPoint(trackID: track.id, seq: 0, lat: 40, lon: -105)])
        var header = try XCTUnwrap(try store.tracks().first)
        header.comment = "wet"
        try store.update(header)
        XCTAssertEqual(try store.tracks().first?.comment, "wet")
        XCTAssertEqual(try store.trackPoints(trackID: track.id).count, 1)
    }

    // MARK: - Preferences

    func testRoutePreferencesRoundTrip() throws {
        var route = Route(name: "Loop")
        route.preferences.prefer = .manyCurves
        route.preferences.avoidTolls = true
        try store.insert(route)
        XCTAssertEqual(try store.routes().first?.preferences, route.preferences)

        route.preferences.prefer = .shorterDistance
        try store.update(route)
        XCTAssertEqual(try store.routes().first?.preferences.prefer, .shorterDistance)
        XCTAssertEqual(try store.routes().first?.preferences.avoidTolls, true)
    }

    /// A row written before a preference existed holds `{}`, or a JSON
    /// without the new key, and reads with the default for it.
    func testRoutePreferencesDecodeWithMissingFields() throws {
        let empty = try JSONDecoder().decode(RoutePreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, RoutePreferences())
        let partial = try JSONDecoder().decode(RoutePreferences.self, from: Data(#"{"avoidTolls":true}"#.utf8))
        XCTAssertEqual(partial.avoidTolls, true)
        XCTAssertEqual(partial.prefer, .fasterTime)

        try store.database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO routes (id, name, mode, created_at, updated_at)
                VALUES ('old', 'Old', 'road', '2026-01-01', '2026-01-01')
                """)
        }
        XCTAssertEqual(try store.routes().first?.preferences, RoutePreferences(),
                       "the column default is {} and decodes to the defaults")
    }
}
