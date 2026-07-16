import Foundation
import NotesCore
import NotesServices
@testable import NotesApp
import XCTest

final class CanvasElementSearchBuilderTests: XCTestCase {
    func testSearchableElementsBecomeIndependentPageSegments() {
        let pageID = UUID()
        let textID = ElementID()
        let stickyID = ElementID()
        let linkID = ElementID()
        let elements = [
            element(id: textID, content: .text(TextElement(text: "  Project Atlas  "))),
            element(id: ElementID(), content: .shape(ShapeElement(
                shape: "rectangle",
                strokeColor: RGBAColor(red: 0, green: 0, blue: 0)
            ))),
            element(id: stickyID, content: .stickyNote(StickyNoteElement(
                text: "\nShip local search\n"
            ))),
            element(id: linkID, content: .link(LinkElement(
                title: "Reference",
                destination: URL(string: "https://example.com/private-path")!
            ))),
        ]

        let segments = CanvasElementSearchBuilder.segments(
            for: elements,
            pageID: pageID
        )

        XCTAssertEqual(segments.map(\.id), [
            textID.rawValue,
            stickyID.rawValue,
            linkID.rawValue,
        ])
        XCTAssertEqual(segments.map(\.text), [
            "Project Atlas",
            "Ship local search",
            "Reference",
        ])
        XCTAssertTrue(segments.allSatisfy { $0.pageID == pageID })
        XCTAssertTrue(segments.allSatisfy { $0.source == .canvasElement })
        XCTAssertFalse(segments.map(\.text).contains("private-path"))
    }

    func testWhitespaceAndNontextElementsDoNotCreateSegments() {
        let elements = [
            element(content: .text(TextElement(text: " \n "))),
            element(content: .stickyNote(StickyNoteElement(text: "\t"))),
            element(content: .sticker(StickerElement(
                assetID: AssetID("sticker"),
                accessibilityLabel: "Decorative star"
            ))),
            element(content: .tape(TapeElement(
                color: RGBAColor(red: 1, green: 1, blue: 0)
            ))),
        ]

        XCTAssertTrue(
            CanvasElementSearchBuilder.segments(
                for: elements,
                pageID: UUID()
            ).isEmpty
        )
    }

    func testDocumentIDIsStableAndNamespacedByNotebookAndPage() {
        let notebookID = UUID()
        let pageID = UUID()
        let documentID = CanvasElementSearchBuilder.documentID(
            notebookID: notebookID,
            pageID: pageID
        )

        XCTAssertEqual(documentID, CanvasElementSearchBuilder.documentID(
            notebookID: notebookID,
            pageID: pageID
        ))
        XCTAssertNotEqual(documentID, pageID)
        XCTAssertNotEqual(documentID, CanvasElementSearchBuilder.documentID(
            notebookID: UUID(),
            pageID: pageID
        ))
        XCTAssertNotEqual(documentID, CanvasElementSearchBuilder.documentID(
            notebookID: notebookID,
            pageID: UUID()
        ))
        XCTAssertEqual((documentID.uuid.6 >> 4) & 0x0f, 8)
        XCTAssertEqual((documentID.uuid.8 >> 6) & 0x03, 2)
    }

    func testFingerprintIsStableAndSensitiveToContentAndOrder() {
        let pageID = UUID()
        let first = RecognizedTextSegment(
            id: UUID(),
            text: "First",
            pageID: pageID,
            source: .canvasElement
        )
        let second = RecognizedTextSegment(
            id: UUID(),
            text: "Second",
            pageID: pageID,
            source: .canvasElement
        )

        let fingerprint = CanvasElementSearchBuilder.sourceFingerprint(
            for: [first, second]
        )

        XCTAssertEqual(fingerprint.count, 64)
        XCTAssertEqual(fingerprint, CanvasElementSearchBuilder.sourceFingerprint(
            for: [first, second]
        ))
        XCTAssertNotEqual(fingerprint, CanvasElementSearchBuilder.sourceFingerprint(
            for: [second, first]
        ))
        var edited = second
        edited.text = "Edited"
        XCTAssertNotEqual(fingerprint, CanvasElementSearchBuilder.sourceFingerprint(
            for: [first, edited]
        ))
    }

    private func element(
        id: ElementID = ElementID(),
        content: CanvasElementContent
    ) -> CanvasElement {
        CanvasElement(
            id: id,
            frame: CanvasRect(x: 10, y: 20, width: 200, height: 80),
            content: content,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
