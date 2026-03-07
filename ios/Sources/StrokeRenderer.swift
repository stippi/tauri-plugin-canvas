import MetalKit
import simd
import UIKit

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
  float2 position;
  float4 color;
};

struct VertexOut {
  float4 position [[position]];
  float4 color;
};

vertex VertexOut stroke_vertex(const device VertexIn* vertices [[buffer(0)]], uint id [[vertex_id]]) {
  VertexOut out;
  out.position = float4(vertices[id].position, 0.0, 1.0);
  out.color = vertices[id].color;
  return out;
}

fragment float4 stroke_fragment(VertexOut in [[stage_in]]) {
  return in.color;
}
"""

struct StrokeRenderVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

final class StrokeRenderer: NSObject, MTKViewDelegate {
    private weak var metalView: MTKView?
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var committedVertexBuffer: MTLBuffer?
    private var activeVertexBuffer: MTLBuffer?
    private var committedVertexCount = 0
    private var activeVertexCount = 0

    enum RenderMode {
        case idle
        case drawing
        case dirty
    }

    private(set) var renderMode: RenderMode = .idle

    init?(metalView: MTKView) {
        guard
            let device = metalView.device,
            let commandQueue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(source: shaderSource, options: nil),
            let vertexFunction = library.makeFunction(name: "stroke_vertex"),
            let fragmentFunction = library.makeFunction(name: "stroke_fragment")
        else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }

        self.metalView = metalView
        self.commandQueue = commandQueue
        self.pipelineState = pipelineState
        super.init()
    }

    func update(committed: [ActiveStroke], active: ActiveStroke?) {
        guard let device = metalView?.device else { return }
        let committedVertices = committed.flatMap(makeVertices(for:))
        committedVertexCount = committedVertices.count
        if !committedVertices.isEmpty {
            committedVertexBuffer = device.makeBuffer(
                bytes: committedVertices,
                length: MemoryLayout<StrokeRenderVertex>.stride * committedVertices.count
            )
        } else {
            committedVertexBuffer = nil
        }

        if let active {
            let activeVertices = makeVertices(for: active)
            activeVertexCount = activeVertices.count
            if !activeVertices.isEmpty {
                activeVertexBuffer = device.makeBuffer(
                    bytes: activeVertices,
                    length: MemoryLayout<StrokeRenderVertex>.stride * activeVertices.count
                )
            } else {
                activeVertexBuffer = nil
            }
        } else {
            activeVertexCount = 0
            activeVertexBuffer = nil
        }
    }

    func setRenderMode(_ mode: RenderMode) {
        renderMode = mode
        switch mode {
        case .idle:
            metalView?.isPaused = true
        case .drawing:
            metalView?.isPaused = false
        case .dirty:
            metalView?.isPaused = true
            metalView?.setNeedsDisplay()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let renderPassDescriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)
        else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)

        if let buffer = committedVertexBuffer, committedVertexCount > 0 {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: committedVertexCount)
        }

        if let buffer = activeVertexBuffer, activeVertexCount > 0 {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: activeVertexCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        if renderMode == .dirty {
            setRenderMode(.idle)
        }
    }

    private func makeVertices(for stroke: ActiveStroke) -> [StrokeRenderVertex] {
        guard let view = metalView else { return [] }

        var vertices: [StrokeRenderVertex] = []
        let color = UIColor(hex: stroke.color)?.withAlphaComponent(stroke.opacity) ?? .black
        let rgba = color.rgba

        for triangle in StrokeMeshBuilder.triangles(for: stroke) {
            vertices.append(contentsOf: triangle.map { point in
                StrokeRenderVertex(position: normalizedPoint(point, in: view.bounds), color: rgba)
            })
        }

        return vertices
    }

    private func normalizedPoint(_ point: CGPoint, in bounds: CGRect) -> SIMD2<Float> {
        let x = Float((point.x / max(bounds.width, 1.0)) * 2.0 - 1.0)
        let y = Float(1.0 - (point.y / max(bounds.height, 1.0)) * 2.0)
        return SIMD2<Float>(x, y)
    }
}

private extension UIColor {
    var rgba: SIMD4<Float> {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SIMD4(Float(red), Float(green), Float(blue), Float(alpha))
    }
}
