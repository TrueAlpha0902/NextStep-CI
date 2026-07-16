import Foundation
import XCTest
@testable import NotesApp

final class NotebookPackageImportTests: XCTestCase {
    func testExportedPackageCanBeImportedWithRepositoryDateEncoding() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesPackageImportTests-\(UUID().uuidString)", isDirectory: true)
        let sourceRoot = root.appendingPathComponent("Source", isDirectory: true)
        let destinationRoot = root.appendingPathComponent("Destination", isDirectory: true)
        let sourceStore = LocalNotebookStore(overrideRoot: sourceRoot)
        let destinationStore = LocalNotebookStore(overrideRoot: destinationRoot)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let created = try await sourceStore.createNotebook(
            title: "Portable",
            kind: .notebook,
            template: .grid
        )
        let snapshot = try await sourceStore.packageURL(notebookID: created.id)
        addTeardownBlock { try? FileManager.default.removeItem(at: snapshot) }

        let imported = try await destinationStore.importDocument(at: snapshot)

        XCTAssertEqual(imported.id, created.id)
        XCTAssertEqual(imported.title, created.title)
        XCTAssertEqual(imported.pages.map(\.id), created.pages.map(\.id))
    }
}
