#if os(macOS)
import Foundation

/// A Garmin on the USB bus.
struct GarminUnit: Identifiable, Hashable, Sendable {
    var locationID: UInt32
    var vendorID: UInt16
    var productID: UInt16
    var name: String

    var id: UInt32 { locationID }

    /// Garmin's USB vendor id.
    ///
    /// Matching on vendor and not on a product list, deliberately. Product
    /// ids are per model and a new unit is not in anyone's table — `libmtp`
    /// has entries for a hundred Garmins and a zūmo XT3 is not among them.
    /// Anything Garmin that speaks MTP should work without waiting for
    /// somebody to add a constant.
    static let vendorID: UInt16 = 0x091E

    /// Everything on the bus, Garmins first.
    static func attached() -> [GarminUnit] {
        var buffer = [sc_usb_device_info](repeating: sc_usb_device_info(), count: Int(SC_USB_MAX_DEVICES))
        let count = sc_usb_enumerate(&buffer, Int32(SC_USB_MAX_DEVICES))
        guard count > 0 else { return [] }

        return buffer.prefix(Int(count)).map { info in
            GarminUnit(locationID: info.location_id,
                       vendorID: info.vendor_id,
                       productID: info.product_id,
                       name: Self.name(from: info))
        }
    }

    static func garmins() -> [GarminUnit] {
        attached().filter { $0.vendorID == vendorID }
    }

    /// The C strings are fixed-size arrays, which Swift imports as tuples
    /// rather than anything readable, so each one has to be walked as bytes.
    private static func name(from info: sc_usb_device_info) -> String {
        var product = info.product_name
        var vendor = info.vendor_name
        let productName = withUnsafePointer(to: &product) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(SC_USB_NAME_MAX)) { String(cString: $0) }
        }
        let vendorName = withUnsafePointer(to: &vendor) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(SC_USB_NAME_MAX)) { String(cString: $0) }
        }

        if !productName.isEmpty && !vendorName.isEmpty { return "\(vendorName) \(productName)" }
        if !productName.isEmpty { return productName }
        if !vendorName.isEmpty { return vendorName }
        return String(format: "USB device %04X:%04X", info.vendor_id, info.product_id)
    }
}

/// A file or folder on the device.
struct DeviceFile: Identifiable, Hashable, Sendable {
    var handle: UInt32
    var storage: UInt32
    var name: String
    var size: UInt32
    var isFolder: Bool
    /// What the device says, which is often nothing. Plenty of units leave
    /// the field empty, so this is a bonus rather than something to rely on.
    var modified: Date?

    var id: UInt32 { handle }
}

/// Turns a route or track name into something a device will accept.
///
/// Garmin storage is FAT underneath, so the characters it forbids are FAT's.
/// A device that rejects a filename does not say which character it objected
/// to, and a rider who named a route "Sat 12/9 — Rockies" would get an error
/// about the file rather than about the name.
enum DeviceFilename {
    private static let forbidden = CharacterSet(charactersIn: #"/\:*?"<>|"#)
        .union(.controlCharacters)

    static func make(from name: String, fallback: String = "Route") -> String {
        // Each run of forbidden characters becomes one dash, rather than one
        // dash apiece: a name that is nothing but slashes would otherwise
        // come out as "---.gpx", which is a filename in the same sense that
        // a dial tone is a conversation.
        let dashed = name.components(separatedBy: forbidden)
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        // FAT also refuses a trailing dot, and the extension is about to add
        // one of its own.
        let trimmed = dashed.trimmingCharacters(
            in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".-")))

        let base = trimmed.isEmpty ? fallback : String(trimmed.prefix(58))
        return base + ".gpx"
    }
}

/// PTP timestamps, which are their own format and not ISO 8601.
///
/// `YYYYMMDDThhmmss`, optionally with fractional seconds and a `Z`. Close
/// enough to ISO to be mistaken for it, and different enough that an ISO
/// parser returns nil for every one of them.
enum PTPDate {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// A date the way MTP wants it, `20260912T141200`.
    ///
    /// Not optional in practice. A responder is entitled to reject an
    /// `ObjectInfo` whose dates are empty, and a zūmo answers one with a
    /// general error after several seconds of apparently trying.
    static func format(_ date: Date) -> String {
        formatter.string(from: date)
    }

    static func parse(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        // Trim a trailing Z and any fractional seconds before the format
        // string, which describes neither.
        var trimmed = text.hasSuffix("Z") ? String(text.dropLast()) : text
        if let dot = trimmed.firstIndex(of: ".") { trimmed = String(trimmed[..<dot]) }
        return formatter.date(from: trimmed)
    }
}

/// Reading and writing the GPX a Garmin navigates from.
///
/// The interesting part is that this is all MTP does: the device serves
/// objects, so there is no volume and nothing to mount. What it buys is that
/// Swiftcamp can put a route on the unit without the user installing OpenMTP
/// or MacDroid first, which on a Mac is the whole of the annoyance.
///
/// A real Finder volume would be a filesystem extension over this, which is a
/// separate and much larger piece of work.
struct GarminBrowser {
    /// Where Garmin units keep user routes and tracks — and it is not one
    /// path.
    ///
    /// Over MTP a zūmo XT3 exposes `GPX` at the root of its internal storage,
    /// alongside `Voice`, `Text`, `Vehicle` and `Logs`. In other words the
    /// MTP root *is* what would be the `Garmin` folder on a unit that mounts
    /// as a disk, and the familiar `Garmin/GPX` path is a mass-storage
    /// spelling of the same place.
    ///
    /// So both are searched, and which one gets created is decided by what
    /// the device already looks like rather than by a guess.
    static let gpxCandidates = [["GPX"], ["Garmin", "GPX"]]

    let session: MTPSession

    /// Read once, at connection. Asking the device what it can do before
    /// every file read is a round trip per file to learn something that
    /// cannot change while it is plugged in.
    private let info: MTP.DeviceInfo

    init(unit: GarminUnit) throws {
        session = try MTPSession(locationID: unit.locationID)
        try session.open()
        info = (try? session.deviceInfo()) ?? MTP.DeviceInfo()
    }

    func identify() throws -> MTP.DeviceInfo { info }

    func storages() throws -> [MTP.StorageInfo] {
        try session.storageIDs().compactMap { try? session.storageInfo($0) }
    }

    /// Everything directly inside a folder, or the root of a storage.
    ///
    /// The root is the awkward case. The spec says handle `0xFFFFFFFF` means
    /// "objects with no parent", and `0` means "every object on the storage,
    /// at any depth" — but implementations disagree, and a device that
    /// returns nothing for the first is indistinguishable from an empty
    /// storage. A zūmo with 26 GB of maps on it is not empty, so when the
    /// root comes back bare we ask for everything and keep what has no
    /// parent. Slower, and only ever needed once per connection.
    func contents(of parent: UInt32 = MTP.rootParent, storage: UInt32) throws -> [DeviceFile] {
        let handles = try session.objectHandles(storage: storage, parent: parent)

        if handles.isEmpty && parent == MTP.rootParent {
            return try rootByScan(storage: storage)
        }
        return handles.compactMap { describe($0) }
    }

    private func rootByScan(storage: UInt32) throws -> [DeviceFile] {
        try session.objectHandles(storage: storage, parent: 0)
            .compactMap { handle -> DeviceFile? in
                guard let info = try? session.objectInfo(handle) else { return nil }
                guard info.parent == 0 || info.parent == MTP.rootParent else { return nil }
                return DeviceFile(handle: handle, storage: info.storageID, name: info.filename,
                                  size: info.size, isFolder: info.isFolder)
            }
    }

    private func describe(_ handle: UInt32) -> DeviceFile? {
        guard let info = try? session.objectInfo(handle) else { return nil }
        return DeviceFile(handle: handle, storage: info.storageID, name: info.filename,
                          size: info.size, isFolder: info.isFolder,
                          modified: PTPDate.parse(info.modified))
    }

    /// Walks a path of folder names from the root of a storage.
    ///
    /// Case-insensitive on the way down. The device is strict about the
    /// folder it reads from, but a unit that already has `garmin/gpx` from
    /// some other tool should still be found rather than quietly gaining a
    /// second folder beside it.
    func resolve(_ path: [String], storage: UInt32, creating: Bool = false) throws -> UInt32 {
        var parent = MTP.rootParent

        for component in path {
            let children = try contents(of: parent, storage: storage)
            if let match = children.first(where: {
                $0.isFolder && $0.name.caseInsensitiveCompare(component) == .orderedSame
            }) {
                parent = match.handle
            } else if creating {
                parent = try session.makeFolder(named: component, storage: storage, parent: parent)
            } else {
                throw MTP.Failure.notFound(path.joined(separator: "/"))
            }
        }
        return parent
    }

    /// The handle of the folder this device keeps GPX in, creating it only
    /// when asked.
    ///
    /// When neither layout exists, the one to create follows the device: a
    /// root with a `Garmin` folder in it is a unit using the nested spelling,
    /// and anything else gets `GPX` at the root, which is what the units that
    /// speak MTP actually do.
    func gpxFolder(storage: UInt32, creating: Bool = false) throws -> UInt32 {
        for candidate in Self.gpxCandidates {
            if let handle = try? resolve(candidate, storage: storage) { return handle }
        }
        guard creating else { throw MTP.Failure.notFound("A GPX folder") }

        let root = try contents(of: MTP.rootParent, storage: storage)
        let nested = root.contains {
            $0.isFolder && $0.name.caseInsensitiveCompare("Garmin") == .orderedSame
        }
        return try resolve(nested ? ["Garmin", "GPX"] : ["GPX"], storage: storage, creating: true)
    }

    /// The GPX files already on the unit.
    func gpxFiles(storage: UInt32) throws -> [DeviceFile] {
        let folder = try gpxFolder(storage: storage)
        return try contents(of: folder, storage: storage)
            .filter { !$0.isFolder && $0.name.lowercased().hasSuffix(".gpx") }
    }

    func read(_ file: DeviceFile) throws -> Data {
        try session.object(file.handle)
    }

    /// Whether the device will read a byte range, which decides whether
    /// identifying a file costs kilobytes or megabytes.
    var supportsPartialReads: Bool { info.supports(.getPartialObject) }

    /// Reads the two ends of a file and reports what they say.
    ///
    /// Returns nil when the device cannot do partial reads at all, so the
    /// caller can decide whether the whole file is worth pulling.
    ///
    /// The tail is best-effort, and that is not tidiness. A zūmo XT3 answers
    /// a read at offset zero and refuses one at an offset 22 MB in, so
    /// treating the second read as required threw away a perfectly good first
    /// one and fell back to pulling the entire file — the exact cost this
    /// exists to avoid. Losing the tail costs the end date and nothing else,
    /// and the device's own modification time usually covers that.
    func peek(_ file: DeviceFile) throws -> GPXPeek.Result? {
        guard supportsPartialReads else { return nil }

        let head = try session.partialObject(file.handle, offset: 0,
                                             length: min(GPXPeek.headBytes, file.size))

        // A file smaller than the two windows is entirely covered by the
        // first read, and asking for a range past its end is how a device
        // gets asked for something that does not exist.
        guard file.size > GPXPeek.headBytes + GPXPeek.tailBytes else {
            return GPXPeek.scan(head: head, tail: head)
        }

        let tail = (try? session.partialObject(file.handle,
                                               offset: file.size - GPXPeek.tailBytes,
                                               length: GPXPeek.tailBytes)) ?? Data()
        return GPXPeek.scan(head: head, tail: tail)
    }

    /// Writes a GPX file into `Garmin/GPX`, replacing one of the same name.
    ///
    /// Replacing rather than adding, unlike library import. A device holds
    /// one copy of a route and the user means to update it; leaving
    /// `Route.gpx` and `Route (1).gpx` side by side on a unit whose screen
    /// shows a list of names is how someone follows last week's ride.
    func write(_ data: Data, named name: String, storage: UInt32) throws {
        let folder = try gpxFolder(storage: storage, creating: true)

        if let existing = try contents(of: folder, storage: storage)
            .first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            try session.deleteObject(existing.handle)
        }

        try session.sendObject(data, named: name, storage: storage, parent: folder)
    }
}
#endif
