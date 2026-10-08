import XCTest
@testable import Swiftcamp

/// What a route's mode and preferences become in Valhalla's request. The
/// numbers are the ones measured in docs/routing.md; a change here changes
/// where riders are sent.
final class RoutingOptionsTests: XCTestCase {
    func testRoadAndAdventureDifferOnSurfaces() {
        let road = RoutingEngine.costingOptions(for: .road, preferences: RoutePreferences())
        XCTAssertEqual(road["exclude_unpaved"] as? Bool, true)
        XCTAssertNil(road["use_highways"])
        XCTAssertNil(road["shortest"])
        XCTAssertNil(road["use_curvature"])

        let adventure = RoutingEngine.costingOptions(for: .adventure, preferences: RoutePreferences())
        XCTAssertEqual(adventure["exclude_unpaved"] as? Bool, false)
        XCTAssertEqual(adventure["use_tracks"] as? Int, 1)
        XCTAssertTrue(RoutingEngine.costingOptions(for: .direct, preferences: RoutePreferences()).isEmpty)
    }

    func testAvoidancesAreTheOptionAtZero() {
        var prefs = RoutePreferences()
        prefs.avoidHighways = true
        prefs.avoidTolls = true
        prefs.avoidFerries = true
        let options = RoutingEngine.costingOptions(for: .road, preferences: prefs)
        XCTAssertEqual(options["use_highways"] as? Int, 0)
        XCTAssertEqual(options["use_tolls"] as? Int, 0)
        XCTAssertEqual(options["use_ferry"] as? Int, 0)
    }

    func testPreferenceIsShortestOrCurvature() {
        var prefs = RoutePreferences()
        prefs.prefer = .shorterDistance
        XCTAssertEqual(RoutingEngine.costingOptions(for: .road, preferences: prefs)["shortest"] as? Bool, true)

        prefs.prefer = .someCurves
        XCTAssertEqual(RoutingEngine.costingOptions(for: .road, preferences: prefs)["use_curvature"] as? Double, 0.4)
        prefs.prefer = .manyCurves
        XCTAssertEqual(RoutingEngine.costingOptions(for: .road, preferences: prefs)["use_curvature"] as? Double, 1)
        XCTAssertNil(RoutingEngine.costingOptions(for: .road, preferences: prefs)["shortest"])
    }

    func testGarminWordsAndKeys() {
        XCTAssertEqual(RoutePreferences.Preference.someCurves.garminCalculationMode, "CurvyRoads")
        XCTAssertEqual(RoutePreferences.Preference.manyCurves.garminCalculationMode, "CurvyRoads")
        var prefs = RoutePreferences()
        prefs.setAvoided(["ferries", "highways", "bridges"])
        XCTAssertEqual(prefs.avoided, ["highways", "ferries"])
        var route = Route(name: "Loop", mode: .adventure, preferences: prefs)
        let key = route.routingKey
        route.preferences.avoidTolls = true
        XCTAssertNotEqual(route.routingKey, key, "a refused leg is remembered against the settings that refused it")
    }

    /// Driving is the car costing on the road mode's surfaces, and walking
    /// the pedestrian costing with trails up to demanding hiking; neither
    /// is sent a curvature the motorcycle patch alone understands, nor an
    /// avoidance that means nothing on foot.
    func testDrivingAndWalkingUseTheirOwnCosting() {
        XCTAssertEqual(RoutingEngine.costing(for: .road), "motorcycle")
        XCTAssertEqual(RoutingEngine.costing(for: .driving), "auto")
        XCTAssertEqual(RoutingEngine.costing(for: .walking), "pedestrian")

        var prefs = RoutePreferences()
        prefs.prefer = .manyCurves
        prefs.avoidHighways = true
        prefs.avoidFerries = true
        let driving = RoutingEngine.costingOptions(for: .driving, preferences: prefs)
        XCTAssertEqual(driving["exclude_unpaved"] as? Bool, true)
        XCTAssertEqual(driving["use_highways"] as? Int, 0)
        XCTAssertNil(driving["use_curvature"])

        let walking = RoutingEngine.costingOptions(for: .walking, preferences: prefs)
        XCTAssertEqual(walking["max_hiking_difficulty"] as? Int, 3)
        XCTAssertNil(walking["use_highways"])
        XCTAssertEqual(walking["use_ferry"] as? Int, 0)
        XCTAssertNil(walking["use_curvature"])
    }

    func testGarminWordsForTheModes() {
        XCTAssertEqual(RoutingMode.garmin("Automotive"), .driving)
        XCTAssertEqual(RoutingMode.garmin("Walking"), .walking)
        XCTAssertEqual(RoutingMode.garmin("Direct"), .direct)
        XCTAssertNil(RoutingMode.garmin("Mountain Biking"))
        XCTAssertTrue(RoutingMode.walking.leavesTheRoad)
        XCTAssertFalse(RoutingMode.driving.leavesTheRoad)
    }
}
