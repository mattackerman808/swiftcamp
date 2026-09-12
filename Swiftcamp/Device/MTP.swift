#if os(macOS)
import Foundation

/// Media Transfer Protocol, over USB bulk endpoints.
///
/// MTP is PTP with extensions, and the part that matters here is pure PTP:
/// sessions, storages, object handles, and reading and writing objects. The
/// device serves objects in reply to commands, which is why nothing mounts —
/// there is no block device for the system to put a filesystem on.
///
/// Everything is little-endian. Everything.
enum MTP {
    // MARK: - Wire format

    /// Every exchange is a sequence of these.
    ///
    /// `length` counts the header too, which is the first thing to get wrong.
    struct Container {
        static let headerSize = 12

        enum Kind: UInt16 {
            case command = 1
            case data = 2
            case response = 3
            case event = 4
        }

        var kind: Kind
        var code: UInt16
        var transaction: UInt32
        var payload: Data
    }

    enum Operation: UInt16 {
        case getDeviceInfo = 0x1001
        case openSession = 0x1002
        case closeSession = 0x1003
        case getStorageIDs = 0x1004
        case getStorageInfo = 0x1005
        case getObjectHandles = 0x1007
        case getObjectInfo = 0x1008
        case getObject = 0x1009
        /// Reads a byte range. Optional in the standard, which is why every
        /// caller has to be able to manage without it.
        case getPartialObject = 0x101B
        case deleteObject = 0x100B
        case sendObjectInfo = 0x100C
        case sendObject = 0x100D
    }

    enum Response: UInt16 {
        case ok = 0x2001
        case generalError = 0x2002
        case sessionNotOpen = 0x2003
        case invalidTransactionID = 0x2004
        case operationNotSupported = 0x2005
        case parameterNotSupported = 0x2006
        case incompleteTransfer = 0x2007
        case invalidStorageID = 0x2008
        case invalidObjectHandle = 0x2009
        case invalidObjectFormatCode = 0x200B
        case storeFull = 0x200C
        case objectWriteProtected = 0x200D
        case storeReadOnly = 0x200E
        case accessDenied = 0x200F
        case noValidObjectInfo = 0x2015
        case deviceBusy = 0x2019
        case invalidParentObject = 0x201A
        case invalidParameter = 0x201D
        case sessionAlreadyOpen = 0x201E
        case transactionCancelled = 0x201F

        /// What to tell the user, in words.
        ///
        /// A bare `0x2002` says nothing to anyone. Several of these have an
        /// obvious remedy and the message should carry it: a device that is
        /// busy wants a moment, one left mid-transaction wants a reset.
        var explanation: String {
            switch self {
            case .ok: return "succeeded"
            case .generalError: return "the device reported a general error, which usually means it was left part-way through an earlier transfer"
            case .sessionNotOpen: return "no session is open"
            case .invalidTransactionID: return "the device lost track of the conversation"
            case .operationNotSupported: return "the device does not support that operation"
            case .parameterNotSupported: return "the device did not accept one of the values"
            case .incompleteTransfer: return "the transfer did not finish"
            case .invalidStorageID: return "that storage is not on the device"
            case .invalidObjectHandle: return "that file is no longer on the device"
            case .invalidObjectFormatCode: return "the device rejected the file type"
            case .storeFull: return "the device is full"
            case .objectWriteProtected: return "that file is write-protected"
            case .storeReadOnly: return "that storage is read-only"
            case .accessDenied: return "the device refused access"
            case .noValidObjectInfo: return "the device was not told what was coming"
            case .deviceBusy: return "the device is busy"
            case .invalidParentObject: return "that folder is not somewhere the device will accept a file"
            case .invalidParameter: return "the device did not accept one of the values"
            case .sessionAlreadyOpen: return "a session is already open"
            case .transactionCancelled: return "the device cancelled the transfer"
            }
        }
    }

    /// Object format codes. Only the two that matter here.
    enum Format: UInt16 {
        case undefined = 0x3000
        /// A folder. MTP models the tree as objects that point at a parent.
        case association = 0x3001
    }

    /// The parent handle meaning "the root of this storage".
    static let rootParent: UInt32 = 0xFFFF_FFFF

    // MARK: - Errors

    enum Failure: LocalizedError {
        case noDevice
        case openFailed(Int32)
        case transferFailed(String)
        case malformedResponse(String)
        case deviceRefused(UInt16)
        case notFound(String)

        var errorDescription: String? {
            switch self {
            case .noDevice:
                return "No device is connected."
            case .openFailed(let code):
                return "Could not open the device (\(code)). Another program may be using it."
            case .transferFailed(let detail):
                return "The transfer failed: \(detail)"
            case .malformedResponse(let detail):
                return "The device sent something unexpected: \(detail)"
            case .deviceRefused(let code):
                let hex = String(format: "0x%04X", code)
                guard let known = Response(rawValue: code) else {
                    return "The device refused the request (\(hex))."
                }
                return "The device refused the request: \(known.explanation) (\(hex))."
            case .notFound(let what):
                return "\(what) is not on the device."
            }
        }
    }

    // MARK: - Reading a payload

    /// Little-endian cursor over a response payload.
    ///
    /// Every read is bounds-checked and throws rather than trapping. The
    /// input is bytes from a device we do not control, and a short or
    /// malformed reply should surface as a message, not a crash.
    struct Reader {
        private let data: Data
        private var offset: Int

        init(_ data: Data) {
            self.data = data
            self.offset = 0
        }

        var isAtEnd: Bool { offset >= data.count }

        mutating func uint8() throws -> UInt8 {
            guard offset < data.count else { throw Failure.malformedResponse("ran off the end") }
            defer { offset += 1 }
            return data[data.startIndex + offset]
        }

        mutating func uint16() throws -> UInt16 {
            UInt16(try uint8()) | (UInt16(try uint8()) << 8)
        }

        mutating func uint32() throws -> UInt32 {
            UInt32(try uint16()) | (UInt32(try uint16()) << 16)
        }

        mutating func uint64() throws -> UInt64 {
            UInt64(try uint32()) | (UInt64(try uint32()) << 32)
        }

        /// A PTP string: one byte of length in *characters* including the
        /// terminator, then UTF-16LE. Zero length means empty, with no
        /// terminator following — not a one-character empty string.
        mutating func string() throws -> String {
            let characters = try uint8()
            guard characters > 0 else { return "" }

            var units: [UInt16] = []
            units.reserveCapacity(Int(characters))
            for _ in 0..<characters { units.append(try uint16()) }
            if units.last == 0 { units.removeLast() }
            return String(decoding: units, as: UTF16.self)
        }

        /// A PTP array is a `uint32` count followed by that many elements —
        /// but the element width varies by field, and getting it wrong does
        /// not fail where it happens. Reading a `uint16` array as `uint32`
        /// consumes twice the bytes, and the damage only surfaces several
        /// fields later as an absurd count for something else.
        mutating func uint32Array() throws -> [UInt32] {
            let count = try arrayCount()
            return try (0..<count).map { _ in try uint32() }
        }

        mutating func uint16Array() throws -> [UInt16] {
            let count = try arrayCount()
            return try (0..<count).map { _ in try uint16() }
        }

        private mutating func arrayCount() throws -> UInt32 {
            let count = try uint32()
            // A device reporting an implausible count is malformed rather
            // than a reason to allocate a gigabyte. It also means the parse
            // has drifted, which is the more useful thing to be told.
            guard count < 1_000_000 else {
                throw Failure.malformedResponse("an array of \(count) elements, which means the "
                                                + "reply is being read at the wrong offset")
            }
            return count
        }

        mutating func skip(_ bytes: Int) throws {
            guard offset + bytes <= data.count else {
                throw Failure.malformedResponse("ran off the end")
            }
            offset += bytes
        }
    }

    /// Little-endian builder for a command payload.
    struct Writer {
        private(set) var data = Data()

        mutating func uint8(_ value: UInt8) { data.append(value) }
        mutating func uint16(_ value: UInt16) { uint8(UInt8(value & 0xff)); uint8(UInt8(value >> 8)) }
        mutating func uint32(_ value: UInt32) { uint16(UInt16(value & 0xffff)); uint16(UInt16(value >> 16)) }

        mutating func string(_ value: String) {
            guard !value.isEmpty else { return uint8(0) }
            let units = Array(value.utf16)
            uint8(UInt8(min(units.count + 1, 255)))
            for unit in units.prefix(254) { uint16(unit) }
            uint16(0)
        }
    }

    // MARK: - Object metadata

    struct ObjectInfo {
        var storageID: UInt32 = 0
        var format: UInt16 = Format.undefined.rawValue
        var size: UInt32 = 0
        var parent: UInt32 = 0
        var filename: String = ""
        var modified: String = ""

        var isFolder: Bool { format == Format.association.rawValue }

        /// The dataset the device sends back, and the one it expects for
        /// `SendObjectInfo`. The field order is fixed by the spec and every
        /// field has to be present even when it means nothing for a file.
        init(_ reader: inout Reader) throws {
            storageID = try reader.uint32()
            format = try reader.uint16()
            _ = try reader.uint16()                  // protection status
            size = try reader.uint32()
            try reader.skip(2 + 4 + 4 + 4)           // thumb format, size, width, height
            try reader.skip(4 + 4 + 4)               // image width, height, bit depth
            parent = try reader.uint32()
            try reader.skip(2 + 4 + 4)               // association type, description, sequence
            filename = try reader.string()
            _ = try reader.string()                  // capture date
            modified = try reader.string()
        }

        init(storageID: UInt32, parent: UInt32, filename: String, size: UInt32, isFolder: Bool) {
            self.storageID = storageID
            self.parent = parent
            self.filename = filename
            self.size = size
            self.format = isFolder ? Format.association.rawValue : Format.undefined.rawValue
        }

        func encoded() -> Data {
            var w = Writer()
            w.uint32(storageID)
            w.uint16(format)
            w.uint16(0)                              // protection status
            w.uint32(size)
            w.uint16(0); w.uint32(0); w.uint32(0); w.uint32(0)   // thumbnail, all unused
            w.uint32(0); w.uint32(0); w.uint32(0)                // image dimensions, unused
            w.uint32(parent)
            // Association type 1 is a generic folder. It must be zero for a
            // file: a non-zero value there makes some devices file the object
            // as a directory and the transfer appears to succeed while
            // producing something unopenable.
            w.uint16(isFolder ? 1 : 0)
            w.uint32(0)                              // association description
            w.uint32(0)                              // sequence number
            w.string(filename)
            w.string("")                             // capture date
            w.string("")                             // modification date
            w.string("")                             // keywords
            return w.data
        }
    }

    struct DeviceInfo {
        var manufacturer = ""
        var model = ""
        var deviceVersion = ""
        var serialNumber = ""

        /// What the device says it can do.
        ///
        /// Worth keeping rather than skipping past: half the operations in
        /// MTP are optional, and asking a device for one it does not have
        /// costs a failed round trip and an error that reads like a bug.
        var operations: Set<UInt16> = []

        func supports(_ operation: Operation) -> Bool {
            operations.contains(operation.rawValue)
        }
    }

    struct StorageInfo {
        var id: UInt32
        var capacity: UInt64
        var free: UInt64
        var description: String
        var volumeLabel: String

        var name: String {
            if !description.isEmpty { return description }
            if !volumeLabel.isEmpty { return volumeLabel }
            return "Storage \(id)"
        }
    }
}
#endif
