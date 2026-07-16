import Foundation
import NotesCore
import NotesServices

/// Keeps the persisted study-set model independent from the scheduling engine.
/// Every conversion is explicit so adding scheduler-only state cannot silently
/// change the on-disk `NotesCore` schema.
enum StudySetSchedulerAdapter {
    static let maximumCardCount = 25_000
    static let maximumTagsPerCard = 100
    private static let maximumStudyCounter = 1_000_000
    private static let maximumStudyIntervalDays = 36_500

    static func serviceProgress(
        from progress: NotesCore.StudyCardProgress
    ) -> NotesServices.StudyProgress {
        NotesServices.StudyProgress(
            repetitions: progress.repetitions,
            lapses: progress.lapses,
            intervalDays: progress.intervalDays,
            easeFactor: progress.easeFactor,
            dueAt: progress.dueAt,
            lastReviewedAt: progress.lastReviewedAt
        )
    }

    static func coreProgress(
        cardID: StudyCardID,
        from progress: NotesServices.StudyProgress
    ) -> NotesCore.StudyCardProgress {
        NotesCore.StudyCardProgress(
            cardID: cardID,
            repetitions: progress.repetitions,
            lapses: progress.lapses,
            intervalDays: progress.intervalDays,
            easeFactor: progress.easeFactor,
            dueAt: progress.dueAt,
            lastReviewedAt: progress.lastReviewedAt
        )
    }

    /// Repairs invariants that can be broken by an interrupted edit or by
    /// importing older content. Card text is deliberately not trimmed because
    /// whitespace can be meaningful while the user is editing it.
    static func normalized(
        _ studySet: StudySet,
        now: Date = .now
    ) -> StudySet {
        var seenCardIDs = Set<StudyCardID>()
        let cards = studySet.cards.compactMap { card -> StudyCard? in
            guard seenCardIDs.insert(card.id).inserted else { return nil }

            var normalizedCard = card
            normalizedCard.schemaVersion = StudyCard.currentSchemaVersion
            normalizedCard.tags = normalizedTags(card.tags)
            if card.hint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                normalizedCard.hint = nil
            }
            if !isFinite(card.createdAt) {
                normalizedCard.createdAt = now
            }
            if !isFinite(card.modifiedAt) || card.modifiedAt < normalizedCard.createdAt {
                normalizedCard.modifiedAt = normalizedCard.createdAt
            }
            return normalizedCard
        }

        let validCardIDs = Set(cards.map(\.id))
        var progressByCardID: [StudyCardID: StudyCardProgress] = [:]
        for progress in studySet.progress where validCardIDs.contains(progress.cardID) {
            let candidate = normalized(progress, now: now)
            guard let existing = progressByCardID[progress.cardID] else {
                progressByCardID[progress.cardID] = candidate
                continue
            }

            // Prefer the most recently reviewed duplicate. If neither (or both)
            // has a review timestamp, the later serialized value wins.
            let existingReview = existing.lastReviewedAt ?? .distantPast
            let candidateReview = candidate.lastReviewedAt ?? .distantPast
            if candidateReview >= existingReview {
                progressByCardID[progress.cardID] = candidate
            }
        }

        return StudySet(
            schemaVersion: StudySet.currentSchemaVersion,
            cards: cards,
            progress: cards.compactMap { progressByCardID[$0.id] }
        )
    }

    static func isComplete(_ card: StudyCard) -> Bool {
        !card.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !card.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func completeCards(in studySet: StudySet) -> [StudyCard] {
        normalized(studySet).cards.filter(isComplete)
    }

    /// Returns only complete cards that are due. New cards have no progress and
    /// are therefore immediately due. Equal due dates retain the card order.
    static func reviewQueue(
        in studySet: StudySet,
        now: Date = .now
    ) -> [StudyCard] {
        let studySet = normalized(studySet, now: now)
        let progressByCardID = Dictionary(
            uniqueKeysWithValues: studySet.progress.map { ($0.cardID, $0) }
        )

        let dueCards: [(index: Int, dueAt: Date, card: StudyCard)] =
            studySet.cards.enumerated().compactMap { entry -> (index: Int, dueAt: Date, card: StudyCard)? in
                let (index, card) = entry
                guard isComplete(card) else { return nil }
                let dueAt = progressByCardID[card.id]?.dueAt ?? .distantPast
                guard dueAt <= now else { return nil }
                return (index: index, dueAt: dueAt, card: card)
            }

        return dueCards
        .sorted { lhs, rhs in
            if lhs.dueAt == rhs.dueAt { return lhs.index < rhs.index }
            return lhs.dueAt < rhs.dueAt
        }
        .map(\.card)
    }

    /// Applies one review through `NotesServices.StudyScheduler` and upserts the
    /// resulting durable progress. Incomplete cards cannot acquire progress.
    static func applying(
        grade: StudyGrade,
        to cardID: StudyCardID,
        in studySet: StudySet,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> StudySet {
        var updated = normalized(studySet, now: now)
        guard let card = updated.cards.first(where: { $0.id == cardID }),
              isComplete(card) else {
            return updated
        }

        let current = updated.progress.first(where: { $0.cardID == cardID })
            .map(serviceProgress)
            ?? NotesServices.StudyProgress(dueAt: now)
        let reviewed = StudyScheduler.review(
            current,
            grade: grade,
            now: now,
            calendar: calendar
        )
        let durable = coreProgress(cardID: cardID, from: reviewed)

        if let index = updated.progress.firstIndex(where: { $0.cardID == cardID }) {
            updated.progress[index] = durable
        } else {
            updated.progress.append(durable)
        }
        return normalized(updated, now: now)
    }

    static func tags(from text: String) -> [String] {
        normalizedTags(text.split(separator: ",", omittingEmptySubsequences: false).map(String.init))
    }

    private static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        var normalized: [String] = []
        normalized.reserveCapacity(min(tags.count, maximumTagsPerCard))
        for rawTag in tags {
            let tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty else { continue }
            let comparisonKey = tag.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            guard seen.insert(comparisonKey).inserted else { continue }
            normalized.append(tag)
            if normalized.count == maximumTagsPerCard { break }
        }
        return normalized
    }

    private static func normalized(
        _ progress: StudyCardProgress,
        now: Date
    ) -> StudyCardProgress {
        StudyCardProgress(
            schemaVersion: StudyCardProgress.currentSchemaVersion,
            cardID: progress.cardID,
            repetitions: min(maximumStudyCounter, max(0, progress.repetitions)),
            lapses: min(maximumStudyCounter, max(0, progress.lapses)),
            intervalDays: min(maximumStudyIntervalDays, max(0, progress.intervalDays)),
            easeFactor: progress.easeFactor.isFinite
                ? min(3.2, max(1.3, progress.easeFactor))
                : 2.5,
            dueAt: isFinite(progress.dueAt) ? progress.dueAt : now,
            lastReviewedAt: progress.lastReviewedAt.flatMap { isFinite($0) ? $0 : nil }
        )
    }

    private static func isFinite(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
    }
}
