import Combine
import Foundation
import NotesCore
import NotesServices

enum NotebookAudioTranscriptionLocale: String, CaseIterable, Identifiable, Sendable {
    case traditionalChinese = "zh-Hant-TW"
    case english = "en-US"
    case japanese = "ja-JP"
    case korean = "ko-KR"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .traditionalChinese: String(localized: "Traditional Chinese (Taiwan)")
        case .english: String(localized: "English (United States)")
        case .japanese: String(localized: "Japanese")
        case .korean: String(localized: "Korean")
        }
    }
}

enum NotebookAudioSearchIndexOperationQueueError: Error, Sendable {
    case capacityExceeded
}

@MainActor
private final class NotebookAudioSearchIndexOperationGate {
    private enum State {
        case waiting
        case open
        case cancelled
    }

    private var state: State = .waiting
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async throws {
        try Task.checkCancellation()
        switch state {
        case .waiting:
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        case .open:
            break
        case .cancelled:
            throw CancellationError()
        }
        try Task.checkCancellation()
        guard case .open = state else { throw CancellationError() }
    }

    func open() {
        guard case .waiting = state else { return }
        state = .open
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }

    func cancel() {
        guard case .waiting = state else { return }
        state = .cancelled
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

struct NotebookAudioSearchIndexOperationHandle: Sendable {
    fileprivate let id: UUID
    fileprivate let task: Task<Void, Error>

    func wait() async throws {
        try await task.value
    }
}

/// A bounded, strict-FIFO queue for derived search-index mutations.
///
/// `enqueue` is synchronous on `MainActor`: a caller receives its ticket before
/// it can suspend, so three or more simultaneous callers cannot race when a
/// predecessor completes. Completed operations are removed instead of being
/// retained through a tail-task dependency chain.
@MainActor
final class NotebookAudioSearchIndexOperationQueue {
    private struct Entry {
        let id: UUID
        let gate: NotebookAudioSearchIndexOperationGate
        let task: Task<Void, Error>
    }

    private struct Drain {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let capacity: Int
    private var pending: [Entry] = []
    private var active: Entry?
    private var drain: Drain?

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    var hasOperations: Bool {
        active != nil || !pending.isEmpty
    }

    func enqueue(
        _ operation: @escaping @MainActor @Sendable () async throws -> Void
    ) throws -> NotebookAudioSearchIndexOperationHandle {
        guard pending.count + (active == nil ? 0 : 1) < capacity else {
            throw NotebookAudioSearchIndexOperationQueueError.capacityExceeded
        }
        let id = UUID()
        let gate = NotebookAudioSearchIndexOperationGate()
        let task = Task { @MainActor in
            try await gate.wait()
            try Task.checkCancellation()
            try await operation()
            try Task.checkCancellation()
        }
        pending.append(Entry(id: id, gate: gate, task: task))
        startDrainIfNeeded()
        return NotebookAudioSearchIndexOperationHandle(id: id, task: task)
    }

    func cancel(_ handle: NotebookAudioSearchIndexOperationHandle) {
        if active?.id == handle.id {
            active?.task.cancel()
            active?.gate.cancel()
            return
        }
        guard let index = pending.firstIndex(where: { $0.id == handle.id }) else { return }
        let entry = pending.remove(at: index)
        entry.task.cancel()
        entry.gate.cancel()
    }

    func cancelAll() async {
        let operations = (active.map { [$0] } ?? []) + pending
        pending.removeAll(keepingCapacity: true)
        for entry in operations {
            entry.task.cancel()
            entry.gate.cancel()
        }
        for entry in operations {
            _ = await entry.task.result
        }
        let currentDrain = drain
        await currentDrain?.task.value
        if drain?.id == currentDrain?.id {
            drain = nil
        }
        if let active, operations.contains(where: { $0.id == active.id }) {
            self.active = nil
        }
    }

    func waitUntilIdle() async {
        if let drain {
            await drain.task.value
        }
    }

    private func startDrainIfNeeded() {
        guard drain == nil else { return }
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drainOperations(drainID: id)
        }
        drain = Drain(id: id, task: task)
    }

    private func drainOperations(drainID: UUID) async {
        defer {
            if drain?.id == drainID {
                drain = nil
            }
        }
        while !pending.isEmpty {
            let entry = pending.removeFirst()
            active = entry
            entry.gate.open()
            _ = await entry.task.result
            if active?.id == entry.id {
                active = nil
            }
        }
    }
}

@MainActor
final class NotebookAudioPanelModel: ObservableObject {
    @Published private(set) var sessions: [AudioSessionDescriptor] = []
    @Published private(set) var snapshot: NotebookAudioCoordinatorSnapshot = .idle
    @Published private(set) var playbackState: AudioPlaybackState = .stopped
    @Published private(set) var playbackSessionID: AudioSessionID?
    @Published private(set) var transcript: NotebookAudioTranscriptPayload?
    @Published private(set) var isLoadingSessions = false
    @Published private(set) var failureMessage: String?
    @Published var selectedLocale: NotebookAudioTranscriptionLocale = .traditionalChinese

    private struct QueuedPageMark: Sendable {
        var operationID: OperationID
        var pageID: PageID
    }

    private enum QueuedReplayCapture: Sendable {
        case page(NotebookAudioReplayPageSnapshot, byteCost: Int)
        case ink(Data?, pageID: PageID)
        case elements([CanvasElement], pageID: PageID, byteCost: Int)

        var byteCost: Int {
            switch self {
            case .page(_, let byteCost), .elements(_, _, let byteCost):
                byteCost
            case .ink(let data, _):
                data?.count ?? 0
            }
        }

        var pageID: PageID {
            switch self {
            case .page(let snapshot, _): snapshot.pageID
            case .ink(_, let pageID), .elements(_, let pageID, _): pageID
            }
        }
    }

    private enum RetryAction {
        case load(NotebookID)
        case start(
            NotebookID,
            PageID,
            NotebookAudioReplayPageSnapshot?
        )
        case play(NotebookID, AudioSessionID, TimeInterval)
        case transcribe(NotebookID, AudioSessionID, NotebookAudioTranscriptionLocale)
        case loadTranscript(NotebookID, AudioSessionID)
        case indexTranscript(NotebookID, NotebookAudioTranscriptPayload, AssetID)
        case reconcileSearch(NotebookID)
    }

    private enum FailureContext {
        case load
        case record
        case persist
        case mark
        case replayCapture
        case playback
        case transcription
        case transcriptLoad
        case searchIndex

        var message: String {
            switch self {
            case .load: String(localized: "Audio recordings could not be loaded.")
            case .record: String(localized: "Recording could not start. Check microphone access and try again.")
            case .persist: String(localized: "The recording was not saved. Start a new recording to try again.")
            case .mark: String(localized: "The page change could not be added to the recording, so recording stopped.")
            case .replayCapture: String(localized: "Note Replay history could not be captured safely, so recording stopped without saving.")
            case .playback: String(localized: "This recording could not be played.")
            case .transcription: String(localized: "The on-device transcript could not be created or saved.")
            case .transcriptLoad: String(localized: "The saved transcript could not be loaded.")
            case .searchIndex: String(localized: "The transcript is saved, but local search could not be updated.")
            }
        }
    }

    private let coordinator: NotebookAudioCoordinator
    private let sessionListing: any NotebookAudioSessionListing
    private let transcriptSearchIndexer: (any NotebookAudioTranscriptSearchIndexing)?
    private let searchIndexOperationQueue = NotebookAudioSearchIndexOperationQueue()
    private var currentNotebookID: NotebookID?
    private var libraryRootChangeInProgress = false
    private var libraryRootChangeToken: UUID?
    private var isLibraryRootChangePreparationPending = false
    private var libraryRootChangeFinishRequested = false
    private var notebookOpenGeneration = UUID()
    private var sessionLoadGeneration = UUID()
    private var actionGeneration = UUID()
    private var recordingGeneration: UUID?
    private var pendingStartingPageID: PageID?
    private var queuedPageMarks: [QueuedPageMark] = []
    private var markDrainTask: Task<Void, Never>?
    private var queuedReplayCaptures: [QueuedReplayCapture] = []
    private var queuedReplayCaptureByteCount = 0
    private var replayCaptureDrainTask: Task<Void, Never>?
    private static let maximumQueuedReplayCaptureBytes = 16 * 1_024 * 1_024
    private static let maximumQueuedReplayCaptureCount =
        NoteReplayHistoryLimits.maximumEventCount
    private var searchIndexGeneration = UUID()
    private var searchIndexOperationsAreEnabled = true
    private var retryAction: RetryAction?

    init(
        coordinator: NotebookAudioCoordinator,
        sessionListing: any NotebookAudioSessionListing,
        transcriptSearchIndexer: (any NotebookAudioTranscriptSearchIndexing)? = nil
    ) {
        self.coordinator = coordinator
        self.sessionListing = sessionListing
        self.transcriptSearchIndexer = transcriptSearchIndexer
    }

    var canRetry: Bool { retryAction != nil }

    var isRecording: Bool {
        switch snapshot.activity {
        case .startingRecording, .recording, .stoppingRecording, .persistingRecording:
            true
        default:
            false
        }
    }

    var isTranscribing: Bool { snapshot.activity == .transcribing }

    func open(notebookID: UUID) async {
        guard !libraryRootChangeInProgress else { return }
        let coreID = NotebookID(notebookID)
        let openGeneration = UUID()
        notebookOpenGeneration = openGeneration
        let switchesNotebook = currentNotebookID != nil && currentNotebookID != coreID
        if switchesNotebook || !searchIndexOperationsAreEnabled {
            let cancelled = await cancelCurrentOperation(resumeSearchIndexOperations: false)
            guard notebookOpenGeneration == openGeneration,
                  !libraryRootChangeInProgress else { return }
            guard cancelled else {
                resumeSearchIndexOperations()
                return
            }
        }
        guard notebookOpenGeneration == openGeneration,
              !libraryRootChangeInProgress else { return }
        if switchesNotebook {
            sessions = []
            transcript = nil
            playbackSessionID = nil
            playbackState = .stopped
            snapshot = .idle
        }
        currentNotebookID = coreID
        resumeSearchIndexOperations()
        await loadSessions(notebookID: coreID, automaticallyLoadTranscript: true)
        guard notebookOpenGeneration == openGeneration,
              currentNotebookID == coreID else { return }
        await poll()
    }

    func prepareForLibraryRootChange(token: UUID) async -> Bool {
        guard !libraryRootChangeInProgress,
              libraryRootChangeToken == nil else { return false }
        libraryRootChangeInProgress = true
        libraryRootChangeToken = token
        isLibraryRootChangePreparationPending = true
        libraryRootChangeFinishRequested = false
        notebookOpenGeneration = UUID()
        let previousNotebookID = currentNotebookID
        currentNotebookID = nil
        let cancelled = await cancelCurrentOperation(resumeSearchIndexOperations: false)
        guard libraryRootChangeToken == token else { return false }
        isLibraryRootChangePreparationPending = false
        if libraryRootChangeFinishRequested || Task.isCancelled {
            if !cancelled { currentNotebookID = previousNotebookID }
            endLibraryRootChange(token: token)
            return cancelled
        }
        guard cancelled else {
            currentNotebookID = previousNotebookID
            endLibraryRootChange(token: token)
            return false
        }
        sessions = []
        transcript = nil
        playbackSessionID = nil
        playbackState = .stopped
        snapshot = .idle
        return true
    }

    func finishLibraryRootChange(token: UUID) {
        guard libraryRootChangeToken == token else { return }
        if isLibraryRootChangePreparationPending {
            // A hard-timeboxed caller may abandon an uncooperative coordinator
            // cancellation. Keep audio fenced until that cancellation actually
            // settles, so neither a retry nor a new open can be invalidated by
            // the stale completion.
            libraryRootChangeFinishRequested = true
            return
        }
        endLibraryRootChange(token: token)
    }

    private func endLibraryRootChange(token: UUID) {
        guard libraryRootChangeToken == token else { return }
        libraryRootChangeToken = nil
        isLibraryRootChangePreparationPending = false
        libraryRootChangeFinishRequested = false
        libraryRootChangeInProgress = false
        resumeSearchIndexOperations()
    }

    @discardableResult
    func loadSessions(
        notebookID: NotebookID? = nil,
        automaticallyLoadTranscript: Bool = false
    ) async -> Bool {
        guard let targetID = notebookID ?? currentNotebookID else { return false }
        let loadGeneration = UUID()
        sessionLoadGeneration = loadGeneration
        isLoadingSessions = true
        do {
            let loaded = try await sessionListing.listAudioSessions(notebookID: targetID)
            guard sessionLoadGeneration == loadGeneration,
                  currentNotebookID == targetID else {
                finishSessionLoadIfCurrent(loadGeneration)
                return false
            }
            sessions = loaded.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id.description < rhs.id.description
            }
            if let transcript,
               !sessions.contains(where: {
                   $0.id == transcript.audioSessionID && $0.transcriptAssetID != nil
               }) {
                self.transcript = nil
            }
            isLoadingSessions = false
            clearFailure()
            if automaticallyLoadTranscript,
               transcript == nil,
               snapshot.activity == .idle,
               let sessionID = sessions.first(where: { $0.transcriptAssetID != nil })?.id {
                await loadTranscript(sessionID: sessionID)
            }
            guard sessionLoadGeneration == loadGeneration,
                  currentNotebookID == targetID else {
                finishSessionLoadIfCurrent(loadGeneration)
                return false
            }
            await reconcileTranscriptSearch(notebookID: targetID, sessions: sessions)
            return sessionLoadGeneration == loadGeneration && currentNotebookID == targetID
        } catch {
            guard sessionLoadGeneration == loadGeneration,
                  currentNotebookID == targetID else {
                finishSessionLoadIfCurrent(loadGeneration)
                return false
            }
            isLoadingSessions = false
            presentFailure(.load, retry: .load(targetID), error: error)
            return false
        }
    }

    func startRecording(
        notebookID: UUID,
        pageID: UUID,
        initialReplaySnapshot: NotebookAudioReplayPageSnapshot? = nil
    ) async {
        let targetNotebookID = NotebookID(notebookID)
        let targetPageID = PageID(pageID)
        guard currentNotebookID == targetNotebookID else { return }
        let operationGeneration = beginAction()
        pendingStartingPageID = targetPageID
        failureMessage = nil
        retryAction = nil
        snapshot = NotebookAudioCoordinatorSnapshot(
            activity: .startingRecording,
            notebookID: targetNotebookID,
            recordingID: nil,
            sessionID: nil
        )
        do {
            _ = try await coordinator.startRecording(notebookID: targetNotebookID)
            try ensureCurrent(operationGeneration, notebookID: targetNotebookID)
            var markedPageID = pendingStartingPageID ?? targetPageID
            try await coordinator.addMark(operationID: OperationID(), pageID: markedPageID)
            try ensureCurrent(operationGeneration, notebookID: targetNotebookID)
            if let initialReplaySnapshot {
                guard initialReplaySnapshot.pageID == markedPageID else {
                    throw NotebookAudioCoordinatorError.invalidReplayCapture
                }
                try await coordinator.addReplayPageSnapshot(initialReplaySnapshot)
                try ensureCurrent(operationGeneration, notebookID: targetNotebookID)
            }
            while let latestPageID = pendingStartingPageID, latestPageID != markedPageID {
                markedPageID = latestPageID
                try await coordinator.addMark(operationID: OperationID(), pageID: latestPageID)
                try ensureCurrent(operationGeneration, notebookID: targetNotebookID)
            }
            pendingStartingPageID = nil
            recordingGeneration = UUID()
            queuedReplayCaptures.removeAll(keepingCapacity: true)
            queuedReplayCaptureByteCount = 0
            snapshot = await coordinator.standardSnapshot()
        } catch {
            guard isCurrent(operationGeneration, notebookID: targetNotebookID) else { return }
            pendingStartingPageID = nil
            try? await coordinator.cancelStandardOperation()
            recordingGeneration = nil
            queuedReplayCaptures.removeAll(keepingCapacity: true)
            queuedReplayCaptureByteCount = 0
            replayCaptureDrainTask?.cancel()
            replayCaptureDrainTask = nil
            snapshot = .idle
            presentFailure(
                .record,
                retry: .start(
                    targetNotebookID,
                    targetPageID,
                    initialReplaySnapshot
                ),
                error: error
            )
        }
    }

    /// Page changes are queued in UI order. Each receives a fresh stable
    /// operation identifier, and a later navigation cannot reorder an earlier
    /// mark while the recorder actor is suspended.
    func enqueuePageMark(notebookID: UUID, pageID: UUID) {
        guard currentNotebookID == NotebookID(notebookID) else { return }
        let corePageID = PageID(pageID)
        if snapshot.activity == .startingRecording {
            pendingStartingPageID = corePageID
            return
        }
        guard snapshot.activity == .recording,
              recordingGeneration != nil else { return }
        queuedPageMarks.append(
            QueuedPageMark(operationID: OperationID(), pageID: corePageID)
        )
        startMarkDrainIfNeeded()
    }

    func enqueueReplayPageSnapshot(
        notebookID: UUID,
        snapshot pageSnapshot: NotebookAudioReplayPageSnapshot
    ) {
        guard currentNotebookID == NotebookID(notebookID),
              snapshot.activity == .recording,
              recordingGeneration != nil else { return }
        let elementBytes: Int
        do {
            elementBytes = try NoteReplayPayloadCodec.encodeElements(
                pageSnapshot.elements
            ).count
        } catch {
            failReplayCaptureEnqueue(pageID: pageSnapshot.pageID, error: error)
            return
        }
        enqueueReplayCapture(
            .page(
                pageSnapshot,
                byteCost: (pageSnapshot.inkData?.count ?? 0) + elementBytes
            )
        )
    }

    func enqueueReplayInkSnapshot(
        _ data: Data?,
        notebookID: UUID,
        pageID: UUID
    ) {
        guard currentNotebookID == NotebookID(notebookID),
              snapshot.activity == .recording,
              recordingGeneration != nil else { return }
        enqueueReplayCapture(.ink(data, pageID: PageID(pageID)))
    }

    func enqueueReplayElementsSnapshot(
        _ elements: [CanvasElement],
        notebookID: UUID,
        pageID: UUID
    ) {
        guard currentNotebookID == NotebookID(notebookID),
              snapshot.activity == .recording,
              recordingGeneration != nil else { return }
        let byteCost: Int
        do {
            byteCost = try NoteReplayPayloadCodec.encodeElements(elements).count
        } catch {
            failReplayCaptureEnqueue(pageID: PageID(pageID), error: error)
            return
        }
        enqueueReplayCapture(
            .elements(elements, pageID: PageID(pageID), byteCost: byteCost)
        )
    }

    /// A drawable page that cannot provide both authoritative layers cannot
    /// participate in a complete replay history. Stop rather than silently
    /// persisting a partial log.
    func reportReplayCaptureUnavailable(
        notebookID: UUID,
        pageID: UUID
    ) {
        guard currentNotebookID == NotebookID(notebookID),
              snapshot.activity == .recording else { return }
        failReplayCaptureEnqueue(
            pageID: PageID(pageID),
            error: NotebookAudioCoordinatorError.invalidReplayCapture
        )
    }

    func stopRecording(currentPageID: UUID) async {
        guard let notebookID = currentNotebookID else { return }
        _ = currentPageID
        let operationGeneration = beginAction()
        snapshot.activity = .stoppingRecording
        await flushQueuedPageMarks()
        await flushQueuedReplayCaptures()
        guard isCurrent(operationGeneration, notebookID: notebookID),
              snapshot.activity != .idle else { return }
        recordingGeneration = nil
        queuedPageMarks.removeAll(keepingCapacity: true)
        queuedReplayCaptures.removeAll(keepingCapacity: true)
        queuedReplayCaptureByteCount = 0
        do {
            _ = try await coordinator.stopAndPersist()
            try ensureCurrent(operationGeneration, notebookID: notebookID)
            snapshot = .idle
            failureMessage = nil
            retryAction = nil
            await loadSessions(notebookID: notebookID)
        } catch {
            guard isCurrent(operationGeneration, notebookID: notebookID) else { return }
            snapshot = await coordinator.standardSnapshot()
            presentFailure(
                .persist,
                retry: nil,
                error: error
            )
        }
    }

    @discardableResult
    func cancelCurrentOperation(resumeSearchIndexOperations: Bool = true) async -> Bool {
        invalidateActions()
        await cancelSearchIndexOperations()
        do {
            try await coordinator.cancelStandardOperation()
            snapshot = .idle
            playbackState = .stopped
            playbackSessionID = nil
            if resumeSearchIndexOperations { self.resumeSearchIndexOperations() }
            return true
        } catch {
            snapshot = .idle
            playbackState = .stopped
            playbackSessionID = nil
            presentFailure(.persist, retry: nil, error: error)
            if resumeSearchIndexOperations { self.resumeSearchIndexOperations() }
            return false
        }
    }

    @discardableResult
    func handleInterruption(notebookID: UUID) async -> Bool {
        let targetID = NotebookID(notebookID)
        guard currentNotebookID == targetID else { return true }
        let coordinatorSnapshot = await coordinator.standardSnapshot()
        guard currentNotebookID == targetID,
              coordinatorSnapshot.notebookID == targetID,
              coordinatorSnapshot.activity != .idle || searchIndexOperationQueue.hasOperations else {
            return true
        }
        return await cancelCurrentOperation()
    }

    func play(sessionID: AudioSessionID, from time: TimeInterval = 0) async {
        guard let notebookID = currentNotebookID else { return }
        let operationGeneration = beginAction()
        let wasPlaybackActive = snapshot.activity == .playing || snapshot.activity == .paused
        failureMessage = nil
        retryAction = nil
        snapshot = NotebookAudioCoordinatorSnapshot(
            activity: .preparingPlayback,
            notebookID: notebookID,
            recordingID: nil,
            sessionID: sessionID
        )
        do {
            if wasPlaybackActive {
                await coordinator.stopPlayback()
            }
            try ensureCurrent(operationGeneration, notebookID: notebookID)
            try await coordinator.play(notebookID: notebookID, sessionID: sessionID, from: time)
            try ensureCurrent(operationGeneration, notebookID: notebookID)
            playbackSessionID = sessionID
            snapshot = await coordinator.standardSnapshot()
            playbackState = await coordinator.standardPlaybackState()
        } catch {
            guard isCurrent(operationGeneration, notebookID: notebookID) else { return }
            snapshot = await coordinator.standardSnapshot()
            playbackState = .stopped
            playbackSessionID = nil
            presentFailure(
                .playback,
                retry: .play(notebookID, sessionID, time),
                error: error
            )
        }
    }

    func pausePlayback() async {
        guard let notebookID = currentNotebookID else { return }
        let operationGeneration = beginAction()
        do {
            try await coordinator.pausePlayback()
            try ensureCurrent(operationGeneration, notebookID: notebookID)
            await poll()
        } catch {
            guard isCurrent(operationGeneration, notebookID: notebookID) else { return }
            presentFailure(.playback, retry: nil, error: error)
        }
    }

    func resumePlayback() async {
        guard let notebookID = currentNotebookID, let sessionID = playbackSessionID else { return }
        let operationGeneration = beginAction()
        do {
            try await coordinator.resumePlayback()
            try ensureCurrent(operationGeneration, notebookID: notebookID)
            await poll()
        } catch {
            guard isCurrent(operationGeneration, notebookID: notebookID) else { return }
            presentFailure(
                .playback,
                retry: .play(notebookID, sessionID, playbackState.currentTime),
                error: error
            )
        }
    }

    func seekPlayback(to time: TimeInterval) async {
        guard let notebookID = currentNotebookID, let sessionID = playbackSessionID else { return }
        let operationGeneration = beginAction()
        do {
            try await coordinator.seekPlayback(to: time)
            try ensureCurrent(operationGeneration, notebookID: notebookID)
            playbackState = await coordinator.standardPlaybackState()
        } catch {
            guard isCurrent(operationGeneration, notebookID: notebookID) else { return }
            presentFailure(
                .playback,
                retry: .play(notebookID, sessionID, time),
                error: error
            )
        }
    }

    func stopPlayback() async {
        invalidateActions(preservingRecording: true)
        await coordinator.stopPlayback()
        snapshot = .idle
        playbackState = .stopped
        playbackSessionID = nil
    }

    func transcribe(sessionID: AudioSessionID) async {
        guard let notebookID = currentNotebookID else { return }
        let locale = selectedLocale
        let operationGeneration = beginAction()
        transcript = nil
        failureMessage = nil
        retryAction = nil
        snapshot = NotebookAudioCoordinatorSnapshot(
            activity: .transcribing,
            notebookID: notebookID,
            recordingID: nil,
            sessionID: sessionID
        )
        do {
            let result = try await coordinator.transcribeAndPersist(
                notebookID: notebookID,
                sessionID: sessionID,
                localeIdentifier: locale.rawValue
            )
            try ensureCurrent(operationGeneration, notebookID: notebookID)
            let payload = result.payload
            guard payload.audioSessionID == sessionID else { throw CancellationError() }
            guard result.savedDescriptor.id == sessionID,
                  let transcriptAssetID = result.savedDescriptor.transcriptAssetID else {
                throw NotebookAudioCoordinatorError.incompleteAudioMaterialization
            }
            transcript = payload
            snapshot = .idle
            await loadSessions(notebookID: notebookID)
            try ensureCurrent(operationGeneration, notebookID: notebookID)
            await indexTranscript(
                payload,
                notebookID: notebookID,
                transcriptAssetID: transcriptAssetID,
                operationGeneration: operationGeneration
            )
        } catch {
            guard isCurrent(operationGeneration, notebookID: notebookID) else { return }
            snapshot = await coordinator.standardSnapshot()
            presentFailure(
                .transcription,
                retry: .transcribe(notebookID, sessionID, locale),
                error: error
            )
        }
    }

    func loadTranscript(sessionID: AudioSessionID) async {
        guard let notebookID = currentNotebookID else { return }
        let operationGeneration = beginAction()
        transcript = nil
        failureMessage = nil
        retryAction = nil
        snapshot = NotebookAudioCoordinatorSnapshot(
            activity: .loadingTranscript,
            notebookID: notebookID,
            recordingID: nil,
            sessionID: sessionID
        )
        do {
            let payload = try await coordinator.loadTranscript(
                notebookID: notebookID,
                sessionID: sessionID
            )
            try ensureCurrent(operationGeneration, notebookID: notebookID)
            guard let payload, payload.audioSessionID == sessionID else {
                throw NotebookAudioCoordinatorError.incompleteAudioMaterialization
            }
            transcript = payload
            snapshot = .idle
            await indexTranscript(
                payload,
                notebookID: notebookID,
                operationGeneration: operationGeneration
            )
        } catch {
            guard isCurrent(operationGeneration, notebookID: notebookID) else { return }
            if let transcriptSearchIndexer {
                try? await performSearchIndexOperation(notebookID: notebookID) {
                    try await transcriptSearchIndexer.remove(
                        notebookID: notebookID,
                        sessionID: sessionID
                    )
                }
            }
            snapshot = await coordinator.standardSnapshot()
            presentFailure(
                .transcriptLoad,
                retry: .loadTranscript(notebookID, sessionID),
                error: error
            )
        }
    }

    func playTranscriptSegment(_ segment: NotebookAudioTranscriptSegmentMapping) async {
        guard let transcript else { return }
        if playbackSessionID == transcript.audioSessionID,
           (snapshot.activity == .playing || snapshot.activity == .paused) {
            await seekPlayback(to: segment.startTime)
        } else {
            await play(sessionID: transcript.audioSessionID, from: segment.startTime)
        }
    }

    func retry() async {
        guard let retryAction else { return }
        switch retryAction {
        case .load(let notebookID):
            await loadSessions(notebookID: notebookID)
        case .start(let notebookID, let pageID, let initialReplaySnapshot):
            await startRecording(
                notebookID: notebookID.rawValue,
                pageID: pageID.rawValue,
                initialReplaySnapshot: initialReplaySnapshot
            )
        case .play(let notebookID, let sessionID, let time):
            guard currentNotebookID == notebookID else { return }
            await play(sessionID: sessionID, from: time)
        case .transcribe(let notebookID, let sessionID, let locale):
            guard currentNotebookID == notebookID else { return }
            selectedLocale = locale
            await transcribe(sessionID: sessionID)
        case .loadTranscript(let notebookID, let sessionID):
            guard currentNotebookID == notebookID else { return }
            await loadTranscript(sessionID: sessionID)
        case .indexTranscript(let notebookID, let payload, let transcriptAssetID):
            guard currentNotebookID == notebookID else { return }
            guard await loadSessions(notebookID: notebookID),
                  currentNotebookID == notebookID,
                  sessions.first(where: { $0.id == payload.audioSessionID })?.transcriptAssetID
                    == transcriptAssetID else { return }
            let operationGeneration = beginAction()
            await indexTranscript(
                payload,
                notebookID: notebookID,
                transcriptAssetID: transcriptAssetID,
                operationGeneration: operationGeneration
            )
        case .reconcileSearch(let notebookID):
            guard currentNotebookID == notebookID else { return }
            await loadSessions(notebookID: notebookID)
        }
    }

    func dismissFailure() {
        failureMessage = nil
        retryAction = nil
    }

    func poll() async {
        guard let notebookID = currentNotebookID else { return }
        let expectedActionGeneration = actionGeneration
        let loadedSnapshot = await coordinator.standardSnapshot()
        guard currentNotebookID == notebookID,
              actionGeneration == expectedActionGeneration else { return }
        guard loadedSnapshot.notebookID == nil || loadedSnapshot.notebookID == notebookID else { return }
        snapshot = loadedSnapshot
        if loadedSnapshot.activity == .playing || loadedSnapshot.activity == .paused {
            let loadedPlaybackState = await coordinator.standardPlaybackState()
            guard currentNotebookID == notebookID,
                  actionGeneration == expectedActionGeneration else { return }
            playbackState = loadedPlaybackState
        } else if loadedSnapshot.activity == .idle, playbackSessionID != nil {
            playbackState = .stopped
            playbackSessionID = nil
        }
    }

    private func startMarkDrainIfNeeded() {
        guard markDrainTask == nil, let recordingGeneration else { return }
        markDrainTask = Task { [weak self] in
            guard let self else { return }
            await self.drainPageMarks(recordingGeneration: recordingGeneration)
        }
    }

    private func drainPageMarks(recordingGeneration expectedGeneration: UUID) async {
        while recordingGeneration == expectedGeneration, !queuedPageMarks.isEmpty {
            let mark = queuedPageMarks.removeFirst()
            do {
                try await coordinator.addMark(operationID: mark.operationID, pageID: mark.pageID)
                guard recordingGeneration == expectedGeneration else { break }
            } catch {
                guard recordingGeneration == expectedGeneration else { break }
                queuedPageMarks.removeAll(keepingCapacity: true)
                recordingGeneration = nil
                queuedReplayCaptures.removeAll(keepingCapacity: true)
                queuedReplayCaptureByteCount = 0
                replayCaptureDrainTask?.cancel()
                replayCaptureDrainTask = nil
                try? await coordinator.cancelStandardOperation()
                snapshot = .idle
                presentFailure(
                    .mark,
                    retry: nil,
                    error: error
                )
                break
            }
        }
        if recordingGeneration == expectedGeneration || recordingGeneration == nil {
            markDrainTask = nil
        }
    }

    private func flushQueuedPageMarks() async {
        startMarkDrainIfNeeded()
        let task = markDrainTask
        await task?.value
    }

    private func enqueueReplayCapture(_ capture: QueuedReplayCapture) {
        guard snapshot.activity == .recording,
              recordingGeneration != nil else { return }
        let byteCost = capture.byteCost
        guard queuedReplayCaptures.count < Self.maximumQueuedReplayCaptureCount,
              byteCost >= 0,
              byteCost <= Self.maximumQueuedReplayCaptureBytes,
              queuedReplayCaptureByteCount
                <= Self.maximumQueuedReplayCaptureBytes - byteCost else {
            failReplayCaptureEnqueue(
                pageID: capture.pageID,
                error: NotebookAudioCoordinatorError.replayCaptureLimitExceeded
            )
            return
        }
        queuedReplayCaptures.append(capture)
        queuedReplayCaptureByteCount += byteCost
        startReplayCaptureDrainIfNeeded()
    }

    private func startReplayCaptureDrainIfNeeded() {
        guard replayCaptureDrainTask == nil,
              let recordingGeneration else { return }
        replayCaptureDrainTask = Task { [weak self] in
            guard let self else { return }
            await self.drainReplayCaptures(
                recordingGeneration: recordingGeneration
            )
        }
    }

    private func drainReplayCaptures(
        recordingGeneration expectedGeneration: UUID
    ) async {
        while recordingGeneration == expectedGeneration,
              !queuedReplayCaptures.isEmpty {
            let capture = queuedReplayCaptures.removeFirst()
            queuedReplayCaptureByteCount = max(
                queuedReplayCaptureByteCount - capture.byteCost,
                0
            )
            do {
                switch capture {
                case .page(let snapshot, _):
                    try await coordinator.addReplayPageSnapshot(snapshot)
                case .ink(let data, let pageID):
                    try await coordinator.addReplayInkSnapshot(
                        data,
                        pageID: pageID
                    )
                case .elements(let elements, let pageID, _):
                    try await coordinator.addReplayElementsSnapshot(
                        elements,
                        pageID: pageID
                    )
                }
                guard recordingGeneration == expectedGeneration else { break }
            } catch {
                guard recordingGeneration == expectedGeneration else { break }
                await failReplayCapture(
                    pageID: capture.pageID,
                    error: error
                )
                break
            }
        }
        if recordingGeneration == expectedGeneration
            || recordingGeneration == nil {
            replayCaptureDrainTask = nil
        }
    }

    private func flushQueuedReplayCaptures() async {
        startReplayCaptureDrainIfNeeded()
        let task = replayCaptureDrainTask
        await task?.value
    }

    private func failReplayCaptureEnqueue(pageID: PageID, error: Error) {
        guard recordingGeneration != nil,
              snapshot.activity == .recording else { return }
        Task { @MainActor [weak self] in
            await self?.failReplayCapture(pageID: pageID, error: error)
        }
    }

    private func failReplayCapture(pageID: PageID, error: Error) async {
        guard recordingGeneration != nil else { return }
        queuedReplayCaptures.removeAll(keepingCapacity: true)
        queuedReplayCaptureByteCount = 0
        queuedPageMarks.removeAll(keepingCapacity: true)
        recordingGeneration = nil
        replayCaptureDrainTask = nil
        markDrainTask?.cancel()
        markDrainTask = nil
        try? await coordinator.cancelStandardOperation()
        snapshot = .idle
        presentFailure(
            .replayCapture,
            retry: nil,
            error: error
        )
    }

    private func indexTranscript(
        _ payload: NotebookAudioTranscriptPayload,
        notebookID: NotebookID,
        operationGeneration: UUID
    ) async {
        guard let transcriptSearchIndexer else { return }
        guard let transcriptAssetID = sessions.first(where: {
            $0.id == payload.audioSessionID
        })?.transcriptAssetID else {
            do {
                try await performSearchIndexOperation(notebookID: notebookID) {
                    try await transcriptSearchIndexer.remove(
                        notebookID: notebookID,
                        sessionID: payload.audioSessionID
                    )
                }
                try ensureCurrent(operationGeneration, notebookID: notebookID)
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(operationGeneration, notebookID: notebookID) else { return }
                presentFailure(.searchIndex, retry: nil, error: error)
            }
            return
        }
        await indexTranscript(
            payload,
            notebookID: notebookID,
            transcriptAssetID: transcriptAssetID,
            operationGeneration: operationGeneration
        )
    }

    private func indexTranscript(
        _ payload: NotebookAudioTranscriptPayload,
        notebookID: NotebookID,
        transcriptAssetID: AssetID,
        operationGeneration: UUID
    ) async {
        guard let transcriptSearchIndexer else { return }
        do {
            try await performSearchIndexOperation(notebookID: notebookID) {
                try await transcriptSearchIndexer.index(
                    payload,
                    notebookID: notebookID,
                    transcriptAssetID: transcriptAssetID
                )
            }
            try ensureCurrent(operationGeneration, notebookID: notebookID)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrent(operationGeneration, notebookID: notebookID) else { return }
            presentFailure(
                .searchIndex,
                retry: .indexTranscript(notebookID, payload, transcriptAssetID),
                error: error
            )
        }
    }

    private func reconcileTranscriptSearch(
        notebookID: NotebookID,
        sessions: [AudioSessionDescriptor]
    ) async {
        guard let transcriptSearchIndexer else { return }
        do {
            try await performSearchIndexOperation(notebookID: notebookID) {
                try await transcriptSearchIndexer.reconcile(
                    notebookID: notebookID,
                    sessions: sessions
                )
            }
        } catch is CancellationError {
            return
        } catch {
            guard currentNotebookID == notebookID else { return }
            presentFailure(
                .searchIndex,
                retry: .reconcileSearch(notebookID),
                error: error
            )
        }
    }

    private func performSearchIndexOperation(
        notebookID: NotebookID,
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws {
        let requestGeneration = searchIndexGeneration
        try ensureCurrentSearchRequest(requestGeneration, notebookID: notebookID)
        let handle = try searchIndexOperationQueue.enqueue { [weak self] in
            guard let self else { throw CancellationError() }
            try self.ensureCurrentSearchRequest(requestGeneration, notebookID: notebookID)
            try await operation()
        }
        try await withTaskCancellationHandler {
            try await handle.wait()
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.searchIndexOperationQueue.cancel(handle)
            }
        }
        try ensureCurrentSearchRequest(requestGeneration, notebookID: notebookID)
    }

    private func cancelSearchIndexOperations() async {
        searchIndexOperationsAreEnabled = false
        searchIndexGeneration = UUID()
        await searchIndexOperationQueue.cancelAll()
    }

    private func ensureCurrentSearchRequest(
        _ generation: UUID,
        notebookID: NotebookID
    ) throws {
        try Task.checkCancellation()
        guard searchIndexOperationsAreEnabled,
              searchIndexGeneration == generation,
              currentNotebookID == notebookID else {
            throw CancellationError()
        }
    }

    private func resumeSearchIndexOperations() {
        guard !libraryRootChangeInProgress else { return }
        searchIndexOperationsAreEnabled = true
    }

    private func finishSessionLoadIfCurrent(_ generation: UUID) {
        if sessionLoadGeneration == generation {
            isLoadingSessions = false
        }
    }

    @discardableResult
    private func beginAction() -> UUID {
        let generation = UUID()
        actionGeneration = generation
        return generation
    }

    private func invalidateActions(preservingRecording: Bool = false) {
        actionGeneration = UUID()
        sessionLoadGeneration = UUID()
        isLoadingSessions = false
        markDrainTask?.cancel()
        markDrainTask = nil
        queuedPageMarks.removeAll(keepingCapacity: true)
        replayCaptureDrainTask?.cancel()
        replayCaptureDrainTask = nil
        queuedReplayCaptures.removeAll(keepingCapacity: true)
        queuedReplayCaptureByteCount = 0
        if !preservingRecording {
            recordingGeneration = nil
            pendingStartingPageID = nil
        }
    }

    private func isCurrent(_ generation: UUID, notebookID: NotebookID) -> Bool {
        actionGeneration == generation && currentNotebookID == notebookID
    }

    private func ensureCurrent(_ generation: UUID, notebookID: NotebookID) throws {
        try Task.checkCancellation()
        guard isCurrent(generation, notebookID: notebookID) else { throw CancellationError() }
    }

    private func presentFailure(
        _ context: FailureContext,
        retry: RetryAction?,
        error: Error
    ) {
        guard !(error is CancellationError) else { return }
        failureMessage = context.message
        retryAction = retry
    }

    private func clearFailure() {
        failureMessage = nil
        retryAction = nil
    }
}
