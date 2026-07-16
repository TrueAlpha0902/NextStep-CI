import Combine
import Foundation
import NotesCore

enum NoteReplayControllerState: String, Equatable, Sendable {
    case idle
    case preparing
    case playing
    case paused
    case seeking
    case finished
    case stopping
}

enum NoteReplayAudioPlaybackStatus: String, Equatable, Sendable {
    case playing
    case paused
    case finished
    case failed
    case stopped
}

struct NoteReplayAudioPlaybackSnapshot: Equatable, Sendable {
    let status: NoteReplayAudioPlaybackStatus
    let currentTime: TimeInterval

    init(status: NoteReplayAudioPlaybackStatus, currentTime: TimeInterval) {
        self.status = status
        self.currentTime = currentTime
    }
}

/// The audio boundary is deliberately transport-only. Replay never writes a
/// recording, timeline mark, or notebook operation.
@MainActor
protocol NoteReplayAudioTransport: AnyObject {
    func startReplayAudio(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        from time: TimeInterval
    ) async throws

    func pauseReplayAudio() async throws
    func resumeReplayAudio() async throws
    func seekReplayAudio(to time: TimeInterval) async throws
    func stopReplayAudio() async
    func replayAudioPlaybackSnapshot() async throws
        -> NoteReplayAudioPlaybackSnapshot
}

struct NoteReplaySessionSnapshot: Sendable {
    let descriptor: AudioSessionDescriptor
    let timeline: AudioTimelineDocument
    /// Ordered, currently existing pages that the editor can present in replay.
    let eligiblePageIDs: [PageID]
    /// A validated append-only scene history, when this recording has one.
    /// Legacy recordings intentionally keep this nil.
    let history: NoteReplayHistoryDocument?
    /// True only when a referenced history could not be read safely. The
    /// controller must fail startup closed instead of silently selecting the
    /// legacy final-page path.
    let historyUnavailable: Bool

    init(
        descriptor: AudioSessionDescriptor,
        timeline: AudioTimelineDocument,
        eligiblePageIDs: [PageID],
        history: NoteReplayHistoryDocument? = nil,
        historyUnavailable: Bool = false
    ) {
        self.descriptor = descriptor
        self.timeline = timeline
        self.eligiblePageIDs = eligiblePageIDs
        self.history = history
        self.historyUnavailable = historyUnavailable
    }
}

/// The integration adapter must enforce the requested bounds while reading.
/// The controller independently verifies returned counts and bytes before use.
@MainActor
protocol NoteReplayDataSource: AnyObject {
    func loadReplaySession(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        maximumTimelineMarkCount: Int,
        maximumEligiblePageCount: Int,
        maximumHistoryEventCount: Int
    ) async throws -> NoteReplaySessionSnapshot

    /// `nil` is the canonical representation of a page with no PencilKit ink.
    /// A present, zero-byte value is malformed input and is passed to the strict
    /// PencilKit decoder rather than silently treated as an empty drawing.
    func loadReplayInk(
        notebookID: NotebookID,
        pageID: PageID,
        maximumByteCount: Int
    ) async throws -> Data?

    func loadReplayInkPayload(
        notebookID: NotebookID,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int
    ) async throws -> Data?

    func loadReplayElementsPayload(
        notebookID: NotebookID,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int,
        maximumElementCount: Int
    ) async throws -> NotebookExportCanvasElements

    /// Releases any identity-validated persistence capability opened by
    /// `loadReplaySession`. Implementations must make this idempotent.
    func endReplaySession() async
}

extension NoteReplayDataSource {
    func endReplaySession() async {}

    func loadReplayInkPayload(
        notebookID: NotebookID,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int
    ) async throws -> Data? {
        _ = (notebookID, reference, maximumByteCount)
        throw NoteReplayHistoricalPayloadError.unavailable
    }

    func loadReplayElementsPayload(
        notebookID: NotebookID,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int,
        maximumElementCount: Int
    ) async throws -> NotebookExportCanvasElements {
        _ = (notebookID, reference, maximumByteCount, maximumElementCount)
        throw NoteReplayHistoricalPayloadError.unavailable
    }
}

private enum NoteReplayHistoricalPayloadError: Error {
    case unavailable
}

enum NoteReplayControllerFailure: Equatable, Sendable {
    case sessionUnavailable
    case historicalReplayUnavailable
    case invalidSessionOrTimeline
    case noEligiblePages
    case audioTransportUnavailable
    case audioStoppedUnexpectedly
}

enum NoteReplayPageIssue: Equatable, Sendable {
    case inkUnavailable(PageID)
    case inkTooLarge(PageID, maximumByteCount: Int)
    case renderingUnavailable(PageID)
    case rendererFallback(PageID, NoteReplayFrameFallback)
    case cacheBudgetExceeded(PageID, maximumByteCount: Int)
    case timelineMarkUnavailable(PageID)
    case historicalSceneUnavailable(PageID)
}

enum NoteReplayLifecycleEvent: Equatable, Sendable {
    case becameInactive
    case enteredBackground
    case editorDismissed
    case memoryWarning
}

struct NoteReplayControllerConfiguration: Equatable, Sendable {
    static let `default` = NoteReplayControllerConfiguration()

    static let hardMaximumCacheByteCount = 64 * 1_024 * 1_024
    static let hardMaximumCachedSceneCount = 6
    static let hardMaximumHistoryEventCount = NoteReplayHistoryLimits.maximumEventCount

    let pollInterval: TimeInterval
    let maximumFramesPerSecond: Double
    let maximumCachedPageCount: Int
    let maximumCachedSceneCount: Int
    let maximumCacheByteCount: Int
    let maximumEligiblePageCount: Int
    let maximumHistoryEventCount: Int
    let naturalEndTolerance: TimeInterval
    let renderingLimits: NoteReplayRenderingLimits

    init(
        pollInterval: TimeInterval = 0.075,
        maximumFramesPerSecond: Double = 15,
        maximumCachedPageCount: Int = 3,
        maximumCachedSceneCount: Int = 6,
        maximumCacheByteCount: Int = 24 * 1_024 * 1_024,
        maximumEligiblePageCount: Int = NoteReplayNavigationPlanner.maximumEligiblePageCount,
        maximumHistoryEventCount: Int = NoteReplayHistoryLimits.maximumEventCount,
        naturalEndTolerance: TimeInterval = 0.1,
        renderingLimits: NoteReplayRenderingLimits = .default
    ) {
        self.pollInterval = pollInterval.isFinite
            ? min(max(pollInterval, 0.05), 0.1)
            : 0.075
        self.maximumFramesPerSecond = maximumFramesPerSecond.isFinite
            ? min(max(maximumFramesPerSecond, 1), 15)
            : 15
        self.maximumCachedPageCount = min(max(maximumCachedPageCount, 2), 3)
        self.maximumCachedSceneCount = min(
            max(maximumCachedSceneCount, 2),
            Self.hardMaximumCachedSceneCount
        )
        self.maximumCacheByteCount = min(
            max(maximumCacheByteCount, 1),
            Self.hardMaximumCacheByteCount
        )
        self.maximumEligiblePageCount = min(
            max(maximumEligiblePageCount, 1),
            NoteReplayNavigationPlanner.maximumEligiblePageCount
        )
        self.maximumHistoryEventCount = min(
            max(maximumHistoryEventCount, 1),
            Self.hardMaximumHistoryEventCount
        )
        self.naturalEndTolerance = naturalEndTolerance.isFinite
            ? min(max(naturalEndTolerance, 0), 1)
            : 0.1
        self.renderingLimits = renderingLimits
    }
}

@MainActor
protocol NoteReplayScheduling: AnyObject {
    var monotonicTime: TimeInterval { get }
    func sleep(for interval: TimeInterval) async throws
}

@MainActor
final class SystemNoteReplayScheduler: NoteReplayScheduling {
    var monotonicTime: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func sleep(for interval: TimeInterval) async throws {
        let boundedInterval = interval.isFinite ? max(interval, 0) : 0
        let nanoseconds = UInt64(
            min(boundedInterval * 1_000_000_000, Double(UInt64.max))
        )
        try await Task<Never, Never>.sleep(nanoseconds: nanoseconds)
    }
}

/// Type-erased immutable page preparation. Its render closure is MainActor
/// isolated so test and UI adapters can remain strictly actor-safe; the default
/// implementation immediately delegates heavy work to `NoteReplayRenderer`'s
/// detached, bounded workers.
struct NoteReplayPreparedPage: Sendable {
    let conservativeByteCount: Int
    let preparationFallback: NoteReplayFrameFallback?
    let historicalElements: [CanvasElement]?

    private let renderOperation:
        @MainActor @Sendable (TimeInterval, NoteReplayMode) async throws
            -> NoteReplayFrame

    init(
        conservativeByteCount: Int,
        preparationFallback: NoteReplayFrameFallback? = nil,
        historicalElements: [CanvasElement]? = nil,
        render: @escaping
            @MainActor @Sendable (TimeInterval, NoteReplayMode) async throws
                -> NoteReplayFrame
    ) {
        self.conservativeByteCount = max(conservativeByteCount, 0)
        self.preparationFallback = preparationFallback
        self.historicalElements = historicalElements
        self.renderOperation = render
    }

    @MainActor
    func render(
        at playbackTime: TimeInterval,
        mode: NoteReplayMode
    ) async throws -> NoteReplayFrame {
        let frame = try await renderOperation(playbackTime, mode)
        return frame.replacingHistoricalElements(historicalElements)
    }
}

@MainActor
protocol NoteReplayPageRendering: AnyObject {
    func prepareReplayPage(
        drawingData: Data?,
        timing: NoteReplaySessionTiming,
        limits: NoteReplayRenderingLimits
    ) async throws -> NoteReplayPreparedPage
}

@MainActor
final class PencilKitNoteReplayPageRenderer: NoteReplayPageRendering {
    func prepareReplayPage(
        drawingData: Data?,
        timing: NoteReplaySessionTiming,
        limits: NoteReplayRenderingLimits
    ) async throws -> NoteReplayPreparedPage {
        let prepared = try await NoteReplayRenderer.prepareDrawing(
            drawingData: drawingData,
            timing: timing,
            limits: limits
        )
        let encodedByteCount = drawingData?.count ?? 0
        let decodedCopies = prepared.timedStrokeCount > 0 ? 2 : 1
        let decodedByteCount = Self.multipliedSaturating(
            prepared.estimatedDecodedStructureByteCount,
            decodedCopies
        )
        let conservativeByteCount = Self.addedSaturating(
            encodedByteCount,
            decodedByteCount
        )
        return NoteReplayPreparedPage(
            conservativeByteCount: conservativeByteCount,
            preparationFallback: prepared.preparationFallback
        ) { playbackTime, mode in
            try await NoteReplayRenderer.renderFrame(
                preparedDrawing: prepared,
                playbackTime: playbackTime,
                mode: mode
            )
        }
    }

    private static func multipliedSaturating(_ lhs: Int, _ rhs: Int) -> Int {
        guard lhs > 0, rhs > 0 else { return 0 }
        guard lhs <= Int.max / rhs else { return Int.max }
        return lhs * rhs
    }

    private static func addedSaturating(_ lhs: Int, _ rhs: Int) -> Int {
        guard lhs <= Int.max - rhs else { return Int.max }
        return lhs + rhs
    }
}

struct NoteReplayPageFrame: Sendable {
    let pageID: PageID
    let sceneKey: NoteReplaySceneKey
    let frame: NoteReplayFrame

    init(
        pageID: PageID,
        sceneKey: NoteReplaySceneKey? = nil,
        frame: NoteReplayFrame
    ) {
        self.pageID = pageID
        self.sceneKey = sceneKey ?? .legacy(pageID)
        self.frame = frame
    }
}

/// Editor-owned Note Replay lifecycle and presentation coordinator.
///
/// It owns playback tasks and bounded derived replay state only. It has no API
/// for editing a page or persisting notebook data.
@MainActor
final class NoteReplayController: ObservableObject {
    /// Encoded JSON bounds variable-sized element content; this additional
    /// allowance covers decoded array, enum, UUID, geometry, and heap metadata.
    private static let estimatedDecodedBytesPerHistoricalElement = 2 * 1_024

    @Published private(set) var state: NoteReplayControllerState = .idle
    @Published private(set) var playbackTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentPageID: PageID?
    @Published private(set) var currentMarkID: AudioTimelineMarkID?
    @Published private(set) var currentPageFrame: NoteReplayPageFrame?
    @Published private(set) var failure: NoteReplayControllerFailure?
    @Published private(set) var pageIssue: NoteReplayPageIssue?
    @Published private(set) var mode: NoteReplayMode = .wholeStrokeReveal

    private struct CachedScene {
        let preparedPage: NoteReplayPreparedPage
        let byteCount: Int
        var accessOrdinal: UInt64
    }

    private struct FrameRequest: Sendable {
        let sessionGeneration: UUID
        let presentationGeneration: UUID
        let pageID: PageID
        let sceneKey: NoteReplaySceneKey
        let playbackTime: TimeInterval
        let mode: NoteReplayMode
        let preparedPage: NoteReplayPreparedPage
    }

    private enum PagePreparationResult: Sendable {
        case prepared(NoteReplayPreparedPage)
        case issue(NoteReplayPageIssue)
        case cancelled
    }

    private let audioTransport: any NoteReplayAudioTransport
    private let dataSource: any NoteReplayDataSource
    private let pageRenderer: any NoteReplayPageRendering
    private let scheduler: any NoteReplayScheduling
    private let configuration: NoteReplayControllerConfiguration

    private var notebookID: NotebookID?
    private var audioSessionID: AudioSessionID?
    private var timing: NoteReplaySessionTiming?
    private var timeline: AudioTimelineDocument?
    private var navigationPlan: PreparedNoteReplayNavigationPlan?
    private var history: NoteReplayHistoryDocument?
    private var currentSceneKey: NoteReplaySceneKey?

    private var sessionGeneration = UUID()
    private var shutdownGeneration = UUID()
    private var transportGeneration = UUID()
    private var presentationGeneration = UUID()
    private var pagePreparationGeneration = UUID()
    private var frameTaskGeneration = UUID()
    private var frameWakeGeneration = UUID()
    private var pollTaskGeneration = UUID()
    private var startupTaskGeneration = UUID()
    private var transportControlTaskGeneration = UUID()
    private var transportControlRequestGeneration = UUID()

    private var startupTask: Task<Void, Never>?
    private var pagePreparationTask: Task<PagePreparationResult, Never>?
    private var frameTask: Task<Void, Never>?
    private var frameWakeTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var transportControlTask: Task<Void, Never>?

    private var pendingFrameRequest: FrameRequest?
    private var lastFrameStartMonotonicTime: TimeInterval?
    private var sceneCache: [NoteReplaySceneKey: CachedScene] = [:]
    private var scenePreparationIssues:
        [NoteReplaySceneKey: NoteReplayPageIssue] = [:]
    private var pageCacheByteCount = 0
    private var cacheAccessOrdinal: UInt64 = 0

    init(
        audioTransport: any NoteReplayAudioTransport,
        dataSource: any NoteReplayDataSource,
        pageRenderer: any NoteReplayPageRendering = PencilKitNoteReplayPageRenderer(),
        scheduler: any NoteReplayScheduling = SystemNoteReplayScheduler(),
        configuration: NoteReplayControllerConfiguration = .default
    ) {
        self.audioTransport = audioTransport
        self.dataSource = dataSource
        self.pageRenderer = pageRenderer
        self.scheduler = scheduler
        self.configuration = configuration
    }

    var isActive: Bool { state != .idle }

    var requiresAuthoritativeDrawingReuse: Bool {
        currentPageFrame?.frame.requiresAuthoritativeDrawingReuse ?? true
    }

    var cachedPageIDs: Set<PageID> { Set(sceneCache.keys.map(\.pageID)) }
    var cachedSceneKeys: Set<NoteReplaySceneKey> { Set(sceneCache.keys) }
    var cachedPageByteCount: Int { pageCacheByteCount }

    func start(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        currentPageID: PageID?,
        mode: NoteReplayMode = .wholeStrokeReveal
    ) async {
        if state != .idle || self.audioSessionID != nil {
            await stop()
        }

        let generation = UUID()
        sessionGeneration = generation
        shutdownGeneration = UUID()
        transportGeneration = UUID()
        presentationGeneration = UUID()
        failure = nil
        pageIssue = nil
        state = .preparing
        self.mode = mode
        playbackTime = 0
        duration = 0
        lastFrameStartMonotonicTime = nil

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStart(
                notebookID: notebookID,
                sessionID: sessionID,
                requestedCurrentPageID: currentPageID,
                generation: generation
            )
        }
        startupTaskGeneration = generation
        startupTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if startupTaskGeneration == generation {
            startupTask = nil
        }
    }

    func pause() async {
        await runTransportControl { [weak self] in
            await self?.performPause()
        }
    }

    private func performPause() async {
        guard state == .playing else { return }
        let generation = sessionGeneration
        let actionGeneration = beginTransportAction()
        cancelPolling()
        state = .preparing
        do {
            try await audioTransport.pauseReplayAudio()
            try Task.checkCancellation()
            guard isCurrentSession(generation),
                  transportGeneration == actionGeneration else {
                return
            }
            let snapshot = try await audioTransport.replayAudioPlaybackSnapshot()
            await applyPauseSnapshot(
                snapshot,
                sessionGeneration: generation,
                transportGeneration: actionGeneration
            )
        } catch is CancellationError {
            guard isCurrentSession(generation),
                  transportGeneration == actionGeneration else {
                return
            }
            _ = try? await audioTransport.pauseReplayAudio()
            guard isCurrentSession(generation),
                  transportGeneration == actionGeneration,
                  let snapshot = try? await audioTransport
                    .replayAudioPlaybackSnapshot() else {
                return
            }
            await applyPauseSnapshot(
                snapshot,
                sessionGeneration: generation,
                transportGeneration: actionGeneration
            )
        } catch {
            guard isCurrentSession(generation),
                  transportGeneration == actionGeneration else {
                return
            }
            if let snapshot = try? await audioTransport
                .replayAudioPlaybackSnapshot() {
                await applyPauseSnapshot(
                    snapshot,
                    sessionGeneration: generation,
                    transportGeneration: actionGeneration
                )
            } else {
                await failActiveSession(.audioTransportUnavailable)
            }
        }
    }

    private func applyPauseSnapshot(
        _ snapshot: NoteReplayAudioPlaybackSnapshot,
        sessionGeneration: UUID,
        transportGeneration: UUID
    ) async {
        guard isCurrentSession(sessionGeneration),
              self.transportGeneration == transportGeneration,
              let time = validatedPlaybackTime(snapshot.currentTime) else {
            if isCurrentSession(sessionGeneration),
               self.transportGeneration == transportGeneration {
                await failActiveSession(.audioTransportUnavailable)
            }
            return
        }

        let presentationTime: TimeInterval
        let resolvedState: NoteReplayControllerState
        switch snapshot.status {
        case .paused:
            presentationTime = time
            resolvedState = .paused
        case .finished:
            presentationTime = duration
            resolvedState = .finished
        case .failed:
            await failActiveSession(.audioStoppedUnexpectedly)
            return
        case .stopped:
            guard time >= max(
                duration - configuration.naturalEndTolerance,
                0
            ) else {
                await failActiveSession(.audioStoppedUnexpectedly)
                return
            }
            presentationTime = duration
            resolvedState = .finished
        case .playing:
            await failActiveSession(.audioTransportUnavailable)
            return
        }

        await synchronizePresentation(
            at: presentationTime,
            generation: sessionGeneration,
            renderImmediately: false
        )
        guard isCurrentSession(sessionGeneration),
              self.transportGeneration == transportGeneration else {
            return
        }
        state = resolvedState
    }

    func resume() async {
        await runTransportControl { [weak self] in
            await self?.performResume()
        }
    }

    private func performResume() async {
        guard state == .paused || state == .finished,
              let notebookID,
              let audioSessionID else {
            return
        }
        let wasFinished = state == .finished
        let cancellationState: NoteReplayControllerState = wasFinished
            ? .finished
            : .paused
        let generation = sessionGeneration
        let actionGeneration = beginTransportAction()
        state = .preparing
        do {
            if wasFinished {
                try await audioTransport.startReplayAudio(
                    notebookID: notebookID,
                    sessionID: audioSessionID,
                    from: 0
                )
                guard isCurrentSession(generation),
                      transportGeneration == actionGeneration else {
                    return
                }
                await synchronizePresentation(
                    at: 0,
                    generation: generation,
                    renderImmediately: false
                )
            } else {
                try await audioTransport.resumeReplayAudio()
            }
            try Task.checkCancellation()
            guard isCurrentSession(generation),
                  transportGeneration == actionGeneration else {
                return
            }
            state = .playing
            startPolling(for: generation)
        } catch is CancellationError {
            if wasFinished,
               isCurrentSession(generation),
               transportGeneration == actionGeneration {
                await audioTransport.stopReplayAudio()
            } else if isCurrentSession(generation),
                      transportGeneration == actionGeneration {
                // A superseding slider/control request may cancel immediately
                // after resume succeeded. Restore the pre-resume paused
                // transport before the newest serialized request begins.
                let audioTransport = self.audioTransport
                let recoveryTask = Task { @MainActor in
                    _ = try? await audioTransport.pauseReplayAudio()
                }
                await recoveryTask.value
            }
            if isCurrentSession(generation),
               transportGeneration == actionGeneration {
                state = cancellationState
            }
            return
        } catch {
            guard isCurrentSession(generation),
                  transportGeneration == actionGeneration else {
                return
            }
            await failActiveSession(.audioTransportUnavailable)
        }
    }

    func seek(to requestedTime: TimeInterval) async {
        await runTransportControl { [weak self] in
            await self?.performSeek(to: requestedTime)
        }
    }

    private func performSeek(to requestedTime: TimeInterval) async {
        guard state == .playing || state == .paused || state == .finished,
              let timing,
              let notebookID,
              let audioSessionID else {
            return
        }
        let wasFinished = state == .finished
        let returnState: NoteReplayControllerState = state == .playing
            ? .playing
            : .paused
        let originalPlaybackTime = playbackTime
        let generation = sessionGeneration
        let time = NoteReplayTimelinePlanner.clampedTime(
            requestedTime,
            duration: timing.duration
        )
        let reachesExactEnd = time == timing.duration
        if wasFinished, reachesExactEnd {
            await synchronizePresentation(
                at: timing.duration,
                generation: generation,
                renderImmediately: false
            )
            if isCurrentSession(generation) {
                state = .finished
            }
            return
        }
        let actionGeneration = beginTransportAction()
        cancelPolling()
        state = .seeking
        do {
            if reachesExactEnd {
                try await audioTransport.seekReplayAudio(to: timing.duration)
                try Task.checkCancellation()
                guard isCurrentSession(generation),
                      transportGeneration == actionGeneration else {
                    return
                }
                await audioTransport.stopReplayAudio()
                try Task.checkCancellation()
                guard isCurrentSession(generation),
                      transportGeneration == actionGeneration else {
                    return
                }
                await synchronizePresentation(
                    at: timing.duration,
                    generation: generation,
                    renderImmediately: false
                )
                guard isCurrentSession(generation),
                      transportGeneration == actionGeneration else {
                    return
                }
                state = .finished
                return
            } else if wasFinished {
                // Natural completion releases the coordinator's active player.
                // Re-materialize at the target and pause it so a finished-state
                // scrub never relies on a now-invalid active-player seek.
                try await audioTransport.startReplayAudio(
                    notebookID: notebookID,
                    sessionID: audioSessionID,
                    from: time
                )
                try Task.checkCancellation()
                guard isCurrentSession(generation),
                      transportGeneration == actionGeneration else {
                    return
                }
                try await audioTransport.pauseReplayAudio()
            } else {
                try await audioTransport.seekReplayAudio(to: time)
            }
            try Task.checkCancellation()
            guard isCurrentSession(generation),
                  transportGeneration == actionGeneration else {
                return
            }
            await synchronizePresentation(
                at: time,
                generation: generation,
                renderImmediately: false
            )
            guard isCurrentSession(generation),
                  transportGeneration == actionGeneration else {
                return
            }
            state = returnState
            if returnState == .playing {
                startPolling(for: generation)
            }
        } catch is CancellationError {
            guard isCurrentSession(generation),
                  transportGeneration == actionGeneration else {
                return
            }
            if reachesExactEnd, !wasFinished {
                // Seeking to the exact end releases the active player. If a
                // newer serialized control supersedes this request while that
                // stop is in flight, rebuild the prior transport state before
                // allowing the newer request to run.
                let audioTransport = self.audioTransport
                let recoveryTask = Task { @MainActor in
                    await audioTransport.stopReplayAudio()
                    do {
                        try await audioTransport.startReplayAudio(
                            notebookID: notebookID,
                            sessionID: audioSessionID,
                            from: originalPlaybackTime
                        )
                        if returnState == .paused {
                            try await audioTransport.pauseReplayAudio()
                        }
                    } catch {
                        // The newest serialized control will observe and own
                        // any remaining transport failure.
                    }
                }
                await recoveryTask.value
                guard isCurrentSession(generation),
                      transportGeneration == actionGeneration else {
                    return
                }
                state = returnState
            } else if wasFinished {
                await audioTransport.stopReplayAudio()
                guard isCurrentSession(generation),
                      transportGeneration == actionGeneration else {
                    return
                }
                state = .finished
            } else {
                state = returnState
            }
            if !wasFinished, returnState == .playing {
                startPolling(for: generation)
            }
        } catch {
            guard isCurrentSession(generation),
                  transportGeneration == actionGeneration else {
                return
            }
            await failActiveSession(.audioTransportUnavailable)
        }
    }

    func skipBackward(
        by interval: TimeInterval = NoteReplayTimelinePlanner.defaultSkipInterval
    ) async {
        await seek(to: NoteReplayTimelinePlanner.skipBackwardTime(
            from: playbackTime,
            duration: duration,
            interval: interval
        ))
    }

    func skipForward(
        by interval: TimeInterval = NoteReplayTimelinePlanner.defaultSkipInterval
    ) async {
        await seek(to: NoteReplayTimelinePlanner.skipForwardTime(
            from: playbackTime,
            duration: duration,
            interval: interval
        ))
    }

    @discardableResult
    func seekToPage(_ pageID: PageID) async -> Bool {
        guard let navigationPlan,
              navigationPlan.eligiblePageIDs.contains(pageID),
              let time = navigationPlan.nearestSeekTime(
                for: pageID,
                to: playbackTime
              ) else {
            pageIssue = .timelineMarkUnavailable(pageID)
            return false
        }
        await seek(to: time)
        return currentPageID == pageID
    }

    func setMode(_ mode: NoteReplayMode) async {
        guard self.mode != mode else { return }
        self.mode = mode
        guard state != .idle else { return }
        await synchronizePresentation(
            at: playbackTime,
            generation: sessionGeneration,
            renderImmediately: false
        )
    }

    /// Rebuilds navigation after an externally observed page-set change. The
    /// controller itself never mutates that set or persists the notebook.
    func updateEligiblePageIDs(
        _ eligiblePageIDs: [PageID],
        currentPageID requestedCurrentPageID: PageID?
    ) async {
        guard let timing, let timeline else { return }
        let generation = sessionGeneration
        guard eligiblePageIDs.count
                <= configuration.maximumEligiblePageCount else {
            await failActiveSession(.invalidSessionOrTimeline)
            return
        }
        let navigationInput = Self.historyAwareNavigationInput(
            eligiblePageIDs: eligiblePageIDs,
            requestedCurrentPageID: requestedCurrentPageID,
            playbackTime: playbackTime,
            timeline: timeline,
            history: history
        )
        guard !navigationInput.eligiblePageIDs.isEmpty else {
            await failActiveSession(
                history == nil
                    ? .noEligiblePages
                    : .historicalReplayUnavailable
            )
            return
        }
        guard let navigationPlan = NoteReplayNavigationPlanner.prepare(
            timing: timing,
            timeline: timeline,
            eligiblePageIDs: navigationInput.eligiblePageIDs,
            currentPageID: navigationInput.fallbackPageID,
            maximumPageCount: configuration.maximumEligiblePageCount
        ) else {
            await failActiveSession(.invalidSessionOrTimeline)
            return
        }
        guard isCurrentSession(generation) else { return }
        self.navigationPlan = navigationPlan
        scenePreparationIssues.removeAll(keepingCapacity: true)
        removeCachedPages(notIn: Set(navigationInput.eligiblePageIDs))
        await synchronizePresentation(
            at: playbackTime,
            generation: generation,
            renderImmediately: false
        )
    }

    func pollOnce() async {
        await pollOnce(expectedSessionGeneration: sessionGeneration)
    }

    func handleLifecycle(_ event: NoteReplayLifecycleEvent) async {
        switch event {
        case .becameInactive:
            switch state {
            case .playing:
                await pause()
                if state == .playing || state == .preparing || state == .seeking {
                    await stop()
                }
            case .preparing, .seeking:
                // These transient states may otherwise publish a newly started
                // or newly sought player after the editor has resigned active.
                await stop()
            case .idle, .paused, .finished, .stopping:
                break
            }
        case .enteredBackground, .editorDismissed:
            await stop()
        case .memoryWarning:
            trimCacheForMemoryWarning()
        }
    }

    func stop() async {
        guard state != .idle || audioSessionID != nil || startupTask != nil else {
            clearActiveSession(clearFailure: true)
            return
        }

        let shutdown = UUID()
        shutdownGeneration = shutdown
        let fencedSessionGeneration = UUID()
        sessionGeneration = fencedSessionGeneration
        transportGeneration = UUID()
        presentationGeneration = UUID()
        state = .stopping

        let startupTask = self.startupTask
        let pagePreparationTask = self.pagePreparationTask
        let frameTask = self.frameTask
        let frameWakeTask = self.frameWakeTask
        let pollTask = self.pollTask
        let transportControlTask = self.transportControlTask
        cancelOwnedTasks()
        // Stop audible work before waiting for bounded but non-preemptible
        // PencilKit decode/render calls to unwind after cancellation.
        await audioTransport.stopReplayAudio()
        guard isCurrentShutdown(
            shutdown,
            sessionGeneration: fencedSessionGeneration
        ) else { return }
        await startupTask?.value
        guard isCurrentShutdown(
            shutdown,
            sessionGeneration: fencedSessionGeneration
        ) else { return }
        _ = await pagePreparationTask?.value
        guard isCurrentShutdown(
            shutdown,
            sessionGeneration: fencedSessionGeneration
        ) else { return }
        await frameTask?.value
        await frameWakeTask?.value
        await pollTask?.value
        await transportControlTask?.value
        guard isCurrentShutdown(
            shutdown,
            sessionGeneration: fencedSessionGeneration
        ) else { return }
        if startupTask != nil || transportControlTask != nil {
            // Fence a transport implementation that only noticed cancellation
            // after the first stop request returned.
            await audioTransport.stopReplayAudio()
            guard isCurrentShutdown(
                shutdown,
                sessionGeneration: fencedSessionGeneration
            ) else { return }
        }
        await dataSource.endReplaySession()
        guard isCurrentShutdown(
            shutdown,
            sessionGeneration: fencedSessionGeneration
        ) else { return }
        clearActiveSession(clearFailure: true)
        state = .idle
    }

    private func performStart(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        requestedCurrentPageID: PageID?,
        generation: UUID
    ) async {
        let snapshot: NoteReplaySessionSnapshot
        do {
            snapshot = try await dataSource.loadReplaySession(
                notebookID: notebookID,
                sessionID: sessionID,
                maximumTimelineMarkCount:
                    NoteReplayTimelinePlanner.maximumMarkCount,
                maximumEligiblePageCount:
                    configuration.maximumEligiblePageCount,
                maximumHistoryEventCount:
                    configuration.maximumHistoryEventCount
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            await cancelStartupIfCurrent(generation)
            return
        } catch {
            guard isCurrentSession(generation) else { return }
            await failActiveSession(.sessionUnavailable)
            return
        }

        guard !snapshot.historyUnavailable else {
            if isCurrentSession(generation) {
                await failActiveSession(.historicalReplayUnavailable)
            }
            return
        }

        guard isCurrentSession(generation),
              snapshot.descriptor.id == sessionID,
              Self.validReplayDescriptorEnvelope(snapshot.descriptor),
              snapshot.timeline.marks.count
                <= NoteReplayTimelinePlanner.maximumMarkCount,
              snapshot.eligiblePageIDs.count
                <= configuration.maximumEligiblePageCount,
              let resolvedTiming = NoteReplaySessionTimingResolver.resolve(
                session: snapshot.descriptor,
                timeline: snapshot.timeline
              ),
              (snapshot.history.map {
                Self.validHistory(
                    $0,
                    sessionID: sessionID,
                    duration: resolvedTiming.timing.duration,
                    maximumEventCount: configuration.maximumHistoryEventCount
                )
              } ?? true) else {
            if isCurrentSession(generation) {
                await failActiveSession(.invalidSessionOrTimeline)
            }
            return
        }
        guard Self.descriptorHistoryMatches(
            descriptor: snapshot.descriptor,
            history: snapshot.history
        ) else {
            await failActiveSession(.historicalReplayUnavailable)
            return
        }
        let navigationInput = Self.historyAwareNavigationInput(
            eligiblePageIDs: snapshot.eligiblePageIDs,
            requestedCurrentPageID: requestedCurrentPageID,
            playbackTime: 0,
            timeline: snapshot.timeline,
            history: snapshot.history
        )
        guard !navigationInput.eligiblePageIDs.isEmpty else {
            await failActiveSession(
                snapshot.history == nil
                    ? .noEligiblePages
                    : .historicalReplayUnavailable
            )
            return
        }
        guard let navigationPlan = NoteReplayNavigationPlanner.prepare(
            timing: resolvedTiming.timing,
            timeline: snapshot.timeline,
            eligiblePageIDs: navigationInput.eligiblePageIDs,
            currentPageID: navigationInput.fallbackPageID,
            maximumPageCount: configuration.maximumEligiblePageCount
        ) else {
            await failActiveSession(.invalidSessionOrTimeline)
            return
        }

        self.notebookID = notebookID
        audioSessionID = sessionID
        timing = resolvedTiming.timing
        timeline = snapshot.timeline
        self.navigationPlan = navigationPlan
        history = snapshot.history
        duration = resolvedTiming.timing.duration

        await synchronizePresentation(
            at: 0,
            generation: generation,
            renderImmediately: true
        )
        let initialHistoricalSceneUnavailable = pageIssue.map { issue in
            if case .historicalSceneUnavailable = issue { return true }
            return false
        } ?? false
        guard currentSceneKey != nil, !initialHistoricalSceneUnavailable else {
            if isCurrentSession(generation) {
                await failActiveSession(.historicalReplayUnavailable)
            }
            return
        }
        guard !Task.isCancelled else {
            await cancelStartupIfCurrent(generation)
            return
        }
        guard isCurrentSession(generation) else { return }

        let actionGeneration = beginTransportAction()
        do {
            try await audioTransport.startReplayAudio(
                notebookID: notebookID,
                sessionID: sessionID,
                from: 0
            )
            try Task.checkCancellation()
            guard isCurrentSession(generation),
                  transportGeneration == actionGeneration else {
                return
            }
            state = .playing
            startPolling(for: generation)
        } catch is CancellationError {
            await cancelStartupIfCurrent(generation)
        } catch {
            guard isCurrentSession(generation),
                  transportGeneration == actionGeneration else {
                return
            }
            await failActiveSession(.audioTransportUnavailable)
        }
    }

    private func synchronizePresentation(
        at requestedTime: TimeInterval,
        generation: UUID,
        renderImmediately: Bool
    ) async {
        guard !Task.isCancelled,
              isCurrentSession(generation),
              let navigationPlan else {
            return
        }
        let pagePlan = navigationPlan.pagePlan(at: requestedTime)
        guard let pageID = pagePlan.pageID else { return }
        guard let scene = NoteReplaySceneSelector.selection(
            pageID: pageID,
            playbackTime: pagePlan.playbackTime,
            mode: mode,
            history: history
        ) else {
            presentationGeneration = UUID()
            playbackTime = pagePlan.playbackTime
            currentMarkID = pagePlan.markID
            currentPageID = pageID
            currentSceneKey = nil
            cancelFrameWork()
            currentPageFrame = nil
            pageIssue = .historicalSceneUnavailable(pageID)
            return
        }

        let newPresentationGeneration = UUID()
        presentationGeneration = newPresentationGeneration
        let pageChanged = currentPageID != pageID
        let sceneChanged = currentSceneKey != scene.key
        playbackTime = pagePlan.playbackTime
        currentMarkID = pagePlan.markID
        currentPageID = pageID
        currentSceneKey = scene.key
        if pageChanged || sceneChanged {
            cancelFrameWork()
            currentPageFrame = nil
            pageIssue = nil
        }

        guard let preparedPage = await preparedPage(
            for: scene,
            sessionGeneration: generation,
            presentationGeneration: newPresentationGeneration
        ), !Task.isCancelled, isCurrentPresentation(
            sessionGeneration: generation,
            presentationGeneration: newPresentationGeneration,
            sceneKey: scene.key
        ) else {
            return
        }

        if renderImmediately {
            await self.renderImmediately(
                preparedPage: preparedPage,
                pageID: pageID,
                sceneKey: scene.key,
                playbackTime: pagePlan.playbackTime,
                sessionGeneration: generation,
                presentationGeneration: newPresentationGeneration
            )
        } else {
            enqueueFrame(
                FrameRequest(
                    sessionGeneration: generation,
                    presentationGeneration: newPresentationGeneration,
                    pageID: pageID,
                    sceneKey: scene.key,
                    playbackTime: pagePlan.playbackTime,
                    mode: mode,
                    preparedPage: preparedPage
                )
            )
        }
    }

    private func preparedPage(
        for scene: NoteReplaySceneSelection,
        sessionGeneration: UUID,
        presentationGeneration: UUID
    ) async -> NoteReplayPreparedPage? {
        guard !Task.isCancelled else { return nil }
        let pageID = scene.pageID
        if let cachedPage = cachedScene(for: scene.key) {
            pageIssue = cachedPage.preparationFallback.map {
                .rendererFallback(pageID, $0)
            }
            return cachedPage
        }
        if let issue = scenePreparationIssues[scene.key] {
            pageIssue = issue
            currentPageFrame = nil
            return nil
        }
        guard let notebookID, let timing else { return nil }

        if let previousPagePreparationTask = pagePreparationTask {
            pagePreparationGeneration = UUID()
            previousPagePreparationTask.cancel()
            pagePreparationTask = nil
            _ = await previousPagePreparationTask.value
            guard !Task.isCancelled,
                  isCurrentPresentation(
                      sessionGeneration: sessionGeneration,
                      presentationGeneration: presentationGeneration,
                      sceneKey: scene.key
                  ) else {
                return nil
            }
        }
        let preparationGeneration = UUID()
        pagePreparationGeneration = preparationGeneration
        let dataSource = self.dataSource
        let pageRenderer = self.pageRenderer
        let limits = configuration.renderingLimits
        let maximumByteCount = limits.maximumDrawingByteCount
        let maximumCacheByteCount = configuration.maximumCacheByteCount
        let maximumElementsByteCount = min(
            NoteReplayHistoryLimits.maximumElementPayloadBytes,
            maximumCacheByteCount
        )
        let maximumElementCount = NoteReplayHistoryLimits.maximumElementCountPerSnapshot
        let task: Task<PagePreparationResult, Never> = Task { @MainActor in
            let drawingData: Data?
            let historicalElements: [CanvasElement]?
            let historicalElementsByteCount: Int
            do {
                if scene.isHistoricalSnapshot {
                    if let inkPayload = scene.inkPayload {
                        guard let loadedInk = try await dataSource.loadReplayInkPayload(
                            notebookID: notebookID,
                            reference: inkPayload,
                            maximumByteCount: maximumByteCount
                        ) else {
                            return .issue(.historicalSceneUnavailable(pageID))
                        }
                        guard loadedInk.count == inkPayload.byteCount else {
                            return .issue(.historicalSceneUnavailable(pageID))
                        }
                        drawingData = loadedInk
                    } else {
                        drawingData = nil
                    }
                    if let elementsPayload = scene.elementsPayload {
                        let loadedElements = try await dataSource
                            .loadReplayElementsPayload(
                                notebookID: notebookID,
                                reference: elementsPayload,
                                maximumByteCount: maximumElementsByteCount,
                                maximumElementCount: maximumElementCount
                            )
                        guard loadedElements.elements.count <= maximumElementCount,
                              loadedElements.encodedByteCount >= 0,
                              loadedElements.encodedByteCount
                                == elementsPayload.byteCount,
                              loadedElements.encodedByteCount
                                <= maximumElementsByteCount else {
                            return .issue(.historicalSceneUnavailable(pageID))
                        }
                        historicalElements = loadedElements.elements
                        historicalElementsByteCount = Self.addedSaturating(
                            loadedElements.encodedByteCount,
                            Self.multipliedSaturating(
                                loadedElements.elements.count,
                                Self.estimatedDecodedBytesPerHistoricalElement
                            )
                        )
                    } else {
                        historicalElements = []
                        historicalElementsByteCount = 0
                    }
                } else {
                    drawingData = try await dataSource.loadReplayInk(
                        notebookID: notebookID,
                        pageID: pageID,
                        maximumByteCount: maximumByteCount
                    )
                    historicalElements = nil
                    historicalElementsByteCount = 0
                }
                try Task.checkCancellation()
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .issue(
                    scene.isHistoricalSnapshot
                        ? .historicalSceneUnavailable(pageID)
                        : .inkUnavailable(pageID)
                )
            }
            if let drawingData,
               drawingData.count > maximumByteCount {
                return .issue(
                    scene.isHistoricalSnapshot
                        ? .historicalSceneUnavailable(pageID)
                        : .inkTooLarge(
                            pageID,
                            maximumByteCount: maximumByteCount
                        )
                )
            }
            do {
                let renderedPage = try await pageRenderer.prepareReplayPage(
                    drawingData: drawingData,
                    timing: timing,
                    limits: limits
                )
                try Task.checkCancellation()
                let conservativeByteCount = Self.addedSaturating(
                    renderedPage.conservativeByteCount,
                    historicalElementsByteCount
                )
                let preparedPage = NoteReplayPreparedPage(
                    conservativeByteCount: conservativeByteCount,
                    preparationFallback: renderedPage.preparationFallback,
                    historicalElements: historicalElements
                ) { playbackTime, mode in
                    try await renderedPage.render(at: playbackTime, mode: mode)
                }
                guard preparedPage.conservativeByteCount <= maximumCacheByteCount else {
                    return .issue(
                        scene.isHistoricalSnapshot
                            ? .historicalSceneUnavailable(pageID)
                            : .cacheBudgetExceeded(
                                pageID,
                                maximumByteCount: maximumCacheByteCount
                            )
                    )
                }
                return .prepared(preparedPage)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .issue(
                    scene.isHistoricalSnapshot
                        ? .historicalSceneUnavailable(pageID)
                        : .renderingUnavailable(pageID)
                )
            }
        }
        pagePreparationTask = task
        let result = await task.value
        if pagePreparationGeneration == preparationGeneration {
            pagePreparationTask = nil
        }
        guard !Task.isCancelled,
              isCurrentPresentation(
            sessionGeneration: sessionGeneration,
            presentationGeneration: presentationGeneration,
            sceneKey: scene.key
        ), pagePreparationGeneration == preparationGeneration else {
            return nil
        }

        switch result {
        case .prepared(let preparedPage):
            guard cache(preparedPage, for: scene.key) else {
                cancelFrameWork()
                let issue: NoteReplayPageIssue = scene.isHistoricalSnapshot
                    ? .historicalSceneUnavailable(pageID)
                    : .cacheBudgetExceeded(
                        pageID,
                        maximumByteCount: configuration.maximumCacheByteCount
                    )
                scenePreparationIssues[scene.key] = issue
                pageIssue = issue
                currentPageFrame = nil
                return nil
            }
            pageIssue = preparedPage.preparationFallback.map {
                NoteReplayPageIssue.rendererFallback(pageID, $0)
            }
            return preparedPage
        case .issue(let issue):
            cancelFrameWork()
            scenePreparationIssues[scene.key] = issue
            pageIssue = issue
            currentPageFrame = nil
            return nil
        case .cancelled:
            return nil
        }
    }

    private func renderImmediately(
        preparedPage: NoteReplayPreparedPage,
        pageID: PageID,
        sceneKey: NoteReplaySceneKey,
        playbackTime: TimeInterval,
        sessionGeneration: UUID,
        presentationGeneration: UUID
    ) async {
        cancelFrameWork()
        lastFrameStartMonotonicTime = scheduler.monotonicTime
        do {
            let frame = try await preparedPage.render(
                at: playbackTime,
                mode: mode
            )
            try Task.checkCancellation()
            guard isCurrentPresentation(
                sessionGeneration: sessionGeneration,
                presentationGeneration: presentationGeneration,
                sceneKey: sceneKey
            ) else {
                return
            }
            publish(frame: frame, pageID: pageID, sceneKey: sceneKey)
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentPresentation(
                sessionGeneration: sessionGeneration,
                presentationGeneration: presentationGeneration,
                sceneKey: sceneKey
            ) else {
                return
            }
            pageIssue = sceneKey.isHistoricalSnapshot
                ? .historicalSceneUnavailable(pageID)
                : .renderingUnavailable(pageID)
            currentPageFrame = nil
        }
    }

    private func enqueueFrame(_ request: FrameRequest) {
        pendingFrameRequest = request
        startPendingFrameIfPossible()
    }

    private func startPendingFrameIfPossible() {
        guard frameTask == nil,
              let request = pendingFrameRequest else {
            return
        }
        let now = scheduler.monotonicTime
        let minimumInterval = 1 / configuration.maximumFramesPerSecond
        if let lastFrameStartMonotonicTime {
            let elapsed = now - lastFrameStartMonotonicTime
            guard elapsed.isFinite, elapsed >= minimumInterval else {
                scheduleFrameWake(after: max(minimumInterval - max(elapsed, 0), 0))
                return
            }
        }

        frameWakeTask?.cancel()
        frameWakeTask = nil
        pendingFrameRequest = nil
        lastFrameStartMonotonicTime = now
        let taskGeneration = UUID()
        frameTaskGeneration = taskGeneration
        let task = Task { @MainActor [weak self] in
            let result: Result<NoteReplayFrame, Error>
            do {
                result = .success(try await request.preparedPage.render(
                    at: request.playbackTime,
                    mode: request.mode
                ))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.completeFrameTask(
                result,
                request: request,
                taskGeneration: taskGeneration
            )
        }
        frameTask = task
    }

    private func completeFrameTask(
        _ result: Result<NoteReplayFrame, Error>,
        request: FrameRequest,
        taskGeneration: UUID
    ) {
        guard frameTaskGeneration == taskGeneration else { return }
        frameTask = nil

        // An in-flight frame is never published over a newer request. Only the
        // latest pending playback position survives a slow renderer.
        let hasNewerRequest = pendingFrameRequest != nil
        if !hasNewerRequest,
           isCurrentPresentation(
                sessionGeneration: request.sessionGeneration,
                presentationGeneration: request.presentationGeneration,
                sceneKey: request.sceneKey
           ) {
            switch result {
            case .success(let frame):
                publish(
                    frame: frame,
                    pageID: request.pageID,
                    sceneKey: request.sceneKey
                )
            case .failure(let error):
                if !(error is CancellationError) {
                    pageIssue = request.sceneKey.isHistoricalSnapshot
                        ? .historicalSceneUnavailable(request.pageID)
                        : .renderingUnavailable(request.pageID)
                    currentPageFrame = nil
                }
            }
        }
        startPendingFrameIfPossible()
    }

    private func scheduleFrameWake(after interval: TimeInterval) {
        guard frameWakeTask == nil else { return }
        let generation = UUID()
        frameWakeGeneration = generation
        let scheduler = self.scheduler
        frameWakeTask = Task { @MainActor [weak self] in
            do {
                try await scheduler.sleep(for: max(interval, 0.001))
            } catch {
                return
            }
            guard let self, self.frameWakeGeneration == generation else { return }
            self.frameWakeTask = nil
            self.startPendingFrameIfPossible()
        }
    }

    private func publish(
        frame: NoteReplayFrame,
        pageID: PageID,
        sceneKey: NoteReplaySceneKey
    ) {
        currentPageFrame = NoteReplayPageFrame(
            pageID: pageID,
            sceneKey: sceneKey,
            frame: frame
        )
        if let fallback = frame.fallback {
            pageIssue = .rendererFallback(pageID, fallback)
        } else if case .rendererFallback(let issuePageID, _) = pageIssue,
                  issuePageID == pageID {
            pageIssue = nil
        }
    }

    private func pollOnce(expectedSessionGeneration: UUID) async {
        guard state == .playing,
              isCurrentSession(expectedSessionGeneration) else {
            return
        }
        let expectedTransportGeneration = transportGeneration
        let snapshot: NoteReplayAudioPlaybackSnapshot
        do {
            snapshot = try await audioTransport.replayAudioPlaybackSnapshot()
            try Task.checkCancellation()
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentSession(expectedSessionGeneration),
                  transportGeneration == expectedTransportGeneration else {
                return
            }
            await failActiveSession(.audioTransportUnavailable)
            return
        }
        guard isCurrentSession(expectedSessionGeneration),
              transportGeneration == expectedTransportGeneration,
              state == .playing,
              let time = validatedPlaybackTime(snapshot.currentTime) else {
            if isCurrentSession(expectedSessionGeneration), state == .playing {
                await failActiveSession(.audioTransportUnavailable)
            }
            return
        }

        switch snapshot.status {
        case .playing:
            await synchronizePresentation(
                at: time,
                generation: expectedSessionGeneration,
                renderImmediately: false
            )
        case .paused:
            cancelPolling()
            await synchronizePresentation(
                at: time,
                generation: expectedSessionGeneration,
                renderImmediately: false
            )
            if isCurrentSession(expectedSessionGeneration) {
                state = .paused
            }
        case .finished:
            cancelPolling()
            await synchronizePresentation(
                at: duration,
                generation: expectedSessionGeneration,
                renderImmediately: false
            )
            if isCurrentSession(expectedSessionGeneration) {
                state = .finished
            }
        case .failed:
            await failActiveSession(.audioStoppedUnexpectedly)
        case .stopped:
            if time >= max(duration - configuration.naturalEndTolerance, 0) {
                cancelPolling()
                await synchronizePresentation(
                    at: duration,
                    generation: expectedSessionGeneration,
                    renderImmediately: false
                )
                if isCurrentSession(expectedSessionGeneration) {
                    state = .finished
                }
            } else {
                await failActiveSession(.audioStoppedUnexpectedly)
            }
        }
    }

    private func startPolling(for generation: UUID) {
        cancelPolling()
        let taskGeneration = UUID()
        pollTaskGeneration = taskGeneration
        let scheduler = self.scheduler
        let pollInterval = configuration.pollInterval
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await scheduler.sleep(for: pollInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self,
                      self.pollTaskGeneration == taskGeneration,
                      self.isCurrentSession(generation),
                      self.state == .playing else {
                    return
                }
                await self.pollOnce(expectedSessionGeneration: generation)
            }
            if let self, self.pollTaskGeneration == taskGeneration {
                self.pollTask = nil
            }
        }
    }

    private func cancelPolling() {
        pollTaskGeneration = UUID()
        pollTask?.cancel()
        pollTask = nil
    }

    private func validatedPlaybackTime(_ time: TimeInterval) -> TimeInterval? {
        guard time.isFinite,
              time >= 0,
              time <= duration + configuration.naturalEndTolerance else {
            return nil
        }
        return NoteReplayTimelinePlanner.clampedTime(time, duration: duration)
    }

    @discardableResult
    private func beginTransportAction() -> UUID {
        let generation = UUID()
        transportGeneration = generation
        return generation
    }

    private func runTransportControl(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) async {
        let requestGeneration = UUID()
        transportControlRequestGeneration = requestGeneration
        let previousTask = transportControlTask
        previousTask?.cancel()
        if previousTask != nil {
            let previousPagePreparationTask = pagePreparationTask
            pagePreparationGeneration = UUID()
            previousPagePreparationTask?.cancel()
            pagePreparationTask = nil
            _ = await previousPagePreparationTask?.value
        }
        await previousTask?.value
        guard !Task.isCancelled,
              transportControlRequestGeneration == requestGeneration else {
            return
        }

        let generation = UUID()
        transportControlTaskGeneration = generation
        let task = Task { @MainActor in
            await operation()
        }
        transportControlTask = task
        // The controller, not a transient SwiftUI caller task, owns transport
        // completion. Lifecycle stop explicitly cancels and fences this task.
        await task.value
        if transportControlTaskGeneration == generation,
           transportControlRequestGeneration == requestGeneration {
            transportControlTask = nil
        }
    }

    private func isCurrentSession(_ generation: UUID) -> Bool {
        sessionGeneration == generation && state != .idle && state != .stopping
    }

    private func isCurrentShutdown(
        _ shutdown: UUID,
        sessionGeneration: UUID
    ) -> Bool {
        shutdownGeneration == shutdown
            && self.sessionGeneration == sessionGeneration
            && state == .stopping
    }

    private func isCurrentPresentation(
        sessionGeneration: UUID,
        presentationGeneration: UUID,
        sceneKey: NoteReplaySceneKey
    ) -> Bool {
        isCurrentSession(sessionGeneration)
            && self.presentationGeneration == presentationGeneration
            && currentPageID == sceneKey.pageID
            && currentSceneKey == sceneKey
    }

    private func cancelStartupIfCurrent(_ generation: UUID) async {
        guard isCurrentSession(generation) else { return }
        let shutdown = UUID()
        shutdownGeneration = shutdown
        let fencedSessionGeneration = UUID()
        sessionGeneration = fencedSessionGeneration
        transportGeneration = UUID()
        presentationGeneration = UUID()
        state = .stopping
        cancelOwnedTasks(excludingStartup: true)
        await audioTransport.stopReplayAudio()
        guard isCurrentShutdown(
            shutdown,
            sessionGeneration: fencedSessionGeneration
        ) else { return }
        await dataSource.endReplaySession()
        guard isCurrentShutdown(
            shutdown,
            sessionGeneration: fencedSessionGeneration
        ) else { return }
        clearActiveSession(clearFailure: false)
        state = .idle
    }

    private func failActiveSession(
        _ failure: NoteReplayControllerFailure
    ) async {
        guard state != .idle, state != .stopping else { return }
        let shutdown = UUID()
        shutdownGeneration = shutdown
        let fencedSessionGeneration = UUID()
        sessionGeneration = fencedSessionGeneration
        transportGeneration = UUID()
        presentationGeneration = UUID()
        state = .stopping
        cancelOwnedTasks(excludingStartup: true)
        await audioTransport.stopReplayAudio()
        guard isCurrentShutdown(
            shutdown,
            sessionGeneration: fencedSessionGeneration
        ) else { return }
        await dataSource.endReplaySession()
        guard isCurrentShutdown(
            shutdown,
            sessionGeneration: fencedSessionGeneration
        ) else { return }
        clearActiveSession(clearFailure: false)
        self.failure = failure
        state = .idle
    }

    private func clearActiveSession(clearFailure: Bool) {
        notebookID = nil
        audioSessionID = nil
        timing = nil
        timeline = nil
        navigationPlan = nil
        history = nil
        playbackTime = 0
        duration = 0
        currentPageID = nil
        currentSceneKey = nil
        currentMarkID = nil
        currentPageFrame = nil
        pageIssue = nil
        pendingFrameRequest = nil
        lastFrameStartMonotonicTime = nil
        sceneCache.removeAll(keepingCapacity: false)
        scenePreparationIssues.removeAll(keepingCapacity: false)
        pageCacheByteCount = 0
        cacheAccessOrdinal = 0
        if clearFailure { failure = nil }
    }

    private func cancelFrameWork() {
        frameTaskGeneration = UUID()
        frameWakeGeneration = UUID()
        frameTask?.cancel()
        frameTask = nil
        frameWakeTask?.cancel()
        frameWakeTask = nil
        pendingFrameRequest = nil
    }

    private func cancelOwnedTasks(excludingStartup: Bool = false) {
        if !excludingStartup {
            startupTaskGeneration = UUID()
            startupTask?.cancel()
            startupTask = nil
        }
        transportControlTaskGeneration = UUID()
        transportControlRequestGeneration = UUID()
        transportControlTask?.cancel()
        transportControlTask = nil
        pagePreparationGeneration = UUID()
        pagePreparationTask?.cancel()
        pagePreparationTask = nil
        cancelFrameWork()
        cancelPolling()
    }

    private func cachedScene(
        for sceneKey: NoteReplaySceneKey
    ) -> NoteReplayPreparedPage? {
        guard var entry = sceneCache[sceneKey] else { return nil }
        cacheAccessOrdinal &+= 1
        entry.accessOrdinal = cacheAccessOrdinal
        sceneCache[sceneKey] = entry
        return entry.preparedPage
    }

    @discardableResult
    private func cache(
        _ preparedPage: NoteReplayPreparedPage,
        for sceneKey: NoteReplaySceneKey
    ) -> Bool {
        let byteCount = preparedPage.conservativeByteCount
        guard byteCount <= configuration.maximumCacheByteCount else {
            return false
        }
        if let replaced = sceneCache.removeValue(forKey: sceneKey) {
            pageCacheByteCount -= replaced.byteCount
        }
        while !sceneCache.isEmpty,
              (sceneCache.count >= configuration.maximumCachedSceneCount
                || (!cachedPageIDs.contains(sceneKey.pageID)
                    && cachedPageIDs.count
                        >= configuration.maximumCachedPageCount)
                || pageCacheByteCount
                    > configuration.maximumCacheByteCount - byteCount) {
            evictLeastRecentlyUsedScene()
        }
        guard sceneCache.count < configuration.maximumCachedSceneCount,
              (cachedPageIDs.contains(sceneKey.pageID)
                || cachedPageIDs.count < configuration.maximumCachedPageCount),
              pageCacheByteCount
                <= configuration.maximumCacheByteCount - byteCount else {
            return false
        }
        cacheAccessOrdinal &+= 1
        sceneCache[sceneKey] = CachedScene(
            preparedPage: preparedPage,
            byteCount: byteCount,
            accessOrdinal: cacheAccessOrdinal
        )
        pageCacheByteCount += byteCount
        return true
    }

    private func evictLeastRecentlyUsedScene() {
        guard let sceneKey = sceneCache.min(by: { lhs, rhs in
            if lhs.value.accessOrdinal != rhs.value.accessOrdinal {
                return lhs.value.accessOrdinal < rhs.value.accessOrdinal
            }
            return String(describing: lhs.key) < String(describing: rhs.key)
        })?.key,
        let entry = sceneCache.removeValue(forKey: sceneKey) else {
            return
        }
        pageCacheByteCount -= entry.byteCount
    }

    private func removeCachedPages(notIn eligiblePageIDs: Set<PageID>) {
        let removedSceneKeys = sceneCache.keys.filter {
            !eligiblePageIDs.contains($0.pageID)
        }
        for sceneKey in removedSceneKeys {
            if let entry = sceneCache.removeValue(forKey: sceneKey) {
                pageCacheByteCount -= entry.byteCount
            }
        }
        scenePreparationIssues = scenePreparationIssues.filter {
            eligiblePageIDs.contains($0.key.pageID)
        }
    }

    private func trimCacheForMemoryWarning() {
        guard let currentSceneKey,
              let current = sceneCache[currentSceneKey] else {
            sceneCache.removeAll(keepingCapacity: false)
            scenePreparationIssues.removeAll(keepingCapacity: false)
            pageCacheByteCount = 0
            return
        }
        sceneCache = [currentSceneKey: current]
        scenePreparationIssues = scenePreparationIssues.filter {
            $0.key == currentSceneKey
        }
        pageCacheByteCount = current.byteCount
    }

    private static func addedSaturating(_ lhs: Int, _ rhs: Int) -> Int {
        guard lhs >= 0, rhs >= 0, lhs <= Int.max - rhs else { return Int.max }
        return lhs + rhs
    }

    private static func multipliedSaturating(_ lhs: Int, _ rhs: Int) -> Int {
        guard lhs >= 0, rhs >= 0,
              lhs == 0 || rhs <= Int.max / lhs else {
            return Int.max
        }
        return lhs * rhs
    }

    /// Historical replay can present only pages for which the sealed history
    /// contains a scene. Before the first eligible timeline mark, prefer a
    /// requested page only when that page already has a snapshot at the current
    /// playback time; this prevents an editor page first visited later in the
    /// recording from leaking its future baseline at replay zero.
    private static func historyAwareNavigationInput(
        eligiblePageIDs: [PageID],
        requestedCurrentPageID: PageID?,
        playbackTime: TimeInterval,
        timeline: AudioTimelineDocument,
        history: NoteReplayHistoryDocument?
    ) -> (eligiblePageIDs: [PageID], fallbackPageID: PageID?) {
        guard let history else {
            return (eligiblePageIDs, requestedCurrentPageID)
        }

        let historicalPageIDs = Set(history.events.map(\.pageID))
        let projectedPageIDs = eligiblePageIDs.filter {
            historicalPageIDs.contains($0)
        }
        guard !projectedPageIDs.isEmpty else { return ([], nil) }
        let projectedPageSet = Set(projectedPageIDs)

        if let requestedCurrentPageID,
           projectedPageSet.contains(requestedCurrentPageID),
           history.events.contains(where: {
               $0.pageID == requestedCurrentPageID
                   && $0.timeSeconds <= playbackTime
           }) {
            return (projectedPageIDs, requestedCurrentPageID)
        }

        var earliestTimelineMark: AudioTimelineMark?
        for mark in timeline.marks where projectedPageSet.contains(mark.pageID) {
            if earliestTimelineMark.map({ timelineMarkPrecedes(mark, $0) })
                ?? true {
                earliestTimelineMark = mark
            }
        }
        if let earliestTimelineMark {
            return (projectedPageIDs, earliestTimelineMark.pageID)
        }

        var earliestHistoricalEvent: NoteReplaySnapshotEvent?
        for event in history.events
        where projectedPageSet.contains(event.pageID) {
            if earliestHistoricalEvent.map({
                historicalEventPrecedes(event, $0)
            }) ?? true {
                earliestHistoricalEvent = event
            }
        }
        if let earliestHistoricalEvent {
            return (projectedPageIDs, earliestHistoricalEvent.pageID)
        }

        return (projectedPageIDs, projectedPageIDs[0])
    }

    private static func timelineMarkPrecedes(
        _ lhs: AudioTimelineMark,
        _ rhs: AudioTimelineMark
    ) -> Bool {
        if lhs.timeSeconds != rhs.timeSeconds {
            return lhs.timeSeconds < rhs.timeSeconds
        }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }

    private static func historicalEventPrecedes(
        _ lhs: NoteReplaySnapshotEvent,
        _ rhs: NoteReplaySnapshotEvent
    ) -> Bool {
        if lhs.timeSeconds != rhs.timeSeconds {
            return lhs.timeSeconds < rhs.timeSeconds
        }
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }

    private static func validReplayDescriptorEnvelope(
        _ descriptor: AudioSessionDescriptor
    ) -> Bool {
        let replayFieldsPresent = [
            descriptor.replayFilename != nil,
            descriptor.replayByteCount != nil,
            descriptor.replaySHA256 != nil,
            descriptor.replayEventCount != nil,
        ]
        if descriptor.schemaVersion < 3 {
            return replayFieldsPresent.allSatisfy { !$0 }
        }
        guard descriptor.schemaVersion == 3,
              replayFieldsPresent.allSatisfy({ $0 }),
              let filename = descriptor.replayFilename,
              let byteCount = descriptor.replayByteCount,
              let digest = descriptor.replaySHA256,
              let eventCount = descriptor.replayEventCount else {
            return false
        }
        return filename == "\(descriptor.id.description).replay.json"
            && byteCount > 0
            && byteCount <= Int64(NoteReplayHistoryLimits.maximumIndexBytes)
            && isLowercaseSHA256(digest)
            && (0...NoteReplayHistoryLimits.maximumEventCount)
                .contains(eventCount)
    }

    private static func descriptorHistoryMatches(
        descriptor: AudioSessionDescriptor,
        history: NoteReplayHistoryDocument?
    ) -> Bool {
        if descriptor.schemaVersion < 3 { return history == nil }
        guard descriptor.schemaVersion == 3,
              let replayEventCount = descriptor.replayEventCount,
              let history else {
            return false
        }
        return history.events.count == replayEventCount
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains(Int($0.value))
                || (97...102).contains(Int($0.value))
        }
    }

    private static func validHistory(
        _ history: NoteReplayHistoryDocument,
        sessionID: AudioSessionID,
        duration: TimeInterval,
        maximumEventCount: Int
    ) -> Bool {
        guard history.schemaVersion == NoteReplayHistoryDocument.currentSchemaVersion,
              history.audioSessionID == sessionID,
              history.sealedAt.timeIntervalSinceReferenceDate.isFinite,
              history.events.count <= maximumEventCount,
              Set(history.events.map(\.id)).count == history.events.count,
              Set(history.events.map(\.operationID)).count
                == history.events.count else {
            return false
        }
        var previousSequence = -1
        var previousEventTime: TimeInterval?
        var firstKindByPage: [PageID: NoteReplaySnapshotEventKind] = [:]
        var lastKindByPage: [PageID: NoteReplaySnapshotEventKind] = [:]
        var lastTimeByPage: [PageID: TimeInterval] = [:]
        var countByPage: [PageID: Int] = [:]
        var terminalPages: Set<PageID> = []
        for (eventIndex, event) in history.events.enumerated() {
            let isFirstPageEvent = countByPage[event.pageID] == nil
            guard event.sequence == eventIndex,
                  event.sequence > previousSequence,
                  event.timeSeconds.isFinite,
                  event.timeSeconds >= (previousEventTime ?? 0),
                  event.timeSeconds >= (lastTimeByPage[event.pageID] ?? 0),
                  event.timeSeconds >= 0,
                  event.timeSeconds <= duration,
                  event.kind != .terminal || event.timeSeconds == duration,
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
            firstKindByPage[event.pageID] = firstKindByPage[event.pageID]
                ?? event.kind
            lastKindByPage[event.pageID] = event.kind
            lastTimeByPage[event.pageID] = event.timeSeconds
            countByPage[event.pageID, default: 0] += 1
            if event.kind == .terminal {
                terminalPages.insert(event.pageID)
            }
            guard countByPage[event.pageID, default: 0]
                    <= NoteReplayHistoryLimits.maximumEventsPerPage else {
                return false
            }
        }
        if firstKindByPage.isEmpty { return history.events.isEmpty }
        return firstKindByPage.values.allSatisfy { $0 == .baseline }
            && lastKindByPage.values.allSatisfy { $0 == .terminal }
    }
}
