import XCTest

/// Exercises the real compact Notes library navigation and quick-note path.
final class CompactLegacyNotesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCompactLegacyLibraryCanOpenQuickNote() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-library"]
        app.launch()

        let destinationMenu = app.descendants(matching: .any)["library.destination.menu"]
        XCTAssertTrue(waitUntilInteractable(destinationMenu, timeout: 15))
        destinationMenu.tap()

        let identifiedDocuments = app.descendants(matching: .any)["library.documents"]
        let documents = identifiedDocuments.waitForExistence(timeout: 2)
            ? identifiedDocuments
            : app.buttons["Documents"]
        XCTAssertTrue(waitUntilInteractable(documents, timeout: 5))
        documents.tap()

        let actionsMenu = app.descendants(matching: .any)["library.actions.menu"]
        XCTAssertTrue(waitUntilInteractable(actionsMenu, timeout: 5))
        actionsMenu.tap()

        let quickNote = app.buttons["Quick Note"]
        XCTAssertTrue(waitUntilInteractable(quickNote, timeout: 5))
        quickNote.tap()

        let canvas = app.descendants(matching: .any)["notebook.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))

        let navigator = app.buttons["pageNavigator.open"]
        XCTAssertTrue(waitUntilInteractable(navigator, timeout: 10))
        navigator.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["pageNavigator.filter"]
                .waitForExistence(timeout: 10)
        )

        if ProcessInfo.processInfo.environment["NEXTSTEP_CAPTURE_FINAL_PREVIEWS"] == "1" {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "NextStep-Beta-Legacy-Compact-Quick-Note"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    private func waitUntilInteractable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                block: { object, _ in
                    guard let element = object as? XCUIElement else { return false }
                    return element.exists && element.isHittable
                }
            ),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
