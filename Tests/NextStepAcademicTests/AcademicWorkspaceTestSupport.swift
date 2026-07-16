import Foundation
import NotesCore
@testable import NextStepAcademic
import XCTest

func makeAcademicCourse(
    id: CourseID = testCourseID,
    name: String = "Distributed Systems"
) throws -> Course {
    try Course(
        id: id,
        name: name,
        timeZoneIdentifier: "Asia/Taipei",
        createdAt: testCreatedAt
    )
}

struct ReviewedAcademicFixture {
    let course: Course
    let activeSession: CourseSession
    let reviewedSession: CourseSession
    let link: SessionNoteLink
    let capture: CaptureItem
    let wrapUp: SessionWrapUp

    var content: AcademicWorkspaceContent {
        get throws {
            try AcademicWorkspaceContent(
                courses: [course],
                sessions: [reviewedSession],
                sessionNoteLinks: [link],
                captures: [capture],
                wrapUps: [wrapUp]
            )
        }
    }
}

func makeReviewedAcademicFixture(seed: Int = 500) throws -> ReviewedAcademicFixture {
    let course = try makeAcademicCourse()
    let activeSession = try makeActiveSession()
    let capture = try makeQuickCapture(
        idSeed: seed,
        kind: .professorEmphasis
    )
    let decision = try SessionWrapUpDecision(
        captureID: capture.id,
        expectedRevision: capture.revision,
        kind: .keepAsIs
    )
    let transaction = try SessionWrapUpTransaction(
        sessionID: activeSession.id,
        expectedSessionRevision: activeSession.revision,
        wrapUpID: SessionWrapUpID(testUUID(seed + 2)),
        startedAt: testStartedAt.addingTimeInterval(60),
        completedAt: testCompletedAt,
        oneLineSummary: "Reviewed the key lecture emphasis.",
        noNewActionsConfirmed: false,
        decisions: [decision]
    )
    let result = try transaction.applying(
        to: activeSession,
        captures: [capture]
    )
    let link = try SessionNoteLink(
        id: SessionNoteLinkID(testUUID(seed + 3)),
        sessionID: activeSession.id,
        noteID: NotebookID(testUUID(seed + 4)),
        initialPageID: PageID(testUUID(seed + 5)),
        linkedAt: testStartedAt
    )
    return ReviewedAcademicFixture(
        course: course,
        activeSession: activeSession,
        reviewedSession: result.session,
        link: link,
        capture: result.captures[0],
        wrapUp: result.wrapUp
    )
}

func encodeAcademicWorkspace(_ workspace: AcademicWorkspace) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(workspace)
}

actor ControlledAcademicWorkspaceBacking: AcademicWorkspaceFileBacking {
    private var snapshot: AcademicWorkspaceFileSnapshot
    private var replaceCalls = 0
    private var resetCalls = 0
    private var readCalls = 0
    private var nextReadError: AcademicWorkspaceFileBackingError?
    private var invalidNextReplacement = false
    private var preserveStateFingerprintOnNextReplacement = false
    private var changeRootFingerprintOnNextReplacement = false
    private var pauseNextRead = false
    private var pausedRead: CheckedContinuation<Void, Never>?
    private var pausedReadObservers: [CheckedContinuation<Void, Never>] = []

    init(snapshot: AcademicWorkspaceFileSnapshot) {
        self.snapshot = snapshot
    }

    func read() async throws(AcademicWorkspaceFileBackingError)
        -> AcademicWorkspaceFileSnapshot {
        readCalls += 1
        if let error = nextReadError {
            nextReadError = nil
            throw error
        }
        let captured = snapshot
        if pauseNextRead {
            pauseNextRead = false
            await withCheckedContinuation { continuation in
                pausedRead = continuation
                let observers = pausedReadObservers
                pausedReadObservers.removeAll()
                for observer in observers {
                    observer.resume()
                }
            }
        }
        return captured
    }

    func replace(
        primaryData: Data?,
        backupData: Data?,
        expected: AcademicWorkspaceStorageVersion
    ) async throws(AcademicWorkspaceFileBackingError) -> AcademicWorkspaceFileSnapshot {
        replaceCalls += 1
        guard expected == snapshot.version else {
            throw AcademicWorkspaceFileBackingError.conflict
        }
        let nextRevision = try advanceRevision(snapshot.version.storageRevision)
        if invalidNextReplacement {
            invalidNextReplacement = false
            return AcademicWorkspaceFileSnapshot(
                primary: .bounded(primaryData),
                backup: .bounded(backupData),
                version: snapshot.version
            )
        }
        let nextStateFingerprint: AcademicWorkspaceStateFingerprint
        if preserveStateFingerprintOnNextReplacement {
            preserveStateFingerprintOnNextReplacement = false
            nextStateFingerprint = snapshot.version.stateFingerprint
        } else {
            nextStateFingerprint = AcademicWorkspaceStateFingerprint()
        }
        let nextRootFingerprint: AcademicWorkspaceStorageFingerprint
        if changeRootFingerprintOnNextReplacement {
            changeRootFingerprintOnNextReplacement = false
            nextRootFingerprint = AcademicWorkspaceStorageFingerprint()
        } else {
            nextRootFingerprint = snapshot.version.rootFingerprint
        }
        snapshot = AcademicWorkspaceFileSnapshot(
            primary: .bounded(primaryData),
            backup: .bounded(backupData),
            version: try AcademicWorkspaceStorageVersion(
                rootFingerprint: nextRootFingerprint,
                stateFingerprint: nextStateFingerprint,
                storageRevision: nextRevision
            )
        )
        return snapshot
    }

    func reset(
        expected: AcademicWorkspaceStorageVersion
    ) async throws(AcademicWorkspaceFileBackingError) -> AcademicWorkspaceFileSnapshot {
        resetCalls += 1
        guard expected == snapshot.version else {
            throw AcademicWorkspaceFileBackingError.conflict
        }
        snapshot = AcademicWorkspaceFileSnapshot(
            primary: .missing,
            backup: .missing,
            version: try AcademicWorkspaceStorageVersion(
                rootFingerprint: snapshot.version.rootFingerprint,
                stateFingerprint: AcademicWorkspaceStateFingerprint(),
                storageRevision: try advanceRevision(snapshot.version.storageRevision)
            )
        )
        return snapshot
    }

    func currentSnapshot() -> AcademicWorkspaceFileSnapshot { snapshot }
    func replaceCallCount() -> Int { replaceCalls }
    func resetCallCount() -> Int { resetCalls }
    func readCallCount() -> Int { readCalls }

    func forceSnapshot(_ value: AcademicWorkspaceFileSnapshot) {
        snapshot = value
    }

    func failNextRead(with error: AcademicWorkspaceFileBackingError) {
        nextReadError = error
    }

    func returnInvalidNextReplacement() {
        invalidNextReplacement = true
    }

    func preserveStateFingerprintForNextReplacement() {
        preserveStateFingerprintOnNextReplacement = true
    }

    func changeRootFingerprintForNextReplacement() {
        changeRootFingerprintOnNextReplacement = true
    }

    func armReadPause() {
        pauseNextRead = true
    }

    func waitUntilReadIsPaused() async {
        if pausedRead != nil { return }
        await withCheckedContinuation { continuation in
            pausedReadObservers.append(continuation)
        }
    }

    func resumePausedRead() {
        let continuation = pausedRead
        pausedRead = nil
        continuation?.resume()
    }

    private func advanceRevision(
        _ revision: Int64
    ) throws(AcademicWorkspaceFileBackingError) -> Int64 {
        let (next, overflow) = revision.addingReportingOverflow(1)
        guard !overflow else {
            throw AcademicWorkspaceFileBackingError.storageRevisionOverflow
        }
        return next
    }
}

func makeBackingSnapshot(
    primaryData: Data? = nil,
    backupData: Data? = nil,
    primarySlot: AcademicWorkspaceFileSlotValue? = nil,
    backupSlot: AcademicWorkspaceFileSlotValue? = nil,
    fingerprintSeed: Int = 900,
    stateFingerprintSeed: Int? = nil,
    storageRevision: Int64 = 0
) throws -> AcademicWorkspaceFileSnapshot {
    AcademicWorkspaceFileSnapshot(
        primary: primarySlot ?? .bounded(primaryData),
        backup: backupSlot ?? .bounded(backupData),
        version: try AcademicWorkspaceStorageVersion(
            rootFingerprint: AcademicWorkspaceStorageFingerprint(testUUID(fingerprintSeed)),
            stateFingerprint: AcademicWorkspaceStateFingerprint(
                testUUID(stateFingerprintSeed ?? (fingerprintSeed + 10_000_000))
            ),
            storageRevision: storageRevision
        )
    )
}
