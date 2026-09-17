import XCTest
@testable import Swiftcamp

/// What gets handed to the renderer.
///
/// Testable without a renderer, which is the point of building it here
/// rather than in JavaScript. `CLAUDE.md` warns that synthetic checks lie
/// about cartography, so these assert structure and identity — the things a
/// screenshot cannot check — and the map itself is verified on the map.
final class OverlayGeoJSONTests: XCTestCase {
    private func route(named name: String = "Trail Ridge Road",
                       color: String? = nil) -> RouteDetail {
        let route = Route(name: name, color: color)
        return RouteDetail(route: route, points: [
            RoutePoint(routeID: route.id, seq: 0, lat: 40.0, lon: -105.0, name: "Estes Park",
                       geometry: [Coordinate(lat: 40.1, lon: -105.1)]),
            RoutePoint(routeID: route.id, seq: 1, lat: 40.2, lon: -105.2, name: "Grand Lake"),
        ])
    }

    // MARK: - Routes

    /// The line follows the shaped path, not the via points. Once snapping
    /// lands that is the only difference between a road and a straight line,
    /// and this is where it shows.
    func testRouteLineFollowsTheShapedPath() throws {
        let collection = OverlayGeoJSON.routeLines([route()])
        let feature = try XCTUnwrap(collection.features.first)

        guard case .lineString(let path) = feature.geometry else {
            return XCTFail("a route draws as a LineString")
        }
        XCTAssertEqual(path, [
            Coordinate(lat: 40.0, lon: -105.0),
            Coordinate(lat: 40.1, lon: -105.1),
            Coordinate(lat: 40.2, lon: -105.2),
        ])
    }

    func testARouteTooShortToDrawIsOmitted() {
        let route = Route(name: "One point")
        let detail = RouteDetail(route: route, points: [
            RoutePoint(routeID: route.id, seq: 0, lat: 40.0, lon: -105.0),
        ])
        XCTAssertTrue(OverlayGeoJSON.routeLines([detail]).features.isEmpty)
    }

    /// Road geometry is not a handle. A Colorado leg carries thousands of
    /// vertices between two points; drawing a grabbable dot on each would be
    /// unusable.
    func testRoadGeometryDoesNotBecomeHandles() {
        let collection = OverlayGeoJSON.handles([route()])

        XCTAssertEqual(collection.features.count, 2)
        XCTAssertEqual(collection.features.map(\.properties.name), ["Estes Park", "Grand Lake"])
    }

    /// A shaping point is a handle too, since it can be grabbed, and says
    /// so, since the style draws it differently.
    func testShapingPointsAreHandlesMarkedAsSuch() {
        var detail = route()
        detail.points[1].isVia = false
        let collection = OverlayGeoJSON.handles([detail])

        XCTAssertEqual(collection.features.count, 2)
        XCTAssertEqual(collection.features.map(\.properties.via), [true, false])
    }

    func testSelectionIsAPropertyNotASeparateSource() throws {
        let detail = route()
        let selected = OverlayGeoJSON.handle(detail.route.id, 1)
        let collection = OverlayGeoJSON.handles([detail], selected: [selected])

        XCTAssertEqual(collection.features.map(\.properties.selected), [false, true])
    }

    /// A click has to say which via point of which route it hit, and the
    /// database row id is not available: saving a route rewrites every point.
    func testViaPointsCarryEnoughToIdentifyThemselves() throws {
        let detail = route()
        let feature = try XCTUnwrap(OverlayGeoJSON.handles([detail]).features.last)

        XCTAssertEqual(feature.properties.id, detail.route.id)
        XCTAssertEqual(feature.properties.seq, 1)
    }

    /// The readout under the pointer needs the exact position and how far
    /// along the road the point is; the renderer's own geometry for a hit
    /// is quantised to the tile grid.
    func testHandlesCarryPositionAndDistanceFromStart() throws {
        let detail = route()
        let features = OverlayGeoJSON.handles([detail]).features

        XCTAssertEqual(features.map(\.properties.lat), [40.0, 40.2])
        XCTAssertEqual(features.map(\.properties.lon), [-105.0, -105.2])
        XCTAssertEqual(features[0].properties.distance, 0)
        let expected = GeoMath.length(detail.path)
        XCTAssertEqual(try XCTUnwrap(features[1].properties.distance), expected, accuracy: 0.001)
    }

    // MARK: - Tracks

    /// One line per segment. Joining them draws a straight line across a
    /// recording gap, which on a touring map is a road that does not exist.
    func testEachTrackSegmentIsItsOwnLine() {
        let track = Track(name: "Recorded ride")
        let detail = TrackDetail(track: track, points: [
            TrackPoint(trackID: track.id, seq: 0, segment: 0, lat: 40.0, lon: -105.0),
            TrackPoint(trackID: track.id, seq: 1, segment: 0, lat: 40.1, lon: -105.1),
            TrackPoint(trackID: track.id, seq: 2, segment: 1, lat: 41.0, lon: -106.0),
            TrackPoint(trackID: track.id, seq: 3, segment: 1, lat: 41.1, lon: -106.1),
        ])

        let collection = OverlayGeoJSON.trackLines([detail])
        XCTAssertEqual(collection.features.count, 2)
    }

    func testASegmentOfOnePointIsNotALine() {
        let track = Track(name: "Stuttering")
        let detail = TrackDetail(track: track, points: [
            TrackPoint(trackID: track.id, seq: 0, segment: 0, lat: 40.0, lon: -105.0),
            TrackPoint(trackID: track.id, seq: 1, segment: 1, lat: 41.0, lon: -106.0),
            TrackPoint(trackID: track.id, seq: 2, segment: 1, lat: 41.1, lon: -106.1),
        ])

        XCTAssertEqual(OverlayGeoJSON.trackLines([detail]).features.count, 1)
    }

    // MARK: - Colour

    func testRouteColourReachesTheFeature() throws {
        let collection = OverlayGeoJSON.routeLines([route(color: "Magenta")])
        XCTAssertEqual(collection.features.first?.properties.color,
                       ItemColor.named("Magenta")?.hex)
    }

    // MARK: - Encoding

    func testEncodesAsGeoJSON() throws {
        let json = try OverlayGeoJSON.routeLines([route(color: "Blue")]).json()

        XCTAssertTrue(json.contains(#""type":"FeatureCollection""#))
        XCTAssertTrue(json.contains(#""type":"LineString""#))
        // Longitude first, as GeoJSON requires and the renderer assumes.
        XCTAssertTrue(json.contains("[-105,40]"))
    }

    func testEmptyCollectionsEncodeCleanly() throws {
        let json = try OverlayGeoJSON.routeLines([]).json()
        XCTAssertEqual(json, #"{"features":[],"type":"FeatureCollection"}"#)
    }

    /// Identical content must produce identical bytes, so a push that
    /// changes nothing can be skipped by comparing strings rather than
    /// walking structures on every SwiftUI invalidation.
    func testEncodingIsStableForIdenticalContent() throws {
        let detail = route(color: "Magenta")
        XCTAssertEqual(try OverlayGeoJSON.routeLines([detail]).json(),
                       try OverlayGeoJSON.routeLines([detail]).json())
    }

    func testPropertiesOmitNilsRatherThanWritingNull() throws {
        let json = try OverlayGeoJSON.routeLines([route()]).json()
        XCTAssertFalse(json.contains("null"), "a long collection should not carry nulls")
    }

    // MARK: - Thinning

    /// Display only. A long segment is thinned before it reaches the
    /// renderer, but the stored track and the exported file keep every point.
    func testLongSegmentsAreThinnedForDisplay() {
        let dense = (0..<50_000).map { Coordinate(lat: 40 + Double($0) * 1e-6, lon: -105) }
        let thin = OverlayGeoJSON.thinned(dense)

        XCTAssertLessThan(thin.count, dense.count / 10)
        XCTAssertEqual(thin.first, dense.first)
        XCTAssertEqual(thin.last, dense.last, "a thinned ride must still end where it ended")
    }

    func testShortSegmentsAreLeftAlone() {
        let path = (0..<100).map { Coordinate(lat: 40 + Double($0) * 1e-4, lon: -105) }
        XCTAssertEqual(OverlayGeoJSON.thinned(path), path)
    }

    func testThinningKeepsPointsInOrder() {
        let dense = (0..<20_000).map { Coordinate(lat: 40 + Double($0) * 1e-6, lon: -105) }
        let thin = OverlayGeoJSON.thinned(dense, limit: 50)

        XCTAssertEqual(thin, thin.sorted { $0.lat < $1.lat })
        XCTAssertLessThanOrEqual(thin.count, 51, "the kept last point is the only overshoot")
    }
}
