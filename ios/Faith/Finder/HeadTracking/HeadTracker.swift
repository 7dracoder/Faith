import CoreMotion
import Foundation
import os

/// AirPods head tracking. Works with AirPods Pro, AirPods
/// 3rd gen and later, AirPods Max and some Beats. Call from the main thread.
final class HeadTracker: NSObject, HeadTracking {
    private(set) var status: HeadTrackingStatus = .unavailable
    var onStatusChange: ((HeadTrackingStatus) -> Void)?

    private let logger = Logger(subsystem: "app.faith.finder", category: "HeadTracker")
    private let manager = CMHeadphoneMotionManager()

    private var latestAttitude: CMAttitude?
    /// "Facing the phone". Until the operator calibrates, this is the first
    /// sample after the AirPods connect, so head tracking works right away.
    private var referenceAttitude: CMAttitude?
    private var latestRotation = HeadRotation.identity
    private var lastDebugLog = Date.distantPast

    func start() {
        guard manager.isDeviceMotionAvailable else {
            logger.info("Headphone motion is not available on this device")
            setStatus(.unavailable)
            return
        }

        let authorization = CMHeadphoneMotionManager.authorizationStatus()
        if authorization == .denied || authorization == .restricted {
            logger.error("Motion permission denied. Enable Motion & Fitness for Faith in Settings.")
            setStatus(.unavailable)
            return
        }

        if manager.isDeviceMotionActive {
            return
        }

        logger.info("start")
        manager.delegate = self
        setStatus(.disconnected)
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            self?.handleMotion(motion, error: error)
        }
    }

    func stop() {
        logger.info("stop")
        manager.stopDeviceMotionUpdates()
        clearMotion()
        if status != .unavailable {
            setStatus(.disconnected)
        }
    }

    func calibrate() {
        guard let attitude = latestAttitude else {
            logger.info("calibrate ignored, no headphone motion yet")
            return
        }
        guard let reference = attitude.copy() as? CMAttitude else {
            return
        }
        logger.info("calibrate")
        referenceAttitude = reference
        latestRotation = .identity
        setStatus(.calibrated)
    }

    func currentRotation() -> HeadRotation {
        switch status {
        case .connected, .calibrated:
            return latestRotation
        case .unavailable, .disconnected:
            return .identity
        }
    }

    // MARK: - Motion

    private func handleMotion(_ motion: CMDeviceMotion?, error: Error?) {
        if let error {
            logger.error("Headphone motion error: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let motion else {
            return
        }

        let attitude = motion.attitude
        latestAttitude = attitude

        if referenceAttitude == nil {
            referenceAttitude = attitude.copy() as? CMAttitude
        }
        // Motion can arrive before (or without) the connect callback.
        if status == .disconnected || status == .unavailable {
            setStatus(.connected)
        }

        latestRotation = relativeRotation(of: attitude)
        logRotationOccasionally()
    }

    private func relativeRotation(of attitude: CMAttitude) -> HeadRotation {
        guard let reference = referenceAttitude else {
            return .identity
        }
        guard let relative = attitude.copy() as? CMAttitude else {
            return .identity
        }
        relative.multiply(byInverseOf: reference)

        return HeadRotationMath.headRotation(
            rawYawRadians: relative.yaw,
            rawPitchRadians: relative.pitch
        )
    }

    private func clearMotion() {
        latestAttitude = nil
        referenceAttitude = nil
        latestRotation = .identity
    }

    private func logRotationOccasionally() {
        let now = Date()
        guard now.timeIntervalSince(lastDebugLog) >= 1 else {
            return
        }
        lastDebugLog = now

        let yawDegrees = latestRotation.yawRadians * 180 / Float.pi
        let pitchDegrees = latestRotation.pitchRadians * 180 / Float.pi
        logger.debug("yaw \(yawDegrees, privacy: .public) deg (+ left), pitch \(pitchDegrees, privacy: .public) deg (+ up)")
    }

    private func setStatus(_ newStatus: HeadTrackingStatus) {
        if status == newStatus {
            return
        }
        logger.info("status \(String(describing: newStatus), privacy: .public)")
        status = newStatus
        onStatusChange?(newStatus)
    }
}

// MARK: - CMHeadphoneMotionManagerDelegate

extension HeadTracker: CMHeadphoneMotionManagerDelegate {
    func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            // A new connection has a new reference frame, so the old calibration is void.
            self.clearMotion()
            self.setStatus(.connected)
        }
    }

    func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            self.clearMotion()
            self.setStatus(.disconnected)
        }
    }
}
