import Foundation
import simd

/// "Finder remembers": where the vision model last saw each object this AR session.
/// Filled only from answers we already got, so it never costs an extra vision call.
/// Positions are ARKit world space of THIS session; clear when the session resets.
struct ObjectMemory {
    private(set) var sightings: [ObjectSighting] = []

    /// Words that say nothing about which object is meant.
    static let fillerWords: Set<String> = [
        "a", "an", "the", "my", "me", "i", "is", "are", "was", "it", "its", "of", "to", "for",
        "where", "wheres", "whats", "what", "find", "look", "looking", "can", "you", "please",
        "help", "get", "show", "locate", "did", "put", "left", "leave", "s", "this", "that"
    ]

    /// Stores a sighting. An older sighting of the same object (same label) is replaced.
    mutating func remember(_ sighting: ObjectSighting) {
        let key = Self.normalizedLabel(sighting.objectLabel)
        sightings.removeAll { existing in
            Self.normalizedLabel(existing.objectLabel) == key
        }
        sightings.append(sighting)

        let overflow = sightings.count - Config.maximumRememberedSightings
        if overflow > 0 {
            sightings.removeFirst(overflow)
        }
    }

    /// The newest sighting whose label (or the request that found it) shares an object
    /// word with `utterance`. "where's my mug" matches "blue mug"; "key" matches "keys".
    func bestMatch(for utterance: String) -> ObjectSighting? {
        let wanted = Self.objectWords(utterance)
        guard !wanted.isEmpty else {
            return nil
        }
        let newestFirst = sightings.sorted { first, second in
            first.seenAt > second.seenAt
        }
        for sighting in newestFirst {
            var known = Self.objectWords(sighting.objectLabel)
            known.formUnion(Self.objectWords(sighting.utterance))
            if !known.isDisjoint(with: wanted) {
                return sighting
            }
        }
        return nil
    }

    mutating func clear() {
        sightings.removeAll()
    }

    // MARK: - Pure helpers (unit tested)

    /// Lowercased words without punctuation, filler words, or a plural "s".
    static func objectWords(_ text: String) -> Set<String> {
        var words = Set<String>()
        for word in splitWords(text) {
            if fillerWords.contains(word) {
                continue
            }
            words.insert(singular(word))
        }
        return words
    }

    static func splitWords(_ text: String) -> [String] {
        // "where's" -> "wheres", so the apostrophe doesn't split off a lone "s".
        var cleaned = text.lowercased()
        cleaned = cleaned.replacingOccurrences(of: "'", with: "")
        cleaned = cleaned.replacingOccurrences(of: "’", with: "")
        let pieces = cleaned.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return pieces.filter { !$0.isEmpty }
    }

    static func singular(_ word: String) -> String {
        guard word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") else {
            return word
        }
        return String(word.dropLast())
    }

    static func normalizedLabel(_ label: String) -> String {
        return splitWords(label).joined(separator: " ")
    }

    /// Whole minutes since `seenAt` (never negative).
    static func minutesAgo(_ seenAt: Date, now: Date = Date()) -> Int {
        let seconds = max(0, now.timeIntervalSince(seenAt))
        return Int(seconds / 60)
    }

    static func target(from sighting: ObjectSighting) -> AnchoredTarget {
        return AnchoredTarget(
            id: UUID(),
            label: sighting.objectLabel,
            worldPosition: SIMD3<Float>(sighting.x, sighting.y, sighting.z),
            placement: sighting.placement,
            createdAt: Date()
        )
    }
}

/// The open "want to navigate?" question.
struct MemoryOffer: Equatable {
    let objectLabel: String
    let minutesAgo: Int
    let expiresAt: Date
}

/// How a reply to the memory offer was understood.
enum MemoryAnswer: Equatable {
    case yes
    case no
    /// Not a yes/no: treat it as a new request.
    case other

    static let yesWords: Set<String> = [
        "yes", "yeah", "yep", "yup", "yea", "sure", "okay", "ok", "go", "navigate", "please"
    ]
    static let noWords: Set<String> = ["no", "nope", "nah", "cancel", "dont", "stop"]
    /// Longer replies are requests ("where did I leave my phone"), not answers.
    static let maximumAnswerWords = 4

    static func parse(_ transcript: String) -> MemoryAnswer {
        let words = ObjectMemory.splitWords(transcript)
        guard !words.isEmpty, words.count <= maximumAnswerWords else {
            return .other
        }
        for word in words {
            if noWords.contains(word) {
                return .no
            }
        }
        for word in words {
            if yesWords.contains(word) {
                return .yes
            }
        }
        return .other
    }
}
