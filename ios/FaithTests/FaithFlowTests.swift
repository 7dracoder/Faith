import XCTest
@testable import Faith

final class FaithRoutingTests: XCTestCase {
    func testTicketRequestsGoToTheBookingAgent() {
        XCTAssertTrue(FinderCoordinator.isBookingRequest("Book a train to Boston tomorrow"))
        XCTAssertTrue(FinderCoordinator.isBookingRequest("I need two tickets for a concert"))
        XCTAssertTrue(FinderCoordinator.isBookingRequest("I want to fly to Chicago"))
        XCTAssertTrue(FinderCoordinator.isBookingRequest("Forget my preferences"))
        XCTAssertTrue(FinderCoordinator.isBookingRequest("Cinema showtimes near me tonight"))
    }

    func testSavingNeedsTheUsersOwnAgreement() {
        XCTAssertTrue(BookingAgent.agreedToSave("Yes please remember that"))
        XCTAssertTrue(BookingAgent.agreedToSave("Save my home city as Boston"))
        XCTAssertFalse(BookingAgent.agreedToSave("No, don't remember that"))
        XCTAssertFalse(BookingAgent.agreedToSave("Book the train to Boston"))
        XCTAssertFalse(BookingAgent.agreedToSave(""))
    }

    func testSavedPreferencesEncodeOnlyAllowedFields() throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(SavedPreferences(homeCity: "Boston", stepFree: true, passengers: 2))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["home_city", "step_free", "audio_description", "companion", "passengers"])
    }

    func testObjectRequestsStayWithTheFinder() {
        XCTAssertFalse(FinderCoordinator.isBookingRequest("where's my mug"))
        XCTAssertFalse(FinderCoordinator.isBookingRequest("find my keys"))
        XCTAssertFalse(FinderCoordinator.isBookingRequest("where is my bus pass"))
        XCTAssertFalse(FinderCoordinator.isBookingRequest("headphones"))
    }

    func testOnlyAClearSpokenYesBooks() {
        XCTAssertTrue(BookingAgent.saidYes("Yes please"))
        XCTAssertTrue(BookingAgent.saidYes("okay, book it"))
        XCTAssertFalse(BookingAgent.saidYes("No"))
        XCTAssertFalse(BookingAgent.saidYes("don't book it"))
        XCTAssertFalse(BookingAgent.saidYes("yes but tell me the next one"))
        XCTAssertFalse(BookingAgent.saidYes("what time does it leave"))
        XCTAssertFalse(BookingAgent.saidYes(""))
    }

    func testBackendAnswerBecomesADetection() throws {
        let answer = ObjectLocationAnswer(found: true, label: "blue mug",
                                          box: .init(minX: 0.2, minY: 0.3, maxX: 0.5, maxY: 0.7),
                                          confidence: 0.9, reason: "visible")
        let detection = try FaithLocator.detection(from: answer, utterance: "my mug")
        XCTAssertEqual(detection.label, "blue mug")
        XCTAssertEqual(detection.box, NormalizedRect(minX: 0.2, minY: 0.3, maxX: 0.5, maxY: 0.7))
    }

    func testNotFoundAnswerThrowsObjectNotFound() {
        let answer = ObjectLocationAnswer(found: false, label: "", box: nil, confidence: 0.1, reason: "not visible")
        XCTAssertThrowsError(try FaithLocator.detection(from: answer, utterance: "keys")) { error in
            XCTAssertEqual(error as? FinderError, .objectNotFound("keys"))
        }
    }

    func testBackendAnswerDecodesSnakeCase() throws {
        let json = #"{"found":true,"label":"cup","box":{"min_x":0.1,"min_y":0.2,"max_x":0.3,"max_y":0.4},"confidence":0.95,"reason":"x"}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let answer = try decoder.decode(ObjectLocationAnswer.self, from: Data(json.utf8))
        XCTAssertEqual(answer.box?.maxY, 0.4)
    }
}

/// Per-frame consent: nothing reaches the locator until the user agrees.
@MainActor
final class FrameConsentTests: XCTestCase {
    private final class CountingLocator: ObjectLocator {
        var utterances: [String] = []
        func locate(utterance: String, in snapshot: Snapshot) async throws -> Detection {
            utterances.append(utterance)
            return Detection(label: "mug", box: NormalizedRect(minX: 0.4, minY: 0.4, maxX: 0.6, maxY: 0.6), confidence: 0.9)
        }
    }

    private var locator = CountingLocator()
    private var prompts = MockVoicePromptPlayer()

    private func makeReadyCoordinator() async throws -> FinderCoordinator {
        locator = CountingLocator()
        prompts = MockVoicePromptPlayer()
        let environment = AppEnvironment(
            perception: MockPerceptionService(), locator: locator, headTracker: MockHeadTracker(),
            audio: MockSpatialAudio(), voice: MockVoiceListener(), telemetry: MockTelemetry(), voicePrompts: prompts
        )
        let coordinator = FinderCoordinator(environment: environment)
        coordinator.onAppear()
        try await Task.sleep(nanoseconds: 1_300_000_000)
        XCTAssertEqual(coordinator.state, .ready)
        return coordinator
    }

    func testRequestAsksBeforeSending() async throws {
        let coordinator = try await makeReadyCoordinator()
        coordinator.submitTypedRequest("mug")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(coordinator.pendingFrame?.utterance, "mug")
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertTrue(locator.utterances.isEmpty)
        XCTAssertEqual(prompts.played.last, .sendView)

        coordinator.approvePendingFrame()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(locator.utterances, ["mug"])
        XCTAssertNil(coordinator.pendingFrame)
        coordinator.onDisappear()
    }

    func testDecliningSendsNothing() async throws {
        let coordinator = try await makeReadyCoordinator()
        coordinator.submitTypedRequest("mug")
        coordinator.declinePendingFrame()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(coordinator.pendingFrame)
        XCTAssertTrue(locator.utterances.isEmpty)
        XCTAssertEqual(prompts.played.last, .okay)
        coordinator.onDisappear()
    }

    func testCancelAndLeavingDropTheFrame() async throws {
        let coordinator = try await makeReadyCoordinator()
        coordinator.submitTypedRequest("mug")
        coordinator.cancel()
        XCTAssertNil(coordinator.pendingFrame)
        coordinator.submitTypedRequest("mug")
        coordinator.onDisappear()
        XCTAssertNil(coordinator.pendingFrame)
        coordinator.approvePendingFrame()
        XCTAssertTrue(locator.utterances.isEmpty)
    }

    func testBookingRequestIsHandedOffWithoutACamera() async throws {
        locator = CountingLocator()
        let voice = HeardVoice()
        voice.heard = "book a bus to Philadelphia"
        let environment = AppEnvironment(
            perception: MockPerceptionService(), locator: locator, headTracker: MockHeadTracker(),
            audio: MockSpatialAudio(), voice: voice, telemetry: MockTelemetry(), voicePrompts: MockVoicePromptPlayer()
        )
        let coordinator = FinderCoordinator(environment: environment)
        coordinator.onAppear()
        try await Task.sleep(nanoseconds: 1_300_000_000)
        var handed: [String] = []
        coordinator.onBookingRequest = { handed.append($0) }
        coordinator.beginVoiceRequest()
        coordinator.endVoiceRequest()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(handed, ["book a bus to Philadelphia"])
        XCTAssertNil(coordinator.pendingFrame)
        XCTAssertTrue(locator.utterances.isEmpty)
        coordinator.onDisappear()
    }

    private final class HeardVoice: VoiceCommandListening {
        var onPartialTranscript: ((String) -> Void)?
        var heard = ""
        func requestAuthorization() async -> Bool { true }
        func startListening() throws {}
        func stopListening() async -> String { heard }
    }
}
