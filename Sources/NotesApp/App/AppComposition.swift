import Foundation
import NextStepAcademic

extension LocalNotebookStore {
    /// Creates the single physical store used by both Notes and the academic
    /// workspace for this process. UI tests retain their isolated, optionally
    /// delayed library while production uses the normal Files-backed root.
    static func makeForCurrentProcess(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> LocalNotebookStore {
        guard arguments.contains("-ui-testing") else {
            return LocalNotebookStore()
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesUITests", isDirectory: true)
        if arguments.contains("-ui-testing-reset-library") {
            try? FileManager.default.removeItem(at: root)
        }
        // Academic and Notes bootstrap in independent view tasks. Recreate
        // the selected parent before either task starts so the read-only
        // academic load cannot lose a race with Notes repository creation.
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return LocalNotebookStore(
            overrideRoot: root,
            libraryLoadReturnDelay: arguments.contains("-ui-testing-slow-bootstrap")
                ? .milliseconds(750)
                : .zero
        )
    }
}

@MainActor
struct AppComposition {
    let notes: AppModel
    let academic: AcademicAppModel

    static func live() -> AppComposition {
        let diskStore = LocalNotebookStore.makeForCurrentProcess()
        let academic = AcademicAppModel(
            store: NextStepAcademicStore(backing: diskStore)
        )
        let notes = AppModel(
            store: diskStore,
            academicRootCoordinator: academic
        )
        // The production app is Course-centric while AppModel's standalone
        // default remains Documents for focused Notes tests and adapters.
        notes.destination = .courses
        return AppComposition(notes: notes, academic: academic)
    }
}
