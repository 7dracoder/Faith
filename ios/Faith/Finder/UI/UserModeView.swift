import SwiftUI
import UIKit

/// A simple, accessible screen for a blind or visually impaired participant.
/// Holding anywhere starts listening; releasing submits the spoken request.
struct UserModeView: View {
    @EnvironmentObject private var coordinator: FinderCoordinator

    @State private var isHoldingToAsk = false

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

                Text(isHoldingToAsk ? "Listening…" : "Hold anywhere to ask")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(foregroundColor)

                Text(statusMessage)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(foregroundColor.opacity(0.85))
                    .padding(.horizontal, FinderTheme.largeSpacing)

                Spacer()

                Text(isHoldingToAsk ? "Release when you finish speaking" : "Press, speak, then release")
                    .font(.headline)
                    .foregroundStyle(foregroundColor)

                Label(coordinator.isRemembering ? "Remembering objects · say “stop remembering”" : "Not remembering objects · say “start remembering”",
                      systemImage: coordinator.isRemembering ? "brain.head.profile" : "pause.circle")
                    .font(.footnote)
                    .foregroundStyle(foregroundColor.opacity(0.8))
                    .padding(.bottom, 40)
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
            Button(coordinator.isRemembering ? "Stop remembering objects" : "Start remembering objects") {
                coordinator.setRemembering(!coordinator.isRemembering)
            }
            Button("Forget what you’ve seen") {
                Task { await coordinator.forgetEverythingSeen() }
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
            return "Say the name of the object you want to find, or ask for a ticket."
        }

        switch coordinator.state {
        case .setup:
            return "Getting the camera ready."
        case .ready:
            return coordinator.memoryAnswer ?? "Ready."
        case .listening:
            return "Listening."
        case .locating(let utterance):
            return coordinator.memoryAnswer ?? "Finding \(utterance)."
        case .guiding(let target, _):
            return "Follow the sound to \(target.label). It chimes when you reach it, or hold and say “found”."
        case .found:
            return "Found it."
        case .error:
            return "Something went wrong. Hold anywhere to try again."
        }
    }

    private var accessibilityStatus: String {
        isHoldingToAsk ? "Listening" : statusMessage
    }

    private var holdAccessibilityHint: String {
        return "Say an object, or ask to book a ticket. Releasing sends the camera view to find it. Say calibrate to recenter. Faith chimes when you reach the object, or hold and say found."
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
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        coordinator.beginVoiceRequest()
    }

    private func endHoldingToAsk() {
        guard isHoldingToAsk else {
            return
        }

        isHoldingToAsk = false
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
