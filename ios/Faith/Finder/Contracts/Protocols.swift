import Foundation
import UIKit
import simd

// MARK: - Perception

protocol PerceptionService: AnyObject {
    /// The camera preview (an ARView under the hood). UI embeds this view.
    var previewView: UIView { get }

    var trackingSummary: TrackingSummary { get }
    var planeDetected: Bool { get }

    /// Called on main at frame rate.
    var onBodyPoseUpdate: ((BodyPose) -> Void)? { get set }
    /// Called on main when tracking state or plane detection changes.
    var onStatusChange: ((TrackingSummary, Bool) -> Void)? { get set }

    func start()
    func pause()

    func currentBodyPose() -> BodyPose?

    /// Copies what we need out of the current ARFrame and releases it.
    func captureSnapshot() throws -> Snapshot

    /// Turns a detection from `snapshot` into a world position using the
    /// camera pose saved in the snapshot (NOT the live camera).
    func place(_ detection: Detection, from snapshot: Snapshot) async throws -> AnchoredTarget

    /// Layer 1: place a target where the operator tapped the preview.
    func placeAtViewPoint(_ point: CGPoint, label: String) throws -> AnchoredTarget

    func showDebugMarker(for target: AnchoredTarget)
    func clearDebugMarkers()
}

protocol ObjectLocator: AnyObject {
    /// One vision call. Interprets the request AND finds the object.
    /// Throws FinderError.objectNotFound, .locatorTimeout, .locatorFailed.
    func locate(utterance: String, in snapshot: Snapshot) async throws -> Detection
}

// MARK: - Head tracking and audio

protocol HeadTracking: AnyObject {
    var status: HeadTrackingStatus { get }
    var onStatusChange: ((HeadTrackingStatus) -> Void)? { get set }

    func start()
    func stop()

    /// "Face the phone now." Current head orientation becomes identity.
    func calibrate()

    /// Returns .identity when unavailable or disconnected. Cheap, call every frame.
    func currentRotation() -> HeadRotation
}

protocol SpatialAudioRendering: AnyObject {
    var isRunning: Bool { get }

    /// Configures AVAudioSession and starts the engine. Audio module is the ONLY
    /// owner of AVAudioSession configuration in the app.
    func start() throws
    func stop()

    func setCueSound(_ id: CueSoundID)
    func setTarget(_ target: AnchoredTarget)
    func clearTarget()

    func updateListener(_ pose: ListenerPose)
    func updateCue(_ parameters: CueParameters)

    func playEarcon(_ earcon: Earcon)
}

// MARK: - Voice and telemetry

protocol VoiceCommandListening: AnyObject {
    func requestAuthorization() async -> Bool
    /// Push-to-talk press.
    func startListening() throws
    /// Push-to-talk release. Returns the final transcript ("" if nothing heard).
    func stopListening() async -> String
    /// Optional live partial transcript for the UI.
    var onPartialTranscript: ((String) -> Void)? { get set }
}

/// v2.3: plays the pre-recorded voice lines (VoicePrompt), implemented
/// on the audio module's AVAudioSession; the cue keeps running underneath.
protocol VoicePromptPlaying: AnyObject {
    /// Returns when the clip has finished (or right away if it can't be played).
    /// A new prompt interrupts the one that is playing.
    func play(_ prompt: VoicePrompt) async
    func stop()
}

protocol TelemetryReporting: AnyObject {
    var pendingCount: Int { get }
    func report(_ result: RoundResult) async
    func fetchStats() async -> StudyStats?
    func ping() async -> Bool
    /// Stretch (v1.5): uploads one finished round's search trajectory.
    func reportSamples(_ samples: [RoundSample]) async
    /// v2.3: one sighting, for the dashboard's "Last seen" panel.
    func reportSighting(_ sighting: ObjectSighting) async
}

extension TelemetryReporting {
    /// Default: drop samples, so implementations without the stretch still conform.
    func reportSamples(_ samples: [RoundSample]) async {
    }

    /// Default: drop sightings, so telemetry clients need not implement it.
    func reportSighting(_ sighting: ObjectSighting) async {
    }
}
