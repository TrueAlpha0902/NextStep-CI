import Foundation

public enum DomainValidationError: Error, Equatable, LocalizedError, Sendable {
    case invalidField(String)
    case valueOutOfBounds(String)
    case relationshipMismatch(String)
    case unsupportedSchema(entity: String, found: Int, current: Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidField(field):
            "Invalid value for \(field)."
        case let .valueOutOfBounds(field):
            "The value for \(field) is outside the allowed range."
        case let .relationshipMismatch(message):
            message
        case let .unsupportedSchema(entity, found, current):
            "Unsupported \(entity) schema \(found); current schema is \(current)."
        }
    }
}

public enum FactAuthority: String, Codable, CaseIterable, Hashable, Sendable {
    case sourceVerified
    case userConfirmed
    case aiProposed
    case inferred
}

public enum FactMutability: String, Codable, CaseIterable, Hashable, Sendable {
    case immutable
    case confirmationRequired
    case flexible
}

public enum ProvenanceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case user
    case importedSource
    case deterministicEngine
    case onDeviceModel
    case remoteModel
    case migration
}

public struct Provenance: Codable, Hashable, Sendable {
    public let kind: ProvenanceKind
    public let actorIdentifier: String?
    public let sourceDocumentIDs: [SourceDocumentID]
    public let softwareVersion: String?

    public init(
        kind: ProvenanceKind,
        actorIdentifier: String? = nil,
        sourceDocumentIDs: [SourceDocumentID] = [],
        softwareVersion: String? = nil
    ) {
        self.kind = kind
        self.actorIdentifier = actorIdentifier
        self.sourceDocumentIDs = sourceDocumentIDs
        self.softwareVersion = softwareVersion
    }

    public static let user = Provenance(kind: .user)
    public static let deterministicEngine = Provenance(kind: .deterministicEngine)
}

public struct RecordMetadata<ID: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public let id: ID
    public let schemaVersion: Int
    public let revision: Int64
    public let createdAt: Date
    public let updatedAt: Date
    public let deletedAt: Date?
    public let originDeviceID: DeviceID
    public let lastOperationID: OperationID?
    public let provenance: Provenance

    private enum CodingKeys: String, CodingKey {
        case id
        case schemaVersion
        case revision
        case createdAt
        case updatedAt
        case deletedAt
        case originDeviceID
        case lastOperationID
        case provenance
    }

    public init(
        id: ID,
        schemaVersion: Int = 1,
        revision: Int64 = 0,
        createdAt: Date,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil,
        originDeviceID: DeviceID,
        lastOperationID: OperationID? = nil,
        provenance: Provenance = .user
    ) throws {
        guard schemaVersion == 1 else {
            throw DomainValidationError.unsupportedSchema(
                entity: "record metadata",
                found: schemaVersion,
                current: 1
            )
        }
        guard revision >= 0 else {
            throw DomainValidationError.valueOutOfBounds("revision")
        }
        let effectiveUpdatedAt = updatedAt ?? createdAt
        guard effectiveUpdatedAt >= createdAt,
              deletedAt.map({ $0 >= effectiveUpdatedAt }) ?? true else {
            throw DomainValidationError.invalidField("record chronology")
        }
        self.id = id
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = effectiveUpdatedAt
        self.deletedAt = deletedAt
        self.originDeviceID = originDeviceID
        self.lastOperationID = lastOperationID
        self.provenance = provenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(ID.self, forKey: .id),
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            revision: container.decode(Int64.self, forKey: .revision),
            createdAt: container.decode(Date.self, forKey: .createdAt),
            updatedAt: container.decode(Date.self, forKey: .updatedAt),
            deletedAt: container.decodeIfPresent(Date.self, forKey: .deletedAt),
            originDeviceID: container.decode(DeviceID.self, forKey: .originDeviceID),
            lastOperationID: container.decodeIfPresent(OperationID.self, forKey: .lastOperationID),
            provenance: container.decode(Provenance.self, forKey: .provenance)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(revision, forKey: .revision)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(deletedAt, forKey: .deletedAt)
        try container.encode(originDeviceID, forKey: .originDeviceID)
        try container.encodeIfPresent(lastOperationID, forKey: .lastOperationID)
        try container.encode(provenance, forKey: .provenance)
    }
}

public struct FactValue<Value: Codable & Hashable & Sendable>: Codable, Hashable, Sendable {
    public let value: Value
    public let authority: FactAuthority
    public let mutability: FactMutability
    public let evidenceLinkIDs: [EvidenceLinkID]
    public let confidence: Double?
    public let confirmedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case value
        case authority
        case mutability
        case evidenceLinkIDs
        case confidence
        case confirmedAt
    }

    public init(
        value: Value,
        authority: FactAuthority,
        mutability: FactMutability,
        evidenceLinkIDs: [EvidenceLinkID] = [],
        confidence: Double? = nil,
        confirmedAt: Date? = nil
    ) throws {
        guard confidence.map({ (0...1).contains($0) }) ?? true else {
            throw DomainValidationError.valueOutOfBounds("confidence")
        }
        if authority == .userConfirmed, confirmedAt == nil {
            throw DomainValidationError.invalidField("confirmedAt")
        }
        if authority == .sourceVerified, evidenceLinkIDs.isEmpty {
            throw DomainValidationError.invalidField("source verified evidence")
        }
        if authority == .aiProposed || authority == .inferred {
            guard confidence != nil else {
                throw DomainValidationError.invalidField("proposal confidence")
            }
        }
        self.value = value
        self.authority = authority
        self.mutability = mutability
        self.evidenceLinkIDs = evidenceLinkIDs
        self.confidence = confidence
        self.confirmedAt = confirmedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            value: container.decode(Value.self, forKey: .value),
            authority: container.decode(FactAuthority.self, forKey: .authority),
            mutability: container.decode(FactMutability.self, forKey: .mutability),
            evidenceLinkIDs: container.decode([EvidenceLinkID].self, forKey: .evidenceLinkIDs),
            confidence: container.decodeIfPresent(Double.self, forKey: .confidence),
            confirmedAt: container.decodeIfPresent(Date.self, forKey: .confirmedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        try container.encode(authority, forKey: .authority)
        try container.encode(mutability, forKey: .mutability)
        try container.encode(evidenceLinkIDs, forKey: .evidenceLinkIDs)
        try container.encodeIfPresent(confidence, forKey: .confidence)
        try container.encodeIfPresent(confirmedAt, forKey: .confirmedAt)
    }
}

public struct LocalDay: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    private enum CodingKeys: String, CodingKey {
        case year
        case month
        case day
    }

    public init(year: Int, month: Int, day: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )
        guard let date = calendar.date(from: components) else {
            throw DomainValidationError.invalidField("localDay")
        }
        let check = calendar.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else {
            throw DomainValidationError.invalidField("localDay")
        }
        self.year = year
        self.month = month
        self.day = day
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            year: container.decode(Int.self, forKey: .year),
            month: container.decode(Int.self, forKey: .month),
            day: container.decode(Int.self, forKey: .day)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(year, forKey: .year)
        try container.encode(month, forKey: .month)
        try container.encode(day, forKey: .day)
    }

    public init(date: Date, timeZoneIdentifier: String) throws {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw DomainValidationError.invalidField("timeZoneIdentifier")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        try self.init(
            year: components.year ?? 0,
            month: components.month ?? 0,
            day: components.day ?? 0
        )
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// ISO-8601 weekday where Monday is 1 and Sunday is 7.
    public var isoWeekday: Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(
            from: DateComponents(year: year, month: month, day: day)
        )!
        let foundationWeekday = calendar.component(.weekday, from: date)
        return ((foundationWeekday + 5) % 7) + 1
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public func adding(days: Int) throws -> LocalDay {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              let shifted = calendar.date(byAdding: .day, value: days, to: date) else {
            throw DomainValidationError.invalidField("localDay arithmetic")
        }
        let result = calendar.dateComponents([.year, .month, .day], from: shifted)
        return try LocalDay(
            year: result.year ?? 0,
            month: result.month ?? 0,
            day: result.day ?? 0
        )
    }

    public func distance(to other: LocalDay) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: year, month: month, day: day))!
        let end = calendar.date(
            from: DateComponents(year: other.year, month: other.month, day: other.day)
        )!
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }
}

public struct TimeBlock: Codable, Hashable, Sendable {
    public let day: LocalDay
    public let startMinute: Int
    public let durationMinutes: Int
    public let timeZoneIdentifier: String

    public init(
        day: LocalDay,
        startMinute: Int,
        durationMinutes: Int,
        timeZoneIdentifier: String
    ) throws {
        guard (0..<1_440).contains(startMinute),
              (1...1_440).contains(durationMinutes),
              startMinute + durationMinutes <= 1_440 else {
            throw DomainValidationError.valueOutOfBounds("timeBlock")
        }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw DomainValidationError.invalidField("timeZoneIdentifier")
        }
        self.day = day
        self.startMinute = startMinute
        self.durationMinutes = durationMinutes
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

public enum GoalStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case proposed
    case active
    case paused
    case achieved
    case abandoned
}

public enum Priority: Int, Codable, CaseIterable, Hashable, Sendable, Comparable {
    case low = 1
    case normal = 2
    case high = 3
    case critical = 4

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
