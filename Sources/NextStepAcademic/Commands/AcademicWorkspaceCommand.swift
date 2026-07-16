import Foundation

/// A deterministic, in-memory change to a saved academic workspace.
///
/// Commands carry every identifier and timestamp they need, so applying one
/// never reads the clock, creates an identifier, or performs I/O. A command can
/// therefore be captured directly by `NextStepAcademicStore.mutate`:
///
/// ```swift
/// let command = AcademicWorkspaceCommand.addCourse(course)
/// try await store.mutate(expected: token, savedAt: savedAt) { workspace in
///     try command.applying(to: workspace)
/// }
/// ```
public enum AcademicWorkspaceCommand: Equatable, Sendable {
    case addCourse(Course)
    case replaceCourseSchedule(
        id: CourseID,
        expectedRevision: Int64,
        rules: [CourseScheduleRule],
        at: Date
    )
    case addSession(CourseSession)
    case addSessionNoteLink(SessionNoteLink)
    case addSessionWithNoteLink(session: CourseSession, link: SessionNoteLink)
    case addCapture(CaptureItem)
    case applyCaptureReview(CaptureReviewMutation)
    case transitionSession(
        id: CourseSessionID,
        expectedRevision: Int64,
        to: CourseSessionStatus,
        at: Date
    )
    case applyWrapUp(SessionWrapUpTransaction)

    /// Applies this command without mutating the supplied workspace.
    ///
    /// Entity construction and `AcademicWorkspaceContent` perform the shared
    /// domain validation. The only command-specific revision check is the
    /// optimistic lock needed before a course or session transition. Wrap-up revisions
    /// are checked by `SessionWrapUpTransaction` itself.
    public func applying(
        to workspace: AcademicWorkspace
    ) throws -> AcademicWorkspaceContent {
        var courses = workspace.courses
        var sessions = workspace.sessions
        var sessionNoteLinks = workspace.sessionNoteLinks
        var captures = workspace.captures
        var wrapUps = workspace.wrapUps

        switch self {
        case let .addCourse(course):
            courses.append(course)

        case let .replaceCourseSchedule(id, expectedRevision, rules, timestamp):
            try AcademicValidation.requireRevision(
                expectedRevision,
                field: "academicWorkspaceCommand.expectedCourseRevision"
            )
            guard let index = courses.firstIndex(where: { $0.id == id }) else {
                throw AcademicDomainError.missingEntity(
                    entity: "course",
                    identifier: id.description
                )
            }
            let course = courses[index]
            guard course.revision == expectedRevision else {
                throw AcademicDomainError.revisionConflict(
                    expected: expectedRevision,
                    actual: course.revision
                )
            }
            courses[index] = try course.replacingScheduleRules(
                rules,
                at: timestamp
            )

        case let .addSession(session):
            sessions.append(session)

        case let .addSessionNoteLink(link):
            sessionNoteLinks.append(link)

        case let .addSessionWithNoteLink(session, link):
            guard link.sessionID == session.id else {
                throw AcademicDomainError.relationshipMismatch(
                    "A composite session note link must belong to its new course session."
                )
            }
            sessions.append(session)
            sessionNoteLinks.append(link)

        case let .addCapture(capture):
            captures.append(capture)

        case let .applyCaptureReview(mutation):
            guard let index = captures.firstIndex(
                where: { $0.id == mutation.captureID }
            ) else {
                throw AcademicDomainError.missingEntity(
                    entity: "capture item",
                    identifier: mutation.captureID.description
                )
            }
            let rebuilt = try mutation.applying(to: captures[index])
            guard rebuilt == mutation.resultingCapture else {
                throw AcademicDomainError.relationshipMismatch(
                    "A capture review command did not reproduce its stored post-image."
                )
            }
            captures[index] = rebuilt

        case let .transitionSession(id, expectedRevision, target, timestamp):
            try AcademicValidation.requireRevision(
                expectedRevision,
                field: "academicWorkspaceCommand.expectedSessionRevision"
            )
            guard let index = sessions.firstIndex(where: { $0.id == id }) else {
                throw AcademicDomainError.missingEntity(
                    entity: "course session",
                    identifier: id.description
                )
            }
            let session = sessions[index]
            guard session.revision == expectedRevision else {
                throw AcademicDomainError.revisionConflict(
                    expected: expectedRevision,
                    actual: session.revision
                )
            }
            sessions[index] = try session.transitioned(to: target, at: timestamp)

        case let .applyWrapUp(transaction):
            guard let sessionIndex = sessions.firstIndex(
                where: { $0.id == transaction.sessionID }
            ) else {
                throw AcademicDomainError.missingEntity(
                    entity: "course session",
                    identifier: transaction.sessionID.description
                )
            }
            let sessionCaptures = captures.filter {
                $0.sessionID == transaction.sessionID
            }
            let result = try transaction.applying(
                to: sessions[sessionIndex],
                captures: sessionCaptures
            )

            sessions[sessionIndex] = result.session
            captures.removeAll { $0.sessionID == transaction.sessionID }
            captures.append(contentsOf: result.captures)
            wrapUps.append(result.wrapUp)
        }

        return try AcademicWorkspaceContent(
            courses: courses,
            sessions: sessions,
            sessionNoteLinks: sessionNoteLinks,
            captures: captures,
            wrapUps: wrapUps
        )
    }
}
