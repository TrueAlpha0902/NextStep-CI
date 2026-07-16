import Foundation
import XCTest
import Darwin
import Dispatch
@testable import NotesCore

final class FileNotebookRepositoryTests: XCTestCase {
    func testCallerOwnedNotebookIdentityAndCreationDateArePersistedExactly() async throws {
        let (repository, _) = try makeRepository()
        let notebookID = NotebookID(
            UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )
        let pageID = PageID(
            UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        )
        let createdAt = Date(timeIntervalSinceReferenceDate: 12_345.6789)
        let page = PageDescriptor(
            id: pageID,
            kind: .textDocument,
            createdAt: createdAt,
            modifiedAt: createdAt
        )

        let created = try await repository.createNotebook(
            id: notebookID,
            title: "  Deterministic lecture  ",
            initialPage: page,
            createdAt: createdAt
        )

        XCTAssertEqual(created.id, notebookID)
        XCTAssertEqual(created.title, "Deterministic lecture")
        XCTAssertEqual(created.createdAt, createdAt)
        XCTAssertEqual(created.modifiedAt, createdAt)
        XCTAssertEqual(created.pages.map(\.id), [pageID])
        XCTAssertEqual(created.pages.first?.createdAt, createdAt)
        let initialContent = try await repository.loadPageContent(
            notebookID: notebookID,
            pageID: pageID
        )
        XCTAssertEqual(
            initialContent,
            .textDocument(TextDocument())
        )

        do {
            _ = try await repository.createNotebook(
                id: notebookID,
                title: "Deterministic lecture",
                initialPage: page,
                createdAt: createdAt
            )
            XCTFail("The repository primitive itself must reject an existing identity.")
        } catch let error as NotebookRepositoryError {
            guard case .malformedPackage = error else {
                return XCTFail("Expected an existing-package conflict, got \(error)")
            }
        }
    }

    func testNotebookRoundTripAndChangeStream() async throws {
        let (repository, _) = try makeRepository()
        let stream = await repository.changes()
        let firstChange = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        let page = PageDescriptor(title: "Page one")
        let created = try await repository.createNotebook(title: "  Field Notes  ", initialPage: page)
        XCTAssertEqual(created.title, "Field Notes")
        XCTAssertEqual(created.pages.map(\.id), [page.id])

        let emitted = await firstChange.value
        XCTAssertEqual(emitted?.notebookID, created.id)
        XCTAssertEqual(emitted?.kind, .created)

        let ink = Data([0x50, 0x4b, 0x44, 0x52, 0x41, 0x57, 0x49, 0x4e, 0x47])
        let element = CanvasElement(
            frame: CanvasRect(x: 20, y: 40, width: 240, height: 80),
            content: .text(TextElement(text: "Hello, Notes", fontSize: 24))
        )
        try await repository.saveInk(ink, notebookID: created.id, pageID: page.id)
        try await repository.saveElements([element], notebookID: created.id, pageID: page.id)

        let loadedInk = try await repository.loadInk(notebookID: created.id, pageID: page.id)
        let loadedElements = try await repository.loadElements(notebookID: created.id, pageID: page.id)
        XCTAssertEqual(loadedInk, ink)
        XCTAssertEqual(loadedElements, [element])

        let reopened = try await repository.openNotebook(id: created.id)
        XCTAssertEqual(reopened.id, created.id)
        XCTAssertEqual(reopened.pages.count, 1)
        XCTAssertEqual(reopened.revision, 3)

        let operations = try await repository.operationLog(notebookID: created.id)
        XCTAssertEqual(operations.map(\.kind), [.createNotebook, .saveInk, .saveElements])
        XCTAssertEqual(operations.map(\.sequence), [1, 2, 3])
        let validation = try await repository.validateNotebook(id: created.id)
        XCTAssertTrue(validation.isValid)
    }

    func testBoundedExportReadsDistinguishMissingFilesFromZeroByteInk() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(title: "Export")
        let notebook = try await repository.createNotebook(
            title: "Bounded reads",
            initialPage: page
        )

        let missingInk = try await repository.loadInkForExport(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertNil(missingInk)
        let emptyElements = try await repository.loadElementsForExport(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertEqual(emptyElements, [])

        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        try FileManager.default.removeItem(at: layout.elementsURL(page.id))
        do {
            _ = try await repository.loadElementsForExport(
                notebookID: notebook.id,
                pageID: page.id
            )
            XCTFail("A missing persisted elements file must fail closed")
        } catch is NotebookRepositoryError {
            // Expected.
        }

        try await repository.saveInk(Data(), notebookID: notebook.id, pageID: page.id)
        let zeroByteInk = try await repository.loadInkForExport(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertNotNil(zeroByteInk)
        XCTAssertEqual(zeroByteInk, Data())
    }

    func testReplayInkReadHonorsRequestedAndOneMiBHardBoundaries() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(title: "Replay boundaries")
        let notebook = try await repository.createNotebook(
            title: "Replay boundaries",
            initialPage: page
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))

        let exact = Data(
            repeating: 0x5a,
            count: NotebookReplayReadLimits.maximumInkBytes
        )
        try exact.write(to: layout.inkURL(page.id), options: .atomic)
        let loaded = try await repository.loadInkForReplay(
            notebookID: notebook.id,
            pageID: page.id,
            maximumByteCount: NotebookReplayReadLimits.maximumInkBytes
        )
        XCTAssertEqual(loaded?.count, NotebookReplayReadLimits.maximumInkBytes)

        try resizeRegularFile(
            at: layout.inkURL(page.id),
            to: UInt64(NotebookReplayReadLimits.maximumInkBytes + 1)
        )
        do {
            _ = try await repository.loadInkForReplay(
                notebookID: notebook.id,
                pageID: page.id,
                maximumByteCount: Int.max
            )
            XCTFail("A caller cannot widen replay ink beyond one MiB")
        } catch NotebookRepositoryError.boundedReadLimitExceeded(_, let limit) {
            XCTAssertEqual(limit, NotebookReplayReadLimits.maximumInkBytes)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try Data(repeating: 0x3c, count: 65).write(
            to: layout.inkURL(page.id),
            options: .atomic
        )
        do {
            _ = try await repository.loadInkForReplay(
                notebookID: notebook.id,
                pageID: page.id,
                maximumByteCount: 64
            )
            XCTFail("A stricter caller limit must be enforced before allocation")
        } catch NotebookRepositoryError.boundedReadLimitExceeded(_, let limit) {
            XCTAssertEqual(limit, 64)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReplayInkReadDistinguishesMissingAndZeroByteFiles() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(title: "Replay empty ink")
        let notebook = try await repository.createNotebook(
            title: "Replay empty ink",
            initialPage: page
        )

        let missing = try await repository.loadInkForReplay(
            notebookID: notebook.id,
            pageID: page.id,
            maximumByteCount: NotebookReplayReadLimits.maximumInkBytes
        )
        XCTAssertNil(missing)

        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: layout.inkURL(page.id).path,
            contents: Data()
        ))
        let zero = try await repository.loadInkForReplay(
            notebookID: notebook.id,
            pageID: page.id,
            maximumByteCount: NotebookReplayReadLimits.maximumInkBytes
        )
        XCTAssertNotNil(zero)
        XCTAssertEqual(zero, Data())

        try FileManager.default.removeItem(at: layout.inkURL(page.id))
        try FileManager.default.createDirectory(
            at: layout.inkURL(page.id),
            withIntermediateDirectories: false
        )
        do {
            _ = try await repository.loadInkForReplay(
                notebookID: notebook.id,
                pageID: page.id,
                maximumByteCount: NotebookReplayReadLimits.maximumInkBytes
            )
            XCTFail("A non-regular replay ink source must fail closed")
        } catch is NotebookRepositoryError {
            // Expected.
        }
    }

    func testReplayInkReadRejectsFinalAndAncestorSymbolicLinks() async throws {
        let (repository, root) = try makeRepository()
        let page = PageDescriptor(title: "Replay links")
        let notebook = try await repository.createNotebook(
            title: "Replay links",
            initialPage: page
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        let externalInk = root.appendingPathComponent("replay-external-ink.data")
        try Data([1, 2, 3]).write(to: externalInk, options: .atomic)
        try FileManager.default.createSymbolicLink(
            at: layout.inkURL(page.id),
            withDestinationURL: externalInk
        )

        do {
            _ = try await repository.loadInkForReplay(
                notebookID: notebook.id,
                pageID: page.id,
                maximumByteCount: NotebookReplayReadLimits.maximumInkBytes
            )
            XCTFail("A replay ink symlink must fail closed")
        } catch is NotebookRepositoryError {
            // Expected.
        }

        try FileManager.default.removeItem(at: layout.pageURL(page.id))
        let externalPage = root.appendingPathComponent("replay-external-page", isDirectory: true)
        try FileManager.default.createDirectory(
            at: externalPage,
            withIntermediateDirectories: false
        )
        try Data([4, 5, 6]).write(
            to: externalPage.appendingPathComponent("ink.data"),
            options: .atomic
        )
        try FileManager.default.createSymbolicLink(
            at: layout.pageURL(page.id),
            withDestinationURL: externalPage
        )
        do {
            _ = try await repository.loadInkForReplay(
                notebookID: notebook.id,
                pageID: page.id,
                maximumByteCount: NotebookReplayReadLimits.maximumInkBytes
            )
            XCTFail("A replay ink ancestor symlink must fail closed")
        } catch is NotebookRepositoryError {
            // Expected.
        }
    }

    func testReplayInkReadDetectsGrowthAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesCoreReplayGrowth-\(UUID().uuidString)", isDirectory: true)
        let mutation = BoundedReadMutationController()
        let cancellationGate = BoundedReadCancellationGate()
        let repository = try FileNotebookRepository(rootURL: root) { point in
            try mutation.trigger(point)
            cancellationGate.trigger(point)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor(title: "Replay growth")
        let notebook = try await repository.createNotebook(
            title: "Replay growth",
            initialPage: page
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        try Data([0x01]).write(to: layout.inkURL(page.id), options: .atomic)
        mutation.configure(targetURL: layout.inkURL(page.id))

        do {
            _ = try await repository.loadInkForReplay(
                notebookID: notebook.id,
                pageID: page.id,
                maximumByteCount: NotebookReplayReadLimits.maximumInkBytes
            )
            XCTFail("Concurrent replay ink growth must fail")
        } catch NotebookRepositoryError.boundedReadLimitExceeded(_, let limit) {
            XCTAssertEqual(limit, NotebookReplayReadLimits.maximumInkBytes)
            XCTAssertTrue(mutation.didMutate)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try Data(repeating: 0x02, count: 1_024).write(
            to: layout.inkURL(page.id),
            options: .atomic
        )
        cancellationGate.arm()
        let cancelled = Task {
            try await repository.loadInkForReplay(
                notebookID: notebook.id,
                pageID: page.id,
                maximumByteCount: NotebookReplayReadLimits.maximumInkBytes
            )
        }
        XCTAssertEqual(cancellationGate.waitUntilPaused(), .success)
        cancelled.cancel()
        cancellationGate.release()
        do {
            _ = try await cancelled.value
            XCTFail("Replay ink reads must cooperate with cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testReplayTimelineReadPreservesUnknownAndStructuredPageMarks() async throws {
        let (repository, _) = try makeRepository()
        let inkPage = PageDescriptor(kind: .notebook, title: "Ink")
        var notebook = try await repository.createNotebook(
            title: "Replay timeline",
            initialPage: inkPage
        )
        let textPage = PageDescriptor(kind: .textDocument, title: "Text")
        notebook = try await repository.addPage(
            notebookID: notebook.id,
            page: textPage,
            at: nil
        )
        let sessionID = AudioSessionID()
        let recordingStart = Date(timeIntervalSinceReferenceDate: 92_000)
        let descriptor = AudioSessionDescriptor(
            id: sessionID,
            createdAt: recordingStart,
            modifiedAt: recordingStart.addingTimeInterval(10),
            recordingStartedAt: recordingStart,
            durationSeconds: 10,
            chunkFilenames: ["\(sessionID.description).m4a"],
            audioByteCount: 12,
            audioSHA256: String(repeating: "a", count: 64),
            timelineFilename: "\(sessionID.description).timeline.json"
        )
        let unknownPageID = PageID()
        let marks = [
            AudioTimelineMark(
                operationID: OperationID(),
                pageID: unknownPageID,
                timeSeconds: 1,
                createdAt: recordingStart.addingTimeInterval(1)
            ),
            AudioTimelineMark(
                operationID: OperationID(),
                pageID: textPage.id,
                timeSeconds: 2,
                createdAt: recordingStart.addingTimeInterval(2)
            ),
            AudioTimelineMark(
                operationID: OperationID(),
                pageID: inkPage.id,
                timeSeconds: 3,
                createdAt: recordingStart.addingTimeInterval(3)
            ),
        ]
        let timeline = AudioTimelineDocument(
            audioSessionID: sessionID,
            marks: marks,
            modifiedAt: recordingStart.addingTimeInterval(10)
        )
        notebook.audioSessions = [descriptor]
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        try repositoryJSONData(notebook).write(to: layout.manifestURL, options: .atomic)
        try repositoryJSONData(timeline).write(
            to: layout.audioTimelineURL(sessionID),
            options: .atomic
        )

        let loaded = try await repository.loadAudioTimelineForReplay(
            notebookID: notebook.id,
            sessionID: sessionID,
            maximumMarkCount: 3
        )
        XCTAssertEqual(loaded, timeline)

        let context = try await repository.beginNotebookExport(id: notebook.id)
        let capabilityLoaded = try await repository.loadAudioTimelineForReplay(
            session: context.session,
            sessionID: sessionID,
            maximumMarkCount: 3
        )
        XCTAssertEqual(capabilityLoaded, timeline)
        await repository.endNotebookExport(context.session)

        do {
            _ = try await repository.loadAudioTimelineForReplay(
                notebookID: notebook.id,
                sessionID: sessionID,
                maximumMarkCount: 2
            )
            XCTFail("A stricter requested mark limit must fail closed")
        } catch NotebookRepositoryError.invalidAudioSession(let id, _) {
            XCTAssertEqual(id, sessionID)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBoundedExportReadsRejectOversizedInkAndElementsBeforeDecode() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(title: "Limits")
        let notebook = try await repository.createNotebook(title: "Limits", initialPage: page)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))

        try resizeRegularFile(
            at: layout.inkURL(page.id),
            to: UInt64(NotebookExportReadLimits.maximumInkBytes + 1)
        )
        do {
            _ = try await repository.loadInkForExport(
                notebookID: notebook.id,
                pageID: page.id
            )
            XCTFail("Expected oversized ink to fail")
        } catch NotebookRepositoryError.boundedReadLimitExceeded(_, let limit) {
            XCTAssertEqual(limit, NotebookExportReadLimits.maximumInkBytes)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try resizeRegularFile(
            at: layout.elementsURL(page.id),
            to: UInt64(NotebookExportReadLimits.maximumCanvasElementBytes + 1)
        )
        do {
            _ = try await repository.loadElementsForExport(
                notebookID: notebook.id,
                pageID: page.id
            )
            XCTFail("Expected oversized elements to fail before JSON decode")
        } catch NotebookRepositoryError.boundedReadLimitExceeded(_, let limit) {
            XCTAssertEqual(limit, NotebookExportReadLimits.maximumCanvasElementBytes)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBoundedExportReadsRejectFinalAndAncestorSymbolicLinks() async throws {
        let (repository, root) = try makeRepository()
        let page = PageDescriptor(title: "Links")
        let notebook = try await repository.createNotebook(title: "Links", initialPage: page)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        let externalInk = root.appendingPathComponent("external-ink.data", isDirectory: false)
        try Data([1, 2, 3]).write(to: externalInk, options: .atomic)

        try FileManager.default.createSymbolicLink(
            at: layout.inkURL(page.id),
            withDestinationURL: externalInk
        )
        do {
            _ = try await repository.loadInkForExport(
                notebookID: notebook.id,
                pageID: page.id
            )
            XCTFail("Expected a final-component link to fail")
        } catch is NotebookRepositoryError {
            // Expected: a link is unsafe content, never the same as a missing ink file.
        }

        try FileManager.default.removeItem(at: layout.pageURL(page.id))
        let externalPage = root.appendingPathComponent("external-page", isDirectory: true)
        try FileManager.default.createDirectory(at: externalPage, withIntermediateDirectories: false)
        try Data([4, 5, 6]).write(
            to: externalPage.appendingPathComponent("ink.data", isDirectory: false)
        )
        try FileManager.default.createSymbolicLink(
            at: layout.pageURL(page.id),
            withDestinationURL: externalPage
        )
        do {
            _ = try await repository.loadInkForExport(
                notebookID: notebook.id,
                pageID: page.id
            )
            XCTFail("Expected an ancestor link to fail")
        } catch is NotebookRepositoryError {
            // Expected.
        }
    }

    func testBoundedElementDecodeEnforcesCountStructureAndManifestAssets() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(title: "Elements")
        let notebook = try await repository.createNotebook(title: "Elements", initialPage: page)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        let element = CanvasElement(
            frame: CanvasRect(x: 0, y: 0, width: 10, height: 10),
            content: .text(TextElement(text: "x"))
        )
        let oversized = (0...NotebookExportReadLimits.maximumCanvasElementCount).map { _ in
            CanvasElement(
                frame: element.frame,
                content: element.content
            )
        }
        try repositoryJSONData(oversized).write(to: layout.elementsURL(page.id), options: .atomic)
        do {
            _ = try await repository.loadElementsForExport(
                notebookID: notebook.id,
                pageID: page.id
            )
            XCTFail("Expected decoded count limit")
        } catch NotebookRepositoryError.canvasElementLimitExceeded(let limit) {
            XCTAssertEqual(limit, NotebookExportReadLimits.maximumCanvasElementCount)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let unknownAsset = AssetID(String(repeating: "f", count: 64))
        let unsafeAssetElement = CanvasElement(
            frame: element.frame,
            content: .image(ImageElement(assetID: unknownAsset))
        )
        try repositoryJSONData([unsafeAssetElement]).write(
            to: layout.elementsURL(page.id),
            options: .atomic
        )
        do {
            _ = try await repository.loadElementsForExport(
                notebookID: notebook.id,
                pageID: page.id
            )
            XCTFail("Expected an unknown canvas asset to fail closed")
        } catch is NotebookRepositoryError {
            // Expected.
        }
    }

    func testBoundedAssetReadRejectsLinksDigestMismatchAndDescriptorLimit() async throws {
        let (repository, root) = try makeRepository()
        let page = PageDescriptor(title: "Asset")
        var notebook = try await repository.createNotebook(title: "Asset", initialPage: page)
        let original = Data("owned background bytes".utf8)
        let descriptor = try await repository.importAsset(
            original,
            notebookID: notebook.id,
            mediaType: "application/octet-stream",
            originalFilename: "background.bin"
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        let loadedOriginal = try await repository.loadAssetForExport(
            notebookID: notebook.id,
            assetID: descriptor.id
        )
        XCTAssertEqual(loadedOriginal, original)

        let external = root.appendingPathComponent("external-background.bin", isDirectory: false)
        try original.write(to: external, options: .atomic)
        try FileManager.default.removeItem(at: layout.assetURL(descriptor.id))
        try FileManager.default.createSymbolicLink(
            at: layout.assetURL(descriptor.id),
            withDestinationURL: external
        )
        do {
            _ = try await repository.loadAssetForExport(
                notebookID: notebook.id,
                assetID: descriptor.id
            )
            XCTFail("Expected a linked asset to fail")
        } catch is NotebookRepositoryError {
            // Expected.
        }

        try FileManager.default.removeItem(at: layout.assetURL(descriptor.id))
        var tampered = original
        tampered[0] ^= 0xff
        try tampered.write(to: layout.assetURL(descriptor.id), options: .atomic)
        do {
            _ = try await repository.loadAssetForExport(
                notebookID: notebook.id,
                assetID: descriptor.id
            )
            XCTFail("Expected an asset digest mismatch")
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(error, .invalidAsset(descriptor.id))
        }

        try original.write(to: layout.assetURL(descriptor.id), options: .atomic)
        notebook = try await repository.openNotebook(id: notebook.id)
        let assetIndex = try XCTUnwrap(notebook.assets.firstIndex(where: { $0.id == descriptor.id }))
        notebook.assets[assetIndex].byteCount = Int64(
            NotebookExportReadLimits.maximumBackgroundAssetBytes + 1
        )
        try repositoryJSONData(notebook).write(to: layout.manifestURL, options: .atomic)
        do {
            _ = try await repository.loadAssetForExport(
                notebookID: notebook.id,
                assetID: descriptor.id
            )
            XCTFail("Expected the descriptor byte limit")
        } catch NotebookRepositoryError.boundedReadLimitExceeded(_, let limit) {
            XCTAssertEqual(limit, NotebookExportReadLimits.maximumBackgroundAssetBytes)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCanvasAssetBatchReadIsOwnedBoundedAndIntegrityChecked() async throws {
        let (repository, root) = try makeRepository()
        var notebook = try await repository.createNotebook(
            title: "Canvas assets",
            initialPage: PageDescriptor(title: "Canvas")
        )
        let firstData = Data("first canvas image".utf8)
        let secondData = Data("second canvas image".utf8)
        let first = try await repository.importAsset(
            firstData,
            notebookID: notebook.id,
            mediaType: "image/png",
            originalFilename: "first.png"
        )
        let second = try await repository.importAsset(
            secondData,
            notebookID: notebook.id,
            mediaType: "image/png",
            originalFilename: "second.png"
        )
        let loaded = try await repository.loadCanvasAssetsForExport(
            notebookID: notebook.id,
            assetIDs: [second.id, first.id]
        )
        XCTAssertEqual(loaded, [second.id: secondData, first.id: firstData])

        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        let external = root.appendingPathComponent("external-canvas.png")
        try firstData.write(to: external, options: .atomic)
        try FileManager.default.removeItem(at: layout.assetURL(first.id))
        try FileManager.default.createSymbolicLink(
            at: layout.assetURL(first.id),
            withDestinationURL: external
        )
        do {
            _ = try await repository.loadCanvasAssetsForExport(
                notebookID: notebook.id,
                assetIDs: [first.id]
            )
            XCTFail("Expected a linked canvas asset to fail closed")
        } catch is NotebookRepositoryError {
            // Expected.
        }

        try FileManager.default.removeItem(at: layout.assetURL(first.id))
        var tampered = firstData
        tampered[0] ^= 0xff
        try tampered.write(to: layout.assetURL(first.id), options: .atomic)
        do {
            _ = try await repository.loadCanvasAssetsForExport(
                notebookID: notebook.id,
                assetIDs: [first.id]
            )
            XCTFail("Expected a digest-mismatched canvas asset to fail")
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(error, .invalidAsset(first.id))
        }

        try firstData.write(to: layout.assetURL(first.id), options: .atomic)
        notebook = try await repository.openNotebook(id: notebook.id)
        let firstIndex = try XCTUnwrap(notebook.assets.firstIndex(where: { $0.id == first.id }))
        notebook.assets[firstIndex].byteCount = Int64(
            NotebookExportReadLimits.maximumCanvasAssetSourceBytes + 1
        )
        try repositoryJSONData(notebook).write(to: layout.manifestURL, options: .atomic)
        do {
            _ = try await repository.loadCanvasAssetsForExport(
                notebookID: notebook.id,
                assetIDs: [first.id]
            )
            XCTFail("Expected the per-canvas-asset source limit")
        } catch NotebookRepositoryError.boundedReadLimitExceeded(_, let limit) {
            XCTAssertEqual(limit, NotebookExportReadLimits.maximumCanvasAssetSourceBytes)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCanvasAssetBatchPreflightsAggregateDescriptorBytesBeforeReading() async throws {
        let (repository, _) = try makeRepository()
        var notebook = try await repository.createNotebook(
            title: "Canvas aggregate",
            initialPage: nil
        )
        var assetIDs = [AssetID]()
        for index in 0..<5 {
            let descriptor = try await repository.importAsset(
                Data("asset-\(index)".utf8),
                notebookID: notebook.id,
                mediaType: "image/png",
                originalFilename: "\(index).png"
            )
            assetIDs.append(descriptor.id)
        }
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        notebook = try await repository.openNotebook(id: notebook.id)
        for index in notebook.assets.indices {
            notebook.assets[index].byteCount = 60 * 1_024 * 1_024
        }
        try repositoryJSONData(notebook).write(to: layout.manifestURL, options: .atomic)

        do {
            _ = try await repository.loadCanvasAssetsForExport(
                notebookID: notebook.id,
                assetIDs: assetIDs
            )
            XCTFail("Expected the per-page aggregate source limit before file reads")
        } catch NotebookRepositoryError.boundedReadLimitExceeded(let path, let limit) {
            XCTAssertEqual(path, "canvas-assets")
            XCTAssertEqual(limit, NotebookExportReadLimits.maximumCanvasAssetSourceBytesPerPage)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBoundedOpenNotebookForExportRejectsDuplicateAndExcessPages() async throws {
        let (repository, _) = try makeRepository()
        var notebook = try await repository.createNotebook(
            title: "Bounded manifest",
            initialPage: PageDescriptor(title: "First")
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        let validManifest = notebook
        let duplicatePage = try XCTUnwrap(notebook.pages.first)
        notebook.pages.append(duplicatePage)
        try repositoryJSONData(notebook).write(to: layout.manifestURL, options: .atomic)
        do {
            _ = try await repository.openNotebookForExport(id: notebook.id)
            XCTFail("Expected duplicate page identifiers to fail closed")
        } catch is NotebookRepositoryError {
            // Expected.
        }

        notebook = validManifest
        notebook.pages = (0...NotebookExportReadLimits.maximumNotebookPageCount).map { index in
            PageDescriptor(title: "Page \(index)")
        }
        try repositoryJSONData(notebook).write(to: layout.manifestURL, options: .atomic)
        do {
            _ = try await repository.openNotebookForExport(id: notebook.id)
            XCTFail("Expected the bounded manifest page-count limit")
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(error, .corruptedFile("manifest.json"))
        }
    }

    func testExportSessionDecodesManifestOnceAndReportsExactPersistedElementBytes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesCoreExportSession-\(UUID().uuidString)", isDirectory: true)
        let counter = ExportManifestDecodeCounter()
        let repository = try FileNotebookRepository(rootURL: root) { point in
            counter.observe(point)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor(title: "Session page")
        let notebook = try await repository.createNotebook(
            title: "One manifest decode",
            initialPage: page
        )
        let element = CanvasElement(
            frame: CanvasRect(x: 2, y: 3, width: 40, height: 20),
            content: .text(TextElement(text: "persisted bytes"))
        )
        try await repository.saveInk(Data([1, 2, 3]), notebookID: notebook.id, pageID: page.id)
        try await repository.saveElements([element], notebookID: notebook.id, pageID: page.id)
        let assetData = Data("session asset".utf8)
        let asset = try await repository.importAsset(
            assetData,
            notebookID: notebook.id,
            mediaType: "image/png",
            originalFilename: "session.png"
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        let persistedElementByteCount = try Data(contentsOf: layout.elementsURL(page.id)).count

        let context = try await repository.beginNotebookExport(id: notebook.id)
        XCTAssertEqual(counter.count(for: notebook.id), 1)
        let loadedInk = try await repository.loadInkForExport(
            session: context.session,
            pageID: page.id
        )
        XCTAssertEqual(loadedInk, Data([1, 2, 3]))
        let firstReplayInk = try await repository.loadInkForReplay(
            session: context.session,
            pageID: page.id,
            maximumByteCount: 128
        )
        let secondReplayInk = try await repository.loadInkForReplay(
            session: context.session,
            pageID: page.id,
            maximumByteCount: 128
        )
        XCTAssertEqual(firstReplayInk, Data([1, 2, 3]))
        XCTAssertEqual(secondReplayInk, Data([1, 2, 3]))
        XCTAssertEqual(
            counter.count(for: notebook.id),
            1,
            "Replay cache misses must not reparse the bounded manifest body."
        )
        let loadedElements = try await repository.loadElementsForExport(
            session: context.session,
            pageID: page.id
        )
        XCTAssertEqual(loadedElements.elements, [element])
        XCTAssertEqual(loadedElements.encodedByteCount, persistedElementByteCount)
        let loadedBackground = try await repository.loadAssetForExport(
            session: context.session,
            assetID: asset.id
        )
        XCTAssertEqual(loadedBackground, assetData)
        let loadedCanvasAssets = try await repository.loadCanvasAssetsForExport(
            session: context.session,
            assetIDs: [asset.id]
        )
        XCTAssertEqual(loadedCanvasAssets, [asset.id: assetData])
        let validatedManifest = try await repository.validateNotebookExportSession(context.session)
        XCTAssertEqual(validatedManifest, context.manifest)
        XCTAssertEqual(counter.count(for: notebook.id), 1)

        await repository.endNotebookExport(context.session)
        let endedCount = await repository.activeNotebookExportSessionCount()
        XCTAssertEqual(endedCount, 0)
        do {
            _ = try await repository.validateNotebookExportSession(context.session)
            XCTFail("An ended export session must not remain usable")
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(error, .invalidExportSession)
        }
    }

    func testExportSessionFailsClosedForManifestMutationReplacementRenameAndRepositoryWrite() async throws {
        let (repository, root) = try makeRepository()
        let page = PageDescriptor(title: "Identity")
        let notebook = try await repository.createNotebook(
            title: "Identity fences",
            initialPage: page
        )
        let packageURL = repository.packageURL(for: notebook.id)
        let layout = NotebookPackageLayout(packageURL: packageURL)
        let originalManifest = try Data(contentsOf: layout.manifestURL)

        let inPlace = try await repository.beginNotebookExport(id: notebook.id)
        let handle = try FileHandle(forWritingTo: layout.manifestURL)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: originalManifest)
        try handle.synchronize()
        try handle.close()
        await assertInvalidExportSession(repository, inPlace.session)

        let replaced = try await repository.beginNotebookExport(id: notebook.id)
        try originalManifest.write(to: layout.manifestURL, options: .atomic)
        await assertInvalidExportSession(repository, replaced.session)

        let renamed = try await repository.beginNotebookExport(id: notebook.id)
        let movedPackage = root.appendingPathComponent("moved.notepkg", isDirectory: true)
        try FileManager.default.moveItem(at: packageURL, to: movedPackage)
        await assertInvalidExportSession(repository, renamed.session)
        try FileManager.default.moveItem(at: movedPackage, to: packageURL)

        let repositoryMutation = try await repository.beginNotebookExport(id: notebook.id)
        _ = try await repository.renameNotebook(id: notebook.id, title: "Changed")
        await assertInvalidExportSession(repository, repositoryMutation.session)
        let finalCount = await repository.activeNotebookExportSessionCount()
        XCTAssertEqual(finalCount, 0)
    }

    func testExportSessionPostReadFenceRejectsManifestReplacementDuringContentRead() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesCoreExportPostFence-\(UUID().uuidString)", isDirectory: true)
        let mutation = ExportManifestPostReadMutation()
        let repository = try FileNotebookRepository(rootURL: root) { point in
            try mutation.trigger(point)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor(title: "Post fence")
        let notebook = try await repository.createNotebook(
            title: "Post-read identity",
            initialPage: page
        )
        try await repository.saveInk(
            Data(repeating: 0x5a, count: 128 * 1_024),
            notebookID: notebook.id,
            pageID: page.id
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        let context = try await repository.beginNotebookExport(id: notebook.id)
        mutation.configure(
            manifestURL: layout.manifestURL,
            manifestData: try Data(contentsOf: layout.manifestURL)
        )

        do {
            _ = try await repository.loadInkForExport(
                session: context.session,
                pageID: page.id
            )
            XCTFail("A manifest replacement during the content read must fail the post fence")
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(error, .invalidExportSession)
        }
        XCTAssertTrue(mutation.didMutate)
        let activeCount = await repository.activeNotebookExportSessionCount()
        XCTAssertEqual(activeCount, 0)

        let replayContext = try await repository.beginNotebookExport(id: notebook.id)
        mutation.configure(
            manifestURL: layout.manifestURL,
            manifestData: try Data(contentsOf: layout.manifestURL)
        )
        do {
            _ = try await repository.loadInkForReplay(
                session: replayContext.session,
                pageID: page.id,
                maximumByteCount: NotebookReplayReadLimits.maximumInkBytes
            )
            XCTFail("Replay must reject a manifest replacement during its bounded ink read")
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(error, .invalidExportSession)
        }
        let replayActiveCount = await repository.activeNotebookExportSessionCount()
        XCTAssertEqual(replayActiveCount, 0)
    }

    func testExportSessionsAreIsolatedAndCancellationDoesNotLeakState() async throws {
        let (repository, _) = try makeRepository()
        let first = try await repository.createNotebook(
            title: "First",
            initialPage: PageDescriptor()
        )
        let second = try await repository.createNotebook(
            title: "Second",
            initialPage: PageDescriptor()
        )
        let firstA = try await repository.beginNotebookExport(id: first.id)
        let firstB = try await repository.beginNotebookExport(id: first.id)
        let secondA = try await repository.beginNotebookExport(id: second.id)
        let initialCount = await repository.activeNotebookExportSessionCount()
        XCTAssertEqual(initialCount, 3)

        await repository.endNotebookExport(firstA.session)
        let afterFirstEndCount = await repository.activeNotebookExportSessionCount()
        XCTAssertEqual(afterFirstEndCount, 2)
        _ = try await repository.validateNotebookExportSession(firstB.session)
        _ = try await repository.validateNotebookExportSession(secondA.session)

        let foreign = NotebookExportSession(
            id: firstB.session.id,
            notebookID: second.id
        )
        await assertInvalidExportSession(repository, foreign)
        _ = try await repository.validateNotebookExportSession(firstB.session)
        _ = try await repository.validateNotebookExportSession(secondA.session)

        await repository.endNotebookExport(firstB.session)
        await repository.endNotebookExport(secondA.session)
        let afterAllEndedCount = await repository.activeNotebookExportSessionCount()
        XCTAssertEqual(afterAllEndedCount, 0)

        let gate = AsyncReleaseGate()
        let cancelled = Task {
            await gate.wait()
            return try await repository.beginNotebookExport(id: first.id)
        }
        cancelled.cancel()
        await gate.release()
        do {
            _ = try await cancelled.value
            XCTFail("A pre-cancelled begin must stop before registering a session")
        } catch is CancellationError {
            // Expected.
        }
        let afterCancellationCount = await repository.activeNotebookExportSessionCount()
        XCTAssertEqual(afterCancellationCount, 0)
    }

    func testExportAssetDigestHonorsPreexistingAndMidHashCancellation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesCoreAssetDigest-\(UUID().uuidString)", isDirectory: true)
        let digestGate = ExportAssetDigestCancellationGate()
        let repository = try FileNotebookRepository(rootURL: root) { point in
            digestGate.trigger(point)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let notebook = try await repository.createNotebook(
            title: "Digest cancellation",
            initialPage: nil
        )
        let data = Data(repeating: 0xa5, count: 3 * 1_024 * 1_024 + 17)
        let descriptor = try await repository.importAsset(
            data,
            notebookID: notebook.id,
            mediaType: "application/octet-stream",
            originalFilename: "large.bin"
        )

        let preStartGate = AsyncReleaseGate()
        let preStartEntered = DispatchSemaphore(value: 0)
        let preCancelled = Task {
            preStartEntered.signal()
            await preStartGate.wait()
            return try await repository.loadAssetForExport(
                notebookID: notebook.id,
                assetID: descriptor.id
            )
        }
        XCTAssertEqual(preStartEntered.wait(timeout: .now() + 2), .success)
        preCancelled.cancel()
        await preStartGate.release()
        do {
            _ = try await preCancelled.value
            XCTFail("Expected a pre-cancelled export asset read to stop")
        } catch is CancellationError {
            // Expected.
        }

        digestGate.arm()
        let midHashCancelled = Task {
            try await repository.loadAssetForExport(
                notebookID: notebook.id,
                assetID: descriptor.id
            )
        }
        XCTAssertEqual(digestGate.waitUntilPaused(), .success)
        midHashCancelled.cancel()
        digestGate.release()
        do {
            _ = try await midHashCancelled.value
            XCTFail("Expected cancellation between SHA-256 chunks")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testBoundedReaderDetectsGrowthAndCooperativeCancellation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesCoreGrowthTests-\(UUID().uuidString)", isDirectory: true)
        let mutation = BoundedReadMutationController()
        let cancellationGate = BoundedReadCancellationGate()
        let repository = try FileNotebookRepository(rootURL: root) { point in
            try mutation.trigger(point)
            cancellationGate.trigger(point)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let page = PageDescriptor(title: "Growth")
        let notebook = try await repository.createNotebook(title: "Growth", initialPage: page)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        try Data([0x01]).write(to: layout.inkURL(page.id), options: .atomic)
        mutation.configure(targetURL: layout.inkURL(page.id))

        do {
            _ = try await repository.loadInkForExport(
                notebookID: notebook.id,
                pageID: page.id
            )
            XCTFail("Expected concurrent growth to be detected")
        } catch NotebookRepositoryError.boundedReadLimitExceeded(_, let limit) {
            XCTAssertEqual(limit, NotebookExportReadLimits.maximumInkBytes)
            XCTAssertTrue(mutation.didMutate)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try Data(repeating: 0x02, count: 1_024).write(
            to: layout.inkURL(page.id),
            options: .atomic
        )
        cancellationGate.arm()
        let cancelled = Task {
            return try await repository.loadInkForExport(
                notebookID: notebook.id,
                pageID: page.id
            )
        }
        XCTAssertEqual(cancellationGate.waitUntilPaused(), .success)
        cancelled.cancel()
        cancellationGate.release()
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testBoundedExportManifestReadRejectsOversizedManifestBeforeDecode() async throws {
        let (repository, root) = try makeRepository()
        let page = PageDescriptor(title: "Manifest")
        let notebook = try await repository.createNotebook(title: "Manifest", initialPage: page)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        let originalManifest = try Data(contentsOf: layout.manifestURL)
        try resizeRegularFile(
            at: layout.manifestURL,
            to: UInt64(16 * 1_024 * 1_024 + 1)
        )

        do {
            _ = try await repository.loadInkForExport(
                notebookID: notebook.id,
                pageID: page.id
            )
            XCTFail("Expected the oversized manifest to fail before decode")
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(error, .corruptedFile("manifest.json"))
        }

        try originalManifest.write(to: layout.manifestURL, options: .atomic)
        let externalManifest = root.appendingPathComponent("external-manifest.json")
        try originalManifest.write(to: externalManifest, options: .atomic)
        try FileManager.default.removeItem(at: layout.manifestURL)
        try FileManager.default.createSymbolicLink(
            at: layout.manifestURL,
            withDestinationURL: externalManifest
        )
        do {
            _ = try await repository.loadInkForExport(
                notebookID: notebook.id,
                pageID: page.id
            )
            XCTFail("Expected a linked manifest to fail")
        } catch is NotebookRepositoryError {
            // Expected.
        }
    }

    func testBoundedExportReadsRejectPendingOrLinkedTransactionDirectory() async throws {
        let (repository, root) = try makeRepository()
        let page = PageDescriptor(title: "Transaction")
        let notebook = try await repository.createNotebook(
            title: "Transaction",
            initialPage: page
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        let pending = layout.transactionsURL.appendingPathComponent("pending-entry")
        XCTAssertTrue(FileManager.default.createFile(atPath: pending.path, contents: Data()))

        do {
            _ = try await repository.loadInkForExport(
                notebookID: notebook.id,
                pageID: page.id
            )
            XCTFail("Expected pending transaction state to fail closed")
        } catch let error as NotebookRepositoryError {
            guard case .malformedPackage = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        try FileManager.default.removeItem(at: layout.transactionsURL)
        let externalTransactions = root.appendingPathComponent(
            "external-transactions",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: externalTransactions,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: layout.transactionsURL,
            withDestinationURL: externalTransactions
        )
        do {
            _ = try await repository.loadInkForExport(
                notebookID: notebook.id,
                pageID: page.id
            )
            XCTFail("Expected a linked transaction directory to fail")
        } catch is NotebookRepositoryError {
            // Expected.
        }
    }

    func testAtomicCommitsNeverExposePartialJSONOrTemporaryFiles() async throws {
        let (repository, _) = try makeRepository()
        let manifest = try await repository.createNotebook(title: "Version 0", initialPage: PageDescriptor())

        for version in 1...30 {
            _ = try await repository.renameNotebook(id: manifest.id, title: "Version \(version)")
            let opened = try await repository.openNotebook(id: manifest.id)
            XCTAssertEqual(opened.title, "Version \(version)")
            XCTAssertEqual(opened.revision, Int64(version + 1))
        }

        let package = repository.packageURL(for: manifest.id)
        let enumerator = FileManager.default.enumerator(at: package, includingPropertiesForKeys: nil, options: [])
        var temporaryURLs: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "tmp" { temporaryURLs.append(url) }
        }
        XCTAssertTrue(temporaryURLs.isEmpty)
        let validation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(validation.isValid)
    }

    func testOperationLogFailureReturnsCommittedResultAndRecoveryFinalizesJournal() async throws {
        let (initialRepository, root) = try makeRepository()
        let created = try await initialRepository.createNotebook(title: "Before", initialPage: PageDescriptor())
        let failures = OneShotStorageFailure(.beforeOperationLogWrite)
        let repository = try FileNotebookRepository(rootURL: root) { point in
            try failures.trigger(point)
        }

        let renamed = try await repository.renameNotebook(id: created.id, title: "After")
        XCTAssertEqual(renamed.title, "After")
        XCTAssertEqual(renamed.revision, 2)

        let pending = try await repository.validateNotebook(id: created.id)
        XCTAssertTrue(pending.issues.contains(where: { $0.kind == .pendingTransaction }))
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))
        XCTAssertEqual(try operationJSONCount(in: layout), 1, "The failed append must remain recoverable, not masquerade as a completed log write.")
        let transactionDirectory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: layout.transactionsURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).first
        )
        try Data("damaged-current-journal".utf8).write(
            to: transactionDirectory.appendingPathComponent("transaction.json")
        )

        // A fresh repository models the process being relaunched after the failure.
        let relaunched = try FileNotebookRepository(rootURL: root)
        let recovery = try await relaunched.recoverNotebook(id: created.id)
        XCTAssertTrue(recovery.actions.contains(.restoredTransactionJournal))
        XCTAssertTrue(recovery.actions.contains(.finalizedCommittedTransaction))
        XCTAssertEqual(recovery.manifest.title, "After")
        XCTAssertEqual(recovery.manifest.revision, 2)
        let recoveredOperations = try await relaunched.operationLog(notebookID: created.id)
        XCTAssertEqual(recoveredOperations.map(\.kind), [.createNotebook, .renameNotebook])
        XCTAssertTrue(recovery.validation.isValid, "Unexpected issues: \(recovery.validation.issues)")
        XCTAssertEqual(try transactionDirectoryCount(in: layout), 0)
    }

    func testCrashWindowAfterManifestCommitUsesPreparedJournalToRollForward() async throws {
        let (initialRepository, root) = try makeRepository()
        let created = try await initialRepository.createNotebook(title: "Before crash", initialPage: nil)
        let failures = OneShotStorageFailure(.beforeTransactionPhaseWrite)
        let repository = try FileNotebookRepository(rootURL: root) { point in
            try failures.trigger(point)
        }

        let renamed = try await repository.renameNotebook(id: created.id, title: "Committed before crash")
        XCTAssertEqual(renamed.revision, 2)
        let pending = try await repository.validateNotebook(id: created.id)
        XCTAssertTrue(pending.issues.contains(where: {
            $0.kind == .pendingTransaction && $0.detail.contains("prepared")
        }))

        let relaunched = try FileNotebookRepository(rootURL: root)
        let recovery = try await relaunched.recoverNotebook(id: created.id)
        XCTAssertTrue(recovery.actions.contains(.finalizedCommittedTransaction))
        XCTAssertEqual(recovery.manifest.title, "Committed before crash")
        XCTAssertEqual(recovery.manifest.revision, 2)
        let recoveredOperations = try await relaunched.operationLog(notebookID: created.id)
        XCTAssertEqual(recoveredOperations.map(\.sequence), [1, 2])
        XCTAssertTrue(recovery.validation.isValid)
    }

    func testFailureBeforeManifestCommitRollsBackFilesAndThrows() async throws {
        let (initialRepository, root) = try makeRepository()
        let page = PageDescriptor()
        let created = try await initialRepository.createNotebook(title: "Stable", initialPage: page)
        let originalInk = Data("original".utf8)
        try await initialRepository.saveInk(originalInk, notebookID: created.id, pageID: page.id)
        let failures = OneShotStorageFailure(.beforeStateWrite(relativePath: "manifest.json"))
        let repository = try FileNotebookRepository(rootURL: root) { point in
            try failures.trigger(point)
        }

        do {
            try await repository.saveInk(Data("must rollback".utf8), notebookID: created.id, pageID: page.id)
            XCTFail("A pre-commit storage failure must be reported to the caller.")
        } catch is InjectedStorageFailure {
            // Expected.
        } catch {
            throw error
        }

        let reopened = try await repository.openNotebook(id: created.id)
        let reopenedInk = try await repository.loadInk(notebookID: created.id, pageID: page.id)
        let operations = try await repository.operationLog(notebookID: created.id)
        let validation = try await repository.validateNotebook(id: created.id)
        XCTAssertEqual(reopened.revision, 2)
        XCTAssertEqual(reopenedInk, originalInk)
        XCTAssertEqual(operations.map(\.sequence), [1, 2])
        XCTAssertTrue(validation.isValid)
    }

    func testExportSnapshotIsValidatedAndIndependentFromLaterMutations() async throws {
        let (repository, root) = try makeRepository()
        let page = PageDescriptor(title: "Snapshot page")
        let created = try await repository.createNotebook(title: "Snapshot title", initialPage: page)
        let ink = Data("snapshot ink".utf8)
        try await repository.saveInk(ink, notebookID: created.id, pageID: page.id)

        let exportRoot = root.deletingLastPathComponent()
            .appendingPathComponent("NotesCoreSnapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: exportRoot) }
        let destination = exportRoot
            .appendingPathComponent(created.id.description, isDirectory: false)
            .appendingPathExtension(NotebookPackageLayout.packageExtension)

        let exported = try await repository.exportSnapshot(id: created.id, to: destination)
        XCTAssertEqual(exported.standardizedFileURL, destination.standardizedFileURL)
        _ = try await repository.renameNotebook(id: created.id, title: "Changed after export")
        try await repository.saveInk(Data("new ink".utf8), notebookID: created.id, pageID: page.id)

        let snapshotRepository = try FileNotebookRepository(rootURL: exportRoot)
        let snapshotManifest = try await snapshotRepository.openNotebook(id: created.id)
        let snapshotInk = try await snapshotRepository.loadInk(notebookID: created.id, pageID: page.id)
        let snapshotValidation = try await snapshotRepository.validateNotebook(id: created.id)
        XCTAssertEqual(snapshotManifest.title, "Snapshot title")
        XCTAssertEqual(snapshotManifest.revision, 2)
        XCTAssertEqual(snapshotInk, ink)
        XCTAssertTrue(snapshotValidation.isValid)

        let livePackage = repository.packageURL(for: created.id)
        do {
            _ = try await repository.exportSnapshot(
                id: created.id,
                to: livePackage.appendingPathComponent("nested.notepkg", isDirectory: true)
            )
            XCTFail("A snapshot destination inside the live package must be rejected.")
        } catch {
            XCTAssertEqual(error as? NotebookRepositoryError, .invalidSnapshotDestination)
        }
    }

    func testStructuredPageContentRoundTripsAndRollsBackAtomically() async throws {
        let (initialRepository, root) = try makeRepository()
        let textPage = PageDescriptor(kind: .textDocument, title: "Outline")
        let created = try await initialRepository.createNotebook(
            title: "Structured",
            initialPage: textPage
        )
        let initialContent = try await initialRepository.loadPageContent(
            notebookID: created.id,
            pageID: textPage.id
        )
        XCTAssertEqual(initialContent, .textDocument(TextDocument()))

        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let document = TextDocument(blocks: [
            TextBlock(
                style: .heading1,
                text: "Project",
                createdAt: timestamp,
                modifiedAt: timestamp
            ),
            TextBlock(
                style: .checklist,
                text: "Ship a reliable document model",
                isChecked: false,
                createdAt: timestamp,
                modifiedAt: timestamp
            )
        ])
        try await initialRepository.savePageContent(
            .textDocument(document),
            notebookID: created.id,
            pageID: textPage.id
        )
        let savedContent = try await initialRepository.loadPageContent(
            notebookID: created.id,
            pageID: textPage.id
        )
        let savedManifest = try await initialRepository.openNotebook(id: created.id)
        let savedOperations = try await initialRepository.operationLog(notebookID: created.id)
        XCTAssertEqual(savedContent, .textDocument(document))
        XCTAssertEqual(savedManifest.revision, 2)
        XCTAssertEqual(savedOperations.map(\.kind), [.createNotebook, .savePageContent])

        do {
            try await initialRepository.savePageContent(
                .studySet(StudySet()),
                notebookID: created.id,
                pageID: textPage.id
            )
            XCTFail("A page must reject structured content for another page kind.")
        } catch {
            XCTAssertEqual(
                error as? NotebookRepositoryError,
                .pageContentTypeMismatch(pageID: textPage.id, expected: .textDocument, actual: .studySet)
            )
        }
        let manifestAfterRejection = try await initialRepository.openNotebook(id: created.id)
        XCTAssertEqual(manifestAfterRejection.revision, 2)

        do {
            try await initialRepository.savePageContent(
                .textDocument(TextDocument(schemaVersion: 99)),
                notebookID: created.id,
                pageID: textPage.id
            )
            XCTFail("An unsupported structured-content schema must be rejected.")
        } catch let error as NotebookRepositoryError {
            guard case .invalidPageContent(let pageID, _) = error else {
                XCTFail("Expected invalid page content, got \(error).")
                return
            }
            XCTAssertEqual(pageID, textPage.id)
        } catch {
            throw error
        }
        let manifestAfterInvalidContent = try await initialRepository.openNotebook(id: created.id)
        XCTAssertEqual(manifestAfterInvalidContent.revision, 2)

        let failures = OneShotStorageFailure(.beforeStateWrite(relativePath: "manifest.json"))
        let failingRepository = try FileNotebookRepository(rootURL: root) { point in
            try failures.trigger(point)
        }
        let replacement = TextDocument(blocks: [
            TextBlock(style: .body, text: "This transaction must roll back.")
        ])
        do {
            try await failingRepository.savePageContent(
                .textDocument(replacement),
                notebookID: created.id,
                pageID: textPage.id
            )
            XCTFail("A pre-commit content failure must be reported.")
        } catch is InjectedStorageFailure {
            // Expected.
        } catch {
            throw error
        }
        let rolledBackContent = try await failingRepository.loadPageContent(
            notebookID: created.id,
            pageID: textPage.id
        )
        let rolledBackManifest = try await failingRepository.openNotebook(id: created.id)
        let validation = try await failingRepository.validateNotebook(id: created.id)
        XCTAssertEqual(rolledBackContent, .textDocument(document))
        XCTAssertEqual(rolledBackManifest.revision, 2)
        XCTAssertTrue(validation.isValid)
    }

    func testPendingStructuredTransactionRejectsOversizedStagedContent() async throws {
        let (initialRepository, root) = try makeRepository()
        let page = PageDescriptor(kind: .textDocument, title: "Pending")
        let created = try await initialRepository.createNotebook(
            title: "Pending content",
            initialPage: page
        )
        let failures = OneShotStorageFailure(.beforeTransactionPhaseWrite)
        let repository = try FileNotebookRepository(rootURL: root) { point in
            try failures.trigger(point)
        }
        try await repository.savePageContent(
            .textDocument(TextDocument(blocks: [TextBlock(text: "Committed")])),
            notebookID: created.id,
            pageID: page.id
        )

        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))
        let transactionDirectory = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: layout.transactionsURL,
                includingPropertiesForKeys: [.isDirectoryKey]
            ).first
        )
        let stagedContent = transactionDirectory
            .appendingPathComponent("staged", isDirectory: true)
            .appendingPathComponent("0000.data")
        let oversized = Data(repeating: 0x20, count: 16 * 1_024 * 1_024 + 1)
        try oversized.write(to: stagedContent, options: .atomic)

        let relaunched = try FileNotebookRepository(rootURL: root)
        do {
            _ = try await relaunched.recoverNotebook(id: created.id)
            XCTFail("Recovery must reject oversized staged structured content.")
        } catch is NotebookRepositoryError {
            // Expected.
        }
        let manifestAfterFailure = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: layout.manifestURL)) as? [String: Any]
        )
        XCTAssertEqual(manifestAfterFailure["revision"] as? NSNumber, NSNumber(value: 2))
        XCTAssertEqual(try Data(contentsOf: stagedContent).count, oversized.count)
        XCTAssertLessThan(
            try Data(contentsOf: layout.contentURL(page.id)).count,
            oversized.count
        )
    }

    func testStudyContentRoundTripsWithSchedulerCompatibleProgress() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(kind: .studySet, title: "Vocabulary")
        let created = try await repository.createNotebook(title: "Study", initialPage: page)
        let card = StudyCard(prompt: "bonjour", answer: "hello", tags: ["French"])
        let dueAt = Date(timeIntervalSince1970: 1_800_000_000)
        let content = StudySet(
            cards: [card],
            progress: [
                StudyCardProgress(
                    cardID: card.id,
                    repetitions: 2,
                    lapses: 1,
                    intervalDays: 6,
                    easeFactor: 2.35,
                    dueAt: dueAt,
                    lastReviewedAt: dueAt.addingTimeInterval(-86_400)
                )
            ]
        )

        try await repository.savePageContent(
            .studySet(content),
            notebookID: created.id,
            pageID: page.id
        )

        let loadedContent = try await repository.loadPageContent(
            notebookID: created.id,
            pageID: page.id
        )
        let validation = try await repository.validateNotebook(id: created.id)
        XCTAssertEqual(loadedContent, .studySet(content))
        XCTAssertTrue(validation.isValid)
    }

    func testRecoveryRepairsStructuredContentWithoutDiscardingCorruptSources() async throws {
        let (repository, _) = try makeRepository()
        let missingPage = PageDescriptor(kind: .textDocument, title: "Missing")
        let created = try await repository.createNotebook(title: "Recovery", initialPage: missingPage)
        let mismatchedPage = PageDescriptor(kind: .studySet, title: "Mismatch")
        _ = try await repository.addPage(notebookID: created.id, page: mismatchedPage, at: nil)
        let unreadablePage = PageDescriptor(kind: .textDocument, title: "Unreadable")
        _ = try await repository.addPage(notebookID: created.id, page: unreadablePage, at: nil)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))

        try FileManager.default.removeItem(at: layout.contentURL(missingPage.id))
        let mismatchedData = try JSONEncoder().encode(PageContent.textDocument(TextDocument()))
        try mismatchedData.write(to: layout.contentURL(mismatchedPage.id), options: .atomic)
        try Data("not-json".utf8).write(to: layout.contentURL(unreadablePage.id), options: .atomic)

        let before = try await repository.validateNotebook(id: created.id)
        XCTAssertTrue(before.issues.contains(where: { $0.kind == .missingPageContent }))
        XCTAssertTrue(before.issues.contains(where: { $0.kind == .pageContentTypeMismatch }))
        XCTAssertTrue(before.issues.contains(where: { $0.kind == .unreadablePageContent }))

        let recovery = try await repository.recoverNotebook(id: created.id)
        XCTAssertTrue(recovery.actions.contains(.createdMissingPageContent))
        XCTAssertTrue(recovery.actions.contains(.resetMismatchedPageContent))
        XCTAssertTrue(recovery.actions.contains(.resetUnreadablePageContent))
        XCTAssertTrue(recovery.validation.isValid, "Unexpected issues: \(recovery.validation.issues)")
        let repairedText = try await repository.loadPageContent(
            notebookID: created.id,
            pageID: missingPage.id
        )
        let repairedStudySet = try await repository.loadPageContent(
            notebookID: created.id,
            pageID: mismatchedPage.id
        )
        XCTAssertEqual(repairedText, .textDocument(TextDocument()))
        XCTAssertEqual(repairedStudySet, .studySet(StudySet()))
        let quarantined = try FileManager.default.contentsOfDirectory(
            at: layout.pageURL(mismatchedPage.id),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("content.corrupt-") }
        XCTAssertEqual(quarantined.count, 1)
    }

    func testLegacyStructuredPageWithoutContentLoadsAsEmptyAndRecoveryMigratesIt() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(kind: .textDocument, title: "Legacy")
        let created = try await repository.createNotebook(title: "Legacy package", initialPage: page)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))

        var legacyManifest = try await repository.openNotebook(id: created.id)
        legacyManifest.pages[0].schemaVersion = 2
        var legacyPage = legacyManifest.pages[0]
        legacyPage.schemaVersion = 2
        try repositoryJSONData(legacyManifest).write(to: layout.manifestURL, options: .atomic)
        try repositoryJSONData(legacyPage).write(to: layout.pageDescriptorURL(page.id), options: .atomic)
        try FileManager.default.removeItem(at: layout.contentURL(page.id))

        let legacyContent = try await repository.loadPageContent(
            notebookID: created.id,
            pageID: page.id
        )
        let validationBeforeMigration = try await repository.validateNotebook(id: created.id)
        XCTAssertEqual(legacyContent, .textDocument(TextDocument()))
        XCTAssertTrue(validationBeforeMigration.isValid)

        let recovery = try await repository.recoverNotebook(id: created.id)
        let migrated = try await repository.openNotebook(id: created.id)
        XCTAssertTrue(recovery.actions.contains(.migratedSchema))
        XCTAssertTrue(recovery.actions.contains(.createdMissingPageContent))
        XCTAssertEqual(migrated.pages[0].schemaVersion, PageDescriptor.currentSchemaVersion)
        XCTAssertTrue(recovery.validation.isValid)
    }

    func testCurrentStructuredPageRequiresContentWhileCanvasPagesReturnNil() async throws {
        let (repository, _) = try makeRepository()
        let textPage = PageDescriptor(kind: .textDocument, title: "Required")
        let created = try await repository.createNotebook(title: "Content contract", initialPage: textPage)
        let canvasPage = PageDescriptor(kind: .notebook, title: "Canvas")
        _ = try await repository.addPage(notebookID: created.id, page: canvasPage, at: nil)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))
        try FileManager.default.removeItem(at: layout.contentURL(textPage.id))

        do {
            _ = try await repository.loadPageContent(notebookID: created.id, pageID: textPage.id)
            XCTFail("Current structured pages must surface a missing durable content file.")
        } catch {
            XCTAssertEqual(error as? NotebookRepositoryError, .missingPageContent(textPage.id))
        }
        let canvasContent = try await repository.loadPageContent(
            notebookID: created.id,
            pageID: canvasPage.id
        )
        XCTAssertNil(canvasContent)
    }

    func testStructuredContentRejectsSchedulerOverflowAndRecoversUnsafeEntries() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(kind: .studySet, title: "Unsafe progress")
        let created = try await repository.createNotebook(title: "Bounds", initialPage: page)
        let card = StudyCard(prompt: "Question", answer: "Answer")
        let unsafe = StudySet(
            cards: [card],
            progress: [
                StudyCardProgress(
                    cardID: card.id,
                    repetitions: .max,
                    lapses: .max,
                    intervalDays: .max
                )
            ]
        )

        do {
            try await repository.savePageContent(
                .studySet(unsafe),
                notebookID: created.id,
                pageID: page.id
            )
            XCTFail("Scheduler values that can overflow must be rejected.")
        } catch let error as NotebookRepositoryError {
            guard case .invalidPageContent(let rejectedPageID, _) = error else {
                XCTFail("Expected invalid page content, got \(error).")
                return
            }
            XCTAssertEqual(rejectedPageID, page.id)
        }

        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))
        try repositoryJSONData(PageContent.studySet(unsafe)).write(
            to: layout.contentURL(page.id),
            options: .atomic
        )
        let invalid = try await repository.validateNotebook(id: created.id)
        XCTAssertTrue(invalid.issues.contains(where: { $0.kind == .invalidPageContent }))

        let recovery = try await repository.recoverNotebook(id: created.id)
        XCTAssertTrue(recovery.actions.contains(.resetInvalidPageContent))
        XCTAssertTrue(recovery.validation.isValid)
        let reset = try await repository.loadPageContent(notebookID: created.id, pageID: page.id)
        XCTAssertEqual(reset, .studySet(StudySet()))
    }

    func testStructuredContentEnforcesFieldAndEncodedFileBounds() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(kind: .textDocument, title: "Bounds")
        let created = try await repository.createNotebook(title: "Size limits", initialPage: page)
        let oversizedField = String(repeating: "a", count: 1_024 * 1_024 + 1)

        do {
            try await repository.savePageContent(
                .textDocument(TextDocument(blocks: [TextBlock(text: oversizedField)])),
                notebookID: created.id,
                pageID: page.id
            )
            XCTFail("An oversized text field must be rejected before it is persisted.")
        } catch let error as NotebookRepositoryError {
            guard case .invalidPageContent(let rejectedPageID, _) = error else {
                XCTFail("Expected invalid page content, got \(error).")
                return
            }
            XCTAssertEqual(rejectedPageID, page.id)
        }

        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))
        let oversizedFile = Data(repeating: 0x20, count: 16 * 1_024 * 1_024 + 1)
        try oversizedFile.write(to: layout.contentURL(page.id), options: .atomic)
        do {
            try await repository.savePageContent(
                .textDocument(TextDocument()),
                notebookID: created.id,
                pageID: page.id
            )
            XCTFail("A transaction must not read or overwrite an oversized existing content file.")
        } catch is NotebookRepositoryError {
            // Expected.
        }
        let oversizedAttributes = try FileManager.default.attributesOfItem(
            atPath: layout.contentURL(page.id).path
        )
        XCTAssertEqual(oversizedAttributes[.size] as? NSNumber, NSNumber(value: oversizedFile.count))
        let invalid = try await repository.validateNotebook(id: created.id)
        XCTAssertTrue(invalid.issues.contains(where: { $0.kind == .unreadablePageContent }))

        let recovery = try await repository.recoverNotebook(id: created.id)
        XCTAssertTrue(recovery.actions.contains(.resetUnreadablePageContent))
        XCTAssertTrue(recovery.validation.isValid)
    }

    func testRecoveryQuarantinesUnexpectedAndRemovesDanglingStructuredContentEntries() async throws {
        let (repository, _) = try makeRepository()
        let canvasPage = PageDescriptor(kind: .notebook, title: "Canvas")
        let created = try await repository.createNotebook(title: "Entry safety", initialPage: canvasPage)
        let linkedPage = PageDescriptor(kind: .textDocument, title: "Dangling link")
        _ = try await repository.addPage(notebookID: created.id, page: linkedPage, at: nil)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))

        try repositoryJSONData(PageContent.textDocument(TextDocument())).write(
            to: layout.contentURL(canvasPage.id),
            options: .atomic
        )
        try FileManager.default.removeItem(at: layout.contentURL(linkedPage.id))
        let missingTarget = layout.pageURL(linkedPage.id).appendingPathComponent("missing-target.json")
        try FileManager.default.createSymbolicLink(
            at: layout.contentURL(linkedPage.id),
            withDestinationURL: missingTarget
        )

        let before = try await repository.validateNotebook(id: created.id)
        XCTAssertTrue(before.issues.contains(where: {
            $0.kind == .pageContentTypeMismatch && $0.relativePath.contains(canvasPage.id.description)
        }))
        XCTAssertTrue(before.issues.contains(where: {
            $0.kind == .unreadablePageContent && $0.relativePath.contains(linkedPage.id.description)
        }))

        let recovery = try await repository.recoverNotebook(id: created.id)
        XCTAssertTrue(recovery.actions.contains(.quarantinedUnexpectedPageContent))
        XCTAssertTrue(recovery.actions.contains(.resetUnreadablePageContent))
        XCTAssertTrue(recovery.validation.isValid)
        let linkedContent = try await repository.loadPageContent(
            notebookID: created.id,
            pageID: linkedPage.id
        )
        XCTAssertEqual(linkedContent, .textDocument(TextDocument()))
        let remainingEntries = try FileManager.default.contentsOfDirectory(
            at: layout.pageURL(linkedPage.id),
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        )
        XCTAssertFalse(remainingEntries.contains(where: {
            (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
        }))
    }

    func testStructuredContentNeverFollowsASymbolicLinkPageDirectory() async throws {
        let (repository, root) = try makeRepository()
        let page = PageDescriptor(kind: .textDocument, title: "Contained")
        let created = try await repository.createNotebook(title: "Containment", initialPage: page)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))
        let outsideDirectory = root.appendingPathComponent("OutsidePage", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let outsideContentURL = outsideDirectory.appendingPathComponent("content.json")
        let outsideContent = PageContent.textDocument(
            TextDocument(blocks: [TextBlock(text: "Must remain outside")])
        )
        let outsideData = try repositoryJSONData(outsideContent)
        try outsideData.write(to: outsideContentURL)

        try FileManager.default.removeItem(at: layout.pageURL(page.id))
        try FileManager.default.createSymbolicLink(
            at: layout.pageURL(page.id),
            withDestinationURL: outsideDirectory
        )

        do {
            _ = try await repository.loadPageContent(notebookID: created.id, pageID: page.id)
            XCTFail("A structured-content read must not follow a page-directory link.")
        } catch is NotebookRepositoryError {
            // Expected.
        }
        do {
            try await repository.savePageContent(
                .textDocument(TextDocument()),
                notebookID: created.id,
                pageID: page.id
            )
            XCTFail("A structured-content write must not follow a page-directory link.")
        } catch is NotebookRepositoryError {
            // Expected.
        }

        let validation = try await repository.validateNotebook(id: created.id)
        XCTAssertTrue(validation.issues.contains(where: { $0.kind == .missingPageDirectory }))
        XCTAssertEqual(try Data(contentsOf: outsideContentURL), outsideData)
    }

    func testStructuredContentFIFOIsRejectedWithoutBlockingAndCanBeRecovered() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(kind: .textDocument, title: "FIFO")
        let created = try await repository.createNotebook(title: "Nonblocking", initialPage: page)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))
        let contentURL = layout.contentURL(page.id)
        try FileManager.default.removeItem(at: contentURL)
        let result = contentURL.path.withCString {
            Darwin.mkfifo($0, mode_t(S_IRUSR | S_IWUSR))
        }
        XCTAssertEqual(result, 0)

        let validation = try await repository.validateNotebook(id: created.id)
        XCTAssertTrue(validation.issues.contains(where: { $0.kind == .unreadablePageContent }))
        do {
            _ = try await repository.loadPageContent(notebookID: created.id, pageID: page.id)
            XCTFail("A FIFO must not be accepted as structured content.")
        } catch is NotebookRepositoryError {
            // Expected.
        }
        do {
            try await repository.savePageContent(
                .textDocument(TextDocument()),
                notebookID: created.id,
                pageID: page.id
            )
            XCTFail("A save must not read a FIFO while preparing its transaction backup.")
        } catch is NotebookRepositoryError {
            // Expected.
        }

        let recovery = try await repository.recoverNotebook(id: created.id)
        XCTAssertTrue(recovery.actions.contains(.resetUnreadablePageContent))
        XCTAssertTrue(recovery.validation.isValid)
    }

    func testRecoveryNeverDowngradesFutureManifestOrPageSchemas() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(kind: .textDocument, title: "Future")
        let created = try await repository.createNotebook(title: "Future schema", initialPage: page)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))
        let originalManifest = try Data(contentsOf: layout.manifestURL)
        let originalPage = try Data(contentsOf: layout.pageDescriptorURL(page.id))

        var manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: originalManifest) as? [String: Any]
        )
        manifestObject["schemaVersion"] = NotebookManifest.currentSchemaVersion + 1
        let futureManifest = try JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.sortedKeys]
        )
        try futureManifest.write(to: layout.manifestURL, options: .atomic)

        do {
            _ = try await repository.recoverNotebook(id: created.id)
            XCTFail("Recovery must not rewrite a package from a future manifest schema.")
        } catch is NotebookRepositoryError {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: layout.manifestURL), futureManifest)
        XCTAssertEqual(try Data(contentsOf: layout.pageDescriptorURL(page.id)), originalPage)

        manifestObject["pages"] = "malformed-unrelated-field"
        let malformedFutureManifest = try JSONSerialization.data(
            withJSONObject: manifestObject,
            options: [.sortedKeys]
        )
        try malformedFutureManifest.write(to: layout.manifestURL, options: .atomic)
        do {
            _ = try await repository.recoverNotebook(id: created.id)
            XCTFail("A malformed unrelated field must not hide a future top-level schema.")
        } catch is NotebookRepositoryError {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: layout.manifestURL), malformedFutureManifest)
        XCTAssertEqual(try Data(contentsOf: layout.pageDescriptorURL(page.id)), originalPage)

        try originalManifest.write(to: layout.manifestURL, options: .atomic)
        var pageObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: originalPage) as? [String: Any]
        )
        pageObject["schemaVersion"] = PageDescriptor.currentSchemaVersion + 1
        let futurePage = try JSONSerialization.data(withJSONObject: pageObject, options: [.sortedKeys])
        try futurePage.write(to: layout.pageDescriptorURL(page.id), options: .atomic)

        do {
            _ = try await repository.recoverNotebook(id: created.id)
            XCTFail("Recovery must not rewrite a package containing a future page schema.")
        } catch is NotebookRepositoryError {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: layout.manifestURL), originalManifest)
        XCTAssertEqual(try Data(contentsOf: layout.pageDescriptorURL(page.id)), futurePage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: layout.pageURL(page.id).path))

        try originalPage.write(to: layout.pageDescriptorURL(page.id), options: .atomic)
        let corruptCurrentManifest = Data("corrupt-current-manifest".utf8)
        try corruptCurrentManifest.write(to: layout.manifestURL, options: .atomic)
        try futureManifest.write(to: layout.backupManifestURL, options: .atomic)
        do {
            _ = try await repository.recoverNotebook(id: created.id)
            XCTFail("Recovery must not replace a corrupt manifest from a future-version backup.")
        } catch is NotebookRepositoryError {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: layout.manifestURL), corruptCurrentManifest)
        XCTAssertEqual(try Data(contentsOf: layout.backupManifestURL), futureManifest)
        XCTAssertEqual(try Data(contentsOf: layout.pageDescriptorURL(page.id)), originalPage)
    }

    func testContentAddressedAssetsAreDeduplicatedAndIntegrityChecked() async throws {
        let (repository, _) = try makeRepository()
        let manifest = try await repository.createNotebook(title: "Assets", initialPage: nil)
        let bytes = Data("abc".utf8)

        let first = try await repository.importAsset(
            bytes,
            notebookID: manifest.id,
            mediaType: "text/plain",
            originalFilename: "first.txt"
        )
        let second = try await repository.importAsset(
            bytes,
            notebookID: manifest.id,
            mediaType: "application/octet-stream",
            originalFilename: "second.bin"
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.id.rawValue, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let loadedAsset = try await repository.loadAsset(notebookID: manifest.id, assetID: first.id)
        XCTAssertEqual(loadedAsset, bytes)
        let reopened = try await repository.openNotebook(id: manifest.id)
        XCTAssertEqual(reopened.assets, [first])

        let assetsURL = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id)).assetsURL
        let storedAssets = try FileManager.default.contentsOfDirectory(at: assetsURL, includingPropertiesForKeys: nil)
        XCTAssertEqual(storedAssets.map(\.lastPathComponent), [first.id.rawValue])
    }

    func testPageInsertionOrderingReorderingAndDeletion() async throws {
        let (repository, _) = try makeRepository()
        let first = PageDescriptor(title: "First")
        let second = PageDescriptor(title: "Second")
        let third = PageDescriptor(title: "Third")
        var manifest = try await repository.createNotebook(title: "Pages", initialPage: first)
        manifest = try await repository.addPage(notebookID: manifest.id, page: second, at: nil)
        manifest = try await repository.addPage(notebookID: manifest.id, page: third, at: 1)
        XCTAssertEqual(manifest.pages.map(\.id), [first.id, third.id, second.id])

        manifest = try await repository.reorderPages(
            notebookID: manifest.id,
            pageIDs: [second.id, first.id, third.id]
        )
        XCTAssertEqual(manifest.pages.map(\.id), [second.id, first.id, third.id])

        do {
            _ = try await repository.reorderPages(notebookID: manifest.id, pageIDs: [first.id, second.id])
            XCTFail("An incomplete page order must be rejected.")
        } catch {
            XCTAssertEqual(error as? NotebookRepositoryError, .invalidPageOrder)
        }

        manifest = try await repository.deletePage(notebookID: manifest.id, pageID: first.id)
        XCTAssertEqual(manifest.pages.map(\.id), [second.id, third.id])
        let deletedDirectory = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id)).pageURL(first.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: deletedDirectory.path))
        let validation = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(validation.isValid)
    }

    func testAddPageFailureBeforeManifestCommitRemovesProvisionedDirectory() async throws {
        let (initialRepository, root) = try makeRepository()
        let created = try await initialRepository.createNotebook(
            title: "Atomic page add",
            initialPage: nil
        )
        let page = PageDescriptor(title: "Must roll back")
        let failures = OneShotStorageFailure(.beforeStateWrite(relativePath: "manifest.json"))
        let repository = try FileNotebookRepository(rootURL: root) { point in
            try failures.trigger(point)
        }

        do {
            _ = try await repository.addPage(notebookID: created.id, page: page, at: nil)
            XCTFail("A failure before the manifest commit must reject the page add.")
        } catch is InjectedStorageFailure {
            // Expected.
        } catch {
            throw error
        }

        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.pageURL(page.id).path))
        let reopened = try await repository.openNotebook(id: created.id)
        XCTAssertTrue(reopened.pages.isEmpty)
        XCTAssertEqual(reopened.revision, created.revision)
        let validation = try await repository.validateNotebook(id: created.id)
        XCTAssertTrue(validation.isValid, "Unexpected issues: \(validation.issues)")
    }

    func testAddPageRejectsAndPreservesPreexistingUnownedDirectory() async throws {
        let (repository, _) = try makeRepository()
        let created = try await repository.createNotebook(
            title: "Unowned page directory",
            initialPage: nil
        )
        let page = PageDescriptor(title: "Collision")
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))
        let pageDirectory = layout.pageURL(page.id)
        try FileManager.default.createDirectory(
            at: pageDirectory,
            withIntermediateDirectories: false
        )
        let sentinelURL = pageDirectory.appendingPathComponent("keep.txt", isDirectory: false)
        let sentinel = Data("must remain".utf8)
        try sentinel.write(to: sentinelURL)

        do {
            _ = try await repository.addPage(notebookID: created.id, page: page, at: nil)
            XCTFail("A transaction must not adopt a preexisting page directory.")
        } catch {
            XCTAssertEqual(error as? NotebookRepositoryError, .duplicatePage(page.id))
        }

        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        let reopened = try await repository.openNotebook(id: created.id)
        XCTAssertTrue(reopened.pages.isEmpty)
        XCTAssertEqual(reopened.revision, created.revision)
        XCTAssertEqual(try transactionDirectoryCount(in: layout), 0)
    }

    func testAddPageRejectsLinkedDirectoryWithoutTouchingExternalElements() async throws {
        let (repository, _) = try makeRepository()
        let created = try await repository.createNotebook(
            title: "Linked page directory",
            initialPage: nil
        )
        let page = PageDescriptor(title: "Linked collision")
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))
        let externalDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesCoreExternal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: externalDirectory,
            withIntermediateDirectories: false
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: externalDirectory) }
        let externalElements = externalDirectory.appendingPathComponent(
            "elements.json",
            isDirectory: false
        )
        let sentinel = Data("external elements must remain untouched".utf8)
        try sentinel.write(to: externalElements)
        try FileManager.default.createSymbolicLink(
            at: layout.pageURL(page.id),
            withDestinationURL: externalDirectory
        )

        do {
            _ = try await repository.addPage(notebookID: created.id, page: page, at: nil)
            XCTFail("A transaction must reject a linked page directory before preparing backups.")
        } catch {
            XCTAssertEqual(error as? NotebookRepositoryError, .duplicatePage(page.id))
        }

        XCTAssertEqual(try Data(contentsOf: externalElements), sentinel)
        XCTAssertNoThrow(
            try FileManager.default.destinationOfSymbolicLink(atPath: layout.pageURL(page.id).path)
        )
        XCTAssertEqual(try transactionDirectoryCount(in: layout), 0)
    }

    func testMetadataUpdateAndNotebookDeletion() async throws {
        let (repository, _) = try makeRepository()
        let created = try await repository.createNotebook(title: "Draft", initialPage: nil)
        let updated = try await repository.updateNotebookMetadata(
            id: created.id,
            title: "  Research  ",
            tags: [" work ", "", "work", "ideas"],
            isFavorite: true
        )
        XCTAssertEqual(updated.title, "Research")
        XCTAssertEqual(updated.tags, ["work", "ideas"])
        XCTAssertTrue(updated.isFavorite)
        XCTAssertEqual(updated.revision, created.revision + 1)

        let unchanged = try await repository.updateNotebookMetadata(
            id: created.id,
            title: nil,
            tags: nil,
            isFavorite: nil
        )
        XCTAssertEqual(unchanged.revision, updated.revision)

        try await repository.deleteNotebook(id: created.id)
        let listed = try await repository.listNotebooks()
        XCTAssertTrue(listed.isEmpty)
        do {
            _ = try await repository.openNotebook(id: created.id)
            XCTFail("A deleted notebook must no longer be openable.")
        } catch {
            XCTAssertEqual(error as? NotebookRepositoryError, .notebookNotFound(created.id))
        }
    }

    func testPDFAndImageBackgroundsCodableRoundTrip() throws {
        let assetID = AssetID(String(repeating: "b", count: 64))
        let backgrounds: [PageBackground] = [
            .pdf(assetID: assetID, pageIndex: 7),
            .image(assetID: assetID),
            .asset(assetID)
        ]
        let encoded = try JSONEncoder().encode(backgrounds)
        XCTAssertEqual(try JSONDecoder().decode([PageBackground].self, from: encoded), backgrounds)

        let layout = NotebookPackageLayout(packageURL: URL(fileURLWithPath: "/tmp/example.notepkg", isDirectory: true))
        let maliciousURL = layout.assetURL(AssetID("../../manifest.json"))
        XCTAssertEqual(maliciousURL.deletingLastPathComponent().standardizedFileURL, layout.assetsURL.standardizedFileURL)
        XCTAssertTrue(maliciousURL.lastPathComponent.hasPrefix("invalid-"))
    }

    func testRecoveryUsesBackupAndRepairsPageAndElementsCorruption() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(title: "Recover me")
        var manifest = try await repository.createNotebook(title: "Original", initialPage: page)
        manifest = try await repository.renameNotebook(id: manifest.id, title: "Renamed")
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))

        try Data("not-json".utf8).write(to: layout.manifestURL)
        try Data("also-not-json".utf8).write(to: layout.pageDescriptorURL(page.id))
        try Data("broken-elements".utf8).write(to: layout.elementsURL(page.id))
        let abandonedTemporary = layout.pageURL(page.id).appendingPathComponent(".ink.data.interrupted.tmp")
        try Data("partial".utf8).write(to: abandonedTemporary)

        let before = try await repository.validateNotebook(id: manifest.id)
        XCTAssertFalse(before.isValid)
        XCTAssertTrue(before.issues.contains(where: { $0.kind == .unreadableManifest }))

        let recovery = try await repository.recoverNotebook(id: manifest.id)
        XCTAssertTrue(recovery.actions.contains(.restoredBackupManifest))
        XCTAssertTrue(recovery.actions.contains(.restoredPageDescriptor))
        XCTAssertTrue(recovery.actions.contains(.resetUnreadableElements))
        XCTAssertTrue(recovery.actions.contains(.removedTemporaryFile))
        XCTAssertTrue(recovery.validation.isValid, "Unexpected issues: \(recovery.validation.issues)")
        let recoveredElements = try await repository.loadElements(notebookID: manifest.id, pageID: page.id)
        XCTAssertEqual(recoveredElements, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: abandonedTemporary.path))
    }

    func testRecoveryReconstructsMissingManifestFromPageJSON() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(title: "Only durable page")
        let manifest = try await repository.createNotebook(title: "Lost manifest", initialPage: page)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        try FileManager.default.removeItem(at: layout.manifestURL)
        try? FileManager.default.removeItem(at: layout.backupManifestURL)

        let invalid = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(invalid.issues.contains(where: { $0.kind == .missingManifest }))

        let recovery = try await repository.recoverNotebook(id: manifest.id)
        XCTAssertTrue(recovery.actions.contains(.reconstructedManifest))
        XCTAssertEqual(recovery.manifest.pages.map(\.id), [page.id])
        XCTAssertTrue(recovery.validation.isValid)
    }

    func testRecoveryDropsCorruptAssetReferenceWithoutLosingNotebook() async throws {
        let (repository, _) = try makeRepository()
        let manifest = try await repository.createNotebook(title: "Damaged asset", initialPage: nil)
        let asset = try await repository.importAsset(
            Data("expected".utf8),
            notebookID: manifest.id,
            mediaType: "text/plain",
            originalFilename: nil
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        try Data("tampered".utf8).write(to: layout.assetURL(asset.id))

        let invalid = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(invalid.issues.contains(where: { $0.kind == .invalidAssetDigest }))
        let recovery = try await repository.recoverNotebook(id: manifest.id)
        XCTAssertTrue(recovery.actions.contains(.removedInvalidAssetReference))
        XCTAssertTrue(recovery.manifest.assets.isEmpty)
        XCTAssertTrue(recovery.validation.isValid)
    }

    func testRecoveryAdoptsValidAssetMissingFromBackupManifest() async throws {
        let (repository, _) = try makeRepository()
        let manifest = try await repository.createNotebook(title: "Asset backup", initialPage: nil)
        let bytes = Data("content survives".utf8)
        let asset = try await repository.importAsset(
            bytes,
            notebookID: manifest.id,
            mediaType: "text/plain",
            originalFilename: "content.txt"
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        try Data("broken-manifest".utf8).write(to: layout.manifestURL)

        let recovery = try await repository.recoverNotebook(id: manifest.id)
        XCTAssertTrue(recovery.actions.contains(.restoredBackupManifest))
        XCTAssertTrue(recovery.actions.contains(.adoptedOrphanAsset))
        XCTAssertEqual(recovery.manifest.assets.map(\.id), [asset.id])
        let loaded = try await repository.loadAsset(notebookID: manifest.id, assetID: asset.id)
        XCTAssertEqual(loaded, bytes)
        XCTAssertTrue(recovery.validation.isValid)
    }

    func testRecoveryQuarantinesUnreadableOperationLogEntry() async throws {
        let (repository, _) = try makeRepository()
        let manifest = try await repository.createNotebook(title: "Operation log", initialPage: nil)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: manifest.id))
        let operationURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: layout.operationsURL, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "json" })
        )
        try Data("damaged-operation".utf8).write(to: operationURL)

        let invalid = try await repository.validateNotebook(id: manifest.id)
        XCTAssertTrue(invalid.issues.contains(where: { $0.kind == .unreadableOperation }))
        let recovery = try await repository.recoverNotebook(id: manifest.id)
        XCTAssertTrue(recovery.actions.contains(.removedUnreadableOperation))
        XCTAssertTrue(recovery.validation.isValid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: operationURL.appendingPathExtension("corrupt").path))
    }

    func testRebuildLibraryIndexScansPackagesAndWritesDerivedIndex() async throws {
        let (repository, root) = try makeRepository()
        let first = try await repository.createNotebook(title: "One", initialPage: nil)
        let second = try await repository.createNotebook(title: "Two", initialPage: nil)

        let rebuilt = try await repository.rebuildLibraryIndex()
        XCTAssertEqual(Set(rebuilt.map(\.id)), Set([first.id, second.id]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("library-index.json").path))
        let listed = try await repository.listNotebooks()
        XCTAssertEqual(Set(listed.map(\.id)), Set([first.id, second.id]))
    }

    func testLegacyCodableFieldsReceiveMigrationDefaults() throws {
        let pageID = PageID()
        let notebookID = NotebookID()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = LegacyManifest(
            id: notebookID,
            title: "Legacy",
            createdAt: createdAt,
            pages: [LegacyPage(id: pageID, createdAt: createdAt)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(NotebookManifest.self, from: encoder.encode(legacy))
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.modifiedAt, createdAt)
        XCTAssertEqual(decoded.revision, 0)
        XCTAssertEqual(decoded.assets, [])
        XCTAssertEqual(decoded.audioSessions, [])
        XCTAssertEqual(decoded.tags, [])
        XCTAssertFalse(decoded.isFavorite)
        XCTAssertEqual(decoded.pages.count, 1)
        XCTAssertEqual(decoded.pages[0].kind, .notebook)
        XCTAssertEqual(decoded.pages[0].size, .a4)
        XCTAssertEqual(decoded.pages[0].background, .plain(colorHex: "#FFFFFF"))
        XCTAssertEqual(decoded.pages[0].rotationDegrees, 0)
        XCTAssertFalse(decoded.pages[0].isBookmarked)
    }

    func testManifestAndPageRejectCorruptOrFutureSchemaVersions() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let unsupportedVersions = [0, -1, PageDescriptor.currentSchemaVersion + 1]

        for version in unsupportedVersions {
            let pageData = try encoder.encode(PageDescriptor(schemaVersion: version))
            XCTAssertThrowsError(try decoder.decode(PageDescriptor.self, from: pageData))
        }

        for version in [0, -1, NotebookManifest.currentSchemaVersion + 1] {
            let manifestData = try encoder.encode(
                NotebookManifest(schemaVersion: version, title: "Unsupported")
            )
            XCTAssertThrowsError(try decoder.decode(NotebookManifest.self, from: manifestData))
        }
    }

    func testEveryPublicDomainModelCodableRoundTrips() throws {
        let notebookID = NotebookID()
        let pageID = PageID()
        let assetID = AssetID(String(repeating: "a", count: 64))
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let asset = AssetDescriptor(
            id: assetID,
            mediaType: "image/png",
            originalFilename: "sticker.png",
            byteCount: 42,
            createdAt: createdAt
        )
        let page = PageDescriptor(
            id: pageID,
            kind: .whiteboard,
            title: "Canvas",
            createdAt: createdAt,
            modifiedAt: createdAt,
            size: PageSize(width: 1_000, height: 1_000),
            background: .grid(colorHex: "#EEEEEE", spacing: 20),
            rotationDegrees: 90,
            isBookmarked: true
        )
        let element = CanvasElement(
            frame: CanvasRect(x: 1, y: 2, width: 3, height: 4),
            zIndex: 2,
            content: .sticker(StickerElement(assetID: assetID, accessibilityLabel: "Star")),
            createdAt: createdAt,
            modifiedAt: createdAt
        )
        let command = EditCommand(
            notebookID: notebookID,
            pageID: pageID,
            sequence: 9,
            timestamp: createdAt,
            kind: .custom,
            payload: ["key": "value"]
        )
        let audioSessionID = AudioSessionID()
        let audio = AudioSessionDescriptor(
            id: audioSessionID,
            createdAt: createdAt,
            modifiedAt: createdAt,
            durationSeconds: 30,
            chunkFilenames: ["\(audioSessionID.description).m4a"],
            audioByteCount: 42,
            audioSHA256: String(repeating: "a", count: 64),
            timelineFilename: "\(audioSessionID.description).timeline.json",
            transcriptAssetID: assetID
        )
        let timeline = AudioTimelineDocument(
            audioSessionID: audioSessionID,
            marks: [.init(
                operationID: command.id,
                pageID: pageID,
                timeSeconds: 2.5,
                createdAt: createdAt
            )],
            modifiedAt: createdAt
        )
        let search = SearchSegment(
            notebookID: notebookID,
            pageID: pageID,
            source: .transcript,
            text: "Hello",
            rangeHint: "paragraph:1",
            audioTimeSeconds: 2.5
        )
        let artifact = AIArtifact(
            notebookID: notebookID,
            pageID: pageID,
            kind: .summary,
            content: "Summary",
            sourceSegmentIDs: [search.id],
            modelIdentifier: "local-test",
            createdAt: createdAt
        )
        let manifest = NotebookManifest(
            id: notebookID,
            title: "Everything",
            createdAt: createdAt,
            modifiedAt: createdAt,
            revision: 9,
            pages: [page],
            assets: [asset],
            audioSessions: [audio],
            tags: ["test"],
            isFavorite: true
        )
        let envelope = DomainEnvelope(
            manifest: manifest,
            element: element,
            command: command,
            timeline: timeline,
            search: search,
            artifact: artifact
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(DomainEnvelope.self, from: encoder.encode(envelope)), envelope)
    }
}

private extension FileNotebookRepositoryTests {
    func makeRepository() throws -> (FileNotebookRepository, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesCoreTests-\(UUID().uuidString)", isDirectory: true)
        let repository = try FileNotebookRepository(rootURL: root)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return (repository, root)
    }

    func resizeRegularFile(at url: URL, to byteCount: UInt64) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: byteCount)
    }

    func operationJSONCount(in layout: NotebookPackageLayout) throws -> Int {
        try FileManager.default.contentsOfDirectory(
            at: layout.operationsURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }.count
    }

    func transactionDirectoryCount(in layout: NotebookPackageLayout) throws -> Int {
        try FileManager.default.contentsOfDirectory(
            at: layout.transactionsURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.count
    }

    func repositoryJSONData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    func assertInvalidExportSession(
        _ repository: FileNotebookRepository,
        _ session: NotebookExportSession,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await repository.validateNotebookExportSession(session)
            XCTFail("Expected the export session to be invalid", file: file, line: line)
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(error, .invalidExportSession, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private final class ExportManifestDecodeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [NotebookID: Int] = [:]

    func observe(_ point: StorageFailurePoint) {
        guard case .afterBoundedExportManifestDecode(let notebookID) = point else { return }
        lock.lock()
        counts[notebookID, default: 0] += 1
        lock.unlock()
    }

    func count(for notebookID: NotebookID) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[notebookID, default: 0]
    }
}

private final class ExportManifestPostReadMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var manifestURL: URL?
    private var manifestData: Data?
    private var hasMutated = false

    var didMutate: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasMutated
    }

    func configure(manifestURL: URL, manifestData: Data) {
        lock.lock()
        self.manifestURL = manifestURL
        self.manifestData = manifestData
        hasMutated = false
        lock.unlock()
    }

    func trigger(_ point: StorageFailurePoint) throws {
        guard case .duringBoundedContentRead(let relativePath, let bytesRead) = point,
              relativePath.hasSuffix("ink.data"),
              bytesRead > 0 else { return }
        let mutation: (URL, Data)?
        lock.lock()
        if !hasMutated, let manifestURL, let manifestData {
            hasMutated = true
            mutation = (manifestURL, manifestData)
        } else {
            mutation = nil
        }
        lock.unlock()
        if let mutation {
            try mutation.1.write(to: mutation.0, options: .atomic)
        }
    }
}

private final class BoundedReadMutationController: @unchecked Sendable {
    private let lock = NSLock()
    private var targetURL: URL?
    private var hasMutated = false

    var didMutate: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasMutated
    }

    func configure(targetURL: URL) {
        lock.lock()
        self.targetURL = targetURL
        hasMutated = false
        lock.unlock()
    }

    func trigger(_ point: StorageFailurePoint) throws {
        guard case .duringBoundedContentRead(let relativePath, let bytesRead) = point,
              relativePath.hasSuffix("ink.data"),
              bytesRead > 0 else { return }

        let url: URL?
        lock.lock()
        if hasMutated {
            url = nil
        } else {
            hasMutated = true
            url = targetURL
        }
        lock.unlock()
        guard let url else { return }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(
            atOffset: UInt64(NotebookExportReadLimits.maximumInkBytes + 1)
        )
    }
}

private final class BoundedReadCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let paused = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private var isArmed = false

    func arm() {
        lock.lock()
        isArmed = true
        lock.unlock()
    }

    func trigger(_ point: StorageFailurePoint) {
        guard case .duringBoundedContentRead(let relativePath, let bytesRead) = point,
              relativePath.hasSuffix("ink.data"),
              bytesRead > 0 else { return }
        lock.lock()
        let shouldPause = isArmed
        isArmed = false
        lock.unlock()
        guard shouldPause else { return }
        paused.signal()
        resume.wait()
    }

    func waitUntilPaused() -> DispatchTimeoutResult {
        paused.wait(timeout: .now() + 5)
    }

    func release() {
        resume.signal()
    }
}

private actor AsyncReleaseGate {
    private var isReleased = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isReleased { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private final class ExportAssetDigestCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isArmed = false
    private let paused = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)

    func arm() {
        lock.lock()
        isArmed = true
        lock.unlock()
    }

    func trigger(_ point: StorageFailurePoint) {
        guard case .duringExportAssetDigest(_, let bytesHashed) = point,
              bytesHashed > 0 else { return }
        lock.lock()
        let shouldPause = isArmed
        isArmed = false
        lock.unlock()
        guard shouldPause else { return }
        paused.signal()
        resume.wait()
    }

    func waitUntilPaused() -> DispatchTimeoutResult {
        paused.wait(timeout: .now() + 2)
    }

    func release() {
        resume.signal()
    }
}

private struct InjectedStorageFailure: Error {}

private final class OneShotStorageFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var point: StorageFailurePoint?

    init(_ point: StorageFailurePoint) {
        self.point = point
    }

    func trigger(_ candidate: StorageFailurePoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard point == candidate else { return }
        point = nil
        throw InjectedStorageFailure()
    }
}

private struct LegacyManifest: Encodable {
    var id: NotebookID
    var title: String
    var createdAt: Date
    var pages: [LegacyPage]
}

private struct LegacyPage: Encodable {
    var id: PageID
    var createdAt: Date
}

private struct DomainEnvelope: Codable, Equatable {
    var manifest: NotebookManifest
    var element: CanvasElement
    var command: EditCommand
    var timeline: AudioTimelineDocument
    var search: SearchSegment
    var artifact: AIArtifact
}
