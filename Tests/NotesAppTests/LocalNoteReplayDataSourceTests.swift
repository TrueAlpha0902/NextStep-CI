import Foundation
import NotesCore
import XCTest
@testable import NotesApp

final class LocalNoteReplayDataSourceTests: XCTestCase {
    private let recordingStart = Date(timeIntervalSinceReferenceDate: 91_000)

    @MainActor
    func testSessionKeepsCompleteTimelineAndProjectsEligiblePagesInManifestOrder() async throws {
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        let notebookPage = PageDescriptor(kind: .notebook)
        let textPage = PageDescriptor(kind: .textDocument)
        let whiteboardPage = PageDescriptor(kind: .whiteboard)
        let studyPage = PageDescriptor(kind: .studySet)
        let importedPage = PageDescriptor(kind: .importedDocument)
        let unknownPageID = PageID()
        let marks = [
            makeMark(pageID: unknownPageID, time: 1),
            makeMark(pageID: textPage.id, time: 2),
            makeMark(pageID: studyPage.id, time: 3),
            makeMark(pageID: whiteboardPage.id, time: 4),
        ]
        let descriptor = makeDescriptor(sessionID: sessionID, duration: 12)
        let timeline = makeTimeline(sessionID: sessionID, marks: marks, duration: 12)
        let manifest = NotebookManifest(
            id: notebookID,
            title: "Replay pages",
            pages: [
                notebookPage,
                textPage,
                whiteboardPage,
                studyPage,
                importedPage,
            ],
            audioSessions: [descriptor]
        )
        let store = RecordingNoteReplayStore(
            manifest: manifest,
            timeline: timeline,
            ink: nil
        )
        let dataSource = LocalNoteReplayDataSource(store: store)

        let snapshot = try await dataSource.loadReplaySession(
            notebookID: notebookID,
            sessionID: sessionID,
            maximumTimelineMarkCount: 37,
            maximumEligiblePageCount: 5
        )

        XCTAssertEqual(snapshot.descriptor, descriptor)
        XCTAssertEqual(snapshot.timeline, timeline)
        XCTAssertEqual(snapshot.timeline.marks.map(\.pageID), marks.map(\.pageID))
        XCTAssertEqual(
            snapshot.eligiblePageIDs,
            [notebookPage.id, whiteboardPage.id, importedPage.id]
        )
        let beforeEnd = await store.observation()
        XCTAssertEqual(beforeEnd.beginCount, 1)
        XCTAssertEqual(beforeEnd.timelineMaximums, [37])
        XCTAssertEqual(beforeEnd.endCount, 0)

        await dataSource.endReplaySession()
        await dataSource.endReplaySession()
        let afterEnd = await store.observation()
        XCTAssertEqual(afterEnd.endCount, 1)
    }

    @MainActor
    func testInkLimitIsForwardedExactlyAndReturnedBytesAreCheckedAgain() async throws {
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        let page = PageDescriptor(kind: .notebook)
        let descriptor = makeDescriptor(sessionID: sessionID, duration: 10)
        let store = RecordingNoteReplayStore(
            manifest: NotebookManifest(
                id: notebookID,
                title: "Replay ink",
                pages: [page],
                audioSessions: [descriptor]
            ),
            timeline: makeTimeline(sessionID: sessionID, marks: [], duration: 10),
            ink: Data(repeating: 0x5a, count: 74)
        )
        let dataSource = LocalNoteReplayDataSource(store: store)
        _ = try await dataSource.loadReplaySession(
            notebookID: notebookID,
            sessionID: sessionID,
            maximumTimelineMarkCount: 10,
            maximumEligiblePageCount: 1
        )

        do {
            _ = try await dataSource.loadReplayInk(
                notebookID: notebookID,
                pageID: page.id,
                maximumByteCount: 73
            )
            XCTFail("An over-limit store result must fail the adapter's second fence")
        } catch let error as LocalNoteReplayDataSourceError {
            XCTAssertEqual(error, .inkByteLimitExceeded(limit: 73))
        }
        let failedObservation = await store.observation()
        XCTAssertEqual(failedObservation.inkMaximums, [73])

        await store.setInk(Data(repeating: 0x4c, count: 73))
        let loaded = try await dataSource.loadReplayInk(
            notebookID: notebookID,
            pageID: page.id,
            maximumByteCount: 73
        )
        XCTAssertEqual(loaded?.count, 73)
        let successObservation = await store.observation()
        XCTAssertEqual(successObservation.inkMaximums, [73, 73])
        await dataSource.endReplaySession()
    }

    @MainActor
    func testHistoryAndSnapshotPayloadsStayInsideOneReplayCapability() async throws {
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        let page = PageDescriptor(kind: .notebook)
        let inkReference = NoteReplayPayloadReference(
            assetID: AssetID(String(repeating: "a", count: 64)),
            byteCount: 3
        )
        let elementsReference = NoteReplayPayloadReference(
            assetID: AssetID(String(repeating: "b", count: 64)),
            byteCount: 2
        )
        let event = NoteReplaySnapshotEvent(
            sequence: 0,
            timeSeconds: 0,
            pageID: page.id,
            kind: .baseline,
            inkPayload: inkReference,
            elementsPayload: elementsReference
        )
        let terminalEvent = NoteReplaySnapshotEvent(
            sequence: 1,
            timeSeconds: 10,
            pageID: page.id,
            kind: .terminal,
            inkPayload: inkReference,
            elementsPayload: elementsReference
        )
        let history = NoteReplayHistoryDocument(
            audioSessionID: sessionID,
            sealedAt: recordingStart.addingTimeInterval(10),
            events: [event, terminalEvent]
        )
        let descriptor = AudioSessionDescriptor(
            schemaVersion: 3,
            id: sessionID,
            createdAt: recordingStart,
            modifiedAt: recordingStart.addingTimeInterval(10),
            recordingStartedAt: recordingStart,
            durationSeconds: 10,
            replayFilename: "\(sessionID.description).replay.json",
            replayByteCount: 512,
            replaySHA256: String(repeating: "c", count: 64),
            replayEventCount: 2
        )
        let store = RecordingNoteReplayStore(
            manifest: NotebookManifest(
                id: notebookID,
                title: "Historical replay",
                pages: [page],
                audioSessions: [descriptor]
            ),
            timeline: makeTimeline(sessionID: sessionID, marks: [], duration: 10),
            ink: nil,
            history: history,
            replayInkByReference: [inkReference: Data([1, 2, 3])],
            replayElementsByReference: [
                elementsReference: NotebookExportCanvasElements(
                    elements: [],
                    encodedByteCount: 2
                ),
            ]
        )
        let dataSource = LocalNoteReplayDataSource(store: store)

        let snapshot = try await dataSource.loadReplaySession(
            notebookID: notebookID,
            sessionID: sessionID,
            maximumTimelineMarkCount: 10,
            maximumEligiblePageCount: 1,
            maximumHistoryEventCount: 7
        )
        XCTAssertEqual(snapshot.history, history)
        XCTAssertFalse(snapshot.historyUnavailable)

        let ink = try await dataSource.loadReplayInkPayload(
            notebookID: notebookID,
            reference: inkReference,
            maximumByteCount: 3
        )
        XCTAssertEqual(ink, Data([1, 2, 3]))
        let elements = try await dataSource.loadReplayElementsPayload(
            notebookID: notebookID,
            reference: elementsReference,
            maximumByteCount: 2,
            maximumElementCount: 1
        )
        XCTAssertEqual(elements.elements, [])
        XCTAssertEqual(elements.encodedByteCount, 2)

        let observation = await store.observation()
        XCTAssertEqual(observation.historyMaximums, [7])
        XCTAssertEqual(observation.replayInkMaximums, [3])
        XCTAssertEqual(observation.replayElementLimits.map { $0.bytes }, [2])
        XCTAssertEqual(observation.replayElementLimits.map { $0.elements }, [1])
        await dataSource.endReplaySession()
    }

    @MainActor
    func testInvalidReferencedHistoryIsMarkedUnavailableWithoutPublishingIt() async throws {
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        let page = PageDescriptor(kind: .notebook)
        let descriptor = AudioSessionDescriptor(
            schemaVersion: 3,
            id: sessionID,
            createdAt: recordingStart,
            modifiedAt: recordingStart.addingTimeInterval(10),
            recordingStartedAt: recordingStart,
            durationSeconds: 10,
            replayFilename: "\(sessionID.description).replay.json",
            replayByteCount: 512,
            replaySHA256: String(repeating: "d", count: 64),
            replayEventCount: 1
        )
        let store = RecordingNoteReplayStore(
            manifest: NotebookManifest(
                id: notebookID,
                title: "Unavailable history",
                pages: [page],
                audioSessions: [descriptor]
            ),
            timeline: makeTimeline(sessionID: sessionID, marks: [], duration: 10),
            ink: nil,
            history: NoteReplayHistoryDocument(
                audioSessionID: AudioSessionID(),
                events: []
            )
        )
        let dataSource = LocalNoteReplayDataSource(store: store)

        let snapshot = try await dataSource.loadReplaySession(
            notebookID: notebookID,
            sessionID: sessionID,
            maximumTimelineMarkCount: 10,
            maximumEligiblePageCount: 1,
            maximumHistoryEventCount: 10
        )
        XCTAssertNil(snapshot.history)
        XCTAssertTrue(snapshot.historyUnavailable)
        await dataSource.endReplaySession()
    }

    @MainActor
    func testGloballyDescendingHistoryTimeIsMarkedUnavailable() async throws {
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        let firstPage = PageDescriptor(kind: .notebook)
        let secondPage = PageDescriptor(kind: .whiteboard)
        let elements = NoteReplayPayloadReference(
            assetID: AssetID(String(repeating: "f", count: 64)),
            byteCount: 2
        )
        let history = NoteReplayHistoryDocument(
            audioSessionID: sessionID,
            sealedAt: recordingStart.addingTimeInterval(10),
            events: [
                NoteReplaySnapshotEvent(
                    sequence: 0,
                    timeSeconds: 5,
                    pageID: firstPage.id,
                    kind: .baseline,
                    inkPayload: nil,
                    elementsPayload: elements
                ),
                NoteReplaySnapshotEvent(
                    sequence: 1,
                    timeSeconds: 0,
                    pageID: secondPage.id,
                    kind: .baseline,
                    inkPayload: nil,
                    elementsPayload: elements
                ),
                NoteReplaySnapshotEvent(
                    sequence: 2,
                    timeSeconds: 10,
                    pageID: firstPage.id,
                    kind: .terminal,
                    inkPayload: nil,
                    elementsPayload: elements
                ),
                NoteReplaySnapshotEvent(
                    sequence: 3,
                    timeSeconds: 10,
                    pageID: secondPage.id,
                    kind: .terminal,
                    inkPayload: nil,
                    elementsPayload: elements
                ),
            ]
        )
        let descriptor = AudioSessionDescriptor(
            schemaVersion: 3,
            id: sessionID,
            createdAt: recordingStart,
            modifiedAt: recordingStart.addingTimeInterval(10),
            recordingStartedAt: recordingStart,
            durationSeconds: 10,
            replayFilename: "\(sessionID.description).replay.json",
            replayByteCount: 512,
            replaySHA256: String(repeating: "e", count: 64),
            replayEventCount: history.events.count
        )
        let store = RecordingNoteReplayStore(
            manifest: NotebookManifest(
                id: notebookID,
                title: "Out-of-order replay",
                pages: [firstPage, secondPage],
                audioSessions: [descriptor]
            ),
            timeline: makeTimeline(
                sessionID: sessionID,
                marks: [],
                duration: 10
            ),
            ink: nil,
            history: history
        )
        let dataSource = LocalNoteReplayDataSource(store: store)

        let snapshot = try await dataSource.loadReplaySession(
            notebookID: notebookID,
            sessionID: sessionID,
            maximumTimelineMarkCount: 10,
            maximumEligiblePageCount: 2,
            maximumHistoryEventCount: 10
        )

        XCTAssertNil(snapshot.history)
        XCTAssertTrue(snapshot.historyUnavailable)
        let observation = await store.observation()
        XCTAssertEqual(observation.historyMaximums, [10])
        await dataSource.endReplaySession()
    }

    @MainActor
    func testRedactedEmptyHistoryRemainsValidButContainsNoReplayScene() async throws {
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        let page = PageDescriptor(kind: .notebook)
        let descriptor = AudioSessionDescriptor(
            schemaVersion: 3,
            id: sessionID,
            createdAt: recordingStart,
            modifiedAt: recordingStart.addingTimeInterval(10),
            recordingStartedAt: recordingStart,
            durationSeconds: 10,
            replayFilename: "\(sessionID.description).replay.json",
            replayByteCount: 64,
            replaySHA256: String(repeating: "e", count: 64),
            replayEventCount: 0
        )
        let history = NoteReplayHistoryDocument(
            audioSessionID: sessionID,
            sealedAt: recordingStart.addingTimeInterval(10),
            events: []
        )
        let store = RecordingNoteReplayStore(
            manifest: NotebookManifest(
                id: notebookID,
                title: "Redacted replay",
                pages: [page],
                audioSessions: [descriptor]
            ),
            timeline: makeTimeline(sessionID: sessionID, marks: [], duration: 10),
            ink: nil,
            history: history
        )
        let dataSource = LocalNoteReplayDataSource(store: store)

        let snapshot = try await dataSource.loadReplaySession(
            notebookID: notebookID,
            sessionID: sessionID,
            maximumTimelineMarkCount: 10,
            maximumEligiblePageCount: 1,
            maximumHistoryEventCount: 10
        )

        XCTAssertEqual(snapshot.history, history)
        XCTAssertFalse(snapshot.historyUnavailable)
        await dataSource.endReplaySession()
    }

    @MainActor
    func testNotebookTimelineAndRequestedLimitsFailClosedAndReleaseCandidate() async throws {
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        let descriptor = makeDescriptor(sessionID: sessionID, duration: 10)
        let page = PageDescriptor(kind: .notebook)

        let mismatchedStore = RecordingNoteReplayStore(
            manifest: NotebookManifest(
                id: notebookID,
                title: "Mismatch",
                pages: [page],
                audioSessions: [descriptor]
            ),
            timeline: makeTimeline(
                sessionID: AudioSessionID(),
                marks: [],
                duration: 10
            ),
            ink: nil
        )
        let mismatchedSource = LocalNoteReplayDataSource(store: mismatchedStore)
        do {
            _ = try await mismatchedSource.loadReplaySession(
                notebookID: notebookID,
                sessionID: sessionID,
                maximumTimelineMarkCount: 10,
                maximumEligiblePageCount: 1
            )
            XCTFail("A mismatched timeline identifier must fail closed")
        } catch let error as LocalNoteReplayDataSourceError {
            XCTAssertEqual(error, .invalidTimeline(sessionID))
        }
        let mismatchObservation = await mismatchedStore.observation()
        XCTAssertEqual(mismatchObservation.endCount, 1)

        let twoMarks = [
            makeMark(pageID: page.id, time: 1),
            makeMark(pageID: page.id, time: 2),
        ]
        let markLimitStore = RecordingNoteReplayStore(
            manifest: NotebookManifest(
                id: notebookID,
                title: "Mark limit",
                pages: [page],
                audioSessions: [descriptor]
            ),
            timeline: makeTimeline(
                sessionID: sessionID,
                marks: twoMarks,
                duration: 10
            ),
            ink: nil
        )
        let markLimitSource = LocalNoteReplayDataSource(store: markLimitStore)
        do {
            _ = try await markLimitSource.loadReplaySession(
                notebookID: notebookID,
                sessionID: sessionID,
                maximumTimelineMarkCount: 1,
                maximumEligiblePageCount: 1
            )
            XCTFail("The adapter must enforce the requested mark count after return")
        } catch let error as LocalNoteReplayDataSourceError {
            XCTAssertEqual(error, .invalidTimeline(sessionID))
        }
        let markLimitObservation = await markLimitStore.observation()
        XCTAssertEqual(markLimitObservation.timelineMaximums, [1])
        XCTAssertEqual(markLimitObservation.endCount, 1)

        let invalidLimitSource = LocalNoteReplayDataSource(store: markLimitStore)
        do {
            _ = try await invalidLimitSource.loadReplaySession(
                notebookID: notebookID,
                sessionID: sessionID,
                maximumTimelineMarkCount:
                    NotebookReplayReadLimits.maximumTimelineMarks + 1,
                maximumEligiblePageCount: 1
            )
            XCTFail("A request cannot widen the hard timeline ceiling")
        } catch let error as LocalNoteReplayDataSourceError {
            XCTAssertEqual(error, .invalidRequestedLimits)
        }
        let invalidLimitObservation = await markLimitStore.observation()
        XCTAssertEqual(invalidLimitObservation.beginCount, 1)
    }

    @MainActor
    func testEligiblePageAndDescriptorLimitsFailBeforePublishingSession() async throws {
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        let pages = [
            PageDescriptor(kind: .notebook),
            PageDescriptor(kind: .whiteboard),
            PageDescriptor(kind: .importedDocument),
        ]
        let validDescriptor = makeDescriptor(sessionID: sessionID, duration: 10)
        let pageLimitStore = RecordingNoteReplayStore(
            manifest: NotebookManifest(
                id: notebookID,
                title: "Page limit",
                pages: pages,
                audioSessions: [validDescriptor]
            ),
            timeline: makeTimeline(sessionID: sessionID, marks: [], duration: 10),
            ink: nil
        )
        let pageLimitSource = LocalNoteReplayDataSource(store: pageLimitStore)
        do {
            _ = try await pageLimitSource.loadReplaySession(
                notebookID: notebookID,
                sessionID: sessionID,
                maximumTimelineMarkCount: 10,
                maximumEligiblePageCount: 2
            )
            XCTFail("Eligible pages must honor the caller's stricter limit")
        } catch let error as LocalNoteReplayDataSourceError {
            XCTAssertEqual(error, .eligiblePageLimitExceeded(limit: 2))
        }
        let pageLimitObservation = await pageLimitStore.observation()
        XCTAssertEqual(pageLimitObservation.endCount, 1)

        let invalidDescriptor = AudioSessionDescriptor(
            schemaVersion: 3,
            id: sessionID,
            createdAt: recordingStart,
            modifiedAt: recordingStart.addingTimeInterval(10),
            recordingStartedAt: recordingStart,
            durationSeconds: 10,
            timelineFilename: "\(sessionID.description).timeline.json"
        )
        let descriptorStore = RecordingNoteReplayStore(
            manifest: NotebookManifest(
                id: notebookID,
                title: "Descriptor limit",
                pages: [pages[0]],
                audioSessions: [invalidDescriptor]
            ),
            timeline: makeTimeline(sessionID: sessionID, marks: [], duration: 10),
            ink: nil
        )
        let descriptorSource = LocalNoteReplayDataSource(store: descriptorStore)
        do {
            _ = try await descriptorSource.loadReplaySession(
                notebookID: notebookID,
                sessionID: sessionID,
                maximumTimelineMarkCount: 10,
                maximumEligiblePageCount: 1
            )
            XCTFail("An invalid descriptor envelope must fail before timeline use")
        } catch let error as LocalNoteReplayDataSourceError {
            XCTAssertEqual(error, .invalidSession(sessionID))
        }
        let descriptorObservation = await descriptorStore.observation()
        XCTAssertTrue(descriptorObservation.timelineMaximums.isEmpty)
        XCTAssertEqual(descriptorObservation.endCount, 1)
    }

    @MainActor
    func testManifestIdentityAndDuplicateIDsFailBeforeTimelineRead() async throws {
        let storedNotebookID = NotebookID()
        let requestedNotebookID = NotebookID()
        let sessionID = AudioSessionID()
        let descriptor = makeDescriptor(sessionID: sessionID, duration: 10)
        let page = PageDescriptor(kind: .notebook)
        let identityStore = RecordingNoteReplayStore(
            manifest: NotebookManifest(
                id: storedNotebookID,
                title: "Wrong notebook",
                pages: [page],
                audioSessions: [descriptor]
            ),
            timeline: makeTimeline(sessionID: sessionID, marks: [], duration: 10),
            ink: nil
        )
        let identitySource = LocalNoteReplayDataSource(store: identityStore)
        do {
            _ = try await identitySource.loadReplaySession(
                notebookID: requestedNotebookID,
                sessionID: sessionID,
                maximumTimelineMarkCount: 10,
                maximumEligiblePageCount: 1
            )
            XCTFail("The capability and manifest must match the requested notebook")
        } catch let error as LocalNoteReplayDataSourceError {
            XCTAssertEqual(error, .invalidNotebook)
        }
        let identityObservation = await identityStore.observation()
        XCTAssertTrue(identityObservation.timelineMaximums.isEmpty)
        XCTAssertEqual(identityObservation.endCount, 1)

        let duplicateStore = RecordingNoteReplayStore(
            manifest: NotebookManifest(
                id: storedNotebookID,
                title: "Duplicate identifiers",
                pages: [page, page],
                audioSessions: [descriptor, descriptor]
            ),
            timeline: makeTimeline(sessionID: sessionID, marks: [], duration: 10),
            ink: nil
        )
        let duplicateSource = LocalNoteReplayDataSource(store: duplicateStore)
        do {
            _ = try await duplicateSource.loadReplaySession(
                notebookID: storedNotebookID,
                sessionID: sessionID,
                maximumTimelineMarkCount: 10,
                maximumEligiblePageCount: 2
            )
            XCTFail("Duplicate page or session identifiers must fail closed")
        } catch let error as LocalNoteReplayDataSourceError {
            XCTAssertEqual(error, .invalidNotebook)
        }
        let duplicateObservation = await duplicateStore.observation()
        XCTAssertTrue(duplicateObservation.timelineMaximums.isEmpty)
        XCTAssertEqual(duplicateObservation.endCount, 1)
    }

    @MainActor
    func testCancelledTimelineLoadReleasesCandidateExactlyOnce() async throws {
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        let descriptor = makeDescriptor(sessionID: sessionID, duration: 10)
        let gate = ReplayDataSourceAsyncGate()
        let store = RecordingNoteReplayStore(
            manifest: NotebookManifest(
                id: notebookID,
                title: "Cancellation",
                pages: [PageDescriptor(kind: .notebook)],
                audioSessions: [descriptor]
            ),
            timeline: makeTimeline(sessionID: sessionID, marks: [], duration: 10),
            ink: nil,
            timelineGate: gate
        )
        let dataSource = LocalNoteReplayDataSource(store: store)
        let task = Task { @MainActor in
            try await dataSource.loadReplaySession(
                notebookID: notebookID,
                sessionID: sessionID,
                maximumTimelineMarkCount: 10,
                maximumEligiblePageCount: 1
            )
        }
        await gate.waitUntilEntered()
        task.cancel()
        await gate.release()

        do {
            _ = try await task.value
            XCTFail("A cancelled timeline load must not publish a replay session")
        } catch is CancellationError {
            // Expected.
        }
        let observation = await store.observation()
        XCTAssertEqual(observation.endCount, 1)
        await dataSource.endReplaySession()
        let finalObservation = await store.observation()
        XCTAssertEqual(finalObservation.endCount, 1)
    }

    @MainActor
    func testSuccessfulSessionReplacementEndsPreviousCapabilityExactlyOnce() async throws {
        let notebookID = NotebookID()
        let sessionID = AudioSessionID()
        let descriptor = makeDescriptor(sessionID: sessionID, duration: 10)
        let store = RecordingNoteReplayStore(
            manifest: NotebookManifest(
                id: notebookID,
                title: "Replacement",
                pages: [PageDescriptor(kind: .notebook)],
                audioSessions: [descriptor]
            ),
            timeline: makeTimeline(sessionID: sessionID, marks: [], duration: 10),
            ink: nil
        )
        let dataSource = LocalNoteReplayDataSource(store: store)

        for _ in 0..<2 {
            _ = try await dataSource.loadReplaySession(
                notebookID: notebookID,
                sessionID: sessionID,
                maximumTimelineMarkCount: 10,
                maximumEligiblePageCount: 1
            )
        }
        let afterReplacement = await store.observation()
        XCTAssertEqual(afterReplacement.beginCount, 2)
        XCTAssertEqual(afterReplacement.endCount, 1)

        await dataSource.endReplaySession()
        await dataSource.endReplaySession()
        let finalObservation = await store.observation()
        XCTAssertEqual(finalObservation.endCount, 2)
    }

    private func makeDescriptor(
        sessionID: AudioSessionID,
        duration: TimeInterval
    ) -> AudioSessionDescriptor {
        AudioSessionDescriptor(
            id: sessionID,
            createdAt: recordingStart,
            modifiedAt: recordingStart.addingTimeInterval(duration),
            recordingStartedAt: recordingStart,
            durationSeconds: duration
        )
    }

    private func makeTimeline(
        sessionID: AudioSessionID,
        marks: [AudioTimelineMark],
        duration: TimeInterval
    ) -> AudioTimelineDocument {
        AudioTimelineDocument(
            audioSessionID: sessionID,
            marks: marks,
            modifiedAt: recordingStart.addingTimeInterval(duration)
        )
    }

    private func makeMark(
        pageID: PageID,
        time: TimeInterval
    ) -> AudioTimelineMark {
        AudioTimelineMark(
            operationID: OperationID(),
            pageID: pageID,
            timeSeconds: time,
            createdAt: recordingStart.addingTimeInterval(time)
        )
    }
}

private struct ReplayStoreObservation: Sendable {
    let beginCount: Int
    let timelineMaximums: [Int]
    let inkMaximums: [Int]
    let historyMaximums: [Int]
    let replayInkMaximums: [Int]
    let replayElementLimits: [(bytes: Int, elements: Int)]
    let endCount: Int
}

private actor RecordingNoteReplayStore: NoteReplayStoreReading {
    private let manifest: NotebookManifest
    private let timeline: AudioTimelineDocument
    private var ink: Data?
    private let history: NoteReplayHistoryDocument?
    private var replayInkByReference: [NoteReplayPayloadReference: Data?]
    private var replayElementsByReference:
        [NoteReplayPayloadReference: NotebookExportCanvasElements]
    private let timelineGate: ReplayDataSourceAsyncGate?
    private var beginCount = 0
    private var timelineMaximums: [Int] = []
    private var inkMaximums: [Int] = []
    private var historyMaximums: [Int] = []
    private var replayInkMaximums: [Int] = []
    private var replayElementLimits: [(bytes: Int, elements: Int)] = []
    private var endInvocationCount = 0

    init(
        manifest: NotebookManifest,
        timeline: AudioTimelineDocument,
        ink: Data?,
        history: NoteReplayHistoryDocument? = nil,
        replayInkByReference: [NoteReplayPayloadReference: Data?] = [:],
        replayElementsByReference:
            [NoteReplayPayloadReference: NotebookExportCanvasElements] = [:],
        timelineGate: ReplayDataSourceAsyncGate? = nil
    ) {
        self.manifest = manifest
        self.timeline = timeline
        self.ink = ink
        self.history = history
        self.replayInkByReference = replayInkByReference
        self.replayElementsByReference = replayElementsByReference
        self.timelineGate = timelineGate
    }

    func beginReplayReadSession(
        notebookID: NotebookID
    ) async throws -> NoteReplayStoreSession {
        beginCount += 1
        return NoteReplayStoreSession(
            token: NotebookExportSession(notebookID: manifest.id),
            manifest: manifest
        )
    }

    func loadReplayTimeline(
        session: NoteReplayStoreSession,
        sessionID: AudioSessionID,
        maximumMarkCount: Int
    ) async throws -> AudioTimelineDocument {
        timelineMaximums.append(maximumMarkCount)
        if let timelineGate {
            await timelineGate.enterAndWait()
            try Task.checkCancellation()
        }
        return timeline
    }

    func loadReplayInk(
        session: NoteReplayStoreSession,
        pageID: PageID,
        maximumByteCount: Int
    ) async throws -> Data? {
        inkMaximums.append(maximumByteCount)
        return ink
    }

    func loadNoteReplayHistoryForReplay(
        session: NotebookExportSession,
        sessionID: AudioSessionID,
        maximumEventCount: Int
    ) async throws -> NoteReplayHistoryDocument? {
        historyMaximums.append(maximumEventCount)
        return history
    }

    func loadNoteReplayInkPayloadForReplay(
        session: NotebookExportSession,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int
    ) async throws -> Data? {
        replayInkMaximums.append(maximumByteCount)
        return replayInkByReference[reference] ?? nil
    }

    func loadNoteReplayElementsPayloadForReplay(
        session: NotebookExportSession,
        reference: NoteReplayPayloadReference,
        maximumByteCount: Int,
        maximumElementCount: Int
    ) async throws -> NotebookExportCanvasElements {
        replayElementLimits.append((maximumByteCount, maximumElementCount))
        guard let loaded = replayElementsByReference[reference] else {
            throw LocalNoteReplayDataSourceError.replaySessionUnavailable
        }
        return loaded
    }

    func endReplayReadSession(_ session: NoteReplayStoreSession) async {
        _ = session
        endInvocationCount += 1
    }

    func setInk(_ ink: Data?) {
        self.ink = ink
    }

    func observation() -> ReplayStoreObservation {
        ReplayStoreObservation(
            beginCount: beginCount,
            timelineMaximums: timelineMaximums,
            inkMaximums: inkMaximums,
            historyMaximums: historyMaximums,
            replayInkMaximums: replayInkMaximums,
            replayElementLimits: replayElementLimits,
            endCount: endInvocationCount
        )
    }
}

private actor ReplayDataSourceAsyncGate {
    private var isEntered = false
    private var isReleased = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        isEntered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !isEntered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
