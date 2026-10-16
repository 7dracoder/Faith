import SwiftUI
import UIKit

/// Wraps the perception preview view and reports taps in the view's own points.
/// PLACEHOLDER from the contracts v1 scaffold.
struct PreviewContainer: UIViewRepresentable {
    let previewView: UIView
    let onTap: (CGPoint) -> Void

    func makeCoordinator() -> TapHandler {
        TapHandler(onTap: onTap)
    }

    func makeUIView(context: Context) -> UIView {
        let recognizer = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(TapHandler.handleTap(_:))
        )
        previewView.addGestureRecognizer(recognizer)
        return previewView
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTap = onTap
    }

    final class TapHandler: NSObject {
        var onTap: (CGPoint) -> Void

        init(onTap: @escaping (CGPoint) -> Void) {
            self.onTap = onTap
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else {
                return
            }
            onTap(recognizer.location(in: view))
        }
    }
}
