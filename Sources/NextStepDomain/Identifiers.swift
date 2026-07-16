import Foundation

/// A stable, strongly typed UUID. The phantom tag prevents accidentally
/// assigning (for example) a Goal identifier where a Milestone identifier is
/// required, while keeping the encoded representation framework-neutral.
public struct EntityID<Tag>: RawRepresentable, Codable, Hashable, Sendable,
    Comparable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue.uuidString.lowercased()
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.description < rhs.description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum UserProfileTag: Sendable {}
public enum UltimateGoalTag: Sendable {}
public enum GoalTag: Sendable {}
public enum MilestoneTag: Sendable {}
public enum WeeklyOutcomeTag: Sendable {}
public enum DailyActionTag: Sendable {}
public enum GuidedLearningPackageTag: Sendable {}
public enum CourseReferenceTag: Sendable {}
public enum NoteReferenceTag: Sendable {}
public enum SourceDocumentTag: Sendable {}
public enum PaperSourceTag: Sendable {}
public enum CitationTag: Sendable {}
public enum SourceAnchorTag: Sendable {}
public enum HighlightTag: Sendable {}
public enum ExtractedClaimTag: Sendable {}
public enum EvidenceLinkTag: Sendable {}
public enum KnowledgeConceptTag: Sendable {}
public enum KnowledgeLinkTag: Sendable {}
public enum QuizTag: Sendable {}
public enum QuizItemTag: Sendable {}
public enum UserResponseTag: Sendable {}
public enum CompletionEvidenceTag: Sendable {}
public enum ProjectTag: Sendable {}
public enum ThesisTag: Sendable {}
public enum JobTargetTag: Sendable {}
public enum JobApplicationTag: Sendable {}
public enum CalendarConstraintTag: Sendable {}
public enum PlanningDecisionTag: Sendable {}
public enum ReplanEventTag: Sendable {}
public enum ProgressSnapshotTag: Sendable {}
public enum DeviceTag: Sendable {}
public enum OperationTag: Sendable {}

public typealias UserProfileID = EntityID<UserProfileTag>
public typealias UltimateGoalID = EntityID<UltimateGoalTag>
public typealias GoalID = EntityID<GoalTag>
public typealias MilestoneID = EntityID<MilestoneTag>
public typealias WeeklyOutcomeID = EntityID<WeeklyOutcomeTag>
public typealias DailyActionID = EntityID<DailyActionTag>
public typealias GuidedLearningPackageID = EntityID<GuidedLearningPackageTag>
public typealias CourseReferenceID = EntityID<CourseReferenceTag>
public typealias NoteReferenceID = EntityID<NoteReferenceTag>
public typealias SourceDocumentID = EntityID<SourceDocumentTag>
public typealias PaperSourceID = EntityID<PaperSourceTag>
public typealias CitationID = EntityID<CitationTag>
public typealias SourceAnchorID = EntityID<SourceAnchorTag>
public typealias HighlightID = EntityID<HighlightTag>
public typealias ExtractedClaimID = EntityID<ExtractedClaimTag>
public typealias EvidenceLinkID = EntityID<EvidenceLinkTag>
public typealias KnowledgeConceptID = EntityID<KnowledgeConceptTag>
public typealias KnowledgeLinkID = EntityID<KnowledgeLinkTag>
public typealias QuizID = EntityID<QuizTag>
public typealias QuizItemID = EntityID<QuizItemTag>
public typealias UserResponseID = EntityID<UserResponseTag>
public typealias CompletionEvidenceID = EntityID<CompletionEvidenceTag>
public typealias ProjectID = EntityID<ProjectTag>
public typealias ThesisID = EntityID<ThesisTag>
public typealias JobTargetID = EntityID<JobTargetTag>
public typealias JobApplicationID = EntityID<JobApplicationTag>
public typealias CalendarConstraintID = EntityID<CalendarConstraintTag>
public typealias PlanningDecisionID = EntityID<PlanningDecisionTag>
public typealias ReplanEventID = EntityID<ReplanEventTag>
public typealias ProgressSnapshotID = EntityID<ProgressSnapshotTag>
public typealias DeviceID = EntityID<DeviceTag>
public typealias OperationID = EntityID<OperationTag>
