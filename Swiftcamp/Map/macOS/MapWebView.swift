#if os(macOS)
import SwiftUI
import WebKit

/// macOS map surface: MapLibre GL JS inside a `WKWebView`.
///
/// MapLibre Native ships no macOS slice and upstream considers its AppKit
/// port bit-rotted, so the Mac renders through the JavaScript build
/// instead. That is a host difference only. The style comes from the same
/// `MapStyle` the iOS path uses and points at the same `.pmtiles` archive,
/// so the two platforms cannot drift apart cartographically.
///
/// Nothing here touches the network. MapLibre GL JS, the PMTiles library,
/// and the archive are all in the bundle, served over a private scheme by
/// `BundleSchemeHandler`.
struct MapWebView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(BundleSchemeHandler(), forURLScheme: BundleSchemeHandler.scheme)
        config.userContentController.add(context.coordinator, name: "swiftcamp")

        // Inject the style before any page script runs, so index.html can
        // read it synchronously rather than waiting on a round trip.
        if let json = try? MapStyle.json(bundledURL: BundleSchemeHandler.pmtilesSourceURL,
                                           glyphsURL: BundleSchemeHandler.glyphsURL,
                                           spriteURL: BundleSchemeHandler.spriteURL) {
            let script = WKUserScript(source: """
                window.__SWIFTCAMP_STYLE__ = \(json);
                window.__SWIFTCAMP_MAX_ZOOM__ = \(BasemapSource.maxZoom);
                window.__SWIFTCAMP_CAMERA__ = \(cameraOverrideJSON());
                """,
                                      injectionTime: .atDocumentStart,
                                      forMainFrameOnly: true)
            config.userContentController.addUserScript(script)
        } else {
            assertionFailure("could not build style JSON")
        }

        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")   // no white flash before first paint
        view.load(URLRequest(url: BundleSchemeHandler.indexURL))
        context.coordinator.webView = view
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    /// Camera override from `-SwiftcampCenter <lon,lat> -SwiftcampZoom <z>`.
    ///
    /// Companion to `-SwiftcampSnapshot`, and only useful with it. The page
    /// opens on a fixed downtown view, which is the wrong place to judge a
    /// cartography change that only shows up in mountains. Without this,
    /// checking the terrain palette meant editing `index.html`, rebuilding,
    /// and remembering to put it back.
    ///
    /// Returns `null` when unset, so the page keeps its own defaults.
    ///
    /// Read straight from `CommandLine.arguments` rather than through
    /// `UserDefaults`, unlike `-SwiftcampSnapshot`. The argument domain
    /// treats any token starting with `-` as a key, so every western
    /// longitude looks like a flag and the value is dropped: passing
    /// `-SwiftcampCenter -105.6,40.3` leaves the default nil and the map
    /// silently opens on Denver instead. Snapshot paths never start with a
    /// dash, which is why that one can stay on `UserDefaults`.
    private func cameraOverrideJSON() -> String {
        let args = CommandLine.arguments

        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        var parts: [String] = []

        if let center = value(after: "-SwiftcampCenter") {
            let pair = center.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if pair.count == 2 { parts.append("center: [\(pair[0]), \(pair[1])]") }
        }
        if let zoom = value(after: "-SwiftcampZoom").flatMap(Double.init) {
            parts.append("zoom: \(zoom)")
        }

        return parts.isEmpty ? "null" : "{" + parts.joined(separator: ", ") + "}"
    }

    /// Surfaces JavaScript console output in the Xcode log. A silent web
    /// view is close to undebuggable otherwise.
    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            let level = body["level"] as? String ?? "log"
            let text = body["text"] as? String ?? ""
            NSLog("[Swiftcamp/web] %@: %@", level, text)

            if text.hasPrefix("map idle") { snapshotIfRequested() }
        }

        /// Writes a PNG of the web view when launched with
        /// `-SwiftcampSnapshot <path>`.
        ///
        /// `WKWebView.takeSnapshot` renders the view's own layer, so this
        /// works headlessly and does not need Screen Recording permission
        /// the way `screencapture` does. Debug affordance only — nothing
        /// calls it without the launch argument.
        private func snapshotIfRequested() {
            guard let path = UserDefaults.standard.string(forKey: "SwiftcampSnapshot"),
                  let webView else { return }

            webView.takeSnapshot(with: nil) { image, error in
                guard let image,
                      let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:]) else {
                    NSLog("[Swiftcamp] snapshot failed: %@", String(describing: error))
                    return
                }
                do {
                    try png.write(to: URL(fileURLWithPath: path))
                    NSLog("[Swiftcamp] snapshot written to %@", path)
                } catch {
                    NSLog("[Swiftcamp] snapshot write failed: %@", String(describing: error))
                }
            }
        }
    }
}
#endif
