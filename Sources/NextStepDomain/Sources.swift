import Foundation

private func isValidSHA256Hex(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
    }
}

public struct NormalizedRect: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    private enum CodingKeys: String, CodingKey {
        case x
        case y
        case width
        case height
    }

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard [x, y, width, height].allSatisfy({ $0.isFinite }),
              x >= 0, y >= 0, width >= 0, height >= 0,
              x + width <= 1.000_001, y + height <= 1.000_001 else {
            throw DomainValidationError.valueOutOfBounds("normalizedRect")
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            x: container.decode(Double.self, forKey: .x),
            y: container.decode(Double.self, forKey: .y),
            width: container.decode(Double.self, forKey: .width),
            height: container.decode(Double.self, forKey: .height)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(x, forKey: .x)
        try container.encode(y, forKey: .y)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
    }
}

public enum SourceDocumentType: String, Codable, CaseIterable, Hashable, Sendable {
    case note
    case pdf
    case word
    case presentation
    case image
    case scan
    case web
    case paper
    case syllabus
    case assignment
    case jobDescription
    case calendar
    case audio
    case other
}

public enum SourceAccessState: String, Codable, CaseIterable, Hashable, Sendable {
    case localFullText
    case legalOpenFullText
    case userProvidedFullText
    case abstractOnly
    case metadataOnly
    case unavailable
}

public enum SourceRightsState: String, Codable, CaseIterable, Hashable, Sendable {
    case userOwned
    case licensed
    case openAccess
    case quotationOnly
    case unknown
    case restricted
}

public enum SourceVerificationState: String, Codable, CaseIterable, Hashable, Sendable {
    case unverified
    case identityVerified
    case contentHashVerified
    case stale
    case failed
}

public struct SourceDocument: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<SourceDocumentID>
    public var type: SourceDocumentType
    public var displayTitle: String
    public var contentSHA256: String?
    public var rightsState: SourceRightsState
    public var accessState: SourceAccessState
    public var localRelativePath: String?
    public var canonicalURL: URL?
    public var parserVersion: String?
    public var accessedAt: Date
    public var publishedAt: Date?
    public var verificationState: SourceVerificationState

    public init(
        metadata: RecordMetadata<SourceDocumentID>,
        type: SourceDocumentType,
        displayTitle: String,
        contentSHA256: String? = nil,
        rightsState: SourceRightsState,
        accessState: SourceAccessState,
        localRelativePath: String? = nil,
        canonicalURL: URL? = nil,
        parserVersion: String? = nil,
        accessedAt: Date,
        publishedAt: Date? = nil,
        verificationState: SourceVerificationState = .unverified
    ) throws {
        guard displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw DomainValidationError.invalidField("source title")
        }
        if let contentSHA256 {
            guard isValidSHA256Hex(contentSHA256) else {
                throw DomainValidationError.invalidField("contentSHA256")
            }
        }
        guard localRelativePath != nil || canonicalURL != nil || accessState == .unavailable else {
            throw DomainValidationError.invalidField("source location")
        }
        self.metadata = metadata
        self.type = type
        self.displayTitle = displayTitle
        self.contentSHA256 = contentSHA256?.lowercased()
        self.rightsState = rightsState
        self.accessState = accessState
        self.localRelativePath = localRelativePath
        self.canonicalURL = canonicalURL
        self.parserVersion = parserVersion
        self.accessedAt = accessedAt
        self.publishedAt = publishedAt
        self.verificationState = verificationState
    }
}

public enum PeerReviewState: String, Codable, CaseIterable, Hashable, Sendable {
    case peerReviewed
    case editoriallyReviewed
    case notPeerReviewed
    case unknown
}

public struct PaperAuthor: Codable, Hashable, Sendable {
    public let givenName: String?
    public let familyName: String
    public let orcid: String?

    public init(givenName: String? = nil, familyName: String, orcid: String? = nil) throws {
        guard familyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw DomainValidationError.invalidField("paper author")
        }
        self.givenName = givenName
        self.familyName = familyName
        self.orcid = orcid
    }
}

public struct LegalAccessLink: Codable, Hashable, Sendable {
    public let label: String
    public let url: URL
    public let accessState: SourceAccessState

    public init(label: String, url: URL, accessState: SourceAccessState) {
        self.label = label
        self.url = url
        self.accessState = accessState
    }
}

public struct PaperSource: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<PaperSourceID>
    public let sourceDocumentID: SourceDocumentID
    public var fullTitle: String
    public var authors: [PaperAuthor]
    public var publicationYear: Int?
    public var venue: String?
    public var publisher: String?
    public var doi: String?
    public var officialPageURL: URL?
    public var legalAccessLinks: [LegalAccessLink]
    public var peerReviewState: PeerReviewState
    public var isPreprint: Bool
    public var recommendationReason: String
    public var goalRelevance: String
    public var requiredAnchorIDs: [SourceAnchorID]

    public init(
        metadata: RecordMetadata<PaperSourceID>,
        sourceDocumentID: SourceDocumentID,
        fullTitle: String,
        authors: [PaperAuthor],
        publicationYear: Int? = nil,
        venue: String? = nil,
        publisher: String? = nil,
        doi: String? = nil,
        officialPageURL: URL? = nil,
        legalAccessLinks: [LegalAccessLink] = [],
        peerReviewState: PeerReviewState = .unknown,
        isPreprint: Bool = false,
        recommendationReason: String,
        goalRelevance: String,
        requiredAnchorIDs: [SourceAnchorID] = []
    ) throws {
        guard fullTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              authors.isEmpty == false else {
            throw DomainValidationError.invalidField("paper identity")
        }
        guard publicationYear.map({ (1400...3_000).contains($0) }) ?? true else {
            throw DomainValidationError.valueOutOfBounds("publicationYear")
        }
        self.metadata = metadata
        self.sourceDocumentID = sourceDocumentID
        self.fullTitle = fullTitle
        self.authors = authors
        self.publicationYear = publicationYear
        self.venue = venue
        self.publisher = publisher
        self.doi = doi
        self.officialPageURL = officialPageURL
        self.legalAccessLinks = legalAccessLinks
        self.peerReviewState = peerReviewState
        self.isPreprint = isPreprint
        self.recommendationReason = recommendationReason
        self.goalRelevance = goalRelevance
        self.requiredAnchorIDs = requiredAnchorIDs
    }
}

public enum SourceLocator: Codable, Hashable, Sendable {
    case note(
        noteID: NoteReferenceID,
        pageID: UUID,
        blockID: UUID?,
        utf16Start: Int?,
        utf16Length: Int?,
        revision: Int64
    )
    case pdf(pageIndex: Int, normalizedRects: [NormalizedRect], textQuote: String?)
    /// A zero-based page and a non-empty normalized region in an image or a
    /// multipage scan. Standalone images use page zero.
    case image(pageIndex: Int, normalizedRegion: NormalizedRect, textQuote: String?)
    case web(canonicalURL: URL, textStart: Int?, textLength: Int?, selector: String?, textQuote: String)
    case ink(documentID: UUID, pageID: UUID, strokeIDs: [UUID], bounds: NormalizedRect, revision: Int64)
    case media(startMilliseconds: Int64, endMilliseconds: Int64)

    public func validate() throws {
        switch self {
        case let .note(_, _, _, utf16Start, utf16Length, revision):
            guard revision >= 0,
                  (utf16Start == nil) == (utf16Length == nil) else {
                throw DomainValidationError.invalidField("note source locator")
            }
            if let utf16Start, let utf16Length {
                guard utf16Start >= 0, utf16Length > 0 else {
                    throw DomainValidationError.valueOutOfBounds("note source range")
                }
            }
        case let .pdf(pageIndex, normalizedRects, textQuote):
            guard pageIndex >= 0,
                  normalizedRects.allSatisfy({ $0.width > 0 && $0.height > 0 }),
                  normalizedRects.isEmpty == false || isMeaningful(textQuote) else {
                throw DomainValidationError.invalidField("PDF source locator")
            }
        case let .image(pageIndex, normalizedRegion, textQuote):
            guard pageIndex >= 0,
                  normalizedRegion.width > 0,
                  normalizedRegion.height > 0,
                  textQuote.map({ isMeaningful($0) }) ?? true else {
                throw DomainValidationError.invalidField("image source locator")
            }
        case let .web(canonicalURL, textStart, textLength, selector, textQuote):
            guard canonicalURL.scheme?.isEmpty == false,
                  (textStart == nil) == (textLength == nil),
                  isMeaningful(textQuote) || (selector.map({ isMeaningful($0) }) ?? false) else {
                throw DomainValidationError.invalidField("web source locator")
            }
            if let textStart, let textLength {
                guard textStart >= 0, textLength > 0 else {
                    throw DomainValidationError.valueOutOfBounds("web source range")
                }
            }
        case let .ink(_, _, strokeIDs, bounds, revision):
            guard revision >= 0,
                  strokeIDs.isEmpty == false,
                  Set(strokeIDs).count == strokeIDs.count,
                  bounds.width > 0,
                  bounds.height > 0 else {
                throw DomainValidationError.invalidField("ink source locator")
            }
        case let .media(startMilliseconds, endMilliseconds):
            guard startMilliseconds >= 0, endMilliseconds > startMilliseconds else {
                throw DomainValidationError.valueOutOfBounds("media source range")
            }
        }
    }

    public init(from decoder: Decoder) throws {
        let representation = try SourceLocatorCodingRepresentation(from: decoder)
        switch representation {
        case let .note(noteID, pageID, blockID, utf16Start, utf16Length, revision):
            self = .note(
                noteID: noteID,
                pageID: pageID,
                blockID: blockID,
                utf16Start: utf16Start,
                utf16Length: utf16Length,
                revision: revision
            )
        case let .pdf(pageIndex, normalizedRects, textQuote):
            self = .pdf(
                pageIndex: pageIndex,
                normalizedRects: normalizedRects,
                textQuote: textQuote
            )
        case let .image(pageIndex, normalizedRegion, textQuote):
            self = .image(
                pageIndex: pageIndex,
                normalizedRegion: normalizedRegion,
                textQuote: textQuote
            )
        case let .web(canonicalURL, textStart, textLength, selector, textQuote):
            self = .web(
                canonicalURL: canonicalURL,
                textStart: textStart,
                textLength: textLength,
                selector: selector,
                textQuote: textQuote
            )
        case let .ink(documentID, pageID, strokeIDs, bounds, revision):
            self = .ink(
                documentID: documentID,
                pageID: pageID,
                strokeIDs: strokeIDs,
                bounds: bounds,
                revision: revision
            )
        case let .media(startMilliseconds, endMilliseconds):
            self = .media(
                startMilliseconds: startMilliseconds,
                endMilliseconds: endMilliseconds
            )
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        let representation: SourceLocatorCodingRepresentation
        switch self {
        case let .note(noteID, pageID, blockID, utf16Start, utf16Length, revision):
            representation = .note(
                noteID: noteID,
                pageID: pageID,
                blockID: blockID,
                utf16Start: utf16Start,
                utf16Length: utf16Length,
                revision: revision
            )
        case let .pdf(pageIndex, normalizedRects, textQuote):
            representation = .pdf(
                pageIndex: pageIndex,
                normalizedRects: normalizedRects,
                textQuote: textQuote
            )
        case let .image(pageIndex, normalizedRegion, textQuote):
            representation = .image(
                pageIndex: pageIndex,
                normalizedRegion: normalizedRegion,
                textQuote: textQuote
            )
        case let .web(canonicalURL, textStart, textLength, selector, textQuote):
            representation = .web(
                canonicalURL: canonicalURL,
                textStart: textStart,
                textLength: textLength,
                selector: selector,
                textQuote: textQuote
            )
        case let .ink(documentID, pageID, strokeIDs, bounds, revision):
            representation = .ink(
                documentID: documentID,
                pageID: pageID,
                strokeIDs: strokeIDs,
                bounds: bounds,
                revision: revision
            )
        case let .media(startMilliseconds, endMilliseconds):
            representation = .media(
                startMilliseconds: startMilliseconds,
                endMilliseconds: endMilliseconds
            )
        }
        try representation.encode(to: encoder)
    }

    private func isMeaningful(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

private enum SourceLocatorCodingRepresentation: Codable {
    case note(
        noteID: NoteReferenceID,
        pageID: UUID,
        blockID: UUID?,
        utf16Start: Int?,
        utf16Length: Int?,
        revision: Int64
    )
    case pdf(pageIndex: Int, normalizedRects: [NormalizedRect], textQuote: String?)
    case image(pageIndex: Int, normalizedRegion: NormalizedRect, textQuote: String?)
    case web(canonicalURL: URL, textStart: Int?, textLength: Int?, selector: String?, textQuote: String)
    case ink(documentID: UUID, pageID: UUID, strokeIDs: [UUID], bounds: NormalizedRect, revision: Int64)
    case media(startMilliseconds: Int64, endMilliseconds: Int64)
}

public struct SourceAnchor: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<SourceAnchorID>
    public let sourceDocumentID: SourceDocumentID
    public var locator: SourceLocator
    public var quotedTextSHA256: String?
    public var sourceRevision: Int64
    public var capturedAt: Date
    public var verificationState: SourceVerificationState

    private enum CodingKeys: String, CodingKey {
        case metadata
        case sourceDocumentID
        case locator
        case quotedTextSHA256
        case sourceRevision
        case capturedAt
        case verificationState
    }

    public init(
        metadata: RecordMetadata<SourceAnchorID>,
        sourceDocumentID: SourceDocumentID,
        locator: SourceLocator,
        quotedTextSHA256: String? = nil,
        sourceRevision: Int64,
        capturedAt: Date,
        verificationState: SourceVerificationState
    ) throws {
        guard sourceRevision >= 0 else {
            throw DomainValidationError.valueOutOfBounds("sourceRevision")
        }
        if let quotedTextSHA256, isValidSHA256Hex(quotedTextSHA256) == false {
            throw DomainValidationError.invalidField("quotedTextSHA256")
        }
        try locator.validate()
        self.metadata = metadata
        self.sourceDocumentID = sourceDocumentID
        self.locator = locator
        self.quotedTextSHA256 = quotedTextSHA256?.lowercased()
        self.sourceRevision = sourceRevision
        self.capturedAt = capturedAt
        self.verificationState = verificationState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            metadata: container.decode(
                RecordMetadata<SourceAnchorID>.self,
                forKey: .metadata
            ),
            sourceDocumentID: container.decode(SourceDocumentID.self, forKey: .sourceDocumentID),
            locator: container.decode(SourceLocator.self, forKey: .locator),
            quotedTextSHA256: container.decodeIfPresent(String.self, forKey: .quotedTextSHA256),
            sourceRevision: container.decode(Int64.self, forKey: .sourceRevision),
            capturedAt: container.decode(Date.self, forKey: .capturedAt),
            verificationState: container.decode(
                SourceVerificationState.self,
                forKey: .verificationState
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(sourceDocumentID, forKey: .sourceDocumentID)
        try container.encode(locator, forKey: .locator)
        try container.encodeIfPresent(quotedTextSHA256, forKey: .quotedTextSHA256)
        try container.encode(sourceRevision, forKey: .sourceRevision)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(verificationState, forKey: .verificationState)
    }
}

public enum EvidenceRelation: String, Codable, CaseIterable, Hashable, Sendable {
    case supports
    case contradicts
    case defines
    case limits
    case measures
}

public struct EvidenceLink: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<EvidenceLinkID>
    public let anchorID: SourceAnchorID
    public let relation: EvidenceRelation
    public let subjectType: String
    public let subjectID: UUID
    public var verificationMethod: String
    public var verifiedBy: ProvenanceKind

    public init(
        metadata: RecordMetadata<EvidenceLinkID>,
        anchorID: SourceAnchorID,
        relation: EvidenceRelation,
        subjectType: String,
        subjectID: UUID,
        verificationMethod: String,
        verifiedBy: ProvenanceKind
    ) throws {
        guard subjectType.isEmpty == false, verificationMethod.isEmpty == false else {
            throw DomainValidationError.invalidField("evidenceLink")
        }
        self.metadata = metadata
        self.anchorID = anchorID
        self.relation = relation
        self.subjectType = subjectType
        self.subjectID = subjectID
        self.verificationMethod = verificationMethod
        self.verifiedBy = verifiedBy
    }
}

public enum HighlightSemantic: String, Codable, CaseIterable, Hashable, Sendable {
    case coreConclusion
    case definitionMethodData
    case application
    case limitationRiskDispute
    case personalKnowledgeLink
}

public struct Highlight: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<HighlightID>
    public let anchorID: SourceAnchorID
    public var semantic: HighlightSemantic
    public var originalText: String
    public var explanation: String
    public var learningObjectiveIDs: [UUID]
    public var knowledgeConceptIDs: [KnowledgeConceptID]
    public var isUnderstood: Bool
    public var needsReview: Bool

    public init(
        metadata: RecordMetadata<HighlightID>,
        anchorID: SourceAnchorID,
        semantic: HighlightSemantic,
        originalText: String,
        explanation: String,
        learningObjectiveIDs: [UUID] = [],
        knowledgeConceptIDs: [KnowledgeConceptID] = [],
        isUnderstood: Bool = false,
        needsReview: Bool = true
    ) throws {
        guard originalText.isEmpty == false else {
            throw DomainValidationError.invalidField("highlight text")
        }
        self.metadata = metadata
        self.anchorID = anchorID
        self.semantic = semantic
        self.originalText = originalText
        self.explanation = explanation
        self.learningObjectiveIDs = learningObjectiveIDs
        self.knowledgeConceptIDs = knowledgeConceptIDs
        self.isUnderstood = isUnderstood
        self.needsReview = needsReview
    }
}

public enum ClaimVerificationState: String, Codable, CaseIterable, Hashable, Sendable {
    case proposed
    case evidenceLinked
    case userConfirmed
    case rejected
}

public struct ExtractedClaim: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<ExtractedClaimID>
    public var normalizedClaim: String
    public var claimType: String
    public var author: ProvenanceKind
    public var verificationState: ClaimVerificationState
    public var evidenceLinkIDs: [EvidenceLinkID]

    public init(
        metadata: RecordMetadata<ExtractedClaimID>,
        normalizedClaim: String,
        claimType: String,
        author: ProvenanceKind,
        verificationState: ClaimVerificationState,
        evidenceLinkIDs: [EvidenceLinkID]
    ) throws {
        guard normalizedClaim.isEmpty == false, claimType.isEmpty == false else {
            throw DomainValidationError.invalidField("extractedClaim")
        }
        if verificationState == .evidenceLinked || verificationState == .userConfirmed {
            guard evidenceLinkIDs.isEmpty == false else {
                throw DomainValidationError.invalidField("claim evidence")
            }
        }
        self.metadata = metadata
        self.normalizedClaim = normalizedClaim
        self.claimType = claimType
        self.author = author
        self.verificationState = verificationState
        self.evidenceLinkIDs = evidenceLinkIDs
    }
}

public struct Citation: Codable, Hashable, Sendable {
    public let metadata: RecordMetadata<CitationID>
    public let paperSourceID: PaperSourceID?
    public let sourceDocumentID: SourceDocumentID
    public var anchorIDs: [SourceAnchorID]
    public var citedClaim: String
    public var context: String
    public var locatorLabel: String?

    private enum CodingKeys: String, CodingKey {
        case metadata
        case paperSourceID
        case sourceDocumentID
        case anchorIDs
        case citedClaim
        case context
        case locatorLabel
    }

    public init(
        metadata: RecordMetadata<CitationID>,
        paperSourceID: PaperSourceID? = nil,
        sourceDocumentID: SourceDocumentID,
        anchorIDs: [SourceAnchorID],
        citedClaim: String,
        context: String,
        locatorLabel: String? = nil
    ) throws {
        guard anchorIDs.isEmpty == false,
              Set(anchorIDs).count == anchorIDs.count,
              citedClaim.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              locatorLabel.map({
                  $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
              }) ?? true else {
            throw DomainValidationError.invalidField("citation")
        }
        self.metadata = metadata
        self.paperSourceID = paperSourceID
        self.sourceDocumentID = sourceDocumentID
        self.anchorIDs = anchorIDs
        self.citedClaim = citedClaim
        self.context = context
        self.locatorLabel = locatorLabel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            metadata: container.decode(RecordMetadata<CitationID>.self, forKey: .metadata),
            paperSourceID: container.decodeIfPresent(PaperSourceID.self, forKey: .paperSourceID),
            sourceDocumentID: container.decode(SourceDocumentID.self, forKey: .sourceDocumentID),
            anchorIDs: container.decode([SourceAnchorID].self, forKey: .anchorIDs),
            citedClaim: container.decode(String.self, forKey: .citedClaim),
            context: container.decode(String.self, forKey: .context),
            locatorLabel: container.decodeIfPresent(String.self, forKey: .locatorLabel)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metadata, forKey: .metadata)
        try container.encodeIfPresent(paperSourceID, forKey: .paperSourceID)
        try container.encode(sourceDocumentID, forKey: .sourceDocumentID)
        try container.encode(anchorIDs, forKey: .anchorIDs)
        try container.encode(citedClaim, forKey: .citedClaim)
        try container.encode(context, forKey: .context)
        try container.encodeIfPresent(locatorLabel, forKey: .locatorLabel)
    }
}
