import XCTest
import GRDB
@testable import Swiftcamp

/// The query the index is asked, and the order its answers come back in,
/// over a database in the builder's own schema.
final class PlaceIndexTests: XCTestCase {
    private func database() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE feature (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, detail TEXT NOT NULL,
                                      lat REAL NOT NULL, lon REAL NOT NULL, rank INTEGER NOT NULL DEFAULT 0);
                CREATE VIRTUAL TABLE feature_fts USING fts5(name, detail, content='feature', content_rowid='id',
                                                            tokenize='unicode61 remove_diacritics 2');
                """)
            let rows: [(String, String, String, Double, Double, Int)] = [
                ("town", "Estes Park", "Town, CO", 40.3772, -105.5217, 5900),
                ("hamlet", "Estes", "Hamlet, MN", 46.0, -94.0, 0),
                ("street", "Main Street", "Street · Estes Park, CO", 40.377, -105.52, 12),
                ("street", "Main Street", "Street · Lyons, CO", 40.224, -105.271, 30),
                ("fuel", "Shell", "Fuel · Estes Park, CO", 40.376, -105.523, 0),
                ("cafe", "Kind Coffee", "Café · Estes Park, CO", 40.377, -105.519, 0),
            ]
            for row in rows {
                try db.execute(sql: "INSERT INTO feature(kind, name, detail, lat, lon, rank) VALUES (?,?,?,?,?,?)",
                               arguments: [row.0, row.1, row.2, row.3, row.4, row.5])
            }
            try db.execute(sql: "INSERT INTO feature_fts(feature_fts) VALUES ('rebuild')")
        }
        return db
    }

    func testEveryWordMustMatchAndTheLastMayBeAPrefix() {
        XCTAssertEqual(PlaceIndex.matchExpression(for: "estes"), "\"estes\"*")
        XCTAssertEqual(PlaceIndex.matchExpression(for: "estes par"), "\"estes\" \"par\"*")
        XCTAssertEqual(PlaceIndex.matchExpression(for: "Lyons, CO"), "\"Lyons\" \"CO\"*")
        XCTAssertEqual(PlaceIndex.matchExpression(for: "O\"Neil"), "\"O\"\"Neil\"*")
        XCTAssertNil(PlaceIndex.matchExpression(for: "   "))
    }

    private func search(_ db: DatabaseQueue, _ query: String, near: Coordinate? = nil,
                        order: PlaceIndex.Order) throws -> [SearchResult] {
        try db.read {
            try PlaceIndex.search($0, query: query, match: PlaceIndex.matchExpression(for: query)!,
                                  near: near, limit: 10, order: order)
        }
    }

    /// A town outranks the hamlets that share its first word, and the
    /// shops and streets that carry its name in their detail come after
    /// anything that carries it in the name.
    func testThePlaceComesBeforeTheThingsNamedForIt() throws {
        let db = try database()
        let results = try search(db, "est", order: .importance)
        XCTAssertEqual(results.map(\.name).prefix(2), ["Estes Park", "Estes"])
        XCTAssertEqual(Set(results.map(\.name)), ["Estes Park", "Estes", "Main Street", "Shell", "Kind Coffee"],
                       "the detail is searched too, so a town's streets and shops answer to its name")
        XCTAssertEqual(results.first?.kind, .place)
    }

    /// Two Main Streets: the nearer one first, not the one FTS5 prefers.
    func testTheNearerOfTwoSameNamedStreetsComesFirst() throws {
        let db = try database()
        let nearEstes = Coordinate(lat: 40.38, lon: -105.52)
        let results = try search(db, "main st", near: nearEstes, order: .distance)
        XCTAssertEqual(results.map(\.detail), ["Street · Estes Park, CO", "Street · Lyons, CO"])
        XCTAssertEqual(results.first?.kind, .street)
    }

    /// A category word is answered by kind and distance, not by whoever
    /// put the word on their sign.
    func testACategoryFindsTheNearestOfItsKind() throws {
        let db = try database()
        try db.write { db in
            try db.execute(sql: "INSERT INTO feature(kind, name, detail, lat, lon, rank) VALUES (?,?,?,?,?,?)",
                           arguments: ["convenience", "Food & Fuel", "Convenience store · Lyons, CO", 40.224, -105.27, 0])
            try db.execute(sql: "INSERT INTO feature_fts(feature_fts) VALUES ('rebuild')")
        }
        let results = try search(db, "fuel", near: Coordinate(lat: 40.38, lon: -105.52), order: .distance)
        XCTAssertEqual(results.map(\.name), ["Shell", "Food & Fuel"])
    }

    func testAccentsDoNotMatter() throws {
        let db = try database()
        let results = try search(db, "cafe", order: .distance)
        XCTAssertEqual(results.map(\.name), ["Kind Coffee"], "Café in the detail matches cafe")
        XCTAssertEqual(results.first?.kind, .poi)
    }

    func testAnAddressIsSearchedAsTheStreetTheIndexSpells() {
        XCTAssertEqual(PlaceIndex.streetQuery(for: "472 n juniper st"), "north juniper street")
        XCTAssertEqual(PlaceIndex.streetQuery(for: "1234 W Elkhorn Ave"), "west Elkhorn avenue")
        XCTAssertEqual(PlaceIndex.streetQuery(for: "472 Juniper"), "Juniper")
        XCTAssertEqual(PlaceIndex.streetQuery(for: "472"), "")
    }

    func testTheShardIsTheHighwayCellUnderThePoint() {
        XCTAssertEqual(PlaceIndex.shard(for: Coordinate(lat: 40.3772, lon: -105.5217)), "cells/2898.sqlite")
    }
}
