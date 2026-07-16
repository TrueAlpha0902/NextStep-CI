import Foundation
import XCTest
@testable import NextStepSync

final class NextStepSyncEngineTests: XCTestCase {
    func testReadIfPresentReturnsNilWhenFreshStoreHasNoBlobAncestors() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            at: fixture.localA,
            withIntermediateDirectories: true
        )
        let missingBlob = try SyncRelativePath("blobs/aa/missing.blob")

        let bytes = try SecureSyncFolder.readIfPresent(
            rootURL: fixture.localA,
            path: missingBlob,
            maximumBytes: 1_024
        )

        XCTAssertNil(bytes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.localA.appendingPathComponent("blobs").path
            ),
            "A read-only lookup must not create the missing blob hierarchy."
        )
    }

    func testFolderRoundTripBlobDuplicateAndTombstone() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let transportA = try FileFolderSyncTransport(
            rootURL: fixture.remote,
            requiresSecurityScopedAccess: false
        )
        let transportB = try FileFolderSyncTransport(
            rootURL: fixture.remote,
            requiresSecurityScopedAccess: false
        )
        let deviceA = DeviceID(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!)
        let deviceB = DeviceID(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!)
        let entity = try entity()
        let title = try SyncKey("title")
        let attachment = try SyncKey("attachment")
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let engineA = try NextStepSyncEngine(
            libraryID: fixture.libraryID,
            deviceID: deviceA,
            localRootURL: fixture.localA,
            transport: transportA,
            now: { instant }
        )
        let engineB = try NextStepSyncEngine(
            libraryID: fixture.libraryID,
            deviceID: deviceB,
            localRootURL: fixture.localB,
            transport: transportB,
            now: { instant.addingTimeInterval(1) }
        )

        _ = try await engineA.enqueueSet(
            entity: entity,
            field: title,
            value: .string("NextStep"),
            policy: .flexibleLastWriterWins
        )
        let blobBytes = Data("grounded-source".utf8)
        let blobMutation = try await engineA.enqueueBlob(
            entity: entity,
            field: attachment,
            data: blobBytes,
            mediaType: "text/plain",
            policy: .immutable
        )
        let initialPendingCount = try await engineA.pendingOperationCount()
        XCTAssertEqual(initialPendingCount, 2)

        let upload = try await engineA.synchronize()
        XCTAssertEqual(upload.uploadedOperationCount, 2)
        XCTAssertEqual(upload.pendingOperationCount, 0)

        let download = try await engineB.synchronize()
        XCTAssertEqual(download.importedOperationCount, 2)
        let snapshot = try await engineB.snapshot()
        XCTAssertEqual(snapshot.entity(entity)?.field(title)?.value, .string("NextStep"))
        let downloadedBlob = try await engineB.blobData(for: blobMutation.reference)
        XCTAssertEqual(downloadedBlob, blobBytes)

        let duplicate = try await engineB.synchronize()
        XCTAssertEqual(duplicate.importedOperationCount, 0)
        XCTAssertGreaterThanOrEqual(duplicate.duplicateOperationCount, 2)
        let duplicateSnapshot = try await engineB.snapshot()
        XCTAssertEqual(duplicateSnapshot.entity(entity)?.field(title)?.history.count, 1)

        _ = try await engineA.enqueueTombstone(entity: entity, reason: "User deleted this goal")
        _ = try await engineA.synchronize()
        _ = try await engineB.synchronize()
        let deletedSnapshot = try await engineB.snapshot()
        XCTAssertEqual(deletedSnapshot.entity(entity)?.isDeleted, true)
    }

    func testOutOfOrderFlexibleOperationsConvergeAndPreserveHistory() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transport = try FileFolderSyncTransport(
            rootURL: fixture.remote,
            requiresSecurityScopedAccess: false
        )
        let entity = try entity()
        let field = try SyncKey("displayName")
        let older = try operation(
            libraryID: fixture.libraryID,
            deviceID: DeviceID(UUID(uuidString: "10000000-0000-0000-0000-000000000001")!),
            sequence: 1,
            physical: 100,
            entity: entity,
            field: field,
            value: "older",
            policy: .flexibleLastWriterWins
        )
        let newer = try operation(
            libraryID: fixture.libraryID,
            deviceID: DeviceID(UUID(uuidString: "20000000-0000-0000-0000-000000000002")!),
            sequence: 1,
            physical: 200,
            entity: entity,
            field: field,
            value: "newer",
            policy: .flexibleLastWriterWins
        )
        let forward = try NextStepSyncEngine(
            libraryID: fixture.libraryID,
            deviceID: DeviceID(UUID(uuidString: "30000000-0000-0000-0000-000000000003")!),
            localRootURL: fixture.localA,
            transport: transport,
            now: { Date(timeIntervalSince1970: 1) }
        )
        let reverse = try NextStepSyncEngine(
            libraryID: fixture.libraryID,
            deviceID: DeviceID(UUID(uuidString: "40000000-0000-0000-0000-000000000004")!),
            localRootURL: fixture.localB,
            transport: transport,
            now: { Date(timeIntervalSince1970: 1) }
        )
        let olderEnvelope = try SyncCodec.encodeOperationEnvelope(older)
        let newerEnvelope = try SyncCodec.encodeOperationEnvelope(newer)

        let forwardOlderAccepted = try await forward.ingestOperationEnvelope(olderEnvelope)
        let forwardNewerAccepted = try await forward.ingestOperationEnvelope(newerEnvelope)
        let forwardDuplicateAccepted = try await forward.ingestOperationEnvelope(newerEnvelope)
        let reverseNewerAccepted = try await reverse.ingestOperationEnvelope(newerEnvelope)
        let reverseOlderAccepted = try await reverse.ingestOperationEnvelope(olderEnvelope)
        XCTAssertTrue(forwardOlderAccepted)
        XCTAssertTrue(forwardNewerAccepted)
        XCTAssertFalse(forwardDuplicateAccepted)
        XCTAssertTrue(reverseNewerAccepted)
        XCTAssertTrue(reverseOlderAccepted)

        let forwardSnapshot = try await forward.snapshot()
        let reverseSnapshot = try await reverse.snapshot()
        let forwardField = forwardSnapshot.entity(entity)?.field(field)
        let reverseField = reverseSnapshot.entity(entity)?.field(field)
        XCTAssertEqual(forwardField?.value, .string("newer"))
        XCTAssertEqual(reverseField?.value, .string("newer"))
        XCTAssertEqual(forwardField?.history, reverseField?.history)
        XCTAssertEqual(forwardField?.history.count, 2)
    }

    func testConfirmedFactConflictRequiresExplicitResolution() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transport = try FileFolderSyncTransport(
            rootURL: fixture.remote,
            requiresSecurityScopedAccess: false
        )
        let resolverDevice = DeviceID(UUID(uuidString: "50000000-0000-0000-0000-000000000005")!)
        let engine = try NextStepSyncEngine(
            libraryID: fixture.libraryID,
            deviceID: resolverDevice,
            localRootURL: fixture.localA,
            transport: transport,
            now: { Date(timeIntervalSince1970: 2) }
        )
        let entity = try entity()
        let field = try SyncKey("confirmedDeadline")
        let first = try operation(
            libraryID: fixture.libraryID,
            deviceID: DeviceID(UUID(uuidString: "60000000-0000-0000-0000-000000000006")!),
            sequence: 1,
            physical: 100,
            entity: entity,
            field: field,
            value: "2028-05-01",
            policy: .confirmed
        )
        let second = try operation(
            libraryID: fixture.libraryID,
            deviceID: DeviceID(UUID(uuidString: "70000000-0000-0000-0000-000000000007")!),
            sequence: 1,
            physical: 200,
            entity: entity,
            field: field,
            value: "2028-06-01",
            policy: .confirmed
        )
        _ = try await engine.ingestOperationEnvelope(SyncCodec.encodeOperationEnvelope(second))
        _ = try await engine.ingestOperationEnvelope(SyncCodec.encodeOperationEnvelope(first))

        let unresolved = try await engine.snapshot()
        XCTAssertEqual(unresolved.conflicts.count, 1)
        XCTAssertEqual(unresolved.conflicts[0].status, .unresolved)
        // The earliest confirmed value remains visible until the user decides.
        XCTAssertEqual(unresolved.entity(entity)?.field(field)?.value, .string("2028-05-01"))

        _ = try await engine.resolveConflict(
            unresolved.conflicts[0].id,
            choosing: second.id,
            entity: entity
        )
        let resolved = try await engine.snapshot()
        XCTAssertEqual(resolved.conflicts[0].status, .resolved)
        XCTAssertEqual(resolved.entity(entity)?.field(field)?.value, .string("2028-06-01"))
        XCTAssertEqual(resolved.conflicts[0].chosenOperationID, second.id)
        XCTAssertEqual(resolved.entity(entity)?.field(field)?.history.count, 2)
    }

    func testTamperedEnvelopeIsRejectedBeforeImport() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let operation = try operation(
            libraryID: fixture.libraryID,
            deviceID: DeviceID(UUID(uuidString: "80000000-0000-0000-0000-000000000008")!),
            sequence: 1,
            physical: 100,
            entity: try entity(),
            field: try SyncKey("title"),
            value: "trusted",
            policy: .immutable
        )
        let envelope = try SyncCodec.encodeOperationEnvelope(operation)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: envelope) as? [String: Any]
        )
        var encodedPayload = try XCTUnwrap(object["payload"] as? String)
        let replacement = encodedPayload.first == "A" ? "B" : "A"
        encodedPayload.replaceSubrange(encodedPayload.startIndex ... encodedPayload.startIndex, with: replacement)
        object["payload"] = encodedPayload
        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        do {
            _ = try SyncCodec.decodeOperationEnvelope(tampered)
            XCTFail("A changed payload must not pass its original SHA-256 digest.")
        } catch NextStepSyncError.integrityMismatch(_, _) {
            // Expected.
        } catch {
            XCTFail("Expected an integrity error, got \(error)")
        }
    }

    func testTraversalAndSymlinkPathsAreRejected() async throws {
        XCTAssertThrowsError(try SyncRelativePath("../escape"))
        XCTAssertThrowsError(try SyncRelativePath("safe/../../escape"))
        XCTAssertThrowsError(try SyncRelativePath("safe\\escape"))

        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let external = fixture.root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try Data("secret".utf8).write(to: external.appendingPathComponent("value"))
        try FileManager.default.createSymbolicLink(
            at: fixture.remote.appendingPathComponent("linked", isDirectory: true),
            withDestinationURL: external
        )
        let transport = try FileFolderSyncTransport(
            rootURL: fixture.remote,
            requiresSecurityScopedAccess: false
        )
        do {
            _ = try await transport.read(try SyncRelativePath("linked/value"), maximumBytes: 100)
            XCTFail("An ancestor symlink must not escape the selected folder.")
        } catch NextStepSyncError.symlinkRejected(_) {
            // Expected.
        }
    }

    func testOfflineQueueSurvivesAndRetriesWithoutDuplicatePublication() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let baseTransport = try FileFolderSyncTransport(
            rootURL: fixture.remote,
            requiresSecurityScopedAccess: false
        )
        let flaky = FlakyAvailabilityTransport(base: baseTransport)
        let engine = try NextStepSyncEngine(
            libraryID: fixture.libraryID,
            deviceID: DeviceID(UUID(uuidString: "90000000-0000-0000-0000-000000000009")!),
            localRootURL: fixture.localA,
            transport: flaky,
            now: { Date(timeIntervalSince1970: 3) }
        )
        _ = try await engine.enqueueSet(
            entity: try entity(),
            field: try SyncKey("title"),
            value: .string("queued offline"),
            policy: .flexibleLastWriterWins
        )

        do {
            _ = try await engine.synchronize()
            XCTFail("The first availability check is deliberately offline.")
        } catch NextStepSyncError.transportUnavailable {
            // Expected.
        }
        let pendingAfterFailure = try await engine.pendingOperationCount()
        XCTAssertEqual(pendingAfterFailure, 1)

        let retried = try await engine.synchronize()
        XCTAssertEqual(retried.uploadedOperationCount, 1)
        XCTAssertEqual(retried.pendingOperationCount, 0)
        let repeated = try await engine.synchronize()
        XCTAssertEqual(repeated.uploadedOperationCount, 0)
    }

    func testDeviceIdentityPersistsAcrossLaunches() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NextStepSyncIdentity-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let firstStore = try DeviceIdentityStore(rootURL: root)
        let first = try await firstStore.loadOrCreate()
        let secondStore = try DeviceIdentityStore(rootURL: root)
        let second = try await secondStore.loadOrCreate()
        XCTAssertEqual(first, second)
    }

    func testPendingQueueAndLocalValueRecoverAfterRelaunch() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transport = try FileFolderSyncTransport(
            rootURL: fixture.remote,
            requiresSecurityScopedAccess: false
        )
        let device = DeviceID(UUID(uuidString: "91000000-0000-0000-0000-000000000009")!)
        let entity = try entity()
        let field = try SyncKey("offlineValue")
        let firstLaunch = try NextStepSyncEngine(
            libraryID: fixture.libraryID,
            deviceID: device,
            localRootURL: fixture.localA,
            transport: transport,
            now: { Date(timeIntervalSince1970: 4) }
        )
        _ = try await firstLaunch.enqueueSet(
            entity: entity,
            field: field,
            value: .string("survives relaunch"),
            policy: .flexibleLastWriterWins
        )

        let secondLaunch = try NextStepSyncEngine(
            libraryID: fixture.libraryID,
            deviceID: device,
            localRootURL: fixture.localA,
            transport: transport,
            now: { Date(timeIntervalSince1970: 5) }
        )
        let recoveredSnapshot = try await secondLaunch.snapshot()
        let recoveredPending = try await secondLaunch.pendingOperationCount()
        XCTAssertEqual(
            recoveredSnapshot.entity(entity)?.field(field)?.value,
            .string("survives relaunch")
        )
        XCTAssertEqual(recoveredPending, 1)
        let report = try await secondLaunch.synchronize()
        XCTAssertEqual(report.uploadedOperationCount, 1)
        XCTAssertEqual(report.pendingOperationCount, 0)
    }

    func testSelectedFolderBookmarkRestoresSharedLibraryAcrossTwoDevices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NextStepSyncBookmark-\(UUID().uuidString)",
            isDirectory: true
        )
        let selectedFolder = root.appendingPathComponent("shared", isDirectory: true)
        try FileManager.default.createDirectory(
            at: selectedFolder,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try await NextStepSyncBootstrap.connectSelectedFolder(
            selectedFolder,
            applicationSupportRoot: root.appendingPathComponent("device-a", isDirectory: true)
        )
        let restored = try await NextStepSyncBootstrap.connectFileFolder(
            bookmark: first.bookmarkToPersist,
            applicationSupportRoot: root.appendingPathComponent("device-b", isDirectory: true),
            preferredLibraryID: first.libraryID
        )

        XCTAssertEqual(first.libraryID, restored.libraryID)
        XCTAssertNotEqual(first.deviceID, restored.deviceID)
        let resolution = try restored.bookmarkToPersist.resolve()
        XCTAssertEqual(
            resolution.url.resolvingSymlinksInPath(),
            selectedFolder.resolvingSymlinksInPath()
        )
        XCTAssertFalse(resolution.isStale)
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NextStepSyncTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let remote = root.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        return Fixture(
            root: root,
            remote: remote,
            localA: root.appendingPathComponent("local-a", isDirectory: true),
            localB: root.appendingPathComponent("local-b", isDirectory: true),
            libraryID: SyncLibraryID(UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!)
        )
    }

    private func entity() throws -> SyncEntityReference {
        SyncEntityReference(
            kind: try SyncKey("goal"),
            id: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
        )
    }

    private func operation(
        libraryID: SyncLibraryID,
        deviceID: DeviceID,
        sequence: UInt64,
        physical: Int64,
        entity: SyncEntityReference,
        field: SyncKey,
        value: String,
        policy: SyncFieldPolicy
    ) throws -> SyncOperation {
        try SyncOperation(
            id: UUID(),
            libraryID: libraryID,
            deviceID: deviceID,
            deviceSequence: sequence,
            timestamp: HybridLogicalTimestamp(
                physicalMilliseconds: physical,
                logicalCounter: 0,
                deviceID: deviceID
            ),
            entity: entity,
            mutation: .set(field: field, value: .string(value), policy: policy)
        )
    }
}

private struct Fixture {
    let root: URL
    let remote: URL
    let localA: URL
    let localB: URL
    let libraryID: SyncLibraryID
}

private actor FlakyAvailabilityTransport: SyncTransport {
    private let base: FileFolderSyncTransport
    private var availabilityChecks = 0

    init(base: FileFolderSyncTransport) {
        self.base = base
    }

    func isAvailable() async -> Bool {
        availabilityChecks += 1
        if availabilityChecks == 1 { return false }
        return await base.isAvailable()
    }

    func list(_ path: SyncRelativePath) async throws -> [SyncTransportEntry] {
        try await base.list(path)
    }

    func read(_ path: SyncRelativePath, maximumBytes: Int) async throws -> Data {
        try await base.read(path, maximumBytes: maximumBytes)
    }

    func writeImmutable(_ data: Data, to path: SyncRelativePath) async throws {
        try await base.writeImmutable(data, to: path)
    }

    func replaceAtomically(_ data: Data, at path: SyncRelativePath) async throws {
        try await base.replaceAtomically(data, at: path)
    }
}
