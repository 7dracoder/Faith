import Foundation
import ARKit
import CoreImage
import os

/// Copies everything a request needs out of an ARFrame:
/// an upright JPEG for the vision model, the camera pose and intrinsics, and the LiDAR depth map.
/// The caller must not keep the frame afterwards (ARKit stops delivering frames if you do).
final class SnapshotCapturer {
    static let maximumLongEdge: CGFloat = 1024
    static let jpegQuality: CGFloat = 0.7

    /// One shared context; creating a CIContext per capture is slow.
    private let context = CIContext()
    private let logger = Logger(subsystem: "app.faith.finder", category: "Snapshot")

    func capture(from frame: ARFrame, includeDepth: Bool) throws -> Snapshot {
        let started = Date()

        let jpeg = try uprightJPEG(from: frame.capturedImage)

        var depth: DepthSnapshot?
        if includeDepth {
            depth = copyDepth(from: frame)
        }

        let camera = frame.camera
        let snapshot = Snapshot(
            id: UUID(),
            capturedAt: Date(),
            uprightJPEG: jpeg,
            cameraTransform: camera.transform,
            intrinsics: camera.intrinsics,
            sensorResolution: camera.imageResolution,
            uprightRotation: .portrait,
            depth: depth
        )

        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        let depthText = depth.map { "\($0.width)x\($0.height)" } ?? "none"
        logger.info("Snapshot \(jpeg.count / 1024, privacy: .public) KB, depth \(depthText, privacy: .public), \(elapsedMs, privacy: .public) ms")
        return snapshot
    }

    // MARK: - Image

    /// The sensor image is landscape-right. `.right` rotates it 90 degrees clockwise
    /// to portrait upright, which matches ImageSpace candidate A.
    private func uprightJPEG(from pixelBuffer: CVPixelBuffer) throws -> Data {
        let sensorImage = CIImage(cvPixelBuffer: pixelBuffer)
        var upright = sensorImage.oriented(.right)
        upright = moveToOrigin(upright)

        let extent = upright.extent
        let longEdge = max(extent.width, extent.height)
        if longEdge > Self.maximumLongEdge {
            let scale = Self.maximumLongEdge / longEdge
            upright = upright.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            upright = moveToOrigin(upright)
        }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw FinderError.cameraNotReady
        }
        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        let options: [CIImageRepresentationOption: Any] = [qualityKey: Self.jpegQuality]

        guard let data = context.jpegRepresentation(of: upright, colorSpace: colorSpace, options: options) else {
            logger.error("JPEG encoding failed")
            throw FinderError.cameraNotReady
        }
        return data
    }

    private func moveToOrigin(_ image: CIImage) -> CIImage {
        let origin = image.extent.origin
        if origin == .zero {
            return image
        }
        return image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
    }

    // MARK: - LiDAR depth

    /// Copies smoothedSceneDepth row by row (bytesPerRow can include padding).
    private func copyDepth(from frame: ARFrame) -> DepthSnapshot? {
        guard let sceneDepth = frame.smoothedSceneDepth else {
            return nil
        }

        let depthMap = sceneDepth.depthMap
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard CVPixelBufferGetPixelFormatType(depthMap) == kCVPixelFormatType_DepthFloat32 else {
            logger.error("Unexpected depth pixel format")
            return nil
        }

        guard let depthValues = copyRows(of: depthMap, as: Float.self, width: width, height: height) else {
            return nil
        }

        var confidenceValues: [UInt8]
        if let confidenceMap = sceneDepth.confidenceMap,
           let copied = copyRows(of: confidenceMap, as: UInt8.self, width: width, height: height) {
            confidenceValues = copied
        } else {
            // No confidence map: treat every sample as medium.
            confidenceValues = [UInt8](repeating: 1, count: width * height)
        }

        return DepthSnapshot(
            width: width,
            height: height,
            depthMeters: depthValues,
            confidence: confidenceValues
        )
    }

    private func copyRows<T>(of buffer: CVPixelBuffer, as type: T.Type, width: Int, height: Int) -> [T]? {
        guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height else {
            logger.error("Depth and confidence sizes differ")
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            return nil
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        var values: [T] = []
        values.reserveCapacity(width * height)
        for row in 0..<height {
            let rowStart = base.advanced(by: row * bytesPerRow)
            let typed = rowStart.assumingMemoryBound(to: T.self)
            for column in 0..<width {
                values.append(typed[column])
            }
        }
        return values
    }
}
