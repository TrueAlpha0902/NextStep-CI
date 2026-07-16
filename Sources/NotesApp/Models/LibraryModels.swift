import Foundation
import NotesCore

enum LibraryDestination: String, CaseIterable, Identifiable, Hashable {
    case courses
    case documents
    case favorites
    case trash
    case settings

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .courses: "Courses"
        case .documents: "Documents"
        case .favorites: "Favorites"
        case .trash: "Trash"
        case .settings: "Settings"
        }
    }

    var symbolName: String {
        switch self {
        case .courses: "book.closed.fill"
        case .documents: "doc.on.doc"
        case .favorites: "star"
        case .trash: "trash"
        case .settings: "gearshape"
        }
    }
}

enum LibraryDisplayMode: String, CaseIterable, Identifiable, Hashable {
    case grid
    case list

    var id: Self { self }
}

enum LibrarySortOrder: String, CaseIterable, Identifiable, Hashable {
    case modified
    case created
    case title

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .modified: "Last modified"
        case .created: "Date created"
        case .title: "Title"
        }
    }
}

enum NotebookKind: String, CaseIterable, Codable, Identifiable, Sendable, Hashable {
    case notebook
    case quickNote
    case whiteboard
    case textDocument
    case studySet
    case pdf
    case image

    var id: Self { self }

    static let creatableKinds: [NotebookKind] = [
        .notebook,
        .whiteboard,
        .textDocument,
        .studySet,
    ]

    var title: LocalizedStringResource {
        switch self {
        case .notebook: "Notebook"
        case .quickNote: "Quick Note"
        case .whiteboard: "Whiteboard"
        case .textDocument: "Text document"
        case .studySet: "Study set"
        case .pdf: "PDF"
        case .image: "Image"
        }
    }

    var symbolName: String {
        switch self {
        case .notebook: "book.closed"
        case .quickNote: "bolt.fill"
        case .whiteboard: "scribble.variable"
        case .textDocument: "doc.text"
        case .studySet: "rectangle.stack"
        case .pdf: "doc.richtext"
        case .image: "photo"
        }
    }

    var corePageKind: NotesCore.PageKind {
        switch self {
        case .notebook, .quickNote: .notebook
        case .whiteboard: .whiteboard
        case .textDocument: .textDocument
        case .studySet: .studySet
        case .pdf, .image: .importedDocument
        }
    }

    var supportsInkEditor: Bool {
        switch self {
        case .textDocument, .studySet: false
        case .notebook, .quickNote, .whiteboard, .pdf, .image: true
        }
    }
}

enum PaperTemplate: String, CaseIterable, Codable, Identifiable, Sendable, Hashable {
    case blank
    case ruled
    case grid
    case dots

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .blank: "Blank"
        case .ruled: "Ruled"
        case .grid: "Grid"
        case .dots: "Dotted"
        }
    }

    var symbolName: String {
        switch self {
        case .blank: "square"
        case .ruled: "line.3.horizontal"
        case .grid: "grid"
        case .dots: "circle.grid.3x3"
        }
    }
}

enum PageBackground: Codable, Hashable, Sendable {
    case paper(PaperTemplate)
    case pdf(assetPath: String, pageIndex: Int)
    case image(assetPath: String)
}

struct EditorPage: Codable, Hashable, Identifiable, Sendable {
    static let whiteboardWidth = 3_200.0
    static let whiteboardHeight = 2_400.0

    var id: UUID
    var kind: NotesCore.PageKind
    var modifiedAt: Date
    var background: PageBackground
    var width: Double
    var height: Double
    var inkPath: String
    var isBookmarked: Bool
    var outlineTitle: String?

    init(
        id: UUID = UUID(),
        kind: NotesCore.PageKind = .notebook,
        modifiedAt: Date = Date(),
        background: PageBackground = .paper(.blank),
        width: Double = 768,
        height: Double = 1_024,
        inkPath: String? = nil,
        isBookmarked: Bool = false,
        outlineTitle: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.modifiedAt = modifiedAt
        self.background = background
        self.width = width
        self.height = height
        self.inkPath = inkPath ?? "pages/\(id.uuidString.lowercased())/ink.data"
        self.isBookmarked = isBookmarked
        self.outlineTitle = outlineTitle
    }

    static func newPage(for notebookKind: NotebookKind, template: PaperTemplate = .blank) -> EditorPage {
        if notebookKind == .whiteboard {
            return EditorPage(
                kind: .whiteboard,
                background: .paper(.dots),
                width: whiteboardWidth,
                height: whiteboardHeight
            )
        }
        return EditorPage(
            kind: notebookKind.corePageKind,
            background: .paper(template)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, modifiedAt, background, width, height, inkPath
        case isBookmarked, outlineTitle
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        background = try values.decodeIfPresent(PageBackground.self, forKey: .background) ?? .paper(.blank)
        kind = try values.decodeIfPresent(NotesCore.PageKind.self, forKey: .kind)
            ?? background.inferredCorePageKind
        // Older App-side payloads never stored a page timestamp. A sentinel is
        // preferable to inventing a recent edit and disturbing modification sort.
        modifiedAt = try values.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? .distantPast
        width = try values.decodeIfPresent(Double.self, forKey: .width) ?? 768
        height = try values.decodeIfPresent(Double.self, forKey: .height) ?? 1_024
        inkPath = try values.decodeIfPresent(String.self, forKey: .inkPath)
            ?? "pages/\(id.uuidString.lowercased())/ink.data"
        isBookmarked = try values.decodeIfPresent(Bool.self, forKey: .isBookmarked) ?? false
        outlineTitle = try values.decodeIfPresent(String.self, forKey: .outlineTitle)
    }
}

private extension PageBackground {
    var inferredCorePageKind: NotesCore.PageKind {
        switch self {
        case .paper: .notebook
        case .pdf, .image: .importedDocument
        }
    }
}

struct LibraryNotebook: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var kind: NotebookKind
    var createdAt: Date
    var modifiedAt: Date
    var isFavorite: Bool
    var deletedAt: Date?
    var pageCount: Int
    var coverHue: Double
}

struct EditorNotebook: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var kind: NotebookKind
    var createdAt: Date
    var modifiedAt: Date
    var isFavorite: Bool
    var deletedAt: Date?
    var coverHue: Double
    var pages: [EditorPage]

    var summary: LibraryNotebook {
        LibraryNotebook(
            id: id,
            title: title,
            kind: kind,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            isFavorite: isFavorite,
            deletedAt: deletedAt,
            pageCount: pages.count,
            coverHue: coverHue
        )
    }
}

struct ResolvedPageBackground: Equatable, Sendable {
    var background: PageBackground
    var assetURL: URL?
    /// Owned, descriptor-bounded snapshot used by export. Interactive previews intentionally use
    /// `assetURL`; production PDF export supplies this buffer and never reopens that URL.
    var assetData: Data?

    init(background: PageBackground, assetURL: URL?, assetData: Data? = nil) {
        self.background = background
        self.assetURL = assetURL
        self.assetData = assetData
    }
}

struct AppNotice: Identifiable, Equatable {
    enum Kind: Equatable {
        case information
        case error
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var message: String
}

enum DrawingTool: String, CaseIterable, Identifiable, Hashable {
    case pen
    case highlighter
    case eraser
    case lasso

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .lasso: "Lasso"
        }
    }

    var symbolName: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        }
    }
}

enum InkColor: String, CaseIterable, Identifiable, Hashable {
    case black
    case blue
    case red
    case green

    var id: Self { self }
}

enum CanvasCommand: Equatable {
    case undo
    case redo
    case clear
}

struct CanvasCommandRequest: Equatable {
    let id = UUID()
    let command: CanvasCommand
}
