import Combine
import Foundation
import NextStepAcademic
import NotesCore

enum AcademicWorkspaceFailureOperation: String, Equatable, Sendable {
    case load
    case mutation
    case saveCapture
    case reviewCapture
    case endSession
    case completeWrapUp
    case startSession
    case createSessionNote
    case activateSession
    case reconcileSessionStart
    case prepareLibraryRootTransition
    case resolveCandidateLibraryRoot
    case rollbackLibraryRootTransition
    case rootTransitionContract
}

struct AcademicWorkspaceFailure: Identifiable, Equatable, Sendable {
    let id: UUID
    let operation: AcademicWorkspaceFailureOperation
    let message: String

    init(
        id: UUID = UUID(),
        operation: AcademicWorkspaceFailureOperation,
        message: String
    ) {
        self.id = id
        self.operation = operation
        self.message = message
    }
}

enum AcademicWorkspaceAvailability: Equatable, Sendable {
    case idle
    case loading
    case ready
    case saving
    case changingLibraryRoot
    case unavailable(AcademicWorkspaceFailure)
}

/// Effect-based result for one exact CaptureItem insertion.
///
/// `inserted` also covers a write whose success was proven by reconciliation
/// after the backing reported an ambiguous failure. `alreadyPresent` is
/// reserved for an exact value found before any write begins.
enum CaptureSaveOutcome: Equatable, Sendable {
    case inserted
    case alreadyPresent
    case identifierConflict
    case invalid(String)
    case notReady
}

/// Opaque app-layer capability bracketing one Notes library-root transition.
///
/// The underlying academic-store token deliberately does not cross into
/// `AppModel`; only `AcademicAppModel` can resolve or retain it.
struct AcademicLibraryRootTransition: Hashable, Sendable {
    fileprivate let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

enum AcademicLibraryRootCoordinationError: Error, Equatable, Sendable {
    case operationInProgress
    case rootTransitionInProgress
}

extension AcademicLibraryRootCoordinationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            String(localized: "Wait for the current academic workspace operation to finish.")
        case .rootTransitionInProgress:
            String(localized: "An academic library-root transition is already in progress.")
        }
    }
}

/// Minimal, non-throwing settlement boundary used by the Notes root saga.
///
/// `prepare` is the sole throwing step because Notes must not move its root
/// unless the academic gate is closed. Candidate resolution and rollback keep
/// failures inside `AcademicAppModel`, preserving the Notes result and error.
@MainActor
protocol AcademicLibraryRootCoordinating: AnyObject {
    func prepareForLibraryRootTransition() async throws
        -> AcademicLibraryRootTransition

    func resolveCandidateLibraryRoot(
        _ transition: AcademicLibraryRootTransition
    ) async

    func acceptLibraryRootTransition(
        _ transition: AcademicLibraryRootTransition
    )

    func rollbackLibraryRootTransition(
        _ transition: AcademicLibraryRootTransition
    ) async
}

/// Independent presentation state for the optional NextStep academic sidecar.
///
/// Academic failures are published only through `availability`; this model has
/// no reference to `AppModel` and therefore cannot block or overwrite the Notes
/// library's state or notice channel.
@MainActor
final class AcademicAppModel: ObservableObject, AcademicLibraryRootCoordinating {
    @Published private(set) var workspace: AcademicWorkspace = .empty
    @Published private(set) var availability: AcademicWorkspaceAvailability = .idle
    @Published private(set) var sessionStartState: SessionStartState = .idle

    var courses: [Course] { workspace.courses }

    var failure: AcademicWorkspaceFailure? {
        guard case let .unavailable(failure) = availability else { return nil }
        return failure
    }

    var pendingSessionStart: PendingSessionStart? {
        guard case let .recoveryRequired(pending, _) = sessionStartState else {
            return nil
        }
        return pending
    }

    private struct PendingRootTransition {
        var capability: AcademicLibraryRootTransition
        var storeToken: AcademicWorkspaceRootTransitionToken?
        var stagedCandidate: AcademicWorkspaceStoreSnapshot?
        var resolutionFailure: AcademicWorkspaceFailure?
        var externalRootIsSettled: Bool
    }

    private let store: NextStepAcademicStore
    private var publishedSnapshot: AcademicWorkspaceStoreSnapshot?
    private var pendingRootTransition: PendingRootTransition?
    private var activeOperationID: UUID?

    init(store: NextStepAcademicStore) {
        self.store = store
    }

    /// Idempotent launch load. Repeated view tasks do not refresh a ready model.
    func load() async {
        guard pendingRootTransition == nil,
              activeOperationID == nil else { return }
        switch availability {
        case .idle, .unavailable:
            await loadFreshWorkspace()
        case .loading, .ready, .saving, .changingLibraryRoot:
            return
        }
    }

    /// Retries either a retained root gate or a regular workspace load.
    func retry() async {
        guard activeOperationID == nil else { return }
        if let pendingRootTransition {
            guard pendingRootTransition.externalRootIsSettled else { return }
            await retrySettledRootTransition(pendingRootTransition.capability)
        } else {
            await loadFreshWorkspace()
        }
    }

    /// Applies one deterministic command using the published snapshot's CAS
    /// token. A failed save keeps the previously published workspace read-only.
    @discardableResult
    func apply(
        _ command: AcademicWorkspaceCommand,
        savedAt: Date = Date()
    ) async -> Bool {
        guard activeOperationID == nil,
              pendingRootTransition == nil,
              availability == .ready,
              let current = publishedSnapshot else { return false }

        let operationID = beginOperation()
        availability = .saving
        do {
            let next = try await store.mutate(
                expected: current.token,
                savedAt: savedAt
            ) { workspace in
                try command.applying(to: workspace)
            }
            guard activeOperationID == operationID else { return false }
            publish(next)
            finishOperation(operationID)
            return true
        } catch {
            guard activeOperationID == operationID else { return false }
            availability = .unavailable(
                failure(for: error, operation: .mutation)
            )
            finishOperation(operationID)
            return false
        }
    }

    /// Idempotently persists the exact CaptureItem supplied by the caller.
    ///
    /// The caller owns identifier creation. This operation never reconstructs
    /// the item, replaces an item sharing its identifier, or advances Notes
    /// state. A failed backing operation is treated as ambiguous until a fresh
    /// load proves whether the exact item committed; one missing result is
    /// retried with the same value and identifier.
    func addCapture(
        _ capture: CaptureItem,
        savedAt requestedSavedAt: Date = Date()
    ) async -> CaptureSaveOutcome {
        guard activeOperationID == nil,
              pendingRootTransition == nil,
              availability == .ready,
              let current = publishedSnapshot else {
            return .notReady
        }

        switch capturePersistence(of: capture, in: current.workspace) {
        case .exact:
            return .alreadyPresent
        case .conflict:
            return .identifierConflict
        case .missing:
            break
        }

        guard requestedSavedAt.timeIntervalSinceReferenceDate.isFinite else {
            return .invalid(
                AcademicDomainError.invalidField("captureSave.savedAt")
                    .localizedDescription
            )
        }

        let command = AcademicWorkspaceCommand.addCapture(capture)
        let content: AcademicWorkspaceContent
        do {
            // Validate every workspace relationship before opening a store
            // mutation. Invalid input must never reach the file backing.
            content = try command.applying(to: current.workspace)
        } catch {
            return .invalid(error.localizedDescription)
        }

        let operationID = beginOperation()
        defer { finishOperation(operationID) }
        availability = .saving
        do {
            let inserted = try await store.commit(
                content,
                expected: current.token,
                savedAt: captureSaveDate(
                    requestedSavedAt,
                    capture: capture,
                    workspace: current.workspace
                )
            )
            guard activeOperationID == operationID else { return .notReady }
            publish(inserted)
            return .inserted
        } catch {
            guard activeOperationID == operationID else { return .notReady }
            return await reconcileCaptureSave(
                capture,
                requestedSavedAt: requestedSavedAt,
                operationID: operationID
            )
        }
    }

    /// Idempotently persists one exact Candidate Review pre/post-image pair.
    ///
    /// The mutation owns its complete expected CaptureItem, deterministic
    /// resulting CaptureItem, timestamp, and audit identifiers. Reconciliation
    /// may retry that same canonical mutation once when only the workspace CAS
    /// token changed; any target CaptureItem drift stops without overwriting it.
    /// A linked session may advance from `active` to `needsReview`, but reaching
    /// any other state (or disappearing) permanently fences the review.
    func reviewCapture(
        _ mutation: CaptureReviewMutation,
        savedAt requestedSavedAt: Date = Date()
    ) async -> CandidateReviewSaveOutcome {
        guard activeOperationID == nil,
              pendingRootTransition == nil,
              availability == .ready,
              let current = publishedSnapshot else {
            return .notReady
        }

        guard requestedSavedAt.timeIntervalSinceReferenceDate.isFinite,
              let stableSavedAt: Date = canonicalValue(requestedSavedAt) else {
            return .invalid(
                AcademicDomainError.invalidField("captureReview.savedAt")
                    .localizedDescription
            )
        }

        let stableMutation: CaptureReviewMutation
        do {
            stableMutation = try canonicalCandidateReviewMutation(mutation)
        } catch {
            return .invalid(error.localizedDescription)
        }

        do {
            switch try candidateReviewPersistence(
                of: stableMutation,
                in: current.workspace
            ) {
            case let .postImage(capture):
                return .alreadyApplied(capture)
            case let .conflict(capture):
                return .revisionConflict(capture)
            case .missing:
                return .missing
            case .expectedImage:
                break
            }
        } catch {
            return .invalid(error.localizedDescription)
        }

        let effect: CandidateReviewEffect
        do {
            effect = try makeCandidateReviewEffect(
                stableMutation,
                in: current.workspace
            )
        } catch {
            return .invalid(error.localizedDescription)
        }

        let operationID = beginOperation()
        defer { finishOperation(operationID) }
        availability = .saving
        do {
            let applied = try await store.commit(
                effect.content,
                expected: current.token,
                savedAt: candidateReviewSaveDate(
                    stableSavedAt,
                    mutation: stableMutation,
                    workspace: current.workspace
                )
            )
            guard activeOperationID == operationID else { return .notReady }
            return publishAppliedCandidateReview(
                applied,
                mutation: stableMutation
            )
        } catch {
            guard activeOperationID == operationID else { return .notReady }
            return await reconcileCandidateReview(
                stableMutation,
                requestedSavedAt: stableSavedAt,
                operationID: operationID
            )
        }
    }

    /// Idempotently moves one exact active session into `needsReview`.
    ///
    /// This is intentionally separate from generic `apply`: ending a session
    /// is a recovery boundary. A store error is ambiguous until a fresh load
    /// proves whether the exact end effect committed, and only one recovery
    /// write is permitted with the caller's original revision and timestamp.
    func endSession(
        _ request: SessionEndRequest,
        savedAt requestedSavedAt: Date = Date()
    ) async -> SessionEndOutcome {
        guard activeOperationID == nil,
              pendingRootTransition == nil,
              availability == .ready,
              let current = publishedSnapshot else {
            return .notReady
        }

        guard request.expectedRevision > 0 else {
            return .invalid(
                AcademicDomainError.valueOutOfBounds(
                    field: "sessionEnd.expectedRevision"
                ).localizedDescription
            )
        }
        guard request.endedAt.timeIntervalSinceReferenceDate.isFinite,
              requestedSavedAt.timeIntervalSinceReferenceDate.isFinite,
              let stableEndedAt: Date = canonicalValue(request.endedAt),
              let stableSavedAt: Date = canonicalValue(requestedSavedAt) else {
            return .invalid(
                AcademicDomainError.invalidField("sessionEnd.timestamp")
                    .localizedDescription
            )
        }
        let stableRequest = SessionEndRequest(
            sessionID: request.sessionID,
            expectedRevision: request.expectedRevision,
            endedAt: stableEndedAt
        )

        switch sessionEndPersistence(of: stableRequest, in: current.workspace) {
        case .exact:
            return .alreadyEnded
        case .conflict:
            return .conflict
        case .missing:
            return .invalid(
                AcademicDomainError.missingEntity(
                    entity: "course session",
                    identifier: stableRequest.sessionID.description
                ).localizedDescription
            )
        case .pending:
            break
        }

        let effect: SessionEndEffect
        do {
            effect = try makeSessionEndEffect(
                stableRequest,
                in: current.workspace
            )
        } catch {
            return sessionEndPreflightOutcome(for: error)
        }

        let operationID = beginOperation()
        defer { finishOperation(operationID) }
        availability = .saving
        do {
            let ended = try await store.commit(
                effect.content,
                expected: current.token,
                savedAt: sessionEndSaveDate(
                    stableSavedAt,
                    request: stableRequest,
                    workspace: current.workspace
                )
            )
            guard activeOperationID == operationID else { return .notReady }
            publish(ended)
            return .ended
        } catch {
            guard activeOperationID == operationID else { return .notReady }
            return await reconcileSessionEnd(
                stableRequest,
                expectedEffect: effect,
                requestedSavedAt: stableSavedAt,
                operationID: operationID
            )
        }
    }

    /// Idempotently commits an exact, atomic session wrap-up transaction.
    ///
    /// The transaction owns its wrap-up identifier, completion timestamp, all
    /// capture revisions, and every audit identifier. Reconciliation therefore
    /// never regenerates a decision or applies it to a newer capture revision.
    func completeWrapUp(
        _ transaction: SessionWrapUpTransaction,
        savedAt requestedSavedAt: Date = Date()
    ) async -> SessionWrapUpSaveOutcome {
        guard activeOperationID == nil,
              pendingRootTransition == nil,
              availability == .ready,
              let current = publishedSnapshot else {
            return .notReady
        }

        guard transaction.startedAt.timeIntervalSinceReferenceDate.isFinite,
              transaction.completedAt.timeIntervalSinceReferenceDate.isFinite,
              requestedSavedAt.timeIntervalSinceReferenceDate.isFinite,
              let stableTransaction: SessionWrapUpTransaction = canonicalValue(
                  transaction
              ),
              let stableSavedAt: Date = canonicalValue(requestedSavedAt) else {
            return .invalid(
                AcademicDomainError.invalidField("sessionWrapUp.timestamp")
                    .localizedDescription
            )
        }

        switch wrapUpPersistence(of: stableTransaction, in: current.workspace) {
        case .exact:
            return .alreadyCompleted
        case .conflict:
            return .conflict
        case .missing:
            break
        }

        let effect: SessionWrapUpEffect
        do {
            effect = try makeSessionWrapUpEffect(
                stableTransaction,
                in: current.workspace
            )
        } catch {
            return wrapUpPreflightOutcome(for: error)
        }

        let operationID = beginOperation()
        defer { finishOperation(operationID) }
        availability = .saving
        do {
            let completed = try await store.commit(
                effect.content,
                expected: current.token,
                savedAt: wrapUpSaveDate(
                    stableSavedAt,
                    transaction: stableTransaction,
                    workspace: current.workspace
                )
            )
            guard activeOperationID == operationID else { return .notReady }
            publish(completed)
            return .completed
        } catch {
            guard activeOperationID == operationID else { return .notReady }
            return await reconcileSessionWrapUp(
                stableTransaction,
                expectedEffect: effect,
                requestedSavedAt: stableSavedAt,
                operationID: operationID
            )
        }
    }

    /// Starts a recoverable CourseSession → Note saga without ever creating
    /// an unreferenced note. The planned session and typed note link are saved
    /// first; the exact note IDs are then created idempotently; only then does
    /// the session transition to active.
    func startSession(
        courseID: CourseID,
        topic: String? = nil,
        startedAt: Date = Date(),
        noteTitle: String,
        ensureNote: @escaping SessionTextNoteEnsurer
    ) async -> SessionStartOutcome {
        guard activeOperationID == nil,
              pendingRootTransition == nil,
              availability == .ready,
              sessionStartState == .idle,
              let current = publishedSnapshot else {
            let failure = AcademicWorkspaceFailure(
                operation: .startSession,
                message: String(
                    localized: "Wait for the academic workspace to finish its current operation."
                )
            )
            return .failed(failure)
        }
        guard current.workspace.courses.contains(where: {
            $0.id == courseID && $0.status == .active
        }) else {
            let failure = AcademicWorkspaceFailure(
                operation: .startSession,
                message: String(localized: "This course is no longer active.")
            )
            return .failed(failure)
        }
        guard !current.workspace.sessions.contains(where: {
            $0.courseID == courseID && $0.status == .active
        }) else {
            let failure = AcademicWorkspaceFailure(
                operation: .startSession,
                message: String(localized: "Resume the class already in progress.")
            )
            return .failed(failure)
        }

        let pending: PendingSessionStart
        do {
            let session = try CourseSession(
                courseID: courseID,
                actualStartedAt: nil,
                actualEndedAt: nil,
                topic: topic,
                status: .planned,
                createdAt: startedAt,
                modifiedAt: startedAt
            )
            let link = try SessionNoteLink(
                sessionID: session.id,
                noteID: NotebookID(),
                initialPageID: PageID(),
                linkedAt: startedAt
            )
            pending = PendingSessionStart(session: session, link: link)
        } catch {
            let failure = failure(for: error, operation: .startSession)
            availability = .unavailable(failure)
            return .failed(failure)
        }

        let operationID = beginOperation()
        defer { finishOperation(operationID) }
        sessionStartState = .working(
            courseID: courseID,
            progress: .preparingSession
        )
        availability = .saving

        let plannedSnapshot: AcademicWorkspaceStoreSnapshot
        do {
            let command = AcademicWorkspaceCommand.addSessionWithNoteLink(
                session: pending.session,
                link: pending.link
            )
            plannedSnapshot = try await store.mutate(
                expected: current.token,
                savedAt: max(current.workspace.savedAt, startedAt)
            ) { workspace in
                try command.applying(to: workspace)
            }
        } catch {
            guard activeOperationID == operationID else {
                return .failed(failure(for: error, operation: .startSession))
            }
            return await reconcileUncertainSessionStart(
                pending,
                noteTitle: noteTitle,
                ensureNote: ensureNote,
                operationID: operationID,
                originalFailure: failure(for: error, operation: .startSession)
            )
        }

        guard activeOperationID == operationID else {
            let failure = AcademicWorkspaceFailure(
                operation: .startSession,
                message: String(localized: "The session start operation is no longer current.")
            )
            return .failed(failure)
        }
        publish(plannedSnapshot, detectingPendingSessionStart: false)
        return await ensureNoteAndActivate(
            pending,
            from: plannedSnapshot,
            noteTitle: noteTitle,
            ensureNote: ensureNote,
            operationID: operationID
        )
    }

    /// Resumes either an in-memory failure or a planned session/link recovered
    /// from disk after process relaunch. Missing state is inserted only after a
    /// fresh read proves the original CAS did not commit.
    func retryPendingSessionStart(
        noteTitle: String,
        ensureNote: @escaping SessionTextNoteEnsurer
    ) async -> SessionStartOutcome {
        guard activeOperationID == nil,
              pendingRootTransition == nil,
              let pending = pendingSessionStart else {
            let failure = AcademicWorkspaceFailure(
                operation: .reconcileSessionStart,
                message: String(localized: "There is no class session waiting for recovery.")
            )
            return .failed(failure)
        }

        let operationID = beginOperation()
        defer { finishOperation(operationID) }
        sessionStartState = .working(
            courseID: pending.courseID,
            progress: .preparingSession
        )
        availability = .saving

        let loaded: AcademicWorkspaceStoreSnapshot
        do {
            loaded = try await store.load()
        } catch {
            let failure = failure(for: error, operation: .reconcileSessionStart)
            availability = .unavailable(failure)
            sessionStartState = .recoveryRequired(pending, failure)
            return .recoveryRequired(pending)
        }
        guard activeOperationID == operationID else {
            return .failed(
                AcademicWorkspaceFailure(
                    operation: .reconcileSessionStart,
                    message: String(localized: "The session recovery is no longer current.")
                )
            )
        }

        switch persistence(of: pending, in: loaded.workspace) {
        case .planned:
            publish(loaded, detectingPendingSessionStart: false)
            return await ensureNoteAndActivate(
                pending,
                from: loaded,
                noteTitle: noteTitle,
                ensureNote: ensureNote,
                operationID: operationID
            )
        case .active:
            publish(loaded, detectingPendingSessionStart: false)
            return await ensureNoteForAlreadyActiveSession(
                pending,
                from: loaded,
                noteTitle: noteTitle,
                ensureNote: ensureNote,
                operationID: operationID
            )
        case .missing:
            do {
                let command = AcademicWorkspaceCommand.addSessionWithNoteLink(
                    session: pending.session,
                    link: pending.link
                )
                let inserted = try await store.mutate(
                    expected: loaded.token,
                    savedAt: max(loaded.workspace.savedAt, pending.session.createdAt)
                ) { workspace in
                    try command.applying(to: workspace)
                }
                publish(inserted, detectingPendingSessionStart: false)
                return await ensureNoteAndActivate(
                    pending,
                    from: inserted,
                    noteTitle: noteTitle,
                    ensureNote: ensureNote,
                    operationID: operationID
                )
            } catch {
                return await reconcileUncertainSessionStart(
                    pending,
                    noteTitle: noteTitle,
                    ensureNote: ensureNote,
                    operationID: operationID,
                    originalFailure: failure(
                        for: error,
                        operation: .reconcileSessionStart
                    )
                )
            }
        case .conflict:
            let failure = AcademicWorkspaceFailure(
                operation: .reconcileSessionStart,
                message: String(
                    localized: "The saved class session does not match its recovery record. No note was changed."
                )
            )
            publish(loaded, detectingPendingSessionStart: false)
            sessionStartState = .recoveryRequired(pending, failure)
            return .recoveryRequired(pending)
        }
    }

    func prepareForLibraryRootTransition() async throws
        -> AcademicLibraryRootTransition {
        guard activeOperationID == nil else {
            throw AcademicLibraryRootCoordinationError.operationInProgress
        }

        let capability = AcademicLibraryRootTransition()
        if var pending = pendingRootTransition {
            // A prior candidate was accepted while its academic read failed.
            // Reuse its still-closed gate. The nil-token branch is a defensive
            // recovery for a previous compensating rollback whose fresh
            // prepare failed before it could retain a token.
            guard pending.externalRootIsSettled,
                  pending.stagedCandidate == nil else {
                throw AcademicLibraryRootCoordinationError.rootTransitionInProgress
            }
            if pending.storeToken == nil {
                let operationID = beginOperation()
                do {
                    pending.storeToken = try await store.prepareForRootTransition()
                    finishOperation(operationID)
                } catch {
                    if activeOperationID == operationID {
                        availability = .unavailable(
                            failure(
                                for: error,
                                operation: .prepareLibraryRootTransition
                            )
                        )
                        finishOperation(operationID)
                    }
                    throw error
                }
            }
            pending.capability = capability
            pending.resolutionFailure = nil
            pending.externalRootIsSettled = false
            pendingRootTransition = pending
            clearPublishedWorkspace()
            availability = .changingLibraryRoot
            return capability
        }

        let operationID = beginOperation()
        do {
            let token = try await store.prepareForRootTransition()
            guard activeOperationID == operationID else {
                throw AcademicLibraryRootCoordinationError.operationInProgress
            }
            pendingRootTransition = PendingRootTransition(
                capability: capability,
                storeToken: token,
                stagedCandidate: nil,
                resolutionFailure: nil,
                externalRootIsSettled: false
            )
            clearPublishedWorkspace()
            availability = .changingLibraryRoot
            finishOperation(operationID)
            return capability
        } catch {
            if activeOperationID == operationID {
                availability = .unavailable(
                    failure(for: error, operation: .prepareLibraryRootTransition)
                )
                finishOperation(operationID)
            }
            throw error
        }
    }

    func resolveCandidateLibraryRoot(
        _ transition: AcademicLibraryRootTransition
    ) async {
        guard activeOperationID == nil,
              var pending = pendingRootTransition,
              pending.capability == transition,
              !pending.externalRootIsSettled,
              pending.stagedCandidate == nil,
              let token = pending.storeToken else {
            recordRootContractFailure(for: transition)
            return
        }

        let operationID = beginOperation()
        do {
            let candidate = try await store.finishRootTransition(token)
            guard activeOperationID == operationID,
                  pendingRootTransition?.capability == transition else { return }
            pending.storeToken = nil
            pending.stagedCandidate = candidate
            pending.resolutionFailure = nil
            pendingRootTransition = pending
        } catch {
            guard activeOperationID == operationID,
                  pendingRootTransition?.capability == transition else { return }
            pending.resolutionFailure = failure(
                for: error,
                operation: .resolveCandidateLibraryRoot
            )
            pendingRootTransition = pending
        }
        finishOperation(operationID)
    }

    func acceptLibraryRootTransition(
        _ transition: AcademicLibraryRootTransition
    ) {
        guard activeOperationID == nil,
              var pending = pendingRootTransition,
              pending.capability == transition else {
            recordRootContractFailure(for: transition)
            return
        }

        if let candidate = pending.stagedCandidate {
            pendingRootTransition = nil
            publish(candidate)
            return
        }

        pending.externalRootIsSettled = true
        let failure = pending.resolutionFailure ?? AcademicWorkspaceFailure(
            operation: .rootTransitionContract,
            message: String(
                localized: "The academic candidate root was not resolved before acceptance."
            )
        )
        pending.resolutionFailure = failure
        pendingRootTransition = pending
        clearPublishedWorkspace()
        availability = .unavailable(failure)
    }

    func rollbackLibraryRootTransition(
        _ transition: AcademicLibraryRootTransition
    ) async {
        guard activeOperationID == nil,
              var pending = pendingRootTransition,
              pending.capability == transition else {
            recordRootContractFailure(for: transition)
            return
        }

        let operationID = beginOperation()
        availability = .changingLibraryRoot
        pending.stagedCandidate = nil
        pending.externalRootIsSettled = true

        do {
            let token: AcademicWorkspaceRootTransitionToken
            if let retainedToken = pending.storeToken {
                token = retainedToken
            } else {
                // Candidate resolution consumed the original token. If Notes
                // nevertheless rolls back, close a fresh gate against the now
                // restored route before loading the old root.
                token = try await store.prepareForRootTransition()
                pending.storeToken = token
            }
            let restored = try await store.finishRootTransition(token)
            guard activeOperationID == operationID,
                  pendingRootTransition?.capability == transition else { return }
            pendingRootTransition = nil
            publish(restored)
        } catch {
            guard activeOperationID == operationID,
                  pendingRootTransition?.capability == transition else { return }
            let rootFailure = failure(
                for: error,
                operation: .rollbackLibraryRootTransition
            )
            pending.resolutionFailure = rootFailure
            pendingRootTransition = pending
            clearPublishedWorkspace()
            availability = .unavailable(rootFailure)
        }
        finishOperation(operationID)
    }

    private func loadFreshWorkspace() async {
        guard activeOperationID == nil,
              pendingRootTransition == nil else { return }
        let operationID = beginOperation()
        // A retry after a failed academic-only write keeps the last proven
        // snapshot visible but read-only while the backing is reloaded. This
        // preserves exact retry values owned by presented review flows. An
        // initial load still begins from the empty workspace.
        if publishedSnapshot == nil {
            clearPublishedWorkspace()
        }
        availability = .loading
        do {
            let snapshot = try await store.load()
            guard activeOperationID == operationID else { return }
            publish(snapshot)
        } catch {
            guard activeOperationID == operationID else { return }
            availability = .unavailable(failure(for: error, operation: .load))
        }
        finishOperation(operationID)
    }

    private func retrySettledRootTransition(
        _ transition: AcademicLibraryRootTransition
    ) async {
        guard activeOperationID == nil,
              var pending = pendingRootTransition,
              pending.capability == transition,
              pending.externalRootIsSettled,
              pending.stagedCandidate == nil else { return }

        let operationID = beginOperation()
        availability = .changingLibraryRoot
        do {
            let token: AcademicWorkspaceRootTransitionToken
            if let retainedToken = pending.storeToken {
                token = retainedToken
            } else {
                token = try await store.prepareForRootTransition()
                pending.storeToken = token
            }
            let snapshot = try await store.finishRootTransition(token)
            guard activeOperationID == operationID,
                  pendingRootTransition?.capability == transition else { return }
            pendingRootTransition = nil
            publish(snapshot)
        } catch {
            guard activeOperationID == operationID,
                  pendingRootTransition?.capability == transition else { return }
            let rootFailure = failure(
                for: error,
                operation: .resolveCandidateLibraryRoot
            )
            pending.resolutionFailure = rootFailure
            pendingRootTransition = pending
            clearPublishedWorkspace()
            availability = .unavailable(rootFailure)
        }
        finishOperation(operationID)
    }

    private enum SessionEndPersistence: Equatable {
        case pending
        case missing
        case exact
        case conflict
    }

    private struct SessionEndEffect {
        let content: AcademicWorkspaceContent
        let session: CourseSession
    }

    private func sessionEndPersistence(
        of request: SessionEndRequest,
        in workspace: AcademicWorkspace
    ) -> SessionEndPersistence {
        guard let session = workspace.sessions.first(where: {
            $0.id == request.sessionID
        }) else {
            return .missing
        }
        if sessionEndWasApplied(request, to: session) {
            return .exact
        }
        guard session.status == .active,
              session.revision == request.expectedRevision else {
            return .conflict
        }
        return .pending
    }

    private func sessionEndWasApplied(
        _ request: SessionEndRequest,
        to session: CourseSession
    ) -> Bool {
        let (endedRevision, endedOverflow) = request.expectedRevision
            .addingReportingOverflow(1)
        guard !endedOverflow,
              let actualEndedAt = session.actualEndedAt,
              canonicallyEqual(actualEndedAt, request.endedAt) else {
            return false
        }
        switch session.status {
        case .needsReview:
            return session.revision == endedRevision
                && canonicallyEqual(session.modifiedAt, request.endedAt)
        case .reviewed:
            let (reviewedRevision, reviewedOverflow) = endedRevision
                .addingReportingOverflow(1)
            return session.revision == endedRevision
                || (!reviewedOverflow && session.revision == reviewedRevision)
        case .planned, .active, .cancelled:
            return false
        }
    }

    private func makeSessionEndEffect(
        _ request: SessionEndRequest,
        in workspace: AcademicWorkspace
    ) throws -> SessionEndEffect {
        let content = try AcademicWorkspaceCommand.transitionSession(
            id: request.sessionID,
            expectedRevision: request.expectedRevision,
            to: .needsReview,
            at: request.endedAt
        ).applying(to: workspace)
        guard let session = content.sessions.first(where: {
            $0.id == request.sessionID
        }) else {
            throw AcademicDomainError.missingEntity(
                entity: "course session",
                identifier: request.sessionID.description
            )
        }
        return SessionEndEffect(content: content, session: session)
    }

    private func sessionEndEffectPersistence(
        _ expected: SessionEndEffect,
        request: SessionEndRequest,
        in workspace: AcademicWorkspace
    ) -> SessionEndPersistence {
        guard let session = workspace.sessions.first(where: {
            $0.id == request.sessionID
        }) else {
            return .missing
        }
        if canonicallyEqual(session, expected.session)
            || sessionIsReviewedAfterEnd(session, expected: expected.session) {
            return .exact
        }
        guard sessionEndPersistence(of: request, in: workspace) == .pending,
              let retried = try? makeSessionEndEffect(request, in: workspace),
              canonicallyEqual(retried.session, expected.session) else {
            return .conflict
        }
        return .pending
    }

    private func sessionIsReviewedAfterEnd(
        _ session: CourseSession,
        expected ended: CourseSession
    ) -> Bool {
        let (reviewedRevision, overflow) = ended.revision.addingReportingOverflow(1)
        return !overflow
            && session.id == ended.id
            && session.courseID == ended.courseID
            && session.status == .reviewed
            && session.revision == reviewedRevision
            && canonicallyEqual(session.actualStartedAt, ended.actualStartedAt)
            && canonicallyEqual(session.actualEndedAt, ended.actualEndedAt)
            && (session.modifiedAt >= ended.modifiedAt
                || canonicallyEqual(session.modifiedAt, ended.modifiedAt))
    }

    private func sessionEndSaveDate(
        _ requested: Date,
        request: SessionEndRequest,
        workspace: AcademicWorkspace
    ) -> Date {
        max(workspace.savedAt, max(request.endedAt, requested))
    }

    private func sessionEndPreflightOutcome(
        for error: any Error
    ) -> SessionEndOutcome {
        guard let domain = error as? AcademicDomainError else {
            return .invalid(error.localizedDescription)
        }
        switch domain {
        case .revisionConflict, .invalidStateTransition:
            return .conflict
        default:
            return .invalid(domain.localizedDescription)
        }
    }

    private func reconcileSessionEnd(
        _ request: SessionEndRequest,
        expectedEffect: SessionEndEffect,
        requestedSavedAt: Date,
        operationID: UUID
    ) async -> SessionEndOutcome {
        let loaded: AcademicWorkspaceStoreSnapshot
        do {
            loaded = try await store.load()
        } catch {
            guard activeOperationID == operationID else { return .notReady }
            availability = .unavailable(
                failure(for: error, operation: .endSession)
            )
            return .notReady
        }
        guard activeOperationID == operationID else { return .notReady }

        switch sessionEndEffectPersistence(
            expectedEffect,
            request: request,
            in: loaded.workspace
        ) {
        case .exact:
            publish(loaded)
            return .ended
        case .conflict:
            publish(loaded)
            return .conflict
        case .missing:
            publish(loaded)
            return .invalid(
                AcademicDomainError.missingEntity(
                    entity: "course session",
                    identifier: request.sessionID.description
                ).localizedDescription
            )
        case .pending:
            break
        }

        let retriedEffect: SessionEndEffect
        do {
            retriedEffect = try makeSessionEndEffect(request, in: loaded.workspace)
        } catch {
            publish(loaded)
            return sessionEndPreflightOutcome(for: error)
        }
        guard canonicallyEqual(retriedEffect.session, expectedEffect.session) else {
            publish(loaded)
            return .conflict
        }

        availability = .saving
        do {
            let ended = try await store.commit(
                retriedEffect.content,
                expected: loaded.token,
                savedAt: sessionEndSaveDate(
                    requestedSavedAt,
                    request: request,
                    workspace: loaded.workspace
                )
            )
            guard activeOperationID == operationID else { return .notReady }
            publish(ended)
            return .ended
        } catch {
            guard activeOperationID == operationID else { return .notReady }
            return await settleRetriedSessionEnd(
                request,
                expectedEffect: expectedEffect,
                operationID: operationID,
                retryError: error
            )
        }
    }

    private func settleRetriedSessionEnd(
        _ request: SessionEndRequest,
        expectedEffect: SessionEndEffect,
        operationID: UUID,
        retryError: any Error
    ) async -> SessionEndOutcome {
        let loaded: AcademicWorkspaceStoreSnapshot
        do {
            loaded = try await store.load()
        } catch {
            guard activeOperationID == operationID else { return .notReady }
            availability = .unavailable(
                failure(for: error, operation: .endSession)
            )
            return .notReady
        }
        guard activeOperationID == operationID else { return .notReady }

        switch sessionEndEffectPersistence(
            expectedEffect,
            request: request,
            in: loaded.workspace
        ) {
        case .exact:
            publish(loaded)
            return .ended
        case .conflict:
            publish(loaded)
            return .conflict
        case .missing:
            publish(loaded)
            return .invalid(
                AcademicDomainError.missingEntity(
                    entity: "course session",
                    identifier: request.sessionID.description
                ).localizedDescription
            )
        case .pending:
            break
        }

        publish(loaded)
        availability = .unavailable(
            failure(for: retryError, operation: .endSession)
        )
        return .notReady
    }

    private enum WrapUpPersistence: Equatable {
        case missing
        case exact
        case conflict
    }

    private struct SessionWrapUpEffect {
        let content: AcademicWorkspaceContent
        let session: CourseSession
        let captures: [CaptureItem]
        let wrapUp: SessionWrapUp
    }

    private func wrapUpPersistence(
        of transaction: SessionWrapUpTransaction,
        in workspace: AcademicWorkspace
    ) -> WrapUpPersistence {
        guard let existing = workspace.wrapUps.first(where: {
            $0.id == transaction.wrapUpID
        }) else {
            if workspace.wrapUps.contains(where: {
                $0.sessionID == transaction.sessionID
            }) || workspace.sessions.first(where: {
                $0.id == transaction.sessionID
            })?.status == .reviewed {
                return .conflict
            }
            return .missing
        }
        guard wrapUpReplayMatches(
            transaction,
            existing: existing,
            in: workspace
        ) else {
            return .conflict
        }
        return .exact
    }

    private func wrapUpReplayMatches(
        _ transaction: SessionWrapUpTransaction,
        existing: SessionWrapUp,
        in workspace: AcademicWorkspace
    ) -> Bool {
        guard let expectedWrapUp = try? requestedWrapUp(transaction),
              canonicallyEqual(existing, expectedWrapUp),
              let session = workspace.sessions.first(where: {
                  $0.id == transaction.sessionID
              }) else {
            return false
        }
        let (reviewedRevision, overflow) = transaction.expectedSessionRevision
            .addingReportingOverflow(1)
        guard !overflow,
              session.status == .reviewed,
              session.revision == reviewedRevision,
              canonicallyEqual(session.modifiedAt, transaction.completedAt),
              session.actualEndedAt != nil else {
            return false
        }
        return transaction.decisions.allSatisfy { decision in
            guard let capture = workspace.captures.first(where: {
                $0.id == decision.captureID
                    && $0.sessionID == transaction.sessionID
            }) else {
                return false
            }
            return wrapUpDecisionWasApplied(
                decision,
                to: capture,
                completedAt: transaction.completedAt
            )
        }
    }

    private func wrapUpDecisionWasApplied(
        _ decision: SessionWrapUpDecision,
        to capture: CaptureItem,
        completedAt: Date
    ) -> Bool {
        let auditCount = decision.auditIDs.count
        let (nextRevision, overflow) = decision.expectedRevision
            .addingReportingOverflow(Int64(auditCount))
        guard !overflow, capture.revision == nextRevision else { return false }
        if let fields = decision.draftFields,
           !canonicallyEqual(capture.draftFields, fields) {
            return false
        }
        if auditCount > 0 {
            let suffix = capture.auditTrail.suffix(auditCount)
            guard suffix.map(\.id) == decision.auditIDs,
                  suffix.allSatisfy({
                      canonicallyEqual($0.occurredAt, completedAt)
                  }),
                  canonicallyEqual(capture.modifiedAt, completedAt) else {
                return false
            }
        }
        switch decision.kind {
        case .keepAsIs:
            return auditCount == 0 && capture.state != .resolved
        case .markNeedsDetails:
            return auditCount == 1 && capture.state == .needsDetails
        case .markReadyToConfirm:
            return (1 ... 2).contains(auditCount)
                && capture.state == .readyToConfirm
        case .reject:
            guard let resolution = capture.resolution else { return false }
            return auditCount == 1
                && capture.state == .resolved
                && resolution.kind == .rejected
                && resolution.reason == decision.rejectionReason
                && canonicallyEqual(resolution.resolvedAt, completedAt)
        }
    }

    private func requestedWrapUp(
        _ transaction: SessionWrapUpTransaction
    ) throws -> SessionWrapUp {
        try SessionWrapUp(
            id: transaction.wrapUpID,
            sessionID: transaction.sessionID,
            startedAt: transaction.startedAt,
            completedAt: transaction.completedAt,
            oneLineSummary: transaction.oneLineSummary,
            noNewActionsConfirmed: transaction.noNewActionsConfirmed,
            reviewedCaptureIDs: transaction.decisions.map(\.captureID)
        )
    }

    private func makeSessionWrapUpEffect(
        _ transaction: SessionWrapUpTransaction,
        in workspace: AcademicWorkspace
    ) throws -> SessionWrapUpEffect {
        let content = try AcademicWorkspaceCommand.applyWrapUp(transaction)
            .applying(to: workspace)
        guard let session = content.sessions.first(where: {
            $0.id == transaction.sessionID
        }), let wrapUp = content.wrapUps.first(where: {
            $0.id == transaction.wrapUpID
        }) else {
            throw AcademicDomainError.missingEntity(
                entity: "session wrap-up effect",
                identifier: transaction.wrapUpID.description
            )
        }
        let captures = content.captures
            .filter { $0.sessionID == transaction.sessionID }
            .sorted { $0.id < $1.id }
        return SessionWrapUpEffect(
            content: content,
            session: session,
            captures: captures,
            wrapUp: wrapUp
        )
    }

    private func wrapUpEffectPersistence(
        _ expected: SessionWrapUpEffect,
        transaction: SessionWrapUpTransaction,
        in workspace: AcademicWorkspace
    ) -> WrapUpPersistence {
        if let existingWrapUp = workspace.wrapUps.first(where: {
            $0.id == transaction.wrapUpID
        }) {
            guard canonicallyEqual(existingWrapUp, expected.wrapUp),
                  let session = workspace.sessions.first(where: {
                      $0.id == transaction.sessionID
                  }),
                  canonicallyEqual(session, expected.session) else {
                return .conflict
            }
            let captures = workspace.captures
                .filter { $0.sessionID == transaction.sessionID }
                .sorted { $0.id < $1.id }
            return canonicallyEqual(captures, expected.captures)
                ? .exact
                : .conflict
        }
        guard wrapUpPersistence(of: transaction, in: workspace) == .missing,
              let retried = try? makeSessionWrapUpEffect(
                  transaction,
                  in: workspace
              ),
              sessionWrapUpEffectsEqual(retried, expected) else {
            return .conflict
        }
        return .missing
    }

    private func sessionWrapUpEffectsEqual(
        _ lhs: SessionWrapUpEffect,
        _ rhs: SessionWrapUpEffect
    ) -> Bool {
        canonicallyEqual(lhs.session, rhs.session)
            && canonicallyEqual(lhs.captures, rhs.captures)
            && canonicallyEqual(lhs.wrapUp, rhs.wrapUp)
    }

    private func wrapUpSaveDate(
        _ requested: Date,
        transaction: SessionWrapUpTransaction,
        workspace: AcademicWorkspace
    ) -> Date {
        max(workspace.savedAt, max(transaction.completedAt, requested))
    }

    private func wrapUpPreflightOutcome(
        for error: any Error
    ) -> SessionWrapUpSaveOutcome {
        guard let domain = error as? AcademicDomainError else {
            return .invalid(error.localizedDescription)
        }
        switch domain {
        case .revisionConflict, .invalidStateTransition, .duplicateIdentifier,
             .missingEntity, .relationshipMismatch:
            return .conflict
        default:
            return .invalid(domain.localizedDescription)
        }
    }

    private func reconcileSessionWrapUp(
        _ transaction: SessionWrapUpTransaction,
        expectedEffect: SessionWrapUpEffect,
        requestedSavedAt: Date,
        operationID: UUID
    ) async -> SessionWrapUpSaveOutcome {
        let loaded: AcademicWorkspaceStoreSnapshot
        do {
            loaded = try await store.load()
        } catch {
            guard activeOperationID == operationID else { return .notReady }
            availability = .unavailable(
                failure(for: error, operation: .completeWrapUp)
            )
            return .notReady
        }
        guard activeOperationID == operationID else { return .notReady }

        switch wrapUpEffectPersistence(
            expectedEffect,
            transaction: transaction,
            in: loaded.workspace
        ) {
        case .exact:
            publish(loaded)
            return .completed
        case .conflict:
            publish(loaded)
            return .conflict
        case .missing:
            break
        }

        let retriedEffect: SessionWrapUpEffect
        do {
            retriedEffect = try makeSessionWrapUpEffect(
                transaction,
                in: loaded.workspace
            )
        } catch {
            publish(loaded)
            return wrapUpPreflightOutcome(for: error)
        }
        guard sessionWrapUpEffectsEqual(retriedEffect, expectedEffect) else {
            publish(loaded)
            return .conflict
        }

        availability = .saving
        do {
            let completed = try await store.commit(
                retriedEffect.content,
                expected: loaded.token,
                savedAt: wrapUpSaveDate(
                    requestedSavedAt,
                    transaction: transaction,
                    workspace: loaded.workspace
                )
            )
            guard activeOperationID == operationID else { return .notReady }
            publish(completed)
            return .completed
        } catch {
            guard activeOperationID == operationID else { return .notReady }
            return await settleRetriedSessionWrapUp(
                transaction,
                expectedEffect: expectedEffect,
                operationID: operationID,
                retryError: error
            )
        }
    }

    private func settleRetriedSessionWrapUp(
        _ transaction: SessionWrapUpTransaction,
        expectedEffect: SessionWrapUpEffect,
        operationID: UUID,
        retryError: any Error
    ) async -> SessionWrapUpSaveOutcome {
        let loaded: AcademicWorkspaceStoreSnapshot
        do {
            loaded = try await store.load()
        } catch {
            guard activeOperationID == operationID else { return .notReady }
            availability = .unavailable(
                failure(for: error, operation: .completeWrapUp)
            )
            return .notReady
        }
        guard activeOperationID == operationID else { return .notReady }

        switch wrapUpEffectPersistence(
            expectedEffect,
            transaction: transaction,
            in: loaded.workspace
        ) {
        case .exact:
            publish(loaded)
            return .completed
        case .conflict:
            publish(loaded)
            return .conflict
        case .missing:
            break
        }

        publish(loaded)
        availability = .unavailable(
            failure(for: retryError, operation: .completeWrapUp)
        )
        return .notReady
    }

    private func canonicalValue<Value: Codable>(
        _ value: Value
    ) -> Value? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(Value.self, from: data)
    }

    private func canonicallyEqual<Value: Codable & Equatable>(
        _ lhs: Value,
        _ rhs: Value
    ) -> Bool {
        guard let left = canonicalValue(lhs),
              let right = canonicalValue(rhs) else {
            return false
        }
        return left == right
    }

    private enum CandidateReviewPersistence {
        case expectedImage
        case postImage(CaptureItem)
        case conflict(CaptureItem)
        case missing
    }

    private struct CandidateReviewEffect {
        let content: AcademicWorkspaceContent
    }

    private func canonicalCandidateReviewMutation(
        _ mutation: CaptureReviewMutation
    ) throws -> CaptureReviewMutation {
        guard let expectedCapture = canonicalCapture(
            mutation.expectedCapture
        ), let resultingCapture = canonicalCapture(
            mutation.resultingCapture
        ), let intent = canonicalCandidateReviewIntent(mutation.intent) else {
            throw AcademicDomainError.invalidField(
                "captureReview.canonicalMutation"
            )
        }
        let canonicalMutation = try CaptureReviewMutation(
            base: expectedCapture,
            intent: intent
        )
        guard canonicalMutation.resultingCapture == resultingCapture else {
            throw AcademicDomainError.relationshipMismatch(
                "A canonical Candidate Review mutation must retain its exact post-image."
            )
        }
        return canonicalMutation
    }

    private func canonicalCandidateReviewIntent(
        _ intent: CaptureReviewIntent
    ) -> CaptureReviewIntent? {
        guard let occurredAt: Date = canonicalValue(intent.occurredAt) else {
            return nil
        }
        switch intent {
        case let .saveDraft(fields, _, auditID):
            return .saveDraft(
                fields: fields,
                occurredAt: occurredAt,
                auditID: auditID
            )
        case let .markNeedsDetails(fields, _, auditID):
            return .markNeedsDetails(
                fields: fields,
                occurredAt: occurredAt,
                auditID: auditID
            )
        case let .markReadyToConfirm(fields, _, auditIDs):
            return .markReadyToConfirm(
                fields: fields,
                occurredAt: occurredAt,
                auditIDs: auditIDs
            )
        case let .reject(reason, _, auditID):
            return .reject(
                reason: reason,
                occurredAt: occurredAt,
                auditID: auditID
            )
        }
    }

    private func candidateReviewPersistence(
        of mutation: CaptureReviewMutation,
        in workspace: AcademicWorkspace
    ) throws -> CandidateReviewPersistence {
        let existing = workspace.captures.first(where: {
            $0.id == mutation.captureID
        })
        let canonicalExisting: CaptureItem?
        if let existing {
            guard let canonical = canonicalCapture(existing) else {
                throw AcademicDomainError.invalidField(
                    "captureReview.currentCapture"
                )
            }
            canonicalExisting = canonical
            // A durable exact post-image remains idempotent even after its
            // session advances to reviewed. The status gate below only fences
            // writes; it must not turn a completed effect into a false conflict.
            if canonical == mutation.resultingCapture {
                return .postImage(existing)
            }
        } else {
            canonicalExisting = nil
        }
        if let sessionID = mutation.expectedCapture.sessionID {
            guard let session = workspace.sessions.first(where: {
                $0.id == sessionID
            }), session.status == .active
                || session.status == .needsReview else {
                // Candidate Review must never reopen a completed or cancelled
                // class. When the session and its captures were removed
                // together, retain the caller's exact pre-image as the typed
                // conflict payload instead of treating the operation as a
                // sessionless missing CaptureItem.
                return .conflict(existing ?? mutation.expectedCapture)
            }
        }
        guard let existing else {
            return .missing
        }
        guard let canonicalExisting else { return .missing }
        if canonicalExisting == mutation.expectedCapture {
            return .expectedImage
        }
        return .conflict(existing)
    }

    private func makeCandidateReviewEffect(
        _ mutation: CaptureReviewMutation,
        in workspace: AcademicWorkspace
    ) throws -> CandidateReviewEffect {
        let content = try AcademicWorkspaceCommand
            .applyCaptureReview(mutation)
            .applying(to: workspace)
        guard let resultingCapture = content.captures.first(where: {
            $0.id == mutation.captureID
        }), resultingCapture == mutation.resultingCapture else {
            throw AcademicDomainError.relationshipMismatch(
                "A Candidate Review command must produce its stored post-image."
            )
        }
        return CandidateReviewEffect(content: content)
    }

    private func candidateReviewSaveDate(
        _ requested: Date,
        mutation: CaptureReviewMutation,
        workspace: AcademicWorkspace
    ) -> Date {
        max(
            workspace.savedAt,
            max(mutation.resultingCapture.modifiedAt, requested)
        )
    }

    private func publishAppliedCandidateReview(
        _ snapshot: AcademicWorkspaceStoreSnapshot,
        mutation: CaptureReviewMutation
    ) -> CandidateReviewSaveOutcome {
        let persistence: CandidateReviewPersistence
        do {
            persistence = try candidateReviewPersistence(
                of: mutation,
                in: snapshot.workspace
            )
        } catch {
            publish(snapshot)
            return .invalid(error.localizedDescription)
        }
        publish(snapshot)
        switch persistence {
        case let .postImage(capture):
            return .applied(capture)
        case let .conflict(capture):
            return .revisionConflict(capture)
        case .missing:
            return .missing
        case .expectedImage:
            availability = .unavailable(
                failure(
                    for: AcademicDomainError.relationshipMismatch(
                        "The Candidate Review store commit did not publish its post-image."
                    ),
                    operation: .reviewCapture
                )
            )
            return .notReady
        }
    }

    private func reconcileCandidateReview(
        _ mutation: CaptureReviewMutation,
        requestedSavedAt: Date,
        operationID: UUID
    ) async -> CandidateReviewSaveOutcome {
        let loaded: AcademicWorkspaceStoreSnapshot
        do {
            loaded = try await store.load()
        } catch {
            guard activeOperationID == operationID else { return .notReady }
            availability = .unavailable(
                failure(for: error, operation: .reviewCapture)
            )
            return .notReady
        }
        guard activeOperationID == operationID else { return .notReady }

        let persistence: CandidateReviewPersistence
        do {
            persistence = try candidateReviewPersistence(
                of: mutation,
                in: loaded.workspace
            )
        } catch {
            publish(loaded)
            return .invalid(error.localizedDescription)
        }
        switch persistence {
        case let .postImage(capture):
            publish(loaded)
            return .applied(capture)
        case let .conflict(capture):
            publish(loaded)
            return .revisionConflict(capture)
        case .missing:
            publish(loaded)
            return .missing
        case .expectedImage:
            break
        }

        let effect: CandidateReviewEffect
        do {
            effect = try makeCandidateReviewEffect(
                mutation,
                in: loaded.workspace
            )
        } catch {
            publish(loaded)
            return .invalid(error.localizedDescription)
        }

        availability = .saving
        do {
            let applied = try await store.commit(
                effect.content,
                expected: loaded.token,
                savedAt: candidateReviewSaveDate(
                    requestedSavedAt,
                    mutation: mutation,
                    workspace: loaded.workspace
                )
            )
            guard activeOperationID == operationID else { return .notReady }
            return publishAppliedCandidateReview(
                applied,
                mutation: mutation
            )
        } catch {
            guard activeOperationID == operationID else { return .notReady }
            return await settleRetriedCandidateReview(
                mutation,
                operationID: operationID,
                retryError: error
            )
        }
    }

    private func settleRetriedCandidateReview(
        _ mutation: CaptureReviewMutation,
        operationID: UUID,
        retryError: any Error
    ) async -> CandidateReviewSaveOutcome {
        let loaded: AcademicWorkspaceStoreSnapshot
        do {
            loaded = try await store.load()
        } catch {
            guard activeOperationID == operationID else { return .notReady }
            availability = .unavailable(
                failure(for: error, operation: .reviewCapture)
            )
            return .notReady
        }
        guard activeOperationID == operationID else { return .notReady }

        let persistence: CandidateReviewPersistence
        do {
            persistence = try candidateReviewPersistence(
                of: mutation,
                in: loaded.workspace
            )
        } catch {
            publish(loaded)
            return .invalid(error.localizedDescription)
        }
        switch persistence {
        case let .postImage(capture):
            publish(loaded)
            return .applied(capture)
        case let .conflict(capture):
            publish(loaded)
            return .revisionConflict(capture)
        case .missing:
            publish(loaded)
            return .missing
        case .expectedImage:
            break
        }

        do {
            _ = try makeCandidateReviewEffect(
                mutation,
                in: loaded.workspace
            )
        } catch {
            publish(loaded)
            return .invalid(error.localizedDescription)
        }

        publish(loaded)
        availability = .unavailable(
            failure(for: retryError, operation: .reviewCapture)
        )
        return .notReady
    }

    private enum CapturePersistence {
        case missing
        case exact
        case conflict
    }

    private func capturePersistence(
        of capture: CaptureItem,
        in workspace: AcademicWorkspace
    ) -> CapturePersistence {
        guard let existing = workspace.captures.first(where: {
            $0.id == capture.id
        }) else {
            return .missing
        }
        if existing == capture {
            return .exact
        }
        // The store publishes its canonical JSON round-trip. Compare that
        // representation as well so Date floating-point normalization cannot
        // turn a replay of the same item into a false identifier conflict.
        guard let canonicalExisting = canonicalCapture(existing),
              let canonicalRequested = canonicalCapture(capture) else {
            return .conflict
        }
        return canonicalExisting == canonicalRequested ? .exact : .conflict
    }

    private func canonicalCapture(_ capture: CaptureItem) -> CaptureItem? {
        canonicalValue(capture)
    }

    private func captureSaveDate(
        _ requested: Date,
        capture: CaptureItem,
        workspace: AcademicWorkspace
    ) -> Date {
        max(workspace.savedAt, max(capture.modifiedAt, requested))
    }

    private func reconcileCaptureSave(
        _ capture: CaptureItem,
        requestedSavedAt: Date,
        operationID: UUID
    ) async -> CaptureSaveOutcome {
        let loaded: AcademicWorkspaceStoreSnapshot
        do {
            loaded = try await store.load()
        } catch {
            guard activeOperationID == operationID else { return .notReady }
            availability = .unavailable(
                failure(for: error, operation: .saveCapture)
            )
            return .notReady
        }
        guard activeOperationID == operationID else { return .notReady }

        switch capturePersistence(of: capture, in: loaded.workspace) {
        case .exact:
            publish(loaded)
            return .inserted
        case .conflict:
            publish(loaded)
            return .identifierConflict
        case .missing:
            break
        }

        let command = AcademicWorkspaceCommand.addCapture(capture)
        let content: AcademicWorkspaceContent
        do {
            // The freshly loaded workspace can differ from the published one.
            // Preflight again before the single recovery write.
            content = try command.applying(to: loaded.workspace)
        } catch {
            publish(loaded)
            return .invalid(error.localizedDescription)
        }

        availability = .saving
        do {
            let inserted = try await store.commit(
                content,
                expected: loaded.token,
                savedAt: captureSaveDate(
                    requestedSavedAt,
                    capture: capture,
                    workspace: loaded.workspace
                )
            )
            guard activeOperationID == operationID else { return .notReady }
            publish(inserted)
            return .inserted
        } catch {
            guard activeOperationID == operationID else { return .notReady }
            return await settleRetriedCaptureSave(
                capture,
                operationID: operationID,
                retryError: error
            )
        }
    }

    private func settleRetriedCaptureSave(
        _ capture: CaptureItem,
        operationID: UUID,
        retryError: any Error
    ) async -> CaptureSaveOutcome {
        let loaded: AcademicWorkspaceStoreSnapshot
        do {
            loaded = try await store.load()
        } catch {
            guard activeOperationID == operationID else { return .notReady }
            availability = .unavailable(
                failure(for: error, operation: .saveCapture)
            )
            return .notReady
        }
        guard activeOperationID == operationID else { return .notReady }

        switch capturePersistence(of: capture, in: loaded.workspace) {
        case .exact:
            publish(loaded)
            return .inserted
        case .conflict:
            publish(loaded)
            return .identifierConflict
        case .missing:
            break
        }

        do {
            // Distinguish a relationship that became invalid while retrying
            // from a still-valid value whose durable state remains missing.
            _ = try AcademicWorkspaceCommand.addCapture(capture)
                .applying(to: loaded.workspace)
        } catch {
            publish(loaded)
            return .invalid(error.localizedDescription)
        }

        publish(loaded)
        availability = .unavailable(
            failure(for: retryError, operation: .saveCapture)
        )
        return .notReady
    }

    private enum PendingSessionPersistence {
        case missing
        case planned
        case active
        case conflict
    }

    private func ensureNoteAndActivate(
        _ pending: PendingSessionStart,
        from plannedSnapshot: AcademicWorkspaceStoreSnapshot,
        noteTitle: String,
        ensureNote: SessionTextNoteEnsurer,
        operationID: UUID
    ) async -> SessionStartOutcome {
        guard let request = pending.noteRequest(title: noteTitle),
              let route = pending.route else {
            let failure = AcademicWorkspaceFailure(
                operation: .reconcileSessionStart,
                message: String(
                    localized: "The class session is missing its initial note page reference."
                )
            )
            return retainSessionStartRecovery(
                pending,
                failure: failure,
                snapshot: plannedSnapshot
            )
        }
        guard let persistedSession = plannedSnapshot.workspace.sessions.first(where: {
            $0.id == pending.session.id
        }) else {
            let failure = AcademicWorkspaceFailure(
                operation: .reconcileSessionStart,
                message: String(
                    localized: "The saved class session does not match its recovery record. No note was changed."
                )
            )
            return retainSessionStartRecovery(
                pending,
                failure: failure,
                snapshot: plannedSnapshot
            )
        }

        sessionStartState = .working(
            courseID: pending.courseID,
            progress: .creatingNote
        )
        availability = .saving
        let created = await ensureNote(request)
        guard activeOperationID == operationID else {
            let failure = AcademicWorkspaceFailure(
                operation: .createSessionNote,
                message: String(localized: "The note creation result arrived too late.")
            )
            return retainSessionStartRecovery(
                pending,
                failure: failure,
                snapshot: plannedSnapshot
            )
        }
        guard let created,
              created.notebook.id == request.notebookID,
              created.initialPageID == request.initialPageID,
              created.notebook.kind == .textDocument else {
            let failure = AcademicWorkspaceFailure(
                operation: .createSessionNote,
                message: String(
                    localized: "The class session is saved, but its text note still needs to be created."
                )
            )
            return retainSessionStartRecovery(
                pending,
                failure: failure,
                snapshot: plannedSnapshot
            )
        }

        sessionStartState = .working(
            courseID: pending.courseID,
            progress: .activatingSession
        )
        availability = .saving
        do {
            // Persistence stores dates as milliseconds. A Double multiply/
            // divide round trip can move the decoded value forward by one ULP,
            // so the saved planned session is the chronology authority here.
            let activationTimestamp = max(
                pending.session.createdAt,
                persistedSession.modifiedAt
            )
            let command = AcademicWorkspaceCommand.transitionSession(
                id: pending.session.id,
                expectedRevision: persistedSession.revision,
                to: .active,
                at: activationTimestamp
            )
            let activated = try await store.mutate(
                expected: plannedSnapshot.token,
                savedAt: max(
                    plannedSnapshot.workspace.savedAt,
                    activationTimestamp
                )
            ) { workspace in
                try command.applying(to: workspace)
            }
            guard activeOperationID == operationID else {
                let failure = AcademicWorkspaceFailure(
                    operation: .activateSession,
                    message: String(localized: "The session activation result arrived too late.")
                )
                return retainSessionStartRecovery(
                    pending,
                    failure: failure,
                    snapshot: plannedSnapshot
                )
            }
            publish(activated, detectingPendingSessionStart: false)
            sessionStartState = .idle
            return .started(route)
        } catch {
            return await reconcileUncertainActivation(
                pending,
                noteTitle: noteTitle,
                ensureNote: ensureNote,
                operationID: operationID,
                originalFailure: failure(for: error, operation: .activateSession)
            )
        }
    }

    private func ensureNoteForAlreadyActiveSession(
        _ pending: PendingSessionStart,
        from activeSnapshot: AcademicWorkspaceStoreSnapshot,
        noteTitle: String,
        ensureNote: SessionTextNoteEnsurer,
        operationID: UUID
    ) async -> SessionStartOutcome {
        guard let request = pending.noteRequest(title: noteTitle),
              let route = pending.route else {
            let failure = AcademicWorkspaceFailure(
                operation: .reconcileSessionStart,
                message: String(
                    localized: "The active class session is missing its note page reference."
                )
            )
            return retainSessionStartRecovery(
                pending,
                failure: failure,
                snapshot: activeSnapshot
            )
        }

        sessionStartState = .working(
            courseID: pending.courseID,
            progress: .creatingNote
        )
        availability = .saving
        let created = await ensureNote(request)
        guard activeOperationID == operationID,
              let created,
              created.notebook.id == request.notebookID,
              created.initialPageID == request.initialPageID,
              created.notebook.kind == .textDocument else {
            let failure = AcademicWorkspaceFailure(
                operation: .createSessionNote,
                message: String(
                    localized: "The active class session still needs its linked text note."
                )
            )
            return retainSessionStartRecovery(
                pending,
                failure: failure,
                snapshot: activeSnapshot
            )
        }

        publish(activeSnapshot, detectingPendingSessionStart: false)
        sessionStartState = .idle
        return .started(route)
    }

    private func reconcileUncertainSessionStart(
        _ pending: PendingSessionStart,
        noteTitle: String,
        ensureNote: SessionTextNoteEnsurer,
        operationID: UUID,
        originalFailure: AcademicWorkspaceFailure
    ) async -> SessionStartOutcome {
        let loaded: AcademicWorkspaceStoreSnapshot
        do {
            loaded = try await store.load()
        } catch {
            guard activeOperationID == operationID else {
                return .failed(originalFailure)
            }
            let failure = failure(for: error, operation: .reconcileSessionStart)
            availability = .unavailable(failure)
            sessionStartState = .recoveryRequired(pending, failure)
            return .recoveryRequired(pending)
        }
        guard activeOperationID == operationID else {
            return .failed(originalFailure)
        }

        switch persistence(of: pending, in: loaded.workspace) {
        case .planned:
            publish(loaded, detectingPendingSessionStart: false)
            return await ensureNoteAndActivate(
                pending,
                from: loaded,
                noteTitle: noteTitle,
                ensureNote: ensureNote,
                operationID: operationID
            )
        case .active:
            publish(loaded, detectingPendingSessionStart: false)
            return await ensureNoteForAlreadyActiveSession(
                pending,
                from: loaded,
                noteTitle: noteTitle,
                ensureNote: ensureNote,
                operationID: operationID
            )
        case .missing:
            return retainSessionStartRecovery(
                pending,
                failure: originalFailure,
                snapshot: loaded
            )
        case .conflict:
            let failure = AcademicWorkspaceFailure(
                operation: .reconcileSessionStart,
                message: String(
                    localized: "The saved class session conflicts with this recovery attempt. No note was changed."
                )
            )
            return retainSessionStartRecovery(
                pending,
                failure: failure,
                snapshot: loaded
            )
        }
    }

    private func reconcileUncertainActivation(
        _ pending: PendingSessionStart,
        noteTitle: String,
        ensureNote: SessionTextNoteEnsurer,
        operationID: UUID,
        originalFailure: AcademicWorkspaceFailure
    ) async -> SessionStartOutcome {
        let loaded: AcademicWorkspaceStoreSnapshot
        do {
            loaded = try await store.load()
        } catch {
            guard activeOperationID == operationID else {
                return .failed(originalFailure)
            }
            let failure = failure(for: error, operation: .reconcileSessionStart)
            availability = .unavailable(failure)
            sessionStartState = .recoveryRequired(pending, failure)
            return .recoveryRequired(pending)
        }
        guard activeOperationID == operationID else {
            return .failed(originalFailure)
        }

        switch persistence(of: pending, in: loaded.workspace) {
        case .active:
            publish(loaded, detectingPendingSessionStart: false)
            return await ensureNoteForAlreadyActiveSession(
                pending,
                from: loaded,
                noteTitle: noteTitle,
                ensureNote: ensureNote,
                operationID: operationID
            )
        case .planned, .missing, .conflict:
            return retainSessionStartRecovery(
                pending,
                failure: originalFailure,
                snapshot: loaded
            )
        }
    }

    private func retainSessionStartRecovery(
        _ pending: PendingSessionStart,
        failure: AcademicWorkspaceFailure,
        snapshot: AcademicWorkspaceStoreSnapshot
    ) -> SessionStartOutcome {
        publish(snapshot, detectingPendingSessionStart: false)
        sessionStartState = .recoveryRequired(pending, failure)
        return .recoveryRequired(pending)
    }

    private func persistence(
        of pending: PendingSessionStart,
        in workspace: AcademicWorkspace
    ) -> PendingSessionPersistence {
        let savedSession = workspace.sessions.first { $0.id == pending.session.id }
        let savedLink = workspace.sessionNoteLinks.first { $0.id == pending.link.id }
        guard savedSession != nil || savedLink != nil else { return .missing }
        guard let savedSession,
              let savedLink,
              canonicallyEqual(savedLink, pending.link),
              savedLink.sessionID == savedSession.id else {
            return .conflict
        }
        if canonicallyEqual(savedSession, pending.session) {
            return .planned
        }
        guard let canonicalPendingSession = canonicalValue(pending.session),
              let expectedActive = try? canonicalPendingSession.transitioned(
            to: .active,
            at: max(
                canonicalPendingSession.createdAt,
                canonicalPendingSession.modifiedAt
            )
        ), canonicallyEqual(savedSession, expectedActive) else {
            return .conflict
        }
        return .active
    }

    private func persistedPendingSessionStart(
        in workspace: AcademicWorkspace
    ) -> PendingSessionStart? {
        let planned = workspace.sessions
            .filter { $0.status == .planned }
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.id < $1.id
            }
        for session in planned {
            if let link = workspace.sessionNoteLinks.first(where: {
                $0.sessionID == session.id
                    && $0.isActive
                    && $0.initialPageID != nil
            }) {
                return PendingSessionStart(session: session, link: link)
            }
        }
        return nil
    }

    private func beginOperation() -> UUID {
        precondition(activeOperationID == nil)
        let id = UUID()
        activeOperationID = id
        return id
    }

    private func finishOperation(_ id: UUID) {
        guard activeOperationID == id else { return }
        activeOperationID = nil
    }

    private func publish(
        _ snapshot: AcademicWorkspaceStoreSnapshot,
        detectingPendingSessionStart: Bool = true
    ) {
        publishedSnapshot = snapshot
        workspace = snapshot.workspace
        availability = .ready
        if detectingPendingSessionStart,
           sessionStartState == .idle,
           let pending = persistedPendingSessionStart(in: snapshot.workspace) {
            sessionStartState = .recoveryRequired(
                pending,
                AcademicWorkspaceFailure(
                    operation: .reconcileSessionStart,
                    message: String(
                        localized: "Finish preparing this class note before starting another session."
                    )
                )
            )
        }
    }

    private func clearPublishedWorkspace() {
        publishedSnapshot = nil
        workspace = .empty
        sessionStartState = .idle
    }

    private func failure(
        for error: any Error,
        operation: AcademicWorkspaceFailureOperation
    ) -> AcademicWorkspaceFailure {
        AcademicWorkspaceFailure(
            operation: operation,
            message: error.localizedDescription
        )
    }

    private func recordRootContractFailure(
        for transition: AcademicLibraryRootTransition
    ) {
        guard activeOperationID == nil,
              var pending = pendingRootTransition,
              pending.capability == transition else {
            // A stale or foreign capability must not disturb the live gate or
            // replace an already published workspace.
            return
        }
        let contractFailure = AcademicWorkspaceFailure(
            operation: .rootTransitionContract,
            message: String(
                localized: "The academic library-root transition is no longer current."
            )
        )
        pending.resolutionFailure = contractFailure
        pendingRootTransition = pending
        if pending.externalRootIsSettled {
            availability = .unavailable(contractFailure)
        }
    }
}
