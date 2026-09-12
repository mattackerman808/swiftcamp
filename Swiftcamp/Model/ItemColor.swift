import Foundation

/// The colour a route or track is drawn in.
///
/// ## Why this is Garmin's vocabulary and not a colour well
///
/// A free colour picker would let the user choose something GPX cannot say.
/// `gpxx:DisplayColor` is an enumeration of sixteen names, so anything off
/// that list would either be dropped on export or written as a lie, and the
/// route would arrive on the device in a colour nobody chose. Offering the
/// sixteen means what is on screen is what the unit will draw.
///
/// The stored value is the name. Hex is a rendering detail and never leaves
/// the app.
struct ItemColor: Equatable, Hashable, Sendable, Identifiable {
    /// Garmin's name, exactly as it appears in `gpxx:DisplayColor`.
    let name: String
    let hex: String

    var id: String { name }

    // MARK: - The palette

    /// Ordered for distinctiveness against this basemap, not alphabetically
    /// and not in Garmin's own order.
    ///
    /// The first colour is tachbase's route magenta, which is what the author
    /// reads as "a route" without thinking about it. After that the order
    /// runs down by how well each one survives a pale green and tan map:
    /// the greens, yellows and greys are real Garmin colours and are still
    /// offered, but a fresh import should never be handed one.
    static let palette: [ItemColor] = [
        // #cc00ff is tachbase's magenta, not Garmin's #ff00ff. A shade apart,
        // and the device will draw its own — but the name round-trips, which
        // is the part that has to be right.
        ItemColor(name: "Magenta", hex: "#cc00ff"),
        ItemColor(name: "Blue", hex: "#0a58ff"),
        ItemColor(name: "Red", hex: "#e02020"),
        ItemColor(name: "DarkCyan", hex: "#008b8b"),
        ItemColor(name: "DarkMagenta", hex: "#8b008b"),
        ItemColor(name: "DarkBlue", hex: "#00008b"),
        ItemColor(name: "DarkRed", hex: "#8b0000"),
        ItemColor(name: "Black", hex: "#1d1d1d"),
        ItemColor(name: "Cyan", hex: "#00b8d4"),
        ItemColor(name: "Green", hex: "#00a000"),
        ItemColor(name: "DarkYellow", hex: "#9a8400"),
        ItemColor(name: "DarkGreen", hex: "#006400"),
        ItemColor(name: "Yellow", hex: "#e8c000"),
        ItemColor(name: "DarkGray", hex: "#6e6e6e"),
        ItemColor(name: "LightGray", hex: "#b0b0b0"),
        ItemColor(name: "White", hex: "#ffffff"),
    ]

    /// Looks a stored name up, case-insensitively.
    ///
    /// Returns nil for anything unrecognised rather than guessing. An
    /// unparseable colour in a data-driven paint expression fails the whole
    /// layer rather than the one feature, so the caller has to be able to
    /// fall back.
    static func named(_ name: String?) -> ItemColor? {
        guard let name else { return nil }
        let key = name.lowercased()
        return palette.first { $0.name.lowercased() == key }
    }

    /// The hex a stored name should be drawn in, or nil if unrecognised.
    static func hex(_ name: String?) -> String? { named(name)?.hex }

    /// The colour to give the *n*th route or track that arrives without one.
    ///
    /// Cycles rather than running out. Two items sharing a colour after
    /// sixteen is a cosmetic collision; refusing to assign one would leave a
    /// route drawn in the fallback and looking broken.
    static func `default`(for index: Int) -> ItemColor {
        palette[abs(index) % palette.count]
    }

    /// `hex` split into components, for the renderer and the swatch.
    var components: (red: Double, green: Double, blue: Double) {
        let digits = hex.dropFirst()
        guard digits.count == 6, let value = Int(digits, radix: 16) else { return (0, 0, 0) }
        return (Double((value >> 16) & 0xff) / 255,
                Double((value >> 8) & 0xff) / 255,
                Double(value & 0xff) / 255)
    }
}
