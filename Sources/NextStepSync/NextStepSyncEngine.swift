import Foundation

private struct SyncLocalMetadata: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var libraryID: SyncLibraryID
    var deviceID: DeviceID
    var nextDeviceSequence: UInt64
    var clock: HybridLogicalClock
}

private struct SyncLocalArchive: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var operations: [SyncOperation]
}

private struct DeviceIdentityRecord: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var deviceID: DeviceID
}

private struct SharedLibraryMarker: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var libraryID: SyncLibraryID
}

private struct RemoteSyncLayout: Sendable {
    let base: SyncRelativePath
    let manifests: SyncRelativePath
    let operations: SyncRelativePath
    let blobs: SyncRelativePath

    init(libraryID: SyncLibraryID) throws {
        let root = try SyncRelativePath(component: "NextStepSync-v1")
        base = try root.appending(libraryID.description)
        manifests = try base.appending("manifests")
        operations = try base.appending("operations")
        blobs = try base.appending("blobs")
    }

    func manifest(deviceID: DeviceID) throws -> SyncRelativePath {
        try manifests.appending("\(deviceID.description).manifest.json")
    }

    func operationDirectory(deviceID: DeviceID) throws -> SyncRelativePath {
        try operations.appending(deviceID.description)
    }

    func operation(deviceID: DeviceID, filename: String) throws -> SyncRelativePath {
        try operationDirectory(deviceID: deviceID).appending(filename)
    }

    func blob(_ digest: SyncDigest) throws -> SyncRelativePath {
        let prefix = String(digest.hex.prefix(2))
        return try blobs.appending(prefix).appending("\(digest.hex).blob")
    }
}

/// Persists one random identity per installed app/device. Never copy this file to
/// another device: per-device operation ownership depends on this uniqueness.
public actor DeviceIdentityStore {
    public nonisolated let rootURL: URL
    private let identityPath: SyncRelativePath

    public init(rootURL: URL) throws {
        let standardizedRoot = rootURL.standardizedFileURL
        self.rootURL = standardizedRoot
        self.identityPath = try SyncRelativePath(component: "device-identity.json")
        try SecureSyncFolder.prepareRoot(standardizedRoot, createIfMissing: true)
    }

    public func loadOrCreate() throws -> DeviceID {
        if let data = try SecureSyncFolder.readIfPresent(
            rootURL: rootURL,
            path: identityPath,
            maximumBytes: 16 * 1_024
        ) {
            let record = try SyncCodec.decodeEnvelope(
                DeviceIdentityRecord.self,
                from: data,
                maximumBytes: 8 * 1_024
            )
            guard record.schemaVersion == DeviceIdentityRecord.currentSchemaVersion else {
                throw NextStepSyncError.unsupportedSchemaVersion(record.schemaVersion)
            }
            return record.deviceID
        }

        let record = DeviceIdentityRecord(deviceID: DeviceID())
        let data = try SyncCodec.encodeEnvelope(record, maximumBytes: 8 * 1_024)
        try SecureSyncFolder.writeImmutable(rootURL: rootURL, path: identityPath, data: data)
        return record.deviceID
    }
}

public struct SyncBlobMutationResult: Sendable, Hashable {
    public let reference: SyncBlobReference
    public let operation: SyncOperation
}

/// Local-first sync façade. Mutations are durably queued before network/folder
/// publication, so loss of iCloud connectivity never blocks local editing.
public actor NextStepSyncEngine {
    public nonisolated let libraryID: SyncLibraryID
    public nonisolated let deviceID: DeviceID
    public nonisolated let localRootURL: URL

    private let transport: any SyncTransport
    private let remoteLayout: RemoteSyncLayout
    private let now: @Sendable () -> Date
    private var clock: HybridLogicalClock
    private var nextDeviceSequence: UInt64
    private var operationsByID: [UUID: SyncOperation]
    private var checkpoint: SyncCheckpoint

    public init(
        libraryID: SyncLibraryID,
        deviceID: DeviceID,
        localRootURL: URL,
        transport: any SyncTransport,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let standardizedLocalRoot = localRootURL.standardizedFileURL
        self.libraryID = libraryID
        self.deviceID = deviceID
        self.localRootURL = standardizedLocalRoot
        self.transport = transport
        self.remoteLayout = try RemoteSyncLayout(libraryID: libraryID)
        self.now = now
        self.clock = try HybridLogicalClock(deviceID: deviceID)
        self.nextDeviceSequence = 1
        self.operationsByID = [:]
        self.checkpoint = SyncCheckpoint()
        try SecureSyncFolder.prepareRoot(standardizedLocalRoot, createIfMissing: true)

        let metadataPath = try Self.localPath("metadata.json")
        let archivePath = try Self.localPath("accepted-operations.json")
        let checkpointPath = try Self.localPath("checkpoint.json")

        let metadata: SyncLocalMetadata?
        if let bytes = try SecureSyncFolder.readIfPresent(
            rootURL: standardizedLocalRoot,
            path: metadataPath,
            maximumBytes: 64 * 1_024
        ) {
            metadata = try SyncCodec.decodeEnvelope(
                SyncLocalMetadata.self,
                from: bytes,
                maximumBytes: 32 * 1_024
            )
        } else {
            metadata = nil
        }
        if let metadata {
            guard metadata.schemaVersion == SyncLocalMetadata.currentSchemaVersion else {
                throw NextStepSyncError.unsupportedSchemaVersion(metadata.schemaVersion)
            }
            guard metadata.libraryID == libraryID else {
                throw NextStepSyncError.incompatibleLibrary
            }
            guard metadata.deviceID == deviceID, metadata.clock.deviceID == deviceID else {
                throw NextStepSyncError.incompatibleDevice
            }
            guard metadata.nextDeviceSequence > 0,
                  metadata.clock.lastPhysicalMilliseconds >= 0 else {
                throw NextStepSyncError.malformedDocument("Invalid local sync clock or sequence.")
            }
        }

        var recoveredOperations: [UUID: SyncOperation] = [:]
        if let bytes = try SecureSyncFolder.readIfPresent(
            rootURL: standardizedLocalRoot,
            path: archivePath,
            maximumBytes: SyncLimits.maximumLocalArchiveBytes * 2
        ) {
            let archive = try SyncCodec.decodeEnvelope(
                SyncLocalArchive.self,
                from: bytes,
                maximumBytes: SyncLimits.maximumLocalArchiveBytes
            )
            guard archive.schemaVersion == SyncLocalArchive.currentSchemaVersion else {
                throw NextStepSyncError.unsupportedSchemaVersion(archive.schemaVersion)
            }
            guard archive.operations.count <= SyncLimits.maximumImportedOperations else {
                throw NextStepSyncError.operationLimitExceeded
            }
            for operation in archive.operations {
                try operation.validate()
                guard operation.libraryID == libraryID else {
                    throw NextStepSyncError.incompatibleLibrary
                }
                if let existing = recoveredOperations[operation.id], existing != operation {
                    throw NextStepSyncError.malformedDocument("Duplicate operation ID with different payload.")
                }
                recoveredOperations[operation.id] = operation
            }
        }

        var recoveredCheckpoint: SyncCheckpoint
        if let bytes = try SecureSyncFolder.readIfPresent(
            rootURL: standardizedLocalRoot,
            path: checkpointPath,
            maximumBytes: SyncLimits.maximumManifestBytes * 2
        ) {
            recoveredCheckpoint = try SyncCodec.decodeEnvelope(
                SyncCheckpoint.self,
                from: bytes,
                maximumBytes: SyncLimits.maximumManifestBytes
            )
            guard recoveredCheckpoint.schemaVersion == SyncCheckpoint.currentSchemaVersion else {
                throw NextStepSyncError.unsupportedSchemaVersion(recoveredCheckpoint.schemaVersion)
            }
            guard recoveredCheckpoint.importedOperationIDs.count
                    <= SyncLimits.maximumImportedOperations else {
                throw NextStepSyncError.operationLimitExceeded
            }
        } else {
            recoveredCheckpoint = SyncCheckpoint()
        }

        // Pending files are the crash-recovery authority. A mutation can exist here
        // even if a process died before rewriting the compact local archive.
        let recoveredPending = try Self.readPendingOperations(
            localRootURL: standardizedLocalRoot,
            libraryID: libraryID,
            deviceID: deviceID
        )
        for operation in recoveredPending {
            if let existing = recoveredOperations[operation.id], existing != operation {
                throw NextStepSyncError.malformedDocument("Pending operation collision.")
            }
            recoveredOperations[operation.id] = operation
        }
        guard recoveredOperations.count <= SyncLimits.maximumImportedOperations else {
            throw NextStepSyncError.operationLimitExceeded
        }
        try Self.validateSequences(recoveredOperations.values)
        recoveredCheckpoint.importedOperationIDs.formUnion(recoveredOperations.keys)

        let maximumTimestamp = recoveredOperations.values.map(\.timestamp).max()
        let metadataClock = metadata?.clock
        let maximumPhysical = max(
            metadataClock?.lastPhysicalMilliseconds ?? 0,
            maximumTimestamp?.physicalMilliseconds ?? 0
        )
        let maximumLogical: UInt32
        if metadataClock?.lastPhysicalMilliseconds == maximumPhysical,
           maximumTimestamp?.physicalMilliseconds == maximumPhysical {
            maximumLogical = max(
                metadataClock?.logicalCounter ?? 0,
                maximumTimestamp?.logicalCounter ?? 0
            )
        } else if metadataClock?.lastPhysicalMilliseconds == maximumPhysical {
            maximumLogical = metadataClock?.logicalCounter ?? 0
        } else {
            maximumLogical = maximumTimestamp?.logicalCounter ?? 0
        }
        self.clock = try HybridLogicalClock(
            deviceID: deviceID,
            lastPhysicalMilliseconds: maximumPhysical,
            logicalCounter: maximumLogical
        )
        let largestLocalSequence = recoveredOperations.values
            .filter { $0.deviceID == deviceID }
            .map(\.deviceSequence)
            .max() ?? 0
        guard largestLocalSequence < UInt64.max else {
            throw NextStepSyncError.malformedDocument("Device sequence overflowed.")
        }
        self.nextDeviceSequence = max(
            metadata?.nextDeviceSequence ?? 1,
            largestLocalSequence + 1
        )
        self.operationsByID = recoveredOperations
        self.checkpoint = recoveredCheckpoint
    }

    @discardableResult
    public func enqueueSet(
        entity: SyncEntityReference,
        field: SyncKey,
        value: SyncScalarValue,
        policy: SyncFieldPolicy
    ) throws -> SyncOperation {
        try enqueue(entity: entity, mutation: .set(field: field, value: value, policy: policy))
    }

    @discardableResult
    public func enqueueTombstone(
        entity: SyncEntityReference,
        reason: String? = nil
    ) throws -> SyncOperation {
        try enqueue(entity: entity, mutation: .tombstone(reason: reason))
    }

    public func enqueueBlob(
        entity: SyncEntityReference,
        field: SyncKey,
        data: Data,
        mediaType: String? = nil,
        policy: SyncFieldPolicy
    ) throws -> SyncBlobMutationResult {
        let reference = try storeBlob(data, mediaType: mediaType)
        let operation = try enqueueSet(
            entity: entity,
            field: field,
            value: .blob(reference),
            policy: policy
        )
        return .init(reference: reference, operation: operation)
    }

    @discardableResult
    public func resolveConflict(
        _ conflictID: SyncConflictID,
        choosing operationID: UUID,
        entity: SyncEntityReference
    ) throws -> SyncOperation {
        let current = try SyncStateReducer.snapshot(from: operationsByID)
        guard let conflict = current.conflicts.first(where: { $0.id == conflictID }),
              conflict.entity == entity,
              conflict.contenders.contains(where: { $0.operationID == operationID }) else {
            throw NextStepSyncError.unresolvedConflict(conflictID.description)
        }
        return try enqueue(
            entity: entity,
            mutation: .resolveConflict(conflictID: conflictID, chosenOperationID: operationID)
        )
    }

    public func snapshot() throws -> SyncSnapshot {
        try SyncStateReducer.snapshot(from: operationsByID)
    }

    public func pendingOperationCount() throws -> Int {
        try Self.pendingEntries(localRootURL: localRootURL).count
    }

    public func blobData(for reference: SyncBlobReference) throws -> Data? {
        let path = try Self.localBlobPath(reference.digest)
        guard let data = try SecureSyncFolder.readIfPresent(
            rootURL: localRootURL,
            path: path,
            maximumBytes: reference.byteCount
        ) else { return nil }
        try Self.verifyBlob(data, reference: reference)
        return data
    }

    /// Test/import hook used by non-folder transports. It performs the same
    /// integrity, idempotency and conflict handling as a remote download.
    @discardableResult
    public func ingestOperationEnvelope(_ data: Data) throws -> Bool {
        let operation = try SyncCodec.decodeOperationEnvelope(data)
        return try accept(operation, advanceClock: true)
    }

    public func synchronize() async throws -> SyncReport {
        guard await transport.isAvailable() else {
            throw NextStepSyncError.transportUnavailable
        }

        // Persist any operation recovered only from the durable pending queue.
        try persistLocalState()
        let uploaded = try await uploadPendingOperations()
        let download = try await importRemoteOperations()
        try persistLocalState()
        let currentSnapshot = try snapshot()
        return SyncReport(
            uploadedOperationCount: uploaded,
            importedOperationCount: download.imported,
            duplicateOperationCount: download.duplicates,
            unresolvedConflictCount: currentSnapshot.conflicts.filter {
                $0.status == .unresolved
            }.count,
            pendingOperationCount: try pendingOperationCount()
        )
    }

    private func enqueue(entity: SyncEntityReference, mutation: SyncMutation) throws -> SyncOperation {
        guard nextDeviceSequence < UInt64.max else {
            throw NextStepSyncError.malformedDocument("Device sequence overflowed.")
        }
        let timestamp = try clock.tick(at: now())
        let sequence = nextDeviceSequence
        nextDeviceSequence += 1
        let operation = try SyncOperation(
            libraryID: libraryID,
            deviceID: deviceID,
            deviceSequence: sequence,
            timestamp: timestamp,
            entity: entity,
            mutation: mutation
        )
        let envelope = try SyncCodec.encodeOperationEnvelope(operation)
        let pendingPath = try Self.pendingPath(operation)
        try SecureSyncFolder.writeImmutable(
            rootURL: localRootURL,
            path: pendingPath,
            data: envelope
        )
        _ = try accept(operation, advanceClock: false)
        return operation
    }

    private func storeBlob(_ data: Data, mediaType: String?) throws -> SyncBlobReference {
        guard data.count <= SyncLimits.maximumBlobBytes else {
            throw NextStepSyncError.sizeLimitExceeded(limit: SyncLimits.maximumBlobBytes)
        }
        let digest = SyncDigest(data: data)
        let reference = try SyncBlobReference(
            digest: digest,
            byteCount: data.count,
            mediaType: mediaType
        )
        try SecureSyncFolder.writeImmutable(
            rootURL: localRootURL,
            path: try Self.localBlobPath(digest),
            data: data
        )
        return reference
    }

    @discardableResult
    private func accept(_ operation: SyncOperation, advanceClock: Bool) throws -> Bool {
        try operation.validate()
        guard operation.libraryID == libraryID else {
            throw NextStepSyncError.incompatibleLibrary
        }
        if let existing = operationsByID[operation.id] {
            guard existing == operation else {
                throw NextStepSyncError.malformedDocument("Operation ID payload collision.")
            }
            return false
        }
        if let collision = operationsByID.values.first(where: {
            $0.deviceID == operation.deviceID
                && $0.deviceSequence == operation.deviceSequence
                && $0.id != operation.id
        }) {
            throw NextStepSyncError.sequenceCollision(collision.deviceSequence)
        }
        guard operationsByID.count < SyncLimits.maximumImportedOperations else {
            throw NextStepSyncError.operationLimitExceeded
        }

        let previousClock = clock
        operationsByID[operation.id] = operation
        checkpoint.importedOperationIDs.insert(operation.id)
        if advanceClock {
            do {
                try clock.observe(operation.timestamp, at: now())
            } catch {
                operationsByID.removeValue(forKey: operation.id)
                checkpoint.importedOperationIDs.remove(operation.id)
                clock = previousClock
                throw error
            }
        }
        do {
            try persistLocalState()
        } catch {
            operationsByID.removeValue(forKey: operation.id)
            checkpoint.importedOperationIDs.remove(operation.id)
            clock = previousClock
            throw error
        }
        return true
    }

    private func uploadPendingOperations() async throws -> Int {
        let pending = try Self.readPendingOperations(
            localRootURL: localRootURL,
            libraryID: libraryID,
            deviceID: deviceID
        ).sorted { $0.deviceSequence < $1.deviceSequence }
        let pendingIDs = Set(pending.map(\.id))
        // Reconcile all operations owned by this device, not only the queue. This
        // repairs a stale iCloud manifest without re-creating or mutating history.
        let locallyOwned = operationsByID.values
            .filter { $0.deviceID == deviceID }
            .sorted { $0.deviceSequence < $1.deviceSequence }
        guard !locallyOwned.isEmpty else { return 0 }

        var manifest = try await loadOwnManifest()
        let remoteOperationEntries = try await transport.list(
            try remoteLayout.operationDirectory(deviceID: deviceID)
        )
        let remoteOperationNames = Set(
            remoteOperationEntries.filter { !$0.isDirectory }.map(\.name)
        )
        var uploaded = 0
        for operation in locallyOwned {
            let envelope = try SyncCodec.encodeOperationEnvelope(operation)
            let filename = Self.operationFilename(operation)
            let reference = try SyncOperationReference(
                operation: operation,
                filename: filename,
                envelopeData: envelope
            )
            let knownReference = manifest.operations.contains(reference)
            if pendingIDs.contains(operation.id)
                || !knownReference
                || !remoteOperationNames.contains(filename) {
                try await publishBlobIfNeeded(operation)
                try await transport.writeImmutable(
                    envelope,
                    to: try remoteLayout.operation(deviceID: deviceID, filename: filename)
                )
                uploaded += 1
            }
            let previousGeneration = manifest.generation
            try manifest.append(reference)
            if manifest.generation != previousGeneration {
                let manifestEnvelope = try SyncCodec.encodeEnvelope(
                    manifest,
                    maximumBytes: SyncLimits.maximumManifestBytes
                )
                try await transport.replaceAtomically(
                    manifestEnvelope,
                    at: try remoteLayout.manifest(deviceID: deviceID)
                )
            }
            if pendingIDs.contains(operation.id) {
                try SecureSyncFolder.removeIfPresent(
                    rootURL: localRootURL,
                    path: try Self.pendingPath(operation)
                )
            }
        }
        return uploaded
    }

    private func loadOwnManifest() async throws -> SyncDeviceManifest {
        let filename = "\(deviceID.description).manifest.json"
        let entries = try await transport.list(remoteLayout.manifests)
        guard entries.contains(where: { !$0.isDirectory && $0.name == filename }) else {
            return SyncDeviceManifest(libraryID: libraryID, deviceID: deviceID)
        }
        let data = try await transport.read(
            try remoteLayout.manifest(deviceID: deviceID),
            maximumBytes: SyncLimits.maximumManifestBytes * 2
        )
        let manifest = try SyncCodec.decodeEnvelope(
            SyncDeviceManifest.self,
            from: data,
            maximumBytes: SyncLimits.maximumManifestBytes
        )
        try validate(manifest, expectedDeviceID: deviceID)
        return manifest
    }

    private func publishBlobIfNeeded(_ operation: SyncOperation) async throws {
        guard case .set(_, .blob(let reference), _) = operation.mutation else { return }
        guard let data = try blobData(for: reference) else {
            throw NextStepSyncError.notFound(reference.digest.hex)
        }
        try await transport.writeImmutable(data, to: try remoteLayout.blob(reference.digest))
    }

    private func importRemoteOperations() async throws -> (imported: Int, duplicates: Int) {
        let entries = try await transport.list(remoteLayout.manifests)
        var imported = 0
        var duplicates = 0
        for entry in entries where !entry.isDirectory && entry.name.hasSuffix(".manifest.json") {
            let devicePart = String(entry.name.dropLast(".manifest.json".count))
            guard let uuid = UUID(uuidString: devicePart) else {
                // Unknown files in the user's folder do not become sync input.
                continue
            }
            let producer = DeviceID(uuid)
            let manifestData = try await transport.read(
                try remoteLayout.manifest(deviceID: producer),
                maximumBytes: SyncLimits.maximumManifestBytes * 2
            )
            let manifest = try SyncCodec.decodeEnvelope(
                SyncDeviceManifest.self,
                from: manifestData,
                maximumBytes: SyncLimits.maximumManifestBytes
            )
            try validate(manifest, expectedDeviceID: producer)

            for reference in manifest.operations.sorted() {
                if checkpoint.importedOperationIDs.contains(reference.operationID) {
                    duplicates += 1
                    continue
                }
                let envelopeData = try await transport.read(
                    try remoteLayout.operation(deviceID: producer, filename: reference.filename),
                    maximumBytes: SyncLimits.maximumOperationBytes * 2
                )
                let actualEnvelopeDigest = SyncDigest(data: envelopeData)
                guard actualEnvelopeDigest == reference.envelopeSHA256 else {
                    throw NextStepSyncError.integrityMismatch(
                        expected: reference.envelopeSHA256.hex,
                        actual: actualEnvelopeDigest.hex
                    )
                }
                let operation = try SyncCodec.decodeOperationEnvelope(envelopeData)
                guard operation.id == reference.operationID,
                      operation.deviceID == producer,
                      operation.deviceSequence == reference.deviceSequence,
                      operation.timestamp == reference.timestamp else {
                    throw NextStepSyncError.malformedDocument("Manifest reference mismatch.")
                }
                try await downloadBlobIfNeeded(operation)
                if try accept(operation, advanceClock: true) {
                    imported += 1
                } else {
                    duplicates += 1
                }
            }
            checkpoint.manifestGenerations[producer.description] = manifest.generation
            try persistLocalState()
        }
        return (imported, duplicates)
    }

    private func downloadBlobIfNeeded(_ operation: SyncOperation) async throws {
        guard case .set(_, .blob(let reference), _) = operation.mutation else { return }
        if let existing = try blobData(for: reference) {
            try Self.verifyBlob(existing, reference: reference)
            return
        }
        let data = try await transport.read(
            try remoteLayout.blob(reference.digest),
            maximumBytes: reference.byteCount
        )
        try Self.verifyBlob(data, reference: reference)
        try SecureSyncFolder.writeImmutable(
            rootURL: localRootURL,
            path: try Self.localBlobPath(reference.digest),
            data: data
        )
    }

    private func validate(_ manifest: SyncDeviceManifest, expectedDeviceID: DeviceID) throws {
        try manifest.validate()
        guard manifest.libraryID == libraryID else {
            throw NextStepSyncError.incompatibleLibrary
        }
        guard manifest.deviceID == expectedDeviceID else {
            throw NextStepSyncError.incompatibleDevice
        }
    }

    private func persistLocalState() throws {
        let orderedOperations = operationsByID.values.sorted(by: SyncStateReducer.operationPrecedes)
        let archive = SyncLocalArchive(operations: orderedOperations)
        let archiveData = try SyncCodec.encodeEnvelope(
            archive,
            maximumBytes: SyncLimits.maximumLocalArchiveBytes
        )
        let checkpointData = try SyncCodec.encodeEnvelope(
            checkpoint,
            maximumBytes: SyncLimits.maximumManifestBytes
        )
        let metadata = SyncLocalMetadata(
            libraryID: libraryID,
            deviceID: deviceID,
            nextDeviceSequence: nextDeviceSequence,
            clock: clock
        )
        let metadataData = try SyncCodec.encodeEnvelope(metadata, maximumBytes: 32 * 1_024)
        try SecureSyncFolder.replaceAtomically(
            rootURL: localRootURL,
            path: try Self.localPath("accepted-operations.json"),
            data: archiveData
        )
        try SecureSyncFolder.replaceAtomically(
            rootURL: localRootURL,
            path: try Self.localPath("checkpoint.json"),
            data: checkpointData
        )
        try SecureSyncFolder.replaceAtomically(
            rootURL: localRootURL,
            path: try Self.localPath("metadata.json"),
            data: metadataData
        )
    }

    private static func readPendingOperations(
        localRootURL: URL,
        libraryID: SyncLibraryID,
        deviceID: DeviceID
    ) throws -> [SyncOperation] {
        let entries = try pendingEntries(localRootURL: localRootURL)
        var operations: [SyncOperation] = []
        for entry in entries where !entry.isDirectory && entry.name.hasSuffix(".operation.json") {
            let path = try SyncRelativePath(component: "pending").appending(entry.name)
            guard let bytes = try SecureSyncFolder.readIfPresent(
                rootURL: localRootURL,
                path: path,
                maximumBytes: SyncLimits.maximumOperationBytes * 2
            ) else { continue }
            let operation = try SyncCodec.decodeOperationEnvelope(bytes)
            guard operation.libraryID == libraryID else {
                throw NextStepSyncError.incompatibleLibrary
            }
            guard operation.deviceID == deviceID else {
                throw NextStepSyncError.incompatibleDevice
            }
            guard entry.name == operationFilename(operation) else {
                throw NextStepSyncError.malformedDocument("Pending operation filename mismatch.")
            }
            operations.append(operation)
        }
        return operations
    }

    private static func pendingEntries(localRootURL: URL) throws -> [SyncTransportEntry] {
        do {
            return try SecureSyncFolder.list(
                rootURL: localRootURL,
                path: try SyncRelativePath(component: "pending")
            )
        } catch NextStepSyncError.notFound(_) {
            return []
        }
    }

    private static func validateSequences<S: Sequence>(_ operations: S) throws where S.Element == SyncOperation {
        var values: [String: UUID] = [:]
        for operation in operations {
            let key = "\(operation.deviceID.description):\(operation.deviceSequence)"
            if let existing = values[key], existing != operation.id {
                throw NextStepSyncError.sequenceCollision(operation.deviceSequence)
            }
            values[key] = operation.id
        }
    }

    private static func operationFilename(_ operation: SyncOperation) -> String {
        SyncOperationReference.canonicalFilename(
            deviceSequence: operation.deviceSequence,
            operationID: operation.id
        )
    }

    private static func pendingPath(_ operation: SyncOperation) throws -> SyncRelativePath {
        try SyncRelativePath(component: "pending").appending(operationFilename(operation))
    }

    private static func localBlobPath(_ digest: SyncDigest) throws -> SyncRelativePath {
        try SyncRelativePath(component: "blobs")
            .appending(String(digest.hex.prefix(2)))
            .appending("\(digest.hex).blob")
    }

    private static func localPath(_ filename: String) throws -> SyncRelativePath {
        try SyncRelativePath(component: filename)
    }

    private static func verifyBlob(_ data: Data, reference: SyncBlobReference) throws {
        guard data.count == reference.byteCount else {
            throw NextStepSyncError.integrityMismatch(
                expected: "\(reference.byteCount) bytes",
                actual: "\(data.count) bytes"
            )
        }
        let actual = SyncDigest(data: data)
        guard actual == reference.digest else {
            throw NextStepSyncError.integrityMismatch(
                expected: reference.digest.hex,
                actual: actual.hex
            )
        }
    }
}

public struct FileFolderSyncSession: Sendable {
    public let libraryID: SyncLibraryID
    public let deviceID: DeviceID
    /// Save this bookmark after every successful connection. It is either the
    /// original bookmark or an automatically refreshed replacement.
    public let bookmarkToPersist: SecurityScopedSyncFolderBookmark
    public let refreshedBookmark: SecurityScopedSyncFolderBookmark?
    public let engine: NextStepSyncEngine
}

/// App-facing bootstrap for the free iCloud Drive folder transport.
///
/// The app owns the UIDocumentPicker UI. Pass its selected directory bookmark
/// here on every launch; the shared marker discovers the same library ID on the
/// user's iPhone and iPad, while DeviceIdentityStore remains device-local.
public enum NextStepSyncBootstrap {
    public static func connectSelectedFolder(
        _ folderURL: URL,
        applicationSupportRoot: URL,
        preferredLibraryID: SyncLibraryID? = nil
    ) async throws -> FileFolderSyncSession {
        // A document-picker URL is security scoped. Keep the grant active while
        // producing the bookmark; later transport operations balance their own
        // access calls independently.
        let didStartAccess = folderURL.startAccessingSecurityScopedResource()
        defer { if didStartAccess { folderURL.stopAccessingSecurityScopedResource() } }
        let bookmark = try SecurityScopedSyncFolderBookmark(folderURL: folderURL)
        return try await connectFileFolder(
            bookmark: bookmark,
            applicationSupportRoot: applicationSupportRoot,
            preferredLibraryID: preferredLibraryID
        )
    }

    public static func connectFileFolder(
        bookmark: SecurityScopedSyncFolderBookmark,
        applicationSupportRoot: URL,
        preferredLibraryID: SyncLibraryID? = nil
    ) async throws -> FileFolderSyncSession {
        let resolution = try bookmark.resolve()
        let refreshedBookmark: SecurityScopedSyncFolderBookmark?
        if resolution.isStale {
            let didStart = resolution.url.startAccessingSecurityScopedResource()
            defer { if didStart { resolution.url.stopAccessingSecurityScopedResource() } }
            refreshedBookmark = try SecurityScopedSyncFolderBookmark(folderURL: resolution.url)
        } else {
            refreshedBookmark = nil
        }

        let transport = try FileFolderSyncTransport(
            rootURL: resolution.url,
            requiresSecurityScopedAccess: true,
            createIfMissing: false
        )
        let markerDirectory = try SyncRelativePath(component: "NextStepSync-v1")
        let markerPath = try markerDirectory.appending("library.json")
        let markerEntries = try await transport.list(markerDirectory)
        let marker: SharedLibraryMarker
        if markerEntries.contains(where: { !$0.isDirectory && $0.name == "library.json" }) {
            let data = try await transport.read(markerPath, maximumBytes: 16 * 1_024)
            marker = try SyncCodec.decodeEnvelope(
                SharedLibraryMarker.self,
                from: data,
                maximumBytes: 8 * 1_024
            )
        } else {
            let candidate = SharedLibraryMarker(libraryID: preferredLibraryID ?? SyncLibraryID())
            let data = try SyncCodec.encodeEnvelope(candidate, maximumBytes: 8 * 1_024)
            do {
                try await transport.writeImmutable(data, to: markerPath)
                marker = candidate
            } catch NextStepSyncError.immutableFileCollision(_) {
                let winningData = try await transport.read(markerPath, maximumBytes: 16 * 1_024)
                marker = try SyncCodec.decodeEnvelope(
                    SharedLibraryMarker.self,
                    from: winningData,
                    maximumBytes: 8 * 1_024
                )
            }
        }
        guard marker.schemaVersion == SharedLibraryMarker.currentSchemaVersion else {
            throw NextStepSyncError.unsupportedSchemaVersion(marker.schemaVersion)
        }
        if let preferredLibraryID, preferredLibraryID != marker.libraryID {
            throw NextStepSyncError.incompatibleLibrary
        }

        let syncSupport = applicationSupportRoot
            .appendingPathComponent("NextStepSync", isDirectory: true)
        let identityStore = try DeviceIdentityStore(
            rootURL: syncSupport.appendingPathComponent("Device", isDirectory: true)
        )
        let deviceID = try await identityStore.loadOrCreate()
        let localLibraryRoot = syncSupport
            .appendingPathComponent("Libraries", isDirectory: true)
            .appendingPathComponent(marker.libraryID.description, isDirectory: true)
        let engine = try NextStepSyncEngine(
            libraryID: marker.libraryID,
            deviceID: deviceID,
            localRootURL: localLibraryRoot,
            transport: transport
        )
        return FileFolderSyncSession(
            libraryID: marker.libraryID,
            deviceID: deviceID,
            bookmarkToPersist: refreshedBookmark ?? bookmark,
            refreshedBookmark: refreshedBookmark,
            engine: engine
        )
    }
}
