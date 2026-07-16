import Foundation

public struct CourseID: RawRepresentable, Codable, Hashable, Sendable, Comparable,
    CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.description < rhs.description }
}

public struct CourseScheduleRuleID: RawRepresentable, Codable, Hashable, Sendable, Comparable,
    CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.description < rhs.description }
}

public struct CourseSessionID: RawRepresentable, Codable, Hashable, Sendable, Comparable,
    CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.description < rhs.description }
}

public struct SessionNoteLinkID: RawRepresentable, Codable, Hashable, Sendable, Comparable,
    CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.description < rhs.description }
}

public struct SourceAnchorID: RawRepresentable, Codable, Hashable, Sendable, Comparable,
    CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.description < rhs.description }
}

public struct CaptureItemID: RawRepresentable, Codable, Hashable, Sendable, Comparable,
    CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.description < rhs.description }
}

public struct CaptureAuditEntryID: RawRepresentable, Codable, Hashable, Sendable, Comparable,
    CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.description < rhs.description }
}

public struct SessionWrapUpID: RawRepresentable, Codable, Hashable, Sendable, Comparable,
    CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.description < rhs.description }
}

public enum AcademicEntityType: String, Codable, CaseIterable, Hashable, Sendable {
    case course
    case courseScheduleRule
    case courseSession
    case sessionNoteLink
    case note
    case noteBlock
    case sourceAnchor
    case captureItem
    case sessionWrapUp
}

public struct AcademicEntityRef: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let entityType: AcademicEntityType
    public let entityID: UUID

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        entityType: AcademicEntityType,
        entityID: UUID
    ) throws {
        try AcademicValidation.requireSchema(
            schemaVersion,
            current: Self.currentSchemaVersion,
            entity: "entity reference"
        )
        self.schemaVersion = schemaVersion
        self.entityType = entityType
        self.entityID = entityID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, entityType, entityID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        do {
            try AcademicValidation.requireSchema(
                schemaVersion,
                current: Self.currentSchemaVersion,
                entity: "entity reference"
            )
            try self.init(
                schemaVersion: schemaVersion,
                entityType: try values.decode(AcademicEntityType.self, forKey: .entityType),
                entityID: try values.decode(UUID.self, forKey: .entityID)
            )
        } catch let error as AcademicDomainError {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: error.localizedDescription
            )
        }
    }
}
