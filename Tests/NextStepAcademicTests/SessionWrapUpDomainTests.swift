import Foundation
@testable import NextStepAcademic
import XCTest

final class SessionWrapUpDomainTests: XCTestCase {
    func testTransactionAtomicallyReviewsSessionAndCaptureCandidates() throws {
        let session = try makeActiveSession()
        let candidate = try makeQuickCapture(
            idSeed: 300,
            kind: .assignmentCandidate,
            title: "繳交資料結構作業 📚"
        )
        let emphasis = try makeQuickCapture(
            idSeed: 310,
            kind: .professorEmphasis
        )
        let readyDecision = try SessionWrapUpDecision(
            captureID: candidate.id,
            expectedRevision: candidate.revision,
            kind: .markReadyToConfirm,
            draftFields: try CaptureDraftFields(
                title: "繳交資料結構作業 📚",
                scope: "第 4 章",
                date: AcademicLocalDate(year: 2027, month: 1, day: 8),
                dateCertainty: .confirmed
            ),
            auditIDs: [
                CaptureAuditEntryID(testUUID(302)),
                CaptureAuditEntryID(testUUID(303)),
            ]
        )
        let rejectDecision = try SessionWrapUpDecision(
            captureID: emphasis.id,
            expectedRevision: emphasis.revision,
            kind: .reject,
            rejectionReason: "這是重點，不是課後行動。",
            auditIDs: [CaptureAuditEntryID(testUUID(312))]
        )
        let transaction = try SessionWrapUpTransaction(
            sessionID: session.id,
            expectedSessionRevision: session.revision,
            wrapUpID: SessionWrapUpID(testUUID(320)),
            startedAt: testStartedAt.addingTimeInterval(60),
            completedAt: testCompletedAt,
            oneLineSummary: "完成堆疊與佇列，並確認一項作業候選。 ✅",
            noNewActionsConfirmed: false,
            decisions: [rejectDecision, readyDecision]
        )
        XCTAssertEqual(
            transaction.decisions.map(\.captureID),
            [candidate.id, emphasis.id].sorted()
        )

        let first = try transaction.applying(to: session, captures: [emphasis, candidate])
        let second = try transaction.applying(to: session, captures: [candidate, emphasis])
        XCTAssertEqual(first, second, "Pure domain application must be deterministic.")
        XCTAssertEqual(first.session.status, .reviewed)
        XCTAssertEqual(first.session.revision, session.revision + 1)
        XCTAssertEqual(first.wrapUp.reviewedCaptureIDs, [candidate.id, emphasis.id].sorted())
        XCTAssertEqual(first.captures.map(\.id), [candidate.id, emphasis.id].sorted())

        let updatedCandidate = try XCTUnwrap(
            first.captures.first(where: { $0.id == candidate.id })
        )
        XCTAssertEqual(updatedCandidate.state, .readyToConfirm)
        XCTAssertEqual(updatedCandidate.revision, 3)
        XCTAssertNil(updatedCandidate.resolution)
        let updatedEmphasis = try XCTUnwrap(
            first.captures.first(where: { $0.id == emphasis.id })
        )
        XCTAssertEqual(updatedEmphasis.resolution?.kind, .rejected)

        try assertCodableRoundTrip(transaction)
        try assertCodableRoundTrip(first.wrapUp)
    }

    func testKeepAsIsAndNeedsDetailsDecisionsPreserveExpectedStateSemantics() throws {
        let session = try makeActiveSession()
        let kept = try makeQuickCapture(
            idSeed: 321,
            kind: .researchIdea
        )
        let needsContext = try makeQuickCapture(
            idSeed: 324,
            kind: .learningGap
        )
        let keepDecision = try SessionWrapUpDecision(
            captureID: kept.id,
            expectedRevision: kept.revision,
            kind: .keepAsIs
        )
        let needsDecision = try SessionWrapUpDecision(
            captureID: needsContext.id,
            expectedRevision: needsContext.revision,
            kind: .markNeedsDetails,
            draftFields: try CaptureDraftFields(details: "需要補上第 5 章的先備知識。"),
            auditIDs: [CaptureAuditEntryID(testUUID(326))]
        )
        let transaction = try SessionWrapUpTransaction(
            sessionID: session.id,
            expectedSessionRevision: session.revision,
            wrapUpID: SessionWrapUpID(testUUID(327)),
            startedAt: testStartedAt,
            completedAt: testCompletedAt,
            oneLineSummary: "保留研究靈感，學習缺口等待補充。",
            noNewActionsConfirmed: false,
            decisions: [needsDecision, keepDecision]
        )
        let result = try transaction.applying(
            to: session,
            captures: [needsContext, kept]
        )
        let keptResult = try XCTUnwrap(result.captures.first { $0.id == kept.id })
        XCTAssertEqual(keptResult.state, .inbox)
        XCTAssertEqual(keptResult.revision, kept.revision)
        let needsResult = try XCTUnwrap(
            result.captures.first { $0.id == needsContext.id }
        )
        XCTAssertEqual(needsResult.state, .needsDetails)
        XCTAssertEqual(needsResult.revision, needsContext.revision + 1)
    }

    func testKeepAsIsCompletesWrapUpWithReadyCaptureUnchanged() throws {
        let session = try makeActiveSession()
        let inbox = try makeQuickCapture(
            idSeed: 380,
            kind: .assignmentCandidate,
            title: "已確認的作業候選"
        )
        let needsDetails = try inbox.transitioned(
            to: .needsDetails,
            at: testStartedAt.addingTimeInterval(1),
            auditID: CaptureAuditEntryID(testUUID(381))
        )
        let ready = try needsDetails.transitioned(
            to: .readyToConfirm,
            at: testStartedAt.addingTimeInterval(2),
            auditID: CaptureAuditEntryID(testUUID(382))
        )
        let keepDecision = try SessionWrapUpDecision(
            captureID: ready.id,
            expectedRevision: ready.revision,
            kind: .keepAsIs
        )
        let transaction = try SessionWrapUpTransaction(
            sessionID: session.id,
            expectedSessionRevision: session.revision,
            wrapUpID: SessionWrapUpID(testUUID(383)),
            startedAt: testStartedAt.addingTimeInterval(3),
            completedAt: testCompletedAt,
            oneLineSummary: "保留已可確認的作業候選。",
            noNewActionsConfirmed: false,
            decisions: [keepDecision]
        )

        let result = try transaction.applying(to: session, captures: [ready])
        let kept = try XCTUnwrap(result.captures.first)
        XCTAssertEqual(kept.state, .readyToConfirm)
        XCTAssertEqual(kept.revision, ready.revision)
        XCTAssertEqual(kept, ready)
        XCTAssertEqual(result.wrapUp.reviewedCaptureIDs, [ready.id])
        try assertCodableRoundTrip(keepDecision)
        try assertCodableRoundTrip(transaction)
    }

    func testNoActionConfirmationCanFinishSessionWithoutCaptureDecisions() throws {
        let session = try makeActiveSession()
        let transaction = try SessionWrapUpTransaction(
            sessionID: session.id,
            expectedSessionRevision: session.revision,
            wrapUpID: SessionWrapUpID(testUUID(330)),
            startedAt: testStartedAt,
            completedAt: testCompletedAt,
            oneLineSummary: "本堂沒有新增課後行動。",
            noNewActionsConfirmed: true,
            decisions: []
        )
        let result = try transaction.applying(to: session, captures: [])
        XCTAssertTrue(result.wrapUp.noNewActionsConfirmed)
        XCTAssertTrue(result.wrapUp.reviewedCaptureIDs.isEmpty)
        XCTAssertTrue(result.captures.isEmpty)

        XCTAssertThrowsError(try SessionWrapUpTransaction(
            sessionID: session.id,
            expectedSessionRevision: session.revision,
            wrapUpID: SessionWrapUpID(testUUID(331)),
            startedAt: testStartedAt,
            completedAt: testCompletedAt,
            oneLineSummary: "沒有決策也沒有確認",
            noNewActionsConfirmed: false,
            decisions: []
        ))
    }

    func testTransactionCannotReviewSessionWithUnresolvedCaptureMissingDecision() throws {
        let session = try makeActiveSession()
        let unresolved = try makeQuickCapture(
            idSeed: 332,
            kind: .assignmentCandidate
        )
        let transaction = try SessionWrapUpTransaction(
            sessionID: session.id,
            expectedSessionRevision: session.revision,
            wrapUpID: SessionWrapUpID(testUUID(334)),
            startedAt: testStartedAt,
            completedAt: testCompletedAt,
            oneLineSummary: "不能略過尚未處理的候選項目。",
            noNewActionsConfirmed: true,
            decisions: []
        )

        XCTAssertThrowsError(try transaction.applying(
            to: session,
            captures: [unresolved]
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .relationshipMismatch(
                    "Every unresolved Session CaptureItem must have exactly one wrap-up decision."
                )
            )
        }
    }

    func testTransactionRejectsOversizedCaptureSetBeforeCollectionWork() throws {
        let session = try makeActiveSession()
        let capture = try makeQuickCapture(
            idSeed: 336,
            kind: .professorEmphasis
        )
        let transaction = try SessionWrapUpTransaction(
            sessionID: session.id,
            expectedSessionRevision: session.revision,
            wrapUpID: SessionWrapUpID(testUUID(338)),
            startedAt: testStartedAt,
            completedAt: testCompletedAt,
            oneLineSummary: "拒絕超出上限的輸入。",
            noNewActionsConfirmed: true,
            decisions: []
        )
        let oversized = Array(
            repeating: capture,
            count: AcademicDomainLimits.maximumCapturesPerSession + 1
        )

        XCTAssertThrowsError(try transaction.applying(
            to: session,
            captures: oversized
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .valueOutOfBounds(field: "sessionWrapUpTransaction.captures")
            )
        }
    }

    func testTransactionRejectsRevisionRelationshipAndAuditConflicts() throws {
        let session = try makeActiveSession()
        let capture = try makeQuickCapture(
            idSeed: 340,
            kind: .learningGap
        )
        let conflictingAuditDecision = try SessionWrapUpDecision(
            captureID: capture.id,
            expectedRevision: capture.revision,
            kind: .markNeedsDetails,
            auditIDs: [capture.auditTrail[0].id]
        )
        let conflict = try SessionWrapUpTransaction(
            sessionID: session.id,
            expectedSessionRevision: session.revision,
            wrapUpID: SessionWrapUpID(testUUID(342)),
            startedAt: testStartedAt,
            completedAt: testCompletedAt,
            oneLineSummary: "檢查衝突",
            noNewActionsConfirmed: false,
            decisions: [conflictingAuditDecision]
        )
        XCTAssertThrowsError(try conflict.applying(to: session, captures: [capture]))

        let wrongRevision = try SessionWrapUpTransaction(
            sessionID: session.id,
            expectedSessionRevision: session.revision + 1,
            wrapUpID: SessionWrapUpID(testUUID(343)),
            startedAt: testStartedAt,
            completedAt: testCompletedAt,
            oneLineSummary: "錯誤 revision",
            noNewActionsConfirmed: true,
            decisions: []
        )
        XCTAssertThrowsError(try wrongRevision.applying(to: session, captures: [])) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .revisionConflict(
                    expected: session.revision + 1,
                    actual: session.revision
                )
            )
        }

        let foreignCapture = try makeQuickCapture(
            idSeed: 350,
            kind: .learningGap,
            courseID: CourseID(testUUID(999)),
            sessionID: CourseSessionID(testUUID(998))
        )
        XCTAssertThrowsError(try conflict.applying(to: session, captures: [foreignCapture]))
    }

    func testDecisionValidationRejectsDuplicateCaptureAndInvalidStateSpecificAuditCounts() throws {
        let capture = try makeQuickCapture(
            idSeed: 360,
            kind: .examCandidate,
            title: "期末考"
        )
        let oneAuditReady = try SessionWrapUpDecision(
            captureID: capture.id,
            expectedRevision: capture.revision,
            kind: .markReadyToConfirm,
            auditIDs: [CaptureAuditEntryID(testUUID(362))]
        )
        let session = try makeActiveSession()
        let transaction = try SessionWrapUpTransaction(
            sessionID: session.id,
            expectedSessionRevision: session.revision,
            wrapUpID: SessionWrapUpID(testUUID(363)),
            startedAt: testStartedAt,
            completedAt: testCompletedAt,
            oneLineSummary: "inbox 到 ready 需要兩筆 audit",
            noNewActionsConfirmed: false,
            decisions: [oneAuditReady]
        )
        XCTAssertThrowsError(try transaction.applying(to: session, captures: [capture]))

        XCTAssertThrowsError(try SessionWrapUpTransaction(
            sessionID: session.id,
            expectedSessionRevision: session.revision,
            wrapUpID: SessionWrapUpID(testUUID(364)),
            startedAt: testStartedAt,
            completedAt: testCompletedAt,
            oneLineSummary: "重複 capture decision",
            noNewActionsConfirmed: false,
            decisions: [oneAuditReady, oneAuditReady]
        ))
        XCTAssertThrowsError(try SessionWrapUpDecision(
            captureID: capture.id,
            expectedRevision: capture.revision,
            kind: .reject,
            rejectionReason: nil,
            auditIDs: [CaptureAuditEntryID(testUUID(365))]
        ))
    }

    func testWrapUpModelsFailClosedOnFutureSchemaAndInvalidSummary() throws {
        XCTAssertThrowsError(
            try JSONDecoder().decode(SessionWrapUp.self, from: futureSchemaOnly())
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(SessionWrapUpDecision.self, from: futureSchemaOnly())
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(SessionWrapUpTransaction.self, from: futureSchemaOnly())
        )
        XCTAssertThrowsError(try SessionWrapUp(
            sessionID: testSessionID,
            startedAt: testStartedAt,
            completedAt: testCompletedAt,
            oneLineSummary: "不能有\n換行",
            noNewActionsConfirmed: true,
            reviewedCaptureIDs: []
        ))
        XCTAssertThrowsError(try SessionWrapUp(
            sessionID: testSessionID,
            startedAt: testStartedAt,
            completedAt: testCompletedAt,
            oneLineSummary: "重複 capture",
            noNewActionsConfirmed: false,
            reviewedCaptureIDs: [
                CaptureItemID(testUUID(370)),
                CaptureItemID(testUUID(370)),
            ]
        ))
    }
}
