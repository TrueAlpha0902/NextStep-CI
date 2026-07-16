import Foundation
import NextStepAcademic
import NotesCore

struct SessionWorkspaceRoute: Hashable, Identifiable, Sendable {
    let courseID: CourseID
    let sessionID: CourseSessionID
    let notebookID: UUID
    let initialPageID: UUID

    var id: CourseSessionID { sessionID }
}

/// Explicit authority carried only by a Course Session note editor. Ordinary
/// Documents never receive this value and therefore cannot create a
/// session-scoped academic capture accidentally.
struct AcademicSessionCaptureContext: Equatable, Hashable, Sendable {
    let courseID: CourseID
    let sessionID: CourseSessionID
    let noteID: NotebookID

    init(
        courseID: CourseID,
        sessionID: CourseSessionID,
        noteID: NotebookID
    ) {
        self.courseID = courseID
        self.sessionID = sessionID
        self.noteID = noteID
    }

    init(route: SessionWorkspaceRoute) {
        self.init(
            courseID: route.courseID,
            sessionID: route.sessionID,
            noteID: NotebookID(route.notebookID)
        )
    }
}

struct PendingSessionStart: Equatable, Identifiable, Sendable {
    let session: CourseSession
    let link: SessionNoteLink

    var id: CourseSessionID { session.id }
    var courseID: CourseID { session.courseID }

    var route: SessionWorkspaceRoute? {
        guard let initialPageID = link.initialPageID?.rawValue else { return nil }
        return SessionWorkspaceRoute(
            courseID: session.courseID,
            sessionID: session.id,
            notebookID: link.noteID.rawValue,
            initialPageID: initialPageID
        )
    }

    func noteRequest(title: String) -> SessionTextNoteRequest? {
        guard let initialPageID = link.initialPageID?.rawValue else { return nil }
        return SessionTextNoteRequest(
            notebookID: link.noteID.rawValue,
            initialPageID: initialPageID,
            title: title,
            createdAt: session.createdAt
        )
    }
}

enum SessionStartProgress: Equatable, Sendable {
    case preparingSession
    case creatingNote
    case activatingSession
}

enum SessionStartState: Equatable, Sendable {
    case idle
    case working(courseID: CourseID, progress: SessionStartProgress)
    case recoveryRequired(PendingSessionStart, AcademicWorkspaceFailure)
}

enum SessionStartOutcome: Equatable, Sendable {
    case started(SessionWorkspaceRoute)
    case recoveryRequired(PendingSessionStart)
    case failed(AcademicWorkspaceFailure)
}

typealias SessionTextNoteEnsurer = @MainActor @Sendable (
    SessionTextNoteRequest
) async -> CreatedSessionTextNote?
