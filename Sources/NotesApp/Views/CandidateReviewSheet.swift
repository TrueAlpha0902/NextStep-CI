import Foundation
import NextStepAcademic
import SwiftUI

struct CandidateReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var academicModel: AcademicAppModel

    let sessionID: CourseSessionID
    let courseTimeZoneIdentifier: String
    let allowsEditing: Bool

    @State private var filter: CandidateReviewFilter = .all
    @State private var selectedCaptureID: CaptureItemID?
    @State private var notice: CandidateReviewNotice?
    @State private var presentationState = CandidateReviewPresentationState()

    private var detailOwnsRetryState: Bool {
        presentationState.ownsRetryState
    }

    private var candidates: [CaptureItem] {
        CandidateReviewOrdering.captures(
            in: academicModel.workspace,
            sessionID: sessionID,
            filter: filter
        )
    }

    private var candidateIDs: [CaptureItemID] {
        candidates.map(\.id)
    }

    private var selectedCapture: CaptureItem? {
        guard let selectedCaptureID else { return nil }
        return candidates.first { $0.id == selectedCaptureID }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedCaptureID) {
                Section {
                    Picker("Candidate type", selection: $filter) {
                        ForEach(CandidateReviewFilter.allCases) { option in
                            Text(filterTitle(option)).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("candidate.review.filter")
                }

                if let notice {
                    Section {
                        Label {
                            Text(verbatim: notice.message)
                        } icon: {
                            Image(
                                systemName: notice.isError
                                    ? "exclamationmark.triangle.fill"
                                    : "checkmark.circle.fill"
                            )
                        }
                        .foregroundStyle(
                            notice.isError ? Color.orange : Color.green
                        )
                        .accessibilityIdentifier("candidate.review.notice")
                    }
                }

                ForEach(CandidateReviewSection.allCases) { section in
                    let sectionCaptures = candidates.filter(section.includes)
                    if !sectionCaptures.isEmpty {
                        Section {
                            ForEach(sectionCaptures) { capture in
                                NavigationLink(value: capture.id) {
                                    candidateRow(capture)
                                }
                                .accessibilityIdentifier(
                                    "candidate.review.row.\(capture.kind.rawValue).\(capture.id.description)"
                                )
                            }
                        } header: {
                            Text(sectionTitle(section))
                                .accessibilityIdentifier(
                                    "candidate.review.section.\(section.rawValue)"
                                )
                        }
                    }
                }
            }
            .navigationTitle("Candidates")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .disabled(detailOwnsRetryState)
                }
            }
            .disabled(detailOwnsRetryState)
        } detail: {
            if let selectedCapture {
                CandidateReviewDetail(
                    capture: selectedCapture,
                    courseTimeZoneIdentifier: courseTimeZoneIdentifier,
                    allowsEditing: allowsEditing,
                    presentationState: $presentationState,
                    onNotice: { notice = $0 }
                )
                .id(CandidateReviewDetailIdentity(capture: selectedCapture))
            } else if candidates.isEmpty {
                ContentUnavailableView(
                    "No candidates",
                    systemImage: "checkmark.circle",
                    description: Text(
                        "Assignment and exam markers from this class will appear here."
                    )
                )
                .accessibilityIdentifier("candidate.review.empty")
            } else {
                ContentUnavailableView(
                    "Select a candidate",
                    systemImage: "checklist",
                    description: Text(
                        "Review its saved source and decide what should happen next."
                    )
                )
                .accessibilityIdentifier("candidate.review.select")
            }
        }
        .onAppear {
            selectAvailableCandidate()
            reconcilePendingReview()
        }
        .onChange(of: filter) { _, _ in
            selectedCaptureID = nil
            selectAvailableCandidate()
        }
        .onChange(of: candidateIDs) { _, _ in
            selectAvailableCandidate()
        }
        .onChange(of: academicModel.workspace) { _, _ in
            reconcilePendingReview()
        }
        .onChange(of: allowsEditing) { _, _ in
            reconcilePendingReview()
        }
        .onChange(of: horizontalSizeClass) { _, _ in
            selectAvailableCandidate()
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(detailOwnsRetryState)
        .accessibilityIdentifier("candidate.review.sheet")
    }

    private func selectAvailableCandidate() {
        if let selectedCaptureID, candidateIDs.contains(selectedCaptureID) {
            return
        }
        selectedCaptureID = horizontalSizeClass == .compact
            ? nil
            : candidateIDs.first
    }

    private func reconcilePendingReview() {
        let currentCapture = presentationState.pendingMutation.flatMap { mutation in
            academicModel.workspace.captures.first { $0.id == mutation.captureID }
        }
        switch presentationState.reconcile(
            currentCapture: currentCapture,
            allowsEditing: allowsEditing
        ) {
        case .none, .expectedImage:
            break
        case .applied:
            notice = CandidateReviewNotice(
                message: String(localized: "Candidate review saved."),
                isError: false
            )
        case .conflict:
            notice = CandidateReviewNotice(
                message: String(
                    localized: "This candidate changed elsewhere. The newer saved version was not overwritten."
                ),
                isError: true
            )
        case .missing:
            notice = CandidateReviewNotice(
                message: String(
                    localized: "This candidate is no longer in the saved class."
                ),
                isError: true
            )
        case .terminalSession:
            notice = CandidateReviewNotice(
                message: String(localized: "This completed class is read-only here."),
                isError: true
            )
        }
    }

    private func candidateRow(_ capture: CaptureItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label {
                Text(markerTitle(capture.kind))
            } icon: {
                Image(systemName: markerConfiguration(capture.kind).symbolName)
            }
            .font(.headline)

            if let title = capture.draftFields.title {
                Text(verbatim: title)
                    .font(.subheadline)
                    .lineLimit(2)
            } else {
                Text("Name not added yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text(stateTitle(capture))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func markerConfiguration(
        _ kind: CaptureKind
    ) -> TextDocumentCaptureMarkerConfiguration {
        TextDocumentCaptureMarkerConfiguration(kind: kind)
    }

    private func markerTitle(_ kind: CaptureKind) -> LocalizedStringKey {
        LocalizedStringKey(markerConfiguration(kind).localizationKey)
    }

    private func filterTitle(_ filter: CandidateReviewFilter) -> LocalizedStringKey {
        switch filter {
        case .all: "All"
        case .assignments: "Assignments"
        case .exams: "Exams"
        }
    }

    private func sectionTitle(
        _ section: CandidateReviewSection
    ) -> LocalizedStringKey {
        switch section {
        case .toReview: "To review"
        case .readyForLaterConfirmation: "Ready for later confirmation"
        case .rejected: "Rejected"
        }
    }

    private func stateTitle(_ capture: CaptureItem) -> LocalizedStringKey {
        switch (capture.state, capture.resolution?.kind) {
        case (.inbox, _): "New candidate"
        case (.needsDetails, _): "Needs details"
        case (.readyToConfirm, _): "Ready for later confirmation"
        case (.resolved, .rejected): "Rejected"
        case (.resolved, _): "Resolved"
        }
    }
}

struct CandidateReviewDetailIdentity: Hashable {
    let captureID: CaptureItemID
    let revision: Int64
    let canonicalCapture: Data

    init(capture: CaptureItem) {
        captureID = capture.id
        revision = capture.revision
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        canonicalCapture = (try? encoder.encode(capture))
            ?? Data("\(capture.id.description):\(capture.revision)".utf8)
    }
}

private struct CandidateReviewNotice: Equatable {
    let message: String
    let isError: Bool
}

private struct CandidateReviewDetail: View {
    @EnvironmentObject private var academicModel: AcademicAppModel

    let capture: CaptureItem
    let courseTimeZoneIdentifier: String
    let allowsEditing: Bool
    @Binding var presentationState: CandidateReviewPresentationState
    let onNotice: (CandidateReviewNotice?) -> Void

    @State private var draft: CandidateEditorDraft
    @State private var rejectionReason = ""

    init(
        capture: CaptureItem,
        courseTimeZoneIdentifier: String,
        allowsEditing: Bool,
        presentationState: Binding<CandidateReviewPresentationState>,
        onNotice: @escaping (CandidateReviewNotice?) -> Void
    ) {
        self.capture = capture
        self.courseTimeZoneIdentifier = courseTimeZoneIdentifier
        self.allowsEditing = allowsEditing
        _presentationState = presentationState
        self.onNotice = onNotice
        _draft = State(initialValue: CandidateEditorDraft(
            capture: capture,
            timeZoneIdentifier: courseTimeZoneIdentifier
        ))
    }

    private var canEditFields: Bool {
        allowsEditing
            && capture.state != .resolved
            && presentationState.pendingMutation == nil
    }

    private var isWorking: Bool { presentationState.isWorking }
    private var errorMessage: String? { presentationState.errorMessage }
    private var pendingMutation: CaptureReviewMutation? {
        presentationState.pendingMutation
    }

    private var canAdvanceState: Bool {
        capture.state == .inbox || capture.state == .needsDetails
    }

    var body: some View {
        Form {
            statusSection
            sourceSection
            fieldsSection

            if canEditFields {
                decisionSection
            } else if capture.state == .resolved,
                      capture.resolution?.kind == .rejected {
                rejectedSection
            } else if !allowsEditing {
                Section {
                    Label(
                        "This completed class is read-only here.",
                        systemImage: "lock.fill"
                    )
                    .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                errorSection(errorMessage)
            }
        }
        .navigationTitle("Candidate review")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .overlay {
            if isWorking {
                ProgressView("Saving candidate review")
                    .padding()
                    .background(
                        .regularMaterial,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .accessibilityIdentifier("candidate.review.saving")
            }
        }
        .accessibilityIdentifier("candidate.review.detail")
    }

    private var statusSection: some View {
        Section {
            Label {
                Text(markerTitle)
            } icon: {
                Image(systemName: markerConfiguration.symbolName)
            }
            LabeledContent("Status", value: String(localized: stateTitle))
            Text(
                "Ready for later confirmation records a reviewed candidate only. It does not create a formal assignment, exam, notification, or hard deadline."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        } header: {
            Text("Candidate")
        }
    }

    private var sourceSection: some View {
        Section("Saved source") {
            CaptureSourcePreviewCard(capture: capture)
        }
    }

    private var fieldsSection: some View {
        Section("Details") {
            TextField("Candidate name", text: $draft.title)
                .accessibilityIdentifier("candidate.review.title")
            TextField("Scope or coverage", text: $draft.scope, axis: .vertical)
                .lineLimit(2 ... 4)
                .accessibilityIdentifier("candidate.review.scope")
            TextField("Notes", text: $draft.details, axis: .vertical)
                .lineLimit(2 ... 5)
                .accessibilityIdentifier("candidate.review.notes")

            Picker("Date certainty", selection: $draft.dateCertainty) {
                ForEach(AcademicDateCertainty.allCases, id: \.self) { certainty in
                    Text(dateCertaintyTitle(certainty)).tag(certainty)
                }
            }
            .accessibilityIdentifier("candidate.review.dateCertainty")

            if draft.dateCertainty != .unknown {
                DatePicker(
                    "Date",
                    selection: $draft.date,
                    displayedComponents: .date
                )
                .environment(
                    \.timeZone,
                    TimeZone(identifier: courseTimeZoneIdentifier) ?? .current
                )
                .accessibilityIdentifier("candidate.review.date")
            }

            if draft.hasUnrepresentableStoredDate {
                Label(
                    "The saved date cannot be represented in this course time zone. Choose a new date or mark it unknown before saving.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .accessibilityIdentifier("candidate.review.date.invalid")
            }
        }
        .disabled(!canEditFields)
    }

    private var decisionSection: some View {
        Section {
            Button("Save draft") {
                makeAndSubmit(.saveDraft)
            }
            .accessibilityIdentifier("candidate.review.saveDraft")

            if capture.state == .inbox {
                Button("Keep in Needs Details") {
                    makeAndSubmit(.needsDetails)
                }
                .accessibilityIdentifier("candidate.review.needsDetails")
            }

            if canAdvanceState {
                Button("Ready for later confirmation") {
                    makeAndSubmit(.ready)
                }
                .disabled(!draft.canMarkReady)
                .accessibilityIdentifier("candidate.review.ready")
            }

            TextField(
                "Reason for rejecting this marker",
                text: $rejectionReason,
                axis: .vertical
            )
            .lineLimit(2 ... 4)
            .accessibilityIdentifier("candidate.review.rejectionReason")

            Button("Reject candidate", role: .destructive) {
                makeAndSubmit(.reject)
            }
            .disabled(
                rejectionReason
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            )
            .accessibilityIdentifier("candidate.review.reject")
        } header: {
            Text("Decision")
        }
    }

    private var rejectedSection: some View {
        Section("Decision") {
            Label("Rejected", systemImage: "xmark.circle.fill")
                .foregroundStyle(.secondary)
            if let reason = capture.resolution?.reason {
                Text(verbatim: reason)
            }
        }
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(.orange)

            if pendingMutation != nil {
                Button("Retry the same review") { retryPendingMutation() }
                    .accessibilityIdentifier("candidate.review.retry")
                Button("Reload saved candidate", role: .cancel) {
                    reloadSavedCandidate()
                }
                .accessibilityIdentifier("candidate.review.reload")
            }
        } header: {
            Text(pendingMutation == nil ? "Review needs attention" : "Safe retry available")
        } footer: {
            if pendingMutation != nil {
                Text(
                    "Retrying reuses the exact same fields, audit identifiers, and review time."
                )
            }
        }
        .accessibilityIdentifier("candidate.review.error")
    }

    private var markerConfiguration: TextDocumentCaptureMarkerConfiguration {
        TextDocumentCaptureMarkerConfiguration(kind: capture.kind)
    }

    private var markerTitle: LocalizedStringKey {
        LocalizedStringKey(markerConfiguration.localizationKey)
    }

    private var stateTitle: String.LocalizationValue {
        switch (capture.state, capture.resolution?.kind) {
        case (.inbox, _): "New candidate"
        case (.needsDetails, _): "Needs details"
        case (.readyToConfirm, _): "Ready for later confirmation"
        case (.resolved, .rejected): "Rejected"
        case (.resolved, _): "Resolved"
        }
    }

    private func dateCertaintyTitle(
        _ certainty: AcademicDateCertainty
    ) -> LocalizedStringKey {
        switch certainty {
        case .unknown: "Unknown"
        case .estimated: "Estimated"
        case .confirmed: "Confirmed"
        }
    }

    private enum ReviewAction {
        case saveDraft
        case needsDetails
        case ready
        case reject
    }

    private func makeAndSubmit(_ action: ReviewAction) {
        guard !isWorking, pendingMutation == nil else { return }
        do {
            let timestamp = max(Date(), capture.modifiedAt)
            let intent: CaptureReviewIntent
            switch action {
            case .saveDraft:
                let fields = try draft.makeFields()
                intent = .saveDraft(
                    fields: fields,
                    occurredAt: timestamp,
                    auditID: CaptureAuditEntryID()
                )
            case .needsDetails:
                let fields = try draft.makeFields()
                intent = .markNeedsDetails(
                    fields: fields,
                    occurredAt: timestamp,
                    auditID: CaptureAuditEntryID()
                )
            case .ready:
                let fields = try draft.makeFields()
                intent = .markReadyToConfirm(
                    fields: fields,
                    occurredAt: timestamp,
                    auditIDs: capture.state == .inbox
                        ? [CaptureAuditEntryID(), CaptureAuditEntryID()]
                        : [CaptureAuditEntryID()]
                )
            case .reject:
                intent = .reject(
                    reason: rejectionReason.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                    occurredAt: timestamp,
                    auditID: CaptureAuditEntryID()
                )
            }
            let mutation = try CaptureReviewMutation(
                base: capture,
                intent: intent
            )
            guard presentationState.begin(mutation) else { return }
            submit(mutation)
        } catch {
            presentationState.presentLocalError(reviewErrorMessage(error))
            onNotice(nil)
        }
    }

    private func retryPendingMutation() {
        guard let pendingMutation = presentationState.beginRetry() else { return }
        Task { @MainActor in
            if case .unavailable = academicModel.availability {
                await academicModel.retry()
            }
            guard presentationState.isCurrent(pendingMutation) else { return }
            submit(pendingMutation)
        }
    }

    private func reloadSavedCandidate() {
        guard let pendingMutation = presentationState.beginReload() else { return }
        Task { @MainActor in
            await academicModel.retry()
            guard presentationState.isCurrent(pendingMutation) else { return }
            if case .ready = academicModel.availability {
                _ = presentationState.abandonAfterReload(pendingMutation)
            } else {
                _ = presentationState.retainForRetry(
                    pendingMutation,
                    errorMessage: academicModel.failure?.message
                    ?? String(localized: "Academic data is still unavailable. Try again.")
                )
            }
        }
    }

    private func submit(_ mutation: CaptureReviewMutation) {
        guard presentationState.isCurrent(mutation), isWorking else { return }
        onNotice(nil)
        Task { @MainActor in
            let outcome = await academicModel.reviewCapture(
                mutation,
                savedAt: mutation.resultingCapture.modifiedAt
            )
            guard presentationState.isCurrent(mutation) else { return }
            switch outcome {
            case .applied, .alreadyApplied:
                if presentationState.complete(mutation) {
                    onNotice(CandidateReviewNotice(
                        message: String(localized: "Candidate review saved."),
                        isError: false
                    ))
                }
            case .revisionConflict:
                if presentationState.complete(mutation) {
                    onNotice(CandidateReviewNotice(
                        message: String(
                            localized: "This candidate changed elsewhere. The newer saved version was not overwritten."
                        ),
                        isError: true
                    ))
                }
            case .missing:
                if presentationState.complete(mutation) {
                    onNotice(CandidateReviewNotice(
                        message: String(
                            localized: "This candidate is no longer in the saved class."
                        ),
                        isError: true
                    ))
                }
            case let .invalid(message):
                _ = presentationState.complete(mutation, withError: message)
            case .notReady:
                _ = presentationState.retainForRetry(
                    mutation,
                    errorMessage: academicModel.failure?.message
                    ?? String(
                        localized: "The review is ready, but academic data could not be saved."
                    )
                )
            }
        }
    }

    private func reviewErrorMessage(_ error: any Error) -> String {
        if draft.hasUnrepresentableStoredDate {
            return String(
                localized: "Choose a valid date in the course time zone or mark the date unknown."
            )
        }
        return error.localizedDescription
    }
}
