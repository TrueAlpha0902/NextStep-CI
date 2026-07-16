import NotesCore
import PencilKit
import UIKit
import XCTest
@testable import NotesApp

final class NotebookPDFSnapshotCollectorTests: XCTestCase {
    @MainActor
    func testCollectsEveryPageInOrderWithCompleteImmutableInputs() async throws {
        let backgroundData = try pngData(color: .systemGreen)
        let elementAssetData = try pngData(color: .systemBlue)

        let first = EditorPage(
            kind: .notebook,
            background: .paper(.grid),
            width: 300,
            height: 400
        )
        let second = EditorPage(
            kind: .importedDocument,
            background: .image(assetPath: "assets/background.png"),
            width: 500,
            height: 250
        )
        let notebook = makeNotebook(pages: [first, second])
        let revision = makeRevision(notebook: notebook, selectedPageID: first.id)
        let drawingByPage = [first.id: inkDrawingData(x: 20), second.id: inkDrawingData(x: 40)]
        let assetID = AssetID(String(repeating: "a", count: 64))
        let imageElement = CanvasElement(
            frame: CanvasRect(x: 10, y: 20, width: 40, height: 50),
            content: .image(ImageElement(assetID: assetID))
        )
        let elementsByPage = [first.id: [], second.id: [imageElement]]
        var requestedAssetIDs = [AssetID]()
        var progressValues = [NotebookPDFExportProgress]()

        let dependencies = NotebookPDFSnapshotDependencies(
            flushAllPendingWrites: { true },
            loadNotebook: { _ in notebook },
            loadInk: { _, page in drawingByPage[page.id] },
            loadCanvasElements: { _, pageID in
                guard let elements = elementsByPage[pageID] else {
                    throw InkLoadFailure.unreadable
                }
                return elements
            },
            resolveBackground: { _, page in
                ResolvedPageBackground(
                    background: page.background,
                    assetURL: nil,
                    assetData: page.id == second.id ? backgroundData : nil
                )
            },
            loadCanvasAssets: { _, assetIDs in
                requestedAssetIDs = assetIDs
                return [assetID: elementAssetData]
            }
        )

        let snapshots = try await NotebookPDFSnapshotCollector.collect(
            notebook: notebook,
            expectedRevision: revision,
            currentRevision: { revision },
            dependencies: dependencies,
            progress: { progressValues.append($0) }
        )

        XCTAssertEqual(snapshots.map(\.page.id), [first.id, second.id])
        XCTAssertTrue(snapshots.allSatisfy { $0.drawingData == nil })
        XCTAssertEqual(snapshots.map { $0.preparedDrawing?.complexity.strokeCount }, [1, 1])
        XCTAssertEqual(snapshots[0].background.background, first.background)
        XCTAssertNil(snapshots[0].background.assetURL)
        XCTAssertNil(snapshots[1].background.assetURL)
        XCTAssertNil(snapshots[1].background.assetData)
        XCTAssertNotNil(snapshots[1].preparedBackground?.rasterPixelSize)
        XCTAssertEqual(snapshots[1].canvasElements, [imageElement])
        XCTAssertEqual(requestedAssetIDs, [assetID])
        XCTAssertEqual(
            progressValues,
            [
                NotebookPDFExportProgress(completedUnits: 0, totalUnits: 2),
                NotebookPDFExportProgress(completedUnits: 1, totalUnits: 2),
                NotebookPDFExportProgress(completedUnits: 2, totalUnits: 2),
            ]
        )
        let request = CanvasElementExportImageRequest(
            frameSize: CGSize(width: 32, height: 32),
            rasterScale: 1
        )
        let image = try XCTUnwrap(snapshots[1].assetImageResolver(assetID, request))
        XCTAssertTrue(request.accepts(image))
    }

    @MainActor
    func testSinglePageAuthoritativeInkFailureCannotBecomeBlankPDF() async {
        let page = EditorPage()
        let notebookID = UUID()
        let revision = SinglePagePDFExportRevision(
            pageID: page.id,
            pageLoadID: UUID(),
            interactionGeneration: 4
        )
        var loadedElements = false
        let dependencies = SinglePagePDFSnapshotDependencies(
            loadInk: { _, _ in throw InkLoadFailure.unreadable },
            loadCanvasElements: { _, _ in
                loadedElements = true
                return []
            },
            resolveBackground: { _, page in
                ResolvedPageBackground(background: page.background, assetURL: nil)
            },
            loadCanvasAssets: { _, _ in [:] }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await NotebookPDFSnapshotCollector.collectSinglePage(
                notebookID: notebookID,
                page: page,
                expectedRevision: revision,
                currentRevision: { revision },
                dependencies: dependencies
            )
        } verify: { error in
            XCTAssertEqual(
                error as? NotebookPDFSnapshotCollectionError,
                .inkUnavailable(pageNumber: 1)
            )
        }
        XCTAssertFalse(loadedElements)
    }

    @MainActor
    func testSinglePageRejectsZeroByteAndCorruptPersistedInk() async {
        let page = EditorPage()
        let revision = SinglePagePDFExportRevision(
            pageID: page.id,
            pageLoadID: UUID(),
            interactionGeneration: 1
        )
        for data in [Data(), Data("not a drawing".utf8)] {
            let dependencies = singlePageDependencies(
                page: page,
                loadInk: { _, _ in data }
            )
            await XCTAssertThrowsErrorAsync {
                _ = try await NotebookPDFSnapshotCollector.collectSinglePage(
                    notebookID: UUID(),
                    page: page,
                    expectedRevision: revision,
                    currentRevision: { revision },
                    dependencies: dependencies
                )
            } verify: { error in
                XCTAssertEqual(
                    error as? NotebookPDFSnapshotCollectionError,
                    .corruptDrawingData(pageNumber: 1)
                )
            }
        }
    }

    @MainActor
    func testSinglePageMissingPersistedElementsFailsClosed() async {
        let page = EditorPage()
        let revision = SinglePagePDFExportRevision(
            pageID: page.id,
            pageLoadID: UUID(),
            interactionGeneration: 2
        )
        var resolvedBackground = false
        let dependencies = SinglePagePDFSnapshotDependencies(
            loadInk: { _, _ in nil },
            loadCanvasElements: { _, _ in throw InkLoadFailure.unreadable },
            resolveBackground: { _, page in
                resolvedBackground = true
                return ResolvedPageBackground(background: page.background, assetURL: nil)
            },
            loadCanvasAssets: { _, _ in [:] }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await NotebookPDFSnapshotCollector.collectSinglePage(
                notebookID: UUID(),
                page: page,
                expectedRevision: revision,
                currentRevision: { revision },
                dependencies: dependencies
            )
        } verify: { error in
            XCTAssertEqual(
                error as? NotebookPDFSnapshotCollectionError,
                .pageElementsUnavailable(pageNumber: 1)
            )
        }
        XCTAssertFalse(resolvedBackground)
    }

    @MainActor
    func testSinglePageRejectsEditThatOccursDuringAuthoritativeReload() async {
        let page = EditorPage()
        let expected = SinglePagePDFExportRevision(
            pageID: page.id,
            pageLoadID: UUID(),
            interactionGeneration: 8
        )
        var current = expected
        var loadedElements = false
        let dependencies = SinglePagePDFSnapshotDependencies(
            loadInk: { _, _ in
                current = SinglePagePDFExportRevision(
                    pageID: expected.pageID,
                    pageLoadID: expected.pageLoadID,
                    interactionGeneration: expected.interactionGeneration + 1
                )
                return nil
            },
            loadCanvasElements: { _, _ in
                loadedElements = true
                return []
            },
            resolveBackground: { _, page in
                ResolvedPageBackground(background: page.background, assetURL: nil)
            },
            loadCanvasAssets: { _, _ in [:] }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await NotebookPDFSnapshotCollector.collectSinglePage(
                notebookID: UUID(),
                page: page,
                expectedRevision: expected,
                currentRevision: { current },
                dependencies: dependencies
            )
        } verify: { error in
            XCTAssertEqual(
                error as? NotebookPDFSnapshotCollectionError,
                .staleEditorState
            )
        }
        XCTAssertFalse(loadedElements)
    }

    @MainActor
    func testStaleSinglePagePublicationRemovesOwnedTemporaryExport() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesExports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("stale-\(UUID().uuidString).pdf")
        try Data("temporary PDF".utf8).write(to: url, options: .atomic)
        let expected = SinglePagePDFExportRevision(
            pageID: UUID(),
            pageLoadID: UUID(),
            interactionGeneration: 10
        )
        let stale = SinglePagePDFExportRevision(
            pageID: expected.pageID,
            pageLoadID: expected.pageLoadID,
            interactionGeneration: 11
        )

        let publishURL = SinglePagePDFExportPublication.validatedURL(
            url,
            expectedRevision: expected,
            currentRevision: { stale }
        )

        XCTAssertNil(publishURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    @MainActor
    func testSinglePageCanvasAssetSnapshotSurvivesBackingFileReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Notes-Single-Page-Asset-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let assetURL = directory.appendingPathComponent("asset.png")
        let originalData = try pngData(color: .systemBlue)
        try originalData.write(to: assetURL, options: .atomic)
        let assetID = AssetID(String(repeating: "b", count: 64))
        let page = EditorPage()
        let element = CanvasElement(
            frame: CanvasRect(x: 0, y: 0, width: 48, height: 48),
            content: .image(ImageElement(assetID: assetID))
        )
        let revision = SinglePagePDFExportRevision(
            pageID: page.id,
            pageLoadID: UUID(),
            interactionGeneration: 3
        )
        let dependencies = SinglePagePDFSnapshotDependencies(
            loadInk: { _, _ in nil },
            loadCanvasElements: { _, _ in [element] },
            resolveBackground: { _, page in
                ResolvedPageBackground(background: page.background, assetURL: nil)
            },
            loadCanvasAssets: { _, assetIDs in
                XCTAssertEqual(assetIDs, [assetID])
                let owned = try Data(contentsOf: assetURL)
                try Data("replacement is not an image".utf8).write(
                    to: assetURL,
                    options: .atomic
                )
                return [assetID: owned]
            }
        )

        let snapshot = try await NotebookPDFSnapshotCollector.collectSinglePage(
            notebookID: UUID(),
            page: page,
            expectedRevision: revision,
            currentRevision: { revision },
            dependencies: dependencies
        )
        let request = CanvasElementExportImageRequest(
            frameSize: CGSize(width: 48, height: 48),
            rasterScale: 1
        )
        XCTAssertNotNil(snapshot.assetImageResolver(assetID, request))
        XCTAssertNil(PageAssetImageLoader.thumbnail(data: try Data(contentsOf: assetURL)))
    }

    @MainActor
    func testVerifiedButUnsupportedCanvasCodecUsesMissingImagePlaceholder() throws {
        let assetID = AssetID(String(repeating: "c", count: 64))
        let resolver = try XCTUnwrap(NotebookPDFSnapshotCollector.assetImageResolver(
            dataByAssetID: [assetID: Data("unsupported codec".utf8)],
            expectedAssetIDs: [assetID]
        ))
        let request = CanvasElementExportImageRequest(
            frameSize: CGSize(width: 32, height: 32),
            rasterScale: 1
        )
        XCTAssertNil(resolver(assetID, request))
    }

    @MainActor
    func testRejectsChangedInteractionGenerationDuringPageLoad() async {
        let page = EditorPage()
        let notebook = makeNotebook(pages: [page])
        let expected = makeRevision(notebook: notebook, selectedPageID: page.id)
        var current = expected
        let dependencies = dependencies(notebook: notebook) { _, _ in
            current = NotebookPDFEditorRevision(
                notebookID: expected.notebookID,
                notebookTitle: expected.notebookTitle,
                orderedPageIDs: expected.orderedPageIDs,
                pageIdentities: expected.pageIdentities,
                selectedPageID: expected.selectedPageID,
                interactionGeneration: expected.interactionGeneration + 1
            )
            return nil
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await NotebookPDFSnapshotCollector.collect(
                notebook: notebook,
                expectedRevision: expected,
                currentRevision: { current },
                dependencies: dependencies
            )
        } verify: { error in
            XCTAssertEqual(
                error as? NotebookPDFSnapshotCollectionError,
                .staleEditorState
            )
        }
    }

    @MainActor
    func testRejectsPersistedPageListChangeBeforeTakingSnapshots() async {
        let first = EditorPage()
        let second = EditorPage()
        let notebook = makeNotebook(pages: [first, second])
        let expected = makeRevision(notebook: notebook, selectedPageID: first.id)
        var changed = notebook
        changed.pages.removeLast()
        let dependencies = NotebookPDFSnapshotDependencies(
            flushAllPendingWrites: { true },
            loadNotebook: { _ in changed },
            loadInk: { _, _ in nil },
            loadCanvasElements: { _, _ in [] },
            resolveBackground: { _, page in
                ResolvedPageBackground(background: page.background, assetURL: nil)
            },
            loadCanvasAssets: { _, _ in [:] }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await NotebookPDFSnapshotCollector.collect(
                notebook: notebook,
                expectedRevision: expected,
                currentRevision: { expected },
                dependencies: dependencies
            )
        } verify: { error in
            XCTAssertEqual(
                error as? NotebookPDFSnapshotCollectionError,
                .staleEditorState
            )
        }
    }

    @MainActor
    func testRejectsPersistedTitleChangeBeforeTakingSnapshots() async {
        let page = EditorPage()
        let notebook = makeNotebook(pages: [page])
        let expected = makeRevision(notebook: notebook, selectedPageID: page.id)
        var changed = notebook
        changed.title = "Renamed while exporting"
        let dependencies = NotebookPDFSnapshotDependencies(
            flushAllPendingWrites: { true },
            loadNotebook: { _ in changed },
            loadInk: { _, _ in nil },
            loadCanvasElements: { _, _ in [] },
            resolveBackground: { _, page in
                ResolvedPageBackground(background: page.background, assetURL: nil)
            },
            loadCanvasAssets: { _, _ in [:] }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await NotebookPDFSnapshotCollector.collect(
                notebook: notebook,
                expectedRevision: expected,
                currentRevision: { expected },
                dependencies: dependencies
            )
        } verify: { error in
            XCTAssertEqual(
                error as? NotebookPDFSnapshotCollectionError,
                .staleEditorState
            )
        }
    }

    @MainActor
    func testFlushFailureStopsBeforeAnySnapshotLoad() async {
        let page = EditorPage()
        let notebook = makeNotebook(pages: [page])
        let revision = makeRevision(notebook: notebook, selectedPageID: page.id)
        var loadCount = 0
        let dependencies = NotebookPDFSnapshotDependencies(
            flushAllPendingWrites: { false },
            loadNotebook: { _ in
                loadCount += 1
                return notebook
            },
            loadInk: { _, _ in nil },
            loadCanvasElements: { _, _ in [] },
            resolveBackground: { _, page in
                ResolvedPageBackground(background: page.background, assetURL: nil)
            },
            loadCanvasAssets: { _, _ in [:] }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await NotebookPDFSnapshotCollector.collect(
                notebook: notebook,
                expectedRevision: revision,
                currentRevision: { revision },
                dependencies: dependencies
            )
        } verify: { error in
            XCTAssertEqual(error as? NotebookPDFSnapshotCollectionError, .flushFailed)
        }
        XCTAssertEqual(loadCount, 0)
    }

    @MainActor
    func testCancellationNeverReturnsPartialSnapshots() async {
        let page = EditorPage()
        let notebook = makeNotebook(pages: [page])
        let revision = makeRevision(notebook: notebook, selectedPageID: page.id)
        let dependencies = dependencies(notebook: notebook) { _, _ in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                return nil
            }
            return nil
        }
        let task = Task { @MainActor in
            try await NotebookPDFSnapshotCollector.collect(
                notebook: notebook,
                expectedRevision: revision,
                currentRevision: { revision },
                dependencies: dependencies
            )
        }
        await Task.yield()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled snapshot collection unexpectedly succeeded")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    func testCollectEachConsumesEachPageBeforeLoadingTheNext() async throws {
        let first = EditorPage()
        let second = EditorPage()
        let notebook = makeNotebook(pages: [first, second])
        let revision = makeRevision(notebook: notebook, selectedPageID: first.id)
        var events = [String]()
        let dependencies = NotebookPDFSnapshotDependencies(
            flushAllPendingWrites: { true },
            loadNotebook: { _ in notebook },
            loadInk: { _, page in
                events.append("load-\(page.id.uuidString)")
                return nil
            },
            loadCanvasElements: { _, _ in [] },
            resolveBackground: { _, page in
                ResolvedPageBackground(background: page.background, assetURL: nil)
            },
            loadCanvasAssets: { _, _ in [:] }
        )

        let persistedRevision = try await NotebookPDFSnapshotCollector.collectEach(
            notebook: notebook,
            expectedRevision: revision,
            currentRevision: { revision },
            dependencies: dependencies,
            consume: { snapshot, index, _ in
                events.append("consume-\(snapshot.page.id.uuidString)-\(index)")
            }
        )

        XCTAssertEqual(events, [
            "load-\(first.id.uuidString)",
            "consume-\(first.id.uuidString)-0",
            "load-\(second.id.uuidString)",
            "consume-\(second.id.uuidString)-1",
        ])
        XCTAssertTrue(persistedRevision.matches(notebook))
        var externallyChanged = notebook
        externallyChanged.modifiedAt = notebook.modifiedAt.addingTimeInterval(1)
        XCTAssertFalse(persistedRevision.matches(externallyChanged))
    }

    @MainActor
    func testWholeExportDrawingSourceBudgetAcceptsBoundaryAndStopsBeforeNextDecode() async throws {
        let first = EditorPage()
        let second = EditorPage()
        let notebook = makeNotebook(pages: [first, second])
        let revision = makeRevision(notebook: notebook, selectedPageID: first.id)
        let drawing = inkDrawingData(x: 12)
        let exactBudget = NotebookPDFSnapshotSourceBudget(
            maximumDrawingSourceBytes: Int64(drawing.count * 2),
            maximumBackgroundSourceBytes: 0
        )
        let exactSnapshots = try await NotebookPDFSnapshotCollector.collect(
            notebook: notebook,
            expectedRevision: revision,
            currentRevision: { revision },
            dependencies: dependencies(notebook: notebook) { _, _ in drawing },
            sourceBudget: exactBudget
        )
        XCTAssertEqual(exactSnapshots.count, 2)

        var elementLoadCount = 0
        let exceedingDependencies = NotebookPDFSnapshotDependencies(
            flushAllPendingWrites: { true },
            loadNotebook: { _ in notebook },
            loadInk: { _, _ in drawing },
            loadCanvasElements: { _, _ in
                elementLoadCount += 1
                return []
            },
            resolveBackground: { _, page in
                ResolvedPageBackground(background: page.background, assetURL: nil)
            },
            loadCanvasAssets: { _, _ in [:] }
        )
        let exceedingBudget = NotebookPDFSnapshotSourceBudget(
            maximumDrawingSourceBytes: Int64(drawing.count * 2 - 1),
            maximumBackgroundSourceBytes: 0
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await NotebookPDFSnapshotCollector.collect(
                notebook: notebook,
                expectedRevision: revision,
                currentRevision: { revision },
                dependencies: exceedingDependencies,
                sourceBudget: exceedingBudget
            )
        } verify: { error in
            XCTAssertEqual(
                error as? NotebookPDFSnapshotCollectionError,
                .sourceWorkLimitExceeded
            )
        }
        XCTAssertEqual(elementLoadCount, 1)
    }

    @MainActor
    func testWholeExportBackgroundSourceBudgetAcceptsBoundaryAndStopsBeforeConsume() async throws {
        let backgroundData = try pngData(color: .systemPurple)
        let first = EditorPage(background: .image(assetPath: "assets/first.png"))
        let second = EditorPage(background: .image(assetPath: "assets/second.png"))
        let notebook = makeNotebook(pages: [first, second])
        let revision = makeRevision(notebook: notebook, selectedPageID: first.id)
        let dependencies = NotebookPDFSnapshotDependencies(
            flushAllPendingWrites: { true },
            loadNotebook: { _ in notebook },
            loadInk: { _, _ in nil },
            loadCanvasElements: { _, _ in [] },
            resolveBackground: { _, page in
                ResolvedPageBackground(
                    background: page.background,
                    assetURL: nil,
                    assetData: backgroundData
                )
            },
            loadCanvasAssets: { _, _ in [:] }
        )
        let exactBudget = NotebookPDFSnapshotSourceBudget(
            maximumDrawingSourceBytes: 0,
            maximumBackgroundSourceBytes: Int64(backgroundData.count * 2)
        )
        let exactSnapshots = try await NotebookPDFSnapshotCollector.collect(
            notebook: notebook,
            expectedRevision: revision,
            currentRevision: { revision },
            dependencies: dependencies,
            sourceBudget: exactBudget
        )
        XCTAssertEqual(exactSnapshots.count, 2)

        var consumedCount = 0
        let exceedingBudget = NotebookPDFSnapshotSourceBudget(
            maximumDrawingSourceBytes: 0,
            maximumBackgroundSourceBytes: Int64(backgroundData.count * 2 - 1)
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await NotebookPDFSnapshotCollector.collectEach(
                notebook: notebook,
                expectedRevision: revision,
                currentRevision: { revision },
                dependencies: dependencies,
                sourceBudget: exceedingBudget,
                consume: { _, _, _ in consumedCount += 1 }
            )
        } verify: { error in
            XCTAssertEqual(
                error as? NotebookPDFSnapshotCollectionError,
                .sourceWorkLimitExceeded
            )
        }
        XCTAssertEqual(consumedCount, 1)
    }

    @MainActor
    func testWholeExportElementSourceBudgetAcceptsExactBoundaryAndStopsBeforeLaterWork() async throws {
        let first = EditorPage()
        let second = EditorPage()
        let notebook = makeNotebook(pages: [first, second])
        let revision = makeRevision(notebook: notebook, selectedPageID: first.id)
        var exactElementBytes = [5, 7]
        var exactBackgroundCount = 0
        var exactEndCount = 0
        var exactValidationCount = 0
        let exactDependencies = NotebookPDFSnapshotDependencies(
            flushAllPendingWrites: { true },
            beginExportSession: { _ in
                NotesAppNotebookExportSession(
                    token: NotebookExportSession(notebookID: NotebookID(notebook.id)),
                    notebook: notebook
                )
            },
            validateExportSession: { _ in
                exactValidationCount += 1
                return notebook
            },
            endExportSession: { _ in exactEndCount += 1 },
            loadInk: { _, _ in nil },
            loadCanvasElements: { _, _ in
                NotebookExportCanvasElements(
                    elements: [],
                    encodedByteCount: exactElementBytes.removeFirst()
                )
            },
            resolveBackground: { _, page in
                exactBackgroundCount += 1
                return ResolvedPageBackground(background: page.background, assetURL: nil)
            },
            loadCanvasAssets: { _, _ in [:] }
        )
        let exactBudget = NotebookPDFSnapshotSourceBudget(
            maximumDrawingSourceBytes: 0,
            maximumBackgroundSourceBytes: 0,
            maximumElementSourceBytes: 12
        )
        let snapshots = try await NotebookPDFSnapshotCollector.collect(
            notebook: notebook,
            expectedRevision: revision,
            currentRevision: { revision },
            dependencies: exactDependencies,
            sourceBudget: exactBudget
        )
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(exactBackgroundCount, 2)
        XCTAssertEqual(exactValidationCount, 1)
        XCTAssertEqual(exactEndCount, 1)

        var exceedingElementBytes = [5, 7]
        var exceedingElementLoadCount = 0
        var exceedingBackgroundCount = 0
        var exceedingConsumeCount = 0
        var exceedingEndCount = 0
        let exceedingDependencies = NotebookPDFSnapshotDependencies(
            flushAllPendingWrites: { true },
            beginExportSession: { _ in
                NotesAppNotebookExportSession(
                    token: NotebookExportSession(notebookID: NotebookID(notebook.id)),
                    notebook: notebook
                )
            },
            validateExportSession: { _ in notebook },
            endExportSession: { _ in exceedingEndCount += 1 },
            loadInk: { _, _ in nil },
            loadCanvasElements: { _, _ in
                exceedingElementLoadCount += 1
                return NotebookExportCanvasElements(
                    elements: [],
                    encodedByteCount: exceedingElementBytes.removeFirst()
                )
            },
            resolveBackground: { _, page in
                exceedingBackgroundCount += 1
                return ResolvedPageBackground(background: page.background, assetURL: nil)
            },
            loadCanvasAssets: { _, _ in [:] }
        )
        let exceedingBudget = NotebookPDFSnapshotSourceBudget(
            maximumDrawingSourceBytes: 0,
            maximumBackgroundSourceBytes: 0,
            maximumElementSourceBytes: 11
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await NotebookPDFSnapshotCollector.collectEach(
                notebook: notebook,
                expectedRevision: revision,
                currentRevision: { revision },
                dependencies: exceedingDependencies,
                sourceBudget: exceedingBudget,
                consume: { _, _, _ in exceedingConsumeCount += 1 }
            )
        } verify: { error in
            XCTAssertEqual(
                error as? NotebookPDFSnapshotCollectionError,
                .sourceWorkLimitExceeded
            )
        }
        XCTAssertEqual(exceedingElementLoadCount, 2)
        XCTAssertEqual(exceedingBackgroundCount, 1)
        XCTAssertEqual(exceedingConsumeCount, 1)
        XCTAssertEqual(exceedingEndCount, 1)
    }

    @MainActor
    func testWholeExportCancellationEndsStartedSessionExactlyOnce() async throws {
        let page = EditorPage()
        let notebook = makeNotebook(pages: [page])
        let revision = makeRevision(notebook: notebook, selectedPageID: page.id)
        let gate = NotebookPDFSnapshotCancellationGate()
        var beginCount = 0
        var endCount = 0
        let dependencies = NotebookPDFSnapshotDependencies(
            flushAllPendingWrites: { true },
            beginExportSession: { _ in
                beginCount += 1
                return NotesAppNotebookExportSession(
                    token: NotebookExportSession(notebookID: NotebookID(notebook.id)),
                    notebook: notebook
                )
            },
            validateExportSession: { _ in notebook },
            endExportSession: { _ in endCount += 1 },
            loadInk: { _, _ in
                await gate.wait()
                try Task.checkCancellation()
                return nil
            },
            loadCanvasElements: { _, _ in
                NotebookExportCanvasElements(elements: [], encodedByteCount: 0)
            },
            resolveBackground: { _, page in
                ResolvedPageBackground(background: page.background, assetURL: nil)
            },
            loadCanvasAssets: { _, _ in [:] }
        )

        let export = Task { @MainActor in
            try await NotebookPDFSnapshotCollector.collect(
                notebook: notebook,
                expectedRevision: revision,
                currentRevision: { revision },
                dependencies: dependencies
            )
        }
        await gate.waitUntilEntered()
        export.cancel()
        await gate.release()
        do {
            _ = try await export.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(beginCount, 1)
        XCTAssertEqual(endCount, 1)
    }

    @MainActor
    func testBoundedInkReadLimitStopsBeforeElementsOrArtifactConsumer() async {
        let page = EditorPage()
        let notebook = makeNotebook(pages: [page])
        let revision = makeRevision(notebook: notebook, selectedPageID: page.id)
        var loadedElements = false
        var consumed = false
        let dependencies = NotebookPDFSnapshotDependencies(
            flushAllPendingWrites: { true },
            loadNotebook: { _ in notebook },
            loadInk: { _, _ in
                throw NotebookRepositoryError.boundedReadLimitExceeded(
                    relativePath: "pages/page/ink.data",
                    limit: PageExportRenderer.maximumDrawingDataBytes
                )
            },
            loadCanvasElements: { _, _ in
                loadedElements = true
                return []
            },
            resolveBackground: { _, page in
                ResolvedPageBackground(background: page.background, assetURL: nil)
            },
            loadCanvasAssets: { _, _ in [:] }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await NotebookPDFSnapshotCollector.collectEach(
                notebook: notebook,
                expectedRevision: revision,
                currentRevision: { revision },
                dependencies: dependencies,
                consume: { _, _, _ in consumed = true }
            )
        } verify: { error in
            XCTAssertEqual(
                error as? NotebookPDFSnapshotCollectionError,
                .drawingDataLimitExceeded(
                    pageNumber: 1,
                    limit: PageExportRenderer.maximumDrawingDataBytes
                )
            )
        }
        XCTAssertFalse(loadedElements)
        XCTAssertFalse(consumed)
    }

    @MainActor
    func testInkLoadFailureMapsToLocalizedPageErrorAndNeverPublishesMissingInk() async {
        let page = EditorPage()
        let notebook = makeNotebook(pages: [page])
        let revision = makeRevision(notebook: notebook, selectedPageID: page.id)
        var loadedElements = false
        var consumed = false
        let dependencies = NotebookPDFSnapshotDependencies(
            flushAllPendingWrites: { true },
            loadNotebook: { _ in notebook },
            loadInk: { _, _ in throw InkLoadFailure.unreadable },
            loadCanvasElements: { _, _ in
                loadedElements = true
                return []
            },
            resolveBackground: { _, page in
                ResolvedPageBackground(background: page.background, assetURL: nil)
            },
            loadCanvasAssets: { _, _ in [:] }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await NotebookPDFSnapshotCollector.collectEach(
                notebook: notebook,
                expectedRevision: revision,
                currentRevision: { revision },
                dependencies: dependencies,
                consume: { _, _, _ in consumed = true }
            )
        } verify: { error in
            XCTAssertEqual(
                error as? NotebookPDFSnapshotCollectionError,
                .inkUnavailable(pageNumber: 1)
            )
        }
        XCTAssertFalse(loadedElements)
        XCTAssertFalse(consumed)
    }

    @MainActor
    func testCorruptInkGetsPageNumberAndStopsBeforeElements() async {
        let page = EditorPage()
        let notebook = makeNotebook(pages: [page])
        let revision = makeRevision(notebook: notebook, selectedPageID: page.id)
        var loadedElements = false
        let dependencies = NotebookPDFSnapshotDependencies(
            flushAllPendingWrites: { true },
            loadNotebook: { _ in notebook },
            loadInk: { _, _ in Data("not a PencilKit drawing".utf8) },
            loadCanvasElements: { _, _ in
                loadedElements = true
                return []
            },
            resolveBackground: { _, page in
                ResolvedPageBackground(background: page.background, assetURL: nil)
            },
            loadCanvasAssets: { _, _ in [:] }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await NotebookPDFSnapshotCollector.collect(
                notebook: notebook,
                expectedRevision: revision,
                currentRevision: { revision },
                dependencies: dependencies
            )
        } verify: { error in
            XCTAssertEqual(
                error as? NotebookPDFSnapshotCollectionError,
                .corruptDrawingData(pageNumber: 1)
            )
        }
        XCTAssertFalse(loadedElements)
    }

    @MainActor
    func testZeroByteInkIsCorruptAndStopsBeforeElements() async {
        let page = EditorPage()
        let notebook = makeNotebook(pages: [page])
        let revision = makeRevision(notebook: notebook, selectedPageID: page.id)
        var loadedElements = false
        let dependencies = NotebookPDFSnapshotDependencies(
            flushAllPendingWrites: { true },
            loadNotebook: { _ in notebook },
            loadInk: { _, _ in Data() },
            loadCanvasElements: { _, _ in
                loadedElements = true
                return []
            },
            resolveBackground: { _, page in
                ResolvedPageBackground(background: page.background, assetURL: nil)
            },
            loadCanvasAssets: { _, _ in [:] }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await NotebookPDFSnapshotCollector.collect(
                notebook: notebook,
                expectedRevision: revision,
                currentRevision: { revision },
                dependencies: dependencies
            )
        } verify: { error in
            XCTAssertEqual(
                error as? NotebookPDFSnapshotCollectionError,
                .corruptDrawingData(pageNumber: 1)
            )
        }
        XCTAssertFalse(loadedElements)
    }

    @MainActor
    func testElementLimitStopsBeforeBackgroundOrArtifactConsumer() async {
        let page = EditorPage()
        let notebook = makeNotebook(pages: [page])
        let revision = makeRevision(notebook: notebook, selectedPageID: page.id)
        let element = CanvasElement(
            frame: CanvasRect(x: 0, y: 0, width: 10, height: 10),
            content: .text(TextElement(text: "x"))
        )
        var resolvedBackground = false
        var consumed = false
        let dependencies = NotebookPDFSnapshotDependencies(
            flushAllPendingWrites: { true },
            loadNotebook: { _ in notebook },
            loadInk: { _, _ in nil },
            loadCanvasElements: { _, _ in
                throw NotebookRepositoryError.canvasElementLimitExceeded(
                    limit: CanvasElementExportRenderer.maximumElementCount
                )
            },
            resolveBackground: { _, page in
                resolvedBackground = true
                return ResolvedPageBackground(background: page.background, assetURL: nil)
            },
            loadCanvasAssets: { _, _ in [:] }
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await NotebookPDFSnapshotCollector.collectEach(
                notebook: notebook,
                expectedRevision: revision,
                currentRevision: { revision },
                dependencies: dependencies,
                consume: { _, _, _ in consumed = true }
            )
        } verify: { error in
            XCTAssertEqual(
                error as? NotebookPDFSnapshotCollectionError,
                .pageElementLimitExceeded(
                    pageNumber: 1,
                    limit: CanvasElementExportRenderer.maximumElementCount
                )
            )
        }
        XCTAssertFalse(resolvedBackground)
        XCTAssertFalse(consumed)
    }

    @MainActor
    private func dependencies(
        notebook: EditorNotebook,
        loadInk: @escaping (UUID, EditorPage) async throws -> Data?
    ) -> NotebookPDFSnapshotDependencies {
        NotebookPDFSnapshotDependencies(
            flushAllPendingWrites: { true },
            loadNotebook: { _ in notebook },
            loadInk: loadInk,
            loadCanvasElements: { _, _ in [] },
            resolveBackground: { _, page in
                ResolvedPageBackground(background: page.background, assetURL: nil)
            },
            loadCanvasAssets: { _, _ in [:] }
        )
    }

    @MainActor
    private func singlePageDependencies(
        page: EditorPage,
        loadInk: @escaping (UUID, EditorPage) async throws -> Data?
    ) -> SinglePagePDFSnapshotDependencies {
        SinglePagePDFSnapshotDependencies(
            loadInk: loadInk,
            loadCanvasElements: { _, _ in [] },
            resolveBackground: { _, _ in
                ResolvedPageBackground(background: page.background, assetURL: nil)
            },
            loadCanvasAssets: { _, _ in [:] }
        )
    }

    private func makeRevision(
        notebook: EditorNotebook,
        selectedPageID: UUID?
    ) -> NotebookPDFEditorRevision {
        NotebookPDFEditorRevision(
            notebookID: notebook.id,
            notebookTitle: notebook.title,
            orderedPageIDs: notebook.pages.map(\.id),
            pageIdentities: notebook.pages.map(NotebookPDFPageIdentity.init),
            selectedPageID: selectedPageID,
            interactionGeneration: 7
        )
    }

    private func makeNotebook(pages: [EditorPage]) -> EditorNotebook {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return EditorNotebook(
            id: UUID(),
            title: "Snapshot notebook",
            kind: .notebook,
            createdAt: date,
            modifiedAt: date,
            isFavorite: false,
            deletedAt: nil,
            coverHue: 0.2,
            pages: pages
        )
    }

    @MainActor
    private func pngData(color: UIColor) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 24, height: 24),
            format: format
        ).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        return try XCTUnwrap(image.pngData())
    }

    @MainActor
    private func inkDrawingData(x: CGFloat) -> Data {
        let points = [
            PKStrokePoint(
                location: CGPoint(x: x, y: 20),
                timeOffset: 0,
                size: CGSize(width: 5, height: 5),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2
            ),
            PKStrokePoint(
                location: CGPoint(x: x + 10, y: 30),
                timeOffset: 0.1,
                size: CGSize(width: 5, height: 5),
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
    func XCTAssertThrowsErrorAsync<T>(
        _ expression: () async throws -> T,
        verify errorHandler: (Error) -> Void
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected an error to be thrown")
        } catch {
            errorHandler(error)
        }
    }
}

private enum InkLoadFailure: Error, Equatable {
    case unreadable
}

private actor NotebookPDFSnapshotCancellationGate {
    private var didEnter = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        didEnter = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        if didEnter { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
