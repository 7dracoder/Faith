import Foundation
import os

final class MockHeadTracker: HeadTracking {
    private(set) var status: HeadTrackingStatus = .unavailable
    var onStatusChange: ((HeadTrackingStatus) -> Void)?

    private let logger = Logger(subsystem: "app.faith.finder", category: "MockHeadTracker")
    private var startedAt = Date()
    private var isRunning = false

    /// Yaw sweeps +/- 30 degrees with a 6 s period.
    private let amplitudeRadians: Float = 30 * Float.pi / 180
    private let periodSeconds: Double = 6

    func start() {
        logger.info("start")
        isRunning = true
        startedAt = Date()
        setStatus(.connected)
    }

    func stop() {
        logger.info("stop")
        isRunning = false
        setStatus(.disconnected)
    }

    func calibrate() {
        logger.info("calibrate")
        startedAt = Date()
        setStatus(.calibrated)
    }

    func currentRotation() -> HeadRotation {
        guard isRunning else {
            return .identity
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        let phase = 2 * Double.pi * elapsed / periodSeconds
        let yaw = amplitudeRadians * Float(sin(phase))
        return HeadRotation(yawRadians: yaw, pitchRadians: 0)
    }

    private func setStatus(_ newStatus: HeadTrackingStatus) {
        status = newStatus
        onStatusChange?(newStatus)
    }
}
