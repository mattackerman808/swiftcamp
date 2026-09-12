#if os(macOS)
import SwiftUI

/// The collection: routes, tracks and waypoints, the three things Garmin's
/// format carries and the three things BaseCamp organises.
///
/// Selection is shared with the map through `LibraryModel`, so clicking a
/// route here highlights it there and clicking it there highlights it here,
/// without either side knowing about the other.
struct LibrarySidebar: View {
    @Bindable var model: LibraryModel

    var body: some View {
        // Routed through the model rather than bound straight at
        // `selection`, so the sidebar can frame what it selects while a map
        // click, which goes through `select(_:)`, leaves the camera alone.
        List(selection: Binding(get: { model.selection },
                                set: { model.selectFromSidebar($0) })) {
            if !model.routes.isEmpty {
                Section("Routes") {
                    ForEach(model.routes) { detail in
                        row(name: detail.route.name,
                            detail: model.summaries[detail.route.id] ?? "",
                            color: ItemColor.named(detail.route.color))
                        .tag(detail.route.id)
                        .contextMenu {
                            colorMenu(for: detail.route.id)
                            Divider()
                            deleteButton(detail.route.id)
                        }
                    }
                }
            }

            if !model.tracks.isEmpty {
                Section("Tracks") {
                    ForEach(model.tracks) { detail in
                        row(name: detail.track.name,
                            detail: model.summaries[detail.track.id] ?? "",
                            color: ItemColor.named(detail.track.color))
                        .tag(detail.track.id)
                        .contextMenu {
                            colorMenu(for: detail.track.id)
                            Divider()
                            deleteButton(detail.track.id)
                        }
                    }
                }
            }

            if !model.waypoints.isEmpty {
                Section("Waypoints") {
                    ForEach(model.waypoints) { waypoint in
                        // No swatch. A waypoint's appearance on a Garmin is
                        // its symbol, not a display colour, and offering one
                        // here would promise something GPX cannot carry.
                        row(name: waypoint.name,
                            detail: waypoint.symbol ?? coordinate(waypoint.coordinate),
                            symbol: "mappin.circle.fill")
                        .tag(waypoint.id)
                        .contextMenu { deleteButton(waypoint.id) }
                    }
                }
            }

            if model.routes.isEmpty && model.tracks.isEmpty && model.waypoints.isEmpty {
                // A button, not just an instruction. Telling someone to
                // import a file and leaving them to find the toolbar is how
                // an empty app stays empty.
                ContentUnavailableView {
                    Label("Nothing here yet", systemImage: "map")
                } description: {
                    Text("Import a GPX file to get started.")
                } actions: {
                    Button("Import GPX…") { model.isImporting = true }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Rows

    private func row(name: String, detail: String, color: ItemColor?) -> some View {
        row(name: name, detail: detail) { Swatch(color: color) }
    }

    private func row(name: String, detail: String, symbol: String) -> some View {
        row(name: name, detail: detail) {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
                .frame(width: 13)
        }
    }

    private func row(name: String, detail: String,
                     @ViewBuilder leading: () -> some View) -> some View {
        HStack(spacing: 8) {
            leading()
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Colour

    /// Garmin's sixteen, and only those.
    ///
    /// A colour well would let the user pick something `gpxx:DisplayColor`
    /// cannot express, which on export becomes either a dropped colour or a
    /// different one. What is on screen should be what the device draws.
    private func colorMenu(for id: String) -> some View {
        Menu("Colour") {
            ForEach(ItemColor.palette) { color in
                Button {
                    model.setColor(color, for: id)
                } label: {
                    Label { Text(color.name) } icon: { Swatch(color: color) }
                }
            }
        }
    }

    private func deleteButton(_ id: String) -> some View {
        Button("Delete", role: .destructive) { model.delete(id) }
    }

    private func coordinate(_ c: Coordinate) -> String {
        String(format: "%.4f, %.4f", c.lat, c.lon)
    }
}

/// The colour chip beside a route or track.
private struct Swatch: View {
    var color: ItemColor?

    var body: some View {
        RoundedRectangle(cornerRadius: 2.5)
            .fill(color.map(Color.init) ?? Color.secondary.opacity(0.3))
            .overlay {
                // White and the light greys are real Garmin colours and would
                // otherwise be an invisible chip on a light sidebar.
                RoundedRectangle(cornerRadius: 2.5)
                    .strokeBorder(.primary.opacity(0.25), lineWidth: 0.5)
            }
            .frame(width: 13, height: 13)
    }
}

extension Color {
    init(_ item: ItemColor) {
        let (r, g, b) = item.components
        self.init(red: r, green: g, blue: b)
    }
}
#endif
