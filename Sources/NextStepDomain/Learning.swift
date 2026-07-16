import Foundation

public enum RequiredOutputKind: String, Codable, CaseIterable, Hashable, Sendable {
    case note
    case answer
    case draft
    case artifact
    case decision
    case practice
    case externalConfirmation
}

public enum OutputValidationKind: String, Codable, CaseIterable, Hashable, Sendable {
    case exists
    case minimumWords
    case checklist
    case quizThreshold
    case userConfirmation
    case externalEvidence
}

public struct RequiredOutput: Codable, Hashable, Sendable {
    public let kind: RequiredOutputKind
    public let title: String
    public let destinationHint: String?
    public let validationKind: OutputValidationKind
    public let minimumWordCount: Int?

    public init(
        kind: RequiredOutputKind,
        title: String,
        destinationHint: String? = nil,
        validationKind: OutputValidationKind,
        minimumWordCount: Int? = nil
    ) throws {
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              minimumWordCount.map({ (1...100_000).contains($0) }) ?? true else {
            throw DomainValidationError.invalidField("requiredOutput")
        }
        if validationKind == .minimumWords, minimumWordCount == nil {
            throw DomainValidationError.invalidField("minimumWordCount")
        }
        self.kind = kind
        self.title = title
        self.destinationHint = destinationHint
        self.validationKind = validationKind
        self.minimumWordCount = minimumWordCount
    }
}

public enum CompletionCriterionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case outputExists
    case minimumWordCount
    case quizScore
    case checklistComplete
    case sourceOpened
    case userAttestation
    case externalConfirmation
}

public struct CompletionCriterion: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let kind: CompletionCriterionKind
    public let title: String
    public let threshold: Double?
    public let requiresEvidence: Bool
    public let requiresUserConfirmation: Bool

    public init(
        id: UUID = UUID(),
        kind: CompletionCriterionKind,
        title: String,
        threshold: Double? = nil,
        requiresEvidence: Bool = true,
        requiresUserConfirmation: Bool = false
    ) throws {
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw DomainValidationError.invalidField("completionCriterion")
        }
        switch kind {
        case .quizScore:
            guard threshold.map({
                $0.isFinite && (0...1).contains($0)
            }) ?? true else {
                throw DomainValidationError.invalidField("criterion threshold")
            }
        case .minimumWordCount:
            guard let threshold,
                  threshold.isFinite,
                  threshold >= 1,
                  threshold <= 100_000,
                  threshold.rounded(.towardZero) == threshold else {
                throw DomainValidationError.invalidField("criterion threshold")
            }
        default:
            guard threshold == nil else {
                throw DomainValidationError.invalidField("criterion threshold")
            }
        }
        self.id = id
        self.kind = kind
        self.title = title
        self.threshold = threshold
        self.requiresEvidence = requiresEvidence
        self.requiresUserConfirmation = requiresUserConfirmation
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case title
        case threshold
        case requiresEvidence
        case requiresUserConfirmation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            kind: container.decode(CompletionCriterionKind.self, forKey: .kind),
            title: container.decode(String.self, forKey: .title),
            threshold: container.decodeIfPresent(Double.self, forKey: .threshold),
            requiresEvidence: container.decode(Bool.self, forKey: .requiresEvidence),
            requiresUserConfirmation: container.decode(
                Bool.self,
                forKey: .requiresUserConfirmation
            )
        )
    }
}

public enum CompletionEvidenceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case artifactReference
    case quizResult
    case checklist
    case sourceAccess
    case userAttestation
    case externalReference
}

public struct CompletionEvidence: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<CompletionEvidenceID>
    public let actionID: DailyActionID
    public let packageID: GuidedLearningPackageID?
    public let packageVersion: Int?
    public let kind: CompletionEvidenceKind
    public let value: String
    /// A deterministic scalar measurement used by criterion-specific gates,
    /// such as the observed word count for `.minimumWordCount`.
    public let measuredValue: Double?
    /// Structured quiz evidence. The legacy `value` remains for additive v1
    /// archive compatibility, but it is never trusted for quiz completion.
    public let quizResult: QuizResultEvidence?
    public let capturedAt: Date
    public let criterionIDs: [UUID]

    /// `true` only when quiz evidence carries the typed, replayable payload
    /// introduced additively during schema v1. Legacy v1 archives could encode
    /// `.quizResult` using only the free-text `value`; those records remain
    /// readable, but must never be treated as proof of a passing score.
    public var hasReplayableQuizResult: Bool {
        guard kind == .quizResult, let quizResult else { return false }
        return measuredValue == quizResult.scoreFraction
    }

    public init(
        metadata: RecordMetadata<CompletionEvidenceID>,
        actionID: DailyActionID,
        packageID: GuidedLearningPackageID? = nil,
        packageVersion: Int? = nil,
        kind: CompletionEvidenceKind,
        value: String,
        measuredValue: Double? = nil,
        quizResult: QuizResultEvidence? = nil,
        capturedAt: Date,
        criterionIDs: [UUID]
    ) throws {
        guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              criterionIDs.isEmpty == false,
              Set(criterionIDs).count == criterionIDs.count,
              measuredValue.map({ $0.isFinite && $0 >= 0 }) ?? true,
              (packageID == nil) == (packageVersion == nil),
              packageVersion.map({ $0 >= 1 }) ?? true else {
            throw DomainValidationError.invalidField("completionEvidence")
        }
        if kind == .quizResult {
            guard let quizResult,
                  metadata.provenance.kind == .deterministicEngine,
                  packageID == quizResult.packageID,
                  packageVersion == quizResult.packageVersion,
                  measuredValue == quizResult.scoreFraction else {
                throw DomainValidationError.invalidField("quizResult")
            }
        } else if quizResult != nil {
            throw DomainValidationError.invalidField("quizResult kind")
        }
        self.metadata = metadata
        self.actionID = actionID
        self.packageID = packageID
        self.packageVersion = packageVersion
        self.kind = kind
        self.value = value
        self.measuredValue = measuredValue
        self.quizResult = quizResult
        self.capturedAt = capturedAt
        self.criterionIDs = criterionIDs
    }

    public init(
        metadata: RecordMetadata<CompletionEvidenceID>,
        actionID: DailyActionID,
        packageID: GuidedLearningPackageID,
        packageVersion: Int,
        quizResult: QuizResultEvidence,
        capturedAt: Date,
        criterionIDs: [UUID]
    ) throws {
        self = try Self(
            metadata: metadata,
            actionID: actionID,
            packageID: packageID,
            packageVersion: packageVersion,
            kind: .quizResult,
            value: "quiz:\(quizResult.quizID):\(quizResult.scoreFraction)",
            measuredValue: quizResult.scoreFraction,
            quizResult: quizResult,
            capturedAt: capturedAt,
            criterionIDs: criterionIDs
        )
    }

    private enum CodingKeys: String, CodingKey {
        case metadata
        case actionID
        case packageID
        case packageVersion
        case kind
        case value
        case measuredValue
        case quizResult
        case capturedAt
        case criterionIDs
    }

    /// Preserves opaque schema-v1 quiz records without routing them through
    /// the typed quiz-result initializer. Callers cannot create new opaque
    /// quiz evidence; this path is reserved for legacy decoding only.
    private init(
        legacyMetadata metadata: RecordMetadata<CompletionEvidenceID>,
        actionID: DailyActionID,
        packageID: GuidedLearningPackageID?,
        packageVersion: Int?,
        value: String,
        measuredValue: Double?,
        capturedAt: Date,
        criterionIDs: [UUID]
    ) {
        self.metadata = metadata
        self.actionID = actionID
        self.packageID = packageID
        self.packageVersion = packageVersion
        self.kind = .quizResult
        self.value = value
        self.measuredValue = measuredValue
        self.quizResult = nil
        self.capturedAt = capturedAt
        self.criterionIDs = criterionIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let metadata = try container.decode(
            RecordMetadata<CompletionEvidenceID>.self,
            forKey: .metadata
        )
        let actionID = try container.decode(DailyActionID.self, forKey: .actionID)
        let packageID = try container.decodeIfPresent(
            GuidedLearningPackageID.self,
            forKey: .packageID
        )
        let packageVersion = try container.decodeIfPresent(Int.self, forKey: .packageVersion)
        let kind = try container.decode(CompletionEvidenceKind.self, forKey: .kind)
        let value = try container.decode(String.self, forKey: .value)
        let measuredValue = try container.decodeIfPresent(Double.self, forKey: .measuredValue)
        let quizResult = try container.decodeIfPresent(
            QuizResultEvidence.self,
            forKey: .quizResult
        )
        let capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        let criterionIDs = try container.decode([UUID].self, forKey: .criterionIDs)

        // CompletionEvidenceKind.quizResult existed in the original v1 model,
        // before a typed, replayable result was persisted. Preserve those
        // opaque records for archive compatibility. CompletionValidator checks
        // `hasReplayableQuizResult` and therefore always fails them closed.
        if kind == .quizResult, quizResult == nil {
            guard value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                  criterionIDs.isEmpty == false,
                  Set(criterionIDs).count == criterionIDs.count,
                  measuredValue.map({ $0.isFinite && $0 >= 0 }) ?? true,
                  (packageID == nil) == (packageVersion == nil),
                  packageVersion.map({ $0 >= 1 }) ?? true else {
                throw DomainValidationError.invalidField("completionEvidence")
            }
            self = Self(
                legacyMetadata: metadata,
                actionID: actionID,
                packageID: packageID,
                packageVersion: packageVersion,
                value: value,
                measuredValue: measuredValue,
                capturedAt: capturedAt,
                criterionIDs: criterionIDs
            )
            return
        }

        self = try Self(
            metadata: metadata,
            actionID: actionID,
            packageID: packageID,
            packageVersion: packageVersion,
            kind: kind,
            value: value,
            measuredValue: measuredValue,
            quizResult: quizResult,
            capturedAt: capturedAt,
            criterionIDs: criterionIDs
        )
    }
}

public enum ActionStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case backlog
    case ready
    case scheduled
    case inProgress
    case completed
    case deferred
    case blocked
    case cancelled
}

public enum ActionFlexibility: String, Codable, CaseIterable, Hashable, Sendable {
    case locked
    case movable
    case splittable
}

public enum ActionDifficulty: Int, Codable, CaseIterable, Hashable, Sendable, Comparable {
    case introductory = 1
    case easy = 2
    case moderate = 3
    case challenging = 4
    case advanced = 5

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum PlanningReasonCode: String, Codable, CaseIterable, Hashable, Sendable {
    case hardDeadlineApproaching
    case milestoneDependency
    case prerequisiteReady
    case spacedReviewDue
    case weaknessRemediation
    case userCommitted
    case weeklyOutcomeRequired
    case availableTimeFit
    case sourcePrepared
    case overdueRecovery
    case workloadBalance
    case fixedSchedule
}

public struct DailyAction: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<DailyActionID>
    public let milestoneID: MilestoneID
    public var relatedGoalIDs: [GoalID]
    public var title: String
    public var whyToday: String
    public var estimatedMinutes: Int
    public var difficulty: ActionDifficulty
    public var priority: Priority
    public var earliestDay: LocalDay?
    public var deadline: FactValue<LocalDay>?
    public var scheduledDay: LocalDay?
    public var flexibility: ActionFlexibility
    public var dependencyActionIDs: [DailyActionID]
    public var reasonCodes: [PlanningReasonCode]
    public var requiredOutput: RequiredOutput
    public var completionCriteria: [CompletionCriterion]
    public var packageID: GuidedLearningPackageID?
    public var sourceDocumentIDs: [SourceDocumentID]
    public var status: ActionStatus
    public var completedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case metadata
        case milestoneID
        case relatedGoalIDs
        case title
        case whyToday
        case estimatedMinutes
        case difficulty
        case priority
        case earliestDay
        case deadline
        case scheduledDay
        case flexibility
        case dependencyActionIDs
        case reasonCodes
        case requiredOutput
        case completionCriteria
        case packageID
        case sourceDocumentIDs
        case status
        case completedAt
    }

    public init(
        metadata: RecordMetadata<DailyActionID>,
        milestoneID: MilestoneID,
        relatedGoalIDs: [GoalID] = [],
        title: String,
        whyToday: String,
        estimatedMinutes: Int,
        difficulty: ActionDifficulty,
        priority: Priority = .normal,
        earliestDay: LocalDay? = nil,
        deadline: FactValue<LocalDay>? = nil,
        scheduledDay: LocalDay? = nil,
        flexibility: ActionFlexibility = .movable,
        dependencyActionIDs: [DailyActionID] = [],
        reasonCodes: [PlanningReasonCode] = [],
        requiredOutput: RequiredOutput,
        completionCriteria: [CompletionCriterion],
        packageID: GuidedLearningPackageID? = nil,
        sourceDocumentIDs: [SourceDocumentID] = [],
        status: ActionStatus = .backlog,
        completedAt: Date? = nil
    ) throws {
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              whyToday.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw DomainValidationError.invalidField("dailyAction")
        }
        guard (1...1_440).contains(estimatedMinutes) else {
            throw DomainValidationError.valueOutOfBounds("estimatedMinutes")
        }
        guard Set(dependencyActionIDs).count == dependencyActionIDs.count,
              dependencyActionIDs.contains(metadata.id) == false else {
            throw DomainValidationError.invalidField("action dependencies")
        }
        if flexibility == .locked, scheduledDay == nil {
            throw DomainValidationError.invalidField("locked action schedule")
        }
        if status == .completed, completedAt == nil {
            throw DomainValidationError.invalidField("completedAt")
        }
        self.metadata = metadata
        self.milestoneID = milestoneID
        self.relatedGoalIDs = relatedGoalIDs
        self.title = title
        self.whyToday = whyToday
        self.estimatedMinutes = estimatedMinutes
        self.difficulty = difficulty
        self.priority = priority
        self.earliestDay = earliestDay
        self.deadline = deadline
        self.scheduledDay = scheduledDay
        self.flexibility = flexibility
        self.dependencyActionIDs = dependencyActionIDs.sorted()
        self.reasonCodes = Array(Set(reasonCodes)).sorted { $0.rawValue < $1.rawValue }
        self.requiredOutput = requiredOutput
        self.completionCriteria = completionCriteria
        self.packageID = packageID
        self.sourceDocumentIDs = sourceDocumentIDs
        self.status = status
        self.completedAt = completedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            metadata: container.decode(RecordMetadata<DailyActionID>.self, forKey: .metadata),
            milestoneID: container.decode(MilestoneID.self, forKey: .milestoneID),
            relatedGoalIDs: container.decode([GoalID].self, forKey: .relatedGoalIDs),
            title: container.decode(String.self, forKey: .title),
            whyToday: container.decode(String.self, forKey: .whyToday),
            estimatedMinutes: container.decode(Int.self, forKey: .estimatedMinutes),
            difficulty: container.decode(ActionDifficulty.self, forKey: .difficulty),
            priority: container.decode(Priority.self, forKey: .priority),
            earliestDay: container.decodeIfPresent(LocalDay.self, forKey: .earliestDay),
            deadline: container.decodeIfPresent(
                FactValue<LocalDay>.self,
                forKey: .deadline
            ),
            scheduledDay: container.decodeIfPresent(LocalDay.self, forKey: .scheduledDay),
            flexibility: container.decode(ActionFlexibility.self, forKey: .flexibility),
            dependencyActionIDs: container.decode(
                [DailyActionID].self,
                forKey: .dependencyActionIDs
            ),
            reasonCodes: container.decode([PlanningReasonCode].self, forKey: .reasonCodes),
            requiredOutput: container.decode(RequiredOutput.self, forKey: .requiredOutput),
            completionCriteria: container.decode(
                [CompletionCriterion].self,
                forKey: .completionCriteria
            ),
            packageID: container.decodeIfPresent(GuidedLearningPackageID.self, forKey: .packageID),
            sourceDocumentIDs: container.decode(
                [SourceDocumentID].self,
                forKey: .sourceDocumentIDs
            ),
            status: container.decode(ActionStatus.self, forKey: .status),
            completedAt: container.decodeIfPresent(Date.self, forKey: .completedAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(milestoneID, forKey: .milestoneID)
        try container.encode(relatedGoalIDs, forKey: .relatedGoalIDs)
        try container.encode(title, forKey: .title)
        try container.encode(whyToday, forKey: .whyToday)
        try container.encode(estimatedMinutes, forKey: .estimatedMinutes)
        try container.encode(difficulty, forKey: .difficulty)
        try container.encode(priority, forKey: .priority)
        try container.encodeIfPresent(earliestDay, forKey: .earliestDay)
        try container.encodeIfPresent(deadline, forKey: .deadline)
        try container.encodeIfPresent(scheduledDay, forKey: .scheduledDay)
        try container.encode(flexibility, forKey: .flexibility)
        try container.encode(dependencyActionIDs, forKey: .dependencyActionIDs)
        try container.encode(reasonCodes, forKey: .reasonCodes)
        try container.encode(requiredOutput, forKey: .requiredOutput)
        try container.encode(completionCriteria, forKey: .completionCriteria)
        try container.encodeIfPresent(packageID, forKey: .packageID)
        try container.encode(sourceDocumentIDs, forKey: .sourceDocumentIDs)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
    }
}

public struct LearningObjective: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let statement: String
    public let successDescription: String

    public init(id: UUID = UUID(), statement: String, successDescription: String) throws {
        guard statement.isEmpty == false, successDescription.isEmpty == false else {
            throw DomainValidationError.invalidField("learningObjective")
        }
        self.id = id
        self.statement = statement
        self.successDescription = successDescription
    }
}

public struct Prerequisite: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let explanation: String
    public let conceptID: KnowledgeConceptID?

    public init(
        id: UUID = UUID(),
        title: String,
        explanation: String,
        conceptID: KnowledgeConceptID? = nil
    ) throws {
        guard title.isEmpty == false, explanation.isEmpty == false else {
            throw DomainValidationError.invalidField("prerequisite")
        }
        self.id = id
        self.title = title
        self.explanation = explanation
        self.conceptID = conceptID
    }
}

public struct SourceReading: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let sourceDocumentID: SourceDocumentID
    public let anchorIDs: [SourceAnchorID]
    public let citationID: CitationID?
    public let isRequired: Bool
    public let rationale: String
    public let accessState: SourceAccessState

    public init(
        id: UUID = UUID(),
        sourceDocumentID: SourceDocumentID,
        anchorIDs: [SourceAnchorID],
        citationID: CitationID? = nil,
        isRequired: Bool,
        rationale: String,
        accessState: SourceAccessState
    ) throws {
        guard rationale.isEmpty == false else {
            throw DomainValidationError.invalidField("sourceReading")
        }
        if isRequired, anchorIDs.isEmpty {
            throw DomainValidationError.invalidField("required reading anchor")
        }
        self.id = id
        self.sourceDocumentID = sourceDocumentID
        self.anchorIDs = anchorIDs
        self.citationID = citationID
        self.isRequired = isRequired
        self.rationale = rationale
        self.accessState = accessState
    }
}

public struct GroundedPoint: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let evidenceLinkIDs: [EvidenceLinkID]

    public init(id: UUID = UUID(), text: String, evidenceLinkIDs: [EvidenceLinkID]) throws {
        guard text.isEmpty == false, evidenceLinkIDs.isEmpty == false else {
            throw DomainValidationError.invalidField("groundedPoint")
        }
        self.id = id
        self.text = text
        self.evidenceLinkIDs = evidenceLinkIDs
    }
}

public struct TermDefinition: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let term: String
    public let definition: String
    public let formula: String?
    public let method: String?
    public let evidenceLinkIDs: [EvidenceLinkID]

    public init(
        id: UUID = UUID(),
        term: String,
        definition: String,
        formula: String? = nil,
        method: String? = nil,
        evidenceLinkIDs: [EvidenceLinkID]
    ) throws {
        guard term.isEmpty == false, definition.isEmpty == false else {
            throw DomainValidationError.invalidField("termDefinition")
        }
        self.id = id
        self.term = term
        self.definition = definition
        self.formula = formula
        self.method = method
        self.evidenceLinkIDs = evidenceLinkIDs
    }
}

public struct GuidedQuestion: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let prompt: String
    public let objectiveID: UUID?
    public let evidenceLinkIDs: [EvidenceLinkID]

    public init(
        id: UUID = UUID(),
        prompt: String,
        objectiveID: UUID? = nil,
        evidenceLinkIDs: [EvidenceLinkID] = []
    ) throws {
        guard prompt.isEmpty == false else {
            throw DomainValidationError.invalidField("guidedQuestion")
        }
        self.id = id
        self.prompt = prompt
        self.objectiveID = objectiveID
        self.evidenceLinkIDs = evidenceLinkIDs
    }
}

public enum QuizItemKind: String, Codable, CaseIterable, Hashable, Sendable {
    case multipleChoice
    case multipleSelect
    case shortAnswer
    case numeric
    case application
}

/// Selects the validation and scoring contract for a quiz without changing the
/// workspace schema version. Archives created before this field existed decode
/// as `.generic`; only explicitly opted-in quizzes use the strict Beta gate.
public enum QuizEvaluationPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case generic
    case groundedDeterministicSingleChoiceV1
}

public struct QuizOption: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let text: String

    public init(id: UUID = UUID(), text: String) throws {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw DomainValidationError.invalidField("quizOption")
        }
        self.id = id
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case text
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            text: container.decode(String.self, forKey: .text)
        )
    }
}

public struct QuizItem: Codable, Hashable, Identifiable, Sendable {
    public let id: QuizItemID
    public let kind: QuizItemKind
    public let prompt: String
    public let options: [QuizOption]
    public let correctOptionIDs: [UUID]
    public let answerExplanation: String
    public let objectiveID: UUID
    public let evidenceLinkIDs: [EvidenceLinkID]

    public init(
        id: QuizItemID = QuizItemID(),
        kind: QuizItemKind,
        prompt: String,
        options: [QuizOption] = [],
        correctOptionIDs: [UUID] = [],
        answerExplanation: String,
        objectiveID: UUID,
        evidenceLinkIDs: [EvidenceLinkID]
    ) throws {
        guard prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              answerExplanation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              evidenceLinkIDs.isEmpty == false,
              Set(evidenceLinkIDs).count == evidenceLinkIDs.count,
              Set(options.map(\.id)).count == options.count,
              Set(correctOptionIDs).count == correctOptionIDs.count else {
            throw DomainValidationError.invalidField("quizItem")
        }
        switch kind {
        case .multipleChoice, .multipleSelect:
            guard options.count >= 2,
                   correctOptionIDs.isEmpty == false,
                   Set(correctOptionIDs).isSubset(of: Set(options.map(\.id))) else {
                throw DomainValidationError.invalidField("quiz choices")
            }
        case .shortAnswer, .numeric, .application:
            guard correctOptionIDs.isEmpty
                    || Set(correctOptionIDs).isSubset(of: Set(options.map(\.id))) else {
                throw DomainValidationError.invalidField("quiz choices")
            }
        }
        self.id = id
        self.kind = kind
        self.prompt = prompt
        self.options = options
        self.correctOptionIDs = correctOptionIDs
        self.answerExplanation = answerExplanation
        self.objectiveID = objectiveID
        self.evidenceLinkIDs = evidenceLinkIDs
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case prompt
        case options
        case correctOptionIDs
        case answerExplanation
        case objectiveID
        case evidenceLinkIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(QuizItemID.self, forKey: .id),
            kind: container.decode(QuizItemKind.self, forKey: .kind),
            prompt: container.decode(String.self, forKey: .prompt),
            options: container.decode([QuizOption].self, forKey: .options),
            correctOptionIDs: container.decode([UUID].self, forKey: .correctOptionIDs),
            answerExplanation: container.decode(String.self, forKey: .answerExplanation),
            objectiveID: container.decode(UUID.self, forKey: .objectiveID),
            evidenceLinkIDs: container.decode([EvidenceLinkID].self, forKey: .evidenceLinkIDs)
        )
    }
}

public struct Quiz: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<QuizID>
    public let learningObjectiveIDs: [UUID]
    public let items: [QuizItem]
    public let passingFraction: Double
    public let evaluationPolicy: QuizEvaluationPolicy

    public init(
        metadata: RecordMetadata<QuizID>,
        learningObjectiveIDs: [UUID],
        items: [QuizItem],
        passingFraction: Double,
        evaluationPolicy: QuizEvaluationPolicy = .generic
    ) throws {
        guard learningObjectiveIDs.isEmpty == false,
              Set(learningObjectiveIDs).count == learningObjectiveIDs.count,
              items.isEmpty == false,
              Set(items.map(\.id)).count == items.count,
              passingFraction.isFinite,
              passingFraction >= 0,
              passingFraction <= 1 else {
            throw DomainValidationError.invalidField("quiz")
        }
        let objectiveSet = Set(learningObjectiveIDs)
        guard items.allSatisfy({ objectiveSet.contains($0.objectiveID) }) else {
            throw DomainValidationError.relationshipMismatch(
                "Every quiz item must reference a quiz learning objective."
            )
        }
        if evaluationPolicy == .groundedDeterministicSingleChoiceV1 {
            guard passingFraction > 0,
                  items.allSatisfy({
                      $0.kind == .multipleChoice && $0.correctOptionIDs.count == 1
                  }) else {
                throw DomainValidationError.invalidField("strict quiz")
            }
        }
        self.metadata = metadata
        self.learningObjectiveIDs = learningObjectiveIDs
        self.items = items
        self.passingFraction = passingFraction
        self.evaluationPolicy = evaluationPolicy
    }

    private enum CodingKeys: String, CodingKey {
        case metadata
        case learningObjectiveIDs
        case items
        case passingFraction
        case evaluationPolicy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            metadata: container.decode(RecordMetadata<QuizID>.self, forKey: .metadata),
            learningObjectiveIDs: container.decode(
                [UUID].self,
                forKey: .learningObjectiveIDs
            ),
            items: container.decode([QuizItem].self, forKey: .items),
            passingFraction: container.decode(Double.self, forKey: .passingFraction),
            evaluationPolicy: container.decodeIfPresent(
                QuizEvaluationPolicy.self,
                forKey: .evaluationPolicy
            ) ?? .generic
        )
    }
}

public struct UserResponse: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<UserResponseID>
    public let attemptID: UUID
    public let quizID: QuizID
    public let quizItemID: QuizItemID
    public let packageVersion: Int
    public let answer: String
    public let selectedOptionIDs: [UUID]
    public let scoreFraction: Double
    public let feedback: String
    public let attemptedAt: Date

    public init(
        metadata: RecordMetadata<UserResponseID>,
        attemptID: UUID,
        quizID: QuizID,
        quizItemID: QuizItemID,
        packageVersion: Int,
        answer: String,
        selectedOptionIDs: [UUID] = [],
        scoreFraction: Double,
        feedback: String,
        attemptedAt: Date
    ) throws {
        guard packageVersion >= 1,
              metadata.provenance.kind == .user,
              scoreFraction.isFinite,
              (0...1).contains(scoreFraction),
              Set(selectedOptionIDs).count == selectedOptionIDs.count,
              answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw DomainValidationError.valueOutOfBounds("userResponse")
        }
        self.metadata = metadata
        self.attemptID = attemptID
        self.quizID = quizID
        self.quizItemID = quizItemID
        self.packageVersion = packageVersion
        self.answer = answer
        self.selectedOptionIDs = selectedOptionIDs
        self.scoreFraction = scoreFraction
        self.feedback = feedback
        self.attemptedAt = attemptedAt
    }

    private enum CodingKeys: String, CodingKey {
        case metadata
        case attemptID
        case quizID
        case quizItemID
        case packageVersion
        case answer
        case selectedOptionIDs
        case scoreFraction
        case feedback
        case attemptedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let metadata = try container.decode(
            RecordMetadata<UserResponseID>.self,
            forKey: .metadata
        )
        try self.init(
            metadata: metadata,
            // No v1 workspace persisted responses, but this deterministic
            // fallback keeps standalone legacy response JSON decodable.
            attemptID: container.decodeIfPresent(UUID.self, forKey: .attemptID)
                ?? metadata.id.rawValue,
            quizID: container.decode(QuizID.self, forKey: .quizID),
            quizItemID: container.decode(QuizItemID.self, forKey: .quizItemID),
            packageVersion: container.decode(Int.self, forKey: .packageVersion),
            answer: container.decode(String.self, forKey: .answer),
            selectedOptionIDs: container.decode([UUID].self, forKey: .selectedOptionIDs),
            scoreFraction: container.decode(Double.self, forKey: .scoreFraction),
            feedback: container.decode(String.self, forKey: .feedback),
            attemptedAt: container.decode(Date.self, forKey: .attemptedAt)
        )
    }
}

/// Typed, replayable result produced by the deterministic quiz evaluator.
/// Completion validation replays the referenced responses and never trusts the
/// stored fraction by itself.
public struct QuizResultEvidence: Codable, Hashable, Sendable {
    public static let currentScorerVersion = 1

    public let attemptID: UUID
    public let quizID: QuizID
    public let packageID: GuidedLearningPackageID
    public let packageVersion: Int
    public let responseIDs: [UserResponseID]
    public let scoreFraction: Double
    public let evidenceLinkIDs: [EvidenceLinkID]
    public let scoredAt: Date
    public let scorerVersion: Int

    public init(
        attemptID: UUID,
        quizID: QuizID,
        packageID: GuidedLearningPackageID,
        packageVersion: Int,
        responseIDs: [UserResponseID],
        scoreFraction: Double,
        evidenceLinkIDs: [EvidenceLinkID],
        scoredAt: Date,
        scorerVersion: Int = QuizResultEvidence.currentScorerVersion
    ) throws {
        guard packageVersion >= 1,
              responseIDs.isEmpty == false,
              Set(responseIDs).count == responseIDs.count,
              scoreFraction.isFinite,
              (0...1).contains(scoreFraction),
              evidenceLinkIDs.isEmpty == false,
              Set(evidenceLinkIDs).count == evidenceLinkIDs.count,
              scorerVersion == Self.currentScorerVersion else {
            throw DomainValidationError.invalidField("quizResultEvidence")
        }
        self.attemptID = attemptID
        self.quizID = quizID
        self.packageID = packageID
        self.packageVersion = packageVersion
        self.responseIDs = responseIDs
        self.scoreFraction = scoreFraction
        self.evidenceLinkIDs = evidenceLinkIDs
        self.scoredAt = scoredAt
        self.scorerVersion = scorerVersion
    }

    private enum CodingKeys: String, CodingKey {
        case attemptID
        case quizID
        case packageID
        case packageVersion
        case responseIDs
        case scoreFraction
        case evidenceLinkIDs
        case scoredAt
        case scorerVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            attemptID: container.decode(UUID.self, forKey: .attemptID),
            quizID: container.decode(QuizID.self, forKey: .quizID),
            packageID: container.decode(GuidedLearningPackageID.self, forKey: .packageID),
            packageVersion: container.decode(Int.self, forKey: .packageVersion),
            responseIDs: container.decode([UserResponseID].self, forKey: .responseIDs),
            scoreFraction: container.decode(Double.self, forKey: .scoreFraction),
            evidenceLinkIDs: container.decode([EvidenceLinkID].self, forKey: .evidenceLinkIDs),
            scoredAt: container.decode(Date.self, forKey: .scoredAt),
            scorerVersion: container.decode(Int.self, forKey: .scorerVersion)
        )
    }
}

public struct GuidedLearningPackage: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<GuidedLearningPackageID>
    public let version: Int
    public let dailyActionID: DailyActionID
    public let ultimateGoalID: UltimateGoalID
    public let goalID: GoalID
    public let milestoneID: MilestoneID
    public var title: String
    public var whyToday: String
    public var estimatedMinutes: Int
    public var difficulty: ActionDifficulty
    public var learningObjectives: [LearningObjective]
    public var prerequisites: [Prerequisite]
    public var sourceReadings: [SourceReading]
    public var summary: String
    public var highlightIDs: [HighlightID]
    public var corePoints: [GroundedPoint]
    public var definitions: [TermDefinition]
    public var applications: [GroundedPoint]
    public var limitationsAndRisks: [GroundedPoint]
    public var knowledgeConceptIDs: [KnowledgeConceptID]
    public var guidedQuestions: [GuidedQuestion]
    public var quiz: Quiz?
    public var requiredOutput: RequiredOutput
    public var completionCriteria: [CompletionCriterion]
    public var nextStepTitle: String
    public var generatedBy: Provenance
    public var generatedAt: Date

    public init(
        metadata: RecordMetadata<GuidedLearningPackageID>,
        version: Int,
        dailyActionID: DailyActionID,
        ultimateGoalID: UltimateGoalID,
        goalID: GoalID,
        milestoneID: MilestoneID,
        title: String,
        whyToday: String,
        estimatedMinutes: Int,
        difficulty: ActionDifficulty,
        learningObjectives: [LearningObjective],
        prerequisites: [Prerequisite],
        sourceReadings: [SourceReading],
        summary: String,
        highlightIDs: [HighlightID],
        corePoints: [GroundedPoint],
        definitions: [TermDefinition],
        applications: [GroundedPoint],
        limitationsAndRisks: [GroundedPoint],
        knowledgeConceptIDs: [KnowledgeConceptID],
        guidedQuestions: [GuidedQuestion],
        quiz: Quiz?,
        requiredOutput: RequiredOutput,
        completionCriteria: [CompletionCriterion],
        nextStepTitle: String,
        generatedBy: Provenance,
        generatedAt: Date
    ) throws {
        guard version >= 1, (1...1_440).contains(estimatedMinutes),
              title.isEmpty == false, whyToday.isEmpty == false,
              learningObjectives.isEmpty == false,
              sourceReadings.contains(where: \.isRequired),
              corePoints.isEmpty == false,
              completionCriteria.isEmpty == false,
              nextStepTitle.isEmpty == false else {
            throw DomainValidationError.invalidField("guidedLearningPackage")
        }
        let objectiveIDs = Set(learningObjectives.map(\.id))
        if let quiz {
            guard Set(quiz.learningObjectiveIDs).isSubset(of: objectiveIDs) else {
                throw DomainValidationError.relationshipMismatch(
                    "The quiz must use package learning objectives."
                )
            }
            if quiz.evaluationPolicy == .groundedDeterministicSingleChoiceV1 {
                let quizCriteria = completionCriteria.filter { $0.kind == .quizScore }
                guard quizCriteria.count == 1,
                      let criterion = quizCriteria.first,
                      criterion.requiresEvidence,
                      criterion.requiresUserConfirmation == false,
                      let threshold = criterion.threshold,
                      abs(threshold - quiz.passingFraction) < 0.000_000_001 else {
                    throw DomainValidationError.relationshipMismatch(
                        "The strict package quiz and completion threshold must agree."
                    )
                }
            }
        }
        self.metadata = metadata
        self.version = version
        self.dailyActionID = dailyActionID
        self.ultimateGoalID = ultimateGoalID
        self.goalID = goalID
        self.milestoneID = milestoneID
        self.title = title
        self.whyToday = whyToday
        self.estimatedMinutes = estimatedMinutes
        self.difficulty = difficulty
        self.learningObjectives = learningObjectives
        self.prerequisites = prerequisites
        self.sourceReadings = sourceReadings
        self.summary = summary
        self.highlightIDs = highlightIDs
        self.corePoints = corePoints
        self.definitions = definitions
        self.applications = applications
        self.limitationsAndRisks = limitationsAndRisks
        self.knowledgeConceptIDs = knowledgeConceptIDs
        self.guidedQuestions = guidedQuestions
        self.quiz = quiz
        self.requiredOutput = requiredOutput
        self.completionCriteria = completionCriteria
        self.nextStepTitle = nextStepTitle
        self.generatedBy = generatedBy
        self.generatedAt = generatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case metadata
        case version
        case dailyActionID
        case ultimateGoalID
        case goalID
        case milestoneID
        case title
        case whyToday
        case estimatedMinutes
        case difficulty
        case learningObjectives
        case prerequisites
        case sourceReadings
        case summary
        case highlightIDs
        case corePoints
        case definitions
        case applications
        case limitationsAndRisks
        case knowledgeConceptIDs
        case guidedQuestions
        case quiz
        case requiredOutput
        case completionCriteria
        case nextStepTitle
        case generatedBy
        case generatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            metadata: container.decode(
                RecordMetadata<GuidedLearningPackageID>.self,
                forKey: .metadata
            ),
            version: container.decode(Int.self, forKey: .version),
            dailyActionID: container.decode(DailyActionID.self, forKey: .dailyActionID),
            ultimateGoalID: container.decode(UltimateGoalID.self, forKey: .ultimateGoalID),
            goalID: container.decode(GoalID.self, forKey: .goalID),
            milestoneID: container.decode(MilestoneID.self, forKey: .milestoneID),
            title: container.decode(String.self, forKey: .title),
            whyToday: container.decode(String.self, forKey: .whyToday),
            estimatedMinutes: container.decode(Int.self, forKey: .estimatedMinutes),
            difficulty: container.decode(ActionDifficulty.self, forKey: .difficulty),
            learningObjectives: container.decode(
                [LearningObjective].self,
                forKey: .learningObjectives
            ),
            prerequisites: container.decode([Prerequisite].self, forKey: .prerequisites),
            sourceReadings: container.decode([SourceReading].self, forKey: .sourceReadings),
            summary: container.decode(String.self, forKey: .summary),
            highlightIDs: container.decode([HighlightID].self, forKey: .highlightIDs),
            corePoints: container.decode([GroundedPoint].self, forKey: .corePoints),
            definitions: container.decode([TermDefinition].self, forKey: .definitions),
            applications: container.decode([GroundedPoint].self, forKey: .applications),
            limitationsAndRisks: container.decode(
                [GroundedPoint].self,
                forKey: .limitationsAndRisks
            ),
            knowledgeConceptIDs: container.decode(
                [KnowledgeConceptID].self,
                forKey: .knowledgeConceptIDs
            ),
            guidedQuestions: container.decode(
                [GuidedQuestion].self,
                forKey: .guidedQuestions
            ),
            quiz: container.decodeIfPresent(Quiz.self, forKey: .quiz),
            requiredOutput: container.decode(RequiredOutput.self, forKey: .requiredOutput),
            completionCriteria: container.decode(
                [CompletionCriterion].self,
                forKey: .completionCriteria
            ),
            nextStepTitle: container.decode(String.self, forKey: .nextStepTitle),
            generatedBy: container.decode(Provenance.self, forKey: .generatedBy),
            generatedAt: container.decode(Date.self, forKey: .generatedAt)
        )
    }
}

public enum KnowledgeRelation: String, Codable, CaseIterable, Hashable, Sendable {
    case requires
    case supports
    case contradicts
    case applies
    case exampleOf
    case sameAs
}

public struct KnowledgeConcept: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<KnowledgeConceptID>
    public var canonicalLabel: String
    public var aliases: [String]
    public var definition: String?
    public var masteryFraction: Double
    public var nextReviewDay: LocalDay?

    public init(
        metadata: RecordMetadata<KnowledgeConceptID>,
        canonicalLabel: String,
        aliases: [String] = [],
        definition: String? = nil,
        masteryFraction: Double = 0,
        nextReviewDay: LocalDay? = nil
    ) throws {
        guard canonicalLabel.isEmpty == false, (0...1).contains(masteryFraction) else {
            throw DomainValidationError.invalidField("knowledgeConcept")
        }
        self.metadata = metadata
        self.canonicalLabel = canonicalLabel
        self.aliases = aliases
        self.definition = definition
        self.masteryFraction = masteryFraction
        self.nextReviewDay = nextReviewDay
    }
}

public struct KnowledgeLink: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<KnowledgeLinkID>
    public let sourceConceptID: KnowledgeConceptID
    public let targetConceptID: KnowledgeConceptID
    public let relation: KnowledgeRelation
    public let evidenceLinkIDs: [EvidenceLinkID]

    public init(
        metadata: RecordMetadata<KnowledgeLinkID>,
        sourceConceptID: KnowledgeConceptID,
        targetConceptID: KnowledgeConceptID,
        relation: KnowledgeRelation,
        evidenceLinkIDs: [EvidenceLinkID]
    ) throws {
        guard sourceConceptID != targetConceptID else {
            throw DomainValidationError.invalidField("knowledge link self reference")
        }
        self.metadata = metadata
        self.sourceConceptID = sourceConceptID
        self.targetConceptID = targetConceptID
        self.relation = relation
        self.evidenceLinkIDs = evidenceLinkIDs
    }
}
