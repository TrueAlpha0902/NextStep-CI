@preconcurrency import AVFoundation
import Foundation

public enum AudioTimelineError: LocalizedError, Equatable, Sendable {
    case permissionDenied
    case alreadyRecording
    case notRecording
    case audioSessionBusy
    case invalidDestination
    case couldNotStart
    case couldNotPlay
    case invalidSeekTime

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: "Microphone access is required to record audio."
        case .alreadyRecording: "A recording is already in progress."
        case .notRecording: "There is no active recording."
        case .audioSessionBusy: "Another audio operation is already using the audio session."
        case .invalidDestination: "The audio recording destination is invalid or already exists."
        case .couldNotStart: "The audio recording could not be started."
        case .couldNotPlay: "The audio file could not be played."
        case .invalidSeekTime: "The requested playback time is invalid."
        }
    }
}

public enum AudioTimelineMappingError: LocalizedError, Equatable, Sendable {
    case invalidLookupTime
    case invalidSegmentStartTime(UUID)
    case invalidSegmentDuration(UUID)
    case invalidSegmentConfidence(UUID)
    case invalidMarkTime(UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidLookupTime:
            "The requested timeline lookup time is invalid."
        case .invalidSegmentStartTime:
            "A transcript segment has an invalid start time."
        case .invalidSegmentDuration:
            "A transcript segment has an invalid duration."
        case .invalidSegmentConfidence:
            "A transcript segment has an invalid confidence value."
        case .invalidMarkTime:
            "An audio timeline mark has an invalid time."
        }
    }
}

public protocol AudioTimelineRecording: Sendable {
    func requestPermission() async -> Bool
    func startRecording(to fileURL: URL) async throws -> UUID
    func addMark(commandID: UUID, pageID: UUID) async throws
    /// Returns the same monotonic recording clock used for timeline marks.
    /// Replay mutation events must never derive their position from wall time.
    func currentRecordingTime() async throws -> TimeInterval
    func stopRecording() async throws -> AudioRecordingResult
    func cancelRecording() async
}

public extension AudioTimelineRecording {
    /// Compatibility default for lightweight recorders. Production recorders
    /// must override this so mutation history can share the audio clock.
    func currentRecordingTime() async throws -> TimeInterval {
        throw AudioTimelineError.notRecording
    }
}

/// A Foundation-only boundary for playback that can be replaced by a test double.
public protocol AudioTimelinePlaying: Sendable {
    func play(fileURL: URL, from time: TimeInterval) async throws
    func pause() async
    func resume() async throws
    func stop() async
    func seek(to time: TimeInterval) async throws
    func currentState() async -> AudioPlaybackState
}

public protocol AudioSessionCoordinating: Sendable {
    func acquire(ownerID: UUID, usage: AudioSessionUsage) async throws
    func release(ownerID: UUID) async
}

private protocol AudioSessionDriving: Sendable {
    func activate(for usage: AudioSessionUsage) throws
    func deactivate() throws
}

private final class SystemAudioSessionDriver: AudioSessionDriving, @unchecked Sendable {
    private let session: AVAudioSession

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
    }

    func activate(for usage: AudioSessionUsage) throws {
        switch usage {
        case .recording:
            try session.setCategory(
                .playAndRecord,
                mode: .spokenAudio,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
        case .playback:
            try session.setCategory(.playback, mode: .spokenAudio)
        }
        try session.setActive(true)
    }

    func deactivate() throws {
        try session.setActive(false, options: .notifyOthersOnDeactivation)
    }
}

private final class ClosureAudioSessionDriver: AudioSessionDriving, @unchecked Sendable {
    private let activation: @Sendable (AudioSessionUsage) throws -> Void
    private let deactivation: @Sendable () throws -> Void

    init(
        activation: @escaping @Sendable (AudioSessionUsage) throws -> Void,
        deactivation: @escaping @Sendable () throws -> Void
    ) {
        self.activation = activation
        self.deactivation = deactivation
    }

    func activate(for usage: AudioSessionUsage) throws {
        try activation(usage)
    }

    func deactivate() throws {
        try deactivation()
    }
}

/// Serializes all access to the process-wide `AVAudioSession` and grants one logical owner at a time.
public actor AudioSessionCoordinator: AudioSessionCoordinating {
    public static let shared = AudioSessionCoordinator()

    private let driver: any AudioSessionDriving
    private var state: AudioSessionCoordinatorState = .idle

    public init() {
        driver = SystemAudioSessionDriver()
    }

    init(
        activation: @escaping @Sendable (AudioSessionUsage) throws -> Void,
        deactivation: @escaping @Sendable () throws -> Void
    ) {
        driver = ClosureAudioSessionDriver(
            activation: activation,
            deactivation: deactivation
        )
    }

    public func acquire(ownerID: UUID, usage: AudioSessionUsage) async throws {
        try Task.checkCancellation()
        if let activeOwnerID = state.ownerID {
            guard activeOwnerID == ownerID, state.usage == usage else {
                throw AudioTimelineError.audioSessionBusy
            }
            return
        }

        do {
            try driver.activate(for: usage)
            try Task.checkCancellation()
        } catch {
            try? driver.deactivate()
            throw error
        }
        state = AudioSessionCoordinatorState(ownerID: ownerID, usage: usage)
    }

    public func release(ownerID: UUID) async {
        guard state.ownerID == ownerID else { return }
        try? driver.deactivate()
        state = .idle
    }

    public func currentState() -> AudioSessionCoordinatorState {
        state
    }
}

public extension AudioTimelinePlaying {
    func play(fileURL: URL) async throws {
        try await play(fileURL: fileURL, from: 0)
    }
}

/// Pure timeline matching. Segments retain their input order, while marks may be unsorted.
public enum AudioTimelineMapper {
    public static func map(
        segments: [TranscriptSegment],
        to marks: [AudioTimelineMark]
    ) throws -> [TranscriptTimelineMapping] {
        let orderedMarks = try validatedAndOrderedMarks(marks)

        return try segments.map { segment in
            guard segment.startTime.isFinite, segment.startTime >= 0 else {
                throw AudioTimelineMappingError.invalidSegmentStartTime(segment.id)
            }
            guard segment.duration.isFinite, segment.duration >= 0 else {
                throw AudioTimelineMappingError.invalidSegmentDuration(segment.id)
            }
            guard segment.confidence.isFinite, (0...1).contains(segment.confidence) else {
                throw AudioTimelineMappingError.invalidSegmentConfidence(segment.id)
            }
            return TranscriptTimelineMapping(
                segment: segment,
                mark: mostRecentMark(at: segment.startTime, inOrderedMarks: orderedMarks)
            )
        }
    }

    public static func mostRecentMark(
        at time: TimeInterval,
        in marks: [AudioTimelineMark]
    ) throws -> AudioTimelineMark? {
        guard time.isFinite, time >= 0 else {
            throw AudioTimelineMappingError.invalidLookupTime
        }
        return mostRecentMark(at: time, inOrderedMarks: try validatedAndOrderedMarks(marks))
    }

    private static func validatedAndOrderedMarks(
        _ marks: [AudioTimelineMark]
    ) throws -> [AudioTimelineMark] {
        let indexedMarks = try marks.enumerated().map { index, mark in
            guard mark.time.isFinite, mark.time >= 0 else {
                throw AudioTimelineMappingError.invalidMarkTime(mark.id)
            }
            return (index: index, mark: mark)
        }

        return indexedMarks.sorted { lhs, rhs in
            if lhs.mark.time == rhs.mark.time {
                return lhs.index < rhs.index
            }
            return lhs.mark.time < rhs.mark.time
        }.map(\.mark)
    }

    private static func mostRecentMark(
        at time: TimeInterval,
        inOrderedMarks orderedMarks: [AudioTimelineMark]
    ) -> AudioTimelineMark? {
        var lowerBound = 0
        var upperBound = orderedMarks.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if orderedMarks[middle].time <= time {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound == 0 ? nil : orderedMarks[lowerBound - 1]
    }
}

public actor AudioTimelineRecorder: AudioTimelineRecording {
    private let sessionCoordinator: any AudioSessionCoordinating
    private var sessionLeaseID: UUID?
    private var recorder: AVAudioRecorder?
    private var recordingID: UUID?
    private var recordingURL: URL?
    private var startedAt: Date?
    private var marks: [AudioTimelineMark] = []
    private var isStarting = false
    private var startOperationID: UUID?

    public init(
        sessionCoordinator: any AudioSessionCoordinating = AudioSessionCoordinator.shared
    ) {
        self.sessionCoordinator = sessionCoordinator
    }

    public func requestPermission() async -> Bool {
        if Task.isCancelled { return false }
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        return granted && !Task.isCancelled
    }

    @discardableResult
    public func startRecording(to fileURL: URL) async throws -> UUID {
        guard recorder == nil, !isStarting else { throw AudioTimelineError.alreadyRecording }
        let operationID = UUID()
        isStarting = true
        startOperationID = operationID
        defer {
            isStarting = false
            if startOperationID == operationID {
                startOperationID = nil
            }
        }
        try ensureCurrentStart(operationID)
        try validateDestination(fileURL)
        guard await requestPermission() else {
            try ensureCurrentStart(operationID)
            throw AudioTimelineError.permissionDenied
        }
        try ensureCurrentStart(operationID)
        try validateDestination(fileURL)

        let parent = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
            throw AudioTimelineError.invalidDestination
        }

        let leaseID = UUID()
        var acquiredSession = false
        do {
            try await sessionCoordinator.acquire(
                ownerID: leaseID,
                usage: .recording
            )
            acquiredSession = true
            try ensureCurrentStart(operationID)
            sessionLeaseID = leaseID

            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVEncoderBitRateKey: 96_000
            ]
            let newRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            newRecorder.isMeteringEnabled = true
            guard newRecorder.prepareToRecord(), newRecorder.record() else {
                throw AudioTimelineError.couldNotStart
            }
            try ensureCurrentStart(operationID)

            let id = UUID()
            recorder = newRecorder
            recordingID = id
            recordingURL = fileURL
            startedAt = .now
            marks = []
            return id
        } catch {
            if sessionLeaseID == leaseID {
                sessionLeaseID = nil
            }
            if acquiredSession {
                await sessionCoordinator.release(ownerID: leaseID)
            }
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    public func addMark(commandID: UUID, pageID: UUID) async throws {
        guard let recorder else { throw AudioTimelineError.notRecording }
        let time = recorder.currentTime
        guard time.isFinite, time >= 0 else { throw AudioTimelineError.couldNotStart }
        marks.append(AudioTimelineMark(commandID: commandID, pageID: pageID, time: time))
    }

    public func currentRecordingTime() async throws -> TimeInterval {
        guard let recorder else { throw AudioTimelineError.notRecording }
        let time = recorder.currentTime
        guard time.isFinite, time >= 0 else {
            throw AudioTimelineError.couldNotStart
        }
        return time
    }

    public func stopRecording() async throws -> AudioRecordingResult {
        guard let recorder,
              let id = recordingID,
              let fileURL = recordingURL,
              let startedAt else {
            throw AudioTimelineError.notRecording
        }
        let duration = recorder.currentTime
        let completedMarks = marks
        let leaseID = sessionLeaseID
        recorder.stop()
        reset()
        if let leaseID {
            await sessionCoordinator.release(ownerID: leaseID)
        }

        guard duration.isFinite,
              duration >= 0,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            try? FileManager.default.removeItem(at: fileURL)
            throw AudioTimelineError.couldNotStart
        }
        return AudioRecordingResult(
            id: id,
            fileURL: fileURL,
            duration: duration,
            startedAt: startedAt,
            marks: completedMarks
        )
    }

    public func cancelRecording() async {
        startOperationID = nil
        let fileURL = recordingURL
        let leaseID = sessionLeaseID
        recorder?.stop()
        reset()
        if let leaseID {
            await sessionCoordinator.release(ownerID: leaseID)
        }
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    private func reset() {
        recorder = nil
        recordingID = nil
        recordingURL = nil
        startedAt = nil
        marks = []
        sessionLeaseID = nil
    }

    private func validateDestination(_ fileURL: URL) throws {
        guard fileURL.isFileURL,
              fileURL.pathExtension.caseInsensitiveCompare("m4a") == .orderedSame,
              !FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AudioTimelineError.invalidDestination
        }
        if let values = try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw AudioTimelineError.invalidDestination
        }
    }

    private func ensureCurrentStart(_ operationID: UUID) throws {
        try Task.checkCancellation()
        guard startOperationID == operationID else { throw CancellationError() }
    }
}

enum AudioPlaybackTermination: Equatable, Sendable {
    case finished
    case failed

    static let decodeError: Self = .failed

    static func completion(successfully flag: Bool) -> Self {
        flag ? .finished : .failed
    }
}

final class AudioPlayerDelegateBridge: NSObject, @MainActor AVAudioPlayerDelegate, @unchecked Sendable {
    private let completion: @Sendable (AudioPlaybackTermination) -> Void

    init(completion: @escaping @Sendable (AudioPlaybackTermination) -> Void) {
        self.completion = completion
    }

    @MainActor
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        completion(.completion(successfully: flag))
    }

    @MainActor
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        completion(.decodeError)
    }
}

public actor AudioTimelinePlayer: AudioTimelinePlaying {
    private let sessionCoordinator: any AudioSessionCoordinating
    private var sessionLeaseID: UUID?
    private var player: AVAudioPlayer?
    private var delegateBridge: AudioPlayerDelegateBridge?
    private var playbackGeneration: UUID?
    private var playbackStatus: AudioPlaybackStatus = .stopped
    private var loadedFileURL: URL?
    private var terminalState: AudioPlaybackState = .stopped
    private var transitionID: UUID?

    public init(
        sessionCoordinator: any AudioSessionCoordinating = AudioSessionCoordinator.shared
    ) {
        self.sessionCoordinator = sessionCoordinator
    }

    public func play(fileURL: URL, from time: TimeInterval = 0) async throws {
        let transitionID = try beginTransition()
        defer { finishTransition(transitionID) }

        try ensureCurrentTransition(transitionID)
        guard fileURL.isFileURL else { throw AudioTimelineError.couldNotPlay }
        try validatePlaybackTime(time)
        let values: URLResourceValues
        do {
            values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            throw AudioTimelineError.couldNotPlay
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AudioTimelineError.couldNotPlay
        }

        let newPlayer: AVAudioPlayer
        do {
            newPlayer = try AVAudioPlayer(contentsOf: fileURL)
        } catch {
            throw AudioTimelineError.couldNotPlay
        }
        let duration = newPlayer.duration
        guard duration.isFinite, duration >= 0 else { throw AudioTimelineError.couldNotPlay }
        guard time <= duration else { throw AudioTimelineError.invalidSeekTime }
        try ensureCurrentTransition(transitionID)

        clearCurrentPlayer()
        await releaseSessionLease()
        try ensureCurrentTransition(transitionID)

        let leaseID = UUID()
        do {
            try await sessionCoordinator.acquire(
                ownerID: leaseID,
                usage: .playback
            )
            try ensureCurrentTransition(transitionID)
            sessionLeaseID = leaseID

            let generation = UUID()
            let bridge = AudioPlayerDelegateBridge { [weak self] termination in
                Task { [weak self] in
                    await self?.playbackDidTerminate(
                        generation: generation,
                        termination: termination
                    )
                }
            }
            await MainActor.run {
                newPlayer.delegate = bridge
            }
            newPlayer.currentTime = time
            player = newPlayer
            delegateBridge = bridge
            playbackGeneration = generation
            loadedFileURL = fileURL

            guard newPlayer.prepareToPlay(), newPlayer.play() else {
                throw AudioTimelineError.couldNotPlay
            }
            playbackStatus = .playing
            try ensureCurrentTransition(transitionID)
        } catch {
            newPlayer.delegate = nil
            newPlayer.stop()
            if player === newPlayer {
                clearCurrentPlayer()
            }
            if sessionLeaseID == leaseID {
                sessionLeaseID = nil
            }
            await sessionCoordinator.release(ownerID: leaseID)
            if error is CancellationError {
                throw error
            }
            if let timelineError = error as? AudioTimelineError {
                throw timelineError
            }
            throw AudioTimelineError.couldNotPlay
        }
    }

    public func pause() async {
        transitionID = nil
        guard let player else {
            await releaseSessionLease()
            return
        }
        guard playbackStatus != .paused else { return }
        guard player.isPlaying else {
            // AVAudioPlayer's delegate is the authoritative source for natural
            // completion versus a decode failure. Keep the lease and loaded
            // state until that callback arrives instead of collapsing both
            // terminal outcomes into `.stopped`.
            return
        }
        player.pause()
        playbackStatus = .paused
        await releaseSessionLease()
    }

    public func resume() async throws {
        let transitionID = try beginTransition()
        defer { finishTransition(transitionID) }
        guard let pausedPlayer = player, playbackStatus == .paused else {
            throw AudioTimelineError.couldNotPlay
        }
        try ensureCurrentTransition(transitionID)

        let leaseID = UUID()
        do {
            try await sessionCoordinator.acquire(
                ownerID: leaseID,
                usage: .playback
            )
            try ensureCurrentTransition(transitionID)
            sessionLeaseID = leaseID
            guard player === pausedPlayer, playbackStatus == .paused else {
                throw CancellationError()
            }
            guard pausedPlayer.play() else {
                throw AudioTimelineError.couldNotPlay
            }
            playbackStatus = .playing
            try ensureCurrentTransition(transitionID)
        } catch {
            if player === pausedPlayer {
                pausedPlayer.pause()
                playbackStatus = .paused
            }
            if sessionLeaseID == leaseID {
                sessionLeaseID = nil
            }
            await sessionCoordinator.release(ownerID: leaseID)
            if error is CancellationError {
                throw error
            }
            if let timelineError = error as? AudioTimelineError {
                throw timelineError
            }
            throw AudioTimelineError.couldNotPlay
        }
    }

    public func stop() async {
        transitionID = nil
        clearCurrentPlayer()
        await releaseSessionLease()
    }

    public func seek(to time: TimeInterval) async throws {
        try validatePlaybackTime(time)
        guard let player else { throw AudioTimelineError.couldNotPlay }
        let duration = player.duration
        guard duration.isFinite, duration >= 0, time <= duration else {
            throw AudioTimelineError.invalidSeekTime
        }
        player.currentTime = time
    }

    public func currentState() async -> AudioPlaybackState {
        guard let player else { return terminalState }
        return AudioPlaybackState(
            status: playbackStatus,
            fileURL: loadedFileURL,
            currentTime: sanitizedTime(player.currentTime, upperBound: player.duration),
            duration: sanitizedDuration(player.duration)
        )
    }

    public var currentTime: TimeInterval {
        guard let player else { return terminalState.currentTime }
        return sanitizedTime(player.currentTime, upperBound: player.duration)
    }

    public var duration: TimeInterval {
        guard let player else { return terminalState.duration }
        return sanitizedDuration(player.duration)
    }
    public var isPlaying: Bool { player?.isPlaying ?? false }

    private func playbackDidTerminate(
        generation: UUID,
        termination: AudioPlaybackTermination
    ) async {
        guard playbackGeneration == generation, let player else { return }
        let duration = sanitizedDuration(player.duration)
        let state = AudioPlaybackState(
            status: termination == .finished ? .finished : .failed,
            fileURL: loadedFileURL,
            currentTime: termination == .finished
                ? duration
                : sanitizedTime(player.currentTime, upperBound: duration),
            duration: duration
        )
        clearCurrentPlayer(terminalState: state)
        await releaseSessionLease()
    }

    private func beginTransition() throws -> UUID {
        guard transitionID == nil else { throw AudioTimelineError.couldNotPlay }
        let id = UUID()
        transitionID = id
        return id
    }

    private func ensureCurrentTransition(_ id: UUID) throws {
        try Task.checkCancellation()
        guard transitionID == id else { throw CancellationError() }
    }

    private func finishTransition(_ id: UUID) {
        if transitionID == id {
            transitionID = nil
        }
    }

    private func validatePlaybackTime(_ time: TimeInterval) throws {
        guard time.isFinite, time >= 0 else { throw AudioTimelineError.invalidSeekTime }
    }

    private func sanitizedDuration(_ duration: TimeInterval) -> TimeInterval {
        duration.isFinite && duration >= 0 ? duration : 0
    }

    private func sanitizedTime(
        _ time: TimeInterval,
        upperBound duration: TimeInterval
    ) -> TimeInterval {
        guard time.isFinite, time >= 0 else { return 0 }
        return min(time, sanitizedDuration(duration))
    }

    private func clearCurrentPlayer(
        terminalState: AudioPlaybackState = .stopped
    ) {
        player?.delegate = nil
        player?.stop()
        player = nil
        delegateBridge = nil
        playbackGeneration = nil
        loadedFileURL = nil
        playbackStatus = .stopped
        self.terminalState = terminalState
    }

    private func releaseSessionLease() async {
        guard let leaseID = sessionLeaseID else { return }
        sessionLeaseID = nil
        await sessionCoordinator.release(ownerID: leaseID)
    }
}
