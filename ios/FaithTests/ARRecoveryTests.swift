import XCTest
@testable import Faith

final class ARRecoveryTests: XCTestCase {
    func testBacksOffThenSettles() {
        XCTAssertEqual(ARRecovery.delaySeconds(attempt: 1), 1)
        XCTAssertEqual(ARRecovery.delaySeconds(attempt: 2), 2)
        XCTAssertEqual(ARRecovery.delaySeconds(attempt: 3), 4)
        XCTAssertEqual(ARRecovery.delaySeconds(attempt: 9), 5)
    }

    func testFirstTryKeepsTheWorld() {
        XCTAssertFalse(ARRecovery.shouldResetWorld(attempt: 1))
        XCTAssertTrue(ARRecovery.shouldResetWorld(attempt: 2))
        XCTAssertTrue(ARRecovery.shouldResetWorld(attempt: 5))
    }

    func testStalledOnlyWhileRunningAndSilent() {
        let now = Date()
        let recent = now.addingTimeInterval(-1)
        let old = now.addingTimeInterval(-10)
        XCTAssertFalse(ARRecovery.isStalled(lastFrameAt: recent, now: now, isRunning: true))
        XCTAssertTrue(ARRecovery.isStalled(lastFrameAt: old, now: now, isRunning: true))
        XCTAssertFalse(ARRecovery.isStalled(lastFrameAt: old, now: now, isRunning: false))
        XCTAssertFalse(ARRecovery.isStalled(lastFrameAt: nil, now: now, isRunning: true))
        // Restart grace: lastFrameAt set slightly in the future.
        XCTAssertFalse(ARRecovery.isStalled(lastFrameAt: now.addingTimeInterval(2), now: now, isRunning: true))
    }
}

/// A fresh AR world ends the round: the target's position means nothing anymore.
@MainActor
final class WorldResetTests: XCTestCase {
    func testWorldResetEndsTheRound() async throws {
        let environment = AppEnvironment(
            perception: MockPerceptionService(),
            locator: MockObjectLocator(),
            headTracker: MockHeadTracker(),
            audio: MockSpatialAudio(),
            voice: MockVoiceListener(),
            telemetry: MockTelemetry()
        )
        let coordinator = FinderCoordinator(environment: environment)
        coordinator.onAppear()
        try await Task.sleep(nanoseconds: 1_300_000_000)
        coordinator.placeTargetAtTap(CGPoint(x: 10, y: 10))
        guard case .guiding = coordinator.state else {
            XCTFail("expected guiding, got \(coordinator.state)")
            return
        }

        NotificationCenter.default.post(name: .finderARWorldDidReset, object: nil)
        try await Task.sleep(nanoseconds: 200_000_000)

        guard case .error(.trackingLimited) = coordinator.state else {
            XCTFail("expected error after reset, got \(coordinator.state)")
            return
        }
        XCTAssertNil(coordinator.elapsedSeconds)
        coordinator.onDisappear()
    }
}
