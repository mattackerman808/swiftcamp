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
}
