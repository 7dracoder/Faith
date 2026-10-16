import Foundation

/// Word helpers for matching spoken requests to remembered object labels (SeenObjects.swift).
enum ObjectMemory {
    /// Words that say nothing about which object is meant.
    static let fillerWords: Set<String> = [
        "a", "an", "the", "my", "me", "i", "is", "are", "was", "it", "its", "of", "to", "for",
        "where", "wheres", "whats", "what", "find", "look", "looking", "can", "you", "please",
        "help", "get", "show", "locate", "did", "put", "left", "leave", "s", "this", "that"
    ]

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

    /// Whole minutes since `seenAt` (never negative).
    static func minutesAgo(_ seenAt: Date, now: Date = Date()) -> Int {
        let seconds = max(0, now.timeIntervalSince(seenAt))
        return Int(seconds / 60)
    }
}
