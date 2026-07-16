import Foundation
import NotesCore
@testable import NextStepAcademic
import XCTest

func testUUID(_ value: Int) -> UUID {
    let suffix = String(value)
    precondition(suffix.count <= 12)
    let padded = String(repeating: "0", count: 12 - suffix.count) + suffix
    return UUID(uuidString: "00000000-0000-0000-0000-\(padded)")!
}

let testCourseID = CourseID(testUUID(1))
let testSessionID = CourseSessionID(testUUID(2))
let testCreatedAt = Date(timeIntervalSince1970: 1_800_000_000)
let testStartedAt = testCreatedAt.addingTimeInterval(60)
let testCompletedAt = testCreatedAt.addingTimeInterval(3_600)

func assertCodableRoundTrip<Value: Codable & Equatable>(
    _ value: Value,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys]
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    let data = try encoder.encode(value)
    XCTAssertEqual(try decoder.decode(Value.self, from: data), value, file: file, line: line)
    XCTAssertEqual(
        try encoder.encode(decoder.decode(Value.self, from: data)),
        data,
        "Canonical ordering should make a second encoding byte-stable.",
        file: file,
        line: line
    )
}

func futureSchemaOnly(_ version: Int = 2) -> Data {
    Data("{\"schemaVersion\":\(version)}".utf8)
}

func makeActiveSession(
    id: CourseSessionID = testSessionID,
    courseID: CourseID = testCourseID
) throws -> CourseSession {
    let planned = try CourseSession(
        id: id,
        courseID: courseID,
        topic: "演算法與資料結構 🧠",
        createdAt: testCreatedAt
    )
    return try planned.transitioned(to: .active, at: testStartedAt)
}

func makeQuickCapture(
    idSeed: Int,
    kind: CaptureKind,
    courseID: CourseID? = testCourseID,
    sessionID: CourseSessionID? = testSessionID,
    title: String? = nil
) throws -> CaptureItem {
    let draft = try CaptureDraftFields(
        title: title,
        details: "教授提醒：這裡很重要 👩🏽‍🏫\n保留 emoji 與繁中。"
    )
    return try CaptureItem.create(
        id: CaptureItemID(testUUID(idSeed)),
        kind: kind,
        source: .quickCapture(try QuickCaptureReference()),
        courseID: courseID,
        sessionID: sessionID,
        rawText: "原始文字 📝 — 中文測試",
        draftFields: draft,
        capturedAt: testStartedAt,
        auditID: CaptureAuditEntryID(testUUID(idSeed + 1_000))
    )
}
