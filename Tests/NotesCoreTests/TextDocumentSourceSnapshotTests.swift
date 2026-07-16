import Foundation
import XCTest
@testable import NotesCore

final class TextDocumentSourceSnapshotTests: XCTestCase {
    func testExactTextHashMatchesKnownUTF8SHA256Vectors() {
        XCTAssertEqual(
            ExactTextHash.sha256UTF8(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            ExactTextHash.sha256UTF8("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            ExactTextHash.sha256UTF8("課堂 🧪\n"),
            "aa5202800a356205b3f84f9649887f010fbad52ab4ab3f6f06a48d51658ca537"
        )
    }

    func testExactTextHashPreservesWhitespaceAndUnicodeScalarSequence() {
        XCTAssertEqual(
            ExactTextHash.sha256UTF8(" leading and trailing "),
            "81b14516b5d1331335d162196dd07afa36d1d8c801c561e590c3dedb95c3cc59"
        )
        XCTAssertNotEqual(
            ExactTextHash.sha256UTF8(" leading and trailing "),
            ExactTextHash.sha256UTF8("leading and trailing")
        )

        let decomposed = "e\u{301}"
        let precomposed = "\u{e9}"
        XCTAssertEqual(decomposed, precomposed, "Swift equality is normalization-insensitive")
        XCTAssertEqual(
            ExactTextHash.sha256UTF8(decomposed),
            "bf12767b0f2a56b2190075bae8169f656e3ce8d6357d4aff184bc6c7ea48f9f6"
        )
        XCTAssertEqual(
            ExactTextHash.sha256UTF8(precomposed),
            "4a99557e4033c3539de2eb65472017cad5f9557f7a0625a09f1c3f6e2ba69c4c"
        )
        XCTAssertNotEqual(
            ExactTextHash.sha256UTF8(decomposed),
            ExactTextHash.sha256UTF8(precomposed)
        )
    }

    func testRepositoryReturnsExactAuthoritativeBlockSnapshot() async throws {
        let fixture = try await makeTextDocumentFixture()
        let target = makeBlock(
            id: textBlockID(2),
            style: .quote,
            text: "  Keep exact whitespace.\n第二行 🧪  "
        )
        let saved = try await save(
            blocks: [makeBlock(id: textBlockID(1), text: "First"), target],
            in: fixture
        )

        let provider: any TextDocumentSourceSnapshotProviding = fixture.repository
        let snapshot = try await provider.textDocumentSourceSnapshot(
            noteID: fixture.noteID,
            pageID: fixture.pageID,
            blockID: target.id
        )

        XCTAssertEqual(snapshot.noteID, fixture.noteID)
        XCTAssertEqual(snapshot.pageID, fixture.pageID)
        XCTAssertEqual(snapshot.blockID, target.id)
        XCTAssertEqual(snapshot.blockIndex, 1)
        XCTAssertEqual(snapshot.block, target)
        XCTAssertEqual(snapshot.text, target.text)
        XCTAssertEqual(snapshot.noteRevision, saved.revision)
        XCTAssertEqual(snapshot.textHash, ExactTextHash.sha256UTF8(target.text))
    }

    func testRepositoryLocatesStableBlockIdentityAfterReorder() async throws {
        let fixture = try await makeTextDocumentFixture()
        let first = makeBlock(id: textBlockID(10), text: "First")
        let target = makeBlock(id: textBlockID(11), text: "Target")
        _ = try await save(blocks: [first, target], in: fixture)
        let before = try await fixture.repository.textDocumentSourceSnapshot(
            noteID: fixture.noteID,
            pageID: fixture.pageID,
            blockID: target.id
        )

        let reordered = try await save(blocks: [target, first], in: fixture)
        let after = try await fixture.repository.textDocumentSourceSnapshot(
            noteID: fixture.noteID,
            pageID: fixture.pageID,
            blockID: target.id
        )

        XCTAssertEqual(before.blockIndex, 1)
        XCTAssertEqual(after.blockIndex, 0)
        XCTAssertEqual(after.blockID, target.id)
        XCTAssertEqual(after.text, target.text)
        XCTAssertEqual(after.textHash, before.textHash)
        XCTAssertEqual(after.noteRevision, reordered.revision)
        XCTAssertGreaterThan(after.noteRevision, before.noteRevision)
    }

    func testRepositoryRejectsMissingBlockAndPage() async throws {
        let fixture = try await makeTextDocumentFixture()
        _ = try await save(
            blocks: [makeBlock(id: textBlockID(20), text: "Present")],
            in: fixture
        )
        let missingBlock = textBlockID(21)

        do {
            _ = try await fixture.repository.textDocumentSourceSnapshot(
                noteID: fixture.noteID,
                pageID: fixture.pageID,
                blockID: missingBlock
            )
            XCTFail("A missing block must not produce a source snapshot.")
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(
                error,
                .textBlockNotFound(pageID: fixture.pageID, blockID: missingBlock)
            )
        }

        let missingPage = pageID(99)
        do {
            _ = try await fixture.repository.textDocumentSourceSnapshot(
                noteID: fixture.noteID,
                pageID: missingPage,
                blockID: missingBlock
            )
            XCTFail("A missing page must not produce a source snapshot.")
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(error, .pageNotFound(missingPage))
        }
    }

    func testRepositoryRejectsNonTextDocumentPage() async throws {
        let (repository, _) = try makeRepository()
        let noteID = notebookID(30)
        let wrongPage = PageDescriptor(
            id: pageID(30),
            kind: .studySet,
            title: "Cards",
            createdAt: fixedDate
        )
        _ = try await repository.createNotebook(
            id: noteID,
            title: "Wrong kind",
            initialPage: wrongPage,
            createdAt: fixedDate
        )

        do {
            _ = try await repository.textDocumentSourceSnapshot(
                noteID: noteID,
                pageID: wrongPage.id,
                blockID: textBlockID(30)
            )
            XCTFail("A study-set page must not produce a text source snapshot.")
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(
                error,
                .pageContentTypeMismatch(
                    pageID: wrongPage.id,
                    expected: .textDocument,
                    actual: .studySet
                )
            )
        }
    }

    func testRepositoryFailsClosedForMissingCorruptAndMismatchedContent() async throws {
        let fixture = try await makeTextDocumentFixture()
        let block = makeBlock(id: textBlockID(40), text: "Durable")
        _ = try await save(blocks: [block], in: fixture)
        let layout = fixture.layout
        let contentURL = layout.contentURL(fixture.pageID)

        try FileManager.default.removeItem(at: contentURL)
        await assertRepositoryError(
            .missingPageContent(fixture.pageID),
            from: fixture.repository,
            fixture: fixture,
            blockID: block.id
        )

        try Data("{not-json".utf8).write(to: contentURL)
        await assertCorruptedFile(
            fixture.repository,
            fixture: fixture,
            blockID: block.id,
            pathSuffix: "content.json"
        )

        let wrongKind = Data(
            """
            {"schemaVersion":1,"type":"studySet","studySet":{"schemaVersion":1,"cards":[],"progress":[]}}
            """.utf8
        )
        try wrongKind.write(to: contentURL, options: .atomic)
        await assertRepositoryError(
            .pageContentTypeMismatch(
                pageID: fixture.pageID,
                expected: .textDocument,
                actual: .studySet
            ),
            from: fixture.repository,
            fixture: fixture,
            blockID: block.id
        )
    }

    func testRepositoryNeverFollowsContentSymbolicLink() async throws {
        let fixture = try await makeTextDocumentFixture()
        let block = makeBlock(id: textBlockID(50), text: "Inside")
        _ = try await save(blocks: [block], in: fixture)
        let contentURL = fixture.layout.contentURL(fixture.pageID)
        let outsideURL = fixture.rootURL.appendingPathComponent("outside-content.json")
        try Data("{}".utf8).write(to: outsideURL)
        try FileManager.default.removeItem(at: contentURL)
        try FileManager.default.createSymbolicLink(
            at: contentURL,
            withDestinationURL: outsideURL
        )

        await assertCorruptedFile(
            fixture.repository,
            fixture: fixture,
            blockID: block.id,
            pathSuffix: "content.json"
        )
        XCTAssertEqual(try Data(contentsOf: outsideURL), Data("{}".utf8))
    }

    func testRepositoryRejectsDescriptorThatDisagreesWithManifest() async throws {
        let fixture = try await makeTextDocumentFixture()
        let block = makeBlock(id: textBlockID(60), text: "Manifest authority")
        _ = try await save(blocks: [block], in: fixture)
        let descriptorURL = fixture.layout.pageDescriptorURL(fixture.pageID)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: descriptorURL))
                as? [String: Any]
        )
        object["title"] = "Tampered duplicate descriptor"
        try JSONSerialization.data(withJSONObject: object).write(
            to: descriptorURL,
            options: .atomic
        )

        await assertCorruptedFile(
            fixture.repository,
            fixture: fixture,
            blockID: block.id,
            pathSuffix: "page.json"
        )
    }

    func testRepositoryEnforcesContentBoundBeforeAllocation() async throws {
        let fixture = try await makeTextDocumentFixture()
        let block = makeBlock(id: textBlockID(70), text: "Bounded")
        _ = try await save(blocks: [block], in: fixture)
        let contentURL = fixture.layout.contentURL(fixture.pageID)
        let maximumEncodedBytes = 16 * 1_024 * 1_024
        let handle = try FileHandle(forWritingTo: contentURL)
        try handle.truncate(atOffset: UInt64(maximumEncodedBytes + 1))
        try handle.close()

        do {
            _ = try await fixture.repository.textDocumentSourceSnapshot(
                noteID: fixture.noteID,
                pageID: fixture.pageID,
                blockID: block.id
            )
            XCTFail("An oversized content file must fail before allocation.")
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(
                error,
                .boundedReadLimitExceeded(
                    relativePath: "pages/\(fixture.pageID.description)/content.json",
                    limit: maximumEncodedBytes
                )
            )
        }
    }

    func testRepositoryRejectsContentPathReplacementDuringSnapshot() async throws {
        let replacement = SourceSnapshotReplacement()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TextDocumentSourceSnapshotMutation-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = try FileNotebookRepository(rootURL: root) { point in
            try replacement.trigger(point)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let noteID = notebookID(80)
        let pageID = pageID(80)
        let block = makeBlock(id: textBlockID(80), text: "Old authoritative bytes")
        let page = PageDescriptor(
            id: pageID,
            kind: .textDocument,
            title: "Mutation",
            createdAt: fixedDate
        )
        _ = try await repository.createNotebook(
            id: noteID,
            title: "Mutation fence",
            initialPage: page,
            createdAt: fixedDate
        )
        try await repository.savePageContent(
            .textDocument(TextDocument(blocks: [block])),
            notebookID: noteID,
            pageID: pageID
        )
        let contentURL = NotebookPackageLayout(
            packageURL: repository.packageURL(for: noteID)
        ).contentURL(pageID)
        replacement.configure(
            contentURL: contentURL,
            replacement: Data("{\"replacement\":true}".utf8)
        )

        do {
            _ = try await repository.textDocumentSourceSnapshot(
                noteID: noteID,
                pageID: pageID,
                blockID: block.id
            )
            XCTFail("A path replacement during the read must invalidate the snapshot.")
        } catch NotebookRepositoryError.corruptedFile(let path) {
            XCTAssertTrue(path.hasSuffix("content.json"))
        }
        XCTAssertTrue(replacement.didReplace)
    }
}

private extension TextDocumentSourceSnapshotTests {
    struct Fixture {
        let repository: FileNotebookRepository
        let rootURL: URL
        let noteID: NotebookID
        let pageID: PageID

        var layout: NotebookPackageLayout {
            NotebookPackageLayout(packageURL: repository.packageURL(for: noteID))
        }
    }

    var fixedDate: Date { Date(timeIntervalSinceReferenceDate: 123_456.75) }

    func makeRepository() throws -> (FileNotebookRepository, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TextDocumentSourceSnapshotTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let repository = try FileNotebookRepository(rootURL: root)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (repository, root)
    }

    func makeTextDocumentFixture() async throws -> Fixture {
        let (repository, root) = try makeRepository()
        let noteID = notebookID(1)
        let pageID = pageID(1)
        let page = PageDescriptor(
            id: pageID,
            kind: .textDocument,
            title: "Session note",
            createdAt: fixedDate
        )
        _ = try await repository.createNotebook(
            id: noteID,
            title: "Exact anchors",
            initialPage: page,
            createdAt: fixedDate
        )
        return Fixture(
            repository: repository,
            rootURL: root,
            noteID: noteID,
            pageID: pageID
        )
    }

    func save(
        blocks: [TextBlock],
        in fixture: Fixture
    ) async throws -> NotebookManifest {
        try await fixture.repository.savePageContent(
            .textDocument(TextDocument(blocks: blocks)),
            notebookID: fixture.noteID,
            pageID: fixture.pageID
        )
        return try await fixture.repository.openNotebook(id: fixture.noteID)
    }

    func makeBlock(
        id: TextBlockID,
        style: TextBlockStyle = .body,
        text: String
    ) -> TextBlock {
        TextBlock(
            id: id,
            style: style,
            text: text,
            createdAt: fixedDate
        )
    }

    func notebookID(_ byte: UInt8) -> NotebookID {
        NotebookID(UUID(uuid: (byte, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)))
    }

    func pageID(_ byte: UInt8) -> PageID {
        PageID(UUID(uuid: (byte, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2)))
    }

    func textBlockID(_ byte: UInt8) -> TextBlockID {
        TextBlockID(UUID(uuid: (byte, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3)))
    }

    func assertRepositoryError(
        _ expected: NotebookRepositoryError,
        from repository: FileNotebookRepository,
        fixture: Fixture,
        blockID: TextBlockID,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await repository.textDocumentSourceSnapshot(
                noteID: fixture.noteID,
                pageID: fixture.pageID,
                blockID: blockID
            )
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as NotebookRepositoryError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    func assertCorruptedFile(
        _ repository: FileNotebookRepository,
        fixture: Fixture,
        blockID: TextBlockID,
        pathSuffix: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await repository.textDocumentSourceSnapshot(
                noteID: fixture.noteID,
                pageID: fixture.pageID,
                blockID: blockID
            )
            XCTFail("Expected a corrupt-file error", file: file, line: line)
        } catch NotebookRepositoryError.corruptedFile(let path) {
            XCTAssertTrue(path.hasSuffix(pathSuffix), "Unexpected path: \(path)", file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private final class SourceSnapshotReplacement: @unchecked Sendable {
    private let lock = NSLock()
    private var contentURL: URL?
    private var replacement = Data()
    private var replaced = false

    var didReplace: Bool {
        lock.lock()
        defer { lock.unlock() }
        return replaced
    }

    func configure(contentURL: URL, replacement: Data) {
        lock.lock()
        self.contentURL = contentURL
        self.replacement = replacement
        replaced = false
        lock.unlock()
    }

    func trigger(_ point: StorageFailurePoint) throws {
        guard case .duringBoundedContentRead(let relativePath, let bytesRead) = point,
              relativePath.hasSuffix("content.json"),
              bytesRead > 0 else { return }
        let mutation: (URL, Data)?
        lock.lock()
        if !replaced, let contentURL {
            replaced = true
            mutation = (contentURL, replacement)
        } else {
            mutation = nil
        }
        lock.unlock()
        if let mutation {
            try mutation.1.write(to: mutation.0, options: .atomic)
        }
    }
}
