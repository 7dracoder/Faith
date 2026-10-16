import AVFoundation
import os

/// Real binaural ("8D") renderer for the cue. The node
/// wiring lives in SpatialAudioGraph. This class owns the audio session, the
/// pulse scheduler and recovery from interruptions and route changes.
///
/// Call every method from the main thread. Only the pulse scheduler runs on its
/// own queue, and it shares state with main through `pulseLock`.
final class SpatialAudioEngine: SpatialAudioRendering, CueDucking {
    private struct PulseState {
        var intervalSeconds: Double = 0.4
        var buffer: AVAudioPCMBuffer?
        var isEngineLive = false
    }

    private static let minimumIntervalSeconds: Double = 0.05
    /// How much of the cue is left while a voice line plays over it.
    private static let duckedCueFraction: Float = 0.3

    private let logger = Logger(subsystem: "app.faith.finder", category: "SpatialAudio")

    private let graph = SpatialAudioGraph()
    private var wantsRunning = false
    private var observers: [NSObjectProtocol] = []

    private var cueBuffers: [CueSoundID: AVAudioPCMBuffer] = [:]
    private var earconBuffers: [Earcon: AVAudioPCMBuffer] = [:]
    private var currentCueSound: CueSoundID = .primary
    private var lastAppliedGain: Float?
    /// What the coordinator last asked for, before ducking.
    private var requestedCueGain: Float = 1
    private var isCueDucked = false

    private let pulseQueue = DispatchQueue(label: "app.faith.finder.audio.pulse", qos: .userInteractive)
    private let pulseLock = NSLock()
    private var pulseState = PulseState()
    private var pulseTimer: DispatchSourceTimer?
    /// Next cue voice to use. Touched only on `pulseQueue`.
    private var nextVoiceIndex = 0

    var isRunning: Bool {
        graph.engine.isRunning
    }

    deinit {
        pulseTimer?.cancel()
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - SpatialAudioRendering

    func start() throws {
        wantsRunning = true
        do {
            try AudioSessionConfigurator.configureAndActivate()
            try loadBuffersIfNeeded()
            try graph.buildIfNeeded()
            try startEngineAndPlayers()
        } catch let error as FinderError {
            wantsRunning = false
            throw error
        } catch {
            wantsRunning = false
            throw FinderError.audioEngineFailed(error.localizedDescription)
        }
        registerObserversIfNeeded()
        logger.info("Engine started. Output: \(AudioSessionConfigurator.outputRouteDescription(), privacy: .public)")
    }

    func stop() {
        logger.info("stop")
        wantsRunning = false
        stopPulsing()
        setEngineLive(false)
        graph.stopCuePlayers()
        graph.earconPlayer.stop()
        graph.engine.stop()
    }

    func setCueSound(_ id: CueSoundID) {
        currentCueSound = id
        guard let buffer = cueBuffers[id] else {
            logger.error("Cue sound \(id.rawValue, privacy: .public) is not loaded, keeping the previous one")
            return
        }
        let resourceName = CueSoundCatalog.resourceName(for: id)
        logger.info("setCueSound \(id.rawValue, privacy: .public), file \(resourceName, privacy: .public)")

        pulseLock.lock()
        pulseState.buffer = buffer
        pulseLock.unlock()
    }

    func setTarget(_ target: AnchoredTarget) {
        logger.info("setTarget \(target.label, privacy: .public) at \(String(describing: target.worldPosition), privacy: .public)")
        recoverEngineIfNeeded(reason: "setTarget")
        graph.setSourcePosition(target.worldPosition)
        startPulsingIfNeeded()
    }

    func clearTarget() {
        logger.info("clearTarget")
        stopPulsing()
    }

    func updateListener(_ pose: ListenerPose) {
        // Called at frame rate, so no logging here.
        graph.setListener(pose)
    }

    func updateCue(_ parameters: CueParameters) {
        pulseLock.lock()
        pulseState.intervalSeconds = parameters.intervalSeconds
        pulseLock.unlock()

        requestedCueGain = min(max(parameters.gain, 0), 1)
        applyCueGain()
    }

    // MARK: - CueDucking

    func setCueDucked(_ isDucked: Bool) {
        guard isDucked != isCueDucked else {
            return
        }
        logger.info("Cue ducked: \(isDucked, privacy: .public)")
        isCueDucked = isDucked
        applyCueGain()
    }

    private func applyCueGain() {
        var gain = requestedCueGain
        if isCueDucked {
            gain *= Self.duckedCueFraction
        }
        if gain != lastAppliedGain {
            graph.setCueVolume(gain)
            lastAppliedGain = gain
        }
    }

    func playEarcon(_ earcon: Earcon) {
        recoverEngineIfNeeded(reason: "playEarcon")
        guard let buffer = earconBuffers[earcon] else {
            logger.error("Earcon \(earcon.rawValue, privacy: .public) is not loaded")
            return
        }
        guard graph.engine.isRunning else {
            logger.error("Earcon \(earcon.rawValue, privacy: .public) skipped, engine is not running")
            return
        }
        logger.info("playEarcon \(earcon.rawValue, privacy: .public)")

        graph.earconPlayer.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        if !graph.earconPlayer.isPlaying {
            graph.earconPlayer.play()
        }
    }

    // MARK: - Setup

    private func loadBuffersIfNeeded() throws {
        if cueBuffers.isEmpty {
            for id in CueSoundID.allCases {
                do {
                    cueBuffers[id] = try AudioBufferLoader.loadCue(id)
                } catch {
                    logger.error("Could not load cue \(id.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }
        if earconBuffers.isEmpty {
            for earcon in Earcon.allCases {
                do {
                    earconBuffers[earcon] = try AudioBufferLoader.loadBuffer(named: earcon.rawValue, channelCount: 2)
                } catch {
                    logger.error("Could not load earcon \(earcon.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        }

        let selectedBuffer = cueBuffers[currentCueSound] ?? cueBuffers[.primary]
        guard let cueBuffer = selectedBuffer else {
            throw FinderError.audioEngineFailed("No cue sound could be loaded")
        }

        pulseLock.lock()
        pulseState.buffer = cueBuffer
        pulseLock.unlock()
    }

    private func startEngineAndPlayers() throws {
        graph.engine.prepare()
        try graph.engine.start()
        graph.playCuePlayers()
        graph.earconPlayer.play()
        setEngineLive(true)
    }

    // MARK: - Pulsing

    private func startPulsingIfNeeded() {
        if pulseTimer != nil {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: pulseQueue)
        timer.setEventHandler { [weak self, weak timer] in
            guard let self, let timer else {
                return
            }
            // One-shot timer re-armed after every pulse, so a new interval
            // takes effect on the next pulse.
            let nextInterval = self.firePulse()
            timer.schedule(deadline: .now() + nextInterval, leeway: .milliseconds(2))
        }
        timer.schedule(deadline: .now(), leeway: .milliseconds(2))
        timer.resume()
        pulseTimer = timer
    }

    private func stopPulsing() {
        pulseTimer?.cancel()
        pulseTimer = nil
    }

    /// Runs on `pulseQueue`. Schedules one cue and returns the delay until the next one.
    private func firePulse() -> Double {
        pulseLock.lock()
        let state = pulseState
        pulseLock.unlock()

        if let buffer = state.buffer, state.isEngineLive {
            // Each pulse takes the next voice, so a cue longer than the interval
            // keeps ringing under the following pulses. .interrupts only matters
            // when the cue outlasts all voices: the oldest, quietest tail is cut
            // instead of queueing the new pulse behind it.
            let voice = graph.cuePlayers[nextVoiceIndex]
            voice.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
            nextVoiceIndex = (nextVoiceIndex + 1) % graph.cuePlayers.count
        }
        return max(state.intervalSeconds, Self.minimumIntervalSeconds)
    }

    private func setEngineLive(_ isLive: Bool) {
        pulseLock.lock()
        pulseState.isEngineLive = isLive
        pulseLock.unlock()
    }

    // MARK: - Interruptions and route changes

    private func registerObserversIfNeeded() {
        if !observers.isEmpty {
            return
        }
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        let interruption = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }

        let routeChange = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.handleRouteChange()
        }

        // The engine stops itself when the hardware format changes (AirPods removed).
        let configurationChange = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: graph.engine,
            queue: .main
        ) { [weak self] _ in
            self?.recoverEngineIfNeeded(reason: "engine configuration change")
        }

        let mediaReset = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            self?.recoverEngineIfNeeded(reason: "media services reset")
        }

        observers = [interruption, routeChange, configurationChange, mediaReset]
    }

    private func handleInterruption(_ notification: Notification) {
        let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return
        }

        switch type {
        case .began:
            logger.info("Audio interruption began")
            setEngineLive(false)
        case .ended:
            logger.info("Audio interruption ended")
            recoverEngineIfNeeded(reason: "interruption ended")
        @unknown default:
            break
        }
    }

    private func handleRouteChange() {
        logger.info("Route changed. Output: \(AudioSessionConfigurator.outputRouteDescription(), privacy: .public)")
        recoverEngineIfNeeded(reason: "route change")
    }

    /// Restarts the engine if it should be running but is not. Safe to call often.
    private func recoverEngineIfNeeded(reason: String) {
        guard wantsRunning else {
            return
        }
        if graph.engine.isRunning {
            graph.playCuePlayers()
            if !graph.earconPlayer.isPlaying {
                graph.earconPlayer.play()
            }
            setEngineLive(true)
            return
        }

        logger.info("Restarting engine after \(reason, privacy: .public)")
        setEngineLive(false)
        // Drop anything queued while the engine was down so it does not play as a burst.
        graph.stopCuePlayers()
        graph.earconPlayer.stop()

        do {
            try AudioSessionConfigurator.activate()
            try startEngineAndPlayers()
            logger.info("Engine restarted. Output: \(AudioSessionConfigurator.outputRouteDescription(), privacy: .public)")
        } catch {
            logger.error("Engine restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
