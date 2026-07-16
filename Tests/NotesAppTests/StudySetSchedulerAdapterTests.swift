import Foundation
import NotesCore
import NotesServices
@testable import NotesApp
import XCTest

final class StudySetSchedulerAdapterTests: XCTestCase {
    func testProgressMappingRoundTripsEverySchedulerField() {
        let cardID = StudyCardID()
        let dueAt = Date(timeIntervalSince1970: 1_750_000_000)
        let reviewedAt = dueAt.addingTimeInterval(-86_400)
        let durable = NotesCore.StudyCardProgress(
            cardID: cardID,
            repetitions: 7,
            lapses: 2,
            intervalDays: 31,
            easeFactor: 2.35,
            dueAt: dueAt,
            lastReviewedAt: reviewedAt
        )

        let service = StudySetSchedulerAdapter.serviceProgress(from: durable)
        XCTAssertEqual(service.repetitions, durable.repetitions)
        XCTAssertEqual(service.lapses, durable.lapses)
        XCTAssertEqual(service.intervalDays, durable.intervalDays)
        XCTAssertEqual(service.easeFactor, durable.easeFactor)
        XCTAssertEqual(service.dueAt, durable.dueAt)
        XCTAssertEqual(service.lastReviewedAt, durable.lastReviewedAt)

        let restored = StudySetSchedulerAdapter.coreProgress(
            cardID: cardID,
            from: service
        )
        XCTAssertEqual(restored, durable)
    }

    func testNormalizationRepairsIdentityProgressAndMetadataInvariants() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let firstID = StudyCardID()
        let secondID = StudyCardID()
        let orphanID = StudyCardID()
        let olderReview = now.addingTimeInterval(-300)
        let newerReview = now.addingTimeInterval(-100)

        let first = StudyCard(
            id: firstID,
            prompt: "Capital of Japan?",
            answer: "Tokyo",
            hint: "   ",
            tags: [" Geography ", "geography", "", "Asia"]
        )
        let duplicateIdentity = StudyCard(
            id: firstID,
            prompt: "This duplicate must be discarded",
            answer: "Duplicate"
        )
        let second = StudyCard(id: secondID, prompt: "2 + 2", answer: "4")
        let olderProgress = NotesCore.StudyCardProgress(
            cardID: firstID,
            repetitions: 8,
            lapses: 1,
            intervalDays: 20,
            easeFactor: 2.4,
            dueAt: now,
            lastReviewedAt: olderReview
        )
        let newerInvalidProgress = NotesCore.StudyCardProgress(
            cardID: firstID,
            repetitions: -4,
            lapses: -3,
            intervalDays: -2,
            easeFactor: .infinity,
            dueAt: Date(timeIntervalSinceReferenceDate: .infinity),
            lastReviewedAt: newerReview
        )
        let orphanProgress = NotesCore.StudyCardProgress(
            cardID: orphanID,
            repetitions: 1,
            dueAt: now
        )

        let normalized = StudySetSchedulerAdapter.normalized(
            StudySet(
                schemaVersion: 999,
                cards: [first, duplicateIdentity, second],
                progress: [olderProgress, orphanProgress, newerInvalidProgress]
            ),
            now: now
        )

        XCTAssertEqual(normalized.schemaVersion, StudySet.currentSchemaVersion)
        XCTAssertEqual(normalized.cards.map(\.id), [firstID, secondID])
        XCTAssertEqual(normalized.cards.first?.prompt, first.prompt)
        XCTAssertNil(normalized.cards.first?.hint)
        XCTAssertEqual(normalized.cards.first?.tags, ["Geography", "Asia"])

        let progress = try XCTUnwrap(normalized.progress.first)
        XCTAssertEqual(normalized.progress.count, 1)
        XCTAssertEqual(progress.cardID, firstID)
        XCTAssertEqual(progress.repetitions, 0)
        XCTAssertEqual(progress.lapses, 0)
        XCTAssertEqual(progress.intervalDays, 0)
        XCTAssertEqual(progress.easeFactor, 2.5)
        XCTAssertEqual(progress.dueAt, now)
        XCTAssertEqual(progress.lastReviewedAt, newerReview)
    }

    func testNormalizationClampsPersistedSchedulerBoundsAndCardDates() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let createdAt = now.addingTimeInterval(60)
        let card = StudyCard(
            prompt: "Bounded",
            answer: "Safe",
            createdAt: createdAt,
            modifiedAt: now
        )
        let progress = NotesCore.StudyCardProgress(
            cardID: card.id,
            repetitions: Int.max,
            lapses: Int.max,
            intervalDays: Int.max,
            easeFactor: 100,
            dueAt: now
        )

        let normalized = StudySetSchedulerAdapter.normalized(
            StudySet(cards: [card], progress: [progress]),
            now: now
        )

        XCTAssertEqual(try XCTUnwrap(normalized.cards.first).modifiedAt, createdAt)
        let bounded = try XCTUnwrap(normalized.progress.first)
        XCTAssertEqual(bounded.repetitions, 1_000_000)
        XCTAssertEqual(bounded.lapses, 1_000_000)
        XCTAssertEqual(bounded.intervalDays, 36_500)
        XCTAssertEqual(bounded.easeFactor, 3.2)
    }

    func testReviewQueueContainsOnlyCompleteDueCardsInDueOrder() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let newCard = StudyCard(prompt: "New", answer: "Ready")
        let overdueCard = StudyCard(prompt: "Overdue", answer: "Ready")
        let futureCard = StudyCard(prompt: "Future", answer: "Ready")
        let missingPrompt = StudyCard(prompt: "   ", answer: "Not ready")
        let missingAnswer = StudyCard(prompt: "Not ready", answer: "\n")
        let set = StudySet(
            cards: [overdueCard, futureCard, missingPrompt, newCard, missingAnswer],
            progress: [
                NotesCore.StudyCardProgress(
                    cardID: overdueCard.id,
                    dueAt: now.addingTimeInterval(-600)
                ),
                NotesCore.StudyCardProgress(
                    cardID: futureCard.id,
                    dueAt: now.addingTimeInterval(600)
                ),
            ]
        )

        let queue = StudySetSchedulerAdapter.reviewQueue(in: set, now: now)

        XCTAssertEqual(queue.map(\.id), [newCard.id, overdueCard.id])
        XCTAssertTrue(queue.allSatisfy(StudySetSchedulerAdapter.isComplete))
    }

    func testApplyingGradeMatchesServiceSchedulerAndUpsertsProgress() throws {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let card = StudyCard(prompt: "Question", answer: "Answer")
        let set = StudySet(cards: [card])
        let expected = StudyScheduler.review(
            NotesServices.StudyProgress(dueAt: now),
            grade: .good,
            now: now,
            calendar: calendar
        )

        let updated = StudySetSchedulerAdapter.applying(
            grade: .good,
            to: card.id,
            in: set,
            now: now,
            calendar: calendar
        )

        let durable = try XCTUnwrap(updated.progress.first)
        XCTAssertEqual(updated.progress.count, 1)
        XCTAssertEqual(durable.cardID, card.id)
        XCTAssertEqual(
            StudySetSchedulerAdapter.serviceProgress(from: durable),
            expected
        )
    }

    func testApplyingGradeDoesNotCreateProgressForIncompleteCard() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let card = StudyCard(prompt: "Question", answer: "   ")

        let updated = StudySetSchedulerAdapter.applying(
            grade: .easy,
            to: card.id,
            in: StudySet(cards: [card]),
            now: now
        )

        XCTAssertTrue(updated.progress.isEmpty)
    }

    func testTagParsingTrimsAndDeduplicatesWithoutChangingOrder() {
        XCTAssertEqual(
            StudySetSchedulerAdapter.tags(from: " Biology, exam,biology, , EXAM, Week 1 "),
            ["Biology", "exam", "Week 1"]
        )
    }

    func testTagParsingHonorsDurableTagLimit() {
        let rawTags = (0 ... StudySetSchedulerAdapter.maximumTagsPerCard)
            .map { "tag-\($0)" }
            .joined(separator: ",")

        let tags = StudySetSchedulerAdapter.tags(from: rawTags)

        XCTAssertEqual(tags.count, StudySetSchedulerAdapter.maximumTagsPerCard)
        XCTAssertEqual(tags.first, "tag-0")
        XCTAssertEqual(tags.last, "tag-99")
    }
}
