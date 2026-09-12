import XCTest
@testable import Swiftcamp

/// Learning what a file holds from its two ends.
///
/// This is what makes identifying a 22 MB track log cost eight kilobytes.
/// Both inputs are fragments — the head has no closing tags, the tail starts
/// mid-element — so an XML parser rejects them and the scanning has to cope
/// with that rather than assume a well-formed document.
final class GPXPeekTests: XCTestCase {
    private let head = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx xmlns="http://www.topografix.com/GPX/1/1" creator="zumo XT3" version="1.1">
          <metadata><time>2026-08-12T08:14:00Z</time></metadata>
          <trk><name>Log</name><trkseg>
            <trkpt lat="40.0" lon="-105.0"><ele>1600</ele><time>2026-08-12T08:14:02Z</time></trkpt>
        """.utf8)

    /// Begins part-way through an element, exactly as a read from an offset
    /// in the middle of a file does.
    private let tail = Data("""
            lon="-106.5"><ele>2100</ele><time>2026-08-14T17:42:10Z</time></trkpt>
          </trkseg></trk>
        </gpx>
        """.utf8)

    func testFindsTheFirstAndLastTimestamp() {
        let result = GPXPeek.scan(head: head, tail: tail)

        XCTAssertEqual(result.start, GPXDate.parse("2026-08-12T08:14:00Z"))
        XCTAssertEqual(result.end, GPXDate.parse("2026-08-14T17:42:10Z"))
    }

    func testSeesThatTheFileIsATrackLog() {
        let result = GPXPeek.scan(head: head, tail: tail)

        XCTAssertTrue(result.sawTrack)
        XCTAssertFalse(result.sawRoute)
        XCTAssertFalse(result.sawWaypoint)
    }

    /// A tail almost always begins part-way through a UTF-8 sequence, and a
    /// strict decode returns nil for the whole buffer rather than one bad
    /// character. Losing several thousand good bytes to one broken one would
    /// make this useless on exactly the files it exists for.
    func testATailThatStartsMidCharacterStillScans() {
        var broken = Data([0x9F, 0x8F, 0x94])     // continuation bytes, no lead
        broken.append(tail)

        let result = GPXPeek.scan(head: head, tail: broken)
        XCTAssertEqual(result.end, GPXDate.parse("2026-08-14T17:42:10Z"))
    }

    /// When the tail carries no timestamp, the answer is the one date we do
    /// have rather than nothing at all.
    func testFallsBackToTheStartWhenTheTailHasNoTime() {
        let result = GPXPeek.scan(head: head, tail: Data("</trkseg></trk></gpx>".utf8))
        XCTAssertEqual(result.end, result.start)
    }

    func testEmptyInputIsEmpty() {
        XCTAssertTrue(GPXPeek.scan(head: Data(), tail: Data()).isEmpty)
    }

    func testRecognisesRoutesAndWaypoints() {
        let head = Data("""
            <?xml version="1.0"?>
            <gpx version="1.1"><wpt lat="40" lon="-105"><name>Stop</name></wpt>
            <rte><name>Trail Ridge</name>
            """.utf8)
        let result = GPXPeek.scan(head: head, tail: Data())

        XCTAssertTrue(result.sawRoute)
        XCTAssertTrue(result.sawWaypoint)
        XCTAssertFalse(result.sawTrack)
    }

    /// The windows have to be big enough to clear a Garmin's preamble: the
    /// XML declaration, the gpx element with its namespace declarations, and
    /// a metadata block, before the first timestamp appears.
    func testTheHeadWindowClearsARealisticPreamble() {
        XCTAssertGreaterThanOrEqual(GPXPeek.headBytes, 8 * 1024)
        XCTAssertGreaterThanOrEqual(GPXPeek.tailBytes, 4 * 1024)
    }
}
