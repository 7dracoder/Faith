import XCTest
import AVFoundation
@testable import Faith

final class AudioBufferLoaderTests: XCTestCase {
    private func makeBuffer(sampleRate: Double, channels: [[Float]]) throws -> AVAudioPCMBuffer {
        let channelCount = AVAudioChannelCount(channels.count)
        let frameCount = AVAudioFrameCount(channels[0].count)

        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)
        )
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        let data = try XCTUnwrap(buffer.floatChannelData)
        buffer.frameLength = frameCount

        for channel in 0..<channels.count {
            for frame in 0..<channels[channel].count {
                data[channel][frame] = channels[channel][frame]
            }
        }
        return buffer
    }

    private func peak(of buffer: AVAudioPCMBuffer) throws -> Float {
        let data = try XCTUnwrap(buffer.floatChannelData)
        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(data[channel][frame]))
            }
        }
        return peak
    }

    func testEveryCueLoadsAsMono48kAtTheCuePeak() throws {
        for id in CueSoundID.allCases {
            let buffer = try AudioBufferLoader.loadCue(id)

            XCTAssertEqual(buffer.format.channelCount, 1, id.rawValue)
            XCTAssertEqual(buffer.format.sampleRate, 48_000, id.rawValue)
            XCTAssertGreaterThan(buffer.frameLength, 0, id.rawValue)
            XCTAssertEqual(try peak(of: buffer), AudioBufferLoader.cuePeakAmplitude, accuracy: 1e-4, id.rawValue)
        }
    }

    /// A cue plays `Resources/Sounds/<rawValue>` unless the catalog overrides it.
    /// The final cue ships as `cue_primary.wav`, so nothing is overridden now.
    func testCuesUseTheirOwnFileUnlessOverridden() {
        for id in CueSoundID.allCases {
            let expected = CueSoundCatalog.overrides[id] ?? id.rawValue
            XCTAssertEqual(CueSoundCatalog.resourceName(for: id), expected)
        }
        XCTAssertEqual(CueSoundCatalog.resourceName(for: .primary), "cue_primary")
    }

    func testStereoMP3ComesOutMonoAtTheSameLength() throws {
        // Audio/Sounds/echosound.mp3 is stereo 24 kHz, about 1.06 s. It must come out mono 48 kHz, same length.
        let buffer = try AudioBufferLoader.loadBuffer(named: "echosound", channelCount: 1)
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate

        XCTAssertEqual(buffer.format.channelCount, 1)
        XCTAssertEqual(buffer.format.sampleRate, 48_000)
        XCTAssertEqual(seconds, 1.05, accuracy: 0.1)
    }

    func testNormalizePeakScalesToTheTargetAndLeavesSilenceAlone() throws {
        let quiet = try makeBuffer(sampleRate: 48_000, channels: [[0.1, -0.2, 0.05]])
        AudioBufferLoader.normalizePeak(of: quiet, to: 0.8)
        let quietData = try XCTUnwrap(quiet.floatChannelData)

        XCTAssertEqual(quietData[0][1], -0.8, accuracy: 1e-6)
        XCTAssertEqual(quietData[0][0], 0.4, accuracy: 1e-6)

        let silence = try makeBuffer(sampleRate: 48_000, channels: [[0, 0, 0]])
        AudioBufferLoader.normalizePeak(of: silence, to: 0.8)
        let silenceData = try XCTUnwrap(silence.floatChannelData)

        XCTAssertEqual(silenceData[0][1], 0, accuracy: 1e-9)
    }

    func testEveryEarconLoadsAsStereo48k() throws {
        for earcon in Earcon.allCases {
            let buffer = try AudioBufferLoader.loadBuffer(named: earcon.rawValue, channelCount: 2)

            XCTAssertEqual(buffer.format.channelCount, 2, earcon.rawValue)
            XCTAssertEqual(buffer.format.sampleRate, 48_000, earcon.rawValue)
            XCTAssertGreaterThan(buffer.frameLength, 0, earcon.rawValue)
        }
    }

    func testMissingSoundThrows() {
        XCTAssertThrowsError(try AudioBufferLoader.loadBuffer(named: "does_not_exist", channelCount: 1))
    }

    func testMonoToStereoCopiesTheSignalToBothChannels() throws {
        let mono = try makeBuffer(sampleRate: 48_000, channels: [[0.1, -0.2, 0.3]])

        let stereo = try AudioBufferLoader.remapChannels(mono, channelCount: 2)
        let data = try XCTUnwrap(stereo.floatChannelData)

        XCTAssertEqual(stereo.format.channelCount, 2)
        XCTAssertEqual(stereo.frameLength, 3)
        XCTAssertEqual(data[0][1], -0.2, accuracy: 1e-6)
        XCTAssertEqual(data[1][1], -0.2, accuracy: 1e-6)
        XCTAssertEqual(data[1][2], 0.3, accuracy: 1e-6)
    }

    func testStereoToMonoAveragesTheChannels() throws {
        let stereo = try makeBuffer(sampleRate: 48_000, channels: [[1.0, 0.0], [0.0, 0.5]])

        let mono = try AudioBufferLoader.remapChannels(stereo, channelCount: 1)
        let data = try XCTUnwrap(mono.floatChannelData)

        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(data[0][0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(data[0][1], 0.25, accuracy: 1e-6)
    }

    func testResampleChangesTheRateAndKeepsTheDuration() throws {
        let samples = [Float](repeating: 0.25, count: 4_410)
        let source = try makeBuffer(sampleRate: 44_100, channels: [samples])

        let resampled = try AudioBufferLoader.resample(source, sampleRate: 48_000)

        XCTAssertEqual(resampled.format.sampleRate, 48_000)
        XCTAssertEqual(resampled.format.channelCount, 1)
        // 0.1 s of audio in, about 0.1 s out. The converter may trim a few frames of filter delay.
        XCTAssertEqual(Double(resampled.frameLength), 4_800, accuracy: 100)
    }
}
