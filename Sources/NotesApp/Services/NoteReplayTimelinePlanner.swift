import Foundation
import NotesCore

/// Explicit, trusted timing input for Note Replay.
///
/// `AudioSessionDescriptor.createdAt` is the descriptor persistence time and is
/// deliberately not consulted here. Callers must resolve the durable recording
/// start (or legacy timeline evidence) before constructing this value.
struct NoteReplaySessionTiming: Equatable, Sendable {
    let audioSessionID: AudioSessionID
    let sessionSchemaVersion: Int
    let recordingStartedAt: Date
    let duration: TimeInterval

    init(
        audioSessionID: AudioSessionID,
        sessionSchemaVersion: Int,
        recordingStartedAt: Date,
        duration: TimeInterval
    ) {
        self.audioSessionID = audioSessionID
        self.sessionSchemaVersion = sessionSchemaVersion
        self.recordingStartedAt = recordingStartedAt
        self.duration = duration
    }

    init(session: AudioSessionDescriptor, recordingStartedAt: Date) {
        self.init(
            audioSessionID: session.id,
            sessionSchemaVersion: session.schemaVersion,
            recordingStartedAt: recordingStartedAt,
            duration: session.durationSeconds
        )
    }
}

/// One validity contract shared by drawing replay and page navigation.
enum NoteReplaySessionPolicy {
    static let maximumDuration: TimeInterval = 7 * 24 * 60 * 60

    static func isValid(_ timing: NoteReplaySessionTiming) -> Bool {
        let start = timing.recordingStartedAt.timeIntervalSinceReferenceDate
        return timing.sessionSchemaVersion >= 1
            && timing.sessionSchemaVersion <= AudioSessionDescriptor.currentSchemaVersion
            && start.isFinite
            && start >= Date.distantPast.timeIntervalSinceReferenceDate
            && timing.duration.isFinite
            && timing.duration > 0
            && timing.duration <= maximumDuration
            && start <= Date.distantFuture.timeIntervalSinceReferenceDate - timing.duration
    }
}

enum NoteReplaySessionTimingSource: Equatable, Sendable {
    case durableDescriptor
    case legacyTimelineEvidence
}

struct ResolvedNoteReplaySessionTiming: Equatable, Sendable {
    let timing: NoteReplaySessionTiming
    let source: NoteReplaySessionTimingSource
}

/// One fail-closed mark contract shared by timing evidence and navigation.
/// Silently filtering a malformed mark could make those two consumers derive
/// different replay state from the same durable timeline.
fileprivate enum NoteReplayTimelineMarkPolicy {
    static func allMarksAreValid(
        _ marks: [AudioTimelineMark],
        duration: TimeInterval,
        expectedRecordingStartedAt: Date? = nil,
        evidenceTolerance: TimeInterval = 0
    ) -> Bool {
        guard duration.isFinite,
              duration > 0,
              duration <= NoteReplaySessionPolicy.maximumDuration,
              evidenceTolerance.isFinite,
              evidenceTolerance >= 0 else {
            return false
        }
        var markIDs = Set<AudioTimelineMarkID>()
        var operationIDs = Set<OperationID>()
        markIDs.reserveCapacity(marks.count)
        operationIDs.reserveCapacity(marks.count)

        for mark in marks {
            guard mark.schemaVersion == AudioTimelineMark.currentSchemaVersion,
                  markIDs.insert(mark.id).inserted,
                  operationIDs.insert(mark.operationID).inserted,
                  mark.timeSeconds.isFinite,
                  mark.timeSeconds >= 0,
                  mark.timeSeconds <= duration,
                  mark.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                return false
            }
            let candidateStart = mark.createdAt.addingTimeInterval(
                -mark.timeSeconds
            )
            guard candidateStart.timeIntervalSinceReferenceDate.isFinite else {
                return false
            }
            if let expectedRecordingStartedAt {
                let difference = candidateStart.timeIntervalSince(
                    expectedRecordingStartedAt
                )
                guard difference.isFinite,
                      abs(difference) <= evidenceTolerance else {
                    return false
                }
            }
        }
        return true
    }
}

/// Resolves replay zero without ever treating descriptor persistence time as
/// recording time. New sessions use the durable field. Older schema-v2 data
/// may recover the same instant only when at least one timeline mark exists and
/// every mark independently corroborates it within the repository tolerance.
enum NoteReplaySessionTimingResolver {
    static let timelineEvidenceTolerance: TimeInterval = 0.001

    static func resolve(
        session: AudioSessionDescriptor,
        timeline: AudioTimelineDocument?
    ) -> ResolvedNoteReplaySessionTiming? {
        if let recordingStartedAt = session.recordingStartedAt {
            let timing = NoteReplaySessionTiming(
                session: session,
                recordingStartedAt: recordingStartedAt
            )
            guard NoteReplaySessionPolicy.isValid(timing),
                  timeline.map({ timelineCorroborates(
                      $0,
                      timing: timing,
                      requiresEvidence: false
                  ) }) ?? true else {
                return nil
            }
            return ResolvedNoteReplaySessionTiming(
                timing: timing,
                source: .durableDescriptor
            )
        }

        guard let timeline,
              let recordingStartedAt = corroboratedStart(
                timeline,
                session: session,
                requiresEvidence: true
              ) else {
            return nil
        }
        let timing = NoteReplaySessionTiming(
            session: session,
            recordingStartedAt: recordingStartedAt
        )
        guard NoteReplaySessionPolicy.isValid(timing) else { return nil }
        return ResolvedNoteReplaySessionTiming(
            timing: timing,
            source: .legacyTimelineEvidence
        )
    }

    private static func timelineCorroborates(
        _ timeline: AudioTimelineDocument,
        timing: NoteReplaySessionTiming,
        requiresEvidence: Bool
    ) -> Bool {
        guard validContainer(
            timeline,
            audioSessionID: timing.audioSessionID
        ), NoteReplayTimelineMarkPolicy.allMarksAreValid(
            timeline.marks,
            duration: timing.duration,
            expectedRecordingStartedAt: timing.recordingStartedAt,
            evidenceTolerance: timelineEvidenceTolerance
        ) else {
            return false
        }
        guard !timeline.marks.isEmpty else { return !requiresEvidence }
        guard let resolvedStart = corroboratedStart(
            timeline,
            audioSessionID: timing.audioSessionID,
            duration: timing.duration,
            requiresEvidence: requiresEvidence
        ) else {
            return false
        }
        let difference = resolvedStart.timeIntervalSince(timing.recordingStartedAt)
        return difference.isFinite && abs(difference) <= timelineEvidenceTolerance
    }

    private static func corroboratedStart(
        _ timeline: AudioTimelineDocument,
        session: AudioSessionDescriptor,
        requiresEvidence: Bool
    ) -> Date? {
        corroboratedStart(
            timeline,
            audioSessionID: session.id,
            duration: session.durationSeconds,
            requiresEvidence: requiresEvidence
        )
    }

    private static func corroboratedStart(
        _ timeline: AudioTimelineDocument,
        audioSessionID: AudioSessionID,
        duration: TimeInterval,
        requiresEvidence: Bool
    ) -> Date? {
        guard validContainer(timeline, audioSessionID: audioSessionID),
              NoteReplayTimelineMarkPolicy.allMarksAreValid(
                  timeline.marks,
                  duration: duration
              ),
              !requiresEvidence || !timeline.marks.isEmpty else {
            return nil
        }
        guard !timeline.marks.isEmpty else { return nil }

        var earliestStart: Date?
        var latestStart: Date?
        for mark in timeline.marks {
            let candidate = mark.createdAt.addingTimeInterval(-mark.timeSeconds)
            guard candidate.timeIntervalSinceReferenceDate.isFinite else {
                return nil
            }
            earliestStart = earliestStart.map { min($0, candidate) } ?? candidate
            latestStart = latestStart.map { max($0, candidate) } ?? candidate
        }
        guard let earliestStart, let latestStart else { return nil }
        let evidenceSpread = latestStart.timeIntervalSince(earliestStart)
        guard evidenceSpread.isFinite,
              evidenceSpread <= timelineEvidenceTolerance else {
            return nil
        }
        return earliestStart
    }

    private static func validContainer(
        _ timeline: AudioTimelineDocument,
        audioSessionID: AudioSessionID
    ) -> Bool {
        timeline.schemaVersion == AudioTimelineDocument.currentSchemaVersion
            && timeline.audioSessionID == audioSessionID
            && timeline.modifiedAt.timeIntervalSinceReferenceDate.isFinite
            && timeline.marks.count <= NoteReplayTimelinePlanner.maximumMarkCount
    }
}

struct NoteReplayPagePlan: Equatable, Sendable {
    let playbackTime: TimeInterval
    let pageID: PageID?
    let markID: AudioTimelineMarkID?
}

struct PreparedNoteReplayTimeline: Equatable, Sendable {
    let timing: NoteReplaySessionTiming
    fileprivate let marks: [AudioTimelineMark]
}

/// Pure, deterministic page selection and seek arithmetic for Note Replay.
enum NoteReplayTimelinePlanner {
    static let defaultSkipInterval: TimeInterval = 10
    static let maximumMarkCount = 100_000

    static func pagePlan(
        timing: NoteReplaySessionTiming,
        timeline: AudioTimelineDocument?,
        playbackTime: TimeInterval,
        fallbackPageID: PageID?
    ) -> NoteReplayPagePlan {
        let duration = NoteReplaySessionPolicy.isValid(timing) ? timing.duration : 0
        let time = clampedTime(playbackTime, duration: duration)
        guard let preparedTimeline = prepareTimeline(timing: timing, timeline: timeline) else {
            return NoteReplayPagePlan(
                playbackTime: time,
                pageID: fallbackPageID,
                markID: nil
            )
        }

        return pagePlan(
            timing: timing,
            preparedTimeline: preparedTimeline,
            playbackTime: time,
            fallbackPageID: fallbackPageID
        )
    }

    static func prepareTimeline(
        timing: NoteReplaySessionTiming,
        timeline: AudioTimelineDocument?
    ) -> PreparedNoteReplayTimeline? {
        guard NoteReplaySessionPolicy.isValid(timing),
              let timeline,
              timeline.schemaVersion == AudioTimelineDocument.currentSchemaVersion,
              timeline.modifiedAt.timeIntervalSinceReferenceDate.isFinite,
              timeline.audioSessionID == timing.audioSessionID,
              timeline.marks.count <= maximumMarkCount,
              let sortedMarks = validatedSortedMarks(timeline.marks, timing: timing) else {
            return nil
        }
        return PreparedNoteReplayTimeline(
            timing: timing,
            marks: sortedMarks
        )
    }

    static func pagePlan(
        timing: NoteReplaySessionTiming,
        preparedTimeline: PreparedNoteReplayTimeline?,
        playbackTime: TimeInterval,
        fallbackPageID: PageID?
    ) -> NoteReplayPagePlan {
        let duration = NoteReplaySessionPolicy.isValid(timing) ? timing.duration : 0
        let time = clampedTime(playbackTime, duration: duration)
        guard let preparedTimeline,
              preparedTimeline.timing == timing else {
            return NoteReplayPagePlan(
                playbackTime: time,
                pageID: fallbackPageID,
                markID: nil
            )
        }

        let mark = lastMark(notAfter: time, in: preparedTimeline.marks)
        return NoteReplayPagePlan(
            playbackTime: time,
            pageID: mark?.pageID ?? fallbackPageID,
            markID: mark?.id
        )
    }

    static func seekTime(
        from playbackTime: TimeInterval,
        by delta: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        let current = clampedTime(playbackTime, duration: duration)
        guard delta.isFinite else { return current }
        let candidate = current + delta
        guard candidate.isFinite else { return delta.sign == .minus ? 0 : validDuration(duration) }
        return clampedTime(candidate, duration: duration)
    }

    static func skipBackwardTime(
        from playbackTime: TimeInterval,
        duration: TimeInterval,
        interval: TimeInterval = defaultSkipInterval
    ) -> TimeInterval {
        seekTime(from: playbackTime, by: -abs(interval), duration: duration)
    }

    static func skipForwardTime(
        from playbackTime: TimeInterval,
        duration: TimeInterval,
        interval: TimeInterval = defaultSkipInterval
    ) -> TimeInterval {
        seekTime(from: playbackTime, by: abs(interval), duration: duration)
    }

    static func clampedTime(
        _ playbackTime: TimeInterval,
        duration: TimeInterval
    ) -> TimeInterval {
        let duration = validDuration(duration)
        if playbackTime == .infinity { return duration }
        guard playbackTime.isFinite else { return 0 }
        return min(max(playbackTime, 0), duration)
    }

    static func validatedSortedMarks(
        _ marks: [AudioTimelineMark],
        timing: NoteReplaySessionTiming
    ) -> [AudioTimelineMark]? {
        guard NoteReplaySessionPolicy.isValid(timing),
              marks.count <= maximumMarkCount,
              NoteReplayTimelineMarkPolicy.allMarksAreValid(
                  marks,
                  duration: timing.duration,
                  expectedRecordingStartedAt: timing.recordingStartedAt,
                  evidenceTolerance:
                    NoteReplaySessionTimingResolver.timelineEvidenceTolerance
              ) else {
            return nil
        }
        return marks.sorted(by: markPrecedes)
    }

    private static func validDuration(_ duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        return duration
    }

    private static func lastMark(
        notAfter playbackTime: TimeInterval,
        in marks: [AudioTimelineMark]
    ) -> AudioTimelineMark? {
        var lowerBound = 0
        var upperBound = marks.count
        while lowerBound < upperBound {
            let middle = lowerBound + ((upperBound - lowerBound) / 2)
            if marks[middle].timeSeconds <= playbackTime {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        guard lowerBound > 0 else { return nil }
        return marks[lowerBound - 1]
    }

    private static func markPrecedes(
        _ lhs: AudioTimelineMark,
        _ rhs: AudioTimelineMark
    ) -> Bool {
        if lhs.timeSeconds != rhs.timeSeconds {
            return lhs.timeSeconds < rhs.timeSeconds
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.rawValue.uuidString < rhs.id.rawValue.uuidString
    }
}
