import XCTest
@testable import Swiftcamp

/// Valhalla's narrated reply into the list the inspector shows.
///
/// The reply is built by hand in the serializer's own shape, two legs
/// with a maneuver each plus the arrival, because the engine needs the
/// graph and a test must not. The shapes are Valhalla's 1e6 polylines.
final class RouteDirectionsTests: XCTestCase {
    private let reply: [String: Any] = [
        "trip": [
            "summary": ["length": 61.2, "time": 4500.0],
            "legs": [
                [
                    // Estes Park, two steps north-west.
                    "shape": "_vl_lAfapghE_q@veO_mV~oR",
                    "maneuvers": [
                        ["type": 1, "instruction": "Drive west on Elkhorn Avenue.",
                         "street_names": ["Elkhorn Avenue"], "length": 30.5, "time": 2000.0,
                         "begin_shape_index": 0],
                        ["type": 4, "instruction": "You have arrived at Camp.",
                         "length": 0.0, "time": 0.0, "begin_shape_index": 2],
                    ],
                ],
                [
                    "shape": "_ve`lA~xshhE_pR~oR_pR~oR",
                    "maneuvers": [
                        ["type": 10, "instruction": "Turn right onto Devils Gulch Road.",
                         "street_names": ["Devils Gulch Road"], "length": 30.7, "time": 2500.0,
                         "begin_shape_index": 1],
                        ["type": 4, "instruction": "You have arrived at your destination.",
                         "length": 0.0, "time": 0.0, "begin_shape_index": 2],
                    ],
                ],
            ],
        ],
    ]

    func testTurnsComeOutInOrderWithRoadDistances() throws {
        let directions = try RouteDirections.parse(reply)

        XCTAssertEqual(directions.length, 61_200, accuracy: 0.5, "kilometres become metres")
        XCTAssertEqual(directions.time, 4500)
        XCTAssertEqual(directions.maneuvers.map(\.instruction), [
            "Drive west on Elkhorn Avenue.",
            "You have arrived at Camp.",
            "Turn right onto Devils Gulch Road.",
            "You have arrived at your destination.",
        ])
        XCTAssertEqual(directions.maneuvers.map(\.kind), [.start, .destination, .right, .destination])
        XCTAssertEqual(directions.maneuvers.map(\.leg), [0, 0, 1, 1])
        XCTAssertEqual(directions.maneuvers.map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(directions.maneuvers[0].streetNames, ["Elkhorn Avenue"])
        XCTAssertEqual(directions.maneuvers[2].length, 30_700, accuracy: 0.5)
    }

    /// The distance beside each turn is from the route's start, across
    /// legs, which is what a rider reads against the trip meter.
    func testDistanceFromStartAccumulatesAcrossLegs() throws {
        let directions = try RouteDirections.parse(reply)
        XCTAssertEqual(directions.maneuvers.map { ($0.distanceFromStart / 100).rounded() * 100 },
                       [0, 30_500, 30_500, 61_200])
    }

    /// A turn's place on the map is read out of its leg's shape, so the
    /// list can look at a junction without holding the geometry.
    func testATurnKnowsWhereItIs() throws {
        let directions = try RouteDirections.parse(reply)
        XCTAssertEqual(directions.maneuvers[0].coordinate.lat, 40.3772, accuracy: 1e-6)
        XCTAssertEqual(directions.maneuvers[0].coordinate.lon, -105.5217, accuracy: 1e-6)
        XCTAssertEqual(directions.maneuvers[2].coordinate.lat, 40.4000, accuracy: 1e-6, "index 1 of the second leg")
        XCTAssertEqual(directions.maneuvers[3].coordinate.lon, -105.5600, accuracy: 1e-6)
    }

    func testAnUnknownManeuverTypeIsKeptAsOther() throws {
        var trip = reply["trip"] as! [String: Any]
        var legs = trip["legs"] as! [[String: Any]]
        legs[0]["maneuvers"] = [["type": 99, "instruction": "Teleport.", "begin_shape_index": 0]]
        trip["legs"] = legs
        let directions = try RouteDirections.parse(["trip": trip])
        XCTAssertEqual(directions.maneuvers.first?.kind, .other)
        XCTAssertEqual(directions.maneuvers.first?.instruction, "Teleport.")
        XCTAssertEqual(RouteDirections.Kind.other.symbol, "arrow.up", "and still has a picture")
    }

    func testAReplyWithoutATripIsAnError() {
        XCTAssertThrowsError(try RouteDirections.parse(["error": "No path could be found for input"]))
    }

    func testDurationsReadTheWayARiderSaysThem() {
        XCTAssertEqual(DirectionsPane.duration(20), "< 1 min")
        XCTAssertEqual(DirectionsPane.duration(18 * 60), "18 min")
        XCTAssertEqual(DirectionsPane.duration(2 * 3600), "2 h")
        XCTAssertEqual(DirectionsPane.duration(4 * 3600 + 12 * 60 + 20), "4 h 12 min")
    }
}
