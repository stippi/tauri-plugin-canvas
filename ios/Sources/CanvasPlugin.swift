import CoreGraphics
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

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self), value == "fullscreen" {
            self = .fullscreen
            return
        }

        let object = try container.decode([String: String].self)
        if let bottom = object["bottom"] {
            self = .bottom(bottom)
        } else if let top = object["top"] {
            self = .top(top)
        } else {
            let region = try container.decode([String: NormalizedRect].self)
            self = .region(region["region"] ?? .init(x: 0, y: 0, width: 100, height: 100))
        }
    }
}

private struct NormalizedRect: Codable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

class CanvasPlugin: Plugin {
    private weak var webview: WKWebView?
    private weak var parentView: UIView?
    private var overlayView: MetalCanvasView?

    @objc override func load(webview: WKWebView) {
        self.webview = webview
        self.parentView = webview.superview
        setupOverlayIfNeeded(over: webview)
    }

    @objc public func isAvailable(_ invoke: Invoke) throws {
        invoke.resolve(AvailabilityResponse(available: true, reason: nil))
    }

    @objc public func showCanvas(_ invoke: Invoke) throws {
        let args = try invoke.parseArgs(CanvasConfig.self)
        DispatchQueue.main.async {
            self.setupOverlayIfNeeded(over: self.webview)
            self.overlayView?.isHidden = false
            self.applyPlacement(args.placement ?? .fullscreen)
        }
        invoke.resolve()
    }

    @objc public func hideCanvas(_ invoke: Invoke) throws {
        DispatchQueue.main.async {
            self.overlayView?.isHidden = true
            self.overlayView?.isUserInteractionEnabled = false
        }
        invoke.resolve()
    }

    @objc public func activatePen(_ invoke: Invoke) throws {
        DispatchQueue.main.async {
            self.overlayView?.isUserInteractionEnabled = true
        }
        invoke.resolve()
    }

    @objc public func deactivatePen(_ invoke: Invoke) throws {
        DispatchQueue.main.async {
            self.overlayView?.isUserInteractionEnabled = false
        }
        invoke.resolve()
    }

    @objc public func clear(_ invoke: Invoke) throws {
        DispatchQueue.main.async {
            self.overlayView?.clearPreviewTint()
        }
        invoke.resolve()
    }

    @objc public func undo(_ invoke: Invoke) throws {
        invoke.resolve()
    }

    @objc public func redo(_ invoke: Invoke) throws {
        invoke.resolve()
    }

    @objc public func getStrokes(_ invoke: Invoke) throws {
        invoke.resolve([])
    }

    @objc public func exportImage(_ invoke: Invoke) throws {
        invoke.resolve("")
    }

    private func setupOverlayIfNeeded(over webview: WKWebView?) {
        guard overlayView == nil, let webview, let parentView = webview.superview else {
            return
        }

        let overlay = MetalCanvasView(frame: webview.frame)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.isHidden = true
        parentView.addSubview(overlay)
        overlay.frame = webview.frame
        parentView.bringSubviewToFront(overlay)
        self.overlayView = overlay
        self.parentView = parentView
    }

    private func applyPlacement(_ placement: Placement) {
        guard let overlay = overlayView, let parentView = parentView else { return }
        let bounds = parentView.bounds

        switch placement {
        case .fullscreen:
            overlay.frame = bounds
        case .bottom(let bottom):
            let fraction = max(0.0, min(1.0, parsePercent(bottom)))
            overlay.frame = CGRect(
                x: bounds.minX,
                y: bounds.maxY - bounds.height * fraction,
                width: bounds.width,
                height: bounds.height * fraction
            )
        case .top(let top):
            let fraction = max(0.0, min(1.0, parsePercent(top)))
            overlay.frame = CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: bounds.height * fraction
            )
        case .region(let region):
            overlay.frame = CGRect(
                x: bounds.width * region.x / 100.0,
                y: bounds.height * region.y / 100.0,
                width: bounds.width * region.width / 100.0,
                height: bounds.height * region.height / 100.0
            )
        }
    }

    private func parsePercent(_ value: String) -> CGFloat {
        let trimmed = value.replacingOccurrences(of: "%", with: "")
        guard let number = Double(trimmed) else { return 1.0 }
        return CGFloat(number / 100.0)
    }
}
