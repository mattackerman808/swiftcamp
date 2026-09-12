import XCTest
@testable import Swiftcamp

/// The colour a route or track is drawn in, and the promise that it survives
/// a round trip to a device.
final class ItemColorTests: XCTestCase {
    /// The whole reason this is a fixed list rather than a colour well. Every
    /// name here has to be one `gpxx:DisplayColor` accepts, or the colour is
    /// dropped or changed on export and the route arrives on the unit looking
    /// like something nobody chose.
    private let garminNames: Set<String> = [
        "Black", "DarkRed", "DarkGreen", "DarkYellow", "DarkBlue", "DarkMagenta",
        "DarkCyan", "LightGray", "DarkGray", "Red", "Green", "Yellow", "Blue",
        "Magenta", "Cyan", "White",
    ]

    func testEveryPaletteEntryIsANameGarminAccepts() {
        for color in ItemColor.palette {
            XCTAssertTrue(garminNames.contains(color.name),
                          "\(color.name) is not a gpxx:DisplayColor value")
        }
    }

    func testThePaletteIsTheCompleteGarminSet() {
        XCTAssertEqual(Set(ItemColor.palette.map(\.name)), garminNames)
    }

    func testNamesAreUnique() {
        XCTAssertEqual(Set(ItemColor.palette.map(\.name)).count, ItemColor.palette.count)
    }

    // MARK: - Defaults

    /// Magenta first, because that is what a route looks like.
    func testTheFirstDefaultIsMagenta() {
        XCTAssertEqual(ItemColor.default(for: 0).name, "Magenta")
        XCTAssertEqual(ItemColor.default(for: 0).hex, "#cc00ff", "tachbase's magenta")
    }

    /// The greens and the pale greys are real Garmin colours and are still
    /// offered, but a fresh import should never be handed one: the basemap is
    /// pale green and tan, and a DarkGreen track on it is nearly invisible.
    func testTheFirstDefaultsAvoidColoursThatVanishOnThisBasemap() {
        let firstFew = (0..<6).map { ItemColor.default(for: $0).name }
        for bad in ["DarkGreen", "Green", "Yellow", "LightGray", "White", "DarkGray"] {
            XCTAssertFalse(firstFew.contains(bad), "\(bad) should not be an early default")
        }
    }

    func testDefaultsAreDistinctUntilThePaletteRunsOut() {
        let assigned = (0..<ItemColor.palette.count).map { ItemColor.default(for: $0).name }
        XCTAssertEqual(Set(assigned).count, ItemColor.palette.count)
    }

    /// Cycling beats running out. Two items sharing a colour after sixteen is
    /// cosmetic; leaving one uncoloured draws it in the fallback and looks
    /// like a bug.
    func testDefaultsCycleRatherThanRunOut() {
        XCTAssertEqual(ItemColor.default(for: ItemColor.palette.count).name,
                       ItemColor.default(for: 0).name)
        XCTAssertEqual(ItemColor.default(for: -1).name, ItemColor.default(for: 1).name)
    }

    // MARK: - Lookup

    func testLookupIsCaseInsensitive() {
        XCTAssertEqual(ItemColor.named("magenta")?.name, "Magenta")
        XCTAssertEqual(ItemColor.named("DARKCYAN")?.name, "DarkCyan")
    }

    func testUnknownNamesReturnNil() {
        // An unparseable colour in a data-driven paint expression fails the
        // whole layer rather than the one feature, so the caller has to be
        // able to fall back.
        XCTAssertNil(ItemColor.named("Chartreuse"))
        XCTAssertNil(ItemColor.named(nil))
        XCTAssertNil(ItemColor.hex("Transparent"), "Garmin's, but it means do not draw")
    }

    func testComponentsDecodeTheHex() {
        let white = try? XCTUnwrap(ItemColor.named("White"))
        XCTAssertEqual(white?.components.red, 1.0)
        XCTAssertEqual(white?.components.green, 1.0)

        let magenta = ItemColor.default(for: 0).components
        XCTAssertEqual(magenta.red, 0.8, accuracy: 0.01)
        XCTAssertEqual(magenta.green, 0.0, accuracy: 0.01)
        XCTAssertEqual(magenta.blue, 1.0, accuracy: 0.01)
    }
}
