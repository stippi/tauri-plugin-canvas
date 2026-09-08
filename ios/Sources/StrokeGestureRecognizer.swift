import UIKit

final class StrokeGestureRecognizer: UIGestureRecognizer {
    /// The canvas view whose drawing rect limits where strokes are recognised.
    /// Touches outside the drawing rect are ignored so that toolbar taps and
    /// other UI interactions still work.
    weak var canvasView: MetalCanvasView?

    /// When enabled, direct (finger / capacitive stylus) touches draw too.
    /// Pencil touches always draw. Keep `allowedTouchTypes` in sync — it is
    /// what makes UIKit deliver direct touches to this recognizer at all.
    var allowsFingerDrawing = false

    private(set) var trackedTouch: UITouch?
    private(set) var coalescedTouches: [UITouch] = []
    /// UIKit's prediction of where the tracked touch is heading (a few
    /// samples ahead). Only meaningful while the gesture is `.changed`;
    /// consumers must redraw them from scratch on every update, never
    /// accumulate them.
    private(set) var predictedTouches: [UITouch] = []

    /// Direct touches don't begin the gesture immediately: quick taps and
    /// two-finger zoom/pan gestures must pass through to the web view. The
    /// touch stays pending until it travels `directMovementThreshold`; a
    /// second finger or an early lift fails the gesture without ever having
    /// cancelled the web view's touches.
    private var pendingDirectTouch = false
    private var pendingStartLocation: CGPoint = .zero

    private static let directMovementThreshold: CGFloat = 6.0
    /// Direct touches with a larger contact radius are treated as a resting
    /// palm, not a drawing finger.
    private static let palmRadiusThreshold: CGFloat = 22.0

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        // When the recognizer lives on the parent view (above WKWebView), a
        // recognised gesture must cancel the corresponding touch in the web
        // view so that SVG pointer events don't fire simultaneously. Touches
        // this recognizer ignores or fails on are unaffected.
        cancelsTouchesInView = true
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let tracked = trackedTouch {
            if pendingDirectTouch {
                // Second finger before the first one moved → zoom/pan gesture.
                // Fail so the web view keeps receiving both touches untouched.
                state = .failed
            } else if tracked.type == .direct,
                touches.contains(where: {
                    $0.type == .direct && $0.majorRadius < Self.palmRadiusThreshold
                })
            {
                // A deliberate second finger while a finger stroke is already
                // drawing signals a zoom/pan intent — discard the in-progress
                // stroke (it never reaches the web view) instead of drawing
                // on while the scene zooms underneath. Palm-sized contacts
                // don't trigger this; they are just ignored below.
                state = .cancelled
            }
            // Any other extra touches (resting palm during a pencil or finger
            // stroke) are ignored rather than cancelling the stroke.
            for touch in touches {
                ignore(touch, for: event)
            }
            return
        }

        guard let touch = eligibleTouch(in: touches, event: event) else {
            // No eligible touch (palm-sized contact, finger drawing disabled,
            // outside the drawing rect, simultaneous multi-finger landing).
            // Ignore instead of failing so a pencil touch arriving later —
            // e.g. after the palm already rests on the display — can still
            // begin a stroke within the same gesture session.
            for touch in touches {
                ignore(touch, for: event)
            }
            return
        }

        for other in touches where other !== touch {
            ignore(other, for: event)
        }

        trackedTouch = touch
        coalescedTouches = event.coalescedTouches(for: touch) ?? [touch]
        predictedTouches = []

        if touch.type == .pencil {
            state = .began
        } else {
            pendingDirectTouch = true
            pendingStartLocation = location(of: touch)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        coalescedTouches = event.coalescedTouches(for: trackedTouch) ?? [trackedTouch]
        predictedTouches = event.predictedTouches(for: trackedTouch) ?? []

        if pendingDirectTouch {
            let loc = location(of: trackedTouch)
            let dx = loc.x - pendingStartLocation.x
            let dy = loc.y - pendingStartLocation.y
            guard dx * dx + dy * dy >= Self.directMovementThreshold * Self.directMovementThreshold
            else { return }
            pendingDirectTouch = false
            state = .began
            return
        }

        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        coalescedTouches = event.coalescedTouches(for: trackedTouch) ?? [trackedTouch]
        predictedTouches = []
        if pendingDirectTouch {
            // Lifted before the movement threshold → a tap. Let the web view
            // handle it (tappable scene elements keep working in pen mode).
            state = .failed
            return
        }
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let trackedTouch, touches.contains(trackedTouch) else { return }
        coalescedTouches = []
        predictedTouches = []
        state = pendingDirectTouch ? .failed : .cancelled
    }

    override func reset() {
        trackedTouch = nil
        coalescedTouches = []
        predictedTouches = []
        pendingDirectTouch = false
    }

    /// Pick the touch a stroke may start from: a pencil touch always wins;
    /// otherwise a single palm-filtered direct touch inside the drawing rect
    /// when finger drawing is enabled.
    private func eligibleTouch(in touches: Set<UITouch>, event: UIEvent) -> UITouch? {
        if let pencil = touches.first(where: { $0.type == .pencil }), inDrawingRect(pencil) {
            return pencil
        }

        guard allowsFingerDrawing else { return nil }

        let directTouches = touches.filter { $0.type == .direct }
        // Two fingers landing together are a zoom/pan gesture, not a stroke.
        guard directTouches.count == 1, let touch = directTouches.first else { return nil }
        guard touch.majorRadius < Self.palmRadiusThreshold else { return nil }
        guard inDrawingRect(touch) else { return nil }
        return touch
    }

    private func inDrawingRect(_ touch: UITouch) -> Bool {
        guard let canvas = canvasView else { return true }
        return canvas.currentDrawingRect.contains(touch.location(in: canvas))
    }

    private func location(of touch: UITouch) -> CGPoint {
        if let canvas = canvasView {
            return touch.location(in: canvas)
        }
        return touch.location(in: view)
    }
}
