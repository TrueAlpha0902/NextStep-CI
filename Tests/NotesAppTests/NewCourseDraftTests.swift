import Foundation
import XCTest
import NextStepAcademic
@testable import NotesApp

final class NewCourseDraftTests: XCTestCase {
    func testMakeCourseNormalizesFieldsAndUsesV1Defaults() throws {
        let id = CourseID(UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!)
        let timestamp = Date(timeIntervalSince1970: 1_750_000_000)
        let draft = NewCourseDraft(
            name: "  Organic Chemistry  ",
            code: "  CHEM 201  ",
            term: "   ",
            instructor: "  Dr. Lin  "
        )

        let course = try draft.makeCourse(
            id: id,
            timestamp: timestamp,
            timeZoneIdentifier: "Asia/Taipei"
        )

        XCTAssertEqual(course.id, id)
        XCTAssertEqual(course.name, "Organic Chemistry")
        XCTAssertEqual(course.code, "CHEM 201")
        XCTAssertNil(course.term)
        XCTAssertEqual(course.instructor, "Dr. Lin")
        XCTAssertEqual(course.timeZoneIdentifier, "Asia/Taipei")
        XCTAssertEqual(course.status, .active)
        XCTAssertTrue(course.scheduleRules.isEmpty)
        XCTAssertEqual(course.createdAt, timestamp)
        XCTAssertEqual(course.modifiedAt, timestamp)
    }

    func testWhitespaceOnlyNameCannotSubmitAndFailsDomainValidation() {
        let draft = NewCourseDraft(name: " \n ")

        XCTAssertFalse(draft.canSubmit)
        XCTAssertThrowsError(
            try draft.makeCourse(timeZoneIdentifier: "Asia/Taipei")
        ) { error in
            XCTAssertEqual(error as? AcademicDomainError, .invalidField("course.name"))
        }
    }

    func testInvalidTimeZoneStillUsesDomainValidation() {
        let draft = NewCourseDraft(name: "Biology")

        XCTAssertThrowsError(
            try draft.makeCourse(timeZoneIdentifier: "Not/A-Time-Zone")
        ) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .invalidField("course.timeZoneIdentifier")
            )
        }
    }

    func testDefaultCourseUsesTheCurrentSystemTimeZone() throws {
        let course = try NewCourseDraft(name: "Biology").makeCourse()

        XCTAssertEqual(course.timeZoneIdentifier, TimeZone.current.identifier)
    }

    func testMakeCourseBuildsScheduleRulesWithTheFinalCourseIdentifier() throws {
        let id = CourseID(UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!)
        let scheduleID = CourseScheduleRuleID(
            UUID(uuidString: "ABCDEFAB-1234-1234-1234-ABCDEFABCDEF")!
        )
        let draft = NewCourseDraft(
            name: "Investments",
            scheduleRules: [
                CourseScheduleRuleDraft(
                    id: scheduleID,
                    isoWeekday: 2,
                    startMinute: 14 * 60 + 10,
                    durationMinutes: 180
                ),
            ]
        )

        let course = try draft.makeCourse(
            id: id,
            timeZoneIdentifier: "Asia/Taipei"
        )

        let rule = try XCTUnwrap(course.scheduleRules.first)
        XCTAssertEqual(rule.id, scheduleID)
        XCTAssertEqual(rule.courseID, id)
        XCTAssertEqual(rule.isoWeekday, 2)
        XCTAssertEqual(rule.startMinute, 14 * 60 + 10)
        XCTAssertEqual(rule.durationMinutes, 180)
        XCTAssertEqual(rule.timeZoneIdentifier, "Asia/Taipei")
    }
}
