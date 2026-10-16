import XCTest
import AVFoundation
@testable import Faith

private final class DuckingSpy: CueDucking {
    private(set) var calls: [Bool] = []

    func setCueDucked(_ isDucked: Bool) {
        calls.append(isDucked)
    }
}

@MainActor
final class VoicePromptPlayerTests: XCTestCase {
    private var temporaryFiles: [URL] = []

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles = []
        super.tearDown()
    }

    /// A quiet tone of `seconds`, written as a mono WAV like the real clips.
    private func makeClip(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-clip-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let frameCount = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frameCount) {
            samples[index] = 0.01 * sin(Float(index) * 0.05)
        }
        buffer.frameLength = frameCount

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
        temporaryFiles.append(url)
        return url
    }

    // MARK: - The shipped clips

    func testEveryVoiceClipLoadsFromTheBundle() {
        let player = VoicePromptPlayer(ducking: nil, bundle: .main)
        let loaded = player.loadedClipNames

        for name in VoicePrompt.allClipNames {
            XCTAssertTrue(
                loaded.contains(name),
                "\(name) is missing from Voice/Clips. Run scripts/make_voice_clips.py (Voice/ELEVENLABS.md)."
            )
        }
    }

    func testRealPlayerOnlyForTheRealEngine() {
        XCTAssertNil(VoicePromptPlayer.make(audio: MockSpatialAudio()))
        XCTAssertNotNil(VoicePromptPlayer.make(audio: SpatialAudioEngine()))
    }

    // MARK: - Playback

    func testPlayDucksTheCueAndReturnsWhenTheClipEnds() async throws {
        let ducking = DuckingSpy()
        let clip = try makeClip(seconds: 0.3)
        let player = VoicePromptPlayer(ducking: ducking, clipURLs: [VoicePrompt.okay.clipName: clip])

        let started = Date()
        await player.play(.okay)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(ducking.calls, [true, false])
        XCTAssertGreaterThan(elapsed, 0.2)
        XCTAssertLessThan(elapsed, 1.2)
    }

    func testMissingClipReturnsAtOnceAndLeavesTheCueAlone() async {
        let ducking = DuckingSpy()
        let player = VoicePromptPlayer(ducking: ducking, clipURLs: [:])

        let started = Date()
        await player.play(.foundNavigating)

        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
        XCTAssertTrue(ducking.calls.isEmpty)
    }

    func testUnreadableClipIsSkippedNotACrash() throws {
        let broken = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-clip-\(UUID().uuidString).wav")
        try Data("not audio".utf8).write(to: broken)
        temporaryFiles.append(broken)

        let player = VoicePromptPlayer(ducking: nil, clipURLs: [VoicePrompt.okay.clipName: broken])
        XCTAssertTrue(player.loadedClipNames.isEmpty)
    }

    func testANewPromptCutsOffTheCurrentOne() async throws {
        let ducking = DuckingSpy()
        let longClip = try makeClip(seconds: 3)
        let shortClip = try makeClip(seconds: 0.2)
        let player = VoicePromptPlayer(
            ducking: ducking,
            clipURLs: [
                VoicePrompt.notFoundTurn.clipName: longClip,
                VoicePrompt.okay.clipName: shortClip
            ]
        )

        let started = Date()
        let first = Task {
            await player.play(.notFoundTurn)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        await player.play(.okay)
        await first.value

        // Both calls are back long before the 3 s clip could have ended.
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertEqual(ducking.calls, [true, false, true, false])
    }

    func testStopEndsTheLineAndRestoresTheCue() async throws {
        let ducking = DuckingSpy()
        let longClip = try makeClip(seconds: 3)
        let player = VoicePromptPlayer(ducking: ducking, clipURLs: [VoicePrompt.navigating.clipName: longClip])

        let started = Date()
        let playing = Task {
            await player.play(.navigating)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        player.stop()
        await playing.value

        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertEqual(ducking.calls, [true, false])
    }

    // MARK: - Ducking in the engine

    func testEngineAcceptsDuckingBeforeItStarts() {
        let engine = SpatialAudioEngine()
        engine.setCueDucked(true)
        engine.updateCue(CueParameters(intervalSeconds: 0.4, gain: 0.9, isOnTarget: false))
        engine.setCueDucked(false)
    }
}
