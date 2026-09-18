import Foundation
import GRDB

/// Places, streets and points of interest from our own index on the CDN.
///
/// `scripts/build-search.py` writes it from the same OSM extract the
/// routing graph is built from: one national `places.sqlite`, small enough
/// to always have, and one shard per 4° cell of streets and points of
/// interest, fetched for the cell under the map when a search needs it
/// and kept under Caches. Each is a SQLite file with an FTS5 index, so a
/// search is a local query and works on the road with no signal once the
/// files are there. Nothing is metered and nobody's terms apply, which is
/// why this source comes before the Census geocoder.
actor PlaceIndex: Geocoder {
    private let files: IndexFiles

    init(base: URL, cache: URL) {
        files = IndexFiles(base: base, cache: cache)
    }

    /// Gets the files a search near `near` will need, ahead of it. Called
    /// as the map moves, so the first search in an area does not wait.
    func prepare(near: Coordinate?) async {
        _ = await files.database("places.sqlite")
        if let near {
            _ = await files.database(Self.shard(for: near))
        }
    }

    func search(_ query: String, near: Coordinate?) async throws -> [SearchResult] {
        guard let match = Self.matchExpression(for: query) else { return [] }
        var results: [SearchResult] = []

        if let places = await files.database("places.sqlite") {
            results += try await places.read { db in
                try Self.search(db, query: query, match: match, near: near, limit: 6, order: .importance)
            }
        }
        if let near, let cell = await files.database(Self.shard(for: near)) {
            results += try await cell.read { db in
                try Self.search(db, query: query, match: match, near: near, limit: 14, order: .distance)
            }
        }
        return results
    }

    /// What comes first among matches. Places by importance: Estes Park
    /// before five hamlets called Estes. Streets and points of interest
    /// by distance: the shard is a 440 km cell and the nearest Main
    /// Street is the one meant.
    enum Order { case importance, distance }

    /// Metres within which a place counts as local for ranking.
    static let nearby = 300_000.0

    /// The town nearest a point, as "Estes Park, CO", for completing an
    /// address typed without one.
    func nearestTown(to coordinate: Coordinate) async -> String? {
        guard let places = await files.database("places.sqlite") else { return nil }
        let k = cos(coordinate.lat * .pi / 180)
        return try? await places.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT name, detail FROM feature WHERE kind IN ('city', 'town', 'village')
                ORDER BY (lat - ?) * (lat - ?) + (lon - ?) * (lon - ?) * ? LIMIT 1
                """, arguments: [coordinate.lat, coordinate.lat, coordinate.lon, coordinate.lon, k * k])
            guard let row else { return nil }
            // The detail is "Town, CO": the state is what follows the comma.
            let detail: String = row["detail"]
            let state = detail.split(separator: ",").last?.trimmingCharacters(in: .whitespaces) ?? ""
            let name: String = row["name"]
            return state.isEmpty ? name : "\(name), \(state)"
        }
    }

    // MARK: - Querying

    /// An address as the index spells streets: the house number dropped,
    /// since no street carries one and a word that matches nothing
    /// empties the result, and the abbreviations Census takes written
    /// out, since OSM names the road "North Juniper Street" and
    /// "n juniper st" matches none of its words. Only for a query shaped
    /// like an address; "St Louis" is a place, not a street.
    static func streetQuery(for query: String) -> String {
        var words = query.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map { String($0) }
        if words.first?.first?.isNumber == true { words.removeFirst() }
        return words.map { expansions[$0.lowercased()] ?? $0 }.joined(separator: " ")
    }

    private static let expansions: [String: String] = [
        "n": "north", "s": "south", "e": "east", "w": "west",
        "ne": "northeast", "nw": "northwest", "se": "southeast", "sw": "southwest",
        "st": "street", "ave": "avenue", "av": "avenue", "blvd": "boulevard", "dr": "drive",
        "rd": "road", "ln": "lane", "ct": "court", "pl": "place", "cir": "circle",
        "hwy": "highway", "pkwy": "parkway", "ter": "terrace", "trl": "trail",
    ]

    /// The FTS5 expression for what was typed: every word must match, and
    /// the last one may be the start of a word, since the user is still
    /// typing it. Quoted, so punctuation in a name is a character and not
    /// syntax.
    static func matchExpression(for query: String) -> String? {
        let words = query.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map { String($0) }
        guard !words.isEmpty else { return nil }
        let quoted = words.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return quoted.dropLast().joined(separator: " ") + (quoted.count > 1 ? " " : "") + quoted.last! + "*"
    }

    /// The matches, best first.
    ///
    /// FTS5 finds them, with a hit in the name worth ten of a hit in the
    /// detail, since "estes park" is a town before it is every shop in
    /// it. Its own ranking is not the order, though: it likes short
    /// names, so a hamlet called Estes beats Estes Park. A match whose
    /// name holds every word typed comes before one that matched on its
    /// detail; within that, the order asked for, then FTS5's score.
    static func search(_ db: Database, query: String, match: String, near: Coordinate?,
                       limit: Int, order: Order) throws -> [SearchResult] {
        // The database narrows to two hundred candidates in the order
        // asked for, not in text order: a cell holds 1,300 fuel stations
        // and "fuel" matches every one of them equally, so text order
        // is an arbitrary two hundred that need not include the one
        // across the street.
        let ordering: String
        var arguments: StatementArguments = [match]
        switch (order, near) {
        case (.distance, let near?):
            let k = cos(near.lat * .pi / 180)
            ordering = "(f.lat - ?) * (f.lat - ?) + (f.lon - ?) * (f.lon - ?) * ?"
            arguments += [near.lat, near.lat, near.lon, near.lon, k * k]
        default:
            ordering = "f.rank DESC, score"
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT f.kind, f.name, f.detail, f.lat, f.lon, f.rank, bm25(feature_fts, 10.0, 1.0) AS score
            FROM feature_fts JOIN feature f ON f.id = feature_fts.rowid
            WHERE feature_fts MATCH ?
            ORDER BY \(ordering)
            LIMIT 200
            """, arguments: arguments)
        let words = query.lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)

        struct Candidate {
            var result: SearchResult
            var nameMatches: Bool
            var rank: Int
            var distance: Double
            var score: Double
        }
        var candidates = rows.map { row -> Candidate in
            let name: String = row["name"]
            let coordinate = Coordinate(lat: row["lat"], lon: row["lon"])
            let kind: SearchResult.Kind = switch row["kind"] as String {
            case "street": .street
            case "city", "town", "village", "hamlet", "suburb", "locality", "neighbourhood": .place
            default: .poi
            }
            // The kind's label counts as part of the name, so "fuel" finds
            // every fuel station by distance rather than the one shop
            // with Fuel in its sign.
            let detail: String = row["detail"]
            let label = detail.split(separator: "·").first.map(String.init) ?? ""
            let nameWords = (name + " " + label).lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            let nameMatches = words.allSatisfy { word in nameWords.contains { $0.hasPrefix(word) } }
            return Candidate(result: SearchResult(name: name, detail: detail, coordinate: coordinate, kind: kind),
                             nameMatches: nameMatches, rank: row["rank"],
                             distance: near.map { GeoMath.distance($0, coordinate) } ?? 0,
                             score: row["score"])
        }
        candidates.sort { a, b in
            if a.nameMatches != b.nameMatches { return a.nameMatches }
            switch order {
            case .importance:
                // A place within a few hours' ride outranks a bigger one
                // across the country: "Estes" in Colorado means Estes
                // Park, not a neighbourhood in Texas of the same size.
                let aNear = a.distance < Self.nearby, bNear = b.distance < Self.nearby
                if aNear != bNear { return aNear }
                if a.rank != b.rank { return a.rank > b.rank }
                if a.distance != b.distance { return a.distance < b.distance }
            case .distance:
                if a.distance != b.distance { return a.distance < b.distance }
                if a.rank != b.rank { return a.rank > b.rank }
            }
            return a.score < b.score
        }
        return Array(candidates.prefix(limit).map(\.result))
    }

    // MARK: - Files

    static func shard(for coordinate: Coordinate) -> String {
        "cells/\(RoutingTiles.id(of: coordinate, level: RoutingTiles.highways)).sqlite"
    }

}
