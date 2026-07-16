import Combine
import Foundation
import NotesServices

@MainActor
final class NotebookDocumentSearchModel: ObservableObject {
    private static let maximumQueryCharacters = 1_024

    typealias SearchOperation = @MainActor @Sendable (
        _ query: String,
        _ notebookID: UUID
    ) async -> [LocalSearchSegmentHit]

    enum Phase: Equatable, Sendable {
        case idle
        case searching
        case results
        case noResults
    }

    struct PageResult: Identifiable, Hashable, Sendable {
        let pageID: UUID
        let bestHit: LocalSearchSegmentHit
        let matchCount: Int

        var id: UUID { pageID }
    }

    @Published private(set) var query = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var results: [PageResult] = []
    @Published private(set) var selectedPageID: UUID?

    private var searchOperation: SearchOperation?
    private var searchTask: Task<Void, Never>?
    private var requestGeneration = UUID()
    private var currentNotebookID: UUID?
    private var orderedPageIDs: [UUID] = []
    private var currentRequestQuery = ""

    init() {}

    init(search: @escaping SearchOperation) {
        searchOperation = search
    }

    /// Supports environment-owned dependencies that are unavailable while a
    /// SwiftUI `@StateObject` is initialized. Reconfiguration is deliberately
    /// fenced even when the previous provider ignores task cancellation.
    func configure(search: @escaping SearchOperation) {
        invalidatePendingSearch()
        searchOperation = search
        if phase == .searching {
            phase = results.isEmpty ? .idle : .results
        }
    }

    var selectedResult: PageResult? {
        guard let selectedPageID else { return nil }
        return results.first { $0.pageID == selectedPageID }
    }

    var selectedResultNumber: Int? {
        guard let selectedPageID,
              let index = results.firstIndex(where: {
                  $0.pageID == selectedPageID
              }) else { return nil }
        return index + 1
    }

    var matchCount: Int {
        results.reduce(into: 0) { count, result in
            let (sum, overflow) = count.addingReportingOverflow(
                result.matchCount
            )
            count = overflow ? Int.max : sum
        }
    }

    /// Debounces a notebook-scoped query and binds its eventual result to the
    /// exact notebook, page ordering, and request generation captured here.
    /// Cancelling the prior task is only an optimization: a search provider may
    /// ignore cancellation, so stale publication is rejected independently.
    func search(
        _ rawQuery: String,
        notebookID: UUID,
        orderedPageIDs proposedPageIDs: [UUID]
    ) {
        let boundedRawQuery = String(
            rawQuery.prefix(Self.maximumQueryCharacters)
        )
        let trimmedQuery = boundedRawQuery.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedQuery.isEmpty else {
            reset()
            return
        }

        invalidatePendingSearch()
        let nextPageIDs = Self.uniquePageIDs(proposedPageIDs)
        let notebookChanged = currentNotebookID != notebookID
        currentNotebookID = notebookID
        orderedPageIDs = nextPageIDs
        query = boundedRawQuery
        currentRequestQuery = trimmedQuery

        guard let operation = searchOperation else {
            results = []
            selectedPageID = nil
            phase = .idle
            return
        }

        if notebookChanged {
            results = []
            selectedPageID = nil
        } else {
            reconcilePublishedResults(with: nextPageIDs)
        }

        phase = .searching
        let generation = requestGeneration
        let pageIDs = nextPageIDs

        searchTask = Task { @MainActor [weak self] in
            do {
                try await Task<Never, Never>.sleep(
                    for: .milliseconds(200)
                )
            } catch {
                return
            }

            let hits = await operation(trimmedQuery, notebookID)
            guard let self,
                  self.requestGeneration == generation,
                  self.currentNotebookID == notebookID,
                  self.orderedPageIDs == pageIDs,
                  self.currentRequestQuery == trimmedQuery,
                  self.query.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ) == trimmedQuery else { return }

            self.publish(
                hits,
                notebookID: notebookID,
                orderedPageIDs: pageIDs
            )
            self.searchTask = nil
        }
    }

    @discardableResult
    func select(pageID: UUID) -> PageResult? {
        guard let result = results.first(where: {
            $0.pageID == pageID
        }) else { return nil }
        selectedPageID = pageID
        return result
    }

    @discardableResult
    func selectNextResult() -> PageResult? {
        guard !results.isEmpty else {
            selectedPageID = nil
            return nil
        }
        let nextIndex: Int
        if let selectedPageID,
           let currentIndex = results.firstIndex(where: {
               $0.pageID == selectedPageID
           }) {
            nextIndex = (currentIndex + 1) % results.count
        } else {
            nextIndex = 0
        }
        selectedPageID = results[nextIndex].pageID
        return results[nextIndex]
    }

    @discardableResult
    func selectPreviousResult() -> PageResult? {
        guard !results.isEmpty else {
            selectedPageID = nil
            return nil
        }
        let previousIndex: Int
        if let selectedPageID,
           let currentIndex = results.firstIndex(where: {
               $0.pageID == selectedPageID
           }) {
            previousIndex = (currentIndex - 1 + results.count)
                % results.count
        } else {
            previousIndex = results.count - 1
        }
        selectedPageID = results[previousIndex].pageID
        return results[previousIndex]
    }

    /// Stops only pending work. Settled results remain usable; an unfinished
    /// first query returns to idle because it has not established no-results.
    func cancel() {
        invalidatePendingSearch()
        guard phase == .searching else { return }
        phase = results.isEmpty ? .idle : .results
    }

    func reset() {
        invalidatePendingSearch()
        currentNotebookID = nil
        orderedPageIDs = []
        currentRequestQuery = ""
        query = ""
        results = []
        selectedPageID = nil
        phase = .idle
    }

    private func invalidatePendingSearch() {
        requestGeneration = UUID()
        searchTask?.cancel()
        searchTask = nil
    }

    private func publish(
        _ hits: [LocalSearchSegmentHit],
        notebookID: UUID,
        orderedPageIDs: [UUID]
    ) {
        let priorSelection = selectedPageID
        results = Self.aggregate(
            hits,
            notebookID: notebookID,
            orderedPageIDs: orderedPageIDs
        )
        if let priorSelection,
           results.contains(where: { $0.pageID == priorSelection }) {
            selectedPageID = priorSelection
        } else {
            selectedPageID = results.first?.pageID
        }
        phase = results.isEmpty ? .noResults : .results
    }

    private func reconcilePublishedResults(with pageIDs: [UUID]) {
        let byPageID = Dictionary(
            uniqueKeysWithValues: results.map { ($0.pageID, $0) }
        )
        results = pageIDs.compactMap { byPageID[$0] }
        repairSelection()
    }

    private func repairSelection() {
        if let selectedPageID,
           results.contains(where: { $0.pageID == selectedPageID }) {
            return
        }
        selectedPageID = results.first?.pageID
    }

    private static func aggregate(
        _ hits: [LocalSearchSegmentHit],
        notebookID: UUID,
        orderedPageIDs: [UUID]
    ) -> [PageResult] {
        struct Accumulator {
            var bestHit: LocalSearchSegmentHit
            var matchCount: Int
        }

        let validPageIDs = Set(orderedPageIDs)
        var seenHitIDs = Set<LocalSearchSegmentHit.ID>()
        var byPageID: [UUID: Accumulator] = [:]
        byPageID.reserveCapacity(min(validPageIDs.count, hits.count))

        for hit in hits where hit.notebookID == notebookID
            && validPageIDs.contains(hit.pageID)
            && seenHitIDs.insert(hit.id).inserted {
            if var existing = byPageID[hit.pageID] {
                existing.matchCount += 1
                if isPreferred(hit, over: existing.bestHit) {
                    existing.bestHit = hit
                }
                byPageID[hit.pageID] = existing
            } else {
                byPageID[hit.pageID] = Accumulator(
                    bestHit: hit,
                    matchCount: 1
                )
            }
        }

        return orderedPageIDs.compactMap { pageID in
            guard let aggregate = byPageID[pageID] else { return nil }
            return PageResult(
                pageID: pageID,
                bestHit: aggregate.bestHit,
                matchCount: aggregate.matchCount
            )
        }
    }

    private static func isPreferred(
        _ candidate: LocalSearchSegmentHit,
        over current: LocalSearchSegmentHit
    ) -> Bool {
        let candidateScore = candidate.score.isFinite
            ? candidate.score
            : -Double.infinity
        let currentScore = current.score.isFinite
            ? current.score
            : -Double.infinity
        if candidateScore != currentScore {
            return candidateScore > currentScore
        }
        if candidate.id.documentID != current.id.documentID {
            return candidate.id.documentID.uuidString
                < current.id.documentID.uuidString
        }
        return candidate.id.segmentID.uuidString
            < current.id.segmentID.uuidString
    }

    private static func uniquePageIDs(_ pageIDs: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return pageIDs.filter { seen.insert($0).inserted }
    }
}
