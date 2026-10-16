import XCTest
@testable import Faith

@MainActor
private final class RecordingAnnouncer: StatusAnnouncing {
    private(set) var said: [StatusLine] = []

    func say(_ line: StatusLine) {
        said.append(line)
    }
}

/// A blind user pressing while the camera is still starting hears why nothing happens,
/// then hears when it's ready.
@MainActor
final class CameraStatusTests: XCTestCase {
    func testPressDuringSetupSaysCameraStartingThenReady() async throws {
        let announcer = RecordingAnnouncer()
        let environment = AppEnvironment(
            perception: MockPerceptionService(),
            locator: MockObjectLocator(),
            headTracker: MockHeadTracker(),
            audio: MockSpatialAudio(),
            voice: MockVoiceListener(),
            telemetry: MockTelemetry()
        )
        let coordinator = FinderCoordinator(environment: environment, statusAnnouncer: announcer)
        coordinator.onAppear()
        XCTAssertEqual(coordinator.state, .setup)

        coordinator.beginVoiceRequest()
        XCTAssertEqual(announcer.said, [.cameraStarting])

        // MockPerceptionService reaches normal tracking after ~1 s.
        try await Task.sleep(nanoseconds: 1_400_000_000)
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertEqual(announcer.said, [.cameraStarting, .cameraReady])
        coordinator.onDisappear()
    }

    func testNoReadyLineIfStartingWasNeverSaid() async throws {
        let announcer = RecordingAnnouncer()
        let environment = AppEnvironment(
            perception: MockPerceptionService(),
            locator: MockObjectLocator(),
            headTracker: MockHeadTracker(),
            audio: MockSpatialAudio(),
            voice: MockVoiceListener(),
            telemetry: MockTelemetry()
        )
        let coordinator = FinderCoordinator(environment: environment, statusAnnouncer: announcer)
        coordinator.onAppear()
        try await Task.sleep(nanoseconds: 1_400_000_000)
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertTrue(announcer.said.isEmpty)
        coordinator.onDisappear()
    }

    func testBothClipsShipInTheApp() {
        for line in StatusLine.allCases {
            XCTAssertNotNil(Bundle.main.url(forResource: line.rawValue, withExtension: "wav"), line.rawValue)
        }
    }
}
