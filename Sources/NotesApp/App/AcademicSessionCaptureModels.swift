import Foundation
import NextStepAcademic
import NotesCore

enum AcademicSessionCaptureValidationError: Error, Equatable, Sendable {
    case courseUnavailable
    case sessionUnavailable
    case noteMismatch
    case noteLinkUnavailable
}

extension AcademicSessionCaptureValidationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .courseUnavailable:
            String(localized: "This course is no longer active.")
        case .sessionUnavailable:
            String(localized: "This class session is no longer in progress.")
        case .noteMismatch:
            String(localized: "This note no longer belongs to the active class session.")
        case .noteLinkUnavailable:
            String(localized: "The class note link is no longer active.")
        }
    }
}

enum AcademicSessionCaptureValidation {
    static func validate(
        _ context: AcademicSessionCaptureContext,
        openNotebookID: UUID,
        at timestamp: Date,
        in workspace: AcademicWorkspace
    ) throws {
        guard context.noteID.rawValue == openNotebookID else {
            throw AcademicSessionCaptureValidationError.noteMismatch
        }
        guard workspace.courses.contains(where: {
            $0.id == context.courseID && $0.status == .active
        }) else {
            throw AcademicSessionCaptureValidationError.courseUnavailable
        }
        guard workspace.sessions.contains(where: {
            $0.id == context.sessionID
                && $0.courseID == context.courseID
                && $0.status == .active
        }) else {
            throw AcademicSessionCaptureValidationError.sessionUnavailable
        }
        guard workspace.sessionNoteLinks.contains(where: { link in
            guard link.sessionID == context.sessionID,
                  link.noteID == context.noteID,
                  link.linkedAt <= timestamp else { return false }
            return link.unlinkedAt.map { timestamp < $0 } ?? true
        }) else {
            throw AcademicSessionCaptureValidationError.noteLinkUnavailable
        }
    }

    static func markerKindsByBlock(
        for context: AcademicSessionCaptureContext,
        pageID: PageID,
        in workspace: AcademicWorkspace
    ) -> [TextBlockID: Set<CaptureKind>] {
        workspace.captures.reduce(into: [:]) { result, capture in
            guard capture.courseID == context.courseID,
                  capture.sessionID == context.sessionID,
                  case let .noteAnchor(anchor) = capture.source,
                  anchor.noteID == context.noteID,
                  anchor.pageID == pageID else { return }
            result[anchor.blockID, default: []].insert(capture.kind)
        }
    }
}

struct AcademicTextCaptureRequest: Equatable, Sendable {
    let captureID: CaptureItemID
    let sourceAnchorID: SourceAnchorID
    let auditID: CaptureAuditEntryID
    let kind: CaptureKind
    let capturedAt: Date
    let context: AcademicSessionCaptureContext
    let notebookID: UUID
    let pageID: UUID
    let blockID: TextBlockID
    let editorSession: EditorSessionLease
}

struct PendingAcademicTextCapture: Equatable, Sendable {
    let request: AcademicTextCaptureRequest
    let capture: CaptureItem
}
