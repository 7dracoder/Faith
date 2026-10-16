import SwiftUI
import UIKit

/// A simple, accessible screen for a blind or visually impaired participant.
/// Holding anywhere starts listening; releasing submits the spoken request.
struct UserModeView: View {
    @EnvironmentObject private var coordinator: FinderCoordinator

    @State private var isHoldingToAsk = false
    @State private var pressStartedAt = Date.distantPast
    @State private var lastShortTapAt = Date.distantPast

    var body: some View {
        holdAnywhereSurface
        .onChange(of: coordinator.state) { _, newState in
            playStateHaptic(for: newState)
        }
        .onDisappear {
            if isHoldingToAsk {
                endHoldingToAsk()
            }
        }
    }

    private var holdAnywhereSurface: some View {
        ZStack {
            backgroundColor
                .ignoresSafeArea()

            Circle()
                .fill(FinderTheme.lime.opacity(isHoldingToAsk ? 0.85 : 0.12))
                .frame(width: isHoldingToAsk ? 460 : 220)
                .blur(radius: isHoldingToAsk ? 22 : 8)
                .shadow(
                    color: FinderTheme.lime.opacity(isHoldingToAsk ? 0.9 : 0),
                    radius: 50
                )

            VStack(spacing: FinderTheme.largeSpacing) {
                Spacer()

                Image(systemName: isHoldingToAsk ? "waveform.circle.fill" : "hand.tap.fill")
                    .font(.system(size: 92, weight: .bold))
                    .foregroundStyle(isHoldingToAsk ? FinderTheme.forest : FinderTheme.lime)
                    .symbolEffect(.pulse, isActive: isHoldingToAsk)

                Text(isHoldingToAsk ? "Listening…" : (coordinator.pendingFrame != nil ? "Send this view?" : "Hold anywhere to ask"))
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(foregroundColor)

                Text(statusMessage)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(foregroundColor.opacity(0.85))
                    .padding(.horizontal, FinderTheme.largeSpacing)

                Spacer()

                Text(isHoldingToAsk ? "Release when you finish speaking" : (coordinator.pendingFrame != nil ? "Hold to send · Double tap to cancel" : "Press, speak, then release"))
                    .font(.headline)
                    .foregroundStyle(foregroundColor)
                    .padding(.bottom, 48)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    beginHoldingToAsk()
                }
                .onEnded { _ in
                    endHoldingToAsk()
                }
        )
        .allowsHitTesting(canHoldToAsk)
        .opacity(canHoldToAsk ? 1 : 0.72)
        .animation(.easeOut(duration: 0.16), value: isHoldingToAsk)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold anywhere to ask for an object")
        .accessibilityValue(accessibilityStatus)
        .accessibilityHint(holdAccessibilityHint)
        .accessibilityAction(.magicTap) {
            markFoundWithMagicTap()
        }
        .accessibilityActions {
            if coordinator.pendingFrame != nil {
                Button("Send this view") { coordinator.approvePendingFrame() }
                Button("Don’t send") { coordinator.declinePendingFrame() }
            }
        }
    }

    /// Translucent so the live camera shows through, dark enough to keep the white text high contrast.
    private var backgroundColor: Color {
        isHoldingToAsk ? FinderTheme.mint.opacity(0.88) : Color.black.opacity(0.6)
    }

    private var foregroundColor: Color {
        isHoldingToAsk ? FinderTheme.forest : .white
    }

    private var statusMessage: String {
        if isHoldingToAsk {
            return coordinator.pendingFrame != nil ? "Say yes to send it, or no to cancel." : "Say the name of the object you want to find, or ask for a ticket."
        }
        if let frame = coordinator.pendingFrame {
            return "Send this view to find \(frame.utterance)? Only this one picture is sent, and only if you agree."
        }

        switch coordinator.state {
        case .setup:
            return "Getting the camera ready."
        case .ready:
            return "Ready."
        case .listening:
            return "Listening."
        case .locating(let utterance):
            return "Finding \(utterance)."
        case .guiding(let target, _):
            return "Follow the sound to \(target.label). Hold and say “found” when you have it."
        case .found(let result):
            return String(format: "Found in %.1f seconds.", result.durationSeconds)
        case .error:
            return "Something went wrong. Hold anywhere to try again."
        }
    }

    private var accessibilityStatus: String {
        isHoldingToAsk ? "Listening" : statusMessage
    }

    private var holdAccessibilityHint: String {
        if coordinator.pendingFrame != nil {
            return "Double-tap and hold to send this view, or use the actions to send or cancel."
        }
        if coordinator.memoryOffer != nil {
            return "Say yes to go to where it was last seen, or say no to continue searching."
        }

        return "Say an object, or ask to book a ticket. Say calibrate to recenter. When you reach an object, hold and say found."
    }

    private var canHoldToAsk: Bool {
        switch coordinator.state {
        case .ready, .listening, .guiding, .found, .error:
            return true
        case .setup, .locating:
            return false
        }
    }

    private func beginHoldingToAsk() {
        guard canHoldToAsk, !isHoldingToAsk else {
            return
        }

        isHoldingToAsk = true
        pressStartedAt = Date()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        coordinator.beginVoiceRequest()
    }

    private func endHoldingToAsk() {
        guard isHoldingToAsk else {
            return
        }

        isHoldingToAsk = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let now = Date()
        if coordinator.pendingFrame != nil, now.timeIntervalSince(pressStartedAt) < 0.35 {
            // Two quick taps: don't send.
            if now.timeIntervalSince(lastShortTapAt) < 0.5 {
                lastShortTapAt = .distantPast
                coordinator.declinePendingFrame()
            } else {
                lastShortTapAt = now
            }
        }
        coordinator.endVoiceRequest()
    }

    private func playStateHaptic(for state: FinderState) {
        switch state {
        case .guiding:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .found:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        default:
            break
        }
    }

    private func markFoundWithMagicTap() {
        switch coordinator.state {
        case .guiding:
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            coordinator.markFound()
        default:
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}
