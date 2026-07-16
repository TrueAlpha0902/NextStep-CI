import Foundation
import NotesCore
import NotesServices
@testable import NotesApp
import XCTest

final class HandwritingRecognitionPipelineTests: XCTestCase {
    @MainActor
    func testEmptyMachineOutputDoesNotCreateAnEmptySidecar() {
        XCTAssertThrowsError(try HandwritingRecognitionPipeline.makeDocument(
            segments: [],
            pageID: PageID(),
            sourceInkSHA256: String(repeating: "a", count: 64),
            languages: ["en-US"]
        )) { error in
            XCTAssertEqual(error as? TextRecognitionError, .noResults)
        }
    }

    @MainActor
    func testVisionBoundsBecomeUpperLeftReviewBounds() throws {
        let pageID = PageID()
        let segmentID = UUID()
        let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let document = try HandwritingRecognitionPipeline.makeDocument(
            segments: [RecognizedTextSegment(
                id: segmentID,
                text: "  手寫建議  ",
                confidence: 0.75,
                bounds: NormalizedRect(x: 0.1, y: 0.65, width: 0.3, height: 0.2),
                pageID: pageID.rawValue,
                source: .scannedImage,
                localeIdentifier: "zh-Hant"
            )],
            pageID: pageID,
            sourceInkSHA256: String(repeating: "a", count: 64),
            languages: ["zh-Hant", "en-US", "ZH-hant"],
            generatedAt: generatedAt,
            runID: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        )

        XCTAssertEqual(document.pageID, pageID)
        XCTAssertEqual(document.languages, ["zh-Hant", "en-US"])
        XCTAssertEqual(document.generatedAt, generatedAt)
        XCTAssertTrue(document.reviews.isEmpty)
        XCTAssertTrue(document.acceptedText.isEmpty)
        XCTAssertEqual(document.machineCandidates.first?.id, segmentID)
        XCTAssertEqual(document.machineCandidates.first?.machineText, "  手寫建議  ")
        let bounds = try XCTUnwrap(
            document.machineCandidates.first?.normalizedPageBounds
        )
        XCTAssertEqual(bounds.x, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(bounds.y, 0.15, accuracy: 0.000_001)
        XCTAssertEqual(bounds.width, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(bounds.height, 0.2, accuracy: 0.000_001)
    }

    @MainActor
    func testInvalidSourcePageAndDuplicateCandidateAreRejected() {
        let pageID = PageID()
        let id = UUID()
        let valid = RecognizedTextSegment(
            id: id,
            text: "candidate",
            confidence: 0.9,
            bounds: NormalizedRect(x: 0, y: 0, width: 0.2, height: 0.2),
            pageID: pageID.rawValue,
            source: .scannedImage
        )
        assertInvalid([RecognizedTextSegment(
            id: UUID(),
            text: "typed",
            bounds: valid.bounds,
            pageID: pageID.rawValue,
            source: .typedText
        )], pageID: pageID)
        assertInvalid([RecognizedTextSegment(
            id: UUID(),
            text: "wrong page",
            bounds: valid.bounds,
            pageID: UUID(),
            source: .scannedImage
        )], pageID: pageID)
        assertInvalid([valid, valid], pageID: pageID)
    }

    @MainActor
    func testBoundsAreClippedAndZeroAreaIsRejected() throws {
        let pageID = PageID()
        let clipped = try HandwritingRecognitionPipeline.makeDocument(
            segments: [RecognizedTextSegment(
                text: "edge",
                confidence: 1,
                bounds: NormalizedRect(x: 0.9, y: 0.8, width: 0.4, height: 0.4),
                pageID: pageID.rawValue,
                source: .scannedImage
            )],
            pageID: pageID,
            sourceInkSHA256: String(repeating: "b", count: 64),
            languages: ["en-US"]
        )
        let bounds = clipped.machineCandidates[0].normalizedPageBounds
        XCTAssertEqual(bounds.x, 0.9, accuracy: 0.000_001)
        XCTAssertEqual(bounds.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(bounds.width, 0.1, accuracy: 0.000_001)
        XCTAssertEqual(bounds.height, 0.2, accuracy: 0.000_001)

        assertInvalid([RecognizedTextSegment(
            text: "zero",
            bounds: NormalizedRect(x: 1, y: 0.5, width: 0.2, height: 0.1),
            pageID: pageID.rawValue,
            source: .scannedImage
        )], pageID: pageID)
    }

    @MainActor
    private func assertInvalid(
        _ segments: [RecognizedTextSegment],
        pageID: PageID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try HandwritingRecognitionPipeline.makeDocument(
            segments: segments,
            pageID: pageID,
            sourceInkSHA256: String(repeating: "c", count: 64),
            languages: ["en-US"]
        ), file: file, line: line) { error in
            XCTAssertEqual(
                error as? HandwritingRecognitionPipelineError,
                .invalidRecognitionResult,
                file: file,
                line: line
            )
        }
    }
}
