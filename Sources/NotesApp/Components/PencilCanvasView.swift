import PencilKit
import SwiftUI
import UIKit

struct PencilCanvasView: UIViewRepresentable {
    let pageID: UUID
    let pageSize: CGSize
    let resolvedBackground: ResolvedPageBackground
    let drawingData: Data?
    let drawingRevision: UUID
    let tool: DrawingTool
    let inkColor: InkColor
    let lineWidth: CGFloat
    let fingerDrawingEnabled: Bool
    let showsSystemToolPicker: Bool
    let command: CanvasCommandRequest?
    let onDrawingChanged: (Data) -> Void
    /// A semantic edit boundary used by Note Replay. PencilKit may emit many
    /// drawing-change callbacks during one stroke; this fires once when the
    /// active tool gesture (or an explicit canvas command) finishes.
    let onDrawingCommitted: (Data) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ZoomingCanvasSurface {
        let surface = ZoomingCanvasSurface()
        context.coordinator.attach(to: surface)
        context.coordinator.apply(self, to: surface)
        return surface
    }

    func updateUIView(_ uiView: ZoomingCanvasSurface, context: Context) {
        context.coordinator.apply(self, to: uiView)
    }

    static func dismantleUIView(_ uiView: ZoomingCanvasSurface, coordinator: Coordinator) {
        coordinator.detach(from: uiView)
    }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        private let toolPicker = PKToolPicker()
        private var loadedPageID: UUID?
        private var loadedDrawingRevision: UUID?
        private var lastCommandID: UUID?
        private var drawingChangedHandler: ((Data) -> Void)?
        private var drawingCommittedHandler: ((Data) -> Void)?
        private var isApplyingExternalDrawing = false

        func attach(to surface: ZoomingCanvasSurface) {
            surface.canvasView.delegate = self
            toolPicker.addObserver(surface.canvasView)
        }

        func detach(from surface: ZoomingCanvasSurface) {
            toolPicker.removeObserver(surface.canvasView)
            surface.canvasView.delegate = nil
        }

        func apply(_ configuration: PencilCanvasView, to surface: ZoomingCanvasSurface) {
            drawingChangedHandler = configuration.onDrawingChanged
            drawingCommittedHandler = configuration.onDrawingCommitted
            surface.setPageSize(configuration.pageSize)
            surface.backgroundView.configure(with: configuration.resolvedBackground)
            surface.canvasView.drawingPolicy = configuration.fingerDrawingEnabled ? .anyInput : .pencilOnly
            surface.setFingerDrawingEnabled(configuration.fingerDrawingEnabled)
            surface.canvasView.tool = makeTool(for: configuration)

            let pageChanged = loadedPageID != configuration.pageID
            let drawingChangedExternally = loadedDrawingRevision != configuration.drawingRevision
            if pageChanged || drawingChangedExternally {
                loadedPageID = configuration.pageID
                loadedDrawingRevision = configuration.drawingRevision
                isApplyingExternalDrawing = true
                if let drawingData = configuration.drawingData,
                   let drawing = try? PKDrawing(data: drawingData) {
                    surface.canvasView.drawing = drawing
                } else {
                    surface.canvasView.drawing = PKDrawing()
                }
                isApplyingExternalDrawing = false
                if pageChanged { surface.resetZoom() }
            }

            if lastCommandID != configuration.command?.id {
                lastCommandID = configuration.command?.id
                switch configuration.command?.command {
                case .undo:
                    surface.canvasView.undoManager?.undo()
                    drawingCommittedHandler?(
                        surface.canvasView.drawing.dataRepresentation()
                    )
                case .redo:
                    surface.canvasView.undoManager?.redo()
                    drawingCommittedHandler?(
                        surface.canvasView.drawing.dataRepresentation()
                    )
                case .clear:
                    surface.canvasView.drawing = PKDrawing()
                    let data = surface.canvasView.drawing.dataRepresentation()
                    drawingChangedHandler?(data)
                    drawingCommittedHandler?(data)
                case nil: break
                }
            }

            toolPicker.setVisible(configuration.showsSystemToolPicker, forFirstResponder: surface.canvasView)
            if configuration.showsSystemToolPicker {
                surface.canvasView.becomeFirstResponder()
            }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isApplyingExternalDrawing else { return }
            drawingChangedHandler?(canvasView.drawing.dataRepresentation())
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            guard !isApplyingExternalDrawing else { return }
            drawingCommittedHandler?(canvasView.drawing.dataRepresentation())
        }

        private func makeTool(for configuration: PencilCanvasView) -> PKTool {
            switch configuration.tool {
            case .pen:
                PKInkingTool(.pen, color: configuration.inkColor.uiColor, width: configuration.lineWidth)
            case .highlighter:
                PKInkingTool(.marker, color: configuration.inkColor.uiColor.withAlphaComponent(0.45), width: max(configuration.lineWidth * 4, 12))
            case .eraser:
                PKEraserTool(.vector)
            case .lasso:
                PKLassoTool()
            }
        }
    }
}

@MainActor
final class ZoomingCanvasSurface: UIView, UIScrollViewDelegate {
    let scrollView = UIScrollView()
    let pageView = UIView()
    let backgroundView = PageBackgroundUIView()
    let canvasView = PKCanvasView()

    private var pageSize = CGSize(width: 768, height: 1_024)
    private var needsInitialZoom = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground

        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.keyboardDismissMode = .onDrag
        addSubview(scrollView)

        pageView.backgroundColor = .white
        pageView.layer.shadowColor = UIColor.black.cgColor
        pageView.layer.shadowOpacity = 0.14
        pageView.layer.shadowRadius = 10
        pageView.layer.shadowOffset = CGSize(width: 0, height: 4)
        scrollView.addSubview(pageView)

        backgroundView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pageView.addSubview(backgroundView)

        canvasView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.isScrollEnabled = false
        canvasView.minimumZoomScale = 1
        canvasView.maximumZoomScale = 1
        canvasView.accessibilityIdentifier = "notebook.canvas"
        canvasView.accessibilityLabel = String(localized: "Drawing canvas")
        pageView.addSubview(canvasView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        pageView.bounds = CGRect(origin: .zero, size: pageSize)
        pageView.center = CGPoint(x: pageSize.width / 2, y: pageSize.height / 2)
        backgroundView.frame = pageView.bounds
        canvasView.frame = pageView.bounds
        scrollView.contentSize = pageSize

        guard needsInitialZoom, bounds.width > 0, bounds.height > 0 else {
            centerPage()
            return
        }
        needsInitialZoom = false
        let availableWidth = max(bounds.width - 48, 1)
        let availableHeight = max(bounds.height - 48, 1)
        let fitScale = min(availableWidth / pageSize.width, availableHeight / pageSize.height)
        scrollView.minimumZoomScale = max(min(fitScale * 0.55, 1), 0.1)
        scrollView.maximumZoomScale = max(4, fitScale * 4)
        scrollView.zoomScale = min(max(fitScale, scrollView.minimumZoomScale), scrollView.maximumZoomScale)
        centerPage()
    }

    func setPageSize(_ size: CGSize) {
        let normalized = CGSize(width: max(size.width, 1), height: max(size.height, 1))
        guard normalized != pageSize else { return }
        pageSize = normalized
        needsInitialZoom = true
        setNeedsLayout()
    }

    func setFingerDrawingEnabled(_ enabled: Bool) {
        scrollView.panGestureRecognizer.minimumNumberOfTouches = enabled ? 2 : 1
    }

    func resetZoom() {
        needsInitialZoom = true
        setNeedsLayout()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        pageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerPage()
    }

    private func centerPage() {
        let horizontalInset = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
        let verticalInset = max((scrollView.bounds.height - scrollView.contentSize.height) / 2, 0)
        scrollView.contentInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
    }
}

private extension InkColor {
    var uiColor: UIColor {
        switch self {
        case .black: .black
        case .blue: .systemBlue
        case .red: .systemRed
        case .green: .systemGreen
        }
    }
}
