import Foundation
import NextStepDomain
import NextStepGrounding
import NextStepPlanning

enum NextStepBetaGroundingError: Error, LocalizedError, Equatable {
    case invalidArchiveState
    case candidateNotFound
    case candidateAlreadyReviewed
    case stalePreview
    case targetMissing
    case sourceUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidArchiveState:
            "來源事實的追溯資料無法通過完整性驗證。"
        case .candidateNotFound:
            "找不到這個待核對的來源事實。"
        case .candidateAlreadyReviewed:
            "這個來源事實已經核對完成。"
        case .stalePreview:
            "資料或計畫已變更，請重新產生核對預覽。"
        case .targetMissing:
            "來源事實原本連結的目標路徑已不存在。"
        case .sourceUnavailable:
            "原始來源目前無法讀取；可以拒絕候選內容，但不能確認。"
        }
    }
}

enum NextStepBetaDeadlineTargetScope: String, Codable, Hashable, Sendable {
    case ultimateGoal
    case goal
    case milestone
}

struct NextStepBetaGroundingTarget: Codable, Hashable, Sendable {
    let ultimateGoalID: UltimateGoalID
    let goalID: GoalID
    let milestoneID: MilestoneID
    let deadlineScope: NextStepBetaDeadlineTargetScope

    init(
        ultimateGoalID: UltimateGoalID,
        goalID: GoalID,
        milestoneID: MilestoneID,
        deadlineScope: NextStepBetaDeadlineTargetScope = .milestone
    ) {
        self.ultimateGoalID = ultimateGoalID
        self.goalID = goalID
        self.milestoneID = milestoneID
        self.deadlineScope = deadlineScope
    }

    private enum CodingKeys: String, CodingKey {
        case ultimateGoalID
        case goalID
        case milestoneID
        case deadlineScope
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            ultimateGoalID: try container.decode(UltimateGoalID.self, forKey: .ultimateGoalID),
            goalID: try container.decode(GoalID.self, forKey: .goalID),
            milestoneID: try container.decode(MilestoneID.self, forKey: .milestoneID),
            deadlineScope: try container.decodeIfPresent(
                NextStepBetaDeadlineTargetScope.self,
                forKey: .deadlineScope
            ) ?? .milestone
        )
    }
}

struct NextStepBetaGroundingBatch: Codable, Hashable, Sendable, Identifiable {
    let parseResult: DocumentParseResult
    let target: NextStepBetaGroundingTarget
    let createdAt: Date

    var id: UUID { parseResult.requestID }
}

struct NextStepBetaPendingSourceFact: Hashable, Sendable, Identifiable {
    let batch: NextStepBetaGroundingBatch
    let candidate: DocumentFactCandidate

    var id: UUID { candidate.candidateID }
}

struct NextStepBetaGroundingState: Codable, Hashable, Sendable {
    var batches: [NextStepBetaGroundingBatch]
    var reviewAudits: [SourceFactReviewAudit]
    var confirmedDateFacts: [ConfirmedSourceDateFact]

    static let empty = NextStepBetaGroundingState(
        batches: [],
        reviewAudits: [],
        confirmedDateFacts: []
    )

    var pendingFacts: [NextStepBetaPendingSourceFact] {
        let reviewedIDs = Set(reviewAudits.map(\.candidateID))
        return batches
            .flatMap { batch in
                batch.parseResult.factCandidates.compactMap { candidate in
                    reviewedIDs.contains(candidate.candidateID)
                        ? nil
                        : NextStepBetaPendingSourceFact(batch: batch, candidate: candidate)
                }
            }
            .sorted { lhs, rhs in
                if lhs.batch.createdAt != rhs.batch.createdAt {
                    return lhs.batch.createdAt < rhs.batch.createdAt
                }
                return lhs.candidate.candidateID.uuidString
                    < rhs.candidate.candidateID.uuidString
            }
    }

    func pendingFact(id: UUID) -> NextStepBetaPendingSourceFact? {
        pendingFacts.first { $0.id == id }
    }

    func validate(in workspace: NextStepWorkspaceSnapshot) throws {
        guard batches.count <= 10_000,
              reviewAudits.count <= 50_000,
              confirmedDateFacts.count <= 50_000,
              Set(batches.map(\.id)).count == batches.count,
              Set(reviewAudits.map(\.id)).count == reviewAudits.count,
              Set(reviewAudits.map(\.candidateID)).count == reviewAudits.count,
              Set(confirmedDateFacts.map(\.id)).count == confirmedDateFacts.count,
              Set(confirmedDateFacts.map(\.candidateID)).count
                == confirmedDateFacts.count else {
            throw NextStepBetaGroundingError.invalidArchiveState
        }

        let sourceByID = Dictionary(uniqueKeysWithValues: workspace.sourceDocuments.map {
            ($0.metadata.id, $0)
        })
        let anchorByID = Dictionary(uniqueKeysWithValues: workspace.sourceAnchors.map {
            ($0.metadata.id, $0)
        })
        let evidenceByID = Dictionary(uniqueKeysWithValues: workspace.evidenceLinks.map {
            ($0.metadata.id, $0)
        })
        let ultimateByID = Dictionary(uniqueKeysWithValues: workspace.ultimateGoals.map {
            ($0.metadata.id, $0)
        })
        let goalByID = Dictionary(uniqueKeysWithValues: workspace.goals.map {
            ($0.metadata.id, $0)
        })
        let milestoneByID = Dictionary(uniqueKeysWithValues: workspace.milestones.map {
            ($0.metadata.id, $0)
        })

        var allByCandidateID: [UUID: NextStepBetaPendingSourceFact] = [:]
        for batch in batches {
            let parse = batch.parseResult
            guard let source = sourceByID[parse.sourceDocumentID],
                  source.metadata.deletedAt == nil,
                  source.verificationState == .contentHashVerified,
                  source.contentSHA256 == parse.sourceSHA256,
                  let ultimate = ultimateByID[batch.target.ultimateGoalID],
                  let goal = goalByID[batch.target.goalID],
                  let milestone = milestoneByID[batch.target.milestoneID],
                  goal.ultimateGoalID == ultimate.metadata.id,
                  milestone.goalID == goal.metadata.id else {
                throw NextStepBetaGroundingError.invalidArchiveState
            }
            for block in parse.pages.flatMap(\.blocks) {
                guard let anchor = anchorByID[block.anchorID],
                      anchor.sourceDocumentID == source.metadata.id else {
                    throw NextStepBetaGroundingError.invalidArchiveState
                }
            }
            for candidate in parse.factCandidates {
                guard allByCandidateID[candidate.candidateID] == nil else {
                    throw NextStepBetaGroundingError.invalidArchiveState
                }
                let record = NextStepBetaPendingSourceFact(batch: batch, candidate: candidate)
                allByCandidateID[candidate.candidateID] = record
            }
        }

        let factByID = Dictionary(uniqueKeysWithValues: confirmedDateFacts.map {
            ($0.id, $0)
        })
        var appliedDeadlineFacts: [(
            target: NextStepBetaGroundingTarget,
            fact: ConfirmedSourceDateFact,
            audit: SourceFactReviewAudit
        )] = []
        for audit in reviewAudits {
            guard let record = allByCandidateID[audit.candidateID],
                  audit.sourceDocumentID == record.batch.parseResult.sourceDocumentID,
                  audit.sourceSHA256 == record.batch.parseResult.sourceSHA256,
                  audit.anchorIDs == record.candidate.anchorIDs,
                  audit.parseRequestID == record.batch.parseResult.requestID,
                  audit.parser == record.batch.parseResult.parser else {
                throw NextStepBetaGroundingError.invalidArchiveState
            }
            switch audit.disposition {
            case .confirmed:
                guard let factID = audit.confirmedFactID,
                      let fact = factByID[factID],
                      let source = sourceByID[audit.sourceDocumentID],
                      fact.candidateID == record.candidate.candidateID,
                      fact.sourceDocumentID == audit.sourceDocumentID,
                      fact.kind == record.candidate.kind,
                      fact.day.evidenceLinkIDs == audit.evidenceLinkIDs else {
                    throw NextStepBetaGroundingError.invalidArchiveState
                }
                let selectedAnchors = record.candidate.anchorIDs.compactMap { anchorByID[$0] }
                guard selectedAnchors.count == record.candidate.anchorIDs.count else {
                    throw NextStepBetaGroundingError.invalidArchiveState
                }
                let recomputed: SourceFactReviewOutcome
                do {
                    recomputed = try SourceFactReviewService().review(
                        parseResult: record.batch.parseResult,
                        candidateID: record.candidate.candidateID,
                        sourceDocument: source,
                        anchors: selectedAnchors,
                        decision: .confirm(
                            confirmedFactID: fact.id,
                            evidenceLinkIDs: audit.evidenceLinkIDs
                        ),
                        occurredAt: audit.metadata.createdAt,
                        originDeviceID: audit.metadata.originDeviceID,
                        auditID: audit.id
                    )
                } catch {
                    throw NextStepBetaGroundingError.invalidArchiveState
                }
                guard recomputed.audit == audit,
                      recomputed.confirmedFact == fact,
                      recomputed.evidenceLinks.count == audit.evidenceLinkIDs.count else {
                    throw NextStepBetaGroundingError.invalidArchiveState
                }
                for evidenceID in audit.evidenceLinkIDs {
                    guard let evidence = evidenceByID[evidenceID],
                          evidence.metadata.deletedAt == nil,
                          record.candidate.anchorIDs.contains(evidence.anchorID),
                          evidence.relation == .supports,
                          evidence.subjectType == "ConfirmedSourceDateFact",
                          evidence.subjectID == fact.id,
                          evidence.verifiedBy == .user,
                          recomputed.evidenceLinks.contains(evidence) else {
                        throw NextStepBetaGroundingError.invalidArchiveState
                    }
                }
                if fact.kind == .deadline {
                    appliedDeadlineFacts.append((record.batch.target, fact, audit))
                }
            case .rejected:
                guard audit.confirmedFactID == nil,
                      audit.evidenceLinkIDs.isEmpty else {
                    throw NextStepBetaGroundingError.invalidArchiveState
                }
            }
        }

        let confirmedAuditFactIDs = Set(reviewAudits.compactMap(\.confirmedFactID))
        guard confirmedAuditFactIDs == Set(confirmedDateFacts.map(\.id)) else {
            throw NextStepBetaGroundingError.invalidArchiveState
        }
        for target in Set(appliedDeadlineFacts.map { $0.target }) {
            let targetFacts = appliedDeadlineFacts.filter { $0.target == target }
            guard let latestOccurredAt = targetFacts.map({
                $0.audit.metadata.createdAt
            }).max() else {
                throw NextStepBetaGroundingError.invalidArchiveState
            }
            let appliedDay: FactValue<LocalDay>?
            switch target.deadlineScope {
            case .ultimateGoal:
                appliedDay = ultimateByID[target.ultimateGoalID]?.targetDay
            case .goal:
                appliedDay = goalByID[target.goalID]?.targetDay
            case .milestone:
                appliedDay = milestoneByID[target.milestoneID]?.targetDay
            }
            guard let appliedDay,
                  targetFacts.contains(where: {
                      $0.audit.metadata.createdAt == latestOccurredAt
                          && $0.fact.day == appliedDay
                  }) else {
                throw NextStepBetaGroundingError.invalidArchiveState
            }
        }
    }
}

enum NextStepBetaDeadlineChangeOwner: String, Hashable, Sendable {
    case ultimateGoal
    case goal
    case milestone
    case dailyAction
}

struct NextStepBetaDeadlineChange: Hashable, Sendable, Identifiable {
    let owner: NextStepBetaDeadlineChangeOwner
    let ownerID: String
    let title: String
    let previousDay: LocalDay?
    let proposedDay: LocalDay

    var id: String { "\(owner.rawValue):\(ownerID)" }
}

struct NextStepBetaSourceFactDiff: Hashable, Sendable {
    let kind: DocumentFactKind
    let previousDay: LocalDay?
    let proposedDay: LocalDay
    let target: NextStepBetaGroundingTarget
    let deadlineChanges: [NextStepBetaDeadlineChange]
}

struct NextStepBetaSourceFactReviewPreview: Hashable, Sendable, Identifiable {
    let expectedWorkspaceRevision: Int64
    let expectedDecisionID: PlanningDecisionID?
    let batchID: UUID
    let candidate: DocumentFactCandidate
    let sourceDocumentID: SourceDocumentID
    let outcome: SourceFactReviewOutcome
    let diff: NextStepBetaSourceFactDiff
    let replanProposal: ReplanProposal?
    let replanEventID: ReplanEventID?
    let createdAt: Date

    var id: UUID { candidate.candidateID }
}

struct NextStepBetaGroundingBatchBuilder {
    func makeBatch(
        imported: NextStepBetaImportedSource,
        exactExtract: String,
        anchor: SourceAnchor,
        target: NextStepBetaGroundingTarget,
        now: Date
    ) throws -> NextStepBetaGroundingBatch {
        let block = try DocumentTextBlock(
            blockID: UUID(),
            kind: .paragraph,
            text: exactExtract,
            anchorID: anchor.metadata.id,
            confidence: imported.usedVisionOCR ? 0.85 : 0.99
        )
        let page = try DocumentPage(
            pageIndex: imported.pageIndex,
            widthPoints: 612,
            heightPoints: 792,
            blocks: [block]
        )
        let parse = try DateCandidateExtractor().extract(
            requestID: UUID(),
            sourceDocument: imported.document,
            pages: [page],
            languages: []
        )
        return NextStepBetaGroundingBatch(
            parseResult: parse,
            target: target,
            createdAt: now
        )
    }
}

struct NextStepBetaSourceFactReviewCoordinator {
    static let previewTimeToLive: TimeInterval = 15 * 60

    func makePreview(
        candidateID: UUID,
        archive: NextStepBetaArchive,
        now: Date
    ) throws -> NextStepBetaSourceFactReviewPreview {
        guard let pending = archive.grounding.pendingFact(id: candidateID) else {
            if archive.grounding.reviewAudits.contains(where: { $0.candidateID == candidateID }) {
                throw NextStepBetaGroundingError.candidateAlreadyReviewed
            }
            throw NextStepBetaGroundingError.candidateNotFound
        }
        let parse = pending.batch.parseResult
        guard let source = archive.workspace.sourceDocuments.first(where: {
            $0.metadata.id == parse.sourceDocumentID
        }) else {
            throw NextStepBetaGroundingError.sourceUnavailable
        }
        let anchors = pending.candidate.anchorIDs.compactMap { anchorID in
            archive.workspace.sourceAnchors.first { $0.metadata.id == anchorID }
        }
        let factID = UUID()
        let evidenceIDs = pending.candidate.anchorIDs.map { _ in EvidenceLinkID() }
        let auditID = UUID()
        let outcome = try SourceFactReviewService().review(
            parseResult: parse,
            candidateID: candidateID,
            sourceDocument: source,
            anchors: anchors,
            decision: .confirm(
                confirmedFactID: factID,
                evidenceLinkIDs: evidenceIDs
            ),
            occurredAt: now,
            originDeviceID: archive.deviceID,
            auditID: auditID
        )
        guard let confirmedFact = outcome.confirmedFact else {
            throw NextStepBetaGroundingError.invalidArchiveState
        }

        let deadlineChanges = pending.candidate.kind == .deadline
            ? try targetDeadlineChanges(
                pending.batch.target,
                proposedDay: confirmedFact.day.value,
                workspace: archive.workspace
            )
            : []
        let previousDay = deadlineChanges.first?.previousDay
        var preparedWorkspace = archive.workspace
        preparedWorkspace.evidenceLinks.append(contentsOf: outcome.evidenceLinks)
        var proposal: ReplanProposal?
        var eventID: ReplanEventID?
        if confirmedFact.kind == .deadline {
            try applyDeadline(
                confirmedFact.day,
                target: pending.batch.target,
                workspace: &preparedWorkspace
            )
            let today = try LocalDay(
                date: now,
                timeZoneIdentifier: preparedWorkspace.userProfile.timeZoneIdentifier
            )
            let input = try PlanningInput(
                snapshot: preparedWorkspace,
                horizonStart: today,
                horizonEnd: try today.adding(days: 30),
                createdAt: now
            )
            proposal = try PlanningEngine().replan(
                input,
                previous: archive.currentDecision,
                trigger: .deadlineChanged,
                originDeviceID: archive.deviceID
            )
            eventID = ReplanEventID()
        }
        return NextStepBetaSourceFactReviewPreview(
            expectedWorkspaceRevision: archive.workspace.revision,
            expectedDecisionID: archive.currentDecision?.metadata.id,
            batchID: pending.batch.id,
            candidate: pending.candidate,
            sourceDocumentID: source.metadata.id,
            outcome: outcome,
            diff: NextStepBetaSourceFactDiff(
                kind: confirmedFact.kind,
                previousDay: previousDay,
                proposedDay: confirmedFact.day.value,
                target: pending.batch.target,
                deadlineChanges: deadlineChanges
            ),
            replanProposal: proposal,
            replanEventID: eventID,
            createdAt: now
        )
    }

    func accept(
        _ preview: NextStepBetaSourceFactReviewPreview,
        archive: NextStepBetaArchive,
        now: Date
    ) throws -> NextStepBetaArchive {
        try validatePreviewFreshness(
            preview,
            workspace: archive.workspace,
            now: now
        )
        guard archive.workspace.revision == preview.expectedWorkspaceRevision,
              archive.currentDecision?.metadata.id == preview.expectedDecisionID,
              let pending = archive.grounding.pendingFact(id: preview.candidate.candidateID),
              pending.batch.id == preview.batchID,
              pending.candidate == preview.candidate,
              pending.batch.parseResult.sourceDocumentID == preview.sourceDocumentID,
              let source = archive.workspace.sourceDocuments.first(where: {
                  $0.metadata.id == preview.sourceDocumentID
              }) else {
            throw NextStepBetaGroundingError.stalePreview
        }
        let anchors = pending.candidate.anchorIDs.compactMap { anchorID in
            archive.workspace.sourceAnchors.first { $0.metadata.id == anchorID }
        }
        guard let expectedFact = preview.outcome.confirmedFact else {
            throw NextStepBetaGroundingError.stalePreview
        }
        let previewOutcome = try SourceFactReviewService().review(
            parseResult: pending.batch.parseResult,
            candidateID: pending.candidate.candidateID,
            sourceDocument: source,
            anchors: anchors,
            decision: .confirm(
                confirmedFactID: expectedFact.id,
                evidenceLinkIDs: expectedFact.day.evidenceLinkIDs
            ),
            occurredAt: preview.createdAt,
            originDeviceID: archive.deviceID,
            auditID: preview.outcome.audit.id
        )
        guard previewOutcome == preview.outcome else {
            throw NextStepBetaGroundingError.stalePreview
        }
        let acceptedOutcome = try SourceFactReviewService().review(
            parseResult: pending.batch.parseResult,
            candidateID: pending.candidate.candidateID,
            sourceDocument: source,
            anchors: anchors,
            decision: .confirm(
                confirmedFactID: expectedFact.id,
                evidenceLinkIDs: expectedFact.day.evidenceLinkIDs
            ),
            occurredAt: now,
            originDeviceID: archive.deviceID,
            auditID: preview.outcome.audit.id
        )
        let expectedDeadlineChanges = expectedFact.kind == .deadline
            ? try targetDeadlineChanges(
                pending.batch.target,
                proposedDay: expectedFact.day.value,
                workspace: archive.workspace
            )
            : []
        let expectedPreviousDay = expectedDeadlineChanges.first?.previousDay
        guard let acceptedFact = acceptedOutcome.confirmedFact,
              acceptedFact.id == expectedFact.id,
              acceptedFact.candidateID == expectedFact.candidateID,
              acceptedFact.sourceDocumentID == expectedFact.sourceDocumentID,
              acceptedFact.kind == expectedFact.kind,
              acceptedFact.day.value == expectedFact.day.value,
              acceptedFact.day.evidenceLinkIDs == expectedFact.day.evidenceLinkIDs,
              preview.diff.kind == acceptedFact.kind,
              preview.diff.previousDay == expectedPreviousDay,
              preview.diff.proposedDay == acceptedFact.day.value,
              preview.diff.target == pending.batch.target,
              preview.diff.deadlineChanges == expectedDeadlineChanges else {
            throw NextStepBetaGroundingError.stalePreview
        }

        var result = archive
        result.workspace.evidenceLinks.append(contentsOf: acceptedOutcome.evidenceLinks)
        result.grounding.reviewAudits.append(acceptedOutcome.audit)
        result.grounding.confirmedDateFacts.append(acceptedFact)

        if acceptedFact.kind == .deadline {
            try applyDeadline(
                acceptedFact.day,
                target: pending.batch.target,
                workspace: &result.workspace
            )
            guard let previewProposal = preview.replanProposal,
                  let eventID = preview.replanEventID else {
                throw NextStepBetaGroundingError.stalePreview
            }
            var previewWorkspace = archive.workspace
            previewWorkspace.evidenceLinks.append(contentsOf: previewOutcome.evidenceLinks)
            guard let previewFact = previewOutcome.confirmedFact else {
                throw NextStepBetaGroundingError.stalePreview
            }
            try applyDeadline(
                previewFact.day,
                target: pending.batch.target,
                workspace: &previewWorkspace
            )
            let previewToday = try LocalDay(
                date: preview.createdAt,
                timeZoneIdentifier: previewWorkspace.userProfile.timeZoneIdentifier
            )
            let previewInput = try PlanningInput(
                snapshot: previewWorkspace,
                horizonStart: previewToday,
                horizonEnd: try previewToday.adding(days: 30),
                createdAt: preview.createdAt
            )
            let recomputedPreviewProposal = try PlanningEngine().replan(
                previewInput,
                previous: archive.currentDecision,
                trigger: .deadlineChanged,
                decisionID: previewProposal.proposedDecision.metadata.id,
                originDeviceID: archive.deviceID
            )
            guard semanticallyEquivalent(recomputedPreviewProposal, previewProposal) else {
                throw NextStepBetaGroundingError.stalePreview
            }

            let today = try LocalDay(
                date: now,
                timeZoneIdentifier: result.workspace.userProfile.timeZoneIdentifier
            )
            let input = try PlanningInput(
                snapshot: result.workspace,
                horizonStart: today,
                horizonEnd: try today.adding(days: 30),
                createdAt: now
            )
            let acceptedProposal = try PlanningEngine().replan(
                input,
                previous: archive.currentDecision,
                trigger: .deadlineChanged,
                decisionID: previewProposal.proposedDecision.metadata.id,
                originDeviceID: archive.deviceID
            )
            guard executionEquivalent(acceptedProposal, previewProposal) else {
                throw NextStepBetaGroundingError.stalePreview
            }
            result.workspace = try ExecutionService().acceptReplan(
                acceptedProposal,
                in: result.workspace,
                eventID: eventID,
                originDeviceID: result.deviceID,
                at: now
            )
            result.currentDecisionID = acceptedProposal.proposedDecision.metadata.id
        } else {
            result.workspace.revision += 1
            result.workspace.savedAt = now
        }
        try result.validate()
        return result
    }

    func reject(
        candidateID: UUID,
        reason: String,
        archive: NextStepBetaArchive,
        now: Date
    ) throws -> NextStepBetaArchive {
        guard let pending = archive.grounding.pendingFact(id: candidateID) else {
            if archive.grounding.reviewAudits.contains(where: { $0.candidateID == candidateID }) {
                throw NextStepBetaGroundingError.candidateAlreadyReviewed
            }
            throw NextStepBetaGroundingError.candidateNotFound
        }
        guard let source = archive.workspace.sourceDocuments.first(where: {
            $0.metadata.id == pending.batch.parseResult.sourceDocumentID
        }) else {
            throw NextStepBetaGroundingError.candidateNotFound
        }
        let outcome = try SourceFactReviewService().review(
            parseResult: pending.batch.parseResult,
            candidateID: candidateID,
            sourceDocument: source,
            anchors: [],
            decision: .reject(reason: reason),
            occurredAt: now,
            originDeviceID: archive.deviceID,
            auditID: UUID()
        )
        var result = archive
        result.grounding.reviewAudits.append(outcome.audit)
        result.workspace.revision += 1
        result.workspace.savedAt = now
        try result.validate()
        return result
    }

    private func targetDeadlineChanges(
        _ target: NextStepBetaGroundingTarget,
        proposedDay: LocalDay,
        workspace: NextStepWorkspaceSnapshot
    ) throws -> [NextStepBetaDeadlineChange] {
        guard let ultimate = workspace.ultimateGoals.first(where: {
            $0.metadata.id == target.ultimateGoalID
        }),
        let goal = workspace.goals.first(where: { $0.metadata.id == target.goalID }),
        let milestone = workspace.milestones.first(where: {
            $0.metadata.id == target.milestoneID
        }),
        goal.ultimateGoalID == ultimate.metadata.id,
        milestone.goalID == goal.metadata.id else {
            throw NextStepBetaGroundingError.targetMissing
        }
        switch target.deadlineScope {
        case .ultimateGoal:
            return [.init(
                owner: .ultimateGoal,
                ownerID: ultimate.metadata.id.description,
                title: ultimate.title,
                previousDay: ultimate.targetDay?.value,
                proposedDay: proposedDay
            )]
        case .goal:
            return [.init(
                owner: .goal,
                ownerID: goal.metadata.id.description,
                title: goal.title,
                previousDay: goal.targetDay?.value,
                proposedDay: proposedDay
            )]
        case .milestone:
            let milestoneChange = NextStepBetaDeadlineChange(
                owner: .milestone,
                ownerID: milestone.metadata.id.description,
                title: milestone.title,
                previousDay: milestone.targetDay?.value,
                proposedDay: proposedDay
            )
            let actionChanges: [NextStepBetaDeadlineChange] = workspace.dailyActions.compactMap { action -> NextStepBetaDeadlineChange? in
                guard action.milestoneID == target.milestoneID,
                      action.status != .completed,
                      action.status != .cancelled else { return nil }
                return NextStepBetaDeadlineChange(
                    owner: .dailyAction,
                    ownerID: action.metadata.id.description,
                    title: action.title,
                    previousDay: action.deadline?.value,
                    proposedDay: proposedDay
                )
            }
            return [milestoneChange] + actionChanges
        }
    }

    private func applyDeadline(
        _ deadline: FactValue<LocalDay>,
        target: NextStepBetaGroundingTarget,
        workspace: inout NextStepWorkspaceSnapshot
    ) throws {
        guard let ultimateIndex = workspace.ultimateGoals.firstIndex(where: {
            $0.metadata.id == target.ultimateGoalID
        }),
        let goalIndex = workspace.goals.firstIndex(where: {
            $0.metadata.id == target.goalID
        }),
        let milestoneIndex = workspace.milestones.firstIndex(where: {
            $0.metadata.id == target.milestoneID
        }),
        workspace.goals[goalIndex].ultimateGoalID == target.ultimateGoalID,
        workspace.milestones[milestoneIndex].goalID == target.goalID else {
            throw NextStepBetaGroundingError.targetMissing
        }
        switch target.deadlineScope {
        case .ultimateGoal:
            workspace.ultimateGoals[ultimateIndex].targetDay = deadline
        case .goal:
            workspace.goals[goalIndex].targetDay = deadline
        case .milestone:
            workspace.milestones[milestoneIndex].targetDay = deadline
            for index in workspace.dailyActions.indices
                where workspace.dailyActions[index].milestoneID == target.milestoneID
                    && workspace.dailyActions[index].status != .completed
                    && workspace.dailyActions[index].status != .cancelled {
                workspace.dailyActions[index].deadline = deadline
            }
        }
    }

    private func semanticallyEquivalent(
        _ lhs: ReplanProposal,
        _ rhs: ReplanProposal
    ) -> Bool {
        let lhsDecision = lhs.proposedDecision
        let rhsDecision = rhs.proposedDecision
        guard lhs.trigger == rhs.trigger,
              lhs.previousDecisionID == rhs.previousDecisionID,
              lhs.changes == rhs.changes,
              lhs.protectedFactDescriptions == rhs.protectedFactDescriptions,
              lhs.createdAt == rhs.createdAt,
              lhsDecision.metadata == rhsDecision.metadata,
              lhsDecision.engineVersion == rhsDecision.engineVersion,
              lhsDecision.inputSnapshotSHA256 == rhsDecision.inputSnapshotSHA256,
              lhsDecision.horizonStart == rhsDecision.horizonStart,
              lhsDecision.horizonEnd == rhsDecision.horizonEnd,
              lhsDecision.assignments == rhsDecision.assignments,
              lhsDecision.rejectedActions == rhsDecision.rejectedActions,
              lhsDecision.createdAt == rhsDecision.createdAt,
              lhsDecision.risks.count == rhsDecision.risks.count else {
            return false
        }
        return zip(lhsDecision.risks, rhsDecision.risks).allSatisfy { lhsRisk, rhsRisk in
            lhsRisk.kind == rhsRisk.kind
                && lhsRisk.severity == rhsRisk.severity
                && lhsRisk.actionID == rhsRisk.actionID
                && lhsRisk.milestoneID == rhsRisk.milestoneID
                && lhsRisk.message == rhsRisk.message
        }
    }

    private func executionEquivalent(
        _ lhs: ReplanProposal,
        _ rhs: ReplanProposal
    ) -> Bool {
        let lhsDecision = lhs.proposedDecision
        let rhsDecision = rhs.proposedDecision
        guard lhs.trigger == rhs.trigger,
              lhs.previousDecisionID == rhs.previousDecisionID,
              lhs.changes == rhs.changes,
              lhs.protectedFactDescriptions == rhs.protectedFactDescriptions,
              lhsDecision.metadata.id == rhsDecision.metadata.id,
              lhsDecision.engineVersion == rhsDecision.engineVersion,
              lhsDecision.horizonStart == rhsDecision.horizonStart,
              lhsDecision.horizonEnd == rhsDecision.horizonEnd,
              lhsDecision.assignments == rhsDecision.assignments,
              lhsDecision.rejectedActions == rhsDecision.rejectedActions,
              lhsDecision.risks.count == rhsDecision.risks.count else {
            return false
        }
        return zip(lhsDecision.risks, rhsDecision.risks).allSatisfy { lhsRisk, rhsRisk in
            lhsRisk.kind == rhsRisk.kind
                && lhsRisk.severity == rhsRisk.severity
                && lhsRisk.actionID == rhsRisk.actionID
                && lhsRisk.milestoneID == rhsRisk.milestoneID
                && lhsRisk.message == rhsRisk.message
        }
    }

    private func validatePreviewFreshness(
        _ preview: NextStepBetaSourceFactReviewPreview,
        workspace: NextStepWorkspaceSnapshot,
        now: Date
    ) throws {
        let elapsed = now.timeIntervalSince(preview.createdAt)
        guard elapsed >= 0, elapsed <= Self.previewTimeToLive else {
            throw NextStepBetaGroundingError.stalePreview
        }
        let timeZoneIdentifier = workspace.userProfile.timeZoneIdentifier
        let previewDay = try LocalDay(
            date: preview.createdAt,
            timeZoneIdentifier: timeZoneIdentifier
        )
        let acceptanceDay = try LocalDay(
            date: now,
            timeZoneIdentifier: timeZoneIdentifier
        )
        guard previewDay == acceptanceDay else {
            throw NextStepBetaGroundingError.stalePreview
        }
    }
}
