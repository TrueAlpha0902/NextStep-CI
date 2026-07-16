import Foundation
import Testing
@testable import NotesServices

@Test("Equal search revisions with different content are rejected")
func searchRevisionConflictIsRejected() async throws {
    let documentID = UUID()
    let notebookID = UUID()
    let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let index = LocalSearchIndex()
    try await index.upsert(
        SearchIndexDocument(
            id: documentID,
            notebookID: notebookID,
            title: "Version A",
            revision: 3,
            segments: [RecognizedTextSegment(text: "alpha", source: .typedText)],
            modifiedAt: modifiedAt
        )
    )
    #expect(await index.revision(for: documentID) == 3)

    await #expect(throws: SearchIndexError.revisionConflict(documentID)) {
        try await index.upsert(
            SearchIndexDocument(
                id: documentID,
                notebookID: notebookID,
                title: "Version B",
                revision: 3,
                segments: [RecognizedTextSegment(text: "beta", source: .typedText)],
                modifiedAt: modifiedAt
            )
        )
    }
    #expect(await index.query("alpha", notebookID: nil, limit: 10).count == 1)
    #expect(await index.query("beta", notebookID: nil, limit: 10).isEmpty)
    #expect(await index.revision(for: documentID) == 3)
}

@Test("Equal search revisions cannot silently change only the modification date")
func searchRevisionModifiedDateConflictIsRejected() async throws {
    let documentID = UUID()
    let notebookID = UUID()
    let first = SearchIndexDocument(
        id: documentID,
        notebookID: notebookID,
        title: "Stable payload",
        revision: 7,
        sourceFingerprint: String(repeating: "a", count: 64),
        segments: [RecognizedTextSegment(text: "same text", source: .audioTranscript)],
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    var changedDate = first
    changedDate.modifiedAt = first.modifiedAt.addingTimeInterval(1)

    let index = LocalSearchIndex()
    try await index.upsert(first)
    await #expect(throws: SearchIndexError.revisionConflict(documentID)) {
        try await index.upsert(changedDate)
    }

    let rebuilt = LocalSearchIndex()
    await #expect(throws: SearchIndexError.revisionConflict(documentID)) {
        try await rebuilt.rebuild(from: [first, changedDate])
    }
}

@Test("Atomic search retitling preserves current payload and never recreates a removed document")
func atomicSearchRetitlingPreservesPayloadAndAbsence() async throws {
    let documentID = UUID()
    let notebookID = UUID()
    let pageID = UUID()
    let fingerprint = String(repeating: "b", count: 64)
    let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let segment = RecognizedTextSegment(
        text: "current OCR payload",
        pageID: pageID,
        source: .scannedImage
    )
    let original = SearchIndexDocument(
        id: documentID,
        notebookID: notebookID,
        pageID: pageID,
        title: "Original title",
        revision: 7,
        sourceFingerprint: fingerprint,
        segments: [segment],
        modifiedAt: modifiedAt
    )
    let index = LocalSearchIndex()
    try await index.upsert(SearchIndexDocument(
        id: notebookID,
        notebookID: notebookID,
        title: original.title,
        revision: 1,
        segments: []
    ))
    try await index.upsert(original)

    try await index.retitleDocument(
        documentID: documentID,
        notebookID: UUID(),
        pageID: pageID
    )
    try await index.retitleDocument(
        documentID: documentID,
        notebookID: notebookID,
        pageID: UUID()
    )
    try await index.retitleDocument(
        documentID: documentID,
        notebookID: notebookID,
        pageID: pageID
    )
    #expect(await index.document(for: documentID) == original)

    try await index.upsert(SearchIndexDocument(
        id: notebookID,
        notebookID: notebookID,
        title: "Renamed notebook",
        revision: 2,
        segments: []
    ))
    try await index.retitleDocument(
        documentID: documentID,
        notebookID: notebookID,
        pageID: pageID
    )
    let storedDocument = await index.document(for: documentID)
    let stored = try #require(storedDocument)
    #expect(stored.title == "Renamed notebook")
    #expect(stored.revision == 8)
    #expect(stored.sourceFingerprint == fingerprint)
    #expect(stored.segments == [segment])
    #expect(stored.modifiedAt == modifiedAt)

    let refreshedSegment = RecognizedTextSegment(
        text: "new OCR payload with a stale captured title",
        pageID: pageID,
        source: .scannedImage
    )
    let refreshedAt = modifiedAt.addingTimeInterval(30)
    try await index.upsertUsingCurrentNotebookTitle(SearchIndexDocument(
        id: documentID,
        notebookID: notebookID,
        pageID: pageID,
        title: "Original title",
        revision: 20,
        sourceFingerprint: String(repeating: "c", count: 64),
        segments: [refreshedSegment],
        modifiedAt: refreshedAt
    ))
    let refreshedDocument = await index.document(for: documentID)
    let refreshed = try #require(refreshedDocument)
    #expect(refreshed.title == "Renamed notebook")
    #expect(refreshed.revision == 20)
    #expect(refreshed.sourceFingerprint == String(repeating: "c", count: 64))
    #expect(refreshed.segments == [refreshedSegment])
    #expect(refreshed.modifiedAt == refreshedAt)

    await #expect(throws: SearchIndexError.revisionConflict(documentID)) {
        try await index.upsertUsingCurrentNotebookTitle(SearchIndexDocument(
            id: documentID,
            notebookID: UUID(),
            pageID: pageID,
            title: "Forged provenance",
            revision: 21,
            segments: [refreshedSegment]
        ))
    }
    #expect(await index.document(for: documentID) == refreshed)

    try await index.remove(documentID: documentID)
    try await index.retitleDocument(
        documentID: documentID,
        notebookID: notebookID,
        pageID: pageID
    )
    #expect(await index.document(for: documentID) == nil)

    try await index.upsertUsingCurrentNotebookTitle(SearchIndexDocument(
        id: documentID,
        notebookID: notebookID,
        pageID: pageID,
        title: "Captured before rename",
        revision: 30,
        segments: [refreshedSegment]
    ))
    #expect(await index.document(for: documentID)?.title == "Renamed notebook")

    try await index.removeNotebook(notebookID)
    await #expect(throws: SearchIndexError.revisionConflict(documentID)) {
        try await index.upsertUsingCurrentNotebookTitle(SearchIndexDocument(
            id: documentID,
            notebookID: notebookID,
            pageID: pageID,
            title: "Must fail without title authority",
            revision: 31,
            segments: [refreshedSegment]
        ))
    }
    #expect(await index.document(for: documentID) == nil)
}

@Test("Atomic search retitling rejects revision overflow without changing the document")
func atomicSearchRetitlingRejectsRevisionOverflow() async throws {
    let documentID = UUID()
    let notebookID = UUID()
    let pageID = UUID()
    let original = SearchIndexDocument(
        id: documentID,
        notebookID: notebookID,
        pageID: pageID,
        title: "Maximum revision",
        revision: Int.max,
        segments: [RecognizedTextSegment(
            text: "stable payload",
            pageID: pageID,
            source: .typedText
        )]
    )
    let index = LocalSearchIndex()
    try await index.upsert(SearchIndexDocument(
        id: notebookID,
        notebookID: notebookID,
        title: "Overflow",
        revision: 1,
        segments: []
    ))
    try await index.upsert(original)

    await #expect(throws: SearchIndexError.revisionConflict(documentID)) {
        try await index.retitleDocument(
            documentID: documentID,
            notebookID: notebookID,
            pageID: pageID
        )
    }
    #expect(await index.document(for: documentID) == original)
}

@Test("Notebook title authority rejects a late older publication generation")
func notebookTitleAuthorityRejectsLateOlderGeneration() async throws {
    let notebookID = UUID()
    let current = SearchIndexDocument(
        id: notebookID,
        notebookID: notebookID,
        title: "Current title",
        revision: 5,
        segments: [],
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_020)
    )
    let stale = SearchIndexDocument(
        id: notebookID,
        notebookID: notebookID,
        title: "Stale title",
        revision: Int.max / 4,
        segments: [],
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_010)
    )
    let latest = SearchIndexDocument(
        id: notebookID,
        notebookID: notebookID,
        title: "Latest title",
        revision: 0,
        segments: [],
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_030)
    )
    let index = LocalSearchIndex()

    try await index.upsertNotebookTitleAuthority(
        current,
        publicationGeneration: 20
    )
    try await index.upsertNotebookTitleAuthority(
        stale,
        publicationGeneration: 19
    )
    #expect(await index.document(for: notebookID) == current)

    try await index.upsertNotebookTitleAuthority(
        latest,
        publicationGeneration: 21
    )
    let storedDocument = await index.document(for: notebookID)
    let stored = try #require(storedDocument)
    #expect(stored.title == latest.title)
    #expect(stored.revision == current.revision + 1)
    #expect(stored.modifiedAt == latest.modifiedAt)

    var conflictingSameGeneration = latest
    conflictingSameGeneration.title = "Conflicting title"
    await #expect(throws: SearchIndexError.revisionConflict(notebookID)) {
        try await index.upsertNotebookTitleAuthority(
            conflictingSameGeneration,
            publicationGeneration: 21
        )
    }
    #expect(await index.document(for: notebookID) == stored)

    var invalidRevision = latest
    invalidRevision.revision = -1
    await #expect(throws: SearchIndexError.invalidRevision(-1)) {
        try await index.upsertNotebookTitleAuthority(
            invalidRevision,
            publicationGeneration: 22
        )
    }
    #expect(await index.document(for: notebookID) == stored)
}

@Test("A durable page-delete tombstone rejects late page publications")
func pageDeleteTombstoneRejectsLatePublication() async throws {
    let notebookID = UUID()
    let pageID = UUID()
    let segment = RecognizedTextSegment(
        text: "late deleted-page OCR",
        pageID: pageID,
        source: .scannedImage
    )
    let authority = SearchIndexDocument(
        id: notebookID,
        notebookID: notebookID,
        title: "Current notebook",
        revision: 1,
        segments: []
    )
    let pageDocument = SearchIndexDocument(
        id: pageID,
        notebookID: notebookID,
        pageID: pageID,
        title: "Captured notebook title",
        revision: 1,
        segments: [segment]
    )
    let transcriptDocumentID = UUID()
    let transcriptDocument = SearchIndexDocument(
        id: transcriptDocumentID,
        notebookID: notebookID,
        pageID: pageID,
        title: "Audio",
        revision: 1,
        segments: [RecognizedTextSegment(
            text: "cross-page transcript remains independently owned",
            pageID: pageID,
            source: .audioTranscript
        )]
    )
    let index = LocalSearchIndex()
    try await index.upsert(authority)
    try await index.upsert(transcriptDocument)
    try await index.upsertUsingCurrentNotebookTitle(pageDocument)
    #expect(await index.document(for: pageID)?.title == authority.title)

    try await index.removePageDocuments(
        notebookID: notebookID,
        pageID: pageID,
        documentIDs: [pageID]
    )
    #expect(await index.document(for: pageID) == nil)
    #expect(await index.document(for: transcriptDocumentID) == transcriptDocument)

    var lateDocument = pageDocument
    lateDocument.revision = Int.max / 4
    try await index.upsertUsingCurrentNotebookTitle(lateDocument)
    #expect(await index.document(for: pageID) == nil)
    let latePublicationHits = await index.query(
        segment.text,
        notebookID: notebookID,
        limit: 10
    )
    #expect(!latePublicationHits.contains {
        $0.documentID == pageDocument.id
    })

    try await index.retainNotebooks([])
    try await index.upsert(authority)
    try await index.upsertUsingCurrentNotebookTitle(lateDocument)
    #expect(await index.document(for: pageID)?.title == authority.title)
}

@Test("A page-delete tombstone stays fail-closed when persistence fails")
func pageDeleteTombstoneSurvivesPersistenceFailure() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "NotesPageDeleteFailure-\(UUID().uuidString)",
        isDirectory: true
    )
    let indexURL = root.appendingPathComponent("search-index.json")
    let backupURL = indexURL.appendingPathExtension("backup")
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: root) }

    let notebookID = UUID()
    let pageID = UUID()
    let pageText = "failed persistence deleted-page sentinel"
    let authority = SearchIndexDocument(
        id: notebookID,
        notebookID: notebookID,
        title: "Persistence authority",
        revision: 1,
        segments: []
    )
    let pageDocument = SearchIndexDocument(
        id: pageID,
        notebookID: notebookID,
        pageID: pageID,
        title: "Captured title",
        revision: 1,
        segments: [RecognizedTextSegment(
            text: pageText,
            pageID: pageID,
            source: .scannedImage
        )]
    )
    let index = LocalSearchIndex(persistenceURL: indexURL)
    try await index.upsert(authority)
    try await index.upsertUsingCurrentNotebookTitle(pageDocument)

    try FileManager.default.removeItem(at: indexURL)
    try FileManager.default.removeItem(at: backupURL)
    try FileManager.default.createDirectory(
        at: indexURL,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: backupURL,
        withIntermediateDirectories: true
    )

    do {
        try await index.removePageDocuments(
            notebookID: notebookID,
            pageID: pageID,
            documentIDs: [pageID]
        )
        Issue.record("Deleting through an unwritable index unexpectedly succeeded")
    } catch {
        // Persistence errors vary by platform; fail-closed visibility is the
        // contract under test.
    }

    #expect(await index.indexedDocumentCount() == 2)
    #expect(await index.document(for: pageID) == nil)
    #expect(await index.revision(for: pageID) == nil)
    #expect(await index.query(
        pageText,
        notebookID: notebookID,
        limit: 10
    ).isEmpty)

    var lateDocument = pageDocument
    lateDocument.revision = Int.max / 4
    try await index.upsertUsingCurrentNotebookTitle(lateDocument)
    #expect(await index.document(for: pageID) == nil)
}

@Test("A schema-one search snapshot decodes without a source fingerprint")
func legacySearchIndexSnapshotDecodesWithoutFingerprint() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NotesLegacySearch-\(UUID().uuidString)", isDirectory: true)
    let indexURL = root.appendingPathComponent("search-index.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let documentID = UUID()
    let legacyDocument = SearchIndexDocument(
        id: documentID,
        notebookID: UUID(),
        title: "Legacy",
        revision: 2,
        segments: [RecognizedTextSegment(text: "legacy searchable text", source: .typedText)],
        modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let encodedDocument = try encoder.encode(legacyDocument)
    var documentObject = try #require(
        JSONSerialization.jsonObject(with: encodedDocument) as? [String: Any]
    )
    documentObject.removeValue(forKey: "sourceFingerprint")
    let legacySnapshot: [String: Any] = [
        "schemaVersion": 1,
        "generation": 4,
        "documents": [documentObject],
    ]
    let snapshotData = try JSONSerialization.data(withJSONObject: legacySnapshot)
    try snapshotData.write(to: indexURL, options: .atomic)

    let index = LocalSearchIndex(persistenceURL: indexURL)
    let loadedDocument = await index.document(for: documentID)
    let hits = await index.query("searchable", notebookID: nil, limit: 10)
    #expect(await index.loadState() == .loaded)
    #expect(loadedDocument?.sourceFingerprint == nil)
    #expect(hits.count == 1)
}

@Test("Search hits preserve their document source fingerprint")
func searchHitsPreserveDocumentSourceFingerprint() async throws {
    let notebookID = UUID()
    let fingerprintedPageID = UUID()
    let unfingerprintedPageID = UUID()
    let sourceFingerprint = String(repeating: "f", count: 64)
    let index = LocalSearchIndex()
    try await index.rebuild(from: [
        SearchIndexDocument(
            notebookID: notebookID,
            pageID: fingerprintedPageID,
            title: "Fingerprint source",
            revision: 1,
            sourceFingerprint: sourceFingerprint,
            segments: [RecognizedTextSegment(
                text: "signed searchable sentinel",
                pageID: fingerprintedPageID,
                source: .typedText
            )]
        ),
        SearchIndexDocument(
            notebookID: notebookID,
            pageID: unfingerprintedPageID,
            title: "Legacy source",
            revision: 1,
            segments: [RecognizedTextSegment(
                text: "plain searchable sentinel",
                pageID: unfingerprintedPageID,
                source: .typedText
            )]
        ),
    ])

    let fingerprintedHits = await index.query(
        "signed",
        notebookID: notebookID,
        limit: 10
    )
    let fingerprintedSegmentHits = await index.querySegments(
        "signed",
        notebookID: notebookID,
        limit: 10
    )
    #expect(fingerprintedHits.count == 1)
    #expect(fingerprintedHits.first?.sourceFingerprint == sourceFingerprint)
    #expect(fingerprintedSegmentHits.count == 1)
    #expect(fingerprintedSegmentHits.first?.sourceFingerprint == sourceFingerprint)

    let unfingerprintedHits = await index.query(
        "plain",
        notebookID: notebookID,
        limit: 10
    )
    let unfingerprintedSegmentHits = await index.querySegments(
        "plain",
        notebookID: notebookID,
        limit: 10
    )
    #expect(unfingerprintedHits.count == 1)
    #expect(unfingerprintedHits.first?.sourceFingerprint == nil)
    #expect(unfingerprintedSegmentHits.count == 1)
    #expect(unfingerprintedSegmentHits.first?.sourceFingerprint == nil)
}

@Test("A legacy encoded search hit decodes without a source fingerprint")
func legacySearchHitDecodesWithoutFingerprint() throws {
    let hit = LocalSearchHit(
        documentID: UUID(),
        notebookID: UUID(),
        pageID: UUID(),
        title: "Legacy hit",
        snippet: "search result",
        score: 6,
        segment: RecognizedTextSegment(
            text: "search result",
            source: .typedText
        ),
        sourceFingerprint: String(repeating: "a", count: 64)
    )
    let encoded = try JSONEncoder().encode(hit)
    var object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object.removeValue(forKey: "sourceFingerprint")
    let legacyData = try JSONSerialization.data(withJSONObject: object)

    let decoded = try JSONDecoder().decode(LocalSearchHit.self, from: legacyData)
    #expect(decoded.documentID == hit.documentID)
    #expect(decoded.sourceFingerprint == nil)
}

@Test("A corrupt primary search snapshot recovers from its atomic backup")
func corruptSearchIndexRecoversFromBackup() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NotesSearchRecovery-\(UUID().uuidString)", isDirectory: true)
    let indexURL = root.appendingPathComponent("search-index.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let original = LocalSearchIndex(persistenceURL: indexURL)
    try await original.upsert(
        SearchIndexDocument(
            notebookID: UUID(),
            title: "Recovery",
            revision: 1,
            segments: [RecognizedTextSegment(text: "可恢復的索引內容", source: .typedText)]
        )
    )
    try Data("not-json".utf8).write(to: indexURL, options: .atomic)

    let recovered = LocalSearchIndex(persistenceURL: indexURL)
    #expect(await recovered.loadState() == .recoveredFromBackup)
    #expect(await recovered.query("恢復", notebookID: nil, limit: 10).count == 1)
    #expect(await recovered.indexedDocumentCount() == 1)
}

@Test("An authoritative empty retain rewrites a stale legacy backup")
func authoritativeEmptyRetainRewritesLegacyBackup() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NotesSearchEmptyAuthority-\(UUID().uuidString)", isDirectory: true)
    let indexURL = root.appendingPathComponent("search-index.json")
    let emptyURL = root.appendingPathComponent("empty-index.json")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let notebookID = UUID()
    let legacy = LocalSearchIndex(persistenceURL: indexURL)
    try await legacy.upsert(SearchIndexDocument(
        notebookID: notebookID,
        title: "Previous root",
        revision: 1,
        segments: [RecognizedTextSegment(
            text: "legacy private fallback",
            source: .typedText
        )]
    ))

    // Recreate the state produced by the former best-effort backup write: a
    // valid empty primary beside an older fallback containing private text.
    let empty = LocalSearchIndex(persistenceURL: emptyURL)
    try await empty.rebuild(from: [])
    let emptyPrimary = try Data(contentsOf: emptyURL)
    try emptyPrimary.write(to: indexURL, options: .atomic)

    let migrated = LocalSearchIndex(persistenceURL: indexURL)
    #expect(await migrated.indexedDocumentCount() == 0)
    try await migrated.retainNotebooks([])
    try Data("corrupt-primary".utf8).write(to: indexURL, options: .atomic)

    let recovered = LocalSearchIndex(persistenceURL: indexURL)
    #expect(await recovered.loadState() == .recoveredFromBackup)
    #expect(await recovered.query(
        "legacy private fallback",
        notebookID: notebookID,
        limit: 10
    ).isEmpty)
    #expect(await recovered.indexedDocumentCount() == 0)
}

@Test("Corrupt search snapshots reset safely instead of exposing partial data")
func fullyCorruptSearchIndexResets() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NotesSearchCorrupt-\(UUID().uuidString)", isDirectory: true)
    let indexURL = root.appendingPathComponent("search-index.json")
    let backupURL = indexURL.appendingPathExtension("backup")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("bad-primary".utf8).write(to: indexURL)
    try Data("bad-backup".utf8).write(to: backupURL)

    let index = LocalSearchIndex(persistenceURL: indexURL)
    #expect(await index.loadState() == .resetAfterCorruption)
    #expect(await index.indexedDocumentCount() == 0)
    #expect(await index.query("anything", notebookID: nil, limit: 10).isEmpty)
}

@Test("Failed search persistence does not mutate the live index")
func failedSearchPersistenceIsTransactional() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NotesSearchTransaction-\(UUID().uuidString)", isDirectory: true)
    let directoryUsedAsFile = root.appendingPathComponent("index.json", isDirectory: true)
    try FileManager.default.createDirectory(at: directoryUsedAsFile, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let index = LocalSearchIndex(persistenceURL: directoryUsedAsFile)

    do {
        try await index.upsert(
            SearchIndexDocument(
                notebookID: UUID(),
                title: "Must not commit",
                revision: 1,
                segments: [RecognizedTextSegment(text: "transaction sentinel", source: .typedText)]
            )
        )
        Issue.record("Writing an index snapshot over a directory unexpectedly succeeded")
    } catch {
        // The concrete Cocoa error is platform-dependent; the state invariant is what matters.
    }

    #expect(await index.query("sentinel", notebookID: nil, limit: 10).isEmpty)
    #expect(await index.indexedDocumentCount() == 0)
}

@Test("Invalid search revisions and result limits are bounded")
func invalidSearchInputsAreBounded() async throws {
    let index = LocalSearchIndex()
    await #expect(throws: SearchIndexError.invalidRevision(-1)) {
        try await index.upsert(
            SearchIndexDocument(
                notebookID: UUID(),
                title: "Invalid",
                revision: -1,
                segments: []
            )
        )
    }
    #expect(await index.query("query", notebookID: nil, limit: 0).isEmpty)
    #expect(await index.querySegments(
        "query",
        notebookID: nil,
        limit: 0
    ).isEmpty)

    let notebookID = UUID()
    let pageID = UUID()
    try await index.upsert(SearchIndexDocument(
        notebookID: notebookID,
        pageID: pageID,
        title: "Bounded",
        revision: 1,
        segments: (0..<501).map { index in
            RecognizedTextSegment(
                text: "bounded segment \(index)",
                source: .typedText
            )
        }
    ))
    let segmentHits = await index.querySegments(
        "bounded",
        notebookID: notebookID,
        limit: .max
    )
    #expect(segmentHits.count == 500)

    try await index.upsert(SearchIndexDocument(
        notebookID: notebookID,
        title: "Not navigable",
        revision: 1,
        segments: [
            RecognizedTextSegment(
                text: "bounded but missing a page target",
                source: .typedText
            ),
        ]
    ))
    let navigableHits = await index.querySegments(
        "missing a page target",
        notebookID: notebookID,
        limit: 10
    )
    #expect(navigableHits.isEmpty)

    let cancelledQuery = Task {
        // Force the child task to establish a cancellation point before the
        // fast in-memory query can finish on another executor.
        try? await Task<Never, Never>.sleep(for: .seconds(1))
        return await index.querySegments(
            "bounded",
            notebookID: notebookID,
            limit: 10
        )
    }
    cancelledQuery.cancel()
    let cancelledHits = await cancelledQuery.value
    #expect(cancelledHits.isEmpty)
}

@Test("Source reconciliation removes orphan documents even when their segments are mixed")
func sourceReconciliationRemovesMixedOrphans() async throws {
    let notebookID = UUID()
    let retainedID = UUID()
    let orphanID = UUID()
    let unrelatedID = UUID()
    let index = LocalSearchIndex()
    try await index.rebuild(from: [
        SearchIndexDocument(
            id: retainedID,
            notebookID: notebookID,
            title: "Retained",
            revision: 1,
            segments: [RecognizedTextSegment(
                text: "current canvas",
                source: .canvasElement
            )]
        ),
        SearchIndexDocument(
            id: orphanID,
            notebookID: notebookID,
            title: "Mixed orphan",
            revision: 1,
            segments: [
                RecognizedTextSegment(
                    text: "stale canvas",
                    source: .canvasElement
                ),
                RecognizedTextSegment(
                    text: "unexpected typed segment",
                    source: .typedText
                ),
            ]
        ),
        SearchIndexDocument(
            id: unrelatedID,
            notebookID: notebookID,
            title: "Structured content",
            revision: 1,
            segments: [RecognizedTextSegment(
                text: "keep typed content",
                source: .typedText
            )]
        ),
    ])

    try await index.retainDocuments(
        notebookID: notebookID,
        source: .canvasElement,
        documentIDs: [retainedID]
    )

    #expect(await index.document(for: retainedID) != nil)
    #expect(await index.document(for: orphanID) == nil)
    #expect(await index.document(for: unrelatedID) != nil)
}

@Test("Navigation-owned mixed documents expose only navigation segments")
func navigationOwnedMixedDocumentsIgnoreOtherSources() async throws {
    let notebookID = UUID()
    let navigationPageID = UUID()
    let forgedPageID = UUID()
    let documentID = UUID()
    let outlineText = "Canonical navigation chapter"
    let forgedText = "private mixed-source payload"
    let index = LocalSearchIndex()
    try await index.upsert(SearchIndexDocument(
        id: documentID,
        notebookID: notebookID,
        pageID: navigationPageID,
        title: "Navigation document context",
        revision: 1,
        segments: [
            RecognizedTextSegment(
                text: outlineText,
                pageID: navigationPageID,
                source: .outline
            ),
            RecognizedTextSegment(
                text: PageNavigationSearchQueryPolicy.bookmarkSegmentText,
                pageID: navigationPageID,
                source: .bookmark
            ),
            RecognizedTextSegment(
                text: forgedText,
                pageID: forgedPageID,
                source: .typedText
            ),
        ]
    ))

    #expect(await index.query(
        forgedText,
        notebookID: notebookID,
        limit: 10
    ).isEmpty)
    #expect(await index.querySegments(
        forgedText,
        notebookID: notebookID,
        limit: 10
    ).isEmpty)

    let outlineHits = await index.query(
        outlineText,
        notebookID: notebookID,
        limit: 10
    )
    #expect(outlineHits.count == 1)
    #expect(outlineHits.first?.documentID == documentID)
    #expect(outlineHits.first?.pageID == navigationPageID)
    #expect(outlineHits.first?.segment?.source == .outline)

    let outlineSegmentHits = await index.querySegments(
        outlineText,
        notebookID: notebookID,
        limit: 10
    )
    #expect(outlineSegmentHits.count == 1)
    #expect(outlineSegmentHits.first?.id.documentID == documentID)
    #expect(outlineSegmentHits.first?.pageID == navigationPageID)
    #expect(outlineSegmentHits.first?.segment.source == .outline)

    let bookmarkHits = await index.query(
        "bookmark",
        notebookID: notebookID,
        limit: 10
    )
    #expect(bookmarkHits.count == 1)
    #expect(bookmarkHits.first?.pageID == navigationPageID)
    #expect(bookmarkHits.first?.segment?.source == .bookmark)

    let bookmarkSegmentHits = await index.querySegments(
        "bookmark",
        notebookID: notebookID,
        limit: 10
    )
    #expect(bookmarkSegmentHits.count == 1)
    #expect(bookmarkSegmentHits.first?.pageID == navigationPageID)
    #expect(bookmarkSegmentHits.first?.segment.source == .bookmark)
}
