import Foundation
import Testing
@testable import NotesServices

@Test("Search finds Traditional Chinese text and preserves page context")
func localSearchFindsChineseText() async throws {
    let notebookID = UUID()
    let pageID = UUID()
    let index = LocalSearchIndex()
    try await index.upsert(
        SearchIndexDocument(
            notebookID: notebookID,
            pageID: pageID,
            title: "物理筆記",
            revision: 1,
            segments: [
                RecognizedTextSegment(
                    text: "牛頓第二運動定律說明力、質量與加速度的關係。",
                    pageID: pageID,
                    source: .typedText
                )
            ]
        )
    )

    let hits = await index.query("加速度", notebookID: notebookID, limit: 10)
    #expect(hits.count == 1)
    #expect(hits.first?.pageID == pageID)
    #expect(hits.first?.snippet.contains("加速度") == true)
}

@Test("Segment search returns every bounded navigable match")
func localSegmentSearchPreservesEachMatch() async throws {
    let notebookID = UUID()
    let otherNotebookID = UUID()
    let firstPageID = UUID()
    let secondPageID = UUID()
    let firstSegmentID = UUID()
    let secondSegmentID = UUID()
    let index = LocalSearchIndex()
    try await index.upsert(SearchIndexDocument(
        notebookID: notebookID,
        title: "Physics",
        revision: 1,
        segments: [
            RecognizedTextSegment(
                id: firstSegmentID,
                text: "Force changes acceleration.",
                pageID: firstPageID,
                source: .typedText
            ),
            RecognizedTextSegment(
                id: secondSegmentID,
                text: "Acceleration depends on mass.",
                pageID: secondPageID,
                source: .pdfText
            ),
            RecognizedTextSegment(
                text: "Unrelated paragraph.",
                pageID: secondPageID,
                source: .typedText
            ),
        ]
    ))
    try await index.upsert(SearchIndexDocument(
        notebookID: otherNotebookID,
        title: "Other",
        revision: 1,
        segments: [
            RecognizedTextSegment(
                text: "Acceleration outside the requested notebook.",
                source: .typedText
            )
        ]
    ))

    let hits = await index.querySegments(
        "acceleration",
        notebookID: notebookID,
        limit: 10
    )
    #expect(hits.count == 2)
    #expect(
        Set(hits.map(\.id.segmentID)) == [firstSegmentID, secondSegmentID]
    )
    #expect(Set(hits.map(\.pageID)) == [firstPageID, secondPageID])

    let bounded = await index.querySegments(
        "acceleration",
        notebookID: notebookID,
        limit: 1
    )
    #expect(bounded.count == 1)
}

@Test("Segment search prefers phrases and requires every query token")
func localSegmentSearchUsesStrictTokenMatching() async throws {
    let notebookID = UUID()
    let firstDocumentID = UUID()
    let secondDocumentID = UUID()
    let sharedSegmentID = UUID()
    let index = LocalSearchIndex()
    try await index.upsert(SearchIndexDocument(
        id: firstDocumentID,
        notebookID: notebookID,
        pageID: UUID(),
        title: "Phrase",
        revision: 1,
        segments: [
            RecognizedTextSegment(
                id: sharedSegmentID,
                text: "alpha beta appears together",
                source: .typedText
            ),
        ]
    ))
    try await index.upsert(SearchIndexDocument(
        id: secondDocumentID,
        notebookID: notebookID,
        pageID: UUID(),
        title: "Tokens",
        revision: 1,
        segments: [
            RecognizedTextSegment(
                id: sharedSegmentID,
                text: "alpha appears far away from beta",
                source: .pdfText
            ),
            RecognizedTextSegment(
                text: "alpha alone must not match",
                source: .typedText
            ),
        ]
    ))

    let hits = await index.querySegments(
        "alpha beta",
        notebookID: notebookID,
        limit: 10
    )

    #expect(hits.count == 2)
    #expect(hits.first?.id.documentID == firstDocumentID)
    #expect(Set(hits.map(\.id)).count == 2)
    #expect(Set(hits.map(\.id.documentID)) == [firstDocumentID, secondDocumentID])
}

@Test("Older search revisions cannot overwrite newer content")
func localSearchRejectsStaleRevision() async throws {
    let documentID = UUID()
    let notebookID = UUID()
    let index = LocalSearchIndex()
    try await index.upsert(
        SearchIndexDocument(
            id: documentID,
            notebookID: notebookID,
            title: "New",
            revision: 2,
            segments: [RecognizedTextSegment(text: "最新內容", source: .typedText)]
        )
    )
    try await index.upsert(
        SearchIndexDocument(
            id: documentID,
            notebookID: notebookID,
            title: "Old",
            revision: 1,
            segments: [RecognizedTextSegment(text: "過期內容", source: .typedText)]
        )
    )

    #expect(await index.query("最新", notebookID: nil, limit: 10).count == 1)
    #expect(await index.query("過期", notebookID: nil, limit: 10).isEmpty)
}

@Test("Math evaluator follows precedence and supports functions")
func mathEvaluator() throws {
    let evaluator = MathExpressionEvaluator()
    #expect(try evaluator.evaluate("2 + 3 × 4") == 14)
    #expect(abs(try evaluator.evaluate("sqrt(81) + pow(2, 3)") - 17) < 0.000_001)
    #expect(throws: MathExpressionError.divisionByZero) {
        try evaluator.evaluate("10 / 0")
    }
}

@Test("Study scheduler moves a successful card into the future")
func studyScheduler() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let result = StudyScheduler.review(StudyProgress(), grade: .good, now: now)
    #expect(result.repetitions == 1)
    #expect(result.intervalDays == 1)
    #expect(result.dueAt > now)
}

@Test("Offline intelligence returns actionable meeting notes")
func extractiveMeetingNotes() async throws {
    let provider = ExtractiveIntelligenceProvider()
    let result = try await provider.perform(
        IntelligenceRequest(
            action: .meetingNotes,
            text: "今天確認產品方向。小明需要在週五前完成草稿。下週再次檢查。"
        )
    )
    #expect(result.isGenerative == false)
    #expect(result.text.contains("待辦事項"))
    #expect(result.text.contains("小明需要"))
}

@Test("Extractive Q&A returns matching source excerpts with citations")
func extractiveQuestionAnswering() async throws {
    let provider = ExtractiveIntelligenceProvider()
    let result = try await provider.perform(
        IntelligenceRequest(
            action: .ask(question: "加速度和力有什麼關係？"),
            text: "牛頓第一定律描述慣性。牛頓第二定律指出力等於質量乘以加速度。"
        )
    )
    #expect(result.text.contains("質量乘以加速度"))
    #expect(!result.citations.isEmpty)
}

@Test("Offline calculator is available without a language model")
func intelligenceCalculator() async throws {
    let provider = ExtractiveIntelligenceProvider()
    let result = try await provider.perform(
        IntelligenceRequest(action: .calculate(expression: "(12 + 8) / 4"), text: "calculate")
    )
    #expect(result.text == "5")
    #expect(result.isGenerative == false)
}

@Test("SM-2 lapse is scheduled for a short retry")
func studyLapse() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let progress = StudyProgress(repetitions: 3, intervalDays: 12, easeFactor: 2.5)
    let result = StudyScheduler.review(progress, grade: .again, now: now)
    #expect(result.repetitions == 0)
    #expect(result.lapses == 1)
    #expect(result.dueAt.timeIntervalSince(now) == 600)
}

@Test("Model identifiers cannot escape the model directory")
func modelIdentifierTraversalIsRejected() async throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("NotesModelSafety-\(UUID().uuidString)", isDirectory: true)
    let root = parent.appendingPathComponent("Models", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let manager = ModelDownloadManager(rootDirectory: root)

    await #expect(throws: ModelDownloadError.unsafePath("..")) {
        try await manager.removeModel(id: "..")
    }
    #expect(FileManager.default.fileExists(atPath: parent.path))
}
