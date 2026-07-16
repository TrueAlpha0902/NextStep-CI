import Foundation
@testable import NotesCore
import XCTest

final class HandwritingRecognitionModelsTests: XCTestCase {
    func testAcceptedTextKeepsMachineSuggestionSeparateFromCorrection() throws {
        let first = candidate(text: "Machine original")
        let second = candidate(text: "Reject me")
        let pending = candidate(text: "Pending")
        let document = makeDocument(
            candidates: [first, second, pending],
            reviews: [
                HandwritingCandidateReview(
                    candidateID: first.id,
                    decision: .accepted,
                    correctedText: "Human correction",
                    reviewedAt: reviewDate
                ),
                HandwritingCandidateReview(
                    candidateID: second.id,
                    decision: .rejected,
                    reviewedAt: reviewDate
                ),
            ]
        )

        try document.validate()

        XCTAssertEqual(document.machineCandidates.first?.machineText, "Machine original")
        XCTAssertEqual(document.acceptedText.map(\.id), [first.id])
        XCTAssertEqual(document.acceptedText.map(\.text), ["Human correction"])
    }

    func testAcceptedUnchangedSuggestionUsesMachineText() throws {
        let candidate = candidate(text: "Accepted unchanged")
        let document = makeDocument(
            candidates: [candidate],
            reviews: [HandwritingCandidateReview(
                candidateID: candidate.id,
                decision: .accepted,
                reviewedAt: reviewDate
            )]
        )

        try document.validate()

        XCTAssertEqual(document.acceptedText.map(\.text), ["Accepted unchanged"])
    }

    func testValidationRejectsDuplicateAndDanglingReviews() {
        let candidate = candidate(text: "Candidate")
        let duplicate = makeDocument(
            candidates: [candidate],
            reviews: [
                HandwritingCandidateReview(
                    candidateID: candidate.id,
                    decision: .accepted,
                    reviewedAt: reviewDate
                ),
                HandwritingCandidateReview(
                    candidateID: candidate.id,
                    decision: .rejected,
                    reviewedAt: reviewDate
                ),
            ]
        )
        XCTAssertThrowsError(try duplicate.validate()) { error in
            XCTAssertEqual(
                error as? HandwritingRecognitionValidationError,
                .duplicateReview
            )
        }
        XCTAssertTrue(duplicate.acceptedText.isEmpty)

        let dangling = makeDocument(
            candidates: [candidate],
            reviews: [HandwritingCandidateReview(
                candidateID: UUID(),
                decision: .accepted,
                reviewedAt: reviewDate
            )]
        )
        XCTAssertThrowsError(try dangling.validate()) { error in
            XCTAssertEqual(
                error as? HandwritingRecognitionValidationError,
                .danglingReview
            )
        }
    }

    func testValidationRejectsInvalidBoundsConfidenceAndHash() {
        let invalidBounds = makeDocument(candidates: [HandwritingMachineCandidate(
            machineText: "Bounds",
            machineConfidence: 0.9,
            normalizedPageBounds: HandwritingNormalizedBounds(
                x: 0.8,
                y: 0.2,
                width: 0.3,
                height: 0.1
            )
        )])
        XCTAssertThrowsError(try invalidBounds.validate()) { error in
            XCTAssertEqual(
                error as? HandwritingRecognitionValidationError,
                .invalidCandidate
            )
        }

        let invalidConfidence = makeDocument(candidates: [HandwritingMachineCandidate(
            machineText: "Confidence",
            machineConfidence: .nan,
            normalizedPageBounds: bounds
        )])
        XCTAssertThrowsError(try invalidConfidence.validate())

        let invalidHash = makeDocument(
            sourceInkSHA256: String(repeating: "A", count: 64),
            candidates: []
        )
        XCTAssertThrowsError(try invalidHash.validate()) { error in
            XCTAssertEqual(
                error as? HandwritingRecognitionValidationError,
                .invalidInkFingerprint
            )
        }
    }

    func testFutureSchemaIsDistinguishedAndPageIdentityIsFenced() {
        let document = makeDocument(
            schemaVersion: HandwritingRecognitionDocument.currentSchemaVersion + 1,
            candidates: []
        )
        XCTAssertThrowsError(try document.validate()) { error in
            XCTAssertEqual(
                error as? HandwritingRecognitionValidationError,
                .futureSchemaVersion(found: 2, supported: 1)
            )
        }

        let current = makeDocument(candidates: [])
        XCTAssertThrowsError(try current.validate(expectedPageID: PageID())) { error in
            XCTAssertEqual(
                error as? HandwritingRecognitionValidationError,
                .pageIdentifierMismatch
            )
        }
    }

    func testDocumentRoundTripsWithoutMergingMachineAndUserText() throws {
        let candidate = candidate(text: "Machine")
        let original = makeDocument(
            candidates: [candidate],
            reviews: [HandwritingCandidateReview(
                candidateID: candidate.id,
                decision: .accepted,
                correctedText: "Correction",
                reviewedAt: reviewDate
            )]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(
            HandwritingRecognitionDocument.self,
            from: encoder.encode(original)
        )

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.machineCandidates[0].machineText, "Machine")
        XCTAssertEqual(decoded.reviews[0].correctedText, "Correction")
    }

    func testCodableRejectsFutureAndInvalidSchemaBeforeContent() throws {
        let original = makeDocument(candidates: [])
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        object["schemaVersion"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(
            HandwritingRecognitionDocument.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )) { error in
            XCTAssertEqual(
                error as? HandwritingRecognitionValidationError,
                .futureSchemaVersion(found: 2, supported: 1)
            )
        }

        object["schemaVersion"] = 0
        XCTAssertThrowsError(try JSONDecoder().decode(
            HandwritingRecognitionDocument.self,
            from: try JSONSerialization.data(withJSONObject: object)
        )) { error in
            XCTAssertEqual(
                error as? HandwritingRecognitionValidationError,
                .invalidSchemaVersion(0)
            )
        }
    }

    func testValidationRejectsZeroAreaBoundsAndOutOfLifetimeReview() {
        let zeroArea = makeDocument(candidates: [HandwritingMachineCandidate(
            machineText: "No area",
            machineConfidence: 0.9,
            normalizedPageBounds: HandwritingNormalizedBounds(
                x: 0.1,
                y: 0.1,
                width: 0,
                height: 0.2
            )
        )])
        XCTAssertThrowsError(try zeroArea.validate()) { error in
            XCTAssertEqual(
                error as? HandwritingRecognitionValidationError,
                .invalidCandidate
            )
        }

        let candidate = candidate(text: "Review date")
        let tooEarly = makeDocument(
            candidates: [candidate],
            reviews: [HandwritingCandidateReview(
                candidateID: candidate.id,
                decision: .accepted,
                reviewedAt: generatedDate.addingTimeInterval(-1)
            )]
        )
        XCTAssertThrowsError(try tooEarly.validate()) { error in
            XCTAssertEqual(
                error as? HandwritingRecognitionValidationError,
                .invalidReviewTimestamp
            )
        }
    }

    func testValidationFencesLanguageSemanticsAndTextControls() {
        let candidate = HandwritingMachineCandidate(
            machineText: "French",
            machineConfidence: 0.9,
            normalizedPageBounds: bounds,
            localeIdentifier: "fr-FR"
        )
        let incompatibleLocale = makeDocument(candidates: [candidate])
        XCTAssertThrowsError(try incompatibleLocale.validate()) { error in
            XCTAssertEqual(
                error as? HandwritingRecognitionValidationError,
                .invalidCandidateLocale
            )
        }

        let controlText = makeDocument(candidates: [HandwritingMachineCandidate(
            machineText: "unsafe\u{0000}text",
            machineConfidence: 0.9,
            normalizedPageBounds: bounds,
            localeIdentifier: "en"
        )])
        XCTAssertThrowsError(try controlText.validate()) { error in
            XCTAssertEqual(
                error as? HandwritingRecognitionValidationError,
                .invalidText
            )
        }
    }

    func testValidationEnforcesCandidateAndAggregateTextCaps() {
        let sample = candidate(text: "bounded")
        let tooMany = makeDocument(candidates: Array(
            repeating: sample,
            count: HandwritingRecognitionLimits.maximumCandidateCount + 1
        ))
        XCTAssertThrowsError(try tooMany.validate()) { error in
            XCTAssertEqual(
                error as? HandwritingRecognitionValidationError,
                .tooManyCandidates
            )
        }

        let field = String(
            repeating: "x",
            count: HandwritingRecognitionLimits.maximumUTF8BytesPerTextField
        )
        let aggregate = (0 ... (
            HandwritingRecognitionLimits.maximumTotalTextUTF8Bytes
                / HandwritingRecognitionLimits.maximumUTF8BytesPerTextField
        )).map { offset in
            HandwritingMachineCandidate(
                id: UUID(uuidString: String(
                    format: "00000000-0000-4000-8000-%012llx",
                    UInt64(offset)
                ))!,
                machineText: field,
                machineConfidence: 0.9,
                normalizedPageBounds: bounds,
                localeIdentifier: "en-US"
            )
        }
        let tooMuchText = makeDocument(candidates: aggregate)
        XCTAssertThrowsError(try tooMuchText.validate()) { error in
            XCTAssertEqual(
                error as? HandwritingRecognitionValidationError,
                .tooMuchText
            )
        }
    }

    private let bounds = HandwritingNormalizedBounds(
        x: 0.1,
        y: 0.2,
        width: 0.3,
        height: 0.1
    )

    private var generatedDate: Date {
        Date(timeIntervalSince1970: 1_800_000_000)
    }

    private var reviewDate: Date {
        generatedDate.addingTimeInterval(60)
    }

    private func candidate(text: String) -> HandwritingMachineCandidate {
        HandwritingMachineCandidate(
            machineText: text,
            machineConfidence: 0.85,
            normalizedPageBounds: bounds,
            localeIdentifier: "en-US"
        )
    }

    private func makeDocument(
        schemaVersion: Int = HandwritingRecognitionDocument.currentSchemaVersion,
        sourceInkSHA256: String = String(repeating: "a", count: 64),
        candidates: [HandwritingMachineCandidate],
        reviews: [HandwritingCandidateReview] = []
    ) -> HandwritingRecognitionDocument {
        return HandwritingRecognitionDocument(
            schemaVersion: schemaVersion,
            pageID: PageID(),
            sourceInkSHA256: sourceInkSHA256,
            engineIdentifier: "com.apple.vision.text-recognition",
            engineRevision: 1,
            languages: ["zh-Hant", "en-US"],
            generatedAt: generatedDate,
            modifiedAt: reviewDate,
            machineCandidates: candidates,
            reviews: reviews
        )
    }
}
