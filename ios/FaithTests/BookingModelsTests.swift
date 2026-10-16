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
}
