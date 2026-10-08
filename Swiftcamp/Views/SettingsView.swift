#if os(macOS)
import SwiftUI

/// The Settings window. See `SwiftcampApp.settings` for why it is so small.
///
/// Everything here is only what a new route starts with. A route's own
/// mode and preferences live on the route, in its menus and the inspector.
struct SettingsView: View {
    @AppStorage(RoutingMode.defaultKey) private var defaultMode = RoutingMode.road.rawValue
    @State private var preferences = RoutePreferences.stored

    var body: some View {
        Form {
            Picker("New routes:", selection: $defaultMode) {
                ForEach(RoutingMode.allCases, id: \.rawValue) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            Text("Road follows paved ways and moves a dropped point onto the nearest one. "
                 + "Adventure follows any way the map knows and lands a point only when a way is within 50 m. "
                 + "Driving routes a car on paved roads; Walking follows footpaths and trails. "
                 + "Direct draws straight lines and routes nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Prefer:", selection: $preferences.prefer) {
                ForEach(RoutePreferences.Preference.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle("Avoid highways", isOn: $preferences.avoidHighways)
            Toggle("Avoid tolls", isOn: $preferences.avoidTolls)
            Toggle("Avoid ferries", isOn: $preferences.avoidFerries)
            Text("Some Curves takes a canyon road when it costs a few minutes; "
                 + "Many Curves goes looking for the ride. Each avoidance is a strong preference, not a ban.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: preferences) { _, next in next.store() }
        .padding(20)
        .frame(width: 440)
    }
}
#endif
