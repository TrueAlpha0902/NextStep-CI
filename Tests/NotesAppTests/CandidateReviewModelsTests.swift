import Foundation
import NextStepAcademic
@testable import NotesApp
import XCTest

final class CandidateReviewModelsTests: XCTestCase {
    func testOrderingScopesFiltersAndUsesStableChronology() throws {
        let sessionID = CourseSessionID()
        let otherSessionID = CourseSessionID()
        let assignment = try makeCandidate(
            kind: .assignmentCandidate,
            sessionID: sessionID,
            capturedAt: Date(timeIntervalSince1970: 20)
        )
        let exam = try makeCandidate(
            kind: .examCandidate,
            sessionID: sessionID,
            capturedAt: Date(timeIntervalSince1970: 10)
        )
        let other = try makeCandidate(
            kind: .assignmentCandidate,
            sessionID: otherSessionID,
            capturedAt: Date(timeIntervalSince1970: 5)
        )

        XCTAssertEqual(
            CandidateReviewOrdering.captures(
                [assignment, other, exam],
                sessionID: sessionID,
                filter: .all
            ),
            [exam, assignment]
        )
        XCTAssertEqual(
            CandidateReviewOrdering.captures(
                [assignment, exam],
                sessionID: sessionID,
                filter: .assignments
            ),
            [assignment]
        )
        XCTAssertEqual(
            CandidateReviewOrdering.captures(
                [assignment, exam],
                sessionID: sessionID,
                filter: .exams
            ),
            [exam]
        )
    }

    func testDraftTrimsFieldsAndUsesCourseTimeZoneForLocalDate() throws {
        let capture = try makeCandidate(
            kind: .assignmentCandidate,
            sessionID: CourseSessionID(),
            capturedAt: Date(timeIntervalSince1970: 10)
        )
        let instant = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-09-10T16:30:00Z")
        )
        var draft = CandidateEditorDraft(
            capture: capture,
            timeZoneIdentifier: "Asia/Taipei",
            fallbackDate: instant
        )
        draft.title = "  Lab report  "
        draft.details = "  "
        draft.scope = " Week 2 \n"
        draft.dateCertainty = .confirmed

        let fields = try draft.makeFields()

        XCTAssertEqual(fields.title, "Lab report")
        XCTAssertNil(fields.details)
        XCTAssertEqual(fields.scope, "Week 2")
        XCTAssertEqual(
            fields.date,
            try AcademicLocalDate(year: 2026, month: 9, day: 11)
        )
        XCTAssertEqual(fields.dateCertainty, .confirmed)
        XCTAssertTrue(draft.canMarkReady)
    }

    func testUnknownCertaintyClearsDateAndReadyRequiresTitle() throws {
        let capture = try makeCandidate(
            kind: .examCandidate,
            sessionID: CourseSessionID(),
            capturedAt: Date(timeIntervalSince1970: 10)
        )
        var draft = CandidateEditorDraft(
            capture: capture,
            timeZoneIdentifier: "Asia/Taipei"
        )
        draft.dateCertainty = .unknown
        draft.title = "  "
        XCTAssertFalse(draft.canMarkReady)
        XCTAssertNil(try draft.makeFields().date)

        draft.title = "Midterm"
        XCTAssertTrue(draft.canMarkReady)
    }

    func testSectionsKeepReadyLanguageDistinctFromFormalConfirmation() throws {
        let timestamp = Date(timeIntervalSince1970: 10)
        let inbox = try makeCandidate(
            kind: .assignmentCandidate,
            sessionID: CourseSessionID(),
            capturedAt: timestamp
        )
        let needs = try inbox.transitioned(
            to: .needsDetails,
            at: timestamp,
            auditID: CaptureAuditEntryID()
        )
        let readyFields = try CaptureDraftFields(
            title: "Assignment",
            dateCertainty: .unknown
        )
        let ready = try needs.transitioned(
            to: .readyToConfirm,
            draftFields: readyFields,
            at: timestamp,
            auditID: CaptureAuditEntryID()
        )
        let rejected = try inbox.rejecting(
            reason: "Not an assignment",
            at: timestamp,
            auditID: CaptureAuditEntryID()
        )

        XCTAssertTrue(CandidateReviewSection.toReview.includes(inbox))
        XCTAssertTrue(CandidateReviewSection.toReview.includes(needs))
        XCTAssertTrue(
            CandidateReviewSection.readyForLaterConfirmation.includes(ready)
        )
        XCTAssertTrue(CandidateReviewSection.rejected.includes(rejected))
        let emphasis = try CaptureItem.create(
            kind: .professorEmphasis,
            source: .quickCapture(try QuickCaptureReference()),
            courseID: CourseID(),
            rawText: "Not a candidate",
            draftFields: CaptureDraftFields(),
            capturedAt: timestamp,
            auditID: CaptureAuditEntryID()
        )
        XCTAssertFalse(CandidateReviewSection.toReview.includes(emphasis))
    }

    func testUnrepresentableStoredDateFailsClosedUntilUserChoosesANewDate() throws {
        let capture = try makeCandidate(
            kind: .assignmentCandidate,
            sessionID: CourseSessionID(),
            capturedAt: Date(timeIntervalSince1970: 10),
            fields: try CaptureDraftFields(
                title: "Deadline",
                date: AcademicLocalDate(year: 2026, month: 9, day: 11),
                dateCertainty: .confirmed
            )
        )
        var draft = CandidateEditorDraft(
            capture: capture,
            timeZoneIdentifier: "Invalid/TimeZone"
        )

        XCTAssertTrue(draft.hasUnrepresentableStoredDate)
        XCTAssertFalse(draft.canMarkReady)
        XCTAssertThrowsError(try draft.makeFields())
        draft.dateCertainty = .unknown
        XCTAssertTrue(draft.canMarkReady)
        XCTAssertNil(try draft.makeFields().date)
    }

    func testDetailIdentityChangesForDivergentContentAtTheSameRevision() throws {
        let base = try makeCandidate(
            kind: .assignmentCandidate,
            sessionID: CourseSessionID(),
            capturedAt: Date(timeIntervalSince1970: 10)
        )
        let divergent = try CaptureItem(
            schemaVersion: base.schemaVersion,
            id: base.id,
            revision: base.revision,
            kind: base.kind,
            source: base.source,
            courseID: base.courseID,
            sessionID: base.sessionID,
            rawText: base.rawText,
            draftFields: try CaptureDraftFields(
                title: "Concurrent title",
                dateCertainty: .unknown
            ),
            capturedAt: base.capturedAt,
            modifiedAt: base.modifiedAt,
            state: base.state,
            resolution: base.resolution,
            auditTrail: base.auditTrail
        )

        XCTAssertEqual(base.id, divergent.id)
        XCTAssertEqual(base.revision, divergent.revision)
        XCTAssertNotEqual(
            CandidateReviewDetailIdentity(capture: base),
            CandidateReviewDetailIdentity(capture: divergent)
        )
    }

    func testPendingReviewRetainsCanonicalExpectedImageAfterExternalReload() throws {
        let (initialState, mutation) = try makePendingPresentationState()
        var state = initialState
        let expected = try canonicalized(mutation.expectedCapture)

        let reconciliation = state.reconcile(
            currentCapture: expected,
            allowsEditing: true
        )

        XCTAssertEqual(reconciliation, .expectedImage)
        XCTAssertEqual(state.pendingMutation, mutation)
        XCTAssertEqual(state.errorMessage, "Retry this exact review")
        XCTAssertFalse(state.isWorking)
        XCTAssertTrue(state.ownsRetryState)
    }

    func testPendingReviewRecognizesCanonicalPostImageEvenAfterSessionCloses() throws {
        let (initialState, mutation) = try makePendingPresentationState()
        var state = initialState
        let postImage = try canonicalized(mutation.resultingCapture)

        let reconciliation = state.reconcile(
            currentCapture: postImage,
            allowsEditing: false
        )

        XCTAssertEqual(reconciliation, .applied)
        XCTAssertNil(state.pendingMutation)
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.isWorking)
        XCTAssertFalse(state.ownsRetryState)
    }

    func testPendingReviewUnlocksForSameRevisionDivergentExternalReload() throws {
        let (initialState, mutation) = try makePendingPresentationState()
        var state = initialState
        let base = try canonicalized(mutation.expectedCapture)
        let divergent = try CaptureItem(
            schemaVersion: base.schemaVersion,
            id: base.id,
            revision: base.revision,
            kind: base.kind,
            source: base.source,
            courseID: base.courseID,
            sessionID: base.sessionID,
            rawText: base.rawText,
            draftFields: try CaptureDraftFields(
                title: "External title",
                dateCertainty: .unknown
            ),
            capturedAt: base.capturedAt,
            modifiedAt: base.modifiedAt,
            state: base.state,
            resolution: base.resolution,
            auditTrail: base.auditTrail
        )

        let reconciliation = state.reconcile(
            currentCapture: divergent,
            allowsEditing: true
        )

        XCTAssertEqual(reconciliation, .conflict)
        XCTAssertNil(state.pendingMutation)
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.ownsRetryState)
    }

    func testPendingReviewUnlocksWhenExternalReloadRemovesCapture() throws {
        let (initialState, _) = try makePendingPresentationState()
        var state = initialState

        let reconciliation = state.reconcile(
            currentCapture: nil,
            allowsEditing: true
        )

        XCTAssertEqual(reconciliation, .missing)
        XCTAssertNil(state.pendingMutation)
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.ownsRetryState)
    }

    func testPendingReviewUnlocksWhenExpectedImageBecomesReadOnly() throws {
        let (initialState, mutation) = try makePendingPresentationState()
        var state = initialState

        let reconciliation = state.reconcile(
            currentCapture: try canonicalized(mutation.expectedCapture),
            allowsEditing: false
        )

        XCTAssertEqual(reconciliation, .terminalSession)
        XCTAssertNil(state.pendingMutation)
        XCTAssertNil(state.errorMessage)
        XCTAssertFalse(state.ownsRetryState)
    }

    private func makeCandidate(
        kind: CaptureKind,
        sessionID: CourseSessionID,
        capturedAt: Date,
        fields: CaptureDraftFields = try! CaptureDraftFields()
    ) throws -> CaptureItem {
        try CaptureItem.create(
            kind: kind,
            source: .quickCapture(try QuickCaptureReference()),
            courseID: CourseID(),
            sessionID: sessionID,
            rawText: "Candidate source",
            draftFields: fields,
            capturedAt: capturedAt,
            auditID: CaptureAuditEntryID()
        )
    }

    private func makePendingPresentationState() throws -> (
        CandidateReviewPresentationState,
        CaptureReviewMutation
    ) {
        let capturedAt = Date(timeIntervalSince1970: 10.123_456_7)
        let capture = try makeCandidate(
            kind: .assignmentCandidate,
            sessionID: CourseSessionID(),
            capturedAt: capturedAt
        )
        let mutation = try CaptureReviewMutation(
            base: capture,
            intent: .saveDraft(
                fields: try CaptureDraftFields(
                    title: "Reviewed candidate",
                    dateCertainty: .unknown
                ),
                occurredAt: Date(timeIntervalSince1970: 20.987_654_3),
                auditID: CaptureAuditEntryID()
            )
        )
        var state = CandidateReviewPresentationState()
        XCTAssertTrue(state.begin(mutation))
        XCTAssertTrue(state.retainForRetry(
            mutation,
            errorMessage: "Retry this exact review"
        ))
        return (state, mutation)
    }

    private func canonicalized(_ capture: CaptureItem) throws -> CaptureItem {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(CaptureItem.self, from: encoder.encode(capture))
    }
}
