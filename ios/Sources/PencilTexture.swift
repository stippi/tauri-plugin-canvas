import CoreGraphics
import Metal

enum PencilTexture {
    static let size = 256
    static let sampleScale: CGFloat = 11.34
    static let pixels: [UInt8] = generateMediumGrain(size: size)

    static func makeMetalTexture(device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        pixels.withUnsafeBytes { ptr in
            texture.replace(
                region: MTLRegionMake2D(0, 0, size, size),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: size * MemoryLayout<UInt8>.size
            )
        }
        texture.label = "PencilPaperTexture"
        return texture
    }

    static func coverage(at point: CGPoint, baseAlpha: CGFloat) -> CGFloat {
        let scaledPoint = CGPoint(x: point.x * sampleScale, y: point.y * sampleScale)
        let paperHeight = sample(atScaledPoint: scaledPoint)
        let pressure = clamp01(baseAlpha * 1.05 + 0.08)
        let threshold = 0.56 - pressure * 0.24
        let tooth = smoothstep(threshold - 0.2, threshold + 0.12, paperHeight)
        let clumpNoise = CGFloat(hashValue(
            Int(floor(scaledPoint.x * 0.35)) + 17,
            Int(floor(scaledPoint.y * 0.35)) + 31
        ))
        let microNoise = CGFloat(hashValue(
            Int(floor(scaledPoint.x * 1.7)) + 101,
            Int(floor(scaledPoint.y * 1.7)) + 53
        ))
        let gapNoise = CGFloat(hashValue(
            Int(floor(scaledPoint.x * 4.8)) + 211,
            Int(floor(scaledPoint.y * 4.8)) + 163
        ))
        let dense = 0.32 + 0.68 * smoothstep(0.18, 0.78, clumpNoise)
        let speckle = 0.62 + 0.38 * microNoise
        let gaps = smoothstep(0.58, 0.93, tooth + 0.45 * microNoise + 0.18 * gapNoise - 0.34)
        let coverage = tooth * dense * speckle * gaps
        return clamp01(coverage)
    }

    private static func sample(atScaledPoint point: CGPoint) -> CGFloat {
        let wrappedX = positiveModulo(point.x, CGFloat(size))
        let wrappedY = positiveModulo(point.y, CGFloat(size))

        let x0 = Int(floor(wrappedX)) % size
        let y0 = Int(floor(wrappedY)) % size
        let x1 = (x0 + 1) % size
        let y1 = (y0 + 1) % size
        let tx = wrappedX - floor(wrappedX)
        let ty = wrappedY - floor(wrappedY)

        let v00 = pixelValue(x: x0, y: y0)
        let v10 = pixelValue(x: x1, y: y0)
        let v01 = pixelValue(x: x0, y: y1)
        let v11 = pixelValue(x: x1, y: y1)

        let top = v00 + (v10 - v00) * tx
        let bottom = v01 + (v11 - v01) * tx
        return top + (bottom - top) * ty
    }

    private static func pixelValue(x: Int, y: Int) -> CGFloat {
        CGFloat(pixels[y * size + x]) / 255.0
    }

    private static func generateMediumGrain(size: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let n0 = valueNoise(x: Float(x) * 0.08, y: Float(y) * 0.08) * 1.15
                let n1 = valueNoise(x: Float(x) * 0.18, y: Float(y) * 0.18) * 0.9
                let n2 = valueNoise(x: Float(x) * 0.55, y: Float(y) * 0.55) * 0.45
                let n3 = valueNoise(x: Float(x) * 1.6, y: Float(y) * 1.6) * 0.18
                let value = (n0 + n1 + n2 + n3) / 2.68
                let emphasized = value * value * (3.0 - 2.0 * value)
                let mapped = 0.08 + emphasized * 0.87
                result[y * size + x] = UInt8(clamp01(CGFloat(mapped)) * 255.0)
            }
        }
        return result
    }

    private static func valueNoise(x: Float, y: Float) -> Float {
        let ix = Int(floor(x))
        let iy = Int(floor(y))
        let fx = x - floor(x)
        let fy = y - floor(y)

        let sx = fx * fx * (3.0 - 2.0 * fx)
        let sy = fy * fy * (3.0 - 2.0 * fy)

        let v00 = hashValue(ix, iy)
        let v10 = hashValue(ix + 1, iy)
        let v01 = hashValue(ix, iy + 1)
        let v11 = hashValue(ix + 1, iy + 1)

        let top = v00 + sx * (v10 - v00)
        let bottom = v01 + sx * (v11 - v01)
        return top + sy * (bottom - top)
    }

    private static func hashValue(_ x: Int, _ y: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: x) &* 374_761_393
        h = h &+ UInt32(truncatingIfNeeded: y) &* 668_265_263
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h = h ^ (h >> 16)
        return Float(h & 0xFFFF) / 65535.0
    }

    private static func positiveModulo(_ value: CGFloat, _ modulus: CGFloat) -> CGFloat {
        let remainder = value.truncatingRemainder(dividingBy: modulus)
        return remainder >= 0 ? remainder : remainder + modulus
    }

    private static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        guard edge1 > edge0 else { return x >= edge1 ? 1.0 : 0.0 }
        let t = clamp01((x - edge0) / (edge1 - edge0))
        return t * t * (3.0 - 2.0 * t)
    }

    private static func clamp01(_ value: CGFloat) -> CGFloat {
        max(0.0, min(1.0, value))
    }
}
