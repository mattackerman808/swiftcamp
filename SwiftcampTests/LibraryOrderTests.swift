import XCTest
@testable import Swiftcamp

final class LibraryOrderTests: XCTestCase {
    private struct Row {
        var name: String
        var created: Date
        var updated: Date
        var length: Double?
    }

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private var rows: [Row] {
        [Row(name: "Peak to Peak", created: epoch + 30, updated: epoch + 300, length: 1_000),
         Row(name: "alpine loop", created: epoch + 10, updated: epoch + 100, length: 3_000),
         Row(name: "Route 10", created: epoch + 20, updated: epoch + 400, length: 1_000),
         Row(name: "Route 9", created: epoch + 40, updated: epoch + 200, length: nil)]
    }

    private func sorted(_ sort: LibrarySort, descending: Bool = false) -> [String] {
        LibraryOrder.sorted(rows, by: sort, descending: descending,
                            name: \.name, created: \.created, updated: \.updated, length: \.length).map(\.name)
    }

    func testNameIsCaseInsensitiveAndNumericAware() {
        XCTAssertEqual(sorted(.name), ["alpine loop", "Peak to Peak", "Route 9", "Route 10"])
        XCTAssertEqual(sorted(.name, descending: true), ["Route 10", "Route 9", "Peak to Peak", "alpine loop"])
    }

    func testDates() {
        XCTAssertEqual(sorted(.created), ["alpine loop", "Route 10", "Peak to Peak", "Route 9"])
        XCTAssertEqual(sorted(.updated, descending: true), ["Route 10", "Peak to Peak", "Route 9", "alpine loop"])
    }

    func testLengthTiesBreakOnNameAndUnmeasuredSortsLast() {
        XCTAssertEqual(sorted(.length), ["Peak to Peak", "Route 10", "alpine loop", "Route 9"])
        XCTAssertEqual(sorted(.length, descending: true), ["Route 9", "alpine loop", "Route 10", "Peak to Peak"])
    }

    func testFilterMatchesEveryWordAnywhere() {
        XCTAssertTrue(LibraryOrder.matches("", "anything"))
        XCTAssertTrue(LibraryOrder.matches("ridge trail", "Trail Ridge Road", nil))
        XCTAssertTrue(LibraryOrder.matches("fuel", "Estes Park", "fuel here"))
        XCTAssertFalse(LibraryOrder.matches("ridge trail fuel", "Trail Ridge Road", nil))
        XCTAssertTrue(LibraryOrder.matches("cafe", "Café du Monde"), "diacritics are ignored")
        XCTAssertTrue(LibraryOrder.matches("ESTES", "Estes Park"))
    }
}
