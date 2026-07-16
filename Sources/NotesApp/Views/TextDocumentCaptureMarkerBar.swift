import Foundation
import NextStepAcademic
import NotesCore
import SwiftUI

enum TextDocumentCapturePhase: Equatable, Sendable {
    case ready
    case saving(CaptureKind)
    case succeeded(message: String)
    case failed(message: String)

    var inFlightKind: CaptureKind? {
        guard case let .saving(kind) = self else { return nil }
        return kind
    }

    var retainsCaptureTarget: Bool {
        switch self {
        case .saving, .failed:
            true
        case .ready, .succeeded:
            false
        }
    }

    var disablesMarkerControls: Bool {
        switch self {
        case .saving, .failed:
            true
        case .ready, .succeeded:
            false
        }
    }

    var hasVisibleStatus: Bool {
        self != .ready
    }

    var isFailure: Bool {
        guard case .failed = self else { return false }
        return true
    }
}

struct TextDocumentCapturePresentation: Equatable, Sendable {
    var isEnabled: Bool
    var phase: TextDocumentCapturePhase

    init(
        isEnabled: Bool = true,
        phase: TextDocumentCapturePhase = .ready
    ) {
        self.isEnabled = isEnabled
        self.phase = phase
    }

    var isBusy: Bool {
        phase.inFlightKind != nil
    }

    var inFlightKind: CaptureKind? {
        phase.inFlightKind
    }
}

struct TextDocumentCaptureMarkerConfiguration: Equatable, Identifiable, Sendable {
    let kind: CaptureKind
    let localizationKey: String
    let symbolName: String

    var id: CaptureKind { kind }

    var accessibilityIdentifier: String {
        "capture.kind.\(kind.rawValue)"
    }

    init(kind: CaptureKind) {
        self.kind = kind
        switch kind {
        case .professorEmphasis:
            localizationKey = "Professor emphasis"
            symbolName = "highlighter"
        case .learningGap:
            localizationKey = "Learning gap"
            symbolName = "questionmark.circle"
        case .assignmentCandidate:
            localizationKey = "Assignment"
            symbolName = "checklist"
        case .examCandidate:
            localizationKey = "Exam"
            symbolName = "graduationcap"
        case .researchIdea:
            localizationKey = "Research idea"
            symbolName = "lightbulb"
        case .currentAffairsLink:
            localizationKey = "Current affairs"
            symbolName = "newspaper"
        case .evidenceCandidate:
            localizationKey = "Evidence"
            symbolName = "quote.bubble"
        }
    }

    static let all = CaptureKind.allCases.map { Self(kind: $0) }
}

enum TextDocumentCaptureTargeting {
    static func isEligible(_ block: TextBlock) -> Bool {
        block.style != .divider
            && !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func eligibleBlockID(
        preferredBlockID: TextBlockID?,
        in document: TextDocument
    ) -> TextBlockID? {
        guard let preferredBlockID,
              let block = document.blocks.first(where: { $0.id == preferredBlockID }),
              isEligible(block)
        else { return nil }
        return preferredBlockID
    }
}

struct TextDocumentCaptureMarkerBar: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let presentation: TextDocumentCapturePresentation
    let isLocallyDispatching: Bool
    let onCapture: (CaptureKind) -> Void
    let onRetry: (() -> Void)?
    let onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: presentation.phase.hasVisibleStatus ? 8 : 0) {
            ScrollView(
                .horizontal,
                showsIndicators: horizontalSizeClass == .compact
            ) {
                HStack(spacing: 8) {
                    ForEach(TextDocumentCaptureMarkerConfiguration.all) { marker in
                        markerButton(marker)
                    }
                }
                .padding(.horizontal, 12)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("capture.markerBar.scroll")

            statusContent
                .padding(.horizontal, 12)
        }
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture.markerBar")
    }

    private func markerButton(
        _ marker: TextDocumentCaptureMarkerConfiguration
    ) -> some View {
        let isSavingThisKind = presentation.inFlightKind == marker.kind

        return Button {
            onCapture(marker.kind)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: marker.symbolName)
                    .font(.title3)
                    .frame(height: 22)
                    .opacity(isSavingThisKind ? 0 : 1)
                    .overlay {
                        if isSavingThisKind {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                Text(LocalizedStringKey(marker.localizationKey))
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(minWidth: 72, minHeight: 52)
        }
        .buttonStyle(.bordered)
        .disabled(
            isLocallyDispatching
                || presentation.phase.disablesMarkerControls
        )
        .accessibilityLabel(Text(LocalizedStringKey(marker.localizationKey)))
        .accessibilityAddTraits(isSavingThisKind ? .isSelected : [])
        .accessibilityIdentifier(marker.accessibilityIdentifier)
    }

    @ViewBuilder
    private var statusContent: some View {
        switch presentation.phase {
        case .ready:
            EmptyView()
        case .saving:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Saving…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("capture.status.saving")
        case let .succeeded(message):
            Label {
                Text(verbatim: message)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
            }
            .font(.caption)
            .foregroundStyle(.green)
            .accessibilityIdentifier("capture.status.succeeded")
        case let .failed(message):
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    failureMessage(message)
                    Spacer(minLength: 0)
                    failureActions
                }

                VStack(alignment: .leading, spacing: 8) {
                    failureMessage(message)
                    failureActions
                }
            }
            .font(.caption)
            .foregroundStyle(.red)
            .accessibilityIdentifier("capture.status.failed")
        }
    }

    private func failureMessage(_ message: String) -> some View {
        Label {
            Text(verbatim: message)
                .lineLimit(3)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var failureActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                failureActionButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                failureActionButtons
            }
        }
    }

    @ViewBuilder
    private var failureActionButtons: some View {
        if let onRetry {
            Button("Retry", action: onRetry)
                .buttonStyle(.bordered)
                .disabled(isLocallyDispatching)
                .accessibilityIdentifier("capture.retry")
        }
        if let onCancel {
            Button("Discard pending marker", role: .destructive, action: onCancel)
                .buttonStyle(.bordered)
                .disabled(isLocallyDispatching)
                .accessibilityIdentifier("capture.discard")
        }
    }
}

struct TextDocumentCaptureBadges: View {
    let blockID: TextBlockID
    let kinds: Set<CaptureKind>

    private var markers: [TextDocumentCaptureMarkerConfiguration] {
        TextDocumentCaptureMarkerConfiguration.all.filter {
            kinds.contains($0.kind)
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            ForEach(markers) { marker in
                Image(systemName: marker.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: Capsule()
                    )
                    .accessibilityLabel(
                        Text(LocalizedStringKey(marker.localizationKey))
                    )
                    .accessibilityIdentifier(
                        "capture.badge.\(blockID.description).\(marker.kind.rawValue)"
                    )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture.badges.\(blockID.description)")
    }
}
