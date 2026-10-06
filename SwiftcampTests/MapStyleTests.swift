import XCTest
@testable import Swiftcamp

/// The parts of the style the page depends on by name.
final class MapStyleTests: XCTestCase {
    private func style() throws -> [String: Any] {
        let json = try MapStyle.json(bundledURL: "pmtiles://bundled", glyphsURL: "glyphs", spriteURL: "sprite")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    /// The page switches trails by the id prefix, and the View menu's
    /// switch starts off; a layer that missed either would be drawn with
    /// the switch off, or never.
    func testEveryTrailsLayerIsPrefixedHiddenAndFromTheTrailsSource() throws {
        let style = try style()
        let layers = try XCTUnwrap(style["layers"] as? [[String: Any]])
        let trails = layers.filter { ($0["source"] as? String) == "trails" }

        XCTAssertFalse(trails.isEmpty)
        for layer in trails {
            let id = layer["id"] as? String ?? ""
            XCTAssertTrue(id.hasPrefix(MapStyle.trailLayerPrefix), id)
            XCTAssertEqual((layer["layout"] as? [String: Any])?["visibility"] as? String, "none", id)
        }
        XCTAssertEqual(layers.filter { ($0["id"] as? String ?? "").hasPrefix(MapStyle.trailLayerPrefix) }.count,
                       trails.count, "nothing else wears the prefix")
        XCTAssertNotNil((style["sources"] as? [String: Any])?["trails"])
    }

    /// A route planned along a trail must still read as the route.
    func testTrailsDrawUnderTheRouteLine() throws {
        let ids = try XCTUnwrap(try style()["layers"] as? [[String: Any]]).compactMap { $0["id"] as? String }
        let lastTrail = try XCTUnwrap(ids.lastIndex { $0.hasPrefix(MapStyle.trailLayerPrefix) })
        let route = try XCTUnwrap(ids.firstIndex(of: "route-casing"))
        XCTAssertLessThan(lastTrail, route)
    }
}
