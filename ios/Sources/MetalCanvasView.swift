import MetalKit
import UIKit

protocol MetalCanvasViewDelegate: AnyObject {
    func metalCanvasView(_ view: MetalCanvasView, didStartStroke strokeId: String)
    func metalCanvasView(_ view: MetalCanvasView, didEndStroke stroke: CanvasStroke)
    func metalCanvasViewDidClear(_ view: MetalCanvasView)
}

final class MetalCanvasView: MTKView {
    weak var strokeDelegate: MetalCanvasViewDelegate?

    private let strokeStorage = StrokeStorage()
    private var penConfig = CanvasPenConfig.default
    private lazy var strokeRecognizer = StrokeGestureRecognizer(target: self, action: #selector(handleStroke(_:)))
    private var strokeRenderer: StrokeRenderer?

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

        addGestureRecognizer(strokeRecognizer)
        strokeRenderer = StrokeRenderer(metalView: self)
        delegate = strokeRenderer
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard isUserInteractionEnabled else { return false }
        guard let touch = event?.allTouches?.first else { return false }
        return touch.type == .pencil
    }

    func updatePen(_ config: CanvasPenConfig) {
        penConfig = config
    }

    func clearStrokes() {
        strokeStorage.clear()
        rebuildRenderer(mode: .dirty)
        strokeDelegate?.metalCanvasViewDidClear(self)
    }

    func undoStroke() {
        guard strokeStorage.undo() else { return }
        rebuildRenderer(mode: .dirty)
    }

    func redoStroke() {
        guard strokeStorage.redo() else { return }
        rebuildRenderer(mode: .dirty)
    }

    func exportedStrokes() -> [CanvasStroke] {
        strokeStorage.exportStrokes(in: bounds)
    }

    func exportImage(includeBackground: Bool) -> UIImage {
        strokeStorage.renderImage(in: bounds, includeBackground: includeBackground)
    }

    @objc private func handleStroke(_ recognizer: StrokeGestureRecognizer) {
        let touches = recognizer.coalescedTouches
        guard let touch = touches.last ?? recognizer.trackedTouch else { return }

        switch recognizer.state {
        case .began:
            let sample = makeSample(from: touch)
            let strokeId = strokeStorage.beginStroke(sample: sample, pen: penConfig)
            rebuildRenderer(mode: .drawing)
            strokeDelegate?.metalCanvasView(self, didStartStroke: strokeId)

        case .changed:
            touches.forEach { strokeStorage.append(sample: makeSample(from: $0)) }
            rebuildRenderer(mode: .drawing)

        case .ended:
            touches.forEach { strokeStorage.append(sample: makeSample(from: $0)) }
            if let stroke = strokeStorage.finishStroke() {
                rebuildRenderer(mode: .dirty)
                strokeDelegate?.metalCanvasView(self, didEndStroke: strokeStorage.exportStrokes(in: bounds).last ?? CanvasStroke(
                    id: stroke.id,
                    points: [],
                    color: stroke.color,
                    baseWidth: stroke.baseWidth,
                    boundingBox: CanvasRect(x: 0, y: 0, width: 0, height: 0)
                ))
            }

        case .cancelled, .failed:
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
        strokeRenderer?.update(committed: strokeStorage.committedStrokes, active: strokeStorage.activeStroke)
        strokeRenderer?.setRenderMode(mode)
    }
}
