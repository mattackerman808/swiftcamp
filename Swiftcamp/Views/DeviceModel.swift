#if os(macOS)
import Observation
import SwiftUI

/// What is on the device, and what to put on it.
///
/// Named for the model because the panel it was written for is gone: the
/// device lives in a window with two panes now, not a sheet.
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

    /// What each identified file turned out to hold, keyed by object handle.
    private(set) var summaries: [UInt32: DeviceService.Identification] = [:]

    /// How many files the background scan still has to look at, or nil when
    /// it is not running. Distinct from `isWorking`, which gates the buttons.
    private(set) var scanRemaining: Int?

    @ObservationIgnored private let service = DeviceService()
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    /// Units already tried, so a device that will not open is not retried on
    /// every pass. Cleared when it leaves the bus.
    @ObservationIgnored private var attempted: Set<UInt32> = []

    /// Watches the bus for as long as the window is open.
    ///
    /// A button labelled Scan Again was the wrong shape twice over: it did
    /// blocking work on the main thread with no sign it was doing anything,
    /// and it asked the user to do the noticing. Plugging a cable in is the
    /// signal; nobody should have to tell the app about it afterwards.
    func startWatching() {
        guard watchTask == nil else { return }
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.survey()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    /// One pass: what is on the bus, and what that means for what we have.
    private func survey() async {
        // Enumerating blocks, and it was being done twice — once for Garmins
        // and again for everything else — on the thread drawing the window.
        // That is what made the button feel broken before it felt slow.
        let all = await Task.detached { GarminUnit.attached() }.value
        guard !Task.isCancelled else { return }

        units = all.filter { $0.vendorID == GarminUnit.vendorID }
        // Everything else, so a unit reporting an unexpected vendor id shows
        // up as a device we can see rather than as nothing at all.
        otherDevices = all.filter { $0.vendorID != GarminUnit.vendorID }

        if let connected = snapshot?.unit,
           !units.contains(where: { $0.locationID == connected.locationID }) {
            forgetDevice()
            failure = "The device was disconnected."
            return
        }

        // One Garmin attached and nothing connected is not a choice worth
        // putting to anyone. Attempted once per unit: a device that refuses
        // to open should not be retried every two seconds forever.
        if snapshot == nil, !isWorking, units.count == 1, let only = units.first,
           !attempted.contains(only.locationID) {
            attempted.insert(only.locationID)
            connect(to: only)
        }

        attempted.formIntersection(Set(units.map(\.locationID)))
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
        forgetDevice()
        Task { await service.disconnect() }
    }

    /// Drops everything that described a device that is no longer there.
    ///
    /// Including the background scan: it holds a list of files on a unit that
    /// has gone, and every one of them will fail.
    private func forgetDevice() {
        yieldScan()
        snapshot = nil
        browseStorage = nil
        browsePath = []
        browseFiles = []
        summaries = [:]
        units = []
    }

    /// Writes one or more GPX files into the device's GPX folder.
    ///
    /// Serially, because the device takes one transaction at a time.
    func send(_ files: [(name: String, data: Data)], to storage: UInt32) {
        guard !files.isEmpty else { return }
        let label = files.count == 1 ? "Sending \(files[0].name)…"
                                     : "Sending \(files.count) files…"

        run(label) { [service] in
            for file in files {
                try await service.send(file.data, named: file.name, to: storage)
            }
            // The send may have created the folder, so the handle is only
            // knowable afterwards.
            let folder = try await service.gpxFolder(storage: storage)
            let listing = try await service.list(storage: storage,
                                                 parent: folder ?? MTP.rootParent)
            // Named `listing`, not `files`: the outer `files` is what was
            // sent, and shadowing it here would report the folder's contents
            // as though it were the result of the send.
            let sent = files.count == 1 ? "Sent \(files[0].name)."
                                        : "Sent \(files.count) files."
            return {
                self.browseStorage = storage
                self.browsePath = folder.map { [Crumb(name: "GPX", handle: $0)] } ?? []
                self.browseFiles = listing
                self.status = sent
            }
        }
    }

    /// Identifies one file from its two ends.
    func identify(_ file: DeviceFile) {
        run("Reading \(file.name)…") { [service] in
            let result = try await service.identify(file)
            return { self.summaries[file.handle] = result; self.status = nil }
        }
    }

    /// Pulls one whole file, for exact counts and distance.
    func identifyFully(_ file: DeviceFile) {
        run("Reading all of \(file.name)…") { [service] in
            let result = try await service.identifyFully(file)
            return { self.summaries[file.handle] = result; self.status = nil }
        }
    }

    /// Fills in what each file holds, in the background.
    ///
    /// Deliberately not routed through `run`. Identification is something the
    /// panel does for the user's benefit, not something the user asked for,
    /// so it must never be the reason a button is greyed out or an import has
    /// to wait. It publishes each result as it arrives rather than at the
    /// end, so a long folder fills in from the top while it is being read.
    ///
    /// Serially, because one USB pipe pair carries one transaction —
    /// concurrency here would not be faster and would interleave the replies.
    func identifyAll() {
        scanTask?.cancel()

        let pending = browseFiles.filter {
            !$0.isFolder && $0.name.lowercased().hasSuffix(".gpx") && summaries[$0.handle] == nil
        }
        guard !pending.isEmpty else {
            scanRemaining = nil
            return
        }

        scanRemaining = pending.count
        scanTask = Task { [service] in
            for file in pending {
                if Task.isCancelled { break }
                // One unreadable file must not stop the rest. A device folder
                // can hold a log the unit was part-way through writing.
                let result = try? await service.identify(file)
                if Task.isCancelled { break }

                if let result {
                    summaries[file.handle] = result
                } else if await service.connectedUnitIsGone() {
                    // Unplugged mid-scan. Without this the loop grinds
                    // through every remaining file against dead handles,
                    // failing each one, while the pane still shows them.
                    forgetDevice()
                    failure = "The device was disconnected."
                    return
                }
                scanRemaining = (scanRemaining ?? 1) - 1
            }
            scanRemaining = nil
        }
    }

    /// Stops the background scan so a user action goes next.
    ///
    /// The device answers one request at a time, so a scan half-way through
    /// twenty files would otherwise put an import behind all of them.
    private func yieldScan() {
        scanTask?.cancel()
        scanTask = nil
        scanRemaining = nil
    }

    /// Writes files to whichever storage is open.
    func export(_ files: [(name: String, data: Data)]) {
        guard let storage = browseStorage else { return }
        send(files, to: storage)
    }

    /// Reads device files into the library.
    ///
    /// Folders are skipped rather than refused: dragging a mixed selection
    /// should move what can be moved instead of failing over the one item
    /// that cannot.
    func importToLibrary(handles: [UInt32], into library: LibraryModel) {
        let files = browseFiles.filter { handles.contains($0.handle) && !$0.isFolder }
        guard !files.isEmpty else { return }

        run(files.count == 1 ? "Reading \(files[0].name)…" : "Reading \(files.count) files…") { [service] in
            var loaded: [(String, Data)] = []
            for file in files {
                if let data = try? await service.read(file) { loaded.append((file.name, data)) }
            }
            return {
                for (name, data) in loaded { library.importGPX(data: data, named: name) }
                self.status = loaded.count == 1 ? "Imported \(loaded[0].0)."
                                                : "Imported \(loaded.count) files."
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
    func run(_ label: String, _ work: @escaping () async throws -> () -> Void) {
        guard !isWorking else { return }
        // Whatever the user asked for goes ahead of the background scan.
        yieldScan()
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
                // A device that has been unplugged fails everything, and
                // going on to show its files and offer to write to them is
                // worse than saying it is gone. Checked only on failure:
                // asking before every operation is a bus enumeration per
                // file for an answer that is almost always yes.
                if await service.connectedUnitIsGone() {
                    forgetDevice()
                    failure = "The device was disconnected."
                } else {
                    failure = error.localizedDescription
                }
                status = nil
                isWorking = false
            }

            // Pick the scan back up, for this folder and whatever is left of
            // it. Identifying only ever touches files it has no answer for,
            // so resuming costs nothing when there is nothing to do.
            if snapshot?.canIdentifyCheaply == true { identifyAll() }
        }
    }
}
#endif
