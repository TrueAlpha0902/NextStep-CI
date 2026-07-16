import Foundation
import NextStepDesignSystem
import NextStepDomain
import NextStepGrounding
import NextStepPlanning
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct NextStepBetaGroundedPassageSegment: Equatable, Sendable {
    let text: String
    let isHighlighted: Bool
}

func nextStepBetaGroundedPassageSegments(
    passage: String,
    occurrences: [DocumentFactOccurrence],
    anchorID: SourceAnchorID
) -> [NextStepBetaGroundedPassageSegment] {
    let source = passage as NSString
    let matchingOccurrences = occurrences.filter { occurrence in
        occurrence.anchorID == anchorID
    }
    let unsortedRanges: [NSRange] = matchingOccurrences.map { occurrence in
        NSRange(location: occurrence.utf16Start, length: occurrence.utf16Length)
    }
    let ranges = unsortedRanges.sorted { lhs, rhs in
        if lhs.location == rhs.location {
            return lhs.length < rhs.length
        }
        return lhs.location < rhs.location
    }
    var result: [NextStepBetaGroundedPassageSegment] = []
    var cursor = 0
    for range in ranges {
        guard range.location >= cursor,
              NSMaxRange(range) <= source.length else { continue }
        if range.location > cursor {
            result.append(.init(
                text: source.substring(with: NSRange(
                    location: cursor,
                    length: range.location - cursor
                )),
                isHighlighted: false
            ))
        }
        result.append(.init(text: source.substring(with: range), isHighlighted: true))
        cursor = NSMaxRange(range)
    }
    if cursor < source.length {
        result.append(.init(text: source.substring(from: cursor), isHighlighted: false))
    }
    if result.isEmpty {
        result.append(.init(text: passage, isHighlighted: false))
    }
    return result
}

public struct NextStepBetaRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var model: NextStepBetaModel
    private let onOpenNotesLibrary: () -> Void

    public init(onOpenNotesLibrary: @escaping () -> Void = {}) {
        let arguments = ProcessInfo.processInfo.arguments
        let isUITestFixture = arguments.contains("-ui-testing")
            && arguments.contains("-nextstep-beta-ui-test")
        _model = State(
            initialValue: isUITestFixture
                ? NextStepBetaUITestFixture.makeModel()
                : NextStepBetaModel()
        )
        self.onOpenNotesLibrary = onOpenNotesLibrary
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.loadState == .ready {
                NextStepBetaMessageStack(model: model)
            }

            Group {
                switch model.loadState {
                case .loading:
                    NextStepBetaLoadingView()
                case let .failed(message):
                    NextStepBetaFatalErrorView(message: message) {
                        Task { await model.load() }
                    }
                case .ready:
                    if horizontalSizeClass == .regular {
                        NextStepBetaPadShell(
                            model: model,
                            onOpenNotesLibrary: onOpenNotesLibrary
                        )
                    } else {
                        NextStepBetaPhoneShell(
                            model: model,
                            onOpenNotesLibrary: onOpenNotesLibrary
                        )
                    }
                }
            }
        }
        .background(NextStepPalette.appBackground.ignoresSafeArea())
        .tint(NextStepPalette.primaryAccent)
    }
}

private enum NextStepBetaSection: String, CaseIterable, Identifiable {
    case today
    case goals
    case sources
    case progress
    case notesLibrary

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .goals: "目標"
        case .sources: "來源"
        case .progress: "進度"
        case .notesLibrary: "筆記庫"
        }
    }

    var symbolName: String {
        switch self {
        case .today: "sun.max"
        case .goals: "scope"
        case .sources: "doc.text.magnifyingglass"
        case .progress: "chart.line.uptrend.xyaxis"
        case .notesLibrary: "books.vertical"
        }
    }
}

private enum NextStepBetaDetailRoute: Hashable {
    case guided(DailyActionID)
    case groundedFact(UUID)
}

private struct NextStepBetaPhoneShell: View {
    let model: NextStepBetaModel
    let onOpenNotesLibrary: () -> Void

    var body: some View {
        TabView {
            NavigationStack {
                NextStepBetaTodayView(model: model, usesNavigationLinks: true)
            }
            .tabItem { BetaIconRow("Today", systemImage: "sun.max") }

            NavigationStack {
                NextStepBetaGoalsView(model: model)
            }
            .tabItem { BetaIconRow("目標", systemImage: "scope") }

            NavigationStack {
                NextStepBetaSourcesView(model: model)
            }
            .tabItem { BetaIconRow("來源", systemImage: "doc.text.magnifyingglass") }
            .badge(model.pendingSourceFacts.count)

            NavigationStack {
                NextStepBetaProgressView(model: model)
            }
            .tabItem { BetaIconRow("進度", systemImage: "chart.line.uptrend.xyaxis") }

            NavigationStack {
                NextStepBetaNotesLibraryBridge(onOpen: onOpenNotesLibrary)
            }
            .tabItem { BetaIconRow("筆記庫", systemImage: "books.vertical") }
        }
        .accessibilityIdentifier("nextstep.beta.compact.root")
    }
}

private struct NextStepBetaPadShell: View {
    let model: NextStepBetaModel
    let onOpenNotesLibrary: () -> Void
    @State private var selectedSection: NextStepBetaSection = .today
    @State private var detailRoute: NextStepBetaDetailRoute?

    var body: some View {
        NavigationSplitView {
            List {
                ForEach(NextStepBetaSection.allCases) { section in
                    Button {
                        detailRoute = nil
                        selectedSection = section
                    } label: {
                            HStack {
                                BetaIconRow(section.title, systemImage: section.symbolName)
                                Spacer()
                                if section == .sources, model.pendingSourceFacts.isEmpty == false {
                                    Text(verbatim: String(model.pendingSourceFacts.count))
                                        .font(NextStepTypography.metadata.weight(.semibold))
                                        .foregroundStyle(NextStepPalette.primaryAccent)
                                        .accessibilityIdentifier(
                                            "nextstep.beta.grounding.pendingCount"
                                        )
                                }
                                if selectedSection == section {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(NextStepPalette.primaryAccent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("nextstep.beta.sidebar.\(section.rawValue)")
                    .accessibilityValue(selectedSection == section ? "已選取" : "")
                }
            }
            .nextStepBetaNavigationTitle("NextStep")
            .navigationSplitViewColumnWidth(
                min: NextStepSize.sidebarMinimum,
                ideal: NextStepSize.sidebarIdeal,
                max: NextStepSize.sidebarMaximum
            )
        } detail: {
            NavigationStack {
                if let detailRoute {
                    Group {
                        switch detailRoute {
                        case .guided(let actionID):
                            NextStepBetaGuidedActionView(model: model, actionID: actionID)
                        case .groundedFact(let candidateID):
                            NextStepBetaSourceFactReviewView(
                                model: model,
                                candidateID: candidateID
                            )
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            BetaActionControl(backTitle(for: detailRoute), systemImage: "chevron.left") {
                                self.detailRoute = nil
                            }
                            .accessibilityIdentifier(backIdentifier(for: detailRoute))
                        }
                    }
                } else {
                    detail(for: selectedSection)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .accessibilityIdentifier("nextstep.beta.regular.root")
        .onChange(of: selectedSection) { _, _ in detailRoute = nil }
    }

    @ViewBuilder
    private func detail(for section: NextStepBetaSection) -> some View {
        switch section {
        case .today:
            NextStepBetaTodayView(
                model: model,
                usesNavigationLinks: false,
                onSelectAction: { detailRoute = .guided($0) },
                onSelectSourceFact: {
                    selectedSection = .sources
                    detailRoute = .groundedFact($0)
                }
            )
        case .goals:
            NextStepBetaGoalsView(model: model)
        case .sources:
            NextStepBetaSourcesView(model: model)
        case .progress:
            NextStepBetaProgressView(model: model)
        case .notesLibrary:
            NextStepBetaNotesLibraryBridge(onOpen: onOpenNotesLibrary)
        }
    }

    private func backTitle(for route: NextStepBetaDetailRoute) -> String {
        switch route {
        case .guided: "返回 Today"
        case .groundedFact: "返回來源"
        }
    }

    private func backIdentifier(for route: NextStepBetaDetailRoute) -> String {
        switch route {
        case .guided: "nextstep.beta.guided.backToday"
        case .groundedFact: "nextstep.beta.grounding.backSources"
        }
    }
}

private struct NextStepBetaTodayView: View {
    let model: NextStepBetaModel
    let usesNavigationLinks: Bool
    var onSelectAction: (DailyActionID) -> Void = { _ in }
    var onSelectSourceFact: (UUID) -> Void = { _ in }
    @State private var isGoalSheetPresented = false
    @State private var isImporterPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NextStepSpacing.lg) {
                header
                NextStepBetaOfflineBlock()

                if model.hasGoal == false {
                    NextStepBetaEmptyCard(
                        symbol: "scope",
                        title: "先設定你真正要完成的目標",
                        detail: "建立一條 Ultimate Goal → Goal → Milestone 路徑，期限會被保存為不可由規劃引擎改寫的硬期限。",
                        actionTitle: "建立第一個目標"
                    ) {
                        isGoalSheetPresented = true
                    }
                } else if model.sourceDocuments.isEmpty {
                    NextStepBetaEmptyCard(
                        symbol: "doc.badge.plus",
                        title: "加入一份可追溯來源",
                        detail: "匯入 PDF 或圖片。檔案會安全複製到 Application Support，文字在裝置端抽取。",
                        actionTitle: "匯入來源"
                    ) {
                        isImporterPresented = true
                    }
                } else if let todayPlan = model.todayPlan, todayPlan.actions.isEmpty == false {
                    TodaySummary(plan: todayPlan)
                    ForEach(todayPlan.actions) { item in
                        actionLink(for: item)
                    }
                    if todayPlan.risks.isEmpty == false {
                        NextStepBetaRiskBlock(risks: todayPlan.risks)
                    }
                    if let pending = model.pendingSourceFacts.first {
                        pendingSourceFactLink(pending)
                    }
                } else if model.workspace?.dailyActions.isEmpty == true {
                    NextStepBetaEmptyCard(
                        symbol: "text.magnifyingglass",
                        title: "來源已保存，但尚未取得可讀文字",
                        detail: "可開啟來源確認檔案。加入含可選文字的 PDF 或清晰圖片後，系統才會建立不捏造內容的任務。",
                        actionTitle: "再匯入一份來源"
                    ) {
                        isImporterPresented = true
                    }
                } else {
                    ContentUnavailableView(
                        "今天已完成",
                        systemImage: "checkmark.circle",
                        description: Text(verbatim: "進度與完成證據已保存；可手動要求規劃引擎再次評估。")
                    )
                    BetaActionControl("重新評估計畫", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await model.manualReplan() }
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: NextStepSize.minimumTapTarget)
                }
            }
            .frame(maxWidth: NextStepSize.readingColumnMaximum, alignment: .leading)
            .padding(NextStepSpacing.lg)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("nextstep.beta.screen.today")
        .background(NextStepPalette.appBackground)
        .nextStepBetaNavigationTitle("Today")
        .toolbar {
            if model.hasGoal {
                ToolbarItem(placement: .topBarTrailing) {
                    BetaActionControl("匯入來源", systemImage: "doc.badge.plus") {
                        isImporterPresented = true
                    }
                    .accessibilityHint("匯入 PDF 或圖片並在裝置端抽取文字")
                }
            }
        }
        .sheet(isPresented: $isGoalSheetPresented) {
            NextStepBetaGoalSetupSheet(model: model)
        }
        .sheet(isPresented: $isImporterPresented) {
            DocumentPicker(mode: .importableDocuments) { urls in
                Task { await model.importSources(urls) }
            }
        }
    }

    @ViewBuilder
    private func pendingSourceFactLink(_ pending: NextStepBetaPendingSourceFact) -> some View {
        if usesNavigationLinks {
            NavigationLink {
                NextStepBetaSourceFactReviewView(model: model, candidateID: pending.id)
            } label: {
                NextStepBetaPendingSourceFactCard(
                    pending: pending,
                    totalCount: model.pendingSourceFacts.count,
                    sourceTitle: model.source(for: pending)?.displayTitle
                )
            }
            .buttonStyle(.plain)
        } else {
            Button {
                onSelectSourceFact(pending.id)
            } label: {
                NextStepBetaPendingSourceFactCard(
                    pending: pending,
                    totalCount: model.pendingSourceFacts.count,
                    sourceTitle: model.source(for: pending)?.displayTitle
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
            Text(model.currentDate.formatted(.dateTime.weekday(.wide).month().day()))
                .font(NextStepTypography.metadata)
                .foregroundStyle(NextStepPalette.secondaryText)
            Text(verbatim: "打開就知道下一步")
                .font(NextStepTypography.pageTitle)
                .foregroundStyle(NextStepPalette.primaryText)
            Text(verbatim: "所有安排都由確定性規則產生；首版不呼叫 AI，也不會捏造來源摘要。")
                .font(NextStepTypography.supporting)
                .foregroundStyle(NextStepPalette.secondaryText)
        }
    }

    @ViewBuilder
    private func actionLink(for item: TodayAction) -> some View {
        if usesNavigationLinks {
            NavigationLink {
                NextStepBetaGuidedActionView(model: model, actionID: item.id)
            } label: {
                NextStepBetaTodayActionCard(item: item)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("nextstep.beta.today.primaryAction")
        } else {
            Button {
                onSelectAction(item.id)
            } label: {
                NextStepBetaTodayActionCard(item: item)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("nextstep.beta.today.primaryAction")
        }
    }
}

private struct TodaySummary: View {
    let plan: TodayPlan

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NextStepSpacing.lg) {
            VStack(alignment: .leading, spacing: NextStepSpacing.xxs) {
                Text(verbatim: "今日必要行動")
                    .font(NextStepTypography.annotation)
                    .foregroundStyle(NextStepPalette.secondaryText)
                Text(verbatim: "\(plan.actions.count) 項")
                    .font(NextStepTypography.sectionTitle)
            }
            VStack(alignment: .leading, spacing: NextStepSpacing.xxs) {
                Text(verbatim: "預估時間")
                    .font(NextStepTypography.annotation)
                    .foregroundStyle(NextStepPalette.secondaryText)
                Text(verbatim: "\(plan.totalMinutes) 分鐘")
                    .font(NextStepTypography.sectionTitle)
            }
            Spacer()
        }
        .nextStepCard()
        .accessibilityElement(children: .combine)
    }
}

private struct NextStepBetaTodayActionCard: View {
    let item: TodayAction

    var body: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: NextStepSpacing.xxs) {
                    Text(item.ultimateGoal.title)
                        .font(NextStepTypography.annotation)
                        .foregroundStyle(NextStepPalette.primaryAccent)
                    Text(item.action.title)
                        .font(NextStepTypography.sectionTitle)
                        .foregroundStyle(NextStepPalette.primaryText)
                }
                Spacer(minLength: NextStepSpacing.md)
                Image(systemName: "chevron.right")
                    .foregroundStyle(NextStepPalette.secondaryText)
            }
            BetaIconRow("\(item.action.estimatedMinutes) 分鐘", systemImage: "clock")
                .font(NextStepTypography.metadata)
            Text(item.action.whyToday)
                .font(NextStepTypography.supporting)
                .foregroundStyle(NextStepPalette.secondaryText)
            Divider()
            BetaIconRow(item.action.requiredOutput.title, systemImage: "checklist")
                .font(NextStepTypography.supporting.weight(.semibold))
            HStack {
                BetaIconRow("來源已準備", systemImage: "checkmark.shield")
                    .foregroundStyle(NextStepPalette.sourceVerified)
                Spacer()
                if let deadline = item.action.deadline?.value {
                    BetaIconRow(deadline.description, systemImage: "calendar.badge.exclamationmark")
                        .foregroundStyle(NextStepPalette.warning)
                }
            }
            .font(NextStepTypography.metadata)
        }
        .nextStepCard()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("開啟引導式學習工作區")
    }
}

private struct NextStepBetaGuidedActionView: View {
    let model: NextStepBetaModel
    let actionID: DailyActionID
    @State private var previewURL: URL?
    @State private var completionDraft = ""
    @State private var quizSelections: [QuizItemID: Set<UUID>] = [:]
    @State private var hydratedQuizID: QuizID?
    @State private var isEditingAfterQuizAttempt = false
    @FocusState private var isCompletionFocused: Bool

    var body: some View {
        Group {
            if let action = model.action(id: actionID),
               let package = model.package(for: action) {
                ScrollView {
                    VStack(alignment: .leading, spacing: NextStepSpacing.lg) {
                        guidedHeader(action: action, package: package)
                        whyToday(package)
                        sourceBlock(action: action, package: package)
                        if action.status != .inProgress && action.status != .completed {
                            executionControls(action: action)
                        }
                        exactExtractBlock(package)
                        quizBlock(action: action, package: package)
                        outputBlock(package)
                        if action.status == .inProgress || action.status == .completed {
                            executionControls(action: action)
                        }
                    }
                    .frame(maxWidth: NextStepSize.readingColumnMaximum, alignment: .leading)
                    .padding(NextStepSpacing.lg)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("nextstep.beta.screen.guided")
                .task(id: package.quiz?.metadata.id) {
                    guard let quizID = package.quiz?.metadata.id,
                          hydratedQuizID != quizID else { return }
                    quizSelections = model.latestQuizSelections(for: actionID)
                    hydratedQuizID = quizID
                    isEditingAfterQuizAttempt = false
                }
                .scrollDismissesKeyboard(.interactively)
                .background(NextStepPalette.appBackground)
                .nextStepBetaNavigationTitle("Guided Task")
                .navigationBarTitleDisplayMode(.inline)
                .quickLookPreview($previewURL)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        SwiftUI.Button {
                            isCompletionFocused = false
                        } label: {
                            Text(verbatim: "完成輸入")
                        }
                        .accessibilityIdentifier("nextstep.beta.guided.keyboardDone")
                    }
                }
            } else {
                ContentUnavailableView(
                    "任務不可用",
                    systemImage: "exclamationmark.triangle",
                    description: Text(verbatim: "任務或 Guided Learning Package 已不存在。")
                )
            }
        }
    }

    private func guidedHeader(
        action: DailyAction,
        package: GuidedLearningPackage
    ) -> some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            HStack(spacing: NextStepSpacing.xs) {
                NextStepBetaBadge(
                    title: "AI 未使用",
                    symbol: "sparkles.slash",
                    color: NextStepPalette.aiGenerated
                )
                NextStepBetaBadge(
                    title: "原文可回溯",
                    symbol: "link",
                    color: NextStepPalette.sourceVerified
                )
            }
            Text(package.title)
                .font(NextStepTypography.pageTitle)
            HStack {
                BetaIconRow("\(package.estimatedMinutes) 分鐘", systemImage: "clock")
                BetaIconRow("入門", systemImage: "gauge.with.dots.needle.33percent")
                Text(NextStepBetaStatusText.title(for: action.status))
            }
            .font(NextStepTypography.metadata)
            .foregroundStyle(NextStepPalette.secondaryText)
            Text(package.summary)
                .font(NextStepTypography.supporting)
                .foregroundStyle(NextStepPalette.warning)
        }
    }

    private func whyToday(_ package: GuidedLearningPackage) -> some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
            BetaIconRow("為什麼是今天", systemImage: "calendar.badge.clock")
                .font(NextStepTypography.sectionTitle)
            Text(package.whyToday)
                .font(NextStepTypography.body)
        }
        .nextStepCard()
    }

    private func sourceBlock(
        action: DailyAction,
        package: GuidedLearningPackage
    ) -> some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            BetaIconRow("可信來源", systemImage: "doc.text.magnifyingglass")
                .font(NextStepTypography.sectionTitle)
                .accessibilityIdentifier("nextstep.beta.guided.source")
            if let source = model.source(for: action) {
                Text(source.displayTitle)
                    .font(NextStepTypography.body.weight(.semibold))
                Text(verbatim: "檔案 SHA-256 已驗證；這只證明檔案未被改動，不代表內容事實已獨立查證。")
                    .font(NextStepTypography.annotation)
                    .foregroundStyle(NextStepPalette.secondaryText)
                if let hash = source.contentSHA256 {
                    Text(hash)
                        .font(NextStepTypography.metadata)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                SwiftUI.Button {
                    Task { previewURL = await model.sourceURL(for: source) }
                } label: {
                    HStack {
                        BetaIconRow("開啟原始檔", systemImage: "arrow.up.forward.app")
                        Spacer(minLength: NextStepSpacing.sm)
                    }
                    .frame(
                        maxWidth: .infinity,
                        minHeight: NextStepSize.minimumTapTarget,
                        alignment: .leading
                    )
                    .contentShape(Rectangle())
                }
                .accessibilityIdentifier("nextstep.beta.guided.openSource")
                .buttonStyle(.borderedProminent)
            } else {
                BetaIconRow("原始來源目前不可用", systemImage: "link.badge.plus")
                    .foregroundStyle(NextStepPalette.warning)
            }
            if let reading = package.sourceReadings.first {
                Text(
                    verbatim: reading.anchorIDs.isEmpty
                        ? "必讀定位：第 1 頁 · 來源錨點不可用"
                        : "必讀定位：第 1 頁 · 來源錨點已保存"
                )
                    .font(NextStepTypography.metadata)
                    .foregroundStyle(NextStepPalette.secondaryText)
            }
        }
        .nextStepCard()
    }

    private func exactExtractBlock(_ package: GuidedLearningPackage) -> some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            BetaIconRow("原文節錄（非摘要）", systemImage: "quote.opening")
                .font(NextStepTypography.sectionTitle)
            ForEach(package.corePoints) { point in
                Text(point.text)
                    .font(NextStepTypography.citation)
                    .textSelection(.enabled)
                    .padding(.leading, NextStepSpacing.md)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(NextStepPalette.highlightConclusion)
                            .frame(width: 3)
                    }
            }
            Text(verbatim: "請用上方按鈕打開原始檔，確認頁面內容與節錄一致。")
                .font(NextStepTypography.annotation)
                .foregroundStyle(NextStepPalette.warning)
        }
        .nextStepCard()
    }

    @ViewBuilder
    private func quizBlock(
        action: DailyAction,
        package: GuidedLearningPackage
    ) -> some View {
        if let quiz = package.quiz {
            VStack(alignment: .leading, spacing: NextStepSpacing.md) {
                VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
                    BetaIconRow("來源核對測驗", systemImage: "checkmark.shield")
                        .font(NextStepTypography.sectionTitle)
                        .accessibilityIdentifier("nextstep.beta.guided.quiz.heading")
                    Text(verbatim: "答案只依照上方已保存的原文節錄判定；首版不使用付費 AI。")
                        .font(NextStepTypography.annotation)
                        .foregroundStyle(NextStepPalette.secondaryText)
                }

                quizStatus(action: action, quiz: quiz)

                ForEach(Array(quiz.items.enumerated()), id: \.element.id) { questionIndex, item in
                    VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
                        Text(verbatim: "第 \(questionIndex + 1) 題 · \(item.prompt)")
                            .font(NextStepTypography.body.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier(
                                "nextstep.beta.guided.quiz.question.\(questionIndex)"
                            )

                        ForEach(Array(item.options.enumerated()), id: \.element.id) {
                            optionIndex, option in
                            let isSelected = quizSelections[item.id, default: []]
                                .contains(option.id)
                            SwiftUI.Button {
                                selectQuizOption(option.id, for: item)
                            } label: {
                                HStack(alignment: .top, spacing: NextStepSpacing.sm) {
                                    Image(
                                        systemName: isSelected
                                            ? "largecircle.fill.circle"
                                            : "circle"
                                    )
                                    .foregroundStyle(
                                        isSelected
                                            ? NextStepPalette.primaryAccent
                                            : NextStepPalette.secondaryText
                                    )
                                    .padding(.top, 2)
                                    Text(option.text)
                                        .font(NextStepTypography.supporting)
                                        .foregroundStyle(NextStepPalette.primaryText)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .frame(
                                    maxWidth: .infinity,
                                    minHeight: NextStepSize.minimumTapTarget,
                                    alignment: .leading
                                )
                                .padding(.horizontal, NextStepSpacing.sm)
                                .background(
                                    isSelected
                                        ? NextStepPalette.primaryAccent.opacity(0.10)
                                        : NextStepPalette.surface
                                )
                                .clipShape(
                                    RoundedRectangle(
                                        cornerRadius: NextStepRadius.control,
                                        style: .continuous
                                    )
                                )
                                .overlay {
                                    RoundedRectangle(
                                        cornerRadius: NextStepRadius.control,
                                        style: .continuous
                                    )
                                    .stroke(
                                        isSelected
                                            ? NextStepPalette.primaryAccent
                                            : NextStepPalette.divider
                                    )
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(
                                action.status != .inProgress
                                    || model.isWorking
                                    || model.hasPassingQuizEvidence(for: actionID)
                            )
                            .accessibilityIdentifier(
                                "nextstep.beta.guided.quiz.question.\(questionIndex).option.\(optionIndex)"
                            )
                            .accessibilityValue(isSelected ? "已選取" : "未選取")
                            .accessibilityAddTraits(isSelected ? .isSelected : [])
                        }

                        if let response = displayedQuizAttempt?.responses.first(where: {
                            $0.quizItemID == item.id
                        }) {
                            HStack(alignment: .top, spacing: NextStepSpacing.xs) {
                                Image(
                                    systemName: response.scoreFraction == 1
                                        ? "checkmark.circle.fill"
                                        : "arrow.uturn.backward.circle.fill"
                                )
                                .foregroundStyle(
                                    response.scoreFraction == 1
                                        ? NextStepPalette.success
                                        : NextStepPalette.warning
                                )
                                Text(response.feedback)
                                    .font(NextStepTypography.annotation)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .accessibilityIdentifier(
                                "nextstep.beta.guided.quiz.feedback.\(questionIndex)"
                            )
                        }
                    }
                    .padding(.top, questionIndex == 0 ? 0 : NextStepSpacing.xs)
                }

                if action.status == .inProgress,
                   model.hasPassingQuizEvidence(for: actionID) == false {
                    BetaActionControl(
                        displayedQuizAttempt == nil ? "提交來源核對" : "再次提交來源核對",
                        systemImage: "checkmark.shield"
                    ) {
                        Task {
                            await model.submitQuiz(
                                for: actionID,
                                selections: quizSelections
                            )
                            isEditingAfterQuizAttempt = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isWorking || hasAnsweredEveryQuestion(quiz) == false)
                    .accessibilityIdentifier("nextstep.beta.guided.quiz.submit")

                    if displayedQuizAttempt?.passed == false {
                        BetaActionControl("清除答案重新作答", systemImage: "arrow.counterclockwise") {
                            quizSelections = [:]
                            isEditingAfterQuizAttempt = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("nextstep.beta.guided.quiz.retry")
                    }
                }
            }
            .nextStepCard()
        }
    }

    @ViewBuilder
    private func quizStatus(action: DailyAction, quiz: Quiz) -> some View {
        if model.hasPassingQuizEvidence(for: actionID) {
            BetaIconRow("已通過，完成證據可跨裝置同步", systemImage: "checkmark.seal.fill")
                .foregroundStyle(NextStepPalette.success)
                .accessibilityIdentifier("nextstep.beta.guided.quiz.passed")
        } else {
            switch model.quizSubmissionState(for: quiz.metadata.id) {
            case .submitting:
                HStack(spacing: NextStepSpacing.xs) {
                    ProgressView()
                    Text(verbatim: "正在核對答案…")
                }
                .font(NextStepTypography.supporting)
                .accessibilityIdentifier("nextstep.beta.guided.quiz.submitting")
            case .result(let result) where result.passed == false:
                BetaIconRow(
                    "答對 \(result.correctCount)／\(result.totalCount)，請核對原文後再試",
                    systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                )
                .foregroundStyle(NextStepPalette.warning)
                .accessibilityIdentifier("nextstep.beta.guided.quiz.needsRetry")
            default:
                if let attempt = displayedQuizAttempt, attempt.passed == false {
                    BetaIconRow(
                        "答對 \(attempt.correctCount)／\(attempt.totalCount)，請核對原文後再試",
                        systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                    )
                    .foregroundStyle(NextStepPalette.warning)
                    .accessibilityIdentifier("nextstep.beta.guided.quiz.needsRetry")
                } else {
                    Text(
                        action.status == .inProgress
                            ? "請完成所有題目；全部答對後才能提交最終產出。"
                            : "開始任務後即可作答。"
                    )
                    .font(NextStepTypography.annotation)
                    .foregroundStyle(NextStepPalette.secondaryText)
                    .accessibilityIdentifier("nextstep.beta.guided.quiz.status")
                }
            }
        }
    }

    private var displayedQuizAttempt: NextStepBetaQuizAttemptSummary? {
        guard isEditingAfterQuizAttempt == false else { return nil }
        guard let action = model.action(id: actionID),
              let quizID = model.package(for: action)?.quiz?.metadata.id else {
            return nil
        }
        if case .result(let attempt) = model.quizSubmissionState(for: quizID) {
            return attempt
        }
        return model.latestQuizAttempt(for: actionID)
    }

    private func selectQuizOption(_ optionID: UUID, for item: QuizItem) {
        if displayedQuizAttempt?.passed == false {
            isEditingAfterQuizAttempt = true
        }
        switch item.kind {
        case .multipleChoice:
            quizSelections[item.id] = [optionID]
        case .multipleSelect:
            var values = quizSelections[item.id, default: []]
            if values.contains(optionID) {
                values.remove(optionID)
            } else {
                values.insert(optionID)
            }
            quizSelections[item.id] = values
        case .shortAnswer, .numeric, .application:
            break
        }
    }

    private func hasAnsweredEveryQuestion(_ quiz: Quiz) -> Bool {
        quiz.items.allSatisfy { quizSelections[$0.id]?.isEmpty == false }
    }

    private func outputBlock(_ package: GuidedLearningPackage) -> some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            BetaIconRow("完成產出與標準", systemImage: "checklist")
                .font(NextStepTypography.sectionTitle)
            Text(package.requiredOutput.title)
                .font(NextStepTypography.body.weight(.semibold))
            ForEach(package.completionCriteria) { criterion in
                BetaIconRow(criterion.title, systemImage: "circle")
                    .font(NextStepTypography.supporting)
            }
            Text(
                verbatim: "來源核對通過後會先保存可重播的測驗證據；按下完成會再建立 User Attestation，並更新進度快照。"
            )
                .font(NextStepTypography.annotation)
                .foregroundStyle(NextStepPalette.secondaryText)
        }
        .nextStepCard()
    }

    @ViewBuilder
    private func executionControls(action: DailyAction) -> some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            if model.isReplanning {
                HStack {
                    ProgressView()
                    Text(verbatim: "正在重新評估後續計畫…")
                }
                .font(NextStepTypography.supporting)
            }
            switch action.status {
            case .completed:
                VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
                    BetaIconRow("已完成並保存證據", systemImage: "checkmark.seal.fill")
                        .font(NextStepTypography.sectionTitle)
                        .foregroundStyle(NextStepPalette.success)
                    ForEach(
                        model.completionEvidence(for: actionID),
                        id: \.metadata.id
                    ) { evidence in
                        if evidence.kind == .quizResult,
                           evidence.hasReplayableQuizResult {
                            BetaIconRow("來源核對測驗已通過", systemImage: "checkmark.shield.fill")
                                .font(NextStepTypography.supporting)
                                .foregroundStyle(NextStepPalette.sourceVerified)
                        } else if evidence.kind == .quizResult {
                            BetaIconRow(
                                "舊版測驗紀錄未驗證，不計入完成",
                                systemImage: "exclamationmark.shield"
                            )
                            .font(NextStepTypography.supporting)
                            .foregroundStyle(NextStepPalette.warning)
                            Text(evidence.value)
                                .font(NextStepTypography.metadata)
                                .foregroundStyle(NextStepPalette.secondaryText)
                        } else {
                            Text(evidence.value)
                                .font(NextStepTypography.supporting)
                        }
                        Text(evidence.capturedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(NextStepTypography.metadata)
                            .foregroundStyle(NextStepPalette.secondaryText)
                    }
                }
                .accessibilityIdentifier("nextstep.beta.guided.completedEvidence")
            case .inProgress:
                VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
                    Text(verbatim: "完成證據：每行寫一個從原文直接確認的重點")
                        .font(NextStepTypography.supporting.weight(.semibold))
                    ZStack(alignment: .topLeading) {
                        if completionDraft.isEmpty {
                            Text(verbatim: "重點一\n重點二\n重點三")
                                .foregroundStyle(NextStepPalette.secondaryText.opacity(0.65))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $completionDraft)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 140)
                            .focused($isCompletionFocused)
                            .accessibilityIdentifier("nextstep.beta.guided.completionDraft")
                    }
                    .padding(NextStepSpacing.xs)
                    .background(NextStepPalette.surface)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: NextStepRadius.control,
                            style: .continuous
                        )
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: NextStepRadius.control,
                            style: .continuous
                        )
                        .stroke(NextStepPalette.divider)
                    }
                }
                BetaActionControl("建立完成證據並完成", systemImage: "checkmark.circle") {
                    Task {
                        await model.completeAction(
                            actionID,
                            evidenceText: completionDraft
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.isWorking
                        || completionPointCount < 3
                        || model.hasPassingQuizEvidence(for: actionID) == false
                )
                .accessibilityIdentifier("nextstep.beta.guided.complete")
            default:
                BetaActionControl("開始這一步", systemImage: "play.fill") {
                    Task { await model.startAction(actionID) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
                .accessibilityIdentifier("nextstep.beta.guided.start")
            }
            if action.status != .completed {
                BetaActionControl("今天無法完成，延後並重新安排", systemImage: "clock.arrow.circlepath") {
                    Task { await model.deferAndReplan(actionID) }
                }
                .buttonStyle(.bordered)
                .disabled(model.isWorking)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var completionPointCount: Int {
        completionDraft
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
            .count
    }
}

private struct NextStepBetaGoalsView: View {
    let model: NextStepBetaModel
    @State private var isGoalSheetPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NextStepSpacing.lg) {
                if let workspace = model.workspace, workspace.ultimateGoals.isEmpty == false {
                    ForEach(workspace.ultimateGoals, id: \.metadata.id) { ultimate in
                        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
                            Text(verbatim: "Ultimate Goal")
                                .font(NextStepTypography.annotation)
                                .foregroundStyle(NextStepPalette.primaryAccent)
                            Text(ultimate.title)
                                .font(NextStepTypography.pageTitle)
                            if let target = ultimate.targetDay {
                                BetaIconRow(
                                    "硬期限 \(target.value.description)",
                                    systemImage: "lock.fill"
                                )
                                .font(NextStepTypography.metadata)
                                .foregroundStyle(NextStepPalette.warning)
                            }
                            ForEach(
                                workspace.goals.filter { $0.ultimateGoalID == ultimate.metadata.id },
                                id: \.metadata.id
                            ) { goal in
                                Divider()
                                BetaIconRow(goal.title, systemImage: "scope")
                                    .font(NextStepTypography.sectionTitle)
                                ForEach(
                                    workspace.milestones.filter { $0.goalID == goal.metadata.id },
                                    id: \.metadata.id
                                ) { milestone in
                                    HStack(alignment: .top) {
                                        Image(systemName: "circle.dotted")
                                        VStack(alignment: .leading) {
                                            Text(milestone.title)
                                                .font(NextStepTypography.body.weight(.semibold))
                                            Text(milestone.outcome)
                                                .font(NextStepTypography.supporting)
                                                .foregroundStyle(NextStepPalette.secondaryText)
                                        }
                                    }
                                }
                            }
                        }
                        .nextStepCard()
                    }
                } else {
                    NextStepBetaEmptyCard(
                        symbol: "scope",
                        title: "尚未設定目標",
                        detail: "Today 會以這條目標階層安排第一個完整閉環。",
                        actionTitle: "建立目標"
                    ) { isGoalSheetPresented = true }
                }
            }
            .frame(maxWidth: NextStepSize.readingColumnMaximum, alignment: .leading)
            .padding(NextStepSpacing.lg)
            .frame(maxWidth: .infinity)
        }
        .background(NextStepPalette.appBackground)
        .nextStepBetaNavigationTitle("目標與里程碑")
        .accessibilityIdentifier("nextstep.beta.screen.goals")
        .sheet(isPresented: $isGoalSheetPresented) {
            NextStepBetaGoalSetupSheet(model: model)
        }
    }
}

private struct NextStepBetaSourcesView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let model: NextStepBetaModel
    @State private var isImporterPresented = false
    @State private var isSyncFolderPickerPresented = false
    @State private var previewURL: URL?
    @State private var selectedCandidateID: UUID?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if usesInspectorLayout(availableWidth: geometry.size.width) {
                    HStack(spacing: 0) {
                        sourceList(usesNavigationLinks: false)
                            .frame(width: 320)
                        Divider()
                        if let candidateID = effectiveSelectedCandidateID {
                            NextStepBetaSourceFactReviewView(
                                model: model,
                                candidateID: candidateID
                            )
                        } else {
                            NextStepBetaSourceInspectorEmptyView(
                                pendingCount: model.pendingSourceFacts.count
                            )
                        }
                    }
                } else {
                    sourceList(usesNavigationLinks: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(NextStepPalette.appBackground)
        .nextStepBetaNavigationTitle("來源")
        .onAppear { reconcileSelectedCandidate() }
        .onChange(of: model.pendingSourceFacts.map(\.id)) { _, _ in
            reconcileSelectedCandidate()
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                BetaActionControl("匯入", systemImage: "plus") { isImporterPresented = true }
                    .disabled(model.hasGoal == false)
            }
        }
        .sheet(isPresented: $isImporterPresented) {
            DocumentPicker(mode: .importableDocuments) { urls in
                Task { await model.importSources(urls) }
            }
        }
        .fileImporter(
            isPresented: $isSyncFolderPickerPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let folderURL = urls.first else { return }
                Task { await model.connectSyncFolder(folderURL) }
            case .failure(let error):
                model.reportSyncPickerError(error)
            }
        }
        .quickLookPreview($previewURL)
    }

    private func usesInspectorLayout(availableWidth: CGFloat) -> Bool {
        horizontalSizeClass == .regular
            && dynamicTypeSize.isAccessibilitySize == false
            && availableWidth >= 720
    }

    private func reconcileSelectedCandidate() {
        // Preserve a resolved candidate while its detail shows the confirmation
        // result. A later non-empty pending set can safely select a live item.
        guard model.pendingSourceFacts.isEmpty == false else { return }
        if let selectedCandidateID,
           model.pendingSourceFacts.contains(where: { $0.id == selectedCandidateID }) {
            return
        }
        selectedCandidateID = model.pendingSourceFacts.first?.id
    }

    private var effectiveSelectedCandidateID: UUID? {
        selectedCandidateID ?? model.pendingSourceFacts.first?.id
    }

    private func sourceList(usesNavigationLinks: Bool) -> some View {
        List {
            if model.pendingSourceFacts.isEmpty == false {
                Section(NextStepBetaCopy.verbatim("待確認日期與期限")) {
                    ForEach(model.pendingSourceFacts) { pending in
                        candidateLink(pending, usesNavigationLinks: usesNavigationLinks)
                    }
                    Text(verbatim: "確認前不會修改任何期限或計畫。")
                        .font(NextStepTypography.annotation)
                        .foregroundStyle(NextStepPalette.secondaryText)
                        .accessibilityIdentifier("nextstep.beta.grounding.pendingCount")
                        .accessibilityValue(
                            Text(verbatim: String(model.pendingSourceFacts.count))
                        )
                }
            }
            Section(NextStepBetaCopy.verbatim("跨裝置同步")) {
                NextStepBetaSyncBlock(
                    model: model,
                    chooseFolder: { isSyncFolderPickerPresented = true }
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section {
                NextStepBetaOfflineBlock()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if model.sourceDocuments.isEmpty {
                ContentUnavailableView(
                    "尚無來源",
                    systemImage: "doc.badge.plus",
                    description: Text(verbatim: "先建立目標，再匯入 PDF 或圖片。")
                )
                .listRowBackground(Color.clear)
            } else {
                Section(NextStepBetaCopy.verbatim("使用者提供的原始檔")) {
                    ForEach(model.sourceDocuments, id: \.metadata.id) { source in
                        Button {
                            Task { previewURL = await model.sourceURL(for: source) }
                        } label: {
                            VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
                                HStack {
                                    BetaIconRow(source.displayTitle, systemImage: "doc.text")
                                    Spacer()
                                    Image(systemName: "arrow.up.forward.app")
                                }
                                Text(source.parserVersion ?? "尚未抽取可讀文字")
                                    .font(NextStepTypography.metadata)
                                    .foregroundStyle(
                                        source.parserVersion == nil
                                            ? NextStepPalette.warning
                                            : NextStepPalette.sourceVerified
                                    )
                                Text(verbatim: "檔案雜湊已驗證 · 內容事實需由使用者核對")
                                    .font(NextStepTypography.annotation)
                                    .foregroundStyle(NextStepPalette.secondaryText)
                            }
                            .padding(.vertical, NextStepSpacing.xs)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(NextStepPalette.appBackground)
        // Scope the marker to the concrete list. A split-container identifier
        // propagates into the inspector and replaces its control IDs on iOS 26.
        .accessibilityIdentifier("nextstep.beta.screen.sources")
    }

    @ViewBuilder
    private func candidateLink(
        _ pending: NextStepBetaPendingSourceFact,
        usesNavigationLinks: Bool
    ) -> some View {
        if usesNavigationLinks {
            NavigationLink {
                NextStepBetaSourceFactReviewView(model: model, candidateID: pending.id)
            } label: {
                NextStepBetaPendingSourceFactRow(
                    pending: pending,
                    sourceTitle: model.source(for: pending)?.displayTitle,
                    isSelected: false
                )
            }
        } else {
            Button {
                selectedCandidateID = pending.id
            } label: {
                NextStepBetaPendingSourceFactRow(
                    pending: pending,
                    sourceTitle: model.source(for: pending)?.displayTitle,
                    isSelected: effectiveSelectedCandidateID == pending.id
                )
            }
            .buttonStyle(.plain)
        }
    }
}

private struct NextStepBetaPendingSourceFactCard: View {
    let pending: NextStepBetaPendingSourceFact
    let totalCount: Int
    let sourceTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            HStack {
                NextStepBetaBadge(
                    title: pending.candidate.kind == .deadline ? "待確認期限" : "待確認日期",
                    symbol: "exclamationmark.magnifyingglass",
                    color: NextStepPalette.warning
                )
                Spacer()
                Text(verbatim: "\(totalCount) 筆")
                    .font(NextStepTypography.metadata)
                    .foregroundStyle(NextStepPalette.secondaryText)
            }
            Text(pending.candidate.value)
                .font(NextStepTypography.sectionTitle)
                .foregroundStyle(NextStepPalette.primaryText)
            if let sourceTitle {
                BetaIconRow(sourceTitle, systemImage: "doc.text")
                    .font(NextStepTypography.supporting)
                    .foregroundStyle(NextStepPalette.secondaryText)
            }
            Text(verbatim: "開啟原文與計畫差異；確認前不會修改任何期限或排程。")
                .font(NextStepTypography.annotation)
                .foregroundStyle(NextStepPalette.secondaryText)
        }
        .nextStepCard(state: .aiUncertain)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nextstep.beta.grounding.candidate.\(pending.id.uuidString)")
        .accessibilityHint("開啟可追溯的來源事實核對")
    }
}

private struct NextStepBetaPendingSourceFactRow: View {
    let pending: NextStepBetaPendingSourceFact
    let sourceTitle: String?
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
            HStack {
                BetaIconRow(
                    pending.candidate.kind == .deadline ? "期限候選" : "日期候選",
                    systemImage: "calendar.badge.exclamationmark"
                )
                .font(NextStepTypography.supporting.weight(.semibold))
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(NextStepPalette.primaryAccent)
                }
            }
            Text(pending.candidate.value)
                .font(NextStepTypography.body.weight(.semibold))
            if let sourceTitle {
                Text(sourceTitle)
                    .font(NextStepTypography.metadata)
                    .foregroundStyle(NextStepPalette.secondaryText)
                    .lineLimit(2)
            }
            Text(
                verbatim: "抽取信心 \(Int((pending.candidate.confidence * 100).rounded()))%"
            )
                .font(NextStepTypography.annotation)
                .foregroundStyle(
                    pending.candidate.confidence < 0.7
                        ? NextStepPalette.warning
                        : NextStepPalette.sourceVerified
                )
        }
        .padding(.vertical, NextStepSpacing.xs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("nextstep.beta.grounding.candidate.\(pending.id.uuidString)")
        .accessibilityValue(isSelected ? "已選取" : "待確認")
    }
}

private struct NextStepBetaSourceInspectorEmptyView: View {
    let pendingCount: Int

    var body: some View {
        ContentUnavailableView(
            pendingCount == 0 ? "來源已全部核對" : "選取一筆待確認內容",
            systemImage: pendingCount == 0 ? "checkmark.shield" : "doc.text.magnifyingglass",
            description: Text(
                verbatim: pendingCount == 0
                    ? "已完成的核對會保留來源、證據與使用者決策紀錄。"
                    : "右側會顯示原文、事實差異與重新規劃差異。"
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NextStepPalette.appBackground)
    }
}

private struct NextStepBetaSourceFactReviewView: View {
    let model: NextStepBetaModel
    let candidateID: UUID
    @State private var previewURL: URL?
    @State private var isRejectionSheetPresented = false
    @State private var rejectionReason = ""
    @State private var didConfirm = false
    @State private var didReject = false

    var body: some View {
        Group {
            if let pending = model.pendingSourceFact(id: candidateID) {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: NextStepSpacing.lg) {
                            reviewHeader(pending)
                            sourcePassage(pending)
                            if let preview = matchingPreview {
                                factDiff(preview)
                                replanDiff(preview)
                            } else if model.isWorking {
                                HStack(spacing: NextStepSpacing.sm) {
                                    ProgressView()
                                    Text(verbatim: "正在重新驗證原始檔並建立差異預覽…")
                                }
                                .font(NextStepTypography.supporting)
                                .accessibilityIdentifier("nextstep.beta.grounding.working")
                                .nextStepCard()
                            } else {
                                sourceUnavailableBlock
                            }
                            NextStepBetaOfflineBlock()
                            Text(verbatim: "按下確認前，來源事實、硬期限與計畫都不會被套用。")
                                .font(NextStepTypography.supporting.weight(.semibold))
                                .foregroundStyle(NextStepPalette.warning)
                                .nextStepCard(state: .aiUncertain)
                        }
                        .frame(maxWidth: NextStepSize.readingColumnMaximum, alignment: .leading)
                        .padding(NextStepSpacing.lg)
                        .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("nextstep.beta.grounding.screen.review")

                    Divider()
                    reviewActions(pending)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    didConfirm ? "已確認並保存" : didReject ? "已拒絕候選" : "核對項目已更新",
                    systemImage: didConfirm
                        ? "checkmark.seal.fill"
                        : didReject ? "xmark.circle" : "arrow.triangle.2.circlepath",
                    description: Text(
                        verbatim: didConfirm
                            ? "來源證據、使用者確認與重新規劃已在同一次原子寫入中保存。"
                            : didReject
                                ? "目標期限與排程沒有被這筆候選修改。"
                                : "這筆候選已由同步或其他流程更新；請返回清單查看目前狀態。"
                    )
                )
                .accessibilityIdentifier(
                    didConfirm
                        ? "nextstep.beta.grounding.confirmed"
                        : didReject
                            ? "nextstep.beta.grounding.rejected"
                            : "nextstep.beta.grounding.updated"
                )
            }
        }
        .background(NextStepPalette.appBackground)
        .nextStepBetaNavigationTitle("來源事實核對")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: candidateID) {
            guard model.pendingSourceFact(id: candidateID) != nil,
                  model.sourceFactReviewPreview?.id != candidateID else { return }
            await model.prepareSourceFactReview(candidateID)
        }
        .sheet(isPresented: $isRejectionSheetPresented) {
            rejectionSheet
        }
        .quickLookPreview($previewURL)
    }

    private var matchingPreview: NextStepBetaSourceFactReviewPreview? {
        guard model.sourceFactReviewPreview?.id == candidateID else { return nil }
        return model.sourceFactReviewPreview
    }

    private func reviewHeader(_ pending: NextStepBetaPendingSourceFact) -> some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            HStack(spacing: NextStepSpacing.xs) {
                NextStepBetaBadge(
                    title: "裝置端規則抽取",
                    symbol: "gearshape.2",
                    color: NextStepPalette.primaryAccent
                )
                NextStepBetaBadge(
                    title: "來源已驗證",
                    symbol: "checkmark.shield",
                    color: NextStepPalette.sourceVerified
                )
            }
            Text(pending.candidate.kind == .deadline ? "期限候選" : "日期候選")
                .font(NextStepTypography.annotation)
                .foregroundStyle(NextStepPalette.secondaryText)
            Text(pending.candidate.value)
                .font(NextStepTypography.pageTitle)
                .foregroundStyle(NextStepPalette.primaryText)
                .accessibilityIdentifier("nextstep.beta.grounding.candidateValue")
            if let source = model.source(for: pending) {
                Text(source.displayTitle)
                    .font(NextStepTypography.sectionTitle)
                    .accessibilityIdentifier("nextstep.beta.grounding.sourceTitle")
            }
            HStack {
                BetaIconRow("第 \(pageNumber(pending)) 頁", systemImage: "doc.text")
                    .accessibilityIdentifier("nextstep.beta.grounding.location")
                Spacer()
                Text(
                    verbatim: "抽取信心 \(Int((pending.candidate.confidence * 100).rounded()))%"
                )
                    .accessibilityIdentifier("nextstep.beta.grounding.confidence")
            }
            .font(NextStepTypography.metadata)
            .foregroundStyle(
                pending.candidate.confidence < 0.7
                    ? NextStepPalette.warning
                    : NextStepPalette.secondaryText
            )
        }
    }

    private func sourcePassage(_ pending: NextStepBetaPendingSourceFact) -> some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            BetaIconRow("原始定位段落", systemImage: "quote.opening")
                .font(NextStepTypography.sectionTitle)
            if let block = anchoredBlock(for: pending) {
                Text(highlighted(block.text, pending: pending, anchorID: block.anchorID))
                    .font(NextStepTypography.body)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("nextstep.beta.grounding.passage")
            } else {
                Text(verbatim: "保存的段落定位目前不可用。")
                    .foregroundStyle(NextStepPalette.error)
            }
            if let source = model.source(for: pending) {
                BetaActionControl("開啟原始檔", systemImage: "arrow.up.forward.app") {
                    Task { previewURL = await model.sourceURL(for: source) }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("nextstep.beta.grounding.openSource")
            }
        }
        .nextStepCard()
    }

    private func factDiff(_ preview: NextStepBetaSourceFactReviewPreview) -> some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            BetaIconRow("事實差異", systemImage: "arrow.left.arrow.right")
                .font(NextStepTypography.sectionTitle)
            if preview.diff.kind == .deadline {
                ForEach(preview.diff.deadlineChanges) { change in
                    deadlineDiffRow(change)
                }
                Text(verbatim: "只會更新上列目標層級與其未完成行動；其他長期期限保持不變。")
                    .font(NextStepTypography.annotation)
                    .foregroundStyle(NextStepPalette.secondaryText)
            } else {
                Text(verbatim: "這是一般日期事實；確認後會保存來源與證據，但不修改排程。")
                    .font(NextStepTypography.supporting)
            }
            if preview.diff.kind != .deadline {
                deadlineValueTransition(
                    previousDay: preview.diff.previousDay,
                    proposedDay: preview.diff.proposedDay
                )
            }
        }
        .nextStepCard()
        .accessibilityIdentifier("nextstep.beta.grounding.factDiff")
    }

    private func deadlineDiffRow(_ change: NextStepBetaDeadlineChange) -> some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(deadlineOwnerTitle(change.owner))
                    .font(NextStepTypography.metadata.weight(.semibold))
                Spacer()
                Text(change.title)
                    .font(NextStepTypography.supporting)
                    .multilineTextAlignment(.trailing)
            }
            deadlineValueTransition(
                previousDay: change.previousDay,
                proposedDay: change.proposedDay
            )
        }
        .accessibilityIdentifier("nextstep.beta.grounding.factDiff.row.\(change.id)")
    }

    private func deadlineValueTransition(
        previousDay: LocalDay?,
        proposedDay: LocalDay
    ) -> some View {
        HStack(alignment: .top, spacing: NextStepSpacing.md) {
            Text(previousDay?.description ?? "尚無")
                .font(NextStepTypography.body.weight(.semibold))
            Image(systemName: "arrow.right")
                .foregroundStyle(NextStepPalette.primaryAccent)
            VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
                Text(proposedDay.description)
                    .font(NextStepTypography.body.weight(.semibold))
                Text(verbatim: "使用者確認 · 不可變 · 證據已連結")
                    .font(NextStepTypography.metadata)
                    .foregroundStyle(NextStepPalette.sourceVerified)
            }
        }
    }

    private func deadlineOwnerTitle(_ owner: NextStepBetaDeadlineChangeOwner) -> String {
        switch owner {
        case .ultimateGoal: "Ultimate Goal"
        case .goal: "Goal"
        case .milestone: "Milestone"
        case .dailyAction: "Daily Action"
        }
    }

    private func replanDiff(_ preview: NextStepBetaSourceFactReviewPreview) -> some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            BetaIconRow("重新規劃差異", systemImage: "calendar.badge.clock")
                .font(NextStepTypography.sectionTitle)
            if let proposal = preview.replanProposal {
                let materialChanges = proposal.changes.filter { $0.kind != .preserve }
                let preservedCount = proposal.changes.count - materialChanges.count
                if materialChanges.isEmpty {
                    Text(verbatim: "Today 與後續排程不變。")
                        .font(NextStepTypography.supporting)
                } else {
                    ForEach(Array(materialChanges.enumerated()), id: \.offset) { _, change in
                        VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
                            Text(changeTitle(change))
                                .font(NextStepTypography.supporting.weight(.semibold))
                            Text(change.explanation)
                                .font(NextStepTypography.annotation)
                                .foregroundStyle(NextStepPalette.secondaryText)
                        }
                        .accessibilityIdentifier(
                            "nextstep.beta.grounding.replanDiff.row.\(change.kind.rawValue).\(change.actionID.description)"
                        )
                    }
                }
                if preservedCount > 0 {
                    Text(verbatim: "\(preservedCount) 個行動維持原安排")
                        .font(NextStepTypography.metadata)
                        .foregroundStyle(NextStepPalette.secondaryText)
                }
                ForEach(proposal.proposedDecision.risks) { risk in
                    BetaIconRow(risk.message, systemImage: "exclamationmark.triangle")
                        .font(NextStepTypography.metadata)
                        .foregroundStyle(NextStepPalette.warning)
                }
            } else {
                Text(verbatim: "一般日期事實不會觸發重新規劃。")
                    .font(NextStepTypography.supporting)
            }
        }
        .nextStepCard()
        .accessibilityIdentifier("nextstep.beta.grounding.replanDiff")
    }

    private var sourceUnavailableBlock: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            BetaIconRow("原始來源目前無法重新驗證", systemImage: "exclamationmark.shield")
                .font(NextStepTypography.sectionTitle)
                .foregroundStyle(NextStepPalette.warning)
            Text(verbatim: "保存的原文仍可查看，但確認已停用。你仍可拒絕候選，或重新匯入來源後再試。")
                .font(NextStepTypography.supporting)
        }
        .nextStepCard(state: .sourceUnavailable)
        .accessibilityIdentifier("nextstep.beta.grounding.sourceUnavailable")
    }

    private func reviewActions(_ pending: NextStepBetaPendingSourceFact) -> some View {
        VStack(spacing: NextStepSpacing.sm) {
            BetaActionControl(
                pending.candidate.kind == .deadline ? "確認期限並套用計畫" : "確認並保存日期事實",
                systemImage: "checkmark.seal"
            ) {
                guard let preview = matchingPreview else { return }
                Task {
                    await model.acceptSourceFactReview(preview)
                    didConfirm = model.pendingSourceFact(id: candidateID) == nil
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, minHeight: NextStepSize.minimumTapTarget)
            .disabled(matchingPreview == nil || model.isWorking)
            .accessibilityIdentifier("nextstep.beta.grounding.accept")

            BetaActionControl("拒絕候選", systemImage: "xmark.circle") {
                isRejectionSheetPresented = true
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, minHeight: NextStepSize.minimumTapTarget)
            .disabled(model.isWorking)
            .accessibilityIdentifier("nextstep.beta.grounding.reject")
        }
        .padding(.horizontal, NextStepSpacing.lg)
        .padding(.vertical, NextStepSpacing.sm)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private var rejectionSheet: some View {
        NavigationStack {
            Form {
                Section(NextStepBetaCopy.verbatim("拒絕理由")) {
                    TextEditor(text: $rejectionReason)
                        .frame(minHeight: 120)
                        .accessibilityIdentifier("nextstep.beta.grounding.rejectionReason")
                    Text(verbatim: "拒絕只保存稽核紀錄，不會修改期限或計畫。")
                        .font(NextStepTypography.annotation)
                        .foregroundStyle(NextStepPalette.secondaryText)
                }
            }
            .nextStepBetaNavigationTitle("拒絕候選")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SwiftUI.Button {
                        isRejectionSheetPresented = false
                    } label: {
                        Text(verbatim: "取消")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SwiftUI.Button {
                        let reason = rejectionReason
                        Task {
                            await model.rejectSourceFact(candidateID, reason: reason)
                            didReject = model.pendingSourceFact(id: candidateID) == nil
                            isRejectionSheetPresented = false
                        }
                    } label: {
                        Text(verbatim: "確認拒絕")
                    }
                    .disabled(rejectionReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("nextstep.beta.grounding.reject.confirm")
                }
            }
        }
    }

    private func pageNumber(_ pending: NextStepBetaPendingSourceFact) -> Int {
        let anchorIDs = Set(pending.candidate.anchorIDs)
        return (pending.batch.parseResult.pages.first { page in
            page.blocks.contains { anchorIDs.contains($0.anchorID) }
        }?.pageIndex ?? 0) + 1
    }

    private func anchoredBlock(
        for pending: NextStepBetaPendingSourceFact
    ) -> DocumentTextBlock? {
        let occurrenceAnchorIDs = Set(pending.candidate.occurrences.map(\.anchorID))
        return pending.batch.parseResult.pages
            .flatMap(\.blocks)
            .first { occurrenceAnchorIDs.contains($0.anchorID) }
    }

    private func highlighted(
        _ passage: String,
        pending: NextStepBetaPendingSourceFact,
        anchorID: SourceAnchorID
    ) -> AttributedString {
        var result = AttributedString("")
        for segment in nextStepBetaGroundedPassageSegments(
            passage: passage,
            occurrences: pending.candidate.occurrences,
            anchorID: anchorID
        ) {
            var attributedSegment = AttributedString(segment.text)
            if segment.isHighlighted {
                attributedSegment.backgroundColor =
                    NextStepPalette.highlightConclusion.opacity(0.62)
            }
            result.append(attributedSegment)
        }
        return result
    }

    private func changeTitle(_ change: PlanChange) -> String {
        let dayText = change.toDay?.description ?? change.fromDay?.description ?? "未排入"
        switch change.kind {
        case .add: return "新增到 \(dayText)"
        case .move: return "移動到 \(dayText)"
        case .remove: return "從計畫移除"
        case .preserve: return "維持 \(dayText)"
        case .split: return "拆分行動"
        }
    }
}

private struct NextStepBetaProgressView: View {
    let model: NextStepBetaModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NextStepSpacing.lg) {
                if let workspace = model.workspace,
                   let ultimate = workspace.ultimateGoals.first {
                    let snapshot = workspace.progressSnapshots.last
                    let fraction = snapshot?.ultimateGoalProgress[ultimate.metadata.id] ?? 0
                    VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
                        Text(ultimate.title)
                            .font(NextStepTypography.pageTitle)
                        ProgressView(value: fraction)
                            .tint(NextStepPalette.success)
                        Text(verbatim: "\(Int((fraction * 100).rounded()))%")
                            .font(NextStepTypography.metadata)
                            .accessibilityIdentifier("nextstep.beta.progress.percentage")
                        Text(verbatim: "完成任務後才會新增 ProgressSnapshot；漂亮圖表不會取代完成證據。")
                            .font(NextStepTypography.supporting)
                            .foregroundStyle(NextStepPalette.secondaryText)
                    }
                    .nextStepCard()

                    if let snapshot {
                        HStack {
                            metric("已完成", value: "\(snapshot.completedActionCount)")
                            metric("全部行動", value: "\(snapshot.totalActionCount)")
                            metric("計畫版本", value: "\(snapshot.planRevision)")
                        }
                        .nextStepCard()
                    } else {
                        ContentUnavailableView(
                            "尚無進度快照",
                            systemImage: "chart.line.uptrend.xyaxis",
                            description: Text(verbatim: "完成第一個 Guided Task 後會自動建立。")
                        )
                    }
                } else {
                    ContentUnavailableView(
                        "尚無目標進度",
                        systemImage: "scope",
                        description: Text(verbatim: "先從 Today 建立最終目標。")
                    )
                }
            }
            .frame(maxWidth: NextStepSize.readingColumnMaximum, alignment: .leading)
            .padding(NextStepSpacing.lg)
            .frame(maxWidth: .infinity)
        }
        .background(NextStepPalette.appBackground)
        .nextStepBetaNavigationTitle("進度")
        .accessibilityIdentifier("nextstep.beta.screen.progress")
    }

    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(NextStepTypography.sectionTitle)
            Text(title)
                .font(NextStepTypography.annotation)
                .foregroundStyle(NextStepPalette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NextStepBetaGoalSetupSheet: View {
    let model: NextStepBetaModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var deadline = Calendar.current.date(
        byAdding: .month,
        value: 3,
        to: Date()
    ) ?? Date()
    @State private var dailyMinutes = 35

    var body: some View {
        NavigationStack {
            Form {
                Section(NextStepBetaCopy.verbatim("最終目標")) {
                    TextField(
                        NextStepBetaCopy.verbatim("例如：完成本學期研究計畫"),
                        text: $title,
                        axis: .vertical
                    )
                    DatePicker(
                        NextStepBetaCopy.verbatim("硬期限"),
                        selection: $deadline,
                        in: Calendar.current.startOfDay(for: Date())...,
                        displayedComponents: .date
                    )
                    Stepper(
                        "每天可用 \(dailyMinutes) 分鐘",
                        value: $dailyMinutes,
                        in: 5...240,
                        step: 5
                    )
                }
                Section {
                    BetaIconRow("期限會標記為使用者確認且不可變", systemImage: "lock.fill")
                    BetaIconRow("規劃完全在裝置端執行", systemImage: "iphone.and.arrow.forward")
                } footer: {
                    Text(verbatim: "建立後匯入一份來源，系統才會產生第一個可追溯的 Guided Task。")
                }
            }
            .nextStepBetaNavigationTitle("建立第一條目標路徑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    BetaActionControl("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    BetaActionControl("建立") {
                        Task {
                            if await model.createGoal(
                                title: title,
                                deadline: deadline,
                                dailyMinutes: dailyMinutes
                            ) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(
                        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || model.isWorking
                    )
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct NextStepBetaNotesLibraryBridge: View {
    let onOpen: () -> Void

    var body: some View {
        VStack(spacing: NextStepSpacing.lg) {
            Image(systemName: "books.vertical")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(NextStepPalette.primaryAccent)
            Text(verbatim: "既有 Notes 筆記庫")
                .font(NextStepTypography.pageTitle)
            Text(verbatim: "筆記是 NextStep 的重要輸入來源；此入口保留給主 App 整合既有 Library。")
                .font(NextStepTypography.body)
                .foregroundStyle(NextStepPalette.secondaryText)
                .multilineTextAlignment(.center)
            SwiftUI.Button(action: onOpen) {
                BetaIconRow("開啟筆記庫", systemImage: "arrow.right.circle")
            }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(Text(verbatim: "開啟筆記庫"))
                .accessibilityHint(Text(verbatim: "開啟既有 Notes 筆記庫"))
                .accessibilityIdentifier("nextstep.beta.notes.openLibrary")
        }
        .padding(NextStepSpacing.xl)
        .frame(maxWidth: NextStepSize.compactContentMaximum)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NextStepPalette.appBackground)
        .nextStepBetaNavigationTitle("筆記庫")
        .accessibilityIdentifier("nextstep.beta.screen.notesBridge")
    }
}

private struct NextStepBetaOfflineBlock: View {
    var body: some View {
        HStack(alignment: .top, spacing: NextStepSpacing.sm) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(NextStepPalette.primaryAccent)
            VStack(alignment: .leading, spacing: NextStepSpacing.xxs) {
                Text(verbatim: "離線可執行")
                    .font(NextStepTypography.supporting.weight(.semibold))
                Text(verbatim: "目標、來源抽取、Today 規劃與完成紀錄不依賴付費服務或網路。")
                    .font(NextStepTypography.annotation)
                    .foregroundStyle(NextStepPalette.secondaryText)
            }
        }
        .nextStepCard(state: .offline)
        .accessibilityElement(children: .combine)
    }
}

private struct NextStepBetaSyncBlock: View {
    let model: NextStepBetaModel
    let chooseFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.md) {
            HStack(alignment: .top, spacing: NextStepSpacing.sm) {
                Image(systemName: stateSymbol)
                    .foregroundStyle(stateColor)
                VStack(alignment: .leading, spacing: NextStepSpacing.xxs) {
                    Text(verbatim: stateTitle)
                        .font(NextStepTypography.supporting.weight(.semibold))
                        .accessibilityIdentifier("nextstep.beta.sync.state")
                    Text(verbatim: stateDetail)
                        .font(NextStepTypography.annotation)
                        .foregroundStyle(NextStepPalette.secondaryText)
                }
                Spacer(minLength: 0)
                if isBusy { ProgressView() }
            }

            controls
        }
        .nextStepCard(state: cardState)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nextstep.beta.sync.block")
    }

    @ViewBuilder
    private var controls: some View {
        switch model.syncState {
        case .notConfigured, .failed:
            BetaActionControl("選取同步資料夾", systemImage: "folder.badge.plus") {
                chooseFolder()
            }
            .buttonStyle(.borderedProminent)

        case .offline:
            ViewThatFits(in: .horizontal) {
                HStack { retryButton; changeFolderButton }
                VStack(alignment: .leading) { retryButton; changeFolderButton }
            }

        case .ready:
            ViewThatFits(in: .horizontal) {
                HStack { syncNowButton; folderOptionsMenu }
                VStack(alignment: .leading) { syncNowButton; folderOptionsMenu }
            }

        case .reviewRequired(let review):
            if review.kind == .protectedDeadline {
                VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
                    comparisonRow("這台裝置", value: review.localDescription)
                    comparisonRow("同步資料", value: review.syncedDescription)
                    ViewThatFits(in: .horizontal) {
                        HStack { keepLocalButton; useSyncedButton }
                        VStack(alignment: .leading) { keepLocalButton; useSyncedButton }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
                    Text(verbatim: "相同來源 ID 出現不同檔案內容。首版不會猜測哪份正確，也不會覆寫任何一份。")
                        .font(NextStepTypography.annotation)
                        .foregroundStyle(NextStepPalette.secondaryText)
                    BetaActionControl("選取另一個資料夾", systemImage: "folder") {
                        chooseFolder()
                    }
                    .buttonStyle(.bordered)
                }
            }

        case .restoring, .connecting, .syncing:
            EmptyView()
        }
    }

    private var retryButton: some View {
        BetaActionControl("重試", systemImage: "arrow.clockwise") {
            Task { await model.synchronizeNow() }
        }
        .buttonStyle(.borderedProminent)
    }

    private var changeFolderButton: some View {
        BetaActionControl("更換資料夾", systemImage: "folder") { chooseFolder() }
            .buttonStyle(.bordered)
    }

    private var syncNowButton: some View {
        BetaActionControl("立即同步", systemImage: "arrow.triangle.2.circlepath") {
            Task { await model.synchronizeNow() }
        }
        .buttonStyle(.borderedProminent)
    }

    private var folderOptionsMenu: some View {
        Menu {
            Button(action: chooseFolder) {
                Label {
                    Text(verbatim: "更換資料夾")
                } icon: {
                    Image(systemName: "folder")
                }
            }
            Button {
                Task { await model.disconnectSyncFolder() }
            } label: {
                Label {
                    Text(verbatim: "停止使用同步資料夾")
                } icon: {
                    Image(systemName: "xmark.icloud")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .frame(
                    minWidth: NextStepSize.minimumTapTarget,
                    minHeight: NextStepSize.minimumTapTarget
                )
        }
        .accessibilityLabel(Text(verbatim: "同步資料夾選項"))
    }

    private var keepLocalButton: some View {
        BetaActionControl("保留這台裝置", systemImage: "iphone") {
            Task { await model.resolveSyncReview(useSyncedArchive: false) }
        }
        .buttonStyle(.bordered)
    }

    private var useSyncedButton: some View {
        BetaActionControl("採用同步資料", systemImage: "icloud.and.arrow.down") {
            Task { await model.resolveSyncReview(useSyncedArchive: true) }
        }
        .buttonStyle(.borderedProminent)
    }

    private func comparisonRow(_ title: String, value: String) -> some View {
        HStack {
            Text(verbatim: title)
                .font(NextStepTypography.annotation.weight(.semibold))
            Spacer()
            Text(verbatim: value)
                .font(NextStepTypography.metadata)
                .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }

    private var stateTitle: String {
        switch model.syncState {
        case .notConfigured: "尚未設定跨裝置同步"
        case .restoring: "正在還原同步資料夾"
        case .connecting: "正在連線同步資料夾"
        case .syncing: "正在同步"
        case .ready: "同步資料夾已連線"
        case .offline: "同步資料夾目前離線"
        case .reviewRequired: "需要確認受保護資料"
        case .failed: "同步設定需要處理"
        }
    }

    private var stateDetail: String {
        switch model.syncState {
        case .notConfigured:
            "免費首版使用 Files／iCloud Drive。請在 iPhone 與 iPad 各自選取同一資料夾；本機資料仍可離線使用。"
        case .restoring:
            "正在使用這台裝置保存的 security-scoped bookmark 重新取得權限。"
        case .connecting:
            "正在驗證資料夾與共享 library ID。"
        case .syncing(let last):
            last.map { "上次完成：\($0.formatted(date: .abbreviated, time: .shortened))" }
                ?? "第一次同步可能需要較久時間。"
        case .ready(let date):
            "上次完成：\(date.formatted(date: .abbreviated, time: .shortened))。來源以內容雜湊驗證。"
        case .offline(_, let message):
            "本機原子儲存與待上傳操作均已保留。\(message)"
        case .reviewRequired(let review):
            review.kind == .protectedDeadline
                ? "兩台裝置的硬期限不同；同步已暫停，不會靜默覆寫。"
                : "不可變來源內容不同；同步已暫停，需人工檢查。"
        case .failed(let message):
            "\(message) 可重新選取同一個 iCloud Drive 資料夾。"
        }
    }

    private var stateSymbol: String {
        switch model.syncState {
        case .notConfigured: "icloud.slash"
        case .restoring, .connecting, .syncing: "icloud.and.arrow.up"
        case .ready: "checkmark.icloud"
        case .offline: "icloud.slash"
        case .reviewRequired: "exclamationmark.icloud"
        case .failed: "xmark.icloud"
        }
    }

    private var stateColor: Color {
        switch model.syncState {
        case .ready: NextStepPalette.sourceVerified
        case .reviewRequired, .offline: NextStepPalette.warning
        case .failed: NextStepPalette.error
        case .notConfigured, .restoring, .connecting, .syncing:
            NextStepPalette.primaryAccent
        }
    }

    private var cardState: NextStepComponentState {
        switch model.syncState {
        case .offline: .offline
        case .reviewRequired: .aiUncertain
        case .failed: .error
        default: .standard
        }
    }

    private var isBusy: Bool {
        switch model.syncState {
        case .restoring, .connecting, .syncing: true
        default: false
        }
    }
}

private struct NextStepBetaEmptyCard: View {
    let symbol: String
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(NextStepPalette.primaryAccent)
            Text(title).font(NextStepTypography.sectionTitle)
            Text(detail)
                .font(NextStepTypography.body)
                .foregroundStyle(NextStepPalette.secondaryText)
            BetaActionControl(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .frame(minHeight: NextStepSize.minimumTapTarget)
        }
        .nextStepCard()
    }
}

private struct NextStepBetaBadge: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        BetaIconRow(title, systemImage: symbol)
            .font(NextStepTypography.annotation)
            .foregroundStyle(color)
            .padding(.horizontal, NextStepSpacing.sm)
            .padding(.vertical, NextStepSpacing.xs)
            .background(color.opacity(0.1), in: Capsule())
            .accessibilityLabel(title)
    }
}

private struct NextStepBetaRiskBlock: View {
    let risks: [PlanningRisk]

    var body: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            BetaIconRow("規劃風險", systemImage: "exclamationmark.triangle")
                .font(NextStepTypography.sectionTitle)
                .foregroundStyle(NextStepPalette.warning)
            ForEach(risks) { risk in
                Text(risk.message)
                    .font(NextStepTypography.supporting)
            }
        }
        .nextStepCard(state: .overdue)
    }
}

private struct NextStepBetaMessageStack: View {
    let model: NextStepBetaModel

    var body: some View {
        VStack(spacing: 0) {
            if model.isWorking {
                ProgressView {
                    Text(verbatim: "正在裝置端處理…")
                }
                    .frame(maxWidth: .infinity)
                    .padding(NextStepSpacing.sm)
                    .background(NextStepPalette.elevatedSurface)
            }
            if let error = model.errorMessage {
                messageRow(
                    text: error,
                    symbol: "exclamationmark.octagon.fill",
                    color: NextStepPalette.error
                )
            } else if let status = model.statusMessage {
                messageRow(
                    text: status,
                    symbol: "checkmark.circle.fill",
                    color: NextStepPalette.success
                )
            }
        }
    }

    private func messageRow(text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top) {
            Image(systemName: symbol)
            Text(text)
                .font(NextStepTypography.supporting)
            Spacer()
            SwiftUI.Button {
                model.clearMessages()
            } label: {
                BetaIconRow("關閉", systemImage: "xmark")
            }
            .labelStyle(.iconOnly)
            .accessibilityIdentifier("nextstep.beta.message.dismiss")
        }
        .foregroundStyle(color)
        .padding(NextStepSpacing.sm)
        .background(NextStepPalette.elevatedSurface)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct NextStepBetaLoadingView: View {
    var body: some View {
        VStack(spacing: NextStepSpacing.md) {
            ProgressView()
            Text(verbatim: "載入本機 NextStep 資料…")
                .font(NextStepTypography.supporting)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NextStepBetaFatalErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            BetaIconRow("無法載入 Beta", systemImage: "exclamationmark.octagon")
        } description: {
            Text(message)
        } actions: {
            BetaActionControl("重試", action: retry).buttonStyle(.borderedProminent)
        }
    }
}

/// Beta copy is intentionally verbatim while the product vocabulary is still
/// under validation. This keeps temporary strings out of the production
/// localization catalog without accidentally treating Chinese copy as a key.
private enum NextStepBetaCopy {
    static func verbatim(_ value: String) -> String { value }
}

private struct BetaIconRow: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        SwiftUI.Label {
            Text(verbatim: title)
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

private struct BetaActionControl: View {
    let title: String
    let systemImage: String?
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    init(
        _ title: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = nil
        self.action = action
    }

    var body: some View {
        SwiftUI.Button(action: action) {
            if let systemImage {
                BetaIconRow(title, systemImage: systemImage)
            } else {
                Text(verbatim: title)
            }
        }
    }
}

private extension View {
    func nextStepBetaNavigationTitle(_ title: String) -> some View {
        navigationTitle(Text(verbatim: title))
    }
}

private enum NextStepBetaStatusText {
    static func title(for status: ActionStatus) -> String {
        switch status {
        case .backlog: "待規劃"
        case .ready: "可開始"
        case .scheduled: "已排入 Today"
        case .inProgress: "進行中"
        case .completed: "已完成"
        case .deferred: "已延後"
        case .blocked: "受阻"
        case .cancelled: "已取消"
        }
    }
}
