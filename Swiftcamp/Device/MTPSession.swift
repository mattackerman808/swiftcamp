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

    /// Wire tracing, off the terminal and into the unified log.
    ///
    /// Every container in and out is worth recording — the transaction number
    /// on a reply is what pairs it with the question that asked for it, and a
    /// day went into learning that. It does not belong on stderr.
    private func trace(_ message: String) {
        log.debug("\(message, privacy: .public)")
    }
    private var handle: OpaquePointer?
    private var transaction: UInt32 = 0
    private var isOpen = false

    /// How long a single bulk transfer may take.
    ///
    /// Generous, and then some. Garmin's MTP stack is Android-derived, and
    /// `libmtp` marks every Garmin with its long-timeout flag for exactly
    /// this reason: the first write to a storage can stall while the device
    /// updates its own object database.
    /// How long to wait for a reply.
    ///
    /// Long enough for a slow device, short enough to fail while someone is
    /// still watching. Two minutes was tried and bought nothing: a
    /// `SendObjectInfo` this device will not answer is not answered in two
    /// minutes either, so the extra wait only made the window look frozen.
    /// Whatever is wrong, it is not impatience.
    /// Fifteen seconds, and the number is measured rather than picked. This
    /// device answers a `SendObjectInfo` it dislikes after about seven, and a
    /// shorter wait left that answer in the pipe to be read as the reply to
    /// whatever was asked next.
    private let timeout: Int32 = 15_000

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

        try resynchronise()

        // A session the last run left behind. Closing one that is not open is
        // harmless and the device says so, which is why the result is ignored.
        _ = try? command(.closeSession, [])

        do {
            try openSession()
        } catch MTP.Failure.deviceRefused(let code)
            where code == MTP.Response.deviceBusy.rawValue {
            // Busy means "come back later", and it is not ours to override.
            // A zūmo says this while it is downloading maps over Wi-Fi, and
            // resetting it there aborts the download — the unit puts up
            // "Outdoor Maps+ download failed" and the user loses the
            // transfer, because a route planner was impatient.
            log.info("device is busy; waiting rather than resetting")
            for _ in 0..<3 {
                Thread.sleep(forTimeInterval: 1.5)
                if (try? openSession()) != nil {
                    isOpen = true
                    return
                }
            }
            throw MTP.Failure.deviceRefused(MTP.Response.deviceBusy.rawValue)
        } catch MTP.Failure.deviceRefused(let code)
            where code == MTP.Response.generalError.rawValue {
            // Never reset. This used to call ResetDevice, which is a USB port
            // reset: the unit sees it as being unplugged and plugged back in,
            // and comes back busy re-initialising. It was reached on almost
            // every launch, because a reply left queued by the previous run
            // was read here as a general error — so the app reset the device,
            // the device came back busy, the next write went unanswered
            // because it was busy, that request was abandoned leaving another
            // reply queued, and the next launch reset it again. It is also
            // what kept failing the unit's own map downloads.
            //
            // Nothing here is stuck. Draining the pipes and matching replies
            // to the questions that asked for them is what that reset was
            // standing in for, and both now happen before a word is said.
            log.info("general error at connect; re-opening rather than resetting")
            transaction = 0
            try openSession()
        }
        isOpen = true
    }

    /// Opens session 1, with transaction id 0.
    ///
    /// The spec reserves transaction 0 for `OpenSession`, and everything
    /// after it counts from 1. We were numbering it like any other command,
    /// so the session began at 2 or 3 depending on what had been tried
    /// first. Reads never minded. A responder that checks the sequence more
    /// carefully for operations that change something is a good candidate for
    /// why every write came back refused.
    private func openSession() throws {
        do {
            transaction = 0
            _ = try command(.openSession, [1], startingTransaction: 0)
            transaction = 0
        } catch MTP.Failure.deviceRefused(let code)
            where code == MTP.Response.sessionAlreadyOpen.rawValue {
            // Already ours to use.
            log.info("session was already open")
            transaction = 0
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
        info.operations = Set(try reader.uint16Array())
        _ = try reader.uint16Array()                 // events supported
        _ = try reader.uint16Array()                 // device properties
        _ = try reader.uint16Array()                 // capture formats
        _ = try reader.uint16Array()                 // playback formats

        trace(String(format: "[usb] supports: %@",
              info.operations.sorted().map { String(format: "%04X", $0) }.joined(separator: " ")))

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
        try reader.skip(2 + 2)                       // storage and filesystem types
        // 0 is read-write; anything else means the device will refuse a write,
        // and it is better to know that before sending a file than after.
        let access = try reader.uint16()
        trace(String(format: "[usb] storage %u access capability %u", id, access))
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

    /// Reads a byte range rather than the whole object.
    ///
    /// The difference between answering "what is in this file" in eight
    /// kilobytes and in twenty-two megabytes. Optional in MTP, so callers
    /// check `DeviceInfo.supports` first and fall back to reading it all.
    func partialObject(_ handle: UInt32, offset: UInt32, length: UInt32) throws -> Data {
        try command(.getPartialObject, [handle, offset, length]).data
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
                    storage: UInt32, parent: UInt32,
                    format: UInt16 = MTP.Format.undefined.rawValue) throws -> UInt32 {
        var info = MTP.ObjectInfo(storageID: storage, parent: parent,
                                  filename: name, size: UInt32(payload.count),
                                  isFolder: false)
        info.format = format
        // Both dates, filled in. Empty ones are what a zūmo spends several
        // seconds on before answering with a general error.
        let now = PTPDate.format(Date())
        info.created = now
        info.modified = now

        let encoded = info.encoded()
        trace(String(format: "[send] %@: %d bytes, info %d bytes, storage %u parent %u",
              name, payload.count, encoded.count, storage, parent))

        let reply: Reply
        do {
            reply = try command(.sendObjectInfo, [storage, parent], sending: encoded)
            trace(String(format: "[send] SendObjectInfo ok, params %@",
                  String(describing: reply.parameters)))
        } catch {
            trace(String(format: "[send] SendObjectInfo FAILED: %@", String(describing: error)))
            throw error
        }

        guard reply.parameters.count >= 3 else {
            throw MTP.Failure.malformedResponse("SendObjectInfo returned no handle")
        }
        let handle = reply.parameters[2]

        do {
            _ = try command(.sendObject, [], sending: payload)
            trace(String(format: "[send] SendObject ok, handle %u", handle))
        } catch {
            // A handle reserved by SendObjectInfo and never filled is worse
            // than a failed transfer: the device keeps it, refuses to describe
            // or delete it, and turns down every creation after it until the
            // unit is power cycled. If the object cannot be sent, the
            // reservation goes with it.
            trace(String(format: "[send] SendObject FAILED: %@", String(describing: error)))
            _ = try? deleteObject(handle)
            throw error
        }
        return handle
    }



    /// Asks the device to reset its own protocol state.
    func resetProtocol() throws {
        _ = try command(.resetDevice, [])
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
    /// What the device says about itself, over the control pipe.
    private func reportDeviceStatus(after operation: MTP.Operation) {
        guard let handle else { return }
        var status = [UInt8](repeating: 0, count: 64)
        let read = Int(sc_usb_mtp_device_status(handle, &status, Int32(status.count)))
        guard read >= 4 else {
            trace(String(format: "[usb] ? device status unavailable (%d) after 0x%04X",
                  read, operation.rawValue))
            return
        }
        let code = UInt16(status[2]) | UInt16(status[3]) << 8
        let meaning = MTP.Response(rawValue: code)?.explanation ?? "unknown"
        trace(String(format: "[usb] ? device status after 0x%04X: 0x%04X (%@), %d bytes",
              operation.rawValue, code, meaning, read))
    }


    private func recover() {
        guard let handle else { return }
        _ = sc_usb_clear_halt_in(handle)
        _ = sc_usb_clear_halt_out(handle)
        drain()
    }

    /// Puts the pipes back to a known state before the first word is said.
    ///
    /// A fresh process inherits whatever the last one left behind, and on this
    /// device that is worse than it sounds: it does not hand a queued reply to
    /// a waiting read. It releases it only when new bytes arrive on the
    /// outbound pipe, and it swallows the command that triggered the release
    /// without acting on it. One unread reply therefore leaves the two ends
    /// permanently one question apart — every answer belongs to the question
    /// before, and the one just asked is gone.
    ///
    /// Clearing the halt on both ends is what flushes the device's side, which
    /// a read alone cannot do.
    private func resynchronise() throws {
        guard let handle else { return }
        _ = sc_usb_clear_halt_in(handle)
        _ = sc_usb_clear_halt_out(handle)
        drain()

        // Ask before speaking, and believe the answer.
        //
        // A unit part-way through writing its own flash — a map download, an
        // update — answers reads from cache and simply never answers a write.
        // That presents as a transfer that hangs and a device that reports
        // itself idle afterwards, and it cost most of a day to stop reading as
        // a framing bug. Busy is a real answer and the only correct response
        // to it is to wait, so it is reported rather than pushed past.
        guard let code = deviceStatus() else { return }
        trace(String(format: "[usb] ? device status at connect: 0x%04X (raw %@)",
              code, lastStatusBytes))

        // Report it and stop. Nothing clever.
        //
        // This used to try to take a stuck transaction back — a Cancel
        // Request, then a class-level reset if that failed. Both wedged the
        // device outright: the control pipe stopped answering and the unit
        // needed its power cycling, twice. Whatever state a zūmo is in when it
        // says this, neither of those is the way out of it, and guessing costs
        // the user a power cycle each time.
        if code == MTP.Response.deviceBusy.rawValue {
            throw MTP.Failure.deviceRefused(code)
        }
    }


    /// The response code the device reports over the control pipe, if it will
    /// say. Nil when the request itself failed, which is a dead connection
    /// rather than a busy device and means something quite different.
    private func deviceStatus() -> UInt16? {
        guard let handle else { return nil }
        var status = [UInt8](repeating: 0, count: 64)
        let read = Int(sc_usb_mtp_device_status(handle, &status, Int32(status.count)))
        guard read >= 4 else { return nil }
        // The dataset is a length then a code, both little-endian. Keeping the
        // raw bytes is cheap and means a misread field cannot be mistaken for
        // a device in a state it is not in.
        lastStatusBytes = status[0..<min(read, 8)]
            .map { String(format: "%02X", $0) }.joined(separator: " ")
        return UInt16(status[2]) | UInt16(status[3]) << 8
    }

    private var lastStatusBytes = ""

    /// Takes any pending events off the interrupt pipe.
    ///
    /// Returns whether anything was there, so the caller knows to look again
    /// for the reply that was stuck behind them.
    @discardableResult
    private func drainEvents() -> Bool {
        guard let handle else { return false }
        var buffer = [UInt8](repeating: 0, count: 512)
        var any = false
        for _ in 0..<8 {
            let read = Int(sc_usb_event_read(handle, &buffer, Int32(buffer.count), 200))
            guard read >= MTP.Container.headerSize else { break }
            var reader = MTP.Reader(Data(buffer[0..<read]))
            _ = try? reader.uint32()
            _ = try? reader.uint16()
            let code = (try? reader.uint16()) ?? 0
            let txn = (try? reader.uint32()) ?? 0
            trace(String(format: "[usb] * event 0x%04X txn %u, %d bytes", code, txn, read))
            any = true
        }
        return any
    }

    /// Reads and throws away whatever is still queued.
    ///
    /// This device answers a write it dislikes, but not always promptly: a
    /// refusal that never arrived inside a thirty-second wait turned up on
    /// the *next process's* first read, minutes later, and was taken for the
    /// answer to that process's first question. Anything left in the pipe
    /// belongs to a conversation that is over, so it is read off and dropped
    /// before a new one starts.
    private func drain() {
        guard let handle else { return }
        var buffer = [UInt8](repeating: 0, count: 512 * 1024)
        for _ in 0..<16 {
            let read = Int(sc_usb_bulk_read(handle, &buffer, Int32(buffer.count), 300))
            if read <= 0 { return }
            // A 12-byte header is enough to say what was abandoned, and the
            // code is the diagnosis this spent a day not having.
            if read >= MTP.Container.headerSize {
                var reader = MTP.Reader(Data(buffer[0..<read]))
                _ = try? reader.uint32()
                let kind = (try? reader.uint16()) ?? 0
                let code = (try? reader.uint16()) ?? 0
                let txn = (try? reader.uint32()) ?? 0
                trace(String(format: "[usb] ~ drained kind %u code 0x%04X txn %u, %d bytes",
                      kind, code, txn, read))
            }
        }
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
                         sending payload: Data? = nil,
                         startingTransaction fixed: UInt32? = nil) throws -> Reply {
        let id: UInt32
        if let fixed {
            id = fixed
        } else {
            transaction &+= 1
            id = transaction
        }

        do {
            sawStaleReply = false
            return try exchange(operation, id, parameters, sending: payload)
        } catch where sawStaleReply && payload == nil && fixed == nil {
            // The stale reply we stepped over was released *by* this command,
            // and releasing it is all this device did with it. Asking again is
            // how the two ends get back in step. Only for operations that
            // carry no data and so cannot create anything by being repeated:
            // a second SendObjectInfo would be a second file.
            trace(String(format: "[usb] ! 0x%04X was swallowed releasing a stale reply; asking again",
                  operation.rawValue))
            transaction &+= 1
            sawStaleReply = false
            do {
                return try exchange(operation, transaction, parameters, sending: nil)
            } catch {
                reportDeviceStatus(after: operation)
                recover()
                throw error
            }
        } catch MTP.Failure.deviceRefused(let code) {
            // A refusal is an answer. The device completed the exchange and is
            // holding nothing, so there is nothing to withdraw and nothing to
            // clear — and withdrawing anyway is not harmless: cancelling a
            // transaction the device had already finished cleanly made it
            // ignore every command that followed. `Session_Not_Open` in reply
            // to closing a session nobody opened came through here.
            throw MTP.Failure.deviceRefused(code)
        } catch {
            // Only a transport failure gets this far: the device said nothing
            // at all. Asking over the control pipe is the one question that
            // still gets an answer when a read has timed out, and it separates
            // "the device never answered" from "the answer could not be
            // delivered", which reading the bulk pipe cannot do.
            // Asking is read-only and safe. Withdrawing is not: a Cancel
            // Request wedged this device both times it was sent, and the cost
            // of being wrong about it is a power cycle. The spec says cancel
            // is how a host takes back a request that timed out, and that may
            // well be true elsewhere — but nothing here has earned the right
            // to send one, so it stays out until something does.
            reportDeviceStatus(after: operation)
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

        // Straight from the command to the data, with nothing in between.
        //
        // There was a read here once, looking for an early refusal. It cost
        // an afternoon: a timed-out bulk read is aborted at the pipe, and on
        // a zūmo that abort left the responder waiting for the rest of a
        // transfer that had already finished. Every SendObjectInfo then hung
        // for the full timeout and answered only when the *next* command
        // block arrived and unwedged it. Reads that work — device info,
        // listings, partial object reads — carry no outgoing data and so
        // never ran the probe, which is why sending was the only broken path.
        //
        // A genuine early refusal needs no probe. It arrives as a response
        // for this transaction and is read below like any other.
        if let payload {
            try write(container: .init(kind: .data, code: operation.rawValue,
                                       transaction: id, payload: payload))
        }

        var reply = Reply()
        var container = try readMatching(id)

        if container.kind == .data {
            reply.data = container.payload
            container = try readMatching(id)
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
        trace(String(format: "[usb] > %@ code 0x%04X txn %u, %d bytes payload",
              String(describing: container.kind), container.code,
              container.transaction, container.payload.count))

        var writer = MTP.Writer()
        writer.uint32(UInt32(MTP.Container.headerSize + container.payload.count))
        writer.uint16(container.kind.rawValue)
        writer.uint16(container.code)
        writer.uint32(container.transaction)

        // The data header goes on its own, and this is the whole of why
        // writing to a Garmin never worked.
        //
        // Sent as one transfer, this device accepts the command, silently
        // refuses the data phase, and withholds the general error that says so
        // until the next command block arrives — so the answer lands against
        // the following request and the same failure reads differently every
        // time. Split in two, the identical bytes are accepted and
        // `SendObjectInfo` returns a handle. Every operation that only reads
        // worked throughout, because a read has no outbound data phase at all;
        // writing is the only time two outbound transfers happen in a row.
        //
        // Be aware that this contradicts the reference implementations.
        // libmtp and libgphoto2 both put the header in the same write as the
        // first payload chunk, and gate the split behind a quirk flag they set
        // for one Android operation only. The Android responder Garmin's
        // firmware descends from reads the data phase with a single read,
        // which on their reading should see twelve bytes and an empty payload.
        // It does not: measured against this unit, joined fails every time and
        // split succeeds every time, with the file read back byte-identical.
        // Trust the device over the documentation here, and re-measure before
        // assuming it holds for other hardware.
        if container.kind == .data {
            try writeAll(writer.data, handle: handle)
            try writeAll(container.payload, handle: handle)
            trace(String(format: "[usb] > wrote %d + %d bytes",
                  writer.data.count, container.payload.count))
            terminateIfNeeded(container.payload.count, handle: handle)
            return
        }

        var bytes = writer.data
        bytes.append(container.payload)
        try writeAll(bytes, handle: handle)
        trace(String(format: "[usb] > wrote %d bytes", bytes.count))
        terminateIfNeeded(bytes.count, handle: handle)
    }

    /// A transfer whose length is an exact multiple of the endpoint's packet
    /// size has to be followed by an empty packet, or the device keeps waiting
    /// for the rest and the next read times out with nothing to explain it.
    private func terminateIfNeeded(_ count: Int, handle: OpaquePointer) {
        let packet = Int(sc_usb_max_packet_out(handle))
        guard packet > 0, count > 0, count % packet == 0 else { return }
        trace(String(format: "[usb] > zero-length packet (%d is a multiple of %d)", count, packet))
        _ = sc_usb_bulk_write(handle, nil, 0, timeout)
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

    /// Reads until something arrives that belongs to this transaction.
    ///
    /// Every container carries the transaction id it answers, and ignoring it
    /// is how a late reply becomes the wrong answer to the next question. A
    /// request that times out does not stop the device replying eventually,
    /// and that stale reply was being read as the response to whatever was
    /// asked next — which made the same operation look like it failed
    /// differently each time it was tried.
    ///
    /// Events carry their own numbering and are stepped over here too, which
    /// is cheaper than opening an interrupt endpoint we have no other use for.
    /// Set when a reply belonging to an earlier question had to be stepped
    /// over, which on this device means the question just asked was swallowed.
    private var sawStaleReply = false

    private func readMatching(_ id: UInt32) throws -> MTP.Container {
        for _ in 0..<8 {
            let container = try readContainer()
            if container.kind == .event { continue }
            if container.transaction == id { return container }
            sawStaleReply = true
            trace(String(format: "[usb] ! stale %@ for txn %u while waiting for txn %u",
                  String(describing: container.kind), container.transaction, id))
        }
        throw MTP.Failure.malformedResponse("no reply for transaction \(id)")
    }

    /// Reads one container, following it with more reads until the length in
    /// its header is satisfied.
    ///
    /// The device answers in packets of its endpoint size, so a large object
    /// arrives as many reads and the header only appears in the first.
    private func readContainer(timeout override: Int32? = nil) throws -> MTP.Container {
        guard let handle else { throw MTP.Failure.noDevice }

        let wait = override ?? timeout
        let bufferSize = 512 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        // Step over zero-length packets.
        //
        // A transfer whose length is an exact multiple of the endpoint packet
        // size is terminated by an empty packet, and that marker sits in the
        // pipe until something reads it. The next command then reads the
        // marker instead of its own reply and sees nothing at all.
        //
        // This is what made a partial read of a 22 MB file fail while the
        // same read of a 2 KB file worked: it was never about the size, it
        // was about whatever came before happening to land on a boundary.
        // We send our own terminator for exactly this reason and then did not
        // expect one back.
        // The first read waits properly; retries past an empty packet do not.
        // Four full-length waits stacked up meant a silent device took four
        // minutes to report a timeout, which reads as a hang rather than a
        // failure.
        var first = 0
        let began = Date()
        for attempt in 0..<4 {
            first = Int(sc_usb_bulk_read(handle, &buffer, Int32(bufferSize),
                                         attempt == 0 ? wait : 500))
            if first > 0 { break }

            // Nothing on the bulk pipe. Before calling it a timeout, take
            // whatever is waiting on the interrupt pipe: a responder holding
            // an undelivered event will not send the response queued behind
            // it, and reads raise no events, so this only ever bites on a
            // write. It looked for a long time like the device was refusing
            // the write itself.
            if drainEvents() { continue }
            if first != 0 { break }
        }

        // A stalled inbound pipe is the device talking, not the device gone.
        //
        // Stalling the bulk-in endpoint is how an MTP responder says it cannot
        // do what was asked. The answer is queued behind the stall, and the
        // protocol's recovery is to clear it and read again. We never did, so
        // the read timed out and the reply stayed in the pipe — where the next
        // launch found it, because claiming the interface afresh resets the
        // endpoint. That is the whole reason every answer arrived one run late
        // and looked like a reply to the wrong question.
        if first < MTP.Container.headerSize, sc_usb_pipe_status(handle, 0) == 1 {
            trace(String(format: "[usb] < inbound pipe stalled; clearing and reading again"))
            _ = sc_usb_clear_halt_in(handle)
            first = Int(sc_usb_bulk_read(handle, &buffer, Int32(bufferSize), 2_000))
        }

        guard first >= MTP.Container.headerSize else {
            let waited = Int(Date().timeIntervalSince(began) * 1000)
            trace(String(format: "[usb] < nothing after %d ms (read returned %d); pipes in %d out %d",
                  waited, first,
                  Int(sc_usb_pipe_status(handle, 0)), Int(sc_usb_pipe_status(handle, 1))))
            throw MTP.Failure.transferFailed("read returned \(first)")
        }
        if Date().timeIntervalSince(began) > 1 {
            trace(String(format: "[usb] < waited %d ms for %d bytes",
                  Int(Date().timeIntervalSince(began) * 1000), first))
        }

        var received = Data(buffer[0..<first])
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
                                        Int32(min(bufferSize, total - received.count)), wait)
            guard more > 0 else {
                throw MTP.Failure.transferFailed("read stopped \(total - received.count) bytes short")
            }
            received.append(contentsOf: buffer[0..<Int(more)])
        }

        trace(String(format: "[usb] < %@ code 0x%04X txn %u, %d bytes",
              String(describing: kind), code, transaction, total))
        return MTP.Container(kind: kind, code: code, transaction: transaction,
                             payload: received.dropFirst(MTP.Container.headerSize))
    }
}
#endif
