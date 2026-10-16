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

    func request<T: Decodable, B: Encodable>(_ path: String, method: String = "GET", body: B?) async throws -> T {
        guard baseURL.scheme == "http" || baseURL.scheme == "https" else { throw FaithAPIError.invalidURL }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/" + path))
        request.httpMethod = method
        request.timeoutInterval = 30
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
    func speech(_ text: String) async throws -> Data {
        try await start()
        var request = URLRequest(url: baseURL.appendingPathComponent("api/speech"))
        request.httpMethod = "POST"
        request.timeoutInterval = 40
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        struct Speech: Encodable { let text: String; let consent: Bool }
        request.httpBody = try encoder.encode(Speech(text: text, consent: true))
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FaithAPIError.server("No speech response.") }
        guard http.statusCode == 200, http.mimeType == "audio/mpeg", data.count <= 2_000_000 else {
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw FaithAPIError.server(object?["detail"] as? String ?? "Speech unavailable. Use device read-aloud or show your text.")
        }
        return data
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

@MainActor
final class BookingModel: ObservableObject {
    @Published var search = TicketSearch()
    @Published var offers: [TicketOffer] = []
    @Published var tickets: [DemoTicket] = []
    @Published var quote: TicketQuote?
    @Published var message = ""
    @Published var status = ""
    @Published var busy = false
    @Published var error: String?
    private let client = BookingClient()
    private var resultSearch = TicketSearch()
    private var confirmationKey = UUID().uuidString

    var resultPassengers: Int { resultSearch.passengers }
    func createSpeech(_ text: String) async throws -> Data { try await client.speech(text) }

    func find() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.start()
            struct Results: Decodable { let offers: [TicketOffer] }
            let submitted = search
            let response: Results = try await client.request("search", method: "POST", body: submitted)
            offers = response.offers
            resultSearch = submitted
            status = "\(offers.count) demo options found. All totals include fees."
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func interpret() async {
        guard !busy, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            try await client.start()
            struct Intent: Encodable { let message: String; let current: TicketSearch }
            struct Result: Decodable { let search: TicketSearch; let message: String }
            let result: Result = try await client.request("assistant", method: "POST", body: Intent(message: message, current: search))
            search = result.search
            status = result.message
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func review(_ offer: TicketOffer) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            struct Review: Encodable { let offerId: String; let passengers: Int; let preferences: AccessPreferences }
            quote = try await client.request("quotes", method: "POST", body: Review(offerId: offer.id, passengers: resultSearch.passengers, preferences: resultSearch.preferences))
            confirmationKey = UUID().uuidString
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func confirm() async -> Bool {
        guard !busy, let quote else { return false }
        busy = true
        defer { busy = false }
        do {
            struct Confirm: Encodable { let quoteId: String; let acceptedDemo: Bool; let idempotencyKey: String }
            let ticket: DemoTicket = try await client.request("bookings", method: "POST", body: Confirm(quoteId: quote.id, acceptedDemo: true, idempotencyKey: confirmationKey))
            self.quote = nil
            if !tickets.contains(where: { $0.id == ticket.id }) { tickets.insert(ticket, at: 0) }
            status = "Demo ticket saved. No payment or real reservation was made."
            error = nil
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func loadTickets() async {
        do {
            try await client.start()
            struct Tickets: Decodable { let bookings: [DemoTicket] }
            let response: Tickets = try await client.request("bookings", body: Optional<String>.none)
            tickets = response.bookings
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func cancel(_ ticket: DemoTicket) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let updated: DemoTicket = try await client.request("bookings/\(ticket.id)/cancel", method: "POST", body: Optional<String>.none)
            if let index = tickets.firstIndex(where: { $0.id == ticket.id }) { tickets[index] = updated }
            status = "Demo ticket cancelled."
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}
