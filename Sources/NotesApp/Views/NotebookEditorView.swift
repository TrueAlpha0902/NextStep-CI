import PencilKit
import NextStepAcademic
import NotesCore
import SwiftUI
import UIKit

struct NotebookEditorView: View {
    @EnvironmentObject private var appModel: AppModel
    @EnvironmentObject private var academicModel: AcademicAppModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("editor.fingerDrawing") private var fingerDrawingEnabled = false
    @AppStorage("editor.fingerDrawing.phone") private var phoneFingerDrawingEnabled = true
    let notebookSummary: LibraryNotebook
    var initialPageID: UUID?
    var academicCaptureContext: AcademicSessionCaptureContext? = nil

    @State private var notebook: EditorNotebook?
    @State private var selectedPageID: UUID?
    @State private var selectedPageLoadID = UUID()
    @State private var drawingData: Data?
    @State private var loadedDrawingPageID: UUID?
    @State private var failedDrawingPageID: UUID?
    @State private var drawingRevision = UUID()
    @State private var canvasElements: [CanvasElement] = []
    @State private var loadedCanvasElementPageID: UUID?
    @State private var failedCanvasElementPageID: UUID?
    @State private var isEditingCanvasElements = false
    @State private var availableCanvasAssets: [AssetDescriptor] = []
    @State private var canvasAssetURLs: [AssetID: URL] = [:]
    @State private var canvasAssetImages: [CanvasElementAssetCacheKey: UIImage] = [:]
    @State private var canvasAssetImageCosts: [CanvasElementAssetCacheKey: Int] = [:]
    @State private var canvasAssetImageCacheOrder: [CanvasElementAssetCacheKey] = []
    @State private var loadingCanvasAssetImages = Set<CanvasElementAssetCacheKey>()
    @State private var suppressedCanvasAssetImageKeys = Set<CanvasElementAssetCacheKey>()
    @State private var elementModeInkPreview: UIImage?
    @State private var showsAddLinkAlert = false
    @State private var newLinkTitle = ""
    @State private var newLinkDestination = "https://"
    @State private var addLinkTargetPageID: UUID?
    @State private var addLinkTargetLoadID: UUID?
    @State private var textDocument = TextDocument()
    @State private var studySet = StudySet()
    @State private var loadedStructuredPageID: UUID?
    @State private var failedStructuredPageID: UUID?
    @State private var resolvedBackground = ResolvedPageBackground(background: .paper(.blank), assetURL: nil)
    @State private var selectedTool: DrawingTool = .pen
    @State private var inkColor: InkColor = .black
    @State private var lineWidth: CGFloat = 4
    @State private var canvasCommand: CanvasCommandRequest?
    @State private var editorSidebarMode: EditorSidebarMode? = .pages
    @State private var showsCompactDocumentSearch = false
    @State private var documentSearchFocusRequestID = UUID()
    @State private var documentSearchInteractionGeneration = UUID()
    @State private var showsSystemToolPicker = false
    @State private var shareURL: URL?
    @State private var showsShareSheet = false
    @State private var singlePageExportTask: Task<Void, Never>?
    @State private var singlePageExportID = UUID()
    @State private var notebookPDFExportTask: Task<Void, Never>?
    @State private var notebookPDFExportID = UUID()
    @State private var notebookPDFExportProgress: NotebookPDFExportProgress?
    @State private var notebookPDFExportIsCancelling = false
    @State private var notebookPDFInteractionGeneration: UInt64 = 0
    @State private var showsPageTools = false
    @State private var showsPageNavigator = false
    @State private var pageNavigatorFilter: PageNavigatorFilter = .all
    @State private var outlineDraft = ""
    @State private var pageNavigationMetadataTask: Task<Void, Never>?
    @State private var pageNavigationMetadataMutationID = UUID()
    @State private var isPageNavigationMetadataMutationInFlight = false
    @State private var showsAudioPanel = false
    @StateObject private var documentSearchModel = NotebookDocumentSearchModel()
    @StateObject private var replayModel = NotebookEditorReplayModel()
    @State private var replayRestorationGeneration = UUID()
    @State private var activeStructuralMutationCount = 0
    @State private var pageSelectionGeneration = UUID()
    @State private var replayAuthoritativeDrawingPageID: UUID?
    @State private var replayAuthoritativeDrawing: PKDrawing?
    @State private var editorSessionLease: EditorSessionLease?
    @State private var structuralMutationTask: Task<Void, Never>?
    @State private var structuralMutationID = UUID()
    @State private var textCapturePhase: TextDocumentCapturePhase = .ready
    @State private var pendingTextCaptureRequest: AcademicTextCaptureRequest?
    @State private var pendingAcademicTextCapture: PendingAcademicTextCapture?
    @State private var textCaptureStatusResetTask: Task<Void, Never>?
    @State private var academicTextCaptureTask: Task<Void, Never>?
    @State private var showsSessionEndConfirmation = false
    @State private var showsSessionWrapUp = false
    @State private var isPreparingSessionLifecycle = false
    @State private var isSavingSessionLifecycle = false
    @State private var sessionLifecycleErrorMessage: String?
    @State private var sessionEndErrorMessage: String?
    @State private var canRetrySessionEnd = false
    @State private var pendingSessionEndRequest: SessionEndRequest?
    @State private var pendingSessionEndReviewNow = false
    @State private var sessionWrapUpDraft: SessionWrapUpDraft?
    @State private var showsCandidateReview = false
    @State private var presentsWrapUpAfterEndDismissal = false

    private var selectedPage: EditorPage? {
        guard let selectedPageID else { return nil }
        return notebook?.pages.first { $0.id == selectedPageID }
    }

    private var academicSession: CourseSession? {
        guard let academicCaptureContext else { return nil }
        return academicModel.workspace.sessions.first {
            $0.id == academicCaptureContext.sessionID
                && $0.courseID == academicCaptureContext.courseID
        }
    }

    private var academicCourse: Course? {
        guard let academicCaptureContext else { return nil }
        return academicModel.workspace.courses.first {
            $0.id == academicCaptureContext.courseID
        }
    }

    private var academicSessionCaptures: [CaptureItem] {
        guard let academicCaptureContext else { return [] }
        return academicModel.workspace.captures.filter {
            $0.sessionID == academicCaptureContext.sessionID
                && $0.courseID == academicCaptureContext.courseID
        }
    }

    private var unresolvedAcademicSessionCaptures: [CaptureItem] {
        academicSessionCaptures.filter { $0.state != .resolved }
    }

    private var isAcademicTextCapturePending: Bool {
        pendingTextCaptureRequest != nil
            || pendingAcademicTextCapture != nil
            || textCapturePhase.inFlightKind != nil
    }

    private var isSessionLifecycleWorking: Bool {
        isPreparingSessionLifecycle || isSavingSessionLifecycle
    }

    private var isSessionLifecycleInteractionLocked: Bool {
        isSessionLifecycleWorking
            || showsCandidateReview
            || showsSessionEndConfirmation
            || showsSessionWrapUp
    }

    private var canPrepareSessionEnd: Bool {
        academicSession?.status == .active
            && academicModel.availability == .ready
            && !isSessionLifecycleWorking
            && !isAcademicTextCapturePending
            && appModel.notebookAudio?.isRecording != true
            && !appModel.isLibraryRootChangeInProgress
            && !replayModel.isMutationLocked
            && activeStructuralMutationCount == 0
            && structuralMutationTask == nil
            && !isPageNavigationMetadataMutationInFlight
    }

    private var canPrepareSessionWrapUp: Bool {
        academicSession?.status == .needsReview
            && academicModel.availability == .ready
            && !isSessionLifecycleWorking
            && !isAcademicTextCapturePending
            && appModel.notebookAudio?.isRecording != true
            && !appModel.isLibraryRootChangeInProgress
            && !replayModel.isMutationLocked
            && activeStructuralMutationCount == 0
            && structuralMutationTask == nil
            && !isPageNavigationMetadataMutationInFlight
    }

    private var canPrepareCandidateReview: Bool {
        guard let status = academicSession?.status,
              status == .active || status == .needsReview || status == .reviewed else {
            return false
        }
        return academicModel.availability == .ready
            && !isSessionLifecycleWorking
            && !isAcademicTextCapturePending
            && appModel.notebookAudio?.isRecording != true
            && !appModel.isLibraryRootChangeInProgress
            && !replayModel.isMutationLocked
            && activeStructuralMutationCount == 0
            && structuralMutationTask == nil
            && !isPageNavigationMetadataMutationInFlight
    }

    private var sessionEndDisabledHint: String {
        if isAcademicTextCapturePending {
            return String(localized: "Finish or discard the pending class marker first.")
        }
        if appModel.notebookAudio?.isRecording == true {
            return String(localized: "Stop and save the audio recording before ending class.")
        }
        if academicModel.availability != .ready {
            return String(localized: "Wait for academic data to become available.")
        }
        if appModel.isLibraryRootChangeInProgress {
            return String(localized: "Wait for the library change to finish.")
        }
        return ""
    }

    private var textDocumentCapturePresentation: TextDocumentCapturePresentation? {
        guard let academicCaptureContext else { return nil }
        let isEnabled = editorSessionLease != nil
            && !appModel.isLibraryRootChangeInProgress
            && (try? AcademicSessionCaptureValidation.validate(
                academicCaptureContext,
                openNotebookID: notebookSummary.id,
                at: Date(),
                in: academicModel.workspace
            )) != nil
        return TextDocumentCapturePresentation(
            isEnabled: isEnabled,
            phase: textCapturePhase
        )
    }

    private var academicMarkerKindsByBlock: [TextBlockID: Set<CaptureKind>] {
        guard let academicCaptureContext,
              let selectedPageID else { return [:] }
        return AcademicSessionCaptureValidation.markerKindsByBlock(
            for: academicCaptureContext,
            pageID: PageID(selectedPageID),
            in: academicModel.workspace
        )
    }

    private var canRequestNoteReplay: Bool {
        NotebookEditorReplayInteractionPolicy.canReserveStart(
            isControllerAvailable: replayModel.isAvailable,
            isMutationLocked: replayModel.isMutationLocked,
            activeStructuralMutationCount: activeStructuralMutationCount
                + (isPageNavigationMetadataMutationInFlight ? 1 : 0),
            hasReplayablePage: notebook?.pages.contains(where: {
                NotebookEditorReplayInteractionPolicy.supportsReplay($0.kind)
            }) ?? false
        )
    }

    private var isDocumentSearchPresented: Bool {
        editorSidebarMode == .search || showsCompactDocumentSearch
    }

    private var canNavigateDocumentSearch: Bool {
        PageNavigationMutationInterlockPolicy.canNavigate(
            isReplayMutationLocked: replayModel.isMutationLocked,
            activeStructuralMutationCount: activeStructuralMutationCount,
            isMetadataMutationInFlight:
                isPageNavigationMetadataMutationInFlight
        )
    }

    private var effectiveFingerDrawingEnabled: Bool {
        CurrentDevicePresentation.isPhone
            ? phoneFingerDrawingEnabled
            : fingerDrawingEnabled
    }

    private var isAudioStructureMutationLocked: Bool {
        appModel.notebookAudio?.isRecording == true
    }

    private struct DocumentSearchSelectionAuthority {
        let generation: UUID
        let query: String
        let result: NotebookDocumentSearchModel.PageResult
    }

    private struct SelectedPageLoadIdentity: Hashable {
        let editorSessionID: UUID?
        let pageID: UUID?
    }

    var body: some View {
        editorPresentations
    }

    private var editorBase: some View {
        Group {
            if let notebook, let selectedPage {
                VStack(spacing: 0) {
                    editorToolbar(notebook: notebook, page: selectedPage)
                    Divider()
                    HStack(spacing: 0) {
                        if editorSidebarMode == .pages,
                           horizontalSizeClass != .compact {
                            thumbnailSidebar(notebook: notebook)
                            Divider()
                        } else if editorSidebarMode == .search,
                                  horizontalSizeClass != .compact {
                            documentSearchNavigator(notebook: notebook)
                                .frame(
                                    minWidth: 300,
                                    idealWidth: 320,
                                    maxWidth: 340,
                                    maxHeight: .infinity
                                )
                            Divider()
                        }
                        editorSurface(notebook: notebook, page: selectedPage)
                    }
                }
            } else {
                ProgressView("Opening note…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .disabled(appModel.isLibraryRootChangeInProgress)
        .allowsHitTesting(!isSessionLifecycleInteractionLocked)
        .accessibilityHidden(isSessionLifecycleInteractionLocked)
        .navigationTitle(notebook?.title ?? notebookSummary.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var editorLifecycle: some View {
        editorBase
        .onAppear {
            if editorSessionLease == nil {
                editorSessionLease = appModel.beginEditorSession(
                    notebookID: notebookSummary.id
                )
            }
        }
        .task(id: editorSessionLease?.id) {
            guard editorSessionLease != nil else { return }
            let model = appModel
            documentSearchModel.configure { [weak model] query, notebookID in
                guard let model else { return [] }
                return await model.searchNotebookContent(
                    query,
                    notebookID: notebookID
                )
            }
            replayModel.configure(controller: appModel.makeNoteReplayController())
            await loadNotebook()
        }
        .task(
            id: SelectedPageLoadIdentity(
                editorSessionID: editorSessionLease?.id,
                pageID: selectedPageID
            )
        ) {
            guard editorSessionLease != nil, selectedPageID != nil else { return }
            await loadSelectedPage()
        }
        .onChange(of: notebookSummary.title) { _, title in
            notebook?.title = title
            invalidateNotebookPDFExport()
        }
        .onChange(of: appModel.isLibraryRootChangeInProgress) { wasChanging, isChanging in
            if isChanging {
                invalidateAcademicTextCapture()
                return
            }
            guard wasChanging, !isChanging, editorSessionLease == nil else { return }
            editorSessionLease = appModel.beginEditorSession(
                notebookID: notebookSummary.id
            )
            guard editorSessionLease != nil else { return }
            Task { await loadNotebook() }
        }
        .onChange(of: initialPageID) { _, pageID in
            handleInitialPageChange(pageID)
        }
        .onChange(of: selectedPageID) { _, pageID in
            if let request = pendingTextCaptureRequest,
               request.pageID != pageID {
                invalidateAcademicTextCapture()
            }
            invalidateNotebookPDFExport()
            synchronizeOutlineDraft(pageID: pageID)
            if showsPageTools { showsPageTools = false }
            if showsAddLinkAlert {
                showsAddLinkAlert = false
                addLinkTargetPageID = nil
                addLinkTargetLoadID = nil
            }
            if !replayModel.isMutationLocked,
               let pageID,
               let notebook {
                appModel.notebookAudio?.enqueuePageMark(
                    notebookID: notebook.id,
                    pageID: pageID
                )
            }
        }
        .onChange(of: academicSession?.status) { previousStatus, status in
            if previousStatus == .active, status != .active {
                invalidateAcademicTextCapture()
            }
            if status == .reviewed {
                sessionWrapUpDraft = nil
                showsSessionWrapUp = false
            }
            if showsSessionEndConfirmation,
               status != .active,
               !isSavingSessionLifecycle {
                showsSessionEndConfirmation = false
                sessionLifecycleErrorMessage = String(
                    localized: "The class status changed while the end confirmation was open. Review the current saved session."
                )
            }
            if showsSessionWrapUp,
               status != .needsReview,
               status != .reviewed {
                sessionWrapUpDraft = nil
                showsSessionWrapUp = false
                sessionLifecycleErrorMessage = String(
                    localized: "The class status changed while review was open. No review decision was overwritten."
                )
            }
            if showsCandidateReview,
               status != .active,
               status != .needsReview,
               status != .reviewed {
                showsCandidateReview = false
                sessionLifecycleErrorMessage = String(
                    localized: "This class is no longer available for candidate review."
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            closeDocumentSearch(restoringPages: true)
            cancelNotebookPDFExport()
            Task {
                let replayEvent: NoteReplayLifecycleEvent = phase == .background
                    ? .enteredBackground
                    : .becameInactive
                let restorationPageID = await replayModel.handleLifecycle(
                    replayEvent
                )
                if let restorationPageID {
                    await restoreAuthoritativeEditorState(
                        preferredPageID: restorationPageID
                    )
                }
                if let notebook {
                    await appModel.notebookAudio?.handleInterruption(notebookID: notebook.id)
                }
                await Task.yield()
                _ = await flushPendingPage()
                // Give UIKit/PencilKit callbacks already queued on the main
                // actor one final turn before releasing the root-change lease.
                await Task.yield()
                _ = await flushPendingPage()
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIApplication.didReceiveMemoryWarningNotification
        )) { _ in
            Task { await replayModel.handleLifecycle(.memoryWarning) }
        }
    }

    private var editorStateObservers: some View {
        editorLifecycle
        .onChange(of: replayModel.currentPageID) { _, pageID in
            handleReplayCurrentPageChange(pageID)
        }
        .onChange(of: replayModel.isMutationLocked) { wasLocked, isLocked in
            if isLocked {
                closeDocumentSearch(restoringPages: true)
                return
            }
            guard wasLocked else { return }
            replayAuthoritativeDrawingPageID = nil
            replayAuthoritativeDrawing = nil
            Task { await restoreAuthoritativeEditorState() }
        }
        .onChange(of: horizontalSizeClass) { _, sizeClass in
            migrateDocumentSearchPresentation(for: sizeClass)
        }
        .onChange(of: notebook?.pages.map(\.id) ?? []) { _, pageIDs in
            guard isDocumentSearchPresented,
                  let notebook,
                  !documentSearchModel.query.trimmingCharacters(
                    in: .whitespacesAndNewlines
                  ).isEmpty else { return }
            documentSearchModel.search(
                documentSearchModel.query,
                notebookID: notebook.id,
                orderedPageIDs: pageIDs
            )
        }
        .onDisappear {
            invalidateAcademicTextCapture()
            let closingLease = editorSessionLease
            let closingStructuralMutationTask = structuralMutationTask
            let closingPageNavigationMetadataTask = pageNavigationMetadataTask
            editorSessionLease = nil
            closeDocumentSearch(restoringPages: false, reset: true)
            invalidateNotebookPDFExport()
            cancelStructuralMutation()
            cancelPageNavigationMetadataMutation()
            if !showsShareSheet {
                removeOwnedShareURL()
            }
            Task { @MainActor in
                defer {
                    if let closingLease {
                        appModel.endEditorSession(closingLease)
                    }
                }
                await closingStructuralMutationTask?.value
                await closingPageNavigationMetadataTask?.value
                _ = await replayModel.handleLifecycle(.editorDismissed)
                if let notebook {
                    await appModel.notebookAudio?.handleInterruption(notebookID: notebook.id)
                }
                _ = await flushPendingPage()
            }
        }
    }

    private var editorPresentations: some View {
        editorStateObservers
        .sheet(isPresented: $showsShareSheet, onDismiss: {
            removeOwnedShareURL()
        }) {
            if let shareURL {
                ActivitySheet(items: [shareURL])
                    .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $showsPageTools) {
            if let notebook, let selectedPage {
                NotebookToolsSheet(notebookID: notebook.id, page: selectedPage)
                    .environmentObject(appModel)
            }
        }
        .sheet(isPresented: $showsPageNavigator) {
            if let notebook {
                PageNavigatorView(
                    notebook: notebook,
                    currentPageID: selectedPageID,
                    canEditMetadata: !replayModel.isMutationLocked
                        && activeStructuralMutationCount == 0
                        && structuralMutationTask == nil
                        && singlePageExportTask == nil
                        && notebookPDFExportTask == nil,
                    isUpdatingMetadata: isPageNavigationMetadataMutationInFlight,
                    canSelectPage: { page in
                        activeStructuralMutationCount == 0
                            && !isPageNavigationMetadataMutationInFlight
                            && replayModel.thumbnailAction != .disabled
                            && (!replayModel.isMutationLocked
                                || NotebookEditorReplayInteractionPolicy
                                    .supportsReplay(page.kind))
                    },
                    onSelectPage: { pageID in
                        Task {
                            await handleThumbnailTap(pageID)
                            if horizontalSizeClass == .compact {
                                showsPageNavigator = false
                            }
                        }
                    },
                    onSaveOutline: { title in
                        updateSelectedPageOutline(title)
                    },
                    onDismiss: {
                        showsPageNavigator = false
                    },
                    filter: $pageNavigatorFilter,
                    outlineDraft: $outlineDraft
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showsAudioPanel, onDismiss: {
            guard replayModel.startReservation != nil else { return }
            Task { await startReservedNoteReplay() }
        }) {
            if let notebook, let audioModel = appModel.notebookAudio {
                NotebookAudioPanel(
                    model: audioModel,
                    notebookID: notebook.id,
                    currentPageID: selectedPageID,
                    pages: notebook.pages,
                    exportDependencies: NotebookAudioExportDependencies(
                        beginExportSession: { notebookID in
                            try await appModel.beginNotebookExport(id: notebookID)
                        },
                        validateExportSession: { session in
                            try await appModel.validateNotebookExportSession(session)
                        },
                        endExportSession: { session in
                            await appModel.endNotebookExport(session)
                        },
                        descriptor: { session, sessionID in
                            try await appModel.audioSessionDescriptorForExport(
                                session: session,
                                sessionID: sessionID
                            )
                        },
                        loadAudioChunk: { session, sessionID, offset, maximumByteCount in
                            try await appModel.loadAudioChunkForExport(
                                session: session,
                                sessionID: sessionID,
                                offset: offset,
                                maximumByteCount: maximumByteCount
                            )
                        },
                        loadTranscript: { session, sessionID in
                            try await appModel.loadAudioTranscriptForExport(
                                session: session,
                                sessionID: sessionID
                            )
                        }
                    ),
                    canStartReplay: canRequestNoteReplay,
                    onRequestReplay: { sessionID in
                        requestNoteReplay(sessionID: sessionID)
                    },
                    prepareRecording: {
                        await prepareAudioRecording()
                    },
                    flushBeforeStoppingRecording: {
                        await flushBeforeStoppingAudioRecording()
                    }
                )
            } else {
                ContentUnavailableView(
                    "Audio unavailable",
                    systemImage: "waveform.slash",
                    description: Text("Audio is not available for this notebook store.")
                )
                .presentationDetents([.medium])
            }
        }
        .sheet(
            isPresented: $showsCompactDocumentSearch,
            onDismiss: {
                if editorSidebarMode != .search {
                    documentSearchInteractionGeneration = UUID()
                    documentSearchModel.cancel()
                }
            }
        ) {
            if let notebook {
                documentSearchNavigator(notebook: notebook)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
        .sheet(
            isPresented: $showsCandidateReview
        ) {
            if let session = academicSession, let academicCourse {
                CandidateReviewSheet(
                    sessionID: session.id,
                    courseTimeZoneIdentifier: academicCourse.timeZoneIdentifier,
                    allowsEditing: session.status != .reviewed
                )
                .environmentObject(appModel)
                .environmentObject(academicModel)
            }
        }
        .sheet(
            isPresented: $showsSessionEndConfirmation,
            onDismiss: handleSessionEndDismissal
        ) {
            SessionEndConfirmationSheet(
                markerCount: unresolvedAcademicSessionCaptures.count,
                candidateCount: unresolvedAcademicSessionCaptures.count(where: {
                    $0.kind.isAssignmentOrExamCandidate
                }),
                isWorking: isSavingSessionLifecycle,
                errorMessage: sessionEndErrorMessage,
                onEndAndReview: {
                    endAcademicSession(reviewNow: true)
                },
                onEndAndReviewLater: {
                    endAcademicSession(reviewNow: false)
                },
                onRetry: canRetrySessionEnd
                    ? { retryAcademicSessionEnd() }
                    : nil
            )
        }
        .sheet(
            isPresented: $showsSessionWrapUp,
            onDismiss: {
                if academicSession?.status != .reviewed {
                    sessionWrapUpDraft = nil
                }
            }
        ) {
            if let sessionWrapUpDraft, let academicCourse {
                SessionWrapUpSheet(
                    draft: sessionWrapUpDraft,
                    courseTimeZoneIdentifier: academicCourse.timeZoneIdentifier,
                    onCompleted: {
                        self.sessionWrapUpDraft = nil
                    }
                )
                .environmentObject(appModel)
                .environmentObject(academicModel)
            }
        }
        .alert("Add link", isPresented: $showsAddLinkAlert) {
            TextField("Link title", text: $newLinkTitle)
            TextField("https://example.com", text: $newLinkDestination)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            Button("Cancel", role: .cancel) {
                addLinkTargetPageID = nil
                addLinkTargetLoadID = nil
            }
            Button("Add") {
                addValidatedLink()
            }
            .disabled(
                replayModel.isMutationLocked
                    || CanvasElementFactory.validatedLinkURL(newLinkDestination) == nil
            )
        } message: {
            Text("Enter a complete HTTP or HTTPS address.")
        }
        .alert(
            "Class workflow unavailable",
            isPresented: Binding(
                get: { sessionLifecycleErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { sessionLifecycleErrorMessage = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                sessionLifecycleErrorMessage = nil
            }
        } message: {
            if let sessionLifecycleErrorMessage {
                Text(verbatim: sessionLifecycleErrorMessage)
            }
        }
        .overlay {
            if isPreparingSessionLifecycle {
                ProgressView("Saving this note before class review")
                    .padding()
                    .background(
                        .regularMaterial,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .accessibilityIdentifier("session.lifecycle.preparing")
            }
        }
    }

    private func handleInitialPageChange(_ pageID: UUID?) {
        guard !replayModel.isMutationLocked,
              !isPageNavigationMetadataMutationInFlight,
              let pageID,
              let notebook,
              notebook.pages.contains(where: { $0.id == pageID }) else { return }
        closeDocumentSearch(restoringPages: true)
        Task { await selectPage(pageID) }
    }

    private func handleReplayCurrentPageChange(_ pageID: PageID?) {
        guard replayModel.isMutationLocked, let pageID else { return }
        let selectedReplayPageID = pageID.rawValue
        guard notebook?.pages.contains(where: {
            $0.id == selectedReplayPageID
        }) == true else { return }
        selectedPageID = selectedReplayPageID
    }

    @ViewBuilder
    private func editorSurface(notebook: EditorNotebook, page: EditorPage) -> some View {
        if replayModel.isMutationLocked {
            if NotebookEditorReplayInteractionPolicy.supportsReplay(page.kind) {
                replayEditorSurface(page: page)
            } else {
                ProgressView("Preparing playback")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("noteReplay.preparing")
            }
        } else {
            switch page.kind {
        case .textDocument:
            if loadedStructuredPageID == page.id {
                TextDocumentPageEditor(
                    document: $textDocument,
                    saveState: appModel.pageContentSaveState(
                        notebookID: notebook.id,
                        pageID: page.id
                    ),
                    onDocumentChanged: { document in
                        guard !replayModel.isMutationLocked,
                              let editorSessionLease else { return }
                        appModel.stagePageContent(
                            .textDocument(document),
                            notebookID: notebook.id,
                            pageID: page.id,
                            editorSession: editorSessionLease
                        )
                    },
                    onRetry: {
                        guard !replayModel.isMutationLocked else { return }
                        Task {
                            _ = await appModel.flushPageContent(
                                notebookID: notebook.id,
                                pageID: page.id
                            )
                        }
                    },
                    capturePresentation: textDocumentCapturePresentation,
                    captureKindsByBlockID: academicMarkerKindsByBlock,
                    onCapture: academicCaptureContext == nil ? nil : {
                        blockID, kind in
                        beginAcademicTextCapture(
                            blockID: blockID,
                            kind: kind,
                            document: textDocument,
                            notebookID: notebook.id,
                            pageID: page.id
                        )
                    },
                    onRetryCapture: pendingTextCaptureRequest == nil
                        && pendingAcademicTextCapture == nil
                        ? nil
                        : {
                            retryAcademicTextCapture(
                                document: textDocument,
                                notebookID: notebook.id,
                                pageID: page.id
                            )
                        },
                    onCancelCapture: pendingTextCaptureRequest == nil
                        && pendingAcademicTextCapture == nil
                        ? nil
                        : {
                            invalidateAcademicTextCapture()
                        }
                )
                .id(page.id)
                .accessibilityIdentifier("text-document.editor")
            } else if failedStructuredPageID == page.id {
                structuredLoadFailure
            } else {
                ProgressView("Loading document")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .studySet:
            if loadedStructuredPageID == page.id {
                StudySetPageEditor(
                    studySet: $studySet,
                    saveState: appModel.pageContentSaveState(
                        notebookID: notebook.id,
                        pageID: page.id
                    ),
                    onStudySetChanged: { studySet in
                        guard !replayModel.isMutationLocked,
                              let editorSessionLease else { return }
                        appModel.stagePageContent(
                            .studySet(studySet),
                            notebookID: notebook.id,
                            pageID: page.id,
                            editorSession: editorSessionLease
                        )
                    },
                    onRetry: {
                        guard !replayModel.isMutationLocked else { return }
                        Task {
                            _ = await appModel.flushPageContent(
                                notebookID: notebook.id,
                                pageID: page.id
                            )
                        }
                    }
                )
                .id(page.id)
                .accessibilityIdentifier("study-set.editor")
            } else if failedStructuredPageID == page.id {
                structuredLoadFailure
            } else {
                ProgressView("Loading study set")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .notebook, .whiteboard, .importedDocument:
            ZStack {
                PencilCanvasView(
                    pageID: page.id,
                    pageSize: CGSize(width: CGFloat(page.width), height: CGFloat(page.height)),
                    resolvedBackground: resolvedBackground,
                    drawingData: loadedDrawingPageID == page.id ? drawingData : nil,
                    drawingRevision: drawingRevision,
                    tool: selectedTool,
                    inkColor: inkColor,
                    lineWidth: lineWidth,
                    fingerDrawingEnabled: effectiveFingerDrawingEnabled,
                    showsSystemToolPicker: showsSystemToolPicker,
                    command: canvasCommand,
                    onDrawingChanged: { data in
                        guard !replayModel.isMutationLocked,
                              selectedPageID == page.id,
                              loadedDrawingPageID == page.id else { return }
                        saveDrawing(data, notebookID: notebook.id, page: page)
                    },
                    onDrawingCommitted: { data in
                        guard !replayModel.isMutationLocked,
                              selectedPageID == page.id,
                              loadedDrawingPageID == page.id else { return }
                        appModel.notebookAudio?.enqueueReplayInkSnapshot(
                            data,
                            notebookID: notebook.id,
                            pageID: page.id
                        )
                    }
                )
                .allowsHitTesting(
                    loadedDrawingPageID == page.id
                        && !isEditingCanvasElements
                        && !replayModel.isMutationLocked
                        && !appModel.isLibraryRootChangeInProgress
                )
                .accessibilityIdentifier("notebook.editor")

                if isEditingCanvasElements,
                   loadedDrawingPageID == page.id,
                   loadedCanvasElementPageID == page.id {
                    canvasElementWorkspace(notebook: notebook, page: page)
                        .id(page.id)
                        .transition(.opacity)
                }

                if failedDrawingPageID == page.id {
                    VStack(spacing: 10) {
                        Label("Could not load ink", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text("This page stays read-only until its saved ink can be loaded safely.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try again") {
                            guard !replayModel.isMutationLocked else { return }
                            Task { await loadSelectedPage() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("notebook.ink.load-failed")
                } else if failedCanvasElementPageID == page.id {
                    VStack(spacing: 10) {
                        Label("Could not load canvas elements", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text("The drawing remains available and existing elements were not replaced.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Try again") {
                            guard !replayModel.isMutationLocked else { return }
                            Task { await loadSelectedPage() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("canvas.elements.load-failed")
                } else if loadedDrawingPageID != page.id || loadedCanvasElementPageID != page.id {
                    ProgressView("Loading ink…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        }
    }

    private func beginAcademicTextCapture(
        blockID: TextBlockID,
        kind: CaptureKind,
        document: TextDocument,
        notebookID: UUID,
        pageID: UUID
    ) {
        guard pendingTextCaptureRequest == nil,
              pendingAcademicTextCapture == nil,
              textCapturePhase.inFlightKind == nil,
              let context = academicCaptureContext,
              let editorSessionLease else { return }

        textCaptureStatusResetTask?.cancel()
        let request = AcademicTextCaptureRequest(
            captureID: CaptureItemID(),
            sourceAnchorID: SourceAnchorID(),
            auditID: CaptureAuditEntryID(),
            kind: kind,
            capturedAt: Date(),
            context: context,
            notebookID: notebookID,
            pageID: pageID,
            blockID: blockID,
            editorSession: editorSessionLease
        )
        pendingTextCaptureRequest = request
        textCapturePhase = .saving(kind)
        academicTextCaptureTask = Task { @MainActor in
            await prepareAndSaveAcademicTextCapture(
                request,
                document: document
            )
        }
    }

    private func prepareAcademicSessionEnd() {
        guard canPrepareSessionEnd else { return }
        sessionLifecycleErrorMessage = nil
        isPreparingSessionLifecycle = true
        Task { @MainActor in
            let didFlush = await flushSessionNotebookForAcademicReview()
            isPreparingSessionLifecycle = false
            guard didFlush else {
                sessionLifecycleErrorMessage = String(
                    localized: "The note could not be saved safely. Class status was not changed. Retry the note save before ending class."
                )
                return
            }
            guard canPrepareSessionEnd else {
                sessionLifecycleErrorMessage = String(
                    localized: "The class changed while its note was being saved. Review the current status and try again."
                )
                return
            }
            sessionEndErrorMessage = nil
            canRetrySessionEnd = false
            pendingSessionEndRequest = nil
            pendingSessionEndReviewNow = false
            showsSessionEndConfirmation = true
        }
    }

    private func prepareAcademicCandidateReview() {
        guard canPrepareCandidateReview else { return }
        sessionLifecycleErrorMessage = nil
        isPreparingSessionLifecycle = true
        Task { @MainActor in
            let didFlush = await flushSessionNotebookForAcademicReview()
            isPreparingSessionLifecycle = false
            guard didFlush else {
                sessionLifecycleErrorMessage = String(
                    localized: "The note could not be saved safely. Candidate review was not opened. Retry the note save first."
                )
                return
            }
            guard canPrepareCandidateReview else {
                sessionLifecycleErrorMessage = String(
                    localized: "The class changed while its note was being saved. Review the current status and try again."
                )
                return
            }
            showsCandidateReview = true
        }
    }

    private func prepareAcademicSessionWrapUp() {
        guard canPrepareSessionWrapUp else { return }
        sessionLifecycleErrorMessage = nil
        isPreparingSessionLifecycle = true
        Task { @MainActor in
            let didFlush = await flushSessionNotebookForAcademicReview()
            isPreparingSessionLifecycle = false
            guard didFlush else {
                sessionLifecycleErrorMessage = String(
                    localized: "The note could not be saved safely. The class review was not opened. Retry the note save first."
                )
                return
            }
            guard canPrepareSessionWrapUp else {
                sessionLifecycleErrorMessage = String(
                    localized: "The class changed while its note was being saved. Review the current status and try again."
                )
                return
            }
            presentAcademicSessionWrapUp()
        }
    }

    private func flushSessionNotebookForAcademicReview() async -> Bool {
        guard let notebook else { return false }
        await Task<Never, Never>.yield()
        guard await appModel.flushPendingWrites(notebookID: notebook.id) else {
            return false
        }
        await Task<Never, Never>.yield()
        return await appModel.flushPendingWrites(notebookID: notebook.id)
    }

    private func endAcademicSession(reviewNow: Bool) {
        guard let session = academicSession,
              session.status == .active,
              !isSavingSessionLifecycle else { return }
        let request = pendingSessionEndRequest ?? SessionEndRequest(
            sessionID: session.id,
            expectedRevision: session.revision,
            endedAt: max(Date(), session.modifiedAt)
        )
        pendingSessionEndRequest = request
        pendingSessionEndReviewNow = reviewNow
        submitAcademicSessionEnd(request)
    }

    private func retryAcademicSessionEnd() {
        guard let request = pendingSessionEndRequest,
              !isSavingSessionLifecycle else { return }
        isSavingSessionLifecycle = true
        Task { @MainActor in
            if case .unavailable = academicModel.availability {
                await academicModel.retry()
            }
            isSavingSessionLifecycle = false
            submitAcademicSessionEnd(request)
        }
    }

    private func submitAcademicSessionEnd(_ request: SessionEndRequest) {
        sessionEndErrorMessage = nil
        canRetrySessionEnd = false
        isSavingSessionLifecycle = true
        Task { @MainActor in
            let outcome = await academicModel.endSession(
                request,
                savedAt: request.endedAt
            )
            isSavingSessionLifecycle = false
            switch outcome {
            case .ended, .alreadyEnded:
                let shouldReviewNow = pendingSessionEndReviewNow
                pendingSessionEndRequest = nil
                pendingSessionEndReviewNow = false
                invalidateAcademicTextCapture()
                presentsWrapUpAfterEndDismissal = shouldReviewNow
                showsSessionEndConfirmation = false

            case .conflict:
                sessionEndErrorMessage = String(
                    localized: "This class changed elsewhere. No class status was overwritten."
                )

            case let .invalid(message):
                sessionEndErrorMessage = message

            case .notReady:
                canRetrySessionEnd = true
                sessionEndErrorMessage = academicModel.failure?.message
                    ?? String(localized: "The note is safe, but the class status could not be saved.")
            }
        }
    }

    private func presentAcademicSessionWrapUp() {
        guard let session = academicSession,
              session.status == .needsReview,
              academicCourse != nil else {
            if academicSession?.status != .reviewed {
                sessionLifecycleErrorMessage = String(
                    localized: "This class is not ready for review. Reopen the saved session and try again."
                )
            }
            return
        }
        do {
            let latestCaptureModifiedAt = academicSessionCaptures
                .map(\.modifiedAt)
                .max() ?? session.modifiedAt
            sessionWrapUpDraft = try SessionWrapUpDraft(
                session: session,
                captures: academicSessionCaptures,
                startedAt: max(
                    Date(),
                    max(session.modifiedAt, latestCaptureModifiedAt)
                )
            )
            showsSessionWrapUp = true
        } catch {
            sessionLifecycleErrorMessage = error.localizedDescription
        }
    }

    private func resetDismissedSessionEnd() {
        guard !isSavingSessionLifecycle else { return }
        sessionEndErrorMessage = nil
        canRetrySessionEnd = false
        pendingSessionEndRequest = nil
        pendingSessionEndReviewNow = false
    }

    private func handleSessionEndDismissal() {
        let shouldPresentWrapUp = presentsWrapUpAfterEndDismissal
        presentsWrapUpAfterEndDismissal = false
        resetDismissedSessionEnd()
        guard shouldPresentWrapUp else { return }
        presentAcademicSessionWrapUp()
    }

    private func retryAcademicTextCapture(
        document: TextDocument,
        notebookID: UUID,
        pageID: UUID
    ) {
        guard let request = pendingTextCaptureRequest,
              request.notebookID == notebookID,
              request.pageID == pageID,
              request.editorSession == editorSessionLease,
              academicCaptureContext == request.context else {
            invalidateAcademicTextCapture()
            return
        }

        textCaptureStatusResetTask?.cancel()
        textCapturePhase = .saving(request.kind)
        academicTextCaptureTask = Task { @MainActor in
            if case .unavailable = academicModel.availability {
                await academicModel.retry()
            }
            guard pendingTextCaptureRequest == request else { return }
            if let pendingAcademicTextCapture {
                await saveAcademicTextCapture(pendingAcademicTextCapture)
            } else {
                await prepareAndSaveAcademicTextCapture(
                    request,
                    document: document
                )
            }
        }
    }

    private func prepareAndSaveAcademicTextCapture(
        _ request: AcademicTextCaptureRequest,
        document: TextDocument
    ) async {
        do {
            try AcademicSessionCaptureValidation.validate(
                request.context,
                openNotebookID: request.notebookID,
                at: request.capturedAt,
                in: academicModel.workspace
            )
            let snapshot = try await appModel.prepareTextBlockSourceSnapshot(
                document: document,
                notebookID: request.notebookID,
                pageID: request.pageID,
                blockID: request.blockID,
                editorSession: request.editorSession
            )
            guard pendingTextCaptureRequest == request else { return }
            try AcademicSessionCaptureValidation.validate(
                request.context,
                openNotebookID: request.notebookID,
                at: request.capturedAt,
                in: academicModel.workspace
            )
            guard snapshot.noteID == request.context.noteID,
                  snapshot.pageID == PageID(request.pageID),
                  snapshot.blockID == request.blockID else {
                throw TextBlockAnchorPreparationError.invalidSnapshot
            }

            let anchor = try SourceAnchor(
                id: request.sourceAnchorID,
                noteID: snapshot.noteID,
                pageID: snapshot.pageID,
                blockID: snapshot.blockID,
                noteRevision: snapshot.noteRevision,
                textHash: snapshot.textHash,
                capturedAt: request.capturedAt
            )
            let capture = try CaptureItem.create(
                id: request.captureID,
                kind: request.kind,
                source: .noteAnchor(anchor),
                courseID: request.context.courseID,
                sessionID: request.context.sessionID,
                rawText: nil,
                draftFields: CaptureDraftFields(),
                capturedAt: request.capturedAt,
                auditID: request.auditID
            )
            let pending = PendingAcademicTextCapture(
                request: request,
                capture: capture
            )
            pendingAcademicTextCapture = pending
            await saveAcademicTextCapture(pending)
        } catch {
            guard pendingTextCaptureRequest == request else { return }
            pendingAcademicTextCapture = nil
            textCapturePhase = .failed(message: error.localizedDescription)
        }
    }

    private func saveAcademicTextCapture(
        _ pending: PendingAcademicTextCapture
    ) async {
        guard pendingTextCaptureRequest == pending.request,
              pendingAcademicTextCapture == pending else { return }
        do {
            try AcademicSessionCaptureValidation.validate(
                pending.request.context,
                openNotebookID: pending.request.notebookID,
                at: pending.request.capturedAt,
                in: academicModel.workspace
            )
        } catch {
            textCapturePhase = .failed(message: error.localizedDescription)
            return
        }

        let outcome = await academicModel.addCapture(
            pending.capture,
            savedAt: pending.request.capturedAt
        )
        guard pendingTextCaptureRequest == pending.request,
              pendingAcademicTextCapture == pending else { return }
        switch outcome {
        case .inserted, .alreadyPresent:
            pendingTextCaptureRequest = nil
            pendingAcademicTextCapture = nil
            textCapturePhase = .succeeded(
                message: String(localized: "Class marker saved.")
            )
            scheduleTextCaptureStatusReset()
        case .identifierConflict:
            pendingTextCaptureRequest = nil
            pendingAcademicTextCapture = nil
            textCapturePhase = .failed(
                message: String(localized: "This class marker conflicts with saved academic data. No duplicate was created.")
            )
            scheduleTextCaptureStatusReset()
        case let .invalid(message):
            pendingTextCaptureRequest = nil
            pendingAcademicTextCapture = nil
            textCapturePhase = .failed(message: message)
            scheduleTextCaptureStatusReset()
        case .notReady:
            textCapturePhase = .failed(
                message: academicModel.failure?.message
                    ?? String(localized: "The class marker is ready, but academic data could not be saved. Retry to use the same marker.")
            )
        }
    }

    private func scheduleTextCaptureStatusReset() {
        textCaptureStatusResetTask?.cancel()
        textCaptureStatusResetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
            guard pendingTextCaptureRequest == nil,
                  pendingAcademicTextCapture == nil else { return }
            textCapturePhase = .ready
        }
    }

    private func invalidateAcademicTextCapture() {
        academicTextCaptureTask?.cancel()
        academicTextCaptureTask = nil
        textCaptureStatusResetTask?.cancel()
        textCaptureStatusResetTask = nil
        pendingTextCaptureRequest = nil
        pendingAcademicTextCapture = nil
        textCapturePhase = .ready
    }

    private func replayEditorSurface(page: EditorPage) -> some View {
        let pageID = PageID(page.id)
        let safeBackground = loadedDrawingPageID == page.id
            ? resolvedBackground
            : ResolvedPageBackground(
                background: page.background,
                assetURL: nil
            )
        let displayableFrame = NotebookEditorReplayFramePolicy.isDisplayable(
            replayModel.currentPageFrame,
            for: pageID,
            playbackTime: replayModel.playbackTime,
            mode: replayModel.mode,
            state: replayModel.state
        ) ? replayModel.currentPageFrame : nil
        let hasMatchingFrame = displayableFrame != nil
        let hasTerminalStaticFallback = replayModel.currentPageFrame == nil
            && (replayModel.pageIssue.map {
            $0.affectedPageID == pageID
                && $0.permitsAuthoritativeDrawingFallback
            } ?? false)
        let isReplayPresentationReady = hasMatchingFrame
            || hasTerminalStaticFallback
        let safeElements = NotebookEditorReplayElementResolver.elements(
            displayedPageID: page.id,
            replayPageID: replayModel.currentPageID,
            frame: displayableFrame,
            authoritativePageID: loadedCanvasElementPageID,
            authoritativeElements: canvasElements,
            allowsAuthoritativeFallbackWithoutFrame: hasTerminalStaticFallback
        )
        let drawing = NotebookEditorReplayDrawingResolver.drawing(
            displayedPageID: page.id,
            replayPageID: replayModel.currentPageID,
            frame: displayableFrame,
            authoritativePageID: replayAuthoritativeDrawingPageID,
            authoritativeDrawing: replayAuthoritativeDrawing,
            allowsAuthoritativeFallbackWithoutFrame: hasTerminalStaticFallback
        )
        return ZStack {
            NotebookEditorReplaySurface(
                page: page,
                resolvedBackground: safeBackground,
                drawing: drawing,
                staticElements: safeElements,
                assetImageResolver: { assetID, request in
                    resolveCanvasAssetImage(
                        assetID: assetID,
                        request: request,
                        pageID: page.id
                    )
                }
            )
            if replayModel.currentPageID != pageID
                || !isReplayPresentationReady
                || loadedDrawingPageID != page.id {
                ProgressView("Preparing playback")
                    .padding()
                    .background(
                        .regularMaterial,
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .accessibilityIdentifier("noteReplay.pageLoading")
            }
        }
    }

    private func canvasElementWorkspace(
        notebook: EditorNotebook,
        page: EditorPage
    ) -> some View {
        GeometryReader { proxy in
            let fittedFrame = CanvasElementWorkspaceLayout.fittedFrame(
                pageSize: CGSize(width: CGFloat(page.width), height: CGFloat(page.height)),
                containerSize: proxy.size
            )
            ZStack {
                PageBackgroundPreview(resolvedBackground: resolvedBackground)

                if let elementModeInkPreview {
                    Image(uiImage: elementModeInkPreview)
                        .resizable()
                        .scaledToFit()
                        .allowsHitTesting(false)
                }

                CanvasElementLayerView(
                    elements: $canvasElements,
                    pageBounds: page.canvasBounds,
                    assetImageResolver: { assetID, request in
                        resolveCanvasAssetImage(
                            assetID: assetID,
                            request: request,
                            pageID: page.id
                        )
                    },
                    onElementsChanged: { elements in
                        guard !replayModel.isMutationLocked,
                              selectedPageID == page.id,
                              loadedDrawingPageID == page.id,
                              loadedCanvasElementPageID == page.id,
                              let editorSessionLease else { return }
                        invalidateNotebookPDFExport()
                        appModel.notebookAudio?.enqueueReplayElementsSnapshot(
                            elements,
                            notebookID: notebook.id,
                            pageID: page.id
                        )
                        appModel.stageCanvasElements(
                            elements,
                            notebookID: notebook.id,
                            pageID: page.id,
                            editorSession: editorSessionLease
                        )
                    }
                )
            }
            .frame(width: fittedFrame.width, height: fittedFrame.height)
            .position(x: fittedFrame.midX, y: fittedFrame.midY)
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityIdentifier("canvas.elements.workspace")
    }

    private var structuredLoadFailure: some View {
        ContentUnavailableView {
            Label("Couldn’t load page content", systemImage: "exclamationmark.triangle")
        } description: {
            Text("The saved content could not be opened. Your existing data was not replaced.")
        } actions: {
            Button("Try again") {
                guard !replayModel.isMutationLocked else { return }
                Task { await loadSelectedPage() }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func editorToolbar(notebook: EditorNotebook, page: EditorPage) -> some View {
        ScrollView(
            .horizontal,
            showsIndicators: horizontalSizeClass == .compact
        ) {
            HStack(spacing: 8) {
                if let session = academicSession {
                    if session.status == .active
                        || session.status == .needsReview
                        || session.status == .reviewed {
                        Button {
                            prepareAcademicCandidateReview()
                        } label: {
                            Label {
                                HStack(spacing: 4) {
                                    Text("Candidates")
                                    Text(verbatim:
                                        academicSessionCaptures.count(where: {
                                            $0.kind.isAssignmentOrExamCandidate
                                        }).formatted()
                                    )
                                }
                            } icon: {
                                Image(systemName: "checklist")
                            }
                        }
                        .buttonStyle(.bordered)
                        .labelStyle(.titleAndIcon)
                        .disabled(!canPrepareCandidateReview)
                        .accessibilityIdentifier("candidate.review.open")
                    }

                    switch session.status {
                    case .active:
                        Button {
                            prepareAcademicSessionEnd()
                        } label: {
                            Label("End class", systemImage: "stop.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .labelStyle(.titleAndIcon)
                        .disabled(!canPrepareSessionEnd)
                        .accessibilityHint(sessionEndDisabledHint)
                        .accessibilityIdentifier("session.end.open")

                    case .needsReview:
                        Button {
                            prepareAcademicSessionWrapUp()
                        } label: {
                            Label("Review class", systemImage: "checklist")
                        }
                        .buttonStyle(.borderedProminent)
                        .labelStyle(.titleAndIcon)
                        .disabled(!canPrepareSessionWrapUp)
                        .accessibilityIdentifier("session.wrapUp.open")

                    case .reviewed:
                        Label("Reviewed", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                            .accessibilityIdentifier("session.reviewed")

                    case .planned, .cancelled:
                        EmptyView()
                    }

                    Divider().frame(height: 26)
                }

                if horizontalSizeClass != .compact {
                    Button {
                        togglePageSidebar()
                    } label: {
                        Label("Pages", systemImage: "sidebar.left")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(
                        editorSidebarMode == .pages
                            ? "Hide page thumbnails"
                            : "Show page thumbnails"
                    )
                    .accessibilityAddTraits(
                        editorSidebarMode == .pages ? .isSelected : []
                    )
                    .accessibilityIdentifier("editor.pages.toggle")
                }

                Button {
                    synchronizeOutlineDraft(pageID: page.id)
                    showsPageNavigator = true
                } label: {
                    Label("Navigator", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("pageNavigator.open")

                Button {
                    updateSelectedPageBookmark(!page.isBookmarked)
                } label: {
                    Label {
                        Text(
                            page.isBookmarked
                                ? String(localized: "Remove page bookmark")
                                : String(localized: "Bookmark page")
                        )
                    } icon: {
                        Image(
                            systemName: page.isBookmarked
                                ? "bookmark.fill"
                                : "bookmark"
                        )
                    }
                }
                .buttonStyle(
                    EditorToolButtonStyle(isSelected: page.isBookmarked)
                )
                .disabled(
                    replayModel.isMutationLocked
                        || activeStructuralMutationCount > 0
                        || structuralMutationTask != nil
                        || isPageNavigationMetadataMutationInFlight
                        || singlePageExportTask != nil
                        || notebookPDFExportTask != nil
                )
                .accessibilityAddTraits(page.isBookmarked ? .isSelected : [])
                .accessibilityIdentifier("pageNavigator.bookmark.toggle")

                if replayModel.isMutationLocked {
                    replayToolbarContent
                } else {
                Button {
                    toggleDocumentSearch()
                } label: {
                    Label("Search this note", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("f", modifiers: .command)
                .disabled(
                    activeStructuralMutationCount > 0
                        || isPageNavigationMetadataMutationInFlight
                )
                .accessibilityAddTraits(
                    isDocumentSearchPresented ? .isSelected : []
                )
                .accessibilityIdentifier("editor.search.open")

                if page.kind != .textDocument && page.kind != .studySet {
                    Divider().frame(height: 26)

                    ForEach(DrawingTool.allCases) { tool in
                        Button {
                            selectedTool = tool
                        } label: {
                            Label {
                                Text(tool.title)
                            } icon: {
                                Image(systemName: tool.symbolName)
                            }
                        }
                        .buttonStyle(EditorToolButtonStyle(isSelected: selectedTool == tool))
                        .accessibilityAddTraits(selectedTool == tool ? .isSelected : [])
                    }

                    Menu {
                        ForEach(InkColor.allCases) { color in
                            Button {
                                inkColor = color
                            } label: {
                                Label {
                                    Text(color.localizedTitle)
                                } icon: {
                                    Image(systemName: inkColor == color ? "checkmark.circle.fill" : "circle.fill")
                                }
                            }
                        }
                    } label: {
                        Circle()
                            .fill(inkColor.color)
                            .frame(width: 22, height: 22)
                            .padding(5)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Ink color")

                    Menu {
                        Picker("Line width", selection: $lineWidth) {
                            Text("Thin").tag(CGFloat(2))
                            Text("Medium").tag(CGFloat(4))
                            Text("Thick").tag(CGFloat(8))
                        }
                    } label: {
                        Label("Width", systemImage: "lineweight")
                    }
                    .buttonStyle(.bordered)

                    Divider().frame(height: 26)

                    Button {
                        guard loadedDrawingPageID == page.id else { return }
                        isEditingCanvasElements.toggle()
                        if isEditingCanvasElements {
                            renderElementModeInkPreview(for: page)
                        }
                    } label: {
                        Label("Edit elements", systemImage: "square.on.square")
                    }
                    .buttonStyle(EditorToolButtonStyle(isSelected: isEditingCanvasElements))
                    .disabled(
                        loadedDrawingPageID != page.id
                            || loadedCanvasElementPageID != page.id
                    )
                    .accessibilityIdentifier("canvas.elements.mode")
                    .accessibilityValue(isEditingCanvasElements ? "On" : "Off")

                    Menu {
                        ForEach(CanvasElementKind.directKinds) { kind in
                            Button {
                                addCanvasElement(kind, to: page, notebookID: notebook.id)
                            } label: {
                                Label {
                                    Text(kind.title)
                                } icon: {
                                    Image(systemName: kind.symbolName)
                                }
                            }
                            .accessibilityIdentifier("canvas.elements.add.\(kind.rawValue)")
                        }

                        Menu {
                            if availableCanvasAssets.isEmpty {
                                Text("No image assets available")
                            } else {
                                ForEach(Array(availableCanvasAssets.enumerated()), id: \.element.id) { index, asset in
                                    Button(canvasAssetTitle(asset, fallbackIndex: index + 1)) {
                                        addCanvasElement(
                                            .image,
                                            to: page,
                                            notebookID: notebook.id,
                                            assetID: asset.id
                                        )
                                    }
                                    .accessibilityIdentifier("canvas.elements.add.image.\(asset.id.rawValue)")
                                }
                            }
                        } label: {
                            Label("Image", systemImage: "photo")
                        }
                        .disabled(availableCanvasAssets.isEmpty)

                        Menu {
                            if availableCanvasAssets.isEmpty {
                                Text("No image assets available")
                            } else {
                                ForEach(Array(availableCanvasAssets.enumerated()), id: \.element.id) { index, asset in
                                    Button(canvasAssetTitle(asset, fallbackIndex: index + 1)) {
                                        addCanvasElement(
                                            .sticker,
                                            to: page,
                                            notebookID: notebook.id,
                                            assetID: asset.id
                                        )
                                    }
                                    .accessibilityIdentifier("canvas.elements.add.sticker.\(asset.id.rawValue)")
                                }
                            }
                        } label: {
                            Label("Sticker", systemImage: "star.square")
                        }
                        .disabled(availableCanvasAssets.isEmpty)

                        Button {
                            newLinkTitle = ""
                            newLinkDestination = "https://"
                            addLinkTargetPageID = page.id
                            addLinkTargetLoadID = selectedPageLoadID
                            showsAddLinkAlert = true
                        } label: {
                            Label("Link", systemImage: "link")
                        }
                        .accessibilityIdentifier("canvas.elements.add.link")
                    } label: {
                        Label("Add element", systemImage: "plus.square.on.square")
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        loadedDrawingPageID != page.id
                            || loadedCanvasElementPageID != page.id
                    )
                    .accessibilityIdentifier("canvas.elements.add-menu")

                    Divider().frame(height: 26)

                    Button {
                        guard loadedDrawingPageID == page.id else { return }
                        canvasCommand = CanvasCommandRequest(command: .undo)
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(loadedDrawingPageID != page.id)

                    Button {
                        guard loadedDrawingPageID == page.id else { return }
                        canvasCommand = CanvasCommandRequest(command: .redo)
                    } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .buttonStyle(.bordered)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(loadedDrawingPageID != page.id)
                }

                Button {
                    performStructuralMutation { editorSession in
                        await addPage(to: notebook, editorSession: editorSession)
                    }
                } label: {
                    Label("Add page", systemImage: "doc.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(
                    activeStructuralMutationCount > 0
                        || isPageNavigationMetadataMutationInFlight
                        || isAudioStructureMutationLocked
                )

                if page.kind != .textDocument && page.kind != .studySet {
                    Button {
                        showsPageTools = true
                    } label: {
                        Label("Page tools", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.bordered)
                    .disabled(loadedDrawingPageID != page.id)

                    Button {
                        showsSystemToolPicker.toggle()
                    } label: {
                        Label("PencilKit tools", systemImage: "pencil.tip.crop.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(loadedDrawingPageID != page.id)

                    Button {
                        toggleFingerDrawing()
                    } label: {
                        Label(
                            "Finger and compatible stylus input",
                            systemImage: effectiveFingerDrawingEnabled
                                ? "hand.draw.fill"
                                : "hand.draw"
                        )
                    }
                    .buttonStyle(EditorToolButtonStyle(
                        isSelected: effectiveFingerDrawingEnabled
                    ))
                    .accessibilityValue(effectiveFingerDrawingEnabled ? "On" : "Off")
                }

                Button {
                    startSinglePageShare()
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(
                    !isPageReadyForExport(page)
                        || singlePageExportTask != nil
                        || notebookPDFExportTask != nil
                        || isPageNavigationMetadataMutationInFlight
                )
                .accessibilityIdentifier("editor.share")

                if supportsNotebookPDFExport(notebook) {
                    if let progress = notebookPDFExportProgress {
                        ProgressView(
                            value: Double(progress.completedUnits),
                            total: Double(max(progress.totalUnits, 1))
                        )
                        .frame(width: 72)
                        .accessibilityLabel("Exporting notebook PDF")
                        .accessibilityValue(progress.accessibilityValue)
                        .accessibilityIdentifier("editor.exportNotebookPDF.progress")

                        Button {
                            cancelNotebookPDFExport()
                        } label: {
                            Label {
                                Text(
                                    notebookPDFExportIsCancelling
                                        ? String(localized: "Cancelling notebook PDF export")
                                        : String(localized: "Cancel notebook PDF export")
                                )
                            } icon: {
                                Image(systemName: notebookPDFExportIsCancelling
                                      ? "clock"
                                      : "xmark.circle")
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(notebookPDFExportIsCancelling)
                        .accessibilityIdentifier("editor.exportNotebookPDF.cancel")
                    } else {
                        Button {
                            startNotebookPDFExport()
                        } label: {
                            Label("Export notebook PDF", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            !isPageReadyForExport(page)
                                || isPageNavigationMetadataMutationInFlight
                        )
                        .accessibilityHint("Shares every page as one PDF in notebook order")
                        .accessibilityIdentifier("editor.exportNotebookPDF")
                    }
                }

                if let audioModel = appModel.notebookAudio {
                    NotebookAudioToolbarButton(model: audioModel) {
                        showsAudioPanel = true
                    }
                } else {
                    Button { } label: {
                        Label("Audio", systemImage: "waveform")
                    }
                    .buttonStyle(.bordered)
                    .disabled(true)
                    .accessibilityValue("Audio unavailable")
                    .accessibilityIdentifier("notebook.audio.open")
                }

                if page.kind != .textDocument && page.kind != .studySet {
                    saveIndicator
                }
                if let status = replayModel.status {
                    replayStatusLabel(status)
                }
                }
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var replayToolbarContent: some View {
        Divider().frame(height: 26)
        Label("Note Replay", systemImage: "waveform.path.ecg")
            .font(.headline)
            .labelStyle(.titleAndIcon)
        NotebookEditorReplayControls(model: replayModel) {
            Task { await stopNoteReplay() }
        }
    }

    private func replayStatusLabel(
        _ status: NotebookEditorReplayStatus
    ) -> some View {
        Label {
            Text(status.localizedMessage)
                .lineLimit(2)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(.orange)
        .labelStyle(.titleAndIcon)
        .accessibilityIdentifier("noteReplay.status")
    }

    private func documentSearchNavigator(
        notebook: EditorNotebook
    ) -> some View {
        NotebookDocumentSearchView(
            model: documentSearchModel,
            notebookID: notebook.id,
            orderedPageIDs: notebook.pages.map(\.id),
            currentPageID: selectedPageID,
            focusRequestID: documentSearchFocusRequestID,
            canNavigate: canNavigateDocumentSearch,
            onSelect: handleDocumentSearchSelection,
            onClose: {
                closeDocumentSearch(restoringPages: true)
            }
        )
    }

    private func thumbnailSidebar(notebook: EditorNotebook) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(Array(notebook.pages.enumerated()), id: \.element.id) { index, page in
                        PageThumbnail(
                            notebookID: notebook.id,
                            page: page,
                            pageNumber: index + 1,
                            isSelected: page.id == selectedPageID,
                            liveDrawingData: !replayModel.isMutationLocked
                                && loadedDrawingPageID == page.id
                                ? drawingData
                                : nil,
                            allowsAuthoritativeInk: !replayModel.isMutationLocked
                        ) {
                            Task { await handleThumbnailTap(page.id) }
                        }
                        .id(page.id)
                        .disabled(
                            activeStructuralMutationCount > 0
                                || isPageNavigationMetadataMutationInFlight
                                || replayModel.thumbnailAction == .disabled
                                || (replayModel.isMutationLocked
                                    && !NotebookEditorReplayInteractionPolicy
                                        .supportsReplay(page.kind))
                        )
                        .contextMenu {
                            if !replayModel.isMutationLocked,
                               !isAudioStructureMutationLocked,
                               !isPageNavigationMetadataMutationInFlight {
                            Button {
                                performStructuralMutation { editorSession in
                                    await duplicatePage(
                                        page,
                                        in: notebook,
                                        editorSession: editorSession
                                    )
                                }
                            } label: {
                                Label("Duplicate page", systemImage: "plus.square.on.square")
                            }
                            .disabled(activeStructuralMutationCount > 0)
                            Button {
                                performStructuralMutation { editorSession in
                                    await movePage(
                                        page,
                                        in: notebook,
                                        offset: -1,
                                        editorSession: editorSession
                                    )
                                }
                            } label: {
                                Label("Move page up", systemImage: "arrow.up")
                            }
                            .disabled(index == 0 || activeStructuralMutationCount > 0)
                            Button {
                                performStructuralMutation { editorSession in
                                    await movePage(
                                        page,
                                        in: notebook,
                                        offset: 1,
                                        editorSession: editorSession
                                    )
                                }
                            } label: {
                                Label("Move page down", systemImage: "arrow.down")
                            }
                            .disabled(
                                index == notebook.pages.count - 1
                                    || activeStructuralMutationCount > 0
                            )
                            Divider()
                            Button(role: .destructive) {
                                performStructuralMutation { editorSession in
                                    await deletePage(
                                        page,
                                        from: notebook,
                                        editorSession: editorSession
                                    )
                                }
                            } label: {
                                Label("Delete page", systemImage: "trash")
                            }
                            .disabled(
                                notebook.pages.count <= 1
                                    || activeStructuralMutationCount > 0
                            )
                            }
                        }
                    }
                }
                .padding(12)
            }
            .onChange(of: selectedPageID) { _, selectedPageID in
                guard let selectedPageID else { return }
                withAnimation { proxy.scrollTo(selectedPageID, anchor: .center) }
            }
        }
        .frame(width: 112)
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityLabel("Page thumbnails")
    }

    @ViewBuilder
    private var saveIndicator: some View {
        let state = if let notebook, let selectedPageID {
            combinedCanvasSaveState(notebookID: notebook.id, pageID: selectedPageID)
        } else {
            InkSaveState.idle
        }
        switch state {
        case .idle:
            EmptyView()
        case .saving:
            Label("Saving…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed:
            Button {
                guard !replayModel.isMutationLocked else { return }
                Task { _ = await flushPendingPage() }
            } label: {
                Label("Retry save", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .accessibilityIdentifier("canvas.elements.save.retry")
        }
    }

    private func loadNotebook() async {
        guard let loaded = await appModel.notebook(id: notebookSummary.id) else { return }
        notebook = loaded
        selectedPageID = initialPageID.flatMap { target in
            loaded.pages.contains(where: { $0.id == target }) ? target : nil
        } ?? loaded.pages.first?.id
    }

    private func loadSelectedPage() async {
        guard let notebook, let page = selectedPage else { return }
        let pageID = page.id
        let loadID = UUID()
        selectedPageLoadID = loadID
        if replayModel.isMutationLocked {
            replayAuthoritativeDrawingPageID = nil
            replayAuthoritativeDrawing = nil
        }

        switch page.kind {
        case .textDocument, .studySet:
            isEditingCanvasElements = false
            loadedCanvasElementPageID = nil
            failedCanvasElementPageID = nil
            canvasElements = []
            availableCanvasAssets = []
            canvasAssetURLs = [:]
            canvasAssetImages = [:]
            canvasAssetImageCosts = [:]
            canvasAssetImageCacheOrder = []
            loadingCanvasAssetImages = []
            suppressedCanvasAssetImageKeys = []
            elementModeInkPreview = nil
            loadedDrawingPageID = nil
            failedDrawingPageID = nil
            drawingData = nil
            loadedStructuredPageID = nil
            failedStructuredPageID = nil
            if page.kind == .textDocument {
                textDocument = TextDocument()
            } else {
                studySet = StudySet()
            }

            guard let content = await appModel.loadPageContent(
                notebookID: notebook.id,
                pageID: pageID
            ) else {
                guard selectedPageID == pageID, selectedPageLoadID == loadID else { return }
                failedStructuredPageID = pageID
                return
            }
            guard selectedPageID == pageID, selectedPageLoadID == loadID else { return }

            switch (page.kind, content) {
            case (.textDocument, .textDocument(let document)):
                textDocument = document
            case (.studySet, .studySet(let loadedStudySet)):
                studySet = StudySetSchedulerAdapter.normalized(loadedStudySet)
            default:
                failedStructuredPageID = pageID
                return
            }
            loadedStructuredPageID = pageID
        case .notebook, .whiteboard, .importedDocument:
            isEditingCanvasElements = false
            loadedStructuredPageID = nil
            failedStructuredPageID = nil
            if loadedCanvasElementPageID != pageID {
                loadedCanvasElementPageID = nil
                failedCanvasElementPageID = nil
                canvasElements = []
                availableCanvasAssets = []
                canvasAssetURLs = [:]
            }
            if loadedDrawingPageID != pageID {
                loadedDrawingPageID = nil
                failedDrawingPageID = nil
                drawingData = nil
            }
            async let ink = appModel.loadInkForEditing(
                notebookID: notebook.id,
                page: page
            )
            async let background = appModel.resolveBackground(notebookID: notebook.id, page: page)
            async let elements = appModel.loadCanvasElements(
                notebookID: notebook.id,
                pageID: page.id
            )
            async let assets = appModel.availableCanvasImageAssets(notebookID: notebook.id)
            let loadedInk = await ink
            let loadedBackground = await background
            let loadedElements = await elements
            let loadedAssets = await assets
            let loadedAssetURLs = await appModel.canvasAssetURLs(
                notebookID: notebook.id,
                assetIDs: loadedAssets.map(\.id) + CanvasElementFactory.referencedAssetIDs(
                    in: loadedElements ?? []
                )
            )
            guard selectedPageID == pageID, selectedPageLoadID == loadID else { return }
            switch loadedInk {
            case .loaded(let data):
                if let data, (try? PKDrawing(data: data)) == nil {
                    // A successful file read is not enough: never present an
                    // undecodable payload as an editable blank canvas.
                    drawingData = nil
                    loadedDrawingPageID = nil
                    failedDrawingPageID = pageID
                    showsSystemToolPicker = false
                } else {
                    drawingData = data
                    loadedDrawingPageID = pageID
                    failedDrawingPageID = nil
                    if replayModel.isMutationLocked {
                        cacheReplayAuthoritativeDrawing(data, pageID: pageID)
                    }
                }
            case .failed:
                drawingData = nil
                loadedDrawingPageID = nil
                failedDrawingPageID = pageID
                showsSystemToolPicker = false
            }
            drawingRevision = UUID()
            resolvedBackground = loadedBackground
            availableCanvasAssets = loadedAssets.filter { loadedAssetURLs[$0.id] != nil }
            canvasAssetURLs = loadedAssetURLs
            canvasAssetImages = [:]
            canvasAssetImageCosts = [:]
            canvasAssetImageCacheOrder = []
            loadingCanvasAssetImages = []
            suppressedCanvasAssetImageKeys = []
            if let loadedElements {
                canvasElements = loadedElements
                loadedCanvasElementPageID = pageID
                failedCanvasElementPageID = nil
            } else {
                canvasElements = []
                loadedCanvasElementPageID = nil
                failedCanvasElementPageID = pageID
            }
            renderElementModeInkPreview(for: page)
            if loadedDrawingPageID == pageID,
               loadedCanvasElementPageID == pageID {
                appModel.notebookAudio?.enqueueReplayPageSnapshot(
                    notebookID: notebook.id,
                    snapshot: NotebookAudioReplayPageSnapshot(
                        pageID: PageID(pageID),
                        inkData: drawingData,
                        elements: canvasElements
                    )
                )
            } else {
                appModel.notebookAudio?.reportReplayCaptureUnavailable(
                    notebookID: notebook.id,
                    pageID: pageID
                )
            }
        }
    }

    private func saveDrawing(_ data: Data, notebookID: UUID, page: EditorPage) {
        guard !replayModel.isMutationLocked,
              selectedPageID == page.id,
              loadedDrawingPageID == page.id,
              let editorSessionLease else { return }
        invalidateNotebookPDFExport()
        drawingData = data
        if isEditingCanvasElements {
            renderElementModeInkPreview(for: page)
        }
        appModel.stageInk(
            data,
            notebookID: notebookID,
            page: page,
            editorSession: editorSessionLease
        )
    }

    private func prepareAudioRecording() async
        -> NotebookAudioRecordingPreparation {
        guard !replayModel.isMutationLocked,
              let notebook,
              let page = selectedPage,
              selectedPageID == page.id else {
            return .unavailable
        }
        let notebookID = notebook.id
        let pageID = page.id
        guard await appModel.flushPendingWrites(notebookID: notebookID),
              self.notebook?.id == notebookID,
              selectedPageID == pageID,
              selectedPage?.id == pageID else {
            return .unavailable
        }
        guard NotebookEditorReplayInteractionPolicy.supportsReplay(page.kind) else {
            return .ready(replaySnapshot: nil)
        }
        guard loadedDrawingPageID == pageID,
              loadedCanvasElementPageID == pageID else {
            appModel.notebookAudio?.reportReplayCaptureUnavailable(
                notebookID: notebookID,
                pageID: pageID
            )
            return .unavailable
        }
        return .ready(replaySnapshot: NotebookAudioReplayPageSnapshot(
            pageID: PageID(pageID),
            inkData: drawingData,
            elements: canvasElements
        ))
    }

    private func flushBeforeStoppingAudioRecording() async -> Bool {
        guard let notebookID = notebook?.id else { return false }
        return await appModel.flushPendingWrites(notebookID: notebookID)
    }

    private func addCanvasElement(
        _ kind: CanvasElementKind,
        to page: EditorPage,
        notebookID: UUID,
        assetID: AssetID? = nil
    ) {
        guard !replayModel.isMutationLocked,
              selectedPageID == page.id,
              loadedDrawingPageID == page.id,
              loadedCanvasElementPageID == page.id,
              let editorSessionLease,
              let element = CanvasElementFactory.make(
                kind,
                assetID: assetID,
                ordinal: canvasElements.count,
                pageBounds: page.canvasBounds,
                now: .now
              ) else { return }
        let updated = CanvasElementEditing.inserting(
            element,
            in: canvasElements,
            within: page.canvasBounds,
            now: .now
        )
        guard updated != canvasElements else { return }
        invalidateNotebookPDFExport()
        canvasElements = updated
        isEditingCanvasElements = true
        renderElementModeInkPreview(for: page)
        appModel.notebookAudio?.enqueueReplayElementsSnapshot(
            updated,
            notebookID: notebookID,
            pageID: page.id
        )
        appModel.stageCanvasElements(
            updated,
            notebookID: notebookID,
            pageID: page.id,
            editorSession: editorSessionLease
        )
    }

    private func addValidatedLink() {
        guard !replayModel.isMutationLocked else { return }
        let targetPageID = addLinkTargetPageID
        let targetLoadID = addLinkTargetLoadID
        addLinkTargetPageID = nil
        addLinkTargetLoadID = nil
        guard let notebook,
              let page = selectedPage,
              let editorSessionLease,
              let destination = CanvasElementFactory.validatedLinkURL(newLinkDestination),
              selectedPageID == page.id,
              loadedDrawingPageID == page.id,
              loadedCanvasElementPageID == page.id,
              targetPageID == page.id,
              targetLoadID == selectedPageLoadID else { return }
        guard let element = CanvasElementFactory.makeLink(
            title: newLinkTitle,
            destination: destination,
            ordinal: canvasElements.count,
            pageBounds: page.canvasBounds,
            now: .now
        ) else { return }
        let updated = CanvasElementEditing.inserting(
            element,
            in: canvasElements,
            within: page.canvasBounds,
            now: .now
        )
        guard updated != canvasElements else { return }
        invalidateNotebookPDFExport()
        canvasElements = updated
        isEditingCanvasElements = true
        renderElementModeInkPreview(for: page)
        appModel.notebookAudio?.enqueueReplayElementsSnapshot(
            updated,
            notebookID: notebook.id,
            pageID: page.id
        )
        appModel.stageCanvasElements(
            updated,
            notebookID: notebook.id,
            pageID: page.id,
            editorSession: editorSessionLease
        )
    }

    private func canvasAssetTitle(_ asset: AssetDescriptor, fallbackIndex: Int) -> String {
        let filename = asset.originalFilename?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !filename.isEmpty { return String(filename.prefix(80)) }
        return String.localizedStringWithFormat(
            String(localized: "Image asset %lld"),
            Int64(fallbackIndex)
        )
    }

    private func resolveCanvasAssetImage(
        assetID: AssetID,
        request: CanvasElementImageRequest,
        pageID: UUID
    ) -> UIImage? {
        let key = CanvasElementAssetCacheKey(assetID: assetID, request: request)
        if let image = canvasAssetImages[key], request.accepts(image) {
            return image
        }
        guard canvasAssetURLs[assetID] != nil,
              !suppressedCanvasAssetImageKeys.contains(key) else { return nil }
        Task { @MainActor in
            guard selectedPageID == pageID,
                  loadedCanvasElementPageID == pageID,
                  canvasAssetImages[key] == nil,
                  !loadingCanvasAssetImages.contains(key),
                  let url = canvasAssetURLs[assetID] else { return }
            loadingCanvasAssetImages.insert(key)
            let image = PageAssetImageLoader.thumbnail(
                at: url,
                maximumPixelDimension: CGFloat(key.maximumPixelDimension)
            )
            loadingCanvasAssetImages.remove(key)
            guard selectedPageID == pageID,
                  loadedCanvasElementPageID == pageID,
                  let image,
                  request.accepts(image) else { return }
            insertCanvasAssetImage(image, for: key)
        }
        return nil
    }

    private func insertCanvasAssetImage(
        _ image: UIImage,
        for key: CanvasElementAssetCacheKey
    ) {
        let cost = CanvasElementAssetCachePolicy.estimatedByteCount(of: image)
        guard cost > 0, cost <= CanvasElementAssetCachePolicy.maximumTotalByteCount else { return }

        if canvasAssetImageCosts[key] != nil {
            canvasAssetImages.removeValue(forKey: key)
            canvasAssetImageCosts.removeValue(forKey: key)
            canvasAssetImageCacheOrder.removeAll { $0 == key }
        }
        while canvasAssetImageCosts.values.reduce(0, +) + cost
                > CanvasElementAssetCachePolicy.maximumTotalByteCount
                || canvasAssetImageCacheOrder.count >= CanvasElementAssetCachePolicy.maximumEntryCount {
            guard let oldest = canvasAssetImageCacheOrder.first else { break }
            canvasAssetImageCacheOrder.removeFirst()
            canvasAssetImages.removeValue(forKey: oldest)
            canvasAssetImageCosts.removeValue(forKey: oldest)
            suppressedCanvasAssetImageKeys.insert(oldest)
        }
        canvasAssetImages[key] = image
        canvasAssetImageCosts[key] = cost
        canvasAssetImageCacheOrder.append(key)
    }

    private func renderElementModeInkPreview(for page: EditorPage) {
        guard selectedPageID == page.id,
              let drawingData,
              let drawing = try? PKDrawing(data: drawingData),
              !drawing.strokes.isEmpty else {
            elementModeInkPreview = nil
            return
        }
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(page.width),
            height: CGFloat(page.height)
        )
        let longestDimension = max(bounds.width, bounds.height)
        guard longestDimension.isFinite, longestDimension > 0 else {
            elementModeInkPreview = nil
            return
        }
        let scale = min(2, 2_048 / longestDimension)
        guard scale.isFinite, scale > 0 else {
            elementModeInkPreview = nil
            return
        }
        elementModeInkPreview = drawing.image(from: bounds, scale: scale)
    }

    private func combinedCanvasSaveState(notebookID: UUID, pageID: UUID) -> InkSaveState {
        let states = [
            appModel.inkSaveState(notebookID: notebookID, pageID: pageID),
            appModel.canvasElementSaveState(notebookID: notebookID, pageID: pageID),
        ]
        if states.contains(.failed) { return .failed }
        if states.contains(.saving) { return .saving }
        if states.contains(.saved) { return .saved }
        return .idle
    }

    private func addPage(
        to notebook: EditorNotebook,
        editorSession: EditorSessionLease
    ) async {
        guard !replayModel.isMutationLocked else { return }
        invalidateNotebookPDFExport()
        guard await flushPendingPage() else { return }
        guard !replayModel.isMutationLocked,
              self.notebook?.id == notebook.id else { return }
        guard let updated = await appModel.addPage(
            to: notebook,
            editorSession: editorSession
        ) else { return }
        guard !replayModel.isMutationLocked,
              self.notebook?.id == notebook.id else { return }
        self.notebook = updated
        selectedPageID = updated.pages.last?.id
    }

    private func duplicatePage(
        _ page: EditorPage,
        in notebook: EditorNotebook,
        editorSession: EditorSessionLease
    ) async {
        guard !replayModel.isMutationLocked else { return }
        invalidateNotebookPDFExport()
        if selectedPageID == page.id, !(await flushPendingPage()) { return }
        guard !replayModel.isMutationLocked,
              self.notebook?.id == notebook.id else { return }
        guard let (updated, newPageID) = await appModel.duplicatePage(
            in: notebook,
            page: page,
            editorSession: editorSession
        ) else { return }
        guard !replayModel.isMutationLocked,
              self.notebook?.id == notebook.id else { return }
        self.notebook = updated
        selectedPageID = newPageID
    }

    private func movePage(
        _ page: EditorPage,
        in notebook: EditorNotebook,
        offset: Int,
        editorSession: EditorSessionLease
    ) async {
        guard !replayModel.isMutationLocked else { return }
        invalidateNotebookPDFExport()
        guard self.notebook?.id == notebook.id else { return }
        guard let updated = await appModel.movePage(
            in: notebook,
            pageID: page.id,
            offset: offset,
            editorSession: editorSession
        ) else { return }
        guard !replayModel.isMutationLocked,
              self.notebook?.id == notebook.id else { return }
        self.notebook = updated
        selectedPageID = page.id
    }

    private func deletePage(
        _ page: EditorPage,
        from notebook: EditorNotebook,
        editorSession: EditorSessionLease
    ) async {
        guard !replayModel.isMutationLocked else { return }
        invalidateNotebookPDFExport()
        if selectedPageID == page.id, !(await flushPendingPage()) { return }
        guard !replayModel.isMutationLocked,
              self.notebook?.id == notebook.id else { return }
        guard let index = notebook.pages.firstIndex(where: { $0.id == page.id }),
              let updated = await appModel.deletePage(
                from: notebook,
                pageID: page.id,
                editorSession: editorSession
              ) else { return }
        guard !replayModel.isMutationLocked,
              self.notebook?.id == notebook.id else { return }
        self.notebook = updated
        if selectedPageID == page.id {
            selectedPageID = updated.pages[min(index, updated.pages.count - 1)].id
        }
    }

    private func startNotebookPDFExport() {
        guard !replayModel.isMutationLocked,
              singlePageExportTask == nil,
              notebookPDFExportTask == nil,
              !isPageNavigationMetadataMutationInFlight,
              let notebook,
              supportsNotebookPDFExport(notebook),
              let expectedRevision = currentNotebookPDFRevision() else { return }
        let exportID = UUID()
        notebookPDFExportID = exportID
        notebookPDFExportProgress = NotebookPDFExportProgress(
            completedUnits: 0,
            totalUnits: notebook.pages.count * 2 + 1
        )
        notebookPDFExportIsCancelling = false
        notebookPDFExportTask = Task { @MainActor in
            await prepareNotebookPDFShare(
                notebook: notebook,
                expectedRevision: expectedRevision,
                exportID: exportID
            )
        }
    }

    @MainActor
    private func prepareNotebookPDFShare(
        notebook: EditorNotebook,
        expectedRevision: NotebookPDFEditorRevision,
        exportID: UUID
    ) async {
        var createdURL: URL?
        defer {
            if notebookPDFExportID == exportID {
                notebookPDFExportTask = nil
                notebookPDFExportProgress = nil
                notebookPDFExportIsCancelling = false
            }
        }

        let dependencies = NotebookPDFSnapshotDependencies(
            flushAllPendingWrites: {
                await appModel.flushAllPendingWrites()
            },
            beginExportSession: { notebookID in
                try await appModel.beginNotebookExport(id: notebookID)
            },
            validateExportSession: { session in
                try await appModel.validateNotebookExportSession(session)
            },
            endExportSession: { session in
                await appModel.endNotebookExport(session)
            },
            loadInk: { session, page in
                try await appModel.loadInkForExport(session: session, page: page)
            },
            loadCanvasElements: { session, pageID in
                try await appModel.loadCanvasElementsForExport(
                    session: session,
                    pageID: pageID
                )
            },
            resolveBackground: { session, page in
                try await appModel.resolveBackgroundForExport(
                    session: session,
                    page: page
                )
            },
            loadCanvasAssets: { session, assetIDs in
                try await appModel.canvasAssetsForExport(
                    session: session,
                    assetIDs: assetIDs
                )
            }
        )

        do {
            let writer = try NotebookPDFExporter.makeArtifactWriter(
                title: expectedRevision.notebookTitle,
                notebookID: notebook.id,
                expectedPageCount: notebook.pages.count
            )
            defer { writer.abort() }
            let persistedRevision = try await NotebookPDFSnapshotCollector.collectEach(
                notebook: notebook,
                expectedRevision: expectedRevision,
                currentRevision: { currentNotebookPDFRevision() },
                dependencies: dependencies,
                progress: { progress in
                    guard notebookPDFExportID == exportID else { return }
                    notebookPDFExportProgress = NotebookPDFExportProgress(
                        completedUnits: progress.completedUnits,
                        totalUnits: progress.totalUnits * 2 + 1
                    )
                },
                consume: { snapshot, index, pageCount in
                    try writer.append(snapshot)
                    guard notebookPDFExportID == exportID else {
                        throw CancellationError()
                    }
                    notebookPDFExportProgress = NotebookPDFExportProgress(
                        completedUnits: index + 1,
                        totalUnits: pageCount * 2 + 1
                    )
                }
            )
            try Task.checkCancellation()
            guard notebookPDFExportID == exportID,
                  currentNotebookPDFRevision() == expectedRevision else {
                throw NotebookPDFSnapshotCollectionError.staleEditorState
            }

            let pageCount = notebook.pages.count
            let url = try await writer.finish(
                progress: { mergedPages in
                    guard notebookPDFExportID == exportID else { return }
                    notebookPDFExportProgress = NotebookPDFExportProgress(
                        completedUnits: pageCount + mergedPages,
                        totalUnits: pageCount * 2 + 1
                    )
                }
            )
            createdURL = url
            try Task.checkCancellation()
            guard notebookPDFExportID == exportID,
                  currentNotebookPDFRevision() == expectedRevision else {
                throw NotebookPDFSnapshotCollectionError.staleEditorState
            }
            let finalPersistedNotebook: EditorNotebook?
            do {
                finalPersistedNotebook = try await appModel.notebookForExport(id: notebook.id)
            } catch let error as CancellationError {
                throw error
            } catch {
                throw NotebookPDFSnapshotCollectionError.notebookUnavailable
            }
            try Task.checkCancellation()
            guard let finalPersistedNotebook,
                  persistedRevision.matches(finalPersistedNotebook) else {
                throw NotebookPDFSnapshotCollectionError.staleEditorState
            }
            guard notebookPDFExportID == exportID,
                  currentNotebookPDFRevision() == expectedRevision else {
                throw NotebookPDFSnapshotCollectionError.staleEditorState
            }
            notebookPDFExportProgress = NotebookPDFExportProgress(
                completedUnits: pageCount * 2 + 1,
                totalUnits: pageCount * 2 + 1
            )
            replaceShareURL(with: url)
            createdURL = nil
            showsShareSheet = true
        } catch is CancellationError {
            if let createdURL {
                try? FileManager.default.removeItem(at: createdURL)
            }
        } catch {
            if let createdURL {
                try? FileManager.default.removeItem(at: createdURL)
            }
            guard !replayModel.isMutationLocked else { return }
            appModel.report(error)
        }
    }

    private func invalidateNotebookPDFExport() {
        notebookPDFInteractionGeneration &+= 1
        cancelSinglePageExport()
        cancelNotebookPDFExport()
    }

    private func cancelSinglePageExport() {
        singlePageExportTask?.cancel()
    }

    private func cancelNotebookPDFExport() {
        guard let notebookPDFExportTask else { return }
        notebookPDFExportIsCancelling = true
        notebookPDFExportTask.cancel()
    }

    private func currentNotebookPDFRevision() -> NotebookPDFEditorRevision? {
        guard let notebook else { return nil }
        return NotebookPDFEditorRevision(
            notebookID: notebook.id,
            notebookTitle: notebook.title,
            orderedPageIDs: notebook.pages.map(\.id),
            pageIdentities: notebook.pages.map(NotebookPDFPageIdentity.init),
            selectedPageID: selectedPageID,
            interactionGeneration: notebookPDFInteractionGeneration
        )
    }

    private func supportsNotebookPDFExport(_ notebook: EditorNotebook) -> Bool {
        !notebook.pages.isEmpty && notebook.pages.allSatisfy { page in
            switch page.kind {
            case .notebook, .whiteboard, .importedDocument:
                true
            case .textDocument, .studySet:
                false
            }
        }
    }

    private func replaceShareURL(with url: URL) {
        removeOwnedShareURL()
        shareURL = url
    }

    /// Only Notes-owned regular files directly inside its private temporary export directory are
    /// eligible for cleanup. The share sheet keeps `shareURL` alive until dismissal; arbitrary
    /// Files/iCloud URLs are never removed even if a future share path stores one here.
    private func removeOwnedShareURL() {
        guard !showsShareSheet, let url = shareURL else { return }
        defer { shareURL = nil }
        removeOwnedExportURL(url)
    }

    private func removeOwnedExportURL(_ url: URL) {
        NotesExportTemporaryFile.removeOwned(url)
    }

    private func startSinglePageShare() {
        guard !replayModel.isMutationLocked,
              singlePageExportTask == nil,
              notebookPDFExportTask == nil,
              !isPageNavigationMetadataMutationInFlight,
              let page = selectedPage,
              isPageReadyForExport(page) else { return }
        let exportID = UUID()
        singlePageExportID = exportID
        singlePageExportTask = Task { @MainActor in
            await prepareShare(exportID: exportID)
        }
    }

    @MainActor
    private func prepareShare(exportID: UUID) async {
        var createdURL: URL?
        defer {
            if let createdURL {
                removeOwnedExportURL(createdURL)
            }
            if singlePageExportID == exportID {
                singlePageExportTask = nil
            }
        }
        guard !replayModel.isMutationLocked,
              singlePageExportID == exportID,
              let notebook,
              let page = selectedPage,
              isPageReadyForExport(page) else { return }
        let notebookID = notebook.id
        let pageID = page.id
        let loadID = selectedPageLoadID
        guard await appModel.flushPendingWrites(
            notebookID: notebookID,
            pageID: pageID
        ) else { return }
        do {
            try Task.checkCancellation()
        } catch {
            return
        }
        // Flushing yields the main actor. A fast A → B → A page switch can therefore make
        // the page identifier current again while this task still belongs to A's previous load.
        // Bind the export to the exact load generation and snapshot every input only after the
        // flush completes, so the PDF never combines a stale element/asset map with fresh ink.
        guard selectedPageID == pageID,
              selectedPageLoadID == loadID,
              let currentNotebook = self.notebook,
              currentNotebook.id == notebookID,
              let currentPage = currentNotebook.pages.first(where: { $0.id == pageID }),
              isPageReadyForExport(currentPage) else { return }

        let exportRevision = SinglePagePDFExportRevision(
            pageID: pageID,
            pageLoadID: loadID,
            interactionGeneration: notebookPDFInteractionGeneration
        )
        let title = currentNotebook.title
        do {
            try Task.checkCancellation()
            guard singlePageExportID == exportID else {
                throw CancellationError()
            }
            let nextShareURL: URL
            switch currentPage.kind {
            case .textDocument:
                nextShareURL = try StructuredContentExportRenderer.temporaryMarkdown(
                    title: title,
                    document: textDocument,
                    identifier: currentPage.id
                )
            case .studySet:
                nextShareURL = try StructuredContentExportRenderer.temporaryCSV(
                    title: title,
                    studySet: studySet,
                    identifier: currentPage.id
                )
            case .notebook, .whiteboard, .importedDocument:
                let session = try await appModel.beginNotebookExport(id: notebookID)
                let snapshot: NotebookPDFPageSnapshot
                do {
                    let persistedNotebook = try await appModel
                        .validateNotebookExportSession(session)
                    guard persistedNotebook.pages.contains(where: {
                        NotebookPDFPageIdentity(page: $0)
                            == NotebookPDFPageIdentity(page: currentPage)
                    }) else {
                        throw NotebookPDFSnapshotCollectionError.staleEditorState
                    }
                    snapshot = try await NotebookPDFSnapshotCollector.collectSinglePage(
                        notebookID: notebookID,
                        page: currentPage,
                        expectedRevision: exportRevision,
                        currentRevision: {
                            guard let selectedPageID else { return nil }
                            return SinglePagePDFExportRevision(
                                pageID: selectedPageID,
                                pageLoadID: selectedPageLoadID,
                                interactionGeneration: notebookPDFInteractionGeneration
                            )
                        },
                        dependencies: SinglePagePDFSnapshotDependencies(
                            loadInk: { _, page in
                                try await appModel.loadInkForExport(
                                    session: session,
                                    page: page
                                )
                            },
                            loadCanvasElements: { _, pageID in
                                try await appModel.loadCanvasElementsForExport(
                                    session: session,
                                    pageID: pageID
                                ).elements
                            },
                            resolveBackground: { _, page in
                                try await appModel.resolveBackgroundForExport(
                                    session: session,
                                    page: page
                                )
                            },
                            loadCanvasAssets: { _, assetIDs in
                                try await appModel.canvasAssetsForExport(
                                    session: session,
                                    assetIDs: assetIDs
                                )
                            }
                        )
                    )
                    let finalNotebook = try await appModel
                        .validateNotebookExportSession(session)
                    guard finalNotebook.pages.contains(where: {
                        NotebookPDFPageIdentity(page: $0)
                            == NotebookPDFPageIdentity(page: currentPage)
                    }) else {
                        throw NotebookPDFSnapshotCollectionError.staleEditorState
                    }
                    await appModel.endNotebookExport(session)
                } catch {
                    await appModel.endNotebookExport(session)
                    throw error
                }
                nextShareURL = try NotebookPDFExporter.temporaryPDF(
                    title: title,
                    notebookID: notebookID,
                    pages: [snapshot]
                )
            }
            createdURL = nextShareURL
            try Task.checkCancellation()
            guard singlePageExportID == exportID else {
                throw CancellationError()
            }
            guard let publishURL = SinglePagePDFExportPublication.validatedURL(
                nextShareURL,
                expectedRevision: exportRevision,
                currentRevision: {
                    guard let selectedPageID else { return nil }
                    return SinglePagePDFExportRevision(
                        pageID: selectedPageID,
                        pageLoadID: selectedPageLoadID,
                        interactionGeneration: notebookPDFInteractionGeneration
                    )
                }
            ) else { throw CancellationError() }
            replaceShareURL(with: publishURL)
            createdURL = nil
            showsShareSheet = true
        } catch is CancellationError {
            return
        } catch {
            guard singlePageExportID == exportID else { return }
            guard exportRevision.matches(
                selectedPageID: selectedPageID,
                pageLoadID: selectedPageLoadID,
                interactionGeneration: notebookPDFInteractionGeneration
            ) else { return }
            appModel.report(error)
        }
    }

    private func togglePageSidebar() {
        documentSearchInteractionGeneration = UUID()
        documentSearchModel.cancel()
        showsCompactDocumentSearch = false
        if horizontalSizeClass == .compact {
            synchronizeOutlineDraft(pageID: selectedPageID)
            showsPageNavigator = true
            return
        }
        withAnimation {
            editorSidebarMode = editorSidebarMode == .pages ? nil : .pages
        }
    }

    private func toggleFingerDrawing() {
        if CurrentDevicePresentation.isPhone {
            phoneFingerDrawingEnabled.toggle()
        } else {
            fingerDrawingEnabled.toggle()
        }
    }

    private func toggleDocumentSearch() {
        if isDocumentSearchPresented {
            closeDocumentSearch(restoringPages: true)
            return
        }

        guard canNavigateDocumentSearch, let notebook else { return }
        let generation = UUID()
        let notebookID = notebook.id
        let pageID = selectedPageID
        documentSearchInteractionGeneration = generation

        Task { @MainActor in
            guard await flushPendingPage() else { return }
            guard documentSearchInteractionGeneration == generation,
                  canNavigateDocumentSearch,
                  self.notebook?.id == notebookID,
                  selectedPageID == pageID,
                  let currentNotebook = self.notebook else { return }

            let currentQuery = documentSearchModel.query
            if !currentQuery.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
                documentSearchModel.search(
                    currentQuery,
                    notebookID: currentNotebook.id,
                    orderedPageIDs: currentNotebook.pages.map(\.id)
                )
            }

            documentSearchFocusRequestID = UUID()
            if horizontalSizeClass == .compact {
                showsCompactDocumentSearch = true
            } else {
                withAnimation { editorSidebarMode = .search }
            }
        }
    }

    private func closeDocumentSearch(
        restoringPages: Bool,
        reset: Bool = false
    ) {
        documentSearchInteractionGeneration = UUID()
        if reset {
            documentSearchModel.reset()
        } else {
            documentSearchModel.cancel()
        }
        showsCompactDocumentSearch = false
        guard editorSidebarMode == .search else { return }
        withAnimation {
            editorSidebarMode = restoringPages ? .pages : nil
        }
    }

    private func migrateDocumentSearchPresentation(
        for sizeClass: UserInterfaceSizeClass?
    ) {
        guard isDocumentSearchPresented else { return }
        documentSearchFocusRequestID = UUID()
        if sizeClass == .compact {
            showsCompactDocumentSearch = true
            editorSidebarMode = nil
        } else {
            editorSidebarMode = .search
            showsCompactDocumentSearch = false
        }
    }

    private func handleDocumentSearchSelection(
        _ result: NotebookDocumentSearchModel.PageResult
    ) {
        guard canNavigateDocumentSearch,
              isDocumentSearchPresented,
              documentSearchModel.phase == .results,
              documentSearchModel.results.contains(result) else { return }
        let authority = DocumentSearchSelectionAuthority(
            generation: UUID(),
            query: documentSearchModel.query,
            result: result
        )
        documentSearchInteractionGeneration = authority.generation

        Task { @MainActor in
            guard await selectPage(
                result.pageID,
                documentSearchAuthority: authority
            ) else { return }
            documentSearchModel.select(pageID: result.pageID)
            if showsCompactDocumentSearch {
                showsCompactDocumentSearch = false
            }
        }
    }

    private func requestNoteReplay(sessionID: AudioSessionID) {
        guard canRequestNoteReplay else { return }
        _ = replayModel.reserveStart(sessionID: sessionID)
        closeDocumentSearch(restoringPages: true)

        // Reservation is the write fence. Close every editor surface that can
        // retain a delayed mutation before any asynchronous preparation begins.
        showsPageTools = false
        showsSystemToolPicker = false
        isEditingCanvasElements = false
        showsAddLinkAlert = false
        addLinkTargetPageID = nil
        addLinkTargetLoadID = nil
        canvasCommand = nil
        cacheReplayAuthoritativeDrawing(
            drawingData,
            pageID: loadedDrawingPageID
        )
        invalidateNotebookPDFExport()
        showsAudioPanel = false
    }

    private func startReservedNoteReplay() async {
        guard let reservation = replayModel.startReservation else { return }
        guard let notebook else {
            replayModel.failStart(
                reservation,
                reason: .controllerUnavailable
            )
            return
        }
        let notebookID = notebook.id
        let exportTask = notebookPDFExportTask
        invalidateNotebookPDFExport()
        await exportTask?.value
        guard replayModel.isCurrent(reservation) else { return }

        guard await appModel.flushPendingWrites(notebookID: notebookID) else {
            replayModel.failStart(
                reservation,
                reason: .pendingWritesCouldNotBeFlushed
            )
            return
        }
        guard replayModel.isCurrent(reservation) else { return }
        guard self.notebook?.id == notebookID else {
            replayModel.failStart(
                reservation,
                reason: .controllerUnavailable
            )
            return
        }

        let preferredPageID = NotebookEditorReplayInteractionPolicy
            .preferredStartPageID(
                currentPageID: selectedPageID,
                currentPageKind: selectedPage?.kind
            )
        await replayModel.start(
            reservation,
            notebookID: NotebookID(notebookID),
            currentPageID: preferredPageID
        )
    }

    private func stopNoteReplay() async {
        let restorationPageID = await replayModel.stop()
        replayAuthoritativeDrawingPageID = nil
        replayAuthoritativeDrawing = nil
        await restoreAuthoritativeEditorState(
            preferredPageID: restorationPageID
        )
    }

    private func restoreAuthoritativeEditorState(
        preferredPageID: PageID? = nil
    ) async {
        let restorationGeneration = UUID()
        replayRestorationGeneration = restorationGeneration
        if let preferredPageID,
           notebook?.pages.contains(where: {
               $0.id == preferredPageID.rawValue
           }) == true {
            selectedPageID = preferredPageID.rawValue
        }
        guard !replayModel.isMutationLocked else { return }
        await loadSelectedPage()
        guard replayRestorationGeneration == restorationGeneration else {
            return
        }
    }

    private func handleThumbnailTap(_ pageID: UUID) async {
        switch replayModel.thumbnailAction {
        case .selectEditorPage:
            await selectPage(pageID)
        case .seekReplay:
            guard let page = notebook?.pages.first(where: { $0.id == pageID }),
                  NotebookEditorReplayInteractionPolicy
                    .supportsReplay(page.kind) else { return }
            _ = await replayModel.seekToPage(PageID(pageID))
        case .disabled:
            break
        }
    }

    private func performStructuralMutation(
        _ operation: @escaping @MainActor (EditorSessionLease) async -> Void
    ) {
        guard PageNavigationMutationInterlockPolicy.canBeginStructuralMutation(
            isReplayMutationLocked: replayModel.isMutationLocked,
            isAudioStructureMutationLocked: isAudioStructureMutationLocked,
            activeStructuralMutationCount: activeStructuralMutationCount,
            hasStructuralMutationTask: structuralMutationTask != nil,
            isMetadataMutationInFlight:
                isPageNavigationMetadataMutationInFlight
        ),
              let editorSessionLease else { return }
        closeDocumentSearch(restoringPages: true)
        let mutationID = UUID()
        structuralMutationID = mutationID
        activeStructuralMutationCount += 1
        structuralMutationTask = Task { @MainActor in
            defer {
                if structuralMutationID == mutationID {
                    structuralMutationTask = nil
                    activeStructuralMutationCount = max(
                        activeStructuralMutationCount - 1,
                        0
                    )
                }
            }
            guard !Task.isCancelled else { return }
            await operation(editorSessionLease)
        }
    }

    private func cancelStructuralMutation() {
        guard let structuralMutationTask else { return }
        structuralMutationTask.cancel()
    }

    private func updateSelectedPageBookmark(_ isBookmarked: Bool) {
        guard let page = selectedPage else { return }
        performPageNavigationMetadataMutation(
            page: page,
            update: .bookmark(isBookmarked)
        )
    }

    private func updateSelectedPageOutline(_ outlineTitle: String?) {
        guard let page = selectedPage else { return }
        performPageNavigationMetadataMutation(
            page: page,
            update: .outlineTitle(outlineTitle)
        )
    }

    private func performPageNavigationMetadataMutation(
        page: EditorPage,
        update: PageNavigationMetadataUpdate
    ) {
        guard PageNavigationMutationInterlockPolicy.canBeginMetadataMutation(
            isReplayMutationLocked: replayModel.isMutationLocked,
            activeStructuralMutationCount: activeStructuralMutationCount,
            hasStructuralMutationTask: structuralMutationTask != nil,
            isMetadataMutationInFlight:
                isPageNavigationMetadataMutationInFlight,
            hasPDFExportTask: singlePageExportTask != nil
                || notebookPDFExportTask != nil
        ),
              let notebook,
              notebook.pages.contains(page),
              selectedPageID == page.id,
              let editorSessionLease else { return }
        let canonicalUpdate: PageNavigationMetadataUpdate = switch update {
        case .bookmark(let isBookmarked):
            .bookmark(isBookmarked)
        case .outlineTitle(let outlineTitle):
            .outlineTitle(outlineTitle.flatMap(
                PageNavigationMetadataPolicy.canonicalOutlineTitle
            ))
        }
        guard !PageNavigationMetadataPolicy.isSatisfied(
            canonicalUpdate,
            by: page
        ) else {
            return
        }

        let mutationID = UUID()
        let authority = PageNavigationMetadataPublicationAuthority(
            mutationID: mutationID,
            notebookSnapshot: notebook,
            selectedPageID: page.id
        )
        pageNavigationMetadataMutationID = mutationID
        isPageNavigationMetadataMutationInFlight = true
        pageNavigationMetadataTask = Task { @MainActor in
            defer {
                if pageNavigationMetadataMutationID == mutationID {
                    pageNavigationMetadataTask = nil
                    isPageNavigationMetadataMutationInFlight = false
                }
            }
            guard !Task.isCancelled else { return }
            guard let updated = await appModel.updatePageNavigationMetadata(
                in: notebook,
                pageID: page.id,
                update: canonicalUpdate,
                editorSession: editorSessionLease
            ) else { return }
            guard PageNavigationMetadataPublicationAuthority.canPublish(
                updated,
                authority: authority,
                currentMutationID: pageNavigationMetadataMutationID,
                currentNotebook: self.notebook,
                currentSelectedPageID: selectedPageID,
                isReplayMutationLocked: replayModel.isMutationLocked
            ) else { return }
            self.notebook = updated
            outlineDraft = updated.pages.first(where: { $0.id == page.id })?
                .outlineTitle ?? ""
        }
    }

    private func cancelPageNavigationMetadataMutation() {
        pageNavigationMetadataMutationID = UUID()
        pageNavigationMetadataTask?.cancel()
        pageNavigationMetadataTask = nil
        isPageNavigationMetadataMutationInFlight = false
    }

    private func synchronizeOutlineDraft(pageID: UUID?) {
        outlineDraft = pageID.flatMap { pageID in
            notebook?.pages.first(where: { $0.id == pageID })?.outlineTitle
        } ?? ""
    }

    private func cacheReplayAuthoritativeDrawing(
        _ data: Data?,
        pageID: UUID?
    ) {
        replayAuthoritativeDrawingPageID = pageID
        replayAuthoritativeDrawing = NotebookEditorReplayDrawingResolver
            .boundedAuthoritativeDrawing(from: data)
    }

    @discardableResult
    private func selectPage(
        _ pageID: UUID,
        documentSearchAuthority: DocumentSearchSelectionAuthority? = nil
    ) async -> Bool {
        guard !replayModel.isMutationLocked,
              activeStructuralMutationCount == 0,
              !isPageNavigationMetadataMutationInFlight else { return false }
        if let documentSearchAuthority,
           !canCommitDocumentSearchSelection(documentSearchAuthority) {
            return false
        }
        guard pageID != selectedPageID else { return true }
        let generation = UUID()
        let previousPageID = selectedPageID
        pageSelectionGeneration = generation
        guard await flushPendingPage() else { return false }
        guard pageSelectionGeneration == generation,
              !replayModel.isMutationLocked,
              activeStructuralMutationCount == 0,
              !isPageNavigationMetadataMutationInFlight,
              selectedPageID == previousPageID,
              notebook?.pages.contains(where: { $0.id == pageID }) == true,
              documentSearchAuthority.map(
                canCommitDocumentSearchSelection
              ) ?? true else {
            return false
        }
        selectedPageID = pageID
        return true
    }

    private func canCommitDocumentSearchSelection(
        _ authority: DocumentSearchSelectionAuthority
    ) -> Bool {
        isDocumentSearchPresented
            && documentSearchInteractionGeneration == authority.generation
            && documentSearchModel.phase == .results
            && documentSearchModel.query == authority.query
            && documentSearchModel.results.contains(authority.result)
    }

    private func flushPendingPage() async -> Bool {
        guard let notebook, let pageID = selectedPageID else { return true }
        return await appModel.flushPendingWrites(notebookID: notebook.id, pageID: pageID)
    }

    private func isPageReadyForExport(_ page: EditorPage) -> Bool {
        switch page.kind {
        case .textDocument, .studySet:
            loadedStructuredPageID == page.id
        case .notebook, .whiteboard, .importedDocument:
            loadedDrawingPageID == page.id && loadedCanvasElementPageID == page.id
        }
    }
}

private enum EditorSidebarMode {
    case pages
    case search
}

enum CanvasElementWorkspaceLayout {
    static func fittedFrame(pageSize: CGSize, containerSize: CGSize) -> CGRect {
        let pageWidth = normalized(pageSize.width)
        let pageHeight = normalized(pageSize.height)
        let containerWidth = normalized(containerSize.width)
        let containerHeight = normalized(containerSize.height)
        let availableWidth = max(containerWidth - 48, 1)
        let availableHeight = max(containerHeight - 48, 1)
        let scale = min(availableWidth / pageWidth, availableHeight / pageHeight)
        let width = pageWidth * scale
        let height = pageHeight * scale
        return CGRect(
            x: (containerWidth - width) / 2,
            y: (containerHeight - height) / 2,
            width: width,
            height: height
        )
    }

    private static func normalized(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 1 }
        return value
    }
}

enum CanvasElementKind: String, CaseIterable, Identifiable {
    case text
    case image
    case shape
    case connector
    case stickyNote
    case tape
    case sticker
    case link

    var id: Self { self }

    static let directKinds: [Self] = [.text, .shape, .connector, .stickyNote, .tape]

    var title: LocalizedStringResource {
        switch self {
        case .text: "Text"
        case .image: "Image"
        case .shape: "Shape"
        case .connector: "Connector"
        case .stickyNote: "Sticky note"
        case .tape: "Tape"
        case .sticker: "Sticker"
        case .link: "Link"
        }
    }

    var symbolName: String {
        switch self {
        case .text: "textformat"
        case .image: "photo"
        case .shape: "square.on.circle"
        case .connector: "arrow.up.right"
        case .stickyNote: "note.text"
        case .tape: "rectangle.compress.vertical"
        case .sticker: "star.square"
        case .link: "link"
        }
    }
}

enum CanvasElementFactory {
    static func referencedAssetIDs(in elements: [CanvasElement]) -> [AssetID] {
        elements.compactMap { element in
            switch element.content {
            case .image(let image): image.assetID
            case .sticker(let sticker): sticker.assetID
            case .text, .shape, .connector, .stickyNote, .tape, .link: nil
            }
        }
    }

    static func make(
        _ kind: CanvasElementKind,
        assetID: AssetID? = nil,
        ordinal: Int,
        pageBounds: CanvasRect,
        now: Date,
        id: ElementID = ElementID()
    ) -> CanvasElement? {
        let origin = cascadingOrigin(ordinal: ordinal, pageBounds: pageBounds)
        switch kind {
        case .text:
            return CanvasElementEditing.makeText(
                id: id,
                text: String(localized: "Text"),
                at: origin,
                within: pageBounds,
                now: now
            )
        case .image:
            guard let assetID, assetID.isSHA256Digest else { return nil }
            return normalizedElement(
                id: id,
                frame: CanvasRect(x: origin.x, y: origin.y, width: 240, height: 180),
                content: .image(ImageElement(assetID: assetID)),
                pageBounds: pageBounds,
                now: now
            )
        case .shape:
            return CanvasElementEditing.makeShape(
                id: id,
                at: origin,
                within: pageBounds,
                now: now
            )
        case .connector:
            let frame = CanvasRect(x: origin.x, y: origin.y, width: 240, height: 120)
            return normalizedElement(
                id: id,
                frame: frame,
                content: .connector(ConnectorElement(
                    start: CanvasPoint(x: frame.x, y: frame.y + frame.height),
                    end: CanvasPoint(x: frame.x + frame.width, y: frame.y),
                    strokeColor: RGBAColor(red: 0.18, green: 0.42, blue: 0.88),
                    lineWidth: 3,
                    endCap: "arrow"
                )),
                pageBounds: pageBounds,
                now: now
            )
        case .stickyNote:
            return CanvasElementEditing.makeStickyNote(
                id: id,
                text: String(localized: "Sticky note"),
                at: origin,
                within: pageBounds,
                now: now
            )
        case .tape:
            return CanvasElementEditing.makeTape(
                id: id,
                at: origin,
                within: pageBounds,
                now: now
            )
        case .sticker:
            guard let assetID, assetID.isSHA256Digest else { return nil }
            return normalizedElement(
                id: id,
                frame: CanvasRect(x: origin.x, y: origin.y, width: 160, height: 160),
                content: .sticker(StickerElement(
                    assetID: assetID,
                    accessibilityLabel: String(localized: "Sticker")
                )),
                pageBounds: pageBounds,
                now: now
            )
        case .link:
            return nil
        }
    }

    static func makeLink(
        title: String,
        destination: URL,
        ordinal: Int,
        pageBounds: CanvasRect,
        now: Date,
        id: ElementID = ElementID()
    ) -> CanvasElement? {
        guard validatedLinkURL(destination.absoluteString) != nil else { return nil }
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return CanvasElementEditing.makeLink(
            id: id,
            title: normalizedTitle.isEmpty ? String(localized: "Link") : normalizedTitle,
            destination: destination,
            at: cascadingOrigin(ordinal: ordinal, pageBounds: pageBounds),
            within: pageBounds,
            now: now
        )
    }

    static func validatedLinkURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else { return nil }
        return url
    }

    private static func cascadingOrigin(
        ordinal: Int,
        pageBounds: CanvasRect
    ) -> CanvasPoint {
        let offset = Double(max(ordinal, 0) % 8) * 18
        return CanvasPoint(
            x: pageBounds.x + 40 + offset,
            y: pageBounds.y + 40 + offset
        )
    }

    private static func normalizedElement(
        id: ElementID,
        frame: CanvasRect,
        content: CanvasElementContent,
        pageBounds: CanvasRect,
        now: Date
    ) -> CanvasElement? {
        CanvasElementEditing.normalized(
            [CanvasElement(id: id, frame: frame, content: content, createdAt: now)],
            within: pageBounds,
            now: now
        ).first
    }
}

struct CanvasElementAssetCacheKey: Hashable {
    let assetID: AssetID
    let maximumPixelDimension: Int

    init(assetID: AssetID, request: CanvasElementImageRequest) {
        self.assetID = assetID
        maximumPixelDimension = CanvasElementAssetCachePolicy.pixelBucket(
            for: request.maximumPixelDimension
        )
    }
}

enum CanvasElementAssetCachePolicy {
    static let maximumEntryCount = 32
    static let maximumTotalByteCount = 96 * 1_024 * 1_024

    static func pixelBucket(for requestedDimension: CGFloat) -> Int {
        guard requestedDimension.isFinite, requestedDimension > 1 else { return 1 }
        let capped = min(
            Int(requestedDimension.rounded(.down)),
            Int(CanvasElementImageRequest.maximumAllowedPixelDimension)
        )
        var bucket = 1
        while bucket <= capped / 2 {
            bucket *= 2
        }
        return bucket
    }

    static func estimatedByteCount(of image: UIImage) -> Int {
        let width: Int
        let height: Int
        if let cgImage = image.cgImage {
            width = cgImage.width
            height = cgImage.height
        } else {
            let scale = image.scale.isFinite ? max(image.scale, 1) : 1
            let pixelWidth = image.size.width * scale
            let pixelHeight = image.size.height * scale
            guard pixelWidth.isFinite,
                  pixelHeight.isFinite,
                  pixelWidth > 0,
                  pixelHeight > 0,
                  pixelWidth <= CGFloat(Int.max / 4),
                  pixelHeight <= CGFloat(Int.max / 4) else { return 0 }
            width = Int(pixelWidth.rounded(.up))
            height = Int(pixelHeight.rounded(.up))
        }
        guard width > 0,
              height > 0,
              width <= Int.max / height,
              width * height <= Int.max / 4 else { return 0 }
        return width * height * 4
    }
}

private extension EditorPage {
    var canvasBounds: CanvasRect {
        CanvasRect(x: 0, y: 0, width: max(width, 1), height: max(height, 1))
    }
}

private struct PageThumbnail: View {
    @EnvironmentObject private var appModel: AppModel
    let notebookID: UUID
    let page: EditorPage
    let pageNumber: Int
    let isSelected: Bool
    let liveDrawingData: Data?
    let allowsAuthoritativeInk: Bool
    let action: () -> Void
    @State private var resolvedBackground: ResolvedPageBackground
    @State private var inkPreview: UIImage?
    @State private var inkPreviewGeneration = UUID()

    init(
        notebookID: UUID,
        page: EditorPage,
        pageNumber: Int,
        isSelected: Bool,
        liveDrawingData: Data?,
        allowsAuthoritativeInk: Bool,
        action: @escaping () -> Void
    ) {
        self.notebookID = notebookID
        self.page = page
        self.pageNumber = pageNumber
        self.isSelected = isSelected
        self.liveDrawingData = liveDrawingData
        self.allowsAuthoritativeInk = allowsAuthoritativeInk
        self.action = action
        _resolvedBackground = State(initialValue: ResolvedPageBackground(background: page.background, assetURL: nil))
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    if page.kind == .textDocument || page.kind == .studySet {
                        Color(uiColor: .secondarySystemBackground)
                        VStack(spacing: 8) {
                            Image(systemName: page.kind == .textDocument ? "doc.text" : "rectangle.stack")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                            if page.kind == .textDocument {
                                Text("Text document")
                            } else {
                                Text("Study set")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(8)
                    } else {
                        PageBackgroundPreview(resolvedBackground: resolvedBackground)
                        if allowsAuthoritativeInk, let inkPreview {
                            Image(uiImage: inkPreview)
                                .resizable()
                                .scaledToFit()
                        }
                    }
                }
                    .aspectRatio(CGFloat(page.width / max(page.height, 1)), contentMode: .fit)
                    .frame(maxHeight: 106)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(isSelected ? Color.accentColor : Color(uiColor: .separator), lineWidth: isSelected ? 3 : 1)
                    }
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
                HStack(spacing: 3) {
                    Text("Page")
                    Text(verbatim: "\(pageNumber)")
                }
                .font(.caption2)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(thumbnailAccessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: allowsAuthoritativeInk) {
            guard page.kind != .textDocument, page.kind != .studySet else { return }
            let generation = UUID()
            inkPreviewGeneration = generation
            if !allowsAuthoritativeInk { inkPreview = nil }
            let background = await appModel.resolveBackground(
                notebookID: notebookID,
                page: page
            )
            guard !Task.isCancelled,
                  inkPreviewGeneration == generation else { return }
            resolvedBackground = background
            guard allowsAuthoritativeInk else {
                inkPreview = nil
                return
            }
            if let liveDrawingData {
                renderInkPreview(liveDrawingData)
                return
            }
            let ink = await appModel.loadInk(notebookID: notebookID, page: page)
            guard !Task.isCancelled,
                  inkPreviewGeneration == generation,
                  allowsAuthoritativeInk else { return }
            if let ink {
                renderInkPreview(ink)
            } else {
                inkPreview = nil
            }
        }
        .onChange(of: allowsAuthoritativeInk) { _, allowsInk in
            guard !allowsInk else { return }
            inkPreview = nil
        }
        .onChange(of: liveDrawingData) { _, data in
            guard page.kind != .textDocument, page.kind != .studySet else { return }
            guard allowsAuthoritativeInk else {
                inkPreview = nil
                return
            }
            if let data { renderInkPreview(data) }
        }
    }

    private func renderInkPreview(_ data: Data) {
        guard let drawing = try? PKDrawing(data: data), !drawing.strokes.isEmpty else {
            inkPreview = nil
            return
        }
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(page.width),
            height: CGFloat(page.height)
        )
        let longestDimension = max(bounds.width, bounds.height)
        guard longestDimension.isFinite, longestDimension > 0 else {
            inkPreview = nil
            return
        }
        let scale = min(0.25, 256 / longestDimension)
        guard scale.isFinite, scale > 0 else {
            inkPreview = nil
            return
        }
        inkPreview = drawing.image(from: bounds, scale: scale)
    }

    private var thumbnailAccessibilityLabel: Text {
        let pageLabel = Text("Page") + Text(verbatim: " \(pageNumber)")
        switch page.kind {
        case .textDocument:
            return pageLabel + Text(verbatim: ", ") + Text("Text document")
        case .studySet:
            return pageLabel + Text(verbatim: ", ") + Text("Study set")
        case .notebook, .whiteboard, .importedDocument:
            return pageLabel
        }
    }
}

private struct NotebookAudioToolbarButton: View {
    @ObservedObject var model: NotebookAudioPanelModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(
                "Audio",
                systemImage: model.isRecording ? "waveform.badge.mic" : "waveform"
            )
        }
        .buttonStyle(.bordered)
        .accessibilityValue(model.isRecording ? "Recording" : "Ready")
        .accessibilityIdentifier("notebook.audio.open")
    }
}

private struct EditorToolButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 18, height: 18)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                isSelected ? Color.accentColor : Color(uiColor: .tertiarySystemFill),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private extension InkColor {
    var color: Color {
        switch self {
        case .black: .black
        case .blue: .blue
        case .red: .red
        case .green: .green
        }
    }

    var localizedTitle: LocalizedStringResource {
        switch self {
        case .black: "Black"
        case .blue: "Blue"
        case .red: "Red"
        case .green: "Green"
        }
    }
}
