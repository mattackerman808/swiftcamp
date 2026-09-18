import Foundation

/// Street addresses, from the US Census Bureau's geocoder.
///
/// Free, public domain, no key, and no terms about whose map the result
/// is shown on, which rules out the commercial APIs and Apple's. It knows
/// house numbers by interpolating along TIGER's block ranges, so a match
/// is on the right block and side of the street rather than on the roof.
/// It knows nothing else: a bare town or a road name returns no match, so
/// it is asked only when the query starts with a number, and it is slow
/// and online, which is why the static index comes first.
struct CensusGeocoder: Geocoder {
    func search(_ query: String, near: Coordinate?) async throws -> [SearchResult] {
        guard Self.looksLikeAddress(query) else { return [] }

        var components = URLComponents(string: "https://geocoding.geo.census.gov/geocoder/locations/onelineaddress")!
        components.queryItems = [
            URLQueryItem(name: "address", value: query),
            URLQueryItem(name: "benchmark", value: "Public_AR_Current"),
            URLQueryItem(name: "format", value: "json"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        var found = try Self.results(from: data)
        // Asked with only a state, Census answers with every town that
        // has the number on a street of that name. The one nearest the
        // map is the likeliest.
        if let near {
            let k = cos(near.lat * .pi / 180)
            func d(_ c: Coordinate) -> Double {
                (c.lat - near.lat) * (c.lat - near.lat) + (c.lon - near.lon) * (c.lon - near.lon) * k * k
            }
            found.sort { d($0.coordinate) < d($1.coordinate) }
        }
        return found
    }

    /// What to ask, in order, for a query that may not say where it is.
    ///
    /// Census parses generously: a town without its state, no commas at
    /// all, a street without its type, even a wrong state beside the
    /// right town. What it cannot do is search the country for a house
    /// number: "472 N Juniper" alone is nothing, and neither is it with
    /// "CA", where too many streets carry the name. So the query goes as
    /// typed first, because a town the rider did type must not have
    /// another appended; then with the map's town, since "1234 Main St"
    /// means the one here; then with the map's state, which finds it in
    /// the next town over. Each is asked only if the one before found
    /// nothing. An address anywhere else needs its town or zip, and the
    /// field says so.
    static func attempts(for query: String, near town: String?) -> [String] {
        guard looksLikeAddress(query), !namesAPlace(query), let town else { return [query] }
        var attempts = [query, "\(query), \(town)"]
        if let state = town.split(separator: ",").last.map({ $0.trimmingCharacters(in: .whitespaces) }),
           state != town {
            attempts.append("\(query), \(state)")
        }
        return attempts
    }

    /// A house number first, then words: what an address looks like and
    /// a place or a road does not.
    static func looksLikeAddress(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.first?.isNumber == true && trimmed.contains { $0.isLetter }
    }

    /// Whether the query already says where: a state at the end, or a
    /// zip. Census answers "1234 W Elkhorn Ave" with nothing and the same
    /// with a town or a zip with the address, so a query without either
    /// gets the town the map is looking at appended.
    static func namesAPlace(_ query: String) -> Bool {
        let words = query.uppercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        guard let last = words.last else { return false }
        if last.count == 5, last.allSatisfy(\.isNumber) { return true }
        if last.count == 2, states.contains(last) { return true }
        return false
    }

    private static let states: Set<String> = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA", "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA",
        "ME", "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY", "NC", "ND", "OH", "OK",
        "OR", "PA", "RI", "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY", "DC", "PR",
    ]

    static func results(from data: Data) throws -> [SearchResult] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.result.addressMatches.map { match in
            // "1234 W ELKHORN AVE, ESTES PARK, CO, 80517": the street on
            // the first line, the rest underneath, out of capitals.
            let parts = match.matchedAddress.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let name = titleCase(parts.first ?? match.matchedAddress)
            // A part that is two letters is the state and stays "CO".
            let detail = parts.dropFirst().map { $0.count == 2 ? $0 : titleCase($0) }.joined(separator: ", ")
            return SearchResult(name: name, detail: detail.isEmpty ? "Address" : detail,
                                coordinate: Coordinate(lat: match.coordinates.y, lon: match.coordinates.x),
                                kind: .address)
        }
    }

    /// Census shouts. Words are capitalised, "ST" to "St" and "ELKHORN"
    /// to "Elkhorn", except a direction, which stays "N" or "NE".
    private static func titleCase(_ text: String) -> String {
        text.split(separator: " ").map { word in
            word.count == 1 || compass.contains(String(word))
                ? String(word) : word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    private static let compass: Set<String> = ["NE", "NW", "SE", "SW"]

    private struct Response: Decodable {
        struct Result: Decodable {
            struct Match: Decodable {
                struct Point: Decodable { var x: Double; var y: Double }
                var matchedAddress: String
                var coordinates: Point
            }
            var addressMatches: [Match]
        }
        var result: Result
    }
}
