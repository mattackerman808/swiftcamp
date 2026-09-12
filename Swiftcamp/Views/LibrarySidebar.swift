#if os(macOS)
import SwiftUI

/// The collection: routes, tracks and waypoints, the way BaseCamp lays them
/// out.
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
                            symbol: "point.topleft.down.to.point.bottomright.curvepath")
                        .tag(detail.route.id)
                        .contextMenu { deleteButton(detail.route.id) }
                    }
                }
            }

            if !model.tracks.isEmpty {
                Section("Tracks") {
                    ForEach(model.tracks) { detail in
                        row(name: detail.track.name,
                            detail: model.summaries[detail.track.id] ?? "",
                            symbol: "scribble")
                        .tag(detail.track.id)
                        .contextMenu { deleteButton(detail.track.id) }
                    }
                }
            }

            if !model.waypoints.isEmpty {
                Section("Waypoints") {
                    ForEach(model.waypoints) { waypoint in
                        row(name: waypoint.name,
                            detail: waypoint.symbol ?? coordinate(waypoint.coordinate),
                            symbol: "mappin.circle")
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

    private func row(name: String, detail: String, symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol)
        }
    }

    private func deleteButton(_ id: String) -> some View {
        Button("Delete", role: .destructive) { model.delete(id) }
    }

    private func coordinate(_ c: Coordinate) -> String {
        String(format: "%.4f, %.4f", c.lat, c.lon)
    }
}
#endif
