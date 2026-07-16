import Foundation
import NextStepAcademic
import SwiftUI

struct SessionWrapUpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var academicModel: AcademicAppModel

    let courseTimeZoneIdentifier: String
    let onCompleted: () -> Void

    @State private var draft: SessionWrapUpDraft
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var canRetry = false
    @State private var visibleCaptureCount = 25

    init(
        draft: SessionWrapUpDraft,
        courseTimeZoneIdentifier: String,
        onCompleted: @escaping () -> Void
    ) {
        _draft = State(initialValue: draft)
        self.courseTimeZoneIdentifier = courseTimeZoneIdentifier
        self.onCompleted = onCompleted
    }

    var body: some View {
        NavigationStack {
            Form {
                overviewSection

                ForEach(
                    draft.capturePresentations(limit: visibleCaptureCount)
                ) { capture in
                    captureSection(capture)
                }

                if visibleCaptureCount < draft.captureCount {
                    Section {
                        Button("Show more markers") {
                            visibleCaptureCount = min(
                                draft.captureCount,
                                visibleCaptureCount + 25
                            )
                        }
                        .disabled(isWorking)
                        .accessibilityIdentifier("session.wrapUp.showMore")
                    } footer: {
                        Text(
                            "Markers are shown in small batches so a large class remains responsive."
                        )
                    }
                }

                summarySection
                outcomeSection

                if let errorMessage {
                    errorSection(errorMessage)
                }
            }
            .accessibilityIdentifier("session.wrapUp.form")
            .navigationTitle("Class wrap-up")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Review later") { dismiss() }
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Finish review") { finishReview() }
                        .fontWeight(.semibold)
                        .disabled(
                            isWorking || draft.isFrozen || canRetry
                                || !draft.canFinish
                        )
                        .accessibilityIdentifier("session.wrapUp.finish")
                }
            }
            .overlay {
                if isWorking {
                    ProgressView("Saving class review")
                        .padding()
                        .background(
                            .regularMaterial,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .accessibilityIdentifier("session.wrapUp.saving")
                }
            }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("session.wrapUp.sheet")
    }

    private var overviewSection: some View {
        Section {
            Label {
                Text(verbatim: CurrentDevicePresentation.localized(
                    "Saved on this iPad"
                ))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
                .foregroundStyle(.green)
            LabeledContent(
                "Markers to review",
                value: draft.decisionCounts.unresolvedCaptures.formatted()
            )
            Text("Choose one outcome for each marker. Ready for later confirmation does not create a formal assignment, exam, or deadline yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("2–5 minute review")
        }
        .accessibilityIdentifier("session.wrapUp.overview")
    }

    @ViewBuilder
    private func captureSection(
        _ capture: SessionWrapUpCapturePresentation
    ) -> some View {
        Section {
            CaptureSourcePreviewCard(capture: capture.capture)

            if capture.isAlreadyResolved {
                if capture.isAlreadyRejected {
                    Label("Already rejected", systemImage: "xmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Resolved marker", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                if !capture.rejectionReason.isEmpty {
                    Text(verbatim: capture.rejectionReason)
                }
            } else {
                Picker("Decision", selection: decisionBinding(capture.captureID)) {
                    ForEach(capture.allowedDecisions, id: \.self) { decision in
                        Text(decisionTitle(decision)).tag(decision)
                    }
                }
                .accessibilityIdentifier(
                    "session.wrapUp.decision.\(capture.captureID.description)"
                )

                if capture.selectedDecision == .markNeedsDetails
                    || capture.selectedDecision == .markReadyToConfirm {
                    editableFields(for: capture)
                }

                if capture.selectedDecision == .reject {
                    TextField(
                        "Reason for removing this marker",
                        text: rejectionReasonBinding(capture.captureID),
                        axis: .vertical
                    )
                    .lineLimit(2 ... 4)
                    .accessibilityIdentifier(
                        "session.wrapUp.rejection.\(capture.captureID.description)"
                    )
                }
            }
        } header: {
            Label {
                Text(captureTitle(capture))
            } icon: {
                Image(systemName: markerConfiguration(capture.kind).symbolName)
            }
        }
        .accessibilityIdentifier(
            "session.wrapUp.capture.\(capture.captureID.description)"
        )
        .disabled(isWorking || draft.isFrozen)
    }

    @ViewBuilder
    private func editableFields(
        for capture: SessionWrapUpCapturePresentation
    ) -> some View {
        if capture.isAssignmentOrExamCandidate {
            TextField("Candidate name", text: fieldBinding(capture.captureID, \.title))
                .accessibilityIdentifier(
                    "session.wrapUp.title.\(capture.captureID.description)"
                )
            TextField(
                "Scope or coverage",
                text: fieldBinding(capture.captureID, \.scope),
                axis: .vertical
            )
            .lineLimit(2 ... 4)

            Picker(
                "Date certainty",
                selection: dateCertaintyBinding(capture.captureID)
            ) {
                ForEach(AcademicDateCertainty.allCases, id: \.self) { certainty in
                    Text(dateCertaintyTitle(certainty)).tag(certainty)
                }
            }

            if (fieldPresentation(capture.captureID)?.fields.dateCertainty
                    ?? .unknown) != .unknown {
                DatePicker(
                    "Date",
                    selection: dateBinding(capture.captureID),
                    displayedComponents: .date
                )
                .environment(
                    \.timeZone,
                    TimeZone(identifier: courseTimeZoneIdentifier) ?? .current
                )
            }
        }

        TextField(
            "Review notes",
            text: fieldBinding(capture.captureID, \.details),
            axis: .vertical
        )
        .lineLimit(2 ... 5)
    }

    private var summarySection: some View {
        Section {
            TextField(
                "What mattered in this class?",
                text: Binding(
                    get: { draft.oneLineSummary },
                    set: { value in
                        do {
                            try draft.setOneLineSummary(value)
                            clearDraftError()
                        } catch {
                            presentDraftError(error)
                        }
                    }
                )
            )
            .accessibilityIdentifier("session.wrapUp.summary")
        } header: {
            Text("One-line class summary")
        } footer: {
            if let error = draft.finishValidationError {
                Text(verbatim: wrapUpErrorMessage(error))
                    .foregroundStyle(.orange)
            }
        }
        .disabled(isWorking || draft.isFrozen)
    }

    private var outcomeSection: some View {
        let counts = draft.decisionCounts
        return Section {
            LabeledContent("Keep", value: counts.keepAsIs.formatted())
            LabeledContent("Needs details", value: counts.markNeedsDetails.formatted())
            LabeledContent(
                "Ready for later confirmation",
                value: counts.markReadyToConfirm.formatted()
            )
            LabeledContent("Reject", value: counts.reject.formatted())
            if draft.noNewActionsConfirmed {
                Label("No new actions to confirm", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Outcome preview")
        } footer: {
            Text("V1 records review decisions only. Formal assignments, exams, hard deadlines, and planning are added in the next approved phase.")
        }
        .accessibilityIdentifier("session.wrapUp.outcomes")
    }

    private func errorSection(_ message: String) -> some View {
        Section {
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
                .foregroundStyle(.orange)
            if canRetry {
                Button("Retry saving review") { retrySave() }
                    .disabled(isWorking)
                    .accessibilityIdentifier("session.wrapUp.retry")
            }
        } header: {
            Text(canRetry ? "The review is ready to retry" : "Review needs attention")
        } footer: {
            Text(
                canRetry
                    ? "Retrying reuses the exact same decisions, identifiers, and completion time."
                    : "Close the review and reopen the current saved session before making another decision."
            )
        }
        .accessibilityIdentifier("session.wrapUp.error")
    }

    private func markerConfiguration(
        _ kind: CaptureKind
    ) -> TextDocumentCaptureMarkerConfiguration {
        TextDocumentCaptureMarkerConfiguration(kind: kind)
    }

    private func captureTitle(
        _ capture: SessionWrapUpCapturePresentation
    ) -> LocalizedStringKey {
        LocalizedStringKey(markerConfiguration(capture.kind).localizationKey)
    }

    private func fieldPresentation(
        _ captureID: CaptureItemID
    ) -> SessionWrapUpCapturePresentation? {
        draft.presentation(for: captureID)
    }

    private func decisionBinding(
        _ captureID: CaptureItemID
    ) -> Binding<SessionWrapUpDecisionKind> {
        Binding(
            get: {
                fieldPresentation(captureID)?.selectedDecision ?? .keepAsIs
            },
            set: { decision in
                do {
                    try draft.setDecision(decision, for: captureID)
                    clearDraftError()
                } catch {
                    presentDraftError(error)
                }
            }
        )
    }

    private func fieldBinding(
        _ captureID: CaptureItemID,
        _ keyPath: WritableKeyPath<SessionWrapUpEditableCaptureFields, String>
    ) -> Binding<String> {
        Binding(
            get: { fieldPresentation(captureID)?.fields[keyPath: keyPath] ?? "" },
            set: { value in
                updateFields(captureID) { $0[keyPath: keyPath] = value }
            }
        )
    }

    private func rejectionReasonBinding(
        _ captureID: CaptureItemID
    ) -> Binding<String> {
        Binding(
            get: { fieldPresentation(captureID)?.rejectionReason ?? "" },
            set: { value in
                do {
                    try draft.setRejectionReason(value, for: captureID)
                    clearDraftError()
                } catch {
                    presentDraftError(error)
                }
            }
        )
    }

    private func dateCertaintyBinding(
        _ captureID: CaptureItemID
    ) -> Binding<AcademicDateCertainty> {
        Binding(
            get: {
                fieldPresentation(captureID)?.fields.dateCertainty ?? .unknown
            },
            set: { certainty in
                updateFields(captureID) { fields in
                    fields.dateCertainty = certainty
                    if certainty == .unknown {
                        fields.date = nil
                    } else if fields.date == nil {
                        fields.date = CandidateEditorDraft.localDate(
                            from: draft.startedAt,
                            timeZoneIdentifier: courseTimeZoneIdentifier
                        )
                    }
                }
            }
        )
    }

    private func dateBinding(_ captureID: CaptureItemID) -> Binding<Date> {
        Binding(
            get: {
                guard let localDate = fieldPresentation(captureID)?.fields.date else {
                    return draft.startedAt
                }
                return CandidateEditorDraft.date(
                    from: localDate,
                    timeZoneIdentifier: courseTimeZoneIdentifier
                ) ?? draft.startedAt
            },
            set: { date in
                guard let localDate = CandidateEditorDraft.localDate(
                    from: date,
                    timeZoneIdentifier: courseTimeZoneIdentifier
                ) else {
                    errorMessage = String(localized: "This date cannot be represented in the course time zone.")
                    canRetry = false
                    return
                }
                updateFields(captureID) { $0.date = localDate }
            }
        )
    }

    private func updateFields(
        _ captureID: CaptureItemID,
        update: (inout SessionWrapUpEditableCaptureFields) -> Void
    ) {
        guard var fields = fieldPresentation(captureID)?.fields else { return }
        update(&fields)
        do {
            try draft.setFields(fields, for: captureID)
            clearDraftError()
        } catch {
            presentDraftError(error)
        }
    }

    private func decisionTitle(
        _ decision: SessionWrapUpDecisionKind
    ) -> LocalizedStringKey {
        switch decision {
        case .keepAsIs: "Keep marker"
        case .markNeedsDetails: "Needs details"
        case .markReadyToConfirm: "Ready for later confirmation"
        case .reject: "Reject marker"
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

    private func finishReview() {
        guard !isWorking,
              !draft.isFrozen,
              !canRetry,
              draft.canFinish else { return }
        do {
            let transaction = try draft.finish(
                completedAt: max(Date(), draft.startedAt)
            )
            submit(transaction)
        } catch {
            presentDraftError(error)
        }
    }

    private func retrySave() {
        guard !isWorking,
              canRetry,
              let transaction = draft.frozenTransaction else { return }
        isWorking = true
        Task { @MainActor in
            if case .unavailable = academicModel.availability {
                await academicModel.retry()
            }
            isWorking = false
            submit(transaction)
        }
    }

    private func submit(_ transaction: SessionWrapUpTransaction) {
        errorMessage = nil
        canRetry = false
        isWorking = true
        Task { @MainActor in
            let outcome = await academicModel.completeWrapUp(
                transaction,
                savedAt: transaction.completedAt
            )
            isWorking = false
            switch outcome {
            case .completed, .alreadyCompleted:
                onCompleted()
                dismiss()
            case .conflict:
                errorMessage = String(localized: "This class changed elsewhere. No review decision was overwritten.")
            case let .invalid(message):
                errorMessage = message
            case .notReady:
                canRetry = true
                errorMessage = academicModel.failure?.message
                    ?? String(localized: "The review is ready, but academic data could not be saved.")
            }
        }
    }

    private func clearDraftError() {
        guard !draft.isFrozen else { return }
        errorMessage = nil
        canRetry = false
    }

    private func presentDraftError(_ error: any Error) {
        errorMessage = wrapUpErrorMessage(error)
        canRetry = false
    }

    private func wrapUpErrorMessage(_ error: any Error) -> String {
        switch error as? SessionWrapUpDraftError {
        case .candidateTitleRequired:
            String(localized: "Add a candidate name before marking it ready for later confirmation.")
        case .candidateDateCertaintyRequired:
            String(localized: "Choose whether the candidate date is unknown, estimated, or confirmed.")
        case .summaryRequired:
            String(localized: "Add a one-line class summary before finishing review.")
        case .summaryTooLong:
            String(localized: "Shorten the one-line class summary before finishing review.")
        case .summaryMustBeOneLine:
            String(localized: "Keep the class summary on one line before finishing review.")
        case .rejectionReasonRequired:
            String(localized: "Add a reason before rejecting this marker.")
        case .rejectionReasonTooLong:
            String(localized: "Shorten the rejection reason before finishing review.")
        case .invalidCaptureFields:
            String(localized: "Check the selected marker's fields before finishing review.")
        case .decisionNotAllowed:
            String(localized: "That decision is not available for the marker's current state.")
        case .frozen:
            String(localized: "This review is frozen for a safe retry and can no longer be edited.")
        case .captureNotFound, .captureAlreadyResolved, .duplicateCapture,
             .captureRelationshipMismatch, .duplicateAuditID:
            String(localized: "The saved class markers changed. Close and reopen this review.")
        case .unsupportedSessionStatus:
            String(localized: "This class no longer needs a wrap-up.")
        case .invalidStartedAt, .tooManyCaptures:
            String(localized: "This class review could not be prepared safely.")
        case nil:
            if error is AcademicDomainError {
                String(localized: "One or more review fields is invalid or too long.")
            } else {
                error.localizedDescription
            }
        }
    }
}
