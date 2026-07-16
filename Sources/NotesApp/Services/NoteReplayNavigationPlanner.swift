import Foundation
import NotesCore

/// A strictly validated replay timeline projected onto the pages that still
/// exist in the open notebook. Unknown or deleted page identifiers are ignored
/// only after the complete durable timeline has passed the shared validation
/// contract in `NoteReplayTimelinePlanner`.
struct PreparedNoteReplayNavigationPlan: Equatable, Sendable {
    let timing: NoteReplaySessionTiming
    let eligiblePageIDs: [PageID]
    let fallbackPageID: PageID

    fileprivate let eligibleMarks: [AudioTimelineMark]
    fileprivate let marksByPageID: [PageID: [AudioTimelineMark]]

    func pagePlan(at playbackTime: TimeInterval) -> NoteReplayPagePlan {
        let time = NoteReplayTimelinePlanner.clampedTime(
            playbackTime,
            duration: timing.duration
        )
        let mark = lastMark(notAfter: time, in: eligibleMarks)
        return NoteReplayPagePlan(
            playbackTime: time,
            pageID: mark?.pageID ?? fallbackPageID,
            markID: mark?.id
        )
    }

    /// Finds the navigable mark on `pageID` nearest to the current playback
    /// position. When multiple pages have marks at the same timestamp, only the
    /// final mark under the durable timeline ordering is navigable at that
    /// instant. Shadowed marks are deliberately excluded instead of reporting a
    /// successful thumbnail seek that presents a different page.
    /// Equal-distance ties choose the earlier mark so repeated taps are stable.
    func nearestSeekTime(
        for pageID: PageID,
        to playbackTime: TimeInterval
    ) -> TimeInterval? {
        guard let marks = marksByPageID[pageID], !marks.isEmpty else {
            return nil
        }
        let time = NoteReplayTimelinePlanner.clampedTime(
            playbackTime,
            duration: timing.duration
        )
        let insertionIndex = firstMark(notBefore: time, in: marks)
        if insertionIndex == 0 {
            return marks[0].timeSeconds
        }
        if insertionIndex == marks.count {
            return marks[marks.count - 1].timeSeconds
        }

        let earlier = marks[insertionIndex - 1]
        let later = marks[insertionIndex]
        let earlierDistance = time - earlier.timeSeconds
        let laterDistance = later.timeSeconds - time
        let selectedTime = earlierDistance <= laterDistance
            ? earlier.timeSeconds
            : later.timeSeconds
        guard pagePlan(at: selectedTime).pageID == pageID else { return nil }
        return selectedTime
    }

    private func lastMark(
        notAfter playbackTime: TimeInterval,
        in marks: [AudioTimelineMark]
    ) -> AudioTimelineMark? {
        let insertionIndex = firstMark(after: playbackTime, in: marks)
        guard insertionIndex > 0 else { return nil }
        return marks[insertionIndex - 1]
    }

    private func firstMark(
        notBefore playbackTime: TimeInterval,
        in marks: [AudioTimelineMark]
    ) -> Int {
        var lowerBound = 0
        var upperBound = marks.count
        while lowerBound < upperBound {
            let middle = lowerBound + ((upperBound - lowerBound) / 2)
            if marks[middle].timeSeconds < playbackTime {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    private func firstMark(
        after playbackTime: TimeInterval,
        in marks: [AudioTimelineMark]
    ) -> Int {
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
        return lowerBound
    }
}

enum NoteReplayNavigationPlanner {
    static let maximumEligiblePageCount = 10_000

    static func prepare(
        timing: NoteReplaySessionTiming,
        timeline: AudioTimelineDocument,
        eligiblePageIDs: [PageID],
        currentPageID: PageID?,
        maximumPageCount: Int = maximumEligiblePageCount
    ) -> PreparedNoteReplayNavigationPlan? {
        let boundedMaximumPageCount = min(
            max(maximumPageCount, 1),
            maximumEligiblePageCount
        )
        guard !eligiblePageIDs.isEmpty,
              eligiblePageIDs.count <= boundedMaximumPageCount else {
            return nil
        }

        var eligiblePageSet = Set<PageID>()
        eligiblePageSet.reserveCapacity(eligiblePageIDs.count)
        guard eligiblePageIDs.allSatisfy({
            eligiblePageSet.insert($0).inserted
        }) else {
            return nil
        }

        // Validate the container and every mark exactly once before page
        // filtering. A malformed mark that points to a deleted page must still
        // invalidate the replay session. Keeping the one sorted result also
        // avoids a second O(n log n) sort at the 100k-mark hard limit.
        guard NoteReplaySessionPolicy.isValid(timing),
              timeline.schemaVersion
                == AudioTimelineDocument.currentSchemaVersion,
              timeline.modifiedAt.timeIntervalSinceReferenceDate.isFinite,
              timeline.audioSessionID == timing.audioSessionID,
              timeline.marks.count
                <= NoteReplayTimelinePlanner.maximumMarkCount,
              let allSortedMarks = NoteReplayTimelinePlanner.validatedSortedMarks(
                  timeline.marks,
                  timing: timing
              ) else {
            return nil
        }

        let eligibleMarks = allSortedMarks.filter {
            eligiblePageSet.contains($0.pageID)
        }
        var marksByPageID: [PageID: [AudioTimelineMark]] = [:]
        marksByPageID.reserveCapacity(min(eligiblePageIDs.count, eligibleMarks.count))
        var markIndex = 0
        while markIndex < eligibleMarks.count {
            var timestampEndIndex = markIndex + 1
            while timestampEndIndex < eligibleMarks.count,
                  eligibleMarks[timestampEndIndex].timeSeconds
                    == eligibleMarks[markIndex].timeSeconds {
                timestampEndIndex += 1
            }
            let navigableMark = eligibleMarks[timestampEndIndex - 1]
            marksByPageID[navigableMark.pageID, default: []].append(
                navigableMark
            )
            markIndex = timestampEndIndex
        }

        let fallbackPageID = currentPageID.flatMap {
            eligiblePageSet.contains($0) ? $0 : nil
        } ?? eligiblePageIDs[0]
        return PreparedNoteReplayNavigationPlan(
            timing: timing,
            eligiblePageIDs: eligiblePageIDs,
            fallbackPageID: fallbackPageID,
            eligibleMarks: eligibleMarks,
            marksByPageID: marksByPageID
        )
    }
}
