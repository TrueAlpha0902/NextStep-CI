import ImageIO
import NotesCore
import PDFKit
import SwiftUI
import UIKit

/// Keeps paper templates visually stable as the same logical page is shown at
/// canvas, thumbnail, and export sizes. The 768-point reference width matches
/// the app's standard notebook page, so larger whiteboards do not accidentally
/// create thousands of extra grid marks merely because their coordinate space
/// is larger.
struct PageTemplateLayout: Equatable {
    static let referencePageWidth: CGFloat = 768
    static let maximumAxisMarkCount = 2_048
    static let maximumDotMarkCount = 10_000

    let bounds: CGRect
    let spacing: CGFloat
    let margin: CGFloat
    let lineWidth: CGFloat
    let dotRadius: CGFloat

    init(
        bounds: CGRect,
        minimumVisibleLineWidth: CGFloat = 0,
        minimumVisibleDotRadius: CGFloat = 0
    ) {
        self.bounds = bounds
        let normalizedWidth = Self.normalizedDimension(bounds.width)
        let patternScale = normalizedWidth / Self.referencePageWidth
        spacing = max(28 * patternScale, .ulpOfOne)
        margin = 54 * patternScale
        lineWidth = max(patternScale, minimumVisibleLineWidth)
        dotRadius = max(1.25 * patternScale, minimumVisibleDotRadius)
    }

    var ruledLineCount: Int {
        axisCount(
            start: bounds.minY + margin,
            limit: bounds.maxY - margin / 2
        )
    }

    var gridColumnCount: Int {
        axisCount(
            start: bounds.minX + margin,
            limit: bounds.maxX - margin / 2
        )
    }

    var gridRowCount: Int {
        axisCount(start: bounds.minY, limit: bounds.maxY)
    }

    var dotColumnCount: Int { gridColumnCount }
    var dotRowCount: Int { ruledLineCount }

    var dotMarkCount: Int {
        min(Self.maximumDotMarkCount, dotColumnCount * dotRowCount)
    }

    private func axisCount(start: CGFloat, limit: CGFloat) -> Int {
        guard start.isFinite,
              limit.isFinite,
              spacing.isFinite,
              spacing > 0,
              limit > start else { return 0 }
        let quotient = ceil((limit - start) / spacing)
        guard quotient.isFinite,
              quotient < CGFloat(Self.maximumAxisMarkCount) else {
            return Self.maximumAxisMarkCount
        }
        let rawCount = Int(quotient)
        return min(max(rawCount, 0), Self.maximumAxisMarkCount)
    }

    private static func normalizedDimension(_ value: CGFloat) -> CGFloat {
        guard value.isFinite, value > 0 else { return 1 }
        return value
    }
}

/// ImageIO downsamples imported image backgrounds during decoding. Loading the
/// original with `UIImage(contentsOfFile:)` can otherwise allocate the source's
/// full pixel buffer even though the canvas and PDF only need a bounded preview.
@MainActor
enum PageAssetImageLoader {
    static let maximumPixelDimension: CGFloat = 4_096

    static func thumbnail(
        at url: URL,
        maximumPixelDimension: CGFloat = 4_096
    ) -> UIImage? {
        guard maximumPixelDimension.isFinite, maximumPixelDimension > 0 else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        return thumbnail(from: source, maximumPixelDimension: maximumPixelDimension)
    }

    static func thumbnail(
        data: Data,
        maximumPixelDimension: CGFloat = 4_096
    ) -> UIImage? {
        guard data.count <= NotebookExportReadLimits.maximumCanvasAssetSourceBytes,
              maximumPixelDimension.isFinite,
              maximumPixelDimension > 0 else { return nil }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        return thumbnail(from: source, maximumPixelDimension: maximumPixelDimension)
    }

    private static func thumbnail(
        from source: CGImageSource,
        maximumPixelDimension: CGFloat
    ) -> UIImage? {
        let boundedDimension = min(
            max(maximumPixelDimension.rounded(.up), 1),
            PageAssetImageLoader.maximumPixelDimension
        )
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(boundedDimension),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else { return nil }
        return UIImage(cgImage: image)
    }
}

final class PageBackgroundUIView: UIView {
    private var background: PageBackground = .paper(.blank)
    private var renderedImage: UIImage?
    private var representedKey = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .white
        contentMode = .redraw
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with resolvedBackground: ResolvedPageBackground) {
        background = resolvedBackground.background
        let nextKey = "\(resolvedBackground.background)-\(resolvedBackground.assetURL?.path ?? "")"
        guard representedKey != nextKey else { return }
        representedKey = nextKey
        renderedImage = Self.loadImage(for: resolvedBackground)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        UIColor.white.setFill()
        context.fill(bounds)

        if let renderedImage {
            renderedImage.draw(in: aspectFitRect(for: renderedImage.size, inside: bounds))
            return
        }

        guard case let .paper(template) = background else { return }
        let displayScale = max(window?.screen.scale ?? UIScreen.main.scale, 1)
        let layout = PageTemplateLayout(
            bounds: bounds,
            minimumVisibleLineWidth: 1 / displayScale,
            minimumVisibleDotRadius: 0.5 / displayScale
        )
        context.setLineWidth(layout.lineWidth)
        context.setStrokeColor(UIColor.systemGray4.cgColor)
        context.setFillColor(UIColor.systemGray3.cgColor)

        switch template {
        case .blank:
            break
        case .ruled:
            for row in 0 ..< layout.ruledLineCount {
                let y = bounds.minY + layout.margin + CGFloat(row) * layout.spacing
                context.move(to: CGPoint(x: bounds.minX + layout.margin, y: y))
                context.addLine(to: CGPoint(x: bounds.maxX - layout.margin, y: y))
            }
            context.strokePath()
        case .grid:
            for column in 0 ..< layout.gridColumnCount {
                let x = bounds.minX + layout.margin + CGFloat(column) * layout.spacing
                context.move(to: CGPoint(x: x, y: bounds.minY))
                context.addLine(to: CGPoint(x: x, y: bounds.maxY))
            }
            for row in 0 ..< layout.gridRowCount {
                let y = bounds.minY + CGFloat(row) * layout.spacing
                context.move(to: CGPoint(x: bounds.minX, y: y))
                context.addLine(to: CGPoint(x: bounds.maxX, y: y))
            }
            context.strokePath()
        case .dots:
            var marksDrawn = 0
            dotRows: for row in 0 ..< layout.dotRowCount {
                let y = bounds.minY + layout.margin + CGFloat(row) * layout.spacing
                for column in 0 ..< layout.dotColumnCount {
                    guard marksDrawn < PageTemplateLayout.maximumDotMarkCount else {
                        break dotRows
                    }
                    let x = bounds.minX + layout.margin + CGFloat(column) * layout.spacing
                    context.fillEllipse(in: CGRect(
                        x: x - layout.dotRadius,
                        y: y - layout.dotRadius,
                        width: layout.dotRadius * 2,
                        height: layout.dotRadius * 2
                    ))
                    marksDrawn += 1
                }
            }
        }
    }

    private static func loadImage(for resolvedBackground: ResolvedPageBackground) -> UIImage? {
        guard let assetURL = resolvedBackground.assetURL else { return nil }
        switch resolvedBackground.background {
        case .paper:
            return nil
        case let .pdf(_, pageIndex):
            guard let page = PDFDocument(url: assetURL)?.page(at: pageIndex) else { return nil }
            return page.thumbnail(of: CGSize(width: 1_536, height: 2_048), for: .mediaBox)
        case .image:
            return PageAssetImageLoader.thumbnail(at: assetURL)
        }
    }

    private func aspectFitRect(for contentSize: CGSize, inside rect: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0 else { return rect }
        let scale = min(rect.width / contentSize.width, rect.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}

struct PageBackgroundPreview: UIViewRepresentable {
    var resolvedBackground: ResolvedPageBackground

    func makeUIView(context: Context) -> PageBackgroundUIView {
        PageBackgroundUIView()
    }

    func updateUIView(_ uiView: PageBackgroundUIView, context: Context) {
        uiView.configure(with: resolvedBackground)
    }
}
