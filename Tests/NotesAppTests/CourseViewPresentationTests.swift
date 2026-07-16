import Foundation
import XCTest
import NextStepAcademic
@testable import NotesApp

final class CourseViewPresentationTests: XCTestCase {
    func testCourseListOrderingUsesNameThenCodeThenIdentifier() throws {
        let timestamp = Date(timeIntervalSince1970: 1_750_000_000)
        let firstID = CourseID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let secondID = CourseID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        let biology = try makeCourse(id: secondID, name: "Biology", code: "B")
        let biologyEarlierCode = try makeCourse(id: secondID, name: "Biology", code: "A")
        let biologyEarlierID = try Course(
            id: firstID,
            code: "A",
            name: "Biology",
            timeZoneIdentifier: "Asia/Taipei",
            createdAt: timestamp
        )
        let chemistry = try makeCourse(id: firstID, name: "Chemistry", code: nil)

        XCTAssertTrue(CourseListOrdering.precedes(biology, chemistry))
        XCTAssertTrue(CourseListOrdering.precedes(biologyEarlierCode, biology))
        XCTAssertTrue(CourseListOrdering.precedes(biologyEarlierID, biologyEarlierCode))
    }

    func testSessionOrderingShowsMostRecentFirst() throws {
        let courseID = CourseID()
        let earlier = try CourseSession(
            id: CourseSessionID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            courseID: courseID,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let later = try CourseSession(
            id: CourseSessionID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
            courseID: courseID,
            createdAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertTrue(CourseDetailOrdering.sessionPrecedes(later, earlier))
        XCTAssertFalse(CourseDetailOrdering.sessionPrecedes(earlier, later))
    }

    func testScheduleFormattingUsesISOWeekdayAndCourseTimeZone() throws {
        let courseID = CourseID()
        let rule = try CourseScheduleRule(
            courseID: courseID,
            isoWeekday: 1,
            startMinute: 9 * 60 + 30,
            durationMinutes: 90,
            timeZoneIdentifier: "Asia/Taipei"
        )
        let locale = Locale(identifier: "en_US")

        XCTAssertEqual(
            CourseDetailFormatting.weekday(forISOWeekday: 1, locale: locale),
            "Monday"
        )
        XCTAssertTrue(
            CourseDetailFormatting.time(for: rule, locale: locale).contains("9:30")
        )
    }

    func testSessionNoteTitleUsesCourseNameAndCourseTimeZone() {
        let title = SessionNoteTitle.make(
            courseName: "Biochemistry",
            at: Date(timeIntervalSince1970: 0),
            timeZoneIdentifier: "Asia/Taipei",
            locale: Locale(identifier: "en_US")
        )

        XCTAssertTrue(title.hasPrefix("Biochemistry — "))
        XCTAssertTrue(title.contains("8:00"))
    }

    func testScheduleDraftRoundTripsRuleIdentityAndLocalTime() throws {
        let courseID = CourseID()
        let source = try CourseScheduleRule(
            courseID: courseID,
            isoWeekday: 4,
            startMinute: 9 * 60 + 45,
            durationMinutes: 135,
            timeZoneIdentifier: "Asia/Taipei"
        )
        let draft = CourseScheduleRuleDraft(rule: source)
        let date = CourseScheduleDraftFormatting.time(
            for: draft.startMinute,
            timeZoneIdentifier: source.timeZoneIdentifier
        )

        XCTAssertEqual(
            CourseScheduleDraftFormatting.startMinute(
                from: date,
                timeZoneIdentifier: source.timeZoneIdentifier
            ),
            source.startMinute
        )
        XCTAssertEqual(
            try draft.makeRule(
                courseID: courseID,
                timeZoneIdentifier: source.timeZoneIdentifier
            ),
            source
        )
        XCTAssertFalse(
            CourseScheduleDraftFormatting.duration(
                minutes: source.durationMinutes,
                locale: Locale(identifier: "en_US")
            ).isEmpty
        )
    }

    private func makeCourse(
        id: CourseID,
        name: String,
        code: String?
    ) throws -> Course {
        try Course(
            id: id,
            code: code,
            name: name,
            timeZoneIdentifier: "Asia/Taipei",
            createdAt: Date(timeIntervalSince1970: 1_750_000_000)
        )
    }
}
