import CryptoKit
import Darwin
import Foundation
import NextStepAcademic

struct AcademicWorkspaceDirectoryAuthority: Sendable {
    let selectedParentDescriptor: Int32
    let libraryRootDescriptor: Int32
    let sidecarDescriptor: Int32
}

typealias AcademicWorkspaceAtomicWriter = @Sendable (
    Data,
    String,
    AcademicWorkspaceDirectoryAuthority
) throws -> Void

enum AcademicWorkspaceDiskLayout {
    static let libraryDirectoryName = "Notes"
    static let sidecarDirectoryName = ".nextstep-academic"
    static let currentEnvelopeName = "workspace-envelope.plist"
    static let previousEnvelopeName = "workspace-envelope.previous.plist"
    static let envelopeSchemaVersion = 1
    static let maximumEnvelopeBytes =
        (AcademicWorkspaceLimits.maximumEncodedBytes * 2) + (64 * 1_024)

    static func sidecarDirectory(in libraryRoot: URL) -> URL {
        libraryRoot.appendingPathComponent(sidecarDirectoryName, isDirectory: true)
    }

    static func currentEnvelope(in libraryRoot: URL) -> URL {
        sidecarDirectory(in: libraryRoot).appendingPathComponent(
            currentEnvelopeName,
            isDirectory: false
        )
    }

    static func previousEnvelope(in libraryRoot: URL) -> URL {
        sidecarDirectory(in: libraryRoot).appendingPathComponent(
            previousEnvelopeName,
            isDirectory: false
        )
    }
}

struct AcademicWorkspaceDiskObservation {
    let snapshot: AcademicWorkspaceFileSnapshot
    let authoritativeEnvelopeData: Data?
}

/// Bounded, path-private storage for the academic workspace byte slots.
///
/// Primary and backup workspace bytes are fields in one binary-plist envelope,
/// so their storage revision crosses a single atomic rename. The previous exact
/// envelope is retained separately and is consulted only when the current
/// envelope is missing or corrupt.
enum AcademicWorkspaceDiskIO {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let storageRevision: Int64
        let primaryData: Data?
        let backupData: Data?
    }

    private enum BoundedFile {
        case missing
        case data(Data)
    }

    private enum DiskFailure: Error {
        case unavailable
    }

    private static let missingFingerprintMaterial =
        Data("nextstep-academic-authoritative-envelope-missing-v1".utf8)

    static func read(
        selectedParent: URL,
        rootFingerprint: AcademicWorkspaceStorageFingerprint
    ) throws(AcademicWorkspaceFileBackingError) -> AcademicWorkspaceDiskObservation {
        do {
            let parentDescriptor = try openSelectedParent(selectedParent)
            defer { _ = Darwin.close(parentDescriptor) }
            guard let rootDescriptor = try openChildDirectory(
                named: AcademicWorkspaceDiskLayout.libraryDirectoryName,
                relativeTo: parentDescriptor,
                createIfMissing: false,
                permissions: mode_t(S_IRWXU)
            ) else {
                return try missingObservation(rootFingerprint: rootFingerprint)
            }
            defer { _ = Darwin.close(rootDescriptor) }
            try validateLibraryRoot(
                parentDescriptor: parentDescriptor,
                rootDescriptor: rootDescriptor
            )
            guard let sidecarDescriptor = try openChildDirectory(
                named: AcademicWorkspaceDiskLayout.sidecarDirectoryName,
                relativeTo: rootDescriptor,
                createIfMissing: false,
                permissions: mode_t(S_IRWXU)
            ) else {
                try validateLibraryRoot(
                    parentDescriptor: parentDescriptor,
                    rootDescriptor: rootDescriptor
                )
                return try missingObservation(rootFingerprint: rootFingerprint)
            }
            defer { _ = Darwin.close(sidecarDescriptor) }
            try acquireLock(sidecarDescriptor, operation: LOCK_SH)
            defer { _ = flock(sidecarDescriptor, LOCK_UN) }

            let authority = AcademicWorkspaceDirectoryAuthority(
                selectedParentDescriptor: parentDescriptor,
                libraryRootDescriptor: rootDescriptor,
                sidecarDescriptor: sidecarDescriptor
            )
            try validateAuthority(authority)
            let observation = try observe(
                sidecarDescriptor: sidecarDescriptor,
                rootFingerprint: rootFingerprint
            )
            try validateAuthority(authority)
            return observation
        } catch {
            throw .unavailable
        }
    }

    static func replace(
        primaryData: Data?,
        backupData: Data?,
        expected: AcademicWorkspaceStorageVersion,
        selectedParent: URL,
        rootFingerprint: AcademicWorkspaceStorageFingerprint,
        writer: AcademicWorkspaceAtomicWriter
    ) throws(AcademicWorkspaceFileBackingError) -> AcademicWorkspaceFileSnapshot {
        guard primaryData.map({ $0.count <= AcademicWorkspaceLimits.maximumEncodedBytes }) ?? true,
              backupData.map({ $0.count <= AcademicWorkspaceLimits.maximumEncodedBytes }) ?? true else {
            throw .unavailable
        }

        let (nextRevision, overflow) = expected.storageRevision.addingReportingOverflow(1)
        guard expected.storageRevision >= 0, !overflow else {
            throw .storageRevisionOverflow
        }

        let nextEnvelopeData: Data
        let nextSnapshot: AcademicWorkspaceFileSnapshot
        do {
            nextEnvelopeData = try encodeEnvelope(
                storageRevision: nextRevision,
                primaryData: primaryData,
                backupData: backupData
            )
            let nextStateFingerprint = stateFingerprint(for: nextEnvelopeData)
            guard nextStateFingerprint != expected.stateFingerprint else {
                throw DiskFailure.unavailable
            }
            nextSnapshot = AcademicWorkspaceFileSnapshot(
                primary: slotValue(primaryData),
                backup: slotValue(backupData),
                version: try AcademicWorkspaceStorageVersion(
                    rootFingerprint: rootFingerprint,
                    stateFingerprint: nextStateFingerprint,
                    storageRevision: nextRevision
                )
            )
        } catch let error as AcademicWorkspaceFileBackingError {
            throw error
        } catch {
            throw .unavailable
        }

        do {
            let parentDescriptor = try openSelectedParent(selectedParent)
            defer { _ = Darwin.close(parentDescriptor) }
            guard let rootDescriptor = try openChildDirectory(
                named: AcademicWorkspaceDiskLayout.libraryDirectoryName,
                relativeTo: parentDescriptor,
                createIfMissing: true,
                permissions: mode_t(S_IRWXU)
            ) else {
                throw DiskFailure.unavailable
            }
            defer { _ = Darwin.close(rootDescriptor) }
            guard let sidecarDescriptor = try openChildDirectory(
                named: AcademicWorkspaceDiskLayout.sidecarDirectoryName,
                relativeTo: rootDescriptor,
                createIfMissing: true,
                permissions: mode_t(S_IRWXU)
            ) else {
                throw DiskFailure.unavailable
            }
            defer { _ = Darwin.close(sidecarDescriptor) }
            try acquireLock(sidecarDescriptor, operation: LOCK_EX)
            defer { _ = flock(sidecarDescriptor, LOCK_UN) }

            let authority = AcademicWorkspaceDirectoryAuthority(
                selectedParentDescriptor: parentDescriptor,
                libraryRootDescriptor: rootDescriptor,
                sidecarDescriptor: sidecarDescriptor
            )
            try validateAuthority(authority)

            // The compare happens only after this route's verified sidecar
            // descriptor is locked, and all subsequent I/O stays relative to
            // that same descriptor.
            let observed = try observe(
                sidecarDescriptor: sidecarDescriptor,
                rootFingerprint: rootFingerprint
            )
            guard observed.snapshot.version.rootFingerprint == expected.rootFingerprint,
                  observed.snapshot.version.stateFingerprint == expected.stateFingerprint,
                  observed.snapshot.version.storageRevision == expected.storageRevision else {
                throw AcademicWorkspaceFileBackingError.conflict
            }

            if let authoritativeEnvelopeData = observed.authoritativeEnvelopeData {
                try writer(
                    authoritativeEnvelopeData,
                    AcademicWorkspaceDiskLayout.previousEnvelopeName,
                    authority
                )
                guard case let .data(persistedPrevious) = try readBoundedFile(
                    named: AcademicWorkspaceDiskLayout.previousEnvelopeName,
                    relativeTo: sidecarDescriptor
                ), persistedPrevious == authoritativeEnvelopeData else {
                    throw DiskFailure.unavailable
                }
            }

            try writer(
                nextEnvelopeData,
                AcademicWorkspaceDiskLayout.currentEnvelopeName,
                authority
            )
            return nextSnapshot
        } catch let error as AcademicWorkspaceFileBackingError {
            throw error
        } catch {
            throw .unavailable
        }
    }

    static func encodeEnvelope(
        storageRevision: Int64,
        primaryData: Data?,
        backupData: Data?
    ) throws -> Data {
        guard storageRevision >= 0,
              primaryData.map({ $0.count <= AcademicWorkspaceLimits.maximumEncodedBytes }) ?? true,
              backupData.map({ $0.count <= AcademicWorkspaceLimits.maximumEncodedBytes }) ?? true else {
            throw DiskFailure.unavailable
        }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let encoded = try encoder.encode(Envelope(
            schemaVersion: AcademicWorkspaceDiskLayout.envelopeSchemaVersion,
            storageRevision: storageRevision,
            primaryData: primaryData,
            backupData: backupData
        ))
        guard encoded.count <= AcademicWorkspaceDiskLayout.maximumEnvelopeBytes else {
            throw DiskFailure.unavailable
        }
        return encoded
    }

    /// Writes through a private, exclusive temporary file in the already
    /// locked sidecar and atomically renames relative to that same descriptor.
    static func atomicWrite(
        _ data: Data,
        named destinationName: String,
        authority: AcademicWorkspaceDirectoryAuthority
    ) throws {
        guard data.count <= AcademicWorkspaceDiskLayout.maximumEnvelopeBytes,
              destinationName == AcademicWorkspaceDiskLayout.currentEnvelopeName
                || destinationName == AcademicWorkspaceDiskLayout.previousEnvelopeName else {
            throw DiskFailure.unavailable
        }
        try validateAuthority(authority)

        let temporaryName = ".\(destinationName).\(UUID().uuidString).tmp"
        let fileDescriptor = temporaryName.withCString {
            Darwin.openat(
                authority.sidecarDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard fileDescriptor >= 0 else { throw DiskFailure.unavailable }

        var shouldRemoveTemporary = true
        defer {
            _ = Darwin.close(fileDescriptor)
            if shouldRemoveTemporary {
                temporaryName.withCString {
                    _ = Darwin.unlinkat(authority.sidecarDescriptor, $0, 0)
                }
            }
        }

        var fileMetadata = stat()
        guard Darwin.fstat(fileDescriptor, &fileMetadata) == 0,
              (fileMetadata.st_mode & S_IFMT) == S_IFREG,
              fileMetadata.st_nlink == 1 else {
            throw DiskFailure.unavailable
        }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let baseAddress = bytes.baseAddress else {
                    throw DiskFailure.unavailable
                }
                let written = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw DiskFailure.unavailable
                }
            }
        }
        guard Darwin.fsync(fileDescriptor) == 0 else {
            throw DiskFailure.unavailable
        }

        // A directory entry swap after lock acquisition detaches the locked
        // inode from the selected route. Refuse to rename in that case.
        try validateAuthority(authority)
        let renameResult = temporaryName.withCString { temporaryPath in
            destinationName.withCString { destinationPath in
                Darwin.renameat(
                    authority.sidecarDescriptor,
                    temporaryPath,
                    authority.sidecarDescriptor,
                    destinationPath
                )
            }
        }
        guard renameResult == 0 else { throw DiskFailure.unavailable }
        shouldRemoveTemporary = false
        // Route validation immediately precedes rename. No fallible work runs
        // after the authority change; durability remains best effort here.
        _ = Darwin.fsync(authority.sidecarDescriptor)
    }

    private static func observe(
        sidecarDescriptor: Int32,
        rootFingerprint: AcademicWorkspaceStorageFingerprint
    ) throws -> AcademicWorkspaceDiskObservation {
        let currentFile = try readBoundedFile(
            named: AcademicWorkspaceDiskLayout.currentEnvelopeName,
            relativeTo: sidecarDescriptor
        )
        if case let .data(currentData) = currentFile,
           let currentEnvelope = decodeEnvelope(currentData) {
            return try observation(
                envelope: currentEnvelope,
                exactData: currentData,
                rootFingerprint: rootFingerprint
            )
        }

        // A recovery copy has no authority while current is valid. Reading it
        // lazily keeps a damaged or hostile stale copy from blocking good data.
        let previousFile = try readBoundedFile(
            named: AcademicWorkspaceDiskLayout.previousEnvelopeName,
            relativeTo: sidecarDescriptor
        )
        if case let .data(previousData) = previousFile,
           let previousEnvelope = decodeEnvelope(previousData) {
            return try observation(
                envelope: previousEnvelope,
                exactData: previousData,
                rootFingerprint: rootFingerprint
            )
        }
        if case .missing = currentFile, case .missing = previousFile {
            return try missingObservation(rootFingerprint: rootFingerprint)
        }
        throw DiskFailure.unavailable
    }

    private static func observation(
        envelope: Envelope,
        exactData: Data,
        rootFingerprint: AcademicWorkspaceStorageFingerprint
    ) throws -> AcademicWorkspaceDiskObservation {
        let version = try AcademicWorkspaceStorageVersion(
            rootFingerprint: rootFingerprint,
            stateFingerprint: stateFingerprint(for: exactData),
            storageRevision: envelope.storageRevision
        )
        return AcademicWorkspaceDiskObservation(
            snapshot: AcademicWorkspaceFileSnapshot(
                primary: slotValue(envelope.primaryData),
                backup: slotValue(envelope.backupData),
                version: version
            ),
            authoritativeEnvelopeData: exactData
        )
    }

    private static func missingObservation(
        rootFingerprint: AcademicWorkspaceStorageFingerprint
    ) throws -> AcademicWorkspaceDiskObservation {
        let version = try AcademicWorkspaceStorageVersion(
            rootFingerprint: rootFingerprint,
            stateFingerprint: stateFingerprint(for: nil),
            storageRevision: 0
        )
        return AcademicWorkspaceDiskObservation(
            snapshot: AcademicWorkspaceFileSnapshot(
                primary: .missing,
                backup: .missing,
                version: version
            ),
            authoritativeEnvelopeData: nil
        )
    }

    private static func decodeEnvelope(_ data: Data) -> Envelope? {
        guard data.count <= AcademicWorkspaceDiskLayout.maximumEnvelopeBytes,
              data.starts(with: Data("bplist00".utf8)),
              let envelope = try? PropertyListDecoder().decode(Envelope.self, from: data),
              envelope.schemaVersion == AcademicWorkspaceDiskLayout.envelopeSchemaVersion,
              envelope.storageRevision >= 0 else {
            return nil
        }
        return envelope
    }

    private static func slotValue(_ data: Data?) -> AcademicWorkspaceFileSlotValue {
        guard let data else { return .missing }
        guard data.count <= AcademicWorkspaceLimits.maximumEncodedBytes else {
            return .oversized
        }
        return .data(data)
    }

    private static func stateFingerprint(
        for authoritativeEnvelopeData: Data?
    ) -> AcademicWorkspaceStateFingerprint {
        let material = authoritativeEnvelopeData ?? missingFingerprintMaterial
        let bytes = Array(SHA256.hash(data: material).prefix(16))
        return AcademicWorkspaceStateFingerprint(UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )))
    }

    /// Opens the selected folder itself as the route authority. No ancestor
    /// walk from `/` is performed, which keeps Files-provider sandbox behavior
    /// intact while refusing a symlink as the selected folder's final entry.
    private static func openSelectedParent(_ selectedParent: URL) throws -> Int32 {
        guard selectedParent.isFileURL else { throw DiskFailure.unavailable }
        var beforeOpen = stat()
        guard selectedParent.path.withCString({ Darwin.lstat($0, &beforeOpen) }) == 0,
              (beforeOpen.st_mode & S_IFMT) == S_IFDIR else {
            throw DiskFailure.unavailable
        }
        let descriptor = selectedParent.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw DiskFailure.unavailable }
        do {
            var opened = stat()
            var afterOpen = stat()
            guard Darwin.fstat(descriptor, &opened) == 0,
                  selectedParent.path.withCString({ Darwin.lstat($0, &afterOpen) }) == 0,
                  (opened.st_mode & S_IFMT) == S_IFDIR,
                  sameFile(beforeOpen, opened),
                  sameUnchangedFile(beforeOpen, afterOpen) else {
                throw DiskFailure.unavailable
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func openChildDirectory(
        named name: String,
        relativeTo parentDescriptor: Int32,
        createIfMissing: Bool,
        permissions: mode_t
    ) throws -> Int32? {
        guard isSafeLeafName(name) else { throw DiskFailure.unavailable }
        var entryMetadata = stat()
        let metadataResult = name.withCString {
            Darwin.fstatat(
                parentDescriptor,
                $0,
                &entryMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if metadataResult != 0 {
            let metadataError = errno
            guard metadataError == ENOENT else { throw DiskFailure.unavailable }
            guard createIfMissing else { return nil }
            let createResult = name.withCString {
                Darwin.mkdirat(parentDescriptor, $0, permissions)
            }
            if createResult != 0 {
                let createError = errno
                guard createError == EEXIST else { throw DiskFailure.unavailable }
            }
        } else {
            guard (entryMetadata.st_mode & S_IFMT) == S_IFDIR else {
                throw DiskFailure.unavailable
            }
        }

        let descriptor = name.withCString {
            Darwin.openat(
                parentDescriptor,
                $0,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { throw DiskFailure.unavailable }
        do {
            try validateDirectoryEntry(
                named: name,
                parentDescriptor: parentDescriptor,
                descriptor: descriptor
            )
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func acquireLock(_ descriptor: Int32, operation: Int32) throws {
        var result: Int32
        repeat {
            result = flock(descriptor, operation)
        } while result != 0 && errno == EINTR
        guard result == 0 else { throw DiskFailure.unavailable }
    }

    private static func validateLibraryRoot(
        parentDescriptor: Int32,
        rootDescriptor: Int32
    ) throws {
        try validateDirectoryEntry(
            named: AcademicWorkspaceDiskLayout.libraryDirectoryName,
            parentDescriptor: parentDescriptor,
            descriptor: rootDescriptor
        )
    }

    private static func validateAuthority(
        _ authority: AcademicWorkspaceDirectoryAuthority
    ) throws {
        try validateLibraryRoot(
            parentDescriptor: authority.selectedParentDescriptor,
            rootDescriptor: authority.libraryRootDescriptor
        )
        try validateDirectoryEntry(
            named: AcademicWorkspaceDiskLayout.sidecarDirectoryName,
            parentDescriptor: authority.libraryRootDescriptor,
            descriptor: authority.sidecarDescriptor
        )
    }

    private static func validateDirectoryEntry(
        named name: String,
        parentDescriptor: Int32,
        descriptor: Int32
    ) throws {
        var descriptorMetadata = stat()
        var entryMetadata = stat()
        guard Darwin.fstat(descriptor, &descriptorMetadata) == 0,
              name.withCString({
                  Darwin.fstatat(
                      parentDescriptor,
                      $0,
                      &entryMetadata,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              (descriptorMetadata.st_mode & S_IFMT) == S_IFDIR,
              (entryMetadata.st_mode & S_IFMT) == S_IFDIR,
              sameFile(descriptorMetadata, entryMetadata) else {
            throw DiskFailure.unavailable
        }
    }

    private static func isSafeLeafName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\0")
    }

    /// Reads only after descriptor-relative metadata/type/link checks and
    /// proves that the opened file and its sidecar entry remain unchanged.
    private static func readBoundedFile(
        named name: String,
        relativeTo sidecarDescriptor: Int32
    ) throws -> BoundedFile {
        guard isSafeLeafName(name) else { throw DiskFailure.unavailable }
        var pathMetadata = stat()
        let metadataResult = name.withCString {
            Darwin.fstatat(
                sidecarDescriptor,
                $0,
                &pathMetadata,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if metadataResult != 0 {
            if errno == ENOENT { return .missing }
            throw DiskFailure.unavailable
        }
        guard isSafeRegularFile(pathMetadata),
              pathMetadata.st_size <= off_t(AcademicWorkspaceDiskLayout.maximumEnvelopeBytes) else {
            throw DiskFailure.unavailable
        }

        let descriptor = name.withCString {
            Darwin.openat(
                sidecarDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard descriptor >= 0 else { throw DiskFailure.unavailable }
        defer { _ = Darwin.close(descriptor) }

        var openedMetadata = stat()
        guard Darwin.fstat(descriptor, &openedMetadata) == 0,
              sameFile(pathMetadata, openedMetadata),
              isSafeRegularFile(openedMetadata),
              openedMetadata.st_size <= off_t(AcademicWorkspaceDiskLayout.maximumEnvelopeBytes) else {
            throw DiskFailure.unavailable
        }

        let byteCount = Int(openedMetadata.st_size)
        var data = Data(count: byteCount)
        if byteCount > 0 {
            try data.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    throw DiskFailure.unavailable
                }
                var offset = 0
                while offset < byteCount {
                    let amount = Darwin.pread(
                        descriptor,
                        baseAddress.advanced(by: offset),
                        byteCount - offset,
                        off_t(offset)
                    )
                    if amount > 0 {
                        offset += amount
                    } else if amount < 0, errno == EINTR {
                        continue
                    } else {
                        throw DiskFailure.unavailable
                    }
                }
            }
        }

        var extraByte: UInt8 = 0
        let extraCount = Darwin.pread(
            descriptor,
            &extraByte,
            1,
            off_t(byteCount)
        )
        guard extraCount == 0 else { throw DiskFailure.unavailable }

        var finalDescriptorMetadata = stat()
        var finalPathMetadata = stat()
        guard Darwin.fstat(descriptor, &finalDescriptorMetadata) == 0,
              name.withCString({
                  Darwin.fstatat(
                      sidecarDescriptor,
                      $0,
                      &finalPathMetadata,
                      AT_SYMLINK_NOFOLLOW
                  )
              }) == 0,
              sameUnchangedFile(openedMetadata, finalDescriptorMetadata),
              sameUnchangedFile(openedMetadata, finalPathMetadata) else {
            throw DiskFailure.unavailable
        }
        return .data(data)
    }

    private static func isSafeRegularFile(_ metadata: stat) -> Bool {
        (metadata.st_mode & S_IFMT) == S_IFREG
            && metadata.st_nlink == 1
            && metadata.st_size >= 0
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
    }

    private static func sameUnchangedFile(_ lhs: stat, _ rhs: stat) -> Bool {
        sameFile(lhs, rhs)
            && lhs.st_mode == rhs.st_mode
            && lhs.st_nlink == rhs.st_nlink
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
