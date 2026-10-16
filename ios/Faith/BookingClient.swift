import Foundation
import Combine
import Security

enum FaithAPIError: LocalizedError {
    case invalidURL
    case server(String)
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Configure the Faith backend URL in Local.xcconfig."
        case .server(let message): return message
        }
    }
}

@MainActor
final class BookingClient {
    private let baseURL: URL
    private var token: String?
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private let transport = URLSession(configuration: .ephemeral)

    init() {
        let value = Bundle.main.object(forInfoDictionaryKey: "FAITH_API_URL") as? String ?? "http://127.0.0.1:8000"
        baseURL = URL(string: value) ?? URL(fileURLWithPath: "/invalid-faith-server")
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        token = Self.savedToken()
    }

    func start() async throws {
        guard token == nil else { return }
        struct Session: Decodable { let sessionToken: String }
        let session: Session = try await request("session", method: "POST", body: Optional<String>.none)
        token = session.sessionToken
        Self.saveToken(session.sessionToken)
    }

    func request<T: Decodable, B: Encodable>(_ path: String, method: String = "GET", body: B?, timeout: TimeInterval = 30,
                                             query: [URLQueryItem] = []) async throws -> T {
        guard baseURL.scheme == "http" || baseURL.scheme == "https" else { throw FaithAPIError.invalidURL }
        var url = baseURL.appendingPathComponent("api/" + path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try encoder.encode(body) }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FaithAPIError.server("No response from Faith.") }
        guard (200..<300).contains(http.statusCode) else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw FaithAPIError.server(object?["detail"] as? String ?? "Check your fields and try again.")
        }
        return try decoder.decode(T.self, from: data)
    }

    private static let service = "app.faith.booking.session"
    /// Also asks for Local Network access at launch rather than in the middle of a booking.
    func ping() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 8
        guard let (_, response) = try? await transport.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
    func locateObject(query: String, jpeg: Data) async throws -> ObjectLocationAnswer {
        try await start()
        struct FrameRequest: Encodable { let objectQuery: String; let jpegBase64: String; let consent: Bool }
        return try await request("objects/locate", method: "POST", body: FrameRequest(objectQuery: query, jpegBase64: jpeg.base64EncodedString(), consent: true))
    }
    struct ScanReply: Decodable {
        struct Item: Decodable { let label: String; let place: String?; let box: ObjectLocationAnswer.Box; let confidence: Double }
        let objects: [Item]
    }
    func scanObjects(jpeg: Data) async throws -> ScanReply {
        try await start()
        struct Scan: Encodable { let jpegBase64: String }
        return try await request("objects/scan", method: "POST", body: Scan(jpegBase64: jpeg.base64EncodedString()), timeout: 25)
    }
    struct MemoryItem: Codable { let label: String; let place: String; let seenAt: String; let position: [Float]?; let arSession: String? }
    func saveObjectMemory(_ entries: [MemoryItem]) async throws {
        try await start()
        struct Update: Encodable { let entries: [MemoryItem] }
        struct Stored: Decodable { let stored: Int }
        let _: Stored = try await request("objects/memory", method: "POST", body: Update(entries: entries), timeout: 10)
    }
    func objectMemory(name: String) async throws -> [MemoryItem] {
        try await start()
        struct Recalled: Decodable { let objects: [MemoryItem] }
        let reply: Recalled = try await request("objects/memory", body: Optional<String>.none, timeout: 4,
                                                query: [URLQueryItem(name: "name", value: String(name.prefix(120)))])
        return reply.objects
    }
    func forgetObjectMemory() async throws {
        try await start()
        struct Forgotten: Decodable { let forgotten: Bool }
        let _: Forgotten = try await request("objects/memory", method: "DELETE", body: Optional<String>.none, timeout: 10)
    }
    struct AgentSession: Decodable { let conversationToken: String; let today: String; let savedPreferences: String? }
    func agentSession() async throws -> AgentSession {
        try await start()
        return try await request("agent/session", method: "POST", body: Optional<String>.none)
    }
    func accessInfo(category: TicketCategory, preferences: AccessPreferences) async throws -> AccessInfo {
        try await start()
        struct Lookup: Encodable { let category: TicketCategory; let preferences: AccessPreferences }
        return try await request("access-info", method: "POST", body: Lookup(category: category, preferences: preferences), timeout: 100)
    }
    func realTimes(category: String, origin: String, destination: String, date: String) async throws -> RealTimes {
        try await start()
        struct Lookup: Encodable { let category: String; let origin: String; let destination: String; let date: String }
        return try await request("real-search", method: "POST",
                                 body: Lookup(category: category, origin: origin, destination: destination, date: date), timeout: 115)
    }
    func preferences() async throws -> SavedPreferencesReply {
        try await start()
        return try await request("preferences", body: Optional<String>.none)
    }
    func savePreferences(_ preferences: SavedPreferences) async throws -> SavedPreferencesReply {
        try await start()
        return try await request("preferences", method: "PUT", body: preferences)
    }
    func forgetPreferences() async throws {
        try await start()
        struct Forgotten: Decodable { let forgotten: Bool }
        let _: Forgotten = try await request("preferences", method: "DELETE", body: Optional<String>.none)
    }
    private static func savedToken() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func saveToken(_ token: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
        var values = query
        values[kSecValueData as String] = Data(token.utf8)
        values[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(values as CFDictionary, nil)
    }
}
