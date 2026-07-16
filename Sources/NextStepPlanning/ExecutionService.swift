import Foundation
import NextStepDomain

public enum ExecutionServiceError: Error, Equatable, LocalizedError, Sendable {
    case actionNotFound(DailyActionID)
    case actionIsLocked(DailyActionID)
    case actionAlreadyCompleted(DailyActionID)
    case missingCompletionEvidence([UUID])
    case conflictingCompletionEvidence(CompletionEvidenceID)
    case completionRejected(CompletionValidationError)
    case lockedAssignmentChanged(DailyActionID)

    public var errorDescription: String? {
        switch self {
        case let .actionNotFound(id):
            "Action \(id) was not found."
        case let .actionIsLocked(id):
            "Action \(id) is a protected user commitment."
        case let .actionAlreadyCompleted(id):
            "Action \(id) is already complete."
        case let .missingCompletionEvidence(ids):
            "Completion evidence is missing for criteria: \(ids.map(\.uuidString).joined(separator: ", "))."
        case let .conflictingCompletionEvidence(id):
            "Completion evidence \(id) was submitted with conflicting content."
        case let .completionRejected(error):
            error.localizedDescription
        case let .lockedAssignmentChanged(id):
            "The proposed plan attempted to move locked action \(id)."
        }
    }
}

public enum QuizEvaluationError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedEvaluationPolicy(QuizID)
    case itemNotFound(QuizItemID)
    case unsupportedItemKind(QuizItemID)
    case optionNotFound(itemID: QuizItemID, optionID: UUID)
    case emptyAttempt
    case mixedAttempts
    case responseProvenanceMismatch(UserResponseID)
    case responseQuizMismatch(UserResponseID)
    case packageVersionMismatch(UserResponseID)
    case duplicateItemResponse(QuizItemID)
    case missingItemResponses([QuizItemID])
    case tamperedScore(UserResponseID, expected: Double, actual: Double)
    case tamperedAnswer(UserResponseID)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedEvaluationPolicy(id):
            "Quiz \(id) did not opt in to grounded deterministic scoring."
        case let .itemNotFound(id):
            "Quiz item \(id) was not found."
        case let .unsupportedItemKind(id):
            "Quiz item \(id) is not deterministic single-answer multiple choice."
        case let .optionNotFound(itemID, optionID):
            "Option \(optionID) does not belong to quiz item \(itemID)."
        case .emptyAttempt:
            "A quiz attempt must contain responses."
        case .mixedAttempts:
            "Quiz responses from different attempts cannot be scored together."
        case let .responseProvenanceMismatch(id):
            "Response \(id) is not recorded as a user answer."
        case let .responseQuizMismatch(id):
            "Response \(id) belongs to a different quiz."
        case let .packageVersionMismatch(id):
            "Response \(id) belongs to a different package version."
        case let .duplicateItemResponse(id):
            "Quiz item \(id) has more than one response in the same attempt."
        case let .missingItemResponses(ids):
            "The quiz attempt is missing items: \(ids.map(\.description).joined(separator: ", "))."
        case let .tamperedScore(id, expected, actual):
            "Response \(id) stores score \(actual), but deterministic scoring produced \(expected)."
        case let .tamperedAnswer(id):
            "Response \(id) does not match the selected option or canonical feedback."
        }
    }
}

/// Scores the first canonical quiz format: grounded, single-answer multiple
/// choice. No model output or caller-provided score participates in grading.
public struct QuizEvaluator: Sendable {
    public init() {}

    public func makeResponse(
        metadata: RecordMetadata<UserResponseID>,
        attemptID: UUID,
        quiz: Quiz,
        quizItemID: QuizItemID,
        packageVersion: Int,
        selectedOptionID: UUID,
        attemptedAt: Date
    ) throws -> UserResponse {
        guard quiz.evaluationPolicy == .groundedDeterministicSingleChoiceV1 else {
            throw QuizEvaluationError.unsupportedEvaluationPolicy(quiz.metadata.id)
        }
        guard let item = quiz.items.first(where: { $0.id == quizItemID }) else {
            throw QuizEvaluationError.itemNotFound(quizItemID)
        }
        guard item.kind == .multipleChoice, item.correctOptionIDs.count == 1 else {
            throw QuizEvaluationError.unsupportedItemKind(quizItemID)
        }
        guard let option = item.options.first(where: { $0.id == selectedOptionID }) else {
            throw QuizEvaluationError.optionNotFound(
                itemID: quizItemID,
                optionID: selectedOptionID
            )
        }
        let score = item.correctOptionIDs[0] == selectedOptionID ? 1.0 : 0.0
        return try UserResponse(
            metadata: metadata,
            attemptID: attemptID,
            quizID: quiz.metadata.id,
            quizItemID: quizItemID,
            packageVersion: packageVersion,
            answer: option.text,
            selectedOptionIDs: [selectedOptionID],
            scoreFraction: score,
            feedback: item.answerExplanation,
            attemptedAt: attemptedAt
        )
    }

    public func evaluate(
        quiz: Quiz,
        packageID: GuidedLearningPackageID,
        packageVersion: Int,
        responses: [UserResponse],
        scoredAt: Date
    ) throws -> QuizResultEvidence {
        guard quiz.evaluationPolicy == .groundedDeterministicSingleChoiceV1 else {
            throw QuizEvaluationError.unsupportedEvaluationPolicy(quiz.metadata.id)
        }
        guard let attemptID = responses.first?.attemptID else {
            throw QuizEvaluationError.emptyAttempt
        }
        guard responses.allSatisfy({ $0.attemptID == attemptID }) else {
            throw QuizEvaluationError.mixedAttempts
        }

        var responseByItemID: [QuizItemID: UserResponse] = [:]
        for response in responses {
            guard response.metadata.provenance.kind == .user else {
                throw QuizEvaluationError.responseProvenanceMismatch(response.metadata.id)
            }
            guard response.quizID == quiz.metadata.id else {
                throw QuizEvaluationError.responseQuizMismatch(response.metadata.id)
            }
            guard response.packageVersion == packageVersion else {
                throw QuizEvaluationError.packageVersionMismatch(response.metadata.id)
            }
            guard responseByItemID.updateValue(response, forKey: response.quizItemID) == nil else {
                throw QuizEvaluationError.duplicateItemResponse(response.quizItemID)
            }
        }
        let quizItemIDs = Set(quiz.items.map(\.id))
        let unexpectedItemIDs = Set(responseByItemID.keys).subtracting(quizItemIDs)
        if let unexpected = unexpectedItemIDs.sorted().first {
            throw QuizEvaluationError.itemNotFound(unexpected)
        }
        let missing = quiz.items.map(\.id).filter { responseByItemID[$0] == nil }
        guard missing.isEmpty else {
            throw QuizEvaluationError.missingItemResponses(missing)
        }

        var correctCount = 0
        var orderedResponseIDs: [UserResponseID] = []
        var evidenceLinkIDs: [EvidenceLinkID] = []
        var seenEvidenceLinkIDs = Set<EvidenceLinkID>()
        for item in quiz.items {
            guard item.kind == .multipleChoice, item.correctOptionIDs.count == 1 else {
                throw QuizEvaluationError.unsupportedItemKind(item.id)
            }
            let response = responseByItemID[item.id]!
            guard response.selectedOptionIDs.count == 1,
                  let selectedOptionID = response.selectedOptionIDs.first,
                  let option = item.options.first(where: { $0.id == selectedOptionID }) else {
                throw QuizEvaluationError.tamperedAnswer(response.metadata.id)
            }
            let expectedScore = item.correctOptionIDs[0] == selectedOptionID ? 1.0 : 0.0
            guard response.scoreFraction == expectedScore else {
                throw QuizEvaluationError.tamperedScore(
                    response.metadata.id,
                    expected: expectedScore,
                    actual: response.scoreFraction
                )
            }
            guard response.answer == option.text,
                  response.feedback == item.answerExplanation else {
                throw QuizEvaluationError.tamperedAnswer(response.metadata.id)
            }
            if expectedScore == 1 { correctCount += 1 }
            orderedResponseIDs.append(response.metadata.id)
            for evidenceLinkID in item.evidenceLinkIDs
                where seenEvidenceLinkIDs.insert(evidenceLinkID).inserted {
                evidenceLinkIDs.append(evidenceLinkID)
            }
        }

        return try QuizResultEvidence(
            attemptID: attemptID,
            quizID: quiz.metadata.id,
            packageID: packageID,
            packageVersion: packageVersion,
            responseIDs: orderedResponseIDs,
            scoreFraction: Double(correctCount) / Double(quiz.items.count),
            evidenceLinkIDs: evidenceLinkIDs,
            scoredAt: scoredAt
        )
    }
}

public enum CompletionValidationError: Error, Equatable, LocalizedError, Sendable {
    case actionPackageMismatch
    case duplicateEvidence(CompletionEvidenceID)
    case evidenceActionMismatch(CompletionEvidenceID)
    case evidencePackageMismatch(CompletionEvidenceID)
    case evidenceCriterionMismatch(CompletionEvidenceID)
    case missingEvidence([UUID])
    case wrongEvidenceKind(
        criterionID: UUID,
        expected: CompletionEvidenceKind,
        actual: CompletionEvidenceKind
    )
    case missingMeasuredValue(UUID)
    case belowThreshold(criterionID: UUID, required: Double, actual: Double)
    case userConfirmationRequired(UUID)
    case quizUnavailable(UUID)
    case unsupportedQuizPolicy(UUID)
    case unreplayableQuizEvidence(CompletionEvidenceID)
    case quizResultMismatch(UUID)
    case quizEvaluation(QuizEvaluationError)

    public var errorDescription: String? {
        switch self {
        case .actionPackageMismatch:
            "The action and guided package do not match."
        case let .duplicateEvidence(id):
            "Completion evidence \(id) is duplicated."
        case let .evidenceActionMismatch(id):
            "Completion evidence \(id) belongs to another action."
        case let .evidencePackageMismatch(id):
            "Completion evidence \(id) belongs to another package version."
        case let .evidenceCriterionMismatch(id):
            "Completion evidence \(id) claims a criterion that is not part of the action."
        case let .missingEvidence(ids):
            "Completion evidence is missing for criteria: \(ids.map(\.uuidString).joined(separator: ", "))."
        case let .wrongEvidenceKind(criterionID, expected, actual):
            "Criterion \(criterionID) requires \(expected.rawValue), not \(actual.rawValue)."
        case let .missingMeasuredValue(id):
            "Criterion \(id) requires a deterministic measured value."
        case let .belowThreshold(criterionID, required, actual):
            "Criterion \(criterionID) requires \(required), but the result was \(actual)."
        case let .userConfirmationRequired(id):
            "Criterion \(id) requires explicit user-confirmed evidence."
        case let .quizUnavailable(id):
            "Criterion \(id) refers to a quiz that is unavailable."
        case let .unsupportedQuizPolicy(id):
            "Criterion \(id) refers to a quiz without the grounded deterministic policy."
        case let .unreplayableQuizEvidence(id):
            "Legacy quiz evidence \(id) has no typed result and cannot satisfy completion."
        case let .quizResultMismatch(id):
            "Criterion \(id) contains quiz evidence that cannot be replayed."
        case let .quizEvaluation(error):
            error.localizedDescription
        }
    }
}

public struct CompletionValidationResult: Equatable, Sendable {
    public let satisfiedCriterionIDs: [UUID]
    public let acceptedEvidenceIDs: [CompletionEvidenceID]

    public init(
        satisfiedCriterionIDs: [UUID],
        acceptedEvidenceIDs: [CompletionEvidenceID]
    ) {
        self.satisfiedCriterionIDs = satisfiedCriterionIDs
        self.acceptedEvidenceIDs = acceptedEvidenceIDs
    }
}

/// Applies criterion-kind-specific completion rules and fails closed when a
/// criterion has no deterministic representation yet.
public struct CompletionValidator: Sendable {
    public init() {}

    public func validate(
        action: DailyAction,
        package: GuidedLearningPackage?,
        evidence: [CompletionEvidence],
        userResponses: [UserResponse]
    ) throws -> CompletionValidationResult {
        guard package?.metadata.id == action.packageID,
              action.packageID == nil || package != nil else {
            throw CompletionValidationError.actionPackageMismatch
        }
        if let package {
            guard package.dailyActionID == action.metadata.id,
                  package.completionCriteria == action.completionCriteria else {
                throw CompletionValidationError.actionPackageMismatch
            }
            if let quiz = package.quiz,
               quiz.evaluationPolicy == .groundedDeterministicSingleChoiceV1 {
                let quizCriteria = package.completionCriteria.filter {
                    $0.kind == .quizScore
                }
                guard quizCriteria.count == 1,
                      let criterion = quizCriteria.first,
                      criterion.requiresEvidence,
                      criterion.requiresUserConfirmation == false,
                      let threshold = criterion.threshold,
                      abs(threshold - quiz.passingFraction) < 0.000_000_001 else {
                    throw CompletionValidationError.actionPackageMismatch
                }
            }
        }
        var evidenceIDs = Set<CompletionEvidenceID>()
        let actionCriterionIDs = Set(action.completionCriteria.map(\.id))
        for item in evidence {
            guard evidenceIDs.insert(item.metadata.id).inserted else {
                throw CompletionValidationError.duplicateEvidence(item.metadata.id)
            }
            guard item.actionID == action.metadata.id else {
                throw CompletionValidationError.evidenceActionMismatch(item.metadata.id)
            }
            guard Set(item.criterionIDs).isSubset(of: actionCriterionIDs) else {
                throw CompletionValidationError.evidenceCriterionMismatch(item.metadata.id)
            }
            if let package {
                guard item.packageID == package.metadata.id,
                      item.packageVersion == package.version else {
                    throw CompletionValidationError.evidencePackageMismatch(item.metadata.id)
                }
            } else if item.packageID != nil || item.packageVersion != nil {
                throw CompletionValidationError.evidencePackageMismatch(item.metadata.id)
            }
        }

        let requiredCriteria = action.completionCriteria.filter {
            $0.requiresEvidence || $0.requiresUserConfirmation
        }
        let missing = requiredCriteria
            .filter { criterion in
                evidence.contains { $0.criterionIDs.contains(criterion.id) } == false
            }
            .map(\.id)
        guard missing.isEmpty else {
            throw CompletionValidationError.missingEvidence(missing)
        }

        var acceptedEvidenceIDs: [CompletionEvidenceID] = []
        for criterion in requiredCriteria {
            let candidates = evidence
                .filter { $0.criterionIDs.contains(criterion.id) }
                .sorted { $0.metadata.id < $1.metadata.id }
            let expectedKind = evidenceKind(for: criterion.kind)
            let matching = candidates.filter { $0.kind == expectedKind }
            guard matching.isEmpty == false else {
                throw CompletionValidationError.wrongEvidenceKind(
                    criterionID: criterion.id,
                    expected: expectedKind,
                    actual: candidates[0].kind
                )
            }

            var accepted: CompletionEvidence?
            var lastError: CompletionValidationError?
            for candidate in matching {
                do {
                    try validate(
                        candidate,
                        for: criterion,
                        package: package,
                        userResponses: userResponses
                    )
                    accepted = candidate
                    break
                } catch let error as CompletionValidationError {
                    lastError = error
                }
            }
            guard let accepted else {
                throw lastError ?? CompletionValidationError.missingEvidence([criterion.id])
            }
            acceptedEvidenceIDs.append(accepted.metadata.id)
        }

        return CompletionValidationResult(
            satisfiedCriterionIDs: requiredCriteria.map(\.id),
            acceptedEvidenceIDs: acceptedEvidenceIDs
        )
    }

    private func evidenceKind(
        for criterionKind: CompletionCriterionKind
    ) -> CompletionEvidenceKind {
        switch criterionKind {
        case .outputExists, .minimumWordCount: .artifactReference
        case .quizScore: .quizResult
        case .checklistComplete: .checklist
        case .sourceOpened: .sourceAccess
        case .userAttestation: .userAttestation
        case .externalConfirmation: .externalReference
        }
    }

    private func validate(
        _ evidence: CompletionEvidence,
        for criterion: CompletionCriterion,
        package: GuidedLearningPackage?,
        userResponses: [UserResponse]
    ) throws {
        if criterion.requiresUserConfirmation,
           evidence.metadata.provenance.kind != .user {
            throw CompletionValidationError.userConfirmationRequired(criterion.id)
        }
        switch criterion.kind {
        case .minimumWordCount:
            guard let actual = evidence.measuredValue else {
                throw CompletionValidationError.missingMeasuredValue(criterion.id)
            }
            let required = criterion.threshold!
            guard actual >= required else {
                throw CompletionValidationError.belowThreshold(
                    criterionID: criterion.id,
                    required: required,
                    actual: actual
                )
            }
        case .quizScore:
            guard evidence.hasReplayableQuizResult else {
                throw CompletionValidationError.unreplayableQuizEvidence(evidence.metadata.id)
            }
            guard let package, let quiz = package.quiz else {
                throw CompletionValidationError.quizUnavailable(criterion.id)
            }
            guard quiz.evaluationPolicy == .groundedDeterministicSingleChoiceV1 else {
                throw CompletionValidationError.unsupportedQuizPolicy(criterion.id)
            }
            guard evidence.hasReplayableQuizResult,
                  let suppliedResult = evidence.quizResult,
                  evidence.metadata.provenance.kind == .deterministicEngine,
                  suppliedResult.quizID == quiz.metadata.id,
                  suppliedResult.packageID == package.metadata.id,
                  suppliedResult.packageVersion == package.version else {
                throw CompletionValidationError.quizResultMismatch(criterion.id)
            }
            guard Set(userResponses.map(\.metadata.id)).count == userResponses.count else {
                throw CompletionValidationError.quizResultMismatch(criterion.id)
            }
            let responseByID = Dictionary(
                uniqueKeysWithValues: userResponses.map { ($0.metadata.id, $0) }
            )
            let responses = suppliedResult.responseIDs.compactMap { responseByID[$0] }
            guard responses.count == suppliedResult.responseIDs.count else {
                throw CompletionValidationError.quizResultMismatch(criterion.id)
            }
            let replayed: QuizResultEvidence
            do {
                replayed = try QuizEvaluator().evaluate(
                    quiz: quiz,
                    packageID: package.metadata.id,
                    packageVersion: package.version,
                    responses: responses,
                    scoredAt: suppliedResult.scoredAt
                )
            } catch let error as QuizEvaluationError {
                throw CompletionValidationError.quizEvaluation(error)
            }
            guard replayed == suppliedResult,
                  evidence.measuredValue == suppliedResult.scoreFraction else {
                throw CompletionValidationError.quizResultMismatch(criterion.id)
            }
            let required = criterion.threshold!
            guard suppliedResult.scoreFraction >= required else {
                throw CompletionValidationError.belowThreshold(
                    criterionID: criterion.id,
                    required: required,
                    actual: suppliedResult.scoreFraction
                )
            }
        case .outputExists, .checklistComplete, .sourceOpened,
             .userAttestation, .externalConfirmation:
            break
        }
    }
}

public struct ExecutionService: Sendable {
    public init() {}

    public func startAction(
        _ actionID: DailyActionID,
        in snapshot: NextStepWorkspaceSnapshot,
        at now: Date
    ) throws -> NextStepWorkspaceSnapshot {
        var result = snapshot
        guard let index = result.dailyActions.firstIndex(where: { $0.metadata.id == actionID }) else {
            throw ExecutionServiceError.actionNotFound(actionID)
        }
        if result.dailyActions[index].status == .completed {
            throw ExecutionServiceError.actionAlreadyCompleted(actionID)
        }
        result.dailyActions[index].status = .inProgress
        result.revision += 1
        result.savedAt = now
        try result.validateRelationships()
        return result
    }

    public func completeAction(
        _ actionID: DailyActionID,
        evidence: [CompletionEvidence],
        in snapshot: NextStepWorkspaceSnapshot,
        at now: Date,
        progressSnapshotID: ProgressSnapshotID,
        originDeviceID: DeviceID,
        currentDecision: PlanningDecision?
    ) throws -> NextStepWorkspaceSnapshot {
        var result = snapshot
        guard let index = result.dailyActions.firstIndex(where: { $0.metadata.id == actionID }) else {
            throw ExecutionServiceError.actionNotFound(actionID)
        }
        let action = result.dailyActions[index]
        if action.status == .completed {
            throw ExecutionServiceError.actionAlreadyCompleted(actionID)
        }
        let existingEvidence = result.completionEvidence.filter { $0.actionID == actionID }
        var allExistingEvidenceByID: [CompletionEvidenceID: CompletionEvidence] = [:]
        for item in result.completionEvidence {
            guard allExistingEvidenceByID.updateValue(item, forKey: item.metadata.id) == nil else {
                throw ExecutionServiceError.conflictingCompletionEvidence(item.metadata.id)
            }
        }
        var evidenceByID: [CompletionEvidenceID: CompletionEvidence] = [:]
        for item in existingEvidence {
            guard evidenceByID.updateValue(item, forKey: item.metadata.id) == nil else {
                throw ExecutionServiceError.conflictingCompletionEvidence(item.metadata.id)
            }
        }
        var newEvidence: [CompletionEvidence] = []
        for item in evidence {
            guard item.actionID == actionID else {
                throw ExecutionServiceError.completionRejected(
                    .evidenceActionMismatch(item.metadata.id)
                )
            }
            if let existing = allExistingEvidenceByID[item.metadata.id] {
                guard existing == item else {
                    throw ExecutionServiceError.conflictingCompletionEvidence(item.metadata.id)
                }
                evidenceByID[item.metadata.id] = item
                continue
            }
            allExistingEvidenceByID[item.metadata.id] = item
            evidenceByID[item.metadata.id] = item
            newEvidence.append(item)
        }
        let evidenceUnion = evidenceByID.values.sorted { $0.metadata.id < $1.metadata.id }
        let package = action.packageID.flatMap { packageID in
            result.guidedPackages.first { $0.metadata.id == packageID }
        }
        do {
            _ = try CompletionValidator().validate(
                action: action,
                package: package,
                evidence: evidenceUnion,
                userResponses: result.userResponses
            )
        } catch let error as CompletionValidationError {
            if case let .missingEvidence(ids) = error {
                throw ExecutionServiceError.missingCompletionEvidence(ids)
            }
            throw ExecutionServiceError.completionRejected(error)
        }

        result.dailyActions[index].status = .completed
        result.dailyActions[index].completedAt = now
        result.completionEvidence.append(contentsOf: newEvidence)
        result.revision += 1
        result.savedAt = now
        let progress = try ProgressCalculator().calculate(
            snapshot: result,
            decision: currentDecision,
            id: progressSnapshotID,
            originDeviceID: originDeviceID,
            at: now
        )
        result.progressSnapshots.append(progress)
        try result.validateRelationships()
        return result
    }

    public func deferAction(
        _ actionID: DailyActionID,
        in snapshot: NextStepWorkspaceSnapshot,
        at now: Date
    ) throws -> NextStepWorkspaceSnapshot {
        var result = snapshot
        guard let index = result.dailyActions.firstIndex(where: { $0.metadata.id == actionID }) else {
            throw ExecutionServiceError.actionNotFound(actionID)
        }
        guard result.dailyActions[index].flexibility != .locked else {
            throw ExecutionServiceError.actionIsLocked(actionID)
        }
        result.dailyActions[index].status = .deferred
        result.dailyActions[index].scheduledDay = nil
        result.revision += 1
        result.savedAt = now
        try result.validateRelationships()
        return result
    }

    public func acceptReplan(
        _ proposal: ReplanProposal,
        in snapshot: NextStepWorkspaceSnapshot,
        eventID: ReplanEventID,
        originDeviceID: DeviceID,
        at now: Date
    ) throws -> NextStepWorkspaceSnapshot {
        var result = snapshot
        let proposedByID = Dictionary(
            uniqueKeysWithValues: proposal.proposedDecision.assignments.map {
                ($0.actionID, $0)
            }
        )
        for index in result.dailyActions.indices {
            let actionID = result.dailyActions[index].metadata.id
            let proposed = proposedByID[actionID]
            if result.dailyActions[index].flexibility == .locked {
                guard proposed?.day == result.dailyActions[index].scheduledDay else {
                    throw ExecutionServiceError.lockedAssignmentChanged(actionID)
                }
                continue
            }
            guard result.dailyActions[index].status != .completed,
                  result.dailyActions[index].status != .cancelled else {
                continue
            }
            result.dailyActions[index].scheduledDay = proposed?.day
            result.dailyActions[index].status = proposed == nil ? .backlog : .scheduled
        }
        result.planningDecisions.append(proposal.proposedDecision)
        let metadata = try RecordMetadata(
            id: eventID,
            createdAt: now,
            originDeviceID: originDeviceID,
            provenance: .deterministicEngine
        )
        result.replanEvents.append(
            ReplanEvent(
                metadata: metadata,
                trigger: proposal.trigger,
                beforeDecisionID: proposal.previousDecisionID,
                afterDecisionID: proposal.proposedDecision.metadata.id,
                protectedFactDescriptions: proposal.protectedFactDescriptions,
                resolution: .accepted,
                occurredAt: now
            )
        )
        result.revision += 1
        result.savedAt = now
        try result.validateRelationships()
        return result
    }
}

public struct ProgressCalculator: Sendable {
    public init() {}

    public func calculate(
        snapshot: NextStepWorkspaceSnapshot,
        decision: PlanningDecision?,
        id: ProgressSnapshotID,
        originDeviceID: DeviceID,
        at now: Date
    ) throws -> ProgressSnapshot {
        let actionsByMilestone = Dictionary(grouping: snapshot.dailyActions, by: \.milestoneID)
        var milestoneProgress: [MilestoneID: Double] = [:]
        for milestone in snapshot.milestones {
            let actions = actionsByMilestone[milestone.metadata.id] ?? []
            if actions.isEmpty {
                milestoneProgress[milestone.metadata.id] = milestone.progressFraction
            } else {
                let completed = actions.filter { $0.status == .completed }.count
                milestoneProgress[milestone.metadata.id] = Double(completed) / Double(actions.count)
            }
        }

        let milestonesByGoal = Dictionary(grouping: snapshot.milestones, by: \.goalID)
        var goalProgress: [GoalID: Double] = [:]
        for goal in snapshot.goals {
            let milestones = milestonesByGoal[goal.metadata.id] ?? []
            let fractions = milestones.compactMap { milestoneProgress[$0.metadata.id] }
            goalProgress[goal.metadata.id] = fractions.isEmpty
                ? (goal.status == .achieved ? 1 : 0)
                : fractions.reduce(0, +) / Double(fractions.count)
        }

        let goalsByUltimate = Dictionary(grouping: snapshot.goals, by: \.ultimateGoalID)
        var ultimateProgress: [UltimateGoalID: Double] = [:]
        for ultimate in snapshot.ultimateGoals {
            let goals = goalsByUltimate[ultimate.metadata.id] ?? []
            let fractions = goals.compactMap { goalProgress[$0.metadata.id] }
            ultimateProgress[ultimate.metadata.id] = fractions.isEmpty
                ? (ultimate.status == .achieved ? 1 : 0)
                : fractions.reduce(0, +) / Double(fractions.count)
        }

        let atRisk = Set(
            (decision?.risks ?? [])
                .filter { $0.severity == .critical }
                .compactMap(\.milestoneID)
        ).sorted()
        let metadata = try RecordMetadata(
            id: id,
            createdAt: now,
            originDeviceID: originDeviceID,
            provenance: .deterministicEngine
        )
        return try ProgressSnapshot(
            metadata: metadata,
            capturedAt: now,
            planRevision: snapshot.revision,
            ultimateGoalProgress: ultimateProgress,
            goalProgress: goalProgress,
            milestoneProgress: milestoneProgress,
            completedActionCount: snapshot.dailyActions.filter { $0.status == .completed }.count,
            totalActionCount: snapshot.dailyActions.count,
            atRiskMilestoneIDs: atRisk
        )
    }
}
