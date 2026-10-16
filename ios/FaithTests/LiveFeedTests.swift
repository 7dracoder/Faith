import XCTest
@testable import Faith

/// The live dashboard (live-dashboard/static/app.js) reads these exact JSON keys.
@MainActor
final class LiveFeedTests: XCTestCase {
    func testFrameJSONMatchesDashboard() throws {
        let frame = LiveFeed.Frame(
            t: 1_791_000_000,
            roundId: "R1",
            mode: "finder",
            state: "guiding",
            elapsed: 2.5,
            listener: LiveFeed.Vector(SIMD3<Float>(0, 0.3, 0.35)),
            forward: LiveFeed.Vector(SIMD3<Float>(0, 0, -1)),
            phone: LiveFeed.Vector(SIMD3<Float>(0, 0, 0)),
            phoneForward: LiveFeed.Vector(SIMD3<Float>(0, 0, -1)),
            headYawDeg: 12,
            headTracking: true,
            target: LiveFeed.Vector(SIMD3<Float>(0.2, -0.3, -0.5)),
            angleDeg: 14,
            distanceM: 0.9,
            cueIntervalS: 0.3,
            onTarget: false,
            phoneDistanceM: 0.25,
            detector: true,
            earsLocked: true
        )
        let data = try JSONEncoder().encode(frame)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let expectedKeys: Set<String> = [
            "t", "roundId", "mode", "state", "elapsed", "listener", "forward", "phone",
            "phoneForward", "headYawDeg", "headTracking", "target", "angleDeg",
            "distanceM", "cueIntervalS", "onTarget", "phoneDistanceM", "detector", "earsLocked"
        ]
        XCTAssertEqual(Set(json.keys), expectedKeys)

        let listener = try XCTUnwrap(json["listener"] as? [String: Double])
        XCTAssertEqual(listener["z"] ?? 0, 0.35, accuracy: 1e-6)
    }

    func testIdleFrameOmitsTargetFields() throws {
        let frame = LiveFeed.Frame(
            t: 1, roundId: nil, mode: nil, state: "ready", elapsed: nil,
            listener: LiveFeed.Vector(.zero), forward: LiveFeed.Vector(SIMD3<Float>(0, 0, -1)),
            phone: LiveFeed.Vector(.zero), phoneForward: LiveFeed.Vector(SIMD3<Float>(0, 0, -1)),
            headYawDeg: 0, headTracking: false, target: nil, angleDeg: nil,
            distanceM: nil, cueIntervalS: nil, onTarget: nil,
            phoneDistanceM: nil, detector: nil, earsLocked: nil
        )
        let data = try JSONEncoder().encode(frame)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["target"])
        XCTAssertEqual(json["state"] as? String, "ready")
    }

    func testStateNames() {
        XCTAssertEqual(LiveFeed.stateName(.ready), "ready")
        XCTAssertEqual(LiveFeed.stateName(.locating(utterance: "mug")), "locating")
        XCTAssertEqual(LiveFeed.stateName(.error(.locatorTimeout)), "error")
    }

    func testFeedIsOffWithoutURL() {
        XCTAssertNil(LiveFeed.makeFromBundle(Bundle(for: LiveFeedTests.self)))
    }

    /// Even with FINDER_LIVE_URL set in Local.xcconfig, test runs must not stream.
    func testFeedIsOffUnderUnitTests() {
        XCTAssertTrue(LiveFeed.isRunningUnitTests)
        XCTAssertNil(LiveFeed.makeFromBundle(.main))
    }
}
