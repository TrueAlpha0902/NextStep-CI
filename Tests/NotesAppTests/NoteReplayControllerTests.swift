import Combine
import Foundation
import NotesCore
import PencilKit
import XCTest
@testable import NotesApp

final class NoteReplayControllerTests: XCTestCase {
    private let recordingStart = Date(timeIntervalSinceReferenceDate: 84_000)

    @MainActor
    func testTransportControlsAndBackwardSeekKeepStateAndPageInSync() async {
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        let firstPage = PageID()
        let secondPage = PageID()
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [firstPage, secondPage],
            marks: [(firstPage, 0), (secondPage, 5)],
            duration: 12
        )
        let transport = TestNoteReplayAudioTransport()
        let dataSource = TestNoteReplayDataSource(snapshot: fixture)
        let renderer = TestNoteReplayPageRenderer()
        let scheduler = TestNoteReplayScheduler()
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: dataSource,
            pageRenderer: renderer,
            scheduler: scheduler
        )

        await controller.start(
            notebookID: notebookID,
            sessionID: sessionID,
            currentPageID: firstPage
        )
        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(controller.currentPageID, firstPage)
        XCTAssertEqual(controller.duration, 12)
        XCTAssertEqual(transport.startCalls.count, 1)

        transport.snapshot = NoteReplayAudioPlaybackSnapshot(
            status: .playing,
            currentTime: 6
        )
        await controller.pollOnce()
        XCTAssertEqual(controller.currentPageID, secondPage)
        XCTAssertEqual(controller.playbackTime, 6)

        transport.snapshot = NoteReplayAudioPlaybackSnapshot(
            status: .playing,
            currentTime: 2
        )
        await controller.pollOnce()
        XCTAssertEqual(controller.currentPageID, firstPage)
        XCTAssertEqual(controller.playbackTime, 2)

        await controller.pause()
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(transport.pauseCallCount, 1)

        await controller.seek(to: 7)
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(controller.currentPageID, secondPage)
        XCTAssertEqual(transport.seekTimes.last, 7)

        await controller.resume()
        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(transport.resumeCallCount, 1)

        await controller.skipBackward()
        XCTAssertEqual(controller.currentPageID, firstPage)
        XCTAssertEqual(transport.seekTimes.last, 0)

        await controller.stop()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertNil(controller.currentPageID)
        XCTAssertEqual(transport.stopCallCount, 1)
        XCTAssertEqual(dataSource.endReplaySessionCallCount, 1)
        await controller.stop()
        XCTAssertEqual(
            dataSource.endReplaySessionCallCount,
            1,
            "An already-stopped controller must not release the same session twice."
        )
    }

    @MainActor
    func testHistoricalScenesLoadSnapshotPayloadsAndCacheByEventIdentity() async {
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let baselineData = Data("baseline".utf8)
        let terminalData = Data("terminal".utf8)
        let baselineInk = NoteReplayPayloadReference(
            assetID: AssetID(String(repeating: "a", count: 64)),
            byteCount: baselineData.count
        )
        let terminalInk = NoteReplayPayloadReference(
            assetID: AssetID(String(repeating: "b", count: 64)),
            byteCount: terminalData.count
        )
        let baselineElements = NoteReplayPayloadReference(
            assetID: AssetID(String(repeating: "c", count: 64)),
            byteCount: 2
        )
        let terminalElements = NoteReplayPayloadReference(
            assetID: AssetID(String(repeating: "d", count: 64)),
            byteCount: 2
        )
        let baseline = NoteReplaySnapshotEvent(
            sequence: 0,
            timeSeconds: 0,
            pageID: pageID,
            kind: .baseline,
            inkPayload: baselineInk,
            elementsPayload: baselineElements
        )
        let terminal = NoteReplaySnapshotEvent(
            sequence: 1,
            timeSeconds: 10,
            pageID: pageID,
            kind: .terminal,
            inkPayload: terminalInk,
            elementsPayload: terminalElements
        )
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [pageID],
            marks: [(pageID, 0)],
            duration: 10,
            history: NoteReplayHistoryDocument(
                audioSessionID: sessionID,
                events: [baseline, terminal]
            )
        )
        let transport = TestNoteReplayAudioTransport()
        let dataSource = TestNoteReplayDataSource(snapshot: fixture)
        dataSource.replayInkByReference = [
            baselineInk: baselineData,
            terminalInk: terminalData,
        ]
        dataSource.replayElementsByReference = [
            baselineElements: NotebookExportCanvasElements(
                elements: [],
                encodedByteCount: 2
            ),
            terminalElements: NotebookExportCanvasElements(
                elements: [],
                encodedByteCount: 2
            ),
        ]
        let renderer = TestNoteReplayPageRenderer()
        let scheduler = TestNoteReplayScheduler()
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: dataSource,
            pageRenderer: renderer,
            scheduler: scheduler
        )

        await controller.start(
            notebookID: notebookID,
            sessionID: sessionID,
            currentPageID: pageID
        )
        XCTAssertEqual(
            controller.currentPageFrame?.sceneKey,
            .snapshot(pageID, baseline.id)
        )
        XCTAssertEqual(controller.currentPageFrame?.frame.historicalElements, [])
        XCTAssertEqual(
            controller.cachedSceneKeys,
            Set<NoteReplaySceneKey>([.snapshot(pageID, baseline.id)])
        )
        XCTAssertEqual(dataSource.requestedReplayInkReferences, [baselineInk])

        let wakeScheduled = expectation(description: "Terminal scene frame wake")
        scheduler.observeNextSleep(dueWithin: 0.07) {
            wakeScheduled.fulfill()
        }
        let secondRender = expectation(description: "Terminal scene rendered")
        renderer.observeRenderCount(2) { secondRender.fulfill() }
        await controller.setMode(.static)
        await fulfillment(of: [wakeScheduled], timeout: 1)
        scheduler.advance(by: 0.07)
        await fulfillment(of: [secondRender], timeout: 1)
        await Task.yield()

        XCTAssertEqual(
            controller.currentPageFrame?.sceneKey,
            .snapshot(pageID, terminal.id)
        )
        XCTAssertEqual(
            controller.cachedSceneKeys,
            Set<NoteReplaySceneKey>([
                .snapshot(pageID, baseline.id),
                .snapshot(pageID, terminal.id),
            ])
        )
        XCTAssertEqual(
            dataSource.requestedReplayInkReferences,
            [baselineInk, terminalInk]
        )
        await controller.stop()
    }

    @MainActor
    func testHistoricalReplayProjectsOutUnrecordedCurrentPageBeforeFirstMark() async {
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        let unrecordedPageID = PageID()
        let recordedPageID = PageID()
        let baselineElements = NoteReplayPayloadReference(
            assetID: AssetID(String(repeating: "e", count: 64)),
            byteCount: 2
        )
        let terminalElements = NoteReplayPayloadReference(
            assetID: AssetID(String(repeating: "f", count: 64)),
            byteCount: 2
        )
        let baseline = NoteReplaySnapshotEvent(
            sequence: 0,
            timeSeconds: 0,
            pageID: recordedPageID,
            kind: .baseline,
            inkPayload: nil,
            elementsPayload: baselineElements
        )
        let terminal = NoteReplaySnapshotEvent(
            sequence: 1,
            timeSeconds: 10,
            pageID: recordedPageID,
            kind: .terminal,
            inkPayload: nil,
            elementsPayload: terminalElements
        )
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [unrecordedPageID, recordedPageID],
            marks: [(recordedPageID, 1)],
            duration: 10,
            history: NoteReplayHistoryDocument(
                audioSessionID: sessionID,
                events: [baseline, terminal]
            )
        )
        let transport = TestNoteReplayAudioTransport()
        let dataSource = TestNoteReplayDataSource(snapshot: fixture)
        dataSource.replayElementsByReference = [
            baselineElements: NotebookExportCanvasElements(
                elements: [],
                encodedByteCount: 2
            ),
            terminalElements: NotebookExportCanvasElements(
                elements: [],
                encodedByteCount: 2
            ),
        ]
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: dataSource,
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )

        await controller.start(
            notebookID: notebookID,
            sessionID: sessionID,
            currentPageID: unrecordedPageID
        )

        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(controller.currentPageID, recordedPageID)
        XCTAssertEqual(
            controller.currentPageFrame?.sceneKey,
            .snapshot(recordedPageID, baseline.id)
        )
        XCTAssertEqual(
            dataSource.requestedReplayElementReferences,
            [baselineElements]
        )
        XCTAssertTrue(dataSource.requestedInkMaximums.isEmpty)
        XCTAssertEqual(transport.startCalls.count, 1)
        await controller.stop()
    }

    @MainActor
    func testHistoricalReplayDoesNotShowFutureCurrentPageAtReplayZero() async {
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        let initialPageID = PageID()
        let laterPageID = PageID()
        let initialBaselineElements = NoteReplayPayloadReference(
            assetID: AssetID(String(repeating: "1", count: 64)),
            byteCount: 2
        )
        let laterBaselineElements = NoteReplayPayloadReference(
            assetID: AssetID(String(repeating: "2", count: 64)),
            byteCount: 2
        )
        let initialTerminalElements = NoteReplayPayloadReference(
            assetID: AssetID(String(repeating: "3", count: 64)),
            byteCount: 2
        )
        let laterTerminalElements = NoteReplayPayloadReference(
            assetID: AssetID(String(repeating: "4", count: 64)),
            byteCount: 2
        )
        let initialBaseline = NoteReplaySnapshotEvent(
            sequence: 0,
            timeSeconds: 0,
            pageID: initialPageID,
            kind: .baseline,
            inkPayload: nil,
            elementsPayload: initialBaselineElements
        )
        let laterBaseline = NoteReplaySnapshotEvent(
            sequence: 1,
            timeSeconds: 5,
            pageID: laterPageID,
            kind: .baseline,
            inkPayload: nil,
            elementsPayload: laterBaselineElements
        )
        let initialTerminal = NoteReplaySnapshotEvent(
            sequence: 2,
            timeSeconds: 10,
            pageID: initialPageID,
            kind: .terminal,
            inkPayload: nil,
            elementsPayload: initialTerminalElements
        )
        let laterTerminal = NoteReplaySnapshotEvent(
            sequence: 3,
            timeSeconds: 10,
            pageID: laterPageID,
            kind: .terminal,
            inkPayload: nil,
            elementsPayload: laterTerminalElements
        )
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [initialPageID, laterPageID],
            marks: [(initialPageID, 1), (laterPageID, 5)],
            duration: 10,
            history: NoteReplayHistoryDocument(
                audioSessionID: sessionID,
                events: [
                    initialBaseline,
                    laterBaseline,
                    initialTerminal,
                    laterTerminal,
                ]
            )
        )
        let transport = TestNoteReplayAudioTransport()
        let dataSource = TestNoteReplayDataSource(snapshot: fixture)
        dataSource.replayElementsByReference = [
            initialBaselineElements: NotebookExportCanvasElements(
                elements: [],
                encodedByteCount: 2
            ),
            laterBaselineElements: NotebookExportCanvasElements(
                elements: [],
                encodedByteCount: 2
            ),
            initialTerminalElements: NotebookExportCanvasElements(
                elements: [],
                encodedByteCount: 2
            ),
            laterTerminalElements: NotebookExportCanvasElements(
                elements: [],
                encodedByteCount: 2
            ),
        ]
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: dataSource,
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )

        await controller.start(
            notebookID: notebookID,
            sessionID: sessionID,
            currentPageID: laterPageID
        )

        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(controller.currentPageID, initialPageID)
        XCTAssertEqual(
            controller.currentPageFrame?.sceneKey,
            .snapshot(initialPageID, initialBaseline.id)
        )
        XCTAssertEqual(
            dataSource.requestedReplayElementReferences,
            [initialBaselineElements]
        )
        XCTAssertTrue(dataSource.requestedInkMaximums.isEmpty)
        await controller.stop()
    }

    @MainActor
    func testMalformedUnknownPageMarkFailsBeforeAudioStarts() async {
        let sessionID = AudioSessionID()
        let existingPage = PageID()
        let deletedPage = PageID()
        let malformedMark = AudioTimelineMark(
            schemaVersion: AudioTimelineMark.currentSchemaVersion + 1,
            operationID: OperationID(),
            pageID: deletedPage,
            timeSeconds: 1,
            createdAt: recordingStart.addingTimeInterval(1)
        )
        let fixture = NoteReplaySessionSnapshot(
            descriptor: makeDescriptor(sessionID: sessionID, duration: 10),
            timeline: AudioTimelineDocument(
                audioSessionID: sessionID,
                marks: [malformedMark],
                modifiedAt: recordingStart.addingTimeInterval(10)
            ),
            eligiblePageIDs: [existingPage]
        )
        let transport = TestNoteReplayAudioTransport()
        let dataSource = TestNoteReplayDataSource(snapshot: fixture)
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: dataSource,
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )

        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: existingPage
        )

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.failure, .invalidSessionOrTimeline)
        XCTAssertTrue(transport.startCalls.isEmpty)
        XCTAssertEqual(dataSource.endReplaySessionCallCount, 1)
    }

    @MainActor
    func testReferencedUnavailableHistoryFailsClosedBeforeAudioStarts() async {
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let legacyFixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [pageID],
            marks: [(pageID, 0)],
            duration: 10
        )
        let fixture = NoteReplaySessionSnapshot(
            descriptor: makeDescriptor(
                sessionID: sessionID,
                duration: 10,
                replayEventCount: 1
            ),
            timeline: legacyFixture.timeline,
            eligiblePageIDs: legacyFixture.eligiblePageIDs,
            history: nil,
            historyUnavailable: true
        )
        let transport = TestNoteReplayAudioTransport()
        let dataSource = TestNoteReplayDataSource(snapshot: fixture)
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: dataSource,
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )

        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: pageID
        )

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.failure, .historicalReplayUnavailable)
        XCTAssertTrue(transport.startCalls.isEmpty)
        XCTAssertEqual(dataSource.endReplaySessionCallCount, 1)
    }

    @MainActor
    func testVersionThreeDescriptorCannotFallBackWhenHistoryWasNotLoaded() async {
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let legacyFixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [pageID],
            marks: [(pageID, 0)],
            duration: 10
        )
        let fixture = NoteReplaySessionSnapshot(
            descriptor: makeDescriptor(
                sessionID: sessionID,
                duration: 10,
                replayEventCount: 2
            ),
            timeline: legacyFixture.timeline,
            eligiblePageIDs: legacyFixture.eligiblePageIDs
        )
        let transport = TestNoteReplayAudioTransport()
        let dataSource = TestNoteReplayDataSource(snapshot: fixture)
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: dataSource,
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )

        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: pageID
        )

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.failure, .historicalReplayUnavailable)
        XCTAssertTrue(transport.startCalls.isEmpty)
        XCTAssertTrue(dataSource.requestedInkMaximums.isEmpty)
        XCTAssertTrue(dataSource.requestedReplayInkReferences.isEmpty)
        XCTAssertEqual(dataSource.endReplaySessionCallCount, 1)
    }

    @MainActor
    func testRedactedEmptyHistoryCannotStartReplayOrFallBackToFinalPage() async {
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let base = makeFixture(
            sessionID: sessionID,
            pageIDs: [pageID],
            marks: [(pageID, 0)],
            duration: 10
        )
        let fixture = NoteReplaySessionSnapshot(
            descriptor: makeDescriptor(
                sessionID: sessionID,
                duration: 10,
                replayEventCount: 0
            ),
            timeline: base.timeline,
            eligiblePageIDs: base.eligiblePageIDs,
            history: NoteReplayHistoryDocument(
                audioSessionID: sessionID,
                events: []
            )
        )
        let transport = TestNoteReplayAudioTransport()
        let dataSource = TestNoteReplayDataSource(snapshot: fixture)
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: dataSource,
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )

        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: pageID
        )

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.failure, .historicalReplayUnavailable)
        XCTAssertTrue(transport.startCalls.isEmpty)
        XCTAssertTrue(dataSource.requestedInkMaximums.isEmpty)
        XCTAssertEqual(dataSource.endReplaySessionCallCount, 1)
    }

    @MainActor
    func testGloballyDescendingHistoricalEventTimeFailsBeforeAudioStarts() async {
        let sessionID = AudioSessionID()
        let firstPageID = PageID()
        let secondPageID = PageID()
        let elements = NoteReplayPayloadReference(
            assetID: AssetID(String(repeating: "5", count: 64)),
            byteCount: 2
        )
        let history = NoteReplayHistoryDocument(
            audioSessionID: sessionID,
            events: [
                NoteReplaySnapshotEvent(
                    sequence: 0,
                    timeSeconds: 5,
                    pageID: firstPageID,
                    kind: .baseline,
                    inkPayload: nil,
                    elementsPayload: elements
                ),
                NoteReplaySnapshotEvent(
                    sequence: 1,
                    timeSeconds: 0,
                    pageID: secondPageID,
                    kind: .baseline,
                    inkPayload: nil,
                    elementsPayload: elements
                ),
                NoteReplaySnapshotEvent(
                    sequence: 2,
                    timeSeconds: 10,
                    pageID: firstPageID,
                    kind: .terminal,
                    inkPayload: nil,
                    elementsPayload: elements
                ),
                NoteReplaySnapshotEvent(
                    sequence: 3,
                    timeSeconds: 10,
                    pageID: secondPageID,
                    kind: .terminal,
                    inkPayload: nil,
                    elementsPayload: elements
                ),
            ]
        )
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [firstPageID, secondPageID],
            marks: [(firstPageID, 0)],
            duration: 10,
            history: history
        )
        let transport = TestNoteReplayAudioTransport()
        let dataSource = TestNoteReplayDataSource(snapshot: fixture)
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: dataSource,
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )

        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: firstPageID
        )

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.failure, .invalidSessionOrTimeline)
        XCTAssertTrue(transport.startCalls.isEmpty)
        XCTAssertTrue(dataSource.requestedReplayElementReferences.isEmpty)
        XCTAssertEqual(dataSource.endReplaySessionCallCount, 1)
    }

    @MainActor
    func testThumbnailSeekChoosesEarlierMarkOnTie() async {
        let sessionID = AudioSessionID()
        let firstPage = PageID()
        let secondPage = PageID()
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [firstPage, secondPage],
            marks: [(firstPage, 0), (secondPage, 4), (secondPage, 8)],
            duration: 12
        )
        let transport = TestNoteReplayAudioTransport()
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: TestNoteReplayDataSource(snapshot: fixture),
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )

        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: firstPage
        )
        await controller.pause()
        await controller.seek(to: 6)
        let didSeek = await controller.seekToPage(secondPage)

        XCTAssertTrue(didSeek)
        XCTAssertEqual(Array(transport.seekTimes.suffix(2)), [6, 4])
        XCTAssertEqual(controller.currentPageID, secondPage)
        XCTAssertEqual(controller.playbackTime, 4)
        await controller.stop()
    }

    @MainActor
    func testShadowedSameTimestampPageMarkDoesNotReportFalseSeek() async {
        let sessionID = AudioSessionID()
        let shadowedPage = PageID()
        let navigablePage = PageID()
        let sharedTime: TimeInterval = 4
        let fixture = NoteReplaySessionSnapshot(
            descriptor: makeDescriptor(sessionID: sessionID, duration: 10),
            timeline: AudioTimelineDocument(
                audioSessionID: sessionID,
                marks: [
                    AudioTimelineMark(
                        id: AudioTimelineMarkID(rawValue: UUID(uuid: (
                            0, 0, 0, 0, 0, 0, 0, 0,
                            0, 0, 0, 0, 0, 0, 0, 1
                        ))),
                        operationID: OperationID(),
                        pageID: shadowedPage,
                        timeSeconds: sharedTime,
                        createdAt: recordingStart.addingTimeInterval(sharedTime)
                    ),
                    AudioTimelineMark(
                        id: AudioTimelineMarkID(rawValue: UUID(uuid: (
                            0, 0, 0, 0, 0, 0, 0, 0,
                            0, 0, 0, 0, 0, 0, 0, 2
                        ))),
                        operationID: OperationID(),
                        pageID: navigablePage,
                        timeSeconds: sharedTime,
                        createdAt: recordingStart.addingTimeInterval(sharedTime)
                    ),
                ],
                modifiedAt: recordingStart.addingTimeInterval(10)
            ),
            eligiblePageIDs: [shadowedPage, navigablePage]
        )
        let transport = TestNoteReplayAudioTransport()
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: TestNoteReplayDataSource(snapshot: fixture),
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )

        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: shadowedPage
        )
        await controller.pause()
        await controller.seek(to: 6)
        XCTAssertEqual(controller.currentPageID, navigablePage)

        let didSeek = await controller.seekToPage(shadowedPage)

        XCTAssertFalse(didSeek)
        XCTAssertEqual(controller.currentPageID, navigablePage)
        XCTAssertEqual(controller.pageIssue, .timelineMarkUnavailable(shadowedPage))
        XCTAssertEqual(transport.seekTimes, [6])
        await controller.stop()
    }

    @MainActor
    func testOversizedInkFallsBackToAuthoritativeCanvasAndAudioContinues() async {
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [pageID],
            marks: [(pageID, 0)],
            duration: 10
        )
        let transport = TestNoteReplayAudioTransport()
        let dataSource = TestNoteReplayDataSource(snapshot: fixture)
        dataSource.inkByPageID[pageID] = Data(
            repeating: 0xA5,
            count: NoteReplayRenderingLimits.default.maximumDrawingByteCount + 1
        )
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: dataSource,
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )

        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: pageID
        )

        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(
            controller.pageIssue,
            .inkTooLarge(
                pageID,
                maximumByteCount:
                    NoteReplayRenderingLimits.default.maximumDrawingByteCount
            )
        )
        XCTAssertTrue(controller.requiresAuthoritativeDrawingReuse)
        XCTAssertEqual(
            dataSource.requestedInkMaximums,
            [NoteReplayRenderingLimits.default.maximumDrawingByteCount]
        )
        XCTAssertEqual(transport.startCalls.count, 1)
        await controller.stop()
    }

    @MainActor
    func testPreparationFailureIsNegativelyCachedWhileAudioContinues() async {
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [pageID],
            marks: [(pageID, 0)],
            duration: 10
        )
        let transport = TestNoteReplayAudioTransport()
        let dataSource = TestNoteReplayDataSource(snapshot: fixture)
        let renderer = TestNoteReplayPageRenderer(conservativeByteCount: 64)
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: dataSource,
            pageRenderer: renderer,
            scheduler: TestNoteReplayScheduler(),
            configuration: NoteReplayControllerConfiguration(
                maximumCacheByteCount: 32
            )
        )

        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: pageID
        )
        XCTAssertEqual(
            controller.pageIssue,
            .cacheBudgetExceeded(pageID, maximumByteCount: 32)
        )

        for playbackTime in [1.0, 2.0, 3.0] {
            transport.snapshot = NoteReplayAudioPlaybackSnapshot(
                status: .playing,
                currentTime: playbackTime
            )
            await controller.pollOnce()
        }

        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(controller.playbackTime, 3)
        XCTAssertEqual(dataSource.loadCountByPageID[pageID], 1)
        XCTAssertEqual(
            renderer.preparationCountByKey[dataSource.inkKey(for: pageID)],
            1
        )
        XCTAssertEqual(transport.startCalls.count, 1)
        await controller.stop()
    }

    @MainActor
    func testTwoPageLRUEvictsOldestAndHonorsAggregateBudget() async {
        let sessionID = AudioSessionID()
        let firstPage = PageID()
        let secondPage = PageID()
        let thirdPage = PageID()
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [firstPage, secondPage, thirdPage],
            marks: [(firstPage, 0), (secondPage, 3), (thirdPage, 6)],
            duration: 10
        )
        let dataSource = TestNoteReplayDataSource(snapshot: fixture)
        let renderer = TestNoteReplayPageRenderer(conservativeByteCount: 40)
        let controller = NoteReplayController(
            audioTransport: TestNoteReplayAudioTransport(),
            dataSource: dataSource,
            pageRenderer: renderer,
            scheduler: TestNoteReplayScheduler(),
            configuration: NoteReplayControllerConfiguration(
                maximumCachedPageCount: 2,
                maximumCacheByteCount: 80
            )
        )

        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: firstPage
        )
        await controller.pause()
        await controller.seek(to: 4)
        XCTAssertEqual(controller.cachedPageIDs, Set([firstPage, secondPage]))
        XCTAssertEqual(controller.cachedPageByteCount, 80)

        await controller.seek(to: 7)
        XCTAssertEqual(controller.cachedPageIDs, Set([secondPage, thirdPage]))
        XCTAssertEqual(controller.cachedPageByteCount, 80)

        let secondPageKey = dataSource.inkKey(for: secondPage)
        let secondPagePreparationCount = renderer.preparationCountByKey[secondPageKey]
        await controller.seek(to: 4)
        XCTAssertEqual(
            renderer.preparationCountByKey[secondPageKey],
            secondPagePreparationCount,
            "The recently used second page must remain cached."
        )

        let firstPageKey = dataSource.inkKey(for: firstPage)
        let originalFirstPagePreparationCount = renderer.preparationCountByKey[firstPageKey]
        await controller.seek(to: 0)
        XCTAssertEqual(
            renderer.preparationCountByKey[firstPageKey],
            (originalFirstPagePreparationCount ?? 0) + 1
        )
        XCTAssertLessThanOrEqual(controller.cachedPageIDs.count, 2)
        XCTAssertLessThanOrEqual(controller.cachedPageByteCount, 80)
        await controller.stop()
    }

    @MainActor
    func testSlowRendererDropsIntermediateFrameAndPublishesNewestOnly() async {
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [pageID],
            marks: [(pageID, 0)],
            duration: 10
        )
        let scheduler = TestNoteReplayScheduler()
        let renderer = TestNoteReplayPageRenderer()
        let transport = TestNoteReplayAudioTransport()
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: TestNoteReplayDataSource(snapshot: fixture),
            pageRenderer: renderer,
            scheduler: scheduler
        )

        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: pageID
        )
        let refreshScheduled = expectation(
            description: "Pause refresh schedules its bounded frame wake"
        )
        scheduler.observeNextSleep(dueWithin: 0.07) {
            refreshScheduled.fulfill()
        }
        let secondRender = expectation(description: "Pause refresh renders")
        renderer.observeRenderCount(2) { secondRender.fulfill() }
        await controller.pause()
        await fulfillment(of: [refreshScheduled], timeout: 1)
        scheduler.advance(by: 0.1)
        await fulfillment(of: [secondRender], timeout: 1)

        let renderArrived = expectation(description: "Controlled render arrives")
        let gate = TestNoteReplayOneShotGate {
            renderArrived.fulfill()
        }
        defer { gate.releaseIfNeeded() }
        renderer.nextRenderGate = gate

        // Make the first controlled request immediately eligible under the
        // 15-fps cap, then leave its render blocked while newer requests arrive.
        scheduler.advance(by: 0.1)
        await controller.seek(to: 1)
        await fulfillment(of: [renderArrived], timeout: 1)

        await controller.seek(to: 2)
        scheduler.advance(by: 0.1)
        await controller.seek(to: 3)
        scheduler.advance(by: 0.1)
        let fourthRender = expectation(description: "Newest render completes")
        renderer.observeRenderCount(4) { fourthRender.fulfill() }
        let newestFramePublished = expectation(
            description: "Newest frame is the published frame"
        )
        let frameObservation = controller.$currentPageFrame
            .compactMap { $0?.frame.playbackTime }
            .filter { $0 == 3 }
            .prefix(1)
            .sink { _ in newestFramePublished.fulfill() }
        gate.releaseIfNeeded()

        await fulfillment(
            of: [fourthRender, newestFramePublished],
            timeout: 1
        )
        withExtendedLifetime(frameObservation) {}
        XCTAssertEqual(renderer.renderedTimes, [0, 0, 1, 3])
        XCTAssertFalse(renderer.renderedTimes.contains(2))
        XCTAssertEqual(controller.currentPageFrame?.frame.playbackTime, 3)
        await controller.stop()
    }

    @MainActor
    func testLifecyclePausesStopsAndTrimsCacheWithoutWrites() async {
        let sessionID = AudioSessionID()
        let firstPage = PageID()
        let secondPage = PageID()
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [firstPage, secondPage],
            marks: [(firstPage, 0), (secondPage, 5)],
            duration: 10
        )
        let transport = TestNoteReplayAudioTransport()
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: TestNoteReplayDataSource(snapshot: fixture),
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )

        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: firstPage
        )
        await controller.seek(to: 6)
        XCTAssertEqual(controller.cachedPageIDs.count, 2)

        await controller.handleLifecycle(.memoryWarning)
        XCTAssertEqual(controller.cachedPageIDs, Set([secondPage]))

        await controller.handleLifecycle(.becameInactive)
        XCTAssertEqual(controller.state, .paused)

        await controller.handleLifecycle(.enteredBackground)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(transport.stopCallCount, 1)
    }

    @MainActor
    func testInactiveDuringPreparationStopsBeforeBoundedLoadUnwinds() async {
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [pageID],
            marks: [(pageID, 0)],
            duration: 10
        )
        let loadArrived = expectation(description: "Session load arrives")
        let loadGate = TestNoteReplayOneShotGate(
            cancellationPolicy: .holdUntilExplicitRelease
        ) { loadArrived.fulfill() }
        defer { loadGate.releaseIfNeeded() }
        let dataSource = TestNoteReplayDataSource(snapshot: fixture)
        dataSource.sessionLoadGate = loadGate
        let transport = TestNoteReplayAudioTransport()
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: dataSource,
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )

        let startTask = Task { @MainActor in
            await controller.start(
                notebookID: NotebookID(),
                sessionID: sessionID,
                currentPageID: pageID
            )
        }
        await fulfillment(of: [loadArrived], timeout: 1)
        XCTAssertEqual(controller.state, .preparing)

        let stopInvoked = expectation(description: "Inactive stops audio")
        transport.observeNextStop { stopInvoked.fulfill() }
        let inactiveTask = Task { @MainActor in
            await controller.handleLifecycle(.becameInactive)
        }
        await fulfillment(of: [stopInvoked], timeout: 1)
        XCTAssertEqual(controller.state, .stopping)
        XCTAssertTrue(transport.startCalls.isEmpty)

        loadGate.releaseIfNeeded()
        await inactiveTask.value
        await startTask.value
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(transport.startCalls.isEmpty)
    }

    @MainActor
    func testInactiveDuringSeekStopsTransportAndRejectsLateSeekResult() async {
        let sessionID = AudioSessionID()
        let firstPage = PageID()
        let secondPage = PageID()
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [firstPage, secondPage],
            marks: [(firstPage, 0), (secondPage, 5)],
            duration: 10
        )
        let seekArrived = expectation(description: "Seek transport arrives")
        let seekGate = TestNoteReplayOneShotGate(
            cancellationPolicy: .holdUntilExplicitRelease
        ) { seekArrived.fulfill() }
        defer { seekGate.releaseIfNeeded() }
        let transport = TestNoteReplayAudioTransport()
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: TestNoteReplayDataSource(snapshot: fixture),
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )
        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: firstPage
        )
        transport.nextSeekGate = seekGate

        let seekTask = Task { @MainActor in
            await controller.seek(to: 6)
        }
        await fulfillment(of: [seekArrived], timeout: 1)
        XCTAssertEqual(controller.state, .seeking)

        let stopInvoked = expectation(description: "Inactive stops seek audio")
        transport.observeNextStop { stopInvoked.fulfill() }
        let inactiveTask = Task { @MainActor in
            await controller.handleLifecycle(.becameInactive)
        }
        await fulfillment(of: [stopInvoked], timeout: 1)
        XCTAssertEqual(controller.state, .stopping)
        seekGate.releaseIfNeeded()
        await inactiveTask.value
        await seekTask.value

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(transport.seekTimes.isEmpty)
        XCTAssertGreaterThanOrEqual(transport.stopCallCount, 1)
    }

    @MainActor
    func testThreeConcurrentGatedSeeksAreSerializedAndOnlyLatestWins() async {
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [pageID],
            marks: [(pageID, 0)],
            duration: 10
        )
        let firstSeekArrived = expectation(description: "First seek arrives")
        let firstSeekGate = TestNoteReplayOneShotGate(
            cancellationPolicy: .holdUntilExplicitRelease
        ) {
            firstSeekArrived.fulfill()
        }
        defer { firstSeekGate.releaseIfNeeded() }
        let transport = TestNoteReplayAudioTransport()
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: TestNoteReplayDataSource(snapshot: fixture),
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )
        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: pageID
        )
        await controller.pause()
        transport.nextSeekGate = firstSeekGate

        let firstTask = Task { @MainActor in
            await controller.seek(to: 1)
        }
        await fulfillment(of: [firstSeekArrived], timeout: 1)

        let secondStarted = expectation(description: "Second seek starts")
        let secondTask = Task { @MainActor in
            secondStarted.fulfill()
            await controller.seek(to: 2)
        }
        await fulfillment(of: [secondStarted], timeout: 1)

        let thirdStarted = expectation(description: "Third seek starts")
        let thirdTask = Task { @MainActor in
            thirdStarted.fulfill()
            await controller.seek(to: 3)
        }
        await fulfillment(of: [thirdStarted], timeout: 1)
        firstSeekGate.releaseIfNeeded()

        await firstTask.value
        await secondTask.value
        await thirdTask.value
        XCTAssertEqual(transport.maximumConcurrentSeekCount, 1)
        XCTAssertEqual(transport.seekTimes, [3])
        XCTAssertEqual(controller.playbackTime, 3)
        XCTAssertEqual(controller.state, .paused)
        await controller.stop()
    }

    @MainActor
    func testSupersededSeekWaitsForCancelledPagePreparationAndCannotCache() async {
        let sessionID = AudioSessionID()
        let firstPage = PageID()
        let secondPage = PageID()
        let thirdPage = PageID()
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [firstPage, secondPage, thirdPage],
            marks: [(firstPage, 0), (secondPage, 3), (thirdPage, 6)],
            duration: 10
        )
        let preparationArrived = expectation(
            description: "Superseded page preparation arrives"
        )
        let preparationGate = TestNoteReplayOneShotGate {
            preparationArrived.fulfill()
        }
        defer { preparationGate.releaseIfNeeded() }
        let dataSource = TestNoteReplayDataSource(snapshot: fixture)
        let renderer = TestNoteReplayPageRenderer()
        let controller = NoteReplayController(
            audioTransport: TestNoteReplayAudioTransport(),
            dataSource: dataSource,
            pageRenderer: renderer,
            scheduler: TestNoteReplayScheduler()
        )
        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: firstPage
        )
        await controller.pause()
        renderer.nextPreparationGate = preparationGate

        let supersededSeekCompleted = expectation(
            description: "Superseded seek completes after cancellation"
        )
        let supersededSeek = Task { @MainActor in
            await controller.seek(to: 4)
            supersededSeekCompleted.fulfill()
        }
        await fulfillment(of: [preparationArrived], timeout: 1)

        let newestSeekCompleted = expectation(
            description: "Newest seek completes after cancelled preparation"
        )
        let newestSeek = Task { @MainActor in
            await controller.seek(to: 7)
            newestSeekCompleted.fulfill()
        }
        await fulfillment(
            of: [supersededSeekCompleted, newestSeekCompleted],
            timeout: 1
        )
        await supersededSeek.value
        await newestSeek.value

        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(controller.currentPageID, thirdPage)
        XCTAssertEqual(controller.playbackTime, 7)
        XCTAssertFalse(controller.cachedPageIDs.contains(secondPage))
        XCTAssertTrue(controller.cachedPageIDs.contains(thirdPage))
        XCTAssertEqual(
            renderer.preparationCountByKey[dataSource.inkKey(for: secondPage)],
            1
        )
        XCTAssertFalse(renderer.renderedTimes.contains(4))
        await controller.stop()
    }

    @MainActor
    func testOlderStopCannotClearRestartedSessionAfterItUnwinds() async {
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [pageID],
            marks: [(pageID, 0)],
            duration: 10
        )
        let firstStopArrived = expectation(description: "First stop arrives")
        let firstStopGate = TestNoteReplayOneShotGate {
            firstStopArrived.fulfill()
        }
        defer { firstStopGate.releaseIfNeeded() }
        let transport = TestNoteReplayAudioTransport()
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: TestNoteReplayDataSource(snapshot: fixture),
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )
        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: pageID
        )
        transport.nextStopGate = firstStopGate

        let oldStopCompleted = expectation(description: "Old stop completes")
        let oldStop = Task { @MainActor in
            await controller.stop()
            oldStopCompleted.fulfill()
        }
        await fulfillment(of: [firstStopArrived], timeout: 1)

        let restartCompleted = expectation(description: "New session restarts")
        let restart = Task { @MainActor in
            await controller.start(
                notebookID: NotebookID(),
                sessionID: sessionID,
                currentPageID: pageID
            )
            restartCompleted.fulfill()
        }
        await fulfillment(of: [restartCompleted], timeout: 1)
        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(controller.currentPageID, pageID)
        XCTAssertEqual(transport.startCalls.count, 2)

        firstStopGate.releaseIfNeeded()
        await fulfillment(of: [oldStopCompleted], timeout: 1)
        await oldStop.value
        await restart.value
        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(controller.currentPageID, pageID)
        await controller.stop()
    }

    @MainActor
    func testOnlyExactEndSeekFinishesAcrossPlaybackStates() async {
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [pageID],
            marks: [(pageID, 0)],
            duration: 10
        )
        let transport = TestNoteReplayAudioTransport()
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: TestNoteReplayDataSource(snapshot: fixture),
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )
        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: pageID
        )
        await controller.seek(to: 9.95)
        XCTAssertEqual(controller.state, .playing)
        XCTAssertEqual(controller.playbackTime, 9.95)

        await controller.seek(to: 10)
        XCTAssertEqual(controller.state, .finished)
        XCTAssertEqual(controller.playbackTime, 10)
        XCTAssertEqual(transport.seekTimes, [9.95, 10])
        XCTAssertEqual(transport.startCalls.count, 1)
        let stopCountAfterPlayingEndSeek = transport.stopCallCount

        await controller.seek(to: 9.95)
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(controller.playbackTime, 9.95)
        XCTAssertEqual(transport.startCalls.last?.time, 9.95)
        XCTAssertEqual(transport.startCalls.count, 2)
        XCTAssertEqual(transport.pauseCallCount, 1)

        await controller.seek(to: 10)
        XCTAssertEqual(controller.state, .finished)
        XCTAssertEqual(controller.playbackTime, 10)
        XCTAssertEqual(transport.seekTimes.last, 10)
        XCTAssertEqual(
            transport.stopCallCount,
            stopCountAfterPlayingEndSeek + 1
        )
        let startCountAtFinishedEnd = transport.startCalls.count
        let seekCountAtFinishedEnd = transport.seekTimes.count
        let stopCountAtFinishedEnd = transport.stopCallCount

        await controller.seek(to: 10)
        XCTAssertEqual(controller.state, .finished)
        XCTAssertEqual(controller.playbackTime, 10)
        XCTAssertEqual(transport.startCalls.count, startCountAtFinishedEnd)
        XCTAssertEqual(transport.seekTimes.count, seekCountAtFinishedEnd)
        XCTAssertEqual(transport.stopCallCount, stopCountAtFinishedEnd)
        await controller.stop()
    }

    @MainActor
    func testPauseReconcilesFinishedAndStoppedTransportRaces() async {
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [pageID],
            marks: [(pageID, 0)],
            duration: 10
        )
        let finishedTransport = TestNoteReplayAudioTransport()
        let finishedController = NoteReplayController(
            audioTransport: finishedTransport,
            dataSource: TestNoteReplayDataSource(snapshot: fixture),
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )
        await finishedController.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: pageID
        )
        finishedTransport.pauseResultSnapshot = NoteReplayAudioPlaybackSnapshot(
            status: .finished,
            currentTime: 10
        )

        await finishedController.pause()

        XCTAssertEqual(finishedController.state, .finished)
        XCTAssertEqual(finishedController.playbackTime, 10)
        await finishedController.stop()

        let stoppedTransport = TestNoteReplayAudioTransport()
        let stoppedController = NoteReplayController(
            audioTransport: stoppedTransport,
            dataSource: TestNoteReplayDataSource(snapshot: fixture),
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )
        await stoppedController.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: pageID
        )
        stoppedTransport.pauseResultSnapshot = NoteReplayAudioPlaybackSnapshot(
            status: .stopped,
            currentTime: 4
        )

        await stoppedController.pause()

        XCTAssertEqual(stoppedController.state, .idle)
        XCTAssertEqual(
            stoppedController.failure,
            .audioStoppedUnexpectedly
        )
    }

    @MainActor
    func testFailedTransportNearNaturalEndNeverPublishesFinished() async {
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [pageID],
            marks: [(pageID, 0)],
            duration: 10
        )
        let transport = TestNoteReplayAudioTransport()
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: TestNoteReplayDataSource(snapshot: fixture),
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )
        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: pageID
        )
        transport.snapshot = NoteReplayAudioPlaybackSnapshot(
            status: .failed,
            currentTime: 9.99
        )

        await controller.pollOnce()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(controller.failure, .audioStoppedUnexpectedly)
        XCTAssertNotEqual(controller.state, .finished)
    }

    @MainActor
    func testPauseFailureStillReconcilesAConcurrentNaturalFinish() async {
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [pageID],
            marks: [(pageID, 0)],
            duration: 10
        )
        let transport = TestNoteReplayAudioTransport()
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: TestNoteReplayDataSource(snapshot: fixture),
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )
        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: pageID
        )
        transport.snapshot = NoteReplayAudioPlaybackSnapshot(
            status: .finished,
            currentTime: 10
        )
        transport.failsNextPause = true

        await controller.pause()

        XCTAssertEqual(controller.state, .finished)
        XCTAssertEqual(controller.playbackTime, 10)
        XCTAssertNil(controller.failure)
        await controller.stop()
    }

    @MainActor
    func testCancellingStartDuringPagePreparationNeverStartsAudio() async {
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [pageID],
            marks: [(pageID, 0)],
            duration: 10
        )
        let preparationArrived = expectation(
            description: "Initial replay page preparation arrives"
        )
        let preparationGate = TestNoteReplayOneShotGate {
            preparationArrived.fulfill()
        }
        defer { preparationGate.releaseIfNeeded() }
        let transport = TestNoteReplayAudioTransport()
        let renderer = TestNoteReplayPageRenderer()
        renderer.nextPreparationGate = preparationGate
        let dataSource = TestNoteReplayDataSource(snapshot: fixture)
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: dataSource,
            pageRenderer: renderer,
            scheduler: TestNoteReplayScheduler()
        )

        let startTask = Task { @MainActor in
            await controller.start(
                notebookID: NotebookID(),
                sessionID: sessionID,
                currentPageID: pageID
            )
        }
        await fulfillment(of: [preparationArrived], timeout: 1)
        startTask.cancel()
        preparationGate.releaseIfNeeded()
        await startTask.value

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(transport.startCalls.isEmpty)
        XCTAssertGreaterThanOrEqual(transport.stopCallCount, 1)
        XCTAssertEqual(dataSource.endReplaySessionCallCount, 1)
    }

    @MainActor
    func testInactiveDuringFinishedSeekCannotPublishLateAudioStart() async {
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [pageID],
            marks: [(pageID, 0)],
            duration: 10
        )
        let startArrived = expectation(description: "Finished seek start arrives")
        let startGate = TestNoteReplayOneShotGate(
            cancellationPolicy: .holdUntilExplicitRelease
        ) { startArrived.fulfill() }
        defer { startGate.releaseIfNeeded() }
        let transport = TestNoteReplayAudioTransport()
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: TestNoteReplayDataSource(snapshot: fixture),
            pageRenderer: TestNoteReplayPageRenderer(),
            scheduler: TestNoteReplayScheduler()
        )
        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: pageID
        )
        transport.snapshot = NoteReplayAudioPlaybackSnapshot(
            status: .finished,
            currentTime: 10
        )
        await controller.pollOnce()
        XCTAssertEqual(controller.state, .finished)
        transport.nextStartGate = startGate

        let seekTask = Task { @MainActor in
            await controller.seek(to: 4)
        }
        await fulfillment(of: [startArrived], timeout: 1)
        XCTAssertEqual(controller.state, .seeking)

        let stopInvoked = expectation(
            description: "Inactive stops rematerialized audio"
        )
        transport.observeNextStop { stopInvoked.fulfill() }
        let inactiveTask = Task { @MainActor in
            await controller.handleLifecycle(.becameInactive)
        }
        await fulfillment(of: [stopInvoked], timeout: 1)
        XCTAssertEqual(controller.state, .stopping)
        startGate.releaseIfNeeded()
        await inactiveTask.value
        await seekTask.value

        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(transport.startCalls.count, 1)
        XCTAssertGreaterThanOrEqual(transport.stopCallCount, 1)
    }

    @MainActor
    func testBackgroundStopPrecedesBlockedRendererUnwind() async {
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let fixture = makeFixture(
            sessionID: sessionID,
            pageIDs: [pageID],
            marks: [(pageID, 0)],
            duration: 10
        )
        let scheduler = TestNoteReplayScheduler()
        let renderer = TestNoteReplayPageRenderer()
        let transport = TestNoteReplayAudioTransport()
        let controller = NoteReplayController(
            audioTransport: transport,
            dataSource: TestNoteReplayDataSource(snapshot: fixture),
            pageRenderer: renderer,
            scheduler: scheduler
        )
        await controller.start(
            notebookID: NotebookID(),
            sessionID: sessionID,
            currentPageID: pageID
        )
        let refreshScheduled = expectation(
            description: "Pause refresh schedules before background test"
        )
        scheduler.observeNextSleep(dueWithin: 0.07) {
            refreshScheduled.fulfill()
        }
        let secondRender = expectation(description: "Pause refresh completes")
        renderer.observeRenderCount(2) { secondRender.fulfill() }
        await controller.pause()
        await fulfillment(of: [refreshScheduled], timeout: 1)
        scheduler.advance(by: 0.1)
        await fulfillment(of: [secondRender], timeout: 1)

        let renderArrived = expectation(description: "Blocked render arrives")
        let renderGate = TestNoteReplayOneShotGate(
            cancellationPolicy: .holdUntilExplicitRelease
        ) {
            renderArrived.fulfill()
        }
        defer { renderGate.releaseIfNeeded() }
        renderer.nextRenderGate = renderGate
        scheduler.advance(by: 0.1)
        await controller.setMode(.spotlight)
        await fulfillment(of: [renderArrived], timeout: 1)

        let stopInvoked = expectation(
            description: "Background stop reaches audio first"
        )
        transport.observeNextStop { stopInvoked.fulfill() }
        let stopTask = Task { @MainActor in
            await controller.handleLifecycle(.enteredBackground)
        }
        await fulfillment(of: [stopInvoked], timeout: 1)
        XCTAssertEqual(
            controller.state,
            .stopping,
            "Transport stop must happen while the non-preemptible render is still gated."
        )

        renderGate.releaseIfNeeded()
        await stopTask.value
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(transport.stopCallCount, 1)
    }

    private func makeFixture(
        sessionID: AudioSessionID,
        pageIDs: [PageID],
        marks: [(PageID, TimeInterval)],
        duration: TimeInterval,
        history: NoteReplayHistoryDocument? = nil
    ) -> NoteReplaySessionSnapshot {
        NoteReplaySessionSnapshot(
            descriptor: makeDescriptor(
                sessionID: sessionID,
                duration: duration,
                replayEventCount: history?.events.count
            ),
            timeline: AudioTimelineDocument(
                audioSessionID: sessionID,
                marks: marks.map { pageID, time in
                    AudioTimelineMark(
                        operationID: OperationID(),
                        pageID: pageID,
                        timeSeconds: time,
                        createdAt: recordingStart.addingTimeInterval(time)
                    )
                },
                modifiedAt: recordingStart.addingTimeInterval(duration)
            ),
            eligiblePageIDs: pageIDs,
            history: history
        )
    }

    private func makeDescriptor(
        sessionID: AudioSessionID,
        duration: TimeInterval,
        replayEventCount: Int? = nil
    ) -> AudioSessionDescriptor {
        AudioSessionDescriptor(
            schemaVersion: replayEventCount == nil ? 2 : 3,
            id: sessionID,
            createdAt: recordingStart.addingTimeInterval(duration),
            recordingStartedAt: recordingStart,
            durationSeconds: duration,
            timelineFilename: "\(sessionID.description).timeline.json",
            replayFilename: replayEventCount.map { _ in
                "\(sessionID.description).replay.json"
            },
            replayByteCount: replayEventCount.map { _ in Int64(1) },
            replaySHA256: replayEventCount.map { _ in
                String(repeating: "a", count: 64)
            },
            replayEventCount: replayEventCount
        )
    }
}

@MainActor
private final class TestNoteReplayAudioTransport: NoteReplayAudioTransport {
    struct StartCall: Equatable {
        let notebookID: NotebookID
        let sessionID: AudioSessionID
        let time: TimeInterval
    }

    var snapshot = NoteReplayAudioPlaybackSnapshot(
        status: .playing,
        currentTime: 0
    )
    private(set) var startCalls: [StartCall] = []
    private(set) var pauseCallCount = 0
    private(set) var resumeCallCount = 0
    private(set) var seekTimes: [TimeInterval] = []
    private(set) var stopCallCount = 0
    var nextSeekGate: TestNoteReplayOneShotGate?
    var nextStartGate: TestNoteReplayOneShotGate?
    var nextStopGate: TestNoteReplayOneShotGate?
    var pauseResultSnapshot: NoteReplayAudioPlaybackSnapshot?
    var failsNextPause = false
    private(set) var maximumConcurrentSeekCount = 0
    private var activeSeekCount = 0
    private var nextStopObserver: (() -> Void)?

    func startReplayAudio(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        from time: TimeInterval
    ) async throws {
        if let gate = nextStartGate {
            nextStartGate = nil
            try await gate.arriveAndWait()
            try Task.checkCancellation()
        }
        startCalls.append(StartCall(
            notebookID: notebookID,
            sessionID: sessionID,
            time: time
        ))
        snapshot = NoteReplayAudioPlaybackSnapshot(
            status: .playing,
            currentTime: time
        )
    }

    func pauseReplayAudio() async throws {
        pauseCallCount += 1
        if failsNextPause {
            failsNextPause = false
            throw TestNoteReplayTransportError.expectedFailure
        }
        if let pauseResultSnapshot {
            self.pauseResultSnapshot = nil
            snapshot = pauseResultSnapshot
        } else {
            snapshot = NoteReplayAudioPlaybackSnapshot(
                status: .paused,
                currentTime: snapshot.currentTime
            )
        }
    }

    func resumeReplayAudio() async throws {
        resumeCallCount += 1
        snapshot = NoteReplayAudioPlaybackSnapshot(
            status: .playing,
            currentTime: snapshot.currentTime
        )
    }

    func seekReplayAudio(to time: TimeInterval) async throws {
        activeSeekCount += 1
        maximumConcurrentSeekCount = max(
            maximumConcurrentSeekCount,
            activeSeekCount
        )
        defer { activeSeekCount -= 1 }
        if let gate = nextSeekGate {
            nextSeekGate = nil
            try await gate.arriveAndWait()
            try Task.checkCancellation()
        }
        seekTimes.append(time)
        snapshot = NoteReplayAudioPlaybackSnapshot(
            status: snapshot.status == .playing ? .playing : .paused,
            currentTime: time
        )
    }

    func stopReplayAudio() async {
        stopCallCount += 1
        snapshot = NoteReplayAudioPlaybackSnapshot(
            status: .stopped,
            currentTime: snapshot.currentTime
        )
        let observer = nextStopObserver
        nextStopObserver = nil
        observer?()
        if let gate = nextStopGate {
            nextStopGate = nil
            _ = try? await gate.arriveAndWait()
        }
    }

    func observeNextStop(_ observer: @escaping () -> Void) {
        precondition(nextStopObserver == nil)
        nextStopObserver = observer
    }

    func replayAudioPlaybackSnapshot() async throws
        -> NoteReplayAudioPlaybackSnapshot {
        snapshot
    }
}

private enum TestNoteReplayTransportError: Error {
    case expectedFailure
}

@MainActor
private final class TestNoteReplayDataSource: NoteReplayDataSource {
    let snapshot: NoteReplaySessionSnapshot
    var inkByPageID: [PageID: Data?] = [:]
    var replayInkByReference: [NoteReplayPayloadReference: Data?] = [:]
    var replayElementsByReference:
        [NoteReplayPayloadReference: NotebookExportCanvasElements] = [:]
    var sessionLoadGate: TestNoteReplayOneShotGate?
    private(set) var requestedInkMaximums: [Int] = []
    private(set) var loadCountByPageID: [PageID: Int] = [:]
    private(set) var requestedReplayInkReferences: [NoteReplayPayloadReference] = []
    private(set) var requestedReplayElementReferences: [NoteReplayPayloadReference] = []
    private(set) var endReplaySessionCallCount = 0

    init(snapshot: NoteReplaySessionSnapshot) {
        self.snapshot = snapshot
    }

    func loadReplaySession(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        maximumTimelineMarkCount: Int,
        maximumEligiblePageCount: Int,
        maximumHistoryEventCount: Int
    ) async throws -> NoteReplaySessionSnapshot {
        if let gate = sessionLoadGate {
            sessionLoadGate = nil
            try await gate.arriveAndWait()
            try Task.checkCancellation()
        }
        return snapshot
    }

    func loadReplayInk(
        notebookID: NotebookID,
        pageID: PageID,
        maximumByteCount: Int
    ) async throws -> Data? {
        requestedInkMaximums.append(maximumByteCount)
        loadCountByPageID[pageID, default: 0] += 1
        if let configured = inkByPageID[pageID] {
            return configured
        }
        return Data(inkKey(for: pageID).utf8)
    }

    func loadReplayInkPayload(
        notebookID: NotebookID,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int
    ) async throws -> Data? {
        requestedReplayInkReferences.append(reference)
        return replayInkByReference[reference] ?? nil
    }

    func loadReplayElementsPayload(
        notebookID: NotebookID,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int,
        maximumElementCount: Int
    ) async throws -> NotebookExportCanvasElements {
        requestedReplayElementReferences.append(reference)
        guard let value = replayElementsByReference[reference] else {
            throw TestNoteReplayDataSourceError.missingHistoricalPayload
        }
        return value
    }

    func endReplaySession() async {
        endReplaySessionCallCount += 1
    }

    func inkKey(for pageID: PageID) -> String {
        pageID.rawValue.uuidString.lowercased()
    }
}

private enum TestNoteReplayDataSourceError: Error {
    case missingHistoricalPayload
}

@MainActor
private final class TestNoteReplayPageRenderer: NoteReplayPageRendering {
    let conservativeByteCount: Int
    var nextRenderGate: TestNoteReplayOneShotGate?
    var nextPreparationGate: TestNoteReplayOneShotGate?
    private(set) var preparationCountByKey: [String: Int] = [:]
    private(set) var renderedTimes: [TimeInterval] = []

    private var renderCountObservers:
        [(target: Int, observer: () -> Void)] = []

    init(conservativeByteCount: Int = 16) {
        self.conservativeByteCount = conservativeByteCount
    }

    func prepareReplayPage(
        drawingData: Data?,
        timing: NoteReplaySessionTiming,
        limits: NoteReplayRenderingLimits
    ) async throws -> NoteReplayPreparedPage {
        let key = drawingData.flatMap { String(data: $0, encoding: .utf8) } ?? "empty"
        preparationCountByKey[key, default: 0] += 1
        if let gate = nextPreparationGate {
            nextPreparationGate = nil
            try await gate.arriveAndWait()
            try Task.checkCancellation()
        }
        return NoteReplayPreparedPage(
            conservativeByteCount: conservativeByteCount
        ) { [weak self] playbackTime, mode in
            guard let self else { throw CancellationError() }
            self.renderedTimes.append(playbackTime)
            self.notifySatisfiedRenderObservers()
            if let gate = self.nextRenderGate {
                self.nextRenderGate = nil
                try await gate.arriveAndWait()
            }
            try Task.checkCancellation()
            return NoteReplayFrame(
                drawing: PKDrawing(),
                requestedMode: mode,
                appliedMode: mode,
                playbackTime: playbackTime,
                fallback: nil,
                metadataFallbackStrokeCount: 0,
                processedStrokeCount: 0,
                processedPointCount: 0,
                revealedTimedStrokeCount: 0,
                strokePresentationStrategy:
                    .exactWholeOriginalStrokeAtFirstSample
            )
        }
    }

    func observeRenderCount(
        _ target: Int,
        onReached observer: @escaping () -> Void
    ) {
        guard renderedTimes.count < target else {
            observer()
            return
        }
        renderCountObservers.append((target, observer))
    }

    private func notifySatisfiedRenderObservers() {
        let satisfied = renderCountObservers.filter {
            renderedTimes.count >= $0.target
        }
        renderCountObservers.removeAll {
            renderedTimes.count >= $0.target
        }
        satisfied.forEach { $0.observer() }
    }
}

@MainActor
private final class TestNoteReplayOneShotGate {
    enum CancellationPolicy {
        case resumeThrowingCancellation
        case holdUntilExplicitRelease
    }

    private var hasArrived = false
    private var isCompleted = false
    private var waitID: UUID?
    private var releaseContinuation: CheckedContinuation<Void, Error>?
    private let cancellationPolicy: CancellationPolicy
    private let onArrival: () -> Void

    init(
        cancellationPolicy: CancellationPolicy = .resumeThrowingCancellation,
        onArrival: @escaping () -> Void = {}
    ) {
        self.cancellationPolicy = cancellationPolicy
        self.onArrival = onArrival
    }

    func arriveAndWait() async throws {
        precondition(!hasArrived, "A one-shot replay gate may only be entered once.")
        precondition(!isCompleted, "A replay gate cannot arrive after completion.")
        let id = UUID()
        switch cancellationPolicy {
        case .resumeThrowingCancellation:
            try Task.checkCancellation()
        case .holdUntilExplicitRelease:
            break
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waitID = id
                releaseContinuation = continuation
                hasArrived = true
                onArrival()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWait(id: id)
            }
        }
    }

    func releaseIfNeeded() {
        guard hasArrived, !isCompleted,
              let continuation = releaseContinuation else { return }
        isCompleted = true
        continuation.resume()
        waitID = nil
        releaseContinuation = nil
    }

    private func cancelWait(id: UUID) {
        switch cancellationPolicy {
        case .resumeThrowingCancellation:
            break
        case .holdUntilExplicitRelease:
            return
        }
        guard waitID == id, !isCompleted,
              let continuation = releaseContinuation else { return }
        isCompleted = true
        continuation.resume(throwing: CancellationError())
        waitID = nil
        releaseContinuation = nil
    }
}

@MainActor
private final class TestNoteReplayScheduler: NoteReplayScheduling {
    private struct SleepRequest {
        let id: UUID
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }

    private(set) var monotonicTime: TimeInterval = 0
    private var requests: [SleepRequest] = []
    private var sleepObservation:
        (maximumInterval: TimeInterval, observer: () -> Void)?

    func sleep(for interval: TimeInterval) async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let boundedInterval = max(interval, 0)
                requests.append(SleepRequest(
                    id: id,
                    deadline: monotonicTime + boundedInterval,
                    continuation: continuation
                ))
                if let sleepObservation,
                   boundedInterval <= sleepObservation.maximumInterval {
                    self.sleepObservation = nil
                    sleepObservation.observer()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelRequest(id)
            }
        }
    }

    func advance(by interval: TimeInterval) {
        monotonicTime += max(interval, 0)
        let ready = requests.filter { $0.deadline <= monotonicTime }
        requests.removeAll { $0.deadline <= monotonicTime }
        ready.forEach { $0.continuation.resume() }
    }

    func observeNextSleep(
        dueWithin interval: TimeInterval,
        onScheduled observer: @escaping () -> Void
    ) {
        precondition(sleepObservation == nil)
        sleepObservation = (max(interval, 0), observer)
    }

    private func cancelRequest(_ id: UUID) {
        guard let index = requests.firstIndex(where: { $0.id == id }) else {
            return
        }
        let request = requests.remove(at: index)
        request.continuation.resume(throwing: CancellationError())
    }
}
