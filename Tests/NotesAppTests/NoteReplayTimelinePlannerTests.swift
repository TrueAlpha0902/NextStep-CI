import NotesCore
import XCTest
@testable import NotesApp

final class NoteReplayTimelinePlannerTests: XCTestCase {
    private let sessionID = AudioSessionID(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!)
    private let recordingStart = Date(timeIntervalSinceReferenceDate: 1_000)

    func testSelectsLastValidMarkUsingTimeCreatedAtAndIDOrdering() {
        let fallback = PageID(UUID(uuidString: "F0000000-0000-0000-0000-000000000000")!)
        let earlierPage = PageID(UUID(uuidString: "10000000-0000-0000-0000-000000000000")!)
        let lowerIDPage = PageID(UUID(uuidString: "20000000-0000-0000-0000-000000000000")!)
        let higherIDPage = PageID(UUID(uuidString: "30000000-0000-0000-0000-000000000000")!)
        let earlier = mark(
            id: "00000000-0000-0000-0000-000000000001",
            pageID: earlierPage,
            time: 2,
            createdAt: 1_002
        )
        let lowerID = mark(
            id: "00000000-0000-0000-0000-000000000010",
            pageID: lowerIDPage,
            time: 5,
            createdAt: 1_005
        )
        let higherID = mark(
            id: "00000000-0000-0000-0000-000000000020",
            pageID: higherIDPage,
            time: 5,
            createdAt: 1_005
        )
        let timeline = AudioTimelineDocument(
            audioSessionID: sessionID,
            marks: [higherID, earlier, lowerID]
        )

        let before = NoteReplayTimelinePlanner.pagePlan(
            timing: timing(duration: 10),
            timeline: timeline,
            playbackTime: 1,
            fallbackPageID: fallback
        )
        let atTie = NoteReplayTimelinePlanner.pagePlan(
            timing: timing(duration: 10),
            timeline: timeline,
            playbackTime: 5,
            fallbackPageID: fallback
        )

        XCTAssertEqual(before.pageID, fallback)
        XCTAssertNil(before.markID)
        XCTAssertEqual(atTie.pageID, higherIDPage)
        XCTAssertEqual(atTie.markID, higherID.id)
        XCTAssertEqual(atTie.playbackTime, 5)
    }

    func testPlannerRejectsDuplicateMarkAndOperationIdentitiesLikeResolver() {
        let first = mark(
            id: "00000000-0000-0000-0000-000000000001",
            operationID: "00000000-0000-0000-0000-000000000001",
            pageID: PageID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            time: 3,
            createdAt: 1_003
        )
        let duplicateID = mark(
            id: "00000000-0000-0000-0000-000000000001",
            operationID: "00000000-0000-0000-0000-000000000002",
            pageID: PageID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
            time: 3,
            createdAt: 1_003
        )
        let duplicateOperationID = mark(
            id: "00000000-0000-0000-0000-000000000003",
            operationID: "00000000-0000-0000-0000-000000000001",
            pageID: PageID(UUID(uuidString: "00000000-0000-0000-0000-000000000003")!),
            time: 4,
            createdAt: 1_004
        )

        for malformedMarks in [
            [first, duplicateID],
            [duplicateID, first],
            [first, duplicateOperationID],
            [duplicateOperationID, first],
        ] {
            XCTAssertNil(NoteReplayTimelinePlanner.validatedSortedMarks(
                malformedMarks,
                timing: timing(duration: 10)
            ))
            XCTAssertNil(NoteReplayTimelinePlanner.prepareTimeline(
                timing: timing(duration: 10),
                timeline: AudioTimelineDocument(
                    audioSessionID: sessionID,
                    marks: malformedMarks
                )
            ))
        }

        let legacyDescriptor = AudioSessionDescriptor(
            id: sessionID,
            createdAt: recordingStart.addingTimeInterval(5_000),
            durationSeconds: 10
        )
        let durableDescriptor = AudioSessionDescriptor(
            id: sessionID,
            createdAt: recordingStart.addingTimeInterval(5_000),
            recordingStartedAt: recordingStart,
            durationSeconds: 10
        )
        for malformedMarks in [
            [first, duplicateID],
            [first, duplicateOperationID],
        ] {
            let timeline = AudioTimelineDocument(
                audioSessionID: sessionID,
                marks: malformedMarks,
                modifiedAt: recordingStart.addingTimeInterval(10)
            )
            XCTAssertNil(NoteReplaySessionTimingResolver.resolve(
                session: legacyDescriptor,
                timeline: timeline
            ))
            XCTAssertNil(NoteReplaySessionTimingResolver.resolve(
                session: durableDescriptor,
                timeline: timeline
            ))
        }
    }

    func testPreparedTimelineUsesFullTimingIdentityAndBoundedBinarySelection() throws {
        let firstPage = PageID()
        let secondPage = PageID()
        let timeline = AudioTimelineDocument(
            audioSessionID: sessionID,
            marks: [
                mark(id: UUID().uuidString, pageID: secondPage, time: 8, createdAt: 1_008),
                mark(id: UUID().uuidString, pageID: firstPage, time: 2, createdAt: 1_002),
            ]
        )
        let originalTiming = timing(duration: 10)
        let prepared = try XCTUnwrap(NoteReplayTimelinePlanner.prepareTimeline(
            timing: originalTiming,
            timeline: timeline
        ))

        let selected = NoteReplayTimelinePlanner.pagePlan(
            timing: originalTiming,
            preparedTimeline: prepared,
            playbackTime: 9,
            fallbackPageID: nil
        )
        let changedDuration = NoteReplayTimelinePlanner.pagePlan(
            timing: timing(duration: 12),
            preparedTimeline: prepared,
            playbackTime: 9,
            fallbackPageID: firstPage
        )
        let changedStart = NoteReplayTimelinePlanner.pagePlan(
            timing: timing(
                duration: 10,
                recordingStartedAt: recordingStart.addingTimeInterval(1)
            ),
            preparedTimeline: prepared,
            playbackTime: 9,
            fallbackPageID: firstPage
        )

        XCTAssertEqual(selected.pageID, secondPage)
        XCTAssertEqual(changedDuration.pageID, firstPage)
        XCTAssertNil(changedDuration.markID)
        XCTAssertEqual(changedStart.pageID, firstPage)
        XCTAssertNil(changedStart.markID)
    }

    func testPathologicalInMemoryTimelineIsRefusedBeforeSorting() {
        let repeatedMark = mark(
            id: UUID().uuidString,
            pageID: PageID(),
            time: 0,
            createdAt: 1_000
        )
        let marks = Array(
            repeating: repeatedMark,
            count: NoteReplayTimelinePlanner.maximumMarkCount + 1
        )
        let timeline = AudioTimelineDocument(audioSessionID: sessionID, marks: marks)

        XCTAssertNil(NoteReplayTimelinePlanner.prepareTimeline(
            timing: timing(duration: 10),
            timeline: timeline
        ))
        XCTAssertNil(NoteReplayTimelinePlanner.validatedSortedMarks(
            marks,
            timing: timing(duration: 10)
        ))
    }

    func testAnyMalformedMarkRejectsTheEntireNavigationTimeline() throws {
        let validPage = PageID()
        let valid = mark(
            id: UUID().uuidString,
            pageID: validPage,
            time: 4,
            createdAt: 1_004
        )
        var wrongSchema = mark(
            id: UUID().uuidString,
            pageID: PageID(),
            time: 5,
            createdAt: 1_005
        )
        wrongSchema.schemaVersion = 99
        let negative = mark(
            id: UUID().uuidString,
            pageID: PageID(),
            time: -1,
            createdAt: 999
        )
        let nonfinite = mark(
            id: UUID().uuidString,
            pageID: PageID(),
            time: .nan,
            createdAt: 1_001
        )
        let late = mark(
            id: UUID().uuidString,
            pageID: PageID(),
            time: 11,
            createdAt: 1_011
        )
        let contradictoryRecordingStart = mark(
            id: UUID().uuidString,
            pageID: PageID(),
            time: 6,
            createdAt: 1_006.01
        )
        let invalidDate = AudioTimelineMark(
            operationID: OperationID(),
            pageID: PageID(),
            timeSeconds: 2,
            createdAt: Date(timeIntervalSinceReferenceDate: .nan)
        )

        for malformed in [
            wrongSchema,
            negative,
            nonfinite,
            late,
            invalidDate,
            contradictoryRecordingStart,
        ] {
            let marks = [valid, malformed]
            XCTAssertNil(NoteReplayTimelinePlanner.validatedSortedMarks(
                marks,
                timing: timing(duration: 10)
            ))
            XCTAssertNil(NoteReplayTimelinePlanner.prepareTimeline(
                timing: timing(duration: 10),
                timeline: AudioTimelineDocument(
                    audioSessionID: sessionID,
                    marks: marks
                )
            ))
        }
        XCTAssertEqual(
            try XCTUnwrap(NoteReplayTimelinePlanner.validatedSortedMarks(
                [valid],
                timing: timing(duration: 10)
            )),
            [valid]
        )
    }

    func testMismatchedTimelineCannotNavigateAnotherSession() {
        let fallback = PageID()
        let foreignPage = PageID()
        let foreignTimeline = AudioTimelineDocument(
            audioSessionID: AudioSessionID(),
            marks: [mark(id: UUID().uuidString, pageID: foreignPage, time: 0, createdAt: 1_000)]
        )

        let plan = NoteReplayTimelinePlanner.pagePlan(
            timing: timing(duration: 10),
            timeline: foreignTimeline,
            playbackTime: 5,
            fallbackPageID: fallback
        )

        XCTAssertEqual(plan.pageID, fallback)
        XCTAssertNil(plan.markID)
    }

    func testStrictSessionPolicyRejectsZeroLongNonfiniteAndUnsupportedTiming() {
        let page = PageID()
        let fallback = PageID()
        let timeline = AudioTimelineDocument(
            audioSessionID: sessionID,
            marks: [mark(id: UUID().uuidString, pageID: page, time: 0, createdAt: 1_000)]
        )
        let invalidTimings = [
            timing(duration: 0),
            timing(duration: NoteReplaySessionPolicy.maximumDuration + 1),
            timing(
                duration: 10,
                recordingStartedAt: Date(timeIntervalSinceReferenceDate: .nan)
            ),
            timing(duration: 10, schemaVersion: 99),
        ]

        for invalidTiming in invalidTimings {
            XCTAssertFalse(NoteReplaySessionPolicy.isValid(invalidTiming))
            XCTAssertNil(NoteReplayTimelinePlanner.prepareTimeline(
                timing: invalidTiming,
                timeline: timeline
            ))
            let plan = NoteReplayTimelinePlanner.pagePlan(
                timing: invalidTiming,
                timeline: timeline,
                playbackTime: 100,
                fallbackPageID: fallback
            )
            XCTAssertEqual(plan.playbackTime, 0)
            XCTAssertEqual(plan.pageID, fallback)
            XCTAssertNil(plan.markID)
        }
    }

    func testExplicitRecordingStartNeverUsesDescriptorPersistenceDate() {
        let persistenceDate = recordingStart.addingTimeInterval(5_000)
        let descriptor = AudioSessionDescriptor(
            id: sessionID,
            createdAt: persistenceDate,
            durationSeconds: 10
        )
        let explicitTiming = NoteReplaySessionTiming(
            session: descriptor,
            recordingStartedAt: recordingStart
        )

        XCTAssertEqual(explicitTiming.recordingStartedAt, recordingStart)
        XCTAssertNotEqual(explicitTiming.recordingStartedAt, descriptor.createdAt)
        XCTAssertTrue(NoteReplaySessionPolicy.isValid(explicitTiming))
    }

    func testTimingResolverUsesDurableStartAndRejectsContradictoryEvidence() throws {
        let descriptor = AudioSessionDescriptor(
            id: sessionID,
            createdAt: recordingStart.addingTimeInterval(5_000),
            recordingStartedAt: recordingStart,
            durationSeconds: 10
        )
        let consistentTimeline = AudioTimelineDocument(
            audioSessionID: sessionID,
            marks: [mark(
                id: UUID().uuidString,
                pageID: PageID(),
                time: 2,
                createdAt: 1_002
            )],
            modifiedAt: recordingStart.addingTimeInterval(10)
        )

        let resolved = try XCTUnwrap(NoteReplaySessionTimingResolver.resolve(
            session: descriptor,
            timeline: consistentTimeline
        ))
        XCTAssertEqual(resolved.source, .durableDescriptor)
        XCTAssertEqual(resolved.timing.recordingStartedAt, recordingStart)
        XCTAssertNotEqual(resolved.timing.recordingStartedAt, descriptor.createdAt)

        var contradictoryTimeline = consistentTimeline
        contradictoryTimeline.marks[0].createdAt = recordingStart.addingTimeInterval(2.01)
        XCTAssertNil(NoteReplaySessionTimingResolver.resolve(
            session: descriptor,
            timeline: contradictoryTimeline
        ))
    }

    func testTimingResolverRequiresConsistentLegacyTimelineEvidence() throws {
        let legacyDescriptor = AudioSessionDescriptor(
            id: sessionID,
            createdAt: recordingStart.addingTimeInterval(9_000),
            durationSeconds: 10
        )
        let firstMark = mark(
            id: UUID().uuidString,
            pageID: PageID(),
            time: 2,
            createdAt: 1_002
        )
        let corroboratingMark = mark(
            id: UUID().uuidString,
            pageID: PageID(),
            time: 5,
            createdAt: 1_005.0005
        )
        let timeline = AudioTimelineDocument(
            audioSessionID: sessionID,
            marks: [corroboratingMark, firstMark],
            modifiedAt: recordingStart.addingTimeInterval(10)
        )

        let resolved = try XCTUnwrap(NoteReplaySessionTimingResolver.resolve(
            session: legacyDescriptor,
            timeline: timeline
        ))
        XCTAssertEqual(resolved.source, .legacyTimelineEvidence)
        XCTAssertEqual(
            resolved.timing.recordingStartedAt.timeIntervalSince(recordingStart),
            0,
            accuracy: NoteReplaySessionTimingResolver.timelineEvidenceTolerance
        )

        var inconsistentTimeline = timeline
        inconsistentTimeline.marks[1].createdAt = recordingStart.addingTimeInterval(2.002)
        XCTAssertNil(NoteReplaySessionTimingResolver.resolve(
            session: legacyDescriptor,
            timeline: inconsistentTimeline
        ))
        XCTAssertNil(NoteReplaySessionTimingResolver.resolve(
            session: legacyDescriptor,
            timeline: AudioTimelineDocument(audioSessionID: sessionID, marks: [])
        ))
        XCTAssertNil(NoteReplaySessionTimingResolver.resolve(
            session: legacyDescriptor,
            timeline: nil
        ))
    }

    func testSeekAndDefaultSkipsClampToFiniteDuration() {
        XCTAssertEqual(
            NoteReplayTimelinePlanner.skipBackwardTime(from: 4, duration: 30),
            0
        )
        XCTAssertEqual(
            NoteReplayTimelinePlanner.skipForwardTime(from: 25, duration: 30),
            30
        )
        XCTAssertEqual(
            NoteReplayTimelinePlanner.seekTime(from: 12, by: -2, duration: 30),
            10
        )
        XCTAssertEqual(
            NoteReplayTimelinePlanner.seekTime(from: 12, by: .infinity, duration: 30),
            12
        )
        XCTAssertEqual(NoteReplayTimelinePlanner.clampedTime(.nan, duration: 30), 0)
        XCTAssertEqual(NoteReplayTimelinePlanner.clampedTime(.infinity, duration: 30), 30)
        XCTAssertEqual(NoteReplayTimelinePlanner.clampedTime(-.infinity, duration: 30), 0)
        XCTAssertEqual(NoteReplayTimelinePlanner.clampedTime(12, duration: .nan), 0)
        XCTAssertEqual(NoteReplayTimelinePlanner.clampedTime(12, duration: 0), 0)
    }

    private func timing(
        duration: TimeInterval,
        recordingStartedAt: Date? = nil,
        schemaVersion: Int = AudioSessionDescriptor.currentSchemaVersion
    ) -> NoteReplaySessionTiming {
        NoteReplaySessionTiming(
            audioSessionID: sessionID,
            sessionSchemaVersion: schemaVersion,
            recordingStartedAt: recordingStartedAt ?? recordingStart,
            duration: duration
        )
    }

    private func mark(
        id: String,
        operationID: String = UUID().uuidString,
        pageID: PageID,
        time: TimeInterval,
        createdAt: TimeInterval
    ) -> AudioTimelineMark {
        AudioTimelineMark(
            id: AudioTimelineMarkID(UUID(uuidString: id)!),
            operationID: OperationID(UUID(uuidString: operationID)!),
            pageID: pageID,
            timeSeconds: time,
            createdAt: Date(timeIntervalSinceReferenceDate: createdAt)
        )
    }
}
