import Foundation
import os

struct ServiceFlags {
    var mockPerception: Bool
    var mockLocator: Bool
    var mockHeadTracking: Bool
    var mockAudio: Bool
    var mockVoice: Bool
    var mockTelemetry: Bool

    static let allMocks = ServiceFlags(
        mockPerception: true,
        mockLocator: true,
        mockHeadTracking: true,
        mockAudio: true,
        mockVoice: true,
        mockTelemetry: true
    )
}

extension ServiceFlags {
    /// Layered, last wins:
    /// 1. `Config.defaultFlags` (all mocks on main).
    /// 2. Info.plist `FINDER_REAL_SERVICES`, set per person in the gitignored
    ///    `ios/Config/Local.xcconfig`, e.g. `FINDER_REAL_SERVICES = perception audio`.
    /// 3. UserDefaults (Settings screen, or launch arguments like `-flag.mockPerception NO`).
    static func current(
        defaults: UserDefaults = .standard,
        bundle: Bundle = .main
    ) -> ServiceFlags {
        var flags = Config.defaultFlags
        let realServices = bundle.object(forInfoDictionaryKey: "FINDER_REAL_SERVICES") as? String
        flags = flags.applyingRealServices(realServices ?? "")
        flags.mockPerception = read("flag.mockPerception", fallback: flags.mockPerception, defaults: defaults)
        flags.mockLocator = read("flag.mockLocator", fallback: flags.mockLocator, defaults: defaults)
        flags.mockHeadTracking = read("flag.mockHeadTracking", fallback: flags.mockHeadTracking, defaults: defaults)
        flags.mockAudio = read("flag.mockAudio", fallback: flags.mockAudio, defaults: defaults)
        flags.mockVoice = read("flag.mockVoice", fallback: flags.mockVoice, defaults: defaults)
        flags.mockTelemetry = read("flag.mockTelemetry", fallback: flags.mockTelemetry, defaults: defaults)
        return flags
    }

    /// Turns the named services real. `list` is space or comma separated, case-insensitive.
    func applyingRealServices(_ list: String) -> ServiceFlags {
        var flags = self
        let separators = CharacterSet(charactersIn: " ,")
        let names = list.lowercased().components(separatedBy: separators)
        for name in names {
            switch name {
            case "perception":
                flags.mockPerception = false
            case "locator":
                flags.mockLocator = false
            case "headtracking":
                flags.mockHeadTracking = false
            case "audio":
                flags.mockAudio = false
            case "voice":
                flags.mockVoice = false
            case "telemetry":
                flags.mockTelemetry = false
            default:
                continue
            }
        }
        return flags
    }

    private static func read(_ key: String, fallback: Bool, defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else {
            return fallback
        }
        return defaults.bool(forKey: key)
    }
}

@MainActor
final class AppEnvironment {
    let perception: PerceptionService
    let locator: ObjectLocator
    let headTracker: HeadTracking
    let audio: SpatialAudioRendering
    let voice: VoiceCommandListening
    let telemetry: TelemetryReporting
    /// Pre-recorded voice lines.
    let voicePrompts: VoicePromptPlaying
    /// Sentences with no recorded clip.
    let speech: SentenceSpeaking
    let memoryBackend: ObjectMemoryBackend
    /// Memory pictures and remembered objects on the phone.
    let seenObjects: SeenObjectStore

    init(
        perception: PerceptionService,
        locator: ObjectLocator,
        headTracker: HeadTracking,
        audio: SpatialAudioRendering,
        voice: VoiceCommandListening,
        telemetry: TelemetryReporting,
        voicePrompts: VoicePromptPlaying = MockVoicePromptPlayer(),
        speech: SentenceSpeaking = MockSentenceSpeaker(),
        memoryBackend: ObjectMemoryBackend = MockObjectMemoryBackend(),
        seenObjects: SeenObjectStore? = nil
    ) {
        self.perception = perception
        self.locator = locator
        self.headTracker = headTracker
        self.audio = audio
        self.voice = voice
        self.telemetry = telemetry
        self.voicePrompts = voicePrompts
        self.speech = speech
        self.memoryBackend = memoryBackend
        self.seenObjects = seenObjects ?? SeenObjectStore(directory: nil, defaults: UserDefaults(suiteName: "faith.tests.\(UUID().uuidString)") ?? .standard)
    }

    /// Picks real or mock per flag. Until a real implementation exists, its flag is forced to mock.
    static func make(flags: ServiceFlags, client: BookingClient) -> AppEnvironment {
        let logger = Logger(subsystem: "app.faith.finder", category: "AppEnvironment")
        logger.info("Building environment with flags: \(String(describing: flags), privacy: .public)")

        // Real implementations get wired in here as owners land them.
        let perception = makePerception(useMock: flags.mockPerception, logger: logger)
        // No AnnouncingLocator: the coordinator's memory flow plays the voice lines.
        let locator = makeLocator(useMock: flags.mockLocator, client: client, logger: logger)
        let headTracker = makeHeadTracker(useMock: flags.mockHeadTracking, logger: logger)
        let audio = makeAudio(useMock: flags.mockAudio, logger: logger)
        let voice = makeVoice(useMock: flags.mockVoice, logger: logger)
        // Faith never sends camera or spatial telemetry off the phone.
        let telemetry = MockTelemetry()
        let voicePrompts = makeVoicePrompts(audio: audio, useMock: flags.mockAudio, logger: logger)

        return AppEnvironment(
            perception: perception,
            locator: locator,
            headTracker: headTracker,
            audio: audio,
            voice: voice,
            telemetry: telemetry,
            voicePrompts: voicePrompts,
            speech: flags.mockAudio ? MockSentenceSpeaker() : SentenceSpeaker(),
            memoryBackend: flags.mockLocator ? MockObjectMemoryBackend() : FaithMemoryBackend(client: client),
            seenObjects: SeenObjectStore.standard()
        )
    }

    /// The recorded voice lines need the real audio engine (it owns the session
    /// and ducks the cue under them). With mock audio, the lines are only logged.
    private static func makeVoicePrompts(
        audio: SpatialAudioRendering,
        useMock: Bool,
        logger: Logger
    ) -> VoicePromptPlaying {
        if useMock {
            return MockVoicePromptPlayer()
        }
        guard let player = VoicePromptPlayer.make(audio: audio) else {
            logger.warning("Voice lines unavailable (audio engine can't duck the cue). Logging only.")
            return MockVoicePromptPlayer()
        }
        logger.info("Using real VoicePromptPlayer (recorded voice lines)")
        return player
    }

    private static func makePerception(useMock: Bool, logger: Logger) -> PerceptionService {
        if useMock {
            return MockPerceptionService()
        }
        guard ARSessionController.isSupported else {
            logger.warning("Real perception requested but ARKit world tracking is unsupported (simulator?). Using mock.")
            return MockPerceptionService()
        }
        logger.info("Using real ARSessionController")
        return ARSessionController()
    }

    private static func makeHeadTracker(useMock: Bool, logger: Logger) -> HeadTracking {
        if useMock {
            return MockHeadTracker()
        }
        logger.info("Using real HeadTracker")
        return HeadTracker()
    }

    private static func makeAudio(useMock: Bool, logger: Logger) -> SpatialAudioRendering {
        if useMock {
            return MockSpatialAudio()
        }
        logger.info("Using real SpatialAudioEngine")
        return SpatialAudioEngine()
    }

    private static func makeVoice(useMock: Bool, logger: Logger) -> VoiceCommandListening {
        if useMock {
            return MockVoiceListener()
        }
        logger.info("Using real VoiceCommandListener (on-device speech)")
        return VoiceCommandListener(backend: AppleSpeechBackend())
    }

    private static func makeLocator(useMock: Bool, client: BookingClient, logger: Logger) -> ObjectLocator {
        if useMock {
            return MockObjectLocator()
        }
        logger.info("Using FaithLocator (vision through the Faith backend)")
        return FaithLocator(client: client)
    }
}
