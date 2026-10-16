import XCTest
@testable import Faith

private final class FakeSpeechBackend: SpeechRecognitionBackend {
    var startError: Error?
    var contextualStrings: [String] = []
    var onResult: ((String, Bool) -> Void)?
    var onEnd: (() -> Void)?
    var startCount = 0
    var endAudioCount = 0
    var cancelCount = 0

    func requestAuthorization() async -> Bool {
        return true
    }

    func start(
        contextualStrings: [String],
        onResult: @escaping (String, Bool) -> Void,
        onEnd: @escaping () -> Void
    ) throws {
        if let startError {
            throw startError
        }
        startCount += 1
        self.contextualStrings = contextualStrings
        self.onResult = onResult
        self.onEnd = onEnd
    }

    func endAudio() {
        endAudioCount += 1
    }

    func cancel() {
        cancelCount += 1
    }
}

@MainActor
final class VoiceCommandListenerTests: XCTestCase {
    private var backend = FakeSpeechBackend()

    private func makeListener(
        hardStop: TimeInterval = 5,
        finalResultGrace: TimeInterval = 5
    ) -> VoiceCommandListener {
        backend = FakeSpeechBackend()
        return VoiceCommandListener(
            backend: backend,
            hardStop: hardStop,
            finalResultGrace: finalResultGrace
        )
    }

    /// Lets work queued on the main queue (stopListening) run.
    private func drainMainQueue() async {
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    // MARK: - Press

    func testPressStartsTheRecognizerWithObjectsAndCommands() throws {
        let listener = makeListener()
        try listener.startListening()

        XCTAssertEqual(backend.startCount, 1)
        XCTAssertTrue(backend.contextualStrings.contains("mug"))
        XCTAssertTrue(backend.contextualStrings.contains("calibrate"))
        XCTAssertTrue(backend.contextualStrings.contains("found it"))
        // Answers to "want to navigate?".
        XCTAssertTrue(backend.contextualStrings.contains("yes"))
        XCTAssertTrue(backend.contextualStrings.contains("nope"))
    }

    func testStartFailureIsThrown() {
        let listener = makeListener()
        backend.startError = FinderError.speechNotAuthorized

        XCTAssertThrowsError(try listener.startListening()) { error in
            XCTAssertEqual(error as? FinderError, .speechNotAuthorized)
        }
    }

    func testPartialTranscriptsReachTheUI() throws {
        let listener = makeListener()
        var partials: [String] = []
        listener.onPartialTranscript = { text in
            partials.append(text)
        }

        try listener.startListening()
        backend.onResult?("where's", false)
        backend.onResult?("where's my mug", false)

        XCTAssertEqual(partials, ["where's", "where's my mug"])
    }

    // MARK: - Release

    func testReleaseReturnsTheFinalTranscript() async throws {
        let listener = makeListener()
        try listener.startListening()
        backend.onResult?("where's my", false)

        async let pending = listener.stopListening()
        await drainMainQueue()
        // Release closes the microphone and waits for the final wording.
        XCTAssertEqual(backend.endAudioCount, 1)

        backend.onResult?("where's my mug", true)
        let transcript = await pending
        XCTAssertEqual(transcript, "where's my mug")
        XCTAssertGreaterThanOrEqual(backend.cancelCount, 1)
    }

    func testNoFinalResultFallsBackToTheBestPartial() async throws {
        let listener = makeListener(finalResultGrace: 0.1)
        try listener.startListening()
        backend.onResult?("my keys", false)

        let transcript = await listener.stopListening()
        XCTAssertEqual(transcript, "my keys")
    }

    func testEmptyFinalResultDoesNotEraseWhatWasHeard() async throws {
        let listener = makeListener()
        try listener.startListening()
        backend.onResult?("bottle", false)

        async let pending = listener.stopListening()
        await drainMainQueue()
        backend.onResult?("", true)

        let transcript = await pending
        XCTAssertEqual(transcript, "bottle")
    }

    func testNothingSaidReturnsEmpty() async throws {
        let listener = makeListener(finalResultGrace: 0.1)
        try listener.startListening()

        let transcript = await listener.stopListening()
        XCTAssertEqual(transcript, "")
    }

    func testRecognizerFailureEndsTheWait() async throws {
        let listener = makeListener()
        try listener.startListening()
        backend.onResult?("wallet", false)

        async let pending = listener.stopListening()
        await drainMainQueue()
        backend.onEnd?()

        let transcript = await pending
        XCTAssertEqual(transcript, "wallet")
    }

    func testStopWithoutStartReturnsEmpty() async {
        let listener = makeListener()
        let transcript = await listener.stopListening()
        XCTAssertEqual(transcript, "")
    }

    func testSecondStopCancelsTheWait() async throws {
        let listener = makeListener()
        try listener.startListening()
        backend.onResult?("mug", false)

        async let first = listener.stopListening()
        await drainMainQueue()
        let second = await listener.stopListening()
        let firstResult = await first

        XCTAssertEqual(firstResult, "")
        XCTAssertEqual(second, "")
    }

    // MARK: - Hard stop

    func testHardStopClosesTheMicrophoneAndKeepsTheTranscriptForTheRelease() async throws {
        let listener = makeListener(hardStop: 0.1)
        try listener.startListening()
        backend.onResult?("where are my glasses", false)

        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(backend.endAudioCount, 1)
        backend.onResult?("where are my glasses", true)

        let transcript = await listener.stopListening()
        XCTAssertEqual(transcript, "where are my glasses")
        XCTAssertEqual(backend.endAudioCount, 1)
    }

    func testLateResultsOfAnOldPressAreIgnored() async throws {
        let listener = makeListener(finalResultGrace: 0.1)
        try listener.startListening()
        let oldResult = backend.onResult
        _ = await listener.stopListening()

        try listener.startListening()
        oldResult?("stale words", true)
        backend.onResult?("fresh words", false)

        let transcript = await listener.stopListening()
        XCTAssertEqual(transcript, "fresh words")
    }
}
