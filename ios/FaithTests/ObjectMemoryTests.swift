import XCTest
import simd
@testable import Faith

private final class ScriptedLocator: ObjectLocator {
    /// Requests containing one of these words are "found"; everything else is not found.
    var visible: Set<String> = []
    private(set) var calls = 0

    func locate(utterance: String, in snapshot: Snapshot) async throws -> Detection {
        calls += 1
        let words = ObjectMemory.objectWords(utterance)
        for word in words where visible.contains(word) {
            let box = NormalizedRect(minX: 0.4, minY: 0.4, maxX: 0.6, maxY: 0.6)
            return Detection(label: "blue \(word)", box: box, confidence: 0.9)
        }
        throw FinderError.objectNotFound("not in view")
    }
}

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

final class ObjectMemoryTests: XCTestCase {
    func testObjectWordsDropFillerAndPlurals() {
        XCTAssertEqual(ObjectMemory.objectWords("Where's my mug?"), ["mug"])
        XCTAssertEqual(ObjectMemory.objectWords("find my keys"), ["key"])
        XCTAssertEqual(ObjectMemory.objectWords("the blue water bottle"), ["blue", "water", "bottle"])
        XCTAssertEqual(ObjectMemory.objectWords("glass"), ["glass"])
    }

    func testMinutesAgo() {
        let now = Date()
        XCTAssertEqual(ObjectMemory.minutesAgo(now.addingTimeInterval(-59), now: now), 0)
        XCTAssertEqual(ObjectMemory.minutesAgo(now.addingTimeInterval(-61), now: now), 1)
        XCTAssertEqual(ObjectMemory.minutesAgo(now.addingTimeInterval(-605), now: now), 10)
        XCTAssertEqual(ObjectMemory.minutesAgo(now.addingTimeInterval(30), now: now), 0)
    }
}

/// The coordinator flow on mocks: memory first, then a live find; memory scans; voice commands.
@MainActor
final class MemoryFlowTests: XCTestCase {
    private var locator = ScriptedLocator()
    private var voice = ScriptedVoice()
    private var prompts = MockVoicePromptPlayer()
    private var speech = MockSentenceSpeaker()
    private var backend = MockObjectMemoryBackend()
    private var store: SeenObjectStore!
    private var defaultsName = ""

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: defaultsName)
        super.tearDown()
    }

    private func makeReadyCoordinator(seen: [SeenObject] = [], remembering: Bool = true,
                                      scanned: [ScannedObject] = []) async throws -> FinderCoordinator {
        locator = ScriptedLocator()
        voice = ScriptedVoice()
        prompts = MockVoicePromptPlayer()
        speech = MockSentenceSpeaker()
        backend = MockObjectMemoryBackend()
        backend.scanned = scanned
        defaultsName = "MemoryFlowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.set(true, forKey: "memory.announced")
        store = SeenObjectStore(directory: nil, defaults: defaults)
        store.isRemembering = remembering
        store.remember(seen)
        let environment = AppEnvironment(
            perception: MockPerceptionService(),
            locator: locator,
            headTracker: MockHeadTracker(),
            audio: MockSpatialAudio(),
            voice: voice,
            telemetry: MockTelemetry(),
            voicePrompts: prompts,
            speech: speech,
            memoryBackend: backend,
            seenObjects: store
        )
        let coordinator = FinderCoordinator(environment: environment)
        coordinator.onAppear()
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(coordinator.state, .ready)
        return coordinator
    }

    /// Waits until the request has finished (not listening or locating), up to 5 s, then a
    /// moment more for the voice line that follows. A fixed 0.3 s was too short on CI.
    private func settle(_ coordinator: FinderCoordinator) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
            if !Self.isBusy(coordinator.state) {
                break
            }
        }
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    private static func isBusy(_ state: FinderState) -> Bool {
        switch state {
        case .listening, .locating:
            return true
        default:
            return false
        }
    }

    private func say(_ transcript: String, to coordinator: FinderCoordinator) async throws {
        voice.transcript = transcript
        coordinator.beginVoiceRequest()
        coordinator.endVoiceRequest()
        try await settle(coordinator)
    }

    private func seen(_ label: String, place: String = "on the kitchen counter", minutesAgo: Double = 3,
                      session: UUID? = UUID()) -> SeenObject {
        SeenObject(label: label, place: place, seenAt: Date().addingTimeInterval(-minutesAgo * 60),
                   position: [0.1, -0.2, -0.5], arSession: session)
    }

    func testLiveFindIsSentRightAwayAndRemembered() async throws {
        let coordinator = try await makeReadyCoordinator()
        locator.visible = ["mug"]
        coordinator.submitTypedRequest("where's my mug")
        try await settle(coordinator)
        guard case .guiding = coordinator.state else {
            return XCTFail("expected guiding, got \(coordinator.state)")
        }
        XCTAssertEqual(prompts.played, [.searching, .foundNavigating])
        XCTAssertEqual(store.memory.bestMatch(for: "mug")?.label, "blue mug")
        coordinator.onDisappear()
    }

    func testNotFoundAndNothingRememberedSaysSoHonestly() async throws {
        let coordinator = try await makeReadyCoordinator()
        coordinator.submitTypedRequest("where's my phone")
        try await settle(coordinator)
        guard case .error(.objectNotFound) = coordinator.state else {
            return XCTFail("expected objectNotFound, got \(coordinator.state)")
        }
        XCTAssertEqual(prompts.played, [.searching, .notFoundTurn])
        XCTAssertTrue(speech.spoken.isEmpty)
        coordinator.onDisappear()
    }

    func testRememberedInThisSessionGuidesWithoutAVisionCall() async throws {
        let coordinator = try await makeReadyCoordinator()
        locator.visible = ["mug"]
        coordinator.submitTypedRequest("where's my mug")
        try await settle(coordinator)
        coordinator.markFound()
        locator.visible = []

        try await say("where did I leave my mug", to: coordinator)

        guard case .guiding(let target, _) = coordinator.state else {
            return XCTFail("expected guiding, got \(coordinator.state)")
        }
        // MockPerceptionService.place puts every detection here.
        XCTAssertEqual(target.worldPosition, SIMD3<Float>(0.2, -0.3, -0.5))
        XCTAssertEqual(speech.spoken, ["I last saw your blue mug, just now."])
        XCTAssertEqual(prompts.played.last, .navigating)
        XCTAssertEqual(locator.calls, 1)
        coordinator.onDisappear()
    }

    func testRememberedFromAnEarlierSessionIsSpokenThenFoundLive() async throws {
        let coordinator = try await makeReadyCoordinator(seen: [seen("keys")])
        locator.visible = ["key"]
        try await say("where are my keys", to: coordinator)
        guard case .guiding = coordinator.state else {
            return XCTFail("expected guiding, got \(coordinator.state)")
        }
        XCTAssertEqual(speech.spoken, ["I last saw your keys on the kitchen counter, 3 minutes ago."])
        XCTAssertEqual(prompts.played, [.searching, .foundNavigating])
        XCTAssertEqual(locator.calls, 1)
        coordinator.onDisappear()
    }

    func testRememberedFromAnEarlierSessionButNotInViewSaysTurn() async throws {
        let coordinator = try await makeReadyCoordinator(seen: [seen("keys")])
        try await say("where are my keys", to: coordinator)
        guard case .error(.objectNotFound) = coordinator.state else {
            return XCTFail("expected objectNotFound, got \(coordinator.state)")
        }
        XCTAssertEqual(coordinator.memoryAnswer, "I last saw your keys on the kitchen counter, 3 minutes ago.")
        XCTAssertEqual(prompts.played, [.searching, .notFoundTurn])
        XCTAssertEqual(locator.calls, 1)
        coordinator.onDisappear()
    }

    func testBackendMemoryIsUsedWhenThePhoneHasNone() async throws {
        let coordinator = try await makeReadyCoordinator()
        backend.remote = [seen("wallet", place: "on the hall table", minutesAgo: 10, session: nil)]
        try await say("where's my wallet", to: coordinator)
        XCTAssertEqual(speech.spoken, ["I last saw your wallet on the hall table, 10 minutes ago."])
        XCTAssertEqual(store.memory.bestMatch(for: "wallet")?.place, "on the hall table")
        XCTAssertEqual(locator.calls, 1, "no position from this session, so it still looks")
        coordinator.onDisappear()
    }

    func testForgetWhatYouveSeenClearsThePhoneAndTheBackend() async throws {
        let coordinator = try await makeReadyCoordinator(seen: [seen("keys")])
        try await say("forget what you've seen", to: coordinator)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(store.memory.objects.isEmpty)
        XCTAssertEqual(backend.forgets, 1)
        XCTAssertEqual(speech.spoken.last, "I forgot everything I have seen.")
        XCTAssertEqual(locator.calls, 0)
        coordinator.onDisappear()
    }

    func testStopAndStartRememberingIsSavedAndStopsScans() async throws {
        let coordinator = try await makeReadyCoordinator()
        try await say("stop remembering", to: coordinator)
        XCTAssertFalse(coordinator.isRemembering)
        XCTAssertFalse(store.isRemembering)
        let scans = backend.scans
        try await Task.sleep(nanoseconds: 2_200_000_000)
        XCTAssertEqual(backend.scans, scans)

        try await say("start remembering", to: coordinator)
        XCTAssertTrue(store.isRemembering)
        coordinator.onDisappear()
    }

    func testPeriodicScanRemembersObjectsWithPositions() async throws {
        let keysInView = ScannedObject(label: "keys", place: "next to the kettle",
                                       box: NormalizedRect(minX: 0.4, minY: 0.4, maxX: 0.6, maxY: 0.6), confidence: 0.9)
        let coordinator = try await makeReadyCoordinator(scanned: [keysInView])
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let keys = try XCTUnwrap(store.memory.bestMatch(for: "my keys"))
        XCTAssertEqual(keys.place, "next to the kettle")
        XCTAssertEqual(keys.position, [0.2, -0.3, -0.5])
        XCTAssertNotNil(keys.arSession)
        XCTAssertEqual(backend.saved.first?.label, "keys")
        coordinator.onDisappear()

        // Leaving the finder (booking screen, background) stops capture.
        let scans = backend.scans
        try await Task.sleep(nanoseconds: 2_200_000_000)
        XCTAssertEqual(backend.scans, scans)
    }

    func testNoScansWhenRememberingIsOff() async throws {
        let coordinator = try await makeReadyCoordinator(remembering: false)
        try await Task.sleep(nanoseconds: 2_200_000_000)
        XCTAssertEqual(backend.scans, 0)
        coordinator.onDisappear()
    }
}
