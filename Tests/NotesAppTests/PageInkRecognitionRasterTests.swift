import PencilKit
import UIKit
import XCTest
@testable import NotesApp

final class PageInkRecognitionRasterTests: XCTestCase {
    func testStandardPageUsesPreferredScaleWithinBothRasterBudgets() throws {
        let plan = try PageInkRecognitionRasterPlan(
            pageSize: CGSize(width: 768, height: 1_024)
        )

        XCTAssertEqual(
            plan.rasterScale,
            PageInkRecognitionRasterPlan.preferredRasterScale
        )
        XCTAssertEqual(plan.rasterPixelSize, CGSize(width: 2_304, height: 3_072))
        assertPlanIsBounded(plan)
    }

    func testLargeSquarePageTightensScaleForIntegralMemoryBudget() throws {
        let plan = try PageInkRecognitionRasterPlan(
            pageSize: CGSize(width: 10_000, height: 10_000)
        )

        XCTAssertLessThan(
            plan.rasterScale,
            PageInkRecognitionRasterPlan.preferredRasterScale
        )
        assertPlanIsBounded(plan)
    }

    func testExtremeFiniteAspectRatioStillProducesABoundedRaster() throws {
        let plan = try PageInkRecognitionRasterPlan(
            pageSize: CGSize(width: CGFloat.greatestFiniteMagnitude, height: 1)
        )

        XCTAssertTrue(plan.rasterScale.isFinite)
        XCTAssertGreaterThan(plan.rasterScale, 0)
        XCTAssertEqual(plan.rasterPixelSize.height, 1)
        assertPlanIsBounded(plan)
    }

    func testInvalidPageDimensionsAreRejectedBeforeFrameworkRendering() {
        let invalidSizes = [
            CGSize(width: 0, height: 100),
            CGSize(width: -1, height: 100),
            CGSize(width: 100, height: CGFloat.infinity),
            CGSize(width: CGFloat.nan, height: 100),
        ]

        for size in invalidSizes {
            XCTAssertThrowsError(try PageInkRecognitionRasterPlan(pageSize: size)) { error in
                XCTAssertEqual(
                    error as? PageInkRecognitionRasterError,
                    .invalidPageSize
                )
            }
        }
    }

    @MainActor
    func testEmptyDrawingProducesAnOpaqueWhiteImage() throws {
        let image = try PageExportRenderer.renderInkOnlyRecognitionImage(
            drawingData: PKDrawing().dataRepresentation(),
            pageSize: CGSize(width: 48, height: 32)
        )
        let pixels = try rgbaPixels(in: image)

        XCTAssertEqual(pixels.width, 144)
        XCTAssertEqual(pixels.height, 96)
        XCTAssertTrue(pixels.bytes.allSatisfy { $0 == 255 })
    }

    @MainActor
    func testWhiteInkIsNormalizedToHighContrastOnWhiteBackground() throws {
        let image = try PageExportRenderer.renderInkOnlyRecognitionImage(
            drawingData: inkDrawingData(color: .white),
            pageSize: CGSize(width: 100, height: 100)
        )
        let pixels = try rgbaPixels(in: image)

        var darkestColorComponent = UInt8.max
        var darkPixelCount = 0
        var allPixelsAreOpaque = true
        for index in stride(from: 0, to: pixels.bytes.count, by: 4) {
            let red = pixels.bytes[index]
            let green = pixels.bytes[index + 1]
            let blue = pixels.bytes[index + 2]
            darkestColorComponent = min(
                darkestColorComponent,
                red,
                green,
                blue
            )
            if max(red, green, blue) < 240 {
                darkPixelCount += 1
            }
            allPixelsAreOpaque = allPixelsAreOpaque && pixels.bytes[index + 3] == 255
        }

        XCTAssertLessThan(darkestColorComponent, 96)
        XCTAssertGreaterThan(darkPixelCount, 0)
        XCTAssertLessThan(darkPixelCount, pixels.width * pixels.height / 4)
        XCTAssertTrue(allPixelsAreOpaque)
    }

    @MainActor
    func testRecognitionInputLimitIsAppliedBeforePencilKitDecode() {
        let oversized = Data(
            count: PageExportRenderer.maximumRecognitionDrawingDataBytes + 1
        )

        XCTAssertThrowsError(
            try PageExportRenderer.renderInkOnlyRecognitionImage(
                drawingData: oversized,
                pageSize: CGSize(width: 100, height: 100)
            )
        ) { error in
            XCTAssertEqual(
                error as? PageExportRenderError,
                .drawingDataLimitExceeded(
                    limit: PageExportRenderer.maximumRecognitionDrawingDataBytes
                )
            )
        }
    }

    @MainActor
    func testCorruptRecognitionInputIsNotRenderedAsBlankInk() {
        XCTAssertThrowsError(
            try PageExportRenderer.renderInkOnlyRecognitionImage(
                drawingData: Data("not a PencilKit drawing".utf8),
                pageSize: CGSize(width: 100, height: 100)
            )
        ) { error in
            XCTAssertEqual(error as? PageExportRenderError, .corruptDrawingData)
        }
    }

    private func assertPlanIsBounded(
        _ plan: PageInkRecognitionRasterPlan,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(
            max(plan.rasterPixelSize.width, plan.rasterPixelSize.height),
            PageInkRecognitionRasterPlan.maximumRasterDimension,
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            plan.estimatedRasterBytes,
            PageInkRecognitionRasterPlan.maximumRasterBytes,
            file: file,
            line: line
        )
    }

    @MainActor
    private func inkDrawingData(color: UIColor) -> Data {
        let points = [
            PKStrokePoint(
                location: CGPoint(x: 20, y: 50),
                timeOffset: 0,
                size: CGSize(width: 12, height: 12),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
            PKStrokePoint(
                location: CGPoint(x: 80, y: 50),
                timeOffset: 0.1,
                size: CGSize(width: 12, height: 12),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let stroke = PKStroke(ink: PKInk(.pen, color: color), path: path)
        return PKDrawing(strokes: [stroke]).dataRepresentation()
    }

    @MainActor
    private func rgbaPixels(in image: UIImage) throws -> (
        bytes: [UInt8],
        width: Int,
        height: Int
    ) {
        let cgImage = try XCTUnwrap(image.cgImage)
        let width = cgImage.width
        let height = cgImage.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }
            context.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            return true
        }
        guard rendered else {
            throw PageInkRecognitionRasterError.invalidRenderedImage
        }
        return (bytes, width, height)
    }
}
