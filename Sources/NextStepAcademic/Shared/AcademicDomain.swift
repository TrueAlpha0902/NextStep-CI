import Foundation

public enum AcademicDomainError: Error, Equatable, Sendable {
    case unsupportedSchema(entity: String, version: Int)
    case invalidField(String)
    case valueOutOfBounds(field: String)
    case duplicateIdentifier(entity: String, identifier: String)
    case relationshipMismatch(String)
    case invalidStateTransition(entity: String, from: String, to: String)
    case revisionConflict(expected: Int64, actual: Int64)
    case unsupportedV1Operation(String)
    case chronologyViolation(String)
    case missingEntity(entity: String, identifier: String)
}

extension AcademicDomainError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(entity, version):
            "Unsupported \(entity) schema version \(version)."
        case let .invalidField(field):
            "The academic domain field '\(field)' is invalid."
        case let .valueOutOfBounds(field):
            "The academic domain field '\(field)' is outside its supported bounds."
        case let .duplicateIdentifier(entity, identifier):
            "The \(entity) identifier '\(identifier)' occurs more than once."
        case let .relationshipMismatch(detail):
            detail
        case let .invalidStateTransition(entity, from, to):
            "The \(entity) transition from \(from) to \(to) is invalid."
        case let .revisionConflict(expected, actual):
            "Expected revision \(expected), but found revision \(actual)."
        case let .unsupportedV1Operation(operation):
            "The operation '\(operation)' is unavailable in NextStep Academic V1."
        case let .chronologyViolation(detail):
            detail
        case let .missingEntity(entity, identifier):
            "The \(entity) '\(identifier)' is missing."
        }
    }
}

public enum AcademicDomainLimits {
    public static let maximumCourseNameCharacters = 240
    public static let maximumCourseNameUTF8Bytes = 2 * 1_024
    public static let maximumShortFieldCharacters = 240
    public static let maximumShortFieldUTF8Bytes = 2 * 1_024
    public static let maximumTopicCharacters = 1_000
    public static let maximumTopicUTF8Bytes = 8 * 1_024
    public static let maximumCaptureTextCharacters = 16_000
    public static let maximumCaptureTextUTF8Bytes = 128 * 1_024
    public static let maximumSummaryCharacters = 500
    public static let maximumSummaryUTF8Bytes = 4 * 1_024
    public static let maximumReasonCharacters = 2_000
    public static let maximumReasonUTF8Bytes = 16 * 1_024
    public static let maximumScheduleRulesPerCourse = 1_000
    public static let maximumSessionNoteLinks = 100_000
    public static let maximumCapturesPerSession = 10_000
    public static let maximumAuditEntriesPerCapture = 10_000
    public static let maximumWrapUpDecisions = 10_000
}

enum AcademicValidation {
    static func requireSchema(
        _ version: Int,
        current: Int,
        entity: String
    ) throws {
        guard version == current else {
            throw AcademicDomainError.unsupportedSchema(
                entity: entity,
                version: version
            )
        }
    }

    static func requireRevision(_ revision: Int64, field: String = "revision") throws {
        guard revision > 0 else {
            throw AcademicDomainError.valueOutOfBounds(field: field)
        }
    }

    static func nextRevision(after revision: Int64) throws -> Int64 {
        try requireRevision(revision)
        let (next, overflow) = revision.addingReportingOverflow(1)
        guard !overflow else {
            throw AcademicDomainError.valueOutOfBounds(field: "revision")
        }
        return next
    }

    static func requireFinite(_ date: Date, field: String) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw AcademicDomainError.invalidField(field)
        }
    }

    static func requireChronology(
        earlier: Date,
        later: Date,
        detail: String
    ) throws {
        try requireFinite(earlier, field: "earlierDate")
        try requireFinite(later, field: "laterDate")
        guard earlier <= later else {
            throw AcademicDomainError.chronologyViolation(detail)
        }
    }

    static func requireText(
        _ value: String,
        field: String,
        maximumCharacters: Int,
        maximumUTF8Bytes: Int,
        allowsNewlines: Bool
    ) throws {
        guard !value.isEmpty,
              value.utf8.count <= maximumUTF8Bytes,
              value.count <= maximumCharacters,
              value.trimmingCharacters(in: .whitespacesAndNewlines) == value,
              value.unicodeScalars.contains(where: { !isWhitespaceOrFormatting($0) }),
              value.unicodeScalars.allSatisfy({
                  isAllowedTextScalar($0, allowsNewlines: allowsNewlines)
              }) else {
            throw AcademicDomainError.invalidField(field)
        }
    }

    static func requireOptionalText(
        _ value: String?,
        field: String,
        maximumCharacters: Int,
        maximumUTF8Bytes: Int,
        allowsNewlines: Bool
    ) throws {
        guard let value else { return }
        try requireText(
            value,
            field: field,
            maximumCharacters: maximumCharacters,
            maximumUTF8Bytes: maximumUTF8Bytes,
            allowsNewlines: allowsNewlines
        )
    }

    static func requireUnique<ID: Hashable & CustomStringConvertible>(
        _ identifiers: [ID],
        entity: String
    ) throws {
        var seen = Set<ID>()
        for identifier in identifiers where !seen.insert(identifier).inserted {
            throw AcademicDomainError.duplicateIdentifier(
                entity: entity,
                identifier: identifier.description
            )
        }
    }

    static func decodeBoundedArray<Element: Decodable, Key: CodingKey>(
        _ type: Element.Type,
        from values: KeyedDecodingContainer<Key>,
        forKey key: Key,
        maximumCount: Int,
        field: String
    ) throws -> [Element] {
        var container = try values.nestedUnkeyedContainer(forKey: key)
        var result: [Element] = []
        result.reserveCapacity(min(container.count ?? 0, maximumCount))
        while !container.isAtEnd {
            guard result.count < maximumCount else {
                throw AcademicDomainError.valueOutOfBounds(field: field)
            }
            result.append(try container.decode(Element.self))
        }
        return result
    }

    private static func isAllowedTextScalar(
        _ scalar: Unicode.Scalar,
        allowsNewlines: Bool
    ) -> Bool {
        if scalar.value == 0x200C || scalar.value == 0x200D {
            return true
        }
        if allowsNewlines
            && (scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D) {
            return true
        }
        return !CharacterSet.controlCharacters.contains(scalar)
            && (allowsNewlines || !CharacterSet.newlines.contains(scalar))
    }

    private static func isWhitespaceOrFormatting(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar)
            || scalar.value == 0x200C
            || scalar.value == 0x200D
    }
}
