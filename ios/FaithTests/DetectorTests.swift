import XCTest
import simd
@testable import Faith

final class DetectorCueTests: XCTestCase {
    private let base = CueParameters(intervalSeconds: 0.5, gain: 0.9, isOnTarget: false)

    func testHysteresis() {
        XCTAssertFalse(DetectorCue.isActive(phoneDistance: 0.33, wasActive: false))
        XCTAssertTrue(DetectorCue.isActive(phoneDistance: 0.29, wasActive: false))
        // Once active, it stays on until past the exit radius.
        XCTAssertTrue(DetectorCue.isActive(phoneDistance: 0.35, wasActive: true))
        XCTAssertFalse(DetectorCue.isActive(phoneDistance: 0.40, wasActive: true))
    }

    func testClosenessRange() {
        XCTAssertEqual(DetectorCue.closeness(phoneDistance: 0.30), 0, accuracy: 1e-5)
        XCTAssertEqual(DetectorCue.closeness(phoneDistance: 0.05), 1, accuracy: 1e-5)
        XCTAssertEqual(DetectorCue.closeness(phoneDistance: 0.0), 1, accuracy: 1e-5)
        XCTAssertEqual(DetectorCue.closeness(phoneDistance: 0.5), 0, accuracy: 1e-5)
    }

    func testPulseSpeedsUpAsThePhoneGetsCloser() {
        let edge = DetectorCue.adjust(base, phoneDistance: 0.29)
        let halfway = DetectorCue.adjust(base, phoneDistance: 0.17)
        let touching = DetectorCue.adjust(base, phoneDistance: 0.04)

        XCTAssertGreaterThan(edge.intervalSeconds, halfway.intervalSeconds)
        XCTAssertGreaterThan(halfway.intervalSeconds, touching.intervalSeconds)
        XCTAssertEqual(touching.intervalSeconds, Config.detectorFastestIntervalSeconds, accuracy: 1e-6)
        XCTAssertFalse(halfway.isOnTarget)
        XCTAssertTrue(touching.isOnTarget)
    }
}

final class ReachLockTests: XCTestCase {
    private let target = SIMD3<Float>(0, -0.3, -0.6)

    func testWalkingFarAwayDoesNotLock() {
        let ears = SIMD3<Float>(0, 0.3, 1.0)
        XCTAssertNil(ReachLock.update(locked: nil, liveEars: ears, phone: ears, target: target))
    }

    func testLocksWithinArmsReach() {
        let ears = SIMD3<Float>(0, 0.3, -0.1)   // 0.5 m from the object
        XCTAssertEqual(ReachLock.update(locked: nil, liveEars: ears, phone: ears, target: target), ears)
    }

    func testStaysLockedWhileThePhoneReaches() {
        let locked = SIMD3<Float>(0, 0.3, -0.1)
        let reachingPhone = SIMD3<Float>(0, -0.2, -0.55)
        let movedEars = SIMD3<Float>(0, 0.15, -0.55)
        let result = ReachLock.update(locked: locked, liveEars: movedEars, phone: reachingPhone, target: target)
        XCTAssertEqual(result, locked)
    }

    func testUnlocksWhenWalkingAway() {
        let locked = SIMD3<Float>(0, 0.3, -0.1)
        let walkedAwayPhone = SIMD3<Float>(0, 0, 0.6)   // 1.2 m from the object
        XCTAssertNil(ReachLock.update(locked: locked, liveEars: walkedAwayPhone, phone: walkedAwayPhone, target: target))
    }
}

/// End to end through the coordinator with the fake phone.
@MainActor
final class ReachingTests: XCTestCase {
    func testReachingPhoneDoesNotMoveTheSoundAndTurnsOnTheDetector() async throws {
        let perception = MockPerceptionService()
        let audio = MockSpatialAudio()
        let environment = AppEnvironment(
            perception: perception,
            locator: MockObjectLocator(),
            headTracker: MockHeadTracker(),
            audio: audio,
            voice: MockVoiceListener(),
            telemetry: MockTelemetry()
        )
        let coordinator = FinderCoordinator(environment: environment)
        coordinator.onAppear()
        try await Task.sleep(nanoseconds: 1_300_000_000)

        // Mock tap places the object at (0.4, -0.3, -0.5); phone at the origin, ears 0.35 m above.
        coordinator.placeTargetAtTap(CGPoint(x: 10, y: 10))
        try await Task.sleep(nanoseconds: 200_000_000)
        let earsBeforeReach = try XCTUnwrap(audio.lastListener?.position)

        // Reach: the phone moves to ~7 cm from the object.
        perception.bodyPose = BodyPose(
            position: SIMD3<Float>(0.35, -0.28, -0.45),
            forward: SIMD3<Float>(0, 0, -1)
        )
        try await Task.sleep(nanoseconds: 200_000_000)

        let earsDuringReach = try XCTUnwrap(audio.lastListener?.position)
        XCTAssertEqual(simd_distance(earsBeforeReach, earsDuringReach), 0, accuracy: 1e-4)

        let cue = try XCTUnwrap(audio.lastCue)
        XCTAssertTrue(cue.isOnTarget)
        XCTAssertLessThan(cue.intervalSeconds, 0.12)
        coordinator.onDisappear()
    }
}
