import XCTest
@testable import Swiftcamp

/// Track from route and route from track. The thing each has to keep is
/// the line: a rider converts precisely so the device draws what was
/// planned or recorded, not its own idea of it.
final class ConversionTests: XCTestCase {
    private func point(_ lat: Double, _ lon: Double) -> Coordinate { Coordinate(lat: lat, lon: lon) }

    // MARK: - Track from route

    func testTrackFromRouteFollowsTheShapedPath() {
        let route = Route(name: "Trail Ridge", color: "Magenta", comment: "closed in winter")
        let detail = RouteDetail(route: route, points: [
            RoutePoint(routeID: route.id, seq: 0, lat: 40.0, lon: -105.0,
                       geometry: [point(40.1, -105.1), point(40.2, -105.2)]),
            RoutePoint(routeID: route.id, seq: 1, lat: 40.3, lon: -105.3, isVia: false,
                       geometry: [point(40.4, -105.4)]),
            RoutePoint(routeID: route.id, seq: 2, lat: 40.5, lon: -105.5),
        ])

        let track = TrackDetail(fromRoute: detail)
        XCTAssertEqual(track.track.name, "Trail Ridge")
        XCTAssertEqual(track.track.color, "Magenta")
        XCTAssertEqual(track.track.comment, "closed in winter")
        XCTAssertEqual(track.points.map(\.coordinate), detail.path)
        XCTAssertEqual(track.points.map(\.seq), Array(0..<6))
        XCTAssertEqual(Set(track.points.map(\.segment)), [0], "one segment: a route has no gaps")
        XCTAssertEqual(track.points.map(\.trackID), Array(repeating: track.track.id, count: 6))
    }

    // MARK: - Route from track

    /// North for a kilometre, then east, fixes every hundred metres.
    private var cornerTrack: TrackDetail {
        var path: [Coordinate] = []
        for i in 0...10 { path.append(point(40 + Double(i) * 0.0009, -105)) }
        for i in 1...10 { path.append(point(40.009, -105 + Double(i) * 0.0012)) }
        let track = Track(name: "Corner", color: "Blue")
        return TrackDetail(track: track, points: path.enumerated().map { seq, c in
            TrackPoint(trackID: track.id, seq: seq, segment: seq < 5 ? 0 : 1, lat: c.lat, lon: c.lon)
        })
    }

    func testRouteFromTrackKeepsTheWholeLineAsLegGeometry() {
        let track = cornerTrack
        let detail = RouteDetail(fromTrack: track, mode: .road)

        XCTAssertEqual(detail.route.name, "Corner")
        XCTAssertEqual(detail.route.color, "Blue")
        XCTAssertEqual(detail.route.mode, .road)
        XCTAssertEqual(detail.path, track.points.map(\.coordinate),
                       "the route's shaped path is the track, fix for fix, segments joined")
        XCTAssertEqual(detail.points.map(\.seq), Array(detail.points.indices))
        XCTAssertEqual(detail.points.map(\.routeID), Array(repeating: detail.route.id, count: detail.points.count))
    }

    func testRouteFromTrackHasViaEndsAndShapingBends() {
        let detail = RouteDetail(fromTrack: cornerTrack, mode: .road)
        XCTAssertEqual(detail.points.count, 3, "start, the corner, end")
        XCTAssertEqual(detail.points.map(\.isVia), [true, false, true])
        XCTAssertTrue(detail.straightLegs.isEmpty, "every leg carries the track; nothing is left to the router")
    }

    func testRouteFromTrackNeverLeavesALegForTheRouter() {
        // Every fix a sharp bend, so simplification keeps neighbours,
        // which would otherwise produce legs with no geometry.
        var path: [Coordinate] = []
        for i in 0..<12 {
            path.append(point(40 + Double(i) * 0.001, i % 2 == 0 ? -105 : -104.998))
        }
        let track = Track(name: "Zigzag")
        let detail = RouteDetail(fromTrack: TrackDetail(track: track, points: path.enumerated().map {
            TrackPoint(trackID: track.id, seq: $0, lat: $1.lat, lon: $1.lon)
        }), mode: .road)

        XCTAssertEqual(detail.path, path)
        XCTAssertTrue(detail.straightLegs.isEmpty)
        XCTAssertEqual(detail.points.first?.coordinate, path.first)
        XCTAssertEqual(detail.points.last?.coordinate, path.last)
    }

    func testRouteFromATinyTrack() {
        let track = Track(name: "Two")
        let two = RouteDetail(fromTrack: TrackDetail(track: track, points: [
            TrackPoint(trackID: track.id, seq: 0, lat: 40, lon: -105),
            TrackPoint(trackID: track.id, seq: 1, lat: 41, lon: -105),
        ]), mode: .direct)
        XCTAssertEqual(two.points.count, 2)
        XCTAssertEqual(two.points.map(\.isVia), [true, true])

        let one = RouteDetail(fromTrack: TrackDetail(track: track, points: [
            TrackPoint(trackID: track.id, seq: 0, lat: 40, lon: -105),
        ]), mode: .direct)
        XCTAssertEqual(one.points.count, 1)
    }

    func testRouteFromALongTrackHasAtMostTheHandleLimit() {
        var path: [Coordinate] = []
        for i in 0..<2_000 {
            path.append(point(40 + Double(i) * 0.001, i % 2 == 0 ? -105 : -104.9994))
        }
        let track = Track(name: "Long")
        let detail = RouteDetail(fromTrack: TrackDetail(track: track, points: path.enumerated().map {
            TrackPoint(trackID: track.id, seq: $0, lat: $1.lat, lon: $1.lon)
        }), mode: .road)
        XCTAssertLessThanOrEqual(detail.points.count, RouteDetail.handlesFromTrack)
        XCTAssertEqual(detail.path, path)
    }
}
