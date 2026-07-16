import SwiftUI

struct PageNavigatorView: View {
    let notebook: EditorNotebook
    let currentPageID: UUID?
    let canEditMetadata: Bool
    let isUpdatingMetadata: Bool
    let canSelectPage: (EditorPage) -> Bool
    let onSelectPage: (UUID) -> Void
    let onSaveOutline: (String?) -> Void
    let onDismiss: () -> Void

    @Binding var filter: PageNavigatorFilter
    @Binding var outlineDraft: String

    private var currentPage: EditorPage? {
        guard let currentPageID else { return nil }
        return notebook.pages.first { $0.id == currentPageID }
    }

    private var entries: [PageNavigatorEntry] {
        PageNavigatorPolicy.entries(in: notebook.pages, filter: filter)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Page navigator", selection: $filter) {
                        ForEach(PageNavigatorFilter.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("pageNavigator.filter")
                }

                if filter == .outline, let currentPage {
                    outlineEditor(page: currentPage)
                }

                if entries.isEmpty {
                    emptyState
                } else {
                    Section {
                        ForEach(entries) { entry in
                            pageRow(entry)
                        }
                    }
                }
            }
            .navigationTitle("Navigator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }

    private func outlineEditor(page: EditorPage) -> some View {
        Section("Current page outline") {
            TextField("Outline title", text: $outlineDraft)
                .onChange(of: outlineDraft) { _, newValue in
                    let limited = PageNavigationMetadataPolicy
                        .limitedOutlineInput(newValue)
                    if limited != newValue {
                        outlineDraft = limited
                    }
                }
                .disabled(!canEditMetadata || isUpdatingMetadata)
                .accessibilityIdentifier("pageNavigator.outline.title")

            HStack {
                Text("Maximum 120 characters.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(
                    verbatim: "\(outlineDraft.count)/\(PageNavigationMetadataPolicy.maximumOutlineTitleCharacters)"
                )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            Button {
                onSaveOutline(
                    PageNavigationMetadataPolicy.canonicalOutlineTitle(
                        outlineDraft
                    )
                )
            } label: {
                Label {
                    Text(
                        page.outlineTitle == nil
                            ? String(localized: "Add to outline")
                            : String(localized: "Save outline")
                    )
                } icon: {
                    Image(systemName: "text.badge.checkmark")
                }
            }
            .disabled(
                !canEditMetadata
                    || isUpdatingMetadata
                    || PageNavigationMetadataPolicy
                        .canonicalOutlineTitle(outlineDraft) == nil
                    || PageNavigationMetadataPolicy
                        .canonicalOutlineTitle(outlineDraft) == page.outlineTitle
            )
            .accessibilityIdentifier("pageNavigator.outline.save")

            if page.outlineTitle != nil {
                Button(role: .destructive) {
                    onSaveOutline(nil)
                } label: {
                    Label("Clear outline", systemImage: "text.badge.minus")
                }
                .disabled(!canEditMetadata || isUpdatingMetadata)
                .accessibilityIdentifier("pageNavigator.outline.clear")
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        Section {
            switch filter {
            case .all:
                EmptyView()
            case .bookmarks:
                ContentUnavailableView(
                    "No bookmarked pages",
                    systemImage: "bookmark.slash",
                    description: Text("Bookmark a page to find it here.")
                )
            case .outline:
                ContentUnavailableView(
                    "No outline entries",
                    systemImage: "list.bullet.rectangle",
                    description: Text(
                        "Add an outline title to a page to find it here."
                    )
                )
            }
        }
    }

    private func pageRow(_ entry: PageNavigatorEntry) -> some View {
        Button {
            onSelectPage(entry.page.id)
        } label: {
            HStack(spacing: 12) {
                Text(verbatim: String(entry.pageNumber))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.page.outlineTitle ?? pageTitle(entry.pageNumber))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if entry.page.outlineTitle != nil {
                        Text(pageTitle(entry.pageNumber))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if entry.page.isBookmarked {
                    Image(systemName: "bookmark.fill")
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Bookmark page")
                }
                if entry.page.id == currentPageID {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSelectPage(entry.page))
        .accessibilityIdentifier("pageNavigator.page.\(entry.page.id.uuidString.lowercased())")
    }

    private func pageTitle(_ pageNumber: Int) -> String {
        String(
            format: String(localized: "Page %lld"),
            Int64(pageNumber)
        )
    }
}
