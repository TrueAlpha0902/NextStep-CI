import Foundation
import NextStepDomain

public enum DocumentParseValidationError: Error, Equatable, LocalizedError, Sendable {
    case invalidField(String)
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidField(field):
            "Invalid document parse field: \(field)."
        case let .unsupportedSchema(version):
            "Unsupported document parse schema: \(version)."
        }
    }
}

public enum DocumentParseStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case complete
    case partial
    case unsupported
    case failed
}

public struct DocumentParserDescriptor: Codable, Hashable, Sendable {
    public let identifier: String
    public let version: String
    public let executedOnDevice: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case identifier
        case version
        case executedOnDevice
    }

    public init(identifier: String, version: String, executedOnDevice: Bool) throws {
        guard identifier.isGroundingText(maximumCharacters: 100),
              version.isGroundingText(maximumCharacters: 50) else {
            throw DocumentParseValidationError.invalidField("parser")
        }
        self.identifier = identifier
        self.version = version
        self.executedOnDevice = executedOnDevice
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectGroundingAdditionalKeys(allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            identifier: container.decode(String.self, forKey: .identifier),
            version: container.decode(String.self, forKey: .version),
            executedOnDevice: container.decode(Bool.self, forKey: .executedOnDevice)
        )
    }
}

public enum DocumentBlockKind: String, Codable, CaseIterable, Hashable, Sendable {
    case title
    case heading
    case paragraph
    case list
    case table
    case caption
    case formula
    case unknown
}

public struct DocumentTextBlock: Codable, Hashable, Sendable {
    public let blockID: UUID
    public let kind: DocumentBlockKind
    public let text: String
    public let anchorID: SourceAnchorID
    public let confidence: Double?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case blockID
        case kind
        case text
        case anchorID
        case confidence
    }

    public init(
        blockID: UUID,
        kind: DocumentBlockKind,
        text: String,
        anchorID: SourceAnchorID,
        confidence: Double?
    ) throws {
        guard text.isGroundingText(maximumCharacters: 100_000),
              confidence.map({ (0...1).contains($0) }) ?? true else {
            throw DocumentParseValidationError.invalidField("page block")
        }
        self.blockID = blockID
        self.kind = kind
        self.text = text
        self.anchorID = anchorID
        self.confidence = confidence
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectGroundingAdditionalKeys(allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            blockID: container.decode(UUID.self, forKey: .blockID),
            kind: container.decode(DocumentBlockKind.self, forKey: .kind),
            text: container.decode(String.self, forKey: .text),
            anchorID: container.decode(SourceAnchorID.self, forKey: .anchorID),
            confidence: container.decodeIfPresent(Double.self, forKey: .confidence)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(blockID, forKey: .blockID)
        try container.encode(kind, forKey: .kind)
        try container.encode(text, forKey: .text)
        try container.encode(anchorID, forKey: .anchorID)
        if let confidence {
            try container.encode(confidence, forKey: .confidence)
        } else {
            try container.encodeNil(forKey: .confidence)
        }
    }
}

public struct DocumentPage: Codable, Hashable, Sendable {
    public let pageIndex: Int
    public let widthPoints: Double
    public let heightPoints: Double
    public let blocks: [DocumentTextBlock]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case pageIndex
        case widthPoints
        case heightPoints
        case blocks
    }

    public init(
        pageIndex: Int,
        widthPoints: Double,
        heightPoints: Double,
        blocks: [DocumentTextBlock]
    ) throws {
        guard (0...999_999).contains(pageIndex),
              widthPoints.isFinite, heightPoints.isFinite,
              widthPoints > 0, heightPoints > 0,
              widthPoints <= 100_000, heightPoints <= 100_000,
              blocks.count <= 10_000,
              Set(blocks.map(\.blockID)).count == blocks.count else {
            throw DocumentParseValidationError.invalidField("page")
        }
        self.pageIndex = pageIndex
        self.widthPoints = widthPoints
        self.heightPoints = heightPoints
        self.blocks = blocks
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectGroundingAdditionalKeys(allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            pageIndex: container.decode(Int.self, forKey: .pageIndex),
            widthPoints: container.decode(Double.self, forKey: .widthPoints),
            heightPoints: container.decode(Double.self, forKey: .heightPoints),
            blocks: container.decode([DocumentTextBlock].self, forKey: .blocks)
        )
    }
}

public enum DocumentFactKind: String, Codable, CaseIterable, Hashable, Sendable {
    case title
    case author
    case date
    case deadline
    case courseCode
    case credit
    case grade
    case requirement
    case other
}

public struct DocumentFactOccurrence: Codable, Hashable, Sendable {
    public let anchorID: SourceAnchorID
    public let utf16Start: Int
    public let utf16Length: Int

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case anchorID
        case utf16Start
        case utf16Length
    }

    public init(
        anchorID: SourceAnchorID,
        utf16Start: Int,
        utf16Length: Int
    ) throws {
        guard utf16Start >= 0,
              utf16Length > 0,
              utf16Start <= 10_000_000,
              utf16Length <= 100_000,
              utf16Start <= Int.max - utf16Length else {
            throw DocumentParseValidationError.invalidField("fact occurrence")
        }
        self.anchorID = anchorID
        self.utf16Start = utf16Start
        self.utf16Length = utf16Length
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectGroundingAdditionalKeys(allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            anchorID: container.decode(SourceAnchorID.self, forKey: .anchorID),
            utf16Start: container.decode(Int.self, forKey: .utf16Start),
            utf16Length: container.decode(Int.self, forKey: .utf16Length)
        )
    }
}

public struct DocumentFactCandidate: Codable, Hashable, Sendable, Identifiable {
    public let candidateID: UUID
    public let kind: DocumentFactKind
    public let value: String
    public let anchorIDs: [SourceAnchorID]
    public let occurrences: [DocumentFactOccurrence]
    public let confidence: Double
    public let requiresUserConfirmation: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case candidateID
        case kind
        case value
        case anchorIDs
        case occurrences
        case confidence
        case requiresUserConfirmation
    }

    public var id: UUID { candidateID }

    public init(
        candidateID: UUID,
        kind: DocumentFactKind,
        value: String,
        anchorIDs: [SourceAnchorID],
        occurrences: [DocumentFactOccurrence],
        confidence: Double,
        requiresUserConfirmation: Bool
    ) throws {
        guard value.isGroundingText(maximumCharacters: 2_000),
              anchorIDs.isEmpty == false,
              anchorIDs.count <= 20,
              Set(anchorIDs).count == anchorIDs.count,
              occurrences.isEmpty == false,
              occurrences.count <= 100,
              Set(occurrences).count == occurrences.count,
              Set(occurrences.map(\.anchorID)) == Set(anchorIDs),
              confidence.isFinite,
              (0...1).contains(confidence) else {
            throw DocumentParseValidationError.invalidField("fact candidate")
        }
        self.candidateID = candidateID
        self.kind = kind
        self.value = value
        self.anchorIDs = anchorIDs
        self.occurrences = occurrences
        self.confidence = confidence
        self.requiresUserConfirmation = requiresUserConfirmation
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectGroundingAdditionalKeys(allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            candidateID: container.decode(UUID.self, forKey: .candidateID),
            kind: container.decode(DocumentFactKind.self, forKey: .kind),
            value: container.decode(String.self, forKey: .value),
            anchorIDs: container.decode([SourceAnchorID].self, forKey: .anchorIDs),
            occurrences: container.decode(
                [DocumentFactOccurrence].self,
                forKey: .occurrences
            ),
            confidence: container.decode(Double.self, forKey: .confidence),
            requiresUserConfirmation: container.decode(
                Bool.self,
                forKey: .requiresUserConfirmation
            )
        )
    }
}

public struct DocumentParseResult: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let requestID: UUID
    public let sourceDocumentID: SourceDocumentID
    public let sourceSHA256: String
    public let status: DocumentParseStatus
    public let parser: DocumentParserDescriptor
    public let languages: [String]
    public let pages: [DocumentPage]
    public let factCandidates: [DocumentFactCandidate]
    public let warnings: [String]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case requestID
        case sourceDocumentID
        case sourceSHA256
        case status
        case parser
        case languages
        case pages
        case factCandidates
        case warnings
    }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        requestID: UUID,
        sourceDocumentID: SourceDocumentID,
        sourceSHA256: String,
        status: DocumentParseStatus,
        parser: DocumentParserDescriptor,
        languages: [String],
        pages: [DocumentPage],
        factCandidates: [DocumentFactCandidate],
        warnings: [String]
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DocumentParseValidationError.unsupportedSchema(schemaVersion)
        }
        guard sourceSHA256.isGroundingLowercaseSHA256,
              languages.count <= 16,
              Set(languages).count == languages.count,
              languages.allSatisfy({ $0.isGroundingLanguageTag }),
              pages.count <= 10_000,
              Set(pages.map(\.pageIndex)).count == pages.count,
              factCandidates.count <= 5_000,
              Set(factCandidates.map(\.candidateID)).count == factCandidates.count,
              warnings.count <= 100,
              warnings.allSatisfy({ $0.isGroundingText(maximumCharacters: 500) }) else {
            throw DocumentParseValidationError.invalidField("document parse result")
        }
        let allBlocks = pages.flatMap(\.blocks)
        guard Set(allBlocks.map(\.blockID)).count == allBlocks.count,
              Set(allBlocks.map(\.anchorID)).count == allBlocks.count else {
            throw DocumentParseValidationError.invalidField("document block identity")
        }
        let knownAnchorIDs = Set(allBlocks.map(\.anchorID))
        guard factCandidates.allSatisfy({ Set($0.anchorIDs).isSubset(of: knownAnchorIDs) }) else {
            throw DocumentParseValidationError.invalidField("candidate anchors")
        }
        let textByAnchorID = Dictionary(grouping: allBlocks, by: \.anchorID)
        guard factCandidates.allSatisfy({ candidate in
            candidate.occurrences.allSatisfy { occurrence in
                textByAnchorID[occurrence.anchorID]?.contains(where: { block in
                    let text = block.text as NSString
                    let end = occurrence.utf16Start + occurrence.utf16Length
                    guard end <= text.length else { return false }
                    return text.substring(with: NSRange(
                        location: occurrence.utf16Start,
                        length: occurrence.utf16Length
                    )) == candidate.value
                }) == true
            }
        }) else {
            throw DocumentParseValidationError.invalidField("candidate value anchor")
        }
        if status == .unsupported || status == .failed {
            guard factCandidates.isEmpty else {
                throw DocumentParseValidationError.invalidField("failed parse candidates")
            }
        }
        self.schemaVersion = schemaVersion
        self.requestID = requestID
        self.sourceDocumentID = sourceDocumentID
        self.sourceSHA256 = sourceSHA256
        self.status = status
        self.parser = parser
        self.languages = languages
        self.pages = pages.sorted { $0.pageIndex < $1.pageIndex }
        self.factCandidates = factCandidates
        self.warnings = warnings
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectGroundingAdditionalKeys(allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let decodedPages = try container.decode([DocumentPage].self, forKey: .pages)
        let decodedCandidates: [DocumentFactCandidate]
        switch decodedSchemaVersion {
        case 1:
            decodedCandidates = try container.decode(
                [LegacyDocumentFactCandidate].self,
                forKey: .factCandidates
            ).map { try $0.migrated(using: decodedPages) }
        case Self.currentSchemaVersion:
            decodedCandidates = try container.decode(
                [DocumentFactCandidate].self,
                forKey: .factCandidates
            )
        default:
            throw DocumentParseValidationError.unsupportedSchema(decodedSchemaVersion)
        }
        try self.init(
            schemaVersion: Self.currentSchemaVersion,
            requestID: container.decode(UUID.self, forKey: .requestID),
            sourceDocumentID: container.decode(SourceDocumentID.self, forKey: .sourceDocumentID),
            sourceSHA256: container.decode(String.self, forKey: .sourceSHA256),
            status: container.decode(DocumentParseStatus.self, forKey: .status),
            parser: container.decode(DocumentParserDescriptor.self, forKey: .parser),
            languages: container.decode([String].self, forKey: .languages),
            pages: decodedPages,
            factCandidates: decodedCandidates,
            warnings: container.decode([String].self, forKey: .warnings)
        )
    }
}

private struct LegacyDocumentFactCandidate: Decodable {
    let candidateID: UUID
    let kind: DocumentFactKind
    let value: String
    let anchorIDs: [SourceAnchorID]
    let confidence: Double
    let requiresUserConfirmation: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case candidateID
        case kind
        case value
        case anchorIDs
        case confidence
        case requiresUserConfirmation
    }

    init(from decoder: Decoder) throws {
        try decoder.rejectGroundingAdditionalKeys(allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        candidateID = try container.decode(UUID.self, forKey: .candidateID)
        kind = try container.decode(DocumentFactKind.self, forKey: .kind)
        value = try container.decode(String.self, forKey: .value)
        anchorIDs = try container.decode([SourceAnchorID].self, forKey: .anchorIDs)
        confidence = try container.decode(Double.self, forKey: .confidence)
        requiresUserConfirmation = try container.decode(
            Bool.self,
            forKey: .requiresUserConfirmation
        )
        guard value.isGroundingText(maximumCharacters: 2_000),
              anchorIDs.isEmpty == false,
              anchorIDs.count <= 20,
              Set(anchorIDs).count == anchorIDs.count,
              confidence.isFinite,
              (0...1).contains(confidence) else {
            throw DocumentParseValidationError.invalidField("legacy fact candidate")
        }
    }

    func migrated(using pages: [DocumentPage]) throws -> DocumentFactCandidate {
        let blocksByAnchorID = Dictionary(
            grouping: pages.flatMap(\.blocks),
            by: \.anchorID
        )
        var occurrences: [DocumentFactOccurrence] = []
        for anchorID in anchorIDs {
            guard let blocks = blocksByAnchorID[anchorID] else {
                throw DocumentParseValidationError.invalidField("legacy candidate anchor")
            }
            for block in blocks {
                let text = block.text as NSString
                var searchRange = NSRange(location: 0, length: text.length)
                while searchRange.length > 0 {
                    let match = text.range(of: value, options: [], range: searchRange)
                    guard match.location != NSNotFound else { break }
                    occurrences.append(try DocumentFactOccurrence(
                        anchorID: anchorID,
                        utf16Start: match.location,
                        utf16Length: match.length
                    ))
                    let nextStart = NSMaxRange(match)
                    searchRange = NSRange(
                        location: nextStart,
                        length: text.length - nextStart
                    )
                }
            }
        }
        guard occurrences.isEmpty == false else {
            throw DocumentParseValidationError.invalidField("legacy candidate value")
        }
        return try DocumentFactCandidate(
            candidateID: candidateID,
            kind: kind,
            value: value,
            anchorIDs: anchorIDs,
            occurrences: occurrences,
            confidence: confidence,
            requiresUserConfirmation: requiresUserConfirmation
        )
    }
}

extension String {
    fileprivate var isGroundingLanguageTag: Bool {
        range(
            of: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$"#,
            options: .regularExpression
        ) != nil
    }

    fileprivate func isGroundingText(maximumCharacters: Int) -> Bool {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty == false && count <= maximumCharacters
    }
}

private struct GroundingAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension Decoder {
    func rejectGroundingAdditionalKeys<Key>(
        allowed: Key.Type
    ) throws where Key: CodingKey & CaseIterable {
        let untyped = try container(keyedBy: GroundingAnyCodingKey.self)
        let allowedKeys = Set(Key.allCases.map(\.stringValue))
        guard let unexpected = untyped.allKeys.first(where: {
            allowedKeys.contains($0.stringValue) == false
        }) else { return }
        throw DecodingError.dataCorruptedError(
            forKey: unexpected,
            in: untyped,
            debugDescription: "Unexpected property: \(unexpected.stringValue)."
        )
    }
}
