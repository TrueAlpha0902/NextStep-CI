import Foundation
import NextStepAcademic
import XCTest
@testable import NotesApp

@MainActor
final class AcademicAppModelTests: XCTestCase {
    func testLoadIsIdempotentAndAddCourseSurvivesRelaunch() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )

        XCTAssertEqual(model.availability, .idle)
        await model.load()
        XCTAssertEqual(model.availability, .ready)
        XCTAssertTrue(model.courses.isEmpty)

        let readsAfterFirstLoad = await backing.readCount()
        await model.load()
        let readsAfterSecondLoad = await backing.readCount()
        XCTAssertEqual(readsAfterSecondLoad, readsAfterFirstLoad)

        let savedAt = Date(timeIntervalSince1970: 100)
        let course = try makeCourse(name: "Algorithms", at: savedAt)
        let saved = await model.apply(.addCourse(course), savedAt: savedAt)

        XCTAssertTrue(saved)
        XCTAssertEqual(model.availability, .ready)
        XCTAssertEqual(model.courses, [course])

        let relaunched = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await relaunched.load()

        XCTAssertEqual(relaunched.availability, .ready)
        XCTAssertEqual(relaunched.courses, [course])
    }

    func testLoadFailureStaysUnavailableUntilAcademicRetry() async {
        let backing = AcademicAppModelBacking()
        await backing.failNextRead()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )

        await model.load()

        guard case let .unavailable(failure) = model.availability else {
            return XCTFail("Expected an academic-only load failure.")
        }
        XCTAssertEqual(failure.operation, .load)
        XCTAssertEqual(model.workspace, .empty)

        await model.retry()

        XCTAssertEqual(model.availability, .ready)
        XCTAssertEqual(model.workspace, .empty)
    }

    func testFailedMutationKeepsPublishedWorkspaceAndRetryReloadsIt() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()

        let firstDate = Date(timeIntervalSince1970: 100)
        let first = try makeCourse(name: "Algorithms", at: firstDate)
        let firstSaved = await model.apply(.addCourse(first), savedAt: firstDate)
        XCTAssertTrue(firstSaved)

        await backing.failNextReplace()
        let secondDate = Date(timeIntervalSince1970: 200)
        let second = try makeCourse(name: "Databases", at: secondDate)
        let saved = await model.apply(.addCourse(second), savedAt: secondDate)

        XCTAssertFalse(saved)
        XCTAssertEqual(model.courses, [first])
        guard case let .unavailable(failure) = model.availability else {
            return XCTFail("Expected an academic-only save failure.")
        }
        XCTAssertEqual(failure.operation, .mutation)
        XCTAssertFalse(failure.message.isEmpty)

        await model.retry()

        XCTAssertEqual(model.availability, .ready)
        XCTAssertEqual(model.courses, [first])
    }

    func testFailedRetryReadKeepsLastProvenWorkspaceVisibleReadOnly() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()

        let firstDate = Date(timeIntervalSince1970: 100)
        let first = try makeCourse(name: "Algorithms", at: firstDate)
        let firstSaved = await model.apply(.addCourse(first), savedAt: firstDate)
        XCTAssertTrue(firstSaved)

        await backing.failNextReplace()
        let second = try makeCourse(
            name: "Databases",
            at: Date(timeIntervalSince1970: 200)
        )
        let secondSaved = await model.apply(
            .addCourse(second),
            savedAt: Date(timeIntervalSince1970: 200)
        )
        XCTAssertFalse(secondSaved)
        XCTAssertEqual(model.courses, [first])

        await backing.failNextRead()
        await model.retry()

        guard case .unavailable = model.availability else {
            return XCTFail("The retry read should remain academic-only.")
        }
        XCTAssertEqual(model.courses, [first])

        await model.retry()
        XCTAssertEqual(model.availability, .ready)
        XCTAssertEqual(model.courses, [first])
    }

    func testAddCapturePersistsTheExactStableItemAndSurvivesRelaunch() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        let capturedAt = Date(timeIntervalSince1970: 150)
        let capture = try makeCapture(
            idSeed: 10_001,
            rawText: "Review the proof after class.",
            capturedAt: capturedAt
        )

        let outcome = await model.addCapture(capture, savedAt: capturedAt)

        XCTAssertEqual(outcome, .inserted)
        XCTAssertEqual(model.workspace.captures, [capture])
        XCTAssertEqual(model.workspace.captures.first?.id, capture.id)
        XCTAssertEqual(model.availability, .ready)

        let relaunched = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await relaunched.load()

        XCTAssertEqual(relaunched.workspace.captures, [capture])
        XCTAssertEqual(relaunched.availability, .ready)
    }

    func testAddCaptureReturnsAlreadyPresentWithoutASecondMutation() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        let capturedAt = Date(timeIntervalSince1970: 160)
        let capture = try makeCapture(
            idSeed: 10_011,
            rawText: "The lecturer repeated this definition.",
            capturedAt: capturedAt
        )
        let initial = await model.addCapture(capture, savedAt: capturedAt)
        XCTAssertEqual(initial, .inserted)
        let attemptsAfterInsert = await backing.replaceAttemptCount()
        let revisionAfterInsert = model.workspace.revision

        let replay = await model.addCapture(capture, savedAt: capturedAt)

        XCTAssertEqual(replay, .alreadyPresent)
        let attemptsAfterReplay = await backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfterReplay, attemptsAfterInsert)
        XCTAssertEqual(model.workspace.revision, revisionAfterInsert)
        XCTAssertEqual(model.workspace.captures, [capture])
    }

    func testAddCaptureReplayUsesTheStoreCanonicalDateRepresentation() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        let capturedAt = Date(timeIntervalSince1970: 443_383_332.546_070_1)
        let capture = try makeCapture(
            idSeed: 10_016,
            rawText: "Replay after canonical date coding.",
            capturedAt: capturedAt
        )
        let initial = await model.addCapture(capture, savedAt: capturedAt)
        XCTAssertEqual(initial, .inserted)
        let attemptsAfterInsert = await backing.replaceAttemptCount()

        let replay = await model.addCapture(capture, savedAt: capturedAt)

        XCTAssertEqual(replay, .alreadyPresent)
        let attemptsAfterReplay = await backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfterReplay, attemptsAfterInsert)
        XCTAssertEqual(model.workspace.captures.count, 1)
        XCTAssertEqual(model.workspace.captures.first?.id, capture.id)
    }

    func testAddCaptureRejectsIdentifierConflictWithoutOverwriting() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        let capturedAt = Date(timeIntervalSince1970: 170)
        let original = try makeCapture(
            idSeed: 10_021,
            rawText: "Original marker",
            capturedAt: capturedAt
        )
        let conflicting = try makeCapture(
            idSeed: 10_021,
            rawText: "Conflicting replacement",
            capturedAt: capturedAt
        )
        let initial = await model.addCapture(original, savedAt: capturedAt)
        XCTAssertEqual(initial, .inserted)
        let attemptsAfterInsert = await backing.replaceAttemptCount()

        let outcome = await model.addCapture(conflicting, savedAt: capturedAt)

        XCTAssertEqual(outcome, .identifierConflict)
        let attemptsAfterConflict = await backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfterConflict, attemptsAfterInsert)
        XCTAssertEqual(model.workspace.captures, [original])
        XCTAssertEqual(model.availability, .ready)
    }

    func testAddCaptureReloadDetectsConcurrentIdentifierConflictWithoutOverwrite() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        let capturedAt = Date(timeIntervalSince1970: 175)
        let requested = try makeCapture(
            idSeed: 10_026,
            rawText: "Requested marker",
            capturedAt: capturedAt
        )
        let concurrentlySaved = try makeCapture(
            idSeed: 10_026,
            rawText: "Concurrent marker with the same identifier",
            capturedAt: capturedAt
        )
        await backing.pauseNextReplace()
        let saveTask = Task { @MainActor in
            await model.addCapture(requested, savedAt: capturedAt)
        }
        await backing.waitUntilReplaceIsPaused()

        let concurrentStore = NextStepAcademicStore(backing: backing)
        let concurrentSnapshot = try await concurrentStore.load()
        let concurrentContent = try AcademicWorkspaceCommand
            .addCapture(concurrentlySaved)
            .applying(to: concurrentSnapshot.workspace)
        _ = try await concurrentStore.commit(
            concurrentContent,
            expected: concurrentSnapshot.token,
            savedAt: capturedAt
        )
        await backing.resumePausedReplace()

        let outcome = await saveTask.value

        XCTAssertEqual(outcome, .identifierConflict)
        XCTAssertEqual(model.workspace.captures, [concurrentlySaved])
        XCTAssertFalse(model.workspace.captures.contains(requested))
        XCTAssertEqual(model.availability, .ready)
    }

    func testAddCapturePreflightRejectsInvalidRelationshipBeforeStoreMutation() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        let capturedAt = Date(timeIntervalSince1970: 180)
        let missingCourseCapture = try makeCapture(
            idSeed: 10_031,
            rawText: "Marker for a missing course",
            courseID: CourseID(academicUUID(10_032)),
            capturedAt: capturedAt
        )
        let attemptsBeforeSave = await backing.replaceAttemptCount()

        let outcome = await model.addCapture(
            missingCourseCapture,
            savedAt: capturedAt
        )

        guard case let .invalid(reason) = outcome else {
            return XCTFail("A missing Course relationship must fail preflight.")
        }
        XCTAssertFalse(reason.isEmpty)
        let attemptsAfterSave = await backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfterSave, attemptsBeforeSave)
        XCTAssertTrue(model.workspace.captures.isEmpty)
        XCTAssertEqual(model.availability, .ready)
    }

    func testAddCaptureRejectsNonFiniteSaveDateBeforeStoreMutation() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        let capturedAt = Date(timeIntervalSince1970: 185)
        let capture = try makeCapture(
            idSeed: 10_036,
            rawText: "Reject an invalid workspace timestamp.",
            capturedAt: capturedAt
        )
        let attemptsBeforeSave = await backing.replaceAttemptCount()

        let outcome = await model.addCapture(
            capture,
            savedAt: Date(timeIntervalSinceReferenceDate: .nan)
        )

        guard case let .invalid(reason) = outcome else {
            return XCTFail("A non-finite savedAt must fail before persistence.")
        }
        XCTAssertFalse(reason.isEmpty)
        let attemptsAfterSave = await backing.replaceAttemptCount()
        XCTAssertEqual(attemptsAfterSave, attemptsBeforeSave)
        XCTAssertTrue(model.workspace.captures.isEmpty)
        XCTAssertEqual(model.availability, .ready)
    }

    func testAddCaptureReconcilesACommitThatReportedFailure() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        let capturedAt = Date(timeIntervalSince1970: 190)
        let capture = try makeCapture(
            idSeed: 10_041,
            rawText: "Persist despite an ambiguous response.",
            capturedAt: capturedAt
        )
        await backing.failAfterCommittingNextReplace()

        let outcome = await model.addCapture(capture, savedAt: capturedAt)

        XCTAssertEqual(outcome, .inserted)
        let replaceAttempts = await backing.replaceAttemptCount()
        XCTAssertEqual(replaceAttempts, 1)
        XCTAssertEqual(model.workspace.captures, [capture])
        XCTAssertEqual(model.workspace.revision, 1)
        XCTAssertEqual(model.availability, .ready)
    }

    func testAddCaptureReloadsAndRetriesTheSameIdentifierAfterMissingCommit() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        let capturedAt = Date(timeIntervalSince1970: 200)
        let capture = try makeCapture(
            idSeed: 10_051,
            rawText: "Retry this exact marker.",
            capturedAt: capturedAt
        )
        await backing.failNextReplace()

        let outcome = await model.addCapture(capture, savedAt: capturedAt)

        XCTAssertEqual(outcome, .inserted)
        let replaceAttempts = await backing.replaceAttemptCount()
        XCTAssertEqual(replaceAttempts, 2)
        XCTAssertEqual(model.workspace.captures, [capture])
        XCTAssertEqual(model.workspace.captures.first?.id, capture.id)
        XCTAssertEqual(model.workspace.revision, 1)
        XCTAssertEqual(model.availability, .ready)
    }

    func testAddCaptureSettlesAnAmbiguousRecoveryRetryWithoutDuplication() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        let capturedAt = Date(timeIntervalSince1970: 210)
        let capture = try makeCapture(
            idSeed: 10_061,
            rawText: "The recovery write commits exactly once.",
            capturedAt: capturedAt
        )
        await backing.failNextReplace()
        await backing.failAfterCommittingNextReplace()

        let outcome = await model.addCapture(capture, savedAt: capturedAt)

        XCTAssertEqual(outcome, .inserted)
        let replaceAttempts = await backing.replaceAttemptCount()
        XCTAssertEqual(replaceAttempts, 2)
        XCTAssertEqual(model.workspace.captures, [capture])
        XCTAssertEqual(model.workspace.revision, 1)
        XCTAssertEqual(model.availability, .ready)
    }

    func testAddCaptureStopsAfterOneRecoveryWriteWhenBothAttemptsStayMissing() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        let capturedAt = Date(timeIntervalSince1970: 215)
        let capture = try makeCapture(
            idSeed: 10_066,
            rawText: "Do not loop or regenerate after repeated failure.",
            capturedAt: capturedAt
        )
        await backing.failNextReplaces(2)

        let outcome = await model.addCapture(capture, savedAt: capturedAt)

        XCTAssertEqual(outcome, .notReady)
        let replaceAttempts = await backing.replaceAttemptCount()
        XCTAssertEqual(replaceAttempts, 2)
        XCTAssertTrue(model.workspace.captures.isEmpty)
        guard case let .unavailable(failure) = model.availability else {
            return XCTFail("The bounded recovery failure must stay academic-only.")
        }
        XCTAssertEqual(failure.operation, .saveCapture)

        await model.retry()
        let retried = await model.addCapture(capture, savedAt: capturedAt)
        XCTAssertEqual(retried, .inserted)
        XCTAssertEqual(model.workspace.captures, [capture])
        XCTAssertEqual(model.workspace.captures.first?.id, capture.id)
    }

    func testAddCaptureReportsNotReadyAndAcademicFailureDoesNotEraseWorkspace() async throws {
        let backing = AcademicAppModelBacking()
        let idleModel = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        let capturedAt = Date(timeIntervalSince1970: 220)
        let capture = try makeCapture(
            idSeed: 10_071,
            rawText: "Wait for the academic workspace.",
            capturedAt: capturedAt
        )

        let idleOutcome = await idleModel.addCapture(
            capture,
            savedAt: capturedAt
        )
        XCTAssertEqual(idleOutcome, .notReady)
        XCTAssertEqual(idleModel.availability, .idle)
        let idleReplaceAttempts = await backing.replaceAttemptCount()
        XCTAssertEqual(idleReplaceAttempts, 0)

        await idleModel.load()
        let retained = try makeCapture(
            idSeed: 10_076,
            rawText: "Retain the last published academic snapshot.",
            capturedAt: Date(timeIntervalSince1970: 219)
        )
        let retainedOutcome = await idleModel.addCapture(
            retained,
            savedAt: retained.capturedAt
        )
        XCTAssertEqual(retainedOutcome, .inserted)
        await backing.failNextReplace()
        await backing.failNextRead()
        let failed = await idleModel.addCapture(capture, savedAt: capturedAt)

        XCTAssertEqual(failed, .notReady)
        XCTAssertEqual(idleModel.workspace.captures, [retained])
        guard case let .unavailable(failure) = idleModel.availability else {
            return XCTFail("Only the academic sidecar should become unavailable.")
        }
        XCTAssertEqual(failure.operation, .saveCapture)

        await idleModel.retry()
        XCTAssertEqual(idleModel.availability, .ready)
        XCTAssertEqual(idleModel.workspace.captures, [retained])
        let retried = await idleModel.addCapture(capture, savedAt: capturedAt)
        XCTAssertEqual(retried, .inserted)
        XCTAssertEqual(idleModel.workspace.captures, [capture, retained])
    }

    func testStartSessionCreatesExactLinkedTextNoteThenActivates() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        let courseDate = Date(timeIntervalSince1970: 100)
        let course = try makeCourse(name: "Biochemistry", at: courseDate)
        let addedCourse = await model.apply(.addCourse(course), savedAt: courseDate)
        XCTAssertTrue(addedCourse)

        let startedAt = Date(timeIntervalSince1970: 200)
        let outcome = await model.startSession(
            courseID: course.id,
            startedAt: startedAt,
            noteTitle: "Biochemistry class"
        ) { request in
            makeCreatedSessionNote(for: request)
        }

        guard case let .started(route) = outcome else {
            return XCTFail("Expected a fully linked active session.")
        }
        let session = try XCTUnwrap(model.workspace.sessions.first)
        let link = try XCTUnwrap(model.workspace.sessionNoteLinks.first)
        XCTAssertEqual(session.status, .active)
        XCTAssertEqual(session.actualStartedAt, startedAt)
        XCTAssertEqual(session.revision, 2)
        XCTAssertEqual(link.sessionID, session.id)
        XCTAssertEqual(link.noteID.rawValue, route.notebookID)
        XCTAssertEqual(link.initialPageID?.rawValue, route.initialPageID)
        XCTAssertEqual(model.sessionStartState, .idle)
        XCTAssertEqual(model.availability, .ready)
    }

    func testStartSessionHonorsPersistedTimestampAfterMillisecondRoundTrip() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        let courseDate = Date(timeIntervalSince1970: 100)
        let course = try makeCourse(name: "Biochemistry", at: courseDate)
        let addedCourse = await model.apply(.addCourse(course), savedAt: courseDate)
        XCTAssertTrue(addedCourse)

        // JSONEncoder's milliseconds strategy can decode this value one ULP
        // later than the in-memory Date used to create the planned session.
        let startedAt = Date(timeIntervalSince1970: 1_784_112_300.000_005)
        let outcome = await model.startSession(
            courseID: course.id,
            startedAt: startedAt,
            noteTitle: "Biochemistry class"
        ) { request in
            makeCreatedSessionNote(for: request)
        }

        guard case .started = outcome else {
            return XCTFail("A persisted timestamp must not make activation move backwards.")
        }
        let session = try XCTUnwrap(model.workspace.sessions.first)
        let actualStartedAt = try XCTUnwrap(session.actualStartedAt)
        XCTAssertEqual(session.status, .active)
        XCTAssertGreaterThanOrEqual(actualStartedAt, startedAt)
        XCTAssertLessThan(actualStartedAt.timeIntervalSince(startedAt), 0.001)
        XCTAssertEqual(model.sessionStartState, .idle)
        XCTAssertEqual(model.availability, .ready)
    }

    func testStartSessionRejectsASecondActiveSessionForTheCourse() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        let courseDate = Date(timeIntervalSince1970: 100)
        let course = try makeCourse(name: "Biochemistry", at: courseDate)
        let addedCourse = await model.apply(.addCourse(course), savedAt: courseDate)
        XCTAssertTrue(addedCourse)

        let first = await model.startSession(
            courseID: course.id,
            startedAt: Date(timeIntervalSince1970: 200),
            noteTitle: "Biochemistry class"
        ) { request in
            makeCreatedSessionNote(for: request)
        }
        guard case .started = first else {
            return XCTFail("The first class should start.")
        }

        let second = await model.startSession(
            courseID: course.id,
            startedAt: Date(timeIntervalSince1970: 300),
            noteTitle: "Duplicate class"
        ) { request in
            makeCreatedSessionNote(for: request)
        }

        guard case let .failed(failure) = second else {
            return XCTFail("A second active class must be rejected.")
        }
        XCTAssertEqual(failure.operation, .startSession)
        XCTAssertEqual(model.workspace.sessions.count, 1)
        XCTAssertEqual(model.workspace.sessionNoteLinks.count, 1)
        XCTAssertEqual(model.workspace.sessions.first?.status, .active)
        XCTAssertEqual(model.availability, .ready)
    }

    func testRootPreparationCannotInterruptSessionNoteCreation() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        let courseDate = Date(timeIntervalSince1970: 100)
        let course = try makeCourse(name: "Biochemistry", at: courseDate)
        let addedCourse = await model.apply(.addCourse(course), savedAt: courseDate)
        XCTAssertTrue(addedCourse)
        let gate = SessionNoteEnsureGate()

        let startTask = Task { @MainActor in
            await model.startSession(
                courseID: course.id,
                startedAt: Date(timeIntervalSince1970: 200),
                noteTitle: "Biochemistry class"
            ) { request in
                await gate.pause()
                return makeCreatedSessionNote(for: request)
            }
        }
        await gate.waitUntilPaused()

        XCTAssertEqual(
            model.sessionStartState,
            .working(courseID: course.id, progress: .creatingNote)
        )
        do {
            _ = try await model.prepareForLibraryRootTransition()
            XCTFail("Root preparation must wait for deterministic note creation.")
        } catch let error as AcademicLibraryRootCoordinationError {
            XCTAssertEqual(error, .operationInProgress)
        }

        await gate.resume()
        let outcome = await startTask.value
        guard case .started = outcome else {
            return XCTFail("The fenced Session start should finish normally.")
        }
        XCTAssertEqual(model.workspace.sessions.first?.status, .active)
        XCTAssertEqual(model.availability, .ready)
    }

    func testFailedNoteCreationSurvivesRelaunchAndRetriesSameIdentifiers() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        let courseDate = Date(timeIntervalSince1970: 100)
        let course = try makeCourse(name: "Biochemistry", at: courseDate)
        let addedCourse = await model.apply(.addCourse(course), savedAt: courseDate)
        XCTAssertTrue(addedCourse)

        let first = await model.startSession(
            courseID: course.id,
            startedAt: Date(timeIntervalSince1970: 200),
            noteTitle: "Biochemistry class"
        ) { _ in nil }
        guard case let .recoveryRequired(pending) = first else {
            return XCTFail("The planned session must remain recoverable.")
        }
        XCTAssertEqual(model.workspace.sessions.first?.status, .planned)
        XCTAssertEqual(model.pendingSessionStart, pending)

        let relaunched = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await relaunched.load()
        XCTAssertEqual(relaunched.pendingSessionStart, pending)

        let retry = await relaunched.retryPendingSessionStart(
            noteTitle: "Biochemistry class"
        ) { request in
            makeCreatedSessionNote(for: request)
        }
        guard case let .started(route) = retry else {
            return XCTFail("Retry should activate the same persisted session.")
        }
        XCTAssertEqual(route.sessionID, pending.session.id)
        XCTAssertEqual(route.notebookID, pending.link.noteID.rawValue)
        XCTAssertEqual(route.initialPageID, pending.link.initialPageID?.rawValue)
        XCTAssertEqual(relaunched.workspace.sessions.count, 1)
        XCTAssertEqual(relaunched.workspace.sessionNoteLinks.count, 1)
        XCTAssertEqual(relaunched.workspace.sessions.first?.status, .active)
    }

    func testStartReconcilesReplaceThatCommittedBeforeReportingFailure() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        let courseDate = Date(timeIntervalSince1970: 100)
        let course = try makeCourse(name: "Biochemistry", at: courseDate)
        let addedCourse = await model.apply(.addCourse(course), savedAt: courseDate)
        XCTAssertTrue(addedCourse)
        await backing.failAfterCommittingNextReplace()

        let startedAt = Date(timeIntervalSince1970: 1_784_112_300.000_005)
        let outcome = await model.startSession(
            courseID: course.id,
            startedAt: startedAt,
            noteTitle: "Biochemistry class"
        ) { request in
            makeCreatedSessionNote(for: request)
        }

        guard case .started = outcome else {
            return XCTFail("A committed unknown result must reconcile without duplication.")
        }
        XCTAssertEqual(model.workspace.sessions.count, 1)
        XCTAssertEqual(model.workspace.sessionNoteLinks.count, 1)
        XCTAssertEqual(model.workspace.sessions.first?.status, .active)
        XCTAssertEqual(model.workspace.revision, 3)
    }

    func testStartReconcilesFractionalActivationCommittedBeforeFailure() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        let courseDate = Date(timeIntervalSince1970: 100)
        let course = try makeCourse(name: "Biochemistry", at: courseDate)
        let addedCourse = await model.apply(.addCourse(course), savedAt: courseDate)
        XCTAssertTrue(addedCourse)

        let startedAt = Date(timeIntervalSince1970: 1_784_112_300.000_005)
        let outcome = await model.startSession(
            courseID: course.id,
            startedAt: startedAt,
            noteTitle: "Biochemistry class"
        ) { request in
            // The planned session is already canonical and saved. Fail only
            // after the following activation replace has committed.
            await backing.failAfterCommittingNextReplace()
            return makeCreatedSessionNote(for: request)
        }

        guard case .started = outcome else {
            return XCTFail("A committed activation must reconcile as active.")
        }
        let session = try XCTUnwrap(model.workspace.sessions.first)
        let actualStartedAt = try XCTUnwrap(session.actualStartedAt)
        XCTAssertEqual(session.status, .active)
        XCTAssertGreaterThanOrEqual(actualStartedAt, startedAt)
        XCTAssertLessThan(actualStartedAt.timeIntervalSince(startedAt), 0.001)
        XCTAssertEqual(model.workspace.sessions.count, 1)
        XCTAssertEqual(model.workspace.sessionNoteLinks.count, 1)
        XCTAssertEqual(model.workspace.revision, 3)
        XCTAssertEqual(model.sessionStartState, .idle)
        XCTAssertEqual(model.availability, .ready)
    }

    func testRootPreparationCannotInterruptAnActiveMutation() async throws {
        let backing = AcademicAppModelBacking()
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()

        let savedAt = Date(timeIntervalSince1970: 100)
        let course = try makeCourse(name: "Algorithms", at: savedAt)
        await backing.pauseNextReplace()
        let saveTask = Task { @MainActor in
            await model.apply(.addCourse(course), savedAt: savedAt)
        }
        await backing.waitUntilReplaceIsPaused()

        do {
            _ = try await model.prepareForLibraryRootTransition()
            XCTFail("Root preparation must not supersede an academic save.")
        } catch let error as AcademicLibraryRootCoordinationError {
            XCTAssertEqual(error, .operationInProgress)
        }
        XCTAssertEqual(model.availability, .saving)

        await backing.resumePausedReplace()
        let saved = await saveTask.value

        XCTAssertTrue(saved)
        XCTAssertEqual(model.availability, .ready)
        XCTAssertEqual(model.courses, [course])
    }

    func testCandidateWorkspaceIsNotPublishedUntilAccepted() async throws {
        let backing = AcademicAppModelBacking()
        let oldCourse = try await seedCourse(
            named: "Old Root",
            root: "old",
            savedAt: Date(timeIntervalSince1970: 100),
            backing: backing
        )
        let candidateCourse = try await seedCourse(
            named: "Candidate Root",
            root: "candidate",
            savedAt: Date(timeIntervalSince1970: 200),
            backing: backing
        )
        await backing.selectRoot("old")
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()
        XCTAssertEqual(model.courses, [oldCourse])

        let transition = try await model.prepareForLibraryRootTransition()
        XCTAssertEqual(model.availability, .changingLibraryRoot)
        XCTAssertTrue(model.courses.isEmpty)

        await backing.selectRoot("candidate")
        await model.resolveCandidateLibraryRoot(transition)

        XCTAssertEqual(model.availability, .changingLibraryRoot)
        XCTAssertTrue(
            model.courses.isEmpty,
            "A candidate must remain hidden until the Notes root is final."
        )

        model.acceptLibraryRootTransition(AcademicLibraryRootTransition())
        XCTAssertEqual(model.availability, .changingLibraryRoot)
        XCTAssertTrue(model.courses.isEmpty)

        model.acceptLibraryRootTransition(transition)

        XCTAssertEqual(model.availability, .ready)
        XCTAssertEqual(model.courses, [candidateCourse])

        model.acceptLibraryRootTransition(transition)
        XCTAssertEqual(model.availability, .ready)
        XCTAssertEqual(model.courses, [candidateCourse])
    }

    func testRollbackAfterResolvedCandidateReloadsRestoredOldRoot() async throws {
        let backing = AcademicAppModelBacking()
        let oldCourse = try await seedCourse(
            named: "Old Root",
            root: "old",
            savedAt: Date(timeIntervalSince1970: 100),
            backing: backing
        )
        _ = try await seedCourse(
            named: "Candidate Root",
            root: "candidate",
            savedAt: Date(timeIntervalSince1970: 200),
            backing: backing
        )
        await backing.selectRoot("old")
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()

        let transition = try await model.prepareForLibraryRootTransition()
        await backing.selectRoot("candidate")
        await model.resolveCandidateLibraryRoot(transition)

        // Notes restores its old route before asking the academic sidecar to
        // settle the rollback.
        await backing.selectRoot("old")
        await model.rollbackLibraryRootTransition(transition)

        XCTAssertEqual(model.availability, .ready)
        XCTAssertEqual(model.courses, [oldCourse])
    }

    func testFailedCandidateReadIsRetainedAndRetryPublishesSettledRoot() async throws {
        let backing = AcademicAppModelBacking()
        _ = try await seedCourse(
            named: "Old Root",
            root: "old",
            savedAt: Date(timeIntervalSince1970: 100),
            backing: backing
        )
        let candidateCourse = try await seedCourse(
            named: "Candidate Root",
            root: "candidate",
            savedAt: Date(timeIntervalSince1970: 200),
            backing: backing
        )
        await backing.selectRoot("old")
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()

        let transition = try await model.prepareForLibraryRootTransition()
        await backing.selectRoot("candidate")
        await backing.failNextRead()
        await model.resolveCandidateLibraryRoot(transition)
        model.acceptLibraryRootTransition(transition)

        guard case let .unavailable(failure) = model.availability else {
            return XCTFail("Expected the candidate read failure to stay academic-only.")
        }
        XCTAssertEqual(failure.operation, .resolveCandidateLibraryRoot)
        XCTAssertTrue(model.courses.isEmpty)

        await model.retry()

        XCTAssertEqual(model.availability, .ready)
        XCTAssertEqual(model.courses, [candidateCourse])
    }

    func testNextRootChangeReusesGateRetainedByAcceptedFailure() async throws {
        let backing = AcademicAppModelBacking()
        _ = try await seedCourse(
            named: "Old Root",
            root: "old",
            savedAt: Date(timeIntervalSince1970: 100),
            backing: backing
        )
        _ = try await seedCourse(
            named: "Failed Candidate",
            root: "failed",
            savedAt: Date(timeIntervalSince1970: 200),
            backing: backing
        )
        let finalCourse = try await seedCourse(
            named: "Final Root",
            root: "final",
            savedAt: Date(timeIntervalSince1970: 300),
            backing: backing
        )
        await backing.selectRoot("old")
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()

        let failedTransition = try await model.prepareForLibraryRootTransition()
        await backing.selectRoot("failed")
        await backing.failNextRead()
        await model.resolveCandidateLibraryRoot(failedTransition)
        model.acceptLibraryRootTransition(failedTransition)
        guard case .unavailable = model.availability else {
            return XCTFail("Expected a retained closed gate.")
        }

        let nextTransition = try await model.prepareForLibraryRootTransition()
        XCTAssertNotEqual(nextTransition, failedTransition)
        await backing.selectRoot("final")
        await model.resolveCandidateLibraryRoot(nextTransition)
        model.acceptLibraryRootTransition(nextTransition)

        XCTAssertEqual(model.availability, .ready)
        XCTAssertEqual(model.courses, [finalCourse])
    }

    func testRollbackAfterCandidateReadFailureReopensOldRootWithSameGate() async throws {
        let backing = AcademicAppModelBacking()
        let oldCourse = try await seedCourse(
            named: "Old Root",
            root: "old",
            savedAt: Date(timeIntervalSince1970: 100),
            backing: backing
        )
        _ = try await seedCourse(
            named: "Candidate Root",
            root: "candidate",
            savedAt: Date(timeIntervalSince1970: 200),
            backing: backing
        )
        await backing.selectRoot("old")
        let model = AcademicAppModel(
            store: NextStepAcademicStore(backing: backing)
        )
        await model.load()

        let transition = try await model.prepareForLibraryRootTransition()
        await backing.selectRoot("candidate")
        await backing.failNextRead()
        await model.resolveCandidateLibraryRoot(transition)

        await backing.selectRoot("old")
        await model.rollbackLibraryRootTransition(transition)

        XCTAssertEqual(model.availability, .ready)
        XCTAssertEqual(model.courses, [oldCourse])
    }

    private func seedCourse(
        named name: String,
        root: String,
        savedAt: Date,
        backing: AcademicAppModelBacking
    ) async throws -> Course {
        await backing.selectRoot(root)
        let store = NextStepAcademicStore(backing: backing)
        let initial = try await store.load()
        let course = try makeCourse(name: name, at: savedAt)
        _ = try await store.mutate(
            expected: initial.token,
            savedAt: savedAt
        ) { workspace in
            try AcademicWorkspaceCommand.addCourse(course).applying(to: workspace)
        }
        return course
    }

    private func makeCourse(name: String, at timestamp: Date) throws -> Course {
        try Course(
            name: name,
            timeZoneIdentifier: "UTC",
            createdAt: timestamp
        )
    }

    private func makeCapture(
        idSeed: Int,
        rawText: String,
        courseID: CourseID? = nil,
        capturedAt: Date
    ) throws -> CaptureItem {
        try CaptureItem.create(
            id: CaptureItemID(academicUUID(idSeed)),
            kind: .professorEmphasis,
            source: .quickCapture(try QuickCaptureReference()),
            courseID: courseID,
            rawText: rawText,
            draftFields: try CaptureDraftFields(),
            capturedAt: capturedAt,
            auditID: CaptureAuditEntryID(academicUUID(idSeed + 100_000))
        )
    }

    private func academicUUID(_ value: Int) -> UUID {
        let suffix = String(value)
        precondition(suffix.count <= 12)
        let padded = String(repeating: "0", count: 12 - suffix.count) + suffix
        return UUID(uuidString: "00000000-0000-0000-0000-\(padded)")!
    }
}

private actor AcademicAppModelBacking: AcademicWorkspaceFileBacking {
    private struct RootState {
        let rootFingerprint: AcademicWorkspaceStorageFingerprint
        var stateFingerprint: AcademicWorkspaceStateFingerprint
        var storageRevision: Int64
        var primary: Data?
        var backup: Data?
    }

    private var roots: [String: RootState]
    private var selectedRoot: String
    private var totalReadCount = 0
    private var shouldFailNextRead = false
    private var replaceFailuresRemaining = 0
    private var shouldFailAfterCommittingNextReplace = false
    private var shouldPauseNextReplace = false
    private var totalReplaceAttemptCount = 0
    private var pausedReplace: CheckedContinuation<Void, Never>?
    private var pausedReplaceObservers: [CheckedContinuation<Void, Never>] = []

    init(selectedRoot: String = "default") {
        self.selectedRoot = selectedRoot
        roots = [selectedRoot: Self.emptyRoot()]
    }

    func selectRoot(_ root: String) {
        if roots[root] == nil {
            roots[root] = Self.emptyRoot()
        }
        selectedRoot = root
    }

    func readCount() -> Int { totalReadCount }

    func replaceAttemptCount() -> Int { totalReplaceAttemptCount }

    func failNextRead() {
        shouldFailNextRead = true
    }

    func failNextReplace() {
        replaceFailuresRemaining += 1
    }

    func failNextReplaces(_ count: Int) {
        precondition(count >= 0)
        replaceFailuresRemaining += count
    }

    func failAfterCommittingNextReplace() {
        shouldFailAfterCommittingNextReplace = true
    }

    func pauseNextReplace() {
        shouldPauseNextReplace = true
    }

    func waitUntilReplaceIsPaused() async {
        if pausedReplace != nil { return }
        await withCheckedContinuation { continuation in
            pausedReplaceObservers.append(continuation)
        }
    }

    func resumePausedReplace() {
        let continuation = pausedReplace
        pausedReplace = nil
        continuation?.resume()
    }

    func read() async throws(AcademicWorkspaceFileBackingError)
        -> AcademicWorkspaceFileSnapshot {
        totalReadCount += 1
        if shouldFailNextRead {
            shouldFailNextRead = false
            throw .unavailable
        }
        return try snapshotForSelectedRoot()
    }

    func replace(
        primaryData: Data?,
        backupData: Data?,
        expected: AcademicWorkspaceStorageVersion
    ) async throws(AcademicWorkspaceFileBackingError)
        -> AcademicWorkspaceFileSnapshot {
        totalReplaceAttemptCount += 1
        if replaceFailuresRemaining > 0 {
            replaceFailuresRemaining -= 1
            throw .unavailable
        }
        if shouldPauseNextReplace {
            shouldPauseNextReplace = false
            await withCheckedContinuation { continuation in
                pausedReplace = continuation
                let observers = pausedReplaceObservers
                pausedReplaceObservers.removeAll()
                for observer in observers {
                    observer.resume()
                }
            }
        }
        guard var state = roots[selectedRoot] else { throw .unavailable }
        let currentVersion = try version(of: state)
        guard currentVersion == expected else { throw .conflict }
        let (nextRevision, overflow) = state.storageRevision.addingReportingOverflow(1)
        guard !overflow else { throw .storageRevisionOverflow }
        state.storageRevision = nextRevision
        state.stateFingerprint = AcademicWorkspaceStateFingerprint()
        state.primary = primaryData
        state.backup = backupData
        roots[selectedRoot] = state
        if shouldFailAfterCommittingNextReplace {
            shouldFailAfterCommittingNextReplace = false
            throw .unavailable
        }
        return try snapshot(of: state)
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

    private func snapshotForSelectedRoot()
        throws(AcademicWorkspaceFileBackingError) -> AcademicWorkspaceFileSnapshot {
        guard let state = roots[selectedRoot] else { throw .unavailable }
        return try snapshot(of: state)
    }

    private func snapshot(
        of state: RootState
    ) throws(AcademicWorkspaceFileBackingError) -> AcademicWorkspaceFileSnapshot {
        AcademicWorkspaceFileSnapshot(
            primary: slotValue(state.primary),
            backup: slotValue(state.backup),
            version: try version(of: state)
        )
    }

    private func version(
        of state: RootState
    ) throws(AcademicWorkspaceFileBackingError) -> AcademicWorkspaceStorageVersion {
        try AcademicWorkspaceStorageVersion(
            rootFingerprint: state.rootFingerprint,
            stateFingerprint: state.stateFingerprint,
            storageRevision: state.storageRevision
        )
    }

    private func slotValue(_ data: Data?) -> AcademicWorkspaceFileSlotValue {
        guard let data else { return .missing }
        guard data.count <= AcademicWorkspaceLimits.maximumEncodedBytes else {
            return .oversized
        }
        return .data(data)
    }

    private static func emptyRoot() -> RootState {
        RootState(
            rootFingerprint: AcademicWorkspaceStorageFingerprint(),
            stateFingerprint: AcademicWorkspaceStateFingerprint(),
            storageRevision: 0,
            primary: nil,
            backup: nil
        )
    }
}

private actor SessionNoteEnsureGate {
    private var isPaused = false
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    private var pauseObservers: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        await withCheckedContinuation { continuation in
            isPaused = true
            pauseContinuation = continuation
            let observers = pauseObservers
            pauseObservers.removeAll()
            for observer in observers {
                observer.resume()
            }
        }
    }

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { continuation in
            pauseObservers.append(continuation)
        }
    }

    func resume() {
        isPaused = false
        let continuation = pauseContinuation
        pauseContinuation = nil
        continuation?.resume()
    }
}

@MainActor
private func makeCreatedSessionNote(
    for request: SessionTextNoteRequest
) -> CreatedSessionTextNote {
    CreatedSessionTextNote(
        notebook: LibraryNotebook(
            id: request.notebookID,
            title: request.title,
            kind: .textDocument,
            createdAt: request.createdAt,
            modifiedAt: request.createdAt,
            isFavorite: false,
            deletedAt: nil,
            pageCount: 1,
            coverHue: 0.5
        ),
        initialPageID: request.initialPageID
    )
}
