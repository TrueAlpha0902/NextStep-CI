import CryptoKit
import Foundation
import NotesCore
import NotesServices
@testable import NotesApp
import XCTest

final class NotebookAudioCoordinatorTests: XCTestCase {
    func testStopPersistsMappedMarksAndCleansTemporaryRecording() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let recorder = AudioRecordingFake(bytes: Data(repeating: 7, count: 32), duration: 4, markTimes: [1.25])
        let persistence = NotebookAudioPersistenceFake()
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            recorder: recorder,
            player: AudioPlayerFake(),
            transcriber: SpeechTranscriberFake(),
            workingDirectory: sandbox,
            now: { Date(timeIntervalSince1970: 2_000) }
        )
        let notebookID = NotebookID()
        let operationID = OperationID()
        let pageID = PageID()

        let recordingID = try await coordinator.startRecording(notebookID: notebookID)
        var snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.activity, .recording)
        XCTAssertEqual(snapshot.recordingID, recordingID)
        try await coordinator.addMark(operationID: operationID, pageID: pageID)

        let descriptor = try await coordinator.stopAndPersist()
        let capturedInput = await persistence.lastPersistedInput()
        let persisted = try XCTUnwrap(capturedInput)
        XCTAssertEqual(descriptor.id, AudioSessionID(recordingID))
        XCTAssertEqual(persisted.notebookID, notebookID)
        XCTAssertEqual(persisted.timeline.audioSessionID, descriptor.id)
        XCTAssertEqual(persisted.timeline.modifiedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(persisted.timeline.marks.count, 1)
        XCTAssertEqual(persisted.timeline.marks[0].operationID, operationID)
        XCTAssertEqual(persisted.timeline.marks[0].pageID, pageID)
        XCTAssertEqual(persisted.timeline.marks[0].timeSeconds, 1.25)
        XCTAssertEqual(persisted.recordingStartedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(descriptor.recordingStartedAt, persisted.recordingStartedAt)
        let replayPersistCalls = await persistence.replayPersistCallCount()
        let persistedReplayHistory = await persistence.lastPersistedReplayHistory()
        XCTAssertEqual(descriptor.schemaVersion, 2)
        XCTAssertEqual(replayPersistCalls, 0)
        XCTAssertNil(persistedReplayHistory)
        XCTAssertEqual(
            persisted.timeline.marks[0].createdAt,
            persisted.recordingStartedAt.addingTimeInterval(1.25)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: persisted.fileURL.path))
        snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot, .idle)
    }

    func testReplayCapturePersistsOrderedClockedSnapshotsAndDeduplicatesPayloads() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let recorder = AudioRecordingFake(
            duration: 4,
            recordingTimes: [0.125, 0.5, 1.5, 2.25, 3, 3.5]
        )
        let persistence = NotebookAudioPersistenceFake()
        let sealedAt = Date(timeIntervalSince1970: 2_500)
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            recorder: recorder,
            workingDirectory: sandbox,
            now: { sealedAt }
        )
        let pageID = PageID()
        let firstInk = Data([0x10, 0x20, 0x30])
        let secondInk = Data([0x40, 0x50, 0x60])
        let elementID = ElementID(try XCTUnwrap(
            UUID(uuidString: "10000000-0000-0000-0000-000000000001")
        ))
        let elementDate = Date(timeIntervalSinceReferenceDate: 123)
        let element = CanvasElement(
            id: elementID,
            frame: CanvasRect(x: 10, y: 20, width: 30, height: 40),
            content: .text(TextElement(text: "Replay")),
            createdAt: elementDate,
            modifiedAt: elementDate
        )
        let baseline = NotebookAudioReplayPageSnapshot(
            pageID: pageID,
            inkData: firstInk,
            elements: []
        )

        let recordingID = try await coordinator.startRecording(notebookID: NotebookID())
        try await coordinator.addReplayPageSnapshot(baseline)
        try await coordinator.addReplayPageSnapshot(baseline)
        try await coordinator.addReplayInkSnapshot(secondInk, pageID: pageID)
        try await coordinator.addReplayInkSnapshot(firstInk, pageID: pageID)
        try await coordinator.addReplayElementsSnapshot([element], pageID: pageID)
        try await coordinator.addReplayElementsSnapshot([], pageID: pageID)

        let descriptor = try await coordinator.stopAndPersist()
        let persistedReplay = await persistence.lastPersistedReplayHistory()
        let replayPersistCalls = await persistence.replayPersistCallCount()
        let capture = try XCTUnwrap(persistedReplay)
        let events = capture.document.events
        guard events.count == 6 else {
            XCTFail("Expected baseline, four changes, and one terminal snapshot.")
            return
        }

        XCTAssertEqual(descriptor.id, AudioSessionID(recordingID))
        XCTAssertEqual(replayPersistCalls, 1)
        XCTAssertEqual(capture.document.audioSessionID, descriptor.id)
        XCTAssertEqual(capture.document.sealedAt, sealedAt)
        XCTAssertEqual(
            events.map(\.kind),
            [.baseline, .change, .change, .change, .change, .terminal]
        )
        XCTAssertEqual(events.map(\.sequence), Array(0 ..< 6))
        XCTAssertEqual(events.map(\.timeSeconds), [0.125, 1.5, 2.25, 3, 3.5, 4])
        XCTAssertEqual(events.map(\.pageID), Array(repeating: pageID, count: 6))

        let payloadData = Dictionary(uniqueKeysWithValues: capture.payloads.map {
            ($0.reference, $0.data)
        })
        XCTAssertEqual(capture.payloads.count, 4)
        XCTAssertEqual(payloadData.count, 4)
        for blob in capture.payloads {
            let digest = CryptoKit.SHA256.hash(data: blob.data)
                .map { String(format: "%02x", $0) }
                .joined()
            XCTAssertEqual(blob.reference.assetID, AssetID(digest))
            XCTAssertEqual(blob.reference.byteCount, blob.data.count)
        }

        let baselineInk = try XCTUnwrap(events[0].inkPayload)
        let changedInk = try XCTUnwrap(events[1].inkPayload)
        XCTAssertEqual(payloadData[baselineInk], firstInk)
        XCTAssertEqual(payloadData[changedInk], secondInk)
        XCTAssertEqual(events[2].inkPayload, baselineInk)
        XCTAssertEqual(events[3].inkPayload, baselineInk)
        XCTAssertEqual(events[4].inkPayload, baselineInk)
        XCTAssertEqual(events[5].inkPayload, baselineInk)

        let baselineElements = events[0].elementsPayload
        XCTAssertEqual(events[1].elementsPayload, baselineElements)
        XCTAssertEqual(events[2].elementsPayload, baselineElements)
        XCTAssertNotEqual(events[3].elementsPayload, baselineElements)
        XCTAssertEqual(events[4].elementsPayload, baselineElements)
        XCTAssertEqual(events[5].elementsPayload, baselineElements)
        XCTAssertEqual(
            try NoteReplayPayloadCodec.decodeElements(
                XCTUnwrap(payloadData[events[3].elementsPayload])
            ),
            [element]
        )
        XCTAssertEqual(
            try NoteReplayPayloadCodec.decodeElements(
                XCTUnwrap(payloadData[baselineElements])
            ),
            []
        )
        let recordingTimeCalls = await recorder.recordingTimeCallCount()
        XCTAssertEqual(recordingTimeCalls, 6)
    }

    func testReplayCaptureFailureBeforeTerminalDoesNotAttemptPartialPersistence() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let recorder = AudioRecordingFake(duration: 2, recordingTimes: [3])
        let persistence = NotebookAudioPersistenceFake()
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            recorder: recorder,
            workingDirectory: sandbox
        )
        let notebookID = NotebookID()
        let pageID = PageID()

        _ = try await coordinator.startRecording(notebookID: notebookID)
        let startedURL = await recorder.startedURL()
        let temporaryURL = try XCTUnwrap(startedURL)
        try await coordinator.addReplayPageSnapshot(NotebookAudioReplayPageSnapshot(
            pageID: pageID,
            inkData: Data([0x01]),
            elements: []
        ))

        do {
            _ = try await coordinator.stopAndPersist()
            XCTFail("A terminal snapshot cannot precede the last capture clock.")
        } catch {
            XCTAssertEqual(
                error as? NotebookAudioCoordinatorError,
                .invalidReplayCapture
            )
        }

        let legacyPersistCalls = await persistence.persistCallCount()
        let replayPersistCalls = await persistence.replayPersistCallCount()
        let persistedReplay = await persistence.lastPersistedReplayHistory()
        let persistedInput = await persistence.lastPersistedInput()
        let listedSessions = try await persistence.listAudioSessions(notebookID: notebookID)
        XCTAssertEqual(legacyPersistCalls, 0)
        XCTAssertEqual(replayPersistCalls, 0)
        XCTAssertNil(persistedReplay)
        XCTAssertNil(persistedInput)
        XCTAssertTrue(listedSessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot, .idle)
    }

    func testPersistenceFailureReturnsToIdleAndRemovesRecording() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let recorder = AudioRecordingFake(bytes: Data(repeating: 1, count: 24), duration: 2)
        let persistence = NotebookAudioPersistenceFake(persistBehavior: .fail)
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            recorder: recorder,
            workingDirectory: sandbox
        )

        _ = try await coordinator.startRecording(notebookID: NotebookID())
        let startedURL = await recorder.startedURL()
        let temporaryURL = try XCTUnwrap(startedURL)
        do {
            _ = try await coordinator.stopAndPersist()
            XCTFail("Expected persistence failure")
        } catch let error as AudioPersistenceFakeError {
            XCTAssertEqual(error, .persistFailed)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot, .idle)
    }

    func testStopRollsBackWhenPersistenceChangesReplayZero() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let persistence = NotebookAudioPersistenceFake(
            descriptorRecordingStartOffset: 1
        )
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            recorder: AudioRecordingFake(),
            workingDirectory: sandbox
        )
        let notebookID = NotebookID()
        let recordingID = try await coordinator.startRecording(notebookID: notebookID)

        do {
            _ = try await coordinator.stopAndPersist()
            XCTFail("A changed recording start must not be accepted as replay timing.")
        } catch {
            XCTAssertEqual(
                error as? NotebookAudioCoordinatorError,
                .invalidRecordingResult
            )
        }

        let deletedIDs = await persistence.deletedSessionIDs()
        XCTAssertEqual(deletedIDs, [AudioSessionID(recordingID)])
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot, .idle)
    }

    func testCancelRecordingStopsRecorderAndCleansOwnedFile() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let recorder = AudioRecordingFake(bytes: Data(repeating: 2, count: 24), duration: 2)
        let coordinator = NotebookAudioCoordinator(
            persistence: NotebookAudioPersistenceFake(),
            recorder: recorder,
            workingDirectory: sandbox
        )

        _ = try await coordinator.startRecording(notebookID: NotebookID())
        let startedURL = await recorder.startedURL()
        let temporaryURL = try XCTUnwrap(startedURL)
        try await coordinator.cancelCurrentOperation()

        let cancelCount = await recorder.cancelCount()
        XCTAssertEqual(cancelCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot, .idle)
    }

    func testStalePersistenceCompletionIsRolledBackAfterCancel() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let recorder = AudioRecordingFake(bytes: Data(repeating: 3, count: 24), duration: 2)
        let persistence = NotebookAudioPersistenceFake(persistBehavior: .suspendIgnoringCancellation)
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            recorder: recorder,
            workingDirectory: sandbox
        )
        let notebookID = NotebookID()
        let recordingID = try await coordinator.startRecording(notebookID: notebookID)

        let stopTask = Task {
            try await coordinator.stopAndPersist()
        }
        await persistence.waitUntilPersistEntered()
        let persistingSnapshot = await coordinator.snapshot()
        XCTAssertEqual(persistingSnapshot.activity, .persistingRecording)

        let cancellationTask = Task { try await coordinator.cancelCurrentOperation() }
        while await coordinator.snapshot().activity != .cancelling {
            await Task<Never, Never>.yield()
        }
        await persistence.resumePersistence()
        try await cancellationTask.value
        do {
            _ = try await stopTask.value
            XCTFail("A stale completion must not be reported as a successful save")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let deleted = await persistence.deletedSessionIDs()
        XCTAssertEqual(deleted, [AudioSessionID(recordingID)])
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot, .idle)
    }

    func testDelayedRollbackUsesRepositoryCapturedBeforeRootChange() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let persistence = NotebookAudioPersistenceFake(persistBehavior: .suspendIgnoringCancellation)
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            recorder: AudioRecordingFake(),
            workingDirectory: sandbox
        )
        _ = try await coordinator.startRecording(notebookID: NotebookID())
        let stopTask = Task { try await coordinator.stopAndPersist() }
        await persistence.waitUntilPersistEntered()

        let cancellationTask = Task { try await coordinator.cancelCurrentOperation() }
        while await coordinator.snapshot().activity != .cancelling {
            await Task<Never, Never>.yield()
        }
        let duplicateCancellationTask = Task { try await coordinator.cancelCurrentOperation() }
        await persistence.simulateRootChange()
        await persistence.resumePersistence()
        try await cancellationTask.value
        try await duplicateCancellationTask.value

        do {
            _ = try await stopTask.value
            XCTFail("A save cancelled across a root change must not report success")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let rollbackGenerations = await persistence.deletedRepositoryGenerations()
        XCTAssertEqual(rollbackGenerations, [0])
    }

    func testReceiptRollbackIsExactlyOnceWhenCancellationFinishesBeforeStaleStopCompletion() async throws {
        let counter = NotebookAudioRollbackInvocationCounter()
        let receipt = NotebookAudioPersistenceReceipt(
            descriptor: AudioSessionDescriptor(
                id: AudioSessionID(),
                durationSeconds: 1
            )
        ) {
            await counter.recordInvocation()
        }
        let staleStopReceipt = receipt

        // Deterministically model the ordering that exposed the CI race: the
        // cancellation path finishes rollback before stale stop completion.
        try await receipt.rollback()
        let afterCancellation = await counter.invocationCount()
        XCTAssertEqual(afterCancellation, 1)

        try await staleStopReceipt.rollback()
        let afterStaleStopCompletion = await counter.invocationCount()
        XCTAssertEqual(afterStaleStopCompletion, 1)
    }

    func testMismatchedPersistenceDescriptorRollsBackExpectedSession() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let wrongSessionID = AudioSessionID()
        let recorder = AudioRecordingFake(bytes: Data(repeating: 3, count: 24), duration: 2)
        let persistence = NotebookAudioPersistenceFake(persistedDescriptorID: wrongSessionID)
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            recorder: recorder,
            workingDirectory: sandbox
        )
        let recordingID = try await coordinator.startRecording(notebookID: NotebookID())

        do {
            _ = try await coordinator.stopAndPersist()
            XCTFail("A mismatched descriptor must not be accepted")
        } catch let error as NotebookAudioCoordinatorError {
            XCTAssertEqual(error, .invalidRecordingResult)
        }

        let deleted = await persistence.deletedSessionIDs()
        XCTAssertEqual(deleted, [AudioSessionID(recordingID)])
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot, .idle)
    }

    func testRollbackFailureIsSurfacedAfterCancelledPersistenceCommits() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let persistence = NotebookAudioPersistenceFake(
            persistBehavior: .suspendIgnoringCancellation,
            deleteFails: true
        )
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            recorder: AudioRecordingFake(),
            workingDirectory: sandbox
        )
        _ = try await coordinator.startRecording(notebookID: NotebookID())
        let stopTask = Task { try await coordinator.stopAndPersist() }
        await persistence.waitUntilPersistEntered()

        let cancellationTask = Task { try await coordinator.cancelCurrentOperation() }
        while await coordinator.snapshot().activity != .cancelling {
            await Task<Never, Never>.yield()
        }
        await persistence.resumePersistence()

        do {
            try await cancellationTask.value
            XCTFail("A failed compensating delete must be visible")
        } catch let error as NotebookAudioCoordinatorError {
            XCTAssertEqual(error, .stalePersistenceRollbackFailed)
        }
        do {
            _ = try await stopTask.value
            XCTFail("A cancelled save must not report success")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot, .idle)
    }

    func testCancellationFenceIgnoresFailedRollbackFromOlderGeneration() throws {
        let oldGeneration = UUID()
        let requestedGeneration = UUID()
        let failedRollback = Result<Void, Error>.failure(
            NotebookAudioCoordinatorError.stalePersistenceRollbackFailed
        )

        let shouldCancelRequestedGeneration = try
            NotebookAudioCancellationTaskFence
                .shouldCancelRequestedGeneration(
                    existingResult: failedRollback,
                    existingGeneration: oldGeneration,
                    requestedGeneration: requestedGeneration
                )

        XCTAssertTrue(shouldCancelRequestedGeneration)
        XCTAssertThrowsError(
            try NotebookAudioCancellationTaskFence
                .shouldCancelRequestedGeneration(
                    existingResult: failedRollback,
                    existingGeneration: requestedGeneration,
                    requestedGeneration: requestedGeneration
                )
        ) { error in
            XCTAssertEqual(
                error as? NotebookAudioCoordinatorError,
                .stalePersistenceRollbackFailed
            )
        }
    }

    func testCancelledSuspendedMarkCannotReportSuccess() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let recorder = AudioRecordingFake(addMarkBehavior: .suspendIgnoringCancellation)
        let coordinator = NotebookAudioCoordinator(
            persistence: NotebookAudioPersistenceFake(),
            recorder: recorder,
            workingDirectory: sandbox
        )
        _ = try await coordinator.startRecording(notebookID: NotebookID())

        let markTask = Task {
            try await coordinator.addMark(operationID: OperationID(), pageID: PageID())
        }
        await recorder.waitUntilMarkEntered()
        try await coordinator.cancelCurrentOperation()
        await recorder.resumeMark()

        do {
            try await markTask.value
            XCTFail("A mark completion from a cancelled recording must be stale")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot, .idle)
    }

    func testRejectsNonFileWorkingDirectoryBeforeStartingRecorder() async throws {
        let recorder = AudioRecordingFake(bytes: Data(repeating: 1, count: 24), duration: 1)
        let coordinator = NotebookAudioCoordinator(
            persistence: NotebookAudioPersistenceFake(),
            recorder: recorder,
            workingDirectory: try XCTUnwrap(URL(string: "https://example.invalid/audio"))
        )

        do {
            _ = try await coordinator.startRecording(notebookID: NotebookID())
            XCTFail("Expected unsafe working-directory rejection")
        } catch let error as NotebookAudioCoordinatorError {
            XCTAssertEqual(error, .unsafeWorkingDirectory)
        }
        let startedURL = await recorder.startedURL()
        let snapshot = await coordinator.snapshot()
        XCTAssertNil(startedURL)
        XCTAssertEqual(snapshot, .idle)
    }

    func testRecorderCannotRedirectCleanupOutsideOwnedDirectory() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let outsideURL = sandbox.deletingLastPathComponent()
            .appendingPathComponent("Notes-Audio-Sentinel-\(UUID().uuidString).m4a")
        let sentinel = Data(repeating: 9, count: 24)
        try sentinel.write(to: outsideURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        let recorder = AudioRecordingFake(
            bytes: Data(repeating: 1, count: 24),
            duration: 1,
            resultURLOverride: outsideURL
        )
        let persistence = NotebookAudioPersistenceFake()
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            recorder: recorder,
            workingDirectory: sandbox
        )

        _ = try await coordinator.startRecording(notebookID: NotebookID())
        let startedURL = await recorder.startedURL()
        let ownedURL = try XCTUnwrap(startedURL)
        do {
            _ = try await coordinator.stopAndPersist()
            XCTFail("Expected redirected result rejection")
        } catch let error as NotebookAudioCoordinatorError {
            XCTAssertEqual(error, .invalidRecordingResult)
        }

        XCTAssertEqual(try Data(contentsOf: outsideURL), sentinel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedURL.path))
        let persistCallCount = await persistence.persistCallCount()
        XCTAssertEqual(persistCallCount, 0)
    }

    func testRecorderCannotReplaceOwnedResultWithSymbolicLink() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let outsideURL = sandbox.deletingLastPathComponent()
            .appendingPathComponent("Notes-Audio-Sentinel-\(UUID().uuidString).m4a")
        let sentinel = Data(repeating: 8, count: 24)
        try sentinel.write(to: outsideURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        let recorder = AudioRecordingFake(replaceResultWithSymbolicLinkTo: outsideURL)
        let persistence = NotebookAudioPersistenceFake()
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            recorder: recorder,
            workingDirectory: sandbox
        )

        _ = try await coordinator.startRecording(notebookID: NotebookID())
        let startedResultURL = await recorder.startedURL()
        let startedURL = try XCTUnwrap(startedResultURL)
        do {
            _ = try await coordinator.stopAndPersist()
            XCTFail("A symbolic-link recording result must be rejected")
        } catch let error as NotebookAudioCoordinatorError {
            XCTAssertEqual(error, .unsafeTemporaryFile)
        }

        XCTAssertEqual(try Data(contentsOf: outsideURL), sentinel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: startedURL.path))
        let persistCallCount = await persistence.persistCallCount()
        XCTAssertEqual(persistCallCount, 0)
    }

    func testRecordingCapPreventsDataBasedCoreIngestAndCleansFile() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let recorder = AudioRecordingFake(bytes: Data(repeating: 4, count: 17), duration: 1)
        let persistence = NotebookAudioPersistenceFake()
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            recorder: recorder,
            workingDirectory: sandbox,
            configuration: NotebookAudioCoordinatorConfiguration(
                maximumRecordingBytes: 16,
                maximumMaterializedBytes: 64,
                chunkByteCount: 8
            )
        )

        _ = try await coordinator.startRecording(notebookID: NotebookID())
        let startedURL = await recorder.startedURL()
        let temporaryURL = try XCTUnwrap(startedURL)
        do {
            _ = try await coordinator.stopAndPersist()
            XCTFail("Expected recording cap rejection")
        } catch let error as NotebookAudioCoordinatorError {
            XCTAssertEqual(error, .recordingTooLarge(maximumBytes: 16))
        }

        let persistCallCount = await persistence.persistCallCount()
        XCTAssertEqual(persistCallCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot, .idle)
    }

    func testTranscriptionMaterializesChunksAndMapsSegmentsToDurableMarks() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sessionID = AudioSessionID()
        let firstPageID = PageID()
        let secondPageID = PageID()
        let firstOperationID = OperationID()
        let secondOperationID = OperationID()
        let timeline = NotesCore.AudioTimelineDocument(
            audioSessionID: sessionID,
            marks: [
                NotesCore.AudioTimelineMark(
                    operationID: firstOperationID,
                    pageID: firstPageID,
                    timeSeconds: 1
                ),
                NotesCore.AudioTimelineMark(
                    operationID: secondOperationID,
                    pageID: secondPageID,
                    timeSeconds: 2.5
                ),
            ]
        )
        let audio = Data((0 ..< 12).map { UInt8($0) })
        let persistence = NotebookAudioPersistenceFake(
            storedAudio: audio,
            storedTimeline: timeline
        )
        let firstSegment = TranscriptSegment(
            text: "Before",
            startTime: 0.5,
            duration: 0.2,
            confidence: 0.8
        )
        let secondSegment = TranscriptSegment(
            text: "After",
            startTime: 3,
            duration: 0.4,
            confidence: 0.9
        )
        let transcriber = SpeechTranscriberFake(segments: [firstSegment, secondSegment])
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            recorder: AudioRecordingFake(),
            player: AudioPlayerFake(),
            transcriber: transcriber,
            workingDirectory: sandbox,
            configuration: NotebookAudioCoordinatorConfiguration(
                maximumRecordingBytes: 64,
                maximumMaterializedBytes: 64,
                chunkByteCount: 4
            ),
            now: { Date(timeIntervalSince1970: 3_000) }
        )

        let payload = try await coordinator.transcribe(
            notebookID: NotebookID(),
            sessionID: sessionID,
            localeIdentifier: "zh-Hant-TW"
        )

        XCTAssertEqual(payload.provenance, .speechTranscriber)
        XCTAssertEqual(payload.generatedAt, Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(payload.segments.map(\.id), [firstSegment.id, secondSegment.id])
        XCTAssertNil(payload.segments[0].timelineMarkID)
        XCTAssertEqual(payload.segments[1].operationID, secondOperationID)
        XCTAssertEqual(payload.segments[1].pageID, secondPageID)
        let savedTranscript = await persistence.savedTranscript()
        XCTAssertEqual(savedTranscript, payload)
        let chunkRequests = await persistence.chunkRequests()
        XCTAssertEqual(chunkRequests, [4, 4, 4])
        let receivedURL = await transcriber.receivedURL()
        let transcribedURL = try XCTUnwrap(receivedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcribedURL.path))
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot, .idle)
    }

    func testTranscriptionSortsSegmentsAndClampsFloatingPointTailToDuration() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sessionID = AudioSessionID()
        let lateID = UUID()
        let earlyID = UUID()
        let persistence = NotebookAudioPersistenceFake(
            storedAudio: Data(repeating: 9, count: 12),
            storedTimeline: NotesCore.AudioTimelineDocument(audioSessionID: sessionID)
        )
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            transcriber: SpeechTranscriberFake(segments: [
                TranscriptSegment(
                    id: lateID,
                    text: "Tail",
                    startTime: 9.9995,
                    duration: 0.001,
                    confidence: 1
                ),
                TranscriptSegment(
                    id: earlyID,
                    text: "First",
                    startTime: 1,
                    duration: 0.2,
                    confidence: 1
                ),
            ]),
            workingDirectory: sandbox,
            configuration: NotebookAudioCoordinatorConfiguration(
                maximumRecordingBytes: 64,
                maximumMaterializedBytes: 64,
                chunkByteCount: 4
            )
        )

        let payload = try await coordinator.transcribe(
            notebookID: NotebookID(),
            sessionID: sessionID
        )

        XCTAssertEqual(payload.segments.map(\.id), [earlyID, lateID])
        XCTAssertEqual(payload.segments[1].startTime, 9.9995, accuracy: 0.000_001)
        XCTAssertEqual(payload.segments[1].duration, 0.0005, accuracy: 0.000_001)
    }

    func testTranscriptionRejectsOversizedSegmentBeforePersistence() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sessionID = AudioSessionID()
        let persistence = NotebookAudioPersistenceFake(
            storedAudio: Data(repeating: 9, count: 12),
            storedTimeline: NotesCore.AudioTimelineDocument(audioSessionID: sessionID)
        )
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            transcriber: SpeechTranscriberFake(segments: [
                TranscriptSegment(
                    text: String(
                        repeating: "x",
                        count: AudioTranscriptDocument.maximumTextUTF8BytesPerSegment + 1
                    ),
                    startTime: 0,
                    duration: 0.1,
                    confidence: 1
                ),
            ]),
            workingDirectory: sandbox,
            configuration: NotebookAudioCoordinatorConfiguration(
                maximumRecordingBytes: 64,
                maximumMaterializedBytes: 64,
                chunkByteCount: 4
            )
        )

        do {
            _ = try await coordinator.transcribe(
                notebookID: NotebookID(),
                sessionID: sessionID
            )
            XCTFail("An oversized transcript segment must be rejected before persistence.")
        } catch let error as NotebookAudioCoordinatorError {
            XCTAssertEqual(error, .incompleteAudioMaterialization)
        }
        let savedTranscript = await persistence.savedTranscript()
        let snapshot = await coordinator.snapshot()
        XCTAssertNil(savedTranscript)
        XCTAssertEqual(snapshot, .idle)
    }

    func testTranscriptionRejectsMaterializedAudioDigestMismatch() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sessionID = AudioSessionID()
        let persistence = NotebookAudioPersistenceFake(
            storedAudio: Data(repeating: 6, count: 12),
            storedTimeline: NotesCore.AudioTimelineDocument(audioSessionID: sessionID),
            descriptorDigestOverride: String(repeating: "0", count: 64)
        )
        let transcriber = SpeechTranscriberFake()
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            transcriber: transcriber,
            workingDirectory: sandbox,
            configuration: NotebookAudioCoordinatorConfiguration(
                maximumRecordingBytes: 64,
                maximumMaterializedBytes: 64,
                chunkByteCount: 4
            )
        )

        do {
            _ = try await coordinator.transcribe(notebookID: NotebookID(), sessionID: sessionID)
            XCTFail("A digest mismatch must reject materialized audio")
        } catch let error as NotebookAudioCoordinatorError {
            XCTAssertEqual(error, .incompleteAudioMaterialization)
        }
        let receivedURL = await transcriber.receivedURL()
        let snapshot = await coordinator.snapshot()
        XCTAssertNil(receivedURL)
        XCTAssertEqual(snapshot, .idle)
    }

    func testTranscriptionRejectsTimelineMarkBeyondDescriptorDuration() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sessionID = AudioSessionID()
        let timeline = NotesCore.AudioTimelineDocument(
            audioSessionID: sessionID,
            marks: [
                NotesCore.AudioTimelineMark(
                    operationID: OperationID(),
                    pageID: PageID(),
                    timeSeconds: 11
                ),
            ]
        )
        let persistence = NotebookAudioPersistenceFake(
            storedAudio: Data(repeating: 5, count: 12),
            storedTimeline: timeline
        )
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            transcriber: SpeechTranscriberFake(segments: [
                TranscriptSegment(text: "Late", startTime: 11, duration: 0.2, confidence: 1),
            ]),
            workingDirectory: sandbox,
            configuration: NotebookAudioCoordinatorConfiguration(
                maximumRecordingBytes: 64,
                maximumMaterializedBytes: 64,
                chunkByteCount: 4
            )
        )

        do {
            _ = try await coordinator.transcribe(notebookID: NotebookID(), sessionID: sessionID)
            XCTFail("Timeline marks beyond the recording duration must be rejected")
        } catch let error as NotebookAudioCoordinatorError {
            XCTAssertEqual(error, .incompleteAudioMaterialization)
        }
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot, .idle)
    }

    func testCancelledTranscriptionWaitsForWorkerAndCleansMaterializedFile() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sessionID = AudioSessionID()
        let persistence = NotebookAudioPersistenceFake(
            storedAudio: Data(repeating: 2, count: 12),
            storedTimeline: NotesCore.AudioTimelineDocument(audioSessionID: sessionID)
        )
        let transcriber = SpeechTranscriberFake(behavior: .suspendIgnoringCancellation)
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            transcriber: transcriber,
            workingDirectory: sandbox,
            configuration: NotebookAudioCoordinatorConfiguration(
                maximumRecordingBytes: 64,
                maximumMaterializedBytes: 64,
                chunkByteCount: 4
            )
        )
        let transcriptionTask = Task {
            try await coordinator.transcribe(notebookID: NotebookID(), sessionID: sessionID)
        }
        await transcriber.waitUntilEntered()
        let receivedResultURL = await transcriber.receivedURL()
        let receivedURL = try XCTUnwrap(receivedResultURL)
        let cancellationTask = Task { try await coordinator.cancelCurrentOperation() }

        while true {
            let snapshot = await coordinator.snapshot()
            if snapshot.activity == .cancelling { break }
            await Task<Never, Never>.yield()
        }

        await transcriber.resume()
        try await cancellationTask.value
        do {
            _ = try await transcriptionTask.value
            XCTFail("A cancelled transcription must not publish stale segments")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: receivedURL.path))
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot, .idle)
    }

    func testCancellationWaitsForInFlightAtomicTranscriptSaveAndRejectsStaleResult() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sessionID = AudioSessionID()
        let persistence = NotebookAudioPersistenceFake(
            storedAudio: Data(repeating: 8, count: 12),
            storedTimeline: NotesCore.AudioTimelineDocument(audioSessionID: sessionID),
            transcriptSaveBehavior: .suspendIgnoringCancellation
        )
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            transcriber: SpeechTranscriberFake(segments: [
                TranscriptSegment(text: "Saved atomically", startTime: 0, duration: 0.1, confidence: 1),
            ]),
            workingDirectory: sandbox,
            configuration: NotebookAudioCoordinatorConfiguration(
                maximumRecordingBytes: 64,
                maximumMaterializedBytes: 64,
                chunkByteCount: 4
            )
        )
        let transcription = Task {
            try await coordinator.transcribe(notebookID: NotebookID(), sessionID: sessionID)
        }
        await persistence.waitUntilTranscriptSaveEntered()
        let cancellation = Task { try await coordinator.cancelCurrentOperation() }
        while true {
            let snapshot = await coordinator.snapshot()
            if snapshot.activity == .cancelling { break }
            await Task<Never, Never>.yield()
        }
        await persistence.resumeTranscriptSave()
        try await cancellation.value
        do {
            _ = try await transcription.value
            XCTFail("A cancelled generation must not publish its transcript result.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let savedTranscript = await persistence.savedTranscript()
        let finalSnapshot = await coordinator.snapshot()
        XCTAssertNotNil(savedTranscript)
        XCTAssertEqual(finalSnapshot, .idle)
    }

    func testInvalidTranscriptionLocaleIsRejectedBeforeAudioLoading() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sessionID = AudioSessionID()
        let persistence = NotebookAudioPersistenceFake(
            storedAudio: Data(repeating: 7, count: 12),
            storedTimeline: NotesCore.AudioTimelineDocument(audioSessionID: sessionID)
        )
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            workingDirectory: sandbox
        )

        do {
            _ = try await coordinator.transcribe(
                notebookID: NotebookID(),
                sessionID: sessionID,
                localeIdentifier: "zh-Hant\nTW"
            )
            XCTFail("Control characters are not valid locale identifiers")
        } catch let error as NotebookAudioCoordinatorError {
            XCTAssertEqual(error, .invalidLocaleIdentifier)
        }
        let descriptorCallCount = await persistence.descriptorCallCount()
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(descriptorCallCount, 0)
        XCTAssertEqual(snapshot, .idle)
    }

    func testPlaybackStateIsMutuallyExclusiveAndCleansMaterializedFile() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sessionID = AudioSessionID()
        let audio = Data(repeating: 6, count: 12)
        let persistence = NotebookAudioPersistenceFake(
            storedAudio: audio,
            storedTimeline: NotesCore.AudioTimelineDocument(audioSessionID: sessionID)
        )
        let player = AudioPlayerFake()
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            recorder: AudioRecordingFake(),
            player: player,
            workingDirectory: sandbox,
            configuration: NotebookAudioCoordinatorConfiguration(
                maximumRecordingBytes: 64,
                maximumMaterializedBytes: 64,
                chunkByteCount: 5
            )
        )
        let notebookID = NotebookID()

        try await coordinator.play(notebookID: notebookID, sessionID: sessionID)
        var snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.activity, .playing)
        do {
            _ = try await coordinator.startRecording(notebookID: notebookID)
            XCTFail("Playback and recording must be mutually exclusive")
        } catch let error as NotebookAudioCoordinatorError {
            XCTAssertEqual(error, .busy(.playing))
        }

        try await coordinator.pausePlayback()
        snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.activity, .paused)
        try await coordinator.resumePlayback()
        snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.activity, .playing)
        let receivedURL = await player.receivedURL()
        let playbackURL = try XCTUnwrap(receivedURL)
        await coordinator.stopPlayback()
        snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: playbackURL.path))
        let stopCount = await player.stopCount()
        let chunkRequests = await persistence.chunkRequests()
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(chunkRequests, [5, 5, 2])
    }

    func testReplayPlaybackOwnerCannotBeControlledByStandardOrStaleOwners() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sessionID = AudioSessionID()
        let persistence = NotebookAudioPersistenceFake(
            storedAudio: Data(repeating: 6, count: 12),
            storedTimeline: NotesCore.AudioTimelineDocument(audioSessionID: sessionID)
        )
        let player = AudioPlayerFake()
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            player: player,
            workingDirectory: sandbox,
            configuration: NotebookAudioCoordinatorConfiguration(
                maximumRecordingBytes: 64,
                maximumMaterializedBytes: 64,
                chunkByteCount: 5
            )
        )
        let ownerID = UUID()
        let staleOwnerID = UUID()

        try await coordinator.startReplayPlayback(
            notebookID: NotebookID(),
            sessionID: sessionID,
            from: 0,
            ownerID: ownerID
        )

        await coordinator.stopPlayback()
        await coordinator.stopReplayPlayback(ownerID: staleOwnerID)
        try await coordinator.cancelStandardOperation()
        let standardSnapshot = await coordinator.standardSnapshot()
        let standardPlaybackState = await coordinator.standardPlaybackState()
        var snapshot = await coordinator.snapshot()
        let stopCountBeforeOwnerStop = await player.stopCount()
        XCTAssertEqual(standardSnapshot, .idle)
        XCTAssertEqual(standardPlaybackState, .stopped)
        XCTAssertEqual(stopCountBeforeOwnerStop, 0)
        XCTAssertEqual(snapshot.activity, .playing)
        do {
            try await coordinator.pausePlayback()
            XCTFail("Standard controls must not acquire a Replay-owned player")
        } catch let error as NotebookAudioCoordinatorError {
            XCTAssertEqual(error, .noActivePlayback)
        }
        do {
            try await coordinator.seekReplayPlayback(to: 2, ownerID: staleOwnerID)
            XCTFail("A stale Replay owner must not seek the active player")
        } catch let error as NotebookAudioCoordinatorError {
            XCTAssertEqual(error, .noActivePlayback)
        }

        try await coordinator.pauseReplayPlayback(ownerID: ownerID)
        snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.activity, .paused)
        try await coordinator.seekReplayPlayback(to: 3, ownerID: ownerID)
        try await coordinator.resumeReplayPlayback(ownerID: ownerID)
        snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot.activity, .playing)

        await coordinator.stopReplayPlayback(ownerID: ownerID)
        snapshot = await coordinator.snapshot()
        let stopCount = await player.stopCount()
        XCTAssertEqual(snapshot, .idle)
        XCTAssertEqual(stopCount, 1)
    }

    func testStandardSnapshotHidesReplayWhileCancellationIsInFlight() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sessionID = AudioSessionID()
        let persistence = NotebookAudioPersistenceFake(
            storedAudio: Data(repeating: 6, count: 12),
            storedTimeline: NotesCore.AudioTimelineDocument(audioSessionID: sessionID)
        )
        let player = AudioPlayerFake()
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            player: player,
            workingDirectory: sandbox,
            configuration: NotebookAudioCoordinatorConfiguration(
                maximumRecordingBytes: 64,
                maximumMaterializedBytes: 64,
                chunkByteCount: 5
            )
        )
        let ownerID = UUID()
        try await coordinator.startReplayPlayback(
            notebookID: NotebookID(),
            sessionID: sessionID,
            from: 0,
            ownerID: ownerID
        )
        await player.suspendNextStop()

        let stopTask = Task {
            await coordinator.stopReplayPlayback(ownerID: ownerID)
        }
        await player.waitUntilSuspendedStopEntered()
        let standardSnapshot = await coordinator.standardSnapshot()
        let internalSnapshot = await coordinator.snapshot()

        XCTAssertEqual(standardSnapshot, .idle)
        XCTAssertEqual(internalSnapshot.activity, .cancelling)
        await player.resumeSuspendedStop()
        await stopTask.value
    }

    func testReplayPlaybackPreservesFinishedAndFailedTerminalStates() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sessionID = AudioSessionID()
        let persistence = NotebookAudioPersistenceFake(
            storedAudio: Data(repeating: 6, count: 12),
            storedTimeline: NotesCore.AudioTimelineDocument(audioSessionID: sessionID)
        )
        let player = AudioPlayerFake()
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            player: player,
            workingDirectory: sandbox,
            configuration: NotebookAudioCoordinatorConfiguration(
                maximumRecordingBytes: 64,
                maximumMaterializedBytes: 64,
                chunkByteCount: 5
            )
        )
        let finishedOwnerID = UUID()

        try await coordinator.startReplayPlayback(
            notebookID: NotebookID(),
            sessionID: sessionID,
            from: 0,
            ownerID: finishedOwnerID
        )
        let receivedFinishedURL = await player.receivedURL()
        let finishedURL = try XCTUnwrap(receivedFinishedURL)
        await player.setState(
            AudioPlaybackState(
                status: .finished,
                fileURL: finishedURL,
                currentTime: 10,
                duration: 10
            )
        )
        let observerSnapshot = await coordinator.snapshot()
        let wrongOwnerResult = await coordinator.replayPlaybackState(
            ownerID: UUID()
        )
        let finishedResult = await coordinator.replayPlaybackState(
            ownerID: finishedOwnerID
        )
        let finished = try XCTUnwrap(finishedResult)
        XCTAssertEqual(observerSnapshot, .idle)
        XCTAssertNil(wrongOwnerResult)
        XCTAssertEqual(finished.status, .finished)
        XCTAssertEqual(finished.currentTime, finished.duration)
        let staleFinishedState = await coordinator.replayPlaybackState(
            ownerID: finishedOwnerID
        )
        let finishedSnapshot = await coordinator.snapshot()
        XCTAssertNil(staleFinishedState)
        XCTAssertEqual(finishedSnapshot, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finishedURL.path))

        let failedOwnerID = UUID()
        try await coordinator.startReplayPlayback(
            notebookID: NotebookID(),
            sessionID: sessionID,
            from: 0,
            ownerID: failedOwnerID
        )
        let receivedFailedURL = await player.receivedURL()
        let failedURL = try XCTUnwrap(receivedFailedURL)
        await player.setState(
            AudioPlaybackState(
                status: .failed,
                fileURL: failedURL,
                currentTime: 9.9,
                duration: 10
            )
        )
        let failedObserverSnapshot = await coordinator.snapshot()
        let failedResult = await coordinator.replayPlaybackState(
            ownerID: failedOwnerID
        )
        let failed = try XCTUnwrap(failedResult)
        XCTAssertEqual(failedObserverSnapshot, .idle)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(failed.currentTime, 9.9)
        let failedSnapshot = await coordinator.snapshot()
        XCTAssertEqual(failedSnapshot, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: failedURL.path))
    }

    func testReplayStartCannotStealStandardPlayback() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sessionID = AudioSessionID()
        let persistence = NotebookAudioPersistenceFake(
            storedAudio: Data(repeating: 6, count: 12),
            storedTimeline: NotesCore.AudioTimelineDocument(audioSessionID: sessionID)
        )
        let player = AudioPlayerFake()
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            player: player,
            workingDirectory: sandbox,
            configuration: NotebookAudioCoordinatorConfiguration(
                maximumRecordingBytes: 64,
                maximumMaterializedBytes: 64,
                chunkByteCount: 5
            )
        )

        try await coordinator.play(
            notebookID: NotebookID(),
            sessionID: sessionID
        )
        do {
            try await coordinator.startReplayPlayback(
                notebookID: NotebookID(),
                sessionID: sessionID,
                from: 0,
                ownerID: UUID()
            )
            XCTFail("Replay must not replace standard playback")
        } catch let error as NotebookAudioCoordinatorError {
            XCTAssertEqual(error, .busy(.playing))
        }

        let snapshot = await coordinator.standardSnapshot()
        let stopCount = await player.stopCount()
        XCTAssertEqual(snapshot.activity, .playing)
        XCTAssertEqual(stopCount, 0)
        await coordinator.stopPlayback()
    }

    func testReplayPauseRacingNaturalFinishRetainsTerminalOutcome() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sessionID = AudioSessionID()
        let persistence = NotebookAudioPersistenceFake(
            storedAudio: Data(repeating: 6, count: 12),
            storedTimeline: NotesCore.AudioTimelineDocument(audioSessionID: sessionID)
        )
        let player = AudioPlayerFake()
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            player: player,
            workingDirectory: sandbox,
            configuration: NotebookAudioCoordinatorConfiguration(
                maximumRecordingBytes: 64,
                maximumMaterializedBytes: 64,
                chunkByteCount: 5
            )
        )
        let ownerID = UUID()

        try await coordinator.startReplayPlayback(
            notebookID: NotebookID(),
            sessionID: sessionID,
            from: 0,
            ownerID: ownerID
        )
        let receivedURL = await player.receivedURL()
        let playbackURL = try XCTUnwrap(receivedURL)
        await player.setState(AudioPlaybackState(
            status: .finished,
            fileURL: playbackURL,
            currentTime: 10,
            duration: 10
        ))

        try await coordinator.pauseReplayPlayback(ownerID: ownerID)
        let terminalState = await coordinator.replayPlaybackState(ownerID: ownerID)

        XCTAssertEqual(terminalState?.status, .finished)
        XCTAssertEqual(terminalState?.currentTime, 10)
    }

    func testInvalidPlaybackTimeIsRejectedBeforeAudioLoading() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let persistence = NotebookAudioPersistenceFake()
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            workingDirectory: sandbox
        )

        do {
            try await coordinator.play(
                notebookID: NotebookID(),
                sessionID: AudioSessionID(),
                from: .nan
            )
            XCTFail("Non-finite playback time must be rejected")
        } catch let error as NotebookAudioCoordinatorError {
            XCTAssertEqual(error, .invalidPlaybackTime)
        }
        let descriptorCallCount = await persistence.descriptorCallCount()
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(descriptorCallCount, 0)
        XCTAssertEqual(snapshot, .idle)
    }

    func testPlaybackStartIsClampedToDescriptorDuration() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sessionID = AudioSessionID()
        let persistence = NotebookAudioPersistenceFake(
            storedAudio: Data(repeating: 4, count: 12),
            storedTimeline: NotesCore.AudioTimelineDocument(audioSessionID: sessionID)
        )
        let player = AudioPlayerFake()
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            player: player,
            workingDirectory: sandbox,
            configuration: NotebookAudioCoordinatorConfiguration(
                maximumRecordingBytes: 64,
                maximumMaterializedBytes: 64,
                chunkByteCount: 4
            )
        )

        try await coordinator.play(
            notebookID: NotebookID(),
            sessionID: sessionID,
            from: 999
        )
        let playbackState = await player.currentState()
        XCTAssertEqual(playbackState.currentTime, 10)
        await coordinator.stopPlayback()
    }

    func testConfigurationCannotRaiseHardMemoryCaps() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let coordinator = NotebookAudioCoordinator(
            persistence: NotebookAudioPersistenceFake(),
            recorder: AudioRecordingFake(),
            workingDirectory: sandbox,
            configuration: NotebookAudioCoordinatorConfiguration(
                maximumRecordingBytes: NotebookAudioCoordinatorConfiguration.defaultMaximumRecordingBytes + 1,
                maximumMaterializedBytes: NotebookAudioCoordinatorConfiguration.defaultMaximumMaterializedBytes,
                chunkByteCount: NotebookAudioCoordinatorConfiguration.defaultChunkBytes
            )
        )

        do {
            _ = try await coordinator.startRecording(notebookID: NotebookID())
            XCTFail("The 64 MiB ingest cap must be a hard ceiling")
        } catch let error as NotebookAudioCoordinatorError {
            XCTAssertEqual(error, .invalidConfiguration)
        }
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(snapshot, .idle)
    }

    func testMaterializationCapRejectsBeforeRequestingAnyChunk() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sessionID = AudioSessionID()
        let persistence = NotebookAudioPersistenceFake(
            storedAudio: Data(repeating: 1, count: 33),
            storedTimeline: NotesCore.AudioTimelineDocument(audioSessionID: sessionID)
        )
        let transcriber = SpeechTranscriberFake()
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            transcriber: transcriber,
            workingDirectory: sandbox,
            configuration: NotebookAudioCoordinatorConfiguration(
                maximumRecordingBytes: 32,
                maximumMaterializedBytes: 32,
                chunkByteCount: 8
            )
        )

        do {
            _ = try await coordinator.transcribe(
                notebookID: NotebookID(),
                sessionID: sessionID
            )
            XCTFail("Expected materialization cap rejection")
        } catch let error as NotebookAudioCoordinatorError {
            XCTAssertEqual(error, .materializationTooLarge(maximumBytes: 32))
        }
        let chunkRequests = await persistence.chunkRequests()
        let receivedURL = await transcriber.receivedURL()
        let snapshot = await coordinator.snapshot()
        XCTAssertEqual(chunkRequests, [])
        XCTAssertNil(receivedURL)
        XCTAssertEqual(snapshot, .idle)
    }

    func testSeekUpdatesCoordinatorPlaybackClock() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let sessionID = AudioSessionID()
        let persistence = NotebookAudioPersistenceFake(
            storedAudio: Data(repeating: 6, count: 24),
            storedTimeline: NotesCore.AudioTimelineDocument(audioSessionID: sessionID)
        )
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            player: AudioPlayerFake(),
            workingDirectory: sandbox,
            configuration: NotebookAudioCoordinatorConfiguration(
                maximumRecordingBytes: 64,
                maximumMaterializedBytes: 64,
                chunkByteCount: 5
            )
        )

        try await coordinator.play(
            notebookID: NotebookID(),
            sessionID: sessionID
        )
        try await coordinator.seekPlayback(to: 30)

        let playback = await coordinator.playbackState()
        XCTAssertEqual(playback.status, .playing)
        XCTAssertEqual(playback.currentTime, 10)
        await coordinator.stopPlayback()
    }

    @MainActor
    func testPanelModelQueuesPageMarksAndReloadsDurableSessions() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let persistence = NotebookAudioPersistenceFake()
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            recorder: AudioRecordingFake(markTimes: [0, 1, 2]),
            workingDirectory: sandbox
        )
        let model = NotebookAudioPanelModel(
            coordinator: coordinator,
            sessionListing: persistence
        )
        let notebookID = NotebookID()
        let firstPageID = PageID()
        let secondPageID = PageID()
        let thirdPageID = PageID()

        await model.open(notebookID: notebookID.rawValue)
        await model.startRecording(
            notebookID: notebookID.rawValue,
            pageID: firstPageID.rawValue
        )
        model.enqueuePageMark(
            notebookID: notebookID.rawValue,
            pageID: secondPageID.rawValue
        )
        model.enqueuePageMark(
            notebookID: notebookID.rawValue,
            pageID: thirdPageID.rawValue
        )
        await model.stopRecording(currentPageID: thirdPageID.rawValue)

        let persistedInput = await persistence.lastPersistedInput()
        let persisted = try XCTUnwrap(persistedInput)
        XCTAssertEqual(
            persisted.timeline.marks.map(\.pageID),
            [firstPageID, secondPageID, thirdPageID]
        )
        XCTAssertEqual(Set(persisted.timeline.marks.map(\.operationID)).count, 3)
        XCTAssertEqual(model.sessions.count, 1)

        let relaunchedModel = NotebookAudioPanelModel(
            coordinator: NotebookAudioCoordinator(
                persistence: persistence,
                workingDirectory: sandbox
            ),
            sessionListing: persistence
        )
        await relaunchedModel.open(notebookID: notebookID.rawValue)
        XCTAssertEqual(relaunchedModel.sessions.map(\.id), model.sessions.map(\.id))
    }

    @MainActor
    func testPanelModelReloadsSavedTranscriptAfterRelaunch() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let persistence = NotebookAudioPersistenceFake()
        let notebookID = NotebookID()
        let pageID = PageID()
        let coordinator = NotebookAudioCoordinator(
            persistence: persistence,
            recorder: AudioRecordingFake(markTimes: [0]),
            transcriber: SpeechTranscriberFake(segments: [
                TranscriptSegment(text: "Persistent", startTime: 0, duration: 0.1, confidence: 1),
            ]),
            workingDirectory: sandbox
        )
        let model = NotebookAudioPanelModel(coordinator: coordinator, sessionListing: persistence)
        await model.open(notebookID: notebookID.rawValue)
        await model.startRecording(notebookID: notebookID.rawValue, pageID: pageID.rawValue)
        await model.stopRecording(currentPageID: pageID.rawValue)
        let sessionID = try XCTUnwrap(model.sessions.first?.id)
        await model.transcribe(sessionID: sessionID)
        let saved = try XCTUnwrap(model.transcript)
        XCTAssertNotNil(model.sessions.first?.transcriptAssetID)

        let relaunched = NotebookAudioPanelModel(
            coordinator: NotebookAudioCoordinator(
                persistence: persistence,
                workingDirectory: sandbox
            ),
            sessionListing: persistence
        )
        await relaunched.open(notebookID: notebookID.rawValue)
        XCTAssertEqual(relaunched.transcript, saved)
        XCTAssertEqual(relaunched.transcript?.audioSessionID, sessionID)
    }

    @MainActor
    func testPanelModelKeepsDurableTranscriptSuccessWhenDerivedSearchIndexFails() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let persistence = NotebookAudioPersistenceFake()
        let notebookID = NotebookID()
        let pageID = PageID()
        let model = NotebookAudioPanelModel(
            coordinator: NotebookAudioCoordinator(
                persistence: persistence,
                recorder: AudioRecordingFake(markTimes: [0]),
                transcriber: SpeechTranscriberFake(segments: [
                    TranscriptSegment(
                        text: "Durable despite derived failure",
                        startTime: 0,
                        duration: 0.1,
                        confidence: 1
                    ),
                ]),
                workingDirectory: sandbox
            ),
            sessionListing: persistence,
            transcriptSearchIndexer: FailingTranscriptSearchIndexer()
        )
        await model.open(notebookID: notebookID.rawValue)
        await model.startRecording(notebookID: notebookID.rawValue, pageID: pageID.rawValue)
        await model.stopRecording(currentPageID: pageID.rawValue)
        let sessionID = try XCTUnwrap(model.sessions.first?.id)

        await model.transcribe(sessionID: sessionID)

        XCTAssertEqual(model.transcript?.audioSessionID, sessionID)
        XCTAssertNotNil(model.sessions.first?.transcriptAssetID)
        XCTAssertEqual(
            model.failureMessage,
            String(localized: "The transcript is saved, but local search could not be updated.")
        )
        XCTAssertTrue(model.canRetry)
    }

    @MainActor
    func testPanelModelIndexesSavedTranscriptWhenPostSaveSessionReloadFails() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let persistence = NotebookAudioPersistenceFake()
        let listing = FailingNthAudioSessionListing(base: persistence, failingRequest: 3)
        let searchIndexer = RecordingTranscriptSearchIndexer()
        let notebookID = NotebookID()
        let pageID = PageID()
        let model = NotebookAudioPanelModel(
            coordinator: NotebookAudioCoordinator(
                persistence: persistence,
                recorder: AudioRecordingFake(markTimes: [0]),
                transcriber: SpeechTranscriberFake(segments: [
                    TranscriptSegment(
                        text: "Indexed from the durable save receipt",
                        startTime: 0,
                        duration: 0.1,
                        confidence: 1
                    ),
                ]),
                workingDirectory: sandbox
            ),
            sessionListing: listing,
            transcriptSearchIndexer: searchIndexer
        )
        await model.open(notebookID: notebookID.rawValue)
        await model.startRecording(notebookID: notebookID.rawValue, pageID: pageID.rawValue)
        await model.stopRecording(currentPageID: pageID.rawValue)
        let sessionID = try XCTUnwrap(model.sessions.first?.id)

        await model.transcribe(sessionID: sessionID)

        let indexed = await searchIndexer.indexedTranscripts()
        XCTAssertEqual(indexed.count, 1)
        XCTAssertEqual(indexed.first?.notebookID, notebookID)
        XCTAssertEqual(indexed.first?.sessionID, sessionID)
        XCTAssertEqual(
            indexed.first?.transcriptAssetID,
            AssetID(String(repeating: "a", count: 64))
        )
        XCTAssertEqual(model.transcript?.audioSessionID, sessionID)
        XCTAssertNil(
            model.sessions.first?.transcriptAssetID,
            "The failed reload intentionally leaves the pre-save UI descriptor in place."
        )
        XCTAssertEqual(
            model.failureMessage,
            String(localized: "Audio recordings could not be loaded.")
        )
        XCTAssertTrue(model.canRetry)

        await model.retry()

        XCTAssertNotNil(model.sessions.first?.transcriptAssetID)
        XCTAssertNil(model.failureMessage)
        XCTAssertFalse(model.canRetry)
    }

    @MainActor
    func testPanelModelCapturesPageChangeWhileRecordingStarts() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let persistence = NotebookAudioPersistenceFake()
        let recorder = AudioRecordingFake(
            markTimes: [0, 0.1],
            addMarkBehavior: .suspendIgnoringCancellation
        )
        let model = NotebookAudioPanelModel(
            coordinator: NotebookAudioCoordinator(
                persistence: persistence,
                recorder: recorder,
                workingDirectory: sandbox
            ),
            sessionListing: persistence
        )
        let notebookID = NotebookID()
        let firstPageID = PageID()
        let secondPageID = PageID()
        await model.open(notebookID: notebookID.rawValue)

        let startTask = Task { @MainActor in
            await model.startRecording(
                notebookID: notebookID.rawValue,
                pageID: firstPageID.rawValue
            )
        }
        await recorder.waitUntilMarkEntered()
        model.enqueuePageMark(
            notebookID: notebookID.rawValue,
            pageID: secondPageID.rawValue
        )
        await recorder.resumeMark()
        await startTask.value
        await model.stopRecording(currentPageID: secondPageID.rawValue)

        let persistedInput = await persistence.lastPersistedInput()
        let persisted = try XCTUnwrap(persistedInput)
        XCTAssertEqual(persisted.timeline.marks.map(\.pageID), [firstPageID, secondPageID])
    }

    @MainActor
    func testPanelModelSurfacesPersistenceFailureWithoutListingPhantomSession() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let persistence = NotebookAudioPersistenceFake(persistBehavior: .fail)
        let model = NotebookAudioPanelModel(
            coordinator: NotebookAudioCoordinator(
                persistence: persistence,
                recorder: AudioRecordingFake(markTimes: [0]),
                workingDirectory: sandbox
            ),
            sessionListing: persistence
        )
        let notebookID = NotebookID()
        let pageID = PageID()

        await model.open(notebookID: notebookID.rawValue)
        await model.startRecording(
            notebookID: notebookID.rawValue,
            pageID: pageID.rawValue
        )
        await model.stopRecording(currentPageID: pageID.rawValue)

        XCTAssertEqual(model.snapshot, .idle)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertNotNil(model.failureMessage)
        XCTAssertFalse(model.canRetry)
    }

    @MainActor
    func testPanelModelDoesNotLetStaleNotebookListReplaceNewerNotebook() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let firstNotebookID = NotebookID()
        let secondNotebookID = NotebookID()
        let firstSession = AudioSessionDescriptor(id: AudioSessionID(), durationSeconds: 1)
        let secondSession = AudioSessionDescriptor(id: AudioSessionID(), durationSeconds: 2)
        let listing = ControlledAudioSessionListing(
            firstNotebookID: firstNotebookID,
            firstResult: [firstSession],
            otherResult: [secondSession]
        )
        let persistence = NotebookAudioPersistenceFake()
        let model = NotebookAudioPanelModel(
            coordinator: NotebookAudioCoordinator(
                persistence: persistence,
                workingDirectory: sandbox
            ),
            sessionListing: listing
        )

        let firstOpen = Task { @MainActor in
            await model.open(notebookID: firstNotebookID.rawValue)
        }
        await listing.waitUntilFirstLoadEntered()
        await model.open(notebookID: secondNotebookID.rawValue)
        await listing.resumeFirstLoad()
        await firstOpen.value

        XCTAssertEqual(model.sessions.map(\.id), [secondSession.id])
        XCTAssertFalse(model.isLoadingSessions)
    }

    @MainActor
    func testPanelModelSerializesTwoConcurrentTranscriptSearchOperations() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let persistence = NotebookAudioPersistenceFake()
        let listing = CountingAudioSessionListing()
        let searchIndexer = ControlledTranscriptSearchIndexer(suspensionMode: .everyCall)
        let model = NotebookAudioPanelModel(
            coordinator: NotebookAudioCoordinator(
                persistence: persistence,
                workingDirectory: sandbox
            ),
            sessionListing: listing,
            transcriptSearchIndexer: searchIndexer
        )
        let notebookID = NotebookID()

        let first = Task { @MainActor in
            await model.open(notebookID: notebookID.rawValue)
        }
        await searchIndexer.waitUntilCallCount(1)
        let second = Task { @MainActor in
            await model.loadSessions(notebookID: notebookID)
        }
        await listing.waitUntilRequestCount(2)
        for _ in 0..<50 { await Task.yield() }

        let countWhileFirstIsSuspended = await searchIndexer.callCount()
        let cancellationCountWhileFirstIsSuspended = await searchIndexer.cancellationCount()
        XCTAssertEqual(countWhileFirstIsSuspended, 1)
        XCTAssertEqual(
            cancellationCountWhileFirstIsSuspended,
            0,
            "A same-notebook search mutation should queue without cancelling the active mutation."
        )

        await searchIndexer.resume(call: 0)
        await searchIndexer.waitUntilCallCount(2)
        await searchIndexer.resume(call: 1)
        await first.value
        await second.value

        let maximumActiveCallCount = await searchIndexer.maximumActiveCallCount()
        let cancellationCount = await searchIndexer.cancellationCount()
        XCTAssertEqual(maximumActiveCallCount, 1)
        XCTAssertEqual(cancellationCount, 0)
    }

    @MainActor
    func testTranscriptSearchOperationQueuePreservesThreeTicketArrivalOrder() async throws {
        let queue = NotebookAudioSearchIndexOperationQueue()
        let probe = SearchIndexFIFOProbe()

        let first = try queue.enqueue {
            try await probe.perform(1)
        }
        let second = try queue.enqueue {
            try await probe.perform(2)
        }
        let third = try queue.enqueue {
            try await probe.perform(3)
        }

        await probe.waitUntilStartedCount(1)
        let firstStartedValues = await probe.startedValues()
        XCTAssertEqual(firstStartedValues, [1])

        await probe.resume(call: 0)
        await probe.waitUntilStartedCount(2)
        let secondStartedValues = await probe.startedValues()
        XCTAssertEqual(secondStartedValues, [1, 2])

        await probe.resume(call: 1)
        await probe.waitUntilStartedCount(3)
        let thirdStartedValues = await probe.startedValues()
        XCTAssertEqual(thirdStartedValues, [1, 2, 3])

        await probe.resume(call: 2)
        try await first.wait()
        try await second.wait()
        try await third.wait()
        await queue.waitUntilIdle()
        XCTAssertFalse(queue.hasOperations)
    }

    @MainActor
    func testTranscriptSearchOperationQueueCancelsActiveAndAllPendingTickets() async throws {
        let queue = NotebookAudioSearchIndexOperationQueue()
        let probe = SearchIndexFIFOProbe()
        let handles = try [1, 2, 3].map { value in
            try queue.enqueue {
                try await probe.perform(value)
            }
        }

        await probe.waitUntilStartedCount(1)
        let cancellation = Task { @MainActor in
            await queue.cancelAll()
        }
        await probe.waitUntilCancellationCount(1)
        await probe.resume(call: 0)
        await cancellation.value

        for handle in handles {
            do {
                try await handle.wait()
                XCTFail("Every active or pending search-index ticket must be cancelled.")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
        }
        let startedValues = await probe.startedValues()
        XCTAssertEqual(startedValues, [1])
        await queue.waitUntilIdle()
        XCTAssertFalse(queue.hasOperations)
    }

    @MainActor
    func testPanelModelRootSwitchInvalidatesQueuedOldNotebookSearchMutation() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let persistence = NotebookAudioPersistenceFake()
        let listing = CountingAudioSessionListing()
        let searchIndexer = ControlledTranscriptSearchIndexer(suspensionMode: .firstCallOnly)
        let model = NotebookAudioPanelModel(
            coordinator: NotebookAudioCoordinator(
                persistence: persistence,
                workingDirectory: sandbox
            ),
            sessionListing: listing,
            transcriptSearchIndexer: searchIndexer
        )
        let oldNotebookID = NotebookID()
        let newNotebookID = NotebookID()

        let firstOpen = Task { @MainActor in
            await model.open(notebookID: oldNotebookID.rawValue)
        }
        await searchIndexer.waitUntilCallCount(1)
        let queuedOldLoad = Task { @MainActor in
            await model.loadSessions(notebookID: oldNotebookID)
        }
        await listing.waitUntilRequestCount(2)
        for _ in 0..<50 { await Task.yield() }

        let rootSwitch = Task { @MainActor in
            await model.open(notebookID: newNotebookID.rawValue)
        }
        await searchIndexer.waitUntilCancellationCount(1)
        let duringCancellationOldLoad = Task { @MainActor in
            await model.loadSessions(notebookID: oldNotebookID)
        }
        await listing.waitUntilRequestCount(3)
        await searchIndexer.resume(call: 0)
        await rootSwitch.value
        await queuedOldLoad.value
        await duringCancellationOldLoad.value
        await firstOpen.value

        let calls = await searchIndexer.calledNotebookIDs()
        XCTAssertEqual(calls, [oldNotebookID, newNotebookID])
        XCTAssertEqual(
            calls.filter { $0 == oldNotebookID }.count,
            1,
            "A queued operation from the old notebook must not write after a root switch."
        )
    }

    @MainActor
    func testPanelModelSuspendsSearchAcrossLibraryRootChange() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let persistence = NotebookAudioPersistenceFake()
        let listing = CountingAudioSessionListing()
        let searchIndexer = ControlledTranscriptSearchIndexer(suspensionMode: .firstCallOnly)
        let model = NotebookAudioPanelModel(
            coordinator: NotebookAudioCoordinator(
                persistence: persistence,
                workingDirectory: sandbox
            ),
            sessionListing: listing,
            transcriptSearchIndexer: searchIndexer
        )
        let oldNotebookID = NotebookID()
        let newNotebookID = NotebookID()
        let rootChangeToken = UUID()

        let firstOpen = Task { @MainActor in
            await model.open(notebookID: oldNotebookID.rawValue)
        }
        await searchIndexer.waitUntilCallCount(1)
        let preparation = Task { @MainActor in
            await model.prepareForLibraryRootChange(token: rootChangeToken)
        }
        await searchIndexer.waitUntilCancellationCount(1)

        await model.open(notebookID: oldNotebookID.rawValue)
        await model.loadSessions(notebookID: oldNotebookID)
        await listing.waitUntilRequestCount(2)
        await searchIndexer.resume(call: 0)
        let didPrepare = await preparation.value
        XCTAssertTrue(didPrepare)
        await firstOpen.value

        await model.open(notebookID: newNotebookID.rawValue)
        let callsWhileSuspended = await searchIndexer.calledNotebookIDs()
        XCTAssertEqual(callsWhileSuspended, [oldNotebookID])

        model.finishLibraryRootChange(token: rootChangeToken)
        await model.open(notebookID: newNotebookID.rawValue)
        let callsAfterResuming = await searchIndexer.calledNotebookIDs()
        XCTAssertEqual(callsAfterResuming, [oldNotebookID, newNotebookID])
        XCTAssertFalse(model.isLoadingSessions)
    }

    @MainActor
    func testTimedOutAudioPreparationKeepsGateUntilStaleCancellationSettles() async throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let persistence = NotebookAudioPersistenceFake()
        let listing = CountingAudioSessionListing()
        let searchIndexer = ControlledTranscriptSearchIndexer(suspensionMode: .firstCallOnly)
        let model = NotebookAudioPanelModel(
            coordinator: NotebookAudioCoordinator(
                persistence: persistence,
                workingDirectory: sandbox
            ),
            sessionListing: listing,
            transcriptSearchIndexer: searchIndexer
        )
        let oldNotebookID = NotebookID()
        let newNotebookID = NotebookID()
        let staleToken = UUID()
        let retryToken = UUID()

        let firstOpen = Task { @MainActor in
            await model.open(notebookID: oldNotebookID.rawValue)
        }
        await searchIndexer.waitUntilCallCount(1)
        let stalePreparation = Task { @MainActor in
            await model.prepareForLibraryRootChange(token: staleToken)
        }
        await searchIndexer.waitUntilCancellationCount(1)

        model.finishLibraryRootChange(token: staleToken)
        let retryPrepared = await model.prepareForLibraryRootChange(token: retryToken)
        XCTAssertFalse(retryPrepared)
        model.finishLibraryRootChange(token: retryToken)
        await model.open(notebookID: newNotebookID.rawValue)
        let callsWhileStalePreparationWasPending = await searchIndexer.calledNotebookIDs()
        XCTAssertEqual(callsWhileStalePreparationWasPending, [oldNotebookID])

        await searchIndexer.resume(call: 0)
        _ = await stalePreparation.value
        await firstOpen.value
        await model.open(notebookID: newNotebookID.rawValue)
        let callsAfterStalePreparationSettled = await searchIndexer.calledNotebookIDs()
        XCTAssertEqual(
            callsAfterStalePreparationSettled,
            [oldNotebookID, newNotebookID]
        )
    }

    private func makeSandbox() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Notes-AudioCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

}

private enum AudioPersistenceFakeError: Error, Equatable, Sendable {
    case persistFailed
    case missingStoredAudio
    case listingFailed
}

private actor FailingNthAudioSessionListing: NotebookAudioSessionListing {
    private let base: any NotebookAudioSessionListing
    private let failingRequest: Int
    private var requestCount = 0

    init(base: any NotebookAudioSessionListing, failingRequest: Int) {
        self.base = base
        self.failingRequest = failingRequest
    }

    func listAudioSessions(notebookID: NotebookID) async throws -> [AudioSessionDescriptor] {
        requestCount += 1
        if requestCount == failingRequest {
            throw AudioPersistenceFakeError.listingFailed
        }
        return try await base.listAudioSessions(notebookID: notebookID)
    }
}

private actor ControlledAudioSessionListing: NotebookAudioSessionListing {
    private let firstNotebookID: NotebookID
    private let firstResult: [AudioSessionDescriptor]
    private let otherResult: [AudioSessionDescriptor]
    private var firstLoadEntered = false
    private var firstLoadContinuation: CheckedContinuation<Void, Never>?
    private var firstLoadEntryWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        firstNotebookID: NotebookID,
        firstResult: [AudioSessionDescriptor],
        otherResult: [AudioSessionDescriptor]
    ) {
        self.firstNotebookID = firstNotebookID
        self.firstResult = firstResult
        self.otherResult = otherResult
    }

    func listAudioSessions(notebookID: NotebookID) async throws -> [AudioSessionDescriptor] {
        guard notebookID == firstNotebookID else { return otherResult }
        firstLoadEntered = true
        let waiters = firstLoadEntryWaiters
        firstLoadEntryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            firstLoadContinuation = continuation
        }
        return firstResult
    }

    func waitUntilFirstLoadEntered() async {
        if firstLoadEntered { return }
        await withCheckedContinuation { continuation in
            firstLoadEntryWaiters.append(continuation)
        }
    }

    func resumeFirstLoad() {
        let continuation = firstLoadContinuation
        firstLoadContinuation = nil
        continuation?.resume()
    }
}

private struct PersistedAudioInput: Sendable {
    var fileURL: URL
    var maximumByteCount: Int64
    var timeline: NotesCore.AudioTimelineDocument
    var notebookID: NotebookID
    var durationSeconds: Double
    var recordingStartedAt: Date
    var transcriptAssetID: AssetID?
}

private actor NotebookAudioRollbackInvocationCounter {
    private var count = 0

    func recordInvocation() {
        count += 1
    }

    func invocationCount() -> Int {
        count
    }
}

private actor NotebookAudioPersistenceFake: NotebookAudioPersisting, NotebookAudioSessionListing {
    enum PersistBehavior: Sendable {
        case immediate
        case fail
        case suspendIgnoringCancellation
    }

    enum TranscriptSaveBehavior: Equatable, Sendable {
        case immediate
        case suspendIgnoringCancellation
    }

    private let persistBehavior: PersistBehavior
    private let persistedDescriptorID: AudioSessionID?
    private let deleteFails: Bool
    private let descriptorDigestOverride: String?
    private let descriptorRecordingStartOffset: TimeInterval
    private let transcriptSaveBehavior: TranscriptSaveBehavior
    private var storedAudio: Data?
    private var storedTimeline: NotesCore.AudioTimelineDocument?
    private var storedTranscript: NotebookAudioTranscriptPayload?
    private var persistedInput: PersistedAudioInput?
    private var persistedReplayHistory: NoteReplayCaptureBundle?
    private var persistCalls = 0
    private var replayPersistCalls = 0
    private var descriptorCalls = 0
    private var chunkRequestSizes: [Int] = []
    private var deletedIDs: [AudioSessionID] = []
    private var repositoryGeneration = 0
    private var rollbackRepositoryGenerations: [Int] = []
    private var enteredPersist = false
    private var persistContinuation: CheckedContinuation<Void, Never>?
    private var persistEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var transcriptSaveEntered = false
    private var transcriptSaveContinuation: CheckedContinuation<Void, Never>?
    private var transcriptSaveEntryWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        persistBehavior: PersistBehavior = .immediate,
        storedAudio: Data? = nil,
        storedTimeline: NotesCore.AudioTimelineDocument? = nil,
        persistedDescriptorID: AudioSessionID? = nil,
        deleteFails: Bool = false,
        descriptorDigestOverride: String? = nil,
        descriptorRecordingStartOffset: TimeInterval = 0,
        transcriptSaveBehavior: TranscriptSaveBehavior = .immediate
    ) {
        self.persistBehavior = persistBehavior
        self.storedAudio = storedAudio
        self.storedTimeline = storedTimeline
        self.persistedDescriptorID = persistedDescriptorID
        self.deleteFails = deleteFails
        self.descriptorDigestOverride = descriptorDigestOverride
        self.descriptorRecordingStartOffset = descriptorRecordingStartOffset
        self.transcriptSaveBehavior = transcriptSaveBehavior
    }

    func persistRecordedM4A(
        at fileURL: URL,
        maximumByteCount: Int64,
        timeline: NotesCore.AudioTimelineDocument,
        notebookID: NotebookID,
        durationSeconds: Double,
        recordingStartedAt: Date,
        transcriptAssetID: AssetID?
    ) async throws -> NotebookAudioPersistenceReceipt {
        let capturedRepositoryGeneration = repositoryGeneration
        persistCalls += 1
        persistedReplayHistory = nil
        enteredPersist = true
        let entryWaiters = persistEntryWaiters
        persistEntryWaiters.removeAll()
        entryWaiters.forEach { $0.resume() }
        persistedInput = PersistedAudioInput(
            fileURL: fileURL,
            maximumByteCount: maximumByteCount,
            timeline: timeline,
            notebookID: notebookID,
            durationSeconds: durationSeconds,
            recordingStartedAt: recordingStartedAt,
            transcriptAssetID: transcriptAssetID
        )
        storedAudio = try Data(contentsOf: fileURL)
        storedTimeline = timeline
        switch persistBehavior {
        case .immediate:
            break
        case .fail:
            throw AudioPersistenceFakeError.persistFailed
        case .suspendIgnoringCancellation:
            await withCheckedContinuation { continuation in
                persistContinuation = continuation
            }
        }
        let descriptor = makeDescriptor(
            sessionID: persistedDescriptorID ?? timeline.audioSessionID,
            byteCount: Int64(storedAudio?.count ?? 0),
            duration: durationSeconds,
            recordingStartedAt: recordingStartedAt
        )
        return NotebookAudioPersistenceReceipt(descriptor: descriptor) { [weak self] in
            guard let self else { return }
            try await self.deleteSession(
                notebookID: notebookID,
                sessionID: timeline.audioSessionID,
                repositoryGeneration: capturedRepositoryGeneration
            )
        }
    }

    func persistRecordedM4A(
        at fileURL: URL,
        maximumByteCount: Int64,
        timeline: NotesCore.AudioTimelineDocument,
        replayHistory: NoteReplayCaptureBundle,
        notebookID: NotebookID,
        durationSeconds: Double,
        recordingStartedAt: Date,
        transcriptAssetID: AssetID?
    ) async throws -> NotebookAudioPersistenceReceipt {
        replayPersistCalls += 1
        let receipt = try await persistRecordedM4A(
            at: fileURL,
            maximumByteCount: maximumByteCount,
            timeline: timeline,
            notebookID: notebookID,
            durationSeconds: durationSeconds,
            recordingStartedAt: recordingStartedAt,
            transcriptAssetID: transcriptAssetID
        )
        persistedReplayHistory = replayHistory
        return receipt
    }

    func descriptor(
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> AudioSessionDescriptor {
        descriptorCalls += 1
        guard let storedAudio else { throw AudioPersistenceFakeError.missingStoredAudio }
        return makeDescriptor(
            sessionID: sessionID,
            byteCount: Int64(storedAudio.count),
            duration: 10,
            recordingStartedAt: persistedInput?.recordingStartedAt,
            transcriptAssetID: storedTranscript.map { _ in
                AssetID(String(repeating: "a", count: 64))
            }
        )
    }

    func loadAudioChunk(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        offset: Int64,
        maximumByteCount: Int
    ) async throws -> Data {
        guard let storedAudio else { throw AudioPersistenceFakeError.missingStoredAudio }
        chunkRequestSizes.append(maximumByteCount)
        guard offset >= 0, offset < Int64(storedAudio.count) else { return Data() }
        let lowerBound = Int(offset)
        let upperBound = min(storedAudio.count, lowerBound + maximumByteCount)
        return storedAudio.subdata(in: lowerBound ..< upperBound)
    }

    func loadTimeline(
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> NotesCore.AudioTimelineDocument {
        guard let storedTimeline else { throw AudioPersistenceFakeError.missingStoredAudio }
        return storedTimeline
    }

    func saveTranscript(
        _ transcript: NotebookAudioTranscriptPayload,
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> AudioSessionDescriptor {
        guard transcript.audioSessionID == sessionID else {
            throw AudioPersistenceFakeError.persistFailed
        }
        transcriptSaveEntered = true
        let waiters = transcriptSaveEntryWaiters
        transcriptSaveEntryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if transcriptSaveBehavior == .suspendIgnoringCancellation {
            await withCheckedContinuation { continuation in
                transcriptSaveContinuation = continuation
            }
        }
        storedTranscript = transcript
        guard let storedAudio else { throw AudioPersistenceFakeError.missingStoredAudio }
        return makeDescriptor(
            sessionID: sessionID,
            byteCount: Int64(storedAudio.count),
            duration: 10,
            recordingStartedAt: persistedInput?.recordingStartedAt,
            transcriptAssetID: AssetID(String(repeating: "a", count: 64))
        )
    }

    func loadTranscript(
        notebookID: NotebookID,
        sessionID: AudioSessionID
    ) async throws -> NotebookAudioTranscriptPayload? {
        guard storedTranscript?.audioSessionID == sessionID else { return nil }
        return storedTranscript
    }

    func waitUntilTranscriptSaveEntered() async {
        if transcriptSaveEntered { return }
        await withCheckedContinuation { continuation in
            transcriptSaveEntryWaiters.append(continuation)
        }
    }

    func resumeTranscriptSave() {
        let continuation = transcriptSaveContinuation
        transcriptSaveContinuation = nil
        continuation?.resume()
    }

    func savedTranscript() -> NotebookAudioTranscriptPayload? { storedTranscript }

    private func deleteSession(
        notebookID: NotebookID,
        sessionID: AudioSessionID,
        repositoryGeneration: Int
    ) async throws {
        if deleteFails { throw AudioPersistenceFakeError.persistFailed }
        deletedIDs.append(sessionID)
        rollbackRepositoryGenerations.append(repositoryGeneration)
    }

    func listAudioSessions(notebookID: NotebookID) async throws -> [AudioSessionDescriptor] {
        guard let persistedInput,
              persistedInput.notebookID == notebookID,
              let storedAudio else { return [] }
        return [makeDescriptor(
            sessionID: persistedInput.timeline.audioSessionID,
            byteCount: Int64(storedAudio.count),
            duration: persistedInput.durationSeconds,
            recordingStartedAt: persistedInput.recordingStartedAt,
            transcriptAssetID: storedTranscript.map { _ in
                AssetID(String(repeating: "a", count: 64))
            }
        )]
    }

    func resumePersistence() {
        let continuation = persistContinuation
        persistContinuation = nil
        continuation?.resume()
    }

    func waitUntilPersistEntered() async {
        if enteredPersist { return }
        await withCheckedContinuation { continuation in
            persistEntryWaiters.append(continuation)
        }
    }
    func lastPersistedInput() -> PersistedAudioInput? { persistedInput }
    func lastPersistedReplayHistory() -> NoteReplayCaptureBundle? { persistedReplayHistory }
    func persistCallCount() -> Int { persistCalls }
    func replayPersistCallCount() -> Int { replayPersistCalls }
    func descriptorCallCount() -> Int { descriptorCalls }
    func chunkRequests() -> [Int] { chunkRequestSizes }
    func deletedSessionIDs() -> [AudioSessionID] { deletedIDs }
    func simulateRootChange() { repositoryGeneration += 1 }
    func deletedRepositoryGenerations() -> [Int] { rollbackRepositoryGenerations }

    private func makeDescriptor(
        sessionID: AudioSessionID,
        byteCount: Int64,
        duration: Double,
        recordingStartedAt: Date? = nil,
        transcriptAssetID: AssetID? = nil
    ) -> AudioSessionDescriptor {
        AudioSessionDescriptor(
            id: sessionID,
            recordingStartedAt: recordingStartedAt?.addingTimeInterval(
                descriptorRecordingStartOffset
            ),
            durationSeconds: duration,
            chunkFilenames: ["\(sessionID.description).m4a"],
            audioByteCount: byteCount,
            audioSHA256: descriptorDigestOverride ?? sha256Hex(storedAudio ?? Data()),
            timelineFilename: "\(sessionID.description).timeline.json",
            transcriptAssetID: transcriptAssetID
        )
    }

    private func sha256Hex(_ data: Data) -> String {
        CryptoKit.SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private actor AudioRecordingFake: AudioTimelineRecording {
    enum AddMarkBehavior: Sendable {
        case immediate
        case suspendIgnoringCancellation
    }

    private let bytes: Data
    private let resultDuration: TimeInterval
    private let markTimes: [TimeInterval]
    private let recordingTimes: [TimeInterval]
    private let resultURLOverride: URL?
    private let replaceResultWithSymbolicLinkTo: URL?
    private let addMarkBehavior: AddMarkBehavior
    private var activeID: UUID?
    private var destinationURL: URL?
    private var retainedStartedURL: URL?
    private var marks: [NotesServices.AudioTimelineMark] = []
    private var recordingTimeCalls = 0
    private var cancellationCount = 0
    private var markEntered = false
    private var markContinuation: CheckedContinuation<Void, Never>?
    private var markEntryWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        bytes: Data = Data(repeating: 1, count: 24),
        duration: TimeInterval = 4,
        markTimes: [TimeInterval] = [],
        recordingTimes: [TimeInterval] = [0],
        resultURLOverride: URL? = nil,
        replaceResultWithSymbolicLinkTo: URL? = nil,
        addMarkBehavior: AddMarkBehavior = .immediate
    ) {
        self.bytes = bytes
        self.resultDuration = duration
        self.markTimes = markTimes
        self.recordingTimes = recordingTimes
        self.resultURLOverride = resultURLOverride
        self.replaceResultWithSymbolicLinkTo = replaceResultWithSymbolicLinkTo
        self.addMarkBehavior = addMarkBehavior
    }

    func requestPermission() async -> Bool { true }

    func startRecording(to fileURL: URL) async throws -> UUID {
        try bytes.write(to: fileURL, options: .atomic)
        let id = UUID()
        activeID = id
        destinationURL = fileURL
        retainedStartedURL = fileURL
        marks = []
        recordingTimeCalls = 0
        return id
    }

    func addMark(commandID: UUID, pageID: UUID) async throws {
        guard activeID != nil else { throw AudioTimelineError.notRecording }
        markEntered = true
        let waiters = markEntryWaiters
        markEntryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if case .suspendIgnoringCancellation = addMarkBehavior, marks.isEmpty {
            await withCheckedContinuation { continuation in
                markContinuation = continuation
            }
        }
        let time = markTimes.indices.contains(marks.count) ? markTimes[marks.count] : Double(marks.count + 1)
        marks.append(
            NotesServices.AudioTimelineMark(
                commandID: commandID,
                pageID: pageID,
                time: time
            )
        )
    }

    func currentRecordingTime() async throws -> TimeInterval {
        guard activeID != nil else { throw AudioTimelineError.notRecording }
        let index = recordingTimeCalls
        recordingTimeCalls += 1
        if recordingTimes.indices.contains(index) {
            return recordingTimes[index]
        }
        return recordingTimes.last ?? 0
    }

    func stopRecording() async throws -> AudioRecordingResult {
        guard let id = activeID, let destinationURL else {
            throw AudioTimelineError.notRecording
        }
        activeID = nil
        self.destinationURL = nil
        if let replaceResultWithSymbolicLinkTo {
            try FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.createSymbolicLink(
                at: destinationURL,
                withDestinationURL: replaceResultWithSymbolicLinkTo
            )
        }
        return AudioRecordingResult(
            id: id,
            fileURL: resultURLOverride ?? destinationURL,
            duration: resultDuration,
            startedAt: Date(timeIntervalSince1970: 1_000),
            marks: marks
        )
    }

    func cancelRecording() async {
        cancellationCount += 1
        if let destinationURL { try? FileManager.default.removeItem(at: destinationURL) }
        activeID = nil
        destinationURL = nil
        marks = []
    }

    func startedURL() -> URL? { retainedStartedURL }
    func cancelCount() -> Int { cancellationCount }
    func recordingTimeCallCount() -> Int { recordingTimeCalls }

    func waitUntilMarkEntered() async {
        if markEntered { return }
        await withCheckedContinuation { continuation in
            markEntryWaiters.append(continuation)
        }
    }

    func resumeMark() {
        let continuation = markContinuation
        markContinuation = nil
        continuation?.resume()
    }
}

private actor AudioPlayerFake: AudioTimelinePlaying {
    private var state: AudioPlaybackState = .stopped
    private var fileURL: URL?
    private var stops = 0
    private var shouldSuspendNextStop = false
    private var suspendedStopEntered = false
    private var suspendedStopContinuation: CheckedContinuation<Void, Never>?
    private var stopEntryWaiters: [CheckedContinuation<Void, Never>] = []

    func play(fileURL: URL, from time: TimeInterval) async throws {
        self.fileURL = fileURL
        state = AudioPlaybackState(
            status: .playing,
            fileURL: fileURL,
            currentTime: time,
            duration: 10
        )
    }

    func pause() async {
        if state.status == .playing { state.status = .paused }
    }

    func resume() async throws {
        guard state.status == .paused else { throw AudioTimelineError.couldNotPlay }
        state.status = .playing
    }

    func stop() async {
        stops += 1
        if shouldSuspendNextStop {
            shouldSuspendNextStop = false
            suspendedStopEntered = true
            let waiters = stopEntryWaiters
            stopEntryWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                suspendedStopContinuation = continuation
            }
        }
        state = .stopped
    }

    func seek(to time: TimeInterval) async throws {
        state.currentTime = time
    }

    func currentState() async -> AudioPlaybackState { state }
    func setState(_ state: AudioPlaybackState) { self.state = state }
    func suspendNextStop() {
        shouldSuspendNextStop = true
        suspendedStopEntered = false
    }
    func waitUntilSuspendedStopEntered() async {
        guard !suspendedStopEntered else { return }
        await withCheckedContinuation { continuation in
            stopEntryWaiters.append(continuation)
        }
    }
    func resumeSuspendedStop() {
        let continuation = suspendedStopContinuation
        suspendedStopContinuation = nil
        continuation?.resume()
    }
    func receivedURL() -> URL? { fileURL }
    func stopCount() -> Int { stops }
}

private actor SpeechTranscriberFake: SpeechTranscribing {
    enum Behavior: Sendable {
        case immediate
        case suspendIgnoringCancellation
    }

    private let segments: [TranscriptSegment]
    private let behavior: Behavior
    private var fileURL: URL?
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        segments: [TranscriptSegment] = [],
        behavior: Behavior = .immediate
    ) {
        self.segments = segments
        self.behavior = behavior
    }

    func requestAuthorization() async -> Bool { true }

    func transcribe(fileURL: URL, localeIdentifier: String) async throws -> [TranscriptSegment] {
        self.fileURL = fileURL
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if case .suspendIgnoringCancellation = behavior {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return segments
    }

    func receivedURL() -> URL? { fileURL }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func resume() {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

private actor CountingAudioSessionListing: NotebookAudioSessionListing {
    private struct Waiter {
        let targetCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var requestCount = 0
    private var waiters: [Waiter] = []

    func listAudioSessions(notebookID: NotebookID) async throws -> [AudioSessionDescriptor] {
        requestCount += 1
        resumeSatisfiedWaiters()
        return []
    }

    func waitUntilRequestCount(_ targetCount: Int) async {
        guard requestCount < targetCount else { return }
        await withCheckedContinuation { continuation in
            waiters.append(Waiter(targetCount: targetCount, continuation: continuation))
        }
    }

    private func resumeSatisfiedWaiters() {
        let satisfied = waiters.filter { requestCount >= $0.targetCount }
        waiters.removeAll { requestCount >= $0.targetCount }
        satisfied.forEach { $0.continuation.resume() }
    }
}

private actor FailingTranscriptSearchIndexer: NotebookAudioTranscriptSearchIndexing {
    private enum Failure: Error, Sendable { case unavailable }

    func index(
        _ transcript: NotebookAudioTranscriptPayload,
        notebookID: NotebookID,
        transcriptAssetID: AssetID
    ) async throws {
        throw Failure.unavailable
    }

    func needsIndexing(
        notebookID: NotebookID,
        session: AudioSessionDescriptor
    ) async -> Bool {
        true
    }

    func remove(notebookID: NotebookID, sessionID: AudioSessionID) async throws {}

    func reconcile(
        notebookID: NotebookID,
        sessions: [AudioSessionDescriptor]
    ) async throws {}
}

private actor RecordingTranscriptSearchIndexer: NotebookAudioTranscriptSearchIndexing {
    struct IndexedTranscript: Equatable, Sendable {
        let notebookID: NotebookID
        let sessionID: AudioSessionID
        let transcriptAssetID: AssetID
    }

    private var indexed: [IndexedTranscript] = []

    func index(
        _ transcript: NotebookAudioTranscriptPayload,
        notebookID: NotebookID,
        transcriptAssetID: AssetID
    ) async throws {
        indexed.append(IndexedTranscript(
            notebookID: notebookID,
            sessionID: transcript.audioSessionID,
            transcriptAssetID: transcriptAssetID
        ))
    }

    func needsIndexing(
        notebookID: NotebookID,
        session: AudioSessionDescriptor
    ) async -> Bool {
        true
    }

    func remove(notebookID: NotebookID, sessionID: AudioSessionID) async throws {}

    func reconcile(
        notebookID: NotebookID,
        sessions: [AudioSessionDescriptor]
    ) async throws {}

    func indexedTranscripts() -> [IndexedTranscript] { indexed }
}

private actor SearchIndexFIFOProbe {
    private struct StartWaiter {
        let targetCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var started: [Int] = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var startWaiters: [StartWaiter] = []
    private var cancellationCount = 0
    private var cancellationWaiters: [StartWaiter] = []

    func perform(_ value: Int) async throws {
        let callIndex = started.count
        started.append(value)
        resumeSatisfiedStartWaiters()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                continuations[callIndex] = continuation
            }
        } onCancel: {
            Task { await self.recordCancellation() }
        }
        try Task.checkCancellation()
    }

    func waitUntilStartedCount(_ targetCount: Int) async {
        guard started.count < targetCount else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(StartWaiter(
                targetCount: targetCount,
                continuation: continuation
            ))
        }
    }

    func resume(call index: Int) {
        let continuation = continuations.removeValue(forKey: index)
        continuation?.resume()
    }

    func waitUntilCancellationCount(_ targetCount: Int) async {
        guard cancellationCount < targetCount else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(StartWaiter(
                targetCount: targetCount,
                continuation: continuation
            ))
        }
    }

    func startedValues() -> [Int] { started }

    private func resumeSatisfiedStartWaiters() {
        let satisfied = startWaiters.filter { started.count >= $0.targetCount }
        startWaiters.removeAll { started.count >= $0.targetCount }
        satisfied.forEach { $0.continuation.resume() }
    }

    private func recordCancellation() {
        cancellationCount += 1
        let satisfied = cancellationWaiters.filter {
            cancellationCount >= $0.targetCount
        }
        cancellationWaiters.removeAll {
            cancellationCount >= $0.targetCount
        }
        satisfied.forEach { $0.continuation.resume() }
    }
}

private actor ControlledTranscriptSearchIndexer: NotebookAudioTranscriptSearchIndexing {
    enum SuspensionMode: Equatable, Sendable {
        case everyCall
        case firstCallOnly
    }

    private struct CountWaiter {
        let targetCount: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private let suspensionMode: SuspensionMode
    private var notebookIDs: [NotebookID] = []
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var callWaiters: [CountWaiter] = []
    private var cancellationWaiters: [CountWaiter] = []
    private var activeCallCount = 0
    private var maximumActiveCalls = 0
    private var cancellations = 0

    init(suspensionMode: SuspensionMode) {
        self.suspensionMode = suspensionMode
    }

    func index(
        _ transcript: NotebookAudioTranscriptPayload,
        notebookID: NotebookID,
        transcriptAssetID: AssetID
    ) async throws {
        await performControlledCall(notebookID: notebookID)
    }

    func needsIndexing(
        notebookID: NotebookID,
        session: AudioSessionDescriptor
    ) async -> Bool {
        true
    }

    func remove(notebookID: NotebookID, sessionID: AudioSessionID) async throws {
        await performControlledCall(notebookID: notebookID)
    }

    func reconcile(
        notebookID: NotebookID,
        sessions: [AudioSessionDescriptor]
    ) async throws {
        await performControlledCall(notebookID: notebookID)
    }

    func waitUntilCallCount(_ targetCount: Int) async {
        guard notebookIDs.count < targetCount else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append(CountWaiter(
                targetCount: targetCount,
                continuation: continuation
            ))
        }
    }

    func waitUntilCancellationCount(_ targetCount: Int) async {
        guard cancellations < targetCount else { return }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append(CountWaiter(
                targetCount: targetCount,
                continuation: continuation
            ))
        }
    }

    func resume(call index: Int) {
        let continuation = continuations.removeValue(forKey: index)
        continuation?.resume()
    }

    func callCount() -> Int { notebookIDs.count }
    func cancellationCount() -> Int { cancellations }
    func maximumActiveCallCount() -> Int { maximumActiveCalls }
    func calledNotebookIDs() -> [NotebookID] { notebookIDs }

    private func performControlledCall(notebookID: NotebookID) async {
        let index = notebookIDs.count
        notebookIDs.append(notebookID)
        activeCallCount += 1
        maximumActiveCalls = max(maximumActiveCalls, activeCallCount)
        resumeSatisfiedCallWaiters()

        let shouldSuspend = suspensionMode == .everyCall || index == 0
        if shouldSuspend {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    continuations[index] = continuation
                }
            } onCancel: {
                Task { await self.recordCancellation() }
            }
        }
        activeCallCount -= 1
    }

    private func recordCancellation() {
        cancellations += 1
        let satisfied = cancellationWaiters.filter { cancellations >= $0.targetCount }
        cancellationWaiters.removeAll { cancellations >= $0.targetCount }
        satisfied.forEach { $0.continuation.resume() }
    }

    private func resumeSatisfiedCallWaiters() {
        let satisfied = callWaiters.filter { notebookIDs.count >= $0.targetCount }
        callWaiters.removeAll { notebookIDs.count >= $0.targetCount }
        satisfied.forEach { $0.continuation.resume() }
    }
}
