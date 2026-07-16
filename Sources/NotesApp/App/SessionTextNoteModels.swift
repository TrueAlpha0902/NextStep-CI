import Foundation

/// Deterministic Notes-side identity reserved by one CourseSession start saga.
///
/// The request is safe to retain and replay after an ambiguous create result;
/// storage must either return this exact note/page or fail with a conflict.
struct SessionTextNoteRequest: Equatable, Sendable {
    let notebookID: UUID
    let initialPageID: UUID
    let title: String
    let createdAt: Date

    init(
        notebookID: UUID,
        initialPageID: UUID,
        title: String,
        createdAt: Date
    ) {
        self.notebookID = notebookID
        self.initialPageID = initialPageID
        self.title = title
        self.createdAt = createdAt
    }
}

struct CreatedSessionTextNote: Equatable, Sendable {
    let notebook: LibraryNotebook
    let initialPageID: UUID
}

/// Narrow capability used by Session start without exposing the rest of the
/// Notes persistence surface to its coordinator.
protocol SessionTextNoteStoring: Sendable {
    func ensureSessionTextNote(
        _ request: SessionTextNoteRequest
    ) async throws -> EditorNotebook
}

enum SessionTextNoteStoreError: Error, Equatable, Sendable {
    case invalidRequest
    case notebookConflict
    case initialPageConflict
    case metadataConflict
    case unsupportedStore
}

extension SessionTextNoteStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "The class-session note request is invalid."
        case .notebookConflict:
            "An existing note conflicts with this class-session request."
        case .initialPageConflict:
            "The class-session note does not contain the requested text page."
        case .metadataConflict:
            "The class-session note has conflicting library metadata."
        case .unsupportedStore:
            "The selected note library cannot create class-session notes."
        }
    }
}
