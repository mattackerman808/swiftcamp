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
        List(selection: $model.selection) {
            if !model.routes.isEmpty {
                Section("Routes") {
                    ForEach(model.routes) { detail in
                        row(name: detail.route.name,
                            detail: "\(detail.viaPoints.count) via points · \(distance(detail.length))",
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
                            detail: "\(detail.points.count) points · \(distance(detail.length))",
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
                ContentUnavailableView("Nothing here yet",
                                       systemImage: "map",
                                       description: Text("Import a GPX file to get started."))
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

    /// Miles, because this is a US touring app and the GPS it feeds is set
    /// the same way. The stored value is metres; the conversion lives here
    /// so nothing below the UI ever carries a unit in its name.
    private func distance(_ metres: Double) -> String {
        let miles = metres / 1609.344
        return miles < 10
            ? String(format: "%.1f mi", miles)
            : String(format: "%.0f mi", miles)
    }

    private func coordinate(_ c: Coordinate) -> String {
        String(format: "%.4f, %.4f", c.lat, c.lon)
    }
}
#endif
