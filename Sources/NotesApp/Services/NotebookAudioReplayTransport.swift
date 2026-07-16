import Foundation
import NotesCore
import NotesServices

protocol NotebookAudioReplayCoordinating: Sendable {
    func startReplayPlayback(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        from time: TimeInterval,
        ownerID: UUID
    ) async throws

    func pauseReplayPlayback(ownerID: UUID) async throws
    func resumeReplayPlayback(ownerID: UUID) async throws
    func seekReplayPlayback(to time: TimeInterval, ownerID: UUID) async throws
    func stopReplayPlayback(ownerID: UUID) async
    func replayPlaybackState(ownerID: UUID) async -> AudioPlaybackState?
}

extension NotebookAudioCoordinator: NotebookAudioReplayCoordinating {}

enum NotebookAudioReplayTransportError: Error, Equatable, Sendable {
    case ownershipLost
}

/// Serializes ownership above the shared notebook-audio coordinator. A new
/// Replay owner may replace an older Replay owner, but neither owner can pause,
/// seek, or stop ordinary playback, recording, or transcription.
@MainActor
final class NotebookAudioReplayPlaybackBroker {
    private struct PendingStop {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let coordinator: any NotebookAudioReplayCoordinating
    private var activeOwnerID: UUID?
    private var pendingStop: PendingStop?

    init(coordinator: any NotebookAudioReplayCoordinating) {
        self.coordinator = coordinator
    }

    func start(
        ownerID: UUID,
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        from time: TimeInterval
    ) async throws {
        await waitForPendingStop()

        if let previousOwnerID = activeOwnerID {
            // Reserve the replacement before suspension. A delayed stop from
            // the old editor will now see an ownership mismatch and do nothing.
            activeOwnerID = ownerID
            await stopCoordinatorPlayback(ownerID: previousOwnerID)
            guard activeOwnerID == ownerID else {
                throw CancellationError()
            }
        } else {
            activeOwnerID = ownerID
        }

        do {
            try await coordinator.startReplayPlayback(
                notebookID: notebookID,
                sessionID: sessionID,
                from: time,
                ownerID: ownerID
            )
            guard activeOwnerID == ownerID else {
                await coordinator.stopReplayPlayback(ownerID: ownerID)
                throw CancellationError()
            }
        } catch {
            if activeOwnerID == ownerID {
                activeOwnerID = nil
            }
            throw error
        }
    }

    func pause(ownerID: UUID) async throws {
        try requireOwnership(ownerID)
        try await coordinator.pauseReplayPlayback(ownerID: ownerID)
        try requireOwnership(ownerID)
    }

    func resume(ownerID: UUID) async throws {
        try requireOwnership(ownerID)
        try await coordinator.resumeReplayPlayback(ownerID: ownerID)
        try requireOwnership(ownerID)
    }

    func seek(to time: TimeInterval, ownerID: UUID) async throws {
        try requireOwnership(ownerID)
        try await coordinator.seekReplayPlayback(to: time, ownerID: ownerID)
        try requireOwnership(ownerID)
    }

    func stop(ownerID: UUID) async {
        guard activeOwnerID == ownerID else { return }
        activeOwnerID = nil
        await waitForPendingStop()
        await stopCoordinatorPlayback(ownerID: ownerID)
    }

    func snapshot(ownerID: UUID) async throws -> AudioPlaybackState {
        try requireOwnership(ownerID)
        let coordinatorState = await coordinator.replayPlaybackState(
            ownerID: ownerID
        )
        try requireOwnership(ownerID)
        guard let state = coordinatorState else {
            activeOwnerID = nil
            throw NotebookAudioReplayTransportError.ownershipLost
        }
        switch state.status {
        case .playing, .paused:
            break
        case .stopped, .finished, .failed:
            activeOwnerID = nil
        }
        return state
    }

    private func requireOwnership(_ ownerID: UUID) throws {
        guard activeOwnerID == ownerID else {
            throw NotebookAudioReplayTransportError.ownershipLost
        }
    }

    private func stopCoordinatorPlayback(ownerID: UUID) async {
        let operationID = UUID()
        let coordinator = self.coordinator
        let task = Task {
            await coordinator.stopReplayPlayback(ownerID: ownerID)
        }
        pendingStop = PendingStop(id: operationID, task: task)
        await task.value
        if pendingStop?.id == operationID {
            pendingStop = nil
        }
    }

    private func waitForPendingStop() async {
        guard let operation = pendingStop else { return }
        await operation.task.value
        if pendingStop?.id == operation.id {
            pendingStop = nil
        }
    }
}

@MainActor
final class NotebookAudioReplayTransport: NoteReplayAudioTransport {
    private let broker: NotebookAudioReplayPlaybackBroker
    private let ownerID: UUID
    private var lastSnapshot = NoteReplayAudioPlaybackSnapshot(
        status: .stopped,
        currentTime: 0
    )
    private var terminalSnapshot: NoteReplayAudioPlaybackSnapshot?

    init(
        broker: NotebookAudioReplayPlaybackBroker,
        ownerID: UUID = UUID()
    ) {
        self.broker = broker
        self.ownerID = ownerID
    }

    func startReplayAudio(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        from time: TimeInterval
    ) async throws {
        terminalSnapshot = nil
        lastSnapshot = NoteReplayAudioPlaybackSnapshot(
            status: .stopped,
            currentTime: max(time.isFinite ? time : 0, 0)
        )
        try await broker.start(
            ownerID: ownerID,
            notebookID: notebookID,
            sessionID: sessionID,
            from: time
        )
        lastSnapshot = NoteReplayAudioPlaybackSnapshot(
            status: .playing,
            currentTime: max(time.isFinite ? time : 0, 0)
        )
    }

    func pauseReplayAudio() async throws {
        try await broker.pause(ownerID: ownerID)
    }

    func resumeReplayAudio() async throws {
        try await broker.resume(ownerID: ownerID)
    }

    func seekReplayAudio(to time: TimeInterval) async throws {
        try await broker.seek(to: time, ownerID: ownerID)
        lastSnapshot = NoteReplayAudioPlaybackSnapshot(
            status: lastSnapshot.status,
            currentTime: max(time.isFinite ? time : 0, 0)
        )
    }

    func stopReplayAudio() async {
        await broker.stop(ownerID: ownerID)
        let stopped = NoteReplayAudioPlaybackSnapshot(
            status: .stopped,
            currentTime: 0
        )
        lastSnapshot = stopped
        terminalSnapshot = stopped
    }

    func replayAudioPlaybackSnapshot() async throws
        -> NoteReplayAudioPlaybackSnapshot {
        if let terminalSnapshot { return terminalSnapshot }
        let state = try await broker.snapshot(ownerID: ownerID)

        let snapshot: NoteReplayAudioPlaybackSnapshot
        switch state.status {
        case .playing:
            snapshot = .init(status: .playing, currentTime: state.currentTime)
        case .paused:
            snapshot = .init(status: .paused, currentTime: state.currentTime)
        case .finished:
            snapshot = .init(status: .finished, currentTime: state.duration)
        case .failed:
            snapshot = .init(status: .failed, currentTime: state.currentTime)
        case .stopped:
            snapshot = .init(status: .stopped, currentTime: state.currentTime)
        }
        lastSnapshot = snapshot
        if snapshot.status == .finished
            || snapshot.status == .failed
            || snapshot.status == .stopped {
            terminalSnapshot = snapshot
        }
        return snapshot
    }
}
