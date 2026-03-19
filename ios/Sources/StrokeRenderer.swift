import MetalKit
import UIKit
import simd

private let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
      float2 position;
      float2 canvasPosition;
      float2 localCoord;
      float4 color;
      float style;
    };

    struct VertexOut {
      float4 position [[position]];
      float2 canvasPosition;
      float2 localCoord;
      float4 color;
      float style;
    };

    vertex VertexOut stroke_vertex(const device VertexIn* vertices [[buffer(0)]], uint id [[vertex_id]]) {
      VertexOut out;
      out.position = float4(vertices[id].position, 0.0, 1.0);
      out.canvasPosition = vertices[id].canvasPosition;
      out.localCoord = vertices[id].localCoord;
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

    float marker_coverage(float2 localCoord, float2 canvasPosition) {
      float coarseNoise = hash22(int2(floor(canvasPosition * 0.45)) + int2(41, 73));
      float edgeNoise = hash22(int2(floor(canvasPosition * 1.9)) + int2(151, 227));
      float distanceToEdge = max(abs(localCoord.x), abs(localCoord.y));
      float fray = smoothstep_safe(0.56, 1.02, distanceToEdge);
      float edgeThreshold = 0.84 + 0.1 * coarseNoise + 0.08 * edgeNoise * fray;
      float edgeFade = 1.0 - smoothstep_safe(edgeThreshold, 1.08, distanceToEdge);
      float bodyTexture = 0.9 + 0.1 * coarseNoise;
      return clamp(edgeFade * bodyTexture, 0.0, 1.0);
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
      if (in.style > 1.5) {
        constexpr sampler paperSampler(coord::normalized, filter::linear, address::repeat);
        float2 paperUV = fract((in.canvasPosition * 11.34) / 256.0);
        float paperHeight = paperTexture.sample(paperSampler, paperUV).r;
        float coverage = pencil_coverage(paperHeight, color.a, in.canvasPosition);
        color *= coverage;
      } else if (in.style > 0.5) {
        color *= marker_coverage(in.localCoord, in.canvasPosition);
      }
      return color;
    }
    """

struct StrokeRenderVertex {
    var position: SIMD2<Float>
    var canvasPosition: SIMD2<Float>
    var localCoord: SIMD2<Float>
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
            let normalPipelineState = try? device.makeRenderPipelineState(
                descriptor: normalDescriptor),
            let markerPipelineState = try? device.makeRenderPipelineState(
                descriptor: markerDescriptor)
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
        let committedNormalVertices =
            committed
            .filter { $0.style != .marker }
            .flatMap(makeVertices(for:))
        committedNormalVertexCount = committedNormalVertices.count
        committedNormalVertexBuffer =
            committedNormalVertices.isEmpty
            ? nil
            : device.makeBuffer(
                bytes: committedNormalVertices,
                length: MemoryLayout<StrokeRenderVertex>.stride * committedNormalVertices.count
            )

        let committedMarkerVertices =
            committed
            .filter { $0.style == .marker }
            .flatMap(makeVertices(for:))
        committedMarkerVertexCount = committedMarkerVertices.count
        committedMarkerVertexBuffer =
            committedMarkerVertices.isEmpty
            ? nil
            : device.makeBuffer(
                bytes: committedMarkerVertices,
                length: MemoryLayout<StrokeRenderVertex>.stride * committedMarkerVertices.count
            )

        if let active {
            let activeVertices = makeVertices(for: active)
            if active.style == .marker {
                activeNormalVertexCount = 0
                activeNormalVertexBuffer = nil
                activeMarkerVertexCount = activeVertices.count
                activeMarkerVertexBuffer =
                    activeVertices.isEmpty
                    ? nil
                    : device.makeBuffer(
                        bytes: activeVertices,
                        length: MemoryLayout<StrokeRenderVertex>.stride * activeVertices.count
                    )
            } else {
                activeMarkerVertexCount = 0
                activeMarkerVertexBuffer = nil
                activeNormalVertexCount = activeVertices.count
                activeNormalVertexBuffer =
                    activeVertices.isEmpty
                    ? nil
                    : device.makeBuffer(
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
            encoder.drawPrimitives(
                type: .triangle, vertexStart: 0, vertexCount: committedNormalVertexCount)
        }

        if let buffer = activeNormalVertexBuffer, activeNormalVertexCount > 0 {
            encoder.setRenderPipelineState(normalPipelineState)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(
                type: .triangle, vertexStart: 0, vertexCount: activeNormalVertexCount)
        }

        if let buffer = committedMarkerVertexBuffer, committedMarkerVertexCount > 0 {
            encoder.setRenderPipelineState(markerPipelineState)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(
                type: .triangle, vertexStart: 0, vertexCount: committedMarkerVertexCount)
        }

        if let buffer = activeMarkerVertexBuffer, activeMarkerVertexCount > 0 {
            encoder.setRenderPipelineState(markerPipelineState)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(
                type: .triangle, vertexStart: 0, vertexCount: activeMarkerVertexCount)
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
            vertices.append(
                contentsOf: triangle.map { vertex in
                    let alpha =
                        stroke.style == .pencil
                        ? stroke.opacity * StrokeMeshBuilder.pressureOpacity(for: vertex.pressure)
                        : stroke.opacity
                    return StrokeRenderVertex(
                        position: normalizedPoint(vertex.point, in: view.bounds),
                        canvasPosition: SIMD2(Float(vertex.point.x), Float(vertex.point.y)),
                        localCoord: .zero,
                        color: color.premultipliedRGBA(alpha: alpha),
                        style: stroke.style == .pencil ? 2.0 : 0.0
                    )
                })
        }

        if stroke.style == .marker {
            vertices = makeMarkerVertices(for: stroke, in: view)
        }

        return vertices
    }

    private func makeMarkerVertices(for stroke: ActiveStroke, in view: UIView)
        -> [StrokeRenderVertex]
    {
        let color = UIColor(hex: stroke.color) ?? .black
        var vertices: [StrokeRenderVertex] = []

        for dab in MarkerBrush.dabs(for: stroke) {
            let corners = markerQuad(for: dab)
            let localCoords: [SIMD2<Float>] = [
                SIMD2(-1, -1),
                SIMD2(1, -1),
                SIMD2(1, 1),
                SIMD2(-1, 1),
            ]
            let alpha = dab.opacity
            let rgba = color.premultipliedRGBA(alpha: alpha)

            let quadVertices = zip(corners, localCoords).map { point, local in
                StrokeRenderVertex(
                    position: normalizedPoint(point, in: view.bounds),
                    canvasPosition: SIMD2(Float(point.x), Float(point.y)),
                    localCoord: local,
                    color: rgba,
                    style: 1.0
                )
            }
            vertices.append(quadVertices[0])
            vertices.append(quadVertices[1])
            vertices.append(quadVertices[2])
            vertices.append(quadVertices[0])
            vertices.append(quadVertices[2])
            vertices.append(quadVertices[3])
        }

        return vertices
    }

    private func markerQuad(for dab: MarkerDab) -> [CGPoint] {
        let corners = [
            CGPoint(x: -dab.halfWidth, y: -dab.halfHeight),
            CGPoint(x: dab.halfWidth, y: -dab.halfHeight),
            CGPoint(x: dab.halfWidth, y: dab.halfHeight),
            CGPoint(x: -dab.halfWidth, y: dab.halfHeight),
        ]
        return corners.map { corner in
            let cosine = cos(dab.angle)
            let sine = sin(dab.angle)
            let rotated = CGPoint(
                x: corner.x * cosine - corner.y * sine,
                y: corner.x * sine + corner.y * cosine
            )
            return CGPoint(x: dab.center.x + rotated.x, y: dab.center.y + rotated.y)
        }
    }

    private func normalizedPoint(_ point: CGPoint, in bounds: CGRect) -> SIMD2<Float> {
        let x = Float(((point.x - bounds.minX) / max(bounds.width, 1.0)) * 2.0 - 1.0)
        let y = Float(1.0 - ((point.y - bounds.minY) / max(bounds.height, 1.0)) * 2.0)
        return SIMD2<Float>(x, y)
    }

    // MARK: - Offscreen stroke export

    /// Render a single stroke to a `UIImage` using the Metal pipeline, producing
    /// output that is pixel-identical to the real-time on-screen rendering.
    func renderStrokeToImage(
        _ stroke: ActiveStroke, in canvasBounds: CGRect, fragmentBounds: CGRect
    ) -> UIImage? {
        guard let device = metalView?.device else { return nil }

        let scale = UIScreen.main.scale
        let pixelWidth = max(1, Int(ceil(fragmentBounds.width * scale)))
        let pixelHeight = max(1, Int(ceil(fragmentBounds.height * scale)))

        // --- Build vertices against the fragment bounds ---------------------
        let vertices = makeVerticesForExport(
            stroke: stroke, canvasBounds: canvasBounds, fragmentBounds: fragmentBounds)
        guard !vertices.isEmpty else { return nil }

        let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<StrokeRenderVertex>.stride * vertices.count
        )
        guard let vertexBuffer else { return nil }

        // --- Create offscreen texture (non-MSAA resolve target) -------------
        let resolveDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: pixelWidth,
            height: pixelHeight,
            mipmapped: false
        )
        resolveDescriptor.usage = [.renderTarget, .shaderRead]
        resolveDescriptor.storageMode = .shared
        guard let resolveTexture = device.makeTexture(descriptor: resolveDescriptor) else {
            return nil
        }

        // --- Create MSAA texture if the on-screen view uses MSAA ------------
        let sampleCount = metalView?.sampleCount ?? 1
        let msaaTexture: MTLTexture?
        if sampleCount > 1 {
            let msaaDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: pixelWidth,
                height: pixelHeight,
                mipmapped: false
            )
            msaaDescriptor.textureType = .type2DMultisample
            msaaDescriptor.sampleCount = sampleCount
            msaaDescriptor.usage = [.renderTarget]
            msaaDescriptor.storageMode = .memoryless
            msaaTexture = device.makeTexture(descriptor: msaaDescriptor)
            guard msaaTexture != nil else { return nil }
        } else {
            msaaTexture = nil
        }

        // --- Render pass ----------------------------------------------------
        let passDescriptor = MTLRenderPassDescriptor()
        if let msaa = msaaTexture {
            passDescriptor.colorAttachments[0].texture = msaa
            passDescriptor.colorAttachments[0].resolveTexture = resolveTexture
            passDescriptor.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            passDescriptor.colorAttachments[0].texture = resolveTexture
            passDescriptor.colorAttachments[0].storeAction = .store
        }
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0, green: 0, blue: 0, alpha: 0)

        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else {
            return nil
        }

        let pipelineState = stroke.style == .marker ? markerPipelineState : normalPipelineState
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(paperTexture, index: 0)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // --- Read back pixels -----------------------------------------------
        let bytesPerRow = pixelWidth * 4
        var pixelData = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        resolveTexture.getBytes(
            &pixelData,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight),
            mipmapLevel: 0
        )

        // Metal uses BGRA, convert to RGBA for UIImage
        for i in stride(from: 0, to: pixelData.count, by: 4) {
            let b = pixelData[i]
            pixelData[i] = pixelData[i + 2]
            pixelData[i + 2] = b
        }

        guard let provider = CGDataProvider(data: Data(pixelData) as CFData),
            let cgImage = CGImage(
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            return nil
        }

        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }

    /// Build vertices for a single stroke, normalized against a fragment sub-rect
    /// of the full canvas bounds.  The fragment coordinate system maps the
    /// fragment rect to Metal NDC [-1,+1].
    private func makeVerticesForExport(
        stroke: ActiveStroke,
        canvasBounds: CGRect,
        fragmentBounds: CGRect
    ) -> [StrokeRenderVertex] {
        let color = UIColor(hex: stroke.color) ?? .black

        if stroke.style == .marker {
            return makeMarkerVerticesForExport(
                stroke: stroke, canvasBounds: canvasBounds, fragmentBounds: fragmentBounds)
        }

        let meshTriangles: [[StrokeMeshVertex]]
        if stroke.style == .pencil {
            meshTriangles = StrokeMeshBuilder.meshTriangles(for: stroke)
        } else {
            meshTriangles = StrokeMeshBuilder.triangles(for: stroke).map { triangle in
                triangle.map { point in StrokeMeshVertex(point: point, pressure: 1.0) }
            }
        }

        var vertices: [StrokeRenderVertex] = []
        for triangle in meshTriangles {
            vertices.append(
                contentsOf: triangle.map { vertex in
                    let alpha =
                        stroke.style == .pencil
                        ? stroke.opacity * StrokeMeshBuilder.pressureOpacity(for: vertex.pressure)
                        : stroke.opacity
                    return StrokeRenderVertex(
                        position: normalizedPoint(vertex.point, in: fragmentBounds),
                        canvasPosition: SIMD2(Float(vertex.point.x), Float(vertex.point.y)),
                        localCoord: .zero,
                        color: color.premultipliedRGBA(alpha: alpha),
                        style: stroke.style == .pencil ? 2.0 : 0.0
                    )
                })
        }
        return vertices
    }

    private func makeMarkerVerticesForExport(
        stroke: ActiveStroke,
        canvasBounds: CGRect,
        fragmentBounds: CGRect
    ) -> [StrokeRenderVertex] {
        let color = UIColor(hex: stroke.color) ?? .black
        var vertices: [StrokeRenderVertex] = []

        for dab in MarkerBrush.dabs(for: stroke) {
            let corners = markerQuad(for: dab)
            let localCoords: [SIMD2<Float>] = [
                SIMD2(-1, -1),
                SIMD2(1, -1),
                SIMD2(1, 1),
                SIMD2(-1, 1),
            ]
            let alpha = dab.opacity
            let rgba = color.premultipliedRGBA(alpha: alpha)

            let quadVertices = zip(corners, localCoords).map { point, local in
                StrokeRenderVertex(
                    position: normalizedPoint(point, in: fragmentBounds),
                    canvasPosition: SIMD2(Float(point.x), Float(point.y)),
                    localCoord: local,
                    color: rgba,
                    style: 1.0
                )
            }
            vertices.append(quadVertices[0])
            vertices.append(quadVertices[1])
            vertices.append(quadVertices[2])
            vertices.append(quadVertices[0])
            vertices.append(quadVertices[2])
            vertices.append(quadVertices[3])
        }
        return vertices
    }
}

extension UIColor {
    fileprivate func premultipliedRGBA(alpha: CGFloat) -> SIMD4<Float> {
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
