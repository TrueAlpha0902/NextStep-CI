import Foundation
import Darwin

enum StorageFailurePoint: Equatable, Sendable {
    case beforeStateWrite(relativePath: String)
    case beforeTransactionPhaseWrite
    case beforeOperationLogWrite
    /// Test-only observation point used to deterministically exercise source
    /// mutation and cooperative cancellation during a streaming audio ingest.
    case duringAudioSourceCopy(bytesCopied: Int64)
    case afterAudioSourceStaged
    /// Test-only observation point for deterministic mutation/cancellation coverage of the
    /// shared descriptor-bounded content reader.
    case duringBoundedContentRead(relativePath: String, bytesRead: Int)
    /// Test-only observation point for cooperative cancellation while hashing an owned export
    /// asset after its descriptor-bounded read has completed.
    case duringExportAssetDigest(relativePath: String, bytesHashed: Int)
    /// Test-only observation proving a session performs one bounded manifest body decode.
    case afterBoundedExportManifestDecode(notebookID: NotebookID)
}

/// The stable on-disk layout of a `.notepkg` document package.
public struct NotebookPackageLayout: Sendable {
    public static let packageExtension = "notepkg"
    public static let handwritingRecognitionFilename = "handwriting-recognition.json"

    public let packageURL: URL

    public init(packageURL: URL) {
        self.packageURL = packageURL
    }

    public var manifestURL: URL { packageURL.appendingPathComponent("manifest.json", isDirectory: false) }
    public var backupManifestURL: URL { packageURL.appendingPathComponent("manifest.backup.json", isDirectory: false) }
    public var pagesURL: URL { packageURL.appendingPathComponent("pages", isDirectory: true) }
    public var operationsURL: URL { packageURL.appendingPathComponent("ops/local", isDirectory: true) }
    public var transactionsURL: URL { packageURL.appendingPathComponent("ops/transactions", isDirectory: true) }
    public var assetsURL: URL { packageURL.appendingPathComponent("assets", isDirectory: true) }
    public var audioURL: URL { packageURL.appendingPathComponent("audio", isDirectory: true) }
    public var derivedURL: URL { packageURL.appendingPathComponent("derived", isDirectory: true) }

    public func pageURL(_ pageID: PageID) -> URL {
        pagesURL.appendingPathComponent(pageID.description, isDirectory: true)
    }

    public func pageDescriptorURL(_ pageID: PageID) -> URL {
        pageURL(pageID).appendingPathComponent("page.json", isDirectory: false)
    }

    public func inkURL(_ pageID: PageID) -> URL {
        pageURL(pageID).appendingPathComponent("ink.data", isDirectory: false)
    }

    public func elementsURL(_ pageID: PageID) -> URL {
        pageURL(pageID).appendingPathComponent("elements.json", isDirectory: false)
    }

    public func contentURL(_ pageID: PageID) -> URL {
        pageURL(pageID).appendingPathComponent("content.json", isDirectory: false)
    }

    public func handwritingRecognitionURL(_ pageID: PageID) -> URL {
        pageURL(pageID).appendingPathComponent(
            Self.handwritingRecognitionFilename,
            isDirectory: false
        )
    }

    public func assetURL(_ assetID: AssetID) -> URL {
        let filename = assetID.isSHA256Digest
            ? assetID.rawValue
            : "invalid-\(SHA256.hexDigest(Data(assetID.rawValue.utf8)))"
        return assetsURL.appendingPathComponent(filename, isDirectory: false)
    }

    public func audioSessionURL(_ sessionID: AudioSessionID) -> URL {
        audioURL.appendingPathComponent("\(sessionID.description).m4a", isDirectory: false)
    }

    public func audioTimelineURL(_ sessionID: AudioSessionID) -> URL {
        audioURL.appendingPathComponent("\(sessionID.description).timeline.json", isDirectory: false)
    }

    public func audioReplayHistoryURL(_ sessionID: AudioSessionID) -> URL {
        audioURL.appendingPathComponent("\(sessionID.description).replay.json", isDirectory: false)
    }
}

/// A local, actor-isolated repository. The actor is the only writer for a library,
/// while every durable update uses a temporary sibling followed by an atomic replace.
public actor FileNotebookRepository: NotebookRepository, TextDocumentSourceSnapshotProviding {
    public nonisolated let rootURL: URL

    private var observers: [UUID: AsyncStream<NotebookChange>.Continuation] = [:]
    private var activeExportSessions: [UUID: ActiveNotebookExportSession] = [:]
    private let failureInjector: (@Sendable (StorageFailurePoint) throws -> Void)?

    public init(rootURL: URL) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.failureInjector = nil
        try FileManager.default.createDirectory(
            at: self.rootURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    /// Test-only fault injection hook. Kept internal so production callers cannot
    /// accidentally enable simulated storage failures.
    init(
        rootURL: URL,
        failureInjector: @escaping @Sendable (StorageFailurePoint) throws -> Void
    ) throws {
        self.rootURL = rootURL.standardizedFileURL
        self.failureInjector = failureInjector
        try FileManager.default.createDirectory(
            at: self.rootURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
    }

    public nonisolated func packageURL(for id: NotebookID) -> URL {
        rootURL
            .appendingPathComponent(id.description, isDirectory: false)
            .appendingPathExtension(NotebookPackageLayout.packageExtension)
    }

    public func changes() async -> AsyncStream<NotebookChange> {
        let observerID = UUID()
        let pair = AsyncStream<NotebookChange>.makeStream()
        observers[observerID] = pair.continuation
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeObserver(observerID) }
        }
        return pair.stream
    }

    public func createNotebook(title: String, initialPage: PageDescriptor? = nil) async throws -> NotebookManifest {
        try await createNotebook(
            id: NotebookID(),
            title: title,
            initialPage: initialPage,
            createdAt: Date()
        )
    }

    /// Creates a notebook with caller-owned identity and time authority.
    ///
    /// This overload is intentionally not idempotent: callers that need
    /// recovery after an ambiguous create response must reopen `notebookID`
    /// and verify its manifest before treating it as their requested object.
    public func createNotebook(
        id notebookID: NotebookID,
        title: String,
        initialPage: PageDescriptor? = nil,
        createdAt: Date
    ) async throws -> NotebookManifest {
        let cleanTitle = try normalizedTitle(title)
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw NotebookRepositoryError.malformedPackage(
                "A notebook creation date must be finite."
            )
        }
        if let initialPage {
            try validatePageNavigationMetadata(
                pageID: initialPage.id,
                outlineTitle: initialPage.outlineTitle
            )
        }
        let package = packageURL(for: notebookID)
        let layout = NotebookPackageLayout(packageURL: package)
        var page = initialPage
        page?.schemaVersion = PageDescriptor.currentSchemaVersion
        let manifest = NotebookManifest(
            id: notebookID,
            title: cleanTitle,
            createdAt: createdAt,
            modifiedAt: createdAt,
            revision: 1,
            pages: page.map { [$0] } ?? []
        )

        guard !FileManager.default.fileExists(atPath: package.path) else {
            throw NotebookRepositoryError.malformedPackage(
                "A package already exists for the notebook identifier."
            )
        }
        var createdPackage = false
        do {
            try createPackageDirectories(layout)
            createdPackage = true
            var writes: [PlannedFileWrite] = []
            var cleanupDirectories: [String] = []
            if let page {
                writes.append(.init(url: layout.pageDescriptorURL(page.id), data: try encode(page)))
                writes.append(.init(url: layout.elementsURL(page.id), data: try encode([CanvasElement]())))
                if let content = PageContent.empty(for: page.kind) {
                    writes.append(.init(url: layout.contentURL(page.id), data: try encode(content)))
                }
                cleanupDirectories.append(relativePath(of: layout.pageURL(page.id), in: layout.packageURL))
            }
            writes += try plannedManifestWrites(manifest, layout: layout, preservePrevious: false)
            let command = EditCommand(
                notebookID: notebookID,
                sequence: manifest.revision,
                timestamp: createdAt,
                kind: .createNotebook,
                payload: ["title": cleanTitle]
            )
            try commitTransaction(
                command: command,
                expectedRevision: 0,
                layout: layout,
                writes: writes,
                cleanupDirectories: cleanupDirectories
            )
        } catch {
            if createdPackage { try? FileManager.default.removeItem(at: package) }
            throw error
        }

        try? refreshDerivedLibraryIndex()
        emit(.init(
            notebookID: notebookID,
            kind: .created,
            revision: manifest.revision,
            timestamp: createdAt
        ))
        return manifest
    }

    public func openNotebook(id: NotebookID) async throws -> NotebookManifest {
        try readManifest(id: id)
    }

    public func openNotebookForExport(id: NotebookID) async throws -> NotebookManifest {
        let layout = try existingLayout(id)
        return try readManifestForBoundedContentRead(id: id, layout: layout)
    }

    public func beginNotebookExport(
        id: NotebookID
    ) async throws -> NotebookExportSessionContext {
        try Task.checkCancellation()
        let layout = try existingLayout(id)
        let loaded = try loadBoundedExportManifest(id: id, layout: layout)
        try Task.checkCancellation()
        let session = NotebookExportSession(notebookID: id)
        activeExportSessions[session.id] = ActiveNotebookExportSession(
            token: session,
            manifest: loaded.manifest,
            pageIDs: Set(loaded.manifest.pages.map(\.id)),
            assetDescriptorsByID: Dictionary(
                uniqueKeysWithValues: loaded.manifest.assets.map { ($0.id, $0) }
            ),
            authorizedReplayInkPayloads: [],
            authorizedReplayElementPayloads: [],
            manifestIdentity: loaded.manifestIdentity,
            packageIdentity: loaded.packageIdentity
        )
        return NotebookExportSessionContext(
            session: session,
            manifest: loaded.manifest
        )
    }

    public func validateNotebookExportSession(
        _ session: NotebookExportSession
    ) async throws -> NotebookManifest {
        try validatedActiveExportSession(session).manifest
    }

    public func endNotebookExport(_ session: NotebookExportSession) async {
        guard let active = activeExportSessions[session.id],
              active.token == session else { return }
        activeExportSessions.removeValue(forKey: session.id)
    }

    /// Internal observability for deterministic lifecycle tests.
    func activeNotebookExportSessionCount() -> Int {
        activeExportSessions.count
    }

    public func listNotebooks() async throws -> [NotebookManifest] {
        try resolveLibraryTransactions()
        return try scanValidManifests()
    }

    public func renameNotebook(id: NotebookID, title: String) async throws -> NotebookManifest {
        let cleanTitle = try normalizedTitle(title)
        let layout = try existingLayout(id)
        var manifest = try readManifest(id: id)
        let now = Date()
        manifest.title = cleanTitle
        manifest.modifiedAt = now
        manifest.revision += 1
        let command = EditCommand(
            notebookID: id,
            sequence: manifest.revision,
            timestamp: now,
            kind: .renameNotebook,
            payload: ["title": cleanTitle]
        )
        try commitTransaction(
            command: command,
            expectedRevision: manifest.revision - 1,
            layout: layout,
            writes: try plannedManifestWrites(manifest, layout: layout, preservePrevious: true)
        )
        try? refreshDerivedLibraryIndex()
        emit(.init(notebookID: id, kind: .renamed, revision: manifest.revision, timestamp: now))
        return manifest
    }

    public func updateNotebookMetadata(
        id: NotebookID,
        title: String? = nil,
        tags: [String]? = nil,
        isFavorite: Bool? = nil
    ) async throws -> NotebookManifest {
        let layout = try existingLayout(id)
        var manifest = try readManifest(id: id)
        let cleanTitle = try title.map { try normalizedTitle($0) }
        let cleanTags = tags.map { normalizedTags($0) }

        let nextTitle = cleanTitle ?? manifest.title
        let nextTags = cleanTags ?? manifest.tags
        let nextFavorite = isFavorite ?? manifest.isFavorite
        guard nextTitle != manifest.title || nextTags != manifest.tags || nextFavorite != manifest.isFavorite else {
            return manifest
        }

        let now = Date()
        manifest.title = nextTitle
        manifest.tags = nextTags
        manifest.isFavorite = nextFavorite
        manifest.modifiedAt = now
        manifest.revision += 1
        let command = EditCommand(
            notebookID: id,
            sequence: manifest.revision,
            timestamp: now,
            kind: .updateMetadata,
            payload: [
                "title": manifest.title,
                "tags": manifest.tags.joined(separator: ","),
                "isFavorite": String(manifest.isFavorite)
            ]
        )
        try commitTransaction(
            command: command,
            expectedRevision: manifest.revision - 1,
            layout: layout,
            writes: try plannedManifestWrites(manifest, layout: layout, preservePrevious: true)
        )
        try? refreshDerivedLibraryIndex()
        emit(.init(notebookID: id, kind: .metadataUpdated, revision: manifest.revision, timestamp: now))
        return manifest
    }

    public func deleteNotebook(id: NotebookID) async throws {
        let layout = try existingLayout(id)
        let manifest = try readManifest(id: id)
        invalidateExportSessions(for: id)
        let tombstone = rootURL.appendingPathComponent(
            ".\(id.description).\(UUID().uuidString).deleted",
            isDirectory: true
        )
        // Moving within the same directory makes the notebook disappear from the
        // library atomically; deleting the hidden tombstone is best-effort cleanup.
        try FileManager.default.moveItem(at: layout.packageURL, to: tombstone)
        try? FileManager.default.removeItem(at: tombstone)
        try? refreshDerivedLibraryIndex()
        emit(.init(notebookID: id, kind: .deleted, revision: manifest.revision + 1))
    }

    public func addPage(
        notebookID: NotebookID,
        page: PageDescriptor,
        at index: Int? = nil
    ) async throws -> NotebookManifest {
        try validatePageNavigationMetadata(
            pageID: page.id,
            outlineTitle: page.outlineTitle
        )
        let layout = try existingLayout(notebookID)
        var manifest = try readManifest(id: notebookID)
        guard !manifest.pages.contains(where: { $0.id == page.id }) else {
            throw NotebookRepositoryError.duplicatePage(page.id)
        }
        let insertionIndex = min(max(index ?? manifest.pages.count, 0), manifest.pages.count)
        let now = Date()
        var storedPage = page
        storedPage.schemaVersion = PageDescriptor.currentSchemaVersion
        storedPage.modifiedAt = now

        manifest.pages.insert(storedPage, at: insertionIndex)
        manifest.modifiedAt = now
        manifest.revision += 1
        let command = EditCommand(
            notebookID: notebookID,
            pageID: storedPage.id,
            sequence: manifest.revision,
            timestamp: now,
            kind: .addPage,
            payload: ["index": String(insertionIndex)]
        )
        var writes = [
            PlannedFileWrite(url: layout.pageDescriptorURL(storedPage.id), data: try encode(storedPage)),
            PlannedFileWrite(url: layout.elementsURL(storedPage.id), data: try encode([CanvasElement]()))
        ]
        if let content = PageContent.empty(for: storedPage.kind) {
            writes.append(.init(url: layout.contentURL(storedPage.id), data: try encode(content)))
        }
        writes += try plannedManifestWrites(manifest, layout: layout, preservePrevious: true)
        try commitTransaction(
            command: command,
            expectedRevision: manifest.revision - 1,
            layout: layout,
            writes: writes,
            cleanupDirectories: [relativePath(of: layout.pageURL(storedPage.id), in: layout.packageURL)]
        )
        try? refreshDerivedLibraryIndex()
        emit(.init(notebookID: notebookID, pageID: storedPage.id, kind: .pageAdded, revision: manifest.revision, timestamp: now))
        return manifest
    }

    public func deletePage(notebookID: NotebookID, pageID: PageID) async throws -> NotebookManifest {
        let layout = try existingLayout(notebookID)
        var manifest = try readManifest(id: notebookID)
        guard let index = manifest.pages.firstIndex(where: { $0.id == pageID }) else {
            throw NotebookRepositoryError.pageNotFound(pageID)
        }
        let manifestBeforeDeletion = manifest
        let now = Date()
        manifest.pages.remove(at: index)
        var writes: [PlannedFileWrite] = []
        var removedAudioMarkCount = 0
        var redactedReplayEventCount = 0
        var removedReplayAssetIDs = Set<AssetID>()
        var remainingReplayAssetIDs = Set<AssetID>()
        for audioIndex in manifest.audioSessions.indices {
            var descriptor = manifest.audioSessions[audioIndex]
            if let detail = audioDescriptorValidationDetail(
                descriptor,
                manifest: manifestBeforeDeletion
            ) {
                throw NotebookRepositoryError.invalidAudioSession(descriptor.id, detail: detail)
            }
            guard let timelineFilename = descriptor.timelineFilename else {
                continue
            }
            let sessionID = descriptor.id
            let timelineURL = try safeAudioURL(
                filename: timelineFilename,
                layout: layout,
                expectedExtension: "json"
            )
            let timelineData = try readBoundedRegularFileData(
                at: timelineURL,
                within: layout.packageURL,
                maximumBytes: AudioStorageLimits.maximumTimelineBytes
            )
            var timeline: AudioTimelineDocument
            do {
                timeline = try decode(AudioTimelineDocument.self, from: timelineData)
            } catch {
                throw NotebookRepositoryError.corruptedFile(
                    relativePath(of: timelineURL, in: layout.packageURL)
                )
            }
            guard timeline.audioSessionID == sessionID else {
                throw NotebookRepositoryError.invalidAudioSession(
                    sessionID,
                    detail: "The timeline belongs to another audio session."
                )
            }
            try validateAudioTimeline(
                timeline,
                durationSeconds: descriptor.durationSeconds,
                manifest: manifestBeforeDeletion
            )
            try validateRecordingStart(
                descriptor.recordingStartedAt,
                timeline: timeline,
                sessionID: sessionID
            )

            var replayWasRedacted = false
            if descriptor.schemaVersion >= 3 {
                guard storedNoteReplayHistoryIsValid(
                    descriptor: descriptor,
                    timeline: timeline,
                    manifest: manifestBeforeDeletion,
                    layout: layout
                ) else {
                    throw NotebookRepositoryError.invalidAudioSession(
                        sessionID,
                        detail: "The sealed Note Replay history is invalid and cannot be redacted safely."
                    )
                }
                var replay = try validatedStoredNoteReplayHistory(
                    descriptor: descriptor,
                    timeline: timeline,
                    manifest: manifestBeforeDeletion,
                    layout: layout,
                    maximumEventCount: NoteReplayHistoryLimits.maximumEventCount
                ).document
                let removedEvents = replay.events.filter { $0.pageID == pageID }
                for event in removedEvents {
                    if let inkPayload = event.inkPayload {
                        removedReplayAssetIDs.insert(inkPayload.assetID)
                    }
                    removedReplayAssetIDs.insert(event.elementsPayload.assetID)
                }
                if !removedEvents.isEmpty {
                    replay.events.removeAll { $0.pageID == pageID }
                    for eventIndex in replay.events.indices {
                        replay.events[eventIndex].sequence = eventIndex
                    }
                    let replayData = try encode(replay)
                    guard replayData.count <= NoteReplayHistoryLimits.maximumIndexBytes else {
                        throw NotebookRepositoryError.invalidAudioSession(
                            sessionID,
                            detail: "The redacted Note Replay index exceeds its storage limit."
                        )
                    }
                    guard let replayFilename = descriptor.replayFilename else {
                        throw NotebookRepositoryError.invalidAudioSession(
                            sessionID,
                            detail: "The Note Replay descriptor is missing its sealed index filename."
                        )
                    }
                    let replayURL = try safeAudioURL(
                        filename: replayFilename,
                        layout: layout,
                        expectedExtension: "json"
                    )
                    descriptor.replayByteCount = Int64(replayData.count)
                    descriptor.replaySHA256 = SHA256.hexDigest(replayData)
                    descriptor.replayEventCount = replay.events.count
                    redactedReplayEventCount += removedEvents.count
                    replayWasRedacted = true
                    writes.append(.init(url: replayURL, data: replayData))
                }
                for event in replay.events {
                    if let inkPayload = event.inkPayload {
                        remainingReplayAssetIDs.insert(inkPayload.assetID)
                    }
                    remainingReplayAssetIDs.insert(event.elementsPayload.assetID)
                }
            }

            let previousCount = timeline.marks.count
            timeline.marks.removeAll { $0.pageID == pageID }
            let timelineWasChanged = timeline.marks.count != previousCount
            if timelineWasChanged {
                removedAudioMarkCount += previousCount - timeline.marks.count
                timeline.modifiedAt = now
                try validateAudioTimeline(
                    timeline,
                    durationSeconds: descriptor.durationSeconds,
                    manifest: manifest
                )
                let encodedTimeline = try encode(timeline)
                guard encodedTimeline.count <= AudioStorageLimits.maximumTimelineBytes else {
                    throw NotebookRepositoryError.invalidAudioSession(
                        sessionID,
                        detail: "The encoded timeline exceeds the storage limit."
                    )
                }
                writes.append(.init(url: timelineURL, data: encodedTimeline))
            }
            if timelineWasChanged || replayWasRedacted {
                descriptor.modifiedAt = now
                manifest.audioSessions[audioIndex] = descriptor
            }
        }

        let replayAssetIDsToDelete = removedReplayAssetIDs.subtracting(
            remainingReplayAssetIDs
        )
        let deletedReplayAssetCount = try planReplayAssetGarbageCollection(
            candidates: replayAssetIDsToDelete,
            manifest: &manifest,
            layout: layout,
            writes: &writes
        )
        manifest.modifiedAt = now
        manifest.revision += 1
        let command = EditCommand(
            notebookID: notebookID,
            pageID: pageID,
            sequence: manifest.revision,
            timestamp: now,
            kind: .deletePage,
            payload: [
                "index": String(index),
                "pageID": pageID.description,
                "audioMarksRemoved": String(removedAudioMarkCount),
                "replayEventsRedacted": String(redactedReplayEventCount),
                "replayAssetsDeleted": String(deletedReplayAssetCount),
            ]
        )
        writes += try plannedManifestWrites(manifest, layout: layout, preservePrevious: true)
        try commitTransaction(
            command: command,
            expectedRevision: manifest.revision - 1,
            layout: layout,
            writes: writes
        )
        // The manifest is authoritative. A crash before this cleanup leaves an orphan
        // that validation can identify and recovery can remove using the operation log.
        try? FileManager.default.removeItem(at: layout.pageURL(pageID))
        try? refreshDerivedLibraryIndex()
        emit(.init(notebookID: notebookID, pageID: pageID, kind: .pageDeleted, revision: manifest.revision, timestamp: now))
        return manifest
    }

    public func reorderPages(notebookID: NotebookID, pageIDs: [PageID]) async throws -> NotebookManifest {
        let layout = try existingLayout(notebookID)
        var manifest = try readManifest(id: notebookID)
        let currentIDs = manifest.pages.map(\.id)
        guard pageIDs.count == currentIDs.count,
              Set(pageIDs).count == pageIDs.count,
              Set(pageIDs) == Set(currentIDs) else {
            throw NotebookRepositoryError.invalidPageOrder
        }
        let pagesByID = Dictionary(uniqueKeysWithValues: manifest.pages.map { ($0.id, $0) })
        manifest.pages = try pageIDs.map { id in
            guard let page = pagesByID[id] else { throw NotebookRepositoryError.invalidPageOrder }
            return page
        }
        let now = Date()
        manifest.modifiedAt = now
        manifest.revision += 1
        let command = EditCommand(
            notebookID: notebookID,
            sequence: manifest.revision,
            timestamp: now,
            kind: .reorderPages,
            payload: ["pageIDs": pageIDs.map(\.description).joined(separator: ",")]
        )
        try commitTransaction(
            command: command,
            expectedRevision: manifest.revision - 1,
            layout: layout,
            writes: try plannedManifestWrites(manifest, layout: layout, preservePrevious: true)
        )
        try? refreshDerivedLibraryIndex()
        emit(.init(notebookID: notebookID, kind: .pagesReordered, revision: manifest.revision, timestamp: now))
        return manifest
    }

    public func updatePageNavigationMetadata(
        notebookID: NotebookID,
        pageID: PageID,
        update: PageNavigationMetadataUpdate
    ) async throws -> NotebookManifest {
        if case .outlineTitle(let outlineTitle) = update {
            try validatePageNavigationMetadata(
                pageID: pageID,
                outlineTitle: outlineTitle
            )
        }
        let layout = try existingLayout(notebookID)
        var manifest = try readManifest(id: notebookID)
        guard let pageIndex = manifest.pages.firstIndex(where: { $0.id == pageID }) else {
            throw NotebookRepositoryError.pageNotFound(pageID)
        }
        try ensureSafePageDirectory(layout: layout, pageID: pageID)

        let currentPage = manifest.pages[pageIndex]
        let descriptorURL = layout.pageDescriptorURL(pageID)
        let diskPage = try readStoredPageDescriptor(
            at: descriptorURL,
            layout: layout
        )
        guard diskPage == currentPage else {
            // A Files provider can expose a partially synchronized package.
            // Neither descriptor is safe to overwrite until explicit recovery
            // applies the package's documented disk-descriptor authority.
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: descriptorURL, in: layout.packageURL)
            )
        }
        var updatedPage = currentPage
        updatedPage.schemaVersion = PageDescriptor.currentSchemaVersion
        let updatedField: String
        switch update {
        case .bookmark(let isBookmarked):
            updatedPage.isBookmarked = isBookmarked
            updatedField = "bookmark"
        case .outlineTitle(let outlineTitle):
            updatedPage.outlineTitle = outlineTitle
            updatedField = "outlineTitle"
        }
        guard updatedPage != currentPage else {
            return manifest
        }

        let now = Date()
        updatedPage.modifiedAt = now
        manifest.pages[pageIndex] = updatedPage
        manifest.modifiedAt = now
        manifest.revision += 1
        let command = EditCommand(
            notebookID: notebookID,
            pageID: pageID,
            sequence: manifest.revision,
            timestamp: now,
            kind: .updatePageNavigationMetadata,
            payload: [
                "field": updatedField,
                "isBookmarked": String(updatedPage.isBookmarked),
                "outlineTitlePresent": String(updatedPage.outlineTitle != nil)
            ]
        )
        var writes = [
            PlannedFileWrite(
                url: layout.pageDescriptorURL(pageID),
                data: try encode(manifest.pages[pageIndex])
            )
        ]
        if currentPage.schemaVersion
            < PageDescriptor.structuredContentSchemaVersion,
           let legacyContent = PageContent.empty(for: currentPage.kind) {
            let contentURL = layout.contentURL(pageID)
            guard !isSymbolicLinkEntry(at: contentURL) else {
                throw NotebookRepositoryError.corruptedFile(
                    relativePath(of: contentURL, in: layout.packageURL)
                )
            }
            if !fileSystemEntryExists(at: contentURL) {
                writes.append(PlannedFileWrite(
                    url: contentURL,
                    data: try encode(legacyContent)
                ))
            }
        }
        // Navigation titles are user-authored note content. Keep the recovery
        // manifest at the same revision so clearing or replacing a title does
        // not leave its plaintext in manifest.backup.json indefinitely.
        let encodedManifest = try encode(manifest)
        writes.append(PlannedFileWrite(
            url: layout.backupManifestURL,
            data: encodedManifest
        ))
        // The live manifest remains the transaction's final commit marker.
        writes.append(PlannedFileWrite(
            url: layout.manifestURL,
            data: encodedManifest
        ))
        try commitTransaction(
            command: command,
            expectedRevision: manifest.revision - 1,
            layout: layout,
            writes: writes
        )
        try? refreshDerivedLibraryIndex()
        emit(.init(
            notebookID: notebookID,
            pageID: pageID,
            kind: .metadataUpdated,
            revision: manifest.revision,
            timestamp: now
        ))
        return manifest
    }

    public func saveInk(_ data: Data, notebookID: NotebookID, pageID: PageID) async throws {
        let layout = try existingLayout(notebookID)
        var manifest = try readManifest(id: notebookID)
        guard let pageIndex = manifest.pages.firstIndex(where: { $0.id == pageID }) else {
            throw NotebookRepositoryError.pageNotFound(pageID)
        }
        let now = Date()
        manifest.pages[pageIndex].modifiedAt = now
        manifest.modifiedAt = now
        manifest.revision += 1
        let command = EditCommand(
            notebookID: notebookID,
            pageID: pageID,
            sequence: manifest.revision,
            timestamp: now,
            kind: .saveInk,
            payload: ["sha256": SHA256.hexDigest(data), "byteCount": String(data.count)]
        )
        var writes = [
            PlannedFileWrite(url: layout.inkURL(pageID), data: data),
            PlannedFileWrite(url: layout.pageDescriptorURL(pageID), data: try encode(manifest.pages[pageIndex]))
        ]
        writes += try plannedManifestWrites(manifest, layout: layout, preservePrevious: true)
        try commitTransaction(
            command: command,
            expectedRevision: manifest.revision - 1,
            layout: layout,
            writes: writes
        )
        emit(.init(notebookID: notebookID, pageID: pageID, kind: .inkSaved, revision: manifest.revision, timestamp: now))
    }

    public func loadInk(notebookID: NotebookID, pageID: PageID) async throws -> Data? {
        let layout = try existingLayout(notebookID)
        let manifest = try readManifest(id: notebookID)
        guard manifest.pages.contains(where: { $0.id == pageID }) else {
            throw NotebookRepositoryError.pageNotFound(pageID)
        }
        let url = layout.inkURL(pageID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    public func loadInkForExport(
        notebookID: NotebookID,
        pageID: PageID
    ) async throws -> Data? {
        let layout = try existingLayout(notebookID)
        let manifest = try readManifestForBoundedContentRead(
            id: notebookID,
            layout: layout
        )
        guard manifest.pages.contains(where: { $0.id == pageID }) else {
            throw NotebookRepositoryError.pageNotFound(pageID)
        }
        return try readBoundedRegularFileDataIfPresent(
            at: layout.inkURL(pageID),
            within: layout.packageURL,
            maximumBytes: NotebookExportReadLimits.maximumInkBytes
        )
    }

    public func loadInkForExport(
        session: NotebookExportSession,
        pageID: PageID
    ) async throws -> Data? {
        let active = try validatedActiveExportSession(session)
        guard active.pageIDs.contains(pageID) else {
            throw NotebookRepositoryError.pageNotFound(pageID)
        }
        let layout = try existingLayout(session.notebookID)
        let data = try readBoundedRegularFileDataIfPresent(
            at: layout.inkURL(pageID),
            within: layout.packageURL,
            maximumBytes: NotebookExportReadLimits.maximumInkBytes
        )
        _ = try validatedActiveExportSession(session)
        return data
    }

    public func loadInkForReplay(
        notebookID: NotebookID,
        pageID: PageID,
        maximumByteCount: Int
    ) async throws -> Data? {
        try Task.checkCancellation()
        let layout = try existingLayout(notebookID)
        let manifest = try readManifestForBoundedContentRead(
            id: notebookID,
            layout: layout
        )
        guard manifest.pages.contains(where: { $0.id == pageID }) else {
            throw NotebookRepositoryError.pageNotFound(pageID)
        }
        let effectiveLimit = NotebookReplayReadLimits.clampedInkByteCount(
            maximumByteCount
        )
        return try readBoundedRegularFileDataIfPresent(
            at: layout.inkURL(pageID),
            within: layout.packageURL,
            maximumBytes: effectiveLimit
        )
    }

    public func loadInkForReplay(
        session: NotebookExportSession,
        pageID: PageID,
        maximumByteCount: Int
    ) async throws -> Data? {
        try Task.checkCancellation()
        let active = try validatedActiveExportSession(session)
        guard active.pageIDs.contains(pageID) else {
            throw NotebookRepositoryError.pageNotFound(pageID)
        }
        let layout = try existingLayout(session.notebookID)
        let effectiveLimit = NotebookReplayReadLimits.clampedInkByteCount(
            maximumByteCount
        )
        let data = try readBoundedRegularFileDataIfPresent(
            at: layout.inkURL(pageID),
            within: layout.packageURL,
            maximumBytes: effectiveLimit
        )
        _ = try validatedActiveExportSession(session)
        return data
    }

    public func saveElements(_ elements: [CanvasElement], notebookID: NotebookID, pageID: PageID) async throws {
        let layout = try existingLayout(notebookID)
        var manifest = try readManifest(id: notebookID)
        guard let pageIndex = manifest.pages.firstIndex(where: { $0.id == pageID }) else {
            throw NotebookRepositoryError.pageNotFound(pageID)
        }
        guard Set(elements.map(\.id)).count == elements.count else {
            throw NotebookRepositoryError.malformedPackage("Canvas element identifiers must be unique.")
        }
        let now = Date()
        manifest.pages[pageIndex].modifiedAt = now
        manifest.modifiedAt = now
        manifest.revision += 1
        let command = EditCommand(
            notebookID: notebookID,
            pageID: pageID,
            sequence: manifest.revision,
            timestamp: now,
            kind: .saveElements,
            payload: ["count": String(elements.count)]
        )
        var writes = [
            PlannedFileWrite(url: layout.elementsURL(pageID), data: try encode(elements)),
            PlannedFileWrite(url: layout.pageDescriptorURL(pageID), data: try encode(manifest.pages[pageIndex]))
        ]
        writes += try plannedManifestWrites(manifest, layout: layout, preservePrevious: true)
        try commitTransaction(
            command: command,
            expectedRevision: manifest.revision - 1,
            layout: layout,
            writes: writes
        )
        emit(.init(notebookID: notebookID, pageID: pageID, kind: .elementsSaved, revision: manifest.revision, timestamp: now))
    }

    public func loadElements(notebookID: NotebookID, pageID: PageID) async throws -> [CanvasElement] {
        let layout = try existingLayout(notebookID)
        let manifest = try readManifest(id: notebookID)
        guard manifest.pages.contains(where: { $0.id == pageID }) else {
            throw NotebookRepositoryError.pageNotFound(pageID)
        }
        let url = layout.elementsURL(pageID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try decode([CanvasElement].self, from: Data(contentsOf: url))
        } catch {
            throw NotebookRepositoryError.corruptedFile(relativePath(of: url, in: layout.packageURL))
        }
    }

    public func loadElementsForExport(
        notebookID: NotebookID,
        pageID: PageID
    ) async throws -> [CanvasElement] {
        let layout = try existingLayout(notebookID)
        let manifest = try readManifestForBoundedContentRead(
            id: notebookID,
            layout: layout
        )
        guard manifest.pages.contains(where: { $0.id == pageID }) else {
            throw NotebookRepositoryError.pageNotFound(pageID)
        }
        let url = layout.elementsURL(pageID)
        guard let data = try readBoundedRegularFileDataIfPresent(
            at: url,
            within: layout.packageURL,
            maximumBytes: NotebookExportReadLimits.maximumCanvasElementBytes
        ) else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: url, in: layout.packageURL)
            )
        }
        let elementRelativePath = relativePath(of: url, in: layout.packageURL)
        do {
            try preflightCanvasElementArray(
                data,
                relativePath: elementRelativePath
            )
            let elements = try decode([CanvasElement].self, from: data)
            try validateCanvasElementsForExport(
                elements,
                validAssetIDs: Set(manifest.assets.map(\.id)),
                relativePath: elementRelativePath
            )
            return elements
        } catch let error as CancellationError {
            throw error
        } catch let error as NotebookRepositoryError {
            throw error
        } catch {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: url, in: layout.packageURL)
            )
        }
    }

    public func loadElementsForExport(
        session: NotebookExportSession,
        pageID: PageID
    ) async throws -> NotebookExportCanvasElements {
        let active = try validatedActiveExportSession(session)
        guard active.pageIDs.contains(pageID) else {
            throw NotebookRepositoryError.pageNotFound(pageID)
        }
        let layout = try existingLayout(session.notebookID)
        let url = layout.elementsURL(pageID)
        guard let data = try readBoundedRegularFileDataIfPresent(
            at: url,
            within: layout.packageURL,
            maximumBytes: NotebookExportReadLimits.maximumCanvasElementBytes
        ) else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: url, in: layout.packageURL)
            )
        }
        let elementRelativePath = relativePath(of: url, in: layout.packageURL)
        let elements: [CanvasElement]
        do {
            try preflightCanvasElementArray(data, relativePath: elementRelativePath)
            elements = try decode([CanvasElement].self, from: data)
            try validateCanvasElementsForExport(
                elements,
                validAssetIDs: Set(active.assetDescriptorsByID.keys),
                relativePath: elementRelativePath
            )
        } catch let error as CancellationError {
            throw error
        } catch let error as NotebookRepositoryError {
            throw error
        } catch {
            throw NotebookRepositoryError.corruptedFile(elementRelativePath)
        }
        _ = try validatedActiveExportSession(session)
        return NotebookExportCanvasElements(
            elements: elements,
            encodedByteCount: data.count
        )
    }

    public func savePageContent(
        _ content: PageContent,
        notebookID: NotebookID,
        pageID: PageID
    ) async throws {
        let layout = try existingLayout(notebookID)
        var manifest = try readManifest(id: notebookID)
        guard let pageIndex = manifest.pages.firstIndex(where: { $0.id == pageID }) else {
            throw NotebookRepositoryError.pageNotFound(pageID)
        }
        try ensureSafePageDirectory(layout: layout, pageID: pageID)
        guard !isSymbolicLinkEntry(at: layout.contentURL(pageID)) else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: layout.contentURL(pageID), in: layout.packageURL)
            )
        }
        try validateStructuredContent(content, for: manifest.pages[pageIndex])
        let encodedContent = try encode(content)
        guard encodedContent.count <= StructuredContentLimits.maximumEncodedBytes else {
            throw NotebookRepositoryError.invalidPageContent(
                pageID: pageID,
                detail: "The encoded page content exceeds the storage limit."
            )
        }

        let now = Date()
        manifest.pages[pageIndex].schemaVersion = PageDescriptor.currentSchemaVersion
        manifest.pages[pageIndex].modifiedAt = now
        manifest.modifiedAt = now
        manifest.revision += 1
        let command = EditCommand(
            notebookID: notebookID,
            pageID: pageID,
            sequence: manifest.revision,
            timestamp: now,
            kind: .savePageContent,
            payload: ["contentType": content.pageKind.rawValue]
        )
        var writes = [
            PlannedFileWrite(url: layout.contentURL(pageID), data: encodedContent),
            PlannedFileWrite(url: layout.pageDescriptorURL(pageID), data: try encode(manifest.pages[pageIndex]))
        ]
        writes += try plannedManifestWrites(manifest, layout: layout, preservePrevious: true)
        try commitTransaction(
            command: command,
            expectedRevision: manifest.revision - 1,
            layout: layout,
            writes: writes
        )
        emit(.init(
            notebookID: notebookID,
            pageID: pageID,
            kind: .pageContentSaved,
            revision: manifest.revision,
            timestamp: now
        ))
    }

    public func loadPageContent(notebookID: NotebookID, pageID: PageID) async throws -> PageContent? {
        let layout = try existingLayout(notebookID)
        let manifest = try readManifest(id: notebookID)
        guard let page = manifest.pages.first(where: { $0.id == pageID }) else {
            throw NotebookRepositoryError.pageNotFound(pageID)
        }
        try ensureSafePageDirectory(layout: layout, pageID: pageID)
        let url = layout.contentURL(pageID)
        guard fileSystemEntryExists(at: url) else {
            if let legacyEmptyContent = PageContent.empty(for: page.kind),
               page.schemaVersion < PageDescriptor.structuredContentSchemaVersion {
                return legacyEmptyContent
            }
            guard PageContent.empty(for: page.kind) == nil else {
                throw NotebookRepositoryError.missingPageContent(pageID)
            }
            return nil
        }
        let content: PageContent
        do {
            content = try decode(
                PageContent.self,
                from: readStructuredContentData(at: url, within: layout.packageURL)
            )
        } catch {
            throw NotebookRepositoryError.corruptedFile(relativePath(of: url, in: layout.packageURL))
        }
        try validateStructuredContent(content, for: page)
        return content
    }

    /// Reads the manifest, duplicated page descriptor, structured document,
    /// and requested block as one actor-isolated source snapshot. Every file is
    /// opened without following links and before-allocation byte ceilings are
    /// enforced. The identities of all authoritative inputs are checked again
    /// before publication, so a concurrent out-of-process replacement fails
    /// closed instead of producing a mixed-revision anchor.
    public func textDocumentSourceSnapshot(
        noteID: NotebookID,
        pageID: PageID,
        blockID: TextBlockID
    ) async throws -> TextDocumentSourceSnapshot {
        try Task.checkCancellation()
        let layout = try existingLayout(noteID)
        let loadedManifest = try loadBoundedExportManifest(
            id: noteID,
            layout: layout
        )
        guard let page = loadedManifest.manifest.pages.first(where: {
            $0.id == pageID
        }) else {
            throw NotebookRepositoryError.pageNotFound(pageID)
        }
        guard page.kind == .textDocument else {
            throw NotebookRepositoryError.pageContentTypeMismatch(
                pageID: pageID,
                expected: .textDocument,
                actual: page.kind
            )
        }

        try ensureSafePageDirectory(layout: layout, pageID: pageID)
        let pageDescriptorURL = layout.pageDescriptorURL(pageID)
        guard let pageRead = try readBoundedSourceSnapshotFileIfPresent(
            at: pageDescriptorURL,
            within: layout.packageURL,
            maximumBytes: PageDescriptorStorageLimits.maximumEncodedBytes
        ) else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: pageDescriptorURL, in: layout.packageURL)
            )
        }
        let storedPage: PageDescriptor
        do {
            storedPage = try decode(PageDescriptor.self, from: pageRead.data)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: pageDescriptorURL, in: layout.packageURL)
            )
        }
        guard storedPage == page else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: pageDescriptorURL, in: layout.packageURL)
            )
        }

        let contentURL = layout.contentURL(pageID)
        guard let contentRead = try readBoundedSourceSnapshotFileIfPresent(
            at: contentURL,
            within: layout.packageURL,
            maximumBytes: StructuredContentLimits.maximumEncodedBytes
        ) else {
            throw NotebookRepositoryError.missingPageContent(pageID)
        }
        let content: PageContent
        do {
            content = try decode(PageContent.self, from: contentRead.data)
        } catch let error as CancellationError {
            throw error
        } catch {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: contentURL, in: layout.packageURL)
            )
        }
        try validateStructuredContent(content, for: page)
        guard case .textDocument(let document) = content else {
            // `validateStructuredContent` above is the source of the detailed
            // mismatch error. This guard preserves fail-closed behavior if a
            // future PageContent case changes that validation contract.
            throw NotebookRepositoryError.pageContentTypeMismatch(
                pageID: pageID,
                expected: .textDocument,
                actual: content.pageKind
            )
        }
        guard let blockIndex = document.blocks.firstIndex(where: {
            $0.id == blockID
        }) else {
            throw NotebookRepositoryError.textBlockNotFound(
                pageID: pageID,
                blockID: blockID
            )
        }
        let block = document.blocks[blockIndex]

        try Task.checkCancellation()
        try validateTextDocumentSourceSnapshotFence(
            layout: layout,
            manifest: loadedManifest,
            pageDescriptorURL: pageDescriptorURL,
            pageDescriptorIdentity: pageRead.identity,
            contentURL: contentURL,
            contentIdentity: contentRead.identity
        )
        return TextDocumentSourceSnapshot(
            noteID: noteID,
            pageID: pageID,
            blockIndex: blockIndex,
            block: block,
            noteRevision: loadedManifest.manifest.revision
        )
    }

    public func saveHandwritingRecognition(
        _ document: HandwritingRecognitionDocument,
        notebookID: NotebookID,
        pageID: PageID,
        expectedRunID: UUID?,
        expectedRevision: Int64?
    ) async throws {
        try Task.checkCancellation()
        let layout = try existingLayout(notebookID)
        var manifest = try readManifest(id: notebookID)
        guard let pageIndex = manifest.pages.firstIndex(where: { $0.id == pageID }) else {
            throw NotebookRepositoryError.pageNotFound(pageID)
        }
        try ensureSafePageDirectory(layout: layout, pageID: pageID)

        do {
            try document.validate(expectedPageID: pageID)
        } catch {
            throw NotebookRepositoryError.invalidHandwritingRecognition(
                pageID: pageID,
                detail: error.localizedDescription
            )
        }
        let encodedDocument = try encode(document)
        guard encodedDocument.count <= HandwritingRecognitionLimits.maximumEncodedBytes else {
            throw NotebookRepositoryError.invalidHandwritingRecognition(
                pageID: pageID,
                detail: "The encoded sidecar exceeds the storage limit."
            )
        }

        let storedDocument = try readStoredHandwritingRecognition(
            pageID: pageID,
            layout: layout
        )
        switch (expectedRunID, expectedRevision, storedDocument) {
        case (nil, nil, nil):
            guard document.revision == 1 else {
                throw NotebookRepositoryError.handwritingRecognitionConflict(pageID: pageID)
            }
        case let (.some(expectedRunID), .some(expectedRevision), .some(stored)):
            let (nextRevision, overflow) = expectedRevision.addingReportingOverflow(1)
            guard !overflow,
                  expectedRevision > 0,
                  stored.runID == expectedRunID,
                  stored.revision == expectedRevision,
                  document.revision == nextRevision,
                  document.modifiedAt >= stored.modifiedAt,
                  stored.runID != document.runID
                    || handwritingRecognitionRunIsUnchanged(
                        from: stored,
                        to: document
                    ) else {
                throw NotebookRepositoryError.handwritingRecognitionConflict(pageID: pageID)
            }
        default:
            throw NotebookRepositoryError.handwritingRecognitionConflict(pageID: pageID)
        }

        guard let ink = try readBoundedRegularFileDataIfPresent(
            at: layout.inkURL(pageID),
            within: layout.packageURL,
            maximumBytes: NotebookHandwritingRecognitionReadLimits.maximumInkBytes
        ), SHA256.hexDigest(ink) == document.sourceInkSHA256 else {
            throw NotebookRepositoryError.staleHandwritingRecognitionInk(pageID: pageID)
        }

        let now = Date()
        manifest.pages[pageIndex].schemaVersion = PageDescriptor.currentSchemaVersion
        manifest.pages[pageIndex].modifiedAt = now
        manifest.modifiedAt = now
        manifest.revision += 1
        let command = EditCommand(
            notebookID: notebookID,
            pageID: pageID,
            sequence: manifest.revision,
            timestamp: now,
            kind: .saveHandwritingRecognition,
            payload: [
                "runID": document.runID.uuidString.lowercased(),
                "recognitionRevision": String(document.revision),
                "sourceInkSHA256": document.sourceInkSHA256
            ]
        )
        var writes = [
            PlannedFileWrite(
                url: layout.handwritingRecognitionURL(pageID),
                data: encodedDocument
            ),
            PlannedFileWrite(
                url: layout.pageDescriptorURL(pageID),
                data: try encode(manifest.pages[pageIndex])
            )
        ]
        writes += try plannedManifestWrites(
            manifest,
            layout: layout,
            preservePrevious: true
        )
        try Task.checkCancellation()
        try commitTransaction(
            command: command,
            expectedRevision: manifest.revision - 1,
            layout: layout,
            writes: writes
        )
        emit(.init(
            notebookID: notebookID,
            pageID: pageID,
            kind: .handwritingRecognitionSaved,
            revision: manifest.revision,
            timestamp: now
        ))
    }

    public func loadHandwritingRecognition(
        notebookID: NotebookID,
        pageID: PageID
    ) async throws -> HandwritingRecognitionDocument? {
        let layout = try existingLayout(notebookID)
        let manifest = try readManifest(id: notebookID)
        guard manifest.pages.contains(where: { $0.id == pageID }) else {
            throw NotebookRepositoryError.pageNotFound(pageID)
        }
        try ensureSafePageDirectory(layout: layout, pageID: pageID)
        return try readStoredHandwritingRecognition(pageID: pageID, layout: layout)
    }

    public func loadInkForHandwritingRecognition(
        notebookID: NotebookID,
        pageID: PageID
    ) async throws -> Data? {
        try Task.checkCancellation()
        let layout = try existingLayout(notebookID)
        let manifest = try readManifestForBoundedContentRead(
            id: notebookID,
            layout: layout
        )
        guard manifest.pages.contains(where: { $0.id == pageID }) else {
            throw NotebookRepositoryError.pageNotFound(pageID)
        }
        return try readBoundedRegularFileDataIfPresent(
            at: layout.inkURL(pageID),
            within: layout.packageURL,
            maximumBytes: NotebookHandwritingRecognitionReadLimits.maximumInkBytes
        )
    }

    public func importAsset(
        _ data: Data,
        notebookID: NotebookID,
        mediaType: String,
        originalFilename: String? = nil
    ) async throws -> AssetDescriptor {
        let layout = try existingLayout(notebookID)
        var manifest = try readManifest(id: notebookID)
        let assetID = AssetID(SHA256.hexDigest(data))
        if let existing = manifest.assets.first(where: { $0.id == assetID }) {
            guard let existingData = try? Data(contentsOf: layout.assetURL(assetID), options: .mappedIfSafe),
                  Int64(existingData.count) == existing.byteCount,
                  SHA256.hexDigest(existingData) == assetID.rawValue else {
                throw NotebookRepositoryError.invalidAsset(assetID)
            }
            return existing
        }

        let assetURL = layout.assetURL(assetID)
        var writes: [PlannedFileWrite] = []
        if FileManager.default.fileExists(atPath: assetURL.path) {
            let existingData = try Data(contentsOf: assetURL, options: .mappedIfSafe)
            guard existingData == data else { throw NotebookRepositoryError.invalidAsset(assetID) }
        } else {
            writes.append(.init(url: assetURL, data: data))
        }

        let now = Date()
        let descriptor = AssetDescriptor(
            id: assetID,
            mediaType: mediaType.isEmpty ? "application/octet-stream" : mediaType,
            originalFilename: originalFilename,
            byteCount: Int64(data.count),
            createdAt: now
        )
        manifest.assets.append(descriptor)
        manifest.modifiedAt = now
        manifest.revision += 1
        let command = EditCommand(
            notebookID: notebookID,
            sequence: manifest.revision,
            timestamp: now,
            kind: .importAsset,
            payload: ["assetID": assetID.rawValue, "mediaType": descriptor.mediaType]
        )
        writes += try plannedManifestWrites(manifest, layout: layout, preservePrevious: true)
        try commitTransaction(
            command: command,
            expectedRevision: manifest.revision - 1,
            layout: layout,
            writes: writes
        )
        emit(.init(notebookID: notebookID, kind: .assetImported, revision: manifest.revision, timestamp: now))
        return descriptor
    }

    public func loadAsset(notebookID: NotebookID, assetID: AssetID) async throws -> Data {
        let layout = try existingLayout(notebookID)
        let manifest = try readManifest(id: notebookID)
        guard let descriptor = manifest.assets.first(where: { $0.id == assetID }) else {
            throw NotebookRepositoryError.invalidAsset(assetID)
        }
        let url = layout.assetURL(assetID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NotebookRepositoryError.invalidAsset(assetID)
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard Int64(data.count) == descriptor.byteCount, SHA256.hexDigest(data) == assetID.rawValue else {
            throw NotebookRepositoryError.invalidAsset(assetID)
        }
        return data
    }

    public func loadAssetForExport(
        notebookID: NotebookID,
        assetID: AssetID
    ) async throws -> Data {
        let layout = try existingLayout(notebookID)
        let manifest = try readManifestForBoundedContentRead(
            id: notebookID,
            layout: layout
        )
        guard assetID.isSHA256Digest,
              let descriptor = manifest.assets.first(where: { $0.id == assetID }) else {
            throw NotebookRepositoryError.invalidAsset(assetID)
        }
        return try readValidatedAssetForExport(
            descriptor,
            layout: layout,
            maximumBytes: NotebookExportReadLimits.maximumBackgroundAssetBytes
        )
    }

    public func loadAssetForExport(
        session: NotebookExportSession,
        assetID: AssetID
    ) async throws -> Data {
        let active = try validatedActiveExportSession(session)
        guard assetID.isSHA256Digest,
              let descriptor = active.assetDescriptorsByID[assetID] else {
            throw NotebookRepositoryError.invalidAsset(assetID)
        }
        let layout = try existingLayout(session.notebookID)
        let data = try readValidatedAssetForExport(
            descriptor,
            layout: layout,
            maximumBytes: NotebookExportReadLimits.maximumBackgroundAssetBytes
        )
        _ = try validatedActiveExportSession(session)
        return data
    }

    public func loadCanvasAssetsForExport(
        notebookID: NotebookID,
        assetIDs: [AssetID]
    ) async throws -> [AssetID: Data] {
        guard assetIDs.count <= NotebookExportReadLimits.maximumCanvasAssetResolutionAttempts,
              Set(assetIDs).count == assetIDs.count else {
            throw NotebookRepositoryError.canvasElementLimitExceeded(
                limit: NotebookExportReadLimits.maximumCanvasAssetResolutionAttempts
            )
        }
        let layout = try existingLayout(notebookID)
        let manifest = try readManifestForBoundedContentRead(
            id: notebookID,
            layout: layout
        )
        var descriptorsByID = [AssetID: AssetDescriptor]()
        descriptorsByID.reserveCapacity(manifest.assets.count)
        for descriptor in manifest.assets {
            guard descriptorsByID.updateValue(descriptor, forKey: descriptor.id) == nil else {
                throw NotebookRepositoryError.malformedPackage(
                    "Asset identifiers must be unique."
                )
            }
        }
        var descriptors = [AssetDescriptor]()
        descriptors.reserveCapacity(assetIDs.count)
        var expectedTotalBytes = 0
        for assetID in assetIDs {
            try Task.checkCancellation()
            guard assetID.isSHA256Digest,
                  let descriptor = descriptorsByID[assetID],
                  descriptor.byteCount >= 0 else {
                throw NotebookRepositoryError.invalidAsset(assetID)
            }
            guard descriptor.byteCount <= Int64(
                NotebookExportReadLimits.maximumCanvasAssetSourceBytes
            ) else {
                throw NotebookRepositoryError.boundedReadLimitExceeded(
                    relativePath: "assets/\(assetID.rawValue)",
                    limit: NotebookExportReadLimits.maximumCanvasAssetSourceBytes
                )
            }
            let byteCount = Int(descriptor.byteCount)
            guard expectedTotalBytes <= NotebookExportReadLimits.maximumCanvasAssetSourceBytesPerPage
                    - byteCount else {
                throw NotebookRepositoryError.boundedReadLimitExceeded(
                    relativePath: "canvas-assets",
                    limit: NotebookExportReadLimits.maximumCanvasAssetSourceBytesPerPage
                )
            }
            expectedTotalBytes += byteCount
            descriptors.append(descriptor)
        }

        var result = [AssetID: Data]()
        result.reserveCapacity(descriptors.count)
        var loadedBytes = 0
        for descriptor in descriptors {
            let data = try readValidatedAssetForExport(
                descriptor,
                layout: layout,
                maximumBytes: NotebookExportReadLimits.maximumCanvasAssetSourceBytes
            )
            guard loadedBytes <= NotebookExportReadLimits.maximumCanvasAssetSourceBytesPerPage
                    - data.count else {
                throw NotebookRepositoryError.boundedReadLimitExceeded(
                    relativePath: "canvas-assets",
                    limit: NotebookExportReadLimits.maximumCanvasAssetSourceBytesPerPage
                )
            }
            loadedBytes += data.count
            result[descriptor.id] = data
        }
        return result
    }

    public func loadCanvasAssetsForExport(
        session: NotebookExportSession,
        assetIDs: [AssetID]
    ) async throws -> [AssetID: Data] {
        guard assetIDs.count <= NotebookExportReadLimits.maximumCanvasAssetResolutionAttempts,
              Set(assetIDs).count == assetIDs.count else {
            throw NotebookRepositoryError.canvasElementLimitExceeded(
                limit: NotebookExportReadLimits.maximumCanvasAssetResolutionAttempts
            )
        }
        let active = try validatedActiveExportSession(session)
        var descriptors = [AssetDescriptor]()
        descriptors.reserveCapacity(assetIDs.count)
        var expectedTotalBytes = 0
        for assetID in assetIDs {
            try Task.checkCancellation()
            guard assetID.isSHA256Digest,
                  let descriptor = active.assetDescriptorsByID[assetID],
                  descriptor.byteCount >= 0 else {
                throw NotebookRepositoryError.invalidAsset(assetID)
            }
            guard descriptor.byteCount <= Int64(
                NotebookExportReadLimits.maximumCanvasAssetSourceBytes
            ) else {
                throw NotebookRepositoryError.boundedReadLimitExceeded(
                    relativePath: "assets/\(assetID.rawValue)",
                    limit: NotebookExportReadLimits.maximumCanvasAssetSourceBytes
                )
            }
            let byteCount = Int(descriptor.byteCount)
            guard expectedTotalBytes <= NotebookExportReadLimits.maximumCanvasAssetSourceBytesPerPage
                    - byteCount else {
                throw NotebookRepositoryError.boundedReadLimitExceeded(
                    relativePath: "canvas-assets",
                    limit: NotebookExportReadLimits.maximumCanvasAssetSourceBytesPerPage
                )
            }
            expectedTotalBytes += byteCount
            descriptors.append(descriptor)
        }

        let layout = try existingLayout(session.notebookID)
        var result = [AssetID: Data]()
        result.reserveCapacity(descriptors.count)
        var loadedBytes = 0
        for descriptor in descriptors {
            let data = try readValidatedAssetForExport(
                descriptor,
                layout: layout,
                maximumBytes: NotebookExportReadLimits.maximumCanvasAssetSourceBytes
            )
            guard loadedBytes <= NotebookExportReadLimits.maximumCanvasAssetSourceBytesPerPage
                    - data.count else {
                throw NotebookRepositoryError.boundedReadLimitExceeded(
                    relativePath: "canvas-assets",
                    limit: NotebookExportReadLimits.maximumCanvasAssetSourceBytesPerPage
                )
            }
            loadedBytes += data.count
            result[descriptor.id] = data
        }
        _ = try validatedActiveExportSession(session)
        return result
    }

    public func addAudioSession(
        _ m4aData: Data,
        timeline: AudioTimelineDocument,
        notebookID: NotebookID,
        durationSeconds: Double,
        transcriptAssetID: AssetID? = nil
    ) async throws -> AudioSessionDescriptor {
        try validateAudioData(m4aData, sessionID: timeline.audioSessionID)
        let temporarySource = try makeTemporaryAudioSource(
            from: m4aData,
            sessionID: timeline.audioSessionID
        )
        defer { try? FileManager.default.removeItem(at: temporarySource) }
        return try await addAudioSession(
            from: temporarySource,
            timeline: timeline,
            notebookID: notebookID,
            durationSeconds: durationSeconds,
            transcriptAssetID: transcriptAssetID
        )
    }

    public func addAudioSession(
        from m4aFileURL: URL,
        timeline: AudioTimelineDocument,
        notebookID: NotebookID,
        durationSeconds: Double,
        transcriptAssetID: AssetID? = nil
    ) async throws -> AudioSessionDescriptor {
        try await addAudioSession(
            from: m4aFileURL,
            maximumByteCount: Int64(AudioStorageLimits.maximumAudioBytes),
            timeline: timeline,
            notebookID: notebookID,
            durationSeconds: durationSeconds,
            transcriptAssetID: transcriptAssetID
        )
    }

    public func addAudioSession(
        from m4aFileURL: URL,
        maximumByteCount: Int64,
        timeline: AudioTimelineDocument,
        notebookID: NotebookID,
        durationSeconds: Double,
        transcriptAssetID: AssetID? = nil
    ) async throws -> AudioSessionDescriptor {
        try await ingestAudioSession(
            from: m4aFileURL,
            maximumByteCount: maximumByteCount,
            timeline: timeline,
            replayHistory: nil,
            notebookID: notebookID,
            durationSeconds: durationSeconds,
            recordingStartedAt: nil,
            transcriptAssetID: transcriptAssetID
        )
    }

    public func addRecordedAudioSession(
        from m4aFileURL: URL,
        maximumByteCount: Int64,
        timeline: AudioTimelineDocument,
        notebookID: NotebookID,
        durationSeconds: Double,
        recordingStartedAt: Date,
        transcriptAssetID: AssetID? = nil
    ) async throws -> AudioSessionDescriptor {
        try await ingestAudioSession(
            from: m4aFileURL,
            maximumByteCount: maximumByteCount,
            timeline: timeline,
            replayHistory: nil,
            notebookID: notebookID,
            durationSeconds: durationSeconds,
            recordingStartedAt: recordingStartedAt,
            transcriptAssetID: transcriptAssetID
        )
    }

    public func addRecordedAudioSession(
        from m4aFileURL: URL,
        maximumByteCount: Int64,
        timeline: AudioTimelineDocument,
        replayHistory: NoteReplayCaptureBundle,
        notebookID: NotebookID,
        durationSeconds: Double,
        recordingStartedAt: Date,
        transcriptAssetID: AssetID? = nil
    ) async throws -> AudioSessionDescriptor {
        try await ingestAudioSession(
            from: m4aFileURL,
            maximumByteCount: maximumByteCount,
            timeline: timeline,
            replayHistory: replayHistory,
            notebookID: notebookID,
            durationSeconds: durationSeconds,
            recordingStartedAt: recordingStartedAt,
            transcriptAssetID: transcriptAssetID
        )
    }

    private func ingestAudioSession(
        from m4aFileURL: URL,
        maximumByteCount: Int64,
        timeline: AudioTimelineDocument,
        replayHistory: NoteReplayCaptureBundle?,
        notebookID: NotebookID,
        durationSeconds: Double,
        recordingStartedAt: Date?,
        transcriptAssetID: AssetID?
    ) async throws -> AudioSessionDescriptor {
        let layout = try existingLayout(notebookID)
        var manifest = try readManifest(id: notebookID)
        let sessionID = timeline.audioSessionID
        guard maximumByteCount > 0,
              maximumByteCount <= Int64(AudioStorageLimits.maximumAudioBytes) else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The caller's audio ingestion limit is invalid."
            )
        }
        guard !manifest.audioSessions.contains(where: { $0.id == sessionID }) else {
            throw NotebookRepositoryError.duplicateAudioSession(sessionID)
        }
        try validateAudioDuration(durationSeconds, sessionID: sessionID)
        try validateTranscriptAsset(transcriptAssetID, manifest: manifest, sessionID: sessionID)
        try validateAudioTimeline(timeline, durationSeconds: durationSeconds, manifest: manifest)
        try validateRecordingStart(
            recordingStartedAt,
            timeline: timeline,
            sessionID: sessionID
        )
        try ensureSafeDirectory(layout.audioURL, within: layout.packageURL)
        let source = try inspectAudioSource(
            at: m4aFileURL,
            sessionID: sessionID,
            maximumByteCount: maximumByteCount
        )

        let audioURL = layout.audioSessionURL(sessionID)
        let timelineURL = layout.audioTimelineURL(sessionID)
        let replayURL = layout.audioReplayHistoryURL(sessionID)
        guard !fileSystemEntryExists(at: audioURL),
              !fileSystemEntryExists(at: timelineURL),
              replayHistory == nil || !fileSystemEntryExists(at: replayURL) else {
            throw NotebookRepositoryError.duplicateAudioSession(sessionID)
        }
        let timelineData = try encode(timeline)
        guard timelineData.count <= AudioStorageLimits.maximumTimelineBytes else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The encoded timeline exceeds the storage limit."
            )
        }

        var replayData: Data?
        var replayWrites: [PlannedFileWrite] = []
        if let replayHistory {
            let prepared = try prepareNoteReplayHistoryForIngest(
                replayHistory,
                timeline: timeline,
                durationSeconds: durationSeconds,
                manifest: &manifest,
                layout: layout
            )
            replayData = prepared.indexData
            replayWrites = prepared.payloadWrites
        }

        let now = Date()
        let descriptor = AudioSessionDescriptor(
            schemaVersion: replayData == nil ? 2 : 3,
            id: sessionID,
            createdAt: now,
            modifiedAt: now,
            recordingStartedAt: recordingStartedAt,
            durationSeconds: durationSeconds,
            chunkFilenames: [audioURL.lastPathComponent],
            audioByteCount: source.byteCount,
            audioSHA256: source.sha256,
            timelineFilename: timelineURL.lastPathComponent,
            transcriptAssetID: transcriptAssetID,
            replayFilename: replayData.map { _ in replayURL.lastPathComponent },
            replayByteCount: replayData.map { Int64($0.count) },
            replaySHA256: replayData.map(SHA256.hexDigest),
            replayEventCount: replayHistory?.document.events.count
        )
        manifest.schemaVersion = NotebookManifest.currentSchemaVersion
        manifest.audioSessions.append(descriptor)
        manifest.modifiedAt = now
        manifest.revision += 1
        let command = EditCommand(
            notebookID: notebookID,
            sequence: manifest.revision,
            timestamp: now,
            kind: .addAudioSession,
            payload: ["audioSessionID": sessionID.description]
        )
        var writes = replayWrites + [
            PlannedFileWrite(streamingAudioTo: audioURL, source: source),
            PlannedFileWrite(url: timelineURL, data: timelineData)
        ]
        if let replayData {
            writes.append(PlannedFileWrite(url: replayURL, data: replayData))
        }
        writes += try plannedManifestWrites(manifest, layout: layout, preservePrevious: true)
        try commitTransaction(
            command: command,
            expectedRevision: manifest.revision - 1,
            layout: layout,
            writes: writes
        )
        try? refreshDerivedLibraryIndex()
        emit(.init(
            notebookID: notebookID,
            kind: .audioSessionAdded,
            revision: manifest.revision,
            timestamp: now
        ))
        return descriptor
    }

    public func updateAudioSession(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        timeline: AudioTimelineDocument,
        transcriptAssetID: AssetID? = nil
    ) async throws -> AudioSessionDescriptor {
        let layout = try existingLayout(notebookID)
        var manifest = try readManifest(id: notebookID)
        guard let index = manifest.audioSessions.firstIndex(where: { $0.id == sessionID }) else {
            throw NotebookRepositoryError.audioSessionNotFound(sessionID)
        }
        guard timeline.audioSessionID == sessionID else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The timeline belongs to another audio session."
            )
        }
        var descriptor = manifest.audioSessions[index]
        if let detail = audioDescriptorValidationDetail(descriptor, manifest: manifest) {
            throw NotebookRepositoryError.invalidAudioSession(sessionID, detail: detail)
        }
        let audioURL = try audioFileURL(for: descriptor, layout: layout)
        let storedAudio = try inspectAudioSource(at: audioURL, sessionID: sessionID)
        try validateAudioTimeline(timeline, durationSeconds: descriptor.durationSeconds, manifest: manifest)
        try validateRecordingStart(
            descriptor.recordingStartedAt,
            timeline: timeline,
            sessionID: sessionID
        )
        try validateTranscriptAsset(transcriptAssetID, manifest: manifest, sessionID: sessionID)

        let timelineURL = layout.audioTimelineURL(sessionID)
        guard descriptor.timelineFilename == nil || descriptor.timelineFilename == timelineURL.lastPathComponent else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The timeline filename does not match its session identifier."
            )
        }
        if descriptor.timelineFilename == nil, fileSystemEntryExists(at: timelineURL) {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "A legacy session cannot overwrite an unreferenced timeline file."
            )
        }
        if fileSystemEntryExists(at: timelineURL), isSymbolicLinkEntry(at: timelineURL) {
            throw NotebookRepositoryError.corruptedFile(relativePath(of: timelineURL, in: layout.packageURL))
        }
        let timelineData = try encode(timeline)
        guard timelineData.count <= AudioStorageLimits.maximumTimelineBytes else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The encoded timeline exceeds the storage limit."
            )
        }
        if descriptor.schemaVersion >= 3,
           !storedNoteReplayHistoryIsValid(
               descriptor: descriptor,
               timeline: timeline,
               manifest: manifest,
               layout: layout
           ) {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The replacement timeline is inconsistent with the sealed Note Replay history."
            )
        }

        let now = Date()
        descriptor.schemaVersion = descriptor.replayFilename == nil ? 2 : 3
        descriptor.modifiedAt = now
        descriptor.chunkFilenames = [audioURL.lastPathComponent]
        descriptor.audioByteCount = storedAudio.byteCount
        descriptor.audioSHA256 = storedAudio.sha256
        descriptor.timelineFilename = timelineURL.lastPathComponent
        descriptor.transcriptAssetID = transcriptAssetID
        manifest.schemaVersion = NotebookManifest.currentSchemaVersion
        manifest.audioSessions[index] = descriptor
        manifest.modifiedAt = now
        manifest.revision += 1
        let command = EditCommand(
            notebookID: notebookID,
            sequence: manifest.revision,
            timestamp: now,
            kind: .updateAudioSession,
            payload: ["audioSessionID": sessionID.description]
        )
        var writes = [PlannedFileWrite(url: timelineURL, data: timelineData)]
        writes += try plannedManifestWrites(manifest, layout: layout, preservePrevious: true)
        try commitTransaction(
            command: command,
            expectedRevision: manifest.revision - 1,
            layout: layout,
            writes: writes
        )
        try? refreshDerivedLibraryIndex()
        emit(.init(
            notebookID: notebookID,
            kind: .audioSessionUpdated,
            revision: manifest.revision,
            timestamp: now
        ))
        return descriptor
    }

    public func loadAudioChunk(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        offset: Int64,
        maximumByteCount: Int
    ) async throws -> Data {
        guard offset >= 0,
              maximumByteCount > 0,
              maximumByteCount <= AudioStorageLimits.maximumReadChunkBytes else {
            throw NotebookRepositoryError.invalidAudioReadRange
        }
        let layout = try existingLayout(notebookID)
        let manifest = try readManifest(id: notebookID)
        guard let descriptor = manifest.audioSessions.first(where: { $0.id == sessionID }) else {
            throw NotebookRepositoryError.audioSessionNotFound(sessionID)
        }
        if let detail = audioDescriptorValidationDetail(descriptor, manifest: manifest) {
            throw NotebookRepositoryError.invalidAudioSession(sessionID, detail: detail)
        }
        let audioURL = try audioFileURL(for: descriptor, layout: layout)
        return try readRegularFileChunk(
            at: audioURL,
            within: layout.packageURL,
            offset: offset,
            maximumByteCount: maximumByteCount,
            expectedByteCount: descriptor.audioByteCount
        )
    }

    public func audioSessionDescriptorForExport(
        session: NotebookExportSession,
        sessionID: AudioSessionID
    ) async throws -> AudioSessionDescriptor {
        try Task.checkCancellation()
        let active = try validatedActiveExportSession(session)
        guard let descriptor = active.manifest.audioSessions.first(where: { $0.id == sessionID }) else {
            throw NotebookRepositoryError.audioSessionNotFound(sessionID)
        }
        if let detail = audioDescriptorValidationDetail(descriptor, manifest: active.manifest) {
            throw NotebookRepositoryError.invalidAudioSession(sessionID, detail: detail)
        }
        try Task.checkCancellation()
        return descriptor
    }

    public func loadAudioChunkForExport(
        session: NotebookExportSession,
        sessionID: AudioSessionID,
        offset: Int64,
        maximumByteCount: Int
    ) async throws -> Data {
        try Task.checkCancellation()
        guard offset >= 0,
              maximumByteCount > 0,
              maximumByteCount <= AudioStorageLimits.maximumReadChunkBytes else {
            throw NotebookRepositoryError.invalidAudioReadRange
        }
        let active = try validatedActiveExportSession(session)
        guard let descriptor = active.manifest.audioSessions.first(where: { $0.id == sessionID }) else {
            throw NotebookRepositoryError.audioSessionNotFound(sessionID)
        }
        if let detail = audioDescriptorValidationDetail(descriptor, manifest: active.manifest) {
            throw NotebookRepositoryError.invalidAudioSession(sessionID, detail: detail)
        }
        let layout = try existingLayout(session.notebookID)
        let audioURL = try audioFileURL(for: descriptor, layout: layout)
        let data = try readRegularFileChunk(
            at: audioURL,
            within: layout.packageURL,
            offset: offset,
            maximumByteCount: maximumByteCount,
            expectedByteCount: descriptor.audioByteCount
        )
        try Task.checkCancellation()
        let revalidated = try validatedActiveExportSession(session)
        guard revalidated.manifest.audioSessions.first(where: { $0.id == sessionID }) == descriptor else {
            throw NotebookRepositoryError.invalidExportSession
        }
        return data
    }

    public func loadAudioTimeline(
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> AudioTimelineDocument {
        let layout = try existingLayout(notebookID)
        let manifest = try readManifest(id: notebookID)
        guard let descriptor = manifest.audioSessions.first(where: { $0.id == sessionID }) else {
            throw NotebookRepositoryError.audioSessionNotFound(sessionID)
        }
        if let detail = audioDescriptorValidationDetail(descriptor, manifest: manifest) {
            throw NotebookRepositoryError.invalidAudioSession(sessionID, detail: detail)
        }
        guard let timelineFilename = descriptor.timelineFilename else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "This legacy session does not contain a timeline."
            )
        }
        let timelineURL = try safeAudioURL(filename: timelineFilename, layout: layout, expectedExtension: "json")
        let data = try readBoundedRegularFileData(
            at: timelineURL,
            within: layout.packageURL,
            maximumBytes: AudioStorageLimits.maximumTimelineBytes
        )
        let timeline: AudioTimelineDocument
        do {
            timeline = try decode(AudioTimelineDocument.self, from: data)
        } catch {
            throw NotebookRepositoryError.corruptedFile(relativePath(of: timelineURL, in: layout.packageURL))
        }
        try validateAudioTimeline(timeline, durationSeconds: descriptor.durationSeconds, manifest: manifest)
        try validateRecordingStart(
            descriptor.recordingStartedAt,
            timeline: timeline,
            sessionID: sessionID
        )
        guard timeline.audioSessionID == sessionID else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The timeline belongs to another audio session."
            )
        }
        return timeline
    }

    public func loadAudioTimelineForReplay(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        maximumMarkCount: Int
    ) async throws -> AudioTimelineDocument {
        try Task.checkCancellation()
        let layout = try existingLayout(notebookID)
        let manifest = try readManifestForBoundedContentRead(
            id: notebookID,
            layout: layout
        )
        guard let descriptor = manifest.audioSessions.first(where: { $0.id == sessionID }) else {
            throw NotebookRepositoryError.audioSessionNotFound(sessionID)
        }
        if let detail = audioDescriptorValidationDetail(descriptor, manifest: manifest) {
            throw NotebookRepositoryError.invalidAudioSession(sessionID, detail: detail)
        }
        return try readAudioTimelineForReplay(
            descriptor: descriptor,
            layout: layout,
            maximumMarkCount: maximumMarkCount
        )
    }

    public func loadAudioTimelineForReplay(
        session: NotebookExportSession,
        sessionID: AudioSessionID,
        maximumMarkCount: Int
    ) async throws -> AudioTimelineDocument {
        try Task.checkCancellation()
        let active = try validatedActiveExportSession(session)
        guard let descriptor = active.manifest.audioSessions.first(where: { $0.id == sessionID }) else {
            throw NotebookRepositoryError.audioSessionNotFound(sessionID)
        }
        if let detail = audioDescriptorValidationDetail(
            descriptor,
            manifest: active.manifest
        ) {
            throw NotebookRepositoryError.invalidAudioSession(sessionID, detail: detail)
        }
        let layout = try existingLayout(session.notebookID)
        let timeline = try readAudioTimelineForReplay(
            descriptor: descriptor,
            layout: layout,
            maximumMarkCount: maximumMarkCount
        )
        _ = try validatedActiveExportSession(session)
        return timeline
    }

    private func readAudioTimelineForReplay(
        descriptor: AudioSessionDescriptor,
        layout: NotebookPackageLayout,
        maximumMarkCount: Int
    ) throws -> AudioTimelineDocument {
        let sessionID = descriptor.id
        guard let timelineFilename = descriptor.timelineFilename else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "This legacy session does not contain a timeline."
            )
        }
        let timelineURL = try safeAudioURL(
            filename: timelineFilename,
            layout: layout,
            expectedExtension: "json"
        )
        let data = try readBoundedRegularFileData(
            at: timelineURL,
            within: layout.packageURL,
            maximumBytes: NotebookReplayReadLimits.maximumTimelineBytes
        )
        let timeline: AudioTimelineDocument
        do {
            timeline = try decode(AudioTimelineDocument.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: timelineURL, in: layout.packageURL)
            )
        }
        let effectiveMarkLimit = NotebookReplayReadLimits.clampedTimelineMarkCount(
            maximumMarkCount
        )
        try validateAudioTimelineForReplay(
            timeline,
            descriptor: descriptor,
            maximumMarkCount: effectiveMarkLimit
        )
        return timeline
    }

    public func loadNoteReplayHistoryForReplay(
        session: NotebookExportSession,
        sessionID: AudioSessionID,
        maximumEventCount: Int
    ) async throws -> NoteReplayHistoryDocument? {
        try Task.checkCancellation()
        guard maximumEventCount > 0 else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The requested Note Replay event limit is invalid."
            )
        }
        let active = try validatedActiveExportSession(session)
        guard let descriptor = active.manifest.audioSessions.first(where: { $0.id == sessionID }) else {
            throw NotebookRepositoryError.audioSessionNotFound(sessionID)
        }
        if let detail = audioDescriptorValidationDetail(descriptor, manifest: active.manifest) {
            throw NotebookRepositoryError.invalidAudioSession(sessionID, detail: detail)
        }
        guard descriptor.schemaVersion >= 3 else { return nil }
        guard let replayFilename = descriptor.replayFilename,
              let expectedByteCount = descriptor.replayByteCount,
              let expectedSHA256 = descriptor.replaySHA256 else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The Note Replay descriptor metadata is incomplete."
            )
        }

        let layout = try existingLayout(session.notebookID)
        let replayURL = try safeAudioURL(
            filename: replayFilename,
            layout: layout,
            expectedExtension: "json"
        )
        let data = try readBoundedRegularFileData(
            at: replayURL,
            within: layout.packageURL,
            maximumBytes: NoteReplayHistoryLimits.maximumIndexBytes
        )
        guard Int64(data.count) == expectedByteCount,
              SHA256.hexDigest(data) == expectedSHA256 else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: replayURL, in: layout.packageURL)
            )
        }
        let document: NoteReplayHistoryDocument
        do {
            document = try decode(NoteReplayHistoryDocument.self, from: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: replayURL, in: layout.packageURL)
            )
        }
        let timeline = try readAudioTimelineForReplay(
            descriptor: descriptor,
            layout: layout,
            maximumMarkCount: NotebookReplayReadLimits.maximumTimelineMarks
        )
        let authorized = try validateStoredNoteReplayHistory(
            document,
            descriptor: descriptor,
            timeline: timeline,
            manifest: active.manifest,
            maximumEventCount: NoteReplayHistoryLimits.clampedEventCount(maximumEventCount)
        )

        try Task.checkCancellation()
        var revalidated = try validatedActiveExportSession(session)
        guard revalidated.manifest.audioSessions.first(where: { $0.id == sessionID }) == descriptor else {
            throw NotebookRepositoryError.invalidExportSession
        }
        revalidated.authorizedReplayInkPayloads.formUnion(authorized.ink)
        revalidated.authorizedReplayElementPayloads.formUnion(authorized.elements)
        activeExportSessions[session.id] = revalidated
        return document
    }

    public func loadNoteReplayInkPayloadForReplay(
        session: NotebookExportSession,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int
    ) async throws -> Data? {
        try Task.checkCancellation()
        guard maximumByteCount > 0 else {
            throw NotebookRepositoryError.boundedReadLimitExceeded(
                relativePath: "note-replay-ink",
                limit: 0
            )
        }
        let active = try validatedActiveExportSession(session)
        let effectiveLimit = NoteReplayHistoryLimits.clampedInkByteCount(maximumByteCount)
        guard active.authorizedReplayInkPayloads.contains(reference),
              reference.byteCount > 0,
              reference.byteCount <= effectiveLimit,
              let descriptor = active.assetDescriptorsByID[reference.assetID],
              descriptor.mediaType == NoteReplayPayloadCodec.inkMediaType,
              descriptor.byteCount == Int64(reference.byteCount) else {
            throw NotebookRepositoryError.invalidAsset(reference.assetID)
        }
        let layout = try existingLayout(session.notebookID)
        let data = try readValidatedAssetData(
            descriptor,
            layout: layout,
            maximumBytes: effectiveLimit
        )
        try Task.checkCancellation()
        let revalidated = try validatedActiveExportSession(session)
        guard revalidated.authorizedReplayInkPayloads.contains(reference),
              revalidated.assetDescriptorsByID[reference.assetID] == descriptor else {
            throw NotebookRepositoryError.invalidExportSession
        }
        return data
    }

    public func loadNoteReplayElementsPayloadForReplay(
        session: NotebookExportSession,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int,
        maximumElementCount: Int
    ) async throws -> NotebookExportCanvasElements {
        try Task.checkCancellation()
        guard maximumByteCount > 0, maximumElementCount > 0 else {
            throw NotebookRepositoryError.boundedReadLimitExceeded(
                relativePath: "note-replay-elements",
                limit: 0
            )
        }
        let active = try validatedActiveExportSession(session)
        let effectiveByteLimit = NoteReplayHistoryLimits.clampedElementByteCount(maximumByteCount)
        let effectiveElementLimit = NoteReplayHistoryLimits.clampedElementCount(maximumElementCount)
        guard active.authorizedReplayElementPayloads.contains(reference),
              reference.byteCount > 0,
              reference.byteCount <= effectiveByteLimit,
              let descriptor = active.assetDescriptorsByID[reference.assetID],
              descriptor.mediaType == NoteReplayPayloadCodec.elementsMediaType,
              descriptor.byteCount == Int64(reference.byteCount) else {
            throw NotebookRepositoryError.invalidAsset(reference.assetID)
        }
        let layout = try existingLayout(session.notebookID)
        let data = try readValidatedAssetData(
            descriptor,
            layout: layout,
            maximumBytes: effectiveByteLimit
        )
        let elements: [CanvasElement]
        do {
            try preflightCanvasElementArray(
                data,
                relativePath: "assets/\(reference.assetID.rawValue)",
                maximumElementCount: effectiveElementLimit
            )
            elements = try NoteReplayPayloadCodec.decodeElements(data)
            guard elements.count <= effectiveElementLimit else {
                throw NotebookRepositoryError.canvasElementLimitExceeded(
                    limit: effectiveElementLimit
                )
            }
            try validateCanvasElementsForExport(
                elements,
                validAssetIDs: Set(active.assetDescriptorsByID.keys),
                relativePath: "assets/\(reference.assetID.rawValue)"
            )
        } catch let error as NotebookRepositoryError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NotebookRepositoryError.corruptedFile(
                "assets/\(reference.assetID.rawValue)"
            )
        }
        try Task.checkCancellation()
        let revalidated = try validatedActiveExportSession(session)
        guard revalidated.authorizedReplayElementPayloads.contains(reference),
              revalidated.assetDescriptorsByID[reference.assetID] == descriptor else {
            throw NotebookRepositoryError.invalidExportSession
        }
        return NotebookExportCanvasElements(
            elements: elements,
            encodedByteCount: data.count
        )
    }

    public func saveAudioTranscript(
        _ transcript: AudioTranscriptDocument,
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> AudioSessionDescriptor {
        try Task.checkCancellation()
        let layout = try existingLayout(notebookID)
        var manifest = try readManifest(id: notebookID)
        guard let sessionIndex = manifest.audioSessions.firstIndex(where: { $0.id == sessionID }) else {
            throw NotebookRepositoryError.audioSessionNotFound(sessionID)
        }
        var session = manifest.audioSessions[sessionIndex]
        if let detail = audioDescriptorValidationDetail(session, manifest: manifest) {
            throw NotebookRepositoryError.invalidAudioSession(sessionID, detail: detail)
        }
        guard session.schemaVersion >= 2 else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "A transcript cannot be attached to a legacy audio-session schema."
            )
        }
        let timeline = try storedAudioTimeline(
            for: session,
            manifest: manifest,
            layout: layout
        )
        try validateAudioTranscript(transcript, descriptor: session, timeline: timeline)

        let transcriptData: Data
        do {
            transcriptData = try encode(transcript)
        } catch {
            throw NotebookRepositoryError.invalidAudioTranscript(
                sessionID,
                detail: "The transcript could not be encoded safely."
            )
        }
        guard transcriptData.count <= AudioTranscriptDocument.maximumEncodedBytes else {
            throw NotebookRepositoryError.invalidAudioTranscript(
                sessionID,
                detail: "The encoded transcript exceeds the storage limit."
            )
        }
        let assetID = AssetID(SHA256.hexDigest(transcriptData))
        let assetURL = layout.assetURL(assetID)
        let existingAsset = manifest.assets.first(where: { $0.id == assetID })
        var writes: [PlannedFileWrite] = []

        if let existingAsset {
            guard existingAsset.mediaType == AudioTranscriptDocument.mediaType else {
                throw NotebookRepositoryError.invalidAudioTranscript(
                    sessionID,
                    detail: "The content-addressed transcript asset has an unexpected media type."
                )
            }
            let existingData = try readValidatedAssetData(
                existingAsset,
                layout: layout,
                maximumBytes: AudioTranscriptDocument.maximumEncodedBytes
            )
            guard existingData == transcriptData else {
                throw NotebookRepositoryError.invalidAsset(assetID)
            }
        } else if fileSystemEntryExists(at: assetURL) {
            let existingData: Data
            do {
                existingData = try readBoundedRegularFileData(
                    at: assetURL,
                    within: layout.packageURL,
                    maximumBytes: AudioTranscriptDocument.maximumEncodedBytes
                )
            } catch {
                throw NotebookRepositoryError.invalidAsset(assetID)
            }
            guard existingData == transcriptData else {
                throw NotebookRepositoryError.invalidAsset(assetID)
            }
            manifest.assets.append(AssetDescriptor(
                id: assetID,
                mediaType: AudioTranscriptDocument.mediaType,
                originalFilename: "\(sessionID.description).transcript.json",
                byteCount: Int64(transcriptData.count)
            ))
        } else {
            manifest.assets.append(AssetDescriptor(
                id: assetID,
                mediaType: AudioTranscriptDocument.mediaType,
                originalFilename: "\(sessionID.description).transcript.json",
                byteCount: Int64(transcriptData.count)
            ))
            writes.append(PlannedFileWrite(
                url: assetURL,
                data: transcriptData,
                maximumByteCount: AudioTranscriptDocument.maximumEncodedBytes
            ))
        }

        if session.transcriptAssetID == assetID {
            // A content-addressed identical save is already durable. Avoid an
            // artificial revision while still verifying the complete payload.
            return session
        }

        let now = Date()
        session.modifiedAt = now
        session.transcriptAssetID = assetID
        manifest.audioSessions[sessionIndex] = session

        manifest.schemaVersion = NotebookManifest.currentSchemaVersion
        manifest.modifiedAt = now
        manifest.revision += 1
        let command = EditCommand(
            notebookID: notebookID,
            sequence: manifest.revision,
            timestamp: now,
            kind: .saveAudioTranscript,
            payload: [
                "audioSessionID": sessionID.description,
                "assetID": assetID.rawValue,
            ]
        )
        writes += try plannedManifestWrites(manifest, layout: layout, preservePrevious: true)
        try commitTransaction(
            command: command,
            expectedRevision: manifest.revision - 1,
            layout: layout,
            writes: writes
        )
        try? refreshDerivedLibraryIndex()
        emit(.init(
            notebookID: notebookID,
            kind: .audioTranscriptSaved,
            revision: manifest.revision,
            timestamp: now
        ))
        return session
    }

    public func loadAudioTranscript(
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> AudioTranscriptDocument? {
        try Task.checkCancellation()
        let layout = try existingLayout(notebookID)
        let manifest = try readManifest(id: notebookID)
        guard let session = manifest.audioSessions.first(where: { $0.id == sessionID }) else {
            throw NotebookRepositoryError.audioSessionNotFound(sessionID)
        }
        if let detail = audioDescriptorValidationDetail(session, manifest: manifest) {
            throw NotebookRepositoryError.invalidAudioSession(sessionID, detail: detail)
        }
        guard let assetID = session.transcriptAssetID else { return nil }
        guard let asset = manifest.assets.first(where: { $0.id == assetID }) else {
            throw NotebookRepositoryError.invalidAudioTranscript(
                sessionID,
                detail: "The transcript asset descriptor is missing."
            )
        }
        guard asset.mediaType == AudioTranscriptDocument.mediaType else {
            throw NotebookRepositoryError.invalidAudioTranscript(
                sessionID,
                detail: "The attached asset is not a NextStep audio transcript."
            )
        }
        let data = try readValidatedAssetData(
            asset,
            layout: layout,
            maximumBytes: AudioTranscriptDocument.maximumEncodedBytes
        )
        let transcript: AudioTranscriptDocument
        do {
            transcript = try decode(AudioTranscriptDocument.self, from: data)
        } catch {
            throw NotebookRepositoryError.invalidAudioTranscript(
                sessionID,
                detail: "The transcript JSON or schema is invalid."
            )
        }
        let timeline = try storedAudioTimeline(
            for: session,
            manifest: manifest,
            layout: layout
        )
        try validateAudioTranscript(transcript, descriptor: session, timeline: timeline)
        return transcript
    }

    public func loadAudioTranscriptForExport(
        session exportSession: NotebookExportSession,
        sessionID: AudioSessionID
    ) async throws -> AudioTranscriptDocument? {
        try Task.checkCancellation()
        let active = try validatedActiveExportSession(exportSession)
        let manifest = active.manifest
        guard let descriptor = manifest.audioSessions.first(where: { $0.id == sessionID }) else {
            throw NotebookRepositoryError.audioSessionNotFound(sessionID)
        }
        if let detail = audioDescriptorValidationDetail(descriptor, manifest: manifest) {
            throw NotebookRepositoryError.invalidAudioSession(sessionID, detail: detail)
        }
        guard let assetID = descriptor.transcriptAssetID else { return nil }
        guard let asset = active.assetDescriptorsByID[assetID] else {
            throw NotebookRepositoryError.invalidAudioTranscript(
                sessionID,
                detail: "The transcript asset descriptor is missing."
            )
        }
        guard asset.mediaType == AudioTranscriptDocument.mediaType else {
            throw NotebookRepositoryError.invalidAudioTranscript(
                sessionID,
                detail: "The attached asset is not a NextStep audio transcript."
            )
        }
        let layout = try existingLayout(exportSession.notebookID)
        let data = try readValidatedAssetData(
            asset,
            layout: layout,
            maximumBytes: AudioTranscriptDocument.maximumEncodedBytes
        )
        let transcript: AudioTranscriptDocument
        do {
            transcript = try decode(AudioTranscriptDocument.self, from: data)
        } catch {
            throw NotebookRepositoryError.invalidAudioTranscript(
                sessionID,
                detail: "The transcript JSON or schema is invalid."
            )
        }
        let timeline = try storedAudioTimeline(
            for: descriptor,
            manifest: manifest,
            layout: layout
        )
        try validateAudioTranscript(transcript, descriptor: descriptor, timeline: timeline)
        try Task.checkCancellation()
        let revalidated = try validatedActiveExportSession(exportSession)
        guard revalidated.manifest.audioSessions.first(where: { $0.id == sessionID }) == descriptor,
              revalidated.assetDescriptorsByID[assetID] == asset else {
            throw NotebookRepositoryError.invalidExportSession
        }
        return transcript
    }

    public func deleteAudioSession(notebookID: NotebookID, sessionID: AudioSessionID) async throws {
        try Task.checkCancellation()
        let layout = try existingLayout(notebookID)
        var manifest = try readManifest(id: notebookID)
        guard let index = manifest.audioSessions.firstIndex(where: { $0.id == sessionID }) else {
            throw NotebookRepositoryError.audioSessionNotFound(sessionID)
        }
        let manifestBeforeDeletion = manifest
        let descriptorBeforeDeletion = manifest.audioSessions[index]
        var removedReplayAssetIDs = Set<AssetID>()
        var replayGarbageCollectionIsSafe = true
        if descriptorBeforeDeletion.schemaVersion >= 3 {
            do {
                removedReplayAssetIDs = try storedNoteReplayAssetIDsForGarbageCollection(
                    descriptor: descriptorBeforeDeletion,
                    manifest: manifestBeforeDeletion,
                    layout: layout
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Deleting the recording remains possible, but damaged or partial
                // provenance must never authorize guessing which shared CAS bytes
                // are now unused.
                replayGarbageCollectionIsSafe = false
            }
        }
        let descriptor = manifest.audioSessions.remove(at: index)
        var remainingReplayAssetIDs = Set<AssetID>()
        if replayGarbageCollectionIsSafe, !removedReplayAssetIDs.isEmpty {
            for remainingDescriptor in manifest.audioSessions
                where remainingDescriptor.schemaVersion >= 3 {
                try Task.checkCancellation()
                do {
                    remainingReplayAssetIDs.formUnion(
                        try storedNoteReplayAssetIDsForGarbageCollection(
                            descriptor: remainingDescriptor,
                            manifest: manifestBeforeDeletion,
                            layout: layout
                        )
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    replayGarbageCollectionIsSafe = false
                    break
                }
            }
        }
        let remainingFilenameKeys = Set(
            manifest.audioSessions
                .flatMap(referencedAudioFilenames)
                .map(audioFilenameKey)
        )
        var scheduledFilenameKeys = Set<String>()
        var writes: [PlannedFileWrite] = []
        for filename in descriptor.chunkFilenames {
            let url = try safeAudioURL(filename: filename, layout: layout, expectedExtension: "m4a")
            let key = audioFilenameKey(filename)
            if !remainingFilenameKeys.contains(key),
               scheduledFilenameKeys.insert(key).inserted,
               fileSystemEntryExists(at: url) {
                writes.append(.deleting(url))
            }
        }
        if let timelineFilename = descriptor.timelineFilename {
            let url = try safeAudioURL(filename: timelineFilename, layout: layout, expectedExtension: "json")
            let key = audioFilenameKey(timelineFilename)
            if !remainingFilenameKeys.contains(key),
               scheduledFilenameKeys.insert(key).inserted,
               fileSystemEntryExists(at: url) {
                writes.append(.deleting(url))
            }
        }
        if let replayFilename = descriptor.replayFilename {
            let url = try safeAudioURL(filename: replayFilename, layout: layout, expectedExtension: "json")
            let key = audioFilenameKey(replayFilename)
            if !remainingFilenameKeys.contains(key),
               scheduledFilenameKeys.insert(key).inserted,
               fileSystemEntryExists(at: url) {
                writes.append(.deleting(url))
            }
        }

        var deletedReplayAssetCount = 0
        if replayGarbageCollectionIsSafe {
            let replayAssetIDsToDelete = removedReplayAssetIDs.subtracting(
                remainingReplayAssetIDs
            )
            deletedReplayAssetCount = try planReplayAssetGarbageCollection(
                candidates: replayAssetIDsToDelete,
                manifest: &manifest,
                layout: layout,
                writes: &writes
            )
        }

        let now = Date()
        manifest.schemaVersion = NotebookManifest.currentSchemaVersion
        manifest.modifiedAt = now
        manifest.revision += 1
        let command = EditCommand(
            notebookID: notebookID,
            sequence: manifest.revision,
            timestamp: now,
            kind: .deleteAudioSession,
            payload: [
                "audioSessionID": sessionID.description,
                "replayAssetsDeleted": String(deletedReplayAssetCount),
            ]
        )
        writes += try plannedManifestWrites(manifest, layout: layout, preservePrevious: true)
        try commitTransaction(
            command: command,
            expectedRevision: manifest.revision - 1,
            layout: layout,
            writes: writes
        )
        try? refreshDerivedLibraryIndex()
        emit(.init(
            notebookID: notebookID,
            kind: .audioSessionDeleted,
            revision: manifest.revision,
            timestamp: now
        ))
    }

    public func operationLog(notebookID: NotebookID) async throws -> [EditCommand] {
        let layout = try existingLayout(notebookID)
        try resolvePendingTransactions(layout: layout)
        return try readOperationLog(layout: layout)
    }

    public func exportSnapshot(id: NotebookID, to destinationURL: URL) async throws -> URL {
        let layout = try existingLayout(id)
        try resolvePendingTransactions(layout: layout)

        let source = layout.packageURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        guard source != destination,
              !isURL(destination, inside: source),
              !isURL(source, inside: destination) else {
            throw NotebookRepositoryError.invalidSnapshotDestination
        }

        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        let staging = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).snapshot",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.copyItem(at: source, to: staging)

        let snapshotLayout = NotebookPackageLayout(packageURL: staging)
        let validation = validate(id: id, layout: snapshotLayout)
        guard validation.isValid else {
            let details = validation.issues.map { "\($0.relativePath): \($0.detail)" }.joined(separator: "; ")
            throw NotebookRepositoryError.malformedPackage("Snapshot validation failed. \(details)")
        }

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: staging,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
        return destination
    }

    @discardableResult
    public func rebuildLibraryIndex() async throws -> [NotebookManifest] {
        try resolveLibraryTransactions()
        let manifests = try scanValidManifests()
        try writeLibraryIndex(manifests)
        emit(.init(notebookID: nil, kind: .rebuilt))
        return manifests
    }

    public func validateNotebook(id: NotebookID) async throws -> ValidationReport {
        let layout = try existingLayout(id)
        return validate(id: id, layout: layout)
    }

    public func recoverNotebook(id: NotebookID) async throws -> RecoveryReport {
        let layout = try existingLayout(id)
        invalidateExportSessions(for: id)
        try ensureSafeDirectory(layout.pagesURL, within: layout.packageURL)
        if fileSystemEntryExists(at: layout.audioURL) {
            try ensureSafeDirectory(layout.audioURL, within: layout.packageURL)
        }
        try rejectUnsupportedFutureSchemas(in: layout)
        if !fileSystemEntryExists(at: layout.audioURL) {
            try FileManager.default.createDirectory(
                at: layout.audioURL,
                withIntermediateDirectories: false,
                attributes: nil
            )
        }
        try ensureSafeDirectory(layout.audioURL, within: layout.packageURL)
        var actions: [RecoveryAction] = []
        try resolvePendingTransactions(layout: layout, actions: &actions)
        let transactionActionCount = actions.count
        let temporaryFiles = findTemporaryFiles(in: layout.packageURL)
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
            actions.append(.removedTemporaryFile)
        }
        if let operationURLs = try? FileManager.default.contentsOfDirectory(
            at: layout.operationsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for operationURL in operationURLs where operationURL.pathExtension == "json" {
                guard (try? decode(EditCommand.self, from: Data(contentsOf: operationURL))) == nil else { continue }
                let quarantinedURL = operationURL.appendingPathExtension("corrupt")
                try? FileManager.default.removeItem(at: quarantinedURL)
                try FileManager.default.moveItem(at: operationURL, to: quarantinedURL)
                actions.append(.removedUnreadableOperation)
            }
        }

        let fileManager = FileManager.default
        var sourceManifestWasValid = false
        var manifest: NotebookManifest
        if let current = try? decode(NotebookManifest.self, from: Data(contentsOf: layout.manifestURL)), current.id == id {
            manifest = current
            sourceManifestWasValid = true
        } else if let backup = try? decode(NotebookManifest.self, from: Data(contentsOf: layout.backupManifestURL)), backup.id == id {
            manifest = backup
            actions.append(.restoredBackupManifest)
        } else {
            let pages = scanPageDescriptors(layout: layout)
            let createdAt = pages.map(\.createdAt).min() ?? Date()
            let lastSequence = (try? readOperationLog(layout: layout).map(\.sequence).max()) ?? 0
            manifest = NotebookManifest(
                id: id,
                title: "Recovered Notebook",
                createdAt: createdAt,
                modifiedAt: Date(),
                revision: lastSequence,
                pages: pages
            )
            actions.append(.reconstructedManifest)
        }

        var seenPageIDs = Set<PageID>()
        var repairedPages: [PageDescriptor] = []
        for page in manifest.pages {
            guard seenPageIDs.insert(page.id).inserted else {
                actions.append(.removedDuplicatePage)
                continue
            }
            let pageDirectory = layout.pageURL(page.id)
            guard !isSymbolicLinkEntry(at: pageDirectory),
                  fileManager.fileExists(atPath: pageDirectory.path) else {
                actions.append(.removedMissingPage)
                continue
            }
            let descriptorURL = layout.pageDescriptorURL(page.id)
            if let diskPage = try? readStoredPageDescriptor(
                at: descriptorURL,
                layout: layout
            ), diskPage.id == page.id {
                repairedPages.append(diskPage)
                if diskPage != page {
                    // A valid page.json is the explicit recovery authority.
                    // Record the reconciliation so the repaired manifest is
                    // durably rewritten instead of returning an in-memory-only
                    // result that immediately fails validation again.
                    actions.append(.reconciledPageDescriptor)
                }
            } else {
                try writeJSON(page, to: descriptorURL)
                repairedPages.append(page)
                actions.append(.restoredPageDescriptor)
            }
        }

        let deletedPageIDs = Set(
            (try? readOperationLog(layout: layout))?
                .filter { $0.kind == .deletePage }
                .compactMap { $0.pageID } ?? []
        )
        for page in scanPageDescriptors(layout: layout) where !seenPageIDs.contains(page.id) {
            if deletedPageIDs.contains(page.id) {
                try? fileManager.removeItem(at: layout.pageURL(page.id))
                actions.append(.removedOrphanPage)
            } else {
                try writeJSON(page, to: layout.pageDescriptorURL(page.id))
                repairedPages.append(page)
                seenPageIDs.insert(page.id)
                actions.append(.adoptedOrphanPage)
            }
        }
        let repairedPageIDs = Set(repairedPages.map(\.id))
        if let pageDirectories = try? fileManager.contentsOfDirectory(
            at: layout.pagesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for directory in pageDirectories {
                guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let uuid = UUID(uuidString: directory.lastPathComponent),
                      !repairedPageIDs.contains(PageID(uuid)) else { continue }
                try fileManager.removeItem(at: directory)
                actions.append(.removedOrphanPage)
            }
        }

        var repairedAssets: [AssetDescriptor] = []
        for asset in manifest.assets {
            let url = layout.assetURL(asset.id)
            let boundedAssetMaximum: Int? = switch asset.mediaType {
            case AudioTranscriptDocument.mediaType:
                AudioTranscriptDocument.maximumEncodedBytes
            case NoteReplayPayloadCodec.inkMediaType:
                NoteReplayHistoryLimits.maximumInkPayloadBytes
            case NoteReplayPayloadCodec.elementsMediaType:
                NoteReplayHistoryLimits.maximumElementPayloadBytes
            default:
                nil
            }
            let data: Data? = if let boundedAssetMaximum {
                try? readBoundedRegularFileData(
                    at: url,
                    within: layout.packageURL,
                    maximumBytes: boundedAssetMaximum
                )
            } else {
                try? Data(contentsOf: url, options: .mappedIfSafe)
            }
            guard let data,
                  Int64(data.count) == asset.byteCount,
                  SHA256.hexDigest(data) == asset.id.rawValue else {
                actions.append(.removedInvalidAssetReference)
                continue
            }
            if !repairedAssets.contains(where: { $0.id == asset.id }) {
                repairedAssets.append(asset)
            }
        }
        if let assetURLs = try? fileManager.contentsOfDirectory(
            at: layout.assetsURL,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let hexadecimal = CharacterSet(charactersIn: "0123456789abcdef")
            for assetURL in assetURLs {
                let filename = assetURL.lastPathComponent.lowercased()
                guard filename.count == 64,
                      filename.unicodeScalars.allSatisfy({ hexadecimal.contains($0) }),
                      let data = try? Data(contentsOf: assetURL, options: .mappedIfSafe),
                      SHA256.hexDigest(data) == filename else { continue }
                let assetID = AssetID(filename)
                guard !repairedAssets.contains(where: { $0.id == assetID }) else { continue }
                let values = try? assetURL.resourceValues(forKeys: [.creationDateKey])
                repairedAssets.append(.init(
                    id: assetID,
                    mediaType: "application/octet-stream",
                    originalFilename: nil,
                    byteCount: Int64(data.count),
                    createdAt: values?.creationDate ?? Date()
                ))
                actions.append(.adoptedOrphanAsset)
            }
        }

        var audioValidationManifest = manifest
        audioValidationManifest.pages = repairedPages
        audioValidationManifest.assets = repairedAssets
        var repairedAudioSessions: [AudioSessionDescriptor] = []
        var acceptedAudioSessionIDs = Set<AudioSessionID>()
        var acceptedAudioFilenameKeys = Set<String>()
        var acceptedAudioFilenamesByKey: [String: String] = [:]
        for originalSession in manifest.audioSessions {
            var session = originalSession
            if session.recordingStartedAt != nil {
                var sessionWithoutReplayMetadata = session
                sessionWithoutReplayMetadata.recordingStartedAt = nil
                let replayMetadataIsValid = session.schemaVersion >= 2
                    && (try? storedAudioTimeline(
                        for: session,
                        manifest: audioValidationManifest,
                        layout: layout
                    )) != nil
                let timelineIsOtherwiseValid = session.schemaVersion < 2
                    || (try? storedAudioTimeline(
                        for: sessionWithoutReplayMetadata,
                        manifest: audioValidationManifest,
                        layout: layout
                    )) != nil
                if !replayMetadataIsValid, timelineIsOtherwiseValid {
                    session = sessionWithoutReplayMetadata
                    actions.append(.removedInvalidAudioReplayMetadata)
                }
            }
            if let transcriptAssetID = session.transcriptAssetID,
               !(audioValidationManifest.assets.first(where: {
                   $0.id == transcriptAssetID
                       && $0.mediaType == AudioTranscriptDocument.mediaType
               }).map {
                   storedAudioTranscriptIsValid(
                       descriptor: session,
                       asset: $0,
                       manifest: audioValidationManifest,
                       layout: layout
                   )
               } ?? false) {
                session.transcriptAssetID = nil
                actions.append(.removedInvalidAssetReference)
            }
            let filenames = referencedAudioFilenames(session)
            let completeSessionIsValid = storedAudioSessionIsValid(
                session,
                manifest: audioValidationManifest,
                layout: layout
            )
            var baseAudioIsValid = false
            if !completeSessionIsValid, session.schemaVersion >= 3 {
                var sessionWithoutHistory = session
                sessionWithoutHistory.schemaVersion = 2
                sessionWithoutHistory.replayFilename = nil
                sessionWithoutHistory.replayByteCount = nil
                sessionWithoutHistory.replaySHA256 = nil
                sessionWithoutHistory.replayEventCount = nil
                baseAudioIsValid = storedAudioSessionIsValid(
                    sessionWithoutHistory,
                    manifest: audioValidationManifest,
                    layout: layout
                )
            }
            guard !acceptedAudioSessionIDs.contains(session.id),
                  filenames.count == session.chunkFilenames.count
                    + (session.timelineFilename == nil ? 0 : 1)
                    + (session.replayFilename == nil ? 0 : 1),
                  Set(filenames.map(audioFilenameKey)).count == filenames.count,
                  filenames.allSatisfy({ !acceptedAudioFilenameKeys.contains(audioFilenameKey($0)) }),
                  completeSessionIsValid || baseAudioIsValid else {
                actions.append(.removedInvalidAudioSession)
                continue
            }
            if baseAudioIsValid {
                actions.append(.preservedUnavailableAudioReplayHistory)
            }
            repairedAudioSessions.append(session)
            acceptedAudioSessionIDs.insert(session.id)
            acceptedAudioFilenameKeys.formUnion(filenames.map(audioFilenameKey))
            for filename in filenames {
                acceptedAudioFilenamesByKey[audioFilenameKey(filename)] = filename
            }
        }
        if let audioEntries = try? fileManager.contentsOfDirectory(
            at: layout.audioURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) {
            let visibleEntries = audioEntries.filter {
                !$0.lastPathComponent.hasPrefix(".recovered-")
            }
            for (key, entries) in Dictionary(grouping: visibleEntries, by: {
                audioFilenameKey($0.lastPathComponent)
            }) {
                let keptEntry: URL? = if acceptedAudioFilenameKeys.contains(key) {
                    entries.first(where: {
                        $0.lastPathComponent == acceptedAudioFilenamesByKey[key]
                    }) ?? entries.first
                } else {
                    nil
                }
                for entry in entries {
                    if let keptEntry, entry == keptEntry { continue }
                    try quarantineAudioEntry(at: entry, layout: layout)
                    actions.append(.quarantinedOrphanAudio)
                }
            }
        }

        if manifest.schemaVersion < NotebookManifest.currentSchemaVersion {
            manifest.schemaVersion = NotebookManifest.currentSchemaVersion
            actions.append(.migratedSchema)
        }
        manifest.pages = repairedPages
        manifest.assets = repairedAssets
        manifest.audioSessions = repairedAudioSessions
        var migratedPageSchema = false
        for index in manifest.pages.indices
        where manifest.pages[index].schemaVersion < PageDescriptor.currentSchemaVersion {
            manifest.pages[index].schemaVersion = PageDescriptor.currentSchemaVersion
            try writeJSON(manifest.pages[index], to: layout.pageDescriptorURL(manifest.pages[index].id))
            migratedPageSchema = true
        }
        if migratedPageSchema, !actions.contains(.migratedSchema) {
            actions.append(.migratedSchema)
        }
        for page in manifest.pages {
            let elementsURL = layout.elementsURL(page.id)
            if !fileManager.fileExists(atPath: elementsURL.path)
                || (try? decode([CanvasElement].self, from: Data(contentsOf: elementsURL))) == nil {
                try writeJSON([CanvasElement](), to: elementsURL)
                actions.append(.resetUnreadableElements)
            }

            let recognitionURL = layout.handwritingRecognitionURL(page.id)
            if fileSystemEntryExists(at: recognitionURL) {
                do {
                    let data = try readBoundedRegularFileData(
                        at: recognitionURL,
                        within: layout.packageURL,
                        maximumBytes: HandwritingRecognitionLimits.maximumEncodedBytes
                    )
                    let document = try decode(
                        HandwritingRecognitionDocument.self,
                        from: data
                    )
                    try document.validate(expectedPageID: page.id)
                } catch let validationError as HandwritingRecognitionValidationError {
                    if case .futureSchemaVersion = validationError {
                        throw NotebookRepositoryError.malformedPackage(
                            "This notebook requires a newer handwriting-recognition schema."
                        )
                    }
                    try quarantineHandwritingRecognition(at: recognitionURL)
                    actions.append(.quarantinedInvalidHandwritingRecognition)
                } catch let repositoryError as NotebookRepositoryError {
                    if case .malformedPackage = repositoryError {
                        throw repositoryError
                    }
                    try quarantineHandwritingRecognition(at: recognitionURL)
                    actions.append(.quarantinedInvalidHandwritingRecognition)
                } catch {
                    try quarantineHandwritingRecognition(at: recognitionURL)
                    actions.append(.quarantinedInvalidHandwritingRecognition)
                }
            }

            let contentURL = layout.contentURL(page.id)
            guard let emptyContent = PageContent.empty(for: page.kind) else {
                if fileSystemEntryExists(at: contentURL) {
                    try quarantinePageContent(at: contentURL)
                    actions.append(.quarantinedUnexpectedPageContent)
                }
                continue
            }
            guard fileSystemEntryExists(at: contentURL) else {
                try writeJSON(emptyContent, to: contentURL)
                actions.append(.createdMissingPageContent)
                continue
            }
            guard let storedContent = try? decode(
                PageContent.self,
                from: readStructuredContentData(at: contentURL, within: layout.packageURL)
            ) else {
                try quarantinePageContent(at: contentURL)
                try writeJSON(emptyContent, to: contentURL)
                actions.append(.resetUnreadablePageContent)
                continue
            }
            guard storedContent.pageKind == page.kind else {
                try quarantinePageContent(at: contentURL)
                try writeJSON(emptyContent, to: contentURL)
                actions.append(.resetMismatchedPageContent)
                continue
            }
            if structuredContentValidationDetail(storedContent) != nil {
                try quarantinePageContent(at: contentURL)
                try writeJSON(emptyContent, to: contentURL)
                actions.append(.resetInvalidPageContent)
            }
        }
        // Finalizing or rolling back an existing transaction already leaves the
        // manifest at its authoritative revision. Do not manufacture an extra
        // revision merely because transaction recovery was reported.
        if actions.count > transactionActionCount {
            manifest.modifiedAt = Date()
            manifest.revision += 1
            try writeManifest(manifest, layout: layout, preservePrevious: sourceManifestWasValid)
        }
        let validation = validate(id: id, layout: layout)
        try? refreshDerivedLibraryIndex()
        emit(.init(notebookID: id, kind: .recovered, revision: manifest.revision))
        return RecoveryReport(manifest: manifest, actions: actions, validation: validation)
    }
}

// MARK: - Storage internals

private extension FileNotebookRepository {
    struct PlannedFileWrite: Sendable {
        var url: URL
        var data: Data
        var streamingAudioSource: AudioStreamSource?
        var deletesTarget: Bool
        var maximumByteCount: Int?

        init(
            url: URL,
            data: Data,
            deletesTarget: Bool = false,
            maximumByteCount: Int? = nil
        ) {
            self.url = url
            self.data = data
            self.streamingAudioSource = nil
            self.deletesTarget = deletesTarget
            self.maximumByteCount = maximumByteCount
        }

        init(streamingAudioTo url: URL, source: AudioStreamSource) {
            self.url = url
            self.data = Data()
            self.streamingAudioSource = source
            self.deletesTarget = false
            self.maximumByteCount = nil
        }

        static func deleting(
            _ url: URL,
            maximumByteCount: Int? = nil
        ) -> PlannedFileWrite {
            PlannedFileWrite(
                url: url,
                data: Data(),
                deletesTarget: true,
                maximumByteCount: maximumByteCount
            )
        }

    }

    struct AudioSourceIdentity: Equatable, Sendable {
        var device: UInt64
        var inode: UInt64
        var linkCount: UInt64
        var byteCount: Int64
        var allocatedBlockCount: Int64
        var modificationSeconds: Int64
        var modificationNanoseconds: Int64
        var statusChangeSeconds: Int64
        var statusChangeNanoseconds: Int64
    }

    struct ManifestFileIdentity: Equatable, Sendable {
        var device: UInt64
        var inode: UInt64
        var linkCount: UInt64
        var byteCount: Int64
        var modificationSeconds: Int64
        var modificationNanoseconds: Int64
        var statusChangeSeconds: Int64
        var statusChangeNanoseconds: Int64
    }

    /// Descriptor identity used to fence exact text-source snapshots. Unlike
    /// ordinary editing reads, source anchors reject multiply-linked files and
    /// revalidate the path after all constituent files have been decoded.
    struct SourceSnapshotFileIdentity: Equatable, Sendable {
        var device: UInt64
        var inode: UInt64
        var linkCount: UInt64
        var byteCount: Int64
        var modificationSeconds: Int64
        var modificationNanoseconds: Int64
        var statusChangeSeconds: Int64
        var statusChangeNanoseconds: Int64
    }

    struct BoundedSourceSnapshotFile: Sendable {
        var data: Data
        var identity: SourceSnapshotFileIdentity
    }

    struct PackageDirectoryIdentity: Equatable, Sendable {
        var device: UInt64
        var inode: UInt64
    }

    struct LoadedBoundedExportManifest: Sendable {
        var manifest: NotebookManifest
        var manifestIdentity: ManifestFileIdentity
        var packageIdentity: PackageDirectoryIdentity
    }

    struct ActiveNotebookExportSession: Sendable {
        var token: NotebookExportSession
        var manifest: NotebookManifest
        var pageIDs: Set<PageID>
        var assetDescriptorsByID: [AssetID: AssetDescriptor]
        var authorizedReplayInkPayloads: Set<NoteReplayPayloadReference>
        var authorizedReplayElementPayloads: Set<NoteReplayPayloadReference>
        var manifestIdentity: ManifestFileIdentity
        var packageIdentity: PackageDirectoryIdentity
    }

    enum NoteReplayPayloadRole: Equatable, Sendable {
        case ink
        case elements

        var mediaType: String {
            switch self {
            case .ink: NoteReplayPayloadCodec.inkMediaType
            case .elements: NoteReplayPayloadCodec.elementsMediaType
            }
        }

        var maximumByteCount: Int {
            switch self {
            case .ink: NoteReplayHistoryLimits.maximumInkPayloadBytes
            case .elements: NoteReplayHistoryLimits.maximumElementPayloadBytes
            }
        }
    }

    struct PreparedNoteReplayHistory: Sendable {
        var indexData: Data
        var payloadWrites: [PlannedFileWrite]
    }

    struct AudioStreamSource: Sendable {
        var url: URL
        var sessionID: AudioSessionID
        var maximumByteCount: Int64
        var identity: AudioSourceIdentity
        var byteCount: Int64
        var sha256: String
    }

    enum TransactionPhase: String, Codable, Sendable {
        case prepared
        case stateCommitted
    }

    struct TransactionFile: Codable, Sendable {
        var relativePath: String
        var stagedFilename: String
        var backupFilename: String?
        var existedBeforeTransaction: Bool
        /// Optional so schema-v1 journals created by earlier releases still decode.
        var deletesTarget: Bool? = nil
        /// Optional integrity metadata for streamed audio staged by newer builds.
        var stagedByteCount: Int64? = nil
        var stagedSHA256: String? = nil
        /// Optional per-write bound used by content-addressed asset transactions.
        /// The field is additive so existing schema-v1 journals remain decodable.
        var maximumByteCount: Int? = nil
    }

    struct TransactionRecord: Codable, Sendable {
        static let currentSchemaVersion = 1

        var schemaVersion: Int
        var command: EditCommand
        var expectedRevision: Int64
        var targetRevision: Int64
        var phase: TransactionPhase
        var createdAt: Date
        var files: [TransactionFile]
        var cleanupDirectories: [String]

        init(
            command: EditCommand,
            expectedRevision: Int64,
            files: [TransactionFile],
            cleanupDirectories: [String]
        ) {
            self.schemaVersion = Self.currentSchemaVersion
            self.command = command
            self.expectedRevision = expectedRevision
            self.targetRevision = command.sequence
            self.phase = .prepared
            self.createdAt = Date()
            self.files = files
            self.cleanupDirectories = cleanupDirectories
        }
    }

    struct LibraryIndex: Codable {
        var schemaVersion: Int
        var generatedAt: Date
        var notebooks: [NotebookManifest]
    }

    enum StructuredContentLimits {
        static let maximumBlocks = 25_000
        static let maximumCards = 25_000
        static let maximumProgressEntries = 25_000
        static let maximumUTF8BytesPerField = 1 * 1_024 * 1_024
        static let maximumUTF8BytesPerPage = 8 * 1_024 * 1_024
        static let maximumEncodedBytes = 16 * 1_024 * 1_024
        static let maximumTagsPerCard = 100
        static let maximumIndentationLevel = 32
        static let maximumStudyCounter = 1_000_000
        static let maximumStudyIntervalDays = 36_500
    }

    enum PageDescriptorStorageLimits {
        static let maximumEncodedBytes = 2 * 1_024 * 1_024
    }

    enum AudioStorageLimits {
        static let maximumAudioBytes = 512 * 1_024 * 1_024
        static let maximumTimelineBytes = 4 * 1_024 * 1_024
        static let maximumReadChunkBytes = 4 * 1_024 * 1_024
        static let maximumTimelineMarks = 100_000
        static let maximumDurationSeconds: Double = 7 * 24 * 60 * 60
    }

    func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    func emit(_ change: NotebookChange) {
        for continuation in observers.values {
            continuation.yield(change)
        }
    }

    func normalizedTitle(_ title: String) throws -> String {
        let result = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw NotebookRepositoryError.invalidTitle }
        return result
    }

    func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.compactMap { tag in
            let clean = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, seen.insert(clean).inserted else { return nil }
            return clean
        }
    }

    func validatePageNavigationMetadata(
        pageID: PageID,
        outlineTitle: String?
    ) throws {
        guard PageDescriptor.isValidOutlineTitle(outlineTitle) else {
            throw NotebookRepositoryError.invalidPageNavigationMetadata(
                pageID: pageID,
                detail: "The outline title must be canonical, single-line text containing 1...\(PageDescriptor.maximumOutlineTitleCharacters) characters, at most \(PageDescriptor.maximumOutlineTitleUTF8Bytes) UTF-8 bytes, and no newline or unsafe control/format scalars (Unicode ZWNJ/ZWJ are allowed)."
            )
        }
    }

    func readStoredHandwritingRecognition(
        pageID: PageID,
        layout: NotebookPackageLayout
    ) throws -> HandwritingRecognitionDocument? {
        let url = layout.handwritingRecognitionURL(pageID)
        guard let data = try readBoundedRegularFileDataIfPresent(
            at: url,
            within: layout.packageURL,
            maximumBytes: HandwritingRecognitionLimits.maximumEncodedBytes
        ) else {
            return nil
        }
        do {
            let document = try decode(HandwritingRecognitionDocument.self, from: data)
            try document.validate(expectedPageID: pageID)
            return document
        } catch {
            throw NotebookRepositoryError.invalidHandwritingRecognition(
                pageID: pageID,
                detail: error.localizedDescription
            )
        }
    }

    func handwritingRecognitionRunIsUnchanged(
        from stored: HandwritingRecognitionDocument,
        to replacement: HandwritingRecognitionDocument
    ) -> Bool {
        stored.schemaVersion == replacement.schemaVersion
            && stored.runID == replacement.runID
            && stored.pageID == replacement.pageID
            && stored.sourceInkSHA256 == replacement.sourceInkSHA256
            && stored.engineIdentifier == replacement.engineIdentifier
            && stored.engineRevision == replacement.engineRevision
            && stored.languages == replacement.languages
            && stored.generatedAt == replacement.generatedAt
            && stored.machineCandidates == replacement.machineCandidates
    }

    func handwritingRecognitionValidationIssue(
        pageID: PageID,
        layout: NotebookPackageLayout
    ) -> ValidationIssue? {
        let url = layout.handwritingRecognitionURL(pageID)
        let path = relativePath(of: url, in: layout.packageURL)
        guard fileSystemEntryExists(at: url) else { return nil }

        let data: Data
        do {
            data = try readBoundedRegularFileData(
                at: url,
                within: layout.packageURL,
                maximumBytes: HandwritingRecognitionLimits.maximumEncodedBytes
            )
        } catch {
            return .init(
                kind: .unreadableHandwritingRecognition,
                relativePath: path,
                detail: "The handwriting-recognition sidecar cannot be read safely."
            )
        }

        let document: HandwritingRecognitionDocument
        do {
            document = try decode(HandwritingRecognitionDocument.self, from: data)
        } catch let validationError as HandwritingRecognitionValidationError {
            if case .futureSchemaVersion(let found, _) = validationError {
                return .init(
                    kind: .unsupportedHandwritingRecognitionSchema,
                    relativePath: path,
                    detail: "Handwriting-recognition schema \(found) requires a newer version of NextStep."
                )
            }
            return .init(
                kind: .invalidHandwritingRecognition,
                relativePath: path,
                detail: validationError.localizedDescription
            )
        } catch {
            return .init(
                kind: .unreadableHandwritingRecognition,
                relativePath: path,
                detail: "The handwriting-recognition sidecar cannot be decoded."
            )
        }
        do {
            try document.validate(expectedPageID: pageID)
        } catch let validationError as HandwritingRecognitionValidationError {
            if case .futureSchemaVersion(let found, _) = validationError {
                return .init(
                    kind: .unsupportedHandwritingRecognitionSchema,
                    relativePath: path,
                    detail: "Handwriting-recognition schema \(found) requires a newer version of NextStep."
                )
            }
            return .init(
                kind: .invalidHandwritingRecognition,
                relativePath: path,
                detail: validationError.localizedDescription
            )
        } catch {
            return .init(
                kind: .invalidHandwritingRecognition,
                relativePath: path,
                detail: error.localizedDescription
            )
        }

        do {
            guard let ink = try readBoundedRegularFileDataIfPresent(
                at: layout.inkURL(pageID),
                within: layout.packageURL,
                maximumBytes: NotebookHandwritingRecognitionReadLimits.maximumInkBytes
            ), SHA256.hexDigest(ink) == document.sourceInkSHA256 else {
                return .init(
                    kind: .staleHandwritingRecognition,
                    relativePath: path,
                    detail: "The sidecar was produced from different or missing ink."
                )
            }
        } catch {
            return .init(
                kind: .staleHandwritingRecognition,
                relativePath: path,
                detail: "The current ink cannot be safely compared with this sidecar."
            )
        }
        return nil
    }

    func validateCanvasElementsForExport(
        _ elements: [CanvasElement],
        validAssetIDs: Set<AssetID>,
        relativePath: String
    ) throws {
        guard elements.count <= NotebookExportReadLimits.maximumCanvasElementCount else {
            throw NotebookRepositoryError.canvasElementLimitExceeded(
                limit: NotebookExportReadLimits.maximumCanvasElementCount
            )
        }

        var identifiers = Set<ElementID>()
        identifiers.reserveCapacity(elements.count)
        var totalStringBytes = 0
        var totalTextUnits = 0

        func validateString(_ value: String?, maximumUTF16Units: Int) throws {
            guard let value else { return }
            let count = value.utf8.count
            let utf16Count = (value as NSString).length
            guard count <= NotebookExportReadLimits.maximumCanvasStringUTF8BytesPerField,
                  totalStringBytes <= NotebookExportReadLimits.maximumCanvasStringUTF8BytesPerPage - count,
                  utf16Count <= maximumUTF16Units,
                  totalTextUnits <= NotebookExportReadLimits.maximumCanvasTextUTF16UnitsPerPage - utf16Count else {
                throw NotebookRepositoryError.corruptedFile(relativePath)
            }
            totalStringBytes += count
            totalTextUnits += utf16Count
        }

        func isSafeNumber(_ value: Double) -> Bool {
            value.isFinite
                && abs(value) <= NotebookExportReadLimits.maximumCanvasGeometryMagnitude
        }

        func isSafeColor(_ color: RGBAColor) -> Bool {
            [color.red, color.green, color.blue, color.alpha].allSatisfy {
                $0.isFinite && (0...1).contains($0)
            }
        }

        for element in elements {
            try Task.checkCancellation()
            guard identifiers.insert(element.id).inserted,
                  [element.frame.x, element.frame.y, element.frame.width, element.frame.height]
                    .allSatisfy(isSafeNumber),
                  element.frame.width >= 0,
                  element.frame.height >= 0,
                  isSafeNumber(element.rotationRadians),
                  element.opacity.isFinite,
                  (0...1).contains(element.opacity),
                  element.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  element.modifiedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw NotebookRepositoryError.corruptedFile(relativePath)
            }

            switch element.content {
            case .text(let text):
                try validateString(
                    text.text,
                    maximumUTF16Units: NotebookExportReadLimits.maximumCanvasTextUTF16UnitsPerField
                )
                try validateString(
                    text.fontName,
                    maximumUTF16Units: NotebookExportReadLimits.maximumCanvasFontNameUTF16Units
                )
                guard text.fontSize.isFinite,
                      text.fontSize > 0,
                      text.fontSize <= NotebookExportReadLimits.maximumCanvasFontSize,
                      isSafeColor(text.color) else {
                    throw NotebookRepositoryError.corruptedFile(relativePath)
                }
            case .image(let image):
                try validateString(
                    image.assetID.rawValue,
                    maximumUTF16Units: NotebookExportReadLimits.maximumCanvasTokenUTF16Units
                )
                try validateString(
                    image.contentMode,
                    maximumUTF16Units: NotebookExportReadLimits.maximumCanvasTokenUTF16Units
                )
                guard image.assetID.isSHA256Digest,
                      validAssetIDs.contains(image.assetID) else {
                    throw NotebookRepositoryError.corruptedFile(relativePath)
                }
            case .shape(let shape):
                try validateString(
                    shape.shape,
                    maximumUTF16Units: NotebookExportReadLimits.maximumCanvasTokenUTF16Units
                )
                guard isSafeColor(shape.strokeColor),
                      shape.fillColor.map(isSafeColor) ?? true,
                      shape.lineWidth.isFinite,
                      shape.lineWidth >= 0,
                      shape.lineWidth <= NotebookExportReadLimits.maximumCanvasLineWidth else {
                    throw NotebookRepositoryError.corruptedFile(relativePath)
                }
            case .connector(let connector):
                try validateString(
                    connector.endCap,
                    maximumUTF16Units: NotebookExportReadLimits.maximumCanvasTokenUTF16Units
                )
                guard [connector.start.x, connector.start.y, connector.end.x, connector.end.y]
                    .allSatisfy(isSafeNumber),
                    isSafeColor(connector.strokeColor),
                    connector.lineWidth.isFinite,
                    connector.lineWidth >= 0,
                    connector.lineWidth <= NotebookExportReadLimits.maximumCanvasLineWidth else {
                    throw NotebookRepositoryError.corruptedFile(relativePath)
                }
            case .stickyNote(let note):
                try validateString(
                    note.text,
                    maximumUTF16Units: NotebookExportReadLimits.maximumCanvasTextUTF16UnitsPerField
                )
                guard isSafeColor(note.color) else {
                    throw NotebookRepositoryError.corruptedFile(relativePath)
                }
            case .tape(let tape):
                guard isSafeColor(tape.color) else {
                    throw NotebookRepositoryError.corruptedFile(relativePath)
                }
            case .sticker(let sticker):
                try validateString(
                    sticker.assetID.rawValue,
                    maximumUTF16Units: NotebookExportReadLimits.maximumCanvasTokenUTF16Units
                )
                try validateString(
                    sticker.accessibilityLabel,
                    maximumUTF16Units: NotebookExportReadLimits.maximumCanvasTextUTF16UnitsPerField
                )
                guard sticker.assetID.isSHA256Digest,
                      validAssetIDs.contains(sticker.assetID) else {
                    throw NotebookRepositoryError.corruptedFile(relativePath)
                }
            case .link(let link):
                try validateString(
                    link.title,
                    maximumUTF16Units: NotebookExportReadLimits.maximumCanvasTextUTF16UnitsPerField
                )
                try validateString(
                    link.destination.absoluteString,
                    maximumUTF16Units: NotebookExportReadLimits.maximumCanvasURLUTF16Units
                )
            }
        }
    }

    func readValidatedAssetForExport(
        _ descriptor: AssetDescriptor,
        layout: NotebookPackageLayout,
        maximumBytes: Int
    ) throws -> Data {
        let assetID = descriptor.id
        guard assetID.isSHA256Digest,
              descriptor.byteCount >= 0 else {
            throw NotebookRepositoryError.invalidAsset(assetID)
        }
        let url = layout.assetURL(assetID)
        let assetRelativePath = relativePath(of: url, in: layout.packageURL)
        guard descriptor.byteCount <= Int64(maximumBytes) else {
            throw NotebookRepositoryError.boundedReadLimitExceeded(
                relativePath: assetRelativePath,
                limit: maximumBytes
            )
        }
        guard let data = try readBoundedRegularFileDataIfPresent(
            at: url,
            within: layout.packageURL,
            maximumBytes: maximumBytes
        ) else {
            throw NotebookRepositoryError.invalidAsset(assetID)
        }
        guard Int64(data.count) == descriptor.byteCount else {
            throw NotebookRepositoryError.invalidAsset(assetID)
        }
        let digest = try cancellableAssetDigestForExport(
            data,
            relativePath: assetRelativePath
        )
        guard digest == assetID.rawValue else {
            throw NotebookRepositoryError.invalidAsset(assetID)
        }
        return data
    }

    func cancellableAssetDigestForExport(
        _ data: Data,
        relativePath: String
    ) throws -> String {
        let chunkByteCount = 1 * 1_024 * 1_024
        var hasher = SHA256.Stream()
        var offset = 0
        try Task<Never, Never>.checkCancellation()
        while offset < data.count {
            let end = min(offset + chunkByteCount, data.count)
            data.withUnsafeBytes { rawBuffer in
                hasher.update(UnsafeRawBufferPointer(rebasing: rawBuffer[offset..<end]))
            }
            offset = end
            try failureInjector?(.duringExportAssetDigest(
                relativePath: relativePath,
                bytesHashed: offset
            ))
            try Task<Never, Never>.checkCancellation()
        }
        try Task<Never, Never>.checkCancellation()
        return hasher.finalizeHexDigest()
    }

    /// Counts top-level JSON array elements without materializing decoded objects. Strings,
    /// escapes, and nested arrays/objects are tracked explicitly, and nesting itself is bounded.
    /// This keeps a compact crafted JSON file from allocating far beyond the 10k export contract
    /// before the post-decode semantic validator runs.
    func preflightCanvasElementArray(
        _ data: Data,
        relativePath: String,
        maximumElementCount: Int = NotebookExportReadLimits.maximumCanvasElementCount
    ) throws {
        let maximumNestingDepth = 128
        let openSquare = UInt8(ascii: "[")
        let closeSquare = UInt8(ascii: "]")
        let openBrace = UInt8(ascii: "{")
        let closeBrace = UInt8(ascii: "}")
        let quote = UInt8(ascii: "\"")
        let backslash = UInt8(ascii: "\\")
        let comma = UInt8(ascii: ",")
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0a, 0x0d]

        var expectedClosers = [UInt8]()
        expectedClosers.reserveCapacity(16)
        var inString = false
        var escaped = false
        var topLevelElementStarted = false
        var topLevelElementCount = 0
        var finishedTopLevelArray = false
        var cancellationByteCountdown = 0

        for byte in data {
            if cancellationByteCountdown == 0 {
                try Task.checkCancellation()
                cancellationByteCountdown = 4_096
            }
            cancellationByteCountdown -= 1
            if finishedTopLevelArray {
                guard whitespace.contains(byte) else {
                    throw NotebookRepositoryError.corruptedFile(relativePath)
                }
                continue
            }
            if inString {
                if escaped {
                    escaped = false
                } else if byte == backslash {
                    escaped = true
                } else if byte == quote {
                    inString = false
                }
                continue
            }
            if expectedClosers.isEmpty {
                if whitespace.contains(byte) { continue }
                guard byte == openSquare else {
                    throw NotebookRepositoryError.corruptedFile(relativePath)
                }
                expectedClosers.append(closeSquare)
                continue
            }
            if whitespace.contains(byte) { continue }

            let isTopLevel = expectedClosers.count == 1
            if isTopLevel,
               byte != closeSquare,
               byte != comma,
               !topLevelElementStarted {
                topLevelElementStarted = true
                topLevelElementCount += 1
                guard topLevelElementCount <= maximumElementCount else {
                    throw NotebookRepositoryError.canvasElementLimitExceeded(
                        limit: maximumElementCount
                    )
                }
            }

            switch byte {
            case quote:
                inString = true
            case openSquare:
                expectedClosers.append(closeSquare)
            case openBrace:
                expectedClosers.append(closeBrace)
            case closeSquare, closeBrace:
                guard expectedClosers.last == byte else {
                    throw NotebookRepositoryError.corruptedFile(relativePath)
                }
                expectedClosers.removeLast()
                if expectedClosers.isEmpty {
                    finishedTopLevelArray = true
                }
            case comma:
                if isTopLevel {
                    guard topLevelElementStarted else {
                        throw NotebookRepositoryError.corruptedFile(relativePath)
                    }
                    topLevelElementStarted = false
                }
            default:
                break
            }
            guard expectedClosers.count <= maximumNestingDepth else {
                throw NotebookRepositoryError.corruptedFile(relativePath)
            }
        }

        guard finishedTopLevelArray,
              !inString,
              expectedClosers.isEmpty else {
            throw NotebookRepositoryError.corruptedFile(relativePath)
        }
    }

    func validateStructuredContent(_ content: PageContent, for page: PageDescriptor) throws {
        guard content.pageKind == page.kind else {
            throw NotebookRepositoryError.pageContentTypeMismatch(
                pageID: page.id,
                expected: page.kind,
                actual: content.pageKind
            )
        }
        if let detail = structuredContentValidationDetail(content) {
            throw NotebookRepositoryError.invalidPageContent(pageID: page.id, detail: detail)
        }
    }

    func structuredContentValidationDetail(_ content: PageContent) -> String? {
        var totalUTF8Bytes = 0

        func addField(_ value: String, label: String) -> String? {
            let count = value.utf8.count
            guard count <= StructuredContentLimits.maximumUTF8BytesPerField else {
                return "\(label) exceeds the per-field size limit."
            }
            let (sum, overflow) = totalUTF8Bytes.addingReportingOverflow(count)
            guard !overflow, sum <= StructuredContentLimits.maximumUTF8BytesPerPage else {
                return "The page exceeds the total structured-text size limit."
            }
            totalUTF8Bytes = sum
            return nil
        }

        switch content {
        case .textDocument(let document):
            guard document.schemaVersion == TextDocument.currentSchemaVersion else {
                return "The text-document schema version is unsupported."
            }
            guard document.blocks.count <= StructuredContentLimits.maximumBlocks else {
                return "The text document contains too many blocks."
            }
            var blockIDs = Set<TextBlockID>()
            for block in document.blocks {
                guard block.schemaVersion == TextBlock.currentSchemaVersion else {
                    return "Text block \(block.id) has an unsupported schema version."
                }
                guard blockIDs.insert(block.id).inserted else {
                    return "Text block identifiers must be unique."
                }
                guard (0...StructuredContentLimits.maximumIndentationLevel).contains(block.indentationLevel) else {
                    return "Text block \(block.id) has an invalid indentation level."
                }
                if block.style == .checklist {
                    guard block.isChecked != nil else {
                        return "Checklist block \(block.id) is missing its checked state."
                    }
                } else if block.isChecked != nil {
                    return "Only checklist blocks may store a checked state."
                }
                if block.style == .divider, !block.text.isEmpty {
                    return "Divider block \(block.id) must not contain text."
                }
                if let detail = addField(block.text, label: "Text block \(block.id)") {
                    return detail
                }
                guard validDate(block.createdAt), validDate(block.modifiedAt), block.modifiedAt >= block.createdAt else {
                    return "Text block \(block.id) has invalid timestamps."
                }
            }

        case .studySet(let studySet):
            guard studySet.schemaVersion == StudySet.currentSchemaVersion else {
                return "The study-set schema version is unsupported."
            }
            guard studySet.cards.count <= StructuredContentLimits.maximumCards,
                  studySet.progress.count <= StructuredContentLimits.maximumProgressEntries else {
                return "The study set exceeds its card or progress-entry limit."
            }
            var cardIDs = Set<StudyCardID>()
            for card in studySet.cards {
                guard card.schemaVersion == StudyCard.currentSchemaVersion else {
                    return "Study card \(card.id) has an unsupported schema version."
                }
                guard cardIDs.insert(card.id).inserted else {
                    return "Study card identifiers must be unique."
                }
                guard card.tags.count <= StructuredContentLimits.maximumTagsPerCard else {
                    return "Study card \(card.id) has too many tags."
                }
                for (label, value) in [
                    ("prompt", card.prompt),
                    ("answer", card.answer),
                    ("hint", card.hint ?? "")
                ] {
                    if let detail = addField(value, label: "Study card \(card.id) \(label)") {
                        return detail
                    }
                }
                for tag in card.tags {
                    if let detail = addField(tag, label: "Study card \(card.id) tag") {
                        return detail
                    }
                }
                guard validDate(card.createdAt), validDate(card.modifiedAt), card.modifiedAt >= card.createdAt else {
                    return "Study card \(card.id) has invalid timestamps."
                }
            }

            var progressIDs = Set<StudyCardID>()
            for progress in studySet.progress {
                guard progress.schemaVersion == StudyCardProgress.currentSchemaVersion else {
                    return "Study progress for \(progress.cardID) has an unsupported schema version."
                }
                guard progressIDs.insert(progress.cardID).inserted else {
                    return "Each study card may have at most one progress entry."
                }
                guard cardIDs.contains(progress.cardID) else {
                    return "Study progress references a card that is not in the set."
                }
                guard (0...StructuredContentLimits.maximumStudyCounter).contains(progress.repetitions),
                      (0...StructuredContentLimits.maximumStudyCounter).contains(progress.lapses),
                      (0...StructuredContentLimits.maximumStudyIntervalDays).contains(progress.intervalDays),
                      progress.easeFactor.isFinite,
                      (1.3...5).contains(progress.easeFactor),
                      validDate(progress.dueAt),
                      progress.lastReviewedAt.map({ validDate($0) }) ?? true else {
                    return "Study progress for \(progress.cardID) contains invalid scheduling values."
                }
            }
        }
        return nil
    }

    func validDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
    }

    func validateAudioDuration(_ durationSeconds: Double, sessionID: AudioSessionID) throws {
        guard durationSeconds.isFinite,
              (0...AudioStorageLimits.maximumDurationSeconds).contains(durationSeconds) else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The duration must be finite, nonnegative, and no longer than seven days."
            )
        }
    }

    func validateAudioData(_ data: Data, sessionID: AudioSessionID) throws {
        guard data.count >= 12, data.count <= AudioStorageLimits.maximumAudioBytes else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The M4A data is empty, truncated, or exceeds the storage limit."
            )
        }
        let markerStart = data.index(data.startIndex, offsetBy: 4)
        let markerEnd = data.index(markerStart, offsetBy: 4)
        let brandMarker = String(decoding: data[markerStart..<markerEnd], as: UTF8.self)
        guard brandMarker == "ftyp" else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The audio data is not an ISO base-media (M4A) file."
            )
        }
    }

    func makeTemporaryAudioSource(
        from data: Data,
        sessionID: AudioSessionID
    ) throws -> URL {
        guard data.count <= AudioStorageLimits.maximumAudioBytes else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The M4A data exceeds the storage limit."
            )
        }
        try Task<Never, Never>.checkCancellation()
        let directoryDescriptor = rootURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The temporary audio source could not be created safely."
            )
        }
        defer { _ = Darwin.close(directoryDescriptor) }

        let filename = ".audio-ingest-\(UUID().uuidString).m4a"
        var descriptor = filename.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The temporary audio source could not be created safely."
            )
        }
        var keepFile = false
        defer {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            if !keepFile {
                filename.withCString { _ = Darwin.unlinkat(directoryDescriptor, $0, 0) }
            }
        }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try Task<Never, Never>.checkCancellation()
                guard let baseAddress = bytes.baseAddress else { break }
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    min(64 * 1_024, bytes.count - offset)
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw NotebookRepositoryError.invalidAudioSession(
                        sessionID,
                        detail: "The temporary audio source could not be written safely."
                    )
                }
                guard written > 0 else {
                    throw NotebookRepositoryError.invalidAudioSession(
                        sessionID,
                        detail: "The temporary audio source could not be written safely."
                    )
                }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The temporary audio source could not be synchronized."
            )
        }
        _ = Darwin.close(descriptor)
        descriptor = -1
        _ = Darwin.fsync(directoryDescriptor)
        keepFile = true
        return rootURL.appendingPathComponent(filename, isDirectory: false)
    }

    func inspectAudioSource(
        at url: URL,
        sessionID: AudioSessionID,
        maximumByteCount: Int64 = Int64(AudioStorageLimits.maximumAudioBytes)
    ) throws -> AudioStreamSource {
        try streamAudioSource(
            at: url,
            sessionID: sessionID,
            maximumByteCount: maximumByteCount,
            expected: nil,
            destinationDescriptor: nil
        )
    }

    func stageAudioSource(
        _ source: AudioStreamSource,
        to destination: URL,
        layout: NotebookPackageLayout
    ) throws {
        let parentURL = destination.deletingLastPathComponent()
        let parentDescriptor = try openItemWithoutFollowingLinks(
            at: parentURL,
            within: layout.packageURL,
            finalFlags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        defer { _ = Darwin.close(parentDescriptor) }
        var destinationDescriptor = destination.lastPathComponent.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard destinationDescriptor >= 0 else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: destination, in: layout.packageURL)
            )
        }
        var keepDestination = false
        defer {
            if destinationDescriptor >= 0 { _ = Darwin.close(destinationDescriptor) }
            if !keepDestination {
                destination.lastPathComponent.withCString {
                    _ = Darwin.unlinkat(parentDescriptor, $0, 0)
                }
            }
        }

        let copied = try streamAudioSource(
            at: source.url,
            sessionID: source.sessionID,
            maximumByteCount: source.maximumByteCount,
            expected: source,
            destinationDescriptor: destinationDescriptor
        )
        guard copied.byteCount == source.byteCount, copied.sha256 == source.sha256 else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: destination, in: layout.packageURL)
            )
        }
        guard Darwin.fsync(destinationDescriptor) == 0 else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: destination, in: layout.packageURL)
            )
        }
        _ = Darwin.close(destinationDescriptor)
        destinationDescriptor = -1
        _ = Darwin.fsync(parentDescriptor)
        keepDestination = true
    }

    func secureInstallAudioSource(
        from sourceURL: URL,
        to destination: URL,
        within packageURL: URL,
        sessionID: AudioSessionID,
        expectedByteCount: Int64?,
        expectedSHA256: String?
    ) throws {
        let parentURL = destination.deletingLastPathComponent()
        let parentDescriptor = try openItemWithoutFollowingLinks(
            at: parentURL,
            within: packageURL,
            finalFlags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        defer { _ = Darwin.close(parentDescriptor) }
        let temporaryName = ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        var destinationDescriptor = temporaryName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard destinationDescriptor >= 0 else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: destination, in: packageURL)
            )
        }
        var keepTemporary = false
        defer {
            if destinationDescriptor >= 0 { _ = Darwin.close(destinationDescriptor) }
            if !keepTemporary {
                temporaryName.withCString { _ = Darwin.unlinkat(parentDescriptor, $0, 0) }
            }
        }

        let copied = try streamAudioSource(
            at: sourceURL,
            sessionID: sessionID,
            maximumByteCount: Int64(AudioStorageLimits.maximumAudioBytes),
            expected: nil,
            destinationDescriptor: destinationDescriptor
        )
        guard expectedByteCount.map({ $0 == copied.byteCount }) ?? true,
              expectedSHA256.map({ $0 == copied.sha256 }) ?? true else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: sourceURL, in: packageURL)
            )
        }
        guard Darwin.fsync(destinationDescriptor) == 0 else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: destination, in: packageURL)
            )
        }
        _ = Darwin.close(destinationDescriptor)
        destinationDescriptor = -1
        let renameResult = temporaryName.withCString { temporaryPath in
            destination.lastPathComponent.withCString { destinationPath in
                Darwin.renameat(
                    parentDescriptor,
                    temporaryPath,
                    parentDescriptor,
                    destinationPath
                )
            }
        }
        guard renameResult == 0 else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: destination, in: packageURL)
            )
        }
        keepTemporary = true
        _ = Darwin.fsync(parentDescriptor)
    }

    func streamAudioSource(
        at url: URL,
        sessionID: AudioSessionID,
        maximumByteCount: Int64,
        expected: AudioStreamSource?,
        destinationDescriptor: Int32?
    ) throws -> AudioStreamSource {
        try Task<Never, Never>.checkCancellation()
        guard maximumByteCount > 0,
              maximumByteCount <= Int64(AudioStorageLimits.maximumAudioBytes) else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The caller's audio ingestion limit is invalid."
            )
        }
        let sourceDescriptor = try openAudioSourceWithoutFollowingLinks(at: url, sessionID: sessionID)
        defer { _ = Darwin.close(sourceDescriptor) }

        var initialMetadata = stat()
        guard Darwin.fstat(sourceDescriptor, &initialMetadata) == 0,
              (initialMetadata.st_mode & S_IFMT) == S_IFREG,
              initialMetadata.st_nlink == 1,
              initialMetadata.st_size >= 12,
              initialMetadata.st_size <= off_t(maximumByteCount),
              !audioSourceIsSparse(initialMetadata) else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The audio source must be a bounded, nonsparse, single-link regular file."
            )
        }
        let initialIdentity = audioSourceIdentity(initialMetadata)
        if let expected, expected.identity != initialIdentity {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The audio source changed before it could be committed."
            )
        }

        var hasher = SHA256.Stream()
        var header = [UInt8]()
        header.reserveCapacity(12)
        var totalBytes: Int64 = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task<Never, Never>.checkCancellation()
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(sourceDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw NotebookRepositoryError.invalidAudioSession(
                    sessionID,
                    detail: "The audio source could not be read safely."
                )
            }
            if bytesRead == 0 { break }
            guard totalBytes <= maximumByteCount - Int64(bytesRead) else {
                throw NotebookRepositoryError.invalidAudioSession(
                    sessionID,
                    detail: "The audio source exceeds the storage limit."
                )
            }
            if header.count < 12 {
                header.append(contentsOf: buffer.prefix(min(bytesRead, 12 - header.count)))
            }
            buffer.withUnsafeBytes { rawBuffer in
                hasher.update(UnsafeRawBufferPointer(rebasing: rawBuffer[..<bytesRead]))
            }
            if let destinationDescriptor {
                var written = 0
                while written < bytesRead {
                    let result = buffer.withUnsafeBytes { rawBuffer in
                        Darwin.write(
                            destinationDescriptor,
                            rawBuffer.baseAddress?.advanced(by: written),
                            bytesRead - written
                        )
                    }
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw NotebookRepositoryError.invalidAudioSession(
                            sessionID,
                            detail: "The audio source could not be staged safely."
                        )
                    }
                    guard result > 0 else {
                        throw NotebookRepositoryError.invalidAudioSession(
                            sessionID,
                            detail: "The audio source could not be staged safely."
                        )
                    }
                    written += result
                }
            }
            totalBytes += Int64(bytesRead)
            try failureInjector?(.duringAudioSourceCopy(bytesCopied: totalBytes))
            try Task<Never, Never>.checkCancellation()
        }

        var finalMetadata = stat()
        guard Darwin.fstat(sourceDescriptor, &finalMetadata) == 0,
              audioSourceIdentity(finalMetadata) == initialIdentity,
              totalBytes == initialIdentity.byteCount else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The audio source changed while it was being copied."
            )
        }
        let reopenedDescriptor = try openAudioSourceWithoutFollowingLinks(at: url, sessionID: sessionID)
        defer { _ = Darwin.close(reopenedDescriptor) }
        var reopenedMetadata = stat()
        guard Darwin.fstat(reopenedDescriptor, &reopenedMetadata) == 0,
              audioSourceIdentity(reopenedMetadata) == initialIdentity else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The audio source path changed while it was being copied."
            )
        }
        guard header.count >= 12,
              String(decoding: header[4..<8], as: UTF8.self) == "ftyp" else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The audio source is not an ISO base-media (M4A) file."
            )
        }
        let digest = hasher.finalizeHexDigest()
        if let expected,
           (expected.byteCount != totalBytes || expected.sha256 != digest) {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The audio source changed before it could be committed."
            )
        }
        return AudioStreamSource(
            url: url,
            sessionID: sessionID,
            maximumByteCount: maximumByteCount,
            identity: initialIdentity,
            byteCount: totalBytes,
            sha256: digest
        )
    }

    func openAudioSourceWithoutFollowingLinks(
        at url: URL,
        sessionID: AudioSessionID
    ) throws -> Int32 {
        guard url.isFileURL else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The audio source must be a local file URL."
            )
        }
        var originalMetadata = stat()
        guard url.path.withCString({ Darwin.lstat($0, &originalMetadata) }) == 0,
              (originalMetadata.st_mode & S_IFMT) == S_IFREG else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The audio source must not be a symbolic link or special file."
            )
        }

        let standardizedURL = url.standardizedFileURL
        let canonicalURL = standardizedURL.resolvingSymlinksInPath().standardizedFileURL
        let standardizedPath = standardizedURL.path
        let permittedSystemAliasPath: String? = {
            if standardizedPath == "/var" || standardizedPath.hasPrefix("/var/") {
                return "/private\(standardizedPath)"
            }
            if standardizedPath == "/tmp" || standardizedPath.hasPrefix("/tmp/") {
                return "/private\(standardizedPath)"
            }
            return nil
        }()
        let usesPermittedSystemAlias = permittedSystemAliasPath.map {
            canonicalURL.path == $0
        } ?? false
        guard canonicalURL.path == standardizedPath || usesPermittedSystemAlias else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "An audio source path component is a symbolic link."
            )
        }
        let components = canonicalURL.pathComponents
        guard components.count > 1, components.first == "/" else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The audio source path is invalid."
            )
        }
        var directoryDescriptor = "/".withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The audio source path could not be opened safely."
            )
        }
        for component in components.dropFirst().dropLast() {
            let next = component.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard next >= 0 else {
                _ = Darwin.close(directoryDescriptor)
                throw NotebookRepositoryError.invalidAudioSession(
                    sessionID,
                    detail: "An audio source path component is linked or unsafe."
                )
            }
            _ = Darwin.close(directoryDescriptor)
            directoryDescriptor = next
        }
        let descriptor = canonicalURL.lastPathComponent.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
        }
        _ = Darwin.close(directoryDescriptor)
        guard descriptor >= 0 else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The audio source could not be opened without following links."
            )
        }
        var openedMetadata = stat()
        guard Darwin.fstat(descriptor, &openedMetadata) == 0,
              openedMetadata.st_dev == originalMetadata.st_dev,
              openedMetadata.st_ino == originalMetadata.st_ino else {
            _ = Darwin.close(descriptor)
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The audio source path changed while it was being opened."
            )
        }
        return descriptor
    }

    func audioSourceIdentity(_ metadata: stat) -> AudioSourceIdentity {
        AudioSourceIdentity(
            device: UInt64(bitPattern: Int64(metadata.st_dev)),
            inode: UInt64(metadata.st_ino),
            linkCount: UInt64(metadata.st_nlink),
            byteCount: Int64(metadata.st_size),
            allocatedBlockCount: Int64(metadata.st_blocks),
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }

    func audioSourceIsSparse(_ metadata: stat) -> Bool {
        guard metadata.st_size > 0 else { return false }
        let requiredBlocks = (Int64(metadata.st_size) + 511) / 512
        return Int64(metadata.st_blocks) < requiredBlocks
    }

    func validateTranscriptAsset(
        _ assetID: AssetID?,
        manifest: NotebookManifest,
        sessionID: AudioSessionID
    ) throws {
        guard let assetID else { return }
        guard assetID.isSHA256Digest,
              manifest.assets.contains(where: {
                  $0.id == assetID
                      && $0.mediaType == AudioTranscriptDocument.mediaType
              }) else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The transcript asset is not present in this notebook."
            )
        }
    }

    func storedAudioTimeline(
        for descriptor: AudioSessionDescriptor,
        manifest: NotebookManifest,
        layout: NotebookPackageLayout
    ) throws -> AudioTimelineDocument {
        guard let timelineFilename = descriptor.timelineFilename else {
            throw NotebookRepositoryError.invalidAudioSession(
                descriptor.id,
                detail: "This session does not contain a durable timeline."
            )
        }
        let timelineURL = try safeAudioURL(
            filename: timelineFilename,
            layout: layout,
            expectedExtension: "json"
        )
        let timelineData = try readBoundedRegularFileData(
            at: timelineURL,
            within: layout.packageURL,
            maximumBytes: AudioStorageLimits.maximumTimelineBytes
        )
        let timeline: AudioTimelineDocument
        do {
            timeline = try decode(AudioTimelineDocument.self, from: timelineData)
        } catch {
            throw NotebookRepositoryError.invalidAudioSession(
                descriptor.id,
                detail: "The durable timeline cannot be decoded."
            )
        }
        guard timeline.audioSessionID == descriptor.id else {
            throw NotebookRepositoryError.invalidAudioSession(
                descriptor.id,
                detail: "The timeline belongs to another audio session."
            )
        }
        try validateAudioTimeline(
            timeline,
            durationSeconds: descriptor.durationSeconds,
            manifest: manifest
        )
        try validateRecordingStart(
            descriptor.recordingStartedAt,
            timeline: timeline,
            sessionID: descriptor.id
        )
        return timeline
    }

    func validateAudioTranscript(
        _ transcript: AudioTranscriptDocument,
        descriptor: AudioSessionDescriptor,
        timeline: AudioTimelineDocument
    ) throws {
        let sessionID = descriptor.id
        guard transcript.schemaVersion == AudioTranscriptDocument.currentSchemaVersion,
              transcript.audioSessionID == sessionID,
              validDate(transcript.generatedAt),
              !transcript.localeIdentifier.isEmpty,
              transcript.localeIdentifier.utf8.count <= AudioTranscriptDocument.maximumLocaleUTF8Bytes,
              !transcript.localeIdentifier.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              transcript.segments.count <= AudioTranscriptDocument.maximumSegmentCount else {
            throw NotebookRepositoryError.invalidAudioTranscript(
                sessionID,
                detail: "The transcript schema, session identifier, locale, timestamp, or segment count is invalid."
            )
        }

        let marksByID = Dictionary(uniqueKeysWithValues: timeline.marks.map { ($0.id, $0) })
        var segmentIDs = Set<UUID>()
        var totalTextBytes = 0
        var previousSegment: AudioTranscriptSegment?
        let endTolerance = min(0.001, max(0, descriptor.durationSeconds))
        for segment in transcript.segments {
            let textBytes = segment.text.utf8.count
            guard textBytes <= AudioTranscriptDocument.maximumTextUTF8BytesPerSegment,
                  totalTextBytes <= AudioTranscriptDocument.maximumTotalTextUTF8Bytes - textBytes else {
                throw NotebookRepositoryError.invalidAudioTranscript(
                    sessionID,
                    detail: "The transcript text exceeds its bounded storage policy."
                )
            }
            totalTextBytes += textBytes
            guard segmentIDs.insert(segment.id).inserted,
                  segment.startTime.isFinite,
                  segment.startTime >= 0,
                  segment.duration.isFinite,
                  segment.duration >= 0,
                  segment.confidence.isFinite,
                  (0 ... 1).contains(segment.confidence) else {
                throw NotebookRepositoryError.invalidAudioTranscript(
                    sessionID,
                    detail: "A transcript segment has a duplicate identifier or invalid numeric value."
                )
            }
            let segmentEnd = segment.startTime + segment.duration
            guard segmentEnd.isFinite,
                  segment.startTime <= descriptor.durationSeconds + endTolerance,
                  segmentEnd <= descriptor.durationSeconds + endTolerance else {
                throw NotebookRepositoryError.invalidAudioTranscript(
                    sessionID,
                    detail: "A transcript segment falls outside the recording duration."
                )
            }
            if let previousSegment {
                let isCanonical = segment.startTime > previousSegment.startTime
                    || (segment.startTime == previousSegment.startTime
                        && (segment.duration > previousSegment.duration
                            || (segment.duration == previousSegment.duration
                                && segment.id.uuidString.lowercased()
                                    >= previousSegment.id.uuidString.lowercased())))
                guard isCanonical else {
                    throw NotebookRepositoryError.invalidAudioTranscript(
                        sessionID,
                        detail: "Transcript segments are not in deterministic timeline order."
                    )
                }
            }
            previousSegment = segment
            if let timelineMarkID = segment.timelineMarkID {
                guard let mark = marksByID[timelineMarkID],
                      segment.operationID == mark.operationID,
                      segment.pageID == mark.pageID,
                      mark.timeSeconds <= segment.startTime else {
                    throw NotebookRepositoryError.invalidAudioTranscript(
                        sessionID,
                        detail: "A transcript segment contains a dangling or inconsistent timeline mapping."
                    )
                }
            } else if segment.operationID != nil || segment.pageID != nil {
                throw NotebookRepositoryError.invalidAudioTranscript(
                    sessionID,
                    detail: "A transcript segment contains a partial timeline mapping."
                )
            }
        }
    }

    func readValidatedAssetData(
        _ descriptor: AssetDescriptor,
        layout: NotebookPackageLayout,
        maximumBytes: Int
    ) throws -> Data {
        guard descriptor.id.isSHA256Digest,
              descriptor.byteCount >= 0,
              descriptor.byteCount <= Int64(maximumBytes) else {
            throw NotebookRepositoryError.invalidAsset(descriptor.id)
        }
        let data: Data
        do {
            data = try readBoundedRegularFileData(
                at: layout.assetURL(descriptor.id),
                within: layout.packageURL,
                maximumBytes: maximumBytes
            )
        } catch {
            throw NotebookRepositoryError.invalidAsset(descriptor.id)
        }
        guard Int64(data.count) == descriptor.byteCount,
              SHA256.hexDigest(data) == descriptor.id.rawValue else {
            throw NotebookRepositoryError.invalidAsset(descriptor.id)
        }
        return data
    }

    func prepareNoteReplayHistoryForIngest(
        _ bundle: NoteReplayCaptureBundle,
        timeline: AudioTimelineDocument,
        durationSeconds: Double,
        manifest: inout NotebookManifest,
        layout: NotebookPackageLayout
    ) throws -> PreparedNoteReplayHistory {
        let document = bundle.document
        let sessionID = timeline.audioSessionID
        guard document.schemaVersion == NoteReplayHistoryDocument.currentSchemaVersion,
              document.audioSessionID == sessionID,
              durationSeconds > 0,
              validDate(document.sealedAt),
              !document.events.isEmpty,
              document.events.count <= NoteReplayHistoryLimits.maximumEventCount else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The sealed Note Replay index has an invalid schema, session, date, or event count."
            )
        }

        let drawableKinds: Set<PageKind> = [.notebook, .whiteboard, .importedDocument]
        let pageKindsByID = Dictionary(uniqueKeysWithValues: manifest.pages.map { ($0.id, $0.kind) })
        let drawablePageIDs = Set(pageKindsByID.compactMap { pageID, kind in
            drawableKinds.contains(kind) ? pageID : nil
        })
        let validCanvasAssetIDs = Set(manifest.assets.map(\.id))

        var eventIDs = Set<NoteReplayEventID>()
        var operationIDs = Set<OperationID>()
        var eventCountByPage: [PageID: Int] = [:]
        var hasBaselineByPage: [PageID: Bool] = [:]
        var hasTerminalByPage: [PageID: Bool] = [:]
        var referencesByID: [AssetID: NoteReplayPayloadReference] = [:]
        var rolesByID: [AssetID: NoteReplayPayloadRole] = [:]
        var uniquePayloadByteCount = 0
        var previousTime: TimeInterval?

        func register(
            _ reference: NoteReplayPayloadReference,
            role: NoteReplayPayloadRole
        ) throws {
            guard reference.assetID.isSHA256Digest,
                  reference.byteCount > 0,
                  reference.byteCount <= role.maximumByteCount else {
                throw NotebookRepositoryError.invalidAudioSession(
                    sessionID,
                    detail: "A Note Replay payload reference is malformed or exceeds its layer limit."
                )
            }
            if let existing = referencesByID[reference.assetID] {
                guard existing == reference,
                      rolesByID[reference.assetID] == role else {
                    throw NotebookRepositoryError.invalidAudioSession(
                        sessionID,
                        detail: "A Note Replay asset is referenced with conflicting size or layer metadata."
                    )
                }
                return
            }
            guard referencesByID.count < NoteReplayHistoryLimits.maximumUniquePayloadCount,
                  uniquePayloadByteCount
                    <= NoteReplayHistoryLimits.maximumUniquePayloadBytes - reference.byteCount else {
                throw NotebookRepositoryError.invalidAudioSession(
                    sessionID,
                    detail: "The Note Replay history exceeds its unique payload budget."
                )
            }
            referencesByID[reference.assetID] = reference
            rolesByID[reference.assetID] = role
            uniquePayloadByteCount += reference.byteCount
        }

        eventIDs.reserveCapacity(document.events.count)
        operationIDs.reserveCapacity(document.events.count)
        for (expectedSequence, event) in document.events.enumerated() {
            try Task<Never, Never>.checkCancellation()
            let pageEventCount = eventCountByPage[event.pageID, default: 0]
            guard event.sequence == expectedSequence,
                  eventIDs.insert(event.id).inserted,
                  operationIDs.insert(event.operationID).inserted,
                  drawablePageIDs.contains(event.pageID),
                  event.timeSeconds.isFinite,
                  event.timeSeconds >= 0,
                  event.timeSeconds <= durationSeconds,
                  previousTime.map({ $0 <= event.timeSeconds }) ?? true,
                  pageEventCount < NoteReplayHistoryLimits.maximumEventsPerPage else {
                throw NotebookRepositoryError.invalidAudioSession(
                    sessionID,
                    detail: "The Note Replay event order, identity, page, time, or per-page count is invalid."
                )
            }

            let alreadyHasBaseline = hasBaselineByPage[event.pageID] == true
            let alreadyHasTerminal = hasTerminalByPage[event.pageID] == true
            switch event.kind {
            case .baseline:
                guard pageEventCount == 0, !alreadyHasBaseline, !alreadyHasTerminal else {
                    throw NotebookRepositoryError.invalidAudioSession(
                        sessionID,
                        detail: "The first event for each replay page must be its only baseline."
                    )
                }
                hasBaselineByPage[event.pageID] = true
            case .change:
                guard alreadyHasBaseline, !alreadyHasTerminal else {
                    throw NotebookRepositoryError.invalidAudioSession(
                        sessionID,
                        detail: "A replay change must follow its baseline and precede its terminal event."
                    )
                }
            case .terminal:
                guard alreadyHasBaseline,
                      !alreadyHasTerminal,
                      event.timeSeconds == durationSeconds else {
                    throw NotebookRepositoryError.invalidAudioSession(
                        sessionID,
                        detail: "A replay page requires one terminal event at the exact recording duration."
                    )
                }
                hasTerminalByPage[event.pageID] = true
            }

            if let inkPayload = event.inkPayload {
                try register(inkPayload, role: .ink)
            }
            try register(event.elementsPayload, role: .elements)
            eventCountByPage[event.pageID] = pageEventCount + 1
            previousTime = event.timeSeconds
        }

        guard eventCountByPage.keys.allSatisfy({
            hasBaselineByPage[$0] == true && hasTerminalByPage[$0] == true
        }) else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "Every Note Replay page must contain a baseline and terminal scene."
            )
        }
        let drawableTimelinePageIDs = Set(timeline.marks.compactMap { mark in
            drawablePageIDs.contains(mark.pageID) ? mark.pageID : nil
        })
        guard drawableTimelinePageIDs.allSatisfy({
            hasBaselineByPage[$0] == true && hasTerminalByPage[$0] == true
        }) else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "Every drawable page in the audio timeline requires a baseline and terminal replay scene."
            )
        }

        guard bundle.payloads.count == referencesByID.count else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The Note Replay bundle contains missing or unreferenced payload blobs."
            )
        }
        var blobsByID: [AssetID: NoteReplayPayloadBlob] = [:]
        blobsByID.reserveCapacity(bundle.payloads.count)
        for blob in bundle.payloads {
            try Task<Never, Never>.checkCancellation()
            let assetID = blob.reference.assetID
            guard blobsByID.updateValue(blob, forKey: assetID) == nil,
                  referencesByID[assetID] == blob.reference,
                  blob.data.count == blob.reference.byteCount,
                  SHA256.hexDigest(blob.data) == assetID.rawValue,
                  let role = rolesByID[assetID] else {
                throw NotebookRepositoryError.invalidAudioSession(
                    sessionID,
                    detail: "A Note Replay payload blob does not match its sealed content reference."
                )
            }
            if role == .elements {
                let elements: [CanvasElement]
                do {
                    try preflightCanvasElementArray(
                        blob.data,
                        relativePath: "assets/\(assetID.rawValue)",
                        maximumElementCount:
                            NoteReplayHistoryLimits.maximumElementCountPerSnapshot
                    )
                    elements = try NoteReplayPayloadCodec.decodeElements(blob.data)
                    guard elements.count
                            <= NoteReplayHistoryLimits.maximumElementCountPerSnapshot else {
                        throw NotebookRepositoryError.canvasElementLimitExceeded(
                            limit: NoteReplayHistoryLimits.maximumElementCountPerSnapshot
                        )
                    }
                    try validateCanvasElementsForExport(
                        elements,
                        validAssetIDs: validCanvasAssetIDs,
                        relativePath: "assets/\(assetID.rawValue)"
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw NotebookRepositoryError.invalidAudioSession(
                        sessionID,
                        detail: "A Note Replay element snapshot is malformed or references an unavailable asset."
                    )
                }
            }
        }

        let indexData: Data
        do {
            indexData = try encode(document)
        } catch {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The Note Replay index could not be encoded safely."
            )
        }
        guard indexData.count <= NoteReplayHistoryLimits.maximumIndexBytes else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The encoded Note Replay index exceeds its storage limit."
            )
        }

        var writes: [PlannedFileWrite] = []
        for assetID in referencesByID.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let reference = referencesByID[assetID],
                  let role = rolesByID[assetID],
                  let blob = blobsByID[assetID] else {
                throw NotebookRepositoryError.invalidAudioSession(
                    sessionID,
                    detail: "The Note Replay bundle is internally inconsistent."
                )
            }
            let assetURL = layout.assetURL(assetID)
            if let existing = manifest.assets.first(where: { $0.id == assetID }) {
                guard existing.mediaType == role.mediaType,
                      existing.byteCount == Int64(reference.byteCount),
                      (try? readValidatedAssetData(
                          existing,
                          layout: layout,
                          maximumBytes: role.maximumByteCount
                      )) == blob.data else {
                    throw NotebookRepositoryError.invalidAsset(assetID)
                }
                continue
            }

            if fileSystemEntryExists(at: assetURL) {
                guard let existingData = try? readBoundedRegularFileData(
                          at: assetURL,
                          within: layout.packageURL,
                          maximumBytes: role.maximumByteCount
                      ), existingData == blob.data else {
                    throw NotebookRepositoryError.invalidAsset(assetID)
                }
            } else {
                writes.append(PlannedFileWrite(
                    url: assetURL,
                    data: blob.data,
                    maximumByteCount: role.maximumByteCount
                ))
            }
            manifest.assets.append(AssetDescriptor(
                id: assetID,
                mediaType: role.mediaType,
                originalFilename: "\(sessionID.description).replay-\(role == .ink ? "ink" : "elements")",
                byteCount: Int64(reference.byteCount),
                createdAt: document.sealedAt
            ))
        }
        return PreparedNoteReplayHistory(indexData: indexData, payloadWrites: writes)
    }

    func validateStoredNoteReplayHistory(
        _ document: NoteReplayHistoryDocument,
        descriptor: AudioSessionDescriptor,
        timeline: AudioTimelineDocument,
        manifest: NotebookManifest,
        maximumEventCount: Int
    ) throws -> (
        ink: Set<NoteReplayPayloadReference>,
        elements: Set<NoteReplayPayloadReference>
    ) {
        let sessionID = descriptor.id
        guard document.schemaVersion == NoteReplayHistoryDocument.currentSchemaVersion,
              document.audioSessionID == sessionID,
              validDate(document.sealedAt),
              document.events.count == descriptor.replayEventCount,
              document.events.count <= maximumEventCount else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The stored Note Replay index does not match its descriptor or requested event limit."
            )
        }

        var assetsByID: [AssetID: AssetDescriptor] = [:]
        assetsByID.reserveCapacity(manifest.assets.count)
        for asset in manifest.assets {
            guard assetsByID.updateValue(asset, forKey: asset.id) == nil else {
                throw NotebookRepositoryError.malformedPackage(
                    "Asset identifiers must be unique."
                )
            }
        }
        let drawablePageIDs = Set(manifest.pages.compactMap { page -> PageID? in
            switch page.kind {
            case .notebook, .whiteboard, .importedDocument: page.id
            case .textDocument, .studySet: nil
            }
        })

        var eventIDs = Set<NoteReplayEventID>()
        var operationIDs = Set<OperationID>()
        var eventCountByPage: [PageID: Int] = [:]
        var hasBaselineByPage: [PageID: Bool] = [:]
        var hasTerminalByPage: [PageID: Bool] = [:]
        var rolesByID: [AssetID: NoteReplayPayloadRole] = [:]
        var referencesByID: [AssetID: NoteReplayPayloadReference] = [:]
        var inkReferences = Set<NoteReplayPayloadReference>()
        var elementReferences = Set<NoteReplayPayloadReference>()
        var uniquePayloadByteCount = 0
        var previousTime: TimeInterval?

        func register(
            _ reference: NoteReplayPayloadReference,
            role: NoteReplayPayloadRole
        ) throws {
            guard reference.assetID.isSHA256Digest,
                  reference.byteCount > 0,
                  reference.byteCount <= role.maximumByteCount else {
                throw NotebookRepositoryError.invalidAudioSession(
                    sessionID,
                    detail: "A stored Note Replay payload reference is invalid."
                )
            }
            if let existing = referencesByID[reference.assetID] {
                guard existing == reference,
                      rolesByID[reference.assetID] == role else {
                    throw NotebookRepositoryError.invalidAudioSession(
                        sessionID,
                        detail: "A stored Note Replay asset has conflicting layer metadata."
                    )
                }
            } else {
                guard referencesByID.count < NoteReplayHistoryLimits.maximumUniquePayloadCount,
                      uniquePayloadByteCount
                        <= NoteReplayHistoryLimits.maximumUniquePayloadBytes - reference.byteCount else {
                    throw NotebookRepositoryError.invalidAudioSession(
                        sessionID,
                        detail: "The stored Note Replay payload budget is invalid."
                    )
                }
                referencesByID[reference.assetID] = reference
                rolesByID[reference.assetID] = role
                uniquePayloadByteCount += reference.byteCount
            }

            guard let asset = assetsByID[reference.assetID],
                  asset.mediaType == role.mediaType,
                  asset.byteCount == Int64(reference.byteCount) else {
                throw NotebookRepositoryError.invalidAsset(reference.assetID)
            }
            switch role {
            case .ink: inkReferences.insert(reference)
            case .elements: elementReferences.insert(reference)
            }
        }

        for (expectedSequence, event) in document.events.enumerated() {
            try Task<Never, Never>.checkCancellation()
            let pageEventCount = eventCountByPage[event.pageID, default: 0]
            guard event.sequence == expectedSequence,
                  eventIDs.insert(event.id).inserted,
                  operationIDs.insert(event.operationID).inserted,
                  drawablePageIDs.contains(event.pageID),
                  event.timeSeconds.isFinite,
                  event.timeSeconds >= 0,
                  event.timeSeconds <= descriptor.durationSeconds,
                  previousTime.map({ $0 <= event.timeSeconds }) ?? true,
                  pageEventCount < NoteReplayHistoryLimits.maximumEventsPerPage else {
                throw NotebookRepositoryError.invalidAudioSession(
                    sessionID,
                    detail: "The stored Note Replay event order, identity, time, or per-page count is invalid."
                )
            }
            let alreadyHasBaseline = hasBaselineByPage[event.pageID] == true
            let alreadyHasTerminal = hasTerminalByPage[event.pageID] == true
            switch event.kind {
            case .baseline:
                guard pageEventCount == 0, !alreadyHasBaseline, !alreadyHasTerminal else {
                    throw NotebookRepositoryError.invalidAudioSession(
                        sessionID,
                        detail: "A stored Note Replay page has an invalid baseline."
                    )
                }
                hasBaselineByPage[event.pageID] = true
            case .change:
                guard alreadyHasBaseline, !alreadyHasTerminal else {
                    throw NotebookRepositoryError.invalidAudioSession(
                        sessionID,
                        detail: "A stored Note Replay change is outside its page event boundary."
                    )
                }
            case .terminal:
                guard alreadyHasBaseline,
                      !alreadyHasTerminal,
                      event.timeSeconds == descriptor.durationSeconds else {
                    throw NotebookRepositoryError.invalidAudioSession(
                        sessionID,
                        detail: "A stored Note Replay page has an invalid terminal event."
                    )
                }
                hasTerminalByPage[event.pageID] = true
            }
            if let inkPayload = event.inkPayload {
                try register(inkPayload, role: .ink)
            }
            try register(event.elementsPayload, role: .elements)
            eventCountByPage[event.pageID] = pageEventCount + 1
            previousTime = event.timeSeconds
        }

        guard eventCountByPage.keys.allSatisfy({
            hasBaselineByPage[$0] == true && hasTerminalByPage[$0] == true
        }) else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "A stored Note Replay page is not sealed by baseline and terminal events."
            )
        }
        let requiredTimelinePageIDs = Set(timeline.marks.compactMap { mark in
            drawablePageIDs.contains(mark.pageID) ? mark.pageID : nil
        })
        guard requiredTimelinePageIDs.allSatisfy({
            hasBaselineByPage[$0] == true && hasTerminalByPage[$0] == true
        }) else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "A drawable timeline page is missing from the sealed Note Replay history."
            )
        }
        return (inkReferences, elementReferences)
    }

    func validateAudioTimeline(
        _ timeline: AudioTimelineDocument,
        durationSeconds: Double,
        manifest: NotebookManifest
    ) throws {
        let sessionID = timeline.audioSessionID
        guard timeline.schemaVersion == AudioTimelineDocument.currentSchemaVersion,
              validDate(timeline.modifiedAt),
              timeline.marks.count <= AudioStorageLimits.maximumTimelineMarks else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The timeline schema, timestamp, or mark count is invalid."
            )
        }
        let pageIDs = Set(manifest.pages.map(\.id))
        var markIDs = Set<AudioTimelineMarkID>()
        var operationIDs = Set<OperationID>()
        for mark in timeline.marks {
            guard mark.schemaVersion == AudioTimelineMark.currentSchemaVersion,
                  markIDs.insert(mark.id).inserted,
                  operationIDs.insert(mark.operationID).inserted,
                  pageIDs.contains(mark.pageID),
                  mark.timeSeconds.isFinite,
                  mark.timeSeconds >= 0,
                  mark.timeSeconds <= durationSeconds,
                  validDate(mark.createdAt) else {
                throw NotebookRepositoryError.invalidAudioSession(
                    sessionID,
                    detail: "The timeline contains a duplicate, dangling, or invalid mark."
                )
            }
        }
    }

    /// Replay validates every durable mark before projecting the timeline onto the currently
    /// eligible notebook pages. It therefore deliberately does not reject or remove a mark only
    /// because its page was deleted or became a structured-content page after recording.
    func validateAudioTimelineForReplay(
        _ timeline: AudioTimelineDocument,
        descriptor: AudioSessionDescriptor,
        maximumMarkCount: Int
    ) throws {
        let sessionID = descriptor.id
        guard timeline.schemaVersion == AudioTimelineDocument.currentSchemaVersion,
              timeline.audioSessionID == sessionID,
              validDate(timeline.modifiedAt),
              timeline.marks.count <= maximumMarkCount else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The replay timeline schema, session, timestamp, or mark count is invalid."
            )
        }

        var markIDs = Set<AudioTimelineMarkID>()
        var operationIDs = Set<OperationID>()
        markIDs.reserveCapacity(timeline.marks.count)
        operationIDs.reserveCapacity(timeline.marks.count)
        for mark in timeline.marks {
            try Task.checkCancellation()
            guard mark.schemaVersion == AudioTimelineMark.currentSchemaVersion,
                  markIDs.insert(mark.id).inserted,
                  operationIDs.insert(mark.operationID).inserted,
                  mark.timeSeconds.isFinite,
                  mark.timeSeconds >= 0,
                  mark.timeSeconds <= descriptor.durationSeconds,
                  validDate(mark.createdAt) else {
                throw NotebookRepositoryError.invalidAudioSession(
                    sessionID,
                    detail: "The replay timeline contains a duplicate or invalid mark."
                )
            }
        }
        try validateRecordingStart(
            descriptor.recordingStartedAt,
            timeline: timeline,
            sessionID: sessionID
        )
    }

    /// Validates the exact recording zero independently from descriptor
    /// persistence time. Legacy/imported sessions may omit it; when it exists,
    /// every durable mark must independently corroborate the same instant.
    func validateRecordingStart(
        _ recordingStartedAt: Date?,
        timeline: AudioTimelineDocument,
        sessionID: AudioSessionID
    ) throws {
        guard let recordingStartedAt else { return }
        guard validDate(recordingStartedAt) else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The recording start timestamp is invalid."
            )
        }
        let tolerance: TimeInterval = 0.001
        for mark in timeline.marks {
            let expectedCreatedAt = recordingStartedAt.addingTimeInterval(mark.timeSeconds)
            let difference = mark.createdAt.timeIntervalSince(expectedCreatedAt)
            guard validDate(expectedCreatedAt),
                  difference.isFinite,
                  abs(difference) <= tolerance else {
                throw NotebookRepositoryError.invalidAudioSession(
                    sessionID,
                    detail: "The timeline does not corroborate the recording start timestamp."
                )
            }
        }
    }

    func audioDescriptorValidationDetail(
        _ descriptor: AudioSessionDescriptor,
        manifest: NotebookManifest
    ) -> String? {
        guard (1...AudioSessionDescriptor.currentSchemaVersion).contains(descriptor.schemaVersion) else {
            return "The descriptor schema version is unsupported."
        }
        guard validDate(descriptor.createdAt),
              validDate(descriptor.modifiedAt),
              descriptor.modifiedAt >= descriptor.createdAt,
              descriptor.recordingStartedAt.map({ validDate($0) }) ?? true,
              descriptor.durationSeconds.isFinite,
              (0...AudioStorageLimits.maximumDurationSeconds).contains(descriptor.durationSeconds) else {
            return "The descriptor contains invalid timestamps or duration."
        }
        guard !descriptor.chunkFilenames.isEmpty,
              Set(descriptor.chunkFilenames.map(audioFilenameKey)).count == descriptor.chunkFilenames.count,
              descriptor.chunkFilenames.allSatisfy({ isSafeAudioFilename($0, expectedExtension: "m4a") }) else {
            return "The descriptor contains an unsafe or duplicate audio filename."
        }
        if let transcriptAssetID = descriptor.transcriptAssetID,
           (!transcriptAssetID.isSHA256Digest
            || !manifest.assets.contains(where: {
                $0.id == transcriptAssetID
                    && $0.mediaType == AudioTranscriptDocument.mediaType
            })) {
            return "The transcript asset reference is invalid."
        }
        if descriptor.schemaVersion < 2, descriptor.recordingStartedAt != nil {
            return "A legacy descriptor cannot contain recording replay metadata."
        }
        if descriptor.schemaVersion >= 2 {
            guard descriptor.chunkFilenames.count == 1,
                  let byteCount = descriptor.audioByteCount,
                  byteCount >= 12,
                  byteCount <= Int64(AudioStorageLimits.maximumAudioBytes),
                  let digest = descriptor.audioSHA256,
                  AssetID(digest).isSHA256Digest,
                  digest == digest.lowercased(),
                  let timelineFilename = descriptor.timelineFilename,
                  timelineFilename == "\(descriptor.id.description).timeline.json",
                  isSafeAudioFilename(timelineFilename, expectedExtension: "json") else {
                return "The schema-v2 descriptor is missing bounded audio integrity metadata or its timeline."
            }
        } else if let timelineFilename = descriptor.timelineFilename,
                  !isSafeAudioFilename(timelineFilename, expectedExtension: "json") {
            return "The legacy descriptor contains an unsafe timeline filename."
        }
        let hasAnyReplayField = descriptor.replayFilename != nil
            || descriptor.replayByteCount != nil
            || descriptor.replaySHA256 != nil
            || descriptor.replayEventCount != nil
        if descriptor.schemaVersion < 3 {
            guard !hasAnyReplayField else {
                return "A schema-v1 or schema-v2 descriptor cannot contain partial replay history metadata."
            }
        } else {
            guard descriptor.durationSeconds > 0,
                  let replayFilename = descriptor.replayFilename,
                  replayFilename == "\(descriptor.id.description).replay.json",
                  isSafeAudioFilename(replayFilename, expectedExtension: "json"),
                  let replayByteCount = descriptor.replayByteCount,
                  replayByteCount > 0,
                  replayByteCount <= Int64(NoteReplayHistoryLimits.maximumIndexBytes),
                  let replaySHA256 = descriptor.replaySHA256,
                  replaySHA256 == replaySHA256.lowercased(),
                  AssetID(replaySHA256).isSHA256Digest,
                  let replayEventCount = descriptor.replayEventCount,
                  replayEventCount >= 0,
                  replayEventCount <= NoteReplayHistoryLimits.maximumEventCount else {
                return "The schema-v3 descriptor is missing complete bounded replay history metadata."
            }
        }
        return nil
    }

    func isSafeAudioFilename(_ filename: String, expectedExtension: String) -> Bool {
        guard !filename.isEmpty,
              filename.utf8.count <= 255,
              !filename.hasPrefix("."),
              !filename.contains("/"),
              !filename.contains("\\"),
              !filename.contains(":"),
              !filename.contains("\0") else { return false }
        let url = URL(fileURLWithPath: filename, isDirectory: false)
        return url.lastPathComponent == filename
            && url.pathExtension.lowercased() == expectedExtension.lowercased()
    }

    /// APFS libraries are commonly case-insensitive. Treat canonically equivalent
    /// names as the same durable target even when tests run on a case-sensitive disk.
    func audioFilenameKey(_ filename: String) -> String {
        filename.precomposedStringWithCanonicalMapping.lowercased()
    }

    func safeAudioURL(
        filename: String,
        layout: NotebookPackageLayout,
        expectedExtension: String
    ) throws -> URL {
        guard isSafeAudioFilename(filename, expectedExtension: expectedExtension) else {
            throw NotebookRepositoryError.malformedPackage("An audio filename is unsafe.")
        }
        let url = layout.audioURL.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
        guard isURL(url, inside: layout.audioURL) else {
            throw NotebookRepositoryError.malformedPackage("An audio filename escaped its storage directory.")
        }
        return url
    }

    func audioFileURL(
        for descriptor: AudioSessionDescriptor,
        layout: NotebookPackageLayout
    ) throws -> URL {
        guard descriptor.chunkFilenames.count == 1,
              isSafeAudioFilename(descriptor.chunkFilenames[0], expectedExtension: "m4a") else {
            throw NotebookRepositoryError.invalidAudioSession(
                descriptor.id,
                detail: "The session does not reference exactly one safe M4A file."
            )
        }
        return try safeAudioURL(
            filename: descriptor.chunkFilenames[0],
            layout: layout,
            expectedExtension: "m4a"
        )
    }

    func storedAudioSessionIsValid(
        _ descriptor: AudioSessionDescriptor,
        manifest: NotebookManifest,
        layout: NotebookPackageLayout
    ) -> Bool {
        guard audioDescriptorValidationDetail(descriptor, manifest: manifest) == nil else {
            return false
        }
        for filename in descriptor.chunkFilenames {
            guard let url = try? safeAudioURL(
                filename: filename,
                layout: layout,
                expectedExtension: "m4a"
            ), let data = try? readBoundedRegularFileData(
                at: url,
                within: layout.packageURL,
                maximumBytes: AudioStorageLimits.maximumAudioBytes
            ), (try? validateAudioData(data, sessionID: descriptor.id)) != nil else {
                return false
            }
            if descriptor.schemaVersion >= 2 {
                guard Int64(data.count) == descriptor.audioByteCount,
                      SHA256.hexDigest(data) == descriptor.audioSHA256 else {
                    return false
                }
            }
        }
        guard let timelineFilename = descriptor.timelineFilename else {
            return descriptor.schemaVersion == 1
        }
        guard let timelineURL = try? safeAudioURL(
            filename: timelineFilename,
            layout: layout,
            expectedExtension: "json"
        ), let timelineData = try? readBoundedRegularFileData(
            at: timelineURL,
            within: layout.packageURL,
            maximumBytes: AudioStorageLimits.maximumTimelineBytes
        ), let timeline = try? decode(AudioTimelineDocument.self, from: timelineData),
        timeline.audioSessionID == descriptor.id,
        (try? validateAudioTimeline(
            timeline,
            durationSeconds: descriptor.durationSeconds,
            manifest: manifest
        )) != nil,
        (try? validateRecordingStart(
            descriptor.recordingStartedAt,
            timeline: timeline,
            sessionID: descriptor.id
        )) != nil else {
            return false
        }
        if let transcriptAssetID = descriptor.transcriptAssetID,
           let transcriptAsset = manifest.assets.first(where: { $0.id == transcriptAssetID }),
           transcriptAsset.mediaType == AudioTranscriptDocument.mediaType,
           !storedAudioTranscriptIsValid(
               descriptor: descriptor,
               asset: transcriptAsset,
               manifest: manifest,
               layout: layout,
               knownTimeline: timeline
           ) {
            return false
        }
        if descriptor.schemaVersion >= 3,
           !storedNoteReplayHistoryIsValid(
               descriptor: descriptor,
               timeline: timeline,
               manifest: manifest,
               layout: layout
           ) {
            return false
        }
        return true
    }

    func storedNoteReplayHistoryIsValid(
        descriptor: AudioSessionDescriptor,
        timeline: AudioTimelineDocument,
        manifest: NotebookManifest,
        layout: NotebookPackageLayout
    ) -> Bool {
        guard let validated = try? validatedStoredNoteReplayHistory(
            descriptor: descriptor,
            timeline: timeline,
            manifest: manifest,
            layout: layout,
            maximumEventCount: NoteReplayHistoryLimits.maximumEventCount
        ) else {
            return false
        }
        var assetsByID: [AssetID: AssetDescriptor] = [:]
        assetsByID.reserveCapacity(manifest.assets.count)
        for asset in manifest.assets {
            guard assetsByID.updateValue(asset, forKey: asset.id) == nil else {
                return false
            }
        }
        for reference in validated.authorized.ink {
            guard let asset = assetsByID[reference.assetID],
                  (try? readValidatedAssetData(
                      asset,
                      layout: layout,
                      maximumBytes: NoteReplayHistoryLimits.maximumInkPayloadBytes
                  )) != nil else {
                return false
            }
        }
        let validAssetIDs = Set(assetsByID.keys)
        for reference in validated.authorized.elements {
            guard let asset = assetsByID[reference.assetID],
                  let elementData = try? readValidatedAssetData(
                      asset,
                      layout: layout,
                      maximumBytes: NoteReplayHistoryLimits.maximumElementPayloadBytes
                  ), (try? preflightCanvasElementArray(
                      elementData,
                      relativePath: "assets/\(reference.assetID.rawValue)",
                      maximumElementCount:
                          NoteReplayHistoryLimits.maximumElementCountPerSnapshot
                  )) != nil,
                  let elements = try? NoteReplayPayloadCodec.decodeElements(elementData),
                  elements.count <= NoteReplayHistoryLimits.maximumElementCountPerSnapshot,
                  (try? validateCanvasElementsForExport(
                      elements,
                      validAssetIDs: validAssetIDs,
                      relativePath: "assets/\(reference.assetID.rawValue)"
                  )) != nil else {
                return false
            }
        }
        return true
    }

    func storedNoteReplayAssetIDsForGarbageCollection(
        descriptor: AudioSessionDescriptor,
        manifest: NotebookManifest,
        layout: NotebookPackageLayout
    ) throws -> Set<AssetID> {
        let sessionID = descriptor.id
        guard descriptor.schemaVersion >= 3,
              audioDescriptorValidationDetail(descriptor, manifest: manifest) == nil else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "Replay payload ownership cannot be established from an invalid descriptor."
            )
        }
        let timeline = try storedAudioTimeline(
            for: descriptor,
            manifest: manifest,
            layout: layout
        )
        guard storedNoteReplayHistoryIsValid(
            descriptor: descriptor,
            timeline: timeline,
            manifest: manifest,
            layout: layout
        ) else {
            try Task<Never, Never>.checkCancellation()
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "Replay payload ownership cannot be established from damaged sealed history."
            )
        }
        let validated = try validatedStoredNoteReplayHistory(
            descriptor: descriptor,
            timeline: timeline,
            manifest: manifest,
            layout: layout,
            maximumEventCount: NoteReplayHistoryLimits.maximumEventCount
        )
        var assetIDs = Set(validated.authorized.ink.map(\.assetID))
        assetIDs.formUnion(validated.authorized.elements.map(\.assetID))
        return assetIDs
    }

    func validatedStoredNoteReplayHistory(
        descriptor: AudioSessionDescriptor,
        timeline: AudioTimelineDocument,
        manifest: NotebookManifest,
        layout: NotebookPackageLayout,
        maximumEventCount: Int
    ) throws -> (
        document: NoteReplayHistoryDocument,
        authorized: (
            ink: Set<NoteReplayPayloadReference>,
            elements: Set<NoteReplayPayloadReference>
        )
    ) {
        let sessionID = descriptor.id
        guard descriptor.schemaVersion >= 3,
              let replayFilename = descriptor.replayFilename,
              let expectedByteCount = descriptor.replayByteCount,
              let expectedSHA256 = descriptor.replaySHA256 else {
            throw NotebookRepositoryError.invalidAudioSession(
                sessionID,
                detail: "The Note Replay descriptor metadata is incomplete."
            )
        }
        let replayURL = try safeAudioURL(
            filename: replayFilename,
            layout: layout,
            expectedExtension: "json"
        )
        let data = try readBoundedRegularFileData(
            at: replayURL,
            within: layout.packageURL,
            maximumBytes: NoteReplayHistoryLimits.maximumIndexBytes
        )
        guard Int64(data.count) == expectedByteCount,
              SHA256.hexDigest(data) == expectedSHA256 else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: replayURL, in: layout.packageURL)
            )
        }
        let document: NoteReplayHistoryDocument
        do {
            document = try decode(NoteReplayHistoryDocument.self, from: data)
        } catch {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: replayURL, in: layout.packageURL)
            )
        }
        let authorized = try validateStoredNoteReplayHistory(
            document,
            descriptor: descriptor,
            timeline: timeline,
            manifest: manifest,
            maximumEventCount: maximumEventCount
        )
        return (document, authorized)
    }

    func storedAudioTranscriptIsValid(
        descriptor: AudioSessionDescriptor,
        asset: AssetDescriptor,
        manifest: NotebookManifest,
        layout: NotebookPackageLayout,
        knownTimeline: AudioTimelineDocument? = nil
    ) -> Bool {
        guard asset.id == descriptor.transcriptAssetID,
              asset.mediaType == AudioTranscriptDocument.mediaType,
              let data = try? readValidatedAssetData(
                  asset,
                  layout: layout,
                  maximumBytes: AudioTranscriptDocument.maximumEncodedBytes
              ), let transcript = try? decode(AudioTranscriptDocument.self, from: data),
              let timeline = knownTimeline ?? (try? storedAudioTimeline(
                  for: descriptor,
                  manifest: manifest,
                  layout: layout
              )), (try? validateAudioTranscript(
                  transcript,
                  descriptor: descriptor,
                  timeline: timeline
              )) != nil else {
            return false
        }
        return true
    }

    func referencedAudioFilenames(_ descriptor: AudioSessionDescriptor) -> [String] {
        var filenames = descriptor.chunkFilenames.filter {
            isSafeAudioFilename($0, expectedExtension: "m4a")
        }
        if let timelineFilename = descriptor.timelineFilename,
           isSafeAudioFilename(timelineFilename, expectedExtension: "json") {
            filenames.append(timelineFilename)
        }
        if let replayFilename = descriptor.replayFilename,
           isSafeAudioFilename(replayFilename, expectedExtension: "json") {
            filenames.append(replayFilename)
        }
        return filenames
    }

    func quarantineAudioEntry(at url: URL, layout: NotebookPackageLayout) throws {
        guard fileSystemEntryExists(at: url) else { return }
        if isSymbolicLinkEntry(at: url) {
            try secureRemoveItem(at: url, within: layout.packageURL)
            return
        }
        let quarantineURL = layout.audioURL.appendingPathComponent(
            ".recovered-\(UUID().uuidString)-\(url.lastPathComponent)",
            isDirectory: false
        )
        try FileManager.default.moveItem(at: url, to: quarantineURL)
    }

    func rejectUnsupportedFutureSchemas(in layout: NotebookPackageLayout) throws {
        for manifestURL in [layout.manifestURL, layout.backupManifestURL] {
            guard fileSystemEntryExists(at: manifestURL) else { continue }
            let data = try readBoundedRegularFileData(
                at: manifestURL,
                within: layout.packageURL,
                maximumBytes: StructuredContentLimits.maximumEncodedBytes
            )
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            if let version = (object["schemaVersion"] as? NSNumber)?.intValue,
               version > NotebookManifest.currentSchemaVersion {
                throw NotebookRepositoryError.malformedPackage(
                    "This notebook requires a newer manifest schema."
                )
            }
            let pages = (object["pages"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
            if pages.contains(where: {
                (($0["schemaVersion"] as? NSNumber)?.intValue ?? 1) > PageDescriptor.currentSchemaVersion
            }) == true {
                throw NotebookRepositoryError.malformedPackage(
                    "This notebook requires a newer page schema."
                )
            }
            let audioSessions = (object["audioSessions"] as? [Any])?.compactMap {
                $0 as? [String: Any]
            } ?? []
            let assets = (object["assets"] as? [Any])?.compactMap {
                $0 as? [String: Any]
            } ?? []
            func rawIdentifier(_ value: Any?) -> String? {
                if let string = value as? String { return string.lowercased() }
                return ((value as? [String: Any])?["rawValue"] as? String)?.lowercased()
            }
            let transcriptAssetIDs = Set(assets.compactMap { asset -> String? in
                guard asset["mediaType"] as? String == AudioTranscriptDocument.mediaType else {
                    return nil
                }
                return rawIdentifier(asset["id"])
            })
            if audioSessions.contains(where: {
                (($0["schemaVersion"] as? NSNumber)?.intValue ?? 1) > AudioSessionDescriptor.currentSchemaVersion
            }) == true {
                throw NotebookRepositoryError.malformedPackage(
                    "This notebook requires a newer audio-session schema."
                )
            }
            for session in audioSessions {
                if let transcriptAssetID = rawIdentifier(session["transcriptAssetID"]),
                   transcriptAssetIDs.contains(transcriptAssetID) {
                    let transcriptURL = layout.assetURL(AssetID(transcriptAssetID))
                    if let transcriptData = try? readBoundedRegularFileData(
                        at: transcriptURL,
                        within: layout.packageURL,
                        maximumBytes: AudioTranscriptDocument.maximumEncodedBytes
                    ), let transcriptObject = try? JSONSerialization.jsonObject(
                        with: transcriptData
                    ) as? [String: Any],
                    let version = (transcriptObject["schemaVersion"] as? NSNumber)?.intValue,
                    version > AudioTranscriptDocument.currentSchemaVersion {
                        throw NotebookRepositoryError.malformedPackage(
                            "This notebook requires a newer audio-transcript schema."
                        )
                    }
                }
                if let replayFilename = session["replayFilename"] as? String,
                   isSafeAudioFilename(replayFilename, expectedExtension: "json") {
                    let replayURL = layout.audioURL.appendingPathComponent(
                        replayFilename,
                        isDirectory: false
                    )
                    if let replayData = try? readBoundedRegularFileData(
                        at: replayURL,
                        within: layout.packageURL,
                        maximumBytes: NoteReplayHistoryLimits.maximumIndexBytes
                    ), let replayObject = try? JSONSerialization.jsonObject(
                        with: replayData
                    ) as? [String: Any],
                    let version = (replayObject["schemaVersion"] as? NSNumber)?.intValue,
                    version > NoteReplayHistoryDocument.currentSchemaVersion {
                        throw NotebookRepositoryError.malformedPackage(
                            "This notebook requires a newer Note Replay history schema."
                        )
                    }
                }
                guard let filename = session["timelineFilename"] as? String,
                      isSafeAudioFilename(filename, expectedExtension: "json") else { continue }
                let timelineURL = layout.audioURL.appendingPathComponent(filename, isDirectory: false)
                let values = try? timelineURL.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
                )
                guard values?.isRegularFile == true,
                      values?.isSymbolicLink != true,
                      let size = values?.fileSize,
                      size <= AudioStorageLimits.maximumTimelineBytes,
                      let timelineData = try? readBoundedRegularFileData(
                        at: timelineURL,
                        within: layout.packageURL,
                        maximumBytes: AudioStorageLimits.maximumTimelineBytes
                      ), let timelineObject = try? JSONSerialization.jsonObject(
                        with: timelineData
                      ) as? [String: Any] else { continue }
                if let version = (timelineObject["schemaVersion"] as? NSNumber)?.intValue,
                   version > AudioTimelineDocument.currentSchemaVersion {
                    throw NotebookRepositoryError.malformedPackage(
                        "This notebook requires a newer audio-timeline schema."
                    )
                }
                let marks = (timelineObject["marks"] as? [Any])?.compactMap {
                    $0 as? [String: Any]
                } ?? []
                if marks.contains(where: {
                    (($0["schemaVersion"] as? NSNumber)?.intValue ?? 1) > AudioTimelineMark.currentSchemaVersion
                }) == true {
                    throw NotebookRepositoryError.malformedPackage(
                        "This notebook requires a newer audio-timeline-mark schema."
                    )
                }
            }
        }

        guard let pageDirectories = try? FileManager.default.contentsOfDirectory(
            at: layout.pagesURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for directory in pageDirectories {
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            let descriptorURL = directory.appendingPathComponent("page.json", isDirectory: false)
            if fileSystemEntryExists(at: descriptorURL) {
                let data = try readBoundedRegularFileData(
                    at: descriptorURL,
                    within: layout.packageURL,
                    maximumBytes: 1 * 1_024 * 1_024
                )
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let version = (object["schemaVersion"] as? NSNumber)?.intValue,
                   version > PageDescriptor.currentSchemaVersion {
                    throw NotebookRepositoryError.malformedPackage(
                        "This notebook requires a newer page schema."
                    )
                }
            }

            let recognitionURL = directory.appendingPathComponent(
                NotebookPackageLayout.handwritingRecognitionFilename,
                isDirectory: false
            )
            guard fileSystemEntryExists(at: recognitionURL),
                  !isSymbolicLinkEntry(at: recognitionURL) else { continue }
            let recognitionValues = try? recognitionURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            guard recognitionValues?.isRegularFile == true else { continue }
            guard let recognitionSize = recognitionValues?.fileSize,
                  recognitionSize <= HandwritingRecognitionLimits.maximumEncodedBytes else {
                throw NotebookRepositoryError.malformedPackage(
                    "A handwriting-recognition sidecar exceeds this version's safe storage limit."
                )
            }
            guard let recognitionData = try? readBoundedRegularFileData(
                at: recognitionURL,
                within: layout.packageURL,
                maximumBytes: HandwritingRecognitionLimits.maximumEncodedBytes
            ), let recognitionObject = try? JSONSerialization.jsonObject(
                with: recognitionData
            ) as? [String: Any],
            let recognitionVersion = (recognitionObject["schemaVersion"] as? NSNumber)?.intValue else {
                continue
            }
            if recognitionVersion > HandwritingRecognitionDocument.currentSchemaVersion {
                throw NotebookRepositoryError.malformedPackage(
                    "This notebook requires a newer handwriting-recognition schema."
                )
            }
        }
    }

    func existingLayout(_ id: NotebookID) throws -> NotebookPackageLayout {
        let package = packageURL(for: id)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: package.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NotebookRepositoryError.notebookNotFound(id)
        }
        return NotebookPackageLayout(packageURL: package)
    }

    func createPackageDirectories(_ layout: NotebookPackageLayout) throws {
        let directories = [
            layout.packageURL,
            layout.pagesURL,
            layout.operationsURL,
            layout.transactionsURL,
            layout.assetsURL,
            layout.audioURL,
            layout.derivedURL.appendingPathComponent("previews", isDirectory: true),
            layout.derivedURL.appendingPathComponent("search", isDirectory: true)
        ]
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }
    }

    func createTransactionPageDirectory(
        layout: NotebookPackageLayout,
        pageID: PageID,
        allowExistingDirectory: Bool
    ) throws -> Bool {
        let pagesDescriptor = try openItemWithoutFollowingLinks(
            at: layout.pagesURL,
            within: layout.packageURL,
            finalFlags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        defer { _ = Darwin.close(pagesDescriptor) }

        let directoryName = pageID.description
        let createResult = directoryName.withCString {
            Darwin.mkdirat(pagesDescriptor, $0, mode_t(S_IRWXU))
        }
        let createError = errno
        let wasCreated: Bool
        if createResult == 0 {
            wasCreated = true
        } else if createError == EEXIST, allowExistingDirectory {
            wasCreated = false
        } else if createError == EEXIST {
            throw NotebookRepositoryError.duplicatePage(pageID)
        } else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: layout.pageURL(pageID), in: layout.packageURL)
            )
        }

        let pageDescriptor = directoryName.withCString {
            Darwin.openat(
                pagesDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard pageDescriptor >= 0 else {
            if wasCreated {
                directoryName.withCString {
                    _ = Darwin.unlinkat(pagesDescriptor, $0, AT_REMOVEDIR)
                }
            }
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: layout.pageURL(pageID), in: layout.packageURL)
            )
        }
        _ = Darwin.fsync(pageDescriptor)
        _ = Darwin.close(pageDescriptor)
        _ = Darwin.fsync(pagesDescriptor)
        return wasCreated
    }

    func requireTransactionPageDirectoryToBeAbsent(
        layout: NotebookPackageLayout,
        pageID: PageID
    ) throws {
        let pagesDescriptor = try openItemWithoutFollowingLinks(
            at: layout.pagesURL,
            within: layout.packageURL,
            finalFlags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        defer { _ = Darwin.close(pagesDescriptor) }

        var metadata = stat()
        let directoryName = pageID.description
        let inspectResult = directoryName.withCString {
            Darwin.fstatat(pagesDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        let inspectError = errno
        if inspectResult == 0 {
            throw NotebookRepositoryError.duplicatePage(pageID)
        }
        guard inspectError == ENOENT else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: layout.pageURL(pageID), in: layout.packageURL)
            )
        }
    }

    func plannedManifestWrites(
        _ manifest: NotebookManifest,
        layout: NotebookPackageLayout,
        preservePrevious: Bool
    ) throws -> [PlannedFileWrite] {
        var writes: [PlannedFileWrite] = []
        if preservePrevious,
           FileManager.default.fileExists(atPath: layout.manifestURL.path),
           let previousData = try? Data(contentsOf: layout.manifestURL),
           (try? decode(NotebookManifest.self, from: previousData)) != nil {
            writes.append(.init(url: layout.backupManifestURL, data: previousData))
        }
        // The manifest is deliberately last. Its revision is the transaction's
        // durable commit marker during crash recovery.
        writes.append(.init(url: layout.manifestURL, data: try encode(manifest)))
        return writes
    }

    func commitTransaction(
        command: EditCommand,
        expectedRevision: Int64,
        layout: NotebookPackageLayout,
        writes: [PlannedFileWrite],
        cleanupDirectories: [String] = []
    ) throws {
        guard command.sequence == expectedRevision + 1,
              writes.last?.url.standardizedFileURL == layout.manifestURL.standardizedFileURL else {
            throw NotebookRepositoryError.malformedPackage(
                "A transaction must advance exactly one revision and commit its manifest last."
            )
        }

        try resolvePendingTransactions(layout: layout)
        let packageNotebookID = try notebookID(from: layout)
        guard command.notebookID == packageNotebookID else {
            throw NotebookRepositoryError.malformedPackage("A transaction belongs to another notebook.")
        }
        if command.kind == .createNotebook {
            guard expectedRevision == 0,
                  !FileManager.default.fileExists(atPath: layout.manifestURL.path) else {
                throw NotebookRepositoryError.malformedPackage("The create transaction found an existing manifest.")
            }
        } else {
            guard let data = try? Data(contentsOf: layout.manifestURL),
                  let current = try? decode(NotebookManifest.self, from: data),
                  current.id == command.notebookID,
                  current.revision == expectedRevision else {
                throw NotebookRepositoryError.malformedPackage("The transaction was prepared from a stale notebook revision.")
            }
        }
        invalidateExportSessions(for: packageNotebookID)
        let transactionDirectory = layout.transactionsURL.appendingPathComponent(
            command.id.description,
            isDirectory: true
        )
        let record = try prepareTransaction(
            command: command,
            expectedRevision: expectedRevision,
            layout: layout,
            transactionDirectory: transactionDirectory,
            writes: writes,
            cleanupDirectories: cleanupDirectories
        )

        var stateIsCommitted = false
        var provisionedCleanupDirectories: [String] = []
        var stateFilesMayHaveChanged = false
        do {
            try Task<Never, Never>.checkCancellation()
            provisionedCleanupDirectories = try provisionTransactionCleanupDirectory(
                record,
                layout: layout,
                allowExistingDirectory: false
            )
            stateFilesMayHaveChanged = true
            try applyStagedFiles(record, layout: layout, transactionDirectory: transactionDirectory)
            stateIsCommitted = transactionIsCommitted(record, layout: layout)
            guard stateIsCommitted else {
                throw NotebookRepositoryError.malformedPackage(
                    "The manifest did not expose the committed transaction revision."
                )
            }
        } catch {
            stateIsCommitted = stateIsCommitted || transactionIsCommitted(record, layout: layout)
            if !stateIsCommitted {
                do {
                    if stateFilesMayHaveChanged {
                        try rollbackTransaction(
                            record,
                            layout: layout,
                            transactionDirectory: transactionDirectory,
                            cleanupDirectoriesToRemove: provisionedCleanupDirectories
                        )
                    }
                    try FileManager.default.removeItem(at: transactionDirectory)
                } catch {
                    // The durable journal and its backups remain in place. Recovery
                    // will retry the rollback before another mutation can commit.
                }
                throw error
            }
        }

        // From this point the requested mutation is durably committed. Journal or
        // operation-log failures must not be reported as a failed user operation;
        // the prepared journal is itself sufficient to replay the missing log entry.
        do {
            var committedRecord = record
            committedRecord.phase = .stateCommitted
            try failureInjector?(.beforeTransactionPhaseWrite)
            try writeTransactionRecord(committedRecord, in: transactionDirectory, preservePreparedBackup: true)
            try appendOperation(committedRecord.command, layout: layout)
            try FileManager.default.removeItem(at: transactionDirectory)
        } catch {
            // Intentionally retain the transaction directory. `validateNotebook`
            // surfaces it and `recoverNotebook` deterministically rolls it forward.
        }
    }

    func prepareTransaction(
        command: EditCommand,
        expectedRevision: Int64,
        layout: NotebookPackageLayout,
        transactionDirectory: URL,
        writes: [PlannedFileWrite],
        cleanupDirectories: [String]
    ) throws -> TransactionRecord {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: transactionDirectory.path) else {
            throw NotebookRepositoryError.malformedPackage("A transaction with this identifier already exists.")
        }

        let normalizedCleanupDirectories = try cleanupDirectories.map { relative -> String in
            let url = layout.packageURL.appendingPathComponent(relative, isDirectory: true).standardizedFileURL
            guard isURL(url, inside: layout.packageURL) else {
                throw NotebookRepositoryError.malformedPackage("A rollback directory escaped its package.")
            }
            return normalizedRelativePath(of: url, in: layout.packageURL)
        }
        let targetPaths = try writes.map { write -> String in
            guard isURL(write.url, inside: layout.packageURL) else {
                throw NotebookRepositoryError.malformedPackage("A transaction target escaped its package.")
            }
            return normalizedRelativePath(of: write.url, in: layout.packageURL)
        }
        let newPageCleanup = try validatedTransactionCleanupDirectory(
            command: command,
            cleanupDirectories: normalizedCleanupDirectories,
            fileRelativePaths: targetPaths,
            layout: layout
        )
        if let newPageCleanup {
            try requireTransactionPageDirectoryToBeAbsent(
                layout: layout,
                pageID: newPageCleanup.pageID
            )
        }

        var seenTargets = Set<String>()
        var transactionFiles: [TransactionFile] = []
        do {
            try fileManager.createDirectory(
                at: transactionDirectory.appendingPathComponent("staged", isDirectory: true),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try fileManager.createDirectory(
                at: transactionDirectory.appendingPathComponent("backups", isDirectory: true),
                withIntermediateDirectories: true,
                attributes: nil
            )

            for (index, write) in writes.enumerated() {
                try Task<Never, Never>.checkCancellation()
                let targetPath = targetPaths[index]
                guard seenTargets.insert(targetPath).inserted else {
                    throw NotebookRepositoryError.malformedPackage("A transaction contains duplicate file targets.")
                }
                let belongsToNewPage = newPageCleanup.map {
                    targetPath.hasPrefix("\($0.relativePath)/")
                } ?? false
                let existedBeforeTransaction = belongsToNewPage
                    ? false
                    : fileSystemEntryExists(at: write.url)
                let customMaximumBytes = try validatedTransactionMaximum(
                    write.maximumByteCount,
                    target: write.url,
                    layout: layout,
                    command: command,
                    deletesTarget: write.deletesTarget,
                    existedBeforeTransaction: existedBeforeTransaction
                )
                if write.deletesTarget,
                   !isAudioTarget(write.url, layout: layout),
                   !(customMaximumBytes != nil
                     && isContentAddressedAssetTarget(write.url, layout: layout)) {
                    throw NotebookRepositoryError.malformedPackage(
                        "A transaction attempted to delete an unsupported target."
                    )
                }
                let basename = String(format: "%04d.data", index)
                let stagedRelative = "staged/\(basename)"
                let stagedURL = transactionDirectory.appendingPathComponent(stagedRelative, isDirectory: false)
                if let source = write.streamingAudioSource {
                    try stageAudioSource(
                        source,
                        to: stagedURL,
                        layout: layout
                    )
                    try failureInjector?(.afterAudioSourceStaged)
                    try Task<Never, Never>.checkCancellation()
                } else {
                    try atomicWrite(write.data, to: stagedURL)
                }

                let targetMaximumBytes = customMaximumBytes
                    ?? maximumBytesForProtectedTarget(write.url, layout: layout)
                let isProtectedTarget = targetMaximumBytes != nil
                let existed: Bool
                if belongsToNewPage {
                    existed = false
                } else {
                    existed = isProtectedTarget
                        ? fileSystemEntryExists(at: write.url)
                        : fileManager.fileExists(atPath: write.url.path)
                }
                var backupRelative: String?
                if existed {
                    backupRelative = "backups/\(basename)"
                    let oldData: Data
                    if let maximumBytes = targetMaximumBytes {
                        oldData = try readBoundedRegularFileData(
                            at: write.url,
                            within: layout.packageURL,
                            maximumBytes: maximumBytes
                        )
                    } else {
                        oldData = try Data(contentsOf: write.url, options: .mappedIfSafe)
                    }
                    if customMaximumBytes != nil {
                        try validateContentAddressedTransactionAssetData(
                            oldData,
                            target: write.url,
                            command: command
                        )
                    }
                    try atomicWrite(
                        oldData,
                        to: transactionDirectory.appendingPathComponent(backupRelative!, isDirectory: false)
                    )
                }
                transactionFiles.append(.init(
                    relativePath: targetPath,
                    stagedFilename: stagedRelative,
                    backupFilename: backupRelative,
                    existedBeforeTransaction: existed,
                    deletesTarget: write.deletesTarget ? true : nil,
                    stagedByteCount: write.streamingAudioSource?.byteCount,
                    stagedSHA256: write.streamingAudioSource?.sha256,
                    maximumByteCount: customMaximumBytes
                ))
            }
            try Task<Never, Never>.checkCancellation()

            let record = TransactionRecord(
                command: command,
                expectedRevision: expectedRevision,
                files: transactionFiles,
                cleanupDirectories: normalizedCleanupDirectories
            )
            try writeTransactionRecord(record, in: transactionDirectory, preservePreparedBackup: false)
            return record
        } catch {
            try? fileManager.removeItem(at: transactionDirectory)
            throw error
        }
    }

    func writeTransactionRecord(
        _ record: TransactionRecord,
        in transactionDirectory: URL,
        preservePreparedBackup: Bool
    ) throws {
        let journalURL = transactionDirectory.appendingPathComponent("transaction.json", isDirectory: false)
        let backupURL = transactionDirectory.appendingPathComponent("transaction.backup.json", isDirectory: false)
        if !preservePreparedBackup || !FileManager.default.fileExists(atPath: backupURL.path) {
            try writeJSON(record, to: backupURL)
        }
        try writeJSON(record, to: journalURL)
    }

    func readTransactionRecord(in transactionDirectory: URL) throws -> (record: TransactionRecord, usedBackup: Bool) {
        let journalURL = transactionDirectory.appendingPathComponent("transaction.json", isDirectory: false)
        if let data = try? Data(contentsOf: journalURL),
           let record = try? decode(TransactionRecord.self, from: data),
           record.schemaVersion == TransactionRecord.currentSchemaVersion {
            return (record, false)
        }
        let backupURL = transactionDirectory.appendingPathComponent("transaction.backup.json", isDirectory: false)
        if let data = try? Data(contentsOf: backupURL),
           let record = try? decode(TransactionRecord.self, from: data),
           record.schemaVersion == TransactionRecord.currentSchemaVersion {
            return (record, true)
        }
        throw NotebookRepositoryError.corruptedFile(
            "ops/transactions/\(transactionDirectory.lastPathComponent)/transaction.json"
        )
    }

    func applyStagedFiles(
        _ record: TransactionRecord,
        layout: NotebookPackageLayout,
        transactionDirectory: URL,
        injectFailures: Bool = true
    ) throws {
        var recoveredReplayAssetDeletionsWereValidated = false
        for file in record.files {
            if injectFailures {
                try Task<Never, Never>.checkCancellation()
            }
            let target = try transactionTargetURL(file.relativePath, layout: layout)
            let staged = transactionDirectory
                .appendingPathComponent(file.stagedFilename, isDirectory: false)
                .standardizedFileURL
            guard isURL(staged, inside: transactionDirectory) else {
                throw NotebookRepositoryError.corruptedFile(
                    "ops/transactions/\(transactionDirectory.lastPathComponent)/staged"
                )
            }
            guard FileManager.default.fileExists(atPath: staged.path) else {
                throw NotebookRepositoryError.corruptedFile(
                    "ops/transactions/\(transactionDirectory.lastPathComponent)/\(file.stagedFilename)"
                )
            }
            if injectFailures {
                try failureInjector?(.beforeStateWrite(relativePath: file.relativePath))
            }
            let customMaximumBytes = try validatedTransactionMaximum(
                file.maximumByteCount,
                target: target,
                layout: layout,
                command: record.command,
                deletesTarget: file.deletesTarget == true,
                existedBeforeTransaction: file.existedBeforeTransaction
            )
            let targetMaximumBytes = customMaximumBytes
                ?? maximumBytesForProtectedTarget(target, layout: layout)
            if file.deletesTarget == true {
                let isProtectedAudioDeletion = isAudioTarget(target, layout: layout)
                    && maximumBytesForProtectedTarget(target, layout: layout) != nil
                let isReplayAssetDeletion = customMaximumBytes != nil
                    && isContentAddressedAssetTarget(target, layout: layout)
                guard isProtectedAudioDeletion || isReplayAssetDeletion else {
                    throw NotebookRepositoryError.malformedPackage(
                        "A transaction attempted to delete an unsupported target."
                    )
                }
                if isReplayAssetDeletion,
                   !injectFailures,
                   !recoveredReplayAssetDeletionsWereValidated {
                    try validateCommittedReplayAssetDeletions(
                        record,
                        layout: layout,
                        transactionDirectory: transactionDirectory
                    )
                    recoveredReplayAssetDeletionsWereValidated = true
                }
                if fileSystemEntryExists(at: target) {
                    if let customMaximumBytes {
                        let currentData = try readBoundedRegularFileData(
                            at: target,
                            within: layout.packageURL,
                            maximumBytes: customMaximumBytes
                        )
                        try validateContentAddressedTransactionAssetData(
                            currentData,
                            target: target,
                            command: record.command
                        )
                    }
                    try secureRemoveItem(at: target, within: layout.packageURL)
                }
                continue
            }
            if target.pathExtension.lowercased() == "m4a",
               isAudioTarget(target, layout: layout),
               let uuid = UUID(uuidString: target.deletingPathExtension().lastPathComponent) {
                try secureInstallAudioSource(
                    from: staged,
                    to: target,
                    within: layout.packageURL,
                    sessionID: AudioSessionID(uuid),
                    expectedByteCount: file.stagedByteCount,
                    expectedSHA256: file.stagedSHA256
                )
                continue
            }
            let data: Data
            if let maximumBytes = targetMaximumBytes {
                data = try readBoundedRegularFileData(
                    at: staged,
                    within: layout.packageURL,
                    maximumBytes: maximumBytes
                )
            } else {
                data = try Data(contentsOf: staged, options: .mappedIfSafe)
            }
            if customMaximumBytes != nil {
                try validateContentAddressedTransactionAssetData(
                    data,
                    target: target,
                    command: record.command
                )
            }
            if targetMaximumBytes != nil {
                try secureAtomicWrite(
                    data,
                    to: target,
                    within: layout.packageURL,
                    maximumBytes: targetMaximumBytes ?? StructuredContentLimits.maximumEncodedBytes
                )
            } else {
                try atomicWrite(data, to: target)
            }
        }
    }

    func rollbackTransaction(
        _ record: TransactionRecord,
        layout: NotebookPackageLayout,
        transactionDirectory: URL,
        cleanupDirectoriesToRemove: [String]? = nil
    ) throws {
        let fileManager = FileManager.default
        let validatedCleanupDirectory = try validatedTransactionCleanupDirectory(
            record,
            layout: layout
        )
        for file in record.files.reversed() {
            let target = try transactionTargetURL(file.relativePath, layout: layout)
            let customMaximumBytes = try validatedTransactionMaximum(
                file.maximumByteCount,
                target: target,
                layout: layout,
                command: record.command,
                deletesTarget: file.deletesTarget == true,
                existedBeforeTransaction: file.existedBeforeTransaction
            )
            let targetMaximumBytes = customMaximumBytes
                ?? maximumBytesForProtectedTarget(target, layout: layout)
            if file.deletesTarget == true,
               !(
                   (isAudioTarget(target, layout: layout)
                    && maximumBytesForProtectedTarget(target, layout: layout) != nil)
                    || (customMaximumBytes != nil
                        && isContentAddressedAssetTarget(target, layout: layout))
               ) {
                throw NotebookRepositoryError.malformedPackage(
                    "A transaction attempted to roll back an unsupported deletion."
                )
            }
            if file.existedBeforeTransaction {
                guard let backupFilename = file.backupFilename else {
                    throw NotebookRepositoryError.corruptedFile(
                        "ops/transactions/\(transactionDirectory.lastPathComponent)/backups"
                    )
                }
                let backup = transactionDirectory
                    .appendingPathComponent(backupFilename, isDirectory: false)
                    .standardizedFileURL
                guard isURL(backup, inside: transactionDirectory) else {
                    throw NotebookRepositoryError.corruptedFile(
                        "ops/transactions/\(transactionDirectory.lastPathComponent)/backups"
                    )
                }
                guard fileManager.fileExists(atPath: backup.path) else {
                    throw NotebookRepositoryError.corruptedFile(
                        "ops/transactions/\(transactionDirectory.lastPathComponent)/\(backupFilename)"
                    )
                }
                let data: Data
                if let maximumBytes = targetMaximumBytes {
                    data = try readBoundedRegularFileData(
                        at: backup,
                        within: layout.packageURL,
                        maximumBytes: maximumBytes
                    )
                } else {
                    data = try Data(contentsOf: backup, options: .mappedIfSafe)
                }
                if customMaximumBytes != nil {
                    try validateContentAddressedTransactionAssetData(
                        data,
                        target: target,
                        command: record.command
                    )
                }
                if targetMaximumBytes != nil {
                    try secureAtomicWrite(
                        data,
                        to: target,
                        within: layout.packageURL,
                        maximumBytes: targetMaximumBytes ?? StructuredContentLimits.maximumEncodedBytes
                    )
                } else {
                    try atomicWrite(data, to: target)
                }
            } else {
                let targetExists = targetMaximumBytes != nil
                    ? fileSystemEntryExists(at: target)
                    : fileManager.fileExists(atPath: target.path)
                if targetExists {
                    if customMaximumBytes != nil {
                        try validateContentAddressedRollbackRemoval(
                            target: target,
                            record: record,
                            layout: layout,
                            maximumBytes: customMaximumBytes!
                        )
                    }
                    if targetMaximumBytes != nil {
                        try secureRemoveItem(at: target, within: layout.packageURL)
                    } else {
                        try fileManager.removeItem(at: target)
                    }
                }
            }
        }
        let cleanupDirectories = cleanupDirectoriesToRemove
            ?? validatedCleanupDirectory.map { [$0.relativePath] }
            ?? []
        if let cleanupDirectoriesToRemove {
            let permitted = validatedCleanupDirectory.map { [$0.relativePath] } ?? []
            guard cleanupDirectoriesToRemove == permitted || cleanupDirectoriesToRemove.isEmpty else {
                throw NotebookRepositoryError.malformedPackage(
                    "A rollback attempted to remove an unowned directory."
                )
            }
        }
        for relative in cleanupDirectories.sorted(by: { $0.count > $1.count }) {
            let directory = try transactionTargetURL(relative, layout: layout)
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        }
    }

    func transactionIsCommitted(_ record: TransactionRecord, layout: NotebookPackageLayout) -> Bool {
        currentManifestRevision(layout: layout, notebookID: record.command.notebookID) == record.targetRevision
    }

    func currentManifestRevision(layout: NotebookPackageLayout, notebookID: NotebookID) -> Int64? {
        guard let data = try? Data(contentsOf: layout.manifestURL),
              let manifest = try? decode(NotebookManifest.self, from: data),
              manifest.id == notebookID else { return nil }
        return manifest.revision
    }

    func transactionTargetURL(_ relativePath: String, layout: NotebookPackageLayout) throws -> URL {
        let target = layout.packageURL.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
        guard isURL(target, inside: layout.packageURL) else {
            throw NotebookRepositoryError.malformedPackage("A transaction path escaped its package.")
        }
        return target
    }

    func normalizedRelativePath(of url: URL, in package: URL) -> String {
        relativePath(of: url, in: package).replacingOccurrences(of: "\\", with: "/")
    }

    func transactionDirectories(layout: NotebookPackageLayout) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: layout.transactionsURL.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: layout.transactionsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func resolvePendingTransactions(layout: NotebookPackageLayout) throws {
        var ignoredActions: [RecoveryAction] = []
        try resolvePendingTransactions(layout: layout, actions: &ignoredActions)
    }

    func resolvePendingTransactions(
        layout: NotebookPackageLayout,
        actions: inout [RecoveryAction]
    ) throws {
        let fileManager = FileManager.default
        let directories = try transactionDirectories(layout: layout)
        if !directories.isEmpty {
            invalidateExportSessions(for: try notebookID(from: layout))
        }
        for directory in directories {
            let loaded: (record: TransactionRecord, usedBackup: Bool)
            do {
                loaded = try readTransactionRecord(in: directory)
            } catch {
                // A directory without either journal is left only by a crash during
                // preparation, before any live file can be changed.
                let current = directory.appendingPathComponent("transaction.json")
                let backup = directory.appendingPathComponent("transaction.backup.json")
                guard !fileManager.fileExists(atPath: current.path),
                      !fileManager.fileExists(atPath: backup.path) else {
                    throw error
                }
                try fileManager.removeItem(at: directory)
                actions.append(.removedOrphanTransaction)
                continue
            }

            let record = loaded.record
            let packageNotebookID = try notebookID(from: layout)
            guard record.command.notebookID == packageNotebookID else {
                throw NotebookRepositoryError.malformedPackage("A transaction belongs to another notebook.")
            }
            if loaded.usedBackup {
                actions.append(.restoredTransactionJournal)
            }

            let liveRevision = currentManifestRevision(
                layout: layout,
                notebookID: record.command.notebookID
            )
            if let liveRevision, liveRevision > record.targetRevision {
                // A later authoritative revision can only be observed if this
                // transaction committed earlier. Never overwrite it with staged
                // historical data; only restore the missing audit entry.
                try appendOperation(record.command, layout: layout)
                try fileManager.removeItem(at: directory)
                actions.append(.finalizedCommittedTransaction)
            } else if liveRevision == record.targetRevision {
                // Replaying staged files is idempotent and repairs a torn/corrupted
                // committed state before publishing the missing operation entry.
                _ = try provisionTransactionCleanupDirectory(
                    record,
                    layout: layout,
                    allowExistingDirectory: true
                )
                try applyStagedFiles(record, layout: layout, transactionDirectory: directory, injectFailures: false)
                try appendOperation(record.command, layout: layout)
                try fileManager.removeItem(at: directory)
                actions.append(.finalizedCommittedTransaction)
            } else if record.phase == .stateCommitted {
                // The phase marker is written only after the target manifest is
                // durable. Never trust an isolated journal assertion to replay
                // destructive writes when that authoritative revision is absent.
                throw NotebookRepositoryError.malformedPackage(
                    "A committed transaction is missing its authoritative manifest revision."
                )
            } else if liveRevision == nil || liveRevision == record.expectedRevision {
                try rollbackTransaction(record, layout: layout, transactionDirectory: directory)
                try fileManager.removeItem(at: directory)
                actions.append(.rolledBackTransaction)
            } else {
                throw NotebookRepositoryError.malformedPackage(
                    "A pending transaction conflicts with the live manifest revision."
                )
            }
        }
    }

    func notebookID(from layout: NotebookPackageLayout) throws -> NotebookID {
        guard let uuid = UUID(uuidString: layout.packageURL.deletingPathExtension().lastPathComponent) else {
            throw NotebookRepositoryError.malformedPackage("The package name is not a notebook identifier.")
        }
        return NotebookID(uuid)
    }

    func invalidateExportSessions(for notebookID: NotebookID) {
        activeExportSessions = activeExportSessions.filter {
            $0.value.token.notebookID != notebookID
        }
    }

    func isURL(_ candidate: URL, inside container: URL) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let containerComponents = container.standardizedFileURL.pathComponents
        guard candidateComponents.count > containerComponents.count else { return false }
        return Array(candidateComponents.prefix(containerComponents.count)) == containerComponents
    }

    func provisionTransactionCleanupDirectory(
        _ record: TransactionRecord,
        layout: NotebookPackageLayout,
        allowExistingDirectory: Bool
    ) throws -> [String] {
        guard let cleanup = try validatedTransactionCleanupDirectory(record, layout: layout) else {
            return []
        }
        let wasCreated = try createTransactionPageDirectory(
            layout: layout,
            pageID: cleanup.pageID,
            allowExistingDirectory: allowExistingDirectory
        )
        return wasCreated ? [cleanup.relativePath] : []
    }

    func validatedTransactionCleanupDirectory(
        _ record: TransactionRecord,
        layout: NotebookPackageLayout
    ) throws -> (relativePath: String, pageID: PageID)? {
        let cleanup = try validatedTransactionCleanupDirectory(
            command: record.command,
            cleanupDirectories: record.cleanupDirectories,
            fileRelativePaths: record.files.map(\.relativePath),
            layout: layout
        )
        guard let cleanup else { return nil }
        let expectedDescriptor = normalizedRelativePath(
            of: layout.pageDescriptorURL(cleanup.pageID),
            in: layout.packageURL
        )
        guard record.files.contains(where: {
            $0.relativePath == expectedDescriptor
                && !$0.existedBeforeTransaction
                && $0.deletesTarget != true
        }) else {
            throw NotebookRepositoryError.malformedPackage(
                "A transaction rollback directory did not match its new page."
            )
        }
        return cleanup
    }

    func validatedTransactionCleanupDirectory(
        command: EditCommand,
        cleanupDirectories: [String],
        fileRelativePaths: [String],
        layout: NotebookPackageLayout
    ) throws -> (relativePath: String, pageID: PageID)? {
        guard !cleanupDirectories.isEmpty else { return nil }
        guard cleanupDirectories.count == 1,
              command.kind == .createNotebook || command.kind == .addPage else {
            throw NotebookRepositoryError.malformedPackage(
                "A transaction declared an unsupported rollback directory."
            )
        }

        let cleanupComponents = cleanupDirectories[0].split(separator: "/")
        guard cleanupComponents.count == 2,
              cleanupComponents[0] == "pages",
              let pageUUID = UUID(uuidString: String(cleanupComponents[1])) else {
            throw NotebookRepositoryError.malformedPackage(
                "A transaction declared an invalid page rollback directory."
            )
        }
        let pageID = PageID(pageUUID)
        if command.kind == .addPage {
            guard command.pageID == pageID else {
                throw NotebookRepositoryError.malformedPackage(
                    "An add-page transaction declared another page's rollback directory."
                )
            }
        } else if let commandPageID = command.pageID {
            guard commandPageID == pageID else {
                throw NotebookRepositoryError.malformedPackage(
                    "A create transaction declared another page's rollback directory."
                )
            }
        }

        let expectedDirectory = normalizedRelativePath(
            of: layout.pageURL(pageID),
            in: layout.packageURL
        )
        let expectedDescriptor = normalizedRelativePath(
            of: layout.pageDescriptorURL(pageID),
            in: layout.packageURL
        )
        guard cleanupDirectories[0] == expectedDirectory,
              fileRelativePaths.contains(expectedDescriptor) else {
            throw NotebookRepositoryError.malformedPackage(
                "A transaction rollback directory did not match its new page."
            )
        }
        return (expectedDirectory, pageID)
    }

    func readManifest(id: NotebookID) throws -> NotebookManifest {
        let layout = try existingLayout(id)
        try resolvePendingTransactions(layout: layout)
        guard FileManager.default.fileExists(atPath: layout.manifestURL.path) else {
            throw NotebookRepositoryError.corruptedFile("manifest.json")
        }
        do {
            let manifest = try decode(NotebookManifest.self, from: Data(contentsOf: layout.manifestURL))
            guard manifest.id == id else {
                throw NotebookRepositoryError.malformedPackage("Manifest identifier does not match its package name.")
            }
            return manifest
        } catch let error as NotebookRepositoryError {
            throw error
        } catch {
            throw NotebookRepositoryError.corruptedFile("manifest.json")
        }
    }

    /// Read-only manifest path used before export/replay content decoding. It intentionally does
    /// not run recovery (which may inspect legacy transaction files); callers reach this API only
    /// after the normal open/flush path has serialized pending writes on this repository actor.
    /// A corrupt package therefore fails closed without any unbounded or link-following read.
    func readManifestForBoundedContentRead(
        id: NotebookID,
        layout: NotebookPackageLayout
    ) throws -> NotebookManifest {
        try loadBoundedExportManifest(id: id, layout: layout).manifest
    }

    func loadBoundedExportManifest(
        id: NotebookID,
        layout: NotebookPackageLayout
    ) throws -> LoadedBoundedExportManifest {
        try ensureNoPendingTransactionsForBoundedContentRead(layout: layout)
        let packageIdentity = try currentPackageDirectoryIdentity(layout: layout)
        let loaded: (data: Data, identity: ManifestFileIdentity)
        do {
            guard let manifestRead = try readBoundedManifestDataAndIdentityIfPresent(
                at: layout.manifestURL,
                within: layout.packageURL,
                maximumBytes: NotebookExportReadLimits.maximumManifestBytes
            ) else {
                throw NotebookRepositoryError.corruptedFile("manifest.json")
            }
            loaded = manifestRead
        } catch NotebookRepositoryError.boundedReadLimitExceeded(_, _) {
            throw NotebookRepositoryError.corruptedFile("manifest.json")
        }
        do {
            let manifest = try decode(NotebookManifest.self, from: loaded.data)
            guard manifest.id == id else {
                throw NotebookRepositoryError.malformedPackage(
                    "Manifest identifier does not match its package name."
                )
            }
            try validateManifestForBoundedContentRead(manifest)
            try failureInjector?(.afterBoundedExportManifestDecode(notebookID: id))
            guard try currentPackageDirectoryIdentity(layout: layout) == packageIdentity,
                  try currentManifestFileIdentity(layout: layout) == loaded.identity else {
                throw NotebookRepositoryError.corruptedFile("manifest.json")
            }
            return LoadedBoundedExportManifest(
                manifest: manifest,
                manifestIdentity: loaded.identity,
                packageIdentity: packageIdentity
            )
        } catch let error as CancellationError {
            throw error
        } catch let error as NotebookRepositoryError {
            throw error
        } catch {
            throw NotebookRepositoryError.corruptedFile("manifest.json")
        }
    }

    func validatedActiveExportSession(
        _ session: NotebookExportSession
    ) throws -> ActiveNotebookExportSession {
        guard let active = activeExportSessions[session.id],
              active.token == session,
              active.token.notebookID == session.notebookID else {
            throw NotebookRepositoryError.invalidExportSession
        }
        let layout: NotebookPackageLayout
        do {
            layout = try existingLayout(session.notebookID)
            try ensureNoPendingTransactionsForBoundedContentRead(layout: layout)
            guard try currentPackageDirectoryIdentity(layout: layout) == active.packageIdentity,
                  try currentManifestFileIdentity(layout: layout) == active.manifestIdentity else {
                throw NotebookRepositoryError.invalidExportSession
            }
        } catch let error as CancellationError {
            throw error
        } catch {
            activeExportSessions.removeValue(forKey: session.id)
            throw NotebookRepositoryError.invalidExportSession
        }
        return active
    }

    func currentPackageDirectoryIdentity(
        layout: NotebookPackageLayout
    ) throws -> PackageDirectoryIdentity {
        let descriptor = layout.packageURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw NotebookRepositoryError.corruptedFile(layout.packageURL.lastPathComponent)
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR else {
            throw NotebookRepositoryError.corruptedFile(layout.packageURL.lastPathComponent)
        }
        return PackageDirectoryIdentity(
            device: UInt64(bitPattern: Int64(metadata.st_dev)),
            inode: UInt64(metadata.st_ino)
        )
    }

    func currentManifestFileIdentity(
        layout: NotebookPackageLayout
    ) throws -> ManifestFileIdentity {
        guard let descriptor = try openItemWithoutFollowingLinksIfPresent(
            at: layout.manifestURL,
            within: layout.packageURL,
            finalFlags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        ) else {
            throw NotebookRepositoryError.corruptedFile("manifest.json")
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= off_t(NotebookExportReadLimits.maximumManifestBytes) else {
            throw NotebookRepositoryError.corruptedFile("manifest.json")
        }
        return manifestFileIdentity(metadata)
    }

    func manifestFileIdentity(_ metadata: stat) -> ManifestFileIdentity {
        ManifestFileIdentity(
            device: UInt64(bitPattern: Int64(metadata.st_dev)),
            inode: UInt64(metadata.st_ino),
            linkCount: UInt64(metadata.st_nlink),
            byteCount: Int64(metadata.st_size),
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }

    func readBoundedManifestDataAndIdentityIfPresent(
        at url: URL,
        within packageURL: URL,
        maximumBytes: Int
    ) throws -> (data: Data, identity: ManifestFileIdentity)? {
        let itemRelativePath = relativePath(of: url, in: packageURL)
        guard maximumBytes >= 0, maximumBytes < Int.max else {
            throw NotebookRepositoryError.corruptedFile(itemRelativePath)
        }
        guard let descriptor = try openItemWithoutFollowingLinksIfPresent(
            at: url,
            within: packageURL,
            finalFlags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        ) else { return nil }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0 else {
            throw NotebookRepositoryError.corruptedFile(itemRelativePath)
        }
        guard metadata.st_size <= off_t(maximumBytes) else {
            throw NotebookRepositoryError.boundedReadLimitExceeded(
                relativePath: itemRelativePath,
                limit: maximumBytes
            )
        }
        let initialIdentity = manifestFileIdentity(metadata)
        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let remaining = maximumBytes - data.count
            let requestedCount = min(buffer.count, remaining + 1)
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, requestedCount)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw NotebookRepositoryError.corruptedFile(itemRelativePath)
            }
            if bytesRead == 0 { break }
            guard bytesRead <= remaining else {
                throw NotebookRepositoryError.boundedReadLimitExceeded(
                    relativePath: itemRelativePath,
                    limit: maximumBytes
                )
            }
            data.append(contentsOf: buffer.prefix(bytesRead))
            try failureInjector?(.duringBoundedContentRead(
                relativePath: itemRelativePath,
                bytesRead: data.count
            ))
        }
        var finalMetadata = stat()
        guard Darwin.fstat(descriptor, &finalMetadata) == 0,
              manifestFileIdentity(finalMetadata) == initialIdentity else {
            throw NotebookRepositoryError.corruptedFile(itemRelativePath)
        }
        return (data, initialIdentity)
    }

    func sourceSnapshotFileIdentity(
        _ metadata: stat
    ) -> SourceSnapshotFileIdentity {
        SourceSnapshotFileIdentity(
            device: UInt64(bitPattern: Int64(metadata.st_dev)),
            inode: UInt64(metadata.st_ino),
            linkCount: UInt64(metadata.st_nlink),
            byteCount: Int64(metadata.st_size),
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec),
            statusChangeSeconds: Int64(metadata.st_ctimespec.tv_sec),
            statusChangeNanoseconds: Int64(metadata.st_ctimespec.tv_nsec)
        )
    }

    func readBoundedSourceSnapshotFileIfPresent(
        at url: URL,
        within packageURL: URL,
        maximumBytes: Int
    ) throws -> BoundedSourceSnapshotFile? {
        let itemRelativePath = relativePath(of: url, in: packageURL)
        guard maximumBytes >= 0, maximumBytes < Int.max else {
            throw NotebookRepositoryError.corruptedFile(itemRelativePath)
        }
        guard let descriptor = try openItemWithoutFollowingLinksIfPresent(
            at: url,
            within: packageURL,
            finalFlags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        ) else {
            return nil
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0 else {
            throw NotebookRepositoryError.corruptedFile(itemRelativePath)
        }
        guard metadata.st_size <= off_t(maximumBytes) else {
            throw NotebookRepositoryError.boundedReadLimitExceeded(
                relativePath: itemRelativePath,
                limit: maximumBytes
            )
        }
        let initialIdentity = sourceSnapshotFileIdentity(metadata)

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            let remaining = maximumBytes - data.count
            let requestedCount = min(buffer.count, remaining + 1)
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, requestedCount)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw NotebookRepositoryError.corruptedFile(itemRelativePath)
            }
            if bytesRead == 0 { break }
            guard bytesRead <= remaining else {
                throw NotebookRepositoryError.boundedReadLimitExceeded(
                    relativePath: itemRelativePath,
                    limit: maximumBytes
                )
            }
            data.append(contentsOf: buffer.prefix(bytesRead))
            try failureInjector?(.duringBoundedContentRead(
                relativePath: itemRelativePath,
                bytesRead: data.count
            ))
        }

        var finalMetadata = stat()
        guard Darwin.fstat(descriptor, &finalMetadata) == 0,
              sourceSnapshotFileIdentity(finalMetadata) == initialIdentity else {
            throw NotebookRepositoryError.corruptedFile(itemRelativePath)
        }
        return BoundedSourceSnapshotFile(
            data: data,
            identity: initialIdentity
        )
    }

    func currentSourceSnapshotFileIdentity(
        at url: URL,
        within packageURL: URL,
        maximumBytes: Int
    ) throws -> SourceSnapshotFileIdentity {
        let itemRelativePath = relativePath(of: url, in: packageURL)
        let descriptor = try openItemWithoutFollowingLinks(
            at: url,
            within: packageURL,
            finalFlags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= off_t(maximumBytes) else {
            throw NotebookRepositoryError.corruptedFile(itemRelativePath)
        }
        return sourceSnapshotFileIdentity(metadata)
    }

    func validateTextDocumentSourceSnapshotFence(
        layout: NotebookPackageLayout,
        manifest: LoadedBoundedExportManifest,
        pageDescriptorURL: URL,
        pageDescriptorIdentity: SourceSnapshotFileIdentity,
        contentURL: URL,
        contentIdentity: SourceSnapshotFileIdentity
    ) throws {
        try ensureNoPendingTransactionsForBoundedContentRead(layout: layout)
        guard try currentSourceSnapshotFileIdentity(
            at: pageDescriptorURL,
            within: layout.packageURL,
            maximumBytes: PageDescriptorStorageLimits.maximumEncodedBytes
        ) == pageDescriptorIdentity else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: pageDescriptorURL, in: layout.packageURL)
            )
        }
        guard try currentSourceSnapshotFileIdentity(
            at: contentURL,
            within: layout.packageURL,
            maximumBytes: StructuredContentLimits.maximumEncodedBytes
        ) == contentIdentity else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: contentURL, in: layout.packageURL)
            )
        }
        guard try currentPackageDirectoryIdentity(layout: layout)
                == manifest.packageIdentity else {
            throw NotebookRepositoryError.corruptedFile(
                layout.packageURL.lastPathComponent
            )
        }
        // The authoritative manifest is deliberately the last file identity
        // checked. Repository transactions publish it last, so this is the
        // publication fence that prevents a mixed-revision result.
        try ensureNoPendingTransactionsForBoundedContentRead(layout: layout)
        guard try currentManifestFileIdentity(layout: layout)
                == manifest.manifestIdentity else {
            throw NotebookRepositoryError.corruptedFile("manifest.json")
        }
    }

    func validateManifestForBoundedContentRead(
        _ manifest: NotebookManifest
    ) throws {
        guard manifest.revision >= 0,
              manifest.createdAt.timeIntervalSinceReferenceDate.isFinite,
              manifest.modifiedAt.timeIntervalSinceReferenceDate.isFinite,
              manifest.pages.count <= NotebookExportReadLimits.maximumNotebookPageCount,
              manifest.assets.count <= NotebookExportReadLimits.maximumManifestAssetCount,
              manifest.audioSessions.count
                <= NotebookExportReadLimits.maximumManifestAudioSessionCount,
              manifest.tags.count <= NotebookExportReadLimits.maximumManifestTagCount else {
            throw NotebookRepositoryError.corruptedFile("manifest.json")
        }

        var totalStringBytes = 0
        func validateString(_ value: String?, maximumBytes: Int = 1 * 1_024 * 1_024) throws {
            guard let value else { return }
            let byteCount = value.utf8.count
            guard byteCount <= maximumBytes,
                  totalStringBytes <= 8 * 1_024 * 1_024 - byteCount else {
                throw NotebookRepositoryError.corruptedFile("manifest.json")
            }
            totalStringBytes += byteCount
        }

        try validateString(manifest.title)
        guard !manifest.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NotebookRepositoryError.corruptedFile("manifest.json")
        }
        for tag in manifest.tags {
            try validateString(tag, maximumBytes: 64 * 1_024)
        }

        var pageIDs = Set<PageID>()
        pageIDs.reserveCapacity(manifest.pages.count)
        let assetIDs = Set(manifest.assets.map(\.id))
        guard assetIDs.count == manifest.assets.count else {
            throw NotebookRepositoryError.malformedPackage(
                "Asset identifiers must be unique."
            )
        }
        for page in manifest.pages {
            try Task.checkCancellation()
            guard pageIDs.insert(page.id).inserted,
                  page.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  page.modifiedAt.timeIntervalSinceReferenceDate.isFinite,
                  page.size.width.isFinite,
                  page.size.height.isFinite,
                  page.size.width > 0,
                  page.size.height > 0,
                  page.size.width <= NotebookExportReadLimits.maximumPageDimension,
                  page.size.height <= NotebookExportReadLimits.maximumPageDimension,
                  (0..<360).contains(page.rotationDegrees) else {
                throw NotebookRepositoryError.corruptedFile("manifest.json")
            }
            try validateString(page.title)
            guard PageDescriptor.isValidOutlineTitle(page.outlineTitle) else {
                throw NotebookRepositoryError.corruptedFile("manifest.json")
            }
            try validateString(
                page.outlineTitle,
                maximumBytes: PageDescriptor.maximumOutlineTitleUTF8Bytes
            )
            switch page.background {
            case .plain(let colorHex):
                try validateString(colorHex, maximumBytes: 128)
            case .ruled(let colorHex, let spacing),
                 .grid(let colorHex, let spacing),
                 .dotted(let colorHex, let spacing):
                try validateString(colorHex, maximumBytes: 128)
                guard spacing.isFinite,
                      spacing > 0,
                      spacing <= NotebookExportReadLimits.maximumPageDimension else {
                    throw NotebookRepositoryError.corruptedFile("manifest.json")
                }
            case .pdf(let assetID, let pageIndex):
                guard assetID.isSHA256Digest,
                      assetIDs.contains(assetID),
                      pageIndex >= 0 else {
                    throw NotebookRepositoryError.corruptedFile("manifest.json")
                }
            case .image(let assetID), .asset(let assetID):
                guard assetID.isSHA256Digest,
                      assetIDs.contains(assetID) else {
                    throw NotebookRepositoryError.corruptedFile("manifest.json")
                }
            }
        }

        var validatedAssetIDs = Set<AssetID>()
        validatedAssetIDs.reserveCapacity(manifest.assets.count)
        for asset in manifest.assets {
            try Task.checkCancellation()
            guard validatedAssetIDs.insert(asset.id).inserted,
                  asset.id.isSHA256Digest,
                  asset.byteCount >= 0,
                  asset.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw NotebookRepositoryError.corruptedFile("manifest.json")
            }
            try validateString(asset.mediaType, maximumBytes: 1_024)
            try validateString(asset.originalFilename, maximumBytes: 64 * 1_024)
        }

        var audioSessionIDs = Set<AudioSessionID>()
        audioSessionIDs.reserveCapacity(manifest.audioSessions.count)
        for session in manifest.audioSessions {
            try Task.checkCancellation()
            guard audioSessionIDs.insert(session.id).inserted,
                  session.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  session.modifiedAt.timeIntervalSinceReferenceDate.isFinite,
                  session.recordingStartedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
                  session.durationSeconds.isFinite,
                  session.durationSeconds >= 0,
                  session.audioByteCount.map({ $0 >= 0 }) ?? true,
                  session.audioSHA256.map({
                      AssetID($0).isSHA256Digest
                  }) ?? true,
                  session.transcriptAssetID.map({
                      $0.isSHA256Digest && assetIDs.contains($0)
                  }) ?? true,
                  session.chunkFilenames.count <= 10_000 else {
                throw NotebookRepositoryError.corruptedFile("manifest.json")
            }
            for filename in session.chunkFilenames {
                try validateString(filename, maximumBytes: 4_096)
            }
            try validateString(session.audioSHA256, maximumBytes: 128)
            try validateString(session.timelineFilename, maximumBytes: 4_096)
        }
    }

    func ensureNoPendingTransactionsForBoundedContentRead(
        layout: NotebookPackageLayout
    ) throws {
        let descriptor = try openItemWithoutFollowingLinks(
            at: layout.transactionsURL,
            within: layout.packageURL,
            finalFlags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard let directory = Darwin.fdopendir(descriptor) else {
            _ = Darwin.close(descriptor)
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: layout.transactionsURL, in: layout.packageURL)
            )
        }
        defer { _ = Darwin.closedir(directory) }

        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { bytes -> String in
                guard let baseAddress = bytes.baseAddress else { return "" }
                return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
            }
            guard name == "." || name == ".." else {
                throw NotebookRepositoryError.malformedPackage(
                    "A pending transaction must be resolved before bounded content can be read."
                )
            }
        }
        guard errno == 0 else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: layout.transactionsURL, in: layout.packageURL)
            )
        }
    }

    func writeManifest(_ manifest: NotebookManifest, layout: NotebookPackageLayout, preservePrevious: Bool) throws {
        if preservePrevious,
           FileManager.default.fileExists(atPath: layout.manifestURL.path),
           let previousData = try? Data(contentsOf: layout.manifestURL),
           (try? decode(NotebookManifest.self, from: previousData)) != nil {
            try atomicWrite(previousData, to: layout.backupManifestURL)
        }
        try writeJSON(manifest, to: layout.manifestURL)
    }

    func appendOperation(_ command: EditCommand, layout: NotebookPackageLayout) throws {
        let sequence = String(format: "%020lld", command.sequence)
        let filename = "\(sequence)-\(command.id.description).json"
        let operationURL = layout.operationsURL.appendingPathComponent(filename, isDirectory: false)
        if FileManager.default.fileExists(atPath: operationURL.path) {
            if let existing = try? decode(EditCommand.self, from: Data(contentsOf: operationURL)),
               existing == command {
                return
            }
            let quarantineURL = operationURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: operationURL, to: quarantineURL)
        }
        try failureInjector?(.beforeOperationLogWrite)
        try writeJSON(command, to: operationURL)
    }

    func readOperationLog(layout: NotebookPackageLayout) throws -> [EditCommand] {
        guard FileManager.default.fileExists(atPath: layout.operationsURL.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: layout.operationsURL,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { $0.pathExtension == "json" }
        return try urls.compactMap { url in
            do {
                return try decode(EditCommand.self, from: Data(contentsOf: url))
            } catch {
                throw NotebookRepositoryError.corruptedFile(relativePath(of: url, in: layout.packageURL))
            }
        }.sorted {
            if $0.sequence == $1.sequence { return $0.timestamp < $1.timestamp }
            return $0.sequence < $1.sequence
        }
    }

    func scanValidManifests() throws -> [NotebookManifest] {
        let packageURLs = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == NotebookPackageLayout.packageExtension }

        return packageURLs.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true,
                  let uuid = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
            let layout = NotebookPackageLayout(packageURL: url)
            guard let manifest = try? decode(NotebookManifest.self, from: Data(contentsOf: layout.manifestURL)),
                  manifest.id == NotebookID(uuid) else { return nil }
            return manifest
        }.sorted {
            if $0.modifiedAt == $1.modifiedAt { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.modifiedAt > $1.modifiedAt
        }
    }

    func resolveLibraryTransactions() throws {
        let packageURLs = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == NotebookPackageLayout.packageExtension }
        for packageURL in packageURLs {
            let values = try? packageURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true,
                  UUID(uuidString: packageURL.deletingPathExtension().lastPathComponent) != nil else { continue }
            try resolvePendingTransactions(layout: NotebookPackageLayout(packageURL: packageURL))
        }
    }

    func refreshDerivedLibraryIndex() throws {
        try writeLibraryIndex(scanValidManifests())
    }

    func writeLibraryIndex(_ manifests: [NotebookManifest]) throws {
        let index = LibraryIndex(schemaVersion: 1, generatedAt: Date(), notebooks: manifests)
        try writeJSON(index, to: rootURL.appendingPathComponent("library-index.json", isDirectory: false))
    }

    func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        // Adding the 1970/2001 epoch offset can discard low bits from Date's
        // stored Double. A tagged bit pattern is exact while the decoder below
        // remains compatible with the previous numeric and ISO-8601 formats.
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let interval = date.timeIntervalSinceReferenceDate
            guard interval.isFinite else {
                throw EncodingError.invalidValue(
                    date,
                    .init(codingPath: encoder.codingPath, debugDescription: "Dates must be finite.")
                )
            }
            var container = encoder.singleValueContainer()
            try container.encode("notes-date-v1:\(String(interval.bitPattern, radix: 16))")
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let string = try container.decode(String.self)
            let exactPrefix = "notes-date-v1:"
            if string.hasPrefix(exactPrefix),
               let bits = UInt64(string.dropFirst(exactPrefix.count), radix: 16) {
                let interval = Double(bitPattern: bits)
                guard interval.isFinite else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "The exact date bit pattern is not finite."
                    )
                }
                return Date(timeIntervalSinceReferenceDate: interval)
            }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected seconds since 1970 or an ISO-8601 date."
            )
        }
        return decoder
    }

    func encode<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try makeDecoder().decode(type, from: data)
    }

    func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try atomicWrite(encode(value), to: url)
    }

    func atomicWrite(_ data: Data, to destination: URL) throws {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: nil)
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try data.write(to: temporary)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(
                    destination,
                    withItemAt: temporary,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    func relativePath(of url: URL, in package: URL) -> String {
        let packagePath = package.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(packagePath) else { return url.lastPathComponent }
        return String(path.dropFirst(packagePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
    }

    func findTemporaryFiles(in package: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: package,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "tmp" {
            result.append(url)
        }
        return result
    }

    func isStructuredContentTarget(_ url: URL, layout: NotebookPackageLayout) -> Bool {
        let components = normalizedRelativePath(of: url, in: layout.packageURL).split(separator: "/")
        return components.count == 3
            && components[0] == "pages"
            && UUID(uuidString: String(components[1])) != nil
            && components[2] == "content.json"
    }

    func isManifestTarget(_ url: URL, layout: NotebookPackageLayout) -> Bool {
        let path = normalizedRelativePath(of: url, in: layout.packageURL)
        return path == "manifest.json" || path == "manifest.backup.json"
    }

    func isPageDescriptorTarget(
        _ url: URL,
        layout: NotebookPackageLayout
    ) -> Bool {
        let components = normalizedRelativePath(of: url, in: layout.packageURL)
            .split(separator: "/")
        return components.count == 3
            && components[0] == "pages"
            && UUID(uuidString: String(components[1])) != nil
            && components[2] == "page.json"
    }

    func isCanvasElementsTarget(
        _ url: URL,
        layout: NotebookPackageLayout
    ) -> Bool {
        let components = normalizedRelativePath(of: url, in: layout.packageURL)
            .split(separator: "/")
        return components.count == 3
            && components[0] == "pages"
            && UUID(uuidString: String(components[1])) != nil
            && components[2] == "elements.json"
    }

    func isHandwritingRecognitionTarget(
        _ url: URL,
        layout: NotebookPackageLayout
    ) -> Bool {
        let components = normalizedRelativePath(of: url, in: layout.packageURL)
            .split(separator: "/")
        return components.count == 3
            && components[0] == "pages"
            && UUID(uuidString: String(components[1])) != nil
            && String(components[2]) == NotebookPackageLayout.handwritingRecognitionFilename
    }

    func isAudioTarget(_ url: URL, layout: NotebookPackageLayout) -> Bool {
        let components = normalizedRelativePath(of: url, in: layout.packageURL).split(separator: "/")
        return components.count == 2 && components[0] == "audio"
    }

    func isContentAddressedAssetTarget(
        _ url: URL,
        layout: NotebookPackageLayout
    ) -> Bool {
        let components = normalizedRelativePath(of: url, in: layout.packageURL)
            .split(separator: "/")
        return components.count == 2
            && components[0] == "assets"
            && AssetID(String(components[1])).isSHA256Digest
    }

    func validatedTransactionMaximum(
        _ maximumByteCount: Int?,
        target: URL,
        layout: NotebookPackageLayout,
        command: EditCommand,
        deletesTarget: Bool,
        existedBeforeTransaction: Bool
    ) throws -> Int? {
        guard let maximumByteCount else { return nil }
        let components = normalizedRelativePath(of: target, in: layout.packageURL)
            .split(separator: "/")
        let isAssetTarget = components.count == 2
            && components[0] == "assets"
            && AssetID(String(components[1])).isSHA256Digest
        let isTranscriptAsset = maximumByteCount == AudioTranscriptDocument.maximumEncodedBytes
            && command.kind == .saveAudioTranscript
            && command.payload["assetID"] == String(components.last ?? "")
        let isReplayAsset = command.kind == .addAudioSession
            && (maximumByteCount == NoteReplayHistoryLimits.maximumInkPayloadBytes
                || maximumByteCount == NoteReplayHistoryLimits.maximumElementPayloadBytes)
        let isReplayAssetDeletion = (
            command.kind == .deletePage || command.kind == .deleteAudioSession
        )
            && deletesTarget
            && existedBeforeTransaction
            && (maximumByteCount == NoteReplayHistoryLimits.maximumInkPayloadBytes
                || maximumByteCount == NoteReplayHistoryLimits.maximumElementPayloadBytes)
        if isReplayAssetDeletion, isAssetTarget {
            return maximumByteCount
        }
        guard !deletesTarget,
              existedBeforeTransaction == false,
              isAssetTarget,
              isTranscriptAsset || isReplayAsset else {
            throw NotebookRepositoryError.malformedPackage(
                "A transaction contains an unsupported custom file-size bound."
            )
        }
        return maximumByteCount
    }

    func validateContentAddressedTransactionAssetData(
        _ data: Data,
        target: URL,
        command: EditCommand
    ) throws {
        let assetID = target.lastPathComponent
        guard AssetID(assetID).isSHA256Digest,
              SHA256.hexDigest(data) == assetID,
              command.kind == .addAudioSession
                || command.kind == .deletePage
                || command.kind == .deleteAudioSession
                || command.payload["assetID"] == assetID else {
            throw NotebookRepositoryError.malformedPackage(
                "A transaction contains an invalid content-addressed asset."
            )
        }
    }

    func validateCommittedReplayAssetDeletions(
        _ record: TransactionRecord,
        layout: NotebookPackageLayout,
        transactionDirectory: URL
    ) throws {
        guard record.command.kind == .deletePage
                || record.command.kind == .deleteAudioSession,
              let manifestFile = record.files.last,
              manifestFile.relativePath == "manifest.json",
              manifestFile.deletesTarget != true else {
            throw NotebookRepositoryError.malformedPackage(
                "A replay-asset deletion transaction has no authoritative final manifest."
            )
        }

        let stagedManifestURL = transactionDirectory
            .appendingPathComponent(manifestFile.stagedFilename, isDirectory: false)
            .standardizedFileURL
        guard isURL(stagedManifestURL, inside: transactionDirectory),
              let liveManifestData = try? readBoundedRegularFileData(
                  at: layout.manifestURL,
                  within: layout.packageURL,
                  maximumBytes: NotebookExportReadLimits.maximumManifestBytes
              ),
              let stagedManifestData = try? readBoundedRegularFileData(
                  at: stagedManifestURL,
                  within: transactionDirectory,
                  maximumBytes: NotebookExportReadLimits.maximumManifestBytes
              ),
              let liveManifest = try? decode(
                  NotebookManifest.self,
                  from: liveManifestData
              ),
              let stagedManifest = try? decode(
                  NotebookManifest.self,
                  from: stagedManifestData
              ),
              liveManifest == stagedManifest,
              liveManifest.id == record.command.notebookID,
              liveManifest.revision == record.targetRevision else {
            throw NotebookRepositoryError.malformedPackage(
                "A replay-asset deletion transaction does not match its committed manifest."
            )
        }

        let deletionFiles = record.files.filter { file in
            guard file.deletesTarget == true,
                  file.maximumByteCount == NoteReplayHistoryLimits.maximumInkPayloadBytes
                    || file.maximumByteCount
                        == NoteReplayHistoryLimits.maximumElementPayloadBytes else {
                return false
            }
            let components = file.relativePath.split(separator: "/")
            return components.count == 2
                && components[0] == "assets"
                && AssetID(String(components[1])).isSHA256Digest
        }
        let candidateAssetIDs = Set(deletionFiles.map {
            AssetID(String($0.relativePath.split(separator: "/")[1]))
        })
        guard !candidateAssetIDs.isEmpty,
              candidateAssetIDs.count == deletionFiles.count,
              liveManifest.assets.allSatisfy({
                  !candidateAssetIDs.contains($0.id)
              }),
              let nonCatalogReferences = manifestNonCatalogAssetReferences(
                  among: candidateAssetIDs,
                  manifest: liveManifest,
                  layout: layout
              ),
              nonCatalogReferences.isDisjoint(with: candidateAssetIDs) else {
            throw NotebookRepositoryError.malformedPackage(
                "A committed replay-asset deletion still has a live manifest reference."
            )
        }

        for descriptor in liveManifest.audioSessions
            where descriptor.schemaVersion >= 3 {
            guard audioDescriptorValidationDetail(
                      descriptor,
                      manifest: liveManifest
                  ) == nil,
                  let timeline = try? storedAudioTimeline(
                      for: descriptor,
                      manifest: liveManifest,
                      layout: layout
                  ),
                  storedNoteReplayHistoryIsValid(
                      descriptor: descriptor,
                      timeline: timeline,
                      manifest: liveManifest,
                      layout: layout
                  ) else {
                throw NotebookRepositoryError.malformedPackage(
                    "A committed replay-asset deletion leaves invalid replay history."
                )
            }
        }
    }

    func validateContentAddressedRollbackRemoval(
        target: URL,
        record: TransactionRecord,
        layout: NotebookPackageLayout,
        maximumBytes: Int
    ) throws {
        let data = try readBoundedRegularFileData(
            at: target,
            within: layout.packageURL,
            maximumBytes: maximumBytes
        )
        try validateContentAddressedTransactionAssetData(
            data,
            target: target,
            command: record.command
        )
        guard let manifestData = try? readBoundedRegularFileData(
                  at: layout.manifestURL,
                  within: layout.packageURL,
                  maximumBytes: StructuredContentLimits.maximumEncodedBytes
              ),
              let manifest = try? decode(NotebookManifest.self, from: manifestData),
              manifest.id == record.command.notebookID,
              manifest.revision == record.expectedRevision,
              !manifestReferencesAsset(
                  AssetID(target.lastPathComponent),
                  manifest: manifest,
                  layout: layout
              ) else {
            throw NotebookRepositoryError.malformedPackage(
                "A transaction cannot remove an asset referenced by the live manifest."
            )
        }
    }

    func manifestReferencesAsset(
        _ assetID: AssetID,
        manifest: NotebookManifest,
        layout: NotebookPackageLayout
    ) -> Bool {
        if manifest.assets.contains(where: { $0.id == assetID }) { return true }
        return manifestNonCatalogAssetReferences(
            among: [assetID],
            manifest: manifest,
            layout: layout
        )?.contains(assetID) ?? true
    }

    func manifestNonCatalogAssetReferences(
        among candidates: Set<AssetID>,
        manifest: NotebookManifest,
        layout: NotebookPackageLayout
    ) -> Set<AssetID>? {
        guard !candidates.isEmpty else { return [] }
        var referencedAssetIDs = Set(
            manifest.audioSessions.compactMap(\.transcriptAssetID).filter {
                candidates.contains($0)
            }
        )
        for page in manifest.pages {
            switch page.background {
            case .pdf(let backgroundAssetID, _),
                 .image(let backgroundAssetID),
                 .asset(let backgroundAssetID):
                if candidates.contains(backgroundAssetID) {
                    referencedAssetIDs.insert(backgroundAssetID)
                }
            case .plain, .ruled, .grid, .dotted:
                break
            }

            let elementsURL = layout.elementsURL(page.id)
            guard fileSystemEntryExists(at: elementsURL) else { continue }
            // Refuse deletion when element references cannot be checked safely.
            // Rollback/GC may leave unreferenced bytes, but must never destroy
            // bytes that a recoverable page could still reference.
            guard let data = try? readBoundedRegularFileData(
                at: elementsURL,
                within: layout.packageURL,
                maximumBytes: StructuredContentLimits.maximumEncodedBytes
            ), (try? preflightCanvasElementArray(
                data,
                relativePath: relativePath(of: elementsURL, in: layout.packageURL)
            )) != nil,
            let elements = try? decode([CanvasElement].self, from: data) else {
                return nil
            }
            for element in elements {
                let referencedID: AssetID? = switch element.content {
                case .image(let image): image.assetID
                case .sticker(let sticker): sticker.assetID
                case .text, .shape, .connector, .stickyNote, .tape, .link: nil
                }
                if let referencedID, candidates.contains(referencedID) {
                    referencedAssetIDs.insert(referencedID)
                }
            }
            if referencedAssetIDs.count == candidates.count {
                return referencedAssetIDs
            }
        }
        return referencedAssetIDs
    }

    func planReplayAssetGarbageCollection(
        candidates: Set<AssetID>,
        manifest: inout NotebookManifest,
        layout: NotebookPackageLayout,
        writes: inout [PlannedFileWrite]
    ) throws -> Int {
        try Task<Never, Never>.checkCancellation()
        // Exclude the catalog entries under consideration while checking all
        // actual consumers. If any live page cannot be inspected safely, keep
        // every candidate rather than guessing at ownership.
        guard let externallyReferencedAssetIDs = manifestNonCatalogAssetReferences(
            among: candidates,
            manifest: manifest,
            layout: layout
        ) else {
            return 0
        }
        var candidateDescriptorsByID: [AssetID: AssetDescriptor] = [:]
        for asset in manifest.assets where candidates.contains(asset.id) {
            guard candidateDescriptorsByID[asset.id] == nil else { continue }
            candidateDescriptorsByID[asset.id] = asset
        }

        var assetIDsToDelete = Set<AssetID>()
        for assetID in candidates.sorted(by: { $0.rawValue < $1.rawValue }) {
            try Task<Never, Never>.checkCancellation()
            guard !externallyReferencedAssetIDs.contains(assetID),
                  let asset = candidateDescriptorsByID[assetID] else {
                continue
            }
            let maximumByteCount: Int
            switch asset.mediaType {
            case NoteReplayPayloadCodec.inkMediaType:
                maximumByteCount = NoteReplayHistoryLimits.maximumInkPayloadBytes
            case NoteReplayPayloadCodec.elementsMediaType:
                maximumByteCount = NoteReplayHistoryLimits.maximumElementPayloadBytes
            default:
                continue
            }

            assetIDsToDelete.insert(assetID)
            let assetURL = layout.assetURL(assetID)
            if fileSystemEntryExists(at: assetURL) {
                writes.append(.deleting(
                    assetURL,
                    maximumByteCount: maximumByteCount
                ))
            }
        }
        manifest.assets.removeAll { assetIDsToDelete.contains($0.id) }
        return assetIDsToDelete.count
    }


    func maximumBytesForProtectedTarget(
        _ url: URL,
        layout: NotebookPackageLayout
    ) -> Int? {
        if isManifestTarget(url, layout: layout) {
            return NotebookExportReadLimits.maximumManifestBytes
        }
        if isPageDescriptorTarget(url, layout: layout) {
            return PageDescriptorStorageLimits.maximumEncodedBytes
        }
        if isCanvasElementsTarget(url, layout: layout) {
            return NotebookExportReadLimits.maximumCanvasElementBytes
        }
        if isStructuredContentTarget(url, layout: layout) {
            return StructuredContentLimits.maximumEncodedBytes
        }
        if isHandwritingRecognitionTarget(url, layout: layout) {
            return HandwritingRecognitionLimits.maximumEncodedBytes
        }
        guard isAudioTarget(url, layout: layout) else { return nil }
        switch url.pathExtension.lowercased() {
        case "m4a": return AudioStorageLimits.maximumAudioBytes
        case "json": return AudioStorageLimits.maximumTimelineBytes
        default: return nil
        }
    }

    func isProtectedDurableTarget(_ url: URL, layout: NotebookPackageLayout) -> Bool {
        maximumBytesForProtectedTarget(url, layout: layout) != nil
    }

    func secureAtomicWrite(
        _ data: Data,
        to destination: URL,
        within packageURL: URL,
        maximumBytes: Int
    ) throws {
        guard data.count <= maximumBytes else {
            throw NotebookRepositoryError.corruptedFile(relativePath(of: destination, in: packageURL))
        }
        let parentURL = destination.deletingLastPathComponent()
        let parentDescriptor = try openItemWithoutFollowingLinks(
            at: parentURL,
            within: packageURL,
            finalFlags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        defer { _ = Darwin.close(parentDescriptor) }

        let temporaryName = ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        var temporaryDescriptor = temporaryName.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard temporaryDescriptor >= 0 else {
            throw NotebookRepositoryError.corruptedFile(relativePath(of: destination, in: packageURL))
        }
        var shouldRemoveTemporary = true
        defer {
            if temporaryDescriptor >= 0 { _ = Darwin.close(temporaryDescriptor) }
            if shouldRemoveTemporary {
                temporaryName.withCString { _ = Darwin.unlinkat(parentDescriptor, $0, 0) }
            }
        }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let baseAddress = bytes.baseAddress else { break }
                let written = Darwin.write(
                    temporaryDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw NotebookRepositoryError.corruptedFile(
                        relativePath(of: destination, in: packageURL)
                    )
                }
                guard written > 0 else {
                    throw NotebookRepositoryError.corruptedFile(
                        relativePath(of: destination, in: packageURL)
                    )
                }
                offset += written
            }
        }
        guard Darwin.fsync(temporaryDescriptor) == 0 else {
            throw NotebookRepositoryError.corruptedFile(relativePath(of: destination, in: packageURL))
        }
        _ = Darwin.close(temporaryDescriptor)
        temporaryDescriptor = -1

        let renameResult = temporaryName.withCString { temporaryPath in
            destination.lastPathComponent.withCString { destinationPath in
                Darwin.renameat(
                    parentDescriptor,
                    temporaryPath,
                    parentDescriptor,
                    destinationPath
                )
            }
        }
        guard renameResult == 0 else {
            throw NotebookRepositoryError.corruptedFile(relativePath(of: destination, in: packageURL))
        }
        shouldRemoveTemporary = false
        _ = Darwin.fsync(parentDescriptor)
    }

    func secureRemoveItem(at destination: URL, within packageURL: URL) throws {
        let parentURL = destination.deletingLastPathComponent()
        let parentDescriptor = try openItemWithoutFollowingLinks(
            at: parentURL,
            within: packageURL,
            finalFlags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        defer { _ = Darwin.close(parentDescriptor) }
        let result = destination.lastPathComponent.withCString {
            Darwin.unlinkat(parentDescriptor, $0, 0)
        }
        guard result == 0 || errno == ENOENT else {
            throw NotebookRepositoryError.corruptedFile(relativePath(of: destination, in: packageURL))
        }
        _ = Darwin.fsync(parentDescriptor)
    }

    func quarantinePageContent(at url: URL) throws {
        guard fileSystemEntryExists(at: url) else { return }
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
            try FileManager.default.removeItem(at: url)
            return
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else {
            try FileManager.default.removeItem(at: url)
            return
        }
        let quarantineURL = url.deletingLastPathComponent().appendingPathComponent(
            "content.corrupt-\(UUID().uuidString).json",
            isDirectory: false
        )
        try FileManager.default.moveItem(at: url, to: quarantineURL)
    }

    func quarantineHandwritingRecognition(at url: URL) throws {
        guard fileSystemEntryExists(at: url) else { return }
        if isSymbolicLinkEntry(at: url) {
            try FileManager.default.removeItem(at: url)
            return
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else {
            try FileManager.default.removeItem(at: url)
            return
        }
        let quarantineURL = url.deletingLastPathComponent().appendingPathComponent(
            "handwriting-recognition.corrupt-\(UUID().uuidString).json",
            isDirectory: false
        )
        try FileManager.default.moveItem(at: url, to: quarantineURL)
    }

    func fileSystemEntryExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || isSymbolicLinkEntry(at: url)
    }

    func isSymbolicLinkEntry(at url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    func ensureSafePageDirectory(layout: NotebookPackageLayout, pageID: PageID) throws {
        try ensureSafeDirectory(layout.pageURL(pageID), within: layout.packageURL)
    }

    func ensureSafeDirectory(_ url: URL, within packageURL: URL) throws {
        let descriptor = try openItemWithoutFollowingLinks(
            at: url,
            within: packageURL,
            finalFlags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        _ = Darwin.close(descriptor)
    }

    func openItemWithoutFollowingLinks(
        at url: URL,
        within packageURL: URL,
        finalFlags: Int32
    ) throws -> Int32 {
        guard let descriptor = try openItemWithoutFollowingLinksIfPresent(
            at: url,
            within: packageURL,
            finalFlags: finalFlags
        ) else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: url, in: packageURL)
            )
        }
        return descriptor
    }

    /// Opens a package descendant relative to verified directory descriptors. Only a missing
    /// final component returns nil; a missing/linked ancestor and every other failure remain a
    /// corruption error so callers cannot confuse an unsafe replacement with absent content.
    func openItemWithoutFollowingLinksIfPresent(
        at url: URL,
        within packageURL: URL,
        finalFlags: Int32
    ) throws -> Int32? {
        let packageComponents = packageURL.standardizedFileURL.pathComponents
        let itemComponents = url.standardizedFileURL.pathComponents
        guard itemComponents.count >= packageComponents.count,
              itemComponents.prefix(packageComponents.count).elementsEqual(packageComponents) else {
            throw NotebookRepositoryError.corruptedFile(url.lastPathComponent)
        }
        if itemComponents.count == packageComponents.count {
            guard (finalFlags & O_DIRECTORY) != 0 else {
                throw NotebookRepositoryError.corruptedFile(url.lastPathComponent)
            }
            let packageDescriptor = packageURL.path.withCString {
                Darwin.open($0, finalFlags)
            }
            guard packageDescriptor >= 0 else {
                throw NotebookRepositoryError.corruptedFile(packageURL.lastPathComponent)
            }
            return packageDescriptor
        }
        let relativeComponents = Array(itemComponents.dropFirst(packageComponents.count))
        guard relativeComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw NotebookRepositoryError.corruptedFile(url.lastPathComponent)
        }

        var directoryDescriptor = packageURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else {
            throw NotebookRepositoryError.corruptedFile(packageURL.lastPathComponent)
        }

        for component in relativeComponents.dropLast() {
            let nextDescriptor = component.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard nextDescriptor >= 0 else {
                _ = Darwin.close(directoryDescriptor)
                throw NotebookRepositoryError.corruptedFile(relativePath(of: url, in: packageURL))
            }
            _ = Darwin.close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
        }

        let itemDescriptor = relativeComponents[relativeComponents.count - 1].withCString {
            Darwin.openat(directoryDescriptor, $0, finalFlags)
        }
        let openError = errno
        _ = Darwin.close(directoryDescriptor)
        guard itemDescriptor >= 0 else {
            if openError == ENOENT { return nil }
            throw NotebookRepositoryError.corruptedFile(relativePath(of: url, in: packageURL))
        }
        return itemDescriptor
    }

    func readStructuredContentData(at url: URL, within packageURL: URL) throws -> Data {
        try readBoundedRegularFileData(
            at: url,
            within: packageURL,
            maximumBytes: StructuredContentLimits.maximumEncodedBytes
        )
    }

    func readStoredPageDescriptor(
        at url: URL,
        layout: NotebookPackageLayout
    ) throws -> PageDescriptor {
        let data = try readBoundedRegularFileData(
            at: url,
            within: layout.packageURL,
            maximumBytes: PageDescriptorStorageLimits.maximumEncodedBytes
        )
        do {
            return try decode(PageDescriptor.self, from: data)
        } catch let error as CancellationError {
            throw error
        } catch let error as NotebookRepositoryError {
            throw error
        } catch {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: url, in: layout.packageURL)
            )
        }
    }

    func readBoundedRegularFileData(
        at url: URL,
        within packageURL: URL,
        maximumBytes: Int
    ) throws -> Data {
        guard let data = try readBoundedRegularFileDataIfPresent(
            at: url,
            within: packageURL,
            maximumBytes: maximumBytes
        ) else {
            throw NotebookRepositoryError.corruptedFile(
                relativePath(of: url, in: packageURL)
            )
        }
        return data
    }

    /// Reads into an owned `Data` buffer after an `openat`/`O_NOFOLLOW` walk and descriptor
    /// metadata validation. The loop re-enforces the ceiling so concurrent file growth cannot
    /// bypass the `fstat` check. This is shared by PDF export and replay-safe ink reads.
    func readBoundedRegularFileDataIfPresent(
        at url: URL,
        within packageURL: URL,
        maximumBytes: Int
    ) throws -> Data? {
        let itemRelativePath = relativePath(of: url, in: packageURL)
        guard maximumBytes >= 0, maximumBytes < Int.max else {
            throw NotebookRepositoryError.corruptedFile(
                itemRelativePath
            )
        }
        guard let descriptor = try openItemWithoutFollowingLinksIfPresent(
            at: url,
            within: packageURL,
            finalFlags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        ) else {
            return nil
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0 else {
            throw NotebookRepositoryError.corruptedFile(itemRelativePath)
        }
        guard metadata.st_size <= off_t(maximumBytes) else {
            throw NotebookRepositoryError.boundedReadLimitExceeded(
                relativePath: itemRelativePath,
                limit: maximumBytes
            )
        }

        var data = Data()
        data.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            try Task.checkCancellation()
            var currentMetadata = stat()
            guard Darwin.fstat(descriptor, &currentMetadata) == 0,
                  (currentMetadata.st_mode & S_IFMT) == S_IFREG,
                  currentMetadata.st_size >= 0 else {
                throw NotebookRepositoryError.corruptedFile(itemRelativePath)
            }
            guard currentMetadata.st_size <= off_t(maximumBytes) else {
                throw NotebookRepositoryError.boundedReadLimitExceeded(
                    relativePath: itemRelativePath,
                    limit: maximumBytes
                )
            }
            let remaining = maximumBytes - data.count
            let requestedCount = min(buffer.count, remaining + 1)
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, requestedCount)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw NotebookRepositoryError.corruptedFile(relativePath(of: url, in: packageURL))
            }
            if bytesRead == 0 { break }
            guard bytesRead <= remaining else {
                throw NotebookRepositoryError.boundedReadLimitExceeded(
                    relativePath: itemRelativePath,
                    limit: maximumBytes
                )
            }
            data.append(contentsOf: buffer.prefix(bytesRead))
            try failureInjector?(.duringBoundedContentRead(
                relativePath: itemRelativePath,
                bytesRead: data.count
            ))
        }
        return data
    }

    func readRegularFileChunk(
        at url: URL,
        within packageURL: URL,
        offset: Int64,
        maximumByteCount: Int,
        expectedByteCount: Int64?
    ) throws -> Data {
        let descriptor = try openItemWithoutFollowingLinks(
            at: url,
            within: packageURL,
            finalFlags: O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_size >= 0,
              metadata.st_size <= off_t(AudioStorageLimits.maximumAudioBytes),
              expectedByteCount.map({ off_t($0) == metadata.st_size }) ?? true else {
            throw NotebookRepositoryError.corruptedFile(relativePath(of: url, in: packageURL))
        }
        guard offset <= Int64(metadata.st_size) else { return Data() }
        let available = Int64(metadata.st_size) - offset
        let requested = min(Int64(maximumByteCount), available)
        guard requested > 0 else { return Data() }

        var bytes = [UInt8](repeating: 0, count: Int(requested))
        var completed = 0
        while completed < bytes.count {
            try Task.checkCancellation()
            let remaining = bytes.count - completed
            let result = bytes.withUnsafeMutableBytes { buffer in
                Darwin.pread(
                    descriptor,
                    buffer.baseAddress?.advanced(by: completed),
                    remaining,
                    off_t(offset) + off_t(completed)
                )
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw NotebookRepositoryError.corruptedFile(relativePath(of: url, in: packageURL))
            }
            if result == 0 { break }
            completed += result
        }
        return Data(bytes.prefix(completed))
    }

    func scanPageDescriptors(layout: NotebookPackageLayout) -> [PageDescriptor] {
        guard !isSymbolicLinkEntry(at: layout.pagesURL) else { return [] }
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: layout.pagesURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return directories.compactMap { directory in
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true,
                  values?.isSymbolicLink != true,
                  let uuid = UUID(uuidString: directory.lastPathComponent) else { return nil }
            let descriptorURL = directory.appendingPathComponent("page.json", isDirectory: false)
            guard var page = try? readStoredPageDescriptor(
                at: descriptorURL,
                layout: layout
            ) else { return nil }
            page.id = PageID(uuid)
            return page
        }.sorted {
            if $0.createdAt == $1.createdAt { return $0.id.description < $1.id.description }
            return $0.createdAt < $1.createdAt
        }
    }

    func validate(id: NotebookID, layout: NotebookPackageLayout) -> ValidationReport {
        let fileManager = FileManager.default
        var issues: [ValidationIssue] = []
        for temporary in findTemporaryFiles(in: layout.packageURL) {
            issues.append(.init(
                kind: .abandonedTemporaryFile,
                relativePath: relativePath(of: temporary, in: layout.packageURL),
                detail: "An interrupted atomic write left a temporary file."
            ))
        }
        if let directories = try? transactionDirectories(layout: layout) {
            for directory in directories {
                do {
                    let loaded = try readTransactionRecord(in: directory)
                    issues.append(.init(
                        kind: .pendingTransaction,
                        relativePath: normalizedRelativePath(of: directory, in: layout.packageURL),
                        detail: "Transaction \(loaded.record.command.id) is pending in phase \(loaded.record.phase.rawValue)."
                    ))
                } catch {
                    issues.append(.init(
                        kind: .unreadableTransaction,
                        relativePath: normalizedRelativePath(of: directory, in: layout.packageURL),
                        detail: "The transaction journal and its backup cannot be decoded."
                    ))
                }
            }
        }

        guard fileManager.fileExists(atPath: layout.manifestURL.path) else {
            issues.append(.init(kind: .missingManifest, relativePath: "manifest.json", detail: "The package has no manifest."))
            return ValidationReport(notebookID: id, issues: issues)
        }
        guard let manifest = try? decode(NotebookManifest.self, from: Data(contentsOf: layout.manifestURL)) else {
            issues.append(.init(kind: .unreadableManifest, relativePath: "manifest.json", detail: "The manifest is not valid JSON for a supported schema."))
            return ValidationReport(notebookID: id, issues: issues)
        }
        if manifest.id != id {
            issues.append(.init(kind: .identifierMismatch, relativePath: "manifest.json", detail: "The manifest identifier differs from the package identifier."))
        }

        var manifestPageIDs = Set<PageID>()
        for page in manifest.pages {
            guard manifestPageIDs.insert(page.id).inserted else {
                issues.append(.init(kind: .duplicatePage, relativePath: "manifest.json", detail: "Page \(page.id) occurs more than once."))
                continue
            }
            let directory = layout.pageURL(page.id)
            var isDirectory: ObjCBool = false
            guard !isSymbolicLinkEntry(at: layout.pagesURL),
                  !isSymbolicLinkEntry(at: directory),
                  fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                issues.append(.init(kind: .missingPageDirectory, relativePath: "pages/\(page.id)", detail: "The page directory is missing."))
                continue
            }
            let descriptorURL = layout.pageDescriptorURL(page.id)
            guard fileManager.fileExists(atPath: descriptorURL.path) else {
                issues.append(.init(kind: .missingPageDescriptor, relativePath: relativePath(of: descriptorURL, in: layout.packageURL), detail: "The page descriptor is missing."))
                continue
            }
            guard let diskPage = try? readStoredPageDescriptor(
                at: descriptorURL,
                layout: layout
            ) else {
                issues.append(.init(kind: .unreadablePageDescriptor, relativePath: relativePath(of: descriptorURL, in: layout.packageURL), detail: "The page descriptor cannot be decoded."))
                continue
            }
            if diskPage.id != page.id {
                issues.append(.init(kind: .pageIdentifierMismatch, relativePath: relativePath(of: descriptorURL, in: layout.packageURL), detail: "The page descriptor identifier is inconsistent."))
            } else if diskPage != page {
                issues.append(.init(
                    kind: .pageDescriptorMismatch,
                    relativePath: relativePath(of: descriptorURL, in: layout.packageURL),
                    detail: "The page descriptor does not match the manifest metadata."
                ))
            }
            let elementsURL = layout.elementsURL(page.id)
            if fileManager.fileExists(atPath: elementsURL.path),
               (try? decode([CanvasElement].self, from: Data(contentsOf: elementsURL))) == nil {
                issues.append(.init(kind: .unreadableElements, relativePath: relativePath(of: elementsURL, in: layout.packageURL), detail: "The element collection cannot be decoded."))
            }

            if let recognitionIssue = handwritingRecognitionValidationIssue(
                pageID: page.id,
                layout: layout
            ) {
                issues.append(recognitionIssue)
            }

            let contentURL = layout.contentURL(page.id)
            let contentPath = relativePath(of: contentURL, in: layout.packageURL)
            guard PageContent.empty(for: page.kind) != nil else {
                if fileSystemEntryExists(at: contentURL) {
                    issues.append(.init(
                        kind: .pageContentTypeMismatch,
                        relativePath: contentPath,
                        detail: "This page kind must not contain structured page content."
                    ))
                }
                continue
            }
            guard fileSystemEntryExists(at: contentURL) else {
                if page.schemaVersion < PageDescriptor.structuredContentSchemaVersion {
                    continue
                }
                issues.append(.init(
                    kind: .missingPageContent,
                    relativePath: contentPath,
                    detail: "The structured page content is missing."
                ))
                continue
            }
            guard let content = try? decode(
                PageContent.self,
                from: readStructuredContentData(at: contentURL, within: layout.packageURL)
            ) else {
                issues.append(.init(
                    kind: .unreadablePageContent,
                    relativePath: contentPath,
                    detail: "The structured page content cannot be decoded."
                ))
                continue
            }
            guard content.pageKind == page.kind else {
                issues.append(.init(
                    kind: .pageContentTypeMismatch,
                    relativePath: contentPath,
                    detail: "The structured content type does not match the page kind."
                ))
                continue
            }
            if let detail = structuredContentValidationDetail(content) {
                issues.append(.init(
                    kind: .invalidPageContent,
                    relativePath: contentPath,
                    detail: detail
                ))
            }
        }

        if let pageDirectories = try? fileManager.contentsOfDirectory(
            at: layout.pagesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for directory in pageDirectories {
                guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      let uuid = UUID(uuidString: directory.lastPathComponent) else { continue }
                let pageID = PageID(uuid)
                if !manifestPageIDs.contains(pageID) {
                    issues.append(.init(kind: .orphanPageDirectory, relativePath: relativePath(of: directory, in: layout.packageURL), detail: "The page directory is not referenced by the manifest."))
                }
            }
        }

        if let operationURLs = try? fileManager.contentsOfDirectory(
            at: layout.operationsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for operationURL in operationURLs where operationURL.pathExtension == "json" {
                if (try? decode(EditCommand.self, from: Data(contentsOf: operationURL))) == nil {
                    issues.append(.init(
                        kind: .unreadableOperation,
                        relativePath: relativePath(of: operationURL, in: layout.packageURL),
                        detail: "An operation log entry cannot be decoded."
                    ))
                }
            }
        }

        var seenAssets = Set<AssetID>()
        for asset in manifest.assets where seenAssets.insert(asset.id).inserted {
            let url = layout.assetURL(asset.id)
            let boundedAssetMaximum: Int? = switch asset.mediaType {
            case AudioTranscriptDocument.mediaType:
                AudioTranscriptDocument.maximumEncodedBytes
            case NoteReplayPayloadCodec.inkMediaType:
                NoteReplayHistoryLimits.maximumInkPayloadBytes
            case NoteReplayPayloadCodec.elementsMediaType:
                NoteReplayHistoryLimits.maximumElementPayloadBytes
            default:
                nil
            }
            if let boundedAssetMaximum,
               asset.byteCount > Int64(boundedAssetMaximum) {
                issues.append(.init(
                    kind: .invalidAssetSize,
                    relativePath: relativePath(of: url, in: layout.packageURL),
                    detail: "The content-addressed asset exceeds its media-type storage limit."
                ))
                continue
            }
            let data: Data? = if let boundedAssetMaximum {
                try? readBoundedRegularFileData(
                    at: url,
                    within: layout.packageURL,
                    maximumBytes: boundedAssetMaximum
                )
            } else {
                try? Data(contentsOf: url, options: .mappedIfSafe)
            }
            guard let data else {
                issues.append(.init(kind: .missingAsset, relativePath: relativePath(of: url, in: layout.packageURL), detail: "The content-addressed asset is missing."))
                continue
            }
            if Int64(data.count) != asset.byteCount {
                issues.append(.init(kind: .invalidAssetSize, relativePath: relativePath(of: url, in: layout.packageURL), detail: "The asset byte count differs from its descriptor."))
            }
            if SHA256.hexDigest(data) != asset.id.rawValue {
                issues.append(.init(kind: .invalidAssetDigest, relativePath: relativePath(of: url, in: layout.packageURL), detail: "The asset SHA-256 digest differs from its identifier."))
            }
        }

        let audioDirectoryIsSafe = (try? ensureSafeDirectory(
            layout.audioURL,
            within: layout.packageURL
        )) != nil
        if !audioDirectoryIsSafe {
            issues.append(.init(
                kind: .unreadableAudioFile,
                relativePath: "audio",
                detail: "The audio storage directory is missing, linked, or not a directory."
            ))
        }
        var seenAudioSessionIDs = Set<AudioSessionID>()
        var referencedAudioFilenameKeys = Set<String>()
        for session in manifest.audioSessions {
            guard seenAudioSessionIDs.insert(session.id).inserted else {
                issues.append(.init(
                    kind: .duplicateAudioSession,
                    relativePath: "manifest.json",
                    detail: "Audio session \(session.id) occurs more than once."
                ))
                continue
            }
            if let detail = audioDescriptorValidationDetail(session, manifest: manifest) {
                issues.append(.init(
                    kind: .invalidAudioDescriptor,
                    relativePath: "manifest.json",
                    detail: "Audio session \(session.id): \(detail)"
                ))
            }

            for filename in session.chunkFilenames
            where isSafeAudioFilename(filename, expectedExtension: "m4a") {
                if !referencedAudioFilenameKeys.insert(audioFilenameKey(filename)).inserted {
                    issues.append(.init(
                        kind: .invalidAudioDescriptor,
                        relativePath: "manifest.json",
                        detail: "More than one audio session references \(filename)."
                    ))
                }
                let url = layout.audioURL.appendingPathComponent(filename, isDirectory: false)
                let path = relativePath(of: url, in: layout.packageURL)
                guard audioDirectoryIsSafe else { continue }
                guard fileSystemEntryExists(at: url) else {
                    issues.append(.init(kind: .missingAudioFile, relativePath: path, detail: "The M4A file is missing."))
                    continue
                }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values?.isRegularFile == true,
                      values?.isSymbolicLink != true else {
                    issues.append(.init(kind: .unreadableAudioFile, relativePath: path, detail: "The audio entry is not a regular file."))
                    continue
                }
                guard let fileSize = values?.fileSize,
                      fileSize <= AudioStorageLimits.maximumAudioBytes else {
                    issues.append(.init(kind: .invalidAudioSize, relativePath: path, detail: "The audio file exceeds the storage limit."))
                    continue
                }
                guard let data = try? readBoundedRegularFileData(
                    at: url,
                    within: layout.packageURL,
                    maximumBytes: AudioStorageLimits.maximumAudioBytes
                ) else {
                    issues.append(.init(kind: .unreadableAudioFile, relativePath: path, detail: "The audio file cannot be read safely."))
                    continue
                }
                if session.schemaVersion >= 2,
                   Int64(data.count) != session.audioByteCount {
                    issues.append(.init(kind: .invalidAudioSize, relativePath: path, detail: "The audio byte count differs from its descriptor."))
                }
                if session.schemaVersion >= 2,
                   SHA256.hexDigest(data) != session.audioSHA256 {
                    issues.append(.init(kind: .invalidAudioDigest, relativePath: path, detail: "The audio SHA-256 differs from its descriptor."))
                }
                if (try? validateAudioData(data, sessionID: session.id)) == nil {
                    issues.append(.init(kind: .unreadableAudioFile, relativePath: path, detail: "The file is not a bounded M4A recording."))
                }
            }

            guard let timelineFilename = session.timelineFilename,
                  isSafeAudioFilename(timelineFilename, expectedExtension: "json") else {
                if session.schemaVersion >= 2 {
                    issues.append(.init(
                        kind: .missingAudioTimeline,
                        relativePath: "manifest.json",
                        detail: "Audio session \(session.id) does not reference a safe timeline."
                    ))
                }
                continue
            }
            if !referencedAudioFilenameKeys.insert(audioFilenameKey(timelineFilename)).inserted {
                issues.append(.init(
                    kind: .invalidAudioDescriptor,
                    relativePath: "manifest.json",
                    detail: "More than one audio session references \(timelineFilename)."
                ))
            }
            let timelineURL = layout.audioURL.appendingPathComponent(timelineFilename, isDirectory: false)
            let timelinePath = relativePath(of: timelineURL, in: layout.packageURL)
            guard audioDirectoryIsSafe else { continue }
            guard fileSystemEntryExists(at: timelineURL) else {
                issues.append(.init(kind: .missingAudioTimeline, relativePath: timelinePath, detail: "The audio timeline is missing."))
                continue
            }
            guard let timelineData = try? readBoundedRegularFileData(
                at: timelineURL,
                within: layout.packageURL,
                maximumBytes: AudioStorageLimits.maximumTimelineBytes
            ), let timeline = try? decode(AudioTimelineDocument.self, from: timelineData) else {
                issues.append(.init(kind: .unreadableAudioTimeline, relativePath: timelinePath, detail: "The audio timeline cannot be decoded safely."))
                continue
            }
            guard timeline.audioSessionID == session.id else {
                issues.append(.init(kind: .audioTimelineMismatch, relativePath: timelinePath, detail: "The timeline belongs to another session."))
                continue
            }
            if (try? validateAudioTimeline(
                timeline,
                durationSeconds: session.durationSeconds,
                manifest: manifest
            )) == nil {
                issues.append(.init(kind: .audioTimelineMismatch, relativePath: timelinePath, detail: "The timeline contains invalid or dangling marks."))
            }
            if (try? validateRecordingStart(
                session.recordingStartedAt,
                timeline: timeline,
                sessionID: session.id
            )) == nil {
                issues.append(.init(
                    kind: .audioTimelineMismatch,
                    relativePath: timelinePath,
                    detail: "The timeline does not corroborate its recording start timestamp."
                ))
            }
            if let transcriptAssetID = session.transcriptAssetID,
               let transcriptAsset = manifest.assets.first(where: { $0.id == transcriptAssetID }),
               transcriptAsset.mediaType == AudioTranscriptDocument.mediaType,
               !storedAudioTranscriptIsValid(
                   descriptor: session,
                   asset: transcriptAsset,
                   manifest: manifest,
                   layout: layout,
                   knownTimeline: timeline
               ) {
                issues.append(.init(
                    kind: .invalidAudioTranscript,
                    relativePath: relativePath(of: layout.assetURL(transcriptAssetID), in: layout.packageURL),
                    detail: "The attached transcript is unreadable or does not match its audio session and timeline."
                ))
            }
            if session.schemaVersion >= 3,
               let replayFilename = session.replayFilename,
               isSafeAudioFilename(replayFilename, expectedExtension: "json") {
                if !referencedAudioFilenameKeys.insert(audioFilenameKey(replayFilename)).inserted {
                    issues.append(.init(
                        kind: .invalidAudioDescriptor,
                        relativePath: "manifest.json",
                        detail: "More than one audio session references \(replayFilename)."
                    ))
                }
                let replayURL = layout.audioURL.appendingPathComponent(
                    replayFilename,
                    isDirectory: false
                )
                let replayPath = relativePath(of: replayURL, in: layout.packageURL)
                if !fileSystemEntryExists(at: replayURL) {
                    issues.append(.init(
                        kind: .missingAudioReplayHistory,
                        relativePath: replayPath,
                        detail: "The sealed Note Replay history is missing."
                    ))
                } else if !storedNoteReplayHistoryIsValid(
                    descriptor: session,
                    timeline: timeline,
                    manifest: manifest,
                    layout: layout
                ) {
                    issues.append(.init(
                        kind: .invalidAudioReplayHistory,
                        relativePath: replayPath,
                        detail: "The sealed Note Replay index or one of its payloads is invalid."
                    ))
                }
            }
        }

        if audioDirectoryIsSafe, let audioEntries = try? fileManager.contentsOfDirectory(
            at: layout.audioURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) {
            let visibleEntries = audioEntries.filter {
                !$0.lastPathComponent.hasPrefix(".recovered-")
            }
            for (key, entries) in Dictionary(grouping: visibleEntries, by: {
                audioFilenameKey($0.lastPathComponent)
            }) {
                for entry in entries {
                    let detail: String?
                    if !referencedAudioFilenameKeys.contains(key) {
                        detail = "The audio entry is not referenced by the manifest."
                    } else if entries.count > 1 {
                        detail = "Multiple audio entries collide on a case-insensitive filesystem."
                    } else {
                        detail = nil
                    }
                    guard let detail else { continue }
                    issues.append(.init(
                        kind: .orphanAudioFile,
                        relativePath: relativePath(of: entry, in: layout.packageURL),
                        detail: detail
                    ))
                }
            }
        }
        return ValidationReport(notebookID: id, issues: issues)
    }
}

// MARK: - Dependency-free SHA-256

enum SHA256 {
    private static let initialHash: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ]

    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    static func hexDigest(_ data: Data) -> String {
        var stream = Stream()
        data.withUnsafeBytes { stream.update($0) }
        return stream.finalizeHexDigest()
    }

    struct Stream {
        private var hash = SHA256.initialHash
        private var pending = [UInt8]()
        private var totalByteCount: UInt64 = 0

        init() {}

        mutating func update(_ bytes: UnsafeRawBufferPointer) {
            guard !bytes.isEmpty else { return }
            totalByteCount += UInt64(bytes.count)
            var offset = 0
            var words = [UInt32](repeating: 0, count: 64)
            if !pending.isEmpty {
                let copied = min(64 - pending.count, bytes.count)
                pending.append(contentsOf: bytes[..<copied])
                offset += copied
                if pending.count == 64 {
                    let completedBlock = pending
                    completedBlock.withUnsafeBytes { pendingBytes in
                        SHA256.compress(pendingBytes, at: 0, hash: &hash, words: &words)
                    }
                    pending.removeAll(keepingCapacity: true)
                }
            }
            while offset + 64 <= bytes.count {
                SHA256.compress(bytes, at: offset, hash: &hash, words: &words)
                offset += 64
            }
            if offset < bytes.count {
                pending.append(contentsOf: bytes[offset...])
            }
        }

        mutating func finalizeHexDigest() -> String {
            var tail = pending
            let bitLength = totalByteCount * 8
            tail.append(0x80)
            while tail.count % 64 != 56 { tail.append(0) }
            tail.append(contentsOf: withUnsafeBytes(of: bitLength.bigEndian, Array.init))
            var words = [UInt32](repeating: 0, count: 64)
            tail.withUnsafeBytes { bytes in
                for chunkStart in stride(from: 0, to: bytes.count, by: 64) {
                    SHA256.compress(bytes, at: chunkStart, hash: &hash, words: &words)
                }
            }
            return hash.flatMap { value -> [UInt8] in
                let bigEndian = value.bigEndian
                return withUnsafeBytes(of: bigEndian, Array.init)
            }.map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func compress(
        _ bytes: UnsafeRawBufferPointer,
        at chunkStart: Int,
        hash: inout [UInt32],
        words: inout [UInt32]
    ) {
        for index in 0..<16 {
            let start = chunkStart + index * 4
            words[index] = UInt32(bytes[start]) << 24
                | UInt32(bytes[start + 1]) << 16
                | UInt32(bytes[start + 2]) << 8
                | UInt32(bytes[start + 3])
        }
        for index in 16..<64 {
            let s0 = rotateRight(words[index - 15], by: 7)
                ^ rotateRight(words[index - 15], by: 18)
                ^ (words[index - 15] >> 3)
            let s1 = rotateRight(words[index - 2], by: 17)
                ^ rotateRight(words[index - 2], by: 19)
                ^ (words[index - 2] >> 10)
            words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
        }

        var a = hash[0]
        var b = hash[1]
        var c = hash[2]
        var d = hash[3]
        var e = hash[4]
        var f = hash[5]
        var g = hash[6]
        var h = hash[7]
        for index in 0..<64 {
            let sum1 = rotateRight(e, by: 6) ^ rotateRight(e, by: 11) ^ rotateRight(e, by: 25)
            let choice = (e & f) ^ ((~e) & g)
            let temporary1 = h &+ sum1 &+ choice &+ roundConstants[index] &+ words[index]
            let sum0 = rotateRight(a, by: 2) ^ rotateRight(a, by: 13) ^ rotateRight(a, by: 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let temporary2 = sum0 &+ majority
            h = g
            g = f
            f = e
            e = d &+ temporary1
            d = c
            c = b
            b = a
            a = temporary1 &+ temporary2
        }
        hash[0] &+= a
        hash[1] &+= b
        hash[2] &+= c
        hash[3] &+= d
        hash[4] &+= e
        hash[5] &+= f
        hash[6] &+= g
        hash[7] &+= h
    }

    private static func rotateRight(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }
}
