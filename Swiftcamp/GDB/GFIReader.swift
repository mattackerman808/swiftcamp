import Foundation

/// Reads BaseCamp's `FolderData.gfi`, the file beside its autosaved
/// `AllData.gdb` that holds the lists. It is the same container as GDB
/// with a different signature and its own record types, from the same
/// notes, checked against a BaseCamp 4.8 autosave on the Mac.
///
/// BaseCamp's vocabulary: an item is what the user calls a list, and a
/// folder groups lists. My Collection is the root folder. Some items are
/// BaseCamp's own and not the user's: "Unlisted Data" and the smart lists
/// "Last Week" and "Last Month", told apart by how they were created.
/// Membership is one record per member per list, naming the item and the
/// member, which is why a route in two lists appears twice here and once
/// in a library that files an item in one place.
enum GFIReader {
    static func read(contentsOf url: URL) throws -> [ImportedList] {
        try read(data: Data(contentsOf: url))
    }

    static func looksLikeGFI(_ data: Data) -> Bool {
        data.count > 6 && data.prefix(4) == Data("DifG".utf8)
    }

    /// The user's lists, nested through their folders, each naming the
    /// waypoints, routes and tracks filed in it.
    static func read(data: Data) throws -> [ImportedList] {
        guard looksLikeGFI(data) else { throw GDBError.notGDB }
        var cursor = GDBCursor(data, from: 6)

        struct Folder { var name: String; var parent: UInt32 }
        struct Item { var name: String; var createdBy: UInt32; var folder: UInt32 }
        var folders: [UInt32: Folder] = [:]
        var items: [UInt32: Item] = [:]
        var itemOrder: [UInt32] = []
        var members: [UInt32: ImportedList.Members] = [:]

        while cursor.remaining >= 5 {
            let length = Int(try cursor.u32())
            let type = try cursor.u8()
            guard cursor.remaining >= length else { throw GDBError.truncated }
            var s = GDBCursor(data, from: cursor.offset, count: length)
            cursor.skip(length)

            switch type {
            case UInt8(ascii: "A"):
                _ = try cursor.cString()                 // the application field follows the record
            case UInt8(ascii: "F"):
                let id = try s.u32()
                let name = try s.string(utf8: true)
                let parent = try s.u32()
                folders[id] = Folder(name: name, parent: parent)
            case UInt8(ascii: "I"):
                let id = try s.u32()
                let name = try s.string(utf8: true)
                let createdBy = try s.u32()
                let folder = try s.u32()
                items[id] = Item(name: name, createdBy: createdBy, folder: folder)
                itemOrder.append(id)
            case UInt8(ascii: "W"), UInt8(ascii: "R"), UInt8(ascii: "T"):
                let item = try s.u32()
                let name = try s.string(utf8: true)
                var m = members[item] ?? ImportedList.Members()
                switch type {
                case UInt8(ascii: "W"): m.waypoints.append(name)
                case UInt8(ascii: "R"): m.routes.append(name)
                default: m.tracks.append(name)
                }
                members[item] = m
            default:
                break
            }
        }

        // BaseCamp's own items stay out: 8 is Unlisted Data, 3 a smart
        // list. 0 is the user's and 1 one made for them on import, which
        // they see and name like any other.
        let root: UInt32 = 0xFFFF_FFFF
        func folderName(_ id: UInt32) -> String? {
            guard id != root, let folder = folders[id] else { return nil }
            return folder.name
        }
        var lists: [ImportedList] = []
        for (id, folder) in folders.sorted(by: { $0.key < $1.key }) where id != root {
            lists.append(ImportedList(name: folder.name, parent: folderName(folder.parent)))
        }
        for id in itemOrder {
            guard let item = items[id], item.createdBy == 0 || item.createdBy == 1 else { continue }
            lists.append(ImportedList(name: item.name, parent: folderName(item.folder),
                                      members: members[id] ?? ImportedList.Members()))
        }
        return lists
    }
}

/// A list from another program's library: its name, the list it sits
/// in, and its members by name. Names because that is all a folder file
/// holds; the store matches them against what the same import created.
struct ImportedList: Equatable, Sendable {
    struct Members: Equatable, Sendable {
        var waypoints: [String] = []
        var routes: [String] = []
        var tracks: [String] = []
    }

    var name: String
    var parent: String?
    var members = Members()
}
