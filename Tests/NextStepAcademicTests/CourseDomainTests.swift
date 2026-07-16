import Foundation
import NotesCore
@testable import NextStepAcademic
import XCTest

final class CourseDomainTests: XCTestCase {
    func testCourseCanonicalizesSchedulesAndRoundTripsUnicode() throws {
        let later = try CourseScheduleRule(
            id: CourseScheduleRuleID(testUUID(42)),
            courseID: testCourseID,
            isoWeekday: 5,
            startMinute: 13 * 60,
            durationMinutes: 120,
            timeZoneIdentifier: "Asia/Taipei"
        )
        let earlier = try CourseScheduleRule(
            id: CourseScheduleRuleID(testUUID(41)),
            courseID: testCourseID,
            isoWeekday: 2,
            startMinute: 9 * 60,
            durationMinutes: 90,
            timeZoneIdentifier: "Asia/Taipei",
            effectiveFrom: try AcademicLocalDate(year: 2026, month: 9, day: 1),
            effectiveThrough: try AcademicLocalDate(year: 2027, month: 1, day: 31)
        )
        let course = try Course(
            id: testCourseID,
            code: "CS-進階",
            name: "人工智慧與社會 🤖",
            term: "115 學年度上學期",
            instructor: "陳教授",
            timeZoneIdentifier: "Asia/Taipei",
            scheduleRules: [later, earlier],
            createdAt: testCreatedAt
        )

        XCTAssertEqual(course.scheduleRules.map(\.id), [earlier.id, later.id])
        try assertCodableRoundTrip(course)

        let replaced = try course.replacingScheduleRules(
            [later],
            at: testCreatedAt.addingTimeInterval(1)
        )
        XCTAssertEqual(replaced.revision, 2)
        XCTAssertThrowsError(try course.replacingScheduleRules(
            [later],
            at: testCreatedAt.addingTimeInterval(-1)
        ))
    }

    func testCourseRejectsDuplicateOrForeignScheduleRules() throws {
        let rule = try CourseScheduleRule(
            id: CourseScheduleRuleID(testUUID(50)),
            courseID: testCourseID,
            isoWeekday: 1,
            startMinute: 0,
            durationMinutes: 60,
            timeZoneIdentifier: "UTC"
        )
        XCTAssertThrowsError(try Course(
            id: testCourseID,
            name: "重複規則",
            timeZoneIdentifier: "UTC",
            scheduleRules: [rule, rule],
            createdAt: testCreatedAt
        ))

        let foreign = try CourseScheduleRule(
            id: CourseScheduleRuleID(testUUID(51)),
            courseID: CourseID(testUUID(999)),
            isoWeekday: 1,
            startMinute: 0,
            durationMinutes: 60,
            timeZoneIdentifier: "UTC"
        )
        XCTAssertThrowsError(try Course(
            id: testCourseID,
            name: "外部規則",
            timeZoneIdentifier: "UTC",
            scheduleRules: [foreign],
            createdAt: testCreatedAt
        ))
        XCTAssertThrowsError(try CourseScheduleRule(
            courseID: testCourseID,
            isoWeekday: 8,
            startMinute: 0,
            durationMinutes: 60,
            timeZoneIdentifier: "UTC"
        ))
        XCTAssertThrowsError(
            try JSONDecoder().decode(CourseScheduleRule.self, from: futureSchemaOnly())
        )
        XCTAssertThrowsError(try JSONDecoder().decode(Course.self, from: futureSchemaOnly()))
    }

    func testCourseSessionAllowsOnlyForwardStateTransitions() throws {
        let planned = try CourseSession(
            id: testSessionID,
            courseID: testCourseID,
            createdAt: testCreatedAt
        )
        let active = try planned.transitioned(to: .active, at: testStartedAt)
        XCTAssertEqual(active.status, .active)
        XCTAssertEqual(active.revision, 2)
        XCTAssertEqual(active.actualStartedAt, testStartedAt)
        try assertCodableRoundTrip(active)

        let needsReview = try active.transitioned(to: .needsReview, at: testCompletedAt)
        XCTAssertEqual(needsReview.status, .needsReview)
        XCTAssertEqual(needsReview.revision, 3)

        XCTAssertThrowsError(try planned.transitioned(to: .reviewed, at: testCompletedAt))
        XCTAssertThrowsError(try active.transitioned(to: .reviewed, at: testCompletedAt))
        XCTAssertThrowsError(try needsReview.transitioned(
            to: .reviewed,
            at: testCompletedAt.addingTimeInterval(10)
        ))
        XCTAssertThrowsError(try active.transitioned(to: .planned, at: testCompletedAt))
        XCTAssertThrowsError(try active.transitioned(
            to: .reviewed,
            at: testCreatedAt
        ))
        XCTAssertThrowsError(try CourseSession(
            courseID: testCourseID,
            status: .active,
            createdAt: testCreatedAt
        ))
        XCTAssertThrowsError(
            try JSONDecoder().decode(CourseSession.self, from: futureSchemaOnly())
        )
    }

    func testRevisionOverflowFailsWithTypedBoundError() throws {
        let course = try Course(
            id: testCourseID,
            revision: Int64.max,
            name: "Revision 邊界",
            timeZoneIdentifier: "Asia/Taipei",
            createdAt: testCreatedAt
        )
        XCTAssertThrowsError(try course.replacingScheduleRules(
            [],
            at: testCreatedAt.addingTimeInterval(1)
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .valueOutOfBounds(field: "revision")
            )
        }
    }

    func testOnlyOneActiveLinkPerSessionButNoteMaySpanSessions() throws {
        let noteID = NotebookID(testUUID(70))
        let first = try SessionNoteLink(
            id: SessionNoteLinkID(testUUID(71)),
            sessionID: testSessionID,
            noteID: noteID,
            initialPageID: PageID(testUUID(72)),
            linkedAt: testCreatedAt
        )
        let secondSession = CourseSessionID(testUUID(73))
        let second = try SessionNoteLink(
            id: SessionNoteLinkID(testUUID(74)),
            sessionID: secondSession,
            noteID: noteID,
            linkedAt: testCreatedAt
        )
        let canonical = try SessionNoteLink.validatedCollection([second, first])
        XCTAssertEqual(canonical.map(\.id), [first.id, second.id])
        try assertCodableRoundTrip(first)

        let duplicateActive = try SessionNoteLink(
            id: SessionNoteLinkID(testUUID(75)),
            sessionID: testSessionID,
            noteID: NotebookID(testUUID(76)),
            linkedAt: testCreatedAt
        )
        XCTAssertThrowsError(try SessionNoteLink.validatedCollection([first, duplicateActive]))
        XCTAssertThrowsError(try SessionNoteLink.validatedCollection([first, first]))

        let unlinked = try first.unlinking(at: testCreatedAt.addingTimeInterval(10))
        XCTAssertFalse(unlinked.isActive)
        XCTAssertEqual(unlinked.revision, 2)
        XCTAssertThrowsError(try unlinked.unlinking(at: testCreatedAt.addingTimeInterval(20)))
        XCTAssertNoThrow(try SessionNoteLink.validatedCollection([unlinked, duplicateActive]))
        XCTAssertThrowsError(
            try JSONDecoder().decode(SessionNoteLink.self, from: futureSchemaOnly())
        )
    }
}
