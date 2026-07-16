import Foundation
import NextStepDomain
@testable import NotesApp
import XCTest

final class NextStepBetaStoreTests: XCTestCase {
    func testAtomicRoundTripPreservesImmutableUserDeadline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextstep-beta-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var archive = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: now,
            deviceID: DeviceID(),
            timeZoneIdentifier: "Asia/Taipei"
        )
        let deadline = try LocalDay(year: 2026, month: 12, day: 31)
        archive = try NextStepBetaGoalBuilder().addGoal(
            title: "完成論文口試",
            deadline: deadline,
            dailyMinutes: 45,
            to: archive,
            now: now
        )

        let store = NextStepBetaStore(rootURL: root)
        try await store.save(archive)
        let loadedValue = try await store.load()
        let loaded = try XCTUnwrap(loadedValue)
        let persistedDeadline = try XCTUnwrap(loaded.workspace.ultimateGoals.first?.targetDay)

        XCTAssertEqual(persistedDeadline.value, deadline)
        XCTAssertEqual(persistedDeadline.authority, .userConfirmed)
        XCTAssertEqual(persistedDeadline.mutability, .immutable)
        XCTAssertEqual(persistedDeadline.confirmedAt, now)
        XCTAssertEqual(loaded.workspace.userProfile.maximumDailyMinutes, 45)

        let filenames = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(filenames.contains(NextStepBetaStore.archiveFilename))
        XCTAssertFalse(filenames.contains { $0.contains("partial") || $0.hasSuffix(".tmp") })
    }

    func testStoredSourceResolverRejectsTraversal() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextstep-beta-resolve-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NextStepBetaStore(rootURL: root)

        do {
            _ = try await store.resolveStoredSource(relativePath: "../outside.pdf")
            XCTFail("Traversal should be rejected")
        } catch let error as NextStepBetaStoreError {
            XCTAssertEqual(error, .unsafeStoredPath)
        }
    }

    func testV1ArchiveMigratesToCurrentSchemaWithEmptyGroundingState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextstep-beta-v1-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let original = try NextStepBetaWorkspaceFactory().makeEmpty(
            now: now,
            deviceID: DeviceID(),
            timeZoneIdentifier: "Asia/Taipei"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let currentData = try encoder.encode(original)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentData) as? [String: Any]
        )
        object["schemaVersion"] = 1
        object.removeValue(forKey: "grounding")
        let v1Data = try JSONSerialization.data(withJSONObject: object)
        let store = NextStepBetaStore(rootURL: root)

        let migrated = try await store.decodeArchiveForSync(v1Data)
        XCTAssertEqual(migrated.schemaVersion, NextStepBetaArchive.currentSchemaVersion)
        XCTAssertEqual(migrated.deviceID, original.deviceID)
        XCTAssertEqual(migrated.workspace, original.workspace)
        XCTAssertEqual(migrated.currentDecisionID, original.currentDecisionID)
        XCTAssertEqual(migrated.grounding, .empty)

        try await store.save(migrated)
        let loaded = try await store.load()
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertEqual(reloaded.grounding, .empty)
        XCTAssertEqual(reloaded.schemaVersion, NextStepBetaArchive.currentSchemaVersion)
    }
}
