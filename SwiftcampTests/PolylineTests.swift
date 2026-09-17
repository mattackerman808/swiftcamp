import XCTest
@testable import Swiftcamp

final class PolylineTests: XCTestCase {
    /// Google's own documented example, at their 1e5 precision.
    func testDecodesTheReferenceExampleAtGooglePrecision() {
        let path = Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@", precision: 1e5)
        XCTAssertEqual(path.count, 3)
        XCTAssertEqual(path[0].lat, 38.5, accuracy: 1e-5)
        XCTAssertEqual(path[0].lon, -120.2, accuracy: 1e-5)
        XCTAssertEqual(path[1].lat, 40.7, accuracy: 1e-5)
        XCTAssertEqual(path[1].lon, -120.95, accuracy: 1e-5)
        XCTAssertEqual(path[2].lat, 43.252, accuracy: 1e-5)
        XCTAssertEqual(path[2].lon, -126.453, accuracy: 1e-5)
    }

    /// Valhalla encodes at 1e6. The same bytes read at the wrong precision
    /// are ten times too far from the origin, which is the failure this
    /// default exists to prevent.
    func testDefaultPrecisionIsValhallas() {
        let path = Polyline.decode("_p~iF~ps|U")
        XCTAssertEqual(path[0].lat, 3.85, accuracy: 1e-6)
        XCTAssertEqual(path[0].lon, -12.02, accuracy: 1e-6)
    }

    func testEmptyAndTruncatedInput() {
        XCTAssertTrue(Polyline.decode("").isEmpty)
        // A dangling latitude with no longitude is dropped, not crashed on.
        XCTAssertTrue(Polyline.decode("_p~iF").isEmpty)
    }
}
