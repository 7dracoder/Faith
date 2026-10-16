import Foundation
import os

/// STOPGAP until the coordinator's "Finder remembers" flow lands.
/// That flow plays the voice lines itself, including "previously found N minutes
/// ago"; when it is merged, drop `announcements` from Local.xcconfig, remove the
/// `wrapIfEnabled` line from AppEnvironment and delete this file, or every line
/// would be spoken twice.
///
/// Until then this wraps any `ObjectLocator` and plays the same recorded lines:
/// "Item found, navigating." right before guidance (the beeping) starts, and
/// "Item not found, please turn." when the camera cannot see the object.
/// Other failures (timeout, network) stay silent; the not-found earcon covers them.
final class AnnouncingLocator: ObjectLocator {
    /// Name to add to `FINDER_REAL_SERVICES` (Local.xcconfig) to turn the announcements on.
    /// ServiceFlags ignores names it does not know, so it can sit next to the service names.
    static let serviceName = "announcements"
    /// UserDefaults override, e.g. launch argument `-flag.announcements YES`.
    static let defaultsKey = "flag.announcements"

    private let wrapped: ObjectLocator
    private let prompts: VoicePromptPlaying

    init(wrapping wrapped: ObjectLocator, prompts: VoicePromptPlaying) {
        self.wrapped = wrapped
        self.prompts = prompts
    }

    /// `locator` with spoken announcements when they are switched on, otherwise `locator` itself.
    @MainActor
    static func wrapIfEnabled(
        _ locator: ObjectLocator,
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> ObjectLocator {
        var override: Bool?
        if defaults.object(forKey: defaultsKey) != nil {
            override = defaults.bool(forKey: defaultsKey)
        }
        let realServices = bundle.object(forInfoDictionaryKey: "FINDER_REAL_SERVICES") as? String
        guard isEnabled(realServices: realServices ?? "", override: override) else {
            return locator
        }
        // No cue is playing while an object is being located, so there is nothing to duck.
        let player = VoicePromptPlayer(ducking: nil, bundle: bundle)
        return AnnouncingLocator(wrapping: locator, prompts: player)
    }

    /// `realServices` is space or comma separated, case-insensitive (same rule as ServiceFlags).
    /// A UserDefaults `override` wins.
    static func isEnabled(realServices: String, override: Bool?) -> Bool {
        if let override {
            return override
        }
        let separators = CharacterSet(charactersIn: " ,")
        let names = realServices.lowercased().components(separatedBy: separators)
        return names.contains(serviceName)
    }

    // MARK: - ObjectLocator

    func locate(utterance: String, in snapshot: Snapshot) async throws -> Detection {
        let detection: Detection
        do {
            detection = try await wrapped.locate(utterance: utterance, in: snapshot)
        } catch FinderError.objectNotFound(let what) {
            // Finish the line before the error surfaces, so the not-found earcon comes after the words.
            await prompts.play(.notFoundTurn)
            throw FinderError.objectNotFound(what)
        }

        try Task.checkCancellation()
        // The coordinator starts the cue as soon as this returns, so wait for the line to end.
        await prompts.play(.foundNavigating)
        return detection
    }
}
