import XCTest
@testable import Faith

/// The long-press detection test converts a screen point to an upright image point
/// independently of ImageSpace (aspect-fill geometry), so it can catch a wrong mapping.
final class DetectionTestMappingTests: XCTestCase {
    // iPhone 14 Pro Max portrait points, upright camera image 1440 x 1920 (4:3).
    private let viewSize = CGSize(width: 430, height: 932)
    private let uprightSize = CGSize(width: 1440, height: 1920)

    private func upright(_ x: CGFloat, _ y: CGFloat) -> NormalizedPoint {
        ARSessionController.uprightNormalized(
            fromViewPoint: CGPoint(x: x, y: y),
            viewSize: viewSize,
            uprightImageSize: uprightSize
        )
    }

    func testViewCenterIsImageCenter() {
        let point = upright(215, 466)
        XCTAssertEqual(point.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(point.y, 0.5, accuracy: 1e-6)
    }

    func testTallScreenCropsImageSides() {
        // The image is wider than the screen, so the screen's left edge is inside the image.
        let left = upright(0, 466)
        let right = upright(430, 466)
        XCTAssertGreaterThan(left.x, 0.15)
        XCTAssertLessThan(left.x, 0.25)
        XCTAssertEqual(left.x + right.x, 1.0, accuracy: 1e-6)
    }

    func testTopAndBottomAreNotCropped() {
        XCTAssertEqual(upright(215, 0).y, 0.0, accuracy: 1e-6)
        XCTAssertEqual(upright(215, 932).y, 1.0, accuracy: 1e-6)
    }

    func testWideViewCropsTopAndBottom() {
        let wide = ARSessionController.uprightNormalized(
            fromViewPoint: CGPoint(x: 0, y: 0),
            viewSize: CGSize(width: 1000, height: 500),
            uprightImageSize: uprightSize
        )
        XCTAssertEqual(wide.x, 0.0, accuracy: 1e-6)
        XCTAssertGreaterThan(wide.y, 0.0)
    }
}
