import Foundation
import NotesCore
import NotesServices
import XCTest
@testable import NotesApp

final class StructuredContentSearchBuilderTests: XCTestCase {
    func testTextBlocksFlattenIntoOneDeterministicTypedTextSegment() throws {
        let pageID = UUID()
        let document = TextDocument(blocks: [
            TextBlock(style: .title, text: "  Project Atlas  "),
            TextBlock(style: .divider, text: "not searchable"),
            TextBlock(style: .checklist, text: "Ship offline search", isChecked: true),
            TextBlock(style: .body, text: "\nSupporting detail\n"),
        ])

        let segment = try XCTUnwrap(
            StructuredContentSearchBuilder.segment(
                for: .textDocument(document),
                pageID: pageID
            )
        )

        XCTAssertEqual(segment.id, pageID)
        XCTAssertEqual(segment.pageID, pageID)
        XCTAssertEqual(segment.source, .typedText)
        XCTAssertEqual(segment.text, "Project Atlas\nShip offline search\nSupporting detail")
    }

    func testStudyCardsFlattenPromptAnswerHintAndTagsInCardOrder() {
        let studySet = StudySet(cards: [
            StudyCard(
                prompt: "Force",
                answer: "Mass × acceleration",
                hint: "Newton's second law",
                tags: ["physics", "mechanics"]
            ),
            StudyCard(prompt: "Empty extras", answer: "  answer  ", hint: "   "),
        ])

        XCTAssertEqual(
            StructuredContentSearchBuilder.plainText(for: studySet),
            "Force\nMass × acceleration\nNewton's second law\nphysics\nmechanics\nEmpty extras\nanswer"
        )
    }

    func testEmptyStructuredContentDoesNotCreateSearchText() {
        XCTAssertNil(StructuredContentSearchBuilder.plainText(for: TextDocument()))
        XCTAssertNil(StructuredContentSearchBuilder.plainText(for: StudySet()))
        XCTAssertNil(
            StructuredContentSearchBuilder.plainText(
                for: TextDocument(blocks: [
                    TextBlock(style: .body, text: " \n "),
                    TextBlock(style: .divider),
                ])
            )
        )
    }
}
