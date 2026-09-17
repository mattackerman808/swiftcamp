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
                            detail: (model.summaries[detail.route.id] ?? "")
                                + (model.routing.contains(detail.route.id) ? " · routing…" : ""),
                            color: ItemColor.named(detail.route.color))
                        .tag(detail.route.id)
                        .contextMenu {
                            Button("Edit Route") { model.editRoute(detail.route.id) }
                            Button("Reverse Route") { model.reverseRoute(detail.route.id) }
                            routingMenu(for: detail)
                            Divider()
                            renameButton(detail.route.id, detail.route.name)
                            colorMenu(for: detail.route.id)
                            Divider()
                            deleteButton(detail.route.id)
                        }

                        // The selected route's points, in order, the way
                        // BaseCamp lists them under a route. `seq` rather
                        // than the row id as identity: a point just
                        // written has none until its row comes back.
                        if isExpanded(detail) {
                            ForEach(detail.points.sorted { $0.seq < $1.seq }, id: \.seq) { point in
                                pointRow(detail, point)
                            }
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
                    Button("New Route") { model.newRoute() }
                    Button("Import GPX…") { model.isImporting = true }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            // The background fill of the highway levels, while it runs. A
            // rider should know why the network light is on, and when a
            // cross-country leg will stop waiting on it.
            if let progress = model.prefetch?.progress, !progress.done {
                Text("Routing data: \(megabytes(progress.fetchedBytes)) of \(megabytes(progress.totalBytes)) MB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.bar)
            }
        }
    }

    private func megabytes(_ bytes: Int64) -> String {
        (bytes / 1_000_000).formatted()
    }

    // MARK: - Route points

    /// A route shows its points while it, or one of them, is selected.
    private func isExpanded(_ detail: RouteDetail) -> Bool {
        model.selection.contains(detail.route.id)
            || model.selection.contains { OverlayGeoJSON.parseHandle($0)?.routeID == detail.route.id }
    }

    /// One point of a route: a via point with its name, or a shaping point,
    /// which has none. Both say how far along the road they are.
    private func pointRow(_ detail: RouteDetail, _ point: RoutePoint) -> some View {
        let handle = OverlayGeoJSON.handle(detail.route.id, point.seq)
        let color = ItemColor.named(detail.route.color).map(Color.init) ?? Color.secondary

        return row(id: handle,
                   name: point.isVia ? (point.name ?? "Via point \(point.seq + 1)") : "Shaping point",
                   detail: model.pointSummaries[handle] ?? "") {
            // The same marks the map draws: a ring for a stop, a small solid
            // dot for a bend in the road.
            Image(systemName: point.isVia ? "circle" : "circle.fill")
                .font(.system(size: point.isVia ? 11 : 7, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 13)
        }
        .padding(.leading, 16)
        .tag(handle)
        .contextMenu {
            if point.isVia {
                renameButton(handle, point.name ?? "")
                Button("Make Shaping Point") { model.setVia(routeID: detail.route.id, seq: point.seq, false) }
            } else {
                Button("Make Via Point") { model.setVia(routeID: detail.route.id, seq: point.seq, true) }
            }
            Divider()
            Button("Delete Point", role: .destructive) {
                model.deleteViaPoint(routeID: detail.route.id, seq: point.seq)
            }
        }
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
        if let id = renaming {
            if let handle = OverlayGeoJSON.parseHandle(id) {
                model.renamePoint(routeID: handle.routeID, seq: handle.seq, to: draft)
            } else {
                model.rename(id, to: draft)
            }
        }
        renaming = nil
    }

    // MARK: - Routing

    /// Garmin's activity profile: which ways the legs may use and whether
    /// a dropped point lands on one. Changing it routes the whole route
    /// again, which is what BaseCamp does on a profile change.
    private func routingMenu(for detail: RouteDetail) -> some View {
        Picker("Routing", selection: Binding(get: { detail.route.mode },
                                             set: { model.setMode($0, forRoute: detail.route.id) })) {
            ForEach(RoutingMode.allCases, id: \.self) { mode in
                Text(mode.title).tag(mode)
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
