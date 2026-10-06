import XCTest
@testable import Swiftcamp

/// The three gates between the library and the map.
final class VisibilityTests: XCTestCase {
    func testAnItemOutsideTheSelectedListNeverDraws() {
        XCTAssertFalse(Visibility.draws(hidden: false, kindShown: true, inList: false))
    }

    func testAHiddenItemNeverDraws() {
        XCTAssertFalse(Visibility.draws(hidden: true, kindShown: true, inList: true))
    }

    func testAKindSwitchedOffNeverDraws() {
        XCTAssertFalse(Visibility.draws(hidden: false, kindShown: false, inList: true))
    }

    func testTheOrdinaryCaseDraws() {
        XCTAssertTrue(Visibility.draws(hidden: false, kindShown: true, inList: true))
    }
}
