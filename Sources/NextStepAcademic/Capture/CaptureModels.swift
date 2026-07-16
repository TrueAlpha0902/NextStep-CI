import Foundation

public enum CaptureKind: String, Codable, CaseIterable, Hashable, Sendable {
    case professorEmphasis
    case learningGap
    case assignmentCandidate
    case examCandidate
    case researchIdea
    case currentAffairsLink
    case evidenceCandidate

    public var isAssignmentOrExamCandidate: Bool {
        self == .assignmentCandidate || self == .examCandidate
    }
}

public enum AcademicDateCertainty: String, Codable, CaseIterable, Hashable, Sendable {
    case unknown
    case estimated
    case confirmed
}

public struct CaptureDraftFields: Codable, Equatable, Sendable {
    public let title: String?
    public let details: String?
    public let scope: String?
    public let date: AcademicLocalDate?
    public let dateCertainty: AcademicDateCertainty?

    public init(
        title: String? = nil,
        details: String? = nil,
        scope: String? = nil,
        date: AcademicLocalDate? = nil,
        dateCertainty: AcademicDateCertainty? = nil
    ) throws {
        try AcademicValidation.requireOptionalText(
            title,
            field: "capture.title",
            maximumCharacters: AcademicDomainLimits.maximumShortFieldCharacters,
            maximumUTF8Bytes: AcademicDomainLimits.maximumShortFieldUTF8Bytes,
            allowsNewlines: false
        )
        for (field, value) in [
            ("capture.details", details),
            ("capture.scope", scope),
        ] {
            try AcademicValidation.requireOptionalText(
                value,
                field: field,
                maximumCharacters: AcademicDomainLimits.maximumCaptureTextCharacters,
                maximumUTF8Bytes: AcademicDomainLimits.maximumCaptureTextUTF8Bytes,
                allowsNewlines: true
            )
        }
        switch (date, dateCertainty) {
        case (nil, nil),
             (nil, .some(.unknown)),
             (.some(_), .some(.estimated)),
             (.some(_), .some(.confirmed)):
            break
        default:
            throw AcademicDomainError.relationshipMismatch(
                "Unknown dates must be empty; estimated or confirmed dates require a local date."
            )
        }
        self.title = title
        self.details = details
        self.scope = scope
        self.date = date
        self.dateCertainty = dateCertainty
    }

    private enum CodingKeys: String, CodingKey {
        case title, details, scope, date, dateCertainty
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let title = try values.decodeIfPresent(String.self, forKey: .title)
        let details = try values.decodeIfPresent(String.self, forKey: .details)
        let scope = try values.decodeIfPresent(String.self, forKey: .scope)
        let date = try values.decodeIfPresent(AcademicLocalDate.self, forKey: .date)
        let dateCertainty = try values.decodeIfPresent(
            AcademicDateCertainty.self,
            forKey: .dateCertainty
        )
        do {
            try self.init(
                title: title,
                details: details,
                scope: scope,
                date: date,
                dateCertainty: dateCertainty
            )
        } catch let error as AcademicDomainError {
            throw DecodingError.dataCorruptedError(
                forKey: .title,
                in: values,
                debugDescription: error.localizedDescription
            )
        }
    }
}

public enum CaptureState: String, Codable, CaseIterable, Hashable, Sendable {
    case inbox
    case needsDetails
    case readyToConfirm
    case resolved
}

public enum CaptureResolutionKind: String, Codable, CaseIterable, Hashable, Sendable {
    case created
    case linkedExisting
    case rejected
}

public struct CaptureResolution: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumResolvedEntityReferences = 100

    public let schemaVersion: Int
    public let kind: CaptureResolutionKind
    public let resolvedAt: Date
    public let reason: String?
    public let resolvedEntityRefs: [AcademicEntityRef]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        kind: CaptureResolutionKind,
        resolvedAt: Date,
        reason: String? = nil,
        resolvedEntityRefs: [AcademicEntityRef] = []
    ) throws {
        try AcademicValidation.requireSchema(
            schemaVersion,
            current: Self.currentSchemaVersion,
            entity: "capture resolution"
        )
        try AcademicValidation.requireFinite(resolvedAt, field: "capture.resolvedAt")
        try AcademicValidation.requireOptionalText(
            reason,
            field: "capture.resolutionReason",
            maximumCharacters: AcademicDomainLimits.maximumReasonCharacters,
            maximumUTF8Bytes: AcademicDomainLimits.maximumReasonUTF8Bytes,
            allowsNewlines: true
        )
        guard resolvedEntityRefs.count <= Self.maximumResolvedEntityReferences else {
            throw AcademicDomainError.valueOutOfBounds(field: "capture.resolvedEntityRefs")
        }
        try AcademicValidation.requireUnique(
            resolvedEntityRefs.map { "\($0.entityType.rawValue):\($0.entityID.uuidString)" },
            entity: "resolved entity reference"
        )
        switch kind {
        case .rejected:
            guard reason != nil, resolvedEntityRefs.isEmpty else {
                throw AcademicDomainError.invalidField("capture.rejectedResolution")
            }
        case .created, .linkedExisting:
            guard !resolvedEntityRefs.isEmpty else {
                throw AcademicDomainError.invalidField("capture.resolvedEntityRefs")
            }
        }
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.resolvedAt = resolvedAt
        self.reason = reason
        self.resolvedEntityRefs = resolvedEntityRefs.sorted {
            if $0.entityType.rawValue != $1.entityType.rawValue {
                return $0.entityType.rawValue < $1.entityType.rawValue
            }
            return $0.entityID.uuidString < $1.entityID.uuidString
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, kind, resolvedAt, reason, resolvedEntityRefs
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        do {
            try AcademicValidation.requireSchema(
                schemaVersion,
                current: Self.currentSchemaVersion,
                entity: "capture resolution"
            )
            let references = try AcademicValidation.decodeBoundedArray(
                AcademicEntityRef.self,
                from: values,
                forKey: .resolvedEntityRefs,
                maximumCount: Self.maximumResolvedEntityReferences,
                field: "capture.resolvedEntityRefs"
            )
            try self.init(
                schemaVersion: schemaVersion,
                kind: try values.decode(CaptureResolutionKind.self, forKey: .kind),
                resolvedAt: try values.decode(Date.self, forKey: .resolvedAt),
                reason: try values.decodeIfPresent(String.self, forKey: .reason),
                resolvedEntityRefs: references
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

public enum CaptureAuditAction: String, Codable, CaseIterable, Hashable, Sendable {
    case created
    case draftUpdated
    case stateChanged
    case rejected
}

public struct CaptureAuditEntry: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: CaptureAuditEntryID
    public let occurredAt: Date
    public let action: CaptureAuditAction
    public let fromState: CaptureState?
    public let toState: CaptureState
    public let reason: String?

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: CaptureAuditEntryID = CaptureAuditEntryID(),
        occurredAt: Date,
        action: CaptureAuditAction,
        fromState: CaptureState?,
        toState: CaptureState,
        reason: String? = nil
    ) throws {
        try AcademicValidation.requireSchema(
            schemaVersion,
            current: Self.currentSchemaVersion,
            entity: "capture audit entry"
        )
        try AcademicValidation.requireFinite(occurredAt, field: "captureAudit.occurredAt")
        try AcademicValidation.requireOptionalText(
            reason,
            field: "captureAudit.reason",
            maximumCharacters: AcademicDomainLimits.maximumReasonCharacters,
            maximumUTF8Bytes: AcademicDomainLimits.maximumReasonUTF8Bytes,
            allowsNewlines: true
        )
        switch action {
        case .created:
            guard fromState == nil, toState == .inbox, reason == nil else {
                throw AcademicDomainError.invalidField("captureAudit.created")
            }
        case .draftUpdated:
            guard fromState == toState, fromState != nil, reason == nil else {
                throw AcademicDomainError.invalidField("captureAudit.draftUpdated")
            }
        case .stateChanged:
            guard let fromState,
                  Self.isForwardProgression(from: fromState, to: toState),
                  reason == nil else {
                throw AcademicDomainError.invalidField("captureAudit.stateChanged")
            }
        case .rejected:
            guard let fromState,
                  fromState != .resolved,
                  toState == .resolved,
                  reason != nil else {
                throw AcademicDomainError.invalidField("captureAudit.rejected")
            }
        }
        self.schemaVersion = schemaVersion
        self.id = id
        self.occurredAt = occurredAt
        self.action = action
        self.fromState = fromState
        self.toState = toState
        self.reason = reason
    }

    static func isForwardProgression(from: CaptureState, to: CaptureState) -> Bool {
        switch (from, to) {
        case (.inbox, .needsDetails), (.needsDetails, .readyToConfirm):
            true
        default:
            false
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, occurredAt, action, fromState, toState, reason
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        do {
            try AcademicValidation.requireSchema(
                schemaVersion,
                current: Self.currentSchemaVersion,
                entity: "capture audit entry"
            )
            try self.init(
                schemaVersion: schemaVersion,
                id: try values.decode(CaptureAuditEntryID.self, forKey: .id),
                occurredAt: try values.decode(Date.self, forKey: .occurredAt),
                action: try values.decode(CaptureAuditAction.self, forKey: .action),
                fromState: try values.decodeIfPresent(CaptureState.self, forKey: .fromState),
                toState: try values.decode(CaptureState.self, forKey: .toState),
                reason: try values.decodeIfPresent(String.self, forKey: .reason)
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

public struct CaptureItem: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: CaptureItemID
    public let revision: Int64
    public let kind: CaptureKind
    public let source: CaptureSource
    public let courseID: CourseID?
    public let sessionID: CourseSessionID?
    public let rawText: String?
    public let draftFields: CaptureDraftFields
    public let capturedAt: Date
    public let modifiedAt: Date
    public let state: CaptureState
    public let resolution: CaptureResolution?
    public let auditTrail: [CaptureAuditEntry]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        id: CaptureItemID,
        revision: Int64,
        kind: CaptureKind,
        source: CaptureSource,
        courseID: CourseID?,
        sessionID: CourseSessionID?,
        rawText: String?,
        draftFields: CaptureDraftFields,
        capturedAt: Date,
        modifiedAt: Date,
        state: CaptureState,
        resolution: CaptureResolution?,
        auditTrail: [CaptureAuditEntry]
    ) throws {
        try AcademicValidation.requireSchema(
            schemaVersion,
            current: Self.currentSchemaVersion,
            entity: "capture item"
        )
        try AcademicValidation.requireRevision(revision)
        guard sessionID == nil || courseID != nil else {
            throw AcademicDomainError.relationshipMismatch(
                "A session-scoped capture must also reference a course."
            )
        }
        switch source {
        case let .noteAnchor(anchor):
            guard rawText == nil, courseID != nil, sessionID != nil else {
                throw AcademicDomainError.relationshipMismatch(
                    "A Note-anchored V1 capture requires Course and Session context and cannot duplicate source text."
                )
            }
            guard anchor.capturedAt <= capturedAt else {
                throw AcademicDomainError.chronologyViolation(
                    "A source anchor cannot be captured after its CaptureItem."
                )
            }
        case .quickCapture:
            guard let rawText else {
                throw AcademicDomainError.invalidField("capture.rawText")
            }
            try AcademicValidation.requireText(
                rawText,
                field: "capture.rawText",
                maximumCharacters: AcademicDomainLimits.maximumCaptureTextCharacters,
                maximumUTF8Bytes: AcademicDomainLimits.maximumCaptureTextUTF8Bytes,
                allowsNewlines: true
            )
        }
        if kind.isAssignmentOrExamCandidate {
            guard draftFields.dateCertainty != nil else {
                throw AcademicDomainError.invalidField("capture.dateCertainty")
            }
            if state == .readyToConfirm {
                guard courseID != nil,
                      draftFields.title != nil else {
                    throw AcademicDomainError.relationshipMismatch(
                        "A ready Assignment or Exam Candidate requires a Course and identifiable title."
                    )
                }
            }
        } else {
            guard draftFields.scope == nil,
                  draftFields.date == nil,
                  draftFields.dateCertainty == nil else {
                throw AcademicDomainError.relationshipMismatch(
                    "Only Assignment and Exam Candidates may carry scope or date fields in V1."
                )
            }
        }
        try AcademicValidation.requireChronology(
            earlier: capturedAt,
            later: modifiedAt,
            detail: "A capture cannot be modified before it is created."
        )
        guard auditTrail.count <= AcademicDomainLimits.maximumAuditEntriesPerCapture,
              !auditTrail.isEmpty else {
            throw AcademicDomainError.valueOutOfBounds(field: "capture.auditTrail")
        }
        try AcademicValidation.requireUnique(auditTrail.map(\.id), entity: "capture audit entry")
        try Self.validateAuditTrail(
            auditTrail,
            capturedAt: capturedAt,
            modifiedAt: modifiedAt,
            state: state
        )
        guard revision == Int64(auditTrail.count) else {
            throw AcademicDomainError.relationshipMismatch(
                "A CaptureItem revision must match its append-only audit length."
            )
        }
        if state == .resolved {
            guard let resolution else {
                throw AcademicDomainError.invalidField("capture.resolution")
            }
            guard resolution.kind == .rejected else {
                throw AcademicDomainError.unsupportedV1Operation(
                    "capture.resolution.\(resolution.kind.rawValue)"
                )
            }
            guard resolution.resolvedAt == auditTrail.last?.occurredAt,
                  resolution.reason == auditTrail.last?.reason else {
                throw AcademicDomainError.relationshipMismatch(
                    "A rejected Capture resolution must match its final audit entry."
                )
            }
        } else {
            guard resolution == nil else {
                throw AcademicDomainError.invalidField("capture.resolution")
            }
        }
        self.schemaVersion = schemaVersion
        self.id = id
        self.revision = revision
        self.kind = kind
        self.source = source
        self.courseID = courseID
        self.sessionID = sessionID
        self.rawText = rawText
        self.draftFields = draftFields
        self.capturedAt = capturedAt
        self.modifiedAt = modifiedAt
        self.state = state
        self.resolution = resolution
        self.auditTrail = auditTrail
    }

    public static func create(
        id: CaptureItemID = CaptureItemID(),
        kind: CaptureKind,
        source: CaptureSource,
        courseID: CourseID? = nil,
        sessionID: CourseSessionID? = nil,
        rawText: String? = nil,
        draftFields: CaptureDraftFields,
        capturedAt: Date = Date(),
        auditID: CaptureAuditEntryID = CaptureAuditEntryID()
    ) throws -> CaptureItem {
        let normalizedDraftFields: CaptureDraftFields
        if kind.isAssignmentOrExamCandidate, draftFields.dateCertainty == nil {
            normalizedDraftFields = try CaptureDraftFields(
                title: draftFields.title,
                details: draftFields.details,
                scope: draftFields.scope,
                date: draftFields.date,
                dateCertainty: .unknown
            )
        } else {
            normalizedDraftFields = draftFields
        }
        let audit = try CaptureAuditEntry(
            id: auditID,
            occurredAt: capturedAt,
            action: .created,
            fromState: nil,
            toState: .inbox
        )
        return try CaptureItem(
            id: id,
            revision: 1,
            kind: kind,
            source: source,
            courseID: courseID,
            sessionID: sessionID,
            rawText: rawText,
            draftFields: normalizedDraftFields,
            capturedAt: capturedAt,
            modifiedAt: capturedAt,
            state: .inbox,
            resolution: nil,
            auditTrail: [audit]
        )
    }

    public func updatingDraft(
        _ fields: CaptureDraftFields,
        at timestamp: Date,
        auditID: CaptureAuditEntryID = CaptureAuditEntryID()
    ) throws -> CaptureItem {
        guard state != .resolved else {
            throw AcademicDomainError.invalidStateTransition(
                entity: "capture item",
                from: state.rawValue,
                to: state.rawValue
            )
        }
        let audit = try CaptureAuditEntry(
            id: auditID,
            occurredAt: timestamp,
            action: .draftUpdated,
            fromState: state,
            toState: state
        )
        return try replacing(
            draftFields: fields,
            modifiedAt: timestamp,
            state: state,
            resolution: resolution,
            appending: audit
        )
    }

    public func transitioned(
        to target: CaptureState,
        draftFields: CaptureDraftFields? = nil,
        at timestamp: Date,
        auditID: CaptureAuditEntryID = CaptureAuditEntryID()
    ) throws -> CaptureItem {
        guard target != .resolved,
              CaptureAuditEntry.isForwardProgression(from: state, to: target) else {
            throw AcademicDomainError.invalidStateTransition(
                entity: "capture item",
                from: state.rawValue,
                to: target.rawValue
            )
        }
        let audit = try CaptureAuditEntry(
            id: auditID,
            occurredAt: timestamp,
            action: .stateChanged,
            fromState: state,
            toState: target
        )
        return try replacing(
            draftFields: draftFields ?? self.draftFields,
            modifiedAt: timestamp,
            state: target,
            resolution: nil,
            appending: audit
        )
    }

    public func rejecting(
        reason: String,
        at timestamp: Date,
        auditID: CaptureAuditEntryID = CaptureAuditEntryID()
    ) throws -> CaptureItem {
        guard state != .resolved else {
            throw AcademicDomainError.invalidStateTransition(
                entity: "capture item",
                from: state.rawValue,
                to: CaptureState.resolved.rawValue
            )
        }
        let resolution = try CaptureResolution(
            kind: .rejected,
            resolvedAt: timestamp,
            reason: reason
        )
        let audit = try CaptureAuditEntry(
            id: auditID,
            occurredAt: timestamp,
            action: .rejected,
            fromState: state,
            toState: .resolved,
            reason: reason
        )
        return try replacing(
            draftFields: draftFields,
            modifiedAt: timestamp,
            state: .resolved,
            resolution: resolution,
            appending: audit
        )
    }

    private func replacing(
        draftFields: CaptureDraftFields,
        modifiedAt: Date,
        state: CaptureState,
        resolution: CaptureResolution?,
        appending audit: CaptureAuditEntry
    ) throws -> CaptureItem {
        guard modifiedAt >= self.modifiedAt else {
            throw AcademicDomainError.chronologyViolation(
                "A CaptureItem update cannot move time backwards."
            )
        }
        return try CaptureItem(
            id: id,
            revision: AcademicValidation.nextRevision(after: revision),
            kind: kind,
            source: source,
            courseID: courseID,
            sessionID: sessionID,
            rawText: rawText,
            draftFields: draftFields,
            capturedAt: capturedAt,
            modifiedAt: modifiedAt,
            state: state,
            resolution: resolution,
            auditTrail: auditTrail + [audit]
        )
    }

    private static func validateAuditTrail(
        _ auditTrail: [CaptureAuditEntry],
        capturedAt: Date,
        modifiedAt: Date,
        state: CaptureState
    ) throws {
        guard let first = auditTrail.first,
              first.action == .created,
              first.occurredAt == capturedAt else {
            throw AcademicDomainError.relationshipMismatch(
                "A CaptureItem audit must begin with its creation event."
            )
        }
        var previous = first
        for entry in auditTrail.dropFirst() {
            guard previous.occurredAt <= entry.occurredAt,
                  entry.fromState == previous.toState else {
                throw AcademicDomainError.relationshipMismatch(
                    "Capture audit entries must form one chronological state chain."
                )
            }
            previous = entry
        }
        guard previous.toState == state,
              previous.occurredAt == modifiedAt else {
            throw AcademicDomainError.relationshipMismatch(
                "Capture state and modification time must match the audit tail."
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, revision, kind, source, courseID, sessionID, rawText
        case draftFields, capturedAt, modifiedAt, state, resolution, auditTrail
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        do {
            try AcademicValidation.requireSchema(
                schemaVersion,
                current: Self.currentSchemaVersion,
                entity: "capture item"
            )
            let auditTrail = try AcademicValidation.decodeBoundedArray(
                CaptureAuditEntry.self,
                from: values,
                forKey: .auditTrail,
                maximumCount: AcademicDomainLimits.maximumAuditEntriesPerCapture,
                field: "capture.auditTrail"
            )
            try self.init(
                schemaVersion: schemaVersion,
                id: try values.decode(CaptureItemID.self, forKey: .id),
                revision: try values.decode(Int64.self, forKey: .revision),
                kind: try values.decode(CaptureKind.self, forKey: .kind),
                source: try values.decode(CaptureSource.self, forKey: .source),
                courseID: try values.decodeIfPresent(CourseID.self, forKey: .courseID),
                sessionID: try values.decodeIfPresent(
                    CourseSessionID.self,
                    forKey: .sessionID
                ),
                rawText: try values.decodeIfPresent(String.self, forKey: .rawText),
                draftFields: try values.decode(
                    CaptureDraftFields.self,
                    forKey: .draftFields
                ),
                capturedAt: try values.decode(Date.self, forKey: .capturedAt),
                modifiedAt: try values.decode(Date.self, forKey: .modifiedAt),
                state: try values.decode(CaptureState.self, forKey: .state),
                resolution: try values.decodeIfPresent(
                    CaptureResolution.self,
                    forKey: .resolution
                ),
                auditTrail: auditTrail
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
