import Foundation
import NextStepAcademic
import XCTest
@testable import NotesApp

@MainActor
final class CandidateReviewPersistenceTests: XCTestCase {
    func testReviewPersistsAndSurvivesRelaunch() async throws {
        let fixture = try await makeFixture()
        let mutation = try makeMutation(in: fixture.model)

        let outcome = await fixture.model.reviewCapture(
            mutation,
            savedAt: mutation.resultingCapture.modifiedAt
        )

        XCTAssertEqual(outcome, .applied(mutation.resultingCapture))
        XCTAssertEqual(
            fixture.model.workspace.captures,
            [mutation.resultingCapture]
        )
        let relaunched = AcademicAppModel(
            store: NextStepAcademicStore(backing: fixture.backing)
        )
        await relaunched.load()
        XCTAssertEqual(
            relaunched.workspace.captures,
            [mutation.resultingCapture]
        )
        XCTAssertEqual(relaunched.availability, .ready)
    }

    func testPreexistingPostImageReturnsAlreadyAppliedWithoutWriting() async throws {
        let fixture = try await makeFixture()
        let mutation = try makeMutation(in: fixture.model)
        let initial = await fixture.model.reviewCapture(mutation)
        XCTAssertEqual(
            initial,
            .applied(mutation.resultingCapture)
        )
        let attemptsBeforeReplay = await fixture.backing.replaceAttemptCount()

        let replay = await fixture.model.reviewCapture(mutation)

        XCTAssertEqual(replay, .alreadyApplied(mutation.resultingCapture))
        let attemptsAfterReplay = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfterReplay, attemptsBeforeReplay)
    }

    func testCommitThenErrorReconcilesTheAppliedPostImage() async throws {
        let fixture = try await makeFixture()
        let mutation = try makeMutation(in: fixture.model)
        let attemptsBefore = await fixture.backing.replaceAttemptCount()
        await fixture.backing.failAfterCommittingNextReplace()

        let outcome = await fixture.model.reviewCapture(mutation)

        XCTAssertEqual(outcome, .applied(mutation.resultingCapture))
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter - attemptsBefore, 1)
        XCTAssertEqual(fixture.model.workspace.captures.count, 1)
        XCTAssertEqual(
            fixture.model.workspace.captures.first?.revision,
            mutation.resultingCapture.revision
        )
        XCTAssertEqual(fixture.model.availability, .ready)
    }

    func testMissingEffectRetriesTheSameMutationOnce() async throws {
        let fixture = try await makeFixture()
        let mutation = try makeMutation(in: fixture.model)
        let attemptsBefore = await fixture.backing.replaceAttemptCount()
        await fixture.backing.failNextReplaces(1)

        let outcome = await fixture.model.reviewCapture(mutation)

        XCTAssertEqual(outcome, .applied(mutation.resultingCapture))
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter - attemptsBefore, 2)
        let saved = try XCTUnwrap(fixture.model.workspace.captures.first)
        XCTAssertEqual(
            saved.auditTrail.suffix(2).map(\.id),
            mutation.intent.auditIDs
        )
    }

    func testUnrelatedWorkspaceCASDriftRetriesWithoutLosingOtherContent() async throws {
        let fixture = try await makeFixture()
        let mutation = try makeMutation(in: fixture.model)
        let externalStore = NextStepAcademicStore(backing: fixture.backing)
        let external = try await externalStore.load()
        let otherCourse = try Course(
            id: CourseID(candidateUUID(70)),
            name: "Concurrent course",
            timeZoneIdentifier: "UTC",
            createdAt: candidateDate(105)
        )
        let changedContent = try AcademicWorkspaceContent(
            courses: external.workspace.courses + [otherCourse],
            sessions: external.workspace.sessions,
            sessionNoteLinks: external.workspace.sessionNoteLinks,
            captures: external.workspace.captures,
            wrapUps: external.workspace.wrapUps
        )
        _ = try await externalStore.commit(
            changedContent,
            expected: external.token,
            savedAt: candidateDate(110)
        )
        let attemptsBefore = await fixture.backing.replaceAttemptCount()

        let outcome = await fixture.model.reviewCapture(mutation)

        XCTAssertEqual(outcome, .applied(mutation.resultingCapture))
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter - attemptsBefore, 2)
        XCTAssertTrue(fixture.model.workspace.courses.contains(where: {
            $0.id == otherCourse.id
        }))
        XCTAssertEqual(
            fixture.model.workspace.captures,
            [mutation.resultingCapture]
        )
    }

    func testActiveToNeedsReviewCASDriftStillAllowsTheExactCandidateReview() async throws {
        let fixture = try await makeSessionFixture(status: .active)
        let mutation = try makeMutation(in: fixture.model)
        let externalStore = NextStepAcademicStore(backing: fixture.backing)
        let external = try await externalStore.load()
        let session = try XCTUnwrap(external.workspace.sessions.first)
        let endedContent = try AcademicWorkspaceCommand.transitionSession(
            id: session.id,
            expectedRevision: session.revision,
            to: .needsReview,
            at: candidateDate(110)
        ).applying(to: external.workspace)
        _ = try await externalStore.commit(
            endedContent,
            expected: external.token,
            savedAt: candidateDate(110)
        )
        let attemptsBefore = await fixture.backing.replaceAttemptCount()

        let outcome = await fixture.model.reviewCapture(mutation)

        XCTAssertEqual(outcome, .applied(mutation.resultingCapture))
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter - attemptsBefore, 2)
        XCTAssertEqual(
            fixture.model.workspace.sessions.first?.status,
            .needsReview
        )
        XCTAssertEqual(
            fixture.model.workspace.captures,
            [mutation.resultingCapture]
        )
    }

    func testWrapUpWinningTheCASRacePreventsCandidateRecoveryWrite() async throws {
        let fixture = try await makeSessionFixture(status: .active)
        let mutation = try makeMutation(in: fixture.model)
        let externalStore = NextStepAcademicStore(backing: fixture.backing)
        let external = try await externalStore.load()
        let transaction = try keepAsIsWrapUp(
            in: external.workspace,
            completedAt: candidateDate(120)
        )
        let reviewedContent = try AcademicWorkspaceCommand
            .applyWrapUp(transaction)
            .applying(to: external.workspace)
        let reviewed = try await externalStore.commit(
            reviewedContent,
            expected: external.token,
            savedAt: transaction.completedAt
        )
        let attemptsBefore = await fixture.backing.replaceAttemptCount()

        let outcome = await fixture.model.reviewCapture(mutation)

        XCTAssertEqual(outcome, .revisionConflict(mutation.expectedCapture))
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter - attemptsBefore, 1)
        XCTAssertEqual(fixture.model.workspace, reviewed.workspace)
        XCTAssertEqual(
            fixture.model.workspace.sessions.first?.status,
            .reviewed
        )
        XCTAssertEqual(
            fixture.model.workspace.captures,
            [mutation.expectedCapture]
        )
        XCTAssertTrue(
            fixture.model.workspace.captures[0].auditTrail.allSatisfy {
                !mutation.intent.auditIDs.contains($0.id)
            }
        )
    }

    func testCandidateCommitThenWrapUpKeepsExactReplayIdempotent() async throws {
        let fixture = try await makeSessionFixture(status: .active)
        let mutation = try makeMutation(in: fixture.model)
        let applied = await fixture.model.reviewCapture(mutation)
        XCTAssertEqual(applied, .applied(mutation.resultingCapture))
        let transaction = try keepAsIsWrapUp(
            in: fixture.model.workspace,
            completedAt: candidateDate(140)
        )
        let completed = await fixture.model.completeWrapUp(transaction)
        XCTAssertEqual(completed, .completed)
        XCTAssertEqual(
            fixture.model.workspace.sessions.first?.status,
            .reviewed
        )
        XCTAssertEqual(
            fixture.model.workspace.captures,
            [mutation.resultingCapture]
        )
        let attemptsBeforeReplay = await fixture.backing.replaceAttemptCount()

        let replay = await fixture.model.reviewCapture(mutation)

        XCTAssertEqual(replay, .alreadyApplied(mutation.resultingCapture))
        let attemptsAfterReplay = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfterReplay, attemptsBeforeReplay)
        XCTAssertEqual(
            fixture.model.workspace.sessions.first?.status,
            .reviewed
        )
        XCTAssertEqual(
            fixture.model.workspace.captures,
            [mutation.resultingCapture]
        )
    }

    func testReviewedSessionRejectsCandidateReviewWithoutWriting() async throws {
        let fixture = try await makeSessionFixture(status: .reviewed)
        let mutation = try makeMutation(in: fixture.model)
        let capture = try XCTUnwrap(fixture.model.workspace.captures.first)
        let attemptsBefore = await fixture.backing.replaceAttemptCount()

        let outcome = await fixture.model.reviewCapture(mutation)

        XCTAssertEqual(outcome, .revisionConflict(capture))
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter, attemptsBefore)
        XCTAssertEqual(fixture.model.workspace.captures, [capture])
        XCTAssertEqual(fixture.model.availability, .ready)
    }

    func testCancelledSessionRejectsCandidateReviewWithoutWriting() async throws {
        let fixture = try await makeSessionFixture(status: .cancelled)
        let mutation = try makeMutation(in: fixture.model)
        let capture = try XCTUnwrap(fixture.model.workspace.captures.first)
        let attemptsBefore = await fixture.backing.replaceAttemptCount()

        let outcome = await fixture.model.reviewCapture(mutation)

        XCTAssertEqual(outcome, .revisionConflict(capture))
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter, attemptsBefore)
        XCTAssertEqual(fixture.model.workspace.captures, [capture])
        XCTAssertEqual(fixture.model.availability, .ready)
    }

    func testMissingOwningSessionStopsCandidateRecoveryWrite() async throws {
        let fixture = try await makeSessionFixture(status: .active)
        let mutation = try makeMutation(in: fixture.model)
        let externalStore = NextStepAcademicStore(backing: fixture.backing)
        let external = try await externalStore.load()
        let removedContent = try AcademicWorkspaceContent(
            courses: external.workspace.courses
        )
        let removed = try await externalStore.commit(
            removedContent,
            expected: external.token,
            savedAt: candidateDate(120)
        )
        let attemptsBefore = await fixture.backing.replaceAttemptCount()

        let outcome = await fixture.model.reviewCapture(mutation)

        XCTAssertEqual(outcome, .revisionConflict(mutation.expectedCapture))
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter - attemptsBefore, 1)
        XCTAssertEqual(fixture.model.workspace, removed.workspace)
        XCTAssertTrue(fixture.model.workspace.sessions.isEmpty)
        XCTAssertTrue(fixture.model.workspace.captures.isEmpty)
        XCTAssertEqual(fixture.model.availability, .ready)
    }

    func testSameRevisionDivergentCaptureReturnsConflictWithoutOverwrite() async throws {
        let fixture = try await makeFixture()
        let mutation = try makeMutation(in: fixture.model)
        let externalStore = NextStepAcademicStore(backing: fixture.backing)
        let external = try await externalStore.load()
        let expected = try XCTUnwrap(external.workspace.captures.first)
        let divergent = try CaptureItem(
            schemaVersion: expected.schemaVersion,
            id: expected.id,
            revision: expected.revision,
            kind: expected.kind,
            source: expected.source,
            courseID: expected.courseID,
            sessionID: expected.sessionID,
            rawText: expected.rawText,
            draftFields: try CaptureDraftFields(
                title: "Concurrent draft",
                dateCertainty: .unknown
            ),
            capturedAt: expected.capturedAt,
            modifiedAt: expected.modifiedAt,
            state: expected.state,
            resolution: expected.resolution,
            auditTrail: expected.auditTrail
        )
        let changedContent = try AcademicWorkspaceContent(
            courses: external.workspace.courses,
            sessions: external.workspace.sessions,
            sessionNoteLinks: external.workspace.sessionNoteLinks,
            captures: [divergent],
            wrapUps: external.workspace.wrapUps
        )
        _ = try await externalStore.commit(
            changedContent,
            expected: external.token,
            savedAt: external.workspace.savedAt
        )
        let attemptsBefore = await fixture.backing.replaceAttemptCount()

        let outcome = await fixture.model.reviewCapture(mutation)

        XCTAssertEqual(outcome, .revisionConflict(divergent))
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter - attemptsBefore, 1)
        XCTAssertEqual(fixture.model.workspace.captures, [divergent])
        XCTAssertEqual(fixture.model.availability, .ready)
    }

    func testRetryCommitThenErrorSettlesAsApplied() async throws {
        let fixture = try await makeFixture()
        let mutation = try makeMutation(in: fixture.model)
        let attemptsBefore = await fixture.backing.replaceAttemptCount()
        await fixture.backing.failNextReplaces(1)
        await fixture.backing.failAfterCommittingNextReplace()

        let outcome = await fixture.model.reviewCapture(mutation)

        XCTAssertEqual(outcome, .applied(mutation.resultingCapture))
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter - attemptsBefore, 2)
        XCTAssertEqual(
            fixture.model.workspace.captures,
            [mutation.resultingCapture]
        )
        XCTAssertEqual(fixture.model.availability, .ready)
    }

    func testTwoWriteFailuresAreBoundedAndRetainPublishedWorkspace() async throws {
        let fixture = try await makeFixture()
        let mutation = try makeMutation(in: fixture.model)
        let expected = fixture.model.workspace
        let attemptsBefore = await fixture.backing.replaceAttemptCount()
        await fixture.backing.failNextReplaces(2)

        let outcome = await fixture.model.reviewCapture(mutation)

        XCTAssertEqual(outcome, .notReady)
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter - attemptsBefore, 2)
        XCTAssertEqual(fixture.model.workspace, expected)
        guard case let .unavailable(failure) = fixture.model.availability else {
            return XCTFail("A bounded Candidate Review failure must stay academic-only.")
        }
        XCTAssertEqual(failure.operation, .reviewCapture)
    }

    func testRepeatingSameMutationNeverDuplicatesAuditEntries() async throws {
        let fixture = try await makeFixture()
        let mutation = try makeMutation(in: fixture.model)
        let initial = await fixture.model.reviewCapture(mutation)
        XCTAssertEqual(
            initial,
            .applied(mutation.resultingCapture)
        )
        let attemptsAfterFirst = await fixture.backing.replaceAttemptCount()

        let second = await fixture.model.reviewCapture(mutation)
        let third = await fixture.model.reviewCapture(mutation)

        XCTAssertEqual(second, .alreadyApplied(mutation.resultingCapture))
        XCTAssertEqual(third, .alreadyApplied(mutation.resultingCapture))
        let attemptsAfterReplays = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfterReplays, attemptsAfterFirst)
        let saved = try XCTUnwrap(fixture.model.workspace.captures.first)
        for auditID in mutation.intent.auditIDs {
            XCTAssertEqual(
                saved.auditTrail.filter { $0.id == auditID }.count,
                1
            )
        }
    }

    func testValidMissingTargetIsTypedAndDoesNotWrite() async throws {
        let fixture = try await makeFixture()
        let missingBase = try CaptureItem.create(
            id: CaptureItemID(candidateUUID(80)),
            kind: .assignmentCandidate,
            source: .quickCapture(try QuickCaptureReference()),
            courseID: fixture.courseID,
            rawText: "A valid Candidate that is not in this workspace.",
            draftFields: try CaptureDraftFields(),
            capturedAt: candidateDate(100),
            auditID: CaptureAuditEntryID(candidateUUID(81))
        )
        let mutation = try makeMutation(base: missingBase)
        let attemptsBefore = await fixture.backing.replaceAttemptCount()

        let outcome = await fixture.model.reviewCapture(mutation)

        XCTAssertEqual(outcome, .missing)
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter, attemptsBefore)
        XCTAssertEqual(fixture.model.availability, .ready)
    }

    func testInvalidSavedAtDoesNotWriteOrChangeAvailability() async throws {
        let fixture = try await makeFixture()
        let mutation = try makeMutation(in: fixture.model)
        let workspaceBefore = fixture.model.workspace
        let attemptsBefore = await fixture.backing.replaceAttemptCount()

        let outcome = await fixture.model.reviewCapture(
            mutation,
            savedAt: Date(timeIntervalSinceReferenceDate: .nan)
        )
        let enormousFiniteOutcome = await fixture.model.reviewCapture(
            mutation,
            savedAt: Date(
                timeIntervalSinceReferenceDate: .greatestFiniteMagnitude
            )
        )

        guard case .invalid = outcome else {
            return XCTFail("A non-finite savedAt must be rejected before writing.")
        }
        guard case .invalid = enormousFiniteOutcome else {
            return XCTFail("An unencodable savedAt must be rejected before writing.")
        }
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter, attemptsBefore)
        XCTAssertEqual(fixture.model.workspace, workspaceBefore)
        XCTAssertEqual(fixture.model.availability, .ready)
    }

    func testGloballyInvalidAuditIdentifierDoesNotOpenAWrite() async throws {
        let fixture = try await makeFixture()
        let externalStore = NextStepAcademicStore(backing: fixture.backing)
        let external = try await externalStore.load()
        let other = try CaptureItem.create(
            id: CaptureItemID(candidateUUID(90)),
            kind: .examCandidate,
            source: .quickCapture(try QuickCaptureReference()),
            courseID: fixture.courseID,
            rawText: "Another Candidate owns the intended audit identifier.",
            draftFields: try CaptureDraftFields(),
            capturedAt: candidateDate(101),
            auditID: CaptureAuditEntryID(candidateUUID(4))
        )
        let expanded = try AcademicWorkspaceContent(
            courses: external.workspace.courses,
            sessions: external.workspace.sessions,
            sessionNoteLinks: external.workspace.sessionNoteLinks,
            captures: external.workspace.captures + [other],
            wrapUps: external.workspace.wrapUps
        )
        _ = try await externalStore.commit(
            expanded,
            expected: external.token,
            savedAt: candidateDate(101)
        )
        let current = AcademicAppModel(
            store: NextStepAcademicStore(backing: fixture.backing)
        )
        await current.load()
        let mutation = try makeMutation(in: current)
        let attemptsBefore = await fixture.backing.replaceAttemptCount()

        let outcome = await current.reviewCapture(mutation)

        guard case .invalid = outcome else {
            return XCTFail("A globally duplicated audit ID must fail preflight.")
        }
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter, attemptsBefore)
        XCTAssertEqual(current.workspace.captures.count, 2)
        XCTAssertEqual(current.availability, .ready)
    }

    func testSubmillisecondMutationReplaysCanonicallyWithoutWriting() async throws {
        let fixture = try await makeFixture()
        let timestamp = Date(timeIntervalSince1970: 130.987_654_321)
        let mutation = try makeMutation(
            in: fixture.model,
            occurredAt: timestamp
        )
        guard case .applied = await fixture.model.reviewCapture(mutation) else {
            return XCTFail("The first canonical Candidate Review must apply.")
        }
        let attemptsAfterApply = await fixture.backing.replaceAttemptCount()
        let relaunched = AcademicAppModel(
            store: NextStepAcademicStore(backing: fixture.backing)
        )
        await relaunched.load()

        let replay = await relaunched.reviewCapture(mutation)

        guard case let .alreadyApplied(saved) = replay else {
            return XCTFail("The canonical post-image must be recognized after relaunch.")
        }
        XCTAssertEqual(saved.id, mutation.resultingCapture.id)
        XCTAssertEqual(saved.revision, mutation.resultingCapture.revision)
        XCTAssertEqual(saved.auditTrail.map(\.id), mutation.resultingCapture.auditTrail.map(\.id))
        let attemptsAfterReplay = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfterReplay, attemptsAfterApply)
    }

    func testNotReadyDoesNotClearOrMutateModelState() async throws {
        let fixture = try await makeFixture()
        let mutation = try makeMutation(in: fixture.model)
        let dormant = AcademicAppModel(
            store: NextStepAcademicStore(backing: fixture.backing)
        )
        let attemptsBefore = await fixture.backing.replaceAttemptCount()

        let outcome = await dormant.reviewCapture(mutation)

        XCTAssertEqual(outcome, .notReady)
        XCTAssertEqual(dormant.workspace, .empty)
        XCTAssertEqual(dormant.availability, .idle)
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter, attemptsBefore)
    }

    private struct Fixture {
        let backing: CandidateReviewTestBacking
        let model: AcademicAppModel
        let courseID: CourseID
    }

    private struct SessionFixture {
        let backing: CandidateReviewTestBacking
        let model: AcademicAppModel
    }

    private func makeFixture() async throws -> Fixture {
        let backing = CandidateReviewTestBacking()
        let store = NextStepAcademicStore(backing: backing)
        let empty = try await store.load()
        let courseID = CourseID(candidateUUID(1))
        let course = try Course(
            id: courseID,
            name: "Candidate Persistence",
            timeZoneIdentifier: "UTC",
            createdAt: candidateDate(90)
        )
        let capture = try CaptureItem.create(
            id: CaptureItemID(candidateUUID(2)),
            kind: .assignmentCandidate,
            source: .quickCapture(try QuickCaptureReference()),
            courseID: courseID,
            rawText: "Review this exact Candidate.",
            draftFields: try CaptureDraftFields(),
            capturedAt: candidateDate(100),
            auditID: CaptureAuditEntryID(candidateUUID(3))
        )
        let content = try AcademicWorkspaceContent(
            courses: [course],
            captures: [capture]
        )
        _ = try await store.commit(
            content,
            expected: empty.token,
            savedAt: candidateDate(100)
        )
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        return Fixture(backing: backing, model: model, courseID: courseID)
    }

    private func makeSessionFixture(
        status: CourseSessionStatus
    ) async throws -> SessionFixture {
        let backing = CandidateReviewTestBacking()
        let store = NextStepAcademicStore(backing: backing)
        let empty = try await store.load()
        let courseID = CourseID(candidateUUID(100))
        let sessionID = CourseSessionID(candidateUUID(101))
        let course = try Course(
            id: courseID,
            name: "Session Candidate Persistence",
            timeZoneIdentifier: "UTC",
            createdAt: candidateDate(90)
        )
        let planned = try CourseSession(
            id: sessionID,
            courseID: courseID,
            topic: "Candidate and Wrap-up ordering",
            createdAt: candidateDate(90)
        )
        let active = try planned.transitioned(
            to: .active,
            at: candidateDate(95)
        )
        let capture = try CaptureItem.create(
            id: CaptureItemID(candidateUUID(102)),
            kind: .assignmentCandidate,
            source: .quickCapture(try QuickCaptureReference()),
            courseID: courseID,
            sessionID: sessionID,
            rawText: "Do not review this Candidate after its session closes.",
            draftFields: try CaptureDraftFields(),
            capturedAt: candidateDate(100),
            auditID: CaptureAuditEntryID(candidateUUID(103))
        )

        let session: CourseSession
        let captures: [CaptureItem]
        let wrapUps: [SessionWrapUp]
        switch status {
        case .planned:
            session = planned
            captures = [capture]
            wrapUps = []
        case .active:
            session = active
            captures = [capture]
            wrapUps = []
        case .needsReview:
            session = try active.transitioned(
                to: .needsReview,
                at: candidateDate(110)
            )
            captures = [capture]
            wrapUps = []
        case .reviewed:
            let transaction = try SessionWrapUpTransaction(
                sessionID: sessionID,
                expectedSessionRevision: active.revision,
                wrapUpID: SessionWrapUpID(candidateUUID(104)),
                startedAt: candidateDate(110),
                completedAt: candidateDate(120),
                oneLineSummary: "The Wrap-up owns the final session state.",
                noNewActionsConfirmed: false,
                decisions: [
                    try SessionWrapUpDecision(
                        captureID: capture.id,
                        expectedRevision: capture.revision,
                        kind: .keepAsIs
                    ),
                ]
            )
            let result = try transaction.applying(
                to: active,
                captures: [capture]
            )
            session = result.session
            captures = result.captures
            wrapUps = [result.wrapUp]
        case .cancelled:
            session = try planned.transitioned(
                to: .cancelled,
                at: candidateDate(105)
            )
            captures = [capture]
            wrapUps = []
        }
        let content = try AcademicWorkspaceContent(
            courses: [course],
            sessions: [session],
            captures: captures,
            wrapUps: wrapUps
        )
        _ = try await store.commit(
            content,
            expected: empty.token,
            savedAt: max(
                session.modifiedAt,
                captures.map(\.modifiedAt).max() ?? session.modifiedAt
            )
        )
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        return SessionFixture(backing: backing, model: model)
    }

    private func keepAsIsWrapUp(
        in workspace: AcademicWorkspace,
        completedAt: Date
    ) throws -> SessionWrapUpTransaction {
        let session = try XCTUnwrap(workspace.sessions.first)
        let capture = try XCTUnwrap(workspace.captures.first)
        return try SessionWrapUpTransaction(
            sessionID: session.id,
            expectedSessionRevision: session.revision,
            wrapUpID: SessionWrapUpID(candidateUUID(105)),
            startedAt: max(session.modifiedAt, candidateDate(110)),
            completedAt: completedAt,
            oneLineSummary: "Wrap-up won before Candidate Review reconciliation.",
            noNewActionsConfirmed: false,
            decisions: [
                try SessionWrapUpDecision(
                    captureID: capture.id,
                    expectedRevision: capture.revision,
                    kind: .keepAsIs
                ),
            ]
        )
    }

    private func makeMutation(
        in model: AcademicAppModel,
        occurredAt: Date = candidateDate(130)
    ) throws -> CaptureReviewMutation {
        try makeMutation(
            base: XCTUnwrap(model.workspace.captures.first),
            occurredAt: occurredAt
        )
    }

    private func makeMutation(
        base: CaptureItem,
        occurredAt: Date = candidateDate(130)
    ) throws -> CaptureReviewMutation {
        try CaptureReviewMutation(
            base: base,
            intent: .markReadyToConfirm(
                fields: try CaptureDraftFields(
                    title: "Reviewed assignment",
                    details: "Ready for formal confirmation in V1.5.",
                    dateCertainty: .unknown
                ),
                occurredAt: occurredAt,
                auditIDs: [
                    CaptureAuditEntryID(candidateUUID(4)),
                    CaptureAuditEntryID(candidateUUID(5)),
                ]
            )
        )
    }
}

private func candidateDate(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

private func candidateUUID(_ value: Int) -> UUID {
    let suffix = String(value)
    precondition(suffix.count <= 12)
    let padded = String(repeating: "0", count: 12 - suffix.count) + suffix
    return UUID(uuidString: "00000000-0000-0000-0000-\(padded)")!
}

private actor CandidateReviewTestBacking: AcademicWorkspaceFileBacking {
    private var state = State(
        rootFingerprint: AcademicWorkspaceStorageFingerprint(),
        stateFingerprint: AcademicWorkspaceStateFingerprint(),
        storageRevision: 0,
        primary: nil,
        backup: nil
    )
    private var failuresRemaining = 0
    private var failAfterNextCommit = false
    private var replaceAttempts = 0

    func replaceAttemptCount() -> Int { replaceAttempts }

    func failNextReplaces(_ count: Int) {
        precondition(count >= 0)
        failuresRemaining += count
    }

    func failAfterCommittingNextReplace() {
        failAfterNextCommit = true
    }

    func read() async throws(AcademicWorkspaceFileBackingError)
        -> AcademicWorkspaceFileSnapshot {
        try snapshot()
    }

    func replace(
        primaryData: Data?,
        backupData: Data?,
        expected: AcademicWorkspaceStorageVersion
    ) async throws(AcademicWorkspaceFileBackingError)
        -> AcademicWorkspaceFileSnapshot {
        replaceAttempts += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw .unavailable
        }
        guard try version() == expected else { throw .conflict }
        let (nextRevision, overflow) = state.storageRevision
            .addingReportingOverflow(1)
        guard !overflow else { throw .storageRevisionOverflow }
        state.storageRevision = nextRevision
        state.stateFingerprint = AcademicWorkspaceStateFingerprint()
        state.primary = primaryData
        state.backup = backupData
        if failAfterNextCommit {
            failAfterNextCommit = false
            throw .unavailable
        }
        return try snapshot()
    }

    func reset(
        expected: AcademicWorkspaceStorageVersion
    ) async throws(AcademicWorkspaceFileBackingError)
        -> AcademicWorkspaceFileSnapshot {
        try await replace(
            primaryData: nil,
            backupData: nil,
            expected: expected
        )
    }

    private func snapshot()
        throws(AcademicWorkspaceFileBackingError) -> AcademicWorkspaceFileSnapshot {
        AcademicWorkspaceFileSnapshot(
            primary: slot(state.primary),
            backup: slot(state.backup),
            version: try version()
        )
    }

    private func version()
        throws(AcademicWorkspaceFileBackingError) -> AcademicWorkspaceStorageVersion {
        try AcademicWorkspaceStorageVersion(
            rootFingerprint: state.rootFingerprint,
            stateFingerprint: state.stateFingerprint,
            storageRevision: state.storageRevision
        )
    }

    private func slot(_ data: Data?) -> AcademicWorkspaceFileSlotValue {
        guard let data else { return .missing }
        guard data.count <= AcademicWorkspaceLimits.maximumEncodedBytes else {
            return .oversized
        }
        return .data(data)
    }

    private struct State {
        let rootFingerprint: AcademicWorkspaceStorageFingerprint
        var stateFingerprint: AcademicWorkspaceStateFingerprint
        var storageRevision: Int64
        var primary: Data?
        var backup: Data?
    }
}
