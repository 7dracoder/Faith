import Foundation
import RealityKit
import UIKit
import os

/// Small unlit spheres drawn at world positions so we can see placement on device
/// without headphones. Toggle with the UserDefaults key `debug.showMarkers`
/// (Settings screen); defaults to on.
final class DebugMarkers {
    static let userDefaultsKey = "debug.showMarkers"
    static let radiusMeters: Float = 0.02

    private weak var arView: ARView?
    private var anchors: [AnchorEntity] = []
    private let logger = Logger(subsystem: "app.faith.finder", category: "DebugMarkers")

    init(arView: ARView) {
        self.arView = arView
    }

    var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.userDefaultsKey) != nil else {
            return true
        }
        return defaults.bool(forKey: Self.userDefaultsKey)
    }

    func show(at worldPosition: SIMD3<Float>, color: UIColor) {
        guard isEnabled else {
            return
        }
        guard let arView else {
            logger.error("ARView gone, cannot show marker")
            return
        }

        let mesh = MeshResource.generateSphere(radius: Self.radiusMeters)
        let material = UnlitMaterial(color: color)
        let sphere = ModelEntity(mesh: mesh, materials: [material])

        let anchor = AnchorEntity(world: worldPosition)
        anchor.addChild(sphere)
        arView.scene.addAnchor(anchor)
        anchors.append(anchor)

        logger.info("Marker at \(String(describing: worldPosition), privacy: .public)")
    }

    func clear() {
        guard let arView else {
            anchors.removeAll()
            return
        }
        for anchor in anchors {
            arView.scene.removeAnchor(anchor)
        }
        anchors.removeAll()
    }
}
