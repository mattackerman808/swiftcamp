import XCTest
@testable import Swiftcamp

/// The three gates between the library and the map.
final class VisibilityTests: XCTestCase {
    func testAnItemOutsideTheSelectedListNeverDraws() {
        XCTAssertFalse(Visibility.draws(hidden: false, kindShown: true, inList: false, selected: true, editing: true))
    }

    func testAHiddenItemDrawsOnlyWhileSelectedOrEdited() {
        XCTAssertFalse(Visibility.draws(hidden: true, kindShown: true, inList: true, selected: false))
        XCTAssertTrue(Visibility.draws(hidden: true, kindShown: true, inList: true, selected: true))
        XCTAssertTrue(Visibility.draws(hidden: true, kindShown: true, inList: true, selected: false, editing: true))
    }

    func testAKindSwitchedOffDrawsOnlyTheSelection() {
        XCTAssertFalse(Visibility.draws(hidden: false, kindShown: false, inList: true, selected: false))
        XCTAssertTrue(Visibility.draws(hidden: false, kindShown: false, inList: true, selected: true))
    }

    func testTheOrdinaryCaseDraws() {
        XCTAssertTrue(Visibility.draws(hidden: false, kindShown: true, inList: true, selected: false))
    }
}
