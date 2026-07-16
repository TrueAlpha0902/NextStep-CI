import Foundation
import NotesCore
import PencilKit
import UIKit

/// Stable iPadOS 18 replay presentations. PencilKit does not expose a public,
/// exact sub-stroke API on this deployment target, so replay never fabricates a
/// replacement curve from sampled points.
enum NoteReplayMode: String, CaseIterable, Identifiable, Sendable {
    /// A timed stroke appears in full when its first recorded sample is due.
    case wholeStrokeReveal
    /// The same exact whole-stroke reveal, with future strokes shown dimmed.
    case spotlight
    /// The authoritative final drawing without replay filtering.
    case `static`

    var id: String { rawValue }
}

/// Identity of the immutable visual state a Replay frame was derived from.
/// Legacy pages intentionally retain their old final-page behavior; snapshot
/// keys fence append-only historical scenes from newer editor state.
enum NoteReplaySceneKey: Hashable, Sendable {
    case legacy(PageID)
    case snapshot(PageID, NoteReplayEventID)

    var pageID: PageID {
        switch self {
        case .legacy(let pageID), .snapshot(let pageID, _):
            pageID
        }
    }

    var isHistoricalSnapshot: Bool {
        if case .snapshot = self { return true }
        return false
    }
}

struct NoteReplaySceneSelection: Sendable {
    let key: NoteReplaySceneKey
    let inkPayload: NoteReplayPayloadReference?
    let elementsPayload: NoteReplayPayloadReference?

    var pageID: PageID { key.pageID }
    var isHistoricalSnapshot: Bool { key.isHistoricalSnapshot }

    static func legacy(_ pageID: PageID) -> NoteReplaySceneSelection {
        NoteReplaySceneSelection(
            key: .legacy(pageID),
            inkPayload: nil,
            elementsPayload: nil
        )
    }
}

/// Pure, deterministic projection from append-only history to one immutable
/// scene. Snapshot payloads are complete page states: nil ink represents an
/// empty ink layer, and elements always carry a reference. Neither grants
/// permission to consult the editor's newer final state.
enum NoteReplaySceneSelector {
    static func selection(
        pageID: PageID,
        playbackTime: TimeInterval,
        mode: NoteReplayMode,
        history: NoteReplayHistoryDocument?
    ) -> NoteReplaySceneSelection? {
        guard playbackTime.isFinite else { return nil }
        guard let history else {
            return .legacy(pageID)
        }
        var earliestBaseline: NoteReplaySnapshotEvent?
        var latestDueEvent: NoteReplaySnapshotEvent?
        var terminalEvent: NoteReplaySnapshotEvent?
        for event in history.events where event.pageID == pageID {
            if event.kind == .baseline,
               (earliestBaseline.map({ eventPrecedes(event, $0) }) ?? true) {
                earliestBaseline = event
            }
            if event.timeSeconds <= playbackTime,
               (latestDueEvent.map({ eventPrecedes($0, event) }) ?? true) {
                latestDueEvent = event
            }
            if event.kind == .terminal,
               (terminalEvent.map({ eventPrecedes($0, event) }) ?? true) {
                terminalEvent = event
            }
        }
        // Static Replay means the recording's terminal state, never the
        // current editor document and never a partial change checkpoint.
        let selectedEvent = mode == .static
            ? terminalEvent
            : (latestDueEvent ?? earliestBaseline)
        guard let selectedEvent else { return nil }
        return NoteReplaySceneSelection(
            key: .snapshot(pageID, selectedEvent.id),
            inkPayload: selectedEvent.inkPayload,
            elementsPayload: selectedEvent.elementsPayload
        )
    }

    private static func eventPrecedes(
        _ lhs: NoteReplaySnapshotEvent,
        _ rhs: NoteReplaySnapshotEvent
    ) -> Bool {
        if lhs.timeSeconds != rhs.timeSeconds {
            return lhs.timeSeconds < rhs.timeSeconds
        }
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        return lhs.id.description < rhs.id.description
    }
}

struct NoteReplayRenderingLimits: Equatable, Sendable {
    static let `default` = NoteReplayRenderingLimits()

    /// Conservative accounting constants. This is an interactive replay budget,
    /// not a claim about PencilKit's private decoded representation.
    static let estimatedBytesPerStroke = 1_024
    static let estimatedBytesPerPoint = 256
    static let hardMaximumDrawingByteCount = 1 * 1_024 * 1_024
    static let hardMaximumStrokeCount = 1_024
    static let hardMaximumPointCount = 20_000
    static let hardMaximumPointsPerStroke = 2_048
    static let hardMaximumEstimatedDecodedStructureByteCount = 8 * 1_024 * 1_024

    /// `PKDrawing(data:)` is synchronous and cannot be preempted once entered.
    /// Keep this substantially below the app's general document/import limits.
    let maximumDrawingByteCount: Int
    let maximumStrokeCount: Int
    let maximumPointCount: Int
    let maximumPointsPerStroke: Int
    /// A second, structural guard because encoded bytes do not bound decoded
    /// memory. It is checked immediately after PencilKit's synchronous decode.
    let maximumEstimatedDecodedStructureByteCount: Int
    let maximumStrokeDuration: TimeInterval
    let maximumMetadataDistanceFromSession: TimeInterval
    let sessionEndTolerance: TimeInterval
    let spotlightOpacity: CGFloat

    init(
        maximumDrawingByteCount: Int = 1 * 1_024 * 1_024,
        maximumStrokeCount: Int = 1_024,
        maximumPointCount: Int = 20_000,
        maximumPointsPerStroke: Int = 2_048,
        maximumEstimatedDecodedStructureByteCount: Int = 8 * 1_024 * 1_024,
        maximumStrokeDuration: TimeInterval = 60 * 60,
        maximumMetadataDistanceFromSession: TimeInterval = 10 * 366 * 24 * 60 * 60,
        sessionEndTolerance: TimeInterval = 1,
        spotlightOpacity: CGFloat = 0.18
    ) {
        self.maximumDrawingByteCount = min(
            max(maximumDrawingByteCount, 1),
            Self.hardMaximumDrawingByteCount
        )
        self.maximumStrokeCount = min(
            max(maximumStrokeCount, 1),
            Self.hardMaximumStrokeCount
        )
        self.maximumPointCount = min(
            max(maximumPointCount, 1),
            Self.hardMaximumPointCount
        )
        self.maximumPointsPerStroke = min(
            max(maximumPointsPerStroke, 1),
            Self.hardMaximumPointsPerStroke
        )
        self.maximumEstimatedDecodedStructureByteCount = min(
            max(maximumEstimatedDecodedStructureByteCount, 1),
            Self.hardMaximumEstimatedDecodedStructureByteCount
        )
        self.maximumStrokeDuration = Self.finiteNonnegative(
            maximumStrokeDuration,
            defaultValue: 60 * 60
        )
        self.maximumMetadataDistanceFromSession = Self.finiteNonnegative(
            maximumMetadataDistanceFromSession,
            defaultValue: 10 * 366 * 24 * 60 * 60
        )
        self.sessionEndTolerance = Self.finiteNonnegative(
            sessionEndTolerance,
            defaultValue: 1
        )
        self.spotlightOpacity = spotlightOpacity.isFinite
            ? min(max(spotlightOpacity, 0), 1)
            : 0.18
    }

    private static func finiteNonnegative(
        _ value: TimeInterval,
        defaultValue: TimeInterval
    ) -> TimeInterval {
        value.isFinite ? max(value, 0) : defaultValue
    }
}

enum NoteReplayFrameFallback: Equatable, Sendable {
    case drawingByteLimit(limit: Int)
    case strokeCountLimit(limit: Int)
    case pointsPerStrokeLimit(limit: Int)
    case pointCountLimit(limit: Int)
    case estimatedDecodedStructureLimit(limit: Int)
    case invalidSessionMetadata
}

/// The only stable replay strategy used by the iPadOS 18 implementation.
enum NoteReplayStrokePresentationStrategy: String, Equatable, Sendable {
    case exactWholeOriginalStrokeAtFirstSample
}

struct NoteReplayFrame: Sendable {
    /// `nil` means the consumer must keep displaying its already loaded,
    /// authoritative drawing. This happens when the encoded input is refused
    /// before PencilKit decoding.
    let drawing: PKDrawing?
    let requestedMode: NoteReplayMode
    let appliedMode: NoteReplayMode
    let playbackTime: TimeInterval
    let fallback: NoteReplayFrameFallback?
    let metadataFallbackStrokeCount: Int
    let processedStrokeCount: Int
    /// Always zero. Point validation is preparation-only and no frame samples,
    /// slices, or rebuilds a path.
    let processedPointCount: Int
    let revealedTimedStrokeCount: Int
    let strokePresentationStrategy: NoteReplayStrokePresentationStrategy
    /// A non-nil value is the complete structured-element state captured by a
    /// historical Replay scene. `nil` deliberately preserves the legacy path,
    /// whose read-only surface may reuse the editor's authoritative elements.
    let historicalElements: [CanvasElement]?

    init(
        drawing: PKDrawing?,
        requestedMode: NoteReplayMode,
        appliedMode: NoteReplayMode,
        playbackTime: TimeInterval,
        fallback: NoteReplayFrameFallback?,
        metadataFallbackStrokeCount: Int,
        processedStrokeCount: Int,
        processedPointCount: Int,
        revealedTimedStrokeCount: Int,
        strokePresentationStrategy: NoteReplayStrokePresentationStrategy,
        historicalElements: [CanvasElement]? = nil
    ) {
        self.drawing = drawing
        self.requestedMode = requestedMode
        self.appliedMode = appliedMode
        self.playbackTime = playbackTime
        self.fallback = fallback
        self.metadataFallbackStrokeCount = metadataFallbackStrokeCount
        self.processedStrokeCount = processedStrokeCount
        self.processedPointCount = processedPointCount
        self.revealedTimedStrokeCount = revealedTimedStrokeCount
        self.strokePresentationStrategy = strokePresentationStrategy
        self.historicalElements = historicalElements
    }

    var requiresAuthoritativeDrawingReuse: Bool {
        drawing == nil
    }

    var usesStaticPresentation: Bool {
        appliedMode == .static
    }

    func replacingHistoricalElements(
        _ historicalElements: [CanvasElement]?
    ) -> NoteReplayFrame {
        NoteReplayFrame(
            drawing: drawing,
            requestedMode: requestedMode,
            appliedMode: appliedMode,
            playbackTime: playbackTime,
            fallback: fallback,
            metadataFallbackStrokeCount: metadataFallbackStrokeCount,
            processedStrokeCount: processedStrokeCount,
            processedPointCount: processedPointCount,
            revealedTimedStrokeCount: revealedTimedStrokeCount,
            strokePresentationStrategy: strokePresentationStrategy,
            historicalElements: historicalElements
        )
    }
}

enum NoteReplayRenderingError: Error, Equatable {
    case invalidDrawingData
}

/// Internal synchronization seams used by deterministic concurrency tests.
/// Production callers use `.none`; none of these hooks changes replay output.
struct NoteReplayWorkerHooks: Sendable {
    static let none = NoteReplayWorkerHooks()

    let afterDrawingDecodeFailureBeforeCancellationCheck:
        (@Sendable () async -> Void)?
    let afterWorkerFailureBeforeRethrow: (@Sendable () async -> Void)?
    let didCreateDimmedStroke: (@Sendable () async -> Void)?

    init(
        afterDrawingDecodeFailureBeforeCancellationCheck:
            (@Sendable () async -> Void)? = nil,
        afterWorkerFailureBeforeRethrow:
            (@Sendable () async -> Void)? = nil,
        didCreateDimmedStroke:
            (@Sendable () async -> Void)? = nil
    ) {
        self.afterDrawingDecodeFailureBeforeCancellationCheck =
            afterDrawingDecodeFailureBeforeCancellationCheck
        self.afterWorkerFailureBeforeRethrow = afterWorkerFailureBeforeRethrow
        self.didCreateDimmedStroke = didCreateDimmedStroke
    }
}

enum NoteReplayStrokePreparationDecision: Equatable, Sendable {
    case alwaysVisible(metadataFallback: Bool)
    case timedCandidate
}

/// A pure classification seam shared by production preparation and regression
/// tests. Only `.timedCandidate` is permitted to reach dimmed-copy creation.
enum NoteReplayStrokePreparationClassifier {
    static func decision(
        relativeStart: TimeInterval,
        duration: TimeInterval,
        maximumMetadataDistanceFromSession: TimeInterval,
        presentationIsValid: Bool
    ) -> NoteReplayStrokePreparationDecision {
        guard relativeStart.isFinite,
              abs(relativeStart) <= maximumMetadataDistanceFromSession,
              presentationIsValid else {
            return .alwaysVisible(metadataFallback: true)
        }
        guard relativeStart >= 0, relativeStart <= duration else {
            return .alwaysVisible(metadataFallback: false)
        }
        return .timedCandidate
    }
}

/// The enum shape makes it impossible for an always-visible stroke to retain a
/// dimmed copy. Only fully validated timed strokes pay that memory/work cost.
fileprivate enum NoteReplayPreparedStroke: Sendable {
    case alwaysVisible(source: PKStroke)
    case timed(
        source: PKStroke,
        dimmedSource: PKStroke,
        revealTime: TimeInterval
    )
}

/// Immutable, Sendable replay state prepared on a detached worker. Xcode 26's
/// stable PencilKit SDK marks the value types held here Sendable for an iPadOS
/// 18 deployment. No beta subpath, Bezier, render-state, or substroke API is
/// used.
final class PreparedNoteReplayDrawing: Sendable {
    fileprivate let authoritativeDrawing: PKDrawing?
    fileprivate let strokes: [NoteReplayPreparedStroke]
    fileprivate let timing: NoteReplaySessionTiming
    fileprivate let limits: NoteReplayRenderingLimits

    let preparationFallback: NoteReplayFrameFallback?
    let metadataFallbackStrokeCount: Int
    let decodedStrokeCount: Int
    let decodedPointCount: Int
    let validatedReplayPointCount: Int
    let estimatedDecodedStructureByteCount: Int
    let timedStrokeCount: Int
    let strokePresentationStrategy: NoteReplayStrokePresentationStrategy

    fileprivate init(
        authoritativeDrawing: PKDrawing?,
        strokes: [NoteReplayPreparedStroke],
        timing: NoteReplaySessionTiming,
        limits: NoteReplayRenderingLimits,
        preparationFallback: NoteReplayFrameFallback?,
        metadataFallbackStrokeCount: Int,
        decodedStrokeCount: Int,
        decodedPointCount: Int,
        validatedReplayPointCount: Int,
        estimatedDecodedStructureByteCount: Int,
        timedStrokeCount: Int,
        strokePresentationStrategy: NoteReplayStrokePresentationStrategy =
            .exactWholeOriginalStrokeAtFirstSample
    ) {
        self.authoritativeDrawing = authoritativeDrawing
        self.strokes = strokes
        self.timing = timing
        self.limits = limits
        self.preparationFallback = preparationFallback
        self.metadataFallbackStrokeCount = metadataFallbackStrokeCount
        self.decodedStrokeCount = decodedStrokeCount
        self.decodedPointCount = decodedPointCount
        self.validatedReplayPointCount = validatedReplayPointCount
        self.estimatedDecodedStructureByteCount = estimatedDecodedStructureByteCount
        self.timedStrokeCount = timedStrokeCount
        self.strokePresentationStrategy = strokePresentationStrategy
    }
}

fileprivate struct NoteReplayValidatedStrokeTiming: Sendable {
    let revealTime: TimeInterval
}

/// Derives final-stroke replay frames without mutating or publishing over the
/// authoritative PencilKit data.
enum NoteReplayRenderer {
    /// Decode and bounded validation are always moved off the caller's actor.
    /// Cancellation is checked before and after `PKDrawing(data:)`; PencilKit's
    /// synchronous decoder itself has no public cancellation hook, so an
    /// in-flight decode finishes on the worker before cancellation is observed.
    static func prepareDrawing(
        drawingData: Data?,
        timing: NoteReplaySessionTiming,
        limits: NoteReplayRenderingLimits = .default,
        workerHooks: NoteReplayWorkerHooks = .none
    ) async throws -> PreparedNoteReplayDrawing {
        try Task<Never, Never>.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { @Sendable in
            try await prepareDrawingOnWorker(
                drawingData: drawingData,
                timing: timing,
                limits: limits,
                workerHooks: workerHooks
            )
        }
        return try await awaitWorker(
            worker,
            afterWorkerFailureBeforeRethrow:
                workerHooks.afterWorkerFailureBeforeRethrow
        )
    }

    /// Frame assembly also runs off the caller's actor. Frames only select
    /// already prepared whole strokes; they never inspect a stroke point.
    static func renderFrame(
        preparedDrawing: PreparedNoteReplayDrawing,
        playbackTime: TimeInterval,
        mode: NoteReplayMode
    ) async throws -> NoteReplayFrame {
        try Task<Never, Never>.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { @Sendable in
            try renderFrameOnWorker(
                preparedDrawing: preparedDrawing,
                playbackTime: playbackTime,
                mode: mode
            )
        }
        return try await awaitWorker(worker)
    }

    private static func awaitWorker<Value: Sendable>(
        _ worker: Task<Value, Error>,
        afterWorkerFailureBeforeRethrow:
            (@Sendable () async -> Void)? = nil
    ) async throws -> Value {
        let value: Value
        do {
            value = try await withTaskCancellationHandler(
                operation: {
                    try await worker.value
                },
                onCancel: {
                    worker.cancel()
                }
            )
        } catch {
            if let afterWorkerFailureBeforeRethrow {
                await afterWorkerFailureBeforeRethrow()
            }
            // A worker error must not mask cancellation of the caller's newer
            // replay generation.
            try Task<Never, Never>.checkCancellation()
            throw error
        }

        // Close the worker-completion/caller-cancellation race before handing a
        // result back. The controller must still compare its generation token
        // so a result returned before a later seek cannot replace newer state.
        try Task<Never, Never>.checkCancellation()
        return value
    }

    private static func prepareDrawingOnWorker(
        drawingData: Data?,
        timing: NoteReplaySessionTiming,
        limits: NoteReplayRenderingLimits,
        workerHooks: NoteReplayWorkerHooks
    ) async throws -> PreparedNoteReplayDrawing {
        try Task<Never, Never>.checkCancellation()

        guard let drawingData else {
            let fallback: NoteReplayFrameFallback? = NoteReplaySessionPolicy.isValid(timing)
                ? nil
                : .invalidSessionMetadata
            return PreparedNoteReplayDrawing(
                authoritativeDrawing: PKDrawing(),
                strokes: [],
                timing: timing,
                limits: limits,
                preparationFallback: fallback,
                metadataFallbackStrokeCount: 0,
                decodedStrokeCount: 0,
                decodedPointCount: 0,
                validatedReplayPointCount: 0,
                estimatedDecodedStructureByteCount: 0,
                timedStrokeCount: 0
            )
        }

        guard drawingData.count <= limits.maximumDrawingByteCount else {
            return PreparedNoteReplayDrawing(
                authoritativeDrawing: nil,
                strokes: [],
                timing: timing,
                limits: limits,
                preparationFallback: .drawingByteLimit(
                    limit: limits.maximumDrawingByteCount
                ),
                metadataFallbackStrokeCount: 0,
                decodedStrokeCount: 0,
                decodedPointCount: 0,
                validatedReplayPointCount: 0,
                estimatedDecodedStructureByteCount: 0,
                timedStrokeCount: 0
            )
        }

        let drawing: PKDrawing
        do {
            // Public PencilKit provides no incremental or cancellable decoder.
            drawing = try PKDrawing(data: drawingData)
        } catch {
            if let hook = workerHooks.afterDrawingDecodeFailureBeforeCancellationCheck {
                await hook()
            }
            // Cancellation always outranks a decode error that completed while
            // the caller was cancelling this generation.
            try Task<Never, Never>.checkCancellation()
            throw NoteReplayRenderingError.invalidDrawingData
        }
        try Task<Never, Never>.checkCancellation()

        let sourceStrokes = drawing.strokes
        guard sourceStrokes.count <= limits.maximumStrokeCount else {
            // Do not retain an over-budget decoded drawing. The editor already
            // owns the authoritative page and will keep showing that static copy.
            return staticPreparation(
                drawing: nil,
                timing: timing,
                limits: limits,
                fallback: .strokeCountLimit(limit: limits.maximumStrokeCount),
                decodedStrokeCount: sourceStrokes.count
            )
        }

        guard let strokeEstimate = multipliedWithoutOverflow(
            sourceStrokes.count,
            NoteReplayRenderingLimits.estimatedBytesPerStroke
        ) else {
            return staticPreparation(
                drawing: nil,
                timing: timing,
                limits: limits,
                fallback: .estimatedDecodedStructureLimit(
                    limit: limits.maximumEstimatedDecodedStructureByteCount
                ),
                decodedStrokeCount: sourceStrokes.count
            )
        }
        guard strokeEstimate <= limits.maximumEstimatedDecodedStructureByteCount else {
            return staticPreparation(
                drawing: nil,
                timing: timing,
                limits: limits,
                fallback: .estimatedDecodedStructureLimit(
                    limit: limits.maximumEstimatedDecodedStructureByteCount
                ),
                decodedStrokeCount: sourceStrokes.count,
                estimatedDecodedStructureByteCount: strokeEstimate
            )
        }

        var decodedPointCount = 0
        var estimatedDecodedStructureByteCount = strokeEstimate
        for (strokeIndex, stroke) in sourceStrokes.enumerated() {
            if strokeIndex.isMultiple(of: 32) {
                try Task<Never, Never>.checkCancellation()
            }
            let pointCount = stroke.path.count
            guard pointCount <= limits.maximumPointsPerStroke else {
                return staticPreparation(
                    drawing: nil,
                    timing: timing,
                    limits: limits,
                    fallback: .pointsPerStrokeLimit(
                        limit: limits.maximumPointsPerStroke
                    ),
                    decodedStrokeCount: sourceStrokes.count,
                    decodedPointCount: decodedPointCount,
                    estimatedDecodedStructureByteCount:
                        estimatedDecodedStructureByteCount
                )
            }
            guard pointCount <= limits.maximumPointCount,
                  decodedPointCount <= limits.maximumPointCount - pointCount else {
                return staticPreparation(
                    drawing: nil,
                    timing: timing,
                    limits: limits,
                    fallback: .pointCountLimit(limit: limits.maximumPointCount),
                    decodedStrokeCount: sourceStrokes.count,
                    decodedPointCount: decodedPointCount,
                    estimatedDecodedStructureByteCount:
                        estimatedDecodedStructureByteCount
                )
            }
            guard let pointEstimate = multipliedWithoutOverflow(
                pointCount,
                NoteReplayRenderingLimits.estimatedBytesPerPoint
            ), pointEstimate <= limits.maximumEstimatedDecodedStructureByteCount,
               estimatedDecodedStructureByteCount
                <= limits.maximumEstimatedDecodedStructureByteCount - pointEstimate else {
                return staticPreparation(
                    drawing: nil,
                    timing: timing,
                    limits: limits,
                    fallback: .estimatedDecodedStructureLimit(
                        limit: limits.maximumEstimatedDecodedStructureByteCount
                    ),
                    decodedStrokeCount: sourceStrokes.count,
                    decodedPointCount: decodedPointCount,
                    estimatedDecodedStructureByteCount:
                        estimatedDecodedStructureByteCount
                )
            }
            decodedPointCount += pointCount
            estimatedDecodedStructureByteCount += pointEstimate
        }

        guard NoteReplaySessionPolicy.isValid(timing) else {
            return staticPreparation(
                drawing: drawing,
                timing: timing,
                limits: limits,
                fallback: .invalidSessionMetadata,
                decodedStrokeCount: sourceStrokes.count,
                decodedPointCount: decodedPointCount,
                estimatedDecodedStructureByteCount:
                    estimatedDecodedStructureByteCount
            )
        }

        var preparedStrokes: [NoteReplayPreparedStroke] = []
        preparedStrokes.reserveCapacity(sourceStrokes.count)
        var metadataFallbackStrokeCount = 0
        var validatedReplayPointCount = 0
        var timedStrokeCount = 0

        for (strokeIndex, stroke) in sourceStrokes.enumerated() {
            if strokeIndex.isMultiple(of: 32) {
                try Task<Never, Never>.checkCancellation()
            }

            let relativeStart = stroke.path.creationDate.timeIntervalSince(
                timing.recordingStartedAt
            )
            switch NoteReplayStrokePreparationClassifier.decision(
                relativeStart: relativeStart,
                duration: timing.duration,
                maximumMetadataDistanceFromSession:
                    limits.maximumMetadataDistanceFromSession,
                presentationIsValid: validPresentation(stroke)
            ) {
            case let .alwaysVisible(metadataFallback):
                if metadataFallback {
                    metadataFallbackStrokeCount += 1
                }
                preparedStrokes.append(.alwaysVisible(source: stroke))
                continue
            case .timedCandidate:
                break
            }

            var inspectedPointCount = 0
            guard let strokeTiming = try validatedStrokeTiming(
                stroke,
                relativeStart: relativeStart,
                timing: timing,
                limits: limits,
                inspectedPointCount: &inspectedPointCount
            ) else {
                validatedReplayPointCount += inspectedPointCount
                metadataFallbackStrokeCount += 1
                preparedStrokes.append(.alwaysVisible(source: stroke))
                continue
            }
            validatedReplayPointCount += inspectedPointCount
            let dimmedSource = dimmedStroke(
                stroke,
                opacity: limits.spotlightOpacity
            )
            if let didCreateDimmedStroke = workerHooks.didCreateDimmedStroke {
                await didCreateDimmedStroke()
            }
            try Task<Never, Never>.checkCancellation()
            preparedStrokes.append(.timed(
                source: stroke,
                dimmedSource: dimmedSource,
                revealTime: strokeTiming.revealTime
            ))
            timedStrokeCount += 1
        }

        try Task<Never, Never>.checkCancellation()
        return PreparedNoteReplayDrawing(
            authoritativeDrawing: drawing,
            strokes: preparedStrokes,
            timing: timing,
            limits: limits,
            preparationFallback: nil,
            metadataFallbackStrokeCount: metadataFallbackStrokeCount,
            decodedStrokeCount: sourceStrokes.count,
            decodedPointCount: decodedPointCount,
            validatedReplayPointCount: validatedReplayPointCount,
            estimatedDecodedStructureByteCount: estimatedDecodedStructureByteCount,
            timedStrokeCount: timedStrokeCount
        )
    }

    private static func renderFrameOnWorker(
        preparedDrawing: PreparedNoteReplayDrawing,
        playbackTime: TimeInterval,
        mode: NoteReplayMode
    ) throws -> NoteReplayFrame {
        try Task<Never, Never>.checkCancellation()
        let validTiming = NoteReplaySessionPolicy.isValid(preparedDrawing.timing)
        let clampedPlaybackTime = NoteReplayTimelinePlanner.clampedTime(
            playbackTime,
            duration: validTiming ? preparedDrawing.timing.duration : 0
        )

        if let fallback = preparedDrawing.preparationFallback {
            return staticFrame(
                drawing: preparedDrawing.authoritativeDrawing,
                requestedMode: mode,
                playbackTime: clampedPlaybackTime,
                fallback: fallback,
                metadataFallbackStrokeCount:
                    preparedDrawing.metadataFallbackStrokeCount
            )
        }

        guard mode != .static else {
            return completeFrame(
                preparedDrawing: preparedDrawing,
                requestedMode: mode,
                playbackTime: clampedPlaybackTime
            )
        }

        // The authoritative end state is returned directly, without scanning
        // prepared strokes or allocating a replacement drawing.
        if clampedPlaybackTime >= preparedDrawing.timing.duration {
            return completeFrame(
                preparedDrawing: preparedDrawing,
                requestedMode: mode,
                playbackTime: clampedPlaybackTime
            )
        }

        var renderedStrokes: [PKStroke] = []
        renderedStrokes.reserveCapacity(preparedDrawing.strokes.count)
        var revealedTimedStrokeCount = 0

        for (strokeIndex, preparedStroke) in preparedDrawing.strokes.enumerated() {
            if strokeIndex.isMultiple(of: 32) {
                try Task<Never, Never>.checkCancellation()
            }
            switch preparedStroke {
            case let .alwaysVisible(source):
                renderedStrokes.append(source)
            case let .timed(source, dimmedSource, revealTime):
                if clampedPlaybackTime >= revealTime {
                    // Reuse the exact decoded source stroke: no reconstructed
                    // path, interpolation, or point traversal.
                    renderedStrokes.append(source)
                    revealedTimedStrokeCount += 1
                } else if mode == .spotlight {
                    // Only ink opacity differs. Path, transform, mask, and
                    // random seed remain those of the exact decoded stroke.
                    renderedStrokes.append(dimmedSource)
                }
            }
        }
        try Task<Never, Never>.checkCancellation()

        return NoteReplayFrame(
            drawing: PKDrawing(strokes: renderedStrokes),
            requestedMode: mode,
            appliedMode: mode,
            playbackTime: clampedPlaybackTime,
            fallback: nil,
            metadataFallbackStrokeCount:
                preparedDrawing.metadataFallbackStrokeCount,
            processedStrokeCount: preparedDrawing.strokes.count,
            processedPointCount: 0,
            revealedTimedStrokeCount: revealedTimedStrokeCount,
            strokePresentationStrategy:
                preparedDrawing.strokePresentationStrategy
        )
    }

    private static func validatedStrokeTiming(
        _ stroke: PKStroke,
        relativeStart: TimeInterval,
        timing: NoteReplaySessionTiming,
        limits: NoteReplayRenderingLimits,
        inspectedPointCount: inout Int
    ) throws -> NoteReplayValidatedStrokeTiming? {
        guard !stroke.path.isEmpty else { return nil }
        var previousTime: TimeInterval = -.infinity
        var firstOffset: TimeInterval?

        for (pointIndex, point) in stroke.path.enumerated() {
            if pointIndex.isMultiple(of: 256) {
                try Task<Never, Never>.checkCancellation()
            }
            inspectedPointCount += 1
            guard validPoint(point),
                  point.timeOffset >= 0,
                  point.timeOffset >= previousTime,
                  point.timeOffset <= limits.maximumStrokeDuration,
                  relativeStart + point.timeOffset
                    <= timing.duration + limits.sessionEndTolerance else {
                return nil
            }
            firstOffset = firstOffset ?? point.timeOffset
            previousTime = point.timeOffset
        }

        guard let firstOffset else { return nil }
        let revealTime = relativeStart + firstOffset
        guard revealTime.isFinite,
              revealTime >= 0,
              revealTime <= timing.duration + limits.sessionEndTolerance else {
            return nil
        }
        return NoteReplayValidatedStrokeTiming(revealTime: revealTime)
    }

    private static func validPoint(_ point: PKStrokePoint) -> Bool {
        point.timeOffset.isFinite
            && point.location.x.isFinite
            && point.location.y.isFinite
            && abs(point.location.x) <= 1_000_000
            && abs(point.location.y) <= 1_000_000
            && point.size.width.isFinite
            && point.size.height.isFinite
            && point.size.width >= 0
            && point.size.height >= 0
            && point.size.width <= 100_000
            && point.size.height <= 100_000
            && point.opacity.isFinite
            && (0...2).contains(point.opacity)
            && point.force.isFinite
            && point.force >= 0
            && point.force <= 100
            && point.azimuth.isFinite
            && abs(point.azimuth) <= 2 * CGFloat.pi
            && point.altitude.isFinite
            && (0...(CGFloat.pi / 2)).contains(point.altitude)
            && point.secondaryScale.isFinite
            && point.secondaryScale >= 0
            && point.secondaryScale <= 100
    }

    private static func validPresentation(_ stroke: PKStroke) -> Bool {
        let transform = stroke.transform
        let transformComponents = [
            transform.a,
            transform.b,
            transform.c,
            transform.d,
            transform.tx,
            transform.ty,
        ]
        let alpha = stroke.ink.color.cgColor.alpha
        guard transformComponents.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }),
              alpha.isFinite,
              (0...1).contains(alpha) else {
            return false
        }
        guard let mask = stroke.mask else { return true }
        let bounds = mask.bounds
        return bounds.origin.x.isFinite
            && bounds.origin.y.isFinite
            && bounds.width.isFinite
            && bounds.height.isFinite
            && abs(bounds.origin.x) <= 1_000_000
            && abs(bounds.origin.y) <= 1_000_000
            && bounds.width >= 0
            && bounds.height >= 0
            && bounds.width <= 2_000_000
            && bounds.height <= 2_000_000
    }

    private static func dimmedStroke(_ source: PKStroke, opacity: CGFloat) -> PKStroke {
        var result = source
        result.ink = PKInk(
            source.ink.inkType,
            color: source.ink.color.withAlphaComponent(
                source.ink.color.cgColor.alpha * opacity
            )
        )
        return result
    }

    private static func multipliedWithoutOverflow(
        _ lhs: Int,
        _ rhs: Int
    ) -> Int? {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? nil : result.partialValue
    }

    private static func staticPreparation(
        drawing: PKDrawing?,
        timing: NoteReplaySessionTiming,
        limits: NoteReplayRenderingLimits,
        fallback: NoteReplayFrameFallback,
        decodedStrokeCount: Int,
        decodedPointCount: Int = 0,
        estimatedDecodedStructureByteCount: Int = 0
    ) -> PreparedNoteReplayDrawing {
        PreparedNoteReplayDrawing(
            authoritativeDrawing: drawing,
            strokes: [],
            timing: timing,
            limits: limits,
            preparationFallback: fallback,
            metadataFallbackStrokeCount: 0,
            decodedStrokeCount: decodedStrokeCount,
            decodedPointCount: decodedPointCount,
            validatedReplayPointCount: 0,
            estimatedDecodedStructureByteCount:
                estimatedDecodedStructureByteCount,
            timedStrokeCount: 0
        )
    }

    private static func completeFrame(
        preparedDrawing: PreparedNoteReplayDrawing,
        requestedMode: NoteReplayMode,
        playbackTime: TimeInterval
    ) -> NoteReplayFrame {
        NoteReplayFrame(
            drawing: preparedDrawing.authoritativeDrawing,
            requestedMode: requestedMode,
            appliedMode: requestedMode == .static ? .static : requestedMode,
            playbackTime: playbackTime,
            fallback: nil,
            metadataFallbackStrokeCount:
                preparedDrawing.metadataFallbackStrokeCount,
            processedStrokeCount: 0,
            processedPointCount: 0,
            revealedTimedStrokeCount: requestedMode == .static
                ? 0
                : preparedDrawing.timedStrokeCount,
            strokePresentationStrategy:
                preparedDrawing.strokePresentationStrategy
        )
    }

    private static func staticFrame(
        drawing: PKDrawing?,
        requestedMode: NoteReplayMode,
        playbackTime: TimeInterval,
        fallback: NoteReplayFrameFallback,
        metadataFallbackStrokeCount: Int
    ) -> NoteReplayFrame {
        NoteReplayFrame(
            drawing: drawing,
            requestedMode: requestedMode,
            appliedMode: .static,
            playbackTime: playbackTime,
            fallback: fallback,
            metadataFallbackStrokeCount: metadataFallbackStrokeCount,
            processedStrokeCount: 0,
            processedPointCount: 0,
            revealedTimedStrokeCount: 0,
            strokePresentationStrategy: .exactWholeOriginalStrokeAtFirstSample
        )
    }
}
