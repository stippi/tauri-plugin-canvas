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

    enum Style: String, Decodable {
        case smooth
        case marker
        case pencil
    }

    let tool: Tool?
    let style: Style?
    let color: String?
    let width: CGFloat?
    let opacity: CGFloat?
    let pressureSensitivity: CGFloat?

    static let `default` = CanvasPenConfig(
        tool: .draw,
        style: .smooth,
        color: "#000000",
        width: 2.0,
        opacity: 1.0,
        pressureSensitivity: 0.8
    )
}

struct CanvasStrokeSample {
    let location: CGPoint
    let pressure: CGFloat
    let altitude: CGFloat
    let azimuth: CGFloat
    let roll: CGFloat
    let timestamp: TimeInterval
}

struct ActiveStroke {
    let id: String
    var points: [CanvasStrokeSample]
    let style: CanvasPenConfig.Style
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
            style: pen.style ?? CanvasPenConfig.default.style ?? .smooth,
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
        if stroke.style == .marker {
            return MarkerBrush.bounds(for: stroke)
        }

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
        if stroke.style == .marker {
            return lastMarkerStrokeFragment(stroke, in: bounds)
        }
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

    private func lastMarkerStrokeFragment(_ stroke: ActiveStroke, in bounds: CGRect) -> CanvasStrokeFragment? {
        guard let fragment = renderMarkerStrokeFragment(stroke, in: bounds) else {
            return nil
        }

        guard let data = fragment.image.pngData()?.base64EncodedString() else {
            return nil
        }

        return CanvasStrokeFragment(
            strokeId: stroke.id,
            boundingBox: CanvasRect(
                x: normalize(fragment.bounds.origin.x - bounds.minX, within: bounds.width),
                y: normalize(fragment.bounds.origin.y - bounds.minY, within: bounds.height),
                width: normalize(fragment.bounds.width, within: bounds.width),
                height: normalize(fragment.bounds.height, within: bounds.height)
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
        guard UIColor(hex: stroke.color) != nil else {
            return
        }

        if stroke.style == .pencil {
            renderPencilStroke(stroke, in: context, offset: offset)
            return
        }
        if stroke.style == .marker {
            renderMarkerStroke(stroke, in: context, offset: offset)
            return
        }

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

    private func renderPencilStroke(_ stroke: ActiveStroke, in context: CGContext, offset: CGPoint) {
        let scale = context.ctm.a == 0 ? UIScreen.main.scale : abs(context.ctm.a)
        let shapeBounds = boundingBox(for: stroke).offsetBy(dx: -offset.x, dy: -offset.y)
        let paddedBounds = shapeBounds.insetBy(dx: -max(3.0, stroke.baseWidth), dy: -max(3.0, stroke.baseWidth))
        guard paddedBounds.width > 0, paddedBounds.height > 0 else {
            return
        }

        let pixelWidth = max(1, Int(ceil(paddedBounds.width * scale)))
        let pixelHeight = max(1, Int(ceil(paddedBounds.height * scale)))
        let maskBytesPerRow = pixelWidth
        var maskPixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight)

        guard
            let maskContext = CGContext(
                data: &maskPixels,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: maskBytesPerRow,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        else {
            return
        }

        maskContext.setAllowsAntialiasing(true)
        maskContext.setShouldAntialias(true)
        maskContext.interpolationQuality = .high
        maskContext.translateBy(x: -paddedBounds.minX * scale, y: -paddedBounds.minY * scale)
        maskContext.scaleBy(x: scale, y: scale)
        drawPencilPressureMask(stroke, in: maskContext, offset: offset)

        let bytesPerRow = pixelWidth * 4
        var colorPixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        guard let color = UIColor(hex: stroke.color) else { return }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        for y in 0..<pixelHeight {
            for x in 0..<pixelWidth {
                let maskIndex = y * maskBytesPerRow + x
                let maskAlpha = CGFloat(maskPixels[maskIndex]) / 255.0
                guard maskAlpha > 0 else { continue }

                let worldPoint = CGPoint(
                    x: offset.x + paddedBounds.minX + (CGFloat(x) + 0.5) / scale,
                    y: offset.y + paddedBounds.minY + (CGFloat(y) + 0.5) / scale
                )
                let coverage = PencilTexture.coverage(at: worldPoint, baseAlpha: maskAlpha)
                let finalAlpha = min(1.0, maskAlpha * coverage)
                let premultipliedRed = UInt8(max(0, min(255, Int(round(red * finalAlpha * 255.0)))))
                let premultipliedGreen = UInt8(max(0, min(255, Int(round(green * finalAlpha * 255.0)))))
                let premultipliedBlue = UInt8(max(0, min(255, Int(round(blue * finalAlpha * 255.0)))))
                let alphaByte = UInt8(max(0, min(255, Int(round(finalAlpha * 255.0)))))
                let pixelIndex = (y * pixelWidth + x) * 4
                colorPixels[pixelIndex] = premultipliedRed
                colorPixels[pixelIndex + 1] = premultipliedGreen
                colorPixels[pixelIndex + 2] = premultipliedBlue
                colorPixels[pixelIndex + 3] = alphaByte
            }
        }

        guard
            let outputContext = CGContext(
                data: &colorPixels,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ),
            let image = outputContext.makeImage()
        else {
            return
        }

        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: paddedBounds)
        context.restoreGState()
    }

    private func renderMarkerStroke(_ stroke: ActiveStroke, in context: CGContext, offset: CGPoint) {
        let scale = context.ctm.a == 0 ? UIScreen.main.scale : abs(context.ctm.a)
        guard let raster = markerRaster(
            for: stroke,
            fragmentOrigin: offset,
            scale: scale,
            extraPadding: max(4.0, stroke.baseWidth)
        ) else {
            return
        }
        guard let image = raster.image.cgImage else {
            return
        }

        context.saveGState()
        context.interpolationQuality = .high
        context.draw(image, in: raster.bounds.offsetBy(dx: -offset.x, dy: -offset.y))
        context.restoreGState()
    }

    private func renderMarkerStrokeFragment(_ stroke: ActiveStroke, in bounds: CGRect) -> (bounds: CGRect, image: UIImage)? {
        let padding = max(8.0, stroke.baseWidth * 3.0)
        let clipBounds = MarkerBrush.bounds(for: stroke).insetBy(dx: -padding, dy: -padding).intersection(bounds)
        guard clipBounds.width > 0, clipBounds.height > 0 else {
            return nil
        }
        return markerRaster(
            for: stroke,
            fragmentOrigin: clipBounds.origin,
            scale: UIScreen.main.scale,
            extraPadding: 0
        ).map {
            (bounds: $0.bounds, image: $0.image)
        }
    }

    private func markerRaster(
        for stroke: ActiveStroke,
        fragmentOrigin: CGPoint,
        scale: CGFloat,
        extraPadding: CGFloat
    ) -> (bounds: CGRect, image: UIImage)? {
        let shapeBounds = MarkerBrush.bounds(for: stroke).offsetBy(dx: -fragmentOrigin.x, dy: -fragmentOrigin.y)
        let paddedBounds = shapeBounds.insetBy(dx: -extraPadding, dy: -extraPadding)
        guard paddedBounds.width > 0, paddedBounds.height > 0 else {
            return nil
        }

        let pixelWidth = max(1, Int(ceil(paddedBounds.width * scale)))
        let pixelHeight = max(1, Int(ceil(paddedBounds.height * scale)))
        let maskBytesPerRow = pixelWidth
        var maskPixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight)
        let dabs = MarkerBrush.dabs(for: stroke)

        for dab in dabs {
            let dabBounds = CGRect(
                x: dab.center.x - dab.halfWidth - stroke.baseWidth,
                y: dab.center.y - dab.halfHeight - stroke.baseWidth,
                width: dab.halfWidth * 2 + stroke.baseWidth * 2,
                height: dab.halfHeight * 2 + stroke.baseWidth * 2
            )
            let localMinX = max(0, Int(floor((dabBounds.minX - fragmentOrigin.x - paddedBounds.minX) * scale)))
            let localMaxX = min(pixelWidth - 1, Int(ceil((dabBounds.maxX - fragmentOrigin.x - paddedBounds.minX) * scale)))
            let localMinY = max(0, Int(floor((dabBounds.minY - fragmentOrigin.y - paddedBounds.minY) * scale)))
            let localMaxY = min(pixelHeight - 1, Int(ceil((dabBounds.maxY - fragmentOrigin.y - paddedBounds.minY) * scale)))
            guard localMinX <= localMaxX, localMinY <= localMaxY else { continue }

            for y in localMinY...localMaxY {
                for x in localMinX...localMaxX {
                    let worldPoint = CGPoint(
                        x: fragmentOrigin.x + paddedBounds.minX + (CGFloat(x) + 0.5) / scale,
                        y: fragmentOrigin.y + paddedBounds.minY + (CGFloat(y) + 0.5) / scale
                    )
                    let alpha = MarkerBrush.coverage(at: worldPoint, dab: dab) * dab.opacity
                    guard alpha > 0 else { continue }
                    let index = y * maskBytesPerRow + x
                    let alphaByte = UInt8(max(0, min(255, Int(round(alpha * 255.0)))))
                    if alphaByte > maskPixels[index] {
                        maskPixels[index] = alphaByte
                    }
                }
            }
        }

        let bytesPerRow = pixelWidth * 4
        var colorPixels = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
        guard let color = UIColor(hex: stroke.color) else { return nil }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        for y in 0..<pixelHeight {
            for x in 0..<pixelWidth {
                let maskIndex = y * maskBytesPerRow + x
                let maskAlpha = CGFloat(maskPixels[maskIndex]) / 255.0
                guard maskAlpha > 0 else { continue }

                let finalAlpha = min(1.0, maskAlpha)
                let premultipliedRed = UInt8(max(0, min(255, Int(round(red * finalAlpha * 255.0)))))
                let premultipliedGreen = UInt8(max(0, min(255, Int(round(green * finalAlpha * 255.0)))))
                let premultipliedBlue = UInt8(max(0, min(255, Int(round(blue * finalAlpha * 255.0)))))
                let alphaByte = UInt8(max(0, min(255, Int(round(finalAlpha * 255.0)))))
                let pixelIndex = (y * pixelWidth + x) * 4
                colorPixels[pixelIndex] = premultipliedRed
                colorPixels[pixelIndex + 1] = premultipliedGreen
                colorPixels[pixelIndex + 2] = premultipliedBlue
                colorPixels[pixelIndex + 3] = alphaByte
            }
        }

        guard
            let outputContext = CGContext(
                data: &colorPixels,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ),
            let image = outputContext.makeImage()
        else {
            return nil
        }

        return (
            bounds: CGRect(
                x: fragmentOrigin.x + paddedBounds.minX,
                y: fragmentOrigin.y + paddedBounds.minY,
                width: paddedBounds.width,
                height: paddedBounds.height
            ),
            image: UIImage(cgImage: image, scale: scale, orientation: .up)
        )
    }

    private func drawPencilPressureMask(_ stroke: ActiveStroke, in context: CGContext, offset: CGPoint) {
        if stroke.points.count == 1, let point = stroke.points.first {
            let translated = CGPoint(x: point.location.x - offset.x, y: point.location.y - offset.y)
            let radius = max(1.0, stroke.baseWidth * 0.5)
            let alpha = stroke.opacity * StrokeMeshBuilder.pressureOpacity(for: point.pressure)
            context.setFillColor(UIColor(white: 1.0, alpha: alpha).cgColor)
            context.fillEllipse(in: CGRect(
                x: translated.x - radius,
                y: translated.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            return
        }

        let points = StrokeInterpolation.smoothedPoints(stroke.points)
        guard points.count >= 2 else { return }

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let delta = CGPoint(
                x: current.location.x - previous.location.x,
                y: current.location.y - previous.location.y
            )
            let length = max(0.001, sqrt(delta.x * delta.x + delta.y * delta.y))
            let normal = CGPoint(x: -delta.y / length, y: delta.x / length)
            let previousWidth = max(
                1.0,
                stroke.baseWidth * (1.0 + (previous.pressure - 0.5) * stroke.pressureSensitivity)
            )
            let currentWidth = max(
                1.0,
                stroke.baseWidth * (1.0 + (current.pressure - 0.5) * stroke.pressureSensitivity)
            )
            let previousOffset = CGPoint(x: normal.x * previousWidth * 0.5, y: normal.y * previousWidth * 0.5)
            let currentOffset = CGPoint(x: normal.x * currentWidth * 0.5, y: normal.y * currentWidth * 0.5)
            let alpha = stroke.opacity * StrokeMeshBuilder.pressureOpacity(for: (previous.pressure + current.pressure) * 0.5)

            context.setFillColor(UIColor(white: 1.0, alpha: alpha).cgColor)
            context.beginPath()
            context.move(to: CGPoint(x: previous.location.x + previousOffset.x - offset.x, y: previous.location.y + previousOffset.y - offset.y))
            context.addLine(to: CGPoint(x: current.location.x + currentOffset.x - offset.x, y: current.location.y + currentOffset.y - offset.y))
            context.addLine(to: CGPoint(x: current.location.x - currentOffset.x - offset.x, y: current.location.y - currentOffset.y - offset.y))
            context.addLine(to: CGPoint(x: previous.location.x - previousOffset.x - offset.x, y: previous.location.y - previousOffset.y - offset.y))
            context.closePath()
            context.fillPath()
        }
    }

    private func drawStrokeShape(_ stroke: ActiveStroke, in context: CGContext, offset: CGPoint, fillColor: CGColor) {
        context.setFillColor(fillColor)

        if stroke.points.count == 1, let point = stroke.points.first {
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
