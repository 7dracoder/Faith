import Foundation

/// What the voice module needs from the audio engine: the cue
/// keeps running under a voice line, just quieter. Call from the main thread.
protocol CueDucking: AnyObject {
    func setCueDucked(_ isDucked: Bool)
}
