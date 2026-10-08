import Foundation

/// What a rider looks for near a stop or along a route: BaseCamp's Find
/// Near, cut to the kinds our index carries. Each is a few of the index's
/// kinds, as `scripts/build-search.py` names them.
enum NearbyCategory: String, CaseIterable, Sendable {
    case fuel, food, lodging, camping, motorcycle, groceries, medical, charging, sights

    var title: String {
        switch self {
        case .fuel: "Fuel"
        case .food: "Food"
        case .lodging: "Lodging"
        case .camping: "Camping"
        case .motorcycle: "Motorcycle Shops"
        case .groceries: "Groceries"
        case .medical: "Hospitals & Pharmacies"
        case .charging: "EV Charging"
        case .sights: "Sights"
        }
    }

    var kinds: Set<String> {
        switch self {
        case .fuel: ["fuel"]
        case .food: ["restaurant", "cafe", "fast_food", "pub", "bar"]
        case .lodging: ["hotel", "motel", "guest_house", "hostel"]
        case .camping: ["camp_site", "caravan_site"]
        case .motorcycle: ["motorcycle", "motorcycle_repair"]
        case .groceries: ["supermarket", "convenience"]
        case .medical: ["hospital", "pharmacy"]
        case .charging: ["charging_station"]
        case .sights: ["viewpoint", "attraction", "peak", "pass", "information"]
        }
    }
}

/// One thing found, and where it lies against what it was found near:
/// how far off the line, and how far along it.
struct NearbyHit: Identifiable, Hashable, Sendable {
    var result: SearchResult
    /// Metres from the point, or from the nearest part of the route.
    var offset: Double
    /// Metres from the route's start to where it passes nearest; zero
    /// for a single point.
    var along: Double

    var id: String { result.id }
}

/// The geometry of a corridor search, apart from the index, so it can be
/// tested without one.
///
/// A cross-country route is twenty thousand vertices and its corridor
/// holds tens of thousands of fuel stations, so the distance from each to
/// every segment is out of the question. The route is resampled to a
/// station every `spacing` metres instead, the stations hashed into a grid
/// of cells about as wide as the corridor, and each candidate measured
/// against the stations in its own cell and its neighbours. The nearest
/// station is within half a spacing of the nearest point on the line,
/// which is well inside what "two miles off the route" means.
struct Corridor: Sendable {
    struct Station: Sendable {
        var coordinate: Coordinate
        var along: Double
    }

    let stations: [Station]
    let radius: Double
    private let cell: Double
    private var grid: [Key: [Int]] = [:]

    private struct Key: Hashable { var x: Int, y: Int }

    static let spacing = 400.0

    init(path: [Coordinate], radius: Double) {
        self.radius = radius
        var stations: [Station] = []
        if let first = path.first {
            stations.append(Station(coordinate: first, along: 0))
            var travelled = 0.0
            for (a, b) in zip(path, path.dropFirst()) {
                let leg = GeoMath.distance(a, b)
                guard leg > 0 else { continue }
                let steps = Int((leg / Self.spacing).rounded(.up))
                for step in 1...steps {
                    let t = Double(step) / Double(steps)
                    let lat: Double = a.lat + (b.lat - a.lat) * t
                    let lon: Double = a.lon + (b.lon - a.lon) * t
                    stations.append(Station(coordinate: Coordinate(lat: lat, lon: lon), along: travelled + leg * t))
                }
                travelled += leg
            }
        }
        self.stations = stations
        // Degrees of latitude for the radius; longitude cells are widened
        // by the cosine at each station, so the grid is in "metres" both ways.
        cell = max(radius, Self.spacing) / 111_195.0
        for (i, station) in stations.enumerated() {
            grid[key(station.coordinate), default: []].append(i)
        }
    }

    private func key(_ c: Coordinate) -> Key {
        let k = cos(c.lat * .pi / 180)
        return Key(x: Int((c.lon * k / cell).rounded(.down)), y: Int((c.lat / cell).rounded(.down)))
    }

    /// The nearest station to a spot within the radius, or nil.
    func nearest(to c: Coordinate) -> Station? {
        let center = key(c)
        var best: (Station, Double)?
        for dx in -1...1 {
            for dy in -1...1 {
                for i in grid[Key(x: center.x + dx, y: center.y + dy)] ?? [] {
                    let d = GeoMath.distance(c, stations[i].coordinate)
                    if d <= radius, best == nil || d < best!.1 { best = (stations[i], d) }
                }
            }
        }
        return best?.0
    }

    /// Spots a corridor's index files are keyed by: every station, and a
    /// radius north, south, east and west of it, so a cell boundary just
    /// off the line still has its far side searched.
    var reach: [Coordinate] {
        let dLat = radius / 111_195.0
        return stations.flatMap { s -> [Coordinate] in
            let dLon = dLat / max(0.1, cos(s.coordinate.lat * .pi / 180))
            let c = s.coordinate
            return [c, Coordinate(lat: c.lat + dLat, lon: c.lon), Coordinate(lat: c.lat - dLat, lon: c.lon),
                    Coordinate(lat: c.lat, lon: c.lon + dLon), Coordinate(lat: c.lat, lon: c.lon - dLon)]
        }
    }
}
