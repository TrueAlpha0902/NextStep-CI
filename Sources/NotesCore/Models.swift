import Foundation

// MARK: - Stable identifiers

public struct NotebookID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
}

public struct PageID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
}

public struct ElementID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
}

public struct TextBlockID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
}

public struct StudyCardID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
}

public struct OperationID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
}

public struct AudioSessionID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
}

public struct AudioTimelineMarkID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
}

public struct SearchSegmentID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
}

public struct AIArtifactID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
}

/// A content-addressed identifier. `rawValue` is a lowercase SHA-256 digest.
public struct AssetID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue.lowercased() }
    public init(_ rawValue: String) { self.rawValue = rawValue.lowercased() }
    public var description: String { rawValue }

    private enum CodingKeys: String, CodingKey { case rawValue }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer().decode(String.self) {
            self.init(single)
            return
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try values.decode(String.self, forKey: .rawValue))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(rawValue, forKey: .rawValue)
    }

    public var isSHA256Digest: Bool {
        rawValue.count == 64 && rawValue.unicodeScalars.allSatisfy {
            (48...57).contains(Int($0.value)) || (97...102).contains(Int($0.value))
        }
    }
}

// MARK: - Notebook and page models

public struct NotebookManifest: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var id: NotebookID
    public var title: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var revision: Int64
    public var pages: [PageDescriptor]
    public var assets: [AssetDescriptor]
    public var audioSessions: [AudioSessionDescriptor]
    public var tags: [String]
    public var isFavorite: Bool

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: NotebookID = NotebookID(),
        title: String,
        createdAt: Date = Date(),
        modifiedAt: Date? = nil,
        revision: Int64 = 0,
        pages: [PageDescriptor] = [],
        assets: [AssetDescriptor] = [],
        audioSessions: [AudioSessionDescriptor] = [],
        tags: [String] = [],
        isFavorite: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.revision = revision
        self.pages = pages
        self.assets = assets
        self.audioSessions = audioSessions
        self.tags = tags
        self.isFavorite = isFavorite
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, title, createdAt, modifiedAt, revision, pages, assets
        case audioSessions, tags, isFavorite
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.currentSchemaVersion).contains(decodedSchemaVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported notebook-manifest schema version \(decodedSchemaVersion)."
            )
        }
        schemaVersion = decodedSchemaVersion
        id = try values.decode(NotebookID.self, forKey: .id)
        title = try values.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        modifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
        revision = try values.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        pages = try values.decodeIfPresent([PageDescriptor].self, forKey: .pages) ?? []
        assets = try values.decodeIfPresent([AssetDescriptor].self, forKey: .assets) ?? []
        audioSessions = try values.decodeIfPresent([AudioSessionDescriptor].self, forKey: .audioSessions) ?? []
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        isFavorite = try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }
}

public enum PageKind: String, Codable, CaseIterable, Hashable, Sendable {
    case notebook
    case whiteboard
    case textDocument
    case studySet
    case importedDocument
}

public struct PageSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let a4 = PageSize(width: 595, height: 842)
    public static let letter = PageSize(width: 612, height: 792)
}

public enum PageBackground: Codable, Equatable, Sendable {
    case plain(colorHex: String)
    case ruled(colorHex: String, spacing: Double)
    case grid(colorHex: String, spacing: Double)
    case dotted(colorHex: String, spacing: Double)
    case pdf(assetID: AssetID, pageIndex: Int)
    case image(assetID: AssetID)
    /// Legacy generic asset background retained for on-disk compatibility.
    case asset(AssetID)
}

public struct PageDescriptor: Codable, Equatable, Sendable, Identifiable {
    /// Version 3 makes `content.json` part of the durable contract for
    /// text-document and study-set pages. Version 4 adds the optional flat
    /// outline entry while retaining the version-3 bookmark flag.
    public static let currentSchemaVersion = 4
    /// Version at which structured page kinds began requiring `content.json`.
    /// Keep content compatibility independent from later descriptor additions.
    public static let structuredContentSchemaVersion = 3
    public static let outlineTitleSchemaVersion = 4
    public static let maximumOutlineTitleCharacters = 120
    public static let maximumOutlineTitleUTF8Bytes = 1_024
    public static let zeroWidthNonJoinerScalarValue: UInt32 = 0x200C
    public static let zeroWidthJoinerScalarValue: UInt32 = 0x200D

    public var schemaVersion: Int
    public var id: PageID
    public var kind: PageKind
    public var title: String?
    public var createdAt: Date
    public var modifiedAt: Date
    public var size: PageSize
    public var background: PageBackground
    public var rotationDegrees: Int
    public var isBookmarked: Bool
    public var outlineTitle: String?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: PageID = PageID(),
        kind: PageKind = .notebook,
        title: String? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date? = nil,
        size: PageSize = .a4,
        background: PageBackground = .plain(colorHex: "#FFFFFF"),
        rotationDegrees: Int = 0,
        isBookmarked: Bool = false,
        outlineTitle: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.kind = kind
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.size = size
        self.background = background
        self.rotationDegrees = ((rotationDegrees % 360) + 360) % 360
        self.isBookmarked = isBookmarked
        self.outlineTitle = outlineTitle
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, kind, title, createdAt, modifiedAt, size, background
        case rotationDegrees, isBookmarked, outlineTitle
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.currentSchemaVersion).contains(decodedSchemaVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported page-descriptor schema version \(decodedSchemaVersion)."
            )
        }
        schemaVersion = decodedSchemaVersion
        id = try values.decode(PageID.self, forKey: .id)
        kind = try values.decodeIfPresent(PageKind.self, forKey: .kind) ?? .notebook
        title = try values.decodeIfPresent(String.self, forKey: .title)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        modifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
        size = try values.decodeIfPresent(PageSize.self, forKey: .size) ?? .a4
        background = try values.decodeIfPresent(PageBackground.self, forKey: .background) ?? .plain(colorHex: "#FFFFFF")
        rotationDegrees = try values.decodeIfPresent(Int.self, forKey: .rotationDegrees) ?? 0
        isBookmarked = try values.decodeIfPresent(Bool.self, forKey: .isBookmarked) ?? false
        outlineTitle = try values.decodeIfPresent(String.self, forKey: .outlineTitle)
        guard decodedSchemaVersion >= Self.outlineTitleSchemaVersion
                || !values.contains(.outlineTitle) else {
            throw DecodingError.dataCorruptedError(
                forKey: .outlineTitle,
                in: values,
                debugDescription: "An outline title requires page-descriptor schema version 4."
            )
        }
        guard Self.isValidOutlineTitle(outlineTitle) else {
            throw DecodingError.dataCorruptedError(
                forKey: .outlineTitle,
                in: values,
                debugDescription: "An outline title must be canonical, single-line text containing 1...\(Self.maximumOutlineTitleCharacters) characters, at most \(Self.maximumOutlineTitleUTF8Bytes) UTF-8 bytes, and no newline or unsafe control/format scalars (Unicode ZWNJ/ZWJ are allowed)."
            )
        }
    }

    /// `nil` means the page has no custom outline entry. Non-nil values are
    /// deliberately validated rather than normalized so persisted metadata and
    /// the text shown to users always have one canonical representation.
    public static func isValidOutlineTitle(_ title: String?) -> Bool {
        guard let title else { return true }
        guard !title.isEmpty,
              title.count <= maximumOutlineTitleCharacters,
              title.utf8.count <= maximumOutlineTitleUTF8Bytes,
              title.trimmingCharacters(in: .whitespacesAndNewlines) == title else {
            return false
        }
        guard title.unicodeScalars.allSatisfy({
            !isDisallowedOutlineScalar($0)
        }) else { return false }
        return title.unicodeScalars.contains {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && $0.value != zeroWidthNonJoinerScalarValue
                && $0.value != zeroWidthJoinerScalarValue
        }
    }

    /// Foundation's control-character set also contains Unicode format
    /// scalars. Preserve ZWNJ/ZWJ because they are required by scripts and
    /// emoji graphemes, while rejecting every other control/format scalar and
    /// all newline separators.
    public static func isDisallowedOutlineScalar(
        _ scalar: Unicode.Scalar
    ) -> Bool {
        if scalar.value == zeroWidthNonJoinerScalarValue
            || scalar.value == zeroWidthJoinerScalarValue {
            return false
        }
        return CharacterSet.controlCharacters.contains(scalar)
            || CharacterSet.newlines.contains(scalar)
    }
}

// MARK: - Structured page content

/// Semantic styles are stored instead of presentation attributes so documents can
/// adopt platform typography and accessibility settings without rewriting content.
public enum TextBlockStyle: String, Codable, CaseIterable, Sendable {
    case title
    case heading1
    case heading2
    case heading3
    case body
    case bulletedList
    case numberedList
    case checklist
    case quote
    case code
    case divider
}

public struct TextBlock: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: TextBlockID
    public var style: TextBlockStyle
    public var text: String
    public var indentationLevel: Int
    public var isChecked: Bool?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: TextBlockID = TextBlockID(),
        style: TextBlockStyle = .body,
        text: String = "",
        indentationLevel: Int = 0,
        isChecked: Bool? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.style = style
        self.text = text
        self.indentationLevel = max(0, indentationLevel)
        self.isChecked = isChecked
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, style, text, indentationLevel, isChecked, createdAt, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try values.decode(TextBlockID.self, forKey: .id)
        style = try values.decodeIfPresent(TextBlockStyle.self, forKey: .style) ?? .body
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        indentationLevel = try values.decodeIfPresent(Int.self, forKey: .indentationLevel) ?? 0
        isChecked = try values.decodeIfPresent(Bool.self, forKey: .isChecked)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        modifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
    }
}

public struct TextDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var blocks: [TextBlock]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        blocks: [TextBlock] = []
    ) {
        self.schemaVersion = schemaVersion
        self.blocks = blocks
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, blocks }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        blocks = try values.decodeIfPresent([TextBlock].self, forKey: .blocks) ?? []
    }
}

public struct StudyCard: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: StudyCardID
    public var prompt: String
    public var answer: String
    public var hint: String?
    public var tags: [String]
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: StudyCardID = StudyCardID(),
        prompt: String = "",
        answer: String = "",
        hint: String? = nil,
        tags: [String] = [],
        createdAt: Date = Date(),
        modifiedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.prompt = prompt
        self.answer = answer
        self.hint = hint
        self.tags = tags
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, prompt, answer, hint, tags, createdAt, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        id = try values.decode(StudyCardID.self, forKey: .id)
        prompt = try values.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        answer = try values.decodeIfPresent(String.self, forKey: .answer) ?? ""
        hint = try values.decodeIfPresent(String.self, forKey: .hint)
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        modifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
    }
}

/// Review state is kept separately from card text so studying never has to
/// rewrite a card merely to record progress.
public struct StudyCardProgress: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var cardID: StudyCardID
    public var repetitions: Int
    public var lapses: Int
    public var intervalDays: Int
    public var easeFactor: Double
    public var dueAt: Date
    public var lastReviewedAt: Date?

    public var id: StudyCardID { cardID }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        cardID: StudyCardID,
        repetitions: Int = 0,
        lapses: Int = 0,
        intervalDays: Int = 0,
        easeFactor: Double = 2.5,
        dueAt: Date = Date(),
        lastReviewedAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.cardID = cardID
        self.repetitions = repetitions
        self.lapses = lapses
        self.intervalDays = intervalDays
        self.easeFactor = easeFactor
        self.dueAt = dueAt
        self.lastReviewedAt = lastReviewedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, cardID, repetitions, lapses, intervalDays, easeFactor
        case dueAt, lastReviewedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        cardID = try values.decode(StudyCardID.self, forKey: .cardID)
        repetitions = try values.decodeIfPresent(Int.self, forKey: .repetitions) ?? 0
        lapses = try values.decodeIfPresent(Int.self, forKey: .lapses) ?? 0
        intervalDays = try values.decodeIfPresent(Int.self, forKey: .intervalDays) ?? 0
        easeFactor = try values.decodeIfPresent(Double.self, forKey: .easeFactor) ?? 2.5
        dueAt = try values.decodeIfPresent(Date.self, forKey: .dueAt) ?? .distantPast
        lastReviewedAt = try values.decodeIfPresent(Date.self, forKey: .lastReviewedAt)
    }
}

public struct StudySet: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var cards: [StudyCard]
    public var progress: [StudyCardProgress]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        cards: [StudyCard] = [],
        progress: [StudyCardProgress] = []
    ) {
        self.schemaVersion = schemaVersion
        self.cards = cards
        self.progress = progress
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, cards, progress }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        cards = try values.decodeIfPresent([StudyCard].self, forKey: .cards) ?? []
        progress = try values.decodeIfPresent([StudyCardProgress].self, forKey: .progress) ?? []
    }
}

/// A tagged, versioned envelope for the structured content stored in
/// `pages/<page-id>/content.json`.
public enum PageContent: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    case textDocument(TextDocument)
    case studySet(StudySet)

    public var pageKind: PageKind {
        switch self {
        case .textDocument: return .textDocument
        case .studySet: return .studySet
        }
    }

    public static func empty(for pageKind: PageKind) -> PageContent? {
        switch pageKind {
        case .textDocument: return .textDocument(TextDocument())
        case .studySet: return .studySet(StudySet())
        case .notebook, .whiteboard, .importedDocument: return nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, type, textDocument, studySet
    }

    private enum ContentType: String, Codable {
        case textDocument, studySet
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported page-content schema version \(schemaVersion)."
            )
        }
        switch try values.decode(ContentType.self, forKey: .type) {
        case .textDocument:
            self = .textDocument(try values.decode(TextDocument.self, forKey: .textDocument))
        case .studySet:
            self = .studySet(try values.decode(StudySet.self, forKey: .studySet))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        switch self {
        case .textDocument(let document):
            try values.encode(ContentType.textDocument, forKey: .type)
            try values.encode(document, forKey: .textDocument)
        case .studySet(let studySet):
            try values.encode(ContentType.studySet, forKey: .type)
            try values.encode(studySet, forKey: .studySet)
        }
    }
}

// MARK: - Canvas elements

public struct CanvasPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct CanvasRect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct RGBAColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public struct TextElement: Codable, Equatable, Sendable {
    public var text: String
    public var fontName: String
    public var fontSize: Double
    public var color: RGBAColor

    public init(text: String, fontName: String = "System", fontSize: Double = 17, color: RGBAColor = .init(red: 0, green: 0, blue: 0)) {
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.color = color
    }
}

public struct ImageElement: Codable, Equatable, Sendable {
    public var assetID: AssetID
    public var contentMode: String

    public init(assetID: AssetID, contentMode: String = "fit") {
        self.assetID = assetID
        self.contentMode = contentMode
    }
}

public struct ShapeElement: Codable, Equatable, Sendable {
    public var shape: String
    public var strokeColor: RGBAColor
    public var fillColor: RGBAColor?
    public var lineWidth: Double

    public init(shape: String, strokeColor: RGBAColor, fillColor: RGBAColor? = nil, lineWidth: Double = 2) {
        self.shape = shape
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.lineWidth = lineWidth
    }
}

public struct ConnectorElement: Codable, Equatable, Sendable {
    public var start: CanvasPoint
    public var end: CanvasPoint
    public var strokeColor: RGBAColor
    public var lineWidth: Double
    public var endCap: String

    public init(start: CanvasPoint, end: CanvasPoint, strokeColor: RGBAColor, lineWidth: Double = 2, endCap: String = "arrow") {
        self.start = start
        self.end = end
        self.strokeColor = strokeColor
        self.lineWidth = lineWidth
        self.endCap = endCap
    }
}

public struct StickyNoteElement: Codable, Equatable, Sendable {
    public var text: String
    public var color: RGBAColor

    public init(text: String = "", color: RGBAColor = .init(red: 1, green: 0.92, blue: 0.45)) {
        self.text = text
        self.color = color
    }
}

public struct TapeElement: Codable, Equatable, Sendable {
    public var color: RGBAColor
    public var isRevealed: Bool

    public init(color: RGBAColor, isRevealed: Bool = false) {
        self.color = color
        self.isRevealed = isRevealed
    }
}

public struct StickerElement: Codable, Equatable, Sendable {
    public var assetID: AssetID
    public var accessibilityLabel: String?

    public init(assetID: AssetID, accessibilityLabel: String? = nil) {
        self.assetID = assetID
        self.accessibilityLabel = accessibilityLabel
    }
}

public struct LinkElement: Codable, Equatable, Sendable {
    public var title: String
    public var destination: URL

    public init(title: String, destination: URL) {
        self.title = title
        self.destination = destination
    }
}

public enum CanvasElementContent: Codable, Equatable, Sendable {
    case text(TextElement)
    case image(ImageElement)
    case shape(ShapeElement)
    case connector(ConnectorElement)
    case stickyNote(StickyNoteElement)
    case tape(TapeElement)
    case sticker(StickerElement)
    case link(LinkElement)
}

public struct CanvasElement: Codable, Equatable, Sendable, Identifiable {
    public var id: ElementID
    public var frame: CanvasRect
    public var rotationRadians: Double
    public var zIndex: Int
    public var isLocked: Bool
    public var opacity: Double
    public var content: CanvasElementContent
    public var createdAt: Date
    public var modifiedAt: Date

    public init(
        id: ElementID = ElementID(),
        frame: CanvasRect,
        rotationRadians: Double = 0,
        zIndex: Int = 0,
        isLocked: Bool = false,
        opacity: Double = 1,
        content: CanvasElementContent,
        createdAt: Date = Date(),
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.frame = frame
        self.rotationRadians = rotationRadians
        self.zIndex = zIndex
        self.isLocked = isLocked
        self.opacity = min(max(opacity, 0), 1)
        self.content = content
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
    }
}

// MARK: - Operations, assets, audio, search, and AI

public enum EditCommandKind: String, Codable, Sendable {
    case createNotebook, renameNotebook, updateMetadata, deleteNotebook
    case addPage, deletePage, reorderPages, updatePageNavigationMetadata
    case saveInk, saveElements, savePageContent, saveHandwritingRecognition, importAsset
    case addAudioSession, updateAudioSession, saveAudioTranscript, deleteAudioSession
    case custom
}

public struct EditCommand: Codable, Equatable, Sendable, Identifiable {
    public var id: OperationID
    public var notebookID: NotebookID
    public var pageID: PageID?
    public var actorID: String
    public var sequence: Int64
    public var timestamp: Date
    public var kind: EditCommandKind
    public var payload: [String: String]

    public init(
        id: OperationID = OperationID(),
        notebookID: NotebookID,
        pageID: PageID? = nil,
        actorID: String = "local",
        sequence: Int64,
        timestamp: Date = Date(),
        kind: EditCommandKind,
        payload: [String: String] = [:]
    ) {
        self.id = id
        self.notebookID = notebookID
        self.pageID = pageID
        self.actorID = actorID
        self.sequence = sequence
        self.timestamp = timestamp
        self.kind = kind
        self.payload = payload
    }
}

public struct AssetDescriptor: Codable, Equatable, Sendable, Identifiable {
    public var id: AssetID
    public var mediaType: String
    public var originalFilename: String?
    public var byteCount: Int64
    public var createdAt: Date

    public init(id: AssetID, mediaType: String, originalFilename: String? = nil, byteCount: Int64, createdAt: Date = Date()) {
        self.id = id
        self.mediaType = mediaType
        self.originalFilename = originalFilename
        self.byteCount = byteCount
        self.createdAt = createdAt
    }
}

public struct AudioSessionDescriptor: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var id: AudioSessionID
    public var createdAt: Date
    public var modifiedAt: Date
    /// The wall-clock instant at which an in-app recording began. This is
    /// intentionally optional so imported and legacy audio remains readable;
    /// `createdAt` is the persistence time and must not be used as a replay zero.
    public var recordingStartedAt: Date?
    public var durationSeconds: Double
    public var chunkFilenames: [String]
    /// Present for schema-v2 sessions and checked by repository validation/recovery.
    public var audioByteCount: Int64?
    /// Lowercase SHA-256 of the single schema-v2 M4A file.
    public var audioSHA256: String?
    /// `nil` is retained only for legacy schema-v1 descriptors.
    public var timelineFilename: String?
    public var transcriptAssetID: AssetID?
    /// Schema-v3 sessions seal an immutable Note Replay event index alongside
    /// the recording and timeline. These fields are an all-or-nothing tuple.
    public var replayFilename: String?
    public var replayByteCount: Int64?
    public var replaySHA256: String?
    public var replayEventCount: Int?

    public init(
        // Constructing an audio descriptor without a replay tuple remains a
        // schema-v2 compatibility operation. New sealed-history ingestion
        // passes schema 3 explicitly after validating all required fields.
        schemaVersion: Int = 2,
        id: AudioSessionID = AudioSessionID(),
        createdAt: Date = Date(),
        modifiedAt: Date? = nil,
        recordingStartedAt: Date? = nil,
        durationSeconds: Double = 0,
        chunkFilenames: [String] = [],
        audioByteCount: Int64? = nil,
        audioSHA256: String? = nil,
        timelineFilename: String? = nil,
        transcriptAssetID: AssetID? = nil,
        replayFilename: String? = nil,
        replayByteCount: Int64? = nil,
        replaySHA256: String? = nil,
        replayEventCount: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.recordingStartedAt = recordingStartedAt
        self.durationSeconds = durationSeconds
        self.chunkFilenames = chunkFilenames
        self.audioByteCount = audioByteCount
        self.audioSHA256 = audioSHA256?.lowercased()
        self.timelineFilename = timelineFilename
        self.transcriptAssetID = transcriptAssetID
        self.replayFilename = replayFilename
        self.replayByteCount = replayByteCount
        self.replaySHA256 = replaySHA256?.lowercased()
        self.replayEventCount = replayEventCount
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, createdAt, modifiedAt, durationSeconds, chunkFilenames
        case recordingStartedAt, audioByteCount, audioSHA256, timelineFilename, transcriptAssetID
        case replayFilename, replayByteCount, replaySHA256, replayEventCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.currentSchemaVersion).contains(decodedSchemaVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported audio-session schema version \(decodedSchemaVersion)."
            )
        }
        schemaVersion = decodedSchemaVersion
        id = try values.decode(AudioSessionID.self, forKey: .id)
        createdAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        modifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
        recordingStartedAt = try values.decodeIfPresent(Date.self, forKey: .recordingStartedAt)
        durationSeconds = try values.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 0
        chunkFilenames = try values.decodeIfPresent([String].self, forKey: .chunkFilenames) ?? []
        audioByteCount = try values.decodeIfPresent(Int64.self, forKey: .audioByteCount)
        audioSHA256 = try values.decodeIfPresent(String.self, forKey: .audioSHA256)?.lowercased()
        timelineFilename = try values.decodeIfPresent(String.self, forKey: .timelineFilename)
        transcriptAssetID = try values.decodeIfPresent(AssetID.self, forKey: .transcriptAssetID)
        replayFilename = try values.decodeIfPresent(String.self, forKey: .replayFilename)
        replayByteCount = try values.decodeIfPresent(Int64.self, forKey: .replayByteCount)
        replaySHA256 = try values.decodeIfPresent(String.self, forKey: .replaySHA256)?.lowercased()
        replayEventCount = try values.decodeIfPresent(Int.self, forKey: .replayEventCount)
    }
}

/// A bounded, versioned transcript stored as a content-addressed notebook asset.
/// The repository performs the authoritative validation against the target audio
/// session and its timeline before this document can be saved or loaded.
public enum AudioTranscriptProvenance: String, Codable, Equatable, Sendable {
    case speechTranscriber
}

public struct AudioTranscriptSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var startTime: TimeInterval
    public var duration: TimeInterval
    public var confidence: Double
    public var timelineMarkID: AudioTimelineMarkID?
    public var operationID: OperationID?
    public var pageID: PageID?

    public init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval,
        duration: TimeInterval,
        confidence: Double,
        timelineMarkID: AudioTimelineMarkID? = nil,
        operationID: OperationID? = nil,
        pageID: PageID? = nil
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.duration = duration
        self.confidence = confidence
        self.timelineMarkID = timelineMarkID
        self.operationID = operationID
        self.pageID = pageID
    }
}

public struct AudioTranscriptDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let mediaType = "application/vnd.notes.audio-transcript+json"
    public static let maximumEncodedBytes = 4 * 1_024 * 1_024
    public static let maximumSegmentCount = 100_000
    public static let maximumLocaleUTF8Bytes = 128
    public static let maximumTextUTF8BytesPerSegment = 256 * 1_024
    public static let maximumTotalTextUTF8Bytes = 3 * 1_024 * 1_024

    public var schemaVersion: Int
    public var audioSessionID: AudioSessionID
    public var localeIdentifier: String
    public var provenance: AudioTranscriptProvenance
    public var generatedAt: Date
    public var segments: [AudioTranscriptSegment]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        audioSessionID: AudioSessionID,
        localeIdentifier: String,
        provenance: AudioTranscriptProvenance,
        generatedAt: Date = Date(),
        segments: [AudioTranscriptSegment]
    ) {
        self.schemaVersion = schemaVersion
        self.audioSessionID = audioSessionID
        self.localeIdentifier = localeIdentifier
        self.provenance = provenance
        self.generatedAt = generatedAt
        self.segments = segments
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, audioSessionID, localeIdentifier, provenance, generatedAt, segments
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        guard decodedSchemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported audio-transcript schema version \(decodedSchemaVersion)."
            )
        }
        let decodedLocale = try values.decode(String.self, forKey: .localeIdentifier)
        guard !decodedLocale.isEmpty,
              decodedLocale.utf8.count <= Self.maximumLocaleUTF8Bytes,
              !decodedLocale.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .localeIdentifier,
                in: values,
                debugDescription: "The audio-transcript locale identifier is invalid."
            )
        }

        var decodedSegments: [AudioTranscriptSegment] = []
        var segmentValues = try values.nestedUnkeyedContainer(forKey: .segments)
        decodedSegments.reserveCapacity(min(segmentValues.count ?? 0, Self.maximumSegmentCount))
        var totalTextBytes = 0
        while !segmentValues.isAtEnd {
            guard decodedSegments.count < Self.maximumSegmentCount else {
                throw DecodingError.dataCorruptedError(
                    forKey: .segments,
                    in: values,
                    debugDescription: "The audio transcript contains too many segments."
                )
            }
            let segment = try segmentValues.decode(AudioTranscriptSegment.self)
            let textBytes = segment.text.utf8.count
            guard textBytes <= Self.maximumTextUTF8BytesPerSegment,
                  totalTextBytes <= Self.maximumTotalTextUTF8Bytes - textBytes else {
                throw DecodingError.dataCorruptedError(
                    forKey: .segments,
                    in: values,
                    debugDescription: "The audio transcript contains too much text."
                )
            }
            totalTextBytes += textBytes
            decodedSegments.append(segment)
        }

        schemaVersion = decodedSchemaVersion
        audioSessionID = try values.decode(AudioSessionID.self, forKey: .audioSessionID)
        localeIdentifier = decodedLocale
        provenance = try values.decode(AudioTranscriptProvenance.self, forKey: .provenance)
        generatedAt = try values.decode(Date.self, forKey: .generatedAt)
        segments = decodedSegments
    }
}

/// A durable association between a repository edit command and recording time.
/// The operation identifier is intentionally stored as a UUID-backed `OperationID`
/// rather than an array offset so marks remain stable when the timeline is edited.
public struct AudioTimelineMark: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: AudioTimelineMarkID
    public var operationID: OperationID
    public var pageID: PageID
    public var timeSeconds: Double
    public var createdAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: AudioTimelineMarkID = AudioTimelineMarkID(),
        operationID: OperationID,
        pageID: PageID,
        timeSeconds: Double,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.operationID = operationID
        self.pageID = pageID
        self.timeSeconds = timeSeconds
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, operationID, pageID, timeSeconds, createdAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard decodedSchemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported audio-timeline-mark schema version \(decodedSchemaVersion)."
            )
        }
        let decodedTime = try values.decode(Double.self, forKey: .timeSeconds)
        guard decodedTime.isFinite, decodedTime >= 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .timeSeconds,
                in: values,
                debugDescription: "An audio timeline mark requires a finite, nonnegative time."
            )
        }
        let decodedCreatedAt = try values.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        guard decodedCreatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .createdAt,
                in: values,
                debugDescription: "An audio timeline mark requires a finite creation date."
            )
        }
        schemaVersion = decodedSchemaVersion
        id = try values.decode(AudioTimelineMarkID.self, forKey: .id)
        operationID = try values.decode(OperationID.self, forKey: .operationID)
        pageID = try values.decode(PageID.self, forKey: .pageID)
        timeSeconds = decodedTime
        createdAt = decodedCreatedAt
    }
}

/// Versioned contents of `audio/<session-id>.timeline.json`.
public struct AudioTimelineDocument: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var audioSessionID: AudioSessionID
    public var marks: [AudioTimelineMark]
    public var modifiedAt: Date

    public var id: AudioSessionID { audioSessionID }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        audioSessionID: AudioSessionID,
        marks: [AudioTimelineMark] = [],
        modifiedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.audioSessionID = audioSessionID
        self.marks = marks
        self.modifiedAt = modifiedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, audioSessionID, marks, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard decodedSchemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported audio-timeline schema version \(decodedSchemaVersion)."
            )
        }
        let decodedModifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? .distantPast
        guard decodedModifiedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .modifiedAt,
                in: values,
                debugDescription: "An audio timeline requires a finite modification date."
            )
        }
        schemaVersion = decodedSchemaVersion
        audioSessionID = try values.decode(AudioSessionID.self, forKey: .audioSessionID)
        marks = try values.decodeIfPresent([AudioTimelineMark].self, forKey: .marks) ?? []
        modifiedAt = decodedModifiedAt
    }
}

public enum SearchSegmentSource: String, Codable, Sendable {
    case typedText, pdfText, opticalCharacterRecognition, transcript, outline
}

public struct SearchSegment: Codable, Equatable, Sendable, Identifiable {
    public var id: SearchSegmentID
    public var notebookID: NotebookID
    public var pageID: PageID?
    public var source: SearchSegmentSource
    public var text: String
    public var rangeHint: String?
    public var audioTimeSeconds: Double?

    public init(
        id: SearchSegmentID = SearchSegmentID(),
        notebookID: NotebookID,
        pageID: PageID? = nil,
        source: SearchSegmentSource,
        text: String,
        rangeHint: String? = nil,
        audioTimeSeconds: Double? = nil
    ) {
        self.id = id
        self.notebookID = notebookID
        self.pageID = pageID
        self.source = source
        self.text = text
        self.rangeHint = rangeHint
        self.audioTimeSeconds = audioTimeSeconds
    }
}

public enum AIArtifactKind: String, Codable, Sendable {
    case answer, summary, rewrite, quiz, outline, meetingNotes, template, diagram, mathExplanation
}

public struct AIArtifact: Codable, Equatable, Sendable, Identifiable {
    public var id: AIArtifactID
    public var notebookID: NotebookID
    public var pageID: PageID?
    public var kind: AIArtifactKind
    public var content: String
    public var sourceSegmentIDs: [SearchSegmentID]
    public var modelIdentifier: String
    public var createdAt: Date

    public init(
        id: AIArtifactID = AIArtifactID(),
        notebookID: NotebookID,
        pageID: PageID? = nil,
        kind: AIArtifactKind,
        content: String,
        sourceSegmentIDs: [SearchSegmentID] = [],
        modelIdentifier: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.notebookID = notebookID
        self.pageID = pageID
        self.kind = kind
        self.content = content
        self.sourceSegmentIDs = sourceSegmentIDs
        self.modelIdentifier = modelIdentifier
        self.createdAt = createdAt
    }
}
