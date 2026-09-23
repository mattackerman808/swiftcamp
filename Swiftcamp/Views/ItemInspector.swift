#if os(macOS)
import SwiftUI

/// The selected item's fields, under the sidebar: what BaseCamp puts in a
/// properties dialog, kept in view instead so notes can be read while
/// looking at the map.
///
/// Text is typed into a draft and written when the field is left or
/// submitted, not per keystroke. Every write is an undo step, and a step
/// per character would make Undo useless; it would also re-render the map
/// on every letter of a note.
struct ItemInspector: View {
    @Bindable var model: LibraryModel
    let id: String

    private enum Field: Hashable { case name, comment, notes, lat, lon, elevation }
    @FocusState private var focused: Field?

    @State private var name = ""
    @State private var comment = ""
    @State private var notes = ""
    @State private var lat = ""
    @State private var lon = ""
    @State private var elevation = ""

    private var waypoint: Waypoint? { model.waypoints.first { $0.id == id } }
    private var route: Route? { model.routes.first { $0.route.id == id }?.route }
    private var track: Track? { model.tracks.first { $0.track.id == id }?.track }

    var body: some View {
        Group {
            if let waypoint {
                form(kind: "Waypoint") { waypointFields(waypoint) }
            } else if let route {
                form(kind: "Route") { routeFields(route) }
            } else if let track {
                form(kind: "Track") { trackFields(track) }
            }
        }
        .onAppear(perform: load)
        .onChange(of: id) { load() }
        // An undo, a drag on the map or a rename in the list changes the
        // record under the form; the draft follows unless it is being
        // typed in, when the typist wins.
        .onChange(of: waypoint) { if focused == nil { load() } }
        .onChange(of: route) { if focused == nil { load() } }
        .onChange(of: track) { if focused == nil { load() } }
        .onChange(of: focused) { previous, _ in
            if previous != nil { commit() }
        }
    }

    private func form(kind: String, @ViewBuilder fields: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(kind).font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                fields()
            }
        }
        .controlSize(.small)
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Fields

    @ViewBuilder
    private func waypointFields(_ waypoint: Waypoint) -> some View {
        labelled("Name") {
            TextField("Name", text: $name).focused($focused, equals: .name).onSubmit(commit)
        }
        labelled("Symbol") {
            Picker("Symbol", selection: Binding(get: { SymbolCatalog.known(waypoint.symbol)?.name ?? "" },
                                                set: { model.setSymbol($0, forWaypoint: waypoint.id) })) {
                if SymbolCatalog.known(waypoint.symbol) == nil {
                    // A symbol the catalog lacks, carried through from a
                    // file: named so the user knows what the device draws.
                    Text(waypoint.symbol ?? "None").tag("")
                }
                ForEach(SymbolCatalog.groups, id: \.self) { group in
                    Section {
                        ForEach(SymbolCatalog.entries.filter { $0.group == group }, id: \.name) { entry in
                            Label { Text(entry.name) } icon: { SymbolImage(entry: entry) }.tag(entry.name)
                        }
                    }
                }
            }
            .labelsHidden()
        }
        labelled("Position") {
            HStack(spacing: 4) {
                TextField("Latitude", text: $lat).focused($focused, equals: .lat).onSubmit(commit)
                TextField("Longitude", text: $lon).focused($focused, equals: .lon).onSubmit(commit)
            }
        }
        labelled("Elevation") {
            HStack(spacing: 4) {
                TextField("Elevation", text: $elevation).focused($focused, equals: .elevation).onSubmit(commit)
                Text("ft").foregroundStyle(.secondary)
            }
        }
        labelled("Comment") {
            TextField("Comment", text: $comment).focused($focused, equals: .comment).onSubmit(commit)
        }
        labelled("Notes") { notesEditor }
    }

    @ViewBuilder
    private func routeFields(_ route: Route) -> some View {
        labelled("Name") {
            TextField("Name", text: $name).focused($focused, equals: .name).onSubmit(commit)
        }
        labelled("Colour") { colorPicker(route.color) }
        labelled("Routing") {
            Picker("Routing", selection: Binding(get: { route.mode },
                                                 set: { model.setMode($0, forRoute: route.id) })) {
                ForEach(RoutingMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .labelsHidden()
        }
        labelled("Comment") {
            TextField("Comment", text: $comment).focused($focused, equals: .comment).onSubmit(commit)
        }
        if let summary = model.summaries[route.id] {
            labelled("") { Text(summary).font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder
    private func trackFields(_ track: Track) -> some View {
        labelled("Name") {
            TextField("Name", text: $name).focused($focused, equals: .name).onSubmit(commit)
        }
        labelled("Colour") { colorPicker(track.color) }
        labelled("Comment") {
            TextField("Comment", text: $comment).focused($focused, equals: .comment).onSubmit(commit)
        }
        if let summary = model.summaries[track.id] {
            labelled("") { Text(summary).font(.caption).foregroundStyle(.secondary) }
        }
    }

    /// Garmin's sixteen and nothing else, as the sidebar's menu offers.
    private func colorPicker(_ current: String?) -> some View {
        Picker("Colour", selection: Binding(get: { ItemColor.named(current)?.name ?? "" },
                                            set: { name in
                                                if let color = ItemColor.named(name) { model.setColor(color, for: id) }
                                            })) {
            if ItemColor.named(current) == nil { Text("None").tag("") }
            ForEach(ItemColor.palette) { color in
                Label { Text(color.name) } icon: { Swatch(color: color) }.tag(color.name)
            }
        }
        .labelsHidden()
    }

    /// Several lines, for the description Garmin shows under a waypoint.
    /// Written when the editor loses focus; it has no submit.
    private var notesEditor: some View {
        TextEditor(text: $notes)
            .font(.body)
            .frame(minHeight: 44, maxHeight: 88)
            .focused($focused, equals: .notes)
            .overlay {
                RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary)
            }
    }

    private func labelled(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Draft

    private func load() {
        if let waypoint {
            name = waypoint.name
            comment = waypoint.comment ?? ""
            notes = waypoint.descriptionText ?? ""
            lat = String(format: "%.5f", waypoint.lat)
            lon = String(format: "%.5f", waypoint.lon)
            elevation = waypoint.elevation.map { String(format: "%.0f", $0 / 0.3048) } ?? ""
        } else if let route {
            name = route.name
            comment = route.comment ?? ""
        } else if let track {
            name = track.name
            comment = track.comment ?? ""
        }
    }

    /// Writes the draft back, one undo step for whatever changed.
    private func commit() {
        func text(_ s: String) -> String? {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if var waypoint {
            if let name = text(name) { waypoint.name = name }
            waypoint.comment = text(comment)
            waypoint.descriptionText = text(notes)
            // A position that does not parse is left as it was; the draft
            // reloads to show what is really stored.
            if let lat = Double(lat.trimmingCharacters(in: .whitespaces)), abs(lat) <= 90 { waypoint.lat = lat }
            if let lon = Double(lon.trimmingCharacters(in: .whitespaces)), abs(lon) <= 180 { waypoint.lon = lon }
            if let feet = text(elevation) {
                if let feet = Double(feet) { waypoint.elevation = (feet * 0.3048).rounded() }
            } else {
                waypoint.elevation = nil
            }
            model.update(waypoint)
        } else if var route {
            if let name = text(name) { route.name = name }
            route.comment = text(comment)
            model.update(route)
        } else if var track {
            if let name = text(name) { track.name = name }
            track.comment = text(comment)
            model.update(track)
        }
        load()
    }
}
#endif
