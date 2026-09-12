#if os(macOS)
import SwiftUI

/// Choosing what goes on the device.
///
/// Replaces a single button whose label changed depending on what was
/// selected in a list somewhere else in the window. That coupling was
/// invisible: the same button meant "send everything" or "send these three"
/// with nothing on screen to say which, and the only way to find out was to
/// press it.
struct SendPicker: View {
    var library: LibraryModel
    var storage: DeviceService.StorageSummary
    var send: ([(name: String, data: Data)]) -> Void

    @State private var chosen: Set<String> = []
    @State private var asSeparateFiles = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 340)
        .frame(maxHeight: 460)
        .onAppear(perform: preselect)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Send to \(storage.name)").font(.headline)
            Text("Files go in the device's GPX folder.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                section("Routes", library.routes.map { ($0.route.id, $0.route.name) })
                section("Tracks", library.tracks.map { ($0.track.id, $0.track.name) })
                section("Waypoints", library.waypoints.map { ($0.id, $0.name) })
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [(id: String, name: String)]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.caption).bold().foregroundStyle(.secondary)
                    Spacer()
                    Button(allChosen(items) ? "None" : "All") { toggleAll(items) }
                        .buttonStyle(.link).font(.caption)
                }
                ForEach(items, id: \.id) { item in
                    Toggle(isOn: binding(for: item.id)) {
                        Text(item.name).lineLimit(1)
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            // One file per item by default, because the unit lists what it
            // finds by filename. Three routes in one Swiftcamp.gpx appear on
            // the device as a single entry called Swiftcamp, which is no
            // help at all at a petrol stop.
            Picker("", selection: $asSeparateFiles) {
                Text("A file for each").tag(true)
                Text("One file").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Send") { dispatch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
            }
        }
        .padding(12)
    }

    // MARK: - State

    /// Starts from whatever is selected in the sidebar, or everything when
    /// nothing is. The selection still seeds this — it just no longer decides
    /// silently.
    private func preselect() {
        guard chosen.isEmpty else { return }
        chosen = library.selection.isEmpty ? Set(everyID) : library.selection.intersection(everyID)
        if chosen.isEmpty { chosen = Set(everyID) }
    }

    private var everyID: [String] {
        library.routes.map(\.route.id) + library.tracks.map(\.track.id) + library.waypoints.map(\.id)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { chosen.contains(id) },
                set: { isOn in
                    if isOn { chosen.insert(id) } else { chosen.remove(id) }
                })
    }

    private func allChosen(_ items: [(id: String, name: String)]) -> Bool {
        items.allSatisfy { chosen.contains($0.id) }
    }

    private func toggleAll(_ items: [(id: String, name: String)]) {
        if allChosen(items) {
            items.forEach { chosen.remove($0.id) }
        } else {
            items.forEach { chosen.insert($0.id) }
        }
    }

    private var summary: String {
        let count = chosen.count
        let noun = count == 1 ? "item" : "items"
        return asSeparateFiles && count > 1 ? "\(count) \(noun), \(count) files"
                                            : "\(count) \(noun)"
    }

    // MARK: - Sending

    private func dispatch() {
        guard !chosen.isEmpty else { return }

        if asSeparateFiles {
            let files = chosen.compactMap { id -> (name: String, data: Data)? in
                guard let document = library.document(for: id) else { return nil }
                let name = library.name(for: id) ?? "Route"
                return (DeviceFilename.make(from: name), GPXWriter.data(document))
            }
            send(files.sorted { $0.name < $1.name })
        } else if let document = library.document(for: chosen) {
            send([(DeviceFilename.make(from: "Swiftcamp"), GPXWriter.data(document))])
        }
    }
}
#endif
