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
}
