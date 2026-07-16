import Combine
import Foundation
import NotesServices
import XCTest
@testable import NotesApp

final class NotebookDocumentSearchModelTests: XCTestCase {
    @MainActor
    func testSearchTrimsDebouncesAndWhitespaceResets() async {
        let notebookID = UUID()
        let pageID = UUID()
        let stub = SearchResponseStub(responses: [
            SearchRequestKey(query: "alpha beta", notebookID: notebookID): [
                makeHit(notebookID: notebookID, pageID: pageID, score: 2),
            ],
        ])
        let model = NotebookDocumentSearchModel(search: { query, notebookID in
            await stub.search(query: query, notebookID: notebookID)
        })

        model.search(
            "alpha",
            notebookID: notebookID,
            orderedPageIDs: [pageID]
        )
        try? await Task<Never, Never>.sleep(for: .milliseconds(100))
        model.search(
            "alpha ",
            notebookID: notebookID,
            orderedPageIDs: [pageID]
        )
        XCTAssertEqual(model.query, "alpha ")
        model.search(
            "  alpha beta\t ",
            notebookID: notebookID,
            orderedPageIDs: [pageID]
        )

        let settled = await waitForPhase(.results, model: model)
        XCTAssertTrue(settled)
        XCTAssertEqual(model.query, "  alpha beta\t ")
        XCTAssertEqual(model.results.map(\.pageID), [pageID])
        let requests = await stub.requests()
        XCTAssertEqual(
            requests,
            [SearchRequestKey(query: "alpha beta", notebookID: notebookID)]
        )

        model.search(
            " \n\t ",
            notebookID: notebookID,
            orderedPageIDs: [pageID]
        )
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.query, "")
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selectedPageID)

        try? await Task<Never, Never>.sleep(for: .milliseconds(250))
        let requestsAfterReset = await stub.requests()
        XCTAssertEqual(requestsAfterReset.count, 1)

        model.search(
            String(repeating: "x", count: 2_000),
            notebookID: notebookID,
            orderedPageIDs: [pageID]
        )
        XCTAssertEqual(model.query.count, 1_024)
        model.cancel()
    }

    @MainActor
    func testAggregationFiltersScopesDeduplicatesAndUsesPageOrder() async {
        let notebookID = UUID()
        let otherNotebookID = UUID()
        let firstPageID = UUID()
        let secondPageID = UUID()
        let thirdPageID = UUID()
        let removedPageID = UUID()
        let secondLow = makeHit(
            notebookID: notebookID,
            pageID: secondPageID,
            score: 1,
            snippet: "low"
        )
        let secondHigh = makeHit(
            notebookID: notebookID,
            pageID: secondPageID,
            score: 9,
            snippet: "best"
        )
        let hits = [
            secondLow,
            makeHit(
                notebookID: notebookID,
                pageID: thirdPageID,
                score: 100
            ),
            makeHit(
                notebookID: notebookID,
                pageID: firstPageID,
                score: 4
            ),
            secondHigh,
            secondHigh,
            makeHit(
                notebookID: notebookID,
                pageID: removedPageID,
                score: 200
            ),
            makeHit(
                notebookID: otherNotebookID,
                pageID: firstPageID,
                score: 300
            ),
        ]
        let stub = SearchResponseStub(responses: [
            SearchRequestKey(query: "topic", notebookID: notebookID): hits,
        ])
        let model = NotebookDocumentSearchModel(search: { query, notebookID in
            await stub.search(query: query, notebookID: notebookID)
        })

        model.search(
            "topic",
            notebookID: notebookID,
            orderedPageIDs: [
                thirdPageID,
                firstPageID,
                secondPageID,
                firstPageID,
            ]
        )

        let settled = await waitForPhase(.results, model: model)
        XCTAssertTrue(settled)
        XCTAssertEqual(
            model.results.map(\.pageID),
            [thirdPageID, firstPageID, secondPageID]
        )
        XCTAssertEqual(model.results.last?.matchCount, 2)
        XCTAssertEqual(model.results.last?.bestHit.snippet, "best")
        XCTAssertEqual(model.matchCount, 4)
        XCTAssertEqual(model.selectedPageID, thirdPageID)
        XCTAssertEqual(model.selectedResultNumber, 1)
    }

    @MainActor
    func testOnlyInvalidPageHitsPublishNoResults() async {
        let notebookID = UUID()
        let currentPageID = UUID()
        let stub = SearchResponseStub(responses: [
            SearchRequestKey(query: "missing", notebookID: notebookID): [
                makeHit(
                    notebookID: notebookID,
                    pageID: UUID(),
                    score: 10
                ),
            ],
        ])
        let model = NotebookDocumentSearchModel(search: { query, notebookID in
            await stub.search(query: query, notebookID: notebookID)
        })

        model.search(
            "missing",
            notebookID: notebookID,
            orderedPageIDs: [currentPageID]
        )

        let settled = await waitForPhase(.noResults, model: model)
        XCTAssertTrue(settled)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.matchCount, 0)
        XCTAssertNil(model.selectedResult)
        XCTAssertNil(model.selectedResultNumber)
    }

    @MainActor
    func testSelectionWrapsAndRepairsAcrossResultChanges() async {
        let notebookID = UUID()
        let firstPageID = UUID()
        let secondPageID = UUID()
        let thirdPageID = UUID()
        let responses: [SearchRequestKey: [LocalSearchSegmentHit]] = [
            SearchRequestKey(query: "one", notebookID: notebookID): [
                makeHit(notebookID: notebookID, pageID: firstPageID),
                makeHit(notebookID: notebookID, pageID: secondPageID),
            ],
            SearchRequestKey(query: "two", notebookID: notebookID): [
                makeHit(notebookID: notebookID, pageID: secondPageID),
                makeHit(notebookID: notebookID, pageID: thirdPageID),
            ],
            SearchRequestKey(query: "three", notebookID: notebookID): [
                makeHit(notebookID: notebookID, pageID: thirdPageID),
            ],
        ]
        let stub = SearchResponseStub(responses: responses)
        let model = NotebookDocumentSearchModel(search: { query, notebookID in
            await stub.search(query: query, notebookID: notebookID)
        })
        let pageOrder = [firstPageID, secondPageID, thirdPageID]

        model.search("one", notebookID: notebookID, orderedPageIDs: pageOrder)
        let firstSettled = await waitForPhase(.results, model: model)
        XCTAssertTrue(firstSettled)
        XCTAssertEqual(model.selectPreviousResult()?.pageID, secondPageID)
        XCTAssertEqual(model.selectNextResult()?.pageID, firstPageID)
        XCTAssertEqual(model.select(pageID: secondPageID)?.pageID, secondPageID)

        model.search("two", notebookID: notebookID, orderedPageIDs: pageOrder)
        let secondSettled = await waitForPhase(.results, model: model)
        XCTAssertTrue(secondSettled)
        XCTAssertEqual(model.selectedPageID, secondPageID)
        XCTAssertEqual(model.selectedResultNumber, 1)
        XCTAssertEqual(model.selectNextResult()?.pageID, thirdPageID)
        XCTAssertEqual(model.selectNextResult()?.pageID, secondPageID)

        model.search("three", notebookID: notebookID, orderedPageIDs: pageOrder)
        let thirdSettled = await waitForPhase(.results, model: model)
        XCTAssertTrue(thirdSettled)
        XCTAssertEqual(model.selectedPageID, thirdPageID)
        XCTAssertNil(model.select(pageID: secondPageID))
    }

    @MainActor
    func testLateCancelledSearchCannotCrossNotebookFence() async {
        let firstNotebookID = UUID()
        let secondNotebookID = UUID()
        let firstPageID = UUID()
        let secondPageID = UUID()
        let firstKey = SearchRequestKey(
            query: "first",
            notebookID: firstNotebookID
        )
        let secondKey = SearchRequestKey(
            query: "second",
            notebookID: secondNotebookID
        )
        let stub = ControlledSearchStub()
        let model = NotebookDocumentSearchModel(search: { query, notebookID in
            await stub.search(query: query, notebookID: notebookID)
        })

        model.search(
            firstKey.query,
            notebookID: firstNotebookID,
            orderedPageIDs: [firstPageID]
        )
        let firstPending = await waitForPending(firstKey, in: stub)
        XCTAssertTrue(firstPending)

        model.search(
            secondKey.query,
            notebookID: secondNotebookID,
            orderedPageIDs: [secondPageID]
        )
        let secondPending = await waitForPending(secondKey, in: stub)
        XCTAssertTrue(secondPending)
        let resolvedSecond = await stub.resolve(
            secondKey,
            with: [makeHit(
                notebookID: secondNotebookID,
                pageID: secondPageID
            )]
        )
        XCTAssertTrue(resolvedSecond)
        let secondPublished = await waitForPhase(.results, model: model)
        XCTAssertTrue(secondPublished)

        let resolvedFirst = await stub.resolve(
            firstKey,
            with: [makeHit(
                notebookID: firstNotebookID,
                pageID: firstPageID,
                score: 100
            )]
        )
        XCTAssertTrue(resolvedFirst)
        try? await Task<Never, Never>.sleep(for: .milliseconds(50))

        XCTAssertEqual(model.query, secondKey.query)
        XCTAssertEqual(model.results.map(\.pageID), [secondPageID])
        XCTAssertEqual(model.selectedPageID, secondPageID)
    }

    @MainActor
    func testDefaultConfigurationCanReplaceAnIgnoringProviderSafely() async {
        let notebookID = UUID()
        let stalePageID = UUID()
        let currentPageID = UUID()
        let key = SearchRequestKey(query: "query", notebookID: notebookID)
        let stale = ControlledSearchStub()
        let current = SearchResponseStub(responses: [
            key: [makeHit(
                notebookID: notebookID,
                pageID: currentPageID
            )],
        ])
        let model = NotebookDocumentSearchModel()

        model.search(
            key.query,
            notebookID: notebookID,
            orderedPageIDs: [stalePageID, currentPageID]
        )
        XCTAssertEqual(model.query, key.query)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertTrue(model.results.isEmpty)

        model.configure(search: { query, notebookID in
            await stale.search(query: query, notebookID: notebookID)
        })
        model.search(
            key.query,
            notebookID: notebookID,
            orderedPageIDs: [stalePageID, currentPageID]
        )
        let stalePending = await waitForPending(key, in: stale)
        XCTAssertTrue(stalePending)

        model.configure(search: { query, notebookID in
            await current.search(query: query, notebookID: notebookID)
        })
        model.search(
            key.query,
            notebookID: notebookID,
            orderedPageIDs: [stalePageID, currentPageID]
        )
        let currentPublished = await waitForPhase(.results, model: model)
        XCTAssertTrue(currentPublished)
        XCTAssertEqual(model.results.map(\.pageID), [currentPageID])

        let staleResolved = await stale.resolve(
            key,
            with: [makeHit(
                notebookID: notebookID,
                pageID: stalePageID,
                score: 100
            )]
        )
        XCTAssertTrue(staleResolved)
        try? await Task<Never, Never>.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.results.map(\.pageID), [currentPageID])
    }

    @MainActor
    func testCancelRejectsLatePublicationAndResetClearsSettledState() async {
        let notebookID = UUID()
        let pageID = UUID()
        let key = SearchRequestKey(query: "cancel", notebookID: notebookID)
        let controlled = ControlledSearchStub()
        let model = NotebookDocumentSearchModel(search: { query, notebookID in
            await controlled.search(query: query, notebookID: notebookID)
        })

        model.search(
            key.query,
            notebookID: notebookID,
            orderedPageIDs: [pageID]
        )
        let pending = await waitForPending(key, in: controlled)
        XCTAssertTrue(pending)
        model.cancel()
        XCTAssertEqual(model.phase, .idle)
        let cancelledResolved = await controlled.resolve(
            key,
            with: [makeHit(notebookID: notebookID, pageID: pageID)]
        )
        XCTAssertTrue(cancelledResolved)
        try? await Task<Never, Never>.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.results.isEmpty)

        let settled = SearchResponseStub(responses: [
            key: [makeHit(notebookID: notebookID, pageID: pageID)],
        ])
        model.configure(search: { query, notebookID in
            await settled.search(query: query, notebookID: notebookID)
        })
        model.search(
            key.query,
            notebookID: notebookID,
            orderedPageIDs: [pageID]
        )
        let settledPublished = await waitForPhase(.results, model: model)
        XCTAssertTrue(settledPublished)
        model.reset()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.query, "")
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selectedPageID)
    }

    @MainActor
    private func waitForPhase(
        _ phase: NotebookDocumentSearchModel.Phase,
        model: NotebookDocumentSearchModel
    ) async -> Bool {
        guard model.phase != phase else { return true }
        let phaseReached = expectation(description: "Search reaches \(phase)")
        let observation = model.$phase
            .filter { $0 == phase }
            .prefix(1)
            .sink { _ in phaseReached.fulfill() }

        await fulfillment(of: [phaseReached], timeout: 10)
        withExtendedLifetime(observation) {}
        return model.phase == phase
    }
}

private struct SearchRequestKey: Hashable, Sendable {
    let query: String
    let notebookID: UUID
}

private actor SearchResponseStub {
    private let responses: [SearchRequestKey: [LocalSearchSegmentHit]]
    private var recordedRequests: [SearchRequestKey] = []

    init(responses: [SearchRequestKey: [LocalSearchSegmentHit]]) {
        self.responses = responses
    }

    func search(
        query: String,
        notebookID: UUID
    ) -> [LocalSearchSegmentHit] {
        let key = SearchRequestKey(query: query, notebookID: notebookID)
        recordedRequests.append(key)
        return responses[key] ?? []
    }

    func requests() -> [SearchRequestKey] {
        recordedRequests
    }
}

private actor ControlledSearchStub {
    private struct PendingRequest {
        let key: SearchRequestKey
        let continuation: CheckedContinuation<
            [LocalSearchSegmentHit],
            Never
        >
    }

    private var pendingRequests: [PendingRequest] = []

    func search(
        query: String,
        notebookID: UUID
    ) async -> [LocalSearchSegmentHit] {
        let key = SearchRequestKey(query: query, notebookID: notebookID)
        return await withCheckedContinuation { continuation in
            pendingRequests.append(PendingRequest(
                key: key,
                continuation: continuation
            ))
        }
    }

    func hasPending(_ key: SearchRequestKey) -> Bool {
        pendingRequests.contains { $0.key == key }
    }

    func resolve(
        _ key: SearchRequestKey,
        with hits: [LocalSearchSegmentHit]
    ) -> Bool {
        guard let index = pendingRequests.firstIndex(where: {
            $0.key == key
        }) else { return false }
        let request = pendingRequests.remove(at: index)
        request.continuation.resume(returning: hits)
        return true
    }
}

private func makeHit(
    documentID: UUID = UUID(),
    segmentID: UUID = UUID(),
    notebookID: UUID,
    pageID: UUID,
    score: Double = 1,
    snippet: String = "match"
) -> LocalSearchSegmentHit {
    LocalSearchSegmentHit(
        documentID: documentID,
        notebookID: notebookID,
        pageID: pageID,
        title: "Notebook",
        snippet: snippet,
        score: score,
        segment: RecognizedTextSegment(
            id: segmentID,
            text: snippet,
            pageID: pageID,
            source: .typedText
        )
    )
}

private func waitForPending(
    _ key: SearchRequestKey,
    in stub: ControlledSearchStub
) async -> Bool {
    for _ in 0..<200 {
        if await stub.hasPending(key) { return true }
        try? await Task<Never, Never>.sleep(for: .milliseconds(10))
    }
    return false
}
