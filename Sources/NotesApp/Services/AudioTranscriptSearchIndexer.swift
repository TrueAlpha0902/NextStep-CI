import CryptoKit
import Foundation
import NotesCore
import NotesServices

protocol NotebookAudioTranscriptSearchIndexing: Sendable {
    func index(
        _ transcript: NotebookAudioTranscriptPayload,
        notebookID: NotebookID,
        transcriptAssetID: AssetID
    ) async throws

    func needsIndexing(
        notebookID: NotebookID,
        session: AudioSessionDescriptor
    ) async -> Bool

    func remove(notebookID: NotebookID, sessionID: AudioSessionID) async throws

    func reconcile(
        notebookID: NotebookID,
        sessions: [AudioSessionDescriptor]
    ) async throws
}

enum NotebookAudioTranscriptSearchRebuildError: LocalizedError, Equatable, Sendable {
    case partialFailure

    var errorDescription: String? {
        switch self {
        case .partialFailure:
            String(localized: "Some saved transcripts could not be added to local search.")
        }
    }
}

enum NotebookAudioTranscriptSearchError: Error, Equatable, Sendable {
    case invalidSourceFingerprint
    case invalidTranscript
}

/// Reconciles every saved session at launch. Content-addressed fingerprints
/// avoid decoding unchanged transcript assets, while failures are isolated so
/// one corrupt session cannot prevent later valid sessions from being indexed.
actor NotebookAudioTranscriptSearchRebuilder {
    private let sessionListing: any NotebookAudioSessionListing
    private let transcriptLoading: any NotebookAudioTranscriptLoading
    private let searchIndexer: any NotebookAudioTranscriptSearchIndexing

    init(
        sessionListing: any NotebookAudioSessionListing,
        transcriptLoading: any NotebookAudioTranscriptLoading,
        searchIndexer: any NotebookAudioTranscriptSearchIndexing
    ) {
        self.sessionListing = sessionListing
        self.transcriptLoading = transcriptLoading
        self.searchIndexer = searchIndexer
    }

    func rebuild(notebookID: NotebookID) async throws {
        let sessions = try await sessionListing.listAudioSessions(notebookID: notebookID)
        try await searchIndexer.reconcile(notebookID: notebookID, sessions: sessions)
        var encounteredFailure = false

        for session in sessions where session.transcriptAssetID != nil {
            do {
                try Task.checkCancellation()
                guard await searchIndexer.needsIndexing(
                    notebookID: notebookID,
                    session: session
                ) else { continue }
                guard let transcriptAssetID = session.transcriptAssetID,
                      let transcript = try await transcriptLoading.loadTranscript(
                          notebookID: notebookID,
                          sessionID: session.id
                      ) else {
                    throw NotebookAudioCoordinatorError.incompleteAudioMaterialization
                }
                guard transcript.audioSessionID == session.id else {
                    throw NotebookAudioTranscriptSearchError.invalidTranscript
                }
                try await searchIndexer.index(
                    transcript,
                    notebookID: notebookID,
                    transcriptAssetID: transcriptAssetID
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try? await searchIndexer.remove(
                    notebookID: notebookID,
                    sessionID: session.id
                )
                encounteredFailure = true
            }
        }

        if encounteredFailure {
            throw NotebookAudioTranscriptSearchRebuildError.partialFailure
        }
    }
}

/// Converts durable audio transcripts into derived, local-only search records.
/// The document identifier is namespaced across both notebook and audio-session
/// identifiers so it cannot alias the raw UUID used by a notebook or page index.
actor NotebookAudioTranscriptSearchIndexer: NotebookAudioTranscriptSearchIndexing {
    private enum Constants {
        static let documentNamespace = "com.speci.localnotes.search.audio-transcript.v1"
        static let maximumSearchSegments = 10_000
        static let maximumIndexedTextUTF8Bytes =
            AudioTranscriptDocument.maximumTotalTextUTF8Bytes
            + AudioTranscriptDocument.maximumSegmentCount
    }

    private let searchIndex: any SearchIndexing

    init(searchIndex: any SearchIndexing) {
        self.searchIndex = searchIndex
    }

    func index(
        _ transcript: NotebookAudioTranscriptPayload,
        notebookID: NotebookID,
        transcriptAssetID: AssetID
    ) async throws {
        try Task.checkCancellation()
        let documentID = Self.documentID(
            notebookID: notebookID,
            sessionID: transcript.audioSessionID
        )
        try Self.validate(
            transcript,
            transcriptAssetID: transcriptAssetID
        )
        guard !transcript.segments.isEmpty else {
            try await searchIndex.remove(documentID: documentID)
            return
        }

        let document = try Self.document(
            from: transcript,
            notebookID: notebookID,
            documentID: documentID,
            sourceFingerprint: transcriptAssetID.rawValue
        )
        try await upsertLatest(document)
    }

    func needsIndexing(
        notebookID: NotebookID,
        session: AudioSessionDescriptor
    ) async -> Bool {
        guard let transcriptAssetID = session.transcriptAssetID else { return false }
        let id = Self.documentID(notebookID: notebookID, sessionID: session.id)
        guard let existing = await searchIndex.document(for: id) else { return true }
        return !Self.isExpectedStoredShape(
            existing,
            documentID: id,
            notebookID: notebookID,
            transcriptAssetID: transcriptAssetID
        )
    }

    func remove(notebookID: NotebookID, sessionID: AudioSessionID) async throws {
        try await searchIndex.remove(
            documentID: Self.documentID(notebookID: notebookID, sessionID: sessionID)
        )
    }

    func reconcile(
        notebookID: NotebookID,
        sessions: [AudioSessionDescriptor]
    ) async throws {
        let retainedIDs = Set(sessions.compactMap { session -> UUID? in
            guard let transcriptAssetID = session.transcriptAssetID,
                  transcriptAssetID.isSHA256Digest else { return nil }
            return Self.documentID(notebookID: notebookID, sessionID: session.id)
        })
        try Task.checkCancellation()
        try await searchIndex.retainDocuments(
            notebookID: notebookID.rawValue,
            source: .audioTranscript,
            documentIDs: retainedIDs
        )
    }

    private static func document(
        from transcript: NotebookAudioTranscriptPayload,
        notebookID: NotebookID,
        documentID: UUID,
        sourceFingerprint: String
    ) throws -> SearchIndexDocument {
        let segments = try pageSearchSegments(from: transcript, documentID: documentID)
        return SearchIndexDocument(
            id: documentID,
            notebookID: notebookID.rawValue,
            pageID: segments.first(where: { $0.pageID != nil })?.pageID,
            title: String(localized: "Audio"),
            revision: revision(for: transcript.generatedAt),
            sourceFingerprint: sourceFingerprint,
            segments: segments,
            modifiedAt: transcript.generatedAt
        )
    }

    /// One search segment represents one page. This keeps the matched segment's
    /// navigation target exact even when a recording crosses many pages.
    private static func pageSearchSegments(
        from transcript: NotebookAudioTranscriptPayload,
        documentID: UUID
    ) throws -> [RecognizedTextSegment] {
        var order: [PageID?] = []
        var grouped: [PageID?: [NotebookAudioTranscriptSegmentMapping]] = [:]
        for (index, segment) in transcript.segments.enumerated() {
            if index.isMultiple(of: 512) { try Task.checkCancellation() }
            if grouped[segment.pageID] == nil {
                order.append(segment.pageID)
                guard order.count <= Constants.maximumSearchSegments else {
                    throw SearchIndexError.documentTooLarge(documentID)
                }
                grouped[segment.pageID] = []
            }
            grouped[segment.pageID, default: []].append(segment)
        }
        return order.compactMap { pageID in
            guard let segments = grouped[pageID], !segments.isEmpty else { return nil }
            return searchSegment(from: segments, locale: transcript.localeIdentifier)
        }
    }

    private static func searchSegment(
        from segments: [NotebookAudioTranscriptSegmentMapping],
        locale: String
    ) -> RecognizedTextSegment {
        let first = segments[0]
        let finiteConfidences = segments.map(\.confidence).filter(\.isFinite)
        let confidence = finiteConfidences.isEmpty
            ? 0.25
            : finiteConfidences.reduce(0, +) / Double(finiteConfidences.count)
        return RecognizedTextSegment(
            id: first.id,
            text: segments.map(\.text).joined(separator: "\n"),
            confidence: min(max(confidence, 0), 1),
            pageID: segments.compactMap(\.pageID).first?.rawValue,
            source: .audioTranscript,
            localeIdentifier: locale,
            startTime: first.startTime
        )
    }

    private static func revision(for date: Date) -> Int {
        let microseconds = date.timeIntervalSince1970 * 1_000_000
        guard microseconds.isFinite else { return 0 }
        guard microseconds > 0 else { return 0 }
        guard microseconds < Double(Int.max) else { return Int.max - 1 }
        return Int(microseconds)
    }

    private func upsertLatest(_ baseDocument: SearchIndexDocument) async throws {
        var candidate = baseDocument
        for _ in 0..<4 {
            try Task.checkCancellation()
            if let existing = await searchIndex.document(for: baseDocument.id) {
                if Self.hasSamePayload(existing, baseDocument) { return }
                guard existing.revision < Int.max else {
                    throw SearchIndexError.revisionConflict(existing.id)
                }
                candidate.revision = max(baseDocument.revision, existing.revision + 1)
            } else {
                candidate.revision = baseDocument.revision
            }

            do {
                try await searchIndex.upsert(candidate)
            } catch SearchIndexError.revisionConflict(_) {
                continue
            }
            guard let committed = await searchIndex.document(for: baseDocument.id) else {
                continue
            }
            if Self.hasSamePayload(committed, baseDocument) { return }
        }
        throw SearchIndexError.revisionConflict(baseDocument.id)
    }

    private static func validate(
        _ transcript: NotebookAudioTranscriptPayload,
        transcriptAssetID: AssetID
    ) throws {
        guard transcriptAssetID.isSHA256Digest else {
            throw NotebookAudioTranscriptSearchError.invalidSourceFingerprint
        }
        guard transcript.schemaVersion == AudioTranscriptDocument.currentSchemaVersion,
              transcript.generatedAt.timeIntervalSinceReferenceDate.isFinite,
              !transcript.localeIdentifier.isEmpty,
              transcript.localeIdentifier.utf8.count <= AudioTranscriptDocument.maximumLocaleUTF8Bytes,
              !transcript.localeIdentifier.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              transcript.segments.count <= AudioTranscriptDocument.maximumSegmentCount else {
            throw NotebookAudioTranscriptSearchError.invalidTranscript
        }

        var totalTextBytes = 0
        var segmentIDs = Set<UUID>()
        segmentIDs.reserveCapacity(transcript.segments.count)
        for (index, segment) in transcript.segments.enumerated() {
            if index.isMultiple(of: 512) { try Task.checkCancellation() }
            let textBytes = segment.text.utf8.count
            guard textBytes <= AudioTranscriptDocument.maximumTextUTF8BytesPerSegment,
                  totalTextBytes <= AudioTranscriptDocument.maximumTotalTextUTF8Bytes - textBytes,
                  segmentIDs.insert(segment.id).inserted,
                  segment.startTime.isFinite,
                  segment.startTime >= 0,
                  segment.duration.isFinite,
                  segment.duration >= 0,
                  (segment.startTime + segment.duration).isFinite,
                  segment.confidence.isFinite,
                  (0 ... 1).contains(segment.confidence) else {
                throw NotebookAudioTranscriptSearchError.invalidTranscript
            }
            totalTextBytes += textBytes
        }
    }

    private static func isExpectedStoredShape(
        _ document: SearchIndexDocument,
        documentID: UUID,
        notebookID: NotebookID,
        transcriptAssetID: AssetID
    ) -> Bool {
        guard transcriptAssetID.isSHA256Digest,
              document.id == documentID,
              document.notebookID == notebookID.rawValue,
              document.title == String(localized: "Audio"),
              document.sourceFingerprint == transcriptAssetID.rawValue,
              document.revision >= 0,
              document.modifiedAt.timeIntervalSinceReferenceDate.isFinite,
              !document.segments.isEmpty,
              document.segments.count <= Constants.maximumSearchSegments,
              document.pageID == document.segments.first(where: { $0.pageID != nil })?.pageID else {
            return false
        }

        var pageIDs = Set<UUID?>()
        var segmentIDs = Set<UUID>()
        var localeIdentifier: String?
        var totalTextBytes = 0
        for segment in document.segments {
            let textBytes = segment.text.utf8.count
            guard segment.source == .audioTranscript,
                  segment.bounds == nil,
                  segment.confidence.isFinite,
                  (0 ... 1).contains(segment.confidence),
                  segment.startTime?.isFinite == true,
                  (segment.startTime ?? -1) >= 0,
                  textBytes <= Constants.maximumIndexedTextUTF8Bytes,
                  totalTextBytes <= Constants.maximumIndexedTextUTF8Bytes - textBytes,
                  segmentIDs.insert(segment.id).inserted,
                  pageIDs.insert(segment.pageID).inserted,
                  let locale = segment.localeIdentifier,
                  !locale.isEmpty,
                  locale.utf8.count <= AudioTranscriptDocument.maximumLocaleUTF8Bytes,
                  !locale.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                return false
            }
            totalTextBytes += textBytes
            if let localeIdentifier, localeIdentifier != locale { return false }
            localeIdentifier = locale
        }
        return true
    }

    private static func hasSamePayload(
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

    static func documentID(notebookID: NotebookID, sessionID: AudioSessionID) -> UUID {
        var material = Data(Constants.documentNamespace.utf8)
        Swift.withUnsafeBytes(of: notebookID.rawValue.uuid) { material.append(contentsOf: $0) }
        Swift.withUnsafeBytes(of: sessionID.rawValue.uuid) { material.append(contentsOf: $0) }
        var bytes = Array(SHA256.hash(data: material).prefix(16))
        // UUID version 8 denotes an application-defined, name-derived UUID.
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
