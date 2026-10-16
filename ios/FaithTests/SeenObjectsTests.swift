import XCTest
import simd
@testable import Faith

final class SeenObjectsTests: XCTestCase {
    private let now = Date()

    private func seen(_ label: String, place: String = "", minutesAgo: Double, session: UUID? = nil) -> SeenObject {
        SeenObject(label: label, place: place, seenAt: now.addingTimeInterval(-minutesAgo * 60),
                   position: session == nil ? nil : [1, 0, -1], arSession: session)
    }

    func testNewestSightingPerObjectWinsAndPluralsMatch() {
        var memory = SeenObjectMemory()
        memory.remember(seen("keys", place: "on the desk", minutesAgo: 30))
        memory.remember(seen("Keys", place: "by the door", minutesAgo: 2))
        memory.remember(seen("keys", place: "in the bin", minutesAgo: 60))
        XCTAssertEqual(memory.objects.count, 1)
        XCTAssertEqual(memory.bestMatch(for: "where did I leave my key")?.place, "by the door")
        XCTAssertNil(memory.bestMatch(for: "where is it"))
        XCTAssertNil(memory.bestMatch(for: "wallet"))
    }

    func testPartialLabelMatches() {
        var memory = SeenObjectMemory()
        memory.remember(seen("blue mug", minutesAgo: 5))
        XCTAssertEqual(memory.bestMatch(for: "where's my mug")?.label, "blue mug")
    }

    func testOldAndExcessObjectsAreDropped() {
        var memory = SeenObjectMemory()
        memory.remember(SeenObject(label: "umbrella", place: "", seenAt: Date().addingTimeInterval(-8 * 24 * 3600), position: nil, arSession: nil))
        XCTAssertTrue(memory.objects.isEmpty)
        for index in 0..<(SeenObjectMemory.maximumObjects + 5) {
            memory.remember(SeenObject(label: "thing\(index)", place: "", seenAt: Date().addingTimeInterval(Double(index)), position: nil, arSession: nil))
        }
        XCTAssertEqual(memory.objects.count, SeenObjectMemory.maximumObjects)
        XCTAssertNil(memory.bestMatch(for: "thing0"))
    }

    func testSentence() {
        XCTAssertEqual(SeenObjectMemory.sentence(for: seen("keys", place: "on the kitchen counter", minutesAgo: 3), now: now),
                       "I last saw your keys on the kitchen counter, 3 minutes ago.")
        XCTAssertEqual(SeenObjectMemory.sentence(for: seen("blue mug", minutesAgo: 0.2), now: now),
                       "I last saw your blue mug, just now.")
        XCTAssertEqual(SeenObjectMemory.timeAgo(now.addingTimeInterval(-61), now: now), "1 minute ago")
        XCTAssertEqual(SeenObjectMemory.timeAgo(now.addingTimeInterval(-90 * 60), now: now), "about an hour ago")
        XCTAssertEqual(SeenObjectMemory.timeAgo(now.addingTimeInterval(-5 * 3600), now: now), "5 hours ago")
        XCTAssertEqual(SeenObjectMemory.timeAgo(now.addingTimeInterval(-30 * 3600), now: now), "yesterday")
        XCTAssertEqual(SeenObjectMemory.timeAgo(now.addingTimeInterval(-72 * 3600), now: now), "3 days ago")
    }

    func testGuidanceOnlyInTheSessionThatMeasuredIt() {
        let session = UUID()
        let keys = seen("keys", minutesAgo: 1, session: session)
        XCTAssertEqual(keys.target(in: session)?.worldPosition, SIMD3<Float>(1, 0, -1))
        XCTAssertNil(keys.target(in: UUID()))
        XCTAssertNil(seen("keys", minutesAgo: 1).target(in: session))
    }

    func testCapturePolicyNeedsChangeOrTime() {
        let start = BodyPose(position: .zero, forward: SIMD3<Float>(0, 0, -1))
        let t0 = now
        XCTAssertTrue(MemoryCapturePolicy.isDue(last: nil, lastAt: nil, current: start, now: t0))
        // Too soon, even after a big move.
        let moved = BodyPose(position: SIMD3<Float>(1, 0, 0), forward: start.forward)
        XCTAssertFalse(MemoryCapturePolicy.isDue(last: start, lastAt: t0, current: moved, now: t0.addingTimeInterval(3)))
        // Still phone: not until 30 s.
        XCTAssertFalse(MemoryCapturePolicy.isDue(last: start, lastAt: t0, current: start, now: t0.addingTimeInterval(10)))
        XCTAssertTrue(MemoryCapturePolicy.isDue(last: start, lastAt: t0, current: start, now: t0.addingTimeInterval(31)))
        // Moved or turned enough after 5 s.
        XCTAssertTrue(MemoryCapturePolicy.isDue(last: start, lastAt: t0, current: moved, now: t0.addingTimeInterval(6)))
        let turned = BodyPose(position: .zero, forward: simd_normalize(SIMD3<Float>(1, 0, -1)))
        XCTAssertTrue(MemoryCapturePolicy.isDue(last: start, lastAt: t0, current: turned, now: t0.addingTimeInterval(6)))
        let nudged = BodyPose(position: SIMD3<Float>(0.1, 0, 0), forward: simd_normalize(SIMD3<Float>(0.1, 0, -1)))
        XCTAssertFalse(MemoryCapturePolicy.isDue(last: start, lastAt: t0, current: nudged, now: t0.addingTimeInterval(6)))
    }

    func testMemoryCommands() {
        XCTAssertEqual(MemoryCommand.parse("Forget what you've seen"), .forget)
        XCTAssertEqual(MemoryCommand.parse("forget everything"), .forget)
        XCTAssertEqual(MemoryCommand.parse("stop remembering"), .stop)
        XCTAssertEqual(MemoryCommand.parse("don't remember things"), .stop)
        XCTAssertEqual(MemoryCommand.parse("start remembering"), .start)
        XCTAssertNil(MemoryCommand.parse("forget my preferences"))
        XCTAssertNil(MemoryCommand.parse("where are my keys"))
        XCTAssertNil(MemoryCommand.parse("remember I need step free access"))
    }
}

@MainActor
final class SeenObjectStoreTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private let suite = "SeenObjectStoreTests"

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suite)
    }

    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0xFF, 0xD9])

    func testMemorySurvivesARestartAndIsExcludedFromBackup() throws {
        let store = SeenObjectStore(directory: directory, defaults: defaults)
        store.remember([SeenObject(label: "keys", place: "by the door", seenAt: Date(), position: nil, arSession: nil)])
        let reopened = SeenObjectStore(directory: directory, defaults: defaults)
        XCTAssertEqual(reopened.memory.bestMatch(for: "keys")?.place, "by the door")
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testPicturesKeepTheNewestWithinADay() throws {
        let store = SeenObjectStore(directory: directory, defaults: defaults)
        let now = Date()
        store.savePicture(jpeg, cameraTransform: matrix_identity_float4x4, takenAt: now.addingTimeInterval(-25 * 3600))
        XCTAssertEqual(store.pictureCount, 0, "older than a day is dropped")
        for index in 0..<(SeenObjectStore.maximumPictures + 3) {
            store.savePicture(jpeg, cameraTransform: matrix_identity_float4x4, takenAt: now.addingTimeInterval(Double(index)))
        }
        XCTAssertEqual(store.pictureCount, SeenObjectStore.maximumPictures)
        let pose = directory.appendingPathComponent("Pictures").appendingPathComponent(String(format: "%.3f", now.addingTimeInterval(202).timeIntervalSince1970) + ".json")
        XCTAssertEqual(try JSONDecoder().decode([Float].self, from: Data(contentsOf: pose)).count, 16)
    }

    func testForgetDeletesPicturesAndObjects() {
        let store = SeenObjectStore(directory: directory, defaults: defaults)
        store.savePicture(jpeg, cameraTransform: matrix_identity_float4x4)
        store.remember([SeenObject(label: "keys", place: "", seenAt: Date(), position: nil, arSession: nil)])
        store.forgetAll()
        XCTAssertEqual(store.pictureCount, 0)
        XCTAssertTrue(store.memory.objects.isEmpty)
        XCTAssertTrue(SeenObjectStore(directory: directory, defaults: defaults).memory.objects.isEmpty)
    }

    func testRememberingIsOnByDefaultAndPersists() {
        let store = SeenObjectStore(directory: nil, defaults: defaults)
        XCTAssertTrue(store.isRemembering)
        store.isRemembering = false
        XCTAssertFalse(SeenObjectStore(directory: nil, defaults: defaults).isRemembering)
    }
}
