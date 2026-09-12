import XCTest
@testable import Swiftcamp

/// Route names to filenames a device will accept.
///
/// Garmin storage is FAT underneath, and a unit that rejects a filename does
/// not say which character it objected to. Someone who names a route
/// "Sat 12/9 — Rockies" would get an error about the file rather than about
/// the name, which is the wrong thing to have to work out at a petrol stop.
final class DeviceFilenameTests: XCTestCase {
    func testOrdinaryNamesPassThrough() {
        XCTAssertEqual(DeviceFilename.make(from: "Trail Ridge Road"), "Trail Ridge Road.gpx")
    }

    /// The FAT-forbidden set, every one of which a rider might reasonably
    /// type. A date with slashes is the common one.
    func testForbiddenCharactersAreReplaced() {
        let name = DeviceFilename.make(from: #"Sat 12/9: "best" bits <north>|loop?*"#)

        for character in #"/\:*?"<>|"# {
            XCTAssertFalse(name.contains(character), "\(character) survived in \(name)")
        }
        XCTAssertTrue(name.hasSuffix(".gpx"))
    }

    func testControlCharactersAreReplaced() {
        let name = DeviceFilename.make(from: "Trail\u{0}Ridge\nRoad")
        XCTAssertFalse(name.contains("\u{0}"))
        XCTAssertFalse(name.contains("\n"))
    }

    /// FAT refuses a trailing dot, and the extension is about to add one.
    func testTrailingDotsGo() {
        XCTAssertEqual(DeviceFilename.make(from: "Sunday ride..."), "Sunday ride.gpx")
    }

    func testAnEmptyNameFallsBackRatherThanProducingABareExtension() {
        XCTAssertEqual(DeviceFilename.make(from: ""), "Route.gpx")
        XCTAssertEqual(DeviceFilename.make(from: "   "), "Route.gpx")
        XCTAssertEqual(DeviceFilename.make(from: "///"), "Route.gpx")
        XCTAssertEqual(DeviceFilename.make(from: "", fallback: "Track"), "Track.gpx")
    }

    func testVeryLongNamesAreTrimmed() {
        let name = DeviceFilename.make(from: String(repeating: "a", count: 300))
        XCTAssertLessThanOrEqual(name.count, 64)
        XCTAssertTrue(name.hasSuffix(".gpx"))
    }

    /// Accents and non-Latin scripts are not FAT's problem and must survive:
    /// a route called "Cañon City" should reach the device called that.
    func testAccentsSurvive() {
        XCTAssertEqual(DeviceFilename.make(from: "Cañon City"), "Cañon City.gpx")
    }
}
