import Foundation
import GRDB

/// House numbers, from the National Address Database on the CDN.
///
/// The US Department of Transportation compiles it from state and county
/// address programmes, so a point is the roof or the parcel rather than
/// the Census geocoder's estimate along the block, and it is public
/// domain. `scripts/build-addresses.py` writes one shard per 1° tile,
/// fetched for the tile under the map and kept under Caches, so an
/// address answers at keystroke speed with no signal once the file is
/// there. Coverage is by state participation, which is why the Census
/// geocoder stays behind this for what it lacks.
actor AddressIndex: Geocoder {
    private let files: IndexFiles

    init(base: URL, cache: URL) {
        files = IndexFiles(base: base, cache: cache)
    }

    /// Gets the shard a search near `near` will need, ahead of it.
    func prepare(near: Coordinate?) async {
        if let near { _ = await files.database(Self.shard(for: near)) }
    }

    func search(_ query: String, near: Coordinate?) async throws -> [SearchResult] {
        guard let address = AddressQuery.parse(query) else { return [] }
        // The tile under the map first, then every tile already on disk,
        // newest first, a dozen at most: the one under home answers while
        // the map is across the country, which no bias towards the map
        // could. On disk rather than merely open, so it holds in a fresh
        // session too.
        var shards: [(name: String, database: DatabaseQueue)] = []
        if let near {
            let under = Self.shard(for: near)
            if let database = await files.database(under) { shards.append((under, database)) }
        }
        for name in await files.onDisk(under: "tiles").prefix(12) where !shards.contains(where: { $0.name == name }) {
            if let database = await files.database(name) { shards.append((name, database)) }
        }
        var results: [SearchResult] = []
        for shard in shards {
            results += try await shard.database.read { db in
                try Self.search(db, address: address, near: near, limit: 6)
            }
        }
        return results
    }

    /// The matches in one shard: every street whose name holds the words
    /// typed, nearest the map first, and on each the number asked for.
    /// When no street has that number, the nearest numbers on the nearest
    /// street, so a typo or a gap in the data still lands on the right
    /// block, and the rider sees the number it actually is.
    static func search(_ db: Database, address: AddressQuery, near: Coordinate?, limit: Int) throws -> [SearchResult] {
        let ordering: String
        var arguments: StatementArguments = [address.match]
        if let near {
            let k = cos(near.lat * .pi / 180)
            ordering = "(s.lat - ?) * (s.lat - ?) + (s.lon - ?) * (s.lon - ?) * ?"
            arguments += [near.lat * 1e6, near.lat * 1e6, near.lon * 1e6, near.lon * 1e6, k * k]
        } else {
            ordering = "s.count DESC"
        }
        let streets = try Row.fetchAll(db, sql: """
            SELECT s.id, s.name, s.town, s.state FROM street_fts JOIN street s ON s.id = street_fts.rowid
            WHERE street_fts MATCH ? ORDER BY \(ordering) LIMIT 20
            """, arguments: arguments)

        var results: [SearchResult] = []
        for street in streets where results.count < limit {
            let rows = try Row.fetchAll(db, sql: """
                SELECT number, suffix, lat, lon, zip, placement FROM address WHERE street = ? AND number = ?
                """, arguments: [street["id"] as Int, address.number])
            results += rows.map { result(street: street, row: $0) }
        }
        if results.isEmpty, let street = streets.first {
            // The nearest number below and the nearest above, rather
            // than the two closest, which ties leave to chance.
            for (comparison, direction) in [("<=", "DESC"), (">", "ASC")] {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT number, suffix, lat, lon, zip, placement FROM address WHERE street = ? AND number \(comparison) ?
                    ORDER BY number \(direction), suffix LIMIT 1
                    """, arguments: [street["id"] as Int, address.number])
                results += rows.map { result(street: street, row: $0) }
            }
        }
        return results
    }

    private static func result(street: Row, row: Row) -> SearchResult {
        let number: Int = row["number"]
        let suffix: String = row["suffix"]
        let name: String = street["name"]
        let town: String = street["town"]
        let state: String = street["state"]
        var detail = "\(town), \(state)"
        if let zip = row["zip"] as Int? { detail += " \(String(format: "%05d", zip))" }
        if let placement = placements[row["placement"] as Int] { detail += " · \(placement)" }
        return SearchResult(name: "\(number)\(suffix) \(name)", detail: detail,
                            coordinate: Coordinate(lat: Double(row["lat"] as Int) / 1e6,
                                                   lon: Double(row["lon"] as Int) / 1e6),
                            kind: .address)
    }

    /// What the point marks, in the rider's words. The builder's codes.
    private static let placements: [Int: String] = [0: "Rooftop", 1: "Entrance", 2: "Parcel", 3: "Site", 4: "Street"]

    static let level = RoutingTiles.arterials

    static func shard(for coordinate: Coordinate) -> String {
        "tiles/\(RoutingTiles.id(of: coordinate, level: level)).sqlite"
    }
}

/// A house number and the words after it, ready to ask the index.
struct AddressQuery: Equatable {
    var number: Int
    /// The FTS5 expression over the street's name, town, state and zips:
    /// every word must match somewhere, the last one as a prefix. The
    /// words are the index's spelling, abbreviations written out.
    var match: String

    /// "472 n juniper st, orange" and nothing that does not start with a
    /// number followed by words. "472A" keeps the number and drops the
    /// letter, since the suffix is looked up by number and shown as it is.
    static func parse(_ text: String) -> AddressQuery? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.prefix { $0.isNumber }
        guard let number = Int(digits), number > 0 else { return nil }
        let street = PlaceIndex.streetQuery(for: trimmed).lowercased()
        guard street.contains(where: \.isLetter), let match = PlaceIndex.matchExpression(for: street) else { return nil }
        return AddressQuery(number: number, match: match)
    }
}
