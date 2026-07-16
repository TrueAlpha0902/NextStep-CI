import Foundation
import NextStepDomain
import NextStepGrounding
import NextStepPlanning
@testable import NotesApp
import XCTest

final class NextStepBetaGroundingIntegrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)
    private let originalDeadline = try! LocalDay(year: 2027, month: 6, day: 30)
    private let proposedDeadline = try! LocalDay(year: 2026, month: 9, day: 30)
    private let extract = "Course outline\nAssignment deadline: 2026-09-30\nSubmit one verified memo."

    func testImportPersistsExactAnchoredDeadlineCandidateAcrossRelaunch() async throws {
        let archive = try makeArchive()
        let pending = try XCTUnwrap(archive.grounding.pendingFacts.first)
        let occurrence = try XCTUnwrap(pending.candidate.occurrences.first)
        let block = try XCTUnwrap(
            pending.batch.parseResult.pages.flatMap(\.blocks).first {
                $0.anchorID == occurrence.anchorID
            }
        )
        let recovered = (block.text as NSString).substring(with: NSRange(
            location: occurrence.utf16Start,
            length: occurrence.utf16Length
        ))

        XCTAssertEqual(pending.candidate.kind, .deadline)
        XCTAssertEqual(pending.candidate.value, "2026-09-30")
        XCTAssertEqual(recovered, pending.candidate.value)
        XCTAssertEqual(
            pending.batch.parseResult.sourceSHA256,
            archive.workspace.sourceDocuments.first?.contentSHA256
        )
        XCTAssertTrue(archive.grounding.reviewAudits.isEmpty)
        XCTAssertTrue(archive.grounding.confirmedDateFacts.isEmpty)

        let root = temporaryRoot("grounding-import")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NextStepBetaStore(rootURL: root)
        try await store.save(archive)
        let loaded = try await store.load()
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertEqual(reloaded.grounding, archive.grounding)
        XCTAssertEqual(reloaded.grounding.pendingFacts.first?.candidate, pending.candidate)
    }

    func testPreviewIsPureAndIncludesDeadlineAndReplanDiff() throws {
        let archive = try makeArchive()
        let before = try encoded(archive)
        let candidateID = try XCTUnwrap(archive.grounding.pendingFacts.first?.id)

        let preview = try NextStepBetaSourceFactReviewCoordinator().makePreview(
            candidateID: candidateID,
            archive: archive,
            now: now.addingTimeInterval(60)
        )

        XCTAssertEqual(try encoded(archive), before)
        XCTAssertEqual(preview.diff.kind, .deadline)
        XCTAssertEqual(preview.diff.previousDay, originalDeadline)
        XCTAssertEqual(preview.diff.proposedDay, proposedDeadline)
        XCTAssertEqual(
            preview.diff.deadlineChanges.map(\.owner),
            [.milestone, .dailyAction]
        )
        XCTAssertTrue(preview.diff.deadlineChanges.allSatisfy {
            $0.previousDay == originalDeadline && $0.proposedDay == proposedDeadline
        })
        XCTAssertEqual(preview.replanProposal?.trigger, .deadlineChanged)
        XCTAssertEqual(
            preview.replanProposal?.previousDecisionID,
            archive.currentDecision?.metadata.id
        )
        XCTAssertEqual(archive.workspace.ultimateGoals.first?.targetDay?.value, originalDeadline)
        XCTAssertTrue(archive.grounding.reviewAudits.isEmpty)
        XCTAssertTrue(archive.grounding.confirmedDateFacts.isEmpty)
    }

    func testStalePreviewFailsClosedWithoutChangingArchive() throws {
        let archive = try makeArchive()
        let preview = try NextStepBetaSourceFactReviewCoordinator().makePreview(
            candidateID: try XCTUnwrap(archive.grounding.pendingFacts.first?.id),
            archive: archive,
            now: now.addingTimeInterval(60)
        )
        var changed = archive
        changed.workspace.revision += 1
        changed.workspace.savedAt = now.addingTimeInterval(30)
        let before = try encoded(changed)

        XCTAssertThrowsError(
            try NextStepBetaSourceFactReviewCoordinator().accept(
                preview,
                archive: changed,
                now: preview.createdAt.addingTimeInterval(1)
            )
        ) { error in
            XCTAssertEqual(error as? NextStepBetaGroundingError, .stalePreview)
        }
        XCTAssertEqual(try encoded(changed), before)
        XCTAssertTrue(changed.grounding.reviewAudits.isEmpty)
        XCTAssertTrue(changed.grounding.confirmedDateFacts.isEmpty)
    }

    func testConfirmAtomicallyAddsFactEvidenceDeadlineAndReplan() async throws {
        let archive = try makeArchive()
        let previousEvidenceCount = archive.workspace.evidenceLinks.count
        let previousDecisionCount = archive.workspace.planningDecisions.count
        let previousEventCount = archive.workspace.replanEvents.count
        let preview = try NextStepBetaSourceFactReviewCoordinator().makePreview(
            candidateID: try XCTUnwrap(archive.grounding.pendingFacts.first?.id),
            archive: archive,
            now: now.addingTimeInterval(60)
        )
        let acceptedAt = preview.createdAt.addingTimeInterval(30)

        let confirmed = try NextStepBetaSourceFactReviewCoordinator().accept(
            preview,
            archive: archive,
            now: acceptedAt
        )
        try confirmed.validate()

        XCTAssertTrue(confirmed.grounding.pendingFacts.isEmpty)
        let audit = try XCTUnwrap(confirmed.grounding.reviewAudits.first)
        let fact = try XCTUnwrap(confirmed.grounding.confirmedDateFacts.first)
        XCTAssertEqual(audit.disposition, .confirmed)
        XCTAssertEqual(audit.confirmedFactID, fact.id)
        XCTAssertEqual(fact.day.value, proposedDeadline)
        XCTAssertEqual(fact.day.authority, .userConfirmed)
        XCTAssertEqual(fact.day.mutability, .immutable)
        XCTAssertEqual(fact.day.evidenceLinkIDs, audit.evidenceLinkIDs)
        XCTAssertEqual(fact.day.confirmedAt, acceptedAt)
        XCTAssertEqual(fact.metadata.createdAt, acceptedAt)
        XCTAssertEqual(audit.metadata.createdAt, acceptedAt)
        XCTAssertEqual(
            confirmed.workspace.evidenceLinks.count,
            previousEvidenceCount + preview.candidate.anchorIDs.count
        )
        for evidenceID in fact.day.evidenceLinkIDs {
            let evidence = try XCTUnwrap(
                confirmed.workspace.evidenceLinks.first { $0.metadata.id == evidenceID }
            )
            XCTAssertEqual(evidence.subjectType, "ConfirmedSourceDateFact")
            XCTAssertEqual(evidence.subjectID, fact.id)
            XCTAssertEqual(evidence.verifiedBy, .user)
        }
        XCTAssertEqual(
            confirmed.workspace.ultimateGoals.first?.targetDay?.value,
            originalDeadline
        )
        XCTAssertEqual(
            confirmed.workspace.goals.first?.targetDay?.value,
            originalDeadline
        )
        let affectedDeadlines = confirmed.workspace.milestones.compactMap(\.targetDay)
            + confirmed.workspace.dailyActions.compactMap(\.deadline)
        XCTAssertEqual(affectedDeadlines.count, 2)
        for deadline in affectedDeadlines {
            XCTAssertEqual(deadline.value, proposedDeadline)
            XCTAssertEqual(deadline.authority, .userConfirmed)
            XCTAssertEqual(deadline.mutability, .immutable)
            XCTAssertEqual(deadline.evidenceLinkIDs, fact.day.evidenceLinkIDs)
        }
        XCTAssertEqual(confirmed.workspace.planningDecisions.count, previousDecisionCount + 1)
        XCTAssertEqual(confirmed.workspace.replanEvents.count, previousEventCount + 1)
        XCTAssertEqual(confirmed.workspace.replanEvents.last?.trigger, .deadlineChanged)
        XCTAssertEqual(confirmed.workspace.replanEvents.last?.resolution, .accepted)
        XCTAssertEqual(confirmed.workspace.replanEvents.last?.occurredAt, acceptedAt)
        XCTAssertEqual(confirmed.workspace.savedAt, acceptedAt)
        XCTAssertEqual(confirmed.currentDecisionID, preview.replanProposal?.proposedDecision.metadata.id)

        let root = temporaryRoot("grounding-confirm")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NextStepBetaStore(rootURL: root)
        try await store.save(confirmed)
        let loaded = try await store.load()
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertEqual(reloaded.grounding, confirmed.grounding)
        XCTAssertEqual(reloaded.workspace.ultimateGoals.first?.targetDay?.value, originalDeadline)
        XCTAssertEqual(reloaded.workspace.goals.first?.targetDay?.value, originalDeadline)
        XCTAssertEqual(reloaded.workspace.milestones.first?.targetDay, fact.day)
    }

    func testArchiveValidationRejectsConfirmedDayThatDoesNotMatchCandidate() throws {
        var confirmed = try makeConfirmedArchive()
        let fact = try XCTUnwrap(confirmed.grounding.confirmedDateFacts.first)
        let tamperedDay = try FactValue(
            value: try LocalDay(year: 2026, month: 10, day: 1),
            authority: fact.day.authority,
            mutability: fact.day.mutability,
            evidenceLinkIDs: fact.day.evidenceLinkIDs,
            confidence: fact.day.confidence,
            confirmedAt: fact.day.confirmedAt
        )
        confirmed.grounding.confirmedDateFacts[0] = try ConfirmedSourceDateFact(
            metadata: fact.metadata,
            candidateID: fact.candidateID,
            sourceDocumentID: fact.sourceDocumentID,
            kind: fact.kind,
            day: tamperedDay
        )

        XCTAssertThrowsError(try confirmed.validate()) { error in
            XCTAssertEqual(error as? NextStepBetaGroundingError, .invalidArchiveState)
        }
    }

    func testArchiveValidationRejectsConfirmedDeadlineThatWasNotAppliedToItsScope() throws {
        var confirmed = try makeConfirmedArchive()
        let originalGoalDeadline = try XCTUnwrap(
            confirmed.workspace.ultimateGoals.first?.targetDay
        )
        XCTAssertEqual(originalGoalDeadline.value, originalDeadline)
        confirmed.workspace.milestones[0].targetDay = originalGoalDeadline

        XCTAssertThrowsError(try confirmed.validate()) { error in
            XCTAssertEqual(error as? NextStepBetaGroundingError, .invalidArchiveState)
        }
    }

    func testArchiveValidationRejectsStaleOrTombstonedGroundingEvidence() throws {
        let confirmed = try makeConfirmedArchive()
        let fact = try XCTUnwrap(confirmed.grounding.confirmedDateFacts.first)
        let evidenceID = try XCTUnwrap(fact.day.evidenceLinkIDs.first)
        let evidenceIndex = try XCTUnwrap(
            confirmed.workspace.evidenceLinks.firstIndex {
                $0.metadata.id == evidenceID
            }
        )
        let anchorID = confirmed.workspace.evidenceLinks[evidenceIndex].anchorID
        let anchorIndex = try XCTUnwrap(
            confirmed.workspace.sourceAnchors.firstIndex {
                $0.metadata.id == anchorID
            }
        )

        var staleRevision = confirmed
        staleRevision.workspace.sourceAnchors[anchorIndex].sourceRevision += 1

        var mismatchedQuote = confirmed
        mismatchedQuote.workspace.sourceAnchors[anchorIndex].quotedTextSHA256 = String(
            repeating: "0",
            count: 64
        )

        var tombstonedAnchor = confirmed
        let anchor = tombstonedAnchor.workspace.sourceAnchors[anchorIndex]
        tombstonedAnchor.workspace.sourceAnchors[anchorIndex] = try SourceAnchor(
            metadata: try tombstoned(anchor.metadata),
            sourceDocumentID: anchor.sourceDocumentID,
            locator: anchor.locator,
            quotedTextSHA256: anchor.quotedTextSHA256,
            sourceRevision: anchor.sourceRevision,
            capturedAt: anchor.capturedAt,
            verificationState: anchor.verificationState
        )

        var tombstonedEvidence = confirmed
        let evidence = tombstonedEvidence.workspace.evidenceLinks[evidenceIndex]
        tombstonedEvidence.workspace.evidenceLinks[evidenceIndex] = try EvidenceLink(
            metadata: try tombstoned(evidence.metadata),
            anchorID: evidence.anchorID,
            relation: evidence.relation,
            subjectType: evidence.subjectType,
            subjectID: evidence.subjectID,
            verificationMethod: evidence.verificationMethod,
            verifiedBy: evidence.verifiedBy
        )

        for archive in [
            staleRevision,
            mismatchedQuote,
            tombstonedAnchor,
            tombstonedEvidence
        ] {
            XCTAssertThrowsError(try archive.validate())
        }
    }

    func testAcceptRejectsPreviewAfterTTLWithoutChangingArchive() throws {
        let archive = try makeArchive()
        let preview = try NextStepBetaSourceFactReviewCoordinator().makePreview(
            candidateID: try XCTUnwrap(archive.grounding.pendingFacts.first?.id),
            archive: archive,
            now: now.addingTimeInterval(60)
        )
        let before = try encoded(archive)

        XCTAssertThrowsError(try NextStepBetaSourceFactReviewCoordinator().accept(
            preview,
            archive: archive,
            now: preview.createdAt.addingTimeInterval(
                NextStepBetaSourceFactReviewCoordinator.previewTimeToLive + 1
            )
        )) { error in
            XCTAssertEqual(error as? NextStepBetaGroundingError, .stalePreview)
        }
        XCTAssertEqual(try encoded(archive), before)
    }

    func testAcceptRejectsPreviewAcrossLocalDayEvenWithinTTL() throws {
        let archive = try makeArchive()
        let previewAt = now.addingTimeInterval(50 * 60)
        let preview = try NextStepBetaSourceFactReviewCoordinator().makePreview(
            candidateID: try XCTUnwrap(archive.grounding.pendingFacts.first?.id),
            archive: archive,
            now: previewAt
        )
        let before = try encoded(archive)

        XCTAssertThrowsError(try NextStepBetaSourceFactReviewCoordinator().accept(
            preview,
            archive: archive,
            now: previewAt.addingTimeInterval(5 * 60)
        )) { error in
            XCTAssertEqual(error as? NextStepBetaGroundingError, .stalePreview)
        }
        XCTAssertEqual(try encoded(archive), before)
    }

    func testRejectAddsAuditOnlyAndPreservesDeadlineAndPlan() throws {
        let archive = try makeArchive()
        let candidateID = try XCTUnwrap(archive.grounding.pendingFacts.first?.id)
        let previousDecisionID = archive.currentDecision?.metadata.id
        let previousDecisionCount = archive.workspace.planningDecisions.count
        let previousEventCount = archive.workspace.replanEvents.count
        let previousEvidence = archive.workspace.evidenceLinks

        let rejected = try NextStepBetaSourceFactReviewCoordinator().reject(
            candidateID: candidateID,
            reason: "  這不是作業期限  ",
            archive: archive,
            now: now.addingTimeInterval(60)
        )

        XCTAssertTrue(rejected.grounding.pendingFacts.isEmpty)
        XCTAssertTrue(rejected.grounding.confirmedDateFacts.isEmpty)
        XCTAssertEqual(rejected.grounding.reviewAudits.first?.disposition, .rejected)
        XCTAssertEqual(rejected.grounding.reviewAudits.first?.reason, "這不是作業期限")
        XCTAssertEqual(rejected.workspace.evidenceLinks, previousEvidence)
        XCTAssertEqual(rejected.currentDecision?.metadata.id, previousDecisionID)
        XCTAssertEqual(rejected.workspace.planningDecisions.count, previousDecisionCount)
        XCTAssertEqual(rejected.workspace.replanEvents.count, previousEventCount)
        XCTAssertTrue(targetDeadlines(rejected).allSatisfy { $0.value == originalDeadline })
        XCTAssertEqual(rejected.workspace.revision, archive.workspace.revision + 1)
    }

    private func makeArchive() throws -> NextStepBetaArchive {
        let deviceID = DeviceID()
        var archive = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: now,
            deviceID: deviceID,
            timeZoneIdentifier: "Asia/Taipei"
        )
        archive = try NextStepBetaGoalBuilder().addGoal(
            title: "完成研究計畫",
            deadline: originalDeadline,
            dailyMinutes: 35,
            to: archive,
            now: now
        )
        let documentID = SourceDocumentID()
        let document = try NextStepBetaSourceRecordBuilder().makeDocument(
            id: documentID,
            displayTitle: "course-outline.pdf",
            fileExtension: "pdf",
            relativePath: "Sources/\(documentID.description)/original.pdf",
            contentSHA256: String(repeating: "c", count: 64),
            now: now,
            deviceID: deviceID,
            parserVersion: "pdfkit-first-page-v1"
        )
        archive = try NextStepBetaPackageBuilder().addImportedSource(
            NextStepBetaImportedSource(
                document: document,
                exactExtract: extract,
                pageIndex: 0,
                usedVisionOCR: false,
                extractionNotice: nil
            ),
            to: archive,
            now: now
        )
        return try NextStepBetaPlanningBridge().replan(
            archive: archive,
            trigger: .sourceImported,
            now: now
        )
    }

    private func targetDeadlines(_ archive: NextStepBetaArchive) -> [FactValue<LocalDay>] {
        archive.workspace.ultimateGoals.compactMap(\.targetDay)
            + archive.workspace.goals.compactMap(\.targetDay)
            + archive.workspace.milestones.compactMap(\.targetDay)
            + archive.workspace.dailyActions.compactMap(\.deadline)
    }

    private func makeConfirmedArchive() throws -> NextStepBetaArchive {
        let archive = try makeArchive()
        let preview = try NextStepBetaSourceFactReviewCoordinator().makePreview(
            candidateID: try XCTUnwrap(archive.grounding.pendingFacts.first?.id),
            archive: archive,
            now: now.addingTimeInterval(60)
        )
        return try NextStepBetaSourceFactReviewCoordinator().accept(
            preview,
            archive: archive,
            now: preview.createdAt.addingTimeInterval(30)
        )
    }

    private func tombstoned<ID>(
        _ metadata: RecordMetadata<ID>
    ) throws -> RecordMetadata<ID> where ID: Codable & Hashable & Sendable {
        let deletedAt = metadata.updatedAt.addingTimeInterval(1)
        return try RecordMetadata(
            id: metadata.id,
            schemaVersion: metadata.schemaVersion,
            revision: metadata.revision + 1,
            createdAt: metadata.createdAt,
            updatedAt: deletedAt,
            deletedAt: deletedAt,
            originDeviceID: metadata.originDeviceID,
            lastOperationID: metadata.lastOperationID,
            provenance: metadata.provenance
        )
    }

    private func encoded(_ archive: NextStepBetaArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(archive)
    }

    private func temporaryRoot(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "nextstep-beta-\(suffix)-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
