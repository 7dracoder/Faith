import Foundation
import simd
import os

/// Streams what the app is doing to the live dashboard (live-dashboard/README.md):
/// rounds, each vision answer with its snapshot, and ~5 Hz frames of the listener's
/// position and direction. Presentation only: fire-and-forget, never retried, never
/// blocks or affects guidance. Off unless FINDER_LIVE_URL is set (Local.xcconfig).
@MainActor
final class LiveFeed {
    struct Vector: Encodable, Equatable {
        let x: Float
        let y: Float
        let z: Float

        init(_ v: SIMD3<Float>) {
            x = v.x
            y = v.y
            z = v.z
        }
    }

    struct Frame: Encodable, Equatable {
        let t: Double
        let roundId: String?
        let mode: String?
        let state: String
        let elapsed: Double?
        let listener: Vector
        let forward: Vector
        let phone: Vector
        let phoneForward: Vector
        let headYawDeg: Float
        let headTracking: Bool
        let target: Vector?
        let angleDeg: Float?
        let distanceM: Float?
        let cueIntervalS: Double?
        let onTarget: Bool?
        let phoneDistanceM: Float?
        let detector: Bool?
        let earsLocked: Bool?
    }

    static let frameInterval: TimeInterval = 0.2
    static let maximumInFlight = 3

    private let baseURL: URL
    private let token: String
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let logger = Logger(subsystem: "app.faith.finder", category: "LiveFeed")

    private var lastFrameAt = Date.distantPast
    private var inFlight = 0
    private var hasLoggedFailure = false

    init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        self.session = URLSession(configuration: configuration)
    }

    /// nil unless Info.plist FINDER_LIVE_URL holds an http(s) URL. Always nil under
    /// unit tests, so test runs never put fake rounds on the (public) dashboard.
    static func makeFromBundle(_ bundle: Bundle = .main) -> LiveFeed? {
        if isRunningUnitTests {
            return nil
        }
        let raw = bundle.object(forInfoDictionaryKey: "FINDER_LIVE_URL") as? String ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme, scheme.hasPrefix("http") else {
            return nil
        }
        let token = bundle.object(forInfoDictionaryKey: "FINDER_BACKEND_TOKEN") as? String ?? ""
        return LiveFeed(baseURL: url, token: token)
    }

    static var isRunningUnitTests: Bool {
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    // MARK: - Events

    /// `fromMemory`: guiding to where the object was last seen.
    func roundStarted(_ round: ActiveRound, fromMemory: Bool = false) {
        post("/live/round", [
            "event": "start",
            "roundId": round.id.uuidString,
            "mode": round.mode.rawValue,
            "objectLabel": round.objectLabel,
            "startedAt": round.startedAt.timeIntervalSince1970,
            "fromMemory": fromMemory
        ])
    }

    func roundFound(_ result: RoundResult) {
        post("/live/round", [
            "event": "found",
            "roundId": result.id.uuidString,
            "mode": result.mode.rawValue,
            "objectLabel": result.objectLabel,
            "durationSeconds": result.durationSeconds
        ])
    }

    func roundCancelled() {
        post("/live/round", ["event": "cancelled"])
    }

    func located(
        utterance: String,
        detection: Detection,
        target: AnchoredTarget,
        snapshot: Snapshot,
        latencyMs: Int
    ) {
        let camera = snapshot.cameraTransform.columns.3
        var payload: [String: Any] = [
            "utterance": utterance,
            "label": detection.label,
            "box": [
                "minX": detection.box.minX,
                "minY": detection.box.minY,
                "maxX": detection.box.maxX,
                "maxY": detection.box.maxY
            ],
            "placement": target.placement.rawValue,
            "latencyMs": latencyMs,
            "camera": ["x": camera.x, "y": camera.y, "z": camera.z],
            "target": [
                "x": target.worldPosition.x,
                "y": target.worldPosition.y,
                "z": target.worldPosition.z
            ],
            "snapshotJPEG": snapshot.uprightJPEG.base64EncodedString()
        ]
        if let confidence = detection.confidence {
            payload["confidence"] = confidence
        }
        post("/live/locate", payload)
    }

    /// Call every body pose; sends at most every `frameInterval`.
    func frameIfDue(_ makeFrame: () -> Frame) {
        let now = Date()
        guard now.timeIntervalSince(lastFrameAt) >= Self.frameInterval else {
            return
        }
        guard inFlight < Self.maximumInFlight else {
            // The network is behind; drop this frame rather than pile up requests.
            return
        }
        lastFrameAt = now
        guard let body = try? encoder.encode(["frames": [makeFrame()]]) else {
            return
        }
        send(path: "/live/frames", body: body)
    }

    // MARK: - Pure helpers (unit tested)

    static func stateName(_ state: FinderState) -> String {
        switch state {
        case .setup:
            return "setup"
        case .ready:
            return "ready"
        case .listening:
            return "listening"
        case .locating:
            return "locating"
        case .guiding:
            return "guiding"
        case .found:
            return "found"
        case .error:
            return "error"
        }
    }

    // MARK: - Networking

    private func post(_ path: String, _ payload: [String: Any]) {
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            return
        }
        send(path: path, body: body)
    }

    private func send(path: String, body: Data) {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Finder-Token")
        }
        request.httpBody = body

        inFlight += 1
        let task = session.dataTask(with: request) { [weak self] _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in
                self?.finished(path: path, status: status, error: error)
            }
        }
        task.resume()
    }

    private func finished(path: String, status: Int, error: Error?) {
        inFlight -= 1
        let failed = error != nil || status >= 400
        if failed && !hasLoggedFailure {
            hasLoggedFailure = true
            let reason = error?.localizedDescription ?? "HTTP \(status)"
            logger.warning("Live dashboard unreachable (\(path, privacy: .public)): \(reason, privacy: .public). Further failures are silent.")
        }
        if !failed && hasLoggedFailure {
            hasLoggedFailure = false
            logger.info("Live dashboard reachable again")
        }
    }
}
