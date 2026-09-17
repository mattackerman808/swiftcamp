import XCTest
@testable import Swiftcamp

/// The tile grid and file layout, pinned against ids the engine was seen
/// to fetch for real places, so the prefetcher names exactly the files
/// the engine will look for.
final class RoutingTilesTests: XCTestCase {
    private let estesPark = Coordinate(lat: 40.3772, lon: -105.5217)

    func testIdsMatchWhatTheEngineFetchedForEstesPark() {
        XCTAssertEqual(RoutingTiles.id(of: estesPark, level: RoutingTiles.local), 750537)
        XCTAssertEqual(RoutingTiles.id(of: estesPark, level: RoutingTiles.arterials), 46874)
        XCTAssertEqual(RoutingTiles.id(of: estesPark, level: RoutingTiles.highways), 2898)
    }

    /// Zero-padded to a multiple of three digits per level, split in threes.
    func testPathsMatchTheEnginesFileLayout() {
        XCTAssertEqual(RoutingTiles.path(level: RoutingTiles.highways, id: 2898), "0/002/898")
        XCTAssertEqual(RoutingTiles.path(level: RoutingTiles.arterials, id: 46874), "1/046/874")
        XCTAssertEqual(RoutingTiles.path(level: RoutingTiles.local, id: 750537), "2/000/750/537")
    }

    func testABoxCoversTheTilesItTouchesAndNoMore() {
        // A quarter-degree box straddling one tile corner touches four tiles.
        let box = BoundingBox(west: -105.6, south: 40.4, east: -105.4, north: 40.6)
        let ids = RoutingTiles.ids(in: box, level: RoutingTiles.local)
        XCTAssertEqual(ids.count, 4)
        XCTAssertTrue(ids.contains(RoutingTiles.id(of: Coordinate(lat: 40.4, lon: -105.6), level: RoutingTiles.local)))
        XCTAssertTrue(ids.contains(RoutingTiles.id(of: Coordinate(lat: 40.6, lon: -105.4), level: RoutingTiles.local)))
    }

    func testABoxInsideOneTileIsThatTile() {
        let box = BoundingBox(west: -105.52, south: 40.37, east: -105.51, north: 40.38)
        XCTAssertEqual(RoutingTiles.ids(in: box, level: RoutingTiles.local), [750537])
    }
}
