import ImageIO
import PDFKit
import PencilKit
import NotesCore
import UIKit

enum PageExportRenderError: LocalizedError, Equatable {
    case drawingDataLimitExceeded(limit: Int)
    case corruptDrawingData
    case drawingComplexityLimitExceeded(maximumStrokeCount: Int, maximumPointCount: Int)
    case pageElementLimitExceeded(limit: Int)
    case backgroundAssetUnavailable
    case backgroundAssetLimitExceeded(limit: Int)
    case corruptBackgroundAsset
    case backgroundPDFPageOutOfRange(pageIndex: Int)

    var errorDescription: String? {
        switch self {
        case .drawingDataLimitExceeded(let limit):
            String.localizedStringWithFormat(
                String(localized: "This page's ink data exceeds the %lld MB export limit."),
                Int64(limit / 1_024 / 1_024)
            )
        case .corruptDrawingData:
            String(localized: "This page's ink data is damaged and cannot be exported.")
        case .drawingComplexityLimitExceeded:
            String(localized: "This page's ink is too complex to export safely.")
        case .pageElementLimitExceeded(let limit):
            String.localizedStringWithFormat(
                String(localized: "This page has more than %lld elements and cannot be exported."),
                Int64(limit)
            )
        case .backgroundAssetUnavailable:
            String(localized: "This page's background file is missing or unsafe.")
        case .backgroundAssetLimitExceeded(let limit):
            String.localizedStringWithFormat(
                String(localized: "This page's background file exceeds the %lld MB export limit."),
                Int64(limit / 1_024 / 1_024)
            )
        case .corruptBackgroundAsset:
            String(localized: "This page's background file is damaged or unsupported.")
        case .backgroundPDFPageOutOfRange:
            String(localized: "This page's selected PDF background page is unavailable.")
        }
    }
}

struct PageExportDrawingComplexity: Equatable {
    let strokeCount: Int
    let pointCount: Int
}

/// Persistence/import contract for ink that may enter the export renderer.
///
/// The serialized byte ceiling bounds parser input. These structural ceilings bound the
/// post-decode work handed to PencilKit's rasterizer. Validation is intentionally available
/// independently of PencilKit so importers and stress tests can enforce the same contract.
enum PageExportDrawingComplexityContract {
    static let maximumStrokeCount = 10_000
    static let maximumPointCount = 1_000_000

    static func validate<S: Sequence>(
        strokePointCounts: S
    ) throws -> PageExportDrawingComplexity where S.Element == Int {
        var strokeCount = 0
        var pointCount = 0

        for count in strokePointCounts {
            try Task.checkCancellation()
            guard count >= 0,
                  strokeCount < maximumStrokeCount,
                  pointCount <= maximumPointCount - count else {
                throw PageExportRenderError.drawingComplexityLimitExceeded(
                    maximumStrokeCount: maximumStrokeCount,
                    maximumPointCount: maximumPointCount
                )
            }
            strokeCount += 1
            pointCount += count
        }

        return PageExportDrawingComplexity(
            strokeCount: strokeCount,
            pointCount: pointCount
        )
    }
}

/// Main-actor-only decoded ink. Keeping this representation beside a streaming page snapshot
/// prevents the artifact writer from decoding the same untrusted PencilKit payload a second time.
@MainActor
struct PageExportPreparedDrawing {
    fileprivate let drawing: PKDrawing?
    let complexity: PageExportDrawingComplexity

    var isEmpty: Bool { complexity.strokeCount == 0 }

    fileprivate static let empty = PageExportPreparedDrawing(
        drawing: nil,
        complexity: PageExportDrawingComplexity(strokeCount: 0, pointCount: 0)
    )
}

/// Main-actor-only background material decoded once from a bounded, validated regular file.
/// Export drawing never reopens the source URL, so a missing/replaced asset cannot turn into a
/// silently white page after snapshot validation.
@MainActor
struct PageExportPreparedBackground {
    fileprivate enum Content {
        case paper(PaperTemplate)
        case rasterImage(UIImage)
        case pdfPage(document: CGPDFDocument, page: CGPDFPage)
    }

    let sourceBackground: PageBackground
    fileprivate let content: Content

    var rasterPixelSize: CGSize? {
        guard case .rasterImage(let image) = content,
              let cgImage = image.cgImage else { return nil }
        return CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
    }
}

struct PageExportRenderPlan: Equatable {
    static let preferredDrawingRasterScale: CGFloat = 2
    /// Hard pixel-edge limit passed to `PKDrawing.image(from:scale:)`.
    static let maximumDrawingRasterDimension: CGFloat = 4_096
    /// Hard estimate for the decoded RGBA backing store (four bytes per pixel).
    static let maximumDrawingRasterBytes = 64 * 1_024 * 1_024
    /// Keeps oversized whiteboards usable in common PDF viewers while ordinary
    /// notebook pages retain their native media-box dimensions.
    static let maximumPDFDimension: CGFloat = 1_440

    let sourceBounds: CGRect
    let pdfBounds: CGRect
    let drawingRasterScale: CGFloat

    init(pageSize: CGSize) {
        let sourceWidth = Self.normalizedDimension(pageSize.width)
        let sourceHeight = Self.normalizedDimension(pageSize.height)
        sourceBounds = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)

        let longestSourceDimension = max(sourceWidth, sourceHeight)
        let pdfScale = min(1, Self.maximumPDFDimension / longestSourceDimension)
        pdfBounds = CGRect(
            x: 0,
            y: 0,
            width: max(sourceWidth * pdfScale, 1),
            height: max(sourceHeight * pdfScale, 1)
        )

        let dimensionScale = Self.maximumDrawingRasterDimension / longestSourceDimension
        let maximumPixelCount = CGFloat(Self.maximumDrawingRasterBytes / 4)
        let memoryScale = sqrt(maximumPixelCount / (sourceWidth * sourceHeight))
        var candidate = min(
            Self.preferredDrawingRasterScale,
            dimensionScale,
            memoryScale
        )
        candidate = max(candidate, .leastNonzeroMagnitude)

        // Floating-point rounding can otherwise turn an exact 4096-pixel edge
        // into 4097 after UIImage rounds up. Tighten the scale until both hard
        // limits hold for the actual integral raster dimensions.
        for _ in 0 ..< 4 {
            let rasterWidth = ceil(sourceWidth * candidate)
            let rasterHeight = ceil(sourceHeight * candidate)
            let dimensionRatio = Self.maximumDrawingRasterDimension / max(rasterWidth, rasterHeight)
            let memoryRatio = sqrt(maximumPixelCount / (rasterWidth * rasterHeight))
            guard dimensionRatio < 1 || memoryRatio < 1 else { break }
            candidate *= min(dimensionRatio, memoryRatio) * 0.999_999
        }
        drawingRasterScale = candidate
    }

    var drawingRasterPixelSize: CGSize {
        CGSize(
            width: ceil(sourceBounds.width * drawingRasterScale),
            height: ceil(sourceBounds.height * drawingRasterScale)
        )
    }

    var estimatedDrawingRasterBytes: Int {
        let pixelSize = drawingRasterPixelSize
        guard pixelSize.width.isFinite,
              pixelSize.height.isFinite,
              pixelSize.width <= CGFloat(Int.max / 4),
              pixelSize.height <= CGFloat(Int.max / 4) else {
            return Self.maximumDrawingRasterBytes
        }
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        guard width == 0 || height <= Int.max / width / 4 else {
            return Self.maximumDrawingRasterBytes
        }
        return width * height * 4
    }

    private static func normalizedDimension(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 1 }
        // Subnormal positive values are technically finite but can make the later
        // output/source transform overflow to infinity. A sub-point page is not useful output.
        return max(value, 1)
    }
}

enum PageInkRecognitionRasterError: Error, Equatable {
    case invalidPageSize
    case invalidRenderedImage
}

/// A dedicated raster contract for on-device handwriting recognition.
///
/// This plan is intentionally independent from export rendering: OCR never needs a page's
/// background or structured elements, and its transient bitmap can use a smaller memory budget.
/// Source dimensions stay in PencilKit's page coordinate space while the output is bounded by
/// both an integral pixel edge and an RGBA byte estimate.
struct PageInkRecognitionRasterPlan: Equatable {
    static let preferredRasterScale: CGFloat = 3
    static let maximumRasterDimension: CGFloat = 3_072
    static let maximumRasterBytes = 32 * 1_024 * 1_024

    let sourceBounds: CGRect
    let rasterScale: CGFloat

    init(pageSize: CGSize) throws {
        guard pageSize.width.isFinite,
              pageSize.height.isFinite,
              pageSize.width > 0,
              pageSize.height > 0 else {
            throw PageInkRecognitionRasterError.invalidPageSize
        }

        sourceBounds = CGRect(origin: .zero, size: pageSize)
        let longestSourceDimension = max(pageSize.width, pageSize.height)
        let maximumPixelCount = CGFloat(Self.maximumRasterBytes / 4)
        let dimensionScale = Self.maximumRasterDimension / longestSourceDimension

        // Dividing the shorter edge first avoids overflowing `width * height` for a finite but
        // pathological caller-provided size. The ratio is in 0...1, so the square root remains
        // bounded and well-defined.
        let shortestSourceDimension = min(pageSize.width, pageSize.height)
        let aspectRatio = shortestSourceDimension / longestSourceDimension
        let maximumMemoryEdge = aspectRatio > 0
            ? sqrt(maximumPixelCount / aspectRatio)
            : Self.maximumRasterDimension
        let memoryScale = min(maximumMemoryEdge, Self.maximumRasterDimension)
            / longestSourceDimension

        var candidate = min(
            Self.preferredRasterScale,
            dimensionScale,
            memoryScale
        )
        guard candidate.isFinite, candidate > 0 else {
            throw PageInkRecognitionRasterError.invalidPageSize
        }

        // Account for integral pixel rounding before handing the bounds to PencilKit. Tightening
        // the scale also makes the same plan safe for the final opaque UIKit bitmap.
        for _ in 0 ..< 6 {
            let pixelSize = Self.pixelSize(for: pageSize, scale: candidate)
            let dimensionRatio = Self.maximumRasterDimension
                / max(pixelSize.width, pixelSize.height)
            let memoryRatio = sqrt(
                maximumPixelCount / (pixelSize.width * pixelSize.height)
            )
            guard dimensionRatio < 1 || memoryRatio < 1 else { break }
            candidate *= min(dimensionRatio, memoryRatio) * 0.999_999
        }

        let finalPixelSize = Self.pixelSize(for: pageSize, scale: candidate)
        guard finalPixelSize.width <= Self.maximumRasterDimension,
              finalPixelSize.height <= Self.maximumRasterDimension,
              finalPixelSize.width * finalPixelSize.height * 4
                <= CGFloat(Self.maximumRasterBytes) else {
            throw PageInkRecognitionRasterError.invalidPageSize
        }
        rasterScale = candidate
    }

    var rasterPixelSize: CGSize {
        Self.pixelSize(for: sourceBounds.size, scale: rasterScale)
    }

    var estimatedRasterBytes: Int {
        let pixelSize = rasterPixelSize
        return Int(pixelSize.width) * Int(pixelSize.height) * 4
    }

    private static func pixelSize(for sourceSize: CGSize, scale: CGFloat) -> CGSize {
        CGSize(
            width: max(ceil(sourceSize.width * scale), 1),
            height: max(ceil(sourceSize.height * scale), 1)
        )
    }
}

@MainActor
enum PageExportRenderer {
    /// Bounds untrusted PencilKit source data before `PKDrawing(data:)` can decode it. The
    /// raster limits below bound decoded output, but do not by themselves bound parser input.
    static let maximumDrawingDataBytes = NotebookExportReadLimits.maximumInkBytes
    /// OCR accepts only the current durable ink payload and uses a deliberately tighter parser
    /// ceiling than artifact export. This is checked before `PKDrawing(data:)` is entered.
    static let maximumRecognitionDrawingDataBytes = 16 * 1_024 * 1_024
    static let maximumBackgroundAssetBytes = NotebookExportReadLimits.maximumBackgroundAssetBytes
    static let maximumBackgroundRasterBytes = 64 * 1_024 * 1_024
    static let maximumBackgroundRasterDimension: CGFloat = 4_096
    static let maximumBackgroundPDFPageCount = 10_000
    static let minimumBackgroundPDFDimension: CGFloat = 0.01
    static let maximumBackgroundPDFCoordinateMagnitude: CGFloat = 1_000_000
    static let maximumBackgroundPDFTransformMagnitude: CGFloat = 1_000_000

    /// Decodes and structurally validates PencilKit data exactly once for a page export.
    ///
    /// Residual iPadOS 18 limitation: `PKDrawing(data:)` is a synchronous framework call with no
    /// cancellation hook. The source byte cap bounds its input, and cancellation is checked both
    /// immediately before and after it, but an in-flight decode cannot be preempted. Likewise,
    /// `PKDrawing.image(from:scale:)` is synchronous; the structural and raster contracts bound the
    /// work passed to it, while cancellation can only be observed at the surrounding boundaries.
    static func prepareDrawing(_ drawingData: Data?) throws -> PageExportPreparedDrawing {
        try Task.checkCancellation()
        guard let drawingData else {
            return .empty
        }
        guard !drawingData.isEmpty else {
            throw PageExportRenderError.corruptDrawingData
        }
        guard drawingData.count <= maximumDrawingDataBytes else {
            throw PageExportRenderError.drawingDataLimitExceeded(
                limit: maximumDrawingDataBytes
            )
        }

        try Task.checkCancellation()
        let drawing: PKDrawing
        do {
            drawing = try PKDrawing(data: drawingData)
        } catch {
            throw PageExportRenderError.corruptDrawingData
        }
        try Task.checkCancellation()

        let complexity = try PageExportDrawingComplexityContract.validate(
            strokePointCounts: drawing.strokes.lazy.map { $0.path.count }
        )
        try Task.checkCancellation()
        return PageExportPreparedDrawing(
            drawing: complexity.strokeCount == 0 ? nil : drawing,
            complexity: complexity
        )
    }

    /// Validates and decodes a page background once. ImageIO and PDFKit receive at most a bounded
    /// regular-file payload, and the retained raster is checked against both edge and RGBA limits.
    /// Synchronous framework decoding remains non-preemptible while in flight; cancellation is
    /// checked immediately around every such call.
    static func prepareBackground(
        _ resolved: ResolvedPageBackground,
        for page: EditorPage,
        outputPixelSize: CGSize
    ) throws -> PageExportPreparedBackground {
        try Task.checkCancellation()
        guard resolved.background == page.background else {
            throw PageExportRenderError.backgroundAssetUnavailable
        }

        switch page.background {
        case .paper(let template):
            guard resolved.assetURL == nil,
                  resolved.assetData == nil else {
                throw PageExportRenderError.backgroundAssetUnavailable
            }
            return PageExportPreparedBackground(
                sourceBackground: page.background,
                content: .paper(template)
            )
        case .image(let assetPath):
            let data = try validatedBackgroundData(
                from: resolved,
                relativeAssetPath: assetPath
            )
            try Task.checkCancellation()
            let maximumDimension = boundedBackgroundDimension(for: outputPixelSize)
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
                throw PageExportRenderError.corruptBackgroundAsset
            }
            try Task.checkCancellation()
            let thumbnailOptions: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(maximumDimension),
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                thumbnailOptions as CFDictionary
            ) else {
                throw PageExportRenderError.corruptBackgroundAsset
            }
            try Task.checkCancellation()
            let image = UIImage(cgImage: cgImage)
            try validatePreparedBackgroundImage(image)
            return PageExportPreparedBackground(
                sourceBackground: page.background,
                content: .rasterImage(image)
            )
        case .pdf(let assetPath, let pageIndex):
            let data = try validatedBackgroundData(
                from: resolved,
                relativeAssetPath: assetPath
            )
            try Task.checkCancellation()
            guard let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider),
                  !document.isEncrypted,
                  document.numberOfPages > 0,
                  document.numberOfPages <= maximumBackgroundPDFPageCount else {
                throw PageExportRenderError.corruptBackgroundAsset
            }
            guard pageIndex >= 0,
                  pageIndex < document.numberOfPages,
                  let pdfPage = document.page(at: pageIndex + 1) else {
                throw PageExportRenderError.backgroundPDFPageOutOfRange(
                    pageIndex: pageIndex
                )
            }
            let mediaBox = pdfPage.getBoxRect(.mediaBox).standardized
            let mediaBoxComponents = [
                mediaBox.minX,
                mediaBox.minY,
                mediaBox.maxX,
                mediaBox.maxY,
                mediaBox.width,
                mediaBox.height,
            ]
            guard mediaBoxComponents.allSatisfy({
                $0.isFinite && abs($0) <= maximumBackgroundPDFCoordinateMagnitude
            }),
            mediaBox.width >= minimumBackgroundPDFDimension,
            mediaBox.height >= minimumBackgroundPDFDimension else {
                throw PageExportRenderError.corruptBackgroundAsset
            }
            let destinations = [
                renderPlan(for: page).pdfBounds,
                CGRect(origin: .zero, size: outputPixelSize),
            ]
            guard destinations.allSatisfy({ destination in
                guard destination.minX.isFinite,
                      destination.minY.isFinite,
                      destination.width.isFinite,
                      destination.height.isFinite,
                      destination.width > 0,
                      destination.height > 0 else { return false }
                let transform = pdfPage.getDrawingTransform(
                    .mediaBox,
                    rect: destination,
                    rotate: 0,
                    preserveAspectRatio: true
                )
                return [
                    transform.a,
                    transform.b,
                    transform.c,
                    transform.d,
                    transform.tx,
                    transform.ty,
                ].allSatisfy {
                    $0.isFinite && abs($0) <= maximumBackgroundPDFTransformMagnitude
                }
            }) else {
                throw PageExportRenderError.corruptBackgroundAsset
            }
            try Task.checkCancellation()
            return PageExportPreparedBackground(
                sourceBackground: page.background,
                content: .pdfPage(document: document, page: pdfPage)
            )
        }
    }

    static func renderPlan(for page: EditorPage) -> PageExportRenderPlan {
        PageExportRenderPlan(pageSize: CGSize(width: page.width, height: page.height))
    }

    static func renderPDF(
        page: EditorPage,
        background: ResolvedPageBackground,
        drawingData: Data?,
        canvasElements: [CanvasElement] = [],
        assetImageResolver: CanvasElementExportImageResolver = { _, _ in nil }
    ) throws -> Data {
        try validateElementCount(canvasElements)
        let plan = renderPlan(for: page)
        let preparedBackground = try prepareBackground(
            background,
            for: page,
            outputPixelSize: plan.drawingRasterPixelSize
        )
        let preparedDrawing = try prepareDrawing(drawingData)
        try Task.checkCancellation()
        let renderer = UIGraphicsPDFRenderer(bounds: plan.pdfBounds)
        var cancellationDetected = false
        let data = autoreleasepool {
            renderer.pdfData { context in
                guard !Task.isCancelled else {
                    cancellationDetected = true
                    return
                }
                context.beginPage()
                drawPDFPageContent(
                    preparedBackground: preparedBackground,
                    preparedDrawing: preparedDrawing,
                    canvasElements: canvasElements,
                    plan: plan,
                    context: context,
                    assetImageResolver: assetImageResolver
                )
                cancellationDetected = Task.isCancelled
            }
        }
        guard !cancellationDetected else { throw CancellationError() }
        try Task.checkCancellation()
        return data
    }

    /// Draws one already-open PDF page. Whole-notebook export uses this entry point so the
    /// single-page and multi-page paths cannot drift in their background, ink, element, or link
    /// behavior. The caller owns `beginPage` because a notebook can use a different media box for
    /// every page.
    /// - Precondition: `canvasElements` was accepted by `validateElementCount(_:)`.
    static func drawPDFPageContent(
        preparedBackground: PageExportPreparedBackground,
        preparedDrawing: PageExportPreparedDrawing,
        canvasElements: [CanvasElement],
        plan: PageExportRenderPlan,
        context: UIGraphicsPDFRendererContext,
        assetImageResolver: CanvasElementExportImageResolver,
        linkAnnotationObserver: ((URL, CGRect) -> Void)? = nil
    ) {
        assert(canvasElements.count <= CanvasElementExportRenderer.maximumElementCount)
        guard !Task.isCancelled else { return }
        drawBackground(preparedBackground, in: plan.pdfBounds, context: context.cgContext)
        guard !Task.isCancelled else { return }
        drawInk(preparedDrawing, plan: plan, in: plan.pdfBounds)
        guard !Task.isCancelled else { return }
        CanvasElementExportRenderer.draw(
            elements: canvasElements,
            sourceBounds: plan.sourceBounds,
            outputBounds: plan.pdfBounds,
            rasterScale: plan.drawingRasterScale,
            context: context.cgContext,
            assetImageResolver: assetImageResolver,
            linkAnnotationHandler: { url, rect in
                // UIKit drawing is top-left/y-down, while setURL expects the PDF page's
                // bottom-left/y-up coordinate space. Use the renderer context's public
                // user-to-device transform as recommended by UIKit.
                let pdfRect = rect
                    .applying(context.cgContext.userSpaceToDeviceSpaceTransform)
                    .standardized
                context.setURL(url, for: pdfRect)
                linkAnnotationObserver?(url, pdfRect)
            }
        )
    }

    /// Produces a bounded, one-pixel-per-output-point raster using the same 4,096 edge and
    /// 64 MiB backing-store plan as PencilKit export. Structured elements remain vector-drawn
    /// into the output bitmap; local image assets are requested at their bounded target size.
    static func renderRasterImage(
        page: EditorPage,
        background: ResolvedPageBackground,
        drawingData: Data?,
        canvasElements: [CanvasElement] = [],
        assetImageResolver: CanvasElementExportImageResolver = { _, _ in nil }
    ) throws -> UIImage {
        try validateElementCount(canvasElements)
        let plan = renderPlan(for: page)
        let outputBounds = CGRect(origin: .zero, size: plan.drawingRasterPixelSize)
        let preparedBackground = try prepareBackground(
            background,
            for: page,
            outputPixelSize: outputBounds.size
        )
        let preparedDrawing = try prepareDrawing(drawingData)
        try Task.checkCancellation()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: outputBounds.size, format: format)
        var cancellationDetected = false
        let image = autoreleasepool {
            renderer.image { context in
                guard !Task.isCancelled else {
                    cancellationDetected = true
                    return
                }
                drawBackground(preparedBackground, in: outputBounds, context: context.cgContext)
                guard !Task.isCancelled else {
                    cancellationDetected = true
                    return
                }
                drawInk(preparedDrawing, plan: plan, in: outputBounds)
                guard !Task.isCancelled else {
                    cancellationDetected = true
                    return
                }
                CanvasElementExportRenderer.draw(
                    elements: canvasElements,
                    sourceBounds: plan.sourceBounds,
                    outputBounds: outputBounds,
                    rasterScale: plan.drawingRasterScale,
                    context: context.cgContext,
                    assetImageResolver: assetImageResolver
                )
                cancellationDetected = Task.isCancelled
            }
        }
        guard !cancellationDetected else { throw CancellationError() }
        try Task.checkCancellation()
        return image
    }

    /// Produces an opaque-white, ink-only page raster for on-device handwriting recognition.
    ///
    /// The caller supplies the durable serialized drawing rather than a live `PKDrawing`. Decode,
    /// structural validation, and PencilKit rasterization all remain on the main actor, so no
    /// PencilKit reference crosses an actor boundary. Background assets and canvas elements are
    /// intentionally not accepted by this API and therefore cannot leak into OCR input.
    ///
    /// Residual iPadOS 18 limitation: PencilKit decode and image generation are synchronous and
    /// cannot be preempted once started. Input, stroke/point, edge, and RGBA limits bound that work;
    /// cancellation is observed immediately before and after each framework call.
    static func renderInkOnlyRecognitionImage(
        drawingData: Data,
        pageSize: CGSize
    ) throws -> UIImage {
        try Task.checkCancellation()
        guard drawingData.count <= maximumRecognitionDrawingDataBytes else {
            throw PageExportRenderError.drawingDataLimitExceeded(
                limit: maximumRecognitionDrawingDataBytes
            )
        }

        let plan = try PageInkRecognitionRasterPlan(pageSize: pageSize)
        try Task.checkCancellation()
        let preparedDrawing = try prepareDrawing(drawingData)
        try Task.checkCancellation()

        let inkImage: UIImage?
        if let drawing = preparedDrawing.drawing, !preparedDrawing.isEmpty {
            try Task.checkCancellation()
            inkImage = autoreleasepool {
                drawing.image(from: plan.sourceBounds, scale: plan.rasterScale)
            }
            try Task.checkCancellation()
        } else {
            inkImage = nil
        }

        let outputBounds = CGRect(origin: .zero, size: plan.rasterPixelSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        try Task.checkCancellation()
        let renderer = UIGraphicsImageRenderer(size: outputBounds.size, format: format)
        var cancellationDetected = false
        let image = autoreleasepool {
            renderer.image { context in
                guard !Task.isCancelled else {
                    cancellationDetected = true
                    return
                }
                UIColor.white.setFill()
                context.fill(outputBounds)
                guard !Task.isCancelled else {
                    cancellationDetected = true
                    return
                }
                // PencilKit preserves the user's display color. White and other light inks are
                // perfectly valid on dark paper, but would disappear on this deliberately white
                // OCR canvas. Tint from the image's alpha mask so every visible stroke reaches
                // Vision as high-contrast ink without admitting the original page background.
                inkImage?
                    .withTintColor(.black, renderingMode: .alwaysOriginal)
                    .draw(in: outputBounds)
                cancellationDetected = Task.isCancelled
            }
        }
        guard !cancellationDetected else { throw CancellationError() }
        try Task.checkCancellation()

        guard let cgImage = image.cgImage,
              cgImage.width == Int(plan.rasterPixelSize.width),
              cgImage.height == Int(plan.rasterPixelSize.height),
              cgImage.bytesPerRow > 0,
              cgImage.height > 0,
              cgImage.bytesPerRow <= PageInkRecognitionRasterPlan.maximumRasterBytes
                / cgImage.height else {
            throw PageInkRecognitionRasterError.invalidRenderedImage
        }
        switch cgImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            break
        default:
            throw PageInkRecognitionRasterError.invalidRenderedImage
        }
        return image
    }

    static func validateElementCount(_ canvasElements: [CanvasElement]) throws {
        try Task.checkCancellation()
        guard canvasElements.count <= CanvasElementExportRenderer.maximumElementCount else {
            throw PageExportRenderError.pageElementLimitExceeded(
                limit: CanvasElementExportRenderer.maximumElementCount
            )
        }
    }

    private static func validatedBackgroundData(
        from resolved: ResolvedPageBackground,
        relativeAssetPath: String
    ) throws -> Data {
        try Task.checkCancellation()
        guard safeRelativeAssetPathComponents(relativeAssetPath) != nil,
              resolved.assetURL == nil,
              let data = resolved.assetData else {
            throw PageExportRenderError.backgroundAssetUnavailable
        }
        guard data.count <= maximumBackgroundAssetBytes else {
            throw PageExportRenderError.backgroundAssetLimitExceeded(
                limit: maximumBackgroundAssetBytes
            )
        }
        // LocalNotebookStore supplies an owned buffer produced by NotesCore's bounded descriptor
        // reader. ImageIO/Core Graphics never reopen a path or retain a lazy mapped file.
        return data
    }

    private static func safeRelativeAssetPathComponents(_ relativePath: String) -> [String]? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.hasSuffix("/"),
              !relativePath.contains("\\") else { return nil }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return nil
        }
        return components
    }

    private static func boundedBackgroundDimension(for outputPixelSize: CGSize) -> CGFloat {
        let width = outputPixelSize.width.isFinite ? max(outputPixelSize.width, 1) : 1
        let height = outputPixelSize.height.isFinite ? max(outputPixelSize.height, 1) : 1
        return min(
            ceil(max(width, height)),
            maximumBackgroundRasterDimension
        )
    }

    private static func validatePreparedBackgroundImage(_ image: UIImage) throws {
        guard let cgImage = image.cgImage,
              cgImage.width > 0,
              cgImage.height > 0,
              cgImage.width <= Int(maximumBackgroundRasterDimension),
              cgImage.height <= Int(maximumBackgroundRasterDimension),
              cgImage.bytesPerRow > 0,
              cgImage.bytesPerRow <= maximumBackgroundRasterBytes / cgImage.height else {
            throw PageExportRenderError.corruptBackgroundAsset
        }
    }

    static func temporaryPDF(
        title: String,
        page: EditorPage,
        background: ResolvedPageBackground,
        drawingData: Data?,
        canvasElements: [CanvasElement] = [],
        assetImageResolver: CanvasElementExportImageResolver = { _, _ in nil }
    ) throws -> URL {
        let invalid = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ ")).inverted
        let safeTitle = title.components(separatedBy: invalid).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = safeTitle.isEmpty ? "NextStep Page" : String(safeTitle.prefix(80))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(filename)-\(page.id.uuidString.prefix(8)).pdf")
        try renderPDF(
            page: page,
            background: background,
            drawingData: drawingData,
            canvasElements: canvasElements,
            assetImageResolver: assetImageResolver
        )
            .write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    private static func drawInk(
        _ preparedDrawing: PageExportPreparedDrawing,
        plan: PageExportRenderPlan,
        in outputBounds: CGRect
    ) {
        guard !Task.isCancelled,
              let drawing = preparedDrawing.drawing,
              !preparedDrawing.isEmpty else { return }
        autoreleasepool {
            drawing.image(from: plan.sourceBounds, scale: plan.drawingRasterScale)
                .draw(in: outputBounds)
        }
    }

    private static func drawBackground(
        _ prepared: PageExportPreparedBackground,
        in bounds: CGRect,
        context: CGContext
    ) {
        UIColor.white.setFill()
        context.fill(bounds)

        switch prepared.content {
        case .paper(let template):
            draw(template: template, in: bounds, context: context)
        case .rasterImage(let image):
            image.draw(in: aspectFitRect(for: image.size, in: bounds))
        case .pdfPage(_, let page):
            context.saveGState()
            // UIKit supplies a top-left/y-down user space. Flip once to Quartz PDF space, then
            // apply Core Graphics' box/rotation-aware aspect-fit transform. Drawing into a PDF
            // context preserves the imported page's vector operators; raster export remains
            // bounded by its existing 4,096-edge/64-MiB destination bitmap.
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.concatenate(page.getDrawingTransform(
                .mediaBox,
                rect: bounds,
                rotate: 0,
                preserveAspectRatio: true
            ))
            context.drawPDFPage(page)
            context.restoreGState()
        }
    }

    private static func draw(template: PaperTemplate, in bounds: CGRect, context: CGContext) {
        guard template != .blank else { return }
        let layout = PageTemplateLayout(bounds: bounds)
        let color = UIColor.systemBlue.withAlphaComponent(0.16).cgColor
        context.saveGState()
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(layout.lineWidth)

        switch template {
        case .blank:
            break
        case .ruled:
            for row in 0 ..< layout.ruledLineCount {
                let y = bounds.minY + layout.margin + CGFloat(row) * layout.spacing
                context.move(to: CGPoint(x: bounds.minX + layout.margin, y: y))
                context.addLine(to: CGPoint(x: bounds.maxX - layout.margin, y: y))
            }
            context.strokePath()
        case .grid:
            for row in 0 ..< layout.gridRowCount {
                let y = bounds.minY + CGFloat(row) * layout.spacing
                context.move(to: CGPoint(x: bounds.minX, y: y))
                context.addLine(to: CGPoint(x: bounds.maxX, y: y))
            }
            for column in 0 ..< layout.gridColumnCount {
                let x = bounds.minX + layout.margin + CGFloat(column) * layout.spacing
                context.move(to: CGPoint(x: x, y: bounds.minY))
                context.addLine(to: CGPoint(x: x, y: bounds.maxY))
            }
            context.strokePath()
        case .dots:
            var marksDrawn = 0
            dotRows: for row in 0 ..< layout.dotRowCount {
                let y = bounds.minY + layout.margin + CGFloat(row) * layout.spacing
                for column in 0 ..< layout.dotColumnCount {
                    guard marksDrawn < PageTemplateLayout.maximumDotMarkCount else {
                        break dotRows
                    }
                    let x = bounds.minX + layout.margin + CGFloat(column) * layout.spacing
                    context.fillEllipse(in: CGRect(
                        x: x - layout.dotRadius,
                        y: y - layout.dotRadius,
                        width: layout.dotRadius * 2,
                        height: layout.dotRadius * 2
                    ))
                    marksDrawn += 1
                }
            }
        }
        context.restoreGState()
    }

    private static func aspectFitRect(for size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: bounds.midX - fitted.width / 2,
            y: bounds.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}
