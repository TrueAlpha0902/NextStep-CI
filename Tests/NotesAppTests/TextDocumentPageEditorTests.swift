import Foundation
import NextStepAcademic
import NotesCore
@testable import NotesApp
import XCTest

final class TextDocumentPageEditorTests: XCTestCase {
    func testEveryBlockStyleCreatesNormalizedContent() {
        for style in TextBlockStyle.allCases {
            let block = TextDocumentEditing.makeBlock(style: style)

            XCTAssertEqual(block.style, style)
            XCTAssertEqual(block.indentationLevel, 0)
            XCTAssertEqual(block.text, "")
            if style == .checklist {
                XCTAssertEqual(block.isChecked, false)
            } else {
                XCTAssertNil(block.isChecked)
            }
        }
    }

    func testStyleChangesNormalizeChecklistDividerAndIndentationInvariants() throws {
        let createdAt = Date(timeIntervalSince1970: 100)
        let editedAt = Date(timeIntervalSince1970: 200)
        let blockID = TextBlockID()
        let document = TextDocument(blocks: [
            TextBlock(
                id: blockID,
                style: .body,
                text: "Keep me",
                indentationLevel: 99,
                createdAt: createdAt,
                modifiedAt: createdAt
            ),
        ])

        let checklist = TextDocumentEditing.changingStyle(
            of: blockID,
            to: .checklist,
            in: document,
            now: editedAt
        )
        let checklistBlock = try XCTUnwrap(checklist.blocks.first)
        XCTAssertEqual(checklistBlock.style, .checklist)
        XCTAssertEqual(checklistBlock.text, "Keep me")
        XCTAssertEqual(checklistBlock.indentationLevel, 32)
        XCTAssertEqual(checklistBlock.isChecked, false)
        XCTAssertEqual(checklistBlock.modifiedAt, editedAt)

        let checked = TextDocumentEditing.settingChecklistState(
            true,
            for: blockID,
            in: checklist,
            now: editedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(try XCTUnwrap(checked.blocks.first).isChecked, true)

        let divider = TextDocumentEditing.changingStyle(
            of: blockID,
            to: .divider,
            in: checked,
            now: editedAt.addingTimeInterval(2)
        )
        let dividerBlock = try XCTUnwrap(divider.blocks.first)
        XCTAssertEqual(dividerBlock.style, .divider)
        XCTAssertEqual(dividerBlock.text, "")
        XCTAssertNil(dividerBlock.isChecked)

        let ignoredText = TextDocumentEditing.settingText(
            "Divider text is invalid",
            for: blockID,
            in: divider,
            now: editedAt.addingTimeInterval(3)
        )
        XCTAssertEqual(ignoredText, divider)
    }

    func testIDBasedEditsStillTargetCorrectBlockAfterReordering() throws {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let firstID = TextBlockID()
        let secondID = TextBlockID()
        let thirdID = TextBlockID()
        let document = TextDocument(blocks: [
            makeBlock(id: firstID, text: "First", timestamp: timestamp),
            makeBlock(id: secondID, text: "Second", timestamp: timestamp),
            makeBlock(id: thirdID, text: "Third", timestamp: timestamp),
        ])

        let reordered = TextDocumentEditing.moving(
            firstID,
            by: 1,
            in: document,
            now: timestamp.addingTimeInterval(1)
        )
        XCTAssertEqual(reordered.blocks.map(\.id), [secondID, firstID, thirdID])

        let edited = TextDocumentEditing.settingText(
            "Edited first",
            for: firstID,
            in: reordered,
            now: timestamp.addingTimeInterval(2)
        )
        XCTAssertEqual(edited.blocks.first(where: { $0.id == firstID })?.text, "Edited first")
        XCTAssertEqual(edited.blocks.first(where: { $0.id == secondID })?.text, "Second")

        let deleted = TextDocumentEditing.deleting(secondID, from: edited)
        XCTAssertEqual(deleted.blocks.map(\.id), [firstID, thirdID])
    }

    func testIndentationClampsBetweenZeroAndThirtyTwo() throws {
        let blockID = TextBlockID()
        let document = TextDocument(blocks: [makeBlock(id: blockID, text: "Indented")])

        let maximum = TextDocumentEditing.adjustingIndentation(
            of: blockID,
            by: 100,
            in: document
        )
        XCTAssertEqual(try XCTUnwrap(maximum.blocks.first).indentationLevel, 32)

        let minimum = TextDocumentEditing.adjustingIndentation(
            of: blockID,
            by: -100,
            in: maximum
        )
        XCTAssertEqual(try XCTUnwrap(minimum.blocks.first).indentationLevel, 0)

        let unchanged = TextDocumentEditing.adjustingIndentation(
            of: blockID,
            by: -1,
            in: minimum
        )
        XCTAssertEqual(unchanged, minimum)

        let positiveOverflow = TextDocumentEditing.adjustingIndentation(
            of: blockID,
            by: Int.max,
            in: maximum
        )
        XCTAssertEqual(try XCTUnwrap(positiveOverflow.blocks.first).indentationLevel, 32)

        let negativeOverflow = TextDocumentEditing.adjustingIndentation(
            of: blockID,
            by: Int.min,
            in: minimum
        )
        XCTAssertEqual(try XCTUnwrap(negativeOverflow.blocks.first).indentationLevel, 0)
    }

    func testInsertionRejectsDuplicateIDAndMissingAnchor() {
        let existing = makeBlock(text: "Existing")
        let document = TextDocument(blocks: [existing])

        let duplicate = TextDocumentEditing.inserting(existing, after: existing.id, in: document)
        XCTAssertEqual(duplicate, document)

        let newBlock = makeBlock(text: "New")
        let missingAnchor = TextDocumentEditing.inserting(
            newBlock,
            after: TextBlockID(),
            in: document
        )
        XCTAssertEqual(missingAnchor, document)

        let inserted = TextDocumentEditing.inserting(newBlock, after: existing.id, in: document)
        XCTAssertEqual(inserted.blocks.map(\.id), [existing.id, newBlock.id])
    }

    func testInsertionHonorsDurableBlockCountLimit() {
        let existing = makeBlock(text: "Existing")
        let fullDocument = TextDocument(
            blocks: Array(
                repeating: existing,
                count: TextDocumentEditing.maximumBlockCount
            )
        )

        let unchanged = TextDocumentEditing.inserting(
            makeBlock(text: "Too many"),
            after: existing.id,
            in: fullDocument
        )

        XCTAssertEqual(unchanged.blocks.count, TextDocumentEditing.maximumBlockCount)
        XCTAssertEqual(unchanged, fullDocument)
    }

    func testNumberingRestartsAcrossStylesAndIndentationLevels() {
        let first = TextDocumentEditing.makeBlock(style: .numberedList)
        let second = TextDocumentEditing.makeBlock(style: .numberedList)
        var nested = TextDocumentEditing.makeBlock(style: .numberedList)
        nested.indentationLevel = 1
        let body = TextDocumentEditing.makeBlock(style: .body)
        let restarted = TextDocumentEditing.makeBlock(style: .numberedList)
        let document = TextDocument(blocks: [first, second, nested, body, restarted])

        XCTAssertEqual(TextDocumentEditing.numberedOrdinal(for: first.id, in: document), 1)
        XCTAssertEqual(TextDocumentEditing.numberedOrdinal(for: second.id, in: document), 2)
        XCTAssertEqual(TextDocumentEditing.numberedOrdinal(for: nested.id, in: document), 1)
        XCTAssertEqual(TextDocumentEditing.numberedOrdinal(for: restarted.id, in: document), 1)
    }

    func testModifiedTimestampNeverRegresses() throws {
        let createdAt = Date(timeIntervalSince1970: 300)
        let futureModifiedAt = Date(timeIntervalSince1970: 500)
        let block = TextBlock(
            style: .body,
            text: "Before",
            createdAt: createdAt,
            modifiedAt: futureModifiedAt
        )
        let document = TextDocument(blocks: [block])

        let updated = TextDocumentEditing.settingText(
            "After",
            for: block.id,
            in: document,
            now: Date(timeIntervalSince1970: 400)
        )

        XCTAssertEqual(try XCTUnwrap(updated.blocks.first).modifiedAt, futureModifiedAt)
    }

    func testCaptureMarkerConfigurationsCoverEveryKindWithStableSemantics() {
        let configurations = TextDocumentCaptureMarkerConfiguration.all

        XCTAssertEqual(configurations.map(\.kind), CaptureKind.allCases)
        XCTAssertEqual(Set(configurations.map(\.accessibilityIdentifier)), [
            "capture.kind.professorEmphasis",
            "capture.kind.learningGap",
            "capture.kind.assignmentCandidate",
            "capture.kind.examCandidate",
            "capture.kind.researchIdea",
            "capture.kind.currentAffairsLink",
            "capture.kind.evidenceCandidate",
        ])
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: configurations.map { ($0.kind, $0.symbolName) }),
            [
                .professorEmphasis: "highlighter",
                .learningGap: "questionmark.circle",
                .assignmentCandidate: "checklist",
                .examCandidate: "graduationcap",
                .researchIdea: "lightbulb",
                .currentAffairsLink: "newspaper",
                .evidenceCandidate: "quote.bubble",
            ]
        )
    }

    func testCaptureTargetRequiresNonblankNondividerExactBlock() {
        let eligible = makeBlock(text: "  Important point  ")
        let whitespace = makeBlock(text: " \n\t ")
        let divider = TextBlock(
            style: .divider,
            text: "",
            createdAt: Date(timeIntervalSince1970: 100),
            modifiedAt: Date(timeIntervalSince1970: 100)
        )
        let document = TextDocument(blocks: [eligible, whitespace, divider])

        XCTAssertEqual(
            TextDocumentCaptureTargeting.eligibleBlockID(
                preferredBlockID: eligible.id,
                in: document
            ),
            eligible.id
        )
        XCTAssertNil(TextDocumentCaptureTargeting.eligibleBlockID(
            preferredBlockID: whitespace.id,
            in: document
        ))
        XCTAssertNil(TextDocumentCaptureTargeting.eligibleBlockID(
            preferredBlockID: divider.id,
            in: document
        ))
        XCTAssertNil(TextDocumentCaptureTargeting.eligibleBlockID(
            preferredBlockID: TextBlockID(),
            in: document
        ))
    }

    func testCapturePhaseRetainsTargetAndLocksOnlyForSavingOrFailure() {
        let saving = TextDocumentCapturePhase.saving(.examCandidate)
        let failed = TextDocumentCapturePhase.failed(message: "Try again")
        let succeeded = TextDocumentCapturePhase.succeeded(message: "Added")

        XCTAssertEqual(saving.inFlightKind, .examCandidate)
        XCTAssertTrue(saving.retainsCaptureTarget)
        XCTAssertTrue(saving.disablesMarkerControls)
        XCTAssertTrue(failed.retainsCaptureTarget)
        XCTAssertTrue(failed.disablesMarkerControls)
        XCTAssertFalse(succeeded.retainsCaptureTarget)
        XCTAssertFalse(succeeded.disablesMarkerControls)
        XCTAssertFalse(TextDocumentCapturePhase.ready.retainsCaptureTarget)
        XCTAssertFalse(TextDocumentCapturePhase.ready.disablesMarkerControls)
    }

    private func makeBlock(
        id: TextBlockID = TextBlockID(),
        text: String,
        timestamp: Date = Date(timeIntervalSince1970: 100)
    ) -> TextBlock {
        TextBlock(
            id: id,
            style: .body,
            text: text,
            createdAt: timestamp,
            modifiedAt: timestamp
        )
    }
}
