import SwiftUI

/// Stage 0 shell: the map fills the window and nothing else exists yet.
/// Route/waypoint chrome lands on top of this once the data model does.
struct ContentView: View {
    var body: some View {
        MapContainer()
            #if os(iOS)
            // Edge to edge under the status bar and home indicator.
            //
            // Deliberately NOT applied on macOS. There, SwiftUI would
            // stretch the web view under the title bar while WebKit keeps
            // insetting its own viewport by that same safe area, so the
            // view ends up 32pt taller than the page it is showing and the
            // difference renders as an unpainted strip. Letting AppKit lay
            // the web view out inside the safe area keeps bounds and
            // viewport identical.
            .ignoresSafeArea()
            #endif
            .overlay(alignment: .bottomLeading) {
                // OSM attribution is an ODbL obligation, not decoration.
                // See docs/data-architecture.md.
                Text(BasemapSource.attribution)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
    }
}
