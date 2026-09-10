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
struct MapContainer: View {
    var body: some View {
        #if os(iOS)
        MapLibreMapView()
        #else
        MapWebView()
        #endif
    }
}
