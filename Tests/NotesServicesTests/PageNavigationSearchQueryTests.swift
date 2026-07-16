import Foundation
import Testing
@testable import NotesServices

@Test("Bookmark queries accept only complete localized aliases")
func bookmarkQueryAliasesAreExact() throws {
    for query in [
        "bookmark",
        "BOOKMARK",
        " bookmarked ",
        "bookmarked\t page",
        "書籤",
        " 已加書籤\n",
    ] {
        #expect(PageNavigationSearchQueryPolicy.isExactBookmarkQuery(query))
    }

    for query in [
        "",
        "book",
        "mark",
        "bookmarks",
        "bookmark!",
        "favorite",
        "書",
        "書籤頁",
    ] {
        #expect(!PageNavigationSearchQueryPolicy.isExactBookmarkQuery(query))
    }

    let encodedSource = try JSONEncoder().encode(RecognizedTextSource.bookmark)
    #expect(String(decoding: encodedSource, as: UTF8.self) == "\"bookmark\"")
    #expect(
        try JSONDecoder().decode(
            RecognizedTextSource.self,
            from: encodedSource
        ) == .bookmark
    )
}

@Test("Library bookmark search preserves its page target without title fallback")
func libraryBookmarkSearchPreservesPageTarget() async throws {
    let notebookID = UUID()
    let bookmarkedPageID = UUID()
    let outlinePageID = UUID()
    let authoredPageID = UUID()
    let bookmarkDocumentID = UUID()
    let outlineDocumentID = UUID()
    let authoredDocumentID = UUID()
    let index = LocalSearchIndex()

    try await index.rebuild(from: [
        SearchIndexDocument(
            id: bookmarkDocumentID,
            notebookID: notebookID,
            pageID: bookmarkedPageID,
            title: "Bookmark research",
            revision: 1,
            segments: [RecognizedTextSegment(
                text: PageNavigationSearchQueryPolicy.bookmarkSegmentText,
                pageID: bookmarkedPageID,
                source: .bookmark
            )]
        ),
        SearchIndexDocument(
            id: outlineDocumentID,
            notebookID: notebookID,
            pageID: outlinePageID,
            title: "Bookmark research",
            revision: 1,
            segments: [RecognizedTextSegment(
                text: "Chapter One",
                pageID: outlinePageID,
                source: .outline
            )]
        ),
        SearchIndexDocument(
            id: notebookID,
            notebookID: notebookID,
            title: "Bookmark research",
            revision: 1,
            segments: []
        ),
        SearchIndexDocument(
            id: authoredDocumentID,
            notebookID: notebookID,
            pageID: authoredPageID,
            title: "Notes",
            revision: 1,
            segments: [RecognizedTextSegment(
                text: "bookmark",
                pageID: authoredPageID,
                source: .typedText
            )]
        ),
    ])

    let hits = await index.query(
        " 已加書籤 ",
        notebookID: notebookID,
        limit: 10
    )
    let englishHits = await index.query(
        "bookmark",
        notebookID: notebookID,
        limit: 10
    )

    #expect(hits.count == 1)
    #expect(hits.first?.documentID == bookmarkDocumentID)
    #expect(hits.first?.pageID == bookmarkedPageID)
    #expect(hits.first?.segment?.pageID == bookmarkedPageID)
    #expect(hits.first?.segment?.source == .bookmark)
    #expect(hits.first?.snippet == "已加書籤")
    #expect(!hits.contains { $0.pageID == outlinePageID })
    #expect(englishHits.count == 1)
    let englishBookmarkHit = try #require(englishHits.first {
        $0.documentID == bookmarkDocumentID
    })
    #expect(englishBookmarkHit.pageID == bookmarkedPageID)
    #expect(englishBookmarkHit.segment?.source == .bookmark)
    #expect(englishBookmarkHit.snippet == "bookmark")
    #expect(!englishHits.contains { $0.documentID == outlineDocumentID })
    #expect(!englishHits.contains { $0.documentID == authoredDocumentID })
    #expect(!englishHits.contains { $0.documentID == notebookID })

    let partialTitleHits = await index.query(
        "book",
        notebookID: notebookID,
        limit: 10
    )
    #expect(partialTitleHits.count == 2)
    #expect(Set(partialTitleHits.map(\.documentID)) == [
        notebookID,
        authoredDocumentID,
    ])
    #expect(partialTitleHits.first {
        $0.documentID == notebookID
    }?.pageID == nil)
    #expect(partialTitleHits.first {
        $0.documentID == authoredDocumentID
    }?.pageID == authoredPageID)
    #expect(!partialTitleHits.contains { $0.documentID == bookmarkDocumentID })
    #expect(!partialTitleHits.contains { $0.documentID == outlineDocumentID })

    let outlineContextTitleHits = await index.query(
        "research",
        notebookID: notebookID,
        limit: 10
    )
    let titleAuthorityHit = try #require(outlineContextTitleHits.first {
        $0.documentID == notebookID
    })
    #expect(titleAuthorityHit.pageID == nil)
    #expect(!outlineContextTitleHits.contains {
        $0.documentID == bookmarkDocumentID
    })
    #expect(!outlineContextTitleHits.contains {
        $0.documentID == outlineDocumentID
    })
}

@Test("Editor bookmark search is exact and returns a navigable semantic hit")
func editorBookmarkSearchIsExactAndNavigable() async throws {
    let notebookID = UUID()
    let pageID = UUID()
    let segmentID = UUID()
    let documentID = UUID()
    let index = LocalSearchIndex()
    try await index.upsert(SearchIndexDocument(
        id: documentID,
        notebookID: notebookID,
        pageID: pageID,
        title: "Research",
        revision: 1,
        segments: [RecognizedTextSegment(
            id: segmentID,
            text: PageNavigationSearchQueryPolicy.bookmarkSegmentText,
            pageID: pageID,
            source: .bookmark
        )]
    ))

    for rejectedQuery in ["book", "mark", "favorite"] {
        #expect(await index.query(
            rejectedQuery,
            notebookID: notebookID,
            limit: 10
        ).isEmpty)
        #expect(await index.querySegments(
            rejectedQuery,
            notebookID: notebookID,
            limit: 10
        ).isEmpty)
    }

    let hits = await index.querySegments(
        "BOOKMARKED   PAGE",
        notebookID: notebookID,
        limit: 10
    )
    #expect(hits.count == 1)
    #expect(hits.first?.id.documentID == documentID)
    #expect(hits.first?.id.segmentID == segmentID)
    #expect(hits.first?.pageID == pageID)
    #expect(hits.first?.segment.source == .bookmark)
    #expect(hits.first?.snippet == "BOOKMARKED   PAGE")
}

@Test("Outline segments retain ordinary full-text query behavior")
func outlineSearchRetainsOrdinaryQueryBehavior() async throws {
    let notebookID = UUID()
    let outlinePageID = UUID()
    let bookmarkPageID = UUID()
    let outlineDocumentID = UUID()
    let index = LocalSearchIndex()
    try await index.rebuild(from: [
        SearchIndexDocument(
            id: outlineDocumentID,
            notebookID: notebookID,
            pageID: outlinePageID,
            title: "Research",
            revision: 1,
            segments: [RecognizedTextSegment(
                text: "Project Atlas Overview",
                pageID: outlinePageID,
                source: .outline
            )]
        ),
        SearchIndexDocument(
            notebookID: notebookID,
            pageID: bookmarkPageID,
            title: "Research",
            revision: 1,
            segments: [RecognizedTextSegment(
                text: PageNavigationSearchQueryPolicy.bookmarkSegmentText,
                pageID: bookmarkPageID,
                source: .bookmark
            )]
        ),
    ])

    let libraryHits = await index.query(
        "tlas",
        notebookID: notebookID,
        limit: 10
    )
    let editorHits = await index.querySegments(
        "project overview",
        notebookID: notebookID,
        limit: 10
    )

    #expect(libraryHits.count == 1)
    #expect(libraryHits.first?.documentID == outlineDocumentID)
    #expect(libraryHits.first?.pageID == outlinePageID)
    #expect(libraryHits.first?.segment?.source == .outline)
    #expect(editorHits.count == 1)
    #expect(editorHits.first?.pageID == outlinePageID)
    #expect(editorHits.first?.segment.source == .outline)
}

@Test("Reserved bookmark queries exclude authored text without changing partial search")
func bookmarkPolicyPreservesOnlyNonsemanticAuthoredSearch() async throws {
    let notebookID = UUID()
    let authoredPageID = UUID()
    let bookmarkedPageID = UUID()
    let authoredDocumentID = UUID()
    let bookmarkDocumentID = UUID()
    let index = LocalSearchIndex()
    try await index.upsert(SearchIndexDocument(
        id: authoredDocumentID,
        notebookID: notebookID,
        pageID: authoredPageID,
        title: "Research",
        revision: 1,
        segments: [RecognizedTextSegment(
            text: "A bookmark catalog for the archive",
            pageID: authoredPageID,
            source: .typedText
        )]
    ))
    try await index.upsert(SearchIndexDocument(
        id: bookmarkDocumentID,
        notebookID: notebookID,
        pageID: bookmarkedPageID,
        title: "Research",
        revision: 1,
        segments: [RecognizedTextSegment(
            text: PageNavigationSearchQueryPolicy.bookmarkSegmentText,
            pageID: bookmarkedPageID,
            source: .bookmark
        )]
    ))

    let partialLibraryHits = await index.query(
        "book",
        notebookID: notebookID,
        limit: 10
    )
    let partialEditorHits = await index.querySegments(
        "book",
        notebookID: notebookID,
        limit: 10
    )
    let exactLibraryHits = await index.query(
        "bookmark",
        notebookID: notebookID,
        limit: 10
    )
    let exactEditorHits = await index.querySegments(
        "bookmark",
        notebookID: notebookID,
        limit: 10
    )

    #expect(partialLibraryHits.map(\.documentID) == [authoredDocumentID])
    #expect(partialLibraryHits.map(\.pageID) == [authoredPageID])
    #expect(partialEditorHits.map(\.id.documentID) == [authoredDocumentID])
    #expect(partialEditorHits.map(\.pageID) == [authoredPageID])
    #expect(exactLibraryHits.map(\.documentID) == [bookmarkDocumentID])
    #expect(exactLibraryHits.map(\.pageID) == [bookmarkedPageID])
    #expect(exactLibraryHits.first?.segment?.source == .bookmark)
    #expect(exactEditorHits.map(\.id.documentID) == [bookmarkDocumentID])
    #expect(exactEditorHits.map(\.pageID) == [bookmarkedPageID])
    #expect(exactEditorHits.first?.segment.source == .bookmark)
}
