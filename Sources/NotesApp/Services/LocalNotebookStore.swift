import Foundation
import NextStepAcademic
import NotesCore
import PDFKit
import UIKit

struct NotesAppNotebookExportSession: Sendable {
    let token: NotebookExportSession
    let notebook: EditorNotebook
}

/// Opaque capability for one reversible library-root transition. Production
/// storage keeps the previous repository and security-scope acquisition alive
/// until AppModel either commits or rolls the candidate back.
struct NotesAppLibraryRootTransition: Hashable, Sendable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

/// Token for candidate work that may touch a slow Files provider. Preparation
/// does not change store routing; only `beginRootDirectoryTransition` consumes
/// it and installs a reversible candidate.
struct NotesAppLibraryRootPreparation: Hashable, Sendable {
    let id: UUID

    init(id: UUID = UUID()) {
        self.id = id
    }
}

protocol NotesAppNotebookStore: Sendable {
    func loadLibrary() async throws -> [LibraryNotebook]
    func createNotebook(title: String, kind: NotebookKind, template: PaperTemplate) async throws -> EditorNotebook
    func importDocument(at sourceURL: URL) async throws -> EditorNotebook
    func loadNotebook(id: UUID) async throws -> EditorNotebook
    func loadNotebookForExport(id: UUID) async throws -> EditorNotebook
    func beginNotebookExport(id: UUID) async throws -> NotesAppNotebookExportSession
    func validateNotebookExportSession(
        _ session: NotesAppNotebookExportSession
    ) async throws -> EditorNotebook
    func endNotebookExport(_ session: NotesAppNotebookExportSession) async
    func audioSessionDescriptorForExport(
        session: NotesAppNotebookExportSession,
        sessionID: AudioSessionID
    ) async throws -> AudioSessionDescriptor
    func loadAudioChunkForExport(
        session: NotesAppNotebookExportSession,
        sessionID: AudioSessionID,
        offset: Int64,
        maximumByteCount: Int
    ) async throws -> Data
    func loadAudioTranscriptForExport(
        session: NotesAppNotebookExportSession,
        sessionID: AudioSessionID
    ) async throws -> AudioTranscriptDocument?
    func saveNotebook(_ notebook: EditorNotebook) async throws
    func updatePageNavigationMetadata(
        notebookID: UUID,
        pageID: UUID,
        update: PageNavigationMetadataUpdate
    ) async throws -> EditorNotebook
    func deletePage(notebookID: UUID, pageID: UUID) async throws -> EditorNotebook
    func loadInk(notebookID: UUID, page: EditorPage) async throws -> Data?
    func loadInkForExport(notebookID: UUID, page: EditorPage) async throws -> Data?
    func loadInkForExport(
        session: NotesAppNotebookExportSession,
        page: EditorPage
    ) async throws -> Data?
    func saveInk(_ data: Data, notebookID: UUID, page: EditorPage) async throws
    func loadElements(notebookID: UUID, pageID: UUID) async throws -> [CanvasElement]
    func loadElementsForExport(notebookID: UUID, pageID: UUID) async throws -> [CanvasElement]
    func loadElementsForExport(
        session: NotesAppNotebookExportSession,
        pageID: UUID
    ) async throws -> NotebookExportCanvasElements
    func saveElements(
        _ elements: [CanvasElement],
        notebookID: UUID,
        pageID: UUID
    ) async throws
    func loadPageContent(notebookID: UUID, pageID: UUID) async throws -> NotesCore.PageContent?
    func savePageContent(
        _ content: NotesCore.PageContent,
        notebookID: UUID,
        pageID: UUID
    ) async throws
    func saveHandwritingRecognition(
        _ document: HandwritingRecognitionDocument,
        notebookID: UUID,
        pageID: UUID,
        expectedRunID: UUID?,
        expectedRevision: Int64?
    ) async throws
    func loadHandwritingRecognition(
        notebookID: UUID,
        pageID: UUID
    ) async throws -> HandwritingRecognitionDocument?
    func loadInkForHandwritingRecognition(
        notebookID: UUID,
        pageID: UUID
    ) async throws -> Data?
    func availableImageAssets(notebookID: UUID) async throws -> [AssetDescriptor]
    func assetURLs(notebookID: UUID, assetIDs: Set<AssetID>) async throws -> [AssetID: URL]
    func assetURL(notebookID: UUID, relativePath: String) async throws -> URL
    func loadBackgroundAssetForExport(notebookID: UUID, relativePath: String) async throws -> Data
    func loadBackgroundAssetForExport(
        session: NotesAppNotebookExportSession,
        relativePath: String
    ) async throws -> Data
    func loadCanvasAssetsForExport(
        notebookID: UUID,
        assetIDs: [AssetID]
    ) async throws -> [AssetID: Data]
    func loadCanvasAssetsForExport(
        session: NotesAppNotebookExportSession,
        assetIDs: [AssetID]
    ) async throws -> [AssetID: Data]
    func packageURL(notebookID: UUID) async throws -> URL
    func exportNotebookSnapshots(to directory: URL) async throws -> [URL]
    func libraryDirectoryURL() async throws -> URL
    func validateRestoredNotebookPackages(_ urls: [URL]) async throws
    func deleteNotebook(id: UUID, permanently: Bool) async throws
    func setRootDirectory(_ url: URL?) async throws
    func prepareRootDirectoryTransition(
        to url: URL?,
        preparation: NotesAppLibraryRootPreparation
    ) async throws
    func beginRootDirectoryTransition(
        _ preparation: NotesAppLibraryRootPreparation
    ) async throws -> NotesAppLibraryRootTransition
    func cancelRootDirectoryPreparation(
        _ preparation: NotesAppLibraryRootPreparation
    ) async
    func commitRootDirectoryTransition(
        _ transition: NotesAppLibraryRootTransition
    ) async throws
    func finalizeRootDirectoryTransition(
        _ transition: NotesAppLibraryRootTransition
    ) async
    func rollbackRootDirectoryTransition(
        _ transition: NotesAppLibraryRootTransition
    ) async
    func rootDescription() async -> String
}

extension NotesAppNotebookStore {
    /// Test-double compatibility seams. LocalNotebookStore overrides each method with NotesCore's
    /// descriptor-bounded implementation; filesystem-backed stores must do the same.
    func loadNotebookForExport(id: UUID) async throws -> EditorNotebook {
        try await loadNotebook(id: id)
    }

    func beginNotebookExport(id: UUID) async throws -> NotesAppNotebookExportSession {
        NotesAppNotebookExportSession(
            token: NotebookExportSession(notebookID: NotebookID(id)),
            notebook: try await loadNotebookForExport(id: id)
        )
    }

    func validateNotebookExportSession(
        _ session: NotesAppNotebookExportSession
    ) async throws -> EditorNotebook {
        let notebook = try await loadNotebookForExport(id: session.notebook.id)
        guard notebook.id == session.token.notebookID.rawValue else {
            throw NotebookRepositoryError.invalidExportSession
        }
        return notebook
    }

    func endNotebookExport(_ session: NotesAppNotebookExportSession) async {
        _ = session
    }

    func audioSessionDescriptorForExport(
        session: NotesAppNotebookExportSession,
        sessionID: AudioSessionID
    ) async throws -> AudioSessionDescriptor {
        _ = session
        _ = sessionID
        throw NotebookRepositoryError.invalidExportSession
    }

    func loadAudioChunkForExport(
        session: NotesAppNotebookExportSession,
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
        session: NotesAppNotebookExportSession,
        sessionID: AudioSessionID
    ) async throws -> AudioTranscriptDocument? {
        _ = session
        _ = sessionID
        throw NotebookRepositoryError.invalidExportSession
    }

    func loadInkForExport(notebookID: UUID, page: EditorPage) async throws -> Data? {
        let data = try await loadInk(notebookID: notebookID, page: page)
        guard let data else { return nil }
        guard data.count <= NotebookExportReadLimits.maximumInkBytes else {
            throw NotebookRepositoryError.boundedReadLimitExceeded(
                relativePath: page.inkPath,
                limit: NotebookExportReadLimits.maximumInkBytes
            )
        }
        return data
    }

    func loadInkForExport(
        session: NotesAppNotebookExportSession,
        page: EditorPage
    ) async throws -> Data? {
        try await loadInkForExport(notebookID: session.notebook.id, page: page)
    }

    /// Lightweight stores can read bounded ink for previews and tests without
    /// opting into durable recognition sidecars. Production file storage
    /// overrides all three handwriting methods below.
    func loadInkForHandwritingRecognition(
        notebookID: UUID,
        pageID: UUID
    ) async throws -> Data? {
        let notebook = try await loadNotebook(id: notebookID)
        guard let page = notebook.pages.first(where: { $0.id == pageID }) else {
            throw NotebookRepositoryError.pageNotFound(PageID(pageID))
        }
        let data = try await loadInk(notebookID: notebookID, page: page)
        guard let data else { return nil }
        guard data.count <= NotebookHandwritingRecognitionReadLimits.maximumInkBytes else {
            throw NotebookRepositoryError.boundedReadLimitExceeded(
                relativePath: page.inkPath,
                limit: NotebookHandwritingRecognitionReadLimits.maximumInkBytes
            )
        }
        return data
    }

    func loadHandwritingRecognition(
        notebookID: UUID,
        pageID: UUID
    ) async throws -> HandwritingRecognitionDocument? {
        _ = notebookID
        _ = pageID
        return nil
    }

    func saveHandwritingRecognition(
        _ document: HandwritingRecognitionDocument,
        notebookID: UUID,
        pageID: UUID,
        expectedRunID: UUID?,
        expectedRevision: Int64?
    ) async throws {
        _ = expectedRunID
        _ = expectedRevision
        throw NotebookRepositoryError.invalidHandwritingRecognition(
            pageID: PageID(pageID),
            detail: "This notebook store does not support durable handwriting review."
        )
    }

    func loadElementsForExport(
        notebookID: UUID,
        pageID: UUID
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
        session: NotesAppNotebookExportSession,
        pageID: UUID
    ) async throws -> NotebookExportCanvasElements {
        let elements = try await loadElementsForExport(
            notebookID: session.notebook.id,
            pageID: pageID
        )
        return NotebookExportCanvasElements(
            elements: elements,
            encodedByteCount: try JSONEncoder().encode(elements).count
        )
    }

    func loadBackgroundAssetForExport(
        notebookID: UUID,
        relativePath: String
    ) async throws -> Data {
        let url = try await assetURL(notebookID: notebookID, relativePath: relativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size >= 0 else {
            throw NotebookRepositoryError.corruptedFile(relativePath)
        }
        guard size <= Int64(NotebookExportReadLimits.maximumBackgroundAssetBytes) else {
            throw NotebookRepositoryError.boundedReadLimitExceeded(
                relativePath: relativePath,
                limit: NotebookExportReadLimits.maximumBackgroundAssetBytes
            )
        }
        let data = try Data(contentsOf: url)
        guard data.count <= NotebookExportReadLimits.maximumBackgroundAssetBytes else {
            throw NotebookRepositoryError.boundedReadLimitExceeded(
                relativePath: relativePath,
                limit: NotebookExportReadLimits.maximumBackgroundAssetBytes
            )
        }
        return data
    }

    func loadBackgroundAssetForExport(
        session: NotesAppNotebookExportSession,
        relativePath: String
    ) async throws -> Data {
        try await loadBackgroundAssetForExport(
            notebookID: session.notebook.id,
            relativePath: relativePath
        )
    }

    func loadCanvasAssetsForExport(
        notebookID: UUID,
        assetIDs: [AssetID]
    ) async throws -> [AssetID: Data] {
        guard assetIDs.count <= NotebookExportReadLimits.maximumCanvasAssetResolutionAttempts,
              Set(assetIDs).count == assetIDs.count else {
            throw NotebookRepositoryError.canvasElementLimitExceeded(
                limit: NotebookExportReadLimits.maximumCanvasAssetResolutionAttempts
            )
        }
        var result = [AssetID: Data]()
        result.reserveCapacity(assetIDs.count)
        var totalBytes = 0
        for assetID in assetIDs {
            let url = try await assetURL(
                notebookID: notebookID,
                relativePath: "assets/\(assetID.rawValue)"
            )
            let data = try Data(contentsOf: url)
            guard data.count <= NotebookExportReadLimits.maximumCanvasAssetSourceBytes,
                  totalBytes <= NotebookExportReadLimits.maximumCanvasAssetSourceBytesPerPage
                    - data.count else {
                throw NotebookRepositoryError.boundedReadLimitExceeded(
                    relativePath: "assets/\(assetID.rawValue)",
                    limit: NotebookExportReadLimits.maximumCanvasAssetSourceBytesPerPage
                )
            }
            totalBytes += data.count
            result[assetID] = data
        }
        return result
    }

    func loadCanvasAssetsForExport(
        session: NotesAppNotebookExportSession,
        assetIDs: [AssetID]
    ) async throws -> [AssetID: Data] {
        try await loadCanvasAssetsForExport(
            notebookID: session.notebook.id,
            assetIDs: assetIDs
        )
    }

}

/// A narrow UI adapter over NotesCore. UI-only state that NotesCore intentionally
/// does not model (trash and cover appearance) lives beside the library index;
/// notebook content and every `.notepkg` remain owned by FileNotebookRepository.
actor LocalNotebookStore: NotesAppNotebookStore, NotebookAudioPersisting,
    NotebookAudioSessionListing, NoteReplayStoreReading,
    AcademicWorkspaceFileBacking, SessionTextNoteStoring,
    TextDocumentSourceSnapshotProviding {
    private enum Constants {
        static let bookmarkKey = "notes.library.rootBookmark"
        static let libraryFolder = "Notes"
        static let metadataFile = ".notes-ui-metadata.json"
    }

    private struct LibraryMetadata: Codable, Sendable {
        var notebooks: [String: NotebookMetadata] = [:]
    }

    private struct NotebookMetadata: Codable, Equatable, Sendable {
        var kind: NotebookKind
        var deletedAt: Date?
        var coverHue: Double
    }

    private struct NotebookPackageIdentity: Decodable {
        var id: NotebookID
    }

    private struct PendingRootTransition {
        let capability: NotesAppLibraryRootTransition
        let previousRootURL: URL?
        let previousRepository: FileNotebookRepository?
        let previousScopedURL: URL?
        let candidateRootURL: URL
        let candidateBookmark: Data?
        var candidateScopedURL: URL?
        var candidateDidAccessScope: Bool
        let previousMatchesCandidate: Bool
        let updatesBookmark: Bool
        let previousBookmark: Data?
        var isCommitted: Bool
        var activeInspectionCount: Int
    }

    private struct PreparedRootTransitionCandidate: Sendable {
        let rootURL: URL
        let repository: FileNotebookRepository
        let bookmark: Data?
        let scopedURL: URL?
        let didAccessScope: Bool
        let updatesBookmark: Bool

        func releaseSecurityScope() {
            if didAccessScope {
                scopedURL?.stopAccessingSecurityScopedResource()
            }
        }
    }

    private struct ResolvedInspectionRoot: Sendable {
        let parentURL: URL
        let didAccessScope: Bool
        let refreshedBookmark: Data?

        func releaseSecurityScope() {
            if didAccessScope {
                parentURL.stopAccessingSecurityScopedResource()
            }
        }
    }

    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let userDefaultsSynchronizer:
        @Sendable (UserDefaults) -> Bool
    private let overrideRoot: URL?
    private let libraryLoadReturnDelay: Duration
    private let defaultDocumentsURLForTesting: URL?
    private let repositoryFactory:
        @Sendable (URL) throws -> FileNotebookRepository
    private let libraryMetadataReadHook: @Sendable (URL) -> Void
    private let academicWorkspaceAtomicWriter: AcademicWorkspaceAtomicWriter
    private var activeSecurityScopedURL: URL?
    private var cachedRootURL: URL?
    private var cachedRepository: FileNotebookRepository?
    private var academicWorkspaceRootFingerprint = AcademicWorkspaceStorageFingerprint()
    private var pendingRootTransition: PendingRootTransition?
    private var activeRootPreparationIDs: Set<UUID> = []
    private var cancelledRootPreparationIDs: Set<UUID> = []
    private var preparedRootCandidates:
        [NotesAppLibraryRootPreparation: PreparedRootTransitionCandidate] = [:]
    private var activeLibraryInspectionRoots: [UUID: URL] = [:]
    private var securityScopesAwaitingInspectionDrain: [URL: [URL]] = [:]

    init(
        fileManager: FileManager = .default,
        userDefaultsSuiteName: String? = nil,
        overrideRoot: URL? = nil,
        libraryLoadReturnDelay: Duration = .zero,
        defaultDocumentsURLForTesting: URL? = nil,
        userDefaultsSynchronizer:
            @escaping @Sendable (UserDefaults) -> Bool = { $0.synchronize() },
        libraryMetadataReadHook: @escaping @Sendable (URL) -> Void = { _ in },
        academicWorkspaceAtomicWriter:
            @escaping AcademicWorkspaceAtomicWriter = { data, name, authority in
                try AcademicWorkspaceDiskIO.atomicWrite(
                    data,
                    named: name,
                    authority: authority
                )
            },
        repositoryFactory:
            @escaping @Sendable (URL) throws -> FileNotebookRepository = {
                try FileNotebookRepository(rootURL: $0)
            }
    ) {
        let resolvedUserDefaults: UserDefaults
        if let userDefaultsSuiteName {
            guard let suiteDefaults = UserDefaults(suiteName: userDefaultsSuiteName) else {
                preconditionFailure("Unable to create UserDefaults suite: \(userDefaultsSuiteName)")
            }
            resolvedUserDefaults = suiteDefaults
        } else {
            resolvedUserDefaults = .standard
        }
        self.fileManager = fileManager
        self.userDefaults = resolvedUserDefaults
        self.userDefaultsSynchronizer = userDefaultsSynchronizer
        self.overrideRoot = overrideRoot
        self.libraryLoadReturnDelay = libraryLoadReturnDelay
        self.defaultDocumentsURLForTesting = defaultDocumentsURLForTesting
        self.libraryMetadataReadHook = libraryMetadataReadHook
        self.academicWorkspaceAtomicWriter = academicWorkspaceAtomicWriter
        self.repositoryFactory = repositoryFactory
    }

    func read() async throws(AcademicWorkspaceFileBackingError)
        -> AcademicWorkspaceFileSnapshot {
        do {
            let selectedParent = try libraryRoot().standardizedFileURL
                .deletingLastPathComponent()
            return try AcademicWorkspaceDiskIO.read(
                selectedParent: selectedParent,
                rootFingerprint: academicWorkspaceRootFingerprint
            ).snapshot
        } catch let error as AcademicWorkspaceFileBackingError {
            throw error
        } catch {
            throw .unavailable
        }
    }

    func replace(
        primaryData: Data?,
        backupData: Data?,
        expected: AcademicWorkspaceStorageVersion
    ) async throws(AcademicWorkspaceFileBackingError) -> AcademicWorkspaceFileSnapshot {
        do {
            let selectedParent = try libraryRoot().standardizedFileURL
                .deletingLastPathComponent()
            return try AcademicWorkspaceDiskIO.replace(
                primaryData: primaryData,
                backupData: backupData,
                expected: expected,
                selectedParent: selectedParent,
                rootFingerprint: academicWorkspaceRootFingerprint,
                writer: academicWorkspaceAtomicWriter
            )
        } catch let error as AcademicWorkspaceFileBackingError {
            throw error
        } catch {
            throw .unavailable
        }
    }

    func reset(
        expected: AcademicWorkspaceStorageVersion
    ) async throws(AcademicWorkspaceFileBackingError) -> AcademicWorkspaceFileSnapshot {
        do {
            let selectedParent = try libraryRoot().standardizedFileURL
                .deletingLastPathComponent()
            return try AcademicWorkspaceDiskIO.replace(
                primaryData: nil,
                backupData: nil,
                expected: expected,
                selectedParent: selectedParent,
                rootFingerprint: academicWorkspaceRootFingerprint,
                writer: academicWorkspaceAtomicWriter
            )
        } catch let error as AcademicWorkspaceFileBackingError {
            throw error
        } catch {
            throw .unavailable
        }
    }

    func loadLibrary() async throws -> [LibraryNotebook] {
        let inspectionRoot = try await libraryRootForInspection().standardizedFileURL
        // Record the resolved authoritative route before repository creation can
        // suspend on a Files provider. A concurrent recovery transition can then
        // retain this root's scope even when no repository was cached yet.
        if cachedRootURL == nil {
            cachedRootURL = inspectionRoot
        }
        let libraryInspection = beginLibraryInspection(at: inspectionRoot)
        let candidateInspection = beginCandidateInspection()
        defer {
            finishCandidateInspection(candidateInspection)
            finishLibraryInspection(libraryInspection)
        }
        let repository = try await repositoryForLibraryInspection(at: inspectionRoot)
        let metadataURL = inspectionRoot.appendingPathComponent(Constants.metadataFile)
        let metadataReadHook = libraryMetadataReadHook
        // Files providers may block synchronous URL reads without observing Swift
        // cancellation. Keep that work off this actor so a timed-out candidate
        // inspection cannot prevent rollback from restoring the previous route.
        let metadataWorker = Task.detached(priority: .userInitiated) {
            metadataReadHook(metadataURL)
            return Self.readMetadata(at: metadataURL, fileManager: FileManager())
        }
        let metadata = await withTaskCancellationHandler {
            await metadataWorker.value
        } onCancel: {
            metadataWorker.cancel()
        }
        try Task.checkCancellation()
        let loaded = try await repository.listNotebooks().map { manifest in
            makeEditorNotebook(from: manifest, metadata: metadataEntry(for: manifest, in: metadata)).summary
        }
        // A deterministic seam for proving that AppModel never overwrites a
        // mutation with a library snapshot captured before that mutation.
        if libraryLoadReturnDelay != .zero {
            try await Task.sleep(for: libraryLoadReturnDelay)
        }
        return loaded
    }

    func createNotebook(
        title: String,
        kind: NotebookKind,
        template: PaperTemplate
    ) async throws -> EditorNotebook {
        let repository = try repository()
        let page = EditorPage.newPage(for: kind, template: template)
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest = try await repository.createNotebook(
            title: normalizedTitle.isEmpty ? String(localized: "Untitled") : normalizedTitle,
            initialPage: makeCorePage(from: page)
        )
        var metadata = try loadMetadata()
        let entry = NotebookMetadata(kind: kind, deletedAt: nil, coverHue: Self.coverHue(for: manifest.id.rawValue))
        metadata.notebooks[manifest.id.description] = entry
        try saveMetadata(metadata)
        return makeEditorNotebook(from: manifest, metadata: entry)
    }

    /// Ensures the exact Notes package reserved by a CourseSession start saga.
    ///
    /// A retry never creates a replacement identity. It either verifies the
    /// caller-owned notebook/page or fails closed, while a missing UI metadata
    /// entry is safe to reconstruct from the verified package.
    func ensureSessionTextNote(
        _ request: SessionTextNoteRequest
    ) async throws -> EditorNotebook {
        let normalizedTitle = request.title.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedTitle.isEmpty,
              request.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw SessionTextNoteStoreError.invalidRequest
        }

        let notebookID = NotebookID(request.notebookID)
        let metadataKey = notebookID.description
        var metadata = try loadMetadata()
        if let existingMetadata = metadata.notebooks[metadataKey] {
            try validateSessionTextNoteMetadata(existingMetadata)
        }

        let repository = try repository()
        let manifest = try await loadOrCreateSessionTextNoteManifest(
            repository: repository,
            request: request,
            normalizedTitle: normalizedTitle
        )
        try validateSessionTextNoteManifest(
            manifest,
            request: request
        )

        // Repository I/O yields this actor. Re-read the UI sidecar so a
        // concurrent trash or kind change cannot be overwritten by the stale
        // metadata snapshot captured before package verification.
        metadata = try loadMetadata()
        if let existingMetadata = metadata.notebooks[metadataKey] {
            try validateSessionTextNoteMetadata(existingMetadata)
        }

        let entry: NotebookMetadata
        if let existingMetadata = metadata.notebooks[metadataKey] {
            entry = existingMetadata
        } else {
            entry = NotebookMetadata(
                kind: .textDocument,
                deletedAt: nil,
                coverHue: Self.coverHue(for: request.notebookID)
            )
            metadata.notebooks[metadataKey] = entry
            try saveMetadata(metadata)
        }
        return makeEditorNotebook(from: manifest, metadata: entry)
    }

    func importDocument(at sourceURL: URL) async throws -> EditorNotebook {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess { sourceURL.stopAccessingSecurityScopedResource() }
        }

        let pathExtension = sourceURL.pathExtension.lowercased()
        guard ["notepkg", "pdf", "jpg", "jpeg", "png"].contains(pathExtension) else {
            throw StoreError.unsupportedFile
        }
        if pathExtension == NotebookPackageLayout.packageExtension {
            return try await importNotebookPackage(at: sourceURL)
        }
        let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
        let repository = try repository()
        let title = sourceURL.deletingPathExtension().lastPathComponent
        let initialManifest = try await repository.createNotebook(
            title: title.isEmpty ? String(localized: "Untitled") : title,
            initialPage: nil
        )
        let mediaType = pathExtension == "pdf"
            ? "application/pdf"
            : (pathExtension == "png" ? "image/png" : "image/jpeg")
        let asset = try await repository.importAsset(
            data,
            notebookID: initialManifest.id,
            mediaType: mediaType,
            originalFilename: sourceURL.lastPathComponent
        )

        var manifest = initialManifest
        let kind: NotebookKind
        if pathExtension == "pdf" {
            guard let document = PDFDocument(data: data), document.pageCount > 0 else {
                try? await repository.deleteNotebook(id: initialManifest.id)
                throw StoreError.unreadableDocument
            }
            kind = .pdf
            for pageIndex in 0 ..< document.pageCount {
                let bounds = document.page(at: pageIndex)?.bounds(for: .mediaBox)
                    ?? CGRect(x: 0, y: 0, width: 768, height: 1_024)
                let page = NotesCore.PageDescriptor(
                    kind: .importedDocument,
                    size: NotesCore.PageSize(width: Double(max(bounds.width, 1)), height: Double(max(bounds.height, 1))),
                    background: .pdf(assetID: asset.id, pageIndex: pageIndex)
                )
                manifest = try await repository.addPage(notebookID: manifest.id, page: page, at: nil)
            }
        } else {
            guard let image = UIImage(data: data) else {
                try? await repository.deleteNotebook(id: initialManifest.id)
                throw StoreError.unreadableDocument
            }
            kind = .image
            let size = image.size == .zero ? CGSize(width: 768, height: 1_024) : image.size
            let page = NotesCore.PageDescriptor(
                kind: .importedDocument,
                size: NotesCore.PageSize(width: Double(max(size.width, 1)), height: Double(max(size.height, 1))),
                background: .image(assetID: asset.id)
            )
            manifest = try await repository.addPage(notebookID: manifest.id, page: page, at: nil)
        }

        var metadata = try loadMetadata()
        let entry = NotebookMetadata(kind: kind, deletedAt: nil, coverHue: Self.coverHue(for: manifest.id.rawValue))
        metadata.notebooks[manifest.id.description] = entry
        try saveMetadata(metadata)
        return makeEditorNotebook(from: manifest, metadata: entry)
    }

    func loadNotebook(id: UUID) async throws -> EditorNotebook {
        let repository = try repository()
        let manifest = try await repository.openNotebook(id: NotebookID(id))
        return makeEditorNotebook(from: manifest, metadata: metadataEntry(for: manifest, in: try loadMetadata()))
    }

    func loadNotebookForExport(id: UUID) async throws -> EditorNotebook {
        let manifest = try await repository().openNotebookForExport(id: NotebookID(id))
        // Export does not need trash/cover sidecar state. Avoid the UI metadata file entirely so
        // every persistence read in the PDF snapshot path remains bounded and no-follow.
        return makeEditorNotebook(
            from: manifest,
            metadata: metadataEntry(for: manifest, in: LibraryMetadata())
        )
    }

    func beginReplayReadSession(
        notebookID: NotebookID
    ) async throws -> NoteReplayStoreSession {
        let context = try await repository().beginNotebookExport(id: notebookID)
        return NoteReplayStoreSession(
            token: context.session,
            manifest: context.manifest
        )
    }

    func loadReplayTimeline(
        session: NoteReplayStoreSession,
        sessionID: AudioSessionID,
        maximumMarkCount: Int
    ) async throws -> AudioTimelineDocument {
        try await repository().loadAudioTimelineForReplay(
            session: session.token,
            sessionID: sessionID,
            maximumMarkCount: maximumMarkCount
        )
    }

    func loadReplayInk(
        session: NoteReplayStoreSession,
        pageID: PageID,
        maximumByteCount: Int
    ) async throws -> Data? {
        try await repository().loadInkForReplay(
            session: session.token,
            pageID: pageID,
            maximumByteCount: maximumByteCount
        )
    }

    func loadNoteReplayHistoryForReplay(
        session: NotebookExportSession,
        sessionID: AudioSessionID,
        maximumEventCount: Int
    ) async throws -> NoteReplayHistoryDocument? {
        try await repository().loadNoteReplayHistoryForReplay(
            session: session,
            sessionID: sessionID,
            maximumEventCount: maximumEventCount
        )
    }

    func loadNoteReplayInkPayloadForReplay(
        session: NotebookExportSession,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int
    ) async throws -> Data? {
        try await repository().loadNoteReplayInkPayloadForReplay(
            session: session,
            reference: reference,
            maximumByteCount: maximumByteCount
        )
    }

    func loadNoteReplayElementsPayloadForReplay(
        session: NotebookExportSession,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int,
        maximumElementCount: Int
    ) async throws -> NotebookExportCanvasElements {
        try await repository().loadNoteReplayElementsPayloadForReplay(
            session: session,
            reference: reference,
            maximumByteCount: maximumByteCount,
            maximumElementCount: maximumElementCount
        )
    }

    func endReplayReadSession(_ session: NoteReplayStoreSession) async {
        guard let repository = try? repository() else { return }
        await repository.endNotebookExport(session.token)
    }

    func beginNotebookExport(id: UUID) async throws -> NotesAppNotebookExportSession {
        let context = try await repository().beginNotebookExport(id: NotebookID(id))
        return NotesAppNotebookExportSession(
            token: context.session,
            notebook: makeEditorNotebook(
                from: context.manifest,
                metadata: metadataEntry(for: context.manifest, in: LibraryMetadata())
            )
        )
    }

    func validateNotebookExportSession(
        _ session: NotesAppNotebookExportSession
    ) async throws -> EditorNotebook {
        let manifest = try await repository().validateNotebookExportSession(session.token)
        return makeEditorNotebook(
            from: manifest,
            metadata: metadataEntry(for: manifest, in: LibraryMetadata())
        )
    }

    func endNotebookExport(_ session: NotesAppNotebookExportSession) async {
        guard let repository = try? repository() else { return }
        await repository.endNotebookExport(session.token)
    }

    func audioSessionDescriptorForExport(
        session: NotesAppNotebookExportSession,
        sessionID: AudioSessionID
    ) async throws -> AudioSessionDescriptor {
        try await repository().audioSessionDescriptorForExport(
            session: session.token,
            sessionID: sessionID
        )
    }

    func loadAudioChunkForExport(
        session: NotesAppNotebookExportSession,
        sessionID: AudioSessionID,
        offset: Int64,
        maximumByteCount: Int
    ) async throws -> Data {
        try await repository().loadAudioChunkForExport(
            session: session.token,
            sessionID: sessionID,
            offset: offset,
            maximumByteCount: maximumByteCount
        )
    }

    func loadAudioTranscriptForExport(
        session: NotesAppNotebookExportSession,
        sessionID: AudioSessionID
    ) async throws -> AudioTranscriptDocument? {
        try await repository().loadAudioTranscriptForExport(
            session: session.token,
            sessionID: sessionID
        )
    }

    func saveNotebook(_ notebook: EditorNotebook) async throws {
        let repository = try repository()
        let notebookID = NotebookID(notebook.id)
        var manifest = try await repository.openNotebook(id: notebookID)

        if manifest.title != notebook.title || manifest.isFavorite != notebook.isFavorite {
            manifest = try await repository.updateNotebookMetadata(
                id: notebookID,
                title: notebook.title,
                tags: nil,
                isFavorite: notebook.isFavorite
            )
        }

        let desiredPageIDs = notebook.pages.map { PageID($0.id) }
        let desiredPageIDSet = Set(desiredPageIDs)
        for page in manifest.pages where !desiredPageIDSet.contains(page.id) {
            manifest = try await repository.deletePage(notebookID: notebookID, pageID: page.id)
        }

        var storedPageIDs = Set(manifest.pages.map(\.id))
        for (index, page) in notebook.pages.enumerated() where !storedPageIDs.contains(PageID(page.id)) {
            manifest = try await repository.addPage(
                notebookID: notebookID,
                page: makeCorePage(from: page),
                at: index
            )
            storedPageIDs.insert(PageID(page.id))
        }
        if manifest.pages.map(\.id) != desiredPageIDs {
            manifest = try await repository.reorderPages(notebookID: notebookID, pageIDs: desiredPageIDs)
        }

        var metadata = try loadMetadata()
        let updatedMetadata = NotebookMetadata(
            kind: notebook.kind,
            deletedAt: notebook.deletedAt,
            coverHue: notebook.coverHue
        )
        if metadata.notebooks[notebookID.description] != updatedMetadata {
            metadata.notebooks[notebookID.description] = updatedMetadata
            try saveMetadata(metadata)
        }
    }

    func updatePageNavigationMetadata(
        notebookID: UUID,
        pageID: UUID,
        update: PageNavigationMetadataUpdate
    ) async throws -> EditorNotebook {
        let id = NotebookID(notebookID)
        let manifest = try await repository().updatePageNavigationMetadata(
            notebookID: id,
            pageID: PageID(pageID),
            update: update
        )
        return makeEditorNotebook(
            from: manifest,
            metadata: metadataEntry(for: manifest, in: try loadMetadata())
        )
    }

    /// Removes only the partially-created page during duplicate compensation.
    /// This deliberately avoids replaying an older whole-notebook snapshot,
    /// which could overwrite a concurrent title, page-order, or metadata change.
    func deletePage(notebookID: UUID, pageID: UUID) async throws -> EditorNotebook {
        let repository = try repository()
        let id = NotebookID(notebookID)
        let manifest = try await repository.deletePage(
            notebookID: id,
            pageID: PageID(pageID)
        )
        return makeEditorNotebook(
            from: manifest,
            metadata: metadataEntry(for: manifest, in: try loadMetadata())
        )
    }

    func loadInk(notebookID: UUID, page: EditorPage) async throws -> Data? {
        try await repository().loadInk(notebookID: NotebookID(notebookID), pageID: PageID(page.id))
    }

    func loadInkForExport(notebookID: UUID, page: EditorPage) async throws -> Data? {
        try await repository().loadInkForExport(
            notebookID: NotebookID(notebookID),
            pageID: PageID(page.id)
        )
    }

    func loadInkForExport(
        session: NotesAppNotebookExportSession,
        page: EditorPage
    ) async throws -> Data? {
        try await repository().loadInkForExport(
            session: session.token,
            pageID: PageID(page.id)
        )
    }

    func saveInk(_ data: Data, notebookID: UUID, page: EditorPage) async throws {
        try await repository().saveInk(data, notebookID: NotebookID(notebookID), pageID: PageID(page.id))
    }

    func loadElements(notebookID: UUID, pageID: UUID) async throws -> [CanvasElement] {
        try await repository().loadElements(
            notebookID: NotebookID(notebookID),
            pageID: PageID(pageID)
        )
    }

    func loadElementsForExport(
        notebookID: UUID,
        pageID: UUID
    ) async throws -> [CanvasElement] {
        try await repository().loadElementsForExport(
            notebookID: NotebookID(notebookID),
            pageID: PageID(pageID)
        )
    }

    func loadElementsForExport(
        session: NotesAppNotebookExportSession,
        pageID: UUID
    ) async throws -> NotebookExportCanvasElements {
        try await repository().loadElementsForExport(
            session: session.token,
            pageID: PageID(pageID)
        )
    }

    func saveElements(
        _ elements: [CanvasElement],
        notebookID: UUID,
        pageID: UUID
    ) async throws {
        let repository = try repository()
        let id = NotebookID(notebookID)
        let manifest = try await repository.openNotebook(id: id)
        let imageAssetIDs = Set(manifest.assets.lazy
            .filter { $0.id.isSHA256Digest && $0.mediaType.lowercased().hasPrefix("image/") }
            .map(\.id))
        guard Self.referencedAssetIDs(in: elements).isSubset(of: imageAssetIDs) else {
            throw StoreError.invalidAssetPath
        }
        try await repository.saveElements(
            elements,
            notebookID: id,
            pageID: PageID(pageID)
        )
    }

    func loadPageContent(notebookID: UUID, pageID: UUID) async throws -> NotesCore.PageContent? {
        try await repository().loadPageContent(
            notebookID: NotebookID(notebookID),
            pageID: PageID(pageID)
        )
    }

    func textDocumentSourceSnapshot(
        noteID: NotebookID,
        pageID: PageID,
        blockID: TextBlockID
    ) async throws -> TextDocumentSourceSnapshot {
        try await repository().textDocumentSourceSnapshot(
            noteID: noteID,
            pageID: pageID,
            blockID: blockID
        )
    }

    func savePageContent(
        _ content: NotesCore.PageContent,
        notebookID: UUID,
        pageID: UUID
    ) async throws {
        try await repository().savePageContent(
            content,
            notebookID: NotebookID(notebookID),
            pageID: PageID(pageID)
        )
    }

    func saveHandwritingRecognition(
        _ document: HandwritingRecognitionDocument,
        notebookID: UUID,
        pageID: UUID,
        expectedRunID: UUID?,
        expectedRevision: Int64?
    ) async throws {
        try await repository().saveHandwritingRecognition(
            document,
            notebookID: NotebookID(notebookID),
            pageID: PageID(pageID),
            expectedRunID: expectedRunID,
            expectedRevision: expectedRevision
        )
    }

    func loadHandwritingRecognition(
        notebookID: UUID,
        pageID: UUID
    ) async throws -> HandwritingRecognitionDocument? {
        try await repository().loadHandwritingRecognition(
            notebookID: NotebookID(notebookID),
            pageID: PageID(pageID)
        )
    }

    func loadInkForHandwritingRecognition(
        notebookID: UUID,
        pageID: UUID
    ) async throws -> Data? {
        try await repository().loadInkForHandwritingRecognition(
            notebookID: NotebookID(notebookID),
            pageID: PageID(pageID)
        )
    }

    func listAudioSessions(notebookID: NotebookID) async throws -> [AudioSessionDescriptor] {
        let manifest = try await repository().openNotebook(id: notebookID)
        return manifest.audioSessions.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id.description < rhs.id.description
        }
    }

    func persistRecordedM4A(
        at fileURL: URL,
        maximumByteCount: Int64,
        timeline: NotesCore.AudioTimelineDocument,
        notebookID: NotebookID,
        durationSeconds: Double,
        recordingStartedAt: Date,
        transcriptAssetID: AssetID?
    ) async throws -> NotebookAudioPersistenceReceipt {
        let adapter = NotebookRepositoryAudioPersistence(repository: try repository())
        return try await adapter.persistRecordedM4A(
            at: fileURL,
            maximumByteCount: maximumByteCount,
            timeline: timeline,
            notebookID: notebookID,
            durationSeconds: durationSeconds,
            recordingStartedAt: recordingStartedAt,
            transcriptAssetID: transcriptAssetID
        )
    }

    func persistRecordedM4A(
        at fileURL: URL,
        maximumByteCount: Int64,
        timeline: NotesCore.AudioTimelineDocument,
        replayHistory: NoteReplayCaptureBundle,
        notebookID: NotebookID,
        durationSeconds: Double,
        recordingStartedAt: Date,
        transcriptAssetID: AssetID?
    ) async throws -> NotebookAudioPersistenceReceipt {
        let adapter = NotebookRepositoryAudioPersistence(
            repository: try repository()
        )
        return try await adapter.persistRecordedM4A(
            at: fileURL,
            maximumByteCount: maximumByteCount,
            timeline: timeline,
            replayHistory: replayHistory,
            notebookID: notebookID,
            durationSeconds: durationSeconds,
            recordingStartedAt: recordingStartedAt,
            transcriptAssetID: transcriptAssetID
        )
    }

    func descriptor(
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> AudioSessionDescriptor {
        let adapter = NotebookRepositoryAudioPersistence(repository: try repository())
        return try await adapter.descriptor(notebookID: notebookID, sessionID: sessionID)
    }

    func loadAudioChunk(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        offset: Int64,
        maximumByteCount: Int
    ) async throws -> Data {
        try await repository().loadAudioChunk(
            notebookID: notebookID,
            sessionID: sessionID,
            offset: offset,
            maximumByteCount: maximumByteCount
        )
    }

    func loadTimeline(
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> NotesCore.AudioTimelineDocument {
        try await repository().loadAudioTimeline(
            notebookID: notebookID,
            sessionID: sessionID
        )
    }

    func saveTranscript(
        _ transcript: NotebookAudioTranscriptPayload,
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> AudioSessionDescriptor {
        try await repository().saveAudioTranscript(
            transcript,
            notebookID: notebookID,
            sessionID: sessionID
        )
    }

    func loadTranscript(
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> NotebookAudioTranscriptPayload? {
        try await repository().loadAudioTranscript(
            notebookID: notebookID,
            sessionID: sessionID
        )
    }

    func deleteSession(
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws {
        try await repository().deleteAudioSession(
            notebookID: notebookID,
            sessionID: sessionID
        )
    }

    func availableImageAssets(notebookID: UUID) async throws -> [AssetDescriptor] {
        let manifest = try await repository().openNotebook(id: NotebookID(notebookID))
        return Array(manifest.assets.lazy
            .filter { $0.id.isSHA256Digest && $0.mediaType.lowercased().hasPrefix("image/") }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id.rawValue < rhs.id.rawValue
            }
            .prefix(256))
    }

    func assetURLs(
        notebookID: UUID,
        assetIDs: Set<AssetID>
    ) async throws -> [AssetID: URL] {
        let repository = try repository()
        let id = NotebookID(notebookID)
        let manifest = try await repository.openNotebook(id: id)
        let availableIDs = Set(manifest.assets.lazy
            .filter { $0.id.isSHA256Digest && $0.mediaType.lowercased().hasPrefix("image/") }
            .map(\.id))
        var result: [AssetID: URL] = [:]
        result.reserveCapacity(min(assetIDs.count, availableIDs.count))
        for assetID in assetIDs where assetID.isSHA256Digest && availableIDs.contains(assetID) {
            let url = repository.packageURL(for: id)
                .appendingPathComponent("assets", isDirectory: true)
                .appendingPathComponent(assetID.rawValue, isDirectory: false)
                .standardizedFileURL
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isRegularFile == true, values?.isSymbolicLink != true {
                result[assetID] = url
            }
        }
        return result
    }

    private static func referencedAssetIDs(in elements: [CanvasElement]) -> Set<AssetID> {
        Set(elements.compactMap { element in
            switch element.content {
            case .image(let image): image.assetID
            case .sticker(let sticker): sticker.assetID
            case .text, .shape, .connector, .stickyNote, .tape, .link: nil
            }
        })
    }

    func assetURL(notebookID: UUID, relativePath: String) throws -> URL {
        let repository = try repository()
        let package = repository.packageURL(for: NotebookID(notebookID))
        let candidate = package.appendingPathComponent(relativePath).standardizedFileURL
        let packagePath = package.standardizedFileURL.path
        guard candidate.path.hasPrefix(packagePath + "/") else {
            throw StoreError.invalidAssetPath
        }
        return candidate
    }

    func loadBackgroundAssetForExport(
        notebookID: UUID,
        relativePath: String
    ) async throws -> Data {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard components.count == 2,
              components[0] == "assets",
              !relativePath.contains("\\"),
              !relativePath.hasPrefix("/"),
              !relativePath.hasSuffix("/"),
              !components[1].isEmpty else {
            throw StoreError.invalidAssetPath
        }
        let assetID = AssetID(components[1])
        guard assetID.isSHA256Digest else {
            throw StoreError.invalidAssetPath
        }
        return try await repository().loadAssetForExport(
            notebookID: NotebookID(notebookID),
            assetID: assetID
        )
    }

    func loadBackgroundAssetForExport(
        session: NotesAppNotebookExportSession,
        relativePath: String
    ) async throws -> Data {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard components.count == 2,
              components[0] == "assets",
              !relativePath.contains("\\"),
              !relativePath.hasPrefix("/"),
              !relativePath.hasSuffix("/"),
              !components[1].isEmpty else {
            throw StoreError.invalidAssetPath
        }
        let assetID = AssetID(components[1])
        guard assetID.isSHA256Digest else {
            throw StoreError.invalidAssetPath
        }
        return try await repository().loadAssetForExport(
            session: session.token,
            assetID: assetID
        )
    }

    func loadCanvasAssetsForExport(
        notebookID: UUID,
        assetIDs: [AssetID]
    ) async throws -> [AssetID: Data] {
        try await repository().loadCanvasAssetsForExport(
            notebookID: NotebookID(notebookID),
            assetIDs: assetIDs
        )
    }

    func loadCanvasAssetsForExport(
        session: NotesAppNotebookExportSession,
        assetIDs: [AssetID]
    ) async throws -> [AssetID: Data] {
        try await repository().loadCanvasAssetsForExport(
            session: session.token,
            assetIDs: assetIDs
        )
    }

    func packageURL(notebookID: UUID) async throws -> URL {
        let repository = try repository()
        let exports = fileManager.temporaryDirectory.appendingPathComponent("NotesPackageExports", isDirectory: true)
        try fileManager.createDirectory(at: exports, withIntermediateDirectories: true)
        let destination = exports
            .appendingPathComponent(notebookID.uuidString.lowercased(), isDirectory: false)
            .appendingPathExtension(NotebookPackageLayout.packageExtension)
        return try await repository.exportSnapshot(
            id: NotebookID(notebookID),
            to: destination
        )
    }

    func exportNotebookSnapshots(to directory: URL) async throws -> [URL] {
        let repository = try repository()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifests = try await repository.listNotebooks()
        var snapshots: [URL] = []
        snapshots.reserveCapacity(manifests.count)
        for manifest in manifests {
            let destination = directory
                .appendingPathComponent(manifest.id.description, isDirectory: false)
                .appendingPathExtension(NotebookPackageLayout.packageExtension)
            snapshots.append(
                try await repository.exportSnapshot(id: manifest.id, to: destination)
            )
        }
        return snapshots
    }

    func libraryDirectoryURL() throws -> URL {
        try libraryRoot()
    }

    func validateRestoredNotebookPackages(_ urls: [URL]) async throws {
        let root = try libraryRoot().standardizedFileURL
        let repository = try repository()
        do {
            for url in urls {
                let standardized = url.standardizedFileURL
                guard standardized.deletingLastPathComponent() == root,
                      standardized.pathExtension.caseInsensitiveCompare(NotebookPackageLayout.packageExtension) == .orderedSame,
                      let uuid = UUID(uuidString: standardized.deletingPathExtension().lastPathComponent) else {
                    throw StoreError.invalidNotebookPackage
                }
                let report = try await repository.validateNotebook(id: NotebookID(uuid))
                guard report.isValid else { throw StoreError.invalidNotebookPackage }
            }
            _ = try await repository.rebuildLibraryIndex()
        } catch {
            for url in urls where url.standardizedFileURL.deletingLastPathComponent() == root {
                try? fileManager.removeItem(at: url)
            }
            _ = try? await repository.rebuildLibraryIndex()
            throw error
        }
    }

    func deleteNotebook(id: UUID, permanently: Bool) async throws {
        let repository = try repository()
        let notebookID = NotebookID(id)
        var metadata = try loadMetadata()
        if permanently {
            try await repository.deleteNotebook(id: notebookID)
            metadata.notebooks.removeValue(forKey: notebookID.description)
            // The notebook package is the authoritative user data and is now
            // durably gone. A stale orphaned UI-metadata entry is harmless and
            // must not make a successful destructive operation look failed.
            try? saveMetadata(metadata)
            return
        } else {
            let manifest = try await repository.openNotebook(id: notebookID)
            var entry = metadataEntry(for: manifest, in: metadata)
            entry.deletedAt = Date()
            metadata.notebooks[notebookID.description] = entry
        }
        try saveMetadata(metadata)
    }

    func setRootDirectory(_ url: URL?) async throws {
        let preparation = NotesAppLibraryRootPreparation()
        var transition: NotesAppLibraryRootTransition?
        do {
            try await prepareRootDirectoryTransition(to: url, preparation: preparation)
            let installed = try beginRootDirectoryTransition(preparation)
            transition = installed
            try commitRootDirectoryTransition(installed)
            finalizeRootDirectoryTransition(installed)
        } catch {
            if let transition {
                rollbackRootDirectoryTransition(transition)
            } else {
                cancelRootDirectoryPreparation(preparation)
            }
            throw error
        }
    }

    func prepareRootDirectoryTransition(
        to url: URL?,
        preparation: NotesAppLibraryRootPreparation
    ) async throws {
        try Task.checkCancellation()
        guard pendingRootTransition == nil,
              preparedRootCandidates.isEmpty,
              activeRootPreparationIDs.isEmpty else {
            throw StoreError.rootTransitionInProgress
        }
        if cancelledRootPreparationIDs.remove(preparation.id) != nil {
            throw CancellationError()
        }
        activeRootPreparationIDs.insert(preparation.id)
        defer { activeRootPreparationIDs.remove(preparation.id) }

        let overrideRoot = overrideRoot
        let defaultDocumentsURLForTesting = defaultDocumentsURLForTesting
        let defaultDocumentsURL: URL?
        if overrideRoot == nil, url == nil, defaultDocumentsURLForTesting == nil {
            defaultDocumentsURL = fileManager.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first
        } else {
            defaultDocumentsURL = nil
        }
        let repositoryFactory = repositoryFactory
        let worker = Task.detached(priority: .userInitiated) {
            () throws -> PreparedRootTransitionCandidate in
            var didAccessScope = false
            var scopedURL: URL?
            do {
                let candidateRoot: URL
                let candidateBookmark: Data?
                let updatesBookmark: Bool
                if let overrideRoot {
                    candidateRoot = overrideRoot.appendingPathComponent(
                        Constants.libraryFolder,
                        isDirectory: true
                    )
                    candidateBookmark = nil
                    updatesBookmark = false
                } else if let url {
                    didAccessScope = url.startAccessingSecurityScopedResource()
                    // Keep the requested URL even when a second start returns
                    // false: begin can then recognize and reuse an already-held
                    // security scope for the same external folder.
                    scopedURL = url
                    candidateBookmark = try url.bookmarkData(
                        options: .minimalBookmark,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                    candidateRoot = url.appendingPathComponent(
                        Constants.libraryFolder,
                        isDirectory: true
                    )
                    updatesBookmark = true
                } else {
                    candidateBookmark = nil
                    if let defaultDocumentsURLForTesting {
                        candidateRoot = defaultDocumentsURLForTesting.appendingPathComponent(
                            Constants.libraryFolder,
                            isDirectory: true
                        )
                    } else {
                        guard let documents = defaultDocumentsURL else {
                            throw StoreError.rootUnavailable
                        }
                        candidateRoot = documents.appendingPathComponent(
                            Constants.libraryFolder,
                            isDirectory: true
                        )
                    }
                    updatesBookmark = true
                }

                try Task.checkCancellation()
                let standardizedRoot = candidateRoot.standardizedFileURL
                let candidateRepository = try repositoryFactory(standardizedRoot)
                try Task.checkCancellation()
                return PreparedRootTransitionCandidate(
                    rootURL: standardizedRoot,
                    repository: candidateRepository,
                    bookmark: candidateBookmark,
                    scopedURL: scopedURL,
                    didAccessScope: didAccessScope,
                    updatesBookmark: updatesBookmark
                )
            } catch {
                if didAccessScope {
                    scopedURL?.stopAccessingSecurityScopedResource()
                }
                throw error
            }
        }

        let candidate: PreparedRootTransitionCandidate
        do {
            candidate = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
                Task { await self.cancelRootDirectoryPreparation(preparation) }
            }
        } catch {
            cancelledRootPreparationIDs.remove(preparation.id)
            throw error
        }
        guard !Task.isCancelled,
              cancelledRootPreparationIDs.remove(preparation.id) == nil else {
            candidate.releaseSecurityScope()
            throw CancellationError()
        }
        preparedRootCandidates[preparation] = candidate
    }

    func beginRootDirectoryTransition(
        _ preparation: NotesAppLibraryRootPreparation
    ) throws -> NotesAppLibraryRootTransition {
        guard pendingRootTransition == nil,
              let candidate = preparedRootCandidates.removeValue(forKey: preparation) else {
            throw StoreError.invalidRootTransition
        }

        let previousRootURL = cachedRootURL
        let previousRepository = cachedRepository
        let previousScopedURL = activeSecurityScopedURL
        let previousMatchesCandidate: Bool
        if let previousScopedURL, let candidateScopedURL = candidate.scopedURL,
           overrideRoot == nil {
            previousMatchesCandidate = previousScopedURL.standardizedFileURL
                == candidateScopedURL.standardizedFileURL
        } else {
            previousMatchesCandidate = false
        }
        let candidateActiveScopedURL: URL?
        let candidateOwnsSecurityScope: Bool
        if candidate.didAccessScope {
            candidateActiveScopedURL = candidate.scopedURL
            candidateOwnsSecurityScope = true
        } else if previousMatchesCandidate {
            candidateActiveScopedURL = previousScopedURL
            candidateOwnsSecurityScope = false
        } else if let transferredScope = takeRetiredSecurityScope(
            for: candidate.rootURL
        ) {
            candidateActiveScopedURL = transferredScope
            candidateOwnsSecurityScope = true
        } else {
            candidateActiveScopedURL = nil
            candidateOwnsSecurityScope = false
        }

        let capability = NotesAppLibraryRootTransition()
        cachedRootURL = candidate.rootURL
        cachedRepository = candidate.repository
        activeSecurityScopedURL = candidateActiveScopedURL
        academicWorkspaceRootFingerprint = AcademicWorkspaceStorageFingerprint()
        pendingRootTransition = PendingRootTransition(
            capability: capability,
            previousRootURL: previousRootURL,
            previousRepository: previousRepository,
            previousScopedURL: previousScopedURL,
            candidateRootURL: candidate.rootURL,
            candidateBookmark: candidate.bookmark,
            candidateScopedURL: candidateActiveScopedURL,
            candidateDidAccessScope: candidateOwnsSecurityScope,
            previousMatchesCandidate: previousMatchesCandidate,
            updatesBookmark: candidate.updatesBookmark,
            previousBookmark: userDefaults.data(forKey: Constants.bookmarkKey),
            isCommitted: false,
            activeInspectionCount: 0
        )
        return capability
    }

    func cancelRootDirectoryPreparation(
        _ preparation: NotesAppLibraryRootPreparation
    ) {
        if let candidate = preparedRootCandidates.removeValue(forKey: preparation) {
            candidate.releaseSecurityScope()
            cancelledRootPreparationIDs.remove(preparation.id)
        } else if activeRootPreparationIDs.contains(preparation.id) {
            cancelledRootPreparationIDs.insert(preparation.id)
        } else {
            cancelledRootPreparationIDs.remove(preparation.id)
        }
    }

    /// Makes the candidate durable while deliberately retaining the previous
    /// repository and security scope. AppModel can still roll this commit back
    /// after its actor hop if a late page callback crossed the final fence.
    func commitRootDirectoryTransition(
        _ transition: NotesAppLibraryRootTransition
    ) throws {
        guard var pending = pendingRootTransition,
              pending.capability == transition,
              pending.activeInspectionCount == 0 else {
            throw StoreError.invalidRootTransition
        }
        guard !pending.isCommitted else { return }
        if pending.updatesBookmark {
            storeRootBookmark(pending.candidateBookmark)
            guard userDefaultsSynchronizer(userDefaults) else {
                // A candidate must not become authoritative unless the launch
                // bookmark crossed the same durability boundary. Restore the
                // prior value before exposing the failed commit to the caller.
                storeRootBookmark(pending.previousBookmark)
                _ = userDefaultsSynchronizer(userDefaults)
                throw StoreError.invalidRootTransition
            }
        }
        pending.isCommitted = true
        pendingRootTransition = pending
    }

    /// Releases the previous root only after AppModel has crossed its final
    /// reentrancy fence and accepted the candidate as authoritative.
    func finalizeRootDirectoryTransition(
        _ transition: NotesAppLibraryRootTransition
    ) {
        guard let pending = pendingRootTransition,
              pending.capability == transition,
              pending.isCommitted,
              pending.activeInspectionCount == 0 else { return }
        if let previousScopedURL = pending.previousScopedURL,
           pending.candidateDidAccessScope || !pending.previousMatchesCandidate {
            // If both URLs are equal and a fresh scope was acquired, this
            // balances only the previous acquisition and retains the candidate.
            retireSecurityScope(
                previousScopedURL,
                untilInspectionsFinishAt: pending.previousRootURL
            )
        }
        pendingRootTransition = nil
    }

    func rollbackRootDirectoryTransition(
        _ transition: NotesAppLibraryRootTransition
    ) {
        guard let pending = pendingRootTransition,
              pending.capability == transition else { return }
        cachedRootURL = pending.previousRootURL
        cachedRepository = pending.previousRepository
        activeSecurityScopedURL = pending.previousScopedURL
        academicWorkspaceRootFingerprint = AcademicWorkspaceStorageFingerprint()
        if pending.isCommitted, pending.updatesBookmark {
            storeRootBookmark(pending.previousBookmark)
            _ = userDefaultsSynchronizer(userDefaults)
        }
        if pending.candidateDidAccessScope,
           let candidateScopedURL = pending.candidateScopedURL {
            retireSecurityScope(
                candidateScopedURL,
                untilInspectionsFinishAt: pending.candidateRootURL
            )
        }
        // Inspection leases retain any needed scope independently, so routing
        // control can be released immediately and a different recovery folder
        // can be attempted even if the cancelled provider read never returns.
        pendingRootTransition = nil
    }

    func rootDescription() -> String {
        (try? libraryRoot().deletingLastPathComponent().lastPathComponent) ?? String(localized: "Unavailable")
    }

    /// Internal observability seam for deterministic transition-lease tests.
    func isRootTransitionInspectionActive() -> Bool {
        !activeLibraryInspectionRoots.isEmpty
    }

    /// Internal observability seam for proving that a timeboxed Files-provider
    /// preparation eventually releases its detached worker and token.
    func isRootTransitionPreparationActive() -> Bool {
        !activeRootPreparationIDs.isEmpty || !preparedRootCandidates.isEmpty
    }

    private func beginLibraryInspection(at root: URL) -> UUID {
        let token = UUID()
        activeLibraryInspectionRoots[token] = root.standardizedFileURL
        return token
    }

    private func finishLibraryInspection(_ token: UUID) {
        guard let root = activeLibraryInspectionRoots.removeValue(forKey: token) else {
            return
        }
        guard !activeLibraryInspectionRoots.values.contains(root),
              let scopes = securityScopesAwaitingInspectionDrain.removeValue(
                forKey: root
              ) else { return }
        for scope in scopes {
            scope.stopAccessingSecurityScopedResource()
        }
    }

    private func retireSecurityScope(
        _ scope: URL,
        untilInspectionsFinishAt root: URL?
    ) {
        guard let root = root?.standardizedFileURL,
              activeLibraryInspectionRoots.values.contains(root) else {
            scope.stopAccessingSecurityScopedResource()
            return
        }
        securityScopesAwaitingInspectionDrain[root, default: []].append(scope)
    }

    private func takeRetiredSecurityScope(for root: URL) -> URL? {
        let root = root.standardizedFileURL
        guard var scopes = securityScopesAwaitingInspectionDrain[root],
              !scopes.isEmpty else { return nil }
        let scope = scopes.removeFirst()
        if scopes.isEmpty {
            securityScopesAwaitingInspectionDrain.removeValue(forKey: root)
        } else {
            securityScopesAwaitingInspectionDrain[root] = scopes
        }
        return scope
    }

    private func beginCandidateInspection() -> NotesAppLibraryRootTransition? {
        guard var pending = pendingRootTransition,
              !pending.isCommitted else { return nil }
        pending.activeInspectionCount += 1
        pendingRootTransition = pending
        return pending.capability
    }

    private func finishCandidateInspection(
        _ transition: NotesAppLibraryRootTransition?
    ) {
        guard let transition,
              var pending = pendingRootTransition,
              pending.capability == transition,
              pending.activeInspectionCount > 0 else { return }
        pending.activeInspectionCount -= 1
        pendingRootTransition = pending
    }

    private func storeRootBookmark(_ bookmark: Data?) {
        if let bookmark {
            userDefaults.set(bookmark, forKey: Constants.bookmarkKey)
        } else {
            userDefaults.removeObject(forKey: Constants.bookmarkKey)
        }
    }

    private func repository() throws -> FileNotebookRepository {
        let root = try libraryRoot().standardizedFileURL
        if cachedRootURL == root, let cachedRepository {
            return cachedRepository
        }
        let repository = try repositoryFactory(root)
        cachedRootURL = root
        cachedRepository = repository
        return repository
    }

    private func repositoryForLibraryInspection(
        at root: URL
    ) async throws -> FileNotebookRepository {
        let root = root.standardizedFileURL
        if cachedRootURL == root, let cachedRepository {
            return cachedRepository
        }
        let repositoryFactory = repositoryFactory
        let worker = Task.detached(priority: .userInitiated) {
            try repositoryFactory(root)
        }
        let repository = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        // A recovery root may have been installed while this old-root factory
        // was blocked. Return the captured repository to its fenced inspection,
        // but never replace routing for the now-authoritative root.
        if cachedRootURL == root, cachedRepository == nil {
            cachedRepository = repository
        }
        return repository
    }

    private func importNotebookPackage(at sourceURL: URL) async throws -> EditorNotebook {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !containsSymbolicLink(in: sourceURL) else {
            throw StoreError.invalidNotebookPackage
        }
        let notebookID = try packageNotebookID(at: sourceURL)

        let repository = try repository()
        let destination = repository.packageURL(for: notebookID)
        if sourceURL.standardizedFileURL != destination.standardizedFileURL {
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw StoreError.duplicateNotebook
            }
            do {
                try fileManager.copyItem(at: sourceURL, to: destination)
                let validation = try await repository.validateNotebook(id: notebookID)
                guard validation.isValid else { throw StoreError.invalidNotebookPackage }
                _ = try await repository.rebuildLibraryIndex()
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
        }

        let manifest = try await repository.openNotebook(id: notebookID)
        var metadata = try loadMetadata()
        let entry = metadataEntry(for: manifest, in: metadata)
        metadata.notebooks[manifest.id.description] = entry
        try saveMetadata(metadata)
        return makeEditorNotebook(from: manifest, metadata: entry)
    }

    private func containsSymbolicLink(in root: URL) -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return true }
        while let url = enumerator.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                return true
            }
        }
        return false
    }

    private func packageNotebookID(at packageURL: URL) throws -> NotebookID {
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL, options: .mappedIfSafe) else {
            throw StoreError.invalidNotebookPackage
        }
        guard let identity = try? JSONDecoder().decode(NotebookPackageIdentity.self, from: data) else {
            throw StoreError.invalidNotebookPackage
        }
        return identity.id
    }

    private func libraryRoot() throws -> URL {
        if let pendingRootTransition {
            return pendingRootTransition.candidateRootURL
        }
        if let cachedRootURL {
            return cachedRootURL
        }
        if let overrideRoot {
            return overrideRoot.appendingPathComponent(Constants.libraryFolder, isDirectory: true)
        }
        if let activeSecurityScopedURL {
            return activeSecurityScopedURL.appendingPathComponent(Constants.libraryFolder, isDirectory: true)
        }
        if let bookmark = userDefaults.data(forKey: Constants.bookmarkKey) {
            var stale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withoutUI,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                if resolvedURL.startAccessingSecurityScopedResource() {
                    activeSecurityScopedURL = resolvedURL
                }
                if stale, let refreshed = try? resolvedURL.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    userDefaults.set(refreshed, forKey: Constants.bookmarkKey)
                }
                return resolvedURL.appendingPathComponent(Constants.libraryFolder, isDirectory: true)
            }
        }
        return try defaultLibraryRoot()
    }

    private func libraryRootForInspection() async throws -> URL {
        if let pendingRootTransition {
            return pendingRootTransition.candidateRootURL
        }
        if let cachedRootURL {
            return cachedRootURL
        }
        if let overrideRoot {
            return overrideRoot.appendingPathComponent(
                Constants.libraryFolder,
                isDirectory: true
            )
        }
        if let activeSecurityScopedURL {
            return activeSecurityScopedURL.appendingPathComponent(
                Constants.libraryFolder,
                isDirectory: true
            )
        }
        if let bookmark = userDefaults.data(forKey: Constants.bookmarkKey) {
            let worker = Task.detached(priority: .userInitiated) {
                () -> ResolvedInspectionRoot? in
                var stale = false
                guard let resolvedURL = try? URL(
                    resolvingBookmarkData: bookmark,
                    options: .withoutUI,
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ) else { return nil }
                let didAccessScope = resolvedURL.startAccessingSecurityScopedResource()
                let refreshedBookmark: Data?
                if stale {
                    refreshedBookmark = try? resolvedURL.bookmarkData(
                        options: .minimalBookmark,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                } else {
                    refreshedBookmark = nil
                }
                return ResolvedInspectionRoot(
                    parentURL: resolvedURL,
                    didAccessScope: didAccessScope,
                    refreshedBookmark: refreshedBookmark
                )
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            // A recovery transition may have completed while bookmark
            // resolution was blocked. A same-root recovery may be relying on
            // this exact acquisition when its second start returned false, so
            // transfer ownership instead of withdrawing the only live scope.
            if Task.isCancelled || pendingRootTransition != nil || cachedRootURL != nil {
                if let result,
                   !adoptLateInspectionSecurityScopeIfNeeded(result) {
                    result.releaseSecurityScope()
                }
                throw CancellationError()
            }
            if let result {
                if result.didAccessScope {
                    activeSecurityScopedURL = result.parentURL
                }
                if let refreshedBookmark = result.refreshedBookmark {
                    userDefaults.set(refreshedBookmark, forKey: Constants.bookmarkKey)
                }
                return result.parentURL.appendingPathComponent(
                    Constants.libraryFolder,
                    isDirectory: true
                )
            }
        }
        return try defaultLibraryRoot()
    }

    private func adoptLateInspectionSecurityScopeIfNeeded(
        _ result: ResolvedInspectionRoot
    ) -> Bool {
        guard result.didAccessScope, activeSecurityScopedURL == nil else {
            return false
        }
        let resolvedRoot = result.parentURL.appendingPathComponent(
            Constants.libraryFolder,
            isDirectory: true
        ).standardizedFileURL
        let routedRoot = pendingRootTransition?.candidateRootURL.standardizedFileURL
            ?? cachedRootURL?.standardizedFileURL
        guard routedRoot == resolvedRoot else { return false }

        activeSecurityScopedURL = result.parentURL
        if var pending = pendingRootTransition,
           pending.candidateRootURL.standardizedFileURL == resolvedRoot {
            pending.candidateScopedURL = result.parentURL
            pending.candidateDidAccessScope = true
            pendingRootTransition = pending
        }
        return true
    }

    private func defaultLibraryRoot() throws -> URL {
        if let defaultDocumentsURLForTesting {
            return defaultDocumentsURLForTesting.appendingPathComponent(
                Constants.libraryFolder,
                isDirectory: true
            )
        }
        guard let documents = fileManager.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw StoreError.rootUnavailable
        }
        return documents.appendingPathComponent(
            Constants.libraryFolder,
            isDirectory: true
        )
    }

    private func loadOrCreateSessionTextNoteManifest(
        repository: FileNotebookRepository,
        request: SessionTextNoteRequest,
        normalizedTitle: String
    ) async throws -> NotebookManifest {
        let notebookID = NotebookID(request.notebookID)
        do {
            return try await repository.openNotebook(id: notebookID)
        } catch let repositoryError as NotebookRepositoryError {
            guard case .notebookNotFound(let missingID) = repositoryError,
                  missingID == notebookID else {
                throw repositoryError
            }
        }

        let initialPage = NotesCore.PageDescriptor(
            id: PageID(request.initialPageID),
            kind: .textDocument,
            createdAt: request.createdAt,
            modifiedAt: request.createdAt,
            size: NotesCore.PageSize(width: 768, height: 1_024),
            background: .plain(colorHex: "#FFFFFF")
        )
        do {
            return try await repository.createNotebook(
                id: notebookID,
                title: normalizedTitle,
                initialPage: initialPage,
                createdAt: request.createdAt
            )
        } catch {
            // Creation is a durable transaction whose response can still be
            // interrupted. Reopen the caller-owned identity before surfacing
            // the error so the next saga step never creates a second note.
            let creationError = error
            if let recovered = try? await repository.openNotebook(id: notebookID) {
                return recovered
            }
            throw creationError
        }
    }

    private func validateSessionTextNoteManifest(
        _ manifest: NotebookManifest,
        request: SessionTextNoteRequest
    ) throws {
        guard manifest.id == NotebookID(request.notebookID) else {
            throw SessionTextNoteStoreError.notebookConflict
        }
        guard let requestedPage = manifest.pages.first(where: {
            $0.id == PageID(request.initialPageID)
        }), requestedPage.kind == .textDocument else {
            throw SessionTextNoteStoreError.initialPageConflict
        }
    }

    private func validateSessionTextNoteMetadata(
        _ metadata: NotebookMetadata
    ) throws {
        guard metadata.kind == .textDocument,
              metadata.deletedAt == nil else {
            throw SessionTextNoteStoreError.metadataConflict
        }
    }

    private func makeCorePage(from page: EditorPage) -> NotesCore.PageDescriptor {
        NotesCore.PageDescriptor(
            id: PageID(page.id),
            kind: page.kind,
            modifiedAt: page.modifiedAt,
            size: NotesCore.PageSize(width: page.width, height: page.height),
            background: makeCoreBackground(from: page.background),
            isBookmarked: page.isBookmarked,
            outlineTitle: page.outlineTitle
        )
    }

    private func makeCoreBackground(from background: PageBackground) -> NotesCore.PageBackground {
        switch background {
        case let .paper(template):
            switch template {
            case .blank: .plain(colorHex: "#FFFFFF")
            case .ruled: .ruled(colorHex: "#FFFFFF", spacing: 28)
            case .grid: .grid(colorHex: "#FFFFFF", spacing: 28)
            case .dots: .dotted(colorHex: "#FFFFFF", spacing: 28)
            }
        case let .pdf(assetPath, pageIndex):
            .pdf(assetID: AssetID(assetPathURL(assetPath).lastPathComponent), pageIndex: pageIndex)
        case let .image(assetPath):
            .image(assetID: AssetID(assetPathURL(assetPath).lastPathComponent))
        }
    }

    private func makeEditorNotebook(from manifest: NotebookManifest, metadata: NotebookMetadata) -> EditorNotebook {
        EditorNotebook(
            id: manifest.id.rawValue,
            title: manifest.title,
            kind: metadata.kind,
            createdAt: manifest.createdAt,
            modifiedAt: manifest.modifiedAt,
            isFavorite: manifest.isFavorite,
            deletedAt: metadata.deletedAt,
            coverHue: metadata.coverHue,
            pages: manifest.pages.map(makeEditorPage)
        )
    }

    private func makeEditorPage(from page: NotesCore.PageDescriptor) -> EditorPage {
        let background: PageBackground
        switch page.background {
        case .plain:
            background = .paper(.blank)
        case .ruled:
            background = .paper(.ruled)
        case .grid:
            background = .paper(.grid)
        case .dotted:
            background = .paper(.dots)
        case let .pdf(assetID, pageIndex):
            background = .pdf(assetPath: "assets/\(assetID.rawValue)", pageIndex: pageIndex)
        case let .image(assetID), let .asset(assetID):
            background = .image(assetPath: "assets/\(assetID.rawValue)")
        }
        return EditorPage(
            id: page.id.rawValue,
            kind: page.kind,
            modifiedAt: page.modifiedAt,
            background: background,
            width: page.size.width,
            height: page.size.height,
            inkPath: "pages/\(page.id.description)/ink.data",
            isBookmarked: page.isBookmarked,
            outlineTitle: page.outlineTitle
        )
    }

    private func metadataEntry(for manifest: NotebookManifest, in metadata: LibraryMetadata) -> NotebookMetadata {
        if let entry = metadata.notebooks[manifest.id.description] { return entry }
        let inferredKind: NotebookKind
        if manifest.pages.contains(where: {
            if case .pdf = $0.background { return true }
            return false
        }) {
            inferredKind = .pdf
        } else if manifest.pages.contains(where: {
            switch $0.background {
            case .image, .asset: true
            default: false
            }
        }) {
            inferredKind = .image
        } else {
            inferredKind = switch manifest.pages.first?.kind {
            case .whiteboard: .whiteboard
            case .textDocument: .textDocument
            case .studySet: .studySet
            case .notebook, .importedDocument, nil: .notebook
            }
        }
        return NotebookMetadata(kind: inferredKind, deletedAt: nil, coverHue: Self.coverHue(for: manifest.id.rawValue))
    }

    private func loadMetadata() throws -> LibraryMetadata {
        let url = try libraryRoot().appendingPathComponent(Constants.metadataFile)
        return Self.readMetadata(at: url, fileManager: fileManager)
    }

    private static func readMetadata(
        at url: URL,
        fileManager: FileManager
    ) -> LibraryMetadata {
        guard fileManager.fileExists(atPath: url.path) else { return LibraryMetadata() }
        guard let data = try? Data(contentsOf: url) else { return LibraryMetadata() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(LibraryMetadata.self, from: data)) ?? LibraryMetadata()
    }

    private func saveMetadata(_ metadata: LibraryMetadata) throws {
        let root = try libraryRoot()
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try encoder.encode(metadata).write(
            to: root.appendingPathComponent(Constants.metadataFile),
            options: .atomic
        )
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func assetPathURL(_ path: String) -> URL {
        URL(fileURLWithPath: path)
    }

    private static func coverHue(for id: UUID) -> Double {
        let scalarSum = id.uuidString.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 1_000 }
        return Double(scalarSum) / 1_000
    }
}

extension LocalNotebookStore {
    enum StoreError: LocalizedError, Sendable {
        case rootUnavailable
        case rootTransitionInProgress
        case invalidRootTransition
        case unsupportedFile
        case unreadableDocument
        case invalidAssetPath
        case invalidNotebookPackage
        case duplicateNotebook

        var errorDescription: String? {
            switch self {
            case .rootUnavailable: String(localized: "The library folder is unavailable.")
            case .rootTransitionInProgress:
                String(localized: "Another library location change is already in progress.")
            case .invalidRootTransition:
                String(localized: "The library location change is no longer valid.")
            case .unsupportedFile: String(localized: "This file type is not supported.")
            case .unreadableDocument: String(localized: "This document could not be read.")
            case .invalidAssetPath: String(localized: "The document asset path is invalid.")
            case .invalidNotebookPackage: String(localized: "This NextStep notebook package is invalid or damaged.")
            case .duplicateNotebook: String(localized: "This notebook is already in the selected library.")
            }
        }
    }
}
