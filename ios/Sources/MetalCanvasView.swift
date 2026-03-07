import MetalKit
import UIKit

protocol MetalCanvasViewDelegate: AnyObject {
    func metalCanvasView(_ view: MetalCanvasView, didStartStroke strokeId: String)
    func metalCanvasView(_ view: MetalCanvasView, didEndStroke stroke: CanvasStroke)
    func metalCanvasViewDidClear(_ view: MetalCanvasView)
}

final class MetalCanvasView: MTKView {
    weak var strokeDelegate: MetalCanvasViewDelegate?
    var currentDrawingRect: CGRect { drawingRect }

    private let strokeStorage = StrokeStorage()
    private var penConfig = CanvasPenConfig.default
    private var drawingRect: CGRect = .zero
    private var showsCommittedStrokes = false
    private lazy var strokeRecognizer = StrokeGestureRecognizer(target: self, action: #selector(handleStroke(_:)))
    private var strokeRenderer: StrokeRenderer?
    private var handoffStroke: ActiveStroke?
    private var handoffOpacity: CGFloat = 1.0
    private var handoffDisplayLink: CADisplayLink?
    private var handoffFadeStartTime: CFTimeInterval?
    private let handoffFadeDuration: CFTimeInterval = 0.12

    init(frame: CGRect) {
        super.init(frame: frame, device: MTLCreateSystemDefaultDevice())
        isOpaque = false
        layer.isOpaque = false
        backgroundColor = .clear
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = false
        preferredFramesPerSecond = 120
        enableSetNeedsDisplay = true
        isPaused = true
        isUserInteractionEnabled = false
        isMultipleTouchEnabled = true
        strokeRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]

        addGestureRecognizer(strokeRecognizer)
        strokeRenderer = StrokeRenderer(metalView: self)
        delegate = strokeRenderer
        drawingRect = bounds
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled && !isHidden && alpha > 0.01 else {
            return false
        }

        return drawingRect.contains(point)
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
    }

    func clearStrokes() {
        clearHandoffStroke()
        strokeStorage.clear()
        rebuildRenderer(mode: .dirty)
        strokeDelegate?.metalCanvasViewDidClear(self)
    }

    func undoStroke() {
        clearHandoffStroke()
        guard strokeStorage.undo() else { return }
        rebuildRenderer(mode: .dirty)
    }

    func redoStroke() {
        clearHandoffStroke()
        guard strokeStorage.redo() else { return }
        rebuildRenderer(mode: .dirty)
    }

    func exportedStrokes() -> [CanvasStroke] {
        strokeStorage.exportStrokes(in: drawingRect)
    }

    func exportImage(includeBackground: Bool) -> UIImage {
        strokeStorage.renderImage(in: bounds, includeBackground: includeBackground)
    }

    func exportLatestStrokeFragment() -> CanvasStrokeFragment? {
        strokeStorage.lastStrokeFragment(in: drawingRect)
    }

    @objc private func handleStroke(_ recognizer: StrokeGestureRecognizer) {
        let touches = recognizer.coalescedTouches
        guard let touch = touches.last ?? recognizer.trackedTouch else { return }

        switch recognizer.state {
        case .began:
            clearHandoffStroke()
            let sample = makeSample(from: touch)
            guard drawingRect.contains(sample.location) else { return }
            let strokeId = strokeStorage.beginStroke(sample: sample, pen: penConfig)
            rebuildRenderer(mode: .drawing)
            strokeDelegate?.metalCanvasView(self, didStartStroke: strokeId)

        case .changed:
            let samples = touches.map(makeSample).filter { drawingRect.contains($0.location) }
            guard !samples.isEmpty else { return }
            samples.forEach { strokeStorage.append(sample: $0) }
            rebuildRenderer(mode: .drawing)

        case .ended:
            let samples = touches.map(makeSample).filter { drawingRect.contains($0.location) }
            samples.forEach { strokeStorage.append(sample: $0) }
            if let stroke = strokeStorage.finishStroke() {
                handoffStroke = stroke
                handoffOpacity = 1.0
                rebuildRenderer(mode: .drawing)
                startHandoffFade()
                strokeDelegate?.metalCanvasView(self, didEndStroke: strokeStorage.exportStrokes(in: drawingRect).last ?? CanvasStroke(
                    id: stroke.id,
                    points: [],
                    color: stroke.color,
                    baseWidth: stroke.baseWidth,
                    boundingBox: CanvasRect(x: 0, y: 0, width: 0, height: 0)
                ))
            }

        case .cancelled, .failed:
            clearHandoffStroke()
            _ = strokeStorage.finishStroke()
            rebuildRenderer(mode: .dirty)

        default:
            break
        }
    }

    private func makeSample(from touch: UITouch) -> CanvasStrokeSample {
        CanvasStrokeSample(
            location: touch.location(in: self),
            pressure: touch.maximumPossibleForce > 0 ? touch.force / touch.maximumPossibleForce : 0.5,
            altitude: touch.altitudeAngle,
            azimuth: touch.azimuthAngle(in: self),
            timestamp: touch.timestamp
        )
    }

    private func rebuildRenderer(mode: StrokeRenderer.RenderMode) {
        let fadingStroke = handoffStroke.map { stroke in
            ActiveStroke(
                id: stroke.id,
                points: stroke.points,
                color: stroke.color,
                baseWidth: stroke.baseWidth,
                opacity: stroke.opacity * handoffOpacity,
                pressureSensitivity: stroke.pressureSensitivity
            )
        }
        strokeRenderer?.update(
            committed: showsCommittedStrokes ? strokeStorage.committedStrokes : [],
            active: strokeStorage.activeStroke ?? fadingStroke
        )
        strokeRenderer?.setRenderMode(mode)
    }

    private func startHandoffFade() {
        handoffDisplayLink?.invalidate()
        handoffFadeStartTime = CACurrentMediaTime()
        let displayLink = CADisplayLink(target: self, selector: #selector(handleHandoffFrame))
        if #available(iOS 15.0, *) {
            displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        } else {
            displayLink.preferredFramesPerSecond = 60
        }
        displayLink.add(to: .main, forMode: .common)
        handoffDisplayLink = displayLink
    }

    @objc private func handleHandoffFrame(_ displayLink: CADisplayLink) {
        guard handoffStroke != nil else {
            clearHandoffStroke()
            rebuildRenderer(mode: .dirty)
            return
        }

        let startTime = handoffFadeStartTime ?? displayLink.timestamp
        let progress = min(1.0, max(0.0, (displayLink.timestamp - startTime) / handoffFadeDuration))
        handoffOpacity = CGFloat(1.0 - progress)
        rebuildRenderer(mode: progress >= 1.0 ? .dirty : .drawing)

        if progress >= 1.0 {
            clearHandoffStroke()
        }
    }

    private func clearHandoffStroke() {
        handoffDisplayLink?.invalidate()
        handoffDisplayLink = nil
        handoffFadeStartTime = nil
        handoffStroke = nil
        handoffOpacity = 1.0
    }
}
