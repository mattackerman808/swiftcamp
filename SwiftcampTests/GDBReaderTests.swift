import XCTest
@testable import Swiftcamp

/// The GDB reader against files GPSBabel wrote from this suite's own GPX
/// fixtures, so what each field should hold is known from the GPX, and
/// against a route built byte by byte here for what GPSBabel cannot write.
///
/// GPSBabel is not BaseCamp. Its writer stores each route point's links as
/// the point and its successor and nothing between, so a GPSBabel-written
/// GDB carries no road shape, and it lists every via point as a waypoint of
/// its own, which is also what MapSource and BaseCamp do. The road shape is
/// checked on a hand-built record whose layout follows the published notes,
/// and was confirmed against MapSource's own files, which are not in this
/// repository because they are GPSBabel's and GPL.
final class GDBReaderTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: nil),
                                "\(name) is not in the test bundle")
        return try Data(contentsOf: url)
    }

    private func gpx(_ name: String) throws -> GPXDocument {
        try GPXReader.read(data: try fixture(name))
    }

    // MARK: - Detection

    func testDetectsTheSignature() throws {
        XCTAssertTrue(GDBReader.looksLikeGDB(try fixture("gpsbabel-route-v3.gdb")))
        XCTAssertFalse(GDBReader.looksLikeGDB(try fixture("basecamp-route.gpx")))
        XCTAssertThrowsError(try GDBReader.read(data: try fixture("basecamp-route.gpx"))) { error in
            XCTAssertEqual(error as? GDBError, .notGDB)
        }
    }

    func testFileImportChoosesByBytesNotName() throws {
        let fromGDB = try FileImport.read(data: try fixture("gpsbabel-route-v3.gdb"))
        let fromGPX = try FileImport.read(data: try fixture("basecamp-route.gpx"))
        XCTAssertEqual(fromGDB.routes.count, 1)
        XCTAssertEqual(fromGPX.routes.count, 1)
    }

    func testATruncatedFileSaysSo() throws {
        let data = try fixture("gpsbabel-route-v3.gdb")
        XCTAssertThrowsError(try GDBReader.read(data: data.prefix(data.count / 2))) { error in
            XCTAssertEqual(error as? GDBError, .truncated)
        }
    }

    // MARK: - Waypoints

    /// The file's waypoints are the GPX's plus the route's via points,
    /// because in Garmin's model a via point is a waypoint. The route's
    /// turn points are hidden waypoints of a higher class and stay out.
    func testWaypointsComeBackWithNamePositionSymbolAndNotes() throws {
        for version in ["v2", "v3"] {
            let document = try GDBReader.read(data: try fixture("gpsbabel-route-\(version).gdb"))
            let original = try gpx("basecamp-route.gpx")
            let vias = try XCTUnwrap(original.routes.first).viaPoints

            var expectedNames = original.waypoints.map(\.name)
            for via in vias where !expectedNames.contains(via.name ?? "") { expectedNames.append(via.name ?? "") }
            XCTAssertEqual(document.waypoints.map(\.name), expectedNames, version)

            for (read, expected) in zip(document.waypoints, original.waypoints) {
                XCTAssertEqual(read.lat, expected.lat, accuracy: 1e-6, version)
                XCTAssertEqual(read.lon, expected.lon, accuracy: 1e-6, version)
                XCTAssertEqual(read.symbol, expected.symbol, version)
                if let elevation = expected.elevation {
                    XCTAssertEqual(try XCTUnwrap(read.elevation), elevation, accuracy: 0.01, version)
                }
            }
        }
    }

    // MARK: - Routes

    func testRouteKeepsItsViaPointsInOrder() throws {
        for version in ["v2", "v3"] {
            let document = try GDBReader.read(data: try fixture("gpsbabel-route-\(version).gdb"))
            let original = try gpx("basecamp-route.gpx")
            let route = try XCTUnwrap(document.routes.first, version)
            let expected = try XCTUnwrap(original.routes.first)

            XCTAssertEqual(route.route.name, expected.route.name, version)
            XCTAssertEqual(route.viaPoints.map(\.name), expected.viaPoints.map(\.name), version)
            for (read, want) in zip(route.viaPoints, expected.viaPoints) {
                XCTAssertEqual(read.lat, want.lat, accuracy: 1e-6, version)
                XCTAssertEqual(read.lon, want.lon, accuracy: 1e-6, version)
            }
            XCTAssertEqual(route.points.map(\.seq), Array(route.points.indices), version)
            XCTAssertEqual(Set(route.points.map(\.routeID)), [route.route.id], version)
            // A GDB before 1.9 has no route colour; from 1.9 GPSBabel writes one.
            if version == "v3" { XCTAssertEqual(route.route.color, expected.route.color) }
        }
    }

    /// The point of the format: a route point's links, less the point
    /// itself and the next one, are the road the planner chose, and a
    /// point of a class above zero is the router's, not the rider's.
    func testRoadShapeAndShapingPointsFromALinkedRoute() throws {
        var file = GDBBytes()
        file.waypoint("Start", lat: 40.0, lon: -105.0)
        file.waypoint("End", lat: 40.2, lon: -105.2)
        file.route("Linked", points: [
            (name: "Start", class: 0, links: [(40.0, -105.0), (40.05, -105.05), (40.1, -105.1)]),
            (name: "Turn", class: 8, links: [(40.1, -105.1), (40.15, -105.12), (40.18, -105.15), (40.2, -105.2)]),
            (name: "End", class: 0, links: []),
        ], color: 14)

        let document = try GDBReader.read(data: file.data())
        XCTAssertEqual(document.waypoints.map(\.name), ["Start", "End"])
        let route = try XCTUnwrap(document.routes.first)
        XCTAssertEqual(route.route.name, "Linked")
        XCTAssertEqual(route.route.color, "Magenta")
        XCTAssertEqual(route.points.map(\.isVia), [true, false, true])
        XCTAssertEqual(route.points.map(\.name), ["Start", nil, "End"])
        // Semicircles round at the eighth decimal, so near rather than equal.
        func near(_ got: [Coordinate]?, _ want: [Coordinate], line: UInt = #line) {
            XCTAssertEqual(got?.count, want.count, line: line)
            for (g, w) in zip(got ?? [], want) {
                XCTAssertEqual(g.lat, w.lat, accuracy: 1e-6, line: line)
                XCTAssertEqual(g.lon, w.lon, accuracy: 1e-6, line: line)
            }
        }
        near(route.points[0].geometry, [Coordinate(lat: 40.05, lon: -105.05)])
        near(route.points[1].geometry, [Coordinate(lat: 40.15, lon: -105.12), Coordinate(lat: 40.18, lon: -105.15)])
        XCTAssertNil(route.points[2].geometry)
        XCTAssertEqual(route.points[2].lat, 40.2, accuracy: 1e-6, "a point without links takes its waypoint's position")
        XCTAssertEqual(route.path.count, 6)
    }

    // MARK: - Tracks

    func testTrackPointsComeBackWithTimesAndElevation() throws {
        let document = try GDBReader.read(data: try fixture("gpsbabel-track-v3.gdb"))
        let original = try gpx("gpx10-track.gpx")
        let track = try XCTUnwrap(document.tracks.first)
        let expected = try XCTUnwrap(original.tracks.first)

        XCTAssertEqual(track.track.name, expected.track.name)
        XCTAssertEqual(track.points.count, expected.points.count)
        for (read, want) in zip(track.points, expected.points) {
            XCTAssertEqual(read.lat, want.lat, accuracy: 1e-6)
            XCTAssertEqual(read.lon, want.lon, accuracy: 1e-6)
            if let e = want.elevation { XCTAssertEqual(try XCTUnwrap(read.elevation), e, accuracy: 0.01) }
            if let t = want.time { XCTAssertEqual(try XCTUnwrap(read.time).timeIntervalSince1970, t.timeIntervalSince1970, accuracy: 1) }
        }
        XCTAssertEqual(track.points.map(\.seq), Array(track.points.indices))
    }

    // MARK: - Symbols

    func testSymbolNumbersAreGarminsGPXNames() {
        XCTAssertEqual(GDBSymbols.name(for: 18), "Waypoint")
        XCTAssertEqual(GDBSymbols.name(for: 141), "Flag, Blue")
        XCTAssertEqual(GDBSymbols.name(for: 8), "Gas Station")
        XCTAssertEqual(GDBSymbols.name(for: 503), "Custom 3")
        XCTAssertEqual(GDBSymbols.name(for: 99_999), "Waypoint")
        XCTAssertEqual(GDBSymbols.number(for: "Flag, Blue"), 141)
        XCTAssertEqual(GDBSymbols.number(for: "flag, blue"), 141)
        XCTAssertEqual(GDBSymbols.number(for: "Custom 3"), 503)
        XCTAssertNil(GDBSymbols.number(for: "Not a symbol"))
    }
}

/// Builds a format 1.9 GDB in memory, the layout MapSource 6.12 and later
/// and BaseCamp's Export write, from the published notes. Only what the
/// reader tests need: the header, user waypoints and one route.
private struct GDBBytes {
    private var out = Data()
    private var records = Data()

    init() {
        out.append(contentsOf: Array("MsRc".utf8))
        out.append(contentsOf: [0x66, 0x00])                        // primary format 1.2
        var d = Data(); d.append(contentsOf: [109, 0])              // format 1.9
        record("D", d)
        var a = Data(); a.append(contentsOf: [0xF4, 0x01])          // program version 5.00
        a.append(cstr("SQA")); a.append(cstr("Jan  1 2026")); a.append(cstr("00:00:00"))
        record("A", a)
        out.append(cstr("MapSource"))
    }

    mutating func waypoint(_ name: String, lat: Double, lon: Double) {
        var w = Data()
        w.append(cstr(name)); w.append(u32(0)); w.append(cstr(""))  // name, class, country
        w.append(Data(count: 22))                                   // subclass
        w.append(coord(lat)); w.append(coord(lon))
        w.append(0)                                                 // no altitude
        w.append(cstr("")); w.append(0)                             // comment, no proximity
        w.append(u32(1)); w.append(u32(0)); w.append(u32(141))      // display, colour, Flag, Blue
        w.append(cstr("")); w.append(cstr("")); w.append(cstr(""))  // city, state, facility
        w.append(0); w.append(0)                                    // map line, no depth
        w.append(cstr("")); w.append(0)                             // street, no unknown string
        w.append(u32(0)); w.append(cstr(""))                        // leg time, directions
        w.append(u32(0))                                            // no links
        w.append(contentsOf: [0, 0]); w.append(0); w.append(0)      // categories, no temperature, no time
        w.append(u32(0)); w.append(cstr("")); w.append(cstr(""))    // phones, country, postal code
        record("W", w)
    }

    mutating func route(_ name: String, points: [(name: String, class: UInt32, links: [(Double, Double)])], color: UInt32) {
        var r = Data()
        r.append(cstr(name)); r.append(0)                           // name, auto-name
        r.append(1)                                                 // no bounds
        r.append(u32(UInt32(points.count)))
        for point in points {
            r.append(cstr(point.name)); r.append(u32(point.class)); r.append(cstr(""))
            r.append(Data(count: 22))                               // subclass
            r.append(0)                                             // no unknown string
            r.append(Data(count: 12)); r.append(Data(count: 2)); r.append(u32(0))
            r.append(u32(UInt32(point.links.count)))
            for (lat, lon) in point.links { r.append(coord(lat)); r.append(coord(lon)); r.append(0) }
            r.append(1)                                             // no bounds
            r.append(Data(count: 8))                                // format 1.8 unknown
            r.append(0); r.append(0)                                // no time, no end time
        }
        r.append(u32(0))                                            // no links
        r.append(u32(color))
        r.append(0)                                                 // no auto-route info
        r.append(cstr(""))                                          // notes
        record("R", r)
    }

    func data() -> Data {
        var d = out
        d.append(records)
        var v = Data(); v.append(cstr("")); v.append(0)
        var f = d; f.append(u32(UInt32(v.count))); f.append(UInt8(ascii: "V")); f.append(v)
        return f
    }

    private mutating func record(_ type: Character, _ content: Data) {
        var target: Data
        target = type == "D" || type == "A" ? out : records
        target.append(u32(UInt32(content.count)))
        target.append(UInt8(ascii: type.unicodeScalars.first!))
        target.append(content)
        if type == "D" || type == "A" { out = target } else { records = target }
    }

    private func cstr(_ s: String) -> Data { Data(s.utf8) + [0] }
    private func u32(_ v: UInt32) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)]) }
    private func coord(_ degrees: Double) -> Data {
        u32(UInt32(bitPattern: Int32((degrees / 360.0 * 4_294_967_296.0).rounded())))
    }
}
