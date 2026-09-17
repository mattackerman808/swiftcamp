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
    /// at the midpoint of each leg, and each end landing on itself.
    private let midpoint: RouteEditing.LegShaper = { from, to in
        [from, Coordinate(lat: (from.lat + to.lat) / 2, lon: (from.lon + to.lon) / 2), to]
    }

    /// A router whose roads run north–south every hundredth of a degree,
    /// about 850 m apart here: each end lands on the nearest one, and a
    /// point already on a road lands on itself, as with a real router.
    private let gridRoads: RouteEditing.LegShaper = { from, to in
        func land(_ c: Coordinate) -> Coordinate {
            Coordinate(lat: c.lat, lon: (c.lon * 100).rounded() / 100)
        }
        let a = land(from), b = land(to)
        return [a, Coordinate(lat: (a.lat + b.lat) / 2, lon: (a.lon + b.lon) / 2), b]
    }

    /// About sixty metres east of the grid road at -104.5.
    private let nearRoad = Coordinate(lat: 40.5, lon: -104.5007)
    private let onRoad = Coordinate(lat: 40.5, lon: -104.5)

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

    // MARK: - Via and shaping

    /// A point grown by dragging the line is a shaping point: it bends the
    /// route without being a stop. Otherwise it is a point like any other.
    func testAnInsertedPointCanBeAShapingPoint() {
        var detail = route([a, c])
        detail.insertVia(b, inLeg: 0, isVia: false)

        XCTAssertEqual(detail.points.map(\.isVia), [true, false, true])
        XCTAssertEqual(detail.points.map(\.seq), [0, 1, 2])
        XCTAssertEqual(detail.points.map(\.coordinate), [a, b, c])
    }

    /// Converting changes what the device announces and nothing about the
    /// line: both kinds sit on the road.
    func testConvertingAPointKeepsTheLine() {
        var detail = route([a, b, c], shape: midpoint)
        let before = detail.path

        detail.setVia(at: 1, false)
        XCTAssertFalse(detail.points[1].isVia)
        XCTAssertEqual(detail.path, before)

        detail.setVia(at: 1, true)
        XCTAssertTrue(detail.points[1].isVia)
        XCTAssertEqual(detail.path, before)
    }

    /// A bend in the road is not a place, so it has no name to keep or take.
    func testAShapingPointHasNoName() {
        var detail = route([a, b, c])
        detail.rename(at: 1, to: "Lyons")
        XCTAssertEqual(detail.points[1].name, "Lyons")

        detail.setVia(at: 1, false)
        XCTAssertNil(detail.points[1].name)

        detail.rename(at: 1, to: "Lyons")
        XCTAssertNil(detail.points[1].name)
    }

    func testRenamingTrimsAndEmptiesToNoName() {
        var detail = route([a, b])
        detail.rename(at: 0, to: "  Estes Park ")
        XCTAssertEqual(detail.points[0].name, "Estes Park")
        detail.rename(at: 0, to: "   ")
        XCTAssertNil(detail.points[0].name)
    }

    // MARK: - Snapping

    /// A road route wants its points on the road, however far the drop.
    func testSnappingAlwaysMovesADropOntoTheRoad() {
        var detail = route([a, b])
        detail.insertVia(nearRoad, inLeg: 0, snap: .always, shape: gridRoads)

        XCTAssertEqual(detail.points[1].coordinate, onRoad)
        XCTAssertEqual(detail.points[0].coordinate, a, "a point on a road lands on itself")
        XCTAssertEqual(detail.points[0].geometry?.count, 1, "the landing is the point now, not geometry")
    }

    /// Sixty metres off a track is a choice under a tight limit and a near
    /// miss under a looser one. Either way the leg reaches the road, and
    /// an unmoved point keeps the landing so its spur runs to the road.
    func testSnappingWithinALimitKeepsADeliberateOffRoadPoint() {
        var detail = route([a, b])
        detail.insertVia(nearRoad, inLeg: 0, snap: .within(50), shape: gridRoads)

        XCTAssertEqual(detail.points[1].coordinate, nearRoad)
        XCTAssertEqual(detail.points[0].geometry?.last, onRoad, "leg in ends on the road")
        XCTAssertEqual(detail.points[1].geometry?.first, onRoad, "leg out starts on the road")

        detail.moveVia(at: 1, to: nearRoad, snap: .within(100), shape: gridRoads)
        XCTAssertEqual(detail.points[1].coordinate, onRoad)
        XCTAssertEqual(detail.points[0].geometry?.count, 1, "moved, so the landing is no longer geometry")
    }

    func testNeverSnappingKeepsTheDropAndTheLanding() {
        var detail = route([a, b])
        detail.insertVia(nearRoad, inLeg: 0, snap: .never, shape: gridRoads)

        XCTAssertEqual(detail.points[1].coordinate, nearRoad)
        XCTAssertEqual(detail.points[0].geometry?.last, onRoad)
    }

    /// A change of mode routes every leg again under the new rule.
    func testReshapingEveryLegAppliesANewRule() {
        var detail = route([a, nearRoad, b])
        XCTAssertTrue(detail.points.allSatisfy { $0.geometry == nil }, "straight until reshaped")

        detail.reshapeAll(snap: .always, shape: gridRoads)
        XCTAssertEqual(detail.points.map(\.coordinate), [a, onRoad, b])
        XCTAssertEqual(detail.points[0].geometry?.count, 1)
        XCTAssertEqual(detail.points[1].geometry?.count, 1)
        XCTAssertNil(detail.points[2].geometry)

        detail.reshapeAll(snap: .never, shape: RouteEditing.straight)
        XCTAssertTrue(detail.points.allSatisfy { $0.geometry == nil }, "direct drops the road shapes")
        XCTAssertEqual(detail.points.map(\.coordinate), [a, onRoad, b], "and moves nothing")
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
        let bulge = Coordinate(lat: 40.5, lon: -104.5)
        var detail = route([a, b], shape: { from, to in [from, bulge, to] })
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
