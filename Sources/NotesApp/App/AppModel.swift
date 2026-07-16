import Combine
import Foundation

#if canImport(NotesCore)
import NotesCore
#endif

#if canImport(NotesServices)
import NotesServices
#endif

enum InkSaveState: Equatable, Sendable {
    case idle
    case saving
    case saved
    case failed
}

enum EditorInkLoadResult: Equatable, Sendable {
    /// `nil` is a successfully loaded page with no PencilKit payload.
    case loaded(Data?)
    case failed
}

struct EditorSessionLease: Hashable, Sendable {
    let id: UUID
    let notebookID: UUID
    let libraryRootGeneration: UInt64
}

enum TextBlockAnchorPreparationError: Error, Equatable, Sendable {
    case sourceSnapshotUnavailable
    case editorSessionExpired
    case blockNotFound
    case blockNotCapturable
    case noteSaveFailed
    case sourceChanged
    case invalidSnapshot
}

extension TextBlockAnchorPreparationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .sourceSnapshotUnavailable:
            String(localized: "Exact source links are unavailable for this note.")
        case .editorSessionExpired:
            String(localized: "The note changed location or is no longer open. Return to the class and try again.")
        case .blockNotFound:
            String(localized: "That paragraph is no longer in this note.")
        case .blockNotCapturable:
            String(localized: "Choose a paragraph with text before adding a class marker.")
        case .noteSaveFailed:
            String(localized: "The note could not be saved, so no class marker was added.")
        case .sourceChanged:
            String(localized: "The paragraph changed while it was being saved. Review it and tap the marker again.")
        case .invalidSnapshot:
            String(localized: "The saved paragraph could not be verified. No class marker was added.")
        }
    }
}

/// `withThrowingTaskGroup` cannot implement a hard timeout when a child is
/// awaiting an uncooperative store write because the group must still drain
/// that child. This one-shot bridge resumes the root-transition caller at the
/// deadline while canceling (but not synchronously joining) the operation.
private final class RootOperationRace<Value: Sendable>: @unchecked Sendable {
    typealias Continuation = CheckedContinuation<Value, any Error>

    private let lock = NSLock()
    private var continuation: Continuation?
    private var result: Result<Value, any Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func installContinuation(_ continuation: Continuation) {
        let completed: Result<Value, any Error>?
        lock.lock()
        if let result {
            completed = result
        } else {
            self.continuation = continuation
            completed = nil
        }
        lock.unlock()
        if let completed {
            continuation.resume(with: completed)
        }
    }

    func installTasks(
        operation: Task<Void, Never>,
        timeout: Task<Void, Never>
    ) {
        let alreadyCompleted: Bool
        lock.lock()
        alreadyCompleted = result != nil
        if !alreadyCompleted {
            operationTask = operation
            timeoutTask = timeout
        }
        lock.unlock()
        if alreadyCompleted {
            operation.cancel()
            timeout.cancel()
        }
    }

    func resolve(
        _ result: Result<Value, any Error>,
        cancelOperation: Bool
    ) {
        let pendingContinuation: Continuation?
        let operationToCancel: Task<Void, Never>?
        let timeoutToCancel: Task<Void, Never>?
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        pendingContinuation = continuation
        continuation = nil
        operationToCancel = cancelOperation ? operationTask : nil
        timeoutToCancel = timeoutTask
        operationTask = nil
        timeoutTask = nil
        lock.unlock()

        operationToCancel?.cancel()
        timeoutToCancel?.cancel()
        pendingContinuation?.resume(with: result)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var destination: LibraryDestination = .documents
    @Published var displayMode: LibraryDisplayMode = .grid
    @Published var sortOrder: LibrarySortOrder = .modified
    @Published var searchText = ""
    @Published private(set) var notebooks: [LibraryNotebook] = []
    @Published private(set) var rootDescription = String(localized: "On My iPad")
    @Published private(set) var isLoading = false
    @Published private(set) var matchingNotebookIDs: Set<UUID>?
    @Published private(set) var searchTargetPageIDs: [UUID: UUID] = [:]
    @Published private(set) var backupFolderDescription = String(localized: "Not configured")
    @Published private(set) var backupSnapshots: [BackupSnapshot] = []
    @Published private(set) var isBackupOperationRunning = false
    @Published var notice: AppNotice?
    let notebookAudio: NotebookAudioPanelModel?

    private let noteReplayStore: (any NoteReplayStoreReading)?
    private let textDocumentSourceSnapshotProvider:
        (any TextDocumentSourceSnapshotProviding)?
    private let noteReplayPlaybackBroker: NotebookAudioReplayPlaybackBroker?
    private let academicRootCoordinator:
        (any AcademicLibraryRootCoordinating)?
    private let injectedNoteReplayControllerFactory:
        (@MainActor () -> NoteReplayController?)?

    private struct InkSaveKey: Hashable, Sendable {
        let notebookID: UUID
        let pageID: UUID
    }

    private struct PendingInkSave: Sendable {
        let data: Data
        let page: EditorPage
        let generation: UInt64
        let handwritingGeneration: UInt64
    }

    private enum InkWriteOutcome: Sendable {
        case success
        case failure(String)

        var succeeded: Bool {
            if case .success = self { return true }
            return false
        }
    }

    private struct ActiveInkWrite {
        let generation: UInt64
        let task: Task<InkWriteOutcome, Never>
    }

    private struct CanvasElementSaveKey: Hashable, Sendable {
        let notebookID: UUID
        let pageID: UUID
    }

    private struct PendingCanvasElementSave: Sendable {
        let elements: [CanvasElement]
        let generation: UInt64
    }

    private struct ActiveCanvasElementWrite {
        let generation: UInt64
        let task: Task<InkWriteOutcome, Never>
    }

    private struct PageContentSaveKey: Hashable, Sendable {
        let notebookID: UUID
        let pageID: UUID
    }

    private struct PendingPageContentSave: Sendable {
        let content: PageContent
        let generation: UInt64
    }

    private struct ActivePageContentWrite {
        let generation: UInt64
        let task: Task<InkWriteOutcome, Never>
    }

    private struct HandwritingRecognitionKey: Hashable, Sendable {
        let notebookID: UUID
        let pageID: UUID
    }

    private struct PageNavigationSearchKey: Hashable, Sendable {
        let notebookID: UUID
        let pageID: UUID
    }

    /// Ownership token for derived search work that must follow a durable
    /// whole-notebook save. It survives caller cancellation and can be handed
    /// from an interrupted old-root operation to failed-root rollback recovery.
    private struct WholeNotebookSearchRecovery: Sendable {
        let id: UUID
        let notebookID: UUID
        let claimedNavigationGenerations:
            [PageNavigationSearchKey: UInt64]
        let requiresTitleReindex: Bool
    }

    private struct HandwritingMutationContext: Sendable {
        let token: UUID
        let key: HandwritingRecognitionKey
        let libraryEpoch: UInt64
        let allowsLibraryRootChange: Bool
    }

    private struct LibraryOperationContext: Sendable {
        let token: UUID
        let libraryEpoch: UInt64
    }

    private let store: any NotesAppNotebookStore
    private let searchIndex: any SearchIndexing
    private let audioTranscriptSearchIndexer: any NotebookAudioTranscriptSearchIndexing
    private let audioTranscriptSearchRebuilder: NotebookAudioTranscriptSearchRebuilder?
    private let intelligence: LocalIntelligenceRouter
    private let pdfTextExtractor: PDFTextExtractor
    private let imageTextRecognizer: any TextRecognitionService
    private let handwritingRecognitionPipeline: HandwritingRecognitionPipeline
    private let backupService: any NotesBackupServicing
    private let preferences: UserDefaults
    private let libraryRootChangeTimeout: Duration
    private var backupDestination: BackupDestination?

    private static let backupBookmarkKey = "notes.backup.destinationBookmark"
    static let searchRootRebuildRequiredKey = "notes.search.rootRebuildRequired"

    private enum BootstrapPreparation: Equatable, Sendable {
        case none
        case rootTransition
        case recovery
    }

    private struct BootstrapAttempt {
        let id: UUID
        let task: Task<Void, Error>
    }

    private struct LibraryRootRollbackSnapshot {
        let notebooks: [LibraryNotebook]
        let rootDescription: String
        let wasBootstrapped: Bool
        let matchingNotebookIDs: Set<UUID>?
        let searchTargetPageIDs: [UUID: UUID]
        let searchIndexWasReady: Bool
    }

    private struct RootSearchRollbackRepairs {
        var handwriting: [HandwritingRecognitionKey: UInt64] = [:]
        var pageNavigation: [PageNavigationSearchKey: UInt64] = [:]
    }

    private var bootstrapAttempt: BootstrapAttempt?
    private var isBootstrapped = false
    @Published private var inkSaveStates: [InkSaveKey: InkSaveState] = [:]
    private var pendingInkSaves: [InkSaveKey: PendingInkSave] = [:]
    private var inkDebounceTasks: [InkSaveKey: Task<Void, Never>] = [:]
    private var activeInkWrites: [InkSaveKey: ActiveInkWrite] = [:]
    private var deferredRootTransitionInkSaves: [InkSaveKey: PendingInkSave] = [:]
    private var inkSaveGeneration: UInt64 = 0
    @Published private var canvasElementSaveStates: [CanvasElementSaveKey: InkSaveState] = [:]
    private var pendingCanvasElementSaves: [CanvasElementSaveKey: PendingCanvasElementSave] = [:]
    private var canvasElementDebounceTasks: [CanvasElementSaveKey: Task<Void, Never>] = [:]
    private var activeCanvasElementWrites: [CanvasElementSaveKey: ActiveCanvasElementWrite] = [:]
    private var deferredRootTransitionCanvasElementSaves:
        [CanvasElementSaveKey: PendingCanvasElementSave] = [:]
    private var canvasElementSaveGeneration: UInt64 = 0
    private var canvasSearchPublicationClock: UInt64 = 0
    private var canvasSearchPublicationGenerations: [CanvasElementSaveKey: UInt64] = [:]
    private var notebookTitleSearchPublicationClock: UInt64 = 0
    private var pageNavigationSearchPublicationClock: UInt64 = 0
    private var pageNavigationSearchPublicationGenerations:
        [PageNavigationSearchKey: UInt64] = [:]
    /// Records the latest generation whose desired navigation payload (including
    /// desired absence) was observed in the index. A stale physical write may
    /// safely trigger a repair only when the newer owner has already completed.
    private var reconciledPageNavigationSearchPublicationGenerations:
        [PageNavigationSearchKey: UInt64] = [:]
    /// A stale generation records the newer owner here after its already-sent
    /// index side effect completes. If that owner is between final verification
    /// and authorization, it will hand off to a fresh repair instead of exposing
    /// a payload whose physical index state may already have changed.
    private var pageNavigationSearchRepairRequiredGenerations:
        [PageNavigationSearchKey: UInt64] = [:]
    private var pendingWholeNotebookSearchRecoveries:
        [UUID: WholeNotebookSearchRecovery] = [:]
    @Published private var pageContentSaveStates: [PageContentSaveKey: InkSaveState] = [:]
    private var pendingPageContentSaves: [PageContentSaveKey: PendingPageContentSave] = [:]
    private var pageContentDebounceTasks: [PageContentSaveKey: Task<Void, Never>] = [:]
    private var activePageContentWrites: [PageContentSaveKey: ActivePageContentWrite] = [:]
    private var deferredRootTransitionPageContentSaves:
        [PageContentSaveKey: PendingPageContentSave] = [:]
    private var pageContentSaveGeneration: UInt64 = 0
    private var handwritingOperationClock: UInt64 = 0
    private var handwritingOperationGenerations: [HandwritingRecognitionKey: UInt64] = [:]
    @Published private var activeHandwritingRecognitionKeys: Set<HandwritingRecognitionKey> = []
    private var libraryEpoch: UInt64 = 1
    private var libraryRootGeneration: UInt64 = 1
    @Published private(set) var isLibraryRootChangeInProgress = false
    private var isInstallingLibraryRoot = false
    private var didStagePageMutationDuringLibraryRootChange = false
    private var activeLibraryOperations: [UUID: UInt64] = [:]
    private var activeNotebookExportOperations:
        [NotebookExportSession: LibraryOperationContext] = [:]
    private var activeEditorSessions: [UUID: EditorSessionLease] = [:]
    private var activeHandwritingMutations: [UUID: HandwritingRecognitionKey] = [:]
    /// Privacy fence for stale or unverified handwriting index documents.
    /// Entries leave this set only after the authoritative accepted payload is
    /// observed in the search index.
    private var suppressedHandwritingSearchDocumentIDs: Set<UUID> = []
    /// A page-navigation document is hidden as soon as its durable metadata may
    /// change. Only a verified nonempty authoritative payload is made visible;
    /// desired absence remains a logical tombstone against late publications.
    private var suppressedPageNavigationSearchDocumentIDs: Set<UUID> = []
    /// Positive authority binds a navigation hit to its title, fingerprint and
    /// exact segment. Orphans and late writes remain invisible even when their
    /// IDs were not known early enough to enter the suppression blacklist.
    private var authorizedPageNavigationSearchDocuments:
        [UUID: SearchIndexDocument] = [:]
    private var isSearchIndexReadyForCurrentRoot = true
    private var searchPublicationGeneration: UInt64 = 0
    private var rootSearchRebuildGeneration: UUID?
    private var rootSearchRebuildTask: Task<Void, Never>?

    var isBackupConfigured: Bool { backupDestination != nil }

    init(
        store: (any NotesAppNotebookStore)? = nil,
        academicRootCoordinator:
            (any AcademicLibraryRootCoordinating)? = nil,
        searchIndex: (any SearchIndexing)? = nil,
        backupService: (any NotesBackupServicing)? = nil,
        preferences: UserDefaults = .standard,
        notebookAudio: NotebookAudioPanelModel? = nil,
        imageTextRecognizer: (any TextRecognitionService)? = nil,
        handwritingTextRecognizer: (any TextRecognitionService)? = nil,
        noteReplayControllerFactory:
            (@MainActor () -> NoteReplayController?)? = nil,
        libraryRootChangeTimeout: Duration = .seconds(30)
    ) {
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let resolvedSearchIndex = searchIndex ?? LocalSearchIndex(
            persistenceURL: cacheRoot.appendingPathComponent("Notes/Search/search-index.json")
        )
        self.searchIndex = resolvedSearchIndex
        audioTranscriptSearchIndexer = NotebookAudioTranscriptSearchIndexer(
            searchIndex: resolvedSearchIndex
        )
        intelligence = LocalIntelligenceRouter()
        pdfTextExtractor = PDFTextExtractor()
        self.imageTextRecognizer = imageTextRecognizer ?? VisionTextRecognitionService()
        handwritingRecognitionPipeline = HandwritingRecognitionPipeline(
            textRecognizer: handwritingTextRecognizer
        )
        self.backupService = backupService ?? FileBackupService()
        self.preferences = preferences
        isSearchIndexReadyForCurrentRoot = !preferences.bool(
            forKey: Self.searchRootRebuildRequiredKey
        )
        self.libraryRootChangeTimeout = libraryRootChangeTimeout > .zero
            ? libraryRootChangeTimeout
            : .milliseconds(1)

        let resolvedStore: any NotesAppNotebookStore
        if let store {
            resolvedStore = store
        } else {
            resolvedStore = LocalNotebookStore.makeForCurrentProcess()
        }
        self.store = resolvedStore
        self.academicRootCoordinator = academicRootCoordinator
        noteReplayStore = resolvedStore as? any NoteReplayStoreReading
        textDocumentSourceSnapshotProvider =
            resolvedStore as? any TextDocumentSourceSnapshotProviding
        injectedNoteReplayControllerFactory = noteReplayControllerFactory

        if let audioSessionListing = resolvedStore as? any NotebookAudioSessionListing,
           let transcriptLoading = resolvedStore as? any NotebookAudioTranscriptLoading {
            audioTranscriptSearchRebuilder = NotebookAudioTranscriptSearchRebuilder(
                sessionListing: audioSessionListing,
                transcriptLoading: transcriptLoading,
                searchIndexer: audioTranscriptSearchIndexer
            )
        } else {
            audioTranscriptSearchRebuilder = nil
        }

        if let notebookAudio {
            self.notebookAudio = notebookAudio
            noteReplayPlaybackBroker = nil
        } else if let audioPersistence = resolvedStore as? any NotebookAudioPersisting,
                  let audioSessionListing = resolvedStore as? any NotebookAudioSessionListing {
            let audioCoordinator = NotebookAudioCoordinator(persistence: audioPersistence)
            self.notebookAudio = NotebookAudioPanelModel(
                coordinator: audioCoordinator,
                sessionListing: audioSessionListing,
                transcriptSearchIndexer: audioTranscriptSearchIndexer
            )
            noteReplayPlaybackBroker = NotebookAudioReplayPlaybackBroker(
                coordinator: audioCoordinator
            )
        } else {
            // Lightweight test stores are not forced to implement media I/O.
            self.notebookAudio = nil
            noteReplayPlaybackBroker = nil
        }

        if let bookmark = preferences.data(forKey: Self.backupBookmarkKey) {
            let destination = BackupDestination(bookmarkData: bookmark)
            backupDestination = destination
            backupFolderDescription = (try? destination.resolve().lastPathComponent)
                ?? String(localized: "Permission expired")
        }
    }

    /// Creates editor-owned Replay state while retaining one app-wide audio
    /// coordinator and ownership broker. Lightweight stores intentionally have
    /// no Replay factory unless a test or preview injects one explicitly.
    @MainActor
    func makeNoteReplayController() -> NoteReplayController? {
        if let injectedNoteReplayControllerFactory {
            return injectedNoteReplayControllerFactory()
        }
        guard let noteReplayStore, let noteReplayPlaybackBroker else {
            return nil
        }
        return NoteReplayController(
            audioTransport: NotebookAudioReplayTransport(
                broker: noteReplayPlaybackBroker
            ),
            dataSource: LocalNoteReplayDataSource(store: noteReplayStore)
        )
    }

    /// Root changes use a conservative close-before-switch policy. Keeping the
    /// lease until an editor's final flush finishes is stronger than trying to
    /// infer whether a queued UIKit/PencilKit callback has acknowledged a
    /// transient disabled state across multiple windows.
    func beginEditorSession(notebookID: UUID) -> EditorSessionLease? {
        guard !isLibraryRootChangeInProgress else { return nil }
        let lease = EditorSessionLease(
            id: UUID(),
            notebookID: notebookID,
            libraryRootGeneration: libraryRootGeneration
        )
        activeEditorSessions[lease.id] = lease
        return lease
    }

    func endEditorSession(_ lease: EditorSessionLease) {
        guard activeEditorSessions[lease.id] == lease else { return }
        activeEditorSessions.removeValue(forKey: lease.id)
    }

    private func isCurrentEditorSession(
        _ lease: EditorSessionLease,
        notebookID: UUID
    ) -> Bool {
        lease.notebookID == notebookID
            && lease.libraryRootGeneration == libraryRootGeneration
            && activeEditorSessions[lease.id] == lease
            && !isLibraryRootChangeInProgress
    }

    private func canBeginEditorStructuralMutation(
        notebookID: UUID,
        editorSession: EditorSessionLease?,
        allowsUnleasedTestingMutation: Bool
    ) -> Bool {
        guard !Task.isCancelled else { return false }
        if allowsUnleasedTestingMutation {
            return !isLibraryRootChangeInProgress
        }
        guard let editorSession else { return false }
        return isCurrentEditorSession(editorSession, notebookID: notebookID)
    }

    private func requireCurrentEditorStructuralMutation(
        notebookID: UUID,
        editorSession: EditorSessionLease?,
        allowsUnleasedTestingMutation: Bool
    ) throws {
        try Task.checkCancellation()
        if allowsUnleasedTestingMutation { return }
        guard let editorSession,
              isCurrentEditorSession(editorSession, notebookID: notebookID) else {
            throw CancellationError()
        }
    }

    var visibleNotebooks: [LibraryNotebook] {
        let scoped = notebooks.filter { notebook in
            switch destination {
            case .courses: false
            case .documents: notebook.deletedAt == nil
            case .favorites: notebook.deletedAt == nil && notebook.isFavorite
            case .trash: notebook.deletedAt != nil
            case .settings: false
            }
        }
        let searched: [LibraryNotebook]
        let query = searchText.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if query.isEmpty {
            searched = scoped
        } else if PageNavigationSearchQueryPolicy.isExactBookmarkQuery(query) {
            searched = scoped.filter {
                matchingNotebookIDs?.contains($0.id) ?? false
            }
        } else {
            searched = scoped.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || (matchingNotebookIDs?.contains($0.id) ?? false)
            }
        }

        return searched.sorted { lhs, rhs in
            switch sortOrder {
            case .modified: lhs.modifiedAt > rhs.modifiedAt
            case .created: lhs.createdAt > rhs.createdAt
            case .title: lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    func load() async {
        do {
            try await ensureBootstrapped()
        } catch is CancellationError {
            return
        } catch {
            show(error)
        }
    }

    @discardableResult
    func createNotebook(
        title: String,
        kind: NotebookKind = .notebook,
        template: PaperTemplate = .blank
    ) async -> LibraryNotebook? {
        guard let libraryOperation = beginLibraryOperation() else {
            show(LibraryRootChangeError.changeInProgress)
            return nil
        }
        defer { finishLibraryOperation(libraryOperation) }
        do {
            try await ensureBootstrapped()
            let notebook = try await store.createNotebook(title: title, kind: kind, template: template)
            await upsert(notebook.summary)
            return notebook.summary
        } catch {
            if error is CancellationError { return nil }
            show(error)
            return nil
        }
    }

    /// Ensures the deterministic Notes object reserved by Session start.
    ///
    /// The request owns both identifiers, so a caller can safely replay it
    /// after cancellation or an ambiguous storage response without creating a
    /// second note.
    @discardableResult
    func ensureSessionTextNote(
        _ request: SessionTextNoteRequest
    ) async -> CreatedSessionTextNote? {
        guard let libraryOperation = beginLibraryOperation() else {
            show(LibraryRootChangeError.changeInProgress)
            return nil
        }
        defer { finishLibraryOperation(libraryOperation) }

        do {
            try await ensureBootstrapped()
            try requireCurrentLibraryOperation(libraryOperation)
            guard let sessionTextNoteStore = store as? any SessionTextNoteStoring else {
                throw SessionTextNoteStoreError.unsupportedStore
            }
            let notebook = try await sessionTextNoteStore.ensureSessionTextNote(
                request
            )
            try requireCurrentLibraryOperation(libraryOperation)
            guard notebook.id == request.notebookID,
                  notebook.kind == .textDocument,
                  notebook.deletedAt == nil,
                  notebook.pages.contains(where: {
                      $0.id == request.initialPageID && $0.kind == .textDocument
                  }) else {
                throw SessionTextNoteStoreError.notebookConflict
            }
            await upsert(notebook.summary)
            try requireCurrentLibraryOperation(libraryOperation)
            return CreatedSessionTextNote(
                notebook: notebook.summary,
                initialPageID: request.initialPageID
            )
        } catch is CancellationError {
            return nil
        } catch {
            show(error)
            return nil
        }
    }

    @discardableResult
    func createQuickNote() async -> LibraryNotebook? {
        await createNotebook(
            title: String(localized: "Quick Note"),
            kind: .quickNote,
            template: .blank
        )
    }

    func importDocuments(_ urls: [URL]) async -> [LibraryNotebook] {
        guard let libraryOperation = beginLibraryOperation() else {
            show(LibraryRootChangeError.changeInProgress)
            return []
        }
        defer { finishLibraryOperation(libraryOperation) }
        do {
            try await ensureBootstrapped()
        } catch {
            show(error)
            return []
        }
        var imported: [LibraryNotebook] = []
        for url in urls {
            var importedNavigationGenerations:
                [PageNavigationSearchKey: UInt64] = [:]
            do {
                let notebook = try await store.importDocument(at: url)
                let importedNavigationKeys = notebook.pages.map {
                    PageNavigationSearchKey(
                        notebookID: notebook.id,
                        pageID: $0.id
                    )
                }
                var didSuppressImportedNavigationSearch = false
                for key in importedNavigationKeys {
                    importedNavigationGenerations[key] =
                        beginPageNavigationSearchPublication(for: key)
                    didSuppressImportedNavigationSearch =
                        suppressPageNavigationSearchDocument(for: key)
                        || didSuppressImportedNavigationSearch
                }
                if didSuppressImportedNavigationSearch {
                    schedulePublishedSearchRefresh()
                }
                do {
                    try requireCurrentLibraryOperation(libraryOperation)
                } catch is CancellationError {
                    // The import is already durable on the old root. Publish
                    // enough authority for a failed root switch to snapshot and
                    // repair it; a successful switch replaces this UI state
                    // during candidate bootstrap and clears the search fence.
                    await upsert(notebook.summary)
                    if !isLibraryRootChangeInProgress {
                        schedulePageNavigationSearchRepairs(
                            ownedGenerations: importedNavigationGenerations,
                            expectedLibraryEpoch: libraryEpoch
                        )
                    }
                    throw CancellationError()
                }
                await upsert(notebook.summary)
                try requireCurrentLibraryOperation(libraryOperation)
                await repairPageNavigationSearchAfterWholeNotebookSave(
                    notebookID: notebook.id,
                    knownPageIDs: notebook.pages.map(\.id),
                    expectedLibraryEpoch: libraryOperation.libraryEpoch
                )
                try requireCurrentLibraryOperation(libraryOperation)
                let authoritativeNotebook = try await store.loadNotebook(
                    id: notebook.id
                )
                try requireCurrentLibraryOperation(libraryOperation)
                await reindexStructuredPages(in: authoritativeNotebook)
                try requireCurrentLibraryOperation(libraryOperation)
                await reindexCanvasElements(in: authoritativeNotebook)
                try requireCurrentLibraryOperation(libraryOperation)
                await reindexHandwritingRecognition(in: authoritativeNotebook)
                try requireCurrentLibraryOperation(libraryOperation)
                imported.append(authoritativeNotebook.summary)
            } catch is CancellationError {
                schedulePageNavigationSearchRepairs(
                    ownedGenerations: importedNavigationGenerations,
                    expectedLibraryEpoch: libraryOperation.libraryEpoch
                )
                break
            } catch {
                show(error)
            }
        }
        if !imported.isEmpty {
            notice = AppNotice(
                kind: .information,
                title: String(localized: "Import complete"),
                message: String(localized: "Your document is ready to annotate.")
            )
        }
        return imported
    }

    func searchIndexedContent() async {
        searchPublicationGeneration &+= 1
        if searchPublicationGeneration == 0 { searchPublicationGeneration = 1 }
        let publicationGeneration = searchPublicationGeneration
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            matchingNotebookIDs = nil
            searchTargetPageIDs = [:]
            return
        }
        guard isSearchIndexReadyForCurrentRoot,
              !isLibraryRootChangeInProgress else {
            matchingNotebookIDs = []
            searchTargetPageIDs = [:]
            retryCommittedRootSearchRebuildIfNeeded()
            return
        }
        let expectedLibraryEpoch = libraryEpoch
        let expectedRootGeneration = libraryRootGeneration
        let indexedHits = await searchIndex.query(query, notebookID: nil, limit: 100)
        guard publicationGeneration == searchPublicationGeneration,
              expectedLibraryEpoch == libraryEpoch,
              expectedRootGeneration == libraryRootGeneration,
              isSearchIndexReadyForCurrentRoot,
              !isLibraryRootChangeInProgress else { return }
        var hits: [LocalSearchHit] = []
        hits.reserveCapacity(indexedHits.count)
        for hit in indexedHits {
            guard !suppressedHandwritingSearchDocumentIDs.contains(
                    hit.documentID
                  ), !suppressedPageNavigationSearchDocumentIDs.contains(
                    hit.documentID
                  ) else { continue }
            guard isAuthorizedPageNavigationSearchHit(
                    documentID: hit.documentID,
                    notebookID: hit.notebookID,
                    pageID: hit.pageID,
                    title: hit.title,
                    segment: hit.segment,
                    sourceFingerprint: hit.sourceFingerprint
                  ), !suppressedHandwritingSearchDocumentIDs.contains(
                    hit.documentID
                  ), !suppressedPageNavigationSearchDocumentIDs.contains(
                    hit.documentID
                  ) else { continue }
            hits.append(hit)
        }
        guard publicationGeneration == searchPublicationGeneration,
              expectedLibraryEpoch == libraryEpoch,
              expectedRootGeneration == libraryRootGeneration,
              isSearchIndexReadyForCurrentRoot,
              !isLibraryRootChangeInProgress,
              query == searchText.trimmingCharacters(
                in: .whitespacesAndNewlines
              ) else {
            return
        }
        matchingNotebookIDs = Set(hits.map(\.notebookID))
        searchTargetPageIDs = hits.reduce(into: [:]) { targets, hit in
            if targets[hit.notebookID] == nil, let pageID = hit.pageID {
                targets[hit.notebookID] = pageID
            }
        }
    }

    func searchNotebookContent(
        _ text: String,
        notebookID: UUID,
        limit: Int = 200
    ) async -> [LocalSearchSegmentHit] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, limit > 0 else { return [] }
        do {
            try await ensureBootstrapped()
        } catch {
            show(error)
            return []
        }
        guard isSearchIndexReadyForCurrentRoot,
              !isLibraryRootChangeInProgress else {
            retryCommittedRootSearchRebuildIfNeeded()
            return []
        }
        let expectedLibraryEpoch = libraryEpoch
        let expectedRootGeneration = libraryRootGeneration
        let hits = await searchIndex.querySegments(
            query,
            notebookID: notebookID,
            limit: limit
        )
        guard expectedLibraryEpoch == libraryEpoch,
              expectedRootGeneration == libraryRootGeneration,
              isSearchIndexReadyForCurrentRoot,
              !isLibraryRootChangeInProgress else { return [] }
        var authorizedHits: [LocalSearchSegmentHit] = []
        authorizedHits.reserveCapacity(hits.count)
        for hit in hits {
            guard !suppressedHandwritingSearchDocumentIDs.contains(
                    hit.id.documentID
                  ), !suppressedPageNavigationSearchDocumentIDs.contains(
                    hit.id.documentID
                  ) else { continue }
            guard isAuthorizedPageNavigationSearchHit(
                    documentID: hit.id.documentID,
                    notebookID: hit.notebookID,
                    pageID: hit.pageID,
                    title: hit.title,
                    segment: hit.segment,
                    sourceFingerprint: hit.sourceFingerprint
                  ), !suppressedHandwritingSearchDocumentIDs.contains(
                    hit.id.documentID
                  ), !suppressedPageNavigationSearchDocumentIDs.contains(
                    hit.id.documentID
                  ) else { continue }
            authorizedHits.append(hit)
        }
        guard expectedLibraryEpoch == libraryEpoch,
              expectedRootGeneration == libraryRootGeneration,
              isSearchIndexReadyForCurrentRoot,
              !isLibraryRootChangeInProgress else { return [] }
        return authorizedHits
    }

    func extractText(notebookID: UUID, page: EditorPage) async -> String? {
        guard let libraryOperation = beginLibraryOperation() else {
            show(LibraryRootChangeError.changeInProgress)
            return nil
        }
        defer { finishLibraryOperation(libraryOperation) }
        do {
            try await ensureBootstrapped()
            try requireCurrentLibraryOperation(libraryOperation)
            let resolved = await resolveBackground(notebookID: notebookID, page: page)
            try requireCurrentLibraryOperation(libraryOperation)
            guard let assetURL = resolved.assetURL else {
                throw NoteToolError.backgroundTextUnavailable
            }
            let data = try await Task.detached(priority: .utility) {
                try Data(contentsOf: assetURL, options: .mappedIfSafe)
            }.value
            try requireCurrentLibraryOperation(libraryOperation)

            let segments: [RecognizedTextSegment]
            switch page.background {
            case .paper:
                throw NoteToolError.backgroundTextUnavailable
            case .pdf(_, let pageIndex):
                do {
                    segments = [try await pdfTextExtractor.extract(
                        data: data,
                        pageIndex: pageIndex,
                        pageID: page.id
                    )]
                } catch PDFTextExtractionError.emptyDocument {
                    let renderedPage = try await pdfTextExtractor.renderPageImage(
                        data: data,
                        pageIndex: pageIndex
                    )
                    segments = try await imageTextRecognizer.recognize(
                        imageData: renderedPage,
                        orientation: .up,
                        languages: ["zh-Hant", "en-US"],
                        pageID: page.id
                    )
                }
            case .image:
                segments = try await imageTextRecognizer.recognize(
                    imageData: data,
                    orientation: .up,
                    languages: ["zh-Hant", "en-US"],
                    pageID: page.id
                )
            }

            try requireCurrentLibraryOperation(libraryOperation)
            guard !segments.isEmpty else { throw NoteToolError.noReadableText }
            let title = notebooks.first(where: { $0.id == notebookID })?.title ?? String(localized: "Untitled")
            let revision = try await nextSearchRevision(for: page.id)
            try requireCurrentLibraryOperation(libraryOperation)
            do {
                try await searchIndex.upsertUsingCurrentNotebookTitle(
                    SearchIndexDocument(
                        id: page.id,
                        notebookID: notebookID,
                        pageID: page.id,
                        title: title,
                        revision: revision,
                        segments: segments
                    )
                )
                try requireCurrentLibraryOperation(libraryOperation)
            } catch {
                try requireCurrentLibraryOperation(libraryOperation)
                // Text extraction still succeeded. Keep the derived-index failure
                // visible without presenting the durable note operation as failed.
                show(error)
            }
            if !searchText.isEmpty { await searchIndexedContent() }
            return segments.map(\.text).joined(separator: "\n")
        } catch {
            if error is CancellationError { return nil }
            show(error)
            return nil
        }
    }

    func handwritingRecognitionSnapshot(
        notebookID: UUID,
        pageID: UUID
    ) async -> HandwritingRecognitionSnapshot? {
        guard !isLibraryRootChangeInProgress else {
            show(HandwritingReviewError.libraryLocationChanging)
            return nil
        }
        let expectedLibraryEpoch = libraryEpoch
        do {
            try await ensureBootstrapped()
            guard isCurrentLibraryEpoch(expectedLibraryEpoch) else {
                throw CancellationError()
            }
            guard let document = try await store.loadHandwritingRecognition(
                notebookID: notebookID,
                pageID: pageID
            ) else { return nil }
            guard isCurrentLibraryEpoch(expectedLibraryEpoch) else {
                throw CancellationError()
            }
            let inkKey = InkSaveKey(notebookID: notebookID, pageID: pageID)
            if let pendingInk = pendingInkSaves[inkKey]?.data {
                return HandwritingRecognitionSnapshot(
                    document: document,
                    isCurrentForInk:
                        HandwritingRecognitionPipeline.sourceInkSHA256(for: pendingInk)
                            == document.sourceInkSHA256
                )
            }
            if activeInkWrites[inkKey] != nil {
                return HandwritingRecognitionSnapshot(
                    document: document,
                    isCurrentForInk: false
                )
            }
            let ink = try await store.loadInkForHandwritingRecognition(
                notebookID: notebookID,
                pageID: pageID
            )
            guard isCurrentLibraryEpoch(expectedLibraryEpoch) else {
                throw CancellationError()
            }
            let isCurrent = ink.map {
                HandwritingRecognitionPipeline.sourceInkSHA256(for: $0)
                    == document.sourceInkSHA256
            } ?? false
            return HandwritingRecognitionSnapshot(
                document: document,
                isCurrentForInk: isCurrent
            )
        } catch is CancellationError {
            return nil
        } catch {
            show(error)
            return nil
        }
    }

    /// Runs the bounded on-device fallback recognizer against the latest
    /// durable PencilKit payload. The sidecar CAS and ink digest close both
    /// page-switch and edit-during-recognition races.
    func recognizeHandwriting(
        notebookID: UUID,
        page: EditorPage,
        languages: [String] = ["zh-Hant", "en-US"]
    ) async -> HandwritingRecognitionSnapshot? {
        let key = HandwritingRecognitionKey(
            notebookID: notebookID,
            pageID: page.id
        )
        guard let mutation = beginHandwritingMutation(for: key) else {
            show(HandwritingReviewError.libraryLocationChanging)
            return nil
        }
        defer { finishHandwritingMutation(mutation) }
        guard activeHandwritingRecognitionKeys.insert(key).inserted else {
            show(HandwritingReviewError.alreadyRecognizing)
            return nil
        }
        defer { activeHandwritingRecognitionKeys.remove(key) }
        var operationGeneration: UInt64?
        do {
            try await ensureBootstrapped()
            try requireCurrentHandwritingMutation(mutation)
            guard Self.supportsHandwritingRecognition(page.kind) else {
                throw HandwritingReviewError.unsupportedPage
            }
            guard await flushInk(notebookID: notebookID, pageID: page.id) else {
                show(InkPersistenceError.flushRequired)
                return nil
            }
            try requireCurrentHandwritingMutation(mutation)
            let generation = beginHandwritingOperation(for: key)
            operationGeneration = generation
            let existing = try await store.loadHandwritingRecognition(
                notebookID: notebookID,
                pageID: page.id
            )
            try requireCurrentHandwritingMutation(mutation)
            guard isCurrentHandwritingOperation(generation, for: key) else {
                throw CancellationError()
            }
            guard let ink = try await store.loadInkForHandwritingRecognition(
                notebookID: notebookID,
                pageID: page.id
            ) else {
                throw HandwritingReviewError.missingInk
            }
            try requireCurrentHandwritingMutation(mutation)
            let recognized = try await handwritingRecognitionPipeline.recognize(
                drawingData: ink,
                pageSize: CGSize(width: page.width, height: page.height),
                pageID: PageID(page.id),
                languages: languages
            )
            try Task.checkCancellation()
            try requireCurrentHandwritingMutation(mutation)
            guard isCurrentHandwritingOperation(generation, for: key) else {
                throw CancellationError()
            }
            let nextRevision = try Self.nextHandwritingRevision(after: existing?.revision)
            var modifiedAt = max(Date(), recognized.generatedAt)
            if let existing, existing.modifiedAt > modifiedAt {
                modifiedAt = existing.modifiedAt
            }
            let replacement = HandwritingRecognitionDocument(
                schemaVersion: recognized.schemaVersion,
                runID: recognized.runID,
                pageID: recognized.pageID,
                sourceInkSHA256: recognized.sourceInkSHA256,
                engineIdentifier: recognized.engineIdentifier,
                engineRevision: recognized.engineRevision,
                languages: recognized.languages,
                generatedAt: recognized.generatedAt,
                revision: nextRevision,
                modifiedAt: modifiedAt,
                machineCandidates: recognized.machineCandidates,
                reviews: []
            )
            try Task.checkCancellation()
            try requireCurrentHandwritingMutation(mutation)
            guard isCurrentHandwritingOperation(generation, for: key) else {
                throw CancellationError()
            }
            if suppressHandwritingSearchDocument(
                HandwritingSearchBuilder.documentID(
                    notebookID: notebookID,
                    pageID: page.id
                )
            ) {
                schedulePublishedSearchRefresh()
            }
            try await store.saveHandwritingRecognition(
                replacement,
                notebookID: notebookID,
                pageID: page.id,
                expectedRunID: existing?.runID,
                expectedRevision: existing?.revision
            )
            try requireCurrentHandwritingMutation(mutation)
            if Task.isCancelled {
                if isCurrentHandwritingOperation(generation, for: key) {
                    scheduleHandwritingSearchRepair(
                        for: key,
                        publicationGeneration: generation,
                        expectedLibraryEpoch: mutation.libraryEpoch
                    )
                }
                return nil
            }
            guard isCurrentHandwritingOperation(generation, for: key) else {
                throw CancellationError()
            }
            await indexHandwritingRecognition(
                replacement,
                notebookID: notebookID,
                pageID: page.id,
                publicationGeneration: generation
            )
            try requireCurrentHandwritingMutation(mutation)
            guard isCurrentHandwritingOperation(generation, for: key) else {
                throw CancellationError()
            }
            return HandwritingRecognitionSnapshot(
                document: replacement,
                isCurrentForInk: true
            )
        } catch is CancellationError {
            return nil
        } catch {
            if let operationGeneration,
               isCurrentHandwritingOperation(operationGeneration, for: key),
               isCurrentLibraryEpoch(mutation.libraryEpoch) {
                await repairHandwritingSearch(
                    for: key,
                    publicationGeneration: operationGeneration,
                    expectedLibraryEpoch: mutation.libraryEpoch
                )
            }
            show(error)
            return nil
        }
    }

    func isHandwritingRecognitionRunning(
        notebookID: UUID,
        pageID: UUID
    ) -> Bool {
        activeHandwritingRecognitionKeys.contains(HandwritingRecognitionKey(
            notebookID: notebookID,
            pageID: pageID
        ))
    }

    /// `decision == nil` returns a candidate to pending review. Corrections are
    /// stored separately and never mutate the machine suggestion.
    func updateHandwritingReview(
        notebookID: UUID,
        pageID: UUID,
        candidateID: UUID,
        decision: HandwritingReviewDecision?,
        correctedText: String?
    ) async -> HandwritingRecognitionSnapshot? {
        let key = HandwritingRecognitionKey(
            notebookID: notebookID,
            pageID: pageID
        )
        guard let mutation = beginHandwritingMutation(for: key) else {
            show(HandwritingReviewError.libraryLocationChanging)
            return nil
        }
        defer { finishHandwritingMutation(mutation) }
        var operationGeneration: UInt64?
        do {
            try await ensureBootstrapped()
            try requireCurrentHandwritingMutation(mutation)
            guard await flushInk(notebookID: notebookID, pageID: pageID) else {
                show(InkPersistenceError.flushRequired)
                return nil
            }
            try requireCurrentHandwritingMutation(mutation)
            let generation = beginHandwritingOperation(for: key)
            operationGeneration = generation
            guard let current = try await store.loadHandwritingRecognition(
                notebookID: notebookID,
                pageID: pageID
            ) else {
                throw HandwritingReviewError.missingRecognition
            }
            try requireCurrentHandwritingMutation(mutation)
            guard current.machineCandidates.contains(where: { $0.id == candidateID }) else {
                throw HandwritingReviewError.missingCandidate
            }
            guard let ink = try await store.loadInkForHandwritingRecognition(
                notebookID: notebookID,
                pageID: pageID
            ), HandwritingRecognitionPipeline.sourceInkSHA256(for: ink)
                == current.sourceInkSHA256 else {
                throw HandwritingReviewError.staleInk
            }
            try requireCurrentHandwritingMutation(mutation)
            guard isCurrentHandwritingOperation(generation, for: key) else {
                throw CancellationError()
            }

            var reviews = current.reviews.filter { $0.candidateID != candidateID }
            let now = max(Date(), current.modifiedAt)
            if let decision {
                let correction: String?
                if decision == .accepted,
                   let correctedText,
                   !correctedText.trimmingCharacters(
                       in: .whitespacesAndNewlines
                   ).isEmpty {
                    correction = correctedText
                } else {
                    correction = nil
                }
                reviews.append(HandwritingCandidateReview(
                    candidateID: candidateID,
                    decision: decision,
                    correctedText: correction,
                    reviewedAt: now
                ))
            }
            let replacement = HandwritingRecognitionDocument(
                schemaVersion: current.schemaVersion,
                runID: current.runID,
                pageID: current.pageID,
                sourceInkSHA256: current.sourceInkSHA256,
                engineIdentifier: current.engineIdentifier,
                engineRevision: current.engineRevision,
                languages: current.languages,
                generatedAt: current.generatedAt,
                revision: try Self.nextHandwritingRevision(after: current.revision),
                modifiedAt: now,
                machineCandidates: current.machineCandidates,
                reviews: reviews
            )
            try Task.checkCancellation()
            try requireCurrentHandwritingMutation(mutation)
            guard isCurrentHandwritingOperation(generation, for: key) else {
                throw CancellationError()
            }
            if suppressHandwritingSearchDocument(
                HandwritingSearchBuilder.documentID(
                    notebookID: notebookID,
                    pageID: pageID
                )
            ) {
                schedulePublishedSearchRefresh()
            }
            try await store.saveHandwritingRecognition(
                replacement,
                notebookID: notebookID,
                pageID: pageID,
                expectedRunID: current.runID,
                expectedRevision: current.revision
            )
            try requireCurrentHandwritingMutation(mutation)
            if Task.isCancelled {
                if isCurrentHandwritingOperation(generation, for: key) {
                    scheduleHandwritingSearchRepair(
                        for: key,
                        publicationGeneration: generation,
                        expectedLibraryEpoch: mutation.libraryEpoch
                    )
                }
                return nil
            }
            guard isCurrentHandwritingOperation(generation, for: key) else {
                throw CancellationError()
            }
            await indexHandwritingRecognition(
                replacement,
                notebookID: notebookID,
                pageID: pageID,
                publicationGeneration: generation
            )
            try requireCurrentHandwritingMutation(mutation)
            guard isCurrentHandwritingOperation(generation, for: key) else {
                throw CancellationError()
            }
            return HandwritingRecognitionSnapshot(
                document: replacement,
                isCurrentForInk: true
            )
        } catch is CancellationError {
            return nil
        } catch {
            if let operationGeneration,
               isCurrentHandwritingOperation(operationGeneration, for: key),
               isCurrentLibraryEpoch(mutation.libraryEpoch) {
                await repairHandwritingSearch(
                    for: key,
                    publicationGeneration: operationGeneration,
                    expectedLibraryEpoch: mutation.libraryEpoch
                )
            }
            show(error)
            return nil
        }
    }

    func performIntelligence(action: IntelligenceAction, text: String) async -> IntelligenceResult? {
        do {
            return try await intelligence.perform(
                IntelligenceRequest(action: action, text: text, localeIdentifier: Locale.current.identifier)
            )
        } catch {
            show(error)
            return nil
        }
    }

    func report(_ error: Error) {
        show(error)
    }

    func notebook(id: UUID) async -> EditorNotebook? {
        guard let operation = beginLibraryOperation() else { return nil }
        defer { finishLibraryOperation(operation) }
        do {
            try await ensureBootstrapped()
            try requireCurrentLibraryOperation(operation)
            let notebook = try await store.loadNotebook(id: id)
            try requireCurrentLibraryOperation(operation)
            return notebook
        } catch {
            if error is CancellationError { return nil }
            show(error)
            return nil
        }
    }

    func notebookForExport(id: UUID) async throws -> EditorNotebook {
        guard let operation = beginLibraryOperation() else {
            throw LibraryRootChangeError.changeInProgress
        }
        defer { finishLibraryOperation(operation) }
        try Task.checkCancellation()
        try await ensureBootstrapped()
        let notebook = try await store.loadNotebookForExport(id: id)
        try Task.checkCancellation()
        return notebook
    }

    func beginNotebookExport(id: UUID) async throws -> NotesAppNotebookExportSession {
        guard let operation = beginLibraryOperation() else {
            throw LibraryRootChangeError.changeInProgress
        }
        do {
            try Task.checkCancellation()
            try await ensureBootstrapped()
            let session = try await store.beginNotebookExport(id: id)
            do {
                try Task.checkCancellation()
            } catch {
                await store.endNotebookExport(session)
                throw error
            }
            activeNotebookExportOperations[session.token] = operation
            return session
        } catch {
            finishLibraryOperation(operation)
            throw error
        }
    }

    func validateNotebookExportSession(
        _ session: NotesAppNotebookExportSession
    ) async throws -> EditorNotebook {
        try Task.checkCancellation()
        try requireActiveNotebookExportSession(session)
        let notebook = try await store.validateNotebookExportSession(session)
        try Task.checkCancellation()
        try requireActiveNotebookExportSession(session)
        return notebook
    }

    func audioSessionDescriptorForExport(
        session: NotesAppNotebookExportSession,
        sessionID: AudioSessionID
    ) async throws -> AudioSessionDescriptor {
        try Task.checkCancellation()
        try requireActiveNotebookExportSession(session)
        let descriptor = try await store.audioSessionDescriptorForExport(
            session: session,
            sessionID: sessionID
        )
        try Task.checkCancellation()
        try requireActiveNotebookExportSession(session)
        return descriptor
    }

    func loadAudioChunkForExport(
        session: NotesAppNotebookExportSession,
        sessionID: AudioSessionID,
        offset: Int64,
        maximumByteCount: Int
    ) async throws -> Data {
        try Task.checkCancellation()
        try requireActiveNotebookExportSession(session)
        let data = try await store.loadAudioChunkForExport(
            session: session,
            sessionID: sessionID,
            offset: offset,
            maximumByteCount: maximumByteCount
        )
        try Task.checkCancellation()
        try requireActiveNotebookExportSession(session)
        return data
    }

    func loadAudioTranscriptForExport(
        session: NotesAppNotebookExportSession,
        sessionID: AudioSessionID
    ) async throws -> AudioTranscriptDocument? {
        try Task.checkCancellation()
        try requireActiveNotebookExportSession(session)
        let transcript = try await store.loadAudioTranscriptForExport(
            session: session,
            sessionID: sessionID
        )
        try Task.checkCancellation()
        try requireActiveNotebookExportSession(session)
        return transcript
    }

    func endNotebookExport(_ session: NotesAppNotebookExportSession) async {
        await store.endNotebookExport(session)
        guard let operation = activeNotebookExportOperations.removeValue(
            forKey: session.token
        ) else { return }
        finishLibraryOperation(operation)
    }

    private func requireActiveNotebookExportSession(
        _ session: NotesAppNotebookExportSession
    ) throws {
        guard let operation = activeNotebookExportOperations[session.token],
              activeLibraryOperations[operation.token] == operation.libraryEpoch else {
            throw NotebookRepositoryError.invalidExportSession
        }
    }

    func addPage(
        to notebook: EditorNotebook,
        template: PaperTemplate = .blank,
        editorSession: EditorSessionLease
    ) async -> EditorNotebook? {
        await addPageImpl(
            to: notebook,
            template: template,
            editorSession: editorSession,
            allowsUnleasedTestingMutation: false
        )
    }

    private func addPageImpl(
        to notebook: EditorNotebook,
        template: PaperTemplate,
        editorSession: EditorSessionLease?,
        allowsUnleasedTestingMutation: Bool
    ) async -> EditorNotebook? {
        guard canBeginEditorStructuralMutation(
            notebookID: notebook.id,
            editorSession: editorSession,
            allowsUnleasedTestingMutation: allowsUnleasedTestingMutation
        ) else { return nil }
        guard let libraryOperation = beginLibraryOperation() else {
            show(LibraryRootChangeError.changeInProgress)
            return nil
        }
        defer { finishLibraryOperation(libraryOperation) }
        var updated = notebook
        updated.pages.append(EditorPage.newPage(for: notebook.kind, template: template))
        updated.modifiedAt = Date()
        do {
            try await ensureBootstrapped()
            try requireCurrentEditorStructuralMutation(
                notebookID: notebook.id,
                editorSession: editorSession,
                allowsUnleasedTestingMutation: allowsUnleasedTestingMutation
            )
            try await store.saveNotebook(updated)
            await upsert(updated.summary)
            return updated
        } catch is CancellationError {
            return nil
        } catch {
            show(error)
            return nil
        }
    }

    /// Updates only flat page-navigation metadata. This deliberately bypasses
    /// the whole-notebook save path so an older editor snapshot cannot replace
    /// a concurrent page order or notebook title. The operation is fenced by
    /// both the library epoch and the editor's root-generation lease.
    func updatePageNavigationMetadata(
        in notebook: EditorNotebook,
        pageID: UUID,
        update: PageNavigationMetadataUpdate,
        editorSession: EditorSessionLease
    ) async -> EditorNotebook? {
        guard !Task.isCancelled,
              isCurrentEditorSession(editorSession, notebookID: notebook.id),
              notebook.pages.contains(where: { $0.id == pageID }) else {
            return nil
        }
        let canonicalUpdate: PageNavigationMetadataUpdate = switch update {
        case .bookmark(let isBookmarked):
            .bookmark(isBookmarked)
        case .outlineTitle(let outlineTitle):
            .outlineTitle(outlineTitle.flatMap(
                PageNavigationMetadataPolicy.canonicalOutlineTitle
            ))
        }
        guard let libraryOperation = beginLibraryOperation() else {
            show(LibraryRootChangeError.changeInProgress)
            return nil
        }
        defer { finishLibraryOperation(libraryOperation) }
        let navigationSearchKey = PageNavigationSearchKey(
            notebookID: notebook.id,
            pageID: pageID
        )
        var navigationSearchPublicationGeneration: UInt64?

        do {
            try await ensureBootstrapped()
            try requireCurrentLibraryOperation(libraryOperation)
            guard isCurrentEditorSession(
                editorSession,
                notebookID: notebook.id
            ) else {
                throw CancellationError()
            }
            navigationSearchPublicationGeneration =
                beginPageNavigationSearchPublication(
                for: navigationSearchKey
            )
            let didSuppress = suppressPageNavigationSearchDocument(
                for: navigationSearchKey
            )
            if didSuppress { schedulePublishedSearchRefresh() }

            let updated = try await store.updatePageNavigationMetadata(
                notebookID: notebook.id,
                pageID: pageID,
                update: canonicalUpdate
            )
            // Always reconcile from a fresh durable read. A field-scoped
            // mutation that began earlier may complete after a newer request;
            // publishing either caller snapshot directly would lose the other
            // field from search even though storage retained it.
            await repairCurrentPageNavigationSearch(
                for: navigationSearchKey,
                expectedLibraryEpoch: libraryOperation.libraryEpoch,
                cancellationRecoveryGeneration:
                    navigationSearchPublicationGeneration
            )
            try requireCurrentLibraryOperation(libraryOperation)
            guard isCurrentEditorSession(
                editorSession,
                notebookID: notebook.id
            ),
            let updatedPage = updated.pages.first(where: { $0.id == pageID }),
            updated.id == notebook.id,
            PageNavigationMetadataPolicy.isSatisfied(
                canonicalUpdate,
                by: updatedPage
            ) else {
                throw CancellationError()
            }
            guard publishPageNavigationMetadataSummary(updated.summary) else {
                throw CancellationError()
            }
            try requireCurrentLibraryOperation(libraryOperation)
            guard isCurrentEditorSession(
                editorSession,
                notebookID: notebook.id
            ) else {
                throw CancellationError()
            }
            return updated
        } catch is CancellationError {
            if let navigationSearchPublicationGeneration {
                schedulePageNavigationSearchRepairs(
                    ownedGenerations: [
                        navigationSearchKey:
                            navigationSearchPublicationGeneration,
                    ],
                    expectedLibraryEpoch: libraryOperation.libraryEpoch
                )
            }
            return nil
        } catch {
            if let navigationSearchPublicationGeneration {
                schedulePageNavigationSearchRepairs(
                    ownedGenerations: [
                        navigationSearchKey:
                            navigationSearchPublicationGeneration,
                    ],
                    expectedLibraryEpoch: libraryOperation.libraryEpoch
                )
            }
            show(error)
            return nil
        }
    }

    func deletePage(
        from notebook: EditorNotebook,
        pageID: UUID,
        editorSession: EditorSessionLease
    ) async -> EditorNotebook? {
        await deletePageImpl(
            from: notebook,
            pageID: pageID,
            editorSession: editorSession,
            allowsUnleasedTestingMutation: false
        )
    }

    func deletePageForTesting(
        from notebook: EditorNotebook,
        pageID: UUID
    ) async -> EditorNotebook? {
        await deletePageImpl(
            from: notebook,
            pageID: pageID,
            editorSession: nil,
            allowsUnleasedTestingMutation: true
        )
    }

    private func deletePageImpl(
        from notebook: EditorNotebook,
        pageID: UUID,
        editorSession: EditorSessionLease?,
        allowsUnleasedTestingMutation: Bool
    ) async -> EditorNotebook? {
        guard notebook.pages.count > 1 else {
            show(NoteToolError.cannotDeleteLastPage)
            return nil
        }
        guard canBeginEditorStructuralMutation(
            notebookID: notebook.id,
            editorSession: editorSession,
            allowsUnleasedTestingMutation: allowsUnleasedTestingMutation
        ) else { return nil }
        guard let libraryOperation = beginLibraryOperation() else {
            show(LibraryRootChangeError.changeInProgress)
            return nil
        }
        defer { finishLibraryOperation(libraryOperation) }
        guard await flushPendingWrites(notebookID: notebook.id, pageID: pageID) else {
            show(PageContentPersistenceError.flushRequired)
            return nil
        }
        do {
            try requireCurrentEditorStructuralMutation(
                notebookID: notebook.id,
                editorSession: editorSession,
                allowsUnleasedTestingMutation: allowsUnleasedTestingMutation
            )
        } catch {
            return nil
        }
        var updated = notebook
        updated.pages.removeAll { $0.id == pageID }
        updated.modifiedAt = .now
        let navigationSearchKey = PageNavigationSearchKey(
            notebookID: notebook.id,
            pageID: pageID
        )
        var navigationSearchPublicationGeneration: UInt64?
        do {
            try await ensureBootstrapped()
            try requireCurrentEditorStructuralMutation(
                notebookID: notebook.id,
                editorSession: editorSession,
                allowsUnleasedTestingMutation: allowsUnleasedTestingMutation
            )
            navigationSearchPublicationGeneration =
                beginPageNavigationSearchPublication(
                for: navigationSearchKey
            )
            let didSuppress = suppressPageNavigationSearchDocument(
                for: navigationSearchKey
            )
            if didSuppress { schedulePublishedSearchRefresh() }
            try await store.saveNotebook(updated)
            discardPageContentState(notebookID: notebook.id, pageID: pageID)
            discardCanvasElementState(notebookID: notebook.id, pageID: pageID)
            discardHandwritingState(notebookID: notebook.id, pageID: pageID)
            await upsert(updated.summary)
            await removePageSearchDocuments(
                notebookID: notebook.id,
                pageID: pageID
            )
            searchTargetPageIDs = searchTargetPageIDs.filter { $0.value != pageID }
            if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                await searchIndexedContent()
            }
            return updated
        } catch is CancellationError {
            if let navigationSearchPublicationGeneration {
                schedulePageNavigationSearchRepairs(
                    ownedGenerations: [
                        navigationSearchKey:
                            navigationSearchPublicationGeneration,
                    ],
                    expectedLibraryEpoch: libraryOperation.libraryEpoch
                )
            }
            return nil
        } catch {
            if let navigationSearchPublicationGeneration {
                schedulePageNavigationSearchRepairs(
                    ownedGenerations: [
                        navigationSearchKey:
                            navigationSearchPublicationGeneration,
                    ],
                    expectedLibraryEpoch: libraryOperation.libraryEpoch
                )
            }
            show(error)
            return nil
        }
    }

    func movePage(
        in notebook: EditorNotebook,
        pageID: UUID,
        offset: Int,
        editorSession: EditorSessionLease
    ) async -> EditorNotebook? {
        guard canBeginEditorStructuralMutation(
            notebookID: notebook.id,
            editorSession: editorSession,
            allowsUnleasedTestingMutation: false
        ) else { return nil }
        guard let sourceIndex = notebook.pages.firstIndex(where: { $0.id == pageID }) else { return nil }
        let destinationIndex = sourceIndex + offset
        guard notebook.pages.indices.contains(destinationIndex) else { return notebook }
        guard let libraryOperation = beginLibraryOperation() else {
            show(LibraryRootChangeError.changeInProgress)
            return nil
        }
        defer { finishLibraryOperation(libraryOperation) }
        var updated = notebook
        updated.pages.swapAt(sourceIndex, destinationIndex)
        updated.modifiedAt = .now
        do {
            try await ensureBootstrapped()
            try requireCurrentEditorStructuralMutation(
                notebookID: notebook.id,
                editorSession: editorSession,
                allowsUnleasedTestingMutation: false
            )
            try await store.saveNotebook(updated)
            await upsert(updated.summary)
            return updated
        } catch is CancellationError {
            return nil
        } catch {
            show(error)
            return nil
        }
    }

    func duplicatePage(
        in notebook: EditorNotebook,
        page: EditorPage,
        editorSession: EditorSessionLease
    ) async -> (EditorNotebook, UUID)? {
        await duplicatePageImpl(
            in: notebook,
            page: page,
            editorSession: editorSession,
            allowsUnleasedTestingMutation: false
        )
    }

    func duplicatePageForTesting(
        in notebook: EditorNotebook,
        page: EditorPage
    ) async -> (EditorNotebook, UUID)? {
        await duplicatePageImpl(
            in: notebook,
            page: page,
            editorSession: nil,
            allowsUnleasedTestingMutation: true
        )
    }

    private func duplicatePageImpl(
        in notebook: EditorNotebook,
        page: EditorPage,
        editorSession: EditorSessionLease?,
        allowsUnleasedTestingMutation: Bool
    ) async -> (EditorNotebook, UUID)? {
        guard canBeginEditorStructuralMutation(
            notebookID: notebook.id,
            editorSession: editorSession,
            allowsUnleasedTestingMutation: allowsUnleasedTestingMutation
        ) else { return nil }
        guard let sourceIndex = notebook.pages.firstIndex(where: { $0.id == page.id }) else { return nil }
        guard let libraryOperation = beginLibraryOperation() else {
            show(LibraryRootChangeError.changeInProgress)
            return nil
        }
        defer { finishLibraryOperation(libraryOperation) }
        let copiedInk: Data?
        let copiedContent: PageContent?
        let copiedElements: [CanvasElement]
        let copiedRecognition: HandwritingRecognitionDocument?
        do {
            try await ensureBootstrapped()
            try requireCurrentEditorStructuralMutation(
                notebookID: notebook.id,
                editorSession: editorSession,
                allowsUnleasedTestingMutation: allowsUnleasedTestingMutation
            )
            guard await flushPendingWrites(notebookID: notebook.id, pageID: page.id) else {
                throw PageContentPersistenceError.flushRequired
            }
            switch page.kind {
            case .textDocument, .studySet:
                copiedInk = nil
                copiedElements = []
                copiedRecognition = nil
                guard let content = try await store.loadPageContent(
                    notebookID: notebook.id,
                    pageID: page.id
                ) else {
                    throw PageDuplicationError.missingStructuredContent
                }
                copiedContent = content
            case .notebook, .whiteboard, .importedDocument:
                copiedInk = try await store.loadInk(notebookID: notebook.id, page: page)
                copiedContent = nil
                copiedElements = try await store.loadElements(
                    notebookID: notebook.id,
                    pageID: page.id
                )
                let recognition = try await store.loadHandwritingRecognition(
                    notebookID: notebook.id,
                    pageID: page.id
                )
                if let recognition,
                   let copiedInk,
                   HandwritingRecognitionPipeline.sourceInkSHA256(for: copiedInk)
                    == recognition.sourceInkSHA256 {
                    copiedRecognition = recognition
                } else {
                    copiedRecognition = nil
                }
            }
            try requireCurrentEditorStructuralMutation(
                notebookID: notebook.id,
                editorSession: editorSession,
                allowsUnleasedTestingMutation: allowsUnleasedTestingMutation
            )
        } catch is CancellationError {
            return nil
        } catch {
            show(error)
            return nil
        }
        let duplicate = PageNavigationMetadataPolicy.duplicatePage(
            from: page,
            modifiedAt: .now
        )
        var updated = notebook
        updated.pages.insert(duplicate, at: sourceIndex + 1)
        updated.modifiedAt = .now
        let navigationSearchKey = PageNavigationSearchKey(
            notebookID: notebook.id,
            pageID: duplicate.id
        )
        _ = beginPageNavigationSearchPublication(for: navigationSearchKey)
        let didSuppress = suppressPageNavigationSearchDocument(
            for: navigationSearchKey
        )
        if didSuppress { schedulePublishedSearchRefresh() }
        do {
            try await store.saveNotebook(updated)
            if let copiedInk {
                try await store.saveInk(copiedInk, notebookID: notebook.id, page: duplicate)
            }
            if !copiedElements.isEmpty {
                try await store.saveElements(
                    copiedElements,
                    notebookID: notebook.id,
                    pageID: duplicate.id
                )
                await indexCanvasElements(
                    copiedElements,
                    notebookID: notebook.id,
                    pageID: duplicate.id,
                    modifiedAt: duplicate.modifiedAt
                )
            }
            if let copiedContent {
                try await store.savePageContent(
                    copiedContent,
                    notebookID: notebook.id,
                    pageID: duplicate.id
                )
                await indexStructuredContent(
                    copiedContent,
                    notebookID: notebook.id,
                    pageID: duplicate.id
                )
            }
            if let copiedRecognition {
                let recognitionCopy = HandwritingRecognitionDocument(
                    schemaVersion: copiedRecognition.schemaVersion,
                    runID: UUID(),
                    pageID: PageID(duplicate.id),
                    sourceInkSHA256: copiedRecognition.sourceInkSHA256,
                    engineIdentifier: copiedRecognition.engineIdentifier,
                    engineRevision: copiedRecognition.engineRevision,
                    languages: copiedRecognition.languages,
                    generatedAt: copiedRecognition.generatedAt,
                    revision: 1,
                    modifiedAt: max(Date(), copiedRecognition.modifiedAt),
                    machineCandidates: copiedRecognition.machineCandidates,
                    reviews: copiedRecognition.reviews
                )
                try await store.saveHandwritingRecognition(
                    recognitionCopy,
                    notebookID: notebook.id,
                    pageID: duplicate.id,
                    expectedRunID: nil,
                    expectedRevision: nil
                )
                await indexHandwritingRecognition(
                    recognitionCopy,
                    notebookID: notebook.id,
                    pageID: duplicate.id
                )
            }
            await upsert(updated.summary)
            await repairCurrentPageNavigationSearch(
                for: navigationSearchKey,
                expectedLibraryEpoch: libraryOperation.libraryEpoch
            )
            return (updated, duplicate.id)
        } catch {
            return await recoverFailedDuplicate(
                original: notebook,
                duplicateID: duplicate.id,
                failureDescription: error.localizedDescription
            )
        }
    }

    func loadInk(notebookID: UUID, page: EditorPage) async -> Data? {
        switch await loadInkForEditing(notebookID: notebookID, page: page) {
        case .loaded(let data): data
        case .failed: nil
        }
    }

    func loadInkForEditing(
        notebookID: UUID,
        page: EditorPage
    ) async -> EditorInkLoadResult {
        guard let operation = beginLibraryOperation() else { return .failed }
        defer { finishLibraryOperation(operation) }
        do {
            try await ensureBootstrapped()
            try requireCurrentLibraryOperation(operation)
            // Editor decoding is synchronous just like export decoding. Use the
            // production store's no-follow, pre-allocation bound instead of the
            // legacy convenience read so a malformed package cannot allocate an
            // unbounded PencilKit payload on page open.
            let data = try await store.loadInkForExport(
                notebookID: notebookID,
                page: page
            )
            try requireCurrentLibraryOperation(operation)
            return .loaded(data)
        } catch {
            if error is CancellationError { return .failed }
            show(error)
            return .failed
        }
    }

    /// Export reads require one immutable store session for the entire snapshot.
    func loadInkForExport(
        session: NotesAppNotebookExportSession,
        page: EditorPage
    ) async throws -> Data? {
        try Task.checkCancellation()
        let data = try await store.loadInkForExport(session: session, page: page)
        try Task.checkCancellation()
        return data
    }

    func inkSaveState(notebookID: UUID, pageID: UUID) -> InkSaveState {
        inkSaveStates[InkSaveKey(notebookID: notebookID, pageID: pageID)] ?? .idle
    }

    private enum PageStagingDisposition: Equatable {
        case activeRoot
        case deferredUntilRootRollback
    }

    /// Production editor callbacks must present a live lease for this exact
    /// root generation. That makes callbacks arriving after dismissal or after
    /// a successful move unrepresentable as writes into the new repository.
    /// The unleased path is an explicit queue-test seam and never crosses a move.
    private func pageStagingDisposition(
        notebookID: UUID,
        editorSession: EditorSessionLease?,
        allowsUnleasedTestingMutation: Bool
    ) -> PageStagingDisposition? {
        if allowsUnleasedTestingMutation {
            guard !isLibraryRootChangeInProgress else { return nil }
        } else {
            guard let editorSession,
                  editorSession.notebookID == notebookID,
                  editorSession.libraryRootGeneration == libraryRootGeneration,
                  activeEditorSessions[editorSession.id] == editorSession else {
                return nil
            }
        }
        if isLibraryRootChangeInProgress {
            didStagePageMutationDuringLibraryRootChange = true
        }
        return isInstallingLibraryRoot
            ? .deferredUntilRootRollback
            : .activeRoot
    }

    @discardableResult
    func stageInk(
        _ data: Data,
        notebookID: UUID,
        page: EditorPage,
        editorSession: EditorSessionLease
    ) -> Bool {
        stageInkSnapshot(
            data,
            notebookID: notebookID,
            page: page,
            editorSession: editorSession,
            allowsUnleasedTestingMutation: false
        )
    }

    /// Explicit test seam for persistence-queue tests that do not host SwiftUI.
    @discardableResult
    func stageInkForTesting(
        _ data: Data,
        notebookID: UUID,
        page: EditorPage
    ) -> Bool {
        stageInkSnapshot(
            data,
            notebookID: notebookID,
            page: page,
            editorSession: nil,
            allowsUnleasedTestingMutation: true
        )
    }

    @discardableResult
    private func stageInkSnapshot(
        _ data: Data,
        notebookID: UUID,
        page: EditorPage,
        editorSession: EditorSessionLease?,
        allowsUnleasedTestingMutation: Bool
    ) -> Bool {
        let key = InkSaveKey(notebookID: notebookID, pageID: page.id)
        guard let disposition = pageStagingDisposition(
            notebookID: notebookID,
            editorSession: editorSession,
            allowsUnleasedTestingMutation: allowsUnleasedTestingMutation
        ) else { return false }
        let handwritingGeneration = beginHandwritingOperation(
            for: HandwritingRecognitionKey(
                notebookID: notebookID,
                pageID: page.id
            )
        )
        let didSuppressHandwriting = suppressHandwritingSearchDocument(
            HandwritingSearchBuilder.documentID(
                notebookID: notebookID,
                pageID: page.id
            )
        )
        if didSuppressHandwriting { schedulePublishedSearchRefresh() }
        inkSaveGeneration &+= 1
        let pending = PendingInkSave(
            data: data,
            page: page,
            generation: inkSaveGeneration,
            handwritingGeneration: handwritingGeneration
        )
        inkSaveStates[key] = .saving
        if disposition == .deferredUntilRootRollback {
            if (deferredRootTransitionInkSaves[key]?.generation ?? 0)
                < pending.generation {
                deferredRootTransitionInkSaves[key] = pending
            }
            return false
        }
        pendingInkSaves[key] = pending
        inkDebounceTasks.removeValue(forKey: key)?.cancel()
        inkDebounceTasks[key] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            _ = await self.flushInkOnce(key)
        }
        return true
    }

    /// Compatibility entry point for callers that need an immediate durable save.
    func saveInk(
        _ data: Data,
        notebookID: UUID,
        page: EditorPage,
        editorSession: EditorSessionLease
    ) async -> Bool {
        guard stageInk(
            data,
            notebookID: notebookID,
            page: page,
            editorSession: editorSession
        ) else {
            return false
        }
        return await flushInk(notebookID: notebookID, pageID: page.id)
    }

    func saveInkForTesting(
        _ data: Data,
        notebookID: UUID,
        page: EditorPage
    ) async -> Bool {
        guard stageInkForTesting(data, notebookID: notebookID, page: page) else {
            return false
        }
        return await flushInk(notebookID: notebookID, pageID: page.id)
    }

    func flushInk(notebookID: UUID, pageID: UUID) async -> Bool {
        let key = InkSaveKey(notebookID: notebookID, pageID: pageID)
        repeat {
            guard await flushInkOnce(key) else { return false }
        } while pendingInkSaves[key] != nil || activeInkWrites[key] != nil
        return true
    }

    func flushAllInk() async -> Bool {
        await flushPendingInk(notebookID: nil)
    }

    func loadCanvasElements(notebookID: UUID, pageID: UUID) async -> [CanvasElement]? {
        guard let operation = beginLibraryOperation() else { return nil }
        defer { finishLibraryOperation(operation) }
        do {
            try await ensureBootstrapped()
            try requireCurrentLibraryOperation(operation)
            let elements = try await store.loadElements(
                notebookID: notebookID,
                pageID: pageID
            )
            try requireCurrentLibraryOperation(operation)
            return elements
        } catch {
            if error is CancellationError { return nil }
            show(error)
            return nil
        }
    }

    func loadCanvasElementsForExport(
        session: NotesAppNotebookExportSession,
        pageID: UUID
    ) async throws -> NotebookExportCanvasElements {
        try Task.checkCancellation()
        let loaded = try await store.loadElementsForExport(
            session: session,
            pageID: pageID
        )
        try Task.checkCancellation()
        return loaded
    }

    func canvasElementSaveState(notebookID: UUID, pageID: UUID) -> InkSaveState {
        canvasElementSaveStates[
            CanvasElementSaveKey(notebookID: notebookID, pageID: pageID)
        ] ?? .idle
    }

    /// Internal observability seam for deterministic queue-concurrency tests.
    func isCanvasElementWriteActive(notebookID: UUID, pageID: UUID) -> Bool {
        let key = CanvasElementSaveKey(notebookID: notebookID, pageID: pageID)
        return pendingCanvasElementSaves[key] == nil && activeCanvasElementWrites[key] != nil
    }

    @discardableResult
    func stageCanvasElements(
        _ elements: [CanvasElement],
        notebookID: UUID,
        pageID: UUID,
        editorSession: EditorSessionLease
    ) -> Bool {
        stageCanvasElementSnapshot(
            elements,
            notebookID: notebookID,
            pageID: pageID,
            editorSession: editorSession,
            allowsUnleasedTestingMutation: false
        )
    }

    /// Explicit test seam for persistence-queue tests that do not host SwiftUI.
    @discardableResult
    func stageCanvasElementsForTesting(
        _ elements: [CanvasElement],
        notebookID: UUID,
        pageID: UUID
    ) -> Bool {
        stageCanvasElementSnapshot(
            elements,
            notebookID: notebookID,
            pageID: pageID,
            editorSession: nil,
            allowsUnleasedTestingMutation: true
        )
    }

    @discardableResult
    private func stageCanvasElementSnapshot(
        _ elements: [CanvasElement],
        notebookID: UUID,
        pageID: UUID,
        editorSession: EditorSessionLease?,
        allowsUnleasedTestingMutation: Bool
    ) -> Bool {
        let key = CanvasElementSaveKey(notebookID: notebookID, pageID: pageID)
        guard let disposition = pageStagingDisposition(
            notebookID: notebookID,
            editorSession: editorSession,
            allowsUnleasedTestingMutation: allowsUnleasedTestingMutation
        ) else { return false }
        canvasElementSaveGeneration &+= 1
        let pending = PendingCanvasElementSave(
            elements: elements,
            generation: canvasElementSaveGeneration
        )
        canvasElementSaveStates[key] = .saving
        if disposition == .deferredUntilRootRollback {
            if (deferredRootTransitionCanvasElementSaves[key]?.generation ?? 0)
                < pending.generation {
                deferredRootTransitionCanvasElementSaves[key] = pending
            }
            return false
        }
        pendingCanvasElementSaves[key] = pending
        canvasElementDebounceTasks.removeValue(forKey: key)?.cancel()
        canvasElementDebounceTasks[key] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            _ = await self.flushCanvasElementsOnce(key)
        }
        return true
    }

    func flushCanvasElements(notebookID: UUID, pageID: UUID) async -> Bool {
        let key = CanvasElementSaveKey(notebookID: notebookID, pageID: pageID)
        repeat {
            guard await flushCanvasElementsOnce(key) else { return false }
        } while pendingCanvasElementSaves[key] != nil || activeCanvasElementWrites[key] != nil
        return true
    }

    func availableCanvasImageAssets(notebookID: UUID) async -> [AssetDescriptor] {
        guard let operation = beginLibraryOperation() else { return [] }
        defer { finishLibraryOperation(operation) }
        do {
            try await ensureBootstrapped()
            try requireCurrentLibraryOperation(operation)
            let assets = try await store.availableImageAssets(notebookID: notebookID)
            try requireCurrentLibraryOperation(operation)
            return assets
        } catch {
            if error is CancellationError { return [] }
            show(error)
            return []
        }
    }

    func canvasAssetURLs(
        notebookID: UUID,
        assetIDs: [AssetID]
    ) async -> [AssetID: URL] {
        guard let operation = beginLibraryOperation() else { return [:] }
        defer { finishLibraryOperation(operation) }
        do {
            try await ensureBootstrapped()
            try requireCurrentLibraryOperation(operation)
        } catch {
            if error is CancellationError { return [:] }
            show(error)
            return [:]
        }
        do {
            let urls = try await store.assetURLs(
                notebookID: notebookID,
                assetIDs: Set(assetIDs)
            )
            try requireCurrentLibraryOperation(operation)
            return urls
        } catch {
            if error is CancellationError { return [:] }
            show(error)
            return [:]
        }
    }

    func canvasAssetsForExport(
        session: NotesAppNotebookExportSession,
        assetIDs: [AssetID]
    ) async throws -> [AssetID: Data] {
        try Task.checkCancellation()
        let data = try await store.loadCanvasAssetsForExport(
            session: session,
            assetIDs: assetIDs
        )
        try Task.checkCancellation()
        return data
    }

    func loadPageContent(notebookID: UUID, pageID: UUID) async -> PageContent? {
        guard let operation = beginLibraryOperation() else { return nil }
        defer { finishLibraryOperation(operation) }
        do {
            try await ensureBootstrapped()
            try requireCurrentLibraryOperation(operation)
            let content = try await store.loadPageContent(
                notebookID: notebookID,
                pageID: pageID
            )
            try requireCurrentLibraryOperation(operation)
            return content
        } catch {
            if error is CancellationError { return nil }
            show(error)
            return nil
        }
    }

    func pageContentSaveState(notebookID: UUID, pageID: UUID) -> InkSaveState {
        pageContentSaveStates[
            PageContentSaveKey(notebookID: notebookID, pageID: pageID)
        ] ?? .idle
    }

    /// Internal observability seam for deterministic queue-concurrency tests.
    /// `true` means the latest pending snapshot has been promoted to the active
    /// serialized write chain rather than merely waiting for debounce.
    func isPageContentWriteActive(notebookID: UUID, pageID: UUID) -> Bool {
        let key = PageContentSaveKey(notebookID: notebookID, pageID: pageID)
        return pendingPageContentSaves[key] == nil && activePageContentWrites[key] != nil
    }

    @discardableResult
    func stagePageContent(
        _ content: PageContent,
        notebookID: UUID,
        pageID: UUID,
        editorSession: EditorSessionLease
    ) -> Bool {
        stagePageContentSnapshot(
            content,
            notebookID: notebookID,
            pageID: pageID,
            editorSession: editorSession,
            allowsUnleasedTestingMutation: false
        )
    }

    /// Explicit test seam for persistence-queue tests that do not host SwiftUI.
    @discardableResult
    func stagePageContentForTesting(
        _ content: PageContent,
        notebookID: UUID,
        pageID: UUID
    ) -> Bool {
        stagePageContentSnapshot(
            content,
            notebookID: notebookID,
            pageID: pageID,
            editorSession: nil,
            allowsUnleasedTestingMutation: true
        )
    }

    @discardableResult
    private func stagePageContentSnapshot(
        _ content: PageContent,
        notebookID: UUID,
        pageID: UUID,
        editorSession: EditorSessionLease?,
        allowsUnleasedTestingMutation: Bool
    ) -> Bool {
        let key = PageContentSaveKey(notebookID: notebookID, pageID: pageID)
        guard let disposition = pageStagingDisposition(
            notebookID: notebookID,
            editorSession: editorSession,
            allowsUnleasedTestingMutation: allowsUnleasedTestingMutation
        ) else { return false }
        pageContentSaveGeneration &+= 1
        let pending = PendingPageContentSave(
            content: content,
            generation: pageContentSaveGeneration
        )
        pageContentSaveStates[key] = .saving
        if disposition == .deferredUntilRootRollback {
            if (deferredRootTransitionPageContentSaves[key]?.generation ?? 0)
                < pending.generation {
                deferredRootTransitionPageContentSaves[key] = pending
            }
            return false
        }
        pendingPageContentSaves[key] = pending
        pageContentDebounceTasks.removeValue(forKey: key)?.cancel()
        pageContentDebounceTasks[key] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            _ = await self.flushPageContentOnce(key)
        }
        return true
    }

    func flushPageContent(notebookID: UUID, pageID: UUID) async -> Bool {
        let key = PageContentSaveKey(notebookID: notebookID, pageID: pageID)
        repeat {
            guard await flushPageContentOnce(key) else { return false }
        } while pendingPageContentSaves[key] != nil || activePageContentWrites[key] != nil
        return true
    }

    /// Durably freezes one exact text block before an academic source anchor
    /// may be created. The editor's supplied document is saved first; the
    /// returned value comes from one authoritative repository read rather than
    /// from the live SwiftUI binding.
    func prepareTextBlockSourceSnapshot(
        document: TextDocument,
        notebookID: UUID,
        pageID: UUID,
        blockID: TextBlockID,
        editorSession: EditorSessionLease
    ) async throws -> TextDocumentSourceSnapshot {
        try Task.checkCancellation()
        guard isCurrentEditorSession(
            editorSession,
            notebookID: notebookID
        ) else {
            throw TextBlockAnchorPreparationError.editorSessionExpired
        }
        guard let sourceSnapshotProvider = textDocumentSourceSnapshotProvider else {
            throw TextBlockAnchorPreparationError.sourceSnapshotUnavailable
        }
        guard let block = document.blocks.first(where: { $0.id == blockID }) else {
            throw TextBlockAnchorPreparationError.blockNotFound
        }
        guard block.style != .divider,
              !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TextBlockAnchorPreparationError.blockNotCapturable
        }

        let frozenHash = ExactTextHash.sha256UTF8(block.text)
        guard let operation = beginLibraryOperation() else {
            throw TextBlockAnchorPreparationError.editorSessionExpired
        }
        defer { finishLibraryOperation(operation) }

        do {
            try await ensureBootstrapped()
            try requireCurrentLibraryOperation(operation)
            guard isCurrentEditorSession(
                editorSession,
                notebookID: notebookID
            ) else {
                throw TextBlockAnchorPreparationError.editorSessionExpired
            }
            guard stagePageContent(
                .textDocument(document),
                notebookID: notebookID,
                pageID: pageID,
                editorSession: editorSession
            ) else {
                throw TextBlockAnchorPreparationError.noteSaveFailed
            }
            guard await flushPageContent(
                notebookID: notebookID,
                pageID: pageID
            ) else {
                throw TextBlockAnchorPreparationError.noteSaveFailed
            }
            try requireCurrentLibraryOperation(operation)
            guard isCurrentEditorSession(
                editorSession,
                notebookID: notebookID
            ) else {
                throw TextBlockAnchorPreparationError.editorSessionExpired
            }

            let snapshot: TextDocumentSourceSnapshot
            do {
                snapshot = try await sourceSnapshotProvider
                    .textDocumentSourceSnapshot(
                        noteID: NotebookID(notebookID),
                        pageID: PageID(pageID),
                        blockID: blockID
                    )
            } catch is CancellationError {
                throw CancellationError()
            } catch let repositoryError as NotebookRepositoryError {
                if case .textBlockNotFound = repositoryError {
                    throw TextBlockAnchorPreparationError.blockNotFound
                }
                throw TextBlockAnchorPreparationError.invalidSnapshot
            } catch {
                throw TextBlockAnchorPreparationError.invalidSnapshot
            }

            try requireCurrentLibraryOperation(operation)
            guard isCurrentEditorSession(
                editorSession,
                notebookID: notebookID
            ) else {
                throw TextBlockAnchorPreparationError.editorSessionExpired
            }
            guard snapshot.noteID == NotebookID(notebookID),
                  snapshot.pageID == PageID(pageID),
                  snapshot.blockID == blockID,
                  snapshot.blockIndex >= 0,
                  snapshot.noteRevision > 0 else {
                throw TextBlockAnchorPreparationError.invalidSnapshot
            }
            guard snapshot.block == block,
                  snapshot.textHash == frozenHash,
                  snapshot.textHash == ExactTextHash.sha256UTF8(snapshot.text) else {
                throw TextBlockAnchorPreparationError.sourceChanged
            }
            return snapshot
        } catch is CancellationError {
            throw TextBlockAnchorPreparationError.editorSessionExpired
        }
    }

    /// Resolves an already-saved academic source anchor without staging or
    /// mutating Notes. The repository is read exactly once, inside the same
    /// library-root operation fence used by other authoritative reads.
    func captureSourcePreview(
        noteID: NotebookID,
        pageID: PageID,
        blockID: TextBlockID,
        expectedTextHash: String?
    ) async -> CaptureSourcePreview {
        guard let sourceSnapshotProvider = textDocumentSourceSnapshotProvider,
              let operation = beginLibraryOperation() else {
            return .unavailable
        }
        defer { finishLibraryOperation(operation) }

        do {
            try Task.checkCancellation()
            try await ensureBootstrapped()
            try requireCurrentLibraryOperation(operation)

            let snapshot = try await sourceSnapshotProvider
                .textDocumentSourceSnapshot(
                    noteID: noteID,
                    pageID: pageID,
                    blockID: blockID
                )

            try Task.checkCancellation()
            try requireCurrentLibraryOperation(operation)
            guard snapshot.noteID == noteID,
                  snapshot.pageID == pageID,
                  snapshot.blockID == blockID,
                  snapshot.blockIndex >= 0,
                  snapshot.noteRevision > 0,
                  snapshot.textHash == ExactTextHash.sha256UTF8(snapshot.text) else {
                return .unavailable
            }
            guard let expectedTextHash else {
                return .unverifiable(currentText: snapshot.text)
            }
            return snapshot.textHash == expectedTextHash
                ? .exact(snapshot.text)
                : .changed(currentText: snapshot.text)
        } catch let error as NotebookRepositoryError {
            switch error {
            case .notebookNotFound, .pageNotFound, .textBlockNotFound:
                return .missing
            default:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }

    func flushAllPendingWrites() async -> Bool {
        await flushPendingWrites(notebookID: nil)
    }

    /// Drains every durable page-content queue for one notebook. Replay uses
    /// this before opening its read-only persistence capability so the session
    /// cannot start from stale staged editor state.
    func flushPendingWrites(notebookID: UUID) async -> Bool {
        await flushPendingWrites(notebookID: Optional(notebookID))
    }

    func flushPendingWrites(notebookID: UUID, pageID: UUID) async -> Bool {
        while true {
            let inkSucceeded = await flushInk(notebookID: notebookID, pageID: pageID)
            let elementsSucceeded = await flushCanvasElements(
                notebookID: notebookID,
                pageID: pageID
            )
            let contentSucceeded = await flushPageContent(
                notebookID: notebookID,
                pageID: pageID
            )
            guard inkSucceeded && elementsSucceeded && contentSucceeded else {
                return false
            }
            let inkKey = InkSaveKey(notebookID: notebookID, pageID: pageID)
            let elementKey = CanvasElementSaveKey(notebookID: notebookID, pageID: pageID)
            let contentKey = PageContentSaveKey(notebookID: notebookID, pageID: pageID)
            guard pendingInkSaves[inkKey] != nil || activeInkWrites[inkKey] != nil
                    || pendingCanvasElementSaves[elementKey] != nil
                    || activeCanvasElementWrites[elementKey] != nil
                    || pendingPageContentSaves[contentKey] != nil
                    || activePageContentWrites[contentKey] != nil else {
                return true
            }
        }
    }

    func resolveBackground(notebookID: UUID, page: EditorPage) async -> ResolvedPageBackground {
        guard let operation = beginLibraryOperation() else {
            return ResolvedPageBackground(background: page.background, assetURL: nil)
        }
        defer { finishLibraryOperation(operation) }
        do {
            try await ensureBootstrapped()
            try requireCurrentLibraryOperation(operation)
        } catch {
            if error is CancellationError {
                return ResolvedPageBackground(background: page.background, assetURL: nil)
            }
            show(error)
            return ResolvedPageBackground(background: page.background, assetURL: nil)
        }
        let path: String?
        switch page.background {
        case .paper:
            path = nil
        case let .pdf(assetPath, _), let .image(assetPath):
            path = assetPath
        }
        guard let path else {
            return ResolvedPageBackground(background: page.background, assetURL: nil)
        }
        let assetURL = try? await store.assetURL(
            notebookID: notebookID,
            relativePath: path
        )
        do {
            try requireCurrentLibraryOperation(operation)
        } catch {
            return ResolvedPageBackground(background: page.background, assetURL: nil)
        }
        return ResolvedPageBackground(
            background: page.background,
            assetURL: assetURL
        )
    }

    /// PDF export owns a bounded immutable asset snapshot. The store resolves the content-addressed
    /// package asset through NotesCore's openat/O_NOFOLLOW reader, so PDFKit/ImageIO never retain a
    /// lazy mapping or race a path replacement after validation.
    func resolveBackgroundForExport(
        session: NotesAppNotebookExportSession,
        page: EditorPage
    ) async throws -> ResolvedPageBackground {
        try Task.checkCancellation()
        switch page.background {
        case .paper:
            return ResolvedPageBackground(
                background: page.background,
                assetURL: nil,
                assetData: nil
            )
        case .pdf(let assetPath, _), .image(let assetPath):
            let data = try await store.loadBackgroundAssetForExport(
                session: session,
                relativePath: assetPath
            )
            try Task.checkCancellation()
            return ResolvedPageBackground(
                background: page.background,
                assetURL: nil,
                assetData: data
            )
        }
    }

    func useBackupDirectory(_ url: URL) async {
        do {
            try await ensureBootstrapped()
            let destination = try BackupDestination(url: url)
            try await validateBackupDestination(destination)
            backupDestination = destination
            preferences.set(destination.bookmarkData, forKey: Self.backupBookmarkKey)
            backupFolderDescription = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            try await loadBackupSnapshots(from: destination)
        } catch {
            show(error)
        }
    }

    func clearBackupDirectory() {
        guard !isBackupOperationRunning else { return }
        backupDestination = nil
        backupSnapshots = []
        backupFolderDescription = String(localized: "Not configured")
        preferences.removeObject(forKey: Self.backupBookmarkKey)
    }

    func refreshBackupSnapshots() async {
        guard let backupDestination else {
            backupSnapshots = []
            return
        }
        do {
            try await loadBackupSnapshots(from: backupDestination)
        } catch {
            if error as? FileBackupError == .staleBookmark {
                backupFolderDescription = String(localized: "Permission expired")
            }
            show(error)
        }
    }

    @discardableResult
    func createBackup() async -> BackupSnapshot? {
        guard !isBackupOperationRunning else { return nil }
        guard let backupDestination else {
            show(BackupUIError.folderNotConfigured)
            return nil
        }
        guard let libraryOperation = beginLibraryOperation() else {
            show(LibraryRootChangeError.changeInProgress)
            return nil
        }
        defer { finishLibraryOperation(libraryOperation) }
        isBackupOperationRunning = true
        defer { isBackupOperationRunning = false }

        let stagingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesBackupSources", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        do {
            try await ensureBootstrapped()
            try await validateBackupDestination(backupDestination)
            guard await flushAllPendingWrites() else { throw PageContentPersistenceError.flushRequired }
            let sources = try await store.exportNotebookSnapshots(to: stagingRoot)
            let snapshot = try await backupService.createSnapshot(
                notebookURLs: sources,
                at: backupDestination,
                keepLatest: 10
            )
            try await loadBackupSnapshots(from: backupDestination)
            notice = AppNotice(
                kind: .information,
                title: String(localized: "Backup complete"),
                message: String(
                    format: String(localized: "Saved %lld notebooks in a verified snapshot."),
                    Int64(snapshot.notebookNames.count)
                )
            )
            return snapshot
        } catch {
            show(error)
            return nil
        }
    }

    @discardableResult
    func restoreBackup(_ snapshot: BackupSnapshot) async -> Bool {
        guard !isBackupOperationRunning else { return false }
        guard let backupDestination else {
            show(BackupUIError.folderNotConfigured)
            return false
        }
        guard let libraryOperation = beginLibraryOperation() else {
            show(LibraryRootChangeError.changeInProgress)
            return false
        }
        defer { finishLibraryOperation(libraryOperation) }
        isBackupOperationRunning = true
        defer { isBackupOperationRunning = false }

        do {
            try await ensureBootstrapped()
            try await validateBackupDestination(backupDestination)
            guard await flushAllPendingWrites() else { throw PageContentPersistenceError.flushRequired }
            let libraryDirectory = try await store.libraryDirectoryURL()
            let restored = try await backupService.restore(
                snapshot,
                from: backupDestination,
                into: libraryDirectory
            )
            try await store.validateRestoredNotebookPackages(restored)
            notebooks = try await store.loadLibrary()
            rootDescription = await store.rootDescription()
            await rebuildTitleIndex()
            notice = AppNotice(
                kind: .information,
                title: String(localized: "Restore complete"),
                message: String(
                    format: String(localized: "Restored %lld notebooks. Existing notebook identities were not overwritten."),
                    Int64(restored.count)
                )
            )
            return true
        } catch {
            show(error)
            return false
        }
    }

    private func loadBackupSnapshots(from destination: BackupDestination) async throws {
        backupSnapshots = try await backupService.snapshots(at: destination)
    }

    private func validateBackupDestination(_ destination: BackupDestination) async throws {
        let destinationURL = try destination.resolve().standardizedFileURL
        let libraryURL = (try await store.libraryDirectoryURL()).standardizedFileURL
        let libraryComponents = libraryURL.pathComponents
        let destinationComponents = destinationURL.pathComponents
        let isSameOrInsideLibrary = destinationComponents.count >= libraryComponents.count
            && destinationComponents.prefix(libraryComponents.count).elementsEqual(libraryComponents)
        guard !isSameOrInsideLibrary else { throw BackupUIError.folderInsideLibrary }
    }

    func packageURL(for notebook: LibraryNotebook) async -> URL? {
        guard let libraryOperation = beginLibraryOperation() else {
            show(LibraryRootChangeError.changeInProgress)
            return nil
        }
        defer { finishLibraryOperation(libraryOperation) }
        do {
            try await ensureBootstrapped()
            guard await flushPendingWrites(notebookID: notebook.id) else {
                throw PageContentPersistenceError.flushRequired
            }
            return try await store.packageURL(notebookID: notebook.id)
        } catch {
            show(error)
            return nil
        }
    }

    func toggleFavorite(_ notebook: LibraryNotebook) async {
        guard let libraryOperation = beginLibraryOperation() else {
            show(LibraryRootChangeError.changeInProgress)
            return
        }
        defer { finishLibraryOperation(libraryOperation) }
        guard var editorNotebook = await self.notebook(id: notebook.id) else { return }
        editorNotebook.isFavorite.toggle()
        await persist(editorNotebook, libraryOperation: libraryOperation)
    }

    func rename(_ notebook: LibraryNotebook, to title: String) async {
        guard let libraryOperation = beginLibraryOperation() else {
            show(LibraryRootChangeError.changeInProgress)
            return
        }
        defer { finishLibraryOperation(libraryOperation) }
        guard await flushPendingWrites(notebookID: notebook.id) else {
            show(PageContentPersistenceError.flushRequired)
            return
        }
        guard var editorNotebook = await self.notebook(id: notebook.id) else { return }
        editorNotebook.title = title
        editorNotebook.modifiedAt = .now
        guard await persist(
            editorNotebook,
            libraryOperation: libraryOperation
        ) else { return }
    }

    func moveToTrash(_ notebook: LibraryNotebook) async {
        guard let libraryOperation = beginLibraryOperation() else {
            show(LibraryRootChangeError.changeInProgress)
            return
        }
        defer { finishLibraryOperation(libraryOperation) }
        do {
            try await ensureBootstrapped()
            guard await flushPendingWrites(notebookID: notebook.id) else {
                throw PageContentPersistenceError.flushRequired
            }
            guard (await notebookAudio?.handleInterruption(notebookID: notebook.id)) ?? true else {
                throw NotebookAudioCoordinatorError.stalePersistenceRollbackFailed
            }
            try await store.deleteNotebook(id: notebook.id, permanently: false)
            if let updated = try? await store.loadNotebook(id: notebook.id) {
                await upsert(updated.summary)
            }
        } catch {
            show(error)
        }
    }

    func restore(_ notebook: LibraryNotebook) async {
        guard let libraryOperation = beginLibraryOperation() else {
            show(LibraryRootChangeError.changeInProgress)
            return
        }
        defer { finishLibraryOperation(libraryOperation) }
        guard var restored = await self.notebook(id: notebook.id) else { return }
        restored.deletedAt = nil
        await persist(restored, libraryOperation: libraryOperation)
    }

    func deletePermanently(_ notebook: LibraryNotebook) async {
        guard let libraryOperation = beginLibraryOperation() else {
            show(LibraryRootChangeError.changeInProgress)
            return
        }
        defer { finishLibraryOperation(libraryOperation) }
        var navigationSearchKeys = Set(
            pageNavigationSearchPublicationGenerations.keys.filter {
                $0.notebookID == notebook.id
            }
        )
        var navigationSearchGenerations:
            [PageNavigationSearchKey: UInt64] = [:]
        var didAddNavigationSearchSuppression = false
        do {
            try await ensureBootstrapped()
            try requireCurrentLibraryOperation(libraryOperation)
            guard await flushPendingWrites(notebookID: notebook.id) else {
                throw PageContentPersistenceError.flushRequired
            }
            guard (await notebookAudio?.handleInterruption(notebookID: notebook.id)) ?? true else {
                throw NotebookAudioCoordinatorError.stalePersistenceRollbackFailed
            }
            try requireCurrentLibraryOperation(libraryOperation)
            if let durableNotebook = try? await store.loadNotebook(
                id: notebook.id
            ) {
                try requireCurrentLibraryOperation(libraryOperation)
                navigationSearchKeys.formUnion(
                    durableNotebook.pages.map {
                        PageNavigationSearchKey(
                            notebookID: notebook.id,
                            pageID: $0.id
                        )
                    }
                )
            }
            try requireCurrentLibraryOperation(libraryOperation)
            for key in navigationSearchKeys {
                navigationSearchGenerations[key] =
                    beginPageNavigationSearchPublication(for: key)
                didAddNavigationSearchSuppression =
                    suppressPageNavigationSearchDocument(for: key)
                    || didAddNavigationSearchSuppression
            }
            if didAddNavigationSearchSuppression {
                schedulePublishedSearchRefresh()
            }
            try await store.deleteNotebook(id: notebook.id, permanently: true)
            discardInkState(notebookID: notebook.id)
            discardCanvasElementState(notebookID: notebook.id)
            discardPageContentState(notebookID: notebook.id)
            discardHandwritingState(notebookID: notebook.id)
            pendingWholeNotebookSearchRecoveries.removeValue(
                forKey: notebook.id
            )
            notebooks.removeAll { $0.id == notebook.id }
            do {
                try await searchIndex.removeNotebook(notebook.id)
                for key in navigationSearchKeys {
                    let documentID = PageNavigationSearchBuilder.documentID(
                        notebookID: key.notebookID,
                        pageID: key.pageID
                    )
                    guard await searchIndex.document(for: documentID) == nil else {
                        continue
                    }
                    // Keep the absence tombstone even after verified removal;
                    // a previously sent publication may still complete late.
                    pageNavigationSearchPublicationGenerations.removeValue(
                        forKey: key
                    )
                }
            } catch {
                show(error)
            }
        } catch {
            schedulePageNavigationSearchRepairs(
                ownedGenerations: navigationSearchGenerations,
                expectedLibraryEpoch: libraryOperation.libraryEpoch
            )
            show(error)
        }
    }

    func useRootDirectory(_ url: URL?) async {
        guard !isLibraryRootChangeInProgress else {
            show(HandwritingReviewError.libraryLocationChanging)
            return
        }
        guard activeEditorSessions.isEmpty else {
            show(LibraryRootChangeError.openEditors)
            return
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: libraryRootChangeTimeout)
        // Library-location recovery must remain available when the persisted
        // Files bookmark can no longer be opened. A cold bootstrap owns no
        // editor or queued mutation, so cancel its publication attempt and let
        // the root transaction validate the selected candidate directly.
        if !isBootstrapped, let attempt = bootstrapAttempt {
            cancelBootstrapAttempt(attempt)
        }
        var didBeginRootChange = false
        var rootPreparation: NotesAppLibraryRootPreparation?
        var rootTransition: NotesAppLibraryRootTransition?
        var academicRootTransition: AcademicLibraryRootTransition?
        var rootBootstrapAttempt: BootstrapAttempt?
        var rollbackSearchRepairs = RootSearchRollbackRepairs()
        var rollbackSnapshot: LibraryRootRollbackSnapshot?
        var searchRebuildMarkerBeforeCandidate: Bool?
        let audioRootChangeToken = notebookAudio == nil ? nil : UUID()
        defer {
            if let audioRootChangeToken {
                notebookAudio?.finishLibraryRootChange(token: audioRootChangeToken)
            }
        }

        do {
            guard !isLibraryRootChangeInProgress else {
                throw HandwritingReviewError.libraryLocationChanging
            }
            guard activeEditorSessions.isEmpty else {
                throw LibraryRootChangeError.openEditors
            }
            // Claim the AppModel gate before yielding to audio cleanup so a
            // second request cannot release resources owned by this transition.
            rollbackSearchRepairs = beginLibraryRootChange()
            didBeginRootChange = true
            if let academicRootCoordinator {
                academicRootTransition = try await academicRootCoordinator
                    .prepareForLibraryRootTransition()
            }
            let audioPrepared = try await runRootOperation(before: deadline) {
                guard let audioRootChangeToken else { return true }
                return await self.notebookAudio?.prepareForLibraryRootChange(
                    token: audioRootChangeToken
                ) ?? true
            }
            guard audioPrepared else {
                throw NotebookAudioCoordinatorError.stalePersistenceRollbackFailed
            }
            guard activeEditorSessions.isEmpty else {
                throw LibraryRootChangeError.openEditors
            }
            let firstFlushSucceeded = try await runRootOperation(before: deadline) {
                await self.flushAllPendingWrites()
            }
            guard firstFlushSucceeded else {
                throw PageContentPersistenceError.flushRequired
            }
            try await waitForLibraryOperationsToQuiesce(before: deadline)
            let secondFlushSucceeded = try await runRootOperation(before: deadline) {
                await self.flushAllPendingWrites()
            }
            guard secondFlushSucceeded else {
                throw PageContentPersistenceError.flushRequired
            }
            guard !didStagePageMutationDuringLibraryRootChange else {
                throw LibraryRootChangeError.concurrentPageEdit
            }
            try Task.checkCancellation()
            // Active old-root operations can publish while the transition gate
            // is draining. Capture rollback state only after that drain, so a
            // failed candidate never hides a mutation that already committed.
            rollbackSnapshot = LibraryRootRollbackSnapshot(
                notebooks: notebooks,
                rootDescription: rootDescription,
                wasBootstrapped: isBootstrapped,
                matchingNotebookIDs: matchingNotebookIDs,
                searchTargetPageIDs: searchTargetPageIDs,
                searchIndexWasReady: isSearchIndexReadyForCurrentRoot
            )
            isSearchIndexReadyForCurrentRoot = false
            matchingNotebookIDs = searchText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ? nil : []
            searchTargetPageIDs = [:]
            isInstallingLibraryRoot = true
            let preparation = NotesAppLibraryRootPreparation()
            rootPreparation = preparation
            try await runRootOperation(before: deadline) {
                try await self.store.prepareRootDirectoryTransition(
                    to: url,
                    preparation: preparation
                )
            }
            try Task.checkCancellation()
            // Candidate preparation performs all potentially blocking Files I/O.
            // Consuming its token is now a constant-time, reversible actor hop.
            let transition = try await store.beginRootDirectoryTransition(preparation)
            rootPreparation = nil
            rootTransition = transition
            try Task.checkCancellation()
            guard !didStagePageMutationDuringLibraryRootChange else {
                throw LibraryRootChangeError.concurrentPageEdit
            }
            let attempt = beginBootstrap(.rootTransition)
            rootBootstrapAttempt = attempt
            try await runRootOperation(before: deadline) {
                try await self.waitForBootstrap(attempt)
            }
            try Task.checkCancellation()
            guard !didStagePageMutationDuringLibraryRootChange else {
                throw LibraryRootChangeError.concurrentPageEdit
            }
            guard clock.now < deadline else {
                throw LibraryRootChangeError.operationsDidNotFinish
            }
            // Persist the fail-closed fence before the root bookmark can become
            // durable. A crash on either side of commit therefore forces a full
            // cache clear on the next launch.
            searchRebuildMarkerBeforeCandidate = preferences.bool(
                forKey: Self.searchRootRebuildRequiredKey
            )
            guard setSearchRootRebuildRequired(true) else {
                throw LibraryRootChangeError.operationsDidNotFinish
            }
            // The store's first commit remains reversible. Re-check every
            // MainActor fence after its actor hop before accepting the root.
            try await store.commitRootDirectoryTransition(transition)
            try Task.checkCancellation()
            guard !didStagePageMutationDuringLibraryRootChange else {
                throw LibraryRootChangeError.concurrentPageEdit
            }

            // The final cancellation and concurrent-edit fences are above.
            // Academic candidate resolution is deliberately nonthrowing, and
            // no fallible fence may follow it: Notes is now authoritative even
            // when the optional academic sidecar needs a later retry.
            if let academicRootTransition {
                await academicRootCoordinator?.resolveCandidateLibraryRoot(
                    academicRootTransition
                )
            }

            // From here the candidate is authoritative. Search remains
            // fail-closed while a separately tracked derived-index repair runs.
            isInstallingLibraryRoot = false
            isSearchIndexReadyForCurrentRoot = false
            matchingNotebookIDs = searchText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ? nil : []
            searchTargetPageIDs = [:]
            suppressedHandwritingSearchDocumentIDs.removeAll(keepingCapacity: true)
            suppressedPageNavigationSearchDocumentIDs.removeAll(
                keepingCapacity: true
            )
            pageNavigationSearchPublicationGenerations.removeAll(
                keepingCapacity: true
            )
            reconciledPageNavigationSearchPublicationGenerations.removeAll(
                keepingCapacity: true
            )
            pageNavigationSearchRepairRequiredGenerations.removeAll(
                keepingCapacity: true
            )
            authorizedPageNavigationSearchDocuments.removeAll(
                keepingCapacity: true
            )
            // These tokens belong to the previous root. The committed-root
            // rebuild below clears and reconstructs every candidate-root source.
            pendingWholeNotebookSearchRecoveries.removeAll(
                keepingCapacity: true
            )
            await store.finalizeRootDirectoryTransition(transition)
            rootTransition = nil
            if let academicRootTransition {
                academicRootCoordinator?.acceptLibraryRootTransition(
                    academicRootTransition
                )
            }
            libraryRootGeneration &+= 1
            if libraryRootGeneration == 0 { libraryRootGeneration = 1 }
            isLibraryRootChangeInProgress = false
            scheduleCommittedRootSearchRebuild(
                expectedRootGeneration: libraryRootGeneration
            )
            notice = AppNotice(
                kind: .information,
                title: String(localized: "Library location updated"),
                message: String(localized: "New notes will be saved in the selected Files folder.")
            )
        } catch let rootChangeError {
            guard didBeginRootChange else {
                show(rootChangeError)
                return
            }
            if let rootBootstrapAttempt {
                cancelBootstrapAttempt(rootBootstrapAttempt)
            }
            if let rootPreparation {
                // Preparation never changes routing. Queue cancellation without
                // awaiting a possibly occupied old-root actor; its token cleanup
                // remains mandatory but must not hold the UI gate indefinitely.
                Task {
                    await store.cancelRootDirectoryPreparation(rootPreparation)
                }
            }
            if let rootTransition {
                await store.rollbackRootDirectoryTransition(rootTransition)
            }
            if let academicRootTransition {
                await academicRootCoordinator?.rollbackLibraryRootTransition(
                    academicRootTransition
                )
            }
            if let searchRebuildMarkerBeforeCandidate {
                setSearchRootRebuildRequired(searchRebuildMarkerBeforeCandidate)
            }
            isInstallingLibraryRoot = false
            promoteDeferredRootTransitionWrites()
            if let rollbackSnapshot {
                notebooks = rollbackSnapshot.notebooks
                rootDescription = rollbackSnapshot.rootDescription
                isBootstrapped = rollbackSnapshot.wasBootstrapped
                isSearchIndexReadyForCurrentRoot = rollbackSnapshot.searchIndexWasReady
                matchingNotebookIDs = rollbackSnapshot.matchingNotebookIDs
                searchTargetPageIDs = rollbackSnapshot.searchTargetPageIDs
            }
            isLibraryRootChangeInProgress = false
            scheduleRootRollbackRecovery(
                searchRepairs: rollbackSearchRepairs,
                expectedLibraryEpoch: libraryEpoch
            )
            schedulePublishedSearchRefresh()
            show(rootChangeError)
        }
    }

    /// Coalesces every initial reader and writer behind one complete library load.
    /// The task does not become ready until the persisted search index has also
    /// been reconciled, so a create/import cannot be removed by a stale rebuild.
    private func ensureBootstrapped() async throws {
        if isBootstrapped { return }
        let attempt = bootstrapAttempt ?? beginBootstrap(.none)
        try await waitForBootstrap(attempt)
    }

    private func beginBootstrap(_ preparation: BootstrapPreparation) -> BootstrapAttempt {
        let attemptID = UUID()
        isBootstrapped = false
        let requiresAuthoritativeSearchClear = preparation != .rootTransition
            && preferences.bool(forKey: Self.searchRootRebuildRequiredKey)
        if requiresAuthoritativeSearchClear {
            isSearchIndexReadyForCurrentRoot = false
            matchingNotebookIDs = searchText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty ? nil : []
            searchTargetPageIDs = [:]
        }

        let task = Task { @MainActor [self] in
            isLoading = true
            defer {
                if bootstrapAttempt?.id == attemptID {
                    isLoading = false
                }
            }

            let librarySnapshot = try await store.loadLibrary()
            // `loadLibrary` resolves and leases the authoritative Files route.
            // Describe it afterwards so cold-start bookmark resolution is not
            // duplicated by a second provider request racing the same recovery.
            let rootSnapshot = await store.rootDescription()
            try Task.checkCancellation()
            try requireCurrentBootstrapAttempt(attemptID)
            notebooks = librarySnapshot
            rootDescription = rootSnapshot
            var didClearPreviousRootSearch = !requiresAuthoritativeSearchClear
            if requiresAuthoritativeSearchClear {
                do {
                    try await searchIndex.retainNotebooks([])
                    didClearPreviousRootSearch = true
                } catch {
                    show(error)
                }
                try Task.checkCancellation()
                try requireCurrentBootstrapAttempt(attemptID)
            }
            if preparation != .rootTransition {
                if didClearPreviousRootSearch {
                    let isRootDirectoryBootstrap = preparation != .none
                    await rebuildTitleIndex(
                        reconcileCanvasOrphans: true,
                        allowHandwritingMaintenanceDuringLibraryRootChange:
                            isRootDirectoryBootstrap,
                        bootstrapAttemptID: attemptID
                    )
                }
            }
            try Task.checkCancellation()
            try requireCurrentBootstrapAttempt(attemptID)
            isBootstrapped = true
            if requiresAuthoritativeSearchClear, didClearPreviousRootSearch {
                if setSearchRootRebuildRequired(false) {
                    isSearchIndexReadyForCurrentRoot = true
                    await refreshPublishedSearchIfNeeded()
                } else {
                    isSearchIndexReadyForCurrentRoot = false
                }
            }
        }
        let attempt = BootstrapAttempt(id: attemptID, task: task)
        bootstrapAttempt = attempt
        return attempt
    }

    private func waitForBootstrap(_ attempt: BootstrapAttempt) async throws {
        do {
            try await attempt.task.value
            if bootstrapAttempt?.id == attempt.id {
                bootstrapAttempt = nil
                isLoading = false
            }
        } catch {
            if bootstrapAttempt?.id == attempt.id {
                bootstrapAttempt = nil
                isLoading = false
                isBootstrapped = false
            }
            throw error
        }
    }

    private func requireCurrentBootstrapAttempt(_ attemptID: UUID) throws {
        guard bootstrapAttempt?.id == attemptID else {
            throw CancellationError()
        }
    }

    private func cancelBootstrapAttempt(_ attempt: BootstrapAttempt) {
        attempt.task.cancel()
        guard bootstrapAttempt?.id == attempt.id else { return }
        bootstrapAttempt = nil
        isLoading = false
        isBootstrapped = false
    }

    /// A page descriptor is committed before its payload. If the second write
    /// fails, remove only that new page instead of replaying the caller's older
    /// whole-notebook snapshot over any concurrent edits.
    private func recoverFailedDuplicate(
        original: EditorNotebook,
        duplicateID: UUID,
        failureDescription: String
    ) async -> (EditorNotebook, UUID)? {
        do {
            let restored = try await store.deletePage(
                notebookID: original.id,
                pageID: duplicateID
            )
            await upsert(restored.summary)
        } catch {
            let rollbackDescription = error.localizedDescription
            if let committed = try? await store.loadNotebook(id: original.id) {
                await upsert(committed.summary)
                if !committed.pages.contains(where: { $0.id == duplicateID }) {
                    await removePageSearchDocuments(
                        notebookID: original.id,
                        pageID: duplicateID
                    )
                    show(PageDuplicationError.copyFailed(failureDescription))
                    return nil
                }
                show(PageDuplicationError.rollbackFailed(
                    copy: failureDescription,
                    rollback: rollbackDescription
                ))
                return (committed, duplicateID)
            }
            show(PageDuplicationError.recoveryFailed(
                copy: failureDescription,
                rollback: rollbackDescription
            ))
            return nil
        }

        await removePageSearchDocuments(
            notebookID: original.id,
            pageID: duplicateID
        )
        show(PageDuplicationError.copyFailed(failureDescription))
        return nil
    }

    private func flushInkOnce(_ key: InkSaveKey) async -> Bool {
        inkDebounceTasks.removeValue(forKey: key)?.cancel()

        guard let pending = pendingInkSaves.removeValue(forKey: key) else {
            guard let active = activeInkWrites[key] else {
                return inkSaveStates[key] != .failed
            }
            return (await active.task.value).succeeded
        }

        let previous = activeInkWrites[key]?.task
        let store = self.store
        let task = Task { @MainActor [self] in
            if let previous { _ = await previous.value }
            let outcome: InkWriteOutcome
            do {
                try await store.saveInk(
                    pending.data,
                    notebookID: key.notebookID,
                    page: pending.page
                )
                await reconcileHandwritingSearchAfterInkSave(
                    pending.data,
                    key: HandwritingRecognitionKey(
                        notebookID: key.notebookID,
                        pageID: key.pageID
                    ),
                    publicationGeneration: pending.handwritingGeneration
                )
                outcome = .success
            } catch {
                await reconcileHandwritingSearchWithDurableInk(
                    key: HandwritingRecognitionKey(
                        notebookID: key.notebookID,
                        pageID: key.pageID
                    ),
                    publicationGeneration: pending.handwritingGeneration
                )
                outcome = .failure(error.localizedDescription)
            }
            return finishInkWrite(outcome, pending: pending, key: key)
        }
        activeInkWrites[key] = ActiveInkWrite(generation: pending.generation, task: task)
        return (await task.value).succeeded
    }

    private func finishInkWrite(
        _ outcome: InkWriteOutcome,
        pending: PendingInkSave,
        key: InkSaveKey
    ) -> InkWriteOutcome {
        if activeInkWrites[key]?.generation == pending.generation {
            activeInkWrites.removeValue(forKey: key)
        }
        let hasNewerPending = (pendingInkSaves[key]?.generation ?? 0) > pending.generation
        let hasNewerActive = (activeInkWrites[key]?.generation ?? 0) > pending.generation
        let hasNewerWork = hasNewerPending || hasNewerActive

        switch outcome {
        case .success:
            if !hasNewerWork {
                inkSaveStates[key] = .saved
            }
            if let index = notebooks.firstIndex(where: { $0.id == key.notebookID }) {
                notebooks[index].modifiedAt = .now
            }
            return .success
        case .failure(let description):
            if hasNewerWork { return .success }
            pendingInkSaves[key] = pending
            inkSaveStates[key] = .failed
            show(InkPersistenceError.writeFailed(description))
            return .failure(description)
        }
    }

    private func flushCanvasElementsOnce(_ key: CanvasElementSaveKey) async -> Bool {
        canvasElementDebounceTasks.removeValue(forKey: key)?.cancel()

        guard let pending = pendingCanvasElementSaves.removeValue(forKey: key) else {
            guard let active = activeCanvasElementWrites[key] else {
                return canvasElementSaveStates[key] != .failed
            }
            return (await active.task.value).succeeded
        }

        let previous = activeCanvasElementWrites[key]?.task
        let store = self.store
        let task = Task { @MainActor [self] in
            if let previous { _ = await previous.value }
            let outcome: InkWriteOutcome
            do {
                try await store.saveElements(
                    pending.elements,
                    notebookID: key.notebookID,
                    pageID: key.pageID
                )
                await indexCanvasElements(
                    pending.elements,
                    notebookID: key.notebookID,
                    pageID: key.pageID
                )
                outcome = .success
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            return finishCanvasElementWrite(outcome, pending: pending, key: key)
        }
        activeCanvasElementWrites[key] = ActiveCanvasElementWrite(
            generation: pending.generation,
            task: task
        )
        return (await task.value).succeeded
    }

    private func finishCanvasElementWrite(
        _ outcome: InkWriteOutcome,
        pending: PendingCanvasElementSave,
        key: CanvasElementSaveKey
    ) -> InkWriteOutcome {
        if activeCanvasElementWrites[key]?.generation == pending.generation {
            activeCanvasElementWrites.removeValue(forKey: key)
        }
        let hasNewerPending = (pendingCanvasElementSaves[key]?.generation ?? 0) > pending.generation
        let hasNewerActive = (activeCanvasElementWrites[key]?.generation ?? 0) > pending.generation
        let hasNewerWork = hasNewerPending || hasNewerActive

        switch outcome {
        case .success:
            if !hasNewerWork {
                canvasElementSaveStates[key] = .saved
            }
            if let index = notebooks.firstIndex(where: { $0.id == key.notebookID }) {
                notebooks[index].modifiedAt = .now
            }
            return .success
        case .failure(let description):
            if hasNewerWork { return .success }
            pendingCanvasElementSaves[key] = pending
            canvasElementSaveStates[key] = .failed
            show(CanvasElementPersistenceError.writeFailed(description))
            return .failure(description)
        }
    }

    private func flushPageContentOnce(_ key: PageContentSaveKey) async -> Bool {
        pageContentDebounceTasks.removeValue(forKey: key)?.cancel()

        guard let pending = pendingPageContentSaves.removeValue(forKey: key) else {
            guard let active = activePageContentWrites[key] else {
                return pageContentSaveStates[key] != .failed
            }
            return (await active.task.value).succeeded
        }

        let previous = activePageContentWrites[key]?.task
        let store = self.store
        let task = Task { @MainActor [self] in
            if let previous { _ = await previous.value }
            let outcome: InkWriteOutcome
            do {
                try await store.savePageContent(
                    pending.content,
                    notebookID: key.notebookID,
                    pageID: key.pageID
                )
                await indexStructuredContent(
                    pending.content,
                    notebookID: key.notebookID,
                    pageID: key.pageID
                )
                outcome = .success
            } catch {
                outcome = .failure(error.localizedDescription)
            }
            return finishPageContentWrite(outcome, pending: pending, key: key)
        }
        activePageContentWrites[key] = ActivePageContentWrite(
            generation: pending.generation,
            task: task
        )
        return (await task.value).succeeded
    }

    private func finishPageContentWrite(
        _ outcome: InkWriteOutcome,
        pending: PendingPageContentSave,
        key: PageContentSaveKey
    ) -> InkWriteOutcome {
        if activePageContentWrites[key]?.generation == pending.generation {
            activePageContentWrites.removeValue(forKey: key)
        }
        let hasNewerPending = (pendingPageContentSaves[key]?.generation ?? 0) > pending.generation
        let hasNewerActive = (activePageContentWrites[key]?.generation ?? 0) > pending.generation
        let hasNewerWork = hasNewerPending || hasNewerActive

        switch outcome {
        case .success:
            if !hasNewerWork {
                pageContentSaveStates[key] = .saved
            }
            if let index = notebooks.firstIndex(where: { $0.id == key.notebookID }) {
                notebooks[index].modifiedAt = .now
            }
            return .success
        case .failure(let description):
            if hasNewerWork { return .success }
            pendingPageContentSaves[key] = pending
            pageContentSaveStates[key] = .failed
            show(PageContentPersistenceError.writeFailed(description))
            return .failure(description)
        }
    }

    private func flushPendingInk(notebookID: UUID?) async -> Bool {
        while true {
            let keys = Set(pendingInkSaves.keys)
                .union(activeInkWrites.keys)
                .filter { notebookID == nil || $0.notebookID == notebookID }
            guard !keys.isEmpty else { return true }
            for key in keys {
                if !(await flushInkOnce(key)) { return false }
            }
        }
    }

    private func flushPendingPageContent(notebookID: UUID?) async -> Bool {
        while true {
            let keys = Set(pendingPageContentSaves.keys)
                .union(activePageContentWrites.keys)
                .filter { notebookID == nil || $0.notebookID == notebookID }
            guard !keys.isEmpty else { return true }
            for key in keys {
                if !(await flushPageContentOnce(key)) { return false }
            }
        }
    }

    private func flushPendingCanvasElements(notebookID: UUID?) async -> Bool {
        while true {
            let keys = Set(pendingCanvasElementSaves.keys)
                .union(activeCanvasElementWrites.keys)
                .filter { notebookID == nil || $0.notebookID == notebookID }
            guard !keys.isEmpty else { return true }
            for key in keys {
                if !(await flushCanvasElementsOnce(key)) { return false }
            }
        }
    }

    /// Repeats every durable page queue until the selected scope is quiescent.
    /// AppModel is reentrant while awaiting file I/O, so one pass can otherwise
    /// miss an edit staged while another page payload is being committed.
    private func flushPendingWrites(notebookID: UUID?) async -> Bool {
        while true {
            let inkSucceeded = await flushPendingInk(notebookID: notebookID)
            let elementsSucceeded = await flushPendingCanvasElements(notebookID: notebookID)
            let contentSucceeded = await flushPendingPageContent(notebookID: notebookID)
            guard inkSucceeded && elementsSucceeded && contentSucceeded else {
                return false
            }
            let hasInkWork = pendingInkSaves.keys.contains {
                notebookID == nil || $0.notebookID == notebookID
            } || activeInkWrites.keys.contains {
                notebookID == nil || $0.notebookID == notebookID
            }
            let hasContentWork = pendingPageContentSaves.keys.contains {
                notebookID == nil || $0.notebookID == notebookID
            } || activePageContentWrites.keys.contains {
                notebookID == nil || $0.notebookID == notebookID
            }
            let hasElementWork = pendingCanvasElementSaves.keys.contains {
                notebookID == nil || $0.notebookID == notebookID
            } || activeCanvasElementWrites.keys.contains {
                notebookID == nil || $0.notebookID == notebookID
            }
            guard hasInkWork || hasElementWork || hasContentWork else { return true }
        }
    }

    private var hasOutstandingPageWrites: Bool {
        !pendingInkSaves.isEmpty
            || !activeInkWrites.isEmpty
            || !pendingCanvasElementSaves.isEmpty
            || !activeCanvasElementWrites.isEmpty
            || !pendingPageContentSaves.isEmpty
            || !activePageContentWrites.isEmpty
            || !deferredRootTransitionInkSaves.isEmpty
            || !deferredRootTransitionCanvasElementSaves.isEmpty
            || !deferredRootTransitionPageContentSaves.isEmpty
    }

    /// Candidate-root staging is never written until the store transaction has
    /// rolled back. Promote only the newest generation for each page, then let
    /// the caller drain the ordinary serialized queues against the old root.
    private func promoteDeferredRootTransitionWrites() {
        var promotedInkKeys: [InkSaveKey] = []
        var promotedCanvasKeys: [CanvasElementSaveKey] = []
        var promotedContentKeys: [PageContentSaveKey] = []
        for (key, pending) in deferredRootTransitionInkSaves
        where (pendingInkSaves[key]?.generation ?? 0) < pending.generation {
            pendingInkSaves[key] = pending
            inkSaveStates[key] = .saving
            promotedInkKeys.append(key)
        }
        for (key, pending) in deferredRootTransitionCanvasElementSaves
        where (pendingCanvasElementSaves[key]?.generation ?? 0) < pending.generation {
            pendingCanvasElementSaves[key] = pending
            canvasElementSaveStates[key] = .saving
            promotedCanvasKeys.append(key)
        }
        for (key, pending) in deferredRootTransitionPageContentSaves
        where (pendingPageContentSaves[key]?.generation ?? 0) < pending.generation {
            pendingPageContentSaves[key] = pending
            pageContentSaveStates[key] = .saving
            promotedContentKeys.append(key)
        }
        deferredRootTransitionInkSaves.removeAll(keepingCapacity: true)
        deferredRootTransitionCanvasElementSaves.removeAll(keepingCapacity: true)
        deferredRootTransitionPageContentSaves.removeAll(keepingCapacity: true)

        // This task is intentionally independent from the timeboxed root-change
        // caller. Even when that caller has been cancelled or its deadline has
        // expired, promoted old-root snapshots still receive a durable writer.
        for key in promotedInkKeys {
            inkDebounceTasks.removeValue(forKey: key)?.cancel()
            inkDebounceTasks[key] = Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.flushInkOnce(key)
            }
        }
        for key in promotedCanvasKeys {
            canvasElementDebounceTasks.removeValue(forKey: key)?.cancel()
            canvasElementDebounceTasks[key] = Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.flushCanvasElementsOnce(key)
            }
        }
        for key in promotedContentKeys {
            pageContentDebounceTasks.removeValue(forKey: key)?.cancel()
            pageContentDebounceTasks[key] = Task { @MainActor [weak self] in
                guard let self else { return }
                _ = await self.flushPageContentOnce(key)
            }
        }
    }

    /// Recovery outlives the cancelled/timeboxed root-change task. It first
    /// drains every old-root page queue, then reconciles handwriting only for
    /// pages whose ink is no longer pending. This prevents an accepted stale
    /// transcript from becoming visible between an unsaved edit and its retry.
    private func scheduleRootRollbackRecovery(
        searchRepairs: RootSearchRollbackRepairs,
        expectedLibraryEpoch: UInt64
    ) {
        let wholeNotebookRecoveries = Array(
            pendingWholeNotebookSearchRecoveries.values
        )
        let navigationKeys = Set(searchRepairs.pageNavigation.keys).union(
            pageNavigationSearchPublicationGenerations.keys
        )
        let navigationRepairs = navigationKeys.reduce(
            into: [PageNavigationSearchKey: UInt64]()
        ) { repairs, key in
            repairs[key] = pageNavigationSearchPublicationGenerations[key]
                ?? searchRepairs.pageNavigation[key]
        }
        guard hasOutstandingPageWrites
                || !searchRepairs.handwriting.isEmpty
                || !navigationKeys.isEmpty
                || !wholeNotebookRecoveries.isEmpty else { return }
        guard let operation = beginLibraryOperation() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishLibraryOperation(operation) }
            _ = await self.flushAllPendingWrites()
            for (key, generation) in searchRepairs.handwriting {
                let inkKey = InkSaveKey(
                    notebookID: key.notebookID,
                    pageID: key.pageID
                )
                guard self.pendingInkSaves[inkKey] == nil,
                      self.activeInkWrites[inkKey] == nil else { continue }
                await self.repairHandwritingSearch(
                    for: key,
                    publicationGeneration: generation,
                    expectedLibraryEpoch: expectedLibraryEpoch
                )
            }
            for (key, generation) in navigationRepairs {
                guard self.pageNavigationSearchPublicationGenerations[key]
                        == generation else { continue }
                await self.repairCurrentPageNavigationSearch(
                    for: key,
                    expectedLibraryEpoch: expectedLibraryEpoch,
                    cancellationRecoveryGeneration: generation
                )
            }
            for recovery in wholeNotebookRecoveries {
                guard self.pendingWholeNotebookSearchRecoveries[
                    recovery.notebookID
                ]?.id == recovery.id else { continue }
                do {
                    try await self.recoverWholeNotebookSearch(
                        recovery,
                        expectedLibraryEpoch: expectedLibraryEpoch,
                        claimedNavigationGenerations: nil
                    )
                } catch is CancellationError {
                    continue
                } catch {
                    guard self.libraryEpoch == expectedLibraryEpoch,
                          !self.isLibraryRootChangeInProgress else { continue }
                    self.show(error)
                }
            }
        }
    }

    private func discardInkState(notebookID: UUID) {
        let keys = Set(pendingInkSaves.keys)
            .union(deferredRootTransitionInkSaves.keys)
            .union(inkDebounceTasks.keys)
            .union(activeInkWrites.keys)
            .union(inkSaveStates.keys)
            .filter { $0.notebookID == notebookID }
        for key in keys {
            inkDebounceTasks.removeValue(forKey: key)?.cancel()
            activeInkWrites.removeValue(forKey: key)?.task.cancel()
            pendingInkSaves.removeValue(forKey: key)
            deferredRootTransitionInkSaves.removeValue(forKey: key)
            inkSaveStates.removeValue(forKey: key)
        }
    }

    private func discardPageContentState(notebookID: UUID, pageID: UUID? = nil) {
        let keys = Set(pendingPageContentSaves.keys)
            .union(deferredRootTransitionPageContentSaves.keys)
            .union(pageContentDebounceTasks.keys)
            .union(activePageContentWrites.keys)
            .union(pageContentSaveStates.keys)
            .filter {
                $0.notebookID == notebookID && (pageID == nil || $0.pageID == pageID)
            }
        for key in keys {
            pageContentDebounceTasks.removeValue(forKey: key)?.cancel()
            activePageContentWrites.removeValue(forKey: key)?.task.cancel()
            pendingPageContentSaves.removeValue(forKey: key)
            deferredRootTransitionPageContentSaves.removeValue(forKey: key)
            pageContentSaveStates.removeValue(forKey: key)
        }
    }

    private func discardCanvasElementState(notebookID: UUID, pageID: UUID? = nil) {
        let keys = Set(pendingCanvasElementSaves.keys)
            .union(deferredRootTransitionCanvasElementSaves.keys)
            .union(canvasElementDebounceTasks.keys)
            .union(activeCanvasElementWrites.keys)
            .union(canvasElementSaveStates.keys)
            .union(canvasSearchPublicationGenerations.keys)
            .filter {
                $0.notebookID == notebookID && (pageID == nil || $0.pageID == pageID)
            }
        for key in keys {
            canvasElementDebounceTasks.removeValue(forKey: key)?.cancel()
            activeCanvasElementWrites.removeValue(forKey: key)?.task.cancel()
            pendingCanvasElementSaves.removeValue(forKey: key)
            deferredRootTransitionCanvasElementSaves.removeValue(forKey: key)
            canvasElementSaveStates.removeValue(forKey: key)
            invalidateCanvasSearchPublication(for: key)
        }
    }

    private func discardHandwritingState(notebookID: UUID, pageID: UUID? = nil) {
        let keys = handwritingOperationGenerations.keys.filter {
            $0.notebookID == notebookID && (pageID == nil || $0.pageID == pageID)
        }
        for key in keys {
            handwritingOperationGenerations.removeValue(forKey: key)
        }
    }

    /// Reconciles a durable whole-notebook save in an independently owned task.
    /// If a root transition has already claimed the AppModel gate, the token is
    /// intentionally left pending for failed-root rollback to consume.
    private func scheduleWholeNotebookRecovery(
        _ recovery: WholeNotebookSearchRecovery,
        expectedLibraryEpoch: UInt64
    ) {
        guard pendingWholeNotebookSearchRecoveries[recovery.notebookID]?.id
                == recovery.id else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  self.pendingWholeNotebookSearchRecoveries[
                    recovery.notebookID
                  ]?.id == recovery.id,
                  let operation = self.beginLibraryOperation() else { return }
            defer { self.finishLibraryOperation(operation) }
            let crossedRootBoundary = operation.libraryEpoch
                != expectedLibraryEpoch
            do {
                try await self.recoverWholeNotebookSearch(
                    recovery,
                    expectedLibraryEpoch: operation.libraryEpoch,
                    claimedNavigationGenerations: crossedRootBoundary
                        ? nil
                        : recovery.claimedNavigationGenerations
                )
            } catch is CancellationError {
                return
            } catch {
                guard self.libraryEpoch == operation.libraryEpoch,
                      !self.isLibraryRootChangeInProgress else { return }
                self.show(error)
            }
        }
    }

    private func requireCurrentWholeNotebookSearchRecovery(
        _ recovery: WholeNotebookSearchRecovery,
        expectedLibraryEpoch: UInt64
    ) throws {
        try Task.checkCancellation()
        guard pendingWholeNotebookSearchRecoveries[recovery.notebookID]?.id
                == recovery.id,
              libraryEpoch == expectedLibraryEpoch,
              !isLibraryRootChangeInProgress,
              notebooks.contains(where: { $0.id == recovery.notebookID }) else {
            throw CancellationError()
        }
    }

    /// Rebuilds every search document whose title is derived from a notebook
    /// title, then repairs navigation metadata from a fresh durable read. A nil
    /// navigation-generation map is used after crossing any root boundary,
    /// because the transition invalidates every pre-save generation.
    private func recoverWholeNotebookSearch(
        _ recovery: WholeNotebookSearchRecovery,
        expectedLibraryEpoch: UInt64,
        claimedNavigationGenerations:
            [PageNavigationSearchKey: UInt64]?
    ) async throws {
        try requireCurrentWholeNotebookSearchRecovery(
            recovery,
            expectedLibraryEpoch: expectedLibraryEpoch
        )
        let durableNotebook = try await store.loadNotebook(
            id: recovery.notebookID
        )
        try requireCurrentWholeNotebookSearchRecovery(
            recovery,
            expectedLibraryEpoch: expectedLibraryEpoch
        )
        guard await upsert(
            durableNotebook.summary,
            invalidatesPageNavigationSearch: false
        ) else {
            throw SearchIndexError.revisionConflict(recovery.notebookID)
        }
        try requireCurrentWholeNotebookSearchRecovery(
            recovery,
            expectedLibraryEpoch: expectedLibraryEpoch
        )

        if recovery.requiresTitleReindex {
            try await retitleExistingPageSearchDocuments(in: durableNotebook)
            try requireCurrentWholeNotebookSearchRecovery(
                recovery,
                expectedLibraryEpoch: expectedLibraryEpoch
            )
            await reindexStructuredPages(in: durableNotebook)
            try requireCurrentWholeNotebookSearchRecovery(
                recovery,
                expectedLibraryEpoch: expectedLibraryEpoch
            )
            await reindexCanvasElements(in: durableNotebook)
            try requireCurrentWholeNotebookSearchRecovery(
                recovery,
                expectedLibraryEpoch: expectedLibraryEpoch
            )
            await reindexHandwritingRecognition(in: durableNotebook)
            try requireCurrentWholeNotebookSearchRecovery(
                recovery,
                expectedLibraryEpoch: expectedLibraryEpoch
            )
        }

        if let claimedNavigationGenerations {
            let stillOwned = claimedNavigationGenerations.filter {
                pageNavigationSearchPublicationGenerations[$0.key] == $0.value
            }
            if !stillOwned.isEmpty {
                await repairPageNavigationSearchAfterWholeNotebookSave(
                    notebookID: recovery.notebookID,
                    knownPageIDs: durableNotebook.pages.map(\.id),
                    expectedLibraryEpoch: expectedLibraryEpoch,
                    claimedGenerations: stillOwned
                )
            }
        } else {
            await repairPageNavigationSearchAfterWholeNotebookSave(
                notebookID: recovery.notebookID,
                knownPageIDs: durableNotebook.pages.map(\.id),
                expectedLibraryEpoch: expectedLibraryEpoch
            )
        }
        try requireCurrentWholeNotebookSearchRecovery(
            recovery,
            expectedLibraryEpoch: expectedLibraryEpoch
        )
        await refreshPublishedSearchIfNeeded()
        try requireCurrentWholeNotebookSearchRecovery(
            recovery,
            expectedLibraryEpoch: expectedLibraryEpoch
        )
        pendingWholeNotebookSearchRecoveries.removeValue(
            forKey: recovery.notebookID
        )
    }

    @discardableResult
    private func persist(
        _ notebook: EditorNotebook,
        libraryOperation: LibraryOperationContext
    ) async -> Bool {
        guard activeLibraryOperations[libraryOperation.token]
                == libraryOperation.libraryEpoch else { return false }
        var ownedNavigationGenerations:
            [PageNavigationSearchKey: UInt64] = [:]
        var didDurablySave = false
        var recovery: WholeNotebookSearchRecovery?
        let previousTitle = notebooks.first(where: {
            $0.id == notebook.id
        })?.title
        do {
            try await ensureBootstrapped()
            try requireCurrentLibraryOperation(libraryOperation)
            ownedNavigationGenerations = claimPageNavigationSearchPublications(
                notebookID: notebook.id,
                knownPageIDs: notebook.pages.map(\.id)
            )
            try await store.saveNotebook(notebook)
            didDurablySave = true
            let pendingRecovery = pendingWholeNotebookSearchRecoveries[
                notebook.id
            ]
            var mergedNavigationGenerations =
                ownedNavigationGenerations.filter {
                    pageNavigationSearchPublicationGenerations[$0.key]
                        == $0.value
                }
            if let pendingRecovery {
                for (key, generation) in
                    pendingRecovery.claimedNavigationGenerations
                where pageNavigationSearchPublicationGenerations[key]
                    == generation {
                    mergedNavigationGenerations[key] = generation
                }
            }
            let createdRecovery = WholeNotebookSearchRecovery(
                id: UUID(),
                notebookID: notebook.id,
                claimedNavigationGenerations: mergedNavigationGenerations,
                requiresTitleReindex: (previousTitle.map {
                    $0 != notebook.title
                } ?? true) || (pendingRecovery?.requiresTitleReindex ?? false)
            )
            pendingWholeNotebookSearchRecoveries[notebook.id] = createdRecovery
            recovery = createdRecovery
            try requireCurrentLibraryOperation(libraryOperation)
            try await recoverWholeNotebookSearch(
                createdRecovery,
                expectedLibraryEpoch: libraryOperation.libraryEpoch,
                claimedNavigationGenerations:
                    createdRecovery.claimedNavigationGenerations
            )
            try requireCurrentLibraryOperation(libraryOperation)
            return true
        } catch is CancellationError {
            if didDurablySave, let recovery,
               pendingWholeNotebookSearchRecoveries[notebook.id]?.id
                == recovery.id {
                // Publish the durable summary before the original operation
                // lease drains. A failed root switch snapshots only afterwards.
                await upsert(
                    notebook.summary,
                    invalidatesPageNavigationSearch: false
                )
                scheduleWholeNotebookRecovery(
                    recovery,
                    expectedLibraryEpoch: libraryOperation.libraryEpoch
                )
            } else {
                schedulePageNavigationSearchRepairs(
                    ownedGenerations: ownedNavigationGenerations,
                    expectedLibraryEpoch: libraryOperation.libraryEpoch
                )
            }
            return false
        } catch {
            if didDurablySave, let recovery,
               pendingWholeNotebookSearchRecoveries[notebook.id]?.id
                == recovery.id {
                await upsert(
                    notebook.summary,
                    invalidatesPageNavigationSearch: false
                )
                scheduleWholeNotebookRecovery(
                    recovery,
                    expectedLibraryEpoch: libraryOperation.libraryEpoch
                )
            } else {
                schedulePageNavigationSearchRepairs(
                    ownedGenerations: ownedNavigationGenerations,
                    expectedLibraryEpoch: libraryOperation.libraryEpoch
                )
            }
            show(error)
            return false
        }
    }

    @discardableResult
    private func upsert(
        _ summary: LibraryNotebook,
        invalidatesPageNavigationSearch: Bool = true
    ) async -> Bool {
        let titlePublicationGeneration =
            beginNotebookTitleSearchPublication()
        let previousTitle = notebooks.first(where: { $0.id == summary.id })?.title
        if let index = notebooks.firstIndex(where: { $0.id == summary.id }) {
            notebooks[index] = summary
        } else {
            notebooks.append(summary)
        }
        if let previousTitle, previousTitle != summary.title {
            invalidateCanvasSearchPublications(notebookID: summary.id)
            invalidateHandwritingOperations(notebookID: summary.id)
            if invalidatesPageNavigationSearch {
                invalidatePageNavigationSearchPublications(
                    notebookID: summary.id
                )
                let navigationKeys =
                    pageNavigationSearchPublicationGenerations.keys
                        .filter { $0.notebookID == summary.id }
                var didSuppressNavigationSearch = false
                for key in navigationKeys {
                    didSuppressNavigationSearch =
                        suppressPageNavigationSearchDocument(for: key)
                        || didSuppressNavigationSearch
                }
                if didSuppressNavigationSearch {
                    schedulePublishedSearchRefresh()
                }
            }
        }
        return await indexTitle(
            for: summary,
            publicationGeneration: titlePublicationGeneration
        )
    }

    private func publishPageNavigationMetadataSummary(
        _ persistedSummary: LibraryNotebook
    ) -> Bool {
        guard let index = notebooks.firstIndex(where: {
            $0.id == persistedSummary.id
        }), let merged = PageNavigationMetadataSummaryPolicy.merging(
            persistedNavigationSummary: persistedSummary,
            into: notebooks[index]
        ) else { return false }
        notebooks[index] = merged
        return true
    }

    private func rebuildTitleIndex(
        reconcileCanvasOrphans: Bool = false,
        allowHandwritingMaintenanceDuringLibraryRootChange: Bool = false,
        bootstrapAttemptID: UUID? = nil
    ) async {
        guard canContinueBootstrap(attemptID: bootstrapAttemptID) else { return }
        let notebooksToIndex = notebooks
        let validNotebookIDs = Set(notebooksToIndex.map(\.id))
        do {
            try await searchIndex.retainNotebooks(validNotebookIDs)
        } catch {
            show(error)
        }
        guard canContinueBootstrap(attemptID: bootstrapAttemptID) else { return }
        for notebook in notebooksToIndex {
            guard canContinueBootstrap(attemptID: bootstrapAttemptID) else { return }
            await indexTitle(
                for: notebook,
                publicationGeneration: beginNotebookTitleSearchPublication()
            )
            guard canContinueBootstrap(attemptID: bootstrapAttemptID) else { return }
            if let loaded = try? await store.loadNotebook(id: notebook.id) {
                guard canContinueBootstrap(attemptID: bootstrapAttemptID) else { return }
                await reindexPageNavigationMetadata(
                    in: loaded,
                    reconcileOrphans: reconcileCanvasOrphans
                )
                guard canContinueBootstrap(attemptID: bootstrapAttemptID) else { return }
                await reindexStructuredPages(
                    in: loaded,
                    reconcileOrphans: reconcileCanvasOrphans
                )
                guard canContinueBootstrap(attemptID: bootstrapAttemptID) else { return }
                await reindexCanvasElements(
                    in: loaded,
                    reconcileOrphans: reconcileCanvasOrphans
                )
                guard canContinueBootstrap(attemptID: bootstrapAttemptID) else { return }
                await reindexHandwritingRecognition(
                    in: loaded,
                    reconcileOrphans: reconcileCanvasOrphans,
                    allowDuringLibraryRootChange:
                        allowHandwritingMaintenanceDuringLibraryRootChange
                )
                guard canContinueBootstrap(attemptID: bootstrapAttemptID) else { return }
            }
            await reindexAudioTranscripts(notebookID: NotebookID(notebook.id))
            guard canContinueBootstrap(attemptID: bootstrapAttemptID) else { return }
        }
        if !searchText.isEmpty, isSearchIndexReadyForCurrentRoot {
            await searchIndexedContent()
        }
    }

    /// A root switch never leaves its UI gate waiting on derived search work.
    /// The rebuild still owns a library-operation lease, so another root switch
    /// cannot overtake it. Clearing first prevents documents from the previous
    /// root (including coincidentally reused notebook UUIDs) from being exposed.
    private func scheduleCommittedRootSearchRebuild(
        expectedRootGeneration: UInt64
    ) {
        rootSearchRebuildTask?.cancel()
        guard let operation = beginLibraryOperation() else { return }
        let generation = UUID()
        rootSearchRebuildGeneration = generation
        rootSearchRebuildTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var clearedPreviousRoot = false
            do {
                try await self.searchIndex.retainNotebooks([])
                clearedPreviousRoot = true
            } catch {
                self.show(error)
            }

            if clearedPreviousRoot,
               self.libraryRootGeneration == expectedRootGeneration,
               self.rootSearchRebuildGeneration == generation {
                await self.rebuildTitleIndex(
                    reconcileCanvasOrphans: true,
                    allowHandwritingMaintenanceDuringLibraryRootChange: true
                )
            }

            self.finishLibraryOperation(operation)
            guard self.libraryRootGeneration == expectedRootGeneration,
                  self.rootSearchRebuildGeneration == generation else { return }
            self.rootSearchRebuildGeneration = nil
            self.rootSearchRebuildTask = nil
            if clearedPreviousRoot {
                if self.setSearchRootRebuildRequired(false) {
                    self.isSearchIndexReadyForCurrentRoot = true
                    await self.refreshPublishedSearchIfNeeded()
                } else {
                    self.isSearchIndexReadyForCurrentRoot = false
                }
            } else {
                self.isSearchIndexReadyForCurrentRoot = false
            }
        }
    }

    @discardableResult
    private func setSearchRootRebuildRequired(_ isRequired: Bool) -> Bool {
        preferences.set(isRequired, forKey: Self.searchRootRebuildRequiredKey)
        // The marker is an authority fence paired with the root bookmark, not a
        // cosmetic preference. Request immediate persistence to minimize the
        // crash window before the bookmark transaction crosses its commit.
        return preferences.synchronize()
    }

    private func retryCommittedRootSearchRebuildIfNeeded() {
        guard !isSearchIndexReadyForCurrentRoot,
              rootSearchRebuildGeneration == nil,
              !isLibraryRootChangeInProgress else { return }
        scheduleCommittedRootSearchRebuild(
            expectedRootGeneration: libraryRootGeneration
        )
    }

    private func canContinueBootstrap(attemptID: UUID?) -> Bool {
        guard let attemptID else { return true }
        return !Task.isCancelled && bootstrapAttempt?.id == attemptID
    }

    private func beginNotebookTitleSearchPublication() -> UInt64 {
        notebookTitleSearchPublicationClock &+= 1
        if notebookTitleSearchPublicationClock == 0 {
            notebookTitleSearchPublicationClock = 1
        }
        return notebookTitleSearchPublicationClock
    }

    @discardableResult
    private func indexTitle(
        for notebook: LibraryNotebook,
        publicationGeneration: UInt64
    ) async -> Bool {
        var lastError: Error?
        for _ in 0..<4 {
            guard let authoritative = notebooks.first(where: {
                $0.id == notebook.id
            }) else { return false }
            do {
                let revision = try await nextSearchRevision(
                    for: authoritative.id,
                    modifiedAt: authoritative.modifiedAt
                )
                guard let current = notebooks.first(where: {
                    $0.id == authoritative.id
                }), current.title == authoritative.title,
                   current.modifiedAt == authoritative.modifiedAt else {
                    continue
                }
                try await searchIndex.upsertNotebookTitleAuthority(
                    SearchIndexDocument(
                        id: authoritative.id,
                        notebookID: authoritative.id,
                        title: authoritative.title,
                        revision: revision,
                        segments: [],
                        modifiedAt: authoritative.modifiedAt
                    ),
                    publicationGeneration: publicationGeneration
                )
                guard let latest = notebooks.first(where: {
                    $0.id == authoritative.id
                }), latest.title == authoritative.title,
                   latest.modifiedAt == authoritative.modifiedAt else {
                    continue
                }
                guard let committed = await searchIndex.document(
                    for: authoritative.id
                ) else { continue }
                guard let verifiedLatest = notebooks.first(where: {
                    $0.id == authoritative.id
                }), verifiedLatest.title == authoritative.title,
                   verifiedLatest.modifiedAt == authoritative.modifiedAt else {
                    continue
                }
                if committed.id == authoritative.id,
                   committed.notebookID == authoritative.id,
                   committed.pageID == nil,
                   committed.title == authoritative.title,
                   committed.sourceFingerprint == nil,
                   committed.segments.isEmpty {
                    return true
                }
            } catch {
                lastError = error
            }
        }
        // Search is derived and rebuilt at launch. Surface a failure, but never
        // roll back notebook state that has already committed. Whole-notebook
        // recovery treats false as a retryable authority failure.
        show(lastError ?? SearchIndexError.revisionConflict(notebook.id))
        return false
    }

    @discardableResult
    private func beginPageNavigationSearchPublication(
        for key: PageNavigationSearchKey
    ) -> UInt64 {
        pageNavigationSearchPublicationClock &+= 1
        if pageNavigationSearchPublicationClock == 0 {
            pageNavigationSearchPublicationClock = 1
        }
        pageNavigationSearchPublicationGenerations[key] =
            pageNavigationSearchPublicationClock
        reconciledPageNavigationSearchPublicationGenerations.removeValue(
            forKey: key
        )
        pageNavigationSearchRepairRequiredGenerations.removeValue(forKey: key)
        authorizedPageNavigationSearchDocuments.removeValue(
            forKey: PageNavigationSearchBuilder.documentID(
                notebookID: key.notebookID,
                pageID: key.pageID
            )
        )
        return pageNavigationSearchPublicationClock
    }

    private func invalidatePageNavigationSearchPublication(
        for key: PageNavigationSearchKey
    ) {
        _ = beginPageNavigationSearchPublication(for: key)
    }

    private func invalidatePageNavigationSearchPublications(
        notebookID: UUID
    ) {
        let keys = pageNavigationSearchPublicationGenerations.keys.filter {
            $0.notebookID == notebookID
        }
        for key in keys {
            invalidatePageNavigationSearchPublication(for: key)
        }
    }

    private func isCurrentPageNavigationSearchPublication(
        _ generation: UInt64,
        for key: PageNavigationSearchKey,
        expectedLibraryEpoch: UInt64,
        allowDuringLibraryRootChange: Bool = false
    ) -> Bool {
        !Task.isCancelled
            && pageNavigationSearchPublicationGenerations[key] == generation
            && libraryEpoch == expectedLibraryEpoch
            && (allowDuringLibraryRootChange || !isLibraryRootChangeInProgress)
    }

    @discardableResult
    private func suppressPageNavigationSearchDocument(
        for key: PageNavigationSearchKey
    ) -> Bool {
        suppressedPageNavigationSearchDocumentIDs.insert(
            PageNavigationSearchBuilder.documentID(
                notebookID: key.notebookID,
                pageID: key.pageID
            )
        ).inserted
    }

    @discardableResult
    private func unsuppressPageNavigationSearchDocument(
        for key: PageNavigationSearchKey
    ) -> Bool {
        suppressedPageNavigationSearchDocumentIDs.remove(
            PageNavigationSearchBuilder.documentID(
                notebookID: key.notebookID,
                pageID: key.pageID
            )
        ) != nil
    }

    @discardableResult
    private func authorizePageNavigationSearchDocument(
        for key: PageNavigationSearchKey,
        document: SearchIndexDocument,
        publicationGeneration: UInt64
    ) -> Bool {
        let documentID = PageNavigationSearchBuilder.documentID(
            notebookID: key.notebookID,
            pageID: key.pageID
        )
        guard pageNavigationSearchPublicationGenerations[key]
                == publicationGeneration,
              document.id == documentID,
              document.notebookID == key.notebookID,
              document.pageID == key.pageID else { return false }
        guard pageNavigationSearchRepairRequiredGenerations[key]
                != publicationGeneration else {
            schedulePageNavigationSearchRepairs(
                ownedGenerations: [key: publicationGeneration],
                expectedLibraryEpoch: libraryEpoch
            )
            return false
        }
        authorizedPageNavigationSearchDocuments[documentID] = document
        reconciledPageNavigationSearchPublicationGenerations[key] =
            publicationGeneration
        return true
    }

    private func isAuthorizedPageNavigationSearchHit(
        documentID: UUID,
        notebookID: UUID,
        pageID: UUID?,
        title: String,
        segment: RecognizedTextSegment?,
        sourceFingerprint: String?
    ) -> Bool {
        let key = pageID.map {
            PageNavigationSearchKey(notebookID: notebookID, pageID: $0)
        }
        switch segment?.source {
        case .outline, .bookmark:
            guard let key,
                  documentID == PageNavigationSearchBuilder.documentID(
                notebookID: key.notebookID,
                pageID: key.pageID
                  ), let authorized =
                    authorizedPageNavigationSearchDocuments[documentID],
                  authorized.notebookID == key.notebookID,
                  authorized.pageID == key.pageID,
                  authorized.title == title,
                  let sourceFingerprint,
                  authorized.sourceFingerprint == sourceFingerprint,
                  let segment,
                  authorized.segments.contains(segment) else { return false }
            return true
        default:
            if authorizedPageNavigationSearchDocuments[documentID] != nil {
                // A verified navigation document may expose only its explicit
                // outline/bookmark segments, never its duplicated title.
                return false
            }
            if let key,
               documentID == PageNavigationSearchBuilder.documentID(
                notebookID: key.notebookID,
                pageID: key.pageID
               ) {
                // A navigation document may not manufacture title-only or
                // mixed-source hits. Only its explicit outline/bookmark
                // segments are navigable.
                return false
            }
            // SearchIndexing owns mixed-source quarantine: any document that
            // contains navigation metadata may yield only navigation segments.
            return true
        }
    }

    /// Begins a fresh reconciliation generation after every durable completion.
    /// Reusing a mutation's generation is insufficient: two repairs can read
    /// authoritative state at different instants and then publish out of order
    /// while AppModel is reentrant across search-index actor calls.
    private func claimPageNavigationSearchPublications(
        notebookID: UUID,
        knownPageIDs: [UUID]
    ) -> [PageNavigationSearchKey: UInt64] {
        var keys = Set(
            pageNavigationSearchPublicationGenerations.keys.filter {
                $0.notebookID == notebookID
            }
        )
        keys.formUnion(knownPageIDs.map {
            PageNavigationSearchKey(notebookID: notebookID, pageID: $0)
        })
        var generations: [PageNavigationSearchKey: UInt64] = [:]
        var didSuppress = false
        for key in keys {
            generations[key] = beginPageNavigationSearchPublication(for: key)
            didSuppress = suppressPageNavigationSearchDocument(for: key)
                || didSuppress
        }
        if didSuppress { schedulePublishedSearchRefresh() }
        return generations
    }

    /// Starts recovery in an unstructured task so cancellation of the mutation
    /// that installed the fence cannot cancel its own cleanup. Generation
    /// ownership is checked before claiming a fresh repair, preventing an older
    /// recovery from interrupting a newer durable mutation.
    private func schedulePageNavigationSearchRepairs(
        ownedGenerations: [PageNavigationSearchKey: UInt64],
        expectedLibraryEpoch: UInt64
    ) {
        guard !ownedGenerations.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  self.libraryEpoch == expectedLibraryEpoch,
                  !self.isLibraryRootChangeInProgress else { return }
            for (key, generation) in ownedGenerations {
                guard self.pageNavigationSearchPublicationGenerations[key]
                        == generation else { continue }
                await self.repairCurrentPageNavigationSearch(
                    for: key,
                    expectedLibraryEpoch: expectedLibraryEpoch,
                    cancellationRecoveryGeneration: generation
                )
            }
        }
    }

    private func requirePageNavigationSearchRepairAfterInvalidatedSideEffect(
        for key: PageNavigationSearchKey,
        expectedLibraryEpoch: UInt64
    ) {
        guard libraryEpoch == expectedLibraryEpoch,
              let generation =
                pageNavigationSearchPublicationGenerations[key] else { return }
        pageNavigationSearchRepairRequiredGenerations[key] = generation
        if reconciledPageNavigationSearchPublicationGenerations[key]
                == generation {
            schedulePageNavigationSearchRepairs(
                ownedGenerations: [key: generation],
                expectedLibraryEpoch: expectedLibraryEpoch
            )
        }
    }

    private func repairCurrentPageNavigationSearch(
        for key: PageNavigationSearchKey,
        expectedLibraryEpoch: UInt64,
        cancellationRecoveryGeneration: UInt64? = nil
    ) async {
        guard libraryEpoch == expectedLibraryEpoch,
              !isLibraryRootChangeInProgress,
              notebooks.contains(where: { $0.id == key.notebookID }) else {
            return
        }
        if Task.isCancelled {
            if let generation = cancellationRecoveryGeneration
                    ?? pageNavigationSearchPublicationGenerations[key] {
                schedulePageNavigationSearchRepairs(
                    ownedGenerations: [key: generation],
                    expectedLibraryEpoch: expectedLibraryEpoch
                )
            }
            return
        }
        let generation = beginPageNavigationSearchPublication(for: key)
        let didSuppress = suppressPageNavigationSearchDocument(for: key)
        if didSuppress { schedulePublishedSearchRefresh() }
        await repairPageNavigationSearch(
            for: key,
            publicationGeneration: generation,
            expectedLibraryEpoch: expectedLibraryEpoch
        )
        if Task.isCancelled {
            schedulePageNavigationSearchRepairs(
                ownedGenerations: [key: generation],
                expectedLibraryEpoch: expectedLibraryEpoch
            )
        }
    }

    private func repairPageNavigationSearch(
        for key: PageNavigationSearchKey,
        publicationGeneration: UInt64,
        expectedLibraryEpoch: UInt64,
        allowDuringLibraryRootChange: Bool = false
    ) async {
        guard isCurrentPageNavigationSearchPublication(
            publicationGeneration,
            for: key,
            expectedLibraryEpoch: expectedLibraryEpoch,
            allowDuringLibraryRootChange: allowDuringLibraryRootChange
        ) else { return }
        do {
            let notebook = try await store.loadNotebook(id: key.notebookID)
            guard isCurrentPageNavigationSearchPublication(
                publicationGeneration,
                for: key,
                expectedLibraryEpoch: expectedLibraryEpoch,
                allowDuringLibraryRootChange: allowDuringLibraryRootChange
            ), notebooks.contains(where: { $0.id == key.notebookID }) else {
                return
            }
            guard let page = notebook.pages.first(where: {
                $0.id == key.pageID
            }) else {
                await removePageNavigationSearchDocument(
                    for: key,
                    publicationGeneration: publicationGeneration,
                    expectedLibraryEpoch: expectedLibraryEpoch,
                    allowDuringLibraryRootChange:
                        allowDuringLibraryRootChange
                )
                return
            }
            await publishPageNavigationSearchDocument(
                for: page,
                notebookID: notebook.id,
                notebookTitle: notebook.title,
                publicationGeneration: publicationGeneration,
                expectedLibraryEpoch: expectedLibraryEpoch,
                allowDuringLibraryRootChange: allowDuringLibraryRootChange
            )
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentPageNavigationSearchPublication(
                publicationGeneration,
                for: key,
                expectedLibraryEpoch: expectedLibraryEpoch,
                allowDuringLibraryRootChange: allowDuringLibraryRootChange
            ) else { return }
            // The durable page remains authoritative. Keeping this document
            // suppressed is fail-closed; bootstrap or the next mutation retries.
            show(error)
        }
    }

    private func publishPageNavigationSearchDocument(
        for page: EditorPage,
        notebookID: UUID,
        notebookTitle: String,
        publicationGeneration: UInt64,
        expectedLibraryEpoch: UInt64,
        allowDuringLibraryRootChange: Bool = false
    ) async {
        let key = PageNavigationSearchKey(
            notebookID: notebookID,
            pageID: page.id
        )
        guard isCurrentPageNavigationSearchPublication(
            publicationGeneration,
            for: key,
            expectedLibraryEpoch: expectedLibraryEpoch,
            allowDuringLibraryRootChange: allowDuringLibraryRootChange
        ) else { return }
        let documentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebookID,
            pageID: page.id
        )
        let draft = PageNavigationSearchBuilder.document(
            for: page,
            notebookID: notebookID,
            notebookTitle: notebookTitle,
            revision: 0
        )
        guard let draft else {
            await removePageNavigationSearchDocument(
                for: key,
                publicationGeneration: publicationGeneration,
                expectedLibraryEpoch: expectedLibraryEpoch,
                allowDuringLibraryRootChange: allowDuringLibraryRootChange
            )
            return
        }

        do {
            let existing = await searchIndex.document(for: documentID)
            guard isCurrentPageNavigationSearchPublication(
                publicationGeneration,
                for: key,
                expectedLibraryEpoch: expectedLibraryEpoch,
                allowDuringLibraryRootChange: allowDuringLibraryRootChange
            ) else { return }
            if let existing,
               hasSamePageNavigationSearchPayload(existing, draft) {
                let didAuthorize = authorizePageNavigationSearchDocument(
                    for: key,
                    document: draft,
                    publicationGeneration: publicationGeneration
                )
                if didAuthorize,
                   unsuppressPageNavigationSearchDocument(for: key) {
                    schedulePublishedSearchRefresh()
                }
                return
            }
            let revision = try await nextSearchRevision(
                for: documentID,
                modifiedAt: page.modifiedAt
            )
            guard isCurrentPageNavigationSearchPublication(
                publicationGeneration,
                for: key,
                expectedLibraryEpoch: expectedLibraryEpoch,
                allowDuringLibraryRootChange: allowDuringLibraryRootChange
            ), let baseDocument = PageNavigationSearchBuilder.document(
                for: page,
                notebookID: notebookID,
                notebookTitle: notebookTitle,
                revision: revision
            ) else { return }
            let didPublish = try await upsertLatestPageNavigationSearchDocument(
                baseDocument,
                key: key,
                publicationGeneration: publicationGeneration,
                expectedLibraryEpoch: expectedLibraryEpoch,
                allowDuringLibraryRootChange: allowDuringLibraryRootChange
            )
            guard didPublish,
                  isCurrentPageNavigationSearchPublication(
                    publicationGeneration,
                    for: key,
                    expectedLibraryEpoch: expectedLibraryEpoch,
                    allowDuringLibraryRootChange: allowDuringLibraryRootChange
                  ) else { return }
            let didAuthorize = authorizePageNavigationSearchDocument(
                for: key,
                document: baseDocument,
                publicationGeneration: publicationGeneration
            )
            if didAuthorize,
               unsuppressPageNavigationSearchDocument(for: key) {
                schedulePublishedSearchRefresh()
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentPageNavigationSearchPublication(
                publicationGeneration,
                for: key,
                expectedLibraryEpoch: expectedLibraryEpoch,
                allowDuringLibraryRootChange: allowDuringLibraryRootChange
            ) else { return }
            show(error)
        }
    }

    private func upsertLatestPageNavigationSearchDocument(
        _ baseDocument: SearchIndexDocument,
        key: PageNavigationSearchKey,
        publicationGeneration: UInt64,
        expectedLibraryEpoch: UInt64,
        allowDuringLibraryRootChange: Bool
    ) async throws -> Bool {
        var candidate = baseDocument
        for _ in 0 ..< 4 {
            try Task.checkCancellation()
            guard isCurrentPageNavigationSearchPublication(
                publicationGeneration,
                for: key,
                expectedLibraryEpoch: expectedLibraryEpoch,
                allowDuringLibraryRootChange: allowDuringLibraryRootChange
            ) else { return false }
            let existing = await searchIndex.document(for: baseDocument.id)
            guard isCurrentPageNavigationSearchPublication(
                publicationGeneration,
                for: key,
                expectedLibraryEpoch: expectedLibraryEpoch,
                allowDuringLibraryRootChange: allowDuringLibraryRootChange
            ) else { return false }
            if let existing {
                if hasSamePageNavigationSearchPayload(existing, baseDocument) {
                    return true
                }
                guard existing.revision < Int.max else {
                    throw SearchRevisionError.exhausted(existing.id)
                }
                candidate.revision = max(
                    baseDocument.revision,
                    existing.revision + 1
                )
            } else {
                candidate.revision = baseDocument.revision
            }
            do {
                try await searchIndex.upsertUsingCurrentNotebookTitle(
                    candidate
                )
            } catch SearchIndexError.revisionConflict(_) {
                continue
            } catch {
                if pageNavigationSearchPublicationGenerations[key]
                        != publicationGeneration {
                    requirePageNavigationSearchRepairAfterInvalidatedSideEffect(
                        for: key,
                        expectedLibraryEpoch: expectedLibraryEpoch
                    )
                }
                throw error
            }
            guard isCurrentPageNavigationSearchPublication(
                publicationGeneration,
                for: key,
                expectedLibraryEpoch: expectedLibraryEpoch,
                allowDuringLibraryRootChange: allowDuringLibraryRootChange
            ) else {
                requirePageNavigationSearchRepairAfterInvalidatedSideEffect(
                    for: key,
                    expectedLibraryEpoch: expectedLibraryEpoch
                )
                return false
            }
            guard let committed = await searchIndex.document(
                for: baseDocument.id
            ) else { continue }
            guard isCurrentPageNavigationSearchPublication(
                publicationGeneration,
                for: key,
                expectedLibraryEpoch: expectedLibraryEpoch,
                allowDuringLibraryRootChange: allowDuringLibraryRootChange
            ) else { return false }
            if hasSamePageNavigationSearchPayload(committed, baseDocument) {
                return true
            }
        }
        throw SearchIndexError.revisionConflict(baseDocument.id)
    }

    private func removePageNavigationSearchDocument(
        for key: PageNavigationSearchKey,
        publicationGeneration: UInt64,
        expectedLibraryEpoch: UInt64,
        allowDuringLibraryRootChange: Bool = false
    ) async {
        guard isCurrentPageNavigationSearchPublication(
            publicationGeneration,
            for: key,
            expectedLibraryEpoch: expectedLibraryEpoch,
            allowDuringLibraryRootChange: allowDuringLibraryRootChange
        ) else { return }
        let documentID = PageNavigationSearchBuilder.documentID(
            notebookID: key.notebookID,
            pageID: key.pageID
        )
        do {
            let existing = await searchIndex.document(for: documentID)
            guard isCurrentPageNavigationSearchPublication(
                publicationGeneration,
                for: key,
                expectedLibraryEpoch: expectedLibraryEpoch,
                allowDuringLibraryRootChange: allowDuringLibraryRootChange
            ) else { return }
            if existing != nil {
                try await searchIndex.remove(documentID: documentID)
                guard isCurrentPageNavigationSearchPublication(
                    publicationGeneration,
                    for: key,
                    expectedLibraryEpoch: expectedLibraryEpoch,
                    allowDuringLibraryRootChange: allowDuringLibraryRootChange
                ) else {
                    requirePageNavigationSearchRepairAfterInvalidatedSideEffect(
                        for: key,
                        expectedLibraryEpoch: expectedLibraryEpoch
                    )
                    return
                }
            }
            let committed = await searchIndex.document(for: documentID)
            guard isCurrentPageNavigationSearchPublication(
                publicationGeneration,
                for: key,
                expectedLibraryEpoch: expectedLibraryEpoch,
                allowDuringLibraryRootChange: allowDuringLibraryRootChange
            ), committed == nil else { return }
            guard pageNavigationSearchRepairRequiredGenerations[key]
                    != publicationGeneration else {
                schedulePageNavigationSearchRepairs(
                    ownedGenerations: [key: publicationGeneration],
                    expectedLibraryEpoch: expectedLibraryEpoch
                )
                return
            }
            reconciledPageNavigationSearchPublicationGenerations[key] =
                publicationGeneration
            // Desired absence is a tombstone, not a verified visible state.
            // Keep suppression after physical removal so an already-sent stale
            // upsert cannot resurrect cleared or deleted metadata in search.
        } catch {
            guard isCurrentPageNavigationSearchPublication(
                publicationGeneration,
                for: key,
                expectedLibraryEpoch: expectedLibraryEpoch,
                allowDuringLibraryRootChange: allowDuringLibraryRootChange
            ) else {
                requirePageNavigationSearchRepairAfterInvalidatedSideEffect(
                    for: key,
                    expectedLibraryEpoch: expectedLibraryEpoch
                )
                return
            }
            show(error)
        }
    }

    private func hasSamePageNavigationSearchPayload(
        _ left: SearchIndexDocument,
        _ right: SearchIndexDocument
    ) -> Bool {
        left.id == right.id
            && left.notebookID == right.notebookID
            && left.pageID == right.pageID
            && left.title == right.title
            && left.sourceFingerprint == right.sourceFingerprint
            && left.segments == right.segments
            && left.modifiedAt == right.modifiedAt
    }

    /// Whole-notebook saves (rename, favorite, trash restore) must reconcile
    /// navigation search from a post-save durable read. Generations are claimed
    /// before that read, so a later narrow metadata mutation invalidates only
    /// its page and cannot be overwritten by this bulk repair.
    private func repairPageNavigationSearchAfterWholeNotebookSave(
        notebookID: UUID,
        knownPageIDs: [UUID],
        expectedLibraryEpoch: UInt64,
        claimedGenerations:
            [PageNavigationSearchKey: UInt64]? = nil
    ) async {
        guard libraryEpoch == expectedLibraryEpoch,
              !isLibraryRootChangeInProgress else { return }
        let usesPreclaimedGenerations = claimedGenerations != nil
        var generations = claimedGenerations
            ?? claimPageNavigationSearchPublications(
                notebookID: notebookID,
                knownPageIDs: knownPageIDs
            )
        let initiallyClaimedKeys = Set(generations.keys)

        do {
            let authoritativeNotebook = try await store.loadNotebook(
                id: notebookID
            )
            guard libraryEpoch == expectedLibraryEpoch,
                  !isLibraryRootChangeInProgress,
                  notebooks.contains(where: { $0.id == notebookID }) else {
                return
            }
            for page in authoritativeNotebook.pages {
                let key = PageNavigationSearchKey(
                    notebookID: notebookID,
                    pageID: page.id
                )
                if generations[key] == nil, !usesPreclaimedGenerations {
                    generations[key] = beginPageNavigationSearchPublication(
                        for: key
                    )
                    if suppressPageNavigationSearchDocument(for: key) {
                        schedulePublishedSearchRefresh()
                    }
                }
            }
            let durablePageIDs = Set(authoritativeNotebook.pages.map(\.id))
            for key in initiallyClaimedKeys
                where !durablePageIDs.contains(key.pageID) {
                guard let generation = generations[key] else { continue }
                await removePageNavigationSearchDocument(
                    for: key,
                    publicationGeneration: generation,
                    expectedLibraryEpoch: expectedLibraryEpoch
                )
            }
            for page in authoritativeNotebook.pages {
                let key = PageNavigationSearchKey(
                    notebookID: notebookID,
                    pageID: page.id
                )
                guard let generation = generations[key] else { continue }
                await publishPageNavigationSearchDocument(
                    for: page,
                    notebookID: notebookID,
                    notebookTitle: authoritativeNotebook.title,
                    publicationGeneration: generation,
                    expectedLibraryEpoch: expectedLibraryEpoch
                )
            }
            if Task.isCancelled {
                schedulePageNavigationSearchRepairs(
                    ownedGenerations: generations,
                    expectedLibraryEpoch: expectedLibraryEpoch
                )
            }
        } catch is CancellationError {
            schedulePageNavigationSearchRepairs(
                ownedGenerations: generations,
                expectedLibraryEpoch: expectedLibraryEpoch
            )
        } catch {
            guard libraryEpoch == expectedLibraryEpoch,
                  !isLibraryRootChangeInProgress else { return }
            show(error)
        }
    }

    private func reindexPageNavigationMetadata(
        in notebook: EditorNotebook,
        reconcileOrphans: Bool = false,
        expectedLibraryEpoch: UInt64? = nil,
        allowDuringLibraryRootChange: Bool = false
    ) async {
        let epoch = expectedLibraryEpoch ?? libraryEpoch
        guard !Task.isCancelled,
              libraryEpoch == epoch,
              allowDuringLibraryRootChange
                || !isLibraryRootChangeInProgress else { return }
        var generations: [PageNavigationSearchKey: UInt64] = [:]
        for page in notebook.pages {
            let key = PageNavigationSearchKey(
                notebookID: notebook.id,
                pageID: page.id
            )
            generations[key] = beginPageNavigationSearchPublication(for: key)
            _ = suppressPageNavigationSearchDocument(for: key)
        }
        schedulePublishedSearchRefresh()

        if reconcileOrphans {
            let outlinedDocumentIDs = Set(notebook.pages.compactMap { page in
                page.outlineTitle == nil ? nil
                    : PageNavigationSearchBuilder.documentID(
                        notebookID: notebook.id,
                        pageID: page.id
                    )
            })
            let bookmarkedDocumentIDs = Set(notebook.pages.compactMap { page in
                page.isBookmarked
                    ? PageNavigationSearchBuilder.documentID(
                        notebookID: notebook.id,
                        pageID: page.id
                    )
                    : nil
            })
            do {
                try await searchIndex.retainDocuments(
                    notebookID: notebook.id,
                    source: .outline,
                    documentIDs: outlinedDocumentIDs
                )
                guard !Task.isCancelled,
                      libraryEpoch == epoch,
                      allowDuringLibraryRootChange
                        || !isLibraryRootChangeInProgress else { return }
                try await searchIndex.retainDocuments(
                    notebookID: notebook.id,
                    source: .bookmark,
                    documentIDs: bookmarkedDocumentIDs
                )
                guard !Task.isCancelled,
                      libraryEpoch == epoch,
                      allowDuringLibraryRootChange
                        || !isLibraryRootChangeInProgress else { return }
            } catch {
                guard !Task.isCancelled,
                      libraryEpoch == epoch,
                      allowDuringLibraryRootChange
                        || !isLibraryRootChangeInProgress else { return }
                show(error)
            }
        }

        for page in notebook.pages {
            let key = PageNavigationSearchKey(
                notebookID: notebook.id,
                pageID: page.id
            )
            guard let generation = generations[key] else { continue }
            await publishPageNavigationSearchDocument(
                for: page,
                notebookID: notebook.id,
                notebookTitle: notebook.title,
                publicationGeneration: generation,
                expectedLibraryEpoch: epoch,
                allowDuringLibraryRootChange: allowDuringLibraryRootChange
            )
        }
    }

    private func indexStructuredContent(
        _ content: PageContent,
        notebookID: UUID,
        pageID: UUID
    ) async {
        guard let notebook = notebooks.first(where: { $0.id == notebookID }) else { return }
        let segment = StructuredContentSearchBuilder.segment(for: content, pageID: pageID)

        do {
            guard let segment else {
                try await searchIndex.remove(documentID: pageID)
                if !searchText.isEmpty { await searchIndexedContent() }
                return
            }
            let revision = try await nextSearchRevision(for: pageID)
            try await searchIndex.upsertUsingCurrentNotebookTitle(
                SearchIndexDocument(
                    id: pageID,
                    notebookID: notebookID,
                    pageID: pageID,
                    title: notebook.title,
                    revision: revision,
                    segments: [segment]
                )
            )
            if !searchText.isEmpty { await searchIndexedContent() }
        } catch {
            // Search is derived state. Keep the successfully committed page content.
            show(error)
        }
    }

    /// Retitles existing raw, canvas, and accepted-handwriting documents from
    /// the index's current notebook-title authority. Each operation preserves
    /// the latest payload and treats an already removed document as absent.
    private func retitleExistingPageSearchDocuments(
        in notebook: EditorNotebook
    ) async throws {
        for page in notebook.pages {
            let documentIDs = [
                page.id,
                CanvasElementSearchBuilder.documentID(
                    notebookID: notebook.id,
                    pageID: page.id
                ),
                HandwritingSearchBuilder.documentID(
                    notebookID: notebook.id,
                    pageID: page.id
                ),
            ]
            for documentID in documentIDs {
                try Task.checkCancellation()
                try await searchIndex.retitleDocument(
                    documentID: documentID,
                    notebookID: notebook.id,
                    pageID: page.id
                )
            }
        }
    }

    private func reindexStructuredPages(
        in notebook: EditorNotebook,
        reconcileOrphans: Bool = false
    ) async {
        if reconcileOrphans {
            let validPageDocumentIDs = Set(notebook.pages.map(\.id))
            for source in [
                RecognizedTextSource.typedText,
                .pdfText,
                .scannedImage,
            ] {
                guard !Task.isCancelled else { return }
                do {
                    try await searchIndex.retainDocuments(
                        notebookID: notebook.id,
                        source: source,
                        documentIDs: validPageDocumentIDs
                    )
                } catch {
                    show(error)
                }
            }
        }
        for page in notebook.pages {
            guard !Task.isCancelled else { return }
            guard page.kind == .textDocument || page.kind == .studySet else { continue }
            do {
                if let content = try await store.loadPageContent(
                    notebookID: notebook.id,
                    pageID: page.id
                ) {
                    await indexStructuredContent(
                        content,
                        notebookID: notebook.id,
                        pageID: page.id
                    )
                }
            } catch {
                show(error)
            }
        }
    }

    private func indexCanvasElements(
        _ elements: [CanvasElement],
        notebookID: UUID,
        pageID: UUID,
        modifiedAt: Date? = nil,
        publicationGeneration suppliedPublicationGeneration: UInt64? = nil
    ) async {
        let key = CanvasElementSaveKey(
            notebookID: notebookID,
            pageID: pageID
        )
        let publicationGeneration = suppliedPublicationGeneration
            ?? beginCanvasSearchPublication(for: key)
        let documentID = CanvasElementSearchBuilder.documentID(
            notebookID: notebookID,
            pageID: pageID
        )
        let segments = CanvasElementSearchBuilder.segments(
            for: elements,
            pageID: pageID
        )

        do {
            guard !segments.isEmpty else {
                let existing = await searchIndex.document(for: documentID)
                guard isCurrentCanvasSearchPublication(
                    publicationGeneration,
                    for: key
                ) else { return }
                if existing != nil {
                    try await searchIndex.remove(documentID: documentID)
                    guard isCurrentCanvasSearchPublication(
                        publicationGeneration,
                        for: key
                    ) else { return }
                    if !searchText.isEmpty { await searchIndexedContent() }
                }
                return
            }
            guard let documentTitle = notebooks.first(
                where: { $0.id == notebookID }
            )?.title else {
                return
            }
            let fingerprint = CanvasElementSearchBuilder.sourceFingerprint(
                for: segments
            )
            let existing = await searchIndex.document(for: documentID)
            guard isCurrentCanvasSearchPublication(
                publicationGeneration,
                for: key
            ) else { return }
            if let existing,
               existing.notebookID == notebookID,
               existing.pageID == pageID,
               existing.title == documentTitle,
               existing.sourceFingerprint == fingerprint,
               existing.segments == segments {
                return
            }
            let sourceDate = modifiedAt
                ?? elements.lazy.map(\.modifiedAt).max()
                ?? .now
            let revision = try await nextSearchRevision(
                for: documentID,
                modifiedAt: sourceDate
            )
            guard isCurrentCanvasSearchPublication(
                publicationGeneration,
                for: key
            ) else { return }
            let didPublish = try await upsertLatestCanvasSearchDocument(
                SearchIndexDocument(
                    id: documentID,
                    notebookID: notebookID,
                    pageID: pageID,
                    title: documentTitle,
                    revision: revision,
                    sourceFingerprint: fingerprint,
                    segments: segments,
                    modifiedAt: sourceDate
                ),
                key: key,
                publicationGeneration: publicationGeneration
            )
            guard didPublish,
                  isCurrentCanvasSearchPublication(
                      publicationGeneration,
                      for: key
                  ) else { return }
            if !searchText.isEmpty { await searchIndexedContent() }
        } catch {
            // The element payload is already durable. Search remains derived
            // state and is repaired by the next save or library bootstrap.
            show(error)
        }
    }

    private func upsertLatestCanvasSearchDocument(
        _ baseDocument: SearchIndexDocument,
        key: CanvasElementSaveKey,
        publicationGeneration: UInt64
    ) async throws -> Bool {
        var candidate = baseDocument
        for _ in 0..<4 {
            try Task.checkCancellation()
            guard isCurrentCanvasSearchPublication(
                publicationGeneration,
                for: key
            ) else { return false }
            let existing = await searchIndex.document(for: baseDocument.id)
            guard isCurrentCanvasSearchPublication(
                publicationGeneration,
                for: key
            ) else { return false }
            if let existing {
                if hasSameCanvasSearchPayload(existing, baseDocument) {
                    return true
                }
                guard existing.revision < Int.max else {
                    throw SearchRevisionError.exhausted(existing.id)
                }
                candidate.revision = max(
                    baseDocument.revision,
                    existing.revision + 1
                )
            } else {
                candidate.revision = baseDocument.revision
            }

            do {
                try await searchIndex.upsertUsingCurrentNotebookTitle(
                    candidate
                )
            } catch SearchIndexError.revisionConflict(_) {
                continue
            }
            guard isCurrentCanvasSearchPublication(
                publicationGeneration,
                for: key
            ) else { return false }
            guard let committed = await searchIndex.document(
                for: baseDocument.id
            ) else {
                continue
            }
            guard isCurrentCanvasSearchPublication(
                publicationGeneration,
                for: key
            ) else { return false }
            if hasSameCanvasSearchPayload(committed, baseDocument) {
                return true
            }
        }
        throw SearchIndexError.revisionConflict(baseDocument.id)
    }

    private func beginCanvasSearchPublication(
        for key: CanvasElementSaveKey
    ) -> UInt64 {
        canvasSearchPublicationClock &+= 1
        if canvasSearchPublicationClock == 0 {
            canvasSearchPublicationClock = 1
        }
        canvasSearchPublicationGenerations[key] = canvasSearchPublicationClock
        return canvasSearchPublicationClock
    }

    private func invalidateCanvasSearchPublication(
        for key: CanvasElementSaveKey
    ) {
        _ = beginCanvasSearchPublication(for: key)
    }

    private func invalidateCanvasSearchPublications(notebookID: UUID) {
        let keys = canvasSearchPublicationGenerations.keys.filter {
            $0.notebookID == notebookID
        }
        for key in keys {
            invalidateCanvasSearchPublication(for: key)
        }
    }

    private func isCurrentCanvasSearchPublication(
        _ generation: UInt64,
        for key: CanvasElementSaveKey
    ) -> Bool {
        canvasSearchPublicationGenerations[key] == generation
    }

    private func hasSameCanvasSearchPayload(
        _ left: SearchIndexDocument,
        _ right: SearchIndexDocument
    ) -> Bool {
        left.id == right.id
            && left.notebookID == right.notebookID
            && left.pageID == right.pageID
            && left.title == right.title
            && left.sourceFingerprint == right.sourceFingerprint
            && left.segments == right.segments
    }

    private func reindexCanvasElements(
        in notebook: EditorNotebook,
        reconcileOrphans: Bool = false
    ) async {
        let drawablePages = notebook.pages.filter { page in
            switch page.kind {
            case .notebook, .whiteboard, .importedDocument:
                return true
            case .textDocument, .studySet:
                return false
            }
        }
        if reconcileOrphans {
            let retainedDocumentIDs = Set(drawablePages.map { page in
                CanvasElementSearchBuilder.documentID(
                    notebookID: notebook.id,
                    pageID: page.id
                )
            })
            do {
                try await searchIndex.retainDocuments(
                    notebookID: notebook.id,
                    source: .canvasElement,
                    documentIDs: retainedDocumentIDs
                )
            } catch {
                show(error)
            }
        }

        for page in drawablePages {
            let key = CanvasElementSaveKey(
                notebookID: notebook.id,
                pageID: page.id
            )
            let publicationGeneration = beginCanvasSearchPublication(for: key)
            do {
                let elements = try await store.loadElements(
                    notebookID: notebook.id,
                    pageID: page.id
                )
                await indexCanvasElements(
                    elements,
                    notebookID: notebook.id,
                    pageID: page.id,
                    modifiedAt: page.modifiedAt,
                    publicationGeneration: publicationGeneration
                )
            } catch {
                guard isCurrentCanvasSearchPublication(
                    publicationGeneration,
                    for: key
                ) else { continue }
                let documentID = CanvasElementSearchBuilder.documentID(
                    notebookID: notebook.id,
                    pageID: page.id
                )
                try? await searchIndex.remove(documentID: documentID)
                // Fail closed: unreadable durable source must not leave stale
                // canvas text visible in search snippets.
                show(error)
            }
        }
    }

    private func indexHandwritingRecognition(
        _ document: HandwritingRecognitionDocument,
        notebookID: UUID,
        pageID: UUID,
        publicationGeneration suppliedGeneration: UInt64? = nil
    ) async {
        let key = HandwritingRecognitionKey(
            notebookID: notebookID,
            pageID: pageID
        )
        let generation = suppliedGeneration ?? beginHandwritingOperation(for: key)
        let documentID = HandwritingSearchBuilder.documentID(
            notebookID: notebookID,
            pageID: pageID
        )
        guard isCurrentHandwritingOperation(generation, for: key) else { return }
        let didSuppress = suppressHandwritingSearchDocument(documentID)
        if didSuppress {
            await refreshPublishedSearchIfNeeded()
            guard isCurrentHandwritingOperation(generation, for: key) else { return }
        }
        do {
            let corePageID = PageID(pageID)
            let segments = try HandwritingSearchBuilder.segments(
                for: document,
                expectedPageID: corePageID
            )
            let fingerprint = try HandwritingSearchBuilder.sourceFingerprint(
                for: document,
                expectedPageID: corePageID
            )
            guard isCurrentHandwritingOperation(generation, for: key) else { return }
            guard !segments.isEmpty else {
                let existing = await searchIndex.document(for: documentID)
                guard isCurrentHandwritingOperation(generation, for: key) else { return }
                if existing != nil {
                    try await searchIndex.remove(documentID: documentID)
                    guard isCurrentHandwritingOperation(generation, for: key) else { return }
                }
                return
            }
            guard let title = notebooks.first(where: { $0.id == notebookID })?.title else {
                return
            }
            let existing = await searchIndex.document(for: documentID)
            guard isCurrentHandwritingOperation(generation, for: key) else { return }
            let baseDocument = SearchIndexDocument(
                id: documentID,
                notebookID: notebookID,
                pageID: pageID,
                title: title,
                revision: try await nextSearchRevision(
                    for: documentID,
                    modifiedAt: document.modifiedAt
                ),
                sourceFingerprint: fingerprint,
                segments: segments,
                modifiedAt: document.modifiedAt
            )
            guard isCurrentHandwritingOperation(generation, for: key) else { return }
            if let existing, hasSameHandwritingSearchPayload(existing, baseDocument) {
                let didUnsuppress = unsuppressHandwritingSearchDocument(documentID)
                if didUnsuppress { await refreshPublishedSearchIfNeeded() }
                return
            }
            let didPublish = try await upsertLatestHandwritingSearchDocument(
                baseDocument,
                key: key,
                publicationGeneration: generation
            )
            guard didPublish,
                  isCurrentHandwritingOperation(generation, for: key) else { return }
            let didUnsuppress = unsuppressHandwritingSearchDocument(documentID)
            if didUnsuppress { await refreshPublishedSearchIfNeeded() }
        } catch is CancellationError {
            return
        } catch {
            // The reviewed sidecar is authoritative. Search is derived and is
            // retried on the next review, save, rename, or library bootstrap.
            show(error)
        }
    }

    private func upsertLatestHandwritingSearchDocument(
        _ baseDocument: SearchIndexDocument,
        key: HandwritingRecognitionKey,
        publicationGeneration: UInt64
    ) async throws -> Bool {
        var candidate = baseDocument
        for _ in 0 ..< 4 {
            try Task.checkCancellation()
            guard isCurrentHandwritingOperation(
                publicationGeneration,
                for: key
            ) else { return false }
            let existing = await searchIndex.document(for: baseDocument.id)
            guard isCurrentHandwritingOperation(
                publicationGeneration,
                for: key
            ) else { return false }
            if let existing {
                if hasSameHandwritingSearchPayload(existing, baseDocument) {
                    return true
                }
                guard existing.revision < Int.max else {
                    throw SearchRevisionError.exhausted(existing.id)
                }
                candidate.revision = max(
                    baseDocument.revision,
                    existing.revision + 1
                )
            } else {
                candidate.revision = baseDocument.revision
            }
            do {
                try await searchIndex.upsertUsingCurrentNotebookTitle(
                    candidate
                )
            } catch SearchIndexError.revisionConflict(_) {
                continue
            }
            guard isCurrentHandwritingOperation(
                publicationGeneration,
                for: key
            ) else { return false }
            guard let committed = await searchIndex.document(
                for: baseDocument.id
            ) else { continue }
            guard isCurrentHandwritingOperation(
                publicationGeneration,
                for: key
            ) else { return false }
            if hasSameHandwritingSearchPayload(committed, baseDocument) {
                return true
            }
        }
        throw SearchIndexError.revisionConflict(baseDocument.id)
    }

    private func hasSameHandwritingSearchPayload(
        _ left: SearchIndexDocument,
        _ right: SearchIndexDocument
    ) -> Bool {
        left.id == right.id
            && left.notebookID == right.notebookID
            && left.pageID == right.pageID
            && left.title == right.title
            && left.sourceFingerprint == right.sourceFingerprint
            && left.segments == right.segments
    }

    private func beginHandwritingOperation(
        for key: HandwritingRecognitionKey
    ) -> UInt64 {
        handwritingOperationClock &+= 1
        if handwritingOperationClock == 0 { handwritingOperationClock = 1 }
        handwritingOperationGenerations[key] = handwritingOperationClock
        return handwritingOperationClock
    }

    private func beginHandwritingMutation(
        for key: HandwritingRecognitionKey,
        allowingLibraryRootChange: Bool = false
    ) -> HandwritingMutationContext? {
        guard allowingLibraryRootChange || !isLibraryRootChangeInProgress else { return nil }
        let context = HandwritingMutationContext(
            token: UUID(),
            key: key,
            libraryEpoch: libraryEpoch,
            allowsLibraryRootChange: allowingLibraryRootChange
        )
        activeHandwritingMutations[context.token] = key
        return context
    }

    private func finishHandwritingMutation(_ context: HandwritingMutationContext) {
        activeHandwritingMutations.removeValue(forKey: context.token)
    }

    private func requireCurrentHandwritingMutation(
        _ context: HandwritingMutationContext
    ) throws {
        guard activeHandwritingMutations[context.token] == context.key,
              isCurrentLibraryEpoch(
                  context.libraryEpoch,
                  allowingLibraryRootChange: context.allowsLibraryRootChange
              ) else {
            throw CancellationError()
        }
    }

    private func isCurrentLibraryEpoch(
        _ expectedEpoch: UInt64,
        allowingLibraryRootChange: Bool = false
    ) -> Bool {
        libraryEpoch == expectedEpoch
            && (allowingLibraryRootChange || !isLibraryRootChangeInProgress)
    }

    private func beginLibraryOperation() -> LibraryOperationContext? {
        guard !isLibraryRootChangeInProgress else { return nil }
        let context = LibraryOperationContext(
            token: UUID(),
            libraryEpoch: libraryEpoch
        )
        activeLibraryOperations[context.token] = context.libraryEpoch
        return context
    }

    private func requireCurrentLibraryOperation(
        _ context: LibraryOperationContext
    ) throws {
        try Task.checkCancellation()
        guard activeLibraryOperations[context.token] == context.libraryEpoch,
              context.libraryEpoch == libraryEpoch,
              !isLibraryRootChangeInProgress else {
            throw CancellationError()
        }
    }

    private func finishLibraryOperation(_ context: LibraryOperationContext) {
        activeLibraryOperations.removeValue(forKey: context.token)
    }

    private func runRootOperation<Value: Sendable>(
        before deadline: ContinuousClock.Instant,
        operation: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let clock = ContinuousClock()
        let remaining = clock.now.duration(to: deadline)
        guard remaining > .zero else {
            throw LibraryRootChangeError.operationsDidNotFinish
        }

        let race = RootOperationRace<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.installContinuation(continuation)
                let operationTask = Task { @MainActor in
                    do {
                        try Task.checkCancellation()
                        let value = try await operation()
                        race.resolve(.success(value), cancelOperation: false)
                    } catch {
                        race.resolve(.failure(error), cancelOperation: false)
                    }
                }
                let timeoutTask = Task.detached {
                    do {
                        try await Task.sleep(for: remaining)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    race.resolve(
                        .failure(LibraryRootChangeError.operationsDidNotFinish),
                        cancelOperation: true
                    )
                }
                race.installTasks(operation: operationTask, timeout: timeoutTask)
            }
        } onCancel: {
            race.resolve(.failure(CancellationError()), cancelOperation: true)
        }
    }

    private func waitForLibraryOperationsToQuiesce(
        before deadline: ContinuousClock.Instant
    ) async throws {
        let clock = ContinuousClock()
        try Task.checkCancellation()
        while !activeLibraryOperations.isEmpty || !activeHandwritingMutations.isEmpty {
            guard clock.now < deadline else {
                throw LibraryRootChangeError.operationsDidNotFinish
            }
            try await Task.sleep(for: .milliseconds(50))
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
    }

    private func beginLibraryRootChange() -> RootSearchRollbackRepairs {
        isLibraryRootChangeInProgress = true
        isInstallingLibraryRoot = false
        didStagePageMutationDuringLibraryRootChange = false
        searchPublicationGeneration &+= 1
        if searchPublicationGeneration == 0 { searchPublicationGeneration = 1 }
        libraryEpoch &+= 1
        if libraryEpoch == 0 { libraryEpoch = 1 }

        let handwritingKeys = Set(handwritingOperationGenerations.keys)
            .union(activeHandwritingRecognitionKeys)
            .union(activeHandwritingMutations.values)
        var didAddSuppression = false
        var rollbackRepairs = RootSearchRollbackRepairs()
        for key in handwritingKeys {
            let generation = beginHandwritingOperation(for: key)
            rollbackRepairs.handwriting[key] = generation
            didAddSuppression = suppressHandwritingSearchDocument(
                HandwritingSearchBuilder.documentID(
                    notebookID: key.notebookID,
                    pageID: key.pageID
                )
            ) || didAddSuppression
        }
        for key in Array(pageNavigationSearchPublicationGenerations.keys) {
            let generation = beginPageNavigationSearchPublication(for: key)
            rollbackRepairs.pageNavigation[key] = generation
            didAddSuppression = suppressPageNavigationSearchDocument(
                for: key
            ) || didAddSuppression
        }
        for key in Array(canvasSearchPublicationGenerations.keys) {
            invalidateCanvasSearchPublication(for: key)
        }
        if didAddSuppression { schedulePublishedSearchRefresh() }
        return rollbackRepairs
    }

    private func invalidateHandwritingOperation(
        for key: HandwritingRecognitionKey
    ) {
        _ = beginHandwritingOperation(for: key)
    }

    private func invalidateHandwritingOperations(notebookID: UUID) {
        let keys = handwritingOperationGenerations.keys.filter {
            $0.notebookID == notebookID
        }
        for key in keys { invalidateHandwritingOperation(for: key) }
    }

    private func isCurrentHandwritingOperation(
        _ generation: UInt64,
        for key: HandwritingRecognitionKey
    ) -> Bool {
        handwritingOperationGenerations[key] == generation
    }

    @discardableResult
    private func suppressHandwritingSearchDocument(_ documentID: UUID) -> Bool {
        suppressedHandwritingSearchDocumentIDs.insert(documentID).inserted
    }

    @discardableResult
    private func unsuppressHandwritingSearchDocument(_ documentID: UUID) -> Bool {
        suppressedHandwritingSearchDocumentIDs.remove(documentID) != nil
    }

    private func refreshPublishedSearchIfNeeded() async {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        await searchIndexedContent()
    }

    private func schedulePublishedSearchRefresh() {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        Task { @MainActor [weak self] in
            await self?.searchIndexedContent()
        }
    }

    private func repairHandwritingSearch(
        for key: HandwritingRecognitionKey,
        publicationGeneration suppliedGeneration: UInt64? = nil,
        expectedLibraryEpoch: UInt64? = nil,
        allowDuringLibraryRootChange: Bool = false
    ) async {
        guard let mutation = beginHandwritingMutation(
            for: key,
            allowingLibraryRootChange: allowDuringLibraryRootChange
        ) else { return }
        defer { finishHandwritingMutation(mutation) }
        guard expectedLibraryEpoch == nil
                || expectedLibraryEpoch == mutation.libraryEpoch else { return }

        let generation: UInt64
        if let suppliedGeneration {
            guard isCurrentHandwritingOperation(suppliedGeneration, for: key) else { return }
            generation = suppliedGeneration
        } else {
            generation = beginHandwritingOperation(for: key)
        }
        do {
            try requireCurrentHandwritingMutation(mutation)
            let document = try await store.loadHandwritingRecognition(
                notebookID: key.notebookID,
                pageID: key.pageID
            )
            try requireCurrentHandwritingMutation(mutation)
            guard isCurrentHandwritingOperation(generation, for: key) else { return }
            guard let document else {
                await removeHandwritingSearchDocument(
                    for: key,
                    publicationGeneration: generation
                )
                return
            }
            let ink = try await store.loadInkForHandwritingRecognition(
                notebookID: key.notebookID,
                pageID: key.pageID
            )
            try requireCurrentHandwritingMutation(mutation)
            guard isCurrentHandwritingOperation(generation, for: key) else { return }
            guard let ink,
                  HandwritingRecognitionPipeline.sourceInkSHA256(for: ink)
                    == document.sourceInkSHA256 else {
                await removeHandwritingSearchDocument(
                    for: key,
                    publicationGeneration: generation
                )
                return
            }
            await indexHandwritingRecognition(
                document,
                notebookID: key.notebookID,
                pageID: key.pageID,
                publicationGeneration: generation
            )
        } catch is CancellationError {
            return
        } catch {
            await removeHandwritingSearchDocument(
                for: key,
                publicationGeneration: generation
            )
        }
    }

    private func scheduleHandwritingSearchRepair(
        for key: HandwritingRecognitionKey,
        publicationGeneration: UInt64,
        expectedLibraryEpoch: UInt64
    ) {
        Task { @MainActor [weak self] in
            await self?.repairHandwritingSearch(
                for: key,
                publicationGeneration: publicationGeneration,
                expectedLibraryEpoch: expectedLibraryEpoch
            )
        }
    }

    private func reconcileHandwritingSearchAfterInkSave(
        _ ink: Data,
        key: HandwritingRecognitionKey,
        publicationGeneration: UInt64
    ) async {
        guard isCurrentHandwritingOperation(
            publicationGeneration,
            for: key
        ) else { return }
        do {
            guard let document = try await store.loadHandwritingRecognition(
                notebookID: key.notebookID,
                pageID: key.pageID
            ) else {
                await removeHandwritingSearchDocument(
                    for: key,
                    publicationGeneration: publicationGeneration
                )
                return
            }
            guard document.sourceInkSHA256
                    != HandwritingRecognitionPipeline.sourceInkSHA256(for: ink) else {
                await indexHandwritingRecognition(
                    document,
                    notebookID: key.notebookID,
                    pageID: key.pageID,
                    publicationGeneration: publicationGeneration
                )
                return
            }
            await removeHandwritingSearchDocument(
                for: key,
                publicationGeneration: publicationGeneration
            )
        } catch {
            // If the durable review source cannot be verified, fail closed by
            // removing only its derived search document.
            await removeHandwritingSearchDocument(
                for: key,
                publicationGeneration: publicationGeneration
            )
        }
    }

    /// A failed newer save may leave an older queued write as the current
    /// durable ink. Re-read that authoritative payload before deciding whether
    /// accepted handwriting may remain searchable.
    private func reconcileHandwritingSearchWithDurableInk(
        key: HandwritingRecognitionKey,
        publicationGeneration: UInt64
    ) async {
        guard isCurrentHandwritingOperation(
            publicationGeneration,
            for: key
        ) else { return }
        do {
            guard let document = try await store.loadHandwritingRecognition(
                notebookID: key.notebookID,
                pageID: key.pageID
            ), let ink = try await store.loadInkForHandwritingRecognition(
                notebookID: key.notebookID,
                pageID: key.pageID
            ), document.sourceInkSHA256
                == HandwritingRecognitionPipeline.sourceInkSHA256(for: ink) else {
                await removeHandwritingSearchDocument(
                    for: key,
                    publicationGeneration: publicationGeneration
                )
                return
            }
            await indexHandwritingRecognition(
                document,
                notebookID: key.notebookID,
                pageID: key.pageID,
                publicationGeneration: publicationGeneration
            )
        } catch {
            await removeHandwritingSearchDocument(
                for: key,
                publicationGeneration: publicationGeneration
            )
        }
    }

    private func removeHandwritingSearchDocument(
        for key: HandwritingRecognitionKey,
        publicationGeneration: UInt64
    ) async {
        guard isCurrentHandwritingOperation(
            publicationGeneration,
            for: key
        ) else { return }
        let documentID = HandwritingSearchBuilder.documentID(
            notebookID: key.notebookID,
            pageID: key.pageID
        )
        let didSuppress = suppressHandwritingSearchDocument(documentID)
        if didSuppress {
            await refreshPublishedSearchIfNeeded()
            guard isCurrentHandwritingOperation(
                publicationGeneration,
                for: key
            ) else { return }
        }
        let existing = await searchIndex.document(for: documentID)
        guard existing != nil,
              isCurrentHandwritingOperation(
                  publicationGeneration,
                  for: key
              ) else { return }
        do {
            try await searchIndex.remove(documentID: documentID)
            guard isCurrentHandwritingOperation(
                publicationGeneration,
                for: key
            ) else { return }
        } catch {
            show(error)
        }
    }

    private func reindexHandwritingRecognition(
        in notebook: EditorNotebook,
        reconcileOrphans: Bool = false,
        allowDuringLibraryRootChange: Bool = false
    ) async {
        let drawablePages = notebook.pages.filter {
            Self.supportsHandwritingRecognition($0.kind)
        }
        if reconcileOrphans {
            let retainedDocumentIDs = Set(drawablePages.map { page in
                HandwritingSearchBuilder.documentID(
                    notebookID: notebook.id,
                    pageID: page.id
                )
            })
            do {
                try await searchIndex.retainDocuments(
                    notebookID: notebook.id,
                    source: .handwriting,
                    documentIDs: retainedDocumentIDs
                )
            } catch {
                show(error)
            }
        }
        for page in drawablePages {
            await repairHandwritingSearch(
                for: HandwritingRecognitionKey(
                    notebookID: notebook.id,
                    pageID: page.id
                ),
                allowDuringLibraryRootChange: allowDuringLibraryRootChange
            )
        }
    }

    private func removePageSearchDocuments(
        notebookID: UUID,
        pageID: UUID
    ) async {
        let expectedLibraryEpoch = libraryEpoch
        let navigationKey = PageNavigationSearchKey(
            notebookID: notebookID,
            pageID: pageID
        )
        let navigationGeneration = beginPageNavigationSearchPublication(
            for: navigationKey
        )
        if suppressPageNavigationSearchDocument(for: navigationKey) {
            schedulePublishedSearchRefresh()
        }
        invalidateCanvasSearchPublication(for: CanvasElementSaveKey(
            notebookID: notebookID,
            pageID: pageID
        ))
        invalidateHandwritingOperation(for: HandwritingRecognitionKey(
            notebookID: notebookID,
            pageID: pageID
        ))
        let didSuppressHandwriting = suppressHandwritingSearchDocument(
            HandwritingSearchBuilder.documentID(
                notebookID: notebookID,
                pageID: pageID
            )
        )
        if didSuppressHandwriting { await refreshPublishedSearchIfNeeded() }
        let navigationDocumentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebookID,
            pageID: pageID
        )
        let documentIDs = [
            pageID,
            CanvasElementSearchBuilder.documentID(
                notebookID: notebookID,
                pageID: pageID
            ),
            HandwritingSearchBuilder.documentID(
                notebookID: notebookID,
                pageID: pageID
            ),
            navigationDocumentID,
        ]
        do {
            try await searchIndex.removePageDocuments(
                notebookID: notebookID,
                pageID: pageID,
                documentIDs: Set(documentIDs)
            )
        } catch {
            show(error)
        }
        for documentID in documentIDs {
            do {
                try await searchIndex.remove(documentID: documentID)
            } catch {
                show(error)
            }
        }
        await removePageNavigationSearchDocument(
            for: navigationKey,
            publicationGeneration: navigationGeneration,
            expectedLibraryEpoch: expectedLibraryEpoch
        )
        if pageNavigationSearchPublicationGenerations[navigationKey]
                == navigationGeneration,
           !suppressedPageNavigationSearchDocumentIDs.contains(
                navigationDocumentID
           ) {
            pageNavigationSearchPublicationGenerations.removeValue(
                forKey: navigationKey
            )
        }
        if Task.isCancelled {
            schedulePageNavigationSearchRepairs(
                ownedGenerations: [navigationKey: navigationGeneration],
                expectedLibraryEpoch: expectedLibraryEpoch
            )
        }
    }

    private func reindexAudioTranscripts(notebookID: NotebookID) async {
        guard let audioTranscriptSearchRebuilder else { return }
        do {
            try await audioTranscriptSearchRebuilder.rebuild(notebookID: notebookID)
        } catch is CancellationError {
            return
        } catch {
            // Durable audio remains authoritative. The derived index is retried
            // during the next library bootstrap or when the transcript is opened.
            show(error)
        }
    }

    private func nextSearchRevision(
        for documentID: UUID,
        modifiedAt: Date = .now
    ) async throws -> Int {
        let microseconds = modifiedAt.timeIntervalSince1970 * 1_000_000
        let upperBound = Int.max / 2
        let timeBased: Int
        if !microseconds.isFinite || microseconds <= 0 {
            timeBased = 0
        } else if microseconds >= Double(upperBound) {
            timeBased = upperBound
        } else {
            timeBased = Int(microseconds)
        }
        guard let current = await searchIndex.revision(for: documentID) else {
            return timeBased
        }
        guard current < Int.max else { throw SearchRevisionError.exhausted(documentID) }
        return max(timeBased, current + 1)
    }

    private static func supportsHandwritingRecognition(_ kind: PageKind) -> Bool {
        switch kind {
        case .notebook, .whiteboard, .importedDocument:
            true
        case .textDocument, .studySet:
            false
        }
    }

    private static func nextHandwritingRevision(
        after current: Int64?
    ) throws -> Int64 {
        guard let current else { return 1 }
        let (next, overflow) = current.addingReportingOverflow(1)
        guard !overflow, current > 0 else {
            throw HandwritingReviewError.revisionExhausted
        }
        return next
    }

    private func show(_ error: Error) {
        notice = AppNotice(
            kind: .error,
            title: String(localized: "Something went wrong"),
            message: localizedMessage(for: error)
        )
    }

    private func localizedMessage(for error: Error) -> String {
        guard let backupError = error as? FileBackupError else {
            return error.localizedDescription
        }
        switch backupError {
        case .noNotebooks:
            return String(localized: "There are no notebook packages to back up.")
        case .invalidSnapshot:
            return String(localized: "The selected backup is invalid.")
        case .staleBookmark:
            return String(localized: "The backup folder permission has expired. Please choose it again.")
        case .unsafeItem(let name):
            return String(
                format: String(localized: "The backup contains an unsafe item: %@"),
                name
            )
        case .backupTooLarge:
            return String(localized: "The backup exceeds the configured safety limits.")
        case .destinationConflict(let name):
            return String(
                format: String(localized: "A notebook with the same identity already exists in the library: %@"),
                name
            )
        case .restoreIncomplete:
            return String(localized: "The restore could not be completed and was rolled back.")
        }
    }
}

private enum BackupUIError: LocalizedError, Sendable {
    case folderNotConfigured
    case folderInsideLibrary

    var errorDescription: String? {
        switch self {
        case .folderNotConfigured:
            String(localized: "Choose a backup folder before creating or restoring a backup.")
        case .folderInsideLibrary:
            String(localized: "Choose a backup folder outside the active NextStep library.")
        }
    }
}

private enum InkPersistenceError: LocalizedError, Sendable {
    case flushRequired
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .flushRequired:
            String(localized: "The latest ink could not be saved. Try again before leaving or exporting this note.")
        case .writeFailed(let description):
            String(
                format: String(localized: "The latest ink could not be saved: %@"),
                description
            )
        }
    }
}

private enum CanvasElementPersistenceError: LocalizedError, Sendable {
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .writeFailed(let description):
            String(
                format: String(localized: "The latest canvas elements could not be saved: %@"),
                description
            )
        }
    }
}

private enum PageContentPersistenceError: LocalizedError, Sendable {
    case flushRequired
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .flushRequired:
            String(localized: "The latest page content could not be saved. Try again before leaving or exporting this note.")
        case .writeFailed(let description):
            String(
                format: String(localized: "The latest page content could not be saved: %@"),
                description
            )
        }
    }
}

private enum SearchRevisionError: LocalizedError, Sendable {
    case exhausted(UUID)

    var errorDescription: String? {
        switch self {
        case .exhausted:
            String(localized: "The local search index revision is invalid and must be rebuilt.")
        }
    }
}

private enum LibraryRootChangeError: LocalizedError, Sendable {
    case changeInProgress
    case openEditors
    case concurrentPageEdit
    case operationsDidNotFinish

    var errorDescription: String? {
        switch self {
        case .changeInProgress:
            String(localized: "The library location is changing. Try again when the move finishes.")
        case .openEditors:
            String(localized: "Close every open note before changing the library location.")
        case .concurrentPageEdit:
            String(localized: "Edits arrived while the library was preparing to move. They were saved in the current location, so the move was cancelled. Pause editing and try again.")
        case .operationsDidNotFinish:
            String(localized: "NextStep is still finishing work in the current library. The location was not changed. Try again when that work finishes.")
        }
    }
}

private enum HandwritingReviewError: LocalizedError, Sendable {
    case alreadyRecognizing
    case libraryLocationChanging
    case unsupportedPage
    case missingInk
    case missingRecognition
    case missingCandidate
    case staleInk
    case revisionExhausted

    var errorDescription: String? {
        switch self {
        case .alreadyRecognizing:
            String(localized: "Handwriting recognition is already running for this page.")
        case .libraryLocationChanging:
            String(localized: "The library location is changing. Try again when the move finishes.")
        case .unsupportedPage:
            String(localized: "Handwriting recognition is available on ink pages.")
        case .missingInk:
            String(localized: "There is no saved handwriting to recognize on this page.")
        case .missingRecognition:
            String(localized: "Run handwriting recognition before reviewing suggestions.")
        case .missingCandidate:
            String(localized: "This handwriting suggestion is no longer available.")
        case .staleInk:
            String(localized: "The handwriting changed. Run recognition again before reviewing suggestions.")
        case .revisionExhausted:
            String(localized: "The handwriting review revision is invalid and must be rebuilt.")
        }
    }
}

private enum NoteToolError: LocalizedError, Sendable {
    case backgroundTextUnavailable
    case noReadableText
    case cannotDeleteLastPage

    var errorDescription: String? {
        switch self {
        case .backgroundTextUnavailable:
            String(localized: "Use Handwriting review to recognize ink on this page.")
        case .noReadableText:
            String(localized: "No readable text was found on this page.")
        case .cannotDeleteLastPage:
            String(localized: "A notebook must keep at least one page.")
        }
    }
}

private enum PageDuplicationError: LocalizedError, Sendable {
    case missingStructuredContent
    case copyFailed(String)
    case rollbackFailed(copy: String, rollback: String)
    case recoveryFailed(copy: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .missingStructuredContent:
            String(localized: "The structured page content is unavailable and cannot be duplicated.")
        case let .copyFailed(reason):
            String(
                format: String(localized: "The page could not be duplicated: %@"),
                reason
            )
        case let .rollbackFailed(copy, rollback):
            String(
                format: String(localized: "The duplicate failed (%@), and NextStep could not fully roll back the page (%@). The saved notebook was reloaded."),
                copy,
                rollback
            )
        case let .recoveryFailed(copy, rollback):
            String(
                format: String(localized: "The duplicate failed (%@), and NextStep could neither roll back nor reload the saved page state (%@). Close and reopen the notebook before editing it again."),
                copy,
                rollback
            )
        }
    }
}
