import SwiftUI

public struct NextStepTodayScreen: View {
    @State private var selectedActionID = NextStepPreviewFixtures.todayActions.first?.id
    @State private var showsReplanNotice = false
    private let onOpenGuidedLearning: () -> Void

    public init(onOpenGuidedLearning: @escaping () -> Void = {}) {
        self.onOpenGuidedLearning = onOpenGuidedLearning
    }

    public var body: some View {
        NextStepAdaptiveView { mode in
            if mode == .compact {
                compactContent
            } else {
                wideContent(mode: mode)
            }
        }
        .background(NextStepPalette.appBackground)
        .navigationTitle("今天")
        .accessibilityIdentifier("nextstep.screen.today")
        .alert("重新規劃預覽", isPresented: $showsReplanNotice) {
            Button("保留原計畫", role: .cancel) {}
            Button("檢視影響") {}
        } message: {
            Text("NextStep 會先顯示受影響的任務與里程碑，不會直接改動固定期限。")
        }
    }

    private var compactContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: NextStepSpacing.md) {
                pageHeader
                GoalProgressHeader(goal: NextStepPreviewFixtures.graduationGoal)
                summaryStrip
                actionList
                ReplanControl { showsReplanNotice = true }
                    .frame(maxWidth: .infinity, alignment: .leading)
                riskCard
            }
            .padding(NextStepSpacing.md)
            .padding(.bottom, 72)
        }
        .safeAreaInset(edge: .bottom) {
            startSelectedButton
                .padding(.horizontal, NextStepSpacing.md)
                .padding(.vertical, NextStepSpacing.xs)
                .background(.bar)
        }
    }

    private func wideContent(mode: NextStepLayoutMode) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: NextStepSpacing.md) {
                    pageHeader
                    summaryStrip
                    actionList
                }
                .padding(mode.horizontalPadding)
                .frame(maxWidth: 840)
                .frame(maxWidth: .infinity)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: NextStepSpacing.md) {
                    GoalProgressHeader(goal: NextStepPreviewFixtures.graduationGoal)
                    riskCard
                    ReplanControl { showsReplanNotice = true }
                    startSelectedButton
                }
                .padding(NextStepSpacing.lg)
            }
            .frame(width: NextStepSize.inspectorWidth)
            .background(NextStepPalette.surface.opacity(0.45))
        }
    }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
            Text("7 月 15 日 · 星期三")
                .font(NextStepTypography.metadata)
                .foregroundStyle(NextStepPalette.secondaryText)
            Text("先完成最重要的一步")
                .font(NextStepTypography.display)
                .foregroundStyle(NextStepPalette.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text("今天完成 3 項行動，將推進論文、課程與求職三個里程碑。")
                .font(NextStepTypography.body)
                .foregroundStyle(NextStepPalette.secondaryText)
        }
    }

    private var summaryStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NextStepSpacing.sm) { summaryItems }
            VStack(alignment: .leading, spacing: NextStepSpacing.xs) { summaryItems }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(NextStepSpacing.sm)
        .background(NextStepPalette.surface)
        .clipShape(RoundedRectangle(cornerRadius: NextStepRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NextStepRadius.card, style: .continuous)
                .stroke(NextStepPalette.divider, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var summaryItems: some View {
        Label("1 小時 45 分", systemImage: "clock")
        Divider().frame(height: 18)
        Label("3 個行動", systemImage: "checklist")
        Divider().frame(height: 18)
        Label("1 項落後風險", systemImage: "exclamationmark.triangle")
            .foregroundStyle(NextStepPalette.warning)
    }

    private var actionList: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            Text("依建議順序")
                .font(NextStepTypography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(NextStepPreviewFixtures.todayActions.enumerated()), id: \.element.id) { index, action in
                TodayActionCard(action: action, isPrimary: index == 0) {
                    selectedActionID = action.id
                    onOpenGuidedLearning()
                }
                .onTapGesture {
                    selectedActionID = action.id
                }
            }
        }
    }

    private var riskCard: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
            Label("計畫風險", systemImage: "exclamationmark.triangle.fill")
                .font(NextStepTypography.annotation)
                .foregroundStyle(NextStepPalette.warning)
            Text("若本週少於 4 小時，文獻回顧將無法在 8 月 15 日前完成。")
                .font(NextStepTypography.supporting)
            Text("系統不會移動固定期限；可預覽拆小或調整其他彈性任務。")
                .font(NextStepTypography.metadata)
                .foregroundStyle(NextStepPalette.secondaryText)
        }
        .nextStepCard(state: .overdue)
    }

    private var startSelectedButton: some View {
        Button {
            selectedActionID = selectedActionID ?? NextStepPreviewFixtures.todayActions.first?.id
            onOpenGuidedLearning()
        } label: {
            Label("開始目前行動", systemImage: "play.fill")
                .frame(maxWidth: .infinity, minHeight: NextStepSize.minimumTapTarget)
        }
        .buttonStyle(.borderedProminent)
        .tint(NextStepPalette.primaryAccent)
        .font(NextStepTypography.button)
        .accessibilityHint("直接進入任務材料，不必先搜尋來源")
        .accessibilityIdentifier("nextstep.today.start")
    }
}

#Preview("Today · iPhone Light") {
    NavigationStack { NextStepTodayScreen() }
        .preferredColorScheme(.light)
}

#Preview("Today · iPhone Dark") {
    NavigationStack { NextStepTodayScreen() }
        .preferredColorScheme(.dark)
}
