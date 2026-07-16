import Foundation
import NotesCore
@testable import NextStepAcademic
import XCTest

final class AcademicWorkspaceCommandTests: XCTestCase {
    func testReplaceCourseScheduleUsesOptimisticRevisionAndPreservesOtherCourses() throws {
        let timestamp = testCreatedAt.addingTimeInterval(60)
        let course = try makeCommandCourse(id: testCourseID, name: "Algorithms")
        let other = try makeCommandCourse(
            id: CourseID(testUUID(590)),
            name: "Databases"
        )
        let rule = try CourseScheduleRule(
            id: CourseScheduleRuleID(testUUID(591)),
            courseID: course.id,
            isoWeekday: 2,
            startMinute: 14 * 60 + 10,
            durationMinutes: 180,
            timeZoneIdentifier: "Asia/Taipei"
        )
        let baseline = try AcademicWorkspaceContent(courses: [course, other])

        let updated = try apply(
            .replaceCourseSchedule(
                id: course.id,
                expectedRevision: course.revision,
                rules: [rule],
                at: timestamp
            ),
            to: baseline
        )

        let savedCourse = try XCTUnwrap(updated.courses.first { $0.id == course.id })
        XCTAssertEqual(savedCourse.scheduleRules, [rule])
        XCTAssertEqual(savedCourse.revision, course.revision + 1)
        XCTAssertEqual(savedCourse.modifiedAt, timestamp)
        XCTAssertEqual(updated.courses.first { $0.id == other.id }, other)
        XCTAssertTrue(course.scheduleRules.isEmpty)
    }

    func testReplaceCourseScheduleRejectsStaleRevisionWithoutChangingInput() throws {
        let course = try makeCommandCourse(id: testCourseID, name: "Algorithms")
        let baseline = try AcademicWorkspaceContent(courses: [course])
        let workspace = try commandWorkspace(baseline)
        let command = AcademicWorkspaceCommand.replaceCourseSchedule(
            id: course.id,
            expectedRevision: course.revision + 1,
            rules: [],
            at: testCreatedAt.addingTimeInterval(60)
        )

        XCTAssertThrowsError(try command.applying(to: workspace)) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .revisionConflict(
                    expected: course.revision + 1,
                    actual: course.revision
                )
            )
        }
        XCTAssertEqual(workspace.content, baseline)
    }

    func testAllV1CommandsComposeThroughSendableStoreTransform() throws {
        let course = try makeCommandCourse(id: testCourseID, name: "Algorithms")
        let plannedSession = try CourseSession(
            id: testSessionID,
            courseID: course.id,
            topic: "Graph traversal",
            createdAt: testCreatedAt
        )
        let link = try SessionNoteLink(
            id: SessionNoteLinkID(testUUID(601)),
            sessionID: plannedSession.id,
            noteID: NotebookID(testUUID(602)),
            initialPageID: PageID(testUUID(603)),
            linkedAt: testCreatedAt
        )
        let capture = try makeQuickCapture(
            idSeed: 604,
            kind: .professorEmphasis
        )

        var content = AcademicWorkspaceContent.empty
        for command in [
            AcademicWorkspaceCommand.addCourse(course),
            .addSession(plannedSession),
            .addSessionNoteLink(link),
            .addCapture(capture),
        ] {
            content = try apply(command, to: content)
        }

        content = try apply(
            .transitionSession(
                id: plannedSession.id,
                expectedRevision: plannedSession.revision,
                to: .active,
                at: testStartedAt
            ),
            to: content
        )
        let active = try XCTUnwrap(content.sessions.first)
        content = try apply(
            .transitionSession(
                id: active.id,
                expectedRevision: active.revision,
                to: .needsReview,
                at: testStartedAt.addingTimeInterval(600)
            ),
            to: content
        )
        let needsReview = try XCTUnwrap(content.sessions.first)
        let decision = try SessionWrapUpDecision(
            captureID: capture.id,
            expectedRevision: capture.revision,
            kind: .keepAsIs
        )
        let transaction = try SessionWrapUpTransaction(
            sessionID: needsReview.id,
            expectedSessionRevision: needsReview.revision,
            wrapUpID: SessionWrapUpID(testUUID(606)),
            startedAt: needsReview.modifiedAt,
            completedAt: testCompletedAt,
            oneLineSummary: "Reviewed the traversal strategy.",
            noNewActionsConfirmed: false,
            decisions: [decision]
        )
        let command = AcademicWorkspaceCommand.applyWrapUp(transaction)
        let transform: @Sendable (AcademicWorkspace) throws -> AcademicWorkspaceContent = {
            try command.applying(to: $0)
        }
        content = try transform(try commandWorkspace(content))

        let reviewed = try XCTUnwrap(content.sessions.first)
        XCTAssertEqual(reviewed.status, .reviewed)
        XCTAssertEqual(reviewed.revision, 4)
        XCTAssertEqual(content.sessionNoteLinks, [link])
        XCTAssertEqual(content.captures, [capture])
        XCTAssertEqual(content.wrapUps.map(\.id), [transaction.wrapUpID])
    }

    func testAddCommandsDelegateDuplicateAndMissingRelationshipsToWorkspaceValidation() throws {
        let course = try makeCommandCourse(id: testCourseID, name: "Calculus")
        let withCourse = try apply(.addCourse(course), to: .empty)

        XCTAssertThrowsError(try apply(.addCourse(course), to: withCourse)) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .duplicateIdentifier(
                    entity: "course",
                    identifier: course.id.description
                )
            )
        }

        let orphan = try CourseSession(
            id: testSessionID,
            courseID: CourseID(testUUID(699)),
            createdAt: testCreatedAt
        )
        XCTAssertThrowsError(try apply(.addSession(orphan), to: .empty)) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .missingEntity(
                    entity: "course",
                    identifier: orphan.courseID.description
                )
            )
        }

        XCTAssertThrowsError(try apply(
            .transitionSession(
                id: testSessionID,
                expectedRevision: 1,
                to: .active,
                at: testStartedAt
            ),
            to: withCourse
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .missingEntity(
                    entity: "course session",
                    identifier: testSessionID.description
                )
            )
        }
    }

    func testCompositeCommandAtomicallyAddsSessionAndMatchingNoteLink() throws {
        let course = try makeCommandCourse(
            id: CourseID(testUUID(650)),
            name: "Databases"
        )
        let session = try CourseSession(
            id: CourseSessionID(testUUID(651)),
            courseID: course.id,
            createdAt: testCreatedAt
        )
        let link = try SessionNoteLink(
            id: SessionNoteLinkID(testUUID(652)),
            sessionID: session.id,
            noteID: NotebookID(testUUID(653)),
            initialPageID: PageID(testUUID(654)),
            linkedAt: testCreatedAt
        )
        let baseline = try AcademicWorkspaceContent(courses: [course])

        let result = try apply(
            .addSessionWithNoteLink(session: session, link: link),
            to: baseline
        )

        XCTAssertEqual(result.sessions, [session])
        XCTAssertEqual(result.sessionNoteLinks, [link])
        XCTAssertEqual(baseline.sessions, [])
        XCTAssertEqual(baseline.sessionNoteLinks, [])
    }

    func testCompositeCommandRejectsMismatchedSessionAndLinkWithoutPartialContent() throws {
        let course = try makeCommandCourse(
            id: CourseID(testUUID(660)),
            name: "Operating Systems"
        )
        let session = try CourseSession(
            id: CourseSessionID(testUUID(661)),
            courseID: course.id,
            createdAt: testCreatedAt
        )
        let mismatchedLink = try SessionNoteLink(
            id: SessionNoteLinkID(testUUID(662)),
            sessionID: CourseSessionID(testUUID(663)),
            noteID: NotebookID(testUUID(664)),
            linkedAt: testCreatedAt
        )
        let baseline = try AcademicWorkspaceContent(courses: [course])
        let workspace = try commandWorkspace(baseline)
        let command = AcademicWorkspaceCommand.addSessionWithNoteLink(
            session: session,
            link: mismatchedLink
        )

        XCTAssertThrowsError(try command.applying(to: workspace)) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .relationshipMismatch(
                    "A composite session note link must belong to its new course session."
                )
            )
        }
        XCTAssertEqual(workspace.content, baseline)
    }

    func testCompositeCommandDuplicateFailureDoesNotExposeAnExtraSessionOrLink() throws {
        let course = try makeCommandCourse(
            id: CourseID(testUUID(670)),
            name: "Statistics"
        )
        let session = try CourseSession(
            id: CourseSessionID(testUUID(671)),
            courseID: course.id,
            createdAt: testCreatedAt
        )
        let link = try SessionNoteLink(
            id: SessionNoteLinkID(testUUID(672)),
            sessionID: session.id,
            noteID: NotebookID(testUUID(673)),
            linkedAt: testCreatedAt
        )
        let command = AcademicWorkspaceCommand.addSessionWithNoteLink(
            session: session,
            link: link
        )
        let baseline = try AcademicWorkspaceContent(courses: [course])
        let first = try apply(command, to: baseline)
        let firstWorkspace = try commandWorkspace(first)

        XCTAssertThrowsError(try command.applying(to: firstWorkspace)) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .duplicateIdentifier(
                    entity: "course session",
                    identifier: session.id.description
                )
            )
        }
        XCTAssertEqual(firstWorkspace.content, first)
        XCTAssertEqual(first.sessions, [session])
        XCTAssertEqual(first.sessionNoteLinks, [link])
    }

    func testTransitionSessionRejectsAStaleRevisionWithoutChangingInput() throws {
        let course = try makeCommandCourse(id: testCourseID, name: "Physics")
        let session = try CourseSession(
            id: testSessionID,
            courseID: course.id,
            createdAt: testCreatedAt
        )
        let content = try AcademicWorkspaceContent(
            courses: [course],
            sessions: [session]
        )
        let workspace = try commandWorkspace(content)
        let command = AcademicWorkspaceCommand.transitionSession(
            id: session.id,
            expectedRevision: session.revision + 1,
            to: .active,
            at: testStartedAt
        )

        XCTAssertThrowsError(try command.applying(to: workspace)) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .revisionConflict(
                    expected: session.revision + 1,
                    actual: session.revision
                )
            )
        }
        XCTAssertEqual(workspace.content, content)
    }

    func testWrapUpFailureIsAtomicAfterAnEarlierDecisionWouldSucceed() throws {
        let course = try makeCommandCourse(id: testCourseID, name: "Chemistry")
        let session = try makeActiveSession()
        let firstCapture = try makeQuickCapture(
            idSeed: 710,
            kind: .learningGap
        )
        let staleCapture = try makeQuickCapture(
            idSeed: 720,
            kind: .examCandidate
        )
        let content = try AcademicWorkspaceContent(
            courses: [course],
            sessions: [session],
            captures: [staleCapture, firstCapture]
        )
        let firstDecision = try SessionWrapUpDecision(
            captureID: firstCapture.id,
            expectedRevision: firstCapture.revision,
            kind: .markNeedsDetails,
            auditIDs: [CaptureAuditEntryID(testUUID(711))]
        )
        let staleDecision = try SessionWrapUpDecision(
            captureID: staleCapture.id,
            expectedRevision: staleCapture.revision + 1,
            kind: .markNeedsDetails,
            auditIDs: [CaptureAuditEntryID(testUUID(721))]
        )
        let transaction = try SessionWrapUpTransaction(
            sessionID: session.id,
            expectedSessionRevision: session.revision,
            wrapUpID: SessionWrapUpID(testUUID(730)),
            startedAt: testStartedAt.addingTimeInterval(60),
            completedAt: testCompletedAt,
            oneLineSummary: "One candidate still has a stale revision.",
            noNewActionsConfirmed: false,
            decisions: [staleDecision, firstDecision]
        )
        let workspace = try commandWorkspace(content)
        let command = AcademicWorkspaceCommand.applyWrapUp(transaction)

        XCTAssertThrowsError(try command.applying(to: workspace)) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .revisionConflict(
                    expected: staleCapture.revision + 1,
                    actual: staleCapture.revision
                )
            )
        }
        XCTAssertEqual(workspace.content, content)
        XCTAssertEqual(workspace.sessions.first?.status, .active)
        XCTAssertTrue(workspace.wrapUps.isEmpty)
        XCTAssertEqual(workspace.captures, [firstCapture, staleCapture])
    }

    func testAddCommandsAlwaysReturnCanonicalCollectionOrder() throws {
        let lowerCourse = try makeCommandCourse(
            id: CourseID(testUUID(801)),
            name: "Lower course"
        )
        let higherCourse = try makeCommandCourse(
            id: CourseID(testUUID(802)),
            name: "Higher course"
        )
        let lowerSession = try CourseSession(
            id: CourseSessionID(testUUID(811)),
            courseID: lowerCourse.id,
            createdAt: testCreatedAt
        )
        let higherSession = try CourseSession(
            id: CourseSessionID(testUUID(812)),
            courseID: higherCourse.id,
            createdAt: testCreatedAt
        )
        let lowerLink = try SessionNoteLink(
            id: SessionNoteLinkID(testUUID(821)),
            sessionID: lowerSession.id,
            noteID: NotebookID(testUUID(831)),
            linkedAt: testCreatedAt
        )
        let higherLink = try SessionNoteLink(
            id: SessionNoteLinkID(testUUID(822)),
            sessionID: higherSession.id,
            noteID: NotebookID(testUUID(832)),
            linkedAt: testCreatedAt
        )
        let lowerCapture = try makeQuickCapture(
            idSeed: 841,
            kind: .researchIdea,
            courseID: lowerCourse.id,
            sessionID: lowerSession.id
        )
        let higherCapture = try makeQuickCapture(
            idSeed: 842,
            kind: .professorEmphasis,
            courseID: higherCourse.id,
            sessionID: higherSession.id
        )

        var content = AcademicWorkspaceContent.empty
        for command in [
            AcademicWorkspaceCommand.addCourse(higherCourse),
            .addCourse(lowerCourse),
            .addSession(higherSession),
            .addSession(lowerSession),
            .addSessionNoteLink(higherLink),
            .addSessionNoteLink(lowerLink),
            .addCapture(higherCapture),
            .addCapture(lowerCapture),
        ] {
            let workspace = try commandWorkspace(content)
            let first = try command.applying(to: workspace)
            let second = try command.applying(to: workspace)
            XCTAssertEqual(first, second, "Pure application must be deterministic.")
            content = first
        }

        XCTAssertEqual(content.courses.map(\.id), [lowerCourse.id, higherCourse.id])
        XCTAssertEqual(content.sessions.map(\.id), [lowerSession.id, higherSession.id])
        XCTAssertEqual(content.sessionNoteLinks.map(\.id), [lowerLink.id, higherLink.id])
        XCTAssertEqual(content.captures.map(\.id), [lowerCapture.id, higherCapture.id])
    }
}

private let commandSavedAt = testCompletedAt.addingTimeInterval(3_600)

private func commandWorkspace(
    _ content: AcademicWorkspaceContent
) throws -> AcademicWorkspace {
    try AcademicWorkspace(
        revision: 0,
        savedAt: commandSavedAt,
        content: content
    )
}

private func apply(
    _ command: AcademicWorkspaceCommand,
    to content: AcademicWorkspaceContent
) throws -> AcademicWorkspaceContent {
    try command.applying(to: commandWorkspace(content))
}

private func makeCommandCourse(
    id: CourseID,
    name: String
) throws -> Course {
    try Course(
        id: id,
        name: name,
        timeZoneIdentifier: "Asia/Taipei",
        createdAt: testCreatedAt
    )
}
