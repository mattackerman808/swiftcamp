import XCTest
@testable import Swiftcamp

final class SimplifyTests: XCTestCase {
    /// About 111 m per 0.001° of latitude at any longitude.
    private func point(_ lat: Double, _ lon: Double) -> Coordinate { Coordinate(lat: lat, lon: lon) }

    func testEndsAlwaysSurvive() {
        let path = [point(40, -105), point(40.5, -105), point(41, -105)]
        XCTAssertEqual(Simplify.indices(of: path, tolerance: 1_000_000), [0, 2])
        XCTAssertEqual(Simplify.indices(of: [point(40, -105)], tolerance: 1), [0])
        XCTAssertEqual(Simplify.indices(of: [], tolerance: 1), [])
    }

    func testAWanderWithinToleranceIsDropped() {
        // A straight line north with a 5 m wobble east halfway along.
        let path = [point(40, -105), point(40.0005, -104.99994), point(40.001, -105)]
        XCTAssertEqual(Simplify.indices(of: path, tolerance: 10), [0, 2])
        XCTAssertEqual(Simplify.indices(of: path, tolerance: 1), [0, 1, 2])
    }

    func testARealBendSurvivesAndTheFixesAroundItDoNot() {
        // North for a kilometre, then east for a kilometre, with fixes
        // every hundred metres and no wobble.
        var path: [Coordinate] = []
        for i in 0...10 { path.append(point(40 + Double(i) * 0.0009, -105)) }
        for i in 1...10 { path.append(point(40.009, -105 + Double(i) * 0.0012)) }
        let kept = Simplify.indices(of: path, tolerance: 20)
        XCTAssertEqual(kept, [0, 10, 20], "only the corner is a bend")
    }

    func testAtMostRaisesToleranceUntilTheSurvivorsFit() {
        // A zigzag where every point is a 50 m bend.
        var path: [Coordinate] = []
        for i in 0..<200 {
            path.append(point(40 + Double(i) * 0.001, i % 2 == 0 ? -105 : -104.9994))
        }
        XCTAssertGreaterThan(Simplify.indices(of: path, tolerance: 10).count, 50)
        let kept = Simplify.indices(of: path, tolerance: 10, atMost: 50)
        XCTAssertLessThanOrEqual(kept.count, 50)
        XCTAssertEqual(kept.first, 0)
        XCTAssertEqual(kept.last, 199)
        XCTAssertEqual(kept, kept.sorted(), "in path order")
    }
}
