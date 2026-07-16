import CryptoKit
import Foundation
import XCTest
@testable import NotesCore

final class NoteReplayHistoryRepositoryTests: XCTestCase {
    func testAudioDescriptorWithoutReplayTupleRemainsSchemaV2() {
        let descriptor = AudioSessionDescriptor()

        XCTAssertEqual(descriptor.schemaVersion, 2)
        XCTAssertEqual(AudioSessionDescriptor.currentSchemaVersion, 3)
        XCTAssertNil(descriptor.replayFilename)
        XCTAssertNil(descriptor.replayByteCount)
        XCTAssertNil(descriptor.replaySHA256)
        XCTAssertNil(descriptor.replayEventCount)
    }

    func testRecordedSessionAtomicallyPersistsAndSecurelyReadsReplayHistory() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let page = PageDescriptor(kind: .notebook, title: "Replay")
        let manifest = try await fixture.repository.createNotebook(
            title: "Replay",
            initialPage: page
        )
        let sessionID = AudioSessionID()
        let recordingStartedAt = Date(timeIntervalSinceReferenceDate: 50_000)
        let duration: TimeInterval = 8
        let timeline = AudioTimelineDocument(
            audioSessionID: sessionID,
            modifiedAt: recordingStartedAt.addingTimeInterval(duration)
        )
        let audioURL = fixture.rootURL.appendingPathComponent("capture.m4a")
        try makeM4AData().write(to: audioURL, options: .atomic)

        let inkData = Data([0x01, 0x02, 0x03, 0x04])
        let elementData = try NoteReplayPayloadCodec.encodeElements([])
        let inkReference = reference(for: inkData)
        let elementReference = reference(for: elementData)
        let history = NoteReplayHistoryDocument(
            audioSessionID: sessionID,
            sealedAt: recordingStartedAt.addingTimeInterval(duration),
            events: [
                NoteReplaySnapshotEvent(
                    sequence: 0,
                    timeSeconds: 0,
                    pageID: page.id,
                    kind: .baseline,
                    inkPayload: inkReference,
                    elementsPayload: elementReference
                ),
                NoteReplaySnapshotEvent(
                    sequence: 1,
                    timeSeconds: duration,
                    pageID: page.id,
                    kind: .terminal,
                    inkPayload: inkReference,
                    elementsPayload: elementReference
                ),
            ]
        )
        let bundle = NoteReplayCaptureBundle(
            document: history,
            payloads: [
                NoteReplayPayloadBlob(reference: inkReference, data: inkData),
                NoteReplayPayloadBlob(reference: elementReference, data: elementData),
            ]
        )

        let descriptor = try await fixture.repository.addRecordedAudioSession(
            from: audioURL,
            maximumByteCount: 1_024,
            timeline: timeline,
            replayHistory: bundle,
            notebookID: manifest.id,
            durationSeconds: duration,
            recordingStartedAt: recordingStartedAt,
            transcriptAssetID: nil
        )

        XCTAssertEqual(descriptor.schemaVersion, 3)
        XCTAssertEqual(descriptor.replayEventCount, 2)
        XCTAssertEqual(descriptor.replayFilename, "\(sessionID.description).replay.json")
        XCTAssertNotNil(descriptor.replayByteCount)
        XCTAssertNotNil(descriptor.replaySHA256)

        let layout = NotebookPackageLayout(
            packageURL: fixture.repository.packageURL(for: manifest.id)
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.audioReplayHistoryURL(sessionID).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.assetURL(inkReference.assetID).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.assetURL(elementReference.assetID).path
        ))

        let export = try await fixture.repository.beginNotebookExport(id: manifest.id)
        let loadedHistory = try await fixture.repository.loadNoteReplayHistoryForReplay(
            session: export.session,
            sessionID: sessionID,
            maximumEventCount: NoteReplayHistoryLimits.maximumEventCount
        )
        XCTAssertEqual(loadedHistory, history)
        let loadedInk = try await fixture.repository.loadNoteReplayInkPayloadForReplay(
            session: export.session,
            reference: inkReference,
            maximumByteCount: NoteReplayHistoryLimits.maximumInkPayloadBytes
        )
        XCTAssertEqual(loadedInk, inkData)
        let loadedElements = try await fixture.repository.loadNoteReplayElementsPayloadForReplay(
            session: export.session,
            reference: elementReference,
            maximumByteCount: NoteReplayHistoryLimits.maximumElementPayloadBytes,
            maximumElementCount: NoteReplayHistoryLimits.maximumElementCountPerSnapshot
        )
        XCTAssertEqual(loadedElements.elements, [])
        XCTAssertEqual(loadedElements.encodedByteCount, elementData.count)
        await fixture.repository.endNotebookExport(export.session)

        let originalManifestData = try Data(contentsOf: layout.manifestURL)
        let originalReplayData = try Data(
            contentsOf: layout.audioReplayHistoryURL(sessionID)
        )
        var forgedHistory = history
        let nonexistentPageID = PageID()
        for index in forgedHistory.events.indices {
            forgedHistory.events[index].pageID = nonexistentPageID
        }
        let forgedReplayData = try JSONEncoder().encode(forgedHistory)
        var forgedManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: originalManifestData) as? [String: Any]
        )
        var forgedSessions = try XCTUnwrap(
            forgedManifest["audioSessions"] as? [[String: Any]]
        )
        forgedSessions[0]["replayByteCount"] = forgedReplayData.count
        forgedSessions[0]["replaySHA256"] = digest(for: forgedReplayData)
        forgedManifest["audioSessions"] = forgedSessions
        try forgedReplayData.write(
            to: layout.audioReplayHistoryURL(sessionID),
            options: .atomic
        )
        try JSONSerialization.data(
            withJSONObject: forgedManifest,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: layout.manifestURL, options: .atomic)

        let forgedExport = try await fixture.repository.beginNotebookExport(id: manifest.id)
        do {
            _ = try await fixture.repository.loadNoteReplayHistoryForReplay(
                session: forgedExport.session,
                sessionID: sessionID,
                maximumEventCount: NoteReplayHistoryLimits.maximumEventCount
            )
            XCTFail("A replay history must not authorize events for a nonexistent page.")
        } catch let error as NotebookRepositoryError {
            guard case .invalidAudioSession(let rejectedID, _) = error else {
                return XCTFail("Unexpected repository error: \(error)")
            }
            XCTAssertEqual(rejectedID, sessionID)
        }
        await fixture.repository.endNotebookExport(forgedExport.session)
        let forgedValidation = try await fixture.repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(forgedValidation.issues.contains {
            $0.kind == .invalidAudioReplayHistory
        })

        try originalReplayData.write(
            to: layout.audioReplayHistoryURL(sessionID),
            options: .atomic
        )
        try originalManifestData.write(to: layout.manifestURL, options: .atomic)

        var gappedHistory = history
        gappedHistory.events[1].sequence = 2
        let gappedReplayData = try JSONEncoder().encode(gappedHistory)
        var gappedManifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: originalManifestData) as? [String: Any]
        )
        var gappedSessions = try XCTUnwrap(
            gappedManifest["audioSessions"] as? [[String: Any]]
        )
        gappedSessions[0]["replayByteCount"] = gappedReplayData.count
        gappedSessions[0]["replaySHA256"] = digest(for: gappedReplayData)
        gappedManifest["audioSessions"] = gappedSessions
        try gappedReplayData.write(
            to: layout.audioReplayHistoryURL(sessionID),
            options: .atomic
        )
        try JSONSerialization.data(
            withJSONObject: gappedManifest,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: layout.manifestURL, options: .atomic)

        let gappedExport = try await fixture.repository.beginNotebookExport(id: manifest.id)
        do {
            _ = try await fixture.repository.loadNoteReplayHistoryForReplay(
                session: gappedExport.session,
                sessionID: sessionID,
                maximumEventCount: NoteReplayHistoryLimits.maximumEventCount
            )
            XCTFail("A stored replay history with a sequence gap must be rejected.")
        } catch let error as NotebookRepositoryError {
            guard case .invalidAudioSession(let rejectedID, _) = error else {
                return XCTFail("Unexpected repository error: \(error)")
            }
            XCTAssertEqual(rejectedID, sessionID)
        }
        await fixture.repository.endNotebookExport(gappedExport.session)
        let gappedValidation = try await fixture.repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(gappedValidation.issues.contains {
            $0.kind == .invalidAudioReplayHistory
        })

        try originalReplayData.write(
            to: layout.audioReplayHistoryURL(sessionID),
            options: .atomic
        )
        try originalManifestData.write(to: layout.manifestURL, options: .atomic)
        let tamperExport = try await fixture.repository.beginNotebookExport(id: manifest.id)
        _ = try await fixture.repository.loadNoteReplayHistoryForReplay(
            session: tamperExport.session,
            sessionID: sessionID,
            maximumEventCount: NoteReplayHistoryLimits.maximumEventCount
        )

        try Data([0xff]).write(
            to: layout.assetURL(inkReference.assetID),
            options: .atomic
        )
        do {
            _ = try await fixture.repository.loadNoteReplayInkPayloadForReplay(
                session: tamperExport.session,
                reference: inkReference,
                maximumByteCount: NoteReplayHistoryLimits.maximumInkPayloadBytes
            )
            XCTFail("A tampered content-addressed replay payload must not be returned.")
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(error, .invalidAsset(inkReference.assetID))
        }
        await fixture.repository.endNotebookExport(tamperExport.session)

        let recovery = try await fixture.repository.recoverNotebook(id: manifest.id)
        XCTAssertTrue(recovery.actions.contains(
            .preservedUnavailableAudioReplayHistory
        ))
        XCTAssertFalse(recovery.validation.isValid)
        let recoveredDescriptor = try XCTUnwrap(
            recovery.manifest.audioSessions.first(where: { $0.id == sessionID })
        )
        XCTAssertEqual(recoveredDescriptor.schemaVersion, 3)
        XCTAssertEqual(recoveredDescriptor.replayFilename, descriptor.replayFilename)
        XCTAssertEqual(recoveredDescriptor.replaySHA256, descriptor.replaySHA256)
        let playableAudio = try await fixture.repository.loadAudioChunk(
            notebookID: manifest.id,
            sessionID: sessionID,
            offset: 0,
            maximumByteCount: 12
        )
        XCTAssertEqual(playableAudio, makeM4AData())
    }

    func testReplayIngestRejectsTerminalBeforeRecordingDurationWithoutMutation() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let page = PageDescriptor(kind: .notebook, title: "Replay")
        let manifest = try await fixture.repository.createNotebook(
            title: "Replay",
            initialPage: page
        )
        let sessionID = AudioSessionID()
        let recordingStartedAt = Date(timeIntervalSinceReferenceDate: 60_000)
        let timeline = AudioTimelineDocument(audioSessionID: sessionID)
        let audioURL = fixture.rootURL.appendingPathComponent("invalid-capture.m4a")
        try makeM4AData().write(to: audioURL, options: .atomic)
        let elementData = try NoteReplayPayloadCodec.encodeElements([])
        let elementReference = reference(for: elementData)
        let history = NoteReplayHistoryDocument(
            audioSessionID: sessionID,
            events: [
                NoteReplaySnapshotEvent(
                    sequence: 0,
                    timeSeconds: 0,
                    pageID: page.id,
                    kind: .baseline,
                    inkPayload: nil,
                    elementsPayload: elementReference
                ),
                NoteReplaySnapshotEvent(
                    sequence: 1,
                    timeSeconds: 4,
                    pageID: page.id,
                    kind: .terminal,
                    inkPayload: nil,
                    elementsPayload: elementReference
                ),
            ]
        )
        let bundle = NoteReplayCaptureBundle(
            document: history,
            payloads: [
                NoteReplayPayloadBlob(reference: elementReference, data: elementData),
            ]
        )

        do {
            _ = try await fixture.repository.addRecordedAudioSession(
                from: audioURL,
                maximumByteCount: 1_024,
                timeline: timeline,
                replayHistory: bundle,
                notebookID: manifest.id,
                durationSeconds: 5,
                recordingStartedAt: recordingStartedAt,
                transcriptAssetID: nil
            )
            XCTFail("A replay terminal must equal the exact recording duration.")
        } catch let error as NotebookRepositoryError {
            guard case .invalidAudioSession(let rejectedID, _) = error else {
                return XCTFail("Unexpected repository error: \(error)")
            }
            XCTAssertEqual(rejectedID, sessionID)
        }

        let unchanged = try await fixture.repository.openNotebook(id: manifest.id)
        XCTAssertTrue(unchanged.audioSessions.isEmpty)
        let layout = NotebookPackageLayout(
            packageURL: fixture.repository.packageURL(for: manifest.id)
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.audioReplayHistoryURL(sessionID).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.assetURL(elementReference.assetID).path
        ))
    }

    func testReplayIngestRejectsNonzeroAndGappedGlobalSequencesWithoutMutation() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let page = PageDescriptor(kind: .notebook, title: "Sequence")
        let manifest = try await fixture.repository.createNotebook(
            title: "Sequence",
            initialPage: page
        )
        let audioURL = fixture.rootURL.appendingPathComponent("sequence.m4a")
        try makeM4AData().write(to: audioURL, options: .atomic)
        let elementData = try NoteReplayPayloadCodec.encodeElements([])
        let elementReference = reference(for: elementData)
        let duration: TimeInterval = 3

        for sequences in [[1, 2], [0, 2]] {
            let sessionID = AudioSessionID()
            let recordingStartedAt = Date(timeIntervalSinceReferenceDate: 65_000)
            let timeline = AudioTimelineDocument(
                audioSessionID: sessionID,
                modifiedAt: recordingStartedAt.addingTimeInterval(duration)
            )
            let history = NoteReplayHistoryDocument(
                audioSessionID: sessionID,
                sealedAt: recordingStartedAt.addingTimeInterval(duration),
                events: [
                    NoteReplaySnapshotEvent(
                        sequence: sequences[0],
                        timeSeconds: 0,
                        pageID: page.id,
                        kind: .baseline,
                        inkPayload: nil,
                        elementsPayload: elementReference
                    ),
                    NoteReplaySnapshotEvent(
                        sequence: sequences[1],
                        timeSeconds: duration,
                        pageID: page.id,
                        kind: .terminal,
                        inkPayload: nil,
                        elementsPayload: elementReference
                    ),
                ]
            )

            do {
                _ = try await fixture.repository.addRecordedAudioSession(
                    from: audioURL,
                    maximumByteCount: 1_024,
                    timeline: timeline,
                    replayHistory: NoteReplayCaptureBundle(
                        document: history,
                        payloads: [
                            NoteReplayPayloadBlob(
                                reference: elementReference,
                                data: elementData
                            ),
                        ]
                    ),
                    notebookID: manifest.id,
                    durationSeconds: duration,
                    recordingStartedAt: recordingStartedAt,
                    transcriptAssetID: nil
                )
                XCTFail("Replay sequences must start at zero and remain contiguous.")
            } catch let error as NotebookRepositoryError {
                guard case .invalidAudioSession(let rejectedID, _) = error else {
                    return XCTFail("Unexpected repository error: \(error)")
                }
                XCTAssertEqual(rejectedID, sessionID)
            }
        }

        let unchanged = try await fixture.repository.openNotebook(id: manifest.id)
        XCTAssertTrue(unchanged.audioSessions.isEmpty)
        XCTAssertTrue(unchanged.assets.isEmpty)
        let layout = NotebookPackageLayout(
            packageURL: fixture.repository.packageURL(for: manifest.id)
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.assetURL(elementReference.assetID).path
        ))
    }

    func testDeleteAudioSessionCollectsUniqueReplayPayloadAndPreservesSharedPayload() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let page = PageDescriptor(kind: .notebook, title: "Shared")
        let manifest = try await fixture.repository.createNotebook(
            title: "Audio replay GC",
            initialPage: page
        )
        let duration: TimeInterval = 2
        let recordingStartedAt = Date(timeIntervalSinceReferenceDate: 67_000)
        let uniqueInkData = Data([0xb1, 0xb2])
        let sharedElementsData = try NoteReplayPayloadCodec.encodeElements([])
        let uniqueInk = reference(for: uniqueInkData)
        let sharedElements = reference(for: sharedElementsData)

        let firstSessionID = AudioSessionID()
        let firstAudioURL = fixture.rootURL.appendingPathComponent("delete-a.m4a")
        try makeM4AData().write(to: firstAudioURL, options: .atomic)
        _ = try await fixture.repository.addRecordedAudioSession(
            from: firstAudioURL,
            maximumByteCount: 1_024,
            timeline: AudioTimelineDocument(
                audioSessionID: firstSessionID,
                modifiedAt: recordingStartedAt.addingTimeInterval(duration)
            ),
            replayHistory: NoteReplayCaptureBundle(
                document: NoteReplayHistoryDocument(
                    audioSessionID: firstSessionID,
                    sealedAt: recordingStartedAt.addingTimeInterval(duration),
                    events: [
                        NoteReplaySnapshotEvent(
                            sequence: 0,
                            timeSeconds: 0,
                            pageID: page.id,
                            kind: .baseline,
                            inkPayload: uniqueInk,
                            elementsPayload: sharedElements
                        ),
                        NoteReplaySnapshotEvent(
                            sequence: 1,
                            timeSeconds: duration,
                            pageID: page.id,
                            kind: .terminal,
                            inkPayload: uniqueInk,
                            elementsPayload: sharedElements
                        ),
                    ]
                ),
                payloads: [
                    NoteReplayPayloadBlob(reference: uniqueInk, data: uniqueInkData),
                    NoteReplayPayloadBlob(reference: sharedElements, data: sharedElementsData),
                ]
            ),
            notebookID: manifest.id,
            durationSeconds: duration,
            recordingStartedAt: recordingStartedAt,
            transcriptAssetID: nil
        )

        let secondSessionID = AudioSessionID()
        let secondAudioURL = fixture.rootURL.appendingPathComponent("delete-b.m4a")
        try makeM4AData().write(to: secondAudioURL, options: .atomic)
        _ = try await fixture.repository.addRecordedAudioSession(
            from: secondAudioURL,
            maximumByteCount: 1_024,
            timeline: AudioTimelineDocument(
                audioSessionID: secondSessionID,
                modifiedAt: recordingStartedAt.addingTimeInterval(duration)
            ),
            replayHistory: NoteReplayCaptureBundle(
                document: NoteReplayHistoryDocument(
                    audioSessionID: secondSessionID,
                    sealedAt: recordingStartedAt.addingTimeInterval(duration),
                    events: [
                        NoteReplaySnapshotEvent(
                            sequence: 0,
                            timeSeconds: 0,
                            pageID: page.id,
                            kind: .baseline,
                            inkPayload: nil,
                            elementsPayload: sharedElements
                        ),
                        NoteReplaySnapshotEvent(
                            sequence: 1,
                            timeSeconds: duration,
                            pageID: page.id,
                            kind: .terminal,
                            inkPayload: nil,
                            elementsPayload: sharedElements
                        ),
                    ]
                ),
                payloads: [
                    NoteReplayPayloadBlob(reference: sharedElements, data: sharedElementsData),
                ]
            ),
            notebookID: manifest.id,
            durationSeconds: duration,
            recordingStartedAt: recordingStartedAt,
            transcriptAssetID: nil
        )

        let layout = NotebookPackageLayout(
            packageURL: fixture.repository.packageURL(for: manifest.id)
        )
        try await fixture.repository.deleteAudioSession(
            notebookID: manifest.id,
            sessionID: firstSessionID
        )
        var afterDeletion = try await fixture.repository.openNotebook(id: manifest.id)
        XCTAssertFalse(afterDeletion.audioSessions.contains { $0.id == firstSessionID })
        XCTAssertTrue(afterDeletion.audioSessions.contains { $0.id == secondSessionID })
        XCTAssertFalse(afterDeletion.assets.contains { $0.id == uniqueInk.assetID })
        XCTAssertTrue(afterDeletion.assets.contains { $0.id == sharedElements.assetID })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.assetURL(uniqueInk.assetID).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.assetURL(sharedElements.assetID).path
        ))
        var validation = try await fixture.repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(validation.isValid)

        try await fixture.repository.deleteAudioSession(
            notebookID: manifest.id,
            sessionID: secondSessionID
        )
        afterDeletion = try await fixture.repository.openNotebook(id: manifest.id)
        XCTAssertTrue(afterDeletion.audioSessions.isEmpty)
        XCTAssertFalse(afterDeletion.assets.contains { $0.id == sharedElements.assetID })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.assetURL(sharedElements.assetID).path
        ))
        validation = try await fixture.repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(validation.isValid)
    }

    func testDeleteAudioSessionWithDamagedHistoryRemovesIndexButConservativelyKeepsPayloads() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let page = PageDescriptor(kind: .notebook, title: "Damaged")
        let manifest = try await fixture.repository.createNotebook(
            title: "Damaged replay deletion",
            initialPage: page
        )
        let sessionID = AudioSessionID()
        let duration: TimeInterval = 2
        let recordingStartedAt = Date(timeIntervalSinceReferenceDate: 67_500)
        let inkData = Data([0xc1, 0xc2])
        let elementsData = try NoteReplayPayloadCodec.encodeElements([])
        let ink = reference(for: inkData)
        let elements = reference(for: elementsData)
        let audioURL = fixture.rootURL.appendingPathComponent("damaged-delete.m4a")
        try makeM4AData().write(to: audioURL, options: .atomic)
        _ = try await fixture.repository.addRecordedAudioSession(
            from: audioURL,
            maximumByteCount: 1_024,
            timeline: AudioTimelineDocument(
                audioSessionID: sessionID,
                modifiedAt: recordingStartedAt.addingTimeInterval(duration)
            ),
            replayHistory: NoteReplayCaptureBundle(
                document: NoteReplayHistoryDocument(
                    audioSessionID: sessionID,
                    sealedAt: recordingStartedAt.addingTimeInterval(duration),
                    events: [
                        NoteReplaySnapshotEvent(
                            sequence: 0,
                            timeSeconds: 0,
                            pageID: page.id,
                            kind: .baseline,
                            inkPayload: ink,
                            elementsPayload: elements
                        ),
                        NoteReplaySnapshotEvent(
                            sequence: 1,
                            timeSeconds: duration,
                            pageID: page.id,
                            kind: .terminal,
                            inkPayload: ink,
                            elementsPayload: elements
                        ),
                    ]
                ),
                payloads: [
                    NoteReplayPayloadBlob(reference: ink, data: inkData),
                    NoteReplayPayloadBlob(reference: elements, data: elementsData),
                ]
            ),
            notebookID: manifest.id,
            durationSeconds: duration,
            recordingStartedAt: recordingStartedAt,
            transcriptAssetID: nil
        )
        let layout = NotebookPackageLayout(
            packageURL: fixture.repository.packageURL(for: manifest.id)
        )
        try Data("damaged replay index".utf8).write(
            to: layout.audioReplayHistoryURL(sessionID),
            options: .atomic
        )

        try await fixture.repository.deleteAudioSession(
            notebookID: manifest.id,
            sessionID: sessionID
        )
        let afterDeletion = try await fixture.repository.openNotebook(id: manifest.id)
        XCTAssertTrue(afterDeletion.audioSessions.isEmpty)
        XCTAssertTrue(afterDeletion.assets.contains { $0.id == ink.assetID })
        XCTAssertTrue(afterDeletion.assets.contains { $0.id == elements.assetID })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.audioReplayHistoryURL(sessionID).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.assetURL(ink.assetID).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.assetURL(elements.assetID).path
        ))
        let validation = try await fixture.repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(validation.isValid)
    }

    func testCraftedCommittedReplayDeletionJournalCannotDeleteLiveCASAsset() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let manifest = try await fixture.repository.createNotebook(
            title: "Replay journal guard"
        )
        let assetData = Data([0xd1, 0xd2, 0xd3])
        let asset = try await fixture.repository.importAsset(
            assetData,
            notebookID: manifest.id,
            mediaType: NoteReplayPayloadCodec.inkMediaType,
            originalFilename: "guarded-replay-ink"
        )
        _ = try await fixture.repository.addPage(
            notebookID: manifest.id,
            page: PageDescriptor(background: .image(assetID: asset.id)),
            at: nil
        )
        let current = try await fixture.repository.openNotebook(id: manifest.id)
        let layout = NotebookPackageLayout(
            packageURL: fixture.repository.packageURL(for: manifest.id)
        )
        let transactionID = OperationID()
        let transactionDirectory = layout.transactionsURL.appendingPathComponent(
            transactionID.description,
            isDirectory: true
        )
        let stagedDirectory = transactionDirectory.appendingPathComponent(
            "staged",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stagedDirectory,
            withIntermediateDirectories: true
        )
        try Data().write(
            to: stagedDirectory.appendingPathComponent("0000.data")
        )
        let currentManifestData = try Data(contentsOf: layout.manifestURL)
        try currentManifestData.write(
            to: stagedDirectory.appendingPathComponent("0001.data")
        )
        let journal: [String: Any] = [
            "schemaVersion": 1,
            "command": [
                "id": ["rawValue": transactionID.rawValue.uuidString],
                "notebookID": ["rawValue": manifest.id.rawValue.uuidString],
                "actorID": "local",
                "sequence": current.revision,
                "timestamp": 0,
                "kind": "deletePage",
                "payload": [:],
            ],
            "expectedRevision": current.revision - 1,
            "targetRevision": current.revision,
            "phase": "stateCommitted",
            "createdAt": 0,
            "files": [
                [
                    "relativePath": "assets/\(asset.id.rawValue)",
                    "stagedFilename": "staged/0000.data",
                    "existedBeforeTransaction": true,
                    "deletesTarget": true,
                    "maximumByteCount": NoteReplayHistoryLimits.maximumInkPayloadBytes,
                ],
                [
                    "relativePath": "manifest.json",
                    "stagedFilename": "staged/0001.data",
                    "existedBeforeTransaction": true,
                ],
            ],
            "cleanupDirectories": [],
        ]
        try JSONSerialization.data(withJSONObject: journal).write(
            to: transactionDirectory.appendingPathComponent("transaction.json")
        )

        do {
            _ = try await fixture.repository.recoverNotebook(id: manifest.id)
            XCTFail("A crafted journal must not delete a live replay-media CAS asset.")
        } catch let error as NotebookRepositoryError {
            guard case .malformedPackage = error else {
                return XCTFail("Unexpected repository error: \(error)")
            }
        }
        XCTAssertEqual(
            try Data(contentsOf: layout.assetURL(asset.id)),
            assetData
        )
    }

    func testDeletePageGarbageCollectionPreservesPayloadUsedByAnotherReplaySession() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let firstPage = PageDescriptor(kind: .notebook, title: "Private")
        var manifest = try await fixture.repository.createNotebook(
            title: "Shared replay payload",
            initialPage: firstPage
        )
        let secondPage = PageDescriptor(kind: .whiteboard, title: "Retained")
        manifest = try await fixture.repository.addPage(
            notebookID: manifest.id,
            page: secondPage,
            at: nil
        )
        let duration: TimeInterval = 2
        let recordingStartedAt = Date(timeIntervalSinceReferenceDate: 68_000)
        let exclusiveInkData = Data([0xa1, 0xa2, 0xa3])
        let dedicatedInkData = Data([0xa4, 0xa5, 0xa6])
        let sharedElementsData = try NoteReplayPayloadCodec.encodeElements([])
        let exclusiveInk = reference(for: exclusiveInkData)
        let dedicatedInk = reference(for: dedicatedInkData)
        let sharedElements = reference(for: sharedElementsData)

        let firstSessionID = AudioSessionID()
        let firstAudioURL = fixture.rootURL.appendingPathComponent("shared-a.m4a")
        try makeM4AData().write(to: firstAudioURL, options: .atomic)
        _ = try await fixture.repository.addRecordedAudioSession(
            from: firstAudioURL,
            maximumByteCount: 1_024,
            timeline: AudioTimelineDocument(
                audioSessionID: firstSessionID,
                modifiedAt: recordingStartedAt.addingTimeInterval(duration)
            ),
            replayHistory: NoteReplayCaptureBundle(
                document: NoteReplayHistoryDocument(
                    audioSessionID: firstSessionID,
                    sealedAt: recordingStartedAt.addingTimeInterval(duration),
                    events: [
                        NoteReplaySnapshotEvent(
                            sequence: 0,
                            timeSeconds: 0,
                            pageID: firstPage.id,
                            kind: .baseline,
                            inkPayload: exclusiveInk,
                            elementsPayload: sharedElements
                        ),
                        NoteReplaySnapshotEvent(
                            sequence: 1,
                            timeSeconds: 1,
                            pageID: firstPage.id,
                            kind: .change,
                            inkPayload: dedicatedInk,
                            elementsPayload: sharedElements
                        ),
                        NoteReplaySnapshotEvent(
                            sequence: 2,
                            timeSeconds: duration,
                            pageID: firstPage.id,
                            kind: .terminal,
                            inkPayload: exclusiveInk,
                            elementsPayload: sharedElements
                        ),
                    ]
                ),
                payloads: [
                    NoteReplayPayloadBlob(reference: exclusiveInk, data: exclusiveInkData),
                    NoteReplayPayloadBlob(reference: dedicatedInk, data: dedicatedInkData),
                    NoteReplayPayloadBlob(reference: sharedElements, data: sharedElementsData),
                ]
            ),
            notebookID: manifest.id,
            durationSeconds: duration,
            recordingStartedAt: recordingStartedAt,
            transcriptAssetID: nil
        )

        let secondSessionID = AudioSessionID()
        let secondAudioURL = fixture.rootURL.appendingPathComponent("shared-b.m4a")
        try makeM4AData().write(to: secondAudioURL, options: .atomic)
        _ = try await fixture.repository.addRecordedAudioSession(
            from: secondAudioURL,
            maximumByteCount: 1_024,
            timeline: AudioTimelineDocument(
                audioSessionID: secondSessionID,
                modifiedAt: recordingStartedAt.addingTimeInterval(duration)
            ),
            replayHistory: NoteReplayCaptureBundle(
                document: NoteReplayHistoryDocument(
                    audioSessionID: secondSessionID,
                    sealedAt: recordingStartedAt.addingTimeInterval(duration),
                    events: [
                        NoteReplaySnapshotEvent(
                            sequence: 0,
                            timeSeconds: 0,
                            pageID: secondPage.id,
                            kind: .baseline,
                            inkPayload: nil,
                            elementsPayload: sharedElements
                        ),
                        NoteReplaySnapshotEvent(
                            sequence: 1,
                            timeSeconds: duration,
                            pageID: secondPage.id,
                            kind: .terminal,
                            inkPayload: nil,
                            elementsPayload: sharedElements
                        ),
                    ]
                ),
                payloads: [
                    NoteReplayPayloadBlob(reference: sharedElements, data: sharedElementsData),
                ]
            ),
            notebookID: manifest.id,
            durationSeconds: duration,
            recordingStartedAt: recordingStartedAt,
            transcriptAssetID: nil
        )

        try await fixture.repository.saveElements(
            [CanvasElement(
                frame: CanvasRect(x: 0, y: 0, width: 100, height: 100),
                content: .image(ImageElement(assetID: exclusiveInk.assetID))
            )],
            notebookID: manifest.id,
            pageID: secondPage.id
        )

        manifest = try await fixture.repository.deletePage(
            notebookID: manifest.id,
            pageID: firstPage.id
        )
        let layout = NotebookPackageLayout(
            packageURL: fixture.repository.packageURL(for: manifest.id)
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.assetURL(exclusiveInk.assetID).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.assetURL(dedicatedInk.assetID).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.assetURL(sharedElements.assetID).path
        ))
        XCTAssertTrue(manifest.assets.contains { $0.id == exclusiveInk.assetID })
        XCTAssertFalse(manifest.assets.contains { $0.id == dedicatedInk.assetID })
        XCTAssertTrue(manifest.assets.contains { $0.id == sharedElements.assetID })
        let firstDescriptor = try XCTUnwrap(
            manifest.audioSessions.first { $0.id == firstSessionID }
        )
        let secondDescriptor = try XCTUnwrap(
            manifest.audioSessions.first { $0.id == secondSessionID }
        )
        XCTAssertEqual(firstDescriptor.replayEventCount, 0)
        XCTAssertEqual(secondDescriptor.replayEventCount, 2)
        let validation = try await fixture.repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(validation.isValid)
    }

    func testDeletePageAtomicallyRedactsHistoryRenumbersEventsAndGarbageCollectsPayloads() async throws {
        let fixture = try makeRepository()
        defer { try? FileManager.default.removeItem(at: fixture.rootURL) }
        let firstPage = PageDescriptor(kind: .notebook, title: "First")
        var manifest = try await fixture.repository.createNotebook(
            title: "Redaction",
            initialPage: firstPage
        )
        let secondPage = PageDescriptor(kind: .whiteboard, title: "Second")
        manifest = try await fixture.repository.addPage(
            notebookID: manifest.id,
            page: secondPage,
            at: nil
        )
        let sessionID = AudioSessionID()
        let recordingStartedAt = Date(timeIntervalSinceReferenceDate: 70_000)
        let duration: TimeInterval = 6
        let timeline = AudioTimelineDocument(
            audioSessionID: sessionID,
            marks: [
                AudioTimelineMark(
                    operationID: OperationID(),
                    pageID: firstPage.id,
                    timeSeconds: 1,
                    createdAt: recordingStartedAt.addingTimeInterval(1)
                ),
                AudioTimelineMark(
                    operationID: OperationID(),
                    pageID: secondPage.id,
                    timeSeconds: 2,
                    createdAt: recordingStartedAt.addingTimeInterval(2)
                ),
            ],
            modifiedAt: recordingStartedAt.addingTimeInterval(duration)
        )
        let audioURL = fixture.rootURL.appendingPathComponent("redaction.m4a")
        try makeM4AData().write(to: audioURL, options: .atomic)
        let firstInkData = Data([0x11, 0x12])
        let secondInkData = Data([0x21, 0x22])
        let sharedElementData = try NoteReplayPayloadCodec.encodeElements([])
        let firstInk = reference(for: firstInkData)
        let secondInk = reference(for: secondInkData)
        let sharedElements = reference(for: sharedElementData)
        let history = NoteReplayHistoryDocument(
            audioSessionID: sessionID,
            sealedAt: recordingStartedAt.addingTimeInterval(duration),
            events: [
                NoteReplaySnapshotEvent(
                    sequence: 0,
                    timeSeconds: 0,
                    pageID: firstPage.id,
                    kind: .baseline,
                    inkPayload: firstInk,
                    elementsPayload: sharedElements
                ),
                NoteReplaySnapshotEvent(
                    sequence: 1,
                    timeSeconds: 0,
                    pageID: secondPage.id,
                    kind: .baseline,
                    inkPayload: secondInk,
                    elementsPayload: sharedElements
                ),
                NoteReplaySnapshotEvent(
                    sequence: 2,
                    timeSeconds: duration,
                    pageID: firstPage.id,
                    kind: .terminal,
                    inkPayload: firstInk,
                    elementsPayload: sharedElements
                ),
                NoteReplaySnapshotEvent(
                    sequence: 3,
                    timeSeconds: duration,
                    pageID: secondPage.id,
                    kind: .terminal,
                    inkPayload: secondInk,
                    elementsPayload: sharedElements
                ),
            ]
        )
        _ = try await fixture.repository.addRecordedAudioSession(
            from: audioURL,
            maximumByteCount: 1_024,
            timeline: timeline,
            replayHistory: NoteReplayCaptureBundle(
                document: history,
                payloads: [
                    NoteReplayPayloadBlob(reference: firstInk, data: firstInkData),
                    NoteReplayPayloadBlob(reference: secondInk, data: secondInkData),
                    NoteReplayPayloadBlob(
                        reference: sharedElements,
                        data: sharedElementData
                    ),
                ]
            ),
            notebookID: manifest.id,
            durationSeconds: duration,
            recordingStartedAt: recordingStartedAt,
            transcriptAssetID: nil
        )
        let layout = NotebookPackageLayout(
            packageURL: fixture.repository.packageURL(for: manifest.id)
        )

        manifest = try await fixture.repository.deletePage(
            notebookID: manifest.id,
            pageID: firstPage.id
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.assetURL(firstInk.assetID).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.assetURL(secondInk.assetID).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.assetURL(sharedElements.assetID).path
        ))
        XCTAssertFalse(manifest.assets.contains { $0.id == firstInk.assetID })
        XCTAssertEqual(manifest.audioSessions.first?.replayEventCount, 2)

        let firstExport = try await fixture.repository.beginNotebookExport(id: manifest.id)
        let loadedRedactedHistory = try await fixture.repository.loadNoteReplayHistoryForReplay(
            session: firstExport.session,
            sessionID: sessionID,
            maximumEventCount: NoteReplayHistoryLimits.maximumEventCount
        )
        let redactedHistory = try XCTUnwrap(loadedRedactedHistory)
        XCTAssertEqual(redactedHistory.events.map(\.pageID), [
            secondPage.id,
            secondPage.id,
        ])
        XCTAssertEqual(redactedHistory.events.map(\.sequence), [0, 1])
        await fixture.repository.endNotebookExport(firstExport.session)
        let redactedTimeline = try await fixture.repository.loadAudioTimeline(
            notebookID: manifest.id,
            sessionID: sessionID
        )
        XCTAssertEqual(redactedTimeline.marks.map(\.pageID), [secondPage.id])
        let redactedValidation = try await fixture.repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(redactedValidation.isValid)

        let replayDataBeforeFailure = try Data(
            contentsOf: layout.audioReplayHistoryURL(sessionID)
        )
        let manifestBeforeFailure = manifest
        let failure = OneShotReplayStorageFailure(
            .beforeStateWrite(relativePath: "manifest.json")
        )
        let failingRepository = try FileNotebookRepository(
            rootURL: fixture.rootURL
        ) { point in
            try failure.trigger(point)
        }
        do {
            _ = try await failingRepository.deletePage(
                notebookID: manifest.id,
                pageID: secondPage.id
            )
            XCTFail("A failure before the redaction manifest commit must be reported.")
        } catch is InjectedReplayStorageFailure {
            // Expected. The transaction must restore its index and deleted CAS files.
        }
        let afterFailedDeletion = try await failingRepository.openNotebook(id: manifest.id)
        XCTAssertEqual(afterFailedDeletion, manifestBeforeFailure)
        XCTAssertEqual(
            try Data(contentsOf: layout.audioReplayHistoryURL(sessionID)),
            replayDataBeforeFailure
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.assetURL(secondInk.assetID).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.assetURL(sharedElements.assetID).path
        ))
        let rollbackValidation = try await failingRepository.validateNotebook(id: manifest.id)
        XCTAssertTrue(rollbackValidation.isValid)

        manifest = try await failingRepository.deletePage(
            notebookID: manifest.id,
            pageID: secondPage.id
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.assetURL(secondInk.assetID).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.assetURL(sharedElements.assetID).path
        ))
        XCTAssertFalse(manifest.assets.contains {
            $0.mediaType == NoteReplayPayloadCodec.inkMediaType
                || $0.mediaType == NoteReplayPayloadCodec.elementsMediaType
        })
        XCTAssertEqual(manifest.audioSessions.first?.schemaVersion, 3)
        XCTAssertEqual(manifest.audioSessions.first?.replayEventCount, 0)

        let emptyExport = try await fixture.repository.beginNotebookExport(id: manifest.id)
        let loadedEmptyHistory = try await fixture.repository.loadNoteReplayHistoryForReplay(
            session: emptyExport.session,
            sessionID: sessionID,
            maximumEventCount: NoteReplayHistoryLimits.maximumEventCount
        )
        let emptyHistory = try XCTUnwrap(loadedEmptyHistory)
        XCTAssertTrue(emptyHistory.events.isEmpty)
        await fixture.repository.endNotebookExport(emptyExport.session)
        let emptyValidation = try await fixture.repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(emptyValidation.isValid)
        let playableAudio = try await fixture.repository.loadAudioChunk(
            notebookID: manifest.id,
            sessionID: sessionID,
            offset: 0,
            maximumByteCount: 12
        )
        XCTAssertEqual(playableAudio, makeM4AData())
    }

    private func makeRepository() throws -> (
        repository: FileNotebookRepository,
        rootURL: URL
    ) {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NoteReplayHistoryRepositoryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        return (try FileNotebookRepository(rootURL: rootURL), rootURL)
    }

    private func reference(for data: Data) -> NoteReplayPayloadReference {
        NoteReplayPayloadReference(
            assetID: AssetID(digest(for: data)),
            byteCount: data.count
        )
    }

    private func digest(for data: Data) -> String {
        CryptoKit.SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func makeM4AData() -> Data {
        var data = Data([0x00, 0x00, 0x00, 0x0c])
        data.append(contentsOf: "ftyp".utf8)
        data.append(contentsOf: "M4A ".utf8)
        return data
    }
}

private struct InjectedReplayStorageFailure: Error {}

private final class OneShotReplayStorageFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var point: StorageFailurePoint?

    init(_ point: StorageFailurePoint) {
        self.point = point
    }

    func trigger(_ candidate: StorageFailurePoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard point == candidate else { return }
        point = nil
        throw InjectedReplayStorageFailure()
    }
}
