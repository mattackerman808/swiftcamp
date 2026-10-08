#if os(macOS)
import SwiftUI

/// Help, Acknowledgements: the licence and every notice the data and the
/// software Swiftcamp ships with ask to travel with it, read from the
/// files in the bundle so the window and the repository cannot disagree.
///
/// A BSD or MIT licence asks for its notice to go wherever the binary
/// goes, and the Copernicus terrain asks for a particular sentence; a
/// notarized app that only kept them in the source repository would meet
/// neither.
struct AcknowledgementsView: View {
    static let id = "acknowledgements"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Swiftcamp \(Self.version)")
                    .font(.title2.weight(.semibold))
                Text("Free software: you can redistribute it and modify it under the terms of the GNU General Public License, version 3. It comes with no warranty. Source: \(Self.repository)")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Not affiliated with or endorsed by Garmin. Garmin, BaseCamp and zūmo are trademarks of Garmin Ltd. or its subsidiaries.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                ForEach(Self.files, id: \.self) { name in
                    if let text = Self.text(of: name) {
                        Text(text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Divider()
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 640)
    }

    static let repository = "https://github.com/mattackerman808/swiftcamp"

    /// The notices first, since that is what someone opening this is
    /// after; the licence's own text after.
    private static let files = ["THIRD_PARTY_NOTICES.md", "LICENSE"]

    private static func text(of name: String) -> String? {
        let url = Bundle.main.url(forResource: name, withExtension: nil)
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// For the About panel: the licence, the data, and where the rest is.
    static var aboutCredits: NSAttributedString {
        let text = """
            Free software under the GNU GPL, version 3.
            \(repository)

            Map data © OpenStreetMap contributors, ODbL.
            Terrain: Copernicus DEM via Mapterhorn. \(BasemapSource.terrainAttribution).
            Routing by Valhalla. Trails from the USDA Forest Service.

            Help › Acknowledgements lists everything else.
            Not affiliated with Garmin.
            """
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ])
    }
}
#endif
