import Foundation
import NotesCore

/// A bounded, presentation-ready result for searching one durable transcript.
/// Matches retain the transcript's canonical timeline order; they are never
/// relevance-sorted, so previous/next navigation follows recording time.
struct NotebookAudioTranscriptSearchResult: Equatable, Sendable {
    let query: String
    let matches: [AudioTranscriptSegment]
    let queryWasTruncated: Bool
    let resultsWereTruncated: Bool

    var isEmpty: Bool { matches.isEmpty }
}

/// Pure transcript search used by the audio panel. Durable transcripts are
/// already bounded and stored in deterministic timeline order by NotesCore.
/// This additional boundary keeps arbitrary UI input and published results
/// small even when the caller supplies a programmatically constructed value.
enum NotebookAudioTranscriptSearch {
    static let maximumQueryUTF8Bytes = 4 * 1_024
    static let maximumResults = 500

    /// Searches individual transcript segments using deterministic Unicode
    /// folding. The method is synchronous so callers can choose their own
    /// isolation (normally a non-main task), but it cooperatively observes task
    /// cancellation while scanning a large transcript.
    static func search(
        _ rawQuery: String,
        in transcript: AudioTranscriptDocument
    ) throws -> NotebookAudioTranscriptSearchResult {
        try Task.checkCancellation()

        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = boundedUTF8Prefix(
            of: trimmed,
            maximumByteCount: maximumQueryUTF8Bytes
        )
        let query = bounded.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return NotebookAudioTranscriptSearchResult(
                query: "",
                matches: [],
                queryWasTruncated: bounded.wasTruncated,
                resultsWereTruncated: false
            )
        }

        let foldedQuery = folded(query)
        guard !foldedQuery.isEmpty else {
            return NotebookAudioTranscriptSearchResult(
                query: query,
                matches: [],
                queryWasTruncated: bounded.wasTruncated,
                resultsWereTruncated: false
            )
        }

        var matches: [AudioTranscriptSegment] = []
        matches.reserveCapacity(min(maximumResults, transcript.segments.count))
        var resultsWereTruncated = false

        for (index, segment) in transcript.segments.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            guard folded(segment.text).contains(foldedQuery) else { continue }
            guard matches.count < maximumResults else {
                resultsWereTruncated = true
                break
            }
            matches.append(segment)
        }

        try Task.checkCancellation()
        return NotebookAudioTranscriptSearchResult(
            query: query,
            matches: matches,
            queryWasTruncated: bounded.wasTruncated,
            resultsWereTruncated: resultsWereTruncated
        )
    }

    private static func folded(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    /// Builds the largest Character-aligned prefix that fits the UTF-8 budget.
    /// Iterating Characters prevents a limit from publishing malformed Unicode
    /// or half of an extended grapheme cluster.
    private static func boundedUTF8Prefix(
        of value: String,
        maximumByteCount: Int
    ) -> (value: String, wasTruncated: Bool) {
        guard value.utf8.count > maximumByteCount else {
            return (value, false)
        }

        var result = String()
        result.reserveCapacity(min(value.count, maximumByteCount))
        var byteCount = 0
        for character in value {
            let characterString = String(character)
            let characterByteCount = characterString.utf8.count
            guard characterByteCount <= maximumByteCount - byteCount else { break }
            result.append(character)
            byteCount += characterByteCount
        }
        return (result, true)
    }
}
