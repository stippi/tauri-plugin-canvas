import CoreGraphics
import Foundation
import UIKit

struct CanvasRect: Encodable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
}

struct CanvasPoint: Encodable {
    let x: CGFloat
    let y: CGFloat
    let pressure: CGFloat
    let altitude: CGFloat
    let azimuth: CGFloat
    let timestamp: TimeInterval
}

struct CanvasStroke: Encodable {
    let id: String
    let points: [CanvasPoint]
    let color: String
    let baseWidth: CGFloat
    let boundingBox: CanvasRect
}

struct CanvasPenConfig: Decodable {
    let color: String?
    let width: CGFloat?
    let opacity: CGFloat?
    let pressureSensitivity: CGFloat?

    static let `default` = CanvasPenConfig(color: "#000000", width: 2.0, opacity: 1.0, pressureSensitivity: 0.8)
}

struct CanvasStrokeSample {
    let location: CGPoint
    let pressure: CGFloat
    let altitude: CGFloat
    let azimuth: CGFloat
    let timestamp: TimeInterval
}

struct ActiveStroke {
    let id: String
    var points: [CanvasStrokeSample]
    let color: String
    let baseWidth: CGFloat
    let opacity: CGFloat
    let pressureSensitivity: CGFloat
}

final class StrokeStorage {
    private(set) var committedStrokes: [ActiveStroke] = []
    private(set) var redoStack: [ActiveStroke] = []
    private(set) var activeStroke: ActiveStroke?

    func beginStroke(sample: CanvasStrokeSample, pen: CanvasPenConfig) -> String {
        let stroke = ActiveStroke(
            id: UUID().uuidString,
            points: [sample],
            color: pen.color ?? CanvasPenConfig.default.color ?? "#000000",
            baseWidth: pen.width ?? CanvasPenConfig.default.width ?? 2.0,
            opacity: pen.opacity ?? CanvasPenConfig.default.opacity ?? 1.0,
            pressureSensitivity: pen.pressureSensitivity ?? CanvasPenConfig.default.pressureSensitivity ?? 0.8
        )
        activeStroke = stroke
        redoStack.removeAll()
        return stroke.id
    }

    func append(sample: CanvasStrokeSample) {
        guard var stroke = activeStroke else { return }
        stroke.points.append(sample)
        activeStroke = stroke
    }

    @discardableResult
    func finishStroke() -> ActiveStroke? {
        guard let stroke = activeStroke else { return nil }
        committedStrokes.append(stroke)
        activeStroke = nil
        return stroke
    }

    func clear() {
        committedStrokes.removeAll()
        redoStack.removeAll()
        activeStroke = nil
    }

    @discardableResult
    func undo() -> Bool {
        guard let stroke = committedStrokes.popLast() else { return false }
        redoStack.append(stroke)
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard let stroke = redoStack.popLast() else { return false }
        committedStrokes.append(stroke)
        return true
    }

    func exportStrokes(in bounds: CGRect) -> [CanvasStroke] {
        committedStrokes.map { exportStroke($0, in: bounds) }
    }

    func boundingBox(for stroke: ActiveStroke) -> CGRect {
        guard let first = stroke.points.first else { return .zero }
        return stroke.points.dropFirst().reduce(CGRect(origin: first.location, size: .zero)) { partial, point in
            partial.union(CGRect(origin: point.location, size: .zero))
        }
    }

    private func exportStroke(_ stroke: ActiveStroke, in bounds: CGRect) -> CanvasStroke {
        let points = stroke.points.map { sample in
            CanvasPoint(
                x: normalize(sample.location.x, within: bounds.width),
                y: normalize(sample.location.y, within: bounds.height),
                pressure: max(0.0, min(1.0, sample.pressure)),
                altitude: sample.altitude,
                azimuth: sample.azimuth,
                timestamp: sample.timestamp - (stroke.points.first?.timestamp ?? 0)
            )
        }
        let box = boundingBox(for: stroke)
        return CanvasStroke(
            id: stroke.id,
            points: points,
            color: stroke.color,
            baseWidth: stroke.baseWidth,
            boundingBox: CanvasRect(
                x: normalize(box.origin.x, within: bounds.width),
                y: normalize(box.origin.y, within: bounds.height),
                width: normalize(box.width, within: bounds.width),
                height: normalize(box.height, within: bounds.height)
            )
        )
    }

    private func normalize(_ value: CGFloat, within total: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        return value / total * 100.0
    }
}

extension StrokeStorage {
    func renderImage(in bounds: CGRect, includeBackground: Bool) -> UIImage {
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { context in
            if includeBackground {
                UIColor.white.setFill()
                context.fill(bounds)
            }

            committedStrokes.forEach { stroke in
                guard stroke.points.count >= 2 else { return }
                let path = UIBezierPath()
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: stroke.points[0].location)
                for point in stroke.points.dropFirst() {
                    path.addLine(to: point.location)
                }
                path.lineWidth = stroke.baseWidth
                UIColor(hex: stroke.color)?.withAlphaComponent(stroke.opacity).setStroke()
                path.stroke()
            }
        }
    }
}

