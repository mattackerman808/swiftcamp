import XCTest
@testable import Swiftcamp

/// A memory card in a reader, played by a folder on disk: the one device
/// path that needs no hardware to check.
final class VolumeBrowserTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftcamp-card-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ path: String, _ contents: String = "") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func gpx(_ times: [String]) -> String {
        "<?xml version=\"1.0\"?><gpx version=\"1.1\" creator=\"t\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><trkseg>"
            + times.map { "<trkpt lat=\"40\" lon=\"-105\"><time>\($0)</time></trkpt>" }.joined()
            + "</trkseg></trk></gpx>"
    }

    // MARK: - Finding a card

    func testAVolumeWithAGarminFolderIsACardAndOneWithoutIsNot() throws {
        let other = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try make("garmin/GPX/Ride.gpx", gpx([]))

        let cards = GarminUnit.volumes(among: [root, other])
        XCTAssertEqual(cards.count, 1)
        XCTAssertEqual(cards.first?.volume, root.standardizedFileURL)
        XCTAssertEqual(cards.first?.vendorID, GarminUnit.vendorID, "listed with the Garmins")
        XCTAssertTrue(cards.first!.name.contains("memory card"))
        XCTAssertNotEqual(cards.first!.locationID & 0x8000_0000, 0, "never a USB location")
        XCTAssertEqual(GarminUnit.volumes(among: [root]).first?.locationID, cards.first?.locationID,
                       "the same card gets the same id again")
    }

    // MARK: - Browsing

    func testTheGPXFolderIsFoundInAnyCase() throws {
        try make("garmin/gpx/Ride.gpx", gpx([]))
        let browser = VolumeBrowser(root: root, name: "Card")
        let folder = try browser.gpxFolder(storage: VolumeBrowser.storageID, creating: false)
        let files = try browser.contents(of: folder, storage: VolumeBrowser.storageID)
        XCTAssertEqual(files.map(\.name), ["Ride.gpx"])
        XCTAssertFalse(files[0].isFolder)
        XCTAssertGreaterThan(files[0].size, 0)
        XCTAssertNotNil(files[0].modified)
    }

    func testAMissingGPXFolderIsAnErrorUntilAskedToMakeIt() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Garmin"), withIntermediateDirectories: true)
        let browser = VolumeBrowser(root: root, name: "Card")
        XCTAssertThrowsError(try browser.gpxFolder(storage: 1, creating: false))
        _ = try browser.gpxFolder(storage: 1, creating: true)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Garmin/GPX").path,
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testTheRootListsFoldersFirstAndHandlesAreStable() throws {
        try make("Garmin/GPX/b.gpx")
        try make("Garmin/zz.txt")
        try make("a.txt")
        let browser = VolumeBrowser(root: root, name: "Card")
        let top = try browser.contents(of: MTP.rootParent, storage: 1)
        XCTAssertEqual(top.map(\.name), ["Garmin", "a.txt"])
        XCTAssertTrue(top[0].isFolder)
        let garmin = try browser.contents(of: top[0].handle, storage: 1)
        XCTAssertEqual(garmin.map(\.name), ["GPX", "zz.txt"])
        XCTAssertEqual(try browser.contents(of: MTP.rootParent, storage: 1)[0].handle, top[0].handle)
        XCTAssertEqual(try browser.gpxFolder(storage: 1, creating: false), garmin[0].handle,
                       "one handle per path, however it is reached")
    }

    // MARK: - Reading

    func testReadAndPeek() throws {
        let document = gpx(["2026-09-20T15:00:00Z", "2026-09-20T17:30:00Z"])
        try make("Garmin/GPX/Ride.gpx", document)
        let browser = VolumeBrowser(root: root, name: "Card")
        let file = try browser.contents(of: try browser.gpxFolder(storage: 1, creating: false), storage: 1)[0]

        XCTAssertEqual(try browser.read(file), Data(document.utf8))
        let peek = try XCTUnwrap(try browser.peek(file))
        XCTAssertTrue(peek.sawTrack)
        XCTAssertEqual(peek.start, ISO8601DateFormatter().date(from: "2026-09-20T15:00:00Z"))
        XCTAssertEqual(peek.end, ISO8601DateFormatter().date(from: "2026-09-20T17:30:00Z"))
    }

    func testPeekingALargeFileReadsItsTwoEnds() throws {
        // Past both windows, so the tail is a separate read at an offset.
        let padding = String(repeating: "<!-- -->", count: 4000)
        let document = "<?xml version=\"1.0\"?><gpx version=\"1.1\" creator=\"t\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><trkseg>"
            + "<trkpt lat=\"40\" lon=\"-105\"><time>2026-09-20T15:00:00Z</time></trkpt>" + padding
            + "<trkpt lat=\"40\" lon=\"-105\"><time>2026-09-20T17:30:00Z</time></trkpt></trkseg></trk></gpx>"
        XCTAssertGreaterThan(document.utf8.count, Int(GPXPeek.headBytes + GPXPeek.tailBytes))
        try make("Garmin/GPX/Long.gpx", document)
        let browser = VolumeBrowser(root: root, name: "Card")
        let file = try browser.contents(of: try browser.gpxFolder(storage: 1, creating: false), storage: 1)[0]
        let peek = try XCTUnwrap(try browser.peek(file))
        XCTAssertEqual(peek.start, ISO8601DateFormatter().date(from: "2026-09-20T15:00:00Z"))
        XCTAssertEqual(peek.end, ISO8601DateFormatter().date(from: "2026-09-20T17:30:00Z"))
    }

    // MARK: - Writing

    func testWritingMakesTheFolderAndReplacesANameInAnyCase() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Garmin"), withIntermediateDirectories: true)
        let browser = VolumeBrowser(root: root, name: "Card")
        try browser.write(Data("one".utf8), named: "Ride.gpx", storage: 1)
        try browser.write(Data("two".utf8), named: "RIDE.GPX", storage: 1)

        let files = try browser.contents(of: try browser.gpxFolder(storage: 1, creating: false), storage: 1)
        XCTAssertEqual(files.count, 1, "one copy of a route, whatever its case")
        XCTAssertEqual(try browser.read(files[0]), Data("two".utf8))
    }

    /// Finder's `._Name.gpx` twins end in .gpx and a zūmo reads them as
    /// GPX, after which it lists nothing to import; a write clears the
    /// twin of its own name, and the sweep clears them all.
    ///
    /// On APFS the system itself drops a stale twin when the real file is
    /// written, which an exFAT card does not do, so the twins here are
    /// made after their files and only the sweep is asserted exactly.
    func testAppleDoubleTwinsAreCleared() throws {
        try make("Garmin/GPX/Other.gpx", gpx([]))
        try make("Garmin/GPX/._Other.gpx", "junk")
        try make("Garmin/GPX/._Ride.gpx", "junk")
        let browser = VolumeBrowser(root: root, name: "Card")
        try browser.write(Data("ride".utf8), named: "Ride.gpx", storage: 1)
        let folder = root.appendingPathComponent("Garmin/GPX").path
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: folder).contains("._Ride.gpx"))
        _ = try browser.removeAppleDoubles(storage: 1)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder)), ["Ride.gpx", "Other.gpx"])
        XCTAssertEqual(try browser.contents(of: try browser.gpxFolder(storage: 1, creating: false), storage: 1).map(\.name),
                       ["Other.gpx", "Ride.gpx"])
    }

    func testTheStorageIsTheVolume() throws {
        try make("Garmin/GPX/Ride.gpx")
        let storages = try VolumeBrowser(root: root, name: "Card").storages()
        XCTAssertEqual(storages.map(\.id), [VolumeBrowser.storageID])
        XCTAssertEqual(storages[0].name, "Card")
        XCTAssertGreaterThan(storages[0].capacity, 0)
    }
}
