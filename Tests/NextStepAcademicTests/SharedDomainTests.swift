import Foundation
import NotesCore
@testable import NextStepAcademic
import XCTest

final class SharedDomainTests: XCTestCase {
    func testTypedStableIdentifiersMatchNotesCoreCodableShape() throws {
        let id = CourseID(testUUID(10))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(id)) as? [String: Any]
        )
        XCTAssertEqual(object["rawValue"] as? String, testUUID(10).uuidString)

        try assertCodableRoundTrip(id)
        try assertCodableRoundTrip(CourseScheduleRuleID(testUUID(11)))
        try assertCodableRoundTrip(CourseSessionID(testUUID(12)))
        try assertCodableRoundTrip(SessionNoteLinkID(testUUID(13)))
        try assertCodableRoundTrip(SourceAnchorID(testUUID(14)))
        try assertCodableRoundTrip(CaptureItemID(testUUID(15)))
        try assertCodableRoundTrip(CaptureAuditEntryID(testUUID(16)))
        try assertCodableRoundTrip(SessionWrapUpID(testUUID(17)))
    }

    func testEntityReferenceRoundTripsAndFutureSchemaFailsClosed() throws {
        let reference = try AcademicEntityRef(
            entityType: .noteBlock,
            entityID: testUUID(20)
        )
        try assertCodableRoundTrip(reference)

        do {
            _ = try JSONDecoder().decode(
                AcademicEntityRef.self,
                from: futureSchemaOnly()
            )
            XCTFail("A future schema must fail before decoding payload fields.")
        } catch DecodingError.dataCorrupted(let context) {
            XCTAssertTrue(context.debugDescription.contains(
                "Unsupported entity reference schema version 2"
            ))
        } catch {
            XCTFail("Expected a fail-closed schema error, received \(error).")
        }
    }

    func testLocalDateValidatesCalendarAndISOWeekday() throws {
        let monday = try AcademicLocalDate(year: 2026, month: 9, day: 7)
        XCTAssertEqual(monday.description, "2026-09-07")
        XCTAssertEqual(monday.isoWeekday, 1)
        try assertCodableRoundTrip(monday)

        XCTAssertThrowsError(try AcademicLocalDate(year: 2025, month: 2, day: 29))
        XCTAssertNoThrow(try AcademicLocalDate(year: 2024, month: 2, day: 29))
        XCTAssertThrowsError(try AcademicLocalDate(year: 0, month: 1, day: 1))
    }

    func testZonedIntervalValidatesMinutesTimezoneAndDSTGap() throws {
        let date = try AcademicLocalDate(year: 2026, month: 7, day: 14)
        let interval = try AcademicZonedInterval(
            localDate: date,
            startMinute: 9 * 60 + 30,
            durationMinutes: 90,
            timeZoneIdentifier: "Asia/Taipei"
        )
        XCTAssertEqual(interval.isoWeekday, 2)
        XCTAssertEqual(interval.endDate.timeIntervalSince(interval.startDate), 5_400)
        try assertCodableRoundTrip(interval)

        XCTAssertThrowsError(try AcademicZonedInterval(
            localDate: date,
            startMinute: -1,
            durationMinutes: 60,
            timeZoneIdentifier: "Asia/Taipei"
        ))
        XCTAssertThrowsError(try AcademicZonedInterval(
            localDate: date,
            startMinute: 0,
            durationMinutes: 0,
            timeZoneIdentifier: "Asia/Taipei"
        ))
        XCTAssertThrowsError(try AcademicZonedInterval(
            localDate: date,
            startMinute: 0,
            durationMinutes: 60,
            timeZoneIdentifier: "Invalid/Timezone"
        ))

        let springForward = try AcademicLocalDate(year: 2026, month: 3, day: 8)
        XCTAssertThrowsError(try AcademicZonedInterval(
            localDate: springForward,
            startMinute: 2 * 60 + 30,
            durationMinutes: 60,
            timeZoneIdentifier: "America/New_York"
        ))
    }

    func testSourceAnchorIsBlockLevelAndReservesUTF16RangeForLater() throws {
        let anchor = try SourceAnchor(
            id: SourceAnchorID(testUUID(30)),
            noteID: NotebookID(testUUID(31)),
            pageID: PageID(testUUID(32)),
            blockID: TextBlockID(testUUID(33)),
            noteRevision: 4,
            textHash: String(repeating: "a", count: 64),
            capturedAt: testCreatedAt
        )
        XCTAssertNil(anchor.utf16Range)
        try assertCodableRoundTrip(anchor)

        let range = try UTF16TextRange(location: 2, length: 4)
        try assertCodableRoundTrip(range)
        XCTAssertThrowsError(try SourceAnchor(
            noteID: NotebookID(testUUID(31)),
            pageID: PageID(testUUID(32)),
            blockID: TextBlockID(testUUID(33)),
            utf16Range: range,
            noteRevision: 4,
            capturedAt: testCreatedAt
        ))
        XCTAssertThrowsError(try UTF16TextRange(location: 0, length: 0))
        XCTAssertThrowsError(try SourceAnchor(
            noteID: NotebookID(testUUID(31)),
            pageID: PageID(testUUID(32)),
            blockID: TextBlockID(testUUID(33)),
            noteRevision: 4,
            textHash: String(repeating: "A", count: 64),
            capturedAt: testCreatedAt
        ))
        XCTAssertThrowsError(try SourceAnchor(
            noteID: NotebookID(testUUID(31)),
            pageID: PageID(testUUID(32)),
            blockID: TextBlockID(testUUID(33)),
            noteRevision: 4,
            capturedAt: Date(timeIntervalSinceReferenceDate: .infinity)
        )) { error in
            XCTAssertEqual(
                error as? AcademicDomainError,
                .invalidField("sourceAnchor.capturedAt")
            )
        }
        XCTAssertThrowsError(
            try JSONDecoder().decode(SourceAnchor.self, from: futureSchemaOnly())
        )
        XCTAssertThrowsError(try JSONDecoder().decode(
            UTF16TextRange.self,
            from: Data("{\"location\":\"two\",\"length\":4}".utf8)
        )) { error in
            guard case DecodingError.typeMismatch(_, _) = error else {
                return XCTFail("Expected the original typeMismatch, received \(error).")
            }
        }
    }
}
