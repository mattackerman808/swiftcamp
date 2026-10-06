import XCTest
@testable import Swiftcamp

/// The archive reader against bytes taken from the real terrain archive:
/// its header and its root directory, exactly as the CDN serves them. The
/// expected numbers were read out of the same bytes in Python first.
final class PMTilesTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil), "fixture \(name)")
        return try Data(contentsOf: url)
    }

    func testTheHeaderReadsAsTheArchiveWasBuilt() throws {
        let header = try PMTiles.Header(try fixture("terrain-header.bin"))
        XCTAssertEqual(header.rootOffset, 127)
        XCTAssertEqual(header.rootLength, 263)
        XCTAssertEqual(header.leafOffset, 481)
        XCTAssertEqual(header.leafLength, 597_845)
        XCTAssertEqual(header.tileDataOffset, 598_326)
        XCTAssertTrue(header.clustered)
        XCTAssertEqual(header.internalCompression, 2, "gzip directories")
        XCTAssertEqual(header.tileCompression, 1, "tiles as served")
        XCTAssertEqual(header.tileType, 4, "WebP, not the PNG first assumed")
        XCTAssertEqual(header.minZoom, 0)
        XCTAssertEqual(header.maxZoom, 12)
        XCTAssertEqual(header.minLon, -125.0, accuracy: 1e-6)
        XCTAssertEqual(header.maxLat, 49.5, accuracy: 1e-6)
    }

    func testSomethingElseIsNotAnArchive() {
        XCTAssertThrowsError(try PMTiles.Header(Data(repeating: 0, count: 127)))
        XCTAssertThrowsError(try PMTiles.Header(Data("PMTiles".utf8)))
    }

    /// The spec's own examples.
    func testTileIDsFollowTheHilbertCurve() {
        XCTAssertEqual(PMTiles.tileID(z: 0, x: 0, y: 0), 0)
        XCTAssertEqual(PMTiles.tileID(z: 1, x: 0, y: 0), 1)
        XCTAssertEqual(PMTiles.tileID(z: 1, x: 0, y: 1), 2)
        XCTAssertEqual(PMTiles.tileID(z: 1, x: 1, y: 1), 3)
        XCTAssertEqual(PMTiles.tileID(z: 1, x: 1, y: 0), 4)
        XCTAssertEqual(PMTiles.tileID(z: 2, x: 0, y: 0), 5)
        XCTAssertEqual(PMTiles.tileID(z: 12, x: 846, y: 1546), 8_938_989, "the tile over Longs Peak")
    }

    func testTheRootDirectoryDecodes() throws {
        let entries = try PMTiles.decodeDirectory(try PMTiles.gunzip(try fixture("terrain-root.gz")))
        XCTAssertEqual(entries.count, 59)
        XCTAssertEqual(entries[0], PMTiles.Entry(tileID: 0, offset: 0, length: 11_412, runLength: 0))
        XCTAssertEqual(entries[1], PMTiles.Entry(tileID: 144_298, offset: 11_412, length: 11_102, runLength: 0))
        XCTAssertEqual(entries[58], PMTiles.Entry(tileID: 9_245_292, offset: 593_286, length: 4_559, runLength: 0))
        XCTAssertTrue(entries.allSatisfy(\.isLeaf), "the root of a clustered archive this size is all leaves")

        let leaf = try XCTUnwrap(PMTiles.find(8_938_989, in: entries))
        XCTAssertEqual(leaf.tileID, 8_936_820, "the leaf the Longs Peak tile is in")
        XCTAssertEqual(leaf.offset, 343_521)
    }

    func testFindingInsideAndOutsideARun() {
        let entries = [PMTiles.Entry(tileID: 10, offset: 0, length: 5, runLength: 3),
                       PMTiles.Entry(tileID: 20, offset: 5, length: 5, runLength: 1)]
        XCTAssertEqual(PMTiles.find(10, in: entries)?.offset, 0)
        XCTAssertEqual(PMTiles.find(12, in: entries)?.offset, 0, "inside the run")
        XCTAssertNil(PMTiles.find(13, in: entries), "past the run and before the next")
        XCTAssertNil(PMTiles.find(9, in: entries))
        XCTAssertEqual(PMTiles.find(20, in: entries)?.offset, 5)
        XCTAssertNil(PMTiles.find(21, in: entries))
    }

    func testGunzip() throws {
        let blob = Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0xff, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x57, 0x28, 0xc8, 0x2d, 0xc9, 0xcc, 0x49, 0x2d, 0x06, 0x00, 0x82, 0x27, 0xf9, 0x82, 0x0d, 0x00, 0x00, 0x00])
        XCTAssertEqual(String(decoding: try PMTiles.gunzip(blob), as: UTF8.self), "hello pmtiles")
        XCTAssertThrowsError(try PMTiles.gunzip(Data("not gzip at all, really".utf8)))
    }

    func testVarints() throws {
        var reader = PMTiles.VarintReader(Data([0x00, 0x7f, 0x80, 0x01, 0xac, 0x02]))
        XCTAssertEqual(try reader.next(), 0)
        XCTAssertEqual(try reader.next(), 127)
        XCTAssertEqual(try reader.next(), 128)
        XCTAssertEqual(try reader.next(), 300)
        XCTAssertThrowsError(try reader.next(), "nothing left")
    }
}
