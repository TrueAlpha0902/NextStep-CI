import Foundation
import NotesCore
import NotesServices
@testable import NotesApp
import XCTest

final class HandwritingSearchBuilderTests: XCTestCase {
    func testOnlyAcceptedSuggestionsBecomeSearchable() throws {
        let accepted = candidate(text: "machine accepted", confidence: 0.82)
        let corrected = candidate(text: "machine original", confidence: 0.61)
        let rejected = candidate(text: "must stay private")
        let pending = candidate(text: "not reviewed")
        let pageID = PageID()
        let document = makeDocument(
            pageID: pageID,
            candidates: [accepted, corrected, rejected, pending],
            reviews: [
                HandwritingCandidateReview(
                    candidateID: accepted.id,
                    decision: .accepted,
                    reviewedAt: reviewDate
                ),
                HandwritingCandidateReview(
                    candidateID: corrected.id,
                    decision: .accepted,
                    correctedText: "human correction",
                    reviewedAt: reviewDate
                ),
                HandwritingCandidateReview(
                    candidateID: rejected.id,
                    decision: .rejected,
                    reviewedAt: reviewDate
                ),
            ]
        )

        let segments = try HandwritingSearchBuilder.segments(
            for: document,
            expectedPageID: pageID
        )

        XCTAssertEqual(segments.map(\.id), [accepted.id, corrected.id])
        XCTAssertEqual(segments.map(\.text), ["machine accepted", "human correction"])
        XCTAssertEqual(segments.map(\.confidence), [0.82, 0.61])
        XCTAssertTrue(segments.allSatisfy { $0.pageID == pageID.rawValue })
        XCTAssertTrue(segments.allSatisfy { $0.source == .handwriting })
        XCTAssertEqual(segments.first?.bounds, NormalizedRect(
            x: 0.1,
            y: 0.2,
            width: 0.3,
            height: 0.1
        ))
        XCTAssertEqual(segments.first?.localeIdentifier, "zh-Hant")
    }

    func testDocumentIdentityIsStableAndSeparatelyNamespaced() {
        let notebookID = UUID()
        let pageID = UUID()
        let documentID = HandwritingSearchBuilder.documentID(
            notebookID: notebookID,
            pageID: pageID
        )

        XCTAssertEqual(documentID, HandwritingSearchBuilder.documentID(
            notebookID: notebookID,
            pageID: pageID
        ))
        XCTAssertNotEqual(documentID, pageID)
        XCTAssertNotEqual(
            documentID,
            CanvasElementSearchBuilder.documentID(
                notebookID: notebookID,
                pageID: pageID
            )
        )
        XCTAssertNotEqual(documentID, HandwritingSearchBuilder.documentID(
            notebookID: UUID(),
            pageID: pageID
        ))
        XCTAssertEqual((documentID.uuid.6 >> 4) & 0x0f, 8)
        XCTAssertEqual((documentID.uuid.8 >> 6) & 0x03, 2)
    }

    func testFingerprintChangesWhenReviewOrInkChanges() throws {
        let pageID = PageID()
        let candidate = candidate(text: "candidate")
        let pending = makeDocument(pageID: pageID, candidates: [candidate])
        var accepted = pending
        accepted.revision += 1
        accepted.reviews = [HandwritingCandidateReview(
            candidateID: candidate.id,
            decision: .accepted,
            reviewedAt: reviewDate
        )]
        var corrected = accepted
        corrected.revision += 1
        corrected.reviews[0].correctedText = "correction"
        let differentInk = copy(
            corrected,
            sourceInkSHA256: String(repeating: "b", count: 64),
            revision: corrected.revision + 1
        )

        let first = try HandwritingSearchBuilder.sourceFingerprint(
            for: pending,
            expectedPageID: pageID
        )
        XCTAssertEqual(first, try HandwritingSearchBuilder.sourceFingerprint(
            for: pending,
            expectedPageID: pageID
        ))
        XCTAssertNotEqual(first, try HandwritingSearchBuilder.sourceFingerprint(
            for: accepted,
            expectedPageID: pageID
        ))
        XCTAssertNotEqual(
            try HandwritingSearchBuilder.sourceFingerprint(
                for: accepted,
                expectedPageID: pageID
            ),
            try HandwritingSearchBuilder.sourceFingerprint(
                for: corrected,
                expectedPageID: pageID
            )
        )
        XCTAssertNotEqual(
            try HandwritingSearchBuilder.sourceFingerprint(
                for: corrected,
                expectedPageID: pageID
            ),
            try HandwritingSearchBuilder.sourceFingerprint(
                for: differentInk,
                expectedPageID: pageID
            )
        )
    }

    func testPageIdentityMismatchIsRejectedBeforeIndexing() {
        let document = makeDocument(pageID: PageID(), candidates: [])

        XCTAssertThrowsError(try HandwritingSearchBuilder.segments(
            for: document,
            expectedPageID: PageID()
        )) { error in
            XCTAssertEqual(
                error as? HandwritingRecognitionValidationError,
                .pageIdentifierMismatch
            )
        }
    }

    private func candidate(
        text: String,
        confidence: Double = 0.9
    ) -> HandwritingMachineCandidate {
        HandwritingMachineCandidate(
            machineText: text,
            machineConfidence: confidence,
            normalizedPageBounds: HandwritingNormalizedBounds(
                x: 0.1,
                y: 0.2,
                width: 0.3,
                height: 0.1
            ),
            localeIdentifier: "zh-Hant"
        )
    }

    private func makeDocument(
        pageID: PageID,
        candidates: [HandwritingMachineCandidate],
        reviews: [HandwritingCandidateReview] = []
    ) -> HandwritingRecognitionDocument {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        return HandwritingRecognitionDocument(
            pageID: pageID,
            sourceInkSHA256: String(repeating: "a", count: 64),
            engineIdentifier: "com.apple.vision.text-recognition",
            engineRevision: 1,
            languages: ["zh-Hant", "en-US"],
            generatedAt: timestamp,
            modifiedAt: reviewDate,
            machineCandidates: candidates,
            reviews: reviews
        )
    }

    private var reviewDate: Date {
        Date(timeIntervalSince1970: 1_800_000_060)
    }

    private func copy(
        _ document: HandwritingRecognitionDocument,
        sourceInkSHA256: String? = nil,
        revision: Int64? = nil
    ) -> HandwritingRecognitionDocument {
        HandwritingRecognitionDocument(
            schemaVersion: document.schemaVersion,
            runID: document.runID,
            pageID: document.pageID,
            sourceInkSHA256: sourceInkSHA256 ?? document.sourceInkSHA256,
            engineIdentifier: document.engineIdentifier,
            engineRevision: document.engineRevision,
            languages: document.languages,
            generatedAt: document.generatedAt,
            revision: revision ?? document.revision,
            modifiedAt: document.modifiedAt,
            machineCandidates: document.machineCandidates,
            reviews: document.reviews
        )
    }
}
