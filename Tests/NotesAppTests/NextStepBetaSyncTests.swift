import CryptoKit
import Foundation
import NextStepDomain
import NextStepGrounding
import NextStepPlanning
import NextStepSync
@testable import NotesApp
import XCTest

final class NextStepBetaSyncTests: XCTestCase {
    func testStructuredArchiveAndImportedSourceRoundTripAcrossDevices() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let sourceBytes = Data("grounded source bytes".utf8)
        let storeA = NextStepBetaStore(rootURL: fixture.storeA)
        let storeB = NextStepBetaStore(rootURL: fixture.storeB)
        var archiveA = try await makeArchive(
            store: storeA,
            now: now,
            deadline: try LocalDay(year: 2028, month: 6, day: 30),
            sourceBytes: sourceBytes,
            exactExtract: "Assignment deadline: 2028-09-30"
        )
        let quizPackage = try XCTUnwrap(archiveA.workspace.guidedPackages.first)
        let quiz = try XCTUnwrap(quizPackage.quiz)
        let attempt = try NextStepBetaQuizGrader().grade(
            package: quizPackage,
            selections: Dictionary(uniqueKeysWithValues: quiz.items.map {
                ($0.id, Set($0.correctOptionIDs))
            }),
            attemptID: UUID(uuidString: "abababab-abab-abab-abab-abababababab")!,
            now: now,
            deviceID: archiveA.deviceID
        )
        archiveA.workspace.userResponses.append(contentsOf: attempt.responses)
        archiveA.workspace.revision += 1
        archiveA.workspace.savedAt = now
        let archiveB = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: now.addingTimeInterval(10),
            deviceID: NextStepDomain.DeviceID(),
            timeZoneIdentifier: "Asia/Taipei"
        )
        try await storeA.save(archiveA)
        try await storeB.save(archiveB)

        let engineA = try makeEngine(
            localRoot: fixture.engineA,
            remoteRoot: fixture.remote,
            deviceID: NextStepSync.DeviceID(
                UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
            ),
            now: now,
            libraryID: fixture.libraryID
        )
        let engineB = try makeEngine(
            localRoot: fixture.engineB,
            remoteRoot: fixture.remote,
            deviceID: NextStepSync.DeviceID(
                UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
            ),
            now: now.addingTimeInterval(20),
            libraryID: fixture.libraryID
        )

        _ = try await NextStepBetaSyncArchiveAdapter(
            engine: engineA,
            store: storeA
        ).reconcileInitial(localArchive: archiveA, now: now)
        let received = try await NextStepBetaSyncArchiveAdapter(
            engine: engineB,
            store: storeB
        ).reconcileInitial(localArchive: archiveB, now: now.addingTimeInterval(20))

        XCTAssertTrue(received.didReplaceLocalArchive)
        XCTAssertNil(received.pendingReview)
        XCTAssertEqual(received.archive.deviceID, archiveB.deviceID)
        XCTAssertNotEqual(received.archive.deviceID, archiveA.deviceID)
        XCTAssertEqual(
            received.archive.workspace.ultimateGoals.first?.targetDay?.value,
            try LocalDay(year: 2028, month: 6, day: 30)
        )
        let receivedDocument = try XCTUnwrap(received.archive.workspace.sourceDocuments.first)
        let relativePath = try XCTUnwrap(receivedDocument.localRelativePath)
        let installedBytes = try await storeB.storedSourceData(relativePath: relativePath)
        XCTAssertEqual(installedBytes, sourceBytes)
        XCTAssertEqual(
            receivedDocument.contentSHA256,
            SHA256.hash(data: sourceBytes).map { String(format: "%02x", $0) }.joined()
        )
        XCTAssertEqual(
            received.archive.workspace.userResponses,
            archiveA.workspace.userResponses
        )

        let sentBatch = try XCTUnwrap(archiveA.grounding.batches.first)
        let receivedBatch = try XCTUnwrap(received.archive.grounding.batches.first)
        XCTAssertEqual(received.archive.grounding.batches, archiveA.grounding.batches)
        XCTAssertEqual(receivedBatch, sentBatch)

        let sentPending = try XCTUnwrap(archiveA.grounding.pendingFacts.first)
        let receivedPending = try XCTUnwrap(received.archive.grounding.pendingFacts.first)
        XCTAssertEqual(sentPending.candidate.kind, .deadline)
        XCTAssertEqual(receivedPending.id, sentPending.id)
        XCTAssertEqual(receivedPending.candidate.anchorIDs, sentPending.candidate.anchorIDs)

        let anchorID = try XCTUnwrap(sentPending.candidate.anchorIDs.first)
        let sentAnchor = try XCTUnwrap(archiveA.workspace.sourceAnchors.first {
            $0.metadata.id == anchorID
        })
        let receivedAnchor = try XCTUnwrap(received.archive.workspace.sourceAnchors.first {
            $0.metadata.id == anchorID
        })
        XCTAssertEqual(receivedAnchor, sentAnchor)
    }

    func testLegacyV1SyncPayloadMigratesToCurrentSchemaWithEmptyGrounding() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = Date(timeIntervalSince1970: 1_760_500_000)
        let legacyArchive = try makeGoalOnlyArchive(
            now: now,
            deadline: try LocalDay(year: 2028, month: 6, day: 30)
        )
        let legacyPayload = LegacyNextStepBetaSyncPayloadV1(
            schemaVersion: 1,
            workspace: legacyArchive.workspace,
            currentDecisionID: legacyArchive.currentDecisionID
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let legacyData = try encoder.encode(legacyPayload)

        let publishingEngine = try makeEngine(
            localRoot: fixture.engineA,
            remoteRoot: fixture.remote,
            deviceID: NextStepSync.DeviceID(
                UUID(uuidString: "aaaaaaaa-aaaa-4444-8888-aaaaaaaaaaaa")!
            ),
            now: now,
            libraryID: fixture.libraryID
        )
        let workspaceEntity = try SyncEntityReference(
            kind: SyncKey("betaWorkspace"),
            id: UUID(uuidString: "0f8d9ea7-d17d-4f09-b566-09e3a3ec17b1")!
        )
        _ = try await publishingEngine.enqueueBlob(
            entity: workspaceEntity,
            field: SyncKey("archive"),
            data: legacyData,
            mediaType: "application/vnd.nextstep.beta-archive+json",
            policy: .flexibleLastWriterWins
        )
        _ = try await publishingEngine.synchronize()

        let receivingStore = NextStepBetaStore(rootURL: fixture.storeB)
        let receivingDeviceID = NextStepDomain.DeviceID(
            UUID(uuidString: "bbbbbbbb-bbbb-4444-8888-bbbbbbbbbbbb")!
        )
        let emptyLocalArchive = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: now.addingTimeInterval(10),
            deviceID: receivingDeviceID,
            timeZoneIdentifier: "Asia/Taipei"
        )
        try await receivingStore.save(emptyLocalArchive)
        let receivingEngine = try makeEngine(
            localRoot: fixture.engineB,
            remoteRoot: fixture.remote,
            deviceID: NextStepSync.DeviceID(
                UUID(uuidString: "bbbbbbbb-bbbb-5555-9999-bbbbbbbbbbbb")!
            ),
            now: now.addingTimeInterval(20),
            libraryID: fixture.libraryID
        )

        let migrated = try await NextStepBetaSyncArchiveAdapter(
            engine: receivingEngine,
            store: receivingStore
        ).reconcileInitial(
            localArchive: emptyLocalArchive,
            now: now.addingTimeInterval(20)
        )

        XCTAssertTrue(migrated.didReplaceLocalArchive)
        XCTAssertNil(migrated.pendingReview)
        XCTAssertEqual(migrated.archive.schemaVersion, NextStepBetaArchive.currentSchemaVersion)
        XCTAssertEqual(migrated.archive.deviceID, receivingDeviceID)
        XCTAssertEqual(migrated.archive.workspace, legacyArchive.workspace)
        XCTAssertEqual(migrated.archive.currentDecisionID, legacyArchive.currentDecisionID)
        XCTAssertEqual(migrated.archive.grounding, .empty)
        let storedValue = try await receivingStore.load()
        let stored = try XCTUnwrap(storedValue)
        XCTAssertEqual(stored.grounding, .empty)
    }

    func testConcurrentOfflineQuizAttemptsAndEvidenceConvergeByIDUnion() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = Date(timeIntervalSince1970: 1_761_000_000)
        let sourceBytes = Data("shared grounded source".utf8)
        let storeA = NextStepBetaStore(rootURL: fixture.storeA)
        let storeB = NextStepBetaStore(rootURL: fixture.storeB)
        var baseA = try await makeArchive(
            store: storeA,
            now: now,
            deadline: try LocalDay(year: 2028, month: 6, day: 30),
            sourceBytes: sourceBytes
        )
        let actionID = try XCTUnwrap(baseA.workspace.dailyActions.first?.metadata.id)
        baseA.workspace = try ExecutionService().startAction(
            actionID,
            in: baseA.workspace,
            at: now.addingTimeInterval(1)
        )
        var baseB = baseA
        baseB.deviceID = NextStepDomain.DeviceID(
            UUID(uuidString: "bbbbbbbb-1111-2222-3333-444444444444")!
        )
        let document = try XCTUnwrap(baseB.workspace.sourceDocuments.first)
        let relativePath = try XCTUnwrap(document.localRelativePath)
        let expectedSHA256 = try XCTUnwrap(document.contentSHA256)
        try await storeB.installSyncedSource(
            sourceBytes,
            relativePath: relativePath,
            expectedSHA256: expectedSHA256
        )
        try await storeA.save(baseA)
        try await storeB.save(baseB)

        let engineA = try makeEngine(
            localRoot: fixture.engineA,
            remoteRoot: fixture.remote,
            deviceID: NextStepSync.DeviceID(
                UUID(uuidString: "aaaaaaaa-1111-2222-3333-444444444444")!
            ),
            now: now,
            libraryID: fixture.libraryID
        )
        let engineB = try makeEngine(
            localRoot: fixture.engineB,
            remoteRoot: fixture.remote,
            deviceID: NextStepSync.DeviceID(
                UUID(uuidString: "bbbbbbbb-5555-6666-7777-888888888888")!
            ),
            now: now.addingTimeInterval(2),
            libraryID: fixture.libraryID
        )
        let adapterA = NextStepBetaSyncArchiveAdapter(engine: engineA, store: storeA)
        let adapterB = NextStepBetaSyncArchiveAdapter(engine: engineB, store: storeB)

        _ = try await adapterA.reconcileInitial(localArchive: baseA, now: now)
        _ = try await adapterB.reconcileInitial(
            localArchive: baseB,
            now: now.addingTimeInterval(2)
        )

        let attemptA = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let attemptB = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
        let branchA = try addingPassingQuizAttempt(
            to: baseA,
            attemptID: attemptA,
            now: now.addingTimeInterval(10)
        )
        let branchB = try addingPassingQuizAttempt(
            to: baseB,
            attemptID: attemptB,
            now: now.addingTimeInterval(20)
        )
        try await storeA.save(branchA)
        try await storeB.save(branchB)

        let offlineRemote = fixture.root.appendingPathComponent(
            "remote-while-offline",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: fixture.remote, to: offlineRemote)
        defer {
            if FileManager.default.fileExists(atPath: offlineRemote.path),
               FileManager.default.fileExists(atPath: fixture.remote.path) == false {
                try? FileManager.default.moveItem(at: offlineRemote, to: fixture.remote)
            }
        }
        do {
            _ = try await adapterA.publishLocalAndSynchronize(
                branchA,
                now: now.addingTimeInterval(30)
            )
            XCTFail("The first offline branch must remain queued locally.")
        } catch NextStepSyncError.transportUnavailable {
            // The immutable records and archive operation remain durable locally.
        }
        do {
            _ = try await adapterB.publishLocalAndSynchronize(
                branchB,
                now: now.addingTimeInterval(40)
            )
            XCTFail("The second offline branch must remain queued locally.")
        } catch NextStepSyncError.transportUnavailable {
            // The immutable records and archive operation remain durable locally.
        }
        let pendingA = try await engineA.pendingOperationCount()
        let pendingB = try await engineB.pendingOperationCount()
        XCTAssertEqual(pendingA, 1)
        XCTAssertEqual(pendingB, 1)
        try FileManager.default.moveItem(at: offlineRemote, to: fixture.remote)

        let firstA = try await adapterA.reconcileInitial(
            localArchive: branchA,
            now: now.addingTimeInterval(50)
        )
        let firstB = try await adapterB.reconcileInitial(
            localArchive: branchB,
            now: now.addingTimeInterval(60)
        )
        let convergedA = try await adapterA.reconcileInitial(
            localArchive: firstA.archive,
            now: now.addingTimeInterval(70)
        )
        let convergedB = try await adapterB.reconcileInitial(
            localArchive: firstB.archive,
            now: now.addingTimeInterval(80)
        )

        let expectedAttempts = Set([attemptA, attemptB])
        for archive in [convergedA.archive, convergedB.archive] {
            XCTAssertEqual(
                Set(archive.workspace.userResponses.map(\.attemptID)),
                expectedAttempts
            )
            XCTAssertEqual(
                Set(archive.workspace.completionEvidence.compactMap {
                    $0.quizResult?.attemptID
                }),
                expectedAttempts
            )
            XCTAssertEqual(archive.workspace.userResponses.count, 2)
            XCTAssertEqual(archive.workspace.completionEvidence.count, 2)
            XCTAssertNoThrow(try archive.validate())
        }
        let storedAValue = try await storeA.load()
        let storedBValue = try await storeB.load()
        let storedA = try XCTUnwrap(storedAValue)
        let storedB = try XCTUnwrap(storedBValue)
        XCTAssertEqual(Set(storedA.workspace.userResponses.map(\.attemptID)), expectedAttempts)
        XCTAssertEqual(Set(storedB.workspace.userResponses.map(\.attemptID)), expectedAttempts)
    }

    func testConcurrentRejectedGroundingCandidateAndQuizAttemptConverge() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = Date(timeIntervalSince1970: 1_761_500_000)
        let sourceBytes = Data("shared deadline candidate".utf8)
        let storeA = NextStepBetaStore(rootURL: fixture.storeA)
        let storeB = NextStepBetaStore(rootURL: fixture.storeB)
        let baseA = try await makeArchive(
            store: storeA,
            now: now,
            deadline: try LocalDay(year: 2028, month: 6, day: 30),
            sourceBytes: sourceBytes,
            exactExtract: "Assignment deadline: 2028-09-30"
        )
        let pending = try XCTUnwrap(baseA.grounding.pendingFacts.first)
        XCTAssertEqual(pending.candidate.kind, .deadline)

        var baseB = baseA
        baseB.deviceID = NextStepDomain.DeviceID(
            UUID(uuidString: "bbbbbbbb-2222-3333-4444-555555555555")!
        )
        let document = try XCTUnwrap(baseB.workspace.sourceDocuments.first)
        let relativePath = try XCTUnwrap(document.localRelativePath)
        let expectedSHA256 = try XCTUnwrap(document.contentSHA256)
        try await storeB.installSyncedSource(
            sourceBytes,
            relativePath: relativePath,
            expectedSHA256: expectedSHA256
        )
        try await storeA.save(baseA)
        try await storeB.save(baseB)

        let engineA = try makeEngine(
            localRoot: fixture.engineA,
            remoteRoot: fixture.remote,
            deviceID: NextStepSync.DeviceID(
                UUID(uuidString: "aaaaaaaa-2222-3333-4444-555555555555")!
            ),
            now: now,
            libraryID: fixture.libraryID
        )
        let engineB = try makeEngine(
            localRoot: fixture.engineB,
            remoteRoot: fixture.remote,
            deviceID: NextStepSync.DeviceID(
                UUID(uuidString: "bbbbbbbb-6666-7777-8888-999999999999")!
            ),
            now: now.addingTimeInterval(2),
            libraryID: fixture.libraryID
        )
        let adapterA = NextStepBetaSyncArchiveAdapter(engine: engineA, store: storeA)
        let adapterB = NextStepBetaSyncArchiveAdapter(engine: engineB, store: storeB)
        _ = try await adapterA.reconcileInitial(localArchive: baseA, now: now)
        _ = try await adapterB.reconcileInitial(
            localArchive: baseB,
            now: now.addingTimeInterval(2)
        )

        let rejectedBranch = try NextStepBetaSourceFactReviewCoordinator().reject(
            candidateID: pending.id,
            reason: "The syllabus date was superseded.",
            archive: baseA,
            now: now.addingTimeInterval(10)
        )
        let quizAttemptID = UUID(uuidString: "cccccccc-2222-3333-4444-555555555555")!
        let quizBranch = try addingPassingQuizAttempt(
            to: baseB,
            attemptID: quizAttemptID,
            now: now.addingTimeInterval(20)
        )
        try await storeA.save(rejectedBranch)
        try await storeB.save(quizBranch)

        let firstA = try await adapterA.publishLocalAndSynchronize(
            rejectedBranch,
            now: now.addingTimeInterval(30)
        )
        let firstB = try await adapterB.publishLocalAndSynchronize(
            quizBranch,
            now: now.addingTimeInterval(40)
        )
        let convergedA = try await adapterA.reconcileInitial(
            localArchive: firstA.archive,
            now: now.addingTimeInterval(50)
        )
        let convergedB = try await adapterB.reconcileInitial(
            localArchive: firstB.archive,
            now: now.addingTimeInterval(60)
        )

        for archive in [convergedA.archive, convergedB.archive] {
            let audit = try XCTUnwrap(archive.grounding.reviewAudits.first)
            XCTAssertEqual(archive.grounding.reviewAudits.count, 1)
            XCTAssertEqual(audit.candidateID, pending.id)
            XCTAssertEqual(audit.disposition, .rejected)
            XCTAssertTrue(archive.grounding.pendingFacts.isEmpty)
            XCTAssertTrue(archive.grounding.confirmedDateFacts.isEmpty)
            XCTAssertEqual(
                Set(archive.workspace.userResponses.map(\.attemptID)),
                Set([quizAttemptID])
            )
            XCTAssertEqual(
                Set(archive.workspace.completionEvidence.compactMap {
                    $0.quizResult?.attemptID
                }),
                Set([quizAttemptID])
            )
            XCTAssertNoThrow(try archive.validate())
        }
    }

    func testOrdinaryDateConfirmationAndQuizAttemptMergeWithGroundingEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nextstep-beta-date-union-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_761_750_000)
        let store = NextStepBetaStore(rootURL: root)
        let base = try await makeArchive(
            store: store,
            now: now,
            deadline: try LocalDay(year: 2028, month: 6, day: 30),
            sourceBytes: Data("ordinary date candidate".utf8),
            exactExtract: "Lecture date: 2028-09-30"
        )
        let pending = try XCTUnwrap(base.grounding.pendingFacts.first)
        XCTAssertEqual(pending.candidate.kind, .date)
        let preview = try NextStepBetaSourceFactReviewCoordinator().makePreview(
            candidateID: pending.id,
            archive: base,
            now: now.addingTimeInterval(10)
        )
        let confirmedBranch = try NextStepBetaSourceFactReviewCoordinator().accept(
            preview,
            archive: base,
            now: now.addingTimeInterval(11)
        )
        let quizAttemptID = UUID(uuidString: "dddddddd-2222-3333-4444-555555555555")!
        let quizBranch = try addingPassingQuizAttempt(
            to: base,
            attemptID: quizAttemptID,
            now: now.addingTimeInterval(20)
        )

        let mergedValue = try NextStepBetaSyncArchiveAdapter.mergeImmutableExecutionRecords(
            localArchive: confirmedBranch,
            syncedArchive: quizBranch,
            now: now.addingTimeInterval(30)
        )
        let merged = try XCTUnwrap(mergedValue)
        let audit = try XCTUnwrap(merged.grounding.reviewAudits.first)
        let fact = try XCTUnwrap(merged.grounding.confirmedDateFacts.first)
        XCTAssertEqual(audit.disposition, .confirmed)
        XCTAssertEqual(audit.candidateID, pending.id)
        XCTAssertEqual(fact.candidateID, pending.id)
        XCTAssertEqual(fact.kind, .date)
        XCTAssertEqual(
            Set(audit.evidenceLinkIDs),
            Set(merged.workspace.evidenceLinks.filter {
                $0.subjectType == "ConfirmedSourceDateFact" && $0.subjectID == fact.id
            }.map(\.metadata.id))
        )
        XCTAssertEqual(
            Set(merged.workspace.userResponses.map(\.attemptID)),
            Set([quizAttemptID])
        )
        XCTAssertEqual(
            Set(merged.workspace.completionEvidence.compactMap { $0.quizResult?.attemptID }),
            Set([quizAttemptID])
        )
        XCTAssertNoThrow(try merged.validate())

        let rejectedBranch = try NextStepBetaSourceFactReviewCoordinator().reject(
            candidateID: pending.id,
            reason: "This was not the relevant lecture date.",
            archive: base,
            now: now.addingTimeInterval(40)
        )
        XCTAssertThrowsError(try NextStepBetaSyncArchiveAdapter
            .mergeImmutableExecutionRecords(
                localArchive: confirmedBranch,
                syncedArchive: rejectedBranch,
                now: now.addingTimeInterval(50)
            )) { error in
                XCTAssertEqual(
                    error as? NextStepBetaImmutableMergeError,
                    .conflictingGroundingCandidate(pending.id)
                )
            }

        let originalAudit = try XCTUnwrap(rejectedBranch.grounding.reviewAudits.first)
        let collidingAudit = try SourceFactReviewAudit(
            metadata: originalAudit.metadata,
            candidateID: originalAudit.candidateID,
            disposition: originalAudit.disposition,
            sourceDocumentID: originalAudit.sourceDocumentID,
            sourceSHA256: originalAudit.sourceSHA256,
            anchorIDs: originalAudit.anchorIDs,
            parseRequestID: originalAudit.parseRequestID,
            parser: originalAudit.parser,
            confirmedFactID: originalAudit.confirmedFactID,
            evidenceLinkIDs: originalAudit.evidenceLinkIDs,
            reason: "A different rejection reason with the same audit ID."
        )
        var collidingArchive = base
        collidingArchive.grounding.reviewAudits = [collidingAudit]
        collidingArchive.workspace.revision += 1
        collidingArchive.workspace.savedAt = now.addingTimeInterval(60)
        try collidingArchive.validate()
        XCTAssertThrowsError(try NextStepBetaSyncArchiveAdapter
            .mergeImmutableExecutionRecords(
                localArchive: rejectedBranch,
                syncedArchive: collidingArchive,
                now: now.addingTimeInterval(70)
            )) { error in
                XCTAssertEqual(
                    error as? NextStepBetaImmutableMergeError,
                    .conflictingGroundingAudit(originalAudit.id)
                )
            }
    }

    func testDeadlineConfirmationStaysInMutableBaseAndConflictingOutcomeFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nextstep-beta-deadline-base-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_761_900_000)
        let store = NextStepBetaStore(rootURL: root)
        let base = try await makeArchive(
            store: store,
            now: now,
            deadline: try LocalDay(year: 2028, month: 6, day: 30),
            sourceBytes: Data("deadline merge guard".utf8),
            exactExtract: "Assignment deadline: 2028-09-30"
        )
        let pending = try XCTUnwrap(base.grounding.pendingFacts.first)
        XCTAssertEqual(pending.candidate.kind, .deadline)
        let preview = try NextStepBetaSourceFactReviewCoordinator().makePreview(
            candidateID: pending.id,
            archive: base,
            now: now.addingTimeInterval(10)
        )
        let confirmedBranch = try NextStepBetaSourceFactReviewCoordinator().accept(
            preview,
            archive: base,
            now: now.addingTimeInterval(11)
        )

        let evidenceIDs = Set(
            confirmedBranch.grounding.reviewAudits.flatMap(\.evidenceLinkIDs)
        )
        let groundingEvidence = confirmedBranch.workspace.evidenceLinks.filter {
            evidenceIDs.contains($0.metadata.id)
        }
        var detachedDeadlineFact = confirmedBranch
        detachedDeadlineFact.workspace = base.workspace
        detachedDeadlineFact.workspace.evidenceLinks.append(contentsOf: groundingEvidence)
        detachedDeadlineFact.workspace.revision = confirmedBranch.workspace.revision
        detachedDeadlineFact.workspace.savedAt = confirmedBranch.workspace.savedAt
        detachedDeadlineFact.currentDecisionID = base.currentDecisionID
        XCTAssertThrowsError(try detachedDeadlineFact.validate())

        let quizBranch = try addingPassingQuizAttempt(
            to: base,
            attemptID: UUID(uuidString: "eeeeeeee-2222-3333-4444-555555555555")!,
            now: now.addingTimeInterval(20)
        )
        XCTAssertNil(try NextStepBetaSyncArchiveAdapter.mergeImmutableExecutionRecords(
            localArchive: confirmedBranch,
            syncedArchive: quizBranch,
            now: now.addingTimeInterval(30)
        ))

        let rejectedBranch = try NextStepBetaSourceFactReviewCoordinator().reject(
            candidateID: pending.id,
            reason: "The confirmed deadline was disputed on another device.",
            archive: base,
            now: now.addingTimeInterval(40)
        )
        XCTAssertThrowsError(try NextStepBetaSyncArchiveAdapter
            .mergeImmutableExecutionRecords(
                localArchive: confirmedBranch,
                syncedArchive: rejectedBranch,
                now: now.addingTimeInterval(50)
            )) { error in
                XCTAssertEqual(
                    error as? NextStepBetaImmutableMergeError,
                    .conflictingGroundingCandidate(pending.id)
                )
            }
    }

    func testRepeatedSafeUnionPreservesRetainedDeadlineRecordOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nextstep-beta-retained-order-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_761_950_000)
        let store = NextStepBetaStore(rootURL: root)
        var deadlineBase = try await makeArchive(
            store: store,
            now: now,
            deadline: try LocalDay(year: 2028, month: 6, day: 30),
            sourceBytes: Data("retained deadline ordering".utf8),
            exactExtract: "Assignment deadline: 2028-09-30; "
                + "Assignment deadline: 2028-10-15; Lecture date: 2028-11-01"
        )
        XCTAssertEqual(
            deadlineBase.grounding.pendingFacts.filter { $0.candidate.kind == .deadline }.count,
            2
        )
        XCTAssertEqual(
            deadlineBase.grounding.pendingFacts.filter { $0.candidate.kind == .date }.count,
            1
        )

        for offset in [10.0, 20.0] {
            let pendingDeadline = try XCTUnwrap(deadlineBase.grounding.pendingFacts.first {
                $0.candidate.kind == .deadline
            })
            let preview = try NextStepBetaSourceFactReviewCoordinator().makePreview(
                candidateID: pendingDeadline.id,
                archive: deadlineBase,
                now: now.addingTimeInterval(offset)
            )
            deadlineBase = try NextStepBetaSourceFactReviewCoordinator().accept(
                preview,
                archive: deadlineBase,
                now: now.addingTimeInterval(offset + 1)
            )
        }
        deadlineBase.grounding.reviewAudits.sort {
            $0.id.uuidString.lowercased() > $1.id.uuidString.lowercased()
        }
        deadlineBase.grounding.confirmedDateFacts.sort {
            $0.id.uuidString.lowercased() > $1.id.uuidString.lowercased()
        }
        try deadlineBase.validate()
        let retainedAuditOrder = deadlineBase.grounding.reviewAudits.map(\.id)
        let retainedFactOrder = deadlineBase.grounding.confirmedDateFacts.map(\.id)

        let pendingDate = try XCTUnwrap(deadlineBase.grounding.pendingFacts.first {
            $0.candidate.kind == .date
        })
        let rejectedBranch = try NextStepBetaSourceFactReviewCoordinator().reject(
            candidateID: pendingDate.id,
            reason: "This date is unrelated to the plan.",
            archive: deadlineBase,
            now: now.addingTimeInterval(30)
        )
        let firstAttemptID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let firstQuizBranch = try addingPassingQuizAttempt(
            to: deadlineBase,
            attemptID: firstAttemptID,
            now: now.addingTimeInterval(40)
        )
        let firstMergedValue = try NextStepBetaSyncArchiveAdapter
            .mergeImmutableExecutionRecords(
                localArchive: rejectedBranch,
                syncedArchive: firstQuizBranch,
                now: now.addingTimeInterval(50)
            )
        let firstMerged = try XCTUnwrap(firstMergedValue)
        XCTAssertEqual(
            firstMerged.grounding.reviewAudits
                .filter { $0.disposition == .confirmed }
                .map(\.id),
            retainedAuditOrder
        )
        XCTAssertEqual(firstMerged.grounding.confirmedDateFacts.map(\.id), retainedFactOrder)

        let secondAttemptID = UUID(uuidString: "22222222-2222-3333-4444-555555555555")!
        let secondQuizBranch = try addingPassingQuizAttempt(
            to: deadlineBase,
            attemptID: secondAttemptID,
            now: now.addingTimeInterval(60)
        )
        let secondMergedValue = try NextStepBetaSyncArchiveAdapter
            .mergeImmutableExecutionRecords(
                localArchive: firstMerged,
                syncedArchive: secondQuizBranch,
                now: now.addingTimeInterval(70)
            )
        let secondMerged = try XCTUnwrap(secondMergedValue)
        XCTAssertEqual(
            Set(secondMerged.workspace.userResponses.map(\.attemptID)),
            Set([firstAttemptID, secondAttemptID])
        )
        XCTAssertEqual(
            secondMerged.grounding.reviewAudits.filter {
                $0.disposition == .rejected
            }.map(\.candidateID),
            [pendingDate.id]
        )
        XCTAssertNoThrow(try secondMerged.validate())
    }

    func testImmutableExecutionUnionFailsClosedOnIDCollisionAndSkipsDifferentBase() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nextstep-beta-union-guard-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_762_000_000)
        let store = NextStepBetaStore(rootURL: root)
        let base = try await makeArchive(
            store: store,
            now: now,
            deadline: try LocalDay(year: 2028, month: 6, day: 30),
            sourceBytes: Data("collision source".utf8)
        )
        let left = try addingPassingQuizAttempt(
            to: base,
            attemptID: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
            now: now.addingTimeInterval(1)
        )
        let leftResponse = try XCTUnwrap(left.workspace.userResponses.first)
        let package = try XCTUnwrap(base.workspace.guidedPackages.first)
        let quiz = try XCTUnwrap(package.quiz)
        let item = try XCTUnwrap(quiz.items.first)
        let wrongOption = try XCTUnwrap(item.options.first {
            item.correctOptionIDs.contains($0.id) == false
        })
        var responseCollision = base
        responseCollision.workspace.userResponses = [
            try QuizEvaluator().makeResponse(
                metadata: leftResponse.metadata,
                attemptID: leftResponse.attemptID,
                quiz: quiz,
                quizItemID: item.id,
                packageVersion: package.version,
                selectedOptionID: wrongOption.id,
                attemptedAt: leftResponse.attemptedAt
            )
        ]
        responseCollision.workspace.revision += 1
        responseCollision.workspace.savedAt = now.addingTimeInterval(2)
        try responseCollision.validate()

        XCTAssertThrowsError(try NextStepBetaSyncArchiveAdapter
            .mergeImmutableExecutionRecords(
                localArchive: left,
                syncedArchive: responseCollision,
                now: now.addingTimeInterval(3)
            )) { error in
                XCTAssertEqual(
                    error as? NextStepBetaImmutableMergeError,
                    .conflictingUserResponse(leftResponse.metadata.id)
                )
            }

        let originalEvidence = try XCTUnwrap(left.workspace.completionEvidence.first)
        let result = try XCTUnwrap(originalEvidence.quizResult)
        var evidenceCollision = left
        evidenceCollision.workspace.completionEvidence = [
            try CompletionEvidence(
                metadata: originalEvidence.metadata,
                actionID: originalEvidence.actionID,
                packageID: result.packageID,
                packageVersion: result.packageVersion,
                quizResult: result,
                capturedAt: originalEvidence.capturedAt.addingTimeInterval(1),
                criterionIDs: originalEvidence.criterionIDs
            )
        ]
        evidenceCollision.workspace.revision += 1
        evidenceCollision.workspace.savedAt = now.addingTimeInterval(4)
        try evidenceCollision.validate()

        XCTAssertThrowsError(try NextStepBetaSyncArchiveAdapter
            .mergeImmutableExecutionRecords(
                localArchive: left,
                syncedArchive: evidenceCollision,
                now: now.addingTimeInterval(5)
            )) { error in
                XCTAssertEqual(
                    error as? NextStepBetaImmutableMergeError,
                    .conflictingCompletionEvidence(originalEvidence.metadata.id)
                )
            }

        var incompatible = base
        incompatible.workspace.dailyActions[0].title = "不同的結構化任務"
        incompatible.workspace.revision += 1
        incompatible.workspace.savedAt = now.addingTimeInterval(6)
        try incompatible.validate()
        XCTAssertNil(try NextStepBetaSyncArchiveAdapter.mergeImmutableExecutionRecords(
            localArchive: base,
            syncedArchive: incompatible,
            now: now.addingTimeInterval(7)
        ))
    }

    func testDifferentHardDeadlinesStopForReviewAndNeverReplaceLocalSilently() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let storeA = NextStepBetaStore(rootURL: fixture.storeA)
        let storeB = NextStepBetaStore(rootURL: fixture.storeB)
        let archiveA = try makeGoalOnlyArchive(
            now: now,
            deadline: try LocalDay(year: 2028, month: 5, day: 1)
        )
        let archiveB = try makeGoalOnlyArchive(
            now: now.addingTimeInterval(5),
            deadline: try LocalDay(year: 2028, month: 6, day: 1)
        )
        try await storeA.save(archiveA)
        try await storeB.save(archiveB)
        let engineA = try makeEngine(
            localRoot: fixture.engineA,
            remoteRoot: fixture.remote,
            deviceID: NextStepSync.DeviceID(
                UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
            ),
            now: now,
            libraryID: fixture.libraryID
        )
        let engineB = try makeEngine(
            localRoot: fixture.engineB,
            remoteRoot: fixture.remote,
            deviceID: NextStepSync.DeviceID(
                UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
            ),
            now: now.addingTimeInterval(10),
            libraryID: fixture.libraryID
        )

        _ = try await NextStepBetaSyncArchiveAdapter(
            engine: engineA,
            store: storeA
        ).reconcileInitial(localArchive: archiveA, now: now)
        let adapterB = NextStepBetaSyncArchiveAdapter(engine: engineB, store: storeB)
        let reviewResult = try await adapterB.reconcileInitial(
            localArchive: archiveB,
            now: now.addingTimeInterval(10)
        )
        let pending = try XCTUnwrap(reviewResult.pendingReview)

        XCTAssertEqual(pending.summary.kind, .protectedDeadline)
        XCTAssertTrue(pending.summary.localDescription.contains("最終目標「完成論文」"))
        XCTAssertTrue(pending.summary.localDescription.contains("目標「建立第一個可驗證成果」"))
        XCTAssertTrue(pending.summary.localDescription.contains("里程碑「完成第一個引導式學習任務」"))
        XCTAssertTrue(pending.summary.localDescription.contains("2028-06-01"))
        XCTAssertTrue(pending.summary.syncedDescription.contains("最終目標「完成論文」"))
        XCTAssertTrue(pending.summary.syncedDescription.contains("目標「建立第一個可驗證成果」"))
        XCTAssertTrue(pending.summary.syncedDescription.contains("里程碑「完成第一個引導式學習任務」"))
        XCTAssertTrue(pending.summary.syncedDescription.contains("2028-05-01"))
        XCTAssertEqual(
            reviewResult.archive.workspace.ultimateGoals.first?.targetDay?.value,
            try LocalDay(year: 2028, month: 6, day: 1)
        )
        let storedLocal = try await storeB.load()
        let stillLocal = try XCTUnwrap(storedLocal)
        XCTAssertEqual(
            stillLocal.workspace.ultimateGoals.first?.targetDay?.value,
            try LocalDay(year: 2028, month: 6, day: 1)
        )

        let resolved = try await adapterB.resolve(
            pending,
            useSyncedArchive: true,
            now: now.addingTimeInterval(20)
        )
        XCTAssertEqual(
            resolved.archive.workspace.ultimateGoals.first?.targetDay?.value,
            try LocalDay(year: 2028, month: 5, day: 1)
        )
        let finalSnapshot = try await engineB.snapshot()
        XCTAssertFalse(finalSnapshot.conflicts.contains { $0.status == .unresolved })
    }

    func testSameDeadlineDayWithDifferentConfirmationEvidenceRequiresReview() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = Date(timeIntervalSince1970: 1_762_000_000)
        let day = try LocalDay(year: 2028, month: 9, day: 30)
        let store = NextStepBetaStore(rootURL: fixture.storeA)
        let base = try await makeArchive(
            store: store,
            now: now,
            deadline: day,
            sourceBytes: Data("same day, new evidence".utf8),
            exactExtract: "Assignment deadline: 2028-09-30"
        )
        try await store.save(base)
        let engine = try makeEngine(
            localRoot: fixture.engineA,
            remoteRoot: fixture.remote,
            deviceID: NextStepSync.DeviceID(
                UUID(uuidString: "aaaaaaaa-3333-4444-5555-666666666666")!
            ),
            now: now,
            libraryID: fixture.libraryID
        )
        let adapter = NextStepBetaSyncArchiveAdapter(engine: engine, store: store)
        _ = try await adapter.reconcileInitial(localArchive: base, now: now)

        let candidate = try XCTUnwrap(base.grounding.pendingFacts.first)
        XCTAssertEqual(candidate.candidate.kind, .deadline)
        let preview = try NextStepBetaSourceFactReviewCoordinator().makePreview(
            candidateID: candidate.id,
            archive: base,
            now: now.addingTimeInterval(10)
        )
        let confirmed = try NextStepBetaSourceFactReviewCoordinator().accept(
            preview,
            archive: base,
            now: now.addingTimeInterval(11)
        )
        XCTAssertEqual(confirmed.workspace.milestones.first?.targetDay?.value, day)
        XCTAssertFalse(
            try XCTUnwrap(confirmed.workspace.milestones.first?.targetDay).evidenceLinkIDs.isEmpty
        )
        try await store.save(confirmed)

        let reviewResult = try await adapter.publishLocalAndSynchronize(
            confirmed,
            now: now.addingTimeInterval(20)
        )
        let pending = try XCTUnwrap(reviewResult.pendingReview)
        XCTAssertEqual(pending.summary.kind, .protectedDeadline)
        XCTAssertEqual(
            reviewResult.archive.workspace.milestones.first?.targetDay?.value,
            day
        )
        XCTAssertTrue(pending.summary.localDescription.contains("最終目標「完成論文」"))
        XCTAssertTrue(pending.summary.localDescription.contains("目標「建立第一個可驗證成果」"))
        XCTAssertTrue(
            pending.summary.localDescription.contains(
                "里程碑「完成第一個引導式學習任務」"
            )
        )
        XCTAssertTrue(pending.summary.localDescription.contains("2028-09-30"))
        XCTAssertTrue(pending.summary.localDescription.contains("userConfirmed/immutable"))
        XCTAssertTrue(pending.summary.localDescription.contains("來源證據：grounded.pdf"))
        let milestoneID = try XCTUnwrap(confirmed.workspace.milestones.first).metadata.id
        XCTAssertTrue(pending.summary.localDescription.contains(milestoneID.description))
        XCTAssertTrue(pending.summary.syncedDescription.contains("來源證據：無"))
    }

    func testResolvingDeadlineConflictCarriesLosingRejectedAuditAndQuizAttempt() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = Date(timeIntervalSince1970: 1_762_100_000)
        let sourceBytes = Data("deadline conflict safe history".utf8)
        let storeA = NextStepBetaStore(rootURL: fixture.storeA)
        let storeB = NextStepBetaStore(rootURL: fixture.storeB)
        let baseA = try await makeArchive(
            store: storeA,
            now: now,
            deadline: try LocalDay(year: 2028, month: 6, day: 30),
            sourceBytes: sourceBytes,
            exactExtract: "Lecture date: 2028-11-01"
        )
        let pendingDate = try XCTUnwrap(baseA.grounding.pendingFacts.first)
        XCTAssertEqual(pendingDate.candidate.kind, .date)

        var baseB = baseA
        baseB.deviceID = NextStepDomain.DeviceID(
            UUID(uuidString: "bbbbbbbb-3333-4444-5555-666666666666")!
        )
        let document = try XCTUnwrap(baseB.workspace.sourceDocuments.first)
        try await storeB.installSyncedSource(
            sourceBytes,
            relativePath: try XCTUnwrap(document.localRelativePath),
            expectedSHA256: try XCTUnwrap(document.contentSHA256)
        )
        try await storeA.save(baseA)
        try await storeB.save(baseB)

        let engineA = try makeEngine(
            localRoot: fixture.engineA,
            remoteRoot: fixture.remote,
            deviceID: NextStepSync.DeviceID(
                UUID(uuidString: "aaaaaaaa-7777-8888-9999-000000000000")!
            ),
            now: now,
            libraryID: fixture.libraryID
        )
        let engineB = try makeEngine(
            localRoot: fixture.engineB,
            remoteRoot: fixture.remote,
            deviceID: NextStepSync.DeviceID(
                UUID(uuidString: "bbbbbbbb-7777-8888-9999-000000000000")!
            ),
            now: now.addingTimeInterval(5),
            libraryID: fixture.libraryID
        )
        let adapterA = NextStepBetaSyncArchiveAdapter(engine: engineA, store: storeA)
        let adapterB = NextStepBetaSyncArchiveAdapter(engine: engineB, store: storeB)
        _ = try await adapterA.reconcileInitial(localArchive: baseA, now: now)
        _ = try await adapterB.reconcileInitial(
            localArchive: baseB,
            now: now.addingTimeInterval(5)
        )

        let rejected = try NextStepBetaSourceFactReviewCoordinator().reject(
            candidateID: pendingDate.id,
            reason: "This lecture date is not a planning deadline.",
            archive: baseA,
            now: now.addingTimeInterval(10)
        )
        let quizAttemptID = UUID(uuidString: "cccccccc-7777-8888-9999-000000000000")!
        let losingBranch = try addingPassingQuizAttempt(
            to: rejected,
            attemptID: quizAttemptID,
            now: now.addingTimeInterval(11)
        )
        let chosenDay = try LocalDay(year: 2028, month: 7, day: 31)
        let chosenBranch = try replacingProtectedDeadline(
            in: baseB,
            with: chosenDay,
            now: now.addingTimeInterval(20)
        )
        try await storeA.save(losingBranch)
        try await storeB.save(chosenBranch)

        _ = try await adapterA.publishLocalAndSynchronize(
            losingBranch,
            now: now.addingTimeInterval(30)
        )
        let reviewResult = try await adapterB.publishLocalAndSynchronize(
            chosenBranch,
            now: now.addingTimeInterval(40)
        )
        let pending = try XCTUnwrap(reviewResult.pendingReview)
        XCTAssertEqual(pending.summary.kind, .protectedDeadline)

        let resolved = try await adapterB.resolve(
            pending,
            useSyncedArchive: false,
            now: now.addingTimeInterval(50)
        )
        XCTAssertNil(resolved.pendingReview)
        XCTAssertEqual(
            resolved.archive.workspace.ultimateGoals.first?.targetDay?.value,
            chosenDay
        )
        XCTAssertEqual(
            resolved.archive.workspace.goals.first?.targetDay?.value,
            chosenDay
        )
        XCTAssertEqual(
            resolved.archive.workspace.milestones.first?.targetDay?.value,
            chosenDay
        )
        XCTAssertEqual(
            resolved.archive.grounding.reviewAudits.filter {
                $0.candidateID == pendingDate.id
            }.map(\.disposition),
            [.rejected]
        )
        XCTAssertTrue(resolved.archive.grounding.pendingFacts.isEmpty)
        XCTAssertEqual(
            Set(resolved.archive.workspace.userResponses.map(\.attemptID)),
            Set([quizAttemptID])
        )
        XCTAssertEqual(
            Set(resolved.archive.workspace.completionEvidence.compactMap {
                $0.quizResult?.attemptID
            }),
            Set([quizAttemptID])
        )
        XCTAssertNoThrow(try resolved.archive.validate())
        let storedValue = try await storeB.load()
        let stored = try XCTUnwrap(storedValue)
        XCTAssertEqual(stored.workspace.userResponses, resolved.archive.workspace.userResponses)
        XCTAssertEqual(stored.grounding.reviewAudits, resolved.archive.grounding.reviewAudits)
    }

    func testResolveChoosesOneSameCandidateDeadlineOutcomeAndCarriesOnlySafeHistory() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let now = Date(timeIntervalSince1970: 1_762_200_000)
        let sourceBytes = Data("competing grounded outcomes".utf8)
        let storeA = NextStepBetaStore(rootURL: fixture.storeA)
        let storeB = NextStepBetaStore(rootURL: fixture.storeB)
        let baseA = try await makeArchive(
            store: storeA,
            now: now,
            deadline: try LocalDay(year: 2028, month: 6, day: 30),
            sourceBytes: sourceBytes,
            exactExtract: "Assignment deadline: 2028-09-30; "
                + "Lecture date: 2028-11-01; Lecture date: 2028-12-01"
        )
        let deadlineCandidate = try XCTUnwrap(baseA.grounding.pendingFacts.first {
            $0.candidate.kind == .deadline
        })
        let dateCandidates = baseA.grounding.pendingFacts.filter {
            $0.candidate.kind == .date
        }
        XCTAssertEqual(dateCandidates.count, 2)
        let rejectedDateCandidate = try XCTUnwrap(dateCandidates.first)
        let confirmedDateCandidate = try XCTUnwrap(dateCandidates.dropFirst().first)

        var baseB = baseA
        baseB.deviceID = NextStepDomain.DeviceID(
            UUID(uuidString: "bbbbbbbb-4444-5555-6666-777777777777")!
        )
        let document = try XCTUnwrap(baseB.workspace.sourceDocuments.first)
        try await storeB.installSyncedSource(
            sourceBytes,
            relativePath: try XCTUnwrap(document.localRelativePath),
            expectedSHA256: try XCTUnwrap(document.contentSHA256)
        )

        let previewAt = now.addingTimeInterval(10)
        let acceptedAt = now.addingTimeInterval(11)
        let previewA = try NextStepBetaSourceFactReviewCoordinator().makePreview(
            candidateID: deadlineCandidate.id,
            archive: baseA,
            now: previewAt
        )
        let branchA = try NextStepBetaSourceFactReviewCoordinator().accept(
            previewA,
            archive: baseA,
            now: acceptedAt
        )
        let previewB = try NextStepBetaSourceFactReviewCoordinator().makePreview(
            candidateID: deadlineCandidate.id,
            archive: baseB,
            now: previewAt
        )
        var branchB = try NextStepBetaSourceFactReviewCoordinator().accept(
            previewB,
            archive: baseB,
            now: acceptedAt
        )
        let deadlineFactA = try XCTUnwrap(branchA.grounding.confirmedDateFacts.first {
            $0.candidateID == deadlineCandidate.id
        })
        let deadlineFactB = try XCTUnwrap(branchB.grounding.confirmedDateFacts.first {
            $0.candidateID == deadlineCandidate.id
        })
        XCTAssertEqual(deadlineFactA.kind, .deadline)
        XCTAssertEqual(deadlineFactB.kind, .deadline)
        XCTAssertEqual(deadlineFactA.day.value, deadlineFactB.day.value)
        XCTAssertEqual(deadlineFactA.day.authority, deadlineFactB.day.authority)
        XCTAssertEqual(deadlineFactA.day.mutability, deadlineFactB.day.mutability)
        XCTAssertEqual(deadlineFactA.day.confidence, deadlineFactB.day.confidence)
        XCTAssertEqual(deadlineFactA.day.confirmedAt, deadlineFactB.day.confirmedAt)
        XCTAssertNotEqual(
            Set(deadlineFactA.day.evidenceLinkIDs),
            Set(deadlineFactB.day.evidenceLinkIDs)
        )

        branchB = try NextStepBetaSourceFactReviewCoordinator().reject(
            candidateID: rejectedDateCandidate.id,
            reason: "This lecture date is not relevant to the plan.",
            archive: branchB,
            now: now.addingTimeInterval(12)
        )
        let safeDatePreview = try NextStepBetaSourceFactReviewCoordinator().makePreview(
            candidateID: confirmedDateCandidate.id,
            archive: branchB,
            now: now.addingTimeInterval(13)
        )
        branchB = try NextStepBetaSourceFactReviewCoordinator().accept(
            safeDatePreview,
            archive: branchB,
            now: now.addingTimeInterval(14)
        )
        let safeDateFact = try XCTUnwrap(branchB.grounding.confirmedDateFacts.first {
            $0.candidateID == confirmedDateCandidate.id
        })
        XCTAssertEqual(safeDateFact.kind, .date)
        let quizAttemptID = UUID(uuidString: "cccccccc-4444-5555-6666-777777777777")!
        branchB = try addingPassingQuizAttempt(
            to: branchB,
            attemptID: quizAttemptID,
            now: now.addingTimeInterval(15)
        )
        let deadlineAuditA = try XCTUnwrap(branchA.grounding.reviewAudits.first {
            $0.candidateID == deadlineCandidate.id
        })
        let deadlineAuditB = try XCTUnwrap(branchB.grounding.reviewAudits.first {
            $0.candidateID == deadlineCandidate.id
        })
        let safeAuditIDs = Set(branchB.grounding.reviewAudits.filter {
            $0.candidateID != deadlineCandidate.id
        }.map(\.id))
        let safeEvidenceIDs = Set(branchB.grounding.reviewAudits.filter {
            $0.candidateID == confirmedDateCandidate.id
        }.flatMap(\.evidenceLinkIDs))
        let deadlineEvidenceIDA = try XCTUnwrap(deadlineFactA.day.evidenceLinkIDs.first)
        let deadlineEvidenceIDB = try XCTUnwrap(deadlineFactB.day.evidenceLinkIDs.first)

        try await storeA.save(branchA)
        try await storeB.save(branchB)
        let engineA = try makeEngine(
            localRoot: fixture.engineA,
            remoteRoot: fixture.remote,
            deviceID: NextStepSync.DeviceID(
                UUID(uuidString: "aaaaaaaa-1212-3434-5656-787878787878")!
            ),
            now: now.addingTimeInterval(20),
            libraryID: fixture.libraryID
        )
        let engineB = try makeEngine(
            localRoot: fixture.engineB,
            remoteRoot: fixture.remote,
            deviceID: NextStepSync.DeviceID(
                UUID(uuidString: "bbbbbbbb-1212-3434-5656-787878787878")!
            ),
            now: now.addingTimeInterval(30),
            libraryID: fixture.libraryID
        )
        let adapterA = NextStepBetaSyncArchiveAdapter(engine: engineA, store: storeA)
        let adapterB = NextStepBetaSyncArchiveAdapter(engine: engineB, store: storeB)
        _ = try await adapterB.reconcileInitial(
            localArchive: branchB,
            now: now.addingTimeInterval(30)
        )
        let reviewResult = try await adapterA.reconcileInitial(
            localArchive: branchA,
            now: now.addingTimeInterval(40)
        )
        let pending = try XCTUnwrap(reviewResult.pendingReview)
        XCTAssertEqual(pending.summary.kind, .protectedDeadline)
        XCTAssertTrue(
            pending.summary.localDescription.contains(deadlineEvidenceIDA.description)
        )
        XCTAssertTrue(
            pending.summary.syncedDescription.contains(deadlineEvidenceIDB.description)
        )

        let resolved = try await adapterA.resolve(
            pending,
            useSyncedArchive: false,
            now: now.addingTimeInterval(50)
        )
        XCTAssertNil(resolved.pendingReview)
        XCTAssertEqual(
            resolved.archive.grounding.confirmedDateFacts.filter {
                $0.kind == .deadline
            }.map(\.id),
            [deadlineFactA.id]
        )
        XCTAssertTrue(resolved.archive.grounding.confirmedDateFacts.contains(safeDateFact))
        XCTAssertFalse(resolved.archive.grounding.confirmedDateFacts.contains(deadlineFactB))
        XCTAssertTrue(resolved.archive.grounding.reviewAudits.contains(deadlineAuditA))
        XCTAssertFalse(resolved.archive.grounding.reviewAudits.contains(deadlineAuditB))
        XCTAssertTrue(
            safeAuditIDs.isSubset(
                of: Set(resolved.archive.grounding.reviewAudits.map(\.id))
            )
        )
        XCTAssertTrue(
            Set(deadlineAuditA.evidenceLinkIDs).isSubset(
                of: Set(resolved.archive.workspace.evidenceLinks.map(\.metadata.id))
            )
        )
        XCTAssertTrue(
            Set(deadlineAuditB.evidenceLinkIDs).isDisjoint(
                with: Set(resolved.archive.workspace.evidenceLinks.map(\.metadata.id))
            )
        )
        XCTAssertTrue(
            safeEvidenceIDs.isSubset(
                of: Set(resolved.archive.workspace.evidenceLinks.map(\.metadata.id))
            )
        )
        XCTAssertEqual(
            Set(resolved.archive.workspace.userResponses.map(\.attemptID)),
            Set([quizAttemptID])
        )
        XCTAssertEqual(
            Set(resolved.archive.workspace.completionEvidence.compactMap {
                $0.quizResult?.attemptID
            }),
            Set([quizAttemptID])
        )
        XCTAssertNoThrow(try resolved.archive.validate())
    }

    func testResolveTreatsSameCandidateDeadlineRejectionAsCompetingOutcome() async throws {
        for chooseConfirmed in [true, false] {
            let fixture = try makeFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let now = Date(timeIntervalSince1970: 1_762_300_000)
            let sourceBytes = Data("confirm versus reject".utf8)
            let storeA = NextStepBetaStore(rootURL: fixture.storeA)
            let storeB = NextStepBetaStore(rootURL: fixture.storeB)
            let baseA = try await makeArchive(
                store: storeA,
                now: now,
                deadline: try LocalDay(year: 2028, month: 6, day: 30),
                sourceBytes: sourceBytes,
                exactExtract: "Assignment deadline: 2028-09-30; "
                    + "Lecture date: 2028-11-01"
            )
            let deadlineCandidate = try XCTUnwrap(baseA.grounding.pendingFacts.first {
                $0.candidate.kind == .deadline
            })
            let ordinaryDateCandidate = try XCTUnwrap(baseA.grounding.pendingFacts.first {
                $0.candidate.kind == .date
            })
            var baseB = baseA
            baseB.deviceID = NextStepDomain.DeviceID(
                UUID(uuidString: "bbbbbbbb-4545-5656-6767-787878787878")!
            )
            let document = try XCTUnwrap(baseB.workspace.sourceDocuments.first)
            try await storeB.installSyncedSource(
                sourceBytes,
                relativePath: try XCTUnwrap(document.localRelativePath),
                expectedSHA256: try XCTUnwrap(document.contentSHA256)
            )

            let preview = try NextStepBetaSourceFactReviewCoordinator().makePreview(
                candidateID: deadlineCandidate.id,
                archive: baseA,
                now: now.addingTimeInterval(10)
            )
            let confirmedBranch = try NextStepBetaSourceFactReviewCoordinator().accept(
                preview,
                archive: baseA,
                now: now.addingTimeInterval(11)
            )
            var rejectedBranch = try NextStepBetaSourceFactReviewCoordinator().reject(
                candidateID: deadlineCandidate.id,
                reason: "This is not the deadline to apply.",
                archive: baseB,
                now: now.addingTimeInterval(12)
            )
            rejectedBranch = try NextStepBetaSourceFactReviewCoordinator().reject(
                candidateID: ordinaryDateCandidate.id,
                reason: "This lecture date is not relevant.",
                archive: rejectedBranch,
                now: now.addingTimeInterval(13)
            )
            let quizAttemptID = UUID()
            rejectedBranch = try addingPassingQuizAttempt(
                to: rejectedBranch,
                attemptID: quizAttemptID,
                now: now.addingTimeInterval(14)
            )

            let confirmedFact = try XCTUnwrap(
                confirmedBranch.grounding.confirmedDateFacts.first {
                    $0.candidateID == deadlineCandidate.id
                }
            )
            let confirmedAudit = try XCTUnwrap(
                confirmedBranch.grounding.reviewAudits.first {
                    $0.candidateID == deadlineCandidate.id
                }
            )
            let competingRejection = try XCTUnwrap(
                rejectedBranch.grounding.reviewAudits.first {
                    $0.candidateID == deadlineCandidate.id
                }
            )
            let safeRejection = try XCTUnwrap(
                rejectedBranch.grounding.reviewAudits.first {
                    $0.candidateID == ordinaryDateCandidate.id
                }
            )
            try await storeA.save(confirmedBranch)
            try await storeB.save(rejectedBranch)

            let engineA = try makeEngine(
                localRoot: fixture.engineA,
                remoteRoot: fixture.remote,
                deviceID: NextStepSync.DeviceID(),
                now: now.addingTimeInterval(20),
                libraryID: fixture.libraryID
            )
            let engineB = try makeEngine(
                localRoot: fixture.engineB,
                remoteRoot: fixture.remote,
                deviceID: NextStepSync.DeviceID(),
                now: now.addingTimeInterval(30),
                libraryID: fixture.libraryID
            )
            let adapterA = NextStepBetaSyncArchiveAdapter(engine: engineA, store: storeA)
            let adapterB = NextStepBetaSyncArchiveAdapter(engine: engineB, store: storeB)
            let resolvingAdapter: NextStepBetaSyncArchiveAdapter
            let reviewResult: NextStepBetaSyncAdapterResult
            if chooseConfirmed {
                _ = try await adapterB.reconcileInitial(
                    localArchive: rejectedBranch,
                    now: now.addingTimeInterval(30)
                )
                resolvingAdapter = adapterA
                reviewResult = try await adapterA.reconcileInitial(
                    localArchive: confirmedBranch,
                    now: now.addingTimeInterval(40)
                )
            } else {
                _ = try await adapterA.reconcileInitial(
                    localArchive: confirmedBranch,
                    now: now.addingTimeInterval(20)
                )
                resolvingAdapter = adapterB
                reviewResult = try await adapterB.reconcileInitial(
                    localArchive: rejectedBranch,
                    now: now.addingTimeInterval(40)
                )
            }
            let pending = try XCTUnwrap(reviewResult.pendingReview)
            let resolved = try await resolvingAdapter.resolve(
                pending,
                useSyncedArchive: false,
                now: now.addingTimeInterval(50)
            )
            let sameCandidateAudits = resolved.archive.grounding.reviewAudits.filter {
                $0.candidateID == deadlineCandidate.id
            }
            XCTAssertEqual(sameCandidateAudits.count, 1)
            XCTAssertTrue(resolved.archive.grounding.reviewAudits.contains(safeRejection))
            XCTAssertEqual(
                Set(resolved.archive.workspace.userResponses.map(\.attemptID)),
                Set([quizAttemptID])
            )
            XCTAssertEqual(
                Set(resolved.archive.workspace.completionEvidence.compactMap {
                    $0.quizResult?.attemptID
                }),
                Set([quizAttemptID])
            )
            if chooseConfirmed {
                XCTAssertEqual(sameCandidateAudits, [confirmedAudit])
                XCTAssertFalse(
                    resolved.archive.grounding.reviewAudits.contains(competingRejection)
                )
                XCTAssertTrue(
                    resolved.archive.grounding.confirmedDateFacts.contains(confirmedFact)
                )
                XCTAssertTrue(
                    Set(confirmedAudit.evidenceLinkIDs).isSubset(
                        of: Set(resolved.archive.workspace.evidenceLinks.map(\.metadata.id))
                    )
                )
            } else {
                XCTAssertEqual(sameCandidateAudits, [competingRejection])
                XCTAssertFalse(resolved.archive.grounding.reviewAudits.contains(confirmedAudit))
                XCTAssertFalse(
                    resolved.archive.grounding.confirmedDateFacts.contains(confirmedFact)
                )
                XCTAssertTrue(
                    Set(confirmedAudit.evidenceLinkIDs).isDisjoint(
                        with: Set(resolved.archive.workspace.evidenceLinks.map(\.metadata.id))
                    )
                )
            }
            XCTAssertNoThrow(try resolved.archive.validate())
        }
    }

    func testBookmarkSettingsAreAtomicAndDoNotContainArchiveOrSourceContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nextstep-beta-bookmark-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = NextStepBetaSyncSettingsStore(rootURL: root)
        let bookmark = SecurityScopedSyncFolderBookmark(data: Data("bookmark-only".utf8))
        let libraryID = SyncLibraryID(
            UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        )

        try await settings.save(bookmark: bookmark, libraryID: libraryID)
        let loadedValue = try await settings.load()
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.bookmarkData, bookmark.data)
        XCTAssertEqual(loaded.libraryID, libraryID)

        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(files, ["sync-folder-bookmark-v1.json"])
        let bytes = try Data(contentsOf: root.appendingPathComponent(files[0]))
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains(NextStepBetaStore.archiveFilename))
        XCTAssertFalse(text.contains("Sources/"))
    }

    func testOfflineFailureKeepsAtomicLocalArchiveAndDurablePendingOperations() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nextstep-beta-offline-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let store = NextStepBetaStore(
            rootURL: root.appendingPathComponent("store", isDirectory: true)
        )
        let archive = try makeGoalOnlyArchive(
            now: now,
            deadline: try LocalDay(year: 2028, month: 12, day: 31)
        )
        try await store.save(archive)
        let engine = try NextStepSyncEngine(
            libraryID: SyncLibraryID(),
            deviceID: NextStepSync.DeviceID(),
            localRootURL: root.appendingPathComponent("engine", isDirectory: true),
            transport: PermanentlyOfflineTransport(),
            now: { now }
        )

        do {
            _ = try await NextStepBetaSyncArchiveAdapter(
                engine: engine,
                store: store
            ).publishLocalAndSynchronize(archive, now: now)
            XCTFail("An unavailable folder must report offline.")
        } catch NextStepSyncError.transportUnavailable {
            // Expected. enqueueBlob/enqueueSet have already persisted their queue.
        }

        let loadedValue = try await store.load()
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(
            loaded.workspace.ultimateGoals.first?.targetDay?.value,
            try LocalDay(year: 2028, month: 12, day: 31)
        )
        let pendingCount = try await engine.pendingOperationCount()
        XCTAssertEqual(pendingCount, 2)
    }

    func testSourceWithoutContentHashIsNeverPublished() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nextstep-beta-missing-hash-\(UUID().uuidString)",
            isDirectory: true
        )
        let remote = root.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let store = NextStepBetaStore(
            rootURL: root.appendingPathComponent("store", isDirectory: true)
        )
        var archive = try await makeArchive(
            store: store,
            now: now,
            deadline: try LocalDay(year: 2028, month: 12, day: 31),
            sourceBytes: Data("unverified source".utf8)
        )
        archive.workspace.sourceDocuments[0].contentSHA256 = nil
        let engine = try makeEngine(
            localRoot: root.appendingPathComponent("engine", isDirectory: true),
            remoteRoot: remote,
            deviceID: NextStepSync.DeviceID(),
            now: now,
            libraryID: SyncLibraryID()
        )

        do {
            _ = try await NextStepBetaSyncArchiveAdapter(
                engine: engine,
                store: store
            ).publishLocalAndSynchronize(archive, now: now)
            XCTFail("A source without a verifiable content hash must remain local.")
        } catch let error as NextStepBetaStoreError {
            XCTAssertEqual(error, .sourceIntegrityMismatch)
        }
        let pendingCount = try await engine.pendingOperationCount()
        XCTAssertEqual(pendingCount, 0)
    }

    private func makeArchive(
        store: NextStepBetaStore,
        now: Date,
        deadline: LocalDay,
        sourceBytes: Data,
        exactExtract: String = "Grounded extract"
    ) async throws -> NextStepBetaArchive {
        var archive = try makeGoalOnlyArchive(now: now, deadline: deadline)
        let documentID = SourceDocumentID()
        let relativePath = "Sources/\(documentID.description)/original.pdf"
        let digest = SHA256.hash(data: sourceBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        try await store.installSyncedSource(
            sourceBytes,
            relativePath: relativePath,
            expectedSHA256: digest
        )
        let document = try NextStepBetaSourceRecordBuilder().makeDocument(
            id: documentID,
            displayTitle: "grounded.pdf",
            fileExtension: "pdf",
            relativePath: relativePath,
            contentSHA256: digest,
            now: now,
            deviceID: archive.deviceID,
            parserVersion: "test-extractive-v1"
        )
        archive = try NextStepBetaPackageBuilder().addImportedSource(
            NextStepBetaImportedSource(
                document: document,
                exactExtract: exactExtract,
                pageIndex: 0,
                usedVisionOCR: false,
                extractionNotice: nil
            ),
            to: archive,
            now: now
        )
        return archive
    }

    private func addingPassingQuizAttempt(
        to archive: NextStepBetaArchive,
        attemptID: UUID,
        now: Date
    ) throws -> NextStepBetaArchive {
        var result = archive
        let package = try XCTUnwrap(result.workspace.guidedPackages.first)
        let quiz = try XCTUnwrap(package.quiz)
        let action = try XCTUnwrap(result.workspace.dailyActions.first)
        let responses = try NextStepBetaQuizGrader().grade(
            package: package,
            selections: Dictionary(uniqueKeysWithValues: quiz.items.map {
                ($0.id, Set($0.correctOptionIDs))
            }),
            attemptID: attemptID,
            now: now,
            deviceID: result.deviceID
        ).responses
        let quizResult = try QuizEvaluator().evaluate(
            quiz: quiz,
            packageID: package.metadata.id,
            packageVersion: package.version,
            responses: responses,
            scoredAt: now
        )
        let criterionIDs = action.completionCriteria
            .filter { $0.kind == .quizScore }
            .map(\.id)
        let evidence = try CompletionEvidence(
            metadata: RecordMetadata(
                id: CompletionEvidenceID(),
                createdAt: now,
                originDeviceID: result.deviceID,
                provenance: .deterministicEngine
            ),
            actionID: action.metadata.id,
            packageID: package.metadata.id,
            packageVersion: package.version,
            quizResult: quizResult,
            capturedAt: now,
            criterionIDs: criterionIDs
        )
        result.workspace.userResponses.append(contentsOf: responses)
        result.workspace.completionEvidence.append(evidence)
        result.workspace.revision += 1
        result.workspace.savedAt = now
        try result.validate()
        return result
    }

    private func makeGoalOnlyArchive(
        now: Date,
        deadline: LocalDay
    ) throws -> NextStepBetaArchive {
        var archive = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: now,
            deviceID: NextStepDomain.DeviceID(),
            timeZoneIdentifier: "Asia/Taipei"
        )
        archive = try NextStepBetaGoalBuilder().addGoal(
            title: "完成論文",
            deadline: deadline,
            dailyMinutes: 35,
            to: archive,
            now: now
        )
        return archive
    }

    private func replacingProtectedDeadline(
        in archive: NextStepBetaArchive,
        with deadline: LocalDay,
        now: Date
    ) throws -> NextStepBetaArchive {
        let value = try FactValue(
            value: deadline,
            authority: .userConfirmed,
            mutability: .immutable,
            confirmedAt: now
        )
        var result = archive
        for index in result.workspace.ultimateGoals.indices {
            result.workspace.ultimateGoals[index].targetDay = value
        }
        for index in result.workspace.goals.indices {
            result.workspace.goals[index].targetDay = value
        }
        for index in result.workspace.milestones.indices {
            result.workspace.milestones[index].targetDay = value
        }
        for index in result.workspace.dailyActions.indices {
            result.workspace.dailyActions[index].deadline = value
        }
        result.workspace.revision += 1
        result.workspace.savedAt = now
        try result.validate()
        return result
    }

    private func makeEngine(
        localRoot: URL,
        remoteRoot: URL,
        deviceID: NextStepSync.DeviceID,
        now: Date,
        libraryID: SyncLibraryID
    ) throws -> NextStepSyncEngine {
        let transport = try FileFolderSyncTransport(
            rootURL: remoteRoot,
            requiresSecurityScopedAccess: false
        )
        return try NextStepSyncEngine(
            libraryID: libraryID,
            deviceID: deviceID,
            localRootURL: localRoot,
            transport: transport,
            now: { now }
        )
    }

    private func makeFixture() throws -> SyncFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nextstep-beta-sync-\(UUID().uuidString)",
            isDirectory: true
        )
        let remote = root.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        return SyncFixture(
            root: root,
            remote: remote,
            storeA: root.appendingPathComponent("store-a", isDirectory: true),
            storeB: root.appendingPathComponent("store-b", isDirectory: true),
            engineA: root.appendingPathComponent("engine-a", isDirectory: true),
            engineB: root.appendingPathComponent("engine-b", isDirectory: true),
            libraryID: SyncLibraryID(
                UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
            )
        )
    }
}

private struct LegacyNextStepBetaSyncPayloadV1: Encodable {
    let schemaVersion: Int
    let workspace: NextStepWorkspaceSnapshot
    let currentDecisionID: PlanningDecisionID?
}

private struct SyncFixture {
    let root: URL
    let remote: URL
    let storeA: URL
    let storeB: URL
    let engineA: URL
    let engineB: URL
    let libraryID: SyncLibraryID
}

private struct PermanentlyOfflineTransport: SyncTransport {
    func isAvailable() async -> Bool { false }

    func list(_ path: SyncRelativePath) async throws -> [SyncTransportEntry] {
        throw NextStepSyncError.transportUnavailable
    }

    func read(_ path: SyncRelativePath, maximumBytes: Int) async throws -> Data {
        throw NextStepSyncError.transportUnavailable
    }

    func writeImmutable(_ data: Data, to path: SyncRelativePath) async throws {
        throw NextStepSyncError.transportUnavailable
    }

    func replaceAtomically(_ data: Data, at path: SyncRelativePath) async throws {
        throw NextStepSyncError.transportUnavailable
    }
}
