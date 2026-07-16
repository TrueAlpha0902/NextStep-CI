import CryptoKit
import Foundation
import NextStepDomain

public enum GroundingReviewError: Error, Equatable, LocalizedError, Sendable {
    case sourceNotVerified
    case parseSourceMismatch
    case candidateNotFound
    case candidateNotReviewable
    case staleAnchor
    case anchorMismatch
    case anchorQuoteMismatch
    case invalidDateCandidate
    case invalidReview

    public var errorDescription: String? {
        switch self {
        case .sourceNotVerified:
            "The source is not content-hash verified."
        case .parseSourceMismatch:
            "The parsed source no longer matches the current source."
        case .candidateNotFound:
            "The source fact candidate was not found."
        case .candidateNotReviewable:
            "This source fact candidate cannot be confirmed as a date."
        case .staleAnchor:
            "A source anchor is stale."
        case .anchorMismatch:
            "A source anchor does not belong to the parsed source."
        case .anchorQuoteMismatch:
            "The candidate value cannot be found in its anchored quote."
        case .invalidDateCandidate:
            "The candidate is not an unambiguous full calendar date."
        case .invalidReview:
            "The source fact review is invalid."
        }
    }
}

public enum SourceFactReviewDisposition: String, Codable, Hashable, Sendable {
    case confirmed
    case rejected
}

public struct SourceFactReviewAudit: Codable, Hashable, Sendable, Identifiable {
    public let metadata: RecordMetadata<UUID>
    public let candidateID: UUID
    public let disposition: SourceFactReviewDisposition
    public let sourceDocumentID: SourceDocumentID
    public let sourceSHA256: String
    public let anchorIDs: [SourceAnchorID]
    public let parseRequestID: UUID
    public let parser: DocumentParserDescriptor
    public let confirmedFactID: UUID?
    public let evidenceLinkIDs: [EvidenceLinkID]
    public let reason: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case metadata
        case candidateID
        case disposition
        case sourceDocumentID
        case sourceSHA256
        case anchorIDs
        case parseRequestID
        case parser
        case confirmedFactID
        case evidenceLinkIDs
        case reason
    }

    public var id: UUID { metadata.id }

    public init(
        metadata: RecordMetadata<UUID>,
        candidateID: UUID,
        disposition: SourceFactReviewDisposition,
        sourceDocumentID: SourceDocumentID,
        sourceSHA256: String,
        anchorIDs: [SourceAnchorID],
        parseRequestID: UUID,
        parser: DocumentParserDescriptor,
        confirmedFactID: UUID?,
        evidenceLinkIDs: [EvidenceLinkID],
        reason: String?
    ) throws {
        let normalizedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasValidOutcomeLinks = disposition == .confirmed
            ? evidenceLinkIDs.count == anchorIDs.count
            : evidenceLinkIDs.isEmpty
        guard sourceSHA256.isGroundingLowercaseSHA256,
              anchorIDs.isEmpty == false,
              Set(anchorIDs).count == anchorIDs.count,
              Set(evidenceLinkIDs).count == evidenceLinkIDs.count,
              normalizedReason.map({ $0.isEmpty == false && $0.count <= 2_000 }) ?? true,
              (disposition == .rejected) == (normalizedReason != nil),
              (disposition == .confirmed) == (confirmedFactID != nil),
              hasValidOutcomeLinks,
              metadata.deletedAt == nil,
              metadata.provenance.kind == .user,
              metadata.provenance.sourceDocumentIDs == [sourceDocumentID] else {
            throw GroundingReviewError.invalidReview
        }
        self.metadata = metadata
        self.candidateID = candidateID
        self.disposition = disposition
        self.sourceDocumentID = sourceDocumentID
        self.sourceSHA256 = sourceSHA256
        self.anchorIDs = anchorIDs
        self.parseRequestID = parseRequestID
        self.parser = parser
        self.confirmedFactID = confirmedFactID
        self.evidenceLinkIDs = evidenceLinkIDs
        self.reason = normalizedReason
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectGroundingAdditionalKeys(allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            metadata: container.decode(RecordMetadata<UUID>.self, forKey: .metadata),
            candidateID: container.decode(UUID.self, forKey: .candidateID),
            disposition: container.decode(SourceFactReviewDisposition.self, forKey: .disposition),
            sourceDocumentID: container.decode(SourceDocumentID.self, forKey: .sourceDocumentID),
            sourceSHA256: container.decode(String.self, forKey: .sourceSHA256),
            anchorIDs: container.decode([SourceAnchorID].self, forKey: .anchorIDs),
            parseRequestID: container.decode(UUID.self, forKey: .parseRequestID),
            parser: container.decode(DocumentParserDescriptor.self, forKey: .parser),
            confirmedFactID: container.decodeIfPresent(UUID.self, forKey: .confirmedFactID),
            evidenceLinkIDs: container.decode(
                [EvidenceLinkID].self,
                forKey: .evidenceLinkIDs
            ),
            reason: container.decodeIfPresent(String.self, forKey: .reason)
        )
    }
}

public struct ConfirmedSourceDateFact: Codable, Hashable, Sendable, Identifiable {
    public let metadata: RecordMetadata<UUID>
    public let candidateID: UUID
    public let sourceDocumentID: SourceDocumentID
    public let kind: DocumentFactKind
    public let day: FactValue<LocalDay>

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case metadata
        case candidateID
        case sourceDocumentID
        case kind
        case day
    }

    public var id: UUID { metadata.id }

    public init(
        metadata: RecordMetadata<UUID>,
        candidateID: UUID,
        sourceDocumentID: SourceDocumentID,
        kind: DocumentFactKind,
        day: FactValue<LocalDay>
    ) throws {
        guard kind == .date || kind == .deadline,
              day.authority == .userConfirmed,
              day.mutability == .immutable,
              day.evidenceLinkIDs.isEmpty == false,
              Set(day.evidenceLinkIDs).count == day.evidenceLinkIDs.count,
              day.confirmedAt != nil,
              metadata.deletedAt == nil,
              metadata.provenance.kind == .user,
              metadata.provenance.sourceDocumentIDs == [sourceDocumentID] else {
            throw GroundingReviewError.invalidReview
        }
        self.metadata = metadata
        self.candidateID = candidateID
        self.sourceDocumentID = sourceDocumentID
        self.kind = kind
        self.day = day
    }

    public init(from decoder: Decoder) throws {
        try decoder.rejectGroundingAdditionalKeys(allowed: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            metadata: container.decode(RecordMetadata<UUID>.self, forKey: .metadata),
            candidateID: container.decode(UUID.self, forKey: .candidateID),
            sourceDocumentID: container.decode(SourceDocumentID.self, forKey: .sourceDocumentID),
            kind: container.decode(DocumentFactKind.self, forKey: .kind),
            day: container.decode(FactValue<LocalDay>.self, forKey: .day)
        )
    }
}

public enum SourceFactReviewDecision: Sendable, Hashable {
    case confirm(confirmedFactID: UUID, evidenceLinkIDs: [EvidenceLinkID])
    case reject(reason: String)
}

public struct SourceFactReviewOutcome: Sendable, Hashable {
    public let audit: SourceFactReviewAudit
    public let confirmedFact: ConfirmedSourceDateFact?
    public let evidenceLinks: [EvidenceLink]

    fileprivate init(
        audit: SourceFactReviewAudit,
        confirmedFact: ConfirmedSourceDateFact?,
        evidenceLinks: [EvidenceLink]
    ) {
        self.audit = audit
        self.confirmedFact = confirmedFact
        self.evidenceLinks = evidenceLinks
    }
}

public struct SourceFactReviewService: Sendable {
    public init() {}

    public func review(
        parseResult: DocumentParseResult,
        candidateID: UUID,
        sourceDocument: SourceDocument,
        anchors: [SourceAnchor],
        decision: SourceFactReviewDecision,
        occurredAt: Date,
        originDeviceID: DeviceID,
        auditID: UUID
    ) throws -> SourceFactReviewOutcome {
        guard let candidate = parseResult.factCandidates.first(where: {
            $0.candidateID == candidateID
        }) else {
            throw GroundingReviewError.candidateNotFound
        }

        switch decision {
        case let .reject(reason):
            let audit = try makeAudit(
                id: auditID,
                candidate: candidate,
                parseResult: parseResult,
                disposition: .rejected,
                confirmedFactID: nil,
                evidenceLinkIDs: [],
                reason: reason,
                occurredAt: occurredAt,
                originDeviceID: originDeviceID
            )
            return SourceFactReviewOutcome(
                audit: audit,
                confirmedFact: nil,
                evidenceLinks: []
            )

        case let .confirm(confirmedFactID, evidenceLinkIDs):
            try validateForConfirmation(
                candidate: candidate,
                parseResult: parseResult,
                sourceDocument: sourceDocument,
                anchors: anchors
            )
            guard evidenceLinkIDs.count == candidate.anchorIDs.count,
                  Set(evidenceLinkIDs).count == evidenceLinkIDs.count else {
                throw GroundingReviewError.invalidReview
            }
            let selectedAnchors = try candidate.anchorIDs.map { anchorID in
                guard let anchor = anchors.first(where: { $0.metadata.id == anchorID }) else {
                    throw GroundingReviewError.anchorMismatch
                }
                return anchor
            }
            let evidenceLinks = try zip(selectedAnchors, evidenceLinkIDs).map { anchor, linkID in
                try EvidenceLink(
                    metadata: RecordMetadata(
                        id: linkID,
                        createdAt: occurredAt,
                        originDeviceID: originDeviceID,
                        provenance: Provenance(
                            kind: .user,
                            sourceDocumentIDs: [sourceDocument.metadata.id]
                        )
                    ),
                    anchorID: anchor.metadata.id,
                    relation: .supports,
                    subjectType: "ConfirmedSourceDateFact",
                    subjectID: confirmedFactID,
                    verificationMethod: "user-confirmed anchored date candidate",
                    verifiedBy: .user
                )
            }
            let day = try FactValue(
                value: GroundedDateScanner.parseExact(candidate.value),
                authority: .userConfirmed,
                mutability: .immutable,
                evidenceLinkIDs: evidenceLinkIDs,
                confidence: candidate.confidence,
                confirmedAt: occurredAt
            )
            let confirmedFact = try ConfirmedSourceDateFact(
                metadata: RecordMetadata(
                    id: confirmedFactID,
                    createdAt: occurredAt,
                    originDeviceID: originDeviceID,
                    provenance: Provenance(
                        kind: .user,
                        sourceDocumentIDs: [sourceDocument.metadata.id]
                    )
                ),
                candidateID: candidate.candidateID,
                sourceDocumentID: sourceDocument.metadata.id,
                kind: candidate.kind,
                day: day
            )
            let audit = try makeAudit(
                id: auditID,
                candidate: candidate,
                parseResult: parseResult,
                disposition: .confirmed,
                confirmedFactID: confirmedFactID,
                evidenceLinkIDs: evidenceLinkIDs,
                reason: nil,
                occurredAt: occurredAt,
                originDeviceID: originDeviceID
            )
            return SourceFactReviewOutcome(
                audit: audit,
                confirmedFact: confirmedFact,
                evidenceLinks: evidenceLinks
            )
        }
    }

    private func validateForConfirmation(
        candidate: DocumentFactCandidate,
        parseResult: DocumentParseResult,
        sourceDocument: SourceDocument,
        anchors: [SourceAnchor]
    ) throws {
        guard candidate.requiresUserConfirmation,
              candidate.kind == .date || candidate.kind == .deadline else {
            throw GroundingReviewError.candidateNotReviewable
        }
        guard parseResult.status == .complete || parseResult.status == .partial,
              parseResult.sourceDocumentID == sourceDocument.metadata.id,
              let currentSHA256 = sourceDocument.contentSHA256,
              currentSHA256.lowercased() == parseResult.sourceSHA256.lowercased() else {
            throw GroundingReviewError.parseSourceMismatch
        }
        guard sourceDocument.metadata.deletedAt == nil,
              sourceDocument.verificationState == .contentHashVerified else {
            throw GroundingReviewError.sourceNotVerified
        }
        guard Set(anchors.map { $0.metadata.id }).count == anchors.count else {
            throw GroundingReviewError.anchorMismatch
        }

        for anchorID in candidate.anchorIDs {
            guard let anchor = anchors.first(where: { $0.metadata.id == anchorID }),
                  anchor.sourceDocumentID == sourceDocument.metadata.id else {
                throw GroundingReviewError.anchorMismatch
            }
            guard anchor.sourceRevision == sourceDocument.metadata.revision,
                  anchor.metadata.deletedAt == nil,
                  Self.locatorRevisionMatchesAnchor(anchor),
                  anchor.verificationState == .contentHashVerified else {
                throw GroundingReviewError.staleAnchor
            }
            guard let quote = Self.quote(
                from: anchor,
                parseResult: parseResult
            ),
                  quote.contains(candidate.value),
                  let quotedTextSHA256 = anchor.quotedTextSHA256,
                  quotedTextSHA256 == Self.sha256(quote) else {
                throw GroundingReviewError.anchorQuoteMismatch
            }
        }
        _ = try GroundedDateScanner.parseExact(candidate.value)
    }

    private func makeAudit(
        id: UUID,
        candidate: DocumentFactCandidate,
        parseResult: DocumentParseResult,
        disposition: SourceFactReviewDisposition,
        confirmedFactID: UUID?,
        evidenceLinkIDs: [EvidenceLinkID],
        reason: String?,
        occurredAt: Date,
        originDeviceID: DeviceID
    ) throws -> SourceFactReviewAudit {
        try SourceFactReviewAudit(
            metadata: RecordMetadata(
                id: id,
                createdAt: occurredAt,
                originDeviceID: originDeviceID,
                provenance: Provenance(
                    kind: .user,
                    sourceDocumentIDs: [parseResult.sourceDocumentID]
                )
            ),
            candidateID: candidate.candidateID,
            disposition: disposition,
            sourceDocumentID: parseResult.sourceDocumentID,
            sourceSHA256: parseResult.sourceSHA256,
            anchorIDs: candidate.anchorIDs,
            parseRequestID: parseResult.requestID,
            parser: parseResult.parser,
            confirmedFactID: confirmedFactID,
            evidenceLinkIDs: evidenceLinkIDs,
            reason: reason
        )
    }

    private static func quote(
        from anchor: SourceAnchor,
        parseResult: DocumentParseResult
    ) -> String? {
        switch anchor.locator {
        case let .pdf(_, _, textQuote), let .image(_, _, textQuote):
            if let textQuote { return textQuote }
        case let .web(_, _, _, _, textQuote):
            return textQuote
        case .note, .ink, .media:
            break
        }
        return parseResult.pages
            .lazy
            .flatMap(\.blocks)
            .first(where: { $0.anchorID == anchor.metadata.id })?
            .text
    }

    private static func locatorRevisionMatchesAnchor(_ anchor: SourceAnchor) -> Bool {
        switch anchor.locator {
        case let .note(_, _, _, _, _, revision):
            return revision == anchor.sourceRevision
        case let .ink(_, _, _, _, revision):
            return revision == anchor.sourceRevision
        case .pdf, .image, .web, .media:
            return true
        }
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
