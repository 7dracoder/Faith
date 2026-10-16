import XCTest
import simd
@testable import Faith

/// Phone gives position, AirPods give direction (anchored to the phone heading
/// captured at calibration). See FinderCoordinator.listenerBody.
final class HeadDirectionTests: XCTestCase {
    private let straightAhead = SIMD3<Float>(0, 0, -1)
    private let right = SIMD3<Float>(1, 0, 0)
    private let rig = ListenerRig.standInFront(backOffsetMeters: 0.35, upOffsetMeters: 0.30)

    private func assertVector(
        _ actual: SIMD3<Float>,
        _ expected: SIMD3<Float>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: 1e-4, file: file, line: line)
    }

    func testWithoutHeadTrackingUsesLivePhoneHeading() {
        let body = BodyPose(position: SIMD3<Float>(1, 0, 2), forward: right)

        let result = FinderCoordinator.listenerBody(
            body: body,
            headingReference: straightAhead,
            headTrackingActive: false
        )

        XCTAssertEqual(result, body)
    }

    func testActiveButNoReferenceYetUsesLivePhoneHeading() {
        let body = BodyPose(position: SIMD3<Float>(1, 0, 2), forward: right)

        let result = FinderCoordinator.listenerBody(
            body: body,
            headingReference: nil,
            headTrackingActive: true
        )

        XCTAssertEqual(result, body)
    }

    func testActiveKeepsLivePositionButReferenceHeading() {
        let body = BodyPose(position: SIMD3<Float>(1, 0, 2), forward: right)

        let result = FinderCoordinator.listenerBody(
            body: body,
            headingReference: straightAhead,
            headTrackingActive: true
        )

        assertVector(result.position, SIMD3<Float>(1, 0, 2))
        assertVector(result.forward, straightAhead)
    }

    /// Turn body, phone and head 90 degrees right together. The AirPods report the
    /// turn and the phone reports it too. It must be counted once (face right),
    /// not twice (face backwards).
    func testTurningPhoneAndHeadTogetherCountsOnce() {
        let turnedBody = BodyPose(position: .zero, forward: right)
        let headTurnedRight = HeadRotation(yawRadians: -Float.pi / 2, pitchRadians: 0)

        let listenerBody = FinderCoordinator.listenerBody(
            body: turnedBody,
            headingReference: straightAhead,
            headTrackingActive: true
        )
        let listener = ListenerPoseMath.compose(body: listenerBody, head: headTurnedRight, rig: rig)

        assertVector(listener.forward, right)
    }

    /// Phone gets bumped on its stand, head stays still: listener direction must not change.
    func testPhoneTurningAloneDoesNotTurnListener() {
        let bumpedBody = BodyPose(position: .zero, forward: right)

        let listenerBody = FinderCoordinator.listenerBody(
            body: bumpedBody,
            headingReference: straightAhead,
            headTrackingActive: true
        )
        let listener = ListenerPoseMath.compose(body: listenerBody, head: .identity, rig: rig)

        assertVector(listener.forward, straightAhead)
    }

    func testHeadTrackingActiveStatuses() {
        XCTAssertTrue(FinderCoordinator.isHeadTrackingActive(.connected))
        XCTAssertTrue(FinderCoordinator.isHeadTrackingActive(.calibrated))
        XCTAssertFalse(FinderCoordinator.isHeadTrackingActive(.disconnected))
        XCTAssertFalse(FinderCoordinator.isHeadTrackingActive(.unavailable))
    }
}

/// Every request recalibrates the head (blind users can't find a Calibrate button).
@MainActor
final class AutoCalibrationTests: XCTestCase {
    private func makeReadyCoordinator() async throws -> (FinderCoordinator, MockHeadTracker) {
        let headTracker = MockHeadTracker()
        let environment = AppEnvironment(
            perception: MockPerceptionService(),
            locator: MockObjectLocator(),
            headTracker: headTracker,
            audio: MockSpatialAudio(),
            voice: MockVoiceListener(),
            telemetry: MockTelemetry()
        )
        let coordinator = FinderCoordinator(environment: environment)
        coordinator.onAppear()

        // Mock tracking turns .normal after 1 s.
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(coordinator.state, .ready)
        // Startup pairs the AirPods and phone references automatically.
        XCTAssertEqual(headTracker.status, .calibrated)
        return (coordinator, headTracker)
    }

    func testVoicePressCalibratesHead() async throws {
        let (coordinator, headTracker) = try await makeReadyCoordinator()
        headTracker.start()   // back to .connected so we can see the press recalibrate

        coordinator.beginVoiceRequest()

        XCTAssertEqual(headTracker.status, .calibrated)
        XCTAssertEqual(coordinator.status.headTracking, .calibrated)
        coordinator.onDisappear()
    }

    func testTypedRequestCalibratesHead() async throws {
        let (coordinator, headTracker) = try await makeReadyCoordinator()
        headTracker.start()

        coordinator.submitTypedRequest("mug")

        XCTAssertEqual(headTracker.status, .calibrated)
        coordinator.onDisappear()
    }

    /// The bug found on device: AirPods and phone references taken at different
    /// moments at startup. Both startup and an AirPods reconnect must re-pair them.
    func testReconnectRecalibratesOnNextFrames() async throws {
        let (coordinator, headTracker) = try await makeReadyCoordinator()

        headTracker.start()   // simulates reconnect: AirPods pick their own reference
        XCTAssertEqual(headTracker.status, .connected)

        // Mock body poses arrive at 30 Hz; retry interval is 0.25 s.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(headTracker.status, .calibrated)
        XCTAssertEqual(coordinator.status.headTracking, .calibrated)
        coordinator.onDisappear()
    }

    func testTapStartingRoundCalibrates() async throws {
        let (coordinator, headTracker) = try await makeReadyCoordinator()
        headTracker.start()

        coordinator.placeTargetAtTap(CGPoint(x: 10, y: 10))

        XCTAssertEqual(headTracker.status, .calibrated)
        coordinator.onDisappear()
    }

    func testTapDuringRoundDoesNotCalibrate() async throws {
        let (coordinator, headTracker) = try await makeReadyCoordinator()
        coordinator.placeTargetAtTap(CGPoint(x: 10, y: 10))
        headTracker.start()   // head turned toward the sound; must not be re-zeroed

        coordinator.placeTargetAtTap(CGPoint(x: 50, y: 10))

        XCTAssertEqual(headTracker.status, .connected)
        coordinator.onDisappear()
    }

    func testIgnoredRequestDoesNotCalibrate() async throws {
        let (coordinator, headTracker) = try await makeReadyCoordinator()
        coordinator.submitTypedRequest("mug")
        coordinator.approvePendingFrame()         // now .locating
        headTracker.start()                       // back to .connected

        coordinator.beginVoiceRequest()           // ignored while locating

        XCTAssertEqual(headTracker.status, .connected)
        coordinator.onDisappear()
    }
}

/// Voice stub whose transcript the test controls.
private final class ScriptedVoice: VoiceCommandListening {
    var onPartialTranscript: ((String) -> Void)?
    var transcript = ""

    func requestAuthorization() async -> Bool {
        return true
    }

    func startListening() throws {
    }

    func stopListening() async -> String {
        return transcript
    }
}

/// "Hold the screen, say calibrate" works mid-round without resetting the round.
@MainActor
final class VoiceCalibrateTests: XCTestCase {
    private var voice = ScriptedVoice()
    private var headTracker = MockHeadTracker()

    private func makeReadyCoordinator() async throws -> FinderCoordinator {
        voice = ScriptedVoice()
        headTracker = MockHeadTracker()
        let environment = AppEnvironment(
            perception: MockPerceptionService(),
            locator: MockObjectLocator(),
            headTracker: headTracker,
            audio: MockSpatialAudio(),
            voice: voice,
            telemetry: MockTelemetry()
        )
        let coordinator = FinderCoordinator(environment: environment)
        coordinator.onAppear()
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(coordinator.state, .ready)
        return coordinator
    }

    private func roundID(_ state: FinderState) -> UUID? {
        if case .guiding(_, let round) = state {
            return round.id
        }
        return nil
    }

    func testCalibrateCommandWords() {
        XCTAssertTrue(FinderCoordinator.isCalibrateCommand("Calibrate."))
        XCTAssertTrue(FinderCoordinator.isCalibrateCommand("recalibrate"))
        XCTAssertTrue(FinderCoordinator.isCalibrateCommand("Re-center please"))
        XCTAssertTrue(FinderCoordinator.isCalibrateCommand("recenter"))
        XCTAssertFalse(FinderCoordinator.isCalibrateCommand("where's my mug"))
        XCTAssertFalse(FinderCoordinator.isCalibrateCommand("keys"))
    }

    func testSayingCalibrateMidRoundKeepsRound() async throws {
        let coordinator = try await makeReadyCoordinator()
        coordinator.placeTargetAtTap(CGPoint(x: 10, y: 10))
        let before = try XCTUnwrap(roundID(coordinator.state))
        headTracker.start()   // back to .connected so we can see the recalibration

        voice.transcript = "calibrate"
        coordinator.beginVoiceRequest()
        XCTAssertEqual(headTracker.status, .calibrated)
        XCTAssertEqual(roundID(coordinator.state), before)

        coordinator.endVoiceRequest()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(roundID(coordinator.state), before)
        XCTAssertNotNil(coordinator.elapsedSeconds)
        coordinator.onDisappear()
    }

    func testSilenceMidRoundKeepsRound() async throws {
        let coordinator = try await makeReadyCoordinator()
        coordinator.placeTargetAtTap(CGPoint(x: 10, y: 10))
        let before = try XCTUnwrap(roundID(coordinator.state))

        voice.transcript = ""
        coordinator.beginVoiceRequest()
        coordinator.endVoiceRequest()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(roundID(coordinator.state), before)
        coordinator.onDisappear()
    }

    func testObjectNameMidRoundStartsNewRequest() async throws {
        let coordinator = try await makeReadyCoordinator()
        coordinator.placeTargetAtTap(CGPoint(x: 10, y: 10))

        voice.transcript = "where are my keys"
        coordinator.beginVoiceRequest()
        coordinator.endVoiceRequest()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(coordinator.pendingFrame?.utterance, "where are my keys")
        coordinator.onDisappear()
    }

    func testSayingCalibrateWhenReadyDoesNotSearch() async throws {
        let coordinator = try await makeReadyCoordinator()

        voice.transcript = "calibrate"
        coordinator.beginVoiceRequest()
        XCTAssertEqual(coordinator.state, .listening)
        coordinator.endVoiceRequest()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(coordinator.state, .ready)
        coordinator.onDisappear()
    }
}
