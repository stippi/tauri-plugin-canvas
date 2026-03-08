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

struct CanvasStrokeFragment: Encodable {
    let strokeId: String
    let boundingBox: CanvasRect
    let imageData: String
}

struct CanvasPenConfig: Decodable {
    enum Tool: String, Decodable {
        case draw
        case erase
    }

    let tool: Tool?
    let color: String?
    let width: CGFloat?
    let opacity: CGFloat?
    let pressureSensitivity: CGFloat?

    static let `default` = CanvasPenConfig(tool: .draw, color: "#000000", width: 2.0, opacity: 1.0, pressureSensitivity: 0.8)
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

struct ActiveEraserStroke {
    let id: String
    var points: [CanvasStrokeSample]
    let baseWidth: CGFloat
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
        if stroke.points.count == 1, let point = stroke.points.first {
            let radius = max(1.0, stroke.baseWidth * 0.5)
            return CGRect(
                x: point.location.x - radius,
                y: point.location.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        }

        let triangles = StrokeMeshBuilder.triangles(for: stroke)
        guard let firstTriangle = triangles.first, let firstPoint = firstTriangle.first else {
            return .zero
        }

        return triangles.flatMap { $0 }.dropFirst().reduce(
            CGRect(origin: firstPoint, size: .zero)
        ) { partial, point in
            partial.union(CGRect(origin: point, size: .zero))
        }
    }

    func lastStrokeFragment(in bounds: CGRect) -> CanvasStrokeFragment? {
        guard let stroke = committedStrokes.last else { return nil }
        let box = boundingBox(for: stroke)
        let padding = max(8.0, stroke.baseWidth * 3.0)
        let clippedBox = box.insetBy(dx: -padding, dy: -padding).intersection(bounds)
        guard clippedBox.width > 0, clippedBox.height > 0 else { return nil }
        guard let data = renderStrokeFragment(stroke, in: clippedBox)?.pngData()?.base64EncodedString() else {
            return nil
        }

        return CanvasStrokeFragment(
            strokeId: stroke.id,
            boundingBox: CanvasRect(
                x: normalize(clippedBox.origin.x - bounds.minX, within: bounds.width),
                y: normalize(clippedBox.origin.y - bounds.minY, within: bounds.height),
                width: normalize(clippedBox.width, within: bounds.width),
                height: normalize(clippedBox.height, within: bounds.height)
            ),
            imageData: data
        )
    }

    private func exportStroke(_ stroke: ActiveStroke, in bounds: CGRect) -> CanvasStroke {
        let points = stroke.points.map { sample in
            CanvasPoint(
                x: normalize(sample.location.x - bounds.minX, within: bounds.width),
                y: normalize(sample.location.y - bounds.minY, within: bounds.height),
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
                x: normalize(box.origin.x - bounds.minX, within: bounds.width),
                y: normalize(box.origin.y - bounds.minY, within: bounds.height),
                width: normalize(box.width, within: bounds.width),
                height: normalize(box.height, within: bounds.height)
            )
        )
    }

    private func renderStrokeFragment(_ stroke: ActiveStroke, in fragmentBounds: CGRect) -> UIImage? {
        let renderBounds = CGRect(origin: .zero, size: fragmentBounds.size)
        let renderer = UIGraphicsImageRenderer(bounds: renderBounds)
        return renderer.image { context in
            renderStroke(stroke, in: context.cgContext, offset: fragmentBounds.origin)
        }
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
                renderStroke(stroke, in: context.cgContext, offset: .zero)
            }
        }
    }

    private func renderStroke(_ stroke: ActiveStroke, in context: CGContext, offset: CGPoint) {
        guard let color = UIColor(hex: stroke.color)?.withAlphaComponent(stroke.opacity).cgColor else {
            return
        }

        if stroke.points.count == 1, let point = stroke.points.first {
            context.setFillColor(color)
            let translated = CGPoint(x: point.location.x - offset.x, y: point.location.y - offset.y)
            let radius = max(1.0, stroke.baseWidth * 0.5)
            context.fillEllipse(in: CGRect(
                x: translated.x - radius,
                y: translated.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            return
        }

        context.setFillColor(color)
        for triangle in StrokeMeshBuilder.triangles(for: stroke) {
            guard triangle.count == 3 else { continue }
            context.beginPath()
            context.move(to: CGPoint(x: triangle[0].x - offset.x, y: triangle[0].y - offset.y))
            context.addLine(to: CGPoint(x: triangle[1].x - offset.x, y: triangle[1].y - offset.y))
            context.addLine(to: CGPoint(x: triangle[2].x - offset.x, y: triangle[2].y - offset.y))
            context.closePath()
            context.fillPath()
        }
    }
}
