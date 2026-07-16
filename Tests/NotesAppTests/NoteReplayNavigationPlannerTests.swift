import Foundation
import NotesCore
import XCTest
@testable import NotesApp

final class NoteReplayNavigationPlannerTests: XCTestCase {
    private let recordingStart = Date(timeIntervalSinceReferenceDate: 42_000)

    func testUnknownPagesAreIgnoredOnlyAfterStrictTimelineValidation() throws {
        let sessionID = AudioSessionID()
        let firstPage = PageID()
        let secondPage = PageID()
        let deletedPage = PageID()
        let timing = makeTiming(sessionID: sessionID, duration: 10)
        let timeline = makeTimeline(
            sessionID: sessionID,
            marks: [
                makeMark(pageID: deletedPage, time: 1),
                makeMark(pageID: firstPage, time: 2),
                makeMark(pageID: deletedPage, time: 3),
                makeMark(pageID: secondPage, time: 4),
            ]
        )

        let plan = try XCTUnwrap(NoteReplayNavigationPlanner.prepare(
            timing: timing,
            timeline: timeline,
            eligiblePageIDs: [firstPage, secondPage],
            currentPageID: secondPage
        ))

        XCTAssertEqual(plan.fallbackPageID, secondPage)
        XCTAssertEqual(plan.pagePlan(at: 0.5).pageID, secondPage)
        XCTAssertEqual(plan.pagePlan(at: 1.5).pageID, secondPage)
        XCTAssertEqual(plan.pagePlan(at: 2.5).pageID, firstPage)
        XCTAssertEqual(plan.pagePlan(at: 3.5).pageID, firstPage)
        XCTAssertEqual(plan.pagePlan(at: 4).pageID, secondPage)
    }

    func testMalformedMarkOnDeletedPageInvalidatesWholeNavigationPlan() {
        let sessionID = AudioSessionID()
        let existingPage = PageID()
        let deletedPage = PageID()
        let timing = makeTiming(sessionID: sessionID, duration: 10)
        let malformed = AudioTimelineMark(
            schemaVersion: AudioTimelineMark.currentSchemaVersion + 1,
            operationID: OperationID(),
            pageID: deletedPage,
            timeSeconds: 2,
            createdAt: recordingStart.addingTimeInterval(2)
        )
        let timeline = makeTimeline(sessionID: sessionID, marks: [malformed])

        XCTAssertNil(NoteReplayNavigationPlanner.prepare(
            timing: timing,
            timeline: timeline,
            eligiblePageIDs: [existingPage],
            currentPageID: existingPage
        ))
    }

    func testBackwardPagePlanningAlwaysRecomputesFromTimeline() throws {
        let sessionID = AudioSessionID()
        let firstPage = PageID()
        let secondPage = PageID()
        let thirdPage = PageID()
        let timing = makeTiming(sessionID: sessionID, duration: 20)
        let timeline = makeTimeline(
            sessionID: sessionID,
            marks: [
                makeMark(pageID: firstPage, time: 1),
                makeMark(pageID: secondPage, time: 5),
                makeMark(pageID: thirdPage, time: 9),
            ]
        )
        let plan = try XCTUnwrap(NoteReplayNavigationPlanner.prepare(
            timing: timing,
            timeline: timeline,
            eligiblePageIDs: [firstPage, secondPage, thirdPage],
            currentPageID: firstPage
        ))

        XCTAssertEqual(plan.pagePlan(at: 10).pageID, thirdPage)
        XCTAssertEqual(plan.pagePlan(at: 6).pageID, secondPage)
        XCTAssertEqual(plan.pagePlan(at: 2).pageID, firstPage)
        XCTAssertEqual(plan.pagePlan(at: 0).pageID, firstPage)
    }

    func testNearestThumbnailSeekUsesEarlierMarkForEqualDistanceTie() throws {
        let sessionID = AudioSessionID()
        let firstPage = PageID()
        let secondPage = PageID()
        let timing = makeTiming(sessionID: sessionID, duration: 12)
        let timeline = makeTimeline(
            sessionID: sessionID,
            marks: [
                makeMark(pageID: firstPage, time: 1),
                makeMark(pageID: secondPage, time: 4),
                makeMark(pageID: secondPage, time: 8),
            ]
        )
        let plan = try XCTUnwrap(NoteReplayNavigationPlanner.prepare(
            timing: timing,
            timeline: timeline,
            eligiblePageIDs: [firstPage, secondPage],
            currentPageID: firstPage
        ))

        XCTAssertEqual(plan.nearestSeekTime(for: secondPage, to: 6), 4)
        XCTAssertEqual(plan.nearestSeekTime(for: secondPage, to: 6.001), 8)
        XCTAssertEqual(plan.nearestSeekTime(for: secondPage, to: -100), 4)
        XCTAssertEqual(plan.nearestSeekTime(for: secondPage, to: 100), 8)
        XCTAssertNil(plan.nearestSeekTime(for: PageID(), to: 6))
    }

    func testSameTimestampShadowedPageMarkIsNotReportedAsNavigable() throws {
        let sessionID = AudioSessionID()
        let shadowedPage = PageID()
        let navigablePage = PageID()
        let timing = makeTiming(sessionID: sessionID, duration: 12)
        let sharedTime: TimeInterval = 4
        let timeline = makeTimeline(
            sessionID: sessionID,
            marks: [
                AudioTimelineMark(
                    id: AudioTimelineMarkID(rawValue: UUID(uuid: (
                        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
                    ))),
                    operationID: OperationID(),
                    pageID: shadowedPage,
                    timeSeconds: sharedTime,
                    createdAt: recordingStart.addingTimeInterval(sharedTime)
                ),
                AudioTimelineMark(
                    id: AudioTimelineMarkID(rawValue: UUID(uuid: (
                        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2
                    ))),
                    operationID: OperationID(),
                    pageID: navigablePage,
                    timeSeconds: sharedTime,
                    createdAt: recordingStart.addingTimeInterval(sharedTime)
                ),
            ]
        )
        let plan = try XCTUnwrap(NoteReplayNavigationPlanner.prepare(
            timing: timing,
            timeline: timeline,
            eligiblePageIDs: [shadowedPage, navigablePage],
            currentPageID: shadowedPage
        ))

        XCTAssertEqual(plan.pagePlan(at: sharedTime).pageID, navigablePage)
        XCTAssertNil(plan.nearestSeekTime(for: shadowedPage, to: sharedTime))
        XCTAssertEqual(
            plan.nearestSeekTime(for: navigablePage, to: sharedTime),
            sharedTime
        )
    }

    func testFallbackUsesFirstEligiblePageWhenCurrentPageNoLongerExists() throws {
        let sessionID = AudioSessionID()
        let firstPage = PageID()
        let secondPage = PageID()
        let timing = makeTiming(sessionID: sessionID, duration: 10)
        let plan = try XCTUnwrap(NoteReplayNavigationPlanner.prepare(
            timing: timing,
            timeline: makeTimeline(sessionID: sessionID, marks: []),
            eligiblePageIDs: [firstPage, secondPage],
            currentPageID: PageID()
        ))

        XCTAssertEqual(plan.fallbackPageID, firstPage)
        XCTAssertEqual(plan.pagePlan(at: 9).pageID, firstPage)
    }

    func testDuplicateOrOverLimitEligiblePageListIsRejected() {
        let sessionID = AudioSessionID()
        let pageID = PageID()
        let timing = makeTiming(sessionID: sessionID, duration: 10)
        let timeline = makeTimeline(sessionID: sessionID, marks: [])

        XCTAssertNil(NoteReplayNavigationPlanner.prepare(
            timing: timing,
            timeline: timeline,
            eligiblePageIDs: [pageID, pageID],
            currentPageID: pageID
        ))
        XCTAssertNil(NoteReplayNavigationPlanner.prepare(
            timing: timing,
            timeline: timeline,
            eligiblePageIDs: [pageID, PageID()],
            currentPageID: pageID,
            maximumPageCount: 1
        ))
    }

    private func makeTiming(
        sessionID: AudioSessionID,
        duration: TimeInterval
    ) -> NoteReplaySessionTiming {
        NoteReplaySessionTiming(
            audioSessionID: sessionID,
            sessionSchemaVersion: AudioSessionDescriptor.currentSchemaVersion,
            recordingStartedAt: recordingStart,
            duration: duration
        )
    }

    private func makeTimeline(
        sessionID: AudioSessionID,
        marks: [AudioTimelineMark]
    ) -> AudioTimelineDocument {
        AudioTimelineDocument(
            audioSessionID: sessionID,
            marks: marks,
            modifiedAt: recordingStart.addingTimeInterval(30)
        )
    }

    private func makeMark(
        pageID: PageID,
        time: TimeInterval
    ) -> AudioTimelineMark {
        AudioTimelineMark(
            operationID: OperationID(),
            pageID: pageID,
            timeSeconds: time,
            createdAt: recordingStart.addingTimeInterval(time)
        )
    }
}
