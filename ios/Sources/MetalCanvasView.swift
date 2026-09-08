import MetalKit
import UIKit

protocol MetalCanvasViewDelegate: AnyObject {
    func metalCanvasView(_ view: MetalCanvasView, didStartStroke strokeId: String)
    func metalCanvasView(_ view: MetalCanvasView, didEndStroke stroke: CanvasStroke)
    func metalCanvasView(_ view: MetalCanvasView, didStartEraserStroke stroke: ActiveEraserStroke)
    func metalCanvasView(
        _ view: MetalCanvasView, didSampleEraserStroke strokeId: String,
        samples: [CanvasStrokeSample], baseWidth: CGFloat, pressureSensitivity: CGFloat)
    func metalCanvasView(
        _ view: MetalCanvasView, didEndEraserStroke strokeId: String, cancelled: Bool)
    func metalCanvasViewDidClear(_ view: MetalCanvasView)
}

final class MetalCanvasView: MTKView {
    weak var strokeDelegate: MetalCanvasViewDelegate?
    var currentDrawingRect: CGRect { drawingRect }

    private let strokeStorage = StrokeStorage()
    private var penConfig = CanvasPenConfig.default
    private var drawingRect: CGRect = .zero
    private var showsCommittedStrokes = false
    lazy var strokeRecognizer = StrokeGestureRecognizer(
        target: self, action: #selector(handleStroke(_:)))
    private var strokeRenderer: StrokeRenderer?
    private var activeEraserStroke: ActiveEraserStroke?

    /// A committed stroke between "finished here" and "shown by the webview".
    ///
    /// The overlay keeps showing it from its pre-rendered texture. When the
    /// webview has painted its copy it calls `beginStrokeFade`; from then on
    /// both sides run a linear fade of `handoffFadeDuration` — the webview
    /// in, this copy out with the complementary alpha (see
    /// `handoff_fragment`) — so the composite never deviates from the
    /// original stroke. Sync errors between the two display pipelines cost
    /// a coverage error proportional to error/duration, which is why the
    /// fade is long: a correct one is invisible anyway.
    private struct HandoffStroke {
        let id: String
        let texture: MTLTexture
        /// View points, snapped to the device pixel grid.
        let bounds: CGRect
        let createdAt: CFTimeInterval
        var fadeStart: CFTimeInterval?

        func progress(at now: CFTimeInterval, duration: CFTimeInterval) -> CGFloat {
            guard let fadeStart else { return 0 }
            return max(0, min(1, CGFloat((now - fadeStart) / duration)))
        }
    }

    private var handoffs: [HandoffStroke] = []
    private var handoffDisplayLink: CADisplayLink?
    /// Same value as `STROKE_FADE_MS` in the JS API.
    private let handoffFadeDuration: CFTimeInterval = 0.4
    /// The webview's frame reaches the display roughly one frame after its
    /// script ran. Starting late rather than early keeps opaque pixels (for
    /// which the fade degenerates to a hard switch) from ever showing a gap.
    private let handoffFadeLead: CFTimeInterval = 0.016
    /// Fade anyway when the webview never asks (its paint failed): a stale
    /// copy must not stay on screen forever.
    private let handoffFadeTimeout: CFTimeInterval = 3.0

    init(frame: CGRect) {
        super.init(frame: frame, device: MTLCreateSystemDefaultDevice())
        isOpaque = false
        layer.isOpaque = false
        backgroundColor = .clear
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        if let device, device.supportsTextureSampleCount(4) {
            sampleCount = 4
        }
        preferredFramesPerSecond = 120
        enableSetNeedsDisplay = true
        isPaused = true
        isUserInteractionEnabled = false
        isMultipleTouchEnabled = true
        strokeRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        strokeRecognizer.canvasView = self
        strokeRecognizer.isEnabled = false
        // NOTE: The recognizer is NOT added to this view. It is installed on the
        // parent view by CanvasPlugin so that pencil touches are captured
        // regardless of hit-testing, while finger touches pass through to the
        // WKWebView underneath (enabling two-finger zoom/pan).
        strokeRenderer = StrokeRenderer(metalView: self)
        delegate = strokeRenderer
        drawingRect = bounds
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Always return false so this view is never the hit-test target.
        // The StrokeGestureRecognizer lives on the *parent* view and captures
        // pencil touches there. Finger touches naturally reach the WKWebView.
        return false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if drawingRect == .zero {
            drawingRect = bounds
        }
    }

    func updateDrawingRect(_ rect: CGRect) {
        drawingRect = rect.intersection(bounds)
    }

    func updatePen(_ config: CanvasPenConfig) {
        penConfig = config
        let fingerDrawing = config.fingerDrawing ?? false
        strokeRecognizer.allowsFingerDrawing = fingerDrawing
        var touchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        if fingerDrawing {
            touchTypes.append(NSNumber(value: UITouch.TouchType.direct.rawValue))
        }
        strokeRecognizer.allowedTouchTypes = touchTypes
    }

    func clearStrokes() {
        clearHandoffs()
        activeEraserStroke = nil
        strokeStorage.clear()
        rebuildRenderer(mode: .dirty)
        strokeDelegate?.metalCanvasViewDidClear(self)
    }

    func undoStroke() {
        clearHandoffs()
        activeEraserStroke = nil
        guard strokeStorage.undo() else { return }
        rebuildRenderer(mode: .dirty)
    }

    func redoStroke() {
        clearHandoffs()
        activeEraserStroke = nil
        guard strokeStorage.redo() else { return }
        rebuildRenderer(mode: .dirty)
    }

    func exportedStrokes() -> [CanvasStroke] {
        strokeStorage.exportStrokes(in: drawingRect)
    }

    func exportImage(includeBackground: Bool) -> UIImage {
        strokeStorage.renderImage(in: bounds, includeBackground: includeBackground)
    }

    /// Export a committed stroke as a PNG fragment. `strokeId == nil` exports
    /// the most recent committed stroke. Passing an explicit id makes the
    /// per-stroke handoff to the webview race-free: when two strokes finish in
    /// quick succession, each strokeEnded handler can still fetch its own
    /// stroke instead of whichever happens to be the latest by then.
    func exportStrokeFragment(strokeId: String?) -> CanvasStrokeFragment? {
        guard let renderer = strokeRenderer else {
            return nil
        }
        let candidate: ActiveStroke?
        if let strokeId {
            candidate = strokeStorage.committedStrokes.last(where: { $0.id == strokeId })
        } else {
            candidate = strokeStorage.committedStrokes.last
        }
        guard let stroke = candidate else {
            return nil
        }

        let bounds = drawingRect
        guard let clippedBox = fragmentBounds(for: stroke) else { return nil }

        // Prefer the hand-over texture: the webview then receives exactly
        // the pixels the overlay is showing.
        let texture =
            handoffs.first(where: { $0.id == stroke.id })?.texture
            ?? renderer.renderStrokeToTexture(stroke, in: bounds, fragmentBounds: clippedBox)
        guard
            let texture,
            let image = renderer.image(from: texture),
            let data = image.pngData()?.base64EncodedString()
        else {
            return nil
        }

        let normalize = { (value: CGFloat, total: CGFloat) -> CGFloat in
            guard total > 0 else { return 0 }
            return value / total * 100.0
        }

        return CanvasStrokeFragment(
            strokeId: stroke.id,
            boundingBox: CanvasRect(
                x: normalize(clippedBox.origin.x - bounds.minX, bounds.width),
                y: normalize(clippedBox.origin.y - bounds.minY, bounds.height),
                width: normalize(clippedBox.width, bounds.width),
                height: normalize(clippedBox.height, bounds.height)
            ),
            imageData: data
        )
    }

    @objc private func handleStroke(_ recognizer: StrokeGestureRecognizer) {
        let touches = recognizer.coalescedTouches
        guard let touch = touches.last ?? recognizer.trackedTouch else { return }

        switch recognizer.state {
        case .began:
            let sample = makeSample(from: touch)
            guard drawingRect.contains(sample.location) else { return }
            if penConfig.tool == .erase {
                let stroke = ActiveEraserStroke(
                    id: UUID().uuidString,
                    points: [sample],
                    baseWidth: penConfig.width ?? CanvasPenConfig.default.width ?? 12.0,
                    pressureSensitivity: penConfig.pressureSensitivity ?? CanvasPenConfig.default
                        .pressureSensitivity ?? 0.25
                )
                activeEraserStroke = stroke
                rebuildRenderer(mode: .dirty)
                strokeDelegate?.metalCanvasView(self, didStartEraserStroke: stroke)
                strokeDelegate?.metalCanvasView(
                    self,
                    didSampleEraserStroke: stroke.id,
                    samples: [sample],
                    baseWidth: stroke.baseWidth,
                    pressureSensitivity: stroke.pressureSensitivity
                )
            } else {
                let strokeId = strokeStorage.beginStroke(sample: sample, pen: penConfig)
                rebuildRenderer(mode: .drawing)
                strokeDelegate?.metalCanvasView(self, didStartStroke: strokeId)
            }

        case .changed:
            let samples = touches.map(makeSample).filter { drawingRect.contains($0.location) }
            guard !samples.isEmpty else { return }
            if penConfig.tool == .erase {
                guard var stroke = activeEraserStroke else { return }
                stroke.points.append(contentsOf: samples)
                activeEraserStroke = stroke
                strokeDelegate?.metalCanvasView(
                    self,
                    didSampleEraserStroke: stroke.id,
                    samples: samples,
                    baseWidth: stroke.baseWidth,
                    pressureSensitivity: stroke.pressureSensitivity
                )
            } else {
                samples.forEach { strokeStorage.append(sample: $0) }
                rebuildRenderer(mode: .drawing)
            }

        case .ended:
            let samples = touches.map(makeSample).filter { drawingRect.contains($0.location) }
            if penConfig.tool == .erase {
                guard var stroke = activeEraserStroke else { return }
                if !samples.isEmpty {
                    stroke.points.append(contentsOf: samples)
                    activeEraserStroke = stroke
                    strokeDelegate?.metalCanvasView(
                        self,
                        didSampleEraserStroke: stroke.id,
                        samples: samples,
                        baseWidth: stroke.baseWidth,
                        pressureSensitivity: stroke.pressureSensitivity
                    )
                }
                activeEraserStroke = nil
                rebuildRenderer(mode: .dirty)
                strokeDelegate?.metalCanvasView(self, didEndEraserStroke: stroke.id, cancelled: false)
            } else {
                samples.forEach { strokeStorage.append(sample: $0) }
                if let stroke = strokeStorage.finishStroke() {
                    addHandoff(for: stroke)
                    rebuildRenderer(mode: .dirty)
                    strokeDelegate?.metalCanvasView(
                        self,
                        didEndStroke: strokeStorage.exportStrokes(in: drawingRect).last
                            ?? CanvasStroke(
                                id: stroke.id,
                                points: [],
                                color: stroke.color,
                                baseWidth: stroke.baseWidth,
                                boundingBox: CanvasRect(x: 0, y: 0, width: 0, height: 0)
                            ))
                }
            }

        case .cancelled, .failed:
            if let eraser = activeEraserStroke {
                activeEraserStroke = nil
                // Tell the webview to drop its erase preview — without this a
                // cancelled eraser stroke would leave a stale preview applied.
                strokeDelegate?.metalCanvasView(self, didEndEraserStroke: eraser.id, cancelled: true)
            }
            // Discard, don't commit: a cancelled stroke must neither reach the
            // webview nor occupy a slot in the undo stack (a committed ghost
            // stroke would desync native undo from the webview's op stack).
            strokeStorage.cancelStroke()
            rebuildRenderer(mode: .dirty)

        default:
            break
        }
    }

    private func makeSample(from touch: UITouch) -> CanvasStrokeSample {
        let roll: CGFloat
        if #available(iOS 17.5, *) {
            roll = touch.type == .pencil ? -touch.rollAngle : 0.0
        } else {
            roll = 0.0
        }
        return CanvasStrokeSample(
            location: touch.location(in: self),
            pressure: touch.maximumPossibleForce > 0
                ? touch.force / touch.maximumPossibleForce : 0.5,
            altitude: touch.altitudeAngle,
            azimuth: touch.azimuthAngle(in: self),
            roll: roll,
            timestamp: touch.timestamp
        )
    }

    private func rebuildRenderer(mode: StrokeRenderer.RenderMode) {
        let now = CACurrentMediaTime()
        let quads = handoffs.map { handoff in
            HandoffQuad(
                texture: handoff.texture,
                bounds: handoff.bounds,
                progress: Float(handoff.progress(at: now, duration: handoffFadeDuration))
            )
        }
        strokeRenderer?.update(
            committed: showsCommittedStrokes ? strokeStorage.committedStrokes : [],
            active: strokeStorage.activeStroke,
            handoffs: quads
        )
        strokeRenderer?.setRenderMode(mode)
    }

    // MARK: - Hand-over to the webview

    /// Fragment footprint of a committed stroke: padded bounds, clipped to
    /// the drawing rect and snapped outward to whole device pixels. The
    /// snap is what lets the hand-over texture be drawn texel-for-pixel,
    /// pixel-identical to the live rendering it replaces.
    private func fragmentBounds(for stroke: ActiveStroke) -> CGRect? {
        let box = strokeStorage.boundingBox(for: stroke)
        let padding = max(8.0, stroke.baseWidth * 3.0)
        let clipped = box.insetBy(dx: -padding, dy: -padding).intersection(drawingRect)
        guard clipped.width > 0, clipped.height > 0 else { return nil }
        let scale = UIScreen.main.scale
        let minX = floor(clipped.minX * scale) / scale
        let minY = floor(clipped.minY * scale) / scale
        let maxX = ceil(clipped.maxX * scale) / scale
        let maxY = ceil(clipped.maxY * scale) / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func addHandoff(for stroke: ActiveStroke) {
        guard
            let renderer = strokeRenderer,
            let bounds = fragmentBounds(for: stroke),
            let texture = renderer.renderStrokeToTexture(
                stroke, in: drawingRect, fragmentBounds: bounds)
        else {
            return
        }
        handoffs.append(
            HandoffStroke(
                id: stroke.id, texture: texture, bounds: bounds,
                createdAt: CACurrentMediaTime(), fadeStart: nil))
        ensureHandoffDisplayLink()
    }

    /// The webview has painted its copy and starts fading it in now.
    func beginHandoffFade(strokeId: String) {
        guard let index = handoffs.firstIndex(where: { $0.id == strokeId }) else { return }
        if handoffs[index].fadeStart == nil {
            handoffs[index].fadeStart = CACurrentMediaTime() + handoffFadeLead
        }
    }

    /// The webview's copy is at full opacity: drop ours at once.
    func endHandoffFade(strokeId: String) {
        handoffs.removeAll { $0.id == strokeId }
        rebuildRenderer(mode: .dirty)
        if handoffs.isEmpty {
            handoffDisplayLink?.invalidate()
            handoffDisplayLink = nil
        }
    }

    private func ensureHandoffDisplayLink() {
        guard handoffDisplayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(handleHandoffFrame))
        if #available(iOS 15.0, *) {
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: 30, maximum: 120, preferred: 120)
        } else {
            displayLink.preferredFramesPerSecond = 60
        }
        displayLink.add(to: .main, forMode: .common)
        handoffDisplayLink = displayLink
    }

    @objc private func handleHandoffFrame(_ displayLink: CADisplayLink) {
        let now = displayLink.timestamp
        var fading = false
        for index in handoffs.indices {
            if handoffs[index].fadeStart == nil,
                now - handoffs[index].createdAt > handoffFadeTimeout
            {
                handoffs[index].fadeStart = now
            }
            if handoffs[index].fadeStart != nil {
                fading = true
            }
        }
        handoffs.removeAll { $0.progress(at: now, duration: handoffFadeDuration) >= 1.0 }

        if handoffs.isEmpty {
            displayLink.invalidate()
            handoffDisplayLink = nil
            rebuildRenderer(mode: .dirty)
            return
        }
        // Only redraw while something actually changes; holding copies cost
        // nothing per frame.
        if fading || strokeStorage.activeStroke == nil {
            rebuildRenderer(mode: .dirty)
        }
    }

    private func clearHandoffs() {
        handoffDisplayLink?.invalidate()
        handoffDisplayLink = nil
        handoffs.removeAll()
    }
}
