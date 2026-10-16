import XCTest
import simd
@testable import Faith

private final class ScriptedLocator: ObjectLocator {
    var error: Error?
    private(set) var utterances: [String] = []

    func locate(utterance: String, in snapshot: Snapshot) async throws -> Detection {
        utterances.append(utterance)
        if let error {
            throw error
        }
        let box = NormalizedRect(minX: 0.4, minY: 0.4, maxX: 0.6, maxY: 0.6)
        return Detection(label: "mug", box: box, confidence: 1.0)
    }
}

/// Records which lines were played, and lets a test look at the app while one is playing.
@MainActor
private final class RecordingPrompts: VoicePromptPlaying {
    private(set) var played: [VoicePrompt] = []
    var onPlay: (() -> Void)?

    func play(_ prompt: VoicePrompt) async {
        onPlay?()
        played.append(prompt)
    }

    nonisolated func stop() {
    }
}

private final class SpeechBackendStub: SpeechRecognitionBackend {
    var onResult: ((String, Bool) -> Void)?

    func requestAuthorization() async -> Bool {
        return true
    }

    func start(
        contextualStrings: [String],
        onResult: @escaping (String, Bool) -> Void,
        onEnd: @escaping () -> Void
    ) throws {
        self.onResult = onResult
    }

    func endAudio() {
    }

    func cancel() {
    }
}

@MainActor
final class AnnouncingLocatorTests: XCTestCase {
    private static func makeSnapshot() -> Snapshot {
        return Snapshot(
            id: UUID(),
            capturedAt: Date(),
            uprightJPEG: Data(),
            cameraTransform: matrix_identity_float4x4,
            intrinsics: matrix_identity_float3x3,
            sensorResolution: CGSize(width: 1920, height: 1440),
            uprightRotation: .portrait,
            depth: nil
        )
    }

    func testPlaysFoundNavigatingAndReturnsTheDetection() async throws {
        let prompts = RecordingPrompts()
        let locator = AnnouncingLocator(wrapping: ScriptedLocator(), prompts: prompts)

        let detection = try await locator.locate(utterance: "where's my mug", in: Self.makeSnapshot())

        XCTAssertEqual(detection.label, "mug")
        XCTAssertEqual(prompts.played, [.foundNavigating])
    }

    func testPlaysNotFoundTurnWhenTheObjectIsNotSeen() async {
        let wrapped = ScriptedLocator()
        wrapped.error = FinderError.objectNotFound("mug")
        let prompts = RecordingPrompts()
        let locator = AnnouncingLocator(wrapping: wrapped, prompts: prompts)

        do {
            _ = try await locator.locate(utterance: "mug", in: Self.makeSnapshot())
            XCTFail("Expected objectNotFound")
        } catch {
            XCTAssertEqual(error as? FinderError, .objectNotFound("mug"))
        }
        XCTAssertEqual(prompts.played, [.notFoundTurn])
    }

    func testOtherFailuresStaySilent() async {
        let failures: [FinderError] = [.locatorTimeout, .locatorFailed("503")]
        for failure in failures {
            let wrapped = ScriptedLocator()
            wrapped.error = failure
            let prompts = RecordingPrompts()
            let locator = AnnouncingLocator(wrapping: wrapped, prompts: prompts)

            do {
                _ = try await locator.locate(utterance: "mug", in: Self.makeSnapshot())
                XCTFail("Expected \(failure)")
            } catch {
                XCTAssertEqual(error as? FinderError, failure)
            }
            XCTAssertTrue(prompts.played.isEmpty, "\(failure)")
        }
    }

    func testSwitchedOnByNameOrOverride() {
        XCTAssertTrue(AnnouncingLocator.isEnabled(realServices: "perception audio announcements", override: nil))
        XCTAssertTrue(AnnouncingLocator.isEnabled(realServices: "voice,ANNOUNCEMENTS", override: nil))
        XCTAssertFalse(AnnouncingLocator.isEnabled(realServices: "perception audio", override: nil))
        XCTAssertFalse(AnnouncingLocator.isEnabled(realServices: "announcements", override: false))
        XCTAssertTrue(AnnouncingLocator.isEnabled(realServices: "", override: true))
    }

    func testWrapIfEnabledIsOffByDefault() {
        let suiteName = "AnnouncingLocatorTests"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("No test defaults")
            return
        }
        defaults.removePersistentDomain(forName: suiteName)
        let plain = ScriptedLocator()
        let testBundle = Bundle(for: Self.self)

        let untouched = AnnouncingLocator.wrapIfEnabled(plain, defaults: defaults, bundle: testBundle)
        XCTAssertTrue(untouched === plain)

        defaults.set(true, forKey: AnnouncingLocator.defaultsKey)
        let wrapped = AnnouncingLocator.wrapIfEnabled(plain, defaults: defaults, bundle: testBundle)
        XCTAssertTrue(wrapped is AnnouncingLocator)
        defaults.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Whole flow: say an object -> it becomes the target

    private func makeReadyCoordinator(
        locator: ScriptedLocator,
        prompts: RecordingPrompts,
        backend: SpeechBackendStub
    ) async throws -> FinderCoordinator {
        let environment = AppEnvironment(
            perception: MockPerceptionService(),
            locator: AnnouncingLocator(wrapping: locator, prompts: prompts),
            headTracker: MockHeadTracker(),
            audio: MockSpatialAudio(),
            voice: VoiceCommandListener(backend: backend),
            telemetry: MockTelemetry()
        )
        let coordinator = FinderCoordinator(environment: environment)
        coordinator.onAppear()
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(coordinator.state, .ready)
        return coordinator
    }

    /// "Item found, navigating" comes before the beeping: while it plays the round has not started.
    func testSpokenObjectIsFoundAnnouncedAndThenGuided() async throws {
        let locator = ScriptedLocator()
        let prompts = RecordingPrompts()
        let backend = SpeechBackendStub()
        let coordinator = try await makeReadyCoordinator(locator: locator, prompts: prompts, backend: backend)

        var stateWhileSpeaking: FinderState?
        prompts.onPlay = {
            stateWhileSpeaking = coordinator.state
        }

        coordinator.beginVoiceRequest()
        XCTAssertEqual(coordinator.state, .listening)
        backend.onResult?("where's my mug", false)
        coordinator.endVoiceRequest()
        try await Task.sleep(nanoseconds: 100_000_000)
        backend.onResult?("where's my mug", true)
        try await Task.sleep(nanoseconds: 200_000_000)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(locator.utterances, ["where's my mug"])
        XCTAssertEqual(prompts.played, [.foundNavigating])
        XCTAssertEqual(stateWhileSpeaking, .locating(utterance: "where's my mug"))
        guard case .guiding(let target, _) = coordinator.state else {
            XCTFail("Expected guiding, got \(coordinator.state)")
            return
        }
        XCTAssertEqual(target.label, "mug")
        XCTAssertNotNil(coordinator.elapsedSeconds)
        coordinator.onDisappear()
    }

    func testObjectOutOfViewPlaysNotFoundTurnAndNoRoundStarts() async throws {
        let locator = ScriptedLocator()
        locator.error = FinderError.objectNotFound("mug")
        let prompts = RecordingPrompts()
        let backend = SpeechBackendStub()
        let coordinator = try await makeReadyCoordinator(locator: locator, prompts: prompts, backend: backend)

        coordinator.beginVoiceRequest()
        backend.onResult?("find my mug", true)
        coordinator.endVoiceRequest()
        try await Task.sleep(nanoseconds: 200_000_000)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(prompts.played, [.notFoundTurn])
        XCTAssertEqual(coordinator.state, .error(.objectNotFound("mug")))
        XCTAssertNil(coordinator.elapsedSeconds)
        coordinator.onDisappear()
    }
}
