import Foundation
import NextStepAcademic
import XCTest
@testable import NotesApp

@MainActor
final class SessionWrapUpPersistenceTests: XCTestCase {
    func testEndSessionPersistsAndSurvivesRelaunch() async throws {
        let fixture = try await makeFixture()
        let request = try endRequest(fixture.model, endedAt: date(130))

        let outcome = await fixture.model.endSession(
            request,
            savedAt: request.endedAt
        )

        XCTAssertEqual(outcome, .ended)
        let ended = try XCTUnwrap(fixture.model.workspace.sessions.first)
        XCTAssertEqual(ended.status, .needsReview)
        XCTAssertEqual(ended.actualEndedAt, request.endedAt)
        XCTAssertEqual(ended.revision, request.expectedRevision + 1)

        let relaunched = AcademicAppModel(
            store: NextStepAcademicStore(backing: fixture.backing)
        )
        await relaunched.load()
        XCTAssertEqual(relaunched.workspace.sessions, [ended])
        XCTAssertEqual(relaunched.availability, .ready)
    }

    func testEndSessionReconcilesCommitThenError() async throws {
        let fixture = try await makeFixture()
        let request = try endRequest(fixture.model, endedAt: date(131))
        let attemptsBefore = await fixture.backing.replaceAttemptCount()
        await fixture.backing.failAfterCommittingNextReplace()

        let outcome = await fixture.model.endSession(request)

        XCTAssertEqual(outcome, .ended)
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter - attemptsBefore, 1)
        XCTAssertEqual(
            fixture.model.workspace.sessions.first?.status,
            .needsReview
        )
        XCTAssertEqual(fixture.model.availability, .ready)
    }

    func testEndSessionRetriesTheSameRequestOnceWhenFirstWriteIsMissing() async throws {
        let fixture = try await makeFixture()
        let request = try endRequest(fixture.model, endedAt: date(132))
        let attemptsBefore = await fixture.backing.replaceAttemptCount()
        await fixture.backing.failNextReplaces(1)

        let outcome = await fixture.model.endSession(request)

        XCTAssertEqual(outcome, .ended)
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter - attemptsBefore, 2)
        let session = try XCTUnwrap(fixture.model.workspace.sessions.first)
        XCTAssertEqual(session.actualEndedAt, request.endedAt)
        XCTAssertEqual(session.revision, request.expectedRevision + 1)
    }

    func testEndSessionFinalSettleFindsRecoveryCommit() async throws {
        let fixture = try await makeFixture()
        let request = try endRequest(fixture.model, endedAt: date(132))
        let attemptsBefore = await fixture.backing.replaceAttemptCount()
        await fixture.backing.failNextReplaces(1)
        await fixture.backing.failAfterCommittingNextReplace()

        let outcome = await fixture.model.endSession(request)

        XCTAssertEqual(outcome, .ended)
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter - attemptsBefore, 2)
        XCTAssertEqual(fixture.model.workspace.sessions.first?.status, .needsReview)
        XCTAssertEqual(fixture.model.workspace.revision, 2)
        XCTAssertEqual(fixture.model.availability, .ready)
    }

    func testEndSessionStopsAfterOneRecoveryWrite() async throws {
        let fixture = try await makeFixture()
        let request = try endRequest(fixture.model, endedAt: date(133))
        let attemptsBefore = await fixture.backing.replaceAttemptCount()
        await fixture.backing.failNextReplaces(2)

        let outcome = await fixture.model.endSession(request)

        XCTAssertEqual(outcome, .notReady)
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter - attemptsBefore, 2)
        XCTAssertEqual(fixture.model.workspace.sessions.first?.status, .active)
        guard case let .unavailable(failure) = fixture.model.availability else {
            return XCTFail("A bounded end failure must remain academic-only.")
        }
        XCTAssertEqual(failure.operation, .endSession)
    }

    func testEndSessionPreflightRejectsBackwardTimeWithoutWriting() async throws {
        let fixture = try await makeFixture()
        let request = try endRequest(fixture.model, endedAt: date(109))
        let attemptsBefore = await fixture.backing.replaceAttemptCount()

        let outcome = await fixture.model.endSession(request)

        guard case let .invalid(reason) = outcome else {
            return XCTFail("A backward session end must fail preflight.")
        }
        XCTAssertFalse(reason.isEmpty)
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter, attemptsBefore)
        XCTAssertEqual(fixture.model.workspace.sessions.first?.status, .active)
        XCTAssertEqual(fixture.model.availability, .ready)
    }

    func testEndSessionRejectsUnencodableRequestAndSavedAtWithoutWriting() async throws {
        let fixture = try await makeFixture()
        let validRequest = try endRequest(fixture.model, endedAt: date(130))
        let enormousDate = Date(
            timeIntervalSinceReferenceDate: .greatestFiniteMagnitude
        )
        let enormousRequest = SessionEndRequest(
            sessionID: validRequest.sessionID,
            expectedRevision: validRequest.expectedRevision,
            endedAt: enormousDate
        )
        let workspaceBefore = fixture.model.workspace
        let attemptsBefore = await fixture.backing.replaceAttemptCount()

        let requestOutcome = await fixture.model.endSession(
            enormousRequest,
            savedAt: validRequest.endedAt
        )
        let savedAtOutcome = await fixture.model.endSession(
            validRequest,
            savedAt: enormousDate
        )

        guard case .invalid = requestOutcome else {
            return XCTFail("An unencodable SessionEndRequest must be rejected.")
        }
        guard case .invalid = savedAtOutcome else {
            return XCTFail("An unencodable session-end savedAt must be rejected.")
        }
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter, attemptsBefore)
        XCTAssertEqual(fixture.model.workspace, workspaceBefore)
        XCTAssertEqual(fixture.model.availability, .ready)
    }

    func testEndSessionDoesNotOverwriteAConcurrentEnd() async throws {
        let fixture = try await makeFixture()
        let request = try endRequest(fixture.model, endedAt: date(134))
        let concurrentEnd = date(135)
        let externalStore = NextStepAcademicStore(backing: fixture.backing)
        let external = try await externalStore.load()
        let current = try XCTUnwrap(external.workspace.sessions.first)
        let content = try AcademicWorkspaceCommand.transitionSession(
            id: current.id,
            expectedRevision: current.revision,
            to: .needsReview,
            at: concurrentEnd
        ).applying(to: external.workspace)
        _ = try await externalStore.commit(
            content,
            expected: external.token,
            savedAt: concurrentEnd
        )
        let attemptsBefore = await fixture.backing.replaceAttemptCount()

        let outcome = await fixture.model.endSession(request)

        XCTAssertEqual(outcome, .conflict)
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter - attemptsBefore, 1)
        let retained = try XCTUnwrap(fixture.model.workspace.sessions.first)
        XCTAssertEqual(retained.actualEndedAt, concurrentEnd)
        XCTAssertNotEqual(retained.actualEndedAt, request.endedAt)
        XCTAssertEqual(fixture.model.availability, .ready)
    }

    func testEndSessionCanonicalSubmillisecondReplayDoesNotWrite() async throws {
        let fixture = try await makeFixture()
        let endedAt = Date(timeIntervalSince1970: 443_383_332.546_070_1)
        let request = try endRequest(fixture.model, endedAt: endedAt)
        let initial = await fixture.model.endSession(request)
        XCTAssertEqual(initial, .ended)
        let attemptsAfterEnd = await fixture.backing.replaceAttemptCount()

        let relaunched = AcademicAppModel(
            store: NextStepAcademicStore(backing: fixture.backing)
        )
        await relaunched.load()
        let replay = await relaunched.endSession(request)

        XCTAssertEqual(replay, .alreadyEnded)
        let attemptsAfterReplay = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfterReplay, attemptsAfterEnd)
    }

    func testCompleteWrapUpPersistsAtomicallyAndSurvivesRelaunch() async throws {
        let fixture = try await endedFixture()
        let transaction = try makeWrapUp(
            in: fixture.model,
            completedAt: date(150)
        )

        let outcome = await fixture.model.completeWrapUp(transaction)

        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(fixture.model.workspace.sessions.first?.status, .reviewed)
        XCTAssertEqual(fixture.model.workspace.wrapUps.first?.id, transaction.wrapUpID)
        XCTAssertEqual(fixture.model.workspace.captures.first?.state, .needsDetails)

        let relaunched = AcademicAppModel(
            store: NextStepAcademicStore(backing: fixture.backing)
        )
        await relaunched.load()
        XCTAssertEqual(relaunched.workspace, fixture.model.workspace)
        XCTAssertEqual(relaunched.availability, .ready)
    }

    func testOriginalEndRequestIsAlreadyEndedAfterWrapUpCompletion() async throws {
        let fixture = try await endedFixture()
        let endedSession = try XCTUnwrap(fixture.model.workspace.sessions.first)
        let endedAt = try XCTUnwrap(endedSession.actualEndedAt)
        let originalEndRequest = SessionEndRequest(
            sessionID: endedSession.id,
            expectedRevision: endedSession.revision - 1,
            endedAt: endedAt
        )
        let transaction = try makeWrapUp(
            in: fixture.model,
            completedAt: date(150)
        )
        let completion = await fixture.model.completeWrapUp(transaction)
        XCTAssertEqual(completion, .completed)
        let attemptsAfterCompletion = await fixture.backing.replaceAttemptCount()

        let replay = await fixture.model.endSession(originalEndRequest)

        XCTAssertEqual(replay, .alreadyEnded)
        let attemptsAfterReplay = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfterReplay, attemptsAfterCompletion)
        XCTAssertEqual(fixture.model.workspace.sessions.first?.status, .reviewed)
    }

    func testCompleteWrapUpRejectsConflictingReuseOfWrapUpIdentifier() async throws {
        let fixture = try await endedFixture()
        let original = try makeWrapUp(
            in: fixture.model,
            completedAt: date(150)
        )
        let completion = await fixture.model.completeWrapUp(original)
        XCTAssertEqual(completion, .completed)
        let attemptsAfterCompletion = await fixture.backing.replaceAttemptCount()
        let conflicting = try SessionWrapUpTransaction(
            sessionID: original.sessionID,
            expectedSessionRevision: original.expectedSessionRevision,
            wrapUpID: original.wrapUpID,
            startedAt: original.startedAt,
            completedAt: date(151),
            oneLineSummary: "A different effect must not replace the saved wrap-up.",
            noNewActionsConfirmed: original.noNewActionsConfirmed,
            decisions: original.decisions
        )

        let outcome = await fixture.model.completeWrapUp(conflicting)

        XCTAssertEqual(outcome, .conflict)
        let attemptsAfterConflict = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfterConflict, attemptsAfterCompletion)
        XCTAssertEqual(fixture.model.workspace.wrapUps.first?.id, original.wrapUpID)
        XCTAssertEqual(
            fixture.model.workspace.wrapUps.first?.completedAt,
            original.completedAt
        )
    }

    func testCompleteWrapUpReconcilesCommitThenError() async throws {
        let fixture = try await endedFixture()
        let transaction = try makeWrapUp(
            in: fixture.model,
            completedAt: date(151)
        )
        let attemptsBefore = await fixture.backing.replaceAttemptCount()
        await fixture.backing.failAfterCommittingNextReplace()

        let outcome = await fixture.model.completeWrapUp(transaction)

        XCTAssertEqual(outcome, .completed)
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter - attemptsBefore, 1)
        XCTAssertEqual(fixture.model.workspace.wrapUps.count, 1)
        XCTAssertEqual(fixture.model.workspace.captures.first?.revision, 2)
        XCTAssertEqual(fixture.model.availability, .ready)
    }

    func testCompleteWrapUpRetriesTheExactTransactionOnce() async throws {
        let fixture = try await endedFixture()
        let transaction = try makeWrapUp(
            in: fixture.model,
            completedAt: date(152)
        )
        let attemptsBefore = await fixture.backing.replaceAttemptCount()
        await fixture.backing.failNextReplaces(1)

        let outcome = await fixture.model.completeWrapUp(transaction)

        XCTAssertEqual(outcome, .completed)
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter - attemptsBefore, 2)
        XCTAssertEqual(fixture.model.workspace.wrapUps.count, 1)
        XCTAssertEqual(
            fixture.model.workspace.captures.first?.auditTrail.last?.id,
            transaction.decisions.first?.auditIDs.first
        )
    }

    func testCompleteWrapUpFinalSettleFindsRecoveryCommit() async throws {
        let fixture = try await endedFixture()
        let transaction = try makeWrapUp(
            in: fixture.model,
            completedAt: date(152)
        )
        let attemptsBefore = await fixture.backing.replaceAttemptCount()
        await fixture.backing.failNextReplaces(1)
        await fixture.backing.failAfterCommittingNextReplace()

        let outcome = await fixture.model.completeWrapUp(transaction)

        XCTAssertEqual(outcome, .completed)
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter - attemptsBefore, 2)
        XCTAssertEqual(fixture.model.workspace.wrapUps.count, 1)
        XCTAssertEqual(fixture.model.workspace.captures.first?.revision, 2)
        XCTAssertEqual(fixture.model.availability, .ready)
    }

    func testCompleteWrapUpStopsAfterOneRecoveryWrite() async throws {
        let fixture = try await endedFixture()
        let transaction = try makeWrapUp(
            in: fixture.model,
            completedAt: date(153)
        )
        let attemptsBefore = await fixture.backing.replaceAttemptCount()
        await fixture.backing.failNextReplaces(2)

        let outcome = await fixture.model.completeWrapUp(transaction)

        XCTAssertEqual(outcome, .notReady)
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter - attemptsBefore, 2)
        XCTAssertTrue(fixture.model.workspace.wrapUps.isEmpty)
        XCTAssertEqual(fixture.model.workspace.sessions.first?.status, .needsReview)
        XCTAssertEqual(fixture.model.workspace.captures.first?.revision, 1)
        guard case let .unavailable(failure) = fixture.model.availability else {
            return XCTFail("A bounded wrap-up failure must remain academic-only.")
        }
        XCTAssertEqual(failure.operation, .completeWrapUp)
    }

    func testCompleteWrapUpPreflightRejectsCaptureRevisionWithoutWriting() async throws {
        let fixture = try await endedFixture()
        let session = try XCTUnwrap(fixture.model.workspace.sessions.first)
        let capture = try XCTUnwrap(fixture.model.workspace.captures.first)
        let decision = try SessionWrapUpDecision(
            captureID: capture.id,
            expectedRevision: capture.revision + 1,
            kind: .markNeedsDetails,
            auditIDs: [CaptureAuditEntryID(testUUID(5))]
        )
        let transaction = try SessionWrapUpTransaction(
            sessionID: session.id,
            expectedSessionRevision: session.revision,
            wrapUpID: SessionWrapUpID(testUUID(6)),
            startedAt: session.modifiedAt,
            completedAt: date(153),
            oneLineSummary: "Do not overwrite a newer capture revision.",
            noNewActionsConfirmed: false,
            decisions: [decision]
        )
        let attemptsBefore = await fixture.backing.replaceAttemptCount()

        let outcome = await fixture.model.completeWrapUp(transaction)

        XCTAssertEqual(outcome, .conflict)
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter, attemptsBefore)
        XCTAssertTrue(fixture.model.workspace.wrapUps.isEmpty)
        XCTAssertEqual(fixture.model.workspace.captures, [capture])
        XCTAssertEqual(fixture.model.availability, .ready)
    }

    func testCompleteWrapUpRejectsUnencodableTransactionAndSavedAtWithoutWriting() async throws {
        let fixture = try await endedFixture()
        let valid = try makeWrapUp(
            in: fixture.model,
            completedAt: date(153)
        )
        let enormousDate = Date(
            timeIntervalSinceReferenceDate: .greatestFiniteMagnitude
        )
        let enormous = try SessionWrapUpTransaction(
            sessionID: valid.sessionID,
            expectedSessionRevision: valid.expectedSessionRevision,
            wrapUpID: valid.wrapUpID,
            startedAt: valid.startedAt,
            completedAt: enormousDate,
            oneLineSummary: valid.oneLineSummary,
            noNewActionsConfirmed: valid.noNewActionsConfirmed,
            decisions: valid.decisions
        )
        let workspaceBefore = fixture.model.workspace
        let attemptsBefore = await fixture.backing.replaceAttemptCount()

        let transactionOutcome = await fixture.model.completeWrapUp(
            enormous,
            savedAt: valid.completedAt
        )
        let savedAtOutcome = await fixture.model.completeWrapUp(
            valid,
            savedAt: enormousDate
        )

        guard case .invalid = transactionOutcome else {
            return XCTFail("An unencodable wrap-up transaction must be rejected.")
        }
        guard case .invalid = savedAtOutcome else {
            return XCTFail("An unencodable wrap-up savedAt must be rejected.")
        }
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter, attemptsBefore)
        XCTAssertEqual(fixture.model.workspace, workspaceBefore)
        XCTAssertEqual(fixture.model.availability, .ready)
    }

    func testCompleteWrapUpDoesNotOverwriteConcurrentCaptureRevision() async throws {
        let fixture = try await endedFixture()
        let transaction = try makeWrapUp(
            in: fixture.model,
            completedAt: date(154)
        )
        let externalStore = NextStepAcademicStore(backing: fixture.backing)
        let external = try await externalStore.load()
        let capture = try XCTUnwrap(external.workspace.captures.first)
        let changed = try capture.updatingDraft(
            try CaptureDraftFields(details: "Concurrent clarification"),
            at: date(145),
            auditID: CaptureAuditEntryID(testUUID(8_501))
        )
        let changedContent = try AcademicWorkspaceContent(
            courses: external.workspace.courses,
            sessions: external.workspace.sessions,
            sessionNoteLinks: external.workspace.sessionNoteLinks,
            captures: [changed],
            wrapUps: external.workspace.wrapUps
        )
        _ = try await externalStore.commit(
            changedContent,
            expected: external.token,
            savedAt: date(145)
        )
        let attemptsBefore = await fixture.backing.replaceAttemptCount()

        let outcome = await fixture.model.completeWrapUp(transaction)

        XCTAssertEqual(outcome, .conflict)
        let attemptsAfter = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfter - attemptsBefore, 1)
        XCTAssertTrue(fixture.model.workspace.wrapUps.isEmpty)
        XCTAssertEqual(fixture.model.workspace.sessions.first?.status, .needsReview)
        XCTAssertEqual(fixture.model.workspace.captures, [changed])
        XCTAssertEqual(fixture.model.availability, .ready)
    }

    func testCompleteWrapUpCanonicalSubmillisecondReplayDoesNotWrite() async throws {
        let fixture = try await endedFixture()
        let completedAt = Date(timeIntervalSince1970: 443_383_352.987_654_3)
        let transaction = try makeWrapUp(
            in: fixture.model,
            completedAt: completedAt
        )
        let initial = await fixture.model.completeWrapUp(transaction)
        XCTAssertEqual(initial, .completed)
        let attemptsAfterCompletion = await fixture.backing.replaceAttemptCount()

        let relaunched = AcademicAppModel(
            store: NextStepAcademicStore(backing: fixture.backing)
        )
        await relaunched.load()
        let replay = await relaunched.completeWrapUp(transaction)

        XCTAssertEqual(replay, .alreadyCompleted)
        let attemptsAfterReplay = await fixture.backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfterReplay, attemptsAfterCompletion)
        XCTAssertEqual(relaunched.workspace.wrapUps.count, 1)
    }

    private struct Fixture {
        let backing: SessionWrapUpTestBacking
        let model: AcademicAppModel
    }

    private func makeFixture() async throws -> Fixture {
        let backing = SessionWrapUpTestBacking()
        let seedStore = NextStepAcademicStore(backing: backing)
        let empty = try await seedStore.load()
        let courseID = CourseID(testUUID(1))
        let sessionID = CourseSessionID(testUUID(2))
        let course = try Course(
            id: courseID,
            name: "Persistence Seminar",
            timeZoneIdentifier: "UTC",
            createdAt: date(100)
        )
        let planned = try CourseSession(
            id: sessionID,
            courseID: courseID,
            topic: "Recovery boundaries",
            createdAt: date(100)
        )
        let active = try planned.transitioned(to: .active, at: date(110))
        let capture = try CaptureItem.create(
            id: CaptureItemID(testUUID(3)),
            kind: .professorEmphasis,
            source: .quickCapture(try QuickCaptureReference()),
            courseID: courseID,
            sessionID: sessionID,
            rawText: "Review the exact persistence effect.",
            draftFields: try CaptureDraftFields(),
            capturedAt: date(120),
            auditID: CaptureAuditEntryID(testUUID(4))
        )
        let content = try AcademicWorkspaceContent(
            courses: [course],
            sessions: [active],
            captures: [capture]
        )
        _ = try await seedStore.commit(
            content,
            expected: empty.token,
            savedAt: date(120)
        )
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        return Fixture(backing: backing, model: model)
    }

    private func endedFixture() async throws -> Fixture {
        let fixture = try await makeFixture()
        let request = try endRequest(fixture.model, endedAt: date(130))
        let outcome = await fixture.model.endSession(
            request,
            savedAt: request.endedAt
        )
        XCTAssertEqual(outcome, .ended)
        return fixture
    }

    private func endRequest(
        _ model: AcademicAppModel,
        endedAt: Date
    ) throws -> SessionEndRequest {
        let session = try XCTUnwrap(model.workspace.sessions.first)
        return SessionEndRequest(
            sessionID: session.id,
            expectedRevision: session.revision,
            endedAt: endedAt
        )
    }

    private func makeWrapUp(
        in model: AcademicAppModel,
        completedAt: Date
    ) throws -> SessionWrapUpTransaction {
        let session = try XCTUnwrap(model.workspace.sessions.first)
        let capture = try XCTUnwrap(model.workspace.captures.first)
        let decision = try SessionWrapUpDecision(
            captureID: capture.id,
            expectedRevision: capture.revision,
            kind: .markNeedsDetails,
            auditIDs: [CaptureAuditEntryID(testUUID(5))]
        )
        return try SessionWrapUpTransaction(
            sessionID: session.id,
            expectedSessionRevision: session.revision,
            wrapUpID: SessionWrapUpID(testUUID(6)),
            startedAt: session.modifiedAt,
            completedAt: completedAt,
            oneLineSummary: "Reviewed this class and retained its key point.",
            noNewActionsConfirmed: false,
            decisions: [decision]
        )
    }

    private func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func testUUID(_ value: Int) -> UUID {
        let suffix = String(value)
        precondition(suffix.count <= 12)
        let padded = String(repeating: "0", count: 12 - suffix.count) + suffix
        return UUID(uuidString: "00000000-0000-0000-0000-\(padded)")!
    }
}

private actor SessionWrapUpTestBacking: AcademicWorkspaceFileBacking {
    private var state: State
    private var failuresRemaining = 0
    private var failAfterNextCommit = false
    private var replaceAttempts = 0

    init() {
        state = State(
            rootFingerprint: AcademicWorkspaceStorageFingerprint(),
            stateFingerprint: AcademicWorkspaceStateFingerprint(),
            storageRevision: 0,
            primary: nil,
            backup: nil
        )
    }

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
