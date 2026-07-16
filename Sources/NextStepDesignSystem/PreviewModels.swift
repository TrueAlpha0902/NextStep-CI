import Foundation

public struct NextStepPreviewGoal: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let deadline: String
    public let progress: Double
    public let risk: String?

    public init(
        id: UUID = UUID(),
        title: String,
        deadline: String,
        progress: Double,
        risk: String? = nil
    ) {
        self.id = id
        self.title = title
        self.deadline = deadline
        self.progress = min(max(progress, 0), 1)
        self.risk = risk
    }
}

public struct NextStepPreviewAction: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let durationMinutes: Int
    public let reason: String
    public let milestone: String
    public let materialSummary: String
    public let completionOutput: String
    public let state: NextStepComponentState

    public init(
        id: UUID = UUID(),
        title: String,
        durationMinutes: Int,
        reason: String,
        milestone: String,
        materialSummary: String,
        completionOutput: String,
        state: NextStepComponentState = .standard
    ) {
        self.id = id
        self.title = title
        self.durationMinutes = max(durationMinutes, 1)
        self.reason = reason
        self.milestone = milestone
        self.materialSummary = materialSummary
        self.completionOutput = completionOutput
        self.state = state
    }
}

public struct NextStepPreviewLearningStep: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let index: Int
    public let title: String
    public let detail: String
    public let durationMinutes: Int
    public let state: NextStepComponentState

    public init(
        id: UUID = UUID(),
        index: Int,
        title: String,
        detail: String,
        durationMinutes: Int,
        state: NextStepComponentState
    ) {
        self.id = id
        self.index = index
        self.title = title
        self.detail = detail
        self.durationMinutes = max(durationMinutes, 1)
        self.state = state
    }
}

public struct NextStepPreviewSource: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let detail: String
    public let location: String
    public let isVerified: Bool
    public let accessibility: String

    public init(
        id: UUID = UUID(),
        title: String,
        detail: String,
        location: String,
        isVerified: Bool,
        accessibility: String
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.location = location
        self.isVerified = isVerified
        self.accessibility = accessibility
    }
}

public struct NextStepPreviewHighlight: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let text: String
    public let kind: NextStepHighlightKind
    public let sourceLocation: String
    public let explanation: String

    public init(
        id: UUID = UUID(),
        text: String,
        kind: NextStepHighlightKind,
        sourceLocation: String,
        explanation: String
    ) {
        self.id = id
        self.text = text
        self.kind = kind
        self.sourceLocation = sourceLocation
        self.explanation = explanation
    }
}

public struct NextStepPreviewPaper: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let authors: String
    public let year: Int
    public let publication: String
    public let doi: String
    public let accessStatus: String
    public let peerReviewStatus: String
    public let isVerified: Bool
    public let highlights: [NextStepPreviewHighlight]

    public init(
        id: UUID = UUID(),
        title: String,
        authors: String,
        year: Int,
        publication: String,
        doi: String,
        accessStatus: String,
        peerReviewStatus: String,
        isVerified: Bool,
        highlights: [NextStepPreviewHighlight]
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.year = year
        self.publication = publication
        self.doi = doi
        self.accessStatus = accessStatus
        self.peerReviewStatus = peerReviewStatus
        self.isVerified = isVerified
        self.highlights = highlights
    }
}

public struct NextStepPreviewMilestone: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let dueDate: String
    public let progress: Double
    public let state: NextStepComponentState
    public let output: String

    public init(
        id: UUID = UUID(),
        title: String,
        dueDate: String,
        progress: Double,
        state: NextStepComponentState,
        output: String
    ) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
        self.progress = min(max(progress, 0), 1)
        self.state = state
        self.output = output
    }
}

public enum NextStepWorkspaceKind: String, CaseIterable, Hashable, Sendable, Identifiable {
    case thesis = "論文"
    case project = "作品"
    case career = "求職"

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .thesis: "doc.text.magnifyingglass"
        case .project: "hammer"
        case .career: "briefcase"
        }
    }
}

public struct NextStepPreviewWorkspaceItem: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let kind: NextStepWorkspaceKind
    public let title: String
    public let phase: String
    public let nextOutput: String
    public let sourceCount: Int
    public let progress: Double
    public let state: NextStepComponentState

    public init(
        id: UUID = UUID(),
        kind: NextStepWorkspaceKind,
        title: String,
        phase: String,
        nextOutput: String,
        sourceCount: Int,
        progress: Double,
        state: NextStepComponentState
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.phase = phase
        self.nextOutput = nextOutput
        self.sourceCount = max(sourceCount, 0)
        self.progress = min(max(progress, 0), 1)
        self.state = state
    }
}

public enum NextStepPreviewFixtures {
    public static let graduationGoal = NextStepPreviewGoal(
        title: "2028 年完成研究所並進入企業金融領域",
        deadline: "2028 年 6 月 30 日",
        progress: 0.34,
        risk: "文獻回顧較原計畫落後 3 天"
    )

    public static let todayActions: [NextStepPreviewAction] = [
        NextStepPreviewAction(
            title: "理解負債如何影響 WACC",
            durationMinutes: 35,
            reason: "週五個案討論前需先建立估值基礎",
            milestone: "完成企業財務核心概念複習",
            materialSummary: "5 分鐘前置概念、課本第 12 章與 1 篇驗證論文",
            completionOutput: "寫出 120 字解釋並答對 3 題中的 2 題"
        ),
        NextStepPreviewAction(
            title: "完成研究背景第一段",
            durationMinutes: 45,
            reason: "本週成果必須完成背景與研究動機草稿",
            milestone: "完成論文研究問題與背景",
            materialSummary: "3 個官方統計數據、2 篇核心文獻與段落骨架",
            completionOutput: "一段含 2 個可追溯引用的 250 字草稿",
            state: .selected
        ),
        NextStepPreviewAction(
            title: "修訂履歷的授信分析能力段落",
            durationMinutes: 25,
            reason: "三個目標職缺皆把授信分析列為必要能力",
            milestone: "完成法金 MA 履歷第一版",
            materialSummary: "職缺共同要求、現有經歷與 STAR 提示",
            completionOutput: "一段 3 行、含量化證據的履歷內容",
            state: .offline
        )
    ]

    public static let learningSteps: [NextStepPreviewLearningStep] = [
        NextStepPreviewLearningStep(
            index: 1,
            title: "建立前置概念",
            detail: "先辨認資金成本、稅盾與資本結構的關係。",
            durationMinutes: 5,
            state: .completed
        ),
        NextStepPreviewLearningStep(
            index: 2,
            title: "閱讀指定證據",
            detail: "閱讀來源第 14–16 頁，聚焦已標記的公式與限制。",
            durationMinutes: 15,
            state: .selected
        ),
        NextStepPreviewLearningStep(
            index: 3,
            title: "回答引導問題",
            detail: "用自己的話解釋槓桿提高時 WACC 為何不一定下降。",
            durationMinutes: 8,
            state: .standard
        ),
        NextStepPreviewLearningStep(
            index: 4,
            title: "完成理解測驗",
            detail: "三題單選，答錯後會連回對應來源。",
            durationMinutes: 7,
            state: .standard
        )
    ]

    public static let paper = NextStepPreviewPaper(
        title: "The Cost of Capital, Corporation Finance and the Theory of Investment",
        authors: "Franco Modigliani · Merton H. Miller",
        year: 1958,
        publication: "American Economic Review, 48(3), 261–297",
        doi: "10.2307/1809766",
        accessStatus: "機構典藏全文可用",
        peerReviewStatus: "同儕審查期刊",
        isVerified: true,
        highlights: [
            NextStepPreviewHighlight(
                text: "The market value of any firm is independent of its capital structure.",
                kind: .conclusion,
                sourceLocation: "p. 268 · Proposition I",
                explanation: "在無稅與完全市場的假設下，融資組合不改變公司價值。"
            ),
            NextStepPreviewHighlight(
                text: "This conclusion rests on assumptions that do not fully describe observed markets.",
                kind: .risk,
                sourceLocation: "p. 296 · Limitations",
                explanation: "應與稅、破產成本與資訊不對稱的後續理論一起閱讀。"
            )
        ]
    )

    public static let sources: [NextStepPreviewSource] = [
        NextStepPreviewSource(
            title: paper.title,
            detail: paper.authors,
            location: "必讀 p. 268–271",
            isVerified: true,
            accessibility: "全文可用"
        ),
        NextStepPreviewSource(
            title: "企業財務課程講義：資本成本",
            detail: "使用者於 2026/07/14 匯入",
            location: "第 12–18 張",
            isVerified: true,
            accessibility: "離線檔案"
        )
    ]

    public static let milestones: [NextStepPreviewMilestone] = [
        NextStepPreviewMilestone(
            title: "確認研究問題",
            dueDate: "7 月 18 日",
            progress: 1,
            state: .completed,
            output: "一個經指導教授確認的研究問題"
        ),
        NextStepPreviewMilestone(
            title: "完成文獻回顧",
            dueDate: "8 月 15 日",
            progress: 0.42,
            state: .overdue,
            output: "2,500 字初稿與 20 篇文獻比較矩陣"
        ),
        NextStepPreviewMilestone(
            title: "完成研究設計",
            dueDate: "9 月 10 日",
            progress: 0.08,
            state: .standard,
            output: "方法、樣本與分析計畫"
        ),
        NextStepPreviewMilestone(
            title: "完成論文初稿",
            dueDate: "12 月 12 日",
            progress: 0,
            state: .disabled,
            output: "可送交指導教授的完整初稿"
        )
    ]

    public static let workspaceItems: [NextStepPreviewWorkspaceItem] = [
        NextStepPreviewWorkspaceItem(
            kind: .thesis,
            title: "企業授信決策研究",
            phase: "文獻回顧",
            nextOutput: "完成研究背景第一段",
            sourceCount: 18,
            progress: 0.42,
            state: .overdue
        ),
        NextStepPreviewWorkspaceItem(
            kind: .project,
            title: "NextStep Case Study",
            phase: "Prototype",
            nextOutput: "驗證 Today 行動流程",
            sourceCount: 9,
            progress: 0.56,
            state: .standard
        ),
        NextStepPreviewWorkspaceItem(
            kind: .career,
            title: "法金 MA 求職",
            phase: "履歷第一版",
            nextOutput: "補上授信分析能力證據",
            sourceCount: 3,
            progress: 0.31,
            state: .aiUncertain
        )
    ]
}
