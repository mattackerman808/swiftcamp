import XCTest
import GRDB
@testable import Swiftcamp

/// The query the address index is asked, and what it answers, over a
/// shard in the builder's own schema.
final class AddressIndexTests: XCTestCase {
    private func shard() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE street (id INTEGER PRIMARY KEY, name TEXT NOT NULL, town TEXT NOT NULL, state TEXT NOT NULL,
                                     zips TEXT NOT NULL, search TEXT NOT NULL, lat INTEGER NOT NULL, lon INTEGER NOT NULL,
                                     count INTEGER NOT NULL);
                CREATE VIRTUAL TABLE street_fts USING fts5(search, town, state, zips, content='street', content_rowid='id',
                                                           tokenize='unicode61 remove_diacritics 2');
                CREATE TABLE address (street INTEGER NOT NULL, number INTEGER NOT NULL, suffix TEXT NOT NULL,
                                      lat INTEGER NOT NULL, lon INTEGER NOT NULL, zip INTEGER, placement INTEGER NOT NULL,
                                      PRIMARY KEY (street, number, suffix)) WITHOUT ROWID;
                INSERT INTO street VALUES (1, 'North Juniper Street', 'Orange', 'CA', '92866 92867', 'north juniper street', 33790000, -117850000, 3);
                INSERT INTO street VALUES (2, 'North Juniper Street', 'La Habra', 'CA', '90631', 'north juniper street', 33930000, -117950000, 1);
                INSERT INTO street VALUES (3, 'Juniper Avenue', 'Orange', 'CA', '92866', 'juniper avenue', 33780000, -117860000, 1);
                INSERT INTO address VALUES (1, 470, '', 33790100, -117850100, 92866, 0);
                INSERT INTO address VALUES (1, 472, '', 33790200, -117850200, 92866, 0);
                INSERT INTO address VALUES (1, 472, 'A', 33790250, -117850250, 92866, 2);
                INSERT INTO address VALUES (1, 476, '', 33790300, -117850300, 92867, 4);
                INSERT INTO address VALUES (2, 472, '', 33930100, -117950100, 90631, 0);
                INSERT INTO address VALUES (3, 472, '', 33780100, -117860100, 92866, 2);
                INSERT INTO street_fts(street_fts) VALUES ('rebuild');
                """)
        }
        return db
    }

    func testAnAddressIsANumberAndTheStreetInTheIndexSpelling() {
        XCTAssertEqual(AddressQuery.parse("472 n juniper st"), AddressQuery(number: 472, match: "\"north\" \"juniper\" \"street\"*"))
        XCTAssertEqual(AddressQuery.parse("472A N Juniper")?.number, 472)
        XCTAssertNil(AddressQuery.parse("n juniper st"), "no number")
        XCTAssertNil(AddressQuery.parse("472"), "no street")
        XCTAssertNil(AddressQuery.parse("40.3772, -105.5217"), "coordinates")
    }

    func testTheNumberOnTheNearestStreetOfThatNameComesFirst() throws {
        let db = try shard()
        let orange = Coordinate(lat: 33.79, lon: -117.85)
        let results = try db.read { db in
            try AddressIndex.search(db, address: AddressQuery.parse("472 n juniper")!, near: orange, limit: 6)
        }
        XCTAssertEqual(results.map(\.name), ["472 North Juniper Street", "472A North Juniper Street", "472 North Juniper Street"])
        XCTAssertEqual(results.first?.detail, "Orange, CA 92866 · Rooftop")
        XCTAssertEqual(results.last?.detail, "La Habra, CA 90631 · Rooftop")
        XCTAssertEqual(results.first?.coordinate.lat ?? 0, 33.7902, accuracy: 1e-6)
    }

    func testATownNarrowsIt() throws {
        let db = try shard()
        let results = try db.read { db in
            try AddressIndex.search(db, address: AddressQuery.parse("472 n juniper, la habra")!, near: nil, limit: 6)
        }
        XCTAssertEqual(results.map(\.detail), ["La Habra, CA 90631 · Rooftop"])
    }

    func testAMissingNumberGivesItsNeighbours() throws {
        let db = try shard()
        let results = try db.read { db in
            try AddressIndex.search(db, address: AddressQuery.parse("474 n juniper st")!, near: Coordinate(lat: 33.79, lon: -117.85), limit: 6)
        }
        // Nearest numbers on the nearest street, and the rider sees what
        // they really are, with the parcel point marked as such.
        XCTAssertEqual(results.map(\.name), ["472 North Juniper Street", "476 North Juniper Street"])
        XCTAssertEqual(results.last?.detail, "Orange, CA 92867 · Street")
    }

    func testTheShardIsTheOneDegreeTileUnderThePoint() {
        // Orange, CA: row 123 (33.79 + 90), column 62 (-117.85 + 180).
        XCTAssertEqual(AddressIndex.shard(for: Coordinate(lat: 33.79, lon: -117.85)), "tiles/\(123 * 360 + 62).sqlite")
    }
}
