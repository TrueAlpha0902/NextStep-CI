import NotesCore
import UIKit

/// A bounded image request made by the canvas export renderer.
///
/// Resolvers should decode a local asset directly to this size with ImageIO. The renderer also
/// validates the returned decoded pixel buffer, so an integration cannot accidentally retain or
/// embed an unbounded original image. A resolver receives an `AssetID`, never a network URL.
struct CanvasElementExportImageRequest: Equatable {
    static let hardMaximumPixelDimension: CGFloat = 4_096
    static let hardMaximumDecodedBytes = 64 * 1_024 * 1_024

    let targetPixelSize: CGSize
    let maximumPixelDimension: CGFloat
    let maximumDecodedBytes: Int

    init(
        frameSize: CGSize,
        rasterScale: CGFloat,
        maximumDecodedBytes: Int = CanvasElementExportImageRequest.hardMaximumDecodedBytes
    ) {
        let width = Self.finitePositive(frameSize.width, fallback: 1)
        let height = Self.finitePositive(frameSize.height, fallback: 1)
        let scale = Self.finitePositive(rasterScale, fallback: 1)
        let requestedWidth = min(ceil(width * scale), Self.hardMaximumPixelDimension)
        let requestedHeight = min(ceil(height * scale), Self.hardMaximumPixelDimension)
        let decodedByteBudget = min(max(maximumDecodedBytes, 0), Self.hardMaximumDecodedBytes)
        let memoryScale = sqrt(
            CGFloat(decodedByteBudget / 4) / max(requestedWidth * requestedHeight, 1)
        )
        let boundedScale = min(memoryScale, 1)
        targetPixelSize = CGSize(
            width: max(floor(requestedWidth * boundedScale), 1),
            height: max(floor(requestedHeight * boundedScale), 1)
        )
        maximumPixelDimension = max(targetPixelSize.width, targetPixelSize.height)
        self.maximumDecodedBytes = decodedByteBudget
    }

    func accepts(_ image: UIImage) -> Bool {
        // A CIImage-backed UIImage can defer an arbitrarily large decode until draw time. Export
        // accepts only an already-decoded CGImage thumbnail supplied by the resolver.
        guard let cgImage = image.cgImage,
              cgImage.width > 0,
              cgImage.height > 0,
              CGFloat(max(cgImage.width, cgImage.height)) <= maximumPixelDimension else {
            return false
        }
        guard let decodedByteCount = decodedByteCount(of: image) else { return false }
        return decodedByteCount <= maximumDecodedBytes
    }

    func decodedByteCount(of image: UIImage) -> Int? {
        guard let cgImage = image.cgImage,
              cgImage.width > 0,
              cgImage.height > 0,
              cgImage.bytesPerRow > 0,
              cgImage.height <= Int.max / cgImage.bytesPerRow else { return nil }
        return cgImage.bytesPerRow * cgImage.height
    }

    private static func finitePositive(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return fallback }
        return min(value, 1_000_000)
    }
}

typealias CanvasElementExportImageResolver = (
    _ assetID: AssetID,
    _ request: CanvasElementExportImageRequest
) -> UIImage?

struct CanvasElementExportEntry: Equatable {
    let element: CanvasElement
    let originalOffset: Int
    let frame: CGRect
    let rotationRadians: CGFloat
    let opacity: CGFloat
}

struct CanvasElementExportPlan: Equatable {
    let sourceBounds: CGRect
    let entries: [CanvasElementExportEntry]
}

/// Deterministic vector export for the structured canvas layer.
///
/// Elements are clipped to the page, ordered back-to-front by persisted z-index (stable by input
/// offset), and rendered in page space. Geometry is sanitized independently from editing so a
/// corrupt or future document cannot create non-finite Core Graphics transforms during export.
@MainActor
enum CanvasElementExportRenderer {
    static let maximumElementCount = 10_000
    static let maximumTextUTF16Length = 32_768
    static let maximumAssetResolutionAttempts =
        NotebookExportReadLimits.maximumCanvasAssetResolutionAttempts

    private static let minimumDimension: CGFloat = 0.5
    private static let maximumGeometryMagnitude: CGFloat = 1_000_000
    private static let maximumFontSize: CGFloat = 512
    private static let maximumFontNameUTF16Length = 128

    private struct WorkBudget {
        var remainingTextUTF16Units = 1_000_000
        var remainingDecorativeMarks = 20_000
        var remainingAssetResolutionAttempts =
            NotebookExportReadLimits.maximumCanvasAssetResolutionAttempts
        var remainingAssetDecodedBytes = CanvasElementExportImageRequest.hardMaximumDecodedBytes
    }

    static func plan(
        elements: [CanvasElement],
        sourceBounds: CGRect
    ) -> CanvasElementExportPlan {
        let source = canonicalSourceBounds(sourceBounds)
        // Cap before sorting so a corrupt imported array cannot turn ordering itself into
        // unbounded work. Documents within the supported limit retain exact global z-order.
        let ordered = elements.prefix(maximumElementCount).enumerated().sorted { lhs, rhs in
            if lhs.element.zIndex != rhs.element.zIndex {
                return lhs.element.zIndex < rhs.element.zIndex
            }
            return lhs.offset < rhs.offset
        }
        let entries = ordered.map { offset, element in
            CanvasElementExportEntry(
                element: element,
                originalOffset: offset,
                frame: canonicalFrame(element.frame, sourceBounds: source),
                rotationRadians: canonicalRotation(element.rotationRadians),
                opacity: canonicalUnit(element.opacity, fallback: 1)
            )
        }
        return CanvasElementExportPlan(sourceBounds: source, entries: entries)
    }

    /// Returns the unique assets that can be requested by the renderer, in first-attempt order.
    /// Duplicate image/sticker elements still consume attempts exactly as `draw` does, so callers
    /// never pre-load assets that occur only after the fixed 256-attempt work budget is exhausted.
    static func assetIDsForExport(
        elements: [CanvasElement],
        sourceBounds: CGRect
    ) -> [AssetID] {
        let exportPlan = plan(elements: elements, sourceBounds: sourceBounds)
        var remainingAttempts = maximumAssetResolutionAttempts
        var seen = Set<AssetID>()
        var result = [AssetID]()
        result.reserveCapacity(min(exportPlan.entries.count, maximumAssetResolutionAttempts))
        for entry in exportPlan.entries {
            let assetID: AssetID
            switch entry.element.content {
            case .image(let image):
                assetID = image.assetID
            case .sticker(let sticker):
                assetID = sticker.assetID
            case .text, .shape, .connector, .stickyNote, .tape, .link:
                continue
            }
            guard remainingAttempts > 0 else { break }
            remainingAttempts -= 1
            if seen.insert(assetID).inserted {
                result.append(assetID)
            }
        }
        return result
    }

    static func draw(
        elements: [CanvasElement],
        sourceBounds: CGRect,
        outputBounds: CGRect,
        rasterScale: CGFloat,
        context: CGContext,
        assetImageResolver: CanvasElementExportImageResolver,
        linkAnnotationHandler: ((URL, CGRect) -> Void)? = nil
    ) {
        let exportPlan = plan(elements: elements, sourceBounds: sourceBounds)
        let output = canonicalOutputBounds(outputBounds)
        let scaleX = output.width / exportPlan.sourceBounds.width
        let scaleY = output.height / exportPlan.sourceBounds.height

        context.saveGState()
        context.translateBy(x: output.minX, y: output.minY)
        context.scaleBy(x: scaleX, y: scaleY)
        context.translateBy(x: -exportPlan.sourceBounds.minX, y: -exportPlan.sourceBounds.minY)
        context.clip(to: exportPlan.sourceBounds)

        var workBudget = WorkBudget()
        for entry in exportPlan.entries {
            autoreleasepool {
                draw(
                    entry,
                    rasterScale: rasterScale,
                    context: context,
                    assetImageResolver: assetImageResolver,
                    workBudget: &workBudget
                )
            }
        }
        context.restoreGState()

        guard let linkAnnotationHandler else { return }
        for entry in exportPlan.entries {
            // A fully transparent link has no visible affordance. Keeping its PDF annotation
            // would create an invisible active region in an otherwise faithful export.
            guard entry.opacity > 0,
                  case .link(let link) = entry.element.content,
                  let safeDestination = safeLinkDestination(link.destination) else { continue }
            let rect = transformedBoundingRect(
                for: entry,
                sourceBounds: exportPlan.sourceBounds,
                outputBounds: output
            ).intersection(output)
            guard !rect.isNull, rect.width > 0, rect.height > 0 else { continue }
            linkAnnotationHandler(safeDestination, rect)
        }
    }

    static func safeLinkDestination(_ destination: URL) -> URL? {
        guard (destination.absoluteString as NSString).length <= 4_096,
              let components = URLComponents(url: destination, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        return destination
    }

    private static func draw(
        _ entry: CanvasElementExportEntry,
        rasterScale: CGFloat,
        context: CGContext,
        assetImageResolver: CanvasElementExportImageResolver,
        workBudget: inout WorkBudget
    ) {
        let frame = entry.frame
        context.saveGState()
        context.translateBy(x: frame.midX, y: frame.midY)
        context.rotate(by: entry.rotationRadians)
        context.translateBy(x: -frame.midX, y: -frame.midY)
        context.setAlpha(entry.opacity)

        switch entry.element.content {
        case .text(let text):
            drawText(
                text.text,
                in: frame.insetBy(dx: 8, dy: 8),
                fontName: text.fontName,
                fontSize: finiteClamped(
                    text.fontSize,
                    fallback: 17,
                    minimum: 1,
                    maximum: Double(maximumFontSize)
                ),
                color: color(text.color),
                context: context,
                workBudget: &workBudget
            )
        case .image(let image):
            drawAsset(
                image.assetID,
                in: frame,
                contentMode: image.contentMode,
                rasterScale: rasterScale,
                isSticker: false,
                context: context,
                resolver: assetImageResolver,
                workBudget: &workBudget
            )
        case .shape(let shape):
            drawShape(shape, in: frame, context: context)
        case .connector(let connector):
            drawConnector(connector, in: frame, context: context)
        case .stickyNote(let sticky):
            drawStickyNote(sticky, in: frame, context: context, workBudget: &workBudget)
        case .tape(let tape):
            drawTape(tape, in: frame, context: context, workBudget: &workBudget)
        case .sticker(let sticker):
            drawAsset(
                sticker.assetID,
                in: frame,
                contentMode: "fit",
                rasterScale: rasterScale,
                isSticker: true,
                context: context,
                resolver: assetImageResolver,
                workBudget: &workBudget
            )
        case .link(let link):
            drawLink(link, in: frame, context: context, workBudget: &workBudget)
        }
        context.restoreGState()
    }

    private static func drawText(
        _ rawText: String,
        in rawRect: CGRect,
        fontName rawFontName: String,
        fontSize rawFontSize: Double,
        color: UIColor,
        context: CGContext,
        workBudget: inout WorkBudget
    ) {
        let rect = nonnegativeInsetRect(rawRect)
        guard rect.width > 0,
              rect.height > 0,
              workBudget.remainingTextUTF16Units > 0 else { return }
        let text = boundedString(
            rawText,
            utf16Limit: min(maximumTextUTF16Length, workBudget.remainingTextUTF16Units)
        )
        guard !text.isEmpty else { return }
        workBudget.remainingTextUTF16Units -= (text as NSString).length
        let fontName = boundedString(rawFontName, utf16Limit: maximumFontNameUTF16Length)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fontSize = CGFloat(finiteClamped(
            rawFontSize,
            fallback: 17,
            minimum: 1,
            maximum: Double(maximumFontSize)
        ))
        let font = fontName.isEmpty || fontName.caseInsensitiveCompare("System") == .orderedSame
            ? UIFont.systemFont(ofSize: fontSize)
            : UIFont(name: fontName, size: fontSize) ?? UIFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .natural

        context.saveGState()
        context.clip(to: rect)
        (text as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ],
            context: nil
        )
        context.restoreGState()
    }

    private static func drawShape(
        _ shape: ShapeElement,
        in frame: CGRect,
        context: CGContext
    ) {
        let lineWidth = CGFloat(finiteClamped(
            shape.lineWidth,
            fallback: 2,
            minimum: 0.5,
            maximum: 256
        ))
        let inset = min(lineWidth / 2, min(frame.width, frame.height) / 2)
        let bounds = frame.insetBy(dx: inset, dy: inset)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let path: UIBezierPath
        switch boundedString(shape.shape, utf16Limit: 64).lowercased() {
        case "ellipse", "circle":
            path = UIBezierPath(ovalIn: bounds)
        case "rectangle", "square":
            path = UIBezierPath(rect: bounds)
        case "diamond":
            path = UIBezierPath()
            path.move(to: CGPoint(x: bounds.midX, y: bounds.minY))
            path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY))
            path.addLine(to: CGPoint(x: bounds.midX, y: bounds.maxY))
            path.addLine(to: CGPoint(x: bounds.minX, y: bounds.midY))
            path.close()
        case "triangle":
            path = UIBezierPath()
            path.move(to: CGPoint(x: bounds.midX, y: bounds.minY))
            path.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
            path.addLine(to: CGPoint(x: bounds.minX, y: bounds.maxY))
            path.close()
        default:
            path = UIBezierPath(
                roundedRect: bounds,
                cornerRadius: min(12, min(bounds.width, bounds.height) / 4)
            )
        }

        context.saveGState()
        context.setStrokeColor(color(shape.strokeColor).cgColor)
        context.setLineWidth(lineWidth)
        context.addPath(path.cgPath)
        if let fill = shape.fillColor {
            context.setFillColor(color(fill).cgColor)
            context.drawPath(using: .fillStroke)
        } else {
            context.strokePath()
        }
        context.restoreGState()
    }

    private static func drawConnector(
        _ connector: ConnectorElement,
        in frame: CGRect,
        context: CGContext
    ) {
        let start = canonicalPoint(
            connector.start,
            fallback: CGPoint(x: frame.minX, y: frame.midY),
            around: frame
        )
        let end = canonicalPoint(
            connector.end,
            fallback: CGPoint(x: frame.maxX, y: frame.midY),
            around: frame
        )
        let lineWidth = CGFloat(finiteClamped(
            connector.lineWidth,
            fallback: 2,
            minimum: 0.5,
            maximum: 256
        ))
        context.saveGState()
        context.setStrokeColor(color(connector.strokeColor).cgColor)
        context.setFillColor(color(connector.strokeColor).cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()

        let cap = boundedString(connector.endCap, utf16Limit: 64).lowercased()
        if cap.contains("arrow") {
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = max(8, min(24, lineWidth * 4))
            context.move(to: end)
            context.addLine(to: CGPoint(
                x: end.x - length * cos(angle - .pi / 6),
                y: end.y - length * sin(angle - .pi / 6)
            ))
            context.move(to: end)
            context.addLine(to: CGPoint(
                x: end.x - length * cos(angle + .pi / 6),
                y: end.y - length * sin(angle + .pi / 6)
            ))
            context.strokePath()
        } else if cap.contains("circle") {
            let diameter = max(6, min(20, lineWidth * 3))
            context.fillEllipse(in: CGRect(
                x: end.x - diameter / 2,
                y: end.y - diameter / 2,
                width: diameter,
                height: diameter
            ))
        }
        context.restoreGState()
    }

    private static func drawStickyNote(
        _ sticky: StickyNoteElement,
        in frame: CGRect,
        context: CGContext,
        workBudget: inout WorkBudget
    ) {
        let path = UIBezierPath(
            roundedRect: frame,
            cornerRadius: min(8, min(frame.width, frame.height) / 5)
        )
        context.saveGState()
        context.setFillColor(color(sticky.color).cgColor)
        context.addPath(path.cgPath)
        context.fillPath()
        context.setStrokeColor(UIColor.black.withAlphaComponent(0.08).cgColor)
        context.setLineWidth(1)
        context.addPath(path.cgPath)
        context.strokePath()
        context.restoreGState()
        drawText(
            sticky.text,
            in: frame.insetBy(dx: 10, dy: 10),
            fontName: "System",
            fontSize: 17,
            color: .label,
            context: context,
            workBudget: &workBudget
        )
    }

    private static func drawTape(
        _ tape: TapeElement,
        in frame: CGRect,
        context: CGContext,
        workBudget: inout WorkBudget
    ) {
        let path = UIBezierPath(
            roundedRect: frame,
            cornerRadius: min(5, min(frame.width, frame.height) / 4)
        )
        let tapeColor = color(tape.color)
        context.saveGState()
        context.setFillColor(tapeColor.withAlphaComponent(
            tapeColor.cgColor.alpha * (tape.isRevealed ? 0.28 : 1)
        ).cgColor)
        context.addPath(path.cgPath)
        context.fillPath()
        context.setStrokeColor(UIColor.label.withAlphaComponent(tape.isRevealed ? 0.35 : 0.12).cgColor)
        context.setLineWidth(1)
        if tape.isRevealed {
            context.setLineDash(phase: 0, lengths: [5, 4])
        }
        context.addPath(path.cgPath)
        context.strokePath()

        if tape.isRevealed {
            context.clip(to: frame)
            context.setStrokeColor(UIColor.label.withAlphaComponent(0.16).cgColor)
            context.setLineWidth(1)
            let spacing = max(min(frame.height / 3, 18), 6)
            var x = frame.minX - frame.height
            var marks = 0
            while x < frame.maxX,
                  marks < 512,
                  workBudget.remainingDecorativeMarks > 0 {
                context.move(to: CGPoint(x: x, y: frame.maxY))
                context.addLine(to: CGPoint(x: x + frame.height, y: frame.minY))
                x += spacing
                marks += 1
                workBudget.remainingDecorativeMarks -= 1
            }
            context.strokePath()
        }
        context.restoreGState()
    }

    private static func drawLink(
        _ link: LinkElement,
        in frame: CGRect,
        context: CGContext,
        workBudget: inout WorkBudget
    ) {
        let path = UIBezierPath(
            roundedRect: frame,
            cornerRadius: min(10, min(frame.width, frame.height) / 4)
        )
        context.saveGState()
        context.setFillColor(UIColor.secondarySystemBackground.cgColor)
        context.addPath(path.cgPath)
        context.fillPath()
        context.setStrokeColor(UIColor.separator.cgColor)
        context.setLineWidth(1)
        context.addPath(path.cgPath)
        context.strokePath()

        let iconRect = CGRect(
            x: frame.minX + 12,
            y: frame.midY - 7,
            width: 20,
            height: 14
        )
        context.setStrokeColor(UIColor.systemBlue.cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: CGRect(x: iconRect.minX, y: iconRect.minY, width: 12, height: 8))
        context.strokeEllipse(in: CGRect(x: iconRect.minX + 8, y: iconRect.minY + 6, width: 12, height: 8))
        context.restoreGState()

        let textX = min(frame.minX + 42, frame.maxX)
        let textWidth = max(frame.maxX - textX - 10, 0)
        drawText(
            link.title.isEmpty ? String(localized: "Link") : link.title,
            in: CGRect(x: textX, y: frame.minY + 8, width: textWidth, height: 25),
            fontName: "System",
            fontSize: 15,
            color: .label,
            context: context,
            workBudget: &workBudget
        )
        let destination = boundedString(link.destination.absoluteString, utf16Limit: 4_096)
        drawText(
            destination,
            in: CGRect(x: textX, y: frame.minY + 31, width: textWidth, height: 20),
            fontName: "System",
            fontSize: 11,
            color: .secondaryLabel,
            context: context,
            workBudget: &workBudget
        )
    }

    private static func drawAsset(
        _ assetID: AssetID,
        in frame: CGRect,
        contentMode rawContentMode: String,
        rasterScale: CGFloat,
        isSticker: Bool,
        context: CGContext,
        resolver: CanvasElementExportImageResolver,
        workBudget: inout WorkBudget
    ) {
        let request = CanvasElementExportImageRequest(
            frameSize: frame.size,
            rasterScale: rasterScale,
            maximumDecodedBytes: workBudget.remainingAssetDecodedBytes
        )
        guard workBudget.remainingAssetResolutionAttempts > 0,
              workBudget.remainingAssetDecodedBytes >= 4 else {
            drawMissingAsset(in: frame, isSticker: isSticker, context: context)
            return
        }
        workBudget.remainingAssetResolutionAttempts -= 1
        guard let image = resolver(assetID, request),
              request.accepts(image),
              let decodedByteCount = request.decodedByteCount(of: image),
              decodedByteCount <= workBudget.remainingAssetDecodedBytes else {
            drawMissingAsset(in: frame, isSticker: isSticker, context: context)
            return
        }
        workBudget.remainingAssetDecodedBytes -= decodedByteCount

        let contentMode = boundedString(rawContentMode, utf16Limit: 32).lowercased()
        let destination = contentMode == "fill"
            ? aspectFillRect(for: image.size, in: frame)
            : aspectFitRect(for: image.size, in: frame)
        context.saveGState()
        context.clip(to: frame)
        image.draw(in: destination)
        context.restoreGState()
    }

    private static func drawMissingAsset(
        in frame: CGRect,
        isSticker: Bool,
        context: CGContext
    ) {
        context.saveGState()
        context.setFillColor(UIColor.tertiarySystemFill.cgColor)
        context.fill(frame)
        context.setStrokeColor(UIColor.secondaryLabel.withAlphaComponent(0.6).cgColor)
        context.setLineWidth(max(min(min(frame.width, frame.height) / 18, 3), 1))
        let inset = min(10, min(frame.width, frame.height) / 4)
        let bounds = frame.insetBy(dx: inset, dy: inset)
        if isSticker {
            let radius = min(bounds.width, bounds.height) / 2
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let path = UIBezierPath()
            for index in 0 ..< 10 {
                let angle = -CGFloat.pi / 2 + CGFloat(index) * .pi / 5
                let distance = index.isMultiple(of: 2) ? radius : radius * 0.45
                let point = CGPoint(
                    x: center.x + cos(angle) * distance,
                    y: center.y + sin(angle) * distance
                )
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            path.close()
            context.addPath(path.cgPath)
            context.strokePath()
        } else {
            context.move(to: CGPoint(x: bounds.minX, y: bounds.minY))
            context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
            context.move(to: CGPoint(x: bounds.maxX, y: bounds.minY))
            context.addLine(to: CGPoint(x: bounds.minX, y: bounds.maxY))
            context.strokePath()
        }
        context.restoreGState()
    }

    private static func transformedBoundingRect(
        for entry: CanvasElementExportEntry,
        sourceBounds: CGRect,
        outputBounds: CGRect
    ) -> CGRect {
        let center = CGPoint(x: entry.frame.midX, y: entry.frame.midY)
        let cosine = cos(entry.rotationRadians)
        let sine = sin(entry.rotationRadians)
        let scaleX = outputBounds.width / sourceBounds.width
        let scaleY = outputBounds.height / sourceBounds.height
        let corners = [
            CGPoint(x: entry.frame.minX, y: entry.frame.minY),
            CGPoint(x: entry.frame.maxX, y: entry.frame.minY),
            CGPoint(x: entry.frame.maxX, y: entry.frame.maxY),
            CGPoint(x: entry.frame.minX, y: entry.frame.maxY),
        ].map { point -> CGPoint in
            let dx = point.x - center.x
            let dy = point.y - center.y
            let rotated = CGPoint(
                x: center.x + dx * cosine - dy * sine,
                y: center.y + dx * sine + dy * cosine
            )
            return CGPoint(
                x: outputBounds.minX + (rotated.x - sourceBounds.minX) * scaleX,
                y: outputBounds.minY + (rotated.y - sourceBounds.minY) * scaleY
            )
        }
        guard let first = corners.first else { return .null }
        return corners.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            rect.union(CGRect(origin: point, size: .zero))
        }
    }

    private static func canonicalSourceBounds(_ rawBounds: CGRect) -> CGRect {
        let width = finitePositive(rawBounds.width, fallback: 1)
        let height = finitePositive(rawBounds.height, fallback: 1)
        let x = finiteClamped(rawBounds.minX, fallback: 0)
        let y = finiteClamped(rawBounds.minY, fallback: 0)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func canonicalOutputBounds(_ rawBounds: CGRect) -> CGRect {
        CGRect(
            x: finiteClamped(rawBounds.minX, fallback: 0),
            y: finiteClamped(rawBounds.minY, fallback: 0),
            width: finitePositive(rawBounds.width, fallback: 1),
            height: finitePositive(rawBounds.height, fallback: 1)
        )
    }

    private static func canonicalFrame(
        _ rawFrame: CanvasRect,
        sourceBounds: CGRect
    ) -> CGRect {
        let maximumDimension = min(
            max(max(sourceBounds.width, sourceBounds.height) * 4, 44),
            maximumGeometryMagnitude
        )
        let rawWidth = finiteClamped(CGFloat(rawFrame.width), fallback: 44)
        let rawHeight = finiteClamped(CGFloat(rawFrame.height), fallback: 44)
        let width = min(max(abs(rawWidth), minimumDimension), maximumDimension)
        let height = min(max(abs(rawHeight), minimumDimension), maximumDimension)
        var x = finiteClamped(CGFloat(rawFrame.x), fallback: sourceBounds.minX)
        var y = finiteClamped(CGFloat(rawFrame.y), fallback: sourceBounds.minY)
        if rawWidth < 0 { x -= width }
        if rawHeight < 0 { y -= height }
        let coordinatePadding = maximumDimension
        x = min(max(x, sourceBounds.minX - coordinatePadding), sourceBounds.maxX + coordinatePadding)
        y = min(max(y, sourceBounds.minY - coordinatePadding), sourceBounds.maxY + coordinatePadding)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func canonicalPoint(
        _ point: CanvasPoint,
        fallback: CGPoint,
        around frame: CGRect
    ) -> CGPoint {
        let padding = min(max(max(frame.width, frame.height) * 4, 44), maximumGeometryMagnitude)
        let x = finiteClamped(CGFloat(point.x), fallback: fallback.x)
        let y = finiteClamped(CGFloat(point.y), fallback: fallback.y)
        return CGPoint(
            x: min(max(x, frame.minX - padding), frame.maxX + padding),
            y: min(max(y, frame.minY - padding), frame.maxY + padding)
        )
    }

    private static func canonicalRotation(_ rawValue: Double) -> CGFloat {
        guard rawValue.isFinite else { return 0 }
        let fullTurn = Double.pi * 2
        var angle = rawValue.truncatingRemainder(dividingBy: fullTurn)
        if angle >= Double.pi {
            angle -= fullTurn
        } else if angle < -Double.pi {
            angle += fullTurn
        }
        return CGFloat(angle)
    }

    private static func canonicalUnit(_ value: Double, fallback: CGFloat) -> CGFloat {
        guard value.isFinite else { return fallback }
        return min(max(CGFloat(value), 0), 1)
    }

    private static func color(_ value: RGBAColor) -> UIColor {
        UIColor(
            red: canonicalUnit(value.red, fallback: 0),
            green: canonicalUnit(value.green, fallback: 0),
            blue: canonicalUnit(value.blue, fallback: 0),
            alpha: canonicalUnit(value.alpha, fallback: 1)
        )
    }

    private static func finiteClamped(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        guard value.isFinite else { return fallback }
        return min(max(value, -maximumGeometryMagnitude), maximumGeometryMagnitude)
    }

    private static func finitePositive(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return fallback }
        // Keep scale divisions finite even when a corrupt document contains a positive
        // subnormal source or output dimension.
        return min(max(value, 1), maximumGeometryMagnitude)
    }

    private static func finiteClamped(
        _ value: Double,
        fallback: Double,
        minimum: Double,
        maximum: Double
    ) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, minimum), maximum)
    }

    private static func nonnegativeInsetRect(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: rect.minY,
            width: max(rect.width, 0),
            height: max(rect.height, 0)
        )
    }

    private static func boundedString(_ value: String, utf16Limit: Int) -> String {
        let string = value as NSString
        guard string.length > utf16Limit else { return value }
        var length = utf16Limit
        if length > 0 {
            let finalUnit = string.character(at: length - 1)
            if (0xD800 ... 0xDBFF).contains(finalUnit) {
                length -= 1
            }
        }
        return string.substring(to: max(length, 0))
    }

    private static func aspectFitRect(for size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return bounds
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: bounds.midX - fitted.width / 2,
            y: bounds.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private static func aspectFillRect(for size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return bounds
        }
        let scale = max(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: bounds.midX - fitted.width / 2,
            y: bounds.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}
