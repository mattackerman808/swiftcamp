#if os(macOS)
import SwiftUI
import AppKit

/// A waypoint symbol in the sidebar, cut from the map's own sprite sheet.
///
/// The same pixels the map draws, so the list and the map cannot show two
/// ideas of what "Flag, Blue" looks like, and there is no second set of
/// artwork to keep in step with the first.
struct SymbolImage: View {
    let entry: SymbolCatalog.Entry

    var body: some View {
        if let image = SymbolSprite.image(named: entry.image) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        } else {
            // Only if the bundle is missing its sprites, which the map would
            // already have made obvious.
            Image(systemName: "mappin").frame(width: 16)
        }
    }
}

/// Reads the 2x sprite sheet once and hands out crops of it.
enum SymbolSprite {
    private struct Slot: Decodable {
        var x: Int, y: Int, width: Int, height: Int, pixelRatio: Int
    }

    private static let sheet: (index: [String: Slot], image: CGImage)? = {
        guard let json = Bundle.main.url(forResource: "sprite@2x", withExtension: "json", subdirectory: "sprites"),
              let png = Bundle.main.url(forResource: "sprite@2x", withExtension: "png", subdirectory: "sprites"),
              let data = try? Data(contentsOf: json),
              let index = try? JSONDecoder().decode([String: Slot].self, from: data),
              let source = CGImageSourceCreateWithURL(png as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (index, image)
    }()

    private static var cache: [String: NSImage] = [:]

    /// The named image at its CSS size, so a 2x crop draws at 1x points.
    @MainActor
    static func image(named name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        guard let sheet, let slot = sheet.index[name],
              let crop = sheet.image.cropping(to: CGRect(x: slot.x, y: slot.y,
                                                         width: slot.width, height: slot.height)) else { return nil }
        let scale = CGFloat(slot.pixelRatio)
        let image = NSImage(cgImage: crop, size: NSSize(width: CGFloat(slot.width) / scale,
                                                        height: CGFloat(slot.height) / scale))
        cache[name] = image
        return image
    }
}
#endif
