import Foundation

/// Hard limits for the durable, user-reviewable handwriting-recognition
/// sidecar. Machine suggestions and user corrections share one atomic file but
/// remain logically separate fields.
public enum HandwritingRecognitionLimits {
    public static let maximumEncodedBytes = 8 * 1_024 * 1_024
    public static let maximumCandidateCount = 5_000
    public static let maximumLanguageCount = 8
    public static let maximumUTF8BytesPerTextField = 64 * 1_024
    public static let maximumTotalTextUTF8Bytes = 4 * 1_024 * 1_024
    public static let maximumEngineIdentifierUTF8Bytes = 256
    public static let maximumLocaleIdentifierUTF8Bytes = 128
}

/// Page-normalized coordinates with an upper-left origin. Keeping this model
/// independent of Vision prevents lower-left Vision coordinates from leaking
/// into durable UI state.
public struct HandwritingNormalizedBounds: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct HandwritingMachineCandidate: Codable, Equatable, Sendable, Identifiable {
    /// Machine output is immutable for the lifetime of a recognition run.
    /// User changes belong in `HandwritingCandidateReview.correctedText`.
    public let id: UUID
    public let machineText: String
    public let machineConfidence: Double
    public let normalizedPageBounds: HandwritingNormalizedBounds
    public let localeIdentifier: String?

    public init(
        id: UUID = UUID(),
        machineText: String,
        machineConfidence: Double,
        normalizedPageBounds: HandwritingNormalizedBounds,
        localeIdentifier: String? = nil
    ) {
        self.id = id
        self.machineText = machineText
        self.machineConfidence = machineConfidence
        self.normalizedPageBounds = normalizedPageBounds
        self.localeIdentifier = localeIdentifier
    }
}

public enum HandwritingReviewDecision: String, Codable, Equatable, Sendable {
    case accepted
    case rejected
}

public struct HandwritingCandidateReview: Codable, Equatable, Sendable, Identifiable {
    public var candidateID: UUID
    public var decision: HandwritingReviewDecision
    /// `nil` means the reviewer accepted the immutable machine suggestion.
    /// A nonnil value is user-authored text and never overwrites `machineText`.
    public var correctedText: String?
    public var reviewedAt: Date

    public var id: UUID { candidateID }

    public init(
        candidateID: UUID,
        decision: HandwritingReviewDecision,
        correctedText: String? = nil,
        reviewedAt: Date = .now
    ) {
        self.candidateID = candidateID
        self.decision = decision
        self.correctedText = correctedText
        self.reviewedAt = reviewedAt
    }
}

public struct ReviewedHandwritingText: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let normalizedPageBounds: HandwritingNormalizedBounds
    public let localeIdentifier: String?

    public init(
        id: UUID,
        text: String,
        normalizedPageBounds: HandwritingNormalizedBounds,
        localeIdentifier: String?
    ) {
        self.id = id
        self.text = text
        self.normalizedPageBounds = normalizedPageBounds
        self.localeIdentifier = localeIdentifier
    }
}

public struct HandwritingRecognitionDocument: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let runID: UUID
    public let pageID: PageID
    public let sourceInkSHA256: String
    public let engineIdentifier: String
    public let engineRevision: Int
    public let languages: [String]
    public let generatedAt: Date
    public var revision: Int64
    public var modifiedAt: Date
    public let machineCandidates: [HandwritingMachineCandidate]
    public var reviews: [HandwritingCandidateReview]

    public init(
        schemaVersion: Int = HandwritingRecognitionDocument.currentSchemaVersion,
        runID: UUID = UUID(),
        pageID: PageID,
        sourceInkSHA256: String,
        engineIdentifier: String,
        engineRevision: Int,
        languages: [String],
        generatedAt: Date = .now,
        revision: Int64 = 1,
        modifiedAt: Date? = nil,
        machineCandidates: [HandwritingMachineCandidate],
        reviews: [HandwritingCandidateReview] = []
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.pageID = pageID
        self.sourceInkSHA256 = sourceInkSHA256
        self.engineIdentifier = engineIdentifier
        self.engineRevision = engineRevision
        self.languages = languages
        self.generatedAt = generatedAt
        self.revision = revision
        self.modifiedAt = modifiedAt ?? generatedAt
        self.machineCandidates = machineCandidates
        self.reviews = reviews
    }

    /// Only explicitly accepted suggestions become searchable. Pending and
    /// rejected machine output is intentionally absent.
    public var acceptedText: [ReviewedHandwritingText] {
        // Public initialization intentionally permits callers to build a value
        // before validation. Never let derived text trap or leak content from
        // such an invalid value (for example, duplicate review identifiers).
        guard (try? validate()) != nil else { return [] }
        var reviewsByCandidate: [UUID: HandwritingCandidateReview] = [:]
        reviewsByCandidate.reserveCapacity(reviews.count)
        for review in reviews {
            reviewsByCandidate[review.candidateID] = review
        }
        return machineCandidates.compactMap { candidate in
            guard let review = reviewsByCandidate[candidate.id],
                  review.decision == .accepted else { return nil }
            let text = review.correctedText ?? candidate.machineText
            return ReviewedHandwritingText(
                id: candidate.id,
                text: text,
                normalizedPageBounds: candidate.normalizedPageBounds,
                localeIdentifier: candidate.localeIdentifier
            )
        }
    }

    public func validated(expectedPageID: PageID? = nil) throws -> Self {
        try validate(expectedPageID: expectedPageID)
        return self
    }

    public func validate(expectedPageID: PageID? = nil) throws {
        if schemaVersion > Self.currentSchemaVersion {
            throw HandwritingRecognitionValidationError.futureSchemaVersion(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        guard schemaVersion == Self.currentSchemaVersion else {
            throw HandwritingRecognitionValidationError.invalidSchemaVersion(schemaVersion)
        }
        if let expectedPageID, pageID != expectedPageID {
            throw HandwritingRecognitionValidationError.pageIdentifierMismatch
        }
        guard revision > 0 else {
            throw HandwritingRecognitionValidationError.invalidRevision
        }
        guard sourceInkSHA256.count == 64,
              sourceInkSHA256.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef").contains($0)
              }) else {
            throw HandwritingRecognitionValidationError.invalidInkFingerprint
        }
        let trimmedEngine = engineIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedEngine.isEmpty,
              trimmedEngine == engineIdentifier,
              engineIdentifier.utf8.count
                <= HandwritingRecognitionLimits.maximumEngineIdentifierUTF8Bytes,
              !engineIdentifier.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              engineRevision >= 0 else {
            throw HandwritingRecognitionValidationError.invalidEngine
        }
        guard !languages.isEmpty,
              languages.count <= HandwritingRecognitionLimits.maximumLanguageCount else {
            throw HandwritingRecognitionValidationError.invalidLanguages
        }
        var languageKeys = Set<String>()
        for language in languages {
            let key = try Self.validatedLocale(language)
            guard languageKeys.insert(key).inserted else {
                throw HandwritingRecognitionValidationError.invalidLanguages
            }
        }
        guard Self.validDate(generatedAt),
              Self.validDate(modifiedAt),
              modifiedAt >= generatedAt else {
            throw HandwritingRecognitionValidationError.invalidTimestamp
        }
        guard machineCandidates.count
                <= HandwritingRecognitionLimits.maximumCandidateCount else {
            throw HandwritingRecognitionValidationError.tooManyCandidates
        }
        guard reviews.count <= HandwritingRecognitionLimits.maximumCandidateCount else {
            throw HandwritingRecognitionValidationError.tooManyReviews
        }

        var totalTextBytes = 0
        var candidateIDs = Set<UUID>()
        candidateIDs.reserveCapacity(machineCandidates.count)
        for candidate in machineCandidates {
            guard candidateIDs.insert(candidate.id).inserted else {
                throw HandwritingRecognitionValidationError.duplicateCandidate
            }
            try Self.addText(
                candidate.machineText,
                allowEmpty: false,
                total: &totalTextBytes
            )
            guard candidate.machineConfidence.isFinite,
                  (0 ... 1).contains(candidate.machineConfidence),
                  Self.valid(candidate.normalizedPageBounds) else {
                throw HandwritingRecognitionValidationError.invalidCandidate
            }
            if let localeIdentifier = candidate.localeIdentifier {
                let candidateLocaleKey: String
                do {
                    candidateLocaleKey = try Self.validatedLocale(localeIdentifier)
                } catch {
                    throw HandwritingRecognitionValidationError.invalidCandidateLocale
                }
                guard languageKeys.contains(where: {
                    Self.locale(candidateLocaleKey, isCompatibleWith: $0)
                }) else {
                    throw HandwritingRecognitionValidationError.invalidCandidateLocale
                }
            }
        }

        var reviewedCandidateIDs = Set<UUID>()
        reviewedCandidateIDs.reserveCapacity(reviews.count)
        for review in reviews {
            guard reviewedCandidateIDs.insert(review.candidateID).inserted else {
                throw HandwritingRecognitionValidationError.duplicateReview
            }
            guard candidateIDs.contains(review.candidateID) else {
                throw HandwritingRecognitionValidationError.danglingReview
            }
            guard Self.validDate(review.reviewedAt),
                  review.reviewedAt >= generatedAt,
                  review.reviewedAt <= modifiedAt else {
                throw HandwritingRecognitionValidationError.invalidReviewTimestamp
            }
            switch review.decision {
            case .accepted:
                if let correctedText = review.correctedText {
                    try Self.addText(
                        correctedText,
                        allowEmpty: false,
                        total: &totalTextBytes
                    )
                }
            case .rejected:
                guard review.correctedText == nil else {
                    throw HandwritingRecognitionValidationError.invalidReview
                }
            }
        }
    }

    private static func validatedLocale(_ value: String) throws -> String {
        guard value.utf8.count
                <= HandwritingRecognitionLimits.maximumLocaleIdentifierUTF8Bytes,
              value.range(
                  of: #"^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8}){0,7}$"#,
                  options: .regularExpression
              ) != nil else {
            throw HandwritingRecognitionValidationError.invalidLanguages
        }
        return value.lowercased()
    }

    private static func locale(_ candidate: String, isCompatibleWith language: String) -> Bool {
        candidate == language
            || candidate.hasPrefix(language + "-")
            || language.hasPrefix(candidate + "-")
    }

    private static func addText(
        _ value: String,
        allowEmpty: Bool,
        total: inout Int
    ) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let byteCount = value.utf8.count
        guard (allowEmpty || !trimmed.isEmpty),
              byteCount <= HandwritingRecognitionLimits.maximumUTF8BytesPerTextField,
              !value.unicodeScalars.contains(where: { scalar in
                  guard CharacterSet.controlCharacters.contains(scalar) else {
                      return false
                  }
                  return scalar.value != 0x09
                      && scalar.value != 0x0A
                      && scalar.value != 0x0D
              }) else {
            throw HandwritingRecognitionValidationError.invalidText
        }
        let (sum, overflow) = total.addingReportingOverflow(byteCount)
        guard !overflow,
              sum <= HandwritingRecognitionLimits.maximumTotalTextUTF8Bytes else {
            throw HandwritingRecognitionValidationError.tooMuchText
        }
        total = sum
    }

    private static func valid(_ bounds: HandwritingNormalizedBounds) -> Bool {
        let values = [bounds.x, bounds.y, bounds.width, bounds.height]
        guard values.allSatisfy(\.isFinite),
              (0 ... 1).contains(bounds.x),
              (0 ... 1).contains(bounds.y),
              bounds.width > 0,
              bounds.width <= 1,
              bounds.height > 0,
              bounds.height <= 1 else { return false }
        let maxX = bounds.x + bounds.width
        let maxY = bounds.y + bounds.height
        return maxX.isFinite && maxY.isFinite
            && maxX <= 1 && maxY <= 1
    }

    private static func validDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case runID
        case pageID
        case sourceInkSHA256
        case engineIdentifier
        case engineRevision
        case languages
        case generatedAt
        case revision
        case modifiedAt
        case machineCandidates
        case reviews
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        if decodedSchemaVersion > Self.currentSchemaVersion {
            throw HandwritingRecognitionValidationError.futureSchemaVersion(
                found: decodedSchemaVersion,
                supported: Self.currentSchemaVersion
            )
        }
        guard decodedSchemaVersion == Self.currentSchemaVersion else {
            throw HandwritingRecognitionValidationError.invalidSchemaVersion(
                decodedSchemaVersion
            )
        }

        var decodedLanguages: [String] = []
        var languageValues = try values.nestedUnkeyedContainer(forKey: .languages)
        if let count = languageValues.count,
           count > HandwritingRecognitionLimits.maximumLanguageCount {
            throw HandwritingRecognitionValidationError.invalidLanguages
        }
        while !languageValues.isAtEnd {
            guard decodedLanguages.count
                    < HandwritingRecognitionLimits.maximumLanguageCount else {
                throw HandwritingRecognitionValidationError.invalidLanguages
            }
            decodedLanguages.append(try languageValues.decode(String.self))
        }

        var decodedCandidates: [HandwritingMachineCandidate] = []
        var candidateValues = try values.nestedUnkeyedContainer(forKey: .machineCandidates)
        if let count = candidateValues.count,
           count > HandwritingRecognitionLimits.maximumCandidateCount {
            throw HandwritingRecognitionValidationError.tooManyCandidates
        }
        decodedCandidates.reserveCapacity(
            min(
                candidateValues.count ?? 0,
                HandwritingRecognitionLimits.maximumCandidateCount
            )
        )
        while !candidateValues.isAtEnd {
            guard decodedCandidates.count
                    < HandwritingRecognitionLimits.maximumCandidateCount else {
                throw HandwritingRecognitionValidationError.tooManyCandidates
            }
            decodedCandidates.append(
                try candidateValues.decode(HandwritingMachineCandidate.self)
            )
        }

        var decodedReviews: [HandwritingCandidateReview] = []
        var reviewValues = try values.nestedUnkeyedContainer(forKey: .reviews)
        if let count = reviewValues.count,
           count > HandwritingRecognitionLimits.maximumCandidateCount {
            throw HandwritingRecognitionValidationError.tooManyReviews
        }
        decodedReviews.reserveCapacity(
            min(
                reviewValues.count ?? 0,
                HandwritingRecognitionLimits.maximumCandidateCount
            )
        )
        while !reviewValues.isAtEnd {
            guard decodedReviews.count
                    < HandwritingRecognitionLimits.maximumCandidateCount else {
                throw HandwritingRecognitionValidationError.tooManyReviews
            }
            decodedReviews.append(
                try reviewValues.decode(HandwritingCandidateReview.self)
            )
        }

        self.init(
            schemaVersion: decodedSchemaVersion,
            runID: try values.decode(UUID.self, forKey: .runID),
            pageID: try values.decode(PageID.self, forKey: .pageID),
            sourceInkSHA256: try values.decode(String.self, forKey: .sourceInkSHA256),
            engineIdentifier: try values.decode(String.self, forKey: .engineIdentifier),
            engineRevision: try values.decode(Int.self, forKey: .engineRevision),
            languages: decodedLanguages,
            generatedAt: try values.decode(Date.self, forKey: .generatedAt),
            revision: try values.decode(Int64.self, forKey: .revision),
            modifiedAt: try values.decode(Date.self, forKey: .modifiedAt),
            machineCandidates: decodedCandidates,
            reviews: decodedReviews
        )
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(runID, forKey: .runID)
        try values.encode(pageID, forKey: .pageID)
        try values.encode(sourceInkSHA256, forKey: .sourceInkSHA256)
        try values.encode(engineIdentifier, forKey: .engineIdentifier)
        try values.encode(engineRevision, forKey: .engineRevision)
        try values.encode(languages, forKey: .languages)
        try values.encode(generatedAt, forKey: .generatedAt)
        try values.encode(revision, forKey: .revision)
        try values.encode(modifiedAt, forKey: .modifiedAt)
        try values.encode(machineCandidates, forKey: .machineCandidates)
        try values.encode(reviews, forKey: .reviews)
    }
}

public enum HandwritingRecognitionValidationError: LocalizedError, Equatable, Sendable {
    case futureSchemaVersion(found: Int, supported: Int)
    case invalidSchemaVersion(Int)
    case pageIdentifierMismatch
    case invalidRevision
    case invalidInkFingerprint
    case invalidEngine
    case invalidLanguages
    case invalidTimestamp
    case tooManyCandidates
    case tooManyReviews
    case duplicateCandidate
    case invalidCandidate
    case invalidCandidateLocale
    case duplicateReview
    case danglingReview
    case invalidReviewTimestamp
    case invalidReview
    case invalidText
    case tooMuchText

    public var errorDescription: String? {
        switch self {
        case .futureSchemaVersion(let found, let supported):
            "Handwriting recognition schema \(found) is newer than supported schema \(supported)."
        case .invalidSchemaVersion(let version):
            "Handwriting recognition schema \(version) is invalid."
        case .pageIdentifierMismatch:
            "The handwriting recognition belongs to another page."
        case .invalidRevision:
            "The handwriting recognition revision is invalid."
        case .invalidInkFingerprint:
            "The handwriting recognition ink fingerprint is invalid."
        case .invalidEngine:
            "The handwriting recognition engine metadata is invalid."
        case .invalidLanguages:
            "The handwriting recognition language list is invalid."
        case .invalidTimestamp:
            "The handwriting recognition timestamp is invalid."
        case .tooManyCandidates:
            "The handwriting recognition contains too many candidates."
        case .tooManyReviews:
            "The handwriting recognition contains too many reviews."
        case .duplicateCandidate:
            "Handwriting candidate identifiers must be unique."
        case .invalidCandidate:
            "A handwriting candidate has invalid confidence or bounds."
        case .invalidCandidateLocale:
            "A handwriting candidate locale is not compatible with the recognition languages."
        case .duplicateReview:
            "A handwriting candidate has more than one review."
        case .danglingReview:
            "A handwriting review references a missing candidate."
        case .invalidReviewTimestamp:
            "A handwriting review timestamp falls outside the document lifetime."
        case .invalidReview:
            "A rejected handwriting review cannot contain corrected text."
        case .invalidText:
            "A handwriting text field is empty or too large."
        case .tooMuchText:
            "The handwriting recognition text exceeds the total size limit."
        }
    }
}
