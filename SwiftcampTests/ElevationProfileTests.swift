import XCTest
@testable import Swiftcamp

/// Where a profile samples, what it skips, and how it counts a climb.
final class ElevationProfileTests: XCTestCase {
    private func c(_ lat: Double, _ lon: Double) -> Coordinate { Coordinate(lat: lat, lon: lon) }

    func testStationsAreEvenlySpacedAndIncludeBothEnds() {
        // About 1,112 m north, then 1,112 m north again.
        let path = [c(40.0, -105.0), c(40.01, -105.0), c(40.02, -105.0)]
        let stations = ElevationProfile.stations(along: path, step: 100)
        XCTAssertEqual(stations.first?.distance, 0)
        XCTAssertEqual(stations.first?.coordinate, path[0])
        XCTAssertEqual(stations.last?.coordinate, path[2])
        XCTAssertEqual(try XCTUnwrap(stations.last?.distance), 2224, accuracy: 5)
        XCTAssertEqual(stations.count, 24)
        for (a, b) in zip(stations, stations.dropFirst().dropLast()) {
            XCTAssertEqual(b.distance - a.distance, 100, accuracy: 1e-6)
        }
        XCTAssertEqual(stations[11].coordinate.lat, 40.0099, accuracy: 0.0002, "interpolated along the leg")
    }

    func testStationsNeverExceedTheLimit() {
        let path = [c(40.0, -105.0), c(41.0, -105.0)]   // 111 km
        let stations = ElevationProfile.stations(along: path, step: 30, limit: 500)
        XCTAssertLessThanOrEqual(stations.count, 502)
        XCTAssertGreaterThan(stations.count, 400)
    }

    func testAnEmptyPathHasNoStations() {
        XCTAssertTrue(ElevationProfile.stations(along: []).isEmpty)
        XCTAssertEqual(ElevationProfile.stations(along: [c(40, -105)]).count, 1)
    }

    func testUnknownHeightsAreGapsNotZeros() {
        let stations = ElevationProfile.stations(along: [c(40.0, -105.0), c(40.01, -105.0)], step: 300)
        var heights: [Double?] = stations.map { _ in 1500.0 }
        heights[1] = nil
        let profile = ElevationProfile.make(stations: stations, elevations: heights)
        XCTAssertEqual(profile.samples.count, stations.count - 1)
        XCTAssertEqual(profile.minimum, 1500)
        XCTAssertEqual(profile.ascent, 0)
    }

    func testARecordedTrackUsesItsOwnHeights() {
        let track = Track(name: "Ride")
        let detail = TrackDetail(track: track, points: [
            TrackPoint(trackID: track.id, seq: 0, lat: 40.00, lon: -105, elevation: 1500),
            TrackPoint(trackID: track.id, seq: 1, lat: 40.01, lon: -105, elevation: 1520),
            TrackPoint(trackID: track.id, seq: 2, segment: 1, lat: 40.02, lon: -105, elevation: 1510),
        ])
        let profile = try! XCTUnwrap(ElevationProfile.recorded(detail))
        XCTAssertEqual(profile.samples.map(\.elevation), [1500, 1520, 1510])
        XCTAssertEqual(profile.samples[2].distance, profile.samples[1].distance, "a segment break is not ridden")
        XCTAssertEqual(profile.ascent, 20)
        XCTAssertEqual(profile.descent, 10)

        var bare = detail
        for i in bare.points.indices { bare.points[i].elevation = nil }
        XCTAssertNil(ElevationProfile.recorded(bare), "no heights means the DEM")
    }

    func testClimbIgnoresJitterAndCountsRealRises() {
        XCTAssertEqual(ElevationProfile.climb([1500, 1503, 1500, 1504, 1501]).ascent, 0)
        // Up 10, up 10, down 5, up 15, down 30: every step clears the gate.
        let climb = ElevationProfile.climb([1500, 1510, 1520, 1515, 1530, 1500])
        XCTAssertEqual(climb.ascent, 35)
        XCTAssertEqual(climb.descent, 35)
    }
}
