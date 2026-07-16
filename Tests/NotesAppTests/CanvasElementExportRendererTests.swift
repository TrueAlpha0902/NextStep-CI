import NotesCore
import PDFKit
import UIKit
import XCTest
@testable import NotesApp

final class CanvasElementExportRendererTests: XCTestCase {
    @MainActor
    func testPlanUsesStableZOrderAndCanonicalizesCorruptGeometry() throws {
        var corrupt = makeElement(
            id: ElementID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            frame: CanvasRect(x: .nan, y: .infinity, width: -80, height: -.infinity),
            zIndex: 4,
            content: .text(TextElement(text: "Corrupt"))
        )
        corrupt.rotationRadians = .infinity
        corrupt.opacity = .nan
        let back = makeElement(
            id: ElementID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
            frame: CanvasRect(x: 10, y: 20, width: 30, height: 40),
            zIndex: -2,
            content: .shape(blueShape)
        )
        let sameZFirst = makeElement(
            id: ElementID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!),
            frame: CanvasRect(x: 20, y: 20, width: 30, height: 40),
            zIndex: 4,
            content: .shape(blueShape)
        )

        let plan = CanvasElementExportRenderer.plan(
            elements: [corrupt, sameZFirst, back],
            sourceBounds: CGRect(x: 0, y: 0, width: 200, height: 100)
        )

        XCTAssertEqual(plan.entries.map(\.element.id), [back.id, corrupt.id, sameZFirst.id])
        XCTAssertEqual(plan.entries.map(\.originalOffset), [2, 0, 1])
        let normalized = try XCTUnwrap(plan.entries.first(where: { $0.element.id == corrupt.id }))
        XCTAssertTrue(normalized.frame.origin.x.isFinite)
        XCTAssertTrue(normalized.frame.origin.y.isFinite)
        XCTAssertEqual(normalized.frame.width, 80, accuracy: 0.001)
        XCTAssertGreaterThan(normalized.frame.height, 0)
        XCTAssertEqual(normalized.rotationRadians, 0)
        XCTAssertEqual(normalized.opacity, 1)
    }

    @MainActor
    func testPlanCapsPathologicalElementCountDeterministically() {
        let elements = (0 ..< CanvasElementExportRenderer.maximumElementCount + 50).map { index in
            makeElement(
                frame: CanvasRect(x: Double(index % 100), y: 0, width: 10, height: 10),
                zIndex: index,
                content: .shape(blueShape)
            )
        }

        let plan = CanvasElementExportRenderer.plan(
            elements: elements,
            sourceBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        XCTAssertEqual(plan.entries.count, CanvasElementExportRenderer.maximumElementCount)
        XCTAssertEqual(plan.entries.first?.element.zIndex, 0)
        XCTAssertEqual(
            plan.entries.last?.element.zIndex,
            CanvasElementExportRenderer.maximumElementCount - 1
        )
    }

    @MainActor
    func testPlanCanonicalizesSubnormalSourceBoundsBeforeScaling() {
        let plan = CanvasElementExportRenderer.plan(
            elements: [],
            sourceBounds: CGRect(
                x: 0,
                y: 0,
                width: CGFloat.leastNonzeroMagnitude,
                height: CGFloat.leastNonzeroMagnitude
            )
        )

        XCTAssertEqual(plan.sourceBounds.size, CGSize(width: 1, height: 1))
    }

    @MainActor
    func testAssetPreloadIDsMatchStableRendererAttemptOrderAndBudget() {
        let repeatedID = AssetID(String(repeating: "a", count: 64))
        let excludedLateID = AssetID(String(repeating: "b", count: 64))
        let earlyID = AssetID(String(repeating: "c", count: 64))
        let late = makeElement(
            frame: CanvasRect(x: 0, y: 0, width: 10, height: 10),
            zIndex: 10_000,
            content: .image(ImageElement(assetID: excludedLateID))
        )
        let duplicates = (0..<CanvasElementExportRenderer.maximumAssetResolutionAttempts - 1)
            .map { index in
                makeElement(
                    frame: CanvasRect(x: 0, y: 0, width: 10, height: 10),
                    zIndex: index,
                    content: .image(ImageElement(assetID: repeatedID))
                )
            }
        let early = makeElement(
            frame: CanvasRect(x: 0, y: 0, width: 10, height: 10),
            zIndex: -1,
            content: .sticker(StickerElement(assetID: earlyID))
        )

        let assetIDs = CanvasElementExportRenderer.assetIDsForExport(
            elements: [late] + duplicates + [early],
            sourceBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )

        XCTAssertEqual(assetIDs, [earlyID, repeatedID])
        XCTAssertFalse(assetIDs.contains(excludedLateID))
    }

    @MainActor
    func testRasterHonorsZOrderAndRotation() throws {
        let page = EditorPage(width: 100, height: 100)
        let red = ShapeElement(
            shape: "rectangle",
            strokeColor: RGBAColor(red: 1, green: 0, blue: 0),
            fillColor: RGBAColor(red: 1, green: 0, blue: 0),
            lineWidth: 1
        )
        let rotatedBack = makeElement(
            frame: CanvasRect(x: 20, y: 45, width: 60, height: 10),
            rotationRadians: .pi / 2,
            zIndex: 0,
            content: .shape(red)
        )
        var front = makeElement(
            frame: CanvasRect(x: 40, y: 40, width: 20, height: 20),
            zIndex: 1,
            content: .shape(blueShape)
        )
        front.opacity = 0.5

        let image = try PageExportRenderer.renderRasterImage(
            page: page,
            background: ResolvedPageBackground(background: page.background, assetURL: nil),
            drawingData: nil,
            canvasElements: [front, rotatedBack]
        )

        let rotatedRed = try pixel(in: image, x: 100, y: 50)
        XCTAssertGreaterThan(rotatedRed.red, 0.8)
        XCTAssertLessThan(rotatedRed.blue, 0.2)
        let overlap = try pixel(in: image, x: 100, y: 100)
        XCTAssertEqual(overlap.red, 0.5, accuracy: 0.12)
        XCTAssertEqual(overlap.blue, 0.5, accuracy: 0.12)
    }

    @MainActor
    func testOversizedResolverResultIsRejectedAndMissingAssetGetsPlaceholder() throws {
        let page = EditorPage(width: 100, height: 100)
        let assetID = AssetID(String(repeating: "a", count: 64))
        let imageElement = makeElement(
            frame: CanvasRect(x: 10, y: 10, width: 20, height: 20),
            content: .image(ImageElement(assetID: assetID, contentMode: "fill"))
        )
        let oversized = solidImage(color: .red, size: CGSize(width: 200, height: 200))
        var observedRequest: CanvasElementExportImageRequest?

        let rendered = try PageExportRenderer.renderRasterImage(
            page: page,
            background: ResolvedPageBackground(background: page.background, assetURL: nil),
            drawingData: nil,
            canvasElements: [imageElement],
            assetImageResolver: { resolvedID, request in
                XCTAssertEqual(resolvedID, assetID)
                observedRequest = request
                return oversized
            }
        )

        XCTAssertEqual(observedRequest?.maximumPixelDimension, 40)
        let placeholder = try pixel(in: rendered, x: 40, y: 40)
        XCTAssertFalse(placeholder.red > 0.8 && placeholder.green < 0.2 && placeholder.blue < 0.2)
    }

    func testAssetRequestCapsDecodedMemoryForLargeFrames() {
        let request = CanvasElementExportImageRequest(
            frameSize: CGSize(width: 1_000_000, height: 1_000_000),
            rasterScale: 2
        )

        XCTAssertLessThanOrEqual(
            max(request.targetPixelSize.width, request.targetPixelSize.height),
            CanvasElementExportImageRequest.hardMaximumPixelDimension
        )
        XCTAssertLessThanOrEqual(
            Int(request.targetPixelSize.width * request.targetPixelSize.height) * 4,
            CanvasElementExportImageRequest.hardMaximumDecodedBytes
        )
    }

    func testAssetRequestHonorsSmallerRemainingDecodedMemoryBudget() {
        let remainingBudget = 1 * 1_024 * 1_024
        let request = CanvasElementExportImageRequest(
            frameSize: CGSize(width: 10_000, height: 10_000),
            rasterScale: 2,
            maximumDecodedBytes: remainingBudget
        )

        XCTAssertEqual(request.maximumDecodedBytes, remainingBudget)
        XCTAssertLessThanOrEqual(
            Int(request.targetPixelSize.width * request.targetPixelSize.height) * 4,
            remainingBudget
        )
    }

    @MainActor
    func testAssetResolverReceivesTheRemainingAggregateDecodedMemoryBudget() throws {
        let page = EditorPage(width: 100, height: 100)
        let firstAsset = AssetID(String(repeating: "d", count: 64))
        let secondAsset = AssetID(String(repeating: "e", count: 64))
        let thumbnail = solidImage(color: .systemGreen, size: CGSize(width: 8, height: 8))
        let decodedBytes = try XCTUnwrap(
            CanvasElementExportImageRequest(
                frameSize: CGSize(width: 20, height: 20),
                rasterScale: 2
            ).decodedByteCount(of: thumbnail)
        )
        var observedBudgets = [Int]()

        _ = try PageExportRenderer.renderRasterImage(
            page: page,
            background: ResolvedPageBackground(background: page.background, assetURL: nil),
            drawingData: nil,
            canvasElements: [
                makeElement(
                    frame: CanvasRect(x: 10, y: 10, width: 20, height: 20),
                    content: .image(ImageElement(assetID: firstAsset))
                ),
                makeElement(
                    frame: CanvasRect(x: 40, y: 10, width: 20, height: 20),
                    content: .image(ImageElement(assetID: secondAsset))
                ),
            ],
            assetImageResolver: { _, request in
                observedBudgets.append(request.maximumDecodedBytes)
                return thumbnail
            }
        )

        XCTAssertEqual(observedBudgets, [
            CanvasElementExportImageRequest.hardMaximumDecodedBytes,
            CanvasElementExportImageRequest.hardMaximumDecodedBytes - decodedBytes,
        ])
    }

    @MainActor
    func testPDFRendersEveryElementKindAndAddsOnlySafeLinkAnnotations() throws {
        let page = EditorPage(width: 400, height: 400)
        let imageAsset = AssetID(String(repeating: "b", count: 64))
        let stickerAsset = AssetID(String(repeating: "c", count: 64))
        let safeURL = try XCTUnwrap(URL(string: "https://example.com/notes?id=42"))
        let unsafeURL = try XCTUnwrap(URL(string: "file:///private/notes-secret"))
        let elements = [
            makeElement(frame: frame(0), content: .text(TextElement(text: "Text"))),
            makeElement(frame: frame(1), content: .image(ImageElement(assetID: imageAsset))),
            makeElement(frame: frame(2), content: .shape(blueShape)),
            makeElement(
                frame: frame(3),
                content: .connector(ConnectorElement(
                    start: CanvasPoint(x: 160, y: 25),
                    end: CanvasPoint(x: 195, y: 45),
                    strokeColor: RGBAColor(red: 0, green: 0, blue: 0),
                    endCap: "arrow"
                ))
            ),
            makeElement(frame: frame(4), content: .stickyNote(StickyNoteElement(text: "Sticky"))),
            makeElement(
                frame: frame(5),
                content: .tape(TapeElement(
                    color: RGBAColor(red: 0.7, green: 0.5, blue: 0.9),
                    isRevealed: true
                ))
            ),
            makeElement(
                frame: frame(6),
                content: .sticker(StickerElement(assetID: stickerAsset, accessibilityLabel: "Star"))
            ),
            makeElement(frame: frame(7), content: .link(LinkElement(title: "Safe", destination: safeURL))),
            makeElement(frame: frame(8), content: .link(LinkElement(title: "Unsafe", destination: unsafeURL))),
        ]
        var requestedAssets = [AssetID]()
        let localThumbnail = solidImage(color: .systemGreen, size: CGSize(width: 64, height: 64))

        let data = try PageExportRenderer.renderPDF(
            page: page,
            background: ResolvedPageBackground(background: page.background, assetURL: nil),
            drawingData: nil,
            canvasElements: elements,
            assetImageResolver: { assetID, request in
                requestedAssets.append(assetID)
                return request.accepts(localThumbnail) ? localThumbnail : nil
            }
        )

        XCTAssertEqual(Set(requestedAssets), Set([imageAsset, stickerAsset]))
        let document = try XCTUnwrap(PDFDocument(data: data))
        let renderedPage = try XCTUnwrap(document.page(at: 0))
        let linkURLs = renderedPage.annotations.compactMap { annotation in
            annotation.url ?? (annotation.action as? PDFActionURL)?.url
        }
        XCTAssertEqual(linkURLs, [safeURL])
        let safeAnnotation = try XCTUnwrap(renderedPage.annotations.first { annotation in
            (annotation.url ?? (annotation.action as? PDFActionURL)?.url) == safeURL
        })
        XCTAssertEqual(safeAnnotation.bounds.minX, 295, accuracy: 0.5)
        XCTAssertEqual(safeAnnotation.bounds.minY, 225, accuracy: 0.5)
        XCTAssertEqual(safeAnnotation.bounds.width, 80, accuracy: 0.5)
        XCTAssertEqual(safeAnnotation.bounds.height, 70, accuracy: 0.5)
    }

    @MainActor
    func testLinkSafetyNeverTreatsLocalOrExecutableSchemesAsAnnotations() throws {
        XCTAssertNotNil(CanvasElementExportRenderer.safeLinkDestination(
            try XCTUnwrap(URL(string: "https://example.com"))
        ))
        XCTAssertNil(CanvasElementExportRenderer.safeLinkDestination(
            try XCTUnwrap(URL(string: "file:///private/secret"))
        ))
        XCTAssertNil(CanvasElementExportRenderer.safeLinkDestination(
            try XCTUnwrap(URL(string: "javascript:alert(1)"))
        ))
        XCTAssertNil(CanvasElementExportRenderer.safeLinkDestination(
            try XCTUnwrap(URL(string: "data:text/plain,secret"))
        ))
    }

    @MainActor
    func testPDFDoesNotCreateInvisibleLinkAnnotationForZeroOpacityElement() throws {
        let page = EditorPage(width: 200, height: 200)
        let visibleURL = try XCTUnwrap(URL(string: "https://example.com/visible"))
        let hiddenURL = try XCTUnwrap(URL(string: "https://example.com/hidden"))
        let visible = makeElement(
            frame: CanvasRect(x: 10, y: 10, width: 80, height: 40),
            content: .link(LinkElement(title: "Visible", destination: visibleURL))
        )
        var hidden = makeElement(
            frame: CanvasRect(x: 10, y: 60, width: 80, height: 40),
            content: .link(LinkElement(title: "Hidden", destination: hiddenURL))
        )
        hidden.opacity = 0

        let data = try PageExportRenderer.renderPDF(
            page: page,
            background: ResolvedPageBackground(background: page.background, assetURL: nil),
            drawingData: nil,
            canvasElements: [visible, hidden]
        )

        let document = try XCTUnwrap(PDFDocument(data: data))
        let renderedPage = try XCTUnwrap(document.page(at: 0))
        let linkURLs = renderedPage.annotations.compactMap { annotation in
            annotation.url ?? (annotation.action as? PDFActionURL)?.url
        }
        XCTAssertEqual(linkURLs, [visibleURL])
    }

    private var blueShape: ShapeElement {
        ShapeElement(
            shape: "rectangle",
            strokeColor: RGBAColor(red: 0, green: 0, blue: 1),
            fillColor: RGBAColor(red: 0, green: 0, blue: 1),
            lineWidth: 1
        )
    }

    private func frame(_ index: Int) -> CanvasRect {
        let column = index % 4
        let row = index / 4
        return CanvasRect(
            x: Double(column * 95 + 10),
            y: Double(row * 95 + 10),
            width: 80,
            height: 70
        )
    }

    private func makeElement(
        id: ElementID = ElementID(),
        frame: CanvasRect,
        rotationRadians: Double = 0,
        zIndex: Int = 0,
        content: CanvasElementContent
    ) -> CanvasElement {
        CanvasElement(
            id: id,
            frame: frame,
            rotationRadians: rotationRadians,
            zIndex: zIndex,
            content: content,
            createdAt: Date(timeIntervalSinceReferenceDate: 1)
        )
    }

    @MainActor
    private func solidImage(color: UIColor, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func pixel(in image: UIImage, x: Int, y: Int) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let image = try XCTUnwrap(image.cgImage)
        let safeX = min(max(x, 0), image.width - 1)
        let safeY = min(max(y, 0), image.height - 1)
        let crop = try XCTUnwrap(image.cropping(to: CGRect(x: safeX, y: safeY, width: 1, height: 1)))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (
            red: CGFloat(bytes[0]) / 255,
            green: CGFloat(bytes[1]) / 255,
            blue: CGFloat(bytes[2]) / 255
        )
    }
}
