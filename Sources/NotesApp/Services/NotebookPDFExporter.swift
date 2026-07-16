import CoreGraphics
import Foundation
import NotesCore
import UIKit

/// Immutable page material captured after the editor has flushed its pending writes.
///
/// The image resolver is deliberately page-scoped. Two imported pages may reference the same
/// asset identifier in different notebook packages, so a whole-notebook exporter must never use
/// one global asset namespace.
@MainActor
struct NotebookPDFPageSnapshot {
    let page: EditorPage
    let background: ResolvedPageBackground
    let preparedBackground: PageExportPreparedBackground?
    let drawingData: Data?
    let preparedDrawing: PageExportPreparedDrawing?
    let canvasElements: [CanvasElement]
    let assetImageResolver: CanvasElementExportImageResolver

    init(
        page: EditorPage,
        background: ResolvedPageBackground,
        preparedBackground: PageExportPreparedBackground? = nil,
        drawingData: Data?,
        preparedDrawing: PageExportPreparedDrawing? = nil,
        canvasElements: [CanvasElement] = [],
        assetImageResolver: @escaping CanvasElementExportImageResolver = { _, _ in nil }
    ) {
        self.page = page
        self.background = background
        self.preparedBackground = preparedBackground
        self.drawingData = drawingData
        self.preparedDrawing = preparedDrawing
        self.canvasElements = canvasElements
        self.assetImageResolver = assetImageResolver
    }
}

enum NotebookPDFExportError: LocalizedError, Equatable {
    case emptyNotebook
    case pageLimitExceeded(limit: Int)
    case unsupportedPageKind(pageIndex: Int, kind: PageKind)
    case invalidPageDimensions(pageIndex: Int)
    case backgroundAssetUnavailable(pageIndex: Int)
    case backgroundAssetLimitExceeded(pageIndex: Int, limit: Int)
    case corruptBackgroundAsset(pageIndex: Int)
    case backgroundPDFPageOutOfRange(pageIndex: Int, backgroundPageIndex: Int)
    case drawingDataLimitExceeded(pageIndex: Int, limit: Int)
    case corruptDrawingData(pageIndex: Int)
    case drawingComplexityLimitExceeded(
        pageIndex: Int,
        maximumStrokeCount: Int,
        maximumPointCount: Int
    )
    case pageElementLimitExceeded(pageIndex: Int, limit: Int)
    case totalPageAreaLimitExceeded
    case drawingRasterWorkLimitExceeded
    case structuredElementWorkLimitExceeded
    case artifactStorageLimitExceeded
    case insufficientStorage
    case invalidRenderedArtifact(pageIndex: Int)
    case invalidDestination

    var errorDescription: String? {
        switch self {
        case .emptyNotebook:
            String(localized: "This notebook has no pages to export.")
        case .pageLimitExceeded:
            String(localized: "This notebook has too many pages to export as one PDF.")
        case .unsupportedPageKind(let pageIndex, _):
            String.localizedStringWithFormat(
                String(localized: "Page %lld cannot be included in a notebook PDF."),
                Int64(pageIndex + 1)
            )
        case .invalidPageDimensions(let pageIndex):
            String.localizedStringWithFormat(
                String(localized: "Page %lld has invalid dimensions for PDF export."),
                Int64(pageIndex + 1)
            )
        case .backgroundAssetUnavailable(let pageIndex):
            String.localizedStringWithFormat(
                String(localized: "The background file on page %lld is missing or unsafe."),
                Int64(pageIndex + 1)
            )
        case .backgroundAssetLimitExceeded(let pageIndex, let limit):
            String.localizedStringWithFormat(
                String(localized: "The background file on page %1$lld exceeds the %2$lld MB PDF export limit."),
                Int64(pageIndex + 1),
                Int64(limit / 1_024 / 1_024)
            )
        case .corruptBackgroundAsset(let pageIndex):
            String.localizedStringWithFormat(
                String(localized: "The background file on page %lld is damaged or unsupported."),
                Int64(pageIndex + 1)
            )
        case .backgroundPDFPageOutOfRange(let pageIndex, _):
            String.localizedStringWithFormat(
                String(localized: "The selected PDF background for page %lld is unavailable."),
                Int64(pageIndex + 1)
            )
        case .drawingDataLimitExceeded(let pageIndex, let limit):
            String.localizedStringWithFormat(
                String(localized: "The ink on page %1$lld exceeds the %2$lld MB PDF export limit."),
                Int64(pageIndex + 1),
                Int64(limit / 1_024 / 1_024)
            )
        case .corruptDrawingData(let pageIndex):
            String.localizedStringWithFormat(
                String(localized: "The ink data on page %lld is damaged and cannot be exported."),
                Int64(pageIndex + 1)
            )
        case .drawingComplexityLimitExceeded(let pageIndex, _, _):
            String.localizedStringWithFormat(
                String(localized: "The ink on page %lld is too complex to export safely."),
                Int64(pageIndex + 1)
            )
        case .pageElementLimitExceeded(let pageIndex, let limit):
            String.localizedStringWithFormat(
                String(localized: "Page %1$lld has more than %2$lld elements and cannot be exported."),
                Int64(pageIndex + 1),
                Int64(limit)
            )
        case .totalPageAreaLimitExceeded,
             .drawingRasterWorkLimitExceeded,
             .structuredElementWorkLimitExceeded,
             .artifactStorageLimitExceeded:
            String(localized: "This notebook PDF is too large to export safely.")
        case .insufficientStorage:
            String(localized: "There is not enough free space to export this notebook PDF.")
        case .invalidRenderedArtifact(let pageIndex):
            String.localizedStringWithFormat(
                String(localized: "Temporary PDF page %lld could not be verified."),
                Int64(pageIndex + 1)
            )
        case .invalidDestination:
            String(localized: "The PDF export destination is not safe.")
        }
    }
}

fileprivate final class NotebookPDFAssetWorkBudget {
    var remainingAttempts: Int
    var remainingDecodedBytes: Int

    init(remainingAttempts: Int, remainingDecodedBytes: Int) {
        self.remainingAttempts = remainingAttempts
        self.remainingDecodedBytes = remainingDecodedBytes
    }
}

fileprivate struct NotebookPDFPreparationTotals {
    var pdfPointArea = 0.0
    var drawingRasterBytes = 0
    var elementCount = 0
}

@MainActor
fileprivate struct NotebookPDFPreparedPageContent {
    let plan: PageExportRenderPlan
    let background: PageExportPreparedBackground
    let drawing: PageExportPreparedDrawing
}

fileprivate struct NotebookPDFArtifactRect: Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init?(_ rect: CGRect) {
        let rect = rect.standardized
        let values = [rect.origin.x, rect.origin.y, rect.width, rect.height]
        guard values.allSatisfy(\.isFinite), rect.width > 0, rect.height > 0 else {
            return nil
        }
        x = Double(rect.origin.x)
        y = Double(rect.origin.y)
        width = Double(rect.width)
        height = Double(rect.height)
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

fileprivate struct NotebookPDFLinkArtifact: Sendable {
    let destination: String
    let bounds: NotebookPDFArtifactRect
}

fileprivate struct NotebookPDFPageArtifact: Sendable {
    let pageIndex: Int
    let fileURL: URL
    let byteCount: Int64
    let mediaBox: NotebookPDFArtifactRect
    let links: [NotebookPDFLinkArtifact]
}

fileprivate struct NotebookPDFFileManagerBox: @unchecked Sendable {
    let value: FileManager
}

struct NotebookPDFArtifactBudget: Sendable {
    let maximumPageBytes: Int64
    let maximumTotalBytes: Int64
    let maximumMergedOutputGrowthBytes: Int64
    let minimumFreeBytes: Int64
    let maximumLinkCount: Int
    let maximumLinkURLBytes: Int

    static let standard = NotebookPDFArtifactBudget(
        maximumPageBytes: 256 * 1_024 * 1_024,
        maximumTotalBytes: 2 * 1_024 * 1_024 * 1_024,
        maximumMergedOutputGrowthBytes: 64 * 1_024 * 1_024,
        minimumFreeBytes: 64 * 1_024 * 1_024,
        maximumLinkCount: 100_000,
        maximumLinkURLBytes: 64 * 1_024 * 1_024
    )

    func maximumMergedOutputBytes(forArtifactBytes artifactBytes: Int64) throws -> Int64 {
        guard artifactBytes >= 0,
              artifactBytes <= maximumTotalBytes,
              maximumMergedOutputGrowthBytes >= 0,
              maximumTotalBytes > 0 else {
            throw NotebookPDFExportError.artifactStorageLimitExceeded
        }
        let bytesWithGrowth: Int64
        if artifactBytes > maximumTotalBytes - min(
            maximumMergedOutputGrowthBytes,
            maximumTotalBytes
        ) {
            bytesWithGrowth = maximumTotalBytes
        } else {
            bytesWithGrowth = artifactBytes + maximumMergedOutputGrowthBytes
        }
        return min(bytesWithGrowth, maximumTotalBytes)
    }

    func requiredFreeBytesForMerge(artifactBytes: Int64) throws -> Int64 {
        let maximumOutputBytes = try maximumMergedOutputBytes(
            forArtifactBytes: artifactBytes
        )
        guard minimumFreeBytes >= 0,
              maximumOutputBytes <= Int64.max - minimumFreeBytes else {
            throw NotebookPDFExportError.artifactStorageLimitExceeded
        }
        return maximumOutputBytes + minimumFreeBytes
    }
}

/// Internal deterministic hook used to verify cancellation after the detached merge has begun.
/// Production callers use `.none`; the closure must remain fast and nonblocking.
struct NotebookPDFMergeHooks: Sendable {
    let afterPage: @Sendable (Int) -> Void

    init(afterPage: @escaping @Sendable (Int) -> Void = { _ in }) {
        self.afterPage = afterPage
    }

    static let none = NotebookPDFMergeHooks()
}

/// Main-actor page renderer for the cancellable whole-notebook path.
///
/// It never retains a page snapshot after `append` returns. Each bounded single-page PDF is
/// immediately persisted inside a protected private artifact directory. `finish` transfers only
/// compact Sendable file/geometry descriptors to the detached Core Graphics merge worker.
@MainActor
final class NotebookPDFArtifactWriter {
    private let expectedPageCount: Int
    private let destination: URL
    private let artifactDirectory: URL
    private let fileManager: FileManager
    private let artifactBudget: NotebookPDFArtifactBudget
    private let assetBudget: NotebookPDFAssetWorkBudget
    private var preparationTotals = NotebookPDFPreparationTotals()
    private var artifacts = [NotebookPDFPageArtifact]()
    private var totalArtifactBytes: Int64 = 0
    private var totalLinkCount = 0
    private var totalLinkURLBytes = 0
    private var handedOffToMergeWorker = false

    fileprivate init(
        expectedPageCount: Int,
        destination: URL,
        fileManager: FileManager,
        artifactBudget: NotebookPDFArtifactBudget = .standard
    ) throws {
        guard expectedPageCount > 0 else { throw NotebookPDFExportError.emptyNotebook }
        guard expectedPageCount <= NotebookPDFExporter.maximumPageCount else {
            throw NotebookPDFExportError.pageLimitExceeded(
                limit: NotebookPDFExporter.maximumPageCount
            )
        }
        self.expectedPageCount = expectedPageCount
        self.fileManager = fileManager
        guard artifactBudget.maximumPageBytes > 0,
              artifactBudget.maximumTotalBytes >= artifactBudget.maximumPageBytes,
              artifactBudget.maximumMergedOutputGrowthBytes >= 0,
              artifactBudget.minimumFreeBytes >= 0,
              artifactBudget.maximumLinkCount >= 0,
              artifactBudget.maximumLinkURLBytes >= 0 else {
            throw NotebookPDFExportError.artifactStorageLimitExceeded
        }
        self.artifactBudget = artifactBudget
        assetBudget = NotebookPDFAssetWorkBudget(
            remainingAttempts: NotebookPDFExporter.maximumTotalAssetResolutionAttempts,
            remainingDecodedBytes: NotebookPDFExporter.maximumTotalAssetDecodedBytes
        )

        let safeDestination = try NotebookPDFExporter.safeDestination(
            destination,
            fileManager: fileManager
        )
        self.destination = safeDestination
        let artifactDirectory = safeDestination.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(UUID().uuidString).notes-pdf-artifacts",
                isDirectory: true
            )
        guard !NotebookPDFExporter.itemExistsIncludingSymbolicLink(
            artifactDirectory,
            fileManager: fileManager
        ) else {
            throw NotebookPDFExportError.invalidDestination
        }
        try NotebookPDFExporter.requireAvailableCapacity(
            at: safeDestination.deletingLastPathComponent(),
            bytes: artifactBudget.maximumPageBytes,
            reserve: artifactBudget.minimumFreeBytes,
            fileManager: fileManager
        )
        do {
            try fileManager.createDirectory(
                at: artifactDirectory,
                withIntermediateDirectories: false,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            guard (try? fileManager.destinationOfSymbolicLink(
                atPath: artifactDirectory.path
            )) == nil,
            let attributes = try? fileManager.attributesOfItem(
                atPath: artifactDirectory.path
            ),
            attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw NotebookPDFExportError.invalidDestination
            }
        } catch {
            try? fileManager.removeItem(at: artifactDirectory)
            throw error
        }
        self.artifactDirectory = artifactDirectory
    }

    var renderedPageCount: Int { artifacts.count }
    var totalPageCount: Int { expectedPageCount }

    func append(_ snapshot: NotebookPDFPageSnapshot) throws {
        guard !handedOffToMergeWorker,
              artifacts.count < expectedPageCount else {
            throw NotebookPDFExportError.invalidRenderedArtifact(pageIndex: artifacts.count)
        }
        try Task.checkCancellation()
        let pageIndex = artifacts.count
        let preparedContent = try NotebookPDFExporter.preparePage(
            snapshot,
            pageIndex: pageIndex,
            totals: &preparationTotals
        )
        let plan = preparedContent.plan
        try Task.checkCancellation()
        let artifactURL = artifactDirectory.appendingPathComponent(
            String(format: "page-%06d.pdf", pageIndex),
            isDirectory: false
        )
        try NotebookPDFExporter.requireAvailableCapacity(
            at: artifactDirectory,
            bytes: artifactBudget.maximumPageBytes,
            reserve: artifactBudget.minimumFreeBytes,
            fileManager: fileManager
        )
        guard !NotebookPDFExporter.itemExistsIncludingSymbolicLink(
            artifactURL,
            fileManager: fileManager
        ) else {
            throw NotebookPDFExportError.invalidRenderedArtifact(pageIndex: pageIndex)
        }

        let renderer = UIGraphicsPDFRenderer(bounds: plan.pdfBounds)
        let resolver = NotebookPDFExporter.budgetedResolver(
            snapshot.assetImageResolver,
            budget: assetBudget
        )
        let maximumPageLinkCount = min(
            artifactBudget.maximumLinkCount - totalLinkCount,
            CanvasElementExportRenderer.maximumElementCount
        )
        let maximumPageLinkURLBytes = min(
            artifactBudget.maximumLinkURLBytes - totalLinkURLBytes,
            NotebookPDFExporter.maximumLinkURLBytesPerPage
        )
        var links = [NotebookPDFLinkArtifact]()
        var linkURLBytes = 0
        var linkBudgetExceeded = false
        try autoreleasepool {
            try renderer.writePDF(to: artifactURL) { context in
                context.beginPage(withBounds: plan.pdfBounds, pageInfo: [:])
                PageExportRenderer.drawPDFPageContent(
                    preparedBackground: preparedContent.background,
                    preparedDrawing: preparedContent.drawing,
                    canvasElements: snapshot.canvasElements,
                    plan: plan,
                    context: context,
                    assetImageResolver: resolver,
                    linkAnnotationObserver: { url, rect in
                        guard let safeURL = NotebookPDFExporter.safeHTTPURL(
                            url.absoluteString
                        ),
                        let bounds = NotebookPDFArtifactRect(rect) else { return }
                        let destination = safeURL.absoluteString
                        let destinationBytes = destination.utf8.count
                        guard links.count < maximumPageLinkCount,
                              destinationBytes <= maximumPageLinkURLBytes,
                              linkURLBytes <= maximumPageLinkURLBytes - destinationBytes else {
                            linkBudgetExceeded = true
                            return
                        }
                        links.append(NotebookPDFLinkArtifact(
                            destination: destination,
                            bounds: bounds
                        ))
                        linkURLBytes += destinationBytes
                    }
                )
            }
        }
        try Task.checkCancellation()
        guard !linkBudgetExceeded else {
            throw NotebookPDFExportError.artifactStorageLimitExceeded
        }
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: artifactURL.path
        )
        try Task.checkCancellation()
        let artifactBytes = try NotebookPDFExporter.regularFileSize(
            at: artifactURL,
            fileManager: fileManager
        )
        guard artifactBytes > 0,
              artifactBytes <= artifactBudget.maximumPageBytes,
              totalArtifactBytes <= artifactBudget.maximumTotalBytes - artifactBytes else {
            throw NotebookPDFExportError.artifactStorageLimitExceeded
        }
        let artifact = try NotebookPDFExporter.validateRenderedArtifact(
            at: artifactURL,
            pageIndex: pageIndex,
            byteCount: artifactBytes,
            expectedMediaBox: plan.pdfBounds,
            links: links
        )
        guard artifact.links.count <= artifactBudget.maximumLinkCount,
              linkURLBytes <= artifactBudget.maximumLinkURLBytes,
              totalLinkCount <= artifactBudget.maximumLinkCount - artifact.links.count,
              totalLinkURLBytes <= artifactBudget.maximumLinkURLBytes - linkURLBytes else {
            throw NotebookPDFExportError.artifactStorageLimitExceeded
        }
        totalArtifactBytes += artifactBytes
        totalLinkCount += artifact.links.count
        totalLinkURLBytes += linkURLBytes
        artifacts.append(artifact)
    }

    func finish(
        progress: @escaping @MainActor (Int) -> Void = { _ in },
        mergeHooks: NotebookPDFMergeHooks = .none
    ) async throws -> URL {
        guard !handedOffToMergeWorker,
              artifacts.count == expectedPageCount else {
            throw NotebookPDFExportError.invalidRenderedArtifact(pageIndex: artifacts.count)
        }
        try Task.checkCancellation()
        guard try NotebookPDFExporter.validateArtifactDirectory(
            artifactDirectory,
            artifacts: artifacts,
            fileManager: fileManager
        ) == totalArtifactBytes else {
            throw NotebookPDFExportError.artifactStorageLimitExceeded
        }
        let maximumOutputBytes = try artifactBudget.maximumMergedOutputBytes(
            forArtifactBytes: totalArtifactBytes
        )
        _ = try artifactBudget.requiredFreeBytesForMerge(
            artifactBytes: totalArtifactBytes
        )
        try NotebookPDFExporter.requireAvailableCapacity(
            at: destination.deletingLastPathComponent(),
            bytes: maximumOutputBytes,
            reserve: artifactBudget.minimumFreeBytes,
            fileManager: fileManager
        )
        handedOffToMergeWorker = true
        return try await NotebookPDFExporter.mergeArtifacts(
            artifacts,
            artifactDirectory: artifactDirectory,
            destination: destination,
            fileManager: fileManager,
            artifactBudget: artifactBudget,
            expectedArtifactBytes: totalArtifactBytes,
            maximumOutputBytes: maximumOutputBytes,
            progress: progress,
            hooks: mergeHooks
        )
    }

    /// Removes page artifacts if collection/rendering ends before ownership is handed to merge.
    func abort() {
        guard !handedOffToMergeWorker else { return }
        try? fileManager.removeItem(at: artifactDirectory)
    }
}

/// Writes a flattened, heterogeneous notebook to a protected PDF.
///
/// `writePDF` remains the synchronous compatibility path. Interactive export uses
/// `NotebookPDFArtifactWriter`: UIKit renders one bounded page on the main actor, then a detached
/// Core Graphics worker copies those vector page artifacts into one file-backed PDF without ever
/// constructing an in-memory whole-document `Data`, `PDFDocument`, or `[PDFPage]`.
@MainActor
enum NotebookPDFExporter {
    static let maximumPageCount = 2_000
    static let maximumSourcePageDimension = 100_000.0
    static let maximumTotalPDFPointArea = 2_500_000_000.0
    static let maximumTotalDrawingRasterBytes = 8 * 1_024 * 1_024 * 1_024
    static let maximumTotalStructuredElementCount = 500_000
    static let maximumTotalAssetResolutionAttempts = 4_096
    static let maximumTotalAssetDecodedBytes = 512 * 1_024 * 1_024
    static let maximumLinkURLBytesPerPage = 8 * 1_024 * 1_024

    private struct PreparedPage {
        let snapshot: NotebookPDFPageSnapshot
        let plan: PageExportRenderPlan
        let background: PageExportPreparedBackground
        let drawing: PageExportPreparedDrawing
    }

    /// Creates a protected, uniquely named PDF in Notes' temporary export directory.
    static func temporaryPDF(
        title: String,
        notebookID: UUID,
        pages: [NotebookPDFPageSnapshot],
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination = temporaryDestination(
            title: title,
            notebookID: notebookID,
            fileManager: fileManager
        )
        try writePDF(pages: pages, to: destination, fileManager: fileManager)
        return destination
    }

    static func makeArtifactWriter(
        title: String,
        notebookID: UUID,
        expectedPageCount: Int,
        fileManager: FileManager = .default,
        artifactBudget: NotebookPDFArtifactBudget = .standard
    ) throws -> NotebookPDFArtifactWriter {
        try NotebookPDFArtifactWriter(
            expectedPageCount: expectedPageCount,
            destination: temporaryDestination(
                title: title,
                notebookID: notebookID,
                fileManager: fileManager
            ),
            fileManager: fileManager,
            artifactBudget: artifactBudget
        )
    }

    /// Cooperative array-based convenience retained for service tests and non-streaming callers.
    /// The editor uses `makeArtifactWriter` directly so each source snapshot is discarded after
    /// its page artifact is written.
    static func cancellableTemporaryPDF(
        title: String,
        notebookID: UUID,
        pages: [NotebookPDFPageSnapshot],
        fileManager: FileManager = .default,
        progress: @escaping @MainActor (Int, Int) -> Void = { _, _ in }
    ) async throws -> URL {
        let destination = temporaryDestination(
            title: title,
            notebookID: notebookID,
            fileManager: fileManager
        )
        try await writeCancellablePDF(
            pages: pages,
            to: destination,
            fileManager: fileManager,
            progress: progress
        )
        return destination
    }

    /// Renders one protected page artifact at a time, then performs the file-backed merge off the
    /// main actor. Progress has two units per page plus one verified-publication unit.
    static func writeCancellablePDF(
        pages: [NotebookPDFPageSnapshot],
        to destination: URL,
        fileManager: FileManager = .default,
        progress: @escaping @MainActor (Int, Int) -> Void = { _, _ in },
        mergeHooks: NotebookPDFMergeHooks = .none,
        artifactBudget: NotebookPDFArtifactBudget = .standard
    ) async throws {
        let writer = try NotebookPDFArtifactWriter(
            expectedPageCount: pages.count,
            destination: destination,
            fileManager: fileManager,
            artifactBudget: artifactBudget
        )
        defer { writer.abort() }
        let totalUnits = pages.count * 2 + 1
        progress(0, totalUnits)
        await Task.yield()
        try Task.checkCancellation()

        for (index, snapshot) in pages.enumerated() {
            try Task.checkCancellation()
            try writer.append(snapshot)
            progress(index + 1, totalUnits)
            await Task.yield()
            try Task.checkCancellation()
        }

        let publishedURL = try await writer.finish(
            progress: { mergedPageCount in
                progress(pages.count + mergedPageCount, totalUnits)
            },
            mergeHooks: mergeHooks
        )
        guard !Task.isCancelled else {
            try? fileManager.removeItem(at: publishedURL)
            throw CancellationError()
        }
        progress(totalUnits, totalUnits)
        guard !Task.isCancelled else {
            try? fileManager.removeItem(at: publishedURL)
            throw CancellationError()
        }
    }

    /// Renders to a sibling partial file and atomically publishes it at `destination`.
    /// `destination` must not already exist, which prevents an export from replacing unrelated
    /// user data when a caller accidentally reuses a URL. This synchronous compatibility API is
    /// intentionally preserved; interactive UI uses the cancellable artifact path above.
    static func writePDF(
        pages: [NotebookPDFPageSnapshot],
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        let prepared = try prepare(pages)
        let safeDestination = try safeDestination(destination, fileManager: fileManager)
        try Task.checkCancellation()
        let partialURL = safeDestination.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString).notes-pdf-partial",
            isDirectory: false
        )
        var published = false
        defer {
            if !published {
                try? fileManager.removeItem(at: partialURL)
            }
        }

        let renderer = UIGraphicsPDFRenderer(bounds: prepared[0].plan.pdfBounds)
        let assetBudget = NotebookPDFAssetWorkBudget(
            remainingAttempts: maximumTotalAssetResolutionAttempts,
            remainingDecodedBytes: maximumTotalAssetDecodedBytes
        )
        var cancellationDetected = false
        try autoreleasepool {
            try renderer.writePDF(to: partialURL) { context in
                for preparedPage in prepared {
                    guard !Task.isCancelled else {
                        cancellationDetected = true
                        break
                    }
                    autoreleasepool {
                        context.beginPage(
                            withBounds: preparedPage.plan.pdfBounds,
                            pageInfo: [:]
                        )
                        let resolver = budgetedResolver(
                            preparedPage.snapshot.assetImageResolver,
                            budget: assetBudget
                        )
                        PageExportRenderer.drawPDFPageContent(
                            preparedBackground: preparedPage.background,
                            preparedDrawing: preparedPage.drawing,
                            canvasElements: preparedPage.snapshot.canvasElements,
                            plan: preparedPage.plan,
                            context: context,
                            assetImageResolver: resolver
                        )
                    }
                    if Task.isCancelled {
                        cancellationDetected = true
                        break
                    }
                }
            }
        }

        guard !cancellationDetected else { throw CancellationError() }
        try Task.checkCancellation()
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: partialURL.path
        )
        try Task.checkCancellation()
        try fileManager.moveItem(at: partialURL, to: safeDestination)
        published = true
    }

    fileprivate static func preparePage(
        _ snapshot: NotebookPDFPageSnapshot,
        pageIndex: Int,
        totals: inout NotebookPDFPreparationTotals
    ) throws -> NotebookPDFPreparedPageContent {
        if Task.isCancelled { throw CancellationError() }
        switch snapshot.page.kind {
        case .notebook, .whiteboard, .importedDocument:
            break
        case .textDocument, .studySet:
            throw NotebookPDFExportError.unsupportedPageKind(
                pageIndex: pageIndex,
                kind: snapshot.page.kind
            )
        }
        guard snapshot.page.width.isFinite,
              snapshot.page.height.isFinite,
              snapshot.page.width > 0,
              snapshot.page.height > 0,
              snapshot.page.width <= maximumSourcePageDimension,
              snapshot.page.height <= maximumSourcePageDimension else {
            throw NotebookPDFExportError.invalidPageDimensions(pageIndex: pageIndex)
        }
        guard snapshot.canvasElements.count <= CanvasElementExportRenderer.maximumElementCount else {
            throw NotebookPDFExportError.pageElementLimitExceeded(
                pageIndex: pageIndex,
                limit: CanvasElementExportRenderer.maximumElementCount
            )
        }

        let plan = PageExportRenderer.renderPlan(for: snapshot.page)
        let preparedBackground: PageExportPreparedBackground
        do {
            if let background = snapshot.preparedBackground {
                guard background.sourceBackground == snapshot.page.background,
                      snapshot.background.background == snapshot.page.background else {
                    throw PageExportRenderError.backgroundAssetUnavailable
                }
                preparedBackground = background
            } else {
                preparedBackground = try PageExportRenderer.prepareBackground(
                    snapshot.background,
                    for: snapshot.page,
                    outputPixelSize: plan.drawingRasterPixelSize
                )
            }
        } catch let error as PageExportRenderError {
            switch error {
            case .backgroundAssetUnavailable:
                throw NotebookPDFExportError.backgroundAssetUnavailable(pageIndex: pageIndex)
            case .backgroundAssetLimitExceeded(let limit):
                throw NotebookPDFExportError.backgroundAssetLimitExceeded(
                    pageIndex: pageIndex,
                    limit: limit
                )
            case .corruptBackgroundAsset:
                throw NotebookPDFExportError.corruptBackgroundAsset(pageIndex: pageIndex)
            case .backgroundPDFPageOutOfRange(let backgroundPageIndex):
                throw NotebookPDFExportError.backgroundPDFPageOutOfRange(
                    pageIndex: pageIndex,
                    backgroundPageIndex: backgroundPageIndex
                )
            case .drawingDataLimitExceeded,
                 .corruptDrawingData,
                 .drawingComplexityLimitExceeded,
                 .pageElementLimitExceeded:
                throw error
            }
        }
        try Task.checkCancellation()
        let preparedDrawing: PageExportPreparedDrawing
        do {
            preparedDrawing = if let drawing = snapshot.preparedDrawing {
                drawing
            } else {
                try PageExportRenderer.prepareDrawing(snapshot.drawingData)
            }
        } catch let error as PageExportRenderError {
            switch error {
            case .drawingDataLimitExceeded(let limit):
                throw NotebookPDFExportError.drawingDataLimitExceeded(
                    pageIndex: pageIndex,
                    limit: limit
                )
            case .corruptDrawingData:
                throw NotebookPDFExportError.corruptDrawingData(pageIndex: pageIndex)
            case .drawingComplexityLimitExceeded(
                let maximumStrokeCount,
                let maximumPointCount
            ):
                throw NotebookPDFExportError.drawingComplexityLimitExceeded(
                    pageIndex: pageIndex,
                    maximumStrokeCount: maximumStrokeCount,
                    maximumPointCount: maximumPointCount
                )
            case .pageElementLimitExceeded(let limit):
                throw NotebookPDFExportError.pageElementLimitExceeded(
                    pageIndex: pageIndex,
                    limit: limit
                )
            case .backgroundAssetUnavailable:
                throw NotebookPDFExportError.backgroundAssetUnavailable(pageIndex: pageIndex)
            case .backgroundAssetLimitExceeded(let limit):
                throw NotebookPDFExportError.backgroundAssetLimitExceeded(
                    pageIndex: pageIndex,
                    limit: limit
                )
            case .corruptBackgroundAsset:
                throw NotebookPDFExportError.corruptBackgroundAsset(pageIndex: pageIndex)
            case .backgroundPDFPageOutOfRange(let backgroundPageIndex):
                throw NotebookPDFExportError.backgroundPDFPageOutOfRange(
                    pageIndex: pageIndex,
                    backgroundPageIndex: backgroundPageIndex
                )
            }
        }
        try Task.checkCancellation()
        let pageArea = Double(plan.pdfBounds.width) * Double(plan.pdfBounds.height)
        guard pageArea.isFinite,
              totals.pdfPointArea <= maximumTotalPDFPointArea - pageArea else {
            throw NotebookPDFExportError.totalPageAreaLimitExceeded
        }
        totals.pdfPointArea += pageArea

        if !preparedDrawing.isEmpty {
            guard totals.drawingRasterBytes <= maximumTotalDrawingRasterBytes
                    - plan.estimatedDrawingRasterBytes else {
                throw NotebookPDFExportError.drawingRasterWorkLimitExceeded
            }
            totals.drawingRasterBytes += plan.estimatedDrawingRasterBytes
        }

        guard totals.elementCount <= maximumTotalStructuredElementCount
                - snapshot.canvasElements.count else {
            throw NotebookPDFExportError.structuredElementWorkLimitExceeded
        }
        totals.elementCount += snapshot.canvasElements.count
        return NotebookPDFPreparedPageContent(
            plan: plan,
            background: preparedBackground,
            drawing: preparedDrawing
        )
    }

    private static func prepare(_ pages: [NotebookPDFPageSnapshot]) throws -> [PreparedPage] {
        guard !pages.isEmpty else { throw NotebookPDFExportError.emptyNotebook }
        guard pages.count <= maximumPageCount else {
            throw NotebookPDFExportError.pageLimitExceeded(limit: maximumPageCount)
        }
        var totals = NotebookPDFPreparationTotals()
        var prepared = [PreparedPage]()
        prepared.reserveCapacity(pages.count)
        for (index, snapshot) in pages.enumerated() {
            let content = try preparePage(snapshot, pageIndex: index, totals: &totals)
            prepared.append(PreparedPage(
                snapshot: snapshot,
                plan: content.plan,
                background: content.background,
                drawing: content.drawing
            ))
        }
        return prepared
    }

    fileprivate static func validateRenderedArtifact(
        at artifactURL: URL,
        pageIndex: Int,
        byteCount: Int64,
        expectedMediaBox: CGRect,
        links: [NotebookPDFLinkArtifact]
    ) throws -> NotebookPDFPageArtifact {
        guard let document = CGPDFDocument(artifactURL as CFURL),
              document.numberOfPages == 1,
              let page = document.page(at: 1) else {
            throw NotebookPDFExportError.invalidRenderedArtifact(pageIndex: pageIndex)
        }
        let mediaBox = page.getBoxRect(.mediaBox).standardized
        guard approximatelyEqual(mediaBox, expectedMediaBox),
              let mediaMetadata = NotebookPDFArtifactRect(mediaBox) else {
            throw NotebookPDFExportError.invalidRenderedArtifact(pageIndex: pageIndex)
        }
        return NotebookPDFPageArtifact(
            pageIndex: pageIndex,
            fileURL: artifactURL,
            byteCount: byteCount,
            mediaBox: mediaMetadata,
            links: links
        )
    }

    fileprivate static func mergeArtifacts(
        _ artifacts: [NotebookPDFPageArtifact],
        artifactDirectory: URL,
        destination: URL,
        fileManager: FileManager,
        artifactBudget: NotebookPDFArtifactBudget,
        expectedArtifactBytes: Int64,
        maximumOutputBytes: Int64,
        progress: @escaping @MainActor (Int) -> Void,
        hooks: NotebookPDFMergeHooks
    ) async throws -> URL {
        let streamPair = AsyncStream<Int>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let continuation = streamPair.continuation
        let fileManagerBox = NotebookPDFFileManagerBox(value: fileManager)
        let mergeTask = Task.detached(priority: .userInitiated) {
            defer { continuation.finish() }
            return try mergeArtifactsOnWorker(
                artifacts,
                artifactDirectory: artifactDirectory,
                destination: destination,
                fileManager: fileManagerBox.value,
                artifactBudget: artifactBudget,
                expectedArtifactBytes: expectedArtifactBytes,
                maximumOutputBytes: maximumOutputBytes,
                progress: { _ = continuation.yield($0) },
                hooks: hooks
            )
        }

        return try await withTaskCancellationHandler {
            for await mergedPageCount in streamPair.stream {
                if Task.isCancelled {
                    mergeTask.cancel()
                    break
                }
                progress(mergedPageCount)
            }

            do {
                let publishedURL = try await mergeTask.value
                guard !Task.isCancelled else {
                    try? fileManager.removeItem(at: publishedURL)
                    throw CancellationError()
                }
                return publishedURL
            } catch {
                throw error
            }
        } onCancel: {
            mergeTask.cancel()
            continuation.finish()
        }
    }

    nonisolated private static func mergeArtifactsOnWorker(
        _ artifacts: [NotebookPDFPageArtifact],
        artifactDirectory: URL,
        destination: URL,
        fileManager: FileManager,
        artifactBudget: NotebookPDFArtifactBudget,
        expectedArtifactBytes: Int64,
        maximumOutputBytes: Int64,
        progress: @Sendable (Int) -> Void,
        hooks: NotebookPDFMergeHooks
    ) throws -> URL {
        defer { try? fileManager.removeItem(at: artifactDirectory) }
        try Task.checkCancellation()
        let artifactDirectoryPath = artifactDirectory.standardizedFileURL
        let destinationDirectory = destination.deletingLastPathComponent().standardizedFileURL
        guard artifactDirectoryPath.deletingLastPathComponent() == destinationDirectory,
              (try? fileManager.destinationOfSymbolicLink(
                atPath: artifactDirectoryPath.path
              )) == nil,
              let artifactDirectoryAttributes = try? fileManager.attributesOfItem(
                atPath: artifactDirectoryPath.path
              ),
              artifactDirectoryAttributes[.type] as? FileAttributeType == .typeDirectory,
              artifactDirectoryPath.resolvingSymlinksInPath().standardizedFileURL
                == artifactDirectoryPath,
              !artifacts.isEmpty,
              artifacts.enumerated().allSatisfy({ offset, artifact in
                  artifact.pageIndex == offset
                      && artifact.fileURL.deletingLastPathComponent().standardizedFileURL
                        == artifactDirectoryPath
              }),
              expectedArtifactBytes <= artifactBudget.maximumTotalBytes,
              maximumOutputBytes >= expectedArtifactBytes,
              maximumOutputBytes <= artifactBudget.maximumTotalBytes,
              !itemExistsIncludingSymbolicLink(destination, fileManager: fileManager) else {
            throw NotebookPDFExportError.invalidDestination
        }
        guard try validateArtifactDirectory(
            artifactDirectoryPath,
            artifacts: artifacts,
            fileManager: fileManager
        ) == expectedArtifactBytes else {
            throw NotebookPDFExportError.artifactStorageLimitExceeded
        }

        // Keep the merge output inside the protected artifact directory until publication.
        // Moving it to the parent destination remains a same-volume atomic rename.
        let partialURL = artifactDirectoryPath.appendingPathComponent(
            ".\(UUID().uuidString).notes-pdf-partial",
            isDirectory: false
        )
        guard !itemExistsIncludingSymbolicLink(partialURL, fileManager: fileManager),
              fileManager.createFile(
            atPath: partialURL.path,
            contents: Data(),
            attributes: [.protectionKey: FileProtectionType.complete]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        var movedToDestination = false
        var completedSuccessfully = false
        defer {
            try? fileManager.removeItem(at: partialURL)
            if movedToDestination && !completedSuccessfully {
                try? fileManager.removeItem(at: destination)
            }
        }

        try writeMergedArtifacts(
            artifacts,
            artifactDirectory: artifactDirectory,
            to: partialURL,
            fileManager: fileManager,
            progress: progress,
            hooks: hooks
        )
        try Task.checkCancellation()
        let mergedBytes = try regularFileSize(at: partialURL, fileManager: fileManager)
        guard mergedBytes > 0,
              mergedBytes <= maximumOutputBytes,
              mergedBytes <= artifactBudget.maximumTotalBytes else {
            throw NotebookPDFExportError.artifactStorageLimitExceeded
        }
        try validateMergedPDF(at: partialURL, artifacts: artifacts)
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: partialURL.path
        )
        try Task.checkCancellation()
        guard !itemExistsIncludingSymbolicLink(destination, fileManager: fileManager) else {
            throw NotebookPDFExportError.invalidDestination
        }
        try fileManager.moveItem(at: partialURL, to: destination)
        movedToDestination = true
        try Task.checkCancellation()
        completedSuccessfully = true
        return destination
    }

    nonisolated private static func writeMergedArtifacts(
        _ artifacts: [NotebookPDFPageArtifact],
        artifactDirectory: URL,
        to partialURL: URL,
        fileManager: FileManager,
        progress: @Sendable (Int) -> Void,
        hooks: NotebookPDFMergeHooks
    ) throws {
        guard let output = CGContext(partialURL as CFURL, mediaBox: nil, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { output.closePDF() }

        for (offset, artifact) in artifacts.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                guard artifact.fileURL.deletingLastPathComponent().standardizedFileURL
                        == artifactDirectory.standardizedFileURL,
                      (try? fileManager.destinationOfSymbolicLink(
                        atPath: artifact.fileURL.path
                      )) == nil,
                      let attributes = try? fileManager.attributesOfItem(
                        atPath: artifact.fileURL.path
                      ),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.size] as? NSNumber)?.int64Value == artifact.byteCount,
                      let source = CGPDFDocument(artifact.fileURL as CFURL),
                      source.numberOfPages == 1,
                      let sourcePage = source.page(at: 1),
                      approximatelyEqual(
                        sourcePage.getBoxRect(.mediaBox),
                        artifact.mediaBox.cgRect
                      ) else {
                    throw NotebookPDFExportError.invalidRenderedArtifact(
                        pageIndex: artifact.pageIndex
                    )
                }
                var mediaBox = artifact.mediaBox.cgRect
                let mediaBoxData = withUnsafeBytes(of: &mediaBox) { Data($0) } as CFData
                let pageInfo = [
                    kCGPDFContextMediaBox as String: mediaBoxData,
                ] as CFDictionary
                output.beginPDFPage(pageInfo)
                output.saveGState()
                output.drawPDFPage(sourcePage)
                output.restoreGState()
                for link in artifact.links {
                    guard let destination = safeHTTPURL(link.destination) else { continue }
                    let bounds = link.bounds.cgRect.intersection(mediaBox)
                    guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { continue }
                    output.setURL(destination as CFURL, for: bounds)
                }
                output.endPDFPage()
            }
            hooks.afterPage(offset + 1)
            try Task.checkCancellation()
            progress(offset + 1)
        }
    }

    nonisolated fileprivate static func requireAvailableCapacity(
        at directory: URL,
        bytes: Int64,
        reserve: Int64,
        fileManager: FileManager
    ) throws {
        guard bytes >= 0, reserve >= 0, bytes <= Int64.max - reserve else {
            throw NotebookPDFExportError.insufficientStorage
        }
        let required = bytes + reserve
        let values = try? directory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        let legacyCapacity: Int64?
        if let values, let available = values.volumeAvailableCapacity {
            legacyCapacity = Int64(available)
        } else {
            legacyCapacity = nil
        }
        let resourceCapacity = values?.volumeAvailableCapacityForImportantUsage
            ?? legacyCapacity
        let fileSystemAttributes = try? fileManager.attributesOfFileSystem(
            forPath: directory.path
        )
        let fileSystemCapacity = (fileSystemAttributes?[.systemFreeSize] as? NSNumber)?
            .int64Value
        guard let available = resourceCapacity ?? fileSystemCapacity,
              available >= required else {
            throw NotebookPDFExportError.insufficientStorage
        }
    }

    nonisolated fileprivate static func regularFileSize(
        at url: URL,
        fileManager: FileManager
    ) throws -> Int64 {
        guard (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size >= 0 else {
            throw NotebookPDFExportError.invalidDestination
        }
        return size
    }

    nonisolated fileprivate static func validateArtifactDirectory(
        _ directory: URL,
        artifacts: [NotebookPDFPageArtifact],
        fileManager: FileManager
    ) throws -> Int64 {
        let entries = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        let expectedPaths = Set(artifacts.map { $0.fileURL.standardizedFileURL.path })
        guard entries.count == artifacts.count,
              Set(entries.map { $0.standardizedFileURL.path }) == expectedPaths else {
            throw NotebookPDFExportError.invalidDestination
        }
        var total: Int64 = 0
        for artifact in artifacts {
            try Task.checkCancellation()
            let size = try regularFileSize(at: artifact.fileURL, fileManager: fileManager)
            guard size == artifact.byteCount,
                  total <= Int64.max - size else {
                throw NotebookPDFExportError.artifactStorageLimitExceeded
            }
            total += size
        }
        return total
    }

    nonisolated private static func validateMergedPDF(
        at url: URL,
        artifacts: [NotebookPDFPageArtifact]
    ) throws {
        try Task.checkCancellation()
        guard let document = CGPDFDocument(url as CFURL),
              document.numberOfPages == artifacts.count else {
            throw CocoaError(.fileWriteUnknown)
        }
        for (index, artifact) in artifacts.enumerated() {
            try Task.checkCancellation()
            guard let page = document.page(at: index + 1),
                  approximatelyEqual(
                    page.getBoxRect(.mediaBox),
                    artifact.mediaBox.cgRect
                  ) else {
                throw NotebookPDFExportError.invalidRenderedArtifact(pageIndex: index)
            }
        }
    }

    fileprivate static func safeDestination(
        _ destination: URL,
        fileManager: FileManager
    ) throws -> URL {
        guard destination.isFileURL,
              !destination.lastPathComponent.isEmpty,
              destination.lastPathComponent != ".",
              destination.lastPathComponent != ".." else {
            throw NotebookPDFExportError.invalidDestination
        }
        let directory = destination.deletingLastPathComponent().standardizedFileURL
        let safeDirectory = try ensureSafeDestinationDirectory(
            directory,
            fileManager: fileManager
        )
        let safeDestination = safeDirectory.appendingPathComponent(
            destination.lastPathComponent,
            isDirectory: false
        )
        guard !itemExistsIncludingSymbolicLink(safeDestination, fileManager: fileManager) else {
            throw NotebookPDFExportError.invalidDestination
        }
        return safeDestination
    }

    /// Restricts the generic writer to the app's temporary tree, then walks every descendant
    /// component without following links. Resolving the trusted root once deliberately permits
    /// iOS' system `/var` -> `/private/var` alias while still rejecting caller-controlled links
    /// below the container's temporary directory.
    nonisolated private static func ensureSafeDestinationDirectory(
        _ directory: URL,
        fileManager: FileManager
    ) throws -> URL {
        let rawRoot = fileManager.temporaryDirectory.standardizedFileURL
        let trustedRoot = rawRoot.resolvingSymlinksInPath().standardizedFileURL
        let rawDirectory = directory.standardizedFileURL
        let relativeComponents = relativePathComponents(from: rawRoot, to: rawDirectory)
            ?? relativePathComponents(from: trustedRoot, to: rawDirectory)
        guard let relativeComponents else {
            throw NotebookPDFExportError.invalidDestination
        }

        var current = trustedRoot
        for component in relativeComponents {
            guard component != ".", component != "..", !component.isEmpty else {
                throw NotebookPDFExportError.invalidDestination
            }
            current.appendPathComponent(component, isDirectory: true)
            guard (try? fileManager.destinationOfSymbolicLink(atPath: current.path)) == nil else {
                throw NotebookPDFExportError.invalidDestination
            }
            if let attributes = try? fileManager.attributesOfItem(atPath: current.path) {
                guard attributes[.type] as? FileAttributeType == .typeDirectory,
                      (try? fileManager.destinationOfSymbolicLink(
                        atPath: current.path
                      )) == nil else {
                    throw NotebookPDFExportError.invalidDestination
                }
            } else {
                try fileManager.createDirectory(
                    at: current,
                    withIntermediateDirectories: false,
                    attributes: [.protectionKey: FileProtectionType.complete]
                )
                guard (try? fileManager.destinationOfSymbolicLink(atPath: current.path)) == nil,
                      let attributes = try? fileManager.attributesOfItem(atPath: current.path),
                      attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw NotebookPDFExportError.invalidDestination
                }
            }
        }
        let resolvedCurrentPath = current.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedCurrentPath == current.standardizedFileURL.path else {
            throw NotebookPDFExportError.invalidDestination
        }
        return current
    }

    nonisolated private static func relativePathComponents(
        from root: URL,
        to descendant: URL
    ) -> [String]? {
        let rootComponents = root.standardizedFileURL.pathComponents
        let descendantComponents = descendant.standardizedFileURL.pathComponents
        guard descendantComponents.count >= rootComponents.count,
              Array(descendantComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        return Array(descendantComponents.dropFirst(rootComponents.count))
    }

    nonisolated fileprivate static func itemExistsIncludingSymbolicLink(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
            || (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    fileprivate static func budgetedResolver(
        _ resolver: @escaping CanvasElementExportImageResolver,
        budget: NotebookPDFAssetWorkBudget
    ) -> CanvasElementExportImageResolver {
        { assetID, request in
            guard !Task.isCancelled,
                  budget.remainingAttempts > 0,
                  budget.remainingDecodedBytes >= 4 else { return nil }
            budget.remainingAttempts -= 1

            let limitedRequest = CanvasElementExportImageRequest(
                frameSize: request.targetPixelSize,
                rasterScale: 1,
                maximumDecodedBytes: min(
                    request.maximumDecodedBytes,
                    budget.remainingDecodedBytes
                )
            )
            guard let image = resolver(assetID, limitedRequest),
                  limitedRequest.accepts(image),
                  let decodedBytes = limitedRequest.decodedByteCount(of: image),
                  decodedBytes <= budget.remainingDecodedBytes else { return nil }
            budget.remainingDecodedBytes -= decodedBytes
            return image
        }
    }

    nonisolated fileprivate static func safeHTTPURL(_ rawValue: String) -> URL? {
        guard (rawValue as NSString).length <= 4_096,
              let url = URL(string: rawValue),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty else { return nil }
        return url
    }

    nonisolated private static func approximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect
    ) -> Bool {
        let tolerance: CGFloat = 0.5
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func temporaryDestination(
        title: String,
        notebookID: UUID,
        fileManager: FileManager
    ) -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("NotesExports", isDirectory: true)
        let filename = sanitizedFilename(title)
        return directory.appendingPathComponent(
            "\(filename)-\(notebookID.uuidString.prefix(8))-\(UUID().uuidString.prefix(8)).pdf",
            isDirectory: false
        )
    }

    private static func sanitizedFilename(_ title: String) -> String {
        let invalid = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "-_ "))
            .inverted
        let safe = title.components(separatedBy: invalid).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { return "NextStep Notebook" }

        // APFS limits one filename component to 255 UTF-8 bytes. Preserve whole grapheme
        // clusters and leave ample room for the two UUID suffixes plus the extension.
        let maximumTitleBytes = 180
        var result = ""
        var usedBytes = 0
        for character in safe {
            let characterBytes = String(character).utf8.count
            guard characterBytes <= maximumTitleBytes - usedBytes else { break }
            result.append(character)
            usedBytes += characterBytes
        }
        return result.isEmpty ? "NextStep Notebook" : result
    }
}
