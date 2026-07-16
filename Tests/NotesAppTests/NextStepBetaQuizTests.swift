import Foundation
import NextStepDomain
import NextStepPlanning
@testable import NotesApp
import XCTest

final class NextStepBetaQuizTests: XCTestCase {
    func testBuilderCreatesOneGroundedQuestionPerVerifiedExcerpt() throws {
        let fixture = try makeArchive()
        let package = try XCTUnwrap(fixture.workspace.guidedPackages.first)
        let quiz = try XCTUnwrap(package.quiz)
        let expected = [
            "Debt changes the capital structure.",
            "Evidence must remain traceable to its source.",
            "A daily action requires three verified points."
        ]

        XCTAssertEqual(quiz.items.count, expected.count)
        XCTAssertEqual(quiz.passingFraction, 1)
        XCTAssertEqual(quiz.evaluationPolicy, .groundedDeterministicSingleChoiceV1)
        for (index, item) in quiz.items.enumerated() {
            XCTAssertEqual(item.kind, .multipleChoice)
            XCTAssertEqual(item.options[index].text, expected[index])
            XCTAssertEqual(item.correctOptionIDs, [item.options[index].id])
            XCTAssertEqual(item.evidenceLinkIDs.count, 1)
            let link = try XCTUnwrap(fixture.workspace.evidenceLinks.first {
                $0.metadata.id == item.evidenceLinkIDs[0]
            })
            XCTAssertEqual(link.subjectType, "QuizItem")
            XCTAssertEqual(link.subjectID, item.id.rawValue)
            XCTAssertEqual(link.verifiedBy, .deterministicEngine)
        }
    }

    func testGraderPersistsAttemptIdentityAndProducesVerifiablePayload() throws {
        let fixture = try makeArchive()
        let package = try XCTUnwrap(fixture.workspace.guidedPackages.first)
        let quiz = try XCTUnwrap(package.quiz)
        let attemptID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let selections = Dictionary(uniqueKeysWithValues: quiz.items.map {
            ($0.id, Set($0.correctOptionIDs))
        })

        let summary = try NextStepBetaQuizGrader().grade(
            package: package,
            selections: selections,
            attemptID: attemptID,
            now: Date(timeIntervalSince1970: 1_750_000_100),
            deviceID: fixture.deviceID
        )

        XCTAssertTrue(summary.passed)
        XCTAssertEqual(summary.correctCount, quiz.items.count)
        XCTAssertEqual(summary.scoreFraction, 1)
        XCTAssertEqual(Set(summary.responses.map(\.attemptID)), Set([attemptID]))
        let payload = try QuizEvaluator().evaluate(
            quiz: quiz,
            packageID: package.metadata.id,
            packageVersion: package.version,
            responses: summary.responses,
            scoredAt: Date(timeIntervalSince1970: 1_750_000_100)
        )
        let encoded = try JSONEncoder().encode(payload)
        XCTAssertEqual(try JSONDecoder().decode(QuizResultEvidence.self, from: encoded), payload)
    }

    func testGraderRecordsFailureWithoutCallingAnAnswerCorrect() throws {
        let fixture = try makeArchive()
        let package = try XCTUnwrap(fixture.workspace.guidedPackages.first)
        let quiz = try XCTUnwrap(package.quiz)
        var selections = Dictionary(uniqueKeysWithValues: quiz.items.map {
            ($0.id, Set($0.correctOptionIDs))
        })
        let first = try XCTUnwrap(quiz.items.first)
        let wrong = try XCTUnwrap(first.options.first { option in
            first.correctOptionIDs.contains(option.id) == false
        })
        selections[first.id] = [wrong.id]

        let summary = try NextStepBetaQuizGrader().grade(
            package: package,
            selections: selections,
            attemptID: UUID(),
            now: Date(timeIntervalSince1970: 1_750_000_100),
            deviceID: fixture.deviceID
        )

        XCTAssertFalse(summary.passed)
        XCTAssertEqual(summary.correctCount, quiz.items.count - 1)
        XCTAssertEqual(
            summary.responses.first { $0.quizItemID == first.id }?.scoreFraction,
            0
        )
    }

    @MainActor
    func testModelStoresPassingResponsesAndRequiresBothCompletionCriteria() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nextstep-beta-quiz-model-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = Date(timeIntervalSince1970: 1_750_000_100)
        let archive = try makeArchive(now: timestamp)
        let store = NextStepBetaStore(rootURL: root)
        let model = NextStepBetaModel(
            store: store,
            importer: NextStepBetaSourceImporter(applicationSupportRoot: root),
            now: { timestamp },
            bootstrapArchive: archive
        )
        for _ in 0..<100 {
            if model.loadState != .loading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.loadState, .ready)

        let action = try XCTUnwrap(model.workspace?.dailyActions.first)
        let package = try XCTUnwrap(model.package(for: action))
        let quiz = try XCTUnwrap(package.quiz)
        await model.startAction(action.metadata.id)
        let selections = Dictionary(uniqueKeysWithValues: quiz.items.map {
            ($0.id, Set($0.correctOptionIDs))
        })
        await model.submitQuiz(for: action.metadata.id, selections: selections)
        await model.submitQuiz(for: action.metadata.id, selections: selections)

        XCTAssertTrue(model.hasPassingQuizEvidence(for: action.metadata.id))
        XCTAssertEqual(model.workspace?.userResponses.count, quiz.items.count)
        XCTAssertEqual(
            model.completionEvidence(for: action.metadata.id).filter {
                $0.kind == .quizResult
            }.count,
            1
        )

        await model.completeAction(
            action.metadata.id,
            evidenceText: "Verified point one\nVerified point two\nVerified point three"
        )
        XCTAssertEqual(model.action(id: action.metadata.id)?.status, .completed)
        XCTAssertEqual(
            Set(model.completionEvidence(for: action.metadata.id).map(\.kind)),
            Set([.quizResult, .userAttestation])
        )

        let restoredValue = try await store.load()
        let restored = try XCTUnwrap(restoredValue)
        XCTAssertEqual(restored.workspace.userResponses.count, quiz.items.count)
        XCTAssertEqual(
            restored.workspace.dailyActions.first?.status,
            .completed
        )
    }

    @MainActor
    func testModelPersistsFailedAttemptButDoesNotCreatePassingEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "nextstep-beta-quiz-failure-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let timestamp = Date(timeIntervalSince1970: 1_750_000_200)
        let archive = try makeArchive(now: timestamp)
        let store = NextStepBetaStore(rootURL: root)
        let model = NextStepBetaModel(
            store: store,
            importer: NextStepBetaSourceImporter(applicationSupportRoot: root),
            now: { timestamp },
            bootstrapArchive: archive
        )
        for _ in 0..<100 {
            if model.loadState != .loading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.loadState, .ready)

        let action = try XCTUnwrap(model.workspace?.dailyActions.first)
        let package = try XCTUnwrap(model.package(for: action))
        let quiz = try XCTUnwrap(package.quiz)
        await model.startAction(action.metadata.id)
        var selections = Dictionary(uniqueKeysWithValues: quiz.items.map {
            ($0.id, Set($0.correctOptionIDs))
        })
        let first = try XCTUnwrap(quiz.items.first)
        let wrong = try XCTUnwrap(first.options.first {
            first.correctOptionIDs.contains($0.id) == false
        })
        selections[first.id] = [wrong.id]
        await model.submitQuiz(for: action.metadata.id, selections: selections)

        XCTAssertFalse(model.hasPassingQuizEvidence(for: action.metadata.id))
        XCTAssertEqual(model.workspace?.userResponses.count, quiz.items.count)
        XCTAssertTrue(
            model.completionEvidence(for: action.metadata.id)
                .filter { $0.kind == .quizResult }
                .isEmpty
        )

        await model.completeAction(
            action.metadata.id,
            evidenceText: "Verified point one\nVerified point two\nVerified point three"
        )
        XCTAssertEqual(model.action(id: action.metadata.id)?.status, .inProgress)
        XCTAssertEqual(
            model.errorMessage,
            NextStepBetaQuizError.passingAttemptRequired.localizedDescription
        )
    }

    private func makeArchive(
        now: Date = Date(timeIntervalSince1970: 1_750_000_000)
    ) throws -> NextStepBetaArchive {
        let deviceID = DeviceID(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        var archive = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: now,
            deviceID: deviceID,
            timeZoneIdentifier: "Asia/Taipei"
        )
        archive = try NextStepBetaGoalBuilder().addGoal(
            title: "Complete the grounded Beta slice",
            deadline: try LocalDay(year: 2028, month: 6, day: 30),
            dailyMinutes: 35,
            to: archive,
            now: now
        )
        let documentID = SourceDocumentID(
            UUID(uuidString: "66666666-7777-8888-9999-aaaaaaaaaaaa")!
        )
        let document = try NextStepBetaSourceRecordBuilder().makeDocument(
            id: documentID,
            displayTitle: "verified.pdf",
            fileExtension: "pdf",
            relativePath: "Sources/\(documentID.description)/original.pdf",
            contentSHA256: String(repeating: "a", count: 64),
            now: now,
            deviceID: deviceID,
            parserVersion: "test-native-extract-v1"
        )
        return try NextStepBetaPackageBuilder().addImportedSource(
            NextStepBetaImportedSource(
                document: document,
                exactExtract: [
                    "Debt changes the capital structure.",
                    "Evidence must remain traceable to its source.",
                    "A daily action requires three verified points."
                ].joined(separator: "\n"),
                pageIndex: 0,
                usedVisionOCR: false,
                extractionNotice: nil
            ),
            to: archive,
            now: now
        )
    }
}
