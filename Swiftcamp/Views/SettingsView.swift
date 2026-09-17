#if os(macOS)
import SwiftUI

/// The Settings window. See `SwiftcampApp.settings` for why it is so small.
struct SettingsView: View {
    @AppStorage(RoutingMode.defaultKey) private var defaultMode = RoutingMode.road.rawValue

    var body: some View {
        Form {
            Picker("New routes:", selection: $defaultMode) {
                ForEach(RoutingMode.allCases, id: \.rawValue) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            Text("Road follows paved ways and moves a dropped point onto the nearest one. "
                 + "Adventure follows any way the map knows and lands a point only when a way is within 50 m. "
                 + "Direct draws straight lines and routes nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 440)
    }
}
#endif
