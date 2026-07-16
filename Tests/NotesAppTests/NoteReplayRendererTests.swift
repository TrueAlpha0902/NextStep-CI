import NotesCore
import PencilKit
import UIKit
import XCTest
@testable import NotesApp

final class NoteReplayRendererTests: XCTestCase {
    private let sessionStart = Date(timeIntervalSinceReferenceDate: 10_000)

    func testSceneSelectorUsesBaselineSameTimeSequenceAndTerminalDeterministically() throws {
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let baseline = replayEvent(
            sequence: 0,
            time: 1,
            pageID: pageID,
            kind: .baseline,
            digestCharacter: "a"
        )
        let lowerSequence = replayEvent(
            sequence: 1,
            time: 5,
            pageID: pageID,
            kind: .change,
            digestCharacter: "b"
        )
        let higherSequence = replayEvent(
            sequence: 2,
            time: 5,
            pageID: pageID,
            kind: .change,
            digestCharacter: "c"
        )
        let terminal = replayEvent(
            sequence: 3,
            time: 10,
            pageID: pageID,
            kind: .terminal,
            digestCharacter: "d"
        )
        let history = NoteReplayHistoryDocument(
            audioSessionID: sessionID,
            events: [terminal, higherSequence, baseline, lowerSequence]
        )

        let beforeFirst = try XCTUnwrap(NoteReplaySceneSelector.selection(
            pageID: pageID,
            playbackTime: 0,
            mode: .wholeStrokeReveal,
            history: history
        ))
        XCTAssertEqual(beforeFirst.key, .snapshot(pageID, baseline.id))
        XCTAssertEqual(beforeFirst.elementsPayload, baseline.elementsPayload)

        let sameTime = try XCTUnwrap(NoteReplaySceneSelector.selection(
            pageID: pageID,
            playbackTime: 5,
            mode: .spotlight,
            history: history
        ))
        XCTAssertEqual(sameTime.key, .snapshot(pageID, higherSequence.id))
        XCTAssertEqual(sameTime.inkPayload, higherSequence.inkPayload)

        let staticSelection = try XCTUnwrap(NoteReplaySceneSelector.selection(
            pageID: pageID,
            playbackTime: 2,
            mode: .static,
            history: history
        ))
        XCTAssertEqual(staticSelection.key, .snapshot(pageID, terminal.id))
    }

    func testSceneSelectorPreservesLegacyBehaviorOnlyWithoutAHistoryDocument() throws {
        let pageID = PageID()
        let selection = try XCTUnwrap(NoteReplaySceneSelector.selection(
            pageID: pageID,
            playbackTime: 2,
            mode: .wholeStrokeReveal,
            history: nil
        ))

        XCTAssertEqual(selection.key, .legacy(pageID))
        XCTAssertNil(selection.inkPayload)
        XCTAssertNil(selection.elementsPayload)
        XCTAssertNil(NoteReplaySceneSelector.selection(
            pageID: pageID,
            playbackTime: 2,
            mode: .wholeStrokeReveal,
            history: NoteReplayHistoryDocument(
                audioSessionID: AudioSessionID(),
                events: []
            )
        ))
    }

    @MainActor
    func testWholeStrokeRevealUsesExactSourceGeometryAndNoFramePointWork() async throws {
        let preSession = stroke(
            createdAt: sessionStart.addingTimeInterval(-1),
            offsets: [0, 0.5]
        )
        let current = stroke(
            createdAt: sessionStart.addingTimeInterval(4),
            offsets: [0, 2, 4],
            locations: [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 0, y: 120),
                CGPoint(x: 120, y: 0),
            ],
            transform: CGAffineTransform(translationX: 12, y: 15).rotated(by: 0.25),
            mask: UIBezierPath(rect: CGRect(x: 1, y: 2, width: 30, height: 40)),
            randomSeed: 42
        )
        let future = stroke(
            createdAt: sessionStart.addingTimeInterval(8),
            offsets: [0, 1]
        )
        let data = PKDrawing(strokes: [preSession, current, future]).dataRepresentation()
        let descriptor = AudioSessionDescriptor(
            createdAt: sessionStart.addingTimeInterval(5_000),
            durationSeconds: 10
        )
        let explicitTiming = NoteReplaySessionTiming(
            session: descriptor,
            recordingStartedAt: sessionStart
        )

        let prepared = try await NoteReplayRenderer.prepareDrawing(
            drawingData: data,
            timing: explicitTiming
        )
        let authoritative = try await NoteReplayRenderer.renderFrame(
            preparedDrawing: prepared,
            playbackTime: 5,
            mode: .static
        )
        let frame = try await NoteReplayRenderer.renderFrame(
            preparedDrawing: prepared,
            playbackTime: 5,
            mode: .wholeStrokeReveal
        )

        XCTAssertEqual(explicitTiming.recordingStartedAt, sessionStart)
        XCTAssertNotEqual(explicitTiming.recordingStartedAt, descriptor.createdAt)
        XCTAssertNil(prepared.preparationFallback)
        XCTAssertEqual(prepared.decodedStrokeCount, 3)
        XCTAssertEqual(prepared.decodedPointCount, 7)
        XCTAssertEqual(prepared.validatedReplayPointCount, 5)
        XCTAssertEqual(prepared.timedStrokeCount, 2)

        let sourceStrokes = try XCTUnwrap(authoritative.drawing).strokes
        let renderedStrokes = try XCTUnwrap(frame.drawing).strokes
        XCTAssertEqual(renderedStrokes.count, 2)
        assertSameGeometry(renderedStrokes[0], sourceStrokes[0])
        assertSameGeometry(renderedStrokes[1], sourceStrokes[1])
        XCTAssertEqual(renderedStrokes[1].ink.inkType, sourceStrokes[1].ink.inkType)
        XCTAssertEqual(
            renderedStrokes[1].ink.color.cgColor.alpha,
            sourceStrokes[1].ink.color.cgColor.alpha,
            accuracy: 0.001
        )
        XCTAssertEqual(frame.processedPointCount, 0)
        XCTAssertEqual(frame.revealedTimedStrokeCount, 1)
        XCTAssertEqual(
            frame.strokePresentationStrategy,
            .exactWholeOriginalStrokeAtFirstSample
        )
        XCTAssertNil(frame.fallback)
    }

    @MainActor
    func testWholeStrokeAppearsAtFirstSampleWithoutPartialCurveRebuild() async throws {
        let source = stroke(
            createdAt: sessionStart.addingTimeInterval(2),
            offsets: [1, 3, 5],
            locations: [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 80, y: 120),
                CGPoint(x: 160, y: 0),
            ]
        )
        let prepared = try await NoteReplayRenderer.prepareDrawing(
            drawingData: PKDrawing(strokes: [source]).dataRepresentation(),
            timing: timing(duration: 10)
        )
        let authoritative = try await NoteReplayRenderer.renderFrame(
            preparedDrawing: prepared,
            playbackTime: 0,
            mode: .static
        )
        let before = try await NoteReplayRenderer.renderFrame(
            preparedDrawing: prepared,
            playbackTime: 2.999,
            mode: .wholeStrokeReveal
        )
        let atFirstSample = try await NoteReplayRenderer.renderFrame(
            preparedDrawing: prepared,
            playbackTime: 3,
            mode: .wholeStrokeReveal
        )

        XCTAssertTrue(try XCTUnwrap(before.drawing).strokes.isEmpty)
        let revealed = try XCTUnwrap(atFirstSample.drawing).strokes
        XCTAssertEqual(revealed.count, 1)
        assertSameGeometry(revealed[0], try XCTUnwrap(authoritative.drawing).strokes[0])
        XCTAssertEqual(revealed[0].path.count, 3)
        XCTAssertEqual(atFirstSample.processedPointCount, 0)
    }

    @MainActor
    func testSpotlightDimsFutureWholeStrokeWithoutChangingItsGeometry() async throws {
        let current = stroke(
            createdAt: sessionStart.addingTimeInterval(4),
            offsets: [0, 2, 4],
            inkType: .marker,
            color: UIColor.systemBlue.withAlphaComponent(0.8),
            transform: CGAffineTransform(translationX: 7, y: 9),
            mask: UIBezierPath(rect: CGRect(x: 2, y: 3, width: 20, height: 30)),
            randomSeed: 41
        )
        let future = stroke(
            createdAt: sessionStart.addingTimeInterval(8),
            offsets: [0, 1],
            inkType: .pencil,
            color: .systemRed,
            transform: CGAffineTransform(scaleX: 1.2, y: 0.8),
            randomSeed: 84
        )
        let prepared = try await NoteReplayRenderer.prepareDrawing(
            drawingData: PKDrawing(strokes: [current, future]).dataRepresentation(),
            timing: timing(duration: 10)
        )
        let authoritative = try await NoteReplayRenderer.renderFrame(
            preparedDrawing: prepared,
            playbackTime: 5,
            mode: .static
        )
        let frame = try await NoteReplayRenderer.renderFrame(
            preparedDrawing: prepared,
            playbackTime: 5,
            mode: .spotlight
        )

        let sourceStrokes = try XCTUnwrap(authoritative.drawing).strokes
        let renderedStrokes = try XCTUnwrap(frame.drawing).strokes
        XCTAssertEqual(renderedStrokes.count, 2)
        assertSameGeometry(renderedStrokes[0], sourceStrokes[0])
        assertSameGeometry(renderedStrokes[1], sourceStrokes[1])
        XCTAssertEqual(renderedStrokes[0].randomSeed, 41)
        XCTAssertEqual(renderedStrokes[1].randomSeed, 84)
        XCTAssertEqual(
            renderedStrokes[0].ink.color.cgColor.alpha,
            sourceStrokes[0].ink.color.cgColor.alpha,
            accuracy: 0.001
        )
        XCTAssertEqual(
            renderedStrokes[1].ink.color.cgColor.alpha,
            sourceStrokes[1].ink.color.cgColor.alpha * 0.18,
            accuracy: 0.01
        )
        XCTAssertEqual(frame.processedPointCount, 0)
        XCTAssertEqual(frame.revealedTimedStrokeCount, 1)
    }

    @MainActor
    func testEveryInteractiveFrameDoesZeroPointWork() async throws {
        let strokes = (0..<100).map { index in
            stroke(
                createdAt: sessionStart.addingTimeInterval(Double(index) / 10),
                offsets: [0, 0.1, 0.2]
            )
        }
        let prepared = try await NoteReplayRenderer.prepareDrawing(
            drawingData: PKDrawing(strokes: strokes).dataRepresentation(),
            timing: timing(duration: 20)
        )

        for mode in [NoteReplayMode.wholeStrokeReveal, .spotlight, .static] {
            for playbackTime in [0.0, 4.5, 9.9, 20.0] {
                let frame = try await NoteReplayRenderer.renderFrame(
                    preparedDrawing: prepared,
                    playbackTime: playbackTime,
                    mode: mode
                )
                XCTAssertEqual(frame.processedPointCount, 0)
            }
        }
    }

    @MainActor
    func testStaticModeReturnsCompleteDrawingWithoutReplayFiltering() async throws {
        let drawing = PKDrawing(strokes: [
            stroke(createdAt: sessionStart, offsets: [0, 1]),
            stroke(createdAt: sessionStart.addingTimeInterval(2), offsets: [0, 1]),
        ])
        let prepared = try await NoteReplayRenderer.prepareDrawing(
            drawingData: drawing.dataRepresentation(),
            timing: timing(duration: 10)
        )

        let frame = try await NoteReplayRenderer.renderFrame(
            preparedDrawing: prepared,
            playbackTime: .infinity,
            mode: .static
        )

        XCTAssertEqual(try XCTUnwrap(frame.drawing).strokes.count, 2)
        XCTAssertEqual(frame.appliedMode, .static)
        XCTAssertEqual(frame.playbackTime, 10)
        XCTAssertEqual(frame.processedStrokeCount, 0)
        XCTAssertEqual(frame.processedPointCount, 0)
        XCTAssertNil(frame.fallback)
    }

    @MainActor
    func testRendererAndPlannerShareStrictInvalidSessionFallback() async throws {
        let invalidTiming = timing(duration: 0)
        let prepared = try await NoteReplayRenderer.prepareDrawing(
            drawingData: PKDrawing(strokes: [
                stroke(createdAt: sessionStart.addingTimeInterval(1), offsets: [0, 1]),
            ]).dataRepresentation(),
            timing: invalidTiming
        )
        let frame = try await NoteReplayRenderer.renderFrame(
            preparedDrawing: prepared,
            playbackTime: 10,
            mode: .wholeStrokeReveal
        )

        XCTAssertFalse(NoteReplaySessionPolicy.isValid(invalidTiming))
        XCTAssertEqual(try XCTUnwrap(frame.drawing).strokes.count, 1)
        XCTAssertEqual(frame.appliedMode, .static)
        XCTAssertEqual(frame.playbackTime, 0)
        XCTAssertEqual(frame.fallback, .invalidSessionMetadata)
        XCTAssertTrue(frame.usesStaticPresentation)
        XCTAssertFalse(frame.requiresAuthoritativeDrawingReuse)
    }

    @MainActor
    func testInvalidStrokeTimingFallsBackOnlyThatStrokeDuringPreparation() async throws {
        let invalidOrder = stroke(
            createdAt: sessionStart.addingTimeInterval(1),
            offsets: [0, 2, 1]
        )
        let outsideSession = stroke(
            createdAt: sessionStart.addingTimeInterval(2),
            offsets: [0, 20]
        )
        let future = stroke(
            createdAt: sessionStart.addingTimeInterval(8),
            offsets: [0, 1]
        )
        let prepared = try await NoteReplayRenderer.prepareDrawing(
            drawingData: PKDrawing(strokes: [invalidOrder, outsideSession, future])
                .dataRepresentation(),
            timing: timing(duration: 10)
        )
        let frame = try await NoteReplayRenderer.renderFrame(
            preparedDrawing: prepared,
            playbackTime: 5,
            mode: .wholeStrokeReveal
        )

        XCTAssertEqual(try XCTUnwrap(frame.drawing).strokes.count, 2)
        XCTAssertEqual(prepared.metadataFallbackStrokeCount, 2)
        XCTAssertEqual(frame.metadataFallbackStrokeCount, 2)
        XCTAssertEqual(frame.processedPointCount, 0)
        XCTAssertNil(frame.fallback)
    }

    @MainActor
    func testAlwaysVisibleStrokesNeverInvokeDimmedStrokeConstruction() async throws {
        XCTAssertEqual(
            NoteReplayStrokePreparationClassifier.decision(
                relativeStart: -2,
                duration: 10,
                maximumMetadataDistanceFromSession: 1_000,
                presentationIsValid: true
            ),
            .alwaysVisible(metadataFallback: false)
        )
        XCTAssertEqual(
            NoteReplayStrokePreparationClassifier.decision(
                relativeStart: 2,
                duration: 10,
                maximumMetadataDistanceFromSession: 1_000,
                presentationIsValid: false
            ),
            .alwaysVisible(metadataFallback: true)
        )

        let recorder = NoteReplayHookRecorder()
        let preSession = stroke(
            createdAt: sessionStart.addingTimeInterval(-2),
            offsets: [0, 1]
        )
        let invalidStrokeTiming = stroke(
            createdAt: sessionStart.addingTimeInterval(2),
            offsets: [0, 20]
        )
        let validTimed = stroke(
            createdAt: sessionStart.addingTimeInterval(8),
            offsets: [0, 1]
        )

        let prepared = try await NoteReplayRenderer.prepareDrawing(
            drawingData: PKDrawing(strokes: [
                preSession,
                invalidStrokeTiming,
                validTimed,
            ]).dataRepresentation(),
            timing: timing(duration: 10),
            workerHooks: NoteReplayWorkerHooks(
                didCreateDimmedStroke: {
                    await recorder.recordDimmedStroke()
                }
            )
        )
        let dimmedStrokeCount = await recorder.dimmedStrokeCount()

        XCTAssertEqual(prepared.timedStrokeCount, 1)
        XCTAssertEqual(prepared.metadataFallbackStrokeCount, 1)
        XCTAssertEqual(
            dimmedStrokeCount,
            1,
            "Only the validated timed stroke may create a dimmed copy."
        )
    }

    @MainActor
    func testEncodedAndDecodedStructuralLimitsAcceptBoundaryThenFailStatic() async throws {
        let first = stroke(
            createdAt: sessionStart.addingTimeInterval(1),
            offsets: [0, 1, 2]
        )
        let second = stroke(
            createdAt: sessionStart.addingTimeInterval(2),
            offsets: [0, 1]
        )
        let data = PKDrawing(strokes: [first, second]).dataRepresentation()
        let baseline = try await NoteReplayRenderer.prepareDrawing(
            drawingData: data,
            timing: timing(duration: 10)
        )

        XCTAssertLessThanOrEqual(
            NoteReplayRenderingLimits.default.maximumDrawingByteCount,
            1 * 1_024 * 1_024
        )
        XCTAssertLessThanOrEqual(
            NoteReplayRenderingLimits.default.maximumPointCount,
            20_000
        )
        let attemptedBypass = NoteReplayRenderingLimits(
            maximumDrawingByteCount: .max,
            maximumStrokeCount: .max,
            maximumPointCount: .max,
            maximumPointsPerStroke: .max,
            maximumEstimatedDecodedStructureByteCount: .max
        )
        XCTAssertEqual(
            attemptedBypass.maximumDrawingByteCount,
            NoteReplayRenderingLimits.hardMaximumDrawingByteCount
        )
        XCTAssertEqual(
            attemptedBypass.maximumStrokeCount,
            NoteReplayRenderingLimits.hardMaximumStrokeCount
        )
        XCTAssertEqual(
            attemptedBypass.maximumPointCount,
            NoteReplayRenderingLimits.hardMaximumPointCount
        )
        XCTAssertEqual(
            attemptedBypass.maximumPointsPerStroke,
            NoteReplayRenderingLimits.hardMaximumPointsPerStroke
        )
        XCTAssertEqual(
            attemptedBypass.maximumEstimatedDecodedStructureByteCount,
            NoteReplayRenderingLimits.hardMaximumEstimatedDecodedStructureByteCount
        )

        let byteBoundary = try await NoteReplayRenderer.prepareDrawing(
            drawingData: data,
            timing: timing(duration: 10),
            limits: NoteReplayRenderingLimits(maximumDrawingByteCount: data.count)
        )
        let byteExceeded = try await NoteReplayRenderer.prepareDrawing(
            drawingData: data,
            timing: timing(duration: 10),
            limits: NoteReplayRenderingLimits(maximumDrawingByteCount: data.count - 1)
        )
        XCTAssertNil(byteBoundary.preparationFallback)
        XCTAssertEqual(
            byteExceeded.preparationFallback,
            .drawingByteLimit(limit: data.count - 1)
        )

        let strokeBoundary = try await NoteReplayRenderer.prepareDrawing(
            drawingData: data,
            timing: timing(duration: 10),
            limits: NoteReplayRenderingLimits(
                maximumStrokeCount: baseline.decodedStrokeCount
            )
        )
        let strokeExceeded = try await NoteReplayRenderer.prepareDrawing(
            drawingData: data,
            timing: timing(duration: 10),
            limits: NoteReplayRenderingLimits(
                maximumStrokeCount: baseline.decodedStrokeCount - 1
            )
        )
        XCTAssertNil(strokeBoundary.preparationFallback)
        XCTAssertEqual(
            strokeExceeded.preparationFallback,
            .strokeCountLimit(limit: baseline.decodedStrokeCount - 1)
        )

        let pointBoundary = try await NoteReplayRenderer.prepareDrawing(
            drawingData: data,
            timing: timing(duration: 10),
            limits: NoteReplayRenderingLimits(
                maximumPointCount: baseline.decodedPointCount
            )
        )
        let pointExceeded = try await NoteReplayRenderer.prepareDrawing(
            drawingData: data,
            timing: timing(duration: 10),
            limits: NoteReplayRenderingLimits(
                maximumPointCount: baseline.decodedPointCount - 1
            )
        )
        XCTAssertNil(pointBoundary.preparationFallback)
        XCTAssertEqual(
            pointExceeded.preparationFallback,
            .pointCountLimit(limit: baseline.decodedPointCount - 1)
        )

        let perStrokeBoundary = try await NoteReplayRenderer.prepareDrawing(
            drawingData: data,
            timing: timing(duration: 10),
            limits: NoteReplayRenderingLimits(maximumPointsPerStroke: 3)
        )
        let perStrokeExceeded = try await NoteReplayRenderer.prepareDrawing(
            drawingData: data,
            timing: timing(duration: 10),
            limits: NoteReplayRenderingLimits(maximumPointsPerStroke: 2)
        )
        XCTAssertNil(perStrokeBoundary.preparationFallback)
        XCTAssertEqual(
            perStrokeExceeded.preparationFallback,
            .pointsPerStrokeLimit(limit: 2)
        )

        let estimatedBoundary = try await NoteReplayRenderer.prepareDrawing(
            drawingData: data,
            timing: timing(duration: 10),
            limits: NoteReplayRenderingLimits(
                maximumEstimatedDecodedStructureByteCount:
                    baseline.estimatedDecodedStructureByteCount
            )
        )
        let estimatedExceeded = try await NoteReplayRenderer.prepareDrawing(
            drawingData: data,
            timing: timing(duration: 10),
            limits: NoteReplayRenderingLimits(
                maximumEstimatedDecodedStructureByteCount:
                    baseline.estimatedDecodedStructureByteCount - 1
            )
        )
        XCTAssertNil(estimatedBoundary.preparationFallback)
        XCTAssertEqual(
            estimatedExceeded.preparationFallback,
            .estimatedDecodedStructureLimit(
                limit: baseline.estimatedDecodedStructureByteCount - 1
            )
        )

        let refusedFrame = try await NoteReplayRenderer.renderFrame(
            preparedDrawing: byteExceeded,
            playbackTime: 1,
            mode: .wholeStrokeReveal
        )
        let structuralFrame = try await NoteReplayRenderer.renderFrame(
            preparedDrawing: estimatedExceeded,
            playbackTime: 1,
            mode: .wholeStrokeReveal
        )
        XCTAssertNil(refusedFrame.drawing)
        XCTAssertTrue(refusedFrame.requiresAuthoritativeDrawingReuse)
        XCTAssertNil(structuralFrame.drawing)
        XCTAssertTrue(structuralFrame.requiresAuthoritativeDrawingReuse)
        XCTAssertEqual(structuralFrame.appliedMode, .static)
    }

    @MainActor
    func testMalformedDrawingDataIsRejectedDuringPreparation() async {
        do {
            _ = try await NoteReplayRenderer.prepareDrawing(
                drawingData: Data("not-pencilkit".utf8),
                timing: timing(duration: 10)
            )
            XCTFail("Malformed PencilKit data must be rejected.")
        } catch {
            XCTAssertEqual(error as? NoteReplayRenderingError, .invalidDrawingData)
        }
    }

    @MainActor
    func testCancellationDominatesDecodeFailureInsideWorker() async {
        let decodeFailureGate = NoteReplayAsyncGate()
        let task = Task { @MainActor in
            try await NoteReplayRenderer.prepareDrawing(
                drawingData: Data("not-pencilkit".utf8),
                timing: timing(duration: 10),
                workerHooks: NoteReplayWorkerHooks(
                    afterDrawingDecodeFailureBeforeCancellationCheck: {
                        await decodeFailureGate.arriveAndWait()
                    }
                )
            )
        }

        await decodeFailureGate.waitForArrival()
        task.cancel()
        await decodeFailureGate.release()

        do {
            _ = try await task.value
            XCTFail("Cancellation must outrank a concurrent decode failure.")
        } catch is CancellationError {
            // Expected deterministic worker-side cancellation precedence.
        } catch {
            XCTFail("Expected CancellationError, received \(error).")
        }
    }

    @MainActor
    func testCancellationDominatesFailureWaitingAtOuterWorkerBoundary() async {
        let workerFailureGate = NoteReplayAsyncGate()
        let task = Task { @MainActor in
            try await NoteReplayRenderer.prepareDrawing(
                drawingData: Data("not-pencilkit".utf8),
                timing: timing(duration: 10),
                workerHooks: NoteReplayWorkerHooks(
                    afterWorkerFailureBeforeRethrow: {
                        await workerFailureGate.arriveAndWait()
                    }
                )
            )
        }

        await workerFailureGate.waitForArrival()
        task.cancel()
        await workerFailureGate.release()

        do {
            _ = try await task.value
            XCTFail("Cancellation must outrank a completed worker failure.")
        } catch is CancellationError {
            // Expected deterministic caller-side cancellation precedence.
        } catch {
            XCTFail("Expected CancellationError, received \(error).")
        }
    }

    @MainActor
    func testPreCancelledPreparationAndFrameDoNotPublishResults() async throws {
        let data = PKDrawing(strokes: [
            stroke(createdAt: sessionStart.addingTimeInterval(1), offsets: [0, 1, 2]),
        ]).dataRepresentation()
        let preparationTask = Task { @MainActor in
            await Task.yield()
            return try await NoteReplayRenderer.prepareDrawing(
                drawingData: data,
                timing: timing(duration: 10)
            )
        }
        preparationTask.cancel()

        do {
            _ = try await preparationTask.value
            XCTFail("A cancelled replay preparation must not be published.")
        } catch is CancellationError {
            // Expected. An in-flight PKDrawing decode is the documented
            // synchronous boundary, but this task is cancelled before entry.
        }

        let prepared = try await NoteReplayRenderer.prepareDrawing(
            drawingData: data,
            timing: timing(duration: 10)
        )
        let frameTask = Task { @MainActor in
            await Task.yield()
            return try await NoteReplayRenderer.renderFrame(
                preparedDrawing: prepared,
                playbackTime: 2,
                mode: .wholeStrokeReveal
            )
        }
        frameTask.cancel()

        do {
            _ = try await frameTask.value
            XCTFail("A cancelled replay frame must not be published.")
        } catch is CancellationError {
            // Expected cooperative cancellation.
        }
    }

    private func replayEvent(
        sequence: Int,
        time: TimeInterval,
        pageID: PageID,
        kind: NoteReplaySnapshotEventKind,
        digestCharacter: Character
    ) -> NoteReplaySnapshotEvent {
        let digest = String(repeating: String(digestCharacter), count: 64)
        let reference = NoteReplayPayloadReference(
            assetID: AssetID(digest),
            byteCount: 2
        )
        return NoteReplaySnapshotEvent(
            sequence: sequence,
            timeSeconds: time,
            pageID: pageID,
            kind: kind,
            inkPayload: reference,
            elementsPayload: reference
        )
    }

    @MainActor
    private func timing(duration: TimeInterval) -> NoteReplaySessionTiming {
        NoteReplaySessionTiming(
            audioSessionID: AudioSessionID(),
            sessionSchemaVersion: AudioSessionDescriptor.currentSchemaVersion,
            recordingStartedAt: sessionStart,
            duration: duration
        )
    }

    @MainActor
    private func stroke(
        createdAt: Date,
        offsets: [TimeInterval],
        locations: [CGPoint]? = nil,
        inkType: PKInkingTool.InkType = .pen,
        color: UIColor = .black,
        transform: CGAffineTransform = .identity,
        mask: UIBezierPath? = nil,
        randomSeed: UInt32 = 7,
        pointOpacity: CGFloat = 0.9,
        pointForce: CGFloat = 0.7
    ) -> PKStroke {
        precondition(locations == nil || locations?.count == offsets.count)
        let points = offsets.enumerated().map { index, offset in
            PKStrokePoint(
                location: locations?[index] ?? CGPoint(
                    x: CGFloat(10 + (index * 20)),
                    y: CGFloat(20 + (index * 10))
                ),
                timeOffset: offset,
                size: CGSize(width: CGFloat(6 + index), height: CGFloat(7 + index)),
                opacity: pointOpacity,
                force: pointForce,
                azimuth: 0.25,
                altitude: .pi / 3,
                secondaryScale: 0.75
            )
        }
        return PKStroke(
            ink: PKInk(inkType, color: color),
            path: PKStrokePath(controlPoints: points, creationDate: createdAt),
            transform: transform,
            mask: mask,
            randomSeed: randomSeed
        )
    }

    @MainActor
    private func assertSameGeometry(
        _ actual: PKStroke,
        _ expected: PKStroke,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.path.creationDate, expected.path.creationDate, file: file, line: line)
        XCTAssertEqual(actual.path.count, expected.path.count, file: file, line: line)
        XCTAssertEqual(actual.transform, expected.transform, file: file, line: line)
        XCTAssertEqual(actual.mask?.bounds, expected.mask?.bounds, file: file, line: line)
        XCTAssertEqual(actual.randomSeed, expected.randomSeed, file: file, line: line)

        for index in 0..<expected.path.count {
            let actualPoint = actual.path[index]
            let expectedPoint = expected.path[index]
            XCTAssertEqual(actualPoint.location.x, expectedPoint.location.x, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(actualPoint.location.y, expectedPoint.location.y, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(actualPoint.timeOffset, expectedPoint.timeOffset, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(actualPoint.size.width, expectedPoint.size.width, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(actualPoint.size.height, expectedPoint.size.height, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(actualPoint.opacity, expectedPoint.opacity, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(actualPoint.force, expectedPoint.force, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(actualPoint.azimuth, expectedPoint.azimuth, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(actualPoint.altitude, expectedPoint.altitude, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(actualPoint.secondaryScale, expectedPoint.secondaryScale, accuracy: 0.001, file: file, line: line)
        }
    }
}

private actor NoteReplayAsyncGate {
    private var hasArrived = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func arriveAndWait() async {
        precondition(!hasArrived, "A replay test gate supports one arrival.")
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
            hasArrived = true
            let waiters = arrivalWaiters
            arrivalWaiters.removeAll(keepingCapacity: false)
            waiters.forEach { $0.resume() }
        }
    }

    func waitForArrival() async {
        guard !hasArrived else { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        precondition(hasArrived, "The replay test gate was released before arrival.")
        precondition(releaseContinuation != nil, "The replay test gate was released twice.")
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor NoteReplayHookRecorder {
    private var count = 0

    func recordDimmedStroke() {
        count += 1
    }

    func dimmedStrokeCount() -> Int {
        count
    }
}
