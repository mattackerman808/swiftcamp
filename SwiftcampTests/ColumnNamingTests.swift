import XCTest
@testable import Swiftcamp

/// The camelCase-to-snake_case bridge every record type depends on.
///
/// These exist because GRDB's stock strategies are not inverse over a
/// trailing acronym: `routeID` encodes to `route_id` and `route_id` decodes
/// back to `routeId`. On a non-optional property that throws and you find it
/// at once. On an optional one it reads back `nil`, so a waypoint saved into
/// a folder comes out unfiled with nothing reported anywhere.
final class ColumnNamingTests: XCTestCase {
    /// Every property name across the six record types.
    private let properties = [
        "id", "name", "parentID", "sortOrder", "createdAt", "updatedAt",
        "listID", "lat", "lon", "elevation", "symbol", "comment",
        "descriptionText", "color", "trackID", "seq", "time",
        "routeID", "isVia", "isPinned", "waypointID", "geometry",
    ]

    func testPropertiesConvertToTheColumnsTheSchemaDeclares() {
        XCTAssertEqual(ColumnNaming.column(for: "listID"), "list_id")
        XCTAssertEqual(ColumnNaming.column(for: "routeID"), "route_id")
        XCTAssertEqual(ColumnNaming.column(for: "parentID"), "parent_id")
        XCTAssertEqual(ColumnNaming.column(for: "descriptionText"), "description_text")
        XCTAssertEqual(ColumnNaming.column(for: "isVia"), "is_via")
        XCTAssertEqual(ColumnNaming.column(for: "sortOrder"), "sort_order")
        XCTAssertEqual(ColumnNaming.column(for: "id"), "id")
        XCTAssertEqual(ColumnNaming.column(for: "lat"), "lat")
    }

    func testColumnsConvertBackToTheSwiftSpelling() {
        XCTAssertEqual(ColumnNaming.property(for: "list_id"), "listID")
        XCTAssertEqual(ColumnNaming.property(for: "route_id"), "routeID")
        XCTAssertEqual(ColumnNaming.property(for: "description_text"), "descriptionText")
        XCTAssertEqual(ColumnNaming.property(for: "is_via"), "isVia")
        XCTAssertEqual(ColumnNaming.property(for: "id"), "id")
    }

    /// The property that actually matters: the pair is a round trip. A new
    /// column added later fails here before it fails silently in the app.
    func testTheConversionIsInverseForEveryPropertyInTheSchema() {
        for property in properties {
            let column = ColumnNaming.column(for: property)
            XCTAssertEqual(ColumnNaming.property(for: column), property,
                           "\(property) -> \(column) -> \(ColumnNaming.property(for: column))")
        }
    }
}
