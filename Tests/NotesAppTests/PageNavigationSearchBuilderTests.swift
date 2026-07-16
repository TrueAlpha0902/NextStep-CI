import Foundation
import NotesCore
import NotesServices
@testable import NotesApp
import XCTest

final class PageNavigationSearchBuilderTests: XCTestCase {
    func testSegmentsExposeOnlyCanonicalNavigationMetadata() throws {
        let notebookID = UUID()
        let page = EditorPage(
            isBookmarked: true,
            outlineTitle: "  Chapter\n   One  "
        )

        let segments = PageNavigationSearchBuilder.segments(
            for: page,
            notebookID: notebookID
        )

        XCTAssertEqual(segments.count, 2)
        let outline = try XCTUnwrap(segments.first)
        XCTAssertEqual(outline.id, PageNavigationSearchBuilder.outlineSegmentID(
            notebookID: notebookID,
            pageID: page.id
        ))
        XCTAssertEqual(outline.text, "Chapter One")
        XCTAssertEqual(outline.pageID, page.id)
        XCTAssertEqual(outline.source, .outline)

        let bookmark = try XCTUnwrap(segments.last)
        XCTAssertEqual(bookmark.id, PageNavigationSearchBuilder.bookmarkSegmentID(
            notebookID: notebookID,
            pageID: page.id
        ))
        XCTAssertEqual(
            bookmark.text,
            PageNavigationSearchQueryPolicy.bookmarkSegmentText
        )
        XCTAssertEqual(bookmark.pageID, page.id)
        XCTAssertEqual(bookmark.source, .bookmark)
    }

    func testPageWithoutNavigationMetadataHasNoDerivedDocument() {
        let page = EditorPage()
        let notebookID = UUID()

        XCTAssertTrue(PageNavigationSearchBuilder.segments(
            for: page,
            notebookID: notebookID
        ).isEmpty)
        XCTAssertNil(PageNavigationSearchBuilder.document(
            for: page,
            notebookID: notebookID,
            notebookTitle: "Research",
            revision: 1
        ))
    }

    func testDocumentIdentityIsStableNamespacedAndPageBound() {
        let notebookID = UUID()
        let pageID = UUID()
        let documentID = PageNavigationSearchBuilder.documentID(
            notebookID: notebookID,
            pageID: pageID
        )
        let outlineID = PageNavigationSearchBuilder.outlineSegmentID(
            notebookID: notebookID,
            pageID: pageID
        )
        let bookmarkID = PageNavigationSearchBuilder.bookmarkSegmentID(
            notebookID: notebookID,
            pageID: pageID
        )

        XCTAssertEqual(documentID, PageNavigationSearchBuilder.documentID(
            notebookID: notebookID,
            pageID: pageID
        ))
        XCTAssertNotEqual(documentID, pageID)
        XCTAssertNotEqual(documentID, outlineID)
        XCTAssertNotEqual(documentID, bookmarkID)
        XCTAssertNotEqual(outlineID, bookmarkID)
        XCTAssertNotEqual(documentID, PageNavigationSearchBuilder.documentID(
            notebookID: UUID(),
            pageID: pageID
        ))
        XCTAssertNotEqual(documentID, PageNavigationSearchBuilder.documentID(
            notebookID: notebookID,
            pageID: UUID()
        ))
        XCTAssertNotEqual(documentID, CanvasElementSearchBuilder.documentID(
            notebookID: notebookID,
            pageID: pageID
        ))
        XCTAssertNotEqual(documentID, HandwritingSearchBuilder.documentID(
            notebookID: notebookID,
            pageID: pageID
        ))
        for id in [documentID, outlineID, bookmarkID] {
            XCTAssertEqual((id.uuid.6 >> 4) & 0x0f, 8)
            XCTAssertEqual((id.uuid.8 >> 6) & 0x03, 2)
        }
    }

    func testDocumentPreservesPageIdentityAndFingerprintsCompleteMetadata() throws {
        let notebookID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_900_000_000)
        let page = EditorPage(
            modifiedAt: timestamp,
            isBookmarked: true,
            outlineTitle: "Introduction"
        )

        let document = try XCTUnwrap(PageNavigationSearchBuilder.document(
            for: page,
            notebookID: notebookID,
            notebookTitle: "Research",
            revision: 7
        ))

        XCTAssertEqual(document.id, PageNavigationSearchBuilder.documentID(
            notebookID: notebookID,
            pageID: page.id
        ))
        XCTAssertEqual(document.notebookID, notebookID)
        XCTAssertEqual(document.pageID, page.id)
        XCTAssertEqual(document.title, "Research")
        XCTAssertEqual(document.revision, 7)
        XCTAssertEqual(document.modifiedAt, timestamp)
        XCTAssertEqual(document.segments.map(\.pageID), [page.id, page.id])
        XCTAssertEqual(document.sourceFingerprint?.count, 64)
        XCTAssertEqual(
            document.sourceFingerprint,
            PageNavigationSearchBuilder.sourceFingerprint(
                for: document.segments
            )
        )
        XCTAssertNotEqual(
            document.sourceFingerprint,
            PageNavigationSearchBuilder.sourceFingerprint(
                for: Array(document.segments.reversed())
            )
        )

        let outlineOnly = EditorPage(
            id: page.id,
            modifiedAt: timestamp,
            isBookmarked: false,
            outlineTitle: "Introduction"
        )
        let outlineOnlyDocument = try XCTUnwrap(
            PageNavigationSearchBuilder.document(
                for: outlineOnly,
                notebookID: notebookID,
                notebookTitle: "Research",
                revision: 8
            )
        )
        XCTAssertNotEqual(
            document.sourceFingerprint,
            outlineOnlyDocument.sourceFingerprint
        )
    }

    func testBuiltDocumentUsesSameLibraryAndEditorQueryContract() async throws {
        let notebookID = UUID()
        let page = EditorPage(
            isBookmarked: true,
            outlineTitle: "Project Atlas"
        )
        let document = try XCTUnwrap(PageNavigationSearchBuilder.document(
            for: page,
            notebookID: notebookID,
            notebookTitle: "Bookmark research",
            revision: 1
        ))
        let index = LocalSearchIndex()
        try await index.upsert(document)

        let outlineLibraryHits = await index.query(
            "atlas",
            notebookID: notebookID,
            limit: 10
        )
        let bookmarkLibraryHits = await index.query(
            "書籤",
            notebookID: notebookID,
            limit: 10
        )
        let outlineEditorHits = await index.querySegments(
            "project atlas",
            notebookID: notebookID,
            limit: 10
        )
        let bookmarkEditorHits = await index.querySegments(
            "bookmarked",
            notebookID: notebookID,
            limit: 10
        )

        XCTAssertEqual(outlineLibraryHits.map(\.pageID), [page.id])
        XCTAssertEqual(bookmarkLibraryHits.map(\.pageID), [page.id])
        XCTAssertEqual(outlineEditorHits.map(\.pageID), [page.id])
        XCTAssertEqual(bookmarkEditorHits.map(\.pageID), [page.id])
        XCTAssertEqual(outlineEditorHits.first?.segment.source, .outline)
        XCTAssertEqual(bookmarkEditorHits.first?.segment.source, .bookmark)
        let partialBookmarkHits = await index.query(
            "book",
            notebookID: notebookID,
            limit: 10
        )
        XCTAssertTrue(partialBookmarkHits.isEmpty)
    }
}
