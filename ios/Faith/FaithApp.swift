import SwiftUI

@main
struct FaithApp: App {
    var body: some Scene {
        WindowGroup { FaithView() }
    }
}

private let forest = Color(red: 0.09, green: 0.24, blue: 0.20)
private let paper = Color(red: 0.98, green: 0.98, blue: 0.96)

@MainActor
struct FaithView: View {
    @StateObject private var model = BookingModel()
    @StateObject private var access = AccessServices()
    @State private var tab = 0
    @State private var showAccess = false
    @State private var accepted = false
    @State private var cancellation: DemoTicket?
    @Environment(\.scenePhase) private var scenePhase
    @AccessibilityFocusState private var focusedOffer: String?
    @AppStorage("faith.haptics") private var haptics = false
    @AppStorage("faith.spoken") private var spoken = false
    @AppStorage("faith.contrast") private var contrast = false
    @AppStorage("faith.large") private var large = false
    @AppStorage("faith.reduceMotion") private var reduceMotion = false

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 25) {
                            Text("MORE WORLD. FEWER BARRIERS.").font(.caption).tracking(2)
                            Text("Your next chapter.\nYour way there.").font(.system(size: 43, weight: .regular, design: .serif))
                            Text("Journeys, cinema, and live experiences. Book it your way, with Faith.")
                            demoNotice
                            searchForm
                            if let error = model.error { errorView(error) }
                            Text(model.status).font(.subheadline).accessibilityAddTraits(.updatesFrequently)
                            if model.busy { ProgressView("Finding possibilities…") }
                            ForEach(model.offers) { offer in
                                offerCard(offer)
                                    .id(offer.id)
                            }
                            if !model.busy && model.offers.isEmpty {
                                Text("No options yet. Find tickets or adjust your preferences.").padding()
                            }
                        }
                        .padding(24)
                    }
                    .onChange(of: access.focusedIndex) { _, index in
                        guard model.offers.indices.contains(index) else { return }
                        let id = model.offers[index].id
                        focusedOffer = id
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .background(paper)
                .navigationTitle("faith.")
                .toolbar { accessToolbar }
            }
            .tabItem { Label("Explore", systemImage: "sparkles") }.tag(0)

            NavigationStack {
                List {
                    Section { demoNotice }
                    if let error = model.error { errorView(error) }
                    if model.tickets.isEmpty { Text("Your next chapter is waiting. Explore and save a demo ticket.") }
                    ForEach(model.tickets) { ticket in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(ticket.cancelled ? "DEMO CANCELLED" : "DEMO · NOT VALID FOR ENTRY").font(.caption).bold()
                            Text(ticket.quote.offer.title).font(.title2).fontDesign(.serif)
                            Text("\(ticket.quote.offer.origin) → \(ticket.quote.offer.destination)")
                            Text("\(ticket.quote.offer.date) · \(ticket.quote.offer.departure)")
                            Text(ticket.id).font(.system(.body, design: .monospaced))
                            Text("\(ticketMoney(ticket.quote.totalMinor)) demo total. No payment made.").font(.subheadline)
                            ShareLink(item: ticket.shareText) { Label("Save text ticket", systemImage: "square.and.arrow.up") }.buttonStyle(.bordered)
                            if !ticket.cancelled {
                                Button("Cancel demo ticket", role: .destructive) { cancellation = ticket }.buttonStyle(.bordered)
                            }
                        }.padding(.vertical, 12)
                    }
                }
                .navigationTitle("My tickets")
                .toolbar { accessToolbar }
                .task { await model.loadTickets() }
                .refreshable { await model.loadTickets() }
            }
            .tabItem { Label("My tickets", systemImage: "ticket") }.tag(1)
        }
        .tint(forest)
        .preferredColorScheme(.light)
        .contrast(contrast ? 1.3 : 1)
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil; transaction.disablesAnimations = true }
        }
        .dynamicTypeSize(large ? DynamicTypeSize.xxxLarge ... DynamicTypeSize.accessibility5 : DynamicTypeSize.xSmall ... DynamicTypeSize.accessibility5)
        .sheet(item: $model.quote, onDismiss: { accepted = false }) { quote in
            review(quote)
        }
        .sheet(isPresented: $showAccess) { accessStudio }
        .confirmationDialog("Cancel this demo ticket? No payment was made.", isPresented: Binding(get: { cancellation != nil }, set: { if !$0 { cancellation = nil } })) {
            Button("Cancel demo ticket", role: .destructive) {
                if let cancellation { Task { await model.cancel(cancellation) } }
                cancellation = nil
            }
        }
        .task { access.hapticsEnabled = haptics; access.spokenUpdates = spoken; await model.find() }
        .onChange(of: model.offers.count) { _, count in access.optionCount = count; access.focusedIndex = -1 }
        .onChange(of: model.status) { _, message in if !message.isEmpty { access.feedback(message, success: message.contains("saved")) } }
        .onChange(of: access.transcript) { _, text in model.message = text }
        .onChange(of: model.quote?.id) { _, id in access.suspended = id != nil || showAccess || tab != 0; if id != nil && access.listening { access.stopDictation() } }
        .onChange(of: showAccess) { _, value in access.suspended = value || model.quote != nil || tab != 0 }
        .onChange(of: tab) { _, value in access.suspended = value != 0 || model.quote != nil || showAccess; if access.listening { access.stopDictation() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { access.pause() } }
        .onChange(of: haptics) { _, value in access.hapticsEnabled = value }
        .onChange(of: spoken) { _, value in access.spokenUpdates = value }
    }

    @ToolbarContentBuilder private var accessToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showAccess = true } label: { Label("Access studio", systemImage: "accessibility") }
        }
    }

    private var demoNotice: some View {
        Text("Demo experiences only. No payment, real seat reservation, or admission. Access details are illustrative and unverified.")
            .font(.footnote).padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.94, green: 0.91, blue: 0.83), in: RoundedRectangle(cornerRadius: 12))
    }

    private var searchForm: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Where will life take you?").font(.title2).fontDesign(.serif)
            Picker("Ticket category", selection: $model.search.category) {
                ForEach(TicketCategory.allCases) { category in Label(category.title, systemImage: category.symbol).tag(category) }
            }.pickerStyle(.menu)
            TextField("From / home city", text: $model.search.origin).textFieldStyle(.roundedBorder).accessibilityLabel("From or home city")
            if ![TicketCategory.cinema, .event].contains(model.search.category) {
                TextField("Destination", text: $model.search.destination).textFieldStyle(.roundedBorder).accessibilityLabel("Destination city")
            }
            DatePicker("When", selection: Binding(get: { DateFormatter.faithDate.date(from: model.search.date) ?? Date() }, set: { model.search.date = DateFormatter.faithDate.string(from: $0) }), in: Date()..., displayedComponents: .date)
            Stepper("\(model.search.passengers) people", value: $model.search.passengers, in: 1...6)
            DisclosureGroup("Make it work for you") {
                VStack {
                    Toggle("Step-free", isOn: $model.search.preferences.stepFree)
                    Toggle("Captions", isOn: $model.search.preferences.captions)
                    Toggle("Audio description", isOn: $model.search.preferences.audioDescription)
                    Toggle("Companion place", isOn: $model.search.preferences.companion)
                    TextField("Total budget in USD, optional", text: Binding(get: { model.search.maxPrice.map { String(Double($0) / 100) } ?? "" }, set: { value in
                        if let dollars = Double(value), dollars.isFinite, (0...10000).contains(dollars) { model.search.maxPrice = Int((dollars * 100).rounded()) }
                        else { model.search.maxPrice = nil }
                    })).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                }.padding(.top, 12)
            }
            Button { Task { await model.find() } } label: { Label("Find tickets", systemImage: "arrow.up.right").frame(maxWidth: .infinity).padding(8) }
                .buttonStyle(.borderedProminent).disabled(model.busy)
            Divider()
            Text("Or describe your plan").font(.headline)
            TextField("Two train tickets to Boston tomorrow under $150", text: $model.message, axis: .vertical).textFieldStyle(.roundedBorder).accessibilityLabel("Describe your ticket search")
            HStack {
                Button { Task { await access.toggleDictation() } } label: { Label(access.listening ? "Stop" : "Dictate", systemImage: access.listening ? "stop.fill" : "mic") }.buttonStyle(.bordered)
                Button("Prepare search") { Task { await model.interpret() } }.buttonStyle(.bordered).disabled(model.busy || model.message.isEmpty)
            }
            if !access.speechStatus.isEmpty { Text(access.speechStatus).font(.footnote) }
            if access.motionEnabled { Text(access.motionStatus).font(.footnote) }
        }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 18))
    }

    private func offerCard(_ offer: TicketOffer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(offer.category.title.uppercased(), systemImage: offer.category.symbol).font(.caption).tracking(2)
            Text(offer.title).font(.title2).fontDesign(.serif)
            Text(offer.description).font(.subheadline)
            Text("\(offer.origin) → \(offer.destination) · \(offer.date) · \(offer.departure)").font(.footnote)
            Text(offer.features.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: " · ")).font(.footnote)
            HStack {
                VStack(alignment: .leading) {
                    Text(ticketMoney(offer.total(for: model.resultPassengers))).font(.title2).bold()
                    Text("Total for \(model.resultPassengers) including fees").font(.caption)
                }
                Spacer()
                Button("Review") { Task { await model.review(offer) } }
                    .buttonStyle(.bordered).disabled(model.busy)
                    .accessibilityLabel("Review \(offer.title), \(ticketMoney(offer.total(for: model.resultPassengers))) total")
                    .accessibilityFocused($focusedOffer, equals: offer.id)
            }
        }.padding(22).background(Color(red: 0.91, green: 0.94, blue: 0.86), in: RoundedRectangle(cornerRadius: 18))
    }

    private func review(_ quote: TicketQuote) -> some View {
        NavigationStack {
            Form {
                Section("Your experience") {
                    Text(quote.offer.title).font(.title2).fontDesign(.serif)
                    Text("\(quote.offer.origin) → \(quote.offer.destination)")
                    Text("\(quote.offer.date) · \(quote.offer.departure)–\(quote.offer.arrival)")
                    Text("\(quote.passengers) people")
                }
                Section("Requested features") {
                    Text(quote.preferences.summary)
                    Text(quote.offer.accessNote).font(.footnote)
                }
                Section("Price review · USD") {
                    LabeledContent("Tickets", value: ticketMoney(quote.subtotalMinor))
                    LabeledContent("All demo fees", value: ticketMoney(quote.feesMinor))
                    LabeledContent("Total", value: ticketMoney(quote.totalMinor)).bold()
                    Text("Review expires: \(quote.expiresAt)").font(.caption)
                }
                Section {
                    demoNotice
                    Toggle("I understand this is a demo ticket with no payment or real reservation.", isOn: $accepted)
                    if let error = model.error { errorView(error) }
                    Button {
                        Task { if await model.confirm() { tab = 1 } }
                    } label: { Text(model.busy ? "Saving…" : "Create demo ticket").frame(maxWidth: .infinity).padding(8) }
                        .buttonStyle(.borderedProminent).disabled(!accepted || model.busy)
                }
            }
            .navigationTitle("Check the details")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { model.quote = nil } } }
        }.interactiveDismissDisabled(model.busy)
    }

    private var accessStudio: some View {
        NavigationStack {
            Form {
                Section("Your experience, your rules") {
                    Toggle("More contrast", isOn: $contrast)
                    Toggle("Larger text", isOn: $large)
                    Toggle("Less movement", isOn: $reduceMotion)
                    Toggle("Haptic feedback", isOn: $haptics)
                    Toggle("Speak updates", isOn: $spoken)
                    Button("Read a summary aloud") { access.read(model.status.isEmpty ? "Welcome to Faith. Find flights, trains, buses, cinema, and event demo tickets. All actions also work through text and touch." : model.status) }
                }
                Section("Tilt to explore") {
                    Text("Hold comfortably, then enable motion. Tilt left or right to focus the previous or next result. Return to center between moves. Motion never selects or confirms tickets.")
                    Button(access.motionEnabled ? "Disable motion controls" : "Enable motion controls") { access.toggleMotion() }
                    Text(access.motionStatus).font(.footnote)
                }
                Section("Your data") {
                    Text("Motion and on-device dictation stay on this device. Text searches go to your configured backend and, when enabled, AWS Bedrock. Requested access features and demo tickets are saved under a private session. No camera, location, card details, or diagnosis is required. Use fictional requests while testing.")
                }
                Section { demoNotice }
            }.navigationTitle("Access studio")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showAccess = false } } }
        }
    }

    private func errorView(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(.red)
            .accessibilityLabel("Error. \(text)")
    }
}
