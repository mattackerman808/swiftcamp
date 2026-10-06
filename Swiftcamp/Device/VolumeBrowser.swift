#if os(macOS)
import Foundation

/// What the transfer window needs from a device, whichever way the device
/// is reached: over MTP, where the unit serves objects by handle, or as a
/// mounted volume, where a memory card or an older unit is a folder tree.
///
/// Handles and storage ids are MTP's vocabulary, kept because the window
/// and the model already speak it; a volume browser hands out handles of
/// its own for the paths it has shown.
protocol DeviceBrowser {
    var modelName: String { get }
    var serialNumber: String { get }
    /// Whether a byte range can be read, which decides whether identifying
    /// a file costs kilobytes or the whole thing.
    var supportsPartialReads: Bool { get }

    func storages() throws -> [MTP.StorageInfo]
    func contents(of parent: UInt32, storage: UInt32) throws -> [DeviceFile]
    func gpxFolder(storage: UInt32, creating: Bool) throws -> UInt32
    func read(_ file: DeviceFile) throws -> Data
    func peek(_ file: DeviceFile) throws -> GPXPeek.Result?
    func write(_ data: Data, named name: String, storage: UInt32) throws
    func close()
}

/// A Garmin reached as a volume: a memory card in a reader, or a unit that
/// mounts as a disk, as a Navigator VI still does.
///
/// The card is how experienced riders already move routes. The unit reads
/// `Garmin/GPX` from it and walks subfolders, and it leaves the card alone
/// where it rewrites and prunes what it finds in internal memory. It also
/// needs no USB stack at all: this is ordinary file handling, which is why
/// `docs/basecamp-parity.md` called it the smallest useful device support.
///
/// Handles are made up here, one per path shown, since a path has no
/// number of its own. They are stable for the life of the browser, which
/// is the life of the connection, and that is all a handle promises.
final class VolumeBrowser: DeviceBrowser {
    let root: URL
    let modelName: String
    let serialNumber = ""
    let supportsPartialReads = true

    /// The only storage. A card is one volume.
    static let storageID: UInt32 = 1

    private var handles: [UInt32: URL] = [:]
    private var ids: [String: UInt32] = [:]
    private var nextHandle: UInt32 = 1

    init(root: URL, name: String) {
        self.root = root.standardizedFileURL
        self.modelName = name
    }

    func storages() throws -> [MTP.StorageInfo] {
        let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                        .volumeAvailableCapacityForImportantUsageKey])
        return [MTP.StorageInfo(id: Self.storageID,
                                capacity: UInt64(values?.volumeTotalCapacity ?? 0),
                                free: UInt64(values?.volumeAvailableCapacityForImportantUsage ?? 0),
                                description: modelName,
                                volumeLabel: modelName)]
    }

    func contents(of parent: UInt32, storage: UInt32) throws -> [DeviceFile] {
        let folder = try url(for: parent)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                               options: [.skipsHiddenFiles])
        return urls.map { url -> DeviceFile in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return DeviceFile(handle: handle(for: url),
                              storage: Self.storageID,
                              name: url.lastPathComponent,
                              size: UInt32(clamping: values?.fileSize ?? 0),
                              isFolder: values?.isDirectory ?? false,
                              modified: values?.contentModificationDate)
        }
        .sorted { ($0.isFolder ? 0 : 1, $0.name.lowercased()) < ($1.isFolder ? 0 : 1, $1.name.lowercased()) }
    }

    /// `Garmin/GPX`, found case-insensitively since the card is FAT, and
    /// made in that spelling when asked: on a volume the nested layout is
    /// the only one a unit reads.
    func gpxFolder(storage: UInt32, creating: Bool) throws -> UInt32 {
        var folder = root
        for component in ["Garmin", "GPX"] {
            if let match = try existing(named: component, in: folder) {
                folder = match
            } else if creating {
                folder = folder.appendingPathComponent(component, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            } else {
                throw MTP.Failure.notFound("Garmin/GPX")
            }
        }
        return handle(for: folder)
    }

    func read(_ file: DeviceFile) throws -> Data {
        try Data(contentsOf: url(for: file.handle))
    }

    /// The two ends, as the MTP browser reads them, so the same scan
    /// answers when a ride was for a file of any size.
    func peek(_ file: DeviceFile) throws -> GPXPeek.Result? {
        let handle = try FileHandle(forReadingFrom: url(for: file.handle))
        defer { try? handle.close() }
        let head = try handle.read(upToCount: Int(min(GPXPeek.headBytes, file.size))) ?? Data()
        guard file.size > GPXPeek.headBytes + GPXPeek.tailBytes else {
            return GPXPeek.scan(head: head, tail: head)
        }
        try handle.seek(toOffset: UInt64(file.size - GPXPeek.tailBytes))
        let tail = try handle.read(upToCount: Int(GPXPeek.tailBytes)) ?? Data()
        return GPXPeek.scan(head: head, tail: tail)
    }

    /// Into `Garmin/GPX`, replacing a file of the same name in any case,
    /// for the reason the MTP browser gives: a unit holds one copy of a
    /// route, and two spellings of one name on its screen is how someone
    /// follows last week's ride.
    func write(_ data: Data, named name: String, storage: UInt32) throws {
        let folder = try url(for: gpxFolder(storage: storage, creating: true))
        if let existing = try existing(named: name, in: folder) {
            try FileManager.default.removeItem(at: existing)
        }
        try data.write(to: folder.appendingPathComponent(name), options: .atomic)
    }

    func close() {}

    // MARK: - Handles and names

    private func handle(for url: URL) -> UInt32 {
        let key = url.standardizedFileURL.path
        if let known = ids[key] { return known }
        let handle = nextHandle
        nextHandle += 1
        ids[key] = handle
        handles[handle] = url.standardizedFileURL
        return handle
    }

    private func url(for handle: UInt32) throws -> URL {
        if handle == MTP.rootParent { return root }
        guard let url = handles[handle] else { throw MTP.Failure.notFound("handle \(handle)") }
        return url
    }

    /// The entry called `name` in a folder, in whatever case the card has
    /// it. Not a path test: APFS is case-sensitive when formatted so, and
    /// a fake card on the developer's disk should behave like a real one.
    private func existing(named name: String, in folder: URL) throws -> URL? {
        try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles])
            .first { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
    }
}

extension GarminUnit {
    /// Mounted volumes that look like a Garmin: anything with a `Garmin`
    /// folder at its root, which is what a unit writes to a card the first
    /// time it sees one. The boot volume is never one, whatever is on it.
    /// `-SwiftcampVolume <path>` adds a folder as a card, for checking the
    /// path without a reader to hand.
    static func volumes() -> [GarminUnit] {
        var roots = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                          options: [.skipHiddenVolumes]) ?? []
        roots.removeAll { $0.path == "/" }
        if let fake = UserDefaults.standard.string(forKey: "SwiftcampVolume") {
            roots.append(URL(fileURLWithPath: fake, isDirectory: true))
        }
        return volumes(among: roots)
    }

    /// The Garmins among some volume roots.
    static func volumes(among roots: [URL]) -> [GarminUnit] {
        roots.compactMap { root in
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path),
                  entries.contains(where: { $0.caseInsensitiveCompare("Garmin") == .orderedSame })
            else { return nil }
            // A folder standing in for a card is not a mount point, and
            // asking it for a volume name gets the disk it sits on.
            let values = try? root.resourceValues(forKeys: [.volumeNameKey, .isVolumeKey])
            let name = (values?.isVolume == true ? values?.volumeName : nil) ?? root.lastPathComponent
            return GarminUnit(locationID: locationID(forVolume: root),
                              vendorID: vendorID,
                              productID: 0,
                              name: "\(name) (memory card)",
                              volume: root.standardizedFileURL)
        }
    }

    /// Everything a transfer could go to: units on the bus and cards in
    /// readers.
    static func present() -> [GarminUnit] { attached() + volumes() }

    /// A volume's stand-in for a USB location id: the top bit, which no
    /// location id has, over a hash of the path, stable for the process.
    private static func locationID(forVolume root: URL) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in root.standardizedFileURL.path.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return 0x8000_0000 | (hash & 0x7fff_ffff)
    }
}
#endif
