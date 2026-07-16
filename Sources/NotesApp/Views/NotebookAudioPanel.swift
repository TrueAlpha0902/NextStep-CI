import NotesCore
import NotesServices
import SwiftUI

enum NotebookAudioPanelReplayPolicy {
    static func isEnabled(
        canStartReplay: Bool,
        activity: NotebookAudioCoordinatorActivity,
        session: AudioSessionDescriptor
    ) -> Bool {
        guard canStartReplay,
              activity == .idle,
              session.durationSeconds.isFinite,
              session.durationSeconds > 0,
              session.schemaVersion < 3
                || (session.replayFilename != nil
                    && (session.replayEventCount ?? 0) > 0),
              let timelineFilename = session.timelineFilename,
              !timelineFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }
}

struct NotebookAudioPanel: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: NotebookAudioPanelModel
    let notebookID: UUID
    let currentPageID: UUID?
    let pages: [EditorPage]
    let exportDependencies: NotebookAudioExportDependencies
    let canStartReplay: Bool
    let onRequestReplay: (AudioSessionID) -> Void
    let prepareRecording: @MainActor () async
        -> NotebookAudioRecordingPreparation
    let flushBeforeStoppingRecording: @MainActor () async -> Bool

    @State private var scrubTime: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var exportTask: Task<Void, Never>?
    @State private var exportGeneration: UUID?
    @State private var exportingSessionID: AudioSessionID?
    @State private var shareURL: URL?
    @State private var showsShareSheet = false
    @State private var exportFailureMessage: String?
    @State private var showsExportFailure = false
    @State private var transcriptSearchQuery = ""
    @State private var transcriptSearchResult: NotebookAudioTranscriptSearchResult?
    @State private var activeTranscriptMatchIndex: Int?
    @State private var isSearchingTranscript = false
    @State private var completedTranscriptSearchInput: String?

    private struct TranscriptSearchRequest: Equatable, Sendable {
        let query: String
        let audioSessionID: AudioSessionID
        let generatedAt: Date
        let segmentCount: Int
        let finalSegmentID: UUID?
    }

    private enum ExportSelection: Sendable {
        case recording
        case transcript(NotebookAudioTranscriptExportFormat)
    }

    private var blocksInteractiveDismissal: Bool {
        switch model.snapshot.activity {
        case .startingRecording, .stoppingRecording, .persistingRecording,
             .cancelling:
            true
        default:
            false
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if let failureMessage = model.failureMessage {
                        failureCard(message: failureMessage)
                    }

                    recordingControls
                    transcriptionLanguage
                    recordings

                    if let transcript = model.transcript {
                        transcriptPreview(transcript)
                    }
                }
                .padding()
            }
            .navigationTitle("Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        cancelExport()
                        dismiss()
                    }
                    .disabled(blocksInteractiveDismissal)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(blocksInteractiveDismissal)
        .task(id: notebookID) {
            await model.open(notebookID: notebookID)
            while !Task.isCancelled {
                await model.poll()
                do {
                    try await Task<Never, Never>.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
        }
        .onChange(of: model.playbackState.currentTime) { _, newTime in
            guard !isScrubbing else { return }
            scrubTime = newTime
        }
        .task(id: transcriptSearchRequest) {
            await refreshTranscriptSearch()
        }
        .onDisappear {
            cancelExport()
            guard !showsShareSheet else { return }
            removeOwnedShareURL()
        }
        .sheet(isPresented: $showsShareSheet, onDismiss: {
            removeOwnedShareURL()
        }) {
            if let shareURL {
                ActivitySheet(items: [shareURL])
                    .presentationDetents([.medium, .large])
            }
        }
        .alert("Export failed", isPresented: $showsExportFailure) {
            Button("OK", role: .cancel) {
                exportFailureMessage = nil
            }
        } message: {
            Text(exportFailureMessage ?? String(localized: "The recording could not be exported."))
        }
        .accessibilityIdentifier("notebook.audio.panel")
    }

    private var recordingControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Label(activityTitle, systemImage: activitySymbol)
                    .font(.headline)
                    .foregroundStyle(activityTint)
                    .accessibilityIdentifier("notebook.audio.activity")

                Text("Recording keeps page marks and complete drawing checkpoints so Note Replay can restore erases, moves, and element edits.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { recordingButtons }
                    VStack(alignment: .leading, spacing: 10) { recordingButtons }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Notebook recording")
        }
    }

    @ViewBuilder
    private var recordingButtons: some View {
        if model.snapshot.activity == .recording, let currentPageID {
            Button {
                Task {
                    guard await flushBeforeStoppingRecording() else { return }
                    await model.stopRecording(currentPageID: currentPageID)
                }
            } label: {
                Label("Stop and save", systemImage: "stop.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("notebook.audio.record.stop")

            Button(role: .destructive) {
                Task { await model.cancelCurrentOperation() }
            } label: {
                Label("Cancel recording", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("notebook.audio.record.cancel")
        } else if model.snapshot.activity == .idle, let currentPageID {
            Button {
                Task {
                    let preparation = await prepareRecording()
                    guard preparation.canStart else { return }
                    await model.startRecording(
                        notebookID: notebookID,
                        pageID: currentPageID,
                        initialReplaySnapshot: preparation.replaySnapshot
                    )
                }
            } label: {
                Label("Record", systemImage: "mic.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("notebook.audio.record.start")
        } else if model.snapshot.activity != .idle {
            ProgressView()
                .controlSize(.small)
            Button(role: .cancel) {
                Task { await model.cancelCurrentOperation() }
            } label: {
                Label("Cancel operation", systemImage: "xmark.circle")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("notebook.audio.operation.cancel")
        } else {
            Text("Select a page before recording.")
                .foregroundStyle(.secondary)
        }
    }

    private var transcriptionLanguage: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Language", selection: $model.selectedLocale) {
                    ForEach(NotebookAudioTranscriptionLocale.allCases) { locale in
                        Text(locale.title).tag(locale)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("notebook.audio.transcription.locale")

                Label {
                    Text(verbatim: CurrentDevicePresentation.localized(
                        "Apple Speech runs this transcription on this iPad when the selected language supports it."
                    ))
                } icon: {
                    Image(systemName: "lock.iphone")
                }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } label: {
            Text("On-device transcription")
        }
    }

    private var recordings: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if model.isLoadingSessions && model.sessions.isEmpty {
                    ProgressView("Loading recordings")
                        .frame(maxWidth: .infinity, alignment: .center)
                } else if model.sessions.isEmpty {
                    ContentUnavailableView(
                        "No recordings",
                        systemImage: "waveform",
                        description: Text("Record audio to keep it with this notebook.")
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(model.sessions) { session in
                        sessionRow(session)
                        if session.id != model.sessions.last?.id { Divider() }
                    }
                }
            }
        } label: {
            Text("Recordings")
        }
        .accessibilityIdentifier("notebook.audio.sessions")
    }

    private func sessionRow(_ session: AudioSessionDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.headline)
                    Text(sessionMetadata(session))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                if session.transcriptAssetID != nil {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Saved transcript attached")
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { sessionButtons(session) }
                VStack(alignment: .leading, spacing: 8) { sessionButtons(session) }
            }

            if model.playbackSessionID == session.id,
               (model.snapshot.activity == .playing || model.snapshot.activity == .paused) {
                playbackScrubber(session: session)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("notebook.audio.session.\(session.id.description)")
    }

    @ViewBuilder
    private func sessionButtons(_ session: AudioSessionDescriptor) -> some View {
        if model.playbackSessionID == session.id, model.snapshot.activity == .playing {
            Button {
                Task { await model.pausePlayback() }
            } label: {
                Label("Pause", systemImage: "pause.fill")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("notebook.audio.playback.pause")
        } else if model.playbackSessionID == session.id, model.snapshot.activity == .paused {
            Button {
                Task { await model.resumePlayback() }
            } label: {
                Label("Resume", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("notebook.audio.playback.resume")
        } else {
            Button {
                Task { await model.play(sessionID: session.id) }
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .disabled(model.snapshot.activity != .idle)
            .accessibilityIdentifier("notebook.audio.playback.play.\(session.id.description)")
        }

        if model.playbackSessionID == session.id,
           (model.snapshot.activity == .playing || model.snapshot.activity == .paused) {
            Button {
                Task { await model.stopPlayback() }
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("notebook.audio.playback.stop")
        }

        Button {
            guard NotebookAudioPanelReplayPolicy.isEnabled(
                canStartReplay: canStartReplay,
                activity: model.snapshot.activity,
                session: session
            ) else { return }
            dismiss()
            onRequestReplay(session.id)
        } label: {
            Label("Note Replay", systemImage: "waveform.path.ecg.rectangle")
        }
        .buttonStyle(.bordered)
        .disabled(
            !NotebookAudioPanelReplayPolicy.isEnabled(
                canStartReplay: canStartReplay,
                activity: model.snapshot.activity,
                session: session
            )
        )
        .accessibilityIdentifier("notebook.audio.replay.\(session.id.description)")

        if session.transcriptAssetID != nil {
            Button {
                Task { await model.loadTranscript(sessionID: session.id) }
            } label: {
                Label("View transcript", systemImage: "doc.text")
            }
            .buttonStyle(.bordered)
            .disabled(model.snapshot.activity != .idle)
            .accessibilityIdentifier("notebook.audio.transcript.view.\(session.id.description)")
        }

        Button {
            Task { await model.transcribe(sessionID: session.id) }
        } label: {
            Label("Transcribe", systemImage: "text.bubble")
        }
        .buttonStyle(.bordered)
        .disabled(model.snapshot.activity != .idle)
        .accessibilityIdentifier("notebook.audio.transcribe.\(session.id.description)")

        Menu {
            Button {
                startRecordingExport(sessionID: session.id)
            } label: {
                Label("Recording (M4A)", systemImage: "waveform")
            }

            if session.transcriptAssetID != nil {
                Button {
                    startTranscriptExport(sessionID: session.id, format: .plainText)
                } label: {
                    Label("Transcript (TXT)", systemImage: "doc.plaintext")
                }

                Button {
                    startTranscriptExport(sessionID: session.id, format: .subRip)
                } label: {
                    Label("Subtitles (SRT)", systemImage: "captions.bubble")
                }
            }
        } label: {
            if exportingSessionID == session.id {
                Label("Exporting", systemImage: "arrow.up.doc")
            } else {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
        .buttonStyle(.bordered)
        .disabled(model.snapshot.activity != .idle || exportTask != nil)
        .accessibilityIdentifier("notebook.audio.export.\(session.id.description)")
    }

    private func playbackScrubber(session: AudioSessionDescriptor) -> some View {
        VStack(spacing: 4) {
            Slider(
                value: $scrubTime,
                in: 0 ... max(session.durationSeconds, 0.001)
            ) { editing in
                isScrubbing = editing
                if !editing {
                    Task { await model.seekPlayback(to: scrubTime) }
                }
            }
            .accessibilityLabel("Playback position")
            .accessibilityValue(
                Text(verbatim: durationText(scrubTime))
                    + Text(" of ")
                    + Text(verbatim: durationText(session.durationSeconds))
            )
            .accessibilityIdentifier("notebook.audio.playback.position")

            HStack {
                Text(durationText(scrubTime))
                Spacer()
                Text(durationText(session.durationSeconds))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func transcriptPreview(_ payload: NotebookAudioTranscriptPayload) -> some View {
        GroupBox {
            LazyVStack(alignment: .leading, spacing: 12) {
                Label("Saved to notebook", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("notebook.audio.transcript.saved")
                Text("This transcript is stored with the recording and remains available after you reopen the notebook.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if payload.segments.isEmpty {
                    Text("No speech was found.")
                        .foregroundStyle(.secondary)
                } else {
                    transcriptSearchControls

                    ScrollViewReader { proxy in
                        Group {
                            if isSearchingTranscript {
                                ProgressView("Searching transcript")
                                    .frame(maxWidth: .infinity, alignment: .center)
                            } else if !transcriptSearchQuery.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty, displayedTranscriptSegments.isEmpty {
                                ContentUnavailableView(
                                    "No matches",
                                    systemImage: "magnifyingglass",
                                    description: Text("Try a different word or phrase.")
                                )
                                .frame(maxWidth: .infinity)
                            } else {
                                ForEach(displayedTranscriptSegments) { segment in
                                    Button {
                                        Task { await model.playTranscriptSegment(segment) }
                                    } label: {
                                        HStack(alignment: .top, spacing: 12) {
                                            Text(durationText(segment.startTime))
                                                .font(.caption.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(segment.text)
                                                    .foregroundStyle(.primary)
                                                    .multilineTextAlignment(.leading)
                                                if let pageID = segment.pageID {
                                                    pageLabel(pageID.rawValue)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                }
                                            }
                                            Spacer(minLength: 0)
                                        }
                                        .padding(8)
                                        .background(
                                            activeTranscriptMatchID == segment.id
                                                ? Color.accentColor.opacity(0.12)
                                                : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 8)
                                        )
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id(segment.id)
                                    .accessibilityHint("Plays from this transcript segment")
                                    .accessibilityIdentifier("notebook.audio.transcript.segment.\(segment.id.uuidString.lowercased())")
                                }
                            }
                        }
                        .onChange(of: activeTranscriptMatchID) { _, segmentID in
                            guard let segmentID else { return }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(segmentID, anchor: .center)
                            }
                        }
                    }

                    if transcriptSearchResult?.queryWasTruncated == true
                        || transcriptSearchResult?.resultsWereTruncated == true {
                        Label(
                            "Search was limited to keep this transcript responsive.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } label: {
            Text("Saved transcript")
        }
        .accessibilityIdentifier("notebook.audio.transcript")
    }

    private var transcriptSearchControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search transcript", text: $transcriptSearchQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("notebook.audio.transcript.search")
                if isSearchingTranscript {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Searching transcript")
                } else if !transcriptSearchQuery.isEmpty {
                    Button {
                        transcriptSearchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear transcript search")
                    .accessibilityIdentifier("notebook.audio.transcript.search.clear")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))

            if let result = currentTranscriptSearchResult, !result.matches.isEmpty {
                HStack(spacing: 8) {
                    Text(verbatim: "\((activeTranscriptMatchIndex ?? 0) + 1) / \(result.matches.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            Text("Search result")
                                + Text(verbatim: " \((activeTranscriptMatchIndex ?? 0) + 1) ")
                                + Text("of")
                                + Text(verbatim: " \(result.matches.count)")
                        )
                    Spacer()
                    Button {
                        moveTranscriptMatch(by: -1)
                    } label: {
                        Label("Previous match", systemImage: "chevron.up")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .disabled((activeTranscriptMatchIndex ?? 0) <= 0)
                    .accessibilityIdentifier("notebook.audio.transcript.search.previous")

                    Button {
                        moveTranscriptMatch(by: 1)
                    } label: {
                        Label("Next match", systemImage: "chevron.down")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .disabled((activeTranscriptMatchIndex ?? 0) >= result.matches.count - 1)
                    .accessibilityIdentifier("notebook.audio.transcript.search.next")
                }
            }
        }
    }

    private var transcriptSearchRequest: TranscriptSearchRequest? {
        guard let transcript = model.transcript else { return nil }
        return TranscriptSearchRequest(
            query: transcriptSearchQuery,
            audioSessionID: transcript.audioSessionID,
            generatedAt: transcript.generatedAt,
            segmentCount: transcript.segments.count,
            finalSegmentID: transcript.segments.last?.id
        )
    }

    private var currentTranscriptSearchResult: NotebookAudioTranscriptSearchResult? {
        guard completedTranscriptSearchInput == transcriptSearchRequest?.query else { return nil }
        return transcriptSearchResult
    }

    private var displayedTranscriptSegments: [NotebookAudioTranscriptSegmentMapping] {
        guard let transcript = model.transcript else { return [] }
        if transcriptSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return transcript.segments
        }
        return currentTranscriptSearchResult?.matches ?? []
    }

    private var activeTranscriptMatchID: UUID? {
        guard let result = currentTranscriptSearchResult,
              let index = activeTranscriptMatchIndex,
              result.matches.indices.contains(index) else { return nil }
        return result.matches[index].id
    }

    private func refreshTranscriptSearch() async {
        guard let request = transcriptSearchRequest,
              let transcript = model.transcript,
              transcript.audioSessionID == request.audioSessionID,
              transcript.generatedAt == request.generatedAt else {
            transcriptSearchResult = nil
            activeTranscriptMatchIndex = nil
            completedTranscriptSearchInput = nil
            isSearchingTranscript = false
            return
        }
        if request.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            transcriptSearchResult = nil
            activeTranscriptMatchIndex = nil
            completedTranscriptSearchInput = request.query
            isSearchingTranscript = false
            return
        }

        isSearchingTranscript = true
        transcriptSearchResult = nil
        activeTranscriptMatchIndex = nil
        completedTranscriptSearchInput = nil
        do {
            let worker = Task.detached(priority: .userInitiated) {
                try NotebookAudioTranscriptSearch.search(request.query, in: transcript)
            }
            let result = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try Task.checkCancellation()
            guard transcriptSearchRequest == request else { return }
            transcriptSearchResult = result
            activeTranscriptMatchIndex = result.matches.isEmpty ? nil : 0
            completedTranscriptSearchInput = request.query
            isSearchingTranscript = false
        } catch is CancellationError {
            guard transcriptSearchRequest == request else { return }
            isSearchingTranscript = false
        } catch {
            guard transcriptSearchRequest == request else { return }
            transcriptSearchResult = nil
            activeTranscriptMatchIndex = nil
            completedTranscriptSearchInput = request.query
            isSearchingTranscript = false
        }
    }

    private func moveTranscriptMatch(by offset: Int) {
        guard let result = currentTranscriptSearchResult,
              !result.matches.isEmpty else { return }
        let current = activeTranscriptMatchIndex ?? 0
        activeTranscriptMatchIndex = min(max(current + offset, 0), result.matches.count - 1)
    }

    private func startRecordingExport(sessionID: AudioSessionID) {
        startExport(sessionID: sessionID, selection: .recording)
    }

    private func startTranscriptExport(
        sessionID: AudioSessionID,
        format: NotebookAudioTranscriptExportFormat
    ) {
        startExport(sessionID: sessionID, selection: .transcript(format))
    }

    private func startExport(sessionID: AudioSessionID, selection: ExportSelection) {
        guard exportTask == nil,
              model.snapshot.activity == .idle,
              model.sessions.contains(where: { $0.id == sessionID }) else { return }
        let generation = UUID()
        exportGeneration = generation
        exportingSessionID = sessionID
        exportFailureMessage = nil
        showsExportFailure = false
        let exporter = NotebookAudioExporter(dependencies: exportDependencies)
        exportTask = Task { @MainActor in
            await prepareExport(
                exporter: exporter,
                generation: generation,
                sessionID: sessionID,
                selection: selection
            )
        }
    }

    @MainActor
    private func prepareExport(
        exporter: NotebookAudioExporter,
        generation: UUID,
        sessionID: AudioSessionID,
        selection: ExportSelection
    ) async {
        var unpublishedURL: URL?
        defer {
            if let unpublishedURL {
                NotesExportTemporaryFile.removeOwned(unpublishedURL)
            }
            if exportGeneration == generation {
                exportTask = nil
                exportGeneration = nil
                exportingSessionID = nil
            }
        }

        do {
            let url: URL
            switch selection {
            case .recording:
                url = try await exporter.exportRecording(
                    notebookID: notebookID,
                    sessionID: sessionID
                )
            case .transcript(let format):
                url = try await exporter.exportTranscript(
                    notebookID: notebookID,
                    sessionID: sessionID,
                    format: format
                )
            }
            unpublishedURL = url
            try Task.checkCancellation()
            guard exportGeneration == generation,
                  model.sessions.contains(where: { $0.id == sessionID }) else {
                throw CancellationError()
            }
            removeOwnedShareURL()
            shareURL = url
            unpublishedURL = nil
            showsShareSheet = true
        } catch is CancellationError {
            return
        } catch {
            guard exportGeneration == generation else { return }
            exportFailureMessage = error.localizedDescription
            showsExportFailure = true
        }
    }

    private func cancelExport() {
        exportTask?.cancel()
    }

    private func removeOwnedShareURL() {
        guard !showsShareSheet, let shareURL else { return }
        NotesExportTemporaryFile.removeOwned(shareURL)
        self.shareURL = nil
    }

    private func failureCard(message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Audio needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.canRetry {
                    Button("Try again") { Task { await model.retry() } }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("notebook.audio.retry")
                }
                Button("Dismiss") { model.dismissFailure() }
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("notebook.audio.failure")
    }

    private var activityTitle: String {
        switch model.snapshot.activity {
        case .idle: String(localized: "Ready")
        case .startingRecording: String(localized: "Starting recording")
        case .recording: String(localized: "Recording")
        case .stoppingRecording: String(localized: "Stopping recording")
        case .persistingRecording: String(localized: "Saving recording")
        case .preparingPlayback: String(localized: "Preparing playback")
        case .playing: String(localized: "Playing")
        case .paused: String(localized: "Paused")
        case .transcribing: String(localized: "Creating transcript on device")
        case .loadingTranscript: String(localized: "Loading saved transcript")
        case .cancelling: String(localized: "Cancelling")
        }
    }

    private var activitySymbol: String {
        switch model.snapshot.activity {
        case .recording: "record.circle.fill"
        case .playing: "speaker.wave.2.fill"
        case .paused: "pause.circle.fill"
        case .idle: "checkmark.circle"
        default: "hourglass"
        }
    }

    private var activityTint: Color {
        model.snapshot.activity == .recording ? .red : .primary
    }

    private func sessionMetadata(_ session: AudioSessionDescriptor) -> String {
        let duration = durationText(session.durationSeconds)
        guard let bytes = session.audioByteCount else { return duration }
        return "\(duration) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", locale: .current, hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", locale: .current, minutes, remainingSeconds)
    }

    private func pageLabel(_ pageID: UUID) -> Text {
        guard let index = pages.firstIndex(where: { $0.id == pageID }) else {
            return Text("Page unavailable")
        }
        return Text("Page") + Text(verbatim: " \(index + 1)")
    }
}
