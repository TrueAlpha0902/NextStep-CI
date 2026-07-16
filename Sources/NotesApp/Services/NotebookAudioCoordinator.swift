import CryptoKit
import Darwin
import Foundation
import NotesCore
import NotesServices

typealias NotebookAudioTranscriptProvenance = AudioTranscriptProvenance
typealias NotebookAudioTranscriptSegmentMapping = AudioTranscriptSegment
typealias NotebookAudioTranscriptPayload = AudioTranscriptDocument

struct NotebookAudioTranscriptionResult: Sendable {
    let payload: NotebookAudioTranscriptPayload
    let savedDescriptor: AudioSessionDescriptor
}

/// One immutable editor state captured at a semantic drawing/element boundary.
/// The coordinator content-addresses both layers and reuses unchanged payloads.
struct NotebookAudioReplayPageSnapshot: Equatable, Sendable {
    let pageID: PageID
    let inkData: Data?
    let elements: [CanvasElement]

    init(pageID: PageID, inkData: Data?, elements: [CanvasElement]) {
        self.pageID = pageID
        self.inkData = inkData
        self.elements = elements
    }
}

struct NotebookAudioRecordingPreparation: Sendable {
    let canStart: Bool
    let replaySnapshot: NotebookAudioReplayPageSnapshot?

    static let unavailable = NotebookAudioRecordingPreparation(
        canStart: false,
        replaySnapshot: nil
    )

    static func ready(
        replaySnapshot: NotebookAudioReplayPageSnapshot?
    ) -> NotebookAudioRecordingPreparation {
        NotebookAudioRecordingPreparation(
            canStart: true,
            replaySnapshot: replaySnapshot
        )
    }
}

/// Opens the canonical parent without following a final parent symlink, then
/// opens the item relative to that descriptor. The App's canonical working
/// directory lives inside its private container; `openat` closes the mutable
/// final-component validate/open race without requiring access to filesystem
/// ancestors that the iOS sandbox intentionally hides.
private func openAbsolutePathWithoutFollowingLinks(
    at url: URL,
    finalFlags: Int32
) -> Int32 {
    guard url.isFileURL else { return -1 }
    let standardized = url.standardizedFileURL
    let itemName = standardized.lastPathComponent
    guard !itemName.isEmpty, itemName != ".", itemName != ".." else {
        return -1
    }
    let parent = standardized.deletingLastPathComponent()
    let directoryDescriptor = parent.path.withCString {
        Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    }
    guard directoryDescriptor >= 0 else { return -1 }
    defer { _ = Darwin.close(directoryDescriptor) }
    return itemName.withCString {
        Darwin.openat(directoryDescriptor, $0, finalFlags)
    }
}

private enum NotebookAudioPersistenceRollbackFenceError: Error, Sendable {
    case previousAttemptFailed
}

/// Gives every durable persistence receipt one rollback authority. Cancellation
/// and a stale persistence completion may observe the same receipt in either
/// order; both await the same operation instead of deleting the session twice.
private actor NotebookAudioPersistenceRollbackFence {
    private enum State {
        case ready(@Sendable () async throws -> Void)
        case running(Task<Void, Error>)
        case succeeded
        case failed
    }

    private var state: State

    init(operation: @escaping @Sendable () async throws -> Void) {
        state = .ready(operation)
    }

    func rollback() async throws {
        let task: Task<Void, Error>
        switch state {
        case let .ready(operation):
            task = Task.detached {
                try await operation()
            }
            state = .running(task)
        case let .running(existingTask):
            task = existingTask
        case .succeeded:
            return
        case .failed:
            throw NotebookAudioPersistenceRollbackFenceError.previousAttemptFailed
        }

        do {
            try await task.value
            state = .succeeded
        } catch {
            state = .failed
            throw error
        }
    }
}

/// The App-side persistence boundary for notebook audio.
///
/// Recording ingestion accepts a file URL so neither the coordinator nor its
/// persistence adapter has to materialize a potentially large recording.
struct NotebookAudioPersistenceReceipt: Sendable {
    let descriptor: AudioSessionDescriptor

    private let rollbackFence: NotebookAudioPersistenceRollbackFence

    init(
        descriptor: AudioSessionDescriptor,
        rollbackOperation: @escaping @Sendable () async throws -> Void
    ) {
        self.descriptor = descriptor
        rollbackFence = NotebookAudioPersistenceRollbackFence(
            operation: rollbackOperation
        )
    }

    func rollback() async throws {
        try await rollbackFence.rollback()
    }
}

protocol NotebookAudioTranscriptLoading: Sendable {
    func loadTranscript(
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> NotebookAudioTranscriptPayload?
}

protocol NotebookAudioPersisting: NotebookAudioTranscriptLoading, Sendable {
    func persistRecordedM4A(
        at fileURL: URL,
        maximumByteCount: Int64,
        timeline: NotesCore.AudioTimelineDocument,
        notebookID: NotebookID,
        durationSeconds: Double,
        recordingStartedAt: Date,
        transcriptAssetID: AssetID?
    ) async throws -> NotebookAudioPersistenceReceipt

    /// Persists the sealed, immutable replay history in the same repository
    /// transaction as the M4A, timeline, and descriptor.
    func persistRecordedM4A(
        at fileURL: URL,
        maximumByteCount: Int64,
        timeline: NotesCore.AudioTimelineDocument,
        replayHistory: NoteReplayCaptureBundle,
        notebookID: NotebookID,
        durationSeconds: Double,
        recordingStartedAt: Date,
        transcriptAssetID: AssetID?
    ) async throws -> NotebookAudioPersistenceReceipt

    func descriptor(
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> AudioSessionDescriptor

    func loadAudioChunk(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        offset: Int64,
        maximumByteCount: Int
    ) async throws -> Data

    func loadTimeline(
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> NotesCore.AudioTimelineDocument

    func saveTranscript(
        _ transcript: NotebookAudioTranscriptPayload,
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> AudioSessionDescriptor

}

/// Lists durable sessions independently from the coordinator's active state so
/// reopening an editor can reconstruct its audio library from the manifest.
protocol NotebookAudioSessionListing: Sendable {
    func listAudioSessions(notebookID: NotebookID) async throws -> [AudioSessionDescriptor]
}

/// Bridges the URL-oriented App boundary to Core's streaming ingest. Core opens
/// the regular, single-link file without following its final component, then
/// copies and hashes it incrementally as part of the atomic session transaction.
actor NotebookRepositoryAudioPersistence: NotebookAudioPersisting {
    private let repository: any NotebookRepository

    init(repository: any NotebookRepository) {
        self.repository = repository
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
        try Task.checkCancellation()
        guard maximumByteCount > 0,
              maximumByteCount <= NotebookAudioCoordinatorConfiguration.defaultMaximumRecordingBytes else {
            throw NotebookAudioCoordinatorError.invalidConfiguration
        }
        guard
              fileURL.isFileURL,
              fileURL.pathExtension.caseInsensitiveCompare("m4a") == .orderedSame else {
            throw NotebookAudioCoordinatorError.unsafeTemporaryFile
        }
        try Task.checkCancellation()
        let descriptor = try await repository.addRecordedAudioSession(
            from: fileURL,
            maximumByteCount: maximumByteCount,
            timeline: timeline,
            notebookID: notebookID,
            durationSeconds: durationSeconds,
            recordingStartedAt: recordingStartedAt,
            transcriptAssetID: transcriptAssetID
        )
        let repository = self.repository
        return NotebookAudioPersistenceReceipt(descriptor: descriptor) {
            try await repository.deleteAudioSession(
                notebookID: notebookID,
                sessionID: timeline.audioSessionID
            )
        }
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
        try Task.checkCancellation()
        guard maximumByteCount > 0,
              maximumByteCount
                <= NotebookAudioCoordinatorConfiguration.defaultMaximumRecordingBytes else {
            throw NotebookAudioCoordinatorError.invalidConfiguration
        }
        guard fileURL.isFileURL,
              fileURL.pathExtension.caseInsensitiveCompare("m4a") == .orderedSame else {
            throw NotebookAudioCoordinatorError.unsafeTemporaryFile
        }
        let descriptor = try await repository.addRecordedAudioSession(
            from: fileURL,
            maximumByteCount: maximumByteCount,
            timeline: timeline,
            replayHistory: replayHistory,
            notebookID: notebookID,
            durationSeconds: durationSeconds,
            recordingStartedAt: recordingStartedAt,
            transcriptAssetID: transcriptAssetID
        )
        let repository = self.repository
        return NotebookAudioPersistenceReceipt(descriptor: descriptor) {
            try await repository.deleteAudioSession(
                notebookID: notebookID,
                sessionID: timeline.audioSessionID
            )
        }
    }

    func descriptor(
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> AudioSessionDescriptor {
        let manifest = try await repository.openNotebook(id: notebookID)
        guard let descriptor = manifest.audioSessions.first(where: { $0.id == sessionID }) else {
            throw NotebookRepositoryError.audioSessionNotFound(sessionID)
        }
        return descriptor
    }

    func loadAudioChunk(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        offset: Int64,
        maximumByteCount: Int
    ) async throws -> Data {
        try await repository.loadAudioChunk(
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
        try await repository.loadAudioTimeline(notebookID: notebookID, sessionID: sessionID)
    }

    func saveTranscript(
        _ transcript: NotebookAudioTranscriptPayload,
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> AudioSessionDescriptor {
        try await repository.saveAudioTranscript(
            transcript,
            notebookID: notebookID,
            sessionID: sessionID
        )
    }

    func loadTranscript(
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> NotebookAudioTranscriptPayload? {
        try await repository.loadAudioTranscript(
            notebookID: notebookID,
            sessionID: sessionID
        )
    }

}

enum NotebookAudioCoordinatorActivity: String, Codable, Equatable, Sendable {
    case idle
    case startingRecording
    case recording
    case stoppingRecording
    case persistingRecording
    case preparingPlayback
    case playing
    case paused
    case transcribing
    case loadingTranscript
    case cancelling
}

struct NotebookAudioCoordinatorSnapshot: Codable, Equatable, Sendable {
    var activity: NotebookAudioCoordinatorActivity
    var notebookID: NotebookID?
    var recordingID: UUID?
    var sessionID: AudioSessionID?

    static let idle = NotebookAudioCoordinatorSnapshot(
        activity: .idle,
        notebookID: nil,
        recordingID: nil,
        sessionID: nil
    )
}

enum NotebookAudioCoordinatorError: LocalizedError, Equatable, Sendable {
    case busy(NotebookAudioCoordinatorActivity)
    case noActiveRecording
    case noActivePlayback
    case invalidConfiguration
    case unsafeWorkingDirectory
    case unsafeTemporaryFile
    case invalidRecordingResult
    case invalidPlaybackTime
    case invalidLocaleIdentifier
    case duplicateOperationMark(OperationID)
    case tooManyTimelineMarks(maximum: Int)
    case noReplayBaseline(PageID)
    case replayCaptureLimitExceeded
    case invalidReplayCapture
    case recordingTooLarge(maximumBytes: Int64)
    case materializationTooLarge(maximumBytes: Int64)
    case incompleteAudioMaterialization
    case stalePersistenceRollbackFailed

    var errorDescription: String? {
        switch self {
        case .busy:
            "Another notebook audio operation is already active."
        case .noActiveRecording:
            "There is no notebook recording to stop or mark."
        case .noActivePlayback:
            "There is no notebook recording being played."
        case .invalidConfiguration:
            "The notebook audio limits are invalid."
        case .unsafeWorkingDirectory:
            "The notebook audio working directory is unsafe."
        case .unsafeTemporaryFile:
            "The notebook audio temporary file is unsafe."
        case .invalidRecordingResult:
            "The audio recorder returned an invalid result."
        case .invalidPlaybackTime:
            "The requested playback time is invalid."
        case .invalidLocaleIdentifier:
            "The transcription language identifier is invalid."
        case .duplicateOperationMark:
            "The recording contains more than one mark for the same operation."
        case .tooManyTimelineMarks:
            "The recording contains too many timeline marks."
        case .noReplayBaseline:
            "The page could not be captured before its first replay mutation."
        case .replayCaptureLimitExceeded:
            "The recording's Note Replay history exceeds the safe local limit."
        case .invalidReplayCapture:
            "The recording's Note Replay history is incomplete or invalid."
        case .recordingTooLarge:
            "The recording exceeds the App's safe ingestion limit."
        case .materializationTooLarge:
            "The stored recording exceeds the App's safe materialization limit."
        case .incompleteAudioMaterialization:
            "The stored recording could not be reconstructed completely."
        case .stalePersistenceRollbackFailed:
            "A cancelled recording was saved but could not be rolled back."
        }
    }
}

struct NotebookAudioCoordinatorConfiguration: Equatable, Sendable {
    /// Temporary App cap imposed by Core's current `Data`-based ingest API.
    static let defaultMaximumRecordingBytes: Int64 = 64 * 1_024 * 1_024
    static let defaultMaximumMaterializedBytes: Int64 = 512 * 1_024 * 1_024
    static let defaultChunkBytes = 1 * 1_024 * 1_024
    static let defaultMaximumReplayPayloadBytes = 64 * 1_024 * 1_024

    var maximumRecordingBytes: Int64
    var maximumMaterializedBytes: Int64
    var chunkByteCount: Int
    var maximumTimelineMarks: Int
    var maximumReplayPayloadBytes: Int

    init(
        maximumRecordingBytes: Int64 = Self.defaultMaximumRecordingBytes,
        maximumMaterializedBytes: Int64 = Self.defaultMaximumMaterializedBytes,
        chunkByteCount: Int = Self.defaultChunkBytes,
        maximumTimelineMarks: Int = 100_000,
        maximumReplayPayloadBytes: Int = Self.defaultMaximumReplayPayloadBytes
    ) {
        self.maximumRecordingBytes = maximumRecordingBytes
        self.maximumMaterializedBytes = maximumMaterializedBytes
        self.chunkByteCount = chunkByteCount
        self.maximumTimelineMarks = maximumTimelineMarks
        self.maximumReplayPayloadBytes = maximumReplayPayloadBytes
    }

    var isValid: Bool {
        maximumRecordingBytes > 0
            && maximumRecordingBytes <= Self.defaultMaximumRecordingBytes
            && maximumMaterializedBytes > 0
            && maximumMaterializedBytes <= Self.defaultMaximumMaterializedBytes
            && chunkByteCount > 0
            && chunkByteCount <= 4 * 1_024 * 1_024
            && maximumTimelineMarks > 0
            && maximumTimelineMarks <= 100_000
            && maximumReplayPayloadBytes > 0
            && maximumReplayPayloadBytes
                <= NoteReplayHistoryLimits.maximumUniquePayloadBytes
    }
}

enum NotebookAudioCancellationTaskFence {
    /// A completed cancellation may still be stored briefly while a newer
    /// generation becomes active. Its failure belongs only to its own
    /// generation; callers for a newer generation must cancel that generation
    /// and must not inherit the stale failure.
    static func shouldCancelRequestedGeneration(
        existingResult: Result<Void, Error>,
        existingGeneration: UUID?,
        requestedGeneration: UUID
    ) throws -> Bool {
        guard existingGeneration == requestedGeneration else { return true }
        try existingResult.get()
        return false
    }
}

actor NotebookAudioCoordinator {
    private enum PlaybackOwner: Equatable, Sendable {
        case standard
        case replay(UUID)
    }

    private struct MaterializedAudio: Sendable {
        var url: URL
        var durationSeconds: TimeInterval
    }

    private struct ReplayTerminalPlayback: Sendable {
        let ownerID: UUID
        let state: AudioPlaybackState
    }

    private struct ReplayCapturedScene: Equatable, Sendable {
        var inkPayload: NoteReplayPayloadReference?
        var elementsPayload: NoteReplayPayloadReference
    }

    private struct ReplayCaptureState: Sendable {
        let recordingID: UUID
        var events: [NoteReplaySnapshotEvent] = []
        var payloadsByID: [AssetID: NoteReplayPayloadBlob] = [:]
        var scenesByPage: [PageID: ReplayCapturedScene] = [:]
        var eventCountByPage: [PageID: Int] = [:]
        var uniquePayloadByteCount = 0
    }

    private let persistence: any NotebookAudioPersisting
    private let recorder: any AudioTimelineRecording
    private let player: any AudioTimelinePlaying
    private let transcriber: any SpeechTranscribing
    private let workingDirectory: URL
    private let configuration: NotebookAudioCoordinatorConfiguration
    private let fileManager: FileManager
    private let now: @Sendable () -> Date

    private var state: NotebookAudioCoordinatorSnapshot = .idle
    private var generation = UUID()
    private var recordingURL: URL?
    private var replayCaptureState: ReplayCaptureState?
    private var playbackURL: URL?
    private var playbackOwner: PlaybackOwner?
    private var replayTerminalPlayback: ReplayTerminalPlayback?
    private var ownedTemporaryFiles = Set<URL>()
    private var persistenceTask: Task<NotebookAudioPersistenceReceipt, Error>?
    private var persistenceTaskGeneration: UUID?
    private var cancellationTask: Task<Void, Error>?
    private var cancellationTaskID: UUID?
    private var cancellationTaskGeneration: UUID?
    private var transcriptionTask: Task<[TranscriptSegment], Error>?
    private var transcriptionTaskGeneration: UUID?
    private var transcriptSaveTask: Task<AudioSessionDescriptor, Error>?
    private var transcriptSaveTaskGeneration: UUID?
    private var transcriptLoadTask: Task<NotebookAudioTranscriptPayload?, Error>?
    private var transcriptLoadTaskGeneration: UUID?

    init(
        persistence: any NotebookAudioPersisting,
        recorder: any AudioTimelineRecording = AudioTimelineRecorder(),
        player: any AudioTimelinePlaying = AudioTimelinePlayer(),
        transcriber: any SpeechTranscribing = OnDeviceSpeechTranscriber(),
        workingDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Notes-AudioCoordinator", isDirectory: true),
        configuration: NotebookAudioCoordinatorConfiguration = .init(),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.persistence = persistence
        self.recorder = recorder
        self.player = player
        self.transcriber = transcriber
        self.workingDirectory = workingDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.configuration = configuration
        self.fileManager = fileManager
        self.now = now
    }

    func snapshot() async -> NotebookAudioCoordinatorSnapshot {
        if state.activity == .playing || state.activity == .paused {
            let expectedGeneration = generation
            let playbackState = await player.currentState()
            guard generation == expectedGeneration else { return state }
            switch playbackState.status {
            case .stopped, .finished, .failed:
                finishPlaybackTerminalState(playbackState)
            case .playing:
                state.activity = .playing
            case .paused:
                state.activity = .paused
            }
        }
        return state
    }

    /// The legacy audio panel only observes operations that it is allowed to
    /// control. Replay playback has its own exact-owner observation API.
    func standardSnapshot() async -> NotebookAudioCoordinatorSnapshot {
        if case .replay = playbackOwner {
            return .idle
        }
        return await snapshot()
    }

    /// Returns the player's clock for deterministic UI polling. The caller
    /// still uses `snapshot()` as the authoritative coordinator activity.
    func playbackState() async -> AudioPlaybackState {
        await player.currentState()
    }

    func standardPlaybackState() async -> AudioPlaybackState {
        guard playbackOwner == .standard else { return .stopped }
        let expectedGeneration = generation
        let playbackState = await player.currentState()
        guard generation == expectedGeneration,
              playbackOwner == .standard else { return .stopped }
        return playbackState
    }

    func replayPlaybackState(ownerID: UUID) async -> AudioPlaybackState? {
        if replayTerminalPlayback?.ownerID == ownerID {
            let terminalState = replayTerminalPlayback?.state
            replayTerminalPlayback = nil
            return terminalState
        }
        let owner = PlaybackOwner.replay(ownerID)
        guard playbackOwner == owner else { return nil }
        let expectedGeneration = generation
        let playbackState = await player.currentState()
        guard generation == expectedGeneration, playbackOwner == owner else {
            return nil
        }
        switch playbackState.status {
        case .playing:
            state.activity = .playing
        case .paused:
            state.activity = .paused
        case .stopped, .finished, .failed:
            finishPlaybackTerminalState(playbackState)
            replayTerminalPlayback = nil
        }
        return playbackState
    }

    @discardableResult
    func startRecording(notebookID: NotebookID) async throws -> UUID {
        try requireIdle()
        try validateConfiguration()
        let operationGeneration = begin(
            activity: .startingRecording,
            notebookID: notebookID
        )
        let destination: URL
        do {
            destination = try makeOwnedTemporaryFileURL(prefix: "recording")
            recordingURL = destination
        } catch {
            finishIfCurrent(operationGeneration)
            throw error
        }

        do {
            let recordingID = try await recorder.startRecording(to: destination)
            try ensureCurrent(operationGeneration)
            replayCaptureState = ReplayCaptureState(recordingID: recordingID)
            state = NotebookAudioCoordinatorSnapshot(
                activity: .recording,
                notebookID: notebookID,
                recordingID: recordingID,
                sessionID: nil
            )
            return recordingID
        } catch {
            if generation == operationGeneration {
                await recorder.cancelRecording()
            }
            removeOwnedTemporaryFile(destination)
            if generation == operationGeneration {
                recordingURL = nil
                replayCaptureState = nil
                state = .idle
            }
            throw error
        }
    }

    func addMark(operationID: OperationID, pageID: PageID) async throws {
        guard state.activity == .recording else {
            throw NotebookAudioCoordinatorError.noActiveRecording
        }
        let operationGeneration = generation
        try await recorder.addMark(
            commandID: operationID.rawValue,
            pageID: pageID.rawValue
        )
        try ensureCurrent(operationGeneration)
        guard state.activity == .recording else { throw CancellationError() }
    }

    /// Captures the complete before-state for a page when it first becomes
    /// editable during this recording. Repeated identical baselines are
    /// deduplicated; a later revisit is recorded as an ordinary checkpoint.
    func addReplayPageSnapshot(
        _ snapshot: NotebookAudioReplayPageSnapshot
    ) async throws {
        let time = try await replayCaptureTime()
        var capture = try currentReplayCapture()
        let inkReference = try snapshot.inkData.map {
            try addReplayPayload(
                $0,
                maximumByteCount: NoteReplayHistoryLimits.maximumInkPayloadBytes,
                to: &capture
            )
        }
        guard snapshot.elements.count
                <= NoteReplayHistoryLimits.maximumElementCountPerSnapshot else {
            throw NotebookAudioCoordinatorError.replayCaptureLimitExceeded
        }
        let elementData: Data
        do {
            elementData = try NoteReplayPayloadCodec.encodeElements(snapshot.elements)
        } catch {
            throw NotebookAudioCoordinatorError.invalidReplayCapture
        }
        let elementsReference = try addReplayPayload(
            elementData,
            maximumByteCount:
                NoteReplayHistoryLimits.maximumElementPayloadBytes,
            to: &capture
        )
        let scene = ReplayCapturedScene(
            inkPayload: inkReference,
            elementsPayload: elementsReference
        )
        if let current = capture.scenesByPage[snapshot.pageID],
           current == scene {
            // The page was reloaded without changing either layer.
            replayCaptureState = capture
            return
        }
        let kind: NoteReplaySnapshotEventKind = capture.scenesByPage[
            snapshot.pageID
        ] == nil ? .baseline : .change
        try appendReplayEvent(
            pageID: snapshot.pageID,
            time: time,
            kind: kind,
            scene: scene,
            to: &capture
        )
        capture.scenesByPage[snapshot.pageID] = scene
        replayCaptureState = capture
    }

    func addReplayInkSnapshot(
        _ data: Data?,
        pageID: PageID
    ) async throws {
        let time = try await replayCaptureTime()
        var capture = try currentReplayCapture()
        guard var scene = capture.scenesByPage[pageID] else {
            throw NotebookAudioCoordinatorError.noReplayBaseline(pageID)
        }
        let reference = try data.map {
            try addReplayPayload(
                $0,
                maximumByteCount: NoteReplayHistoryLimits.maximumInkPayloadBytes,
                to: &capture
            )
        }
        guard scene.inkPayload != reference else {
            replayCaptureState = capture
            return
        }
        scene.inkPayload = reference
        try appendReplayEvent(
            pageID: pageID,
            time: time,
            kind: .change,
            scene: scene,
            to: &capture
        )
        capture.scenesByPage[pageID] = scene
        replayCaptureState = capture
    }

    func addReplayElementsSnapshot(
        _ elements: [CanvasElement],
        pageID: PageID
    ) async throws {
        let time = try await replayCaptureTime()
        var capture = try currentReplayCapture()
        guard var scene = capture.scenesByPage[pageID] else {
            throw NotebookAudioCoordinatorError.noReplayBaseline(pageID)
        }
        guard elements.count
                <= NoteReplayHistoryLimits.maximumElementCountPerSnapshot else {
            throw NotebookAudioCoordinatorError.replayCaptureLimitExceeded
        }
        let data: Data
        do {
            data = try NoteReplayPayloadCodec.encodeElements(elements)
        } catch {
            throw NotebookAudioCoordinatorError.invalidReplayCapture
        }
        let reference = try addReplayPayload(
            data,
            maximumByteCount:
                NoteReplayHistoryLimits.maximumElementPayloadBytes,
            to: &capture
        )
        guard scene.elementsPayload != reference else {
            replayCaptureState = capture
            return
        }
        scene.elementsPayload = reference
        try appendReplayEvent(
            pageID: pageID,
            time: time,
            kind: .change,
            scene: scene,
            to: &capture
        )
        capture.scenesByPage[pageID] = scene
        replayCaptureState = capture
    }

    @discardableResult
    func stopAndPersist(transcriptAssetID: AssetID? = nil) async throws -> AudioSessionDescriptor {
        guard state.activity == .recording,
              let notebookID = state.notebookID,
              let expectedRecordingID = state.recordingID,
              let expectedURL = recordingURL else {
            throw NotebookAudioCoordinatorError.noActiveRecording
        }
        let operationGeneration = generation
        state.activity = .stoppingRecording

        let result: AudioRecordingResult
        do {
            result = try await recorder.stopRecording()
            try ensureCurrent(operationGeneration)
            try validateRecordingResult(
                result,
                expectedRecordingID: expectedRecordingID,
                expectedURL: expectedURL
            )
        } catch {
            removeOwnedTemporaryFile(expectedURL)
            if generation == operationGeneration {
                recordingURL = nil
                replayCaptureState = nil
                state = .idle
            }
            throw error
        }

        let sessionID = AudioSessionID(result.id)
        let timeline: NotesCore.AudioTimelineDocument
        do {
            timeline = try makeCoreTimeline(result: result, sessionID: sessionID)
        } catch {
            removeOwnedTemporaryFile(expectedURL)
            if generation == operationGeneration {
                recordingURL = nil
                replayCaptureState = nil
                state = .idle
            }
            throw error
        }


        let replayHistory: NoteReplayCaptureBundle?
        do {
            replayHistory = try finalizeReplayHistory(
                sessionID: sessionID,
                expectedRecordingID: expectedRecordingID,
                duration: result.duration
            )
        } catch {
            removeOwnedTemporaryFile(expectedURL)
            if generation == operationGeneration {
                recordingURL = nil
                replayCaptureState = nil
                state = .idle
            }
            throw error
        }

        state.activity = .persistingRecording
        state.sessionID = sessionID
        let task = Task {
            if let replayHistory {
                return try await persistence.persistRecordedM4A(
                    at: expectedURL,
                    maximumByteCount: configuration.maximumRecordingBytes,
                    timeline: timeline,
                    replayHistory: replayHistory,
                    notebookID: notebookID,
                    durationSeconds: result.duration,
                    recordingStartedAt: result.startedAt,
                    transcriptAssetID: transcriptAssetID
                )
            }
            return try await persistence.persistRecordedM4A(
                at: expectedURL,
                maximumByteCount: configuration.maximumRecordingBytes,
                timeline: timeline,
                notebookID: notebookID,
                durationSeconds: result.duration,
                recordingStartedAt: result.startedAt,
                transcriptAssetID: transcriptAssetID
            )
        }
        persistenceTask = task
        persistenceTaskGeneration = operationGeneration

        do {
            let receipt = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            let descriptor = receipt.descriptor
            guard !Task.isCancelled, generation == operationGeneration else {
                let cancellationOwnsRollbackFailure = generation != operationGeneration
                do {
                    try await rollbackPersistedSession(receipt)
                } catch {
                    // A coordinator cancellation owns and surfaces rollback
                    // failure. A directly cancelled stop still owns its error.
                    if cancellationOwnsRollbackFailure {
                        throw CancellationError()
                    }
                    throw error
                }
                throw CancellationError()
            }
            guard descriptor.id == sessionID,
                  descriptor.recordingStartedAt == result.startedAt else {
                try await rollbackPersistedSession(receipt)
                throw NotebookAudioCoordinatorError.invalidRecordingResult
            }
            clearPersistenceTask(ifGeneration: operationGeneration)
            recordingURL = nil
            replayCaptureState = nil
            removeOwnedTemporaryFile(expectedURL)
            state = .idle
            return descriptor
        } catch {
            clearPersistenceTask(ifGeneration: operationGeneration)
            removeOwnedTemporaryFile(expectedURL)
            if generation == operationGeneration {
                recordingURL = nil
                replayCaptureState = nil
                state = .idle
            }
            throw error
        }
    }

    func play(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        from time: TimeInterval = 0
    ) async throws {
        try await startPlayback(
            notebookID: notebookID,
            sessionID: sessionID,
            from: time,
            owner: .standard
        )
    }

    func startReplayPlayback(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        from time: TimeInterval,
        ownerID: UUID
    ) async throws {
        try await startPlayback(
            notebookID: notebookID,
            sessionID: sessionID,
            from: time,
            owner: .replay(ownerID)
        )
    }

    private func startPlayback(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        from time: TimeInterval,
        owner: PlaybackOwner
    ) async throws {
        try requireIdle()
        try validateConfiguration()
        guard time.isFinite, time >= 0 else {
            throw NotebookAudioCoordinatorError.invalidPlaybackTime
        }
        playbackOwner = owner
        let operationGeneration = begin(
            activity: .preparingPlayback,
            notebookID: notebookID,
            sessionID: sessionID
        )
        var temporaryURL: URL?
        do {
            let materialized = try await materializeAudio(
                notebookID: notebookID,
                sessionID: sessionID,
                generation: operationGeneration,
                prefix: "playback"
            )
            let materializedURL = materialized.url
            temporaryURL = materializedURL
            try ensureCurrent(operationGeneration)
            try await player.play(
                fileURL: materializedURL,
                from: min(time, materialized.durationSeconds)
            )
            try ensureCurrent(operationGeneration)
            playbackURL = materializedURL
            state.activity = .playing
        } catch {
            if generation == operationGeneration {
                await player.stop()
            }
            if let temporaryURL { removeOwnedTemporaryFile(temporaryURL) }
            if generation == operationGeneration {
                playbackURL = nil
                playbackOwner = nil
                state = .idle
            }
            throw error
        }
    }

    func pausePlayback() async throws {
        try await pausePlayback(owner: .standard)
    }

    func pauseReplayPlayback(ownerID: UUID) async throws {
        try await pausePlayback(owner: .replay(ownerID))
    }

    private func pausePlayback(owner: PlaybackOwner) async throws {
        guard playbackOwner == owner, state.activity == .playing else {
            throw NotebookAudioCoordinatorError.noActivePlayback
        }
        let operationGeneration = generation
        await player.pause()
        try ensureCurrent(operationGeneration)
        guard playbackOwner == owner else {
            throw NotebookAudioCoordinatorError.noActivePlayback
        }
        let playbackState = await player.currentState()
        try ensureCurrent(operationGeneration)
        guard playbackOwner == owner else {
            throw NotebookAudioCoordinatorError.noActivePlayback
        }
        switch playbackState.status {
        case .paused:
            state.activity = .paused
        case .stopped, .finished, .failed:
            finishPlaybackTerminalState(playbackState)
        case .playing:
            throw NotebookAudioCoordinatorError.noActivePlayback
        }
    }

    func resumePlayback() async throws {
        try await resumePlayback(owner: .standard)
    }

    func resumeReplayPlayback(ownerID: UUID) async throws {
        try await resumePlayback(owner: .replay(ownerID))
    }

    private func resumePlayback(owner: PlaybackOwner) async throws {
        guard playbackOwner == owner, state.activity == .paused else {
            throw NotebookAudioCoordinatorError.noActivePlayback
        }
        let operationGeneration = generation
        try await player.resume()
        try ensureCurrent(operationGeneration)
        guard playbackOwner == owner else {
            throw NotebookAudioCoordinatorError.noActivePlayback
        }
        let playbackState = await player.currentState()
        try ensureCurrent(operationGeneration)
        guard playbackOwner == owner else {
            throw NotebookAudioCoordinatorError.noActivePlayback
        }
        switch playbackState.status {
        case .playing:
            state.activity = .playing
        case .stopped, .finished, .failed:
            finishPlaybackTerminalState(playbackState)
        case .paused:
            throw NotebookAudioCoordinatorError.noActivePlayback
        }
    }

    func seekPlayback(to time: TimeInterval) async throws {
        try await seekPlayback(to: time, owner: .standard)
    }

    func seekReplayPlayback(to time: TimeInterval, ownerID: UUID) async throws {
        try await seekPlayback(to: time, owner: .replay(ownerID))
    }

    private func seekPlayback(
        to time: TimeInterval,
        owner: PlaybackOwner
    ) async throws {
        guard playbackOwner == owner,
              state.activity == .playing || state.activity == .paused else {
            throw NotebookAudioCoordinatorError.noActivePlayback
        }
        guard time.isFinite, time >= 0 else {
            throw NotebookAudioCoordinatorError.invalidPlaybackTime
        }
        let operationGeneration = generation
        let playbackState = await player.currentState()
        try ensureCurrent(operationGeneration)
        guard playbackOwner == owner else {
            throw NotebookAudioCoordinatorError.noActivePlayback
        }
        if playbackState.status == .stopped
            || playbackState.status == .finished
            || playbackState.status == .failed {
            finishPlaybackTerminalState(playbackState)
            throw NotebookAudioCoordinatorError.noActivePlayback
        }
        guard playbackState.status == .playing || playbackState.status == .paused,
              playbackState.duration.isFinite,
              playbackState.duration >= 0 else {
            throw NotebookAudioCoordinatorError.noActivePlayback
        }
        try await player.seek(to: min(time, playbackState.duration))
        try ensureCurrent(operationGeneration)
        guard playbackOwner == owner else {
            throw NotebookAudioCoordinatorError.noActivePlayback
        }
    }

    func stopPlayback() async {
        guard playbackOwner == .standard,
              state.activity == .playing || state.activity == .paused else { return }
        let stopGeneration = UUID()
        generation = stopGeneration
        await player.stop()
        guard generation == stopGeneration else { return }
        if let playbackURL { removeOwnedTemporaryFile(playbackURL) }
        playbackURL = nil
        playbackOwner = nil
        state = .idle
    }

    func stopReplayPlayback(ownerID: UUID) async {
        if replayTerminalPlayback?.ownerID == ownerID {
            replayTerminalPlayback = nil
            return
        }
        guard playbackOwner == .replay(ownerID),
              state.activity == .preparingPlayback
                || state.activity == .playing
                || state.activity == .paused else { return }
        try? await cancelCurrentOperation(ifGeneration: generation)
    }

    /// Cancels panel-owned work without granting an old panel authority over
    /// a Replay owner that may belong to another editor lifecycle.
    func cancelStandardOperation() async throws {
        if case .replay = playbackOwner { return }
        guard state.activity != .idle else { return }
        try await cancelCurrentOperation(ifGeneration: generation)
    }

    func transcribe(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        localeIdentifier: String = "zh-Hant-TW"
    ) async throws -> NotebookAudioTranscriptPayload {
        let result = try await transcribeAndPersist(
            notebookID: notebookID,
            sessionID: sessionID,
            localeIdentifier: localeIdentifier
        )
        return result.payload
    }

    /// Returns the descriptor committed by the same durable transcript save.
    /// Consumers can update derived state from this receipt even if a
    /// subsequent session-list refresh is temporarily unavailable.
    func transcribeAndPersist(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        localeIdentifier: String = "zh-Hant-TW"
    ) async throws -> NotebookAudioTranscriptionResult {
        try requireIdle()
        try validateConfiguration()
        try validateLocaleIdentifier(localeIdentifier)
        let operationGeneration = begin(
            activity: .transcribing,
            notebookID: notebookID,
            sessionID: sessionID
        )
        var temporaryURL: URL?
        do {
            let materialized = try await materializeAudio(
                notebookID: notebookID,
                sessionID: sessionID,
                generation: operationGeneration,
                prefix: "transcription"
            )
            let materializedURL = materialized.url
            temporaryURL = materializedURL
            try ensureCurrent(operationGeneration)

            let timeline = try await persistence.loadTimeline(
                notebookID: notebookID,
                sessionID: sessionID
            )
            try ensureCurrent(operationGeneration)
            guard timeline.audioSessionID == sessionID else {
                throw NotebookAudioCoordinatorError.incompleteAudioMaterialization
            }

            let task = Task {
                try await transcriber.transcribe(
                    fileURL: materializedURL,
                    localeIdentifier: localeIdentifier
                )
            }
            transcriptionTask = task
            transcriptionTaskGeneration = operationGeneration
            let segments = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            clearTranscriptionTask(ifGeneration: operationGeneration)
            try Task.checkCancellation()
            try ensureCurrent(operationGeneration)

            let payload = try makeTranscriptPayload(
                sessionID: sessionID,
                localeIdentifier: localeIdentifier,
                segments: segments,
                timeline: timeline,
                durationSeconds: materialized.durationSeconds
            )
            removeOwnedTemporaryFile(materializedURL)
            temporaryURL = nil
            let saveTask = Task {
                try await persistence.saveTranscript(
                    payload,
                    notebookID: notebookID,
                    sessionID: sessionID
                )
            }
            transcriptSaveTask = saveTask
            transcriptSaveTaskGeneration = operationGeneration
            let savedDescriptor = try await withTaskCancellationHandler {
                try await saveTask.value
            } onCancel: {
                saveTask.cancel()
            }
            clearTranscriptSaveTask(ifGeneration: operationGeneration)
            try Task.checkCancellation()
            try ensureCurrent(operationGeneration)
            guard savedDescriptor.id == sessionID,
                  savedDescriptor.transcriptAssetID != nil else {
                throw NotebookAudioCoordinatorError.incompleteAudioMaterialization
            }
            state = .idle
            return NotebookAudioTranscriptionResult(
                payload: payload,
                savedDescriptor: savedDescriptor
            )
        } catch {
            if transcriptionTaskGeneration == operationGeneration {
                transcriptionTask?.cancel()
                clearTranscriptionTask(ifGeneration: operationGeneration)
            }
            if transcriptSaveTaskGeneration == operationGeneration {
                transcriptSaveTask?.cancel()
                clearTranscriptSaveTask(ifGeneration: operationGeneration)
            }
            if let temporaryURL { removeOwnedTemporaryFile(temporaryURL) }
            if generation == operationGeneration {
                state = .idle
            }
            throw error
        }
    }

    func loadTranscript(
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> NotebookAudioTranscriptPayload? {
        try requireIdle()
        let operationGeneration = begin(
            activity: .loadingTranscript,
            notebookID: notebookID,
            sessionID: sessionID
        )
        do {
            let loadTask = Task {
                try await persistence.loadTranscript(
                    notebookID: notebookID,
                    sessionID: sessionID
                )
            }
            transcriptLoadTask = loadTask
            transcriptLoadTaskGeneration = operationGeneration
            let payload = try await withTaskCancellationHandler {
                try await loadTask.value
            } onCancel: {
                loadTask.cancel()
            }
            clearTranscriptLoadTask(ifGeneration: operationGeneration)
            try Task.checkCancellation()
            try ensureCurrent(operationGeneration)
            guard payload?.audioSessionID == sessionID || payload == nil else {
                throw NotebookAudioCoordinatorError.incompleteAudioMaterialization
            }
            state = .idle
            return payload
        } catch {
            if transcriptLoadTaskGeneration == operationGeneration {
                transcriptLoadTask?.cancel()
                clearTranscriptLoadTask(ifGeneration: operationGeneration)
            }
            if generation == operationGeneration { state = .idle }
            throw error
        }
    }

    func cancelCurrentOperation() async throws {
        try await cancelCurrentOperation(ifGeneration: generation)
    }

    private func cancelCurrentOperation(ifGeneration expectedGeneration: UUID) async throws {
        if let cancellationTask {
            let existingTaskID = cancellationTaskID
            let existingGeneration = cancellationTaskGeneration
            let existingResult = await cancellationTask.result
            if let existingTaskID,
               cancellationTaskID == existingTaskID {
                clearCancellationTask(ifID: existingTaskID)
            }
            let shouldCancelRequestedGeneration = try
                NotebookAudioCancellationTaskFence
                    .shouldCancelRequestedGeneration(
                        existingResult: existingResult,
                        existingGeneration: existingGeneration,
                        requestedGeneration: expectedGeneration
                    )
            if shouldCancelRequestedGeneration,
               generation == expectedGeneration {
                try await cancelCurrentOperation(
                    ifGeneration: expectedGeneration
                )
            }
            return
        }
        guard generation == expectedGeneration else { return }
        let taskID = UUID()
        let task = Task {
            try await performCancellation(ifGeneration: expectedGeneration)
        }
        cancellationTask = task
        cancellationTaskID = taskID
        cancellationTaskGeneration = expectedGeneration
        do {
            try await task.value
            clearCancellationTask(ifID: taskID)
        } catch {
            clearCancellationTask(ifID: taskID)
            throw error
        }
    }

    private func performCancellation(ifGeneration expectedGeneration: UUID) async throws {
        guard generation == expectedGeneration else { return }
        let priorState = state
        let persistenceToCancel = persistenceTask
        generation = UUID()
        state.activity = .cancelling
        let transcriptionToCancel = transcriptionTask
        let transcriptSaveToCancel = transcriptSaveTask
        let transcriptLoadToCancel = transcriptLoadTask
        persistenceToCancel?.cancel()
        transcriptionToCancel?.cancel()
        transcriptSaveToCancel?.cancel()
        transcriptLoadToCancel?.cancel()
        persistenceTask = nil
        persistenceTaskGeneration = nil
        transcriptionTask = nil
        transcriptionTaskGeneration = nil
        transcriptSaveTask = nil
        transcriptSaveTaskGeneration = nil
        transcriptLoadTask = nil
        transcriptLoadTaskGeneration = nil

        if priorState.activity == .startingRecording
            || priorState.activity == .recording
            || priorState.activity == .stoppingRecording
            || priorState.activity == .persistingRecording {
            await recorder.cancelRecording()
        }
        if priorState.activity == .preparingPlayback
            || priorState.activity == .playing
            || priorState.activity == .paused {
            await player.stop()
        }
        if priorState.activity == .transcribing, let transcriptionToCancel {
            _ = await transcriptionToCancel.result
        }
        if priorState.activity == .transcribing, let transcriptSaveToCancel {
            _ = await transcriptSaveToCancel.result
        }
        if priorState.activity == .loadingTranscript, let transcriptLoadToCancel {
            _ = await transcriptLoadToCancel.result
        }

        var rollbackFailed = false
        if let persistenceToCancel {
            do {
                let receipt = try await persistenceToCancel.value
                try await rollbackPersistedSession(receipt)
            } catch is CancellationError {
                // A cooperative persistence task did not commit anything.
            } catch {
                // A persistence failure is atomic by contract; only a failed
                // compensating rollback needs to block a root-directory change.
                if let coordinatorError = error as? NotebookAudioCoordinatorError,
                   coordinatorError == .stalePersistenceRollbackFailed {
                    rollbackFailed = true
                }
            }
        }

        if let recordingURL { removeOwnedTemporaryFile(recordingURL) }
        if let playbackURL { removeOwnedTemporaryFile(playbackURL) }
        recordingURL = nil
        replayCaptureState = nil
        playbackURL = nil
        playbackOwner = nil
        replayTerminalPlayback = nil
        state = .idle
        if rollbackFailed {
            throw NotebookAudioCoordinatorError.stalePersistenceRollbackFailed
        }
    }

    private func materializeAudio(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        generation operationGeneration: UUID,
        prefix: String
    ) async throws -> MaterializedAudio {
        let descriptor = try await persistence.descriptor(
            notebookID: notebookID,
            sessionID: sessionID
        )
        try ensureCurrent(operationGeneration)
        guard (2...AudioSessionDescriptor.currentSchemaVersion)
                .contains(descriptor.schemaVersion),
              descriptor.id == sessionID,
              descriptor.durationSeconds.isFinite,
              descriptor.durationSeconds >= 0,
              descriptor.durationSeconds <= 7 * 24 * 60 * 60,
              let expectedByteCount = descriptor.audioByteCount,
              expectedByteCount >= 12,
              let expectedDigest = descriptor.audioSHA256,
              isSHA256Digest(expectedDigest) else {
            throw NotebookAudioCoordinatorError.incompleteAudioMaterialization
        }
        guard expectedByteCount <= configuration.maximumMaterializedBytes else {
            throw NotebookAudioCoordinatorError.materializationTooLarge(
                maximumBytes: configuration.maximumMaterializedBytes
            )
        }

        let destination = try makeOwnedTemporaryFileURL(prefix: prefix)
        var shouldKeepDestination = false
        defer {
            if !shouldKeepDestination {
                removeOwnedTemporaryFile(destination)
            }
        }
        let handle = try createExclusiveOwnedTemporaryFile(at: destination)
        var digest = CryptoKit.SHA256()
        do {
            var offset: Int64 = 0
            while offset < expectedByteCount {
                try Task.checkCancellation()
                try ensureCurrent(operationGeneration)
                let remaining = expectedByteCount - offset
                let requestedCount = min(
                    configuration.chunkByteCount,
                    Int(min(remaining, Int64(Int.max)))
                )
                let chunk = try await persistence.loadAudioChunk(
                    notebookID: notebookID,
                    sessionID: sessionID,
                    offset: offset,
                    maximumByteCount: requestedCount
                )
                try ensureCurrent(operationGeneration)
                guard !chunk.isEmpty,
                      chunk.count <= requestedCount,
                      Int64(chunk.count) <= remaining else {
                    throw NotebookAudioCoordinatorError.incompleteAudioMaterialization
                }
                try handle.write(contentsOf: chunk)
                digest.update(data: chunk)
                offset += Int64(chunk.count)
            }
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        let values = try destination.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        let actualByteCount = values.fileSize.map { Int64($0) }
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              actualByteCount == expectedByteCount,
              hexadecimalDigest(digest.finalize()) == expectedDigest else {
            throw NotebookAudioCoordinatorError.incompleteAudioMaterialization
        }
        shouldKeepDestination = true
        return MaterializedAudio(
            url: destination,
            durationSeconds: descriptor.durationSeconds
        )
    }

    private func makeCoreTimeline(
        result: AudioRecordingResult,
        sessionID: AudioSessionID
    ) throws -> NotesCore.AudioTimelineDocument {
        guard result.marks.count <= configuration.maximumTimelineMarks else {
            throw NotebookAudioCoordinatorError.tooManyTimelineMarks(
                maximum: configuration.maximumTimelineMarks
            )
        }
        var operationIDs = Set<OperationID>()
        var markIDs = Set<AudioTimelineMarkID>()
        let marks = try result.marks.map { mark -> NotesCore.AudioTimelineMark in
            let operationID = OperationID(mark.commandID)
            let markID = AudioTimelineMarkID(mark.id)
            guard operationIDs.insert(operationID).inserted else {
                throw NotebookAudioCoordinatorError.duplicateOperationMark(operationID)
            }
            guard markIDs.insert(markID).inserted else {
                throw NotebookAudioCoordinatorError.invalidRecordingResult
            }
            guard mark.time.isFinite,
                  mark.time >= 0,
                  mark.time <= result.duration else {
                throw NotebookAudioCoordinatorError.invalidRecordingResult
            }
            let createdAt = result.startedAt.addingTimeInterval(mark.time)
            guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw NotebookAudioCoordinatorError.invalidRecordingResult
            }
            return NotesCore.AudioTimelineMark(
                id: markID,
                operationID: operationID,
                pageID: PageID(mark.pageID),
                timeSeconds: mark.time,
                createdAt: createdAt
            )
        }
        let modifiedAt = now()
        guard modifiedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw NotebookAudioCoordinatorError.invalidRecordingResult
        }
        return NotesCore.AudioTimelineDocument(
            audioSessionID: sessionID,
            marks: marks,
            modifiedAt: modifiedAt
        )
    }

    private func replayCaptureTime() async throws -> TimeInterval {
        guard state.activity == .recording else {
            throw NotebookAudioCoordinatorError.noActiveRecording
        }
        let operationGeneration = generation
        let time = try await recorder.currentRecordingTime()
        try ensureCurrent(operationGeneration)
        guard state.activity == .recording,
              time.isFinite,
              time >= 0,
              time <= NoteReplaySessionPolicy.maximumDuration else {
            throw NotebookAudioCoordinatorError.invalidReplayCapture
        }
        return time
    }

    private func currentReplayCapture() throws -> ReplayCaptureState {
        guard state.activity == .recording,
              let recordingID = state.recordingID,
              let replayCaptureState,
              replayCaptureState.recordingID == recordingID else {
            throw NotebookAudioCoordinatorError.noActiveRecording
        }
        return replayCaptureState
    }

    private func addReplayPayload(
        _ data: Data,
        maximumByteCount: Int,
        to capture: inout ReplayCaptureState
    ) throws -> NoteReplayPayloadReference {
        guard !data.isEmpty,
              data.count <= maximumByteCount else {
            throw NotebookAudioCoordinatorError.replayCaptureLimitExceeded
        }
        let digest = hexadecimalDigest(CryptoKit.SHA256.hash(data: data))
        let assetID = AssetID(digest)
        let reference = NoteReplayPayloadReference(
            assetID: assetID,
            byteCount: data.count
        )
        if let existing = capture.payloadsByID[assetID] {
            guard existing.reference == reference,
                  existing.data == data else {
                throw NotebookAudioCoordinatorError.invalidReplayCapture
            }
            return reference
        }
        guard capture.payloadsByID.count
                < NoteReplayHistoryLimits.maximumUniquePayloadCount,
              data.count <= configuration.maximumReplayPayloadBytes,
              capture.uniquePayloadByteCount
                <= configuration.maximumReplayPayloadBytes - data.count else {
            throw NotebookAudioCoordinatorError.replayCaptureLimitExceeded
        }
        capture.payloadsByID[assetID] = NoteReplayPayloadBlob(
            reference: reference,
            data: data
        )
        capture.uniquePayloadByteCount += data.count
        return reference
    }

    private func appendReplayEvent(
        pageID: PageID,
        time: TimeInterval,
        kind: NoteReplaySnapshotEventKind,
        scene: ReplayCapturedScene,
        to capture: inout ReplayCaptureState
    ) throws {
        guard time.isFinite,
              time >= 0,
              capture.events.last.map({ $0.timeSeconds <= time }) ?? true else {
            throw NotebookAudioCoordinatorError.invalidReplayCapture
        }
        guard capture.events.count < NoteReplayHistoryLimits.maximumEventCount,
              (capture.eventCountByPage[pageID] ?? 0)
                < NoteReplayHistoryLimits.maximumEventsPerPage else {
            throw NotebookAudioCoordinatorError.replayCaptureLimitExceeded
        }
        let sequence = capture.events.count
        capture.events.append(NoteReplaySnapshotEvent(
            id: NoteReplayEventID(),
            operationID: OperationID(),
            sequence: sequence,
            timeSeconds: time,
            pageID: pageID,
            kind: kind,
            inkPayload: scene.inkPayload,
            elementsPayload: scene.elementsPayload
        ))
        capture.eventCountByPage[pageID, default: 0] += 1
    }

    private func finalizeReplayHistory(
        sessionID: AudioSessionID,
        expectedRecordingID: UUID,
        duration: TimeInterval
    ) throws -> NoteReplayCaptureBundle? {
        guard duration.isFinite,
              duration > 0,
              duration <= NoteReplaySessionPolicy.maximumDuration,
               var capture = replayCaptureState,
               capture.recordingID == expectedRecordingID else {
            throw NotebookAudioCoordinatorError.invalidReplayCapture
        }
        if capture.scenesByPage.isEmpty {
            guard capture.events.isEmpty,
                  capture.payloadsByID.isEmpty,
                  capture.eventCountByPage.isEmpty,
                  capture.uniquePayloadByteCount == 0 else {
                throw NotebookAudioCoordinatorError.invalidReplayCapture
            }
            // Audio-only recordings on structured pages do not fabricate an
            // empty Replay index. They retain the legacy descriptor envelope.
            return nil
        }
        for pageID in capture.scenesByPage.keys.sorted(by: {
            $0.description < $1.description
        }) {
            guard let scene = capture.scenesByPage[pageID] else {
                throw NotebookAudioCoordinatorError.invalidReplayCapture
            }
            try appendReplayEvent(
                pageID: pageID,
                time: duration,
                kind: .terminal,
                scene: scene,
                to: &capture
            )
        }
        let sealedAt = now()
        guard sealedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw NotebookAudioCoordinatorError.invalidReplayCapture
        }
        let document = NoteReplayHistoryDocument(
            audioSessionID: sessionID,
            sealedAt: sealedAt,
            events: capture.events
        )
        let payloads = capture.payloadsByID.values.sorted {
            $0.reference.assetID.rawValue < $1.reference.assetID.rawValue
        }
        return NoteReplayCaptureBundle(
            document: document,
            payloads: payloads
        )
    }

    private func makeTranscriptPayload(
        sessionID: AudioSessionID,
        localeIdentifier: String,
        segments: [TranscriptSegment],
        timeline: NotesCore.AudioTimelineDocument,
        durationSeconds: TimeInterval
    ) throws -> NotebookAudioTranscriptPayload {
        guard timeline.schemaVersion == NotesCore.AudioTimelineDocument.currentSchemaVersion,
              timeline.modifiedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw NotebookAudioCoordinatorError.incompleteAudioMaterialization
        }
        guard timeline.marks.count <= configuration.maximumTimelineMarks else {
            throw NotebookAudioCoordinatorError.tooManyTimelineMarks(
                maximum: configuration.maximumTimelineMarks
            )
        }
        var markIDs = Set<AudioTimelineMarkID>()
        var operationIDs = Set<OperationID>()
        for mark in timeline.marks {
            guard mark.schemaVersion == NotesCore.AudioTimelineMark.currentSchemaVersion,
                  markIDs.insert(mark.id).inserted,
                  operationIDs.insert(mark.operationID).inserted,
                  mark.timeSeconds.isFinite,
                  mark.timeSeconds >= 0,
                  mark.timeSeconds <= durationSeconds,
                  mark.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw NotebookAudioCoordinatorError.incompleteAudioMaterialization
            }
        }
        var segmentIDs = Set<UUID>()
        var totalTextBytes = 0
        let endTolerance = min(0.001, max(0, durationSeconds))
        guard segments.count <= min(
                  configuration.maximumTimelineMarks,
                  AudioTranscriptDocument.maximumSegmentCount
              ),
              segments.allSatisfy({ segment in
                  let textBytes = segment.text.utf8.count
                  guard textBytes <= AudioTranscriptDocument.maximumTextUTF8BytesPerSegment,
                        totalTextBytes <= AudioTranscriptDocument.maximumTotalTextUTF8Bytes - textBytes else {
                      return false
                  }
                  totalTextBytes += textBytes
                  return segmentIDs.insert(segment.id).inserted
                      && segment.startTime.isFinite
                      && segment.startTime >= 0
                      && segment.startTime <= durationSeconds + endTolerance
                      && segment.duration.isFinite
                      && segment.duration >= 0
                      && segment.confidence.isFinite
                      && (0 ... 1).contains(segment.confidence)
              }) else {
            throw NotebookAudioCoordinatorError.incompleteAudioMaterialization
        }
        let serviceMarks = timeline.marks.map {
            NotesServices.AudioTimelineMark(
                id: $0.id.rawValue,
                commandID: $0.operationID.rawValue,
                pageID: $0.pageID.rawValue,
                time: $0.timeSeconds
            )
        }
        let mappings = try AudioTimelineMapper.map(segments: segments, to: serviceMarks)
        var coreMarksByID: [UUID: NotesCore.AudioTimelineMark] = [:]
        for mark in timeline.marks {
            coreMarksByID[mark.id.rawValue] = mark
        }
        let mappedSegments = mappings.map { mapping in
            let coreMark = mapping.mark.flatMap { coreMarksByID[$0.id] }
            let normalizedStart = min(mapping.segment.startTime, durationSeconds)
            let normalizedDuration = min(
                mapping.segment.duration,
                max(0, durationSeconds - normalizedStart)
            )
            return NotebookAudioTranscriptSegmentMapping(
                id: mapping.segment.id,
                text: mapping.segment.text,
                startTime: normalizedStart,
                duration: normalizedDuration,
                confidence: mapping.segment.confidence,
                timelineMarkID: coreMark?.id,
                operationID: coreMark?.operationID,
                pageID: coreMark?.pageID
            )
        }.sorted { lhs, rhs in
            if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
            if lhs.duration != rhs.duration { return lhs.duration < rhs.duration }
            return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
        }
        let generatedAt = now()
        guard generatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw NotebookAudioCoordinatorError.incompleteAudioMaterialization
        }
        return NotebookAudioTranscriptPayload(
            audioSessionID: sessionID,
            localeIdentifier: localeIdentifier,
            provenance: .speechTranscriber,
            generatedAt: generatedAt,
            segments: mappedSegments
        )
    }

    private func validateRecordingResult(
        _ result: AudioRecordingResult,
        expectedRecordingID: UUID,
        expectedURL: URL
    ) throws {
        guard result.id == expectedRecordingID,
              result.fileURL.standardizedFileURL == expectedURL.standardizedFileURL,
              isOwnedTemporaryFile(result.fileURL),
              result.duration.isFinite,
              result.duration >= 0,
              result.startedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw NotebookAudioCoordinatorError.invalidRecordingResult
        }
        let values = try result.fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0 else {
            throw NotebookAudioCoordinatorError.unsafeTemporaryFile
        }
        guard Int64(size) <= configuration.maximumRecordingBytes else {
            throw NotebookAudioCoordinatorError.recordingTooLarge(
                maximumBytes: configuration.maximumRecordingBytes
            )
        }
    }

    private func requireIdle() throws {
        guard state.activity == .idle else {
            throw NotebookAudioCoordinatorError.busy(state.activity)
        }
    }

    private func finishPlaybackTerminalState(_ playbackState: AudioPlaybackState) {
        if case .replay(let ownerID) = playbackOwner {
            replayTerminalPlayback = ReplayTerminalPlayback(
                ownerID: ownerID,
                state: playbackState
            )
        }
        if let playbackURL { removeOwnedTemporaryFile(playbackURL) }
        playbackURL = nil
        playbackOwner = nil
        state = .idle
    }

    private func validateConfiguration() throws {
        guard configuration.isValid else {
            throw NotebookAudioCoordinatorError.invalidConfiguration
        }
    }

    @discardableResult
    private func begin(
        activity: NotebookAudioCoordinatorActivity,
        notebookID: NotebookID,
        sessionID: AudioSessionID? = nil
    ) -> UUID {
        replayTerminalPlayback = nil
        let newGeneration = UUID()
        generation = newGeneration
        state = NotebookAudioCoordinatorSnapshot(
            activity: activity,
            notebookID: notebookID,
            recordingID: nil,
            sessionID: sessionID
        )
        return newGeneration
    }

    private func ensureCurrent(_ expectedGeneration: UUID) throws {
        try Task.checkCancellation()
        guard generation == expectedGeneration else { throw CancellationError() }
    }

    private func rollbackPersistedSession(
        _ receipt: NotebookAudioPersistenceReceipt
    ) async throws {
        let rollbackTask = Task.detached {
            try await receipt.rollback()
        }
        do {
            try await rollbackTask.value
        } catch {
            throw NotebookAudioCoordinatorError.stalePersistenceRollbackFailed
        }
    }

    private func validateLocaleIdentifier(_ identifier: String) throws {
        guard !identifier.isEmpty,
              identifier.utf8.count <= 128,
              !identifier.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw NotebookAudioCoordinatorError.invalidLocaleIdentifier
        }
    }

    private func finishIfCurrent(_ expectedGeneration: UUID) {
        if generation == expectedGeneration { state = .idle }
    }

    private func clearPersistenceTask(ifGeneration expectedGeneration: UUID) {
        guard persistenceTaskGeneration == expectedGeneration else { return }
        persistenceTask = nil
        persistenceTaskGeneration = nil
    }

    private func clearTranscriptionTask(ifGeneration expectedGeneration: UUID) {
        guard transcriptionTaskGeneration == expectedGeneration else { return }
        transcriptionTask = nil
        transcriptionTaskGeneration = nil
    }

    private func clearTranscriptSaveTask(ifGeneration expectedGeneration: UUID) {
        guard transcriptSaveTaskGeneration == expectedGeneration else { return }
        transcriptSaveTask = nil
        transcriptSaveTaskGeneration = nil
    }

    private func clearTranscriptLoadTask(ifGeneration expectedGeneration: UUID) {
        guard transcriptLoadTaskGeneration == expectedGeneration else { return }
        transcriptLoadTask = nil
        transcriptLoadTaskGeneration = nil
    }

    private func clearCancellationTask(ifID expectedID: UUID) {
        guard cancellationTaskID == expectedID else { return }
        cancellationTask = nil
        cancellationTaskID = nil
        cancellationTaskGeneration = nil
    }

    private func makeOwnedTemporaryFileURL(prefix: String) throws -> URL {
        try ensureSafeWorkingDirectory()
        let url = workingDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString.lowercased()).m4a", isDirectory: false)
            .standardizedFileURL
        guard url.deletingLastPathComponent().standardizedFileURL == workingDirectory,
              url.pathExtension.caseInsensitiveCompare("m4a") == .orderedSame,
              !fileManager.fileExists(atPath: url.path),
              (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil else {
            throw NotebookAudioCoordinatorError.unsafeTemporaryFile
        }
        ownedTemporaryFiles.insert(url)
        return url
    }

    private func ensureSafeWorkingDirectory() throws {
        guard workingDirectory.isFileURL else {
            throw NotebookAudioCoordinatorError.unsafeWorkingDirectory
        }
        try fileManager.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let values = try workingDirectory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw NotebookAudioCoordinatorError.unsafeWorkingDirectory
        }
        let descriptor = openAbsolutePathWithoutFollowingLinks(
            at: workingDirectory,
            finalFlags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw NotebookAudioCoordinatorError.unsafeWorkingDirectory
        }
        _ = Darwin.close(descriptor)
    }

    private func createExclusiveOwnedTemporaryFile(at url: URL) throws -> FileHandle {
        guard isOwnedTemporaryFile(url) else {
            throw NotebookAudioCoordinatorError.unsafeTemporaryFile
        }
        let directoryDescriptor = openAbsolutePathWithoutFollowingLinks(
            at: workingDirectory,
            finalFlags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else {
            throw NotebookAudioCoordinatorError.unsafeWorkingDirectory
        }
        defer { _ = Darwin.close(directoryDescriptor) }

        let descriptor = url.lastPathComponent.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw NotebookAudioCoordinatorError.unsafeTemporaryFile
        }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1 else {
            _ = Darwin.close(descriptor)
            throw NotebookAudioCoordinatorError.unsafeTemporaryFile
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func isSHA256Digest(_ value: String) -> Bool {
        value.utf8.count == 64
            && value == value.lowercased()
            && value.unicodeScalars.allSatisfy {
                (48 ... 57).contains($0.value) || (97 ... 102).contains($0.value)
            }
    }

    private func hexadecimalDigest(_ digest: CryptoKit.SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private func isOwnedTemporaryFile(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        return standardized.deletingLastPathComponent().standardizedFileURL == workingDirectory
            && ownedTemporaryFiles.contains(standardized)
    }

    private func removeOwnedTemporaryFile(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard isOwnedTemporaryFile(standardized) else { return }
        let directoryDescriptor = openAbsolutePathWithoutFollowingLinks(
            at: workingDirectory,
            finalFlags: O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryDescriptor >= 0 else { return }
        defer { _ = Darwin.close(directoryDescriptor) }
        let result = standardized.lastPathComponent.withCString {
            Darwin.unlinkat(directoryDescriptor, $0, 0)
        }
        if result == 0 || errno == ENOENT {
            ownedTemporaryFiles.remove(standardized)
        }
    }
}
