import Foundation

public enum SearchIndexError: LocalizedError, Equatable, Sendable {
    case invalidRevision(Int)
    case revisionConflict(UUID)
    case documentTooLarge(UUID)
    case snapshotTooLarge
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidRevision(let revision): "Search revisions cannot be negative: \(revision)."
        case .revisionConflict(let id): "Document \(id) reused a revision with different content."
        case .documentTooLarge(let id): "Document \(id) is too large for the local search index."
        case .snapshotTooLarge: "The local search index exceeds its configured size limit."
        case .unsupportedSchema(let version): "Search index schema \(version) is not supported."
        }
    }
}

public enum SearchIndexLoadState: String, Codable, Hashable, Sendable {
    case empty
    case loaded
    case recoveredFromBackup
    case resetAfterCorruption
}

public struct SearchIndexLimits: Hashable, Sendable {
    public var maximumDocumentCount: Int
    public var maximumSegmentsPerDocument: Int
    public var maximumCharactersPerDocument: Int
    public var maximumTotalCharacters: Int
    public var maximumSnapshotBytes: Int
    public var maximumQueryCharacters: Int
    public var maximumResults: Int

    public init(
        maximumDocumentCount: Int = 200_000,
        maximumSegmentsPerDocument: Int = 10_000,
        maximumCharactersPerDocument: Int = 10_000_000,
        maximumTotalCharacters: Int = 100_000_000,
        maximumSnapshotBytes: Int = 256 * 1_024 * 1_024,
        maximumQueryCharacters: Int = 1_024,
        maximumResults: Int = 500
    ) {
        self.maximumDocumentCount = maximumDocumentCount
        self.maximumSegmentsPerDocument = maximumSegmentsPerDocument
        self.maximumCharactersPerDocument = maximumCharactersPerDocument
        self.maximumTotalCharacters = maximumTotalCharacters
        self.maximumSnapshotBytes = maximumSnapshotBytes
        self.maximumQueryCharacters = maximumQueryCharacters
        self.maximumResults = maximumResults
    }
}

public protocol SearchIndexing: Sendable {
    func revision(for documentID: UUID) async -> Int?
    func document(for documentID: UUID) async -> SearchIndexDocument?
    /// Atomically retitles the current matching document from its notebook's
    /// title-authority document (`id == notebookID`). Missing or provenance-
    /// mismatched documents remain untouched, so a concurrent remove cannot be
    /// undone; malformed or missing authority fails closed.
    func retitleDocument(
        documentID: UUID,
        notebookID: UUID,
        pageID: UUID?
    ) async throws
    /// Publishes a page payload using the current notebook-title authority
    /// document (`id == notebookID`) inside the same actor turn. Page-derived
    /// work can therefore finish on either side of a rename without restoring
    /// its captured old title. Missing or malformed authority fails closed.
    func upsertUsingCurrentNotebookTitle(
        _ document: SearchIndexDocument
    ) async throws
    /// Publishes the canonical title-authority document with an in-process
    /// serial generation. A logically older publication is ignored even when
    /// it arrives later with a numerically higher document revision.
    func upsertNotebookTitleAuthority(
        _ document: SearchIndexDocument,
        publicationGeneration: UInt64
    ) async throws
    func upsert(_ document: SearchIndexDocument) async throws
    func remove(documentID: UUID) async throws
    /// Atomically removes the specified page-owned documents for a durable page
    /// delete and installs an in-process tombstone. Exact IDs avoid deleting a
    /// multi-page source such as an audio transcript; late page publications
    /// are ignored until the notebook/root authority is reset.
    func removePageDocuments(
        notebookID: UUID,
        pageID: UUID,
        documentIDs: Set<UUID>
    ) async throws
    func removeNotebook(_ notebookID: UUID) async throws
    /// Prunes documents containing `source` unless explicitly retained. Mixed
    /// source documents are treated as owned by every source they contain so a
    /// malformed orphan cannot evade reconciliation.
    func retainDocuments(
        notebookID: UUID,
        source: RecognizedTextSource,
        documentIDs: Set<UUID>
    ) async throws
    func retainNotebooks(_ notebookIDs: Set<UUID>) async throws
    /// Returns one best hit per document. Exact aliases recognized by
    /// `PageNavigationSearchQueryPolicy` are reserved bookmark queries and
    /// therefore ignore document titles and non-bookmark segments. A document
    /// containing any outline or bookmark segment is navigation-owned; mixed
    /// non-navigation segments in that document must never produce hits.
    func query(_ text: String, notebookID: UUID?, limit: Int) async -> [LocalSearchHit]
    /// Returns independently navigable matching segments. Implementations must
    /// keep the result count bounded by `limit`, preserve page context, and
    /// apply the same reserved bookmark-query semantics and navigation-owned
    /// mixed-source quarantine as `query`.
    func querySegments(
        _ text: String,
        notebookID: UUID?,
        limit: Int
    ) async -> [LocalSearchSegmentHit]
    func rebuild(from documents: [SearchIndexDocument]) async throws
}

public actor LocalSearchIndex: SearchIndexing {
    private static let maximumSegmentQueryResults = 500

    private struct PageSearchKey: Hashable, Sendable {
        let notebookID: UUID
        let pageID: UUID
    }

    private struct Snapshot: Codable, Sendable {
        var schemaVersion: Int
        var generation: UInt64
        var documents: [SearchIndexDocument]

        init(generation: UInt64, documents: [SearchIndexDocument]) {
            schemaVersion = 2
            self.generation = generation
            self.documents = documents
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case generation
            case documents
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            generation = try container.decodeIfPresent(UInt64.self, forKey: .generation) ?? 0
            documents = try container.decode([SearchIndexDocument].self, forKey: .documents)
        }
    }

    private struct LoadResult: Sendable {
        var documents: [UUID: SearchIndexDocument]
        var generation: UInt64
        var state: SearchIndexLoadState
    }

    private let persistenceURL: URL?
    private let backupURL: URL?
    private let fileManager: FileManager
    private let limits: SearchIndexLimits
    private var documents: [UUID: SearchIndexDocument]
    private var notebookTitlePublicationGenerations: [UUID: UInt64]
    private var deletedPageSearchTombstones: [PageSearchKey: Set<UUID>]
    private var generation: UInt64
    private var state: SearchIndexLoadState

    public init(
        persistenceURL: URL? = nil,
        fileManager: FileManager = .default,
        limits: SearchIndexLimits = SearchIndexLimits()
    ) {
        let standardizedURL = persistenceURL?.standardizedFileURL
        self.persistenceURL = standardizedURL
        self.backupURL = standardizedURL?.appendingPathExtension("backup")
        self.fileManager = fileManager
        self.limits = limits

        let result = Self.load(
            primaryURL: standardizedURL,
            backupURL: standardizedURL?.appendingPathExtension("backup"),
            fileManager: fileManager,
            limits: limits
        )
        documents = result.documents
        notebookTitlePublicationGenerations = [:]
        deletedPageSearchTombstones = [:]
        generation = result.generation
        state = result.state
    }

    public func loadState() -> SearchIndexLoadState { state }
    public func indexedDocumentCount() -> Int { documents.count }
    public func revision(for documentID: UUID) async -> Int? {
        guard let document = documents[documentID],
              !isPageDocumentTombstoned(document) else { return nil }
        return document.revision
    }

    public func document(for documentID: UUID) async -> SearchIndexDocument? {
        guard let document = documents[documentID],
              !isPageDocumentTombstoned(document) else { return nil }
        return document
    }

    public func retitleDocument(
        documentID: UUID,
        notebookID: UUID,
        pageID: UUID?
    ) async throws {
        guard var document = documents[documentID],
              !isPageDocumentTombstoned(document),
              document.notebookID == notebookID,
              document.pageID == pageID else { return }
        guard let titleAuthority = documents[notebookID],
              Self.isNotebookTitleAuthority(titleAuthority) else {
            throw SearchIndexError.revisionConflict(documentID)
        }
        guard document.title != titleAuthority.title else { return }
        guard document.revision < Int.max else {
            throw SearchIndexError.revisionConflict(documentID)
        }
        document.title = titleAuthority.title
        document.revision += 1
        try Self.validate(document, limits: limits)
        var next = documents
        next[documentID] = document
        try commit(next)
    }

    public func upsertUsingCurrentNotebookTitle(
        _ document: SearchIndexDocument
    ) async throws {
        var candidate = document
        guard let pageID = candidate.pageID else {
            throw SearchIndexError.revisionConflict(candidate.id)
        }
        let pageKey = PageSearchKey(
            notebookID: candidate.notebookID,
            pageID: pageID
        )
        guard deletedPageSearchTombstones[pageKey] == nil else { return }
        guard let titleAuthority = documents[candidate.notebookID],
              Self.isNotebookTitleAuthority(titleAuthority) else {
            throw SearchIndexError.revisionConflict(candidate.id)
        }
        candidate.title = titleAuthority.title
        if let old = documents[candidate.id] {
            guard old.notebookID == candidate.notebookID,
                  old.pageID == candidate.pageID else {
                throw SearchIndexError.revisionConflict(candidate.id)
            }
        }
        try Self.validate(candidate, limits: limits)
        if let old = documents[candidate.id] {
            if old.revision > candidate.revision { return }
            if old.revision == candidate.revision {
                guard Self.hasSameRevisionPayload(old, candidate) else {
                    throw SearchIndexError.revisionConflict(candidate.id)
                }
                return
            }
        }
        var next = documents
        next[candidate.id] = candidate
        try commit(next)
    }

    public func upsertNotebookTitleAuthority(
        _ document: SearchIndexDocument,
        publicationGeneration: UInt64
    ) async throws {
        guard Self.isNotebookTitleAuthority(document) else {
            throw SearchIndexError.revisionConflict(document.id)
        }
        try Self.validate(document, limits: limits)
        if let currentGeneration = notebookTitlePublicationGenerations[
            document.notebookID
        ] {
            if currentGeneration == publicationGeneration {
                guard let existing = documents[document.id],
                      Self.hasSameTitleAuthorityPayload(
                        existing,
                        document
                      ) else {
                    throw SearchIndexError.revisionConflict(document.id)
                }
                return
            }
            guard Self.isNewerPublicationGeneration(
                publicationGeneration,
                than: currentGeneration
            ) else { return }
        }

        var candidate = document
        if let existing = documents[candidate.id] {
            guard Self.isNotebookTitleAuthority(existing),
                  existing.notebookID == candidate.notebookID,
                  existing.revision < Int.max else {
                throw SearchIndexError.revisionConflict(candidate.id)
            }
            candidate.revision = max(
                candidate.revision,
                existing.revision + 1
            )
        }
        try Self.validate(candidate, limits: limits)
        var next = documents
        next[candidate.id] = candidate
        try commit(next)
        notebookTitlePublicationGenerations[candidate.notebookID] =
            publicationGeneration
    }

    public func upsert(_ document: SearchIndexDocument) async throws {
        try Self.validate(document, limits: limits)
        if let pageID = document.pageID,
           deletedPageSearchTombstones[PageSearchKey(
               notebookID: document.notebookID,
               pageID: pageID
           )]?.contains(document.id) == true {
            return
        }
        if let old = documents[document.id] {
            if old.revision > document.revision { return }
            if old.revision == document.revision {
                guard Self.hasSameRevisionPayload(old, document) else {
                    throw SearchIndexError.revisionConflict(document.id)
                }
                return
            }
        }
        var next = documents
        next[document.id] = document
        try commit(next)
        if Self.isNotebookTitleAuthority(document) {
            notebookTitlePublicationGenerations.removeValue(
                forKey: document.notebookID
            )
        }
    }

    public func remove(documentID: UUID) async throws {
        guard let removed = documents[documentID] else { return }
        var next = documents
        next.removeValue(forKey: documentID)
        try commit(next)
        if Self.isNotebookTitleAuthority(removed) {
            notebookTitlePublicationGenerations.removeValue(
                forKey: removed.notebookID
            )
        }
    }

    public func removePageDocuments(
        notebookID: UUID,
        pageID: UUID,
        documentIDs: Set<UUID>
    ) async throws {
        let pageKey = PageSearchKey(
            notebookID: notebookID,
            pageID: pageID
        )
        // The notebook is already authoritative when this cleanup runs. Keep
        // the process-local delete barrier even if persistence fails so a late
        // OCR/canvas publication cannot recreate the removed page.
        deletedPageSearchTombstones[pageKey, default: []]
            .formUnion(documentIDs)
        let next = documents.filter { id, document in
            guard documentIDs.contains(id) else { return true }
            return document.notebookID != notebookID
                || document.pageID != pageID
        }
        if next.count != documents.count {
            try commit(next)
        }
    }

    public func removeNotebook(_ notebookID: UUID) async throws {
        let next = documents.filter { $0.value.notebookID != notebookID }
        if next.count != documents.count {
            try commit(next)
        }
        notebookTitlePublicationGenerations.removeValue(forKey: notebookID)
        deletedPageSearchTombstones = deletedPageSearchTombstones.filter {
            $0.key.notebookID != notebookID
        }
    }

    public func retainDocuments(
        notebookID: UUID,
        source: RecognizedTextSource,
        documentIDs: Set<UUID>
    ) async throws {
        let next = documents.filter { id, document in
            guard document.notebookID == notebookID,
                  !document.segments.isEmpty,
                  document.segments.contains(where: { $0.source == source }) else {
                return true
            }
            return documentIDs.contains(id)
        }
        guard next.count != documents.count else { return }
        try commit(next)
    }

    public func retainNotebooks(_ notebookIDs: Set<UUID>) async throws {
        let next = documents.filter { notebookIDs.contains($0.value.notebookID) }
        if notebookIDs.isEmpty {
            // An authority reset must rewrite both durable snapshots even when
            // memory is already empty; a legacy/stale backup may otherwise be
            // resurrected after a later primary-file failure.
            try commit([:])
            notebookTitlePublicationGenerations.removeAll()
            deletedPageSearchTombstones.removeAll()
            return
        }
        if next.count != documents.count {
            try commit(next)
        }
        notebookTitlePublicationGenerations =
            notebookTitlePublicationGenerations.filter {
                notebookIDs.contains($0.key)
            }
        deletedPageSearchTombstones = deletedPageSearchTombstones.filter {
            notebookIDs.contains($0.key.notebookID)
        }
    }

    public func rebuild(from input: [SearchIndexDocument]) async throws {
        guard input.count <= limits.maximumDocumentCount else { throw SearchIndexError.snapshotTooLarge }
        var next: [UUID: SearchIndexDocument] = [:]
        for document in input {
            try Self.validate(document, limits: limits)
            guard let existing = next[document.id] else {
                next[document.id] = document
                continue
            }
            if document.revision == existing.revision {
                guard Self.hasSameRevisionPayload(existing, document) else {
                    throw SearchIndexError.revisionConflict(document.id)
                }
            } else if document.revision > existing.revision {
                next[document.id] = document
            }
        }
        try commit(next)
        notebookTitlePublicationGenerations.removeAll()
        deletedPageSearchTombstones.removeAll()
    }

    public func query(_ text: String, notebookID: UUID? = nil, limit: Int = 50) async -> [LocalSearchHit] {
        guard limit > 0, limits.maximumResults > 0, limits.maximumQueryCharacters > 0 else { return [] }
        let boundedText = String(text.prefix(limits.maximumQueryCharacters))
        let query = Self.normalized(boundedText)
        guard !query.isEmpty, !Task.isCancelled else { return [] }
        let tokens = Self.tokens(in: query)
        let isExactBookmarkQuery = PageNavigationSearchQueryPolicy
            .isExactBookmarkQuery(query)
        let pageTombstones = deletedPageSearchTombstones

        return documents.values
            .lazy
            .filter { document in
                guard notebookID == nil
                    || document.notebookID == notebookID else { return false }
                guard let pageID = document.pageID else { return true }
                let key = PageSearchKey(
                    notebookID: document.notebookID,
                    pageID: pageID
                )
                return pageTombstones[key]?.contains(document.id) != true
            }
            .compactMap { document -> LocalSearchHit? in
                let title = Self.normalized(document.title)
                let isNavigationDocument = document.segments.contains {
                    $0.source == .outline || $0.source == .bookmark
                }
                var bestScore = 0.0
                var bestSegment: RecognizedTextSegment?

                for segment in document.segments {
                    if isNavigationDocument,
                       segment.source != .outline,
                       segment.source != .bookmark {
                        continue
                    }
                    if segment.source == .bookmark {
                        guard isExactBookmarkQuery else { continue }
                        let score = 7.5
                        if score > bestScore {
                            bestScore = score
                            bestSegment = segment
                        }
                        continue
                    }
                    guard !isExactBookmarkQuery else { continue }
                    let candidate = Self.normalized(segment.text)
                    var score = candidate.contains(query) ? 6.0 : 0.0
                    if !tokens.isEmpty {
                        let candidateTokens = Set(Self.tokens(in: candidate))
                        score += Double(tokens.filter(candidateTokens.contains).count) * 1.5
                    }
                    let confidence = segment.confidence.isFinite
                        ? min(max(segment.confidence, 0.25), 1)
                        : 0.25
                    score *= confidence
                    if score > bestScore {
                        bestScore = score
                        bestSegment = segment
                    }
                }

                // Navigation documents repeat their owning notebook's title.
                // It is context, not page-authored content, so scoring it would
                // manufacture an arbitrary page target for any title query.
                // Outside reserved semantic queries, the separately indexed
                // notebook-title document remains the title-search authority
                // and has no page target. `>=` preserves the prior title-first
                // tie break without scanning every segment a second time.
                if !isExactBookmarkQuery,
                   !isNavigationDocument,
                   title.contains(query),
                   8.0 >= bestScore {
                    bestScore = 8.0
                    bestSegment = nil
                }

                guard bestScore.isFinite, bestScore > 0 else { return nil }
                let snippet = bestSegment?.source == .bookmark
                    ? PageNavigationSearchQueryPolicy.bookmarkSnippet(
                        for: boundedText
                    )
                    : Self.snippet(
                        from: bestSegment?.text ?? document.title,
                        query: query
                    )
                return LocalSearchHit(
                    documentID: document.id,
                    notebookID: document.notebookID,
                    pageID: bestSegment?.pageID ?? document.pageID,
                    title: document.title,
                    snippet: snippet,
                    score: bestScore,
                    segment: bestSegment,
                    sourceFingerprint: document.sourceFingerprint
                )
            }
            .sorted {
                if $0.score == $1.score {
                    if $0.title == $1.title { return $0.documentID.uuidString < $1.documentID.uuidString }
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
                return $0.score > $1.score
            }
            .prefix(min(limit, limits.maximumResults))
            .map { $0 }
    }

    public func querySegments(
        _ text: String,
        notebookID: UUID? = nil,
        limit: Int = 100
    ) async -> [LocalSearchSegmentHit] {
        guard limit > 0,
              limits.maximumResults > 0,
              limits.maximumQueryCharacters > 0 else { return [] }
        let boundedText = String(text.prefix(limits.maximumQueryCharacters))
        let query = Self.normalized(boundedText)
        guard !query.isEmpty, !Task.isCancelled else { return [] }
        let queryTokens = Set(Self.tokens(in: query))
        let isExactBookmarkQuery = PageNavigationSearchQueryPolicy
            .isExactBookmarkQuery(query)
        let pageTombstones = deletedPageSearchTombstones
        let resultLimit = min(
            min(limit, limits.maximumResults),
            Self.maximumSegmentQueryResults
        )
        let compactionThreshold = max(resultLimit * 2, resultLimit + 1)
        var hits: [LocalSearchSegmentHit] = []
        hits.reserveCapacity(resultLimit)
        var scannedSegmentCount = 0

        for document in documents.values where notebookID == nil
            || document.notebookID == notebookID {
            if let pageID = document.pageID {
                let key = PageSearchKey(
                    notebookID: document.notebookID,
                    pageID: pageID
                )
                if pageTombstones[key]?.contains(document.id) == true {
                    continue
                }
            }
            let isNavigationDocument = document.segments.contains {
                $0.source == .outline || $0.source == .bookmark
            }
            for segment in document.segments {
                scannedSegmentCount += 1
                if scannedSegmentCount.isMultiple(of: 128), Task.isCancelled {
                    return []
                }
                if isNavigationDocument,
                   segment.source != .outline,
                   segment.source != .bookmark {
                    continue
                }
                guard let pageID = segment.pageID ?? document.pageID else {
                    continue
                }
                if segment.source == .bookmark {
                    guard isExactBookmarkQuery else { continue }
                    hits.append(LocalSearchSegmentHit(
                        documentID: document.id,
                        notebookID: document.notebookID,
                        pageID: pageID,
                        title: document.title,
                        snippet: PageNavigationSearchQueryPolicy
                            .bookmarkSnippet(for: boundedText),
                        score: 7.5,
                        segment: segment,
                        sourceFingerprint: document.sourceFingerprint
                    ))
                    if hits.count >= compactionThreshold {
                        hits.sort(by: Self.isOrderedBefore)
                        hits.removeSubrange(resultLimit...)
                    }
                    continue
                }
                guard !isExactBookmarkQuery else { continue }
                let candidate = Self.normalized(segment.text)
                let containsPhrase = candidate.contains(query)
                let candidateTokens = Set(Self.tokens(in: candidate))
                let containsAllTokens = !queryTokens.isEmpty
                    && queryTokens.isSubset(of: candidateTokens)
                guard containsPhrase || containsAllTokens else { continue }
                var score = containsPhrase ? 6.0 : 0.0
                score += Double(queryTokens.count) * 1.5
                let confidence = segment.confidence.isFinite
                    ? min(max(segment.confidence, 0.25), 1)
                    : 0.25
                score *= confidence
                guard score.isFinite, score > 0 else { continue }

                hits.append(LocalSearchSegmentHit(
                    documentID: document.id,
                    notebookID: document.notebookID,
                    pageID: pageID,
                    title: document.title,
                    snippet: Self.snippet(from: segment.text, query: query),
                    score: score,
                    segment: segment,
                    sourceFingerprint: document.sourceFingerprint
                ))
                if hits.count >= compactionThreshold {
                    hits.sort(by: Self.isOrderedBefore)
                    hits.removeSubrange(resultLimit...)
                }
            }
        }

        hits.sort(by: Self.isOrderedBefore)
        guard !Task.isCancelled else { return [] }
        return Array(hits.prefix(resultLimit))
    }

    private func commit(_ next: [UUID: SearchIndexDocument]) throws {
        guard next.count <= limits.maximumDocumentCount else { throw SearchIndexError.snapshotTooLarge }
        try Self.validateCollection(next.values, limits: limits)
        let (nextGeneration, overflow) = generation.addingReportingOverflow(1)
        let targetGeneration = overflow ? 0 : nextGeneration
        try persist(next, generation: targetGeneration)
        documents = next
        generation = targetGeneration
        state = next.isEmpty ? .empty : .loaded
    }

    private func persist(_ next: [UUID: SearchIndexDocument], generation: UInt64) throws {
        guard let persistenceURL else { return }
        try fileManager.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let snapshot = Snapshot(
            generation: generation,
            documents: next.values.sorted { $0.id.uuidString < $1.id.uuidString }
        )
        let data = try Self.encoder.encode(snapshot)
        guard data.count <= limits.maximumSnapshotBytes else { throw SearchIndexError.snapshotTooLarge }
        // Commit the fallback first and require both copies to succeed. If the
        // primary write then fails, readers still prefer the previous valid
        // primary; if the backup write fails, the primary remains untouched.
        // This ordering is especially important when a library-root switch
        // clears private documents: a stale fallback must never be resurrected.
        if let backupURL {
            try data.write(to: backupURL, options: [.atomic, .completeFileProtection])
        }
        try data.write(to: persistenceURL, options: [.atomic, .completeFileProtection])
    }

    private static func load(
        primaryURL: URL?,
        backupURL: URL?,
        fileManager: FileManager,
        limits: SearchIndexLimits
    ) -> LoadResult {
        guard let primaryURL else {
            return LoadResult(documents: [:], generation: 0, state: .empty)
        }
        if let snapshot = try? readSnapshot(at: primaryURL, fileManager: fileManager, limits: limits),
           let reduced = try? reduce(snapshot.documents, limits: limits) {
            return LoadResult(
                documents: reduced,
                generation: snapshot.generation,
                state: reduced.isEmpty ? .empty : .loaded
            )
        }
        let primaryExisted = fileManager.fileExists(atPath: primaryURL.path)
        if let backupURL,
           let snapshot = try? readSnapshot(at: backupURL, fileManager: fileManager, limits: limits),
           let reduced = try? reduce(snapshot.documents, limits: limits) {
            if let data = try? encoder.encode(snapshot), data.count <= limits.maximumSnapshotBytes {
                try? fileManager.createDirectory(
                    at: primaryURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? data.write(to: primaryURL, options: [.atomic, .completeFileProtection])
            }
            return LoadResult(
                documents: reduced,
                generation: snapshot.generation,
                state: .recoveredFromBackup
            )
        }
        let backupExisted = backupURL.map { fileManager.fileExists(atPath: $0.path) } ?? false
        return LoadResult(
            documents: [:],
            generation: 0,
            state: primaryExisted || backupExisted ? .resetAfterCorruption : .empty
        )
    }

    private static func readSnapshot(
        at url: URL,
        fileManager: FileManager,
        limits: SearchIndexLimits
    ) throws -> Snapshot {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= limits.maximumSnapshotBytes else {
            throw SearchIndexError.snapshotTooLarge
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        let snapshot = try decoder.decode(Snapshot.self, from: data)
        guard snapshot.schemaVersion == 1 || snapshot.schemaVersion == 2 else {
            throw SearchIndexError.unsupportedSchema(snapshot.schemaVersion)
        }
        return snapshot
    }

    private static func reduce(
        _ input: [SearchIndexDocument],
        limits: SearchIndexLimits
    ) throws -> [UUID: SearchIndexDocument] {
        guard input.count <= limits.maximumDocumentCount else { throw SearchIndexError.snapshotTooLarge }
        var result: [UUID: SearchIndexDocument] = [:]
        for document in input {
            try validate(document, limits: limits)
            guard let existing = result[document.id] else {
                result[document.id] = document
                continue
            }
            if document.revision == existing.revision {
                guard hasSameRevisionPayload(existing, document) else {
                    throw SearchIndexError.revisionConflict(document.id)
                }
            } else if document.revision > existing.revision {
                result[document.id] = document
            }
        }
        try validateCollection(result.values, limits: limits)
        return result
    }

    private static func validate(_ document: SearchIndexDocument, limits: SearchIndexLimits) throws {
        guard document.revision >= 0 else { throw SearchIndexError.invalidRevision(document.revision) }
        guard document.segments.count <= limits.maximumSegmentsPerDocument else {
            throw SearchIndexError.documentTooLarge(document.id)
        }
        var characters = document.title.count
        if let sourceFingerprint = document.sourceFingerprint {
            let (sum, overflow) = characters.addingReportingOverflow(sourceFingerprint.count)
            guard !overflow, sourceFingerprint.count <= 1_024,
                  sum <= limits.maximumCharactersPerDocument else {
                throw SearchIndexError.documentTooLarge(document.id)
            }
            characters = sum
        }
        guard characters <= limits.maximumCharactersPerDocument else {
            throw SearchIndexError.documentTooLarge(document.id)
        }
        for segment in document.segments {
            let (sum, overflow) = characters.addingReportingOverflow(segment.text.count)
            guard !overflow, sum <= limits.maximumCharactersPerDocument else {
                throw SearchIndexError.documentTooLarge(document.id)
            }
            characters = sum
        }
    }

    private static func validateCollection<S: Sequence>(
        _ documents: S,
        limits: SearchIndexLimits
    ) throws where S.Element == SearchIndexDocument {
        guard limits.maximumTotalCharacters > 0 else { throw SearchIndexError.snapshotTooLarge }
        var total = 0
        for document in documents {
            var documentCount = document.title.count
            if let sourceFingerprint = document.sourceFingerprint {
                let (sum, overflow) = documentCount.addingReportingOverflow(sourceFingerprint.count)
                guard !overflow else { throw SearchIndexError.snapshotTooLarge }
                documentCount = sum
            }
            for segment in document.segments {
                let (sum, overflow) = documentCount.addingReportingOverflow(segment.text.count)
                guard !overflow else { throw SearchIndexError.snapshotTooLarge }
                documentCount = sum
            }
            let (sum, overflow) = total.addingReportingOverflow(documentCount)
            guard !overflow, sum <= limits.maximumTotalCharacters else {
                throw SearchIndexError.snapshotTooLarge
            }
            total = sum
        }
    }

    private static func hasSameRevisionPayload(
        _ left: SearchIndexDocument,
        _ right: SearchIndexDocument
    ) -> Bool {
        left.id == right.id
            && left.notebookID == right.notebookID
            && left.pageID == right.pageID
            && left.title == right.title
            && left.revision == right.revision
            && left.sourceFingerprint == right.sourceFingerprint
            && left.segments == right.segments
            && left.modifiedAt == right.modifiedAt
    }

    private static func isNotebookTitleAuthority(
        _ document: SearchIndexDocument
    ) -> Bool {
        document.id == document.notebookID
            && document.pageID == nil
            && document.sourceFingerprint == nil
            && document.segments.isEmpty
    }

    private func isPageDocumentTombstoned(
        _ document: SearchIndexDocument
    ) -> Bool {
        guard let pageID = document.pageID else { return false }
        let key = PageSearchKey(
            notebookID: document.notebookID,
            pageID: pageID
        )
        return deletedPageSearchTombstones[key]?.contains(document.id) == true
    }

    private static func hasSameTitleAuthorityPayload(
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

    /// Serial-number arithmetic keeps generation ordering valid across UInt64
    /// wraparound without allowing a very old publication to become newest.
    private static func isNewerPublicationGeneration(
        _ candidate: UInt64,
        than current: UInt64
    ) -> Bool {
        let distance = candidate &- current
        return distance != 0 && distance <= UInt64.max / 2
    }

    private static func normalized(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokens(in text: String) -> [String] {
        let words = text.split { $0.isWhitespace || $0.isPunctuation }.prefix(256).map(String.init)
        if words.count > 1 { return words.filter { !$0.isEmpty } }
        // Chinese notes often have no spaces. Bigrams provide useful local matching without a server tokenizer.
        let characters = Array(text.prefix(512)).filter { !$0.isWhitespace }
        guard characters.count > 1 else { return words }
        return (0..<min(characters.count - 1, 256)).map { String(characters[$0...$0 + 1]) }
    }

    private static func snippet(from text: String, query: String) -> String {
        let collapsed = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard let range = collapsed.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        ) else {
            return String(collapsed.prefix(180))
        }
        let distance = collapsed.distance(from: collapsed.startIndex, to: range.lowerBound)
        let startOffset = max(0, distance - 50)
        let start = collapsed.index(collapsed.startIndex, offsetBy: min(startOffset, collapsed.count))
        let end = collapsed.index(start, offsetBy: min(180, collapsed.distance(from: start, to: collapsed.endIndex)))
        return (startOffset > 0 ? "…" : "")
            + String(collapsed[start..<end])
            + (end < collapsed.endIndex ? "…" : "")
    }

    private static func isOrderedBefore(
        _ left: LocalSearchSegmentHit,
        _ right: LocalSearchSegmentHit
    ) -> Bool {
        if left.score != right.score { return left.score > right.score }
        let titleOrder = left.title.localizedStandardCompare(right.title)
        if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
        if left.pageID != right.pageID {
            return left.pageID.uuidString < right.pageID.uuidString
        }
        if left.id.documentID != right.id.documentID {
            return left.id.documentID.uuidString
                < right.id.documentID.uuidString
        }
        return left.id.segmentID.uuidString < right.id.segmentID.uuidString
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
