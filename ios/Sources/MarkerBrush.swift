import CoreGraphics

struct MarkerDab {
    let center: CGPoint
    let angle: CGFloat
    let halfWidth: CGFloat
    let halfHeight: CGFloat
    let opacity: CGFloat
}

enum MarkerBrush {
    static func dabs(for stroke: ActiveStroke) -> [MarkerDab] {
        let points = StrokeInterpolation.smoothedPoints(stroke.points)
        guard !points.isEmpty else { return [] }
        if points.count == 1, let point = points.first {
            return [dab(for: point, stroke: stroke)]
        }

        var dabs: [MarkerDab] = []
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let previousDab = dab(for: previous, stroke: stroke)
            let currentDab = dab(for: current, stroke: stroke)
            let delta = CGPoint(x: current.location.x - previous.location.x, y: current.location.y - previous.location.y)
            let distance = hypot(delta.x, delta.y)
            let spacing = max(1.0, min(previousDab.halfHeight, currentDab.halfHeight) * 0.45)
            let steps = max(1, Int(ceil(distance / spacing)))

            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                dabs.append(interpolate(previousDab, currentDab, t: t))
            }
        }
        if let last = points.last {
            dabs.append(dab(for: last, stroke: stroke))
        }
        return dabs
    }

    static func bounds(for stroke: ActiveStroke) -> CGRect {
        let dabs = dabs(for: stroke)
        guard let first = dabs.first else { return .zero }
        return dabs.dropFirst().reduce(bounds(for: first)) { partial, dab in
            partial.union(bounds(for: dab))
        }
    }

    static func coverage(at point: CGPoint, dab: MarkerDab) -> CGFloat {
        let translated = CGPoint(x: point.x - dab.center.x, y: point.y - dab.center.y)
        let rotated = rotate(translated, by: -dab.angle)
        let local = CGPoint(
            x: rotated.x / max(dab.halfWidth, 0.001),
            y: rotated.y / max(dab.halfHeight, 0.001)
        )
        let distanceToEdge = max(abs(local.x), abs(local.y))
        guard distanceToEdge <= 1.12 else { return 0.0 }

        let coarseNoise = hashValue(
            Int(floor(point.x * 0.45)) + 41,
            Int(floor(point.y * 0.45)) + 73
        )
        let edgeNoise = hashValue(
            Int(floor(point.x * 1.9)) + 151,
            Int(floor(point.y * 1.9)) + 227
        )
        let fray = smoothstep(0.56, 1.02, distanceToEdge)
        let edgeThreshold = 0.84 + 0.1 * CGFloat(coarseNoise) + 0.08 * CGFloat(edgeNoise) * fray
        let edgeFade = 1.0 - smoothstep(edgeThreshold, 1.08, distanceToEdge)
        let bodyTexture = 0.9 + 0.1 * CGFloat(coarseNoise)
        return clamp01(edgeFade * bodyTexture)
    }

    private static func dab(for sample: CanvasStrokeSample, stroke: ActiveStroke) -> MarkerDab {
        let tilt = clamp01(1.0 - sin(sample.altitude))
        let pressure = clamp01(sample.pressure)
        let shortHalf = max(1.0, stroke.baseWidth * (0.38 + 0.12 * pressure + 0.08 * tilt))
        let longHalf = shortHalf * (1.6 + 1.4 * tilt)
        let opacity = stroke.opacity * max(0.44, min(1.0, 0.44 + pressure * 0.56))
        return MarkerDab(
            center: sample.location,
            angle: sample.roll,
            halfWidth: longHalf,
            halfHeight: shortHalf,
            opacity: opacity
        )
    }

    private static func interpolate(_ start: MarkerDab, _ end: MarkerDab, t: CGFloat) -> MarkerDab {
        MarkerDab(
            center: CGPoint(
                x: start.center.x + (end.center.x - start.center.x) * t,
                y: start.center.y + (end.center.y - start.center.y) * t
            ),
            angle: interpolateAngle(start.angle, end.angle, t: t),
            halfWidth: start.halfWidth + (end.halfWidth - start.halfWidth) * t,
            halfHeight: start.halfHeight + (end.halfHeight - start.halfHeight) * t,
            opacity: start.opacity + (end.opacity - start.opacity) * t
        )
    }

    private static func bounds(for dab: MarkerDab) -> CGRect {
        let corners = [
            CGPoint(x: -dab.halfWidth, y: -dab.halfHeight),
            CGPoint(x: dab.halfWidth, y: -dab.halfHeight),
            CGPoint(x: dab.halfWidth, y: dab.halfHeight),
            CGPoint(x: -dab.halfWidth, y: dab.halfHeight),
        ].map { corner in
            let rotated = rotate(corner, by: dab.angle)
            return CGPoint(x: dab.center.x + rotated.x, y: dab.center.y + rotated.y)
        }
        guard let first = corners.first else { return .zero }
        return corners.dropFirst().reduce(CGRect(origin: first, size: .zero)) { partial, point in
            partial.union(CGRect(origin: point, size: .zero))
        }
    }

    private static func interpolateAngle(_ start: CGFloat, _ end: CGFloat, t: CGFloat) -> CGFloat {
        var delta = end - start
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        return start + delta * t
    }

    private static func rotate(_ point: CGPoint, by angle: CGFloat) -> CGPoint {
        let cosine = cos(angle)
        let sine = sin(angle)
        return CGPoint(
            x: point.x * cosine - point.y * sine,
            y: point.x * sine + point.y * cosine
        )
    }

    private static func hashValue(_ x: Int, _ y: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: x) &* 374_761_393
        h = h &+ UInt32(truncatingIfNeeded: y) &* 668_265_263
        h = (h ^ (h >> 13)) &* 1_274_126_177
        h = h ^ (h >> 16)
        return Float(h & 0xFFFF) / 65535.0
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
