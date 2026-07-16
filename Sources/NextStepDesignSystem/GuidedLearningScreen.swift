import SwiftUI

public struct NextStepGuidedLearningScreen: View {
    @State private var selectedStepID = NextStepPreviewFixtures.learningSteps.dropFirst().first?.id
    @State private var showsSources = false

    public init() {}

    public var body: some View {
        NextStepAdaptiveView { mode in
            switch mode {
            case .compact:
                compactContent
            case .balanced:
                balancedContent
            case .expansive:
                expansiveContent
            }
        }
        .background(NextStepPalette.appBackground)
        .navigationTitle("引導學習")
        .accessibilityIdentifier("nextstep.screen.learning")
        .sheet(isPresented: $showsSources) {
            NavigationStack {
                sourceInspector
                    .navigationTitle("任務來源")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showsSources = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var compactContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NextStepSpacing.md) {
                packageHeader
                LearningTimer(elapsedMinutes: 7, totalMinutes: 35)
                currentStepContent
                stepList
                QuizCard(
                    question: "在有公司稅且其他條件不變時，負債稅盾通常如何影響 WACC？",
                    options: ["提高", "降低", "完全沒有影響"],
                    correctIndex: 1
                )
                CompletionCriteriaBlock(criteria: [
                    "以自己的話寫出至少 120 字解釋",
                    "三題理解測驗至少答對兩題",
                    "標記一項理論限制"
                ])
                .nextStepCard()
            }
            .padding(NextStepSpacing.md)
            .padding(.bottom, 68)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: NextStepSpacing.sm) {
                Button { showsSources = true } label: {
                    Label("來源", systemImage: "books.vertical")
                        .frame(minHeight: NextStepSize.minimumTapTarget)
                }
                .buttonStyle(.bordered)

                Button {} label: {
                    Label("完成步驟", systemImage: "checkmark")
                        .frame(maxWidth: .infinity, minHeight: NextStepSize.minimumTapTarget)
                }
                .buttonStyle(.borderedProminent)
                .tint(NextStepPalette.primaryAccent)
            }
            .padding(.horizontal, NextStepSpacing.md)
            .padding(.vertical, NextStepSpacing.xs)
            .background(.bar)
        }
    }

    private var balancedContent: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
                    Text("學習步驟")
                        .font(NextStepTypography.sectionTitle)
                    stepList
                }
                .padding(NextStepSpacing.md)
            }
            .frame(width: 290)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: NextStepSpacing.md) {
                    packageHeader
                    LearningTimer(elapsedMinutes: 7, totalMinutes: 35)
                    currentStepContent
                    QuizCard(
                        question: "負債稅盾在其他條件不變時通常如何影響 WACC？",
                        options: ["提高", "降低", "沒有影響"],
                        correctIndex: 1
                    )
                    Button { showsSources = true } label: {
                        Label("檢視任務來源", systemImage: "books.vertical")
                            .frame(minHeight: NextStepSize.minimumTapTarget)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(NextStepSpacing.lg)
                .frame(maxWidth: NextStepSize.readingColumnMaximum)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var expansiveContent: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
                    Text("學習步驟")
                        .font(NextStepTypography.sectionTitle)
                    stepList
                }
                .padding(NextStepSpacing.md)
            }
            .frame(width: 280)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: NextStepSpacing.md) {
                    packageHeader
                    LearningTimer(elapsedMinutes: 7, totalMinutes: 35)
                    currentStepContent
                    KnowledgeLink(
                        from: "負債稅盾",
                        to: "WACC",
                        relationship: "在限制條件下可能降低"
                    )
                    QuizCard(
                        question: "負債稅盾在其他條件不變時通常如何影響 WACC？",
                        options: ["提高", "降低", "沒有影響"],
                        correctIndex: 1
                    )
                }
                .padding(NextStepSpacing.lg)
                .frame(maxWidth: NextStepSize.readingColumnMaximum)
                .frame(maxWidth: .infinity)
            }

            Divider()
            sourceInspector
                .frame(width: NextStepSize.inspectorWidth)
        }
    }

    private var packageHeader: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
            HStack {
                AIGeneratedBadge()
                VerifiedSourceBadge(isVerified: true)
            }
            Text("理解負債如何影響 WACC")
                .font(NextStepTypography.pageTitle)
                .foregroundStyle(NextStepPalette.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text("今天安排，是因為週五個案討論會直接使用這個概念。預計 35 分鐘。")
                .font(NextStepTypography.body)
                .foregroundStyle(NextStepPalette.secondaryText)
        }
    }

    private var stepList: some View {
        VStack(spacing: NextStepSpacing.xs) {
            ForEach(NextStepPreviewFixtures.learningSteps) { step in
                let selectedStep = NextStepPreviewLearningStep(
                    id: step.id,
                    index: step.index,
                    title: step.title,
                    detail: step.detail,
                    durationMinutes: step.durationMinutes,
                    state: selectedStepID == step.id ? .selected : step.state
                )
                GuidedLearningStep(step: selectedStep) {
                    selectedStepID = step.id
                }
            }
        }
    }

    private var currentStepContent: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.md) {
            Label("目前步驟 · 閱讀指定證據", systemImage: "book.pages")
                .font(NextStepTypography.sectionTitle)
                .foregroundStyle(NextStepPalette.primaryText)
            Text("閱讀第 14–16 頁。先找到 Proposition I，再比較有稅與無稅條件；不要把原始結論套用到所有市場。")
                .font(NextStepTypography.body)
                .foregroundStyle(NextStepPalette.primaryText)
            HighlightedPassage(
                highlight: NextStepPreviewFixtures.paper.highlights[0],
                isSelected: true
            )
        }
        .nextStepCard(state: .selected)
    }

    private var sourceInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NextStepSpacing.md) {
                Text("已準備的來源")
                    .font(NextStepTypography.sectionTitle)
                    .accessibilityAddTraits(.isHeader)
                SourceConfidenceBadge(confidence: 0.96, isVerified: true)
                ForEach(NextStepPreviewFixtures.sources) { source in
                    SourceCard(source: source)
                }
                Text("所有摘要與測驗都必須連回上述原始位置。")
                    .font(NextStepTypography.metadata)
                    .foregroundStyle(NextStepPalette.secondaryText)
            }
            .padding(NextStepSpacing.md)
        }
        .background(NextStepPalette.surface.opacity(0.45))
    }
}

#Preview("Guided Learning · Light") {
    NavigationStack { NextStepGuidedLearningScreen() }
        .preferredColorScheme(.light)
}

#Preview("Guided Learning · Dark") {
    NavigationStack { NextStepGuidedLearningScreen() }
        .preferredColorScheme(.dark)
}
