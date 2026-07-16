import Foundation
import NotesCore
import XCTest
@testable import NotesApp

final class NotebookAudioTranscriptSearchTests: XCTestCase {
    func testSearchTrimsAndFoldsCaseAndDiacriticsInTimelineOrder() throws {
        let first = segment(text: "CAF\u{00C9} planning", startTime: 1)
        let ignored = segment(text: "Unrelated", startTime: 2)
        let third = segment(text: "Cafe\u{301} follow-up", startTime: 3)
        let transcript = makeTranscript(segments: [first, ignored, third])

        let result = try NotebookAudioTranscriptSearch.search(
            "  cAfE\n",
            in: transcript
        )

        XCTAssertEqual(result.query, "cAfE")
        XCTAssertEqual(result.matches.map(\.id), [first.id, third.id])
        XCTAssertEqual(result.matches.map(\.startTime), [1, 3])
        XCTAssertFalse(result.queryWasTruncated)
        XCTAssertFalse(result.resultsWereTruncated)
    }

    func testQueryIsBoundedByUTF8WithoutSplittingGraphemeClusters() throws {
        let bytesPerCharacter = String("\u{00E9}").utf8.count
        XCTAssertEqual(
            NotebookAudioTranscriptSearch.maximumQueryUTF8Bytes % bytesPerCharacter,
            0
        )
        let retainedCharacterCount =
            NotebookAudioTranscriptSearch.maximumQueryUTF8Bytes / bytesPerCharacter
        let retainedQuery = String(repeating: "\u{00E9}", count: retainedCharacterCount)
        let oversizedQuery = retainedQuery + "\u{00E9}"
        let matching = segment(text: "prefix \(retainedQuery) suffix", startTime: 0)

        let result = try NotebookAudioTranscriptSearch.search(
            oversizedQuery,
            in: makeTranscript(segments: [matching])
        )

        XCTAssertEqual(result.query, retainedQuery)
        XCTAssertEqual(result.query.utf8.count, NotebookAudioTranscriptSearch.maximumQueryUTF8Bytes)
        XCTAssertTrue(result.queryWasTruncated)
        XCTAssertEqual(result.matches.map(\.id), [matching.id])
    }

    func testResultsStopAtHardLimitAndReportAdditionalMatches() throws {
        let segments = (0 ... NotebookAudioTranscriptSearch.maximumResults).map { index in
            segment(text: "needle \(index)", startTime: TimeInterval(index))
        }

        let result = try NotebookAudioTranscriptSearch.search(
            "needle",
            in: makeTranscript(segments: segments)
        )

        XCTAssertEqual(result.matches.count, NotebookAudioTranscriptSearch.maximumResults)
        XCTAssertEqual(result.matches.first?.startTime, 0)
        XCTAssertEqual(
            result.matches.last?.startTime,
            TimeInterval(NotebookAudioTranscriptSearch.maximumResults - 1)
        )
        XCTAssertTrue(result.resultsWereTruncated)
    }

    func testExactlyMaximumResultsDoesNotReportTruncation() throws {
        let segments = (0 ..< NotebookAudioTranscriptSearch.maximumResults).map { index in
            segment(text: "match", startTime: TimeInterval(index))
        }

        let result = try NotebookAudioTranscriptSearch.search(
            "MATCH",
            in: makeTranscript(segments: segments)
        )

        XCTAssertEqual(result.matches.count, NotebookAudioTranscriptSearch.maximumResults)
        XCTAssertFalse(result.resultsWereTruncated)
    }

    func testWhitespaceOnlyQueryPublishesNoMatches() throws {
        let result = try NotebookAudioTranscriptSearch.search(
            " \n\t ",
            in: makeTranscript(segments: [segment(text: "anything", startTime: 0)])
        )

        XCTAssertEqual(result.query, "")
        XCTAssertTrue(result.isEmpty)
        XCTAssertFalse(result.queryWasTruncated)
        XCTAssertFalse(result.resultsWereTruncated)
    }

    func testSearchAndResultTypesAreSendable() {
        assertSendable(NotebookAudioTranscriptSearchResult.self)
    }
}

private func makeTranscript(
    segments: [AudioTranscriptSegment]
) -> AudioTranscriptDocument {
    AudioTranscriptDocument(
        audioSessionID: AudioSessionID(),
        localeIdentifier: "en-US",
        provenance: .speechTranscriber,
        generatedAt: Date(timeIntervalSince1970: 1),
        segments: segments
    )
}

private func segment(
    text: String,
    startTime: TimeInterval
) -> AudioTranscriptSegment {
    AudioTranscriptSegment(
        text: text,
        startTime: startTime,
        duration: 0.25,
        confidence: 1
    )
}

private func assertSendable<T: Sendable>(_: T.Type) {}
