import GRDB
import XCTest
@testable import Swiftcamp

/// Migrations and schema integrity.
///
/// tachbase has 55 append-only migrations and no test over any of them,
/// including one hand-written rebuild that moved 7,100 rows and one that
/// silently collapsed 4,400. Every assertion here is cheap, and it is the
/// gap in that precedent worth not repeating.
final class AppDatabaseTests: XCTestCase {
    /// Grows by one with every migration added. Asserting the exact number
    /// rather than "at least one" is what catches a migration accidentally
    /// deleted or renamed, which the append-only rule forbids and which
    /// nothing else would notice.
    private let migrationCount = 3

    private func makeLibrary() throws -> AppDatabase {
        try AppDatabase.inMemory()
    }

    // MARK: - Migrations

    func testFreshLibraryMigratesToTheCurrentSchema() throws {
        let db = try makeLibrary()
        XCTAssertEqual(try db.appliedMigrationCount(), migrationCount)

        let tables = ["lists", "waypoints", "tracks", "track_points", "routes", "route_points"]
        try db.writer.read { d in
            for table in tables {
                XCTAssertTrue(try d.tableExists(table), "missing table \(table)")
            }
        }
    }

    /// Every launch after the first re-runs the migrator over a file that is
    /// already migrated. On disk rather than in memory, because that is the
    /// only way to reopen the same database twice.
    func testReopeningAMigratedLibraryIsANoOp() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftcamp-test-\(UUID().uuidString)")
            .appendingPathComponent("library.sqlite")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = try AppDatabase(url: url)
        try first.writer.write { d in try insertRoute(d, id: "r1", name: "Trail Ridge") }
        XCTAssertEqual(try first.appliedMigrationCount(), migrationCount)

        let second = try AppDatabase(url: url)
        XCTAssertEqual(try second.appliedMigrationCount(), migrationCount,
                       "migrations must not re-apply")

        let names = try second.writer.read { d in
            try String.fetchAll(d, sql: "SELECT name FROM routes")
        }
        XCTAssertEqual(names, ["Trail Ridge"], "reopening must not disturb existing rows")
    }

    // MARK: - Cascades

    /// The behaviour every cascade in the schema depends on. SQLite defaults
    /// foreign keys off, so without the pragma in `Configuration` these rules
    /// are decoration and the two tests below would both pass for the wrong
    /// reason.
    func testForeignKeysAreEnforced() throws {
        let db = try makeLibrary()
        XCTAssertThrowsError(try db.writer.write { d in
            try d.execute(sql: """
                INSERT INTO route_points (route_id, seq, lat, lon, is_via)
                VALUES ('no-such-route', 0, 40.0, -105.0, 1)
                """)
        })
    }

    func testDeletingARouteDeletesItsPoints() throws {
        let db = try makeLibrary()
        try db.writer.write { d in
            try insertRoute(d, id: "r1", name: "Trail Ridge")
            try insertRoutePoint(d, routeID: "r1", seq: 0, lat: 40.37, lon: -105.52)
            try insertRoutePoint(d, routeID: "r1", seq: 1, lat: 40.44, lon: -105.75)
        }

        try db.writer.write { d in try d.execute(sql: "DELETE FROM routes WHERE id = 'r1'") }

        let remaining = try db.writer.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM route_points") ?? -1
        }
        XCTAssertEqual(remaining, 0)
    }

    /// Deleting a folder must not destroy what was filed in it. BaseCamp
    /// drops those items back to the top of the collection, and a cascade
    /// here would turn tidying up into data loss.
    func testDeletingAListKeepsItsRoutes() throws {
        let db = try makeLibrary()
        try db.writer.write { d in
            try d.execute(sql: """
                INSERT INTO lists (id, name, sort_order, created_at, updated_at)
                VALUES ('l1', 'Colorado 2026', 0, '2026-09-11', '2026-09-11')
                """)
            try insertRoute(d, id: "r1", name: "Trail Ridge", listID: "l1")
        }

        try db.writer.write { d in try d.execute(sql: "DELETE FROM lists WHERE id = 'l1'") }

        let listID = try db.writer.read { d in
            try Optional<String>.fetchOne(d, sql: "SELECT list_id FROM routes WHERE id = 'r1'") ?? nil
        }
        let count = try db.writer.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM routes") ?? -1
        }
        XCTAssertEqual(count, 1, "the route should survive its folder")
        XCTAssertNil(listID, "and should be unfiled")
    }

    // MARK: - Ordering

    func testRoutePointSequenceIsUnique() throws {
        let db = try makeLibrary()
        try db.writer.write { d in
            try insertRoute(d, id: "r1", name: "Trail Ridge")
            try insertRoutePoint(d, routeID: "r1", seq: 0, lat: 40.37, lon: -105.52)
        }

        XCTAssertThrowsError(try db.writer.write { d in
            try insertRoutePoint(d, routeID: "r1", seq: 0, lat: 41.0, lon: -106.0)
        })
    }

    /// Two routes each owning a point at position zero is the normal case,
    /// and a unique index on `seq` alone would forbid it.
    func testSequenceIsUniquePerRouteNotGlobally() throws {
        let db = try makeLibrary()
        try db.writer.write { d in
            try insertRoute(d, id: "r1", name: "Trail Ridge")
            try insertRoute(d, id: "r2", name: "Peak to Peak")
            try insertRoutePoint(d, routeID: "r1", seq: 0, lat: 40.37, lon: -105.52)
            try insertRoutePoint(d, routeID: "r2", seq: 0, lat: 39.95, lon: -105.50)
        }

        let count = try db.writer.read { d in
            try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM route_points") ?? -1
        }
        XCTAssertEqual(count, 2)
    }

    // MARK: - Helpers

    private func insertRoute(_ d: Database, id: String, name: String, listID: String? = nil) throws {
        try d.execute(sql: """
            INSERT INTO routes (id, list_id, name, created_at, updated_at)
            VALUES (?, ?, ?, '2026-09-11', '2026-09-11')
            """, arguments: [id, listID, name])
    }

    private func insertRoutePoint(_ d: Database, routeID: String, seq: Int,
                                  lat: Double, lon: Double) throws {
        try d.execute(sql: """
            INSERT INTO route_points (route_id, seq, lat, lon, is_via)
            VALUES (?, ?, ?, ?, 1)
            """, arguments: [routeID, seq, lat, lon])
    }
}
