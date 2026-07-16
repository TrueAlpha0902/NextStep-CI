import Foundation
import NextStepDomain
import NextStepGrounding
@testable import NotesApp
import XCTest

final class NextStepBetaGroundedPassageTests: XCTestCase {
    func testLegacyGroundingTargetWithoutScopeDefaultsToMilestone() throws {
        let legacy = LegacyGroundingTarget(
            ultimateGoalID: UltimateGoalID(),
            goalID: GoalID(),
            milestoneID: MilestoneID()
        )

        let decoded = try JSONDecoder().decode(
            NextStepBetaGroundingTarget.self,
            from: JSONEncoder().encode(legacy)
        )

        XCTAssertEqual(decoded.ultimateGoalID, legacy.ultimateGoalID)
        XCTAssertEqual(decoded.goalID, legacy.goalID)
        XCTAssertEqual(decoded.milestoneID, legacy.milestoneID)
        XCTAssertEqual(decoded.deadlineScope, .milestone)
    }

    func testExactUTF16OccurrenceHighlightsTheSelectedDuplicateOnly() throws {
        let passage = "🙂 first 2026-09-30; second 2026-09-30."
        let source = passage as NSString
        let first = source.range(of: "2026-09-30")
        let searchRange = NSRange(
            location: NSMaxRange(first),
            length: source.length - NSMaxRange(first)
        )
        let second = source.range(of: "2026-09-30", options: [], range: searchRange)
        let anchorID = SourceAnchorID()
        let occurrence = try DocumentFactOccurrence(
            anchorID: anchorID,
            utf16Start: second.location,
            utf16Length: second.length
        )

        let segments = nextStepBetaGroundedPassageSegments(
            passage: passage,
            occurrences: [occurrence],
            anchorID: anchorID
        )

        XCTAssertEqual(segments.map(\.text).joined(), passage)
        XCTAssertEqual(segments.filter(\.isHighlighted).map(\.text), ["2026-09-30"])
        var utf16Offset = 0
        for segment in segments {
            if segment.isHighlighted {
                XCTAssertEqual(utf16Offset, second.location)
            }
            utf16Offset += segment.text.utf16.count
        }
    }
}

private struct LegacyGroundingTarget: Encodable {
    let ultimateGoalID: UltimateGoalID
    let goalID: GoalID
    let milestoneID: MilestoneID
}
