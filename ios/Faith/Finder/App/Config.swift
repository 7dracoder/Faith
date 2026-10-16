import Foundation

enum Config {
    /// Whole budget for one backend vision request. The coordinator adds 1 s on top.
    static let locatorTimeoutSeconds: TimeInterval = 25
    /// Holding this long on the booking screen books the quote.
    static let holdToAcceptSeconds: TimeInterval = 1.5
    /// Where the ears are relative to the phone. No stand: the phone is held against the
    /// chest, so the ears are ~35 cm straight above it. (With a stand in front of the user,
    /// use .standInFront(backOffsetMeters: 0.35, upOffsetMeters: 0.30).)
    static let rig = ListenerRig.chestMount(upOffsetMeters: 0.35)
    static let fallbackDepthMeters: Float = 0.6
    /// Non-LiDAR placements sit on the table; the sound is raised to the object's middle.
    /// The lift is half the object's estimated height (RayMath.centerLift), clamped to
    /// minimum...maximum. objectCenterLiftMeters is the fallback when it can't be estimated.
    static let objectCenterLiftMeters: Float = 0.05
    static let minimumObjectCenterLiftMeters: Float = 0.005
    static let maximumObjectCenterLiftMeters: Float = 0.10
    static let onTargetThresholdDegrees: Float = 12
    /// Detector bubble (DetectorCue): once the phone is this close to the object, the cue
    /// follows the phone's distance instead of the head's angle.
    static let detectorEnterRadiusMeters: Float = 0.30
    static let detectorExitRadiusMeters: Float = 0.38
    static let detectorTouchingMeters: Float = 0.05
    static let detectorOnTargetMeters: Float = 0.08
    /// The phone held this close to the object for this long ends the round with the chime.
    static let arrivalRadiusMeters: Float = 0.25
    static let arrivalHoldSeconds: TimeInterval = 0.5
    static let detectorSlowestIntervalSeconds: Double = 0.35
    static let detectorFastestIntervalSeconds: Double = 0.06
    /// ReachLock: ears lock when within arm's reach of the object, unlock when the phone
    /// is farther than this (the user walked away).
    static let reachLockMeters: Float = 0.70
    static let reachUnlockMeters: Float = 1.00

    // "Finder remembers"
    /// Pre-recorded status lines ("Item found, navigating", ...). Off = earcons only.
    static let voicePromptsEnabled = true
    /// Voice line loudness (0...1). Full volume was jarring next to the cue in testing.
    static let voiceLineVolume: Float = 0.45
    /// Say "The camera is still starting…" after this long stuck in setup, then every N seconds.
    static let cameraStartingAnnounceAfterSeconds: TimeInterval = 3
    static let cameraStartingRepeatSeconds: TimeInterval = 15
    static let knownObjects = [
        "mug", "cup", "bottle", "keys", "phone", "wallet",
        "glasses", "remote", "pen", "headphones", "apple"
    ]
    /// Real services by default; perception falls back to the mock where ARKit is missing.
    static let defaultFlags = ServiceFlags(
        mockPerception: false,
        mockLocator: false,
        mockHeadTracking: false,
        mockAudio: false,
        mockVoice: false,
        mockTelemetry: true
    )
    static let appVersion = "0.1.0"
}
