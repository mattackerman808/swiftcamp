import XCTest
@testable import Swiftcamp

final class MeasurementTests: XCTestCase {
    private let estes = Coordinate(lat: 40.3772, lon: -105.5217)
    private let lyons = Coordinate(lat: 40.2247, lon: -105.2714)
    private let boulder = Coordinate(lat: 40.0150, lon: -105.2705)

    func testNothingMeasuresNothing() {
        var m = Measurement()
        XCTAssertEqual(m.total, 0)
        XCTAssertNil(m.lastLeg)
        XCTAssertNil(m.direct)
        m.add(estes)
        XCTAssertEqual(m.total, 0)
        XCTAssertNil(m.lastLeg, "one point is not a leg")
    }

    func testLegsAddUpAndTheLastOneHasABearing() throws {
        var m = Measurement()
        m.add(estes); m.add(lyons); m.add(boulder)
        XCTAssertEqual(m.total, GeoMath.distance(estes, lyons) + GeoMath.distance(lyons, boulder), accuracy: 0.01)
        let last = try XCTUnwrap(m.lastLeg)
        XCTAssertEqual(last.distance, GeoMath.distance(lyons, boulder), accuracy: 0.01)
        XCTAssertEqual(last.bearing, 180, accuracy: 1, "Lyons to Boulder is due south")
        XCTAssertEqual(try XCTUnwrap(m.direct), GeoMath.distance(estes, boulder), accuracy: 0.01)
    }

    func testDeleteTakesTheLastPointBack() {
        var m = Measurement()
        m.add(estes); m.add(lyons)
        m.removeLast()
        XCTAssertEqual(m.points, [estes])
        m.removeLast(); m.removeLast()
        XCTAssertTrue(m.points.isEmpty)
    }
}
