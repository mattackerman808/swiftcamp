import SwiftUI

/// Stage 0 shell: the map fills the window and nothing else exists yet.
/// Route/waypoint chrome lands on top of this once the data model does.
struct ContentView: View {
    var body: some View {
        MapContainer()
            .ignoresSafeArea()
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
