import Foundation
import NotesCore
import NotesServices
import XCTest
@testable import NotesApp

@MainActor
final class SessionTextNoteTests: XCTestCase {
    func testEnsureCreatesExactEmptyTextNoteAndIsIdempotent() async throws {
        let base = temporaryBase(named: "Exact")
        let suiteName = "NotesAppTests.SessionTextNote.Exact.\(UUID().uuidString)"
        defer { cleanup(base: base, suiteName: suiteName) }
        let store = LocalNotebookStore(
            userDefaultsSuiteName: suiteName,
            overrideRoot: base
        )
        let request = makeRequest()

        let first = try await store.ensureSessionTextNote(request)
        let second = try await store.ensureSessionTextNote(request)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.id, request.notebookID)
        XCTAssertEqual(first.title, request.title)
        XCTAssertEqual(first.kind, .textDocument)
        XCTAssertNil(first.deletedAt)
        XCTAssertEqual(first.createdAt, request.createdAt)
        XCTAssertEqual(first.pages.map(\.id), [request.initialPageID])
        XCTAssertEqual(first.pages.first?.kind, .textDocument)
        let initialContent = try await store.loadPageContent(
            notebookID: request.notebookID,
            pageID: request.initialPageID
        )
        XCTAssertEqual(
            initialContent,
            .textDocument(TextDocument())
        )

        let libraryRoot = try await store.libraryDirectoryURL()
        let inspection = try FileNotebookRepository(rootURL: libraryRoot)
        let operations = try await inspection.operationLog(
            notebookID: NotebookID(request.notebookID)
        )
        XCTAssertEqual(
            operations.map(\.kind),
            [.createNotebook]
        )
    }

    func testEnsureRepairsMissingMetadataForExactExistingPackage() async throws {
        let base = temporaryBase(named: "MetadataRepair")
        let suiteName = "NotesAppTests.SessionTextNote.Repair.\(UUID().uuidString)"
        defer { cleanup(base: base, suiteName: suiteName) }
        let request = makeRequest()
        let libraryRoot = base.appendingPathComponent("Notes", isDirectory: true)
        let repository = try FileNotebookRepository(rootURL: libraryRoot)
        let page = PageDescriptor(
            id: PageID(request.initialPageID),
            kind: .textDocument,
            createdAt: request.createdAt,
            modifiedAt: request.createdAt,
            size: PageSize(width: 768, height: 1_024),
            background: .plain(colorHex: "#FFFFFF")
        )
        _ = try await repository.createNotebook(
            id: NotebookID(request.notebookID),
            title: request.title,
            initialPage: page,
            createdAt: request.createdAt
        )

        let store = LocalNotebookStore(
            userDefaultsSuiteName: suiteName,
            overrideRoot: base
        )
        let ensured = try await store.ensureSessionTextNote(request)

        XCTAssertEqual(ensured.id, request.notebookID)
        XCTAssertEqual(ensured.kind, .textDocument)
        XCTAssertNil(ensured.deletedAt)
        let metadataData = try Data(
            contentsOf: libraryRoot.appendingPathComponent(
                ".notes-ui-metadata.json",
                isDirectory: false
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: metadataData) as? [String: Any]
        )
        let notebooks = try XCTUnwrap(object["notebooks"] as? [String: Any])
        let entry = try XCTUnwrap(
            notebooks[NotebookID(request.notebookID).description] as? [String: Any]
        )
        XCTAssertEqual(entry["kind"] as? String, "textDocument")
        XCTAssertNil(entry["deletedAt"])
    }

    func testEnsureAcceptsTitleChangesButRejectsPageAndTrashConflicts() async throws {
        let base = temporaryBase(named: "Conflicts")
        let suiteName = "NotesAppTests.SessionTextNote.Conflict.\(UUID().uuidString)"
        defer { cleanup(base: base, suiteName: suiteName) }
        let store = LocalNotebookStore(
            userDefaultsSuiteName: suiteName,
            overrideRoot: base
        )
        let request = makeRequest()
        _ = try await store.ensureSessionTextNote(request)

        let replayedWithAnotherTitle = try await store.ensureSessionTextNote(
            SessionTextNoteRequest(
                notebookID: request.notebookID,
                initialPageID: request.initialPageID,
                title: "Another lecture",
                createdAt: request.createdAt
            )
        )
        XCTAssertEqual(replayedWithAnotherTitle.title, request.title)

        do {
            _ = try await store.ensureSessionTextNote(
                SessionTextNoteRequest(
                    notebookID: request.notebookID,
                    initialPageID: UUID(),
                    title: request.title,
                    createdAt: request.createdAt
                )
            )
            XCTFail("A missing reserved initial page must conflict.")
        } catch let error as SessionTextNoteStoreError {
            XCTAssertEqual(error, .initialPageConflict)
        }

        try await store.deleteNotebook(id: request.notebookID, permanently: false)
        do {
            _ = try await store.ensureSessionTextNote(request)
            XCTFail("Ensure must not silently restore a trashed note.")
        } catch let error as SessionTextNoteStoreError {
            XCTAssertEqual(error, .metadataConflict)
        }
    }

    func testAppModelEnsurePublishesOneDeterministicSummary() async throws {
        let base = temporaryBase(named: "AppModel")
        let suiteName = "NotesAppTests.SessionTextNote.AppModel.\(UUID().uuidString)"
        defer { cleanup(base: base, suiteName: suiteName) }
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let store = LocalNotebookStore(
            userDefaultsSuiteName: suiteName,
            overrideRoot: base
        )
        let model = AppModel(
            store: store,
            searchIndex: LocalSearchIndex(persistenceURL: nil),
            preferences: preferences
        )
        let request = makeRequest()

        let firstResult = await model.ensureSessionTextNote(request)
        let secondResult = await model.ensureSessionTextNote(request)
        let first = try XCTUnwrap(firstResult)
        let second = try XCTUnwrap(secondResult)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.notebook.id, request.notebookID)
        XCTAssertEqual(first.initialPageID, request.initialPageID)
        XCTAssertEqual(model.notebooks, [first.notebook])
        XCTAssertNil(model.notice)
    }

    private func makeRequest() -> SessionTextNoteRequest {
        SessionTextNoteRequest(
            notebookID: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            initialPageID: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
            title: "Algorithms — Lecture 1",
            createdAt: Date(timeIntervalSinceReferenceDate: 50_000.125)
        )
    }

    private func temporaryBase(named name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "SessionTextNote-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func cleanup(base: URL, suiteName: String) {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(
            forName: suiteName
        )
        try? FileManager.default.removeItem(at: base)
    }
}
