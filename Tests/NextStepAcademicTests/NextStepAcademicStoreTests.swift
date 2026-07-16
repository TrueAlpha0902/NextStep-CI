import Foundation
@testable import NextStepAcademic
import XCTest

@MainActor
final class NextStepAcademicStoreTests: XCTestCase {
    func testBothFilesMissingLoadsDeterministicInMemoryEmptyWorkspace() async throws {
        let backing = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(storageRevision: 4)
        )
        let store = NextStepAcademicStore(backing: backing)

        let loaded = try await store.load()

        XCTAssertEqual(loaded.workspace, .empty)
        XCTAssertEqual(loaded.token.workspaceRevision, 0)
        XCTAssertEqual(loaded.token.storageRevision, 4)
        let current = try await store.currentSnapshot()
        XCTAssertEqual(current, loaded)
        let replacements = await backing.replaceCallCount()
        XCTAssertEqual(replacements, 0)

    }

    func testPrimaryRoundTripAndCommitAdvanceBothCASRevisionsExactlyOnce() async throws {
        let fixture = try makeReviewedAcademicFixture(seed: 700)
        let initial = try AcademicWorkspace(
            revision: 5,
            savedAt: testCompletedAt,
            content: fixture.content
        )
        let initialData = try encodeAcademicWorkspace(initial)
        let backing = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(
                primaryData: initialData,
                storageRevision: 8
            )
        )
        let store = NextStepAcademicStore(backing: backing)
        let loaded = try await store.load()

        let committed = try await store.commit(
            loaded.workspace.content,
            expected: loaded.token,
            savedAt: testCompletedAt.addingTimeInterval(1)
        )

        XCTAssertEqual(committed.workspace.revision, 6)
        XCTAssertEqual(committed.token.workspaceRevision, 6)
        XCTAssertEqual(committed.token.storageRevision, 9)
        XCTAssertEqual(
            committed.token.storageRootFingerprint,
            loaded.token.storageRootFingerprint
        )
        XCTAssertNotEqual(
            committed.token.storageStateFingerprint,
            loaded.token.storageStateFingerprint
        )
        let files = await backing.currentSnapshot()
        XCTAssertEqual(files.backup, .data(initialData))
        guard case let .data(primary) = files.primary else {
            return XCTFail("Expected committed primary data.")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        XCTAssertEqual(
            try decoder.decode(AcademicWorkspace.self, from: primary),
            committed.workspace
        )
        let replacements = await backing.replaceCallCount()
        XCTAssertEqual(replacements, 1)
    }

    func testCommitCannotMoveWorkspaceSaveTimeBackwards() async throws {
        let initial = try AcademicWorkspace(
            revision: 2,
            savedAt: testCompletedAt,
            content: .empty
        )
        let backing = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(
                primaryData: try encodeAcademicWorkspace(initial),
                fingerprintSeed: 904
            )
        )
        let store = NextStepAcademicStore(backing: backing)
        let loaded = try await store.load()

        do {
            _ = try await store.commit(
                .empty,
                expected: loaded.token,
                savedAt: testStartedAt
            )
            XCTFail("A CAS commit cannot move its durable save time backwards.")
        } catch {
            XCTAssertEqual(
                error as? AcademicDomainError,
                .chronologyViolation(
                    "An academic workspace commit cannot move savedAt backwards."
                )
            )
        }
        let writes = await backing.replaceCallCount()
        XCTAssertEqual(writes, 0)
    }

    func testStaleStoreAndBackingTokensCannotMutate() async throws {
        let backing = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot()
        )
        let store = NextStepAcademicStore(backing: backing)
        let first = try await store.load()
        let externallyAdvanced = try makeBackingSnapshot(
            fingerprintSeed: 900,
            storageRevision: 1
        )
        await backing.forceSnapshot(externallyAdvanced)

        do {
            _ = try await store.commit(
                .empty,
                expected: first.token,
                savedAt: AcademicWorkspace.emptySavedAt
            )
            XCTFail("Backing CAS must reject an externally stale storage token.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .backingConflict
            )
        }

        let refreshed = try await store.load()
        let committed = try await store.commit(
            .empty,
            expected: refreshed.token,
            savedAt: AcademicWorkspace.emptySavedAt
        )
        do {
            _ = try await store.commit(
                .empty,
                expected: refreshed.token,
                savedAt: AcademicWorkspace.emptySavedAt
            )
            XCTFail("A used workspace token must not be reusable.")
        } catch {
            XCTAssertEqual(error as? AcademicWorkspaceStoreError, .tokenConflict)
        }
        XCTAssertEqual(committed.workspace.revision, 1)
        XCTAssertEqual(committed.token.storageRevision, 2)
    }

    func testFingerprintDetectsOutOfBandBytesWithoutStorageRevisionAdvance() async throws {
        let backing = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(
                fingerprintSeed: 905,
                storageRevision: 0
            )
        )
        let store = NextStepAcademicStore(backing: backing)
        let loaded = try await store.load()
        let externalWorkspace = try AcademicWorkspace(
            revision: 1,
            savedAt: AcademicWorkspace.emptySavedAt,
            content: .empty
        )
        let externalSnapshot = try makeBackingSnapshot(
            primaryData: try encodeAcademicWorkspace(externalWorkspace),
            fingerprintSeed: 905,
            stateFingerprintSeed: 10_000_906,
            storageRevision: 0
        )
        XCTAssertEqual(
            externalSnapshot.version.rootFingerprint,
            loaded.token.storageRootFingerprint
        )
        XCTAssertNotEqual(
            externalSnapshot.version.stateFingerprint,
            loaded.token.storageStateFingerprint
        )
        await backing.forceSnapshot(externalSnapshot)

        do {
            _ = try await store.commit(
                .empty,
                expected: loaded.token,
                savedAt: AcademicWorkspace.emptySavedAt
            )
            XCTFail("Out-of-band bytes must invalidate CAS even at the same revision.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .backingConflict
            )
        }
        let unchangedExternalSnapshot = await backing.currentSnapshot()
        XCTAssertEqual(unchangedExternalSnapshot, externalSnapshot)
    }

    func testCorruptAndMissingPrimaryRecoverBackupWithOneCASRestore() async throws {
        let backupWorkspace = try AcademicWorkspace(
            revision: 9,
            savedAt: AcademicWorkspace.emptySavedAt,
            content: .empty
        )
        let backupData = try encodeAcademicWorkspace(backupWorkspace)

        let corruptBacking = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(
                primaryData: Data("not-json".utf8),
                backupData: backupData,
                fingerprintSeed: 910,
                storageRevision: 2
            )
        )
        let corruptStore = NextStepAcademicStore(backing: corruptBacking)
        let recoveredCorrupt = try await corruptStore.load()
        XCTAssertEqual(recoveredCorrupt.workspace, backupWorkspace)
        XCTAssertEqual(recoveredCorrupt.token.storageRevision, 3)
        XCTAssertEqual(
            recoveredCorrupt.token.storageRootFingerprint,
            AcademicWorkspaceStorageFingerprint(testUUID(910))
        )
        XCTAssertNotEqual(
            recoveredCorrupt.token.storageStateFingerprint,
            AcademicWorkspaceStateFingerprint(testUUID(10_000_910))
        )
        let corruptFiles = await corruptBacking.currentSnapshot()
        XCTAssertEqual(corruptFiles.primary, .data(backupData))
        XCTAssertEqual(corruptFiles.backup, .data(backupData))
        let corruptReplacements = await corruptBacking.replaceCallCount()
        XCTAssertEqual(corruptReplacements, 1)

        let missingBacking = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(
                primaryData: nil,
                backupData: backupData,
                fingerprintSeed: 911,
                storageRevision: 6
            )
        )
        let missingStore = NextStepAcademicStore(backing: missingBacking)
        let recoveredMissing = try await missingStore.load()
        XCTAssertEqual(recoveredMissing.workspace, backupWorkspace)
        XCTAssertEqual(recoveredMissing.token.storageRevision, 7)
        XCTAssertEqual(
            recoveredMissing.token.storageRootFingerprint,
            AcademicWorkspaceStorageFingerprint(testUUID(911))
        )
        XCTAssertNotEqual(
            recoveredMissing.token.storageStateFingerprint,
            AcademicWorkspaceStateFingerprint(testUUID(10_000_911))
        )
        let missingReplacements = await missingBacking.replaceCallCount()
        XCTAssertEqual(missingReplacements, 1)
    }

    func testFuturePrimaryFailsClosedWithoutFallbackOrWrite() async throws {
        let validBackup = try encodeAcademicWorkspace(.empty)
        let backing = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(
                primaryData: futureSchemaOnly(2),
                backupData: validBackup
            )
        )
        let store = NextStepAcademicStore(backing: backing)

        do {
            _ = try await store.load()
            XCTFail("A future primary must not fall back to an older backup.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .unsupportedSchema(slot: .primary, version: 2)
            )
            XCTAssertEqual(
                error.localizedDescription,
                "The primary academic workspace uses unsupported schema version 2."
            )
        }
        let replacements = await backing.replaceCallCount()
        XCTAssertEqual(replacements, 0)

        let largeVersion = 2_147_483_648
        let largeFutureBacking = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(
                primaryData: Data("{\"schemaVersion\":\(largeVersion)}".utf8),
                backupData: validBackup,
                fingerprintSeed: 914
            )
        )
        let largeFutureStore = NextStepAcademicStore(backing: largeFutureBacking)
        do {
            _ = try await largeFutureStore.load()
            XCTFail("Large integral future versions must not be classified as corruption.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .unsupportedSchema(slot: .primary, version: largeVersion)
            )
        }
        let largeFutureWrites = await largeFutureBacking.replaceCallCount()
        XCTAssertEqual(largeFutureWrites, 0)
    }

    func testOversizedSlotFailsClosedWithoutAllocationFallbackOrWrite() async throws {
        let backing = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(
                backupData: try encodeAcademicWorkspace(.empty),
                primarySlot: .oversized,
                fingerprintSeed: 915
            )
        )
        let store = NextStepAcademicStore(backing: backing)

        do {
            _ = try await store.load()
            XCTFail("An oversized primary must not be read, treated as missing, or replaced.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .encodedWorkspaceTooLarge
            )
        }
        let writes = await backing.replaceCallCount()
        XCTAssertEqual(writes, 0)
        let files = await backing.currentSnapshot()
        XCTAssertEqual(files.primary, .oversized)
    }

    func testNestedFutureSchemaIsFoundByJSONPreflightBeforeFallback() async throws {
        let course = try makeAcademicCourse()
        let current = try AcademicWorkspace(
            revision: 1,
            savedAt: testCompletedAt,
            courses: [course]
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try encodeAcademicWorkspace(current)
            ) as? [String: Any]
        )
        var courses = try XCTUnwrap(object["courses"] as? [[String: Any]])
        courses[0]["schemaVersion"] = 2
        object["courses"] = courses
        let futureNested = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        let backing = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(
                primaryData: futureNested,
                backupData: try encodeAcademicWorkspace(.empty)
            )
        )
        let store = NextStepAcademicStore(backing: backing)

        do {
            _ = try await store.load()
            XCTFail("A nested future entity must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .unsupportedSchema(slot: .primary, version: 2)
            )
        }
        let replacements = await backing.replaceCallCount()
        XCTAssertEqual(replacements, 0)
    }

    func testFutureBackupAndTwoCorruptCopiesNeverWrite() async throws {
        let currentPrimaryFutureBackup = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(
                primaryData: try encodeAcademicWorkspace(.empty),
                backupData: futureSchemaOnly(4),
                fingerprintSeed: 919
            )
        )
        let mixedStore = NextStepAcademicStore(backing: currentPrimaryFutureBackup)
        do {
            _ = try await mixedStore.load()
            XCTFail("A future backup must fail closed even beside a current primary.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .unsupportedSchema(slot: .backup, version: 4)
            )
        }
        let mixedWrites = await currentPrimaryFutureBackup.replaceCallCount()
        XCTAssertEqual(mixedWrites, 0)

        let futureBackup = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(
                primaryData: Data("broken".utf8),
                backupData: futureSchemaOnly(3),
                fingerprintSeed: 920
            )
        )
        let futureStore = NextStepAcademicStore(backing: futureBackup)
        do {
            _ = try await futureStore.load()
            XCTFail("A future backup must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .unsupportedSchema(slot: .backup, version: 3)
            )
        }
        let futureWrites = await futureBackup.replaceCallCount()
        XCTAssertEqual(futureWrites, 0)

        let corruptBacking = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(
                primaryData: Data("broken-primary".utf8),
                backupData: Data("broken-backup".utf8),
                fingerprintSeed: 921
            )
        )
        let corruptStore = NextStepAcademicStore(backing: corruptBacking)
        do {
            _ = try await corruptStore.load()
            XCTFail("Two corrupt copies must not become an empty workspace.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .unrecoverableWorkspace
            )
        }
        let corruptWrites = await corruptBacking.replaceCallCount()
        XCTAssertEqual(corruptWrites, 0)
    }

    func testNewerOrDivergentCurrentSchemaBackupFailsClosedAsSplitBrain() async throws {
        let primary = try AcademicWorkspace(
            revision: 4,
            savedAt: AcademicWorkspace.emptySavedAt,
            content: .empty
        )
        let newerBackup = try AcademicWorkspace(
            revision: 5,
            savedAt: AcademicWorkspace.emptySavedAt,
            content: .empty
        )
        let backing = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(
                primaryData: try encodeAcademicWorkspace(primary),
                backupData: try encodeAcademicWorkspace(newerBackup),
                fingerprintSeed: 925
            )
        )
        let store = NextStepAcademicStore(backing: backing)

        do {
            _ = try await store.load()
            XCTFail("A newer backup must not be overwritten by an older primary.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .invalidBackingSnapshot
            )
        }
        let writes = await backing.replaceCallCount()
        XCTAssertEqual(writes, 0)

        let divergentBackup = try AcademicWorkspace(
            revision: 4,
            savedAt: AcademicWorkspace.emptySavedAt.addingTimeInterval(1),
            content: .empty
        )
        let divergentBacking = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(
                primaryData: try encodeAcademicWorkspace(primary),
                backupData: try encodeAcademicWorkspace(divergentBackup),
                fingerprintSeed: 926
            )
        )
        let divergentStore = NextStepAcademicStore(backing: divergentBacking)
        do {
            _ = try await divergentStore.load()
            XCTFail("Equal revisions with different canonical bytes must fail closed.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .invalidBackingSnapshot
            )
        }
        let divergentWrites = await divergentBacking.replaceCallCount()
        XCTAssertEqual(divergentWrites, 0)
    }

    func testResetAtomicallyClearsPrimaryAndBackup() async throws {
        let initial = try AcademicWorkspace(
            revision: 4,
            savedAt: AcademicWorkspace.emptySavedAt,
            content: .empty
        )
        let data = try encodeAcademicWorkspace(initial)
        let backing = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(
                primaryData: data,
                backupData: data,
                storageRevision: 10
            )
        )
        let store = NextStepAcademicStore(backing: backing)
        let loaded = try await store.load()

        let reset = try await store.reset(expected: loaded.token)

        XCTAssertEqual(reset.workspace, .empty)
        XCTAssertEqual(reset.token.workspaceRevision, 0)
        XCTAssertEqual(reset.token.storageRevision, 11)
        XCTAssertEqual(
            reset.token.storageRootFingerprint,
            loaded.token.storageRootFingerprint
        )
        XCTAssertNotEqual(
            reset.token.storageStateFingerprint,
            loaded.token.storageStateFingerprint
        )
        let files = await backing.currentSnapshot()
        XCTAssertEqual(files.primary, .missing)
        XCTAssertEqual(files.backup, .missing)
        let resets = await backing.resetCallCount()
        XCTAssertEqual(resets, 1)
    }

    func testRevisionOverflowStopsBeforeBackingMutation() async throws {
        let maximumWorkspace = try AcademicWorkspace(
            revision: Int64.max,
            savedAt: AcademicWorkspace.emptySavedAt,
            content: .empty
        )
        let workspaceBacking = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(
                primaryData: try encodeAcademicWorkspace(maximumWorkspace),
                fingerprintSeed: 930
            )
        )
        let workspaceStore = NextStepAcademicStore(backing: workspaceBacking)
        let maximumLoaded = try await workspaceStore.load()
        do {
            _ = try await workspaceStore.commit(
                .empty,
                expected: maximumLoaded.token,
                savedAt: AcademicWorkspace.emptySavedAt
            )
            XCTFail("Workspace revision overflow must fail.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .workspaceRevisionOverflow
            )
        }
        let workspaceWrites = await workspaceBacking.replaceCallCount()
        XCTAssertEqual(workspaceWrites, 0)

        let storageBacking = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(
                fingerprintSeed: 931,
                storageRevision: Int64.max
            )
        )
        let storageStore = NextStepAcademicStore(backing: storageBacking)
        let storageLoaded = try await storageStore.load()
        do {
            _ = try await storageStore.commit(
                .empty,
                expected: storageLoaded.token,
                savedAt: AcademicWorkspace.emptySavedAt
            )
            XCTFail("Storage revision overflow must fail.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .storageRevisionOverflow
            )
        }
        let storageWrites = await storageBacking.replaceCallCount()
        XCTAssertEqual(storageWrites, 0)
    }

    func testCanonicalEncodingHasFixedSixteenMiBLimit() async throws {
        let backing = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(fingerprintSeed: 940)
        )
        let store = NextStepAcademicStore(backing: backing)
        let loaded = try await store.load()
        let rawText = String(
            repeating: "a",
            count: AcademicDomainLimits.maximumCaptureTextCharacters
        )
        let largeDraft = try CaptureDraftFields(details: rawText)
        var captures: [CaptureItem] = []
        captures.reserveCapacity(540)
        for index in 0..<540 {
            captures.append(try CaptureItem.create(
                id: CaptureItemID(testUUID(100_000 + index)),
                kind: .researchIdea,
                source: .quickCapture(try QuickCaptureReference()),
                rawText: rawText,
                draftFields: largeDraft,
                capturedAt: testStartedAt,
                auditID: CaptureAuditEntryID(testUUID(200_000 + index))
            ))
        }
        let content = try AcademicWorkspaceContent(captures: captures)
        let candidate = try AcademicWorkspace(
            revision: 1,
            savedAt: testStartedAt,
            content: content
        )
        let boundedEncoder = JSONEncoder()
        boundedEncoder.dateEncodingStrategy = .millisecondsSince1970
        boundedEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertFalse(try AcademicWorkspaceEncodingPreflight.fits(
            candidate,
            encoder: boundedEncoder
        ))

        do {
            _ = try await store.commit(
                content,
                expected: loaded.token,
                savedAt: testStartedAt
            )
            XCTFail("An encoded workspace over 16 MiB must fail.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .encodedWorkspaceTooLarge
            )
        }
        let writes = await backing.replaceCallCount()
        XCTAssertEqual(writes, 0)
    }

    func testRootTransitionGateReplacesFingerprintAndInvalidatesOldToken() async throws {
        let backing = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(fingerprintSeed: 950)
        )
        let store = NextStepAcademicStore(backing: backing)
        let old = try await store.load()
        let gate = try await store.prepareForRootTransition()

        do {
            _ = try await store.load()
            XCTFail("Normal loads must remain closed during a root transition.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .rootTransitionInProgress
            )
        }

        let newWorkspace = try AcademicWorkspace(
            revision: 12,
            savedAt: AcademicWorkspace.emptySavedAt,
            content: .empty
        )
        await backing.forceSnapshot(try makeBackingSnapshot(
            primaryData: try encodeAcademicWorkspace(newWorkspace),
            fingerprintSeed: 951,
            storageRevision: 3
        ))
        let transitioned = try await store.finishRootTransition(gate)
        XCTAssertEqual(transitioned.workspace, newWorkspace)
        XCTAssertEqual(
            transitioned.token.storageRootFingerprint,
            AcademicWorkspaceStorageFingerprint(testUUID(951))
        )
        XCTAssertNotEqual(
            transitioned.token.storageRootFingerprint,
            old.token.storageRootFingerprint
        )

        do {
            _ = try await store.commit(
                .empty,
                expected: old.token,
                savedAt: AcademicWorkspace.emptySavedAt
            )
            XCTFail("A token from the prior root must be invalid.")
        } catch {
            XCTAssertEqual(error as? AcademicWorkspaceStoreError, .tokenConflict)
        }
    }

    func testRootTransitionIdentityPreventsOldTokenRevivalOnVersionCollision() async throws {
        let backing = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(fingerprintSeed: 955)
        )
        let store = NextStepAcademicStore(backing: backing)
        let old = try await store.load()
        let gate = try await store.prepareForRootTransition()

        // Model a cancelled transition or a backing identity collision: every
        // public storage/workspace value is unchanged after finish.
        let reopened = try await store.finishRootTransition(gate)
        XCTAssertEqual(reopened.workspace, old.workspace)
        XCTAssertEqual(reopened.token.workspaceRevision, old.token.workspaceRevision)
        XCTAssertEqual(reopened.token.storageRevision, old.token.storageRevision)
        XCTAssertEqual(
            reopened.token.storageRootFingerprint,
            old.token.storageRootFingerprint
        )
        XCTAssertEqual(
            reopened.token.storageStateFingerprint,
            old.token.storageStateFingerprint
        )
        XCTAssertNotEqual(reopened.token, old.token)

        do {
            _ = try await store.commit(
                .empty,
                expected: old.token,
                savedAt: AcademicWorkspace.emptySavedAt
            )
            XCTFail("The hidden transition identity must invalidate the old token.")
        } catch {
            XCTAssertEqual(error as? AcademicWorkspaceStoreError, .tokenConflict)
        }
    }

    func testPrepareCannotRaceAReadSuspendedAcrossAwait() async throws {
        let backing = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(fingerprintSeed: 960)
        )
        await backing.armReadPause()
        let store = NextStepAcademicStore(backing: backing)
        let loadTask = Task { try await store.load() }
        await backing.waitUntilReadIsPaused()

        do {
            _ = try await store.prepareForRootTransition()
            XCTFail("A root transition cannot supersede in-flight file I/O.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .operationInProgress
            )
        }
        await backing.resumePausedRead()
        let loaded = try await loadTask.value
        let current = try await store.currentSnapshot()
        XCTAssertEqual(current, loaded)
    }

    func testSuccessfulRevisionWithUnchangedStateFingerprintIsInvalid() async throws {
        let backing = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(fingerprintSeed: 965)
        )
        let store = NextStepAcademicStore(backing: backing)
        let loaded = try await store.load()
        await backing.preserveStateFingerprintForNextReplacement()

        do {
            _ = try await store.commit(
                .empty,
                expected: loaded.token,
                savedAt: AcademicWorkspace.emptySavedAt
            )
            XCTFail("A successful backing mutation must rotate its state fingerprint.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .invalidBackingSnapshot
            )
        }
        let files = await backing.currentSnapshot()
        XCTAssertEqual(files.version.storageRevision, 1)
        XCTAssertEqual(
            files.version.rootFingerprint,
            loaded.token.storageRootFingerprint
        )
        XCTAssertEqual(
            files.version.stateFingerprint,
            loaded.token.storageStateFingerprint
        )

        let changedRootBacking = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(fingerprintSeed: 966)
        )
        let changedRootStore = NextStepAcademicStore(backing: changedRootBacking)
        let changedRootLoaded = try await changedRootStore.load()
        await changedRootBacking.changeRootFingerprintForNextReplacement()
        do {
            _ = try await changedRootStore.commit(
                .empty,
                expected: changedRootLoaded.token,
                savedAt: AcademicWorkspace.emptySavedAt
            )
            XCTFail("A normal mutation cannot silently change storage roots.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .invalidBackingSnapshot
            )
        }
        let changedRootFiles = await changedRootBacking.currentSnapshot()
        XCTAssertEqual(changedRootFiles.version.storageRevision, 1)
        XCTAssertNotEqual(
            changedRootFiles.version.rootFingerprint,
            changedRootLoaded.token.storageRootFingerprint
        )
        XCTAssertNotEqual(
            changedRootFiles.version.stateFingerprint,
            changedRootLoaded.token.storageStateFingerprint
        )
    }

    func testInvalidBackingResultAndBackingErrorsAreSanitized() async throws {
        let backing = ControlledAcademicWorkspaceBacking(
            snapshot: try makeBackingSnapshot(fingerprintSeed: 970)
        )
        let store = NextStepAcademicStore(backing: backing)
        await backing.failNextRead(with: .unavailable)
        do {
            _ = try await store.load()
            XCTFail("An arbitrary backing error must be sanitized.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .backingUnavailable(operation: .load)
            )
            XCTAssertEqual(
                error.localizedDescription,
                "The academic workspace backing is unavailable during load."
            )
            XCTAssertFalse(error.localizedDescription.contains("private"))
        }

        let loaded = try await store.load()
        await backing.returnInvalidNextReplacement()
        do {
            _ = try await store.commit(
                .empty,
                expected: loaded.token,
                savedAt: AcademicWorkspace.emptySavedAt
            )
            XCTFail("A backing must advance its storage revision exactly once.")
        } catch {
            XCTAssertEqual(
                error as? AcademicWorkspaceStoreError,
                .invalidBackingSnapshot
            )
        }
        let current = try await store.currentSnapshot()
        XCTAssertEqual(current, loaded)
    }
}
