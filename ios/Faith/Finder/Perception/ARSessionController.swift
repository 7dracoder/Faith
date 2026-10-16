import Foundation
import ARKit
import RealityKit
import UIKit
import os

/// Real `PerceptionService`: RealityKit ARView + ARKit world tracking.
/// Device only. AppEnvironment falls back to the mock when ARKit is unsupported (simulator).
///
/// Layer 1: session, body pose, tap-to-place, debug markers.
/// Layer 2: snapshot capture and detection placement (LiDAR first, then raycasts from
/// the SAVED snapshot camera, plane intersection, fixed depth).
///
/// Device test without the vision model (debug mode only, `debug.showMarkers`): switch on the
/// "Test mode" button in the preview, then TAP. Each tap also runs the full photo pipeline. The pressed point goes through
/// the full photo pipeline and is compared with a direct screen raycast:
/// red = direct, blue = LiDAR path, green = non-LiDAR path; offsets shown in the readout.
/// (No extra gestures: a long-press linked to the tap crashed UIKit's gesture graph inside
/// SwiftUI, and a two-finger tap never arrived. The normal tap is known to work.)
final class ARSessionController: NSObject, PerceptionService, ARSessionDelegate {
    let previewView: UIView
    private(set) var trackingSummary: TrackingSummary = .notStarted
    private(set) var planeDetected = false

    var onBodyPoseUpdate: ((BodyPose) -> Void)?
    var onStatusChange: ((TrackingSummary, Bool) -> Void)?

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.isSupported
    }

    /// UserDefaults key: true forces `depth = nil` in snapshots (test the non-LiDAR path).
    static let disableLiDARKey = "debug.disableLiDAR"

    private let arView: ARView
    private let debugMarkers: DebugMarkers
    private let snapshotCapturer = SnapshotCapturer()
    private let debugLabel = UILabel()
    private let logger = Logger(subsystem: "app.faith.finder", category: "Perception")

    private var latestBodyPose: BodyPose?
    private var lastForward = SIMD3<Float>(0, 0, -1)
    /// World Y of every horizontal plane ARKit has found, for plane intersection.
    private var horizontalPlaneHeights: [UUID: Float] = [:]
    private var hasStartedOnce = false
    private var usesLiDAR = false

    /// Targets whose tap raycast missed and fell back to fixed depth. Drawn yellow instead of red.
    private var fallbackTargetIDs = Set<UUID>()
    private var lastTapDescription = "none"
    private var lastDetectDescription = "turn on Test mode, then tap"
    private var isDetectionTestMode = false
    private let testModeButton = UIButton(type: .system)
    /// Debug only: freezes the camera like a sensor failure, to watch auto-recovery.
    private let stopCameraButton = UIButton(type: .system)

    /// Auto-recovery (ARRecovery): true between start() and pause().
    private var isRunning = false
    private var lastFrameAt: Date?
    private var recoveryAttempts = 0
    private var recoveryWorkItem: DispatchWorkItem?
    private var watchdogTimer: Timer?
    private var recoveryDescription = "none"

    override init() {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        arView = view
        previewView = view
        debugMarkers = DebugMarkers(arView: view)
        super.init()

        view.session.delegate = self
        installDebugLabel()
        installDetectionTestGesture()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(thermalStateChanged),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
    }

    deinit {
        watchdogTimer?.invalidate()
        recoveryWorkItem?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Lifecycle

    func start() {
        let resetWorld = !hasStartedOnce
        hasStartedOnce = true
        isRunning = true
        recoveryAttempts = 0
        lastFrameAt = Date()
        runSession(resetWorld: resetWorld)
        startWatchdog()
    }

    func pause() {
        logger.info("Pausing AR session")
        isRunning = false
        stopWatchdog()
        recoveryWorkItem?.cancel()
        recoveryWorkItem = nil
        arView.session.pause()
    }

    private func runSession(resetWorld: Bool) {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]

        usesLiDAR = ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
        if usesLiDAR {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }

        var options: ARSession.RunOptions = []
        if resetWorld {
            options = [.resetTracking, .removeExistingAnchors]
        }

        logger.info("Starting AR session, LiDAR depth: \(self.usesLiDAR, privacy: .public), new world: \(resetWorld, privacy: .public)")
        arView.session.run(configuration, options: options)
        setStatus(tracking: .initializing, planeDetected: planeDetected)
    }

    // MARK: - Auto-recovery (ARRecovery)

    /// Restarts the session after a short wait. First attempt keeps the world;
    /// later attempts start a fresh one and tell the app (finderARWorldDidReset).
    private func scheduleRecovery(reason: String) {
        guard isRunning else {
            return
        }
        guard recoveryWorkItem == nil else {
            // A restart is already on its way.
            return
        }
        recoveryAttempts += 1
        let attempt = recoveryAttempts
        let delay = ARRecovery.delaySeconds(attempt: attempt)
        let resetWorld = ARRecovery.shouldResetWorld(attempt: attempt)
        logger.warning("AR recovery #\(attempt, privacy: .public) in \(delay, privacy: .public) s (\(reason, privacy: .public)), new world: \(resetWorld, privacy: .public)")
        recoveryDescription = "#\(attempt) after \(reason)"
        refreshDebugLabel()

        let work = DispatchWorkItem { [weak self] in
            self?.recover(resetWorld: resetWorld)
        }
        recoveryWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func recover(resetWorld: Bool) {
        recoveryWorkItem = nil
        guard isRunning else {
            return
        }
        if resetWorld {
            horizontalPlaneHeights.removeAll()
            planeDetected = false
            debugMarkers.clear()
            fallbackTargetIDs.removeAll()
        }
        // Give the restart a grace period before the watchdog may call it stalled again.
        lastFrameAt = Date().addingTimeInterval(ARRecovery.restartGraceSeconds - ARRecovery.stalledFrameSeconds)
        runSession(resetWorld: resetWorld)
        if resetWorld {
            NotificationCenter.default.post(name: .finderARWorldDidReset, object: self)
        }
    }

    private func startWatchdog() {
        stopWatchdog()
        let timer = Timer(timeInterval: ARRecovery.watchdogIntervalSeconds, repeats: true) { [weak self] _ in
            self?.checkForStalledFrames()
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func checkForStalledFrames() {
        let stalled = ARRecovery.isStalled(lastFrameAt: lastFrameAt, now: Date(), isRunning: isRunning)
        guard stalled else {
            return
        }
        // Background / interruptions pause frames on purpose; only recover in the foreground.
        guard UIApplication.shared.applicationState == .active else {
            return
        }
        scheduleRecovery(reason: "no camera frames")
    }

    @objc private func thermalStateChanged() {
        DispatchQueue.main.async {
            let state = ProcessInfo.processInfo.thermalState
            self.logger.warning("Phone temperature: \(ARRecovery.describe(state), privacy: .public)")
            self.refreshDebugLabel()
        }
    }

    func currentBodyPose() -> BodyPose? {
        return latestBodyPose
    }

    // MARK: - Layer 2: snapshot capture

    func captureSnapshot() throws -> Snapshot {
        if case .limited(let reason) = trackingSummary {
            throw FinderError.trackingLimited(reason)
        }
        guard let frame = arView.session.currentFrame else {
            throw FinderError.cameraNotReady
        }
        let includeDepth = !UserDefaults.standard.bool(forKey: Self.disableLiDARKey)
        return try snapshotCapturer.capture(from: frame, includeDepth: includeDepth)
    }

    // MARK: - Layer 2: detection placement

    func place(_ detection: Detection, from snapshot: Snapshot) async throws -> AnchoredTarget {
        let placed = locate(detection.box, in: snapshot)
        guard placed.method != .fixedDepthFallback else {
            // Faith never guides to a guessed distance.
            throw FinderError.placementFailed
        }

        var position = placed.position
        var lift: Float = 0
        if placed.method != .lidarDepth {
            // Raycast / plane / fixed-depth points sit on the table: lift to the object's
            // middle, sized from the box (a flat pen ~1 cm, a mug ~5 cm, a bottle up to 10 cm).
            lift = RayMath.centerLift(box: detection.box, basePoint: placed.position, snapshot: snapshot)
            position.y += lift
        }

        let liftText = String(format: "%.1f cm", lift * 100)
        logger.info("Placed \(detection.label, privacy: .public) via \(placed.method.rawValue, privacy: .public), lift \(liftText, privacy: .public), at \(Self.format(position), privacy: .public)")

        return AnchoredTarget(
            id: UUID(),
            label: detection.label,
            worldPosition: position,
            placement: placed.method,
            createdAt: Date()
        )
    }

    /// Placement order, WITHOUT the object-center lift.
    /// Everything is built from the SAVED snapshot camera, never the live camera.
    private func locate(_ box: NormalizedRect, in snapshot: Snapshot) -> (position: SIMD3<Float>, method: PlacementMethod) {
        // 0. LiDAR: the object itself, so use its center.
        if let lidarPoint = RayMath.worldPointFromDepth(uprightPoint: box.center, snapshot: snapshot) {
            return (lidarPoint, .lidarDepth)
        }

        // 1-4. Non-LiDAR: where the object meets the table, so use its base.
        let ray = RayMath.ray(through: box.baseCenter, snapshot: snapshot)

        if let hit = raycast(ray, allowing: .existingPlaneGeometry, alignment: .horizontal) {
            return (hit, .raycastExistingPlane)
        }
        if let hit = raycast(ray, allowing: .estimatedPlane, alignment: .any) {
            return (hit, .raycastEstimatedPlane)
        }
        if let hit = nearestPlaneIntersection(ray) {
            return (hit, .planeIntersection)
        }
        let fallback = RayMath.point(along: ray, distance: Config.fallbackDepthMeters)
        return (fallback, .fixedDepthFallback)
    }

    private func raycast(
        _ ray: Ray,
        allowing target: ARRaycastQuery.Target,
        alignment: ARRaycastQuery.TargetAlignment
    ) -> SIMD3<Float>? {
        let query = ARRaycastQuery(
            origin: ray.origin,
            direction: ray.direction,
            allowing: target,
            alignment: alignment
        )
        let results = arView.session.raycast(query)
        guard let first = results.first else {
            return nil
        }
        return Self.translation(of: first.worldTransform)
    }

    private func nearestPlaneIntersection(_ ray: Ray) -> SIMD3<Float>? {
        var best: SIMD3<Float>?
        var bestDistance = Float.greatestFiniteMagnitude
        for planeY in horizontalPlaneHeights.values {
            guard let hit = RayMath.intersectHorizontalPlane(ray: ray, planeY: planeY) else {
                continue
            }
            let distance = simd_distance(ray.origin, hit)
            if distance < bestDistance {
                bestDistance = distance
                best = hit
            }
        }
        return best
    }

    // MARK: - Layer 1: tap to place

    func placeAtViewPoint(_ point: CGPoint, label: String) throws -> AnchoredTarget {
        if isDetectionTestMode && debugMarkers.isEnabled {
            // Run after the coordinator has cleared and redrawn its own marker for this tap.
            DispatchQueue.main.async { [weak self] in
                self?.runDetectionTest(at: point)
            }
        }

        let worldPosition: SIMD3<Float>
        var usedFallback = false

        let hits = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .any)
        if let hit = hits.first {
            worldPosition = Self.translation(of: hit.worldTransform)
        } else {
            guard let screenRay = arView.ray(through: point) else {
                logger.error("Tap at \(String(describing: point), privacy: .public): no raycast hit and no screen ray")
                throw FinderError.placementFailed
            }
            let ray = Ray(
                origin: screenRay.origin,
                direction: simd_normalize(screenRay.direction)
            )
            worldPosition = RayMath.point(along: ray, distance: Config.fallbackDepthMeters)
            usedFallback = true
        }

        let target = AnchoredTarget(
            id: UUID(),
            label: label,
            worldPosition: worldPosition,
            placement: .manualTap,
            createdAt: Date()
        )

        if usedFallback {
            fallbackTargetIDs.insert(target.id)
        }

        let method = usedFallback ? "fallback 0.6 m" : "raycast"
        lastTapDescription = "\(method) \(Self.format(worldPosition))"
        logger.info("Tap at \(String(describing: point), privacy: .public) -> \(self.lastTapDescription, privacy: .public)")
        refreshDebugLabel()

        return target
    }

    func showDebugMarker(for target: AnchoredTarget) {
        var color = UIColor.red
        if fallbackTargetIDs.contains(target.id) {
            color = UIColor.yellow
        }
        debugMarkers.show(at: target.worldPosition, color: color)
    }

    func clearDebugMarkers() {
        debugMarkers.clear()
    }

    // MARK: - ARSessionDelegate (called on main)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Read only what we need. Never keep a reference to `frame`.
        let transform = frame.camera.transform
        let trackingState = frame.camera.trackingState

        lastFrameAt = Date()

        let pose = Self.bodyPose(fromCameraTransform: transform, previousForward: lastForward)
        lastForward = pose.forward
        latestBodyPose = pose
        onBodyPoseUpdate?(pose)

        let summary = Self.summary(from: trackingState)
        if summary != trackingSummary {
            logger.info("Tracking: \(String(describing: summary), privacy: .public)")
            setStatus(tracking: summary, planeDetected: planeDetected)
        }
        if summary == .normal && recoveryAttempts > 0 {
            logger.info("AR recovered after \(self.recoveryAttempts, privacy: .public) restart(s)")
            recoveryAttempts = 0
            recoveryDescription = "recovered"
            refreshDebugLabel()
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        updatePlanes(addedOrUpdated: anchors, removed: [])
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        updatePlanes(addedOrUpdated: anchors, removed: [])
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        updatePlanes(addedOrUpdated: [], removed: anchors)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        let code = (error as NSError).code
        logger.error("AR session failed (code \(code, privacy: .public)): \(error.localizedDescription, privacy: .public)")
        setStatus(tracking: .limited("Session failed, restarting"), planeDetected: planeDetected)
        scheduleRecovery(reason: "session failed (\(code))")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        logger.warning("AR session interrupted")
        setStatus(tracking: .limited("Interrupted"), planeDetected: planeDetected)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        logger.info("AR session interruption ended, relocalizing")
        lastFrameAt = Date()
    }

    /// Try to snap back into the same world after an interruption, so positions stay valid.
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool {
        return true
    }

    // MARK: - Pure helpers (unit tested)

    static func bodyPose(
        fromCameraTransform transform: simd_float4x4,
        previousForward: SIMD3<Float>
    ) -> BodyPose {
        let position = translation(of: transform)
        let forward = Geometry.horizontalForward(fromCameraTransform: transform) ?? previousForward
        return BodyPose(position: position, forward: forward)
    }

    static func summary(from state: ARCamera.TrackingState) -> TrackingSummary {
        switch state {
        case .normal:
            return .normal
        case .notAvailable:
            return .limited("Not available")
        case .limited(let reason):
            switch reason {
            case .initializing:
                return .initializing
            case .excessiveMotion:
                return .limited("Moving too fast")
            case .insufficientFeatures:
                return .limited("Not enough texture")
            case .relocalizing:
                return .limited("Relocalizing")
            @unknown default:
                return .limited("Limited")
            }
        }
    }

    static func translation(of transform: simd_float4x4) -> SIMD3<Float> {
        let column = transform.columns.3
        return SIMD3<Float>(column.x, column.y, column.z)
    }

    // MARK: - Private

    private func updatePlanes(addedOrUpdated: [ARAnchor], removed: [ARAnchor]) {
        for anchor in addedOrUpdated {
            guard let plane = anchor as? ARPlaneAnchor else {
                continue
            }
            if plane.alignment == .horizontal {
                horizontalPlaneHeights[plane.identifier] = plane.transform.columns.3.y
            }
        }
        for anchor in removed {
            horizontalPlaneHeights.removeValue(forKey: anchor.identifier)
        }

        let detected = !horizontalPlaneHeights.isEmpty
        if detected != planeDetected {
            logger.info("Horizontal plane detected: \(detected, privacy: .public)")
            setStatus(tracking: trackingSummary, planeDetected: detected)
        }
    }

    private func setStatus(tracking: TrackingSummary, planeDetected detected: Bool) {
        trackingSummary = tracking
        planeDetected = detected
        refreshDebugLabel()
        onStatusChange?(tracking, detected)
    }

    // MARK: - On-screen debug readout (device testing)

    private func installDebugLabel() {
        debugLabel.numberOfLines = 0
        debugLabel.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        debugLabel.textColor = UIColor.white
        debugLabel.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        debugLabel.isUserInteractionEnabled = false
        debugLabel.translatesAutoresizingMaskIntoConstraints = false
        arView.addSubview(debugLabel)

        let guide = arView.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            debugLabel.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            debugLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
            debugLabel.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -8)
        ])
        refreshDebugLabel()
    }

    private func refreshDebugLabel() {
        debugLabel.isHidden = !debugMarkers.isEnabled

        let planeText = planeDetected ? "yes" : "no"
        let lidarText = usesLiDAR ? "yes" : "no"
        let lines = [
            " tracking: \(Self.describe(trackingSummary)) ",
            " plane: \(planeText)   lidar: \(lidarText) ",
            " last tap: \(lastTapDescription) ",
            " detect test: \(lastDetectDescription) ",
            " heat: \(ARRecovery.describe(ProcessInfo.processInfo.thermalState))   recovery: \(recoveryDescription) "
        ]
        debugLabel.text = lines.joined(separator: "\n")
    }

    private static func describe(_ summary: TrackingSummary) -> String {
        switch summary {
        case .notStarted:
            return "not started"
        case .initializing:
            return "initializing"
        case .normal:
            return "normal"
        case .limited(let reason):
            return "limited (\(reason))"
        }
    }

    // MARK: - Detection test (long-press, device only)

    private func installDetectionTestGesture() {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.6)
        configuration.baseForegroundColor = UIColor.white
        configuration.cornerStyle = .medium
        testModeButton.configuration = configuration
        testModeButton.translatesAutoresizingMaskIntoConstraints = false
        testModeButton.addTarget(self, action: #selector(toggleDetectionTestMode), for: .touchUpInside)
        arView.addSubview(testModeButton)

        stopCameraButton.configuration = configuration
        stopCameraButton.translatesAutoresizingMaskIntoConstraints = false
        stopCameraButton.setTitle("Stop camera", for: .normal)
        stopCameraButton.addTarget(self, action: #selector(simulateCameraFailure), for: .touchUpInside)
        arView.addSubview(stopCameraButton)

        let guide = arView.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            testModeButton.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            testModeButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
            testModeButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            stopCameraButton.topAnchor.constraint(equalTo: testModeButton.bottomAnchor, constant: 8),
            stopCameraButton.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),
            stopCameraButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        refreshTestModeButton()
    }

    /// Pauses the session behind the app's back: frames stop, as when the camera dies.
    /// The watchdog should restart it within ~5 s. Press again before it recovers to
    /// force the second attempt (fresh world).
    @objc private func simulateCameraFailure() {
        logger.warning("Debug: simulating a camera failure (session paused without telling the app)")
        recoveryDescription = "simulated failure, waiting"
        refreshDebugLabel()
        arView.session.pause()
        if recoveryAttempts > 0 {
            // Already recovering once: make the next attempt the fresh-world one.
            lastFrameAt = Date.distantPast
        }
    }

    @objc private func toggleDetectionTestMode() {
        isDetectionTestMode.toggle()
        logger.info("Detection test mode: \(self.isDetectionTestMode, privacy: .public)")
        refreshTestModeButton()
    }

    private func refreshTestModeButton() {
        testModeButton.isHidden = !debugMarkers.isEnabled
        stopCameraButton.isHidden = !debugMarkers.isEnabled
        let title = isDetectionTestMode ? "Test mode: ON" : "Test mode: OFF"
        testModeButton.setTitle(title, for: .normal)
    }

    /// Pretends the vision model found a tiny object at `viewPoint` and runs the full photo
    /// pipeline twice (with and without LiDAR), next to a direct screen raycast.
    private func runDetectionTest(at viewPoint: CGPoint) {
        let snapshot: Snapshot
        do {
            snapshot = try captureSnapshot()
        } catch {
            lastDetectDescription = "snapshot failed: \(error)"
            refreshDebugLabel()
            return
        }

        let uprightSize = CGSize(
            width: snapshot.sensorResolution.height,
            height: snapshot.sensorResolution.width
        )
        let upright = Self.uprightNormalized(
            fromViewPoint: viewPoint,
            viewSize: arView.bounds.size,
            uprightImageSize: uprightSize
        )
        let box = NormalizedRect(
            minX: upright.x - 0.005,
            minY: upright.y - 0.005,
            maxX: upright.x + 0.005,
            maxY: upright.y + 0.005
        )

        let directHits = arView.raycast(from: viewPoint, allowing: .estimatedPlane, alignment: .any)
        let direct = directHits.first.map { Self.translation(of: $0.worldTransform) }

        let withLiDAR = locate(box, in: snapshot)
        let noDepthSnapshot = Snapshot(
            id: snapshot.id,
            capturedAt: snapshot.capturedAt,
            uprightJPEG: snapshot.uprightJPEG,
            cameraTransform: snapshot.cameraTransform,
            intrinsics: snapshot.intrinsics,
            sensorResolution: snapshot.sensorResolution,
            uprightRotation: snapshot.uprightRotation,
            depth: nil
        )
        let withoutLiDAR = locate(box, in: noDepthSnapshot)

        debugMarkers.clear()
        if let direct {
            debugMarkers.show(at: direct, color: UIColor.red)
        }
        if withLiDAR.method == .lidarDepth {
            debugMarkers.show(at: withLiDAR.position, color: UIColor.blue)
        }
        debugMarkers.show(at: withoutLiDAR.position, color: UIColor.green)

        var parts: [String] = []
        let uprightText = String(format: "upright (%.2f, %.2f)", upright.x, upright.y)
        parts.append(uprightText)
        if withLiDAR.method == .lidarDepth {
            parts.append("lidar \(Self.offsetText(withLiDAR.position, from: direct))")
        } else {
            parts.append("lidar n/a")
        }
        parts.append("\(withoutLiDAR.method.rawValue) \(Self.offsetText(withoutLiDAR.position, from: direct))")
        lastDetectDescription = parts.joined(separator: ", ")

        logger.info("Detection test at \(String(describing: viewPoint), privacy: .public): \(self.lastDetectDescription, privacy: .public)")
        refreshDebugLabel()
    }

    private static func offsetText(_ position: SIMD3<Float>, from direct: SIMD3<Float>?) -> String {
        guard let direct else {
            return "(no red)"
        }
        let centimeters = simd_distance(position, direct) * 100
        return String(format: "%.1f cm", centimeters)
    }

    /// View point -> UPRIGHT normalized image point, assuming the preview shows the upright
    /// camera image aspect-FILLED (centered, cropped). Independent of ImageSpace on purpose,
    /// so the detection test really checks the upright -> sensor mapping.
    static func uprightNormalized(
        fromViewPoint point: CGPoint,
        viewSize: CGSize,
        uprightImageSize: CGSize
    ) -> NormalizedPoint {
        let scale = max(
            viewSize.width / uprightImageSize.width,
            viewSize.height / uprightImageSize.height
        )
        let displayedWidth = uprightImageSize.width * scale
        let displayedHeight = uprightImageSize.height * scale
        let cropX = (displayedWidth - viewSize.width) / 2
        let cropY = (displayedHeight - viewSize.height) / 2

        let x = (point.x + cropX) / displayedWidth
        let y = (point.y + cropY) / displayedHeight
        return NormalizedPoint(x: Double(x), y: Double(y))
    }

    private static func format(_ position: SIMD3<Float>) -> String {
        return String(format: "(%.2f, %.2f, %.2f)", position.x, position.y, position.z)
    }
}
