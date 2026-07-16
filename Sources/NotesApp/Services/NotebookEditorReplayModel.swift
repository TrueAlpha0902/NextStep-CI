import Combine
import Foundation
import NotesCore

enum NotebookEditorReplayPreparationFailure: Equatable, Sendable {
    case controllerUnavailable
    case unsupportedPage
    case pendingWritesCouldNotBeFlushed
}

enum NotebookEditorReplayStatus: Equatable, Sendable {
    case preparation(NotebookEditorReplayPreparationFailure)
    case controller(NoteReplayControllerFailure)
    case page(NoteReplayPageIssue)
}

extension NoteReplayPageIssue {
    var affectedPageID: PageID {
        switch self {
        case .inkUnavailable(let pageID),
             .inkTooLarge(let pageID, _),
             .renderingUnavailable(let pageID),
             .rendererFallback(let pageID, _),
             .cacheBudgetExceeded(let pageID, _),
             .timelineMarkUnavailable(let pageID),
             .historicalSceneUnavailable(let pageID):
            pageID
        }
    }

    var permitsAuthoritativeDrawingFallback: Bool {
        switch self {
        case .inkUnavailable, .inkTooLarge, .renderingUnavailable,
             .cacheBudgetExceeded:
            true
        case .rendererFallback, .timelineMarkUnavailable:
            false
        case .historicalSceneUnavailable:
            false
        }
    }
}

enum NotebookEditorReplayInteractionPolicy {
    enum ThumbnailAction: Equatable {
        case selectEditorPage
        case seekReplay
        case disabled
    }

    static func supportsReplay(_ kind: PageKind) -> Bool {
        switch kind {
        case .notebook, .whiteboard, .importedDocument:
            true
        case .textDocument, .studySet:
            false
        }
    }

    static func canReserveStart(
        isControllerAvailable: Bool,
        isMutationLocked: Bool,
        activeStructuralMutationCount: Int,
        hasReplayablePage: Bool
    ) -> Bool {
        isControllerAvailable
            && !isMutationLocked
            && activeStructuralMutationCount == 0
            && hasReplayablePage
    }

    /// A structured page is not a Replay startup failure. Passing `nil` lets
    /// the controller choose the first eligible drawable page in the session.
    static func preferredStartPageID(
        currentPageID: UUID?,
        currentPageKind: PageKind?
    ) -> PageID? {
        guard let currentPageID,
              let currentPageKind,
              supportsReplay(currentPageKind) else { return nil }
        return PageID(currentPageID)
    }

    static func thumbnailAction(
        hasStartReservation: Bool,
        isStopping: Bool,
        replayState: NoteReplayControllerState
    ) -> ThumbnailAction {
        guard !hasStartReservation, !isStopping else { return .disabled }
        switch replayState {
        case .idle:
            return .selectEditorPage
        case .playing, .paused, .finished:
            return .seekReplay
        case .preparing, .seeking, .stopping:
            return .disabled
        }
    }
}

@MainActor
final class NotebookEditorReplayModel: ObservableObject {
    struct StartReservation: Equatable, Sendable {
        let id: UUID
        let sessionID: AudioSessionID
    }

    @Published private(set) var startReservation: StartReservation?
    @Published private(set) var isStopping = false
    @Published private(set) var preparationFailure:
        NotebookEditorReplayPreparationFailure?

    private var controller: NoteReplayController?
    private var controllerObservation: AnyCancellable?
    private var interactionGeneration = UUID()

    var isAvailable: Bool { controller != nil }
    var state: NoteReplayControllerState { controller?.state ?? .idle }
    var playbackTime: TimeInterval { controller?.playbackTime ?? 0 }
    var duration: TimeInterval { controller?.duration ?? 0 }
    var currentPageID: PageID? { controller?.currentPageID }
    var currentPageFrame: NoteReplayPageFrame? { controller?.currentPageFrame }
    var failure: NoteReplayControllerFailure? { controller?.failure }
    var pageIssue: NoteReplayPageIssue? { controller?.pageIssue }
    var mode: NoteReplayMode { controller?.mode ?? .wholeStrokeReveal }

    var isMutationLocked: Bool {
        startReservation != nil || isStopping || state != .idle
    }

    var thumbnailAction: NotebookEditorReplayInteractionPolicy.ThumbnailAction {
        NotebookEditorReplayInteractionPolicy.thumbnailAction(
            hasStartReservation: startReservation != nil,
            isStopping: isStopping,
            replayState: state
        )
    }

    var status: NotebookEditorReplayStatus? {
        if let preparationFailure { return .preparation(preparationFailure) }
        if let failure { return .controller(failure) }
        if let pageIssue { return .page(pageIssue) }
        return nil
    }

    func configure(controller: NoteReplayController?) {
        // App setup can legitimately finish after the editor's first task
        // pass. A nil attempt therefore must not permanently seal the model.
        guard self.controller == nil, let controller else { return }
        self.controller = controller
        controllerObservation = controller.objectWillChange.sink {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.objectWillChange.send()
            }
        }
        objectWillChange.send()
    }

    @discardableResult
    func reserveStart(sessionID: AudioSessionID) -> StartReservation {
        interactionGeneration = UUID()
        let reservation = StartReservation(
            id: interactionGeneration,
            sessionID: sessionID
        )
        preparationFailure = nil
        isStopping = false
        startReservation = reservation
        return reservation
    }

    func isCurrent(_ reservation: StartReservation) -> Bool {
        startReservation == reservation
            && interactionGeneration == reservation.id
    }

    func failStart(
        _ reservation: StartReservation,
        reason: NotebookEditorReplayPreparationFailure
    ) {
        guard isCurrent(reservation) else { return }
        startReservation = nil
        preparationFailure = reason
    }

    func start(
        _ reservation: StartReservation,
        notebookID: NotebookID,
        currentPageID: PageID?
    ) async {
        guard isCurrent(reservation) else { return }
        guard let controller else {
            failStart(reservation, reason: .controllerUnavailable)
            return
        }
        await controller.start(
            notebookID: notebookID,
            sessionID: reservation.sessionID,
            currentPageID: currentPageID,
            mode: mode
        )
        guard interactionGeneration == reservation.id else { return }
        startReservation = nil
    }

    func pause() async { await controller?.pause() }
    func resume() async { await controller?.resume() }
    func seek(to time: TimeInterval) async { await controller?.seek(to: time) }
    func skipBackward() async { await controller?.skipBackward(by: 15) }
    func skipForward() async { await controller?.skipForward(by: 15) }

    @discardableResult
    func seekToPage(_ pageID: PageID) async -> Bool {
        await controller?.seekToPage(pageID) ?? false
    }

    func setMode(_ mode: NoteReplayMode) async {
        await controller?.setMode(mode)
    }

    @discardableResult
    func stop() async -> PageID? {
        interactionGeneration = UUID()
        startReservation = nil
        preparationFailure = nil
        let generation = interactionGeneration
        let restorationPageID = currentPageID
        isStopping = controller?.isActive == true
        await controller?.stop()
        guard interactionGeneration == generation else { return nil }
        isStopping = false
        return restorationPageID
    }

    @discardableResult
    func handleLifecycle(_ event: NoteReplayLifecycleEvent) async -> PageID? {
        if event == .enteredBackground || event == .editorDismissed {
            interactionGeneration = UUID()
            startReservation = nil
            preparationFailure = nil
        } else if event == .becameInactive, startReservation != nil {
            interactionGeneration = UUID()
            startReservation = nil
            preparationFailure = nil
        }
        let generation = interactionGeneration
        let restorationPageID = currentPageID
        let shouldRestore = event == .enteredBackground
            || event == .editorDismissed
        if shouldRestore { isStopping = controller?.isActive == true }
        await controller?.handleLifecycle(event)
        guard interactionGeneration == generation else { return nil }
        if shouldRestore { isStopping = false }
        return shouldRestore && state == .idle ? restorationPageID : nil
    }
}
