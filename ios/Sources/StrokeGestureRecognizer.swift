import UIKit

final class StrokeGestureRecognizer: UIGestureRecognizer {
    private(set) var trackedTouch: UITouch?
    private(set) var coalescedTouches: [UITouch] = []

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, let touch = touches.first(where: { $0.type == .pencil }) else {
            state = .failed
            return
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
