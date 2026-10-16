import XCTest
import simd
@testable import Faith

private final class ScriptedLocator: ObjectLocator {
    /// Requests containing one of these words are "found"; everything else is not found.
    var visible: Set<String> = []

    func locate(utterance: String, in snapshot: Snapshot) async throws -> Detection {
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

private func makeSighting(label: String, utterance: String, secondsAgo: TimeInterval) -> ObjectSighting {
    return ObjectSighting(
        id: UUID(),
        participantId: "P01",
        objectLabel: label,
        utterance: utterance,
        seenAt: Date().addingTimeInterval(-secondsAgo),
        x: 0.1,
        y: -0.2,
        z: -0.5,
        placement: .lidarDepth,
        confidence: 0.9
    )
}

final class ObjectMemoryTests: XCTestCase {
    func testObjectWordsDropFillerAndPlurals() {
        XCTAssertEqual(ObjectMemory.objectWords("Where's my mug?"), ["mug"])
        XCTAssertEqual(ObjectMemory.objectWords("find my keys"), ["key"])
        XCTAssertEqual(ObjectMemory.objectWords("the blue water bottle"), ["blue", "water", "bottle"])
        XCTAssertEqual(ObjectMemory.objectWords("glass"), ["glass"])
    }

    func testMatchesByLabelOrOriginalRequest() {
        var memory = ObjectMemory()
        memory.remember(makeSighting(label: "blue mug", utterance: "where's my mug", secondsAgo: 60))
        memory.remember(makeSighting(label: "coffee cup", utterance: "find my coffee", secondsAgo: 30))

        XCTAssertEqual(memory.bestMatch(for: "where is the mug")?.objectLabel, "blue mug")
        XCTAssertEqual(memory.bestMatch(for: "my coffee please")?.objectLabel, "coffee cup")
        XCTAssertNil(memory.bestMatch(for: "where's my phone"))
        XCTAssertNil(memory.bestMatch(for: "where is it"))
    }

    func testNewestMatchWins() {
        var memory = ObjectMemory()
        memory.remember(makeSighting(label: "red pen", utterance: "pen", secondsAgo: 300))
        memory.remember(makeSighting(label: "black pen", utterance: "pen", secondsAgo: 10))
        XCTAssertEqual(memory.bestMatch(for: "my pen")?.objectLabel, "black pen")
    }

    func testSameLabelIsReplaced() {
        var memory = ObjectMemory()
        memory.remember(makeSighting(label: "Blue mug", utterance: "mug", secondsAgo: 300))
        memory.remember(makeSighting(label: "blue mug", utterance: "mug", secondsAgo: 5))
        XCTAssertEqual(memory.sightings.count, 1)
        XCTAssertEqual(ObjectMemory.minutesAgo(memory.sightings[0].seenAt), 0)
    }

    func testMinutesAgo() {
        let now = Date()
        XCTAssertEqual(ObjectMemory.minutesAgo(now.addingTimeInterval(-59), now: now), 0)
        XCTAssertEqual(ObjectMemory.minutesAgo(now.addingTimeInterval(-61), now: now), 1)
        XCTAssertEqual(ObjectMemory.minutesAgo(now.addingTimeInterval(-605), now: now), 10)
        XCTAssertEqual(ObjectMemory.minutesAgo(now.addingTimeInterval(30), now: now), 0)
    }

    func testAnswers() {
        XCTAssertEqual(MemoryAnswer.parse("Yes"), .yes)
        XCTAssertEqual(MemoryAnswer.parse("yeah sure"), .yes)
        XCTAssertEqual(MemoryAnswer.parse("okay."), .yes)
        XCTAssertEqual(MemoryAnswer.parse("No"), .no)
        XCTAssertEqual(MemoryAnswer.parse("nope"), .no)
        XCTAssertEqual(MemoryAnswer.parse("no thanks"), .no)
        XCTAssertEqual(MemoryAnswer.parse("I know"), .other)
        XCTAssertEqual(MemoryAnswer.parse("where's my phone"), .other)
        XCTAssertEqual(MemoryAnswer.parse("can you please go find my keys"), .other)
        XCTAssertEqual(MemoryAnswer.parse(""), .other)
    }
}

/// The coordinator flow on mocks: found -> remembered; not found -> offer -> yes / no.
@MainActor
final class MemoryFlowTests: XCTestCase {
    private var locator = ScriptedLocator()
    private var voice = ScriptedVoice()
    private var prompts = MockVoicePromptPlayer()

    private func makeReadyCoordinator() async throws -> FinderCoordinator {
        locator = ScriptedLocator()
        voice = ScriptedVoice()
        prompts = MockVoicePromptPlayer()
        let environment = AppEnvironment(
            perception: MockPerceptionService(),
            locator: locator,
            headTracker: MockHeadTracker(),
            audio: MockSpatialAudio(),
            voice: voice,
            telemetry: MockTelemetry(),
            voicePrompts: prompts
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

    /// Finds the mug once, ends that round, then the mug goes out of view.
    private func makeCoordinatorThatSawTheMug() async throws -> FinderCoordinator {
        let coordinator = try await makeReadyCoordinator()
        locator.visible = ["mug"]
        coordinator.submitTypedRequest("where's my mug")
        coordinator.approvePendingFrame()
        try await settle(coordinator)
        guard case .guiding = coordinator.state else {
            XCTFail("expected guiding, got \(coordinator.state)")
            return coordinator
        }
        coordinator.markFound()
        locator.visible = []
        return coordinator
    }

    func testFoundSaysFoundNavigating() async throws {
        let coordinator = try await makeCoordinatorThatSawTheMug()
        XCTAssertEqual(prompts.played, [.sendView, .searching, .foundNavigating])
        coordinator.onDisappear()
    }

    func testNotFoundAndNothingRememberedSaysPleaseTurn() async throws {
        let coordinator = try await makeReadyCoordinator()
        coordinator.submitTypedRequest("where's my phone")
        coordinator.approvePendingFrame()
        try await settle(coordinator)

        guard case .error(.objectNotFound) = coordinator.state else {
            XCTFail("expected objectNotFound, got \(coordinator.state)")
            return
        }
        XCTAssertNil(coordinator.memoryOffer)
        XCTAssertEqual(prompts.played, [.sendView, .searching, .notFoundTurn])
        coordinator.onDisappear()
    }

    func testNotFoundButRememberedOffersTheSpot() async throws {
        let coordinator = try await makeCoordinatorThatSawTheMug()
        coordinator.submitTypedRequest("mug")
        coordinator.approvePendingFrame()
        try await settle(coordinator)

        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertEqual(coordinator.memoryOffer?.objectLabel, "blue mug")
        XCTAssertEqual(coordinator.memoryOffer?.minutesAgo, 0)
        XCTAssertEqual(prompts.played.last, .previouslyFound(minutesAgo: 0))
        coordinator.onDisappear()
    }

    func testSayingYesGuidesToTheRememberedSpot() async throws {
        let coordinator = try await makeCoordinatorThatSawTheMug()
        coordinator.submitTypedRequest("mug")
        coordinator.approvePendingFrame()
        try await settle(coordinator)

        try await say("yes", to: coordinator)

        guard case .guiding(let target, let round) = coordinator.state else {
            XCTFail("expected guiding, got \(coordinator.state)")
            return
        }
        // MockPerceptionService.place puts every detection here.
        XCTAssertEqual(target.worldPosition, SIMD3<Float>(0.2, -0.3, -0.5))
        XCTAssertEqual(round.objectLabel, "blue mug")
        XCTAssertNil(coordinator.memoryOffer)
        XCTAssertEqual(prompts.played.last, .navigating)
        coordinator.onDisappear()
    }

    func testSayingNoSaysOkayAndStaysReady() async throws {
        let coordinator = try await makeCoordinatorThatSawTheMug()
        coordinator.submitTypedRequest("mug")
        coordinator.approvePendingFrame()
        try await settle(coordinator)

        try await say("no", to: coordinator)

        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertNil(coordinator.memoryOffer)
        XCTAssertEqual(prompts.played.last, .okay)
        coordinator.onDisappear()
    }

    func testOperatorButtonsAnswerToo() async throws {
        let coordinator = try await makeCoordinatorThatSawTheMug()
        coordinator.submitTypedRequest("mug")
        coordinator.approvePendingFrame()
        try await settle(coordinator)

        coordinator.answerMemoryOffer(accept: true)
        try await settle(coordinator)

        guard case .guiding = coordinator.state else {
            XCTFail("expected guiding, got \(coordinator.state)")
            return
        }
        coordinator.onDisappear()
    }

    func testTypedYesAnswersToo() async throws {
        let coordinator = try await makeCoordinatorThatSawTheMug()
        coordinator.submitTypedRequest("mug")
        coordinator.approvePendingFrame()
        try await settle(coordinator)

        coordinator.submitTypedRequest("yes")
        try await settle(coordinator)

        guard case .guiding = coordinator.state else {
            XCTFail("expected guiding, got \(coordinator.state)")
            return
        }
        XCTAssertEqual(prompts.played.last, .navigating)
        coordinator.onDisappear()
    }

    func testAnotherRequestDropsTheOffer() async throws {
        let coordinator = try await makeCoordinatorThatSawTheMug()
        coordinator.submitTypedRequest("mug")
        coordinator.approvePendingFrame()
        try await settle(coordinator)
        XCTAssertNotNil(coordinator.memoryOffer)

        try await say("where are my keys", to: coordinator)
        coordinator.approvePendingFrame()
        try await settle(coordinator)

        XCTAssertNil(coordinator.memoryOffer)
        XCTAssertEqual(prompts.played.last, .notFoundTurn)
        coordinator.onDisappear()
    }

    func testCancelDropsTheOffer() async throws {
        let coordinator = try await makeCoordinatorThatSawTheMug()
        coordinator.submitTypedRequest("mug")
        coordinator.approvePendingFrame()
        try await settle(coordinator)

        coordinator.cancel()
        XCTAssertNil(coordinator.memoryOffer)

        coordinator.answerMemoryOffer(accept: true)
        try await settle(coordinator)
        XCTAssertEqual(coordinator.state, .ready)
        coordinator.onDisappear()
    }
}
