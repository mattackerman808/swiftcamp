import SwiftUI

/// The single point where the two map backends diverge.
///
/// MapLibre Native ships iOS-only slices (verified: the 6.29.0
/// XCFramework contains `ios-arm64` and `ios-arm64_x86_64-simulator`
/// and nothing else), and upstream considers the AppKit port bit-rotted.
/// So iOS gets the native renderer and macOS will get MapLibre GL JS in
/// a `WKWebView`.
///
/// Everything above this view is shared. Everything below it is a host
/// for the same style JSON and the same `.pmtiles`. Keep the divergence
/// confined to this file.
///
/// `overlay` is a value rather than an observable object on purpose. A
/// representable re-renders when a value SwiftUI saw it read changes, not
/// when an `@Observable` it holds a reference to does — see `MapWebView`.
struct MapContainer: View {
    var overlay: MapOverlay = .empty
    var camera: MapCameraRequest?
    /// The route whose via points can be dragged, if one is being edited.
    var editingRouteID: String?
    var pageEvent: MapPageEvent?
    var onClick: ((MapClick) -> Void)?
    var onDrag: ((MapDrag) -> Void)?
    var onKey: ((MapKey) -> Void)?

    var body: some View {
        #if os(iOS)
        // No overlay path on iOS yet. The library, the GPX layer and the
        // GeoJSON the map consumes are all platform-free, so what is missing
        // here is the host, not the model.
        MapLibreMapView()
        #else
        MapWebView(overlay: overlay, camera: camera, editingRouteID: editingRouteID,
                   pageEvent: pageEvent, onClick: onClick, onDrag: onDrag, onKey: onKey)
        #endif
    }
}
