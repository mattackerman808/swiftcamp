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
///
/// ## `overlay` is a value, and that is not incidental
///
/// An `NSViewRepresentable` is not re-rendered because an `@Observable`
/// object changed; it is re-rendered when a value SwiftUI saw it read
/// changes. Handing this view the observable and reading through it would
/// produce a map that never updates and never errors, which is expensive to
/// diagnose. Handing it an `Equatable` value forces the dependency to exist.
/// tachbase carries the scar comment for the identical trap on iOS.
struct MapWebView: NSViewRepresentable {
    var overlay: MapOverlay
    var onClick: ((MapClick) -> Void)?

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
        context.coordinator.onClick = onClick
        context.coordinator.push(overlay)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onClick = onClick
        context.coordinator.push(overlay)
    }

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

    /// Holds the web view, relays messages, and owns the readiness gate.
    ///
    /// Every message from the page is `{type: ...}`. The app used to detect
    /// that the map had settled by matching the prefix of a forwarded log
    /// line, which meant any new event had to be smuggled through
    /// `console.log` to reach Swift at all.
    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var webView: WKWebView?
        var onClick: ((MapClick) -> Void)?

        /// Nothing can be pushed until the page reports that its style has
        /// parsed and its sources exist. `makeNSView` returns long before
        /// that, so the first overlay is held here and sent on `ready`.
        /// Without the gate the first push lands on a map with no sources
        /// and is simply lost, which looks like an import that did nothing.
        private var isReady = false
        private var pending: MapOverlay?
        private var applied = MapOverlay.empty

        // MARK: - Pushing

        func push(_ overlay: MapOverlay) {
            guard isReady else {
                pending = overlay
                return
            }

            // Only what differs crosses the bridge. `updateNSView` runs on
            // every SwiftUI invalidation and dragging a via point
            // invalidates constantly, so without this a three-point route
            // resends every track in the library on each frame.
            let changed = overlay.changes(from: applied)
            guard !changed.isEmpty else { return }
            applied = overlay

            // `callAsyncJavaScript` passes arguments as data rather than as
            // interpolated source text. A route named "Bob's ridge" would
            // otherwise close the string literal and turn the push into a
            // syntax error — and anything sharper than an apostrophe into
            // something worse.
            webView?.callAsyncJavaScript("window.swiftcamp.setOverlay(overlay);",
                                         arguments: ["overlay": changed],
                                         in: nil,
                                         in: .page) { result in
                if case .failure(let error) = result {
                    NSLog("[Swiftcamp] overlay push failed: %@", String(describing: error))
                }
            }
        }

        // MARK: - Receiving

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            switch type {
            case "console":
                // Surfaces JavaScript output in the Xcode log. A silent web
                // view is close to undebuggable otherwise.
                let level = body["level"] as? String ?? "log"
                NSLog("[Swiftcamp/web] %@: %@", level, body["text"] as? String ?? "")

            case "ready":
                isReady = true
                if let overlay = pending {
                    pending = nil
                    push(overlay)
                }

            case "idle":
                snapshotIfRequested()

            case "click":
                if let click = Self.click(from: body) { onClick?(click) }

            default:
                break
            }
        }

        /// A via point is identified by its route and its position, never by
        /// its database row id. Saving a route rewrites every one of its
        /// points, so a row id is not stable across the edit a click usually
        /// precedes.
        private static func click(from body: [String: Any]) -> MapClick? {
            guard let lon = body["lon"] as? Double, let lat = body["lat"] as? Double else { return nil }

            let id = body["id"] as? String
            let seq = body["seq"] as? Int
            let target: MapClick.Target

            switch body["layer"] as? String {
            case "via-point":
                guard let id, let seq else { return nil }
                target = .viaPoint(routeID: id, seq: seq)
            case "route-line":
                guard let id else { return nil }
                target = .routeLine(routeID: id)
            case "waypoint-dot":
                guard let id else { return nil }
                target = .waypoint(id: id)
            case "track-line":
                guard let id else { return nil }
                target = .track(id: id)
            default:
                target = .ground
            }

            return MapClick(coordinate: Coordinate(lat: lat, lon: lon), target: target)
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
