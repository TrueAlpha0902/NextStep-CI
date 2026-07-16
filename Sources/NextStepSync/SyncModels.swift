import CryptoKit
import Foundation

public enum SyncLimits {
    public static let maximumOperationBytes = 1 * 1_024 * 1_024
    public static let maximumManifestBytes = 8 * 1_024 * 1_024
    public static let maximumBlobBytes = 64 * 1_024 * 1_024
    public static let maximumLocalArchiveBytes = 64 * 1_024 * 1_024
    public static let maximumOperationsPerManifest = 50_000
    public static let maximumImportedOperations = 100_000
    public static let maximumDirectoryEntries = 1_024
    public static let maximumKeyLength = 128
    public static let maximumScalarStringBytes = 256 * 1_024
}

public enum NextStepSyncError: Error, Equatable, Sendable, LocalizedError {
    case invalidIdentifier(String)
    case invalidRelativePath(String)
    case sizeLimitExceeded(limit: Int)
    case malformedDocument(String)
    case unsupportedSchemaVersion(Int)
    case integrityMismatch(expected: String, actual: String)
    case immutableFileCollision(String)
    case incompatibleLibrary
    case incompatibleDevice
    case sequenceCollision(UInt64)
    case operationLimitExceeded
    case symlinkRejected(String)
    case nonRegularFile(String)
    case notFound(String)
    case transportUnavailable
    case ioFailure(String)
    case unresolvedConflict(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let value):
            "Invalid sync identifier: \(value)"
        case .invalidRelativePath(let value):
            "Invalid sync relative path: \(value)"
        case .sizeLimitExceeded(let limit):
            "The sync item exceeds the \(limit)-byte safety limit."
        case .malformedDocument(let reason):
            "Malformed sync document: \(reason)"
        case .unsupportedSchemaVersion(let version):
            "Unsupported sync schema version: \(version)"
        case .integrityMismatch(let expected, let actual):
            "Sync integrity mismatch (expected \(expected), got \(actual))."
        case .immutableFileCollision(let path):
            "An immutable sync file already contains different data: \(path)"
        case .incompatibleLibrary:
            "The sync data belongs to another library."
        case .incompatibleDevice:
            "The sync operation does not match its producing device."
        case .sequenceCollision(let sequence):
            "Two different operations use device sequence \(sequence)."
        case .operationLimitExceeded:
            "The first-version sync operation limit was exceeded."
        case .symlinkRejected(let path):
            "Symbolic links are not accepted in sync storage: \(path)"
        case .nonRegularFile(let path):
            "A sync item is not a regular file: \(path)"
        case .notFound(let path):
            "A sync item was not found: \(path)"
        case .transportUnavailable:
            "The selected sync folder is currently unavailable."
        case .ioFailure(let reason):
            "Sync storage failed: \(reason)"
        case .unresolvedConflict(let identifier):
            "The protected value conflict requires confirmation: \(identifier)"
        }
    }
}

public struct SyncLibraryID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.description < rhs.description
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let uuid = UUID(uuidString: raw) else {
            throw NextStepSyncError.invalidIdentifier(raw)
        }
        self.init(uuid)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct DeviceID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.description < rhs.description
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let uuid = UUID(uuidString: raw) else {
            throw NextStepSyncError.invalidIdentifier(raw)
        }
        self.init(uuid)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// A field/entity key that is safe to place in a structured sync document.
/// Keys are never used directly as filesystem paths.
public struct SyncKey: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= SyncLimits.maximumKeyLength,
              rawValue != ".",
              rawValue != "..",
              rawValue.unicodeScalars.allSatisfy({ scalar in
                  scalar.value >= 0x20 && scalar.value != 0x7f && scalar != "/" && scalar != "\\"
              }) else {
            throw NextStepSyncError.invalidIdentifier(rawValue)
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct SyncEntityReference: Hashable, Sendable, Comparable, Codable {
    public let kind: SyncKey
    public let id: UUID

    public init(kind: SyncKey, id: UUID) {
        self.kind = kind
        self.id = id
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }
}

public struct SyncDigest: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let hex: String

    public init(validating hex: String) throws {
        let normalized = hex.lowercased()
        guard normalized.utf8.count == 64,
              normalized.unicodeScalars.allSatisfy({
                  (0x30 ... 0x39).contains($0.value) || (0x61 ... 0x66).contains($0.value)
              }) else {
            throw NextStepSyncError.invalidIdentifier(hex)
        }
        self.hex = normalized
    }

    public init(data: Data) {
        self.hex = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public var description: String { hex }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.hex < rhs.hex }

    public init(from decoder: Decoder) throws {
        try self.init(validating: decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

public struct HybridLogicalTimestamp: Hashable, Sendable, Comparable, Codable {
    public let physicalMilliseconds: Int64
    public let logicalCounter: UInt32
    public let deviceID: DeviceID

    public init(
        physicalMilliseconds: Int64,
        logicalCounter: UInt32,
        deviceID: DeviceID
    ) throws {
        guard physicalMilliseconds >= 0 else {
            throw NextStepSyncError.malformedDocument("A hybrid clock cannot be negative.")
        }
        self.physicalMilliseconds = physicalMilliseconds
        self.logicalCounter = logicalCounter
        self.deviceID = deviceID
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.physicalMilliseconds != rhs.physicalMilliseconds {
            return lhs.physicalMilliseconds < rhs.physicalMilliseconds
        }
        if lhs.logicalCounter != rhs.logicalCounter {
            return lhs.logicalCounter < rhs.logicalCounter
        }
        return lhs.deviceID < rhs.deviceID
    }
}

/// A deterministic HLC. The app persists this value with the local queue.
public struct HybridLogicalClock: Hashable, Sendable, Codable {
    public let deviceID: DeviceID
    public private(set) var lastPhysicalMilliseconds: Int64
    public private(set) var logicalCounter: UInt32

    public init(
        deviceID: DeviceID,
        lastPhysicalMilliseconds: Int64 = 0,
        logicalCounter: UInt32 = 0
    ) throws {
        guard lastPhysicalMilliseconds >= 0 else {
            throw NextStepSyncError.malformedDocument("A hybrid clock cannot be negative.")
        }
        self.deviceID = deviceID
        self.lastPhysicalMilliseconds = lastPhysicalMilliseconds
        self.logicalCounter = logicalCounter
    }

    @discardableResult
    public mutating func tick(at date: Date) throws -> HybridLogicalTimestamp {
        let wall = Self.milliseconds(date)
        if wall > lastPhysicalMilliseconds {
            lastPhysicalMilliseconds = wall
            logicalCounter = 0
        } else {
            logicalCounter = try Self.increment(logicalCounter)
        }
        return try HybridLogicalTimestamp(
            physicalMilliseconds: lastPhysicalMilliseconds,
            logicalCounter: logicalCounter,
            deviceID: deviceID
        )
    }

    @discardableResult
    public mutating func observe(
        _ remote: HybridLogicalTimestamp,
        at date: Date
    ) throws -> HybridLogicalTimestamp {
        let wall = Self.milliseconds(date)
        let maximumPhysical = max(
            wall,
            max(lastPhysicalMilliseconds, remote.physicalMilliseconds)
        )
        let nextLogical: UInt32
        if maximumPhysical == lastPhysicalMilliseconds,
           maximumPhysical == remote.physicalMilliseconds {
            nextLogical = try Self.increment(max(logicalCounter, remote.logicalCounter))
        } else if maximumPhysical == lastPhysicalMilliseconds {
            nextLogical = try Self.increment(logicalCounter)
        } else if maximumPhysical == remote.physicalMilliseconds {
            nextLogical = try Self.increment(remote.logicalCounter)
        } else {
            nextLogical = 0
        }
        lastPhysicalMilliseconds = maximumPhysical
        logicalCounter = nextLogical
        return try HybridLogicalTimestamp(
            physicalMilliseconds: maximumPhysical,
            logicalCounter: nextLogical,
            deviceID: deviceID
        )
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        if !value.isFinite || value <= 0 { return 0 }
        if value >= Double(Int64.max) { return Int64.max }
        return Int64(value.rounded(.down))
    }

    private static func increment(_ value: UInt32) throws -> UInt32 {
        guard value < UInt32.max else {
            throw NextStepSyncError.malformedDocument("The hybrid clock counter overflowed.")
        }
        return value + 1
    }
}

public enum SyncFieldPolicy: String, Codable, Hashable, Sendable {
    /// A scalar that may be reordered automatically. The total HLC order wins.
    case flexibleLastWriterWins
    /// A user-confirmed fact. Competing values require explicit resolution.
    case confirmed
    /// An imported authority such as a verified deadline. It is never silently replaced.
    case immutable
}

public struct SyncBlobReference: Hashable, Sendable, Codable {
    public let digest: SyncDigest
    public let byteCount: Int
    public let mediaType: String?

    public init(digest: SyncDigest, byteCount: Int, mediaType: String? = nil) throws {
        guard byteCount >= 0, byteCount <= SyncLimits.maximumBlobBytes else {
            throw NextStepSyncError.sizeLimitExceeded(limit: SyncLimits.maximumBlobBytes)
        }
        if let mediaType,
           mediaType.utf8.count > 128 || mediaType.contains("\n") || mediaType.contains("\r") {
            throw NextStepSyncError.malformedDocument("Invalid blob media type.")
        }
        self.digest = digest
        self.byteCount = byteCount
        self.mediaType = mediaType
    }
}

public enum SyncScalarValue: Hashable, Sendable {
    case string(String)
    case integer(Int64)
    case decimal(String)
    case boolean(Bool)
    case timestampMilliseconds(Int64)
    case blob(SyncBlobReference)
    case null
}

extension SyncScalarValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case stringValue
        case integerValue
        case booleanValue
        case blobValue
    }

    private enum Kind: String, Codable {
        case string, integer, decimal, boolean, timestampMilliseconds, blob, null
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .string:
            self = .string(try container.decode(String.self, forKey: .stringValue))
        case .integer:
            self = .integer(try container.decode(Int64.self, forKey: .integerValue))
        case .decimal:
            self = .decimal(try container.decode(String.self, forKey: .stringValue))
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .booleanValue))
        case .timestampMilliseconds:
            self = .timestampMilliseconds(try container.decode(Int64.self, forKey: .integerValue))
        case .blob:
            self = .blob(try container.decode(SyncBlobReference.self, forKey: .blobValue))
        case .null:
            self = .null
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .integer(let value):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encode(value, forKey: .integerValue)
        case .decimal(let value):
            try container.encode(Kind.decimal, forKey: .kind)
            try container.encode(value, forKey: .stringValue)
        case .boolean(let value):
            try container.encode(Kind.boolean, forKey: .kind)
            try container.encode(value, forKey: .booleanValue)
        case .timestampMilliseconds(let value):
            try container.encode(Kind.timestampMilliseconds, forKey: .kind)
            try container.encode(value, forKey: .integerValue)
        case .blob(let value):
            try container.encode(Kind.blob, forKey: .kind)
            try container.encode(value, forKey: .blobValue)
        case .null:
            try container.encode(Kind.null, forKey: .kind)
        }
    }

    func validate() throws {
        switch self {
        case .string(let value), .decimal(let value):
            guard value.utf8.count <= SyncLimits.maximumScalarStringBytes else {
                throw NextStepSyncError.sizeLimitExceeded(limit: SyncLimits.maximumScalarStringBytes)
            }
        case .timestampMilliseconds(let value):
            guard value >= 0 else {
                throw NextStepSyncError.malformedDocument("A timestamp cannot be negative.")
            }
        case .blob(let reference):
            _ = try SyncBlobReference(
                digest: reference.digest,
                byteCount: reference.byteCount,
                mediaType: reference.mediaType
            )
        case .integer, .boolean, .null:
            break
        }
    }
}

public struct SyncConflictID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: SyncDigest

    public init(_ rawValue: SyncDigest) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.hex }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum SyncMutation: Hashable, Sendable {
    case set(field: SyncKey, value: SyncScalarValue, policy: SyncFieldPolicy)
    case tombstone(reason: String?)
    case resolveConflict(conflictID: SyncConflictID, chosenOperationID: UUID)
}

extension SyncMutation: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, field, value, policy, reason, conflictID, chosenOperationID
    }

    private enum Kind: String, Codable { case set, tombstone, resolveConflict }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .set:
            self = .set(
                field: try container.decode(SyncKey.self, forKey: .field),
                value: try container.decode(SyncScalarValue.self, forKey: .value),
                policy: try container.decode(SyncFieldPolicy.self, forKey: .policy)
            )
        case .tombstone:
            self = .tombstone(reason: try container.decodeIfPresent(String.self, forKey: .reason))
        case .resolveConflict:
            self = .resolveConflict(
                conflictID: try container.decode(SyncConflictID.self, forKey: .conflictID),
                chosenOperationID: try container.decode(UUID.self, forKey: .chosenOperationID)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .set(let field, let value, let policy):
            try container.encode(Kind.set, forKey: .kind)
            try container.encode(field, forKey: .field)
            try container.encode(value, forKey: .value)
            try container.encode(policy, forKey: .policy)
        case .tombstone(let reason):
            try container.encode(Kind.tombstone, forKey: .kind)
            try container.encodeIfPresent(reason, forKey: .reason)
        case .resolveConflict(let conflictID, let chosenOperationID):
            try container.encode(Kind.resolveConflict, forKey: .kind)
            try container.encode(conflictID, forKey: .conflictID)
            try container.encode(chosenOperationID, forKey: .chosenOperationID)
        }
    }
}

public struct SyncOperation: Hashable, Sendable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let libraryID: SyncLibraryID
    public let deviceID: DeviceID
    public let deviceSequence: UInt64
    public let timestamp: HybridLogicalTimestamp
    public let entity: SyncEntityReference
    public let mutation: SyncMutation

    public init(
        id: UUID = UUID(),
        libraryID: SyncLibraryID,
        deviceID: DeviceID,
        deviceSequence: UInt64,
        timestamp: HybridLogicalTimestamp,
        entity: SyncEntityReference,
        mutation: SyncMutation,
        schemaVersion: Int = currentSchemaVersion
    ) throws {
        self.schemaVersion = schemaVersion
        self.id = id
        self.libraryID = libraryID
        self.deviceID = deviceID
        self.deviceSequence = deviceSequence
        self.timestamp = timestamp
        self.entity = entity
        self.mutation = mutation
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw NextStepSyncError.unsupportedSchemaVersion(schemaVersion)
        }
        guard deviceSequence > 0 else {
            throw NextStepSyncError.malformedDocument("Device sequence must start at one.")
        }
        guard timestamp.deviceID == deviceID else {
            throw NextStepSyncError.incompatibleDevice
        }
        guard timestamp.physicalMilliseconds >= 0 else {
            throw NextStepSyncError.malformedDocument("A hybrid clock cannot be negative.")
        }
        switch mutation {
        case .set(_, let value, _):
            try value.validate()
        case .tombstone(let reason):
            guard reason?.utf8.count ?? 0 <= 4_096 else {
                throw NextStepSyncError.sizeLimitExceeded(limit: 4_096)
            }
        case .resolveConflict:
            break
        }
    }
}

public struct SyncIntegrityEnvelope: Hashable, Sendable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let payload: Data
    public let sha256: SyncDigest

    public init(payload: Data, schemaVersion: Int = currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.payload = payload
        self.sha256 = SyncDigest(data: payload)
    }

    public func verifiedPayload(maximumBytes: Int) throws -> Data {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw NextStepSyncError.unsupportedSchemaVersion(schemaVersion)
        }
        guard payload.count <= maximumBytes else {
            throw NextStepSyncError.sizeLimitExceeded(limit: maximumBytes)
        }
        let actual = SyncDigest(data: payload)
        guard actual == sha256 else {
            throw NextStepSyncError.integrityMismatch(expected: sha256.hex, actual: actual.hex)
        }
        return payload
    }
}

public enum SyncCodec {
    public static func encodeOperationEnvelope(_ operation: SyncOperation) throws -> Data {
        try operation.validate()
        let payload = try encode(operation)
        guard payload.count <= SyncLimits.maximumOperationBytes else {
            throw NextStepSyncError.sizeLimitExceeded(limit: SyncLimits.maximumOperationBytes)
        }
        return try encode(SyncIntegrityEnvelope(payload: payload))
    }

    public static func decodeOperationEnvelope(_ data: Data) throws -> SyncOperation {
        guard data.count <= SyncLimits.maximumOperationBytes * 2 else {
            throw NextStepSyncError.sizeLimitExceeded(limit: SyncLimits.maximumOperationBytes * 2)
        }
        let envelope: SyncIntegrityEnvelope = try decode(SyncIntegrityEnvelope.self, from: data)
        let payload = try envelope.verifiedPayload(maximumBytes: SyncLimits.maximumOperationBytes)
        let operation: SyncOperation = try decode(SyncOperation.self, from: payload)
        try operation.validate()
        return operation
    }

    public static func encodeEnvelope<T: Encodable>(_ value: T, maximumBytes: Int) throws -> Data {
        let payload = try encode(value)
        guard payload.count <= maximumBytes else {
            throw NextStepSyncError.sizeLimitExceeded(limit: maximumBytes)
        }
        return try encode(SyncIntegrityEnvelope(payload: payload))
    }

    public static func decodeEnvelope<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        maximumBytes: Int
    ) throws -> T {
        guard data.count <= maximumBytes * 2 else {
            throw NextStepSyncError.sizeLimitExceeded(limit: maximumBytes * 2)
        }
        let envelope: SyncIntegrityEnvelope = try decode(SyncIntegrityEnvelope.self, from: data)
        return try decode(type, from: envelope.verifiedPayload(maximumBytes: maximumBytes))
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        return try decoder.decode(type, from: data)
    }
}

public struct SyncOperationReference: Hashable, Sendable, Codable, Comparable {
    public let operationID: UUID
    public let deviceSequence: UInt64
    public let timestamp: HybridLogicalTimestamp
    public let filename: String
    public let envelopeSHA256: SyncDigest

    public init(operation: SyncOperation, filename: String, envelopeData: Data) throws {
        guard operation.deviceSequence > 0 else {
            throw NextStepSyncError.malformedDocument("Invalid operation sequence.")
        }
        _ = try SyncRelativePath(component: filename)
        guard filename == Self.canonicalFilename(
            deviceSequence: operation.deviceSequence,
            operationID: operation.id
        ) else {
            throw NextStepSyncError.malformedDocument("Non-canonical operation filename.")
        }
        self.operationID = operation.id
        self.deviceSequence = operation.deviceSequence
        self.timestamp = operation.timestamp
        self.filename = filename
        self.envelopeSHA256 = SyncDigest(data: envelopeData)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.deviceSequence != rhs.deviceSequence { return lhs.deviceSequence < rhs.deviceSequence }
        return lhs.operationID.uuidString.lowercased() < rhs.operationID.uuidString.lowercased()
    }

    public static func canonicalFilename(deviceSequence: UInt64, operationID: UUID) -> String {
        let rawSequence = String(deviceSequence)
        let sequence = String(repeating: "0", count: max(0, 20 - rawSequence.count))
            + rawSequence
        return "\(sequence)-\(operationID.uuidString.lowercased()).operation.json"
    }
}

public struct SyncDeviceManifest: Hashable, Sendable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public let libraryID: SyncLibraryID
    public let deviceID: DeviceID
    public private(set) var generation: UInt64
    public private(set) var operations: [SyncOperationReference]

    public init(libraryID: SyncLibraryID, deviceID: DeviceID) {
        self.schemaVersion = Self.currentSchemaVersion
        self.libraryID = libraryID
        self.deviceID = deviceID
        self.generation = 0
        self.operations = []
    }

    public mutating func append(_ reference: SyncOperationReference) throws {
        try validate()
        if let existing = operations.first(where: { $0.operationID == reference.operationID }) {
            guard existing == reference else {
                throw NextStepSyncError.immutableFileCollision(reference.filename)
            }
            return
        }
        if let existing = operations.first(where: { $0.deviceSequence == reference.deviceSequence }) {
            guard existing.operationID == reference.operationID else {
                throw NextStepSyncError.sequenceCollision(reference.deviceSequence)
            }
            return
        }
        guard operations.count < SyncLimits.maximumOperationsPerManifest else {
            throw NextStepSyncError.operationLimitExceeded
        }
        operations.append(reference)
        operations.sort()
        guard generation < UInt64.max else {
            throw NextStepSyncError.malformedDocument("Manifest generation overflowed.")
        }
        generation += 1
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw NextStepSyncError.unsupportedSchemaVersion(schemaVersion)
        }
        guard operations.count <= SyncLimits.maximumOperationsPerManifest else {
            throw NextStepSyncError.operationLimitExceeded
        }
        guard generation == UInt64(operations.count) else {
            throw NextStepSyncError.malformedDocument("Manifest generation does not match its history.")
        }
        var IDs = Set<UUID>()
        var sequences = Set<UInt64>()
        for reference in operations {
            guard reference.timestamp.deviceID == deviceID else {
                throw NextStepSyncError.incompatibleDevice
            }
            guard reference.timestamp.physicalMilliseconds >= 0,
                  reference.deviceSequence > 0 else {
                throw NextStepSyncError.malformedDocument("Invalid manifest operation reference.")
            }
            guard IDs.insert(reference.operationID).inserted else {
                throw NextStepSyncError.malformedDocument("Duplicate operation ID in manifest.")
            }
            guard sequences.insert(reference.deviceSequence).inserted else {
                throw NextStepSyncError.sequenceCollision(reference.deviceSequence)
            }
            _ = try SyncRelativePath(component: reference.filename)
            guard reference.filename == SyncOperationReference.canonicalFilename(
                deviceSequence: reference.deviceSequence,
                operationID: reference.operationID
            ) else {
                throw NextStepSyncError.malformedDocument("Non-canonical operation filename.")
            }
        }
    }
}

public struct SyncCheckpoint: Hashable, Sendable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var importedOperationIDs: Set<UUID>
    public var manifestGenerations: [String: UInt64]

    public init(
        importedOperationIDs: Set<UUID> = [],
        manifestGenerations: [String: UInt64] = [:]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.importedOperationIDs = importedOperationIDs
        self.manifestGenerations = manifestGenerations
    }
}

public struct SyncFieldRevision: Hashable, Sendable, Codable, Comparable {
    public let operationID: UUID
    public let timestamp: HybridLogicalTimestamp
    public let value: SyncScalarValue
    public let policy: SyncFieldPolicy

    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.operationID.uuidString.lowercased() < rhs.operationID.uuidString.lowercased()
    }
}

public struct SyncResolvedField: Hashable, Sendable, Codable {
    public let field: SyncKey
    public let value: SyncScalarValue
    public let winningOperationID: UUID
    public let policy: SyncFieldPolicy
    /// Every distinct accepted operation is retained, including losing LWW values.
    public let history: [SyncFieldRevision]
}

public enum SyncConflictKind: String, Hashable, Sendable, Codable {
    case competingProtectedValues
    case policyMismatch
}

public enum SyncConflictStatus: String, Hashable, Sendable, Codable {
    case unresolved
    case resolved
}

public struct ConflictRecord: Hashable, Sendable, Codable, Comparable {
    public let id: SyncConflictID
    public let entity: SyncEntityReference
    public let field: SyncKey
    public let kind: SyncConflictKind
    public let status: SyncConflictStatus
    public let contenders: [SyncFieldRevision]
    public let chosenOperationID: UUID?
    public let resolutionOperationID: UUID?

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.id < rhs.id }
}

public struct SyncEntitySnapshot: Hashable, Sendable, Codable, Comparable {
    public let reference: SyncEntityReference
    public let isDeleted: Bool
    public let tombstoneOperationID: UUID?
    public let fields: [SyncResolvedField]

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.reference < rhs.reference }

    public func field(_ key: SyncKey) -> SyncResolvedField? {
        fields.first { $0.field == key }
    }
}

public struct SyncSnapshot: Hashable, Sendable, Codable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let entities: [SyncEntitySnapshot]
    public let conflicts: [ConflictRecord]

    public init(entities: [SyncEntitySnapshot], conflicts: [ConflictRecord]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.entities = entities.sorted()
        self.conflicts = conflicts.sorted()
    }

    public func entity(_ reference: SyncEntityReference) -> SyncEntitySnapshot? {
        entities.first { $0.reference == reference }
    }
}

public struct SyncReport: Hashable, Sendable {
    public let uploadedOperationCount: Int
    public let importedOperationCount: Int
    public let duplicateOperationCount: Int
    public let unresolvedConflictCount: Int
    public let pendingOperationCount: Int
}
