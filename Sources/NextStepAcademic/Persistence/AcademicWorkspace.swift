import Foundation
import NotesCore

/// Fixed safety limits for the V1 academic workspace format.
///
/// These limits are part of the persistence contract. They are intentionally not
/// configurable by a file backing or caller.
public enum AcademicWorkspaceLimits {
    public static let maximumEncodedBytes = 16 * 1_024 * 1_024
    public static let maximumCourses = 10_000
    public static let maximumScheduleRules = 100_000
    public static let maximumSessions = 100_000
    public static let maximumSessionNoteLinks = 100_000
    public static let maximumCaptures = 100_000
    public static let maximumCaptureAuditEntries = 250_000
    public static let maximumWrapUps = 100_000
    public static let maximumReviewedCaptureReferences = 250_000
}

/// The revision-free portion of an academic workspace.
///
/// Store callers submit content rather than a complete workspace so that only
/// `NextStepAcademicStore` can advance the workspace revision.
public struct AcademicWorkspaceContent: Equatable, Sendable {
    public let courses: [Course]
    public let sessions: [CourseSession]
    public let sessionNoteLinks: [SessionNoteLink]
    public let captures: [CaptureItem]
    public let wrapUps: [SessionWrapUp]

    public static let empty = AcademicWorkspaceContent(
        validatedCourses: [],
        sessions: [],
        sessionNoteLinks: [],
        captures: [],
        wrapUps: []
    )

    public init(
        courses: [Course] = [],
        sessions: [CourseSession] = [],
        sessionNoteLinks: [SessionNoteLink] = [],
        captures: [CaptureItem] = [],
        wrapUps: [SessionWrapUp] = []
    ) throws {
        let canonical = try AcademicWorkspaceValidator.validateAndCanonicalize(
            courses: courses,
            sessions: sessions,
            sessionNoteLinks: sessionNoteLinks,
            captures: captures,
            wrapUps: wrapUps
        )
        self.init(
            validatedCourses: canonical.courses,
            sessions: canonical.sessions,
            sessionNoteLinks: canonical.sessionNoteLinks,
            captures: canonical.captures,
            wrapUps: canonical.wrapUps
        )
    }

    fileprivate init(
        validatedCourses courses: [Course],
        sessions: [CourseSession],
        sessionNoteLinks: [SessionNoteLink],
        captures: [CaptureItem],
        wrapUps: [SessionWrapUp]
    ) {
        self.courses = courses
        self.sessions = sessions
        self.sessionNoteLinks = sessionNoteLinks
        self.captures = captures
        self.wrapUps = wrapUps
    }
}

/// Schema V1 envelope for all local NextStep academic state.
public struct AcademicWorkspace: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let emptySavedAt = Date(timeIntervalSince1970: 0)
    public static let empty = AcademicWorkspace(
        validatedSchemaVersion: currentSchemaVersion,
        revision: 0,
        savedAt: emptySavedAt,
        content: .empty
    )

    public let schemaVersion: Int
    public let revision: Int64
    public let savedAt: Date
    public let courses: [Course]
    public let sessions: [CourseSession]
    public let sessionNoteLinks: [SessionNoteLink]
    public let captures: [CaptureItem]
    public let wrapUps: [SessionWrapUp]

    public var content: AcademicWorkspaceContent {
        AcademicWorkspaceContent(
            validatedCourses: courses,
            sessions: sessions,
            sessionNoteLinks: sessionNoteLinks,
            captures: captures,
            wrapUps: wrapUps
        )
    }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        revision: Int64,
        savedAt: Date,
        courses: [Course] = [],
        sessions: [CourseSession] = [],
        sessionNoteLinks: [SessionNoteLink] = [],
        captures: [CaptureItem] = [],
        wrapUps: [SessionWrapUp] = []
    ) throws {
        try self.init(
            schemaVersion: schemaVersion,
            revision: revision,
            savedAt: savedAt,
            content: AcademicWorkspaceContent(
                courses: courses,
                sessions: sessions,
                sessionNoteLinks: sessionNoteLinks,
                captures: captures,
                wrapUps: wrapUps
            )
        )
    }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        revision: Int64,
        savedAt: Date,
        content: AcademicWorkspaceContent
    ) throws {
        try AcademicValidation.requireSchema(
            schemaVersion,
            current: Self.currentSchemaVersion,
            entity: "academic workspace"
        )
        guard revision >= 0 else {
            throw AcademicDomainError.valueOutOfBounds(field: "workspace.revision")
        }
        try AcademicValidation.requireFinite(savedAt, field: "workspace.savedAt")
        try AcademicWorkspaceValidator.validateSavedAt(savedAt, content: content)
        self.init(
            validatedSchemaVersion: schemaVersion,
            revision: revision,
            savedAt: savedAt,
            content: content
        )
    }

    private init(
        validatedSchemaVersion schemaVersion: Int,
        revision: Int64,
        savedAt: Date,
        content: AcademicWorkspaceContent
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.savedAt = savedAt
        courses = content.courses
        sessions = content.sessions
        sessionNoteLinks = content.sessionNoteLinks
        captures = content.captures
        wrapUps = content.wrapUps
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, savedAt, courses, sessions
        case sessionNoteLinks, captures, wrapUps
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        do {
            try AcademicValidation.requireSchema(
                schemaVersion,
                current: Self.currentSchemaVersion,
                entity: "academic workspace"
            )
            let courses = try AcademicValidation.decodeBoundedArray(
                Course.self,
                from: values,
                forKey: .courses,
                maximumCount: AcademicWorkspaceLimits.maximumCourses,
                field: "workspace.courses"
            )
            let sessions = try AcademicValidation.decodeBoundedArray(
                CourseSession.self,
                from: values,
                forKey: .sessions,
                maximumCount: AcademicWorkspaceLimits.maximumSessions,
                field: "workspace.sessions"
            )
            let sessionNoteLinks = try AcademicValidation.decodeBoundedArray(
                SessionNoteLink.self,
                from: values,
                forKey: .sessionNoteLinks,
                maximumCount: AcademicWorkspaceLimits.maximumSessionNoteLinks,
                field: "workspace.sessionNoteLinks"
            )
            let captures = try AcademicValidation.decodeBoundedArray(
                CaptureItem.self,
                from: values,
                forKey: .captures,
                maximumCount: AcademicWorkspaceLimits.maximumCaptures,
                field: "workspace.captures"
            )
            let wrapUps = try AcademicValidation.decodeBoundedArray(
                SessionWrapUp.self,
                from: values,
                forKey: .wrapUps,
                maximumCount: AcademicWorkspaceLimits.maximumWrapUps,
                field: "workspace.wrapUps"
            )
            try self.init(
                schemaVersion: schemaVersion,
                revision: try values.decode(Int64.self, forKey: .revision),
                savedAt: try values.decode(Date.self, forKey: .savedAt),
                courses: courses,
                sessions: sessions,
                sessionNoteLinks: sessionNoteLinks,
                captures: captures,
                wrapUps: wrapUps
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

private struct CanonicalAcademicWorkspaceContent {
    let courses: [Course]
    let sessions: [CourseSession]
    let sessionNoteLinks: [SessionNoteLink]
    let captures: [CaptureItem]
    let wrapUps: [SessionWrapUp]
}

private enum AcademicWorkspaceValidator {
    static func validateAndCanonicalize(
        courses: [Course],
        sessions: [CourseSession],
        sessionNoteLinks: [SessionNoteLink],
        captures: [CaptureItem],
        wrapUps: [SessionWrapUp]
    ) throws -> CanonicalAcademicWorkspaceContent {
        try requireCount(
            courses.count,
            maximum: AcademicWorkspaceLimits.maximumCourses,
            field: "workspace.courses"
        )
        try requireCount(
            sessions.count,
            maximum: AcademicWorkspaceLimits.maximumSessions,
            field: "workspace.sessions"
        )
        try requireCount(
            sessionNoteLinks.count,
            maximum: AcademicWorkspaceLimits.maximumSessionNoteLinks,
            field: "workspace.sessionNoteLinks"
        )
        try requireCount(
            captures.count,
            maximum: AcademicWorkspaceLimits.maximumCaptures,
            field: "workspace.captures"
        )
        try requireCount(
            wrapUps.count,
            maximum: AcademicWorkspaceLimits.maximumWrapUps,
            field: "workspace.wrapUps"
        )

        try AcademicValidation.requireUnique(courses.map(\.id), entity: "course")
        try AcademicValidation.requireUnique(sessions.map(\.id), entity: "course session")
        try AcademicValidation.requireUnique(captures.map(\.id), entity: "capture item")
        try AcademicValidation.requireUnique(wrapUps.map(\.id), entity: "session wrap-up")

        let canonicalLinks = try SessionNoteLink.validatedCollection(sessionNoteLinks)
        let coursesByID = Dictionary(uniqueKeysWithValues: courses.map { ($0.id, $0) })
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let capturesByID = Dictionary(uniqueKeysWithValues: captures.map { ($0.id, $0) })

        try validateScheduleRules(courses)
        try validateSessions(sessions, coursesByID: coursesByID)
        let noteLinkIndex = try validateLinks(
            canonicalLinks,
            sessionsByID: sessionsByID
        )
        try validateCaptures(
            captures,
            coursesByID: coursesByID,
            sessionsByID: sessionsByID,
            sessionNoteLinks: noteLinkIndex
        )
        try validateWrapUps(
            wrapUps,
            sessions: sessions,
            sessionsByID: sessionsByID,
            captures: captures,
            capturesByID: capturesByID
        )

        return CanonicalAcademicWorkspaceContent(
            courses: courses.sorted { $0.id < $1.id },
            sessions: sessions.sorted { $0.id < $1.id },
            sessionNoteLinks: canonicalLinks,
            captures: captures.sorted { $0.id < $1.id },
            wrapUps: wrapUps.sorted {
                if $0.sessionID != $1.sessionID { return $0.sessionID < $1.sessionID }
                return $0.id < $1.id
            }
        )
    }

    static func validateSavedAt(
        _ savedAt: Date,
        content: AcademicWorkspaceContent
    ) throws {
        for course in content.courses where course.modifiedAt > savedAt {
            throw AcademicDomainError.chronologyViolation(
                "A workspace cannot be saved before a course's latest change."
            )
        }
        for session in content.sessions where session.modifiedAt > savedAt {
            throw AcademicDomainError.chronologyViolation(
                "A workspace cannot be saved before a session's latest change."
            )
        }
        for link in content.sessionNoteLinks
        where (link.unlinkedAt ?? link.linkedAt) > savedAt {
            throw AcademicDomainError.chronologyViolation(
                "A workspace cannot be saved before a note link's latest change."
            )
        }
        for capture in content.captures where capture.modifiedAt > savedAt {
            throw AcademicDomainError.chronologyViolation(
                "A workspace cannot be saved before a capture's latest change."
            )
        }
        for wrapUp in content.wrapUps where wrapUp.completedAt > savedAt {
            throw AcademicDomainError.chronologyViolation(
                "A workspace cannot be saved before a wrap-up completes."
            )
        }
    }

    private static func validateScheduleRules(_ courses: [Course]) throws {
        var total = 0
        var ruleIDs = Set<CourseScheduleRuleID>()
        for course in courses {
            total = try addingBounded(
                course.scheduleRules.count,
                to: total,
                maximum: AcademicWorkspaceLimits.maximumScheduleRules,
                field: "workspace.scheduleRules"
            )
            for rule in course.scheduleRules where !ruleIDs.insert(rule.id).inserted {
                throw AcademicDomainError.duplicateIdentifier(
                    entity: "course schedule rule",
                    identifier: rule.id.description
                )
            }
        }
    }

    private static func validateSessions(
        _ sessions: [CourseSession],
        coursesByID: [CourseID: Course]
    ) throws {
        for session in sessions {
            guard let course = coursesByID[session.courseID] else {
                throw AcademicDomainError.missingEntity(
                    entity: "course",
                    identifier: session.courseID.description
                )
            }
            if let scheduleRuleID = session.scheduleRuleID,
               !course.scheduleRules.contains(where: { $0.id == scheduleRuleID }) {
                throw AcademicDomainError.relationshipMismatch(
                    "A course session's schedule rule must belong to its course."
                )
            }
        }
    }

    private static func validateLinks(
        _ links: [SessionNoteLink],
        sessionsByID: [CourseSessionID: CourseSession]
    ) throws -> SessionNoteLinkIndex {
        var previousBySession = [CourseSessionID: SessionNoteLink]()
        for link in links where sessionsByID[link.sessionID] == nil {
            throw AcademicDomainError.missingEntity(
                entity: "course session",
                identifier: link.sessionID.description
            )
        }
        for link in links {
            if let previous = previousBySession[link.sessionID] {
                guard let unlinkedAt = previous.unlinkedAt,
                      unlinkedAt <= link.linkedAt else {
                    throw AcademicDomainError.relationshipMismatch(
                        "A course session's note-link history cannot overlap."
                    )
                }
            }
            previousBySession[link.sessionID] = link
        }
        let linksByNote = Dictionary(grouping: links, by: \.noteID)
        for noteLinks in linksByNote.values {
            let ordered = noteLinks.sorted {
                if $0.linkedAt != $1.linkedAt { return $0.linkedAt < $1.linkedAt }
                return $0.id < $1.id
            }
            var previous: SessionNoteLink?
            for link in ordered {
                if let previous {
                    guard let unlinkedAt = previous.unlinkedAt,
                          unlinkedAt <= link.linkedAt else {
                        throw AcademicDomainError.relationshipMismatch(
                            "A lecture note can belong to only one course session at a time."
                        )
                    }
                }
                previous = link
            }
        }
        return SessionNoteLinkIndex(links: links)
    }

    private static func validateCaptures(
        _ captures: [CaptureItem],
        coursesByID: [CourseID: Course],
        sessionsByID: [CourseSessionID: CourseSession],
        sessionNoteLinks: SessionNoteLinkIndex
    ) throws {
        var auditTotal = 0
        var auditIDs = Set<CaptureAuditEntryID>()
        var anchorIDs = Set<SourceAnchorID>()
        for capture in captures {
            auditTotal = try addingBounded(
                capture.auditTrail.count,
                to: auditTotal,
                maximum: AcademicWorkspaceLimits.maximumCaptureAuditEntries,
                field: "workspace.captureAuditEntries"
            )
            for audit in capture.auditTrail where !auditIDs.insert(audit.id).inserted {
                throw AcademicDomainError.duplicateIdentifier(
                    entity: "capture audit entry",
                    identifier: audit.id.description
                )
            }
            if case let .noteAnchor(anchor) = capture.source {
                guard anchorIDs.insert(anchor.id).inserted else {
                    throw AcademicDomainError.duplicateIdentifier(
                        entity: "source anchor",
                        identifier: anchor.id.description
                    )
                }
                guard let sessionID = capture.sessionID,
                      sessionNoteLinks.contains(
                          sessionID: sessionID,
                          noteID: anchor.noteID,
                          from: anchor.capturedAt,
                          through: capture.capturedAt
                    ) else {
                    throw AcademicDomainError.relationshipMismatch(
                        "A note-anchored capture requires one session note link spanning anchor and capture times."
                    )
                }
            }
            if let courseID = capture.courseID, coursesByID[courseID] == nil {
                throw AcademicDomainError.missingEntity(
                    entity: "course",
                    identifier: courseID.description
                )
            }
            if let sessionID = capture.sessionID {
                guard let session = sessionsByID[sessionID] else {
                    throw AcademicDomainError.missingEntity(
                        entity: "course session",
                        identifier: sessionID.description
                    )
                }
                guard capture.courseID == session.courseID else {
                    throw AcademicDomainError.relationshipMismatch(
                        "A session capture must reference the session's course."
                    )
                }
            }
        }
    }

    private static func validateWrapUps(
        _ wrapUps: [SessionWrapUp],
        sessions: [CourseSession],
        sessionsByID: [CourseSessionID: CourseSession],
        captures: [CaptureItem],
        capturesByID: [CaptureItemID: CaptureItem]
    ) throws {
        var reviewedReferenceTotal = 0
        var wrapUpBySession = [CourseSessionID: SessionWrapUp]()
        var reviewedIDsBySession = [CourseSessionID: Set<CaptureItemID>]()
        for wrapUp in wrapUps {
            reviewedReferenceTotal = try addingBounded(
                wrapUp.reviewedCaptureIDs.count,
                to: reviewedReferenceTotal,
                maximum: AcademicWorkspaceLimits.maximumReviewedCaptureReferences,
                field: "workspace.reviewedCaptureReferences"
            )
            guard wrapUpBySession.updateValue(wrapUp, forKey: wrapUp.sessionID) == nil else {
                throw AcademicDomainError.relationshipMismatch(
                    "A course session can have only one wrap-up."
                )
            }
            reviewedIDsBySession[wrapUp.sessionID] = Set(wrapUp.reviewedCaptureIDs)
            guard let session = sessionsByID[wrapUp.sessionID] else {
                throw AcademicDomainError.missingEntity(
                    entity: "course session",
                    identifier: wrapUp.sessionID.description
                )
            }
            guard session.status == .reviewed else {
                throw AcademicDomainError.relationshipMismatch(
                    "A session wrap-up requires a reviewed course session."
                )
            }
            guard wrapUp.completedAt == session.modifiedAt,
                  session.actualStartedAt.map({ wrapUp.startedAt >= $0 }) ?? false else {
                throw AcademicDomainError.chronologyViolation(
                    "A session wrap-up must align with the reviewed session timeline."
                )
            }
            for captureID in wrapUp.reviewedCaptureIDs {
                guard let capture = capturesByID[captureID] else {
                    throw AcademicDomainError.missingEntity(
                        entity: "capture item",
                        identifier: captureID.description
                    )
                }
                guard capture.sessionID == wrapUp.sessionID,
                      capture.modifiedAt <= wrapUp.completedAt else {
                    throw AcademicDomainError.relationshipMismatch(
                        "Every reviewed capture must belong to the wrapped session and predate completion."
                    )
                }
                if capture.state == .resolved {
                    guard capture.resolution?.resolvedAt == wrapUp.completedAt else {
                        throw AcademicDomainError.relationshipMismatch(
                            "A resolved reviewed capture must be resolved by its wrap-up."
                        )
                    }
                }
            }
        }

        for session in sessions where session.status == .reviewed {
            guard wrapUpBySession[session.id] != nil else {
                throw AcademicDomainError.relationshipMismatch(
                    "Every reviewed course session must have one wrap-up."
                )
            }
        }
        for capture in captures {
            guard let sessionID = capture.sessionID,
                  let session = sessionsByID[sessionID],
                  session.status == .reviewed,
                  let wrapUp = wrapUpBySession[sessionID] else {
                continue
            }
            guard capture.modifiedAt <= wrapUp.completedAt else {
                throw AcademicDomainError.chronologyViolation(
                    "A reviewed session cannot gain captures after its wrap-up."
                )
            }
            if capture.state != .resolved {
                guard reviewedIDsBySession[sessionID]?.contains(capture.id) == true else {
                    throw AcademicDomainError.relationshipMismatch(
                        "Every unresolved capture in a reviewed session must appear in its wrap-up."
                    )
                }
            } else if capture.resolution?.resolvedAt == wrapUp.completedAt {
                guard reviewedIDsBySession[sessionID]?.contains(capture.id) == true else {
                    throw AcademicDomainError.relationshipMismatch(
                        "A capture resolved by a wrap-up must appear in its reviewed captures."
                    )
                }
            }
        }
    }

    private static func requireCount(
        _ count: Int,
        maximum: Int,
        field: String
    ) throws {
        guard count <= maximum else {
            throw AcademicDomainError.valueOutOfBounds(field: field)
        }
    }

    private static func addingBounded(
        _ amount: Int,
        to current: Int,
        maximum: Int,
        field: String
    ) throws -> Int {
        let (sum, overflow) = current.addingReportingOverflow(amount)
        guard !overflow, sum <= maximum else {
            throw AcademicDomainError.valueOutOfBounds(field: field)
        }
        return sum
    }
}

private struct SessionNoteLinkIndex {
    private struct Key: Hashable {
        let sessionID: CourseSessionID
        let noteID: NotebookID
    }

    private let linksByKey: [Key: [SessionNoteLink]]

    init(links: [SessionNoteLink]) {
        linksByKey = Dictionary(grouping: links) {
            Key(sessionID: $0.sessionID, noteID: $0.noteID)
        }
    }

    func contains(
        sessionID: CourseSessionID,
        noteID: NotebookID,
        from anchorTimestamp: Date,
        through captureTimestamp: Date
    ) -> Bool {
        guard anchorTimestamp <= captureTimestamp,
              let links = linksByKey[Key(sessionID: sessionID, noteID: noteID)] else {
            return false
        }
        var lowerBound = 0
        var upperBound = links.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if links[middle].linkedAt <= anchorTimestamp {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        guard lowerBound > 0 else { return false }
        let candidate = links[lowerBound - 1]
        // Link intervals are half-open: [linkedAt, unlinkedAt). A replacement
        // link beginning at the same instant therefore owns the boundary.
        return candidate.unlinkedAt.map { captureTimestamp < $0 } ?? true
    }
}
