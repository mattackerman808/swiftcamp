import XCTest
@testable import Swiftcamp

/// Every way a rider might paste a coordinate into the search field, and
/// the things that must not be mistaken for one.
final class CoordinateParserTests: XCTestCase {
    private let estes = Coordinate(lat: 40.3772, lon: -105.5217)

    private func assertParses(_ text: String, _ expected: Coordinate, accuracy: Double = 0.0001,
                              file: StaticString = #filePath, line: UInt = #line) {
        guard let parsed = CoordinateParser.parse(text) else {
            return XCTFail("\(text) did not parse", file: file, line: line)
        }
        XCTAssertEqual(parsed.lat, expected.lat, accuracy: accuracy, text, file: file, line: line)
        XCTAssertEqual(parsed.lon, expected.lon, accuracy: accuracy, text, file: file, line: line)
    }

    func testDecimalDegrees() {
        assertParses("40.3772, -105.5217", estes)
        assertParses("40.3772 -105.5217", estes)
        assertParses("40.3772,-105.5217", estes)
    }

    func testDecimalDegreesWithHemispheres() {
        assertParses("40.3772 N 105.5217 W", estes)
        assertParses("40.3772N, 105.5217W", estes)
        assertParses("N 40.3772 W 105.5217", estes)
        assertParses("105.5217 W 40.3772 N", estes, accuracy: 0.0001)
    }

    func testDegreesAndDecimalMinutes() {
        assertParses("40 22.632 N 105 31.302 W", estes)
        assertParses("N40 22.632 W105 31.302", estes)
        assertParses("40°22.632'N 105°31.302'W", estes)
    }

    func testDegreesMinutesSeconds() {
        assertParses("40°22'38\"N 105°31'18\"W", estes, accuracy: 0.001)
        assertParses("40 22 38 N 105 31 18 W", estes, accuracy: 0.001)
        assertParses("40 22 38 -105 31 18", estes, accuracy: 0.001)
    }

    func testSouthAndEastAreNegativeAndPositive() {
        assertParses("33.8688 S 151.2093 E", Coordinate(lat: -33.8688, lon: 151.2093))
    }

    func testWhatIsNotACoordinate() {
        XCTAssertNil(CoordinateParser.parse("Estes Park"))
        XCTAssertNil(CoordinateParser.parse("1234 W Elkhorn Ave"))
        XCTAssertNil(CoordinateParser.parse("40.3772"))
        XCTAssertNil(CoordinateParser.parse("95, -105"), "latitude past the pole")
        XCTAssertNil(CoordinateParser.parse("40 75 N 105 W"), "minutes past sixty")
        XCTAssertNil(CoordinateParser.parse(""))
    }

    func testFormatIsFiveDecimals() {
        XCTAssertEqual(CoordinateParser.format(estes), "40.37720, -105.52170")
    }
}
