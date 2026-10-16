import Foundation
import simd
import CoreGraphics

// MARK: - Image space

/// Normalized point in UPRIGHT image space. (0,0) top-left, (1,1) bottom-right.
struct NormalizedPoint: Codable, Equatable {
    var x: Double
    var y: Double
}

/// Normalized rect in UPRIGHT image space.
struct NormalizedRect: Codable, Equatable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double

    var center: NormalizedPoint {
        NormalizedPoint(
            x: (minX + maxX) / 2.0,
            y: (minY + maxY) / 2.0
        )
    }

    /// Where the object meets the table. Used for raycasting so the ray
    /// hits the table at the object's base instead of behind the object.
    var baseCenter: NormalizedPoint {
        let height = maxY - minY
        return NormalizedPoint(
            x: (minX + maxX) / 2.0,
            y: maxY - (0.1 * height)
        )
    }
}

/// How the sensor image must be rotated to become upright.
enum UprightRotation: String, Codable {
    case portrait
    case landscapeRight
}

// MARK: - Perception

struct Detection: Codable, Equatable {
    var label: String            // what the vision model says it found, e.g. "blue mug"
    var box: NormalizedRect      // upright normalized
    var confidence: Double?      // 0...1 if provided
}

/// Copy of the LiDAR depth map at capture time (sensor orientation, e.g. 256 x 192).
/// Nil on phones without LiDAR.
struct DepthSnapshot {
    let width: Int
    let height: Int
    let depthMeters: [Float]              // row-major, width * height
    let confidence: [UInt8]               // ARConfidenceLevel raw values: 0 low, 1 medium, 2 high
}

/// Everything needed to turn a pixel in THIS photo into a 3D point later,
/// even after the phone has moved. Never store the ARFrame itself.
struct Snapshot {
    let id: UUID
    let capturedAt: Date
    let uprightJPEG: Data                 // sent to the vision model, long edge <= 1024 px
    let cameraTransform: simd_float4x4    // ARCamera.transform at capture time
    let intrinsics: simd_float3x3         // ARCamera.intrinsics, pixels, sensor orientation
    let sensorResolution: CGSize          // ARCamera.imageResolution, e.g. 1920 x 1440
    let uprightRotation: UprightRotation
    let depth: DepthSnapshot?             // LiDAR phones only
}

enum PlacementMethod: String, Codable {
    case lidarDepth
    case raycastExistingPlane
    case raycastEstimatedPlane
    case planeIntersection
    case fixedDepthFallback
    case manualTap
}

struct AnchoredTarget: Identifiable, Equatable {
    let id: UUID
    let label: String
    let worldPosition: SIMD3<Float>       // meters, ARKit world space
    let placement: PlacementMethod
    let createdAt: Date
}

enum TrackingSummary: Equatable {
    case notStarted
    case initializing
    case normal
    case limited(String)
}

// MARK: - Listener

/// Pose of the phone, ARKit world space.
struct BodyPose: Equatable {
    var position: SIMD3<Float>
    var forward: SIMD3<Float>             // horizontal unit vector, y == 0
}

/// Head rotation relative to the body (from AirPods). Identity = facing the same way as the phone.
struct HeadRotation: Equatable {
    var yawRadians: Float                 // + = head turned LEFT
    var pitchRadians: Float               // + = looking UP

    static let identity = HeadRotation(yawRadians: 0, pitchRadians: 0)
}

/// Where the listener's ears are and which way they face. Fed to the audio engine every frame.
struct ListenerPose: Equatable {
    var position: SIMD3<Float>
    var forward: SIMD3<Float>             // unit
    var up: SIMD3<Float>                  // unit
}

enum ListenerRig: Equatable {
    /// Phone on a stand in front of the user. Ears are behind and above the phone.
    case standInFront(backOffsetMeters: Float, upOffsetMeters: Float)
    /// Phone on the chest. Ears are above the phone.
    case chestMount(upOffsetMeters: Float)
}

enum HeadTrackingStatus: Equatable {
    case unavailable                      // no compatible headphones / API unavailable
    case disconnected
    case connected
    case calibrated
}

// MARK: - Audio

struct CueParameters: Equatable {
    var intervalSeconds: Double           // time between cue pulses
    var gain: Float                       // 0...1
    var isOnTarget: Bool
}

/// Spatialized cue sounds. Files live at Resources/Sounds/<rawValue>.wav, mono.
enum CueSoundID: String, CaseIterable, Codable {
    case primary = "cue_primary"
    case alt1 = "cue_alt1"
    case alt2 = "cue_alt2"
}

/// Non-spatial interface sounds (played centered). Files at Resources/Sounds/<rawValue>.wav.
enum Earcon: String, CaseIterable, Codable {
    case listeningStart = "earcon_listen_start"
    case listeningEnd = "earcon_listen_end"
    case located = "earcon_located"
    case notFound = "earcon_not_found"
    case found = "earcon_found"
}

/// Pre-recorded voice lines (v2.3, "Finder remembers"). Generated once with
/// ElevenLabs, shipped as files at Voice/Clips/<clipName>.wav, played centered.
/// Fixed clips, so no network and no TTS latency during a search.
enum VoicePrompt: Equatable {
    /// "Searching." Right after a request, while the vision model looks (v2.4). The next line cuts it off.
    case searching
    /// "Item not found, please turn." The vision model didn't see it and nothing is remembered.
    case notFoundTurn
    /// "Item found, navigating." The vision model found it; guidance starts.
    case foundNavigating
    /// "Navigating." Guidance to a remembered spot starts.
    case navigating

    /// Bundle file name without extension.
    var clipName: String {
        switch self {
        case .searching:
            return "voice_searching"
        case .notFoundTurn:
            return "voice_not_found_turn"
        case .foundNavigating:
            return "voice_found_navigating"
        case .navigating:
            return "voice_navigating"
        }
    }

    /// Every file the voice module must ship.
    static var allClipNames: [String] {
        return [
            VoicePrompt.searching.clipName,
            VoicePrompt.notFoundTurn.clipName,
            VoicePrompt.foundNavigating.clipName,
            VoicePrompt.navigating.clipName
        ]
    }
}

// MARK: - Study / rounds

/// Only Finder mode since v2.0 (the spoken-directions comparison was dropped).
/// Kept as a type so RoundResult / RoundSample JSON still carries "mode": "finder".
enum RoundMode: String, Codable {
    case finder = "finder"
}

struct ActiveRound: Equatable {
    let id: UUID
    let mode: RoundMode
    let objectLabel: String
    let startedAt: Date
}

struct RoundResult: Codable, Identifiable, Equatable {
    let id: UUID
    let participantId: String             // "P01", "P02", ...
    let mode: RoundMode
    let objectLabel: String
    let durationSeconds: Double
    let success: Bool
    let isPractice: Bool
    let headTrackingUsed: Bool
    let placement: PlacementMethod
    let startedAt: Date
    let appVersion: String
}

struct StudyStats: Codable, Equatable {
    let participants: Int                 // distinct participants with a valid round (non-practice, success)
    let finderRounds: Int
    let medianFinderSeconds: Double?
    let meanFinderSeconds: Double?
}

/// One sample of how the listener is searching during a round (~10 Hz).
/// Uploaded with the round when FOUND is tapped. Stored as time-series in Tiger Data.
struct RoundSample: Codable, Equatable {
    let roundId: UUID
    let secondsSinceStart: Double         // since the round timer started
    let mode: RoundMode
    let angleDegrees: Float               // listener forward to target, + = target to the RIGHT
    let distanceMeters: Float             // horizontal, listener to target
    let headYawDegrees: Float             // AirPods yaw, + = head turned LEFT (0 without AirPods)
}

/// One time the vision model found an object (v2.3, "Finder remembers"). The app keeps
/// these in memory for the session and also sends them to the backend
/// (POST /api/sightings) for the dashboard's "Last seen" panel.
/// Positions are ARKit world space for THIS AR session only.
struct ObjectSighting: Codable, Equatable {
    let id: UUID
    let participantId: String
    let objectLabel: String               // the vision model's label, e.g. "blue mug"
    let utterance: String                 // what the user asked, e.g. "where's my mug"
    let seenAt: Date
    let x: Float                          // meters, ARKit world, +Y up
    let y: Float
    let z: Float
    let placement: PlacementMethod
    let confidence: Double?
}

// MARK: - App state

enum FinderError: Error, Equatable {
    case cameraNotReady
    case trackingLimited(String)
    case objectNotFound(String)
    case locatorTimeout
    case locatorFailed(String)
    case placementFailed
    case audioEngineFailed(String)
    case speechNotAuthorized
    case speechFailed(String)
}

enum FinderState: Equatable {
    case setup                            // waiting for AR tracking == .normal
    case ready
    case listening
    case locating(utterance: String)
    case guiding(target: AnchoredTarget, round: ActiveRound)
    case found(result: RoundResult)
    case error(FinderError)
}

struct SystemStatus: Equatable {
    var tracking: TrackingSummary = .notStarted
    var planeDetected: Bool = false
    var headTracking: HeadTrackingStatus = .unavailable
    var backendReachable: Bool = false
    var pendingUploads: Int = 0
}

struct DebugInfo: Equatable {
    var lastUtterance: String?
    var lastDetection: Detection?
    var lastSnapshotJPEG: Data?           // show this with the box drawn on it, NOT the live preview
    var locatorLatencyMs: Int?
    var placement: PlacementMethod?
    var targetPosition: SIMD3<Float>?
    var targetDistanceMeters: Float?
    var targetAngleDegrees: Float?        // + = right
    var cue: CueParameters?
    var headRotation: HeadRotation = .identity
}
