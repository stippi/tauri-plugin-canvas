import MetalKit
import UIKit

final class MetalCanvasView: MTKView {
    private let previewLayer = CALayer()

    init(frame: CGRect) {
        super.init(frame: frame, device: MTLCreateSystemDefaultDevice())
        isOpaque = false
        layer.isOpaque = false
        backgroundColor = .clear
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        framebufferOnly = false
        isPaused = true
        enableSetNeedsDisplay = true
        isUserInteractionEnabled = false

        previewLayer.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.18).cgColor
        previewLayer.cornerRadius = 12
        previewLayer.borderWidth = 1
        previewLayer.borderColor = UIColor.systemBlue.withAlphaComponent(0.45).cgColor
        layer.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds.insetBy(dx: 2, dy: 2)
    }

    func clearPreviewTint() {
        previewLayer.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.18).cgColor
    }
}
