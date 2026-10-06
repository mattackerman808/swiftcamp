import XCTest
@testable import Swiftcamp

/// The track tools and the statistics, on values with no store.
///
/// Every tool makes a new track and leaves the original alone; the
/// invariants are `seq` matching array order, segments still breaking
/// where the recording did, and each fix keeping its own time and
/// elevation through whatever happens to its neighbours.
final class TrackEditingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Ten fixes north at a hundred metres and ten seconds each, a break,
    /// then ten east: a ride in two segments with a clock and an altimeter.
    private var ride: TrackDetail {
        let track = Track(name: "Ride", color: "Blue", comment: "Sunday")
        var points: [TrackPoint] = []
        for i in 0..<10 {
            points.append(TrackPoint(trackID: track.id, seq: i, segment: 0,
                                     lat: 40 + Double(i) * 0.0009, lon: -105,
                                     elevation: 1500 + Double(i) * 10, time: start.addingTimeInterval(Double(i) * 10)))
        }
        for i in 0..<10 {
            points.append(TrackPoint(trackID: track.id, seq: 10 + i, segment: 1,
                                     lat: 40.0081, lon: -105 + Double(i) * 0.0012,
                                     elevation: 1590 - Double(i) * 10, time: start.addingTimeInterval(600 + Double(i) * 10)))
        }
        return TrackDetail(track: track, points: points)
    }

    // MARK: - Invert

    func testInvertingReversesTheFixesAndRenumbersTheSegments() {
        let original = ride
        let inverted = original.inverted()

        XCTAssertNotEqual(inverted.track.id, original.track.id, "a new track")
        XCTAssertEqual(inverted.track.name, "Ride")
        XCTAssertEqual(inverted.track.color, "Blue")
        XCTAssertEqual(inverted.points.map(\.coordinate), original.points.map(\.coordinate).reversed())
        XCTAssertEqual(inverted.points.map(\.seq), Array(0..<20))
        XCTAssertEqual(inverted.points.map(\.segment), Array(repeating: 0, count: 10) + Array(repeating: 1, count: 10),
                       "the last recorded segment is now the first")
        XCTAssertEqual(inverted.points.first?.elevation, 1500, "each fix keeps its own elevation")
        XCTAssertEqual(inverted.points.map(\.trackID), Array(repeating: inverted.track.id, count: 20))
        XCTAssertEqual(original.points.count, 20, "the original is untouched")
    }

    // MARK: - Split

    func testSplittingSharesTheCutPointSoNeitherHalfHasAGap() throws {
        let original = ride
        let (first, second) = try XCTUnwrap(original.split(at: 7))

        XCTAssertEqual(first.track.name, "Ride 1")
        XCTAssertEqual(second.track.name, "Ride 2")
        XCTAssertEqual(first.points.count, 8)
        XCTAssertEqual(second.points.count, 13)
        XCTAssertEqual(first.points.last?.coordinate, original.points[7].coordinate)
        XCTAssertEqual(second.points.first?.coordinate, original.points[7].coordinate)
        XCTAssertEqual(first.points.map(\.seq), Array(0..<8))
        XCTAssertEqual(second.points.map(\.seq), Array(0..<13))
        XCTAssertEqual(second.points.map(\.segment).max(), 1, "the break survives in the half that has it")
        XCTAssertNotEqual(first.track.id, second.track.id)
    }

    func testSplittingAtEitherEndIsRefused() {
        XCTAssertNil(ride.split(at: 0))
        XCTAssertNil(ride.split(at: 19))
        XCTAssertNil(ride.split(at: 40))
    }

    func testTheNearestFixToAClick() {
        let detail = ride
        XCTAssertEqual(detail.nearestPointIndex(to: Coordinate(lat: 40.00271, lon: -105.00001)), 3)
        XCTAssertEqual(detail.nearestPointIndex(to: Coordinate(lat: 40.0081, lon: -104.9893)), 19)
        XCTAssertNil(TrackDetail(track: Track(name: "Empty"), points: []).nearestPointIndex(to: .init(lat: 0, lon: 0)))
    }

    // MARK: - Join

    func testJoiningKeepsEachRideAsItsOwnSegments() throws {
        let a = ride
        let (b1, b2) = try XCTUnwrap(ride.split(at: 5))
        let joined = a.joined(with: [b1, b2])

        XCTAssertEqual(joined.track.name, "Ride")
        XCTAssertEqual(joined.points.count, 20 + 6 + 15)
        XCTAssertEqual(joined.points.map(\.seq), Array(joined.points.indices))
        XCTAssertEqual(joined.segments.count, 2 + 1 + 2, "no straight run from one ride's end to the next's start")
        XCTAssertEqual(Set(joined.points.map(\.trackID)), [joined.track.id])
        XCTAssertEqual(joined.points[20].coordinate, b1.points[0].coordinate)
    }

    func testJoiningWithNothingIsACopy() {
        let original = ride
        let copy = original.joined(with: [])
        XCTAssertNotEqual(copy.track.id, original.track.id)
        XCTAssertEqual(copy.points.map(\.coordinate), original.points.map(\.coordinate))
        XCTAssertEqual(copy.points.map(\.segment), original.points.map(\.segment))
    }

    // MARK: - Simplify

    func testSimplifyingKeepsTheCornerAndEachFixesOwnTime() {
        let original = ride
        let thin = original.simplified(atMost: 4)

        XCTAssertLessThanOrEqual(thin.points.count, 4)
        XCTAssertEqual(thin.points.first?.coordinate, original.points.first?.coordinate)
        XCTAssertEqual(thin.points.last?.coordinate, original.points.last?.coordinate)
        XCTAssertEqual(thin.points.first?.time, start, "a survivor keeps its own time")
        XCTAssertEqual(thin.points.map(\.seq), Array(thin.points.indices))
        XCTAssertEqual(thin.segments.count, 2, "the break stays where it was")
    }

    func testSimplifyingASmallTrackIsACopy() {
        let original = ride
        let same = original.simplified(atMost: 10_000)
        XCTAssertEqual(same.points.map(\.coordinate), original.points.map(\.coordinate))
    }

    // MARK: - Statistics

    func testStatisticsReadTheClockAndTheAltimeter() {
        let stats = TrackStatistics(ride)
        // Nine legs of about a hundred metres north, nine of about 102 m
        // east; the gap between segments is not ridden.
        XCTAssertEqual(stats.distance, 1821, accuracy: 20)
        XCTAssertEqual(stats.elapsed, 690, "first fix to last, lunch included")
        XCTAssertEqual(stats.moving, 180, "the ten-minute gap between segments is not moving")
        XCTAssertEqual(try XCTUnwrap(stats.movingSpeed), 10.1, accuracy: 0.2)
        XCTAssertEqual(stats.ascent, 90)
        XCTAssertEqual(stats.descent, 90)
    }

    func testAnInvertedRideTookAsLongAndClimbedTheOtherWay() {
        let forward = TrackStatistics(ride)
        let backward = TrackStatistics(ride.inverted())
        XCTAssertEqual(backward.elapsed, forward.elapsed)
        XCTAssertEqual(backward.moving, forward.moving)
        XCTAssertEqual(backward.ascent, forward.descent)
        XCTAssertEqual(backward.descent, forward.ascent)
    }

    func testSimplifyingNeverLeavesASegmentAsASingleFix() throws {
        // Three segments, a tiny budget: every segment keeps its ends.
        let (a, b) = try XCTUnwrap(ride.split(at: 5))
        let three = a.joined(with: [b])
        XCTAssertEqual(three.segments.count, 3)
        let thin = three.simplified(atMost: 3)
        XCTAssertEqual(thin.segments.count, 3)
        XCTAssertTrue(thin.segments.allSatisfy { $0.count >= 2 })
        XCTAssertGreaterThan(TrackStatistics(thin).distance, 0)
    }

    func testStoppedTimeIsNotMovingTime() {
        var detail = ride
        // Sitting still for a minute between fix 3 and fix 4.
        for i in 4..<detail.points.count {
            detail.points[i].time = detail.points[i].time?.addingTimeInterval(60)
        }
        detail.points.insert(TrackPoint(trackID: detail.track.id, seq: 3, segment: 0,
                                        lat: detail.points[3].lat, lon: detail.points[3].lon,
                                        time: detail.points[3].time?.addingTimeInterval(60)), at: 4)
        for i in detail.points.indices { detail.points[i].seq = i }
        let stats = TrackStatistics(detail)
        XCTAssertEqual(stats.elapsed, 750)
        XCTAssertEqual(stats.moving, 180, "the minute at rest is not counted")
    }

    func testAltimeterJitterIsNotAClimb() {
        var detail = ride
        for i in detail.points.indices { detail.points[i].elevation = 1500 + Double(i % 2) * 3 }
        let stats = TrackStatistics(detail)
        XCTAssertEqual(stats.ascent, 0, "three metres up and down is noise")
        XCTAssertEqual(stats.descent, 0)
    }

    func testATrackWithoutAClockOrAltimeterReportsOnlyItsLength() {
        var detail = ride
        for i in detail.points.indices {
            detail.points[i].time = nil
            detail.points[i].elevation = nil
        }
        let stats = TrackStatistics(detail)
        XCTAssertGreaterThan(stats.distance, 0)
        XCTAssertNil(stats.elapsed)
        XCTAssertNil(stats.moving)
        XCTAssertNil(stats.movingSpeed)
        XCTAssertNil(stats.ascent)
        XCTAssertNil(stats.descent)
    }
}
