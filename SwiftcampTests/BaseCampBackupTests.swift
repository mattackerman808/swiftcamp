import XCTest
@testable import Swiftcamp

/// `basecamp-backup.backup` is a zip laid out as BaseCamp's Application
/// Support folder: the real Mac autosave under `Database/4.8` with its
/// folder file, an older library under `Database/4.7`, and a photo stored
/// uncompressed, so both of the zip methods BaseCamp's writer uses are read.
final class BaseCampBackupTests: XCTestCase {
    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil), "\(name) is not in the test bundle")
    }

    /// The library inside the zip is the loose autosave beside it in the
    /// fixtures, lists and road shape included, so the newest version was
    /// chosen and inflating lost nothing.
    func testReadsTheNewestLibraryWithItsLists() throws {
        let fromBackup = try FileImport.read(contentsOf: try fixture("basecamp-backup.backup"))
        let loose = try FileImport.read(contentsOf: try fixture("basecamp-mac-AllData.gdb"))
        XCTAssertEqual(fromBackup.lists.map(\.name), ["My Collection.gdb"], "the folder file beside it")
        XCTAssertEqual(fromBackup.lists, loose.lists)
        XCTAssertEqual(fromBackup.routes.map(\.route.name), ["Santa Clara to Reno"], "4.8, not 4.7")
        // Ids and import times are fresh on every read, so compare what
        // came out of the file rather than the whole value.
        XCTAssertEqual(fromBackup.waypoints.map { [$0.name, "\($0.lat)", "\($0.lon)"] },
                       loose.waypoints.map { [$0.name, "\($0.lat)", "\($0.lon)"] })
        let road = { (d: GPXDocument) in d.routes.flatMap(\.points).flatMap { [Coordinate(lat: $0.lat, lon: $0.lon)] + ($0.geometry ?? []) } }
        XCTAssertGreaterThan(road(fromBackup).count, 100)
        XCTAssertEqual(road(fromBackup), road(loose), "the road, point for point")
    }

    func testStoredAndDeflatedEntriesBothInflate() throws {
        let archive = try ZipArchive(data: Data(contentsOf: try fixture("basecamp-backup.backup")))
        let photo = try XCTUnwrap(archive.entries.first { $0.path == "Photos/ride.jpg" })
        XCTAssertEqual(photo.method, 0)
        XCTAssertEqual(try archive.contents(of: photo).count, 5000)
        let gfi = try XCTUnwrap(archive.entries.first { $0.path == "Database/4.8/FolderData.gfi" })
        XCTAssertEqual(gfi.method, 8)
        XCTAssertEqual(try archive.contents(of: gfi), try Data(contentsOf: try fixture("basecamp-mac-AllData.gfi")))
    }

    func testRefusesAnArchiveWithNoLibrary() throws {
        // The backup cut off before its first central entry is still a
        // zip by signature and holds nothing readable.
        let whole = try Data(contentsOf: try fixture("basecamp-backup.backup"))
        XCTAssertThrowsError(try FileImport.read(data: whole.prefix(200)))
        XCTAssertThrowsError(try ZipArchive(data: Data("not a zip".utf8)))
    }
}
