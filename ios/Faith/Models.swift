import Foundation

enum TicketCategory: String, CaseIterable, Codable, Identifiable {
    case all, flight, train, bus, cinema, event
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Everything"
        case .flight: return "Flights"
        case .train: return "Trains"
        case .bus: return "Buses"
        case .cinema: return "Cinema"
        case .event: return "Events"
        }
    }
    var symbol: String {
        switch self {
        case .all: return "sparkles"
        case .flight: return "airplane"
        case .train: return "tram.fill"
        case .bus: return "bus.fill"
        case .cinema: return "film"
        case .event: return "music.note"
        }
    }
}

struct AccessPreferences: Codable, Equatable {
    var stepFree = false
    var captions = false
    var audioDescription = false
    var textUpdates = true
    var companion = false

    var summary: String {
        [stepFree ? "Step-free" : nil, captions ? "Captions" : nil,
         audioDescription ? "Audio description" : nil, companion ? "Companion place" : nil,
         textUpdates ? "Text updates" : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

struct TicketSearch: Codable {
    var category: TicketCategory = .all
    var origin = "New York"
    var destination = "Boston"
    var date: String = DateFormatter.faithDate.string(from: Date().addingTimeInterval(86400))
    var passengers = 1
    var maxPrice: Int?
    var preferences = AccessPreferences()
}

struct TicketOffer: Codable, Identifiable {
    let id: String
    let category: TicketCategory
    let title: String
    let `operator`: String
    let origin: String
    let destination: String
    let date: String
    let departure: String
    let arrival: String
    let duration: String
    let priceMinor: Int
    let feeMinor: Int
    let currency: String
    let features: [String]
    let accessNote: String
    let description: String
    let illustration: String
    let demo: Bool

    func total(for people: Int) -> Int { (priceMinor + feeMinor) * people }
}

struct TicketQuote: Codable, Identifiable {
    let id: String
    let offer: TicketOffer
    let passengers: Int
    let preferences: AccessPreferences
    let subtotalMinor: Int
    let feesMinor: Int
    let totalMinor: Int
    let currency: String
    let expiresAt: String
    let demo: Bool
    let notice: String
}

struct DemoTicket: Codable, Identifiable {
    let id: String
    let quote: TicketQuote
    let createdAt: String
    let status: String
    let demo: Bool
    let admissionValid: Bool
    var cancelled: Bool { status == "demo_cancelled" }
    var shareText: String {
        "Faith — DEMO TICKET. NOT VALID FOR ENTRY OR TRAVEL.\n\(quote.offer.title)\n\(quote.offer.origin) to \(quote.offer.destination)\n\(quote.offer.date), \(quote.offer.departure)\n\(quote.passengers) people\n\(id)\n\(cancelled ? "Cancelled" : "Demo confirmed")\n\(quote.notice)"
    }
}

extension DateFormatter {
    static var faithDate: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

func ticketMoney(_ minor: Int) -> String {
    (Double(minor) / 100).formatted(.currency(code: "USD"))
}
