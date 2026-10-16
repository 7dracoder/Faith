import Foundation
import UIKit
import simd
import os

final class MockPerceptionService: PerceptionService {
    let previewView: UIView
    private(set) var trackingSummary: TrackingSummary = .notStarted
    private(set) var planeDetected = false

    var onBodyPoseUpdate: ((BodyPose) -> Void)?
    var onStatusChange: ((TrackingSummary, Bool) -> Void)?

    private let logger = Logger(subsystem: "app.faith.finder", category: "MockPerception")
    private var poseTimer: Timer?
    private var trackingWorkItem: DispatchWorkItem?
    /// Tests can move the fake phone (e.g. to simulate reaching toward an object).
    var bodyPose = BodyPose(
        position: SIMD3<Float>(0, 0, 0),
        forward: SIMD3<Float>(0, 0, -1)
    )

    init() {
        let view = UIView()
        view.backgroundColor = UIColor.darkGray

        let label = UILabel()
        label.text = "MOCK CAMERA"
        label.textColor = UIColor.white
        label.font = UIFont.preferredFont(forTextStyle: .title2)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        previewView = view
    }

    func start() {
        logger.info("start")
        setStatus(.initializing, plane: false)

        let workItem = DispatchWorkItem { [weak self] in
            self?.setStatus(.normal, plane: true)
        }
        trackingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)

        poseTimer?.invalidate()
        poseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else {
                return
            }
            self.onBodyPoseUpdate?(self.bodyPose)
        }
    }

    func pause() {
        logger.info("pause")
        trackingWorkItem?.cancel()
        poseTimer?.invalidate()
        poseTimer = nil
    }

    func currentBodyPose() -> BodyPose? {
        return bodyPose
    }

    func captureSnapshot() throws -> Snapshot {
        guard let url = Bundle.main.url(forResource: "mock_table", withExtension: "jpg") else {
            logger.error("mock_table.jpg missing from bundle")
            throw FinderError.cameraNotReady
        }
        let data = try Data(contentsOf: url)

        // Plausible iPhone wide-camera intrinsics for a 1920 x 1440 sensor image.
        let intrinsics = simd_float3x3(
            SIMD3<Float>(1500, 0, 0),
            SIMD3<Float>(0, 1500, 0),
            SIMD3<Float>(960, 720, 1)
        )

        return Snapshot(
            id: UUID(),
            capturedAt: Date(),
            uprightJPEG: data,
            cameraTransform: matrix_identity_float4x4,
            intrinsics: intrinsics,
            sensorResolution: CGSize(width: 1920, height: 1440),
            uprightRotation: .portrait,
            depth: nil
        )
    }

    func place(_ detection: Detection, from snapshot: Snapshot) async throws -> AnchoredTarget {
        try await Task.sleep(nanoseconds: 50_000_000)
        return AnchoredTarget(
            id: UUID(),
            label: detection.label,
            worldPosition: SIMD3<Float>(0.2, -0.3, -0.5),
            placement: .raycastExistingPlane,
            createdAt: Date()
        )
    }

    func placeAtViewPoint(_ point: CGPoint, label: String) throws -> AnchoredTarget {
        let width = max(previewView.bounds.width, 1)
        let fraction = min(max(point.x / width, 0), 1)
        let x = -0.4 + 0.8 * Float(fraction)

        return AnchoredTarget(
            id: UUID(),
            label: label,
            worldPosition: SIMD3<Float>(x, -0.3, -0.5),
            placement: .manualTap,
            createdAt: Date()
        )
    }

    func showDebugMarker(for target: AnchoredTarget) {
        logger.info("showDebugMarker at \(String(describing: target.worldPosition), privacy: .public)")
    }

    func clearDebugMarkers() {
        logger.info("clearDebugMarkers")
    }

    private func setStatus(_ tracking: TrackingSummary, plane: Bool) {
        trackingSummary = tracking
        planeDetected = plane
        onStatusChange?(tracking, plane)
    }
}
