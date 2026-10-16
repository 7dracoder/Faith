import XCTest
@testable import Faith

final class BookingModelsTests: XCTestCase {
    func testAccessPreferencesUseBackendFieldNames() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(AccessPreferences(stepFree: true, audioDescription: true))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["step_free"] as? Bool, true)
        XCTAssertEqual(object["audio_description"] as? Bool, true)
        XCTAssertNil(object["stepFree"])
    }

    func testEveryTicketCategoryIsAvailable() {
        XCTAssertEqual(Set(TicketCategory.allCases.map(\.rawValue)), ["all", "flight", "train", "bus", "cinema", "event"])
    }

    func testSearchDateUsesISOCalendarFormat() {
        let search = TicketSearch()
        XCTAssertNotNil(DateFormatter.faithDate.date(from: search.date))
        XCTAssertEqual(search.passengers, 1)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: Data(json.utf8))
    }

    func testLiveResultsDecodeAndReadAsOneLine() throws {
        let results = try decode(LiveResults.self, """
        {"provider": "Google Flights", "source": "https://www.google.com/travel/flights?q=x", "verified": false, "cached": false,
         "notice": "Live results", "options": [
          {"option_id": "live-0a1b2c3d", "provider": "Google Flights", "what": "JetBlue, nonstop", "departs": "9:30 AM",
           "arrives": "11:24 AM", "duration": "2 hr 54 min", "price": "$183"},
          {"option_id": "live-0a1b2c3e", "provider": "Fandango", "what": "Clayface at AMC 34th Street", "departs": "10:00a",
           "arrives": null, "duration": null, "price": null}]}
        """)
        XCTAssertEqual(results.options.count, 2)
        XCTAssertEqual(results.options[0].spoken, "Google Flights: JetBlue, nonstop, 9:30 AM, $183")
        XCTAssertEqual(results.options[1].spoken, "Fandango: Clayface at AMC 34th Street, 10:00a, price not shown")
    }

    func testSavedTripOnlyOpensSecureProviderLinks() throws {
        let reply = try decode(TripReply.self, """
        {"saved": true, "paid": false, "say": "I saved this trip. Faith can't pay for tickets yet, so I've kept the provider link to finish booking.",
         "trip": {"provider": "Wanderu", "what": "Amtrak Northeast Regional", "departs": "6:45 PM", "price": "$126.00",
                  "link": "https://www.wanderu.com/en-us/depart/Boston/New%20York/2026-10-24/?travelMode=train"}}
        """)
        XCTAssertEqual(reply.trip.providerURL?.host, "www.wanderu.com")
        XCTAssertTrue(reply.say.contains("can't pay"))
        let insecure = SavedTrip(provider: "X", what: "x", departs: "1 PM", price: nil, link: "http://example.com")
        XCTAssertNil(insecure.providerURL)
    }
}
