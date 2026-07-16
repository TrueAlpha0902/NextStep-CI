import PDFKit
import NotesCore
import PencilKit
import UIKit
import XCTest
@testable import NotesApp

final class PageExportRendererTests: XCTestCase {
    @MainActor
    func testWhiteboardExportCapsInkRasterAndNormalizesPDFPage() {
        let page = EditorPage(
            kind: .whiteboard,
            background: .paper(.dots),
            width: EditorPage.whiteboardWidth,
            height: EditorPage.whiteboardHeight
        )

        let plan = PageExportRenderer.renderPlan(for: page)

        XCTAssertEqual(plan.sourceBounds.size, CGSize(width: 3_200, height: 2_400))
        XCTAssertEqual(plan.pdfBounds.size, CGSize(width: 1_440, height: 1_080))
        XCTAssertEqual(plan.drawingRasterScale, 1.28, accuracy: 0.001)
        XCTAssertLessThanOrEqual(
            max(plan.drawingRasterPixelSize.width, plan.drawingRasterPixelSize.height),
            PageExportRenderPlan.maximumDrawingRasterDimension
        )
        XCTAssertLessThanOrEqual(
            plan.estimatedDrawingRasterBytes,
            PageExportRenderPlan.maximumDrawingRasterBytes
        )
    }

    func testStandardNotebookRetainsNativePDFSizeAndPreferredInkScale() {
        let plan = PageExportRenderPlan(pageSize: CGSize(width: 768, height: 1_024))

        XCTAssertEqual(plan.pdfBounds.size, CGSize(width: 768, height: 1_024))
        XCTAssertEqual(
            plan.drawingRasterScale,
            PageExportRenderPlan.preferredDrawingRasterScale
        )
        XCTAssertEqual(plan.drawingRasterPixelSize, CGSize(width: 1_536, height: 2_048))
    }

    func testSquareCanvasAlsoHonorsRasterMemoryBudget() {
        let plan = PageExportRenderPlan(pageSize: CGSize(width: 10_000, height: 10_000))

        XCTAssertLessThanOrEqual(
            max(plan.drawingRasterPixelSize.width, plan.drawingRasterPixelSize.height),
            PageExportRenderPlan.maximumDrawingRasterDimension
        )
        XCTAssertLessThanOrEqual(
            plan.estimatedDrawingRasterBytes,
            PageExportRenderPlan.maximumDrawingRasterBytes
        )
        XCTAssertLessThanOrEqual(
            max(plan.pdfBounds.width, plan.pdfBounds.height),
            PageExportRenderPlan.maximumPDFDimension
        )
    }

    func testSubnormalPageDimensionsCannotCreateNonfiniteExportScale() {
        let plan = PageExportRenderPlan(pageSize: CGSize(
            width: CGFloat.leastNonzeroMagnitude,
            height: CGFloat.leastNonzeroMagnitude
        ))

        XCTAssertEqual(plan.sourceBounds.size, CGSize(width: 1, height: 1))
        XCTAssertEqual(plan.pdfBounds.size, CGSize(width: 1, height: 1))
        XCTAssertTrue(plan.drawingRasterScale.isFinite)
        XCTAssertEqual(plan.drawingRasterPixelSize, CGSize(width: 2, height: 2))
    }

    func testDottedTemplateKeepsDensityAcrossCanvasPreviewAndExport() {
        let canvas = PageTemplateLayout(
            bounds: CGRect(x: 0, y: 0, width: 3_200, height: 2_400)
        )
        let preview = PageTemplateLayout(
            bounds: CGRect(x: 0, y: 0, width: 160, height: 120),
            minimumVisibleLineWidth: 0.5,
            minimumVisibleDotRadius: 0.25
        )
        let export = PageTemplateLayout(
            bounds: CGRect(x: 0, y: 0, width: 1_440, height: 1_080)
        )

        XCTAssertEqual(canvas.dotColumnCount, preview.dotColumnCount)
        XCTAssertEqual(canvas.dotRowCount, preview.dotRowCount)
        XCTAssertEqual(canvas.dotMarkCount, preview.dotMarkCount)
        XCTAssertEqual(canvas.dotColumnCount, export.dotColumnCount)
        XCTAssertEqual(canvas.dotRowCount, export.dotRowCount)
        XCTAssertEqual(canvas.dotMarkCount, 450)
    }

    func testTemplateGeometryBoundsPathologicalMarkCounts() {
        let layout = PageTemplateLayout(
            bounds: CGRect(x: 0, y: 0, width: 1, height: CGFloat.greatestFiniteMagnitude)
        )

        XCTAssertLessThanOrEqual(
            layout.gridRowCount,
            PageTemplateLayout.maximumAxisMarkCount
        )
        XCTAssertLessThanOrEqual(
            layout.dotMarkCount,
            PageTemplateLayout.maximumDotMarkCount
        )
    }

    @MainActor
    func testRenderedWhiteboardPDFUsesPlannedMediaBox() throws {
        let page = EditorPage(
            kind: .whiteboard,
            background: .paper(.dots),
            width: EditorPage.whiteboardWidth,
            height: EditorPage.whiteboardHeight
        )
        let data = try PageExportRenderer.renderPDF(
            page: page,
            background: ResolvedPageBackground(background: page.background, assetURL: nil),
            drawingData: nil
        )

        let document = try XCTUnwrap(PDFDocument(data: data))
        let renderedPage = try XCTUnwrap(document.page(at: 0))
        let mediaBox = renderedPage.bounds(for: .mediaBox)
        XCTAssertEqual(mediaBox.width, 1_440, accuracy: 0.5)
        XCTAssertEqual(mediaBox.height, 1_080, accuracy: 0.5)
    }

    @MainActor
    func testRasterExportUsesExistingBoundedDrawingPlan() throws {
        let page = EditorPage(
            kind: .whiteboard,
            background: .paper(.blank),
            width: EditorPage.whiteboardWidth,
            height: EditorPage.whiteboardHeight
        )
        let plan = PageExportRenderer.renderPlan(for: page)

        let image = try PageExportRenderer.renderRasterImage(
            page: page,
            background: ResolvedPageBackground(background: page.background, assetURL: nil),
            drawingData: nil
        )

        let cgImage = try XCTUnwrap(image.cgImage)
        XCTAssertEqual(cgImage.width, Int(plan.drawingRasterPixelSize.width))
        XCTAssertEqual(cgImage.height, Int(plan.drawingRasterPixelSize.height))
        XCTAssertLessThanOrEqual(max(cgImage.width, cgImage.height), 4_096)
        XCTAssertLessThanOrEqual(cgImage.width * cgImage.height * 4, 64 * 1_024 * 1_024)
    }

    @MainActor
    func testRejectsOversizedPencilKitSourceBeforeDecode() throws {
        let page = EditorPage(width: 200, height: 300)
        let oversized = Data(count: PageExportRenderer.maximumDrawingDataBytes + 1)
        XCTAssertThrowsError(
            try PageExportRenderer.renderPDF(
                page: page,
                background: ResolvedPageBackground(
                    background: page.background,
                    assetURL: nil
                ),
                drawingData: Data()
            )
        ) { error in
            XCTAssertEqual(error as? PageExportRenderError, .corruptDrawingData)
        }

        XCTAssertThrowsError(
            try PageExportRenderer.renderPDF(
                page: page,
                background: ResolvedPageBackground(
                    background: page.background,
                    assetURL: nil
                ),
                drawingData: oversized
            )
        ) { error in
            XCTAssertEqual(
                error as? PageExportRenderError,
                .drawingDataLimitExceeded(
                    limit: PageExportRenderer.maximumDrawingDataBytes
                )
            )
        }
    }

    @MainActor
    func testRejectsCorruptPencilKitSourceInsteadOfRenderingBlankInk() {
        let page = EditorPage(width: 200, height: 300)

        XCTAssertThrowsError(
            try PageExportRenderer.renderPDF(
                page: page,
                background: ResolvedPageBackground(
                    background: page.background,
                    assetURL: nil
                ),
                drawingData: Data("not a PencilKit drawing".utf8)
            )
        ) { error in
            XCTAssertEqual(error as? PageExportRenderError, .corruptDrawingData)
        }
    }

    func testDrawingComplexityContractRejectsTenThousandAndFirstStroke() throws {
        let maximumStrokes = PageExportDrawingComplexityContract.maximumStrokeCount
        let boundary = try PageExportDrawingComplexityContract.validate(
            strokePointCounts: Array(repeating: 0, count: maximumStrokes)
        )
        XCTAssertEqual(boundary.strokeCount, maximumStrokes)

        XCTAssertThrowsError(
            try PageExportDrawingComplexityContract.validate(
                strokePointCounts: Array(repeating: 0, count: maximumStrokes + 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? PageExportRenderError,
                .drawingComplexityLimitExceeded(
                    maximumStrokeCount: maximumStrokes,
                    maximumPointCount: PageExportDrawingComplexityContract.maximumPointCount
                )
            )
        }
    }

    func testDrawingComplexityContractRejectsPointOverflowWithoutAllocatingPoints() {
        XCTAssertThrowsError(
            try PageExportDrawingComplexityContract.validate(
                strokePointCounts: [PageExportDrawingComplexityContract.maximumPointCount + 1]
            )
        ) { error in
            XCTAssertEqual(
                error as? PageExportRenderError,
                .drawingComplexityLimitExceeded(
                    maximumStrokeCount: PageExportDrawingComplexityContract.maximumStrokeCount,
                    maximumPointCount: PageExportDrawingComplexityContract.maximumPointCount
                )
            )
        }
    }

    @MainActor
    func testPreparedDrawingCapturesValidatedComplexityOnce() throws {
        let prepared = try PageExportRenderer.prepareDrawing(inkDrawingData())

        XCTAssertFalse(prepared.isEmpty)
        XCTAssertEqual(prepared.complexity.strokeCount, 1)
        XCTAssertEqual(prepared.complexity.pointCount, 2)
    }

    @MainActor
    func testSinglePageRenderersAcceptElementBoundaryAndRejectNextElement() throws {
        let element = CanvasElement(
            frame: CanvasRect(x: 0, y: 0, width: 10, height: 10),
            opacity: 0,
            content: .shape(ShapeElement(
                shape: "rectangle",
                strokeColor: RGBAColor(red: 0, green: 0, blue: 0)
            ))
        )
        let boundary = Array(
            repeating: element,
            count: CanvasElementExportRenderer.maximumElementCount
        )
        XCTAssertNoThrow(try PageExportRenderer.validateElementCount(boundary))

        let oversized = boundary + [element]
        let page = EditorPage(width: 100, height: 100)
        let background = ResolvedPageBackground(
            background: page.background,
            assetURL: nil
        )
        XCTAssertNoThrow(
            try PageExportRenderer.renderPDF(
                page: page,
                background: background,
                drawingData: nil,
                canvasElements: boundary
            )
        )
        XCTAssertThrowsError(
            try PageExportRenderer.renderPDF(
                page: page,
                background: background,
                drawingData: nil,
                canvasElements: oversized
            )
        ) { error in
            XCTAssertEqual(
                error as? PageExportRenderError,
                .pageElementLimitExceeded(
                    limit: CanvasElementExportRenderer.maximumElementCount
                )
            )
        }
        XCTAssertThrowsError(
            try PageExportRenderer.renderRasterImage(
                page: page,
                background: background,
                drawingData: nil,
                canvasElements: oversized
            )
        ) { error in
            XCTAssertEqual(
                error as? PageExportRenderError,
                .pageElementLimitExceeded(
                    limit: CanvasElementExportRenderer.maximumElementCount
                )
            )
        }
    }

    @MainActor
    func testPreparedImageBackgroundUsesTwoTimesExportRasterPlan() throws {
        let page = EditorPage(
            kind: .importedDocument,
            background: .image(assetPath: "assets/high-resolution.png"),
            width: 300,
            height: 400
        )
        let plan = PageExportRenderer.renderPlan(for: page)
        XCTAssertEqual(plan.drawingRasterPixelSize, CGSize(width: 600, height: 800))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(
            size: CGSize(width: 1_200, height: 1_600),
            format: format
        ).pngData { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 1_600))
        }
        let background = ResolvedPageBackground(
            background: page.background,
            assetURL: nil,
            assetData: data
        )

        let prepared = try PageExportRenderer.prepareBackground(
            background,
            for: page,
            outputPixelSize: plan.drawingRasterPixelSize
        )
        XCTAssertEqual(prepared.rasterPixelSize, plan.drawingRasterPixelSize)
    }

    @MainActor
    func testBackgroundExportRequiresOwnedDataAndRejectsCorruptOrMissingPDFPage() throws {
        let imagePage = EditorPage(
            kind: .importedDocument,
            background: .image(assetPath: "assets/image.png"),
            width: 100,
            height: 100
        )
        XCTAssertThrowsError(
            try PageExportRenderer.renderPDF(
                page: imagePage,
                background: ResolvedPageBackground(
                    background: imagePage.background,
                    assetURL: URL(fileURLWithPath: "/tmp/image.png")
                ),
                drawingData: nil
            )
        ) { error in
            XCTAssertEqual(error as? PageExportRenderError, .backgroundAssetUnavailable)
        }
        XCTAssertThrowsError(
            try PageExportRenderer.renderPDF(
                page: imagePage,
                background: ResolvedPageBackground(
                    background: imagePage.background,
                    assetURL: nil,
                    assetData: Data("not an image".utf8)
                ),
                drawingData: nil
            )
        ) { error in
            XCTAssertEqual(error as? PageExportRenderError, .corruptBackgroundAsset)
        }

        let sourcePDF = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        ).pdfData { context in
            context.beginPage()
        }
        let pdfPage = EditorPage(
            kind: .importedDocument,
            background: .pdf(assetPath: "assets/source.pdf", pageIndex: 1),
            width: 100,
            height: 100
        )
        XCTAssertThrowsError(
            try PageExportRenderer.renderPDF(
                page: pdfPage,
                background: ResolvedPageBackground(
                    background: pdfPage.background,
                    assetURL: nil,
                    assetData: sourcePDF
                ),
                drawingData: nil
            )
        ) { error in
            XCTAssertEqual(
                error as? PageExportRenderError,
                .backgroundPDFPageOutOfRange(pageIndex: 1)
            )
        }
    }

    @MainActor
    func testImportedPDFRejectsUnboundedMediaBoxBeforeDrawingTransform() throws {
        let sourcePDF = try pdfData(
            mediaBox: CGRect(
                x: 0,
                y: 0,
                width: PageExportRenderer.maximumBackgroundPDFCoordinateMagnitude + 1,
                height: 100
            )
        )
        let page = EditorPage(
            kind: .importedDocument,
            background: .pdf(assetPath: "assets/huge.pdf", pageIndex: 0),
            width: 100,
            height: 100
        )

        XCTAssertThrowsError(
            try PageExportRenderer.prepareBackground(
                ResolvedPageBackground(
                    background: page.background,
                    assetURL: nil,
                    assetData: sourcePDF
                ),
                for: page,
                outputPixelSize: CGSize(width: 200, height: 200)
            )
        ) { error in
            XCTAssertEqual(error as? PageExportRenderError, .corruptBackgroundAsset)
        }
    }

    @MainActor
    func testImportedImageLoaderDownsamplesOversizedAsset() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: 5_000, height: 100),
            format: format
        )
        let data = renderer.pngData { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 5_000, height: 100))
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-image-loader-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url, options: .atomic)

        let image = try XCTUnwrap(PageAssetImageLoader.thumbnail(at: url))
        let cgImage = try XCTUnwrap(image.cgImage)

        XCTAssertLessThanOrEqual(
            max(cgImage.width, cgImage.height),
            Int(PageAssetImageLoader.maximumPixelDimension)
        )
        XCTAssertGreaterThan(cgImage.width, 0)
        XCTAssertGreaterThan(cgImage.height, 0)
    }

    private func pdfData(mediaBox: CGRect) throws -> Data {
        let mutableData = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: mutableData as CFMutableData))
        var mediaBox = mediaBox
        let context = try XCTUnwrap(CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        ))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return mutableData as Data
    }

    @MainActor
    private func inkDrawingData() -> Data {
        let points = [
            PKStrokePoint(
                location: CGPoint(x: 20, y: 20),
                timeOffset: 0,
                size: CGSize(width: 5, height: 5),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
            PKStrokePoint(
                location: CGPoint(x: 30, y: 30),
                timeOffset: 0.1,
                size: CGSize(width: 5, height: 5),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: path)
        return PKDrawing(strokes: [stroke]).dataRepresentation()
    }
}
