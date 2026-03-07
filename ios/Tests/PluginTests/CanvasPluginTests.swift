import XCTest
@testable import tauri_plugin_canvas

final class CanvasPluginTests: XCTestCase {
    func testStrokeInterpolationKeepsEndpoints() {
        let samples = [
            CanvasStrokeSample(location: CGPoint(x: 0, y: 0), pressure: 1, altitude: 1, azimuth: 0, timestamp: 0),
            CanvasStrokeSample(location: CGPoint(x: 10, y: 10), pressure: 1, altitude: 1, azimuth: 0, timestamp: 1),
            CanvasStrokeSample(location: CGPoint(x: 20, y: 0), pressure: 1, altitude: 1, azimuth: 0, timestamp: 2),
        ]

        let smoothed = StrokeInterpolation.smoothedPoints(samples)

        XCTAssertEqual(smoothed.first?.location, samples.first?.location)
        XCTAssertEqual(smoothed.last?.location, samples.last?.location)
    }
}
