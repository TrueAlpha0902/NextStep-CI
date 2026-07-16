import XCTest

final class NotesAppUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testCreateQuickNoteAndOpenCanvas() throws {
        let app = launchIsolatedApp()

        let quickNote = app.buttons["library.quickNote"]
        XCTAssertTrue(waitUntilInteractable(quickNote, timeout: 15))
        quickNote.tap()

        // Creation/navigation and editor setup are separate observable phases.
        XCTAssertTrue(app.navigationBars["Quick Note"].waitForExistence(timeout: 15))
        let canvas = app.descendants(matching: .any)["notebook.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        XCTAssertTrue(
            app.buttons["editor.exportNotebookPDF"].waitForExistence(timeout: 10),
            "The whole-notebook PDF action should remain distinct from editor.share"
        )
        captureScreen("Quick-Note-Canvas")

        let navigator = app.buttons["pageNavigator.open"]
        XCTAssertTrue(waitUntilInteractable(navigator, timeout: 5))
        navigator.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pageNavigator.filter"]
            .waitForExistence(timeout: 5))
        captureScreen("Page-Navigator")
        let done = app.buttons["Done"]
        XCTAssertTrue(waitUntilInteractable(done, timeout: 5))
        done.tap()

        let search = app.buttons["editor.search.open"]
        XCTAssertTrue(waitUntilInteractable(search, timeout: 5))
        search.tap()
        XCTAssertTrue(app.descendants(matching: .any)["editor.search.navigator"]
            .waitForExistence(timeout: 5))
        captureScreen("Note-Search")
    }

    @MainActor
    func testLibraryDestinationsAreReachable() throws {
        let app = launchIsolatedApp()

        XCTAssertTrue(app.staticTexts["NextStep"].waitForExistence(timeout: 5))
        let newNote = app.buttons["library.new"]
        XCTAssertTrue(waitUntilInteractable(newNote, timeout: 15))
        XCTAssertTrue(app.cells["library.courses"].exists || app.staticTexts["Courses"].exists)
        XCTAssertTrue(app.cells["library.documents"].exists || app.staticTexts["Documents"].exists)
        XCTAssertTrue(app.cells["library.favorites"].exists || app.staticTexts["Favorites"].exists)
        XCTAssertTrue(app.cells["library.trash"].exists || app.staticTexts["Trash"].exists)
        XCTAssertTrue(app.cells["library.settings"].exists || app.staticTexts["Settings"].exists)

        let addCourse = app.buttons["courses.add"]
        XCTAssertTrue(waitUntilInteractable(addCourse, timeout: 15))
        addCourse.tap()

        let newCourseForm = app.descendants(matching: .any)["newCourse.form"]
        XCTAssertTrue(newCourseForm.waitForExistence(timeout: 15))
        XCTAssertTrue(waitForUsableFrame(newCourseForm, timeout: 10))
        let courseName = app.textFields["newCourse.name"]
        XCTAssertTrue(waitUntilInteractable(courseName, timeout: 15))
        courseName.tap()
        courseName.typeText("Biochemistry")
        let createCourse = app.buttons["newCourse.create"]
        XCTAssertTrue(waitUntilInteractable(createCourse, timeout: 10))
        createCourse.tap()

        let savedCourse = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Biochemistry"))
            .firstMatch
        XCTAssertTrue(savedCourse.waitForExistence(timeout: 15))

        // The academic sidecar shares the isolated Notes root and must survive
        // a complete process relaunch without relying on cloud services.
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(waitUntilInteractable(newNote, timeout: 15))
        XCTAssertTrue(savedCourse.waitForExistence(timeout: 15))
        savedCourse.tap()
        XCTAssertTrue(app.navigationBars["Biochemistry"].waitForExistence(timeout: 5))

        let editSchedule = app.buttons["course.editSchedule"]
        XCTAssertTrue(waitUntilInteractable(editSchedule, timeout: 5))
        editSchedule.tap()
        XCTAssertTrue(app.navigationBars["Edit schedule"].waitForExistence(timeout: 5))
        let addClassTime = app.buttons["courseSchedule.add"]
        XCTAssertTrue(waitUntilInteractable(addClassTime, timeout: 5))
        addClassTime.tap()
        captureScreen("Course-Schedule")
        let saveSchedule = app.buttons["courseSchedule.save"]
        XCTAssertTrue(waitUntilInteractable(saveSchedule, timeout: 5))
        saveSchedule.tap()
        XCTAssertTrue(app.descendants(matching: .any)["course.schedule.rule"]
            .waitForExistence(timeout: 10))
        captureScreen("Course-Detail")

        let startSession = app.buttons["course.startSession"]
        XCTAssertTrue(waitUntilInteractable(startSession, timeout: 10))
        startSession.tap()

        let sessionStatus = app.descendants(matching: .any)["session.status"]
        let didOpenSession = sessionStatus.waitForExistence(timeout: 45)
        if !didOpenSession {
            attachCurrentAppState(
                app,
                name: "Session-Start-Failure",
                note: "starting=\(app.descendants(matching: .any)["course.session.starting"].exists), recovery=\(app.descendants(matching: .any)["course.session.recovery"].exists)"
            )
        }
        XCTAssertTrue(
            didOpenSession,
            "Starting a class must either open its saved workspace or expose a recovery state."
        )

        // The CourseSession, typed note link, exact Notes package, and active
        // transition must all survive a process relaunch with the same IDs.
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(waitUntilInteractable(newNote, timeout: 15))

        let relaunchedCourse = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Biochemistry"))
            .firstMatch
        XCTAssertTrue(waitUntilInteractable(relaunchedCourse, timeout: 15))
        relaunchedCourse.tap()
        XCTAssertTrue(app.navigationBars["Biochemistry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["course.schedule.rule"]
            .waitForExistence(timeout: 5))

        let activeSession = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "In progress"))
            .firstMatch
        XCTAssertTrue(waitUntilInteractable(activeSession, timeout: 15))
        activeSession.tap()
        XCTAssertTrue(sessionStatus.waitForExistence(timeout: 15))

        captureScreen("Session-Workspace")

        let addSessionBlock = app.buttons["text-document.empty.add"]
        XCTAssertTrue(waitUntilInteractable(addSessionBlock, timeout: 10))
        addSessionBlock.tap()
        let sessionBlock = app.descendants(matching: .any)[
            "text-document.block.input"
        ].firstMatch
        XCTAssertTrue(sessionBlock.waitForExistence(timeout: 20))
        if waitUntilInteractable(sessionBlock, timeout: 5) {
            sessionBlock.tap()
        } else {
            XCTAssertTrue(
                app.keyboards.firstMatch.exists,
                "The newly inserted block must be either tappable or already focused."
            )
        }
        sessionBlock.typeText("Professor emphasized this pathway")

        let emphasisMarker = app.buttons["capture.kind.professorEmphasis"]
        XCTAssertTrue(waitUntilInteractable(emphasisMarker, timeout: 10))
        emphasisMarker.tap()
        XCTAssertTrue(app.descendants(matching: .any)["capture.status.succeeded"]
            .waitForExistence(timeout: 20))
        let emphasisBadge = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "capture.badge.",
                ".professorEmphasis"
            ))
            .firstMatch
        XCTAssertTrue(emphasisBadge.waitForExistence(timeout: 10))
        captureScreen("Session-Capture")

        let assignmentMarker = app.buttons["capture.kind.assignmentCandidate"]
        XCTAssertTrue(waitUntilInteractable(assignmentMarker, timeout: 10))
        assignmentMarker.tap()
        let assignmentBadge = captureBadge(
            in: app,
            kind: "assignmentCandidate"
        )
        XCTAssertTrue(assignmentBadge.waitForExistence(timeout: 30))

        let examMarker = app.buttons["capture.kind.examCandidate"]
        XCTAssertTrue(examMarker.waitForExistence(timeout: 10))
        let markerBar = app.descendants(matching: .any)["capture.markerBar"]
        let markerScroll = app.descendants(matching: .any)["capture.markerBar.scroll"]
        let markerViewport: XCUIElement
        // The inner SwiftUI ScrollView can temporarily lose its AX node when a
        // saved marker updates the status row. The outer marker bar remains a
        // stable gesture surface and the drag still begins over a marker in the
        // horizontal ScrollView.
        if waitForUsableFrame(markerBar, timeout: 2) {
            markerViewport = markerBar
        } else if waitForUsableFrame(markerScroll, timeout: 2) {
            markerViewport = markerScroll
        } else {
            markerViewport = app
        }
        XCTAssertTrue(
            revealCaptureMarker(
                examMarker,
                beside: assignmentMarker,
                in: markerViewport,
                timeout: 10
            ),
            "The horizontal capture marker bar must reveal the Exam marker."
        )
        examMarker.tap()
        let examBadge = captureBadge(in: app, kind: "examCandidate")
        XCTAssertTrue(examBadge.waitForExistence(timeout: 30))

        let candidateReview = app.buttons["candidate.review.open"]
        XCTAssertTrue(waitUntilInteractable(candidateReview, timeout: 15))
        candidateReview.tap()
        XCTAssertTrue(app.descendants(matching: .any)["candidate.review.sheet"]
            .waitForExistence(timeout: 30))

        let assignmentRow = candidateRow(
            in: app,
            kind: "assignmentCandidate"
        )
        XCTAssertTrue(waitUntilInteractable(assignmentRow, timeout: 15))
        assignmentRow.tap()
        let candidateTitle = app.textFields["candidate.review.title"]
        XCTAssertTrue(waitUntilInteractable(candidateTitle, timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["candidate.source"]
            .waitForExistence(timeout: 15))
        captureScreen("Candidate-Review")

        candidateTitle.tap()
        candidateTitle.typeText("Metabolism problem set")
        let candidateDetail = app.descendants(matching: .any)[
            "candidate.review.detail"
        ]
        let needsDetails = app.buttons["candidate.review.needsDetails"]
        XCTAssertTrue(reveal(needsDetails, in: candidateDetail, timeout: 15))
        needsDetails.tap()
        XCTAssertTrue(
            waitForLabel(
                assignmentRow,
                containing: "Needs details",
                timeout: 30
            )
        )

        let ready = app.buttons["candidate.review.ready"]
        XCTAssertTrue(reveal(ready, in: candidateDetail, timeout: 15))
        ready.tap()
        XCTAssertTrue(
            waitForLabel(
                assignmentRow,
                containing: "Ready for later confirmation",
                timeout: 30
            )
        )
        let saveDraft = app.buttons["candidate.review.saveDraft"]
        XCTAssertTrue(reveal(saveDraft, in: candidateDetail, timeout: 15))

        let examRow = candidateRow(in: app, kind: "examCandidate")
        XCTAssertTrue(waitUntilInteractable(examRow, timeout: 15))
        examRow.tap()
        let rejectionReason = app.textFields[
            "candidate.review.rejectionReason"
        ]
        XCTAssertTrue(reveal(rejectionReason, in: candidateDetail, timeout: 15))
        rejectionReason.tap()
        rejectionReason.typeText("Duplicate announcement")
        let reject = app.buttons["candidate.review.reject"]
        XCTAssertTrue(reveal(reject, in: candidateDetail, timeout: 15))
        reject.tap()
        XCTAssertTrue(
            waitForLabel(examRow, containing: "Rejected", timeout: 30)
        )
        captureScreen("Candidate-Review-Completed")

        let candidateDone = app.navigationBars["Candidates"].buttons["Done"]
        XCTAssertTrue(waitUntilInteractable(candidateDone, timeout: 10))
        candidateDone.tap()

        let endClass = app.buttons["session.end.open"]
        XCTAssertTrue(waitUntilInteractable(endClass, timeout: 15))
        endClass.tap()
        XCTAssertTrue(app.descendants(matching: .any)["session.end.sheet"]
            .waitForExistence(timeout: 30))
        XCTAssertTrue(app.descendants(matching: .any)["session.end.notesSaved"].exists)
        captureScreen("Session-End")
        let reviewLater = app.buttons["session.end.reviewLater"]
        XCTAssertTrue(waitUntilInteractable(reviewLater, timeout: 10))
        reviewLater.tap()
        let reviewClass = app.buttons["session.wrapUp.open"]
        XCTAssertTrue(
            waitUntilInteractable(reviewClass, timeout: 30)
        )
        XCTAssertTrue(waitForLabel(reviewClass, containing: "Review class", timeout: 5))

        // The note, exact SourceAnchors, reviewed Candidate states, and the
        // recoverable Needs Review session all survive a complete relaunch.
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(waitUntilInteractable(newNote, timeout: 15))
        let capturedCourse = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Biochemistry"))
            .firstMatch
        XCTAssertTrue(waitUntilInteractable(capturedCourse, timeout: 15))
        capturedCourse.tap()
        let capturedSession = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "Needs review"))
            .firstMatch
        XCTAssertTrue(waitUntilInteractable(capturedSession, timeout: 15))
        capturedSession.tap()
        let reopenedSessionBlock = app.descendants(matching: .any)[
            "text-document.block.input"
        ].firstMatch
        XCTAssertTrue(reopenedSessionBlock.waitForExistence(timeout: 15))
        XCTAssertEqual(
            reopenedSessionBlock.value as? String,
            "Professor emphasized this pathway"
        )
        XCTAssertTrue(emphasisBadge.waitForExistence(timeout: 15))
        XCTAssertTrue(assignmentBadge.waitForExistence(timeout: 15))
        XCTAssertTrue(examBadge.waitForExistence(timeout: 15))

        let openWrapUp = app.buttons["session.wrapUp.open"]
        XCTAssertTrue(waitUntilInteractable(openWrapUp, timeout: 15))
        openWrapUp.tap()
        XCTAssertTrue(app.descendants(matching: .any)["session.wrapUp.sheet"]
            .waitForExistence(timeout: 30))
        let wrapUpForm = app.descendants(matching: .any)["session.wrapUp.form"]
        let summary = app.textFields["session.wrapUp.summary"]
        XCTAssertTrue(reveal(summary, in: wrapUpForm, timeout: 15))
        summary.tap()
        summary.typeText("Metabolism pathways and the next problem set")
        captureScreen("Session-Wrap-Up")
        let finishReview = app.buttons["session.wrapUp.finish"]
        XCTAssertTrue(waitUntilInteractable(finishReview, timeout: 15))
        finishReview.tap()
        XCTAssertTrue(app.descendants(matching: .any)["session.reviewed"]
            .waitForExistence(timeout: 30))
        captureScreen("Session-Reviewed")

        // The completed wrap-up and original Notes content remain durable.
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()
        XCTAssertTrue(waitUntilInteractable(newNote, timeout: 15))
        let reviewedCourse = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Biochemistry"))
            .firstMatch
        XCTAssertTrue(waitUntilInteractable(reviewedCourse, timeout: 15))
        reviewedCourse.tap()
        let reviewedSession = app.buttons
            .matching(NSPredicate(format: "label CONTAINS %@", "Reviewed"))
            .firstMatch
        XCTAssertTrue(waitUntilInteractable(reviewedSession, timeout: 15))
        reviewedSession.tap()
        XCTAssertTrue(app.descendants(matching: .any)["session.reviewed"]
            .waitForExistence(timeout: 15))
        let finalSessionBlock = app.descendants(matching: .any)[
            "text-document.block.input"
        ].firstMatch
        XCTAssertTrue(finalSessionBlock.waitForExistence(timeout: 15))
        XCTAssertEqual(
            finalSessionBlock.value as? String,
            "Professor emphasized this pathway"
        )
        XCTAssertTrue(emphasisBadge.waitForExistence(timeout: 15))
        XCTAssertTrue(assignmentBadge.waitForExistence(timeout: 15))
        XCTAssertTrue(examBadge.waitForExistence(timeout: 15))
    }

    @MainActor
    func testImmediateQuickNoteWaitsForBootstrapAndRemainsVisible() throws {
        let app = launchIsolatedApp(slowBootstrap: true)

        let quickNote = app.buttons["library.quickNote"]
        XCTAssertTrue(waitUntilInteractable(quickNote, timeout: 15))
        quickNote.tap()

        XCTAssertTrue(app.navigationBars["Quick Note"].waitForExistence(timeout: 15))
        let canvas = app.descendants(matching: .any)["notebook.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))

        // The delayed snapshot has already completed before creation is allowed.
        // Keeping this assertion after an additional delay catches regressions
        // where the stale bootstrap result removes the newly-created summary.
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(canvas.exists)
        XCTAssertTrue(app.staticTexts["Quick Note"].exists)
    }

    @MainActor
    func testCreateTextDocumentEditAndReopenPersistedContent() throws {
        let app = launchIsolatedApp()

        let newNote = app.buttons["library.new"]
        XCTAssertTrue(waitUntilInteractable(newNote, timeout: 15))
        newNote.tap()

        XCTAssertTrue(app.navigationBars["New note"].waitForExistence(timeout: 5))
        let form = app.descendants(matching: .any)["newNotebook.form"]
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        let textDocumentKind = app.buttons["newNotebook.kind.textDocument"]
        XCTAssertTrue(textDocumentKind.waitForExistence(timeout: 5))
        if !textDocumentKind.isHittable {
            form.swipeUp()
        }
        XCTAssertTrue(waitUntilInteractable(textDocumentKind, timeout: 3))
        textDocumentKind.tap()

        let titleField = app.textFields["newNotebook.title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        if !titleField.isHittable {
            form.swipeDown()
        }
        XCTAssertTrue(waitUntilInteractable(titleField, timeout: 3))
        titleField.tap()
        titleField.typeText("Structured UI")
        let keyboard = app.keyboards.firstMatch
        if keyboard.waitForExistence(timeout: 1) {
            // Use an app-owned inline control instead of depending on the
            // system keyboard accessory hierarchy, which can be exposed late.
            let done = app.buttons["newNotebook.title.done"]
            XCTAssertTrue(waitUntilInteractable(done, timeout: 10))
            done.tap()
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        }
        let create = app.buttons["newNotebook.create"]
        XCTAssertTrue(waitUntilInteractable(create, timeout: 3))
        create.tap()

        let editor = app.descendants(matching: .any)["text-document.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        let addBlock = app.buttons["text-document.empty.add"]
        XCTAssertTrue(addBlock.waitForExistence(timeout: 15))
        addBlock.tap()

        let bodyField = app.descendants(matching: .any)["text-document.block.input"].firstMatch
        XCTAssertTrue(bodyField.waitForExistence(timeout: 15))
        bodyField.tap()
        bodyField.typeText("Persisted text")

        // Observe the app's durable-save state instead of racing the debounce
        // timer. The second launch reuses this isolated library without reset.
        let savedByIdentifier = app.descendants(matching: .any)["text-document.save.saved"]
        let savedByLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Document saved"))
            .firstMatch
        if !savedByIdentifier.waitForExistence(timeout: 7) {
            XCTAssertTrue(savedByLabel.waitForExistence(timeout: 3))
        }
        app.terminate()
        app.launchArguments = ["-ui-testing"]
        app.launch()

        // The Label propagates its identifier to both its icon and text on
        // iPadOS 26. Target the uniquely labeled text instead of whichever
        // descendant XCTest happens to return first.
        let documentsDestination = app.staticTexts["Documents"]
        XCTAssertTrue(waitUntilInteractable(documentsDestination, timeout: 15))
        documentsDestination.tap()

        let savedNote = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Structured UI"))
            .firstMatch
        XCTAssertTrue(savedNote.waitForExistence(timeout: 15))
        savedNote.tap()
        let reopenedField = app.descendants(matching: .any)["text-document.block.input"].firstMatch
        XCTAssertTrue(reopenedField.waitForExistence(timeout: 15))
        XCTAssertEqual(reopenedField.value as? String, "Persisted text")
        captureScreen("Text-Document")
    }

    @MainActor
    func testCaptureNavigationAndCreationScreens() throws {
        let app = launchIsolatedApp()

        XCTAssertTrue(app.staticTexts["NextStep"].waitForExistence(timeout: 5))
        let addCourse = app.buttons["courses.add"]
        XCTAssertTrue(waitUntilInteractable(addCourse, timeout: 15))
        captureScreen("Home")

        addCourse.tap()
        let newCourseForm = app.descendants(matching: .any)["newCourse.form"]
        XCTAssertTrue(newCourseForm.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForUsableFrame(newCourseForm, timeout: 10))
        captureScreen("New-Course")
        let cancelCourse = app.buttons["newCourse.cancel"]
        XCTAssertTrue(waitUntilInteractable(cancelCourse, timeout: 10))
        cancelCourse.tap()
        XCTAssertTrue(newCourseForm.waitForNonExistence(timeout: 10))

        let documents = app.staticTexts["Documents"]
        XCTAssertTrue(waitUntilInteractable(documents, timeout: 10))
        documents.tap()
        XCTAssertTrue(app.navigationBars["Documents"].waitForExistence(timeout: 5))
        captureScreen("Documents")

        let newNote = app.buttons["library.new"]
        XCTAssertTrue(waitUntilInteractable(newNote, timeout: 10))
        newNote.tap()
        XCTAssertTrue(app.descendants(matching: .any)["newNotebook.form"]
            .waitForExistence(timeout: 5))
        captureScreen("New-Note")
        let cancelNote = app.navigationBars["New note"].buttons["Cancel"]
        XCTAssertTrue(waitUntilInteractable(cancelNote, timeout: 5))
        cancelNote.tap()

        let favorites = app.staticTexts["Favorites"]
        XCTAssertTrue(waitUntilInteractable(favorites, timeout: 5))
        favorites.tap()
        XCTAssertTrue(app.navigationBars["Favorites"].waitForExistence(timeout: 5))
        captureScreen("Favorites")

        let trash = app.staticTexts["Trash"]
        XCTAssertTrue(waitUntilInteractable(trash, timeout: 5))
        trash.tap()
        XCTAssertTrue(app.navigationBars["Trash"].waitForExistence(timeout: 5))
        captureScreen("Trash")

        let settings = app.staticTexts["Settings"]
        XCTAssertTrue(waitUntilInteractable(settings, timeout: 5))
        settings.tap()
        let settingsForm = app.descendants(matching: .any)["settings.form"]
        XCTAssertTrue(settingsForm.waitForExistence(timeout: 10))
        captureScreen("Settings")
        settingsForm.swipeUp()
        settingsForm.swipeUp()
        captureScreen("Settings-Advanced")
    }

    @MainActor
    func testCaptureStudySetAndWhiteboardEditors() throws {
        let app = launchIsolatedApp()
        let newNote = app.buttons["library.new"]
        XCTAssertTrue(waitUntilInteractable(newNote, timeout: 15))

        createNotebook(
            in: app,
            newNoteButton: newNote,
            kindIdentifier: "newNotebook.kind.studySet",
            title: "Study Cards"
        )
        XCTAssertTrue(app.descendants(matching: .any)["study-set.editor"]
            .waitForExistence(timeout: 15))
        captureScreen("Study-Set")

        XCTAssertTrue(waitUntilInteractable(newNote, timeout: 10))
        createNotebook(
            in: app,
            newNoteButton: newNote,
            kindIdentifier: "newNotebook.kind.whiteboard",
            title: "Ideas Board"
        )
        XCTAssertTrue(app.descendants(matching: .any)["notebook.editor"]
            .waitForExistence(timeout: 15))
        captureScreen("Whiteboard")
    }

    @MainActor
    func testNextStepResponsiveCoreScreens() throws {
        let lightApp = launchResponsiveApp(dark: false)
        try captureResponsiveCoreScreens(in: lightApp, colorScheme: "Light")
        lightApp.terminate()

        let darkApp = launchResponsiveApp(dark: true)
        try captureResponsiveCoreScreens(in: darkApp, colorScheme: "Dark")
    }

    @MainActor
    func testNextStepBetaNativeFlow() throws {
        for (colorScheme, dark) in [("Light", false), ("Dark", true)] {
            let app = launchNextStepBetaFixture(dark: dark)
            try exerciseNextStepBetaFlow(in: app, colorScheme: colorScheme)
            app.terminate()
        }
    }

    @MainActor
    func testNextStepBetaSourceFactReviewFlow() throws {
        let app = launchNextStepBetaFixture(dark: false)
        defer { app.terminate() }

        let compactRoot = app.descendants(matching: .any)["nextstep.beta.compact.root"]
        let regularRoot = app.descendants(matching: .any)["nextstep.beta.regular.root"]
        let rootExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in compactRoot.exists || regularRoot.exists },
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [rootExpectation], timeout: 15),
            .completed,
            app.debugDescription
        )

        openNextStepBetaDestination(
            compactLabel: "來源",
            regularIdentifier: "nextstep.beta.sidebar.sources",
            in: app
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["nextstep.beta.screen.sources"]
                .waitForExistence(timeout: 10)
        )

        let candidate = app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@",
                "nextstep.beta.grounding.candidate."
            ))
            .firstMatch
        XCTAssertTrue(candidate.waitForExistence(timeout: 10))

        let review = app.descendants(matching: .any)[
            "nextstep.beta.grounding.screen.review"
        ]
        if review.waitForExistence(timeout: 2) == false {
            XCTAssertTrue(waitUntilInteractable(candidate, timeout: 10))
            candidate.tap()
        }
        XCTAssertTrue(review.waitForExistence(timeout: 10))

        let candidateValue = app.descendants(matching: .any)[
            "nextstep.beta.grounding.candidateValue"
        ]
        XCTAssertTrue(candidateValue.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(candidateValue, containing: "2026-09-30", timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["nextstep.beta.grounding.passage"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["nextstep.beta.grounding.factDiff"]
                .waitForExistence(timeout: 10)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["nextstep.beta.grounding.replanDiff"]
                .waitForExistence(timeout: 10)
        )

        let accept = app.buttons["nextstep.beta.grounding.accept"]
        XCTAssertTrue(waitUntilInteractable(accept, timeout: 10))
        accept.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["nextstep.beta.grounding.confirmed"]
                .waitForExistence(timeout: 15)
        )
    }

    @MainActor
    private func launchNextStepBetaFixture(dark: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-reset-library",
            "-nextstep-beta-ui-test"
        ]
        app.launchArguments.append(
            dark ? "-nextstep-dark-preview" : "-nextstep-light-preview"
        )
        app.launch()
        return app
    }

    @MainActor
    private func exerciseNextStepBetaFlow(
        in app: XCUIApplication,
        colorScheme: String
    ) throws {
        let compactRoot = app.descendants(matching: .any)["nextstep.beta.compact.root"]
        let regularRoot = app.descendants(matching: .any)["nextstep.beta.regular.root"]
        let rootExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in compactRoot.exists || regularRoot.exists },
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [rootExpectation], timeout: 15),
            .completed,
            app.debugDescription
        )
        let usesRegularLayout = regularRoot.exists

        let today = app.descendants(matching: .any)["nextstep.beta.screen.today"]
        XCTAssertTrue(today.waitForExistence(timeout: 10))
        captureBetaNativeScreen("\(colorScheme)-Today")

        let primaryAction = app.descendants(matching: .any)[
            "nextstep.beta.today.primaryAction"
        ]
        let todayScroll = app.scrollViews["nextstep.beta.screen.today"].exists
            ? app.scrollViews["nextstep.beta.screen.today"]
            : app.scrollViews.firstMatch
        XCTAssertTrue(reveal(primaryAction, in: todayScroll, timeout: 10))
        XCTAssertTrue(waitUntilInteractable(primaryAction, timeout: 10))
        XCTAssertTrue(
            waitForLabel(primaryAction, containing: "完成 NextStep Beta 驗收", timeout: 5)
        )
        primaryAction.tap()

        let guided = app.descendants(matching: .any)["nextstep.beta.screen.guided"]
        XCTAssertTrue(guided.waitForExistence(timeout: 10))
        let guidedScroll = app.scrollViews["nextstep.beta.screen.guided"].exists
            ? app.scrollViews["nextstep.beta.screen.guided"]
            : app.scrollViews.firstMatch
        let source = app.descendants(matching: .any)["nextstep.beta.guided.source"]
        let openSource = app.buttons["nextstep.beta.guided.openSource"]
        XCTAssertTrue(reveal(openSource, in: guidedScroll, timeout: 10))
        XCTAssertTrue(source.exists)
        XCTAssertTrue(app.staticTexts["NextStep Beta Evidence.pdf"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "原文可回溯"))
                .firstMatch.exists
        )
        XCTAssertTrue(openSource.exists)
        captureBetaNativeScreen("\(colorScheme)-Guided-Source")

        let start = app.descendants(matching: .any)["nextstep.beta.guided.start"]
        XCTAssertTrue(reveal(start, in: guidedScroll, timeout: 10))
        XCTAssertTrue(waitUntilInteractable(start, timeout: 5))
        start.tap()

        for (questionIndex, optionIndex) in [(0, 0), (1, 1), (2, 2)] {
            let option = app.descendants(matching: .any)[
                "nextstep.beta.guided.quiz.question.\(questionIndex).option.\(optionIndex)"
            ]
            XCTAssertTrue(reveal(option, in: guidedScroll, timeout: 10))
            XCTAssertTrue(waitUntilInteractable(option, timeout: 5))
            option.tap()
            let selectedExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate { object, _ in
                    (object as? XCUIElement)?.isSelected == true
                },
                object: option
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [selectedExpectation], timeout: 3),
                .completed
            )
        }

        let submitQuiz = app.descendants(matching: .any)[
            "nextstep.beta.guided.quiz.submit"
        ]
        XCTAssertTrue(reveal(submitQuiz, in: guidedScroll, timeout: 10))
        XCTAssertTrue(waitUntilInteractable(submitQuiz, timeout: 5))
        submitQuiz.tap()
        let quizPassed = app.descendants(matching: .any)[
            "nextstep.beta.guided.quiz.passed"
        ]
        XCTAssertTrue(quizPassed.waitForExistence(timeout: 15))
        captureBetaNativeScreen("\(colorScheme)-Grounded-Quiz-Passed")

        let draft = app.descendants(matching: .any)[
            "nextstep.beta.guided.completionDraft"
        ]
        XCTAssertTrue(reveal(draft, in: guidedScroll, timeout: 10))
        XCTAssertTrue(waitUntilInteractable(draft, timeout: 5))
        draft.tap()
        draft.typeText(
            "Debt changes the capital structure.\n"
                + "Evidence remains traceable.\n"
                + "Three verified points complete the action."
        )

        let keyboardDone = app.buttons["nextstep.beta.guided.keyboardDone"].firstMatch
        XCTAssertTrue(waitUntilInteractable(keyboardDone, timeout: 10))
        keyboardDone.tap()

        let complete = app.descendants(matching: .any)["nextstep.beta.guided.complete"]
        XCTAssertTrue(reveal(complete, in: guidedScroll, timeout: 10))
        XCTAssertTrue(waitUntilInteractable(complete, timeout: 5))
        complete.tap()

        let completedEvidence = app.descendants(matching: .any)[
            "nextstep.beta.guided.completedEvidence"
        ]
        XCTAssertTrue(completedEvidence.waitForExistence(timeout: 15))
        captureBetaNativeScreen("\(colorScheme)-Completed-Evidence")

        returnFromGuidedTask(in: app, isRegular: usesRegularLayout)
        openNextStepBetaDestination(
            compactLabel: "來源",
            regularIdentifier: "nextstep.beta.sidebar.sources",
            in: app
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["nextstep.beta.screen.sources"]
                .waitForExistence(timeout: 10)
        )
        let syncState = app.descendants(matching: .any)["nextstep.beta.sync.state"]
        XCTAssertTrue(syncState.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(syncState, containing: "尚未設定跨裝置同步", timeout: 5))
        captureBetaNativeScreen("\(colorScheme)-Sources-Sync")

        openNextStepBetaDestination(
            compactLabel: "進度",
            regularIdentifier: "nextstep.beta.sidebar.progress",
            in: app
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["nextstep.beta.screen.progress"]
                .waitForExistence(timeout: 10)
        )
        let progress = app.descendants(matching: .any)[
            "nextstep.beta.progress.percentage"
        ]
        XCTAssertTrue(progress.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(progress, containing: "100%", timeout: 5))
        captureBetaNativeScreen("\(colorScheme)-Progress")

        openNextStepBetaDestination(
            compactLabel: "筆記庫",
            regularIdentifier: "nextstep.beta.sidebar.notesLibrary",
            in: app
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["nextstep.beta.screen.notesBridge"]
                .waitForExistence(timeout: 10)
        )
        captureBetaNativeScreen("\(colorScheme)-Notes-Library-Bridge")

        // iPadOS 26 can omit a SwiftUI styled button's identifier while still
        // exposing its explicit accessibility label. Prefer the identifier,
        // then use the same semantic label that VoiceOver users receive.
        let identifiedOpenLibrary = app.buttons["nextstep.beta.notes.openLibrary"]
        let labeledOpenLibrary = app.buttons
            .matching(NSPredicate(format: "label == %@", "開啟筆記庫"))
            .firstMatch
        let openLibrary = identifiedOpenLibrary.waitForExistence(timeout: 2)
            ? identifiedOpenLibrary
            : labeledOpenLibrary
        XCTAssertTrue(waitUntilInteractable(openLibrary, timeout: 10))
        openLibrary.tap()
        let legacyLibraryReady = usesRegularLayout
            ? app.buttons["library.new"]
            : app.descendants(matching: .any)["library.actions.menu"]
        XCTAssertTrue(legacyLibraryReady.waitForExistence(timeout: 15))
        captureBetaNativeScreen("\(colorScheme)-Notes-Library-Legacy")
    }

    @MainActor
    private func returnFromGuidedTask(
        in app: XCUIApplication,
        isRegular: Bool
    ) {
        let dismissMessage = app.buttons["nextstep.beta.message.dismiss"].firstMatch
        if dismissMessage.waitForExistence(timeout: 2) {
            XCTAssertTrue(waitUntilInteractable(dismissMessage, timeout: 5))
            dismissMessage.tap()
            XCTAssertTrue(dismissMessage.waitForNonExistence(timeout: 5))
        }

        if isRegular {
            let today = app.buttons["nextstep.beta.sidebar.today"]
            XCTAssertTrue(waitUntilInteractable(today, timeout: 5))
            today.tap()
        } else {
            let navigationBar = app.navigationBars["Guided Task"]
            XCTAssertTrue(navigationBar.waitForExistence(timeout: 5))
            let back = navigationBar.buttons.firstMatch
            XCTAssertTrue(waitUntilInteractable(back, timeout: 5))
            back.tap()
        }
        XCTAssertTrue(
            app.descendants(matching: .any)["nextstep.beta.screen.today"]
                .waitForExistence(timeout: 10)
        )
    }

    @MainActor
    private func openNextStepBetaDestination(
        compactLabel: String,
        regularIdentifier: String,
        in app: XCUIApplication
    ) {
        let regularDestination = app.descendants(matching: .any)[regularIdentifier]
        if regularDestination.exists {
            XCTAssertTrue(waitUntilInteractable(regularDestination, timeout: 5))
            regularDestination.tap()
            return
        }
        let compactDestination = app.tabBars.buttons[compactLabel]
        XCTAssertTrue(waitUntilInteractable(compactDestination, timeout: 5))
        compactDestination.tap()
    }

    @MainActor
    private func launchResponsiveApp(dark: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-reset-library",
            "-nextstep-responsive-preview"
        ]
        app.launchArguments.append(
            dark ? "-nextstep-dark-preview" : "-nextstep-light-preview"
        )
        app.launch()
        return app
    }

    @MainActor
    private func captureResponsiveCoreScreens(
        in app: XCUIApplication,
        colorScheme: String
    ) throws {
        let compactRoot = app.descendants(matching: .any)["nextstep.compact.root"]
        let regularRoot = app.descendants(matching: .any)["nextstep.regular.root"]
        let rootExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in compactRoot.exists || regularRoot.exists },
            object: app
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [rootExpectation], timeout: 15),
            .completed
        )
        XCTAssertTrue(app.descendants(matching: .any)["nextstep.screen.today"].exists)
        captureResponsiveScreen("\(colorScheme)-Today")

        let identifiedStart = app.buttons["nextstep.today.start"].firstMatch
        let start = identifiedStart.waitForExistence(timeout: 2)
            ? identifiedStart
            : app.buttons["開始目前行動"].firstMatch
        XCTAssertTrue(waitUntilInteractable(start, timeout: 10))
        start.tap()
        XCTAssertTrue(app.descendants(matching: .any)["nextstep.screen.learning"]
            .waitForExistence(timeout: 10))
        captureResponsiveScreen("\(colorScheme)-Guided-Learning")

        openResponsiveDestination(
            compactLabel: "來源",
            regularIdentifier: "nextstep.sidebar.papers",
            in: app
        )
        XCTAssertTrue(app.descendants(matching: .any)["nextstep.screen.papers"]
            .waitForExistence(timeout: 10))
        captureResponsiveScreen("\(colorScheme)-Paper-Reader")

        openResponsiveDestination(
            compactLabel: "目標",
            regularIdentifier: "nextstep.sidebar.goals",
            in: app
        )
        XCTAssertTrue(app.descendants(matching: .any)["nextstep.screen.goals"]
            .waitForExistence(timeout: 10))
        captureResponsiveScreen("\(colorScheme)-Goals")

        openResponsiveDestination(
            compactLabel: "工作",
            regularIdentifier: "nextstep.sidebar.workspace",
            in: app
        )
        XCTAssertTrue(app.descendants(matching: .any)["nextstep.screen.workspace"]
            .waitForExistence(timeout: 10))
        captureResponsiveScreen("\(colorScheme)-Workspace")
    }

    @MainActor
    private func launchIsolatedApp(slowBootstrap: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing", "-ui-testing-reset-library"]
        if slowBootstrap {
            app.launchArguments.append("-ui-testing-slow-bootstrap")
        }
        app.launch()
        return app
    }

    @MainActor
    private func waitUntilInteractable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var previousFrame: CGRect?
        var stableFrameSamples = 0

        while Date() < deadline {
            guard let frame = usableFrame(of: element) else {
                previousFrame = nil
                stableFrameSamples = 0
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                continue
            }

            if let previousFrame,
               abs(previousFrame.minX - frame.minX) < 0.5,
               abs(previousFrame.minY - frame.minY) < 0.5,
               abs(previousFrame.width - frame.width) < 0.5,
               abs(previousFrame.height - frame.height) < 0.5 {
                stableFrameSamples += 1
            } else {
                stableFrameSamples = 1
            }
            previousFrame = frame

            // XCTest can record an infrastructure failure when `isHittable`
            // is queried while a sheet or navigation transition still reports
            // an invalid activation point. Require a real, stable frame first.
            if stableFrameSamples >= 2,
               element.isEnabled,
               element.isHittable {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return false
    }

    @MainActor
    private func openResponsiveDestination(
        compactLabel: String,
        regularIdentifier: String,
        in app: XCUIApplication
    ) {
        let regularButton = app.buttons[regularIdentifier]
        if regularButton.exists {
            XCTAssertTrue(waitUntilInteractable(regularButton, timeout: 5))
            regularButton.tap()
            return
        }
        let compactButton = app.tabBars.buttons[compactLabel]
        XCTAssertTrue(waitUntilInteractable(compactButton, timeout: 5))
        compactButton.tap()
    }

    @MainActor
    private func createNotebook(
        in app: XCUIApplication,
        newNoteButton: XCUIElement,
        kindIdentifier: String,
        title: String
    ) {
        newNoteButton.tap()
        let form = app.descendants(matching: .any)["newNotebook.form"]
        XCTAssertTrue(form.waitForExistence(timeout: 5))

        let kind = app.buttons[kindIdentifier]
        for _ in 0..<3 {
            if kind.exists { break }
            form.swipeUp()
        }
        XCTAssertTrue(kind.waitForExistence(timeout: 5))
        if !kind.isHittable {
            form.swipeUp()
        }
        XCTAssertTrue(waitUntilInteractable(kind, timeout: 3))
        kind.tap()

        let titleField = app.textFields["newNotebook.title"]
        if !titleField.isHittable {
            form.swipeDown()
        }
        XCTAssertTrue(waitUntilInteractable(titleField, timeout: 3))
        titleField.tap()
        titleField.typeText(title)
        let keyboard = app.keyboards.firstMatch
        if keyboard.waitForExistence(timeout: 1) {
            let done = app.buttons["newNotebook.title.done"]
            XCTAssertTrue(waitUntilInteractable(done, timeout: 10))
            done.tap()
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        }

        let create = app.buttons["newNotebook.create"]
        XCTAssertTrue(waitUntilInteractable(create, timeout: 5))
        create.tap()
    }

    @MainActor
    private func captureBadge(
        in app: XCUIApplication,
        kind: String
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
                "capture.badge.",
                ".\(kind)"
            ))
            .firstMatch
    }

    @MainActor
    private func candidateRow(
        in app: XCUIApplication,
        kind: String
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "identifier BEGINSWITH %@",
                "candidate.review.row.\(kind)."
            ))
            .firstMatch
    }

    @MainActor
    private func reveal(
        _ element: XCUIElement,
        in scrollable: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        guard scrollable.waitForExistence(timeout: min(timeout, 3)),
              waitForUsableFrame(scrollable, timeout: min(timeout, 3))
        else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var hasElementFrame = false
            var shouldScrollDown = false
            if let elementFrame = usableFrame(of: element),
               let viewportFrame = usableFrame(of: scrollable) {
                hasElementFrame = true
                let safeInset = min(48, viewportFrame.height * 0.15)
                let safeViewport = viewportFrame.insetBy(dx: 0, dy: safeInset)
                let visibleFrame = elementFrame.intersection(safeViewport)
                if visibleFrame.isNull == false,
                   visibleFrame.width >= min(elementFrame.width * 0.5, 24),
                   visibleFrame.height >= min(elementFrame.height * 0.5, 24),
                   waitUntilInteractable(element, timeout: 1) {
                    return true
                }
                shouldScrollDown = elementFrame.midY < safeViewport.midY
            }

            // Move an existing target toward the viewport centre. Always
            // swiping up can push a partially visible control underneath the
            // navigation bar and keep it permanently non-hittable. Use a
            // longer gesture for controls that are still well outside the
            // viewport so compact, content-rich screens do not need several
            // slow XCTest drags before the timeout expires.
            if hasElementFrame {
                let elementFrame = usableFrame(of: element)
                let viewportFrame = usableFrame(of: scrollable)
                let isFarFromViewport = if let elementFrame, let viewportFrame {
                    abs(elementFrame.midY - viewportFrame.midY) > viewportFrame.height * 0.75
                } else {
                    false
                }
                let startY: CGFloat
                let endY: CGFloat
                if isFarFromViewport {
                    startY = shouldScrollDown ? 0.2 : 0.8
                    endY = shouldScrollDown ? 0.8 : 0.2
                } else {
                    startY = shouldScrollDown ? 0.4 : 0.6
                    endY = shouldScrollDown ? 0.6 : 0.4
                }
                let start = scrollable.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: startY)
                )
                let end = scrollable.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: endY)
                )
                start.press(forDuration: 0.05, thenDragTo: end)
            } else {
                scrollable.swipeUp()
            }
        }
        return false
    }

    @MainActor
    private func revealCaptureMarker(
        _ marker: XCUIElement,
        beside visibleMarker: XCUIElement,
        in scrollSurface: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        guard marker.waitForExistence(timeout: timeout),
              visibleMarker.waitForExistence(timeout: timeout),
              waitForUsableFrame(scrollSurface, timeout: min(timeout, 3))
        else { return false }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let viewportFrame = usableFrame(of: scrollSurface) else {
                guard waitForUsableFrame(scrollSurface, timeout: 1) else { return false }
                continue
            }
            if let markerFrame = usableFrame(of: marker) {
                let visibleFrame = markerFrame.intersection(viewportFrame)
                if visibleFrame.isNull == false,
                   visibleFrame.width >= min(markerFrame.width * 0.5, 24),
                   visibleFrame.height >= min(markerFrame.height * 0.5, 24),
                   waitUntilInteractable(marker, timeout: 1) {
                    return true
                }
            }

            // Prefer the marker ScrollView when SwiftUI exposes it. The app
            // viewport remains a fallback, but the gesture starts from the
            // actual visible marker instead of a device-specific fixed point.
            let visibleFrame = usableFrame(of: visibleMarker)
            let rawY = visibleFrame.map {
                ($0.midY - viewportFrame.minY) / viewportFrame.height
            } ?? 0.5
            let normalizedY = min(max(rawY, 0.1), 0.9)
            let rawX = visibleFrame.map {
                ($0.midX - viewportFrame.minX) / viewportFrame.width
            } ?? 0.75
            let normalizedX = min(max(rawX, 0.25), 0.88)
            let endX = max(0.08, normalizedX - 0.42)
            let start = scrollSurface.coordinate(
                withNormalizedOffset: CGVector(dx: normalizedX, dy: normalizedY)
            )
            let end = scrollSurface.coordinate(
                withNormalizedOffset: CGVector(dx: endX, dy: normalizedY)
            )
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        return false
    }

    @MainActor
    private func waitForUsableFrame(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let element = object as? XCUIElement else { return false }
                guard element.exists else { return false }
                let frame = element.frame
                return frame.isNull == false
                    && frame.isInfinite == false
                    && frame.width.isFinite
                    && frame.height.isFinite
                    && frame.width > 1
                    && frame.height > 1
            },
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func usableFrame(of element: XCUIElement) -> CGRect? {
        guard element.exists else { return nil }
        let frame = element.frame
        guard frame.isNull == false,
              frame.isInfinite == false,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 1,
              frame.height > 1
        else { return nil }
        return frame
    }

    @MainActor
    private func waitForLabel(
        _ element: XCUIElement,
        containing text: String,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", text),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor
    private func attachCurrentAppState(
        _ app: XCUIApplication,
        name: String,
        note: String
    ) {
        captureScreen(name)
        let attachment = XCTAttachment(
            string: "\(note)\n\n\(app.debugDescription)"
        )
        attachment.name = "Diagnostic-\(name)-Hierarchy"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func captureScreen(_ name: String) {
        guard shouldCaptureFinalPreviews else { return }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "NextStep-iPad-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func captureResponsiveScreen(_ name: String) {
        guard shouldCaptureFinalPreviews else { return }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "NextStep-Responsive-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func captureBetaNativeScreen(_ name: String) {
        guard shouldCaptureFinalPreviews else { return }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "NextStep-Beta-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private var shouldCaptureFinalPreviews: Bool {
        ProcessInfo.processInfo.environment["NEXTSTEP_CAPTURE_FINAL_PREVIEWS"] == "1"
    }
}
