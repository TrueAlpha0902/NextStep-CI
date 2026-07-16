import Darwin
import Foundation
import XCTest
@testable import NotesCore

final class AudioSessionRepositoryTests: XCTestCase {
    func testTranscriptSaveIsAtomicContentAddressedBoundedAndIdempotent() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(title: "Transcript", initialPage: page)
        let sessionID = AudioSessionID()
        let timeline = makeTimeline(sessionID: sessionID, pageID: page.id, time: 0.5)
        _ = try await repository.addAudioSession(
            makeM4A(payload: "transcript audio"),
            timeline: timeline,
            notebookID: manifest.id,
            durationSeconds: 4,
            transcriptAssetID: nil
        )
        let revisionBeforeSave = try await repository.openNotebook(id: manifest.id).revision
        let payload = makeTranscript(
            sessionID: sessionID,
            timeline: timeline,
            text: "Durable words"
        )

        let descriptor = try await repository.saveAudioTranscript(
            payload,
            notebookID: manifest.id,
            sessionID: sessionID
        )
        let afterSave = try await repository.openNotebook(id: manifest.id)
        let assetID = try XCTUnwrap(descriptor.transcriptAssetID)
        XCTAssertEqual(afterSave.revision, revisionBeforeSave + 1)
        XCTAssertEqual(afterSave.assets.count, 1)
        XCTAssertEqual(afterSave.assets.first?.id, assetID)
        XCTAssertEqual(afterSave.assets.first?.mediaType, AudioTranscriptDocument.mediaType)
        let loadedTranscript = try await repository.loadAudioTranscript(
            notebookID: manifest.id,
            sessionID: sessionID
        )
        XCTAssertEqual(loadedTranscript, payload)

        _ = try await repository.saveAudioTranscript(
            payload,
            notebookID: manifest.id,
            sessionID: sessionID
        )
        let afterIdenticalSave = try await repository.openNotebook(id: manifest.id)
        XCTAssertEqual(afterIdenticalSave.revision, afterSave.revision)
        XCTAssertEqual(afterIdenticalSave.assets.map(\.id), [assetID])
        let validation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(validation.isValid)
    }

    func testTranscriptFailureBeforeManifestCommitLeavesNoAssetOrReference() async throws {
        let (initialRepository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await initialRepository.createNotebook(title: "Transcript rollback", initialPage: page)
        let sessionID = AudioSessionID()
        let timeline = makeTimeline(sessionID: sessionID, pageID: page.id, time: 0)
        _ = try await initialRepository.addAudioSession(
            makeM4A(payload: "rollback transcript"),
            timeline: timeline,
            notebookID: manifest.id,
            durationSeconds: 2,
            transcriptAssetID: nil
        )
        let revisionBeforeFailure = try await initialRepository.openNotebook(id: manifest.id).revision
        let failure = OneShotAudioStorageFailure(.beforeStateWrite(relativePath: "manifest.json"))
        let repository = try FileNotebookRepository(rootURL: root) { point in
            try failure.trigger(point)
        }

        do {
            _ = try await repository.saveAudioTranscript(
                makeTranscript(sessionID: sessionID, timeline: timeline, text: "must roll back"),
                notebookID: manifest.id,
                sessionID: sessionID
            )
            XCTFail("The injected transcript manifest failure must be reported.")
        } catch is InjectedAudioStorageFailure {
            // Expected.
        }

        let afterFailure = try await repository.openNotebook(id: manifest.id)
        XCTAssertEqual(afterFailure.revision, revisionBeforeFailure)
        XCTAssertTrue(afterFailure.assets.isEmpty)
        XCTAssertNil(afterFailure.audioSessions.first?.transcriptAssetID)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: layout.assetsURL.path).isEmpty)
        let validation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(validation.isValid)
    }

    func testTranscriptReplacementPreservesAssetSharedByPageBackground() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(title: "Shared transcript asset", initialPage: page)
        let sessionID = AudioSessionID()
        let timeline = makeTimeline(sessionID: sessionID, pageID: page.id, time: 0)
        _ = try await repository.addAudioSession(
            makeM4A(payload: "shared transcript"),
            timeline: timeline,
            notebookID: manifest.id,
            durationSeconds: 3,
            transcriptAssetID: nil
        )
        let original = try await repository.saveAudioTranscript(
            makeTranscript(sessionID: sessionID, timeline: timeline, text: "first"),
            notebookID: manifest.id,
            sessionID: sessionID
        )
        let originalAssetID = try XCTUnwrap(original.transcriptAssetID)
        _ = try await repository.addPage(
            notebookID: manifest.id,
            page: PageDescriptor(background: .image(assetID: originalAssetID)),
            at: nil
        )

        let replacement = try await repository.saveAudioTranscript(
            makeTranscript(sessionID: sessionID, timeline: timeline, text: "replacement"),
            notebookID: manifest.id,
            sessionID: sessionID
        )
        let replacementAssetID = try XCTUnwrap(replacement.transcriptAssetID)
        let afterReplacement = try await repository.openNotebook(id: manifest.id)
        XCTAssertNotEqual(replacementAssetID, originalAssetID)
        XCTAssertEqual(Set(afterReplacement.assets.map(\.id)), [originalAssetID, replacementAssetID])
        let preservedAsset = try await repository.loadAsset(
            notebookID: manifest.id,
            assetID: originalAssetID
        )
        XCTAssertFalse(preservedAsset.isEmpty)
        let validation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(validation.isValid)
    }

    func testTranscriptRejectsOversizeWrongSessionAndUnsupportedSchema() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(title: "Transcript validation", initialPage: page)
        let sessionID = AudioSessionID()
        let timeline = makeTimeline(sessionID: sessionID, pageID: page.id, time: 0)
        _ = try await repository.addAudioSession(
            makeM4A(payload: "validation transcript"),
            timeline: timeline,
            notebookID: manifest.id,
            durationSeconds: 2,
            transcriptAssetID: nil
        )
        let revision = try await repository.openNotebook(id: manifest.id).revision
        var oversized = makeTranscript(sessionID: sessionID, timeline: timeline, text: "valid")
        oversized.segments[0].text = String(
            repeating: "x",
            count: AudioTranscriptDocument.maximumTextUTF8BytesPerSegment + 1
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.saveAudioTranscript(
                oversized,
                notebookID: manifest.id,
                sessionID: sessionID
            )
        } verify: { error in
            XCTAssertTrue(error is NotebookRepositoryError)
        }
        var wrongSession = makeTranscript(sessionID: AudioSessionID(), timeline: timeline, text: "wrong")
        wrongSession.segments[0].timelineMarkID = nil
        wrongSession.segments[0].operationID = nil
        wrongSession.segments[0].pageID = nil
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.saveAudioTranscript(
                wrongSession,
                notebookID: manifest.id,
                sessionID: sessionID
            )
        }
        var toleratedTail = makeTranscript(
            sessionID: sessionID,
            timeline: timeline,
            text: "tail"
        )
        toleratedTail.segments[0].startTime = 1.9995
        toleratedTail.segments[0].duration = 0.001
        _ = try await repository.saveAudioTranscript(
            toleratedTail,
            notebookID: manifest.id,
            sessionID: sessionID
        )
        var unsorted = makeTranscript(
            sessionID: sessionID,
            timeline: timeline,
            text: "later"
        )
        unsorted.segments[0].startTime = 1
        unsorted.segments[0].duration = 0.1
        unsorted.segments[0].timelineMarkID = nil
        unsorted.segments[0].operationID = nil
        unsorted.segments[0].pageID = nil
        unsorted.segments.append(AudioTranscriptSegment(
            text: "earlier",
            startTime: 0.5,
            duration: 0.1,
            confidence: 1
        ))
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.saveAudioTranscript(
                unsorted,
                notebookID: manifest.id,
                sessionID: sessionID
            )
        }
        let futureSchemaData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "audioSessionID": ["rawValue": sessionID.rawValue.uuidString],
            "localeIdentifier": "en-US",
            "provenance": "speechTranscriber",
            "generatedAt": 0,
            "segments": [],
        ])
        let futureSchemaAsset = try await repository.importAsset(
            futureSchemaData,
            notebookID: manifest.id,
            mediaType: AudioTranscriptDocument.mediaType,
            originalFilename: "future-transcript.json"
        )
        _ = try await repository.updateAudioSession(
            notebookID: manifest.id,
            sessionID: sessionID,
            timeline: timeline,
            transcriptAssetID: futureSchemaAsset.id
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.loadAudioTranscript(
                notebookID: manifest.id,
                sessionID: sessionID
            )
        } verify: { error in
            guard let repositoryError = error as? NotebookRepositoryError,
                  case .invalidAudioTranscript = repositoryError else {
                return XCTFail("Expected invalidAudioTranscript, got \(error)")
            }
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.recoverNotebook(id: manifest.id)
        } verify: { error in
            guard let repositoryError = error as? NotebookRepositoryError,
                  case .malformedPackage(let detail) = repositoryError,
                  detail.contains("newer audio-transcript schema") else {
                return XCTFail("Expected future transcript schema preservation, got \(error)")
            }
        }
        let afterRejectedSaves = try await repository.openNotebook(id: manifest.id)
        XCTAssertGreaterThan(afterRejectedSaves.revision, revision)
    }

    func testTranscriptWrongMediaTypeIsRejectedByLoadRecoveryAndDedupSave() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(title: "Transcript MIME", initialPage: page)
        let sessionID = AudioSessionID()
        let timeline = makeTimeline(sessionID: sessionID, pageID: page.id, time: 0)
        _ = try await repository.addAudioSession(
            makeM4A(payload: "mime transcript"),
            timeline: timeline,
            notebookID: manifest.id,
            durationSeconds: 2,
            transcriptAssetID: nil
        )
        let payload = makeTranscript(sessionID: sessionID, timeline: timeline, text: "mime")
        _ = try await repository.saveAudioTranscript(
            payload,
            notebookID: manifest.id,
            sessionID: sessionID
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        let validManifestData = try Data(contentsOf: layout.manifestURL)
        let validManifestText = try XCTUnwrap(String(data: validManifestData, encoding: .utf8))
        let wrongMIMEManifestText = validManifestText.replacingOccurrences(
            of: AudioTranscriptDocument.mediaType,
            with: "application/octet-stream"
        )
        XCTAssertNotEqual(wrongMIMEManifestText, validManifestText)
        try Data(wrongMIMEManifestText.utf8).write(to: layout.manifestURL)

        let invalidValidation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(invalidValidation.issues.contains { $0.kind == .invalidAudioDescriptor })
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.loadAudioTranscript(
                notebookID: manifest.id,
                sessionID: sessionID
            )
        }

        let recovery = try await repository.recoverNotebook(id: manifest.id)
        XCTAssertTrue(recovery.actions.contains(.removedInvalidAssetReference))
        XCTAssertNil(recovery.manifest.audioSessions.first?.transcriptAssetID)
        XCTAssertTrue(recovery.validation.isValid)

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.saveAudioTranscript(
                payload,
                notebookID: manifest.id,
                sessionID: sessionID
            )
        } verify: { error in
            guard let repositoryError = error as? NotebookRepositoryError,
                  case .invalidAudioTranscript = repositoryError else {
                return XCTFail("Expected invalidAudioTranscript, got \(error)")
            }
        }
        let afterRejectedDedup = try await repository.openNotebook(id: manifest.id)
        XCTAssertNil(afterRejectedDedup.audioSessions.first?.transcriptAssetID)
    }

    func testCraftedTranscriptBoundCannotAuthorizeAssetDeletionJournal() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try await repository.createNotebook(title: "Journal guard")
        let asset = try await repository.importAsset(
            Data("must survive".utf8),
            notebookID: manifest.id,
            mediaType: "text/plain",
            originalFilename: "survive.txt"
        )
        let current = try await repository.openNotebook(id: manifest.id)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        let operationID = OperationID()
        let transactionDirectory = layout.transactionsURL.appendingPathComponent(
            operationID.description,
            isDirectory: true
        )
        let stagedDirectory = transactionDirectory.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagedDirectory,
            withIntermediateDirectories: true
        )
        try Data().write(to: stagedDirectory.appendingPathComponent("0000.data"))
        let journal: [String: Any] = [
            "schemaVersion": 1,
            "command": [
                "id": ["rawValue": operationID.rawValue.uuidString],
                "notebookID": ["rawValue": manifest.id.rawValue.uuidString],
                "actorID": "local",
                "sequence": current.revision,
                "timestamp": 0,
                "kind": "saveAudioTranscript",
                "payload": [:],
            ],
            "expectedRevision": current.revision - 1,
            "targetRevision": current.revision,
            "phase": "stateCommitted",
            "createdAt": 0,
            "files": [[
                "relativePath": "assets/\(asset.id.rawValue)",
                "stagedFilename": "staged/0000.data",
                "existedBeforeTransaction": true,
                "deletesTarget": true,
                "maximumByteCount": AudioTranscriptDocument.maximumEncodedBytes,
            ]],
            "cleanupDirectories": [],
        ]
        let journalData = try JSONSerialization.data(withJSONObject: journal)
        try journalData.write(to: transactionDirectory.appendingPathComponent("transaction.json"))

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.recoverNotebook(id: manifest.id)
        } verify: { error in
            guard let repositoryError = error as? NotebookRepositoryError,
                  case .malformedPackage = repositoryError else {
                return XCTFail("Expected a guarded malformed transaction, got \(error)")
            }
        }
        let assetURL = layout.assetURL(asset.id)
        XCTAssertEqual(try Data(contentsOf: assetURL), Data("must survive".utf8))
    }

    func testCraftedTranscriptJournalCannotInstallDataThatDoesNotMatchAssetID() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try await repository.createNotebook(title: "Journal digest guard")
        let current = try await repository.openNotebook(id: manifest.id)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        let operationID = OperationID()
        let claimedAssetID = String(repeating: "b", count: 64)
        let transactionDirectory = layout.transactionsURL.appendingPathComponent(
            operationID.description,
            isDirectory: true
        )
        let stagedDirectory = transactionDirectory.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagedDirectory,
            withIntermediateDirectories: true
        )
        try Data("not the claimed digest".utf8).write(
            to: stagedDirectory.appendingPathComponent("0000.data")
        )
        let journal: [String: Any] = [
            "schemaVersion": 1,
            "command": [
                "id": ["rawValue": operationID.rawValue.uuidString],
                "notebookID": ["rawValue": manifest.id.rawValue.uuidString],
                "actorID": "local",
                "sequence": current.revision,
                "timestamp": 0,
                "kind": "saveAudioTranscript",
                "payload": ["assetID": claimedAssetID],
            ],
            "expectedRevision": current.revision - 1,
            "targetRevision": current.revision,
            "phase": "stateCommitted",
            "createdAt": 0,
            "files": [[
                "relativePath": "assets/\(claimedAssetID)",
                "stagedFilename": "staged/0000.data",
                "existedBeforeTransaction": false,
                "maximumByteCount": AudioTranscriptDocument.maximumEncodedBytes,
            ]],
            "cleanupDirectories": [],
        ]
        try JSONSerialization.data(withJSONObject: journal).write(
            to: transactionDirectory.appendingPathComponent("transaction.json")
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.recoverNotebook(id: manifest.id)
        } verify: { error in
            guard let repositoryError = error as? NotebookRepositoryError,
                  case .malformedPackage = repositoryError else {
                return XCTFail("Expected a content-addressed transaction rejection, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: layout.assetURL(AssetID(claimedAssetID)).path
        ))
    }

    func testCraftedPreparedTranscriptJournalCannotRollbackReferencedAsset() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try await repository.createNotebook(title: "Journal rollback guard")
        let assetData = Data("referenced content address".utf8)
        let asset = try await repository.importAsset(
            assetData,
            notebookID: manifest.id,
            mediaType: "text/plain",
            originalFilename: "referenced.txt"
        )
        _ = try await repository.addPage(
            notebookID: manifest.id,
            page: PageDescriptor(background: .image(assetID: asset.id)),
            at: nil
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        let manifestData = try Data(contentsOf: layout.manifestURL)
        var manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        // Simulate a corrupt-but-recoverable manifest whose page still points to
        // the content-addressed bytes even though the asset descriptor was lost.
        manifestObject["assets"] = []
        try JSONSerialization.data(withJSONObject: manifestObject).write(to: layout.manifestURL)
        let current = try await repository.openNotebook(id: manifest.id)
        let operationID = OperationID()
        let transactionDirectory = layout.transactionsURL.appendingPathComponent(
            operationID.description,
            isDirectory: true
        )
        let stagedDirectory = transactionDirectory.appendingPathComponent("staged", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagedDirectory,
            withIntermediateDirectories: true
        )
        try assetData.write(to: stagedDirectory.appendingPathComponent("0000.data"))
        let journal: [String: Any] = [
            "schemaVersion": 1,
            "command": [
                "id": ["rawValue": operationID.rawValue.uuidString],
                "notebookID": ["rawValue": manifest.id.rawValue.uuidString],
                "actorID": "local",
                "sequence": current.revision + 1,
                "timestamp": 0,
                "kind": "saveAudioTranscript",
                "payload": ["assetID": asset.id.rawValue],
            ],
            "expectedRevision": current.revision,
            "targetRevision": current.revision + 1,
            "phase": "prepared",
            "createdAt": 0,
            "files": [[
                "relativePath": "assets/\(asset.id.rawValue)",
                "stagedFilename": "staged/0000.data",
                "existedBeforeTransaction": false,
                "maximumByteCount": AudioTranscriptDocument.maximumEncodedBytes,
            ]],
            "cleanupDirectories": [],
        ]
        try JSONSerialization.data(withJSONObject: journal).write(
            to: transactionDirectory.appendingPathComponent("transaction.json")
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.recoverNotebook(id: manifest.id)
        } verify: { error in
            guard let repositoryError = error as? NotebookRepositoryError,
                  case .malformedPackage = repositoryError else {
                return XCTFail("Expected referenced-asset rollback rejection, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: layout.assetURL(asset.id)), assetData)
    }

    func testAudioExportSessionReturnsCapturedDescriptorChunksAndTranscript() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor(title: "Exported recording")
        let manifest = try await repository.createNotebook(
            title: "Audio export",
            initialPage: page
        )
        let sessionID = AudioSessionID()
        let timeline = makeTimeline(sessionID: sessionID, pageID: page.id, time: 0.5)
        let audio = makeM4A(payload: "point-in-time audio bytes")
        _ = try await repository.addAudioSession(
            audio,
            timeline: timeline,
            notebookID: manifest.id,
            durationSeconds: 4,
            transcriptAssetID: nil
        )
        let transcript = makeTranscript(
            sessionID: sessionID,
            timeline: timeline,
            text: "Exported transcript"
        )
        let expectedDescriptor = try await repository.saveAudioTranscript(
            transcript,
            notebookID: manifest.id,
            sessionID: sessionID
        )

        let context = try await repository.beginNotebookExport(id: manifest.id)
        let exportedDescriptor = try await repository.audioSessionDescriptorForExport(
            session: context.session,
            sessionID: sessionID
        )
        XCTAssertEqual(exportedDescriptor, expectedDescriptor)
        XCTAssertEqual(
            context.manifest.audioSessions.first(where: { $0.id == sessionID }),
            expectedDescriptor
        )

        let splitOffset = 7
        let prefix = try await repository.loadAudioChunkForExport(
            session: context.session,
            sessionID: sessionID,
            offset: 0,
            maximumByteCount: splitOffset
        )
        let suffix = try await repository.loadAudioChunkForExport(
            session: context.session,
            sessionID: sessionID,
            offset: Int64(splitOffset),
            maximumByteCount: audio.count
        )
        var reconstructedAudio = prefix
        reconstructedAudio.append(suffix)
        XCTAssertEqual(reconstructedAudio, audio)
        let exportedTranscript = try await repository.loadAudioTranscriptForExport(
            session: context.session,
            sessionID: sessionID
        )
        XCTAssertEqual(exportedTranscript, transcript)

        await repository.endNotebookExport(context.session)
        let activeSessionCount = await repository.activeNotebookExportSessionCount()
        XCTAssertEqual(activeSessionCount, 0)
    }

    func testAudioExportSessionRejectsEndedAndForgedCapabilities() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(
            title: "Audio export capability",
            initialPage: page
        )
        let sessionID = AudioSessionID()
        let timeline = makeTimeline(sessionID: sessionID, pageID: page.id, time: 0.5)
        _ = try await repository.addAudioSession(
            makeM4A(payload: "capability audio"),
            timeline: timeline,
            notebookID: manifest.id,
            durationSeconds: 2,
            transcriptAssetID: nil
        )
        _ = try await repository.saveAudioTranscript(
            makeTranscript(sessionID: sessionID, timeline: timeline, text: "Capability transcript"),
            notebookID: manifest.id,
            sessionID: sessionID
        )

        let ended = try await repository.beginNotebookExport(id: manifest.id)
        await repository.endNotebookExport(ended.session)
        await assertAudioExportAPIsRejectInvalidSession(
            repository,
            session: ended.session,
            sessionID: sessionID
        )

        let active = try await repository.beginNotebookExport(id: manifest.id)
        let forged = NotebookExportSession(
            id: active.session.id,
            notebookID: active.session.notebookID
        )
        await assertAudioExportAPIsRejectInvalidSession(
            repository,
            session: forged,
            sessionID: sessionID
        )
        _ = try await repository.audioSessionDescriptorForExport(
            session: active.session,
            sessionID: sessionID
        )
        await repository.endNotebookExport(active.session)
        let activeSessionCount = await repository.activeNotebookExportSessionCount()
        XCTAssertEqual(activeSessionCount, 0)
    }

    func testAudioExportSessionManifestReplacementInvalidatesEveryReadAPI() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(
            title: "Audio export manifest fence",
            initialPage: page
        )
        let sessionID = AudioSessionID()
        let timeline = makeTimeline(sessionID: sessionID, pageID: page.id, time: 0.5)
        _ = try await repository.addAudioSession(
            makeM4A(payload: "manifest-fenced audio"),
            timeline: timeline,
            notebookID: manifest.id,
            durationSeconds: 2,
            transcriptAssetID: nil
        )
        _ = try await repository.saveAudioTranscript(
            makeTranscript(sessionID: sessionID, timeline: timeline, text: "Manifest-fenced transcript"),
            notebookID: manifest.id,
            sessionID: sessionID
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))

        let descriptorContext = try await repository.beginNotebookExport(id: manifest.id)
        try replaceManifestWithIdenticalBytes(at: layout.manifestURL)
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.audioSessionDescriptorForExport(
                session: descriptorContext.session,
                sessionID: sessionID
            )
        } verify: { error in
            XCTAssertEqual(error as? NotebookRepositoryError, .invalidExportSession)
        }

        let chunkContext = try await repository.beginNotebookExport(id: manifest.id)
        try replaceManifestWithIdenticalBytes(at: layout.manifestURL)
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.loadAudioChunkForExport(
                session: chunkContext.session,
                sessionID: sessionID,
                offset: 0,
                maximumByteCount: 4
            )
        } verify: { error in
            XCTAssertEqual(error as? NotebookRepositoryError, .invalidExportSession)
        }

        let transcriptContext = try await repository.beginNotebookExport(id: manifest.id)
        try replaceManifestWithIdenticalBytes(at: layout.manifestURL)
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.loadAudioTranscriptForExport(
                session: transcriptContext.session,
                sessionID: sessionID
            )
        } verify: { error in
            XCTAssertEqual(error as? NotebookRepositoryError, .invalidExportSession)
        }
        let activeSessionCount = await repository.activeNotebookExportSessionCount()
        XCTAssertEqual(activeSessionCount, 0)
    }

    func testAudioExportChunkRejectsContentIdenticalHardLink() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(
            title: "Hard-linked audio",
            initialPage: page
        )
        let sessionID = AudioSessionID()
        let timeline = makeTimeline(sessionID: sessionID, pageID: page.id, time: 0)
        let audio = makeM4A(payload: "same bytes, foreign inode ownership")
        let descriptor = try await repository.addAudioSession(
            audio,
            timeline: timeline,
            notebookID: manifest.id,
            durationSeconds: 2,
            transcriptAssetID: nil
        )
        let context = try await repository.beginNotebookExport(id: manifest.id)
        let original = try await repository.loadAudioChunkForExport(
            session: context.session,
            sessionID: sessionID,
            offset: 0,
            maximumByteCount: audio.count
        )
        XCTAssertEqual(original, audio)

        let filename = try XCTUnwrap(descriptor.chunkFilenames.first)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        let storedAudioURL = layout.audioSessionURL(sessionID)
        XCTAssertEqual(storedAudioURL.lastPathComponent, filename)
        let outsideURL = root.appendingPathComponent("outside-audio.m4a", isDirectory: false)
        try FileManager.default.copyItem(at: storedAudioURL, to: outsideURL)
        try FileManager.default.removeItem(at: storedAudioURL)
        try FileManager.default.linkItem(at: outsideURL, to: storedAudioURL)

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.loadAudioChunkForExport(
                session: context.session,
                sessionID: sessionID,
                offset: 0,
                maximumByteCount: audio.count
            )
        } verify: { error in
            guard let repositoryError = error as? NotebookRepositoryError,
                  case .corruptedFile(let path) = repositoryError else {
                return XCTFail("Expected a hard-linked audio file to be rejected, got \(error)")
            }
            XCTAssertTrue(path.hasSuffix(".m4a"))
        }
        await repository.endNotebookExport(context.session)
    }

    func testAudioSessionRoundTripUpdateSnapshotAndDelete() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor(title: "Recorded page")
        let manifest = try await repository.createNotebook(title: "Audio", initialPage: page)
        let sessionID = AudioSessionID()
        let firstTimeline = makeTimeline(sessionID: sessionID, pageID: page.id, time: 1.25)
        let audio = makeM4A(payload: "first recording")

        let descriptor = try await repository.addAudioSession(
            audio,
            timeline: firstTimeline,
            notebookID: manifest.id,
            durationSeconds: 8,
            transcriptAssetID: nil
        )
        XCTAssertEqual(descriptor.schemaVersion, 2)
        XCTAssertEqual(descriptor.audioByteCount, Int64(audio.count))
        XCTAssertEqual(descriptor.chunkFilenames, ["\(sessionID.description).m4a"])
        XCTAssertEqual(descriptor.timelineFilename, "\(sessionID.description).timeline.json")
        let brandChunk = try await repository.loadAudioChunk(
            notebookID: manifest.id,
            sessionID: sessionID,
            offset: 4,
            maximumByteCount: 4
        )
        XCTAssertEqual(brandChunk, Data("ftyp".utf8))
        let loadedFirstTimeline = try await repository.loadAudioTimeline(
            notebookID: manifest.id,
            sessionID: sessionID
        )
        XCTAssertEqual(loadedFirstTimeline, firstTimeline)

        var updatedTimeline = firstTimeline
        updatedTimeline.modifiedAt = Date(timeIntervalSinceReferenceDate: 900)
        updatedTimeline.marks.append(.init(
            operationID: OperationID(),
            pageID: page.id,
            timeSeconds: 7.5,
            createdAt: Date(timeIntervalSinceReferenceDate: 800)
        ))
        let updated = try await repository.updateAudioSession(
            notebookID: manifest.id,
            sessionID: sessionID,
            timeline: updatedTimeline,
            transcriptAssetID: nil
        )
        XCTAssertNil(updated.transcriptAssetID)
        let transcriptPayload = makeTranscript(
            sessionID: sessionID,
            timeline: updatedTimeline,
            text: "Transcript"
        )
        let transcriptDescriptor = try await repository.saveAudioTranscript(
            transcriptPayload,
            notebookID: manifest.id,
            sessionID: sessionID
        )
        XCTAssertNotNil(transcriptDescriptor.transcriptAssetID)
        let loadedUpdatedTimeline = try await repository.loadAudioTimeline(
            notebookID: manifest.id,
            sessionID: sessionID
        )
        XCTAssertEqual(loadedUpdatedTimeline, updatedTimeline)
        let liveValidation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(liveValidation.isValid)

        let snapshotURL = root.appendingPathComponent("snapshot.notepkg", isDirectory: true)
        _ = try await repository.exportSnapshot(id: manifest.id, to: snapshotURL)
        let snapshotRepository = try FileNotebookRepository(rootURL: root.appendingPathComponent("snapshot-library", isDirectory: true))
        let snapshotPackage = snapshotRepository.packageURL(for: manifest.id)
        try FileManager.default.moveItem(at: snapshotURL, to: snapshotPackage)
        let snapshotAudio = try await snapshotRepository.loadAudioChunk(
            notebookID: manifest.id,
            sessionID: sessionID,
            offset: 0,
            maximumByteCount: audio.count
        )
        XCTAssertEqual(snapshotAudio, audio)
        let snapshotValidation = try await snapshotRepository.validateNotebook(id: manifest.id)
        XCTAssertTrue(snapshotValidation.isValid)

        try await repository.deleteAudioSession(notebookID: manifest.id, sessionID: sessionID)
        let afterDelete = try await repository.openNotebook(id: manifest.id)
        XCTAssertTrue(afterDelete.audioSessions.isEmpty)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.audioSessionURL(sessionID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.audioTimelineURL(sessionID).path))
        let deletedValidation = try await repository.validateNotebook(id: manifest.id)
        let operations = try await repository.operationLog(notebookID: manifest.id)
        let operationKinds = operations.map(\.kind)
        XCTAssertTrue(deletedValidation.isValid)
        XCTAssertEqual(
            operationKinds,
            [.createNotebook, .addAudioSession, .updateAudioSession, .saveAudioTranscript, .deleteAudioSession]
        )
    }

    func testRecordedAudioPersistsExactReplayZeroAndRecoveryRejectsContradiction() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor(title: "Replay page")
        let manifest = try await repository.createNotebook(title: "Replay timing", initialPage: page)
        let sessionID = AudioSessionID()
        let recordingStartedAt = Date(timeIntervalSinceReferenceDate: 12_345)
        let markTime: TimeInterval = 1.25
        let timeline = AudioTimelineDocument(
            audioSessionID: sessionID,
            marks: [.init(
                operationID: OperationID(),
                pageID: page.id,
                timeSeconds: markTime,
                createdAt: recordingStartedAt.addingTimeInterval(markTime)
            )],
            modifiedAt: recordingStartedAt.addingTimeInterval(4)
        )
        let audio = makeM4A(payload: "exact replay timing")
        let source = root.appendingPathComponent("exact-replay-source.m4a", isDirectory: false)
        try audio.write(to: source, options: .atomic)

        let descriptor = try await repository.addRecordedAudioSession(
            from: source,
            maximumByteCount: Int64(audio.count),
            timeline: timeline,
            notebookID: manifest.id,
            durationSeconds: 4,
            recordingStartedAt: recordingStartedAt,
            transcriptAssetID: nil
        )
        XCTAssertEqual(descriptor.recordingStartedAt, recordingStartedAt)

        let relaunchedRepository = try FileNotebookRepository(rootURL: root)
        let relaunchedManifest = try await relaunchedRepository.openNotebook(id: manifest.id)
        XCTAssertEqual(relaunchedManifest.audioSessions.first?.recordingStartedAt, recordingStartedAt)
        let relaunchedTimeline = try await relaunchedRepository.loadAudioTimeline(
            notebookID: manifest.id,
            sessionID: sessionID
        )
        XCTAssertEqual(relaunchedTimeline, timeline)
        let relaunchedValidation = try await relaunchedRepository.validateNotebook(id: manifest.id)
        XCTAssertTrue(relaunchedValidation.isValid)

        let rejectedSessionID = AudioSessionID()
        var contradictoryTimeline = timeline
        contradictoryTimeline.audioSessionID = rejectedSessionID
        contradictoryTimeline.marks[0].createdAt = recordingStartedAt.addingTimeInterval(markTime + 0.01)
        await XCTAssertThrowsErrorAsync {
            _ = try await relaunchedRepository.addRecordedAudioSession(
                from: source,
                maximumByteCount: Int64(audio.count),
                timeline: contradictoryTimeline,
                notebookID: manifest.id,
                durationSeconds: 4,
                recordingStartedAt: recordingStartedAt,
                transcriptAssetID: nil
            )
        }
        let afterRejectedIngest = try await relaunchedRepository.openNotebook(id: manifest.id)
        XCTAssertEqual(afterRejectedIngest.audioSessions.map(\.id), [sessionID])

        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        var manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: layout.manifestURL)
            ) as? [String: Any]
        )
        var sessions = try XCTUnwrap(manifestObject["audioSessions"] as? [[String: Any]])
        XCTAssertNotNil(sessions[0]["recordingStartedAt"])

        sessions[0].removeValue(forKey: "recordingStartedAt")
        manifestObject["audioSessions"] = sessions
        try JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: layout.manifestURL, options: .atomic)
        let schema2WithoutReplayMetadata = try await relaunchedRepository.openNotebook(id: manifest.id)
        XCTAssertEqual(
            schema2WithoutReplayMetadata.audioSessions.first?.schemaVersion,
            2
        )
        XCTAssertNil(schema2WithoutReplayMetadata.audioSessions.first?.recordingStartedAt)
        let legacySchema2Validation = try await relaunchedRepository.validateNotebook(id: manifest.id)
        XCTAssertTrue(legacySchema2Validation.isValid)

        let contradictoryStart = recordingStartedAt.addingTimeInterval(10)
            .timeIntervalSinceReferenceDate
        let encodedContradictoryStart = String(contradictoryStart.bitPattern, radix: 16)
        sessions[0]["recordingStartedAt"] = "notes-date-v1:\(encodedContradictoryStart)"
        manifestObject["audioSessions"] = sessions
        try JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.prettyPrinted, .sortedKeys]
        ).write(to: layout.manifestURL, options: .atomic)

        let invalidReport = try await relaunchedRepository.validateNotebook(id: manifest.id)
        XCTAssertTrue(invalidReport.issues.contains { $0.kind == .audioTimelineMismatch })
        let recovery = try await relaunchedRepository.recoverNotebook(id: manifest.id)
        XCTAssertTrue(recovery.actions.contains(.removedInvalidAudioReplayMetadata))
        XCTAssertFalse(recovery.actions.contains(.removedInvalidAudioSession))
        XCTAssertEqual(recovery.manifest.audioSessions.map(\.id), [sessionID])
        XCTAssertNil(recovery.manifest.audioSessions.first?.recordingStartedAt)
        let recoveredAudio = try await relaunchedRepository.loadAudioChunk(
            notebookID: manifest.id,
            sessionID: sessionID,
            offset: 0,
            maximumByteCount: audio.count
        )
        XCTAssertEqual(recoveredAudio, audio)
        XCTAssertTrue(recovery.validation.isValid)
    }

    func testRecordedAudioReplayZeroUsesOneMillisecondTolerance() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor(title: "Replay tolerance")
        let manifest = try await repository.createNotebook(
            title: "Replay tolerance",
            initialPage: page
        )
        let recordingStartedAt = Date(timeIntervalSinceReferenceDate: 22_000)
        let audio = makeM4A(payload: "replay tolerance")
        let source = root.appendingPathComponent("replay-tolerance.m4a", isDirectory: false)
        try audio.write(to: source, options: .atomic)

        let acceptedID = AudioSessionID()
        let acceptedTimeline = AudioTimelineDocument(
            audioSessionID: acceptedID,
            marks: [.init(
                operationID: OperationID(),
                pageID: page.id,
                timeSeconds: 1,
                createdAt: recordingStartedAt.addingTimeInterval(1.0005)
            )],
            modifiedAt: recordingStartedAt.addingTimeInterval(2)
        )
        let accepted = try await repository.addRecordedAudioSession(
            from: source,
            maximumByteCount: Int64(audio.count),
            timeline: acceptedTimeline,
            notebookID: manifest.id,
            durationSeconds: 2,
            recordingStartedAt: recordingStartedAt,
            transcriptAssetID: nil
        )
        XCTAssertEqual(accepted.id, acceptedID)

        let rejectedID = AudioSessionID()
        let rejectedTimeline = AudioTimelineDocument(
            audioSessionID: rejectedID,
            marks: [.init(
                operationID: OperationID(),
                pageID: page.id,
                timeSeconds: 1,
                createdAt: recordingStartedAt.addingTimeInterval(1.0015)
            )],
            modifiedAt: recordingStartedAt.addingTimeInterval(2)
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.addRecordedAudioSession(
                from: source,
                maximumByteCount: Int64(audio.count),
                timeline: rejectedTimeline,
                notebookID: manifest.id,
                durationSeconds: 2,
                recordingStartedAt: recordingStartedAt,
                transcriptAssetID: nil
            )
        }
        let afterRejected = try await repository.openNotebook(id: manifest.id)
        XCTAssertEqual(afterRejected.audioSessions.map(\.id), [acceptedID])
    }

    func testAudioSessionRejectsDuplicateInvalidDataDurationAndTimelineMarks() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(title: "Audio validation", initialPage: page)
        let sessionID = AudioSessionID()
        let timeline = makeTimeline(sessionID: sessionID, pageID: page.id, time: 1)
        let audio = makeM4A(payload: "valid")
        _ = try await repository.addAudioSession(
            audio,
            timeline: timeline,
            notebookID: manifest.id,
            durationSeconds: 2,
            transcriptAssetID: nil
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.addAudioSession(
                audio,
                timeline: timeline,
                notebookID: manifest.id,
                durationSeconds: 2,
                transcriptAssetID: nil
            )
        } verify: { error in
            XCTAssertEqual(error as? NotebookRepositoryError, .duplicateAudioSession(sessionID))
        }

        let invalidSessionID = AudioSessionID()
        let invalidTimeline = makeTimeline(sessionID: invalidSessionID, pageID: page.id, time: 3)
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.addAudioSession(
                audio,
                timeline: invalidTimeline,
                notebookID: manifest.id,
                durationSeconds: 2,
                transcriptAssetID: nil
            )
        }
        var nonfiniteTimeline = makeTimeline(
            sessionID: AudioSessionID(),
            pageID: page.id,
            time: 0
        )
        nonfiniteTimeline.marks[0].timeSeconds = .infinity
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.addAudioSession(
                audio,
                timeline: nonfiniteTimeline,
                notebookID: manifest.id,
                durationSeconds: 2,
                transcriptAssetID: nil
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.addAudioSession(
                Data("not an m4a".utf8),
                timeline: makeTimeline(sessionID: AudioSessionID(), pageID: page.id, time: 0),
                notebookID: manifest.id,
                durationSeconds: 2,
                transcriptAssetID: nil
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.addAudioSession(
                audio,
                timeline: makeTimeline(sessionID: AudioSessionID(), pageID: page.id, time: 0),
                notebookID: manifest.id,
                durationSeconds: .infinity,
                transcriptAssetID: nil
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.loadAudioChunk(
                notebookID: manifest.id,
                sessionID: sessionID,
                offset: -1,
                maximumByteCount: 1
            )
        } verify: { error in
            XCTAssertEqual(error as? NotebookRepositoryError, .invalidAudioReadRange)
        }
        let pastEnd = try await repository.loadAudioChunk(
            notebookID: manifest.id,
            sessionID: sessionID,
            offset: .max,
            maximumByteCount: 1
        )
        XCTAssertTrue(pastEnd.isEmpty, "A huge offset must not overflow the pread offset calculation.")
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.loadAudioChunk(
                notebookID: manifest.id,
                sessionID: sessionID,
                offset: 0,
                maximumByteCount: 4 * 1_024 * 1_024 + 1
            )
        } verify: { error in
            XCTAssertEqual(error as? NotebookRepositoryError, .invalidAudioReadRange)
        }
    }

    func testTimelineCodableRejectsFutureSchemaAndNegativeOrNonfiniteTime() throws {
        let pageID = PageID()
        let mark = AudioTimelineMark(
            operationID: OperationID(),
            pageID: pageID,
            timeSeconds: 1,
            createdAt: Date(timeIntervalSinceReferenceDate: 10)
        )
        let encoded = try JSONEncoder().encode(mark)

        for replacement in [-1.0, Double.infinity] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            if replacement.isFinite {
                object["timeSeconds"] = replacement
                let data = try JSONSerialization.data(withJSONObject: object)
                XCTAssertThrowsError(try JSONDecoder().decode(AudioTimelineMark.self, from: data))
            }
        }

        var futureMark = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        futureMark["schemaVersion"] = AudioTimelineMark.currentSchemaVersion + 1
        XCTAssertThrowsError(try JSONDecoder().decode(
            AudioTimelineMark.self,
            from: try JSONSerialization.data(withJSONObject: futureMark)
        ))

        let document = AudioTimelineDocument(audioSessionID: AudioSessionID(), marks: [mark])
        var futureDocument = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any]
        )
        futureDocument["schemaVersion"] = AudioTimelineDocument.currentSchemaVersion + 1
        XCTAssertThrowsError(try JSONDecoder().decode(
            AudioTimelineDocument.self,
            from: try JSONSerialization.data(withJSONObject: futureDocument)
        ))

        let legacyID = AudioSessionID()
        let legacyDescriptor = AudioSessionDescriptor(
            schemaVersion: 1,
            id: legacyID,
            createdAt: Date(timeIntervalSinceReferenceDate: 1),
            modifiedAt: Date(timeIntervalSinceReferenceDate: 2),
            durationSeconds: 3,
            chunkFilenames: ["0001.m4a"]
        )
        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyDescriptor)) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "schemaVersion")
        let decodedLegacy = try JSONDecoder().decode(
            AudioSessionDescriptor.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        XCTAssertEqual(decodedLegacy.schemaVersion, 1)
        XCTAssertEqual(decodedLegacy.id, legacyID)
        XCTAssertNil(decodedLegacy.timelineFilename)
        XCTAssertNil(decodedLegacy.audioByteCount)
        XCTAssertNil(decodedLegacy.recordingStartedAt)
    }

    func testAddFailureBeforeManifestCommitRollsBackAudioAndTimeline() async throws {
        let (initialRepository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await initialRepository.createNotebook(title: "Audio rollback", initialPage: page)
        let failure = OneShotAudioStorageFailure(.beforeStateWrite(relativePath: "manifest.json"))
        let repository = try FileNotebookRepository(rootURL: root) { point in
            try failure.trigger(point)
        }
        let sessionID = AudioSessionID()

        do {
            _ = try await repository.addAudioSession(
                makeM4A(payload: "rollback"),
                timeline: makeTimeline(sessionID: sessionID, pageID: page.id, time: 0),
                notebookID: manifest.id,
                durationSeconds: 1,
                transcriptAssetID: nil
            )
            XCTFail("The injected manifest failure must be reported.")
        } catch is InjectedAudioStorageFailure {
            // Expected.
        }

        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.audioSessionURL(sessionID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.audioTimelineURL(sessionID).path))
        let afterFailure = try await repository.openNotebook(id: manifest.id)
        let rollbackValidation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(afterFailure.audioSessions.isEmpty)
        XCTAssertTrue(rollbackValidation.isValid)
    }

    func testCommittedAudioTransactionIsRecoveredAfterJournalPhaseFailure() async throws {
        let (initialRepository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await initialRepository.createNotebook(title: "Audio replay", initialPage: page)
        let failure = OneShotAudioStorageFailure(.beforeTransactionPhaseWrite)
        let repository = try FileNotebookRepository(rootURL: root) { point in
            try failure.trigger(point)
        }
        let sessionID = AudioSessionID()
        let audio = makeM4A(payload: "committed")
        _ = try await repository.addAudioSession(
            audio,
            timeline: makeTimeline(sessionID: sessionID, pageID: page.id, time: 0.5),
            notebookID: manifest.id,
            durationSeconds: 1,
            transcriptAssetID: nil
        )
        let pendingValidation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(pendingValidation.issues.contains {
            $0.kind == .pendingTransaction
        })

        let relaunched = try FileNotebookRepository(rootURL: root)
        let recovery = try await relaunched.recoverNotebook(id: manifest.id)
        XCTAssertTrue(recovery.actions.contains(.finalizedCommittedTransaction))
        XCTAssertTrue(recovery.validation.isValid, "Unexpected issues: \(recovery.validation.issues)")
        let recoveredAudio = try await relaunched.loadAudioChunk(
            notebookID: manifest.id,
            sessionID: sessionID,
            offset: 0,
            maximumByteCount: audio.count
        )
        XCTAssertEqual(recoveredAudio, audio)
    }

    func testDeleteFailureBeforeManifestCommitRestoresFilesAndDescriptor() async throws {
        let (initialRepository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await initialRepository.createNotebook(title: "Audio delete rollback", initialPage: page)
        let sessionID = AudioSessionID()
        let audio = makeM4A(payload: "keep me")
        _ = try await initialRepository.addAudioSession(
            audio,
            timeline: makeTimeline(sessionID: sessionID, pageID: page.id, time: 0),
            notebookID: manifest.id,
            durationSeconds: 1,
            transcriptAssetID: nil
        )
        let failure = OneShotAudioStorageFailure(.beforeStateWrite(relativePath: "manifest.json"))
        let repository = try FileNotebookRepository(rootURL: root) { point in
            try failure.trigger(point)
        }

        do {
            try await repository.deleteAudioSession(notebookID: manifest.id, sessionID: sessionID)
            XCTFail("The injected manifest failure must be reported.")
        } catch is InjectedAudioStorageFailure {
            // Expected.
        }
        let restoredManifest = try await repository.openNotebook(id: manifest.id)
        let restoredAudio = try await repository.loadAudioChunk(
            notebookID: manifest.id,
            sessionID: sessionID,
            offset: 0,
            maximumByteCount: audio.count
        )
        let restoredValidation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertEqual(restoredManifest.audioSessions.map(\.id), [sessionID])
        XCTAssertEqual(restoredAudio, audio)
        XCTAssertTrue(restoredValidation.isValid)
    }

    func testUpdateFailureBeforeManifestCommitRestoresTimelineAndDescriptor() async throws {
        let (initialRepository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await initialRepository.createNotebook(title: "Audio update rollback", initialPage: page)
        let sessionID = AudioSessionID()
        let originalTimeline = makeTimeline(sessionID: sessionID, pageID: page.id, time: 0)
        let originalDescriptor = try await initialRepository.addAudioSession(
            makeM4A(payload: "unchanged audio"),
            timeline: originalTimeline,
            notebookID: manifest.id,
            durationSeconds: 2,
            transcriptAssetID: nil
        )
        var replacementTimeline = originalTimeline
        replacementTimeline.modifiedAt = Date(timeIntervalSinceReferenceDate: 500)
        replacementTimeline.marks.append(.init(
            operationID: OperationID(),
            pageID: page.id,
            timeSeconds: 1
        ))
        let failure = OneShotAudioStorageFailure(.beforeStateWrite(relativePath: "manifest.json"))
        let repository = try FileNotebookRepository(rootURL: root) { point in
            try failure.trigger(point)
        }

        do {
            _ = try await repository.updateAudioSession(
                notebookID: manifest.id,
                sessionID: sessionID,
                timeline: replacementTimeline,
                transcriptAssetID: nil
            )
            XCTFail("The injected manifest failure must be reported.")
        } catch is InjectedAudioStorageFailure {
            // Expected.
        }

        let restoredTimeline = try await repository.loadAudioTimeline(
            notebookID: manifest.id,
            sessionID: sessionID
        )
        let restoredManifest = try await repository.openNotebook(id: manifest.id)
        let restoredValidation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertEqual(restoredTimeline, originalTimeline)
        XCTAssertEqual(restoredManifest.audioSessions, [originalDescriptor])
        XCTAssertTrue(restoredValidation.isValid)
    }

    func testDeletePreservesAudioFileStillReferencedByLegacySession() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(title: "Shared legacy audio", initialPage: page)
        let originalSessionID = AudioSessionID()
        let audio = makeM4A(payload: "shared recording")
        _ = try await repository.addAudioSession(
            audio,
            timeline: makeTimeline(sessionID: originalSessionID, pageID: page.id, time: 0),
            notebookID: manifest.id,
            durationSeconds: 1,
            transcriptAssetID: nil
        )

        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        var manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: layout.manifestURL)) as? [String: Any]
        )
        var sessions = try XCTUnwrap(manifestObject["audioSessions"] as? [[String: Any]])
        var legacySession = try XCTUnwrap(sessions.first)
        let legacySessionID = AudioSessionID()
        var encodedID = try XCTUnwrap(legacySession["id"] as? [String: Any])
        encodedID["rawValue"] = legacySessionID.description
        legacySession["id"] = encodedID
        legacySession["schemaVersion"] = 1
        legacySession.removeValue(forKey: "audioByteCount")
        legacySession.removeValue(forKey: "audioSHA256")
        legacySession.removeValue(forKey: "timelineFilename")
        sessions.append(legacySession)
        manifestObject["audioSessions"] = sessions
        try JSONSerialization.data(withJSONObject: manifestObject, options: [.sortedKeys]).write(
            to: layout.manifestURL,
            options: .atomic
        )

        let duplicateValidation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(duplicateValidation.issues.contains { $0.kind == .invalidAudioDescriptor })
        try await repository.deleteAudioSession(notebookID: manifest.id, sessionID: originalSessionID)

        let preservedAudio = try await repository.loadAudioChunk(
            notebookID: manifest.id,
            sessionID: legacySessionID,
            offset: 0,
            maximumByteCount: audio.count
        )
        XCTAssertEqual(preservedAudio, audio)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.audioSessionURL(originalSessionID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.audioTimelineURL(originalSessionID).path))
        let validation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(validation.isValid, "Unexpected issues: \(validation.issues)")
    }

    func testSymlinkAndFIFOAudioInputsAreRejectedWithoutFollowingThem() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(title: "Audio links", initialPage: page)
        let sessionID = AudioSessionID()
        _ = try await repository.addAudioSession(
            makeM4A(payload: "replace"),
            timeline: makeTimeline(sessionID: sessionID, pageID: page.id, time: 0),
            notebookID: manifest.id,
            durationSeconds: 1,
            transcriptAssetID: nil
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        let outside = root.appendingPathComponent("outside.m4a", isDirectory: false)
        let outsideData = makeM4A(payload: "outside must survive")
        try outsideData.write(to: outside)
        try FileManager.default.removeItem(at: layout.audioSessionURL(sessionID))
        try FileManager.default.createSymbolicLink(
            at: layout.audioSessionURL(sessionID),
            withDestinationURL: outside
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.loadAudioChunk(
                notebookID: manifest.id,
                sessionID: sessionID,
                offset: 0,
                maximumByteCount: 4
            )
        }
        let symlinkValidation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(symlinkValidation.issues.contains {
            $0.kind == .unreadableAudioFile
        })
        let recovery = try await repository.recoverNotebook(id: manifest.id)
        XCTAssertTrue(recovery.actions.contains(.removedInvalidAudioSession))
        XCTAssertEqual(try Data(contentsOf: outside), outsideData)
        XCTAssertTrue(recovery.validation.isValid)

        let orphanFIFO = layout.audioURL.appendingPathComponent("orphan.m4a", isDirectory: false)
        let fifoResult = orphanFIFO.path.withCString {
            Darwin.mkfifo($0, mode_t(S_IRUSR | S_IWUSR))
        }
        XCTAssertEqual(fifoResult, 0)
        let fifoValidation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(fifoValidation.issues.contains { $0.kind == .orphanAudioFile })
        let fifoRecovery = try await repository.recoverNotebook(id: manifest.id)
        XCTAssertTrue(fifoRecovery.actions.contains(.quarantinedOrphanAudio))
        XCTAssertTrue(fifoRecovery.validation.isValid)
    }

    func testOversizedAndDigestMismatchedAudioAreDetectedAndRecovered() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(title: "Audio corruption", initialPage: page)
        let sessionID = AudioSessionID()
        _ = try await repository.addAudioSession(
            makeM4A(payload: "digest"),
            timeline: makeTimeline(sessionID: sessionID, pageID: page.id, time: 0),
            notebookID: manifest.id,
            durationSeconds: 1,
            transcriptAssetID: nil
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        var corrupt = try Data(contentsOf: layout.audioSessionURL(sessionID))
        corrupt[corrupt.index(before: corrupt.endIndex)] ^= 0xff
        try corrupt.write(to: layout.audioSessionURL(sessionID), options: .atomic)
        let corruptValidation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(corruptValidation.issues.contains {
            $0.kind == .invalidAudioDigest
        })
        let digestRecovery = try await repository.recoverNotebook(id: manifest.id)
        XCTAssertTrue(digestRecovery.actions.contains(.removedInvalidAudioSession))
        XCTAssertTrue(digestRecovery.validation.isValid)
        let quarantinedEntries = try FileManager.default.contentsOfDirectory(
            at: layout.audioURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(quarantinedEntries.contains {
            $0.lastPathComponent.hasPrefix(".recovered-")
                && $0.lastPathComponent.hasSuffix(layout.audioSessionURL(sessionID).lastPathComponent)
        }, "Recovery must quarantine salvageable recording bytes rather than deleting them.")

        let oversizedTimeline = layout.audioURL.appendingPathComponent("orphan.timeline.json", isDirectory: false)
        try Data(repeating: 0x20, count: 4 * 1_024 * 1_024 + 1).write(to: oversizedTimeline)
        let oversizedValidation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(oversizedValidation.issues.contains {
            $0.kind == .orphanAudioFile
        })
        let oversizedRecovery = try await repository.recoverNotebook(id: manifest.id)
        XCTAssertTrue(oversizedRecovery.actions.contains(.quarantinedOrphanAudio))
        XCTAssertTrue(oversizedRecovery.validation.isValid)
    }

    func testRecoveryRetainsValidSessionAfterInvalidDuplicateDescriptor() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(title: "Recover duplicate audio", initialPage: page)
        let sessionID = AudioSessionID()
        let descriptor = try await repository.addAudioSession(
            makeM4A(payload: "recover the valid descriptor"),
            timeline: makeTimeline(sessionID: sessionID, pageID: page.id, time: 0),
            notebookID: manifest.id,
            durationSeconds: 1,
            transcriptAssetID: nil
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        var manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: layout.manifestURL)) as? [String: Any]
        )
        var sessions = try XCTUnwrap(manifestObject["audioSessions"] as? [[String: Any]])
        var invalidDuplicate = try XCTUnwrap(sessions.first)
        invalidDuplicate["audioSHA256"] = String(repeating: "0", count: 64)
        sessions.insert(invalidDuplicate, at: 0)
        manifestObject["audioSessions"] = sessions
        try JSONSerialization.data(withJSONObject: manifestObject, options: [.sortedKeys]).write(
            to: layout.manifestURL,
            options: .atomic
        )

        let recovery = try await repository.recoverNotebook(id: manifest.id)
        XCTAssertTrue(recovery.actions.contains(.removedInvalidAudioSession))
        XCTAssertEqual(recovery.manifest.audioSessions, [descriptor])
        XCTAssertTrue(recovery.validation.isValid, "Unexpected issues: \(recovery.validation.issues)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.audioSessionURL(sessionID).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.audioTimelineURL(sessionID).path))
    }

    func testMissingAndOversizedReferencedAudioFilesAreDetectedAndRecovered() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(title: "Audio file repair", initialPage: page)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))

        let missingAudioID = AudioSessionID()
        _ = try await repository.addAudioSession(
            makeM4A(payload: "will be missing"),
            timeline: makeTimeline(sessionID: missingAudioID, pageID: page.id, time: 0),
            notebookID: manifest.id,
            durationSeconds: 1,
            transcriptAssetID: nil
        )
        try FileManager.default.removeItem(at: layout.audioSessionURL(missingAudioID))
        let missingAudioValidation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(missingAudioValidation.issues.contains { $0.kind == .missingAudioFile })
        let missingAudioRecovery = try await repository.recoverNotebook(id: manifest.id)
        XCTAssertTrue(missingAudioRecovery.actions.contains(.removedInvalidAudioSession))
        XCTAssertTrue(missingAudioRecovery.validation.isValid)

        let missingTimelineID = AudioSessionID()
        _ = try await repository.addAudioSession(
            makeM4A(payload: "timeline will be missing"),
            timeline: makeTimeline(sessionID: missingTimelineID, pageID: page.id, time: 0),
            notebookID: manifest.id,
            durationSeconds: 1,
            transcriptAssetID: nil
        )
        try FileManager.default.removeItem(at: layout.audioTimelineURL(missingTimelineID))
        let missingTimelineValidation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(missingTimelineValidation.issues.contains { $0.kind == .missingAudioTimeline })
        let missingTimelineRecovery = try await repository.recoverNotebook(id: manifest.id)
        XCTAssertTrue(missingTimelineRecovery.actions.contains(.removedInvalidAudioSession))
        XCTAssertTrue(missingTimelineRecovery.validation.isValid)

        let oversizedTimelineID = AudioSessionID()
        _ = try await repository.addAudioSession(
            makeM4A(payload: "timeline will be oversized"),
            timeline: makeTimeline(sessionID: oversizedTimelineID, pageID: page.id, time: 0),
            notebookID: manifest.id,
            durationSeconds: 1,
            transcriptAssetID: nil
        )
        try Data(repeating: 0x20, count: 4 * 1_024 * 1_024 + 1).write(
            to: layout.audioTimelineURL(oversizedTimelineID),
            options: .atomic
        )
        let oversizedTimelineValidation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(oversizedTimelineValidation.issues.contains { $0.kind == .unreadableAudioTimeline })
        let oversizedTimelineRecovery = try await repository.recoverNotebook(id: manifest.id)
        XCTAssertTrue(oversizedTimelineRecovery.actions.contains(.removedInvalidAudioSession))
        XCTAssertTrue(oversizedTimelineRecovery.validation.isValid)

        let oversizedAudioID = AudioSessionID()
        _ = try await repository.addAudioSession(
            makeM4A(payload: "audio will be oversized"),
            timeline: makeTimeline(sessionID: oversizedAudioID, pageID: page.id, time: 0),
            notebookID: manifest.id,
            durationSeconds: 1,
            transcriptAssetID: nil
        )
        let oversizedAudioURL = layout.audioSessionURL(oversizedAudioID)
        let truncateResult = oversizedAudioURL.path.withCString {
            Darwin.truncate($0, off_t(512 * 1_024 * 1_024 + 1))
        }
        XCTAssertEqual(truncateResult, 0)
        let oversizedAudioValidation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(oversizedAudioValidation.issues.contains { $0.kind == .invalidAudioSize })
        let oversizedAudioRecovery = try await repository.recoverNotebook(id: manifest.id)
        XCTAssertTrue(oversizedAudioRecovery.actions.contains(.removedInvalidAudioSession))
        XCTAssertTrue(oversizedAudioRecovery.validation.isValid)
    }

    func testDeletingPageAtomicallyRemovesItsTimelineMarks() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstPage = PageDescriptor(title: "First")
        let manifest = try await repository.createNotebook(title: "Page-linked audio", initialPage: firstPage)
        let secondPage = PageDescriptor(title: "Second")
        _ = try await repository.addPage(notebookID: manifest.id, page: secondPage, at: nil)
        let sessionID = AudioSessionID()
        let timeline = AudioTimelineDocument(
            audioSessionID: sessionID,
            marks: [
                .init(operationID: OperationID(), pageID: firstPage.id, timeSeconds: 1),
                .init(operationID: OperationID(), pageID: secondPage.id, timeSeconds: 2)
            ]
        )
        _ = try await repository.addAudioSession(
            makeM4A(payload: "two pages"),
            timeline: timeline,
            notebookID: manifest.id,
            durationSeconds: 3,
            transcriptAssetID: nil
        )

        let failure = OneShotAudioStorageFailure(.beforeStateWrite(relativePath: "manifest.json"))
        let failingRepository = try FileNotebookRepository(rootURL: root) { point in
            try failure.trigger(point)
        }
        do {
            _ = try await failingRepository.deletePage(notebookID: manifest.id, pageID: firstPage.id)
            XCTFail("The injected manifest failure must be reported.")
        } catch is InjectedAudioStorageFailure {
            // Expected.
        }
        let rolledBackTimeline = try await repository.loadAudioTimeline(
            notebookID: manifest.id,
            sessionID: sessionID
        )
        let rolledBackManifest = try await repository.openNotebook(id: manifest.id)
        XCTAssertEqual(rolledBackTimeline.marks.map(\.pageID), [firstPage.id, secondPage.id])
        XCTAssertEqual(rolledBackManifest.pages.map(\.id), [firstPage.id, secondPage.id])

        _ = try await repository.deletePage(notebookID: manifest.id, pageID: firstPage.id)
        let filteredTimeline = try await repository.loadAudioTimeline(
            notebookID: manifest.id,
            sessionID: sessionID
        )
        XCTAssertEqual(filteredTimeline.marks.map(\.pageID), [secondPage.id])
        let validation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(validation.isValid)
    }

    func testFutureTimelineSchemaAbortsRecoveryWithoutMutatingPackage() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(title: "Future audio", initialPage: page)
        let sessionID = AudioSessionID()
        _ = try await repository.addAudioSession(
            makeM4A(payload: "future"),
            timeline: makeTimeline(sessionID: sessionID, pageID: page.id, time: 0),
            notebookID: manifest.id,
            durationSeconds: 1,
            transcriptAssetID: nil
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        let timelineURL = layout.audioTimelineURL(sessionID)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: timelineURL)) as? [String: Any]
        )
        object["schemaVersion"] = AudioTimelineDocument.currentSchemaVersion + 1
        object["marks"] = "malformed-unrelated-field"
        try JSONSerialization.data(withJSONObject: object).write(to: timelineURL, options: .atomic)
        let manifestBefore = try Data(contentsOf: layout.manifestURL)
        let audioBefore = try Data(contentsOf: layout.audioSessionURL(sessionID))
        let timelineBefore = try Data(contentsOf: timelineURL)

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.recoverNotebook(id: manifest.id)
        }
        XCTAssertEqual(try Data(contentsOf: layout.manifestURL), manifestBefore)
        XCTAssertEqual(try Data(contentsOf: layout.audioSessionURL(sessionID)), audioBefore)
        XCTAssertEqual(try Data(contentsOf: timelineURL), timelineBefore)
    }

    func testUnsafeAudioFilenameIsRejectedAndRecoveryDoesNotTouchEscapedPath() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(title: "Unsafe audio path", initialPage: page)
        let sessionID = AudioSessionID()
        _ = try await repository.addAudioSession(
            makeM4A(payload: "safe original"),
            timeline: makeTimeline(sessionID: sessionID, pageID: page.id, time: 0),
            notebookID: manifest.id,
            durationSeconds: 1,
            transcriptAssetID: nil
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        let escapedURL = layout.packageURL.appendingPathComponent("escaped.m4a", isDirectory: false)
        let escapedData = makeM4A(payload: "must not be read or removed")
        try escapedData.write(to: escapedURL)

        var manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: layout.manifestURL)) as? [String: Any]
        )
        var sessions = try XCTUnwrap(manifestObject["audioSessions"] as? [[String: Any]])
        sessions[0]["chunkFilenames"] = ["../escaped.m4a"]
        manifestObject["audioSessions"] = sessions
        try JSONSerialization.data(withJSONObject: manifestObject).write(
            to: layout.manifestURL,
            options: .atomic
        )

        let validation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(validation.issues.contains { $0.kind == .invalidAudioDescriptor })
        let recovery = try await repository.recoverNotebook(id: manifest.id)
        XCTAssertTrue(recovery.actions.contains(.removedInvalidAudioSession))
        XCTAssertEqual(try Data(contentsOf: escapedURL), escapedData)
        XCTAssertTrue(recovery.validation.isValid)
    }

    func testURLAudioIngestStreamsDigestBytesAndCommitsTimelineAtomically() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(title: "Streamed audio", initialPage: page)
        let sessionID = AudioSessionID()
        let source = root.appendingPathComponent("recording-source.m4a", isDirectory: false)
        let audio = makeM4A(payload: "streamed source")
        try audio.write(to: source)

        let descriptor = try await repository.addAudioSession(
            from: source,
            timeline: makeTimeline(sessionID: sessionID, pageID: page.id, time: 0.5),
            notebookID: manifest.id,
            durationSeconds: 2,
            transcriptAssetID: nil
        )

        XCTAssertEqual(descriptor.audioByteCount, 27)
        XCTAssertEqual(
            descriptor.audioSHA256,
            "92b1d4021867029cfe189d33d721333a0704ae11ccd1b45181a3a8ca3db77255"
        )
        let loaded = try await repository.loadAudioChunk(
            notebookID: manifest.id,
            sessionID: sessionID,
            offset: 0,
            maximumByteCount: audio.count
        )
        XCTAssertEqual(loaded, audio)
        let validation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(validation.isValid)
    }

    func testStreamingSHA256MatchesKnownPaddingAndBufferBoundaryVectors() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(title: "SHA boundaries", initialPage: page)
        let vectors: [(byteCount: Int, digest: String)] = [
            (55, "2df37dfac75f2f657cf2f2aa88f0dc9479ad1f4ae9f54ebfb034f79489ddddfe"),
            (56, "6cf0fe3311df774316ee075596c4db1330e146b1757a6b95cbc00515c18182f6"),
            (63, "ca8cfb0a5ea3b793a9565ed3e06004641e93d8b29c5032f6898d40cd7b3f5124"),
            (64, "586c86e2659b3d487c52c3342145c713a78634abc832256cc6f0ccd21932ba01"),
            (65, "51e7c817565feda933847354f23553281b01eea44c46e5ddcfef4d0863ec2c9b"),
            (65_535, "1b86f8a0f85828bb1db3473a57d64dce88e73a257d94f26f0f86e3afa6ee355c"),
            (65_536, "f5f05996b737bd80d93d3598cd53c3ae6e2dc63781f74e82ff3804312df89c35"),
            (65_537, "29883d4c7cb948a78ec262e03b9fa28602a1b6307262d148211499e9a53ee756")
        ]

        for vector in vectors {
            var audio = Data([0, 0, 0, 12])
            audio.append(contentsOf: "ftypM4A ".utf8)
            audio.append(contentsOf: (0..<(vector.byteCount - 12)).map { UInt8($0 % 251) })
            let source = root.appendingPathComponent("vector-\(vector.byteCount).m4a", isDirectory: false)
            try audio.write(to: source)
            let sessionID = AudioSessionID()
            let descriptor = try await repository.addAudioSession(
                from: source,
                timeline: makeTimeline(sessionID: sessionID, pageID: page.id, time: 0),
                notebookID: manifest.id,
                durationSeconds: 1,
                transcriptAssetID: nil
            )
            XCTAssertEqual(descriptor.audioByteCount, Int64(vector.byteCount))
            XCTAssertEqual(descriptor.audioSHA256, vector.digest, "Unexpected digest at \(vector.byteCount) bytes")
        }
        let validation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(validation.isValid)
    }

    func testURLAudioIngestEnforcesCallerByteLimitOnOpenedSource() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(title: "Caller limit", initialPage: page)
        let source = root.appendingPathComponent("caller-limit.m4a", isDirectory: false)
        let audio = makeM4A(payload: String(repeating: "bounded", count: 32))
        try audio.write(to: source)

        for invalidLimit in [Int64(0), Int64(512 * 1_024 * 1_024) + 1, Int64(audio.count - 1)] {
            let sessionID = AudioSessionID()
            await XCTAssertThrowsErrorAsync {
                _ = try await repository.addAudioSession(
                    from: source,
                    maximumByteCount: invalidLimit,
                    timeline: self.makeTimeline(sessionID: sessionID, pageID: page.id, time: 0),
                    notebookID: manifest.id,
                    durationSeconds: 1,
                    transcriptAssetID: nil
                )
            }
        }

        let acceptedSessionID = AudioSessionID()
        let descriptor = try await repository.addAudioSession(
            from: source,
            maximumByteCount: Int64(audio.count),
            timeline: makeTimeline(sessionID: acceptedSessionID, pageID: page.id, time: 0),
            notebookID: manifest.id,
            durationSeconds: 1,
            transcriptAssetID: nil
        )
        XCTAssertEqual(descriptor.audioByteCount, Int64(audio.count))
        let afterIngest = try await repository.openNotebook(id: manifest.id)
        XCTAssertEqual(afterIngest.audioSessions.map(\.id), [acceptedSessionID])
    }

    func testURLAudioIngestRejectsSymlinkFIFOHardlinkAndOversizedSparseSource() async throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(title: "Unsafe sources", initialPage: page)
        let regular = root.appendingPathComponent("regular.m4a", isDirectory: false)
        try makeM4A(payload: "regular source").write(to: regular)

        let symbolicLink = root.appendingPathComponent("linked.m4a", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: regular)
        let realDirectory = root.appendingPathComponent("real-source", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: false)
        try makeM4A(payload: "linked parent").write(
            to: realDirectory.appendingPathComponent("recording.m4a", isDirectory: false)
        )
        let linkedDirectory = root.appendingPathComponent("linked-source", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: realDirectory)
        let intermediateLink = linkedDirectory.appendingPathComponent("recording.m4a", isDirectory: false)
        let hardLink = root.appendingPathComponent("hard-linked.m4a", isDirectory: false)
        let hardLinkResult = regular.path.withCString { sourcePath in
            hardLink.path.withCString { destinationPath in
                Darwin.link(sourcePath, destinationPath)
            }
        }
        XCTAssertEqual(hardLinkResult, 0)
        let fifo = root.appendingPathComponent("recording.fifo", isDirectory: false)
        let fifoResult = fifo.path.withCString {
            Darwin.mkfifo($0, mode_t(S_IRUSR | S_IWUSR))
        }
        XCTAssertEqual(fifoResult, 0)
        let sparseWithinLimit = root.appendingPathComponent("sparse-within-limit.m4a", isDirectory: false)
        try makeM4A(payload: "sparse").write(to: sparseWithinLimit)
        let sparseWithinDescriptor = sparseWithinLimit.path.withCString {
            Darwin.open($0, O_WRONLY | O_CLOEXEC)
        }
        XCTAssertGreaterThanOrEqual(sparseWithinDescriptor, 0)
        XCTAssertEqual(Darwin.ftruncate(sparseWithinDescriptor, off_t(1 * 1_024 * 1_024)), 0)
        _ = Darwin.close(sparseWithinDescriptor)
        let sparse = root.appendingPathComponent("oversized-sparse.m4a", isDirectory: false)
        let sparseDescriptor = sparse.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        XCTAssertGreaterThanOrEqual(sparseDescriptor, 0)
        XCTAssertEqual(Darwin.ftruncate(sparseDescriptor, off_t(512 * 1_024 * 1_024 + 1)), 0)
        _ = Darwin.close(sparseDescriptor)

        for source in [symbolicLink, intermediateLink, fifo, hardLink, sparseWithinLimit, sparse] {
            let sessionID = AudioSessionID()
            await XCTAssertThrowsErrorAsync {
                _ = try await repository.addAudioSession(
                    from: source,
                    timeline: self.makeTimeline(sessionID: sessionID, pageID: page.id, time: 0),
                    notebookID: manifest.id,
                    durationSeconds: 1,
                    transcriptAssetID: nil
                )
            }
        }
        let afterRejections = try await repository.openNotebook(id: manifest.id)
        let validation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(afterRejections.audioSessions.isEmpty)
        XCTAssertTrue(validation.isValid)
    }

    func testURLAudioIngestDetectsSourceMutationAndCleansTransaction() async throws {
        let (_, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("mutating.m4a", isDirectory: false)
        var audio = makeM4A(payload: "mutation")
        audio.append(Data(repeating: 7, count: 256 * 1_024))
        try audio.write(to: source)
        let mutation = AudioSourceMutation(sourceURL: source)
        let repository = try FileNotebookRepository(rootURL: root) { point in
            try mutation.trigger(point)
        }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(title: "Mutating source", initialPage: page)
        let sessionID = AudioSessionID()

        await XCTAssertThrowsErrorAsync {
            _ = try await repository.addAudioSession(
                from: source,
                timeline: self.makeTimeline(sessionID: sessionID, pageID: page.id, time: 0),
                notebookID: manifest.id,
                durationSeconds: 1,
                transcriptAssetID: nil
            )
        }

        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.audioSessionURL(sessionID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.audioTimelineURL(sessionID).path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: layout.transactionsURL.path).isEmpty)
        let afterMutation = try await repository.openNotebook(id: manifest.id)
        XCTAssertTrue(afterMutation.audioSessions.isEmpty)
    }

    func testURLAudioIngestCancellationRemovesPartialStagingAndLeavesManifestUnchanged() async throws {
        let (_, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("cancelled.m4a", isDirectory: false)
        var audio = makeM4A(payload: "cancel")
        audio.append(Data(repeating: 3, count: 2 * 1_024 * 1_024))
        try audio.write(to: source)
        let gate = AudioCopyCancellationGate()
        let repository = try FileNotebookRepository(rootURL: root) { point in
            try gate.pauseOnce(point)
        }
        let page = PageDescriptor()
        let manifest = try await repository.createNotebook(title: "Cancelled source", initialPage: page)
        let sessionID = AudioSessionID()
        let timeline = makeTimeline(sessionID: sessionID, pageID: page.id, time: 0)
        let ingest = Task {
            try await repository.addAudioSession(
                from: source,
                timeline: timeline,
                notebookID: manifest.id,
                durationSeconds: 1,
                transcriptAssetID: nil
            )
        }
        for _ in 0..<5_000 where !gate.hasPaused {
            try? await Task<Never, Never>.sleep(nanoseconds: 1_000_000)
        }
        guard gate.hasPaused else {
            ingest.cancel()
            gate.resume()
            _ = try? await ingest.value
            XCTFail("The streaming ingest did not reach its staged copy pass.")
            return
        }
        ingest.cancel()
        gate.resume()
        do {
            _ = try await ingest.value
            XCTFail("A cancelled ingest must not commit.")
        } catch is CancellationError {
            // Expected.
        }

        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.audioSessionURL(sessionID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.audioTimelineURL(sessionID).path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: layout.transactionsURL.path).isEmpty)
        let afterCancellation = try await repository.openNotebook(id: manifest.id)
        XCTAssertTrue(afterCancellation.audioSessions.isEmpty)
    }
}

private extension AudioSessionRepositoryTests {
    func makeRepository() throws -> (FileNotebookRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NotesCoreAudioTests-\(UUID().uuidString)",
            isDirectory: true
        )
        return (try FileNotebookRepository(rootURL: root), root)
    }

    func makeM4A(payload: String) -> Data {
        var data = Data([0, 0, 0, 12])
        data.append(contentsOf: "ftypM4A ".utf8)
        data.append(contentsOf: payload.utf8)
        return data
    }

    func makeTimeline(
        sessionID: AudioSessionID,
        pageID: PageID,
        time: Double
    ) -> AudioTimelineDocument {
        AudioTimelineDocument(
            audioSessionID: sessionID,
            marks: [AudioTimelineMark(
                operationID: OperationID(),
                pageID: pageID,
                timeSeconds: time,
                createdAt: Date(timeIntervalSinceReferenceDate: 100)
            )],
            modifiedAt: Date(timeIntervalSinceReferenceDate: 200)
        )
    }

    func makeTranscript(
        sessionID: AudioSessionID,
        timeline: AudioTimelineDocument,
        text: String
    ) -> AudioTranscriptDocument {
        let mark = timeline.marks.first
        let mappedMark = mark.flatMap { $0.timeSeconds <= 0.5 ? $0 : nil }
        return AudioTranscriptDocument(
            audioSessionID: sessionID,
            localeIdentifier: "en-US",
            provenance: .speechTranscriber,
            generatedAt: Date(timeIntervalSinceReferenceDate: 300),
            segments: [AudioTranscriptSegment(
                text: text,
                startTime: 0.5,
                duration: 0.25,
                confidence: 0.9,
                timelineMarkID: mappedMark?.id,
                operationID: mappedMark?.operationID,
                pageID: mappedMark?.pageID
            )]
        )
    }

    func replaceManifestWithIdenticalBytes(at manifestURL: URL) throws {
        let data = try Data(contentsOf: manifestURL)
        try data.write(to: manifestURL, options: .atomic)
    }

    func assertAudioExportAPIsRejectInvalidSession(
        _ repository: FileNotebookRepository,
        session: NotebookExportSession,
        sessionID: AudioSessionID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.audioSessionDescriptorForExport(
                session: session,
                sessionID: sessionID
            )
        } verify: { error in
            XCTAssertEqual(
                error as? NotebookRepositoryError,
                .invalidExportSession,
                file: file,
                line: line
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.loadAudioChunkForExport(
                session: session,
                sessionID: sessionID,
                offset: 0,
                maximumByteCount: 4
            )
        } verify: { error in
            XCTAssertEqual(
                error as? NotebookRepositoryError,
                .invalidExportSession,
                file: file,
                line: line
            )
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await repository.loadAudioTranscriptForExport(
                session: session,
                sessionID: sessionID
            )
        } verify: { error in
            XCTAssertEqual(
                error as? NotebookRepositoryError,
                .invalidExportSession,
                file: file,
                line: line
            )
        }
    }

    func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> Void,
        verify: (Error) -> Void = { _ in }
    ) async {
        do {
            try await expression()
            XCTFail("Expected the asynchronous expression to throw.")
        } catch {
            verify(error)
        }
    }
}

private struct InjectedAudioStorageFailure: Error {}

private final class OneShotAudioStorageFailure: @unchecked Sendable {
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
        throw InjectedAudioStorageFailure()
    }
}

private final class AudioSourceMutation: @unchecked Sendable {
    private let lock = NSLock()
    private let sourceURL: URL
    private var hasMutated = false
    private var lastCopiedByteCount: Int64?
    private var reachedSecondPass = false

    init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    func trigger(_ point: StorageFailurePoint) throws {
        guard case .duringAudioSourceCopy(let bytesCopied) = point else { return }
        lock.lock()
        defer { lock.unlock() }
        if let lastCopiedByteCount, bytesCopied < lastCopiedByteCount {
            reachedSecondPass = true
        }
        lastCopiedByteCount = bytesCopied
        guard reachedSecondPass, !hasMutated else { return }
        hasMutated = true
        let descriptor = sourceURL.path.withCString {
            Darwin.open($0, O_WRONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw InjectedAudioStorageFailure() }
        defer { _ = Darwin.close(descriptor) }
        var replacement: UInt8 = 0x5a
        guard Darwin.pwrite(descriptor, &replacement, 1, 12) == 1 else {
            throw InjectedAudioStorageFailure()
        }
        _ = Darwin.fsync(descriptor)
    }
}

private final class AudioCopyCancellationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var released = false

    var hasPaused: Bool {
        condition.lock()
        defer { condition.unlock() }
        return paused
    }

    func pauseOnce(_ point: StorageFailurePoint) throws {
        guard point == .afterAudioSourceStaged else { return }
        condition.lock()
        guard !paused else {
            condition.unlock()
            return
        }
        paused = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func resume() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}
