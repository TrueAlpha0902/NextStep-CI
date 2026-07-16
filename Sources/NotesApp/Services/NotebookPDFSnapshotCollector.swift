import Foundation
import NotesCore

struct NotebookPDFExportProgress: Equatable {
    let completedUnits: Int
    let totalUnits: Int

    var accessibilityValue: String {
        String.localizedStringWithFormat(
            String(localized: "%lld of %lld export steps complete"),
            Int64(completedUnits),
            Int64(totalUnits)
        )
    }
}

struct NotebookPDFEditorRevision: Equatable {
    let notebookID: UUID
    let notebookTitle: String
    let orderedPageIDs: [UUID]
    let pageIdentities: [NotebookPDFPageIdentity]
    let selectedPageID: UUID?
    let interactionGeneration: UInt64
}

/// Binds a single-page share to the exact editor load and mutation generation captured after its
/// pending writes were flushed. Page identity alone is insufficient for an A → B → A switch, and
/// the load identifier alone does not change when the user draws while an asset read is awaiting.
struct SinglePagePDFExportRevision: Equatable {
    let pageID: UUID
    let pageLoadID: UUID
    let interactionGeneration: UInt64

    func matches(
        selectedPageID: UUID?,
        pageLoadID: UUID,
        interactionGeneration: UInt64
    ) -> Bool {
        self.pageID == selectedPageID
            && self.pageLoadID == pageLoadID
            && self.interactionGeneration == interactionGeneration
    }
}

enum NotesExportTemporaryFile {
    static func removeOwned(_ url: URL, fileManager: FileManager = .default) {
        guard url.isFileURL,
              ["pdf", "md", "csv", "m4a", "txt", "srt"]
                .contains(url.pathExtension.lowercased()),
              (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return }
        let rawOwnedDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("NotesExports", isDirectory: true)
        guard (try? fileManager.destinationOfSymbolicLink(
            atPath: rawOwnedDirectory.path
        )) == nil,
        let directoryAttributes = try? fileManager.attributesOfItem(
            atPath: rawOwnedDirectory.path
        ),
        directoryAttributes[.type] as? FileAttributeType == .typeDirectory else { return }
        let ownedDirectory = rawOwnedDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL
        guard candidate.deletingLastPathComponent() == ownedDirectory else { return }
        try? fileManager.removeItem(at: candidate)
    }
}

@MainActor
enum SinglePagePDFExportPublication {
    static func validatedURL(
        _ url: URL,
        expectedRevision: SinglePagePDFExportRevision,
        currentRevision: () -> SinglePagePDFExportRevision?,
        fileManager: FileManager = .default
    ) -> URL? {
        guard currentRevision() == expectedRevision else {
            NotesExportTemporaryFile.removeOwned(url, fileManager: fileManager)
            return nil
        }
        return url
    }
}

struct NotebookPDFPageIdentity: Equatable {
    let id: UUID
    let kind: PageKind
    let background: PageBackground
    let width: Double
    let height: Double
    let inkPath: String

    init(page: EditorPage) {
        id = page.id
        kind = page.kind
        background = page.background
        width = page.width
        height = page.height
        inkPath = page.inkPath
    }
}

struct NotebookPDFPersistenceRevision: Equatable {
    let notebookID: UUID
    let notebookTitle: String
    let orderedPageIDs: [UUID]
    let pageIdentities: [NotebookPDFPageIdentity]
    let modifiedAt: Date

    init(notebook: EditorNotebook) {
        notebookID = notebook.id
        notebookTitle = notebook.title
        orderedPageIDs = notebook.pages.map(\.id)
        pageIdentities = notebook.pages.map(NotebookPDFPageIdentity.init)
        modifiedAt = notebook.modifiedAt
    }

    func matches(_ notebook: EditorNotebook) -> Bool {
        self == NotebookPDFPersistenceRevision(notebook: notebook)
    }
}

struct NotebookPDFSnapshotSourceBudget: Equatable {
    let maximumDrawingSourceBytes: Int64
    let maximumBackgroundSourceBytes: Int64
    let maximumElementSourceBytes: Int64

    init(
        maximumDrawingSourceBytes: Int64,
        maximumBackgroundSourceBytes: Int64,
        maximumElementSourceBytes: Int64 = 512 * 1_024 * 1_024
    ) {
        self.maximumDrawingSourceBytes = maximumDrawingSourceBytes
        self.maximumBackgroundSourceBytes = maximumBackgroundSourceBytes
        self.maximumElementSourceBytes = maximumElementSourceBytes
    }

    static let standard = NotebookPDFSnapshotSourceBudget(
        maximumDrawingSourceBytes: 2 * 1_024 * 1_024 * 1_024,
        maximumBackgroundSourceBytes: 8 * 1_024 * 1_024 * 1_024,
        maximumElementSourceBytes: 512 * 1_024 * 1_024
    )
}

enum NotebookPDFSnapshotCollectionError: LocalizedError, Equatable {
    case flushFailed
    case staleEditorState
    case notebookUnavailable
    case unsupportedPage(pageNumber: Int)
    case inkUnavailable(pageNumber: Int)
    case drawingDataLimitExceeded(pageNumber: Int, limit: Int)
    case corruptDrawingData(pageNumber: Int)
    case drawingComplexityLimitExceeded(
        pageNumber: Int,
        maximumStrokeCount: Int,
        maximumPointCount: Int
    )
    case pageElementLimitExceeded(pageNumber: Int, limit: Int)
    case pageElementsUnavailable(pageNumber: Int)
    case backgroundAssetUnavailable(pageNumber: Int)
    case backgroundAssetLimitExceeded(pageNumber: Int, limit: Int)
    case corruptBackgroundAsset(pageNumber: Int)
    case backgroundPDFPageOutOfRange(pageNumber: Int, backgroundPageIndex: Int)
    case referencedAssetsUnavailable(pageNumber: Int)
    case sourceWorkLimitExceeded

    var errorDescription: String? {
        switch self {
        case .flushFailed:
            String(localized: "Save every pending edit before exporting the notebook.")
        case .staleEditorState:
            String(localized: "The notebook changed while its PDF was being prepared. Try again.")
        case .notebookUnavailable:
            String(localized: "The saved notebook could not be opened for PDF export.")
        case .unsupportedPage(let pageNumber):
            String.localizedStringWithFormat(
                String(localized: "Page %lld cannot be included in a notebook PDF."),
                Int64(pageNumber)
            )
        case .inkUnavailable(let pageNumber):
            String.localizedStringWithFormat(
                String(localized: "The ink on page %lld could not be opened for PDF export."),
                Int64(pageNumber)
            )
        case .drawingDataLimitExceeded(let pageNumber, let limit):
            String.localizedStringWithFormat(
                String(localized: "The ink on page %1$lld exceeds the %2$lld MB PDF export limit."),
                Int64(pageNumber),
                Int64(limit / 1_024 / 1_024)
            )
        case .corruptDrawingData(let pageNumber):
            String.localizedStringWithFormat(
                String(localized: "The ink data on page %lld is damaged and cannot be exported."),
                Int64(pageNumber)
            )
        case .drawingComplexityLimitExceeded(let pageNumber, _, _):
            String.localizedStringWithFormat(
                String(localized: "The ink on page %lld is too complex to export safely."),
                Int64(pageNumber)
            )
        case .pageElementLimitExceeded(let pageNumber, let limit):
            String.localizedStringWithFormat(
                String(localized: "Page %1$lld has more than %2$lld elements and cannot be exported."),
                Int64(pageNumber),
                Int64(limit)
            )
        case .pageElementsUnavailable(let pageNumber):
            String.localizedStringWithFormat(
                String(localized: "The elements on page %lld could not be opened for PDF export."),
                Int64(pageNumber)
            )
        case .backgroundAssetUnavailable(let pageNumber):
            String.localizedStringWithFormat(
                String(localized: "The background file on page %lld is missing or unsafe."),
                Int64(pageNumber)
            )
        case .backgroundAssetLimitExceeded(let pageNumber, let limit):
            String.localizedStringWithFormat(
                String(localized: "The background file on page %1$lld exceeds the %2$lld MB PDF export limit."),
                Int64(pageNumber),
                Int64(limit / 1_024 / 1_024)
            )
        case .corruptBackgroundAsset(let pageNumber):
            String.localizedStringWithFormat(
                String(localized: "The background file on page %lld is damaged or unsupported."),
                Int64(pageNumber)
            )
        case .backgroundPDFPageOutOfRange(let pageNumber, _):
            String.localizedStringWithFormat(
                String(localized: "The selected PDF background for page %lld is unavailable."),
                Int64(pageNumber)
            )
        case .referencedAssetsUnavailable(let pageNumber):
            String.localizedStringWithFormat(
                String(localized: "An image on page %lld could not be opened for PDF export."),
                Int64(pageNumber)
            )
        case .sourceWorkLimitExceeded:
            String(localized: "This notebook PDF is too large to export safely.")
        }
    }
}

@MainActor
struct NotebookPDFSnapshotDependencies {
    let flushAllPendingWrites: () async -> Bool
    let beginExportSession: (UUID) async throws -> NotesAppNotebookExportSession
    let validateExportSession:
        (NotesAppNotebookExportSession) async throws -> EditorNotebook
    let endExportSession: (NotesAppNotebookExportSession) async -> Void
    let loadInk: (NotesAppNotebookExportSession, EditorPage) async throws -> Data?
    let loadCanvasElements:
        (NotesAppNotebookExportSession, UUID) async throws -> NotebookExportCanvasElements
    let resolveBackground:
        (NotesAppNotebookExportSession, EditorPage) async throws -> ResolvedPageBackground
    let loadCanvasAssets:
        (NotesAppNotebookExportSession, [AssetID]) async throws -> [AssetID: Data]

    /// Compatibility initializer for focused collector tests and in-memory stores. Production
    /// filesystem export uses the session-aware initializer below.
    init(
        flushAllPendingWrites: @escaping () async -> Bool,
        loadNotebook: @escaping (UUID) async throws -> EditorNotebook?,
        loadInk: @escaping (UUID, EditorPage) async throws -> Data?,
        loadCanvasElements: @escaping (UUID, UUID) async throws -> [CanvasElement],
        resolveBackground: @escaping (UUID, EditorPage) async throws -> ResolvedPageBackground,
        loadCanvasAssets: @escaping (UUID, [AssetID]) async throws -> [AssetID: Data]
    ) {
        self.flushAllPendingWrites = flushAllPendingWrites
        beginExportSession = { notebookID in
            guard let notebook = try await loadNotebook(notebookID) else {
                throw NotebookPDFSnapshotCollectionError.notebookUnavailable
            }
            return NotesAppNotebookExportSession(
                token: NotebookExportSession(notebookID: NotebookID(notebookID)),
                notebook: notebook
            )
        }
        validateExportSession = { session in
            guard let notebook = try await loadNotebook(session.notebook.id) else {
                throw NotebookPDFSnapshotCollectionError.notebookUnavailable
            }
            return notebook
        }
        endExportSession = { _ in }
        self.loadInk = { session, page in
            try await loadInk(session.notebook.id, page)
        }
        self.loadCanvasElements = { session, pageID in
            let elements = try await loadCanvasElements(session.notebook.id, pageID)
            return NotebookExportCanvasElements(
                elements: elements,
                encodedByteCount: try JSONEncoder().encode(elements).count
            )
        }
        self.resolveBackground = { session, page in
            try await resolveBackground(session.notebook.id, page)
        }
        self.loadCanvasAssets = { session, assetIDs in
            try await loadCanvasAssets(session.notebook.id, assetIDs)
        }
    }

    init(
        flushAllPendingWrites: @escaping () async -> Bool,
        beginExportSession: @escaping (UUID) async throws -> NotesAppNotebookExportSession,
        validateExportSession:
            @escaping (NotesAppNotebookExportSession) async throws -> EditorNotebook,
        endExportSession: @escaping (NotesAppNotebookExportSession) async -> Void,
        loadInk:
            @escaping (NotesAppNotebookExportSession, EditorPage) async throws -> Data?,
        loadCanvasElements:
            @escaping (NotesAppNotebookExportSession, UUID) async throws
                -> NotebookExportCanvasElements,
        resolveBackground:
            @escaping (NotesAppNotebookExportSession, EditorPage) async throws
                -> ResolvedPageBackground,
        loadCanvasAssets:
            @escaping (NotesAppNotebookExportSession, [AssetID]) async throws
                -> [AssetID: Data]
    ) {
        self.flushAllPendingWrites = flushAllPendingWrites
        self.beginExportSession = beginExportSession
        self.validateExportSession = validateExportSession
        self.endExportSession = endExportSession
        self.loadInk = loadInk
        self.loadCanvasElements = loadCanvasElements
        self.resolveBackground = resolveBackground
        self.loadCanvasAssets = loadCanvasAssets
    }
}

@MainActor
struct SinglePagePDFSnapshotDependencies {
    let loadInk: (UUID, EditorPage) async throws -> Data?
    let loadCanvasElements: (UUID, UUID) async throws -> [CanvasElement]
    let resolveBackground: (UUID, EditorPage) async throws -> ResolvedPageBackground
    let loadCanvasAssets: (UUID, [AssetID]) async throws -> [AssetID: Data]
}

@MainActor
enum NotebookPDFSnapshotCollector {
    /// A notebook can contain up to 2,000 pages. Keep the cumulative compressed-image work
    /// bounded as well as each streaming page, so a crafted notebook cannot request hundreds of
    /// gigabytes of otherwise individually valid image parsing during one export.
    static let maximumTotalCanvasAssetSourceBytes: Int64 = 8 * 1_024 * 1_024 * 1_024

    /// Reopens one flushed page through the same bounded persistence APIs used by whole-notebook
    /// export. Interactive editor recovery values are deliberately not accepted as inputs.
    static func collectSinglePage(
        notebookID: UUID,
        page: EditorPage,
        expectedRevision: SinglePagePDFExportRevision,
        currentRevision: () -> SinglePagePDFExportRevision?,
        dependencies: SinglePagePDFSnapshotDependencies
    ) async throws -> NotebookPDFPageSnapshot {
        let pageNumber = 1
        try validate(expectedRevision, currentRevision: currentRevision)

        let drawingData: Data?
        do {
            drawingData = try await dependencies.loadInk(notebookID, page)
        } catch let error as CancellationError {
            throw error
        } catch NotebookRepositoryError.boundedReadLimitExceeded(_, let limit) {
            throw NotebookPDFSnapshotCollectionError.drawingDataLimitExceeded(
                pageNumber: pageNumber,
                limit: limit
            )
        } catch {
            throw NotebookPDFSnapshotCollectionError.inkUnavailable(pageNumber: pageNumber)
        }
        try validate(expectedRevision, currentRevision: currentRevision)

        let preparedDrawing: PageExportPreparedDrawing
        do {
            preparedDrawing = try PageExportRenderer.prepareDrawing(drawingData)
        } catch let error as PageExportRenderError {
            switch error {
            case .drawingDataLimitExceeded(let limit):
                throw NotebookPDFSnapshotCollectionError.drawingDataLimitExceeded(
                    pageNumber: pageNumber,
                    limit: limit
                )
            case .corruptDrawingData:
                throw NotebookPDFSnapshotCollectionError.corruptDrawingData(
                    pageNumber: pageNumber
                )
            case .drawingComplexityLimitExceeded(
                let maximumStrokeCount,
                let maximumPointCount
            ):
                throw NotebookPDFSnapshotCollectionError.drawingComplexityLimitExceeded(
                    pageNumber: pageNumber,
                    maximumStrokeCount: maximumStrokeCount,
                    maximumPointCount: maximumPointCount
                )
            case .pageElementLimitExceeded(let limit):
                throw NotebookPDFSnapshotCollectionError.pageElementLimitExceeded(
                    pageNumber: pageNumber,
                    limit: limit
                )
            case .backgroundAssetUnavailable,
                 .backgroundAssetLimitExceeded,
                 .corruptBackgroundAsset,
                 .backgroundPDFPageOutOfRange:
                throw error
            }
        }
        try validate(expectedRevision, currentRevision: currentRevision)

        let elements: [CanvasElement]
        do {
            elements = try await dependencies.loadCanvasElements(notebookID, page.id)
        } catch let error as CancellationError {
            throw error
        } catch NotebookRepositoryError.canvasElementLimitExceeded(let limit) {
            throw NotebookPDFSnapshotCollectionError.pageElementLimitExceeded(
                pageNumber: pageNumber,
                limit: limit
            )
        } catch {
            throw NotebookPDFSnapshotCollectionError.pageElementsUnavailable(
                pageNumber: pageNumber
            )
        }
        try validate(expectedRevision, currentRevision: currentRevision)
        guard elements.count <= CanvasElementExportRenderer.maximumElementCount else {
            throw NotebookPDFSnapshotCollectionError.pageElementLimitExceeded(
                pageNumber: pageNumber,
                limit: CanvasElementExportRenderer.maximumElementCount
            )
        }

        let background: ResolvedPageBackground
        do {
            background = try await dependencies.resolveBackground(notebookID, page)
        } catch let error as CancellationError {
            throw error
        } catch NotebookRepositoryError.boundedReadLimitExceeded(_, let limit) {
            throw NotebookPDFSnapshotCollectionError.backgroundAssetLimitExceeded(
                pageNumber: pageNumber,
                limit: limit
            )
        } catch {
            throw NotebookPDFSnapshotCollectionError.backgroundAssetUnavailable(
                pageNumber: pageNumber
            )
        }
        try validate(expectedRevision, currentRevision: currentRevision)

        let plan = PageExportRenderer.renderPlan(for: page)
        let preparedBackground: PageExportPreparedBackground
        do {
            preparedBackground = try PageExportRenderer.prepareBackground(
                background,
                for: page,
                outputPixelSize: plan.drawingRasterPixelSize
            )
        } catch let error as PageExportRenderError {
            switch error {
            case .backgroundAssetUnavailable:
                throw NotebookPDFSnapshotCollectionError.backgroundAssetUnavailable(
                    pageNumber: pageNumber
                )
            case .backgroundAssetLimitExceeded(let limit):
                throw NotebookPDFSnapshotCollectionError.backgroundAssetLimitExceeded(
                    pageNumber: pageNumber,
                    limit: limit
                )
            case .corruptBackgroundAsset:
                throw NotebookPDFSnapshotCollectionError.corruptBackgroundAsset(
                    pageNumber: pageNumber
                )
            case .backgroundPDFPageOutOfRange(let backgroundPageIndex):
                throw NotebookPDFSnapshotCollectionError.backgroundPDFPageOutOfRange(
                    pageNumber: pageNumber,
                    backgroundPageIndex: backgroundPageIndex
                )
            case .drawingDataLimitExceeded,
                 .corruptDrawingData,
                 .drawingComplexityLimitExceeded,
                 .pageElementLimitExceeded:
                throw error
            }
        }
        try validate(expectedRevision, currentRevision: currentRevision)

        let referencedAssetIDs = CanvasElementExportRenderer.assetIDsForExport(
            elements: elements,
            sourceBounds: plan.sourceBounds
        )
        let assetData: [AssetID: Data]
        if referencedAssetIDs.isEmpty {
            assetData = [:]
        } else {
            do {
                assetData = try await dependencies.loadCanvasAssets(
                    notebookID,
                    referencedAssetIDs
                )
            } catch let error as CancellationError {
                throw error
            } catch {
                throw NotebookPDFSnapshotCollectionError.referencedAssetsUnavailable(
                    pageNumber: pageNumber
                )
            }
            try validate(expectedRevision, currentRevision: currentRevision)
        }
        guard let resolver = assetImageResolver(
            dataByAssetID: assetData,
            expectedAssetIDs: referencedAssetIDs
        ) else {
            throw NotebookPDFSnapshotCollectionError.referencedAssetsUnavailable(
                pageNumber: pageNumber
            )
        }
        try validate(expectedRevision, currentRevision: currentRevision)

        return NotebookPDFPageSnapshot(
            page: page,
            background: ResolvedPageBackground(
                background: background.background,
                assetURL: nil,
                assetData: nil
            ),
            preparedBackground: preparedBackground,
            drawingData: nil,
            preparedDrawing: preparedDrawing,
            canvasElements: elements,
            assetImageResolver: resolver
        )
    }

    static func collect(
        notebook: EditorNotebook,
        expectedRevision: NotebookPDFEditorRevision,
        currentRevision: () -> NotebookPDFEditorRevision?,
        dependencies: NotebookPDFSnapshotDependencies,
        sourceBudget: NotebookPDFSnapshotSourceBudget = .standard,
        progress: (NotebookPDFExportProgress) -> Void = { _ in }
    ) async throws -> [NotebookPDFPageSnapshot] {
        var snapshots = [NotebookPDFPageSnapshot]()
        snapshots.reserveCapacity(notebook.pages.count)
        _ = try await collectEach(
            notebook: notebook,
            expectedRevision: expectedRevision,
            currentRevision: currentRevision,
            dependencies: dependencies,
            sourceBudget: sourceBudget,
            progress: progress,
            consume: { snapshot, _, _ in
                snapshots.append(snapshot)
            }
        )
        return snapshots
    }

    /// Loads and validates one persisted page at a time. The consumer must finish using the
    /// snapshot before returning; the editor uses this to render a protected page artifact
    /// immediately, so no array of every page's ink and structured elements is retained.
    @discardableResult
    static func collectEach(
        notebook: EditorNotebook,
        expectedRevision: NotebookPDFEditorRevision,
        currentRevision: () -> NotebookPDFEditorRevision?,
        dependencies: NotebookPDFSnapshotDependencies,
        sourceBudget: NotebookPDFSnapshotSourceBudget = .standard,
        progress: (NotebookPDFExportProgress) -> Void = { _ in },
        consume: @MainActor (NotebookPDFPageSnapshot, Int, Int) async throws -> Void
    ) async throws -> NotebookPDFPersistenceRevision {
        try validate(expectedRevision, currentRevision: currentRevision)
        guard sourceBudget.maximumDrawingSourceBytes >= 0,
              sourceBudget.maximumBackgroundSourceBytes >= 0,
              sourceBudget.maximumElementSourceBytes >= 0 else {
            throw NotebookPDFSnapshotCollectionError.sourceWorkLimitExceeded
        }
        guard expectedRevision.notebookID == notebook.id,
              expectedRevision.notebookTitle == notebook.title,
              expectedRevision.orderedPageIDs == notebook.pages.map(\.id),
              expectedRevision.pageIdentities == notebook.pages.map(NotebookPDFPageIdentity.init) else {
            throw NotebookPDFSnapshotCollectionError.staleEditorState
        }
        for (index, page) in notebook.pages.enumerated() {
            guard isSupported(page.kind) else {
                throw NotebookPDFSnapshotCollectionError.unsupportedPage(pageNumber: index + 1)
            }
        }

        let didFlush = await dependencies.flushAllPendingWrites()
        try validate(expectedRevision, currentRevision: currentRevision)
        guard didFlush else {
            throw NotebookPDFSnapshotCollectionError.flushFailed
        }

        let exportSession: NotesAppNotebookExportSession
        do {
            exportSession = try await dependencies.beginExportSession(notebook.id)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw NotebookPDFSnapshotCollectionError.notebookUnavailable
        }
        do {
            try validate(expectedRevision, currentRevision: currentRevision)
            let savedNotebook = exportSession.notebook
            try validateNotebook(savedNotebook, expectedRevision: expectedRevision)

            progress(NotebookPDFExportProgress(completedUnits: 0, totalUnits: savedNotebook.pages.count))
            var totalDrawingSourceBytes: Int64 = 0
            var totalBackgroundSourceBytes: Int64 = 0
            var totalElementSourceBytes: Int64 = 0
            var totalCanvasAssetSourceBytes: Int64 = 0

            for (index, page) in savedNotebook.pages.enumerated() {
            try validate(expectedRevision, currentRevision: currentRevision)
            let drawingData: Data?
            do {
                drawingData = try await dependencies.loadInk(exportSession, page)
            } catch let error as CancellationError {
                throw error
            } catch NotebookRepositoryError.boundedReadLimitExceeded(_, let limit) {
                throw NotebookPDFSnapshotCollectionError.drawingDataLimitExceeded(
                    pageNumber: index + 1,
                    limit: limit
                )
            } catch {
                throw NotebookPDFSnapshotCollectionError.inkUnavailable(
                    pageNumber: index + 1
                )
            }
            try validate(expectedRevision, currentRevision: currentRevision)
            let drawingSourceBytes = Int64(drawingData?.count ?? 0)
            guard drawingSourceBytes <= sourceBudget.maximumDrawingSourceBytes,
                  totalDrawingSourceBytes
                    <= sourceBudget.maximumDrawingSourceBytes - drawingSourceBytes else {
                throw NotebookPDFSnapshotCollectionError.sourceWorkLimitExceeded
            }
            totalDrawingSourceBytes += drawingSourceBytes
            let preparedDrawing: PageExportPreparedDrawing
            do {
                preparedDrawing = try PageExportRenderer.prepareDrawing(drawingData)
            } catch let error as PageExportRenderError {
                switch error {
                case .drawingDataLimitExceeded(let limit):
                    throw NotebookPDFSnapshotCollectionError.drawingDataLimitExceeded(
                        pageNumber: index + 1,
                        limit: limit
                    )
                case .corruptDrawingData:
                    throw NotebookPDFSnapshotCollectionError.corruptDrawingData(
                        pageNumber: index + 1
                    )
                case .drawingComplexityLimitExceeded(
                    let maximumStrokeCount,
                    let maximumPointCount
                ):
                    throw NotebookPDFSnapshotCollectionError.drawingComplexityLimitExceeded(
                        pageNumber: index + 1,
                        maximumStrokeCount: maximumStrokeCount,
                        maximumPointCount: maximumPointCount
                    )
                case .pageElementLimitExceeded(let limit):
                    throw NotebookPDFSnapshotCollectionError.pageElementLimitExceeded(
                        pageNumber: index + 1,
                        limit: limit
                    )
                case .backgroundAssetUnavailable:
                    throw NotebookPDFSnapshotCollectionError.backgroundAssetUnavailable(
                        pageNumber: index + 1
                    )
                case .backgroundAssetLimitExceeded(let limit):
                    throw NotebookPDFSnapshotCollectionError.backgroundAssetLimitExceeded(
                        pageNumber: index + 1,
                        limit: limit
                    )
                case .corruptBackgroundAsset:
                    throw NotebookPDFSnapshotCollectionError.corruptBackgroundAsset(
                        pageNumber: index + 1
                    )
                case .backgroundPDFPageOutOfRange(let backgroundPageIndex):
                    throw NotebookPDFSnapshotCollectionError.backgroundPDFPageOutOfRange(
                        pageNumber: index + 1,
                        backgroundPageIndex: backgroundPageIndex
                    )
                }
            }
            try validate(expectedRevision, currentRevision: currentRevision)

            let loadedElements: NotebookExportCanvasElements
            do {
                loadedElements = try await dependencies.loadCanvasElements(
                    exportSession,
                    page.id
                )
            } catch let error as CancellationError {
                throw error
            } catch NotebookRepositoryError.canvasElementLimitExceeded(let limit) {
                throw NotebookPDFSnapshotCollectionError.pageElementLimitExceeded(
                    pageNumber: index + 1,
                    limit: limit
                )
            } catch {
                throw NotebookPDFSnapshotCollectionError.pageElementsUnavailable(
                    pageNumber: index + 1
                )
            }
            guard let elementSourceBytes = Int64(exactly: loadedElements.encodedByteCount),
                  elementSourceBytes >= 0,
                  elementSourceBytes <= sourceBudget.maximumElementSourceBytes,
                  totalElementSourceBytes
                    <= sourceBudget.maximumElementSourceBytes - elementSourceBytes else {
                throw NotebookPDFSnapshotCollectionError.sourceWorkLimitExceeded
            }
            totalElementSourceBytes += elementSourceBytes
            let elements = loadedElements.elements
            try validate(expectedRevision, currentRevision: currentRevision)
            guard elements.count <= CanvasElementExportRenderer.maximumElementCount else {
                throw NotebookPDFSnapshotCollectionError.pageElementLimitExceeded(
                    pageNumber: index + 1,
                    limit: CanvasElementExportRenderer.maximumElementCount
                )
            }

            let background: ResolvedPageBackground
            do {
                background = try await dependencies.resolveBackground(exportSession, page)
            } catch let error as CancellationError {
                throw error
            } catch NotebookRepositoryError.boundedReadLimitExceeded(_, let limit) {
                throw NotebookPDFSnapshotCollectionError.backgroundAssetLimitExceeded(
                    pageNumber: index + 1,
                    limit: limit
                )
            } catch {
                throw NotebookPDFSnapshotCollectionError.backgroundAssetUnavailable(
                    pageNumber: index + 1
                )
            }
            try validate(expectedRevision, currentRevision: currentRevision)
            let backgroundSourceBytes = Int64(background.assetData?.count ?? 0)
            guard backgroundSourceBytes <= sourceBudget.maximumBackgroundSourceBytes,
                  totalBackgroundSourceBytes
                    <= sourceBudget.maximumBackgroundSourceBytes - backgroundSourceBytes else {
                throw NotebookPDFSnapshotCollectionError.sourceWorkLimitExceeded
            }
            totalBackgroundSourceBytes += backgroundSourceBytes
            let preparedBackground: PageExportPreparedBackground
            do {
                let plan = PageExportRenderer.renderPlan(for: page)
                preparedBackground = try PageExportRenderer.prepareBackground(
                    background,
                    for: page,
                    outputPixelSize: plan.drawingRasterPixelSize
                )
            } catch let error as PageExportRenderError {
                switch error {
                case .backgroundAssetUnavailable:
                    throw NotebookPDFSnapshotCollectionError.backgroundAssetUnavailable(
                        pageNumber: index + 1
                    )
                case .backgroundAssetLimitExceeded(let limit):
                    throw NotebookPDFSnapshotCollectionError.backgroundAssetLimitExceeded(
                        pageNumber: index + 1,
                        limit: limit
                    )
                case .corruptBackgroundAsset:
                    throw NotebookPDFSnapshotCollectionError.corruptBackgroundAsset(
                        pageNumber: index + 1
                    )
                case .backgroundPDFPageOutOfRange(let backgroundPageIndex):
                    throw NotebookPDFSnapshotCollectionError.backgroundPDFPageOutOfRange(
                        pageNumber: index + 1,
                        backgroundPageIndex: backgroundPageIndex
                    )
                case .drawingDataLimitExceeded,
                     .corruptDrawingData,
                     .drawingComplexityLimitExceeded,
                     .pageElementLimitExceeded:
                    throw error
                }
            }
            try validate(expectedRevision, currentRevision: currentRevision)

            let referencedAssetIDs = CanvasElementExportRenderer.assetIDsForExport(
                elements: elements,
                sourceBounds: PageExportRenderer.renderPlan(for: page).sourceBounds
            )
            let assetData: [AssetID: Data]
            if referencedAssetIDs.isEmpty {
                assetData = [:]
            } else {
                do {
                    assetData = try await dependencies.loadCanvasAssets(
                        exportSession,
                        referencedAssetIDs
                    )
                } catch let error as CancellationError {
                    throw error
                } catch {
                    throw NotebookPDFSnapshotCollectionError.referencedAssetsUnavailable(
                        pageNumber: index + 1
                    )
                }
                try validate(expectedRevision, currentRevision: currentRevision)
            }
            guard let assetImageResolver = assetImageResolver(
                dataByAssetID: assetData,
                expectedAssetIDs: referencedAssetIDs
            ) else {
                throw NotebookPDFSnapshotCollectionError.referencedAssetsUnavailable(
                    pageNumber: index + 1
                )
            }
            let pageAssetSourceBytes = assetData.values.reduce(into: Int64(0)) {
                $0 += Int64($1.count)
            }
            guard totalCanvasAssetSourceBytes
                    <= maximumTotalCanvasAssetSourceBytes - pageAssetSourceBytes else {
                throw NotebookPDFSnapshotCollectionError.referencedAssetsUnavailable(
                    pageNumber: index + 1
                )
            }
            totalCanvasAssetSourceBytes += pageAssetSourceBytes

            let snapshot = NotebookPDFPageSnapshot(
                page: page,
                // The decoded background owns everything rendering needs. Drop the source
                // buffer from the streaming snapshot so an image page does not retain both its
                // compressed asset and decoded raster while its artifact is written.
                background: ResolvedPageBackground(
                    background: background.background,
                    assetURL: nil,
                    assetData: nil
                ),
                preparedBackground: preparedBackground,
                drawingData: nil,
                preparedDrawing: preparedDrawing,
                canvasElements: elements,
                assetImageResolver: assetImageResolver
            )
            try await consume(snapshot, index, savedNotebook.pages.count)
            try validate(expectedRevision, currentRevision: currentRevision)
            progress(
                NotebookPDFExportProgress(
                    completedUnits: index + 1,
                    totalUnits: savedNotebook.pages.count
                )
            )
            }

            try validate(expectedRevision, currentRevision: currentRevision)
            let finalNotebook: EditorNotebook
            do {
                finalNotebook = try await dependencies.validateExportSession(exportSession)
            } catch let error as CancellationError {
                throw error
            } catch {
                throw NotebookPDFSnapshotCollectionError.staleEditorState
            }
            try validate(expectedRevision, currentRevision: currentRevision)
            try validateNotebook(finalNotebook, expectedRevision: expectedRevision)
            guard finalNotebook.modifiedAt == savedNotebook.modifiedAt else {
                throw NotebookPDFSnapshotCollectionError.staleEditorState
            }
            let revision = NotebookPDFPersistenceRevision(notebook: finalNotebook)
            await dependencies.endExportSession(exportSession)
            return revision
        } catch {
            await dependencies.endExportSession(exportSession)
            throw error
        }
    }

    static func assetImageResolver(
        dataByAssetID: [AssetID: Data],
        expectedAssetIDs: [AssetID]
    ) -> CanvasElementExportImageResolver? {
        guard validateCanvasAssetData(
            dataByAssetID,
            expectedAssetIDs: expectedAssetIDs
        ) else { return nil }
        // Persistence failures are handled before this closure is created. A digest-verified but
        // unsupported/corrupt image codec remains a visible missing-image placeholder.
        return { assetID, request in
            guard !Task.isCancelled,
                  let data = dataByAssetID[assetID],
                  let image = PageAssetImageLoader.thumbnail(
                    data: data,
                    maximumPixelDimension: request.maximumPixelDimension
                  ),
                  request.accepts(image) else {
                return nil
            }
            return image
        }
    }

    private static func validateCanvasAssetData(
        _ dataByAssetID: [AssetID: Data],
        expectedAssetIDs: [AssetID]
    ) -> Bool {
        guard expectedAssetIDs.count
                <= NotebookExportReadLimits.maximumCanvasAssetResolutionAttempts,
              Set(expectedAssetIDs).count == expectedAssetIDs.count,
              Set(dataByAssetID.keys) == Set(expectedAssetIDs) else {
            return false
        }
        var totalBytes = 0
        for data in dataByAssetID.values {
            guard data.count <= NotebookExportReadLimits.maximumCanvasAssetSourceBytes,
                  totalBytes <= NotebookExportReadLimits.maximumCanvasAssetSourceBytesPerPage
                    - data.count else {
                return false
            }
            totalBytes += data.count
        }
        return true
    }

    private static func validate(
        _ expectedRevision: NotebookPDFEditorRevision,
        currentRevision: () -> NotebookPDFEditorRevision?
    ) throws {
        try Task.checkCancellation()
        guard currentRevision() == expectedRevision else {
            throw NotebookPDFSnapshotCollectionError.staleEditorState
        }
    }

    private static func validate(
        _ expectedRevision: SinglePagePDFExportRevision,
        currentRevision: () -> SinglePagePDFExportRevision?
    ) throws {
        try Task.checkCancellation()
        guard currentRevision() == expectedRevision else {
            throw NotebookPDFSnapshotCollectionError.staleEditorState
        }
    }

    private static func validateNotebook(
        _ notebook: EditorNotebook,
        expectedRevision: NotebookPDFEditorRevision
    ) throws {
        guard notebook.id == expectedRevision.notebookID,
              notebook.title == expectedRevision.notebookTitle,
              notebook.pages.map(\.id) == expectedRevision.orderedPageIDs,
              notebook.pages.map(NotebookPDFPageIdentity.init)
                == expectedRevision.pageIdentities else {
            throw NotebookPDFSnapshotCollectionError.staleEditorState
        }
    }

    private static func isSupported(_ kind: PageKind) -> Bool {
        switch kind {
        case .notebook, .whiteboard, .importedDocument:
            true
        case .textDocument, .studySet:
            false
        }
    }
}
