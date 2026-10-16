import Foundation

/// Records sentences instead of speaking them.
@MainActor
final class MockSentenceSpeaker: SentenceSpeaking {
    private(set) var spoken: [String] = []

    nonisolated init() {}

    func speak(_ text: String) async {
        spoken.append(text)
    }
}

/// Object memory backend that is never reachable unless a test scripts it.
@MainActor
final class MockObjectMemoryBackend: ObjectMemoryBackend {
    var scanned: [ScannedObject] = []
    var remote: [SeenObject] = []
    private(set) var scans = 0
    private(set) var saved: [SeenObject] = []
    private(set) var forgets = 0

    nonisolated init() {}

    func scan(jpeg: Data) async throws -> [ScannedObject] {
        scans += 1
        return scanned
    }

    func save(_ objects: [SeenObject]) async throws {
        saved.append(contentsOf: objects)
    }

    func recall(name: String) async throws -> [SeenObject] {
        let memory = remote.reduce(into: SeenObjectMemory()) { $0.remember($1) }
        return memory.bestMatch(for: name).map { [$0] } ?? []
    }

    func forget() async throws {
        forgets += 1
        remote = []
    }
}
