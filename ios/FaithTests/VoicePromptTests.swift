import XCTest
@testable import Faith

final class VoicePromptTests: XCTestCase {
    func testFixedClipNames() {
        XCTAssertEqual(VoicePrompt.searching.clipName, "voice_searching")
        XCTAssertEqual(VoicePrompt.notFoundTurn.clipName, "voice_not_found_turn")
        XCTAssertEqual(VoicePrompt.foundNavigating.clipName, "voice_found_navigating")
        XCTAssertEqual(VoicePrompt.navigating.clipName, "voice_navigating")
    }

    func testAllClipNamesAreUnique() {
        let names = VoicePrompt.allClipNames
        XCTAssertEqual(names.count, 4)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testSightingRoundTripsThroughJSON() throws {
        let sighting = ObjectSighting(
            id: UUID(),
            participantId: "P01",
            objectLabel: "blue mug",
            utterance: "where's my mug",
            seenAt: Date(timeIntervalSince1970: 1_791_000_000),
            x: 0.25,
            y: -0.25,
            z: -0.55,
            placement: .lidarDepth,
            confidence: 0.9
        )
        let data = try JSONEncoder().encode(sighting)
        let decoded = try JSONDecoder().decode(ObjectSighting.self, from: data)
        XCTAssertEqual(decoded, sighting)
    }

    func testMockTelemetryAcceptsSightingsByDefault() async {
        let telemetry: TelemetryReporting = MockTelemetry()
        let sighting = ObjectSighting(
            id: UUID(),
            participantId: "P01",
            objectLabel: "keys",
            utterance: "find my keys",
            seenAt: Date(),
            x: 0,
            y: 0,
            z: -1,
            placement: .fixedDepthFallback,
            confidence: nil
        )
        await telemetry.reportSighting(sighting)
    }
}
