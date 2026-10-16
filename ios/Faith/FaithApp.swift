import SwiftUI
import os

@main
struct FaithApp: App {
    @StateObject private var controller = FaithController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(controller.coordinator)
                .environmentObject(controller.agent)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: controller.enterBackground()
            case .active: controller.becomeActive()
            default: break
            }
        }
    }
}

/// One screen for blind users: hold and speak. Objects go to the finder,
/// ticket requests to the ElevenLabs booking agent. Only one owns the audio at a time.
@MainActor
final class FaithController: ObservableObject {
    let coordinator: FinderCoordinator
    let agent: BookingAgent
    private var pendingFind: String?
    private var backgrounded = false
    private let speaker = SentenceSpeaker()

    init() {
        let client = BookingClient()
        coordinator = FinderCoordinator(environment: AppEnvironment.make(flags: ServiceFlags.current(), client: client))
        agent = BookingAgent(client: client)
        coordinator.onBookingRequest = { [weak self] request in self?.startBooking(request) }
        agent.onFindObject = { [weak self] object in self?.pendingFind = object }
        agent.onFinished = { [weak self] in self?.resumeFinder() }
        Task {
            let reachable = await client.ping()
            Logger(subsystem: "app.faith.booking", category: "Backend").info("Faith backend reachable: \(reachable, privacy: .public)")
        }
    }

    /// The camera and memory capture stop while the booking screen is open.
    private func startBooking(_ request: String) {
        coordinator.onDisappear()
        let speaker = speaker
        agent.start(with: request) { await speaker.speak("Booking assistant") }
    }

    /// The camera, memory capture, and the conversation never run in the background.
    /// Remembered objects stay; their positions are only reused within the same AR session.
    func enterBackground() {
        backgrounded = true
        pendingFind = nil
        if agent.isOn { agent.end() }
        coordinator.onDisappear()
    }

    func becomeActive() {
        guard backgrounded else { return }
        backgrounded = false
        if !agent.isOn { coordinator.onAppear() }
    }

    private func resumeFinder() {
        guard !backgrounded else { return }
        coordinator.onAppear()
        guard let object = pendingFind else { return }
        pendingFind = nil
        Task {
            // The camera needs a moment before it can take a picture.
            for _ in 0..<60 where coordinator.state != .ready {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            coordinator.submitTypedRequest(object)
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var coordinator: FinderCoordinator
    @EnvironmentObject private var agent: BookingAgent

    var body: some View {
        ZStack {
            // ARKit only delivers frames once the AR view is in the window, so it always stays underneath.
            PreviewContainer(previewView: coordinator.previewView) { _ in }
                .ignoresSafeArea()
                .accessibilityHidden(true)
            if agent.isOn {
                AgentView()
            } else {
                UserModeView()
            }
        }
        .onAppear { coordinator.onAppear() }
    }
}

/// The booking screen: opaque mint with a "Booking" header, so it never looks like the finder.
struct AgentView: View {
    @EnvironmentObject private var agent: BookingAgent

    var body: some View {
        ZStack {
            FinderTheme.mint.ignoresSafeArea()
            VStack(spacing: FinderTheme.largeSpacing) {
                HStack(spacing: FinderTheme.smallSpacing) {
                    Image(systemName: "ticket.fill")
                    Text("Booking")
                }
                .font(.largeTitle.weight(.heavy))
                .padding(.top, 24)
                Spacer()
                if let quote = agent.quote {
                    VStack(spacing: FinderTheme.regularSpacing) {
                        Image(systemName: "hand.tap.fill").font(.system(size: 64, weight: .bold))
                        Text("Hold to book · Double tap for another")
                            .font(.system(size: 34, weight: .heavy)).multilineTextAlignment(.center)
                        Text("\(quote.offer.title), \(ticketMoney(quote.totalMinor)) total")
                            .font(.title2.bold()).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(FinderTheme.mint)
                    .padding(FinderTheme.largeSpacing)
                    .frame(maxWidth: .infinity)
                    .background(FinderTheme.forest, in: RoundedRectangle(cornerRadius: FinderTheme.cornerRadius))
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 92, weight: .bold))
                        .symbolEffect(.pulse, isActive: agent.speaking)
                    Text(title).font(.largeTitle.bold()).multilineTextAlignment(.center)
                }
                Text(agent.lastLine).font(.title3).multilineTextAlignment(.center).lineLimit(8)
                    .padding(.horizontal, FinderTheme.regularSpacing)
                Spacer()
                Text("Demo tickets only. Not valid for travel or entry. No payment is taken.")
                    .font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
                Button("End conversation") { agent.end() }
                    .font(.headline).frame(minHeight: FinderTheme.minimumTouchSize).padding(.bottom, 32)
            }
            .foregroundStyle(FinderTheme.forest)
            .padding(.horizontal)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { agent.rejectQuote() }
        .onLongPressGesture(minimumDuration: Config.holdToAcceptSeconds) {
            agent.acceptQuote()
        } onPressingChanged: { pressing in
            if pressing, agent.quote != nil { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Booking. " + title)
        .accessibilityValue(agent.quote.map { "\($0.offer.title), \(ticketMoney($0.totalMinor)) total. Demo ticket." } ?? "")
        .accessibilityHint(agent.quote != nil ? "Double-tap and hold to book. Double-tap for another option." : "Just talk. Two-finger double-tap ends the conversation.")
        .accessibilityAction { agent.rejectQuote() }
        .accessibilityAction(.magicTap) { agent.end() }
        .accessibilityActions {
            if agent.quote != nil {
                Button("Book it") { agent.acceptQuote() }
                Button("Hear another option") { agent.rejectQuote() }
            }
            Button("End conversation") { agent.end() }
        }
    }

    private var title: String {
        if agent.quote != nil { return "Hold to book · Double tap for another" }
        switch agent.phase {
        case .connecting: return "Booking assistant, connecting…"
        default: return agent.speaking ? "Faith is speaking" : "Faith is listening"
        }
    }

    private var symbol: String {
        agent.speaking ? "waveform" : "ear"
    }
}
