import Foundation
import NextStepDomain
@testable import NextStepPlanning
import XCTest

final class PlanningEngineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_782_835_200)
    private let day1 = try! LocalDay(year: 2026, month: 7, day: 15)
    private let deviceID = DeviceID(
        UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    )

    func testDependencyIsScheduledOnALaterDayNotTheSameDay() throws {
        let fixture = try makeFixture(capacityPerDay: 60)
        let prerequisite = try makeAction(
            id: 40,
            milestoneID: fixture.milestone.metadata.id,
            title: "Read verified source",
            minutes: 30,
            deadline: try day1.adding(days: 3)
        )
        let dependent = try makeAction(
            id: 41,
            milestoneID: fixture.milestone.metadata.id,
            title: "Write evidence paragraph",
            minutes: 30,
            deadline: try day1.adding(days: 3),
            dependencies: [prerequisite.metadata.id]
        )
        var snapshot = fixture.snapshot
        snapshot.dailyActions = [prerequisite, dependent]
        try snapshot.validateRelationships()

        let decision = try PlanningEngine().plan(
            try PlanningInput(
                snapshot: snapshot,
                horizonStart: day1,
                horizonEnd: try day1.adding(days: 2),
                createdAt: now
            ),
            decisionID: PlanningDecisionID(fixedUUID(90)),
            originDeviceID: deviceID
        )
        let byID = Dictionary(
            uniqueKeysWithValues: decision.assignments.map { ($0.actionID, $0.day) }
        )
        XCTAssertEqual(byID[prerequisite.metadata.id], day1)
        XCTAssertEqual(byID[dependent.metadata.id], try day1.adding(days: 1))
    }

    func testHardDeadlineOutranksLowerRiskAction() throws {
        let fixture = try makeFixture(capacityPerDay: 30)
        let later = try makeAction(
            id: 42,
            milestoneID: fixture.milestone.metadata.id,
            title: "Optional practice",
            minutes: 30,
            priority: .high,
            deadline: try day1.adding(days: 10)
        )
        let urgent = try makeAction(
            id: 43,
            milestoneID: fixture.milestone.metadata.id,
            title: "Submit required paragraph",
            minutes: 30,
            priority: .normal,
            deadline: day1
        )
        var snapshot = fixture.snapshot
        snapshot.dailyActions = [later, urgent]
        try snapshot.validateRelationships()

        let decision = try PlanningEngine().plan(
            try PlanningInput(
                snapshot: snapshot,
                horizonStart: day1,
                horizonEnd: try day1.adding(days: 1),
                createdAt: now
            ),
            originDeviceID: deviceID
        )
        XCTAssertEqual(decision.assignments.first?.actionID, urgent.metadata.id)
        XCTAssertEqual(decision.assignments.first?.day, day1)
    }

    func testReplanPreservesLockedCommitmentEvenWhenCapacityDrops() throws {
        let fixture = try makeFixture(capacityPerDay: 60)
        let locked = try makeAction(
            id: 44,
            milestoneID: fixture.milestone.metadata.id,
            title: "Attend confirmed oral defense",
            minutes: 60,
            deadline: day1,
            scheduledDay: day1,
            flexibility: .locked
        )
        var snapshot = fixture.snapshot
        snapshot.dailyActions = [locked]
        try snapshot.validateRelationships()
        let engine = PlanningEngine()
        let first = try engine.plan(
            try PlanningInput(
                snapshot: snapshot,
                horizonStart: day1,
                horizonEnd: day1,
                createdAt: now
            ),
            originDeviceID: deviceID
        )
        let proposal = try engine.replan(
            try PlanningInput(
                snapshot: snapshot,
                horizonStart: day1,
                horizonEnd: day1,
                dailyCapacityOverrides: [day1: 0],
                createdAt: now.addingTimeInterval(60)
            ),
            previous: first,
            trigger: .insufficientTime,
            originDeviceID: deviceID
        )

        XCTAssertEqual(proposal.proposedDecision.assignments.first?.day, day1)
        XCTAssertEqual(proposal.changes.first?.kind, .preserve)
        XCTAssertTrue(proposal.proposedDecision.risks.contains {
            $0.kind == .overloadedDay && $0.severity == .critical
        })
        XCTAssertTrue(proposal.protectedFactDescriptions.contains {
            $0.contains("deadline 2026-07-15")
        })
    }

    func testNoCapacityProducesExplicitRiskInsteadOfSilentDrop() throws {
        let fixture = try makeFixture(capacityPerDay: 0)
        let action = try makeAction(
            id: 45,
            milestoneID: fixture.milestone.metadata.id,
            title: "Complete required analysis",
            minutes: 45,
            deadline: day1
        )
        var snapshot = fixture.snapshot
        snapshot.dailyActions = [action]
        try snapshot.validateRelationships()

        let decision = try PlanningEngine().plan(
            try PlanningInput(
                snapshot: snapshot,
                horizonStart: day1,
                horizonEnd: day1,
                createdAt: now
            ),
            originDeviceID: deviceID
        )
        XCTAssertTrue(decision.assignments.isEmpty)
        XCTAssertEqual(decision.rejectedActions.first?.reason, .insufficientCapacity)
        XCTAssertTrue(decision.risks.contains {
            $0.actionID == action.metadata.id && $0.severity == .critical
        })
    }

    func testIdenticalInputProducesIdenticalAssignmentsAndRiskIDs() throws {
        let fixture = try makeFixture(capacityPerDay: 0)
        let action = try makeAction(
            id: 46,
            milestoneID: fixture.milestone.metadata.id,
            title: "Prepare interview evidence",
            minutes: 30,
            deadline: day1
        )
        var snapshot = fixture.snapshot
        snapshot.dailyActions = [action]
        let input = try PlanningInput(
            snapshot: snapshot,
            horizonStart: day1,
            horizonEnd: day1,
            createdAt: now
        )
        let engine = PlanningEngine()
        let first = try engine.plan(
            input,
            decisionID: PlanningDecisionID(fixedUUID(91)),
            originDeviceID: deviceID
        )
        let second = try engine.plan(
            input,
            decisionID: PlanningDecisionID(fixedUUID(91)),
            originDeviceID: deviceID
        )
        XCTAssertEqual(first, second)
    }

    func testInputFingerprintIsCanonicalForCollectionAndDictionaryOrder() throws {
        let fixture = try makeFixture(capacityPerDay: 0)
        let firstAction = try makeAction(
            id: 48,
            milestoneID: fixture.milestone.metadata.id,
            title: "Read source A",
            minutes: 20,
            deadline: try day1.adding(days: 2)
        )
        let secondAction = try makeAction(
            id: 49,
            milestoneID: fixture.milestone.metadata.id,
            title: "Read source B",
            minutes: 20,
            deadline: try day1.adding(days: 2)
        )
        let day2 = try day1.adding(days: 1)
        var forwardSnapshot = fixture.snapshot
        forwardSnapshot.dailyActions = [firstAction, secondAction]
        var reverseSnapshot = fixture.snapshot
        reverseSnapshot.dailyActions = [secondAction, firstAction]

        let firstProgressID = MilestoneID(fixedUUID(60))
        let secondProgressID = MilestoneID(fixedUUID(61))
        var forwardProgress: [MilestoneID: Double] = [:]
        forwardProgress[firstProgressID] = 0.25
        forwardProgress[secondProgressID] = 0.75
        var reverseProgress: [MilestoneID: Double] = [:]
        reverseProgress[secondProgressID] = 0.75
        reverseProgress[firstProgressID] = 0.25
        forwardSnapshot.progressSnapshots = [try ProgressSnapshot(
            metadata: metadata(ProgressSnapshotID(fixedUUID(62))),
            capturedAt: now,
            planRevision: 0,
            ultimateGoalProgress: [:],
            goalProgress: [:],
            milestoneProgress: forwardProgress,
            completedActionCount: 0,
            totalActionCount: 0,
            atRiskMilestoneIDs: []
        )]
        reverseSnapshot.progressSnapshots = [try ProgressSnapshot(
            metadata: metadata(ProgressSnapshotID(fixedUUID(62))),
            capturedAt: now,
            planRevision: 0,
            ultimateGoalProgress: [:],
            goalProgress: [:],
            milestoneProgress: reverseProgress,
            completedActionCount: 0,
            totalActionCount: 0,
            atRiskMilestoneIDs: []
        )]

        var forwardOverrides: [LocalDay: Int] = [:]
        forwardOverrides[day1] = 20
        forwardOverrides[day2] = 40
        var reverseOverrides: [LocalDay: Int] = [:]
        reverseOverrides[day2] = 40
        reverseOverrides[day1] = 20

        let engine = PlanningEngine()
        let forward = try engine.plan(
            try PlanningInput(
                snapshot: forwardSnapshot,
                horizonStart: day1,
                horizonEnd: day2,
                dailyCapacityOverrides: forwardOverrides,
                createdAt: now
            ),
            originDeviceID: deviceID
        )
        let reverse = try engine.plan(
            try PlanningInput(
                snapshot: reverseSnapshot,
                horizonStart: day1,
                horizonEnd: day2,
                dailyCapacityOverrides: reverseOverrides,
                createdAt: now
            ),
            originDeviceID: deviceID
        )

        XCTAssertEqual(forward.inputSnapshotSHA256, reverse.inputSnapshotSHA256)
        XCTAssertEqual(forward.assignments, reverse.assignments)
    }

    func testInputFingerprintIncludesHorizonAndCapacityOverrides() throws {
        let fixture = try makeFixture(capacityPerDay: 60)
        let day2 = try day1.adding(days: 1)
        let engine = PlanningEngine()
        let baseline = try engine.plan(
            try PlanningInput(
                snapshot: fixture.snapshot,
                horizonStart: day1,
                horizonEnd: day1,
                createdAt: now
            ),
            originDeviceID: deviceID
        )
        let changedHorizon = try engine.plan(
            try PlanningInput(
                snapshot: fixture.snapshot,
                horizonStart: day1,
                horizonEnd: day2,
                createdAt: now
            ),
            originDeviceID: deviceID
        )
        let changedCapacity = try engine.plan(
            try PlanningInput(
                snapshot: fixture.snapshot,
                horizonStart: day1,
                horizonEnd: day1,
                dailyCapacityOverrides: [day1: 10],
                createdAt: now
            ),
            originDeviceID: deviceID
        )

        XCTAssertNotEqual(baseline.inputSnapshotSHA256, changedHorizon.inputSnapshotSHA256)
        XCTAssertNotEqual(baseline.inputSnapshotSHA256, changedCapacity.inputSnapshotSHA256)
        XCTAssertNotEqual(changedHorizon.inputSnapshotSHA256, changedCapacity.inputSnapshotSHA256)
    }

    func testPlanningDecisionDecodingCannotBypassHashOrAssignmentValidation() throws {
        let fixture = try makeFixture(capacityPerDay: 60)
        let action = try makeAction(
            id: 50,
            milestoneID: fixture.milestone.metadata.id,
            title: "Prepare verified output",
            minutes: 30,
            deadline: day1
        )
        var snapshot = fixture.snapshot
        snapshot.dailyActions = [action]
        let decision = try PlanningEngine().plan(
            try PlanningInput(
                snapshot: snapshot,
                horizonStart: day1,
                horizonEnd: day1,
                createdAt: now
            ),
            originDeviceID: deviceID
        )

        let invalidHash = try mutatedJSONObject(from: decision) { root in
            root["inputSnapshotSHA256"] = String(repeating: "g", count: 64)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(PlanningDecision.self, from: invalidHash))

        let duplicateAssignment = try mutatedJSONObject(from: decision) { root in
            let assignments = try XCTUnwrap(root["assignments"] as? [Any])
            let first = try XCTUnwrap(assignments.first)
            root["assignments"] = [first, first]
        }
        XCTAssertThrowsError(try JSONDecoder().decode(
            PlanningDecision.self,
            from: duplicateAssignment
        ))
    }

    func testCompleteActionUpdatesProgressAndReplanRemovesWork() throws {
        let fixture = try makeFixture(capacityPerDay: 60)
        let action = try makeAction(
            id: 47,
            milestoneID: fixture.milestone.metadata.id,
            title: "Produce reviewed paragraph",
            minutes: 30,
            deadline: try day1.adding(days: 2)
        )
        var snapshot = fixture.snapshot
        snapshot.dailyActions = [action]
        let engine = PlanningEngine()
        let first = try engine.plan(
            try PlanningInput(
                snapshot: snapshot,
                horizonStart: day1,
                horizonEnd: try day1.adding(days: 1),
                createdAt: now
            ),
            originDeviceID: deviceID
        )
        let evidence = try CompletionEvidence(
            metadata: metadata(CompletionEvidenceID(fixedUUID(70))),
            actionID: action.metadata.id,
            kind: .artifactReference,
            value: "local://artifact/paragraph-1",
            capturedAt: now.addingTimeInterval(300),
            criterionIDs: action.completionCriteria.map(\.id)
        )
        let completed = try ExecutionService().completeAction(
            action.metadata.id,
            evidence: [evidence],
            in: snapshot,
            at: now.addingTimeInterval(300),
            progressSnapshotID: ProgressSnapshotID(fixedUUID(71)),
            originDeviceID: deviceID,
            currentDecision: first
        )
        XCTAssertEqual(completed.dailyActions.first?.status, .completed)
        XCTAssertEqual(completed.progressSnapshots.last?.completedActionCount, 1)
        XCTAssertEqual(
            completed.progressSnapshots.last?.milestoneProgress[fixture.milestone.metadata.id],
            1
        )

        let proposal = try engine.replan(
            try PlanningInput(
                snapshot: completed,
                horizonStart: day1,
                horizonEnd: try day1.adding(days: 1),
                createdAt: now.addingTimeInterval(301)
            ),
            previous: first,
            trigger: .actionCompleted,
            originDeviceID: deviceID
        )
        XCTAssertTrue(proposal.proposedDecision.assignments.isEmpty)
        XCTAssertEqual(proposal.changes.first?.kind, .remove)
        XCTAssertFalse(proposal.changes.first?.requiresConfirmation ?? true)
    }

    private struct Fixture {
        let snapshot: NextStepWorkspaceSnapshot
        let milestone: Milestone
    }

    private func makeFixture(capacityPerDay: Int) throws -> Fixture {
        let availability = try (1...7).map {
            try WeeklyAvailability(isoWeekday: $0, availableMinutes: capacityPerDay)
        }
        let profile = try UserProfile(
            metadata: metadata(UserProfileID(fixedUUID(2))),
            localeIdentifier: "zh_TW",
            timeZoneIdentifier: "Asia/Taipei",
            weeklyAvailability: availability,
            maximumDailyMinutes: 240,
            onboardingState: .ready
        )
        let ultimate = try UltimateGoal(
            metadata: metadata(UltimateGoalID(fixedUUID(10))),
            title: "Graduate",
            definitionOfDone: "Degree awarded"
        )
        let goal = try Goal(
            metadata: metadata(GoalID(fixedUUID(20))),
            ultimateGoalID: ultimate.metadata.id,
            title: "Complete thesis",
            outcome: "Thesis approved"
        )
        let criterion = try CompletionCriterion(
            kind: .outputExists,
            title: "The artifact exists"
        )
        let milestone = try Milestone(
            metadata: metadata(MilestoneID(fixedUUID(30))),
            goalID: goal.metadata.id,
            title: "Finish literature review",
            outcome: "Reviewed evidence matrix",
            completionCriteria: [criterion]
        )
        let snapshot = try NextStepWorkspaceSnapshot(
            savedAt: now,
            userProfile: profile,
            ultimateGoals: [ultimate],
            goals: [goal],
            milestones: [milestone]
        )
        return Fixture(snapshot: snapshot, milestone: milestone)
    }

    private func makeAction(
        id: UInt8,
        milestoneID: MilestoneID,
        title: String,
        minutes: Int,
        priority: Priority = .normal,
        deadline: LocalDay,
        scheduledDay: LocalDay? = nil,
        flexibility: ActionFlexibility = .movable,
        dependencies: [DailyActionID] = []
    ) throws -> DailyAction {
        let deadlineFact = try FactValue(
            value: deadline,
            authority: .userConfirmed,
            mutability: .immutable,
            confirmedAt: now
        )
        let output = try RequiredOutput(
            kind: .artifact,
            title: "Saved artifact",
            validationKind: .exists
        )
        let criterion = try CompletionCriterion(
            kind: .outputExists,
            title: "The artifact is saved"
        )
        return try DailyAction(
            metadata: metadata(DailyActionID(fixedUUID(id))),
            milestoneID: milestoneID,
            title: title,
            whyToday: "This action advances the confirmed milestone.",
            estimatedMinutes: minutes,
            difficulty: .moderate,
            priority: priority,
            deadline: deadlineFact,
            scheduledDay: scheduledDay,
            flexibility: flexibility,
            dependencyActionIDs: dependencies,
            requiredOutput: output,
            completionCriteria: [criterion],
            status: .ready
        )
    }

    private func metadata<ID>(_ id: ID) throws -> RecordMetadata<ID>
    where ID: Codable & Hashable & Sendable {
        try RecordMetadata(
            id: id,
            createdAt: now,
            originDeviceID: deviceID
        )
    }

    private func fixedUUID(_ suffix: UInt8) -> UUID {
        UUID(uuid: (
            0, 0, 0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0,
            0, 0, 0, suffix
        ))
    }

    private func mutatedJSONObject<Value: Encodable>(
        from value: Value,
        mutate: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        try mutate(&root)
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}
