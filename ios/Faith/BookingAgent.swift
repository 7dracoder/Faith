import Combine
import ElevenLabs
import Foundation
import UIKit

/// The ElevenLabs voice agent. It reads live options from provider sites, and falls back to
/// practice (demo) tickets only when that fails. Faith can't pay: choosing a live option saves
/// the trip and its provider link. Its tools run here, against the Faith backend; the agent
/// never sees session tokens. Choosing or booking needs a hold, or the user's own spoken yes.
@MainActor
final class BookingAgent: ObservableObject {
    enum Phase: Equatable { case idle, connecting, active }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var speaking = false
    @Published private(set) var lastLine = ""
    @Published private(set) var quote: TicketQuote?
    /// A live option waiting for hold to choose.
    @Published private(set) var liveChoice: LiveOption?
    @Published private(set) var savedTrip: SavedTrip?
    /// Which results the conversation is on: live from a provider, or practice tickets.
    @Published private(set) var source: Source = .none
    @Published private(set) var busy = false

    enum Source: Equatable { case none, live(provider: String), practice }

    /// The agent asked to find an object: the app switches to the finder.
    var onFindObject: ((String) -> Void)?
    /// The conversation ended (by the user, the agent, or an error).
    var onFinished: (() -> Void)?

    private let client: BookingClient
    private var conversation: Conversation?
    private var subscriptions = Set<AnyCancellable>()
    private var startTask: Task<Void, Never>?
    private var handledCalls = Set<String>()
    private var offers: [TicketOffer] = []
    private var liveOptions: [LiveOption] = []
    private var search = TicketSearch()
    private var confirmationKey = UUID().uuidString
    /// Messages that existed when the quote was proposed; a spoken yes must come after them.
    private var quoteMessageCount = 0

    init(client: BookingClient) {
        self.client = client
    }

    var isOn: Bool { phase != .idle }
    var hasChoice: Bool { quote != nil || liveChoice != nil }

    /// `intro` plays before connecting (the "Booking assistant" announcement).
    func start(with request: String, intro: (() async -> Void)? = nil) {
        guard phase == .idle else { return }
        phase = .connecting
        lastLine = "Booking assistant. Connecting you to Faith…"
        startTask = Task {
            do {
                await intro?()
                try Task.checkCancellation()
                let session = try await client.agentSession()
                let conversation = try await ElevenLabs.startConversation(
                    conversationToken: session.conversationToken,
                    config: ConversationConfig(dynamicVariables: ["today": session.today,
                                                                   "saved_preferences": session.savedPreferences ?? "none"])
                )
                try Task.checkCancellation()
                self.conversation = conversation
                observe(conversation)
                phase = .active
                try await conversation.sendMessage(request)
            } catch is CancellationError {
                finish()
            } catch {
                announce("The booking assistant isn’t available right now. Please try again later.")
                finish()
            }
        }
    }

    func end() {
        startTask?.cancel()
        let conversation = conversation
        Task { await conversation?.endConversation() }
        finish()
    }

    /// Hold for 1.5 seconds: save the live option, or book the practice quote.
    func acceptQuote() {
        guard hasChoice, !busy else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if liveChoice != nil {
            Task {
                let context: String
                do {
                    let reply = try await saveChosenTrip()
                    context = "The user held the screen to choose. Faith saved the trip but can't pay for it. Say exactly: \(reply.say)"
                } catch {
                    context = "Saving failed: \(error.localizedDescription) Nothing was saved or bought. Offer to try again."
                }
                try? await conversation?.updateContext(context)
                try? await conversation?.sendMessage("I held the screen to choose it.")
            }
            return
        }
        Task {
            let context: String
            do {
                let ticket = try await confirm()
                context = "The user held the screen to confirm. Faith booked demo ticket \(ticket.id). Tell them it is booked, say the reference slowly, and remind them it is a demo ticket, not valid for travel or entry."
            } catch {
                context = "Booking failed: \(error.localizedDescription) Nothing was booked. Offer to prepare it again."
            }
            try? await conversation?.updateContext(context)
            try? await conversation?.sendMessage("I held the screen to book it.")
        }
    }

    /// Double tap: reject this option and hear the next one.
    func rejectQuote() {
        guard hasChoice else { return }
        quote = nil
        liveChoice = nil
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        Task { try? await conversation?.sendMessage("No, not that one. Please tell me the next available option.") }
    }

    // MARK: - Conversation

    private func observe(_ conversation: Conversation) {
        conversation.$pendingToolCalls.receive(on: RunLoop.main).sink { [weak self] calls in
            guard let self else { return }
            for call in calls where handledCalls.insert(call.toolCallId).inserted {
                Task { await self.handle(call) }
            }
        }.store(in: &subscriptions)
        conversation.$agentState.receive(on: RunLoop.main).sink { [weak self] state in
            self?.speaking = state == .speaking
        }.store(in: &subscriptions)
        conversation.$messages.receive(on: RunLoop.main).sink { [weak self] messages in
            guard let self else { return }
            if let line = messages.last(where: { $0.role == .agent })?.content, !line.isEmpty { lastLine = line }
        }.store(in: &subscriptions)
        conversation.$state.receive(on: RunLoop.main).sink { [weak self] state in
            switch state {
            case .ended, .error: self?.finish()
            default: break
            }
        }.store(in: &subscriptions)
    }

    private func finish() {
        guard phase != .idle else { return }
        subscriptions.removeAll()
        conversation = nil
        quote = nil
        liveChoice = nil
        savedTrip = nil
        source = .none
        offers = []
        liveOptions = []
        handledCalls = []
        speaking = false
        phase = .idle
        onFinished?()
    }

    private func announce(_ text: String) {
        lastLine = text
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    // MARK: - Client tools

    private func handle(_ call: ClientToolCallEvent) async {
        let parameters = (try? call.getParameters()) ?? [:]
        var isError = false
        let result: [String: Any]
        do {
            switch call.toolName {
            case "search_tickets": result = try await searchTickets(parameters)
            case "propose_booking": result = try await proposeBooking(parameters)
            case "confirm_booking": result = try await confirmBySpeech()
            case "check_venue_accessibility": result = try await checkAccessibility()
            case "search_live_tickets": result = try await searchLiveTickets(parameters)
            case "choose_live_option": result = try chooseLiveOption(parameters)
            case "save_trip": result = try await saveTripBySpeech()
            case "remember_preferences": result = try await rememberPreferences(parameters)
            case "get_preferences": result = ["remembered": try await client.preferences().summary]
            case "forget_preferences":
                try await client.forgetPreferences()
                result = ["forgotten": true, "say": "Everything Faith remembered about your preferences is forgotten."]
            case "find_object": result = findObject(parameters)
            default: throw FaithAPIError.server("Unknown tool.")
            }
        } catch {
            isError = true
            result = ["error": error.localizedDescription]
        }
        let data = (try? JSONSerialization.data(withJSONObject: result)) ?? Data("{}".utf8)
        try? await conversation?.sendToolResult(for: call.toolCallId, result: String(decoding: data, as: UTF8.self), isError: isError)
    }

    private func searchTickets(_ parameters: [String: Any]) async throws -> [String: Any] {
        var next = TicketSearch()
        next.category = TicketCategory(rawValue: parameters["category"] as? String ?? "") ?? .all
        if let origin = parameters["origin"] as? String, !origin.isEmpty { next.origin = String(origin.prefix(80)) }
        next.destination = String((parameters["destination"] as? String ?? "").prefix(80))
        if let date = parameters["date"] as? String, DateFormatter.faithDate.date(from: date) != nil { next.date = date }
        next.passengers = min(max(parameters["passengers"] as? Int ?? 1, 1), 6)
        if let perPerson = parameters["max_price_usd"] as? Int, perPerson > 0 { next.maxPrice = perPerson * 100 * next.passengers }
        next.preferences.stepFree = parameters["step_free"] as? Bool ?? false
        next.preferences.audioDescription = parameters["audio_description"] as? Bool ?? false
        next.preferences.companion = parameters["companion"] as? Bool ?? false

        struct Results: Decodable { let offers: [TicketOffer]; let notice: String }
        try await client.start()
        let response: Results = try await client.request("search", method: "POST", body: next)
        search = next
        offers = response.offers
        quote = nil
        liveChoice = nil
        source = .practice
        return ["notice": response.notice, "options": offers.prefix(5).map { offer in
            ["offer_id": offer.id, "what": offer.title, "operator": offer.operator, "from": offer.origin,
             "to": offer.destination, "date": offer.date, "departs": offer.departure, "arrives": offer.arrival,
             "duration": offer.duration, "total_for_everyone": ticketMoney(offer.total(for: next.passengers)),
             "access": offer.accessNote, "features": offer.features] as [String: Any]
        }]
    }

    private func proposeBooking(_ parameters: [String: Any]) async throws -> [String: Any] {
        guard let id = parameters["offer_id"] as? String, let offer = offers.first(where: { $0.id == id }) else {
            throw FaithAPIError.server("Use an offer_id from the latest search_tickets result.")
        }
        struct Review: Encodable { let offerId: String; let passengers: Int; let preferences: AccessPreferences }
        let next: TicketQuote = try await client.request("quotes", method: "POST",
                                                         body: Review(offerId: offer.id, passengers: search.passengers, preferences: search.preferences))
        quote = next
        liveChoice = nil
        confirmationKey = UUID().uuidString
        quoteMessageCount = conversation?.messages.count ?? 0
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        return ["quote_ready": true, "what": offer.title, "departs": "\(offer.date) \(offer.departure)",
                "people": next.passengers, "total_including_fees": ticketMoney(next.totalMinor), "notice": next.notice,
                "next_step": "Say the total, then: hold the screen for a moment to book it, or double tap to hear another option. They can also say yes or no."]
    }

    private func confirmBySpeech() async throws -> [String: Any] {
        guard quote != nil else { throw FaithAPIError.server("Nothing is waiting to be booked. Call propose_booking first.") }
        let reply = conversation?.messages.dropFirst(quoteMessageCount).last(where: { $0.role == .user })?.content ?? ""
        guard Self.saidYes(reply) else {
            throw FaithAPIError.server("The user has not clearly said yes. Ask them to say yes, or hold the screen to book.")
        }
        let ticket = try await confirm()
        return ["booked": true, "reference": ticket.id,
                "notice": "Demo ticket only. Not valid for travel or entry. No payment was taken."]
    }

    private func confirm() async throws -> DemoTicket {
        guard let quote else { throw FaithAPIError.server("Nothing is waiting to be booked.") }
        busy = true
        defer { busy = false }
        struct Confirm: Encodable { let quoteId: String; let acceptedDemo: Bool; let idempotencyKey: String }
        let ticket: DemoTicket = try await client.request("bookings", method: "POST",
                                                          body: Confirm(quoteId: quote.id, acceptedDemo: true, idempotencyKey: confirmationKey))
        self.quote = nil
        return ticket
    }

    private func checkAccessibility() async throws -> [String: Any] {
        let category = quote?.offer.category ?? (search.category == .all ? offers.first?.category : search.category)
        guard let category, category != .all else { throw FaithAPIError.server("Search for a kind of ticket first.") }
        let info = try await client.accessInfo(category: category, preferences: search.preferences)
        return ["provider": info.provider, "summary": String(info.summary.prefix(1500)), "notice": info.notice]
    }

    private func searchLiveTickets(_ parameters: [String: Any]) async throws -> [String: Any] {
        let category = parameters["category"] as? String ?? ""
        let origin = String((parameters["origin"] as? String ?? "").prefix(60))
        let destination = String((parameters["destination"] as? String ?? "").prefix(80))
        let date = parameters["date"] as? String ?? ""
        guard ["flight", "train", "bus", "cinema", "event"].contains(category), DateFormatter.faithDate.date(from: date) != nil else {
            throw FaithAPIError.server("Use a kind of ticket (flight, train, bus, cinema, or event) and a YYYY-MM-DD date.")
        }
        let results = try await client.liveSearch(category: category, origin: origin, destination: destination, date: date)
        liveOptions = results.options
        liveChoice = nil
        quote = nil
        source = .live(provider: results.provider)
        return ["provider": results.provider, "notice": results.notice, "options": results.options.map { option in
            ["option_id": option.optionId, "provider": option.provider, "what": option.what, "departs": option.departs,
             "arrives": option.arrives ?? "", "duration": option.duration ?? "", "price": option.price ?? "price not shown"]
        }]
    }

    private func chooseLiveOption(_ parameters: [String: Any]) throws -> [String: Any] {
        guard let id = parameters["option_id"] as? String, let option = liveOptions.first(where: { $0.optionId == id }) else {
            throw FaithAPIError.server("Use an option_id from the latest search_live_tickets result.")
        }
        liveChoice = option
        quote = nil
        quoteMessageCount = conversation?.messages.count ?? 0
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        return ["ready_to_choose": true, "option": option.spoken,
                "next_step": "Say the option once more, then: hold the screen for a moment to choose it, or double tap to hear another option. They can also say yes or no."]
    }

    private func saveTripBySpeech() async throws -> [String: Any] {
        guard liveChoice != nil else { throw FaithAPIError.server("Nothing is waiting to be chosen. Call choose_live_option first.") }
        let reply = conversation?.messages.dropFirst(quoteMessageCount).last(where: { $0.role == .user })?.content ?? ""
        guard Self.saidYes(reply) else {
            throw FaithAPIError.server("The user has not clearly said yes. Ask them to say yes, or hold the screen to choose.")
        }
        let saved = try await saveChosenTrip()
        return ["saved": true, "paid": false, "say": saved.say]
    }

    private func saveChosenTrip() async throws -> TripReply {
        guard let liveChoice else { throw FaithAPIError.server("Nothing is waiting to be chosen.") }
        busy = true
        defer { busy = false }
        let reply = try await client.saveTrip(optionId: liveChoice.optionId)
        self.liveChoice = nil
        savedTrip = reply.trip
        return reply
    }

    private func rememberPreferences(_ parameters: [String: Any]) async throws -> [String: Any] {
        let reply = conversation?.messages.last(where: { $0.role == .user })?.content ?? ""
        guard Self.agreedToSave(reply) else {
            throw FaithAPIError.server("The user has not asked to save. Ask: would you like me to remember that for next time?")
        }
        let city = (parameters["home_city"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let preferences = SavedPreferences(homeCity: city.count >= 2 ? String(city.prefix(60)) : nil,
                                           stepFree: parameters["step_free"] as? Bool ?? false,
                                           audioDescription: parameters["audio_description"] as? Bool ?? false,
                                           companion: parameters["companion"] as? Bool ?? false,
                                           passengers: (parameters["passengers"] as? Int).map { min(max($0, 1), 6) })
        return ["saved": true, "remembered": try await client.savePreferences(preferences).summary]
    }

    private func findObject(_ parameters: [String: Any]) -> [String: Any] {
        let object = String((parameters["object"] as? String ?? "").prefix(120))
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            end()
            if !object.isEmpty { onFindObject?(object) }
        }
        return ["ok": true, "say": "Switching to the object finder now."]
    }

    /// The user's own latest words, not the agent's reading of them.
    nonisolated static func saidYes(_ text: String) -> Bool {
        let words = ObjectMemory.splitWords(text)
        guard !words.isEmpty, words.count <= 12 else { return false }
        let no: Set<String> = ["no", "not", "dont", "nope", "nah", "cancel", "stop", "wait", "never", "another", "next", "else"]
        let yes: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "confirm", "book", "absolutely", "definitely", "correct"]
        return no.isDisjoint(with: words) && !yes.isDisjoint(with: words)
    }

    /// Saving needs the user's own request or yes, like "remember that" or "yes please".
    nonisolated static func agreedToSave(_ text: String) -> Bool {
        let words = ObjectMemory.splitWords(text)
        guard !words.isEmpty, words.count <= 25 else { return false }
        let no: Set<String> = ["no", "not", "dont", "nope", "nah", "never", "forget", "stop"]
        let yes: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "please", "remember", "save", "keep"]
        return no.isDisjoint(with: words) && !yes.isDisjoint(with: words)
    }
}
