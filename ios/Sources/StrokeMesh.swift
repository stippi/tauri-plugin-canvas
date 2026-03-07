import CoreGraphics

enum StrokeMeshBuilder {
    static func triangles(for stroke: ActiveStroke) -> [[CGPoint]] {
        let points = StrokeInterpolation.smoothedPoints(stroke.points)
        guard points.count >= 2 else { return [] }

        var triangles: [[CGPoint]] = []

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let delta = CGPoint(
                x: current.location.x - previous.location.x,
                y: current.location.y - previous.location.y
            )
            let length = max(0.001, sqrt(delta.x * delta.x + delta.y * delta.y))
            let normal = CGPoint(x: -delta.y / length, y: delta.x / length)
            let width = max(
                1.0,
                stroke.baseWidth * (1.0 + (current.pressure - 0.5) * stroke.pressureSensitivity)
            )
            let offset = CGPoint(x: normal.x * width * 0.5, y: normal.y * width * 0.5)

            let a = CGPoint(x: previous.location.x + offset.x, y: previous.location.y + offset.y)
            let b = CGPoint(x: previous.location.x - offset.x, y: previous.location.y - offset.y)
            let c = CGPoint(x: current.location.x + offset.x, y: current.location.y + offset.y)
            let d = CGPoint(x: current.location.x - offset.x, y: current.location.y - offset.y)

            triangles.append([a, b, c])
            triangles.append([c, b, d])
        }

        return triangles
    }
}
