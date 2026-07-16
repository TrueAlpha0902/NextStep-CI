import NotesServices
import SwiftUI
import UIKit

struct NotebookDocumentSearchView: View {
    @ObservedObject var model: NotebookDocumentSearchModel

    let notebookID: UUID
    let orderedPageIDs: [UUID]
    let currentPageID: UUID?
    let focusRequestID: UUID
    let canNavigate: Bool
    let onSelect: (NotebookDocumentSearchModel.PageResult) -> Void
    let onClose: () -> Void

    @FocusState private var searchFieldIsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            resultContent
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .task(id: focusRequestID) {
            await Task.yield()
            searchFieldIsFocused = true
        }
        .accessibilityIdentifier("editor.search.navigator")
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Search this note")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Label("Close search", systemImage: "xmark")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("editor.search.close")
            }

            TextField(
                "Search pages",
                text: Binding(
                    get: { model.query },
                    set: { query in
                        model.search(
                            query,
                            notebookID: notebookID,
                            orderedPageIDs: orderedPageIDs
                        )
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.search)
            .focused($searchFieldIsFocused)
            .accessibilityIdentifier("editor.search.field")

            HStack(spacing: 8) {
                Button {
                    if let previousResult { onSelect(previousResult) }
                } label: {
                    Label("Previous result", systemImage: "chevron.up")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(previousResult == nil || !canNavigate)
                .accessibilityIdentifier("editor.search.previous")

                Button {
                    if let nextResult { onSelect(nextResult) }
                } label: {
                    Label("Next result", systemImage: "chevron.down")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("g", modifiers: .command)
                .disabled(nextResult == nil || !canNavigate)
                .accessibilityIdentifier("editor.search.next")

                Spacer()

                if !model.results.isEmpty {
                    Text(verbatim: resultPosition)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(resultPositionAccessibilityLabel)
                }
            }
            .labelStyle(.iconOnly)
        }
        .padding(16)
    }

    @ViewBuilder
    private var resultContent: some View {
        switch model.phase {
        case .idle:
            ContentUnavailableView(
                "Search pages",
                systemImage: "doc.text.magnifyingglass",
                description: Text(
                    "Search typed text, scanned pages, PDFs, and transcripts."
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("editor.search.idle")
        case .searching:
            VStack(spacing: 12) {
                ProgressView()
                Text("Searching…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("editor.search.searching")
        case .noResults:
            ContentUnavailableView.search(text: model.query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("editor.search.no-results")
        case .results:
            VStack(spacing: 0) {
                List(model.results) { result in
                    resultRow(result)
                        .listRowInsets(
                            EdgeInsets(
                                top: 8,
                                leading: 12,
                                bottom: 8,
                                trailing: 12
                            )
                        )
                }
                .listStyle(.plain)

                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Results open the matching page.")
                    if model.matchCount >= 200 {
                        Text(localizedMatchLimit(200))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
    }

    private func resultRow(
        _ result: NotebookDocumentSearchModel.PageResult
    ) -> some View {
        let pageNumber = pageNumber(for: result.pageID)
        let isSelected = model.selectedPageID == result.pageID
        let isCurrentPage = currentPageID == result.pageID
        return Button {
            guard canNavigate else { return }
            onSelect(result)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(
                    systemName: isCurrentPage
                        ? "checkmark.circle.fill"
                        : result.bestHit.segment.source.searchSymbolName
                )
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(result.bestHit.segment.source.searchTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(localizedPageTitle(pageNumber))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: result.bestHit.snippet)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if result.matchCount > 1 {
                        Text(localizedPageMatchCount(result.matchCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canNavigate)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(
            result.bestHit.segment.source.searchAccessibilityLabel(
                pageNumber: pageNumber,
                snippet: result.bestHit.snippet,
                matchCount: result.matchCount
            )
        )
        .accessibilityIdentifier("editor.search.result.\(result.pageID.uuidString)")
    }

    private var previousResult: NotebookDocumentSearchModel.PageResult? {
        adjacentResult(offset: -1)
    }

    private var nextResult: NotebookDocumentSearchModel.PageResult? {
        adjacentResult(offset: 1)
    }

    private func adjacentResult(
        offset: Int
    ) -> NotebookDocumentSearchModel.PageResult? {
        guard model.phase == .results,
              !model.results.isEmpty else { return nil }
        if model.selectedPageID != currentPageID,
           let selectedResult = model.selectedResult {
            return selectedResult
        }
        guard let selectedPageID = model.selectedPageID,
              let index = model.results.firstIndex(where: {
                  $0.pageID == selectedPageID
              }) else {
            return offset < 0 ? model.results.last : model.results.first
        }
        let count = model.results.count
        let targetIndex = (index + offset + count) % count
        return model.results[targetIndex]
    }

    private func pageNumber(for pageID: UUID) -> Int {
        (orderedPageIDs.firstIndex(of: pageID) ?? 0) + 1
    }

    private var resultPosition: String {
        guard let number = model.selectedResultNumber else {
            return "— / \(model.results.count)"
        }
        return "\(number) / \(model.results.count)"
    }

    private var resultPositionAccessibilityLabel: Text {
        guard let number = model.selectedResultNumber else {
            return Text("No result selected")
        }
        return Text(
            localizedResultPosition(
                number: number,
                total: model.results.count
            )
        )
    }
}

private extension RecognizedTextSource {
    var searchTitle: LocalizedStringResource {
        switch self {
        case .typedText: "Typed text"
        case .canvasElement: "Canvas text"
        case .handwriting: "Handwriting"
        case .pdfText: "PDF text"
        case .scannedImage: "Scanned text"
        case .audioTranscript: "Audio transcript"
        case .outline: "Outline"
        case .bookmark: "Bookmarks"
        }
    }

    var searchSymbolName: String {
        switch self {
        case .typedText: "text.alignleft"
        case .canvasElement: "square.and.pencil"
        case .handwriting: "pencil.and.scribble"
        case .pdfText: "doc.richtext"
        case .scannedImage: "viewfinder"
        case .audioTranscript: "waveform"
        case .outline: "list.bullet.indent"
        case .bookmark: "bookmark.fill"
        }
    }

    func searchAccessibilityLabel(
        pageNumber: Int,
        snippet: String,
        matchCount: Int
    ) -> Text {
        Text(searchTitle)
            + Text(verbatim: ", ")
            + Text(localizedPageTitle(pageNumber))
            + Text(verbatim: ", ")
            + Text(verbatim: snippet)
            + Text(verbatim: ", ")
            + Text(localizedPageMatchCount(matchCount))
    }
}

private func localizedPageTitle(_ pageNumber: Int) -> String {
    String.localizedStringWithFormat(
        String(localized: "Page %lld"),
        Int64(pageNumber)
    )
}

private func localizedPageMatchCount(_ count: Int) -> String {
    String.localizedStringWithFormat(
        String(localized: "Matches on this page: %lld"),
        Int64(count)
    )
}

private func localizedMatchLimit(_ limit: Int) -> String {
    String.localizedStringWithFormat(
        String(localized: "Showing up to %lld matches"),
        Int64(limit)
    )
}

private func localizedResultPosition(number: Int, total: Int) -> String {
    String.localizedStringWithFormat(
        String(localized: "Result %1$lld of %2$lld"),
        Int64(number),
        Int64(total)
    )
}
