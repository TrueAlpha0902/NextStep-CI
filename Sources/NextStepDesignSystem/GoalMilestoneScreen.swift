import SwiftUI

public struct NextStepGoalMilestoneScreen: View {
    @State private var showsPlanAdjustment = false

    public init() {}

    public var body: some View {
        NextStepAdaptiveView { mode in
            if mode == .compact {
                compactContent
            } else {
                wideContent
            }
        }
        .background(NextStepPalette.appBackground)
        .navigationTitle("目標與里程碑")
        .accessibilityIdentifier("nextstep.screen.goals")
        .sheet(isPresented: $showsPlanAdjustment) {
            NavigationStack {
                replanPreview
                    .navigationTitle("計畫影響預覽")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("關閉") { showsPlanAdjustment = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private var compactContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NextStepSpacing.md) {
                GoalProgressHeader(goal: NextStepPreviewFixtures.graduationGoal)
                goalChain
                milestoneCard
                weeklyOutcome
                riskSummary
            }
            .padding(NextStepSpacing.md)
        }
    }

    private var wideContent: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: NextStepSpacing.lg) {
                    GoalProgressHeader(goal: NextStepPreviewFixtures.graduationGoal)
                    goalChain
                    weeklyOutcome
                }
                .padding(NextStepSpacing.lg)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: NextStepSpacing.md) {
                    milestoneCard
                    riskSummary
                }
                .padding(NextStepSpacing.lg)
            }
            .frame(width: 390)
            .background(NextStepPalette.surface.opacity(0.42))
        }
    }

    private var goalChain: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            Text("這條路徑如何連到今天")
                .font(NextStepTypography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            chainRow(label: "Goal", title: "完成論文研究", symbol: "target")
            chainConnector
            chainRow(label: "Milestone", title: "完成文獻回顧", symbol: "flag")
            chainConnector
            chainRow(label: "本週成果", title: "完成研究背景與 5 篇核心文獻矩陣", symbol: "calendar.day.timeline.left")
            chainConnector
            chainRow(label: "今天", title: "完成研究背景第一段", symbol: "checkmark.square")
        }
        .nextStepCard()
    }

    private func chainRow(label: String, title: String, symbol: String) -> some View {
        HStack(spacing: NextStepSpacing.sm) {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
                .foregroundStyle(NextStepPalette.primaryAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(NextStepTypography.metadata)
                    .foregroundStyle(NextStepPalette.secondaryText)
                Text(title)
                    .font(NextStepTypography.supporting.weight(.semibold))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var chainConnector: some View {
        Image(systemName: "arrow.down")
            .font(.caption)
            .foregroundStyle(NextStepPalette.secondaryText)
            .padding(.leading, 7)
            .accessibilityHidden(true)
    }

    private var milestoneCard: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.md) {
            HStack {
                Text("里程碑時間線")
                    .font(NextStepTypography.sectionTitle)
                Spacer()
                Button("調整") { showsPlanAdjustment = true }
                    .buttonStyle(.bordered)
            }
            MilestoneTimeline(milestones: NextStepPreviewFixtures.milestones)
        }
        .nextStepCard()
    }

    private var weeklyOutcome: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            Label("本週必須產出的成果", systemImage: "calendar.badge.checkmark")
                .font(NextStepTypography.sectionTitle)
            Text("完成研究背景 600 字草稿，以及 5 篇核心文獻的理論、方法、證據與限制比較。")
                .font(NextStepTypography.body)
            CompletionCriteriaBlock(criteria: [
                "每項主張至少連到一個 SourceAnchor",
                "引用作者、年份與來源位置已驗證",
                "指導教授待確認事項獨立標示"
            ])
        }
        .nextStepCard(state: .selected)
    }

    private var riskSummary: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            NextStepStateBadge(state: .overdue)
            Text("目前按過去 14 天完成速度推估，文獻回顧將晚 3 天。")
                .font(NextStepTypography.supporting)
            Button { showsPlanAdjustment = true } label: {
                Label("查看可行的恢復方案", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, minHeight: NextStepSize.minimumTapTarget)
            }
            .buttonStyle(.borderedProminent)
            .tint(NextStepPalette.warning)
        }
        .nextStepCard(state: .overdue)
    }

    private var replanPreview: some View {
        List {
            Section("不會改動") {
                Label("8 月 15 日固定期限", systemImage: "lock.fill")
                Label("每週四 14:00 指導會議", systemImage: "calendar")
            }
            Section("建議變更") {
                LabeledContent("拆分", value: "兩個 25 分鐘閱讀行動")
                LabeledContent("移動", value: "作品集任務延後至週日")
                LabeledContent("效果", value: "預估恢復 2 天進度")
            }
            Section {
                Button("確認套用建議") {}
                    .frame(maxWidth: .infinity)
            } footer: {
                Text("這是 AI 候選方案；Planning Engine 會再次檢查硬期限與可用時間。")
            }
        }
    }
}

#Preview("Goal & Milestone · Light") {
    NavigationStack { NextStepGoalMilestoneScreen() }
        .preferredColorScheme(.light)
}

#Preview("Goal & Milestone · Dark") {
    NavigationStack { NextStepGoalMilestoneScreen() }
        .preferredColorScheme(.dark)
}
