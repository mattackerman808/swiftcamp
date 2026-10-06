import Foundation

/// A route's turns, as Valhalla narrates them: what BaseCamp lists on its
/// Directions tab and prints beside the map.
///
/// Computed, never stored. Garmin's format carries no instructions, the
/// device makes its own from the shape it is given, and the narrative
/// is a function of the route's points and settings, so a stored copy
/// could only go stale. `LibraryModel` keeps the last answer for each
/// route against the edit signature that produced it.
///
/// Lengths are metres and times seconds, like everything below the UI.
struct RouteDirections: Equatable, Sendable {
    struct Maneuver: Equatable, Sendable, Identifiable {
        var id: Int
        var kind: Kind
        /// Valhalla's sentence: "Turn right onto Peak to Peak Highway."
        var instruction: String
        var streetNames: [String]
        /// Along the road from this turn to the next.
        var length: Double
        var time: Double
        /// Along the road from the route's start to this turn.
        var distanceFromStart: Double
        /// Where the turn is, for the map to look at.
        var coordinate: Coordinate
        /// Which leg, counting via points, the turn is in.
        var leg: Int
    }

    /// Valhalla's maneuver types, the ones a touring route meets. The raw
    /// values are Valhalla's own, from `proto/directions.proto`, so the
    /// parser is a cast and an unknown one is `other`.
    enum Kind: Int, Equatable, Sendable {
        case none = 0
        case start = 1, startRight = 2, startLeft = 3
        case destination = 4, destinationRight = 5, destinationLeft = 6
        case becomes = 7, `continue` = 8
        case slightRight = 9, right = 10, sharpRight = 11
        case uturnRight = 12, uturnLeft = 13
        case sharpLeft = 14, left = 15, slightLeft = 16
        case rampStraight = 17, rampRight = 18, rampLeft = 19
        case exitRight = 20, exitLeft = 21
        case stayStraight = 22, stayRight = 23, stayLeft = 24
        case merge = 25
        case roundaboutEnter = 26, roundaboutExit = 27
        case ferryEnter = 28, ferryExit = 29
        case mergeRight = 37, mergeLeft = 38
        case other = -1

        /// An SF Symbol for the list.
        var symbol: String {
            switch self {
            case .start, .startRight, .startLeft: "mappin.circle"
            case .destination, .destinationRight, .destinationLeft: "flag.checkered"
            case .becomes, .continue, .stayStraight, .rampStraight, .none, .other: "arrow.up"
            case .slightRight, .stayRight, .rampRight, .exitRight: "arrow.up.right"
            case .slightLeft, .stayLeft, .rampLeft, .exitLeft: "arrow.up.left"
            case .right: "arrow.turn.up.right"
            case .left: "arrow.turn.up.left"
            case .sharpRight: "arrow.turn.right.down"
            case .sharpLeft: "arrow.turn.left.down"
            case .uturnRight: "arrow.uturn.right"
            case .uturnLeft: "arrow.uturn.left"
            case .merge, .mergeRight, .mergeLeft: "arrow.triangle.merge"
            case .roundaboutEnter, .roundaboutExit: "arrow.triangle.2.circlepath"
            case .ferryEnter, .ferryExit: "ferry"
            }
        }
    }

    var maneuvers: [Maneuver]
    var length: Double
    var time: Double

    /// Reads Valhalla's route reply, asked for with `directions_type`
    /// `instructions` and `units` `kilometers`.
    ///
    /// Each leg carries its own shape, and a maneuver names where it
    /// starts as an index into that shape, which is turned into a
    /// coordinate here so the list never has to hold the geometry.
    static func parse(_ json: [String: Any]) throws -> RouteDirections {
        guard let trip = json["trip"] as? [String: Any],
              let legs = trip["legs"] as? [[String: Any]],
              let summary = trip["summary"] as? [String: Any]
        else { throw RoutingError(message: "unexpected reply from the routing engine") }

        var maneuvers: [Maneuver] = []
        var travelled = 0.0
        for (legIndex, leg) in legs.enumerated() {
            let shape = Polyline.decode(leg["shape"] as? String ?? "")
            for raw in leg["maneuvers"] as? [[String: Any]] ?? [] {
                let index = raw["begin_shape_index"] as? Int ?? 0
                guard shape.indices.contains(index) else { continue }
                let length = ((raw["length"] as? Double) ?? 0) * 1000
                maneuvers.append(Maneuver(id: maneuvers.count,
                                          kind: Kind(rawValue: raw["type"] as? Int ?? 0) ?? .other,
                                          instruction: raw["instruction"] as? String ?? "",
                                          streetNames: raw["street_names"] as? [String] ?? [],
                                          length: length,
                                          time: (raw["time"] as? Double) ?? 0,
                                          distanceFromStart: travelled,
                                          coordinate: shape[index],
                                          leg: legIndex))
                travelled += length
            }
        }
        return RouteDirections(maneuvers: maneuvers,
                               length: ((summary["length"] as? Double) ?? 0) * 1000,
                               time: (summary["time"] as? Double) ?? 0)
    }
}
