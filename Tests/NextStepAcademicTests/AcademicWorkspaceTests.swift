import Foundation
import NotesCore
@testable import NextStepAcademic
import XCTest

final class AcademicWorkspaceTests: XCTestCase {
    func testWorkspaceCanonicalizesEveryTopLevelCollectionAndRoundTrips() throws {
        let secondCourse = try makeAcademicCourse(
            id: CourseID(testUUID(602)),
            name: "Algorithms"
        )
        let firstCourse = try makeAcademicCourse(
            id: CourseID(testUUID(601)),
            name: "Databases"
        )
        let secondSession = try CourseSession(
            id: CourseSessionID(testUUID(612)),
            courseID: secondCourse.id,
            createdAt: testCreatedAt
        )
        let firstSession = try CourseSession(
            id: CourseSessionID(testUUID(611)),
            courseID: firstCourse.id,
            createdAt: testCreatedAt
        )
        let workspace = try AcademicWorkspace(
            revision: 7,
            savedAt: testCompletedAt,
            courses: [secondCourse, firstCourse],
            sessions: [secondSession, firstSession]
        )

        XCTAssertEqual(workspace.courses.map(\.id), [firstCourse.id, secondCourse.id])
        XCTAssertEqual(workspace.sessions.map(\.id), [firstSession.id, secondSession.id])
        XCTAssertEqual(workspace.content.courses, workspace.courses)
        try assertCodableRoundTrip(workspace)
    }

    func testWorkspaceAcceptsOneFullyRelatedReviewedSessionGraph() throws {
        let fixture = try makeReviewedAcademicFixture()
        let workspace = try AcademicWorkspace(
            revision: 3,
            savedAt: testCompletedAt,
            content: fixture.content
        )

        XCTAssertEqual(workspace.courses, [fixture.course])
        XCTAssertEqual(workspace.sessions, [fixture.reviewedSession])
        XCTAssertEqual(workspace.sessionNoteLinks, [fixture.link])
        XCTAssertEqual(workspace.captures, [fixture.capture])
        XCTAssertEqual(workspace.wrapUps, [fixture.wrapUp])
        try assertCodableRoundTrip(workspace)
    }

    func testWorkspaceBoundsAndGlobalIdentifiersFailClosed() throws {
        let course = try makeAcademicCourse()
        XCTAssertThrowsError(try AcademicWorkspaceContent(
            courses: Array(
                repeating: course,
                count: AcademicWorkspaceLimits.maximumCourses + 1
            )
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .valueOutOfBounds(field: "workspace.courses")
            )
        }
        XCTAssertThrowsError(try AcademicWorkspaceContent(courses: [course, course]))

        let sharedAuditID = CaptureAuditEntryID(testUUID(620))
        let firstCapture = try CaptureItem.create(
            id: CaptureItemID(testUUID(621)),
            kind: .researchIdea,
            source: .quickCapture(try QuickCaptureReference()),
            rawText: "First idea",
            draftFields: try CaptureDraftFields(),
            capturedAt: testStartedAt,
            auditID: sharedAuditID
        )
        let secondCapture = try CaptureItem.create(
            id: CaptureItemID(testUUID(622)),
            kind: .researchIdea,
            source: .quickCapture(try QuickCaptureReference()),
            rawText: "Second idea",
            draftFields: try CaptureDraftFields(),
            capturedAt: testStartedAt,
            auditID: sharedAuditID
        )
        XCTAssertThrowsError(try AcademicWorkspaceContent(
            captures: [firstCapture, secondCapture]
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .duplicateIdentifier(
                    entity: "capture audit entry",
                    identifier: sharedAuditID.description
                )
            )
        }
    }

    func testWorkspaceRejectsMissingAndMismatchedRelationships() throws {
        let course = try makeAcademicCourse()
        let session = try CourseSession(
            id: testSessionID,
            courseID: course.id,
            createdAt: testCreatedAt
        )
        XCTAssertThrowsError(try AcademicWorkspaceContent(sessions: [session]))

        let link = try SessionNoteLink(
            sessionID: session.id,
            noteID: NotebookID(testUUID(630)),
            linkedAt: testCreatedAt
        )
        XCTAssertThrowsError(try AcademicWorkspaceContent(
            courses: [course],
            sessionNoteLinks: [link]
        ))

        let foreignCourse = try makeAcademicCourse(
            id: CourseID(testUUID(631)),
            name: "Foreign course"
        )
        let capture = try makeQuickCapture(
            idSeed: 632,
            kind: .learningGap,
            courseID: foreignCourse.id,
            sessionID: session.id
        )
        XCTAssertThrowsError(try AcademicWorkspaceContent(
            courses: [course, foreignCourse],
            sessions: [session],
            captures: [capture]
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .relationshipMismatch(
                    "A session capture must reference the session's course."
                )
            )
        }
    }

    func testAnchoredCaptureRequiresMatchingSessionNoteLinkAtCaptureTime() throws {
        let course = try makeAcademicCourse()
        let session = try makeActiveSession()
        let noteID = NotebookID(testUUID(640))
        let anchor = try SourceAnchor(
            id: SourceAnchorID(testUUID(641)),
            noteID: noteID,
            pageID: PageID(testUUID(642)),
            blockID: TextBlockID(testUUID(643)),
            noteRevision: 3,
            capturedAt: testStartedAt
        )
        let capture = try CaptureItem.create(
            id: CaptureItemID(testUUID(644)),
            kind: .professorEmphasis,
            source: .noteAnchor(anchor),
            courseID: course.id,
            sessionID: session.id,
            draftFields: try CaptureDraftFields(),
            capturedAt: testStartedAt,
            auditID: CaptureAuditEntryID(testUUID(645))
        )

        XCTAssertThrowsError(try AcademicWorkspaceContent(
            courses: [course],
            sessions: [session],
            captures: [capture]
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .relationshipMismatch(
                    "A note-anchored capture requires one session note link spanning anchor and capture times."
                )
            )
        }

        let expiredAtCaptureTime = try SessionNoteLink(
            id: SessionNoteLinkID(testUUID(647)),
            sessionID: session.id,
            noteID: noteID,
            linkedAt: testCreatedAt,
            unlinkedAt: testStartedAt
        )
        XCTAssertThrowsError(try AcademicWorkspaceContent(
            courses: [course],
            sessions: [session],
            sessionNoteLinks: [expiredAtCaptureTime],
            captures: [capture]
        ))

        let link = try SessionNoteLink(
            id: SessionNoteLinkID(testUUID(646)),
            sessionID: session.id,
            noteID: noteID,
            linkedAt: testStartedAt
        )
        XCTAssertNoThrow(try AcademicWorkspaceContent(
            courses: [course],
            sessions: [session],
            sessionNoteLinks: [link],
            captures: [capture]
        ))

        let preLinkAnchor = try SourceAnchor(
            id: SourceAnchorID(testUUID(648)),
            noteID: noteID,
            pageID: PageID(testUUID(649)),
            blockID: TextBlockID(testUUID(650)),
            noteRevision: 4,
            capturedAt: testCreatedAt
        )
        let createdAfterLink = try CaptureItem.create(
            id: CaptureItemID(testUUID(651)),
            kind: .professorEmphasis,
            source: .noteAnchor(preLinkAnchor),
            courseID: course.id,
            sessionID: session.id,
            draftFields: try CaptureDraftFields(),
            capturedAt: testStartedAt,
            auditID: CaptureAuditEntryID(testUUID(652))
        )
        XCTAssertThrowsError(try AcademicWorkspaceContent(
            courses: [course],
            sessions: [session],
            sessionNoteLinks: [link],
            captures: [createdAfterLink]
        ))

        let linkEndingAfterAnchor = try SessionNoteLink(
            id: SessionNoteLinkID(testUUID(653)),
            sessionID: session.id,
            noteID: noteID,
            linkedAt: testCreatedAt,
            unlinkedAt: testStartedAt.addingTimeInterval(1)
        )
        let createdAfterUnlink = try CaptureItem.create(
            id: CaptureItemID(testUUID(654)),
            kind: .professorEmphasis,
            source: .noteAnchor(anchor),
            courseID: course.id,
            sessionID: session.id,
            draftFields: try CaptureDraftFields(),
            capturedAt: testStartedAt.addingTimeInterval(2),
            auditID: CaptureAuditEntryID(testUUID(655))
        )
        XCTAssertThrowsError(try AcademicWorkspaceContent(
            courses: [course],
            sessions: [session],
            sessionNoteLinks: [linkEndingAfterAnchor],
            captures: [createdAfterUnlink]
        ))
    }

    func testLectureNoteOwnershipCannotOverlapAcrossSessionsButMayTransfer() throws {
        let course = try makeAcademicCourse()
        let firstSession = try CourseSession(
            id: CourseSessionID(testUUID(660)),
            courseID: course.id,
            createdAt: testCreatedAt
        )
        let secondSession = try CourseSession(
            id: CourseSessionID(testUUID(661)),
            courseID: course.id,
            createdAt: testCreatedAt
        )
        let noteID = NotebookID(testUUID(662))
        let firstActive = try SessionNoteLink(
            id: SessionNoteLinkID(testUUID(663)),
            sessionID: firstSession.id,
            noteID: noteID,
            linkedAt: testCreatedAt
        )
        let secondOverlapping = try SessionNoteLink(
            id: SessionNoteLinkID(testUUID(664)),
            sessionID: secondSession.id,
            noteID: noteID,
            linkedAt: testStartedAt
        )
        XCTAssertThrowsError(try AcademicWorkspaceContent(
            courses: [course],
            sessions: [firstSession, secondSession],
            sessionNoteLinks: [firstActive, secondOverlapping]
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .relationshipMismatch(
                    "A lecture note can belong to only one course session at a time."
                )
            )
        }

        let transferTime = testStartedAt.addingTimeInterval(30)
        let firstEnded = try SessionNoteLink(
            id: firstActive.id,
            sessionID: firstSession.id,
            noteID: noteID,
            linkedAt: firstActive.linkedAt,
            unlinkedAt: transferTime
        )
        let secondAtBoundary = try SessionNoteLink(
            id: secondOverlapping.id,
            sessionID: secondSession.id,
            noteID: noteID,
            linkedAt: transferTime
        )
        XCTAssertNoThrow(try AcademicWorkspaceContent(
            courses: [course],
            sessions: [firstSession, secondSession],
            sessionNoteLinks: [firstEnded, secondAtBoundary]
        ))
    }

    func testWorkspaceRequiresWrapUpAndReviewedCaptureConsistency() throws {
        let fixture = try makeReviewedAcademicFixture(seed: 650)
        XCTAssertThrowsError(try AcademicWorkspaceContent(
            courses: [fixture.course],
            sessions: [fixture.reviewedSession],
            sessionNoteLinks: [fixture.link],
            captures: [fixture.capture]
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .relationshipMismatch(
                    "Every reviewed course session must have one wrap-up."
                )
            )
        }

        XCTAssertThrowsError(try AcademicWorkspaceContent(
            courses: [fixture.course],
            sessions: [fixture.reviewedSession],
            sessionNoteLinks: [fixture.link],
            captures: [],
            wrapUps: [fixture.wrapUp]
        )) { error in
            guard let domainError = error as? AcademicDomainError,
                  case let .missingEntity(entity, _) = domainError,
                  entity == "capture item" else {
                return XCTFail("Expected a missing reviewed capture, received \(error).")
            }
        }

        XCTAssertThrowsError(try AcademicWorkspaceContent(
            courses: [fixture.course],
            sessions: [fixture.activeSession],
            sessionNoteLinks: [fixture.link],
            captures: [fixture.capture],
            wrapUps: [fixture.wrapUp]
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .relationshipMismatch(
                    "A session wrap-up requires a reviewed course session."
                )
            )
        }
    }

    func testReviewedSessionCaptureHistoryExactlyMatchesWrapUpBoundary() throws {
        let course = try makeAcademicCourse()
        let active = try makeActiveSession()
        let rejectedInput = try makeQuickCapture(
            idSeed: 680,
            kind: .learningGap
        )
        let rejectDecision = try SessionWrapUpDecision(
            captureID: rejectedInput.id,
            expectedRevision: rejectedInput.revision,
            kind: .reject,
            rejectionReason: "Not actionable after review.",
            auditIDs: [CaptureAuditEntryID(testUUID(682))]
        )
        let rejectTransaction = try SessionWrapUpTransaction(
            sessionID: active.id,
            expectedSessionRevision: active.revision,
            wrapUpID: SessionWrapUpID(testUUID(683)),
            startedAt: testStartedAt.addingTimeInterval(60),
            completedAt: testCompletedAt,
            oneLineSummary: "Rejected the non-actionable learning gap.",
            noNewActionsConfirmed: false,
            decisions: [rejectDecision]
        )
        let rejectedResult = try rejectTransaction.applying(
            to: active,
            captures: [rejectedInput]
        )
        let omittedRejectedCapture = try SessionWrapUp(
            id: rejectedResult.wrapUp.id,
            sessionID: active.id,
            startedAt: rejectedResult.wrapUp.startedAt,
            completedAt: rejectedResult.wrapUp.completedAt,
            oneLineSummary: rejectedResult.wrapUp.oneLineSummary,
            noNewActionsConfirmed: true,
            reviewedCaptureIDs: []
        )
        XCTAssertThrowsError(try AcademicWorkspaceContent(
            courses: [course],
            sessions: [rejectedResult.session],
            captures: rejectedResult.captures,
            wrapUps: [omittedRejectedCapture]
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .relationshipMismatch(
                    "A capture resolved by a wrap-up must appear in its reviewed captures."
                )
            )
        }

        let fixture = try makeReviewedAcademicFixture(seed: 710)
        let resolvedBeforeWrap = try makeQuickCapture(
            idSeed: 720,
            kind: .researchIdea
        ).rejecting(
            reason: "Resolved before wrap-up.",
            at: testStartedAt.addingTimeInterval(10),
            auditID: CaptureAuditEntryID(testUUID(722))
        )
        let incorrectlyReviewed = try SessionWrapUp(
            id: fixture.wrapUp.id,
            sessionID: fixture.wrapUp.sessionID,
            startedAt: fixture.wrapUp.startedAt,
            completedAt: fixture.wrapUp.completedAt,
            oneLineSummary: fixture.wrapUp.oneLineSummary,
            noNewActionsConfirmed: false,
            reviewedCaptureIDs: [fixture.capture.id, resolvedBeforeWrap.id]
        )
        XCTAssertThrowsError(try AcademicWorkspaceContent(
            courses: [fixture.course],
            sessions: [fixture.reviewedSession],
            sessionNoteLinks: [fixture.link],
            captures: [fixture.capture, resolvedBeforeWrap],
            wrapUps: [incorrectlyReviewed]
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .relationshipMismatch(
                    "A resolved reviewed capture must be resolved by its wrap-up."
                )
            )
        }

        let createdAfterWrap = try CaptureItem.create(
            id: CaptureItemID(testUUID(730)),
            kind: .researchIdea,
            source: .quickCapture(try QuickCaptureReference()),
            courseID: fixture.course.id,
            sessionID: fixture.reviewedSession.id,
            rawText: "Late capture",
            draftFields: try CaptureDraftFields(),
            capturedAt: testCompletedAt.addingTimeInterval(1),
            auditID: CaptureAuditEntryID(testUUID(731))
        ).rejecting(
            reason: "Also too late.",
            at: testCompletedAt.addingTimeInterval(2),
            auditID: CaptureAuditEntryID(testUUID(732))
        )
        XCTAssertThrowsError(try AcademicWorkspaceContent(
            courses: [fixture.course],
            sessions: [fixture.reviewedSession],
            sessionNoteLinks: [fixture.link],
            captures: [fixture.capture, createdAfterWrap],
            wrapUps: [fixture.wrapUp]
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .chronologyViolation(
                    "A reviewed session cannot gain captures after its wrap-up."
                )
            )
        }
    }

    func testWorkspaceSavedAtAndRevisionAreStrict() throws {
        let fixture = try makeReviewedAcademicFixture(seed: 670)
        XCTAssertThrowsError(try AcademicWorkspace(
            revision: -1,
            savedAt: testCompletedAt,
            content: fixture.content
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .valueOutOfBounds(field: "workspace.revision")
            )
        }
        XCTAssertThrowsError(try AcademicWorkspace(
            revision: 1,
            savedAt: testStartedAt,
            content: fixture.content
        ))
        XCTAssertThrowsError(try AcademicWorkspace(
            revision: 1,
            savedAt: Date(timeIntervalSinceReferenceDate: .infinity),
            content: .empty
        ))
    }

    func testWorkspaceDecoderFailsClosedBeforeFuturePayloadFields() throws {
        do {
            _ = try JSONDecoder().decode(
                AcademicWorkspace.self,
                from: futureSchemaOnly()
            )
            XCTFail("A future workspace schema must fail closed.")
        } catch DecodingError.dataCorrupted(let context) {
            XCTAssertTrue(context.debugDescription.contains(
                "Unsupported academic workspace schema version 2"
            ))
        }
    }

    func testStorageVersionRejectsNegativeRevisionWithoutPathState() throws {
        XCTAssertThrowsError(try AcademicWorkspaceStorageVersion(
            rootFingerprint: AcademicWorkspaceStorageFingerprint(testUUID(690)),
            stateFingerprint: AcademicWorkspaceStateFingerprint(testUUID(691)),
            storageRevision: -1
        )) { error in
            XCTAssertEqual(
                error as? AcademicWorkspaceFileBackingError,
                .invalidStorageRevision
            )
        }
    }
}
