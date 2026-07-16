import Foundation
@testable import NextStepDomain
import XCTest

final class DomainValidationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_782_835_200)
    private let deviceID = DeviceID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

    func testFactAuthorityRequiresGroundingOrConfidence() throws {
        let day = try LocalDay(year: 2026, month: 7, day: 15)

        XCTAssertThrowsError(try FactValue(
            value: day,
            authority: .sourceVerified,
            mutability: .immutable
        ))
        XCTAssertThrowsError(try FactValue(
            value: day,
            authority: .aiProposed,
            mutability: .confirmationRequired
        ))
        XCTAssertNoThrow(try FactValue(
            value: day,
            authority: .aiProposed,
            mutability: .confirmationRequired,
            confidence: 0.82
        ))
        XCTAssertNoThrow(try FactValue(
            value: day,
            authority: .userConfirmed,
            mutability: .immutable,
            confirmedAt: now
        ))
    }

    func testLocalDayUsesISOWeekdayAndCalendarSafeArithmetic() throws {
        let wednesday = try LocalDay(year: 2026, month: 7, day: 15)
        XCTAssertEqual(wednesday.isoWeekday, 3)
        XCTAssertEqual(try wednesday.adding(days: 1).description, "2026-07-16")
        XCTAssertEqual(wednesday.distance(to: try wednesday.adding(days: 7)), 7)
        XCTAssertThrowsError(try LocalDay(year: 2026, month: 2, day: 29))
    }

    func testLocalDayDecodingCannotBypassCalendarValidation() throws {
        let invalidDate = Data(#"{"year":2026,"month":2,"day":29}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(LocalDay.self, from: invalidDate))

        let validDate = Data(#"{"year":2028,"month":2,"day":29}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(LocalDay.self, from: validDate).description,
            "2028-02-29"
        )
    }

    func testImageAndScanLocatorRoundTripsWithZeroBasedPageAndRegion() throws {
        let region = try NormalizedRect(x: 0.1, y: 0.2, width: 0.7, height: 0.3)
        let locator = SourceLocator.image(
            pageIndex: 2,
            normalizedRegion: region,
            textQuote: "教授標記的掃描段落"
        )

        let data = try JSONEncoder().encode(locator)
        let decoded = try JSONDecoder().decode(SourceLocator.self, from: data)
        XCTAssertEqual(decoded, locator)

        guard case let .image(pageIndex, decodedRegion, quote) = decoded else {
            return XCTFail("Expected an image locator.")
        }
        XCTAssertEqual(pageIndex, 2)
        XCTAssertEqual(decodedRegion, region)
        XCTAssertEqual(quote, "教授標記的掃描段落")
    }

    func testImageLocatorRejectsInvalidPageOrEmptyRegionDuringConstructionAndDecode() throws {
        let region = try NormalizedRect(x: 0.1, y: 0.2, width: 0.7, height: 0.3)
        let invalidConstructed = SourceLocator.image(
            pageIndex: -1,
            normalizedRegion: region,
            textQuote: nil
        )
        XCTAssertThrowsError(try invalidConstructed.validate())
        XCTAssertThrowsError(try JSONEncoder().encode(invalidConstructed))

        let valid = SourceLocator.image(
            pageIndex: 0,
            normalizedRegion: region,
            textQuote: nil
        )
        let invalidPageData = try mutatedJSONObject(from: valid) { root in
            var image = try XCTUnwrap(root["image"] as? [String: Any])
            image["pageIndex"] = -1
            root["image"] = image
        }
        XCTAssertThrowsError(try JSONDecoder().decode(SourceLocator.self, from: invalidPageData))

        let emptyRegionData = try mutatedJSONObject(from: valid) { root in
            var image = try XCTUnwrap(root["image"] as? [String: Any])
            var normalizedRegion = try XCTUnwrap(
                image["normalizedRegion"] as? [String: Any]
            )
            normalizedRegion["width"] = 0
            image["normalizedRegion"] = normalizedRegion
            root["image"] = image
        }
        XCTAssertThrowsError(try JSONDecoder().decode(SourceLocator.self, from: emptyRegionData))
    }

    func testDeadlineFactDecodingCannotBypassAuthorityInvariants() throws {
        let valid = try FactValue(
            value: try LocalDay(year: 2026, month: 7, day: 30),
            authority: .userConfirmed,
            mutability: .immutable,
            confirmedAt: now
        )
        let missingConfirmation = try mutatedJSONObject(from: valid) { root in
            root.removeValue(forKey: "confirmedAt")
        }

        XCTAssertThrowsError(try JSONDecoder().decode(
            FactValue<LocalDay>.self,
            from: missingConfirmation
        ))
    }

    func testSourceAnchorAndCitationDecodingCannotBypassValidation() throws {
        let anchorID = SourceAnchorID(
            UUID(uuidString: "00000000-0000-0000-0000-000000000050")!
        )
        let sourceDocumentID = SourceDocumentID(
            UUID(uuidString: "00000000-0000-0000-0000-000000000051")!
        )
        let anchor = try SourceAnchor(
            metadata: metadata(anchorID),
            sourceDocumentID: sourceDocumentID,
            locator: .image(
                pageIndex: 0,
                normalizedRegion: try NormalizedRect(
                    x: 0.1,
                    y: 0.1,
                    width: 0.8,
                    height: 0.2
                ),
                textQuote: "Verified passage"
            ),
            quotedTextSHA256: String(repeating: "a", count: 64),
            sourceRevision: 1,
            capturedAt: now,
            verificationState: .contentHashVerified
        )
        let invalidAnchorData = try mutatedJSONObject(from: anchor) { root in
            root["quotedTextSHA256"] = "not-a-sha256"
            root["sourceRevision"] = -1
        }
        XCTAssertThrowsError(try JSONDecoder().decode(SourceAnchor.self, from: invalidAnchorData))

        let citation = try Citation(
            metadata: metadata(CitationID(
                UUID(uuidString: "00000000-0000-0000-0000-000000000052")!
            )),
            sourceDocumentID: sourceDocumentID,
            anchorIDs: [anchorID],
            citedClaim: "The cited claim is traceable.",
            context: "Literature review"
        )
        let invalidCitationData = try mutatedJSONObject(from: citation) { root in
            root["anchorIDs"] = []
        }
        XCTAssertThrowsError(try JSONDecoder().decode(Citation.self, from: invalidCitationData))
    }

    func testDailyActionDecodingCannotCreateAnUnscheduledLockedDeadline() throws {
        let criterion = try CompletionCriterion(
            kind: .outputExists,
            title: "A draft exists"
        )
        let output = try RequiredOutput(
            kind: .draft,
            title: "Draft",
            validationKind: .exists
        )
        let action = try DailyAction(
            metadata: metadata(DailyActionID()),
            milestoneID: MilestoneID(),
            title: "Write draft",
            whyToday: "The confirmed deadline is approaching.",
            estimatedMinutes: 30,
            difficulty: .moderate,
            deadline: try FactValue(
                value: try LocalDay(year: 2026, month: 7, day: 30),
                authority: .userConfirmed,
                mutability: .immutable,
                confirmedAt: now
            ),
            requiredOutput: output,
            completionCriteria: [criterion]
        )
        let invalidData = try mutatedJSONObject(from: action) { root in
            root["flexibility"] = ActionFlexibility.locked.rawValue
            root.removeValue(forKey: "scheduledDay")
        }

        XCTAssertThrowsError(try JSONDecoder().decode(DailyAction.self, from: invalidData))
    }

    func testCompletionCriterionRejectsThresholdsThatDoNotMatchItsKind() throws {
        XCTAssertThrowsError(try CompletionCriterion(
            kind: .quizScore,
            title: "Score at least 80%",
            threshold: 1.01
        ))
        XCTAssertThrowsError(try CompletionCriterion(
            kind: .minimumWordCount,
            title: "Write at least 250 words",
            threshold: 250.5
        ))
        XCTAssertThrowsError(try CompletionCriterion(
            kind: .outputExists,
            title: "A draft exists",
            threshold: 1
        ))

        let quizCriterion = try CompletionCriterion(
            kind: .quizScore,
            title: "Score at least 80%",
            threshold: 0.8
        )
        let invalidQuizThreshold = try mutatedJSONObject(from: quizCriterion) { root in
            root["threshold"] = 1.01
        }
        XCTAssertThrowsError(try JSONDecoder().decode(
            CompletionCriterion.self,
            from: invalidQuizThreshold
        ))

        let wordCountCriterion = try CompletionCriterion(
            kind: .minimumWordCount,
            title: "Write at least 250 words",
            threshold: 250
        )
        let fractionalWordCount = try mutatedJSONObject(from: wordCountCriterion) { root in
            root["threshold"] = 250.5
        }
        XCTAssertThrowsError(try JSONDecoder().decode(
            CompletionCriterion.self,
            from: fractionalWordCount
        ))

        let outputCriterion = try CompletionCriterion(
            kind: .outputExists,
            title: "A draft exists"
        )
        let irrelevantThreshold = try mutatedJSONObject(from: outputCriterion) { root in
            root["threshold"] = 1
        }
        XCTAssertThrowsError(try JSONDecoder().decode(
            CompletionCriterion.self,
            from: irrelevantThreshold
        ))
    }

    func testGenericQuizPreservesLegacyMultipleCorrectChoiceWhileStrictPolicyRejectsIt() throws {
        let objectiveID = UUID()
        let optionA = try QuizOption(text: "Assets")
        let optionB = try QuizOption(text: "Liabilities")
        let evidenceLinkID = EvidenceLinkID()

        let legacyItem = try QuizItem(
            kind: .multipleChoice,
            prompt: "Which item belongs on the balance sheet?",
            options: [optionA, optionB],
            correctOptionIDs: [optionA.id, optionB.id],
            answerExplanation: "Both are balance-sheet categories, so the question needs one answer.",
            objectiveID: objectiveID,
            evidenceLinkIDs: [evidenceLinkID]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                QuizItem.self,
                from: JSONEncoder().encode(legacyItem)
            ),
            legacyItem
        )

        let generic = try Quiz(
            metadata: metadata(QuizID()),
            learningObjectiveIDs: [objectiveID],
            items: [legacyItem],
            passingFraction: 0
        )
        XCTAssertEqual(generic.evaluationPolicy, .generic)
        let legacyQuizJSON = try mutatedJSONObject(from: generic) { root in
            root.removeValue(forKey: "evaluationPolicy")
        }
        let decodedLegacyQuiz = try JSONDecoder().decode(Quiz.self, from: legacyQuizJSON)
        XCTAssertEqual(decodedLegacyQuiz.evaluationPolicy, .generic)
        XCTAssertEqual(decodedLegacyQuiz.items[0].correctOptionIDs.count, 2)

        XCTAssertNoThrow(try CompletionCriterion(
            kind: .quizScore,
            title: "Legacy generic quiz without a deterministic gate"
        ))
        XCTAssertNoThrow(try CompletionCriterion(
            kind: .quizScore,
            title: "Legacy generic zero threshold",
            threshold: 0
        ))

        XCTAssertThrowsError(try Quiz(
            metadata: metadata(QuizID()),
            learningObjectiveIDs: [objectiveID],
            items: [legacyItem],
            passingFraction: 1,
            evaluationPolicy: .groundedDeterministicSingleChoiceV1
        ))
    }

    func testQuizDecodingCannotBypassInitializerValidation() throws {
        let objectiveID = UUID()
        let optionA = try QuizOption(text: "Equity")
        let optionB = try QuizOption(text: "Revenue")
        let item = try QuizItem(
            kind: .multipleChoice,
            prompt: "Which item is part of capital structure?",
            options: [optionA, optionB],
            correctOptionIDs: [optionA.id],
            answerExplanation: "Equity is a source of long-term capital.",
            objectiveID: objectiveID,
            evidenceLinkIDs: [EvidenceLinkID()]
        )
        let quiz = try Quiz(
            metadata: metadata(QuizID()),
            learningObjectiveIDs: [objectiveID],
            items: [item],
            passingFraction: 0.8
        )

        let legacyWithoutPolicy = try mutatedJSONObject(from: quiz) { root in
            root.removeValue(forKey: "evaluationPolicy")
        }
        XCTAssertEqual(
            try JSONDecoder().decode(Quiz.self, from: legacyWithoutPolicy).evaluationPolicy,
            .generic
        )

        let outOfRangePassingFraction = try mutatedJSONObject(from: quiz) { root in
            root["passingFraction"] = 1.2
        }
        XCTAssertThrowsError(try JSONDecoder().decode(
            Quiz.self,
            from: outOfRangePassingFraction
        ))

        let danglingObjective = try mutatedJSONObject(from: quiz) { root in
            root["learningObjectiveIDs"] = [UUID().uuidString]
        }
        XCTAssertThrowsError(try JSONDecoder().decode(
            Quiz.self,
            from: danglingObjective
        ))
    }

    func testGenericQuizPreservesMultipleSelectAndShortAnswerKinds() throws {
        let objectiveID = UUID()
        let optionA = try QuizOption(text: "Debt")
        let optionB = try QuizOption(text: "Equity")
        let multipleSelect = try QuizItem(
            kind: .multipleSelect,
            prompt: "Select the capital sources.",
            options: [optionA, optionB],
            correctOptionIDs: [optionA.id, optionB.id],
            answerExplanation: "Both are capital sources.",
            objectiveID: objectiveID,
            evidenceLinkIDs: [EvidenceLinkID()]
        )
        let shortAnswer = try QuizItem(
            kind: .shortAnswer,
            prompt: "Explain capital structure.",
            answerExplanation: "A free-text answer requires a separate evaluator.",
            objectiveID: objectiveID,
            evidenceLinkIDs: [EvidenceLinkID()]
        )
        let quiz = try Quiz(
            metadata: metadata(QuizID()),
            learningObjectiveIDs: [objectiveID],
            items: [multipleSelect, shortAnswer],
            passingFraction: 0.8
        )

        let decoded = try JSONDecoder().decode(
            Quiz.self,
            from: JSONEncoder().encode(quiz)
        )
        XCTAssertEqual(decoded.evaluationPolicy, .generic)
        XCTAssertEqual(decoded.items.map(\.kind), [.multipleSelect, .shortAnswer])
    }

    func testLegacyOpaqueQuizEvidenceDecodesAndRoundTripsWithoutBecomingReplayable() throws {
        let packageID = GuidedLearningPackageID()
        let baseline = try CompletionEvidence(
            metadata: metadata(CompletionEvidenceID()),
            actionID: DailyActionID(),
            packageID: packageID,
            packageVersion: 1,
            kind: .userAttestation,
            value: "1.0 — legacy caller claimed a passing score",
            capturedAt: now,
            criterionIDs: [UUID()]
        )
        let legacyJSON = try mutatedJSONObject(from: baseline) { root in
            root["kind"] = CompletionEvidenceKind.quizResult.rawValue
            root.removeValue(forKey: "measuredValue")
            root.removeValue(forKey: "quizResult")
        }

        let decoded = try JSONDecoder().decode(CompletionEvidence.self, from: legacyJSON)
        XCTAssertEqual(decoded.kind, .quizResult)
        XCTAssertNil(decoded.quizResult)
        XCTAssertNil(decoded.measuredValue)
        XCTAssertFalse(decoded.hasReplayableQuizResult)

        let roundTripped = try JSONDecoder().decode(
            CompletionEvidence.self,
            from: JSONEncoder().encode(decoded)
        )
        XCTAssertEqual(roundTripped, decoded)
        XCTAssertFalse(roundTripped.hasReplayableQuizResult)
    }

    func testUserResponseAttemptRoundTripsAndDecodeCannotBypassValidation() throws {
        let attemptID = UUID()
        let response = try UserResponse(
            metadata: metadata(UserResponseID()),
            attemptID: attemptID,
            quizID: QuizID(),
            quizItemID: QuizItemID(),
            packageVersion: 1,
            answer: "Equity",
            selectedOptionIDs: [UUID()],
            scoreFraction: 1,
            feedback: "Correct",
            attemptedAt: now
        )

        let encoded = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(UserResponse.self, from: encoded)
        XCTAssertEqual(decoded.attemptID, attemptID)

        let invalidPackageVersion = try mutatedJSONObject(from: response) { root in
            root["packageVersion"] = 0
        }
        XCTAssertThrowsError(try JSONDecoder().decode(
            UserResponse.self,
            from: invalidPackageVersion
        ))

        let invalidScore = try mutatedJSONObject(from: response) { root in
            root["scoreFraction"] = 1.2
        }
        XCTAssertThrowsError(try JSONDecoder().decode(
            UserResponse.self,
            from: invalidScore
        ))
    }

    func testWorkspaceV1WithoutUserResponsesDecodesAsEmpty() throws {
        let workspace = try NextStepWorkspaceSnapshot(
            savedAt: now,
            userProfile: makeProfile()
        )
        let legacyV1 = try mutatedJSONObject(from: workspace) { root in
            root.removeValue(forKey: "userResponses")
        }

        let decoded = try JSONDecoder().decode(
            NextStepWorkspaceSnapshot.self,
            from: legacyV1
        )

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertTrue(decoded.userResponses.isEmpty)
    }

    func testWorkspaceRejectsDanglingGoalRelationship() throws {
        let profile = try makeProfile()
        let ultimateGoal = try UltimateGoal(
            metadata: metadata(UltimateGoalID(
                UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
            )),
            title: "Graduate",
            definitionOfDone: "Degree awarded"
        )
        let danglingGoal = try Goal(
            metadata: metadata(GoalID(
                UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
            )),
            ultimateGoalID: UltimateGoalID(
                UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
            ),
            title: "Finish semester",
            outcome: "All credits completed"
        )

        XCTAssertThrowsError(try NextStepWorkspaceSnapshot(
            savedAt: now,
            userProfile: profile,
            ultimateGoals: [ultimateGoal],
            goals: [danglingGoal]
        ))
    }

    func testLockedActionRequiresAConcreteDay() throws {
        let criterion = try CompletionCriterion(
            kind: .outputExists,
            title: "A draft exists"
        )
        let output = try RequiredOutput(
            kind: .draft,
            title: "Draft",
            validationKind: .exists
        )
        XCTAssertThrowsError(try DailyAction(
            metadata: metadata(DailyActionID()),
            milestoneID: MilestoneID(),
            title: "Write draft",
            whyToday: "The confirmed submission is approaching.",
            estimatedMinutes: 30,
            difficulty: .moderate,
            flexibility: .locked,
            requiredOutput: output,
            completionCriteria: [criterion]
        ))
    }

    private func makeProfile() throws -> UserProfile {
        try UserProfile(
            metadata: metadata(UserProfileID(
                UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            )),
            localeIdentifier: "zh_TW",
            timeZoneIdentifier: "Asia/Taipei",
            weeklyAvailability: [
                try WeeklyAvailability(isoWeekday: 3, availableMinutes: 90)
            ],
            onboardingState: .ready
        )
    }

    private func metadata<ID>(_ id: ID) throws -> RecordMetadata<ID>
    where ID: Codable & Hashable & Sendable {
        try RecordMetadata(
            id: id,
            createdAt: now,
            originDeviceID: deviceID
        )
    }

    private func mutatedJSONObject<Value: Encodable>(
        from value: Value,
        mutate: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        let encoded = try JSONEncoder().encode(value)
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        try mutate(&root)
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}
