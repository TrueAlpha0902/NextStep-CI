import Foundation
@testable import NotesApp
import XCTest

@MainActor
final class NextStepBetaUITestFixtureTests: XCTestCase {
    func testTodayActionResolvesFixtureSourceAndStoredURL() async throws {
        let model = NextStepBetaUITestFixture.makeModel()

        for _ in 0..<500 {
            if model.loadState == .ready, model.syncState != .restoring {
                break
            }
            try await Task<Never, Never>.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertEqual(model.loadState, .ready)
        XCTAssertNotEqual(model.syncState, .restoring)
        let action = try XCTUnwrap(model.todayPlan?.actions.first?.action)
        let source = try XCTUnwrap(model.source(for: action))

        XCTAssertEqual(action.sourceDocumentIDs, [source.metadata.id])
        XCTAssertEqual(source.displayTitle, "NextStep Beta Evidence.pdf")

        let resolvedURL = await model.sourceURL(for: source)
        let sourceURL = try XCTUnwrap(resolvedURL)
        let fixtureRoot = sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(sourceURL.lastPathComponent, "original.pdf")
        XCTAssertFalse(try Data(contentsOf: sourceURL).isEmpty)
    }
}
