import Foundation
import os

final class MockSpatialAudio: SpatialAudioRendering {
    private(set) var isRunning = false

    // Kept for inspection in tests and the debugger.
    private(set) var lastListener: ListenerPose?
    private(set) var lastTarget: AnchoredTarget?
    private(set) var lastCue: CueParameters?
    private(set) var lastCueSound: CueSoundID = .primary
    private(set) var lastEarcon: Earcon?
    private(set) var listenerUpdateCount = 0

    private let logger = Logger(subsystem: "app.faith.finder", category: "MockAudio")

    func start() throws {
        logger.info("start")
        isRunning = true
    }

    func stop() {
        logger.info("stop")
        isRunning = false
    }

    func setCueSound(_ id: CueSoundID) {
        logger.info("setCueSound \(id.rawValue, privacy: .public)")
        lastCueSound = id
    }

    func setTarget(_ target: AnchoredTarget) {
        logger.info("setTarget \(target.label, privacy: .public) at \(String(describing: target.worldPosition), privacy: .public)")
        lastTarget = target
    }

    func clearTarget() {
        logger.info("clearTarget")
        lastTarget = nil
    }

    func updateListener(_ pose: ListenerPose) {
        // Called at frame rate, so no logging here.
        lastListener = pose
        listenerUpdateCount += 1
    }

    func updateCue(_ parameters: CueParameters) {
        lastCue = parameters
    }

    func playEarcon(_ earcon: Earcon) {
        logger.info("playEarcon \(earcon.rawValue, privacy: .public)")
        lastEarcon = earcon
    }
}
