import Foundation

/// One user-authored V1 review decision for an Assignment or Exam Candidate.
///
/// Every timestamp and audit identifier is supplied by the caller and retained
/// by the value. Reapplying the same intent therefore computes the same exact
/// post-image instead of reading the clock or minting a second audit event.
public enum CaptureReviewIntent: Equatable, Sendable {
    case saveDraft(
        fields: CaptureDraftFields,
        occurredAt: Date,
        auditID: CaptureAuditEntryID
    )
    case markNeedsDetails(
        fields: CaptureDraftFields?,
        occurredAt: Date,
        auditID: CaptureAuditEntryID
    )
    case markReadyToConfirm(
        fields: CaptureDraftFields?,
        occurredAt: Date,
        auditIDs: [CaptureAuditEntryID]
    )
    case reject(
        reason: String,
        occurredAt: Date,
        auditID: CaptureAuditEntryID
    )

    public var occurredAt: Date {
        switch self {
        case let .saveDraft(_, occurredAt, _),
             let .markNeedsDetails(_, occurredAt, _),
             let .markReadyToConfirm(_, occurredAt, _),
             let .reject(_, occurredAt, _):
            occurredAt
        }
    }

    public var auditIDs: [CaptureAuditEntryID] {
        switch self {
        case let .saveDraft(_, _, auditID),
             let .markNeedsDetails(_, _, auditID),
             let .reject(_, _, auditID):
            [auditID]
        case let .markReadyToConfirm(_, _, auditIDs):
            auditIDs
        }
    }
}

/// A deterministic candidate-review mutation with exact pre- and post-images.
///
/// The public initializer accepts a valid base entity and an intent. It does
/// not accept an arbitrary replacement `CaptureItem`. This makes ambiguous
/// store retries safe even if a fresh reload contains a different, otherwise
/// valid value with the same identifier and revision.
public struct CaptureReviewMutation: Equatable, Sendable {
    public let expectedCapture: CaptureItem
    public let intent: CaptureReviewIntent
    public let resultingCapture: CaptureItem

    public var captureID: CaptureItemID { expectedCapture.id }
    public var expectedRevision: Int64 { expectedCapture.revision }

    public init(
        base: CaptureItem,
        intent: CaptureReviewIntent
    ) throws {
        try Self.validate(intent)
        let resultingCapture = try Self.makeResult(
            from: base,
            intent: intent
        )

        expectedCapture = base
        self.intent = intent
        self.resultingCapture = resultingCapture
    }

    /// Rebuilds the post-image only when `capture` is the exact expected value.
    public func applying(to capture: CaptureItem) throws -> CaptureItem {
        guard capture.id == expectedCapture.id else {
            throw AcademicDomainError.relationshipMismatch(
                "A capture review mutation must be applied to its exact CaptureItem."
            )
        }
        guard capture.revision == expectedCapture.revision else {
            throw AcademicDomainError.revisionConflict(
                expected: expectedCapture.revision,
                actual: capture.revision
            )
        }
        guard capture == expectedCapture else {
            throw AcademicDomainError.relationshipMismatch(
                "A capture review mutation requires its exact expected CaptureItem pre-image."
            )
        }

        let rebuilt = try Self.makeResult(from: capture, intent: intent)
        guard rebuilt == resultingCapture else {
            throw AcademicDomainError.relationshipMismatch(
                "A capture review mutation did not reproduce its stored post-image."
            )
        }
        return rebuilt
    }

    private static func validate(_ intent: CaptureReviewIntent) throws {
        try AcademicValidation.requireFinite(
            intent.occurredAt,
            field: "captureReviewMutation.occurredAt"
        )
        try AcademicValidation.requireUnique(
            intent.auditIDs,
            entity: "capture audit entry"
        )

        switch intent {
        case .saveDraft, .markNeedsDetails:
            guard intent.auditIDs.count == 1 else {
                throw AcademicDomainError.invalidField(
                    "captureReviewMutation.auditIDs"
                )
            }

        case let .markReadyToConfirm(_, _, auditIDs):
            guard (1 ... 2).contains(auditIDs.count) else {
                throw AcademicDomainError.invalidField(
                    "captureReviewMutation.markReadyToConfirm.auditIDs"
                )
            }

        case let .reject(reason, _, _):
            try AcademicValidation.requireText(
                reason,
                field: "captureReviewMutation.rejectionReason",
                maximumCharacters: AcademicDomainLimits.maximumReasonCharacters,
                maximumUTF8Bytes: AcademicDomainLimits.maximumReasonUTF8Bytes,
                allowsNewlines: true
            )
        }
    }

    private static func makeResult(
        from capture: CaptureItem,
        intent: CaptureReviewIntent
    ) throws -> CaptureItem {
        guard capture.kind.isAssignmentOrExamCandidate else {
            throw AcademicDomainError.unsupportedV1Operation(
                "captureReview.nonCandidate"
            )
        }
        guard capture.state != .resolved else {
            throw AcademicDomainError.invalidStateTransition(
                entity: "capture item",
                from: capture.state.rawValue,
                to: targetState(for: intent).rawValue
            )
        }

        switch intent {
        case let .saveDraft(fields, occurredAt, auditID):
            return try capture.updatingDraft(
                fields,
                at: occurredAt,
                auditID: auditID
            )

        case let .markNeedsDetails(fields, occurredAt, auditID):
            guard capture.state == .inbox else {
                throw AcademicDomainError.invalidStateTransition(
                    entity: "capture item",
                    from: capture.state.rawValue,
                    to: CaptureState.needsDetails.rawValue
                )
            }
            return try capture.transitioned(
                to: .needsDetails,
                draftFields: fields,
                at: occurredAt,
                auditID: auditID
            )

        case let .markReadyToConfirm(fields, occurredAt, auditIDs):
            switch capture.state {
            case .inbox:
                guard auditIDs.count == 2 else {
                    throw AcademicDomainError.invalidField(
                        "captureReviewMutation.markReadyToConfirm.auditIDs"
                    )
                }
                let needsDetails = try capture.transitioned(
                    to: .needsDetails,
                    draftFields: fields,
                    at: occurredAt,
                    auditID: auditIDs[0]
                )
                return try needsDetails.transitioned(
                    to: .readyToConfirm,
                    at: occurredAt,
                    auditID: auditIDs[1]
                )

            case .needsDetails:
                guard auditIDs.count == 1 else {
                    throw AcademicDomainError.invalidField(
                        "captureReviewMutation.markReadyToConfirm.auditIDs"
                    )
                }
                return try capture.transitioned(
                    to: .readyToConfirm,
                    draftFields: fields,
                    at: occurredAt,
                    auditID: auditIDs[0]
                )

            case .readyToConfirm, .resolved:
                throw AcademicDomainError.invalidStateTransition(
                    entity: "capture item",
                    from: capture.state.rawValue,
                    to: CaptureState.readyToConfirm.rawValue
                )
            }

        case let .reject(reason, occurredAt, auditID):
            return try capture.rejecting(
                reason: reason,
                at: occurredAt,
                auditID: auditID
            )
        }
    }

    private static func targetState(
        for intent: CaptureReviewIntent
    ) -> CaptureState {
        switch intent {
        case .saveDraft:
            .resolved
        case .markNeedsDetails:
            .needsDetails
        case .markReadyToConfirm:
            .readyToConfirm
        case .reject:
            .resolved
        }
    }
}
