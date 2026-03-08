import MetalKit
import simd
import UIKit

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexIn {
  float2 position;
  float2 canvasPosition;
  float4 color;
  float style;
};

struct VertexOut {
  float4 position [[position]];
  float2 canvasPosition;
  float4 color;
  float style;
};

vertex VertexOut stroke_vertex(const device VertexIn* vertices [[buffer(0)]], uint id [[vertex_id]]) {
  VertexOut out;
  out.position = float4(vertices[id].position, 0.0, 1.0);
  out.canvasPosition = vertices[id].canvasPosition;
  out.color = vertices[id].color;
  out.style = vertices[id].style;
  return out;
}

float hash22(int2 p) {
  uint h = uint(p.x) * 374761393u;
  h += uint(p.y) * 668265263u;
  h = (h ^ (h >> 13)) * 1274126177u;
  h ^= (h >> 16);
  return float(h & 0xFFFFu) / 65535.0;
}

float smoothstep_safe(float edge0, float edge1, float x) {
  if (edge1 <= edge0) {
    return x >= edge1 ? 1.0 : 0.0;
  }
  float t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

float pencil_coverage(float paperHeight, float baseAlpha, float2 canvasPosition) {
  constexpr float sampleScale = 11.34;
  float2 scaledCanvas = canvasPosition * sampleScale;
  float pressure = clamp(baseAlpha * 1.05 + 0.08, 0.0, 1.0);
  float threshold = 0.56 - pressure * 0.24;
  float tooth = smoothstep_safe(threshold - 0.2, threshold + 0.12, paperHeight);
  int2 clumpCoord = int2(floor(scaledCanvas * 0.35)) + int2(17, 31);
  int2 microCoord = int2(floor(scaledCanvas * 1.7)) + int2(101, 53);
  int2 gapCoord = int2(floor(scaledCanvas * 4.8)) + int2(211, 163);
  float clumpNoise = hash22(clumpCoord);
  float microNoise = hash22(microCoord);
  float gapNoise = hash22(gapCoord);
  float clump = clumpNoise * (0.28 + 0.72 * clumpNoise);
  float gaps = smoothstep_safe(0.42, 0.86, tooth + 0.45 * microNoise + 0.2 * gapNoise - 0.38);
  return clamp(tooth * (0.08 + 0.92 * clump) * gaps, 0.0, 1.0);
}

fragment float4 stroke_fragment(VertexOut in [[stage_in]], texture2d<float> paperTexture [[texture(0)]]) {
  float4 color = in.color;
  if (in.style > 0.5) {
    constexpr sampler paperSampler(coord::normalized, filter::linear, address::repeat);
    float2 paperUV = fract((in.canvasPosition * 11.34) / 256.0);
    float paperHeight = paperTexture.sample(paperSampler, paperUV).r;
    float coverage = pencil_coverage(paperHeight, color.a, in.canvasPosition);
    color *= coverage;
  }
  return color;
}
"""

struct StrokeRenderVertex {
    var position: SIMD2<Float>
    var canvasPosition: SIMD2<Float>
    var color: SIMD4<Float>
    var style: Float
}

final class StrokeRenderer: NSObject, MTKViewDelegate {
    private weak var metalView: MTKView?
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let paperTexture: MTLTexture
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
            let fragmentFunction = library.makeFunction(name: "stroke_fragment"),
            let paperTexture = PencilTexture.makeMetalTexture(device: device)
        else {
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.rasterSampleCount = metalView.sampleCount
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }

        self.metalView = metalView
        self.commandQueue = commandQueue
        self.pipelineState = pipelineState
        self.paperTexture = paperTexture
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
        encoder.setFragmentTexture(paperTexture, index: 0)

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
        let rgba = color.premultipliedRGBA
        let style: Float = stroke.style == .pencil ? 1.0 : 0.0

        for triangle in StrokeMeshBuilder.triangles(for: stroke) {
            vertices.append(contentsOf: triangle.map { point in
                StrokeRenderVertex(
                    position: normalizedPoint(point, in: view.bounds),
                    canvasPosition: SIMD2(Float(point.x), Float(point.y)),
                    color: rgba,
                    style: style
                )
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
    var premultipliedRGBA: SIMD4<Float> {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return SIMD4(
            Float(red * alpha),
            Float(green * alpha),
            Float(blue * alpha),
            Float(alpha)
        )
    }
}
