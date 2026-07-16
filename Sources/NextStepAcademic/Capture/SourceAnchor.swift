import Foundation
import NotesCore

public struct UTF16TextRange: Codable, Equatable, Hashable, Sendable {
    public let location: Int
    public let length: Int

    public init(location: Int, length: Int) throws {
        guard location >= 0, length > 0 else {
            throw AcademicDomainError.valueOutOfBounds(field: "utf16Range")
        }
        let (_, overflow) = location.addingReportingOverflow(length)
        guard !overflow else {
            throw AcademicDomainError.valueOutOfBounds(field: "utf16Range")
        }
        self.location = location
        self.length = length
    }

    private enum CodingKeys: String, CodingKey { case location, length }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let location = try values.decode(Int.self, forKey: .location)
        let length = try values.decode(Int.self, forKey: .length)
        do {
            try self.init(
                location: location,
                length: length
            )
        } catch let error as AcademicDomainError {
            throw DecodingError.dataCorruptedError(
                forKey: .length,
                in: values,
                debugDescription: error.localizedDescription
            )
        }
    }
}

public struct SourceAnchor: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: SourceAnchorID
    public let noteID: NotebookID
    public let pageID: PageID
    public let blockID: TextBlockID
    /// Reserved for a later editor-selection adapter. V1 anchors are block-level.
    public let utf16Range: UTF16TextRange?
    public let noteRevision: Int64
    public let textHash: String?
    public let capturedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: SourceAnchorID = SourceAnchorID(),
        noteID: NotebookID,
        pageID: PageID,
        blockID: TextBlockID,
        utf16Range: UTF16TextRange? = nil,
        noteRevision: Int64,
        textHash: String? = nil,
        capturedAt: Date = Date()
    ) throws {
        try AcademicValidation.requireSchema(
            schemaVersion,
            current: Self.currentSchemaVersion,
            entity: "source anchor"
        )
        guard utf16Range == nil else {
            throw AcademicDomainError.unsupportedV1Operation("sourceAnchor.utf16Range")
        }
        try AcademicValidation.requireRevision(noteRevision, field: "sourceAnchor.noteRevision")
        if let textHash {
            guard textHash.count == 64,
                  textHash.unicodeScalars.allSatisfy({
                      (48...57).contains(Int($0.value))
                          || (97...102).contains(Int($0.value))
                  }) else {
                throw AcademicDomainError.invalidField("sourceAnchor.textHash")
            }
        }
        try AcademicValidation.requireFinite(capturedAt, field: "sourceAnchor.capturedAt")
        self.schemaVersion = schemaVersion
        self.id = id
        self.noteID = noteID
        self.pageID = pageID
        self.blockID = blockID
        self.utf16Range = utf16Range
        self.noteRevision = noteRevision
        self.textHash = textHash
        self.capturedAt = capturedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, noteID, pageID, blockID, utf16Range
        case noteRevision, textHash, capturedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        do {
            try AcademicValidation.requireSchema(
                schemaVersion,
                current: Self.currentSchemaVersion,
                entity: "source anchor"
            )
            try self.init(
                schemaVersion: schemaVersion,
                id: try values.decode(SourceAnchorID.self, forKey: .id),
                noteID: try values.decode(NotebookID.self, forKey: .noteID),
                pageID: try values.decode(PageID.self, forKey: .pageID),
                blockID: try values.decode(TextBlockID.self, forKey: .blockID),
                utf16Range: try values.decodeIfPresent(
                    UTF16TextRange.self,
                    forKey: .utf16Range
                ),
                noteRevision: try values.decode(Int64.self, forKey: .noteRevision),
                textHash: try values.decodeIfPresent(String.self, forKey: .textHash),
                capturedAt: try values.decode(Date.self, forKey: .capturedAt)
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

public struct QuickCaptureReference: Equatable, Sendable {
    public let noteID: NotebookID?
    public let pageID: PageID?

    public init(noteID: NotebookID? = nil, pageID: PageID? = nil) throws {
        guard pageID == nil || noteID != nil else {
            throw AcademicDomainError.relationshipMismatch(
                "A quick-capture page requires a note identifier."
            )
        }
        self.noteID = noteID
        self.pageID = pageID
    }
}

public enum CaptureSource: Codable, Equatable, Sendable {
    case noteAnchor(SourceAnchor)
    case quickCapture(QuickCaptureReference)

    private enum SourceType: String, Codable {
        case noteAnchor
        case quickCapture
    }

    private enum CodingKeys: String, CodingKey {
        case type, anchor, noteID, pageID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(SourceType.self, forKey: .type) {
        case .noteAnchor:
            guard !values.contains(.noteID), !values.contains(.pageID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: values,
                    debugDescription: "A note-anchor source cannot also contain quick-capture fields."
                )
            }
            self = .noteAnchor(try values.decode(SourceAnchor.self, forKey: .anchor))
        case .quickCapture:
            guard !values.contains(.anchor) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: values,
                    debugDescription: "A quick-capture source cannot also contain a note anchor."
                )
            }
            let noteID = try values.decodeIfPresent(NotebookID.self, forKey: .noteID)
            let pageID = try values.decodeIfPresent(PageID.self, forKey: .pageID)
            do {
                self = .quickCapture(try QuickCaptureReference(
                    noteID: noteID,
                    pageID: pageID
                ))
            } catch let error as AcademicDomainError {
                throw DecodingError.dataCorruptedError(
                    forKey: .pageID,
                    in: values,
                    debugDescription: error.localizedDescription
                )
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .noteAnchor(anchor):
            try values.encode(SourceType.noteAnchor, forKey: .type)
            try values.encode(anchor, forKey: .anchor)
        case let .quickCapture(reference):
            try values.encode(SourceType.quickCapture, forKey: .type)
            try values.encodeIfPresent(reference.noteID, forKey: .noteID)
            try values.encodeIfPresent(reference.pageID, forKey: .pageID)
        }
    }
}
