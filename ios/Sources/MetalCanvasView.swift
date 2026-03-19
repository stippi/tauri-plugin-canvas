import MetalKit
import UIKit

protocol MetalCanvasViewDelegate: AnyObject {
    func metalCanvasView(_ view: MetalCanvasView, didStartStroke strokeId: String)
    func metalCanvasView(_ view: MetalCanvasView, didEndStroke stroke: CanvasStroke)
    func metalCanvasView(_ view: MetalCanvasView, didStartEraserStroke stroke: ActiveEraserStroke)
    func metalCanvasView(
        _ view: MetalCanvasView, didSampleEraserStroke strokeId: String,
        samples: [CanvasStrokeSample], baseWidth: CGFloat, pressureSensitivity: CGFloat)
    func metalCanvasView(_ view: MetalCanvasView, didEndEraserStroke strokeId: String)
    func metalCanvasViewDidClear(_ view: MetalCanvasView)
}

final class MetalCanvasView: MTKView {
    weak var strokeDelegate: MetalCanvasViewDelegate?
    var currentDrawingRect: CGRect { drawingRect }

    private let strokeStorage = StrokeStorage()
    private var penConfig = CanvasPenConfig.default
    private var drawingRect: CGRect = .zero
    private var showsCommittedStrokes = false
    private lazy var strokeRecognizer = StrokeGestureRecognizer(
        target: self, action: #selector(handleStroke(_:)))
    private var strokeRenderer: StrokeRenderer?
    private var handoffStroke: ActiveStroke?
    private var activeEraserStroke: ActiveEraserStroke?
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
        if let device, device.supportsTextureSampleCount(4) {
            sampleCount = 4
        }
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
        activeEraserStroke = nil
        strokeStorage.clear()
        rebuildRenderer(mode: .dirty)
        strokeDelegate?.metalCanvasViewDidClear(self)
    }

    func undoStroke() {
        clearHandoffStroke()
        activeEraserStroke = nil
        guard strokeStorage.undo() else { return }
        rebuildRenderer(mode: .dirty)
    }

    func redoStroke() {
        clearHandoffStroke()
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

    func exportLatestStrokeFragment() -> CanvasStrokeFragment? {
        guard let renderer = strokeRenderer,
            let stroke = strokeStorage.committedStrokes.last
        else {
            return nil
        }

        let bounds = drawingRect
        let box = strokeStorage.boundingBox(for: stroke)
        let padding = max(8.0, stroke.baseWidth * 3.0)
        let clippedBox = box.insetBy(dx: -padding, dy: -padding).intersection(bounds)
        guard clippedBox.width > 0, clippedBox.height > 0 else { return nil }

        guard
            let image = renderer.renderStrokeToImage(
                stroke, in: bounds, fragmentBounds: clippedBox),
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
            clearHandoffStroke()
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
                strokeDelegate?.metalCanvasView(self, didEndEraserStroke: stroke.id)
            } else {
                samples.forEach { strokeStorage.append(sample: $0) }
                if let stroke = strokeStorage.finishStroke() {
                    handoffStroke = stroke
                    handoffOpacity = 1.0
                    rebuildRenderer(mode: .drawing)
                    startHandoffFade()
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
            clearHandoffStroke()
            activeEraserStroke = nil
            if penConfig.tool != .erase {
                _ = strokeStorage.finishStroke()
            }
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
        let fadingStroke = handoffStroke.map { stroke in
            ActiveStroke(
                id: stroke.id,
                points: stroke.points,
                style: stroke.style,
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
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: 30, maximum: 120, preferred: 120)
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
