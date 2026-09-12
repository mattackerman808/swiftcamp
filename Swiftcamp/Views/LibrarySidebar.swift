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

    /// Which row is being renamed, and what has been typed so far.
    ///
    /// Inline rather than in a dialog, which is what a Mac sidebar does and
    /// what makes renaming several things in a row bearable.
    @State private var renaming: String?
    @State private var draft = ""
    @FocusState private var isNaming: Bool

    var body: some View {
        // Routed through the model rather than bound straight at
        // `selection`, so the sidebar can frame what it selects while a map
        // click, which goes through `select(_:)`, leaves the camera alone.
        List(selection: Binding(get: { model.selection },
                                set: { model.selectFromSidebar($0) })) {
            if !model.routes.isEmpty {
                Section("Routes") {
                    ForEach(model.routes) { detail in
                        row(id: detail.route.id,
                            name: detail.route.name,
                            detail: model.summaries[detail.route.id] ?? "",
                            color: ItemColor.named(detail.route.color))
                        .tag(detail.route.id)
                        .contextMenu {
                            renameButton(detail.route.id, detail.route.name)
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
                        row(id: detail.track.id,
                            name: detail.track.name,
                            detail: model.summaries[detail.track.id] ?? "",
                            color: ItemColor.named(detail.track.color))
                        .tag(detail.track.id)
                        .contextMenu {
                            renameButton(detail.track.id, detail.track.name)
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
                        row(id: waypoint.id,
                            name: waypoint.name,
                            detail: waypoint.symbol ?? coordinate(waypoint.coordinate),
                            symbol: "mappin.circle.fill")
                        .tag(waypoint.id)
                        .contextMenu {
                            renameButton(waypoint.id, waypoint.name)
                            Divider()
                            deleteButton(waypoint.id)
                        }
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

    private func row(id: String, name: String, detail: String, color: ItemColor?) -> some View {
        row(id: id, name: name, detail: detail) { Swatch(color: color) }
    }

    private func row(id: String, name: String, detail: String, symbol: String) -> some View {
        row(id: id, name: name, detail: detail) {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
                .frame(width: 13)
        }
    }

    private func row(id: String, name: String, detail: String,
                     @ViewBuilder leading: () -> some View) -> some View {
        HStack(spacing: 8) {
            leading()
            VStack(alignment: .leading, spacing: 1) {
                if renaming == id {
                    TextField("Name", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused($isNaming)
                        .onSubmit(commitRename)
                        // Escape and clicking away both mean "leave it alone",
                        // which is the opposite of what saving on focus loss
                        // would do to a half-typed name.
                        .onExitCommand { renaming = nil }
                        .onChange(of: isNaming) { _, focused in
                            if !focused { renaming = nil }
                        }
                } else {
                    Text(name)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func renameButton(_ id: String, _ name: String) -> some View {
        Button("Rename…") {
            draft = name
            renaming = id
            // The field does not exist until the row redraws, so focus has to
            // wait for it.
            DispatchQueue.main.async { isNaming = true }
        }
    }

    private func commitRename() {
        if let id = renaming { model.rename(id, to: draft) }
        renaming = nil
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
