import XCTest
import AVFoundation
import simd
@testable import Faith

/// Renders the real engine graph offline and measures the energy in each ear,
/// so "a source on the right is louder in the right ear" is locked by a test
/// and not only by someone listening.
final class SpatialAudioGraphTests: XCTestCase {
    private struct EarEnergy {
        var left: Float
        var right: Float
        var peak: Float = 0
    }

    private let body = BodyPose(
        position: SIMD3<Float>(0, 0, 0),
        forward: SIMD3<Float>(0, 0, -1)
    )
    private let rig = ListenerRig.chestMount(upOffsetMeters: 0)

    /// A fixed broadband burst (seeded noise with a fast decay), mono 48 kHz like a cue.
    /// The left/right tests measure the graph, so they must not depend on whichever
    /// cue sound is shipped: a low, warm cue has far less level difference between
    /// the ears than a bright one.
    private func makeTestBurst() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: AudioBufferLoader.sampleRate, channels: 1)
        )
        let frameCount = AVAudioFrameCount(AudioBufferLoader.sampleRate * 0.15)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        let decayFrames = Float(AudioBufferLoader.sampleRate) * 0.03

        var state: UInt32 = 12_345
        for frame in 0..<Int(frameCount) {
            state = state &* 1_664_525 &+ 1_013_904_223
            let noise = Float(state >> 8) / Float(1 << 24) * 2 - 1
            let envelope = exp(-Float(frame) / decayFrames)
            samples[frame] = noise * envelope * AudioBufferLoader.cuePeakAmplitude
        }
        buffer.frameLength = frameCount
        return buffer
    }

    /// Renders `cue` (the fixed test burst when nil) from `source`. `pulseIntervalSeconds`
    /// nil plays it once, otherwise it is repeated on rotating voices the way the engine pulses it.
    private func renderCue(
        source: SIMD3<Float>,
        head: HeadRotation,
        cue shippedCue: AVAudioPCMBuffer? = nil,
        pulseIntervalSeconds: Double? = nil,
        renderSeconds: Double = 1.2
    ) throws -> EarEnergy {
        let graph = SpatialAudioGraph()
        let renderFormat = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: AudioBufferLoader.sampleRate, channels: 2)
        )
        try graph.engine.enableManualRenderingMode(.offline, format: renderFormat, maximumFrameCount: 4_096)
        try graph.buildIfNeeded()
        try graph.engine.start()

        let listener = ListenerPoseMath.compose(body: body, head: head, rig: rig)
        graph.setListener(listener)
        graph.setSourcePosition(source)
        graph.setCueVolume(CueModulator.gain)

        let cue = try shippedCue ?? makeTestBurst()
        graph.playCuePlayers()

        var pulseTimes: [Double] = [0]
        if let pulseIntervalSeconds {
            var time = pulseIntervalSeconds
            while time < renderSeconds {
                pulseTimes.append(time)
                time += pulseIntervalSeconds
            }
        }
        for (index, time) in pulseTimes.enumerated() {
            let voice = graph.cuePlayers[index % graph.cuePlayers.count]
            let sampleTime = AVAudioFramePosition(time * AudioBufferLoader.sampleRate)
            let when = AVAudioTime(sampleTime: sampleTime, atRate: AudioBufferLoader.sampleRate)
            voice.scheduleBuffer(cue, at: when, options: [], completionHandler: nil)
        }

        let output = try XCTUnwrap(
            AVAudioPCMBuffer(
                pcmFormat: graph.engine.manualRenderingFormat,
                frameCapacity: graph.engine.manualRenderingMaximumFrameCount
            )
        )

        var energy = EarEnergy(left: 0, right: 0)
        let framesToRender = AVAudioFramePosition(AudioBufferLoader.sampleRate * renderSeconds)

        while graph.engine.manualRenderingSampleTime < framesToRender {
            let status = try graph.engine.renderOffline(output.frameCapacity, to: output)
            XCTAssertEqual(status, .success)

            let data = try XCTUnwrap(output.floatChannelData)
            for frame in 0..<Int(output.frameLength) {
                let left = data[0][frame]
                let right = data[1][frame]
                energy.left += left * left
                energy.right += right * right
                energy.peak = max(energy.peak, abs(left), abs(right))
            }
        }

        graph.stopCuePlayers()
        graph.engine.stop()
        return energy
    }

    func testSourceOnTheRightIsLouderInTheRightEar() throws {
        let energy = try renderCue(source: SIMD3<Float>(0.6, 0, 0), head: .identity)

        XCTAssertGreaterThan(energy.right, 0)
        XCTAssertGreaterThan(energy.right, energy.left * 2)
    }

    func testSourceOnTheLeftIsLouderInTheLeftEar() throws {
        let energy = try renderCue(source: SIMD3<Float>(-0.6, 0, 0), head: .identity)

        XCTAssertGreaterThan(energy.left, 0)
        XCTAssertGreaterThan(energy.left, energy.right * 2)
    }

    func testSourceStraightAheadIsBalanced() throws {
        let energy = try renderCue(source: SIMD3<Float>(0, 0, -0.6), head: .identity)

        XCTAssertGreaterThan(energy.left, 0)
        XCTAssertEqual(energy.left / energy.right, 1, accuracy: 0.25)
    }

    func testTurningTheHeadLeftMovesAFrontSourceToTheRightEar() throws {
        let headLeft = HeadRotation(yawRadians: Float.pi / 2, pitchRadians: 0)
        let energy = try renderCue(source: SIMD3<Float>(0, 0, -0.6), head: headLeft)

        XCTAssertGreaterThan(energy.right, energy.left * 2)
    }

    func testFrontRightSourceLeansRight() throws {
        // Half a meter right and half a meter ahead: 45 degrees to the right.
        let energy = try renderCue(source: SIMD3<Float>(0.5, 0, -0.5), head: .identity)

        XCTAssertGreaterThan(energy.right, energy.left * 1.3)
    }

    /// Worst case for loudness: the source right next to one ear, pulsing at the
    /// fastest rate so the tails of a long cue pile up. Clipping here would crackle.
    /// This one is about the sound we ship, so it renders the bundled primary cue.
    func testFastestPulseNextToTheEarDoesNotClip() throws {
        let energy = try renderCue(
            source: SIMD3<Float>(0.3, 0, 0),
            head: .identity,
            cue: try AudioBufferLoader.loadCue(.primary),
            pulseIntervalSeconds: CueModulator.fastestIntervalSeconds,
            renderSeconds: 2.5
        )
        print("Peak output with the fastest pulse next to the ear: \(energy.peak)")

        XCTAssertGreaterThan(energy.peak, 0.05)
        XCTAssertLessThan(energy.peak, 1.0)
    }

    /// The shipped cue only has to end up on the correct side. How strongly depends on
    /// the sound itself; the ratio is printed so a new cue can be compared with the last.
    func testShippedPrimaryCueIsLouderOnTheSourceSide() throws {
        let energy = try renderCue(
            source: SIMD3<Float>(0.6, 0, 0),
            head: .identity,
            cue: try AudioBufferLoader.loadCue(.primary)
        )
        print("Shipped primary cue, source 90 degrees right: right/left energy \(energy.right / energy.left)")

        XCTAssertGreaterThan(energy.right, energy.left)
    }

    func testPulsingKeepsTheSoundOnTheSameSide() throws {
        let energy = try renderCue(
            source: SIMD3<Float>(0.6, 0, 0),
            head: .identity,
            pulseIntervalSeconds: CueModulator.fastestIntervalSeconds
        )

        XCTAssertGreaterThan(energy.right, energy.left * 2)
    }

    func testCloserSourceIsLouder() throws {
        let near = try renderCue(source: SIMD3<Float>(0, 0, -0.4), head: .identity)
        let far = try renderCue(source: SIMD3<Float>(0, 0, -2.0), head: .identity)

        XCTAssertGreaterThan(near.left + near.right, (far.left + far.right) * 2)
    }
}
