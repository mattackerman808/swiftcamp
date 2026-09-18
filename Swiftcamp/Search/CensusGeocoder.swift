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
        return try Self.results(from: data)
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
            let detail = parts.dropFirst().map(titleCase).joined(separator: ", ")
            return SearchResult(name: name, detail: detail.isEmpty ? "Address" : detail,
                                coordinate: Coordinate(lat: match.coordinates.y, lon: match.coordinates.x),
                                kind: .address)
        }
    }

    /// Census shouts. Words are capitalised, except a two-letter word,
    /// which is a state or a direction and stays as it was.
    private static func titleCase(_ text: String) -> String {
        text.split(separator: " ").map { word in
            word.count <= 2 ? String(word) : word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

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
