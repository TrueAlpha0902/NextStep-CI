import Foundation
import NextStepAcademic

enum SessionWrapUpDraftError: Error, Equatable, Sendable {
    case unsupportedSessionStatus(CourseSessionStatus)
    case invalidStartedAt
    case tooManyCaptures
    case duplicateCapture(CaptureItemID)
    case captureRelationshipMismatch(CaptureItemID)
    case duplicateAuditID(CaptureAuditEntryID)
    case captureNotFound(CaptureItemID)
    case captureAlreadyResolved(CaptureItemID)
    case decisionNotAllowed(
        captureID: CaptureItemID,
        state: CaptureState,
        decision: SessionWrapUpDecisionKind
    )
    case summaryRequired
    case summaryTooLong
    case summaryMustBeOneLine
    case candidateTitleRequired(CaptureItemID)
    case candidateDateCertaintyRequired(CaptureItemID)
    case rejectionReasonRequired(CaptureItemID)
    case rejectionReasonTooLong(CaptureItemID)
    case invalidCaptureFields(CaptureItemID)
    case frozen
}

extension SessionWrapUpDraftError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .summaryRequired:
            String(localized: "Add a one-line class summary before finishing review.")
        case .summaryTooLong:
            String(localized: "Shorten the one-line class summary before finishing review.")
        case .summaryMustBeOneLine:
            String(localized: "Keep the class summary on one line before finishing review.")
        case .candidateTitleRequired:
            String(localized: "Add a candidate name before marking it ready for later confirmation.")
        case .candidateDateCertaintyRequired:
            String(localized: "Choose whether the candidate date is unknown, estimated, or confirmed.")
        case .rejectionReasonRequired:
            String(localized: "Add a reason before rejecting this marker.")
        case .rejectionReasonTooLong:
            String(localized: "Shorten the rejection reason before finishing review.")
        case .invalidCaptureFields:
            String(localized: "Check the selected marker's fields before finishing review.")
        case .decisionNotAllowed:
            String(localized: "That decision is not available for the marker's current state.")
        case .frozen:
            String(localized: "This review is frozen for a safe retry and can no longer be edited.")
        case .captureNotFound, .captureAlreadyResolved, .duplicateCapture,
             .captureRelationshipMismatch, .duplicateAuditID:
            String(localized: "The saved class markers changed. Close and reopen this review.")
        case .unsupportedSessionStatus:
            String(localized: "This class no longer needs a wrap-up.")
        case .invalidStartedAt, .tooManyCaptures:
            String(localized: "This class review could not be prepared safely.")
        }
    }
}

struct SessionWrapUpEditableCaptureFields: Equatable, Sendable {
    var title: String
    var details: String
    var scope: String
    var date: AcademicLocalDate?
    var dateCertainty: AcademicDateCertainty?

    init(
        title: String = "",
        details: String = "",
        scope: String = "",
        date: AcademicLocalDate? = nil,
        dateCertainty: AcademicDateCertainty? = nil
    ) {
        self.title = title
        self.details = details
        self.scope = scope
        self.date = date
        self.dateCertainty = dateCertainty
    }

    init(_ fields: CaptureDraftFields) {
        self.init(
            title: fields.title ?? "",
            details: fields.details ?? "",
            scope: fields.scope ?? "",
            date: fields.date,
            dateCertainty: fields.dateCertainty
        )
    }

    func validatedCaptureDraftFields() throws -> CaptureDraftFields {
        try CaptureDraftFields(
            title: Self.normalizedOptionalText(title),
            details: Self.normalizedOptionalText(details),
            scope: Self.normalizedOptionalText(scope),
            date: date,
            dateCertainty: dateCertainty
        )
    }

    private static func normalizedOptionalText(_ value: String) -> String? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

struct SessionWrapUpCapturePresentation: Equatable, Identifiable, Sendable {
    let capture: CaptureItem
    let captureID: CaptureItemID
    let kind: CaptureKind
    let source: CaptureSource
    let rawText: String?
    let capturedAt: Date
    let originalState: CaptureState
    let fields: SessionWrapUpEditableCaptureFields
    let selectedDecision: SessionWrapUpDecisionKind?
    let rejectionReason: String
    let reservedAuditIDs: [CaptureAuditEntryID]

    var id: CaptureItemID { captureID }
    var isAlreadyResolved: Bool { originalState == .resolved }
    var isAlreadyRejected: Bool {
        capture.resolution?.kind == .rejected
    }
    var isAlreadyReadyToConfirm: Bool { originalState == .readyToConfirm }
    var isAssignmentOrExamCandidate: Bool { kind.isAssignmentOrExamCandidate }

    var allowedDecisions: [SessionWrapUpDecisionKind] {
        switch originalState {
        case .inbox, .needsDetails:
            SessionWrapUpDecisionKind.allCases
        case .readyToConfirm:
            [.keepAsIs, .reject]
        case .resolved:
            []
        }
    }
}

struct SessionWrapUpDecisionCounts: Equatable, Sendable {
    let totalCaptures: Int
    let unresolvedCaptures: Int
    let keepAsIs: Int
    let markNeedsDetails: Int
    let markReadyToConfirm: Int
    let reject: Int
    let alreadyReadyToConfirm: Int
    let alreadyRejected: Int
}

/// A value-type editor for the V1 post-class review flow.
///
/// Identity and timestamps needed for an idempotent write are allocated when the draft starts.
/// The first successful `finish` call freezes the complete transaction; every later call returns
/// that exact value so retry cannot generate a new completion time, wrap-up ID, or audit ID.
struct SessionWrapUpDraft: Equatable, Sendable {
    let sessionID: CourseSessionID
    let expectedSessionRevision: Int64
    let wrapUpID: SessionWrapUpID
    let startedAt: Date

    private let session: CourseSession
    private var entries: [CaptureEntry]
    private let entryIndicesByID: [CaptureItemID: Int]

    private(set) var oneLineSummary: String
    private(set) var frozenTransaction: SessionWrapUpTransaction?

    init(
        session: CourseSession,
        captures: [CaptureItem],
        startedAt: Date = Date(),
        wrapUpID: SessionWrapUpID = SessionWrapUpID(),
        oneLineSummary: String = "",
        auditIDFactory: () -> CaptureAuditEntryID = { CaptureAuditEntryID() }
    ) throws {
        guard session.status == .active || session.status == .needsReview else {
            throw SessionWrapUpDraftError.unsupportedSessionStatus(session.status)
        }
        let latestCaptureModifiedAt = captures
            .map(\.modifiedAt)
            .max() ?? session.modifiedAt
        guard startedAt.timeIntervalSinceReferenceDate.isFinite,
              startedAt >= session.modifiedAt,
              startedAt >= latestCaptureModifiedAt else {
            throw SessionWrapUpDraftError.invalidStartedAt
        }
        guard captures.count <= AcademicDomainLimits.maximumCapturesPerSession else {
            throw SessionWrapUpDraftError.tooManyCaptures
        }

        var seenCaptureIDs = Set<CaptureItemID>()
        var seenAuditIDs = Set(captures.flatMap { $0.auditTrail.map(\.id) })
        var entries: [CaptureEntry] = []
        entries.reserveCapacity(captures.count)

        for capture in captures.sorted(by: Self.captureSort) {
            guard seenCaptureIDs.insert(capture.id).inserted else {
                throw SessionWrapUpDraftError.duplicateCapture(capture.id)
            }
            guard capture.courseID == session.courseID,
                  capture.sessionID == session.id else {
                throw SessionWrapUpDraftError.captureRelationshipMismatch(capture.id)
            }

            let auditIDs: [CaptureAuditEntryID]
            let decision: SessionWrapUpDecisionKind?
            if capture.state == .resolved {
                auditIDs = []
                decision = nil
            } else {
                let first = auditIDFactory()
                guard seenAuditIDs.insert(first).inserted else {
                    throw SessionWrapUpDraftError.duplicateAuditID(first)
                }
                let second = auditIDFactory()
                guard seenAuditIDs.insert(second).inserted else {
                    throw SessionWrapUpDraftError.duplicateAuditID(second)
                }
                auditIDs = [first, second]
                decision = .keepAsIs
            }

            entries.append(CaptureEntry(
                capture: capture,
                fields: SessionWrapUpEditableCaptureFields(capture.draftFields),
                decision: decision,
                rejectionReason: capture.resolution?.reason ?? "",
                reservedAuditIDs: auditIDs
            ))
        }

        self.sessionID = session.id
        self.expectedSessionRevision = session.revision
        self.wrapUpID = wrapUpID
        self.startedAt = startedAt
        self.session = session
        self.entries = entries
        self.entryIndicesByID = Dictionary(
            uniqueKeysWithValues: entries.enumerated().map { index, entry in
                (entry.capture.id, index)
            }
        )
        self.oneLineSummary = oneLineSummary
        self.frozenTransaction = nil
    }

    var capturePresentations: [SessionWrapUpCapturePresentation] {
        capturePresentations(limit: entries.count)
    }

    var captureCount: Int { entries.count }

    func capturePresentations(
        limit: Int
    ) -> [SessionWrapUpCapturePresentation] {
        entries.prefix(max(0, limit)).map { entry in
            SessionWrapUpCapturePresentation(
                capture: entry.capture,
                captureID: entry.capture.id,
                kind: entry.capture.kind,
                source: entry.capture.source,
                rawText: entry.capture.rawText,
                capturedAt: entry.capture.capturedAt,
                originalState: entry.capture.state,
                fields: entry.fields,
                selectedDecision: entry.decision,
                rejectionReason: entry.rejectionReason,
                reservedAuditIDs: entry.reservedAuditIDs
            )
        }
    }

    func presentation(
        for captureID: CaptureItemID
    ) -> SessionWrapUpCapturePresentation? {
        guard let index = entryIndicesByID[captureID], entries.indices.contains(index) else {
            return nil
        }
        let entry = entries[index]
        return SessionWrapUpCapturePresentation(
            capture: entry.capture,
            captureID: entry.capture.id,
            kind: entry.capture.kind,
            source: entry.capture.source,
            rawText: entry.capture.rawText,
            capturedAt: entry.capture.capturedAt,
            originalState: entry.capture.state,
            fields: entry.fields,
            selectedDecision: entry.decision,
            rejectionReason: entry.rejectionReason,
            reservedAuditIDs: entry.reservedAuditIDs
        )
    }

    var decisionCounts: SessionWrapUpDecisionCounts {
        SessionWrapUpDecisionCounts(
            totalCaptures: entries.count,
            unresolvedCaptures: entries.count(where: { $0.capture.state != .resolved }),
            keepAsIs: entries.count(where: { $0.decision == .keepAsIs }),
            markNeedsDetails: entries.count(where: { $0.decision == .markNeedsDetails }),
            markReadyToConfirm: entries.count(where: { $0.decision == .markReadyToConfirm }),
            reject: entries.count(where: { $0.decision == .reject }),
            alreadyReadyToConfirm: entries.count(where: {
                $0.capture.state == .readyToConfirm
            }),
            alreadyRejected: entries.count(where: { $0.capture.state == .resolved })
        )
    }

    var noNewActionsConfirmed: Bool {
        entries.allSatisfy { $0.capture.state == .resolved }
    }

    var isFrozen: Bool { frozenTransaction != nil }

    var finishValidationError: SessionWrapUpDraftError? {
        let normalizedSummary = oneLineSummary.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedSummary.isEmpty else { return .summaryRequired }
        guard !normalizedSummary.contains("\n"),
              !normalizedSummary.contains("\r") else {
            return .summaryMustBeOneLine
        }
        guard normalizedSummary.count <= AcademicDomainLimits.maximumSummaryCharacters,
              normalizedSummary.utf8.count
                <= AcademicDomainLimits.maximumSummaryUTF8Bytes else {
            return .summaryTooLong
        }

        for entry in entries {
            if let error = validationError(for: entry) {
                return error
            }
        }
        return nil
    }

    var canFinish: Bool { finishValidationError == nil }

    mutating func setOneLineSummary(_ summary: String) throws {
        try requireEditable()
        oneLineSummary = summary
    }

    mutating func setFields(
        _ fields: SessionWrapUpEditableCaptureFields,
        for captureID: CaptureItemID
    ) throws {
        try requireEditable()
        let index = try editableEntryIndex(for: captureID)
        entries[index].fields = fields
    }

    mutating func setRejectionReason(
        _ reason: String,
        for captureID: CaptureItemID
    ) throws {
        try requireEditable()
        let index = try editableEntryIndex(for: captureID)
        entries[index].rejectionReason = reason
    }

    mutating func setDecision(
        _ decision: SessionWrapUpDecisionKind,
        for captureID: CaptureItemID
    ) throws {
        try requireEditable()
        let index = try editableEntryIndex(for: captureID)
        let state = entries[index].capture.state
        let isAllowed = switch state {
        case .inbox, .needsDetails:
            true
        case .readyToConfirm:
            decision == .keepAsIs || decision == .reject
        case .resolved:
            false
        }
        guard isAllowed else {
            throw SessionWrapUpDraftError.decisionNotAllowed(
                captureID: captureID,
                state: state,
                decision: decision
            )
        }
        entries[index].decision = decision
    }

    mutating func finish(completedAt: Date) throws -> SessionWrapUpTransaction {
        if let frozenTransaction {
            return frozenTransaction
        }

        if let finishValidationError {
            throw finishValidationError
        }

        let decisions = try entries.compactMap { try makeDecision($0) }
        let normalizedSummary = oneLineSummary.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let transaction = try SessionWrapUpTransaction(
            sessionID: sessionID,
            expectedSessionRevision: expectedSessionRevision,
            wrapUpID: wrapUpID,
            startedAt: startedAt,
            completedAt: completedAt,
            oneLineSummary: normalizedSummary,
            noNewActionsConfirmed: decisions.isEmpty,
            decisions: decisions
        )

        // Validate the entire frozen snapshot before it can leave the draft. This includes the
        // exact one-decision-per-unresolved-capture relationship and state-specific audit counts.
        _ = try transaction.applying(
            to: session,
            captures: entries.map(\.capture)
        )
        frozenTransaction = transaction
        return transaction
    }

    private func makeDecision(_ entry: CaptureEntry) throws -> SessionWrapUpDecision? {
        guard let decision = entry.decision else {
            guard entry.capture.state == .resolved else {
                throw SessionWrapUpDraftError.captureNotFound(entry.capture.id)
            }
            return nil
        }

        switch decision {
        case .keepAsIs:
            return try SessionWrapUpDecision(
                captureID: entry.capture.id,
                expectedRevision: entry.capture.revision,
                kind: .keepAsIs
            )

        case .markNeedsDetails:
            return try SessionWrapUpDecision(
                captureID: entry.capture.id,
                expectedRevision: entry.capture.revision,
                kind: .markNeedsDetails,
                draftFields: try entry.fields.validatedCaptureDraftFields(),
                auditIDs: [entry.reservedAuditIDs[0]]
            )

        case .markReadyToConfirm:
            if entry.capture.kind.isAssignmentOrExamCandidate {
                guard !entry.fields.title.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty else {
                    throw SessionWrapUpDraftError.candidateTitleRequired(entry.capture.id)
                }
                guard entry.fields.dateCertainty != nil else {
                    throw SessionWrapUpDraftError.candidateDateCertaintyRequired(
                        entry.capture.id
                    )
                }
            }
            let fields = try entry.fields.validatedCaptureDraftFields()
            let auditIDs = entry.capture.state == .inbox
                ? Array(entry.reservedAuditIDs.prefix(2))
                : [entry.reservedAuditIDs[0]]
            return try SessionWrapUpDecision(
                captureID: entry.capture.id,
                expectedRevision: entry.capture.revision,
                kind: .markReadyToConfirm,
                draftFields: fields,
                auditIDs: auditIDs
            )

        case .reject:
            let reason = entry.rejectionReason.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !reason.isEmpty else {
                throw SessionWrapUpDraftError.rejectionReasonRequired(
                    entry.capture.id
                )
            }
            guard reason.count <= AcademicDomainLimits.maximumReasonCharacters,
                  reason.utf8.count
                    <= AcademicDomainLimits.maximumReasonUTF8Bytes else {
                throw SessionWrapUpDraftError.rejectionReasonTooLong(
                    entry.capture.id
                )
            }
            return try SessionWrapUpDecision(
                captureID: entry.capture.id,
                expectedRevision: entry.capture.revision,
                kind: .reject,
                rejectionReason: reason.isEmpty ? nil : reason,
                auditIDs: [entry.reservedAuditIDs[0]]
            )
        }
    }

    private func validationError(
        for entry: CaptureEntry
    ) -> SessionWrapUpDraftError? {
        guard let decision = entry.decision else {
            return entry.capture.state == .resolved
                ? nil
                : .captureNotFound(entry.capture.id)
        }

        switch decision {
        case .keepAsIs:
            return nil

        case .markNeedsDetails:
            do {
                _ = try entry.fields.validatedCaptureDraftFields()
                return nil
            } catch {
                return .invalidCaptureFields(entry.capture.id)
            }

        case .markReadyToConfirm:
            if entry.capture.kind.isAssignmentOrExamCandidate {
                guard !entry.fields.title.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty else {
                    return .candidateTitleRequired(entry.capture.id)
                }
                guard entry.fields.dateCertainty != nil else {
                    return .candidateDateCertaintyRequired(entry.capture.id)
                }
            }
            do {
                _ = try entry.fields.validatedCaptureDraftFields()
                return nil
            } catch {
                return .invalidCaptureFields(entry.capture.id)
            }

        case .reject:
            let reason = entry.rejectionReason.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !reason.isEmpty else {
                return .rejectionReasonRequired(entry.capture.id)
            }
            guard reason.count <= AcademicDomainLimits.maximumReasonCharacters,
                  reason.utf8.count
                    <= AcademicDomainLimits.maximumReasonUTF8Bytes else {
                return .rejectionReasonTooLong(entry.capture.id)
            }
            return nil
        }
    }

    private mutating func editableEntryIndex(
        for captureID: CaptureItemID
    ) throws -> Array<CaptureEntry>.Index {
        guard let index = entryIndicesByID[captureID],
              entries.indices.contains(index) else {
            throw SessionWrapUpDraftError.captureNotFound(captureID)
        }
        guard entries[index].capture.state != .resolved else {
            throw SessionWrapUpDraftError.captureAlreadyResolved(captureID)
        }
        return index
    }

    private func requireEditable() throws {
        guard frozenTransaction == nil else {
            throw SessionWrapUpDraftError.frozen
        }
    }

    private static func captureSort(_ lhs: CaptureItem, _ rhs: CaptureItem) -> Bool {
        if lhs.capturedAt != rhs.capturedAt {
            return lhs.capturedAt < rhs.capturedAt
        }
        return lhs.id < rhs.id
    }

    private struct CaptureEntry: Equatable, Sendable {
        let capture: CaptureItem
        var fields: SessionWrapUpEditableCaptureFields
        var decision: SessionWrapUpDecisionKind?
        var rejectionReason: String
        let reservedAuditIDs: [CaptureAuditEntryID]
    }
}
