import Dispatch
import Foundation
import ImageIO
import NotesCore
import NotesServices
import PencilKit
@testable import NotesApp
import XCTest

final class AppModelConsistencyTests: XCTestCase {
    @MainActor
    func testNotebookContentSearchForwardsNotebookScope() async throws {
        let notebook = makeNotebook(title: "Search scope")
        let pageID = try XCTUnwrap(notebook.pages.first?.id)
        let segment = RecognizedTextSegment(
            text: "Focused result",
            pageID: pageID,
            source: .typedText
        )
        let expectedHit = LocalSearchSegmentHit(
            documentID: UUID(),
            notebookID: notebook.id,
            pageID: pageID,
            title: notebook.title,
            snippet: segment.text,
            score: 7.5,
            segment: segment
        )
        let search = SearchIndexSpy(segmentQueryResponse: [expectedHit])
        let model = AppModel(
            store: ControlledNotebookStore(initialNotebooks: [notebook]),
            searchIndex: search
        )

        let hits = await model.searchNotebookContent(
            "  Focused result  ",
            notebookID: notebook.id,
            limit: 37
        )

        XCTAssertEqual(hits, [expectedHit])
        let request = await search.lastSegmentQuery
        XCTAssertEqual(request?.text, "Focused result")
        XCTAssertEqual(request?.notebookID, notebook.id)
        XCTAssertEqual(request?.limit, 37)
    }

    @MainActor
    func testConcurrentCreateAndImportWaitForSlowBootstrapSnapshot() async throws {
        let existing = makeNotebook(title: "Existing")
        let store = ControlledNotebookStore(
            initialNotebooks: [existing],
            blocksInitialLoad: true
        )
        let search = SearchIndexSpy()
        let model = AppModel(store: store, searchIndex: search)

        let loadTask = Task { @MainActor in await model.load() }
        let didCaptureSnapshot = await waitUntil { await store.hasCapturedInitialLoad }
        XCTAssertTrue(didCaptureSnapshot)

        let createTask = Task { @MainActor in
            await model.createNotebook(title: "Created while loading")
        }
        let importTask = Task { @MainActor in
            await model.importDocuments([URL(fileURLWithPath: "/tmp/Imported.pdf")])
        }

        try await Task.sleep(for: .milliseconds(50))
        let mutationsBeforeRelease = await store.mutationCount
        XCTAssertEqual(mutationsBeforeRelease, 0, "Mutations must wait for bootstrap to finish.")

        await store.releaseInitialLoad()
        await loadTask.value
        let created = await createTask.value
        let imported = await importTask.value

        XCTAssertNotNil(created)
        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(Set(model.notebooks.map(\.title)), Set([
            "Existing",
            "Created while loading",
            "Imported",
        ]))
    }

    @MainActor
    func testDeletingPageRemovesItsSearchDocument() async throws {
        var notebook = makeNotebook(title: "Indexed", pageCount: 2)
        let removedPageID = try XCTUnwrap(notebook.pages.last?.id)
        notebook.pages[1].outlineTitle = "Disposable outline"
        notebook.pages[1].isBookmarked = true
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let search = SearchIndexSpy(documents: [
            SearchIndexDocument(
                id: removedPageID,
                notebookID: notebook.id,
                pageID: removedPageID,
                title: notebook.title,
                revision: 1,
                segments: [
                    RecognizedTextSegment(
                        text: "searchable page",
                        pageID: removedPageID,
                        source: .typedText
                    ),
                ]
            ),
        ])
        let model = AppModel(store: store, searchIndex: search)
        await model.load()

        let updated = await model.deletePageForTesting(
            from: notebook,
            pageID: removedPageID
        )

        XCTAssertEqual(updated?.pages.count, 1)
        let removedIDs = await search.removedDocumentIDs
        XCTAssertTrue(removedIDs.contains(removedPageID))
        XCTAssertTrue(removedIDs.contains(
            CanvasElementSearchBuilder.documentID(
                notebookID: notebook.id,
                pageID: removedPageID
            )
        ))
        XCTAssertTrue(removedIDs.contains(
            HandwritingSearchBuilder.documentID(
                notebookID: notebook.id,
                pageID: removedPageID
            )
        ))
        let navigationDocumentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: removedPageID
        )
        XCTAssertTrue(removedIDs.contains(navigationDocumentID))
        let stillIndexed = await search.contains(documentID: removedPageID)
        XCTAssertFalse(stillIndexed)
        let navigationStillIndexed = await search.contains(
            documentID: navigationDocumentID
        )
        XCTAssertFalse(navigationStillIndexed)
    }

    @MainActor
    func testDuplicateInkFailureRollsBackCommittedPage() async throws {
        let notebook = makeNotebook(title: "Rollback")
        let page = try XCTUnwrap(notebook.pages.first)
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            duplicateFailure: .inkWrite
        )
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()

        let result = await model.duplicatePageForTesting(in: notebook, page: page)

        XCTAssertNil(result)
        let persistedValue = await store.persistedNotebook(id: notebook.id)
        let persisted = try XCTUnwrap(persistedValue)
        XCTAssertEqual(persisted.pages.map(\.id), notebook.pages.map(\.id))
        let savedPageSequences = await store.savedPageIDSequences
        XCTAssertEqual(savedPageSequences.count, 1)
        let removedPageIDs = await store.deletedPageIDs
        XCTAssertEqual(removedPageIDs.count, 1)
        XCTAssertNotNil(model.notice)
    }

    @MainActor
    func testDuplicateReloadsCommittedStateWhenInkAndRollbackFail() async throws {
        let notebook = makeNotebook(title: "Reload")
        let page = try XCTUnwrap(notebook.pages.first)
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            duplicateFailure: .inkWriteAndRollback
        )
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()

        let result = await model.duplicatePageForTesting(in: notebook, page: page)

        let committed = try XCTUnwrap(result?.0)
        let duplicateID = try XCTUnwrap(result?.1)
        XCTAssertEqual(committed.pages.count, 2)
        XCTAssertTrue(committed.pages.contains(where: { $0.id == duplicateID }))
        let persistedValue = await store.persistedNotebook(id: notebook.id)
        let persisted = try XCTUnwrap(persistedValue)
        XCTAssertEqual(persisted.pages.map(\.id), committed.pages.map(\.id))
        XCTAssertNotNil(model.notice)
    }

    @MainActor
    func testBootstrapAdvancesPersistedRevisionBeforeReplacingIndexedTitle() async throws {
        let notebook = makeNotebook(title: "Current title")
        let persistedRevision = 2_000_000_000_000_000
        let search = SearchIndexSpy(documents: [
            SearchIndexDocument(
                id: notebook.id,
                notebookID: notebook.id,
                title: "Previous title",
                revision: persistedRevision,
                segments: []
            ),
        ])
        let model = AppModel(
            store: ControlledNotebookStore(initialNotebooks: [notebook]),
            searchIndex: search
        )

        await model.load()

        let indexed = await search.document(id: notebook.id)
        XCTAssertEqual(indexed?.title, notebook.title)
        XCTAssertEqual(indexed?.revision, persistedRevision + 1)
    }

    @MainActor
    func testPackageSnapshotFlushesLatestStagedInkBeforeExport() async throws {
        let notebook = makeNotebook(title: "Snapshot")
        let page = try XCTUnwrap(notebook.pages.first)
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()

        model.stageInkForTesting(Data([0x01, 0x02, 0x03]), notebookID: notebook.id, page: page)
        let exported = await model.packageURL(for: notebook.summary)

        XCTAssertNotNil(exported)
        let events = await store.persistenceEvents
        XCTAssertEqual(events, ["saveInk", "packageURL"])
    }

    @MainActor
    func testFailedInkFlushRetainsLatestPayloadForRetry() async throws {
        let notebook = makeNotebook(title: "Retry")
        let page = try XCTUnwrap(notebook.pages.first)
        let payload = Data([0xCA, 0xFE])
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            transientInkFailures: 1
        )
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()

        model.stageInkForTesting(payload, notebookID: notebook.id, page: page)
        let first = await model.flushInk(notebookID: notebook.id, pageID: page.id)
        let second = await model.flushInk(notebookID: notebook.id, pageID: page.id)
        let savedPayloads = await store.savedInkPayloads

        XCTAssertFalse(first)
        XCTAssertTrue(second)
        XCTAssertEqual(savedPayloads, [payload])
        XCTAssertEqual(model.inkSaveState(notebookID: notebook.id, pageID: page.id), .saved)
    }

    @MainActor
    func testLatestStructuredGenerationWaitsForAndSupersedesActiveWrite() async throws {
        let notebook = makeNotebook(title: "Generations", kind: .textDocument)
        let page = try XCTUnwrap(notebook.pages.first)
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            blocksPageContentSave: true
        )
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()
        let first = PageContent.textDocument(
            TextDocument(blocks: [TextBlock(text: "First")])
        )
        let second = PageContent.textDocument(
            TextDocument(blocks: [TextBlock(text: "Second")])
        )

        model.stagePageContentForTesting(first, notebookID: notebook.id, pageID: page.id)
        let flushTask = Task { @MainActor in
            await model.flushPageContent(notebookID: notebook.id, pageID: page.id)
        }
        let started = await waitUntil {
            await store.persistenceEvents.contains("savePageContent")
        }
        XCTAssertTrue(started)
        model.stagePageContentForTesting(second, notebookID: notebook.id, pageID: page.id)
        await store.releasePageContentSave()

        let flushSucceeded = await flushTask.value
        let savedContents = await store.savedPageContents
        XCTAssertTrue(flushSucceeded)
        XCTAssertEqual(savedContents, [first, second])
        XCTAssertEqual(
            model.pageContentSaveState(notebookID: notebook.id, pageID: page.id),
            .saved
        )
    }

    @MainActor
    func testFailedOlderStructuredGenerationCannotOverwriteNewerActiveWrite() async throws {
        let notebook = makeNotebook(title: "Active generation", kind: .textDocument)
        let page = try XCTUnwrap(notebook.pages.first)
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            blocksPageContentSave: true,
            transientPageContentFailures: 1
        )
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()
        let first = PageContent.textDocument(
            TextDocument(blocks: [TextBlock(text: "Stale")])
        )
        let second = PageContent.textDocument(
            TextDocument(blocks: [TextBlock(text: "Newest")])
        )

        model.stagePageContentForTesting(first, notebookID: notebook.id, pageID: page.id)
        let firstFlush = Task { @MainActor in
            await model.flushPageContent(notebookID: notebook.id, pageID: page.id)
        }
        let started = await waitUntil {
            await store.persistenceEvents.filter { $0 == "savePageContent" }.count == 1
        }
        XCTAssertTrue(started)

        model.stagePageContentForTesting(second, notebookID: notebook.id, pageID: page.id)
        let secondFlush = Task { @MainActor in
            await model.flushPageContent(notebookID: notebook.id, pageID: page.id)
        }
        let newerIsActive = await waitUntil {
            model.isPageContentWriteActive(notebookID: notebook.id, pageID: page.id)
        }
        XCTAssertTrue(newerIsActive)
        await store.releasePageContentSave()

        let firstSucceeded = await firstFlush.value
        let secondSucceeded = await secondFlush.value
        let savedContents = await store.savedPageContents
        let persisted = await store.persistedPageContent(
            notebookID: notebook.id,
            pageID: page.id
        )

        XCTAssertTrue(firstSucceeded)
        XCTAssertTrue(secondSucceeded)
        XCTAssertEqual(savedContents, [second])
        XCTAssertEqual(persisted, second)
    }

    @MainActor
    func testFailedStructuredFlushRetainsPayloadAndIndexesOnlyAfterRetry() async throws {
        let notebook = makeNotebook(title: "Retry text", kind: .textDocument)
        let page = try XCTUnwrap(notebook.pages.first)
        let content = PageContent.textDocument(
            TextDocument(blocks: [TextBlock(text: "Durable searchable text")])
        )
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            transientPageContentFailures: 1
        )
        let search = SearchIndexSpy()
        let model = AppModel(store: store, searchIndex: search)
        await model.load()

        model.stagePageContentForTesting(content, notebookID: notebook.id, pageID: page.id)
        let first = await model.flushPageContent(notebookID: notebook.id, pageID: page.id)
        let indexedAfterFailure = await search.contains(documentID: page.id)
        let second = await model.flushPageContent(notebookID: notebook.id, pageID: page.id)
        let indexed = await search.document(id: page.id)
        let savedContents = await store.savedPageContents

        XCTAssertFalse(first)
        XCTAssertFalse(indexedAfterFailure)
        XCTAssertTrue(second)
        XCTAssertEqual(savedContents, [content])
        XCTAssertEqual(indexed?.segments.first?.text, "Durable searchable text")
    }

    @MainActor
    func testTextBlockSourceSnapshotSavesBeforeOneAuthoritativeRead() async throws {
        let notebook = makeNotebook(title: "Anchored", kind: .textDocument)
        let page = try XCTUnwrap(notebook.pages.first)
        let block = TextBlock(text: "  Exact e\u{301} source\n")
        let document = TextDocument(blocks: [block])
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            blocksPageContentSave: true
        )
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()
        let lease = try XCTUnwrap(model.beginEditorSession(notebookID: notebook.id))
        defer { model.endEditorSession(lease) }

        let snapshotTask = Task { @MainActor in
            try await model.prepareTextBlockSourceSnapshot(
                document: document,
                notebookID: notebook.id,
                pageID: page.id,
                blockID: block.id,
                editorSession: lease
            )
        }
        let saveStarted = await waitUntil {
            await store.persistenceEvents.contains("savePageContent")
        }
        XCTAssertTrue(saveStarted)
        let readCountWhileSaveIsBlocked = await store
            .textDocumentSourceSnapshotReadCount
        XCTAssertEqual(readCountWhileSaveIsBlocked, 0)
        await store.releasePageContentSave()
        let snapshot = try await snapshotTask.value

        XCTAssertEqual(snapshot.noteID, NotebookID(notebook.id))
        XCTAssertEqual(snapshot.pageID, PageID(page.id))
        XCTAssertEqual(snapshot.block, block)
        XCTAssertEqual(snapshot.textHash, ExactTextHash.sha256UTF8(block.text))
        let events = await store.persistenceEvents
        XCTAssertEqual(events, ["savePageContent", "sourceSnapshot"])
        let readCount = await store.textDocumentSourceSnapshotReadCount
        XCTAssertEqual(readCount, 1)
    }

    @MainActor
    func testTextBlockSourceSnapshotDoesNotReadWhenNoteSaveFails() async throws {
        let notebook = makeNotebook(title: "Failed anchor", kind: .textDocument)
        let page = try XCTUnwrap(notebook.pages.first)
        let block = TextBlock(text: "Save me first")
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            transientPageContentFailures: 1
        )
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()
        let lease = try XCTUnwrap(model.beginEditorSession(notebookID: notebook.id))
        defer { model.endEditorSession(lease) }

        do {
            _ = try await model.prepareTextBlockSourceSnapshot(
                document: TextDocument(blocks: [block]),
                notebookID: notebook.id,
                pageID: page.id,
                blockID: block.id,
                editorSession: lease
            )
            XCTFail("A failed Notes write must prevent academic source capture.")
        } catch let error as TextBlockAnchorPreparationError {
            XCTAssertEqual(error, .noteSaveFailed)
        }

        let readCount = await store.textDocumentSourceSnapshotReadCount
        XCTAssertEqual(readCount, 0)
    }

    @MainActor
    func testTextBlockSourceSnapshotRejectsChangedPersistedParagraph() async throws {
        let notebook = makeNotebook(title: "Changed anchor", kind: .textDocument)
        let page = try XCTUnwrap(notebook.pages.first)
        let block = TextBlock(text: "Original")
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        await store.overrideTextDocumentSourceSnapshotText("Changed")
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()
        let lease = try XCTUnwrap(model.beginEditorSession(notebookID: notebook.id))
        defer { model.endEditorSession(lease) }

        do {
            _ = try await model.prepareTextBlockSourceSnapshot(
                document: TextDocument(blocks: [block]),
                notebookID: notebook.id,
                pageID: page.id,
                blockID: block.id,
                editorSession: lease
            )
            XCTFail("A changed authoritative paragraph must not produce an anchor.")
        } catch let error as TextBlockAnchorPreparationError {
            XCTAssertEqual(error, .sourceChanged)
        }

        let events = await store.persistenceEvents
        XCTAssertEqual(events, ["savePageContent", "sourceSnapshot"])
    }

    @MainActor
    func testTextBlockSourceSnapshotRejectsBlankBlockWithoutWriting() async throws {
        let notebook = makeNotebook(title: "Blank anchor", kind: .textDocument)
        let page = try XCTUnwrap(notebook.pages.first)
        let block = TextBlock(text: " \n\t ")
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()
        let lease = try XCTUnwrap(model.beginEditorSession(notebookID: notebook.id))
        defer { model.endEditorSession(lease) }

        do {
            _ = try await model.prepareTextBlockSourceSnapshot(
                document: TextDocument(blocks: [block]),
                notebookID: notebook.id,
                pageID: page.id,
                blockID: block.id,
                editorSession: lease
            )
            XCTFail("Blank blocks cannot be captured.")
        } catch let error as TextBlockAnchorPreparationError {
            XCTAssertEqual(error, .blockNotCapturable)
        }

        let events = await store.persistenceEvents
        XCTAssertTrue(events.isEmpty)
    }

    @MainActor
    func testCaptureSourcePreviewClassifiesExactChangedAndUnverifiableWithOneReadEach() async throws {
        let notebook = makeNotebook(title: "Preview source", kind: .textDocument)
        let page = try XCTUnwrap(notebook.pages.first)
        let block = TextBlock(text: "  Exact source\n")
        let content = PageContent.textDocument(TextDocument(blocks: [block]))
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()
        model.stagePageContentForTesting(
            content,
            notebookID: notebook.id,
            pageID: page.id
        )
        let flushed = await model.flushPageContent(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertTrue(flushed)

        let exact = await model.captureSourcePreview(
            noteID: NotebookID(notebook.id),
            pageID: PageID(page.id),
            blockID: block.id,
            expectedTextHash: ExactTextHash.sha256UTF8(block.text)
        )
        XCTAssertEqual(exact, .exact(block.text))

        await store.overrideTextDocumentSourceSnapshotText("Changed source")
        let changed = await model.captureSourcePreview(
            noteID: NotebookID(notebook.id),
            pageID: PageID(page.id),
            blockID: block.id,
            expectedTextHash: ExactTextHash.sha256UTF8(block.text)
        )
        XCTAssertEqual(changed, .changed(currentText: "Changed source"))

        let unverifiable = await model.captureSourcePreview(
            noteID: NotebookID(notebook.id),
            pageID: PageID(page.id),
            blockID: block.id,
            expectedTextHash: nil
        )
        XCTAssertEqual(
            unverifiable,
            .unverifiable(currentText: "Changed source")
        )
        let readCount = await store.textDocumentSourceSnapshotReadCount
        XCTAssertEqual(readCount, 3)
    }

    @MainActor
    func testCaptureSourcePreviewReportsMissingWithoutGuessingAnotherBlock() async throws {
        let notebook = makeNotebook(title: "Missing source", kind: .textDocument)
        let page = try XCTUnwrap(notebook.pages.first)
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()

        let preview = await model.captureSourcePreview(
            noteID: NotebookID(notebook.id),
            pageID: PageID(page.id),
            blockID: TextBlockID(),
            expectedTextHash: String(repeating: "0", count: 64)
        )

        XCTAssertEqual(preview, .missing)
        let readCount = await store.textDocumentSourceSnapshotReadCount
        XCTAssertEqual(readCount, 1)
    }

    @MainActor
    func testPackageSnapshotFlushesStructuredContentBeforeExport() async throws {
        let notebook = makeNotebook(title: "Structured snapshot", kind: .studySet)
        let page = try XCTUnwrap(notebook.pages.first)
        let card = StudyCard(prompt: "Question", answer: "Answer")
        let content = PageContent.studySet(StudySet(cards: [card]))
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()

        model.stagePageContentForTesting(content, notebookID: notebook.id, pageID: page.id)
        let exported = await model.packageURL(for: notebook.summary)
        let events = await store.persistenceEvents

        XCTAssertNotNil(exported)
        XCTAssertEqual(events, ["savePageContent", "packageURL"])
    }

    @MainActor
    func testPackageFlushRepeatsWhenInkIsStagedDuringStructuredWrite() async throws {
        let notebook = makeNotebook(title: "Reentrant snapshot", kind: .textDocument)
        let page = try XCTUnwrap(notebook.pages.first)
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            blocksPageContentSave: true
        )
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()
        model.stagePageContentForTesting(
            .textDocument(TextDocument(blocks: [TextBlock(text: "Snapshot")])),
            notebookID: notebook.id,
            pageID: page.id
        )

        let packageTask = Task { @MainActor in
            await model.packageURL(for: notebook.summary)
        }
        let contentWriteStarted = await waitUntil {
            await store.persistenceEvents.contains("savePageContent")
        }
        XCTAssertTrue(contentWriteStarted)
        model.stageInkForTesting(Data([0xAA]), notebookID: notebook.id, page: page)
        await store.releasePageContentSave()

        let package = await packageTask.value
        let events = await store.persistenceEvents
        XCTAssertNotNil(package)
        XCTAssertEqual(events, ["savePageContent", "saveInk", "packageURL"])
    }

    @MainActor
    func testFailedCanvasElementFlushRetainsLatestSnapshotForRetry() async throws {
        let notebook = makeNotebook(title: "Element retry")
        let page = try XCTUnwrap(notebook.pages.first)
        let element = CanvasElementEditing.makeStickyNote(
            id: ElementID(),
            text: "Durable",
            at: CanvasPoint(x: 40, y: 60),
            within: CanvasRect(x: 0, y: 0, width: page.width, height: page.height),
            now: .now
        )
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            transientCanvasElementFailures: 1
        )
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()

        model.stageCanvasElementsForTesting([element], notebookID: notebook.id, pageID: page.id)
        let first = await model.flushCanvasElements(
            notebookID: notebook.id,
            pageID: page.id
        )
        let second = await model.flushCanvasElements(
            notebookID: notebook.id,
            pageID: page.id
        )

        XCTAssertFalse(first)
        XCTAssertTrue(second)
        let saved = await store.savedCanvasElements
        XCTAssertEqual(saved, [[element]])
        XCTAssertEqual(
            model.canvasElementSaveState(notebookID: notebook.id, pageID: page.id),
            .saved
        )
    }

    @MainActor
    func testCanvasTextIndexesOnlyAfterDurableSaveSucceeds() async throws {
        let notebook = makeNotebook(title: "Canvas index retry")
        let page = try XCTUnwrap(notebook.pages.first)
        let element = CanvasElementEditing.makeText(
            id: ElementID(),
            text: "Durable canvas text",
            at: CanvasPoint(x: 40, y: 60),
            within: CanvasRect(
                x: 0,
                y: 0,
                width: page.width,
                height: page.height
            ),
            now: page.modifiedAt
        )
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            transientCanvasElementFailures: 1
        )
        let search = SearchIndexSpy()
        let model = AppModel(store: store, searchIndex: search)
        await model.load()
        let documentID = CanvasElementSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )

        model.stageCanvasElementsForTesting([element], notebookID: notebook.id, pageID: page.id)
        let first = await model.flushCanvasElements(
            notebookID: notebook.id,
            pageID: page.id
        )

        XCTAssertFalse(first)
        let indexedAfterFailure = await search.document(id: documentID)
        XCTAssertNil(indexedAfterFailure)

        let second = await model.flushCanvasElements(
            notebookID: notebook.id,
            pageID: page.id
        )
        let indexed = await search.document(id: documentID)

        XCTAssertTrue(second)
        XCTAssertEqual(indexed?.notebookID, notebook.id)
        XCTAssertEqual(indexed?.pageID, page.id)
        XCTAssertEqual(indexed?.segments.map(\.text), ["Durable canvas text"])
        XCTAssertEqual(indexed?.segments.map(\.source), [.canvasElement])
    }

    @MainActor
    func testBootstrapRebuildsCanvasTextIndexFromDurableElements() async throws {
        let notebook = makeNotebook(title: "Bootstrap canvas")
        let page = try XCTUnwrap(notebook.pages.first)
        let element = CanvasElementEditing.makeStickyNote(
            id: ElementID(),
            text: "Recovered after launch",
            at: CanvasPoint(x: 30, y: 50),
            within: CanvasRect(
                x: 0,
                y: 0,
                width: page.width,
                height: page.height
            ),
            now: page.modifiedAt
        )
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        await store.setCanvasElements(
            [element],
            notebookID: notebook.id,
            pageID: page.id
        )
        let search = SearchIndexSpy()
        let model = AppModel(store: store, searchIndex: search)

        await model.load()

        let indexed = await search.document(id:
            CanvasElementSearchBuilder.documentID(
                notebookID: notebook.id,
                pageID: page.id
            )
        )
        XCTAssertEqual(indexed?.title, notebook.title)
        XCTAssertEqual(indexed?.segments.map(\.text), ["Recovered after launch"])
    }

    @MainActor
    func testDerivedCanvasIndexFailureDoesNotFailDurableSave() async throws {
        let notebook = makeNotebook(title: "Derived index failure")
        let page = try XCTUnwrap(notebook.pages.first)
        let documentID = CanvasElementSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        let element = CanvasElementEditing.makeText(
            id: ElementID(),
            text: "Still durable",
            at: CanvasPoint(x: 20, y: 20),
            within: CanvasRect(
                x: 0,
                y: 0,
                width: page.width,
                height: page.height
            ),
            now: page.modifiedAt
        )
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let search = SearchIndexSpy(failingUpsertDocumentIDs: [documentID])
        let model = AppModel(store: store, searchIndex: search)
        await model.load()

        model.stageCanvasElementsForTesting([element], notebookID: notebook.id, pageID: page.id)
        let saved = await model.flushCanvasElements(
            notebookID: notebook.id,
            pageID: page.id
        )

        XCTAssertTrue(saved)
        let persisted = await store.persistedCanvasElements(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertEqual(persisted, [element])
        XCTAssertEqual(
            model.canvasElementSaveState(notebookID: notebook.id, pageID: page.id),
            .saved
        )
        let indexed = await search.document(id: documentID)
        XCTAssertNil(indexed)
        XCTAssertNotNil(model.notice)
    }

    @MainActor
    func testRemovingCanvasTextPreservesRawPageSearchDocument() async throws {
        let notebook = makeNotebook(title: "Independent canvas document")
        let page = try XCTUnwrap(notebook.pages.first)
        let textElement = CanvasElementEditing.makeText(
            id: ElementID(),
            text: "Temporary canvas text",
            at: CanvasPoint(x: 20, y: 20),
            within: CanvasRect(
                x: 0,
                y: 0,
                width: page.width,
                height: page.height
            ),
            now: page.modifiedAt
        )
        let shapeElement = CanvasElementEditing.makeShape(
            id: ElementID(),
            at: CanvasPoint(x: 20, y: 20),
            within: CanvasRect(
                x: 0,
                y: 0,
                width: page.width,
                height: page.height
            ),
            now: page.modifiedAt
        )
        let rawPageDocument = SearchIndexDocument(
            id: page.id,
            notebookID: notebook.id,
            pageID: page.id,
            title: notebook.title,
            revision: 1,
            segments: [RecognizedTextSegment(
                text: "Imported scan",
                pageID: page.id,
                source: .scannedImage
            )]
        )
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        await store.setCanvasElements(
            [textElement],
            notebookID: notebook.id,
            pageID: page.id
        )
        let search = SearchIndexSpy(documents: [rawPageDocument])
        let model = AppModel(store: store, searchIndex: search)
        await model.load()
        let canvasDocumentID = CanvasElementSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )

        model.stageCanvasElementsForTesting(
            [shapeElement],
            notebookID: notebook.id,
            pageID: page.id
        )
        let saved = await model.flushCanvasElements(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertTrue(saved)

        let rawDocumentAfterSave = await search.document(id: page.id)
        let canvasDocumentAfterSave = await search.document(id: canvasDocumentID)
        XCTAssertNotNil(rawDocumentAfterSave)
        XCTAssertNil(canvasDocumentAfterSave)
    }

    @MainActor
    func testRenameRefreshesCanvasSearchDocumentTitle() async throws {
        let notebook = makeNotebook(title: "Old title")
        let page = try XCTUnwrap(notebook.pages.first)
        let element = CanvasElementEditing.makeStickyNote(
            id: ElementID(),
            text: "Rename me",
            at: CanvasPoint(x: 20, y: 20),
            within: CanvasRect(
                x: 0,
                y: 0,
                width: page.width,
                height: page.height
            ),
            now: page.modifiedAt
        )
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        await store.setCanvasElements(
            [element],
            notebookID: notebook.id,
            pageID: page.id
        )
        let search = SearchIndexSpy()
        let model = AppModel(store: store, searchIndex: search)
        await model.load()
        let summary = try XCTUnwrap(model.notebooks.first)

        await model.rename(summary, to: "New title")

        let indexed = await search.document(id:
            CanvasElementSearchBuilder.documentID(
                notebookID: notebook.id,
                pageID: page.id
            )
        )
        XCTAssertEqual(indexed?.title, "New title")
    }

    @MainActor
    func testRenameRefreshesActiveLibrarySearchWithoutChangingQuery() async throws {
        let oldTitle = "Obsolete Library Sentinel"
        let notebook = makeNotebook(title: oldTitle)
        let model = AppModel(
            store: ControlledNotebookStore(initialNotebooks: [notebook]),
            searchIndex: LocalSearchIndex()
        )
        await model.load()
        model.searchText = oldTitle
        await model.searchIndexedContent()
        XCTAssertEqual(model.matchingNotebookIDs, [notebook.id])
        XCTAssertEqual(model.visibleNotebooks.map(\.id), [notebook.id])
        let summary = try XCTUnwrap(model.notebooks.first)

        await model.rename(summary, to: "Current Library Sentinel")

        XCTAssertEqual(model.searchText, oldTitle)
        XCTAssertEqual(model.matchingNotebookIDs, Set<UUID>())
        XCTAssertTrue(model.visibleNotebooks.isEmpty)
    }

    @MainActor
    func testLateOCRPublicationUsesCurrentTitleAuthorityAfterRename() async throws {
        var notebook = makeNotebook(title: "Before OCR rename")
        var page = try XCTUnwrap(notebook.pages.first)
        let assetPath = "assets/late-ocr-title.bin"
        page.background = .image(assetPath: assetPath)
        notebook.pages[0] = page
        let ocrNotebook = notebook
        let ocrPage = page
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        try await store.installAsset(
            Data([0x10, 0x20, 0x30]),
            relativePath: assetPath
        )
        let libraryURL = try await store.libraryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: libraryURL) }
        let recognizer = BlockingHandwritingRecognizer()
        let search = SearchIndexSpy()
        let model = AppModel(
            store: store,
            searchIndex: search,
            imageTextRecognizer: recognizer
        )
        await model.load()
        let summary = try XCTUnwrap(model.notebooks.first)
        await search.blockNextUpsert(ocrPage.id)

        let extraction = Task { @MainActor in
            await model.extractText(
                notebookID: ocrNotebook.id,
                page: ocrPage
            )
        }
        let recognitionStarted = await waitUntil { await recognizer.wasInvoked }
        XCTAssertTrue(recognitionStarted)
        await recognizer.release()
        let stalePublicationDidBlock = await waitUntil {
            await search.hasBlockedUpsert
        }
        XCTAssertTrue(stalePublicationDidBlock)

        await model.rename(summary, to: "After OCR rename")
        let titleAuthority = await search.document(id: ocrNotebook.id)
        XCTAssertEqual(titleAuthority?.title, "After OCR rename")

        await search.releaseBlockedUpsert()
        let extracted = await extraction.value
        let indexed = await search.document(id: ocrPage.id)
        XCTAssertNotNil(extracted)
        XCTAssertEqual(indexed?.title, "After OCR rename")
        XCTAssertEqual(indexed?.segments.map(\.text), ["stale machine result"])
    }

    @MainActor
    func testPageDeleteTombstoneSurvivesBatchFailureAndRejectsLateOCRPublication() async throws {
        var notebook = makeNotebook(
            title: "Delete during OCR",
            pageCount: 2
        )
        var page = try XCTUnwrap(notebook.pages.first)
        let assetPath = "assets/deleted-page-late-ocr.bin"
        page.background = .image(assetPath: assetPath)
        notebook.pages[0] = page
        let ocrNotebook = notebook
        let ocrPage = page
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        try await store.installAsset(
            Data([0x40, 0x50, 0x60]),
            relativePath: assetPath
        )
        let libraryURL = try await store.libraryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: libraryURL) }
        let recognizer = BlockingHandwritingRecognizer()
        let search = SearchIndexSpy(removePageDocumentsFailures: 1)
        let model = AppModel(
            store: store,
            searchIndex: search,
            imageTextRecognizer: recognizer
        )
        await model.load()
        await search.blockNextUpsert(ocrPage.id)

        let extraction = Task { @MainActor in
            await model.extractText(
                notebookID: ocrNotebook.id,
                page: ocrPage
            )
        }
        let recognitionStarted = await waitUntil { await recognizer.wasInvoked }
        XCTAssertTrue(recognitionStarted)
        await recognizer.release()
        let latePublicationDidBlock = await waitUntil {
            await search.hasBlockedUpsert
        }
        XCTAssertTrue(latePublicationDidBlock)

        let updated = await model.deletePageForTesting(
            from: ocrNotebook,
            pageID: ocrPage.id
        )
        XCTAssertNotNil(updated)
        XCTAssertFalse(updated?.pages.contains(where: {
            $0.id == ocrPage.id
        }) ?? true)

        await search.releaseBlockedUpsert()
        let extracted = await extraction.value
        let deletedDocument = await search.document(id: ocrPage.id)
        XCTAssertNotNil(extracted)
        XCTAssertNil(deletedDocument)
    }

    @MainActor
    func testLateHigherRevisionTitlePublicationCannotOverrideCurrentRename() async throws {
        let notebook = makeNotebook(title: "Before overlapping renames")
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let search = SearchIndexSpy()
        let model = AppModel(store: store, searchIndex: search)
        await model.load()
        let originalSummary = try XCTUnwrap(model.notebooks.first)
        await search.blockNextUpsert(
            notebook.id,
            forcedRevision: Int.max / 4
        )

        let staleRename = Task { @MainActor in
            await model.rename(originalSummary, to: "Stale rename")
        }
        let staleTitleDidBlock = await waitUntil {
            await search.hasBlockedUpsert
        }
        XCTAssertTrue(staleTitleDidBlock)
        let currentSummary = try XCTUnwrap(model.notebooks.first)

        await model.rename(currentSummary, to: "Current rename")
        let indexedBeforeRelease = await search.document(id: notebook.id)
        XCTAssertEqual(indexedBeforeRelease?.title, "Current rename")

        await search.releaseBlockedUpsert()
        await staleRename.value
        let indexed = await search.document(id: notebook.id)
        let durable = try await store.loadNotebook(id: notebook.id)
        XCTAssertEqual(model.notebooks.first?.title, "Current rename")
        XCTAssertEqual(durable.title, "Current rename")
        XCTAssertEqual(indexed?.title, "Current rename")
    }

    @MainActor
    func testStaleRenameReindexCannotOverwriteNewerCanvasSave() async throws {
        let notebook = makeNotebook(title: "Before rename")
        let page = try XCTUnwrap(notebook.pages.first)
        let bounds = CanvasRect(
            x: 0,
            y: 0,
            width: page.width,
            height: page.height
        )
        let oldElement = CanvasElementEditing.makeText(
            id: ElementID(),
            text: "Old durable text",
            at: CanvasPoint(x: 20, y: 20),
            within: bounds,
            now: page.modifiedAt
        )
        let newElement = CanvasElementEditing.makeText(
            id: ElementID(),
            text: "Newest durable text",
            at: CanvasPoint(x: 30, y: 30),
            within: bounds,
            now: page.modifiedAt
        )
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        await store.setCanvasElements(
            [oldElement],
            notebookID: notebook.id,
            pageID: page.id
        )
        let search = SearchIndexSpy()
        let model = AppModel(store: store, searchIndex: search)
        await model.load()
        let summary = try XCTUnwrap(model.notebooks.first)
        let documentID = CanvasElementSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        await search.blockNextDocumentRead(documentID)

        let renameTask = Task { @MainActor in
            await model.rename(summary, to: "After rename")
        }
        let renameDidBlock = await waitUntil {
            await search.hasBlockedDocumentRead
        }
        XCTAssertTrue(renameDidBlock)

        model.stageCanvasElementsForTesting(
            [newElement],
            notebookID: notebook.id,
            pageID: page.id
        )
        let saved = await model.flushCanvasElements(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertTrue(saved)
        await search.releaseBlockedDocumentRead()
        await renameTask.value

        let indexed = await search.document(id: documentID)
        XCTAssertEqual(indexed?.title, "After rename")
        XCTAssertEqual(indexed?.segments.map(\.text), ["Newest durable text"])
    }

    @MainActor
    func testFailedOlderCanvasGenerationCannotOverwriteNewerActiveWrite() async throws {
        let notebook = makeNotebook(title: "Element generations")
        let page = try XCTUnwrap(notebook.pages.first)
        let bounds = CanvasRect(x: 0, y: 0, width: page.width, height: page.height)
        let firstElement = CanvasElementEditing.makeText(
            id: ElementID(),
            text: "Stale",
            at: CanvasPoint(x: 20, y: 20),
            within: bounds,
            now: .now
        )
        let secondElement = CanvasElementEditing.makeText(
            id: ElementID(),
            text: "Newest",
            at: CanvasPoint(x: 80, y: 80),
            within: bounds,
            now: .now
        )
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            blocksCanvasElementSave: true,
            transientCanvasElementFailures: 1
        )
        let search = SearchIndexSpy()
        let model = AppModel(store: store, searchIndex: search)
        await model.load()

        model.stageCanvasElementsForTesting([firstElement], notebookID: notebook.id, pageID: page.id)
        let firstFlush = Task { @MainActor in
            await model.flushCanvasElements(notebookID: notebook.id, pageID: page.id)
        }
        let firstStarted = await waitUntil {
            await store.persistenceEvents.filter { $0 == "saveElements" }.count == 1
        }
        XCTAssertTrue(firstStarted)

        model.stageCanvasElementsForTesting([secondElement], notebookID: notebook.id, pageID: page.id)
        let secondFlush = Task { @MainActor in
            await model.flushCanvasElements(notebookID: notebook.id, pageID: page.id)
        }
        let newerIsActive = await waitUntil {
            model.isCanvasElementWriteActive(notebookID: notebook.id, pageID: page.id)
        }
        XCTAssertTrue(newerIsActive)
        await store.releaseCanvasElementSave()

        let firstSucceeded = await firstFlush.value
        let secondSucceeded = await secondFlush.value
        XCTAssertTrue(firstSucceeded)
        XCTAssertTrue(secondSucceeded)
        let saved = await store.savedCanvasElements
        XCTAssertEqual(saved, [[secondElement]])
        let indexed = await search.document(id:
            CanvasElementSearchBuilder.documentID(
                notebookID: notebook.id,
                pageID: page.id
            )
        )
        XCTAssertEqual(indexed?.segments.map(\.text), ["Newest"])
    }

    @MainActor
    func testPackageSnapshotFlushesCanvasElementsBeforeExport() async throws {
        let notebook = makeNotebook(title: "Element snapshot")
        let page = try XCTUnwrap(notebook.pages.first)
        let element = CanvasElementEditing.makeShape(
            id: ElementID(),
            at: CanvasPoint(x: 100, y: 100),
            within: CanvasRect(x: 0, y: 0, width: page.width, height: page.height),
            now: .now
        )
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()

        model.stageCanvasElementsForTesting([element], notebookID: notebook.id, pageID: page.id)
        let exported = await model.packageURL(for: notebook.summary)

        XCTAssertNotNil(exported)
        let events = await store.persistenceEvents
        XCTAssertEqual(events, ["saveElements", "packageURL"])
    }

    @MainActor
    func testDuplicateInkPageCopiesAndIndexesItsCanvasElements() async throws {
        let notebook = makeNotebook(title: "Element duplicate")
        let page = try XCTUnwrap(notebook.pages.first)
        let element = CanvasElementEditing.makeStickyNote(
            id: ElementID(),
            text: "Copied search text",
            at: CanvasPoint(x: 90, y: 120),
            within: CanvasRect(x: 0, y: 0, width: page.width, height: page.height),
            now: .now
        )
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        await store.setCanvasElements([element], notebookID: notebook.id, pageID: page.id)
        let search = SearchIndexSpy()
        let model = AppModel(store: store, searchIndex: search)
        await model.load()

        let result = await model.duplicatePageForTesting(in: notebook, page: page)
        let duplicateID = try XCTUnwrap(result?.1)
        let copied = await store.persistedCanvasElements(
            notebookID: notebook.id,
            pageID: duplicateID
        )

        XCTAssertEqual(copied, [element])
        let duplicateDocument = await search.document(id:
            CanvasElementSearchBuilder.documentID(
                notebookID: notebook.id,
                pageID: duplicateID
            )
        )
        XCTAssertEqual(duplicateDocument?.segments.map(\.id), [element.id.rawValue])
        XCTAssertEqual(duplicateDocument?.segments.map(\.text), ["Copied search text"])
        XCTAssertNotEqual(
            duplicateDocument?.id,
            CanvasElementSearchBuilder.documentID(
                notebookID: notebook.id,
                pageID: page.id
            )
        )
    }

    @MainActor
    func testStructuredDuplicateFailureDeletesOnlyThePartialNewPage() async throws {
        let notebook = makeNotebook(title: "Structured rollback", kind: .textDocument)
        let sourcePage = try XCTUnwrap(notebook.pages.first)
        let sourceContent = PageContent.textDocument(
            TextDocument(blocks: [TextBlock(text: "Source content")])
        )
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            duplicateFailure: .pageContentWrite
        )
        await store.setPageContent(
            sourceContent,
            notebookID: notebook.id,
            pageID: sourcePage.id
        )
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()

        let result = await model.duplicatePageForTesting(
            in: notebook,
            page: sourcePage
        )
        let persisted = await store.persistedNotebook(id: notebook.id)
        let deletedPageIDs = await store.deletedPageIDs

        XCTAssertNil(result)
        XCTAssertEqual(persisted?.pages.map(\.id), notebook.pages.map(\.id))
        XCTAssertEqual(deletedPageIDs.count, 1)
        XCTAssertNotNil(model.notice)
    }

    @MainActor
    func testStructuredDuplicateRejectsMissingSourceContentBeforeAddingPage() async throws {
        let notebook = makeNotebook(title: "Missing structured source", kind: .studySet)
        let sourcePage = try XCTUnwrap(notebook.pages.first)
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        await store.removePageContent(notebookID: notebook.id, pageID: sourcePage.id)
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()

        let result = await model.duplicatePageForTesting(
            in: notebook,
            page: sourcePage
        )
        let savedPageSequences = await store.savedPageIDSequences
        let deletedPageIDs = await store.deletedPageIDs

        XCTAssertNil(result)
        XCTAssertTrue(savedPageSequences.isEmpty)
        XCTAssertTrue(deletedPageIDs.isEmpty)
        XCTAssertNotNil(model.notice)
    }

    @MainActor
    func testBackupUsesVerifiedStoreSnapshotsAndRefreshesHistory() async throws {
        let notebook = makeNotebook(title: "Backed up")
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let backupService = BackupServiceSpy()
        let suiteName = "NotesAppTests.Backup.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let model = AppModel(
            store: store,
            searchIndex: SearchIndexSpy(),
            backupService: backupService,
            preferences: preferences
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesAppBackupTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }
        await model.load()
        await model.useBackupDirectory(destination)

        let createdSnapshot = await model.createBackup()
        let snapshot = try XCTUnwrap(createdSnapshot)

        XCTAssertEqual(snapshot.notebookNames.count, 1)
        XCTAssertEqual(model.backupSnapshots.map(\.id), [snapshot.id])
        XCTAssertTrue(preferences.data(forKey: "notes.backup.destinationBookmark") != nil)
        let sourceNames = await backupService.lastSourceNames
        XCTAssertEqual(sourceNames.count, 1)
        XCTAssertTrue(try XCTUnwrap(sourceNames.first).hasSuffix(".notepkg"))
    }

    @MainActor
    func testLightweightStoreDoesNotOfferAudioOrReplay() {
        let store = ControlledNotebookStore(initialNotebooks: [])
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())

        XCTAssertNil(model.notebookAudio)
        XCTAssertNil(model.makeNoteReplayController())
    }

    @MainActor
    func testLocalStoreCreatesFreshReplayControllersFromSharedAudioInfrastructure() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesReplayFactory-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "NotesAppTests.ReplayFactory.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            preferences.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
        let store = LocalNotebookStore(
            userDefaultsSuiteName: suiteName,
            overrideRoot: root
        )
        let model = AppModel(
            store: store,
            searchIndex: SearchIndexSpy(),
            preferences: preferences
        )

        let first = try XCTUnwrap(model.makeNoteReplayController())
        let second = try XCTUnwrap(model.makeNoteReplayController())

        XCTAssertNotNil(model.notebookAudio)
        XCTAssertFalse(first === second)
    }

    @MainActor
    func testLocalStoreRootValidationFailuresPreserveSelectedRootAndBookmark() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NotesRootRollback-\(UUID().uuidString)",
            isDirectory: true
        )
        let oldDirectory = base.appendingPathComponent("old", isDirectory: true)
        let rejectedDirectory = base.appendingPathComponent("rejected", isDirectory: true)
        let defaultDocuments = base.appendingPathComponent("default", isDirectory: true)
        for directory in [oldDirectory, rejectedDirectory, defaultDocuments] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        let suiteName = "NotesAppTests.RootRollback.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            preferences.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: base)
        }

        let rejectedRootPaths = Set([
            rejectedDirectory.appendingPathComponent(
                "Notes",
                isDirectory: true
            ).standardizedFileURL.path,
            defaultDocuments.appendingPathComponent(
                "Notes",
                isDirectory: true
            ).standardizedFileURL.path,
        ])
        let store = LocalNotebookStore(
            userDefaultsSuiteName: suiteName,
            defaultDocumentsURLForTesting: defaultDocuments,
            repositoryFactory: { root in
                guard !rejectedRootPaths.contains(root.standardizedFileURL.path) else {
                    throw RootRepositoryValidationFailure.rejected
                }
                return try FileNotebookRepository(rootURL: root)
            }
        )
        try await store.setRootDirectory(oldDirectory)
        let notebook = try await store.createNotebook(
            title: "Preserved root",
            kind: .notebook,
            template: .blank
        )
        let bookmarkKey = "notes.library.rootBookmark"
        let originalBookmark = try XCTUnwrap(preferences.data(forKey: bookmarkKey))
        let originalDescription = await store.rootDescription()

        do {
            try await store.setRootDirectory(rejectedDirectory)
            XCTFail("A rejected selected root must fail")
        } catch RootRepositoryValidationFailure.rejected {
            // Expected.
        }
        XCTAssertEqual(preferences.data(forKey: bookmarkKey), originalBookmark)
        let selectedFailureDescription = await store.rootDescription()
        let selectedFailureNotebook = try await store.loadNotebook(id: notebook.id)
        XCTAssertEqual(selectedFailureDescription, originalDescription)
        XCTAssertEqual(selectedFailureNotebook.id, notebook.id)

        do {
            try await store.setRootDirectory(nil)
            XCTFail("A rejected default root must fail")
        } catch RootRepositoryValidationFailure.rejected {
            // Expected.
        }
        XCTAssertEqual(preferences.data(forKey: bookmarkKey), originalBookmark)
        let defaultFailureDescription = await store.rootDescription()
        let defaultFailureNotebook = try await store.loadNotebook(id: notebook.id)
        XCTAssertEqual(defaultFailureDescription, originalDescription)
        XCTAssertEqual(defaultFailureNotebook.id, notebook.id)
    }

    @MainActor
    func testLocalStoreTentativeRootCommitCanStillRollback() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NotesTentativeRoot-\(UUID().uuidString)",
            isDirectory: true
        )
        let oldDirectory = base.appendingPathComponent("old", isDirectory: true)
        let candidateDirectory = base.appendingPathComponent("candidate", isDirectory: true)
        try FileManager.default.createDirectory(
            at: oldDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: candidateDirectory,
            withIntermediateDirectories: true
        )
        let suiteName = "NotesAppTests.TentativeRoot.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            preferences.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: base)
        }
        let synchronizer = RootBookmarkSynchronizerSpy()
        let store = LocalNotebookStore(
            userDefaultsSuiteName: suiteName,
            userDefaultsSynchronizer: { synchronizer.synchronize($0) }
        )
        try await store.setRootDirectory(oldDirectory)
        let notebook = try await store.createNotebook(
            title: "Old root survives",
            kind: .notebook,
            template: .blank
        )
        let bookmarkKey = "notes.library.rootBookmark"
        let previousBookmark = try XCTUnwrap(preferences.data(forKey: bookmarkKey))
        let previousDescription = await store.rootDescription()
        let synchronizationCountBeforeCandidate = synchronizer.observedBookmarks.count

        let preparation = NotesAppLibraryRootPreparation()
        try await store.prepareRootDirectoryTransition(
            to: candidateDirectory,
            preparation: preparation
        )
        let transition = try await store.beginRootDirectoryTransition(preparation)
        _ = try await store.loadLibrary()
        try await store.commitRootDirectoryTransition(transition)
        await store.rollbackRootDirectoryTransition(transition)

        let restoredBookmark = preferences.data(forKey: bookmarkKey)
        let restoredDescription = await store.rootDescription()
        let restoredNotebook = try await store.loadNotebook(id: notebook.id)
        XCTAssertEqual(restoredBookmark, previousBookmark)
        XCTAssertEqual(restoredDescription, previousDescription)
        XCTAssertEqual(restoredNotebook.id, notebook.id)
        XCTAssertEqual(
            synchronizer.observedBookmarks.count,
            synchronizationCountBeforeCandidate + 2
        )
        XCTAssertEqual(synchronizer.observedBookmarks.last ?? nil, previousBookmark)
    }

    @MainActor
    func testLocalStoreFailedBookmarkSynchronizationRestoresPreviousRoot() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NotesBookmarkSynchronization-\(UUID().uuidString)",
            isDirectory: true
        )
        let oldDirectory = base.appendingPathComponent("old", isDirectory: true)
        let candidateDirectory = base.appendingPathComponent("candidate", isDirectory: true)
        try FileManager.default.createDirectory(
            at: oldDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: candidateDirectory,
            withIntermediateDirectories: true
        )
        let suiteName = "NotesAppTests.BookmarkSynchronization.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            preferences.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: base)
        }
        let synchronizer = RootBookmarkSynchronizerSpy(
            results: [true, false, true]
        )
        let store = LocalNotebookStore(
            userDefaultsSuiteName: suiteName,
            userDefaultsSynchronizer: { synchronizer.synchronize($0) }
        )
        try await store.setRootDirectory(oldDirectory)
        let notebook = try await store.createNotebook(
            title: "Durable old root",
            kind: .notebook,
            template: .blank
        )
        let bookmarkKey = "notes.library.rootBookmark"
        let previousBookmark = try XCTUnwrap(preferences.data(forKey: bookmarkKey))
        let previousDescription = await store.rootDescription()

        do {
            try await store.setRootDirectory(candidateDirectory)
            XCTFail("A root whose bookmark could not synchronize must be rejected")
        } catch LocalNotebookStore.StoreError.invalidRootTransition {
            // Expected: the failed candidate was never marked committed.
        }

        let restoredNotebook = try await store.loadNotebook(id: notebook.id)
        let restoredDescription = await store.rootDescription()
        XCTAssertEqual(preferences.data(forKey: bookmarkKey), previousBookmark)
        XCTAssertEqual(restoredDescription, previousDescription)
        XCTAssertEqual(restoredNotebook.id, notebook.id)
        XCTAssertEqual(synchronizer.observedBookmarks.count, 3)
        XCTAssertNotEqual(synchronizer.observedBookmarks[1], previousBookmark)
        XCTAssertEqual(synchronizer.observedBookmarks[2], previousBookmark)
    }

    @MainActor
    func testLocalStoreRollbackRetainsCandidateLeaseUntilLateInspectionEnds() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NotesInspectionLease-\(UUID().uuidString)",
            isDirectory: true
        )
        let oldDirectory = base.appendingPathComponent("old", isDirectory: true)
        let candidateDirectory = base.appendingPathComponent("candidate", isDirectory: true)
        try FileManager.default.createDirectory(
            at: oldDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: candidateDirectory,
            withIntermediateDirectories: true
        )
        let suiteName = "NotesAppTests.InspectionLease.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            preferences.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: base)
        }
        let store = LocalNotebookStore(
            userDefaultsSuiteName: suiteName,
            libraryLoadReturnDelay: .seconds(10)
        )
        try await store.setRootDirectory(oldDirectory)
        let oldDescription = await store.rootDescription()
        let preparation = NotesAppLibraryRootPreparation()
        try await store.prepareRootDirectoryTransition(
            to: candidateDirectory,
            preparation: preparation
        )
        let transition = try await store.beginRootDirectoryTransition(preparation)
        let inspection = Task {
            try await store.loadLibrary()
        }
        let inspectionStarted = await waitUntil {
            await store.isRootTransitionInspectionActive()
        }
        XCTAssertTrue(inspectionStarted)

        await store.rollbackRootDirectoryTransition(transition)
        let restoredDescription = await store.rootDescription()
        XCTAssertEqual(restoredDescription, oldDescription)

        inspection.cancel()
        _ = try? await inspection.value
        let cleanupFinished = await waitUntil {
            !(await store.isRootTransitionInspectionActive())
        }
        XCTAssertTrue(cleanupFinished)

        let retryPreparation = NotesAppLibraryRootPreparation()
        try await store.prepareRootDirectoryTransition(
            to: candidateDirectory,
            preparation: retryPreparation
        )
        let retry = try await store.beginRootDirectoryTransition(retryPreparation)
        await store.rollbackRootDirectoryTransition(retry)
    }

    @MainActor
    func testRootPreparationTimeoutReturnsBeforeBlockedRepositoryFactory() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NotesAppRootPreparationTimeout-\(UUID().uuidString)",
            isDirectory: true
        )
        let suiteName = "NotesAppTests.RootPreparationTimeout.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            preferences.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: base)
        }
        let factory = BlockingSecondRepositoryFactory()
        defer { factory.releaseSecondInvocation() }
        let store = LocalNotebookStore(
            userDefaultsSuiteName: suiteName,
            overrideRoot: base,
            repositoryFactory: { try factory.makeRepository(at: $0) }
        )
        let model = AppModel(
            store: store,
            searchIndex: SearchIndexSpy(),
            preferences: preferences,
            libraryRootChangeTimeout: .milliseconds(75)
        )
        await model.load()
        let clock = ContinuousClock()
        let startedAt = clock.now
        let move = Task { @MainActor in
            await model.useRootDirectory(
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("NotesBlockedProvider-\(UUID().uuidString)")
            )
        }
        let preparationDidBlock = await waitUntil {
            factory.hasBlockedSecondInvocation
        }
        XCTAssertTrue(preparationDidBlock)

        await move.value
        let elapsed = startedAt.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertFalse(model.isLibraryRootChangeInProgress)
        XCTAssertFalse(preferences.bool(
            forKey: AppModel.searchRootRebuildRequiredKey
        ))

        factory.releaseSecondInvocation()
        let preparationCleanedUp = await waitUntil {
            !(await store.isRootTransitionPreparationActive())
        }
        XCTAssertTrue(preparationCleanedUp)
    }

    @MainActor
    func testCandidateMetadataTimeoutRollsBackWithoutBlockingStoreActor() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NotesAppMetadataTimeout-\(UUID().uuidString)",
            isDirectory: true
        )
        let suiteName = "NotesAppTests.MetadataTimeout.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            preferences.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: base)
        }
        let metadataRead = BlockingSecondMetadataRead()
        defer { metadataRead.releaseSecondInvocation() }
        let store = LocalNotebookStore(
            userDefaultsSuiteName: suiteName,
            overrideRoot: base,
            libraryMetadataReadHook: { metadataRead.read($0) }
        )
        let model = AppModel(
            store: store,
            searchIndex: SearchIndexSpy(),
            preferences: preferences,
            libraryRootChangeTimeout: .milliseconds(75)
        )
        await model.load()
        let clock = ContinuousClock()
        let startedAt = clock.now
        let move = Task { @MainActor in
            await model.useRootDirectory(
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("NotesBlockedMetadata-\(UUID().uuidString)")
            )
        }
        let metadataDidBlock = await waitUntil {
            metadataRead.hasBlockedSecondInvocation
        }
        XCTAssertTrue(metadataDidBlock)

        await move.value
        let elapsed = startedAt.duration(to: clock.now)
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertFalse(model.isLibraryRootChangeInProgress)
        XCTAssertFalse(preferences.bool(
            forKey: AppModel.searchRootRebuildRequiredKey
        ))

        metadataRead.releaseSecondInvocation()
        let inspectionCleanedUp = await waitUntil {
            !(await store.isRootTransitionInspectionActive())
        }
        XCTAssertTrue(inspectionCleanedUp)
    }

    @MainActor
    func testBlockedCurrentMetadataReadDoesNotPreventRecoveryRootSwitch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NotesAppCurrentMetadataRecovery-\(UUID().uuidString)",
            isDirectory: true
        )
        let suiteName = "NotesAppTests.CurrentMetadataRecovery.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            preferences.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: base)
        }
        let metadataRead = BlockingFirstMetadataRead()
        defer { metadataRead.releaseFirstInvocation() }
        let store = LocalNotebookStore(
            userDefaultsSuiteName: suiteName,
            overrideRoot: base,
            libraryMetadataReadHook: { metadataRead.read($0) }
        )
        let model = AppModel(
            store: store,
            searchIndex: SearchIndexSpy(),
            preferences: preferences,
            libraryRootChangeTimeout: .seconds(1)
        )
        let initialLoad = Task { @MainActor in await model.load() }
        let metadataDidBlock = await waitUntil {
            metadataRead.hasBlockedFirstInvocation
        }
        XCTAssertTrue(metadataDidBlock)

        await model.useRootDirectory(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("NotesCurrentMetadataRecovery-\(UUID().uuidString)")
        )

        XCTAssertFalse(model.isLibraryRootChangeInProgress)
        let oldInspectionStillOwnsItsLease = await store
            .isRootTransitionInspectionActive()
        XCTAssertTrue(oldInspectionStillOwnsItsLease)
        metadataRead.releaseFirstInvocation()
        await initialLoad.value
        let inspectionCleanedUp = await waitUntil {
            !(await store.isRootTransitionInspectionActive())
        }
        XCTAssertTrue(inspectionCleanedUp)
    }

    @MainActor
    func testBlockedCurrentRepositoryFactoryDoesNotPreventRecoveryRootSwitch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NotesAppCurrentFactoryRecovery-\(UUID().uuidString)",
            isDirectory: true
        )
        let suiteName = "NotesAppTests.CurrentFactoryRecovery.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            preferences.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: base)
        }
        let factory = BlockingFirstRepositoryFactory()
        defer { factory.releaseFirstInvocation() }
        let store = LocalNotebookStore(
            userDefaultsSuiteName: suiteName,
            overrideRoot: base,
            repositoryFactory: { try factory.makeRepository(at: $0) }
        )
        let model = AppModel(
            store: store,
            searchIndex: SearchIndexSpy(),
            preferences: preferences,
            libraryRootChangeTimeout: .seconds(1)
        )
        let initialLoad = Task { @MainActor in await model.load() }
        let factoryDidBlock = await waitUntil {
            factory.hasBlockedFirstInvocation
        }
        XCTAssertTrue(factoryDidBlock)

        await model.useRootDirectory(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("NotesCurrentFactoryRecovery-\(UUID().uuidString)")
        )

        XCTAssertFalse(model.isLibraryRootChangeInProgress)
        let oldInspectionStillOwnsItsLease = await store
            .isRootTransitionInspectionActive()
        XCTAssertTrue(oldInspectionStillOwnsItsLease)
        factory.releaseFirstInvocation()
        await initialLoad.value
        let inspectionCleanedUp = await waitUntil {
            !(await store.isRootTransitionInspectionActive())
        }
        XCTAssertTrue(inspectionCleanedUp)
    }

    @MainActor
    func testNotebookScopedFlushDrainsPendingContentAcrossPages() async throws {
        let notebook = makeNotebook(title: "Replay flush", pageCount: 2)
        let firstPage = try XCTUnwrap(notebook.pages.first)
        let secondPage = try XCTUnwrap(notebook.pages.last)
        let ink = Data([0x52, 0x50, 0x4C, 0x59])
        let element = CanvasElementEditing.makeStickyNote(
            id: ElementID(),
            text: "Replay",
            at: CanvasPoint(x: 40, y: 60),
            within: CanvasRect(
                x: 0,
                y: 0,
                width: secondPage.width,
                height: secondPage.height
            ),
            now: .now
        )
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()

        model.stageInkForTesting(ink, notebookID: notebook.id, page: firstPage)
        model.stageCanvasElementsForTesting(
            [element],
            notebookID: notebook.id,
            pageID: secondPage.id
        )

        let didFlush = await model.flushPendingWrites(notebookID: notebook.id)
        let savedInk = await store.savedInkPayloads
        let savedElements = await store.savedCanvasElements

        XCTAssertTrue(didFlush)
        XCTAssertEqual(savedInk, [ink])
        XCTAssertEqual(savedElements, [[element]])
    }

    @MainActor
    func testBootstrapIndexesOnlyAcceptedCurrentHandwriting() async throws {
        let notebook = makeNotebook(title: "Reviewed handwriting")
        let page = try XCTUnwrap(notebook.pages.first)
        let ink = Data("durable ink".utf8)
        let candidate = handwritingCandidate(text: "machine suggestion")
        let document = handwritingDocument(
            pageID: page.id,
            ink: ink,
            candidates: [candidate],
            reviews: [HandwritingCandidateReview(
                candidateID: candidate.id,
                decision: .accepted,
                correctedText: "human correction",
                reviewedAt: handwritingTimestamp
            )]
        )
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        await store.setInk(ink, notebookID: notebook.id, pageID: page.id)
        await store.setHandwritingRecognition(
            document,
            notebookID: notebook.id,
            pageID: page.id
        )
        let search = SearchIndexSpy()
        let model = AppModel(store: store, searchIndex: search)

        await model.load()

        let indexed = await search.document(id: HandwritingSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        ))
        XCTAssertEqual(indexed?.title, notebook.title)
        XCTAssertEqual(indexed?.segments.map(\.text), ["human correction"])
        XCTAssertEqual(indexed?.segments.map(\.source), [.handwriting])
        XCTAssertEqual(indexed?.segments.map(\.pageID), [page.id])
    }

    @MainActor
    func testAcceptRejectAndResetPublishOnlyDurableReviewedText() async throws {
        let notebook = makeNotebook(title: "Review workflow")
        let page = try XCTUnwrap(notebook.pages.first)
        let ink = Data("same ink".utf8)
        let candidate = handwritingCandidate(text: "machine remains immutable")
        let pending = handwritingDocument(
            pageID: page.id,
            ink: ink,
            candidates: [candidate]
        )
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        await store.setInk(ink, notebookID: notebook.id, pageID: page.id)
        await store.setHandwritingRecognition(
            pending,
            notebookID: notebook.id,
            pageID: page.id
        )
        let search = SearchIndexSpy()
        let model = AppModel(store: store, searchIndex: search)
        await model.load()
        let documentID = HandwritingSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        let pendingIsIndexed = await search.contains(documentID: documentID)
        XCTAssertFalse(pendingIsIndexed)

        let accepted = await model.updateHandwritingReview(
            notebookID: notebook.id,
            pageID: page.id,
            candidateID: candidate.id,
            decision: .accepted,
            correctedText: "reviewed correction"
        )

        XCTAssertEqual(accepted?.document.revision, 2)
        XCTAssertEqual(accepted?.document.acceptedText.map(\.text), ["reviewed correction"])
        let acceptedIndex = await search.document(id: documentID)
        XCTAssertEqual(acceptedIndex?.segments.map(\.text), ["reviewed correction"])
        let storedAccepted = await store.storedHandwritingRecognition(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertEqual(storedAccepted?.machineCandidates.first?.machineText,
                       "machine remains immutable")

        let rejected = await model.updateHandwritingReview(
            notebookID: notebook.id,
            pageID: page.id,
            candidateID: candidate.id,
            decision: .rejected,
            correctedText: "must be discarded"
        )
        XCTAssertEqual(rejected?.document.revision, 3)
        XCTAssertTrue(rejected?.document.acceptedText.isEmpty == true)
        let rejectedIsIndexed = await search.contains(documentID: documentID)
        XCTAssertFalse(rejectedIsIndexed)

        let reset = await model.updateHandwritingReview(
            notebookID: notebook.id,
            pageID: page.id,
            candidateID: candidate.id,
            decision: nil,
            correctedText: nil
        )
        XCTAssertEqual(reset?.document.revision, 4)
        XCTAssertTrue(reset?.document.reviews.isEmpty == true)
    }

    @MainActor
    func testRejectedHandwritingIsSuppressedWhenIndexRemovalFails() async throws {
        let notebook = makeNotebook(title: "Fail closed search")
        let page = try XCTUnwrap(notebook.pages.first)
        let ink = Data("private ink".utf8)
        let candidate = handwritingCandidate(text: "private accepted phrase")
        let reviewed = handwritingDocument(
            pageID: page.id,
            ink: ink,
            candidates: [candidate],
            reviews: [HandwritingCandidateReview(
                candidateID: candidate.id,
                decision: .accepted,
                reviewedAt: handwritingTimestamp
            )]
        )
        let documentID = HandwritingSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        let staleSegment = RecognizedTextSegment(
            id: candidate.id,
            text: candidate.machineText,
            pageID: page.id,
            source: .handwriting
        )
        let staleHit = LocalSearchSegmentHit(
            documentID: documentID,
            notebookID: notebook.id,
            pageID: page.id,
            title: notebook.title,
            snippet: candidate.machineText,
            score: 1,
            segment: staleSegment
        )
        let staleLibraryHit = LocalSearchHit(
            documentID: documentID,
            notebookID: notebook.id,
            pageID: page.id,
            title: notebook.title,
            snippet: candidate.machineText,
            score: 1,
            segment: staleSegment
        )
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        await store.setInk(ink, notebookID: notebook.id, pageID: page.id)
        await store.setHandwritingRecognition(
            reviewed,
            notebookID: notebook.id,
            pageID: page.id
        )
        let search = SearchIndexSpy(
            queryResponse: [staleLibraryHit],
            segmentQueryResponse: [staleHit],
            failingRemoveDocumentIDs: [documentID]
        )
        let model = AppModel(store: store, searchIndex: search)
        await model.load()
        model.searchText = candidate.machineText
        await model.searchIndexedContent()
        XCTAssertEqual(model.visibleNotebooks.map(\.id), [notebook.id])

        let rejected = await model.updateHandwritingReview(
            notebookID: notebook.id,
            pageID: page.id,
            candidateID: candidate.id,
            decision: .rejected,
            correctedText: nil
        )
        let directIndexStillContainsStaleText = await search.contains(
            documentID: documentID
        )
        let visibleHits = await model.searchNotebookContent(
            "private accepted phrase",
            notebookID: notebook.id
        )

        XCTAssertEqual(rejected?.document.reviews.first?.decision, .rejected)
        XCTAssertTrue(directIndexStillContainsStaleText)
        XCTAssertTrue(visibleHits.isEmpty)
        XCTAssertEqual(model.matchingNotebookIDs, Set<UUID>())
        XCTAssertTrue(model.searchTargetPageIDs.isEmpty)
        XCTAssertTrue(model.visibleNotebooks.isEmpty)
        XCTAssertNotNil(model.notice)
    }

    @MainActor
    func testReviewFlushesPendingInkAndRefusesStaleRecognition() async throws {
        let notebook = makeNotebook(title: "Pending ink review fence")
        let page = try XCTUnwrap(notebook.pages.first)
        let originalInk = Data("reviewed source ink".utf8)
        let changedInk = Data("new pending ink".utf8)
        let candidate = handwritingCandidate(text: "must not be accepted")
        let pendingReview = handwritingDocument(
            pageID: page.id,
            ink: originalInk,
            candidates: [candidate]
        )
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        await store.setInk(originalInk, notebookID: notebook.id, pageID: page.id)
        await store.setHandwritingRecognition(
            pendingReview,
            notebookID: notebook.id,
            pageID: page.id
        )
        let search = SearchIndexSpy()
        let model = AppModel(store: store, searchIndex: search)
        await model.load()

        model.stageInkForTesting(changedInk, notebookID: notebook.id, page: page)
        let result = await model.updateHandwritingReview(
            notebookID: notebook.id,
            pageID: page.id,
            candidateID: candidate.id,
            decision: .accepted,
            correctedText: "private correction"
        )

        XCTAssertNil(result)
        let storedInk = await store.savedInkPayloads
        XCTAssertEqual(storedInk, [changedInk])
        let storedReview = await store.storedHandwritingRecognition(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertEqual(storedReview, pendingReview)
        let indexed = await search.contains(
            documentID: HandwritingSearchBuilder.documentID(
                notebookID: notebook.id,
                pageID: page.id
            )
        )
        XCTAssertFalse(indexed)
        let snapshot = await model.handwritingRecognitionSnapshot(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertEqual(snapshot?.isCurrentForInk, false)
    }

    @MainActor
    func testDurableInkChangeRemovesAcceptedHandwritingFromSearchButRetainsReview() async throws {
        let notebook = makeNotebook(title: "Stale review")
        let page = try XCTUnwrap(notebook.pages.first)
        let originalInk = Data("original ink".utf8)
        let changedInk = Data("changed ink".utf8)
        let candidate = handwritingCandidate(text: "accepted before edit")
        let reviewed = handwritingDocument(
            pageID: page.id,
            ink: originalInk,
            candidates: [candidate],
            reviews: [HandwritingCandidateReview(
                candidateID: candidate.id,
                decision: .accepted,
                reviewedAt: handwritingTimestamp
            )]
        )
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        await store.setInk(originalInk, notebookID: notebook.id, pageID: page.id)
        await store.setHandwritingRecognition(
            reviewed,
            notebookID: notebook.id,
            pageID: page.id
        )
        let search = SearchIndexSpy()
        let model = AppModel(store: store, searchIndex: search)
        await model.load()
        let documentID = HandwritingSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        let wasIndexed = await search.contains(documentID: documentID)
        XCTAssertTrue(wasIndexed)

        let didSaveInk = await model.saveInkForTesting(
            changedInk,
            notebookID: notebook.id,
            page: page
        )
        XCTAssertTrue(didSaveInk)

        let remainsIndexed = await search.contains(documentID: documentID)
        XCTAssertFalse(remainsIndexed)
        let snapshot = await model.handwritingRecognitionSnapshot(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertEqual(snapshot?.document, reviewed)
        XCTAssertEqual(snapshot?.isCurrentForInk, false)
    }

    @MainActor
    func testIdenticalInkSaveDoesNotLeaveValidHandwritingSuppressed() async throws {
        let notebook = makeNotebook(title: "Unchanged ink")
        let page = try XCTUnwrap(notebook.pages.first)
        let ink = Data("unchanged ink".utf8)
        let candidate = handwritingCandidate(text: "still searchable")
        let reviewed = handwritingDocument(
            pageID: page.id,
            ink: ink,
            candidates: [candidate],
            reviews: [HandwritingCandidateReview(
                candidateID: candidate.id,
                decision: .accepted,
                reviewedAt: handwritingTimestamp
            )]
        )
        let documentID = HandwritingSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        let segment = RecognizedTextSegment(
            id: candidate.id,
            text: candidate.machineText,
            pageID: page.id,
            source: .handwriting
        )
        let search = SearchIndexSpy(segmentQueryResponse: [LocalSearchSegmentHit(
            documentID: documentID,
            notebookID: notebook.id,
            pageID: page.id,
            title: notebook.title,
            snippet: candidate.machineText,
            score: 1,
            segment: segment
        )])
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        await store.setInk(ink, notebookID: notebook.id, pageID: page.id)
        await store.setHandwritingRecognition(
            reviewed,
            notebookID: notebook.id,
            pageID: page.id
        )
        let model = AppModel(store: store, searchIndex: search)
        await model.load()

        let didSave = await model.saveInkForTesting(
            ink,
            notebookID: notebook.id,
            page: page
        )
        let visibleHits = await model.searchNotebookContent(
            "still searchable",
            notebookID: notebook.id
        )

        XCTAssertTrue(didSave)
        XCTAssertEqual(visibleHits.map(\.id.documentID), [documentID])
    }

    @MainActor
    func testOlderSuccessfulInkWriteIsReconciledWhenNewerQueuedWriteFails() async throws {
        let notebook = makeNotebook(title: "Queued ink repair")
        let page = try XCTUnwrap(notebook.pages.first)
        let originalInk = Data("indexed ink".utf8)
        let firstQueuedInk = Data("first queued ink".utf8)
        let secondQueuedInk = Data("second queued ink".utf8)
        let candidate = handwritingCandidate(text: "must become stale")
        let reviewed = handwritingDocument(
            pageID: page.id,
            ink: originalInk,
            candidates: [candidate],
            reviews: [HandwritingCandidateReview(
                candidateID: candidate.id,
                decision: .accepted,
                reviewedAt: handwritingTimestamp
            )]
        )
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            blocksInkSave: true,
            inkFailureCallNumbers: [2]
        )
        await store.setInk(originalInk, notebookID: notebook.id, pageID: page.id)
        await store.setHandwritingRecognition(
            reviewed,
            notebookID: notebook.id,
            pageID: page.id
        )
        let search = SearchIndexSpy()
        let model = AppModel(store: store, searchIndex: search)
        await model.load()
        let documentID = HandwritingSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        let initiallyIndexed = await search.contains(documentID: documentID)
        XCTAssertTrue(initiallyIndexed)

        model.stageInkForTesting(firstQueuedInk, notebookID: notebook.id, page: page)
        let flushTask = Task { @MainActor in
            await model.flushInk(notebookID: notebook.id, pageID: page.id)
        }
        let firstWriteStarted = await waitUntil { await store.saveInkCallCount == 1 }
        XCTAssertTrue(firstWriteStarted)
        model.stageInkForTesting(secondQueuedInk, notebookID: notebook.id, page: page)
        await store.releaseInkSave()

        let didFlush = await flushTask.value
        let remainsIndexed = await search.contains(documentID: documentID)
        let storedInkWrites = await store.savedInkPayloads
        let snapshot = await model.handwritingRecognitionSnapshot(
            notebookID: notebook.id,
            pageID: page.id
        )

        XCTAssertFalse(didFlush)
        XCTAssertEqual(storedInkWrites, [firstQueuedInk])
        XCTAssertFalse(remainsIndexed)
        XCTAssertEqual(snapshot?.isCurrentForInk, false)
    }

    @MainActor
    func testLateOlderRepairCannotResuppressNewerAcceptedReview() async throws {
        let notebook = makeNotebook(title: "Late repair fence")
        let page = try XCTUnwrap(notebook.pages.first)
        let ink = PKDrawing().dataRepresentation()
        let candidate = handwritingCandidate(text: "original accepted text")
        let reviewed = handwritingDocument(
            pageID: page.id,
            ink: ink,
            candidates: [candidate],
            reviews: [HandwritingCandidateReview(
                candidateID: candidate.id,
                decision: .accepted,
                reviewedAt: handwritingTimestamp
            )]
        )
        let documentID = HandwritingSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        let querySegment = RecognizedTextSegment(
            id: candidate.id,
            text: "newer reviewed text",
            pageID: page.id,
            source: .handwriting
        )
        let search = SearchIndexSpy(segmentQueryResponse: [LocalSearchSegmentHit(
            documentID: documentID,
            notebookID: notebook.id,
            pageID: page.id,
            title: notebook.title,
            snippet: querySegment.text,
            score: 1,
            segment: querySegment
        )])
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        await store.setInk(ink, notebookID: notebook.id, pageID: page.id)
        await store.setHandwritingRecognition(
            reviewed,
            notebookID: notebook.id,
            pageID: page.id
        )
        let model = AppModel(
            store: store,
            searchIndex: search,
            handwritingTextRecognizer: FailingHandwritingRecognizer()
        )
        await model.load()
        await store.blockHandwritingRecognitionLoad(afterAdditionalCalls: 1)

        let olderRecognition = Task { @MainActor in
            await model.recognizeHandwriting(
                notebookID: notebook.id,
                page: page,
                languages: ["en-US"]
            )
        }
        let oldRepairDidBlock = await waitUntil {
            await store.hasBlockedHandwritingRecognitionLoad
        }
        XCTAssertTrue(oldRepairDidBlock)

        let newerReview = await model.updateHandwritingReview(
            notebookID: notebook.id,
            pageID: page.id,
            candidateID: candidate.id,
            decision: .accepted,
            correctedText: "newer reviewed text"
        )
        XCTAssertEqual(newerReview?.document.revision, 2)
        XCTAssertEqual(newerReview?.document.acceptedText.map(\.text), ["newer reviewed text"])

        await store.releaseHandwritingRecognitionLoad()
        let olderResult = await olderRecognition.value
        XCTAssertNil(olderResult)

        let committedSearch = await search.document(id: documentID)
        XCTAssertEqual(committedSearch?.segments.map(\.text), ["newer reviewed text"])
        let visibleHits = await model.searchNotebookContent(
            "newer reviewed text",
            notebookID: notebook.id
        )
        XCTAssertEqual(visibleHits.map(\.id.documentID), [documentID])
    }

    @MainActor
    func testDelayedOlderRecognitionFailureCannotRepairOverNewerReview() async throws {
        let notebook = makeNotebook(title: "Recognition failure generation fence")
        let page = try XCTUnwrap(notebook.pages.first)
        let ink = PKDrawing().dataRepresentation()
        let candidate = handwritingCandidate(text: "machine text")
        let existing = handwritingDocument(
            pageID: page.id,
            ink: ink,
            candidates: [candidate]
        )
        let documentID = HandwritingSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        await store.setInk(ink, notebookID: notebook.id, pageID: page.id)
        await store.setHandwritingRecognition(
            existing,
            notebookID: notebook.id,
            pageID: page.id
        )
        let recognizer = DelayedFailingHandwritingRecognizer()
        let search = SearchIndexSpy()
        let model = AppModel(
            store: store,
            searchIndex: search,
            handwritingTextRecognizer: recognizer
        )
        await model.load()

        let olderRecognition = Task { @MainActor in
            await model.recognizeHandwriting(
                notebookID: notebook.id,
                page: page,
                languages: ["en-US"]
            )
        }
        let recognitionDidBlock = await waitUntil { await recognizer.wasInvoked }
        XCTAssertTrue(recognitionDidBlock)

        let newerReview = await model.updateHandwritingReview(
            notebookID: notebook.id,
            pageID: page.id,
            candidateID: candidate.id,
            decision: .accepted,
            correctedText: "newer accepted text"
        )
        XCTAssertEqual(newerReview?.document.revision, 2)
        let loadsBeforeOlderFailure = await store.handwritingRecognitionLoadCallCount

        await recognizer.release()
        let olderResult = await olderRecognition.value
        let loadsAfterOlderFailure = await store.handwritingRecognitionLoadCallCount
        let indexed = await search.document(id: documentID)

        XCTAssertNil(olderResult)
        XCTAssertEqual(loadsAfterOlderFailure, loadsBeforeOlderFailure)
        XCTAssertEqual(indexed?.segments.map(\.text), ["newer accepted text"])
    }

    @MainActor
    func testInkEditDuringRecognitionCannotPublishStaleSidecar() async throws {
        let notebook = makeNotebook(title: "Recognition race")
        let page = try XCTUnwrap(notebook.pages.first)
        let initialInk = PKDrawing().dataRepresentation()
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        await store.setInk(initialInk, notebookID: notebook.id, pageID: page.id)
        let recognizer = BlockingHandwritingRecognizer()
        let search = SearchIndexSpy()
        let model = AppModel(
            store: store,
            searchIndex: search,
            handwritingTextRecognizer: recognizer
        )
        await model.load()

        let recognitionTask = Task { @MainActor in
            await model.recognizeHandwriting(
                notebookID: notebook.id,
                page: page,
                languages: ["en-US"]
            )
        }
        let recognitionStarted = await waitUntil { await recognizer.wasInvoked }
        XCTAssertTrue(recognitionStarted)

        let didSaveNewerInk = await model.saveInkForTesting(
            Data("newer durable ink".utf8),
            notebookID: notebook.id,
            page: page
        )
        XCTAssertTrue(didSaveNewerInk)
        await recognizer.release()
        let result = await recognitionTask.value

        XCTAssertNil(result)
        let stored = await store.storedHandwritingRecognition(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertNil(stored)
        let staleDocumentWasIndexed = await search.contains(
            documentID: HandwritingSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        ))
        XCTAssertFalse(staleDocumentWasIndexed)
    }

    @MainActor
    func testLibraryRootChangeWaitsForAndInvalidatesActiveRecognition() async throws {
        let notebook = makeNotebook(title: "Root transition fence")
        let page = try XCTUnwrap(notebook.pages.first)
        let ink = PKDrawing().dataRepresentation()
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        await store.setInk(ink, notebookID: notebook.id, pageID: page.id)
        let recognizer = BlockingHandwritingRecognizer()
        let search = SearchIndexSpy()
        let model = AppModel(
            store: store,
            searchIndex: search,
            handwritingTextRecognizer: recognizer
        )
        await model.load()

        let recognitionTask = Task { @MainActor in
            await model.recognizeHandwriting(
                notebookID: notebook.id,
                page: page,
                languages: ["en-US"]
            )
        }
        let recognitionStarted = await waitUntil { await recognizer.wasInvoked }
        XCTAssertTrue(recognitionStarted)

        let newRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesRootTransition-\(UUID().uuidString)", isDirectory: true)
        let rootChangeTask = Task { @MainActor in
            await model.useRootDirectory(newRoot)
        }
        let transitionStarted = await waitUntil {
            model.isLibraryRootChangeInProgress
        }
        XCTAssertTrue(transitionStarted)
        let rootChangesBeforeRelease = await store.rootChangeCallCount
        XCTAssertEqual(rootChangesBeforeRelease, 0)

        await model.useRootDirectory(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("NotesCompetingMove-\(UUID().uuidString)")
        )
        XCTAssertTrue(model.isLibraryRootChangeInProgress)
        let rootChangesAfterCompetingRequest = await store.rootChangeCallCount
        XCTAssertEqual(rootChangesAfterCompetingRequest, 0)

        let blockedReview = await model.updateHandwritingReview(
            notebookID: notebook.id,
            pageID: page.id,
            candidateID: UUID(),
            decision: .accepted,
            correctedText: nil
        )
        XCTAssertNil(blockedReview)

        await recognizer.release()
        let recognitionResult = await recognitionTask.value
        await rootChangeTask.value

        XCTAssertNil(recognitionResult)
        let rootChangesAfterRelease = await store.rootChangeCallCount
        XCTAssertEqual(rootChangesAfterRelease, 1)
        let stored = await store.storedHandwritingRecognition(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertNil(stored)
        let staleDocumentWasIndexed = await search.contains(
            documentID: HandwritingSearchBuilder.documentID(
                notebookID: notebook.id,
                pageID: page.id
            )
        )
        XCTAssertFalse(staleDocumentWasIndexed)
    }

    @MainActor
    func testLibraryRootChangeWaitsForPageDuplicationBeforeInstallingNewRoot() async throws {
        let notebook = makeNotebook(title: "Duplicate root fence")
        let page = try XCTUnwrap(notebook.pages.first)
        let ink = PKDrawing().dataRepresentation()
        let candidate = handwritingCandidate(text: "review copied only in old root")
        let reviewed = handwritingDocument(
            pageID: page.id,
            ink: ink,
            candidates: [candidate],
            reviews: [HandwritingCandidateReview(
                candidateID: candidate.id,
                decision: .accepted,
                reviewedAt: handwritingTimestamp
            )]
        )
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            rootTransitionLoadFailures: 1
        )
        await store.setInk(ink, notebookID: notebook.id, pageID: page.id)
        await store.setHandwritingRecognition(
            reviewed,
            notebookID: notebook.id,
            pageID: page.id
        )
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()
        await store.blockHandwritingRecognitionLoad()

        let duplicationTask = Task { @MainActor in
            await model.duplicatePageForTesting(in: notebook, page: page)
        }
        let duplicationDidBlock = await waitUntil {
            await store.hasBlockedHandwritingRecognitionLoad
        }
        XCTAssertTrue(duplicationDidBlock)

        let rootChangeTask = Task { @MainActor in
            await model.useRootDirectory(
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("NotesDuplicateMove-\(UUID().uuidString)")
            )
        }
        let transitionStarted = await waitUntil {
            model.isLibraryRootChangeInProgress
        }
        XCTAssertTrue(transitionStarted)
        let rootChangesWhileDuplicateWasBlocked = await store.rootChangeCallCount
        XCTAssertEqual(rootChangesWhileDuplicateWasBlocked, 0)

        await store.releaseHandwritingRecognitionLoad()
        let duplicated = await duplicationTask.value
        await rootChangeTask.value

        let duplicationResult = try XCTUnwrap(duplicated)
        let rootChangesAfterDuplicateFinished = await store.rootChangeCallCount
        XCTAssertEqual(rootChangesAfterDuplicateFinished, 1)
        XCTAssertFalse(model.isLibraryRootChangeInProgress)
        XCTAssertEqual(
            model.notebooks.first(where: { $0.id == notebook.id })?.modifiedAt,
            duplicationResult.0.modifiedAt
        )
        let persistedAfterRollback = await model.notebook(id: notebook.id)
        XCTAssertEqual(persistedAfterRollback?.pages.count, 2)
    }

    @MainActor
    func testFailedRootChangeRepairsAuthoritativeHandwritingSuppression() async throws {
        let notebook = makeNotebook(title: "Root rollback search")
        let page = try XCTUnwrap(notebook.pages.first)
        let ink = PKDrawing().dataRepresentation()
        let candidate = handwritingCandidate(text: "visible after rollback")
        let reviewed = handwritingDocument(
            pageID: page.id,
            ink: ink,
            candidates: [candidate],
            reviews: [HandwritingCandidateReview(
                candidateID: candidate.id,
                decision: .accepted,
                reviewedAt: handwritingTimestamp
            )]
        )
        let documentID = HandwritingSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        let segment = RecognizedTextSegment(
            id: candidate.id,
            text: candidate.machineText,
            pageID: page.id,
            source: .handwriting
        )
        let search = SearchIndexSpy(segmentQueryResponse: [LocalSearchSegmentHit(
            documentID: documentID,
            notebookID: notebook.id,
            pageID: page.id,
            title: notebook.title,
            snippet: candidate.machineText,
            score: 1,
            segment: segment
        )])
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            transientInkFailures: 1
        )
        await store.setInk(ink, notebookID: notebook.id, pageID: page.id)
        await store.setHandwritingRecognition(
            reviewed,
            notebookID: notebook.id,
            pageID: page.id
        )
        let model = AppModel(store: store, searchIndex: search)
        await model.load()
        model.stageInkForTesting(ink, notebookID: notebook.id, page: page)

        await model.useRootDirectory(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("NotesFailedMove-\(UUID().uuidString)")
        )

        let rootChangeCount = await store.rootChangeCallCount
        let repairBecameVisible = await waitUntil {
            let hits = await model.searchNotebookContent(
                candidate.machineText,
                notebookID: notebook.id
            )
            return !hits.isEmpty
        }
        let visibleHits = await model.searchNotebookContent(
            candidate.machineText,
            notebookID: notebook.id
        )
        XCTAssertEqual(rootChangeCount, 0)
        XCTAssertTrue(repairBecameVisible)
        XCTAssertEqual(visibleHits.map(\.id.documentID), [documentID])
        XCTAssertFalse(model.isLibraryRootChangeInProgress)
        XCTAssertNotNil(model.notice)
    }

    @MainActor
    func testOpenEditorLeaseRefusesRootChangeUntilFinalFlushReleasesIt() async throws {
        let notebook = makeNotebook(title: "Root transition editor lease")
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()
        let lease = try XCTUnwrap(model.beginEditorSession(notebookID: notebook.id))
        let candidateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesEditorLeaseMove-\(UUID().uuidString)")

        await model.useRootDirectory(candidateRoot)

        let refusedRootChanges = await store.rootChangeCallCount
        XCTAssertEqual(refusedRootChanges, 0)
        XCTAssertFalse(model.isLibraryRootChangeInProgress)
        XCTAssertNotNil(model.notice)

        model.endEditorSession(lease)
        await model.useRootDirectory(candidateRoot)

        let completedRootChanges = await store.rootChangeCallCount
        XCTAssertEqual(completedRootChanges, 1)
        XCTAssertFalse(model.isLibraryRootChangeInProgress)
    }

    @MainActor
    func testBrokenInitialLibraryLoadDoesNotPreventRecoveryRootSwitch() async throws {
        let notebook = makeNotebook(title: "Broken current root")
        let suiteName = "NotesAppTests.BrokenRootRecovery.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            initialLibraryLoadFailures: 1
        )
        let model = AppModel(
            store: store,
            searchIndex: SearchIndexSpy(),
            preferences: preferences
        )
        await model.load()

        await model.useRootDirectory(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("NotesBrokenRootRecovery-\(UUID().uuidString)")
        )

        let rootChanges = await store.rootChangeCallCount
        XCTAssertEqual(rootChanges, 1)
        XCTAssertFalse(model.isLibraryRootChangeInProgress)
        let markerCleared = await waitUntil {
            !preferences.bool(forKey: AppModel.searchRootRebuildRequiredKey)
        }
        XCTAssertTrue(markerCleared)
    }

    @MainActor
    func testBlockedInitialLibraryLoadCanBeBypassedByRecoveryRootSwitch() async throws {
        let notebook = makeNotebook(title: "Blocked current root")
        let suiteName = "NotesAppTests.BlockedRootRecovery.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            blocksInitialLoad: true
        )
        let model = AppModel(
            store: store,
            searchIndex: SearchIndexSpy(),
            preferences: preferences,
            libraryRootChangeTimeout: .seconds(1)
        )
        let initialLoad = Task { @MainActor in await model.load() }
        let initialLoadDidBlock = await waitUntil { await store.hasCapturedInitialLoad }
        XCTAssertTrue(initialLoadDidBlock)

        await model.useRootDirectory(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("NotesBlockedRootRecovery-\(UUID().uuidString)")
        )

        let rootChanges = await store.rootChangeCallCount
        XCTAssertEqual(rootChanges, 1)
        XCTAssertFalse(model.isLibraryRootChangeInProgress)
        await store.releaseInitialLoad()
        await initialLoad.value
        let markerCleared = await waitUntil {
            !preferences.bool(forKey: AppModel.searchRootRebuildRequiredKey)
        }
        XCTAssertTrue(markerCleared)
    }

    @MainActor
    func testCandidateLibraryLoadFailureRollsBackAndAllowsRetry() async throws {
        let notebook = makeNotebook(title: "Transactional root")
        let suiteName = "NotesAppTests.RootRollbackMarker.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            rootTransitionLoadFailures: 1
        )
        let model = AppModel(
            store: store,
            searchIndex: SearchIndexSpy(),
            preferences: preferences
        )
        await model.load()
        let candidateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesTransactionalMove-\(UUID().uuidString)")

        await model.useRootDirectory(candidateRoot)

        let failedBeginCount = await store.rootChangeCallCount
        let failedCommitCount = await store.rootCommitCallCount
        let rollbackCount = await store.rootRollbackCallCount
        XCTAssertEqual(failedBeginCount, 1)
        XCTAssertEqual(failedCommitCount, 0)
        XCTAssertEqual(rollbackCount, 1)
        XCTAssertEqual(model.notebooks.map(\.id), [notebook.id])
        XCTAssertFalse(model.isLibraryRootChangeInProgress)
        XCTAssertFalse(preferences.bool(
            forKey: AppModel.searchRootRebuildRequiredKey
        ))

        await model.useRootDirectory(candidateRoot)

        let retriedBeginCount = await store.rootChangeCallCount
        let retriedCommitCount = await store.rootCommitCallCount
        let finalizeCount = await store.rootFinalizeCallCount
        XCTAssertEqual(retriedBeginCount, 2)
        XCTAssertEqual(retriedCommitCount, 1)
        XCTAssertEqual(finalizeCount, 1)
        XCTAssertFalse(model.isLibraryRootChangeInProgress)
        let markerCleared = await waitUntil {
            !preferences.bool(forKey: AppModel.searchRootRebuildRequiredKey)
        }
        XCTAssertTrue(markerCleared)
    }

    @MainActor
    func testLibraryRootChangeSettlesAcademicCandidateAfterNotesCommit() async {
        let store = ControlledNotebookStore(initialNotebooks: [])
        let academic = AcademicRootCoordinatorSpy(notesStore: store)
        let model = AppModel(
            store: store,
            academicRootCoordinator: academic,
            searchIndex: SearchIndexSpy()
        )
        await model.load()

        await model.useRootDirectory(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("NotesAcademicMove-\(UUID().uuidString)")
        )

        XCTAssertEqual(
            academic.events,
            [.prepare, .resolveCandidate, .accept]
        )
        XCTAssertEqual(academic.notesBeginCountsAtPrepare, [0])
        XCTAssertEqual(academic.notesCommitCountsAtResolve, [1])
        XCTAssertEqual(academic.notesFinalizeCountsAtResolve, [0])
        let finalizeCount = await store.rootFinalizeCallCount
        XCTAssertEqual(finalizeCount, 1)
        XCTAssertFalse(model.isLibraryRootChangeInProgress)
    }

    @MainActor
    func testFailedNotesCandidateRollsBackRouteBeforeAcademicWorkspace() async {
        let store = ControlledNotebookStore(
            initialNotebooks: [],
            rootTransitionLoadFailures: 1
        )
        let academic = AcademicRootCoordinatorSpy(notesStore: store)
        let model = AppModel(
            store: store,
            academicRootCoordinator: academic,
            searchIndex: SearchIndexSpy()
        )
        await model.load()

        await model.useRootDirectory(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("NotesAcademicRollback-\(UUID().uuidString)")
        )

        XCTAssertEqual(academic.events, [.prepare, .rollback])
        XCTAssertEqual(academic.notesRollbackCountsAtRollback, [1])
        let rollbackCount = await store.rootRollbackCallCount
        let finalizeCount = await store.rootFinalizeCallCount
        XCTAssertEqual(rollbackCount, 1)
        XCTAssertEqual(finalizeCount, 0)
        XCTAssertFalse(model.isLibraryRootChangeInProgress)
    }

    @MainActor
    func testAcademicPrepareFailureLeavesNotesRouteUntouched() async {
        let store = ControlledNotebookStore(initialNotebooks: [])
        let academic = AcademicRootCoordinatorSpy(
            notesStore: store,
            prepareShouldFail: true
        )
        let model = AppModel(
            store: store,
            academicRootCoordinator: academic,
            searchIndex: SearchIndexSpy()
        )
        await model.load()

        await model.useRootDirectory(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("NotesAcademicRejected-\(UUID().uuidString)")
        )

        XCTAssertEqual(academic.events, [.prepare])
        let rootChangeCount = await store.rootChangeCallCount
        let rootCommitCount = await store.rootCommitCallCount
        let rootRollbackCount = await store.rootRollbackCallCount
        XCTAssertEqual(rootChangeCount, 0)
        XCTAssertEqual(rootCommitCount, 0)
        XCTAssertEqual(rootRollbackCount, 0)
        XCTAssertFalse(model.isLibraryRootChangeInProgress)
        XCTAssertNotNil(model.notice)
    }

    @MainActor
    func testTentativeRootCommitFailureRestoresPreviousSearchAuthorityMarker() async throws {
        let notebook = makeNotebook(title: "Commit marker rollback")
        let suiteName = "NotesAppTests.CommitMarkerRollback.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            rootCommitFailures: 1
        )
        let model = AppModel(
            store: store,
            searchIndex: SearchIndexSpy(),
            preferences: preferences
        )
        await model.load()

        await model.useRootDirectory(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("NotesCommitFailure-\(UUID().uuidString)")
        )

        let commitAttempts = await store.rootCommitCallCount
        let rollbacks = await store.rootRollbackCallCount
        let finalizations = await store.rootFinalizeCallCount
        XCTAssertEqual(commitAttempts, 1)
        XCTAssertEqual(rollbacks, 1)
        XCTAssertEqual(finalizations, 0)
        XCTAssertFalse(preferences.bool(
            forKey: AppModel.searchRootRebuildRequiredKey
        ))
        XCTAssertEqual(model.notebooks.map(\.id), [notebook.id])
        XCTAssertFalse(model.isLibraryRootChangeInProgress)
    }

    @MainActor
    func testDurableImportSurvivesFailedRootSwitchWithNavigationSearch() async throws {
        let existing = makeNotebook(title: "Existing root notebook")
        let store = ControlledNotebookStore(
            initialNotebooks: [existing],
            blocksImport: true,
            importedPageOutlineTitle: "Recovered imported outline",
            importedPageIsBookmarked: true,
            rootCommitFailures: 1
        )
        let search = LocalSearchIndex()
        let model = AppModel(
            store: store,
            searchIndex: search,
            libraryRootChangeTimeout: .seconds(2)
        )
        await model.load()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("Recovered Import.pdf")

        let importTask = Task { @MainActor in
            await model.importDocuments([source])
        }
        let importDidBlock = await waitUntil { await store.hasBlockedImport }
        XCTAssertTrue(importDidBlock)

        let rootChange = Task { @MainActor in
            await model.useRootDirectory(
                FileManager.default.temporaryDirectory.appendingPathComponent(
                    "NotesImportRootFailure-\(UUID().uuidString)"
                )
            )
        }
        let rootDidStart = await waitUntil {
            model.isLibraryRootChangeInProgress
        }
        XCTAssertTrue(rootDidStart)
        await store.releaseImport()
        _ = await importTask.value
        await rootChange.value

        let rootCommitCallCount = await store.rootCommitCallCount
        let rootRollbackCallCount = await store.rootRollbackCallCount
        XCTAssertEqual(rootCommitCallCount, 1)
        XCTAssertEqual(rootRollbackCallCount, 1)
        let importedSummary = try XCTUnwrap(
            model.notebooks.first(where: { $0.title == "Recovered Import" })
        )
        let imported = try await store.loadNotebook(id: importedSummary.id)
        let page = try XCTUnwrap(imported.pages.first)
        let documentID = PageNavigationSearchBuilder.documentID(
            notebookID: imported.id,
            pageID: page.id
        )
        let didRecover = await waitUntil {
            let document = await search.document(for: documentID)
            return document?.segments.map(\.source) == [.outline, .bookmark]
        }
        XCTAssertTrue(didRecover)

        model.searchText = "Recovered imported outline"
        await model.searchIndexedContent()
        XCTAssertEqual(model.matchingNotebookIDs, [imported.id])
        XCTAssertEqual(model.searchTargetPageIDs[imported.id], page.id)
        let bookmarkHits = await model.searchNotebookContent(
            "bookmark",
            notebookID: imported.id
        )
        XCTAssertEqual(bookmarkHits.map(\.pageID), [page.id])
        XCTAssertEqual(bookmarkHits.map(\.segment.source), [.bookmark])
    }

    @MainActor
    func testRootChangeTimeoutDoesNotWaitForUncooperativePageWrite() async throws {
        let notebook = makeNotebook(title: "Bounded root drain")
        let page = try XCTUnwrap(notebook.pages.first)
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            blocksInkSave: true
        )
        let model = AppModel(
            store: store,
            searchIndex: SearchIndexSpy(),
            libraryRootChangeTimeout: .milliseconds(75)
        )
        await model.load()
        model.stageInkForTesting(Data("pending ink".utf8), notebookID: notebook.id, page: page)
        let clock = ContinuousClock()
        let startedAt = clock.now

        await model.useRootDirectory(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("NotesBoundedMove-\(UUID().uuidString)")
        )

        let elapsed = startedAt.duration(to: clock.now)
        let rootChangeCount = await store.rootChangeCallCount
        XCTAssertLessThan(elapsed, .seconds(1))
        XCTAssertEqual(rootChangeCount, 0)
        XCTAssertFalse(model.isLibraryRootChangeInProgress)
        XCTAssertNotNil(model.notice)

        await store.releaseInkSave()
        let cleanupFlushSucceeded = await model.flushInk(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertTrue(cleanupFlushSucceeded)
    }

    @MainActor
    func testRootChangeWaitsForActiveNotebookExportSession() async throws {
        let notebook = makeNotebook(title: "Export root fence")
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()
        let session = try await model.beginNotebookExport(id: notebook.id)

        let rootChangeTask = Task { @MainActor in
            await model.useRootDirectory(
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("NotesExportMove-\(UUID().uuidString)")
            )
        }
        let rootChangeStarted = await waitUntil {
            model.isLibraryRootChangeInProgress
        }
        XCTAssertTrue(rootChangeStarted)
        let rootChangesWhileExporting = await store.rootChangeCallCount
        XCTAssertEqual(rootChangesWhileExporting, 0)
        let validatedDuringDrain = try await model.validateNotebookExportSession(session)
        XCTAssertEqual(validatedDuringDrain.id, notebook.id)

        await model.endNotebookExport(session)
        await rootChangeTask.value

        let rootChangesAfterExport = await store.rootChangeCallCount
        XCTAssertEqual(rootChangesAfterExport, 1)
        XCTAssertFalse(model.isLibraryRootChangeInProgress)
    }

    @MainActor
    func testCancelledExportAcquisitionDoesNotLeakLibraryOperation() async throws {
        let notebook = makeNotebook(title: "Cancelled export acquisition")
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let model = AppModel(
            store: store,
            searchIndex: SearchIndexSpy(),
            libraryRootChangeTimeout: .seconds(1)
        )
        await model.load()
        let startGate = AsyncGate(isOpen: false)
        let export = Task { @MainActor in
            await startGate.wait()
            do {
                _ = try await model.beginNotebookExport(id: notebook.id)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        export.cancel()
        await startGate.open()
        let cancellationWasObserved = await export.value
        XCTAssertTrue(cancellationWasObserved)

        await model.useRootDirectory(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("NotesCancelledExportMove-\(UUID().uuidString)")
        )

        let rootChanges = await store.rootChangeCallCount
        XCTAssertEqual(rootChanges, 1)
        XCTAssertFalse(model.isLibraryRootChangeInProgress)
    }

    @MainActor
    func testCommittedRootSearchStaysFailClosedUntilOldIndexIsCleared() async throws {
        var notebook = makeNotebook(title: "Search root fence")
        notebook.pages[0].outlineTitle = "Root-safe outline"
        notebook.pages[0].isBookmarked = true
        let suiteName = "NotesAppTests.RootSearchMarker.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let page = try XCTUnwrap(notebook.pages.first)
        let documentID = UUID()
        let segment = RecognizedTextSegment(
            text: "old root private text",
            pageID: page.id,
            source: .scannedImage
        )
        let staleHit = LocalSearchSegmentHit(
            documentID: documentID,
            notebookID: notebook.id,
            pageID: page.id,
            title: notebook.title,
            snippet: segment.text,
            score: 1,
            segment: segment
        )
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let search = SearchIndexSpy(segmentQueryResponse: [staleHit])
        let model = AppModel(
            store: store,
            searchIndex: search,
            preferences: preferences
        )
        await model.load()
        await search.blockNextEmptyNotebookRetention()

        await model.useRootDirectory(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("NotesSearchFenceMove-\(UUID().uuidString)")
        )
        let rebuildDidBlock = await waitUntil {
            await search.hasBlockedEmptyNotebookRetention
        }
        XCTAssertTrue(rebuildDidBlock)
        XCTAssertTrue(preferences.bool(
            forKey: AppModel.searchRootRebuildRequiredKey
        ))

        let hiddenDuringClear = await model.searchNotebookContent(
            segment.text,
            notebookID: notebook.id
        )
        XCTAssertTrue(hiddenDuringClear.isEmpty)

        await search.releaseEmptyNotebookRetention()
        let searchBecameReady = await waitUntil {
            let hits = await model.searchNotebookContent(
                segment.text,
                notebookID: notebook.id
            )
            return !hits.isEmpty
        }
        XCTAssertTrue(searchBecameReady)
        XCTAssertFalse(preferences.bool(
            forKey: AppModel.searchRootRebuildRequiredKey
        ))
        let navigationDocumentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        let rebuiltNavigation = await search.document(id: navigationDocumentID)
        XCTAssertEqual(
            rebuiltNavigation?.segments.map(\.source),
            [.outline, .bookmark]
        )
    }

    @MainActor
    func testColdBootstrapKeepsSearchClosedUntilDurableRootClearRetries() async throws {
        let notebook = makeNotebook(title: "Cold search authority fence")
        let page = try XCTUnwrap(notebook.pages.first)
        let suiteName = "NotesAppTests.ColdSearchMarker.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(true, forKey: AppModel.searchRootRebuildRequiredKey)
        let segment = RecognizedTextSegment(
            text: "previous root secret",
            pageID: page.id,
            source: .scannedImage
        )
        let search = SearchIndexSpy(
            segmentQueryResponse: [LocalSearchSegmentHit(
                documentID: UUID(),
                notebookID: notebook.id,
                pageID: page.id,
                title: notebook.title,
                snippet: segment.text,
                score: 1,
                segment: segment
            )],
            emptyNotebookRetentionFailures: 1
        )
        let model = AppModel(
            store: ControlledNotebookStore(initialNotebooks: [notebook]),
            searchIndex: search,
            preferences: preferences
        )

        await model.load()

        XCTAssertTrue(preferences.bool(
            forKey: AppModel.searchRootRebuildRequiredKey
        ))
        await search.blockNextEmptyNotebookRetention()
        let hidden = await model.searchNotebookContent(
            segment.text,
            notebookID: notebook.id
        )
        XCTAssertTrue(hidden.isEmpty)
        let retryDidBlock = await waitUntil {
            await search.hasBlockedEmptyNotebookRetention
        }
        XCTAssertTrue(retryDidBlock)
        XCTAssertTrue(preferences.bool(
            forKey: AppModel.searchRootRebuildRequiredKey
        ))

        await search.releaseEmptyNotebookRetention()
        let markerCleared = await waitUntil {
            !preferences.bool(forKey: AppModel.searchRootRebuildRequiredKey)
        }
        XCTAssertTrue(markerCleared)
    }

    @MainActor
    func testSegmentQueryStartedBeforeRootSwitchCannotReturnOldRootHit() async throws {
        let notebook = makeNotebook(title: "Blocked root query")
        let page = try XCTUnwrap(notebook.pages.first)
        let suiteName = "NotesAppTests.QueryRootFence.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let segment = RecognizedTextSegment(
            text: "old root query result",
            pageID: page.id,
            source: .scannedImage
        )
        let search = SearchIndexSpy(segmentQueryResponse: [LocalSearchSegmentHit(
            documentID: UUID(),
            notebookID: notebook.id,
            pageID: page.id,
            title: notebook.title,
            snippet: segment.text,
            score: 1,
            segment: segment
        )])
        let model = AppModel(
            store: ControlledNotebookStore(initialNotebooks: [notebook]),
            searchIndex: search,
            preferences: preferences
        )
        await model.load()
        await search.blockNextSegmentQuery()

        let oldQuery = Task { @MainActor in
            await model.searchNotebookContent(
                segment.text,
                notebookID: notebook.id
            )
        }
        let queryDidBlock = await waitUntil { await search.hasBlockedSegmentQuery }
        XCTAssertTrue(queryDidBlock)

        await model.useRootDirectory(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("NotesQueryFenceMove-\(UUID().uuidString)")
        )
        await search.releaseSegmentQuery()
        let staleHits = await oldQuery.value

        XCTAssertTrue(staleHits.isEmpty)
        let markerCleared = await waitUntil {
            !preferences.bool(forKey: AppModel.searchRootRebuildRequiredKey)
        }
        XCTAssertTrue(markerCleared)
    }

    @MainActor
    func testExpiredEditorLeaseCannotMutateCommittedRoot() async throws {
        let notebook = makeNotebook(title: "Expired editor root fence")
        let page = try XCTUnwrap(notebook.pages.first)
        let suiteName = "NotesAppTests.EditorGenerationFence.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let model = AppModel(
            store: store,
            searchIndex: SearchIndexSpy(),
            preferences: preferences
        )
        await model.load()
        let staleLease = try XCTUnwrap(model.beginEditorSession(notebookID: notebook.id))
        model.endEditorSession(staleLease)

        await model.useRootDirectory(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("NotesExpiredEditorMove-\(UUID().uuidString)")
        )
        let markerCleared = await waitUntil {
            !preferences.bool(forKey: AppModel.searchRootRebuildRequiredKey)
        }
        XCTAssertTrue(markerCleared)

        let accepted = model.stageInk(
            Data("obsolete editor ink".utf8),
            notebookID: notebook.id,
            page: page,
            editorSession: staleLease
        )
        let savedPayloads = await store.savedInkPayloads
        let structuralResult = await model.addPage(
            to: notebook,
            editorSession: staleLease
        )
        let savedPageSequences = await store.savedPageIDSequences
        XCTAssertFalse(accepted)
        XCTAssertTrue(savedPayloads.isEmpty)
        XCTAssertNil(structuralResult)
        XCTAssertTrue(savedPageSequences.isEmpty)
    }

    @MainActor
    func testPageNavigationMetadataUpdatePublishesCanonicalAuthoritativeNotebook() async throws {
        let notebook = makeNotebook(title: "Navigation metadata")
        let page = try XCTUnwrap(notebook.pages.first)
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()
        let lease = try XCTUnwrap(
            model.beginEditorSession(notebookID: notebook.id)
        )
        defer { model.endEditorSession(lease) }

        let bookmarked = await model.updatePageNavigationMetadata(
            in: notebook,
            pageID: page.id,
            update: .bookmark(true),
            editorSession: lease
        )
        let updated = await model.updatePageNavigationMetadata(
            in: notebook,
            pageID: page.id,
            update: .outlineTitle("  Chapter\n   One  "),
            editorSession: lease
        )

        XCTAssertTrue(try XCTUnwrap(bookmarked?.pages.first).isBookmarked)
        let updatedPage = try XCTUnwrap(updated?.pages.first)
        XCTAssertTrue(updatedPage.isBookmarked)
        XCTAssertEqual(updatedPage.outlineTitle, "Chapter One")
        XCTAssertEqual(model.notebooks.first?.modifiedAt, updated?.modifiedAt)
        let stored = try await store.loadNotebook(id: notebook.id)
        XCTAssertEqual(stored, updated)
    }

    @MainActor
    func testCancelledDurableNavigationMetadataUpdateRecoversSearch() async throws {
        let notebook = makeNotebook(title: "Cancelled navigation update")
        let page = try XCTUnwrap(notebook.pages.first)
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let search = LocalSearchIndex()
        let model = AppModel(store: store, searchIndex: search)
        await model.load()
        let lease = try XCTUnwrap(
            model.beginEditorSession(notebookID: notebook.id)
        )
        defer { model.endEditorSession(lease) }
        await store.blockNextPageNavigationMetadataUpdate()

        let update = Task { @MainActor in
            await model.updatePageNavigationMetadata(
                in: notebook,
                pageID: page.id,
                update: .outlineTitle("Recovered durable outline"),
                editorSession: lease
            )
        }
        let didBlock = await waitUntil {
            await store.hasBlockedPageNavigationMetadataUpdate
        }
        XCTAssertTrue(didBlock)

        update.cancel()
        await store.releasePageNavigationMetadataUpdate()
        let cancelledResult = await update.value
        XCTAssertNil(cancelledResult)

        let documentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        let didRecover = await waitUntil {
            let document = await search.document(for: documentID)
            return document?.segments.first?.text == "Recovered durable outline"
        }
        XCTAssertTrue(didRecover)
        model.searchText = "Recovered durable outline"
        await model.searchIndexedContent()
        XCTAssertEqual(model.matchingNotebookIDs, [notebook.id])
        let editorHits = await model.searchNotebookContent(
            "Recovered durable outline",
            notebookID: notebook.id
        )
        XCTAssertEqual(editorHits.map(\.pageID), [page.id])
    }

    @MainActor
    func testBootstrapIndexesPageOutlineAndBookmarkForLibraryAndEditorSearch() async throws {
        var notebook = makeNotebook(title: "Navigation search bootstrap")
        notebook.pages[0].outlineTitle = "Thermodynamics review"
        notebook.pages[0].isBookmarked = true
        let pageID = notebook.pages[0].id
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let search = LocalSearchIndex()
        let model = AppModel(store: store, searchIndex: search)

        await model.load()

        let navigationDocumentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: pageID
        )
        let document = await search.document(for: navigationDocumentID)
        XCTAssertEqual(document?.segments.map(\.source), [.outline, .bookmark])
        XCTAssertEqual(document?.segments.first?.text, "Thermodynamics review")

        model.searchText = "Thermodynamics"
        await model.searchIndexedContent()
        XCTAssertEqual(model.matchingNotebookIDs, [notebook.id])
        XCTAssertEqual(model.searchTargetPageIDs[notebook.id], pageID)
        let outlineHits = await model.searchNotebookContent(
            "Thermodynamics",
            notebookID: notebook.id
        )
        XCTAssertEqual(outlineHits.map(\.pageID), [pageID])
        XCTAssertEqual(outlineHits.map(\.segment.source), [.outline])

        model.searchText = "bookmark"
        await model.searchIndexedContent()
        XCTAssertEqual(model.matchingNotebookIDs, [notebook.id])
        XCTAssertEqual(model.searchTargetPageIDs[notebook.id], pageID)
        let bookmarkHits = await model.searchNotebookContent(
            "書籤",
            notebookID: notebook.id
        )
        XCTAssertEqual(bookmarkHits.map(\.pageID), [pageID])
        XCTAssertEqual(bookmarkHits.map(\.segment.source), [.bookmark])
    }

    @MainActor
    func testExactBookmarkLibraryQueryCannotBeBypassedByNotebookTitle() async throws {
        let titleMatch = makeNotebook(title: "Bookmark research")
        var bookmarked = makeNotebook(title: "Travel plans")
        bookmarked.pages[0].isBookmarked = true
        let bookmarkedPageID = bookmarked.pages[0].id
        let model = AppModel(
            store: ControlledNotebookStore(
                initialNotebooks: [titleMatch, bookmarked]
            ),
            searchIndex: LocalSearchIndex()
        )

        await model.load()
        model.searchText = "bookmark"
        await model.searchIndexedContent()

        XCTAssertEqual(
            Set(model.visibleNotebooks.map(\.id)),
            [bookmarked.id]
        )
        XCTAssertEqual(
            model.searchTargetPageIDs[bookmarked.id],
            bookmarkedPageID
        )
        XCTAssertNil(model.searchTargetPageIDs[titleMatch.id])

        model.searchText = "book"
        await model.searchIndexedContent()

        XCTAssertEqual(
            Set(model.visibleNotebooks.map(\.id)),
            [titleMatch.id]
        )
        XCTAssertTrue(model.searchTargetPageIDs.isEmpty)
    }

    @MainActor
    func testBootstrapPrunesRawPageSearchOrphanAfterInterruptedDelete() async throws {
        let notebook = makeNotebook(title: "Raw orphan recovery")
        let orphanPageID = UUID()
        let orphanText = "interrupted delete OCR sentinel"
        let orphan = SearchIndexDocument(
            id: orphanPageID,
            notebookID: notebook.id,
            pageID: orphanPageID,
            title: notebook.title,
            revision: 9,
            segments: [RecognizedTextSegment(
                text: orphanText,
                pageID: orphanPageID,
                source: .scannedImage
            )]
        )
        let search = LocalSearchIndex()
        try await search.upsert(orphan)
        let model = AppModel(
            store: ControlledNotebookStore(initialNotebooks: [notebook]),
            searchIndex: search
        )

        await model.load()

        let retainedOrphan = await search.document(for: orphanPageID)
        let orphanHits = await search.query(
            orphanText,
            notebookID: notebook.id,
            limit: 10
        )
        XCTAssertNil(retainedOrphan)
        XCTAssertTrue(orphanHits.isEmpty)
    }

    @MainActor
    func testAuthorizedNavigationDocumentRejectsForgedPageTarget() async throws {
        var notebook = makeNotebook(title: "Navigation target authority")
        notebook.pages[0].outlineTitle = "Authorized outline"
        let realPageID = notebook.pages[0].id
        let forgedPageID = UUID()
        let documentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: realPageID
        )
        let forgedSegment = RecognizedTextSegment(
            text: "Authorized outline",
            pageID: forgedPageID,
            source: .outline
        )
        let authorizedFingerprint = PageNavigationSearchBuilder
            .sourceFingerprint(for: PageNavigationSearchBuilder.segments(
                for: notebook.pages[0],
                notebookID: notebook.id
            ))
        let search = SearchIndexSpy(
            queryResponse: [LocalSearchHit(
                documentID: documentID,
                notebookID: notebook.id,
                pageID: forgedPageID,
                title: notebook.title,
                snippet: forgedSegment.text,
                score: 7.5,
                segment: forgedSegment,
                sourceFingerprint: authorizedFingerprint
            )],
            segmentQueryResponse: [LocalSearchSegmentHit(
                documentID: documentID,
                notebookID: notebook.id,
                pageID: forgedPageID,
                title: notebook.title,
                snippet: forgedSegment.text,
                score: 7.5,
                segment: forgedSegment,
                sourceFingerprint: authorizedFingerprint
            )]
        )
        let model = AppModel(
            store: ControlledNotebookStore(initialNotebooks: [notebook]),
            searchIndex: search
        )
        await model.load()

        model.searchText = forgedSegment.text
        await model.searchIndexedContent()
        XCTAssertEqual(model.matchingNotebookIDs, [])
        let editorHits = await model.searchNotebookContent(
            forgedSegment.text,
            notebookID: notebook.id
        )
        XCTAssertTrue(editorHits.isEmpty)
    }

    @MainActor
    func testAuthorizedNavigationDocumentRejectsSiblingFingerprint() async throws {
        var notebook = makeNotebook(title: "Navigation fingerprint authority")
        notebook.pages[0].outlineTitle = "Shared authorized outline"
        let page = notebook.pages[0]
        let documentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        let authorizedSegment = try XCTUnwrap(
            PageNavigationSearchBuilder.segments(
                for: page,
                notebookID: notebook.id
            ).first
        )
        var siblingPage = page
        siblingPage.isBookmarked = true
        let authorizedFingerprint = PageNavigationSearchBuilder
            .sourceFingerprint(for: [authorizedSegment])
        let siblingFingerprint = PageNavigationSearchBuilder.sourceFingerprint(
            for: PageNavigationSearchBuilder.segments(
                for: siblingPage,
                notebookID: notebook.id
            )
        )
        let authorizedLibraryHit = LocalSearchHit(
            documentID: documentID,
            notebookID: notebook.id,
            pageID: page.id,
            title: notebook.title,
            snippet: authorizedSegment.text,
            score: 7.5,
            segment: authorizedSegment,
            sourceFingerprint: authorizedFingerprint
        )
        let authorizedEditorHit = LocalSearchSegmentHit(
            documentID: documentID,
            notebookID: notebook.id,
            pageID: page.id,
            title: notebook.title,
            snippet: authorizedSegment.text,
            score: 7.5,
            segment: authorizedSegment,
            sourceFingerprint: authorizedFingerprint
        )
        let search = SearchIndexSpy(
            queryResponse: [authorizedLibraryHit],
            segmentQueryResponse: [authorizedEditorHit]
        )
        let model = AppModel(
            store: ControlledNotebookStore(initialNotebooks: [notebook]),
            searchIndex: search
        )
        await model.load()

        model.searchText = authorizedSegment.text
        await model.searchIndexedContent()
        XCTAssertEqual(model.matchingNotebookIDs, [notebook.id])
        let authorizedEditorHits = await model.searchNotebookContent(
            authorizedSegment.text,
            notebookID: notebook.id
        )
        XCTAssertEqual(authorizedEditorHits.map(\.pageID), [page.id])

        await search.setQueryResponses(
            library: [LocalSearchHit(
                documentID: documentID,
                notebookID: notebook.id,
                pageID: page.id,
                title: notebook.title,
                snippet: authorizedSegment.text,
                score: 7.5,
                segment: authorizedSegment,
                sourceFingerprint: siblingFingerprint
            )],
            editor: [LocalSearchSegmentHit(
                documentID: documentID,
                notebookID: notebook.id,
                pageID: page.id,
                title: notebook.title,
                snippet: authorizedSegment.text,
                score: 7.5,
                segment: authorizedSegment,
                sourceFingerprint: siblingFingerprint
            )]
        )

        await model.searchIndexedContent()
        XCTAssertEqual(model.matchingNotebookIDs, [])
        let editorHits = await model.searchNotebookContent(
            authorizedSegment.text,
            notebookID: notebook.id
        )
        XCTAssertTrue(editorHits.isEmpty)
    }

    @MainActor
    func testBootstrapRetainFailureCannotAuthorizeNavigationOrphan() async throws {
        let notebook = makeNotebook(title: "Navigation orphan authority")
        let orphanPageID = UUID()
        let documentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: orphanPageID
        )
        let orphanSegment = RecognizedTextSegment(
            text: "Orphan bookmark metadata",
            pageID: orphanPageID,
            source: .bookmark
        )
        let orphanFingerprint = PageNavigationSearchBuilder
            .sourceFingerprint(for: [orphanSegment])
        let orphanDocument = SearchIndexDocument(
            id: documentID,
            notebookID: notebook.id,
            pageID: orphanPageID,
            title: notebook.title,
            revision: 1,
            sourceFingerprint: orphanFingerprint,
            segments: [orphanSegment]
        )
        let search = SearchIndexSpy(
            documents: [orphanDocument],
            queryResponse: [LocalSearchHit(
                documentID: documentID,
                notebookID: notebook.id,
                pageID: orphanPageID,
                title: notebook.title,
                snippet: orphanSegment.text,
                score: 7.5,
                segment: orphanSegment,
                sourceFingerprint: orphanFingerprint
            )],
            segmentQueryResponse: [LocalSearchSegmentHit(
                documentID: documentID,
                notebookID: notebook.id,
                pageID: orphanPageID,
                title: notebook.title,
                snippet: orphanSegment.text,
                score: 7.5,
                segment: orphanSegment,
                sourceFingerprint: orphanFingerprint
            )],
            failingRetainSources: [.bookmark]
        )
        let model = AppModel(
            store: ControlledNotebookStore(initialNotebooks: [notebook]),
            searchIndex: search
        )

        await model.load()

        let retainedOrphan = await search.document(id: documentID)
        XCTAssertNotNil(retainedOrphan)
        model.searchText = orphanSegment.text
        await model.searchIndexedContent()
        XCTAssertEqual(model.matchingNotebookIDs, [])
        let editorHits = await model.searchNotebookContent(
            orphanSegment.text,
            notebookID: notebook.id
        )
        XCTAssertTrue(editorHits.isEmpty)
    }

    @MainActor
    func testPageNavigationMetadataMutationReplacesAndClearsDerivedDocument() async throws {
        let notebook = makeNotebook(title: "Navigation mutation index")
        let page = try XCTUnwrap(notebook.pages.first)
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let search = SearchIndexSpy()
        let model = AppModel(store: store, searchIndex: search)
        await model.load()
        let lease = try XCTUnwrap(model.beginEditorSession(notebookID: notebook.id))
        defer { model.endEditorSession(lease) }
        let documentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )

        _ = await model.updatePageNavigationMetadata(
            in: notebook,
            pageID: page.id,
            update: .outlineTitle("Indexed chapter"),
            editorSession: lease
        )
        _ = await model.updatePageNavigationMetadata(
            in: notebook,
            pageID: page.id,
            update: .bookmark(true),
            editorSession: lease
        )

        var document = await search.document(id: documentID)
        XCTAssertEqual(document?.segments.map(\.source), [.outline, .bookmark])
        XCTAssertEqual(document?.segments.first?.text, "Indexed chapter")

        _ = await model.updatePageNavigationMetadata(
            in: notebook,
            pageID: page.id,
            update: .outlineTitle(nil),
            editorSession: lease
        )
        document = await search.document(id: documentID)
        XCTAssertEqual(document?.segments.map(\.source), [.bookmark])

        _ = await model.updatePageNavigationMetadata(
            in: notebook,
            pageID: page.id,
            update: .bookmark(false),
            editorSession: lease
        )
        document = await search.document(id: documentID)
        XCTAssertNil(document)
    }

    @MainActor
    func testRenameReindexesExistingNavigationDocumentTitle() async throws {
        var notebook = makeNotebook(title: "Original navigation title")
        notebook.pages[0].outlineTitle = "Stable outline"
        notebook.pages[0].isBookmarked = true
        let pageID = notebook.pages[0].id
        let search = SearchIndexSpy()
        let model = AppModel(
            store: ControlledNotebookStore(initialNotebooks: [notebook]),
            searchIndex: search
        )
        await model.load()

        await model.rename(notebook.summary, to: "Renamed navigation title")

        let documentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: pageID
        )
        let document = await search.document(id: documentID)
        XCTAssertEqual(document?.title, "Renamed navigation title")
        XCTAssertEqual(document?.segments.map(\.source), [.outline, .bookmark])
        XCTAssertEqual(document?.segments.first?.text, "Stable outline")
    }

    @MainActor
    func testCancelledRenameAfterDurableSaveRecoversEverySearchTitle() async throws {
        let fixture = try await makeRenameSearchRecoveryFixture()
        let expectedTitle = "Durably renamed after cancellation"
        await fixture.store.blockNextNotebookSaveReturn()
        let rename = Task { @MainActor in
            await fixture.model.rename(
                fixture.notebook.summary,
                to: expectedTitle
            )
        }
        let didBlock = await waitUntil {
            await fixture.store.hasBlockedNotebookSaveReturn
        }
        XCTAssertTrue(didBlock)
        let durableAtCancellation = await fixture.store.persistedNotebook(
            id: fixture.notebook.id
        )
        XCTAssertEqual(durableAtCancellation?.title, expectedTitle)

        rename.cancel()
        await fixture.store.releaseNotebookSaveReturn()
        await rename.value

        let didRecover = await waitUntil {
            await self.didRecoverRenameSearchState(
                fixture,
                expectedTitle: expectedTitle
            )
        }
        XCTAssertTrue(didRecover)
        await assertRecoveredRenameSearch(
            fixture,
            expectedTitle: expectedTitle
        )
    }

    @MainActor
    func testFailedRootSwitchAfterDurableRenameRecoversEverySearchTitle() async throws {
        let fixture = try await makeRenameSearchRecoveryFixture(
            rootCommitFailures: 1
        )
        let expectedTitle = "Durably renamed before root rollback"
        await fixture.store.blockNextNotebookSaveReturn()
        let rename = Task { @MainActor in
            await fixture.model.rename(
                fixture.notebook.summary,
                to: expectedTitle
            )
        }
        let saveDidCommit = await waitUntil {
            await fixture.store.hasBlockedNotebookSaveReturn
        }
        XCTAssertTrue(saveDidCommit)
        let durableBeforeRoot = await fixture.store.persistedNotebook(
            id: fixture.notebook.id
        )
        XCTAssertEqual(durableBeforeRoot?.title, expectedTitle)
        let searchStillHasPreSaveTitle = await didRecoverAllRenameSearchTitles(
            fixture,
            expectedTitle: fixture.notebook.title
        )
        XCTAssertTrue(searchStillHasPreSaveTitle)

        let rootChange = Task { @MainActor in
            await fixture.model.useRootDirectory(
                FileManager.default.temporaryDirectory.appendingPathComponent(
                    "NotesDurableRenameRootFailure-\(UUID().uuidString)"
                )
            )
        }
        let rootDidStart = await waitUntil {
            fixture.model.isLibraryRootChangeInProgress
        }
        XCTAssertTrue(rootDidStart)
        await fixture.store.releaseNotebookSaveReturn()
        await rename.value
        await rootChange.value

        let rootCommitCallCount = await fixture.store.rootCommitCallCount
        let rootRollbackCallCount = await fixture.store.rootRollbackCallCount
        XCTAssertEqual(rootCommitCallCount, 1)
        XCTAssertEqual(rootRollbackCallCount, 1)
        let didRecover = await waitUntil {
            await self.didRecoverRenameSearchState(
                fixture,
                expectedTitle: expectedTitle
            )
        }
        XCTAssertTrue(didRecover)
        await assertRecoveredRenameSearch(
            fixture,
            expectedTitle: expectedTitle
        )
    }

    @MainActor
    func testDurableRenameReturningAfterRootTimeoutUsesCurrentRecoveryEpoch() async throws {
        let fixture = try await makeRenameSearchRecoveryFixture(
            libraryRootChangeTimeout: .milliseconds(150)
        )
        let expectedTitle = "Durable rename after root timeout"
        await fixture.store.blockNextNotebookSaveReturn()
        let rename = Task { @MainActor in
            await fixture.model.rename(
                fixture.notebook.summary,
                to: expectedTitle
            )
        }
        let saveDidCommit = await waitUntil {
            await fixture.store.hasBlockedNotebookSaveReturn
        }
        XCTAssertTrue(saveDidCommit)
        let durableBeforeTimeout = await fixture.store.persistedNotebook(
            id: fixture.notebook.id
        )
        XCTAssertEqual(durableBeforeTimeout?.title, expectedTitle)

        let rootChange = Task { @MainActor in
            await fixture.model.useRootDirectory(
                FileManager.default.temporaryDirectory.appendingPathComponent(
                    "NotesLateDurableRename-\(UUID().uuidString)"
                )
            )
        }
        let rootDidStart = await waitUntil {
            fixture.model.isLibraryRootChangeInProgress
        }
        XCTAssertTrue(rootDidStart)
        await rootChange.value
        XCTAssertFalse(fixture.model.isLibraryRootChangeInProgress)
        let rootCommitCallCount = await fixture.store.rootCommitCallCount
        XCTAssertEqual(rootCommitCallCount, 0)

        await fixture.store.releaseNotebookSaveReturn()
        await rename.value
        let didRecover = await waitUntil {
            await self.didRecoverRenameSearchState(
                fixture,
                expectedTitle: expectedTitle
            )
        }
        XCTAssertTrue(didRecover)
        await assertRecoveredRenameSearch(
            fixture,
            expectedTitle: expectedTitle
        )
    }

    @MainActor
    func testNavigationRemovalFailureSuppressesClearedMetadataInBothSearchSurfaces() async throws {
        var notebook = makeNotebook(title: "Navigation removal failure")
        notebook.pages[0].outlineTitle = "Cleared private outline"
        notebook.pages[0].isBookmarked = true
        let page = notebook.pages[0]
        let documentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        let bookmarkSegment = try XCTUnwrap(
            PageNavigationSearchBuilder.segments(
                for: page,
                notebookID: notebook.id
            ).first(where: { $0.source == .bookmark })
        )
        let search = SearchIndexSpy(
            queryResponse: [LocalSearchHit(
                documentID: documentID,
                notebookID: notebook.id,
                pageID: page.id,
                title: notebook.title,
                snippet: "bookmark",
                score: 7.5,
                segment: bookmarkSegment
            )],
            segmentQueryResponse: [LocalSearchSegmentHit(
                documentID: documentID,
                notebookID: notebook.id,
                pageID: page.id,
                title: notebook.title,
                snippet: "bookmark",
                score: 7.5,
                segment: bookmarkSegment
            )],
            failingRemoveDocumentIDs: [documentID]
        )
        let model = AppModel(
            store: ControlledNotebookStore(initialNotebooks: [notebook]),
            searchIndex: search
        )
        await model.load()
        let lease = try XCTUnwrap(model.beginEditorSession(notebookID: notebook.id))
        defer { model.endEditorSession(lease) }

        _ = await model.updatePageNavigationMetadata(
            in: notebook,
            pageID: page.id,
            update: .outlineTitle(nil),
            editorSession: lease
        )
        _ = await model.updatePageNavigationMetadata(
            in: notebook,
            pageID: page.id,
            update: .bookmark(false),
            editorSession: lease
        )

        let staleDocument = await search.document(id: documentID)
        XCTAssertNotNil(staleDocument)
        model.searchText = "bookmark"
        await model.searchIndexedContent()
        XCTAssertEqual(model.matchingNotebookIDs, [])
        let editorHits = await model.searchNotebookContent(
            "bookmark",
            notebookID: notebook.id
        )
        XCTAssertTrue(editorHits.isEmpty)
    }

    @MainActor
    func testClearedNavigationTombstoneHidesUpsertThatCommitsAfterRemoval() async throws {
        var notebook = makeNotebook(title: "Navigation late upsert tombstone")
        notebook.pages[0].outlineTitle = "Original outline"
        let page = notebook.pages[0]
        let documentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        let staleSegment = RecognizedTextSegment(
            text: "Late resurrected outline",
            pageID: page.id,
            source: .outline
        )
        let search = SearchIndexSpy(
            queryResponse: [LocalSearchHit(
                documentID: documentID,
                notebookID: notebook.id,
                pageID: page.id,
                title: notebook.title,
                snippet: staleSegment.text,
                score: 7.5,
                segment: staleSegment
            )],
            segmentQueryResponse: [LocalSearchSegmentHit(
                documentID: documentID,
                notebookID: notebook.id,
                pageID: page.id,
                title: notebook.title,
                snippet: staleSegment.text,
                score: 7.5,
                segment: staleSegment
            )]
        )
        let model = AppModel(
            store: ControlledNotebookStore(initialNotebooks: [notebook]),
            searchIndex: search
        )
        await model.load()
        let lease = try XCTUnwrap(model.beginEditorSession(notebookID: notebook.id))
        defer { model.endEditorSession(lease) }
        await search.blockNextUpsert(documentID)

        let staleUpdate = Task { @MainActor in
            await model.updatePageNavigationMetadata(
                in: notebook,
                pageID: page.id,
                update: .outlineTitle(staleSegment.text),
                editorSession: lease
            )
        }
        let didBlock = await waitUntil { await search.hasBlockedUpsert }
        XCTAssertTrue(didBlock)

        _ = await model.updatePageNavigationMetadata(
            in: notebook,
            pageID: page.id,
            update: .outlineTitle(nil),
            editorSession: lease
        )
        await search.releaseBlockedUpsert()
        _ = await staleUpdate.value

        let didRemoveLateResurrection = await waitUntil {
            await search.document(id: documentID) == nil
        }
        XCTAssertTrue(didRemoveLateResurrection)
        model.searchText = staleSegment.text
        await model.searchIndexedContent()
        XCTAssertEqual(model.matchingNotebookIDs, [])
        let editorHits = await model.searchNotebookContent(
            staleSegment.text,
            notebookID: notebook.id
        )
        XCTAssertTrue(editorHits.isEmpty)
    }

    @MainActor
    func testLateNavigationRemovalCannotEraseNewerPresentPayload() async throws {
        var notebook = makeNotebook(title: "Navigation late remove")
        notebook.pages[0].outlineTitle = "Initial removable outline"
        let page = notebook.pages[0]
        let documentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        var latestPage = page
        latestPage.outlineTitle = "Latest outline survives remove"
        let latestSegments = PageNavigationSearchBuilder.segments(
            for: latestPage,
            notebookID: notebook.id
        )
        let latestSegment = try XCTUnwrap(latestSegments.first)
        let latestFingerprint = PageNavigationSearchBuilder
            .sourceFingerprint(for: latestSegments)
        let search = SearchIndexSpy(
            queryResponse: [LocalSearchHit(
                documentID: documentID,
                notebookID: notebook.id,
                pageID: page.id,
                title: notebook.title,
                snippet: latestSegment.text,
                score: 7.5,
                segment: latestSegment,
                sourceFingerprint: latestFingerprint
            )],
            segmentQueryResponse: [LocalSearchSegmentHit(
                documentID: documentID,
                notebookID: notebook.id,
                pageID: page.id,
                title: notebook.title,
                snippet: latestSegment.text,
                score: 7.5,
                segment: latestSegment,
                sourceFingerprint: latestFingerprint
            )]
        )
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let model = AppModel(store: store, searchIndex: search)
        await model.load()
        let lease = try XCTUnwrap(
            model.beginEditorSession(notebookID: notebook.id)
        )
        defer { model.endEditorSession(lease) }
        await search.blockNextRemove(documentID)

        let staleClear = Task { @MainActor in
            await model.updatePageNavigationMetadata(
                in: notebook,
                pageID: page.id,
                update: .outlineTitle(nil),
                editorSession: lease
            )
        }
        let didBlock = await waitUntil { await search.hasBlockedRemove }
        XCTAssertTrue(didBlock)

        _ = await model.updatePageNavigationMetadata(
            in: notebook,
            pageID: page.id,
            update: .outlineTitle(latestSegment.text),
            editorSession: lease
        )
        await search.releaseBlockedRemove()
        _ = await staleClear.value

        let didRecover = await waitUntil {
            let document = await search.document(id: documentID)
            return document?.segments.first?.text == latestSegment.text
        }
        XCTAssertTrue(didRecover)
        model.searchText = latestSegment.text
        await model.searchIndexedContent()
        XCTAssertEqual(model.matchingNotebookIDs, [notebook.id])
        let editorHits = await model.searchNotebookContent(
            latestSegment.text,
            notebookID: notebook.id
        )
        XCTAssertEqual(editorHits.map(\.pageID), [page.id])
    }

    @MainActor
    func testPayloadAuthorityHidesLateHigherRevisionNavigationOverwrite() async throws {
        var notebook = makeNotebook(title: "Navigation payload authority")
        notebook.pages[0].outlineTitle = "Initial outline"
        let page = notebook.pages[0]
        let documentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        var stalePage = page
        stalePage.outlineTitle = "Stale higher-revision outline"
        let staleSegment = try XCTUnwrap(
            PageNavigationSearchBuilder.segments(
                for: stalePage,
                notebookID: notebook.id
            ).first
        )
        let staleFingerprint = PageNavigationSearchBuilder
            .sourceFingerprint(for: [staleSegment])
        var currentPage = page
        currentPage.outlineTitle = "Current authoritative outline"
        let currentSegment = try XCTUnwrap(
            PageNavigationSearchBuilder.segments(
                for: currentPage,
                notebookID: notebook.id
            ).first
        )
        let currentFingerprint = PageNavigationSearchBuilder
            .sourceFingerprint(for: [currentSegment])
        let search = SearchIndexSpy(
            queryResponse: [LocalSearchHit(
                documentID: documentID,
                notebookID: notebook.id,
                pageID: page.id,
                title: notebook.title,
                snippet: staleSegment.text,
                score: 7.5,
                segment: staleSegment,
                sourceFingerprint: staleFingerprint
            )],
            segmentQueryResponse: [LocalSearchSegmentHit(
                documentID: documentID,
                notebookID: notebook.id,
                pageID: page.id,
                title: notebook.title,
                snippet: staleSegment.text,
                score: 7.5,
                segment: staleSegment,
                sourceFingerprint: staleFingerprint
            )]
        )
        let model = AppModel(
            store: ControlledNotebookStore(initialNotebooks: [notebook]),
            searchIndex: search
        )
        await model.load()
        let lease = try XCTUnwrap(model.beginEditorSession(notebookID: notebook.id))
        defer { model.endEditorSession(lease) }
        await search.blockNextUpsert(
            documentID,
            forcedRevision: Int.max / 4
        )

        let staleUpdate = Task { @MainActor in
            await model.updatePageNavigationMetadata(
                in: notebook,
                pageID: page.id,
                update: .outlineTitle(staleSegment.text),
                editorSession: lease
            )
        }
        let didBlock = await waitUntil { await search.hasBlockedUpsert }
        XCTAssertTrue(didBlock)

        _ = await model.updatePageNavigationMetadata(
            in: notebook,
            pageID: page.id,
            update: .outlineTitle(currentSegment.text),
            editorSession: lease
        )
        await search.releaseBlockedUpsert()
        _ = await staleUpdate.value

        let didRepairPhysicalPayload = await waitUntil {
            let document = await search.document(id: documentID)
            return document?.segments.first?.text == currentSegment.text
        }
        XCTAssertTrue(didRepairPhysicalPayload)
        model.searchText = staleSegment.text
        await model.searchIndexedContent()
        XCTAssertEqual(model.matchingNotebookIDs, [])
        let editorHits = await model.searchNotebookContent(
            staleSegment.text,
            notebookID: notebook.id
        )
        XCTAssertTrue(editorHits.isEmpty)

        await search.setQueryResponses(
            library: [LocalSearchHit(
                documentID: documentID,
                notebookID: notebook.id,
                pageID: page.id,
                title: notebook.title,
                snippet: currentSegment.text,
                score: 7.5,
                segment: currentSegment,
                sourceFingerprint: currentFingerprint
            )],
            editor: [LocalSearchSegmentHit(
                documentID: documentID,
                notebookID: notebook.id,
                pageID: page.id,
                title: notebook.title,
                snippet: currentSegment.text,
                score: 7.5,
                segment: currentSegment,
                sourceFingerprint: currentFingerprint
            )]
        )
        model.searchText = currentSegment.text
        await model.searchIndexedContent()
        XCTAssertEqual(model.matchingNotebookIDs, [notebook.id])
        let currentHits = await model.searchNotebookContent(
            currentSegment.text,
            notebookID: notebook.id
        )
        XCTAssertEqual(currentHits.map(\.pageID), [page.id])
    }

    @MainActor
    func testLaterNavigationRepairInvalidatesBlockedEarlierPublication() async throws {
        let notebook = makeNotebook(title: "Navigation repair ordering")
        let page = try XCTUnwrap(notebook.pages.first)
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let search = SearchIndexSpy()
        let model = AppModel(store: store, searchIndex: search)
        await model.load()
        let lease = try XCTUnwrap(model.beginEditorSession(notebookID: notebook.id))
        defer { model.endEditorSession(lease) }
        let documentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        await search.blockNextDocumentRead(documentID)

        let earlier = Task { @MainActor in
            await model.updatePageNavigationMetadata(
                in: notebook,
                pageID: page.id,
                update: .outlineTitle("Newest durable outline"),
                editorSession: lease
            )
        }
        let didBlock = await waitUntil { await search.hasBlockedDocumentRead }
        XCTAssertTrue(didBlock)

        let later = await model.updatePageNavigationMetadata(
            in: notebook,
            pageID: page.id,
            update: .bookmark(true),
            editorSession: lease
        )
        XCTAssertTrue(try XCTUnwrap(later?.pages.first).isBookmarked)
        await search.releaseBlockedDocumentRead()
        _ = await earlier.value

        let indexed = await search.document(id: documentID)
        XCTAssertEqual(indexed?.segments.map(\.source), [.outline, .bookmark])
        XCTAssertEqual(indexed?.segments.first?.text, "Newest durable outline")
    }

    @MainActor
    func testDuplicateStartsWithoutNavigationIndexAndDeleteRemovesSourceIndex() async throws {
        var notebook = makeNotebook(title: "Navigation copy lifecycle")
        notebook.pages[0].outlineTitle = "Source outline"
        notebook.pages[0].isBookmarked = true
        let sourcePage = notebook.pages[0]
        let search = SearchIndexSpy()
        let model = AppModel(
            store: ControlledNotebookStore(initialNotebooks: [notebook]),
            searchIndex: search
        )
        await model.load()

        let duplicated = await model.duplicatePageForTesting(
            in: notebook,
            page: sourcePage
        )
        let duplicatedNotebook = try XCTUnwrap(duplicated?.0)
        let duplicateID = try XCTUnwrap(duplicated?.1)
        let duplicateDocumentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: duplicateID
        )
        let duplicateDocument = await search.document(id: duplicateDocumentID)
        XCTAssertNil(duplicateDocument)

        let afterDelete = await model.deletePageForTesting(
            from: duplicatedNotebook,
            pageID: sourcePage.id
        )
        XCTAssertEqual(afterDelete?.pages.map(\.id), [duplicateID])
        let sourceDocumentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: sourcePage.id
        )
        let sourceDocument = await search.document(id: sourceDocumentID)
        XCTAssertNil(sourceDocument)
    }

    @MainActor
    func testPermanentlyDeletedNotebookCannotBeReindexedByBlockedNavigationRepair() async throws {
        var notebook = makeNotebook(title: "Navigation delete fence")
        notebook.pages[0].outlineTitle = "Private outline"
        let page = notebook.pages[0]
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let search = SearchIndexSpy()
        let model = AppModel(store: store, searchIndex: search)
        await model.load()
        let lease = try XCTUnwrap(model.beginEditorSession(notebookID: notebook.id))
        defer { model.endEditorSession(lease) }
        let documentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        await search.blockNextDocumentRead(documentID)

        let update = Task { @MainActor in
            await model.updatePageNavigationMetadata(
                in: notebook,
                pageID: page.id,
                update: .bookmark(true),
                editorSession: lease
            )
        }
        let didBlock = await waitUntil { await search.hasBlockedDocumentRead }
        XCTAssertTrue(didBlock)

        await model.deletePermanently(notebook.summary)
        let documentAfterDelete = await search.document(id: documentID)
        XCTAssertNil(documentAfterDelete)
        await search.releaseBlockedDocumentRead()
        let staleResult = await update.value
        XCTAssertNil(staleResult)
        let documentAfterLateRepair = await search.document(id: documentID)
        XCTAssertNil(documentAfterLateRepair)
        XCTAssertFalse(model.notebooks.contains { $0.id == notebook.id })
    }

    @MainActor
    func testPermanentDeleteSearchRemovalFailureKeepsNavigationHitsSuppressed() async throws {
        var notebook = makeNotebook(title: "Fail-closed navigation delete")
        notebook.pages[0].outlineTitle = "Confidential chapter"
        let page = notebook.pages[0]
        let documentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebook.id,
            pageID: page.id
        )
        let segment = try XCTUnwrap(
            PageNavigationSearchBuilder.segments(
                for: page,
                notebookID: notebook.id
            ).first
        )
        let libraryHit = LocalSearchHit(
            documentID: documentID,
            notebookID: notebook.id,
            pageID: page.id,
            title: notebook.title,
            snippet: segment.text,
            score: 7.5,
            segment: segment
        )
        let editorHit = LocalSearchSegmentHit(
            documentID: documentID,
            notebookID: notebook.id,
            pageID: page.id,
            title: notebook.title,
            snippet: segment.text,
            score: 7.5,
            segment: segment
        )
        let search = SearchIndexSpy(
            queryResponse: [libraryHit],
            segmentQueryResponse: [editorHit],
            failingRemoveNotebookIDs: [notebook.id]
        )
        let model = AppModel(
            store: ControlledNotebookStore(initialNotebooks: [notebook]),
            searchIndex: search
        )
        await model.load()

        await model.deletePermanently(notebook.summary)

        let retainedDerivedDocument = await search.document(id: documentID)
        XCTAssertNotNil(retainedDerivedDocument)
        model.searchText = "Confidential"
        await model.searchIndexedContent()
        XCTAssertEqual(model.matchingNotebookIDs, [])
        let editorResults = await model.searchNotebookContent(
            "Confidential",
            notebookID: notebook.id
        )
        XCTAssertTrue(editorResults.isEmpty)
    }

    @MainActor
    func testPageNavigationMetadataLateCompletionCannotPublishAfterEditorLeaseEnds() async throws {
        let notebook = makeNotebook(title: "Stale navigation metadata")
        let page = try XCTUnwrap(notebook.pages.first)
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()
        let lease = try XCTUnwrap(
            model.beginEditorSession(notebookID: notebook.id)
        )
        await store.blockNextPageNavigationMetadataUpdate()

        let update = Task { @MainActor in
            await model.updatePageNavigationMetadata(
                in: notebook,
                pageID: page.id,
                update: .outlineTitle("Late chapter"),
                editorSession: lease
            )
        }
        let didBlock = await waitUntil {
            await store.hasBlockedPageNavigationMetadataUpdate
        }
        XCTAssertTrue(didBlock)
        model.endEditorSession(lease)
        await store.releasePageNavigationMetadataUpdate()

        let staleResult = await update.value
        XCTAssertNil(staleResult)
        XCTAssertEqual(model.notebooks.first?.modifiedAt, notebook.modifiedAt)
        let stored = try await store.loadNotebook(id: notebook.id)
        let storedPage = try XCTUnwrap(stored.pages.first)
        XCTAssertFalse(storedPage.isBookmarked)
        XCTAssertEqual(storedPage.outlineTitle, "Late chapter")
    }

    @MainActor
    func testPageNavigationMetadataLateCompletionCannotResurrectPermanentlyDeletedNotebook() async throws {
        let notebook = makeNotebook(title: "Deleted navigation metadata")
        let page = try XCTUnwrap(notebook.pages.first)
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let model = AppModel(store: store, searchIndex: SearchIndexSpy())
        await model.load()
        let lease = try XCTUnwrap(
            model.beginEditorSession(notebookID: notebook.id)
        )
        defer { model.endEditorSession(lease) }
        await store.blockNextPageNavigationMetadataUpdate()

        let update = Task { @MainActor in
            await model.updatePageNavigationMetadata(
                in: notebook,
                pageID: page.id,
                update: .bookmark(true),
                editorSession: lease
            )
        }
        let didBlock = await waitUntil {
            await store.hasBlockedPageNavigationMetadataUpdate
        }
        XCTAssertTrue(didBlock)

        await model.deletePermanently(notebook.summary)
        XCTAssertFalse(model.notebooks.contains { $0.id == notebook.id })
        await store.releasePageNavigationMetadataUpdate()

        let staleResult = await update.value
        XCTAssertNil(staleResult)
        XCTAssertFalse(model.notebooks.contains { $0.id == notebook.id })
        do {
            _ = try await store.loadNotebook(id: notebook.id)
            XCTFail("The permanently deleted notebook must stay absent.")
        } catch {
            // Expected.
        }
    }

    @MainActor
    func testRootChangeDrainsCancelledEditorReadBeforeInstallingCandidate() async throws {
        let notebook = makeNotebook(title: "Editor read root fence")
        let suiteName = "NotesAppTests.EditorReadFence.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        let model = AppModel(
            store: store,
            searchIndex: SearchIndexSpy(),
            preferences: preferences
        )
        await model.load()
        let lease = try XCTUnwrap(model.beginEditorSession(notebookID: notebook.id))
        await store.blockNextNotebookLoad()
        let read = Task { @MainActor in await model.notebook(id: notebook.id) }
        let readDidBlock = await waitUntil { await store.hasBlockedNotebookLoad }
        XCTAssertTrue(readDidBlock)
        read.cancel()
        model.endEditorSession(lease)

        let rootChange = Task { @MainActor in
            await model.useRootDirectory(
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("NotesEditorReadMove-\(UUID().uuidString)")
            )
        }
        let transitionStarted = await waitUntil { model.isLibraryRootChangeInProgress }
        XCTAssertTrue(transitionStarted)
        let installsWhileReadBlocked = await store.rootChangeCallCount
        XCTAssertEqual(installsWhileReadBlocked, 0)

        await store.releaseNotebookLoad()
        let staleNotebook = await read.value
        await rootChange.value
        let installsAfterReadFinished = await store.rootChangeCallCount
        XCTAssertNil(staleNotebook)
        XCTAssertEqual(installsAfterReadFinished, 1)
        let markerCleared = await waitUntil {
            !preferences.bool(forKey: AppModel.searchRootRebuildRequiredKey)
        }
        XCTAssertTrue(markerCleared)
    }

    @MainActor
    func testRootChangeDrainsOldRootOCRAndPreventsLateIndexPublication() async throws {
        var notebook = makeNotebook(title: "OCR root fence")
        var page = try XCTUnwrap(notebook.pages.first)
        let assetPath = "assets/ocr-root-fence.bin"
        page.background = .image(assetPath: assetPath)
        notebook.pages[0] = page
        let ocrNotebook = notebook
        let ocrPage = page
        let suiteName = "NotesAppTests.OCRRootFence.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let store = ControlledNotebookStore(initialNotebooks: [ocrNotebook])
        try await store.installAsset(Data([0x01, 0x02, 0x03]), relativePath: assetPath)
        let libraryURL = try await store.libraryDirectoryURL()
        defer { try? FileManager.default.removeItem(at: libraryURL) }
        let recognizer = BlockingHandwritingRecognizer()
        let search = SearchIndexSpy()
        let model = AppModel(
            store: store,
            searchIndex: search,
            preferences: preferences,
            imageTextRecognizer: recognizer
        )
        await model.load()

        let extraction = Task { @MainActor in
            await model.extractText(notebookID: ocrNotebook.id, page: ocrPage)
        }
        let recognitionStarted = await waitUntil { await recognizer.wasInvoked }
        XCTAssertTrue(recognitionStarted)
        let rootChange = Task { @MainActor in
            await model.useRootDirectory(
                FileManager.default.temporaryDirectory
                    .appendingPathComponent("NotesOCRMove-\(UUID().uuidString)")
            )
        }
        let transitionStarted = await waitUntil { model.isLibraryRootChangeInProgress }
        XCTAssertTrue(transitionStarted)
        let installsWhileOCRBlocked = await store.rootChangeCallCount
        XCTAssertEqual(installsWhileOCRBlocked, 0)

        await recognizer.release()
        let extracted = await extraction.value
        await rootChange.value
        let staleDocumentWasIndexed = await search.contains(documentID: ocrPage.id)
        XCTAssertNil(extracted)
        XCTAssertFalse(staleDocumentWasIndexed)
        let installsAfterOCRFinished = await store.rootChangeCallCount
        XCTAssertEqual(installsAfterOCRFinished, 1)
        let markerCleared = await waitUntil {
            !preferences.bool(forKey: AppModel.searchRootRebuildRequiredKey)
        }
        XCTAssertTrue(markerCleared)
    }

    @MainActor
    func testCancelledRecognitionDoesNotReplaceDurableReview() async throws {
        let notebook = makeNotebook(title: "Cancelled recognition")
        let page = try XCTUnwrap(notebook.pages.first)
        let ink = PKDrawing().dataRepresentation()
        let candidate = handwritingCandidate(text: "keep existing review")
        let existing = handwritingDocument(
            pageID: page.id,
            ink: ink,
            candidates: [candidate],
            reviews: [HandwritingCandidateReview(
                candidateID: candidate.id,
                decision: .accepted,
                reviewedAt: handwritingTimestamp
            )]
        )
        let store = ControlledNotebookStore(initialNotebooks: [notebook])
        await store.setInk(ink, notebookID: notebook.id, pageID: page.id)
        await store.setHandwritingRecognition(
            existing,
            notebookID: notebook.id,
            pageID: page.id
        )
        let recognizer = BlockingHandwritingRecognizer()
        let model = AppModel(
            store: store,
            searchIndex: SearchIndexSpy(),
            handwritingTextRecognizer: recognizer
        )
        await model.load()

        let task = Task { @MainActor in
            await model.recognizeHandwriting(
                notebookID: notebook.id,
                page: page,
                languages: ["en-US"]
            )
        }
        let started = await waitUntil { await recognizer.wasInvoked }
        XCTAssertTrue(started)
        task.cancel()
        await recognizer.release()

        let result = await task.value
        XCTAssertNil(result)
        let stored = await store.storedHandwritingRecognition(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertEqual(stored, existing)
        XCTAssertFalse(model.isHandwritingRecognitionRunning(
            notebookID: notebook.id,
            pageID: page.id
        ))
    }

    private struct RenameSearchRecoveryFixture {
        let notebook: EditorNotebook
        let canvasPageID: UUID
        let structuredPageID: UUID
        let navigationDocumentID: UUID
        let canvasDocumentID: UUID
        let handwritingDocumentID: UUID
        let outlineText: String
        let structuredText: String
        let canvasText: String
        let handwritingText: String
        let store: ControlledNotebookStore
        let search: LocalSearchIndex
        let model: AppModel
    }

    @MainActor
    private func makeRenameSearchRecoveryFixture(
        rootCommitFailures: Int = 0,
        libraryRootChangeTimeout: Duration = .seconds(2)
    ) async throws -> RenameSearchRecoveryFixture {
        var notebook = makeNotebook(title: "Title before durable rename")
        notebook.pages[0].outlineTitle = "Recovery outline target"
        notebook.pages[0].isBookmarked = true
        let canvasPage = notebook.pages[0]
        var structuredPage = EditorPage.newPage(for: .textDocument)
        structuredPage.modifiedAt = canvasPage.modifiedAt
        notebook.pages.append(structuredPage)

        let outlineText = try XCTUnwrap(canvasPage.outlineTitle)
        let structuredText = "Recovery structured text"
        let canvasText = "Recovery canvas text"
        let handwritingText = "Recovery reviewed handwriting"
        let structuredContent = PageContent.textDocument(
            TextDocument(blocks: [TextBlock(text: structuredText)])
        )
        let canvasElement = CanvasElementEditing.makeText(
            id: ElementID(),
            text: canvasText,
            at: CanvasPoint(x: 40, y: 60),
            within: CanvasRect(
                x: 0,
                y: 0,
                width: canvasPage.width,
                height: canvasPage.height
            ),
            now: canvasPage.modifiedAt
        )
        let ink = Data("rename recovery ink".utf8)
        let candidate = handwritingCandidate(text: handwritingText)
        let recognition = handwritingDocument(
            pageID: canvasPage.id,
            ink: ink,
            candidates: [candidate],
            reviews: [HandwritingCandidateReview(
                candidateID: candidate.id,
                decision: .accepted,
                reviewedAt: handwritingTimestamp
            )]
        )
        let store = ControlledNotebookStore(
            initialNotebooks: [notebook],
            rootCommitFailures: rootCommitFailures
        )
        await store.setPageContent(
            structuredContent,
            notebookID: notebook.id,
            pageID: structuredPage.id
        )
        await store.setCanvasElements(
            [canvasElement],
            notebookID: notebook.id,
            pageID: canvasPage.id
        )
        await store.setInk(
            ink,
            notebookID: notebook.id,
            pageID: canvasPage.id
        )
        await store.setHandwritingRecognition(
            recognition,
            notebookID: notebook.id,
            pageID: canvasPage.id
        )
        let search = LocalSearchIndex()
        let model = AppModel(
            store: store,
            searchIndex: search,
            libraryRootChangeTimeout: libraryRootChangeTimeout
        )
        await model.load()

        return RenameSearchRecoveryFixture(
            notebook: notebook,
            canvasPageID: canvasPage.id,
            structuredPageID: structuredPage.id,
            navigationDocumentID: PageNavigationSearchBuilder.documentID(
                notebookID: notebook.id,
                pageID: canvasPage.id
            ),
            canvasDocumentID: CanvasElementSearchBuilder.documentID(
                notebookID: notebook.id,
                pageID: canvasPage.id
            ),
            handwritingDocumentID: HandwritingSearchBuilder.documentID(
                notebookID: notebook.id,
                pageID: canvasPage.id
            ),
            outlineText: outlineText,
            structuredText: structuredText,
            canvasText: canvasText,
            handwritingText: handwritingText,
            store: store,
            search: search,
            model: model
        )
    }

    @MainActor
    private func didRecoverAllRenameSearchTitles(
        _ fixture: RenameSearchRecoveryFixture,
        expectedTitle: String
    ) async -> Bool {
        let titleDocument = await fixture.search.document(
            for: fixture.notebook.id
        )
        let navigationDocument = await fixture.search.document(
            for: fixture.navigationDocumentID
        )
        let structuredDocument = await fixture.search.document(
            for: fixture.structuredPageID
        )
        let canvasDocument = await fixture.search.document(
            for: fixture.canvasDocumentID
        )
        let handwritingDocument = await fixture.search.document(
            for: fixture.handwritingDocumentID
        )
        return [
            titleDocument,
            navigationDocument,
            structuredDocument,
            canvasDocument,
            handwritingDocument
        ].allSatisfy { $0?.title == expectedTitle }
    }

    @MainActor
    private func didRecoverRenameSearchState(
        _ fixture: RenameSearchRecoveryFixture,
        expectedTitle: String
    ) async -> Bool {
        guard await didRecoverAllRenameSearchTitles(
            fixture,
            expectedTitle: expectedTitle
        ) else { return false }
        fixture.model.searchText = fixture.outlineText
        await fixture.model.searchIndexedContent()
        guard fixture.model.matchingNotebookIDs == Set([fixture.notebook.id]),
              fixture.model.searchTargetPageIDs[fixture.notebook.id]
                == fixture.canvasPageID else { return false }
        let editorHits = await fixture.model.searchNotebookContent(
            fixture.outlineText,
            notebookID: fixture.notebook.id
        )
        return editorHits.map(\.title) == [expectedTitle]
            && editorHits.map(\.pageID) == [fixture.canvasPageID]
    }

    @MainActor
    private func assertRecoveredRenameSearch(
        _ fixture: RenameSearchRecoveryFixture,
        expectedTitle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let durable = try? await fixture.store.loadNotebook(
            id: fixture.notebook.id
        )
        XCTAssertEqual(durable?.title, expectedTitle, file: file, line: line)
        XCTAssertEqual(
            fixture.model.notebooks.first(where: {
                $0.id == fixture.notebook.id
            })?.title,
            expectedTitle,
            file: file,
            line: line
        )
        let didRecoverAllTitles = await didRecoverAllRenameSearchTitles(
            fixture,
            expectedTitle: expectedTitle
        )
        XCTAssertTrue(
            didRecoverAllTitles,
            file: file,
            line: line
        )

        fixture.model.searchText = fixture.outlineText
        await fixture.model.searchIndexedContent()
        XCTAssertEqual(
            fixture.model.matchingNotebookIDs,
            [fixture.notebook.id],
            file: file,
            line: line
        )
        XCTAssertEqual(
            fixture.model.searchTargetPageIDs[fixture.notebook.id],
            fixture.canvasPageID,
            file: file,
            line: line
        )
        let editorHits = await fixture.model.searchNotebookContent(
            fixture.outlineText,
            notebookID: fixture.notebook.id
        )
        XCTAssertEqual(editorHits.map(\.title), [expectedTitle], file: file, line: line)
        XCTAssertEqual(
            editorHits.map(\.pageID),
            [fixture.canvasPageID],
            file: file,
            line: line
        )

        let sourceQueries: [(String, RecognizedTextSource, UUID)] = [
            (fixture.structuredText, .typedText, fixture.structuredPageID),
            (fixture.canvasText, .canvasElement, fixture.canvasPageID),
            (fixture.handwritingText, .handwriting, fixture.canvasPageID)
        ]
        for (query, source, pageID) in sourceQueries {
            fixture.model.searchText = query
            await fixture.model.searchIndexedContent()
            XCTAssertEqual(
                fixture.model.matchingNotebookIDs,
                [fixture.notebook.id],
                file: file,
                line: line
            )
            let hits = await fixture.model.searchNotebookContent(
                query,
                notebookID: fixture.notebook.id
            )
            XCTAssertEqual(
                hits.first?.title,
                expectedTitle,
                file: file,
                line: line
            )
            XCTAssertEqual(
                hits.first?.segment.source,
                source,
                file: file,
                line: line
            )
            XCTAssertEqual(
                hits.first?.pageID,
                pageID,
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private var handwritingTimestamp: Date {
        Date(timeIntervalSince1970: 1_700_000_000)
    }

    @MainActor
    private func handwritingCandidate(text: String) -> HandwritingMachineCandidate {
        HandwritingMachineCandidate(
            machineText: text,
            machineConfidence: 0.9,
            normalizedPageBounds: HandwritingNormalizedBounds(
                x: 0.1,
                y: 0.2,
                width: 0.4,
                height: 0.1
            ),
            localeIdentifier: "en-US"
        )
    }

    @MainActor
    private func handwritingDocument(
        pageID: UUID,
        ink: Data,
        candidates: [HandwritingMachineCandidate],
        reviews: [HandwritingCandidateReview] = []
    ) -> HandwritingRecognitionDocument {
        HandwritingRecognitionDocument(
            pageID: PageID(pageID),
            sourceInkSHA256: HandwritingRecognitionPipeline.sourceInkSHA256(for: ink),
            engineIdentifier: HandwritingRecognitionPipeline.engineIdentifier,
            engineRevision: HandwritingRecognitionPipeline.engineRevision,
            languages: ["en-US"],
            generatedAt: handwritingTimestamp,
            modifiedAt: handwritingTimestamp,
            machineCandidates: candidates,
            reviews: reviews
        )
    }

    @MainActor
    private func waitUntil(
        attempts: Int = 100,
        condition: () async -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

@MainActor
private final class AcademicRootCoordinatorSpy: AcademicLibraryRootCoordinating {
    enum Event: Equatable {
        case prepare
        case resolveCandidate
        case accept
        case rollback
    }

    private let notesStore: ControlledNotebookStore
    private let prepareShouldFail: Bool
    private var activeTransition: AcademicLibraryRootTransition?

    private(set) var events: [Event] = []
    private(set) var notesBeginCountsAtPrepare: [Int] = []
    private(set) var notesCommitCountsAtResolve: [Int] = []
    private(set) var notesFinalizeCountsAtResolve: [Int] = []
    private(set) var notesRollbackCountsAtRollback: [Int] = []

    init(
        notesStore: ControlledNotebookStore,
        prepareShouldFail: Bool = false
    ) {
        self.notesStore = notesStore
        self.prepareShouldFail = prepareShouldFail
    }

    func prepareForLibraryRootTransition() async throws
        -> AcademicLibraryRootTransition {
        events.append(.prepare)
        let notesBeginCount = await notesStore.rootChangeCallCount
        notesBeginCountsAtPrepare.append(notesBeginCount)
        guard !prepareShouldFail else {
            throw AcademicRootCoordinatorSpyError.prepareFailed
        }
        let transition = AcademicLibraryRootTransition()
        activeTransition = transition
        return transition
    }

    func resolveCandidateLibraryRoot(
        _ transition: AcademicLibraryRootTransition
    ) async {
        guard activeTransition == transition else { return }
        events.append(.resolveCandidate)
        let notesCommitCount = await notesStore.rootCommitCallCount
        let notesFinalizeCount = await notesStore.rootFinalizeCallCount
        notesCommitCountsAtResolve.append(notesCommitCount)
        notesFinalizeCountsAtResolve.append(notesFinalizeCount)
    }

    func acceptLibraryRootTransition(
        _ transition: AcademicLibraryRootTransition
    ) {
        guard activeTransition == transition else { return }
        events.append(.accept)
        activeTransition = nil
    }

    func rollbackLibraryRootTransition(
        _ transition: AcademicLibraryRootTransition
    ) async {
        guard activeTransition == transition else { return }
        events.append(.rollback)
        let notesRollbackCount = await notesStore.rootRollbackCallCount
        notesRollbackCountsAtRollback.append(notesRollbackCount)
        activeTransition = nil
    }
}

private enum AcademicRootCoordinatorSpyError: Error {
    case prepareFailed
}

private final class BlockingSecondRepositoryFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let secondInvocationGate = DispatchSemaphore(value: 0)
    private var invocationCount = 0
    private var didBlockSecondInvocation = false

    var hasBlockedSecondInvocation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didBlockSecondInvocation
    }

    func makeRepository(at url: URL) throws -> FileNotebookRepository {
        lock.lock()
        invocationCount += 1
        let shouldBlock = invocationCount == 2
        if shouldBlock { didBlockSecondInvocation = true }
        lock.unlock()
        if shouldBlock { secondInvocationGate.wait() }
        return try FileNotebookRepository(rootURL: url)
    }

    func releaseSecondInvocation() {
        secondInvocationGate.signal()
    }
}

private final class BlockingFirstRepositoryFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let firstInvocationGate = DispatchSemaphore(value: 0)
    private var invocationCount = 0
    private var didBlockFirstInvocation = false

    var hasBlockedFirstInvocation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didBlockFirstInvocation
    }

    func makeRepository(at url: URL) throws -> FileNotebookRepository {
        lock.lock()
        invocationCount += 1
        let shouldBlock = invocationCount == 1
        if shouldBlock { didBlockFirstInvocation = true }
        lock.unlock()
        if shouldBlock { firstInvocationGate.wait() }
        return try FileNotebookRepository(rootURL: url)
    }

    func releaseFirstInvocation() {
        firstInvocationGate.signal()
    }
}

private final class RootBookmarkSynchronizerSpy: @unchecked Sendable {
    private static let bookmarkKey = "notes.library.rootBookmark"

    private let lock = NSLock()
    private var results: [Bool]
    private var bookmarkSnapshots: [Data?] = []

    init(results: [Bool] = []) {
        self.results = results
    }

    var observedBookmarks: [Data?] {
        lock.lock()
        defer { lock.unlock() }
        return bookmarkSnapshots
    }

    func synchronize(_ preferences: UserDefaults) -> Bool {
        let bookmark = preferences.data(forKey: Self.bookmarkKey)
        lock.lock()
        defer { lock.unlock() }
        bookmarkSnapshots.append(bookmark)
        guard !results.isEmpty else { return true }
        return results.removeFirst()
    }
}

private enum RootRepositoryValidationFailure: Error, Sendable {
    case rejected
}

private actor AsyncGate {
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(isOpen: Bool) {
        self.isOpen = isOpen
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor BlockingHandwritingRecognizer: TextRecognitionService {
    private let gate = AsyncGate(isOpen: false)
    private(set) var wasInvoked = false

    func recognize(
        imageData: Data,
        orientation: CGImagePropertyOrientation,
        languages: [String],
        pageID: UUID?
    ) async throws -> [RecognizedTextSegment] {
        wasInvoked = true
        await gate.wait()
        guard let pageID else { return [] }
        return [RecognizedTextSegment(
            text: "stale machine result",
            confidence: 0.9,
            bounds: NormalizedRect(x: 0.1, y: 0.7, width: 0.4, height: 0.1),
            pageID: pageID,
            source: .scannedImage,
            localeIdentifier: languages.first
        )]
    }

    func release() async {
        await gate.open()
    }
}

private struct FailingHandwritingRecognizer: TextRecognitionService {
    func recognize(
        imageData: Data,
        orientation: CGImagePropertyOrientation,
        languages: [String],
        pageID: UUID?
    ) async throws -> [RecognizedTextSegment] {
        throw StubError.handwritingRecognitionFailed
    }
}

private actor DelayedFailingHandwritingRecognizer: TextRecognitionService {
    private let gate = AsyncGate(isOpen: false)
    private(set) var wasInvoked = false

    func recognize(
        imageData: Data,
        orientation: CGImagePropertyOrientation,
        languages: [String],
        pageID: UUID?
    ) async throws -> [RecognizedTextSegment] {
        _ = imageData
        _ = orientation
        _ = languages
        _ = pageID
        wasInvoked = true
        await gate.wait()
        throw StubError.handwritingRecognitionFailed
    }

    func release() async {
        await gate.open()
    }
}

private final class BlockingSecondMetadataRead: @unchecked Sendable {
    private let lock = NSLock()
    private let secondInvocationGate = DispatchSemaphore(value: 0)
    private var invocationCount = 0
    private var didBlockSecondInvocation = false

    var hasBlockedSecondInvocation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didBlockSecondInvocation
    }

    func read(_ url: URL) {
        _ = url
        lock.lock()
        invocationCount += 1
        let shouldBlock = invocationCount == 2
        if shouldBlock {
            didBlockSecondInvocation = true
        }
        lock.unlock()
        if shouldBlock {
            secondInvocationGate.wait()
        }
    }

    func releaseSecondInvocation() {
        secondInvocationGate.signal()
    }
}

private final class BlockingFirstMetadataRead: @unchecked Sendable {
    private let lock = NSLock()
    private let firstInvocationGate = DispatchSemaphore(value: 0)
    private var invocationCount = 0
    private var didBlockFirstInvocation = false

    var hasBlockedFirstInvocation: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didBlockFirstInvocation
    }

    func read(_ url: URL) {
        _ = url
        lock.lock()
        invocationCount += 1
        let shouldBlock = invocationCount == 1
        if shouldBlock {
            didBlockFirstInvocation = true
        }
        lock.unlock()
        if shouldBlock {
            firstInvocationGate.wait()
        }
    }

    func releaseFirstInvocation() {
        firstInvocationGate.signal()
    }
}

private actor ControlledNotebookStore:
    NotesAppNotebookStore, TextDocumentSourceSnapshotProviding {
    private struct PageContentKey: Hashable, Sendable {
        let notebookID: UUID
        let pageID: UUID
    }

    enum DuplicateFailure: Equatable, Sendable {
        case none
        case inkWrite
        case inkWriteAndRollback
        case pageContentWrite
    }

    private let loadGate: AsyncGate
    private let inkSaveGate: AsyncGate
    private let pageContentSaveGate: AsyncGate
    private let canvasElementSaveGate: AsyncGate
    private let importGate: AsyncGate
    private var notebookLoadGate: AsyncGate?
    private var notebookSaveReturnGate: AsyncGate?
    private var pageNavigationMetadataUpdateGate: AsyncGate?
    private let libraryURL: URL
    private let duplicateFailure: DuplicateFailure
    private var transientInkFailures: Int
    private var transientPageContentFailures: Int
    private var transientCanvasElementFailures: Int
    private var initialLibraryLoadFailures: Int
    private var rootTransitionLoadFailures: Int
    private var rootCommitFailures: Int
    private let inkFailureCallNumbers: Set<Int>
    private let importedPageOutlineTitle: String?
    private let importedPageIsBookmarked: Bool
    private var notebooks: [UUID: EditorNotebook]
    private var pageContents: [PageContentKey: PageContent]
    private var textDocumentSourceSnapshotTextOverride: String? = nil
    private var canvasElements: [PageContentKey: [CanvasElement]] = [:]
    private var inkByPage: [PageContentKey: Data] = [:]
    private var handwritingRecognition: [PageContentKey: HandwritingRecognitionDocument] = [:]
    private var handwritingRecognitionLoadGate: AsyncGate?
    private var handwritingRecognitionLoadBlockCountdown: Int?
    private(set) var hasCapturedInitialLoad = false
    private(set) var hasBlockedHandwritingRecognitionLoad = false
    private(set) var hasBlockedNotebookLoad = false
    private(set) var hasBlockedNotebookSaveReturn = false
    private(set) var hasBlockedPageNavigationMetadataUpdate = false
    private(set) var hasBlockedImport = false
    private(set) var mutationCount = 0
    private(set) var rootChangeCallCount = 0
    private(set) var rootCommitCallCount = 0
    private(set) var rootRollbackCallCount = 0
    private(set) var rootFinalizeCallCount = 0
    private(set) var savedPageIDSequences: [[UUID]] = []
    private(set) var deletedPageIDs: [UUID] = []
    private(set) var savedInkPayloads: [Data] = []
    private(set) var savedPageContents: [PageContent] = []
    private(set) var textDocumentSourceSnapshotReadCount = 0
    private(set) var savedCanvasElements: [[CanvasElement]] = []
    private(set) var persistenceEvents: [String] = []
    private var saveNotebookCallCount = 0
    private(set) var saveInkCallCount = 0
    private(set) var handwritingRecognitionLoadCallCount = 0
    private var pendingRootPreparation: NotesAppLibraryRootPreparation?
    private var pendingRootTransition: NotesAppLibraryRootTransition?
    private var pendingRootTransitionIsCommitted = false

    init(
        initialNotebooks: [EditorNotebook],
        blocksInitialLoad: Bool = false,
        blocksInkSave: Bool = false,
        blocksPageContentSave: Bool = false,
        blocksCanvasElementSave: Bool = false,
        blocksImport: Bool = false,
        importedPageOutlineTitle: String? = nil,
        importedPageIsBookmarked: Bool = false,
        duplicateFailure: DuplicateFailure = .none,
        transientInkFailures: Int = 0,
        transientPageContentFailures: Int = 0,
        transientCanvasElementFailures: Int = 0,
        initialLibraryLoadFailures: Int = 0,
        rootTransitionLoadFailures: Int = 0,
        rootCommitFailures: Int = 0,
        inkFailureCallNumbers: Set<Int> = []
    ) {
        notebooks = Dictionary(uniqueKeysWithValues: initialNotebooks.map { ($0.id, $0) })
        pageContents = initialNotebooks.reduce(into: [:]) { contents, notebook in
            for page in notebook.pages {
                if let content = PageContent.empty(for: page.kind) {
                    contents[PageContentKey(notebookID: notebook.id, pageID: page.id)] = content
                }
            }
        }
        loadGate = AsyncGate(isOpen: !blocksInitialLoad)
        inkSaveGate = AsyncGate(isOpen: !blocksInkSave)
        pageContentSaveGate = AsyncGate(isOpen: !blocksPageContentSave)
        canvasElementSaveGate = AsyncGate(isOpen: !blocksCanvasElementSave)
        importGate = AsyncGate(isOpen: !blocksImport)
        libraryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesAppControlledStoreLibrary-\(UUID().uuidString)", isDirectory: true)
        self.duplicateFailure = duplicateFailure
        self.transientInkFailures = transientInkFailures
        self.transientPageContentFailures = transientPageContentFailures
        self.transientCanvasElementFailures = transientCanvasElementFailures
        self.initialLibraryLoadFailures = initialLibraryLoadFailures
        self.rootTransitionLoadFailures = rootTransitionLoadFailures
        self.rootCommitFailures = rootCommitFailures
        self.inkFailureCallNumbers = inkFailureCallNumbers
        self.importedPageOutlineTitle = importedPageOutlineTitle
        self.importedPageIsBookmarked = importedPageIsBookmarked
    }

    func loadLibrary() async throws -> [LibraryNotebook] {
        let snapshot = notebooks.values.map(\.summary)
        let isInitialLoad = !hasCapturedInitialLoad
        hasCapturedInitialLoad = true
        if isInitialLoad {
            await loadGate.wait()
            if initialLibraryLoadFailures > 0 {
                initialLibraryLoadFailures -= 1
                throw StubError.libraryLoadFailed
            }
        }
        if pendingRootTransition != nil, rootTransitionLoadFailures > 0 {
            rootTransitionLoadFailures -= 1
            throw StubError.libraryLoadFailed
        }
        return snapshot
    }

    func releaseInitialLoad() async {
        await loadGate.open()
    }

    func releasePageContentSave() async {
        await pageContentSaveGate.open()
    }

    func releaseInkSave() async {
        await inkSaveGate.open()
    }

    func releaseCanvasElementSave() async {
        await canvasElementSaveGate.open()
    }

    func releaseImport() async {
        await importGate.open()
    }

    func blockNextNotebookLoad() {
        notebookLoadGate = AsyncGate(isOpen: false)
        hasBlockedNotebookLoad = false
    }

    func releaseNotebookLoad() async {
        let gate = notebookLoadGate
        notebookLoadGate = nil
        await gate?.open()
    }

    func blockNextNotebookSaveReturn() {
        notebookSaveReturnGate = AsyncGate(isOpen: false)
        hasBlockedNotebookSaveReturn = false
    }

    func releaseNotebookSaveReturn() async {
        let gate = notebookSaveReturnGate
        notebookSaveReturnGate = nil
        await gate?.open()
    }

    func blockNextPageNavigationMetadataUpdate() {
        pageNavigationMetadataUpdateGate = AsyncGate(isOpen: false)
        hasBlockedPageNavigationMetadataUpdate = false
    }

    func releasePageNavigationMetadataUpdate() async {
        let gate = pageNavigationMetadataUpdateGate
        pageNavigationMetadataUpdateGate = nil
        await gate?.open()
    }

    func blockHandwritingRecognitionLoad(afterAdditionalCalls: Int = 0) {
        handwritingRecognitionLoadGate = AsyncGate(isOpen: false)
        handwritingRecognitionLoadBlockCountdown = max(0, afterAdditionalCalls)
        hasBlockedHandwritingRecognitionLoad = false
    }

    func releaseHandwritingRecognitionLoad() async {
        let gate = handwritingRecognitionLoadGate
        handwritingRecognitionLoadGate = nil
        handwritingRecognitionLoadBlockCountdown = nil
        await gate?.open()
    }

    func createNotebook(
        title: String,
        kind: NotebookKind,
        template: PaperTemplate
    ) async throws -> EditorNotebook {
        mutationCount += 1
        let notebook = makeNotebook(title: title, kind: kind, template: template)
        notebooks[notebook.id] = notebook
        return notebook
    }

    func importDocument(at sourceURL: URL) async throws -> EditorNotebook {
        mutationCount += 1
        let title = sourceURL.deletingPathExtension().lastPathComponent
        var notebook = makeNotebook(title: title, kind: .pdf)
        notebook.pages[0].outlineTitle = importedPageOutlineTitle
        notebook.pages[0].isBookmarked = importedPageIsBookmarked
        notebooks[notebook.id] = notebook
        hasBlockedImport = true
        await importGate.wait()
        return notebook
    }

    func loadNotebook(id: UUID) async throws -> EditorNotebook {
        guard let notebook = notebooks[id] else { throw StubError.missingNotebook }
        if let notebookLoadGate {
            hasBlockedNotebookLoad = true
            await notebookLoadGate.wait()
        }
        return notebook
    }

    func saveNotebook(_ notebook: EditorNotebook) async throws {
        mutationCount += 1
        saveNotebookCallCount += 1
        savedPageIDSequences.append(notebook.pages.map(\.id))
        if duplicateFailure == .inkWriteAndRollback, saveNotebookCallCount == 2 {
            throw StubError.rollbackFailed
        }
        notebooks[notebook.id] = notebook
        let validPageIDs = Set(notebook.pages.map(\.id))
        pageContents = pageContents.filter {
            $0.key.notebookID != notebook.id || validPageIDs.contains($0.key.pageID)
        }
        canvasElements = canvasElements.filter {
            $0.key.notebookID != notebook.id || validPageIDs.contains($0.key.pageID)
        }
        inkByPage = inkByPage.filter {
            $0.key.notebookID != notebook.id || validPageIDs.contains($0.key.pageID)
        }
        handwritingRecognition = handwritingRecognition.filter {
            $0.key.notebookID != notebook.id || validPageIDs.contains($0.key.pageID)
        }
        for page in notebook.pages {
            let key = PageContentKey(notebookID: notebook.id, pageID: page.id)
            if pageContents[key] == nil, let empty = PageContent.empty(for: page.kind) {
                pageContents[key] = empty
            }
        }
        if let notebookSaveReturnGate {
            hasBlockedNotebookSaveReturn = true
            await notebookSaveReturnGate.wait()
        }
    }

    func updatePageNavigationMetadata(
        notebookID: UUID,
        pageID: UUID,
        update: PageNavigationMetadataUpdate
    ) async throws -> EditorNotebook {
        guard var notebook = notebooks[notebookID],
              let pageIndex = notebook.pages.firstIndex(where: {
                  $0.id == pageID
              }) else {
            throw StubError.missingNotebook
        }
        mutationCount += 1
        let now = Date()
        switch update {
        case .bookmark(let isBookmarked):
            notebook.pages[pageIndex].isBookmarked = isBookmarked
        case .outlineTitle(let outlineTitle):
            notebook.pages[pageIndex].outlineTitle = outlineTitle
        }
        notebook.pages[pageIndex].modifiedAt = now
        notebook.modifiedAt = now
        notebooks[notebookID] = notebook
        if let pageNavigationMetadataUpdateGate {
            hasBlockedPageNavigationMetadataUpdate = true
            await pageNavigationMetadataUpdateGate.wait()
        }
        return notebook
    }

    func deletePage(notebookID: UUID, pageID: UUID) async throws -> EditorNotebook {
        if duplicateFailure == .inkWriteAndRollback {
            throw StubError.rollbackFailed
        }
        guard var notebook = notebooks[notebookID],
              notebook.pages.contains(where: { $0.id == pageID }) else {
            throw StubError.missingNotebook
        }
        notebook.pages.removeAll { $0.id == pageID }
        notebooks[notebookID] = notebook
        pageContents.removeValue(
            forKey: PageContentKey(notebookID: notebookID, pageID: pageID)
        )
        canvasElements.removeValue(
            forKey: PageContentKey(notebookID: notebookID, pageID: pageID)
        )
        inkByPage.removeValue(
            forKey: PageContentKey(notebookID: notebookID, pageID: pageID)
        )
        handwritingRecognition.removeValue(
            forKey: PageContentKey(notebookID: notebookID, pageID: pageID)
        )
        deletedPageIDs.append(pageID)
        return notebook
    }

    func loadInk(notebookID: UUID, page: EditorPage) async throws -> Data? {
        inkByPage[PageContentKey(notebookID: notebookID, pageID: page.id)]
            ?? Data([0x4E, 0x4F, 0x54, 0x45, 0x53])
    }

    func saveInk(_ data: Data, notebookID: UUID, page: EditorPage) async throws {
        mutationCount += 1
        persistenceEvents.append("saveInk")
        saveInkCallCount += 1
        let callNumber = saveInkCallCount
        await inkSaveGate.wait()
        if inkFailureCallNumbers.contains(callNumber) {
            throw StubError.inkWriteFailed
        }
        if transientInkFailures > 0 {
            transientInkFailures -= 1
            throw StubError.inkWriteFailed
        }
        switch duplicateFailure {
        case .none:
            savedInkPayloads.append(data)
            inkByPage[PageContentKey(
                notebookID: notebookID,
                pageID: page.id
            )] = data
        case .inkWrite, .inkWriteAndRollback:
            throw StubError.inkWriteFailed
        case .pageContentWrite:
            savedInkPayloads.append(data)
            inkByPage[PageContentKey(
                notebookID: notebookID,
                pageID: page.id
            )] = data
        }
    }

    func loadElements(notebookID: UUID, pageID: UUID) async throws -> [CanvasElement] {
        canvasElements[PageContentKey(notebookID: notebookID, pageID: pageID)] ?? []
    }

    func saveElements(
        _ elements: [CanvasElement],
        notebookID: UUID,
        pageID: UUID
    ) async throws {
        mutationCount += 1
        persistenceEvents.append("saveElements")
        await canvasElementSaveGate.wait()
        if transientCanvasElementFailures > 0 {
            transientCanvasElementFailures -= 1
            throw StubError.elementWriteFailed
        }
        canvasElements[PageContentKey(notebookID: notebookID, pageID: pageID)] = elements
        savedCanvasElements.append(elements)
    }

    func loadPageContent(notebookID: UUID, pageID: UUID) async throws -> PageContent? {
        pageContents[PageContentKey(notebookID: notebookID, pageID: pageID)]
    }

    func overrideTextDocumentSourceSnapshotText(_ text: String?) {
        textDocumentSourceSnapshotTextOverride = text
    }

    func textDocumentSourceSnapshot(
        noteID: NotebookID,
        pageID: PageID,
        blockID: TextBlockID
    ) async throws -> TextDocumentSourceSnapshot {
        textDocumentSourceSnapshotReadCount += 1
        persistenceEvents.append("sourceSnapshot")
        guard let content = pageContents[PageContentKey(
            notebookID: noteID.rawValue,
            pageID: pageID.rawValue
        )],
              case let .textDocument(document) = content,
              let blockIndex = document.blocks.firstIndex(where: {
                  $0.id == blockID
              }) else {
            throw NotebookRepositoryError.textBlockNotFound(
                pageID: pageID,
                blockID: blockID
            )
        }
        var block = document.blocks[blockIndex]
        if let textDocumentSourceSnapshotTextOverride {
            block.text = textDocumentSourceSnapshotTextOverride
        }
        return TextDocumentSourceSnapshot(
            noteID: noteID,
            pageID: pageID,
            blockIndex: blockIndex,
            block: block,
            noteRevision: 7
        )
    }

    func savePageContent(
        _ content: PageContent,
        notebookID: UUID,
        pageID: UUID
    ) async throws {
        mutationCount += 1
        persistenceEvents.append("savePageContent")
        await pageContentSaveGate.wait()
        if transientPageContentFailures > 0 {
            transientPageContentFailures -= 1
            throw StubError.pageContentWriteFailed
        }
        if duplicateFailure == .pageContentWrite {
            throw StubError.pageContentWriteFailed
        }
        pageContents[PageContentKey(notebookID: notebookID, pageID: pageID)] = content
        savedPageContents.append(content)
    }

    func loadHandwritingRecognition(
        notebookID: UUID,
        pageID: UUID
    ) async throws -> HandwritingRecognitionDocument? {
        handwritingRecognitionLoadCallCount += 1
        let snapshot = handwritingRecognition[PageContentKey(
            notebookID: notebookID,
            pageID: pageID
        )]
        if let countdown = handwritingRecognitionLoadBlockCountdown {
            if countdown == 0 {
                handwritingRecognitionLoadBlockCountdown = nil
                hasBlockedHandwritingRecognitionLoad = true
                await handwritingRecognitionLoadGate?.wait()
            } else {
                handwritingRecognitionLoadBlockCountdown = countdown - 1
            }
        }
        return snapshot
    }

    func saveHandwritingRecognition(
        _ document: HandwritingRecognitionDocument,
        notebookID: UUID,
        pageID: UUID,
        expectedRunID: UUID?,
        expectedRevision: Int64?
    ) async throws {
        let key = PageContentKey(notebookID: notebookID, pageID: pageID)
        let stored = handwritingRecognition[key]
        switch (expectedRunID, expectedRevision, stored) {
        case (nil, nil, nil):
            guard document.revision == 1 else {
                throw NotebookRepositoryError.handwritingRecognitionConflict(
                    pageID: PageID(pageID)
                )
            }
        case let (.some(runID), .some(revision), .some(stored)):
            guard stored.runID == runID,
                  stored.revision == revision,
                  document.revision == revision + 1 else {
                throw NotebookRepositoryError.handwritingRecognitionConflict(
                    pageID: PageID(pageID)
                )
            }
        default:
            throw NotebookRepositoryError.handwritingRecognitionConflict(
                pageID: PageID(pageID)
            )
        }
        handwritingRecognition[key] = document
        persistenceEvents.append("saveHandwritingRecognition")
    }

    func setInk(_ data: Data, notebookID: UUID, pageID: UUID) {
        inkByPage[PageContentKey(notebookID: notebookID, pageID: pageID)] = data
    }

    func setHandwritingRecognition(
        _ document: HandwritingRecognitionDocument,
        notebookID: UUID,
        pageID: UUID
    ) {
        handwritingRecognition[PageContentKey(
            notebookID: notebookID,
            pageID: pageID
        )] = document
    }

    func storedHandwritingRecognition(
        notebookID: UUID,
        pageID: UUID
    ) -> HandwritingRecognitionDocument? {
        handwritingRecognition[PageContentKey(
            notebookID: notebookID,
            pageID: pageID
        )]
    }

    func availableImageAssets(notebookID: UUID) async throws -> [AssetDescriptor] {
        []
    }

    func assetURLs(
        notebookID: UUID,
        assetIDs: Set<AssetID>
    ) async throws -> [AssetID: URL] {
        Dictionary(uniqueKeysWithValues: assetIDs.map { assetID in
            (
                assetID,
                URL(fileURLWithPath: "/tmp/assets").appendingPathComponent(assetID.rawValue)
            )
        })
    }

    func assetURL(notebookID: UUID, relativePath: String) async throws -> URL {
        libraryURL.appendingPathComponent(relativePath)
    }

    func installAsset(_ data: Data, relativePath: String) throws {
        let url = libraryURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    func packageURL(notebookID: UUID) async throws -> URL {
        persistenceEvents.append("packageURL")
        return URL(fileURLWithPath: "/tmp/\(notebookID.uuidString.lowercased()).notepkg")
    }

    func exportNotebookSnapshots(to directory: URL) async throws -> [URL] {
        persistenceEvents.append("exportNotebookSnapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try notebooks.keys.sorted { $0.uuidString < $1.uuidString }.map { id in
            let url = directory
                .appendingPathComponent(id.uuidString.lowercased(), isDirectory: false)
                .appendingPathExtension("notepkg")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    func libraryDirectoryURL() async throws -> URL {
        libraryURL
    }

    func validateRestoredNotebookPackages(_ urls: [URL]) async throws {}

    func deleteNotebook(id: UUID, permanently: Bool) async throws {
        mutationCount += 1
        if permanently {
            notebooks.removeValue(forKey: id)
            pageContents = pageContents.filter { $0.key.notebookID != id }
            canvasElements = canvasElements.filter { $0.key.notebookID != id }
        } else if var notebook = notebooks[id] {
            notebook.deletedAt = .now
            notebooks[id] = notebook
        }
    }

    func setRootDirectory(_ url: URL?) async throws {
        let preparation = NotesAppLibraryRootPreparation()
        try await prepareRootDirectoryTransition(to: url, preparation: preparation)
        let transition = try await beginRootDirectoryTransition(preparation)
        try await commitRootDirectoryTransition(transition)
        await finalizeRootDirectoryTransition(transition)
    }

    func prepareRootDirectoryTransition(
        to url: URL?,
        preparation: NotesAppLibraryRootPreparation
    ) async throws {
        guard pendingRootTransition == nil,
              pendingRootPreparation == nil else {
            throw StubError.invalidRootTransition
        }
        _ = url
        pendingRootPreparation = preparation
    }

    func beginRootDirectoryTransition(
        _ preparation: NotesAppLibraryRootPreparation
    ) async throws -> NotesAppLibraryRootTransition {
        guard pendingRootTransition == nil,
              pendingRootPreparation == preparation else {
            throw StubError.invalidRootTransition
        }
        pendingRootPreparation = nil
        mutationCount += 1
        rootChangeCallCount += 1
        let transition = NotesAppLibraryRootTransition()
        pendingRootTransition = transition
        pendingRootTransitionIsCommitted = false
        return transition
    }

    func cancelRootDirectoryPreparation(
        _ preparation: NotesAppLibraryRootPreparation
    ) async {
        if pendingRootPreparation == preparation {
            pendingRootPreparation = nil
        }
    }

    func commitRootDirectoryTransition(
        _ transition: NotesAppLibraryRootTransition
    ) async throws {
        guard pendingRootTransition == transition else {
            throw StubError.invalidRootTransition
        }
        rootCommitCallCount += 1
        if rootCommitFailures > 0 {
            rootCommitFailures -= 1
            throw StubError.invalidRootTransition
        }
        pendingRootTransitionIsCommitted = true
    }

    func finalizeRootDirectoryTransition(
        _ transition: NotesAppLibraryRootTransition
    ) async {
        guard pendingRootTransition == transition,
              pendingRootTransitionIsCommitted else { return }
        rootFinalizeCallCount += 1
        pendingRootTransition = nil
        pendingRootTransitionIsCommitted = false
    }

    func rollbackRootDirectoryTransition(
        _ transition: NotesAppLibraryRootTransition
    ) async {
        guard pendingRootTransition == transition else { return }
        rootRollbackCallCount += 1
        pendingRootTransition = nil
        pendingRootTransitionIsCommitted = false
    }

    func rootDescription() async -> String {
        "Test Library"
    }

    func persistedNotebook(id: UUID) -> EditorNotebook? {
        notebooks[id]
    }

    func persistedPageContent(notebookID: UUID, pageID: UUID) -> PageContent? {
        pageContents[PageContentKey(notebookID: notebookID, pageID: pageID)]
    }

    func persistedCanvasElements(notebookID: UUID, pageID: UUID) -> [CanvasElement]? {
        canvasElements[PageContentKey(notebookID: notebookID, pageID: pageID)]
    }

    func setPageContent(_ content: PageContent, notebookID: UUID, pageID: UUID) {
        pageContents[PageContentKey(notebookID: notebookID, pageID: pageID)] = content
    }

    func setCanvasElements(
        _ elements: [CanvasElement],
        notebookID: UUID,
        pageID: UUID
    ) {
        canvasElements[PageContentKey(notebookID: notebookID, pageID: pageID)] = elements
    }

    func removePageContent(notebookID: UUID, pageID: UUID) {
        pageContents.removeValue(
            forKey: PageContentKey(notebookID: notebookID, pageID: pageID)
        )
    }
}

private actor SearchIndexSpy: SearchIndexing {
    private struct PageSearchKey: Hashable, Sendable {
        let notebookID: UUID
        let pageID: UUID
    }

    struct SegmentQuery: Equatable, Sendable {
        let text: String
        let notebookID: UUID?
        let limit: Int
    }

    private var documents: [UUID: SearchIndexDocument]
    private var notebookTitlePublicationGenerations: [UUID: UInt64] = [:]
    private var deletedPageSearchTombstones: [PageSearchKey: Set<UUID>] = [:]
    private var queryResponse: [LocalSearchHit]
    private var segmentQueryResponse: [LocalSearchSegmentHit]
    private let failingUpsertDocumentIDs: Set<UUID>
    private let failingRemoveDocumentIDs: Set<UUID>
    private let failingRemoveNotebookIDs: Set<UUID>
    private let failingRetainSources: Set<RecognizedTextSource>
    private var emptyNotebookRetentionFailuresRemaining: Int
    private var removePageDocumentsFailuresRemaining: Int
    private var blockedDocumentID: UUID?
    private var documentReadGate: AsyncGate?
    private var blockedUpsertDocumentID: UUID?
    private var blockedUpsertForcedRevision: Int?
    private var upsertGate: AsyncGate?
    private var blockedRemoveDocumentID: UUID?
    private var removeGate: AsyncGate?
    private var emptyNotebookRetentionGate: AsyncGate?
    private var segmentQueryGate: AsyncGate?
    private(set) var removedDocumentIDs: [UUID] = []
    private(set) var lastSegmentQuery: SegmentQuery?
    private(set) var hasBlockedDocumentRead = false
    private(set) var hasBlockedUpsert = false
    private(set) var hasBlockedRemove = false
    private(set) var hasBlockedEmptyNotebookRetention = false
    private(set) var hasBlockedSegmentQuery = false

    init(
        documents: [SearchIndexDocument] = [],
        queryResponse: [LocalSearchHit] = [],
        segmentQueryResponse: [LocalSearchSegmentHit] = [],
        failingUpsertDocumentIDs: Set<UUID> = [],
        failingRemoveDocumentIDs: Set<UUID> = [],
        failingRemoveNotebookIDs: Set<UUID> = [],
        failingRetainSources: Set<RecognizedTextSource> = [],
        emptyNotebookRetentionFailures: Int = 0,
        removePageDocumentsFailures: Int = 0
    ) {
        self.documents = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        self.queryResponse = queryResponse
        self.segmentQueryResponse = segmentQueryResponse
        self.failingUpsertDocumentIDs = failingUpsertDocumentIDs
        self.failingRemoveDocumentIDs = failingRemoveDocumentIDs
        self.failingRemoveNotebookIDs = failingRemoveNotebookIDs
        self.failingRetainSources = failingRetainSources
        emptyNotebookRetentionFailuresRemaining = max(
            0,
            emptyNotebookRetentionFailures
        )
        removePageDocumentsFailuresRemaining = max(
            0,
            removePageDocumentsFailures
        )
    }

    func upsert(_ document: SearchIndexDocument) async throws {
        var candidate = document
        if blockedUpsertDocumentID == document.id, let upsertGate {
            blockedUpsertDocumentID = nil
            let forcedRevision = blockedUpsertForcedRevision
            blockedUpsertForcedRevision = nil
            hasBlockedUpsert = true
            await upsertGate.wait()
            if let forcedRevision {
                candidate.revision = forcedRevision
            }
        }
        if failingUpsertDocumentIDs.contains(candidate.id) {
            throw StubError.searchWriteFailed
        }
        if let pageID = candidate.pageID,
           deletedPageSearchTombstones[PageSearchKey(
               notebookID: candidate.notebookID,
               pageID: pageID
           )]?.contains(candidate.id) == true {
            return
        }
        if let old = documents[candidate.id] {
            if old.revision > candidate.revision { return }
            if old.revision == candidate.revision {
                guard old == candidate else { throw StubError.searchRevisionConflict }
                return
            }
        }
        documents[candidate.id] = candidate
        if Self.isNotebookTitleAuthority(candidate) {
            notebookTitlePublicationGenerations.removeValue(
                forKey: candidate.notebookID
            )
        }
    }

    func revision(for documentID: UUID) -> Int? {
        guard let document = documents[documentID],
              !isPageDocumentTombstoned(document) else { return nil }
        return document.revision
    }

    func document(for documentID: UUID) async -> SearchIndexDocument? {
        if blockedDocumentID == documentID, let documentReadGate {
            blockedDocumentID = nil
            hasBlockedDocumentRead = true
            await documentReadGate.wait()
        }
        guard let document = documents[documentID],
              !isPageDocumentTombstoned(document) else { return nil }
        return document
    }

    func retitleDocument(
        documentID: UUID,
        notebookID: UUID,
        pageID: UUID?
    ) async throws {
        guard var document = documents[documentID],
              !isPageDocumentTombstoned(document),
              document.notebookID == notebookID,
              document.pageID == pageID else { return }
        guard let titleAuthority = documents[notebookID],
              Self.isNotebookTitleAuthority(titleAuthority) else {
            throw StubError.searchRevisionConflict
        }
        guard document.title != titleAuthority.title else { return }
        guard document.revision < Int.max else {
            throw StubError.searchRevisionConflict
        }
        document.title = titleAuthority.title
        document.revision += 1
        documents[documentID] = document
    }

    func upsertUsingCurrentNotebookTitle(
        _ document: SearchIndexDocument
    ) async throws {
        var candidate = document
        if blockedUpsertDocumentID == document.id, let upsertGate {
            blockedUpsertDocumentID = nil
            let forcedRevision = blockedUpsertForcedRevision
            blockedUpsertForcedRevision = nil
            hasBlockedUpsert = true
            await upsertGate.wait()
            if let forcedRevision {
                candidate.revision = forcedRevision
            }
        }
        guard let pageID = candidate.pageID else {
            throw StubError.searchRevisionConflict
        }
        let pageKey = PageSearchKey(
            notebookID: candidate.notebookID,
            pageID: pageID
        )
        guard deletedPageSearchTombstones[pageKey] == nil else { return }
        guard let titleAuthority = documents[candidate.notebookID],
              Self.isNotebookTitleAuthority(titleAuthority) else {
            throw StubError.searchRevisionConflict
        }
        candidate.title = titleAuthority.title
        if let old = documents[candidate.id] {
            guard old.notebookID == candidate.notebookID,
                  old.pageID == candidate.pageID else {
                throw StubError.searchRevisionConflict
            }
        }
        if failingUpsertDocumentIDs.contains(candidate.id) {
            throw StubError.searchWriteFailed
        }
        if let old = documents[candidate.id] {
            if old.revision > candidate.revision { return }
            if old.revision == candidate.revision {
                guard old == candidate else {
                    throw StubError.searchRevisionConflict
                }
                return
            }
        }
        documents[candidate.id] = candidate
    }

    func upsertNotebookTitleAuthority(
        _ document: SearchIndexDocument,
        publicationGeneration: UInt64
    ) async throws {
        var candidate = document
        if blockedUpsertDocumentID == document.id, let upsertGate {
            blockedUpsertDocumentID = nil
            let forcedRevision = blockedUpsertForcedRevision
            blockedUpsertForcedRevision = nil
            hasBlockedUpsert = true
            await upsertGate.wait()
            if let forcedRevision {
                candidate.revision = forcedRevision
            }
        }
        guard Self.isNotebookTitleAuthority(candidate) else {
            throw StubError.searchRevisionConflict
        }
        guard candidate.revision >= 0 else {
            throw StubError.searchRevisionConflict
        }
        if let currentGeneration = notebookTitlePublicationGenerations[
            candidate.notebookID
        ] {
            if currentGeneration == publicationGeneration {
                guard let existing = documents[candidate.id],
                      Self.hasSameTitleAuthorityPayload(
                        existing,
                        candidate
                      ) else {
                    throw StubError.searchRevisionConflict
                }
                return
            }
            guard Self.isNewerPublicationGeneration(
                publicationGeneration,
                than: currentGeneration
            ) else { return }
        }
        if failingUpsertDocumentIDs.contains(candidate.id) {
            throw StubError.searchWriteFailed
        }
        if let existing = documents[candidate.id] {
            guard Self.isNotebookTitleAuthority(existing),
                  existing.notebookID == candidate.notebookID,
                  existing.revision < Int.max else {
                throw StubError.searchRevisionConflict
            }
            candidate.revision = max(
                candidate.revision,
                existing.revision + 1
            )
        }
        documents[candidate.id] = candidate
        notebookTitlePublicationGenerations[candidate.notebookID] =
            publicationGeneration
    }

    func blockNextDocumentRead(_ documentID: UUID) {
        blockedDocumentID = documentID
        documentReadGate = AsyncGate(isOpen: false)
        hasBlockedDocumentRead = false
    }

    func releaseBlockedDocumentRead() async {
        let gate = documentReadGate
        documentReadGate = nil
        await gate?.open()
    }

    func blockNextUpsert(
        _ documentID: UUID,
        forcedRevision: Int? = nil
    ) {
        blockedUpsertDocumentID = documentID
        blockedUpsertForcedRevision = forcedRevision
        upsertGate = AsyncGate(isOpen: false)
        hasBlockedUpsert = false
    }

    func releaseBlockedUpsert() async {
        let gate = upsertGate
        upsertGate = nil
        await gate?.open()
    }

    func blockNextRemove(_ documentID: UUID) {
        blockedRemoveDocumentID = documentID
        removeGate = AsyncGate(isOpen: false)
        hasBlockedRemove = false
    }

    func releaseBlockedRemove() async {
        let gate = removeGate
        removeGate = nil
        await gate?.open()
    }

    func blockNextEmptyNotebookRetention() {
        emptyNotebookRetentionGate = AsyncGate(isOpen: false)
        hasBlockedEmptyNotebookRetention = false
    }

    func releaseEmptyNotebookRetention() async {
        let gate = emptyNotebookRetentionGate
        emptyNotebookRetentionGate = nil
        await gate?.open()
    }

    func blockNextSegmentQuery() {
        segmentQueryGate = AsyncGate(isOpen: false)
        hasBlockedSegmentQuery = false
    }

    func releaseSegmentQuery() async {
        let gate = segmentQueryGate
        segmentQueryGate = nil
        await gate?.open()
    }

    func setQueryResponses(
        library: [LocalSearchHit],
        editor: [LocalSearchSegmentHit]
    ) {
        queryResponse = library
        segmentQueryResponse = editor
    }

    func remove(documentID: UUID) async throws {
        removedDocumentIDs.append(documentID)
        if blockedRemoveDocumentID == documentID, let removeGate {
            blockedRemoveDocumentID = nil
            hasBlockedRemove = true
            await removeGate.wait()
        }
        if failingRemoveDocumentIDs.contains(documentID) {
            throw StubError.searchWriteFailed
        }
        let removed = documents.removeValue(forKey: documentID)
        if let removed, Self.isNotebookTitleAuthority(removed) {
            notebookTitlePublicationGenerations.removeValue(
                forKey: removed.notebookID
            )
        }
    }

    func removePageDocuments(
        notebookID: UUID,
        pageID: UUID,
        documentIDs: Set<UUID>
    ) async throws {
        let pageKey = PageSearchKey(
            notebookID: notebookID,
            pageID: pageID
        )
        deletedPageSearchTombstones[pageKey, default: []]
            .formUnion(documentIDs)
        if removePageDocumentsFailuresRemaining > 0 {
            removePageDocumentsFailuresRemaining -= 1
            throw StubError.searchWriteFailed
        }
        documents = documents.filter { id, document in
            guard documentIDs.contains(id) else { return true }
            return document.notebookID != notebookID
                || document.pageID != pageID
        }
    }

    func removeNotebook(_ notebookID: UUID) async throws {
        if failingRemoveNotebookIDs.contains(notebookID) {
            throw StubError.searchWriteFailed
        }
        documents = documents.filter { $0.value.notebookID != notebookID }
        notebookTitlePublicationGenerations.removeValue(forKey: notebookID)
        deletedPageSearchTombstones = deletedPageSearchTombstones.filter {
            $0.key.notebookID != notebookID
        }
    }

    func retainDocuments(
        notebookID: UUID,
        source: RecognizedTextSource,
        documentIDs: Set<UUID>
    ) async throws {
        if failingRetainSources.contains(source) {
            throw StubError.searchWriteFailed
        }
        documents = documents.filter { id, document in
            guard document.notebookID == notebookID,
                  !document.segments.isEmpty,
                  document.segments.contains(where: { $0.source == source }) else {
                return true
            }
            return documentIDs.contains(id)
        }
    }

    func retainNotebooks(_ notebookIDs: Set<UUID>) async throws {
        if notebookIDs.isEmpty, emptyNotebookRetentionFailuresRemaining > 0 {
            emptyNotebookRetentionFailuresRemaining -= 1
            throw StubError.searchWriteFailed
        }
        if notebookIDs.isEmpty, let emptyNotebookRetentionGate {
            hasBlockedEmptyNotebookRetention = true
            await emptyNotebookRetentionGate.wait()
        }
        documents = documents.filter { notebookIDs.contains($0.value.notebookID) }
        notebookTitlePublicationGenerations =
            notebookTitlePublicationGenerations.filter {
                notebookIDs.contains($0.key)
            }
        deletedPageSearchTombstones = deletedPageSearchTombstones.filter {
            notebookIDs.contains($0.key.notebookID)
        }
    }

    func query(_ text: String, notebookID: UUID?, limit: Int) async -> [LocalSearchHit] {
        Array(queryResponse.prefix(max(0, limit)))
    }

    func querySegments(
        _ text: String,
        notebookID: UUID?,
        limit: Int
    ) async -> [LocalSearchSegmentHit] {
        if let segmentQueryGate {
            hasBlockedSegmentQuery = true
            await segmentQueryGate.wait()
        }
        lastSegmentQuery = SegmentQuery(
            text: text,
            notebookID: notebookID,
            limit: limit
        )
        return segmentQueryResponse
    }

    func rebuild(from documents: [SearchIndexDocument]) async throws {
        self.documents = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        notebookTitlePublicationGenerations.removeAll()
        deletedPageSearchTombstones.removeAll()
    }

    func contains(documentID: UUID) -> Bool {
        documents[documentID] != nil
    }

    func document(id: UUID) -> SearchIndexDocument? {
        documents[id]
    }

    private static func isNotebookTitleAuthority(
        _ document: SearchIndexDocument
    ) -> Bool {
        document.id == document.notebookID
            && document.pageID == nil
            && document.sourceFingerprint == nil
            && document.segments.isEmpty
    }

    private func isPageDocumentTombstoned(
        _ document: SearchIndexDocument
    ) -> Bool {
        guard let pageID = document.pageID else { return false }
        let key = PageSearchKey(
            notebookID: document.notebookID,
            pageID: pageID
        )
        return deletedPageSearchTombstones[key]?.contains(document.id) == true
    }

    private static func hasSameTitleAuthorityPayload(
        _ left: SearchIndexDocument,
        _ right: SearchIndexDocument
    ) -> Bool {
        left.id == right.id
            && left.notebookID == right.notebookID
            && left.pageID == right.pageID
            && left.title == right.title
            && left.sourceFingerprint == right.sourceFingerprint
            && left.segments == right.segments
            && left.modifiedAt == right.modifiedAt
    }

    private static func isNewerPublicationGeneration(
        _ candidate: UInt64,
        than current: UInt64
    ) -> Bool {
        let distance = candidate &- current
        return distance != 0 && distance <= UInt64.max / 2
    }
}

private actor BackupServiceSpy: NotesBackupServicing {
    private var history: [BackupSnapshot] = []
    private(set) var lastSourceNames: [String] = []

    func createSnapshot(
        notebookURLs: [URL],
        at destination: BackupDestination,
        keepLatest: Int
    ) async throws -> BackupSnapshot {
        lastSourceNames = notebookURLs.map(\.lastPathComponent).sorted()
        guard !lastSourceNames.isEmpty else { throw FileBackupError.noNotebooks }
        let snapshot = BackupSnapshot(
            folderName: "Notes Backup Test",
            notebookNames: lastSourceNames
        )
        history.insert(snapshot, at: 0)
        return snapshot
    }

    func snapshots(at destination: BackupDestination) async throws -> [BackupSnapshot] {
        history
    }

    func restore(
        _ snapshot: BackupSnapshot,
        from destination: BackupDestination,
        into libraryDirectory: URL
    ) async throws -> [URL] {
        snapshot.notebookNames.map {
            libraryDirectory.appendingPathComponent($0, isDirectory: true)
        }
    }
}

private enum StubError: LocalizedError, Sendable {
    case missingNotebook
    case inkWriteFailed
    case elementWriteFailed
    case pageContentWriteFailed
    case rollbackFailed
    case searchRevisionConflict
    case searchWriteFailed
    case handwritingRecognitionFailed
    case libraryLoadFailed
    case invalidRootTransition

    var errorDescription: String? {
        switch self {
        case .missingNotebook: "The test notebook is missing."
        case .inkWriteFailed: "The injected ink write failed."
        case .elementWriteFailed: "The injected element write failed."
        case .pageContentWriteFailed: "The injected page-content write failed."
        case .rollbackFailed: "The injected rollback failed."
        case .searchRevisionConflict: "The injected search revision conflicted."
        case .searchWriteFailed: "The injected search write failed."
        case .handwritingRecognitionFailed: "The injected handwriting recognition failed."
        case .libraryLoadFailed: "The injected candidate library load failed."
        case .invalidRootTransition: "The injected root transition is invalid."
        }
    }
}

private func makeNotebook(
    title: String,
    kind: NotebookKind = .notebook,
    template: PaperTemplate = .blank,
    pageCount: Int = 1
) -> EditorNotebook {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    return EditorNotebook(
        id: UUID(),
        title: title,
        kind: kind,
        createdAt: now,
        modifiedAt: now,
        isFavorite: false,
        deletedAt: nil,
        coverHue: 0.42,
        pages: (0 ..< pageCount).map { _ in
            var page = EditorPage.newPage(for: kind, template: template)
            page.modifiedAt = now
            return page
        }
    )
}
