import XCTest
@testable import Swiftcamp

/// One copy of the great-circle math, so one place to test it.
final class GeoMathTests: XCTestCase {
    private let denver = Coordinate(lat: 39.7392, lon: -104.9903)
    private let grandJunction = Coordinate(lat: 39.0639, lon: -108.5506)

    func testDistanceMatchesAKnownPair() throws {
        // Denver to Grand Junction, great circle, roughly 314 km. The figure
        // is independent of the routed 392 km quoted in the Valhalla spike
        // in docs/data-architecture.md — that one follows I-70.
        let km = GeoMath.distance(denver, grandJunction) / 1000
        XCTAssertEqual(km, 314, accuracy: 2)
    }

    func testDistanceIsSymmetricAndZeroAtAPoint() {
        XCTAssertEqual(GeoMath.distance(denver, grandJunction),
                       GeoMath.distance(grandJunction, denver),
                       accuracy: 1e-6)
        XCTAssertEqual(GeoMath.distance(denver, denver), 0, accuracy: 1e-9)
    }

    func testBearingIsDegreesTrueClockwiseFromNorth() {
        let north = Coordinate(lat: 40.7392, lon: -104.9903)
        let east = Coordinate(lat: 39.7392, lon: -103.9903)
        XCTAssertEqual(GeoMath.bearing(from: denver, to: north), 0, accuracy: 0.5)
        XCTAssertEqual(GeoMath.bearing(from: denver, to: east), 90, accuracy: 0.5)
    }

    /// A westerly bearing is the case that catches a missing wrap:
    /// `truncatingRemainder` keeps the sign of the dividend, so the raw
    /// result here is negative and a compass would read it as nonsense.
    func testWesterlyBearingWrapsIntoRange() {
        let west = Coordinate(lat: 39.7392, lon: -105.9903)
        let bearing = GeoMath.bearing(from: denver, to: west)
        XCTAssertEqual(bearing, 270, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(bearing, 0)
        XCTAssertLessThan(bearing, 360)
    }

    func testLengthSumsTheSegments() {
        let path = [denver, grandJunction, denver]
        XCTAssertEqual(GeoMath.length(path),
                       GeoMath.distance(denver, grandJunction) * 2,
                       accuracy: 1e-6)
        XCTAssertEqual(GeoMath.length([denver]), 0)
        XCTAssertEqual(GeoMath.length([]), 0)
    }

    /// The compact wire form matters: a route's shaping geometry is
    /// thousands of these in one column, and the order is GeoJSON's.
    func testCoordinateEncodesAsLonLatPair() throws {
        let json = try JSONEncoder().encode(Coordinate(lat: 40.25, lon: -105.75))
        XCTAssertEqual(String(decoding: json, as: UTF8.self), "[-105.75,40.25]")

        let back = try JSONDecoder().decode(Coordinate.self, from: json)
        XCTAssertEqual(back, Coordinate(lat: 40.25, lon: -105.75))
    }
}
