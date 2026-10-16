import XCTest
@testable import Faith

final class ContractsTests: XCTestCase {
    func testRectCenterAndBaseCenter() {
        let rect = NormalizedRect(minX: 0.2, minY: 0.4, maxX: 0.4, maxY: 0.8)
        XCTAssertEqual(rect.center.x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(rect.center.y, 0.6, accuracy: 1e-9)
        XCTAssertEqual(rect.baseCenter.x, 0.3, accuracy: 1e-9)
        XCTAssertEqual(rect.baseCenter.y, 0.76, accuracy: 1e-9)
    }

    func testRoundResultEncodesCamelCaseForBackend() throws {
        let result = RoundResult(
            id: UUID(),
            participantId: "P07",
            mode: .finder,
            objectLabel: "blue mug",
            durationSeconds: 6.42,
            success: true,
            isPractice: false,
            headTrackingUsed: true,
            placement: .raycastExistingPlane,
            startedAt: Date(timeIntervalSince1970: 1_791_000_000),
            appVersion: "0.1.0"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(result)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["participantId"] as? String, "P07")
        XCTAssertEqual(json["mode"] as? String, "finder")
        XCTAssertEqual(json["placement"] as? String, "raycastExistingPlane")
        XCTAssertNotNil(json["durationSeconds"])
        XCTAssertNotNil(json["headTrackingUsed"])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RoundResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }

    func testParticipantNumberParsing() {
        XCTAssertEqual(FinderCoordinator.participantNumber(from: "P07"), 7)
        XCTAssertEqual(FinderCoordinator.participantNumber(from: "P12"), 12)
        XCTAssertNil(FinderCoordinator.participantNumber(from: "P"))
    }
}
