import NextStepAcademic
import SwiftUI

struct SessionWorkspaceView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var academicModel: AcademicAppModel

    let route: SessionWorkspaceRoute

    private var notebook: LibraryNotebook? {
        appModel.notebooks.first { $0.id == route.notebookID }
    }

    private var session: CourseSession? {
        academicModel.workspace.sessions.first { $0.id == route.sessionID }
    }

    var body: some View {
        Group {
            if let notebook, notebook.deletedAt == nil {
                NotebookEditorView(
                    notebookSummary: notebook,
                    initialPageID: route.initialPageID,
                    academicCaptureContext: AcademicSessionCaptureContext(
                        route: route
                    )
                )
                .id(route.sessionID)
            } else {
                ContentUnavailableView {
                    Label("Class note unavailable", systemImage: "doc.badge.exclamationmark")
                } description: {
                    Text("Return to the course and retry preparing this session's note.")
                }
                .accessibilityIdentifier("session.note.unavailable")
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let session {
                    Label(statusTitle(for: session.status), systemImage: statusSymbol(for: session.status))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("session.status")
                }
            }
        }
        .accessibilityIdentifier("session.workspace")
    }

    private func statusTitle(for status: CourseSessionStatus) -> String {
        switch status {
        case .planned:
            String(localized: "Preparing")
        case .active:
            String(localized: "In progress")
        case .needsReview:
            String(localized: "Needs review")
        case .reviewed:
            String(localized: "Reviewed")
        case .cancelled:
            String(localized: "Cancelled")
        }
    }

    private func statusSymbol(for status: CourseSessionStatus) -> String {
        switch status {
        case .planned: "clock"
        case .active: "record.circle"
        case .needsReview: "checklist"
        case .reviewed: "checkmark.circle"
        case .cancelled: "xmark.circle"
        }
    }
}
