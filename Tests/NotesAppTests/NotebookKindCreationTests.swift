import NotesCore
@testable import NotesApp
import XCTest

final class NotebookKindCreationTests: XCTestCase {
    func testCreatableKindsExposeEveryUserAuthoredNoteType() {
        XCTAssertEqual(
            NotebookKind.creatableKinds,
            [.notebook, .whiteboard, .textDocument, .studySet]
        )
        XCTAssertFalse(NotebookKind.creatableKinds.contains(.quickNote))
        XCTAssertFalse(NotebookKind.creatableKinds.contains(.pdf))
        XCTAssertFalse(NotebookKind.creatableKinds.contains(.image))
    }

    func testNewPageMapsNotebookKindToDurableCoreKind() {
        XCTAssertEqual(EditorPage.newPage(for: .notebook).kind, .notebook)
        XCTAssertEqual(EditorPage.newPage(for: .quickNote).kind, .notebook)
        XCTAssertEqual(EditorPage.newPage(for: .textDocument).kind, .textDocument)
        XCTAssertEqual(EditorPage.newPage(for: .studySet).kind, .studySet)
        XCTAssertEqual(EditorPage.newPage(for: .pdf).kind, .importedDocument)
        XCTAssertEqual(EditorPage.newPage(for: .image).kind, .importedDocument)
    }

    func testWhiteboardUsesBoundedLandscapeDottedCanvas() {
        let page = EditorPage.newPage(for: .whiteboard, template: .ruled)

        XCTAssertEqual(page.kind, .whiteboard)
        XCTAssertEqual(page.width, EditorPage.whiteboardWidth)
        XCTAssertEqual(page.height, EditorPage.whiteboardHeight)
        XCTAssertEqual(page.background, .paper(.dots))
        XCTAssertGreaterThan(page.width, page.height)
    }

    func testRegularNotebookPreservesSelectedPaperTemplate() {
        let page = EditorPage.newPage(for: .notebook, template: .grid)

        XCTAssertEqual(page.kind, .notebook)
        XCTAssertEqual(page.background, .paper(.grid))
        XCTAssertEqual(page.width, 768)
        XCTAssertEqual(page.height, 1_024)
    }
}
