import SwiftUI

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

    init() {
        let client = BookingClient()
        coordinator = FinderCoordinator(environment: AppEnvironment.make(flags: ServiceFlags.current(), client: client))
        agent = BookingAgent(client: client)
        coordinator.onBookingRequest = { [weak self] request in self?.startBooking(request) }
        agent.onFindObject = { [weak self] object in self?.pendingFind = object }
        agent.onFinished = { [weak self] in self?.resumeFinder() }
    }

    private func startBooking(_ request: String) {
        coordinator.onDisappear()
        coordinator.forgetRememberedObjects()
        agent.start(with: request)
    }

    /// Camera frames, object positions, and the conversation never outlive the foreground.
    func enterBackground() {
        backgrounded = true
        pendingFind = nil
        if agent.isOn { agent.end() }
        coordinator.onDisappear()
        coordinator.forgetRememberedObjects()
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

struct AgentView: View {
    @EnvironmentObject private var agent: BookingAgent

    var body: some View {
        ZStack {
            (agent.quote != nil ? FinderTheme.mint : FinderTheme.forest).ignoresSafeArea()
            VStack(spacing: FinderTheme.largeSpacing) {
                Spacer()
                Image(systemName: symbol)
                    .font(.system(size: 92, weight: .bold))
                    .foregroundStyle(agent.quote != nil ? FinderTheme.forest : FinderTheme.lime)
                    .symbolEffect(.pulse, isActive: agent.speaking)
                Text(title).font(.largeTitle.bold()).multilineTextAlignment(.center)
                Text(agent.lastLine).font(.title3).multilineTextAlignment(.center).lineLimit(8)
                    .padding(.horizontal, FinderTheme.largeSpacing)
                if let quote = agent.quote {
                    Text("\(quote.offer.title), \(ticketMoney(quote.totalMinor)) total")
                        .font(.title2.bold()).multilineTextAlignment(.center)
                }
                Spacer()
                Text("Demo tickets only. Not valid for travel or entry. No payment is taken.")
                    .font(.footnote).multilineTextAlignment(.center)
                Button("End conversation") { agent.end() }
                    .font(.headline).frame(minHeight: FinderTheme.minimumTouchSize).padding(.bottom, 32)
            }
            .foregroundStyle(agent.quote != nil ? FinderTheme.forest : .white)
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
        .accessibilityLabel(title)
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
        case .connecting: return "Connecting…"
        default: return agent.speaking ? "Faith is speaking" : "Faith is listening"
        }
    }

    private var symbol: String {
        if agent.quote != nil { return "ticket.fill" }
        return agent.speaking ? "waveform" : "ear"
    }
}
