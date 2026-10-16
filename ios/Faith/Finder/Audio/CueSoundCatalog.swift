import Foundation

/// Which bundled file each cue plays.
///
/// The contract default is `Resources/Sounds/<rawValue>.wav`.
/// `overrides` lets the audio module try a sound from `Audio/Sounds/` without
/// touching that folder. Once the chosen sound ships as `cue_primary.wav`,
/// delete the override here and the file in `Audio/Sounds/`.
enum CueSoundCatalog {
    static let overrides: [CueSoundID: String] = [:]

    /// Bundle resource name without the extension.
    static func resourceName(for id: CueSoundID) -> String {
        if let override = overrides[id] {
            return override
        }
        return id.rawValue
    }
}
