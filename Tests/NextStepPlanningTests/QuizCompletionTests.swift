import CryptoKit
import Foundation
import NextStepDomain
@testable import NextStepPlanning
import XCTest

final class QuizCompletionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let deviceID = DeviceID(
        UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    )

    func testQuizEvaluatorScoresDeterministicallyAndRejectsTamperedStoredScore() throws {
        let fixture = try makeFixture()
        let response = try makeResponse(
            fixture: fixture,
            selectedOptionID: fixture.correctOptionID,
            responseID: UserResponseID(fixedUUID(80)),
            attemptID: fixedUUID(81)
        )

        let result = try QuizEvaluator().evaluate(
            quiz: fixture.quiz,
            packageID: fixture.package.metadata.id,
            packageVersion: fixture.package.version,
            responses: [response],
            scoredAt: now
        )
        XCTAssertEqual(response.scoreFraction, 1)
        XCTAssertEqual(result.scoreFraction, 1)
        XCTAssertEqual(result.responseIDs, [response.metadata.id])
        XCTAssertEqual(result.evidenceLinkIDs, fixture.quiz.items[0].evidenceLinkIDs)

        let tampered = try UserResponse(
            metadata: metadata(UserResponseID(fixedUUID(82))),
            attemptID: fixedUUID(83),
            quizID: fixture.quiz.metadata.id,
            quizItemID: fixture.quiz.items[0].id,
            packageVersion: fixture.package.version,
            answer: fixture.correctOptionText,
            selectedOptionIDs: [fixture.correctOptionID],
            scoreFraction: 0,
            feedback: fixture.quiz.items[0].answerExplanation,
            attemptedAt: now
        )
        XCTAssertThrowsError(try QuizEvaluator().evaluate(
            quiz: fixture.quiz,
            packageID: fixture.package.metadata.id,
            packageVersion: fixture.package.version,
            responses: [tampered],
            scoredAt: now
        )) { error in
            guard let evaluationError = error as? QuizEvaluationError,
                  case .tamperedScore = evaluationError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAttestationCannotSatisfyQuizCriterionAndUnknownCriterionIsRejected() throws {
        let fixture = try makeFixture()
        let attestation = try CompletionEvidence(
            metadata: metadata(CompletionEvidenceID(fixedUUID(84))),
            actionID: fixture.action.metadata.id,
            packageID: fixture.package.metadata.id,
            packageVersion: fixture.package.version,
            kind: .userAttestation,
            value: "I completed the quiz.",
            capturedAt: now,
            criterionIDs: [fixture.quizCriterion.id]
        )

        XCTAssertThrowsError(try CompletionValidator().validate(
            action: fixture.action,
            package: fixture.package,
            evidence: [attestation],
            userResponses: []
        )) { error in
            guard let validationError = error as? CompletionValidationError,
                  case .wrongEvidenceKind = validationError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let unknown = try CompletionEvidence(
            metadata: metadata(CompletionEvidenceID(fixedUUID(85))),
            actionID: fixture.action.metadata.id,
            packageID: fixture.package.metadata.id,
            packageVersion: fixture.package.version,
            kind: .userAttestation,
            value: "Unrelated claim",
            capturedAt: now,
            criterionIDs: [fixedUUID(86)]
        )
        XCTAssertThrowsError(try CompletionValidator().validate(
            action: fixture.action,
            package: fixture.package,
            evidence: [unknown],
            userResponses: []
        )) { error in
            guard let validationError = error as? CompletionValidationError,
                  case .evidenceCriterionMismatch = validationError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testQuizResultBelowThresholdCannotCompleteAction() throws {
        let fixture = try makeFixture()
        let response = try makeResponse(
            fixture: fixture,
            selectedOptionID: fixture.wrongOptionID,
            responseID: UserResponseID(fixedUUID(87)),
            attemptID: fixedUUID(88)
        )
        let result = try QuizEvaluator().evaluate(
            quiz: fixture.quiz,
            packageID: fixture.package.metadata.id,
            packageVersion: fixture.package.version,
            responses: [response],
            scoredAt: now
        )
        let evidence = try makeQuizEvidence(
            fixture: fixture,
            result: result,
            evidenceID: CompletionEvidenceID(fixedUUID(89))
        )

        XCTAssertThrowsError(try CompletionValidator().validate(
            action: fixture.action,
            package: fixture.package,
            evidence: [evidence],
            userResponses: [response]
        )) { error in
            guard let validationError = error as? CompletionValidationError,
                  case let .belowThreshold(_, required, actual) = validationError
            else { return XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(required, 1)
            XCTAssertEqual(actual, 0)
        }
    }

    func testLegacyOpaqueQuizEvidenceLoadsButNeverPassesValidatorOrExecutionGate() throws {
        let fixture = try makeFixture()
        let legacy = try makeLegacyQuizEvidence(
            fixture: fixture,
            evidenceID: CompletionEvidenceID(fixedUUID(108))
        )
        XCTAssertFalse(legacy.hasReplayableQuizResult)
        XCTAssertEqual(
            try JSONDecoder().decode(
                CompletionEvidence.self,
                from: JSONEncoder().encode(legacy)
            ),
            legacy
        )

        XCTAssertThrowsError(try CompletionValidator().validate(
            action: fixture.action,
            package: fixture.package,
            evidence: [legacy],
            userResponses: []
        )) { error in
            guard let validationError = error as? CompletionValidationError,
                  case .unreplayableQuizEvidence = validationError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        var snapshot = fixture.snapshot
        snapshot.completionEvidence = [legacy]
        try snapshot.validateRelationships()
        XCTAssertThrowsError(try ExecutionService().completeAction(
            fixture.action.metadata.id,
            evidence: [legacy],
            in: snapshot,
            at: now.addingTimeInterval(60),
            progressSnapshotID: ProgressSnapshotID(fixedUUID(109)),
            originDeviceID: deviceID,
            currentDecision: nil
        )) { error in
            guard let serviceError = error as? ExecutionServiceError,
                  case let .completionRejected(validationError) = serviceError,
                  case .unreplayableQuizEvidence = validationError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(snapshot.dailyActions[0].status, .inProgress)
    }

    func testTypedQuizEvidenceSupersedesLegacyOpaqueRecordForTheSameCriterion() throws {
        let fixture = try makeFixture()
        let legacy = try makeLegacyQuizEvidence(
            fixture: fixture,
            evidenceID: CompletionEvidenceID(fixedUUID(118))
        )
        let response = try makeResponse(
            fixture: fixture,
            selectedOptionID: fixture.correctOptionID,
            responseID: UserResponseID(fixedUUID(119)),
            attemptID: fixedUUID(120)
        )
        let result = try QuizEvaluator().evaluate(
            quiz: fixture.quiz,
            packageID: fixture.package.metadata.id,
            packageVersion: fixture.package.version,
            responses: [response],
            scoredAt: now
        )
        let typed = try makeQuizEvidence(
            fixture: fixture,
            result: result,
            evidenceID: CompletionEvidenceID(fixedUUID(121))
        )
        var snapshot = fixture.snapshot
        snapshot.userResponses = [response]
        snapshot.completionEvidence = [legacy]
        try snapshot.validateRelationships()

        let completed = try ExecutionService().completeAction(
            fixture.action.metadata.id,
            evidence: [typed],
            in: snapshot,
            at: now.addingTimeInterval(60),
            progressSnapshotID: ProgressSnapshotID(fixedUUID(122)),
            originDeviceID: deviceID,
            currentDecision: nil
        )

        XCTAssertEqual(completed.dailyActions[0].status, .completed)
        XCTAssertEqual(
            Set(completed.completionEvidence.map(\.metadata.id)),
            Set([legacy.metadata.id, typed.metadata.id])
        )
    }

    func testExecutionServiceUnionsExistingAndNewEvidenceWithoutDuplicates() throws {
        let fixture = try makeFixture(includeAttestationCriterion: true)
        let response = try makeResponse(
            fixture: fixture,
            selectedOptionID: fixture.correctOptionID,
            responseID: UserResponseID(fixedUUID(90)),
            attemptID: fixedUUID(91)
        )
        let result = try QuizEvaluator().evaluate(
            quiz: fixture.quiz,
            packageID: fixture.package.metadata.id,
            packageVersion: fixture.package.version,
            responses: [response],
            scoredAt: now
        )
        let quizEvidence = try makeQuizEvidence(
            fixture: fixture,
            result: result,
            evidenceID: CompletionEvidenceID(fixedUUID(92))
        )
        let attestationCriterion = try XCTUnwrap(
            fixture.action.completionCriteria.first { $0.kind == .userAttestation }
        )
        let attestation = try CompletionEvidence(
            metadata: metadata(CompletionEvidenceID(fixedUUID(93))),
            actionID: fixture.action.metadata.id,
            packageID: fixture.package.metadata.id,
            packageVersion: fixture.package.version,
            kind: .userAttestation,
            value: "I reviewed the evidence-backed explanation.",
            capturedAt: now,
            criterionIDs: [attestationCriterion.id]
        )
        var snapshot = fixture.snapshot
        snapshot.userResponses = [response]
        snapshot.completionEvidence = [quizEvidence]
        try snapshot.validateRelationships()

        let completed = try ExecutionService().completeAction(
            fixture.action.metadata.id,
            evidence: [quizEvidence, attestation, attestation],
            in: snapshot,
            at: now.addingTimeInterval(60),
            progressSnapshotID: ProgressSnapshotID(fixedUUID(94)),
            originDeviceID: deviceID,
            currentDecision: nil
        )

        XCTAssertEqual(completed.dailyActions[0].status, .completed)
        XCTAssertEqual(completed.completionEvidence.count, 2)
        XCTAssertEqual(
            Set(completed.completionEvidence.map(\.metadata.id)),
            Set([quizEvidence.metadata.id, attestation.metadata.id])
        )
    }

    func testWorkspaceRejectsTamperedQuizGroundingQuoteHashAndPackageCriteria() throws {
        XCTAssertThrowsError(try makeFixture(tamperedLinkSubjectID: fixedUUID(95)))
        XCTAssertThrowsError(try makeFixture(tamperedLocatorQuote: true))

        let fixture = try makeFixture()
        var mismatched = fixture.snapshot
        let lowered = try CompletionCriterion(
            id: fixture.quizCriterion.id,
            kind: .quizScore,
            title: fixture.quizCriterion.title,
            threshold: 0.5
        )
        mismatched.guidedPackages[0].completionCriteria = [lowered]
        XCTAssertThrowsError(try mismatched.validateRelationships())

        var jointlyLowered = fixture.snapshot
        jointlyLowered.guidedPackages[0].completionCriteria = [lowered]
        jointlyLowered.dailyActions[0].completionCriteria = [lowered]
        XCTAssertThrowsError(try jointlyLowered.validateRelationships())

        let evidenceOptional = try CompletionCriterion(
            id: fixture.quizCriterion.id,
            kind: .quizScore,
            title: fixture.quizCriterion.title,
            threshold: 1,
            requiresEvidence: false,
            requiresUserConfirmation: false
        )
        var bypassed = fixture.snapshot
        bypassed.guidedPackages[0].completionCriteria = [evidenceOptional]
        bypassed.dailyActions[0].completionCriteria = [evidenceOptional]
        XCTAssertThrowsError(try bypassed.validateRelationships())
        XCTAssertThrowsError(try CompletionValidator().validate(
            action: bypassed.dailyActions[0],
            package: bypassed.guidedPackages[0],
            evidence: [],
            userResponses: []
        )) { error in
            XCTAssertEqual(error as? CompletionValidationError, .actionPackageMismatch)
        }

        var detached = fixture.snapshot
        detached.dailyActions[0].packageID = nil
        XCTAssertThrowsError(try detached.validateRelationships())
    }

    func testWorkspaceRejectsVerifiedQuizEvidenceFromUnrelatedSource() throws {
        let fixture = try makeFixture()
        let originalLink = try XCTUnwrap(fixture.snapshot.evidenceLinks.first)
        let missingSourceProvenanceLink = try EvidenceLink(
            metadata: metadata(
                originalLink.metadata.id,
                provenance: .deterministicEngine
            ),
            anchorID: originalLink.anchorID,
            relation: originalLink.relation,
            subjectType: originalLink.subjectType,
            subjectID: originalLink.subjectID,
            verificationMethod: originalLink.verificationMethod,
            verifiedBy: originalLink.verifiedBy
        )
        var missingSourceProvenance = fixture.snapshot
        missingSourceProvenance.evidenceLinks[0] = missingSourceProvenanceLink
        XCTAssertThrowsError(try missingSourceProvenance.validateRelationships())

        let unrelatedSourceID = SourceDocumentID(fixedUUID(106))
        let unrelatedAnchorID = SourceAnchorID(fixedUUID(107))
        let unrelatedSource = try SourceDocument(
            metadata: metadata(unrelatedSourceID, provenance: Provenance(
                kind: .importedSource,
                sourceDocumentIDs: [unrelatedSourceID]
            )),
            type: .pdf,
            displayTitle: "Unrelated but verified source",
            contentSHA256: String(repeating: "b", count: 64),
            rightsState: .userOwned,
            accessState: .localFullText,
            localRelativePath: "unrelated.pdf",
            accessedAt: now,
            verificationState: .contentHashVerified
        )
        let unrelatedAnchor = try SourceAnchor(
            metadata: metadata(unrelatedAnchorID, provenance: Provenance(
                kind: .deterministicEngine,
                sourceDocumentIDs: [unrelatedSourceID]
            )),
            sourceDocumentID: unrelatedSourceID,
            locator: .pdf(
                pageIndex: 0,
                normalizedRects: [],
                textQuote: fixture.correctOptionText
            ),
            quotedTextSHA256: sha256(fixture.correctOptionText),
            sourceRevision: 0,
            capturedAt: now,
            verificationState: .contentHashVerified
        )
        let unrelatedLink = try EvidenceLink(
            metadata: metadata(originalLink.metadata.id, provenance: Provenance(
                kind: .deterministicEngine,
                sourceDocumentIDs: [unrelatedSourceID]
            )),
            anchorID: unrelatedAnchorID,
            relation: .supports,
            subjectType: "QuizItem",
            subjectID: fixture.quiz.items[0].id.rawValue,
            verificationMethod: "Exact quote and SHA-256",
            verifiedBy: .deterministicEngine
        )

        var tampered = fixture.snapshot
        tampered.sourceDocuments.append(unrelatedSource)
        tampered.sourceAnchors.append(unrelatedAnchor)
        tampered.evidenceLinks[0] = unrelatedLink

        XCTAssertThrowsError(try tampered.validateRelationships())
    }

    func testGenericQuizKindsAndLegacyThresholdBypassStrictGroundingOnly() throws {
        let fixture = try makeFixture()
        let objectiveID = try XCTUnwrap(fixture.quiz.learningObjectiveIDs.first)
        let first = try QuizOption(id: fixedUUID(110), text: "Debt")
        let second = try QuizOption(id: fixedUUID(111), text: "Equity")
        let multipleChoice = try QuizItem(
            id: QuizItemID(fixedUUID(112)),
            kind: .multipleChoice,
            prompt: "Which legacy answers are accepted?",
            options: [first, second],
            correctOptionIDs: [first.id, second.id],
            answerExplanation: "Legacy generic MC could store more than one correct option.",
            objectiveID: objectiveID,
            evidenceLinkIDs: [EvidenceLinkID(fixedUUID(113))]
        )
        let multipleSelect = try QuizItem(
            id: QuizItemID(fixedUUID(114)),
            kind: .multipleSelect,
            prompt: "Select the capital sources.",
            options: [first, second],
            correctOptionIDs: [first.id, second.id],
            answerExplanation: "Both are capital sources.",
            objectiveID: objectiveID,
            evidenceLinkIDs: [EvidenceLinkID(fixedUUID(115))]
        )
        let shortAnswer = try QuizItem(
            id: QuizItemID(fixedUUID(116)),
            kind: .shortAnswer,
            prompt: "Explain the relationship.",
            answerExplanation: "A separate evaluator is required.",
            objectiveID: objectiveID,
            evidenceLinkIDs: [EvidenceLinkID(fixedUUID(117))]
        )
        let generic = try Quiz(
            metadata: fixture.quiz.metadata,
            learningObjectiveIDs: [objectiveID],
            items: [multipleChoice, multipleSelect, shortAnswer],
            passingFraction: 0,
            evaluationPolicy: .generic
        )

        var snapshot = fixture.snapshot
        snapshot.guidedPackages[0].quiz = generic
        XCTAssertNoThrow(try snapshot.validateRelationships())
        XCTAssertThrowsError(try QuizEvaluator().evaluate(
            quiz: generic,
            packageID: fixture.package.metadata.id,
            packageVersion: fixture.package.version,
            responses: [],
            scoredAt: now
        )) { error in
            guard let evaluationError = error as? QuizEvaluationError,
                  case .unsupportedEvaluationPolicy = evaluationError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testGuidedPackageDecodeCannotLowerQuizThreshold() throws {
        let fixture = try makeFixture()
        let encoded = try JSONEncoder().encode(fixture.package)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var criteria = try XCTUnwrap(root["completionCriteria"] as? [[String: Any]])
        criteria[0]["threshold"] = 0.5
        root["completionCriteria"] = criteria
        let tampered = try JSONSerialization.data(withJSONObject: root)

        XCTAssertThrowsError(try JSONDecoder().decode(
            GuidedLearningPackage.self,
            from: tampered
        ))

        var evidenceOptionalRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var evidenceOptionalCriteria = try XCTUnwrap(
            evidenceOptionalRoot["completionCriteria"] as? [[String: Any]]
        )
        evidenceOptionalCriteria[0]["requiresEvidence"] = false
        evidenceOptionalRoot["completionCriteria"] = evidenceOptionalCriteria
        let evidenceOptional = try JSONSerialization.data(
            withJSONObject: evidenceOptionalRoot
        )
        XCTAssertThrowsError(try JSONDecoder().decode(
            GuidedLearningPackage.self,
            from: evidenceOptional
        ))
    }

    func testQuizResponseAndResultEvidenceEnforceProvenanceRoles() throws {
        let fixture = try makeFixture()
        XCTAssertThrowsError(try UserResponse(
            metadata: metadata(
                UserResponseID(fixedUUID(96)),
                provenance: .deterministicEngine
            ),
            attemptID: fixedUUID(97),
            quizID: fixture.quiz.metadata.id,
            quizItemID: fixture.quiz.items[0].id,
            packageVersion: fixture.package.version,
            answer: fixture.correctOptionText,
            selectedOptionIDs: [fixture.correctOptionID],
            scoreFraction: 1,
            feedback: fixture.quiz.items[0].answerExplanation,
            attemptedAt: now
        ))

        let response = try makeResponse(
            fixture: fixture,
            selectedOptionID: fixture.correctOptionID,
            responseID: UserResponseID(fixedUUID(98)),
            attemptID: fixedUUID(99)
        )
        let result = try QuizEvaluator().evaluate(
            quiz: fixture.quiz,
            packageID: fixture.package.metadata.id,
            packageVersion: fixture.package.version,
            responses: [response],
            scoredAt: now
        )
        XCTAssertThrowsError(try CompletionEvidence(
            metadata: metadata(CompletionEvidenceID(fixedUUID(100))),
            actionID: fixture.action.metadata.id,
            packageID: fixture.package.metadata.id,
            packageVersion: fixture.package.version,
            quizResult: result,
            capturedAt: now,
            criterionIDs: [fixture.quizCriterion.id]
        ))
    }

    func testPlanningFingerprintCanonicalizesUserResponseOrder() throws {
        let fixture = try makeFixture()
        let first = try makeResponse(
            fixture: fixture,
            selectedOptionID: fixture.correctOptionID,
            responseID: UserResponseID(fixedUUID(101)),
            attemptID: fixedUUID(102)
        )
        let second = try makeResponse(
            fixture: fixture,
            selectedOptionID: fixture.wrongOptionID,
            responseID: UserResponseID(fixedUUID(103)),
            attemptID: fixedUUID(104)
        )
        var lhs = fixture.snapshot
        lhs.userResponses = [first, second]
        var rhs = fixture.snapshot
        rhs.userResponses = [second, first]
        let day = try LocalDay(year: 2027, month: 1, day: 15)
        let engine = PlanningEngine()
        let lhsDecision = try engine.plan(
            try PlanningInput(
                snapshot: lhs,
                horizonStart: day,
                horizonEnd: day,
                createdAt: now
            ),
            decisionID: PlanningDecisionID(fixedUUID(105)),
            originDeviceID: deviceID
        )
        let rhsDecision = try engine.plan(
            try PlanningInput(
                snapshot: rhs,
                horizonStart: day,
                horizonEnd: day,
                createdAt: now
            ),
            decisionID: PlanningDecisionID(fixedUUID(105)),
            originDeviceID: deviceID
        )
        XCTAssertEqual(lhsDecision.inputSnapshotSHA256, rhsDecision.inputSnapshotSHA256)
    }

    private struct Fixture {
        let snapshot: NextStepWorkspaceSnapshot
        let action: DailyAction
        let package: GuidedLearningPackage
        let quiz: Quiz
        let quizCriterion: CompletionCriterion
        let correctOptionID: UUID
        let wrongOptionID: UUID
        let correctOptionText: String
    }

    private func makeFixture(
        includeAttestationCriterion: Bool = false,
        tamperedLinkSubjectID: UUID? = nil,
        tamperedLocatorQuote: Bool = false
    ) throws -> Fixture {
        let ultimateID = UltimateGoalID(fixedUUID(10))
        let goalID = GoalID(fixedUUID(11))
        let milestoneID = MilestoneID(fixedUUID(12))
        let actionID = DailyActionID(fixedUUID(13))
        let packageID = GuidedLearningPackageID(fixedUUID(14))
        let sourceID = SourceDocumentID(fixedUUID(15))
        let anchorID = SourceAnchorID(fixedUUID(16))
        let itemID = QuizItemID(fixedUUID(17))
        let evidenceID = EvidenceLinkID(fixedUUID(18))
        let objectiveID = fixedUUID(19)
        let correctOptionID = fixedUUID(20)
        let wrongOptionID = fixedUUID(21)
        let quote = "Equity is a source of long-term capital."

        let quizCriterion = try CompletionCriterion(
            id: fixedUUID(22),
            kind: .quizScore,
            title: "Answer the grounded question correctly",
            threshold: 1
        )
        var criteria = [quizCriterion]
        if includeAttestationCriterion {
            criteria.append(try CompletionCriterion(
                id: fixedUUID(23),
                kind: .userAttestation,
                title: "Confirm review",
                requiresUserConfirmation: true
            ))
        }
        let output = try RequiredOutput(
            kind: .answer,
            title: "Grounded quiz response",
            validationKind: .quizThreshold
        )
        let profile = try UserProfile(
            metadata: metadata(UserProfileID(fixedUUID(2))),
            localeIdentifier: "en_US",
            timeZoneIdentifier: "UTC",
            weeklyAvailability: [try WeeklyAvailability(
                isoWeekday: 5,
                availableMinutes: 120
            )],
            onboardingState: .ready
        )
        let ultimate = try UltimateGoal(
            metadata: metadata(ultimateID),
            title: "Graduate",
            definitionOfDone: "Degree awarded"
        )
        let goal = try Goal(
            metadata: metadata(goalID),
            ultimateGoalID: ultimateID,
            title: "Learn finance",
            outcome: "Explain capital structure"
        )
        let milestone = try Milestone(
            metadata: metadata(milestoneID),
            goalID: goalID,
            title: "Understand equity",
            outcome: "Pass grounded assessment",
            completionCriteria: criteria
        )
        let document = try SourceDocument(
            metadata: metadata(sourceID, provenance: Provenance(
                kind: .importedSource,
                sourceDocumentIDs: [sourceID]
            )),
            type: .pdf,
            displayTitle: "Verified source",
            contentSHA256: String(repeating: "a", count: 64),
            rightsState: .userOwned,
            accessState: .localFullText,
            localRelativePath: "verified.pdf",
            accessedAt: now,
            verificationState: .contentHashVerified
        )
        let locatorQuote = tamperedLocatorQuote ? "\(quote) Tampered." : quote
        let anchor = try SourceAnchor(
            metadata: metadata(anchorID, provenance: .deterministicEngine),
            sourceDocumentID: sourceID,
            locator: .pdf(pageIndex: 0, normalizedRects: [], textQuote: locatorQuote),
            quotedTextSHA256: sha256(quote),
            sourceRevision: 0,
            capturedAt: now,
            verificationState: .contentHashVerified
        )
        let link = try EvidenceLink(
            metadata: metadata(evidenceID, provenance: Provenance(
                kind: .deterministicEngine,
                sourceDocumentIDs: [sourceID]
            )),
            anchorID: anchorID,
            relation: .supports,
            subjectType: "QuizItem",
            subjectID: tamperedLinkSubjectID ?? itemID.rawValue,
            verificationMethod: "Exact quote and SHA-256",
            verifiedBy: .deterministicEngine
        )
        let correct = try QuizOption(id: correctOptionID, text: quote)
        let wrong = try QuizOption(id: wrongOptionID, text: "Revenue is long-term capital.")
        let item = try QuizItem(
            id: itemID,
            kind: .multipleChoice,
            prompt: "Which statement is supported by the source?",
            options: [correct, wrong],
            correctOptionIDs: [correctOptionID],
            answerExplanation: "The verified quote states that equity is long-term capital.",
            objectiveID: objectiveID,
            evidenceLinkIDs: [evidenceID]
        )
        let quiz = try Quiz(
            metadata: metadata(QuizID(fixedUUID(24)), provenance: .deterministicEngine),
            learningObjectiveIDs: [objectiveID],
            items: [item],
            passingFraction: 1,
            evaluationPolicy: .groundedDeterministicSingleChoiceV1
        )
        let action = try DailyAction(
            metadata: metadata(actionID),
            milestoneID: milestoneID,
            title: "Complete grounded quiz",
            whyToday: "It verifies the prepared source.",
            estimatedMinutes: 15,
            difficulty: .introductory,
            requiredOutput: output,
            completionCriteria: criteria,
            packageID: packageID,
            sourceDocumentIDs: [sourceID],
            status: .inProgress
        )
        let objective = try LearningObjective(
            id: objectiveID,
            statement: "Identify the supported capital source.",
            successDescription: "Select the evidence-backed answer."
        )
        let reading = try SourceReading(
            sourceDocumentID: sourceID,
            anchorIDs: [anchorID],
            isRequired: true,
            rationale: "The quiz is derived from this exact quote.",
            accessState: .localFullText
        )
        let package = try GuidedLearningPackage(
            metadata: metadata(packageID, provenance: .deterministicEngine),
            version: 1,
            dailyActionID: actionID,
            ultimateGoalID: ultimateID,
            goalID: goalID,
            milestoneID: milestoneID,
            title: "Grounded equity lesson",
            whyToday: "The source is prepared and verified.",
            estimatedMinutes: 15,
            difficulty: .introductory,
            learningObjectives: [objective],
            prerequisites: [],
            sourceReadings: [reading],
            summary: quote,
            highlightIDs: [],
            corePoints: [try GroundedPoint(text: quote, evidenceLinkIDs: [evidenceID])],
            definitions: [],
            applications: [],
            limitationsAndRisks: [],
            knowledgeConceptIDs: [],
            guidedQuestions: [],
            quiz: quiz,
            requiredOutput: output,
            completionCriteria: criteria,
            nextStepTitle: "Apply the concept",
            generatedBy: .deterministicEngine,
            generatedAt: now
        )
        let snapshot = try NextStepWorkspaceSnapshot(
            savedAt: now,
            userProfile: profile,
            ultimateGoals: [ultimate],
            goals: [goal],
            milestones: [milestone],
            dailyActions: [action],
            guidedPackages: [package],
            sourceDocuments: [document],
            sourceAnchors: [anchor],
            evidenceLinks: [link]
        )
        return Fixture(
            snapshot: snapshot,
            action: action,
            package: package,
            quiz: quiz,
            quizCriterion: quizCriterion,
            correctOptionID: correctOptionID,
            wrongOptionID: wrongOptionID,
            correctOptionText: quote
        )
    }

    private func makeResponse(
        fixture: Fixture,
        selectedOptionID: UUID,
        responseID: UserResponseID,
        attemptID: UUID
    ) throws -> UserResponse {
        try QuizEvaluator().makeResponse(
            metadata: metadata(responseID),
            attemptID: attemptID,
            quiz: fixture.quiz,
            quizItemID: fixture.quiz.items[0].id,
            packageVersion: fixture.package.version,
            selectedOptionID: selectedOptionID,
            attemptedAt: now
        )
    }

    private func makeQuizEvidence(
        fixture: Fixture,
        result: QuizResultEvidence,
        evidenceID: CompletionEvidenceID
    ) throws -> CompletionEvidence {
        try CompletionEvidence(
            metadata: metadata(evidenceID, provenance: .deterministicEngine),
            actionID: fixture.action.metadata.id,
            packageID: fixture.package.metadata.id,
            packageVersion: fixture.package.version,
            quizResult: result,
            capturedAt: now,
            criterionIDs: [fixture.quizCriterion.id]
        )
    }

    private func makeLegacyQuizEvidence(
        fixture: Fixture,
        evidenceID: CompletionEvidenceID
    ) throws -> CompletionEvidence {
        let placeholder = try CompletionEvidence(
            metadata: metadata(evidenceID),
            actionID: fixture.action.metadata.id,
            packageID: fixture.package.metadata.id,
            packageVersion: fixture.package.version,
            kind: .userAttestation,
            value: "1.0 — legacy free-text score",
            capturedAt: now,
            criterionIDs: [fixture.quizCriterion.id]
        )
        let encoded = try JSONEncoder().encode(placeholder)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["kind"] = CompletionEvidenceKind.quizResult.rawValue
        object.removeValue(forKey: "measuredValue")
        object.removeValue(forKey: "quizResult")
        return try JSONDecoder().decode(
            CompletionEvidence.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    private func metadata<ID: Codable & Hashable & Sendable>(
        _ id: ID,
        provenance: Provenance = .user
    ) throws -> RecordMetadata<ID> {
        try RecordMetadata(
            id: id,
            createdAt: now,
            originDeviceID: deviceID,
            provenance: provenance
        )
    }

    private func fixedUUID(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    private func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
