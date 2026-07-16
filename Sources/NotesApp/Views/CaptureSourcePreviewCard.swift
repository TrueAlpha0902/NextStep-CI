import Foundation
import NextStepAcademic
import SwiftUI

struct CaptureSourcePreviewCard: View {
    @EnvironmentObject private var appModel: AppModel

    let capture: CaptureItem

    @State private var preview: CaptureSourcePreview?
    @State private var retryID = UUID()

    private struct LoadIdentity: Hashable {
        let captureID: CaptureItemID
        let revision: Int64
        let retryID: UUID
    }

    private var loadIdentity: LoadIdentity {
        LoadIdentity(
            captureID: capture.id,
            revision: capture.revision,
            retryID: retryID
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Captured source", systemImage: "text.quote")
                .font(.headline)

            sourceContent
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            Color(uiColor: .secondarySystemBackground),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .task(id: loadIdentity) {
            await loadSource(identity: loadIdentity)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("candidate.source")
    }

    @ViewBuilder
    private var sourceContent: some View {
        if case .quickCapture = capture.source {
            Label("Quick capture", systemImage: "bolt.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let rawText = capture.rawText {
                Text(verbatim: rawText)
                    .textSelection(.enabled)
            }
        } else if let preview {
            previewContent(preview)
        } else {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking the saved paragraph")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("candidate.source.loading")
        }
    }

    @ViewBuilder
    private func previewContent(_ preview: CaptureSourcePreview) -> some View {
        switch preview {
        case let .exact(text):
            status(
                "Matches captured source",
                symbol: "checkmark.circle.fill",
                color: .green
            )
            Text(verbatim: text)
                .textSelection(.enabled)
                .accessibilityIdentifier("candidate.source.exact")

        case let .changed(currentText):
            status(
                "Source needs relocation: paragraph changed after capture",
                symbol: "exclamationmark.triangle.fill",
                color: .orange
            )
            Text("Current paragraph (changed)")
                .font(.caption.weight(.semibold))
            Text(verbatim: currentText)
                .textSelection(.enabled)
                .accessibilityIdentifier("candidate.source.changed")

        case let .unverifiable(currentText):
            status(
                "This older marker has no source hash to verify",
                symbol: "questionmark.diamond.fill",
                color: .orange
            )
            Text(verbatim: currentText)
                .textSelection(.enabled)
                .accessibilityIdentifier("candidate.source.unverifiable")

        case .missing:
            status(
                "Source needs relocation: paragraph was removed",
                symbol: "text.badge.xmark",
                color: .orange
            )
            Text("NextStep will not guess or move this marker to different text.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("candidate.source.missing")

        case .unavailable:
            status(
                "Source is temporarily unavailable",
                symbol: "exclamationmark.triangle.fill",
                color: .orange
            )
            Button("Retry source check") {
                self.preview = nil
                retryID = UUID()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("candidate.source.retry")
        }
    }

    private func status(
        _ title: LocalizedStringKey,
        symbol: String,
        color: Color
    ) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
    }

    @MainActor
    private func loadSource(identity: LoadIdentity) async {
        guard loadIdentity == identity else { return }
        preview = nil
        let result: CaptureSourcePreview
        switch capture.source {
        case .quickCapture:
            return
        case let .noteAnchor(anchor):
            result = await appModel.captureSourcePreview(
                noteID: anchor.noteID,
                pageID: anchor.pageID,
                blockID: anchor.blockID,
                expectedTextHash: anchor.textHash
            )
        }
        guard !Task.isCancelled, loadIdentity == identity else { return }
        preview = result
    }
}
