import Foundation
import XCTest
@testable import NotesCore

final class PageNavigationMetadataRepositoryTests: XCTestCase {
    func testLegacyPageNavigationMetadataDecodesWithSafeDefaults() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let page = PageDescriptor(isBookmarked: true, outlineTitle: "Overview")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(page)) as? [String: Any]
        )
        object["schemaVersion"] = 3
        object.removeValue(forKey: "isBookmarked")
        object.removeValue(forKey: "outlineTitle")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacyPage = try decoder.decode(PageDescriptor.self, from: legacyData)
        XCTAssertEqual(legacyPage.schemaVersion, 3)
        XCTAssertFalse(legacyPage.isBookmarked)
        XCTAssertNil(legacyPage.outlineTitle)

        object["isBookmarked"] = true
        let bookmarkedData = try JSONSerialization.data(withJSONObject: object)
        let bookmarkedPage = try decoder.decode(PageDescriptor.self, from: bookmarkedData)
        XCTAssertTrue(bookmarkedPage.isBookmarked)
        XCTAssertNil(bookmarkedPage.outlineTitle)

        object["outlineTitle"] = "Version mismatch"
        let mismatchedSchemaData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try decoder.decode(PageDescriptor.self, from: mismatchedSchemaData)
        )
    }

    func testPageDescriptorRejectsMalformedOutlineTitles() throws {
        let overByteBudgetTitle = String(
            repeating: "a\u{0301}\u{0301}\u{0301}\u{0301}",
            count: PageDescriptor.maximumOutlineTitleCharacters
        )
        XCTAssertEqual(
            overByteBudgetTitle.count,
            PageDescriptor.maximumOutlineTitleCharacters
        )
        XCTAssertGreaterThan(
            overByteBudgetTitle.utf8.count,
            PageDescriptor.maximumOutlineTitleUTF8Bytes
        )
        let invalidTitles = [
            "",
            "\u{200D}",
            " Leading",
            "Trailing ",
            "Two\nLines",
            "Two\u{2028}Lines",
            "Control\u{0007}Character",
            String(repeating: "a", count: PageDescriptor.maximumOutlineTitleCharacters + 1),
            overByteBudgetTitle
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for title in invalidTitles {
            let encoded = try encoder.encode(PageDescriptor(outlineTitle: title))
            XCTAssertThrowsError(try decoder.decode(PageDescriptor.self, from: encoded), title)
        }

        let maximumTitle = String(
            repeating: "a",
            count: PageDescriptor.maximumOutlineTitleCharacters
        )
        let valid = PageDescriptor(outlineTitle: maximumTitle)
        XCTAssertEqual(try decoder.decode(PageDescriptor.self, from: encoder.encode(valid)), valid)

        let familyEmoji = "\u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let joined = PageDescriptor(outlineTitle: "Family \(familyEmoji)")
        XCTAssertTrue(PageDescriptor.isValidOutlineTitle(joined.outlineTitle))
        XCTAssertEqual(
            try decoder.decode(PageDescriptor.self, from: encoder.encode(joined)),
            joined
        )
    }

    func testBookmarkAndOutlineUpdateClearAndReopenDurably() async throws {
        let (repository, root) = try makeRepository()
        let page = PageDescriptor(title: "Page title remains independent")
        let created = try await repository.createNotebook(
            title: "Navigation",
            initialPage: page
        )

        let bookmarked = try await repository.updatePageNavigationMetadata(
            notebookID: created.id,
            pageID: page.id,
            update: .bookmark(true)
        )
        let updated = try await repository.updatePageNavigationMetadata(
            notebookID: created.id,
            pageID: page.id,
            update: .outlineTitle("Chapter 1")
        )
        XCTAssertEqual(bookmarked.revision, created.revision + 1)
        XCTAssertEqual(updated.revision, created.revision + 2)
        XCTAssertTrue(updated.pages[0].isBookmarked)
        XCTAssertEqual(updated.pages[0].outlineTitle, "Chapter 1")
        XCTAssertEqual(updated.pages[0].title, page.title)
        XCTAssertEqual(updated.pages[0].schemaVersion, PageDescriptor.currentSchemaVersion)
        XCTAssertEqual(updated.modifiedAt, updated.pages[0].modifiedAt)

        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))
        XCTAssertEqual(try decodePage(at: layout.pageDescriptorURL(page.id)), updated.pages[0])
        let operations = try await repository.operationLog(notebookID: created.id)
        let operation = try XCTUnwrap(operations.last)
        XCTAssertEqual(operation.kind, .updatePageNavigationMetadata)
        XCTAssertEqual(operation.pageID, page.id)
        XCTAssertEqual(operation.payload["field"], "outlineTitle")
        XCTAssertEqual(operation.payload["isBookmarked"], "true")
        XCTAssertEqual(operation.payload["outlineTitlePresent"], "true")
        XCTAssertNil(operation.payload["outlineTitle"])
        XCTAssertEqual(operation.timestamp, updated.modifiedAt)
        let operationBytes = try FileManager.default.contentsOfDirectory(
            at: layout.operationsURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
            .reduce(into: Data()) { bytes, url in
                bytes.append(try Data(contentsOf: url))
            }
        XCTAssertFalse(String(decoding: operationBytes, as: UTF8.self).contains(
            "Chapter 1"
        ))

        let reopenedRepository = try FileNotebookRepository(rootURL: root)
        let reopened = try await reopenedRepository.openNotebook(id: created.id)
        XCTAssertEqual(reopened.pages[0], updated.pages[0])

        let outlineCleared = try await reopenedRepository.updatePageNavigationMetadata(
            notebookID: created.id,
            pageID: page.id,
            update: .outlineTitle(nil)
        )
        let cleared = try await reopenedRepository.updatePageNavigationMetadata(
            notebookID: created.id,
            pageID: page.id,
            update: .bookmark(false)
        )
        XCTAssertEqual(outlineCleared.revision, updated.revision + 1)
        XCTAssertEqual(cleared.revision, updated.revision + 2)
        XCTAssertFalse(cleared.pages[0].isBookmarked)
        XCTAssertNil(cleared.pages[0].outlineTitle)
        for url in [
            layout.manifestURL,
            layout.backupManifestURL,
            layout.pageDescriptorURL(page.id)
        ] {
            XCTAssertFalse(
                String(decoding: try Data(contentsOf: url), as: UTF8.self)
                    .contains("Chapter 1"),
                "Cleared outline content remained in \(url.lastPathComponent)."
            )
        }

        let reopenedAfterClear = try FileNotebookRepository(rootURL: root)
        let durableClear = try await reopenedAfterClear.openNotebook(id: created.id)
        XCTAssertEqual(durableClear, cleared)
        XCTAssertEqual(try decodePage(at: layout.pageDescriptorURL(page.id)), cleared.pages[0])

        let unchanged = try await reopenedAfterClear.updatePageNavigationMetadata(
            notebookID: created.id,
            pageID: page.id,
            update: .outlineTitle(nil)
        )
        XCTAssertEqual(unchanged.revision, cleared.revision)
    }

    func testFieldScopedUpdatesPreserveConcurrentNavigationMetadata() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor()
        let created = try await repository.createNotebook(
            title: "Field scoped",
            initialPage: page
        )

        let bookmarked = try await repository.updatePageNavigationMetadata(
            notebookID: created.id,
            pageID: page.id,
            update: .bookmark(true)
        )
        let outlinedFromStaleClient = try await repository
            .updatePageNavigationMetadata(
                notebookID: created.id,
                pageID: page.id,
                update: .outlineTitle("Concurrent outline")
            )

        XCTAssertTrue(bookmarked.pages[0].isBookmarked)
        XCTAssertNil(bookmarked.pages[0].outlineTitle)
        XCTAssertTrue(outlinedFromStaleClient.pages[0].isBookmarked)
        XCTAssertEqual(
            outlinedFromStaleClient.pages[0].outlineTitle,
            "Concurrent outline"
        )
    }

    func testInvalidOutlineUpdateLeavesPackageUnchanged() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor()
        let created = try await repository.createNotebook(
            title: "No mutation",
            initialPage: page
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))
        let manifestBefore = try Data(contentsOf: layout.manifestURL)
        let pageBefore = try Data(contentsOf: layout.pageDescriptorURL(page.id))
        let operationsBefore = try operationJSONCount(in: layout)
        let overByteBudgetTitle = String(
            repeating: "a\u{0301}\u{0301}\u{0301}\u{0301}",
            count: PageDescriptor.maximumOutlineTitleCharacters
        )
        let invalidTitles = [
            "",
            " padded",
            "padded ",
            "line\nbreak",
            "control\u{0000}character",
            String(repeating: "x", count: PageDescriptor.maximumOutlineTitleCharacters + 1),
            overByteBudgetTitle
        ]

        for title in invalidTitles {
            do {
                _ = try await repository.updatePageNavigationMetadata(
                    notebookID: created.id,
                    pageID: page.id,
                    update: .outlineTitle(title)
                )
                XCTFail("Invalid outline metadata must be rejected: \(title.debugDescription)")
            } catch let error as NotebookRepositoryError {
                guard case .invalidPageNavigationMetadata(let rejectedPageID, _) = error else {
                    return XCTFail("Unexpected repository error: \(error)")
                }
                XCTAssertEqual(rejectedPageID, page.id)
            }
            XCTAssertEqual(try Data(contentsOf: layout.manifestURL), manifestBefore)
            XCTAssertEqual(try Data(contentsOf: layout.pageDescriptorURL(page.id)), pageBefore)
            XCTAssertEqual(try operationJSONCount(in: layout), operationsBefore)
            XCTAssertTrue(try transactionDirectories(in: layout).isEmpty)
        }

        let reopened = try await repository.openNotebook(id: created.id)
        XCTAssertEqual(reopened, created)
    }

    func testNavigationMetadataUpdateFailsClosedOnDescriptorDivergence() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(title: "Manifest title")
        let created = try await repository.createNotebook(
            title: "Partial provider sync",
            initialPage: page
        )
        let layout = NotebookPackageLayout(
            packageURL: repository.packageURL(for: created.id)
        )
        var diskPage = try decodePage(at: layout.pageDescriptorURL(page.id))
        diskPage.title = "Disk-side newer title"
        try encodePage(diskPage).write(
            to: layout.pageDescriptorURL(page.id),
            options: .atomic
        )
        let manifestBefore = try Data(contentsOf: layout.manifestURL)
        let descriptorBefore = try Data(
            contentsOf: layout.pageDescriptorURL(page.id)
        )
        let operationsBefore = try operationJSONCount(in: layout)

        do {
            _ = try await repository.updatePageNavigationMetadata(
                notebookID: created.id,
                pageID: page.id,
                update: .bookmark(true)
            )
            XCTFail("Divergent descriptors must require explicit recovery.")
        } catch NotebookRepositoryError.corruptedFile(let path) {
            XCTAssertEqual(path, "pages/\(page.id)/page.json")
        }

        XCTAssertEqual(try Data(contentsOf: layout.manifestURL), manifestBefore)
        XCTAssertEqual(
            try Data(contentsOf: layout.pageDescriptorURL(page.id)),
            descriptorBefore
        )
        XCTAssertEqual(try operationJSONCount(in: layout), operationsBefore)
        XCTAssertTrue(try transactionDirectories(in: layout).isEmpty)
    }

    func testNavigationMetadataUpdateRejectsLinkedPageDescriptorWithoutTouchingTarget() async throws {
        let (repository, root) = try makeRepository()
        let page = PageDescriptor()
        let created = try await repository.createNotebook(
            title: "Linked descriptor",
            initialPage: page
        )
        let layout = NotebookPackageLayout(
            packageURL: repository.packageURL(for: created.id)
        )
        let external = root.appendingPathComponent(
            "external-page.json",
            isDirectory: false
        )
        let sentinel = Data("outside must not change".utf8)
        try sentinel.write(to: external, options: .atomic)
        try FileManager.default.removeItem(at: layout.pageDescriptorURL(page.id))
        try FileManager.default.createSymbolicLink(
            at: layout.pageDescriptorURL(page.id),
            withDestinationURL: external
        )
        let manifestBefore = try Data(contentsOf: layout.manifestURL)

        do {
            _ = try await repository.updatePageNavigationMetadata(
                notebookID: created.id,
                pageID: page.id,
                update: .bookmark(true)
            )
            XCTFail("A linked page descriptor must fail closed.")
        } catch is NotebookRepositoryError {
            // Expected.
        }

        XCTAssertEqual(try Data(contentsOf: external), sentinel)
        XCTAssertEqual(try Data(contentsOf: layout.manifestURL), manifestBefore)
        XCTAssertTrue(try transactionDirectories(in: layout).isEmpty)
    }

    func testNavigationMetadataTransactionRollsBackBothDescriptors() async throws {
        let (repository, root) = try makeRepository()
        let page = PageDescriptor()
        let created = try await repository.createNotebook(
            title: "Rollback",
            initialPage: page
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))
        let manifestBefore = try Data(contentsOf: layout.manifestURL)
        let backupBefore = try? Data(contentsOf: layout.backupManifestURL)
        let pageBefore = try Data(contentsOf: layout.pageDescriptorURL(page.id))
        let operationsBefore = try operationJSONCount(in: layout)
        let failure = PageNavigationOneShotFailure(
            .beforeStateWrite(relativePath: "manifest.json")
        )
        let failingRepository = try FileNotebookRepository(rootURL: root) { point in
            try failure.trigger(point)
        }

        do {
            _ = try await failingRepository.updatePageNavigationMetadata(
                notebookID: created.id,
                pageID: page.id,
                update: .outlineTitle("Must roll back")
            )
            XCTFail("The injected manifest-write failure must escape.")
        } catch is PageNavigationInjectedFailure {
            // Expected.
        }

        XCTAssertEqual(try Data(contentsOf: layout.manifestURL), manifestBefore)
        XCTAssertEqual(try? Data(contentsOf: layout.backupManifestURL), backupBefore)
        XCTAssertEqual(try Data(contentsOf: layout.pageDescriptorURL(page.id)), pageBefore)
        XCTAssertEqual(try operationJSONCount(in: layout), operationsBefore)
        XCTAssertTrue(try transactionDirectories(in: layout).isEmpty)

        let reopened = try FileNotebookRepository(rootURL: root)
        let durableManifest = try await reopened.openNotebook(id: created.id)
        XCTAssertEqual(durableManifest, created)
    }

    func testVersionThreeStillRequiresStructuredContentWhileVersionTwoUsesLegacyFallback() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(kind: .textDocument)
        let created = try await repository.createNotebook(
            title: "Content contract",
            initialPage: page
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))
        try FileManager.default.removeItem(at: layout.contentURL(page.id))
        try rewritePageSchema(
            at: layout.manifestURL,
            version: PageDescriptor.structuredContentSchemaVersion,
            nestedPage: true
        )
        try rewritePageSchema(
            at: layout.pageDescriptorURL(page.id),
            version: PageDescriptor.structuredContentSchemaVersion,
            nestedPage: false
        )

        do {
            _ = try await repository.loadPageContent(
                notebookID: created.id,
                pageID: page.id
            )
            XCTFail("Schema-v3 structured pages must require content.json.")
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(error, .missingPageContent(page.id))
        }
        let versionThreeValidation = try await repository.validateNotebook(id: created.id)
        XCTAssertTrue(versionThreeValidation.issues.contains {
            $0.kind == .missingPageContent
        })

        try rewritePageSchema(
            at: layout.manifestURL,
            version: PageDescriptor.structuredContentSchemaVersion - 1,
            nestedPage: true
        )
        try rewritePageSchema(
            at: layout.pageDescriptorURL(page.id),
            version: PageDescriptor.structuredContentSchemaVersion - 1,
            nestedPage: false
        )
        let legacyContent = try await repository.loadPageContent(
            notebookID: created.id,
            pageID: page.id
        )
        XCTAssertEqual(legacyContent, .textDocument(TextDocument()))
        let legacyValidation = try await repository.validateNotebook(id: created.id)
        XCTAssertFalse(legacyValidation.issues.contains {
            $0.kind == .missingPageContent
        })
        XCTAssertTrue(legacyValidation.isValid)

        let migrated = try await repository.updatePageNavigationMetadata(
            notebookID: created.id,
            pageID: page.id,
            update: .bookmark(true)
        )
        XCTAssertEqual(
            migrated.pages[0].schemaVersion,
            PageDescriptor.currentSchemaVersion
        )
        XCTAssertTrue(migrated.pages[0].isBookmarked)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: layout.contentURL(page.id).path
        ))
        let migratedContent = try await repository.loadPageContent(
            notebookID: created.id,
            pageID: page.id
        )
        XCTAssertEqual(migratedContent, .textDocument(TextDocument()))
        let migratedValidation = try await repository.validateNotebook(id: created.id)
        XCTAssertTrue(migratedValidation.isValid)
    }

    func testValidationDetectsDivergentPageNavigationMetadata() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor()
        let created = try await repository.createNotebook(
            title: "Descriptor fence",
            initialPage: page
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))
        var diskPage = try decodePage(at: layout.pageDescriptorURL(page.id))
        diskPage.isBookmarked = true
        diskPage.outlineTitle = "Tampered outline"
        try encodePage(diskPage).write(
            to: layout.pageDescriptorURL(page.id),
            options: .atomic
        )

        let validation = try await repository.validateNotebook(id: created.id)
        XCTAssertTrue(validation.issues.contains {
            $0.kind == .pageDescriptorMismatch
        })
        XCTAssertFalse(validation.isValid)
    }

    func testRecoveryDurablyReconcilesValidDivergentPageDescriptor() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(title: "Manifest title")
        let created = try await repository.createNotebook(
            title: "Descriptor recovery",
            initialPage: page
        )
        let layout = NotebookPackageLayout(
            packageURL: repository.packageURL(for: created.id)
        )
        var diskPage = try decodePage(at: layout.pageDescriptorURL(page.id))
        diskPage.title = "Disk authority"
        diskPage.isBookmarked = true
        diskPage.outlineTitle = "Recovered outline"
        diskPage.modifiedAt = Date()
        try encodePage(diskPage).write(
            to: layout.pageDescriptorURL(page.id),
            options: .atomic
        )
        let validationBeforeRecovery = try await repository.validateNotebook(
            id: created.id
        )
        XCTAssertFalse(validationBeforeRecovery.isValid)

        let recovery = try await repository.recoverNotebook(id: created.id)

        XCTAssertTrue(recovery.actions.contains(.reconciledPageDescriptor))
        XCTAssertTrue(recovery.validation.isValid)
        XCTAssertEqual(recovery.manifest.revision, created.revision + 1)
        XCTAssertEqual(recovery.manifest.pages, [diskPage])
        let reopened = try await repository.openNotebook(id: created.id)
        XCTAssertEqual(reopened, recovery.manifest)
        XCTAssertEqual(
            try decodePage(at: layout.pageDescriptorURL(page.id)),
            reopened.pages[0]
        )
        let validationAfterReopen = try await repository.validateNotebook(
            id: created.id
        )
        XCTAssertTrue(validationAfterReopen.isValid)
    }

    func testRecoveryMigratesVersionThreeNavigationMetadataWithoutLosingBookmark() async throws {
        let (repository, _) = try makeRepository()
        let page = PageDescriptor(isBookmarked: true)
        let created = try await repository.createNotebook(
            title: "Legacy navigation",
            initialPage: page
        )
        let layout = NotebookPackageLayout(packageURL: repository.packageURL(for: created.id))
        try rewritePageSchema(
            at: layout.manifestURL,
            version: 3,
            nestedPage: true
        )
        try rewritePageSchema(
            at: layout.pageDescriptorURL(page.id),
            version: 3,
            nestedPage: false
        )

        let legacy = try await repository.openNotebook(id: created.id)
        XCTAssertEqual(legacy.pages[0].schemaVersion, 3)
        XCTAssertTrue(legacy.pages[0].isBookmarked)
        XCTAssertNil(legacy.pages[0].outlineTitle)

        let recovery = try await repository.recoverNotebook(id: created.id)
        XCTAssertTrue(recovery.actions.contains(.migratedSchema))
        XCTAssertTrue(recovery.validation.isValid)
        XCTAssertEqual(recovery.manifest.pages[0].schemaVersion, PageDescriptor.currentSchemaVersion)
        XCTAssertTrue(recovery.manifest.pages[0].isBookmarked)
        XCTAssertNil(recovery.manifest.pages[0].outlineTitle)
        XCTAssertEqual(
            try decodePage(at: layout.pageDescriptorURL(page.id)),
            recovery.manifest.pages[0]
        )
    }
}

private extension PageNavigationMetadataRepositoryTests {
    func makeRepository() throws -> (FileNotebookRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PageNavigationMetadataTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = try FileNotebookRepository(rootURL: root)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return (repository, root)
    }

    func decodePage(at url: URL) throws -> PageDescriptor {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let value = try container.decode(String.self)
            let prefix = "notes-date-v1:"
            guard value.hasPrefix(prefix),
                  let bits = UInt64(value.dropFirst(prefix.count), radix: 16) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a repository date."
                )
            }
            return Date(timeIntervalSinceReferenceDate: Double(bitPattern: bits))
        }
        return try decoder.decode(PageDescriptor.self, from: Data(contentsOf: url))
    }

    func encodePage(_ page: PageDescriptor) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(
                "notes-date-v1:\(String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16))"
            )
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(page)
    }

    func operationJSONCount(in layout: NotebookPackageLayout) throws -> Int {
        try FileManager.default.contentsOfDirectory(
            at: layout.operationsURL,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }.count
    }

    func transactionDirectories(in layout: NotebookPackageLayout) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: layout.transactionsURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    func rewritePageSchema(at url: URL, version: Int, nestedPage: Bool) throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        if nestedPage {
            var pages = try XCTUnwrap(object["pages"] as? [[String: Any]])
            XCTAssertEqual(pages.count, 1)
            pages[0]["schemaVersion"] = version
            pages[0].removeValue(forKey: "outlineTitle")
            object["pages"] = pages
        } else {
            object["schemaVersion"] = version
            object.removeValue(forKey: "outlineTitle")
        }
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).write(to: url, options: .atomic)
    }
}

private struct PageNavigationInjectedFailure: Error {}

private final class PageNavigationOneShotFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var point: StorageFailurePoint?

    init(_ point: StorageFailurePoint) {
        self.point = point
    }

    func trigger(_ candidate: StorageFailurePoint) throws {
        lock.lock()
        defer { lock.unlock() }
        guard candidate == point else { return }
        point = nil
        throw PageNavigationInjectedFailure()
    }
}
