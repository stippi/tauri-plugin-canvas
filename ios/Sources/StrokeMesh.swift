import CoreGraphics

struct StrokeMeshVertex {
    let point: CGPoint
    let pressure: CGFloat
}

enum StrokeMeshBuilder {
    /// Attempt 4: pow(p, 0.45) was good for mid-range but lifted very low
    /// pressure too much, making delicate faint strokes impossible.
    /// Now blending from linear (at p near 0) into the power curve
    /// (above ~0.2) via smoothstep, so the lightest touch stays faint
    /// while moderate pressure still ramps up quickly.
    static func remapPressure(_ pressure: CGFloat) -> CGFloat {
        let p = max(0.0, min(1.0, pressure))
        let curved = pow(p, 0.45)
        // smoothstep blend: linear below ~0.05, fully curved above ~0.2
        let t = min(1.0, p / 0.2)
        let blend = t * t * (3.0 - 2.0 * t)
        return p + (curved - p) * blend
    }

    static func triangles(for stroke: ActiveStroke) -> [[CGPoint]] {
        meshTriangles(for: stroke).map { triangle in
            triangle.map(\.point)
        }
    }

    static func pressureOpacity(for pressure: CGFloat) -> CGFloat {
        let p = remapPressure(pressure)
        return max(0.2, min(1.0, 0.2 + p * 0.8))
    }

    static func meshTriangles(for stroke: ActiveStroke) -> [[StrokeMeshVertex]] {
        let points = StrokeInterpolation.smoothedPoints(stroke.points)
        guard points.count >= 2 else { return [] }

        let outlines = meshOutline(for: stroke, points: points)
        var triangles: [[StrokeMeshVertex]] = []

        for index in 1..<outlines.count {
            let previous = outlines[index - 1]
            let current = outlines[index]
            triangles.append([previous.left, previous.right, current.left])
            triangles.append([current.left, previous.right, current.right])
        }

        return triangles
    }

    private static func meshOutline(
        for stroke: ActiveStroke,
        points: [CanvasStrokeSample]
    ) -> [(left: StrokeMeshVertex, right: StrokeMeshVertex)] {
        points.enumerated().map { index, point in
            let tangent = tangent(at: index, in: points)
            let normal = CGPoint(x: -tangent.y, y: tangent.x)
            let remapped = remapPressure(point.pressure)
            let width = max(
                1.0,
                stroke.baseWidth * (1.0 + (remapped - 0.5) * stroke.pressureSensitivity)
            )
            let offset = CGPoint(x: normal.x * width * 0.5, y: normal.y * width * 0.5)
            let left = StrokeMeshVertex(
                point: CGPoint(x: point.location.x + offset.x, y: point.location.y + offset.y),
                pressure: point.pressure
            )
            let right = StrokeMeshVertex(
                point: CGPoint(x: point.location.x - offset.x, y: point.location.y - offset.y),
                pressure: point.pressure
            )
            return (left: left, right: right)
        }
    }

    private static func tangent(at index: Int, in points: [CanvasStrokeSample]) -> CGPoint {
        let current = points[index]
        let previous = index > 0 ? points[index - 1] : current
        let next = index < points.count - 1 ? points[index + 1] : current

        let incoming = normalizedDirection(from: previous.location, to: current.location)
        let outgoing = normalizedDirection(from: current.location, to: next.location)
        let blended = normalize(CGPoint(x: incoming.x + outgoing.x, y: incoming.y + outgoing.y))

        if length(blended) > 0.0001 {
            return blended
        }
        if length(outgoing) > 0.0001 {
            return outgoing
        }
        if length(incoming) > 0.0001 {
            return incoming
        }
        return CGPoint(x: 1.0, y: 0.0)
    }

    private static func normalizedDirection(from start: CGPoint, to end: CGPoint) -> CGPoint {
        normalize(CGPoint(x: end.x - start.x, y: end.y - start.y))
    }

    private static func normalize(_ vector: CGPoint) -> CGPoint {
        let vectorLength = length(vector)
        guard vectorLength > 0.0001 else {
            return .zero
        }
        return CGPoint(x: vector.x / vectorLength, y: vector.y / vectorLength)
    }

    private static func length(_ vector: CGPoint) -> CGFloat {
        sqrt(vector.x * vector.x + vector.y * vector.y)
    }
}
