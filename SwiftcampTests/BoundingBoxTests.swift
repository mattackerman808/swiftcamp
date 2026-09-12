import XCTest
@testable import Swiftcamp

/// Framing a selected item.
final class BoundingBoxTests: XCTestCase {
    func testEnclosesEveryPoint() throws {
        let box = try XCTUnwrap(BoundingBox([
            Coordinate(lat: 40.3772, lon: -105.5217),
            Coordinate(lat: 40.2503, lon: -105.8712),
            Coordinate(lat: 40.4000, lon: -105.7000),
        ]))

        XCTAssertEqual(box.north, 40.4000, accuracy: 1e-9)
        XCTAssertEqual(box.south, 40.2503, accuracy: 1e-9)
        XCTAssertEqual(box.west, -105.8712, accuracy: 1e-9)
        XCTAssertEqual(box.east, -105.5217, accuracy: 1e-9)
    }

    /// West is the smaller longitude and east the larger. In the western
    /// hemisphere both are negative, which is exactly where a min/max that
    /// was reasoned about rather than tested comes out swapped.
    func testWestIsWestInTheWesternHemisphere() throws {
        let box = try XCTUnwrap(BoundingBox([
            Coordinate(lat: 40, lon: -105),
            Coordinate(lat: 41, lon: -109),
        ]))
        XCTAssertLessThan(box.west, box.east)
        XCTAssertEqual(box.west, -109, accuracy: 1e-9)
    }

    func testNothingHasNoBox() {
        XCTAssertNil(BoundingBox([]))
    }

    /// One point, or several on the same spot, has no rectangle. Fitting a
    /// degenerate one zooms to the renderer's maximum and drops the user into
    /// a parking lot with no context around it.
    func testASinglePointIsDegenerate() throws {
        let box = try XCTUnwrap(BoundingBox([Coordinate(lat: 40, lon: -105)]))
        XCTAssertTrue(box.isDegenerate)
        XCTAssertEqual(box.center, Coordinate(lat: 40, lon: -105))
    }

    func testARealSpreadIsNotDegenerate() throws {
        let box = try XCTUnwrap(BoundingBox([
            Coordinate(lat: 40, lon: -105),
            Coordinate(lat: 40.001, lon: -105),
        ]))
        XCTAssertFalse(box.isDegenerate)
    }

    // MARK: - What gets framed

    /// A route's box covers its shaped path, not its via points. A road that
    /// loops well off the straight line between two stops must still fit on
    /// screen whole.
    func testRouteBoundsFollowTheShapedPath() throws {
        let route = Route(name: "Detour")
        let detail = RouteDetail(route: route, points: [
            RoutePoint(routeID: route.id, seq: 0, lat: 40.0, lon: -105.0,
                       geometry: [Coordinate(lat: 41.5, lon: -105.0)]),
            RoutePoint(routeID: route.id, seq: 1, lat: 40.0, lon: -104.9),
        ])

        let box = try XCTUnwrap(detail.bounds)
        XCTAssertEqual(box.north, 41.5, accuracy: 1e-9,
                       "the northern loop is part of the route")
    }

    func testTrackBoundsCoverEverySegment() throws {
        let track = Track(name: "Two halves")
        let detail = TrackDetail(track: track, points: [
            TrackPoint(trackID: track.id, seq: 0, segment: 0, lat: 40.0, lon: -105.0),
            TrackPoint(trackID: track.id, seq: 1, segment: 1, lat: 41.0, lon: -106.0),
        ])

        let box = try XCTUnwrap(detail.bounds)
        XCTAssertEqual(box.north, 41.0, accuracy: 1e-9)
        XCTAssertEqual(box.west, -106.0, accuracy: 1e-9)
    }
}
