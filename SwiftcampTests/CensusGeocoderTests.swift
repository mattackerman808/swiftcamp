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

    func testAStreetSuffixComesOutOfCapitalsAndADirectionDoesNot() throws {
        let json = """
        {"result":{"addressMatches":[{"matchedAddress":"472 N JUNIPER ST, ORANGE, CA, 92866",
        "coordinates":{"x":-117.85,"y":33.79}}]}}
        """
        let results = try CensusGeocoder.results(from: Data(json.utf8))
        XCTAssertEqual(results.first?.name, "472 N Juniper St")
        XCTAssertEqual(results.first?.detail, "Orange, CA, 92866")
    }

    func testNoMatchesIsAnEmptyList() throws {
        let empty = #"{"result":{"input":{"address":{"address":"Estes Park CO"}},"addressMatches":[]}}"#
        XCTAssertEqual(try CensusGeocoder.results(from: Data(empty.utf8)), [])
    }

    /// An address that names no town or zip gets the map's town appended
    /// before it goes out, because Census answers it with nothing otherwise.
    func testAnAddressWithoutAPlaceIsRecognised() {
        XCTAssertFalse(CensusGeocoder.namesAPlace("1234 W Elkhorn Ave"))
        XCTAssertTrue(CensusGeocoder.namesAPlace("1234 W Elkhorn Ave, Estes Park, CO"))
        XCTAssertTrue(CensusGeocoder.namesAPlace("1234 W Elkhorn Ave 80517"))
        XCTAssertFalse(CensusGeocoder.namesAPlace("1234 W Elkhorn Ave, Estes Park"), "a town alone is not enough for Census either")
    }

    /// Only a query that starts with a house number is worth a round trip.
    func testABareAddressIsAskedAsTypedThenInTheTownThenTheState() {
        XCTAssertEqual(CensusGeocoder.attempts(for: "472 n juniper", near: "Denver, CO"),
                       ["472 n juniper", "472 n juniper, Denver, CO", "472 n juniper, CO"])
        // One that says where is asked once, as typed.
        XCTAssertEqual(CensusGeocoder.attempts(for: "472 n juniper st, orange, ca", near: "Denver, CO"),
                       ["472 n juniper st, orange, ca"])
        XCTAssertEqual(CensusGeocoder.attempts(for: "472 n juniper, 92866", near: "Denver, CO"),
                       ["472 n juniper, 92866"])
        // Nowhere to bias towards, and not an address.
        XCTAssertEqual(CensusGeocoder.attempts(for: "472 n juniper", near: nil), ["472 n juniper"])
        XCTAssertEqual(CensusGeocoder.attempts(for: "Estes Park", near: "Denver, CO"), ["Estes Park"])
    }

    func testTheHintSaysHowToFindAnAddressElsewhere() {
        XCTAssertNil(SearchModel.hint(matchedAt: 0))
        XCTAssertNil(SearchModel.hint(matchedAt: 1))
        XCTAssertEqual(SearchModel.hint(matchedAt: 2), "Found in the map's state. For one elsewhere, add its town or zip.")
        XCTAssertEqual(SearchModel.hint(matchedAt: nil), "No address found near the map. For one elsewhere, add its town or zip.")
    }

    func testOnlyAddressesAreAsked() {
        XCTAssertTrue(CensusGeocoder.looksLikeAddress("1234 W Elkhorn Ave, Estes Park"))
        XCTAssertFalse(CensusGeocoder.looksLikeAddress("Estes Park"))
        XCTAssertFalse(CensusGeocoder.looksLikeAddress("40.3772, -105.5217"))
        XCTAssertFalse(CensusGeocoder.looksLikeAddress("Trail Ridge Road"))
    }
}
