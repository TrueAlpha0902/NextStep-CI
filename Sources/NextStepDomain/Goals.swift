import Foundation

public enum OnboardingState: String, Codable, CaseIterable, Hashable, Sendable {
    case notStarted
    case goalsNeeded
    case availabilityNeeded
    case ready
}

public struct WeeklyAvailability: Codable, Hashable, Sendable {
    /// ISO weekday (Monday = 1, Sunday = 7).
    public let isoWeekday: Int
    public let availableMinutes: Int
    public let preferredStartMinute: Int?

    public init(
        isoWeekday: Int,
        availableMinutes: Int,
        preferredStartMinute: Int? = nil
    ) throws {
        guard (1...7).contains(isoWeekday),
              (0...1_440).contains(availableMinutes),
              preferredStartMinute.map({ (0..<1_440).contains($0) }) ?? true else {
            throw DomainValidationError.valueOutOfBounds("weeklyAvailability")
        }
        self.isoWeekday = isoWeekday
        self.availableMinutes = availableMinutes
        self.preferredStartMinute = preferredStartMinute
    }
}

public struct UserProfile: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<UserProfileID>
    public var localeIdentifier: String
    public var timeZoneIdentifier: String
    public var weeklyAvailability: [WeeklyAvailability]
    public var preferredSessionMinutes: Int
    public var maximumDailyMinutes: Int
    public var onboardingState: OnboardingState
    public var reduceMotion: Bool
    public var prefersMoreExamples: Bool

    public init(
        metadata: RecordMetadata<UserProfileID>,
        localeIdentifier: String,
        timeZoneIdentifier: String,
        weeklyAvailability: [WeeklyAvailability],
        preferredSessionMinutes: Int = 35,
        maximumDailyMinutes: Int = 240,
        onboardingState: OnboardingState = .notStarted,
        reduceMotion: Bool = false,
        prefersMoreExamples: Bool = false
    ) throws {
        guard Locale(identifier: localeIdentifier).identifier.isEmpty == false else {
            throw DomainValidationError.invalidField("localeIdentifier")
        }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw DomainValidationError.invalidField("timeZoneIdentifier")
        }
        guard (5...240).contains(preferredSessionMinutes),
              (0...1_440).contains(maximumDailyMinutes) else {
            throw DomainValidationError.valueOutOfBounds("workload preference")
        }
        let weekdays = weeklyAvailability.map(\.isoWeekday)
        guard Set(weekdays).count == weekdays.count else {
            throw DomainValidationError.invalidField("duplicate weekly availability")
        }
        self.metadata = metadata
        self.localeIdentifier = localeIdentifier
        self.timeZoneIdentifier = timeZoneIdentifier
        self.weeklyAvailability = weeklyAvailability.sorted { $0.isoWeekday < $1.isoWeekday }
        self.preferredSessionMinutes = preferredSessionMinutes
        self.maximumDailyMinutes = maximumDailyMinutes
        self.onboardingState = onboardingState
        self.reduceMotion = reduceMotion
        self.prefersMoreExamples = prefersMoreExamples
    }
}

public struct UltimateGoal: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<UltimateGoalID>
    public var title: String
    public var definitionOfDone: String
    public var targetDay: FactValue<LocalDay>?
    public var status: GoalStatus
    public var priority: Priority

    public init(
        metadata: RecordMetadata<UltimateGoalID>,
        title: String,
        definitionOfDone: String,
        targetDay: FactValue<LocalDay>? = nil,
        status: GoalStatus = .active,
        priority: Priority = .normal
    ) throws {
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              definitionOfDone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw DomainValidationError.invalidField("ultimateGoal")
        }
        self.metadata = metadata
        self.title = title
        self.definitionOfDone = definitionOfDone
        self.targetDay = targetDay
        self.status = status
        self.priority = priority
    }
}

public struct Goal: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<GoalID>
    public let ultimateGoalID: UltimateGoalID
    public var title: String
    public var outcome: String
    public var targetDay: FactValue<LocalDay>?
    public var status: GoalStatus
    public var priority: Priority

    public init(
        metadata: RecordMetadata<GoalID>,
        ultimateGoalID: UltimateGoalID,
        title: String,
        outcome: String,
        targetDay: FactValue<LocalDay>? = nil,
        status: GoalStatus = .active,
        priority: Priority = .normal
    ) throws {
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw DomainValidationError.invalidField("goal")
        }
        self.metadata = metadata
        self.ultimateGoalID = ultimateGoalID
        self.title = title
        self.outcome = outcome
        self.targetDay = targetDay
        self.status = status
        self.priority = priority
    }
}

public struct Milestone: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<MilestoneID>
    public let goalID: GoalID
    public var title: String
    public var outcome: String
    public var dependencyIDs: [MilestoneID]
    public var targetDay: FactValue<LocalDay>?
    public var completionCriteria: [CompletionCriterion]
    public var status: GoalStatus
    public var progressFraction: Double

    public init(
        metadata: RecordMetadata<MilestoneID>,
        goalID: GoalID,
        title: String,
        outcome: String,
        dependencyIDs: [MilestoneID] = [],
        targetDay: FactValue<LocalDay>? = nil,
        completionCriteria: [CompletionCriterion],
        status: GoalStatus = .active,
        progressFraction: Double = 0
    ) throws {
        guard title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw DomainValidationError.invalidField("milestone")
        }
        guard (0...1).contains(progressFraction) else {
            throw DomainValidationError.valueOutOfBounds("progressFraction")
        }
        guard Set(dependencyIDs).count == dependencyIDs.count,
              dependencyIDs.contains(metadata.id) == false else {
            throw DomainValidationError.invalidField("milestone dependencies")
        }
        self.metadata = metadata
        self.goalID = goalID
        self.title = title
        self.outcome = outcome
        self.dependencyIDs = dependencyIDs.sorted()
        self.targetDay = targetDay
        self.completionCriteria = completionCriteria
        self.status = status
        self.progressFraction = progressFraction
    }
}

public enum OutcomeStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case planned
    case inProgress
    case achieved
    case missed
    case replanned
}

public struct WeeklyOutcome: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<WeeklyOutcomeID>
    public let milestoneID: MilestoneID
    public let weekStart: LocalDay
    public var requiredArtifact: String
    public var plannedEffortMinutes: Int
    public var status: OutcomeStatus

    public init(
        metadata: RecordMetadata<WeeklyOutcomeID>,
        milestoneID: MilestoneID,
        weekStart: LocalDay,
        requiredArtifact: String,
        plannedEffortMinutes: Int,
        status: OutcomeStatus = .planned
    ) throws {
        guard requiredArtifact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw DomainValidationError.invalidField("requiredArtifact")
        }
        guard (1...10_080).contains(plannedEffortMinutes) else {
            throw DomainValidationError.valueOutOfBounds("plannedEffortMinutes")
        }
        self.metadata = metadata
        self.milestoneID = milestoneID
        self.weekStart = weekStart
        self.requiredArtifact = requiredArtifact
        self.plannedEffortMinutes = plannedEffortMinutes
        self.status = status
    }
}
