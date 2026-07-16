import SwiftUI

struct SessionEndConfirmationSheet: View {
    @Environment(\.dismiss) private var dismiss

    let markerCount: Int
    let candidateCount: Int
    let isWorking: Bool
    let errorMessage: String?
    let onEndAndReview: () -> Void
    let onEndAndReviewLater: () -> Void
    let onRetry: (() -> Void)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text(verbatim: CurrentDevicePresentation.localized(
                            "Saved on this iPad"
                        ))
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                    }
                        .foregroundStyle(.green)
                        .accessibilityIdentifier("session.end.notesSaved")

                    LabeledContent("Class markers", value: markerCount.formatted())
                    LabeledContent(
                        "Assignment and exam candidates",
                        value: candidateCount.formatted()
                    )
                } header: {
                    Text("Ready to end class")
                } footer: {
                    Text("Ending class stops new class markers. Your note stays available and editable.")
                }

                Section {
                    Button {
                        onEndAndReview()
                    } label: {
                        Label("End and review now", systemImage: "checklist")
                    }
                    .disabled(isWorking || errorMessage != nil)
                    .accessibilityIdentifier("session.end.reviewNow")

                    Button {
                        onEndAndReviewLater()
                    } label: {
                        Label("End and review later", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(isWorking || errorMessage != nil)
                    .accessibilityIdentifier("session.end.reviewLater")
                } footer: {
                    Text("Review later is safe: this class will remain in Needs Review after relaunch.")
                }

                if let errorMessage {
                    Section {
                        Label {
                            Text(verbatim: errorMessage)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                            .foregroundStyle(.orange)

                        if let onRetry {
                            Button("Retry ending class") {
                                onRetry()
                            }
                            .disabled(isWorking)
                            .accessibilityIdentifier("session.end.retry")
                        }
                    } header: {
                        Text("The note is safe")
                    } footer: {
                        if onRetry != nil {
                            Text("Only the class status failed to save. Retrying reuses the same end request.")
                        } else {
                            Text("The saved class status changed or this request is no longer valid. Close this sheet and review the current session.")
                        }
                    }
                    .accessibilityIdentifier("session.end.error")
                }
            }
            .navigationTitle("End class")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isWorking)
            .interactiveDismissDisabled(isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
            }
            .overlay {
                if isWorking {
                    ProgressView("Ending class")
                        .padding()
                        .background(
                            .regularMaterial,
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                        .accessibilityIdentifier("session.end.saving")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("session.end.sheet")
    }
}
