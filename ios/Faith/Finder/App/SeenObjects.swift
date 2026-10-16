import Foundation
import simd
import os

/// One object Faith noticed: what, where in words, when, and (for the AR session that saw it) where in space.
/// Never the picture or the user's words.
struct SeenObject: Codable, Equatable {
    let label: String
    let place: String
    let seenAt: Date
    /// Meters, ARKit world space of `arSession` only.
    let position: [Float]?
    let arSession: UUID?

    /// A spot to guide to, only while the AR session that measured it is still running.
    func target(in currentSession: UUID) -> AnchoredTarget? {
        guard arSession == currentSession, let position, position.count == 3 else {
            return nil
        }
        return AnchoredTarget(
            id: UUID(),
            label: label,
            worldPosition: SIMD3<Float>(position[0], position[1], position[2]),
            placement: .raycastEstimatedPlane,
            createdAt: Date()
        )
    }
}

/// The remembered objects: newest sighting per object, a week at most.
struct SeenObjectMemory: Codable, Equatable {
    private(set) var objects: [SeenObject] = []

    static let maximumObjects = 100
    static let keepSeconds: TimeInterval = 7 * 24 * 3600

    mutating func remember(_ seen: SeenObject) {
        let key = Self.key(seen.label)
        if let existing = objects.first(where: { Self.key($0.label) == key }), existing.seenAt > seen.seenAt {
            return
        }
        objects.removeAll { Self.key($0.label) == key }
        objects.append(seen)
        prune()
    }

    mutating func prune(now: Date = Date()) {
        objects.removeAll { now.timeIntervalSince($0.seenAt) > Self.keepSeconds }
        objects.sort { $0.seenAt > $1.seenAt }
        if objects.count > Self.maximumObjects {
            objects.removeLast(objects.count - Self.maximumObjects)
        }
    }

    /// "where did I leave my keys" matches "keys"; "my mug" matches "blue mug". Newest first.
    func bestMatch(for utterance: String) -> SeenObject? {
        let wanted = ObjectMemory.objectWords(utterance)
        guard !wanted.isEmpty else {
            return nil
        }
        return objects
            .sorted { $0.seenAt > $1.seenAt }
            .first { !ObjectMemory.objectWords($0.label).isDisjoint(with: wanted) }
    }

    mutating func clear() {
        objects.removeAll()
    }

    static func key(_ label: String) -> String {
        ObjectMemory.objectWords(label).sorted().joined(separator: " ")
    }

    /// "I last saw your keys on the kitchen counter, 3 minutes ago."
    static func sentence(for seen: SeenObject, now: Date = Date()) -> String {
        let place = seen.place.trimmingCharacters(in: .whitespacesAndNewlines)
        let where_ = place.isEmpty ? "" : " " + place
        return "I last saw your \(seen.label)\(where_), \(timeAgo(seen.seenAt, now: now))."
    }

    static func timeAgo(_ date: Date, now: Date = Date()) -> String {
        let minutes = ObjectMemory.minutesAgo(date, now: now)
        switch minutes {
        case 0: return "just now"
        case 1: return "1 minute ago"
        case 2..<60: return "\(minutes) minutes ago"
        case 60..<120: return "about an hour ago"
        case 120..<(24 * 60): return "\(minutes / 60) hours ago"
        case (24 * 60)..<(48 * 60): return "yesterday"
        default: return "\(minutes / (24 * 60)) days ago"
        }
    }
}

/// When a memory snapshot is worth its cost: at most every few seconds, and only after the
/// view changed (moved or turned) or a while has passed.
enum MemoryCapturePolicy {
    static let minimumInterval: TimeInterval = 5
    static let stillInterval: TimeInterval = 30
    static let movedMeters: Float = 0.5
    static let turnedDegrees: Float = 25

    static func isDue(last: BodyPose?, lastAt: Date?, current: BodyPose, now: Date) -> Bool {
        guard let last, let lastAt else {
            return true
        }
        let elapsed = now.timeIntervalSince(lastAt)
        guard elapsed >= minimumInterval else {
            return false
        }
        if elapsed >= stillInterval {
            return true
        }
        let moved = simd_distance(last.position, current.position) >= movedMeters
        let cosine = simd_dot(simd_normalize(last.forward), simd_normalize(current.forward))
        let turned = acos(min(max(cosine, -1), 1)) * 180 / .pi >= turnedDegrees
        return moved || turned
    }
}

/// Spoken memory controls: "forget what you've seen", "stop remembering", "start remembering".
enum MemoryCommand: Equatable {
    case forget
    case stop
    case start

    static func parse(_ transcript: String) -> MemoryCommand? {
        let words = Set(ObjectMemory.splitWords(transcript))
        guard words.count <= 8 else {
            return nil
        }
        let remembering = !words.isDisjoint(with: ["remembering", "remember", "memory"])
        if words.contains("forget"), words.isDisjoint(with: ["preference", "preferences"]),
           !words.isDisjoint(with: ["seen", "saw", "everything", "memory", "pictures", "photos", "objects", "all"]) {
            return .forget
        }
        if remembering, !words.isDisjoint(with: ["stop", "dont", "pause", "off"]) {
            return .stop
        }
        if remembering, !words.isDisjoint(with: ["start", "resume", "on", "begin"]) {
            return .start
        }
        return nil
    }
}

/// Keeps memory pictures and the remembered objects on the phone, in Application Support,
/// excluded from iCloud backup. Pictures never leave the phone except for the one scan request.
@MainActor
final class SeenObjectStore {
    static let maximumPictures = 200
    static let pictureSeconds: TimeInterval = 24 * 3600

    private(set) var memory = SeenObjectMemory()
    private let directory: URL?
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "app.faith.finder", category: "SeenObjects")

    /// nil directory keeps everything in memory (tests).
    init(directory: URL?, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
        load()
    }

    static func standard() -> SeenObjectStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SeenObjectStore(directory: base.appendingPathComponent("ObjectMemory", isDirectory: true))
    }

    var isRemembering: Bool {
        get { defaults.object(forKey: "memory.remembering") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "memory.remembering") }
    }

    var hasAnnounced: Bool {
        get { defaults.bool(forKey: "memory.announced") }
        set { defaults.set(newValue, forKey: "memory.announced") }
    }

    var pictureCount: Int {
        pictureFiles().count
    }

    func remember(_ objects: [SeenObject]) {
        for seen in objects {
            memory.remember(seen)
        }
        save()
    }

    func forgetAll() {
        memory.clear()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        logger.info("Forgot all remembered objects and pictures")
    }

    /// Saves one memory picture with its AR camera pose, then drops the oldest past the limits.
    func savePicture(_ jpeg: Data, cameraTransform: simd_float4x4, takenAt: Date = Date()) {
        guard let pictures = picturesDirectory() else {
            return
        }
        let name = String(format: "%.3f", takenAt.timeIntervalSince1970)
        let columns = [cameraTransform.columns.0, cameraTransform.columns.1, cameraTransform.columns.2, cameraTransform.columns.3]
        let pose = columns.flatMap { [$0.x, $0.y, $0.z, $0.w] }
        do {
            try jpeg.write(to: pictures.appendingPathComponent(name + ".jpg"), options: [.atomic, .completeFileProtection])
            try JSONEncoder().encode(pose).write(to: pictures.appendingPathComponent(name + ".json"), options: [.atomic, .completeFileProtection])
        } catch {
            logger.error("Couldn't save memory picture: \(error.localizedDescription, privacy: .public)")
        }
        prunePictures()
    }

    func prunePictures(now: Date = Date()) {
        let files = pictureFiles()
        var expired: [URL] = []
        for (index, file) in files.enumerated() {
            let takenAt = Double(file.deletingPathExtension().lastPathComponent) ?? 0
            if index >= Self.maximumPictures || now.timeIntervalSince1970 - takenAt > Self.pictureSeconds {
                expired.append(file)
            }
        }
        for file in expired {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.deletingPathExtension().appendingPathExtension("json"))
        }
    }

    // MARK: - Files

    /// Newest first.
    private func pictureFiles() -> [URL] {
        guard let directory else {
            return []
        }
        let pictures = directory.appendingPathComponent("Pictures", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: pictures, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "jpg" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func picturesDirectory() -> URL? {
        guard let directory = preparedDirectory() else {
            return nil
        }
        let pictures = directory.appendingPathComponent("Pictures", isDirectory: true)
        try? FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        return pictures
    }

    private func preparedDirectory() -> URL? {
        guard var directory else {
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        } catch {
            logger.error("Memory folder unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return directory
    }

    private func load() {
        guard let file = directory?.appendingPathComponent("memory.json"),
              let data = try? Data(contentsOf: file),
              let saved = try? Self.decoder.decode(SeenObjectMemory.self, from: data) else {
            return
        }
        memory = saved
        memory.prune()
    }

    private func save() {
        guard let directory = preparedDirectory(), let data = try? Self.encoder.encode(memory) else {
            return
        }
        try? data.write(to: directory.appendingPathComponent("memory.json"), options: [.atomic, .completeFileProtection])
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
