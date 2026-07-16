import SwiftUI

public struct NextStepPaperReaderScreen: View {
    @State private var selectedHighlightID = NextStepPreviewFixtures.paper.highlights.first?.id
    @State private var showsInspector = false

    public init() {}

    public var body: some View {
        NextStepAdaptiveView { mode in
            if mode == .expansive {
                HStack(spacing: 0) {
                    reader
                    Divider()
                    inspector
                        .frame(width: NextStepSize.inspectorWidth)
                }
            } else {
                reader
                    .safeAreaInset(edge: .bottom) {
                        compactInspectorControl
                    }
            }
        }
        .background(NextStepPalette.appBackground)
        .navigationTitle("論文閱讀")
        .accessibilityIdentifier("nextstep.screen.papers")
        .sheet(isPresented: $showsInspector) {
            NavigationStack {
                inspector
                    .navigationTitle("螢光標記")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showsInspector = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var reader: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NextStepSpacing.lg) {
                PaperCitationCard(paper: NextStepPreviewFixtures.paper)
                readingToolbar

                VStack(alignment: .leading, spacing: NextStepSpacing.md) {
                    Text("PROPOSITION I")
                        .font(NextStepTypography.metadata)
                        .foregroundStyle(NextStepPalette.secondaryText)
                    Text("Capital Structure and Market Value")
                        .font(NextStepTypography.pageTitle)
                        .foregroundStyle(NextStepPalette.primaryText)
                    Text(sampleParagraphOne)
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(NextStepPalette.primaryText)
                        .lineSpacing(7)
                    HighlightedPassage(
                        highlight: NextStepPreviewFixtures.paper.highlights[0],
                        isSelected: selectedHighlightID == NextStepPreviewFixtures.paper.highlights[0].id
                    ) {
                        selectedHighlightID = NextStepPreviewFixtures.paper.highlights[0].id
                        showsInspector = true
                    }
                    Text(sampleParagraphTwo)
                        .font(.system(.body, design: .serif))
                        .foregroundStyle(NextStepPalette.primaryText)
                        .lineSpacing(7)
                    HighlightedPassage(
                        highlight: NextStepPreviewFixtures.paper.highlights[1],
                        isSelected: selectedHighlightID == NextStepPreviewFixtures.paper.highlights[1].id
                    ) {
                        selectedHighlightID = NextStepPreviewFixtures.paper.highlights[1].id
                        showsInspector = true
                    }
                }
                .frame(maxWidth: NextStepSize.readingColumnMaximum, alignment: .leading)
                .padding(.horizontal, NextStepSpacing.md)
                .padding(.vertical, NextStepSpacing.lg)
                .background(NextStepPalette.surface)
                .clipShape(RoundedRectangle(cornerRadius: NextStepRadius.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: NextStepRadius.card, style: .continuous)
                        .stroke(NextStepPalette.divider, lineWidth: 1)
                }
            }
            .frame(maxWidth: NextStepSize.readingColumnMaximum + 64)
            .frame(maxWidth: .infinity)
            .padding(NextStepSpacing.md)
            .padding(.bottom, 68)
        }
    }

    private var readingToolbar: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
            HighlightLegend()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NextStepSpacing.sm) { readerActions }
                VStack(alignment: .leading, spacing: NextStepSpacing.xs) { readerActions }
            }
        }
    }

    @ViewBuilder
    private var readerActions: some View {
        Button {} label: {
            Label("畫記", systemImage: "highlighter")
                .frame(minHeight: NextStepSize.minimumTapTarget)
        }
        .buttonStyle(.bordered)

        Button {} label: {
            Label("加入學習任務", systemImage: "plus.square.on.square")
                .frame(minHeight: NextStepSize.minimumTapTarget)
        }
        .buttonStyle(.bordered)

        OriginalFileLink()
    }

    private var compactInspectorControl: some View {
        Button { showsInspector = true } label: {
            Label("查看標記與來源定位", systemImage: "sidebar.trailing")
                .frame(maxWidth: .infinity, minHeight: NextStepSize.minimumTapTarget)
        }
        .buttonStyle(.borderedProminent)
        .tint(NextStepPalette.primaryAccent)
        .padding(.horizontal, NextStepSpacing.md)
        .padding(.vertical, NextStepSpacing.xs)
        .background(.bar)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NextStepSpacing.md) {
                Text("標記檢查器")
                    .font(NextStepTypography.sectionTitle)
                    .accessibilityAddTraits(.isHeader)

                SourceConfidenceBadge(confidence: 0.98, isVerified: true)

                if let highlight = selectedHighlight {
                    NextStepBadge(
                        title: highlight.kind.title,
                        symbolName: highlight.kind.symbolName,
                        tint: highlight.kind.color
                    )
                    Text(highlight.text)
                        .font(NextStepTypography.citation)
                        .padding(NextStepSpacing.sm)
                        .background(highlight.kind.color.opacity(0.38))
                        .clipShape(RoundedRectangle(cornerRadius: NextStepRadius.control))
                    LabeledContent("原始位置", value: highlight.sourceLocation)
                        .font(NextStepTypography.metadata)
                    Text("AI 解釋")
                        .font(NextStepTypography.annotation)
                        .foregroundStyle(NextStepPalette.aiGenerated)
                    Text(highlight.explanation)
                        .font(NextStepTypography.supporting)
                    AIGeneratedBadge()
                } else {
                    ContentUnavailableView(
                        "尚未選擇標記",
                        systemImage: "highlighter",
                        description: Text("點選文章中的螢光段落以檢視來源定位。")
                    )
                }

                Divider()
                OriginalFileLink()
                Button {} label: {
                    Label("標示為已理解", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity, minHeight: NextStepSize.minimumTapTarget)
                }
                .buttonStyle(.bordered)
            }
            .padding(NextStepSpacing.md)
        }
        .background(NextStepPalette.surface.opacity(0.5))
    }

    private var selectedHighlight: NextStepPreviewHighlight? {
        NextStepPreviewFixtures.paper.highlights.first { $0.id == selectedHighlightID }
    }

    private var sampleParagraphOne: String {
        "Consider a firm whose expected return depends on the productive use of its assets. The financing claims divide that return among investors, while the assumptions of the model determine whether this division can change total market value."
    }

    private var sampleParagraphTwo: String {
        "The proposition is useful because it makes the assumptions visible. Taxes, transaction costs, distress costs, information asymmetry and agency effects must be evaluated before applying the result to observed financing decisions."
    }
}

#Preview("Paper Reader · Light") {
    NavigationStack { NextStepPaperReaderScreen() }
        .preferredColorScheme(.light)
}

#Preview("Paper Reader · Dark") {
    NavigationStack { NextStepPaperReaderScreen() }
        .preferredColorScheme(.dark)
}
