import CryptoKit
import Foundation
import NextStepDomain

public struct DateCandidateExtractor: Sendable {
    public static let parserIdentifier = "nextstep.deterministic-date"
    public static let parserVersion = "1"

    public init() {}

    public func extract(
        requestID: UUID,
        sourceDocument: SourceDocument,
        pages: [DocumentPage],
        languages: [String]
    ) throws -> DocumentParseResult {
        guard let sourceSHA256 = sourceDocument.contentSHA256,
              sourceSHA256.isGroundingLowercaseSHA256,
              sourceDocument.metadata.deletedAt == nil,
              sourceDocument.verificationState == .contentHashVerified else {
            throw GroundingReviewError.sourceNotVerified
        }

        var candidates: [DocumentFactCandidate] = []
        var warnings: [String] = []
        var candidateIDs = Set<UUID>()
        var omittedWarnings = false
        var candidatesWereTruncated = false

        func appendWarning(_ warning: String) {
            if warnings.count < 99 {
                warnings.append(warning)
            } else {
                omittedWarnings = true
            }
        }

        extraction: for page in pages.sorted(by: { $0.pageIndex < $1.pageIndex }) {
            for block in page.blocks {
                let scan = try GroundedDateScanner.scan(block.text)
                for warning in scan.warnings {
                    appendWarning("Page \(page.pageIndex + 1): \(warning)")
                }

                for match in scan.matches {
                    let kind = Self.kind(
                        for: block.text,
                        matchRange: match.utf16Range
                    )
                    let candidateID = StableGroundingID.make(
                        [
                            sourceSHA256.lowercased(),
                            block.anchorID.description,
                            kind.rawValue,
                            match.day.description,
                            String(match.utf16Range.location),
                            String(match.utf16Range.length)
                        ]
                    )
                    guard candidateIDs.insert(candidateID).inserted else { continue }
                    guard candidates.count < 5_000 else {
                        candidatesWereTruncated = true
                        break extraction
                    }
                    let confidence = min(max(block.confidence ?? 0.5, 0), 0.99)
                    candidates.append(try DocumentFactCandidate(
                        candidateID: candidateID,
                        kind: kind,
                        value: match.originalText,
                        anchorIDs: [block.anchorID],
                        occurrences: [try DocumentFactOccurrence(
                            anchorID: block.anchorID,
                            utf16Start: match.utf16Range.location,
                            utf16Length: match.utf16Range.length
                        )],
                        confidence: confidence,
                        requiresUserConfirmation: true
                    ))
                }
            }
        }

        if candidatesWereTruncated {
            appendWarning("Additional date candidates were omitted after the 5,000 item limit.")
        }
        if omittedWarnings {
            if warnings.count == 100 {
                warnings[99] = "Additional parser warnings were omitted."
            } else {
                warnings.append("Additional parser warnings were omitted.")
            }
        }
        return try DocumentParseResult(
            requestID: requestID,
            sourceDocumentID: sourceDocument.metadata.id,
            sourceSHA256: sourceSHA256,
            status: warnings.isEmpty ? .complete : .partial,
            parser: DocumentParserDescriptor(
                identifier: Self.parserIdentifier,
                version: Self.parserVersion,
                executedOnDevice: true
            ),
            languages: languages,
            pages: pages,
            factCandidates: candidates,
            warnings: warnings
        )
    }

    private static func kind(
        for text: String,
        matchRange: NSRange
    ) -> DocumentFactKind {
        let folded = leadingContext(for: matchRange, in: text).folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let deadlineKeywords = [
            "deadline", "due", "submit", "submission", "截止", "繳交", "提交", "到期"
        ]
        return deadlineKeywords.contains(where: { folded.contains($0) }) ? .deadline : .date
    }

    private static func leadingContext(for matchRange: NSRange, in text: String) -> String {
        let utf16Text = text as NSString
        guard matchRange.location >= 0,
              NSMaxRange(matchRange) <= utf16Text.length else { return text }
        let delimiters = CharacterSet(charactersIn: ".;。；,，\n\r")
        let leadingSearch = NSRange(location: 0, length: matchRange.location)
        let leadingDelimiter = utf16Text.rangeOfCharacter(
            from: delimiters,
            options: .backwards,
            range: leadingSearch
        )
        var start = leadingDelimiter.location == NSNotFound
            ? 0
            : NSMaxRange(leadingDelimiter)
        let conjunctions = [" and ", " but ", "以及", "但是", "但", "且"]
        let prefixRange = NSRange(location: start, length: matchRange.location - start)
        for conjunction in conjunctions {
            let found = utf16Text.range(
                of: conjunction,
                options: [.caseInsensitive, .backwards],
                range: prefixRange
            )
            if found.location != NSNotFound {
                start = max(start, NSMaxRange(found))
            }
        }
        start = max(start, matchRange.location - 96)
        return utf16Text.substring(with: NSRange(
            location: start,
            length: NSMaxRange(matchRange) - start
        ))
    }
}

struct GroundedDateMatch: Hashable, Sendable {
    let day: LocalDay
    let originalText: String
    let utf16Range: NSRange
}

enum GroundedDateScanner {
    private static let fullPatterns = [
        #"(?<![\d/-])([12]\d{3})[-/](\d{1,2})[-/](\d{1,2})(?![\d/-])"#,
        #"(?<![\d/-])([12]\d{3})\s*年\s*(\d{1,2})\s*月\s*(\d{1,2})\s*日(?![\d/-])"#
    ]
    private static let ambiguousPatterns = [
        #"(?<![\d/-])(\d{1,2})[/-](\d{1,2})(?![\d/-])"#,
        #"(?<![\d/-])(\d{1,2})\s*月\s*(\d{1,2})\s*日(?![\d/-])"#
    ]

    static func scan(_ text: String) throws -> (matches: [GroundedDateMatch], warnings: [String]) {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var matches: [GroundedDateMatch] = []
        var warnings: [String] = []
        var occupiedRanges: [NSRange] = []

        for pattern in fullPatterns {
            let expression = try NSRegularExpression(pattern: pattern)
            for result in expression.matches(in: text, range: fullRange) {
                occupiedRanges.append(result.range)
                guard result.numberOfRanges == 4,
                      let year = integer(in: text, range: result.range(at: 1)),
                      let month = integer(in: text, range: result.range(at: 2)),
                      let day = integer(in: text, range: result.range(at: 3)),
                      let originalRange = Range(result.range, in: text) else {
                    continue
                }
                let original = String(text[originalRange])
                do {
                    matches.append(GroundedDateMatch(
                        day: try LocalDay(year: year, month: month, day: day),
                        originalText: original,
                        utf16Range: result.range
                    ))
                } catch {
                    warnings.append("Invalid calendar date was not proposed: \(original)")
                }
            }
        }

        for pattern in ambiguousPatterns {
            let expression = try NSRegularExpression(pattern: pattern)
            for result in expression.matches(in: text, range: fullRange) {
                guard occupiedRanges.contains(where: { NSIntersectionRange($0, result.range).length > 0 })
                        == false,
                      let range = Range(result.range, in: text) else {
                    continue
                }
                warnings.append(
                    "Ambiguous date without a year requires manual entry: \(text[range])"
                )
            }
        }

        matches.sort {
            if $0.utf16Range.location != $1.utf16Range.location {
                return $0.utf16Range.location < $1.utf16Range.location
            }
            return $0.day < $1.day
        }
        return (matches, warnings)
    }

    static func parseExact(_ value: String) throws -> LocalDay {
        let scan = try scan(value)
        guard scan.matches.count == 1,
              scan.warnings.isEmpty,
              scan.matches[0].utf16Range == NSRange(value.startIndex..<value.endIndex, in: value) else {
            throw GroundingReviewError.invalidDateCandidate
        }
        return scan.matches[0].day
    }

    private static func integer(in text: String, range: NSRange) -> Int? {
        guard let swiftRange = Range(range, in: text) else { return nil }
        return Int(text[swiftRange])
    }
}

enum StableGroundingID {
    static func make(_ components: [String]) -> UUID {
        let digest = Array(SHA256.hash(data: Data(components.joined(separator: "\u{1f}").utf8)))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

extension String {
    var isGroundingLowercaseSHA256: Bool {
        count == 64 && unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }
}
