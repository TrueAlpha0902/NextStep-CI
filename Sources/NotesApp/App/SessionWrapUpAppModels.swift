import Foundation
import NextStepAcademic

/// Stable, caller-owned request for ending one active class session.
///
/// `endedAt` and `expectedRevision` are deliberately carried by the request so
/// an ambiguous store response can be reconciled and retried without reading
/// the clock or silently targeting a newer session revision.
struct SessionEndRequest: Equatable, Sendable {
    let sessionID: CourseSessionID
    let expectedRevision: Int64
    let endedAt: Date

    init(
        sessionID: CourseSessionID,
        expectedRevision: Int64,
        endedAt: Date
    ) {
        self.sessionID = sessionID
        self.expectedRevision = expectedRevision
        self.endedAt = endedAt
    }
}

/// Effect-based result for one exact `SessionEndRequest`.
enum SessionEndOutcome: Equatable, Sendable {
    case ended
    case alreadyEnded
    case conflict
    case invalid(String)
    case notReady
}

/// Effect-based result for one exact `SessionWrapUpTransaction`.
enum SessionWrapUpSaveOutcome: Equatable, Sendable {
    case completed
    case alreadyCompleted
    case conflict
    case invalid(String)
    case notReady
}
