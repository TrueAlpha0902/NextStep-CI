import Foundation
import NotesCore
@testable import NextStepAcademic
import XCTest

final class CaptureDomainTests: XCTestCase {
    func testAllSevenCaptureKindsAreCodableAndComplete() throws {
        let expected: Set<String> = [
            "professorEmphasis",
            "learningGap",
            "assignmentCandidate",
            "examCandidate",
            "researchIdea",
            "currentAffairsLink",
            "evidenceCandidate",
        ]
        XCTAssertEqual(Set(CaptureKind.allCases.map(\.rawValue)), expected)
        XCTAssertEqual(CaptureKind.allCases.count, 7)

        for (index, kind) in CaptureKind.allCases.enumerated() {
            let capture = try makeQuickCapture(
                idSeed: 100 + index * 10,
                kind: kind,
                title: kind.isAssignmentOrExamCandidate ? "第 \(index + 1) 份候選項目 📚" : nil
            )
            XCTAssertEqual(capture.kind, kind)
            try assertCodableRoundTrip(capture)
        }
    }

    func testAnchoredAndQuickCaptureSourceTextAreMutuallyExclusive() throws {
        let anchor = try SourceAnchor(
            id: SourceAnchorID(testUUID(200)),
            noteID: NotebookID(testUUID(201)),
            pageID: PageID(testUUID(202)),
            blockID: TextBlockID(testUUID(203)),
            noteRevision: 8,
            textHash: String(repeating: "f", count: 64),
            capturedAt: testCreatedAt
        )
        let draft = try CaptureDraftFields(details: "錨點不重複保存原文 🧷")
        let anchored = try CaptureItem.create(
            id: CaptureItemID(testUUID(204)),
            kind: .professorEmphasis,
            source: .noteAnchor(anchor),
            courseID: testCourseID,
            sessionID: testSessionID,
            rawText: nil,
            draftFields: draft,
            capturedAt: testStartedAt,
            auditID: CaptureAuditEntryID(testUUID(205))
        )
        XCTAssertNil(anchored.rawText)
        try assertCodableRoundTrip(anchored)

        XCTAssertThrowsError(try CaptureItem.create(
            kind: .professorEmphasis,
            source: .noteAnchor(anchor),
            courseID: testCourseID,
            sessionID: testSessionID,
            rawText: "不應複製的原文",
            draftFields: draft,
            capturedAt: testStartedAt
        ))
        XCTAssertThrowsError(try CaptureItem.create(
            kind: .professorEmphasis,
            source: .quickCapture(try QuickCaptureReference()),
            courseID: nil,
            sessionID: nil,
            rawText: nil,
            draftFields: draft,
            capturedAt: testStartedAt
        ))
        XCTAssertThrowsError(try QuickCaptureReference(
            noteID: nil,
            pageID: PageID(testUUID(206))
        ))
    }

    func testQuickCaptureReferencePreservesFlatShapeAndRejectsMixedPayloads() throws {
        let noteID = NotebookID(testUUID(207))
        let pageID = PageID(testUUID(208))
        let source = CaptureSource.quickCapture(try QuickCaptureReference(
            noteID: noteID,
            pageID: pageID
        ))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(source)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["type"] as? String, "quickCapture")
        XCTAssertNotNil(object["noteID"])
        XCTAssertNotNil(object["pageID"])
        XCTAssertNil(object["reference"], "The persisted CaptureSource shape must remain flat.")
        XCTAssertEqual(try JSONDecoder().decode(CaptureSource.self, from: encoded), source)

        var pageWithoutNote = object
        pageWithoutNote.removeValue(forKey: "noteID")
        XCTAssertThrowsError(try JSONDecoder().decode(
            CaptureSource.self,
            from: JSONSerialization.data(withJSONObject: pageWithoutNote)
        ))

        let quickWithAnchor = Data(
            "{\"type\":\"quickCapture\",\"anchor\":{}}".utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(CaptureSource.self, from: quickWithAnchor)
        )

        let anchor = try SourceAnchor(
            id: SourceAnchorID(testUUID(209)),
            noteID: noteID,
            pageID: pageID,
            blockID: TextBlockID(testUUID(210)),
            noteRevision: 2,
            capturedAt: testCreatedAt
        )
        var anchorObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try encoder.encode(CaptureSource.noteAnchor(anchor))
            ) as? [String: Any]
        )
        anchorObject["noteID"] = ["rawValue": testUUID(211).uuidString]
        let anchorWithQuickField = try JSONSerialization.data(withJSONObject: anchorObject)
        XCTAssertThrowsError(
            try JSONDecoder().decode(CaptureSource.self, from: anchorWithQuickField)
        )
    }

    func testCandidateDraftDateCertaintyAndReadyStateInvariants() throws {
        let typeOnlyDraft = try CaptureDraftFields()
        let typeOnlyCandidate = try CaptureItem.create(
            kind: .assignmentCandidate,
            source: .quickCapture(try QuickCaptureReference()),
            courseID: testCourseID,
            sessionID: testSessionID,
            rawText: "只用類型建立的作業候選",
            draftFields: typeOnlyDraft,
            capturedAt: testStartedAt
        )
        XCTAssertEqual(typeOnlyCandidate.draftFields.dateCertainty, .unknown)
        XCTAssertThrowsError(try CaptureItem(
            id: typeOnlyCandidate.id,
            revision: typeOnlyCandidate.revision,
            kind: typeOnlyCandidate.kind,
            source: typeOnlyCandidate.source,
            courseID: typeOnlyCandidate.courseID,
            sessionID: typeOnlyCandidate.sessionID,
            rawText: typeOnlyCandidate.rawText,
            draftFields: typeOnlyDraft,
            capturedAt: typeOnlyCandidate.capturedAt,
            modifiedAt: typeOnlyCandidate.modifiedAt,
            state: typeOnlyCandidate.state,
            resolution: typeOnlyCandidate.resolution,
            auditTrail: typeOnlyCandidate.auditTrail
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .invalidField("capture.dateCertainty")
            )
        }
        XCTAssertThrowsError(try CaptureDraftFields(
            title: "期中考",
            dateCertainty: .confirmed
        ))
        XCTAssertThrowsError(try CaptureDraftFields(
            title: "日期仍未知",
            date: AcademicLocalDate(year: 2026, month: 10, day: 1),
            dateCertainty: .unknown
        ))
        XCTAssertThrowsError(try CaptureItem.create(
            kind: .researchIdea,
            source: .quickCapture(try QuickCaptureReference()),
            rawText: "非候選項目不應有日期",
            draftFields: try CaptureDraftFields(
                date: AcademicLocalDate(year: 2026, month: 10, day: 1),
                dateCertainty: .estimated
            ),
            capturedAt: testStartedAt
        ))

        let missingTitle = try makeQuickCapture(
            idSeed: 220,
            kind: .examCandidate,
            title: nil
        )
        let needsDetails = try missingTitle.transitioned(
            to: .needsDetails,
            at: testStartedAt.addingTimeInterval(1),
            auditID: CaptureAuditEntryID(testUUID(222))
        )
        XCTAssertThrowsError(try needsDetails.transitioned(
            to: .readyToConfirm,
            at: testStartedAt.addingTimeInterval(2),
            auditID: CaptureAuditEntryID(testUUID(223))
        ))

        let completeDraft = try CaptureDraftFields(
            title: "期中考範圍 🧪",
            scope: "第 1–6 章",
            date: AcademicLocalDate(year: 2026, month: 11, day: 3),
            dateCertainty: .confirmed
        )
        let ready = try needsDetails.transitioned(
            to: .readyToConfirm,
            draftFields: completeDraft,
            at: testStartedAt.addingTimeInterval(2),
            auditID: CaptureAuditEntryID(testUUID(224))
        )
        XCTAssertEqual(ready.state, .readyToConfirm)
        XCTAssertEqual(ready.draftFields.dateCertainty, .confirmed)
        XCTAssertThrowsError(try ready.transitioned(
            to: .needsDetails,
            at: testStartedAt.addingTimeInterval(3)
        ))
    }

    func testAuditTrailIsAppendOnlyUniqueAndStateTransitionsAreStrict() throws {
        let inbox = try makeQuickCapture(
            idSeed: 240,
            kind: .professorEmphasis
        )
        XCTAssertThrowsError(try inbox.transitioned(
            to: .readyToConfirm,
            at: testStartedAt.addingTimeInterval(1)
        ))
        XCTAssertThrowsError(try inbox.transitioned(
            to: .needsDetails,
            at: testStartedAt.addingTimeInterval(1),
            auditID: inbox.auditTrail[0].id
        ))

        let rejected = try inbox.rejecting(
            reason: "不是可執行事項，但保留審計記錄。",
            at: testStartedAt.addingTimeInterval(2),
            auditID: CaptureAuditEntryID(testUUID(242))
        )
        XCTAssertEqual(rejected.state, .resolved)
        XCTAssertEqual(rejected.resolution?.kind, .rejected)
        XCTAssertEqual(rejected.revision, 2)
        try assertCodableRoundTrip(rejected)
        XCTAssertThrowsError(try rejected.updatingDraft(
            try CaptureDraftFields(details: "已解決後不可修改"),
            at: testStartedAt.addingTimeInterval(3)
        ))
    }

    func testV1CannotRepresentFormalAssignmentExamOrTaskResolution() throws {
        let forbiddenNames: Set<String> = ["assignment", "exam", "task"]
        XCTAssertTrue(forbiddenNames.isDisjoint(
            with: Set(AcademicEntityType.allCases.map(\.rawValue))
        ))

        let inbox = try makeQuickCapture(
            idSeed: 260,
            kind: .assignmentCandidate,
            title: "候選作業"
        )
        let createdResolution = try CaptureResolution(
            kind: .created,
            resolvedAt: testCompletedAt,
            resolvedEntityRefs: [
                try AcademicEntityRef(
                    entityType: .noteBlock,
                    entityID: testUUID(264)
                ),
                try AcademicEntityRef(
                    entityType: .course,
                    entityID: testCourseID.rawValue
                ),
                try AcademicEntityRef(
                    entityType: .noteBlock,
                    entityID: testUUID(263)
                ),
            ]
        )
        XCTAssertEqual(
            createdResolution.resolvedEntityRefs.map {
                "\($0.entityType.rawValue):\($0.entityID.uuidString)"
            },
            [
                "course:\(testCourseID.rawValue.uuidString)",
                "noteBlock:\(testUUID(263).uuidString)",
                "noteBlock:\(testUUID(264).uuidString)",
            ]
        )
        try assertCodableRoundTrip(createdResolution)
        let finalAudit = try CaptureAuditEntry(
            id: CaptureAuditEntryID(testUUID(262)),
            occurredAt: testCompletedAt,
            action: .rejected,
            fromState: .inbox,
            toState: .resolved,
            reason: "合成非法 resolved 狀態"
        )
        XCTAssertThrowsError(try CaptureItem(
            id: inbox.id,
            revision: 2,
            kind: inbox.kind,
            source: inbox.source,
            courseID: inbox.courseID,
            sessionID: inbox.sessionID,
            rawText: inbox.rawText,
            draftFields: inbox.draftFields,
            capturedAt: inbox.capturedAt,
            modifiedAt: testCompletedAt,
            state: .resolved,
            resolution: createdResolution,
            auditTrail: [inbox.auditTrail[0], finalAudit]
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .unsupportedV1Operation("capture.resolution.created")
            )
        }
    }

    func testCodableFailsClosedForFutureSchemaAndInvalidNestedDraft() throws {
        XCTAssertThrowsError(
            try JSONDecoder().decode(CaptureItem.self, from: futureSchemaOnly())
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(CaptureResolution.self, from: futureSchemaOnly())
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(CaptureAuditEntry.self, from: futureSchemaOnly())
        )
        XCTAssertThrowsError(try JSONDecoder().decode(
            CaptureDraftFields.self,
            from: Data("{\"title\":\" 前後空白 \"}".utf8)
        ))

        let tooLong = String(
            repeating: "界",
            count: AcademicDomainLimits.maximumCaptureTextCharacters + 1
        )
        XCTAssertThrowsError(try CaptureDraftFields(details: tooLong))

        let oversizedUTF8Title = "a" + String(
            repeating: "\u{0301}",
            count: AcademicDomainLimits.maximumShortFieldUTF8Bytes / 2 + 1
        )
        XCTAssertEqual(oversizedUTF8Title.count, 1)
        XCTAssertLessThanOrEqual(
            oversizedUTF8Title.count,
            AcademicDomainLimits.maximumShortFieldCharacters
        )
        XCTAssertGreaterThan(
            oversizedUTF8Title.utf8.count,
            AcademicDomainLimits.maximumShortFieldUTF8Bytes
        )
        XCTAssertThrowsError(try CaptureDraftFields(title: oversizedUTF8Title))

        XCTAssertThrowsError(try JSONDecoder().decode(
            CaptureDraftFields.self,
            from: Data("{\"title\":42}".utf8)
        )) { error in
            guard case DecodingError.typeMismatch(_, _) = error else {
                return XCTFail("Expected the original typeMismatch, received \(error).")
            }
        }
    }
}
