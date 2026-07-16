import Foundation

public struct SessionWrapUp: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: SessionWrapUpID
    public let sessionID: CourseSessionID
    public let revision: Int64
    public let startedAt: Date
    public let completedAt: Date
    public let oneLineSummary: String
    public let noNewActionsConfirmed: Bool
    public let reviewedCaptureIDs: [CaptureItemID]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: SessionWrapUpID = SessionWrapUpID(),
        sessionID: CourseSessionID,
        revision: Int64 = 1,
        startedAt: Date,
        completedAt: Date,
        oneLineSummary: String,
        noNewActionsConfirmed: Bool,
        reviewedCaptureIDs: [CaptureItemID]
    ) throws {
        try AcademicValidation.requireSchema(
            schemaVersion,
            current: Self.currentSchemaVersion,
            entity: "session wrap-up"
        )
        try AcademicValidation.requireRevision(revision)
        try AcademicValidation.requireChronology(
            earlier: startedAt,
            later: completedAt,
            detail: "A session wrap-up cannot finish before it starts."
        )
        try AcademicValidation.requireText(
            oneLineSummary,
            field: "sessionWrapUp.oneLineSummary",
            maximumCharacters: AcademicDomainLimits.maximumSummaryCharacters,
            maximumUTF8Bytes: AcademicDomainLimits.maximumSummaryUTF8Bytes,
            allowsNewlines: false
        )
        guard reviewedCaptureIDs.count <= AcademicDomainLimits.maximumWrapUpDecisions else {
            throw AcademicDomainError.valueOutOfBounds(
                field: "sessionWrapUp.reviewedCaptureIDs"
            )
        }
        try AcademicValidation.requireUnique(
            reviewedCaptureIDs,
            entity: "reviewed capture"
        )
        guard noNewActionsConfirmed || !reviewedCaptureIDs.isEmpty else {
            throw AcademicDomainError.invalidField("sessionWrapUp.outcome")
        }
        self.schemaVersion = schemaVersion
        self.id = id
        self.sessionID = sessionID
        self.revision = revision
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.oneLineSummary = oneLineSummary
        self.noNewActionsConfirmed = noNewActionsConfirmed
        self.reviewedCaptureIDs = reviewedCaptureIDs.sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, sessionID, revision, startedAt, completedAt
        case oneLineSummary, noNewActionsConfirmed, reviewedCaptureIDs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        do {
            try AcademicValidation.requireSchema(
                schemaVersion,
                current: Self.currentSchemaVersion,
                entity: "session wrap-up"
            )
            let reviewedCaptureIDs = try AcademicValidation.decodeBoundedArray(
                CaptureItemID.self,
                from: values,
                forKey: .reviewedCaptureIDs,
                maximumCount: AcademicDomainLimits.maximumWrapUpDecisions,
                field: "sessionWrapUp.reviewedCaptureIDs"
            )
            try self.init(
                schemaVersion: schemaVersion,
                id: try values.decode(SessionWrapUpID.self, forKey: .id),
                sessionID: try values.decode(CourseSessionID.self, forKey: .sessionID),
                revision: try values.decode(Int64.self, forKey: .revision),
                startedAt: try values.decode(Date.self, forKey: .startedAt),
                completedAt: try values.decode(Date.self, forKey: .completedAt),
                oneLineSummary: try values.decode(String.self, forKey: .oneLineSummary),
                noNewActionsConfirmed: try values.decode(
                    Bool.self,
                    forKey: .noNewActionsConfirmed
                ),
                reviewedCaptureIDs: reviewedCaptureIDs
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

public enum SessionWrapUpDecisionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case keepAsIs
    case markNeedsDetails
    case markReadyToConfirm
    case reject
}

public struct SessionWrapUpDecision: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let captureID: CaptureItemID
    public let expectedRevision: Int64
    public let kind: SessionWrapUpDecisionKind
    public let draftFields: CaptureDraftFields?
    public let rejectionReason: String?
    public let auditIDs: [CaptureAuditEntryID]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        captureID: CaptureItemID,
        expectedRevision: Int64,
        kind: SessionWrapUpDecisionKind,
        draftFields: CaptureDraftFields? = nil,
        rejectionReason: String? = nil,
        auditIDs: [CaptureAuditEntryID] = []
    ) throws {
        try AcademicValidation.requireSchema(
            schemaVersion,
            current: Self.currentSchemaVersion,
            entity: "session wrap-up decision"
        )
        try AcademicValidation.requireRevision(
            expectedRevision,
            field: "sessionWrapUpDecision.expectedRevision"
        )
        try AcademicValidation.requireOptionalText(
            rejectionReason,
            field: "sessionWrapUpDecision.rejectionReason",
            maximumCharacters: AcademicDomainLimits.maximumReasonCharacters,
            maximumUTF8Bytes: AcademicDomainLimits.maximumReasonUTF8Bytes,
            allowsNewlines: true
        )
        try AcademicValidation.requireUnique(auditIDs, entity: "capture audit entry")
        switch kind {
        case .keepAsIs:
            guard draftFields == nil, rejectionReason == nil, auditIDs.isEmpty else {
                throw AcademicDomainError.invalidField("sessionWrapUpDecision.keepAsIs")
            }
        case .markNeedsDetails:
            guard rejectionReason == nil, auditIDs.count == 1 else {
                throw AcademicDomainError.invalidField(
                    "sessionWrapUpDecision.markNeedsDetails"
                )
            }
        case .markReadyToConfirm:
            guard rejectionReason == nil, (1 ... 2).contains(auditIDs.count) else {
                throw AcademicDomainError.invalidField(
                    "sessionWrapUpDecision.markReadyToConfirm"
                )
            }
        case .reject:
            guard draftFields == nil, rejectionReason != nil, auditIDs.count == 1 else {
                throw AcademicDomainError.invalidField("sessionWrapUpDecision.reject")
            }
        }
        self.schemaVersion = schemaVersion
        self.captureID = captureID
        self.expectedRevision = expectedRevision
        self.kind = kind
        self.draftFields = draftFields
        self.rejectionReason = rejectionReason
        self.auditIDs = auditIDs
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, captureID, expectedRevision, kind, draftFields
        case rejectionReason, auditIDs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        do {
            try AcademicValidation.requireSchema(
                schemaVersion,
                current: Self.currentSchemaVersion,
                entity: "session wrap-up decision"
            )
            let auditIDs = try AcademicValidation.decodeBoundedArray(
                CaptureAuditEntryID.self,
                from: values,
                forKey: .auditIDs,
                maximumCount: 2,
                field: "sessionWrapUpDecision.auditIDs"
            )
            try self.init(
                schemaVersion: schemaVersion,
                captureID: try values.decode(CaptureItemID.self, forKey: .captureID),
                expectedRevision: try values.decode(Int64.self, forKey: .expectedRevision),
                kind: try values.decode(SessionWrapUpDecisionKind.self, forKey: .kind),
                draftFields: try values.decodeIfPresent(
                    CaptureDraftFields.self,
                    forKey: .draftFields
                ),
                rejectionReason: try values.decodeIfPresent(
                    String.self,
                    forKey: .rejectionReason
                ),
                auditIDs: auditIDs
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

public struct SessionWrapUpTransaction: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sessionID: CourseSessionID
    public let expectedSessionRevision: Int64
    public let wrapUpID: SessionWrapUpID
    public let startedAt: Date
    public let completedAt: Date
    public let oneLineSummary: String
    public let noNewActionsConfirmed: Bool
    public let decisions: [SessionWrapUpDecision]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        sessionID: CourseSessionID,
        expectedSessionRevision: Int64,
        wrapUpID: SessionWrapUpID,
        startedAt: Date,
        completedAt: Date,
        oneLineSummary: String,
        noNewActionsConfirmed: Bool,
        decisions: [SessionWrapUpDecision]
    ) throws {
        try AcademicValidation.requireSchema(
            schemaVersion,
            current: Self.currentSchemaVersion,
            entity: "session wrap-up transaction"
        )
        try AcademicValidation.requireRevision(
            expectedSessionRevision,
            field: "sessionWrapUpTransaction.expectedSessionRevision"
        )
        try AcademicValidation.requireChronology(
            earlier: startedAt,
            later: completedAt,
            detail: "A session wrap-up transaction cannot finish before it starts."
        )
        try AcademicValidation.requireText(
            oneLineSummary,
            field: "sessionWrapUpTransaction.oneLineSummary",
            maximumCharacters: AcademicDomainLimits.maximumSummaryCharacters,
            maximumUTF8Bytes: AcademicDomainLimits.maximumSummaryUTF8Bytes,
            allowsNewlines: false
        )
        guard decisions.count <= AcademicDomainLimits.maximumWrapUpDecisions else {
            throw AcademicDomainError.valueOutOfBounds(
                field: "sessionWrapUpTransaction.decisions"
            )
        }
        try AcademicValidation.requireUnique(
            decisions.map(\.captureID),
            entity: "session wrap-up decision"
        )
        try AcademicValidation.requireUnique(
            decisions.flatMap(\.auditIDs),
            entity: "capture audit entry"
        )
        guard noNewActionsConfirmed || !decisions.isEmpty else {
            throw AcademicDomainError.invalidField("sessionWrapUpTransaction.outcome")
        }
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.expectedSessionRevision = expectedSessionRevision
        self.wrapUpID = wrapUpID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.oneLineSummary = oneLineSummary
        self.noNewActionsConfirmed = noNewActionsConfirmed
        self.decisions = decisions.sorted { $0.captureID < $1.captureID }
    }

    public func applying(
        to session: CourseSession,
        captures: [CaptureItem]
    ) throws -> SessionWrapUpTransactionResult {
        guard captures.count <= AcademicDomainLimits.maximumCapturesPerSession else {
            throw AcademicDomainError.valueOutOfBounds(
                field: "sessionWrapUpTransaction.captures"
            )
        }
        guard session.id == sessionID else {
            throw AcademicDomainError.relationshipMismatch(
                "The wrap-up transaction belongs to a different course session."
            )
        }
        guard session.revision == expectedSessionRevision else {
            throw AcademicDomainError.revisionConflict(
                expected: expectedSessionRevision,
                actual: session.revision
            )
        }
        guard session.status == .active || session.status == .needsReview else {
            throw AcademicDomainError.invalidStateTransition(
                entity: "course session",
                from: session.status.rawValue,
                to: CourseSessionStatus.reviewed.rawValue
            )
        }
        guard startedAt >= session.modifiedAt else {
            throw AcademicDomainError.chronologyViolation(
                "A session wrap-up cannot start before the session's latest change."
            )
        }
        try AcademicValidation.requireUnique(captures.map(\.id), entity: "capture item")
        for capture in captures {
            guard capture.sessionID == session.id,
                  capture.courseID == session.courseID else {
                throw AcademicDomainError.relationshipMismatch(
                    "Every transaction CaptureItem must belong to the wrapped session and course."
                )
            }
        }
        let unresolvedCaptureIDs = Set(
            captures.lazy.filter { $0.state != .resolved }.map(\.id)
        )
        let decidedCaptureIDs = Set(decisions.map(\.captureID))
        guard unresolvedCaptureIDs == decidedCaptureIDs else {
            throw AcademicDomainError.relationshipMismatch(
                "Every unresolved Session CaptureItem must have exactly one wrap-up decision."
            )
        }

        let existingAuditIDs = Set(captures.flatMap { $0.auditTrail.map(\.id) })
        for auditID in decisions.flatMap(\.auditIDs) where existingAuditIDs.contains(auditID) {
            throw AcademicDomainError.duplicateIdentifier(
                entity: "capture audit entry",
                identifier: auditID.description
            )
        }

        var capturesByID = Dictionary(uniqueKeysWithValues: captures.map { ($0.id, $0) })
        for decision in decisions {
            guard let capture = capturesByID[decision.captureID] else {
                throw AcademicDomainError.missingEntity(
                    entity: "capture item",
                    identifier: decision.captureID.description
                )
            }
            guard capture.revision == decision.expectedRevision else {
                throw AcademicDomainError.revisionConflict(
                    expected: decision.expectedRevision,
                    actual: capture.revision
                )
            }
            guard capture.modifiedAt <= completedAt else {
                throw AcademicDomainError.chronologyViolation(
                    "A reviewed CaptureItem cannot be newer than the wrap-up completion."
                )
            }
            capturesByID[decision.captureID] = try apply(decision, to: capture)
        }

        let updatedSession = try session.completingWrapUp(at: completedAt)
        let wrapUp = try SessionWrapUp(
            id: wrapUpID,
            sessionID: sessionID,
            startedAt: startedAt,
            completedAt: completedAt,
            oneLineSummary: oneLineSummary,
            noNewActionsConfirmed: noNewActionsConfirmed,
            reviewedCaptureIDs: decisions.map(\.captureID)
        )
        return SessionWrapUpTransactionResult(
            session: updatedSession,
            captures: capturesByID.values.sorted { $0.id < $1.id },
            wrapUp: wrapUp
        )
    }

    private func apply(
        _ decision: SessionWrapUpDecision,
        to capture: CaptureItem
    ) throws -> CaptureItem {
        switch decision.kind {
        case .keepAsIs:
            guard capture.state != .resolved else {
                throw AcademicDomainError.invalidStateTransition(
                    entity: "capture item",
                    from: capture.state.rawValue,
                    to: capture.state.rawValue
                )
            }
            return capture

        case .markNeedsDetails:
            guard let auditID = decision.auditIDs.first else {
                throw AcademicDomainError.invalidField(
                    "sessionWrapUpDecision.markNeedsDetails"
                )
            }
            switch capture.state {
            case .inbox:
                return try capture.transitioned(
                    to: .needsDetails,
                    draftFields: decision.draftFields,
                    at: completedAt,
                    auditID: auditID
                )
            case .needsDetails:
                guard let draftFields = decision.draftFields else {
                    throw AcademicDomainError.invalidField(
                        "sessionWrapUpDecision.draftFields"
                    )
                }
                return try capture.updatingDraft(
                    draftFields,
                    at: completedAt,
                    auditID: auditID
                )
            case .readyToConfirm, .resolved:
                throw AcademicDomainError.invalidStateTransition(
                    entity: "capture item",
                    from: capture.state.rawValue,
                    to: CaptureState.needsDetails.rawValue
                )
            }

        case .markReadyToConfirm:
            switch capture.state {
            case .inbox:
                guard decision.auditIDs.count == 2 else {
                    throw AcademicDomainError.invalidField(
                        "sessionWrapUpDecision.auditIDs"
                    )
                }
                let needsDetails = try capture.transitioned(
                    to: .needsDetails,
                    draftFields: decision.draftFields,
                    at: completedAt,
                    auditID: decision.auditIDs[0]
                )
                return try needsDetails.transitioned(
                    to: .readyToConfirm,
                    at: completedAt,
                    auditID: decision.auditIDs[1]
                )
            case .needsDetails:
                guard decision.auditIDs.count == 1 else {
                    throw AcademicDomainError.invalidField(
                        "sessionWrapUpDecision.auditIDs"
                    )
                }
                return try capture.transitioned(
                    to: .readyToConfirm,
                    draftFields: decision.draftFields,
                    at: completedAt,
                    auditID: decision.auditIDs[0]
                )
            case .readyToConfirm, .resolved:
                throw AcademicDomainError.invalidStateTransition(
                    entity: "capture item",
                    from: capture.state.rawValue,
                    to: CaptureState.readyToConfirm.rawValue
                )
            }

        case .reject:
            guard let rejectionReason = decision.rejectionReason,
                  let auditID = decision.auditIDs.first else {
                throw AcademicDomainError.invalidField("sessionWrapUpDecision.reject")
            }
            return try capture.rejecting(
                reason: rejectionReason,
                at: completedAt,
                auditID: auditID
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sessionID, expectedSessionRevision, wrapUpID
        case startedAt, completedAt, oneLineSummary, noNewActionsConfirmed, decisions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        do {
            try AcademicValidation.requireSchema(
                schemaVersion,
                current: Self.currentSchemaVersion,
                entity: "session wrap-up transaction"
            )
            let decisions = try AcademicValidation.decodeBoundedArray(
                SessionWrapUpDecision.self,
                from: values,
                forKey: .decisions,
                maximumCount: AcademicDomainLimits.maximumWrapUpDecisions,
                field: "sessionWrapUpTransaction.decisions"
            )
            try self.init(
                schemaVersion: schemaVersion,
                sessionID: try values.decode(CourseSessionID.self, forKey: .sessionID),
                expectedSessionRevision: try values.decode(
                    Int64.self,
                    forKey: .expectedSessionRevision
                ),
                wrapUpID: try values.decode(SessionWrapUpID.self, forKey: .wrapUpID),
                startedAt: try values.decode(Date.self, forKey: .startedAt),
                completedAt: try values.decode(Date.self, forKey: .completedAt),
                oneLineSummary: try values.decode(String.self, forKey: .oneLineSummary),
                noNewActionsConfirmed: try values.decode(
                    Bool.self,
                    forKey: .noNewActionsConfirmed
                ),
                decisions: decisions
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

public struct SessionWrapUpTransactionResult: Equatable, Sendable {
    public let session: CourseSession
    public let captures: [CaptureItem]
    public let wrapUp: SessionWrapUp

    public init(
        session: CourseSession,
        captures: [CaptureItem],
        wrapUp: SessionWrapUp
    ) {
        self.session = session
        self.captures = captures
        self.wrapUp = wrapUp
    }
}
