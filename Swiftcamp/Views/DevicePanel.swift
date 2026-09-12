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
            return { self.snapshot = snapshot; self.status = nil }
        }
    }

    func disconnect() {
        snapshot = nil
        Task { await service.disconnect() }
    }

    /// Writes one GPX file into `Garmin/GPX`.
    func send(_ data: Data, named name: String, to storage: UInt32) {
        run("Sending \(name)…") { [service] in
            try await service.send(data, named: name, to: storage)
            let files = try await service.refresh(storage: storage)
            return {
                self.replaceFiles(files, in: storage)
                self.status = "Sent \(name)."
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

    func closeBrowser() {
        browseStorage = nil
        browsePath = []
        browseFiles = []
    }

    private func list(storage: UInt32, parent: UInt32) {
        run("Reading folder…") { [service] in
            let files = try await service.list(storage: storage, parent: parent)
            return { self.browseFiles = files; self.status = nil }
        }
    }

    private func replaceFiles(_ files: [DeviceFile], in storage: UInt32) {
        guard var snapshot else { return }
        for index in snapshot.storages.indices where snapshot.storages[index].id == storage {
            snapshot.storages[index].gpxFiles = files
            snapshot.storages[index].gpxFolderMissing = false
        }
        self.snapshot = snapshot
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
                apply()
            } catch {
                failure = error.localizedDescription
                status = nil
            }
            isWorking = false
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

    private func connected(_ snapshot: DeviceService.Snapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.model).font(.title3).bold()
                    if !snapshot.serialNumber.isEmpty {
                        Text("Serial \(snapshot.serialNumber)")
                            .font(.caption).monospaced().foregroundStyle(.secondary)
                    }
                }

                ForEach(snapshot.storages) { storage in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label(storage.name, systemImage: "internaldrive")
                                .font(.subheadline).bold()
                            Spacer()
                            Text(capacity(storage))
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        if storage.gpxFolderMissing {
                            Text("No GPX folder yet. Sending a route will create it.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else if storage.gpxFiles.isEmpty {
                            Text("No GPX files.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(storage.gpxFiles) { file in
                                HStack {
                                    Image(systemName: "doc.text").foregroundStyle(.secondary)
                                    Text(file.name)
                                    Spacer()
                                    Text(size(file.size)).font(.caption).foregroundStyle(.secondary)
                                    Button("Import") { importFromDevice(file) }
                                        .controlSize(.small)
                                }
                                .font(.callout)
                            }
                        }

                        HStack {
                            Button {
                                sendLibrary(to: storage.id)
                            } label: {
                                Label(sendLabel, systemImage: "arrow.up.circle")
                            }
                            .disabled(model.isWorking || library.routes.isEmpty
                                      && library.tracks.isEmpty && library.waypoints.isEmpty)

                            Button {
                                model.browseRoot(storage.id)
                            } label: {
                                Label("Browse", systemImage: "folder")
                            }
                            .disabled(model.isWorking)
                        }
                        .controlSize(.small)
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }

                if model.browseStorage != nil { browser }
            }
            .padding(14)
        }
    }

    /// The device's own folder tree.
    ///
    /// Here because a device that refuses a file is usually a device whose
    /// layout is not what we assumed, and looking settles that faster than
    /// reasoning about the specification does.
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
                Button("Close") { model.closeBrowser() }.buttonStyle(.link)
            }
            .font(.caption)

            if model.browseFiles.isEmpty {
                Text("Empty.").font(.caption).foregroundStyle(.secondary)
            } else if model.browseFiles.count > 8 {
                Text("\(model.browseFiles.count) items")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !model.browseFiles.isEmpty {
                ForEach(model.browseFiles) { file in
                    HStack(spacing: 8) {
                        Image(systemName: file.isFolder ? "folder.fill" : "doc")
                            .foregroundStyle(file.isFolder ? Color.accentColor : .secondary)
                        if file.isFolder {
                            Button(file.name) { model.descend(into: file) }
                                .buttonStyle(.plain)
                        } else {
                            Text(file.name)
                        }
                        Spacer()
                        if !file.isFolder {
                            Text(size(file.size)).font(.caption).foregroundStyle(.secondary)
                            // Anywhere on the device, not just the folder we
                            // went looking for. The archived track logs are
                            // the rider's own history and they live a level
                            // down, where the GPX listing above never reaches.
                            if file.name.lowercased().hasSuffix(".gpx") {
                                Button("Import") { importFromDevice(file) }
                                    .controlSize(.small)
                                    .disabled(model.isWorking)
                            }
                        }
                    }
                    .font(.callout)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
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

    private func size(_ bytes: UInt32) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
#endif
