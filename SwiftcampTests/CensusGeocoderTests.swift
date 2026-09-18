import XCTest
@testable import Swiftcamp

/// The Census reply as it arrived on 2026-09-18, and what the field shows
/// for it. Pinned so a change in their shape is caught here, not by a
/// rider with an empty list.
final class CensusGeocoderTests: XCTestCase {
    private let reply = """
    {"result":{"input":{"address":{"address":"1234 W Elkhorn Ave Estes Park CO"}},
     "addressMatches":[{"tigerLine":{"side":"R","tigerLineId":"181462054"},
       "coordinates":{"x":-105.539653483148,"y":40.381683978633},
       "addressComponents":{"zip":"80517","streetName":"ELKHORN","preType":"","city":"ESTES PARK","preDirection":"W","suffixDirection":"","fromAddress":"1200","state":"CO","suffixType":"AVE","toAddress":"1298","suffixQualifier":"","preQualifier":""},
       "matchedAddress":"1234 W ELKHORN AVE, ESTES PARK, CO, 80517"}]}}
    """

    func testAMatchBecomesAResultOutOfCapitals() throws {
        let results = try CensusGeocoder.results(from: Data(reply.utf8))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "1234 W Elkhorn Ave")
        XCTAssertEqual(results[0].detail, "Estes Park, CO, 80517")
        XCTAssertEqual(results[0].kind, .address)
        XCTAssertEqual(results[0].coordinate.lat, 40.3817, accuracy: 0.0001)
        XCTAssertEqual(results[0].coordinate.lon, -105.5397, accuracy: 0.0001)
    }

    func testNoMatchesIsAnEmptyList() throws {
        let empty = #"{"result":{"input":{"address":{"address":"Estes Park CO"}},"addressMatches":[]}}"#
        XCTAssertEqual(try CensusGeocoder.results(from: Data(empty.utf8)), [])
    }

    /// Only a query that starts with a house number is worth a round trip.
    func testOnlyAddressesAreAsked() {
        XCTAssertTrue(CensusGeocoder.looksLikeAddress("1234 W Elkhorn Ave, Estes Park"))
        XCTAssertFalse(CensusGeocoder.looksLikeAddress("Estes Park"))
        XCTAssertFalse(CensusGeocoder.looksLikeAddress("40.3772, -105.5217"))
        XCTAssertFalse(CensusGeocoder.looksLikeAddress("Trail Ridge Road"))
    }
}
