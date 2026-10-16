import Foundation

/// Real `ObjectMemoryBackend`, through the Faith backend (Baseten for scans, SurrealDB for memory).
@MainActor
final class FaithMemoryBackend: ObjectMemoryBackend {
    private let client: BookingClient

    init(client: BookingClient) {
        self.client = client
    }

    func scan(jpeg: Data) async throws -> [ScannedObject] {
        try await client.scanObjects(jpeg: jpeg).objects.map { item in
            ScannedObject(
                label: item.label,
                place: item.place ?? "",
                box: NormalizedRect(minX: item.box.minX, minY: item.box.minY, maxX: item.box.maxX, maxY: item.box.maxY),
                confidence: item.confidence
            )
        }
    }

    func save(_ objects: [SeenObject]) async throws {
        try await client.saveObjectMemory(objects.map { seen in
            BookingClient.MemoryItem(label: seen.label, place: seen.place, seenAt: Self.iso.string(from: seen.seenAt),
                                     position: seen.position, arSession: seen.arSession?.uuidString)
        })
    }

    func recall(name: String) async throws -> [SeenObject] {
        try await client.objectMemory(name: name).compactMap { item in
            guard let seenAt = Self.iso.date(from: item.seenAt) ?? Self.isoFractional.date(from: item.seenAt) else {
                return nil
            }
            return SeenObject(label: item.label, place: item.place, seenAt: seenAt, position: item.position,
                              arSession: item.arSession.flatMap(UUID.init(uuidString:)))
        }
    }

    func forget() async throws {
        try await client.forgetObjectMemory()
    }

    private static let iso = ISO8601DateFormatter()
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
