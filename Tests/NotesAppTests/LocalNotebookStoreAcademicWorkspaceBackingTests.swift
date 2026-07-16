import Dispatch
import Foundation
import NextStepAcademic
import XCTest
@testable import NotesApp

final class LocalNotebookStoreAcademicWorkspaceBackingTests: XCTestCase {
    func testEmptyReplaceResetAndRelaunchPreserveBoundedEnvelopeState() async throws {
        let location = try makeLocation("Lifecycle")
        defer { cleanUp(location) }
        let store = makeStore(at: location)

        let empty = try await store.read()
        XCTAssertEqual(empty.primary, .missing)
        XCTAssertEqual(empty.backup, .missing)
        XCTAssertEqual(empty.version.storageRevision, 0)

        let independentlyOpenedEmpty = try await makeStore(at: location).read()
        XCTAssertEqual(
            independentlyOpenedEmpty.version.stateFingerprint,
            empty.version.stateFingerprint,
            "A missing authority must have a deterministic state fingerprint."
        )

        let primary = Data("primary-v1".utf8)
        let backup = Data("backup-v1".utf8)
        let replaced = try await store.replace(
            primaryData: primary,
            backupData: backup,
            expected: empty.version
        )
        XCTAssertEqual(replaced.primary, .data(primary))
        XCTAssertEqual(replaced.backup, .data(backup))
        XCTAssertEqual(replaced.version.storageRevision, 1)
        XCTAssertEqual(replaced.version.rootFingerprint, empty.version.rootFingerprint)
        XCTAssertNotEqual(replaced.version.stateFingerprint, empty.version.stateFingerprint)

        let reset = try await store.reset(expected: replaced.version)
        XCTAssertEqual(reset.primary, .missing)
        XCTAssertEqual(reset.backup, .missing)
        XCTAssertEqual(reset.version.storageRevision, 2)
        XCTAssertEqual(reset.version.rootFingerprint, replaced.version.rootFingerprint)
        XCTAssertNotEqual(reset.version.stateFingerprint, replaced.version.stateFingerprint)
        XCTAssertNotEqual(reset.version.stateFingerprint, empty.version.stateFingerprint)

        let envelope = try Data(contentsOf: location.currentEnvelope)
        XCTAssertTrue(envelope.starts(with: Data("bplist00".utf8)))
        XCTAssertLessThanOrEqual(
            envelope.count,
            AcademicWorkspaceDiskLayout.maximumEnvelopeBytes
        )

        let relaunched = try await makeStore(at: location).read()
        XCTAssertEqual(relaunched.primary, .missing)
        XCTAssertEqual(relaunched.backup, .missing)
        XCTAssertEqual(relaunched.version.storageRevision, 2)
        XCTAssertEqual(relaunched.version.stateFingerprint, reset.version.stateFingerprint)
    }

    func testPrimaryAndBackupRoundTripExactlyAndOuterEnvelopeRetainsPreviousState() async throws {
        let location = try makeLocation("RoundTrip")
        defer { cleanUp(location) }
        let store = makeStore(at: location)
        let empty = try await store.read()
        let primary = Data([0, 1, 2, 3, 254, 255])
        let backup = Data([255, 0, 127, 128])

        let first = try await store.replace(
            primaryData: primary,
            backupData: backup,
            expected: empty.version
        )
        let firstEnvelope = try Data(contentsOf: location.currentEnvelope)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.previousEnvelope.path))

        let reopenedStore = makeStore(at: location)
        let reopened = try await reopenedStore.read()
        XCTAssertEqual(reopened.primary, .data(primary))
        XCTAssertEqual(reopened.backup, .data(backup))
        XCTAssertEqual(reopened.version.storageRevision, 1)
        XCTAssertEqual(reopened.version.stateFingerprint, first.version.stateFingerprint)

        let secondPrimary = Data("primary-v2".utf8)
        let second = try await reopenedStore.replace(
            primaryData: secondPrimary,
            backupData: primary,
            expected: reopened.version
        )
        XCTAssertEqual(second.version.storageRevision, 2)
        XCTAssertEqual(
            try Data(contentsOf: location.previousEnvelope),
            firstEnvelope,
            "The outer recovery copy must be the exact previously authoritative envelope."
        )

        let secondRelaunch = try await makeStore(at: location).read()
        XCTAssertEqual(secondRelaunch.primary, .data(secondPrimary))
        XCTAssertEqual(secondRelaunch.backup, .data(primary))
        XCTAssertEqual(secondRelaunch.version.stateFingerprint, second.version.stateFingerprint)
    }

    func testValidCurrentIgnoresInvalidOuterPreviousAndSafelyReplacesIt() async throws {
        let location = try makeLocation("LazyRecovery")
        defer { cleanUp(location) }
        let store = makeStore(at: location)
        let empty = try await store.read()
        let committed = try await store.replace(
            primaryData: Data("current-authority".utf8),
            backupData: Data("current-backup".utf8),
            expected: empty.version
        )
        let exactCurrent = try Data(contentsOf: location.currentEnvelope)

        let outsideTarget = location.parent.appendingPathComponent(
            "must-not-be-followed.plist",
            isDirectory: false
        )
        let outsideBytes = Data("outside-target".utf8)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: outsideTarget.path,
            contents: outsideBytes
        ))
        try FileManager.default.createSymbolicLink(
            at: location.previousEnvelope,
            withDestinationURL: outsideTarget
        )

        let observed = try await store.read()
        XCTAssertEqual(observed, committed)

        let advanced = try await store.replace(
            primaryData: Data("advanced".utf8),
            backupData: nil,
            expected: observed.version
        )
        XCTAssertEqual(advanced.version.storageRevision, 2)
        XCTAssertEqual(
            try Data(contentsOf: location.previousEnvelope),
            exactCurrent
        )
        XCTAssertEqual(
            try Data(contentsOf: outsideTarget),
            outsideBytes,
            "Replacing an invalid recovery symlink must not follow its target."
        )
    }

    func testSidecarInodeSwapFailsWithoutMutatingReplacementAuthority() async throws {
        let location = try makeLocation("SidecarSwap")
        defer { cleanUp(location) }
        let seedStore = makeStore(at: location)
        let empty = try await seedStore.read()
        _ = try await seedStore.replace(
            primaryData: Data("stable-authority".utf8),
            backupData: nil,
            expected: empty.version
        )
        let exactCurrent = try Data(contentsOf: location.currentEnvelope)

        let replacementSidecar = location.libraryRoot.appendingPathComponent(
            ".nextstep-academic.replacement",
            isDirectory: true
        )
        let detachedSidecar = location.libraryRoot.appendingPathComponent(
            ".nextstep-academic.detached",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: replacementSidecar,
            withIntermediateDirectories: false
        )
        let replacementCurrent = replacementSidecar.appendingPathComponent(
            AcademicWorkspaceDiskLayout.currentEnvelopeName,
            isDirectory: false
        )
        try exactCurrent.write(to: replacementCurrent)
        let sentinel = replacementSidecar.appendingPathComponent("sentinel", isDirectory: false)
        let sentinelBytes = Data("replacement-must-stay-untouched".utf8)
        try sentinelBytes.write(to: sentinel)

        let swapper = SidecarSwapAtomicWriter(
            liveSidecar: location.sidecar,
            detachedSidecar: detachedSidecar,
            replacementSidecar: replacementSidecar
        )
        let swappingStore = LocalNotebookStore(
            userDefaultsSuiteName: location.suiteName,
            overrideRoot: location.parent,
            academicWorkspaceAtomicWriter: { data, destinationName, authority in
                try swapper.write(
                    data,
                    named: destinationName,
                    authority: authority
                )
            }
        )
        let expected = try await swappingStore.read()
        do {
            _ = try await swappingStore.replace(
                primaryData: Data("must-not-land".utf8),
                backupData: nil,
                expected: expected.version
            )
            XCTFail("A swapped sidecar inode must invalidate the locked route.")
        } catch let error as AcademicWorkspaceFileBackingError {
            XCTAssertEqual(error, .unavailable)
        }

        XCTAssertEqual(
            try Data(contentsOf: location.currentEnvelope),
            exactCurrent,
            "The replacement authority must remain byte-for-byte untouched."
        )
        XCTAssertEqual(
            try Data(contentsOf: location.sidecar.appendingPathComponent("sentinel")),
            sentinelBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: detachedSidecar.appendingPathComponent(
                AcademicWorkspaceDiskLayout.currentEnvelopeName
            )),
            exactCurrent
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            location.previousEnvelope.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            detachedSidecar.appendingPathComponent(
                AcademicWorkspaceDiskLayout.previousEnvelopeName
            ).path))
    }

    func testOutOfBandSameRevisionEnvelopeReplacementConflictsOnStateFingerprint() async throws {
        let location = try makeLocation("Conflict")
        defer { cleanUp(location) }
        let store = makeStore(at: location)
        let empty = try await store.read()
        let committed = try await store.replace(
            primaryData: Data("owned".utf8),
            backupData: nil,
            expected: empty.version
        )

        let wrongRevision = try AcademicWorkspaceStorageVersion(
            rootFingerprint: committed.version.rootFingerprint,
            stateFingerprint: committed.version.stateFingerprint,
            storageRevision: committed.version.storageRevision + 1
        )
        do {
            _ = try await store.replace(
                primaryData: Data("wrong-revision".utf8),
                backupData: nil,
                expected: wrongRevision
            )
            XCTFail("CAS must reread and compare the storage revision.")
        } catch let error as AcademicWorkspaceFileBackingError {
            XCTAssertEqual(error, .conflict)
        }

        let tamperedPrimary = Data("out-of-band".utf8)
        let tamperedEnvelope = try AcademicWorkspaceDiskIO.encodeEnvelope(
            storageRevision: committed.version.storageRevision,
            primaryData: tamperedPrimary,
            backupData: nil
        )
        try tamperedEnvelope.write(to: location.currentEnvelope, options: .atomic)

        do {
            _ = try await store.replace(
                primaryData: Data("must-not-commit".utf8),
                backupData: nil,
                expected: committed.version
            )
            XCTFail("A same-revision out-of-band envelope must fail CAS.")
        } catch let error as AcademicWorkspaceFileBackingError {
            XCTAssertEqual(error, .conflict)
        }

        let observed = try await store.read()
        XCTAssertEqual(observed.primary, .data(tamperedPrimary))
        XCTAssertEqual(
            observed.version.storageRevision,
            committed.version.storageRevision
        )
        XCTAssertEqual(
            observed.version.rootFingerprint,
            committed.version.rootFingerprint
        )
        XCTAssertNotEqual(
            observed.version.stateFingerprint,
            committed.version.stateFingerprint
        )
    }

    func testConcurrentStoresSerializeCASSoOnlyOneWriterCommits() async throws {
        let location = try makeLocation("ConcurrentCAS")
        defer { cleanUp(location) }
        let blocker = BlockingCurrentAtomicWriter()
        let firstStore = LocalNotebookStore(
            userDefaultsSuiteName: location.suiteName,
            overrideRoot: location.parent,
            academicWorkspaceAtomicWriter: { data, destinationName, authority in
                try blocker.write(
                    data,
                    named: destinationName,
                    authority: authority
                )
            }
        )
        let secondStore = makeStore(at: location)
        let firstExpected = try await firstStore.read()
        let secondExpected = try await secondStore.read()

        let firstTask = Task {
            try await firstStore.replace(
                primaryData: Data("first-writer".utf8),
                backupData: nil,
                expected: firstExpected.version
            )
        }
        defer { blocker.release() }
        guard await blocker.waitUntilBlocked() else {
            blocker.release()
            _ = try? await firstTask.value
            XCTFail("The first writer did not reach its atomic commit boundary.")
            return
        }

        let secondTask = Task {
            try await secondStore.replace(
                primaryData: Data("second-writer".utf8),
                backupData: nil,
                expected: secondExpected.version
            )
        }
        // Give the second actor an opportunity to contend for the filesystem
        // lock while the first writer remains paused inside the critical section.
        await Task.yield()
        await Task.yield()
        blocker.release()

        let firstCommitted = try await firstTask.value
        do {
            _ = try await secondTask.value
            XCTFail("Two stores must not both commit from the same byte state.")
        } catch let error as AcademicWorkspaceFileBackingError {
            XCTAssertEqual(error, .conflict)
        }

        let surviving = try await firstStore.read()
        XCTAssertEqual(surviving, firstCommitted)
        XCTAssertEqual(surviving.primary, .data(Data("first-writer".utf8)))
        XCTAssertEqual(surviving.version.storageRevision, 1)
    }

    func testCorruptCurrentEnvelopeRecoversFromOuterPreviousEnvelope() async throws {
        let location = try makeLocation("Recovery")
        defer { cleanUp(location) }
        let store = makeStore(at: location)
        let empty = try await store.read()
        let firstPrimary = Data("recover-me".utf8)
        let firstBackup = Data("recover-backup".utf8)
        let first = try await store.replace(
            primaryData: firstPrimary,
            backupData: firstBackup,
            expected: empty.version
        )
        let second = try await store.replace(
            primaryData: Data("newer-current".utf8),
            backupData: firstPrimary,
            expected: first.version
        )
        XCTAssertEqual(second.version.storageRevision, 2)

        try Data("not-a-binary-plist".utf8).write(
            to: location.currentEnvelope,
            options: .atomic
        )

        let recoveredStore = makeStore(at: location)
        let recovered = try await recoveredStore.read()
        XCTAssertEqual(recovered.primary, .data(firstPrimary))
        XCTAssertEqual(recovered.backup, .data(firstBackup))
        XCTAssertEqual(recovered.version.storageRevision, 1)
        XCTAssertEqual(recovered.version.stateFingerprint, first.version.stateFingerprint)

        let repaired = try await recoveredStore.replace(
            primaryData: Data("repaired".utf8),
            backupData: firstPrimary,
            expected: recovered.version
        )
        XCTAssertEqual(repaired.version.storageRevision, 2)
        let repairedReread = try await recoveredStore.read()
        XCTAssertEqual(repairedReread, repaired)
    }

    func testOversizedEnvelopeIsRejectedBeforeAnyUnboundedRead() async throws {
        let location = try makeLocation("Oversized")
        defer { cleanUp(location) }
        try createSidecarDirectory(at: location)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: location.currentEnvelope.path,
            contents: Data()
        ))
        let handle = try FileHandle(forWritingTo: location.currentEnvelope)
        try handle.truncate(
            atOffset: UInt64(AcademicWorkspaceDiskLayout.maximumEnvelopeBytes + 1)
        )
        try handle.close()

        do {
            _ = try await makeStore(at: location).read()
            XCTFail("An oversized envelope must be rejected from metadata.")
        } catch let error as AcademicWorkspaceFileBackingError {
            XCTAssertEqual(error, .unavailable)
        }
    }

    func testSymbolicLinkEnvelopeIsRejected() async throws {
        let location = try makeLocation("SymbolicLink")
        defer { cleanUp(location) }
        try createSidecarDirectory(at: location)
        let target = location.parent.appendingPathComponent("target.plist")
        try AcademicWorkspaceDiskIO.encodeEnvelope(
            storageRevision: 1,
            primaryData: Data("target".utf8),
            backupData: nil
        ).write(to: target, options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: location.currentEnvelope,
            withDestinationURL: target
        )

        do {
            _ = try await makeStore(at: location).read()
            XCTFail("A symbolic-link envelope must never be followed.")
        } catch let error as AcademicWorkspaceFileBackingError {
            XCTAssertEqual(error, .unavailable)
        }
    }

    func testLibraryRootSymbolicLinkIsRejectedWithoutTouchingOutsideTarget() async throws {
        let location = try makeLocation("LibraryRootSymbolicLink")
        defer { cleanUp(location) }
        let store = makeStore(at: location)
        let empty = try await store.read()
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.libraryRoot.path))

        let outside = location.parent.appendingPathComponent(
            "outside-library",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let sentinel = outside.appendingPathComponent("sentinel", isDirectory: false)
        let sentinelBytes = Data("outside-must-stay-untouched".utf8)
        try sentinelBytes.write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: location.libraryRoot,
            withDestinationURL: outside
        )

        do {
            _ = try await store.replace(
                primaryData: Data("must-not-escape".utf8),
                backupData: nil,
                expected: empty.version
            )
            XCTFail("A Notes symlink must never become the library authority.")
        } catch let error as AcademicWorkspaceFileBackingError {
            XCTAssertEqual(error, .unavailable)
        }
        do {
            _ = try await makeStore(at: location).read()
            XCTFail("A Notes symlink must also be rejected by reads.")
        } catch let error as AcademicWorkspaceFileBackingError {
            XCTAssertEqual(error, .unavailable)
        }

        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            AcademicWorkspaceDiskLayout.sidecarDirectory(in: outside).path))
    }

    func testNonRegularEnvelopeIsRejected() async throws {
        let location = try makeLocation("NonRegular")
        defer { cleanUp(location) }
        try createSidecarDirectory(at: location)
        try FileManager.default.createDirectory(
            at: location.currentEnvelope,
            withIntermediateDirectories: false
        )

        do {
            _ = try await makeStore(at: location).read()
            XCTFail("A non-regular envelope must be rejected.")
        } catch let error as AcademicWorkspaceFileBackingError {
            XCTAssertEqual(error, .unavailable)
        }
    }

    func testHardLinkedEnvelopeIsRejected() async throws {
        let location = try makeLocation("HardLink")
        defer { cleanUp(location) }
        try createSidecarDirectory(at: location)
        let source = location.parent.appendingPathComponent("hard-link-source.plist")
        try AcademicWorkspaceDiskIO.encodeEnvelope(
            storageRevision: 1,
            primaryData: Data("linked".utf8),
            backupData: nil
        ).write(to: source, options: .atomic)
        try FileManager.default.linkItem(at: source, to: location.currentEnvelope)

        do {
            _ = try await makeStore(at: location).read()
            XCTFail("A multiply linked envelope must be rejected.")
        } catch let error as AcademicWorkspaceFileBackingError {
            XCTAssertEqual(error, .unavailable)
        }
    }

    func testCurrentAtomicWriteFailureDoesNotChangeAuthoritativeState() async throws {
        let location = try makeLocation("WriteFailure")
        defer { cleanUp(location) }
        let initialStore = makeStore(at: location)
        let empty = try await initialStore.read()
        _ = try await initialStore.replace(
            primaryData: Data("stable".utf8),
            backupData: Data("stable-backup".utf8),
            expected: empty.version
        )
        let exactCurrentBeforeFailure = try Data(contentsOf: location.currentEnvelope)

        let failingStore = LocalNotebookStore(
            userDefaultsSuiteName: location.suiteName,
            overrideRoot: location.parent,
            academicWorkspaceAtomicWriter: { data, destinationName, authority in
                if destinationName == AcademicWorkspaceDiskLayout.currentEnvelopeName {
                    throw InjectedWriteFailure.currentEnvelope
                }
                try AcademicWorkspaceDiskIO.atomicWrite(
                    data,
                    named: destinationName,
                    authority: authority
                )
            }
        )
        let expected = try await failingStore.read()
        do {
            _ = try await failingStore.replace(
                primaryData: Data("must-not-win".utf8),
                backupData: nil,
                expected: expected.version
            )
            XCTFail("The injected current-envelope write must fail.")
        } catch let error as AcademicWorkspaceFileBackingError {
            XCTAssertEqual(error, .unavailable)
        }

        XCTAssertEqual(
            try Data(contentsOf: location.currentEnvelope),
            exactCurrentBeforeFailure
        )
        let survivingState = try await failingStore.read()
        XCTAssertEqual(survivingState, expected)
        XCTAssertEqual(
            try Data(contentsOf: location.previousEnvelope),
            exactCurrentBeforeFailure,
            "A harmless outer refresh may complete before the current atomic failure."
        )
    }

    func testRootBeginRollbackFinalizeRotateGenerationAndKeepRootsIsolated() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AcademicWorkspaceRoots-\(UUID().uuidString)",
            isDirectory: true
        )
        let oldParent = base.appendingPathComponent("old", isDirectory: true)
        let rollbackParent = base.appendingPathComponent("rollback", isDirectory: true)
        let finalParent = base.appendingPathComponent("final", isDirectory: true)
        for directory in [oldParent, rollbackParent, finalParent] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let suiteName = "NotesAppTests.AcademicRoots.\(UUID().uuidString)"
        defer {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: base)
        }
        let store = LocalNotebookStore(userDefaultsSuiteName: suiteName)

        try await store.setRootDirectory(oldParent)
        let oldEmpty = try await store.read()
        let oldData = Data("old-root".utf8)
        let oldStored = try await store.replace(
            primaryData: oldData,
            backupData: nil,
            expected: oldEmpty.version
        )

        let rollbackPreparation = NotesAppLibraryRootPreparation()
        try await store.prepareRootDirectoryTransition(
            to: rollbackParent,
            preparation: rollbackPreparation
        )
        let rollbackTransition = try await store.beginRootDirectoryTransition(
            rollbackPreparation
        )
        do {
            _ = try await store.replace(
                primaryData: Data("wrong-token".utf8),
                backupData: nil,
                expected: oldStored.version
            )
            XCTFail("A pre-begin token must conflict after route generation rotates.")
        } catch let error as AcademicWorkspaceFileBackingError {
            XCTAssertEqual(error, .conflict)
        }

        let rollbackEmpty = try await store.read()
        XCTAssertNotEqual(
            rollbackEmpty.version.rootFingerprint,
            oldStored.version.rootFingerprint
        )
        let rollbackData = Data("rollback-candidate".utf8)
        let rollbackStored = try await store.replace(
            primaryData: rollbackData,
            backupData: nil,
            expected: rollbackEmpty.version
        )
        await store.rollbackRootDirectoryTransition(rollbackTransition)

        let restored = try await store.read()
        XCTAssertEqual(restored.primary, .data(oldData))
        XCTAssertEqual(restored.version.storageRevision, oldStored.version.storageRevision)
        XCTAssertEqual(
            restored.version.stateFingerprint,
            oldStored.version.stateFingerprint
        )
        XCTAssertNotEqual(
            restored.version.rootFingerprint,
            oldStored.version.rootFingerprint,
            "Rollback must rotate again rather than resurrecting old CAS tokens."
        )
        XCTAssertNotEqual(
            restored.version.rootFingerprint,
            rollbackStored.version.rootFingerprint
        )
        let rollbackRootVerification = try await LocalNotebookStore(
            overrideRoot: rollbackParent
        ).read()
        XCTAssertEqual(
            rollbackRootVerification.primary,
            .data(rollbackData),
            "Rolling routing back must not move or erase candidate-root bytes."
        )

        let finalPreparation = NotesAppLibraryRootPreparation()
        try await store.prepareRootDirectoryTransition(
            to: finalParent,
            preparation: finalPreparation
        )
        let finalTransition = try await store.beginRootDirectoryTransition(finalPreparation)
        let finalEmpty = try await store.read()
        let finalData = Data("final-root".utf8)
        let finalStored = try await store.replace(
            primaryData: finalData,
            backupData: nil,
            expected: finalEmpty.version
        )
        try await store.commitRootDirectoryTransition(finalTransition)
        await store.finalizeRootDirectoryTransition(finalTransition)

        let finalized = try await store.read()
        XCTAssertEqual(finalized, finalStored)
        XCTAssertEqual(finalized.primary, .data(finalData))
        XCTAssertEqual(
            finalized.version.rootFingerprint,
            finalStored.version.rootFingerprint,
            "Finalize must preserve the generation installed by begin."
        )
        let oldRootVerification = try await LocalNotebookStore(
            overrideRoot: oldParent
        ).read()
        let secondRollbackRootVerification = try await LocalNotebookStore(
            overrideRoot: rollbackParent
        ).read()
        XCTAssertEqual(oldRootVerification.primary, .data(oldData))
        XCTAssertEqual(secondRollbackRootVerification.primary, .data(rollbackData))
    }
}

private final class SidecarSwapAtomicWriter: @unchecked Sendable {
    private let liveSidecar: URL
    private let detachedSidecar: URL
    private let replacementSidecar: URL
    private let lock = NSLock()
    private var hasSwapped = false

    init(liveSidecar: URL, detachedSidecar: URL, replacementSidecar: URL) {
        self.liveSidecar = liveSidecar
        self.detachedSidecar = detachedSidecar
        self.replacementSidecar = replacementSidecar
    }

    func write(
        _ data: Data,
        named destinationName: String,
        authority: AcademicWorkspaceDirectoryAuthority
    ) throws {
        lock.lock()
        let shouldSwap = !hasSwapped
        hasSwapped = true
        lock.unlock()
        if shouldSwap {
            try FileManager.default.moveItem(at: liveSidecar, to: detachedSidecar)
            try FileManager.default.moveItem(at: replacementSidecar, to: liveSidecar)
        }
        try AcademicWorkspaceDiskIO.atomicWrite(
            data,
            named: destinationName,
            authority: authority
        )
    }
}

private final class BlockingCurrentAtomicWriter: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var hasBlocked = false

    func write(
        _ data: Data,
        named destinationName: String,
        authority: AcademicWorkspaceDirectoryAuthority
    ) throws {
        var shouldBlock = false
        if destinationName == AcademicWorkspaceDiskLayout.currentEnvelopeName {
            lock.lock()
            if !hasBlocked {
                hasBlocked = true
                shouldBlock = true
            }
            lock.unlock()
        }
        if shouldBlock {
            entered.signal()
            resume.wait()
        }
        try AcademicWorkspaceDiskIO.atomicWrite(
            data,
            named: destinationName,
            authority: authority
        )
    }

    func waitUntilBlocked() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = self.entered.wait(timeout: .now() + 5)
                continuation.resume(returning: result == .success)
            }
        }
    }

    func release() {
        resume.signal()
    }
}

private extension LocalNotebookStoreAcademicWorkspaceBackingTests {
    struct TestLocation {
        let parent: URL
        let libraryRoot: URL
        let sidecar: URL
        let currentEnvelope: URL
        let previousEnvelope: URL
        let suiteName: String
    }

    enum InjectedWriteFailure: Error {
        case currentEnvelope
    }

    func makeLocation(_ label: String) throws -> TestLocation {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "AcademicBacking-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let libraryRoot = parent.appendingPathComponent("Notes", isDirectory: true)
        let sidecar = AcademicWorkspaceDiskLayout.sidecarDirectory(in: libraryRoot)
        return TestLocation(
            parent: parent,
            libraryRoot: libraryRoot,
            sidecar: sidecar,
            currentEnvelope: AcademicWorkspaceDiskLayout.currentEnvelope(in: libraryRoot),
            previousEnvelope: AcademicWorkspaceDiskLayout.previousEnvelope(in: libraryRoot),
            suiteName: "NotesAppTests.AcademicBacking.\(label).\(UUID().uuidString)"
        )
    }

    func makeStore(at location: TestLocation) -> LocalNotebookStore {
        LocalNotebookStore(
            userDefaultsSuiteName: location.suiteName,
            overrideRoot: location.parent
        )
    }

    func createSidecarDirectory(at location: TestLocation) throws {
        try FileManager.default.createDirectory(
            at: location.sidecar,
            withIntermediateDirectories: true
        )
    }

    func cleanUp(_ location: TestLocation) {
        UserDefaults(suiteName: location.suiteName)?.removePersistentDomain(
            forName: location.suiteName
        )
        try? FileManager.default.removeItem(at: location.parent)
    }
}
