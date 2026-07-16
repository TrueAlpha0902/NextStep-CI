import Foundation
import SwiftUI

public struct NextStepBadge: View {
    private let title: String
    private let symbolName: String
    private let tint: Color

    public init(title: String, symbolName: String, tint: Color) {
        self.title = title
        self.symbolName = symbolName
        self.tint = tint
    }

    public var body: some View {
        Label(title, systemImage: symbolName)
            .font(NextStepTypography.metadata)
            .foregroundStyle(tint)
            .padding(.horizontal, NextStepSpacing.xs)
            .padding(.vertical, NextStepSpacing.xxs)
            .background(tint.opacity(0.11), in: Capsule())
            .overlay {
                Capsule().stroke(tint.opacity(0.35), lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
    }
}

public struct NextStepStateBadge: View {
    private let state: NextStepComponentState

    public init(state: NextStepComponentState) {
        self.state = state
    }

    public var body: some View {
        NextStepBadge(
            title: state.title,
            symbolName: state.symbolName,
            tint: state.foregroundColor
        )
    }
}

public struct SourceConfidenceBadge: View {
    private let confidence: Double
    private let isVerified: Bool

    public init(confidence: Double, isVerified: Bool) {
        self.confidence = min(max(confidence, 0), 1)
        self.isVerified = isVerified
    }

    public var body: some View {
        NextStepBadge(
            title: isVerified
                ? "來源信心 \(confidence.formatted(.percent.precision(.fractionLength(0))))"
                : "尚未驗證",
            symbolName: isVerified ? "checkmark.shield.fill" : "questionmark.diamond.fill",
            tint: isVerified ? NextStepPalette.sourceVerified : NextStepPalette.sourceUnverified
        )
        .accessibilityLabel(
            isVerified
                ? "來源已驗證，信心 \(confidence.formatted(.percent))"
                : "來源尚未驗證"
        )
    }
}

public struct AIGeneratedBadge: View {
    private let isUncertain: Bool

    public init(isUncertain: Bool = false) {
        self.isUncertain = isUncertain
    }

    public var body: some View {
        NextStepBadge(
            title: isUncertain ? "AI 建議 · 待確認" : "AI 建議",
            symbolName: "sparkles",
            tint: NextStepPalette.aiGenerated
        )
    }
}

public struct VerifiedSourceBadge: View {
    private let isVerified: Bool

    public init(isVerified: Bool) {
        self.isVerified = isVerified
    }

    public var body: some View {
        NextStepBadge(
            title: isVerified ? "來源已驗證" : "來源未驗證",
            symbolName: isVerified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill",
            tint: isVerified ? NextStepPalette.sourceVerified : NextStepPalette.sourceUnverified
        )
    }
}

public struct GoalProgressHeader: View {
    private let goal: NextStepPreviewGoal

    public init(goal: NextStepPreviewGoal) {
        self.goal = goal
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: NextStepSpacing.sm) {
                VStack(alignment: .leading, spacing: NextStepSpacing.xxs) {
                    Text("最終目標")
                        .font(NextStepTypography.metadata)
                        .foregroundStyle(NextStepPalette.secondaryText)
                    Text(goal.title)
                        .font(NextStepTypography.sectionTitle)
                        .foregroundStyle(NextStepPalette.primaryText)
                }
                Spacer(minLength: NextStepSpacing.sm)
                Text(goal.progress, format: .percent.precision(.fractionLength(0)))
                    .font(NextStepTypography.sectionTitle)
                    .foregroundStyle(NextStepPalette.primaryAccent)
            }

            ProgressView(value: goal.progress)
                .tint(NextStepPalette.primaryAccent)
                .accessibilityLabel("目標進度")

            HStack(spacing: NextStepSpacing.xs) {
                Label(goal.deadline, systemImage: "calendar")
                if let risk = goal.risk {
                    Label(risk, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(NextStepPalette.warning)
                }
            }
            .font(NextStepTypography.supporting)
            .foregroundStyle(NextStepPalette.secondaryText)
        }
        .nextStepCard()
        .accessibilityElement(children: .combine)
    }
}

public struct TodayActionCard: View {
    private let action: NextStepPreviewAction
    private let isPrimary: Bool
    private let onStart: () -> Void

    public init(
        action: NextStepPreviewAction,
        isPrimary: Bool = false,
        onStart: @escaping () -> Void = {}
    ) {
        self.action = action
        self.isPrimary = isPrimary
        self.onStart = onStart
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            HStack(alignment: .top, spacing: NextStepSpacing.sm) {
                Image(systemName: action.state == .completed ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(action.state.foregroundColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: NextStepSpacing.xxs) {
                    Text(action.title)
                        .font(NextStepTypography.sectionTitle)
                        .foregroundStyle(NextStepPalette.primaryText)
                    Label("\(action.durationMinutes) 分鐘", systemImage: "clock")
                        .font(NextStepTypography.metadata)
                        .foregroundStyle(NextStepPalette.secondaryText)
                }

                Spacer(minLength: NextStepSpacing.xs)
                if isPrimary {
                    NextStepBadge(
                        title: "主要任務",
                        symbolName: "flag.fill",
                        tint: NextStepPalette.primaryAccent
                    )
                }
            }

            WhyTodayBlock(reason: action.reason)

            Label(action.materialSummary, systemImage: "tray.full")
                .font(NextStepTypography.supporting)
                .foregroundStyle(NextStepPalette.secondaryText)

            CompletionCriteriaBlock(criteria: [action.completionOutput])

            HStack {
                Label(action.milestone, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(NextStepTypography.metadata)
                    .foregroundStyle(NextStepPalette.secondaryText)
                Spacer()
                Button(action: onStart) {
                    if action.state == .loading {
                        ProgressView()
                            .frame(minWidth: NextStepSize.minimumTapTarget)
                    } else {
                        Label("開始", systemImage: "arrow.right")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(NextStepPalette.primaryAccent)
                .font(NextStepTypography.button)
                .disabled(!action.state.allowsInteraction || action.state == .completed)
                .accessibilityHint("開啟已準備好的引導式學習內容")
            }
        }
        .nextStepCard(state: action.state)
        .overlay(alignment: .topTrailing) {
            if action.state != .standard && action.state != .selected {
                NextStepStateBadge(state: action.state)
                    .padding(NextStepSpacing.xs)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

public struct WhyTodayBlock: View {
    private let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public var body: some View {
        HStack(alignment: .top, spacing: NextStepSpacing.xs) {
            Image(systemName: "text.bubble")
                .foregroundStyle(NextStepPalette.primaryAccent)
            VStack(alignment: .leading, spacing: NextStepSpacing.xxs) {
                Text("為什麼是今天")
                    .font(NextStepTypography.annotation)
                    .foregroundStyle(NextStepPalette.primaryAccent)
                Text(reason)
                    .font(NextStepTypography.supporting)
                    .foregroundStyle(NextStepPalette.primaryText)
            }
        }
        .padding(NextStepSpacing.sm)
        .background(NextStepPalette.primaryAccent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: NextStepRadius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

public struct CompletionCriteriaBlock: View {
    private let criteria: [String]

    public init(criteria: [String]) {
        self.criteria = criteria
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
            Label("完成標準", systemImage: "checklist")
                .font(NextStepTypography.annotation)
                .foregroundStyle(NextStepPalette.primaryText)
            ForEach(Array(criteria.enumerated()), id: \.offset) { _, criterion in
                Label(criterion, systemImage: "square")
                    .font(NextStepTypography.supporting)
                    .foregroundStyle(NextStepPalette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

public struct GuidedLearningStep: View {
    private let step: NextStepPreviewLearningStep
    private let onSelect: () -> Void

    public init(step: NextStepPreviewLearningStep, onSelect: @escaping () -> Void = {}) {
        self.step = step
        self.onSelect = onSelect
    }

    public var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: NextStepSpacing.sm) {
                ZStack {
                    Circle()
                        .fill(step.state.foregroundColor.opacity(0.12))
                        .frame(width: 34, height: 34)
                    if step.state == .completed {
                        Image(systemName: "checkmark")
                    } else {
                        Text("\(step.index)")
                    }
                }
                .font(NextStepTypography.annotation)
                .foregroundStyle(step.state.foregroundColor)

                VStack(alignment: .leading, spacing: NextStepSpacing.xxs) {
                    Text(step.title)
                        .font(NextStepTypography.supporting.weight(.semibold))
                        .foregroundStyle(NextStepPalette.primaryText)
                    Text(step.detail)
                        .font(NextStepTypography.supporting)
                        .foregroundStyle(NextStepPalette.secondaryText)
                        .lineLimit(step.state == .selected ? nil : 2)
                    Label("\(step.durationMinutes) 分鐘", systemImage: "clock")
                        .font(NextStepTypography.metadata)
                        .foregroundStyle(NextStepPalette.secondaryText)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(NextStepPalette.secondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .nextStepCard(state: step.state)
        .disabled(!step.state.allowsInteraction)
        .accessibilityLabel("步驟 \(step.index)，\(step.title)，\(step.state.title)")
    }
}

public struct SourceCard: View {
    private let source: NextStepPreviewSource
    private let state: NextStepComponentState
    private let onOpen: () -> Void

    public init(
        source: NextStepPreviewSource,
        state: NextStepComponentState = .standard,
        onOpen: @escaping () -> Void = {}
    ) {
        self.source = source
        self.state = state
        self.onOpen = onOpen
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            HStack(alignment: .top) {
                Image(systemName: "doc.text")
                    .foregroundStyle(NextStepPalette.primaryAccent)
                VStack(alignment: .leading, spacing: NextStepSpacing.xxs) {
                    Text(source.title)
                        .font(NextStepTypography.supporting.weight(.semibold))
                        .foregroundStyle(NextStepPalette.primaryText)
                    Text(source.detail)
                        .font(NextStepTypography.citation)
                        .foregroundStyle(NextStepPalette.secondaryText)
                }
            }
            HStack {
                VerifiedSourceBadge(isVerified: source.isVerified)
                NextStepBadge(
                    title: source.accessibility,
                    symbolName: "lock.open",
                    tint: NextStepPalette.secondaryText
                )
            }
            Label(source.location, systemImage: "bookmark")
                .font(NextStepTypography.metadata)
                .foregroundStyle(NextStepPalette.secondaryText)
            OriginalFileLink(state: state, onOpen: onOpen)
        }
        .nextStepCard(state: state)
    }
}

public struct PaperCitationCard: View {
    private let paper: NextStepPreviewPaper

    public init(paper: NextStepPreviewPaper) {
        self.paper = paper
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: NextStepSpacing.xxs) {
                    Text(paper.title)
                        .font(NextStepTypography.sectionTitle)
                        .foregroundStyle(NextStepPalette.primaryText)
                    Text("\(paper.authors) (\(paper.year))")
                        .font(NextStepTypography.citation)
                        .foregroundStyle(NextStepPalette.secondaryText)
                    Text(paper.publication)
                        .font(NextStepTypography.citation)
                        .foregroundStyle(NextStepPalette.secondaryText)
                }
                Spacer(minLength: NextStepSpacing.sm)
                VerifiedSourceBadge(isVerified: paper.isVerified)
            }

            LabeledContent("DOI", value: paper.doi)
            LabeledContent("存取", value: paper.accessStatus)
            LabeledContent("審查", value: paper.peerReviewStatus)
        }
        .font(NextStepTypography.metadata)
        .foregroundStyle(NextStepPalette.primaryText)
        .nextStepCard()
        .accessibilityElement(children: .combine)
    }
}

public struct OriginalFileLink: View {
    private let state: NextStepComponentState
    private let onOpen: () -> Void

    public init(
        state: NextStepComponentState = .standard,
        onOpen: @escaping () -> Void = {}
    ) {
        self.state = state
        self.onOpen = onOpen
    }

    public var body: some View {
        Button(action: onOpen) {
            HStack {
                Label(
                    state == .sourceUnavailable ? "原始來源目前無法存取" : "開啟原始來源",
                    systemImage: state == .sourceUnavailable ? "link.badge.plus" : "arrow.up.right.square"
                )
                Spacer()
                if state == .loading { ProgressView() }
            }
            .frame(minHeight: NextStepSize.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .tint(state.foregroundColor)
        .disabled(!state.allowsInteraction)
        .accessibilityHint("離開摘要並檢視可驗證的原始位置")
    }
}

public struct HighlightedPassage: View {
    private let highlight: NextStepPreviewHighlight
    private let isSelected: Bool
    private let onSelect: () -> Void

    public init(
        highlight: NextStepPreviewHighlight,
        isSelected: Bool = false,
        onSelect: @escaping () -> Void = {}
    ) {
        self.highlight = highlight
        self.isSelected = isSelected
        self.onSelect = onSelect
    }

    public var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
                Text(highlight.text)
                    .font(NextStepTypography.citation)
                    .foregroundStyle(NextStepPalette.primaryText)
                    .padding(.horizontal, NextStepSpacing.xxs)
                    .background(highlight.kind.color.opacity(0.52))
                Label(highlight.sourceLocation, systemImage: "scope")
                    .font(NextStepTypography.metadata)
                    .foregroundStyle(NextStepPalette.secondaryText)
                if isSelected {
                    Text(highlight.explanation)
                        .font(NextStepTypography.supporting)
                        .foregroundStyle(NextStepPalette.primaryText)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .nextStepCard(state: isSelected ? .selected : .standard)
        .accessibilityLabel("\(highlight.kind.title)，\(highlight.text)，位置 \(highlight.sourceLocation)")
        .accessibilityHint("顯示這段重點的解釋")
    }
}

public struct HighlightLegend: View {
    public init() {}

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NextStepSpacing.sm) { legendItems }
            VStack(alignment: .leading, spacing: NextStepSpacing.xs) { legendItems }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var legendItems: some View {
        ForEach(NextStepHighlightKind.allCases) { kind in
            Label(kind.title, systemImage: kind.symbolName)
                .font(NextStepTypography.metadata)
                .foregroundStyle(NextStepPalette.primaryText)
                .padding(.horizontal, NextStepSpacing.xs)
                .padding(.vertical, NextStepSpacing.xxs)
                .background(kind.color.opacity(0.45), in: Capsule())
        }
    }
}

public struct MilestoneTimeline: View {
    private let milestones: [NextStepPreviewMilestone]

    public init(milestones: [NextStepPreviewMilestone]) {
        self.milestones = milestones
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(milestones.enumerated()), id: \.element.id) { index, milestone in
                HStack(alignment: .top, spacing: NextStepSpacing.sm) {
                    VStack(spacing: 0) {
                        Image(systemName: milestone.state.symbolName)
                            .foregroundStyle(milestone.state.foregroundColor)
                            .frame(width: 28, height: 28)
                        if index < milestones.count - 1 {
                            Rectangle()
                                .fill(NextStepPalette.divider)
                                .frame(width: 1, height: 76)
                        }
                    }

                    VStack(alignment: .leading, spacing: NextStepSpacing.xxs) {
                        HStack {
                            Text(milestone.title)
                                .font(NextStepTypography.supporting.weight(.semibold))
                            Spacer()
                            Text(milestone.dueDate)
                                .font(NextStepTypography.metadata)
                        }
                        ProgressView(value: milestone.progress)
                            .tint(milestone.state.foregroundColor)
                        Text(milestone.output)
                            .font(NextStepTypography.supporting)
                            .foregroundStyle(NextStepPalette.secondaryText)
                    }
                    .padding(.bottom, NextStepSpacing.md)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

public struct ReplanControl: View {
    private let onReplan: () -> Void

    public init(onReplan: @escaping () -> Void = {}) {
        self.onReplan = onReplan
    }

    public var body: some View {
        Menu {
            Button("我今天時間不足", systemImage: "clock.badge.exclamationmark", action: onReplan)
            Button("任務太難，請拆小", systemImage: "square.split.2x1", action: onReplan)
            Button("我已經會了", systemImage: "checkmark.circle", action: onReplan)
            Button("需要更多解釋", systemImage: "text.bubble", action: onReplan)
            Button("更換學習方式", systemImage: "arrow.triangle.2.circlepath", action: onReplan)
        } label: {
            Label("調整今日計畫", systemImage: "slider.horizontal.3")
                .frame(minHeight: NextStepSize.minimumTapTarget)
        }
        .buttonStyle(.bordered)
        .tint(NextStepPalette.primaryAccent)
        .accessibilityHint("顯示原因並預覽重新規劃的影響，不會直接更改固定期限")
    }
}

public struct LearningTimer: View {
    private let elapsedMinutes: Int
    private let totalMinutes: Int
    @State private var isRunning = false

    public init(elapsedMinutes: Int, totalMinutes: Int) {
        self.elapsedMinutes = max(elapsedMinutes, 0)
        self.totalMinutes = max(totalMinutes, 1)
    }

    public var body: some View {
        HStack(spacing: NextStepSpacing.sm) {
            ZStack {
                Circle()
                    .stroke(NextStepPalette.divider, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: min(Double(elapsedMinutes) / Double(totalMinutes), 1))
                    .stroke(NextStepPalette.primaryAccent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(max(totalMinutes - elapsedMinutes, 0))")
                    .font(NextStepTypography.metadata)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: NextStepSpacing.xxs) {
                Text(isRunning ? "專注進行中" : "學習計時器")
                    .font(NextStepTypography.supporting.weight(.semibold))
                Text("剩餘約 \(max(totalMinutes - elapsedMinutes, 0)) 分鐘")
                    .font(NextStepTypography.metadata)
                    .foregroundStyle(NextStepPalette.secondaryText)
            }
            Spacer()
            Button(isRunning ? "暫停" : "開始") {
                isRunning.toggle()
            }
            .buttonStyle(.bordered)
            .frame(minHeight: NextStepSize.minimumTapTarget)
        }
        .nextStepCard()
        .accessibilityElement(children: .contain)
    }
}

public struct QuizCard: View {
    private let question: String
    private let options: [String]
    private let correctIndex: Int
    @State private var selectedIndex: Int?

    public init(question: String, options: [String], correctIndex: Int) {
        self.question = question
        self.options = options
        self.correctIndex = correctIndex
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            Label("理解測驗", systemImage: "questionmark.bubble")
                .font(NextStepTypography.annotation)
                .foregroundStyle(NextStepPalette.primaryAccent)
            Text(question)
                .font(NextStepTypography.body.weight(.semibold))

            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                Button {
                    selectedIndex = index
                } label: {
                    HStack {
                        Image(systemName: selectedIndex == index ? "circle.inset.filled" : "circle")
                        Text(option)
                            .multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, minHeight: NextStepSize.minimumTapTarget, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(NextStepPalette.primaryText)
            }

            if let selectedIndex {
                Label(
                    selectedIndex == correctIndex ? "回答正確" : "再查看標記的來源段落",
                    systemImage: selectedIndex == correctIndex ? "checkmark.circle.fill" : "arrow.uturn.backward.circle.fill"
                )
                .font(NextStepTypography.supporting)
                .foregroundStyle(
                    selectedIndex == correctIndex ? NextStepPalette.success : NextStepPalette.warning
                )
                .accessibilityLabel(
                    selectedIndex == correctIndex
                        ? "回答正確"
                        : "回答不正確，請查看標記的來源段落"
                )
            }
        }
        .nextStepCard()
    }
}

public struct KnowledgeLink: View {
    private let from: String
    private let to: String
    private let relationship: String

    public init(from: String, to: String, relationship: String) {
        self.from = from
        self.to = to
        self.relationship = relationship
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NextStepSpacing.xs) {
                concept(from)
                Label(relationship, systemImage: "arrow.right")
                    .font(NextStepTypography.annotation)
                    .foregroundStyle(NextStepPalette.aiGenerated)
                concept(to)
            }
            VStack(alignment: .leading, spacing: NextStepSpacing.xs) {
                concept(from)
                Label(relationship, systemImage: "arrow.down")
                    .font(NextStepTypography.annotation)
                    .foregroundStyle(NextStepPalette.aiGenerated)
                concept(to)
            }
        }
        .nextStepCard()
        .accessibilityElement(children: .combine)
    }

    private func concept(_ title: String) -> some View {
        Text(title)
            .font(NextStepTypography.supporting.weight(.semibold))
            .padding(.horizontal, NextStepSpacing.sm)
            .padding(.vertical, NextStepSpacing.xs)
            .background(NextStepPalette.aiGenerated.opacity(0.09))
            .clipShape(RoundedRectangle(cornerRadius: NextStepRadius.control, style: .continuous))
    }
}

public struct WeeklyCurrentAffairsCard: View {
    private let title: String
    private let publishedDate: String
    private let eventDate: String
    private let relevance: String
    private let state: NextStepComponentState

    public init(
        title: String,
        publishedDate: String,
        eventDate: String,
        relevance: String,
        state: NextStepComponentState = .standard
    ) {
        self.title = title
        self.publishedDate = publishedDate
        self.eventDate = eventDate
        self.relevance = relevance
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NextStepSpacing.sm) {
            HStack(alignment: .top) {
                Label("本週時事", systemImage: "newspaper")
                    .font(NextStepTypography.annotation)
                    .foregroundStyle(NextStepPalette.primaryAccent)
                Spacer()
                VerifiedSourceBadge(isVerified: state != .aiUncertain)
            }
            Text(title)
                .font(NextStepTypography.sectionTitle)
                .foregroundStyle(NextStepPalette.primaryText)
            ViewThatFits(in: .horizontal) {
                HStack { dateLabels }
                VStack(alignment: .leading) { dateLabels }
            }
            Text(relevance)
                .font(NextStepTypography.supporting)
                .foregroundStyle(NextStepPalette.secondaryText)
        }
        .nextStepCard(state: state)
    }

    @ViewBuilder
    private var dateLabels: some View {
        Label("發布 \(publishedDate)", systemImage: "calendar.badge.clock")
        Label("事件 \(eventDate)", systemImage: "calendar")
    }
}
