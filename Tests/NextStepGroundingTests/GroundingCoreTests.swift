import CryptoKit
import Foundation
import NextStepDomain
@testable import NextStepGrounding
import XCTest

final class GroundingCoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_782_835_200)
    private let deviceID = DeviceID(
        UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    )
    private let sourceID = SourceDocumentID(
        UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    )
    private let firstAnchorID = SourceAnchorID(
        UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
    )
    private let secondAnchorID = SourceAnchorID(
        UUID(uuidString: "00000000-0000-0000-0000-000000000021")!
    )

    func testExtractorUsesDeterministicCandidateIDsOrderAndExactAnchors() throws {
        let source = try makeSource()
        let pageOne = try DocumentPage(
            pageIndex: 1,
            widthPoints: 612,
            heightPoints: 792,
            blocks: [try block(
                id: "00000000-0000-0000-0000-000000000102",
                text: "Assignment deadline: 2027年5月1日",
                anchorID: secondAnchorID,
                confidence: 0.93
            )]
        )
        let pageZero = try DocumentPage(
            pageIndex: 0,
            widthPoints: 612,
            heightPoints: 792,
            blocks: [try block(
                id: "00000000-0000-0000-0000-000000000101",
                text: "Final exam: 2027-06-30",
                anchorID: firstAnchorID,
                confidence: nil
            )]
        )

        let first = try DateCandidateExtractor().extract(
            requestID: UUID(),
            sourceDocument: source,
            pages: [pageOne, pageZero],
            languages: ["en", "zh-Hant"]
        )
        let second = try DateCandidateExtractor().extract(
            requestID: UUID(),
            sourceDocument: source,
            pages: [pageZero, pageOne],
            languages: ["en", "zh-Hant"]
        )

        XCTAssertEqual(first.pages.map(\.pageIndex), [0, 1])
        XCTAssertEqual(first.factCandidates, second.factCandidates)
        XCTAssertEqual(first.factCandidates.map(\.anchorIDs), [[firstAnchorID], [secondAnchorID]])
        XCTAssertEqual(first.factCandidates.map(\.value), ["2027-06-30", "2027年5月1日"])
        XCTAssertEqual(first.factCandidates.map(\.kind), [.date, .deadline])
        XCTAssertEqual(first.factCandidates.map(\.confidence), [0.5, 0.93])
        XCTAssertEqual(first.factCandidates[0].occurrences, [try DocumentFactOccurrence(
            anchorID: firstAnchorID,
            utf16Start: 12,
            utf16Length: 10
        )])
        XCTAssertTrue(first.factCandidates.allSatisfy { $0.requiresUserConfirmation })
        XCTAssertEqual(first.status, .complete)

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(first))
        let root = try XCTUnwrap(encoded as? [String: Any])
        let pages = try XCTUnwrap(root["pages"] as? [[String: Any]])
        let blocks = try XCTUnwrap(pages.first?["blocks"] as? [[String: Any]])
        XCTAssertTrue(blocks.first?.keys.contains("confidence") == true)
        XCTAssertTrue(blocks.first?["confidence"] is NSNull)
    }

    func testExtractorRejectsAmbiguousAndImpossibleDates() throws {
        let page = try DocumentPage(
            pageIndex: 0,
            widthPoints: 612,
            heightPoints: 792,
            blocks: [try block(
                id: "00000000-0000-0000-0000-000000000103",
                text: "Exam 7/15; impossible deadline 2026-02-30.",
                anchorID: firstAnchorID,
                confidence: 0.99
            )]
        )
        let result = try DateCandidateExtractor().extract(
            requestID: UUID(),
            sourceDocument: makeSource(),
            pages: [page],
            languages: ["en"]
        )

        XCTAssertTrue(result.factCandidates.isEmpty)
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.warnings.count, 2)
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("7/15") }))
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("2026-02-30") }))
    }

    func testExtractorClassifiesEachOccurrenceAndPreservesDuplicateDates() throws {
        let page = try DocumentPage(
            pageIndex: 0,
            widthPoints: 612,
            heightPoints: 792,
            blocks: [try block(
                id: "00000000-0000-0000-0000-000000000105",
                text: "Deadline 2027-05-01; semester begins 2027-05-01.",
                anchorID: firstAnchorID,
                confidence: 0.91
            )]
        )
        let result = try DateCandidateExtractor().extract(
            requestID: UUID(),
            sourceDocument: makeSource(),
            pages: [page],
            languages: ["en"]
        )

        XCTAssertEqual(result.factCandidates.count, 2)
        XCTAssertEqual(result.factCandidates.map(\.kind), [.deadline, .date])
        XCTAssertEqual(Set(result.factCandidates.map(\.candidateID)).count, 2)
    }

    func testExtractorUsesNearestLeadingLabelWithinOneSentence() throws {
        let page = try DocumentPage(
            pageIndex: 0,
            widthPoints: 612,
            heightPoints: 792,
            blocks: [try block(
                id: "00000000-0000-0000-0000-000000000108",
                text: "Course begins 2027-09-01 and assignment deadline is 2027-10-01",
                anchorID: firstAnchorID,
                confidence: 0.9
            )]
        )
        let result = try DateCandidateExtractor().extract(
            requestID: UUID(),
            sourceDocument: makeSource(),
            pages: [page],
            languages: ["en"]
        )

        XCTAssertEqual(result.factCandidates.map(\.kind), [.date, .deadline])
    }

    func testExtractorBoundsCandidateAccumulation() throws {
        let dates = Array(repeating: "2027-06-30", count: 5_001).joined(separator: " ")
        let page = try DocumentPage(
            pageIndex: 0,
            widthPoints: 612,
            heightPoints: 792,
            blocks: [try block(
                id: "00000000-0000-0000-0000-000000000109",
                text: dates,
                anchorID: firstAnchorID,
                confidence: 0.9
            )]
        )
        let result = try DateCandidateExtractor().extract(
            requestID: UUID(),
            sourceDocument: makeSource(),
            pages: [page],
            languages: ["en"]
        )

        XCTAssertEqual(result.factCandidates.count, 5_000)
        XCTAssertEqual(result.status, .partial)
        XCTAssertTrue(result.warnings.contains(where: { $0.contains("5,000") }))
    }

    func testExtractorRejectsDateEmbeddedInMalformedToken() throws {
        let page = try DocumentPage(
            pageIndex: 0,
            widthPoints: 612,
            heightPoints: 792,
            blocks: [try block(
                id: "00000000-0000-0000-0000-000000000106",
                text: "Malformed 99-2026-07-15 must not become a deadline.",
                anchorID: firstAnchorID,
                confidence: 0.99
            )]
        )
        let result = try DateCandidateExtractor().extract(
            requestID: UUID(),
            sourceDocument: makeSource(),
            pages: [page],
            languages: ["en"]
        )

        XCTAssertTrue(result.factCandidates.isEmpty)
    }

    func testConfirmCreatesImmutableGroundedFactEvidenceAndAudit() throws {
        let fixture = try makeFixture(confidence: 0.96)
        let candidate = try XCTUnwrap(fixture.result.factCandidates.first)
        let evidenceID = EvidenceLinkID(
            UUID(uuidString: "00000000-0000-0000-0000-000000000030")!
        )
        let confirmedFactID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000031"
        )!
        let outcome = try SourceFactReviewService().review(
            parseResult: fixture.result,
            candidateID: candidate.id,
            sourceDocument: fixture.source,
            anchors: [fixture.anchor],
            decision: .confirm(
                confirmedFactID: confirmedFactID,
                evidenceLinkIDs: [evidenceID]
            ),
            occurredAt: now,
            originDeviceID: deviceID,
            auditID: UUID(uuidString: "00000000-0000-0000-0000-000000000032")!
        )

        let fact = try XCTUnwrap(outcome.confirmedFact)
        XCTAssertEqual(fact.day.value, try LocalDay(year: 2027, month: 6, day: 30))
        XCTAssertEqual(fact.day.authority, .userConfirmed)
        XCTAssertEqual(fact.day.mutability, .immutable)
        XCTAssertEqual(fact.day.evidenceLinkIDs, [evidenceID])
        XCTAssertEqual(fact.day.confirmedAt, now)
        XCTAssertEqual(outcome.audit.disposition, .confirmed)
        XCTAssertEqual(outcome.audit.sourceSHA256, fixture.result.sourceSHA256)
        XCTAssertEqual(outcome.audit.parseRequestID, fixture.result.requestID)
        XCTAssertEqual(outcome.audit.parser, fixture.result.parser)
        XCTAssertEqual(outcome.audit.confirmedFactID, confirmedFactID)
        XCTAssertEqual(outcome.audit.evidenceLinkIDs, [evidenceID])
        XCTAssertEqual(
            outcome.audit.metadata.provenance.sourceDocumentIDs,
            [fixture.source.metadata.id]
        )
        XCTAssertEqual(outcome.evidenceLinks.first?.anchorID, fixture.anchor.metadata.id)
        XCTAssertEqual(outcome.evidenceLinks.first?.subjectID, confirmedFactID)
        XCTAssertEqual(
            outcome.evidenceLinks.first?.metadata.provenance.sourceDocumentIDs,
            [fixture.source.metadata.id]
        )
        XCTAssertEqual(
            fact.metadata.provenance.sourceDocumentIDs,
            [fixture.source.metadata.id]
        )

        let encoded = try JSONEncoder().encode(fact)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var day = try XCTUnwrap(root["day"] as? [String: Any])
        day["authority"] = FactAuthority.sourceVerified.rawValue
        root["day"] = day
        let invalid = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        XCTAssertThrowsError(try JSONDecoder().decode(ConfirmedSourceDateFact.self, from: invalid))
    }

    func testRejectCreatesAuditWithoutFactOrEvidence() throws {
        let fixture = try makeFixture(confidence: 0.96)
        let candidate = try XCTUnwrap(fixture.result.factCandidates.first)
        let outcome = try SourceFactReviewService().review(
            parseResult: fixture.result,
            candidateID: candidate.id,
            sourceDocument: fixture.source,
            anchors: [],
            decision: .reject(reason: "This date is a practice example."),
            occurredAt: now,
            originDeviceID: deviceID,
            auditID: UUID()
        )

        XCTAssertEqual(outcome.audit.disposition, .rejected)
        XCTAssertEqual(outcome.audit.reason, "This date is a practice example.")
        XCTAssertNil(outcome.confirmedFact)
        XCTAssertTrue(outcome.evidenceLinks.isEmpty)
    }

    func testAuditDecodeRequiresReasonOnlyForRejection() throws {
        let fixture = try makeFixture(confidence: 0.96)
        let candidate = try XCTUnwrap(fixture.result.factCandidates.first)
        let confirmedAudit = try SourceFactReviewAudit(
            metadata: RecordMetadata(
                id: UUID(),
                createdAt: now,
                originDeviceID: deviceID,
                provenance: Provenance(
                    kind: .user,
                    sourceDocumentIDs: [fixture.source.metadata.id]
                )
            ),
            candidateID: candidate.id,
            disposition: .confirmed,
            sourceDocumentID: fixture.source.metadata.id,
            sourceSHA256: fixture.result.sourceSHA256,
            anchorIDs: candidate.anchorIDs,
            parseRequestID: fixture.result.requestID,
            parser: fixture.result.parser,
            confirmedFactID: UUID(),
            evidenceLinkIDs: [EvidenceLinkID()],
            reason: nil
        )
        var confirmedRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(confirmedAudit))
                as? [String: Any]
        )
        confirmedRoot["reason"] = "A confirmed review must not carry a rejection reason."
        XCTAssertThrowsError(try JSONDecoder().decode(
            SourceFactReviewAudit.self,
            from: try JSONSerialization.data(withJSONObject: confirmedRoot)
        ))

        var rejectedRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(confirmedAudit))
                as? [String: Any]
        )
        rejectedRoot["disposition"] = SourceFactReviewDisposition.rejected.rawValue
        XCTAssertThrowsError(try JSONDecoder().decode(
            SourceFactReviewAudit.self,
            from: try JSONSerialization.data(withJSONObject: rejectedRoot)
        ))
    }

    func testExplicitConfirmationAcceptsLowConfidenceAnchoredCandidate() throws {
        let lowConfidence = try makeFixture(confidence: 0.4)
        let outcome = try confirm(lowConfidence)
        XCTAssertEqual(outcome.confirmedFact?.day.confidence, 0.4)
        XCTAssertEqual(outcome.confirmedFact?.day.authority, .userConfirmed)
    }

    func testConfirmationFailsClosedForStaleAnchorAndHashMismatch() throws {
        let stale = try makeFixture(confidence: 0.96, anchorSourceRevision: 1)
        XCTAssertThrowsError(try confirm(stale)) { error in
            XCTAssertEqual(error as? GroundingReviewError, .staleAnchor)
        }

        let quoteMismatch = try makeFixture(
            confidence: 0.96,
            anchorQuotedTextSHA256: String(repeating: "f", count: 64)
        )
        XCTAssertThrowsError(try confirm(quoteMismatch)) { error in
            XCTAssertEqual(error as? GroundingReviewError, .anchorQuoteMismatch)
        }

        let fixture = try makeFixture(confidence: 0.96)
        let mismatchedSource = try makeSource(sha256: String(repeating: "b", count: 64))
        let replaced = Fixture(
            source: mismatchedSource,
            anchor: fixture.anchor,
            result: fixture.result
        )
        XCTAssertThrowsError(try confirm(replaced)) { error in
            XCTAssertEqual(error as? GroundingReviewError, .parseSourceMismatch)
        }

        let deletedSource = try makeSource(deletedAt: now)
        let deletedSourceFixture = Fixture(
            source: deletedSource,
            anchor: fixture.anchor,
            result: fixture.result
        )
        XCTAssertThrowsError(try confirm(deletedSourceFixture)) { error in
            XCTAssertEqual(error as? GroundingReviewError, .sourceNotVerified)
        }

        let deletedAnchor = try makeAnchor(
            text: "Final exam date: 2027-06-30",
            sourceRevision: 0,
            deletedAt: now
        )
        let deletedAnchorFixture = Fixture(
            source: fixture.source,
            anchor: deletedAnchor,
            result: fixture.result
        )
        XCTAssertThrowsError(try confirm(deletedAnchorFixture)) { error in
            XCTAssertEqual(error as? GroundingReviewError, .staleAnchor)
        }
    }

    func testConfirmationUsesHashVerifiedParseTextForNoteAnchor() throws {
        let source = try makeSource(type: .note)
        let text = "Assignment deadline: 2027-06-30"
        let noteAnchor = try SourceAnchor(
            metadata: RecordMetadata(
                id: firstAnchorID,
                createdAt: now,
                originDeviceID: deviceID,
                provenance: Provenance(
                    kind: .deterministicEngine,
                    sourceDocumentIDs: [sourceID]
                )
            ),
            sourceDocumentID: sourceID,
            locator: .note(
                noteID: NoteReferenceID(),
                pageID: UUID(),
                blockID: UUID(),
                utf16Start: 0,
                utf16Length: text.utf16.count,
                revision: source.metadata.revision
            ),
            quotedTextSHA256: sha256(text),
            sourceRevision: source.metadata.revision,
            capturedAt: now,
            verificationState: .contentHashVerified
        )
        let page = try DocumentPage(
            pageIndex: 0,
            widthPoints: 612,
            heightPoints: 792,
            blocks: [try block(
                id: "00000000-0000-0000-0000-000000000107",
                text: text,
                anchorID: firstAnchorID,
                confidence: 0.55
            )]
        )
        let result = try DateCandidateExtractor().extract(
            requestID: UUID(),
            sourceDocument: source,
            pages: [page],
            languages: ["en"]
        )

        let outcome = try confirm(Fixture(source: source, anchor: noteAnchor, result: result))
        XCTAssertEqual(outcome.confirmedFact?.day.value, try LocalDay(
            year: 2027,
            month: 6,
            day: 30
        ))
    }

    func testParseResultDecodeCannotBypassCandidateAnchorInvariant() throws {
        let fixture = try makeFixture(confidence: 0.96)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.result))
                as? [String: Any]
        )
        var candidates = try XCTUnwrap(root["factCandidates"] as? [[String: Any]])
        candidates[0]["anchorIDs"] = [UUID().uuidString]
        root["factCandidates"] = candidates
        let invalid = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])

        XCTAssertThrowsError(try JSONDecoder().decode(DocumentParseResult.self, from: invalid))
    }

    func testParseResultDecodeMatchesSchemaHashAndPageBounds() throws {
        let fixture = try makeFixture(confidence: 0.96)
        let encoded = try JSONEncoder().encode(fixture.result)

        var uppercaseHash = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        uppercaseHash["sourceSHA256"] = fixture.result.sourceSHA256.uppercased()
        XCTAssertThrowsError(try JSONDecoder().decode(
            DocumentParseResult.self,
            from: try JSONSerialization.data(withJSONObject: uppercaseHash)
        ))

        var oversizedPage = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var pages = try XCTUnwrap(oversizedPage["pages"] as? [[String: Any]])
        pages[0]["pageIndex"] = 1_000_000
        oversizedPage["pages"] = pages
        XCTAssertThrowsError(try JSONDecoder().decode(
            DocumentParseResult.self,
            from: try JSONSerialization.data(withJSONObject: oversizedPage)
        ))
    }

    func testParseResultDecodeRejectsUnknownKeysAndUnanchoredValue() throws {
        let fixture = try makeFixture(confidence: 0.96)
        let encoded = try JSONEncoder().encode(fixture.result)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        root["unexpected"] = true
        XCTAssertThrowsError(try JSONDecoder().decode(
            DocumentParseResult.self,
            from: try JSONSerialization.data(withJSONObject: root)
        ))

        root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var parser = try XCTUnwrap(root["parser"] as? [String: Any])
        parser["unexpected"] = true
        root["parser"] = parser
        XCTAssertThrowsError(try JSONDecoder().decode(
            DocumentParseResult.self,
            from: try JSONSerialization.data(withJSONObject: root)
        ))

        root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var candidates = try XCTUnwrap(root["factCandidates"] as? [[String: Any]])
        candidates[0]["value"] = "2028-01-01"
        root["factCandidates"] = candidates
        XCTAssertThrowsError(try JSONDecoder().decode(
            DocumentParseResult.self,
            from: try JSONSerialization.data(withJSONObject: root)
        ))
    }

    func testLegacyV1ParseResultMigratesExactOccurrences() throws {
        let fixture = try makeFixture(confidence: 0.96)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.result))
                as? [String: Any]
        )
        root["schemaVersion"] = 1
        var candidates = try XCTUnwrap(root["factCandidates"] as? [[String: Any]])
        candidates[0].removeValue(forKey: "occurrences")
        root["factCandidates"] = candidates

        let migrated = try JSONDecoder().decode(
            DocumentParseResult.self,
            from: try JSONSerialization.data(withJSONObject: root)
        )
        XCTAssertEqual(migrated.schemaVersion, DocumentParseResult.currentSchemaVersion)
        XCTAssertEqual(migrated.factCandidates.first?.occurrences, [
            try DocumentFactOccurrence(
                anchorID: firstAnchorID,
                utf16Start: 17,
                utf16Length: 10
            )
        ])
    }

    func testConfirmedRecordsRejectRemoteOrDeletedMetadata() throws {
        let fixture = try makeFixture(confidence: 0.96)
        let outcome = try confirm(fixture)
        let fact = try XCTUnwrap(outcome.confirmedFact)
        let remoteMetadata = try RecordMetadata(
            id: fact.id,
            createdAt: now,
            originDeviceID: deviceID,
            provenance: Provenance(
                kind: .remoteModel,
                sourceDocumentIDs: [sourceID]
            )
        )
        XCTAssertThrowsError(try ConfirmedSourceDateFact(
            metadata: remoteMetadata,
            candidateID: fact.candidateID,
            sourceDocumentID: fact.sourceDocumentID,
            kind: fact.kind,
            day: fact.day
        ))

        let deletedMetadata = try RecordMetadata(
            id: fact.id,
            createdAt: now,
            deletedAt: now,
            originDeviceID: deviceID,
            provenance: Provenance(
                kind: .user,
                sourceDocumentIDs: [sourceID]
            )
        )
        XCTAssertThrowsError(try ConfirmedSourceDateFact(
            metadata: deletedMetadata,
            candidateID: fact.candidateID,
            sourceDocumentID: fact.sourceDocumentID,
            kind: fact.kind,
            day: fact.day
        ))
    }

    private struct Fixture {
        let source: SourceDocument
        let anchor: SourceAnchor
        let result: DocumentParseResult
    }

    private func makeFixture(
        confidence: Double,
        anchorSourceRevision: Int64 = 0,
        anchorQuotedTextSHA256: String? = nil
    ) throws -> Fixture {
        let source = try makeSource()
        let text = "Final exam date: 2027-06-30"
        let anchor = try makeAnchor(
            text: text,
            sourceRevision: anchorSourceRevision,
            quotedTextSHA256: anchorQuotedTextSHA256
        )
        let page = try DocumentPage(
            pageIndex: 0,
            widthPoints: 612,
            heightPoints: 792,
            blocks: [try block(
                id: "00000000-0000-0000-0000-000000000104",
                text: text,
                anchorID: anchor.metadata.id,
                confidence: confidence
            )]
        )
        let result = try DateCandidateExtractor().extract(
            requestID: UUID(),
            sourceDocument: source,
            pages: [page],
            languages: ["en"]
        )
        return Fixture(source: source, anchor: anchor, result: result)
    }

    private func confirm(_ fixture: Fixture) throws -> SourceFactReviewOutcome {
        let candidate = try XCTUnwrap(fixture.result.factCandidates.first)
        return try SourceFactReviewService().review(
            parseResult: fixture.result,
            candidateID: candidate.id,
            sourceDocument: fixture.source,
            anchors: [fixture.anchor],
            decision: .confirm(
                confirmedFactID: UUID(),
                evidenceLinkIDs: [EvidenceLinkID()]
            ),
            occurredAt: now,
            originDeviceID: deviceID,
            auditID: UUID()
        )
    }

    private func makeSource(
        sha256: String = String(repeating: "a", count: 64),
        type: SourceDocumentType = .pdf,
        deletedAt: Date? = nil
    ) throws -> SourceDocument {
        try SourceDocument(
            metadata: RecordMetadata(
                id: sourceID,
                createdAt: now,
                deletedAt: deletedAt,
                originDeviceID: deviceID,
                provenance: Provenance(
                    kind: .importedSource,
                    sourceDocumentIDs: [sourceID]
                )
            ),
            type: type,
            displayTitle: "syllabus.pdf",
            contentSHA256: sha256,
            rightsState: .userOwned,
            accessState: .userProvidedFullText,
            localRelativePath: "Sources/source/original.pdf",
            parserVersion: "fixture",
            accessedAt: now,
            verificationState: .contentHashVerified
        )
    }

    private func makeAnchor(
        text: String,
        sourceRevision: Int64,
        quotedTextSHA256: String? = nil,
        deletedAt: Date? = nil
    ) throws -> SourceAnchor {
        try SourceAnchor(
            metadata: RecordMetadata(
                id: firstAnchorID,
                createdAt: now,
                deletedAt: deletedAt,
                originDeviceID: deviceID,
                provenance: Provenance(
                    kind: .deterministicEngine,
                    sourceDocumentIDs: [sourceID]
                )
            ),
            sourceDocumentID: sourceID,
            locator: .pdf(
                pageIndex: 0,
                normalizedRects: [try NormalizedRect(x: 0, y: 0, width: 1, height: 0.2)],
                textQuote: text
            ),
            quotedTextSHA256: quotedTextSHA256 ?? SHA256.hash(data: Data(text.utf8))
                .map { String(format: "%02x", $0) }
                .joined(),
            sourceRevision: sourceRevision,
            capturedAt: now,
            verificationState: .contentHashVerified
        )
    }

    private func block(
        id: String,
        text: String,
        anchorID: SourceAnchorID,
        confidence: Double?
    ) throws -> DocumentTextBlock {
        try DocumentTextBlock(
            blockID: UUID(uuidString: id)!,
            kind: .paragraph,
            text: text,
            anchorID: anchorID,
            confidence: confidence
        )
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
