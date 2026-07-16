import Foundation
import NextStepAcademic

enum CandidateReviewFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case assignments
    case exams

    var id: Self { self }

    func includes(_ capture: CaptureItem) -> Bool {
        switch self {
        case .all:
            capture.kind.isAssignmentOrExamCandidate
        case .assignments:
            capture.kind == .assignmentCandidate
        case .exams:
            capture.kind == .examCandidate
        }
    }
}

enum CandidateReviewSection: Int, CaseIterable, Identifiable, Sendable {
    case toReview
    case readyForLaterConfirmation
    case rejected

    var id: Self { self }

    func includes(_ capture: CaptureItem) -> Bool {
        guard capture.kind.isAssignmentOrExamCandidate else { return false }
        return switch (self, capture.state, capture.resolution?.kind) {
        case (.toReview, .inbox, _), (.toReview, .needsDetails, _):
            true
        case (.readyForLaterConfirmation, .readyToConfirm, _):
            true
        case (.rejected, .resolved, .rejected):
            true
        default:
            false
        }
    }
}

enum CandidateReviewOrdering {
    static func captures(
        in workspace: AcademicWorkspace,
        sessionID: CourseSessionID,
        filter: CandidateReviewFilter
    ) -> [CaptureItem] {
        captures(workspace.captures, sessionID: sessionID, filter: filter)
    }

    static func captures(
        _ captures: [CaptureItem],
        sessionID: CourseSessionID,
        filter: CandidateReviewFilter
    ) -> [CaptureItem] {
        captures
            .filter {
                $0.sessionID == sessionID
                    && $0.kind.isAssignmentOrExamCandidate
                    && filter.includes($0)
            }
            .sorted {
                if $0.capturedAt != $1.capturedAt {
                    return $0.capturedAt < $1.capturedAt
                }
                return $0.id < $1.id
            }
    }
}

enum CandidateReviewPendingReconciliation: Equatable {
    case none
    case expectedImage
    case applied
    case conflict
    case missing
    case terminalSession
}

/// Sheet-owned state for one exact Candidate Review operation.
///
/// The selected detail view is recreated whenever the canonical CaptureItem
/// changes. Keeping this state above that identity boundary makes an ambiguous
/// mutation and its retry controls survive an external workspace reload.
struct CandidateReviewPresentationState: Equatable {
    private(set) var pendingMutation: CaptureReviewMutation? = nil
    private(set) var isWorking = false
    private(set) var errorMessage: String? = nil

    var ownsRetryState: Bool {
        pendingMutation != nil || isWorking
    }

    mutating func begin(_ mutation: CaptureReviewMutation) -> Bool {
        guard pendingMutation == nil, !isWorking else { return false }
        pendingMutation = mutation
        isWorking = true
        errorMessage = nil
        return true
    }

    mutating func beginRetry() -> CaptureReviewMutation? {
        guard let pendingMutation, !isWorking else { return nil }
        isWorking = true
        errorMessage = nil
        return pendingMutation
    }

    mutating func beginReload() -> CaptureReviewMutation? {
        beginRetry()
    }

    func isCurrent(_ mutation: CaptureReviewMutation) -> Bool {
        pendingMutation == mutation
    }

    @discardableResult
    mutating func complete(_ mutation: CaptureReviewMutation) -> Bool {
        guard isCurrent(mutation) else { return false }
        clearPendingOperation()
        return true
    }

    @discardableResult
    mutating func complete(
        _ mutation: CaptureReviewMutation,
        withError message: String
    ) -> Bool {
        guard isCurrent(mutation) else { return false }
        pendingMutation = nil
        isWorking = false
        errorMessage = message
        return true
    }

    @discardableResult
    mutating func retainForRetry(
        _ mutation: CaptureReviewMutation,
        errorMessage message: String
    ) -> Bool {
        guard isCurrent(mutation) else { return false }
        isWorking = false
        errorMessage = message
        return true
    }

    mutating func presentLocalError(_ message: String) {
        guard pendingMutation == nil else { return }
        isWorking = false
        errorMessage = message
    }

    /// Explicit Reload abandons the pending user operation after the backing
    /// has been read successfully. This differs from an external reload, which
    /// must retain an exact expected-image retry.
    @discardableResult
    mutating func abandonAfterReload(
        _ mutation: CaptureReviewMutation
    ) -> Bool {
        complete(mutation)
    }

    mutating func reconcile(
        currentCapture: CaptureItem?,
        allowsEditing: Bool
    ) -> CandidateReviewPendingReconciliation {
        guard let pendingMutation else { return .none }

        if let currentCapture,
           CandidateReviewCanonicalCapture.equal(
               currentCapture,
               pendingMutation.resultingCapture
           ) {
            clearPendingOperation()
            return .applied
        }

        guard allowsEditing else {
            clearPendingOperation()
            return .terminalSession
        }

        guard let currentCapture else {
            clearPendingOperation()
            return .missing
        }

        if CandidateReviewCanonicalCapture.equal(
            currentCapture,
            pendingMutation.expectedCapture
        ) {
            return .expectedImage
        }

        clearPendingOperation()
        return .conflict
    }

    private mutating func clearPendingOperation() {
        pendingMutation = nil
        isWorking = false
        errorMessage = nil
    }
}

private enum CandidateReviewCanonicalCapture {
    static func value(_ capture: CaptureItem) -> CaptureItem? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(capture) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(CaptureItem.self, from: data)
    }

    static func equal(_ lhs: CaptureItem, _ rhs: CaptureItem) -> Bool {
        guard let left = value(lhs), let right = value(rhs) else { return false }
        return left == right
    }
}

struct CandidateEditorDraft: Equatable, Sendable {
    var title: String
    var details: String
    var scope: String
    var dateCertainty: AcademicDateCertainty {
        didSet {
            if dateCertainty == .unknown {
                hasUnrepresentableStoredDate = false
            }
        }
    }
    var date: Date {
        didSet { hasUnrepresentableStoredDate = false }
    }
    let timeZoneIdentifier: String
    private(set) var hasUnrepresentableStoredDate: Bool

    init(
        capture: CaptureItem,
        timeZoneIdentifier: String,
        fallbackDate: Date = Date()
    ) {
        title = capture.draftFields.title ?? ""
        details = capture.draftFields.details ?? ""
        scope = capture.draftFields.scope ?? ""
        dateCertainty = capture.draftFields.dateCertainty ?? .unknown
        self.timeZoneIdentifier = timeZoneIdentifier
        let convertedDate = capture.draftFields.date.flatMap {
            Self.date(from: $0, timeZoneIdentifier: timeZoneIdentifier)
        }
        date = convertedDate ?? fallbackDate
        hasUnrepresentableStoredDate = capture.draftFields.date != nil
            && convertedDate == nil
    }

    var canMarkReady: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hasUnrepresentableStoredDate
            && (dateCertainty == .unknown || Self.localDate(
                from: date,
                timeZoneIdentifier: timeZoneIdentifier
            ) != nil)
    }

    func makeFields() throws -> CaptureDraftFields {
        let localDate: AcademicLocalDate?
        switch dateCertainty {
        case .unknown:
            localDate = nil
        case .estimated, .confirmed:
            guard !hasUnrepresentableStoredDate,
                  let converted = Self.localDate(
                from: date,
                timeZoneIdentifier: timeZoneIdentifier
            ) else {
                throw AcademicDomainError.invalidField("candidateReview.date")
            }
            localDate = converted
        }
        return try CaptureDraftFields(
            title: Self.normalized(title),
            details: Self.normalized(details),
            scope: Self.normalized(scope),
            date: localDate,
            dateCertainty: dateCertainty
        )
    }

    private static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func date(
        from localDate: AcademicLocalDate,
        timeZoneIdentifier: String
    ) -> Date? {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: localDate.year,
            month: localDate.month,
            day: localDate.day,
            hour: 12
        ))
    }

    static func localDate(
        from date: Date,
        timeZoneIdentifier: String
    ) -> AcademicLocalDate? {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year,
              let month = components.month,
              let day = components.day else { return nil }
        return try? AcademicLocalDate(year: year, month: month, day: day)
    }
}
