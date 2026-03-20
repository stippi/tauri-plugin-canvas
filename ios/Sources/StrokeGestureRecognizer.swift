import UIKit

final class StrokeGestureRecognizer: UIGestureRecognizer {
    /// The canvas view whose drawing rect limits where strokes are recognised.
    /// Pencil touches outside the drawing rect are ignored so that toolbar
    /// taps and other UI interactions still work.
    weak var canvasView: MetalCanvasView?

    private(set) var trackedTouch: UITouch?
    private(set) var coalescedTouches: [UITouch] = []

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        // When the recognizer lives on the parent view (above WKWebView), a
        // recognised pencil gesture must cancel the corresponding touch in the
        // web view so that SVG pointer events don't fire simultaneously.
        // For finger touches the recognizer immediately fails, so
        // cancelsTouchesInView has no effect on them.
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, let touch = touches.first(where: { $0.type == .pencil }) else {
            state = .failed
            return
        }

        // Only recognise touches inside the canvas drawing area. Pencil taps
        // on the toolbar or other UI must pass through to the web view.
        if let canvas = canvasView {
            let loc = touch.location(in: canvas)
            guard canvas.currentDrawingRect.contains(loc) else {
                state = .failed
                return
            }
        }

        trackedTouch = touch
        coalescedTouches = event.coalescedTouches(for: touch) ?? [touch]
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        coalescedTouches = event.coalescedTouches(for: trackedTouch) ?? [trackedTouch]
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        coalescedTouches = event.coalescedTouches(for: trackedTouch) ?? [trackedTouch]
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        coalescedTouches = []
        state = .cancelled
    }

    override func reset() {
        trackedTouch = nil
        coalescedTouches = []
    }
}
