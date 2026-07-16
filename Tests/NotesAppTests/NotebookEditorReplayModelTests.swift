import Combine
import Foundation
import NotesCore
import PencilKit
import UIKit
import XCTest
@testable import NotesApp

final class NotebookEditorReplayModelTests: XCTestCase {
    @MainActor
    func testReplayPagePolicyAndPreferredStartPageAreDeterministic() {
        let supportedKinds = PageKind.allCases.filter {
            NotebookEditorReplayInteractionPolicy.supportsReplay($0)
        }
        XCTAssertEqual(
            supportedKinds,
            [.notebook, .whiteboard, .importedDocument]
        )

        let currentPageID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000101"
        )!
        for kind in [PageKind.notebook, .whiteboard, .importedDocument] {
            XCTAssertEqual(
                NotebookEditorReplayInteractionPolicy.preferredStartPageID(
                    currentPageID: currentPageID,
                    currentPageKind: kind
                ),
                PageID(rawValue: currentPageID)
            )
        }
        for kind in [PageKind.textDocument, .studySet] {
            XCTAssertNil(
                NotebookEditorReplayInteractionPolicy.preferredStartPageID(
                    currentPageID: currentPageID,
                    currentPageKind: kind
                )
            )
        }
        XCTAssertNil(
            NotebookEditorReplayInteractionPolicy.preferredStartPageID(
                currentPageID: nil,
                currentPageKind: .notebook
            )
        )
        XCTAssertNil(
            NotebookEditorReplayInteractionPolicy.preferredStartPageID(
                currentPageID: currentPageID,
                currentPageKind: nil
            )
        )
    }

    @MainActor
    func testThumbnailPolicyHasSelectSeekAndDisabledStates() {
        XCTAssertEqual(
            NotebookEditorReplayInteractionPolicy.thumbnailAction(
                hasStartReservation: false,
                isStopping: false,
                replayState: .idle
            ),
            .selectEditorPage
        )

        for state in [
            NoteReplayControllerState.playing,
            .paused,
            .finished,
        ] {
            XCTAssertEqual(
                NotebookEditorReplayInteractionPolicy.thumbnailAction(
                    hasStartReservation: false,
                    isStopping: false,
                    replayState: state
                ),
                .seekReplay
            )
        }

        for state in [
            NoteReplayControllerState.preparing,
            .seeking,
            .stopping,
        ] {
            XCTAssertEqual(
                NotebookEditorReplayInteractionPolicy.thumbnailAction(
                    hasStartReservation: false,
                    isStopping: false,
                    replayState: state
                ),
                .disabled
            )
        }

        XCTAssertEqual(
            NotebookEditorReplayInteractionPolicy.thumbnailAction(
                hasStartReservation: true,
                isStopping: false,
                replayState: .idle
            ),
            .disabled
        )
        XCTAssertEqual(
            NotebookEditorReplayInteractionPolicy.thumbnailAction(
                hasStartReservation: false,
                isStopping: true,
                replayState: .playing
            ),
            .disabled
        )
    }

    @MainActor
    func testReplayReservationPolicyRejectsStructuralMutationWindow() {
        XCTAssertTrue(NotebookEditorReplayInteractionPolicy.canReserveStart(
            isControllerAvailable: true,
            isMutationLocked: false,
            activeStructuralMutationCount: 0,
            hasReplayablePage: true
        ))
        XCTAssertFalse(NotebookEditorReplayInteractionPolicy.canReserveStart(
            isControllerAvailable: true,
            isMutationLocked: false,
            activeStructuralMutationCount: 1,
            hasReplayablePage: true
        ))
        XCTAssertFalse(NotebookEditorReplayInteractionPolicy.canReserveStart(
            isControllerAvailable: true,
            isMutationLocked: true,
            activeStructuralMutationCount: 0,
            hasReplayablePage: true
        ))
    }

    @MainActor
    func testReservationImmediatelyLocksAndChangesComputedThumbnailAction() {
        let model = NotebookEditorReplayModel()
        XCTAssertFalse(model.isMutationLocked)
        XCTAssertEqual(model.thumbnailAction, .selectEditorPage)

        let reservation = model.reserveStart(sessionID: AudioSessionID())

        XCTAssertTrue(model.isMutationLocked)
        XCTAssertTrue(model.isCurrent(reservation))
        XCTAssertEqual(model.thumbnailAction, .disabled)
    }

    @MainActor
    func testNewReservationInvalidatesStaleStartAndStaleFailure() async {
        let model = NotebookEditorReplayModel()
        let first = model.reserveStart(sessionID: AudioSessionID())
        let second = model.reserveStart(sessionID: AudioSessionID())

        XCTAssertFalse(model.isCurrent(first))
        XCTAssertTrue(model.isCurrent(second))

        await model.start(
            first,
            notebookID: NotebookID(),
            currentPageID: nil
        )
        XCTAssertEqual(model.startReservation, second)
        XCTAssertNil(model.preparationFailure)

        model.failStart(first, reason: .controllerUnavailable)
        XCTAssertEqual(model.startReservation, second)
        XCTAssertNil(model.preparationFailure)
        XCTAssertTrue(model.isMutationLocked)

        model.failStart(second, reason: .pendingWritesCouldNotBeFlushed)
        XCTAssertNil(model.startReservation)
        XCTAssertEqual(
            model.preparationFailure,
            .pendingWritesCouldNotBeFlushed
        )
        XCTAssertFalse(model.isMutationLocked)
    }

    @MainActor
    func testNilConfigurationCanBeRetriedWithAvailableController() {
        let model = NotebookEditorReplayModel()

        model.configure(controller: nil)
        XCTAssertFalse(model.isAvailable)

        model.configure(controller: makeController())
        XCTAssertTrue(model.isAvailable)
    }

    @MainActor
    func testConfiguredControllerChangesAreForwardedByModel() async {
        let model = NotebookEditorReplayModel()
        let controller = makeController()
        model.configure(controller: controller)

        let forwardedChange = expectation(
            description: "Controller change is forwarded"
        )
        let observation = model.objectWillChange
            .prefix(1)
            .sink { forwardedChange.fulfill() }

        await controller.start(
            notebookID: NotebookID(),
            sessionID: AudioSessionID(),
            currentPageID: nil
        )
        await fulfillment(of: [forwardedChange], timeout: 1)

        XCTAssertEqual(model.failure, .sessionUnavailable)
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testDrawingResolverRequiresReplayAndFramePageIdentity() {
        let displayedPageID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000201"
        )!
        let otherPageID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000202"
        )!
        let frameDrawing = makeDrawing(strokeCount: 1, xOffset: 10)
        let authoritativeDrawing = makeDrawing(strokeCount: 2, xOffset: 100)
        let matchingFrame = makeFrame(
            pageID: PageID(rawValue: displayedPageID),
            drawing: frameDrawing
        )

        let replayPageMismatch = NotebookEditorReplayDrawingResolver.drawing(
            displayedPageID: displayedPageID,
            replayPageID: PageID(rawValue: otherPageID),
            frame: matchingFrame,
            authoritativePageID: displayedPageID,
            authoritativeDrawing: authoritativeDrawing
        )
        XCTAssertTrue(replayPageMismatch.strokes.isEmpty)

        let resolvedFrame = NotebookEditorReplayDrawingResolver.drawing(
            displayedPageID: displayedPageID,
            replayPageID: PageID(rawValue: displayedPageID),
            frame: matchingFrame,
            authoritativePageID: displayedPageID,
            authoritativeDrawing: authoritativeDrawing
        )
        XCTAssertEqual(resolvedFrame.strokes.count, 1)

        let mismatchedFrame = makeFrame(
            pageID: PageID(rawValue: otherPageID),
            drawing: frameDrawing
        )
        let mismatchedFrameDoesNotRevealAuthoritativeDrawing =
            NotebookEditorReplayDrawingResolver.drawing(
                displayedPageID: displayedPageID,
                replayPageID: PageID(rawValue: displayedPageID),
                frame: mismatchedFrame,
                authoritativePageID: otherPageID,
                authoritativeDrawing: authoritativeDrawing
            )
        XCTAssertTrue(
            mismatchedFrameDoesNotRevealAuthoritativeDrawing.strokes.isEmpty
        )
    }

    @MainActor
    func testDrawingResolverReusesOnlyMatchingAuthoritativePage() {
        let displayedPageID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000301"
        )!
        let otherPageID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000302"
        )!
        let authoritativeDrawing = makeDrawing(strokeCount: 2, xOffset: 200)
        let mismatchedFrame = makeFrame(
            pageID: PageID(rawValue: otherPageID),
            drawing: makeDrawing(strokeCount: 1, xOffset: 20)
        )

        let resolvedMismatchedFrame = NotebookEditorReplayDrawingResolver.drawing(
            displayedPageID: displayedPageID,
            replayPageID: PageID(rawValue: displayedPageID),
            frame: mismatchedFrame,
            authoritativePageID: displayedPageID,
            authoritativeDrawing: authoritativeDrawing
        )
        XCTAssertTrue(resolvedMismatchedFrame.strokes.isEmpty)

        let matchingFallbackFrame = makeFrame(
            pageID: PageID(rawValue: displayedPageID),
            drawing: nil
        )
        let resolvedFallback = NotebookEditorReplayDrawingResolver.drawing(
            displayedPageID: displayedPageID,
            replayPageID: PageID(rawValue: displayedPageID),
            frame: matchingFallbackFrame,
            authoritativePageID: displayedPageID,
            authoritativeDrawing: authoritativeDrawing
        )
        XCTAssertEqual(resolvedFallback.strokes.count, 2)

        let wrongAuthoritativePage = NotebookEditorReplayDrawingResolver.drawing(
            displayedPageID: displayedPageID,
            replayPageID: PageID(rawValue: displayedPageID),
            frame: nil,
            authoritativePageID: otherPageID,
            authoritativeDrawing: authoritativeDrawing
        )
        XCTAssertTrue(wrongAuthoritativePage.strokes.isEmpty)

        let pendingFrameDoesNotRevealAuthoritativeDrawing =
            NotebookEditorReplayDrawingResolver.drawing(
                displayedPageID: displayedPageID,
                replayPageID: PageID(rawValue: displayedPageID),
                frame: nil,
                authoritativePageID: displayedPageID,
                authoritativeDrawing: authoritativeDrawing
            )
        XCTAssertTrue(pendingFrameDoesNotRevealAuthoritativeDrawing.strokes.isEmpty)

        let terminalFallback = NotebookEditorReplayDrawingResolver.drawing(
            displayedPageID: displayedPageID,
            replayPageID: PageID(rawValue: displayedPageID),
            frame: nil,
            authoritativePageID: displayedPageID,
            authoritativeDrawing: authoritativeDrawing,
            allowsAuthoritativeFallbackWithoutFrame: true
        )
        XCTAssertEqual(terminalFallback.strokes.count, 2)
    }

    @MainActor
    func testHistoricalSceneNeverLeaksAuthoritativeInkOrElements() {
        let pageID = PageID()
        let authoritativeDrawing = makeDrawing(strokeCount: 2, xOffset: 200)
        let authoritativeElement = CanvasElement(
            frame: CanvasRect(x: 0, y: 0, width: 20, height: 20),
            content: .shape(ShapeElement(
                shape: "rectangle",
                strokeColor: RGBAColor(red: 0, green: 0, blue: 0)
            ))
        )
        let historicalElement = CanvasElement(
            frame: CanvasRect(x: 10, y: 10, width: 30, height: 30),
            content: .text(TextElement(text: "Earlier"))
        )
        let sceneKey = NoteReplaySceneKey.snapshot(pageID, NoteReplayEventID())
        let historicalFrame = makeFrame(
            pageID: pageID,
            drawing: nil,
            sceneKey: sceneKey,
            historicalElements: [historicalElement]
        )

        let drawing = NotebookEditorReplayDrawingResolver.drawing(
            displayedPageID: pageID.rawValue,
            replayPageID: pageID,
            frame: historicalFrame,
            authoritativePageID: pageID.rawValue,
            authoritativeDrawing: authoritativeDrawing
        )
        XCTAssertTrue(drawing.strokes.isEmpty)

        XCTAssertEqual(
            NotebookEditorReplayElementResolver.elements(
                displayedPageID: pageID.rawValue,
                replayPageID: pageID,
                frame: historicalFrame,
                authoritativePageID: pageID.rawValue,
                authoritativeElements: [authoritativeElement]
            ),
            [historicalElement]
        )

        let malformedHistoricalFrame = makeFrame(
            pageID: pageID,
            drawing: nil,
            sceneKey: sceneKey,
            historicalElements: nil
        )
        XCTAssertTrue(NotebookEditorReplayElementResolver.elements(
            displayedPageID: pageID.rawValue,
            replayPageID: pageID,
            frame: malformedHistoricalFrame,
            authoritativePageID: pageID.rawValue,
            authoritativeElements: [authoritativeElement]
        ).isEmpty)
    }

    @MainActor
    func testFramePolicyRejectsBackwardTimeModeAndTransitionMismatches() {
        let pageID = PageID()
        let drawing = makeDrawing(strokeCount: 1, xOffset: 10)
        let currentFrame = makeFrame(
            pageID: pageID,
            drawing: drawing,
            mode: .wholeStrokeReveal,
            playbackTime: 20
        )

        XCTAssertTrue(NotebookEditorReplayFramePolicy.isDisplayable(
            currentFrame,
            for: pageID,
            playbackTime: 20,
            mode: .wholeStrokeReveal,
            state: .playing
        ))
        XCTAssertFalse(NotebookEditorReplayFramePolicy.isDisplayable(
            currentFrame,
            for: pageID,
            playbackTime: 5,
            mode: .wholeStrokeReveal,
            state: .paused
        ))
        XCTAssertFalse(NotebookEditorReplayFramePolicy.isDisplayable(
            currentFrame,
            for: pageID,
            playbackTime: 20,
            mode: .static,
            state: .playing
        ))
        XCTAssertFalse(NotebookEditorReplayFramePolicy.isDisplayable(
            currentFrame,
            for: pageID,
            playbackTime: 20,
            mode: .wholeStrokeReveal,
            state: .seeking
        ))
        XCTAssertFalse(NoteReplayPageIssue.rendererFallback(
            pageID,
            .drawingByteLimit(limit: 1)
        ).permitsAuthoritativeDrawingFallback)
        XCTAssertTrue(NoteReplayPageIssue.cacheBudgetExceeded(
            pageID,
            maximumByteCount: 1
        ).permitsAuthoritativeDrawingFallback)
        XCTAssertFalse(NoteReplayPageIssue.historicalSceneUnavailable(
            pageID
        ).permitsAuthoritativeDrawingFallback)
    }

    @MainActor
    func testAuthoritativeFallbackDecodeIsBounded() {
        let drawing = makeDrawing(strokeCount: 1, xOffset: 10)
        XCTAssertNotNil(
            NotebookEditorReplayDrawingResolver.boundedAuthoritativeDrawing(
                from: drawing.dataRepresentation()
            )
        )
        XCTAssertNil(
            NotebookEditorReplayDrawingResolver.boundedAuthoritativeDrawing(
                from: Data(
                    count: NoteReplayRenderingLimits
                        .hardMaximumDrawingByteCount + 1
                )
            )
        )
    }

    @MainActor
    private func makeController() -> NoteReplayController {
        NoteReplayController(
            audioTransport: ReplayAudioTransportStub(),
            dataSource: ReplayDataSourceStub()
        )
    }

    @MainActor
    private func makeDrawing(
        strokeCount: Int,
        xOffset: CGFloat
    ) -> PKDrawing {
        let strokes = (0..<strokeCount).map { index in
            let x = xOffset + CGFloat(index * 10)
            let points = [
                PKStrokePoint(
                    location: CGPoint(x: x, y: 10),
                    timeOffset: 0,
                    size: CGSize(width: 4, height: 4),
                    opacity: 1,
                    force: 1,
                    azimuth: 0,
                    altitude: .pi / 2,
                    secondaryScale: 1
                ),
                PKStrokePoint(
                    location: CGPoint(x: x + 5, y: 15),
                    timeOffset: 0.1,
                    size: CGSize(width: 4, height: 4),
                    opacity: 1,
                    force: 1,
                    azimuth: 0,
                    altitude: .pi / 2,
                    secondaryScale: 1
                ),
            ]
            return PKStroke(
                ink: PKInk(.pen, color: .black),
                path: PKStrokePath(
                    controlPoints: points,
                    creationDate: Date(
                        timeIntervalSinceReferenceDate: TimeInterval(index + 1)
                    )
                ),
                randomSeed: UInt32(index + 1)
            )
        }
        return PKDrawing(strokes: strokes)
    }

    @MainActor
    private func makeFrame(
        pageID: PageID,
        drawing: PKDrawing?,
        mode: NoteReplayMode = .wholeStrokeReveal,
        playbackTime: TimeInterval = 1,
        sceneKey: NoteReplaySceneKey? = nil,
        historicalElements: [CanvasElement]? = nil
    ) -> NoteReplayPageFrame {
        NoteReplayPageFrame(
            pageID: pageID,
            sceneKey: sceneKey,
            frame: NoteReplayFrame(
                drawing: drawing,
                requestedMode: mode,
                appliedMode: mode,
                playbackTime: playbackTime,
                fallback: nil,
                metadataFallbackStrokeCount: 0,
                processedStrokeCount: drawing?.strokes.count ?? 0,
                processedPointCount: 0,
                revealedTimedStrokeCount: drawing?.strokes.count ?? 0,
                strokePresentationStrategy: .exactWholeOriginalStrokeAtFirstSample,
                historicalElements: historicalElements
            )
        )
    }
}

@MainActor
private final class ReplayAudioTransportStub: NoteReplayAudioTransport {
    func startReplayAudio(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        from time: TimeInterval
    ) async throws {}

    func pauseReplayAudio() async throws {}
    func resumeReplayAudio() async throws {}
    func seekReplayAudio(to time: TimeInterval) async throws {}
    func stopReplayAudio() async {}

    func replayAudioPlaybackSnapshot() async throws
        -> NoteReplayAudioPlaybackSnapshot {
        NoteReplayAudioPlaybackSnapshot(status: .stopped, currentTime: 0)
    }
}

@MainActor
private final class ReplayDataSourceStub: NoteReplayDataSource {
    func loadReplaySession(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        maximumTimelineMarkCount: Int,
        maximumEligiblePageCount: Int,
        maximumHistoryEventCount: Int
    ) async throws -> NoteReplaySessionSnapshot {
        throw ReplayTestStubError.unused
    }

    func loadReplayInk(
        notebookID: NotebookID,
        pageID: PageID,
        maximumByteCount: Int
    ) async throws -> Data? {
        throw ReplayTestStubError.unused
    }

    func endReplaySession() async {}
}

private enum ReplayTestStubError: Error, Sendable {
    case unused
}
