#if os(macOS)
import Foundation
import os

/// One conversation with an MTP device.
///
/// Not thread-safe and not meant to be: a single USB pipe pair carries one
/// transaction at a time, and the transaction id in every container is what
/// pairs a reply with its command. Keep one session on one queue.
final class MTPSession {
    private let log = Logger(subsystem: "app.swiftcamp", category: "mtp")
    private var handle: OpaquePointer?
    private var transaction: UInt32 = 0
    private var isOpen = false

    /// How long a single bulk transfer may take.
    ///
    /// Generous, and then some. Garmin's MTP stack is Android-derived, and
    /// `libmtp` marks every Garmin with its long-timeout flag for exactly
    /// this reason: the first write to a storage can stall while the device
    /// updates its own object database.
    private let timeout: Int32 = 60_000

    // MARK: - Lifecycle

    init(locationID: UInt32) throws {
        var error = SC_USB_OK
        guard let opened = sc_usb_open(locationID, &error) else {
            throw MTP.Failure.openFailed(error.rawValue)
        }
        handle = opened
    }

    deinit { close() }

    /// Opens session 1. Every operation except `GetDeviceInfo` needs one.
    ///
    /// Three attempts, because the interesting failure is a device left
    /// mid-transaction by a run that crashed or timed out. It answers the
    /// next `OpenSession` with a general error and stays that way until
    /// something clears it, which previously meant unplugging the cable.
    func open() throws {
        guard !isOpen else { return }

        // A session the last run left behind. Closing one that is not open is
        // harmless and the device says so, which is why the result is ignored.
        _ = try? command(.closeSession, [])

        do {
            try openSession()
        } catch MTP.Failure.deviceRefused(let code)
            where code == MTP.Response.generalError.rawValue
               || code == MTP.Response.deviceBusy.rawValue {
            log.info("device is wedged; resetting and retrying")
            if let handle { _ = sc_usb_reset(handle) }
            // The device drops off the bus briefly while it resets.
            Thread.sleep(forTimeInterval: 1.0)
            transaction = 0
            try openSession()
        }
        isOpen = true
    }

    private func openSession() throws {
        do {
            _ = try command(.openSession, [1])
        } catch MTP.Failure.deviceRefused(let code)
            where code == MTP.Response.sessionAlreadyOpen.rawValue {
            // Already ours to use.
            log.info("session was already open")
        }
    }

    func close() {
        if isOpen {
            _ = try? command(.closeSession, [])
            isOpen = false
        }
        if let handle {
            sc_usb_close(handle)
            self.handle = nil
        }
    }

    // MARK: - Operations

    func deviceInfo() throws -> MTP.DeviceInfo {
        var reader = MTP.Reader(try command(.getDeviceInfo, []).data)
        var info = MTP.DeviceInfo()

        try reader.skip(2 + 4 + 2)                   // standard version, vendor extension, version
        _ = try reader.string()                      // vendor extension description
        try reader.skip(2)                           // functional mode

        // These five are arrays of UInt16, not UInt32. Operation, event,
        // property and format codes are all 16-bit, and reading them at 32
        // bits walks twice as far as it should — which does not fail here.
        // It fails four fields later, as a request to allocate an array of
        // 150,994,944 elements, with nothing pointing back to the cause.
        _ = try reader.uint16Array()                 // operations supported
        _ = try reader.uint16Array()                 // events supported
        _ = try reader.uint16Array()                 // device properties
        _ = try reader.uint16Array()                 // capture formats
        _ = try reader.uint16Array()                 // playback formats

        info.manufacturer = try reader.string()
        info.model = try reader.string()
        info.deviceVersion = try reader.string()
        info.serialNumber = try reader.string()
        return info
    }

    func storageIDs() throws -> [UInt32] {
        var reader = MTP.Reader(try command(.getStorageIDs, []).data)
        return try reader.uint32Array()
    }

    func storageInfo(_ id: UInt32) throws -> MTP.StorageInfo {
        var reader = MTP.Reader(try command(.getStorageInfo, [id]).data)
        try reader.skip(2 + 2 + 2)                   // storage, filesystem and access types
        let capacity = try reader.uint64()
        let free = try reader.uint64()
        try reader.skip(4)                           // free objects
        let description = try reader.string()
        let label = try reader.string()
        return MTP.StorageInfo(id: id, capacity: capacity, free: free,
                               description: description, volumeLabel: label)
    }

    /// Handles of everything directly inside `parent`.
    ///
    /// The second parameter is a format filter and must be zero for "any" —
    /// passing a format code here is how you get an empty listing from a
    /// folder that plainly has files in it.
    func objectHandles(storage: UInt32, parent: UInt32) throws -> [UInt32] {
        var reader = MTP.Reader(try command(.getObjectHandles, [storage, 0, parent]).data)
        return try reader.uint32Array()
    }

    func objectInfo(_ handle: UInt32) throws -> MTP.ObjectInfo {
        var reader = MTP.Reader(try command(.getObjectInfo, [handle]).data)
        return try MTP.ObjectInfo(&reader)
    }

    func object(_ handle: UInt32) throws -> Data {
        try command(.getObject, [handle]).data
    }

    func deleteObject(_ handle: UInt32) throws {
        _ = try command(.deleteObject, [handle, 0])
    }

    /// Writes a file and returns its new handle.
    ///
    /// Two operations, in order, and the order is not optional. `SendObjectInfo`
    /// tells the device what is coming and returns the handle it reserved;
    /// `SendObject` then delivers the bytes with no parameters at all, because
    /// the device is still holding the info from the call before. Sending them
    /// the other way round, or putting a handle on the second call, fails in
    /// ways that do not name the cause.
    @discardableResult
    func sendObject(_ payload: Data, named name: String,
                    storage: UInt32, parent: UInt32) throws -> UInt32 {
        let info = MTP.ObjectInfo(storageID: storage, parent: parent,
                                  filename: name, size: UInt32(payload.count),
                                  isFolder: false)

        let reply = try command(.sendObjectInfo, [storage, parent], sending: info.encoded())
        guard reply.parameters.count >= 3 else {
            throw MTP.Failure.malformedResponse("SendObjectInfo returned no handle")
        }
        let handle = reply.parameters[2]

        _ = try command(.sendObject, [], sending: payload)
        return handle
    }

    /// Creates a folder and returns its handle.
    func makeFolder(named name: String, storage: UInt32, parent: UInt32) throws -> UInt32 {
        let info = MTP.ObjectInfo(storageID: storage, parent: parent,
                                  filename: name, size: 0, isFolder: true)
        let reply = try command(.sendObjectInfo, [storage, parent], sending: info.encoded())
        guard reply.parameters.count >= 3 else {
            throw MTP.Failure.malformedResponse("SendObjectInfo returned no handle")
        }
        // A folder has no data phase. Sending one here leaves the device
        // waiting for bytes that never come.
        return reply.parameters[2]
    }

    // MARK: - The exchange

    private struct Reply {
        var data = Data()
        var parameters: [UInt32] = []
    }

    /// Puts the pipes back in a usable state after a failed exchange.
    ///
    /// A timeout leaves the device believing it is still mid-transaction, so
    /// the *next* command reads the tail of the last one and fails in a way
    /// that has nothing to do with what it asked. Clearing both halts costs
    /// nothing and stops one failure becoming a run of them.
    private func recover() {
        guard let handle else { return }
        _ = sc_usb_clear_halt_in(handle)
        _ = sc_usb_clear_halt_out(handle)
    }

    /// Sends one operation and runs the phases it implies.
    ///
    /// Command, then an optional data phase in one direction or the other,
    /// then a response. Which phases happen is a property of the operation,
    /// not something the wire format announces, so the caller says whether it
    /// is sending data and the reader copes with data coming back or not.
    @discardableResult
    private func command(_ operation: MTP.Operation,
                         _ parameters: [UInt32],
                         sending payload: Data? = nil) throws -> Reply {
        transaction &+= 1
        let id = transaction

        do {
            return try exchange(operation, id, parameters, sending: payload)
        } catch {
            recover()
            throw error
        }
    }

    private func exchange(_ operation: MTP.Operation,
                          _ id: UInt32,
                          _ parameters: [UInt32],
                          sending payload: Data?) throws -> Reply {
        try write(container: .init(kind: .command, code: operation.rawValue,
                                   transaction: id, payload: packed(parameters)))

        if let payload {
            try write(container: .init(kind: .data, code: operation.rawValue,
                                       transaction: id, payload: payload))
        }

        var reply = Reply()
        var container = try readContainer()

        if container.kind == .data {
            reply.data = container.payload
            container = try readContainer()
        }

        // An event can arrive on the bulk pipe between the data and the
        // response on some devices. Stepping over it is cheaper than opening
        // the interrupt endpoint we otherwise have no use for.
        while container.kind == .event {
            container = try readContainer()
        }

        guard container.kind == .response else {
            throw MTP.Failure.malformedResponse("expected a response, got \(container.kind)")
        }
        guard container.code == MTP.Response.ok.rawValue else {
            throw MTP.Failure.deviceRefused(container.code)
        }

        var reader = MTP.Reader(container.payload)
        while !reader.isAtEnd, let value = try? reader.uint32() {
            reply.parameters.append(value)
        }
        return reply
    }

    private func packed(_ parameters: [UInt32]) -> Data {
        var writer = MTP.Writer()
        for parameter in parameters { writer.uint32(parameter) }
        return writer.data
    }

    // MARK: - Framing

    private func write(container: MTP.Container) throws {
        guard let handle else { throw MTP.Failure.noDevice }

        var writer = MTP.Writer()
        writer.uint32(UInt32(MTP.Container.headerSize + container.payload.count))
        writer.uint16(container.kind.rawValue)
        writer.uint16(container.code)
        writer.uint32(container.transaction)

        var bytes = writer.data
        bytes.append(container.payload)

        try writeAll(bytes, handle: handle)

        // A transfer whose length is an exact multiple of the endpoint's
        // packet size has to be terminated by a zero-length packet, or the
        // device keeps waiting for the rest and the next read times out with
        // nothing to explain it.
        let packet = Int(sc_usb_max_packet_out(handle))
        if packet > 0 && bytes.count % packet == 0 {
            _ = sc_usb_bulk_write(handle, nil, 0, timeout)
        }
    }

    private func writeAll(_ bytes: Data, handle: OpaquePointer) throws {
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var sent = 0
            while sent < bytes.count {
                let chunk = min(bytes.count - sent, 256 * 1024)
                let written = sc_usb_bulk_write(handle,
                                                base + sent, Int32(chunk), timeout)
                guard written > 0 else {
                    throw MTP.Failure.transferFailed("write returned \(written)")
                }
                sent += Int(written)
            }
        }
    }

    /// Reads one container, following it with more reads until the length in
    /// its header is satisfied.
    ///
    /// The device answers in packets of its endpoint size, so a large object
    /// arrives as many reads and the header only appears in the first.
    private func readContainer() throws -> MTP.Container {
        guard let handle else { throw MTP.Failure.noDevice }

        let bufferSize = 512 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        let first = sc_usb_bulk_read(handle, &buffer, Int32(bufferSize), timeout)
        guard first >= MTP.Container.headerSize else {
            throw MTP.Failure.transferFailed("read returned \(first)")
        }

        var received = Data(buffer[0..<Int(first)])
        var header = MTP.Reader(received)
        let total = Int(try header.uint32())
        let rawKind = try header.uint16()
        let code = try header.uint16()
        let transaction = try header.uint32()

        guard let kind = MTP.Container.Kind(rawValue: rawKind) else {
            throw MTP.Failure.malformedResponse("container type \(rawKind)")
        }

        while received.count < total {
            let more = sc_usb_bulk_read(handle, &buffer,
                                        Int32(min(bufferSize, total - received.count)), timeout)
            guard more > 0 else {
                throw MTP.Failure.transferFailed("read stopped \(total - received.count) bytes short")
            }
            received.append(contentsOf: buffer[0..<Int(more)])
        }

        return MTP.Container(kind: kind, code: code, transaction: transaction,
                             payload: received.dropFirst(MTP.Container.headerSize))
    }
}
#endif
