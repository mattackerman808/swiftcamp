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
        .frame(width: 560, height: 460)
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
                            Text("No Garmin/GPX folder yet. Sending a route will create it.")
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

                        Button {
                            sendLibrary(to: storage.id)
                        } label: {
                            Label(sendLabel, systemImage: "arrow.up.circle")
                        }
                        .controlSize(.small)
                        .disabled(model.isWorking || library.routes.isEmpty
                                  && library.tracks.isEmpty && library.waypoints.isEmpty)
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(14)
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

    private func size(_ bytes: UInt32) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
#endif
