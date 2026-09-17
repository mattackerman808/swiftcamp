import XCTest
@testable import Swiftcamp

/// The edits a route can take, checked on values with no map and no store.
///
/// Every operation has to keep two things true: `seq` matches array order,
/// because that is what a map click reports and the store assumes; and the
/// geometry stored on a via point describes the leg *leaving* it. The second
/// is where reversal and deletion go wrong if they treat geometry as a
/// property of the point rather than of the leg.
final class RouteEditingTests: XCTestCase {
    private let a = Coordinate(lat: 40.0, lon: -105.0)
    private let b = Coordinate(lat: 40.0, lon: -104.0)
    private let c = Coordinate(lat: 41.0, lon: -104.0)
    private let d = Coordinate(lat: 41.0, lon: -105.0)

    /// A shaper that is easy to recognise in the output: one interior point
    /// at the midpoint of each leg.
    private let midpoint: RouteEditing.LegShaper = { from, to in
        [Coordinate(lat: (from.lat + to.lat) / 2, lon: (from.lon + to.lon) / 2)]
    }

    private func route(_ coordinates: [Coordinate], shape: RouteEditing.LegShaper = RouteEditing.straight) -> RouteDetail {
        var detail = RouteDetail(route: Route(name: "Test"), points: [])
        coordinates.forEach { detail.appendVia($0, shape: shape) }
        return detail
    }

    // MARK: - Append

    func testAppendingNumbersPointsInOrder() {
        let detail = route([a, b, c])
        XCTAssertEqual(detail.points.map(\.seq), [0, 1, 2])
        XCTAssertEqual(detail.points.map(\.coordinate), [a, b, c])
        XCTAssertEqual(detail.route.id, detail.points[0].routeID)
    }

    func testAppendingShapesTheLegIntoTheNewPointAndNothingAfterIt() {
        let detail = route([a, b], shape: midpoint)
        XCTAssertEqual(detail.points[0].geometry, [Coordinate(lat: 40.0, lon: -104.5)])
        XCTAssertNil(detail.points[1].geometry, "the last point leads nowhere")
    }

    func testStraightLegsCarryNoGeometry() {
        let detail = route([a, b, c])
        XCTAssertTrue(detail.points.allSatisfy { $0.geometry == nil })
        XCTAssertEqual(detail.path, [a, b, c])
    }

    // MARK: - Insert

    func testInsertingSplitsTheLeg() {
        var detail = route([a, c], shape: midpoint)
        detail.insertVia(b, inLeg: 0, shape: midpoint)

        XCTAssertEqual(detail.points.map(\.coordinate), [a, b, c])
        XCTAssertEqual(detail.points.map(\.seq), [0, 1, 2])
        XCTAssertEqual(detail.points[0].geometry, [Coordinate(lat: 40.0, lon: -104.5)], "a→b reshaped")
        XCTAssertEqual(detail.points[1].geometry, [Coordinate(lat: 40.5, lon: -104.0)], "b→c reshaped")
        XCTAssertNil(detail.points[2].geometry)
    }

    func testInsertingPastTheLastLegAppends() {
        var detail = route([a, b])
        detail.insertVia(c, inLeg: 7)
        XCTAssertEqual(detail.points.map(\.coordinate), [a, b, c])
    }

    // MARK: - Move

    func testMovingReshapesBothAdjacentLegsOnly() {
        var detail = route([a, b, c, d], shape: midpoint)
        let untouched = detail.points[2].geometry
        let moved = Coordinate(lat: 40.5, lon: -104.5)

        detail.moveVia(at: 1, to: moved, shape: midpoint)

        XCTAssertEqual(detail.points[1].coordinate, moved)
        XCTAssertEqual(detail.points[0].geometry, [Coordinate(lat: 40.25, lon: -104.75)], "leg into it")
        XCTAssertEqual(detail.points[1].geometry, [Coordinate(lat: 40.75, lon: -104.25)], "leg out of it")
        XCTAssertEqual(detail.points[2].geometry, untouched, "leg c→d had no reason to change")
    }

    func testMovingAnUnknownIndexIsIgnored() {
        var detail = route([a, b])
        let before = detail
        detail.moveVia(at: 5, to: c)
        XCTAssertEqual(detail, before)
    }

    // MARK: - Remove

    func testRemovingJoinsTheNeighbours() {
        var detail = route([a, b, c], shape: midpoint)
        detail.removeVia(at: 1, shape: midpoint)

        XCTAssertEqual(detail.points.map(\.coordinate), [a, c])
        XCTAssertEqual(detail.points.map(\.seq), [0, 1])
        XCTAssertEqual(detail.points[0].geometry, [Coordinate(lat: 40.5, lon: -104.5)], "a→c is a new leg")
        XCTAssertNil(detail.points[1].geometry)
    }

    /// Removing the end must clear the geometry of the point that is now
    /// last, or the line keeps drawing a leg to a place that is no longer
    /// in the route.
    func testRemovingTheLastPointClearsTheDanglingLeg() {
        var detail = route([a, b, c], shape: midpoint)
        detail.removeVia(at: 2, shape: midpoint)

        XCTAssertEqual(detail.points.count, 2)
        XCTAssertNil(detail.points[1].geometry)
    }

    func testRemovingTheFirstPoint() {
        var detail = route([a, b, c], shape: midpoint)
        detail.removeVia(at: 0, shape: midpoint)
        XCTAssertEqual(detail.points.map(\.coordinate), [b, c])
        XCTAssertEqual(detail.points[0].geometry, [Coordinate(lat: 40.5, lon: -104.0)])
    }

    // MARK: - Reverse

    /// The geometry has to travel with the leg. Reversing only the points
    /// would attach each road shape to the wrong end.
    func testReversingKeepsEachLegsShapeOnTheRightEnd() {
        var detail = route([a, b, c], shape: midpoint)
        let forward = detail.path
        detail.reverse()

        XCTAssertEqual(detail.points.map(\.coordinate), [c, b, a])
        XCTAssertEqual(detail.points.map(\.seq), [0, 1, 2])
        XCTAssertEqual(detail.path, Array(forward.reversed()),
                       "the shaped path reads the same backwards")
        XCTAssertNil(detail.points[2].geometry)
    }

    /// A leg with several interior points has to come out in reverse order,
    /// not merely on the right point.
    func testReversingReversesTheInteriorOfEachLeg() {
        let road = [Coordinate(lat: 40.1, lon: -105.0), Coordinate(lat: 40.2, lon: -105.0)]
        var detail = route([a, b], shape: { _, _ in road })
        detail.reverse()
        XCTAssertEqual(detail.points[0].geometry, Array(road.reversed()))
    }

    func testReversingTwiceIsTheIdentity() {
        var detail = route([a, b, c, d], shape: midpoint)
        let before = detail
        detail.reverse()
        detail.reverse()
        XCTAssertEqual(detail, before)
    }

    // MARK: - Nearest leg

    func testNearestLegFindsTheLegUnderAClick() {
        let detail = route([a, b, c])
        // Just off the a→b leg, which runs along latitude 40.
        XCTAssertEqual(detail.nearestLeg(to: Coordinate(lat: 40.01, lon: -104.5)), 0)
        // Just off the b→c leg, which runs along longitude -104.
        XCTAssertEqual(detail.nearestLeg(to: Coordinate(lat: 40.5, lon: -103.99)), 1)
    }

    /// The line the user sees is the shaped path. A click on a road that
    /// loops away from the straight line between its via points must still
    /// land on that leg.
    func testNearestLegMeasuresTheShapedPathNotTheChord() {
        // Leg a→b bulges north to latitude 40.5; leg b→c is straight.
        let bulge = [Coordinate(lat: 40.5, lon: -104.5)]
        var detail = route([a, b], shape: { _, _ in bulge })
        detail.appendVia(c, shape: RouteEditing.straight)

        // Near the bulge, far from the a→b chord, and nearer the b→c chord
        // than to that chord — the chord would say leg 1.
        XCTAssertEqual(detail.nearestLeg(to: Coordinate(lat: 40.49, lon: -104.49)), 0)
    }

    func testNearestLegIsNilWithoutALeg() {
        XCTAssertNil(route([a]).nearestLeg(to: b))
        XCTAssertNil(route([]).nearestLeg(to: b))
    }

    // MARK: - Segment distance

    func testDistanceToSegmentIsPerpendicularInsideAndToTheEndOutside() {
        let p = Coordinate(lat: 40.0, lon: -104.5)
        // On the segment.
        XCTAssertEqual(GeoMath.distance(p, toSegment: a, b), 0, accuracy: 0.001)
        // One hundredth of a degree of latitude north of it, about 1.1 km.
        let north = Coordinate(lat: 40.01, lon: -104.5)
        XCTAssertEqual(GeoMath.distance(north, toSegment: a, b), 1_111.95, accuracy: 1)
        // Past the western end: measures to `a`, not to the line's extension.
        let west = Coordinate(lat: 40.0, lon: -105.01)
        XCTAssertEqual(GeoMath.distance(west, toSegment: a, b),
                       GeoMath.distance(west, a), accuracy: 1)
    }
}
