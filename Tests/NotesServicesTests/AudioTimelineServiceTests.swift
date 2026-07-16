import Foundation
import Testing
@testable import NotesServices

@Test("Transcript times map to the most recent page mark at each boundary")
func transcriptTimelineBoundaryMapping() throws {
    let firstPageID = UUID()
    let secondPageID = UUID()
    let thirdPageID = UUID()
    let firstMark = AudioTimelineMark(commandID: UUID(), pageID: firstPageID, time: 1)
    let secondMark = AudioTimelineMark(commandID: UUID(), pageID: secondPageID, time: 5)
    let thirdMark = AudioTimelineMark(commandID: UUID(), pageID: thirdPageID, time: 10)
    let segments = [0.999, 1, 4.999, 5, 10, 40].map {
        TranscriptSegment(text: "\($0)", startTime: $0, duration: 0.25, confidence: 1)
    }

    let mappings = try AudioTimelineMapper.map(
        segments: segments,
        to: [thirdMark, firstMark, secondMark]
    )

    #expect(mappings.map(\.pageID) == [nil, firstPageID, firstPageID, secondPageID, thirdPageID, thirdPageID])
    #expect(mappings.map(\.segment.id) == segments.map(\.id))
}

@Test("The last input mark wins when multiple page marks share a timestamp")
func equalTimelineMarkBoundaryUsesLastInputMark() throws {
    let earlierInput = AudioTimelineMark(commandID: UUID(), pageID: UUID(), time: 3)
    let laterInput = AudioTimelineMark(commandID: UUID(), pageID: UUID(), time: 3)

    let match = try AudioTimelineMapper.mostRecentMark(
        at: 3,
        in: [earlierInput, laterInput]
    )

    #expect(match == laterInput)
}

@Test("Timeline mapping rejects negative and non-finite times")
func timelineMappingRejectsInvalidTimes() throws {
    let invalidMark = AudioTimelineMark(commandID: UUID(), pageID: UUID(), time: .infinity)
    #expect(throws: AudioTimelineMappingError.invalidMarkTime(invalidMark.id)) {
        try AudioTimelineMapper.mostRecentMark(at: 0, in: [invalidMark])
    }

    let invalidSegment = TranscriptSegment(
        text: "Invalid",
        startTime: -0.001,
        duration: 1,
        confidence: 1
    )
    #expect(throws: AudioTimelineMappingError.invalidSegmentStartTime(invalidSegment.id)) {
        try AudioTimelineMapper.map(segments: [invalidSegment], to: [])
    }

    let invalidDuration = TranscriptSegment(
        text: "Invalid duration",
        startTime: 0,
        duration: .infinity,
        confidence: 1
    )
    #expect(throws: AudioTimelineMappingError.invalidSegmentDuration(invalidDuration.id)) {
        try AudioTimelineMapper.map(segments: [invalidDuration], to: [])
    }

    let invalidConfidence = TranscriptSegment(
        text: "Invalid confidence",
        startTime: 0,
        duration: 1,
        confidence: 1.01
    )
    #expect(throws: AudioTimelineMappingError.invalidSegmentConfidence(invalidConfidence.id)) {
        try AudioTimelineMapper.map(segments: [invalidConfidence], to: [])
    }

    #expect(throws: AudioTimelineMappingError.invalidLookupTime) {
        try AudioTimelineMapper.mostRecentMark(at: .nan, in: [])
    }
}

@Test("Playback exposes deterministic stopped state and validates seek before touching audio")
func playbackStateAndSeekValidation() async {
    let player: any AudioTimelinePlaying = AudioTimelinePlayer()

    #expect(await player.currentState() == .stopped)
    await #expect(throws: AudioTimelineError.invalidSeekTime) {
        try await player.seek(to: -.infinity)
    }
    await #expect(throws: AudioTimelineError.invalidSeekTime) {
        try await player.seek(to: -0.001)
    }
    await #expect(throws: AudioTimelineError.couldNotPlay) {
        try await player.seek(to: 0)
    }
    await #expect(throws: AudioTimelineError.couldNotPlay) {
        try await player.resume()
    }

    await player.pause()
    await player.stop()
    #expect(await player.currentState() == .stopped)
}

@Test("AVAudioPlayer terminal callbacks preserve success versus failure")
func playbackDelegateTerminalOutcomeMapping() {
    #expect(AudioPlaybackTermination.completion(successfully: true) == .finished)
    #expect(AudioPlaybackTermination.completion(successfully: false) == .failed)
    #expect(AudioPlaybackTermination.decodeError == .failed)
}

@Test("Playback protocol is injectable without AVFoundation types")
func playbackProtocolSupportsTestDoubles() async throws {
    let fileURL = URL(fileURLWithPath: "/tmp/injected.m4a")
    let fake: any AudioTimelinePlaying = PlaybackFake()

    try await fake.play(fileURL: fileURL)
    try await fake.seek(to: 2.5)
    await fake.pause()

    let state = await fake.currentState()
    #expect(state.status == .paused)
    #expect(state.fileURL == fileURL)
    #expect(state.currentTime == 2.5)

    try await fake.resume()
    #expect(await fake.currentState().status == .playing)

    await fake.stop()
    #expect(await fake.currentState() == .stopped)
}

@Test("Audio session coordinator grants one owner at a time")
func audioSessionCoordinatorEnforcesMutualExclusion() async throws {
    let coordinator = AudioSessionCoordinator(
        activation: { _ in },
        deactivation: {}
    )
    let playbackOwner = UUID()
    let recordingOwner = UUID()

    try await coordinator.acquire(ownerID: playbackOwner, usage: .playback)
    #expect(
        await coordinator.currentState()
            == AudioSessionCoordinatorState(ownerID: playbackOwner, usage: .playback)
    )

    await #expect(throws: AudioTimelineError.audioSessionBusy) {
        try await coordinator.acquire(ownerID: recordingOwner, usage: .recording)
    }
    await coordinator.release(ownerID: recordingOwner)
    #expect(await coordinator.currentState().ownerID == playbackOwner)

    try await coordinator.acquire(ownerID: playbackOwner, usage: .playback)
    await coordinator.release(ownerID: playbackOwner)
    #expect(await coordinator.currentState() == .idle)

    try await coordinator.acquire(ownerID: recordingOwner, usage: .recording)
    #expect(await coordinator.currentState().usage == .recording)
    await coordinator.release(ownerID: recordingOwner)
}

@Test("Concrete playback pauses, resumes, and releases its lease after natural completion")
func concretePlaybackLifecycleReleasesSession() async throws {
    let fixtureURL = try makeSilentWaveFixture(duration: 1)
    defer { try? FileManager.default.removeItem(at: fixtureURL) }
    let coordinator = PlaybackSessionCoordinatorFake()
    let player = AudioTimelinePlayer(sessionCoordinator: coordinator)

    try await player.play(fileURL: fixtureURL)
    #expect(await player.currentState().status == .playing)
    #expect(await coordinator.snapshot().usage == .playback)

    await player.pause()
    #expect(await player.currentState().status == .paused)
    #expect(await coordinator.snapshot().usage == nil)

    try await player.resume()
    let resumedState = await player.currentState()
    #expect(resumedState.status == .playing)
    try await player.seek(to: max(0, resumedState.duration - 0.05))

    for _ in 0..<250 {
        if await coordinator.snapshot().usage == nil { break }
        try await Task.sleep(for: .milliseconds(20))
    }
    let completedSnapshot = await coordinator.snapshot()
    #expect(completedSnapshot.usage == nil)
    #expect(completedSnapshot.releaseCount == 2)
    let completedState = await player.currentState()
    let repeatedCompletedState = await player.currentState()
    #expect(completedState.status == .finished)
    #expect(completedState.duration > 0)
    #expect(completedState.currentTime == completedState.duration)
    #expect(repeatedCompletedState == completedState)

    await player.stop()
    #expect(await player.currentState() == .stopped)
}

@Test("Play and resume honor task cancellation without leaking a session lease")
func playbackTransitionsHonorCancellation() async throws {
    let fixtureURL = try makeSilentWaveFixture(duration: 1)
    defer { try? FileManager.default.removeItem(at: fixtureURL) }
    let coordinator = PlaybackSessionCoordinatorFake()
    await coordinator.setAcquisitionDelayEnabled(true)
    let player = AudioTimelinePlayer(sessionCoordinator: coordinator)

    let playTask = Task {
        try await player.play(fileURL: fixtureURL)
    }
    try await waitForAcquisitionAttempt(1, coordinator: coordinator)
    playTask.cancel()
    do {
        try await playTask.value
        Issue.record("Cancelled play unexpectedly succeeded")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(await player.currentState() == .stopped)
    #expect(await coordinator.snapshot().usage == nil)

    await coordinator.setAcquisitionDelayEnabled(false)
    try await player.play(fileURL: fixtureURL)
    await player.pause()
    await coordinator.setAcquisitionDelayEnabled(true)
    let attemptBeforeResume = await coordinator.snapshot().acquisitionAttempts
    let resumeTask = Task {
        try await player.resume()
    }
    try await waitForAcquisitionAttempt(attemptBeforeResume + 1, coordinator: coordinator)
    resumeTask.cancel()
    do {
        try await resumeTask.value
        Issue.record("Cancelled resume unexpectedly succeeded")
    } catch {
        #expect(error is CancellationError)
    }
    #expect(await player.currentState().status == .paused)
    #expect(await coordinator.snapshot().usage == nil)
    await player.stop()
}

private actor PlaybackFake: AudioTimelinePlaying {
    private var state: AudioPlaybackState = .stopped

    func play(fileURL: URL, from time: TimeInterval) async throws {
        state = AudioPlaybackState(
            status: .playing,
            fileURL: fileURL,
            currentTime: time,
            duration: 30
        )
    }

    func pause() async {
        state.status = .paused
    }

    func resume() async throws {
        guard state.status == .paused else { throw AudioTimelineError.couldNotPlay }
        state.status = .playing
    }

    func stop() async {
        state = .stopped
    }

    func seek(to time: TimeInterval) async throws {
        state.currentTime = time
    }

    func currentState() async -> AudioPlaybackState {
        state
    }
}

private struct PlaybackSessionCoordinatorSnapshot: Sendable {
    var ownerID: UUID?
    var usage: AudioSessionUsage?
    var acquisitionAttempts: Int
    var releaseCount: Int
}

private actor PlaybackSessionCoordinatorFake: AudioSessionCoordinating {
    private var ownerID: UUID?
    private var usage: AudioSessionUsage?
    private var acquisitionAttempts = 0
    private var releaseCount = 0
    private var acquisitionDelayEnabled = false

    func acquire(ownerID: UUID, usage: AudioSessionUsage) async throws {
        acquisitionAttempts += 1
        if acquisitionDelayEnabled {
            try await Task.sleep(for: .seconds(30))
        }
        try Task.checkCancellation()
        if let activeOwnerID = self.ownerID {
            guard activeOwnerID == ownerID, self.usage == usage else {
                throw AudioTimelineError.audioSessionBusy
            }
            return
        }
        self.ownerID = ownerID
        self.usage = usage
    }

    func release(ownerID: UUID) async {
        guard self.ownerID == ownerID else { return }
        self.ownerID = nil
        usage = nil
        releaseCount += 1
    }

    func setAcquisitionDelayEnabled(_ enabled: Bool) {
        acquisitionDelayEnabled = enabled
    }

    func snapshot() -> PlaybackSessionCoordinatorSnapshot {
        PlaybackSessionCoordinatorSnapshot(
            ownerID: ownerID,
            usage: usage,
            acquisitionAttempts: acquisitionAttempts,
            releaseCount: releaseCount
        )
    }
}

private func waitForAcquisitionAttempt(
    _ expectedCount: Int,
    coordinator: PlaybackSessionCoordinatorFake
) async throws {
    for _ in 0..<100 {
        if await coordinator.snapshot().acquisitionAttempts >= expectedCount { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for the audio session acquisition attempt")
}

private func makeSilentWaveFixture(duration: TimeInterval) throws -> URL {
    let sampleRate: UInt32 = 8_000
    let sampleCount = UInt32((Double(sampleRate) * duration).rounded(.up))
    let dataByteCount = sampleCount * 2
    var data = Data()

    data.append(contentsOf: "RIFF".utf8)
    appendLittleEndian(UInt32(36) + dataByteCount, to: &data)
    data.append(contentsOf: "WAVE".utf8)
    data.append(contentsOf: "fmt ".utf8)
    appendLittleEndian(UInt32(16), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(UInt16(1), to: &data)
    appendLittleEndian(sampleRate, to: &data)
    appendLittleEndian(sampleRate * 2, to: &data)
    appendLittleEndian(UInt16(2), to: &data)
    appendLittleEndian(UInt16(16), to: &data)
    data.append(contentsOf: "data".utf8)
    appendLittleEndian(dataByteCount, to: &data)
    data.append(Data(repeating: 0, count: Int(dataByteCount)))

    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("Notes-AudioTimeline-\(UUID().uuidString).wav")
    try data.write(to: fileURL, options: .atomic)
    return fileURL
}

private func appendLittleEndian<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
    var littleEndianValue = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndianValue) { bytes in
        data.append(contentsOf: bytes)
    }
}
