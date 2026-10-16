import Foundation
import UIKit
import simd
import os

@MainActor
final class FinderCoordinator: ObservableObject {
    @Published private(set) var state: FinderState = .setup {
        didSet {
            if state == .setup && oldValue != .setup {
                setupSince = Date()
            }
        }
    }
    @Published private(set) var status = SystemStatus()
    @Published private(set) var debug = DebugInfo()
    @Published var participantId: String = "P01"
    @Published var isPractice: Bool = false
    @Published var cueSound: CueSoundID = .primary {
        didSet {
            environment.audio.setCueSound(cueSound)
        }
    }
    /// Faith: ticket requests go to the voice booking agent instead of the camera.
    var onBookingRequest: ((String) -> Void)?
    /// Object memory: snapshots every few seconds while the finder is open (persisted on/off).
    @Published private(set) var isRemembering: Bool
    /// The last answer from memory, shown on screen while and after it is spoken.
    @Published private(set) var memoryAnswer: String?

    private let environment: AppEnvironment

    /// Spoken camera status for blind users (App/StatusAnnouncer.swift).
    private let statusAnnouncer: StatusAnnouncing
    private var setupSince = Date()
    private var lastCameraAnnouncement: Date?
    private var saidCameraStarting = false
    private var setupWatchTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "app.faith.finder", category: "Coordinator")

    /// When the round timer actually started (guidance output began). nil = not running.
    private var roundTimerStartedAt: Date?
    private var requestTask: Task<Void, Never>?
    private var errorResetTask: Task<Void, Never>?
    private var foundResetTask: Task<Void, Never>?
    private var arrival = ArrivalDetector()
    private var healthTask: Task<Void, Never>?
    private var lastDebugPublish = Date.distantPast
    private let debugPublishInterval: TimeInterval = 0.1
    private var hasAppeared = false

    /// The phone's horizontal forward at the moment the AirPods reference was set
    /// (connect or calibrate). While head tracking is active, the listener faces this
    /// direction turned by the AirPods yaw, so the phone's live heading is ignored and
    /// turning the phone together with your head is not counted twice.
    /// nil = capture it from the next body pose.
    private var headingReference: SIMD3<Float>?
    private var lastAutoCalibrationAttempt = Date.distantPast

    /// Search trajectory of the current round. Uploaded on FOUND.
    private var roundSamples: [RoundSample] = []
    private var lastSampleTime = Date.distantPast
    private let sampleInterval: TimeInterval = 0.1
    private let maximumSamples = 3000   // 5 minutes at 10 Hz
    private let autoCalibrationRetryInterval: TimeInterval = 0.25

    /// True while push-to-talk is held during a round (.guiding).
    /// The round keeps running; the release decides between "calibrate" and a new object.
    private var isListeningMidRound = false
    /// When the mid-round push-to-talk was pressed. A spoken "found" ends the round
    /// here, not when the transcript arrives (the user touched the object before pressing).
    private var midRoundPressTime: Date?

    /// Live dashboard stream (presentation only). nil unless FINDER_LIVE_URL is set.
    private let liveFeed: LiveFeed?

    /// Reaching: ears locked within arm's reach (ReachLock) so moving the phone doesn't
    /// drag the sound; detector bubble (DetectorCue) when the phone is near the object.
    private var lockedEarPosition: SIMD3<Float>?
    private var isDetectorActive = false
    private let proximityHaptics = ProximityHaptics()

    /// Positions are only valid in the AR world that measured them; a new id per AR start or reset.
    private var arSessionID = UUID()
    private var memoryTask: Task<Void, Never>?
    private var isScanning = false
    private var lastScanPose: BodyPose?
    private var lastScanAt: Date?
    /// Bumped by "forget", so a scan already in flight can't bring old objects back.
    private var memoryGeneration = 0

    /// Perception restarted the AR session with a fresh world (ARRecovery).
    private var worldResetObserver: NSObjectProtocol?

    init(environment: AppEnvironment, statusAnnouncer: StatusAnnouncing? = nil) {
        self.environment = environment
        self.isRemembering = environment.seenObjects.isRemembering
        self.statusAnnouncer = statusAnnouncer ?? StatusAnnouncer()
        self.liveFeed = LiveFeed.makeFromBundle()
        if liveFeed != nil {
            logger.info("Live dashboard feed is ON")
        }
    }

    // MARK: - Read-only helpers for UI

    /// The camera preview to embed. UI wraps this in a UIViewRepresentable.
    var previewView: UIView {
        environment.perception.previewView
    }

    var elapsedSeconds: Double? {
        guard let startedAt = roundTimerStartedAt else {
            return nil
        }
        return Date().timeIntervalSince(startedAt)
    }

    // MARK: - Lifecycle

    func onAppear() {
        guard !hasAppeared else {
            return
        }
        hasAppeared = true
        arSessionID = UUID()
        lastScanAt = nil
        logger.info("onAppear")

        wireCallbacks()

        do {
            try environment.audio.start()
            environment.audio.setCueSound(cueSound)
        } catch {
            logger.error("Audio failed to start: \(error.localizedDescription, privacy: .public)")
            handleError(.audioEngineFailed(error.localizedDescription))
        }

        environment.perception.start()
        environment.headTracker.start()
        status.headTracking = environment.headTracker.status

        Task {
            let authorized = await environment.voice.requestAuthorization()
            if !authorized {
                logger.warning("Speech not authorized. Typed requests still work.")
            }
        }

        startHealthPolling()
        startSetupWatch()
        startMemoryCapture()
    }

    func onDisappear() {
        logger.info("onDisappear")
        hasAppeared = false
        healthTask?.cancel()
        healthTask = nil
        setupWatchTask?.cancel()
        setupWatchTask = nil
        memoryTask?.cancel()
        memoryTask = nil
        foundResetTask?.cancel()
        foundResetTask = nil
        stopGuidance()
        environment.perception.pause()
        environment.headTracker.stop()
        environment.audio.stop()
    }

    // MARK: - Operator intents

    func calibrateHead() {
        let body = environment.perception.currentBodyPose()
        calibratePair(phoneForward: body?.forward)
    }

    /// Takes the AirPods reference and the phone heading at the SAME instant.
    /// If either is missing (no AirPods motion yet, no camera pose yet), the pair stays
    /// unset and handleBodyPose retries on a later frame.
    private func calibratePair(phoneForward: SIMD3<Float>?) {
        environment.headTracker.calibrate()
        status.headTracking = environment.headTracker.status

        let airPodsCalibrated = environment.headTracker.status == .calibrated
        guard airPodsCalibrated, let phoneForward else {
            headingReference = nil
            logger.info("Head calibration pending (AirPods calibrated: \(airPodsCalibrated, privacy: .public))")
            return
        }
        headingReference = phoneForward
        logger.info("Head calibrated, heading reference \(String(describing: phoneForward), privacy: .public)")
    }

    func beginVoiceRequest() {
        let midRound = isInRound
        guard canStartRequest || midRound else {
            if state == .setup {
                // Pressing while the camera is still starting: say so, instead of silence.
                announceCameraStarting(minimumGap: 2)
            }
            logger.info("Ignoring voice press in state \(String(describing: self.state), privacy: .public)")
            return
        }
        guard !isListeningMidRound else {
            return
        }

        // Pressing means facing the phone: recalibrate now, before anything is said.
        calibrateHeadForRequest()
        // The user is answering or asking: don't talk over them.
        environment.voicePrompts.stop()

        do {
            try environment.voice.startListening()
            environment.audio.playEarcon(.listeningStart)
            if midRound {
                // Keep the round (and its timer and cue) running while the user speaks.
                isListeningMidRound = true
                midRoundPressTime = Date()
            } else {
                state = .listening
            }
        } catch {
            logger.error("startListening failed: \(error.localizedDescription, privacy: .public)")
            if midRound {
                return
            }
            handleError(.speechFailed(error.localizedDescription))
        }
    }

    func endVoiceRequest() {
        if isListeningMidRound {
            isListeningMidRound = false
            Task {
                let transcript = await environment.voice.stopListening()
                environment.audio.playEarcon(.listeningEnd)
                handleMidRoundTranscript(transcript)
            }
            return
        }

        guard state == .listening else {
            return
        }
        Task {
            let transcript = await environment.voice.stopListening()
            environment.audio.playEarcon(.listeningEnd)
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                handleError(.speechFailed("Nothing heard"))
                return
            }
            if let command = MemoryCommand.parse(trimmed) {
                state = readyOrSetup
                handleMemoryCommand(command)
                return
            }
            if Self.isBookingRequest(trimmed), let onBookingRequest {
                state = readyOrSetup
                onBookingRequest(trimmed)
                return
            }
            if Self.isFoundCommand(trimmed) {
                // No round running: nothing to finish, and never send "found" to the vision model.
                logger.info("Voice command: found, but no round is running")
                state = readyOrSetup
                return
            }
            if Self.isCalibrateCommand(trimmed) {
                // Already calibrated on press. Confirm and stay ready.
                logger.info("Voice command: calibrate")
                environment.audio.playEarcon(.located)
                state = readyOrSetup
                return
            }
            state = .ready
            startRequest(utterance: trimmed)
        }
    }

    /// Release during a round. "calibrate" / "recenter" / silence: the press already
    /// recalibrated, so confirm and keep the same round and timer. Anything else is a
    /// new object: drop the current round (no result) and start a new request.
    private func handleMidRoundTranscript(_ transcript: String) {
        guard isInRound else {
            // Round ended (FOUND / Cancel) while the button was held.
            return
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let pressTime = midRoundPressTime ?? Date()
        midRoundPressTime = nil

        if Self.isFoundCommand(trimmed) {
            logger.info("Voice command: found")
            finishRound(endedAt: pressTime)
            return
        }
        if trimmed.isEmpty || Self.isCalibrateCommand(trimmed) {
            logger.info("Mid-round recalibration, round continues")
            environment.audio.playEarcon(.located)
            return
        }

        if Self.isLikelyFoundMidRound(trimmed) {
            logger.info("Mid-round \"\(trimmed, privacy: .public)\" taken as found (short, no object named)")
            finishRound(endedAt: pressTime)
            return
        }

        logger.info("Mid-round new request \"\(trimmed, privacy: .public)\", dropping current round")
        stopGuidance()
        startRequest(utterance: trimmed)
    }

    func submitTypedRequest(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        guard canStartRequest else {
            logger.info("Ignoring typed request in state \(String(describing: self.state), privacy: .public)")
            return
        }
        calibrateHeadForRequest()
        startRequest(utterance: trimmed)
    }

    func placeTargetAtTap(_ point: CGPoint) {
        let target: AnchoredTarget
        do {
            target = try environment.perception.placeAtViewPoint(point, label: "tap")
        } catch {
            logger.error("Tap placement failed: \(error.localizedDescription, privacy: .public)")
            handleError(.placementFailed)
            return
        }
        logger.info("Tap placed target at \(String(describing: target.worldPosition), privacy: .public)")

        environment.perception.clearDebugMarkers()
        environment.perception.showDebugMarker(for: target)
        debug.placement = target.placement
        debug.targetPosition = target.worldPosition

        // Manual override during a round: move the target, keep the round and its timer.
        switch state {
        case .guiding(_, let round):
            environment.audio.setTarget(target)
            state = .guiding(target: target, round: round)
        case .ready, .found, .error, .setup:
            // A tap that starts a round means you're holding or facing the phone, like a request.
            // (Taps during a round only move the target: no recalibration, so the sound doesn't jump.)
            calibrateHeadForRequest()
            environment.audio.playEarcon(.located)
            beginGuidance(for: target)
        case .listening, .locating:
            logger.info("Ignoring tap while a request is in flight")
        }
    }

    func markFound() {
        finishRound(endedAt: Date())
    }

    /// Ends the round with a successful result. Operator FOUND uses "now"; a spoken
    /// "found" uses the push-to-talk press time.
    private func finishRound(endedAt: Date) {
        let target: AnchoredTarget
        let round: ActiveRound
        switch state {
        case .guiding(let currentTarget, let currentRound):
            target = currentTarget
            round = currentRound
        default:
            return
        }

        stopMidRoundListening()

        let startedAt = roundTimerStartedAt ?? round.startedAt
        let duration = max(0, endedAt.timeIntervalSince(startedAt))

        stopGuidance()
        environment.audio.playEarcon(.found)

        let headStatus = status.headTracking
        let headTrackingUsed = headStatus == .connected || headStatus == .calibrated

        let result = RoundResult(
            id: round.id,
            participantId: participantId,
            mode: round.mode,
            objectLabel: round.objectLabel,
            durationSeconds: duration,
            success: true,
            isPractice: isPractice,
            headTrackingUsed: headTrackingUsed,
            placement: target.placement,
            startedAt: startedAt,
            appVersion: Config.appVersion
        )
        logger.info("Round found in \(duration, privacy: .public) s, mode \(round.mode.rawValue, privacy: .public)")
        state = .found(result: result)
        liveFeed?.roundFound(result)
        returnToReadyAfterFound(result.id)

        let samples = roundSamples
        roundSamples = []
        Task {
            await environment.telemetry.report(result)
            if !samples.isEmpty {
                await environment.telemetry.reportSamples(samples)
            }
            status.pendingUploads = environment.telemetry.pendingCount
        }
    }

    /// "Found it" once the chime has rung, then back to the hold-to-talk screen.
    private func returnToReadyAfterFound(_ id: UUID) {
        foundResetTask?.cancel()
        foundResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !Task.isCancelled else { return }
            await environment.speech.speak("Found it")
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, case .found(let result) = state, result.id == id else { return }
            state = readyOrSetup
        }
    }

    private func makeLiveFrame(
        body: BodyPose,
        listener: ListenerPose,
        head: HeadRotation,
        headTracking: Bool,
        target: AnchoredTarget?,
        round: ActiveRound?,
        cue: CueParameters?,
        phoneDistance: Float?
    ) -> LiveFeed.Frame {
        var angle: Float?
        var distance: Float?
        if let target {
            angle = Geometry.signedHorizontalAngleDegrees(
                from: listener.position,
                forward: listener.forward,
                to: target.worldPosition
            )
            distance = Geometry.horizontalDistance(listener.position, target.worldPosition)
        }
        var onTarget: Bool?
        if let angle {
            onTarget = abs(angle) < Config.onTargetThresholdDegrees
        }

        return LiveFeed.Frame(
            t: Date().timeIntervalSince1970,
            roundId: round?.id.uuidString,
            mode: round?.mode.rawValue,
            state: LiveFeed.stateName(state),
            elapsed: elapsedSeconds,
            listener: LiveFeed.Vector(listener.position),
            forward: LiveFeed.Vector(listener.forward),
            phone: LiveFeed.Vector(body.position),
            phoneForward: LiveFeed.Vector(body.forward),
            headYawDeg: head.yawRadians * 180 / Float.pi,
            headTracking: headTracking,
            target: target.map { LiveFeed.Vector($0.worldPosition) },
            angleDeg: angle,
            distanceM: distance,
            cueIntervalS: cue?.intervalSeconds,
            onTarget: onTarget,
            phoneDistanceM: phoneDistance,
            detector: round == nil ? nil : isDetectorActive,
            earsLocked: round == nil ? nil : lockedEarPosition != nil
        )
    }

    /// 10 Hz while the round timer runs.
    private func recordSampleIfDue(
        round: ActiveRound,
        listener: ListenerPose,
        head: HeadRotation,
        target: AnchoredTarget
    ) {
        guard let timerStart = roundTimerStartedAt else {
            return
        }
        guard roundSamples.count < maximumSamples else {
            return
        }
        let now = Date()
        guard now.timeIntervalSince(lastSampleTime) >= sampleInterval else {
            return
        }
        lastSampleTime = now

        let sample = Self.makeSample(
            roundId: round.id,
            mode: round.mode,
            secondsSinceStart: now.timeIntervalSince(timerStart),
            listener: listener,
            head: head,
            target: target.worldPosition
        )
        roundSamples.append(sample)
    }

    func cancel() {
        logger.info("cancel in state \(String(describing: self.state), privacy: .public)")
        requestTask?.cancel()
        requestTask = nil
        if state == .listening {
            Task {
                _ = await environment.voice.stopListening()
            }
        }
        stopMidRoundListening()
        stopGuidance()
        environment.voicePrompts.stop()
        roundSamples = []   // cancelled rounds upload nothing
        liveFeed?.roundCancelled()
        errorResetTask?.cancel()
        state = readyOrSetup
    }

    func nextParticipant() {
        let current = Self.participantNumber(from: participantId) ?? 0
        participantId = String(format: "P%02d", current + 1)
        cancel()
        logger.info("Next participant \(self.participantId, privacy: .public)")
    }

    // MARK: - Request pipeline

    private var isInRound: Bool {
        switch state {
        case .guiding:
            return true
        default:
            return false
        }
    }

    private func stopMidRoundListening() {
        guard isListeningMidRound else {
            return
        }
        isListeningMidRound = false
        midRoundPressTime = nil
        Task {
            _ = await environment.voice.stopListening()
        }
    }

    private var canStartRequest: Bool {
        switch state {
        case .ready, .found, .error:
            return true
        default:
            return false
        }
    }

    private var readyOrSetup: FinderState {
        if status.tracking == .normal {
            return .ready
        }
        return .setup
    }

    private func startRequest(utterance: String) {
        errorResetTask?.cancel()
        memoryAnswer = nil

        // Taken at release, so a live find sees what the phone pointed at when the user asked.
        let snapshot: Result<Snapshot, FinderError>
        do {
            snapshot = .success(try environment.perception.captureSnapshot())
        } catch let error as FinderError {
            snapshot = .failure(error)
        } catch {
            snapshot = .failure(.cameraNotReady)
        }

        debug.lastUtterance = utterance
        debug.lastDetection = nil
        state = .locating(utterance: utterance)
        requestTask = Task {
            // A spot measured in an earlier AR session can't be guided to, so it is
            // only spoken and the live find still runs.
            if let seen = await recall(utterance), await answerFromMemory(seen) {
                return
            }
            if Task.isCancelled {
                return
            }
            switch snapshot {
            case .failure(let error):
                handleError(error)
            case .success(let snapshot):
                // Asking is the consent: the picture is sent as soon as the user lets go.
                debug.lastSnapshotJPEG = snapshot.uprightJPEG
                logger.info("Locating \"\(utterance, privacy: .public)\"")
                // Something to hear while the vision model works; the answer's line cuts it off.
                say(.searching)
                await runLocateAndPlace(utterance: utterance, snapshot: snapshot)
            }
        }
    }

    private func runLocateAndPlace(utterance: String, snapshot: Snapshot) async {
        let locator = environment.locator
        let perception = environment.perception
        let started = Date()

        do {
            let detection = try await Self.withTimeout(seconds: Config.locatorTimeoutSeconds + 1) {
                try await locator.locate(utterance: utterance, in: snapshot)
            }
            try Task.checkCancellation()

            let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            debug.locatorLatencyMs = latencyMs
            debug.lastDetection = detection
            logger.info("Located \(detection.label, privacy: .public) in \(latencyMs, privacy: .public) ms")

            let target = try await perception.place(detection, from: snapshot)
            try Task.checkCancellation()

            liveFeed?.located(
                utterance: utterance,
                detection: detection,
                target: target,
                snapshot: snapshot,
                latencyMs: latencyMs
            )
            debug.placement = target.placement
            debug.targetPosition = target.worldPosition
            perception.clearDebugMarkers()
            perception.showDebugMarker(for: target)
            rememberSighting(utterance: utterance, detection: detection, target: target)
            environment.audio.playEarcon(.located)

            // "Item found, navigating", then the beeping. The round timer starts with
            // the cue, so the spoken line never counts.
            await sayAndWait(.foundNavigating)
            try Task.checkCancellation()
            beginGuidance(for: target)
        } catch is CancellationError {
            logger.info("Request cancelled")
        } catch let error as FinderError {
            handleLocateFailure(error, utterance: utterance)
        } catch {
            handleLocateFailure(.locatorFailed(error.localizedDescription), utterance: utterance)
        }
    }

    // MARK: - Object memory

    /// A live find is remembered like a memory scan, with its position in this AR session.
    private func rememberSighting(utterance: String, detection: Detection, target: AnchoredTarget) {
        let position = target.worldPosition
        let sighting = ObjectSighting(
            id: UUID(),
            participantId: participantId,
            objectLabel: detection.label,
            utterance: utterance,
            seenAt: Date(),
            x: position.x,
            y: position.y,
            z: position.z,
            placement: target.placement,
            confidence: detection.confidence
        )
        storeSeen([SeenObject(label: detection.label, place: "", seenAt: sighting.seenAt,
                              position: [position.x, position.y, position.z], arSession: arSessionID)])

        let telemetry = environment.telemetry
        Task {
            await telemetry.reportSighting(sighting)
        }
    }

    /// Keeps a local copy first, so memory works when the backend is unreachable.
    private func storeSeen(_ objects: [SeenObject]) {
        environment.seenObjects.remember(objects)
        let backend = environment.memoryBackend
        let logger = logger
        Task {
            do {
                try await backend.save(objects)
                logger.info("Object memory stored on the backend (\(objects.count, privacy: .public) objects)")
            } catch {
                logger.warning("Object memory kept on the phone only: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The phone's copy first, then the backend's (e.g. after reinstalling).
    private func recall(_ utterance: String) async -> SeenObject? {
        let store = environment.seenObjects
        if let local = store.memory.bestMatch(for: utterance) {
            return local
        }
        let words = ObjectMemory.objectWords(utterance)
        guard !words.isEmpty else {
            return nil
        }
        let backend = environment.memoryBackend
        let name = words.sorted().joined(separator: " ")
        guard let remote = try? await Self.withTimeout(seconds: 4, operation: { try await backend.recall(name: name) }) else {
            return nil
        }
        let found = remote.reduce(into: SeenObjectMemory()) { $0.remember($1) }.bestMatch(for: utterance)
        if let found {
            store.remember([found])
        }
        return found
    }

    /// "I last saw your keys on the kitchen counter, 3 minutes ago." Then guidance, if the spot
    /// was measured in this AR session. Returns false when there's nothing to guide to.
    private func answerFromMemory(_ seen: SeenObject) async -> Bool {
        let sentence = SeenObjectMemory.sentence(for: seen)
        let target = seen.target(in: arSessionID)
        logger.info("Answering from memory, seen \(ObjectMemory.minutesAgo(seen.seenAt), privacy: .public) min ago, guidable: \(target != nil, privacy: .public)")
        memoryAnswer = sentence
        environment.audio.playEarcon(.located)
        await speak(sentence)
        guard !Task.isCancelled, let target else {
            return Task.isCancelled
        }
        environment.perception.clearDebugMarkers()
        environment.perception.showDebugMarker(for: target)
        debug.placement = target.placement
        debug.targetPosition = target.worldPosition
        await sayAndWait(.navigating)
        if !Task.isCancelled {
            beginGuidance(for: target, fromMemory: true)
        }
        return true
    }

    /// The vision model couldn't find it (or couldn't answer), and memory had nothing:
    /// the usual error, plus "Item not found, please turn" when it looked and it wasn't there.
    private func handleLocateFailure(_ error: FinderError, utterance: String) {
        handleError(error)
        if case .objectNotFound = error {
            say(.notFoundTurn)
        }
    }

    private func handleMemoryCommand(_ command: MemoryCommand) {
        environment.audio.playEarcon(.located)
        switch command {
        case .stop:
            setRemembering(false)
            Task { await speak("Okay, I stopped remembering objects. Say start remembering to turn it back on.") }
        case .start:
            setRemembering(true)
            Task { await speak("Okay, I will remember objects I see.") }
        case .forget:
            Task { await forgetEverythingSeen() }
        }
    }

    func setRemembering(_ on: Bool) {
        logger.info("Object memory capture \(on ? "on" : "off", privacy: .public)")
        isRemembering = on
        environment.seenObjects.isRemembering = on
        lastScanAt = nil
    }

    /// Deletes the pictures and remembered objects on the phone and the backend's copy.
    func forgetEverythingSeen() async {
        memoryGeneration += 1
        memoryAnswer = nil
        environment.seenObjects.forgetAll()
        do {
            try await environment.memoryBackend.forget()
            await speak("I forgot everything I have seen.")
        } catch {
            logger.warning("Backend object memory not cleared: \(error.localizedDescription, privacy: .public)")
            await speak("I forgot everything on this phone, but couldn't reach the server to clear its copy. Please try again later.")
        }
    }

    private func startMemoryCapture() {
        memoryTask?.cancel()
        memoryTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await scanIfDue()
            }
        }
    }

    /// One memory snapshot when the view has changed: saved on the phone, listed by the vision
    /// model (the backend keeps no picture), placed in this AR world, and remembered.
    private func scanIfDue() async {
        guard hasAppeared, isRemembering, !isScanning, status.tracking == .normal else {
            return
        }
        switch state {
        case .ready, .found:
            break
        default:
            return
        }
        guard let pose = environment.perception.currentBodyPose(),
              MemoryCapturePolicy.isDue(last: lastScanPose, lastAt: lastScanAt, current: pose, now: Date()),
              let snapshot = try? environment.perception.captureSnapshot() else {
            return
        }
        isScanning = true
        defer { isScanning = false }
        lastScanPose = pose
        lastScanAt = Date()
        let session = arSessionID
        let generation = memoryGeneration
        let store = environment.seenObjects
        store.savePicture(snapshot.uprightJPEG, cameraTransform: snapshot.cameraTransform, takenAt: snapshot.capturedAt)

        let scanned: [ScannedObject]
        do {
            scanned = try await environment.memoryBackend.scan(jpeg: snapshot.uprightJPEG)
        } catch {
            logger.info("Memory scan unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Left the finder, stopped remembering, forgot, or the AR world reset while waiting.
        guard hasAppeared, isRemembering, generation == memoryGeneration, session == arSessionID else {
            return
        }

        var seen: [SeenObject] = []
        for item in scanned {
            let detection = Detection(label: item.label, box: item.box, confidence: item.confidence)
            let target = try? await environment.perception.place(detection, from: snapshot)
            let position = target.map { [$0.worldPosition.x, $0.worldPosition.y, $0.worldPosition.z] }
            seen.append(SeenObject(label: item.label, place: item.place, seenAt: snapshot.capturedAt,
                                   position: position, arSession: position == nil ? nil : session))
        }
        let placed = seen.filter { $0.position != nil }.count
        logger.info("Memory scan: \(seen.count, privacy: .public) objects, \(placed, privacy: .public) placed, \(store.pictureCount, privacy: .public) pictures on the phone")
        if !seen.isEmpty {
            storeSeen(seen)
        }
    }

    private func speak(_ sentence: String) async {
        guard Config.voicePromptsEnabled else {
            return
        }
        await environment.speech.speak(sentence)
    }

    private func say(_ prompt: VoicePrompt) {
        guard Config.voicePromptsEnabled else {
            return
        }
        let player = environment.voicePrompts
        Task {
            await player.play(prompt)
        }
    }

    private func sayAndWait(_ prompt: VoicePrompt) async {
        guard Config.voicePromptsEnabled else {
            return
        }
        await environment.voicePrompts.play(prompt)
    }

    private func beginGuidance(for target: AnchoredTarget, fromMemory: Bool = false) {
        let round = ActiveRound(
            id: UUID(),
            mode: .finder,
            objectLabel: target.label,
            startedAt: Date()
        )

        roundSamples = []
        lastSampleTime = Date.distantPast
        liveFeed?.roundStarted(round, fromMemory: fromMemory)

        // The round timer starts with the guidance sound, so vision latency never counts.
        arrival.reset()
        environment.audio.setTarget(target)
        roundTimerStartedAt = Date()
        state = .guiding(target: target, round: round)
    }

    private func stopGuidance() {
        if case .guiding = state {
            environment.audio.clearTarget()
        }
        roundTimerStartedAt = nil
        debug.cue = nil
        lockedEarPosition = nil
        isDetectorActive = false
        arrival.reset()
        proximityHaptics.stop()
    }

    /// Ears follow the phone while walking; within arm's reach they lock so a reaching
    /// phone doesn't move the sound (ReachLock).
    private func applyReachLock(to listener: inout ListenerPose, phone: SIMD3<Float>, target: SIMD3<Float>) {
        let wasLocked = lockedEarPosition != nil
        lockedEarPosition = ReachLock.update(
            locked: lockedEarPosition,
            liveEars: listener.position,
            phone: phone,
            target: target
        )
        let isLocked = lockedEarPosition != nil
        if isLocked != wasLocked {
            logger.info("Reach lock \(isLocked ? "ON (within arm's reach)" : "OFF (walked away)", privacy: .public)")
        }
        if let lockedEarPosition {
            listener.position = lockedEarPosition
        }
    }

    /// Inside the bubble the cue follows the phone's distance (DetectorCue).
    private func applyDetector(to parameters: CueParameters, phoneDistance: Float) -> CueParameters {
        let wasActive = isDetectorActive
        isDetectorActive = DetectorCue.isActive(phoneDistance: phoneDistance, wasActive: wasActive)
        if isDetectorActive != wasActive {
            logger.info("Detector \(self.isDetectorActive ? "ON" : "OFF", privacy: .public) at \(phoneDistance, privacy: .public) m")
        }
        guard isDetectorActive else {
            return parameters
        }
        return DetectorCue.adjust(parameters, phoneDistance: phoneDistance)
    }

    private func handleError(_ error: FinderError) {
        logger.error("Error: \(String(describing: error), privacy: .public)")
        switch error {
        case .cameraNotReady, .trackingLimited:
            announceCameraStarting(minimumGap: 2)
        default:
            break
        }
        stopGuidance()
        environment.audio.playEarcon(.notFound)
        state = .error(error)

        errorResetTask?.cancel()
        errorResetTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if Task.isCancelled {
                return
            }
            if case .error = state {
                state = readyOrSetup
            }
        }
    }

    // MARK: - Real-time loop (Part 2.2)

    private func wireCallbacks() {
        environment.perception.onBodyPoseUpdate = { [weak self] body in
            self?.handleBodyPose(body)
        }
        environment.perception.onStatusChange = { [weak self] tracking, planeDetected in
            self?.handlePerceptionStatus(tracking: tracking, planeDetected: planeDetected)
        }
        environment.headTracker.onStatusChange = { [weak self] headStatus in
            self?.handleHeadTrackingStatus(headStatus)
        }

        if let worldResetObserver {
            NotificationCenter.default.removeObserver(worldResetObserver)
        }
        worldResetObserver = NotificationCenter.default.addObserver(
            forName: .finderARWorldDidReset,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWorldReset()
            }
        }
    }

    /// After a fresh AR world, old positions point at nothing: end the round (no result)
    /// and take a new heading reference from the next frame.
    private func handleWorldReset() {
        logger.warning("AR world was reset; positions from before are no longer valid")
        headingReference = nil
        arSessionID = UUID()
        guard isInRound || state == .listening else {
            return
        }
        stopMidRoundListening()
        stopGuidance()
        roundSamples = []
        liveFeed?.roundCancelled()
        environment.perception.clearDebugMarkers()
        handleError(.trackingLimited("Camera restarted, please ask again"))
    }

    /// Blind users can't find a Calibrate button, so every request recalibrates.
    /// Asking means reaching for or holding the phone in front of you, so you're
    /// almost certainly facing it. Also cancels AirPods drift on every request.
    private func calibrateHeadForRequest() {
        guard Self.isHeadTrackingActive(status.headTracking) else {
            return
        }
        logger.info("Auto-calibrating head at request start")
        calibrateHead()
    }

    private func handleHeadTrackingStatus(_ headStatus: HeadTrackingStatus) {
        status.headTracking = headStatus

        // Only our own calibratePair produces a valid pair (status .calibrated).
        // .connected means the AirPods picked or reset their reference on their own
        // (first motion, reconnect), so the pair is stale: recalibrate on the next frame.
        // .disconnected / .unavailable: fall back to the phone's live heading.
        if headStatus != .calibrated {
            if headingReference != nil {
                logger.info("Head tracking \(String(describing: headStatus), privacy: .public), heading reference reset")
            }
            headingReference = nil
        }
    }

    private func handleBodyPose(_ body: BodyPose) {
        let headActive = Self.isHeadTrackingActive(status.headTracking)
        if headActive && headingReference == nil {
            let now = Date()
            if now.timeIntervalSince(lastAutoCalibrationAttempt) >= autoCalibrationRetryInterval {
                lastAutoCalibrationAttempt = now
                logger.info("Auto-calibrating head (startup or AirPods reconnect)")
                calibratePair(phoneForward: body.forward)
            }
        }

        var activeTarget: AnchoredTarget?
        var activeRound: ActiveRound?
        if case .guiding(let currentTarget, let currentRound) = state {
            activeTarget = currentTarget
            activeRound = currentRound
        }

        // Outside a round the pose is only needed for the live dashboard.
        if activeRound == nil && liveFeed == nil {
            return
        }

        let head = environment.headTracker.currentRotation()
        let listenerBody = Self.listenerBody(
            body: body,
            headingReference: headingReference,
            headTrackingActive: headActive
        )
        var listener = ListenerPoseMath.compose(body: listenerBody, head: head, rig: Config.rig)

        var cue: CueParameters?
        var phoneDistance: Float?
        if let target = activeTarget {
            applyReachLock(to: &listener, phone: body.position, target: target.worldPosition)

            environment.audio.updateListener(listener)
            var parameters = CueModulator.parameters(listener: listener, target: target)

            let distance = simd_distance(body.position, target.worldPosition)
            phoneDistance = distance
            if arrival.update(phoneDistance: distance, at: Date()) {
                logger.info("Reached the object, phone \(distance, privacy: .public) m away")
                finishRound(endedAt: Date())
                return
            }
            parameters = applyDetector(to: parameters, phoneDistance: distance)
            let angle = Geometry.signedHorizontalAngleDegrees(from: listener.position, forward: listener.forward,
                                                              to: target.worldPosition)
            proximityHaptics.update(HapticGuidance.pulse(phoneDistance: distance, angleDegrees: angle))

            environment.audio.updateCue(parameters)
            cue = parameters
        }

        liveFeed?.frameIfDue {
            makeLiveFrame(
                body: body,
                listener: listener,
                head: head,
                headTracking: headActive,
                target: activeTarget,
                round: activeRound,
                cue: cue,
                phoneDistance: phoneDistance
            )
        }

        guard let target = activeTarget, let round = activeRound else {
            return
        }

        recordSampleIfDue(round: round, listener: listener, head: head, target: target)

        let now = Date()
        guard now.timeIntervalSince(lastDebugPublish) >= debugPublishInterval else {
            return
        }
        lastDebugPublish = now

        var updated = debug
        updated.cue = cue
        updated.headRotation = head
        updated.targetPosition = target.worldPosition
        updated.targetDistanceMeters = Geometry.horizontalDistance(listener.position, target.worldPosition)
        updated.targetAngleDegrees = Geometry.signedHorizontalAngleDegrees(
            from: listener.position,
            forward: listener.forward,
            to: target.worldPosition
        )
        debug = updated
    }

    private func handlePerceptionStatus(tracking: TrackingSummary, planeDetected: Bool) {
        status.tracking = tracking
        status.planeDetected = planeDetected
        if tracking == .normal && state == .setup {
            state = .ready
            if saidCameraStarting {
                saidCameraStarting = false
                statusAnnouncer.say(.cameraReady)
            }
            announceMemoryOnce()
        }
    }

    /// Once per install, after "Camera ready" has had time to play.
    private func announceMemoryOnce() {
        let store = environment.seenObjects
        guard !store.hasAnnounced else {
            return
        }
        store.hasAnnounced = true
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await speak(Self.memoryAnnouncement)
        }
    }

    nonisolated static let memoryAnnouncement =
        "Faith remembers objects it sees to help you find them later. Say stop remembering to turn this off."

    // MARK: - Spoken camera status

    /// While stuck in setup: say "The camera is still starting…" after a few seconds,
    /// then again every so often, so a blind user isn't left in silence.
    private func startSetupWatch() {
        setupWatchTask?.cancel()
        setupWatchTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard state == .setup else {
                    continue
                }
                let stuckFor = Date().timeIntervalSince(setupSince)
                if stuckFor >= Config.cameraStartingAnnounceAfterSeconds {
                    announceCameraStarting(minimumGap: Config.cameraStartingRepeatSeconds)
                }
            }
        }
    }

    private func announceCameraStarting(minimumGap: TimeInterval) {
        let now = Date()
        if let last = lastCameraAnnouncement, now.timeIntervalSince(last) < minimumGap {
            return
        }
        lastCameraAnnouncement = now
        saidCameraStarting = true
        logger.info("Camera still starting, telling the user")
        statusAnnouncer.say(.cameraStarting)
    }

    // MARK: - Backend health

    private func startHealthPolling() {
        healthTask?.cancel()
        healthTask = Task {
            while !Task.isCancelled {
                let reachable = await environment.telemetry.ping()
                status.backendReachable = reachable
                status.pendingUploads = environment.telemetry.pendingCount
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    // MARK: - Helpers

    /// "found", "found it", "got it", "i got it", "here it is", "i have it", plus common
    /// mishearings of "found" ("fund", "fond") and "done". Case and punctuation ignored.
    nonisolated static func isFoundCommand(_ transcript: String) -> Bool {
        let lowered = transcript.lowercased()
        let phrases = ["found", "got it", "here it is", "have it", "grabbed it"]
        for phrase in phrases {
            if lowered.contains(phrase) {
                return true
            }
        }
        let words = Set(ObjectMemory.splitWords(transcript))
        let soundAlikes: Set<String> = ["fund", "fond", "foun", "done"]
        return !words.isDisjoint(with: soundAlikes)
    }

    /// Mid-round, a short reply that doesn't name an object or sound like a request is
    /// almost always a misheard "found" ("fun", "sound"...). Ending the round beats
    /// silently dropping it and starting a search for "fun".
    nonisolated static func isLikelyFoundMidRound(_ transcript: String) -> Bool {
        let words = ObjectMemory.splitWords(transcript)
        guard !words.isEmpty, words.count <= 2 else {
            return false
        }
        let requestWords: Set<String> = ["where", "wheres", "find", "look", "my", "the", "a", "calibrate", "recenter", "center"]
        let known = Set(Config.knownObjects)
        for word in words {
            if requestWords.contains(word) || known.contains(ObjectMemory.singular(word)) || known.contains(word) {
                return false
            }
        }
        return true
    }

    /// Faith: "book a train to Boston", "I need tickets for a concert". Case and punctuation ignored.
    nonisolated static func isBookingRequest(_ transcript: String) -> Bool {
        let words = Set(ObjectMemory.splitWords(transcript))
        // "where's my bus pass" or "find my phone" is an object, not a booking.
        let objectWords = Set(Config.knownObjects).union(["where", "wheres"])
        if !words.isDisjoint(with: objectWords) || words.contains(where: { Config.knownObjects.contains(ObjectMemory.singular($0)) }) {
            return false
        }
        let bookingWords: Set<String> = [
            "book", "booking", "ticket", "tickets", "flight", "flights", "fly", "train", "trains",
            "bus", "buses", "cinema", "movie", "movies", "film", "concert", "event", "events",
            "travel", "trip", "reserve", "reservation", "preferences", "showtimes"
        ]
        return !words.isDisjoint(with: bookingWords)
    }

    /// "calibrate", "recalibrate", "recenter", "re-center", "center". Case and punctuation ignored.
    nonisolated static func isCalibrateCommand(_ transcript: String) -> Bool {
        let lowered = transcript.lowercased()
        let keywords = ["calibrate", "recenter", "re-center", "re center", "center"]
        for keyword in keywords {
            if lowered.contains(keyword) {
                return true
            }
        }
        return false
    }

    nonisolated static func makeSample(
        roundId: UUID,
        mode: RoundMode,
        secondsSinceStart: Double,
        listener: ListenerPose,
        head: HeadRotation,
        target: SIMD3<Float>
    ) -> RoundSample {
        let angle = Geometry.signedHorizontalAngleDegrees(
            from: listener.position,
            forward: listener.forward,
            to: target
        )
        let distance = Geometry.horizontalDistance(listener.position, target)
        let yawDegrees = head.yawRadians * 180 / Float.pi

        return RoundSample(
            roundId: roundId,
            secondsSinceStart: secondsSinceStart,
            mode: mode,
            angleDegrees: angle,
            distanceMeters: distance,
            headYawDegrees: yawDegrees
        )
    }

    nonisolated static func isHeadTrackingActive(_ headStatus: HeadTrackingStatus) -> Bool {
        return headStatus == .connected || headStatus == .calibrated
    }

    /// Phone gives the position. Direction comes from the AirPods (via `head` in
    /// ListenerPoseMath) anchored to `headingReference`. Without head tracking,
    /// the phone's live heading is the only direction we have.
    nonisolated static func listenerBody(
        body: BodyPose,
        headingReference: SIMD3<Float>?,
        headTrackingActive: Bool
    ) -> BodyPose {
        guard headTrackingActive, let reference = headingReference else {
            return body
        }
        return BodyPose(position: body.position, forward: reference)
    }

    nonisolated static func participantNumber(from id: String) -> Int? {
        let digits = id.filter { $0.isNumber }
        return Int(digits)
    }

    /// Races `operation` against a timer. Throws FinderError.locatorTimeout if the timer wins.
    private static func withTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw FinderError.locatorTimeout
            }
            guard let first = try await group.next() else {
                throw FinderError.locatorTimeout
            }
            group.cancelAll()
            return first
        }
    }
}
