import CoreGraphics

enum StrokeInterpolation {
    static func smoothedPoints(_ points: [CanvasStrokeSample]) -> [CanvasStrokeSample] {
        guard points.count > 2 else { return points }

        var result: [CanvasStrokeSample] = [points[0]]
        for index in 1..<(points.count - 1) {
            let previous = points[index - 1]
            let current = points[index]
            let next = points[index + 1]
            let smoothedLocation = CGPoint(
                x: (previous.location.x + current.location.x * 2 + next.location.x) / 4.0,
                y: (previous.location.y + current.location.y * 2 + next.location.y) / 4.0
            )
            result.append(
                CanvasStrokeSample(
                    location: smoothedLocation,
                    pressure: current.pressure,
                    altitude: current.altitude,
                    azimuth: current.azimuth,
                    roll: current.roll,
                    timestamp: current.timestamp
                )
            )
        }
        result.append(points[points.count - 1])
        return result
    }
}
