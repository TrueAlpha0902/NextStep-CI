import NotesCore
import NotesServices
import SwiftUI
import UIKit

struct StudySetPageEditor: View {
    @Binding private var studySet: StudySet
    let saveState: InkSaveState
    let onStudySetChanged: (StudySet) -> Void
    let onRetry: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var mode = EditorMode.cards
    @State private var selectedCardID: StudyCardID?
    @State private var reviewCardIDs: [StudyCardID] = []
    @State private var reviewSessionTotal = 0
    @State private var reviewedCardCount = 0
    @State private var isAnswerRevealed = false
    @State private var isHintRevealed = false

    init(
        studySet: Binding<StudySet>,
        saveState: InkSaveState,
        onStudySetChanged: @escaping (StudySet) -> Void,
        onRetry: @escaping () -> Void
    ) {
        _studySet = studySet
        self.saveState = saveState
        self.onStudySetChanged = onStudySetChanged
        self.onRetry = onRetry
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            switch mode {
            case .cards:
                cardsEditor
            case .study:
                studyView
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .onAppear {
            let normalized = publish(studySet)
            ensureCardSelection(in: normalized)
        }
        .onChange(of: mode) { _, newMode in
            if newMode == .study {
                beginReviewSession()
            } else {
                ensureCardSelection(in: studySet)
            }
        }
        .onChange(of: studySet.cards.map(\.id)) { _, cardIDs in
            guard !cardIDs.isEmpty else {
                selectedCardID = nil
                reviewCardIDs = []
                return
            }
            ensureCardSelection(in: studySet)
            reviewCardIDs.removeAll { !cardIDs.contains($0) }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                modePicker
                Spacer(minLength: 8)
                saveStatus
            }

            VStack(alignment: .leading, spacing: 8) {
                modePicker
                saveStatus
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var modePicker: some View {
        Picker("Study set mode", selection: $mode) {
            ForEach(EditorMode.allCases) { editorMode in
                Label(editorMode.title, systemImage: editorMode.symbolName)
                    .tag(editorMode)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 380)
        .accessibilityIdentifier("studySet.modePicker")
    }

    private var saveStatus: some View {
        StudySetSaveStatus(
            state: saveState,
            onRetry: onRetry
        )
    }

    @ViewBuilder
    private var cardsEditor: some View {
        if horizontalSizeClass == .compact {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    cardSidebar
                        .frame(height: compactSidebarHeight(
                            availableHeight: proxy.size.height
                        ))
                    Divider()
                    cardDetail
                }
            }
        } else {
            HStack(spacing: 0) {
                cardSidebar
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
                Divider()
                cardDetail
            }
        }
    }

    private var cardSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cards")
                        .font(.headline)
                    Text("\(studySet.cards.count) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }

                Spacer()

                EditButton()

                Button(action: addCard) {
                    Label("Add card", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("n", modifiers: .command)
                .disabled(studySet.cards.count >= StudySetSchedulerAdapter.maximumCardCount)
                .accessibilityIdentifier("studySet.addCard")
            }
            .padding(12)

            Divider()

            if studySet.cards.isEmpty {
                ContentUnavailableView {
                    Label("No cards", systemImage: "rectangle.stack.badge.plus")
                } description: {
                    Text("Add a card, then enter both a prompt and an answer.")
                } actions: {
                    Button("Add card", action: addCard)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List(selection: $selectedCardID) {
                    ForEach(studySet.cards) { card in
                        StudyCardRow(card: card)
                            .tag(card.id)
                            .contextMenu {
                                Button {
                                    duplicateCard(card.id)
                                } label: {
                                    Label("Duplicate", systemImage: "plus.square.on.square")
                                }
                                .disabled(studySet.cards.count >= StudySetSchedulerAdapter.maximumCardCount)

                                Button(role: .destructive) {
                                    deleteCards(withIDs: [card.id])
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                    .onDelete(perform: deleteCards)
                    .onMove(perform: moveCards)
                }
                .listStyle(.sidebar)
                .environment(\.defaultMinListRowHeight, 56)
                .accessibilityLabel("Study cards")
            }
        }
        .background(Color(uiColor: .secondarySystemGroupedBackground))
    }

    @ViewBuilder
    private var cardDetail: some View {
        if let selectedCardID,
           studySet.cards.contains(where: { $0.id == selectedCardID }) {
            VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        cardDetailTitle
                        Spacer()
                        cardDetailActions(selectedCardID: selectedCardID)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        cardDetailTitle
                        cardDetailActions(selectedCardID: selectedCardID)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.bar)

                Divider()

                ScrollView {
                    StudyCardForm(card: cardBinding(for: selectedCardID))
                        .id(selectedCardID)
                        .frame(maxWidth: 760)
                        .padding(20)
                        .frame(maxWidth: .infinity)
                }
            }
        } else {
            ContentUnavailableView(
                "Select a card",
                systemImage: "rectangle.stack",
                description: Text("Choose a card from the list to edit it.")
            )
        }
    }

    private var cardDetailTitle: some View {
        Text("Edit Card")
            .font(.headline)
    }

    private func cardDetailActions(selectedCardID: StudyCardID) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                cardDetailActionButtons(selectedCardID: selectedCardID)
            }
            VStack(alignment: .leading, spacing: 8) {
                cardDetailActionButtons(selectedCardID: selectedCardID)
            }
        }
    }

    @ViewBuilder
    private func cardDetailActionButtons(selectedCardID: StudyCardID) -> some View {
        Button {
            duplicateCard(selectedCardID)
        } label: {
            Label("Duplicate card", systemImage: "plus.square.on.square")
        }
        .buttonStyle(.bordered)
        .disabled(studySet.cards.count >= StudySetSchedulerAdapter.maximumCardCount)

        Button(role: .destructive) {
            deleteCards(withIDs: [selectedCardID])
        } label: {
            Label("Delete card", systemImage: "trash")
        }
        .buttonStyle(.bordered)
    }

    private func compactSidebarHeight(availableHeight: CGFloat) -> CGFloat {
        let isShort = verticalSizeClass == .compact
        let ratio: CGFloat = isShort ? 0.34 : 0.38
        let minimum: CGFloat = isShort ? 104 : 180
        let maximum: CGFloat = isShort ? 150 : 300
        return min(max(availableHeight * ratio, minimum), maximum)
    }

    @ViewBuilder
    private var studyView: some View {
        if let card = currentReviewCard {
            ScrollView {
                VStack(spacing: 24) {
                    reviewProgress
                    reviewCard(card)
                }
                .frame(maxWidth: 780)
                .padding(.horizontal, horizontalSizeClass == .compact ? 16 : 24)
                .padding(.vertical, verticalSizeClass == .compact ? 16 : 28)
                .frame(maxWidth: .infinity)
            }
        } else {
            studyEmptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var reviewProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Study session")
                    .font(.headline)
                Spacer()
                Text("\(reviewedCardCount) of \(reviewSessionTotal)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(
                value: Double(reviewedCardCount),
                total: Double(max(1, reviewSessionTotal))
            )
            .accessibilityLabel("Study progress")
            .accessibilityValue("\(reviewedCardCount) of \(reviewSessionTotal) cards")
        }
    }

    private func reviewCard(_ card: StudyCard) -> some View {
        VStack(spacing: 22) {
            VStack(spacing: 12) {
                Label("Prompt", systemImage: "questionmark.bubble")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(card.prompt)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("studySet.reviewPrompt")
            }
            .frame(
                maxWidth: .infinity,
                minHeight: horizontalSizeClass == .compact ? 120 : 180
            )

            if let hint = card.hint,
               !hint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if isHintRevealed {
                    VStack(spacing: 6) {
                        Label("Hint", systemImage: "lightbulb")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(hint)
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    Button {
                        withAnimation { isHintRevealed = true }
                    } label: {
                        Label("Show hint", systemImage: "lightbulb")
                    }
                    .buttonStyle(.bordered)
                }
            }

            Divider()

            if isAnswerRevealed {
                VStack(spacing: 12) {
                    Label("Answer", systemImage: "checkmark.bubble")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(card.answer)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("studySet.reviewAnswer")
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: horizontalSizeClass == .compact ? 90 : 120
                )
                .transition(.opacity)

                gradeButtons(for: card.id)
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isAnswerRevealed = true
                    }
                } label: {
                    Label("Reveal Answer", systemImage: "eye")
                        .frame(maxWidth: 260)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityHint("Shows the answer and review choices")
                .accessibilityIdentifier("studySet.revealAnswer")
            }
        }
        .padding(horizontalSizeClass == .compact ? 18 : 28)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(uiColor: .separator), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private func gradeButtons(for cardID: StudyCardID) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                gradeButton("Again", symbol: "arrow.counterclockwise", grade: .again, cardID: cardID)
                gradeButton("Hard", symbol: "tortoise", grade: .hard, cardID: cardID)
                gradeButton("Good", symbol: "hand.thumbsup", grade: .good, cardID: cardID)
                gradeButton("Easy", symbol: "sparkles", grade: .easy, cardID: cardID)
            }

            VStack(spacing: 10) {
                gradeButton("Again", symbol: "arrow.counterclockwise", grade: .again, cardID: cardID)
                gradeButton("Hard", symbol: "tortoise", grade: .hard, cardID: cardID)
                gradeButton("Good", symbol: "hand.thumbsup", grade: .good, cardID: cardID)
                gradeButton("Easy", symbol: "sparkles", grade: .easy, cardID: cardID)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rate your answer")
    }

    private func gradeButton(
        _ title: LocalizedStringKey,
        symbol: String,
        grade: StudyGrade,
        cardID: StudyCardID
    ) -> some View {
        Button {
            apply(grade, to: cardID)
        } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityHint("Records this rating and advances to the next card")
    }

    private var studyEmptyState: some View {
        let completeCount = StudySetSchedulerAdapter.completeCards(in: studySet).count
        let incompleteCount = studySet.cards.count - completeCount

        return ContentUnavailableView {
            if completeCount == 0 {
                Label("No cards ready", systemImage: "rectangle.stack.badge.exclamationmark")
            } else {
                Label("You're caught up", systemImage: "checkmark.circle")
            }
        } description: {
            if completeCount == 0 {
                Text("A study card needs both a prompt and an answer.")
            } else if incompleteCount > 0 {
                Text("There are no cards due now. \(incompleteCount) incomplete cards were skipped.")
            } else {
                Text("There are no cards due for review right now.")
            }
        } actions: {
            Button {
                beginReviewSession()
            } label: {
                Label("Refresh Queue", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var currentReviewCard: StudyCard? {
        guard let cardID = reviewCardIDs.first else { return nil }
        return studySet.cards.first(where: { $0.id == cardID })
    }

    private func addCard() {
        guard studySet.cards.count < StudySetSchedulerAdapter.maximumCardCount else { return }
        let now = Date.now
        let card = StudyCard(createdAt: now, modifiedAt: now)
        var updated = studySet
        updated.cards.append(card)
        _ = publish(updated)
        selectedCardID = card.id
    }

    private func duplicateCard(_ cardID: StudyCardID) {
        guard studySet.cards.count < StudySetSchedulerAdapter.maximumCardCount,
              let sourceIndex = studySet.cards.firstIndex(where: { $0.id == cardID }) else { return }
        let source = studySet.cards[sourceIndex]
        let now = Date.now
        let duplicate = StudyCard(
            prompt: source.prompt,
            answer: source.answer,
            hint: source.hint,
            tags: source.tags,
            createdAt: now,
            modifiedAt: now
        )
        var updated = studySet
        updated.cards.insert(duplicate, at: sourceIndex + 1)
        // Review progress is intentionally not copied to a new card.
        _ = publish(updated)
        selectedCardID = duplicate.id
    }

    private func deleteCards(at offsets: IndexSet) {
        let ids = Set(offsets.compactMap { index in
            studySet.cards.indices.contains(index) ? studySet.cards[index].id : nil
        })
        deleteCards(withIDs: ids)
    }

    private func deleteCards(withIDs cardIDs: Set<StudyCardID>) {
        guard !cardIDs.isEmpty else { return }
        let oldCards = studySet.cards
        let selectedIndex = selectedCardID.flatMap { selectedID in
            oldCards.firstIndex(where: { $0.id == selectedID })
        }

        var updated = studySet
        updated.cards.removeAll { cardIDs.contains($0.id) }
        // Progress has no meaning without its card and must be removed in the
        // same published mutation.
        updated.progress.removeAll { cardIDs.contains($0.cardID) }
        let published = publish(updated)

        if let selectedCardID, cardIDs.contains(selectedCardID) {
            let nextIndex = min(selectedIndex ?? 0, max(0, published.cards.count - 1))
            self.selectedCardID = published.cards.isEmpty ? nil : published.cards[nextIndex].id
        }
        reviewCardIDs.removeAll { cardIDs.contains($0) }
    }

    private func moveCards(from source: IndexSet, to destination: Int) {
        var updated = studySet
        updated.cards.move(fromOffsets: source, toOffset: destination)
        _ = publish(updated)
    }

    private func cardBinding(for cardID: StudyCardID) -> Binding<StudyCard> {
        Binding {
            studySet.cards.first(where: { $0.id == cardID }) ?? StudyCard(id: cardID)
        } set: { replacement in
            guard let index = studySet.cards.firstIndex(where: { $0.id == cardID }) else { return }
            var updated = studySet
            var replacement = replacement
            replacement.id = cardID
            replacement.modifiedAt = max(
                replacement.modifiedAt,
                max(replacement.createdAt, .now)
            )
            updated.cards[index] = replacement
            _ = publish(updated)
        }
    }

    private func beginReviewSession() {
        reviewCardIDs = StudySetSchedulerAdapter.reviewQueue(in: studySet).map(\.id)
        reviewSessionTotal = reviewCardIDs.count
        reviewedCardCount = 0
        isAnswerRevealed = false
        isHintRevealed = false
    }

    private func apply(_ grade: StudyGrade, to cardID: StudyCardID) {
        let updated = StudySetSchedulerAdapter.applying(
            grade: grade,
            to: cardID,
            in: studySet
        )
        _ = publish(updated)
        reviewCardIDs.removeAll { $0 == cardID }
        reviewedCardCount = min(reviewSessionTotal, reviewedCardCount + 1)
        isAnswerRevealed = false
        isHintRevealed = false
    }

    @discardableResult
    private func publish(_ candidate: StudySet) -> StudySet {
        let normalized = StudySetSchedulerAdapter.normalized(candidate)
        guard normalized != studySet else { return normalized }
        studySet = normalized
        onStudySetChanged(normalized)
        return normalized
    }

    private func ensureCardSelection(in studySet: StudySet) {
        if let selectedCardID,
           studySet.cards.contains(where: { $0.id == selectedCardID }) {
            return
        }
        selectedCardID = studySet.cards.first?.id
    }
}

private extension StudySetPageEditor {
    enum EditorMode: String, CaseIterable, Identifiable {
        case cards
        case study

        var id: Self { self }

        var title: LocalizedStringResource {
            switch self {
            case .cards: "Cards"
            case .study: "Study"
            }
        }

        var symbolName: String {
            switch self {
            case .cards: "rectangle.stack"
            case .study: "brain.head.profile"
            }
        }
    }
}

private struct StudyCardRow: View {
    let card: StudyCard

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: StudySetSchedulerAdapter.isComplete(card)
                ? "checkmark.circle.fill"
                : "circle.dashed")
                .foregroundStyle(StudySetSchedulerAdapter.isComplete(card) ? Color.green : Color.secondary)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(card.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Untitled card"
                    : card.prompt)
                    .font(.body)
                    .lineLimit(2)

                Text(StudySetSchedulerAdapter.isComplete(card) ? "Ready to study" : "Needs prompt and answer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(card.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Untitled card"
            : card.prompt)
        .accessibilityValue(StudySetSchedulerAdapter.isComplete(card) ? "Ready to study" : "Incomplete")
    }
}

private struct StudyCardForm: View {
    @Binding var card: StudyCard
    @State private var tagsText: String

    init(card: Binding<StudyCard>) {
        _card = card
        _tagsText = State(initialValue: card.wrappedValue.tags.joined(separator: ", "))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            fieldGroup(title: "Prompt", symbol: "questionmark.bubble") {
                TextField("What do you want to remember?", text: $card.prompt, axis: .vertical)
                    .lineLimit(3 ... 10)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Card prompt")
                    .accessibilityIdentifier("studySet.cardPrompt")
            }

            fieldGroup(title: "Answer", symbol: "checkmark.bubble") {
                TextField("Enter the answer", text: $card.answer, axis: .vertical)
                    .lineLimit(3 ... 12)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Card answer")
                    .accessibilityIdentifier("studySet.cardAnswer")
            }

            fieldGroup(title: "Hint", symbol: "lightbulb") {
                TextField("Optional hint", text: hintBinding, axis: .vertical)
                    .lineLimit(2 ... 6)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Card hint")
            }

            fieldGroup(title: "Tags", symbol: "tag") {
                TextField("Comma-separated tags", text: $tagsText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel("Card tags")
                    .onChange(of: tagsText) { _, newValue in
                        let tags = StudySetSchedulerAdapter.tags(from: newValue)
                        if tags != card.tags {
                            card.tags = tags
                        }
                    }

                Text("Separate multiple tags with commas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .accessibilityHidden(true)
                Text("Last edited")
                Text(card.modifiedAt, format: .dateTime.year().month().day().hour().minute())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private var hintBinding: Binding<String> {
        Binding {
            card.hint ?? ""
        } set: { value in
            card.hint = value.isEmpty ? nil : value
        }
    }

    private func fieldGroup<Content: View>(
        title: LocalizedStringKey,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content()
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(uiColor: .separator), lineWidth: 0.5)
        }
    }
}

private struct StudySetSaveStatus: View {
    let state: InkSaveState
    let onRetry: () -> Void

    @ViewBuilder
    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .saving:
            Label("Saving…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("study-set.save.saving")
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("study-set.save.saved")
        case .failed:
            Button(action: onRetry) {
                Label("Retry save", systemImage: "arrow.clockwise.circle.fill")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .accessibilityHint("Attempts to save this study set again")
            .accessibilityIdentifier("studySet.retrySave")
        }
    }
}
