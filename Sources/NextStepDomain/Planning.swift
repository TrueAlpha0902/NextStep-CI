import CryptoKit
import Foundation

private func isValidPlanningSHA256Hex(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
    }
}

public enum CalendarConstraintKind: String, Codable, CaseIterable, Hashable, Sendable {
    case busy
    case available
    case preferred
    case rest
}

public enum ConstraintRigidity: String, Codable, CaseIterable, Hashable, Sendable {
    case hard
    case soft
}

public struct CalendarConstraint: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<CalendarConstraintID>
    public var title: String
    public var block: TimeBlock
    public var kind: CalendarConstraintKind
    public var rigidity: ConstraintRigidity
    public var sourceDocumentID: SourceDocumentID?

    public init(
        metadata: RecordMetadata<CalendarConstraintID>,
        title: String,
        block: TimeBlock,
        kind: CalendarConstraintKind,
        rigidity: ConstraintRigidity,
        sourceDocumentID: SourceDocumentID? = nil
    ) throws {
        guard title.isEmpty == false else {
            throw DomainValidationError.invalidField("calendarConstraint")
        }
        self.metadata = metadata
        self.title = title
        self.block = block
        self.kind = kind
        self.rigidity = rigidity
        self.sourceDocumentID = sourceDocumentID
    }
}

public struct ScheduledAction: Codable, Hashable, Sendable {
    public let actionID: DailyActionID
    public let day: LocalDay
    public let plannedMinutes: Int
    public let order: Int
    public let reasonCodes: [PlanningReasonCode]
    public let isLocked: Bool

    private enum CodingKeys: String, CodingKey {
        case actionID
        case day
        case plannedMinutes
        case order
        case reasonCodes
        case isLocked
    }

    public init(
        actionID: DailyActionID,
        day: LocalDay,
        plannedMinutes: Int,
        order: Int,
        reasonCodes: [PlanningReasonCode],
        isLocked: Bool
    ) throws {
        guard plannedMinutes > 0, order >= 0 else {
            throw DomainValidationError.valueOutOfBounds("scheduledAction")
        }
        self.actionID = actionID
        self.day = day
        self.plannedMinutes = plannedMinutes
        self.order = order
        self.reasonCodes = reasonCodes
        self.isLocked = isLocked
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            actionID: container.decode(DailyActionID.self, forKey: .actionID),
            day: container.decode(LocalDay.self, forKey: .day),
            plannedMinutes: container.decode(Int.self, forKey: .plannedMinutes),
            order: container.decode(Int.self, forKey: .order),
            reasonCodes: container.decode([PlanningReasonCode].self, forKey: .reasonCodes),
            isLocked: container.decode(Bool.self, forKey: .isLocked)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(actionID, forKey: .actionID)
        try container.encode(day, forKey: .day)
        try container.encode(plannedMinutes, forKey: .plannedMinutes)
        try container.encode(order, forKey: .order)
        try container.encode(reasonCodes, forKey: .reasonCodes)
        try container.encode(isLocked, forKey: .isLocked)
    }
}

public enum PlanningRiskKind: String, Codable, CaseIterable, Hashable, Sendable {
    case hardDeadlineAtRisk
    case insufficientCapacity
    case blockedDependency
    case missingSource
    case overloadedDay
    case unscheduledRequiredAction
}

public enum RiskSeverity: String, Codable, CaseIterable, Hashable, Sendable {
    case info
    case warning
    case critical
}

public struct PlanningRisk: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let kind: PlanningRiskKind
    public let severity: RiskSeverity
    public let actionID: DailyActionID?
    public let milestoneID: MilestoneID?
    public let message: String

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case severity
        case actionID
        case milestoneID
        case message
    }

    public init(
        id: UUID = UUID(),
        kind: PlanningRiskKind,
        severity: RiskSeverity,
        actionID: DailyActionID? = nil,
        milestoneID: MilestoneID? = nil,
        message: String
    ) throws {
        guard message.isEmpty == false else {
            throw DomainValidationError.invalidField("planningRisk")
        }
        self.id = id
        self.kind = kind
        self.severity = severity
        self.actionID = actionID
        self.milestoneID = milestoneID
        self.message = message
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: container.decode(UUID.self, forKey: .id),
            kind: container.decode(PlanningRiskKind.self, forKey: .kind),
            severity: container.decode(RiskSeverity.self, forKey: .severity),
            actionID: container.decodeIfPresent(DailyActionID.self, forKey: .actionID),
            milestoneID: container.decodeIfPresent(MilestoneID.self, forKey: .milestoneID),
            message: container.decode(String.self, forKey: .message)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(severity, forKey: .severity)
        try container.encodeIfPresent(actionID, forKey: .actionID)
        try container.encodeIfPresent(milestoneID, forKey: .milestoneID)
        try container.encode(message, forKey: .message)
    }
}

public struct RejectedAction: Codable, Hashable, Sendable {
    public let actionID: DailyActionID
    public let reason: PlanningRiskKind
    public let detail: String

    public init(actionID: DailyActionID, reason: PlanningRiskKind, detail: String) {
        self.actionID = actionID
        self.reason = reason
        self.detail = detail
    }
}

public struct PlanningDecision: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<PlanningDecisionID>
    public let engineVersion: String
    public let inputSnapshotSHA256: String
    public let horizonStart: LocalDay
    public let horizonEnd: LocalDay
    public let assignments: [ScheduledAction]
    public let rejectedActions: [RejectedAction]
    public let risks: [PlanningRisk]
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case metadata
        case engineVersion
        case inputSnapshotSHA256
        case horizonStart
        case horizonEnd
        case assignments
        case rejectedActions
        case risks
        case createdAt
    }

    public init(
        metadata: RecordMetadata<PlanningDecisionID>,
        engineVersion: String,
        inputSnapshotSHA256: String,
        horizonStart: LocalDay,
        horizonEnd: LocalDay,
        assignments: [ScheduledAction],
        rejectedActions: [RejectedAction],
        risks: [PlanningRisk],
        createdAt: Date
    ) throws {
        guard engineVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              isValidPlanningSHA256Hex(inputSnapshotSHA256),
              horizonStart <= horizonEnd else {
            throw DomainValidationError.invalidField("planningDecision")
        }
        let assignedIDs = assignments.map(\.actionID)
        let rejectedIDs = rejectedActions.map(\.actionID)
        guard Set(assignedIDs).count == assignedIDs.count,
              Set(rejectedIDs).count == rejectedIDs.count,
              Set(assignedIDs).isDisjoint(with: Set(rejectedIDs)),
              assignments.allSatisfy({
                  $0.day >= horizonStart && $0.day <= horizonEnd
              }),
              Dictionary(grouping: assignments, by: \.day).values.allSatisfy({ sameDay in
                  Set(sameDay.map(\.order)).count == sameDay.count
              }) else {
            throw DomainValidationError.invalidField("duplicate plan assignment")
        }
        self.metadata = metadata
        self.engineVersion = engineVersion
        self.inputSnapshotSHA256 = inputSnapshotSHA256.lowercased()
        self.horizonStart = horizonStart
        self.horizonEnd = horizonEnd
        self.assignments = assignments
        self.rejectedActions = rejectedActions
        self.risks = risks
        self.createdAt = createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            metadata: container.decode(
                RecordMetadata<PlanningDecisionID>.self,
                forKey: .metadata
            ),
            engineVersion: container.decode(String.self, forKey: .engineVersion),
            inputSnapshotSHA256: container.decode(String.self, forKey: .inputSnapshotSHA256),
            horizonStart: container.decode(LocalDay.self, forKey: .horizonStart),
            horizonEnd: container.decode(LocalDay.self, forKey: .horizonEnd),
            assignments: container.decode([ScheduledAction].self, forKey: .assignments),
            rejectedActions: container.decode(
                [RejectedAction].self,
                forKey: .rejectedActions
            ),
            risks: container.decode([PlanningRisk].self, forKey: .risks),
            createdAt: container.decode(Date.self, forKey: .createdAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(engineVersion, forKey: .engineVersion)
        try container.encode(inputSnapshotSHA256, forKey: .inputSnapshotSHA256)
        try container.encode(horizonStart, forKey: .horizonStart)
        try container.encode(horizonEnd, forKey: .horizonEnd)
        try container.encode(assignments, forKey: .assignments)
        try container.encode(rejectedActions, forKey: .rejectedActions)
        try container.encode(risks, forKey: .risks)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

public enum ReplanTrigger: String, Codable, CaseIterable, Hashable, Sendable {
    case actionCompleted
    case actionDeferred
    case insufficientTime
    case actionTooDifficult
    case alreadyMastered
    case deadlineChanged
    case sourceImported
    case professorFeedback
    case gradeReceived
    case jobTargetAdded
    case availabilityChanged
    case manualRequest
}

public enum PlanChangeKind: String, Codable, CaseIterable, Hashable, Sendable {
    case add
    case move
    case remove
    case preserve
    case split
}

public struct PlanChange: Codable, Hashable, Sendable {
    public let kind: PlanChangeKind
    public let actionID: DailyActionID
    public let fromDay: LocalDay?
    public let toDay: LocalDay?
    public let explanation: String
    public let requiresConfirmation: Bool

    public init(
        kind: PlanChangeKind,
        actionID: DailyActionID,
        fromDay: LocalDay? = nil,
        toDay: LocalDay? = nil,
        explanation: String,
        requiresConfirmation: Bool
    ) throws {
        guard explanation.isEmpty == false else {
            throw DomainValidationError.invalidField("planChange")
        }
        self.kind = kind
        self.actionID = actionID
        self.fromDay = fromDay
        self.toDay = toDay
        self.explanation = explanation
        self.requiresConfirmation = requiresConfirmation
    }
}

public struct ReplanProposal: Codable, Hashable, Sendable {
    public let trigger: ReplanTrigger
    public let previousDecisionID: PlanningDecisionID?
    public let proposedDecision: PlanningDecision
    public let changes: [PlanChange]
    public let protectedFactDescriptions: [String]
    public let createdAt: Date

    public init(
        trigger: ReplanTrigger,
        previousDecisionID: PlanningDecisionID?,
        proposedDecision: PlanningDecision,
        changes: [PlanChange],
        protectedFactDescriptions: [String],
        createdAt: Date
    ) {
        self.trigger = trigger
        self.previousDecisionID = previousDecisionID
        self.proposedDecision = proposedDecision
        self.changes = changes
        self.protectedFactDescriptions = protectedFactDescriptions
        self.createdAt = createdAt
    }
}

public enum ReplanResolution: String, Codable, CaseIterable, Hashable, Sendable {
    case proposed
    case accepted
    case partiallyAccepted
    case rejected
}

public struct ReplanEvent: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<ReplanEventID>
    public let trigger: ReplanTrigger
    public let beforeDecisionID: PlanningDecisionID?
    public let afterDecisionID: PlanningDecisionID?
    public let protectedFactDescriptions: [String]
    public let resolution: ReplanResolution
    public let occurredAt: Date

    public init(
        metadata: RecordMetadata<ReplanEventID>,
        trigger: ReplanTrigger,
        beforeDecisionID: PlanningDecisionID? = nil,
        afterDecisionID: PlanningDecisionID? = nil,
        protectedFactDescriptions: [String] = [],
        resolution: ReplanResolution,
        occurredAt: Date
    ) {
        self.metadata = metadata
        self.trigger = trigger
        self.beforeDecisionID = beforeDecisionID
        self.afterDecisionID = afterDecisionID
        self.protectedFactDescriptions = protectedFactDescriptions
        self.resolution = resolution
        self.occurredAt = occurredAt
    }
}

public struct ProgressSnapshot: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<ProgressSnapshotID>
    public let capturedAt: Date
    public let planRevision: Int64
    public let ultimateGoalProgress: [UltimateGoalID: Double]
    public let goalProgress: [GoalID: Double]
    public let milestoneProgress: [MilestoneID: Double]
    public let completedActionCount: Int
    public let totalActionCount: Int
    public let atRiskMilestoneIDs: [MilestoneID]

    public init(
        metadata: RecordMetadata<ProgressSnapshotID>,
        capturedAt: Date,
        planRevision: Int64,
        ultimateGoalProgress: [UltimateGoalID: Double],
        goalProgress: [GoalID: Double],
        milestoneProgress: [MilestoneID: Double],
        completedActionCount: Int,
        totalActionCount: Int,
        atRiskMilestoneIDs: [MilestoneID]
    ) throws {
        let fractions = Array(ultimateGoalProgress.values)
            + Array(goalProgress.values)
            + Array(milestoneProgress.values)
        guard fractions.allSatisfy({ (0...1).contains($0) }),
              completedActionCount >= 0,
              totalActionCount >= completedActionCount,
              planRevision >= 0 else {
            throw DomainValidationError.valueOutOfBounds("progressSnapshot")
        }
        self.metadata = metadata
        self.capturedAt = capturedAt
        self.planRevision = planRevision
        self.ultimateGoalProgress = ultimateGoalProgress
        self.goalProgress = goalProgress
        self.milestoneProgress = milestoneProgress
        self.completedActionCount = completedActionCount
        self.totalActionCount = totalActionCount
        self.atRiskMilestoneIDs = atRiskMilestoneIDs
    }
}

/// The serializable v1 aggregate used by the deterministic planner and the
/// local projection. Large source binaries and native ink remain in the blob
/// store and are referenced by their records instead of being embedded here.
public struct NextStepWorkspaceSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var revision: Int64
    public var savedAt: Date
    public var userProfile: UserProfile
    public var ultimateGoals: [UltimateGoal]
    public var goals: [Goal]
    public var milestones: [Milestone]
    public var weeklyOutcomes: [WeeklyOutcome]
    public var dailyActions: [DailyAction]
    public var guidedPackages: [GuidedLearningPackage]
    public var sourceDocuments: [SourceDocument]
    public var paperSources: [PaperSource]
    public var sourceAnchors: [SourceAnchor]
    public var citations: [Citation]
    public var highlights: [Highlight]
    public var extractedClaims: [ExtractedClaim]
    public var evidenceLinks: [EvidenceLink]
    public var completionEvidence: [CompletionEvidence]
    public var userResponses: [UserResponse]
    public var calendarConstraints: [CalendarConstraint]
    public var planningDecisions: [PlanningDecision]
    public var replanEvents: [ReplanEvent]
    public var progressSnapshots: [ProgressSnapshot]

    public init(
        schemaVersion: Int = NextStepWorkspaceSnapshot.currentSchemaVersion,
        revision: Int64 = 0,
        savedAt: Date,
        userProfile: UserProfile,
        ultimateGoals: [UltimateGoal] = [],
        goals: [Goal] = [],
        milestones: [Milestone] = [],
        weeklyOutcomes: [WeeklyOutcome] = [],
        dailyActions: [DailyAction] = [],
        guidedPackages: [GuidedLearningPackage] = [],
        sourceDocuments: [SourceDocument] = [],
        paperSources: [PaperSource] = [],
        sourceAnchors: [SourceAnchor] = [],
        citations: [Citation] = [],
        highlights: [Highlight] = [],
        extractedClaims: [ExtractedClaim] = [],
        evidenceLinks: [EvidenceLink] = [],
        completionEvidence: [CompletionEvidence] = [],
        userResponses: [UserResponse] = [],
        calendarConstraints: [CalendarConstraint] = [],
        planningDecisions: [PlanningDecision] = [],
        replanEvents: [ReplanEvent] = [],
        progressSnapshots: [ProgressSnapshot] = []
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DomainValidationError.unsupportedSchema(
                entity: "workspace",
                found: schemaVersion,
                current: Self.currentSchemaVersion
            )
        }
        guard revision >= 0 else {
            throw DomainValidationError.valueOutOfBounds("workspace revision")
        }
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.savedAt = savedAt
        self.userProfile = userProfile
        self.ultimateGoals = ultimateGoals
        self.goals = goals
        self.milestones = milestones
        self.weeklyOutcomes = weeklyOutcomes
        self.dailyActions = dailyActions
        self.guidedPackages = guidedPackages
        self.sourceDocuments = sourceDocuments
        self.paperSources = paperSources
        self.sourceAnchors = sourceAnchors
        self.citations = citations
        self.highlights = highlights
        self.extractedClaims = extractedClaims
        self.evidenceLinks = evidenceLinks
        self.completionEvidence = completionEvidence
        self.userResponses = userResponses
        self.calendarConstraints = calendarConstraints
        self.planningDecisions = planningDecisions
        self.replanEvents = replanEvents
        self.progressSnapshots = progressSnapshots
        try validateRelationships()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case revision
        case savedAt
        case userProfile
        case ultimateGoals
        case goals
        case milestones
        case weeklyOutcomes
        case dailyActions
        case guidedPackages
        case sourceDocuments
        case paperSources
        case sourceAnchors
        case citations
        case highlights
        case extractedClaims
        case evidenceLinks
        case completionEvidence
        case userResponses
        case calendarConstraints
        case planningDecisions
        case replanEvents
        case progressSnapshots
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: container.decode(Int.self, forKey: .schemaVersion),
            revision: container.decode(Int64.self, forKey: .revision),
            savedAt: container.decode(Date.self, forKey: .savedAt),
            userProfile: container.decode(UserProfile.self, forKey: .userProfile),
            ultimateGoals: container.decode([UltimateGoal].self, forKey: .ultimateGoals),
            goals: container.decode([Goal].self, forKey: .goals),
            milestones: container.decode([Milestone].self, forKey: .milestones),
            weeklyOutcomes: container.decode([WeeklyOutcome].self, forKey: .weeklyOutcomes),
            dailyActions: container.decode([DailyAction].self, forKey: .dailyActions),
            guidedPackages: container.decode(
                [GuidedLearningPackage].self,
                forKey: .guidedPackages
            ),
            sourceDocuments: container.decode(
                [SourceDocument].self,
                forKey: .sourceDocuments
            ),
            paperSources: container.decode([PaperSource].self, forKey: .paperSources),
            sourceAnchors: container.decode([SourceAnchor].self, forKey: .sourceAnchors),
            citations: container.decode([Citation].self, forKey: .citations),
            highlights: container.decode([Highlight].self, forKey: .highlights),
            extractedClaims: container.decode(
                [ExtractedClaim].self,
                forKey: .extractedClaims
            ),
            evidenceLinks: container.decode([EvidenceLink].self, forKey: .evidenceLinks),
            completionEvidence: container.decode(
                [CompletionEvidence].self,
                forKey: .completionEvidence
            ),
            userResponses: container.decodeIfPresent(
                [UserResponse].self,
                forKey: .userResponses
            ) ?? [],
            calendarConstraints: container.decode(
                [CalendarConstraint].self,
                forKey: .calendarConstraints
            ),
            planningDecisions: container.decode(
                [PlanningDecision].self,
                forKey: .planningDecisions
            ),
            replanEvents: container.decode([ReplanEvent].self, forKey: .replanEvents),
            progressSnapshots: container.decode(
                [ProgressSnapshot].self,
                forKey: .progressSnapshots
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(revision, forKey: .revision)
        try container.encode(savedAt, forKey: .savedAt)
        try container.encode(userProfile, forKey: .userProfile)
        try container.encode(ultimateGoals, forKey: .ultimateGoals)
        try container.encode(goals, forKey: .goals)
        try container.encode(milestones, forKey: .milestones)
        try container.encode(weeklyOutcomes, forKey: .weeklyOutcomes)
        try container.encode(dailyActions, forKey: .dailyActions)
        try container.encode(guidedPackages, forKey: .guidedPackages)
        try container.encode(sourceDocuments, forKey: .sourceDocuments)
        try container.encode(paperSources, forKey: .paperSources)
        try container.encode(sourceAnchors, forKey: .sourceAnchors)
        try container.encode(citations, forKey: .citations)
        try container.encode(highlights, forKey: .highlights)
        try container.encode(extractedClaims, forKey: .extractedClaims)
        try container.encode(evidenceLinks, forKey: .evidenceLinks)
        try container.encode(completionEvidence, forKey: .completionEvidence)
        try container.encode(userResponses, forKey: .userResponses)
        try container.encode(calendarConstraints, forKey: .calendarConstraints)
        try container.encode(planningDecisions, forKey: .planningDecisions)
        try container.encode(replanEvents, forKey: .replanEvents)
        try container.encode(progressSnapshots, forKey: .progressSnapshots)
    }

    public func validateRelationships() throws {
        let ultimateGoalIDs = Set(ultimateGoals.map(\.metadata.id))
        let goalIDs = Set(goals.map(\.metadata.id))
        let milestoneIDs = Set(milestones.map(\.metadata.id))
        let actionIDs = Set(dailyActions.map(\.metadata.id))
        let packageIDs = Set(guidedPackages.map(\.metadata.id))
        let sourceIDs = Set(sourceDocuments.map(\.metadata.id))
        let sourceAnchorIDs = Set(sourceAnchors.map(\.metadata.id))
        let evidenceLinkIDs = Set(evidenceLinks.map(\.metadata.id))
        let completionEvidenceIDs = Set(completionEvidence.map(\.metadata.id))
        let responseIDs = Set(userResponses.map(\.metadata.id))
        let packageQuizPairs = guidedPackages.compactMap { package in
            package.quiz.map { (package: package, quiz: $0) }
        }
        let strictPackageQuizPairs = packageQuizPairs.filter {
            $0.quiz.evaluationPolicy == .groundedDeterministicSingleChoiceV1
        }
        let quizIDs = Set(packageQuizPairs.map { $0.quiz.metadata.id })

        guard ultimateGoalIDs.count == ultimateGoals.count,
              goalIDs.count == goals.count,
              milestoneIDs.count == milestones.count,
              actionIDs.count == dailyActions.count,
              packageIDs.count == guidedPackages.count,
              sourceIDs.count == sourceDocuments.count,
              sourceAnchorIDs.count == sourceAnchors.count,
              evidenceLinkIDs.count == evidenceLinks.count,
              completionEvidenceIDs.count == completionEvidence.count,
              responseIDs.count == userResponses.count,
              quizIDs.count == packageQuizPairs.count else {
            throw DomainValidationError.invalidField("duplicate workspace identifier")
        }
        guard goals.allSatisfy({ ultimateGoalIDs.contains($0.ultimateGoalID) }),
              milestones.allSatisfy({ goalIDs.contains($0.goalID) }),
              milestones.allSatisfy({ Set($0.dependencyIDs).isSubset(of: milestoneIDs) }),
              dailyActions.allSatisfy({ milestoneIDs.contains($0.milestoneID) }),
              dailyActions.allSatisfy({ Set($0.dependencyActionIDs).isSubset(of: actionIDs) }),
              dailyActions.allSatisfy({ Set($0.sourceDocumentIDs).isSubset(of: sourceIDs) }),
              dailyActions.allSatisfy({ $0.packageID.map(packageIDs.contains) ?? true }),
              guidedPackages.allSatisfy({ actionIDs.contains($0.dailyActionID) }) else {
            throw DomainValidationError.relationshipMismatch(
                "The workspace contains a dangling goal, action, package, or source relationship."
            )
        }

        let actionByID = Dictionary(uniqueKeysWithValues: dailyActions.map {
            ($0.metadata.id, $0)
        })
        let packageByID = Dictionary(uniqueKeysWithValues: guidedPackages.map {
            ($0.metadata.id, $0)
        })
        let packageAndQuizByQuizID = Dictionary(
            uniqueKeysWithValues: packageQuizPairs.map {
                ($0.quiz.metadata.id, ($0.package, $0.quiz))
            }
        )
        let sourceByID = Dictionary(uniqueKeysWithValues: sourceDocuments.map {
            ($0.metadata.id, $0)
        })
        let anchorByID = Dictionary(uniqueKeysWithValues: sourceAnchors.map {
            ($0.metadata.id, $0)
        })
        let evidenceByID = Dictionary(uniqueKeysWithValues: evidenceLinks.map {
            ($0.metadata.id, $0)
        })

        for pair in strictPackageQuizPairs {
            guard let action = actionByID[pair.package.dailyActionID],
                  action.packageID == pair.package.metadata.id,
                  action.completionCriteria == pair.package.completionCriteria else {
                throw DomainValidationError.relationshipMismatch(
                    "Strict quiz actions and packages must agree in both directions and criteria."
                )
            }
        }

        for package in guidedPackages {
            guard let quiz = package.quiz,
                  quiz.evaluationPolicy == .groundedDeterministicSingleChoiceV1 else {
                continue
            }
            let quizCriteria = package.completionCriteria.filter {
                $0.kind == .quizScore
            }
            guard quizCriteria.count == 1,
                  let criterion = quizCriteria.first,
                  criterion.requiresEvidence,
                  criterion.requiresUserConfirmation == false,
                  let threshold = criterion.threshold,
                  abs(threshold - quiz.passingFraction) < 0.000_000_001 else {
                throw DomainValidationError.relationshipMismatch(
                    "A strict package quiz and its completion threshold must agree."
                )
            }
        }

        for pair in strictPackageQuizPairs {
            guard let action = actionByID[pair.package.dailyActionID] else {
                throw DomainValidationError.relationshipMismatch(
                    "A quiz package must resolve to its daily action."
                )
            }
            let actionSourceIDs = Set(action.sourceDocumentIDs)
            for item in pair.quiz.items {
                guard item.evidenceLinkIDs.isEmpty == false else {
                    throw DomainValidationError.relationshipMismatch(
                        "Every quiz item must remain grounded in workspace evidence."
                    )
                }
                let correctOptionText: String?
                if item.kind == .multipleChoice,
                   let correctOptionID = item.correctOptionIDs.first {
                    correctOptionText = item.options.first {
                        $0.id == correctOptionID
                    }?.text
                } else {
                    correctOptionText = nil
                }
                for evidenceLinkID in item.evidenceLinkIDs {
                    guard let link = evidenceByID[evidenceLinkID],
                          link.subjectType == "QuizItem",
                          link.subjectID == item.id.rawValue,
                          link.relation == .supports,
                          link.verifiedBy == .deterministicEngine,
                          let anchor = anchorByID[link.anchorID],
                          actionSourceIDs.contains(anchor.sourceDocumentID),
                          pair.package.sourceReadings.contains(where: {
                              $0.sourceDocumentID == anchor.sourceDocumentID
                                  && $0.anchorIDs.contains(anchor.metadata.id)
                          }),
                          link.metadata.provenance.sourceDocumentIDs.contains(
                              anchor.sourceDocumentID
                          ),
                          anchor.verificationState == .contentHashVerified,
                          let quote = anchor.locator.nextStepQuizTextQuote,
                          anchor.quotedTextSHA256 == nextStepQuizSHA256(quote),
                          let source = sourceByID[anchor.sourceDocumentID],
                          source.metadata.id == anchor.sourceDocumentID,
                          source.contentSHA256 != nil,
                          source.verificationState == .contentHashVerified else {
                        throw DomainValidationError.relationshipMismatch(
                            "Quiz evidence must resolve through a verified item link and anchor."
                        )
                    }
                    if let correctOptionText {
                        guard quote.range(of: correctOptionText) != nil else {
                            throw DomainValidationError.relationshipMismatch(
                                "The verified quiz quote must contain the correct option text."
                            )
                        }
                    }
                }
            }
        }

        for response in userResponses {
            guard let (package, quiz) = packageAndQuizByQuizID[response.quizID],
                  response.metadata.provenance.kind == .user,
                  response.packageVersion == package.version,
                  let item = quiz.items.first(where: { $0.id == response.quizItemID })
            else {
                throw DomainValidationError.relationshipMismatch(
                    "A user response does not match its quiz, package version, or item."
                )
            }
            guard quiz.evaluationPolicy == .groundedDeterministicSingleChoiceV1 else {
                continue
            }
            guard item.kind == .multipleChoice,
                  response.selectedOptionIDs.count == 1,
                  let selectedOptionID = response.selectedOptionIDs.first,
                  let selectedOption = item.options.first(where: { $0.id == selectedOptionID })
            else {
                throw DomainValidationError.relationshipMismatch(
                    "A user response does not match its quiz, package version, item, or option."
                )
            }
            let expectedScore = item.correctOptionIDs.contains(selectedOptionID) ? 1.0 : 0.0
            guard response.scoreFraction == expectedScore,
                  response.answer == selectedOption.text,
                  response.feedback == item.answerExplanation else {
                throw DomainValidationError.relationshipMismatch(
                    "A user response contains a non-deterministic score or feedback."
                )
            }
        }

        for completion in completionEvidence {
            guard let action = actionByID[completion.actionID],
                  Set(completion.criterionIDs).isSubset(
                    of: Set(action.completionCriteria.map(\.id))
                  ),
                  completion.packageID == action.packageID else {
                throw DomainValidationError.relationshipMismatch(
                    "Completion evidence does not match its action or criteria."
                )
            }
            if let packageID = completion.packageID {
                guard let package = packageByID[packageID],
                      completion.packageVersion == package.version else {
                    throw DomainValidationError.relationshipMismatch(
                        "Completion evidence does not match its package version."
                    )
                }
            } else if completion.packageVersion != nil {
                throw DomainValidationError.relationshipMismatch(
                    "Completion evidence has a version without a package."
                )
            }

            guard let result = completion.quizResult else { continue }
            guard completion.kind == .quizResult,
                  completion.metadata.provenance.kind == .deterministicEngine,
                  completion.packageID == result.packageID,
                   completion.packageVersion == result.packageVersion,
                   let package = packageByID[result.packageID],
                   let quiz = package.quiz,
                   quiz.evaluationPolicy == .groundedDeterministicSingleChoiceV1,
                   quiz.metadata.id == result.quizID else {
                throw DomainValidationError.relationshipMismatch(
                    "Quiz completion evidence does not match its package quiz."
                )
            }
            let resultResponses = result.responseIDs.compactMap { responseID in
                userResponses.first { $0.metadata.id == responseID }
            }
            guard resultResponses.count == result.responseIDs.count,
                  resultResponses.allSatisfy({
                    $0.attemptID == result.attemptID
                        && $0.quizID == result.quizID
                        && $0.packageVersion == result.packageVersion
                  }),
                  Set(resultResponses.map(\.quizItemID)).count == resultResponses.count else {
                throw DomainValidationError.relationshipMismatch(
                    "Quiz result evidence references missing or mismatched responses."
                )
            }
            let responseByItemID = Dictionary(
                uniqueKeysWithValues: resultResponses.map { ($0.quizItemID, $0) }
            )
            guard responseByItemID.count == quiz.items.count,
                  quiz.items.allSatisfy({ responseByItemID[$0.id] != nil }) else {
                throw DomainValidationError.relationshipMismatch(
                    "Quiz result evidence must cover every quiz item exactly once."
                )
            }
            let correctCount = quiz.items.reduce(into: 0) { count, item in
                guard let response = responseByItemID[item.id],
                      let selected = response.selectedOptionIDs.first,
                      item.correctOptionIDs.contains(selected) else { return }
                count += 1
            }
            let expectedFraction = Double(correctCount) / Double(quiz.items.count)
            var expectedEvidenceLinkIDs: [EvidenceLinkID] = []
            var seenEvidenceLinkIDs = Set<EvidenceLinkID>()
            for item in quiz.items {
                for evidenceLinkID in item.evidenceLinkIDs
                    where seenEvidenceLinkIDs.insert(evidenceLinkID).inserted {
                    expectedEvidenceLinkIDs.append(evidenceLinkID)
                }
            }
            guard result.scoreFraction == expectedFraction,
                  result.evidenceLinkIDs == expectedEvidenceLinkIDs,
                  completion.measuredValue == result.scoreFraction else {
                throw DomainValidationError.relationshipMismatch(
                    "Quiz result evidence contains a tampered score or grounding set."
                )
            }
        }
    }
}

private func nextStepQuizSHA256(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
}

private extension SourceLocator {
    var nextStepQuizTextQuote: String? {
        switch self {
        case let .pdf(_, _, textQuote):
            textQuote
        case let .image(_, _, textQuote):
            textQuote
        case let .web(_, _, _, _, textQuote):
            textQuote
        case .note, .ink, .media:
            nil
        }
    }
}
