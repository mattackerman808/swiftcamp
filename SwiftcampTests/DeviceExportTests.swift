import XCTest
@testable import Swiftcamp

/// What leaves for a device, against what the library holds.
final class DeviceExportTests: XCTestCase {
    private func c(_ lat: Double, _ lon: Double) -> Coordinate { Coordinate(lat: lat, lon: lon) }

    /// Stop, bend, bend, stop, bend, stop: the bends fold into the road.
    private var route: RouteDetail {
        let route = Route(name: "Loop")
        return RouteDetail(route: route, points: [
            RoutePoint(routeID: route.id, seq: 0, lat: 40.0, lon: -105.0, name: "Start", geometry: [c(40.05, -105.0)]),
            RoutePoint(routeID: route.id, seq: 1, lat: 40.1, lon: -105.0, isVia: false, geometry: [c(40.15, -105.0)]),
            RoutePoint(routeID: route.id, seq: 2, lat: 40.2, lon: -105.0, isVia: false),
            RoutePoint(routeID: route.id, seq: 3, lat: 40.3, lon: -105.0, name: "Lunch", geometry: [c(40.35, -105.0)]),
            RoutePoint(routeID: route.id, seq: 4, lat: 40.4, lon: -105.0, isVia: false, geometry: [c(40.45, -105.0)]),
            RoutePoint(routeID: route.id, seq: 5, lat: 40.5, lon: -105.0, name: "End"),
        ])
    }

    func testStrippingKeepsTheStopsAndTheWholeRoad() {
        let original = route
        let stripped = DeviceExport.strippingShapingPoints(original)

        XCTAssertEqual(stripped.points.map(\.name), ["Start", "Lunch", "End"])
        XCTAssertEqual(stripped.points.map(\.seq), [0, 1, 2])
        XCTAssertTrue(stripped.points.allSatisfy(\.isVia))
        XCTAssertEqual(stripped.path, original.path, "the line the device follows is unchanged")
        XCTAssertEqual(stripped.points[0].geometry, [c(40.05, -105.0), c(40.1, -105.0), c(40.15, -105.0), c(40.2, -105.0)])
        XCTAssertEqual(stripped.points[1].geometry, [c(40.35, -105.0), c(40.4, -105.0), c(40.45, -105.0)])
        XCTAssertNil(stripped.points[2].geometry)
    }

    func testAShapingPointAtEitherEndBecomesAStop() {
        var detail = route
        detail.points[0].isVia = false
        detail.points[5].isVia = false
        let stripped = DeviceExport.strippingShapingPoints(detail)
        XCTAssertEqual(stripped.points.count, 3)
        XCTAssertTrue(stripped.points.first!.isVia)
        XCTAssertTrue(stripped.points.last!.isVia)
        XCTAssertEqual(stripped.path, detail.path)
    }

    func testOptionsOffLeaveTheDocumentAlone() {
        let document = GPXDocument(routes: [route])
        XCTAssertEqual(DeviceExport(stripShapingPoints: false, trackPointLimit: nil).apply(to: document), document)
    }

    func testTheTrackLimitThinsOnlyLongTracks() {
        let track = Track(name: "Long")
        let points = (0..<50).map { i in
            TrackPoint(trackID: track.id, seq: i, lat: 40 + Double(i) * 0.001 + (i % 2 == 0 ? 0 : 0.000001), lon: -105)
        }
        let short = TrackDetail(track: Track(name: "Short"), points: Array(points.prefix(5)))
        let document = GPXDocument(tracks: [TrackDetail(track: track, points: points), short])

        let out = DeviceExport(stripShapingPoints: false, trackPointLimit: 10).apply(to: document)
        XCTAssertLessThanOrEqual(out.tracks[0].points.count, 10)
        XCTAssertEqual(out.tracks[0].track.name, "Long")
        XCTAssertEqual(out.tracks[1], short, "under the limit, untouched")
    }

    func testTheDefaultsAreBaseCampsDefaults() {
        let export = DeviceExport()
        XCTAssertFalse(export.stripShapingPoints, "a zūmo honours shaping points")
        XCTAssertEqual(export.trackPointLimit, 10_000)
    }
}
