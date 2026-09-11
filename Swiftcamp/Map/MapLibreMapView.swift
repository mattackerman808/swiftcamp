#if os(iOS)
import SwiftUI
import MapLibre

/// iOS map surface: MapLibre Native reading the bundled PMTiles archive.
///
/// Nothing here talks to the network. The style points at a `pmtiles://`
/// URL wrapping a file in the app bundle, and MapLibre's built-in PMTiles
/// reader range-reads it off disk exactly as it would over HTTP.
struct MapLibreMapView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MLNMapView {
        // Build the style URL *before* the map view exists. `MLNMapView(frame:)`
        // loads MapLibre's hosted demo style by default, which fires a request
        // to demotiles.maplibre.org that we then cancel a moment later when we
        // assign our own style. Harmless but wrong for an offline-first app —
        // the bundled basemap exists precisely so a cold launch touches no
        // network. Passing the style up front means that request never happens.
        let styleURL: URL?
        if let source = BasemapSource.bundledURL {
            styleURL = try? MapStyle.write(bundledURL: source)
        } else {
            assertionFailure("world-z6.pmtiles missing from the app bundle")
            styleURL = nil
        }

        let view = MLNMapView(frame: .zero, styleURL: styleURL)
        view.delegate = context.coordinator
        view.maximumZoomLevel = BasemapSource.maxZoom
        view.logoView.isHidden = true          // attribution is drawn in SwiftUI instead
        view.attributionButton.isHidden = true

        // Somewhere over the western US, zoomed out far enough that the
        // z0–6 bundled archive still has data to draw.
        // Colorado Front Range at a zoom where the streamed archive has
        // real detail, so a launch immediately shows whether streaming works.
        view.setCenter(CLLocationCoordinate2D(latitude: 39.74, longitude: -104.99),
                       zoomLevel: 11,
                       animated: false)

        return view
    }

    func updateUIView(_ uiView: MLNMapView, context: Context) {}

    final class Coordinator: NSObject, MLNMapViewDelegate {
        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            NSLog("[Swiftcamp] style loaded, \(style.layers.count) layers")
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: Error) {
            NSLog("[Swiftcamp] map failed to load: \(error)")
        }
    }
}
#endif
