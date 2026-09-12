#if os(macOS)
import Observation
import SwiftUI

/// What is on the device, and what to put on it.
@Observable
@MainActor
final class DeviceModel {
    private(set) var units: [GarminUnit] = []
    private(set) var otherDevices: [GarminUnit] = []
    private(set) var snapshot: DeviceService.Snapshot?
    private(set) var isWorking = false
    private(set) var status: String?
    var failure: String?

    /// Where the browser is looking.
    struct Crumb: Identifiable, Hashable {
        var name: String
        var handle: UInt32
        var id: UInt32 { handle }
    }

    private(set) var browsePath: [Crumb] = []
    private(set) var browseFiles: [DeviceFile] = []
    private(set) var browseStorage: UInt32?

    /// What each inspected file turned out to hold, keyed by object handle.
    private(set) var summaries: [UInt32: GPXSummary] = [:]

    @ObservationIgnored private let service = DeviceService()

    func scan() {
        units = service.garmins()
        // Everything else, so a unit reporting an unexpected vendor id shows
        // up as a device we can see rather than as nothing at all.
        otherDevices = service.allDevices().filter { $0.vendorID != GarminUnit.vendorID }
        status = units.isEmpty ? "No Garmin found." : nil
    }

    func connect(to unit: GarminUnit) {
        run("Connecting…") { [service] in
            let snapshot = try await service.connect(to: unit)
            // Clearing the status matters: leaving "Connecting…" up after it
            // has connected reads as a job still running, which is the one
            // thing a progress message must never say when it is finished.
            return {
                self.snapshot = snapshot
                self.status = nil
                // Straight to the files. Connecting and then being asked to
                // press Browse is a step that exists only because the code is
                // arranged that way.
                if let first = snapshot.storages.first { self.open(first) }
            }
        }
    }

    /// Opens a storage at its GPX folder, or at the root when it has none.
    func open(_ storage: DeviceService.StorageSummary) {
        browseStorage = storage.id
        if let folder = storage.gpxFolder {
            browsePath = [Crumb(name: "GPX", handle: folder)]
            list(storage: storage.id, parent: folder)
        } else {
            browsePath = []
            list(storage: storage.id, parent: MTP.rootParent)
        }
    }

    func disconnect() {
        snapshot = nil
        Task { await service.disconnect() }
    }

    /// Writes one GPX file into the device's GPX folder and shows it.
    func send(_ data: Data, named name: String, to storage: UInt32) {
        run("Sending \(name)…") { [service] in
            try await service.send(data, named: name, to: storage)
            // The send may have created the folder, so the handle is only
            // knowable afterwards.
            let folder = try await service.gpxFolder(storage: storage)
            let files = try await service.list(storage: storage,
                                               parent: folder ?? MTP.rootParent)
            return {
                self.browseStorage = storage
                self.browsePath = folder.map { [Crumb(name: "GPX", handle: $0)] } ?? []
                self.browseFiles = files
                self.status = "Sent \(name)."
            }
        }
    }

    /// Reads one file and records what is in it.
    func inspect(_ file: DeviceFile) {
        run("Reading \(file.name)…") { [service] in
            let summary = try await service.inspect(file)
            return { self.summaries[file.handle] = summary; self.status = nil }
        }
    }

    /// Inspects every GPX in the folder, one after another.
    ///
    /// Serially, not in parallel. One USB pipe pair carries one transaction,
    /// so concurrency here would not be faster and would interleave replies.
    func inspectAll() {
        let pending = browseFiles.filter {
            !$0.isFolder && $0.name.lowercased().hasSuffix(".gpx") && summaries[$0.handle] == nil
        }
        guard !pending.isEmpty else { return }

        run("Reading \(pending.count) files…") { [service] in
            var found: [UInt32: GPXSummary] = [:]
            for file in pending {
                // One unreadable file must not stop the rest. A device folder
                // can hold a log the unit was part-way through writing.
                if let summary = try? await service.inspect(file) {
                    found[file.handle] = summary
                }
            }
            return {
                self.summaries.merge(found) { _, new in new }
                self.status = nil
            }
        }
    }

    func read(_ file: DeviceFile, then handle: @escaping (Data) -> Void) {
        run("Reading \(file.name)…") { [service] in
            let data = try await service.read(file)
            return { handle(data); self.status = "Read \(file.name)." }
        }
    }

    // MARK: - Browsing

    func browseRoot(_ storage: UInt32) {
        browseStorage = storage
        browsePath = []
        list(storage: storage, parent: MTP.rootParent)
    }

    func descend(into folder: DeviceFile) {
        guard let storage = browseStorage else { return }
        browsePath.append(Crumb(name: folder.name, handle: folder.handle))
        list(storage: storage, parent: folder.handle)
    }

    /// Back to a crumb, or to the root when `index` is nil.
    func ascend(to index: Int?) {
        guard let storage = browseStorage else { return }
        if let index {
            browsePath = Array(browsePath.prefix(index + 1))
            list(storage: storage, parent: browsePath[index].handle)
        } else {
            browsePath = []
            list(storage: storage, parent: MTP.rootParent)
        }
    }

    private func list(storage: UInt32, parent: UInt32) {
        run("Reading folder…") { [service] in
            let files = try await service.list(storage: storage, parent: parent)
            return { self.browseFiles = files; self.status = nil }
        }
    }

    /// Runs device work off the main actor and applies the result on it.
    ///
    /// Every USB call blocks its thread, so none of them can happen where the
    /// window lives — the same mistake that froze the app on import.
    private func run(_ label: String, _ work: @escaping () async throws -> () -> Void) {
        guard !isWorking else { return }
        isWorking = true
        status = label
        failure = nil

        Task {
            do {
                let apply = try await work()
                // Cleared *before* applying, and the order is the whole bug
                // this once had. An apply block may start the next piece of
                // work — connecting opens the GPX folder — and that call went
                // through `run`, which saw the flag still set and dropped it
                // on the floor. The panel then showed an empty folder until
                // something else made it ask again.
                isWorking = false
                apply()
            } catch {
                failure = error.localizedDescription
                status = nil
                isWorking = false
            }
        }
    }
}

/// The device sheet.
struct DevicePanel: View {
    @Bindable var library: LibraryModel
    @State private var model = DeviceModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            Group {
                if let snapshot = model.snapshot {
                    connected(snapshot)
                } else {
                    chooser
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            footer
        }
        // Resizable, and taller by default. A device's archive folder holds
        // as many track logs as the unit has rotated, and a fixed sheet that
        // shows four of them is a list the user cannot read.
        .frame(minWidth: 560, idealWidth: 640, maxWidth: .infinity,
               minHeight: 460, idealHeight: 680, maxHeight: .infinity)
        .onAppear { model.scan() }
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Label("Device", systemImage: "cable.connector")
                .font(.headline)
            Spacer()
            if model.isWorking { ProgressView().controlSize(.small) }
        }
        .padding(12)
    }

    private var chooser: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if model.units.isEmpty {
                    // Not an error state. A Garmin that is switched off, or
                    // sitting in its cradle unpowered, is simply not there.
                    ContentUnavailableView {
                        Label("No Garmin connected", systemImage: "cable.connector.slash")
                    } description: {
                        Text("Connect the device with a USB cable and switch it on. "
                             + "It does not need to appear in Finder.")
                    } actions: {
                        Button("Scan Again") { model.scan() }
                    }
                    .padding(.top, 30)
                } else {
                    Text("Garmin devices").font(.subheadline).bold()
                    ForEach(model.units) { unit in
                        Button { model.connect(to: unit) } label: {
                            row(unit, highlighted: true)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !model.otherDevices.isEmpty {
                    // Deliberately visible. If a Garmin ever reports a vendor
                    // id we do not know, this is the list it will be hiding
                    // in, and an empty panel would say nothing.
                    DisclosureGroup("Other USB devices (\(model.otherDevices.count))") {
                        ForEach(model.otherDevices) { unit in
                            row(unit, highlighted: false)
                        }
                    }
                    .font(.subheadline)
                }
            }
            .padding(14)
        }
    }

    private func row(_ unit: GarminUnit, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: highlighted ? "location.circle.fill" : "shippingbox")
                .foregroundStyle(highlighted ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(unit.name)
                Text(String(format: "%04X:%04X", unit.vendorID, unit.productID))
                    .font(.caption).monospaced().foregroundStyle(.secondary)
            }
            Spacer()
            if highlighted { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(highlighted ? Color.secondary.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
    }

    /// Storage headers, then the folder you are standing in.
    ///
    /// One list, not two. The panel used to show the GPX folder's contents
    /// and then offer a Browse button that showed the same files again a few
    /// pixels lower, which is a distinction that only made sense from inside
    /// the code.
    private func connected(_ snapshot: DeviceService.Snapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.model).font(.title3).bold()
                    if !snapshot.serialNumber.isEmpty {
                        Text("Serial \(snapshot.serialNumber)")
                            .font(.caption).monospaced().foregroundStyle(.secondary)
                    }
                }

                ForEach(snapshot.storages) { storage in
                    storageRow(storage)
                }

                if model.browseStorage != nil {
                    Divider()
                    browser
                }
            }
            .padding(14)
        }
    }

    private func storageRow(_ storage: DeviceService.StorageSummary) -> some View {
        let isOpen = model.browseStorage == storage.id
        return HStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .foregroundStyle(isOpen ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(storage.name).bold()
                Text(capacity(storage)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                sendLibrary(to: storage.id)
            } label: {
                Label(sendLabel, systemImage: "arrow.up.circle")
            }
            .controlSize(.small)
            .disabled(model.isWorking || library.routes.isEmpty
                      && library.tracks.isEmpty && library.waypoints.isEmpty)
        }
        .font(.callout)
        .padding(10)
        .contentShape(Rectangle())
        .background(isOpen ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8))
        // Only meaningful with a card in as well as internal storage, but
        // then it is the only way to reach the card.
        .onTapGesture { model.open(storage) }
    }

    /// Where you are on the device.
    private var browser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Button("Device") { model.ascend(to: nil) }
                    .buttonStyle(.link)
                ForEach(Array(model.browsePath.enumerated()), id: \.element.id) { index, crumb in
                    Text("/").foregroundStyle(.tertiary)
                    Button(crumb.name) { model.ascend(to: index) }
                        .buttonStyle(.link)
                }
                Spacer()
                if model.browseFiles.count > 8 {
                    Text("\(model.browseFiles.count) items").foregroundStyle(.secondary)
                }
                if gpxCount > 1 {
                    Button("Identify All") { model.inspectAll() }
                        .buttonStyle(.link)
                        .disabled(model.isWorking)
                }
            }
            .font(.caption)

            if model.browseFiles.isEmpty {
                Text(model.browsePath.isEmpty
                     ? "Nothing on this storage."
                     : "This folder is empty.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ForEach(model.browseFiles) { file in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: file.isFolder ? "folder.fill" : "doc")
                        .foregroundStyle(file.isFolder ? Color.accentColor : .secondary)

                    VStack(alignment: .leading, spacing: 1) {
                        if file.isFolder {
                            Button(file.name) { model.descend(into: file) }
                                .buttonStyle(.plain)
                        } else {
                            Text(file.name)
                            Text(subtitle(for: file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if !file.isFolder, file.name.lowercased().hasSuffix(".gpx") {
                        if model.summaries[file.handle] == nil {
                            Button("Identify") { model.inspect(file) }
                                .controlSize(.small)
                                .disabled(model.isWorking)
                        }
                        // Anywhere on the device, not only in the folder we
                        // opened at. The archived track logs are the rider's
                        // own history and they sit a level down.
                        Button("Import") { importFromDevice(file) }
                            .controlSize(.small)
                            .disabled(model.isWorking)
                    }
                }
                .font(.callout)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).lineLimit(2)
            } else if let status = model.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.snapshot != nil {
                Button("Disconnect") { model.disconnect() }
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: - Actions

    private var sendLabel: String {
        library.selection.isEmpty ? "Send Whole Library" : "Send Selection"
    }

    private func sendLibrary(to storage: UInt32) {
        guard let document = library.exportDocument() else { return }
        model.send(GPXWriter.data(document), named: "Swiftcamp.gpx", to: storage)
    }

    private func importFromDevice(_ file: DeviceFile) {
        model.read(file) { data in library.importGPX(data: data, named: file.name) }
    }

    private func capacity(_ storage: DeviceService.StorageSummary) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        guard storage.capacityBytes > 0 else { return "" }
        return "\(formatter.string(fromByteCount: Int64(storage.freeBytes))) free "
             + "of \(formatter.string(fromByteCount: Int64(storage.capacityBytes)))"
    }

    private var gpxCount: Int {
        model.browseFiles.filter { !$0.isFolder && $0.name.lowercased().hasSuffix(".gpx") }.count
    }

    /// What is known about a file, best first.
    ///
    /// Contents beat a timestamp, and a timestamp beats a byte count. A name
    /// like `18.gpx` says nothing; "3 tracks · 12–14 Aug · 340 mi" is the
    /// thing the rider is actually looking for.
    private func subtitle(for file: DeviceFile) -> String {
        var parts: [String] = []

        if let summary = model.summaries[file.handle] {
            parts.append(contentsOf: contents(of: summary))
            if let span = dateSpan(summary) { parts.append(span) }
            if summary.distance > 0 { parts.append(distance(summary.distance)) }
        } else if let modified = file.modified {
            parts.append(Self.dayFormatter.string(from: modified))
        }

        parts.append(size(file.size))
        return parts.joined(separator: " · ")
    }

    private func contents(of summary: GPXSummary) -> [String] {
        var parts: [String] = []
        if summary.tracks > 0 { parts.append(count(summary.tracks, "track")) }
        if summary.routes > 0 { parts.append(count(summary.routes, "route")) }
        if summary.waypoints > 0 { parts.append(count(summary.waypoints, "waypoint")) }
        if parts.isEmpty { parts.append("empty") }
        return parts
    }

    private func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// "12–14 Aug 2026", or one date when it is all one day.
    private func dateSpan(_ summary: GPXSummary) -> String? {
        guard let start = summary.start else { return nil }
        guard let end = summary.end,
              !Calendar.current.isDate(start, inSameDayAs: end) else {
            return Self.dayFormatter.string(from: start)
        }
        return Self.rangeFormatter.string(from: start, to: end)
    }

    private func distance(_ metres: Double) -> String {
        String(format: "%.0f mi", metres / 1609.344)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    private static let rangeFormatter: DateIntervalFormatter = {
        let f = DateIntervalFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private func size(_ bytes: UInt32) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
#endif
