import Foundation
import NotesCore

public enum CourseSessionStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case planned
    case active
    case needsReview
    case reviewed
    case cancelled
}

public struct CourseSession: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: CourseSessionID
    public let courseID: CourseID
    public let revision: Int64
    public let scheduleRuleID: CourseScheduleRuleID?
    public let scheduledInterval: AcademicZonedInterval?
    public let actualStartedAt: Date?
    public let actualEndedAt: Date?
    public let topic: String?
    public let status: CourseSessionStatus
    public let createdAt: Date
    public let modifiedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: CourseSessionID = CourseSessionID(),
        courseID: CourseID,
        revision: Int64 = 1,
        scheduleRuleID: CourseScheduleRuleID? = nil,
        scheduledInterval: AcademicZonedInterval? = nil,
        actualStartedAt: Date? = nil,
        actualEndedAt: Date? = nil,
        topic: String? = nil,
        status: CourseSessionStatus = .planned,
        createdAt: Date = Date(),
        modifiedAt: Date? = nil
    ) throws {
        try AcademicValidation.requireSchema(
            schemaVersion,
            current: Self.currentSchemaVersion,
            entity: "course session"
        )
        try AcademicValidation.requireRevision(revision)
        try AcademicValidation.requireOptionalText(
            topic,
            field: "courseSession.topic",
            maximumCharacters: AcademicDomainLimits.maximumTopicCharacters,
            maximumUTF8Bytes: AcademicDomainLimits.maximumTopicUTF8Bytes,
            allowsNewlines: false
        )
        let resolvedModifiedAt = modifiedAt ?? createdAt
        try AcademicValidation.requireChronology(
            earlier: createdAt,
            later: resolvedModifiedAt,
            detail: "A course session cannot be modified before it is created."
        )
        if let actualStartedAt {
            try AcademicValidation.requireFinite(
                actualStartedAt,
                field: "courseSession.actualStartedAt"
            )
            guard actualStartedAt <= resolvedModifiedAt else {
                throw AcademicDomainError.chronologyViolation(
                    "A session start cannot be later than its modification time."
                )
            }
        }
        if let actualEndedAt {
            try AcademicValidation.requireFinite(
                actualEndedAt,
                field: "courseSession.actualEndedAt"
            )
            guard actualEndedAt <= resolvedModifiedAt else {
                throw AcademicDomainError.chronologyViolation(
                    "A session end cannot be later than its modification time."
                )
            }
        }
        if let actualStartedAt, let actualEndedAt, actualStartedAt > actualEndedAt {
            throw AcademicDomainError.chronologyViolation(
                "A course session cannot end before it starts."
            )
        }
        switch status {
        case .planned, .cancelled:
            guard actualStartedAt == nil, actualEndedAt == nil else {
                throw AcademicDomainError.invalidField("courseSession.statusDates")
            }
        case .active:
            guard actualStartedAt != nil, actualEndedAt == nil else {
                throw AcademicDomainError.invalidField("courseSession.statusDates")
            }
        case .needsReview, .reviewed:
            guard actualStartedAt != nil, actualEndedAt != nil else {
                throw AcademicDomainError.invalidField("courseSession.statusDates")
            }
        }
        self.schemaVersion = schemaVersion
        self.id = id
        self.courseID = courseID
        self.revision = revision
        self.scheduleRuleID = scheduleRuleID
        self.scheduledInterval = scheduledInterval
        self.actualStartedAt = actualStartedAt
        self.actualEndedAt = actualEndedAt
        self.topic = topic
        self.status = status
        self.createdAt = createdAt
        self.modifiedAt = resolvedModifiedAt
    }

    public func transitioned(
        to target: CourseSessionStatus,
        at timestamp: Date
    ) throws -> CourseSession {
        try transitioning(to: target, at: timestamp, permitsReviewedState: false)
    }

    /// Module-internal so only the atomic wrap-up command can produce `reviewed`.
    func completingWrapUp(at timestamp: Date) throws -> CourseSession {
        try transitioning(
            to: .reviewed,
            at: timestamp,
            permitsReviewedState: true
        )
    }

    private func transitioning(
        to target: CourseSessionStatus,
        at timestamp: Date,
        permitsReviewedState: Bool
    ) throws -> CourseSession {
        try AcademicValidation.requireFinite(timestamp, field: "transition.timestamp")
        guard timestamp >= modifiedAt else {
            throw AcademicDomainError.chronologyViolation(
                "A session transition cannot move time backwards."
            )
        }
        let isAllowed = switch (status, target) {
        case (.planned, .active), (.planned, .cancelled),
             (.active, .needsReview):
            true
        case (.active, .reviewed), (.needsReview, .reviewed):
            permitsReviewedState
        default:
            false
        }
        guard isAllowed else {
            throw AcademicDomainError.invalidStateTransition(
                entity: "course session",
                from: status.rawValue,
                to: target.rawValue
            )
        }

        let startedAt: Date?
        let endedAt: Date?
        switch target {
        case .active:
            startedAt = timestamp
            endedAt = nil
        case .needsReview, .reviewed:
            startedAt = actualStartedAt
            endedAt = actualEndedAt ?? timestamp
        case .cancelled:
            startedAt = nil
            endedAt = nil
        case .planned:
            startedAt = actualStartedAt
            endedAt = actualEndedAt
        }

        return try CourseSession(
            id: id,
            courseID: courseID,
            revision: AcademicValidation.nextRevision(after: revision),
            scheduleRuleID: scheduleRuleID,
            scheduledInterval: scheduledInterval,
            actualStartedAt: startedAt,
            actualEndedAt: endedAt,
            topic: topic,
            status: target,
            createdAt: createdAt,
            modifiedAt: timestamp
        )
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, courseID, revision, scheduleRuleID, scheduledInterval
        case actualStartedAt, actualEndedAt, topic, status, createdAt, modifiedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        do {
            try AcademicValidation.requireSchema(
                schemaVersion,
                current: Self.currentSchemaVersion,
                entity: "course session"
            )
            try self.init(
                schemaVersion: schemaVersion,
                id: try values.decode(CourseSessionID.self, forKey: .id),
                courseID: try values.decode(CourseID.self, forKey: .courseID),
                revision: try values.decode(Int64.self, forKey: .revision),
                scheduleRuleID: try values.decodeIfPresent(
                    CourseScheduleRuleID.self,
                    forKey: .scheduleRuleID
                ),
                scheduledInterval: try values.decodeIfPresent(
                    AcademicZonedInterval.self,
                    forKey: .scheduledInterval
                ),
                actualStartedAt: try values.decodeIfPresent(
                    Date.self,
                    forKey: .actualStartedAt
                ),
                actualEndedAt: try values.decodeIfPresent(Date.self, forKey: .actualEndedAt),
                topic: try values.decodeIfPresent(String.self, forKey: .topic),
                status: try values.decode(CourseSessionStatus.self, forKey: .status),
                createdAt: try values.decode(Date.self, forKey: .createdAt),
                modifiedAt: try values.decode(Date.self, forKey: .modifiedAt)
            )
        } catch let error as AcademicDomainError {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: error.localizedDescription
            )
        }
    }
}

public struct SessionNoteLink: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: SessionNoteLinkID
    public let sessionID: CourseSessionID
    public let noteID: NotebookID
    public let initialPageID: PageID?
    public let revision: Int64
    public let linkedAt: Date
    public let unlinkedAt: Date?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: SessionNoteLinkID = SessionNoteLinkID(),
        sessionID: CourseSessionID,
        noteID: NotebookID,
        initialPageID: PageID? = nil,
        revision: Int64 = 1,
        linkedAt: Date = Date(),
        unlinkedAt: Date? = nil
    ) throws {
        try AcademicValidation.requireSchema(
            schemaVersion,
            current: Self.currentSchemaVersion,
            entity: "session note link"
        )
        try AcademicValidation.requireRevision(revision)
        try AcademicValidation.requireFinite(linkedAt, field: "sessionNoteLink.linkedAt")
        if let unlinkedAt {
            try AcademicValidation.requireChronology(
                earlier: linkedAt,
                later: unlinkedAt,
                detail: "A note link cannot be removed before it is created."
            )
        }
        self.schemaVersion = schemaVersion
        self.id = id
        self.sessionID = sessionID
        self.noteID = noteID
        self.initialPageID = initialPageID
        self.revision = revision
        self.linkedAt = linkedAt
        self.unlinkedAt = unlinkedAt
    }

    public var isActive: Bool { unlinkedAt == nil }

    public func unlinking(at timestamp: Date) throws -> SessionNoteLink {
        guard isActive else {
            throw AcademicDomainError.invalidStateTransition(
                entity: "session note link",
                from: "unlinked",
                to: "unlinked"
            )
        }
        return try SessionNoteLink(
            id: id,
            sessionID: sessionID,
            noteID: noteID,
            initialPageID: initialPageID,
            revision: AcademicValidation.nextRevision(after: revision),
            linkedAt: linkedAt,
            unlinkedAt: timestamp
        )
    }

    public static func validatedCollection(_ links: [Self]) throws -> [Self] {
        guard links.count <= AcademicDomainLimits.maximumSessionNoteLinks else {
            throw AcademicDomainError.valueOutOfBounds(field: "sessionNoteLinks")
        }
        try AcademicValidation.requireUnique(links.map(\.id), entity: "session note link")
        var activeSessions = Set<CourseSessionID>()
        for link in links where link.isActive {
            guard activeSessions.insert(link.sessionID).inserted else {
                throw AcademicDomainError.relationshipMismatch(
                    "A course session can have only one active note link."
                )
            }
        }
        return links.sorted {
            if $0.sessionID != $1.sessionID { return $0.sessionID < $1.sessionID }
            if $0.linkedAt != $1.linkedAt { return $0.linkedAt < $1.linkedAt }
            return $0.id < $1.id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, sessionID, noteID, initialPageID, revision
        case linkedAt, unlinkedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        do {
            try AcademicValidation.requireSchema(
                schemaVersion,
                current: Self.currentSchemaVersion,
                entity: "session note link"
            )
            try self.init(
                schemaVersion: schemaVersion,
                id: try values.decode(SessionNoteLinkID.self, forKey: .id),
                sessionID: try values.decode(CourseSessionID.self, forKey: .sessionID),
                noteID: try values.decode(NotebookID.self, forKey: .noteID),
                initialPageID: try values.decodeIfPresent(PageID.self, forKey: .initialPageID),
                revision: try values.decode(Int64.self, forKey: .revision),
                linkedAt: try values.decode(Date.self, forKey: .linkedAt),
                unlinkedAt: try values.decodeIfPresent(Date.self, forKey: .unlinkedAt)
            )
        } catch let error as AcademicDomainError {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: error.localizedDescription
            )
        }
    }
}
