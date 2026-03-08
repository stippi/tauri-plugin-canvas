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
  float dense = 0.32 + 0.68 * smoothstep_safe(0.18, 0.78, clumpNoise);
  float speckle = 0.62 + 0.38 * microNoise;
  float gaps = smoothstep_safe(0.58, 0.93, tooth + 0.45 * microNoise + 0.18 * gapNoise - 0.34);
  return clamp(tooth * dense * speckle * gaps, 0.0, 1.0);
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
    private let normalPipelineState: MTLRenderPipelineState
    private let markerPipelineState: MTLRenderPipelineState
    private let paperTexture: MTLTexture
    private var committedNormalVertexBuffer: MTLBuffer?
    private var committedMarkerVertexBuffer: MTLBuffer?
    private var activeNormalVertexBuffer: MTLBuffer?
    private var activeMarkerVertexBuffer: MTLBuffer?
    private var committedNormalVertexCount = 0
    private var committedMarkerVertexCount = 0
    private var activeNormalVertexCount = 0
    private var activeMarkerVertexCount = 0

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

        let normalDescriptor = MTLRenderPipelineDescriptor()
        normalDescriptor.vertexFunction = vertexFunction
        normalDescriptor.fragmentFunction = fragmentFunction
        normalDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        normalDescriptor.rasterSampleCount = metalView.sampleCount
        normalDescriptor.colorAttachments[0].isBlendingEnabled = true
        normalDescriptor.colorAttachments[0].rgbBlendOperation = .add
        normalDescriptor.colorAttachments[0].alphaBlendOperation = .add
        normalDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        normalDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        normalDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        normalDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let markerDescriptor = MTLRenderPipelineDescriptor()
        markerDescriptor.vertexFunction = vertexFunction
        markerDescriptor.fragmentFunction = fragmentFunction
        markerDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        markerDescriptor.rasterSampleCount = metalView.sampleCount
        markerDescriptor.colorAttachments[0].isBlendingEnabled = true
        markerDescriptor.colorAttachments[0].rgbBlendOperation = .max
        markerDescriptor.colorAttachments[0].alphaBlendOperation = .max
        markerDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        markerDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        markerDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        markerDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one

        guard
            let normalPipelineState = try? device.makeRenderPipelineState(descriptor: normalDescriptor),
            let markerPipelineState = try? device.makeRenderPipelineState(descriptor: markerDescriptor)
        else {
            return nil
        }

        self.metalView = metalView
        self.commandQueue = commandQueue
        self.normalPipelineState = normalPipelineState
        self.markerPipelineState = markerPipelineState
        self.paperTexture = paperTexture
        super.init()
    }

    func update(committed: [ActiveStroke], active: ActiveStroke?) {
        guard let device = metalView?.device else { return }
        let committedNormalVertices = committed
            .filter { $0.style != .marker }
            .flatMap(makeVertices(for:))
        committedNormalVertexCount = committedNormalVertices.count
        committedNormalVertexBuffer = committedNormalVertices.isEmpty ? nil : device.makeBuffer(
            bytes: committedNormalVertices,
            length: MemoryLayout<StrokeRenderVertex>.stride * committedNormalVertices.count
        )

        let committedMarkerVertices = committed
            .filter { $0.style == .marker }
            .flatMap(makeVertices(for:))
        committedMarkerVertexCount = committedMarkerVertices.count
        committedMarkerVertexBuffer = committedMarkerVertices.isEmpty ? nil : device.makeBuffer(
            bytes: committedMarkerVertices,
            length: MemoryLayout<StrokeRenderVertex>.stride * committedMarkerVertices.count
        )

        if let active {
            let activeVertices = makeVertices(for: active)
            if active.style == .marker {
                activeNormalVertexCount = 0
                activeNormalVertexBuffer = nil
                activeMarkerVertexCount = activeVertices.count
                activeMarkerVertexBuffer = activeVertices.isEmpty ? nil : device.makeBuffer(
                    bytes: activeVertices,
                    length: MemoryLayout<StrokeRenderVertex>.stride * activeVertices.count
                )
            } else {
                activeMarkerVertexCount = 0
                activeMarkerVertexBuffer = nil
                activeNormalVertexCount = activeVertices.count
                activeNormalVertexBuffer = activeVertices.isEmpty ? nil : device.makeBuffer(
                    bytes: activeVertices,
                    length: MemoryLayout<StrokeRenderVertex>.stride * activeVertices.count
                )
            }
        } else {
            activeNormalVertexCount = 0
            activeMarkerVertexCount = 0
            activeNormalVertexBuffer = nil
            activeMarkerVertexBuffer = nil
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

        encoder.setFragmentTexture(paperTexture, index: 0)

        if let buffer = committedNormalVertexBuffer, committedNormalVertexCount > 0 {
            encoder.setRenderPipelineState(normalPipelineState)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: committedNormalVertexCount)
        }

        if let buffer = activeNormalVertexBuffer, activeNormalVertexCount > 0 {
            encoder.setRenderPipelineState(normalPipelineState)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: activeNormalVertexCount)
        }

        if let buffer = committedMarkerVertexBuffer, committedMarkerVertexCount > 0 {
            encoder.setRenderPipelineState(markerPipelineState)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: committedMarkerVertexCount)
        }

        if let buffer = activeMarkerVertexBuffer, activeMarkerVertexCount > 0 {
            encoder.setRenderPipelineState(markerPipelineState)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: activeMarkerVertexCount)
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
        let color = UIColor(hex: stroke.color) ?? .black
        let style: Float = stroke.style == .pencil ? 1.0 : 0.0

        let meshTriangles: [[StrokeMeshVertex]]
        if stroke.style == .pencil {
            meshTriangles = StrokeMeshBuilder.meshTriangles(for: stroke)
        } else {
            meshTriangles = StrokeMeshBuilder.triangles(for: stroke).map { triangle in
                triangle.map { point in
                    StrokeMeshVertex(point: point, pressure: 1.0)
                }
            }
        }

        for triangle in meshTriangles {
            vertices.append(contentsOf: triangle.map { vertex in
                let alpha = stroke.style == .pencil
                    ? stroke.opacity * StrokeMeshBuilder.pressureOpacity(for: vertex.pressure)
                    : stroke.opacity
                return StrokeRenderVertex(
                    position: normalizedPoint(vertex.point, in: view.bounds),
                    canvasPosition: SIMD2(Float(vertex.point.x), Float(vertex.point.y)),
                    color: color.premultipliedRGBA(alpha: alpha),
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
    func premultipliedRGBA(alpha: CGFloat) -> SIMD4<Float> {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var baseAlpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &baseAlpha)
        let finalAlpha = max(0.0, min(1.0, alpha * baseAlpha))
        return SIMD4(
            Float(red * finalAlpha),
            Float(green * finalAlpha),
            Float(blue * finalAlpha),
            Float(finalAlpha)
        )
    }
}
