import XCTest
@testable import Swiftcamp

/// BaseCamp's folder file, and the lists it becomes on import.
final class GFIReaderTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil), "\(name) is not in the test bundle")
    }

    /// The Mac autosave's folder file: My Collection at the root, BaseCamp's
    /// Unlisted Data and two smart lists, and the one list the import made,
    /// named after the file it came from, holding both waypoints and the route.
    func testUserListsAndTheirMembers() throws {
        let lists = try GFIReader.read(contentsOf: try fixture("basecamp-mac-AllData.gfi"))
        XCTAssertEqual(lists.map(\.name), ["My Collection.gdb"], "BaseCamp's own lists stay out")
        let list = try XCTUnwrap(lists.first)
        XCTAssertNil(list.parent, "at the top, under My Collection")
        XCTAssertEqual(Set(list.members.waypoints), ["Reno", "Santa Clara"])
        XCTAssertEqual(list.members.routes, ["Santa Clara to Reno"])
        XCTAssertEqual(list.members.tracks, [])
    }

    func testRefusesWhatIsNotAFolderFile() throws {
        XCTAssertThrowsError(try GFIReader.read(contentsOf: try fixture("basecamp-mac-AllData.gdb")))
    }

    /// The import door reads the folder file beside a library, by the
    /// library's own name or as BaseCamp names it.
    func testImportPicksUpTheFolderFileBesideTheLibrary() throws {
        let document = try FileImport.read(contentsOf: try fixture("basecamp-mac-AllData.gdb"))
        XCTAssertEqual(document.lists.map(\.name), ["My Collection.gdb"])
        XCTAssertNil(FileImport.folderFile(beside: try fixture("gpsbabel-route-v3.gdb")))
    }

    /// Importing a library with lists recreates them, nested, and files
    /// what they name, matched only among what the same import made.
    func testStoreRecreatesListsAndFilesMembers() throws {
        let store = LibraryStore(try AppDatabase.inMemory())
        try store.save(Waypoint(name: "Reno", lat: 1, lon: 1))   // a stranger with the same name

        var document = try FileImport.read(contentsOf: try fixture("basecamp-mac-AllData.gdb"))
        document.lists = [
            ImportedList(name: "Trips", parent: nil),
            ImportedList(name: "Nevada", parent: "Trips",
                         members: .init(waypoints: ["Reno"], routes: ["Santa Clara to Reno"], tracks: [])),
            ImportedList(name: "Orphan", parent: "Never Made",
                         members: .init(waypoints: ["Santa Clara"], routes: [], tracks: [])),
        ]
        try store.importGPX(document)

        let lists = try store.lists()
        let byName = Dictionary(uniqueKeysWithValues: lists.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName.keys), ["Trips", "Nevada", "Orphan"])
        XCTAssertEqual(byName["Nevada"]?.parentID, byName["Trips"]?.id)
        XCTAssertNil(byName["Orphan"]?.parentID, "a parent never made puts the list at the top")

        let waypoints = try store.waypoints()
        let renos = waypoints.filter { $0.name == "Reno" }
        XCTAssertEqual(renos.count, 2)
        XCTAssertEqual(renos.filter { $0.listID == byName["Nevada"]?.id }.count, 1, "the imported Reno, not the stranger")
        XCTAssertEqual(renos.filter { $0.lat == 1 }.first?.listID, nil)
        XCTAssertEqual(waypoints.first { $0.name == "Santa Clara" }?.listID, byName["Orphan"]?.id)
        XCTAssertEqual(try store.routes().first?.listID, byName["Nevada"]?.id)
    }
}
