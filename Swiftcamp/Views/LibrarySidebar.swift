#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// The collection: routes, tracks and waypoints, the three things Garmin's
/// format carries and the three things BaseCamp organises, under the lists
/// they are filed in.
///
/// Selection is shared with the map through `LibraryModel`, so clicking a
/// route here highlights it there and clicking it there highlights it here,
/// without either side knowing about the other.
///
/// Two panes, the way BaseCamp lays it out: lists above, the chosen list's
/// items below. They are two `List`s because they select different things.
/// The items pane's selection is the library selection the map and the
/// export share, and a list is not something to export; putting both in
/// one `List` would mean a selected folder was an exported nothing.
struct LibrarySidebar: View {
    @Bindable var model: LibraryModel

    /// Which row is being renamed, and what has been typed so far.
    ///
    /// Inline rather than in a dialog, which is what a Mac sidebar does and
    /// what makes renaming several things in a row bearable.
    @State private var renaming: String?
    @State private var draft = ""
    @FocusState private var isNaming: Bool

    /// The lists pane's own selection. `collection` stands for the whole
    /// library, because an optional binding cannot distinguish "nothing
    /// chosen" from "everything chosen".
    private static let collection = "collection"

    var body: some View {
        VStack(spacing: 0) {
            listsPane
            Divider()
            filterBar
            itemsPane
        }
        // A rename asked for on the map, or by New List, opens the same
        // field a right-click here does. The request carries a token so
        // the same item can be asked for twice.
        .onChange(of: model.renameRequest) { _, request in
            guard let request, let name = model.name(for: request.id)
                    ?? model.lists.first(where: { $0.id == request.id })?.name else { return }
            draft = name
            renaming = request.id
            DispatchQueue.main.async { isNaming = true }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let id = model.selection.first, model.selection.count == 1 {
                    ItemInspector(model: model, id: id)
                    if let detail = model.routes.first(where: { $0.route.id == id }) {
                        DirectionsPane(model: model, detail: detail)
                    }
                }
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
    }

    private func megabytes(_ bytes: Int64) -> String {
        (bytes / 1_000_000).formatted()
    }

    // MARK: - Lists

    /// The whole collection, then every list, nested. Sized to its rows so
    /// the items below get the rest of the sidebar; a library with two
    /// lists should not give half the window to a folder tree.
    private var listsPane: some View {
        let rows = 1 + model.lists.count
        return List(selection: Binding(get: { model.selectedListID ?? Self.collection },
                                       set: { model.selectedListID = $0 == Self.collection ? nil : $0 })) {
            Label("My Collection", systemImage: "books.vertical")
                .tag(Self.collection)
                .contextMenu {
                    Button("New List") { model.newList() }
                }
                .dropDestination(for: String.self) { ids, _ in drop(ids, onList: nil) }
            ForEach(model.lists(in: nil)) { list in
                listRows(list, depth: 0)
            }
            if model.lists.isEmpty {
                // The one gesture that makes a list, said once. Gone the
                // moment a list exists, so the pane never grows a button
                // for it; a row of controls is the BaseCamp look this
                // sidebar is deliberately not.
                Text("Right-click to add a list")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .selectionDisabled()
            }
        }
        .listStyle(.sidebar)
        .frame(height: CGFloat(min(rows, 8)) * 24 + 20 + (model.lists.isEmpty ? 20 : 0))
    }

    /// A list and, under it, its sublists, indented. Recursion through a
    /// function rather than `OutlineGroup` so every row keeps the same
    /// context menu, rename field and drop target.
    private func listRows(_ list: LibraryList, depth: Int) -> AnyView {
        AnyView(Group {
            row(id: list.id, name: list.name, detail: "") {
                Image(systemName: "folder").foregroundStyle(.secondary)
            }
            .padding(.leading, CGFloat(depth) * 16)
            .tag(list.id)
            .draggable("list:" + list.id)
            .dropDestination(for: String.self) { ids, _ in drop(ids, onList: list.id) }
            .contextMenu {
                Button("New List Inside") { model.newList(in: list.id) }
                renameButton(list.id, list.name)
                if list.parentID != nil {
                    Button("Move to Top") { model.nest(list.id, under: nil) }
                }
                Divider()
                Button("Delete List", role: .destructive) { model.deleteList(list.id) }
            }
            ForEach(model.lists(in: list.id)) { child in
                listRows(child, depth: depth + 1)
            }
        })
    }

    /// Items dropped on a list are filed in it; a list dropped on a list
    /// goes inside it. The dragged id stands for the whole selection when
    /// it is part of one, which is how the Finder reads a drag of several.
    private func drop(_ ids: [String], onList listID: String?) -> Bool {
        var items: Set<String> = []
        for id in ids {
            if id.hasPrefix("list:") {
                model.nest(String(id.dropFirst(5)), under: listID)
            } else if model.selection.contains(id) {
                items.formUnion(model.selection)
            } else {
                items.insert(id)
            }
        }
        if !items.isEmpty { model.file(items, in: listID) }
        return true
    }

    /// Waypoints dropped on a route become its stops, before point
    /// `before` or at the end; the whole selection when the dragged one is
    /// part of it, in the sidebar's order, so three stops dropped together
    /// arrive in the order they were listed. Anything else dropped on a
    /// route, a track or a list, is refused, and the drag shows it.
    private func drop(_ ids: [String], onRoute routeID: String, before index: Int?) -> Bool {
        var dropped: Set<String> = []
        for id in ids where !id.hasPrefix("list:") {
            dropped.formUnion(model.selection.contains(id) ? model.selection : [id])
        }
        let waypoints = model.shownWaypoints.filter { dropped.contains($0.id) }
        guard !waypoints.isEmpty else { return false }
        for (offset, waypoint) in waypoints.enumerated() {
            model.addWaypoint(waypoint.id, toRoute: routeID, before: index.map { $0 + offset })
        }
        return true
    }

    // MARK: - Filter and order

    private var filterBar: some View {
        HStack(spacing: 6) {
            TextField("Filter", text: $model.filterText, prompt: Text("Filter"))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            Menu {
                Picker("Sort By", selection: $model.sort) {
                    ForEach(LibrarySort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Descending", isOn: $model.sortDescending)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort by \(model.sort.title)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Items

    private var itemsPane: some View {
        // Routed through the model rather than bound straight at
        // `selection`, so the sidebar can frame what it selects while a map
        // click, which goes through `select(_:)`, leaves the camera alone.
        List(selection: Binding(get: { model.selection },
                                set: { model.selectFromSidebar($0) })) {
            if !model.shownRoutes.isEmpty {
                Section("Routes") {
                    ForEach(model.shownRoutes) { detail in
                        row(id: detail.route.id,
                            name: detail.route.name,
                            detail: (model.summaries[detail.route.id] ?? "")
                                + (model.routing.contains(detail.route.id) ? " · routing…" : ""),
                            color: ItemColor.named(detail.route.color))
                        .tag(detail.route.id)
                        .draggable(detail.route.id)
                        .dropDestination(for: String.self) { ids, _ in
                            drop(ids, onRoute: detail.route.id, before: nil)
                        }
                        .contextMenu {
                            Button("Edit Route") { model.editRoute(detail.route.id) }
                            Button("Reverse Route") { model.reverseRoute(detail.route.id) }
                            routingMenu(for: detail)
                            preferMenu(for: detail)
                            avoidMenu(for: detail)
                            Button("Create Track from Route") { model.makeTrack(fromRoute: detail.route.id) }
                            Divider()
                            renameButton(detail.route.id, detail.route.name)
                            Button("Duplicate") { model.duplicate(detail.route.id) }
                            colorMenu(for: detail.route.id)
                            listMenu(for: detail.route.id)
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
                            .onMove { source, destination in
                                model.movePoints(routeID: detail.route.id, fromOffsets: source, toOffset: destination)
                            }
                        }
                    }
                }
            }

            if !model.shownTracks.isEmpty {
                Section("Tracks") {
                    ForEach(model.shownTracks) { detail in
                        row(id: detail.track.id,
                            name: detail.track.name,
                            detail: model.summaries[detail.track.id] ?? "",
                            color: ItemColor.named(detail.track.color))
                        .tag(detail.track.id)
                        .draggable(detail.track.id)
                        .contextMenu {
                            Button("Create Route from Track") { model.makeRoute(fromTrack: detail.track.id) }
                            Button("Invert Track") { model.invertTrack(detail.track.id) }
                            if selectedTrackCount >= 2, model.selection.contains(detail.track.id) {
                                Button("Join \(selectedTrackCount) Tracks") { model.joinTracks(model.selection) }
                            }
                            simplifyMenu(for: detail)
                            Divider()
                            renameButton(detail.track.id, detail.track.name)
                            Button("Duplicate") { model.duplicate(detail.track.id) }
                            colorMenu(for: detail.track.id)
                            listMenu(for: detail.track.id)
                            Divider()
                            deleteButton(detail.track.id)
                        }
                    }
                }
            }

            if !model.shownWaypoints.isEmpty {
                Section("Waypoints") {
                    ForEach(model.shownWaypoints) { waypoint in
                        // No swatch. A waypoint's appearance on a Garmin is
                        // its symbol, not a display colour, and offering one
                        // here would promise something GPX cannot carry. The
                        // symbol is drawn from the same sprite the map uses,
                        // so the list and the map cannot disagree.
                        row(id: waypoint.id,
                            name: waypoint.name,
                            detail: waypoint.symbol ?? coordinate(waypoint.coordinate)) {
                            SymbolImage(entry: SymbolCatalog.entry(for: waypoint.symbol))
                        }
                        .tag(waypoint.id)
                        .draggable(waypoint.id)
                        .contextMenu {
                            Button("New Route from \(waypoint.name)") {
                                model.startRoute(from: waypoint)
                            }
                            addToRouteMenu(for: waypoint)
                            Divider()
                            renameButton(waypoint.id, waypoint.name)
                            Button("Duplicate") { model.duplicate(waypoint.id) }
                            symbolMenu(for: waypoint)
                            listMenu(for: waypoint.id)
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
                    Text("Import a GPX or GDB file to get started.")
                } actions: {
                    Button("New Route") { model.newRoute() }
                    Button("Import GPX…") { model.isImporting = true }
                }
            } else if model.shownRoutes.isEmpty && model.shownTracks.isEmpty && model.shownWaypoints.isEmpty {
                // Empty because of the list or the filter, not the library.
                Text(model.filterText.isEmpty ? "Nothing in this list" : "No matches")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
        }
        .listStyle(.sidebar)
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
            if point.isVia, let symbol = point.symbol {
                // A stop that is a waypoint, or came from a file as one,
                // wears the symbol the map and the device draw it with.
                SymbolImage(entry: SymbolCatalog.entry(for: symbol))
                    .frame(width: 13)
            } else {
                // The same marks the map draws: a ring for a stop, a small
                // solid dot for a bend in the road.
                Image(systemName: point.isVia ? "circle" : "circle.fill")
                    .font(.system(size: point.isVia ? 11 : 7, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 13)
            }
        }
        .padding(.leading, 16)
        .tag(handle)
        // A waypoint dropped on a stop goes in before it; dropped on the
        // route's own row it goes at the end.
        .dropDestination(for: String.self) { ids, _ in
            drop(ids, onRoute: detail.route.id, before: point.seq)
        }
        .contextMenu {
            if point.isVia {
                renameButton(handle, point.name ?? "")
                Button("Make Shaping Point") { model.setVia(routeID: detail.route.id, seq: point.seq, false) }
            } else {
                Button("Make Via Point") { model.setVia(routeID: detail.route.id, seq: point.seq, true) }
            }
            if let waypointID = point.waypointID, model.waypoints.contains(where: { $0.id == waypointID }) {
                Button("Show Waypoint") { model.selectFromSidebar([waypointID]) }
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
                if !detail.isEmpty {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
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

    // MARK: - Lists menu

    /// Where an item is filed, with the alternative to dragging it there.
    /// The whole selection moves when the item is part of it, as a drag
    /// of it would.
    private func listMenu(for id: String) -> some View {
        let ids = model.selection.contains(id) ? model.selection : [id]
        let current = model.listID(of: id)
        return Menu("Move to List") {
            Button {
                model.file(ids, in: nil)
            } label: {
                Label("My Collection", systemImage: current == nil ? "checkmark" : "")
            }
            if !model.lists.isEmpty { Divider() }
            ForEach(model.lists) { list in
                Button {
                    model.file(ids, in: list.id)
                } label: {
                    Label(list.name, systemImage: current == list.id ? "checkmark" : "")
                }
            }
        }
    }

    /// The alternative to dragging a waypoint onto a route: every route,
    /// the selected waypoints appended to the one chosen.
    private func addToRouteMenu(for waypoint: Waypoint) -> some View {
        let ids = model.selection.contains(waypoint.id) ? model.selection : [waypoint.id]
        return Menu("Add to Route") {
            if model.routes.isEmpty {
                Text("No routes").foregroundStyle(.secondary)
            }
            ForEach(model.routes) { detail in
                Button(detail.route.name) {
                    for chosen in model.shownWaypoints where ids.contains(chosen.id) {
                        model.addWaypoint(chosen.id, toRoute: detail.route.id)
                    }
                }
            }
        }
    }

    // MARK: - Tracks

    private var selectedTrackCount: Int {
        model.shownTracks.filter { model.selection.contains($0.track.id) }.count
    }

    /// The point limits worth thinning to. Ten thousand is what a Garmin
    /// unit takes per track; the smaller ones are for older units and
    /// for a line that only has to look right.
    private static let pointLimits = [500, 2_000, 10_000]

    private func simplifyMenu(for detail: TrackDetail) -> some View {
        Menu("Simplify Track") {
            ForEach(Self.pointLimits, id: \.self) { limit in
                Button("To \(limit.formatted()) points") { model.simplifyTrack(detail.track.id, atMost: limit) }
                    .disabled(detail.points.count <= limit)
            }
        }
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

    /// What the legs optimise for: Garmin's calculation mode with curvy
    /// split in two. See `RoutePreferences`.
    private func preferMenu(for detail: RouteDetail) -> some View {
        Picker("Prefer", selection: Binding(get: { detail.route.preferences.prefer },
                                            set: { prefer in
                                                var next = detail.route.preferences
                                                next.prefer = prefer
                                                model.setPreferences(next, forRoute: detail.route.id)
                                            })) {
            ForEach(RoutePreferences.Preference.allCases, id: \.self) { Text($0.title).tag($0) }
        }
    }

    /// The kinds of road to keep off. Each is a heavy penalty rather than
    /// a ban, so a route that can only end past the toll booth still gets
    /// there.
    private func avoidMenu(for detail: RouteDetail) -> some View {
        Menu("Avoid") {
            avoidToggle("Highways", detail, \.avoidHighways)
            avoidToggle("Tolls", detail, \.avoidTolls)
            avoidToggle("Ferries", detail, \.avoidFerries)
        }
    }

    private func avoidToggle(_ title: String, _ detail: RouteDetail,
                             _ path: WritableKeyPath<RoutePreferences, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { detail.route.preferences[keyPath: path] },
                                    set: { on in
                                        var next = detail.route.preferences
                                        next[keyPath: path] = on
                                        model.setPreferences(next, forRoute: detail.route.id)
                                    }))
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

    // MARK: - Symbol

    /// Garmin's symbols, the waypoint's own ticked. A picker so the tick
    /// is the system's; a symbol the catalog lacks matches no tag and
    /// ticks nothing, which is honest about what the generic marker is.
    private func symbolMenu(for waypoint: Waypoint) -> some View {
        Menu("Change Icon") {
            Picker("Icon", selection: Binding(get: { SymbolCatalog.known(waypoint.symbol)?.name ?? "" },
                                              set: { model.setSymbol($0, forWaypoint: waypoint.id) })) {
                ForEach(SymbolCatalog.groups, id: \.self) { group in
                    Section {
                        ForEach(SymbolCatalog.entries.filter { $0.group == group }, id: \.name) { entry in
                            Label { Text(entry.name) } icon: { SymbolImage(entry: entry) }
                                .tag(entry.name)
                        }
                    }
                }
            }
            .pickerStyle(.inline)
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
struct Swatch: View {
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
