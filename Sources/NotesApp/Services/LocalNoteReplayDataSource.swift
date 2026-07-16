import Foundation
import NotesCore

/// The narrow, read-only persistence surface required by Note Replay. Keeping this separate from
/// the editor store contract makes it impossible for replay preparation to invoke a write API.
struct NoteReplayStoreSession: Sendable {
    let token: NotebookExportSession
    let manifest: NotebookManifest
}

protocol NoteReplayStoreReading: Sendable {
    /// Opens one identity-validated, bounded manifest capability. Subsequent page/timeline reads
    /// use this capability instead of reparsing up to 16 MiB of manifest data on every cache miss.
    func beginReplayReadSession(notebookID: NotebookID) async throws
        -> NoteReplayStoreSession

    func loadReplayTimeline(
        session: NoteReplayStoreSession,
        sessionID: AudioSessionID,
        maximumMarkCount: Int
    ) async throws -> AudioTimelineDocument

    func loadReplayInk(
        session: NoteReplayStoreSession,
        pageID: PageID,
        maximumByteCount: Int
    ) async throws -> Data?

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

    func endReplayReadSession(_ session: NoteReplayStoreSession) async
}

enum LocalNoteReplayDataSourceError: Error, Equatable, Sendable {
    case invalidRequestedLimits
    case invalidNotebook
    case sessionNotFound(AudioSessionID)
    case invalidSession(AudioSessionID)
    case invalidTimeline(AudioSessionID)
    case replaySessionUnavailable
    case eligiblePageLimitExceeded(limit: Int)
    case inkByteLimitExceeded(limit: Int)
    case elementPayloadLimitExceeded(byteLimit: Int, elementLimit: Int)
}

extension NoteReplayStoreReading {
    func loadNoteReplayHistoryForReplay(
        session: NotebookExportSession,
        sessionID: AudioSessionID,
        maximumEventCount: Int
    ) async throws -> NoteReplayHistoryDocument? {
        _ = (session, sessionID, maximumEventCount)
        return nil
    }

    func loadNoteReplayInkPayloadForReplay(
        session: NotebookExportSession,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int
    ) async throws -> Data? {
        _ = (session, reference, maximumByteCount)
        throw LocalNoteReplayDataSourceError.replaySessionUnavailable
    }

    func loadNoteReplayElementsPayloadForReplay(
        session: NotebookExportSession,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int,
        maximumElementCount: Int
    ) async throws -> NotebookExportCanvasElements {
        _ = (session, reference, maximumByteCount, maximumElementCount)
        throw LocalNoteReplayDataSourceError.replaySessionUnavailable
    }
}

/// Main-actor adapter used by the editor-owned replay controller. Filesystem work remains on the
/// actor-isolated store/repository; this layer validates the returned values again before the
/// controller performs its own independent validation and rendering.
@MainActor
final class LocalNoteReplayDataSource: NoteReplayDataSource {
    private let store: any NoteReplayStoreReading
    private var activeStoreSession: NoteReplayStoreSession?

    init(store: any NoteReplayStoreReading) {
        self.store = store
    }

    func loadReplaySession(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        maximumTimelineMarkCount: Int,
        maximumEligiblePageCount: Int,
        maximumHistoryEventCount: Int = NoteReplayHistoryLimits.maximumEventCount
    ) async throws -> NoteReplaySessionSnapshot {
        guard (1...NotebookReplayReadLimits.maximumTimelineMarks)
            .contains(maximumTimelineMarkCount),
              (1...NoteReplayNavigationPlanner.maximumEligiblePageCount)
            .contains(maximumEligiblePageCount),
              (1...NoteReplayHistoryLimits.maximumEventCount)
            .contains(maximumHistoryEventCount) else {
            throw LocalNoteReplayDataSourceError.invalidRequestedLimits
        }

        let candidate = try await store.beginReplayReadSession(notebookID: notebookID)
        do {
            try Task.checkCancellation()
            let manifest = candidate.manifest
            guard candidate.token.notebookID == notebookID,
                  manifest.id == notebookID,
                  manifest.pages.count <= NotebookExportReadLimits.maximumNotebookPageCount,
                  manifest.audioSessions.count
                    <= NotebookExportReadLimits.maximumManifestAudioSessionCount,
                  Set(manifest.pages.map(\.id)).count == manifest.pages.count,
                  Set(manifest.audioSessions.map(\.id)).count
                    == manifest.audioSessions.count else {
                throw LocalNoteReplayDataSourceError.invalidNotebook
            }
            guard let descriptor = manifest.audioSessions.first(where: { $0.id == sessionID }) else {
                throw LocalNoteReplayDataSourceError.sessionNotFound(sessionID)
            }
            guard Self.validDescriptorEnvelope(descriptor) else {
                throw LocalNoteReplayDataSourceError.invalidSession(sessionID)
            }

            // Preserve the exact caller limit at the storage boundary. FileNotebookRepository
            // applies it under the independent 100k hard ceiling and revalidates capability
            // identity before and after the no-follow timeline read.
            let timeline = try await store.loadReplayTimeline(
                session: candidate,
                sessionID: sessionID,
                maximumMarkCount: maximumTimelineMarkCount
            )
            try Task.checkCancellation()
            guard descriptor.id == sessionID,
                  timeline.audioSessionID == sessionID,
                  timeline.marks.count <= maximumTimelineMarkCount,
                  timeline.marks.count <= NotebookReplayReadLimits.maximumTimelineMarks,
                  NoteReplaySessionTimingResolver.resolve(
                    session: descriptor,
                    timeline: timeline
                  ) != nil else {
                throw LocalNoteReplayDataSourceError.invalidTimeline(sessionID)
            }

            // Do not filter timeline marks. Marks targeting deleted or structured-content pages
            // must still participate in complete-timeline validation before navigation projects
            // them onto the currently eligible pages below.
            let eligiblePageIDs = manifest.pages.compactMap { page -> PageID? in
                switch page.kind {
                case .notebook, .whiteboard, .importedDocument:
                    page.id
                case .textDocument, .studySet:
                    nil
                }
            }
            guard eligiblePageIDs.count <= maximumEligiblePageCount else {
                throw LocalNoteReplayDataSourceError.eligiblePageLimitExceeded(
                    limit: maximumEligiblePageCount
                )
            }

            let historyResult: (history: NoteReplayHistoryDocument?, unavailable: Bool)
            if descriptor.replayFilename == nil {
                historyResult = (nil, false)
            } else {
                do {
                    let loadedHistory = try await store.loadNoteReplayHistoryForReplay(
                        session: candidate.token,
                        sessionID: sessionID,
                        maximumEventCount: maximumHistoryEventCount
                    )
                    try Task.checkCancellation()
                    if let loadedHistory,
                       let expectedEventCount = descriptor.replayEventCount,
                       loadedHistory.events.count == expectedEventCount,
                       Self.validHistoryEnvelope(
                        loadedHistory,
                        sessionID: sessionID,
                        maximumEventCount: maximumHistoryEventCount,
                        duration: descriptor.durationSeconds
                       ) {
                        historyResult = (loadedHistory, false)
                    } else {
                        historyResult = (nil, true)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    // Preserve a distinct marker instead of silently treating a
                    // referenced-but-unreadable history as a legacy recording.
                    // The controller fails startup closed on this value.
                    historyResult = (nil, true)
                }
            }

            let previousSession = activeStoreSession
            activeStoreSession = candidate
            if let previousSession {
                await store.endReplayReadSession(previousSession)
            }
            return NoteReplaySessionSnapshot(
                descriptor: descriptor,
                timeline: timeline,
                eligiblePageIDs: eligiblePageIDs,
                history: historyResult.history,
                historyUnavailable: historyResult.unavailable
            )
        } catch {
            await store.endReplayReadSession(candidate)
            throw error
        }
    }

    func loadReplayInk(
        notebookID: NotebookID,
        pageID: PageID,
        maximumByteCount: Int
    ) async throws -> Data? {
        guard (1...NotebookReplayReadLimits.maximumInkBytes)
            .contains(maximumByteCount) else {
            throw LocalNoteReplayDataSourceError.invalidRequestedLimits
        }

        // Forward the exact value; never widen it to the repository or export ceiling.
        guard let activeStoreSession,
              activeStoreSession.token.notebookID == notebookID else {
            throw LocalNoteReplayDataSourceError.replaySessionUnavailable
        }
        let data = try await store.loadReplayInk(
            session: activeStoreSession,
            pageID: pageID,
            maximumByteCount: maximumByteCount
        )
        try Task.checkCancellation()
        guard let data else { return nil }
        guard data.count <= maximumByteCount,
              data.count <= NotebookReplayReadLimits.maximumInkBytes else {
            throw LocalNoteReplayDataSourceError.inkByteLimitExceeded(
                limit: maximumByteCount
            )
        }
        return data
    }

    func loadReplayInkPayload(
        notebookID: NotebookID,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int
    ) async throws -> Data? {
        guard (1...NoteReplayHistoryLimits.maximumInkPayloadBytes)
            .contains(maximumByteCount) else {
            throw LocalNoteReplayDataSourceError.invalidRequestedLimits
        }
        guard reference.byteCount > 0,
              reference.byteCount <= maximumByteCount,
              let activeStoreSession,
              activeStoreSession.token.notebookID == notebookID else {
            throw LocalNoteReplayDataSourceError.replaySessionUnavailable
        }
        let data = try await store.loadNoteReplayInkPayloadForReplay(
            session: activeStoreSession.token,
            reference: reference,
            maximumByteCount: maximumByteCount
        )
        try Task.checkCancellation()
        guard let data else { return nil }
        guard data.count == reference.byteCount,
              data.count <= maximumByteCount,
              data.count <= NoteReplayHistoryLimits.maximumInkPayloadBytes else {
            throw LocalNoteReplayDataSourceError.inkByteLimitExceeded(
                limit: maximumByteCount
            )
        }
        return data
    }

    func loadReplayElementsPayload(
        notebookID: NotebookID,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int,
        maximumElementCount: Int
    ) async throws -> NotebookExportCanvasElements {
        guard (1...NoteReplayHistoryLimits.maximumElementPayloadBytes)
                .contains(maximumByteCount),
              (1...NoteReplayHistoryLimits.maximumElementCountPerSnapshot)
                .contains(maximumElementCount),
              reference.byteCount > 0,
              reference.byteCount <= maximumByteCount else {
            throw LocalNoteReplayDataSourceError.invalidRequestedLimits
        }
        guard let activeStoreSession,
              activeStoreSession.token.notebookID == notebookID else {
            throw LocalNoteReplayDataSourceError.replaySessionUnavailable
        }
        let loaded = try await store.loadNoteReplayElementsPayloadForReplay(
            session: activeStoreSession.token,
            reference: reference,
            maximumByteCount: maximumByteCount,
            maximumElementCount: maximumElementCount
        )
        try Task.checkCancellation()
        guard loaded.encodedByteCount == reference.byteCount,
              loaded.encodedByteCount <= maximumByteCount,
              loaded.elements.count <= maximumElementCount else {
            throw LocalNoteReplayDataSourceError.elementPayloadLimitExceeded(
                byteLimit: maximumByteCount,
                elementLimit: maximumElementCount
            )
        }
        return loaded
    }

    func endReplaySession() async {
        guard let activeStoreSession else { return }
        self.activeStoreSession = nil
        await store.endReplayReadSession(activeStoreSession)
    }

    private static func validDescriptorEnvelope(
        _ descriptor: AudioSessionDescriptor
    ) -> Bool {
        let createdAt = descriptor.createdAt.timeIntervalSinceReferenceDate
        let modifiedAt = descriptor.modifiedAt.timeIntervalSinceReferenceDate
        let replayFieldsPresent = [
            descriptor.replayFilename != nil,
            descriptor.replayByteCount != nil,
            descriptor.replaySHA256 != nil,
            descriptor.replayEventCount != nil,
        ]
        let validReplayEnvelope: Bool
        if replayFieldsPresent.allSatisfy({ !$0 }) {
            validReplayEnvelope = descriptor.schemaVersion < 3
        } else if replayFieldsPresent.allSatisfy({ $0 }),
                  let filename = descriptor.replayFilename,
                  let byteCount = descriptor.replayByteCount,
                  let digest = descriptor.replaySHA256,
                  let eventCount = descriptor.replayEventCount {
            validReplayEnvelope = descriptor.schemaVersion == 3
                && filename == "\(descriptor.id.description).replay.json"
                && byteCount > 0
                && byteCount <= Int64(NoteReplayHistoryLimits.maximumIndexBytes)
                && isLowercaseSHA256(digest)
                && (0...NoteReplayHistoryLimits.maximumEventCount).contains(eventCount)
        } else {
            validReplayEnvelope = false
        }
        return (1...AudioSessionDescriptor.currentSchemaVersion)
            .contains(descriptor.schemaVersion)
            && createdAt.isFinite
            && modifiedAt.isFinite
            && modifiedAt >= createdAt
            && (descriptor.recordingStartedAt.map {
                $0.timeIntervalSinceReferenceDate.isFinite
            } ?? true)
            && descriptor.durationSeconds.isFinite
            && descriptor.durationSeconds > 0
            && descriptor.durationSeconds <= NoteReplaySessionPolicy.maximumDuration
            && validReplayEnvelope
    }

    private static func validHistoryEnvelope(
        _ history: NoteReplayHistoryDocument,
        sessionID: AudioSessionID,
        maximumEventCount: Int,
        duration: TimeInterval
    ) -> Bool {
        guard history.schemaVersion == NoteReplayHistoryDocument.currentSchemaVersion,
              history.audioSessionID == sessionID,
              history.events.count <= maximumEventCount,
              history.events.count <= NoteReplayHistoryLimits.maximumEventCount,
              history.sealedAt.timeIntervalSinceReferenceDate.isFinite,
              Set(history.events.map(\.id)).count == history.events.count,
              Set(history.events.map(\.operationID)).count
                == history.events.count else {
            return false
        }
        var previousSequence = -1
        var previousEventTime: TimeInterval?
        var countsByPage: [PageID: Int] = [:]
        var lastTimeByPage: [PageID: TimeInterval] = [:]
        var terminalPages: Set<PageID> = []
        for (eventIndex, event) in history.events.enumerated() {
            let isFirstPageEvent = countsByPage[event.pageID] == nil
            guard event.sequence == eventIndex,
                  event.sequence > previousSequence,
                  event.timeSeconds.isFinite,
                  event.timeSeconds >= (previousEventTime ?? 0),
                  event.timeSeconds >= 0,
                  event.timeSeconds <= duration,
                  event.kind != .terminal || event.timeSeconds == duration,
                  event.timeSeconds >= (lastTimeByPage[event.pageID] ?? 0),
                  isFirstPageEvent == (event.kind == .baseline),
                  !terminalPages.contains(event.pageID),
                  (event.inkPayload.map {
                    $0.byteCount > 0
                        && $0.byteCount
                            <= NoteReplayHistoryLimits.maximumInkPayloadBytes
                        && $0.assetID.isSHA256Digest
                  } ?? true),
                  event.elementsPayload.byteCount > 0,
                  event.elementsPayload.byteCount
                    <= NoteReplayHistoryLimits.maximumElementPayloadBytes,
                  event.elementsPayload.assetID.isSHA256Digest else {
                return false
            }
            previousSequence = event.sequence
            previousEventTime = event.timeSeconds
            let pageCount = (countsByPage[event.pageID] ?? 0) + 1
            guard pageCount <= NoteReplayHistoryLimits.maximumEventsPerPage else {
                return false
            }
            countsByPage[event.pageID] = pageCount
            lastTimeByPage[event.pageID] = event.timeSeconds
            if event.kind == .terminal {
                terminalPages.insert(event.pageID)
            }
        }
        if countsByPage.isEmpty { return history.events.isEmpty }
        return terminalPages == Set(countsByPage.keys)
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains(Int($0.value))
                || (97...102).contains(Int($0.value))
        }
    }
}
