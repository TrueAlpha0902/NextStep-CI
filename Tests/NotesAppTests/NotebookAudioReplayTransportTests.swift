import Foundation
import NotesCore
import NotesServices
import XCTest
@testable import NotesApp

final class NotebookAudioReplayTransportTests: XCTestCase {
    @MainActor
    func testTransportMapsEveryControlAndTerminalOutcomeExactly() async throws {
        let coordinator = ReplayCoordinatorFake(duration: 8)
        let broker = NotebookAudioReplayPlaybackBroker(coordinator: coordinator)
        let ownerID = UUID()
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        let transport = NotebookAudioReplayTransport(
            broker: broker,
            ownerID: ownerID
        )

        try await transport.startReplayAudio(
            notebookID: notebookID,
            sessionID: sessionID,
            from: 2
        )
        let startCalls = await coordinator.recordedStartCalls()
        XCTAssertEqual(
            startCalls,
            [.init(
                notebookID: notebookID,
                sessionID: sessionID,
                time: 2,
                ownerID: ownerID
            )]
        )
        var snapshot = try await transport.replayAudioPlaybackSnapshot()
        XCTAssertEqual(snapshot, .init(status: .playing, currentTime: 2))

        try await transport.pauseReplayAudio()
        snapshot = try await transport.replayAudioPlaybackSnapshot()
        XCTAssertEqual(snapshot, .init(status: .paused, currentTime: 2))

        try await transport.seekReplayAudio(to: 4)
        try await transport.resumeReplayAudio()
        snapshot = try await transport.replayAudioPlaybackSnapshot()
        let seekTimes = await coordinator.recordedSeekTimes()
        XCTAssertEqual(seekTimes, [4])
        XCTAssertEqual(snapshot, .init(status: .playing, currentTime: 4))

        await coordinator.setState(.init(
            status: .finished,
            fileURL: nil,
            currentTime: 7.9,
            duration: 8
        ))
        snapshot = try await transport.replayAudioPlaybackSnapshot()
        XCTAssertEqual(snapshot, .init(status: .finished, currentTime: 8))
        let repeatedFinish = try await transport.replayAudioPlaybackSnapshot()
        XCTAssertEqual(repeatedFinish, snapshot)

        await transport.stopReplayAudio()
        snapshot = try await transport.replayAudioPlaybackSnapshot()
        XCTAssertEqual(snapshot, .init(status: .stopped, currentTime: 0))

        try await transport.startReplayAudio(
            notebookID: notebookID,
            sessionID: sessionID,
            from: 7.99
        )
        await coordinator.setState(.init(
            status: .failed,
            fileURL: nil,
            currentTime: 7.99,
            duration: 8
        ))
        snapshot = try await transport.replayAudioPlaybackSnapshot()
        XCTAssertEqual(snapshot, .init(status: .failed, currentTime: 7.99))
    }

    @MainActor
    func testStaleOwnerStopCannotStopReplacementOwner() async throws {
        let coordinator = ReplayCoordinatorFake(duration: 10)
        let broker = NotebookAudioReplayPlaybackBroker(coordinator: coordinator)
        let firstOwnerID = UUID()
        let secondOwnerID = UUID()
        let first = NotebookAudioReplayTransport(
            broker: broker,
            ownerID: firstOwnerID
        )
        let second = NotebookAudioReplayTransport(
            broker: broker,
            ownerID: secondOwnerID
        )
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()

        try await first.startReplayAudio(
            notebookID: notebookID,
            sessionID: sessionID,
            from: 9.99
        )
        try await second.startReplayAudio(
            notebookID: notebookID,
            sessionID: sessionID,
            from: 3
        )
        do {
            _ = try await first.replayAudioPlaybackSnapshot()
            XCTFail("A stale near-end owner must report ownership loss")
        } catch let error as NotebookAudioReplayTransportError {
            XCTAssertEqual(error, .ownershipLost)
        }
        await first.stopReplayAudio()

        let activeOwnerID = await coordinator.currentOwnerID()
        let stoppedOwnerIDs = await coordinator.recordedStopOwnerIDs()
        let secondSnapshot = try await second.replayAudioPlaybackSnapshot()
        XCTAssertEqual(activeOwnerID, secondOwnerID)
        XCTAssertEqual(stoppedOwnerIDs, [firstOwnerID])
        XCTAssertEqual(secondSnapshot, .init(status: .playing, currentTime: 3))

        do {
            try await first.pauseReplayAudio()
            XCTFail("A stale owner must not pause the replacement owner")
        } catch let error as NotebookAudioReplayTransportError {
            XCTAssertEqual(error, .ownershipLost)
        }
    }

    @MainActor
    func testReplacementCancelsOwnerThatIsStillPreparing() async throws {
        let coordinator = ReplayCoordinatorFake(duration: 10)
        let broker = NotebookAudioReplayPlaybackBroker(coordinator: coordinator)
        let firstOwnerID = UUID()
        let secondOwnerID = UUID()
        let gate = ReplayStartGate()
        await coordinator.blockStart(ownerID: firstOwnerID, on: gate)
        let first = NotebookAudioReplayTransport(
            broker: broker,
            ownerID: firstOwnerID
        )
        let second = NotebookAudioReplayTransport(
            broker: broker,
            ownerID: secondOwnerID
        )
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()

        let firstStart = Task { @MainActor in
            try await first.startReplayAudio(
                notebookID: notebookID,
                sessionID: sessionID,
                from: 0
            )
        }
        await gate.waitUntilArrived()
        try await second.startReplayAudio(
            notebookID: notebookID,
            sessionID: sessionID,
            from: 5
        )
        await gate.open()

        do {
            try await firstStart.value
            XCTFail("The replaced preparing owner must be cancelled")
        } catch {
            // Cancellation is the expected result for the replaced start.
        }
        let activeOwnerID = await coordinator.currentOwnerID()
        let stoppedOwnerIDs = await coordinator.recordedStopOwnerIDs()
        let secondSnapshot = try await second.replayAudioPlaybackSnapshot()
        XCTAssertEqual(activeOwnerID, secondOwnerID)
        XCTAssertEqual(stoppedOwnerIDs, [firstOwnerID])
        XCTAssertEqual(secondSnapshot, .init(status: .playing, currentTime: 5))
    }

    @MainActor
    func testBusyNonReplayOperationIsNeverStoppedOrStolen() async throws {
        let coordinator = ReplayCoordinatorFake(duration: 10)
        await coordinator.setNonReplayBusy(true)
        let broker = NotebookAudioReplayPlaybackBroker(coordinator: coordinator)
        let transport = NotebookAudioReplayTransport(broker: broker)

        do {
            try await transport.startReplayAudio(
                notebookID: NotebookID(),
                sessionID: AudioSessionID(),
                from: 0
            )
            XCTFail("Replay must not steal a non-Replay audio operation")
        } catch let error as NotebookAudioCoordinatorError {
            XCTAssertEqual(error, .busy(.playing))
        }

        let remainsBusy = await coordinator.isNonReplayBusy()
        let stoppedOwnerIDs = await coordinator.recordedStopOwnerIDs()
        let activeOwnerID = await coordinator.currentOwnerID()
        XCTAssertTrue(remainsBusy)
        XCTAssertTrue(stoppedOwnerIDs.isEmpty)
        XCTAssertNil(activeOwnerID)
    }
}

private actor ReplayCoordinatorFake: NotebookAudioReplayCoordinating {
    struct StartCall: Equatable, Sendable {
        let notebookID: NotebookID
        let sessionID: AudioSessionID
        let time: TimeInterval
        let ownerID: UUID
    }

    private let duration: TimeInterval
    private var activeOwnerID: UUID?
    private var state: AudioPlaybackState = .stopped
    private var startCalls: [StartCall] = []
    private var seekTimes: [TimeInterval] = []
    private var stopOwnerIDs: [UUID] = []
    private var startGates: [UUID: ReplayStartGate] = [:]
    private var nonReplayBusy = false

    init(duration: TimeInterval) {
        self.duration = duration
    }

    func startReplayPlayback(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        from time: TimeInterval,
        ownerID: UUID
    ) async throws {
        guard !nonReplayBusy else {
            throw NotebookAudioCoordinatorError.busy(.playing)
        }
        startCalls.append(.init(
            notebookID: notebookID,
            sessionID: sessionID,
            time: time,
            ownerID: ownerID
        ))
        activeOwnerID = ownerID
        if let gate = startGates.removeValue(forKey: ownerID) {
            await gate.wait()
        }
        guard activeOwnerID == ownerID else { throw CancellationError() }
        state = .init(
            status: .playing,
            fileURL: nil,
            currentTime: time,
            duration: duration
        )
    }

    func pauseReplayPlayback(ownerID: UUID) async throws {
        try requireOwner(ownerID)
        if state.status == .playing { state.status = .paused }
    }

    func resumeReplayPlayback(ownerID: UUID) async throws {
        try requireOwner(ownerID)
        guard state.status == .paused else {
            throw NotebookAudioCoordinatorError.noActivePlayback
        }
        state.status = .playing
    }

    func seekReplayPlayback(to time: TimeInterval, ownerID: UUID) async throws {
        try requireOwner(ownerID)
        seekTimes.append(time)
        state.currentTime = time
    }

    func stopReplayPlayback(ownerID: UUID) async {
        guard activeOwnerID == ownerID else { return }
        stopOwnerIDs.append(ownerID)
        activeOwnerID = nil
        state = .stopped
    }

    func replayPlaybackState(ownerID: UUID) async -> AudioPlaybackState? {
        guard activeOwnerID == ownerID else { return nil }
        let result = state
        if result.status == .stopped
            || result.status == .finished
            || result.status == .failed {
            activeOwnerID = nil
        }
        return result
    }

    func setState(_ state: AudioPlaybackState) {
        self.state = state
    }

    func blockStart(ownerID: UUID, on gate: ReplayStartGate) {
        startGates[ownerID] = gate
    }

    func setNonReplayBusy(_ isBusy: Bool) {
        nonReplayBusy = isBusy
    }

    func isNonReplayBusy() -> Bool { nonReplayBusy }
    func currentOwnerID() -> UUID? { activeOwnerID }
    func recordedStartCalls() -> [StartCall] { startCalls }
    func recordedSeekTimes() -> [TimeInterval] { seekTimes }
    func recordedStopOwnerIDs() -> [UUID] { stopOwnerIDs }

    private func requireOwner(_ ownerID: UUID) throws {
        guard activeOwnerID == ownerID else {
            throw NotebookAudioCoordinatorError.noActivePlayback
        }
    }
}

private actor ReplayStartGate {
    private var isOpen = false
    private var hasArrived = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        hasArrived = true
        let arrivals = arrivalWaiters
        arrivalWaiters.removeAll()
        arrivals.forEach { $0.resume() }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitUntilArrived() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let blocked = waiters
        waiters.removeAll()
        blocked.forEach { $0.resume() }
    }
}
