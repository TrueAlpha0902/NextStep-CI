import Foundation
@testable import NextStepDesignSystem
import XCTest

final class NextStepDesignSystemModelTests: XCTestCase {
    func testResponsiveLayoutNeverUsesWideColumnsForCompactSizeClass() {
        XCTAssertEqual(
            NextStepLayoutMode.resolve(width: 1_366, isRegularWidth: false),
            .compact
        )
        XCTAssertEqual(
            NextStepLayoutMode.resolve(width: 390, isRegularWidth: true),
            .compact
        )
    }

    func testResponsiveLayoutUsesBalancedAndExpansiveBreakpoints() {
        XCTAssertEqual(
            NextStepLayoutMode.resolve(width: 679, isRegularWidth: true),
            .compact
        )
        XCTAssertEqual(
            NextStepLayoutMode.resolve(width: 680, isRegularWidth: true),
            .balanced
        )
        XCTAssertEqual(
            NextStepLayoutMode.resolve(width: 1_023, isRegularWidth: true),
            .balanced
        )
        XCTAssertEqual(
            NextStepLayoutMode.resolve(width: 1_024, isRegularWidth: true),
            .expansive
        )
    }

    func testEveryRequiredComponentStateIsRepresented() {
        XCTAssertEqual(
            Set(NextStepComponentState.allCases.map(\.rawValue)),
            Set([
                "default",
                "pressed",
                "selected",
                "disabled",
                "loading",
                "completed",
                "overdue",
                "error",
                "offline",
                "aiUncertain",
                "sourceUnavailable",
            ])
        )
        XCTAssertFalse(NextStepComponentState.disabled.allowsInteraction)
        XCTAssertFalse(NextStepComponentState.loading.allowsInteraction)
        XCTAssertFalse(NextStepComponentState.sourceUnavailable.allowsInteraction)
        XCTAssertTrue(NextStepComponentState.offline.allowsInteraction)
        XCTAssertTrue(NextStepComponentState.aiUncertain.allowsInteraction)
    }

    func testHighlightSemanticsAreCompleteAndStable() {
        XCTAssertEqual(NextStepHighlightKind.allCases.count, 5)
        XCTAssertEqual(NextStepHighlightKind.conclusion.title, "核心結論")
        XCTAssertTrue(NextStepHighlightKind.definition.title.contains("公式"))
        XCTAssertTrue(NextStepHighlightKind.application.title.contains("應用"))
        XCTAssertTrue(NextStepHighlightKind.risk.title.contains("風險"))
        XCTAssertTrue(NextStepHighlightKind.connection.title.contains("目標"))
    }

    func testPreviewFixturesProvideExecutableActionsInsteadOfVagueTodos() {
        let actions = NextStepPreviewFixtures.todayActions
        XCTAssertEqual(actions.count, 3)
        XCTAssertTrue(actions.allSatisfy { $0.durationMinutes > 0 })
        XCTAssertTrue(actions.allSatisfy { !$0.reason.isEmpty })
        XCTAssertTrue(actions.allSatisfy { !$0.milestone.isEmpty })
        XCTAssertTrue(actions.allSatisfy { !$0.materialSummary.isEmpty })
        XCTAssertTrue(actions.allSatisfy { !$0.completionOutput.isEmpty })
        XCTAssertEqual(Set(actions.map(\.id)).count, actions.count)
    }

    func testPaperFixtureKeepsVerifiableMetadataAndAnchors() {
        let paper = NextStepPreviewFixtures.paper
        XCTAssertFalse(paper.title.isEmpty)
        XCTAssertFalse(paper.authors.isEmpty)
        XCTAssertFalse(paper.publication.isEmpty)
        XCTAssertFalse(paper.doi.isEmpty)
        XCTAssertTrue(paper.isVerified)
        XCTAssertTrue(paper.highlights.allSatisfy { !$0.sourceLocation.isEmpty })
        XCTAssertTrue(paper.highlights.allSatisfy { !$0.text.isEmpty })
    }

    func testGoalAndProgressInputsAreClamped() {
        let goal = NextStepPreviewGoal(
            title: "Goal",
            deadline: "Tomorrow",
            progress: 9
        )
        let milestone = NextStepPreviewMilestone(
            title: "Milestone",
            dueDate: "Tomorrow",
            progress: -2,
            state: .standard,
            output: "Output"
        )
        XCTAssertEqual(goal.progress, 1)
        XCTAssertEqual(milestone.progress, 0)
    }

    func testCompactNavigationLabelsRemainShortAndUnique() {
        let destinations = NextStepPreviewDestination.allCases
        XCTAssertEqual(destinations.count, 5)
        XCTAssertEqual(Set(destinations.map(\.compactTitle)).count, destinations.count)
        XCTAssertTrue(destinations.allSatisfy { $0.compactTitle.count <= 2 })
        XCTAssertTrue(destinations.allSatisfy { !$0.symbolName.isEmpty })
    }

    func testWorkspaceFixtureCoversThesisProjectAndCareer() {
        let representedKinds = Set(NextStepPreviewFixtures.workspaceItems.map(\.kind))
        XCTAssertEqual(representedKinds, Set(NextStepWorkspaceKind.allCases))
        XCTAssertTrue(NextStepPreviewFixtures.workspaceItems.allSatisfy {
            !$0.nextOutput.isEmpty && $0.sourceCount >= 0
        })
    }
}
