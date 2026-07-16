import Foundation

/// Opaque identity for one storage root.
///
/// It remains stable across replace/reset/recovery operations and changes only
/// when the underlying root changes. No URL or path crosses this boundary.
public struct AcademicWorkspaceStorageFingerprint: Hashable, Sendable,
    CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

/// Opaque identity for the observed primary/backup byte state.
///
/// A backing derives this from both files (or equivalent durable metadata) and
/// refreshes it before CAS. It must change after every successful mutation and
/// whenever out-of-band bytes change, even if their stored revision does not.
public struct AcademicWorkspaceStateFingerprint: Hashable, Sendable,
    CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

/// Atomic version of the backing's primary/backup pair.
public struct AcademicWorkspaceStorageVersion: Equatable, Sendable {
    public let rootFingerprint: AcademicWorkspaceStorageFingerprint
    public let stateFingerprint: AcademicWorkspaceStateFingerprint
    public let storageRevision: Int64

    public init(
        rootFingerprint: AcademicWorkspaceStorageFingerprint,
        stateFingerprint: AcademicWorkspaceStateFingerprint,
        storageRevision: Int64
    ) throws(AcademicWorkspaceFileBackingError) {
        guard storageRevision >= 0 else {
            throw AcademicWorkspaceFileBackingError.invalidStorageRevision
        }
        self.rootFingerprint = rootFingerprint
        self.stateFingerprint = stateFingerprint
        self.storageRevision = storageRevision
    }
}

/// Bounded result for one workspace file slot.
///
/// A backing checks metadata and performs a bounded read before constructing
/// `.data`; it reports `.oversized` without allocating the complete file.
public enum AcademicWorkspaceFileSlotValue: Equatable, Sendable {
    case missing
    case data(Data)
    case oversized

    static func bounded(_ data: Data?) -> Self {
        guard let data else { return .missing }
        guard data.count <= AcademicWorkspaceLimits.maximumEncodedBytes else {
            return .oversized
        }
        return .data(data)
    }
}

/// One atomic view of the primary and backup workspace bytes.
public struct AcademicWorkspaceFileSnapshot: Equatable, Sendable {
    public let primary: AcademicWorkspaceFileSlotValue
    public let backup: AcademicWorkspaceFileSlotValue
    public let version: AcademicWorkspaceStorageVersion

    public init(
        primary: AcademicWorkspaceFileSlotValue,
        backup: AcademicWorkspaceFileSlotValue,
        version: AcademicWorkspaceStorageVersion
    ) {
        self.primary = primary
        self.backup = backup
        self.version = version
    }
}

/// Sanitized errors a file backing may expose across the module boundary.
///
/// Implementations must not attach paths, URLs, or underlying error text.
public enum AcademicWorkspaceFileBackingError: Error, Equatable, Sendable {
    case conflict
    case unavailable
    case invalidStorageRevision
    case storageRevisionOverflow
}

extension AcademicWorkspaceFileBackingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .conflict:
            "The academic workspace files changed before the operation completed."
        case .unavailable:
            "The academic workspace files are unavailable."
        case .invalidStorageRevision:
            "The academic workspace storage revision is invalid."
        case .storageRevisionOverflow:
            "The academic workspace storage revision cannot advance."
        }
    }
}

/// Byte-only boundary implemented by the Notes storage layer.
///
/// `replace` and `reset` must atomically compare `expected`, update both files,
/// and advance `storageRevision` by exactly one. A successful mutation keeps
/// `rootFingerprint` stable and returns a new `stateFingerprint`. Before CAS,
/// an implementation refreshes the observed state fingerprint so an out-of-band
/// byte replacement conflicts even when its stored revision was not advanced.
/// The protocol deliberately accepts no URL, path, or caller-provided limit.
public protocol AcademicWorkspaceFileBacking: Sendable {
    func read() async throws(AcademicWorkspaceFileBackingError)
        -> AcademicWorkspaceFileSnapshot

    func replace(
        primaryData: Data?,
        backupData: Data?,
        expected: AcademicWorkspaceStorageVersion
    ) async throws(AcademicWorkspaceFileBackingError) -> AcademicWorkspaceFileSnapshot

    func reset(
        expected: AcademicWorkspaceStorageVersion
    ) async throws(AcademicWorkspaceFileBackingError) -> AcademicWorkspaceFileSnapshot
}

/// Opaque capability used to bracket an external notebook-root transition.
public struct AcademicWorkspaceRootTransitionToken: Hashable, Sendable {
    fileprivate let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Minimal gate required by a storage-root coordinator.
public protocol AcademicWorkspaceRootTransitionGating: Sendable {
    func prepareForRootTransition() async throws -> AcademicWorkspaceRootTransitionToken

    func finishRootTransition(
        _ token: AcademicWorkspaceRootTransitionToken
    ) async throws -> AcademicWorkspaceStoreSnapshot
}
