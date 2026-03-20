import Foundation
import MetalKit
import Tauri
import UIKit
import WebKit

private struct AvailabilityResponse: Encodable {
    let available: Bool
    let reason: String?
}

private struct CanvasConfig: Decodable {
    let placement: Placement?
}

private enum Placement: Decodable {
    case fullscreen
    case bottom(String)
    case top(String)
    case region(NormalizedRect)
    case viewport(NormalizedRect)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self), value == "fullscreen" {
            self = .fullscreen
            return
        }

        if let object = try? container.decode([String: String].self) {
            if let bottom = object["bottom"] {
                self = .bottom(bottom)
                return
            }
            if let top = object["top"] {
                self = .top(top)
                return
            }
        }

        let object = try container.decode([String: NormalizedRect].self)
        if let viewport = object["viewport"] {
            self = .viewport(viewport)
            return
        }
        self = .region(object["region"] ?? NormalizedRect(x: 0, y: 0, width: 100, height: 100))
    }
}

private struct NormalizedRect: Codable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

private struct ExportOptions: Decodable {
    let includeBackground: Bool?
}

class CanvasPlugin: Plugin {
    private weak var webview: WKWebView?
    private weak var parentView: UIView?
    private var overlayView: MetalCanvasView?
    private var lastLayoutSnapshot = "layout snapshot unavailable"

    @objc override func load(webview: WKWebView) {
        self.webview = webview
        self.parentView = webview.superview

        // Prevent the scroll view from automatically adding safe area insets
        // to its content. With viewport-fit=cover in the HTML meta tag, CSS
        // env(safe-area-inset-*) already provides the correct values. The
        // default .automatic behaviour would double-compensate, causing the
        // bottom toolbar padding to be too large and inconsistent on rotation.
        webview.scrollView.contentInsetAdjustmentBehavior = .never

        setupOverlayIfNeeded(over: webview)
        updateLayoutSnapshot(label: "load")
    }

    @objc public func isAvailable(_ invoke: Invoke) throws {
        let available = MTLCreateSystemDefaultDevice() != nil
        invoke.resolve(
            AvailabilityResponse(
                available: available,
                reason: available ? nil : "Metal is not available on this device"
            ))
    }

    @objc public func showCanvas(_ invoke: Invoke) throws {
        let args = try invoke.parseArgs(CanvasConfig.self)
        DispatchQueue.main.async {
            self.setupOverlayIfNeeded(over: self.webview)
            self.overlayView?.isHidden = false
            self.applyPlacement(args.placement ?? .fullscreen)
            self.emitDebug(self.lastLayoutSnapshot)
        }
        invoke.resolve()
    }

    @objc public func hideCanvas(_ invoke: Invoke) throws {
        DispatchQueue.main.async {
            self.overlayView?.isHidden = true
            self.overlayView?.isUserInteractionEnabled = false
            self.overlayView?.strokeRecognizer.isEnabled = false
        }
        invoke.resolve()
    }

    @objc public func activatePen(_ invoke: Invoke) throws {
        let args = try invoke.parseArgs(CanvasPenConfig.self)
        DispatchQueue.main.async {
            self.setupOverlayIfNeeded(over: self.webview)
            self.overlayView?.updatePen(args)
            self.overlayView?.isHidden = false
            self.overlayView?.isUserInteractionEnabled = true
            self.overlayView?.strokeRecognizer.isEnabled = true
            self.updateLayoutSnapshot(label: "activatePen")
            self.emitDebug(self.lastLayoutSnapshot)
        }
        invoke.resolve()
    }

    @objc public func deactivatePen(_ invoke: Invoke) throws {
        DispatchQueue.main.async {
            self.overlayView?.isUserInteractionEnabled = false
            self.overlayView?.strokeRecognizer.isEnabled = false
        }
        invoke.resolve()
    }

    @objc public func clear(_ invoke: Invoke) throws {
        DispatchQueue.main.async {
            self.overlayView?.clearStrokes()
        }
        invoke.resolve()
    }

    @objc public func undo(_ invoke: Invoke) throws {
        DispatchQueue.main.async {
            self.overlayView?.undoStroke()
        }
        invoke.resolve()
    }

    @objc public func redo(_ invoke: Invoke) throws {
        DispatchQueue.main.async {
            self.overlayView?.redoStroke()
        }
        invoke.resolve()
    }

    @objc public func getStrokes(_ invoke: Invoke) throws {
        invoke.resolve(overlayView?.exportedStrokes() ?? [])
    }

    @objc public func exportImage(_ invoke: Invoke) throws {
        let args = try invoke.parseArgs(ExportOptions.self)
        let image = overlayView?.exportImage(includeBackground: args.includeBackground ?? false)
        let pngData = image?.pngData()?.base64EncodedString() ?? ""
        invoke.resolve(pngData)
    }

    @objc public func exportLatestStrokeFragment(_ invoke: Invoke) throws {
        invoke.resolve(overlayView?.exportLatestStrokeFragment())
    }

    private func emitEvent(_ eventName: String, data: JSObject) {
        DispatchQueue.main.async { [weak self] in
            self?.trigger(eventName, data: data)
        }
    }

    private func emitClearEvent(_ eventName: String) {
        DispatchQueue.main.async { [weak self] in
            self?.trigger(eventName, data: [:])
        }
    }

    private func emitDebug(_ message: String) {
        emitEvent(
            "debug",
            data: [
                "source": "ios-canvas",
                "message": message,
            ] as JSObject)
    }

    private func setupOverlayIfNeeded(over webview: WKWebView?) {
        guard overlayView == nil, let webview, let parentView = webview.superview else {
            return
        }

        let overlay = MetalCanvasView(frame: parentView.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isHidden = true
        overlay.strokeDelegate = self
        parentView.addSubview(overlay)
        overlay.frame = parentView.bounds
        parentView.bringSubviewToFront(overlay)

        // Install the pencil gesture recognizer on the *parent* view (not the
        // overlay). Because the overlay's point(inside:with:) always returns
        // false, attaching the recognizer there would starve it of events.
        // On the parent view the recognizer receives all touches; it only
        // tracks .pencil touches so finger events pass through to WKWebView
        // undisturbed, preserving two-finger zoom/pan.
        parentView.addGestureRecognizer(overlay.strokeRecognizer)

        self.overlayView = overlay
        self.parentView = parentView
        updateLayoutSnapshot(label: "setupOverlay")
    }

    private func applyPlacement(_ placement: Placement) {
        guard let overlay = overlayView, let parentView = parentView else { return }
        overlay.frame = parentView.bounds
        let usableBounds = overlay.bounds
        let drawingRect: CGRect

        switch placement {
        case .fullscreen:
            drawingRect = usableBounds
        case .bottom(let bottom):
            let fraction = max(0.0, min(1.0, parsePercent(bottom)))
            drawingRect = CGRect(
                x: usableBounds.minX,
                y: usableBounds.maxY - usableBounds.height * fraction,
                width: usableBounds.width,
                height: usableBounds.height * fraction
            )
        case .top(let top):
            let fraction = max(0.0, min(1.0, parsePercent(top)))
            drawingRect = CGRect(
                x: usableBounds.minX,
                y: usableBounds.minY,
                width: usableBounds.width,
                height: usableBounds.height * fraction
            )
        case .region(let region):
            drawingRect = CGRect(
                x: usableBounds.minX + usableBounds.width * region.x / 100.0,
                y: usableBounds.minY + usableBounds.height * region.y / 100.0,
                width: usableBounds.width * region.width / 100.0,
                height: usableBounds.height * region.height / 100.0
            )
        case .viewport(let viewport):
            drawingRect = CGRect(
                x: viewport.x,
                y: viewport.y,
                width: viewport.width,
                height: viewport.height
            )
        }

        overlay.updateDrawingRect(drawingRect.intersection(overlay.bounds))
        updateLayoutSnapshot(label: "applyPlacement")
    }

    private func parsePercent(_ value: String) -> CGFloat {
        let trimmed = value.replacingOccurrences(of: "%", with: "")
        guard let number = Double(trimmed) else { return 1.0 }
        return CGFloat(number / 100.0)
    }

    private func updateLayoutSnapshot(label: String) {
        guard let webview = webview, let parentView = parentView, let overlay = overlayView else {
            lastLayoutSnapshot =
                "[\(label)] missing views webview=\(webview != nil) parent=\(parentView != nil) overlay=\(overlayView != nil)"
            return
        }

        let webviewInParent = webview.convert(webview.bounds, to: parentView)
        let overlayInParent = overlay.convert(overlay.bounds, to: parentView)
        let parentInWindow = parentView.convert(parentView.bounds, to: nil)
        let windowBounds = parentView.window?.bounds ?? .zero
        let windowSafeArea = parentView.window?.safeAreaInsets ?? .zero

        lastLayoutSnapshot = [
            "[\(label)]",
            "parent.bounds=\(format(parentView.bounds))",
            "parent.safeArea=\(format(windowSafeArea: parentView.safeAreaInsets))",
            "parent.inWindow=\(format(parentInWindow))",
            "window.bounds=\(format(windowBounds))",
            "window.safeArea=\(format(windowSafeArea: windowSafeArea))",
            "webview.frame=\(format(webview.frame))",
            "webview.bounds=\(format(webview.bounds))",
            "webview.inParent=\(format(webviewInParent))",
            "scroll.contentInset=\(format(edgeInsets: webview.scrollView.contentInset))",
            "scroll.adjustedInset=\(format(edgeInsets: webview.scrollView.adjustedContentInset))",
            "overlay.frame=\(format(overlay.frame))",
            "overlay.bounds=\(format(overlay.bounds))",
            "overlay.inParent=\(format(overlayInParent))",
            "drawingRect=\(format(overlay.currentDrawingRect))",
        ].joined(separator: " ")
    }

    private func format(_ rect: CGRect) -> String {
        String(
            format: "{x:%.1f,y:%.1f,w:%.1f,h:%.1f}",
            rect.origin.x,
            rect.origin.y,
            rect.size.width,
            rect.size.height
        )
    }

    private func format(edgeInsets: UIEdgeInsets) -> String {
        String(
            format: "{t:%.1f,l:%.1f,b:%.1f,r:%.1f}",
            edgeInsets.top,
            edgeInsets.left,
            edgeInsets.bottom,
            edgeInsets.right
        )
    }

    private func format(windowSafeArea: UIEdgeInsets) -> String {
        format(edgeInsets: windowSafeArea)
    }
}

extension CanvasPlugin: MetalCanvasViewDelegate {
    func metalCanvasView(_ view: MetalCanvasView, didStartStroke strokeId: String) {
        emitDebug("didStartStroke \(strokeId)")
        emitEvent(
            "strokeStarted",
            data: [
                "strokeId": strokeId
            ] as JSObject)
    }

    func metalCanvasView(_ view: MetalCanvasView, didEndStroke stroke: CanvasStroke) {
        let points: JSArray = stroke.points.map { point in
            [
                "x": point.x,
                "y": point.y,
                "pressure": point.pressure,
                "altitude": point.altitude,
                "azimuth": point.azimuth,
                "timestamp": point.timestamp,
            ] as JSObject
        }
        let boundingBox: JSObject = [
            "x": Double(stroke.boundingBox.x),
            "y": Double(stroke.boundingBox.y),
            "width": Double(stroke.boundingBox.width),
            "height": Double(stroke.boundingBox.height),
        ]
        emitDebug("didEndStroke \(stroke.id) points=\(stroke.points.count)")
        emitEvent(
            "strokeEnded",
            data: [
                "strokeId": stroke.id,
                "points": points,
                "boundingBox": boundingBox,
            ] as JSObject
        )
    }

    func metalCanvasView(_ view: MetalCanvasView, didStartEraserStroke stroke: ActiveEraserStroke) {
        emitDebug("didStartEraserStroke \(stroke.id)")
        emitEvent(
            "eraserStrokeStarted",
            data: [
                "strokeId": stroke.id,
                "baseWidth": Double(stroke.baseWidth),
                "pressureSensitivity": Double(stroke.pressureSensitivity),
            ] as JSObject
        )
    }

    func metalCanvasView(
        _ view: MetalCanvasView,
        didSampleEraserStroke strokeId: String,
        samples: [CanvasStrokeSample],
        baseWidth: CGFloat,
        pressureSensitivity: CGFloat
    ) {
        let points: JSArray = samples.map { sample in
            let normalized = normalize(sample: sample, within: view.currentDrawingRect)
            return [
                "x": Double(normalized.x),
                "y": Double(normalized.y),
                "pressure": Double(normalized.pressure),
                "altitude": Double(normalized.altitude),
                "azimuth": Double(normalized.azimuth),
                "timestamp": normalized.timestamp,
            ] as JSObject
        }
        emitEvent(
            "eraserStrokeSampled",
            data: [
                "strokeId": strokeId,
                "baseWidth": Double(baseWidth),
                "pressureSensitivity": Double(pressureSensitivity),
                "points": points,
            ] as JSObject
        )
    }

    func metalCanvasView(_ view: MetalCanvasView, didEndEraserStroke strokeId: String) {
        emitDebug("didEndEraserStroke \(strokeId)")
        emitEvent(
            "eraserStrokeEnded",
            data: [
                "strokeId": strokeId
            ] as JSObject
        )
    }

    func metalCanvasViewDidClear(_ view: MetalCanvasView) {
        emitDebug("strokesCleared")
        emitClearEvent("strokesCleared")
    }

    private func normalize(sample: CanvasStrokeSample, within bounds: CGRect) -> CanvasPoint {
        let width = max(bounds.width, 1.0)
        let height = max(bounds.height, 1.0)
        return CanvasPoint(
            x: (sample.location.x - bounds.minX) / width * 100.0,
            y: (sample.location.y - bounds.minY) / height * 100.0,
            pressure: max(0.0, min(1.0, sample.pressure)),
            altitude: sample.altitude,
            azimuth: sample.azimuth,
            timestamp: sample.timestamp
        )
    }
}

extension UIColor {
    convenience init?(hex: String) {
        var value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if value.count == 6 {
            value.append("FF")
        }
        guard value.count == 8, let number = UInt64(value, radix: 16) else { return nil }
        self.init(
            red: CGFloat((number >> 24) & 0xff) / 255.0,
            green: CGFloat((number >> 16) & 0xff) / 255.0,
            blue: CGFloat((number >> 8) & 0xff) / 255.0,
            alpha: CGFloat(number & 0xff) / 255.0
        )
    }
}

@_cdecl("init_plugin_canvas")
func initPlugin() -> Plugin {
    CanvasPlugin()
}
