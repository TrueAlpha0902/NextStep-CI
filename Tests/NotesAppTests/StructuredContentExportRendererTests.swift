import Foundation
import NotesCore
import XCTest
@testable import NotesApp

final class StructuredContentExportRendererTests: XCTestCase {
    func testMarkdownPreservesEverySemanticBlockStyle() {
        let document = TextDocument(blocks: [
            TextBlock(style: .title, text: "Document title"),
            TextBlock(style: .heading1, text: "First heading"),
            TextBlock(style: .heading2, text: "Second heading"),
            TextBlock(style: .heading3, text: "Third heading"),
            TextBlock(style: .body, text: "Body copy"),
            TextBlock(style: .bulletedList, text: "Bullet", indentationLevel: 1),
            TextBlock(style: .numberedList, text: "Number", indentationLevel: 1),
            TextBlock(style: .checklist, text: "Done", isChecked: true),
            TextBlock(style: .checklist, text: "Todo", isChecked: false),
            TextBlock(style: .quote, text: "Line one\nLine two"),
            TextBlock(style: .code, text: "let value = `code`"),
            TextBlock(style: .divider),
        ])

        XCTAssertEqual(
            StructuredContentExportRenderer.markdown(from: document),
            """
            # Document title

            ## First heading

            ### Second heading

            #### Third heading

            Body copy

                - Bullet

                1. Number

            - [x] Done

            - [ ] Todo

            > Line one
            > Line two

            ```
            let value = `code`
            ```

            ---
            """
        )
    }

    func testCSVUsesRFC4180EscapingAndProtectsFormulaFields() {
        let studySet = StudySet(cards: [
            StudyCard(
                prompt: "A \"quoted\", prompt",
                answer: "first line\nsecond line",
                hint: "=HYPERLINK(\"https://example.test\")",
                tags: ["alpha", "beta"]
            ),
            StudyCard(
                prompt: "  +SUM(A1:A2)",
                answer: "-2+3",
                hint: "@malicious",
                tags: []
            ),
        ])

        XCTAssertEqual(
            StructuredContentExportRenderer.csv(from: studySet),
            "Prompt,Answer,Hint,Tags\r\n"
                + "\"A \"\"quoted\"\", prompt\",\"first line\r\nsecond line\",\"'=HYPERLINK(\"\"https://example.test\"\")\",\"alpha, beta\"\r\n"
                + "'  +SUM(A1:A2),'-2+3,'@malicious,\r\n"
        )
    }

    func testTemporaryExportUsesSafeBoundedFilenameAndAtomicProtectedWrite() throws {
        let identifier = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!
        let url = try StructuredContentExportRenderer.temporaryMarkdown(
            title: " ../../Unsafe:/筆記? ",
            document: TextDocument(blocks: [TextBlock(text: "Saved")]),
            identifier: identifier
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(url.lastPathComponent, "Unsafe 筆記-12345678.md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Saved")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "NotesExports")
    }
}
