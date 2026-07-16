import Foundation
import NextStepDomain

public struct TodayAction: Hashable, Identifiable, Sendable {
    public let action: DailyAction
    public let assignment: ScheduledAction
    public let package: GuidedLearningPackage?
    public let milestone: Milestone
    public let goal: Goal
    public let ultimateGoal: UltimateGoal

    public var id: DailyActionID { action.metadata.id }

    public init(
        action: DailyAction,
        assignment: ScheduledAction,
        package: GuidedLearningPackage?,
        milestone: Milestone,
        goal: Goal,
        ultimateGoal: UltimateGoal
    ) {
        self.action = action
        self.assignment = assignment
        self.package = package
        self.milestone = milestone
        self.goal = goal
        self.ultimateGoal = ultimateGoal
    }
}

public struct TodayPlan: Hashable, Sendable {
    public let day: LocalDay
    public let actions: [TodayAction]
    public let totalMinutes: Int
    public let risks: [PlanningRisk]

    public init(
        day: LocalDay,
        actions: [TodayAction],
        totalMinutes: Int,
        risks: [PlanningRisk]
    ) {
        self.day = day
        self.actions = actions
        self.totalMinutes = totalMinutes
        self.risks = risks
    }
}

public enum TodayProjectionError: Error, Equatable, Sendable {
    case danglingAction(DailyActionID)
    case danglingMilestone(MilestoneID)
    case danglingGoal(GoalID)
    case danglingUltimateGoal(UltimateGoalID)
}

public struct TodayProjector: Sendable {
    public init() {}

    public func project(
        day: LocalDay,
        decision: PlanningDecision,
        snapshot: NextStepWorkspaceSnapshot
    ) throws -> TodayPlan {
        let actions = Dictionary(
            uniqueKeysWithValues: snapshot.dailyActions.map { ($0.metadata.id, $0) }
        )
        let packages = Dictionary(
            uniqueKeysWithValues: snapshot.guidedPackages.map { ($0.metadata.id, $0) }
        )
        let milestones = Dictionary(
            uniqueKeysWithValues: snapshot.milestones.map { ($0.metadata.id, $0) }
        )
        let goals = Dictionary(uniqueKeysWithValues: snapshot.goals.map { ($0.metadata.id, $0) })
        let ultimateGoals = Dictionary(
            uniqueKeysWithValues: snapshot.ultimateGoals.map { ($0.metadata.id, $0) }
        )

        let assignments = decision.assignments
            .filter { $0.day == day }
            .sorted {
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.actionID < $1.actionID
            }
        var todayActions: [TodayAction] = []
        for assignment in assignments {
            guard let action = actions[assignment.actionID] else {
                throw TodayProjectionError.danglingAction(assignment.actionID)
            }
            guard let milestone = milestones[action.milestoneID] else {
                throw TodayProjectionError.danglingMilestone(action.milestoneID)
            }
            guard let goal = goals[milestone.goalID] else {
                throw TodayProjectionError.danglingGoal(milestone.goalID)
            }
            guard let ultimateGoal = ultimateGoals[goal.ultimateGoalID] else {
                throw TodayProjectionError.danglingUltimateGoal(goal.ultimateGoalID)
            }
            todayActions.append(
                TodayAction(
                    action: action,
                    assignment: assignment,
                    package: action.packageID.flatMap { packages[$0] },
                    milestone: milestone,
                    goal: goal,
                    ultimateGoal: ultimateGoal
                )
            )
        }
        let actionIDs = Set(todayActions.map(\.id))
        return TodayPlan(
            day: day,
            actions: todayActions,
            totalMinutes: assignments.reduce(0) { $0 + $1.plannedMinutes },
            risks: decision.risks.filter {
                ($0.actionID.map(actionIDs.contains) ?? false) ||
                    $0.severity == .critical
            }
        )
    }
}
