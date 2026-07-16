import Foundation
import XCTest
@testable import NotesCore

final class HandwritingRecognitionRepositoryTests: XCTestCase {
    func testRecognitionRoundTripUsesBoundedInkAndOneRevisionTransaction() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(title: "Handwriting")
        let notebook = try await repository.createNotebook(
            title: "Recognition",
            initialPage: page
        )
        try await repository.saveInk(Data(), notebookID: notebook.id, pageID: page.id)
        let document = makeDocument(pageID: page.id)

        try await repository.saveHandwritingRecognition(
            document,
            notebookID: notebook.id,
            pageID: page.id,
            expectedRunID: nil,
            expectedRevision: nil
        )

        let loadedDocument = try await repository.loadHandwritingRecognition(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertEqual(loadedDocument, document)
        let recognitionInk = try await repository.loadInkForHandwritingRecognition(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertEqual(recognitionInk, Data())
        let reopened = try await repository.openNotebook(id: notebook.id)
        XCTAssertEqual(reopened.revision, 3)
        let operations = try await repository.operationLog(notebookID: notebook.id)
        XCTAssertEqual(operations.map(\.kind), [
            .createNotebook,
            .saveInk,
            .saveHandwritingRecognition
        ])
        XCTAssertEqual(operations.last?.payload["runID"], document.runID.uuidString.lowercased())
        let validation = try await repository.validateNotebook(id: notebook.id)
        XCTAssertTrue(validation.isValid)
    }

    func testRecognitionSaveRejectsMissingOrChangedInkWithoutMutation() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(title: "Stale source")
        let notebook = try await repository.createNotebook(
            title: "Recognition",
            initialPage: page
        )
        let document = makeDocument(pageID: page.id)

        do {
            try await repository.saveHandwritingRecognition(
                document,
                notebookID: notebook.id,
                pageID: page.id,
                expectedRunID: nil,
                expectedRevision: nil
            )
            XCTFail("Recognition without durable ink must fail")
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(error, .staleHandwritingRecognitionInk(pageID: page.id))
        }

        try await repository.saveInk(Data([0x01]), notebookID: notebook.id, pageID: page.id)
        do {
            try await repository.saveHandwritingRecognition(
                document,
                notebookID: notebook.id,
                pageID: page.id,
                expectedRunID: nil,
                expectedRevision: nil
            )
            XCTFail("Recognition for different ink must fail")
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(error, .staleHandwritingRecognitionInk(pageID: page.id))
        }

        let missingRecognition = try await repository.loadHandwritingRecognition(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertNil(missingRecognition)
        let reopened = try await repository.openNotebook(id: notebook.id)
        XCTAssertEqual(reopened.revision, 2)
    }

    func testRecognitionCompareAndSwapRejectsStaleWriterAndPreservesRunOutput() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(title: "CAS")
        let notebook = try await repository.createNotebook(title: "CAS", initialPage: page)
        try await repository.saveInk(Data(), notebookID: notebook.id, pageID: page.id)
        let first = makeDocument(pageID: page.id)
        try await repository.saveHandwritingRecognition(
            first,
            notebookID: notebook.id,
            pageID: page.id,
            expectedRunID: nil,
            expectedRevision: nil
        )

        do {
            try await repository.saveHandwritingRecognition(
                first,
                notebookID: notebook.id,
                pageID: page.id,
                expectedRunID: nil,
                expectedRevision: nil
            )
            XCTFail("An existing sidecar must not be overwritten as a first save")
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(error, .handwritingRecognitionConflict(pageID: page.id))
        }

        var reviewed = first
        reviewed.revision = 2
        reviewed.modifiedAt = first.generatedAt.addingTimeInterval(1)
        reviewed.reviews = [
            .init(
                candidateID: first.machineCandidates[0].id,
                decision: .accepted,
                correctedText: "Reviewed text",
                reviewedAt: reviewed.modifiedAt
            )
        ]
        try await repository.saveHandwritingRecognition(
            reviewed,
            notebookID: notebook.id,
            pageID: page.id,
            expectedRunID: first.runID,
            expectedRevision: 1
        )

        // A new value with the same run ID cannot replace immutable machine output.
        var alteredMachineOutput = makeDocument(
            pageID: page.id,
            runID: first.runID,
            revision: 3,
            generatedAt: first.generatedAt
        )
        alteredMachineOutput.modifiedAt = reviewed.modifiedAt.addingTimeInterval(1)
        do {
            try await repository.saveHandwritingRecognition(
                alteredMachineOutput,
                notebookID: notebook.id,
                pageID: page.id,
                expectedRunID: first.runID,
                expectedRevision: 2
            )
            XCTFail("Machine candidates must remain immutable within one run")
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(error, .handwritingRecognitionConflict(pageID: page.id))
        }

        var staleWriter = first
        staleWriter.revision = 2
        staleWriter.modifiedAt = reviewed.modifiedAt
        do {
            try await repository.saveHandwritingRecognition(
                staleWriter,
                notebookID: notebook.id,
                pageID: page.id,
                expectedRunID: first.runID,
                expectedRevision: 1
            )
            XCTFail("A stale review writer must fail")
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(error, .handwritingRecognitionConflict(pageID: page.id))
        }
        let storedReview = try await repository.loadHandwritingRecognition(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertEqual(storedReview, reviewed)

        let rerun = makeDocument(
            pageID: page.id,
            revision: 3,
            generatedAt: reviewed.modifiedAt.addingTimeInterval(1)
        )
        try await repository.saveHandwritingRecognition(
            rerun,
            notebookID: notebook.id,
            pageID: page.id,
            expectedRunID: reviewed.runID,
            expectedRevision: reviewed.revision
        )
        let storedRerun = try await repository.loadHandwritingRecognition(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertEqual(storedRerun, rerun)
    }

    func testInkChangeMarksRecognitionStaleButRecoveryRetainsReviewHistory() async throws {
        let (repository, root) = try makeRepository()
        let page = PageDescriptor(title: "Stale review")
        let notebook = try await repository.createNotebook(title: "Stale", initialPage: page)
        try await repository.saveInk(Data(), notebookID: notebook.id, pageID: page.id)
        let document = makeDocument(pageID: page.id)
        try await repository.saveHandwritingRecognition(
            document,
            notebookID: notebook.id,
            pageID: page.id,
            expectedRunID: nil,
            expectedRevision: nil
        )

        try await repository.saveInk(Data([0xff]), notebookID: notebook.id, pageID: page.id)
        let validation = try await repository.validateNotebook(id: notebook.id)
        XCTAssertTrue(validation.issues.contains(where: {
            $0.kind == .staleHandwritingRecognition
        }))
        XCTAssertTrue(validation.isValid, "Stale derived text must not block package use")
        let snapshotURL = root.appendingPathComponent(
            "stale-recognition-snapshot.notepkg",
            isDirectory: true
        )
        _ = try await repository.exportSnapshot(id: notebook.id, to: snapshotURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))

        let recovery = try await repository.recoverNotebook(id: notebook.id)
        XCTAssertFalse(recovery.actions.contains(.quarantinedInvalidHandwritingRecognition))
        XCTAssertTrue(recovery.validation.issues.contains(where: {
            $0.kind == .staleHandwritingRecognition
        }))
        XCTAssertTrue(recovery.validation.isValid)
        let retainedDocument = try await repository.loadHandwritingRecognition(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertEqual(retainedDocument, document)
    }

    func testRecoveryQuarantinesInvalidCurrentSidecar() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(title: "Corrupt")
        let notebook = try await repository.createNotebook(title: "Corrupt", initialPage: page)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        try Data(#"{"schemaVersion":1}"#.utf8).write(
            to: layout.handwritingRecognitionURL(page.id),
            options: .atomic
        )

        let before = try await repository.validateNotebook(id: notebook.id)
        XCTAssertTrue(before.issues.contains(where: {
            $0.kind == .unreadableHandwritingRecognition
        }))
        let recovery = try await repository.recoverNotebook(id: notebook.id)
        XCTAssertTrue(recovery.actions.contains(.quarantinedInvalidHandwritingRecognition))
        XCTAssertTrue(recovery.validation.isValid)
        let removedDocument = try await repository.loadHandwritingRecognition(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertNil(removedDocument)
        let filenames = try FileManager.default.contentsOfDirectory(
            atPath: layout.pageURL(page.id).path
        )
        XCTAssertTrue(filenames.contains(where: {
            $0.hasPrefix("handwriting-recognition.corrupt-") && $0.hasSuffix(".json")
        }))
    }

    func testRecoveryRefusesFutureSidecarWithoutModifyingIt() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(title: "Future")
        let notebook = try await repository.createNotebook(title: "Future", initialPage: page)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        let futureData = Data(#"{"schemaVersion":2}"#.utf8)
        let sidecarURL = layout.handwritingRecognitionURL(page.id)
        try futureData.write(to: sidecarURL, options: .atomic)

        let validation = try await repository.validateNotebook(id: notebook.id)
        XCTAssertTrue(validation.issues.contains(where: {
            $0.kind == .unsupportedHandwritingRecognitionSchema
        }))
        do {
            _ = try await repository.recoverNotebook(id: notebook.id)
            XCTFail("Recovery must not mutate a future sidecar")
        } catch NotebookRepositoryError.malformedPackage(_) {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: sidecarURL), futureData)
    }

    func testRecognitionInkReadEnforcesSixteenMiBCeiling() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(title: "Bound")
        let notebook = try await repository.createNotebook(title: "Bound", initialPage: page)
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        XCTAssertTrue(FileManager.default.createFile(
            atPath: layout.inkURL(page.id).path,
            contents: Data()
        ))
        let handle = try FileHandle(forWritingTo: layout.inkURL(page.id))
        try handle.truncate(
            atOffset: UInt64(NotebookHandwritingRecognitionReadLimits.maximumInkBytes + 1)
        )
        try handle.close()

        do {
            _ = try await repository.loadInkForHandwritingRecognition(
                notebookID: notebook.id,
                pageID: page.id
            )
            XCTFail("Oversized recognition ink must fail before allocation")
        } catch NotebookRepositoryError.boundedReadLimitExceeded(_, let limit) {
            XCTAssertEqual(limit, NotebookHandwritingRecognitionReadLimits.maximumInkBytes)
        }
    }

    func testDeletingPageRemovesRecognitionSidecarWithPageDirectory() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(title: "Delete")
        let notebook = try await repository.createNotebook(title: "Delete", initialPage: page)
        try await repository.saveInk(Data(), notebookID: notebook.id, pageID: page.id)
        try await repository.saveHandwritingRecognition(
            makeDocument(pageID: page.id),
            notebookID: notebook.id,
            pageID: page.id,
            expectedRunID: nil,
            expectedRevision: nil
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.handwritingRecognitionURL(page.id).path
        ))

        _ = try await repository.deletePage(notebookID: notebook.id, pageID: page.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.pageURL(page.id).path))
    }

    func testFailedRecognitionTransactionRollsBackSidecarAndManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HandwritingRecognitionFailureTests-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        let repository = try FileNotebookRepository(rootURL: root) { point in
            if case .beforeStateWrite(let relativePath) = point,
               relativePath.hasSuffix("handwriting-recognition.json") {
                throw RecognitionInjectedFailure.write
            }
        }
        let page = PageDescriptor(title: "Rollback")
        let notebook = try await repository.createNotebook(title: "Rollback", initialPage: page)
        try await repository.saveInk(Data(), notebookID: notebook.id, pageID: page.id)

        do {
            try await repository.saveHandwritingRecognition(
                makeDocument(pageID: page.id),
                notebookID: notebook.id,
                pageID: page.id,
                expectedRunID: nil,
                expectedRevision: nil
            )
            XCTFail("The injected state-write failure must escape")
        } catch RecognitionInjectedFailure.write {
            // Expected.
        }

        let reopened = try await repository.openNotebook(id: notebook.id)
        XCTAssertEqual(reopened.revision, 2)
        let stored = try await repository.loadHandwritingRecognition(
            notebookID: notebook.id,
            pageID: page.id
        )
        XCTAssertNil(stored)
        let operations = try await repository.operationLog(notebookID: notebook.id)
        XCTAssertEqual(operations.map(\.kind), [.createNotebook, .saveInk])
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: notebook.id))
        let transactions = try FileManager.default.contentsOfDirectory(
            at: layout.transactionsURL,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(transactions.isEmpty)
    }
}

private enum RecognitionInjectedFailure: Error {
    case write
}

private extension HandwritingRecognitionRepositoryTests {
    static let emptyInkSHA256 =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    func makeRepository() throws -> (FileNotebookRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HandwritingRecognitionRepositoryTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = try FileNotebookRepository(rootURL: root)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return (repository, root)
    }

    func makeDocument(
        pageID: PageID,
        runID: UUID = UUID(),
        revision: Int64 = 1,
        generatedAt: Date = Date(timeIntervalSinceReferenceDate: 700_000_000)
    ) -> HandwritingRecognitionDocument {
        HandwritingRecognitionDocument(
            runID: runID,
            pageID: pageID,
            sourceInkSHA256: Self.emptyInkSHA256,
            engineIdentifier: "vision-text-recognition",
            engineRevision: 1,
            languages: ["zh-Hant", "en-US"],
            generatedAt: generatedAt,
            revision: revision,
            modifiedAt: generatedAt,
            machineCandidates: [
                .init(
                    machineText: "Machine text",
                    machineConfidence: 0.9,
                    normalizedPageBounds: .init(
                        x: 0.1,
                        y: 0.2,
                        width: 0.4,
                        height: 0.1
                    ),
                    localeIdentifier: "en-US"
                )
            ]
        )
    }
}
