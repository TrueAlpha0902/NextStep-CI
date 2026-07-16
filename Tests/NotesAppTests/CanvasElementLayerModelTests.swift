import CoreGraphics
import Foundation
import UIKit
import XCTest
import NotesCore
@testable import NotesApp

final class CanvasElementLayerModelTests: XCTestCase {
    private let pageBounds = CanvasRect(x: 100, y: 200, width: 1_000, height: 500)
    private let timestamp = Date(timeIntervalSince1970: 1_000)

    func testCoordinateTransformAccountsForPageOriginAndIndependentAxes() {
        let transform = CanvasElementCoordinateTransform(
            pageBounds: pageBounds,
            viewSize: CGSize(width: 500, height: 500)
        )

        XCTAssertEqual(
            transform.localRect(for: CanvasRect(x: 300, y: 250, width: 200, height: 100)),
            CGRect(x: 100, y: 50, width: 100, height: 100)
        )
        XCTAssertEqual(
            transform.pageTranslation(for: CGSize(width: 25, height: -40)),
            CanvasPoint(x: 50, y: -40)
        )
        XCTAssertEqual(
            transform.pagePoint(for: CGPoint(x: 150, y: 75)),
            CanvasPoint(x: 400, y: 275)
        )
    }

    func testCoordinateTransformReturnsZeroTranslationWhenViewHasNoSize() {
        let transform = CanvasElementCoordinateTransform(
            pageBounds: pageBounds,
            viewSize: .zero
        )

        XCTAssertEqual(
            transform.pageTranslation(for: CGSize(width: 100, height: 100)),
            CanvasPoint(x: 0, y: 0)
        )
    }

    func testCoordinateTransformCanonicalizesNegativeBoundsAndFrames() {
        let transform = CanvasElementCoordinateTransform(
            pageBounds: CanvasRect(x: 100, y: 200, width: -1_000, height: 500),
            viewSize: CGSize(width: 500, height: 500)
        )

        XCTAssertEqual(
            transform.localRect(for: CanvasRect(x: -600, y: 250, width: -200, height: 100)),
            CGRect(x: 50, y: 50, width: 100, height: 100)
        )
        XCTAssertEqual(
            transform.pagePoint(for: CGPoint(x: 150, y: 75)),
            CanvasPoint(x: -600, y: 275)
        )
    }

    func testCoordinateTransformNeverReturnsNonFiniteGeometry() {
        let transform = CanvasElementCoordinateTransform(
            pageBounds: CanvasRect(x: .infinity, y: -.infinity, width: .nan, height: 0),
            viewSize: CGSize(width: CGFloat.infinity, height: CGFloat.nan)
        )

        let rect = transform.localRect(for: CanvasRect(
            x: .nan,
            y: .infinity,
            width: -.infinity,
            height: .nan
        ))
        let translation = transform.pageTranslation(
            for: CGSize(width: CGFloat.nan, height: CGFloat.infinity)
        )
        let point = transform.pagePoint(
            for: CGPoint(x: CGFloat.infinity, y: CGFloat.nan)
        )

        XCTAssertTrue(
            ([rect.origin.x, rect.origin.y, rect.width, rect.height] as [CGFloat])
                .allSatisfy(\.isFinite)
        )
        XCTAssertTrue(
            ([translation.x, translation.y, point.x, point.y] as [Double])
                .allSatisfy(\.isFinite)
        )
        XCTAssertGreaterThanOrEqual(rect.width, 0)
        XCTAssertGreaterThanOrEqual(rect.height, 0)
    }

    func testEveryResizeHandleProducesExpectedAnchoredFrame() {
        let frame = CanvasRect(x: 20, y: 30, width: 100, height: 80)
        let translation = CanvasPoint(x: 10, y: 15)

        XCTAssertEqual(
            CanvasElementResizeHandle.topLeading.proposedFrame(from: frame, translation: translation),
            CanvasRect(x: 30, y: 45, width: 90, height: 65)
        )
        XCTAssertEqual(
            CanvasElementResizeHandle.topTrailing.proposedFrame(from: frame, translation: translation),
            CanvasRect(x: 20, y: 45, width: 110, height: 65)
        )
        XCTAssertEqual(
            CanvasElementResizeHandle.bottomLeading.proposedFrame(from: frame, translation: translation),
            CanvasRect(x: 30, y: 30, width: 90, height: 95)
        )
        XCTAssertEqual(
            CanvasElementResizeHandle.bottomTrailing.proposedFrame(from: frame, translation: translation),
            CanvasRect(x: 20, y: 30, width: 110, height: 95)
        )
    }

    func testResizeHandlesRefuseNonFiniteGeometry() {
        for handle in CanvasElementResizeHandle.allCases {
            let frame = handle.proposedFrame(
                from: CanvasRect(x: .nan, y: .infinity, width: -.infinity, height: .nan),
                translation: CanvasPoint(x: .infinity, y: .nan)
            )
            XCTAssertTrue(
                [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite),
                "\(handle) produced non-finite geometry"
            )
        }
    }

    func testGesturePreviewDoesNotMutateBaselineAndCommitUsesSuppliedTimestamp() throws {
        let element = makeText(id: elementID(1), frame: CanvasRect(x: 200, y: 250, width: 120, height: 80))
        let model = CanvasElementGestureCommitModel(
            baselineElements: [element],
            pageBounds: pageBounds,
            operation: .translation(
                selectedIDs: Set([element.id]),
                offset: CanvasPoint(x: 40, y: 30)
            )
        )

        let preview = try XCTUnwrap(model.previewElements().first)
        XCTAssertEqual(preview.frame, CanvasRect(x: 240, y: 280, width: 120, height: 80))
        XCTAssertEqual(model.baselineElements, [element])
        XCTAssertEqual(preview.modifiedAt, timestamp)

        let committedAt = timestamp.addingTimeInterval(20)
        let committed = try XCTUnwrap(model.committedElements(now: committedAt).first)
        XCTAssertEqual(committed.frame, preview.frame)
        XCTAssertEqual(committed.modifiedAt, committedAt)
    }

    func testGestureModelRefusesAmbiguousDuplicatePersistedIDs() {
        let duplicatedID = elementID(3)
        let first = makeText(
            id: duplicatedID,
            frame: CanvasRect(x: 200, y: 250, width: 120, height: 80)
        )
        let second = makeText(
            id: duplicatedID,
            frame: CanvasRect(x: 400, y: 350, width: 120, height: 80)
        )
        let model = CanvasElementGestureCommitModel(
            baselineElements: [first, second],
            pageBounds: pageBounds,
            operation: .translation(
                selectedIDs: Set([duplicatedID]),
                offset: CanvasPoint(x: 40, y: 30)
            )
        )

        XCTAssertEqual(model.previewElements(), [first, second])
        XCTAssertEqual(model.committedElements(now: timestamp.addingTimeInterval(20)), [first, second])
    }

    func testResizePreviewUsesCanvasEditingContainmentAndAspectPolicy() throws {
        let element = CanvasElement(
            id: elementID(2),
            frame: CanvasRect(x: 900, y: 600, width: 100, height: 50),
            content: .image(ImageElement(
                assetID: AssetID(String(repeating: "a", count: 64))
            )),
            createdAt: timestamp,
            modifiedAt: timestamp
        )
        let model = CanvasElementGestureCommitModel(
            baselineElements: [element],
            pageBounds: pageBounds,
            operation: .resize(
                id: element.id,
                proposedFrame: CanvasRect(x: 900, y: 600, width: 400, height: 80),
                preservesAspectRatio: true
            )
        )

        let resized = try XCTUnwrap(model.previewElements().first)
        XCTAssertEqual(resized.frame.width / resized.frame.height, 2, accuracy: 0.000_001)
        XCTAssertLessThanOrEqual(resized.frame.x + resized.frame.width, pageBounds.x + pageBounds.width)
        XCTAssertLessThanOrEqual(resized.frame.y + resized.frame.height, pageBounds.y + pageBounds.height)
    }

    func testRotationDeltaUsesCenterAndQuarterTurn() {
        let delta = CanvasElementGestureCommitModel.rotationDelta(
            around: CanvasPoint(x: 50, y: 50),
            start: CanvasPoint(x: 100, y: 50),
            current: CanvasPoint(x: 50, y: 100)
        )

        XCTAssertEqual(delta, .pi / 2, accuracy: 0.000_001)
    }

    func testRenderEntriesKeepDuplicatePersistedIDsDistinctAndNonEditable() {
        let duplicatedID = elementID(4)
        var front = makeText(
            id: duplicatedID,
            frame: CanvasRect(x: 300, y: 300, width: 100, height: 100)
        )
        front.zIndex = 5
        var back = makeText(
            id: duplicatedID,
            frame: CanvasRect(x: 200, y: 200, width: 100, height: 100)
        )
        back.zIndex = 1
        var unique = makeText(
            id: elementID(5),
            frame: CanvasRect(x: 400, y: 400, width: 100, height: 100)
        )
        unique.zIndex = 3

        let entries = CanvasElementRenderEntry.entries(for: [front, unique, back])

        XCTAssertEqual(entries.map(\.element.frame), [back.frame, unique.frame, front.frame])
        XCTAssertEqual(entries.map(\.hasUnambiguousIdentity), [false, true, false])
        XCTAssertEqual(Set(entries.map(\.id)).count, 3)
        XCTAssertNotEqual(
            entries[0].id.accessibilityIdentifier(hasUnambiguousIdentity: false),
            entries[2].id.accessibilityIdentifier(hasUnambiguousIdentity: false)
        )
    }

    func testImageRequestBoundsDecodeSizeForTinyAndHugeDisplays() {
        XCTAssertEqual(
            CanvasElementImageRequest(
                displaySize: CGSize(width: 100, height: 40),
                displayScale: 2
            ).maximumPixelDimension,
            200
        )
        XCTAssertEqual(
            CanvasElementImageRequest(
                displaySize: CGSize(width: CGFloat.infinity, height: 20_000),
                displayScale: CGFloat.infinity
            ).maximumPixelDimension,
            CanvasElementImageRequest.maximumAllowedPixelDimension
        )
    }

    @MainActor
    func testImageRequestRejectsResolverOutputLargerThanRequestedPixelBudget() throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 20,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 80,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = UIImage(cgImage: try XCTUnwrap(context.makeImage()))

        XCTAssertFalse(CanvasElementImageRequest(
            displaySize: CGSize(width: 10, height: 10),
            displayScale: 1
        ).accepts(image))
        XCTAssertTrue(CanvasElementImageRequest(
            displaySize: CGSize(width: 20, height: 20),
            displayScale: 1
        ).accepts(image))
    }

    func testPresentationModelCoversAllPersistedElementKinds() throws {
        let destination = try XCTUnwrap(URL(string: "https://example.test/note"))
        let assetID = AssetID(String(repeating: "b", count: 64))
        let contents: [CanvasElementContent] = [
            .text(TextElement(text: "Meeting notes")),
            .image(ImageElement(assetID: assetID)),
            .shape(ShapeElement(shape: "ellipse", strokeColor: .init(red: 0, green: 0, blue: 0))),
            .connector(ConnectorElement(
                start: CanvasPoint(x: 0, y: 0),
                end: CanvasPoint(x: 10, y: 10),
                strokeColor: .init(red: 0, green: 0, blue: 0)
            )),
            .stickyNote(StickyNoteElement(text: "Remember this")),
            .tape(TapeElement(color: .init(red: 1, green: 0, blue: 0), isRevealed: false)),
            .sticker(StickerElement(assetID: assetID, accessibilityLabel: "Gold star")),
            .link(LinkElement(title: "Reference", destination: destination))
        ]

        let presentations = contents.map { content in
            CanvasElementPresentationModel(element: CanvasElement(
                frame: CanvasRect(x: 0, y: 0, width: 100, height: 100),
                content: content,
                createdAt: timestamp,
                modifiedAt: timestamp
            ))
        }

        XCTAssertEqual(
            presentations.map(\.kind),
            [.text, .image, .shape, .connector, .stickyNote, .tape, .sticker, .link]
        )
        XCTAssertEqual(presentations[0].summary, "Meeting notes")
        XCTAssertEqual(presentations[5].summary, "Hidden")
        XCTAssertEqual(presentations[6].accessibilityValue(isLocked: true), "Gold star, locked")
        XCTAssertEqual(presentations[7].symbolName, "link")
    }

    func testEmptyPresentationSummaryHasUsefulAccessibilityFallback() {
        let element = CanvasElement(
            frame: CanvasRect(x: 0, y: 0, width: 100, height: 100),
            content: .text(TextElement(text: "  \n")),
            createdAt: timestamp,
            modifiedAt: timestamp
        )

        XCTAssertEqual(
            CanvasElementPresentationModel(element: element).accessibilityValue(isLocked: false),
            "Empty"
        )
    }

    private func elementID(_ value: UInt8) -> ElementID {
        let suffix = String(format: "%012x", value)
        return ElementID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!)
    }

    private func makeText(id: ElementID, frame: CanvasRect) -> CanvasElement {
        CanvasElement(
            id: id,
            frame: frame,
            content: .text(TextElement(text: "Text")),
            createdAt: timestamp,
            modifiedAt: timestamp
        )
    }
}
