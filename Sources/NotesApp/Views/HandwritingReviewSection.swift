import NotesCore
import SwiftUI

struct HandwritingReviewSection: View {
    @EnvironmentObject private var appModel: AppModel

    let notebookID: UUID
    let page: EditorPage
    @Binding var sourceText: String

    @State private var snapshot: HandwritingRecognitionSnapshot?
    @State private var corrections: [UUID: String] = [:]
    @State private var isLoading = true
    @State private var isRecognizing = false
    @State private var isSavingReview = false
    @State private var showsRerunConfirmation = false
    @State private var recognitionTask: Task<Void, Never>?
    @State private var reviewTask: Task<Void, Never>?

    var body: some View {
        Section {
            if isLoading {
                ProgressView("Loading handwriting review…")
            } else {
                recognitionStatus
                recognitionActions
                if let snapshot {
                    let reviewsByCandidateID = snapshot.document.reviews.reduce(
                        into: [UUID: HandwritingCandidateReview]()
                    ) { lookup, review in
                        // Preserve the previous `first` lookup semantics if a
                        // malformed document ever contains duplicate reviews.
                        lookup[review.candidateID] = lookup[review.candidateID] ?? review
                    }
                    reviewSummary(snapshot.document)
                    ForEach(snapshot.document.machineCandidates) { candidate in
                        candidateReview(
                            candidate,
                            review: reviewsByCandidateID[candidate.id],
                            in: snapshot
                        )
                    }
                }
            }
        } header: {
            Text("Handwriting review")
        } footer: {
            Text(verbatim: CurrentDevicePresentation.localized(
                "Recognition runs on this iPad. Machine suggestions stay private and do not enter search or page tools until you accept them."
            ))
        }
        .task(id: page.id) {
            await loadSnapshot(reset: true)
        }
        .onChange(of: recognitionIsActive) { wasActive, isActive in
            guard wasActive, !isActive, !isRecognizing else { return }
            Task { await loadSnapshot(reset: false) }
        }
        .onDisappear {
            recognitionTask?.cancel()
            reviewTask?.cancel()
        }
        .confirmationDialog(
            "Replace handwriting suggestions?",
            isPresented: $showsRerunConfirmation,
            titleVisibility: .visible
        ) {
            Button("Recognize again", role: .destructive) {
                startRecognition()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the current machine suggestions and their reviews. Your ink is not changed.")
        }
    }

    @ViewBuilder
    private var recognitionStatus: some View {
        if recognitionIsActive {
            HStack(spacing: 10) {
                ProgressView()
                Text("Recognizing handwriting on device…")
            }
            Text("Closing this sheet cancels unfinished recognition.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let snapshot, !snapshot.isCurrentForInk {
            Label(
                "The ink changed after this review. Previous accepted text has been removed from search.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
        } else if snapshot == nil {
            Label(
                "No handwriting suggestions yet.",
                systemImage: "pencil.and.scribble"
            )
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var recognitionActions: some View {
        Button {
            if snapshot == nil {
                startRecognition()
            } else {
                showsRerunConfirmation = true
            }
        } label: {
            Label(
                snapshot == nil ? "Recognize handwriting" : "Recognize again",
                systemImage: "text.viewfinder"
            )
        }
        .disabled(recognitionIsActive || isSavingReview)

        if let snapshot,
           snapshot.isCurrentForInk,
           !snapshot.document.acceptedText.isEmpty {
            Button {
                sourceText = snapshot.document.acceptedText
                    .map(\.text)
                    .joined(separator: "\n")
            } label: {
                Label("Use accepted handwriting as source", systemImage: "text.badge.checkmark")
            }
            .disabled(recognitionIsActive || isSavingReview)
        }
    }

    private func reviewSummary(
        _ document: HandwritingRecognitionDocument
    ) -> some View {
        let accepted = document.reviews.filter { $0.decision == .accepted }.count
        let rejected = document.reviews.filter { $0.decision == .rejected }.count
        let pending = max(document.machineCandidates.count - document.reviews.count, 0)
        return LabeledContent("Review progress") {
            Text("\(accepted) accepted · \(rejected) rejected · \(pending) pending")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityValue(
            Text("\(accepted) accepted, \(rejected) rejected, \(pending) pending")
        )
    }

    private func candidateReview(
        _ candidate: HandwritingMachineCandidate,
        review: HandwritingCandidateReview?,
        in snapshot: HandwritingRecognitionSnapshot
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(candidate.machineText)
                    .font(.body)
                    .textSelection(.enabled)
                Spacer(minLength: 12)
                Text(candidate.machineConfidence.formatted(
                    .percent.precision(.fractionLength(0))
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                reviewBadge(review)
            }

            TextField(
                "Correction (optional)",
                text: correctionBinding(for: candidate.id),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .disabled(!snapshot.isCurrentForInk || recognitionIsActive || isSavingReview)
            .accessibilityLabel("Correction for \(candidate.machineText)")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    reviewButtons(candidateID: candidate.id, hasReview: review != nil)
                }
                VStack(alignment: .leading, spacing: 8) {
                    reviewButtons(candidateID: candidate.id, hasReview: review != nil)
                }
            }
            .buttonStyle(.bordered)
            .disabled(!snapshot.isCurrentForInk || recognitionIsActive || isSavingReview)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func reviewButtons(candidateID: UUID, hasReview: Bool) -> some View {
        Button {
            saveReview(
                candidateID: candidateID,
                decision: .accepted
            )
        } label: {
            Label("Accept", systemImage: "checkmark.circle")
        }
        .tint(.green)

        Button {
            saveReview(
                candidateID: candidateID,
                decision: .rejected
            )
        } label: {
            Label("Reject", systemImage: "xmark.circle")
        }
        .tint(.red)

        if hasReview {
            Button("Reset") {
                saveReview(candidateID: candidateID, decision: nil)
            }
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func reviewBadge(_ review: HandwritingCandidateReview?) -> some View {
        switch review?.decision {
        case .accepted?:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Accepted")
        case .rejected?:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Rejected")
        case nil:
            Image(systemName: "circle.dotted")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Pending review")
        }
    }

    private func correctionBinding(for candidateID: UUID) -> Binding<String> {
        Binding(
            get: { corrections[candidateID, default: ""] },
            set: { corrections[candidateID] = $0 }
        )
    }

    private var recognitionIsActive: Bool {
        isRecognizing || appModel.isHandwritingRecognitionRunning(
            notebookID: notebookID,
            pageID: page.id
        )
    }

    private func startRecognition() {
        recognitionTask?.cancel()
        recognitionTask = Task { @MainActor in
            isRecognizing = true
            defer { isRecognizing = false }
            let result = await appModel.recognizeHandwriting(
                notebookID: notebookID,
                page: page
            )
            guard !Task.isCancelled else { return }
            if let result {
                apply(result, preservingDrafts: false)
            } else {
                await loadSnapshot(reset: false)
            }
        }
    }

    private func saveReview(
        candidateID: UUID,
        decision: HandwritingReviewDecision?
    ) {
        reviewTask?.cancel()
        reviewTask = Task { @MainActor in
            isSavingReview = true
            defer { isSavingReview = false }
            let result = await appModel.updateHandwritingReview(
                notebookID: notebookID,
                pageID: page.id,
                candidateID: candidateID,
                decision: decision,
                correctedText: corrections[candidateID]
            )
            guard !Task.isCancelled else { return }
            if let result {
                apply(
                    result,
                    preservingDrafts: true,
                    clearingDraftFor: decision == .accepted ? nil : candidateID
                )
            } else {
                await loadSnapshot(reset: false)
            }
        }
    }

    private func loadSnapshot(reset: Bool) async {
        if reset {
            isLoading = true
            snapshot = nil
            corrections = [:]
        }
        let loaded = await appModel.handwritingRecognitionSnapshot(
            notebookID: notebookID,
            pageID: page.id
        )
        guard !Task.isCancelled else { return }
        if let loaded {
            apply(loaded, preservingDrafts: !reset)
        } else {
            snapshot = nil
        }
        isLoading = false
    }

    private func apply(
        _ newSnapshot: HandwritingRecognitionSnapshot,
        preservingDrafts: Bool,
        clearingDraftFor candidateIDToClear: UUID? = nil
    ) {
        snapshot = newSnapshot
        let candidateIDs = Set(newSnapshot.document.machineCandidates.map(\.id))
        var merged = preservingDrafts
            ? corrections.filter { candidateIDs.contains($0.key) }
            : [:]
        let durableCorrections: [UUID: String] = Dictionary(
            uniqueKeysWithValues: newSnapshot.document.reviews.compactMap {
                review -> (UUID, String)? in
                guard let correctedText = review.correctedText else { return nil }
                return (review.candidateID, correctedText)
            }
        )
        for (candidateID, text) in durableCorrections where merged[candidateID] == nil {
            merged[candidateID] = text
        }
        if let candidateIDToClear {
            merged.removeValue(forKey: candidateIDToClear)
        }
        corrections = merged
    }
}
