#if os(macOS)
import Foundation

/// Owns the connection to a device.
///
/// An actor because `MTPSession` holds raw USB pipes and is single-threaded
/// by nature: one pipe pair carries one transaction, and the transaction id
/// is what pairs a reply with its command. Actor isolation is what keeps the
/// session from escaping onto two threads, which would not crash so much as
/// quietly return one command's answer to another.
actor DeviceService {
    private var browser: GarminBrowser?
    private var connected: GarminUnit?

    /// What the panel shows about a connected unit.
    struct Snapshot: Sendable {
        var unit: GarminUnit
        var model: String
        var serialNumber: String
        var storages: [StorageSummary]
    }

    struct StorageSummary: Identifiable, Sendable {
        var id: UInt32
        var name: String
        var freeBytes: UInt64
        var capacityBytes: UInt64
        /// Where the browser should open. Nil when the unit has no GPX
        /// folder yet, which is normal for a fresh memory card and not an
        /// error — the browser then opens at the root instead.
        var gpxFolder: UInt32?
    }

    // MARK: - Discovery

    /// Garmins on the bus.
    nonisolated func garmins() -> [GarminUnit] { GarminUnit.garmins() }

    /// Everything on the bus. Shown when no Garmin is recognised, so a unit
    /// that reports an unexpected vendor is visible rather than invisible.
    nonisolated func allDevices() -> [GarminUnit] { GarminUnit.attached() }

    // MARK: - Connection

    func connect(to unit: GarminUnit) throws -> Snapshot {
        disconnect()

        let browser = try GarminBrowser(unit: unit)
        self.browser = browser
        self.connected = unit

        // A failure to identify must not stop the connection. The model name
        // is decoration — the USB product string already names the unit — and
        // refusing to list a device's files because its self-description
        // parsed oddly would be the wrong trade every time.
        let info = (try? browser.identify()) ?? MTP.DeviceInfo()
        var storages: [StorageSummary] = []

        for storage in try browser.storages() {
            storages.append(StorageSummary(id: storage.id,
                                           name: storage.name,
                                           freeBytes: storage.free,
                                           capacityBytes: storage.capacity,
                                           gpxFolder: try? browser.gpxFolder(storage: storage.id)))
        }

        return Snapshot(unit: unit,
                        model: info.model.isEmpty ? unit.name : info.model,
                        serialNumber: info.serialNumber,
                        storages: storages)
    }

    func disconnect() {
        browser?.session.close()
        browser = nil
        connected = nil
    }

    // MARK: - Transfer

    func send(_ data: Data, named name: String, to storage: UInt32) throws {
        guard let browser else { throw MTP.Failure.noDevice }
        try browser.write(data, named: name, storage: storage)
    }

    func read(_ file: DeviceFile) throws -> Data {
        guard let browser else { throw MTP.Failure.noDevice }
        return try browser.read(file)
    }

    /// One folder's contents, for the browser.
    ///
    /// A device that will not take a file is usually a device whose layout is
    /// not what we assumed, and no amount of reasoning about the spec settles
    /// that as fast as looking.
    func list(storage: UInt32, parent: UInt32) throws -> [DeviceFile] {
        guard let browser else { throw MTP.Failure.noDevice }
        return try browser.contents(of: parent, storage: storage)
    }

    /// The GPX folder's handle, which a send may have just created.
    func gpxFolder(storage: UInt32) throws -> UInt32? {
        guard let browser else { throw MTP.Failure.noDevice }
        return try? browser.gpxFolder(storage: storage)
    }
}
#endif
