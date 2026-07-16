import Foundation
import NotesCore
@testable import NotesApp
import XCTest

final class PageNavigatorModelTests: XCTestCase {
    func testLocalStoreAdapterRoundTripsBookmarkAndOutlineMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NotesPageNavigator-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalNotebookStore(overrideRoot: root)
        let created = try await store.createNotebook(
            title: "Navigation",
            kind: .notebook,
            template: .blank
        )
        let pageID = try XCTUnwrap(created.pages.first?.id)

        _ = try await store.updatePageNavigationMetadata(
            notebookID: created.id,
            pageID: pageID,
            update: .bookmark(true)
        )
        let updated = try await store.updatePageNavigationMetadata(
            notebookID: created.id,
            pageID: pageID,
            update: .outlineTitle("Chapter one")
        )
        let reopened = try await store.loadNotebook(id: created.id)

        XCTAssertEqual(updated, reopened)
        let page = try XCTUnwrap(reopened.pages.first)
        XCTAssertTrue(page.isBookmarked)
        XCTAssertEqual(page.outlineTitle, "Chapter one")
    }

    func testFiltersPreserveNotebookPageOrderAndOriginalPageNumbers() {
        let first = makePage(isBookmarked: true)
        let second = makePage(outlineTitle: "Introduction")
        let third = makePage(isBookmarked: true, outlineTitle: "Details")
        let pages = [first, second, third]

        XCTAssertEqual(
            PageNavigatorPolicy.entries(in: pages, filter: .all).map(\.id),
            pages.map(\.id)
        )
        XCTAssertEqual(
            PageNavigatorPolicy.entries(in: pages, filter: .bookmarks).map(\.id),
            [first.id, third.id]
        )
        let outline = PageNavigatorPolicy.entries(
            in: pages,
            filter: .outline
        )
        XCTAssertEqual(outline.map(\.id), [second.id, third.id])
        XCTAssertEqual(outline.map(\.pageNumber), [2, 3])
    }

    func testOutlineCanonicalizationProducesValidSingleLineCoreMetadata() {
        let canonical = PageNavigationMetadataPolicy.canonicalOutlineTitle(
            " \t First\n\n  section\u{0000}  "
        )

        XCTAssertEqual(canonical, "First section")
        XCTAssertTrue(PageDescriptor.isValidOutlineTitle(canonical))
        XCTAssertNil(
            PageNavigationMetadataPolicy.canonicalOutlineTitle("\n \t")
        )
    }

    func testOutlineCanonicalizationMeetsCharacterAndUTF8BudgetsWithoutSplittingGraphemes() throws {
        let grapheme = "a\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}"
        let raw = String(repeating: grapheme, count: 120)

        let canonical = try XCTUnwrap(
            PageNavigationMetadataPolicy.canonicalOutlineTitle(raw)
        )

        XCTAssertTrue(raw.hasPrefix(canonical))
        XCTAssertLessThanOrEqual(
            canonical.count,
            PageDescriptor.maximumOutlineTitleCharacters
        )
        XCTAssertLessThanOrEqual(
            canonical.utf8.count,
            PageDescriptor.maximumOutlineTitleUTF8Bytes
        )
        XCTAssertTrue(PageDescriptor.isValidOutlineTitle(canonical))
        XCTAssertEqual(
            canonical.unicodeScalars.count,
            canonical.count * grapheme.unicodeScalars.count
        )
    }

    func testLimitedOutlineInputIsSingleLineAndWithinCoreBudgets() {
        let familyEmoji = "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let raw = String(repeating: familyEmoji, count: 200) + "\nnext"

        let limited = PageNavigationMetadataPolicy.limitedOutlineInput(raw)

        XCTAssertFalse(limited.contains("\n"))
        XCTAssertLessThanOrEqual(
            limited.count,
            PageDescriptor.maximumOutlineTitleCharacters
        )
        XCTAssertLessThanOrEqual(
            limited.utf8.count,
            PageDescriptor.maximumOutlineTitleUTF8Bytes
        )
        XCTAssertTrue(raw.hasPrefix(limited))
    }

    func testDuplicatePageClearsBookmarkAndOutlineMetadata() {
        let source = makePage(
            isBookmarked: true,
            outlineTitle: "Source outline"
        )

        let duplicate = PageNavigationMetadataPolicy.duplicatePage(
            from: source,
            modifiedAt: Date(timeIntervalSince1970: 50)
        )

        XCTAssertNotEqual(duplicate.id, source.id)
        XCTAssertEqual(duplicate.kind, source.kind)
        XCTAssertEqual(duplicate.background, source.background)
        XCTAssertFalse(duplicate.isBookmarked)
        XCTAssertNil(duplicate.outlineTitle)
    }

    func testPublicationAuthorityRejectsStaleSelectionAndNewerNotebookSnapshot() {
        let page = makePage()
        let notebook = makeNotebook(pages: [page])
        let mutationID = UUID()
        let authority = PageNavigationMetadataPublicationAuthority(
            mutationID: mutationID,
            notebookSnapshot: notebook,
            selectedPageID: page.id
        )
        var persisted = notebook
        persisted.pages[0].isBookmarked = true

        XCTAssertTrue(PageNavigationMetadataPublicationAuthority.canPublish(
            persisted,
            authority: authority,
            currentMutationID: mutationID,
            currentNotebook: notebook,
            currentSelectedPageID: page.id,
            isReplayMutationLocked: false
        ))
        XCTAssertFalse(PageNavigationMetadataPublicationAuthority.canPublish(
            persisted,
            authority: authority,
            currentMutationID: mutationID,
            currentNotebook: notebook,
            currentSelectedPageID: UUID(),
            isReplayMutationLocked: false
        ))
        var newerNotebook = notebook
        newerNotebook.title = "Newer title"
        XCTAssertFalse(PageNavigationMetadataPublicationAuthority.canPublish(
            persisted,
            authority: authority,
            currentMutationID: mutationID,
            currentNotebook: newerNotebook,
            currentSelectedPageID: page.id,
            isReplayMutationLocked: false
        ))
        XCTAssertFalse(PageNavigationMetadataPublicationAuthority.canPublish(
            persisted,
            authority: authority,
            currentMutationID: mutationID,
            currentNotebook: notebook,
            currentSelectedPageID: page.id,
            isReplayMutationLocked: true
        ))
    }

    func testMutationInterlockSerializesNavigationMetadataAndStructure() {
        XCTAssertTrue(
            PageNavigationMutationInterlockPolicy.canBeginMetadataMutation(
                isReplayMutationLocked: false,
                activeStructuralMutationCount: 0,
                hasStructuralMutationTask: false,
                isMetadataMutationInFlight: false,
                hasPDFExportTask: false
            ),
            "Recording is intentionally absent from the metadata policy."
        )
        XCTAssertFalse(
            PageNavigationMutationInterlockPolicy.canBeginMetadataMutation(
                isReplayMutationLocked: true,
                activeStructuralMutationCount: 0,
                hasStructuralMutationTask: false,
                isMetadataMutationInFlight: false,
                hasPDFExportTask: false
            )
        )
        XCTAssertFalse(
            PageNavigationMutationInterlockPolicy.canBeginMetadataMutation(
                isReplayMutationLocked: false,
                activeStructuralMutationCount: 1,
                hasStructuralMutationTask: true,
                isMetadataMutationInFlight: false,
                hasPDFExportTask: false
            )
        )
        XCTAssertFalse(
            PageNavigationMutationInterlockPolicy.canBeginMetadataMutation(
                isReplayMutationLocked: false,
                activeStructuralMutationCount: 0,
                hasStructuralMutationTask: false,
                isMetadataMutationInFlight: false,
                hasPDFExportTask: true
            )
        )
        XCTAssertFalse(
            PageNavigationMutationInterlockPolicy.canBeginStructuralMutation(
                isReplayMutationLocked: false,
                isAudioStructureMutationLocked: false,
                activeStructuralMutationCount: 0,
                hasStructuralMutationTask: false,
                isMetadataMutationInFlight: true
            )
        )
        XCTAssertFalse(PageNavigationMutationInterlockPolicy.canNavigate(
            isReplayMutationLocked: false,
            activeStructuralMutationCount: 0,
            isMetadataMutationInFlight: true
        ))
    }

    func testNavigationSummaryMergePreservesConcurrentLibraryStateAndMonotonicTime() throws {
        let notebookID = UUID()
        let persisted = LibraryNotebook(
            id: notebookID,
            title: "Stale title",
            kind: .notebook,
            createdAt: Date(timeIntervalSince1970: 1),
            modifiedAt: Date(timeIntervalSince1970: 20),
            isFavorite: false,
            deletedAt: nil,
            pageCount: 1,
            coverHue: 0.1
        )
        let current = LibraryNotebook(
            id: notebookID,
            title: "Concurrent rename",
            kind: .whiteboard,
            createdAt: Date(timeIntervalSince1970: 2),
            modifiedAt: Date(timeIntervalSince1970: 30),
            isFavorite: true,
            deletedAt: Date(timeIntervalSince1970: 25),
            pageCount: 4,
            coverHue: 0.9
        )

        let merged = try XCTUnwrap(PageNavigationMetadataSummaryPolicy.merging(
            persistedNavigationSummary: persisted,
            into: current
        ))

        XCTAssertEqual(merged, current)

        var laterPersisted = persisted
        laterPersisted.modifiedAt = Date(timeIntervalSince1970: 40)
        let advanced = try XCTUnwrap(PageNavigationMetadataSummaryPolicy.merging(
            persistedNavigationSummary: laterPersisted,
            into: current
        ))
        XCTAssertEqual(advanced.title, current.title)
        XCTAssertEqual(advanced.kind, current.kind)
        XCTAssertEqual(advanced.isFavorite, current.isFavorite)
        XCTAssertEqual(advanced.deletedAt, current.deletedAt)
        XCTAssertEqual(advanced.pageCount, current.pageCount)
        XCTAssertEqual(advanced.coverHue, current.coverHue)
        XCTAssertEqual(advanced.modifiedAt, laterPersisted.modifiedAt)
        XCTAssertNil(PageNavigationMetadataSummaryPolicy.merging(
            persistedNavigationSummary: persisted,
            into: nil
        ))
    }

    private func makePage(
        isBookmarked: Bool = false,
        outlineTitle: String? = nil
    ) -> EditorPage {
        EditorPage(
            modifiedAt: Date(timeIntervalSince1970: 10),
            isBookmarked: isBookmarked,
            outlineTitle: outlineTitle
        )
    }

    private func makeNotebook(pages: [EditorPage]) -> EditorNotebook {
        let timestamp = Date(timeIntervalSince1970: 10)
        return EditorNotebook(
            id: UUID(),
            title: "Notebook",
            kind: .notebook,
            createdAt: timestamp,
            modifiedAt: timestamp,
            isFavorite: false,
            deletedAt: nil,
            coverHue: 0.5,
            pages: pages
        )
    }
}
