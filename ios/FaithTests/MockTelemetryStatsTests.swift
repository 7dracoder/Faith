import XCTest
@testable import Faith

final class MockTelemetryStatsTests: XCTestCase {
    private func round(
        _ participant: String,
        _ mode: RoundMode,
        _ seconds: Double,
        success: Bool = true,
        practice: Bool = false
    ) -> RoundResult {
        RoundResult(
            id: UUID(),
            participantId: participant,
            mode: mode,
            objectLabel: "mug",
            durationSeconds: seconds,
            success: success,
            isPractice: practice,
            headTrackingUsed: false,
            placement: .manualTap,
            startedAt: Date(),
            appVersion: "test"
        )
    }

    func testStatsRules() {
        let rounds = [
            round("P01", .finder, 4),
            round("P02", .finder, 6),
            round("P02", .finder, 5),
            round("P03", .finder, 100, practice: true),   // excluded
            round("P04", .finder, 1, success: false)      // excluded
        ]
        let stats = MockTelemetry.computeStats(rounds)

        XCTAssertEqual(stats.participants, 2)
        XCTAssertEqual(stats.finderRounds, 3)
        XCTAssertEqual(stats.medianFinderSeconds ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(stats.meanFinderSeconds ?? 0, 5, accuracy: 1e-9)
    }

    func testNoValidRoundsGivesNilTimes() {
        let stats = MockTelemetry.computeStats([round("P01", .finder, 4, practice: true)])
        XCTAssertEqual(stats.participants, 0)
        XCTAssertNil(stats.medianFinderSeconds)
        XCTAssertNil(stats.meanFinderSeconds)
    }

    func testObjectSightingJSONIsCamelCase() throws {
        let sighting = ObjectSighting(
            id: UUID(),
            participantId: "P07",
            objectLabel: "blue mug",
            utterance: "where's my mug",
            seenAt: Date(),
            x: 0.25,
            y: -0.25,
            z: -0.55,
            placement: .lidarDepth,
            confidence: 0.92
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(sighting)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["participantId"])
        XCTAssertNotNil(json["objectLabel"])
        XCTAssertNotNil(json["seenAt"])
        XCTAssertEqual(json["placement"] as? String, "lidarDepth")
    }

    func testMockTelemetryStoresSightingsIdempotently() async {
        let mock = MockTelemetry()
        let sighting = ObjectSighting(
            id: UUID(),
            participantId: "P07",
            objectLabel: "blue mug",
            utterance: "where's my mug",
            seenAt: Date(),
            x: 0.25,
            y: -0.25,
            z: -0.55,
            placement: .lidarDepth,
            confidence: nil
        )
        await mock.reportSighting(sighting)
        await mock.reportSighting(sighting)
        XCTAssertEqual(mock.sightings.count, 1)
        XCTAssertEqual(mock.sightings.first, sighting)
    }
}
