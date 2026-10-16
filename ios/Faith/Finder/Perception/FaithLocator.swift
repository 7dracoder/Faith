import Foundation

/// Real `ObjectLocator`: one approved frame goes to Faith's backend, which asks the
/// configured vision model (Baseten or Bedrock). No provider keys live in the app.
final class FaithLocator: ObjectLocator {
    private let client: BookingClient

    init(client: BookingClient) {
        self.client = client
    }

    func locate(utterance: String, in snapshot: Snapshot) async throws -> Detection {
        let answer: ObjectLocationAnswer
        do {
            answer = try await client.locateObject(query: String(utterance.prefix(120)), jpeg: snapshot.uprightJPEG)
        } catch let error as URLError where error.code == .timedOut {
            throw FinderError.locatorTimeout
        } catch {
            throw FinderError.locatorFailed(error.localizedDescription)
        }
        return try Self.detection(from: answer, utterance: utterance)
    }

    nonisolated static func detection(from answer: ObjectLocationAnswer, utterance: String) throws -> Detection {
        guard answer.found, let box = answer.box else {
            throw FinderError.objectNotFound(utterance)
        }
        return Detection(
            label: answer.label,
            box: NormalizedRect(minX: box.minX, minY: box.minY, maxX: box.maxX, maxY: box.maxY),
            confidence: answer.confidence
        )
    }
}

struct ObjectLocationAnswer: Decodable, Equatable {
    struct Box: Decodable, Equatable { let minX, minY, maxX, maxY: Double }
    let found: Bool
    let label: String
    let box: Box?
    let confidence: Double
    let reason: String
}
