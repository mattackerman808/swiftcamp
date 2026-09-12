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

    var id: UInt32 { handle }
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
    /// Where Garmin units look for user routes and tracks. Case matters on
    /// the device even though it does not on a Mac.
    static let gpxPath = ["Garmin", "GPX"]

    let session: MTPSession

    init(unit: GarminUnit) throws {
        session = try MTPSession(locationID: unit.locationID)
        try session.open()
    }

    func identify() throws -> MTP.DeviceInfo { try session.deviceInfo() }

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
                          size: info.size, isFolder: info.isFolder)
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

    /// The GPX files already on the unit.
    func gpxFiles(storage: UInt32) throws -> [DeviceFile] {
        let folder = try resolve(Self.gpxPath, storage: storage)
        return try contents(of: folder, storage: storage)
            .filter { !$0.isFolder && $0.name.lowercased().hasSuffix(".gpx") }
    }

    func read(_ file: DeviceFile) throws -> Data {
        try session.object(file.handle)
    }

    /// Writes a GPX file into `Garmin/GPX`, replacing one of the same name.
    ///
    /// Replacing rather than adding, unlike library import. A device holds
    /// one copy of a route and the user means to update it; leaving
    /// `Route.gpx` and `Route (1).gpx` side by side on a unit whose screen
    /// shows a list of names is how someone follows last week's ride.
    func write(_ data: Data, named name: String, storage: UInt32) throws {
        let folder = try resolve(Self.gpxPath, storage: storage, creating: true)

        if let existing = try contents(of: folder, storage: storage)
            .first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            try session.deleteObject(existing.handle)
        }

        try session.sendObject(data, named: name, storage: storage, parent: folder)
    }
}
#endif
