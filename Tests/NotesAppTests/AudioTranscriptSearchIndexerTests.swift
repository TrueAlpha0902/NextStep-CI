import Foundation
import NotesCore
import NotesServices
@testable import NotesApp
import XCTest

final class AudioTranscriptSearchIndexerTests: XCTestCase {
    func testDocumentIdentityIsStableNamespacedAndIdempotent() async throws {
        let search = LocalSearchIndex()
        let indexer = NotebookAudioTranscriptSearchIndexer(searchIndex: search)
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let transcript = makeTranscript(
            sessionID: sessionID,
            generatedAt: generatedAt,
            segments: [makeSegment(text: "stable transcript", pageID: pageID)]
        )
        let assetID = digest("a")

        try await indexer.index(
            transcript,
            notebookID: notebookID,
            transcriptAssetID: assetID
        )
        let documentID = NotebookAudioTranscriptSearchIndexer.documentID(
            notebookID: notebookID,
            sessionID: sessionID
        )
        let storedFirst = await search.document(for: documentID)
        let first = try XCTUnwrap(storedFirst)
        try await indexer.index(
            transcript,
            notebookID: notebookID,
            transcriptAssetID: assetID
        )
        let storedSecond = await search.document(for: documentID)
        let second = try XCTUnwrap(storedSecond)

        XCTAssertEqual(first, second)
        XCTAssertEqual(documentID, NotebookAudioTranscriptSearchIndexer.documentID(
            notebookID: notebookID,
            sessionID: sessionID
        ))
        XCTAssertNotEqual(documentID, notebookID.rawValue)
        XCTAssertNotEqual(documentID, sessionID.rawValue)
        XCTAssertNotEqual(
            documentID,
            NotebookAudioTranscriptSearchIndexer.documentID(
                notebookID: NotebookID(),
                sessionID: sessionID
            )
        )
        XCTAssertEqual(first.sourceFingerprint, assetID.rawValue)
    }

    func testReplacementWithSameTimestampAdvancesRevisionAndRemovesOldText() async throws {
        let search = LocalSearchIndex()
        let indexer = NotebookAudioTranscriptSearchIndexer(searchIndex: search)
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let first = makeTranscript(
            sessionID: sessionID,
            generatedAt: generatedAt,
            segments: [makeSegment(text: "obsolete phrase")]
        )
        let replacement = makeTranscript(
            sessionID: sessionID,
            generatedAt: generatedAt,
            segments: [makeSegment(text: "replacement phrase")]
        )

        try await indexer.index(first, notebookID: notebookID, transcriptAssetID: digest("b"))
        let documentID = NotebookAudioTranscriptSearchIndexer.documentID(
            notebookID: notebookID,
            sessionID: sessionID
        )
        let storedFirstRevision = await search.revision(for: documentID)
        let firstRevision = try XCTUnwrap(storedFirstRevision)
        try await indexer.index(
            replacement,
            notebookID: notebookID,
            transcriptAssetID: digest("c")
        )

        let obsoleteHits = await search.query("obsolete", notebookID: nil, limit: 10)
        let replacementHits = await search.query("replacement", notebookID: nil, limit: 10)
        let replacementRevision = await search.revision(for: documentID)
        XCTAssertEqual(obsoleteHits.count, 0)
        XCTAssertEqual(replacementHits.count, 1)
        XCTAssertEqual(replacementRevision, firstRevision + 1)
    }

    func testMatchingLaterPageSegmentNavigatesToThatPage() async throws {
        let search = LocalSearchIndex()
        let indexer = NotebookAudioTranscriptSearchIndexer(searchIndex: search)
        let notebookID = NotebookID()
        let firstPageID = PageID()
        let laterPageID = PageID()
        let transcript = makeTranscript(
            sessionID: AudioSessionID(),
            segments: [
                makeSegment(text: "opening remarks", startTime: 0, pageID: firstPageID),
                makeSegment(text: "later navigation sentinel", startTime: 1, pageID: laterPageID),
                makeSegment(text: "more on the later page", startTime: 2, pageID: laterPageID),
            ]
        )

        try await indexer.index(
            transcript,
            notebookID: notebookID,
            transcriptAssetID: digest("d")
        )
        let navigationHits = await search.query(
            "navigation sentinel",
            notebookID: notebookID.rawValue,
            limit: 10
        )
        let hit = try XCTUnwrap(navigationHits.first)

        XCTAssertEqual(hit.pageID, laterPageID.rawValue)
        XCTAssertEqual(hit.segment?.pageID, laterPageID.rawValue)
        XCTAssertEqual(hit.segment?.source, .audioTranscript)
        let documentID = NotebookAudioTranscriptSearchIndexer.documentID(
            notebookID: notebookID,
            sessionID: transcript.audioSessionID
        )
        let stored = await search.document(for: documentID)
        XCTAssertEqual(stored?.segments.count, 2)
        XCTAssertEqual(
            stored?.segments.compactMap(\.pageID),
            [firstPageID.rawValue, laterPageID.rawValue]
        )
    }

    func testMatchingFingerprintDoesNotSkipMalformedStoredSourceShape() async throws {
        let search = LocalSearchIndex()
        let indexer = NotebookAudioTranscriptSearchIndexer(searchIndex: search)
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        let assetID = digest("4")
        let documentID = NotebookAudioTranscriptSearchIndexer.documentID(
            notebookID: notebookID,
            sessionID: sessionID
        )
        try await search.upsert(
            SearchIndexDocument(
                id: documentID,
                notebookID: notebookID.rawValue,
                title: String(localized: "Audio"),
                revision: 1,
                sourceFingerprint: assetID.rawValue,
                segments: [
                    RecognizedTextSegment(
                        text: "forged typed source",
                        source: .typedText
                    ),
                ],
                modifiedAt: Date(timeIntervalSince1970: 1)
            )
        )
        let transcript = makeTranscript(
            sessionID: sessionID,
            segments: [makeSegment(text: "authoritative transcript")]
        )
        let loader = TranscriptLoaderFake(results: [sessionID: .success(transcript)])
        let rebuilder = NotebookAudioTranscriptSearchRebuilder(
            sessionListing: AudioSessionListingFake(
                sessions: [AudioSessionDescriptor(id: sessionID, transcriptAssetID: assetID)]
            ),
            transcriptLoading: loader,
            searchIndexer: indexer
        )

        let needsRepair = await indexer.needsIndexing(
            notebookID: notebookID,
            session: AudioSessionDescriptor(id: sessionID, transcriptAssetID: assetID)
        )
        XCTAssertTrue(needsRepair)
        try await rebuilder.rebuild(notebookID: notebookID)

        let loadedSessionIDs = await loader.loadedSessionIDs()
        let repaired = await search.document(for: documentID)
        XCTAssertEqual(loadedSessionIDs, [sessionID])
        XCTAssertEqual(repaired?.segments.map(\.source), [.audioTranscript])
        XCTAssertEqual(repaired?.segments.first?.text, "authoritative transcript")
    }

    func testIndexerRejectsOversizedOrNonfiniteInitializerPayloadBeforeIndexing() async throws {
        let search = LocalSearchIndex()
        let indexer = NotebookAudioTranscriptSearchIndexer(searchIndex: search)
        let notebookID = NotebookID()
        let oversizedSessionID = AudioSessionID()
        let oversized = makeTranscript(
            sessionID: oversizedSessionID,
            segments: [
                makeSegment(
                    text: String(
                        repeating: "x",
                        count: AudioTranscriptDocument.maximumTextUTF8BytesPerSegment + 1
                    )
                ),
            ]
        )

        do {
            try await indexer.index(
                oversized,
                notebookID: notebookID,
                transcriptAssetID: digest("5")
            )
            XCTFail("An initializer-created oversized transcript must be rejected.")
        } catch let error as NotebookAudioTranscriptSearchError {
            XCTAssertEqual(error, .invalidTranscript)
        }

        let nonfiniteSessionID = AudioSessionID()
        let nonfinite = makeTranscript(
            sessionID: nonfiniteSessionID,
            segments: [
                AudioTranscriptSegment(
                    text: "invalid timing",
                    startTime: .infinity,
                    duration: 0.1,
                    confidence: .nan
                ),
            ]
        )
        do {
            try await indexer.index(
                nonfinite,
                notebookID: notebookID,
                transcriptAssetID: digest("6")
            )
            XCTFail("Nonfinite transcript timing and confidence must be rejected.")
        } catch let error as NotebookAudioTranscriptSearchError {
            XCTAssertEqual(error, .invalidTranscript)
        }

        let oversizedID = NotebookAudioTranscriptSearchIndexer.documentID(
            notebookID: notebookID,
            sessionID: oversizedSessionID
        )
        let nonfiniteID = NotebookAudioTranscriptSearchIndexer.documentID(
            notebookID: notebookID,
            sessionID: nonfiniteSessionID
        )
        let oversizedDocument = await search.document(for: oversizedID)
        let nonfiniteDocument = await search.document(for: nonfiniteID)
        XCTAssertNil(oversizedDocument)
        XCTAssertNil(nonfiniteDocument)
    }

    func testIndexerRejectsInvalidSourceFingerprint() async throws {
        let search = LocalSearchIndex()
        let indexer = NotebookAudioTranscriptSearchIndexer(searchIndex: search)
        do {
            try await indexer.index(
                makeTranscript(
                    sessionID: AudioSessionID(),
                    segments: [makeSegment(text: "must not index")]
                ),
                notebookID: NotebookID(),
                transcriptAssetID: AssetID("not-a-sha256-digest")
            )
            XCTFail("A non-content-addressed transcript fingerprint must be rejected.")
        } catch let error as NotebookAudioTranscriptSearchError {
            XCTAssertEqual(error, .invalidSourceFingerprint)
        }
        let indexedDocumentCount = await search.indexedDocumentCount()
        XCTAssertEqual(indexedDocumentCount, 0)
    }

    func testUnchangedFingerprintSkipsDurableTranscriptDecode() async throws {
        let search = LocalSearchIndex()
        let indexer = NotebookAudioTranscriptSearchIndexer(searchIndex: search)
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        let assetID = digest("e")
        let transcript = makeTranscript(
            sessionID: sessionID,
            segments: [makeSegment(text: "already indexed")]
        )
        try await indexer.index(
            transcript,
            notebookID: notebookID,
            transcriptAssetID: assetID
        )
        let session = AudioSessionDescriptor(id: sessionID, transcriptAssetID: assetID)
        let loader = TranscriptLoaderFake(results: [:])
        let rebuilder = NotebookAudioTranscriptSearchRebuilder(
            sessionListing: AudioSessionListingFake(sessions: [session]),
            transcriptLoading: loader,
            searchIndexer: indexer
        )

        try await rebuilder.rebuild(notebookID: notebookID)

        let loadedSessionIDs = await loader.loadedSessionIDs()
        let hits = await search.query("already indexed", notebookID: nil, limit: 10)
        XCTAssertEqual(loadedSessionIDs, [])
        XCTAssertEqual(hits.count, 1)
    }

    func testBadFirstTranscriptIsRemovedWhileLaterTranscriptStillIndexes() async throws {
        let search = LocalSearchIndex()
        let indexer = NotebookAudioTranscriptSearchIndexer(searchIndex: search)
        let notebookID = NotebookID()
        let badSessionID = AudioSessionID()
        let goodSessionID = AudioSessionID()

        try await indexer.index(
            makeTranscript(
                sessionID: badSessionID,
                segments: [makeSegment(text: "stale corrupt transcript")]
            ),
            notebookID: notebookID,
            transcriptAssetID: digest("f")
        )

        let badSession = AudioSessionDescriptor(
            id: badSessionID,
            transcriptAssetID: digest("1")
        )
        let goodAssetID = digest("2")
        let goodSession = AudioSessionDescriptor(
            id: goodSessionID,
            transcriptAssetID: goodAssetID
        )
        let goodTranscript = makeTranscript(
            sessionID: goodSessionID,
            segments: [makeSegment(text: "valid later transcript")]
        )
        let loader = TranscriptLoaderFake(results: [
            badSessionID: .failure(.corrupt),
            goodSessionID: .success(goodTranscript),
        ])
        let rebuilder = NotebookAudioTranscriptSearchRebuilder(
            sessionListing: AudioSessionListingFake(sessions: [badSession, goodSession]),
            transcriptLoading: loader,
            searchIndexer: indexer
        )

        do {
            try await rebuilder.rebuild(notebookID: notebookID)
            XCTFail("A partial rebuild should report its isolated failure")
        } catch let error as NotebookAudioTranscriptSearchRebuildError {
            guard case .partialFailure = error else {
                return XCTFail("Unexpected rebuild failure: \(error)")
            }
        }

        let staleHits = await search.query("stale corrupt", notebookID: nil, limit: 10)
        let validHits = await search.query("valid later", notebookID: nil, limit: 10)
        let loadedSessionIDs = await loader.loadedSessionIDs()
        XCTAssertEqual(staleHits.count, 0)
        XCTAssertEqual(validHits.count, 1)
        XCTAssertEqual(loadedSessionIDs, [badSessionID, goodSessionID])
    }

    func testMismatchedFirstSessionIsRemovedWhileLaterSessionStillIndexes() async throws {
        let search = LocalSearchIndex()
        let indexer = NotebookAudioTranscriptSearchIndexer(searchIndex: search)
        let notebookID = NotebookID()
        let badSessionID = AudioSessionID()
        let goodSessionID = AudioSessionID()
        let badAssetID = digest("7")
        let goodAssetID = digest("8")
        try await indexer.index(
            makeTranscript(
                sessionID: badSessionID,
                segments: [makeSegment(text: "stale mismatch text")]
            ),
            notebookID: notebookID,
            transcriptAssetID: digest("9")
        )
        let loader = TranscriptLoaderFake(results: [
            badSessionID: .success(makeTranscript(
                sessionID: AudioSessionID(),
                segments: [makeSegment(text: "wrong session payload")]
            )),
            goodSessionID: .success(makeTranscript(
                sessionID: goodSessionID,
                segments: [makeSegment(text: "good session after mismatch")]
            )),
        ])
        let rebuilder = NotebookAudioTranscriptSearchRebuilder(
            sessionListing: AudioSessionListingFake(sessions: [
                AudioSessionDescriptor(id: badSessionID, transcriptAssetID: badAssetID),
                AudioSessionDescriptor(id: goodSessionID, transcriptAssetID: goodAssetID),
            ]),
            transcriptLoading: loader,
            searchIndexer: indexer
        )

        do {
            try await rebuilder.rebuild(notebookID: notebookID)
            XCTFail("A mismatched durable transcript should report a partial rebuild failure.")
        } catch let error as NotebookAudioTranscriptSearchRebuildError {
            XCTAssertEqual(error, .partialFailure)
        }

        let staleHits = await search.query("stale", notebookID: nil, limit: 10)
        let goodHits = await search.query("good session", notebookID: nil, limit: 10)
        let loadedSessionIDs = await loader.loadedSessionIDs()
        XCTAssertTrue(staleHits.isEmpty)
        XCTAssertEqual(goodHits.count, 1)
        XCTAssertEqual(loadedSessionIDs, [badSessionID, goodSessionID])
    }

    func testReconcileRemovesSessionWhoseTranscriptReferenceDisappeared() async throws {
        let search = LocalSearchIndex()
        let indexer = NotebookAudioTranscriptSearchIndexer(searchIndex: search)
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        try await indexer.index(
            makeTranscript(
                sessionID: sessionID,
                segments: [makeSegment(text: "must disappear")]
            ),
            notebookID: notebookID,
            transcriptAssetID: digest("3")
        )

        try await indexer.reconcile(
            notebookID: notebookID,
            sessions: [AudioSessionDescriptor(id: sessionID, transcriptAssetID: nil)]
        )

        let hits = await search.query("must disappear", notebookID: nil, limit: 10)
        XCTAssertEqual(hits.count, 0)
    }

    private func makeTranscript(
        sessionID: AudioSessionID,
        generatedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        segments: [AudioTranscriptSegment]
    ) -> AudioTranscriptDocument {
        AudioTranscriptDocument(
            audioSessionID: sessionID,
            localeIdentifier: "en-US",
            provenance: .speechTranscriber,
            generatedAt: generatedAt,
            segments: segments
        )
    }

    private func makeSegment(
        text: String,
        startTime: TimeInterval = 0,
        pageID: PageID? = nil
    ) -> AudioTranscriptSegment {
        AudioTranscriptSegment(
            text: text,
            startTime: startTime,
            duration: 0.1,
            confidence: 0.95,
            pageID: pageID
        )
    }

    private func digest(_ character: Character) -> AssetID {
        AssetID(String(repeating: String(character), count: 64))
    }
}

private enum TranscriptLoaderFakeError: Error, Sendable {
    case corrupt
}

private actor TranscriptLoaderFake: NotebookAudioTranscriptLoading {
    private let results: [AudioSessionID: Result<NotebookAudioTranscriptPayload, TranscriptLoaderFakeError>]
    private var loaded: [AudioSessionID] = []

    init(results: [AudioSessionID: Result<NotebookAudioTranscriptPayload, TranscriptLoaderFakeError>]) {
        self.results = results
    }

    func loadTranscript(
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> NotebookAudioTranscriptPayload? {
        loaded.append(sessionID)
        guard let result = results[sessionID] else { return nil }
        return try result.get()
    }

    func loadedSessionIDs() -> [AudioSessionID] { loaded }
}

private actor AudioSessionListingFake: NotebookAudioSessionListing {
    let sessions: [AudioSessionDescriptor]

    init(sessions: [AudioSessionDescriptor]) {
        self.sessions = sessions
    }

    func listAudioSessions(notebookID: NotebookID) async throws -> [AudioSessionDescriptor] {
        sessions
    }
}
