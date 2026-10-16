import XCTest
import simd
@testable import Faith

/// Records results and samples so tests can inspect what the coordinator uploaded.
private final class SpyTelemetry: TelemetryReporting {
    var results: [RoundResult] = []
    var sampleBatches: [[RoundSample]] = []
    let pendingCount = 0

    func report(_ result: RoundResult) async {
        results.append(result)
    }

    func fetchStats() async -> StudyStats? {
        return nil
    }

    func ping() async -> Bool {
        return true
    }

    func reportSamples(_ samples: [RoundSample]) async {
        sampleBatches.append(samples)
    }
}

/// Telemetry that never implemented the stretch: must still compile and do nothing.
private final class LegacyTelemetry: TelemetryReporting {
    let pendingCount = 0
    func report(_ result: RoundResult) async {}
    func fetchStats() async -> StudyStats? { return nil }
    func ping() async -> Bool { return true }
}

@MainActor
final class RoundSampleTests: XCTestCase {
    private var telemetry = SpyTelemetry()

    private func makeReadyCoordinator() async throws -> FinderCoordinator {
        telemetry = SpyTelemetry()
        let environment = AppEnvironment(
            perception: MockPerceptionService(),
            locator: MockObjectLocator(),
            headTracker: MockHeadTracker(),
            audio: MockSpatialAudio(),
            voice: MockVoiceListener(),
            telemetry: telemetry
        )
        let coordinator = FinderCoordinator(environment: environment)
        coordinator.onAppear()
        try await Task.sleep(nanoseconds: 1_300_000_000)
        return coordinator
    }

    func testFinderRoundUploadsSamplesWithResult() async throws {
        let coordinator = try await makeReadyCoordinator()
        coordinator.placeTargetAtTap(CGPoint(x: 10, y: 10))

        try await Task.sleep(nanoseconds: 600_000_000)
        coordinator.markFound()
        try await Task.sleep(nanoseconds: 100_000_000)

        let result = try XCTUnwrap(telemetry.results.first)
        let samples = try XCTUnwrap(telemetry.sampleBatches.first)
        XCTAssertGreaterThanOrEqual(samples.count, 3)
        for sample in samples {
            XCTAssertEqual(sample.roundId, result.id)
            XCTAssertEqual(sample.mode, .finder)
        }
        let times = samples.map { $0.secondsSinceStart }
        XCTAssertEqual(times, times.sorted())
        coordinator.onDisappear()
    }

    func testCancelledRoundUploadsNothing() async throws {
        let coordinator = try await makeReadyCoordinator()
        coordinator.placeTargetAtTap(CGPoint(x: 10, y: 10))
        try await Task.sleep(nanoseconds: 400_000_000)

        coordinator.cancel()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(telemetry.results.isEmpty)
        XCTAssertTrue(telemetry.sampleBatches.isEmpty)
        coordinator.onDisappear()
    }

    func testMakeSampleAngleSignAndDistance() {
        let listener = ListenerPose(
            position: SIMD3<Float>(0, 0, 0),
            forward: SIMD3<Float>(0, 0, -1),
            up: SIMD3<Float>(0, 1, 0)
        )
        let head = HeadRotation(yawRadians: Float.pi / 6, pitchRadians: 0)

        let sample = FinderCoordinator.makeSample(
            roundId: UUID(),
            mode: .finder,
            secondsSinceStart: 1.5,
            listener: listener,
            head: head,
            target: SIMD3<Float>(0.3, -0.2, -0.4)   // ahead and to the right
        )

        XCTAssertGreaterThan(sample.angleDegrees, 0)
        XCTAssertEqual(sample.distanceMeters, 0.5, accuracy: 1e-4)
        XCTAssertEqual(sample.headYawDegrees, 30, accuracy: 1e-3)
    }

    func testRoundSampleJSONIsCamelCase() throws {
        let sample = RoundSample(
            roundId: UUID(),
            secondsSinceStart: 1.2,
            mode: .finder,
            angleDegrees: -14.5,
            distanceMeters: 0.42,
            headYawDegrees: 12
        )
        let data = try JSONEncoder().encode(sample)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["roundId"])
        XCTAssertNotNil(json["secondsSinceStart"])
        XCTAssertEqual(json["mode"] as? String, "finder")
    }

    func testDefaultReportSamplesIsNoOp() async {
        let legacy = LegacyTelemetry()
        await legacy.reportSamples([])
    }
}
