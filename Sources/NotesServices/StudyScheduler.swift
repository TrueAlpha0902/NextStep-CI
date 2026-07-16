import Foundation

public enum StudyGrade: Int, Codable, CaseIterable, Sendable {
    case again = 0
    case hard = 1
    case good = 2
    case easy = 3
}

public struct StudyProgress: Codable, Hashable, Sendable {
    public var repetitions: Int
    public var lapses: Int
    public var intervalDays: Int
    public var easeFactor: Double
    public var dueAt: Date
    public var lastReviewedAt: Date?

    public init(
        repetitions: Int = 0,
        lapses: Int = 0,
        intervalDays: Int = 0,
        easeFactor: Double = 2.5,
        dueAt: Date = .now,
        lastReviewedAt: Date? = nil
    ) {
        self.repetitions = repetitions
        self.lapses = lapses
        self.intervalDays = intervalDays
        self.easeFactor = easeFactor
        self.dueAt = dueAt
        self.lastReviewedAt = lastReviewedAt
    }
}

public enum StudyScheduler {
    public static func review(
        _ progress: StudyProgress,
        grade: StudyGrade,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> StudyProgress {
        var next = progress
        next.lastReviewedAt = now

        switch grade {
        case .again:
            next.repetitions = 0
            next.lapses += 1
            next.intervalDays = 0
            next.easeFactor = max(1.3, next.easeFactor - 0.2)
            next.dueAt = calendar.date(byAdding: .minute, value: 10, to: now) ?? now.addingTimeInterval(600)
        case .hard:
            next.repetitions += 1
            next.intervalDays = max(1, Int((Double(max(1, progress.intervalDays)) * 1.2).rounded()))
            next.easeFactor = max(1.3, next.easeFactor - 0.15)
            next.dueAt = calendar.date(byAdding: .day, value: next.intervalDays, to: now) ?? now
        case .good:
            next.repetitions += 1
            if progress.repetitions == 0 {
                next.intervalDays = 1
            } else if progress.repetitions == 1 {
                next.intervalDays = 6
            } else {
                next.intervalDays = max(1, Int((Double(progress.intervalDays) * progress.easeFactor).rounded()))
            }
            next.dueAt = calendar.date(byAdding: .day, value: next.intervalDays, to: now) ?? now
        case .easy:
            next.repetitions += 1
            next.easeFactor = min(3.2, next.easeFactor + 0.15)
            let base = progress.intervalDays == 0 ? 4 : progress.intervalDays
            next.intervalDays = max(4, Int((Double(base) * next.easeFactor * 1.3).rounded()))
            next.dueAt = calendar.date(byAdding: .day, value: next.intervalDays, to: now) ?? now
        }

        return next
    }
}
