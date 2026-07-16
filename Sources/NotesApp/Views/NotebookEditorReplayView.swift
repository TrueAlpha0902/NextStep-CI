import NotesCore
import PencilKit
import SwiftUI
import UIKit

enum NotebookEditorReplayDrawingResolver {
    static func drawing(
        displayedPageID: UUID,
        replayPageID: PageID?,
        frame: NoteReplayPageFrame?,
        authoritativePageID: UUID?,
        authoritativeDrawing: PKDrawing?,
        allowsAuthoritativeFallbackWithoutFrame: Bool = false
    ) -> PKDrawing {
        guard replayPageID?.rawValue == displayedPageID else {
            return PKDrawing()
        }
        if let frame {
            guard frame.pageID.rawValue == displayedPageID else {
                return PKDrawing()
            }
            if let drawing = frame.frame.drawing {
                return drawing
            }
            // A refused historical payload must never expose ink from the
            // notebook's newer authoritative editor state.
            if frame.sceneKey.isHistoricalSnapshot {
                return PKDrawing()
            }
        } else if !allowsAuthoritativeFallbackWithoutFrame {
            return PKDrawing()
        }
        guard authoritativePageID == displayedPageID,
              let authoritativeDrawing else {
            return PKDrawing()
        }
        return authoritativeDrawing
    }

    static func boundedAuthoritativeDrawing(from data: Data?) -> PKDrawing? {
        guard let data,
              data.count <= NoteReplayRenderingLimits
                .hardMaximumDrawingByteCount else { return nil }
        guard let drawing = try? PKDrawing(data: data) else { return nil }
        let limits = NoteReplayRenderingLimits.default
        let strokes = drawing.strokes
        guard strokes.count <= limits.maximumStrokeCount else { return nil }
        var pointCount = 0
        for stroke in strokes {
            let strokePointCount = stroke.path.count
            guard strokePointCount <= limits.maximumPointsPerStroke,
                  strokePointCount <= limits.maximumPointCount - pointCount else {
                return nil
            }
            pointCount += strokePointCount
        }
        let estimatedBytes = strokes.count
            * NoteReplayRenderingLimits.estimatedBytesPerStroke
            + pointCount * NoteReplayRenderingLimits.estimatedBytesPerPoint
        guard estimatedBytes
                <= limits.maximumEstimatedDecodedStructureByteCount else {
            return nil
        }
        return drawing
    }
}

enum NotebookEditorReplayElementResolver {
    static func elements(
        displayedPageID: UUID,
        replayPageID: PageID?,
        frame: NoteReplayPageFrame?,
        authoritativePageID: UUID?,
        authoritativeElements: [CanvasElement],
        allowsAuthoritativeFallbackWithoutFrame: Bool = false
    ) -> [CanvasElement] {
        guard replayPageID?.rawValue == displayedPageID else { return [] }
        if let frame {
            guard frame.pageID.rawValue == displayedPageID else { return [] }
            if let historicalElements = frame.frame.historicalElements {
                return historicalElements
            }
            // Historical frames are required to carry an explicit complete
            // element snapshot, including `[]`. Fail closed if that invariant
            // is ever broken so post-recording editor changes cannot leak in.
            if frame.sceneKey.isHistoricalSnapshot { return [] }
        } else if !allowsAuthoritativeFallbackWithoutFrame {
            return []
        }
        guard authoritativePageID == displayedPageID else { return [] }
        return authoritativeElements
    }
}

enum NotebookEditorReplayFramePolicy {
    private static let playbackTimeTolerance: TimeInterval = 0.001

    static func isDisplayable(
        _ frame: NoteReplayPageFrame?,
        for pageID: PageID,
        playbackTime: TimeInterval,
        mode: NoteReplayMode,
        state: NoteReplayControllerState
    ) -> Bool {
        switch state {
        case .playing, .paused, .finished:
            break
        case .idle, .preparing, .seeking, .stopping:
            return false
        }
        guard let frame,
              frame.pageID == pageID,
              playbackTime.isFinite,
              frame.frame.playbackTime.isFinite,
              frame.frame.requestedMode == mode else {
            return false
        }
        return frame.frame.playbackTime
            <= playbackTime + playbackTimeTolerance
    }
}

struct NotebookEditorReplaySurface: View {
    let page: EditorPage
    let resolvedBackground: ResolvedPageBackground
    let drawing: PKDrawing
    let staticElements: [CanvasElement]
    let assetImageResolver: (AssetID, CanvasElementImageRequest) -> UIImage?

    var body: some View {
        GeometryReader { proxy in
            let fittedFrame = CanvasElementWorkspaceLayout.fittedFrame(
                pageSize: CGSize(
                    width: CGFloat(page.width),
                    height: CGFloat(page.height)
                ),
                containerSize: proxy.size
            )
            ZStack {
                PageBackgroundPreview(resolvedBackground: resolvedBackground)
                NotebookEditorReplayReadOnlyCanvas(
                    pageID: page.id,
                    pageSize: CGSize(
                        width: CGFloat(page.width),
                        height: CGFloat(page.height)
                    ),
                    drawing: drawing
                )
                if !staticElements.isEmpty {
                    CanvasElementLayerView(
                        elements: .constant(staticElements),
                        pageBounds: CanvasRect(
                            x: 0,
                            y: 0,
                            width: max(page.width, 1),
                            height: max(page.height, 1)
                        ),
                        assetImageResolver: assetImageResolver,
                        onElementsChanged: { _ in }
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .frame(width: fittedFrame.width, height: fittedFrame.height)
            .position(x: fittedFrame.midX, y: fittedFrame.midY)
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .accessibilityIdentifier("noteReplay.surface")
    }
}

private struct NotebookEditorReplayReadOnlyCanvas: UIViewRepresentable {
    let pageID: UUID
    let pageSize: CGSize
    let drawing: PKDrawing

    func makeUIView(context: Context) -> NotebookEditorReplayCanvasSurface {
        NotebookEditorReplayCanvasSurface()
    }

    func updateUIView(
        _ uiView: NotebookEditorReplayCanvasSurface,
        context: Context
    ) {
        uiView.configure(
            pageID: pageID,
            pageSize: pageSize,
            drawing: drawing
        )
    }
}

@MainActor
private final class NotebookEditorReplayCanvasSurface: UIView {
    private let canvasView = PKCanvasView()
    private var pageID: UUID?
    private var pageSize = CGSize(width: 1, height: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        isUserInteractionEnabled = false
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.isScrollEnabled = false
        canvasView.isUserInteractionEnabled = false
        canvasView.delegate = nil
        canvasView.accessibilityLabel = String(localized: "Replay drawing")
        canvasView.accessibilityIdentifier = "noteReplay.canvas"
        addSubview(canvasView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(pageID: UUID, pageSize: CGSize, drawing: PKDrawing) {
        let normalizedSize = CGSize(
            width: max(pageSize.width, 1),
            height: max(pageSize.height, 1)
        )
        let pageChanged = self.pageID != pageID
        let sizeChanged = self.pageSize != normalizedSize
        self.pageID = pageID
        self.pageSize = normalizedSize
        canvasView.drawing = drawing
        if pageChanged || sizeChanged { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        canvasView.transform = .identity
        canvasView.frame = CGRect(origin: .zero, size: pageSize)
        let scale = min(bounds.width / pageSize.width, bounds.height / pageSize.height)
        canvasView.layer.anchorPoint = CGPoint(x: 0, y: 0)
        canvasView.layer.position = .zero
        canvasView.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}

struct NotebookEditorReplayControls: View {
    @ObservedObject var model: NotebookEditorReplayModel
    let onStop: () -> Void

    @State private var scrubTime: TimeInterval = 0
    @State private var isScrubbing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    transportButtons
                    timeline
                    modePicker
                    stopButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        transportButtons
                        modePicker
                        stopButton
                    }
                    timeline
                }
            }
            replayStatus
        }
        .onChange(of: model.playbackTime) { _, time in
            guard !isScrubbing else { return }
            scrubTime = time
        }
        .onChange(of: model.duration) { _, duration in
            scrubTime = min(max(scrubTime, 0), max(duration, 0))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("noteReplay.controls")
    }

    private var transportButtons: some View {
        HStack(spacing: 6) {
            Button {
                Task { await model.skipBackward() }
            } label: {
                Image(systemName: "gobackward.15")
            }
            .accessibilityLabel("Skip back 15 seconds")
            .accessibilityIdentifier("noteReplay.skipBackward")
            .disabled(!canSeek)

            Button {
                Task {
                    if model.state == .playing {
                        await model.pause()
                    } else {
                        await model.resume()
                    }
                }
            } label: {
                Image(systemName: model.state == .playing
                      ? "pause.fill"
                      : "play.fill")
                    .frame(minWidth: 24, minHeight: 24)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(
                model.state == .playing ? Text("Pause") : Text("Play")
            )
            .accessibilityIdentifier("noteReplay.playPause")
            .disabled(!canTogglePlayback)

            Button {
                Task { await model.skipForward() }
            } label: {
                Image(systemName: "goforward.15")
            }
            .accessibilityLabel("Skip forward 15 seconds")
            .accessibilityIdentifier("noteReplay.skipForward")
            .disabled(!canSeek)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
    }

    private var timeline: some View {
        HStack(spacing: 8) {
            Text(Self.formattedTime(isScrubbing ? scrubTime : model.playbackTime))
                .monospacedDigit()
                .accessibilityHidden(true)
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubTime : model.playbackTime },
                    set: { scrubTime = $0 }
                ),
                in: 0...max(model.duration, 0.001),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        let requestedTime = scrubTime
                        Task { await model.seek(to: requestedTime) }
                    }
                }
            )
            .frame(minWidth: 140, idealWidth: 260, maxWidth: 420)
            .accessibilityLabel("Playback position")
            .accessibilityValue(Text(verbatim: Self.formattedPosition(
                current: isScrubbing ? scrubTime : model.playbackTime,
                duration: model.duration
            )))
            .accessibilityIdentifier("noteReplay.position")
            .disabled(!canSeek)
            Text(Self.formattedTime(model.duration))
                .monospacedDigit()
                .accessibilityHidden(true)
        }
        .font(.caption)
    }

    private var modePicker: some View {
        Picker("Replay mode", selection: Binding(
            get: { model.mode },
            set: { mode in Task { await model.setMode(mode) } }
        )) {
            Text("Whole Stroke").tag(NoteReplayMode.wholeStrokeReveal)
            Text("Spotlight").tag(NoteReplayMode.spotlight)
            Text("Static").tag(NoteReplayMode.static)
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("noteReplay.mode")
        .disabled(
            model.startReservation != nil
                || model.state == .preparing
                || model.state == .seeking
                || model.state == .stopping
                || model.isStopping
        )
    }

    private var stopButton: some View {
        Button(role: .cancel, action: onStop) {
            Label("Stop", systemImage: "stop.fill")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Stop Note Replay")
        .accessibilityIdentifier("noteReplay.stop")
        .disabled(model.isStopping || model.state == .stopping)
    }

    @ViewBuilder
    private var replayStatus: some View {
        if let status = model.status {
            Label(status.localizedMessage, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .accessibilityIdentifier("noteReplay.issue")
        } else if model.startReservation != nil || model.state == .preparing {
            ProgressView("Preparing Note Replay")
                .font(.caption)
                .accessibilityIdentifier("noteReplay.issue")
        } else if model.state == .seeking {
            ProgressView("Seeking Note Replay")
                .font(.caption)
                .accessibilityIdentifier("noteReplay.issue")
        } else if model.isStopping || model.state == .stopping {
            ProgressView("Stopping Note Replay")
                .font(.caption)
                .accessibilityIdentifier("noteReplay.issue")
        } else if model.state == .finished {
            Label("Replay finished", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .accessibilityIdentifier("noteReplay.issue")
        }
    }

    private var canSeek: Bool {
        model.state == .playing || model.state == .paused || model.state == .finished
    }

    private var canTogglePlayback: Bool {
        model.state == .playing || model.state == .paused || model.state == .finished
    }

    private static func formattedTime(_ value: TimeInterval) -> String {
        let totalSeconds = Int(max(value.isFinite ? value : 0, 0).rounded(.down))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private static func formattedPosition(
        current: TimeInterval,
        duration: TimeInterval
    ) -> String {
        String.localizedStringWithFormat(
            String(localized: "%1$@ of %2$@"),
            formattedTime(current),
            formattedTime(duration)
        )
    }
}

extension NotebookEditorReplayStatus {
    var localizedMessage: String {
        switch self {
        case .preparation(.controllerUnavailable):
            String(localized: "Note Replay is unavailable for this notebook.")
        case .preparation(.unsupportedPage):
            String(localized: "Note Replay supports notebook, whiteboard, and imported pages.")
        case .preparation(.pendingWritesCouldNotBeFlushed):
            String(localized: "Save pending changes before starting Note Replay.")
        case .controller(.sessionUnavailable):
            String(localized: "The Replay recording is unavailable.")
        case .controller(.historicalReplayUnavailable):
            String(localized: "This recording cannot be replayed safely.")
        case .controller(.invalidSessionOrTimeline):
            String(localized: "This recording cannot be replayed safely.")
        case .controller(.noEligiblePages):
            String(localized: "This recording has no replayable pages.")
        case .controller(.audioTransportUnavailable):
            String(localized: "Replay audio is unavailable.")
        case .controller(.audioStoppedUnexpectedly):
            String(localized: "Replay audio stopped unexpectedly.")
        case .page(.inkUnavailable):
            String(localized: "Ink is unavailable for this Replay page.")
        case .page(.inkTooLarge):
            String(localized: "This page is too large to animate safely.")
        case .page(.renderingUnavailable):
            String(localized: "This Replay page could not be rendered.")
        case .page(.rendererFallback):
            String(localized: "Replay is showing the authoritative static drawing for this page.")
        case .page(.cacheBudgetExceeded):
            String(localized: "Replay cache is full; this page is shown safely without animation.")
        case .page(.timelineMarkUnavailable):
            String(localized: "No recorded timeline point is available for this page.")
        case .page(.historicalSceneUnavailable):
            String(localized: "This Replay page could not be rendered.")
        }
    }
}
