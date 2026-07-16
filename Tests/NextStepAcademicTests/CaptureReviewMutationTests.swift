import Foundation
@testable import NextStepAcademic
import XCTest

final class CaptureReviewMutationTests: XCTestCase {
    func testInboxCandidateCanMoveToNeedsDetailsWithOneStableAudit() throws {
        let capture = try reviewCandidate(seed: 7_101)
        let fields = try candidateFields(
            title: "Problem set 3",
            details: "Confirm which exercises are assigned."
        )
        let auditID = CaptureAuditEntryID(testUUID(2_101))
        let mutation = try CaptureReviewMutation(
            base: capture,
            intent: .markNeedsDetails(
                fields: fields,
                occurredAt: reviewTimestamp,
                auditID: auditID
            )
        )
        let baseline = try reviewContent(captures: [capture])

        let updated = try applyReview(mutation, to: baseline)
        let saved = try XCTUnwrap(updated.captures.first)

        XCTAssertEqual(saved.state, .needsDetails)
        XCTAssertEqual(saved.revision, 2)
        XCTAssertEqual(saved.draftFields, fields)
        XCTAssertEqual(saved.modifiedAt, reviewTimestamp)
        XCTAssertEqual(saved.auditTrail.last?.id, auditID)
        XCTAssertEqual(saved.auditTrail.last?.action, .stateChanged)
        XCTAssertEqual(baseline.captures, [capture])
    }

    func testInboxCandidateCanMoveToReadyThroughTwoStableAudits() throws {
        let capture = try reviewCandidate(seed: 7_102, kind: .examCandidate)
        let fields = try candidateFields(
            title: "Midterm",
            details: "Covers chapters 1 through 4."
        )
        let auditIDs = [
            CaptureAuditEntryID(testUUID(2_102)),
            CaptureAuditEntryID(testUUID(2_103)),
        ]
        let mutation = try CaptureReviewMutation(
            base: capture,
            intent: .markReadyToConfirm(
                fields: fields,
                occurredAt: reviewTimestamp,
                auditIDs: auditIDs
            )
        )

        let firstPostImage = try mutation.applying(to: capture)
        let secondPostImage = try mutation.applying(to: capture)

        XCTAssertEqual(firstPostImage, secondPostImage)
        XCTAssertEqual(firstPostImage.state, .readyToConfirm)
        XCTAssertEqual(firstPostImage.revision, 3)
        XCTAssertEqual(firstPostImage.draftFields, fields)
        XCTAssertEqual(
            firstPostImage.auditTrail.suffix(2).map(\.id),
            auditIDs
        )
        XCTAssertEqual(
            firstPostImage.auditTrail.suffix(2).map(\.occurredAt),
            [reviewTimestamp, reviewTimestamp]
        )
        XCTAssertNil(firstPostImage.resolution)
        XCTAssertEqual(capture.state, .inbox)
        XCTAssertEqual(capture.revision, 1)
    }

    func testNeedsDetailsCandidateCanMoveToReadyWithOneAudit() throws {
        let inbox = try reviewCandidate(seed: 7_104)
        let needsFields = try candidateFields(
            title: "Lab report",
            details: "Add the submission date."
        )
        let needs = try inbox.transitioned(
            to: .needsDetails,
            draftFields: needsFields,
            at: reviewTimestamp,
            auditID: CaptureAuditEntryID(testUUID(2_104))
        )
        let readyFields = try candidateFields(
            title: "Lab report",
            details: "Submit the report on Friday."
        )
        let readyAt = reviewTimestamp.addingTimeInterval(60)
        let readyAuditID = CaptureAuditEntryID(testUUID(2_105))
        let mutation = try CaptureReviewMutation(
            base: needs,
            intent: .markReadyToConfirm(
                fields: readyFields,
                occurredAt: readyAt,
                auditIDs: [readyAuditID]
            )
        )

        let saved = try mutation.applying(to: needs)

        XCTAssertEqual(saved.state, .readyToConfirm)
        XCTAssertEqual(saved.revision, 3)
        XCTAssertEqual(saved.draftFields, readyFields)
        XCTAssertEqual(saved.auditTrail.last?.id, readyAuditID)
        XCTAssertEqual(saved.auditTrail.last?.fromState, .needsDetails)
        XCTAssertEqual(saved.auditTrail.last?.toState, .readyToConfirm)
    }

    func testReadyCandidateDraftCanBeEditedWithoutMovingStateBackward() throws {
        let ready = try makeReadyCandidate(seed: 7_106)
        let editedFields = try candidateFields(
            title: "Final presentation",
            details: "Ten minutes plus questions."
        )
        let editedAt = reviewTimestamp.addingTimeInterval(120)
        let auditID = CaptureAuditEntryID(testUUID(2_108))
        let mutation = try CaptureReviewMutation(
            base: ready,
            intent: .saveDraft(
                fields: editedFields,
                occurredAt: editedAt,
                auditID: auditID
            )
        )

        let saved = try mutation.applying(to: ready)

        XCTAssertEqual(saved.state, .readyToConfirm)
        XCTAssertEqual(saved.revision, ready.revision + 1)
        XCTAssertEqual(saved.draftFields, editedFields)
        XCTAssertEqual(saved.auditTrail.last?.action, .draftUpdated)
        XCTAssertEqual(saved.auditTrail.last?.id, auditID)
        XCTAssertNil(saved.resolution)
    }

    func testCandidateCanBeRejectedWithoutCreatingCanonicalAssignmentOrExam() throws {
        let capture = try reviewCandidate(seed: 7_109, kind: .examCandidate)
        let reason = "The professor clarified that this is optional."
        let auditID = CaptureAuditEntryID(testUUID(2_109))
        let mutation = try CaptureReviewMutation(
            base: capture,
            intent: .reject(
                reason: reason,
                occurredAt: reviewTimestamp,
                auditID: auditID
            )
        )

        let saved = try mutation.applying(to: capture)

        XCTAssertEqual(saved.state, .resolved)
        XCTAssertEqual(saved.resolution?.kind, .rejected)
        XCTAssertEqual(saved.resolution?.reason, reason)
        XCTAssertTrue(saved.resolution?.resolvedEntityRefs.isEmpty == true)
        XCTAssertEqual(saved.auditTrail.last?.action, .rejected)
        XCTAssertEqual(saved.auditTrail.last?.id, auditID)
    }

    func testCommandRejectsStaleRevisionAndLeavesWorkspaceInputUnchanged() throws {
        let base = try reviewCandidate(seed: 7_110)
        let mutation = try CaptureReviewMutation(
            base: base,
            intent: .saveDraft(
                fields: try candidateFields(title: "Stale edit"),
                occurredAt: reviewTimestamp,
                auditID: CaptureAuditEntryID(testUUID(2_110))
            )
        )
        let current = try base.updatingDraft(
            try candidateFields(title: "Concurrent edit"),
            at: reviewTimestamp.addingTimeInterval(-1),
            auditID: CaptureAuditEntryID(testUUID(3_110))
        )
        let baseline = try reviewContent(captures: [current])
        let workspace = try reviewWorkspace(baseline)

        XCTAssertThrowsError(
            try AcademicWorkspaceCommand.applyCaptureReview(mutation)
                .applying(to: workspace)
        ) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .revisionConflict(
                    expected: base.revision,
                    actual: current.revision
                )
            )
        }
        XCTAssertEqual(workspace.content, baseline)
    }

    func testCommandRejectsMissingCaptureAndLeavesWorkspaceInputUnchanged() throws {
        let missingBase = try reviewCandidate(seed: 7_111)
        let baseline = try reviewContent(captures: [])
        let workspace = try reviewWorkspace(baseline)
        let mutation = try CaptureReviewMutation(
            base: missingBase,
            intent: .reject(
                reason: "Not an actionable item.",
                occurredAt: reviewTimestamp,
                auditID: CaptureAuditEntryID(testUUID(2_111))
            )
        )

        XCTAssertThrowsError(
            try AcademicWorkspaceCommand.applyCaptureReview(mutation)
                .applying(to: workspace)
        ) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .missingEntity(
                    entity: "capture item",
                    identifier: missingBase.id.description
                )
            )
        }
        XCTAssertEqual(workspace.content, baseline)
    }

    func testReviewRejectsNonCandidateCapture() throws {
        let capture = try makeQuickCapture(
            idSeed: 7_112,
            kind: .professorEmphasis,
            courseID: testCourseID,
            sessionID: nil
        )
        XCTAssertThrowsError(try CaptureReviewMutation(
            base: capture,
            intent: .saveDraft(
                fields: try CaptureDraftFields(title: "Not a candidate"),
                occurredAt: reviewTimestamp,
                auditID: CaptureAuditEntryID(testUUID(2_112))
            )
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .unsupportedV1Operation("captureReview.nonCandidate")
            )
        }
        XCTAssertEqual(capture.revision, 1)
        XCTAssertEqual(capture.state, .inbox)
    }

    func testReadyCandidateCannotMoveBackwardToNeedsDetails() throws {
        let ready = try makeReadyCandidate(seed: 7_113)
        XCTAssertThrowsError(try CaptureReviewMutation(
            base: ready,
            intent: .markNeedsDetails(
                fields: nil,
                occurredAt: reviewTimestamp.addingTimeInterval(120),
                auditID: CaptureAuditEntryID(testUUID(2_115))
            )
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .invalidStateTransition(
                    entity: "capture item",
                    from: CaptureState.readyToConfirm.rawValue,
                    to: CaptureState.needsDetails.rawValue
                )
            )
        }
        XCTAssertEqual(ready.state, .readyToConfirm)
    }

    func testRejectedCandidateCannotBeEditedAgain() throws {
        let inbox = try reviewCandidate(seed: 7_114)
        let rejected = try inbox.rejecting(
            reason: "This was not assigned.",
            at: reviewTimestamp,
            auditID: CaptureAuditEntryID(testUUID(2_114))
        )
        XCTAssertThrowsError(try CaptureReviewMutation(
            base: rejected,
            intent: .saveDraft(
                fields: try candidateFields(title: "Must remain rejected"),
                occurredAt: reviewTimestamp.addingTimeInterval(60),
                auditID: CaptureAuditEntryID(testUUID(2_118))
            )
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .invalidStateTransition(
                    entity: "capture item",
                    from: CaptureState.resolved.rawValue,
                    to: CaptureState.resolved.rawValue
                )
            )
        }
        XCTAssertEqual(rejected.state, .resolved)
        XCTAssertEqual(rejected.revision, 2)
    }

    func testReviewRejectsBackwardTimeAndInvalidIntentInputs() throws {
        let capture = try reviewCandidate(seed: 7_116)
        XCTAssertThrowsError(try CaptureReviewMutation(
            base: capture,
            intent: .saveDraft(
                fields: try candidateFields(title: "Backdated edit"),
                occurredAt: capture.modifiedAt.addingTimeInterval(-1),
                auditID: CaptureAuditEntryID(testUUID(2_116))
            )
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .chronologyViolation(
                    "A CaptureItem update cannot move time backwards."
                )
            )
        }

        XCTAssertThrowsError(try CaptureReviewMutation(
            base: capture,
            intent: .markReadyToConfirm(
                fields: try candidateFields(title: "Invalid audits"),
                occurredAt: reviewTimestamp,
                auditIDs: []
            )
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .invalidField("captureReviewMutation.markReadyToConfirm.auditIDs")
            )
        }

        XCTAssertThrowsError(try CaptureReviewMutation(
            base: capture,
            intent: .reject(
                reason: "   ",
                occurredAt: reviewTimestamp,
                auditID: CaptureAuditEntryID(testUUID(2_117))
            )
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .invalidField("captureReviewMutation.rejectionReason")
            )
        }
    }

    func testCommandRejectsAuditIdentifierUsedByAnotherCaptureGlobally() throws {
        let target = try reviewCandidate(seed: 7_118)
        let other = try reviewCandidate(seed: 7_119, kind: .examCandidate)
        let duplicateAuditID = try XCTUnwrap(other.auditTrail.first?.id)
        let baseline = try reviewContent(captures: [other, target])
        let workspace = try reviewWorkspace(baseline)
        let mutation = try CaptureReviewMutation(
            base: target,
            intent: .saveDraft(
                fields: try candidateFields(title: "Globally duplicated audit"),
                occurredAt: reviewTimestamp,
                auditID: duplicateAuditID
            )
        )

        XCTAssertThrowsError(
            try AcademicWorkspaceCommand.applyCaptureReview(mutation)
                .applying(to: workspace)
        ) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .duplicateIdentifier(
                    entity: "capture audit entry",
                    identifier: duplicateAuditID.description
                )
            )
        }
        XCTAssertEqual(workspace.content, baseline)
        XCTAssertEqual(workspace.captures, baseline.captures)
    }

    func testMutationRequiresExactCaptureIdentifierPreimage() throws {
        let expected = try reviewCandidate(seed: 7_120)
        let other = try reviewCandidate(seed: 7_121)
        let mutation = try CaptureReviewMutation(
            base: expected,
            intent: .saveDraft(
                fields: try candidateFields(title: "Exact pre-image only"),
                occurredAt: reviewTimestamp,
                auditID: CaptureAuditEntryID(testUUID(2_120))
            )
        )

        XCTAssertThrowsError(try mutation.applying(to: other)) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .relationshipMismatch(
                    "A capture review mutation must be applied to its exact CaptureItem."
                )
            )
        }
        XCTAssertEqual(other.revision, 1)
    }

    func testCommandRejectsDifferentLegalContentAtTheSameRevision() throws {
        let expected = try reviewCandidate(seed: 7_122)
        let divergent = try CaptureItem(
            schemaVersion: expected.schemaVersion,
            id: expected.id,
            revision: expected.revision,
            kind: expected.kind,
            source: expected.source,
            courseID: expected.courseID,
            sessionID: expected.sessionID,
            rawText: expected.rawText,
            draftFields: try candidateFields(title: "Reloaded divergent draft"),
            capturedAt: expected.capturedAt,
            modifiedAt: expected.modifiedAt,
            state: expected.state,
            resolution: expected.resolution,
            auditTrail: expected.auditTrail
        )
        let mutation = try CaptureReviewMutation(
            base: expected,
            intent: .saveDraft(
                fields: try candidateFields(title: "Must not overwrite reload"),
                occurredAt: reviewTimestamp,
                auditID: CaptureAuditEntryID(testUUID(2_122))
            )
        )
        let baseline = try reviewContent(captures: [divergent])
        let workspace = try reviewWorkspace(baseline)

        XCTAssertEqual(divergent.id, expected.id)
        XCTAssertEqual(divergent.revision, expected.revision)
        XCTAssertNotEqual(divergent, expected)
        XCTAssertThrowsError(
            try AcademicWorkspaceCommand.applyCaptureReview(mutation)
                .applying(to: workspace)
        ) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .relationshipMismatch(
                    "A capture review mutation requires its exact expected CaptureItem pre-image."
                )
            )
        }
        XCTAssertEqual(workspace.content, baseline)
        XCTAssertEqual(workspace.captures, [divergent])
    }

    func testMutationStoresDeterministicPostImageForPreflightAndRetry() throws {
        let base = try reviewCandidate(seed: 7_123, kind: .examCandidate)
        let mutation = try CaptureReviewMutation(
            base: base,
            intent: .markReadyToConfirm(
                fields: try candidateFields(title: "Stored post-image"),
                occurredAt: reviewTimestamp,
                auditIDs: [
                    CaptureAuditEntryID(testUUID(2_123)),
                    CaptureAuditEntryID(testUUID(2_124)),
                ]
            )
        )
        let workspace = try reviewWorkspace(
            reviewContent(captures: [base])
        )
        let command = AcademicWorkspaceCommand.applyCaptureReview(mutation)

        XCTAssertEqual(mutation.expectedCapture, base)
        XCTAssertEqual(mutation.captureID, base.id)
        XCTAssertEqual(mutation.expectedRevision, base.revision)
        XCTAssertEqual(
            try mutation.applying(to: base),
            mutation.resultingCapture
        )
        XCTAssertEqual(
            try mutation.applying(to: base),
            mutation.resultingCapture
        )
        XCTAssertEqual(
            try command.applying(to: workspace),
            try command.applying(to: workspace)
        )
        XCTAssertEqual(
            try command.applying(to: workspace).captures,
            [mutation.resultingCapture]
        )
    }
}

private let reviewTimestamp = testStartedAt.addingTimeInterval(120)

private func candidateFields(
    title: String,
    details: String? = nil
) throws -> CaptureDraftFields {
    try CaptureDraftFields(
        title: title,
        details: details,
        dateCertainty: .unknown
    )
}

private func reviewCandidate(
    seed: Int,
    kind: CaptureKind = .assignmentCandidate
) throws -> CaptureItem {
    try makeQuickCapture(
        idSeed: seed,
        kind: kind,
        courseID: testCourseID,
        sessionID: nil
    )
}

private func makeReadyCandidate(seed: Int) throws -> CaptureItem {
    let inbox = try reviewCandidate(seed: seed)
    let mutation = try CaptureReviewMutation(
        base: inbox,
        intent: .markReadyToConfirm(
            fields: try candidateFields(title: "Candidate \(seed)"),
            occurredAt: reviewTimestamp,
            auditIDs: [
                CaptureAuditEntryID(testUUID(seed + 2_000)),
                CaptureAuditEntryID(testUUID(seed + 2_001)),
            ]
        )
    )
    return mutation.resultingCapture
}

private func reviewContent(
    captures: [CaptureItem]
) throws -> AcademicWorkspaceContent {
    let course = try Course(
        id: testCourseID,
        name: "Candidate Review",
        timeZoneIdentifier: "Asia/Taipei",
        createdAt: testCreatedAt
    )
    return try AcademicWorkspaceContent(
        courses: [course],
        captures: captures
    )
}

private func reviewWorkspace(
    _ content: AcademicWorkspaceContent
) throws -> AcademicWorkspace {
    try AcademicWorkspace(
        revision: 0,
        savedAt: testCompletedAt,
        content: content
    )
}

private func applyReview(
    _ mutation: CaptureReviewMutation,
    to content: AcademicWorkspaceContent
) throws -> AcademicWorkspaceContent {
    try AcademicWorkspaceCommand.applyCaptureReview(mutation)
        .applying(to: reviewWorkspace(content))
}
