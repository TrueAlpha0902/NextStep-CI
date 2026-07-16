import CryptoKit
import Foundation
import NextStepDomain

public struct PlanningInput: Hashable, Sendable {
    public let snapshot: NextStepWorkspaceSnapshot
    public let horizonStart: LocalDay
    public let horizonEnd: LocalDay
    public let dailyCapacityOverrides: [LocalDay: Int]
    public let createdAt: Date

    public init(
        snapshot: NextStepWorkspaceSnapshot,
        horizonStart: LocalDay,
        horizonEnd: LocalDay,
        dailyCapacityOverrides: [LocalDay: Int] = [:],
        createdAt: Date
    ) throws {
        guard horizonStart <= horizonEnd,
              horizonStart.distance(to: horizonEnd) <= 366,
              dailyCapacityOverrides.values.allSatisfy({ (0...1_440).contains($0) }) else {
            throw PlanningEngineError.invalidHorizon
        }
        self.snapshot = snapshot
        self.horizonStart = horizonStart
        self.horizonEnd = horizonEnd
        self.dailyCapacityOverrides = dailyCapacityOverrides
        self.createdAt = createdAt
    }
}

public enum PlanningEngineError: Error, Equatable, LocalizedError, Sendable {
    case invalidHorizon
    case invalidWorkspace(String)
    case lockedActionOutsideSchedule(DailyActionID)

    public var errorDescription: String? {
        switch self {
        case .invalidHorizon:
            "The planning horizon or capacity override is invalid."
        case let .invalidWorkspace(message):
            message
        case let .lockedActionOutsideSchedule(actionID):
            "Locked action \(actionID) does not have a usable schedule."
        }
    }
}

public struct PlanningEngine: Sendable {
    public static let version = "nextstep-deterministic-v1"

    public init() {}

    public func plan(
        _ input: PlanningInput,
        decisionID: PlanningDecisionID = PlanningDecisionID(),
        originDeviceID: DeviceID
    ) throws -> PlanningDecision {
        do {
            try input.snapshot.validateRelationships()
        } catch {
            throw PlanningEngineError.invalidWorkspace(error.localizedDescription)
        }

        let days = try makeDays(from: input.horizonStart, through: input.horizonEnd)
        let actions = input.snapshot.dailyActions
        let completedIDs = Set(
            actions.lazy
                .filter { $0.status == .completed }
                .map(\.metadata.id)
        )
        let excludedStatuses: Set<ActionStatus> = [.completed, .cancelled]
        let activeActions = actions.filter { excludedStatuses.contains($0.status) == false }

        var capacities = Dictionary(uniqueKeysWithValues: days.map {
            ($0, availableMinutes(on: $0, input: input))
        })
        var assignments: [ScheduledAction] = []
        var risks: [PlanningRisk] = []
        var rejected: [RejectedAction] = []

        let lockedActions = activeActions
            .filter { $0.flexibility == .locked }
            .sorted(by: actionTieBreak)
        for action in lockedActions {
            guard let day = action.scheduledDay else {
                throw PlanningEngineError.lockedActionOutsideSchedule(action.metadata.id)
            }
            guard day >= input.horizonStart, day <= input.horizonEnd else {
                continue
            }
            let order = assignments.filter { $0.day == day }.count
            assignments.append(
                try ScheduledAction(
                    actionID: action.metadata.id,
                    day: day,
                    plannedMinutes: action.estimatedMinutes,
                    order: order,
                    reasonCodes: mergedReasons(action.reasonCodes, [.fixedSchedule]),
                    isLocked: true
                )
            )
            capacities[day, default: 0] -= action.estimatedMinutes
            if capacities[day, default: 0] < 0 {
                risks.append(
                    try makeRisk(
                        kind: .overloadedDay,
                        severity: .critical,
                        action: action,
                        message: "A locked commitment exceeds the available time on \(day)."
                    )
                )
            }
            if Set(action.dependencyActionIDs).isSubset(of: completedIDs) == false {
                risks.append(
                    try makeRisk(
                        kind: .blockedDependency,
                        severity: .critical,
                        action: action,
                        message: "A locked commitment still has an incomplete dependency."
                    )
                )
            }
        }

        let lockedIDs = Set(lockedActions.map(\.metadata.id))
        let candidates = activeActions
            .filter { $0.flexibility != .locked && $0.status != .blocked }
            .sorted { candidateComesFirst($0, $1, referenceDay: input.horizonStart) }
        var scheduledIDs = Set(assignments.map(\.actionID))
        var resolvedBeforeDay = completedIDs

        for day in days {
            var remainingCapacity = max(0, capacities[day, default: 0])
            let assignedEarlierToday = Set(assignments.lazy.filter { $0.day == day }.map(\.actionID))
            var newlyScheduledToday = Set<DailyActionID>()

            for action in candidates where scheduledIDs.contains(action.metadata.id) == false {
                guard action.earliestDay.map({ $0 <= day }) ?? true else { continue }
                guard Set(action.dependencyActionIDs).isSubset(of: resolvedBeforeDay) else { continue }
                guard action.estimatedMinutes <= remainingCapacity else { continue }

                let order = assignedEarlierToday.count + newlyScheduledToday.count
                var reasons = action.reasonCodes
                reasons.append(.availableTimeFit)
                if action.sourceDocumentIDs.isEmpty == false { reasons.append(.sourcePrepared) }
                if let deadline = action.deadline?.value,
                   day.distance(to: deadline) <= 3 {
                    reasons.append(.hardDeadlineApproaching)
                }
                assignments.append(
                    try ScheduledAction(
                        actionID: action.metadata.id,
                        day: day,
                        plannedMinutes: action.estimatedMinutes,
                        order: order,
                        reasonCodes: mergedReasons(reasons, []),
                        isLocked: false
                    )
                )
                scheduledIDs.insert(action.metadata.id)
                newlyScheduledToday.insert(action.metadata.id)
                remainingCapacity -= action.estimatedMinutes
            }

            resolvedBeforeDay.formUnion(newlyScheduledToday)
            resolvedBeforeDay.formUnion(assignedEarlierToday)
        }

        let actionByID = Dictionary(uniqueKeysWithValues: actions.map { ($0.metadata.id, $0) })
        let assignmentByID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.actionID, $0) })

        for action in activeActions where scheduledIDs.contains(action.metadata.id) == false {
            guard lockedIDs.contains(action.metadata.id) == false else { continue }
            let dependenciesSatisfied = Set(action.dependencyActionIDs)
                .isSubset(of: resolvedBeforeDay)
            let reason: PlanningRiskKind = dependenciesSatisfied
                ? .insufficientCapacity
                : .blockedDependency
            let detail = dependenciesSatisfied
                ? "No available block in this horizon can fit the action."
                : "One or more prerequisite actions are not complete or scheduled earlier."
            rejected.append(
                RejectedAction(actionID: action.metadata.id, reason: reason, detail: detail)
            )
            risks.append(
                try makeRisk(
                    kind: reason,
                    severity: deadlineSeverity(for: action, horizonEnd: input.horizonEnd),
                    action: action,
                    message: detail
                )
            )
        }

        for (actionID, assignment) in assignmentByID {
            guard let action = actionByID[actionID],
                  let deadline = action.deadline?.value,
                  assignment.day > deadline else {
                continue
            }
            risks.append(
                try makeRisk(
                    kind: .hardDeadlineAtRisk,
                    severity: .critical,
                    action: action,
                    message: "The planned day is after the protected deadline \(deadline)."
                )
            )
        }

        assignments.sort {
            if $0.day != $1.day { return $0.day < $1.day }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.actionID < $1.actionID
        }
        rejected.sort { $0.actionID < $1.actionID }
        risks.sort {
            if $0.severity != $1.severity {
                return severityRank($0.severity) > severityRank($1.severity)
            }
            if $0.kind != $1.kind { return $0.kind.rawValue < $1.kind.rawValue }
            return ($0.actionID?.description ?? "") < ($1.actionID?.description ?? "")
        }

        let metadata = try RecordMetadata(
            id: decisionID,
            createdAt: input.createdAt,
            originDeviceID: originDeviceID,
            provenance: .deterministicEngine
        )
        return try PlanningDecision(
            metadata: metadata,
            engineVersion: Self.version,
            inputSnapshotSHA256: try planningInputSHA256(input),
            horizonStart: input.horizonStart,
            horizonEnd: input.horizonEnd,
            assignments: assignments,
            rejectedActions: rejected,
            risks: risks,
            createdAt: input.createdAt
        )
    }

    public func replan(
        _ input: PlanningInput,
        previous: PlanningDecision?,
        trigger: ReplanTrigger,
        decisionID: PlanningDecisionID = PlanningDecisionID(),
        originDeviceID: DeviceID
    ) throws -> ReplanProposal {
        let proposed = try plan(
            input,
            decisionID: decisionID,
            originDeviceID: originDeviceID
        )
        let previousByID = Dictionary(
            uniqueKeysWithValues: (previous?.assignments ?? []).map { ($0.actionID, $0) }
        )
        let proposedByID = Dictionary(
            uniqueKeysWithValues: proposed.assignments.map { ($0.actionID, $0) }
        )
        let actionByID = Dictionary(
            uniqueKeysWithValues: input.snapshot.dailyActions.map { ($0.metadata.id, $0) }
        )
        let allIDs = Set(previousByID.keys).union(proposedByID.keys).sorted()
        var changes: [PlanChange] = []

        for actionID in allIDs {
            let old = previousByID[actionID]
            let new = proposedByID[actionID]
            switch (old, new) {
            case (nil, let new?):
                changes.append(
                    try PlanChange(
                        kind: .add,
                        actionID: actionID,
                        toDay: new.day,
                        explanation: "Capacity and dependencies now allow this action.",
                        requiresConfirmation: false
                    )
                )
            case (let old?, nil):
                let completed = actionByID[actionID]?.status == .completed
                changes.append(
                    try PlanChange(
                        kind: .remove,
                        actionID: actionID,
                        fromDay: old.day,
                        explanation: completed
                            ? "The completed action no longer needs a schedule."
                            : "The current horizon cannot safely fit this action.",
                        requiresConfirmation: completed == false
                    )
                )
            case (let old?, let new?) where old.day != new.day:
                if actionByID[actionID]?.flexibility == .locked {
                    throw PlanningEngineError.lockedActionOutsideSchedule(actionID)
                }
                changes.append(
                    try PlanChange(
                        kind: .move,
                        actionID: actionID,
                        fromDay: old.day,
                        toDay: new.day,
                        explanation: "The flexible action moves to preserve higher-risk work.",
                        requiresConfirmation: false
                    )
                )
            case (let old?, let new?):
                changes.append(
                    try PlanChange(
                        kind: .preserve,
                        actionID: actionID,
                        fromDay: old.day,
                        toDay: new.day,
                        explanation: new.isLocked
                            ? "The user commitment is protected."
                            : "The action still fits its current day.",
                        requiresConfirmation: false
                    )
                )
            case (nil, nil):
                break
            }
        }

        let protectedFacts = input.snapshot.dailyActions.compactMap { action -> String? in
            guard let deadline = action.deadline,
                  deadline.mutability != .flexible else {
                return nil
            }
            return "\(action.title): deadline \(deadline.value)"
        }.sorted()

        return ReplanProposal(
            trigger: trigger,
            previousDecisionID: previous?.metadata.id,
            proposedDecision: proposed,
            changes: changes,
            protectedFactDescriptions: protectedFacts,
            createdAt: input.createdAt
        )
    }

    private func makeDays(from start: LocalDay, through end: LocalDay) throws -> [LocalDay] {
        let distance = start.distance(to: end)
        guard distance >= 0, distance <= 366 else {
            throw PlanningEngineError.invalidHorizon
        }
        return try (0...distance).map { try start.adding(days: $0) }
    }

    private func availableMinutes(on day: LocalDay, input: PlanningInput) -> Int {
        if let override = input.dailyCapacityOverrides[day] {
            return override
        }
        let profile = input.snapshot.userProfile
        let weekly = profile.weeklyAvailability
            .first { $0.isoWeekday == day.isoWeekday }?
            .availableMinutes ?? 0
        var capacity = min(profile.maximumDailyMinutes, weekly)
        let constraints = input.snapshot.calendarConstraints.filter { $0.block.day == day }
        let hardAvailable = constraints.filter {
            $0.rigidity == .hard && $0.kind == .available
        }
        if hardAvailable.isEmpty == false {
            let explicitAvailable = hardAvailable.reduce(0) { $0 + $1.block.durationMinutes }
            capacity = capacity == 0
                ? min(profile.maximumDailyMinutes, explicitAvailable)
                : min(capacity, explicitAvailable)
        }
        let unavailable = constraints.lazy
            .filter {
                $0.rigidity == .hard && ($0.kind == .busy || $0.kind == .rest)
            }
            .reduce(0) { $0 + $1.block.durationMinutes }
        return max(0, min(1_440, capacity - unavailable))
    }

    private func candidateComesFirst(
        _ lhs: DailyAction,
        _ rhs: DailyAction,
        referenceDay: LocalDay
    ) -> Bool {
        let lhsScore = score(lhs, referenceDay: referenceDay)
        let rhsScore = score(rhs, referenceDay: referenceDay)
        if lhsScore != rhsScore { return lhsScore > rhsScore }
        return actionTieBreak(lhs, rhs)
    }

    private func score(_ action: DailyAction, referenceDay: LocalDay) -> Int64 {
        var result = Int64(action.priority.rawValue) * 1_000_000
        if action.status == .inProgress { result += 400_000 }
        if action.reasonCodes.contains(.userCommitted) { result += 300_000 }
        if action.reasonCodes.contains(.weeklyOutcomeRequired) { result += 200_000 }
        if let deadline = action.deadline?.value {
            let distance = referenceDay.distance(to: deadline)
            if distance < 0 {
                result += 100_000_000 + Int64(abs(distance)) * 1_000
            } else {
                result += Int64(max(0, 366 - distance)) * 10_000
                // Work inside the same urgency window used when explaining a
                // plan must outrank a less urgent priority label. Without this
                // tier, a high-priority action due later can displace an
                // immutable deadline due today, contradicting the planner's
                // protected-deadline contract.
                if distance <= 3 {
                    result += 5_000_000
                }
            }
        }
        result += Int64(max(0, 10 - action.difficulty.rawValue)) * 100
        return result
    }

    private func actionTieBreak(_ lhs: DailyAction, _ rhs: DailyAction) -> Bool {
        let lhsDeadline = lhs.deadline?.value
        let rhsDeadline = rhs.deadline?.value
        if lhsDeadline != rhsDeadline {
            if lhsDeadline == nil { return false }
            if rhsDeadline == nil { return true }
            return lhsDeadline! < rhsDeadline!
        }
        if lhs.estimatedMinutes != rhs.estimatedMinutes {
            return lhs.estimatedMinutes < rhs.estimatedMinutes
        }
        return lhs.metadata.id < rhs.metadata.id
    }

    private func deadlineSeverity(
        for action: DailyAction,
        horizonEnd: LocalDay
    ) -> RiskSeverity {
        guard let deadline = action.deadline?.value else { return .warning }
        return deadline <= horizonEnd ? .critical : .warning
    }

    private func mergedReasons(
        _ lhs: [PlanningReasonCode],
        _ rhs: [PlanningReasonCode]
    ) -> [PlanningReasonCode] {
        Array(Set(lhs + rhs)).sorted { $0.rawValue < $1.rawValue }
    }

    private func severityRank(_ severity: RiskSeverity) -> Int {
        switch severity {
        case .info: 0
        case .warning: 1
        case .critical: 2
        }
    }

    /// Produces a process-independent fingerprint of every value that can
    /// change a planning result. Top-level workspace collections and the
    /// non-string-keyed progress maps are normalized before hashing; the
    /// planning horizon and capacity overrides are part of the same envelope.
    private func planningInputSHA256(_ input: PlanningInput) throws -> String {
        let snapshot = canonicalSnapshot(input.snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let encodedSnapshot = try encoder.encode(snapshot)
        guard var snapshotObject = try JSONSerialization.jsonObject(
            with: encodedSnapshot
        ) as? [String: Any] else {
            throw EncodingError.invalidValue(
                snapshot,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: "The planning snapshot is not a JSON object."
                )
            )
        }
        try normalizeProgressMaps(in: &snapshotObject)

        let capacityOverrides: [[String: Any]] = input.dailyCapacityOverrides
            .sorted { $0.key < $1.key }
            .map { entry in
                [
                    "day": localDayObject(entry.key),
                    "minutes": entry.value
                ]
            }
        let envelope: [String: Any] = [
            "fingerprintSchemaVersion": 3,
            "snapshot": snapshotObject,
            "horizonStart": localDayObject(input.horizonStart),
            "horizonEnd": localDayObject(input.horizonEnd),
            "dailyCapacityOverrides": capacityOverrides
        ]
        let data = try JSONSerialization.data(
            withJSONObject: envelope,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func canonicalSnapshot(
        _ original: NextStepWorkspaceSnapshot
    ) -> NextStepWorkspaceSnapshot {
        var snapshot = original
        snapshot.ultimateGoals.sort { $0.metadata.id < $1.metadata.id }
        snapshot.goals.sort { $0.metadata.id < $1.metadata.id }
        snapshot.milestones.sort { $0.metadata.id < $1.metadata.id }
        snapshot.weeklyOutcomes.sort { $0.metadata.id < $1.metadata.id }
        snapshot.dailyActions.sort { $0.metadata.id < $1.metadata.id }
        snapshot.guidedPackages.sort { $0.metadata.id < $1.metadata.id }
        snapshot.sourceDocuments.sort { $0.metadata.id < $1.metadata.id }
        snapshot.paperSources.sort { $0.metadata.id < $1.metadata.id }
        snapshot.sourceAnchors.sort { $0.metadata.id < $1.metadata.id }
        snapshot.citations.sort { $0.metadata.id < $1.metadata.id }
        snapshot.highlights.sort { $0.metadata.id < $1.metadata.id }
        snapshot.extractedClaims.sort { $0.metadata.id < $1.metadata.id }
        snapshot.evidenceLinks.sort { $0.metadata.id < $1.metadata.id }
        snapshot.completionEvidence.sort { $0.metadata.id < $1.metadata.id }
        snapshot.userResponses.sort { $0.metadata.id < $1.metadata.id }
        snapshot.calendarConstraints.sort { $0.metadata.id < $1.metadata.id }
        snapshot.planningDecisions.sort { $0.metadata.id < $1.metadata.id }
        snapshot.replanEvents.sort { $0.metadata.id < $1.metadata.id }
        snapshot.progressSnapshots.sort { $0.metadata.id < $1.metadata.id }
        return snapshot
    }

    private func localDayObject(_ day: LocalDay) -> [String: Int] {
        ["year": day.year, "month": day.month, "day": day.day]
    }

    /// JSONEncoder represents dictionaries with non-String/Int Codable keys as
    /// alternating key/value arrays. Their iteration order is intentionally
    /// unspecified, so convert the three progress maps into sorted entry lists
    /// before the canonical JSONSerialization pass.
    private func normalizeProgressMaps(in root: inout [String: Any]) throws {
        guard var progressSnapshots = root["progressSnapshots"] as? [[String: Any]] else {
            return
        }
        let mapKeys = ["ultimateGoalProgress", "goalProgress", "milestoneProgress"]
        for index in progressSnapshots.indices {
            for key in mapKeys {
                guard let alternating = progressSnapshots[index][key] as? [Any] else {
                    continue
                }
                guard alternating.count.isMultiple(of: 2) else {
                    throw EncodingError.invalidValue(
                        alternating,
                        EncodingError.Context(
                            codingPath: [],
                            debugDescription: "The progress map has an invalid Codable representation."
                        )
                    )
                }
                var entries: [(sortKey: String, value: [String: Any])] = []
                for pairStart in stride(from: 0, to: alternating.count, by: 2) {
                    let encodedKey = try JSONSerialization.data(
                        withJSONObject: [alternating[pairStart]],
                        options: [.sortedKeys, .withoutEscapingSlashes]
                    )
                    let sortKey = String(decoding: encodedKey, as: UTF8.self)
                    entries.append((
                        sortKey: sortKey,
                        value: [
                            "key": alternating[pairStart],
                            "value": alternating[pairStart + 1]
                        ]
                    ))
                }
                progressSnapshots[index][key] = entries
                    .sorted { $0.sortKey < $1.sortKey }
                    .map { $0.value }
            }
        }
        root["progressSnapshots"] = progressSnapshots
    }

    private func makeRisk(
        kind: PlanningRiskKind,
        severity: RiskSeverity,
        action: DailyAction,
        message: String
    ) throws -> PlanningRisk {
        try PlanningRisk(
            id: stableUUID(
                for: "\(kind.rawValue)|\(severity.rawValue)|\(action.metadata.id)|\(message)"
            ),
            kind: kind,
            severity: severity,
            actionID: action.metadata.id,
            milestoneID: action.milestoneID,
            message: message
        )
    }

    private func stableUUID(for value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
