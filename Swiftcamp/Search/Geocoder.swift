import Foundation

/// A place a search can land on.
struct SearchResult: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case coordinate, address, place, street, poi
    }

    var name: String
    /// The line under the name: a town and state, or where the answer
    /// came from.
    var detail: String
    var coordinate: Coordinate
    var kind: Kind

    var id: String { "\(kind.rawValue)|\(name)|\(coordinate.lat),\(coordinate.lon)" }
}

/// Somewhere a query can be sent.
///
/// A protocol so the sources can change under the field: today a parser
/// for coordinates and the US Census geocoder for street addresses; next
/// the static index of places, streets and points of interest on the CDN,
/// which needs no network once fetched. `near` biases ranking towards
/// where the map is looking, for sources that can.
protocol Geocoder: Sendable {
    func search(_ query: String, near: Coordinate?) async throws -> [SearchResult]
}
