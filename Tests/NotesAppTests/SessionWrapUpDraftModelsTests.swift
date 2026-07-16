import Foundation
import NextStepAcademic
@testable import NotesApp
import XCTest

final class SessionWrapUpDraftModelsTests: XCTestCase {
    func testDraftUsesStableChronologicalPresentationAndReservedAuditIDs() throws {
        let session = try makeActiveSession()
        let laterHighID = try makeCapture(
            idSeed: 220,
            kind: .professorEmphasis,
            session: session,
            capturedAt: time(20)
        )
        let laterLowID = try makeCapture(
            idSeed: 210,
            kind: .examCandidate,
            session: session,
            capturedAt: time(20),
            title: "Midterm scope"
        )
        let needsDetails = try laterLowID.transitioned(
            to: .needsDetails,
            at: time(21),
            auditID: auditID(211)
        )
        let ready = try needsDetails.transitioned(
            to: .readyToConfirm,
            at: time(22),
            auditID: auditID(212)
        )
        let earlier = try makeCapture(
            idSeed: 200,
            kind: .learningGap,
            session: session,
            capturedAt: time(15)
        )
        let rejected = try earlier.rejecting(
            reason: "Not actionable",
            at: time(16),
            auditID: auditID(201)
        )
        var generated = [auditID(300), auditID(301), auditID(302), auditID(303)]
            .makeIterator()

        let draft = try SessionWrapUpDraft(
            session: session,
            captures: [laterHighID, ready, rejected],
            startedAt: time(30),
            wrapUpID: wrapUpID(1),
            auditIDFactory: { generated.next()! }
        )

        XCTAssertEqual(
            draft.capturePresentations.map(\.captureID),
            [rejected.id, ready.id, laterHighID.id]
        )
        XCTAssertEqual(draft.capturePresentations[0].reservedAuditIDs, [])
        XCTAssertTrue(draft.capturePresentations[0].isAlreadyResolved)
        XCTAssertTrue(draft.capturePresentations[0].isAlreadyRejected)
        XCTAssertEqual(
            draft.capturePresentations[1].reservedAuditIDs,
            [auditID(300), auditID(301)]
        )
        XCTAssertTrue(draft.capturePresentations[1].isAlreadyReadyToConfirm)
        XCTAssertEqual(
            draft.capturePresentations[1].allowedDecisions,
            [.keepAsIs, .reject]
        )
        XCTAssertEqual(
            draft.capturePresentations[2].reservedAuditIDs,
            [auditID(302), auditID(303)]
        )
        XCTAssertTrue(draft.capturePresentations.allSatisfy {
            $0.reservedAuditIDs.count <= 2
        })
        XCTAssertEqual(
            draft.decisionCounts,
            SessionWrapUpDecisionCounts(
                totalCaptures: 3,
                unresolvedCaptures: 2,
                keepAsIs: 2,
                markNeedsDetails: 0,
                markReadyToConfirm: 0,
                reject: 0,
                alreadyReadyToConfirm: 1,
                alreadyRejected: 1
            )
        )
        XCTAssertFalse(draft.noNewActionsConfirmed)
    }

    func testDraftRejectsAStartBeforeTheLatestCaptureModification() throws {
        let active = try makeActiveSession()
        let session = try active.transitioned(to: .needsReview, at: time(40))
        let inbox = try makeCapture(
            idSeed: 350,
            kind: .learningGap,
            session: session,
            capturedAt: time(20)
        )
        let futureCapture = try inbox.transitioned(
            to: .needsDetails,
            at: time(50),
            auditID: auditID(351)
        )

        XCTAssertThrowsError(try SessionWrapUpDraft(
            session: session,
            captures: [futureCapture],
            startedAt: time(49)
        )) {
            XCTAssertEqual($0 as? SessionWrapUpDraftError, .invalidStartedAt)
        }

        XCTAssertNoThrow(try SessionWrapUpDraft(
            session: session,
            captures: [futureCapture],
            startedAt: time(50)
        ))
    }

    func testFinishFreezesTheExactCompleteTransactionForRetry() throws {
        let activeSession = try makeActiveSession()
        let session = try activeSession.transitioned(to: .needsReview, at: time(40))
        let assignment = try makeCapture(
            idSeed: 400,
            kind: .assignmentCandidate,
            session: session,
            capturedAt: time(20)
        )
        let gapInbox = try makeCapture(
            idSeed: 410,
            kind: .learningGap,
            session: session,
            capturedAt: time(21)
        )
        let gap = try gapInbox.transitioned(
            to: .needsDetails,
            at: time(22),
            auditID: auditID(411)
        )
        let examInbox = try makeCapture(
            idSeed: 420,
            kind: .examCandidate,
            session: session,
            capturedAt: time(23),
            title: "Quiz chapters"
        )
        let examNeedsDetails = try examInbox.transitioned(
            to: .needsDetails,
            at: time(24),
            auditID: auditID(421)
        )
        let examReady = try examNeedsDetails.transitioned(
            to: .readyToConfirm,
            at: time(25),
            auditID: auditID(422)
        )
        let rejectedInbox = try makeCapture(
            idSeed: 430,
            kind: .researchIdea,
            session: session,
            capturedAt: time(26)
        )
        let alreadyRejected = try rejectedInbox.rejecting(
            reason: "Duplicate thought",
            at: time(27),
            auditID: auditID(431)
        )
        var generated = (500 ... 505).map(auditID).makeIterator()
        var draft = try SessionWrapUpDraft(
            session: session,
            captures: [alreadyRejected, examReady, gap, assignment],
            startedAt: time(40),
            wrapUpID: wrapUpID(2),
            auditIDFactory: { generated.next()! }
        )

        try draft.setOneLineSummary("  We reviewed the proof and next actions.  ")
        try draft.setFields(
            SessionWrapUpEditableCaptureFields(
                title: "  Homework 3  ",
                details: "Submit the proof.",
                scope: "Sections 4-5",
                date: try AcademicLocalDate(year: 2026, month: 7, day: 20),
                dateCertainty: .confirmed
            ),
            for: assignment.id
        )
        try draft.setDecision(.markReadyToConfirm, for: assignment.id)
        var gapFields = try XCTUnwrap(
            draft.capturePresentations.first { $0.id == gap.id }
        ).fields
        gapFields.details = "Revisit the final derivation."
        try draft.setFields(gapFields, for: gap.id)
        try draft.setDecision(.markNeedsDetails, for: gap.id)

        XCTAssertEqual(draft.decisionCounts.markReadyToConfirm, 1)
        XCTAssertEqual(draft.decisionCounts.markNeedsDetails, 1)
        XCTAssertEqual(draft.decisionCounts.keepAsIs, 1)
        XCTAssertEqual(draft.decisionCounts.alreadyRejected, 1)

        let first = try draft.finish(completedAt: time(50))
        let retry = try draft.finish(completedAt: time(500))

        XCTAssertEqual(first, retry)
        XCTAssertEqual(first.wrapUpID, wrapUpID(2))
        XCTAssertEqual(first.startedAt, time(40))
        XCTAssertEqual(first.completedAt, time(50))
        XCTAssertEqual(first.oneLineSummary, "We reviewed the proof and next actions.")
        XCTAssertFalse(first.noNewActionsConfirmed)
        XCTAssertEqual(
            first.decisions.map(\.captureID),
            [assignment.id, gap.id, examReady.id].sorted()
        )
        XCTAssertEqual(
            first.decisions.first { $0.captureID == assignment.id }?.auditIDs.count,
            2
        )
        XCTAssertEqual(
            first.decisions.first { $0.captureID == assignment.id }?.draftFields?.title,
            "Homework 3"
        )
        XCTAssertEqual(
            first.decisions.first { $0.captureID == gap.id }?.auditIDs.count,
            1
        )
        XCTAssertEqual(
            first.decisions.first { $0.captureID == examReady.id }?.kind,
            .keepAsIs
        )
        XCTAssertEqual(
            first.decisions.first { $0.captureID == examReady.id }?.auditIDs,
            []
        )
        XCTAssertTrue(draft.isFrozen)
        XCTAssertEqual(draft.frozenTransaction, first)
        XCTAssertThrowsError(try draft.setOneLineSummary("Changed after finish")) {
            XCTAssertEqual($0 as? SessionWrapUpDraftError, .frozen)
        }

        let result = try first.applying(
            to: session,
            captures: [alreadyRejected, examReady, gap, assignment]
        )
        XCTAssertEqual(result.session.status, .reviewed)
        XCTAssertEqual(
            result.captures.first { $0.id == assignment.id }?.state,
            .readyToConfirm
        )
        XCTAssertEqual(
            result.captures.first { $0.id == alreadyRejected.id }?.resolution?.kind,
            .rejected
        )
    }

    func testCandidateMustHaveTitleAndDateCertaintyBeforeReadyToConfirm() throws {
        let session = try makeActiveSession()
        let candidate = try makeCapture(
            idSeed: 600,
            kind: .assignmentCandidate,
            session: session,
            capturedAt: time(20)
        )
        var draft = try SessionWrapUpDraft(
            session: session,
            captures: [candidate],
            startedAt: time(30),
            wrapUpID: wrapUpID(3)
        )
        try draft.setOneLineSummary("Review the assignment candidate.")
        try draft.setDecision(.markReadyToConfirm, for: candidate.id)
        try draft.setFields(
            SessionWrapUpEditableCaptureFields(title: "   ", dateCertainty: nil),
            for: candidate.id
        )

        XCTAssertThrowsError(try draft.finish(completedAt: time(40))) {
            XCTAssertEqual(
                $0 as? SessionWrapUpDraftError,
                .candidateTitleRequired(candidate.id)
            )
        }
        XCTAssertFalse(draft.isFrozen)

        try draft.setFields(
            SessionWrapUpEditableCaptureFields(
                title: "Problem set",
                dateCertainty: nil
            ),
            for: candidate.id
        )
        XCTAssertThrowsError(try draft.finish(completedAt: time(40))) {
            XCTAssertEqual(
                $0 as? SessionWrapUpDraftError,
                .candidateDateCertaintyRequired(candidate.id)
            )
        }
        XCTAssertFalse(draft.isFrozen)

        try draft.setFields(
            SessionWrapUpEditableCaptureFields(
                title: "Problem set",
                dateCertainty: .estimated
            ),
            for: candidate.id
        )
        XCTAssertThrowsError(try draft.finish(completedAt: time(40))) {
            XCTAssertEqual(
                $0 as? SessionWrapUpDraftError,
                .invalidCaptureFields(candidate.id)
            )
        }

        try draft.setFields(
            SessionWrapUpEditableCaptureFields(
                title: "Problem set",
                date: try AcademicLocalDate(year: 2026, month: 7, day: 24),
                dateCertainty: .estimated
            ),
            for: candidate.id
        )
        let transaction = try draft.finish(completedAt: time(40))
        XCTAssertEqual(transaction.decisions.count, 1)
        XCTAssertEqual(transaction.decisions[0].kind, .markReadyToConfirm)
        XCTAssertEqual(transaction.decisions[0].auditIDs.count, 2)
    }

    func testZeroCaptureWrapUpConfirmsNoNewActions() throws {
        let session = try makeActiveSession()
        var draft = try SessionWrapUpDraft(
            session: session,
            captures: [],
            startedAt: time(30),
            wrapUpID: wrapUpID(4)
        )
        try draft.setOneLineSummary("No new action was captured.")

        XCTAssertTrue(draft.noNewActionsConfirmed)
        let transaction = try draft.finish(completedAt: time(31))
        XCTAssertTrue(transaction.noNewActionsConfirmed)
        XCTAssertTrue(transaction.decisions.isEmpty)
        XCTAssertEqual(transaction.wrapUpID, wrapUpID(4))
        XCTAssertEqual(
            try transaction.applying(to: session, captures: []).session.status,
            .reviewed
        )
    }

    func testReadyCaptureCanBeKeptOrRejectedButCannotMoveBackward() throws {
        let session = try makeActiveSession()
        let inbox = try makeCapture(
            idSeed: 700,
            kind: .examCandidate,
            session: session,
            capturedAt: time(20),
            title: "Final topics"
        )
        let needs = try inbox.transitioned(
            to: .needsDetails,
            at: time(21),
            auditID: auditID(701)
        )
        let ready = try needs.transitioned(
            to: .readyToConfirm,
            at: time(22),
            auditID: auditID(702)
        )
        let rejectedInbox = try makeCapture(
            idSeed: 710,
            kind: .evidenceCandidate,
            session: session,
            capturedAt: time(23)
        )
        let rejected = try rejectedInbox.rejecting(
            reason: "Not relevant",
            at: time(24),
            auditID: auditID(711)
        )
        var draft = try SessionWrapUpDraft(
            session: session,
            captures: [ready, rejected],
            startedAt: time(30),
            wrapUpID: wrapUpID(5)
        )

        XCTAssertEqual(draft.finishValidationError, .summaryRequired)

        XCTAssertThrowsError(try draft.setDecision(.markNeedsDetails, for: ready.id)) {
            XCTAssertEqual(
                $0 as? SessionWrapUpDraftError,
                .decisionNotAllowed(
                    captureID: ready.id,
                    state: .readyToConfirm,
                    decision: .markNeedsDetails
                )
            )
        }
        XCTAssertThrowsError(
            try draft.setFields(SessionWrapUpEditableCaptureFields(), for: rejected.id)
        ) {
            XCTAssertEqual(
                $0 as? SessionWrapUpDraftError,
                .captureAlreadyResolved(rejected.id)
            )
        }

        try draft.setDecision(.reject, for: ready.id)
        try draft.setOneLineSummary("Resolved the remaining candidate.")
        XCTAssertThrowsError(try draft.finish(completedAt: time(40))) {
            XCTAssertEqual(
                $0 as? SessionWrapUpDraftError,
                .rejectionReasonRequired(ready.id)
            )
        }
        XCTAssertFalse(draft.isFrozen)
        try draft.setRejectionReason("Already tracked elsewhere", for: ready.id)
        let transaction = try draft.finish(completedAt: time(40))

        XCTAssertEqual(transaction.decisions.count, 1)
        XCTAssertEqual(transaction.decisions[0].captureID, ready.id)
        XCTAssertEqual(transaction.decisions[0].kind, .reject)
        XCTAssertEqual(transaction.decisions[0].rejectionReason, "Already tracked elsewhere")
        XCTAssertFalse(transaction.noNewActionsConfirmed)
        XCTAssertEqual(draft.decisionCounts.alreadyRejected, 1)
    }

    func testDraftRejectsIdentityCollisionsBeforeEditing() throws {
        let session = try makeActiveSession()
        let capture = try makeCapture(
            idSeed: 800,
            kind: .professorEmphasis,
            session: session,
            capturedAt: time(20)
        )

        XCTAssertThrowsError(try SessionWrapUpDraft(
            session: session,
            captures: [capture, capture],
            startedAt: time(30)
        )) {
            XCTAssertEqual(
                $0 as? SessionWrapUpDraftError,
                .duplicateCapture(capture.id)
            )
        }
        XCTAssertThrowsError(try SessionWrapUpDraft(
            session: session,
            captures: [capture],
            startedAt: time(30),
            auditIDFactory: { capture.auditTrail[0].id }
        )) {
            XCTAssertEqual(
                $0 as? SessionWrapUpDraftError,
                .duplicateAuditID(capture.auditTrail[0].id)
            )
        }
    }

    private func makeActiveSession() throws -> CourseSession {
        try CourseSession(
            id: sessionID(10),
            courseID: courseID(11),
            actualStartedAt: time(10),
            status: .active,
            createdAt: time(1),
            modifiedAt: time(10)
        )
    }

    private func makeCapture(
        idSeed: Int,
        kind: CaptureKind,
        session: CourseSession,
        capturedAt: Date,
        title: String? = nil
    ) throws -> CaptureItem {
        try CaptureItem.create(
            id: captureID(idSeed),
            kind: kind,
            source: .quickCapture(try QuickCaptureReference()),
            courseID: session.courseID,
            sessionID: session.id,
            rawText: "Source \(idSeed)",
            draftFields: try CaptureDraftFields(title: title),
            capturedAt: capturedAt,
            auditID: auditID(idSeed)
        )
    }

    private func time(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value)
    }

    private func courseID(_ value: Int) -> CourseID {
        CourseID(testUUID(value))
    }

    private func sessionID(_ value: Int) -> CourseSessionID {
        CourseSessionID(testUUID(value))
    }

    private func captureID(_ value: Int) -> CaptureItemID {
        CaptureItemID(testUUID(value))
    }

    private func auditID(_ value: Int) -> CaptureAuditEntryID {
        CaptureAuditEntryID(testUUID(value + 100_000))
    }

    private func wrapUpID(_ value: Int) -> SessionWrapUpID {
        SessionWrapUpID(testUUID(value + 200_000))
    }

    private func testUUID(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
