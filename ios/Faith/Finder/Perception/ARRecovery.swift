import Foundation

/// When and how ARSessionController restarts a dead AR session (e.g. "Required sensor
/// failed" when the phone gets hot). Pure rules, unit tested.
enum ARRecovery {
    /// No camera frame for this long while running = the camera died silently.
    static let stalledFrameSeconds: TimeInterval = 4
    /// How often the watchdog looks for stalled frames.
    static let watchdogIntervalSeconds: TimeInterval = 2
    /// After a restart, frames must be back within this long or we escalate.
    static let restartGraceSeconds: TimeInterval = 6

    /// Wait before restart attempt `attempt` (1-based): 1, 2, 4, then every 5 s.
    static func delaySeconds(attempt: Int) -> TimeInterval {
        switch attempt {
        case ...1:
            return 1
        case 2:
            return 2
        case 3:
            return 4
        default:
            return 5
        }
    }

    /// First try keeps the same world (the current target and remembered spots stay valid).
    /// If that didn't bring the camera back, start a fresh world.
    static func shouldResetWorld(attempt: Int) -> Bool {
        return attempt >= 2
    }

    static func isStalled(lastFrameAt: Date?, now: Date, isRunning: Bool) -> Bool {
        guard isRunning, let lastFrameAt else {
            return false
        }
        return now.timeIntervalSince(lastFrameAt) > stalledFrameSeconds
    }

    static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:
            return "ok"
        case .fair:
            return "warm"
        case .serious:
            return "HOT"
        case .critical:
            return "CRITICAL"
        @unknown default:
            return "unknown"
        }
    }
}

extension Notification.Name {
    /// Posted by ARSessionController when recovery had to start a fresh AR world:
    /// every earlier world position (current target, remembered spots) is now meaningless.
    static let finderARWorldDidReset = Notification.Name("finderARWorldDidReset")
}
