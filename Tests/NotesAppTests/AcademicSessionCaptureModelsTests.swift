import Foundation
import NextStepAcademic
import NotesCore
@testable import NotesApp
import XCTest

final class AcademicSessionCaptureModelsTests: XCTestCase {
    func testValidationAcceptsOnlyTheExactActiveCourseSessionNoteLink() throws {
        let fixture = try makeFixture()

        XCTAssertNoThrow(try AcademicSessionCaptureValidation.validate(
            fixture.context,
            openNotebookID: fixture.noteID.rawValue,
            at: fixture.capturedAt,
            in: fixture.workspace
        ))

        XCTAssertThrowsError(try AcademicSessionCaptureValidation.validate(
            fixture.context,
            openNotebookID: UUID(),
            at: fixture.capturedAt,
            in: fixture.workspace
        )) { error in
            XCTAssertEqual(
                error as? AcademicSessionCaptureValidationError,
                .noteMismatch
            )
        }
    }

    func testMarkerBadgesRequireExactNotePageBlockAndSession() throws {
        let blockID = TextBlockID()
        let firstPageID = PageID()
        let secondPageID = PageID()
        let fixture = try makeFixture(
            captures: { context, capturedAt in
                [
                    try makeCapture(
                        kind: .professorEmphasis,
                        context: context,
                        pageID: firstPageID,
                        blockID: blockID,
                        capturedAt: capturedAt
                    ),
                    try makeCapture(
                        kind: .evidenceCandidate,
                        context: context,
                        pageID: secondPageID,
                        blockID: blockID,
                        capturedAt: capturedAt
                    ),
                ]
            }
        )

        let firstPageMarkers = AcademicSessionCaptureValidation.markerKindsByBlock(
            for: fixture.context,
            pageID: firstPageID,
            in: fixture.workspace
        )
        let secondPageMarkers = AcademicSessionCaptureValidation.markerKindsByBlock(
            for: fixture.context,
            pageID: secondPageID,
            in: fixture.workspace
        )

        XCTAssertEqual(firstPageMarkers, [blockID: [.professorEmphasis]])
        XCTAssertEqual(secondPageMarkers, [blockID: [.evidenceCandidate]])
    }

    func testValidationTreatsUnlinkedAtAsExclusive() throws {
        let boundary = Date(timeIntervalSince1970: 120)
        let fixture = try makeFixture(unlinkedAt: boundary)

        XCTAssertThrowsError(try AcademicSessionCaptureValidation.validate(
            fixture.context,
            openNotebookID: fixture.noteID.rawValue,
            at: boundary,
            in: fixture.workspace
        )) { error in
            XCTAssertEqual(
                error as? AcademicSessionCaptureValidationError,
                .noteLinkUnavailable
            )
        }
    }

    private struct Fixture {
        let noteID: NotebookID
        let capturedAt: Date
        let context: AcademicSessionCaptureContext
        let workspace: AcademicWorkspace
    }

    private func makeFixture(
        unlinkedAt: Date? = nil,
        captures makeCaptures: (
            AcademicSessionCaptureContext,
            Date
        ) throws -> [CaptureItem] = { _, _ in [] }
    ) throws -> Fixture {
        let createdAt = Date(timeIntervalSince1970: 100)
        let startedAt = Date(timeIntervalSince1970: 110)
        let capturedAt = Date(timeIntervalSince1970: 120)
        let courseID = CourseID()
        let sessionID = CourseSessionID()
        let noteID = NotebookID()
        let course = try Course(
            id: courseID,
            name: "Biochemistry",
            timeZoneIdentifier: "UTC",
            createdAt: createdAt
        )
        let session = try CourseSession(
            id: sessionID,
            courseID: courseID,
            actualStartedAt: startedAt,
            status: .active,
            createdAt: createdAt,
            modifiedAt: startedAt
        )
        let link = try SessionNoteLink(
            sessionID: sessionID,
            noteID: noteID,
            initialPageID: PageID(),
            linkedAt: startedAt,
            unlinkedAt: unlinkedAt
        )
        let context = AcademicSessionCaptureContext(
            courseID: courseID,
            sessionID: sessionID,
            noteID: noteID
        )
        let captures = try makeCaptures(context, capturedAt)
        let workspace = try AcademicWorkspace(
            revision: 1,
            savedAt: capturedAt,
            courses: [course],
            sessions: [session],
            sessionNoteLinks: [link],
            captures: captures
        )
        return Fixture(
            noteID: noteID,
            capturedAt: capturedAt,
            context: context,
            workspace: workspace
        )
    }

    private func makeCapture(
        kind: CaptureKind,
        context: AcademicSessionCaptureContext,
        pageID: PageID,
        blockID: TextBlockID,
        capturedAt: Date
    ) throws -> CaptureItem {
        let anchor = try SourceAnchor(
            noteID: context.noteID,
            pageID: pageID,
            blockID: blockID,
            noteRevision: 1,
            textHash: String(repeating: "a", count: 64),
            capturedAt: capturedAt
        )
        return try CaptureItem.create(
            kind: kind,
            source: .noteAnchor(anchor),
            courseID: context.courseID,
            sessionID: context.sessionID,
            draftFields: CaptureDraftFields(),
            capturedAt: capturedAt
        )
    }
}
