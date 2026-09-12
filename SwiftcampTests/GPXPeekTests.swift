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

    /// The start is the first timestamp *inside a point*, not the first in
    /// the file. A Garmin stamps metadata with when the file was written,
    /// which on an active log is today while the riding was last week.
    func testStartComesFromTheFirstPointNotTheMetadata() {
        let result = GPXPeek.scan(head: head, tail: tail)

        XCTAssertEqual(result.start, GPXDate.parse("2026-08-12T08:14:02Z"),
                       "the trkpt time, not the metadata time two seconds earlier")
        XCTAssertEqual(result.end, GPXDate.parse("2026-08-14T17:42:10Z"))
    }

    /// A file whose metadata is stamped later than its contents reported a
    /// range running backwards — "Sep 12–7" on screen.
    func testARangeNeverRunsBackwards() {
        let stamped = Data("""
            <?xml version="1.0"?>
            <gpx version="1.1"><metadata><time>2026-09-12T10:00:00Z</time></metadata>
            <trk><trkseg>
            """.utf8)
        let earlier = Data("<time>2026-09-07T14:00:00Z</time></trkpt></trkseg></trk></gpx>".utf8)

        let result = GPXPeek.scan(head: stamped, tail: earlier)
        let start = try? XCTUnwrap(result.start)
        let end = try? XCTUnwrap(result.end)
        XCTAssertLessThanOrEqual(start ?? .distantPast, end ?? .distantFuture)
    }

    /// With no point timestamps at all, the metadata time is better than
    /// nothing.
    func testFallsBackToMetadataWhenNoPointHasATime() {
        let noPointTimes = Data("""
            <?xml version="1.0"?>
            <gpx version="1.1"><metadata><time>2026-09-12T10:00:00Z</time></metadata>
            <trk><trkseg><trkpt lat="40" lon="-105"><ele>1600</ele></trkpt>
            """.utf8)

        let result = GPXPeek.scan(head: noPointTimes, tail: Data())
        XCTAssertEqual(result.start, GPXDate.parse("2026-09-12T10:00:00Z"))
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

    /// The case that cost a 22 MB download. A zūmo XT3 answers a read at
    /// offset zero and refuses one a long way in, so the head arrives and the
    /// tail does not. Scanning must still report everything the head knows
    /// rather than treating the pair as all-or-nothing.
    func testAMissingTailStillReportsWhatTheHeadKnows() {
        let result = GPXPeek.scan(head: head, tail: Data())

        XCTAssertTrue(result.sawTrack)
        XCTAssertEqual(result.start, GPXDate.parse("2026-08-12T08:14:02Z"))
        XCTAssertFalse(result.isEmpty, "a head-only read is not an empty result")
    }
}
