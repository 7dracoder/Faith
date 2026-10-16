import Foundation
import os

final class MockObjectLocator: ObjectLocator {
    private let logger = Logger(subsystem: "app.faith.finder", category: "MockLocator")

    func locate(utterance: String, in snapshot: Snapshot) async throws -> Detection {
        logger.info("locate \"\(utterance, privacy: .public)\"")
        try await Task.sleep(nanoseconds: 1_200_000_000)

        let lowered = utterance.lowercased()
        if lowered.contains("unicorn") {
            throw FinderError.objectNotFound(utterance)
        }
        if lowered.contains("slow") {
            throw FinderError.locatorTimeout
        }

        var label = utterance
        for known in Config.knownObjects {
            if lowered.contains(known) {
                label = known
                break
            }
        }

        let box = NormalizedRect(minX: 0.4, minY: 0.4, maxX: 0.6, maxY: 0.6)
        return Detection(label: label, box: box, confidence: 0.9)
    }
}
