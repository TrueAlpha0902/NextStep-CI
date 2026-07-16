import Foundation

/// Fixed ceilings for persistence reads that feed synchronous export/replay decoders.
/// Production repositories enforce the byte limits against an opened descriptor before
/// allocating the returned `Data`; protocol defaults exist only as a compatibility seam for
/// lightweight test repositories.
public enum NotebookExportReadLimits {
    public static let maximumInkBytes = 64 * 1_024 * 1_024
    public static let maximumCanvasElementBytes = 16 * 1_024 * 1_024
    public static let maximumCanvasElementCount = 10_000
    public static let maximumCanvasStringUTF8BytesPerField = 1 * 1_024 * 1_024
    public static let maximumCanvasStringUTF8BytesPerPage = 8 * 1_024 * 1_024
    public static let maximumCanvasTextUTF16UnitsPerField = 32_768
    public static let maximumCanvasTextUTF16UnitsPerPage = 1_000_000
    public static let maximumCanvasFontNameUTF16Units = 128
    public static let maximumCanvasURLUTF16Units = 4_096
    public static let maximumCanvasTokenUTF16Units = 64
    public static let maximumCanvasGeometryMagnitude = 1_000_000.0
    public static let maximumCanvasFontSize = 512.0
    public static let maximumCanvasLineWidth = 256.0
    public static let maximumCanvasAssetResolutionAttempts = 256
    public static let maximumCanvasAssetSourceBytes = 64 * 1_024 * 1_024
    public static let maximumCanvasAssetSourceBytesPerPage = 256 * 1_024 * 1_024
    public static let maximumBackgroundAssetBytes = 256 * 1_024 * 1_024
    public static let maximumManifestBytes = 16 * 1_024 * 1_024
    public static let maximumNotebookPageCount = 2_000
    public static let maximumManifestAssetCount = 100_000
    public static let maximumManifestAudioSessionCount = 10_000
    public static let maximumManifestTagCount = 10_000
    public static let maximumPageDimension = 100_000.0
}

/// Hard ceilings for the read-only Note Replay path. Replay prepares PencilKit drawings
/// synchronously, so its ink source ceiling is intentionally much smaller than PDF export's.
/// Callers may request a stricter limit, but no repository implementation may raise this cap.
public enum NotebookReplayReadLimits {
    public static let maximumInkBytes = 1 * 1_024 * 1_024
    public static let maximumTimelineBytes = 4 * 1_024 * 1_024
    public static let maximumTimelineMarks = 100_000

    public static func clampedInkByteCount(_ requestedByteCount: Int) -> Int {
        min(max(requestedByteCount, 0), maximumInkBytes)
    }

    public static func clampedTimelineMarkCount(_ requestedMarkCount: Int) -> Int {
        min(max(requestedMarkCount, 0), maximumTimelineMarks)
    }
}

/// Hard ceiling for ink loaded into the handwriting-recognition pipeline. This
/// path rasterizes PencilKit data synchronously, so it intentionally accepts a
/// much smaller source than whole-page export.
public enum NotebookHandwritingRecognitionReadLimits {
    public static let maximumInkBytes = 16 * 1_024 * 1_024
}

/// Opaque capability for one point-in-time notebook export. File-backed repositories keep the
/// authoritative manifest and filesystem identity in actor-isolated storage; callers cannot
/// manufacture a usable capability by copying these public identifiers.
public struct NotebookExportSession: Hashable, Sendable {
    public let id: UUID
    public let notebookID: NotebookID
    private let capabilityID: UUID

    public init(id: UUID = UUID(), notebookID: NotebookID) {
        self.id = id
        self.notebookID = notebookID
        self.capabilityID = UUID()
    }
}

/// The single bounded manifest decode returned when an export session begins.
public struct NotebookExportSessionContext: Sendable {
    public let session: NotebookExportSession
    public let manifest: NotebookManifest

    public init(session: NotebookExportSession, manifest: NotebookManifest) {
        self.session = session
        self.manifest = manifest
    }
}

/// Canvas elements plus the exact number of persisted JSON bytes consumed by the secure reader.
/// Whole-notebook exporters use the byte count to cap cumulative JSON decode work.
public struct NotebookExportCanvasElements: Equatable, Sendable {
    public let elements: [CanvasElement]
    public let encodedByteCount: Int

    public init(elements: [CanvasElement], encodedByteCount: Int) {
        self.elements = elements
        self.encodedByteCount = encodedByteCount
    }
}

public enum NotebookRepositoryError: Error, Equatable, Sendable, LocalizedError {
    case notebookNotFound(NotebookID)
    case pageNotFound(PageID)
    case invalidTitle
    case invalidPageOrder
    case invalidPageNavigationMetadata(pageID: PageID, detail: String)
    case duplicatePage(PageID)
    case malformedPackage(String)
    case corruptedFile(String)
    case invalidAsset(AssetID)
    case audioSessionNotFound(AudioSessionID)
    case duplicateAudioSession(AudioSessionID)
    case invalidAudioSession(AudioSessionID, detail: String)
    case invalidAudioTranscript(AudioSessionID, detail: String)
    case invalidAudioReadRange
    case invalidSnapshotDestination
    case missingPageContent(PageID)
    case pageContentTypeMismatch(pageID: PageID, expected: PageKind, actual: PageKind)
    case textBlockNotFound(pageID: PageID, blockID: TextBlockID)
    case invalidPageContent(pageID: PageID, detail: String)
    case invalidHandwritingRecognition(pageID: PageID, detail: String)
    case staleHandwritingRecognitionInk(pageID: PageID)
    case handwritingRecognitionConflict(pageID: PageID)
    case boundedReadLimitExceeded(relativePath: String, limit: Int)
    case canvasElementLimitExceeded(limit: Int)
    case invalidExportSession

    public var errorDescription: String? {
        switch self {
        case .notebookNotFound(let id): return "Notebook \(id) was not found."
        case .pageNotFound(let id): return "Page \(id) was not found."
        case .invalidTitle: return "A notebook title cannot be empty."
        case .invalidPageOrder: return "The new page order must contain every page exactly once."
        case .invalidPageNavigationMetadata(let pageID, let detail):
            return "Page \(pageID) has invalid navigation metadata: \(detail)"
        case .duplicatePage(let id): return "Page \(id) already exists."
        case .malformedPackage(let detail): return "The notebook package is malformed: \(detail)"
        case .corruptedFile(let path): return "The file at \(path) is corrupted."
        case .invalidAsset(let id): return "Asset \(id) failed integrity validation."
        case .audioSessionNotFound(let id): return "Audio session \(id) was not found."
        case .duplicateAudioSession(let id): return "Audio session \(id) already exists."
        case .invalidAudioSession(let id, let detail): return "Audio session \(id) is invalid: \(detail)"
        case .invalidAudioTranscript(let id, let detail): return "Audio transcript for session \(id) is invalid: \(detail)"
        case .invalidAudioReadRange: return "The requested audio byte range is invalid or exceeds the read limit."
        case .invalidSnapshotDestination: return "The snapshot destination must be outside the live notebook package."
        case .missingPageContent(let id): return "Page \(id) is missing its structured content."
        case .pageContentTypeMismatch(let pageID, let expected, let actual):
            return "Page \(pageID) has \(actual.rawValue) content but requires \(expected.rawValue) content."
        case .textBlockNotFound(let pageID, let blockID):
            return "Text block \(blockID) was not found on page \(pageID)."
        case .invalidPageContent(let pageID, let detail):
            return "Page \(pageID) has invalid structured content: \(detail)"
        case .invalidHandwritingRecognition(let pageID, let detail):
            return "Page \(pageID) has invalid handwriting recognition: \(detail)"
        case .staleHandwritingRecognitionInk(let pageID):
            return "Page \(pageID) handwriting recognition does not match its current ink."
        case .handwritingRecognitionConflict(let pageID):
            return "Page \(pageID) handwriting recognition changed before this update was saved."
        case .boundedReadLimitExceeded(let relativePath, let limit):
            return "The file at \(relativePath) exceeds the \(limit)-byte read limit."
        case .canvasElementLimitExceeded(let limit):
            return "The page exceeds the \(limit)-element read limit."
        case .invalidExportSession:
            return "The notebook export session is no longer valid."
        }
    }
}

public enum NotebookChangeKind: String, Codable, Sendable {
    case created, renamed, metadataUpdated, deleted, pageAdded, pageDeleted, pagesReordered
    case inkSaved, elementsSaved, pageContentSaved, handwritingRecognitionSaved, assetImported
    case audioSessionAdded, audioSessionUpdated, audioTranscriptSaved, audioSessionDeleted
    case recovered, rebuilt
}

public struct NotebookChange: Codable, Equatable, Sendable {
    public var notebookID: NotebookID?
    public var pageID: PageID?
    public var kind: NotebookChangeKind
    public var revision: Int64?
    public var timestamp: Date

    public init(notebookID: NotebookID?, pageID: PageID? = nil, kind: NotebookChangeKind, revision: Int64? = nil, timestamp: Date = Date()) {
        self.notebookID = notebookID
        self.pageID = pageID
        self.kind = kind
        self.revision = revision
        self.timestamp = timestamp
    }
}

public enum ValidationIssueKind: String, Codable, Sendable {
    case missingManifest, unreadableManifest, identifierMismatch, duplicatePage
    case missingPageDirectory, missingPageDescriptor, unreadablePageDescriptor
    case pageIdentifierMismatch, pageDescriptorMismatch, unreadableElements, missingAsset, invalidAssetDigest
    case invalidAssetSize, abandonedTemporaryFile, orphanPageDirectory, unreadableOperation
    case pendingTransaction, unreadableTransaction
    case missingPageContent, unreadablePageContent, pageContentTypeMismatch, invalidPageContent
    case unreadableHandwritingRecognition, invalidHandwritingRecognition
    case staleHandwritingRecognition, unsupportedHandwritingRecognitionSchema
    case duplicateAudioSession, invalidAudioDescriptor, missingAudioFile, unreadableAudioFile
    case invalidAudioSize, invalidAudioDigest, missingAudioTimeline, unreadableAudioTimeline
    case audioTimelineMismatch, orphanAudioFile
    case invalidAudioTranscript, missingAudioReplayHistory, invalidAudioReplayHistory
}

public struct ValidationIssue: Codable, Equatable, Sendable {
    public var kind: ValidationIssueKind
    public var relativePath: String
    public var detail: String

    public init(kind: ValidationIssueKind, relativePath: String, detail: String) {
        self.kind = kind
        self.relativePath = relativePath
        self.detail = detail
    }
}

public struct ValidationReport: Codable, Equatable, Sendable {
    public var notebookID: NotebookID
    public var issues: [ValidationIssue]

    public init(notebookID: NotebookID, issues: [ValidationIssue]) {
        self.notebookID = notebookID
        self.issues = issues
    }

    /// Stale recognition is derived review state, not package corruption. It
    /// remains visible to callers so they can invalidate search and offer a
    /// rerun, while snapshots and imports stay available after ordinary ink
    /// edits.
    public var blockingIssues: [ValidationIssue] {
        issues.filter { $0.kind != .staleHandwritingRecognition }
    }

    public var isValid: Bool { blockingIssues.isEmpty }
}

public enum RecoveryAction: String, Codable, Sendable {
    case removedTemporaryFile
    case restoredBackupManifest
    case reconstructedManifest
    case restoredPageDescriptor
    case reconciledPageDescriptor
    case resetUnreadableElements
    case createdMissingPageContent
    case resetUnreadablePageContent
    case resetMismatchedPageContent
    case resetInvalidPageContent
    case quarantinedUnexpectedPageContent
    case quarantinedInvalidHandwritingRecognition
    case adoptedOrphanPage
    case removedOrphanPage
    case removedMissingPage
    case removedDuplicatePage
    case removedInvalidAssetReference
    case adoptedOrphanAsset
    case removedUnreadableOperation
    case finalizedCommittedTransaction
    case rolledBackTransaction
    case removedOrphanTransaction
    case restoredTransactionJournal
    case removedInvalidAudioSession
    case removedInvalidAudioReplayMetadata
    case preservedUnavailableAudioReplayHistory
    case quarantinedOrphanAudio
    case migratedSchema
}

public struct RecoveryReport: Codable, Equatable, Sendable {
    public var manifest: NotebookManifest
    public var actions: [RecoveryAction]
    public var validation: ValidationReport

    public init(manifest: NotebookManifest, actions: [RecoveryAction], validation: ValidationReport) {
        self.manifest = manifest
        self.actions = actions
        self.validation = validation
    }
}

/// A field-scoped page-navigation mutation. Keeping the two fields separate
/// prevents an editor holding an older page snapshot from overwriting a
/// concurrent bookmark or outline change made by another editor.
public enum PageNavigationMetadataUpdate: Equatable, Sendable {
    case bookmark(Bool)
    case outlineTitle(String?)
}

public protocol NotebookRepository: Sendable {
    func changes() async -> AsyncStream<NotebookChange>

    func createNotebook(title: String, initialPage: PageDescriptor?) async throws -> NotebookManifest
    func openNotebook(id: NotebookID) async throws -> NotebookManifest
    /// Bounded, no-follow read used by export before any page content is loaded.
    func openNotebookForExport(id: NotebookID) async throws -> NotebookManifest
    /// Begins a point-in-time export and decodes the bounded manifest exactly once. Production
    /// repositories must bind the opaque token to the manifest's no-follow filesystem identity.
    func beginNotebookExport(id: NotebookID) async throws -> NotebookExportSessionContext
    /// Revalidates the current manifest path against the session identity without rereading its
    /// body. This is also the final publication fence for a whole-notebook export.
    func validateNotebookExportSession(
        _ session: NotebookExportSession
    ) async throws -> NotebookManifest
    /// Explicitly releases actor-isolated session state. Ending an unknown or already-ended token
    /// is deliberately idempotent.
    func endNotebookExport(_ session: NotebookExportSession) async
    func listNotebooks() async throws -> [NotebookManifest]
    func renameNotebook(id: NotebookID, title: String) async throws -> NotebookManifest
    func updateNotebookMetadata(id: NotebookID, title: String?, tags: [String]?, isFavorite: Bool?) async throws -> NotebookManifest
    func deleteNotebook(id: NotebookID) async throws

    func addPage(notebookID: NotebookID, page: PageDescriptor, at index: Int?) async throws -> NotebookManifest
    func deletePage(notebookID: NotebookID, pageID: PageID) async throws -> NotebookManifest
    func reorderPages(notebookID: NotebookID, pageIDs: [PageID]) async throws -> NotebookManifest
    /// Atomically applies one flat navigation-metadata field to the repository-
    /// latest descriptor duplicated in the manifest and page descriptor.
    func updatePageNavigationMetadata(
        notebookID: NotebookID,
        pageID: PageID,
        update: PageNavigationMetadataUpdate
    ) async throws -> NotebookManifest

    func saveInk(_ data: Data, notebookID: NotebookID, pageID: PageID) async throws
    func loadInk(notebookID: NotebookID, pageID: PageID) async throws -> Data?
    /// Secure, bounded persistence read for export/replay. A production implementation must
    /// reject links and non-regular files and enforce `maximumInkBytes` before allocation.
    func loadInkForExport(notebookID: NotebookID, pageID: PageID) async throws -> Data?
    func loadInkForExport(
        session: NotebookExportSession,
        pageID: PageID
    ) async throws -> Data?
    /// Descriptor-bounded ink read for Note Replay. Implementations must enforce the smaller of
    /// `maximumByteCount` and the 1 MiB replay hard limit before allocating the returned buffer.
    func loadInkForReplay(
        notebookID: NotebookID,
        pageID: PageID,
        maximumByteCount: Int
    ) async throws -> Data?
    func loadInkForReplay(
        session: NotebookExportSession,
        pageID: PageID,
        maximumByteCount: Int
    ) async throws -> Data?
    func saveElements(_ elements: [CanvasElement], notebookID: NotebookID, pageID: PageID) async throws
    func loadElements(notebookID: NotebookID, pageID: PageID) async throws -> [CanvasElement]
    /// Secure, bounded decode path for export. Encoded bytes and decoded structure must both be
    /// validated before the elements are returned to a renderer.
    func loadElementsForExport(notebookID: NotebookID, pageID: PageID) async throws -> [CanvasElement]
    func loadElementsForExport(
        session: NotebookExportSession,
        pageID: PageID
    ) async throws -> NotebookExportCanvasElements
    func savePageContent(_ content: PageContent, notebookID: NotebookID, pageID: PageID) async throws
    func loadPageContent(notebookID: NotebookID, pageID: PageID) async throws -> PageContent?
    /// Atomically publishes a reviewed handwriting-recognition sidecar. The
    /// expected run and revision form a compare-and-swap token: both are nil
    /// only for the first sidecar, and both are required for every replacement.
    /// The document's ink digest must match the current durable bounded ink.
    func saveHandwritingRecognition(
        _ document: HandwritingRecognitionDocument,
        notebookID: NotebookID,
        pageID: PageID,
        expectedRunID: UUID?,
        expectedRevision: Int64?
    ) async throws
    /// Loads the structurally valid sidecar even when its ink digest is stale,
    /// allowing the review UI to explain and replace outdated recognition.
    func loadHandwritingRecognition(
        notebookID: NotebookID,
        pageID: PageID
    ) async throws -> HandwritingRecognitionDocument?
    /// Descriptor-bounded, no-follow ink read for handwriting rasterization.
    func loadInkForHandwritingRecognition(
        notebookID: NotebookID,
        pageID: PageID
    ) async throws -> Data?

    func importAsset(_ data: Data, notebookID: NotebookID, mediaType: String, originalFilename: String?) async throws -> AssetDescriptor
    func loadAsset(notebookID: NotebookID, assetID: AssetID) async throws -> Data
    /// Returns an owned, integrity-checked asset buffer after enforcing the background ceiling
    /// against the opened file descriptor. This avoids retaining a lazy mapped file in PDFKit.
    func loadAssetForExport(notebookID: NotebookID, assetID: AssetID) async throws -> Data
    func loadAssetForExport(
        session: NotebookExportSession,
        assetID: AssetID
    ) async throws -> Data
    /// Batch-loads only the image/sticker assets the renderer can actually attempt on one page.
    /// Production implementations enforce both ceilings before and throughout allocation.
    func loadCanvasAssetsForExport(
        notebookID: NotebookID,
        assetIDs: [AssetID]
    ) async throws -> [AssetID: Data]
    func loadCanvasAssetsForExport(
        session: NotebookExportSession,
        assetIDs: [AssetID]
    ) async throws -> [AssetID: Data]

    /// Atomically adds one bounded M4A file, its versioned timeline, and the
    /// corresponding manifest descriptor. The timeline's session identifier is
    /// used as the stable identifier and must not already exist.
    func addAudioSession(
        _ m4aData: Data,
        timeline: AudioTimelineDocument,
        notebookID: NotebookID,
        durationSeconds: Double,
        transcriptAssetID: AssetID?
    ) async throws -> AudioSessionDescriptor
    /// Atomically ingests a bounded M4A from a regular, single-link file while
    /// copying and hashing it incrementally. Implementations must not follow a
    /// symbolic-link final component or buffer the complete recording in memory.
    func addAudioSession(
        from m4aFileURL: URL,
        timeline: AudioTimelineDocument,
        notebookID: NotebookID,
        durationSeconds: Double,
        transcriptAssetID: AssetID?
    ) async throws -> AudioSessionDescriptor
    /// The bounded streaming variant used by callers with a stricter ingest
    /// policy than the repository-wide storage ceiling. The limit is enforced
    /// against the opened descriptor and throughout the copy.
    func addAudioSession(
        from m4aFileURL: URL,
        maximumByteCount: Int64,
        timeline: AudioTimelineDocument,
        notebookID: NotebookID,
        durationSeconds: Double,
        transcriptAssetID: AssetID?
    ) async throws -> AudioSessionDescriptor
    /// Atomically ingests an in-app recording while preserving the exact
    /// wall-clock replay zero. Generic/imported audio APIs intentionally leave
    /// this metadata absent rather than guessing from persistence time.
    func addRecordedAudioSession(
        from m4aFileURL: URL,
        maximumByteCount: Int64,
        timeline: AudioTimelineDocument,
        notebookID: NotebookID,
        durationSeconds: Double,
        recordingStartedAt: Date,
        transcriptAssetID: AssetID?
    ) async throws -> AudioSessionDescriptor
    /// Atomically seals the immutable replay event index and its
    /// content-addressed snapshot payloads with the recording and timeline.
    func addRecordedAudioSession(
        from m4aFileURL: URL,
        maximumByteCount: Int64,
        timeline: AudioTimelineDocument,
        replayHistory: NoteReplayCaptureBundle,
        notebookID: NotebookID,
        durationSeconds: Double,
        recordingStartedAt: Date,
        transcriptAssetID: AssetID?
    ) async throws -> AudioSessionDescriptor
    /// Atomically replaces a session timeline and transcript reference.
    func updateAudioSession(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        timeline: AudioTimelineDocument,
        transcriptAssetID: AssetID?
    ) async throws -> AudioSessionDescriptor
    /// Reads at most the repository's bounded chunk size without loading the
    /// entire recording into memory.
    func loadAudioChunk(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        offset: Int64,
        maximumByteCount: Int
    ) async throws -> Data
    /// Returns the audio descriptor captured by a point-in-time export session.
    /// Production repositories must reject a stale capability instead of
    /// falling back to the live manifest.
    func audioSessionDescriptorForExport(
        session: NotebookExportSession,
        sessionID: AudioSessionID
    ) async throws -> AudioSessionDescriptor
    /// Secure, bounded audio read tied to the exact manifest and package
    /// identity captured when `session` began.
    func loadAudioChunkForExport(
        session: NotebookExportSession,
        sessionID: AudioSessionID,
        offset: Int64,
        maximumByteCount: Int
    ) async throws -> Data
    func loadAudioTimeline(notebookID: NotebookID, sessionID: AudioSessionID) async throws -> AudioTimelineDocument
    /// Bounded read for Note Replay. Unlike the editing API, this path must use the no-follow
    /// manifest/timeline readers and retain every structurally valid mark, including marks whose
    /// pages are no longer replay-eligible. Page projection happens only after full validation.
    func loadAudioTimelineForReplay(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        maximumMarkCount: Int
    ) async throws -> AudioTimelineDocument
    func loadAudioTimelineForReplay(
        session: NotebookExportSession,
        sessionID: AudioSessionID,
        maximumMarkCount: Int
    ) async throws -> AudioTimelineDocument
    /// Loads the sealed event index through the exact point-in-time export
    /// capability and authorizes only the payload references it contains.
    func loadNoteReplayHistoryForReplay(
        session: NotebookExportSession,
        sessionID: AudioSessionID,
        maximumEventCount: Int
    ) async throws -> NoteReplayHistoryDocument?
    func loadNoteReplayInkPayloadForReplay(
        session: NotebookExportSession,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int
    ) async throws -> Data?
    func loadNoteReplayElementsPayloadForReplay(
        session: NotebookExportSession,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int,
        maximumElementCount: Int
    ) async throws -> NotebookExportCanvasElements
    /// Content-addresses the validated transcript and updates its target audio
    /// descriptor in the same single-revision transaction.
    func saveAudioTranscript(
        _ transcript: AudioTranscriptDocument,
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> AudioSessionDescriptor
    /// Loads and validates a bounded transcript against its session and timeline.
    func loadAudioTranscript(
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> AudioTranscriptDocument?
    /// Loads a validated transcript from the exact export-session manifest.
    func loadAudioTranscriptForExport(
        session: NotebookExportSession,
        sessionID: AudioSessionID
    ) async throws -> AudioTranscriptDocument?
    func deleteAudioSession(notebookID: NotebookID, sessionID: AudioSessionID) async throws

    func operationLog(notebookID: NotebookID) async throws -> [EditCommand]
    /// Publishes a point-in-time copy of a notebook package at `destinationURL`.
    /// Repository implementations must prevent mutations from interleaving with the copy.
    func exportSnapshot(id: NotebookID, to destinationURL: URL) async throws -> URL
    func rebuildLibraryIndex() async throws -> [NotebookManifest]
    func validateNotebook(id: NotebookID) async throws -> ValidationReport
    func recoverNotebook(id: NotebookID) async throws -> RecoveryReport
}

public extension NotebookRepository {
    /// Compatibility implementations for in-memory test repositories. FileNotebookRepository
    /// supplies descriptor-bounded overrides; production adapters must not rely on these
    /// post-load checks for untrusted filesystem content.
    func openNotebookForExport(id: NotebookID) async throws -> NotebookManifest {
        try await openNotebook(id: id)
    }

    func beginNotebookExport(id: NotebookID) async throws -> NotebookExportSessionContext {
        let manifest = try await openNotebookForExport(id: id)
        return NotebookExportSessionContext(
            session: NotebookExportSession(notebookID: id),
            manifest: manifest
        )
    }

    func validateNotebookExportSession(
        _ session: NotebookExportSession
    ) async throws -> NotebookManifest {
        try await openNotebookForExport(id: session.notebookID)
    }

    func endNotebookExport(_ session: NotebookExportSession) async {
        _ = session
    }

    func loadInkForExport(notebookID: NotebookID, pageID: PageID) async throws -> Data? {
        let data = try await loadInk(notebookID: notebookID, pageID: pageID)
        guard let data else { return nil }
        guard data.count <= NotebookExportReadLimits.maximumInkBytes else {
            throw NotebookRepositoryError.boundedReadLimitExceeded(
                relativePath: "ink.data",
                limit: NotebookExportReadLimits.maximumInkBytes
            )
        }
        return data
    }

    func loadInkForExport(
        session: NotebookExportSession,
        pageID: PageID
    ) async throws -> Data? {
        try await loadInkForExport(notebookID: session.notebookID, pageID: pageID)
    }

    func loadInkForReplay(
        notebookID: NotebookID,
        pageID: PageID,
        maximumByteCount: Int
    ) async throws -> Data? {
        let effectiveLimit = NotebookReplayReadLimits.clampedInkByteCount(
            maximumByteCount
        )
        let data = try await loadInk(notebookID: notebookID, pageID: pageID)
        guard let data else { return nil }
        guard data.count <= effectiveLimit else {
            throw NotebookRepositoryError.boundedReadLimitExceeded(
                relativePath: "ink.data",
                limit: effectiveLimit
            )
        }
        return data
    }

    func loadInkForReplay(
        session: NotebookExportSession,
        pageID: PageID,
        maximumByteCount: Int
    ) async throws -> Data? {
        try await loadInkForReplay(
            notebookID: session.notebookID,
            pageID: pageID,
            maximumByteCount: maximumByteCount
        )
    }

    /// Compatibility seam for lightweight/in-memory repositories. The file
    /// repository overrides this with a descriptor-bounded pre-allocation read.
    func loadInkForHandwritingRecognition(
        notebookID: NotebookID,
        pageID: PageID
    ) async throws -> Data? {
        let data = try await loadInk(notebookID: notebookID, pageID: pageID)
        guard let data else { return nil }
        guard data.count <= NotebookHandwritingRecognitionReadLimits.maximumInkBytes else {
            throw NotebookRepositoryError.boundedReadLimitExceeded(
                relativePath: "ink.data",
                limit: NotebookHandwritingRecognitionReadLimits.maximumInkBytes
            )
        }
        return data
    }

    func loadHandwritingRecognition(
        notebookID: NotebookID,
        pageID: PageID
    ) async throws -> HandwritingRecognitionDocument? {
        _ = notebookID
        _ = pageID
        return nil
    }

    func saveHandwritingRecognition(
        _ document: HandwritingRecognitionDocument,
        notebookID: NotebookID,
        pageID: PageID,
        expectedRunID: UUID?,
        expectedRevision: Int64?
    ) async throws {
        _ = document
        _ = notebookID
        _ = expectedRunID
        _ = expectedRevision
        throw NotebookRepositoryError.invalidHandwritingRecognition(
            pageID: pageID,
            detail: "This repository does not support durable handwriting review."
        )
    }

    func loadAudioTimelineForReplay(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        maximumMarkCount: Int
    ) async throws -> AudioTimelineDocument {
        let effectiveLimit = NotebookReplayReadLimits.clampedTimelineMarkCount(
            maximumMarkCount
        )
        let timeline = try await loadAudioTimeline(
            notebookID: notebookID,
            sessionID: sessionID
        )
        guard timeline.audioSessionID == sessionID,
              timeline.marks.count <= effectiveLimit else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The replay timeline exceeds its requested mark limit or belongs to another session."
            )
        }
        return timeline
    }

    func loadAudioTimelineForReplay(
        session: NotebookExportSession,
        sessionID: AudioSessionID,
        maximumMarkCount: Int
    ) async throws -> AudioTimelineDocument {
        try await loadAudioTimelineForReplay(
            notebookID: session.notebookID,
            sessionID: sessionID,
            maximumMarkCount: maximumMarkCount
        )
    }

    func addRecordedAudioSession(
        from m4aFileURL: URL,
        maximumByteCount: Int64,
        timeline: AudioTimelineDocument,
        replayHistory: NoteReplayCaptureBundle,
        notebookID: NotebookID,
        durationSeconds: Double,
        recordingStartedAt: Date,
        transcriptAssetID: AssetID?
    ) async throws -> AudioSessionDescriptor {
        _ = m4aFileURL
        _ = maximumByteCount
        _ = notebookID
        _ = durationSeconds
        _ = recordingStartedAt
        _ = transcriptAssetID
        guard replayHistory.document.audioSessionID == timeline.audioSessionID else {
            throw NotebookRepositoryError.invalidAudioSession(
                timeline.audioSessionID,
                detail: "The Note Replay history belongs to another audio session."
            )
        }
        throw NotebookRepositoryError.invalidAudioSession(
            timeline.audioSessionID,
            detail: "This repository does not support durable Note Replay histories."
        )
    }

    func loadNoteReplayHistoryForReplay(
        session: NotebookExportSession,
        sessionID: AudioSessionID,
        maximumEventCount: Int
    ) async throws -> NoteReplayHistoryDocument? {
        _ = session
        _ = sessionID
        _ = maximumEventCount
        return nil
    }

    func loadNoteReplayInkPayloadForReplay(
        session: NotebookExportSession,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int
    ) async throws -> Data? {
        _ = session
        _ = reference
        _ = maximumByteCount
        throw NotebookRepositoryError.invalidExportSession
    }

    func loadNoteReplayElementsPayloadForReplay(
        session: NotebookExportSession,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int,
        maximumElementCount: Int
    ) async throws -> NotebookExportCanvasElements {
        _ = session
        _ = reference
        _ = maximumByteCount
        _ = maximumElementCount
        throw NotebookRepositoryError.invalidExportSession
    }

    func audioSessionDescriptorForExport(
        session: NotebookExportSession,
        sessionID: AudioSessionID
    ) async throws -> AudioSessionDescriptor {
        _ = session
        _ = sessionID
        throw NotebookRepositoryError.invalidExportSession
    }

    func loadAudioChunkForExport(
        session: NotebookExportSession,
        sessionID: AudioSessionID,
        offset: Int64,
        maximumByteCount: Int
    ) async throws -> Data {
        _ = session
        _ = sessionID
        _ = offset
        _ = maximumByteCount
        throw NotebookRepositoryError.invalidExportSession
    }

    func loadAudioTranscriptForExport(
        session: NotebookExportSession,
        sessionID: AudioSessionID
    ) async throws -> AudioTranscriptDocument? {
        _ = session
        _ = sessionID
        throw NotebookRepositoryError.invalidExportSession
    }

    func loadElementsForExport(
        notebookID: NotebookID,
        pageID: PageID
    ) async throws -> [CanvasElement] {
        let elements = try await loadElements(notebookID: notebookID, pageID: pageID)
        guard elements.count <= NotebookExportReadLimits.maximumCanvasElementCount else {
            throw NotebookRepositoryError.canvasElementLimitExceeded(
                limit: NotebookExportReadLimits.maximumCanvasElementCount
            )
        }
        return elements
    }

    func loadElementsForExport(
        session: NotebookExportSession,
        pageID: PageID
    ) async throws -> NotebookExportCanvasElements {
        let elements = try await loadElementsForExport(
            notebookID: session.notebookID,
            pageID: pageID
        )
        let encodedByteCount = try JSONEncoder().encode(elements).count
        guard encodedByteCount <= NotebookExportReadLimits.maximumCanvasElementBytes else {
            throw NotebookRepositoryError.boundedReadLimitExceeded(
                relativePath: "elements.json",
                limit: NotebookExportReadLimits.maximumCanvasElementBytes
            )
        }
        return NotebookExportCanvasElements(
            elements: elements,
            encodedByteCount: encodedByteCount
        )
    }

    func loadAssetForExport(notebookID: NotebookID, assetID: AssetID) async throws -> Data {
        let data = try await loadAsset(notebookID: notebookID, assetID: assetID)
        guard data.count <= NotebookExportReadLimits.maximumBackgroundAssetBytes else {
            throw NotebookRepositoryError.boundedReadLimitExceeded(
                relativePath: "assets/\(assetID.rawValue)",
                limit: NotebookExportReadLimits.maximumBackgroundAssetBytes
            )
        }
        return data
    }

    func loadAssetForExport(
        session: NotebookExportSession,
        assetID: AssetID
    ) async throws -> Data {
        try await loadAssetForExport(notebookID: session.notebookID, assetID: assetID)
    }

    func loadCanvasAssetsForExport(
        notebookID: NotebookID,
        assetIDs: [AssetID]
    ) async throws -> [AssetID: Data] {
        guard assetIDs.count <= NotebookExportReadLimits.maximumCanvasAssetResolutionAttempts,
              Set(assetIDs).count == assetIDs.count else {
            throw NotebookRepositoryError.canvasElementLimitExceeded(
                limit: NotebookExportReadLimits.maximumCanvasAssetResolutionAttempts
            )
        }
        var totalBytes = 0
        var result = [AssetID: Data]()
        result.reserveCapacity(assetIDs.count)
        for assetID in assetIDs {
            let data = try await loadAsset(notebookID: notebookID, assetID: assetID)
            guard data.count <= NotebookExportReadLimits.maximumCanvasAssetSourceBytes else {
                throw NotebookRepositoryError.boundedReadLimitExceeded(
                    relativePath: "assets/\(assetID.rawValue)",
                    limit: NotebookExportReadLimits.maximumCanvasAssetSourceBytes
                )
            }
            guard totalBytes <= NotebookExportReadLimits.maximumCanvasAssetSourceBytesPerPage
                    - data.count else {
                throw NotebookRepositoryError.boundedReadLimitExceeded(
                    relativePath: "canvas-assets",
                    limit: NotebookExportReadLimits.maximumCanvasAssetSourceBytesPerPage
                )
            }
            totalBytes += data.count
            result[assetID] = data
        }
        return result
    }

    func loadCanvasAssetsForExport(
        session: NotebookExportSession,
        assetIDs: [AssetID]
    ) async throws -> [AssetID: Data] {
        try await loadCanvasAssetsForExport(
            notebookID: session.notebookID,
            assetIDs: assetIDs
        )
    }
}
