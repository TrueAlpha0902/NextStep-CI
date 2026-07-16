import SwiftUI

public struct NextStepWorkspaceScreen: View {
    @State private var selectedKind: NextStepWorkspaceKind = .thesis
    @State private var selectedItemID = NextStepPreviewFixtures.workspaceItems.first?.id

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
        .navigationTitle("研究、作品與求職")
        .accessibilityIdentifier("nextstep.screen.workspace")
        .onChange(of: selectedKind) { _, kind in
            selectedItemID = items(for: kind).first?.id
        }
    }

    private var compactContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NextStepSpacing.md) {
                Picker("工作區類型", selection: $selectedKind) {
                    ForEach(NextStepWorkspaceKind.allCases) { kind in
                        Label(kind.rawValue, systemImage: kind.symbolName)
                            .tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("選擇論文、作品或求職工作區")

                workspacePageHeader

                ForEach(items(for: selectedKind)) { item in
                    workspaceCard(item)
                }

                selectedItemDetail
            }
            .padding(NextStepSpacing.md)
        }
        .safeAreaInset(edge: .bottom) {
            Button {} label: {
                Label("開始下一個產出", systemImage: "play.fill")
                    .frame(maxWidth: .infinity, minHeight: NextStepSize.minimumTapTarget)
            }
            .buttonStyle(.borderedProminent)
            .tint(NextStepPalette.primaryAccent)
            .padding(.horizontal, NextStepSpacing.md)
            .padding(.vertical, NextStepSpacing.xs)
            .background(.bar)
        }
    }

    private var wideContent: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: NextStepSpacing.md) {
                    workspacePageHeader
                    ForEach(NextStepWorkspaceKind.allCases) { kind in
                        Button {
                            selectedKind = kind
                        } label: {
                            HStack {
                                Label(kind.rawValue, systemImage: kind.symbolName)
                                Spacer()
                                Text("\(items(for: kind).count)")
                                    .font(NextStepTypography.metadata)
                            }
                            .frame(minHeight: NextStepSize.minimumTapTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(
                            selectedKind == kind
                                ? NextStepPalette.primaryAccent
                                : NextStepPalette.primaryText
                        )
                    }
                    Divider()
                    ForEach(items(for: selectedKind)) { item in
                        workspaceCard(item)
                    }
                }
                .padding(NextStepSpacing.md)
            }
            .frame(width: 340)
            .background(NextStepPalette.surface.opacity(0.45))

            Divider()

            ScrollView {
                selectedItemDetail
                    .padding(NextStepSpacing.xl)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var workspacePageHeader: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
            Text("工作區")
                .font(NextStepTypography.metadata)
                .foregroundStyle(NextStepPalette.secondaryText)
            Text("每個專案都連回每日產出")
                .font(NextStepTypography.pageTitle)
                .foregroundStyle(NextStepPalette.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text("來源、進度、待確認事項與下一個可執行產出集中在同一處。")
                .font(NextStepTypography.supporting)
                .foregroundStyle(NextStepPalette.secondaryText)
        }
    }

    private func workspaceCard(_ item: NextStepPreviewWorkspaceItem) -> some View {
        Button {
            selectedKind = item.kind
            selectedItemID = item.id
        } label: {
            VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
                HStack {
                    Label(item.kind.rawValue, systemImage: item.kind.symbolName)
                        .font(NextStepTypography.annotation)
                        .foregroundStyle(NextStepPalette.primaryAccent)
                    Spacer()
                    NextStepStateBadge(state: item.state)
                }
                Text(item.title)
                    .font(NextStepTypography.sectionTitle)
                    .foregroundStyle(NextStepPalette.primaryText)
                LabeledContent("階段", value: item.phase)
                LabeledContent("下一個產出", value: item.nextOutput)
                ProgressView(value: item.progress)
                    .tint(item.state.foregroundColor)
                HStack {
                    Text(item.progress, format: .percent.precision(.fractionLength(0)))
                    Spacer()
                    Label("\(item.sourceCount) 個來源", systemImage: "books.vertical")
                }
                .font(NextStepTypography.metadata)
                .foregroundStyle(NextStepPalette.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .nextStepCard(state: selectedItemID == item.id ? .selected : item.state)
        .accessibilityLabel("\(item.kind.rawValue)工作區，\(item.title)，\(item.state.title)")
    }

    @ViewBuilder
    private var selectedItemDetail: some View {
        if let item = selectedItem {
            VStack(alignment: .leading, spacing: NextStepSpacing.lg) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
                        Text(item.kind.rawValue)
                            .font(NextStepTypography.metadata)
                            .foregroundStyle(NextStepPalette.secondaryText)
                        Text(item.title)
                            .font(NextStepTypography.display)
                            .foregroundStyle(NextStepPalette.primaryText)
                            .accessibilityAddTraits(.isHeader)
                        Text("目前階段 · \(item.phase)")
                            .font(NextStepTypography.body)
                            .foregroundStyle(NextStepPalette.secondaryText)
                    }
                    Spacer()
                    NextStepStateBadge(state: item.state)
                }

                nextOutputCard(item)
                evidenceBoard(for: item)
                phaseChecklist(for: item.kind)
            }
        } else {
            ContentUnavailableView(
                "尚無工作區",
                systemImage: selectedKind.symbolName,
                description: Text("新增目標或來源後，NextStep 會建立第一個可執行階段。")
            )
        }
    }

    private func nextOutputCard(_ item: NextStepPreviewWorkspaceItem) -> some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            Label("下一個明確產出", systemImage: "arrow.forward.circle.fill")
                .font(NextStepTypography.annotation)
                .foregroundStyle(NextStepPalette.primaryAccent)
            Text(item.nextOutput)
                .font(NextStepTypography.sectionTitle)
            WhyTodayBlock(reason: "這是目前 critical path 上最小且已準備材料的行動。")
            CompletionCriteriaBlock(criteria: completionCriteria(for: item.kind))
            Button {} label: {
                Label("開始引導式工作", systemImage: "play.fill")
                    .frame(maxWidth: .infinity, minHeight: NextStepSize.minimumTapTarget)
            }
            .buttonStyle(.borderedProminent)
            .tint(NextStepPalette.primaryAccent)
        }
        .nextStepCard(state: .selected)
    }

    private func evidenceBoard(for item: NextStepPreviewWorkspaceItem) -> some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            HStack {
                Text("已準備的證據與來源")
                    .font(NextStepTypography.sectionTitle)
                Spacer()
                VerifiedSourceBadge(isVerified: item.state != .aiUncertain)
            }

            ForEach(NextStepPreviewFixtures.sources) { source in
                HStack(alignment: .top, spacing: NextStepSpacing.sm) {
                    Image(systemName: source.isVerified ? "checkmark.circle.fill" : "questionmark.circle")
                        .foregroundStyle(
                            source.isVerified
                                ? NextStepPalette.sourceVerified
                                : NextStepPalette.sourceUnverified
                        )
                    VStack(alignment: .leading, spacing: NextStepSpacing.xxs) {
                        Text(source.title)
                            .font(NextStepTypography.supporting.weight(.semibold))
                        Text(source.location)
                            .font(NextStepTypography.metadata)
                            .foregroundStyle(NextStepPalette.secondaryText)
                    }
                }
            }
        }
        .nextStepCard()
    }

    private func phaseChecklist(for kind: NextStepWorkspaceKind) -> some View {
        let steps: [String] = switch kind {
        case .thesis: ["研究問題", "文獻搜尋", "文獻比較", "研究缺口", "研究方法", "章節撰寫"]
        case .project: ["問題定義", "需求整理", "Wireframe", "Prototype", "開發測試", "Case Study"]
        case .career: ["職缺分析", "能力差距", "履歷", "作品集", "Mock Interview", "投遞追蹤"]
        }

        return VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            Text("生命週期")
                .font(NextStepTypography.sectionTitle)
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack {
                    Image(systemName: index < 2 ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(index < 2 ? NextStepPalette.success : NextStepPalette.secondaryText)
                    Text(step)
                        .font(NextStepTypography.supporting)
                }
            }
        }
        .nextStepCard()
    }

    private var selectedItem: NextStepPreviewWorkspaceItem? {
        NextStepPreviewFixtures.workspaceItems.first { $0.id == selectedItemID }
            ?? items(for: selectedKind).first
    }

    private func items(for kind: NextStepWorkspaceKind) -> [NextStepPreviewWorkspaceItem] {
        NextStepPreviewFixtures.workspaceItems.filter { $0.kind == kind }
    }

    private func completionCriteria(for kind: NextStepWorkspaceKind) -> [String] {
        switch kind {
        case .thesis:
            ["250 字背景段落", "至少 2 個可追溯引用", "未確認研究範圍獨立標示"]
        case .project:
            ["完成 1 條核心流程", "記錄 3 個測試觀察", "建立下一輪修改清單"]
        case .career:
            ["3 行以內", "至少 1 個量化成果", "對應目標職缺的共同要求"]
        }
    }
}

#Preview("Workspace · Light") {
    NavigationStack { NextStepWorkspaceScreen() }
        .preferredColorScheme(.light)
}

#Preview("Workspace · Dark") {
    NavigationStack { NextStepWorkspaceScreen() }
        .preferredColorScheme(.dark)
}
