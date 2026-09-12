import XCTest
@testable import Swiftcamp

/// The GPX round trip, which is the product.
///
/// `CLAUDE.md`: "The GPX export path is the product. A route that looks right
/// on screen but imports wrong on the device is a failed feature." Nothing
/// else in this app can be got right in a way that makes up for getting this
/// wrong, so these tests are about fidelity rather than coverage.
final class GPXTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "gpx"),
                               "fixture \(name).gpx is not in the test bundle")
        return try Data(contentsOf: url)
    }

    private func read(_ name: String) throws -> GPXDocument {
        try GPXReader.read(data: try fixture(name))
    }

    // MARK: - Reading

    func testReadsABaseCampExport() throws {
        let doc = try read("basecamp-route")

        XCTAssertEqual(doc.creator, "Garmin BaseCamp 4.8.11")
        XCTAssertEqual(doc.name, "Colorado 2026")
        XCTAssertEqual(doc.waypoints.count, 2)
        XCTAssertEqual(doc.routes.count, 1)
        XCTAssertEqual(doc.tracks.count, 1)
    }

    func testReadsWaypointFields() throws {
        let doc = try read("basecamp-route")
        let estes = try XCTUnwrap(doc.waypoints.first)

        XCTAssertEqual(estes.name, "Estes Park")
        XCTAssertEqual(estes.lat, 40.3772, accuracy: 1e-9)
        XCTAssertEqual(estes.lon, -105.5217, accuracy: 1e-9)
        XCTAssertEqual(estes.elevation, 2293.0)
        XCTAssertEqual(estes.symbol, "Flag, Blue")
        XCTAssertEqual(estes.descriptionText, "East entrance to the park")
        XCTAssertEqual(estes.comment, "fuel & coffee", "entities must be decoded")
    }

    /// The single most important assertion in this file. These shaping points
    /// are what make a Garmin follow the planned road instead of re-routing
    /// from scratch.
    func testReadsRouteShapingPoints() throws {
        let doc = try read("basecamp-route")
        let route = try XCTUnwrap(doc.routes.first)

        XCTAssertEqual(route.route.name, "Trail Ridge Road")
        XCTAssertEqual(route.route.color, "Magenta")
        XCTAssertEqual(route.points.count, 3, "three via points")

        XCTAssertEqual(route.points[0].geometry?.count, 4)
        XCTAssertEqual(route.points[1].geometry?.count, 2)
        XCTAssertNil(route.points[2].geometry, "the last via point leads nowhere")

        XCTAssertEqual(route.points[0].geometry?.first,
                       Coordinate(lat: 40.3781, lon: -105.5289))
    }

    /// Via points and shaping geometry interleave into one path, which is
    /// what the map draws and what the length is measured along.
    func testRoutePathIsViaPointsAndGeometryInOrder() throws {
        let route = try XCTUnwrap(try read("basecamp-route").routes.first)
        // 3 via points + 4 shaping + 2 shaping.
        XCTAssertEqual(route.path.count, 9)
        XCTAssertEqual(route.path.first, Coordinate(lat: 40.3772, lon: -105.5217))
        XCTAssertEqual(route.path.last, Coordinate(lat: 40.2503, lon: -105.8712))
    }

    func testReadsTrackSegments() throws {
        let track = try XCTUnwrap(try read("basecamp-route").tracks.first)

        XCTAssertEqual(track.track.name, "Recorded ride")
        XCTAssertEqual(track.track.color, "DarkGreen")
        XCTAssertEqual(track.points.count, 3)
        XCTAssertEqual(track.segments.count, 2, "the gap in recording is real")
        XCTAssertEqual(track.segments.map(\.count), [2, 1])
        XCTAssertEqual(track.points.first?.time,
                       GPXDate.parse("2026-09-11T15:00:00Z"))
    }

    /// `gpxx` is a convention, not a rule. A file that binds Garmin's
    /// extensions to any other prefix means exactly the same thing, and
    /// matching on the literal string would drop its route shape.
    func testPrefixDoesNotMatterOnlyTheNamespace() throws {
        let route = try XCTUnwrap(try read("odd-prefix").routes.first)

        XCTAssertEqual(route.route.name, "Peak to Peak")
        XCTAssertEqual(route.route.color, "Blue")
        XCTAssertEqual(route.points[0].geometry?.count, 2)
    }

    func testReadsGPX10() throws {
        let doc = try read("gpx10-track")

        XCTAssertEqual(doc.waypoints.count, 1)
        XCTAssertEqual(doc.waypoints.first?.name, "Denver")
        XCTAssertEqual(doc.tracks.first?.points.count, 2)
    }

    /// Unknown vendor blocks are skipped whole. The fixture hides a `<name>`
    /// inside one, which would become the track's name if the reader
    /// descended into namespaces it does not handle.
    func testForeignExtensionsAreSkippedEntirely() throws {
        let track = try XCTUnwrap(try read("foreign-extensions").tracks.first)

        XCTAssertEqual(track.track.name, "Sensor-laden")
        XCTAssertEqual(track.points.count, 2)
        XCTAssertEqual(track.points[0].elevation, 1500.0)
        XCTAssertEqual(track.points[1].elevation, 1520.0,
                       "the element after a skipped block must still parse")
    }

    // MARK: - Failures

    func testNonGPXIsRejected() {
        XCTAssertThrowsError(try GPXReader.read(data: Data("not xml at all".utf8))) { error in
            XCTAssertEqual(error as? GPXError, .notGPX)
        }
    }

    func testXMLThatIsNotGPXIsRejected() {
        let xml = Data(#"<?xml version="1.0"?><kml><Placemark/></kml>"#.utf8)
        XCTAssertThrowsError(try GPXReader.read(data: xml)) { error in
            XCTAssertEqual(error as? GPXError, .notGPX)
        }
    }

    /// A point with no coordinate is not a point. Carrying on would drop
    /// geometry without saying so, which is the failure mode this whole file
    /// exists to prevent.
    func testAPointWithoutCoordinatesIsAnError() {
        let xml = Data("""
            <?xml version="1.0"?>
            <gpx version="1.1" creator="t" xmlns="\(GPX.namespace)">
              <wpt lon="-105.0"><name>no latitude</name></wpt>
            </gpx>
            """.utf8)
        XCTAssertThrowsError(try GPXReader.read(data: xml)) { error in
            guard case .malformed = error as? GPXError else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    // MARK: - Round trip

    /// Identity and timestamps flattened, so a comparison is about content.
    ///
    /// GPX carries no stable identifier for anything in it, so every read
    /// mints fresh ones and two reads of the same bytes are never `==`. That
    /// is correct — importing the same file twice really does produce two
    /// separate routes in the library — but it makes the synthesised fields
    /// noise in a fidelity test.
    private func normalized(_ document: GPXDocument) -> GPXDocument {
        let epoch = Date(timeIntervalSince1970: 0)
        var document = document

        document.waypoints = document.waypoints.map {
            var w = $0
            w.id = "-"; w.createdAt = epoch; w.updatedAt = epoch
            return w
        }
        document.routes = document.routes.map {
            var detail = $0
            detail.route.id = "-"; detail.route.createdAt = epoch; detail.route.updatedAt = epoch
            detail.points = detail.points.map { var p = $0; p.id = nil; p.routeID = "-"; return p }
            return detail
        }
        document.tracks = document.tracks.map {
            var detail = $0
            detail.track.id = "-"; detail.track.createdAt = epoch; detail.track.updatedAt = epoch
            detail.points = detail.points.map { var p = $0; p.id = nil; p.trackID = "-"; return p }
            return detail
        }
        return document
    }

    /// Read, write, read again, and compare. The second read is what proves
    /// nothing was lost on the way out, which reading alone cannot.
    func testBaseCampExportSurvivesARoundTrip() throws {
        let original = try read("basecamp-route")
        let rewritten = try GPXReader.read(data: GPXWriter.data(original))

        XCTAssertEqual(normalized(rewritten), normalized(original))
    }

    func testEveryFixtureSurvivesARoundTrip() throws {
        for name in ["basecamp-route", "gpx10-track", "odd-prefix", "foreign-extensions"] {
            let original = try read(name)
            let once = try GPXReader.read(data: GPXWriter.data(original))
            let twice = try GPXReader.read(data: GPXWriter.data(once))

            // Original against the first write catches anything the writer
            // drops; first against second catches anything it adds or
            // reshapes, which a single pass would call stable.
            XCTAssertEqual(normalized(once), normalized(original), "\(name), first write")
            XCTAssertEqual(normalized(twice), normalized(once), "\(name), second write")
        }
    }

    /// Importing one file twice must produce two routes, not one seen twice.
    func testEachReadMintsFreshIdentifiers() throws {
        let first = try read("basecamp-route")
        let second = try read("basecamp-route")

        XCTAssertNotEqual(first.routes.first?.route.id, second.routes.first?.route.id)
        XCTAssertNotEqual(first.waypoints.first?.id, second.waypoints.first?.id)
    }

    /// Shaping points are the thing most likely to be quietly dropped on the
    /// way out, so they get their own assertion on written text.
    func testWrittenRouteCarriesShapingPoints() throws {
        let text = GPXWriter.write(try read("basecamp-route"))

        XCTAssertTrue(text.contains("<gpxx:RoutePointExtension>"))
        XCTAssertTrue(text.contains(#"<gpxx:rpt lat="40.3781" lon="-105.5289"/>"#))
        XCTAssertEqual(text.components(separatedBy: "<gpxx:rpt ").count - 1, 6,
                       "all six shaping points, across both via points")
    }

    func testWrittenFileDeclaresGPX11AndTheGarminNamespace() throws {
        let text = GPXWriter.write(try read("basecamp-route"))

        XCTAssertTrue(text.hasPrefix(#"<?xml version="1.0" encoding="UTF-8"?>"#))
        XCTAssertTrue(text.contains(#"version="1.1""#))
        XCTAssertTrue(text.contains(GPX.namespace))
        XCTAssertTrue(text.contains(GPX.garminExtensions))
    }

    /// A GPX 1.0 file read and written comes out as 1.1. We read the old
    /// version so a user's existing library opens; we never write it.
    func testLegacyInputIsWrittenAsGPX11() throws {
        let text = GPXWriter.write(try read("gpx10-track"))

        XCTAssertTrue(text.contains(GPX.namespace))
        XCTAssertFalse(text.contains(GPX.legacyNamespace))
    }

    func testTrackSegmentsSurviveTheWrite() throws {
        let text = GPXWriter.write(try read("basecamp-route"))
        XCTAssertEqual(text.components(separatedBy: "<trkseg>").count - 1, 2)
    }

    // MARK: - Escaping

    func testTextIsEscapedAndComesBackIntact() throws {
        let nasty = #"Bob & Jane's "best" <road> pick"#
        let doc = GPXDocument(name: nasty, waypoints: [
            Waypoint(name: nasty, lat: 40.0, lon: -105.0, comment: nasty),
        ])

        let text = GPXWriter.write(doc)
        XCTAssertFalse(text.contains("<road>"), "raw markup must not reach the file")
        XCTAssertTrue(text.contains("&amp;"))
        XCTAssertFalse(text.contains("&amp;amp;"), "ampersands must not be escaped twice")

        let back = try GPXReader.read(data: Data(text.utf8))
        XCTAssertEqual(back.name, nasty)
        XCTAssertEqual(back.waypoints.first?.name, nasty)
        XCTAssertEqual(back.waypoints.first?.comment, nasty)
    }

    /// A `NumberFormatter` here would write `40,3772` for a user whose locale
    /// uses a decimal comma, producing a file no GPS can read. The failure
    /// would never appear on the developer's machine.
    func testCoordinatesAreWrittenLocaleIndependently() throws {
        let doc = GPXDocument(waypoints: [
            Waypoint(name: "Estes Park", lat: 40.3772, lon: -105.5217),
        ])
        let text = GPXWriter.write(doc)

        XCTAssertTrue(text.contains(#"lat="40.3772" lon="-105.5217""#))
        XCTAssertFalse(text.contains("40,3772"))
    }

    // MARK: - Into and out of the library

    /// A file lands in the library and comes back out with its shape intact.
    /// This is the whole path the product is judged on.
    func testGPXSurvivesARoundTripThroughTheLibrary() throws {
        let store = LibraryStore(try AppDatabase.inMemory())
        let original = try read("basecamp-route")

        let added = try store.importGPX(original)
        XCTAssertEqual(added, GPXImportCount(waypoints: 2, routes: 1, tracks: 1))

        let exported = try store.exportGPX(
            waypointIDs: try store.waypoints().map(\.id),
            routeIDs: try store.routes().map(\.id),
            trackIDs: try store.tracks().map(\.id))

        let route = try XCTUnwrap(exported.routes.first)
        XCTAssertEqual(route.route.name, "Trail Ridge Road")
        XCTAssertEqual(route.route.color, "Magenta")
        XCTAssertEqual(route.points.map { $0.geometry?.count }, [4, 2, nil],
                       "shaping points must survive the database")
        XCTAssertEqual(exported.tracks.first?.segments.count, 2)

        // And out to bytes, then back, which is what a device would read.
        let reread = try GPXReader.read(data: GPXWriter.data(exported))
        XCTAssertEqual(reread.routes.first?.path, route.path)
    }

    func testImportingTheSameFileTwiceAddsTwoCopies() throws {
        let store = LibraryStore(try AppDatabase.inMemory())
        try store.importGPX(try read("basecamp-route"))
        try store.importGPX(try read("basecamp-route"))

        XCTAssertEqual(try store.routes().count, 2,
                       "import adds; matching by name would overwrite an edited route")
    }

    func testImportFilesEverythingIntoTheChosenList() throws {
        let store = LibraryStore(try AppDatabase.inMemory())
        let list = LibraryList(name: "Colorado 2026")
        try store.save(list)

        try store.importGPX(try read("basecamp-route"), into: list.id)

        XCTAssertEqual(try store.waypoints().map(\.listID), [list.id, list.id])
        XCTAssertEqual(try store.routes().first?.listID, list.id)
        XCTAssertEqual(try store.tracks().first?.listID, list.id)
    }
}
