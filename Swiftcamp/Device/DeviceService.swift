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
        /// Whether the device will read a byte range. It decides whether
        /// identifying a folder is something we can just do, or something
        /// worth asking about first.
        var canIdentifyCheaply: Bool
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
                        storages: storages,
                        canIdentifyCheaply: browser.supportsPartialReads)
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

    /// What identifying a file cost, so the panel can say which answer it has.
    enum Depth: Sendable {
        /// Read from the two ends of the file. Dates only, and cheap.
        case ends
        /// The whole file. Exact counts and distance.
        case whole
    }

    struct Identification: Sendable {
        var summary: GPXSummary
        var depth: Depth
    }

    /// Reports what is in a GPX without importing it.
    ///
    /// Reads the two ends when the device supports a byte range, which
    /// answers the question a rider actually has — when was this ride — for
    /// about eight kilobytes instead of twenty-two megabytes. Counts and
    /// distance are not knowable that way, so they stay zero and the panel
    /// says so rather than guessing.
    func identify(_ file: DeviceFile) throws -> Identification {
        guard let browser else { throw MTP.Failure.noDevice }

        if let peek = try? browser.peek(file), !peek.isEmpty {
            var summary = GPXSummary()
            summary.start = peek.start
            summary.end = peek.end
            // Seen, not counted. A fragment can show that a track is present
            // and can never show how many there are.
            summary.tracks = peek.sawTrack ? 1 : 0
            summary.routes = peek.sawRoute ? 1 : 0
            summary.waypoints = peek.sawWaypoint ? 1 : 0
            return Identification(summary: summary, depth: .ends)
        }

        return Identification(summary: try GPXReader.read(data: browser.read(file)).summary,
                              depth: .whole)
    }

    /// Pulls the whole file, for exact counts and distance.
    func identifyFully(_ file: DeviceFile) throws -> Identification {
        guard let browser else { throw MTP.Failure.noDevice }
        return Identification(summary: try GPXReader.read(data: browser.read(file)).summary,
                              depth: .whole)
    }

    /// The GPX folder's handle, which a send may have just created.
    func gpxFolder(storage: UInt32) throws -> UInt32? {
        guard let browser else { throw MTP.Failure.noDevice }
        return try? browser.gpxFolder(storage: storage)
    }
}
#endif
