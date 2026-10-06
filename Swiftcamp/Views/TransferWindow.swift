#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

/// Moving things between the Mac and the device.
///
/// Two panes, library on the left and device on the right, and you drag
/// between them. This replaces a modal sheet with an Export button in it,
/// which put the whole point of the feature behind a dialog and a verb.
///
/// A window rather than a sheet, and that is the substance of the change:
/// a sheet is a question the app asks, and moving files onto a device is not
/// a question. It is the work.
struct TransferWindow: View {
    static let id = "transfer"

    @Bindable var library: LibraryModel
    @State private var device = DeviceModel()

    var body: some View {
        HSplitView {
            LibraryPane(library: library, device: device)
                .frame(minWidth: 260, idealWidth: 320)
            DevicePane(library: library, device: device)
                .frame(minWidth: 320, idealWidth: 420)
        }
        .frame(minWidth: 700, minHeight: 420)
        .onAppear {
            device.startWatching()
            // Never restored at launch. An app that opens on the Transfer
            // window alone looks like one that has lost its map.
            NSApp.windows.first { $0.identifier?.rawValue == Self.id }?.isRestorable = false
        }
        .onDisappear { device.stopWatching() }
        .safeAreaInset(edge: .bottom) { statusBar }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if device.isWorking { ProgressView().controlSize(.small) }

            if let failure = device.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).lineLimit(2)
            } else if let status = device.status {
                Text(status).foregroundStyle(.secondary)
            } else if let remaining = device.scanRemaining {
                Text("reading \(remaining)…").foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Drag payloads

/// What a drag carries.
///
/// A tagged string rather than a custom uniform type. Declaring one would
/// mean a real Info.plist on a target that generates its own, and the tag
/// does the same job for a drag that never leaves this app: anything without
/// the right first line is not ours and is refused.
enum DragPayload {
    static let libraryTag = "swiftcamp.library"
    static let deviceTag = "swiftcamp.device"

    static func encode(tag: String, _ values: [String]) -> String {
        ([tag] + values).joined(separator: "\n")
    }

    static func decode(tag: String, _ text: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        guard lines.first == tag else { return [] }
        return Array(lines.dropFirst()).filter { !$0.isEmpty }
    }
}

// MARK: - Library side

private struct LibraryPane: View {
    @Bindable var library: LibraryModel
    var device: DeviceModel

    @State private var chosen: Set<String> = []
    @State private var isTarget = false

    /// What the device gets, remembered between sends. See `DeviceExport`.
    @AppStorage(DeviceExport.defaultsKeys.strip) private var stripShapingPoints = false
    @AppStorage(DeviceExport.defaultsKeys.limit) private var limitTracks = true

    private var export: DeviceExport {
        DeviceExport(stripShapingPoints: stripShapingPoints,
                     trackPointLimit: limitTracks ? DeviceExport.garminTrackLimit : nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Library", subtitle: subtitle) {
                Button {
                    exportChosen()
                } label: {
                    Label("Copy to Device", systemImage: "arrow.right")
                }
                .help("Copy the selected items to the device")
                .disabled(chosen.isEmpty || device.snapshot == nil || device.isWorking)
            }
            // The two things BaseCamp asks on the way out, as settings
            // rather than a dialog per send.
            HStack(spacing: 14) {
                Toggle("Strip shaping points", isOn: $stripShapingPoints)
                    .help("Send only the stops, each carrying the whole road to the next. For a unit that announces every bend as a destination.")
                Toggle("Limit tracks to \(DeviceExport.garminTrackLimit.formatted()) points", isOn: $limitTracks)
                    .help("Thin a longer recording to what a Garmin will take, keeping the line within a couple of metres.")
                Spacer()
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            List(selection: $chosen) {
                section("Routes", library.routes.map { ($0.route.id, $0.route.name,
                                                        library.summaries[$0.route.id] ?? "") })
                section("Tracks", library.tracks.map { ($0.track.id, $0.track.name,
                                                        library.summaries[$0.track.id] ?? "") })
                section("Waypoints", library.waypoints.map { ($0.id, $0.name, $0.symbol ?? "") })
            }
            .listStyle(.inset)
            // Dropping device files here imports them, which is the same
            // gesture in the other direction and needs no button at all.
            .dropDestination(for: String.self) { items, _ in
                importDropped(items)
            } isTargeted: { isTarget = $0 }
            .overlay {
                if isTarget {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(4)
                }
            }
        }
    }

    private var subtitle: String {
        let total = library.routes.count + library.tracks.count + library.waypoints.count
        return chosen.isEmpty ? "\(total) items" : "\(chosen.count) of \(total) selected"
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [(id: String, name: String, detail: String)]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items, id: \.id) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name)
                        if !item.detail.isEmpty {
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(item.id)
                    // Dragging a row that is not in the selection carries
                    // just that row, which is what every file list does and
                    // what stops a stray drag moving something unexpected.
                    .draggable(DragPayload.encode(tag: DragPayload.libraryTag,
                                                  chosen.contains(item.id) ? Array(chosen) : [item.id]))
                }
            }
        }
    }

    private func exportChosen() {
        device.export(library.files(for: chosen, export: export))
    }

    private func importDropped(_ items: [String]) -> Bool {
        let handles = items.flatMap { DragPayload.decode(tag: DragPayload.deviceTag, $0) }
            .compactMap(UInt32.init)
        guard !handles.isEmpty else { return false }
        device.importToLibrary(handles: handles, into: library)
        return true
    }
}

// MARK: - Device side

private struct DevicePane: View {
    @Bindable var library: LibraryModel
    @Bindable var device: DeviceModel

    @State private var chosen: Set<UInt32> = []
    @State private var isTarget = false

    var body: some View {
        VStack(spacing: 0) {
            if let snapshot = device.snapshot {
                PaneHeader(title: snapshot.model, subtitle: path) {
                    Button {
                        importChosen()
                    } label: {
                        Label("Copy to Library", systemImage: "arrow.left")
                    }
                    .help("Copy the selected files into the library")
                    .disabled(chosen.isEmpty || device.isWorking)

                    Button("Eject", systemImage: "eject") { device.disconnect() }
                        .labelStyle(.iconOnly)
                        .help("Disconnect")
                }
                breadcrumb
                if device.browseStorage == nil, hasSeveralStorages {
                    storageList
                } else {
                    files
                }
            } else if device.isWorking {
                // Connecting happens on its own when there is one device, so
                // the first thing the pane shows is usually this rather than
                // a list to click through.
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Connecting…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chooser
            }
        }
    }

    /// True when the device has more than one storage, which on a zūmo means
    /// a memory card is in. Then the storages are a level of their own.
    private var hasSeveralStorages: Bool {
        (device.snapshot?.storages.count ?? 0) > 1
    }

    private var path: String {
        var parts = ["Device"]
        if hasSeveralStorages, !device.storageName.isEmpty, device.browseStorage != nil {
            parts.append(device.storageName)
        }
        return (parts + device.browsePath.map(\.name)).joined(separator: " / ")
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button("Device") {
                if hasSeveralStorages { device.showStorages() } else { device.ascend(to: nil) }
            }
            .buttonStyle(.link)

            if hasSeveralStorages, device.browseStorage != nil, !device.storageName.isEmpty {
                Text("/").foregroundStyle(.tertiary)
                Button(device.storageName) { device.ascend(to: nil) }.buttonStyle(.link)
            }
            ForEach(Array(device.browsePath.enumerated()), id: \.element.id) { index, crumb in
                Text("/").foregroundStyle(.tertiary)
                Button(crumb.name) { device.ascend(to: index) }.buttonStyle(.link)
            }
            Spacer()
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    /// The storages, when there is a choice to make.
    private var storageList: some View {
        List {
            ForEach(device.snapshot?.storages ?? [], id: \.id) { storage in
                HStack(spacing: 8) {
                    Image(systemName: storage.isRemovable ? "sdcard" : "internaldrive")
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(storage.name)
                        Text(free(storage)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
                .onTapGesture { device.open(storage) }
            }
        }
        .listStyle(.inset)
    }

    private func free(_ storage: DeviceService.StorageSummary) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(storage.freeBytes)) + " free of "
            + formatter.string(fromByteCount: Int64(storage.capacityBytes))
    }

    private var files: some View {
        List(selection: $chosen) {
            ForEach(device.browseFiles) { file in
                HStack(spacing: 8) {
                    Image(systemName: file.isFolder ? "folder.fill" : "doc")
                        .foregroundStyle(file.isFolder ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                        Text(subtitle(for: file)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !file.isFolder, device.summaries[file.handle]?.depth == .ends {
                        Button { device.identifyFully(file) } label: { Image(systemName: "info.circle") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Read the whole file (\(size(file.size))) to count its tracks "
                                  + "and measure how far they go.")
                    }
                }
                .tag(file.handle)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if file.isFolder { device.descend(into: file) } }
                .draggable(DragPayload.encode(tag: DragPayload.deviceTag,
                                              dragging(file).map(String.init)))
            }
        }
        .listStyle(.inset)
        .dropDestination(for: String.self) { items, _ in
            exportDropped(items)
        } isTargeted: { isTarget = $0 }
        .overlay {
            if isTarget {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
            }
        }
    }

    private var chooser: some View {
        VStack(spacing: 14) {
            if device.units.isEmpty {
                // No button. The app is already watching, and asking
                // someone to press Scan Again after plugging in a cable is
                // asking them to do the noticing.
                ContentUnavailableView {
                    Label("Looking for a device…", systemImage: "cable.connector.slash")
                } description: {
                    Text("Connect a Garmin with a USB cable and switch it on, "
                         + "or put its memory card in a reader. Either will "
                         + "appear here on its own.")
                }
            } else {
                // Only ever reached with more than one attached, since a
                // single device connects itself.
                Text("Choose a device").font(.subheadline).bold()
                ForEach(device.units) { unit in
                    Button { device.connect(to: unit) } label: {
                        HStack {
                            Image(systemName: unit.volume == nil ? "location.circle.fill" : "sdcard.fill")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(unit.name)
                                Text(unit.volume?.path ?? String(format: "%04X:%04X", unit.vendorID, unit.productID))
                                    .font(.caption).monospaced().foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Actions

    private func dragging(_ file: DeviceFile) -> [UInt32] {
        chosen.contains(file.handle) ? Array(chosen) : [file.handle]
    }

    private func importChosen() {
        device.importToLibrary(handles: Array(chosen), into: library)
    }

    private func exportDropped(_ items: [String]) -> Bool {
        let ids = items.flatMap { DragPayload.decode(tag: DragPayload.libraryTag, $0) }
        guard !ids.isEmpty else { return false }
        device.export(library.files(for: Set(ids), export: DeviceExport.stored))
        return true
    }

    private func subtitle(for file: DeviceFile) -> String {
        guard !file.isFolder else { return "Folder" }
        var parts: [String] = []
        if let identification = device.summaries[file.handle] {
            parts.append(contentsOf: DeviceSummaryText.contents(identification))
            if let span = DeviceSummaryText.dateSpan(identification.summary) { parts.append(span) }
            if identification.summary.distance > 0 {
                parts.append(DeviceSummaryText.distance(identification.summary.distance))
            }
        } else if let modified = file.modified {
            parts.append(DeviceSummaryText.day(modified))
        }
        parts.append(size(file.size))
        return parts.joined(separator: " · ")
    }

    private func size(_ bytes: UInt32) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Shared chrome

private struct PaneHeader<Actions: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
#endif
