import NotesCore
import PDFKit
import PencilKit
import UIKit
import XCTest
@testable import NotesApp

final class NotebookPDFExporterTests: XCTestCase {
    @MainActor
    func testCancellableExportWritesHeterogeneousPagesInOrderWithMediaBoxesContentInkAssetsAndLinks() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let importedBackgroundData = try XCTUnwrap(
            solidImage(color: .systemGreen, size: CGSize(width: 40, height: 20)).pngData()
        )

        let notebookURL = try XCTUnwrap(URL(string: "https://example.com/notebook"))
        let whiteboardURL = try XCTUnwrap(URL(string: "https://example.com/whiteboard"))
        let unsafeURL = try XCTUnwrap(URL(string: "file:///private/notes-secret"))
        let firstAssetID = AssetID(String(repeating: "1", count: 64))
        let secondAssetID = AssetID(String(repeating: "2", count: 64))
        var resolvedAssets = [AssetID]()

        let notebookPage = EditorPage(
            kind: .notebook,
            background: .paper(.blank),
            width: 200,
            height: 300
        )
        let whiteboardPage = EditorPage(
            kind: .whiteboard,
            background: .paper(.dots),
            width: EditorPage.whiteboardWidth,
            height: EditorPage.whiteboardHeight
        )
        let importedPage = EditorPage(
            kind: .importedDocument,
            background: .image(assetPath: "assets/imported.png"),
            width: 400,
            height: 200
        )
        let snapshots = [
            NotebookPDFPageSnapshot(
                page: notebookPage,
                background: ResolvedPageBackground(
                    background: notebookPage.background,
                    assetURL: nil
                ),
                drawingData: inkDrawingData(),
                canvasElements: [
                    textElement("Notebook marker", frame: CanvasRect(
                        x: 10, y: 10, width: 180, height: 40
                    )),
                    imageElement(firstAssetID, frame: CanvasRect(
                        x: 150, y: 10, width: 30, height: 30
                    )),
                    linkElement(notebookURL, frame: CanvasRect(
                        x: 10, y: 220, width: 100, height: 40
                    )),
                    linkElement(unsafeURL, frame: CanvasRect(
                        x: 120, y: 220, width: 60, height: 40
                    )),
                ],
                assetImageResolver: { assetID, request in
                    resolvedAssets.append(assetID)
                    let image = self.solidImage(color: .systemRed, size: CGSize(width: 16, height: 16))
                    return request.accepts(image) ? image : nil
                }
            ),
            NotebookPDFPageSnapshot(
                page: whiteboardPage,
                background: ResolvedPageBackground(
                    background: whiteboardPage.background,
                    assetURL: nil
                ),
                drawingData: nil,
                canvasElements: [
                    textElement("Whiteboard marker", frame: CanvasRect(
                        x: 200, y: 200, width: 800, height: 300
                    )),
                    imageElement(secondAssetID, frame: CanvasRect(
                        x: 2_700, y: 100, width: 300, height: 300
                    )),
                    linkElement(whiteboardURL, frame: CanvasRect(
                        x: 200, y: 1_800, width: 800, height: 300
                    )),
                ],
                assetImageResolver: { assetID, request in
                    resolvedAssets.append(assetID)
                    let image = self.solidImage(color: .systemBlue, size: CGSize(width: 16, height: 16))
                    return request.accepts(image) ? image : nil
                }
            ),
            NotebookPDFPageSnapshot(
                page: importedPage,
                background: ResolvedPageBackground(
                    background: importedPage.background,
                    assetURL: nil,
                    assetData: importedBackgroundData
                ),
                drawingData: nil,
                canvasElements: [
                    textElement("Imported marker", frame: CanvasRect(
                        x: 10, y: 10, width: 150, height: 40
                    )),
                ]
            ),
        ]
        let destination = directory.appendingPathComponent("whole-notebook.pdf")
        var progress = [(completed: Int, total: Int)]()

        try await NotebookPDFExporter.writeCancellablePDF(
            pages: snapshots,
            to: destination,
            progress: { progress.append(($0, $1)) }
        )

        XCTAssertEqual(resolvedAssets, [firstAssetID, secondAssetID])
        XCTAssertEqual(progress.first?.completed, 0)
        XCTAssertEqual(progress.last?.completed, 7)
        XCTAssertTrue(progress.allSatisfy { $0.total == 7 })
        let completedProgress = progress.map { $0.completed }
        XCTAssertEqual(completedProgress, completedProgress.sorted())
        let document = try XCTUnwrap(PDFDocument(url: destination))
        XCTAssertEqual(document.pageCount, 3)
        let notebookPDFPage = try XCTUnwrap(document.page(at: 0))
        let whiteboardPDFPage = try XCTUnwrap(document.page(at: 1))
        let importedPDFPage = try XCTUnwrap(document.page(at: 2))
        XCTAssertEqual(notebookPDFPage.bounds(for: .mediaBox).width, 200, accuracy: 0.5)
        XCTAssertEqual(notebookPDFPage.bounds(for: .mediaBox).height, 300, accuracy: 0.5)
        XCTAssertEqual(whiteboardPDFPage.bounds(for: .mediaBox).width, 1_440, accuracy: 0.5)
        XCTAssertEqual(whiteboardPDFPage.bounds(for: .mediaBox).height, 1_080, accuracy: 0.5)
        XCTAssertEqual(importedPDFPage.bounds(for: .mediaBox).width, 400, accuracy: 0.5)
        XCTAssertEqual(importedPDFPage.bounds(for: .mediaBox).height, 200, accuracy: 0.5)
        XCTAssertTrue(notebookPDFPage.string?.contains("Notebook marker") == true)
        XCTAssertTrue(whiteboardPDFPage.string?.contains("Whiteboard marker") == true)
        XCTAssertTrue(importedPDFPage.string?.contains("Imported marker") == true)
        XCTAssertEqual(linkURLs(on: notebookPDFPage), [notebookURL])
        XCTAssertEqual(linkURLs(on: whiteboardPDFPage), [whiteboardURL])
        XCTAssertEqual(linkURLs(on: importedPDFPage), [])
        let notebookLinkBounds = try XCTUnwrap(linkBounds(for: notebookURL, on: notebookPDFPage))
        XCTAssertEqual(notebookLinkBounds.origin.x, 10, accuracy: 0.5)
        XCTAssertEqual(notebookLinkBounds.origin.y, 40, accuracy: 0.5)
        XCTAssertEqual(notebookLinkBounds.width, 100, accuracy: 0.5)
        XCTAssertEqual(notebookLinkBounds.height, 40, accuracy: 0.5)
        let whiteboardLinkBounds = try XCTUnwrap(
            linkBounds(for: whiteboardURL, on: whiteboardPDFPage)
        )
        XCTAssertEqual(whiteboardLinkBounds.origin.x, 90, accuracy: 0.5)
        XCTAssertEqual(whiteboardLinkBounds.origin.y, 135, accuracy: 0.5)
        XCTAssertEqual(whiteboardLinkBounds.width, 360, accuracy: 0.5)
        XCTAssertEqual(whiteboardLinkBounds.height, 135, accuracy: 0.5)

        let notebookThumbnail = notebookPDFPage.thumbnail(
            of: notebookPDFPage.bounds(for: .mediaBox).size,
            for: .mediaBox
        )
        let inkPixel = try pixel(in: notebookThumbnail, x: 100, y: 150)
        XCTAssertLessThan(inkPixel.red, 0.45)
        XCTAssertLessThan(inkPixel.green, 0.45)
        XCTAssertLessThan(inkPixel.blue, 0.45)
        let localAssetPixel = try pixel(in: notebookThumbnail, x: 165, y: 25)
        XCTAssertGreaterThan(localAssetPixel.red, localAssetPixel.green)
        XCTAssertGreaterThan(localAssetPixel.red, localAssetPixel.blue)
        let importedThumbnail = importedPDFPage.thumbnail(
            of: importedPDFPage.bounds(for: .mediaBox).size,
            for: .mediaBox
        )
        let importedPixel = try pixel(in: importedThumbnail, x: 300, y: 100)
        XCTAssertGreaterThan(importedPixel.green, importedPixel.red)
        XCTAssertGreaterThan(importedPixel.green, importedPixel.blue)
        XCTAssertTrue(try exportWorkFiles(in: directory).isEmpty)
    }

    @MainActor
    func testWholeNotebookPreservesSelectedPDFBackgroundAsSearchableVectorContent() throws {
        let sourceBounds = CGRect(x: 0, y: 0, width: 240, height: 120)
        let sourcePDF = UIGraphicsPDFRenderer(bounds: sourceBounds).pdfData { context in
            context.beginPage()
            NSAttributedString(
                string: "UNSELECTED PDF BACKGROUND",
                attributes: [.font: UIFont.systemFont(ofSize: 18)]
            ).draw(at: CGPoint(x: 12, y: 40))
            context.beginPage()
            NSAttributedString(
                string: "SELECTED VECTOR BACKGROUND MARKER",
                attributes: [.font: UIFont.systemFont(ofSize: 10)]
            ).draw(at: CGPoint(x: 12, y: 40))
        }
        let page = EditorPage(
            kind: .importedDocument,
            background: .pdf(assetPath: "assets/source.pdf", pageIndex: 1),
            width: 480,
            height: 240
        )
        let snapshot = NotebookPDFPageSnapshot(
            page: page,
            background: ResolvedPageBackground(
                background: page.background,
                assetURL: nil,
                assetData: sourcePDF
            ),
            drawingData: nil
        )
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("vector-background.pdf")

        try NotebookPDFExporter.writePDF(pages: [snapshot], to: destination)

        let document = try XCTUnwrap(PDFDocument(url: destination))
        let exportedPage = try XCTUnwrap(document.page(at: 0))
        XCTAssertEqual(exportedPage.bounds(for: .mediaBox).width, 480, accuracy: 0.5)
        XCTAssertEqual(exportedPage.bounds(for: .mediaBox).height, 240, accuracy: 0.5)
        XCTAssertTrue(exportedPage.string?.contains("SELECTED VECTOR BACKGROUND MARKER") == true)
        XCTAssertFalse(exportedPage.string?.contains("UNSELECTED PDF BACKGROUND") == true)
    }

    @MainActor
    func testRejectsEmptyPathologicalCountAndInvalidDimensionsBeforeCreatingOutput() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("invalid.pdf")

        XCTAssertThrowsError(try NotebookPDFExporter.writePDF(pages: [], to: destination)) { error in
            XCTAssertEqual(error as? NotebookPDFExportError, .emptyNotebook)
        }

        let page = EditorPage(width: 200, height: 300)
        let snapshot = NotebookPDFPageSnapshot(
            page: page,
            background: ResolvedPageBackground(background: page.background, assetURL: nil),
            drawingData: nil
        )
        let pathological = Array(
            repeating: snapshot,
            count: NotebookPDFExporter.maximumPageCount + 1
        )
        XCTAssertThrowsError(
            try NotebookPDFExporter.writePDF(pages: pathological, to: destination)
        ) { error in
            XCTAssertEqual(
                error as? NotebookPDFExportError,
                .pageLimitExceeded(limit: NotebookPDFExporter.maximumPageCount)
            )
        }

        let corruptPage = EditorPage(width: .infinity, height: 300)
        let corrupt = NotebookPDFPageSnapshot(
            page: corruptPage,
            background: ResolvedPageBackground(
                background: corruptPage.background,
                assetURL: nil
            ),
            drawingData: nil
        )
        XCTAssertThrowsError(
            try NotebookPDFExporter.writePDF(pages: [corrupt], to: destination)
        ) { error in
            XCTAssertEqual(
                error as? NotebookPDFExportError,
                .invalidPageDimensions(pageIndex: 0)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testTemporaryPDFBoundsLongUnicodeFilenameByUTF8Bytes() throws {
        let page = EditorPage(width: 100, height: 100)
        let snapshot = NotebookPDFPageSnapshot(
            page: page,
            background: ResolvedPageBackground(background: page.background, assetURL: nil),
            drawingData: nil
        )

        let url = try NotebookPDFExporter.temporaryPDF(
            title: String(repeating: "筆", count: 200),
            notebookID: UUID(),
            pages: [snapshot]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertLessThanOrEqual(url.lastPathComponent.utf8.count, 255)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testRejectsStructuredPageKindsUntilTheirContentSnapshotsAreSupported() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for kind in [PageKind.textDocument, .studySet] {
            let leadingPage = EditorPage(kind: .notebook, width: 200, height: 300)
            let unsupportedPage = EditorPage(kind: kind, width: 200, height: 300)
            let pages = [leadingPage, unsupportedPage].map { page in
                NotebookPDFPageSnapshot(
                    page: page,
                    background: ResolvedPageBackground(
                        background: page.background,
                        assetURL: nil
                    ),
                    drawingData: nil
                )
            }
            let destination = directory.appendingPathComponent("unsupported-\(kind.rawValue).pdf")

            XCTAssertThrowsError(
                try NotebookPDFExporter.writePDF(pages: pages, to: destination)
            ) { error in
                XCTAssertEqual(
                    error as? NotebookPDFExportError,
                    .unsupportedPageKind(pageIndex: 1, kind: kind)
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @MainActor
    func testRejectsAggregateDrawingRasterWorkBeforeRendering() throws {
        let page = EditorPage(
            kind: .whiteboard,
            background: .paper(.blank),
            width: EditorPage.whiteboardWidth,
            height: EditorPage.whiteboardHeight
        )
        let perPageBytes = PageExportRenderer.renderPlan(for: page).estimatedDrawingRasterBytes
        let pageCount = NotebookPDFExporter.maximumTotalDrawingRasterBytes / perPageBytes + 1
        XCTAssertLessThan(pageCount, NotebookPDFExporter.maximumPageCount)
        let ink = inkDrawingData()
        let snapshot = NotebookPDFPageSnapshot(
            page: page,
            background: ResolvedPageBackground(background: page.background, assetURL: nil),
            drawingData: ink,
            preparedDrawing: try PageExportRenderer.prepareDrawing(ink)
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("drawing-budget-\(UUID().uuidString).pdf")

        XCTAssertThrowsError(
            try NotebookPDFExporter.writePDF(
                pages: Array(repeating: snapshot, count: pageCount),
                to: destination
            )
        ) { error in
            XCTAssertEqual(error as? NotebookPDFExportError, .drawingRasterWorkLimitExceeded)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testExistingDestinationIsRefusedWithoutPartialFileAndIsPreserved() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("occupied.pdf")
        let sentinel = Data("existing user file".utf8)
        try sentinel.write(to: destination, options: .atomic)
        let page = EditorPage(width: 100, height: 100)
        let snapshot = NotebookPDFPageSnapshot(
            page: page,
            background: ResolvedPageBackground(background: page.background, assetURL: nil),
            drawingData: nil,
            canvasElements: [textElement(
                "Must be cleaned up",
                frame: CanvasRect(x: 10, y: 10, width: 80, height: 40)
            )]
        )

        XCTAssertThrowsError(
            try NotebookPDFExporter.writePDF(pages: [snapshot], to: destination)
        ) { error in
            XCTAssertEqual(error as? NotebookPDFExportError, .invalidDestination)
        }

        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        let partials = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasSuffix(".notes-pdf-partial") }
        XCTAssertTrue(partials.isEmpty)
    }

    @MainActor
    func testSymlinkedDestinationDirectoryIsRefusedWithoutWritingThroughIt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let realDirectory = directory.appendingPathComponent("real", isDirectory: true)
        let linkedDirectory = directory.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory,
            withDestinationURL: realDirectory
        )
        let page = EditorPage(width: 100, height: 100)
        let snapshot = NotebookPDFPageSnapshot(
            page: page,
            background: ResolvedPageBackground(background: page.background, assetURL: nil),
            drawingData: nil
        )

        XCTAssertThrowsError(
            try NotebookPDFExporter.writePDF(
                pages: [snapshot],
                to: linkedDirectory
                    .appendingPathComponent("nested", isDirectory: true)
                    .appendingPathComponent("escaped.pdf")
            )
        ) { error in
            XCTAssertEqual(error as? NotebookPDFExportError, .invalidDestination)
        }
        let escapedDirectory = realDirectory.appendingPathComponent("nested", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: escapedDirectory.appendingPathComponent("escaped.pdf").path
        ))
        let partials = ((try? FileManager.default.contentsOfDirectory(
            at: escapedDirectory,
            includingPropertiesForKeys: nil
        )) ?? []).filter { $0.lastPathComponent.hasSuffix(".notes-pdf-partial") }
        XCTAssertTrue(partials.isEmpty)
    }

    @MainActor
    func testDanglingDestinationSymlinkIsRefusedWithoutCreatingItsTarget() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missingTarget = directory.appendingPathComponent("missing-target.pdf")
        let destination = directory.appendingPathComponent("dangling.pdf")
        try FileManager.default.createSymbolicLink(
            at: destination,
            withDestinationURL: missingTarget
        )
        let page = EditorPage(width: 100, height: 100)
        let snapshot = NotebookPDFPageSnapshot(
            page: page,
            background: ResolvedPageBackground(background: page.background, assetURL: nil),
            drawingData: nil
        )

        XCTAssertThrowsError(
            try NotebookPDFExporter.writePDF(pages: [snapshot], to: destination)
        ) { error in
            XCTAssertEqual(error as? NotebookPDFExportError, .invalidDestination)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingTarget.path))
        let remainingLinkTarget = try FileManager.default.destinationOfSymbolicLink(
            atPath: destination.path
        )
        XCTAssertFalse(remainingLinkTarget.isEmpty)
    }

    @MainActor
    func testCancellationDoesNotPublishFinalOrLeavePartialFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("cancelled.pdf")
        let page = EditorPage(width: 200, height: 300)
        let assetID = AssetID(String(repeating: "3", count: 64))
        var task: Task<Void, Error>?
        let snapshot = NotebookPDFPageSnapshot(
            page: page,
            background: ResolvedPageBackground(background: page.background, assetURL: nil),
            drawingData: nil,
            canvasElements: [imageElement(
                assetID,
                frame: CanvasRect(x: 10, y: 10, width: 100, height: 40)
            )],
            assetImageResolver: { _, _ in
                // Cancellation happens after UIGraphicsPDFRenderer has created its partial file
                // and entered the page loop, exercising the cleanup path rather than preflight.
                task?.cancel()
                return nil
            }
        )
        task = Task { @MainActor in
            try await NotebookPDFExporter.writeCancellablePDF(
                pages: Array(repeating: snapshot, count: 20),
                to: destination
            )
        }
        let exportTask = try XCTUnwrap(task)

        do {
            try await exportTask.value
            XCTFail("A cancelled whole-notebook export must not succeed.")
        } catch is CancellationError {
            // Expected cooperative cancellation.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try exportWorkFiles(in: directory).isEmpty)
    }

    @MainActor
    func testCancellationDuringDetachedMergeRemovesOutputArtifactsAndPartial() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("cancelled-during-merge.pdf")
        let page = EditorPage(width: 240, height: 320)
        let snapshot = NotebookPDFPageSnapshot(
            page: page,
            background: ResolvedPageBackground(background: page.background, assetURL: nil),
            drawingData: nil,
            canvasElements: [textElement(
                "Detached merge cancellation",
                frame: CanvasRect(x: 20, y: 20, width: 180, height: 60)
            )]
        )
        let cancellation = NotebookPDFCancellationRelay()
        let task = Task { @MainActor in
            try await NotebookPDFExporter.writeCancellablePDF(
                pages: Array(repeating: snapshot, count: 8),
                to: destination,
                mergeHooks: NotebookPDFMergeHooks { mergedPageCount in
                    if mergedPageCount == 1 {
                        cancellation.cancel()
                    }
                }
            )
        }
        cancellation.install { task.cancel() }

        do {
            try await task.value
            XCTFail("A merge cancelled after its first page unexpectedly succeeded")
        } catch is CancellationError {
            // Expected. The exporter awaits detached cleanup before returning cancellation.
        }

        XCTAssertTrue(cancellation.wasInvoked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try exportWorkFiles(in: directory).isEmpty)
    }

    @MainActor
    func testArtifactByteBudgetFailureCleansPrivateDirectoryAndOutput() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("over-budget.pdf")
        let page = EditorPage(width: 100, height: 100)
        let snapshot = NotebookPDFPageSnapshot(
            page: page,
            background: ResolvedPageBackground(background: page.background, assetURL: nil),
            drawingData: nil
        )
        let tinyBudget = NotebookPDFArtifactBudget(
            maximumPageBytes: 1,
            maximumTotalBytes: 1,
            maximumMergedOutputGrowthBytes: 0,
            minimumFreeBytes: 0,
            maximumLinkCount: 1,
            maximumLinkURLBytes: 64
        )

        do {
            try await NotebookPDFExporter.writeCancellablePDF(
                pages: [snapshot],
                to: destination,
                artifactBudget: tinyBudget
            )
            XCTFail("An artifact larger than its explicit byte budget unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error as? NotebookPDFExportError, .artifactStorageLimitExceeded)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try exportWorkFiles(in: directory).isEmpty)
    }

    @MainActor
    func testWholeNotebookRejectsCorruptInkWithPageNumber() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("corrupt-ink.pdf")
        let page = EditorPage(width: 100, height: 100)
        let snapshot = NotebookPDFPageSnapshot(
            page: page,
            background: ResolvedPageBackground(background: page.background, assetURL: nil),
            drawingData: Data("not a PencilKit drawing".utf8)
        )

        XCTAssertThrowsError(
            try NotebookPDFExporter.writePDF(pages: [snapshot], to: destination)
        ) { error in
            XCTAssertEqual(
                error as? NotebookPDFExportError,
                .corruptDrawingData(pageIndex: 0)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try exportWorkFiles(in: directory).isEmpty)
    }

    @MainActor
    func testWholeNotebookRejectsTenThousandAndFirstElementInsteadOfTruncating() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("too-many-elements.pdf")
        let page = EditorPage(width: 100, height: 100)
        let element = textElement(
            "x",
            frame: CanvasRect(x: 0, y: 0, width: 10, height: 10)
        )
        let snapshot = NotebookPDFPageSnapshot(
            page: page,
            background: ResolvedPageBackground(background: page.background, assetURL: nil),
            drawingData: nil,
            canvasElements: Array(
                repeating: element,
                count: CanvasElementExportRenderer.maximumElementCount + 1
            )
        )

        XCTAssertThrowsError(
            try NotebookPDFExporter.writePDF(pages: [snapshot], to: destination)
        ) { error in
            XCTAssertEqual(
                error as? NotebookPDFExportError,
                .pageElementLimitExceeded(
                    pageIndex: 0,
                    limit: CanvasElementExportRenderer.maximumElementCount
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try exportWorkFiles(in: directory).isEmpty)
    }

    func testMergeBudgetSeparatesOutputGrowthFromFreeSpaceReserve() throws {
        let budget = NotebookPDFArtifactBudget(
            maximumPageBytes: 100,
            maximumTotalBytes: 1_000,
            maximumMergedOutputGrowthBytes: 100,
            minimumFreeBytes: 500,
            maximumLinkCount: 0,
            maximumLinkURLBytes: 0
        )
        let differentReserve = NotebookPDFArtifactBudget(
            maximumPageBytes: 100,
            maximumTotalBytes: 1_000,
            maximumMergedOutputGrowthBytes: 100,
            minimumFreeBytes: 5,
            maximumLinkCount: 0,
            maximumLinkURLBytes: 0
        )

        XCTAssertEqual(try budget.maximumMergedOutputBytes(forArtifactBytes: 700), 800)
        XCTAssertEqual(
            try differentReserve.maximumMergedOutputBytes(forArtifactBytes: 700),
            800
        )
        XCTAssertEqual(try budget.requiredFreeBytesForMerge(artifactBytes: 700), 1_300)
    }

    func testMergeBudgetCapsOutputAtMaximumTotalBeforeAddingReserve() throws {
        let budget = NotebookPDFArtifactBudget(
            maximumPageBytes: 100,
            maximumTotalBytes: 1_000,
            maximumMergedOutputGrowthBytes: 100,
            minimumFreeBytes: 500,
            maximumLinkCount: 0,
            maximumLinkURLBytes: 0
        )

        XCTAssertEqual(try budget.maximumMergedOutputBytes(forArtifactBytes: 950), 1_000)
        XCTAssertEqual(try budget.requiredFreeBytesForMerge(artifactBytes: 950), 1_500)
        XCTAssertThrowsError(
            try budget.maximumMergedOutputBytes(forArtifactBytes: 1_001)
        ) { error in
            XCTAssertEqual(error as? NotebookPDFExportError, .artifactStorageLimitExceeded)
        }
    }

    @MainActor
    func testWholeNotebookRejectsOversizedInkBeforePencilKitDecode() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("oversized-ink.pdf")
        let page = EditorPage(width: 100, height: 100)
        let snapshot = NotebookPDFPageSnapshot(
            page: page,
            background: ResolvedPageBackground(background: page.background, assetURL: nil),
            drawingData: Data(count: PageExportRenderer.maximumDrawingDataBytes + 1)
        )

        XCTAssertThrowsError(
            try NotebookPDFExporter.writePDF(pages: [snapshot], to: destination)
        ) { error in
            XCTAssertEqual(
                error as? NotebookPDFExportError,
                .drawingDataLimitExceeded(
                    pageIndex: 0,
                    limit: PageExportRenderer.maximumDrawingDataBytes
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(try exportWorkFiles(in: directory).isEmpty)
    }

    @MainActor
    private func textElement(_ text: String, frame: CanvasRect) -> CanvasElement {
        CanvasElement(frame: frame, content: .text(TextElement(text: text)))
    }

    @MainActor
    private func imageElement(_ assetID: AssetID, frame: CanvasRect) -> CanvasElement {
        CanvasElement(frame: frame, content: .image(ImageElement(assetID: assetID)))
    }

    @MainActor
    private func linkElement(_ url: URL, frame: CanvasRect) -> CanvasElement {
        CanvasElement(
            frame: frame,
            content: .link(LinkElement(title: url.lastPathComponent, destination: url))
        )
    }

    @MainActor
    private func inkDrawingData() -> Data {
        let points = [
            PKStrokePoint(
                location: CGPoint(x: 20, y: 150),
                timeOffset: 0,
                size: CGSize(width: 16, height: 16),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
            PKStrokePoint(
                location: CGPoint(x: 180, y: 150),
                timeOffset: 0.1,
                size: CGSize(width: 16, height: 16),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
        ]
        let path = PKStrokePath(controlPoints: points, creationDate: Date())
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: path)
        return PKDrawing(strokes: [stroke]).dataRepresentation()
    }

    @MainActor
    private func solidImage(color: UIColor, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notes-notebook-pdf-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func exportWorkFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasSuffix(".notes-pdf-partial")
                || $0.lastPathComponent.hasSuffix(".notes-pdf-artifacts")
        }
    }

    private func linkURLs(on page: PDFPage) -> [URL] {
        page.annotations.compactMap { annotation in
            annotation.url ?? (annotation.action as? PDFActionURL)?.url
        }
    }

    private func linkBounds(for url: URL, on page: PDFPage) -> CGRect? {
        page.annotations.first { annotation in
            annotation.url == url || (annotation.action as? PDFActionURL)?.url == url
        }?.bounds
    }

    private func pixel(
        in image: UIImage,
        x: Int,
        y: Int
    ) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let cgImage = try XCTUnwrap(image.cgImage)
        let safeX = min(max(x, 0), cgImage.width - 1)
        let safeY = min(max(y, 0), cgImage.height - 1)
        let crop = try XCTUnwrap(cgImage.cropping(to: CGRect(
            x: safeX,
            y: safeY,
            width: 1,
            height: 1
        )))
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (
            red: CGFloat(bytes[0]) / 255,
            green: CGFloat(bytes[1]) / 255,
            blue: CGFloat(bytes[2]) / 255
        )
    }
}

private final class NotebookPDFCancellationRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?
    private var invoked = false

    var wasInvoked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return invoked
    }

    func install(_ cancellation: @escaping @Sendable () -> Void) {
        lock.lock()
        self.cancellation = cancellation
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        invoked = true
        let cancellation = self.cancellation
        lock.unlock()
        cancellation?()
    }
}
