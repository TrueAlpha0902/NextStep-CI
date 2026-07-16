import Foundation
import NotesCore
@testable import NotesApp
import XCTest

final class CanvasElementFactoryTests: XCTestCase {
    func testCreatesEveryElementKindWithUniqueStableIdentityAndContainedFrames() throws {
        let bounds = CanvasRect(x: 0, y: 0, width: 768, height: 1_024)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let assetID = AssetID(String(repeating: "a", count: 64))
        var elements: [CanvasElement] = []

        for (index, kind) in CanvasElementKind.allCases.enumerated() {
            let id = ElementID()
            let element: CanvasElement?
            if kind == .link {
                element = CanvasElementFactory.makeLink(
                    title: "OpenAI",
                    destination: try XCTUnwrap(URL(string: "https://openai.com")),
                    ordinal: index,
                    pageBounds: bounds,
                    now: now,
                    id: id
                )
            } else {
                element = CanvasElementFactory.make(
                    kind,
                    assetID: kind == .image || kind == .sticker ? assetID : nil,
                    ordinal: index,
                    pageBounds: bounds,
                    now: now,
                    id: id
                )
            }
            let created = try XCTUnwrap(element, "Missing factory output for \(kind.rawValue)")
            XCTAssertEqual(created.id, id)
            XCTAssertEqual(created.createdAt, now)
            XCTAssertGreaterThanOrEqual(created.frame.x, bounds.x)
            XCTAssertGreaterThanOrEqual(created.frame.y, bounds.y)
            XCTAssertLessThanOrEqual(created.frame.x + created.frame.width, bounds.x + bounds.width)
            XCTAssertLessThanOrEqual(created.frame.y + created.frame.height, bounds.y + bounds.height)
            elements.append(created)
        }

        XCTAssertEqual(Set(elements.map(\.id)).count, CanvasElementKind.allCases.count)
        XCTAssertEqual(elements.count, 8)
        XCTAssertTrue(elements.contains { if case .text = $0.content { true } else { false } })
        XCTAssertTrue(elements.contains { if case .image = $0.content { true } else { false } })
        XCTAssertTrue(elements.contains { if case .shape = $0.content { true } else { false } })
        XCTAssertTrue(elements.contains { if case .connector = $0.content { true } else { false } })
        XCTAssertTrue(elements.contains { if case .stickyNote = $0.content { true } else { false } })
        XCTAssertTrue(elements.contains { if case .tape = $0.content { true } else { false } })
        XCTAssertTrue(elements.contains { if case .sticker = $0.content { true } else { false } })
        XCTAssertTrue(elements.contains { if case .link = $0.content { true } else { false } })
        XCTAssertEqual(
            CanvasElementFactory.referencedAssetIDs(in: elements),
            [assetID, assetID]
        )
    }

    func testAssetElementsRequireAContentAddressedAssetIdentifier() {
        let bounds = CanvasRect(x: 0, y: 0, width: 768, height: 1_024)

        XCTAssertNil(CanvasElementFactory.make(
            .image,
            ordinal: 0,
            pageBounds: bounds,
            now: .now
        ))
        XCTAssertNil(CanvasElementFactory.make(
            .sticker,
            assetID: AssetID("not-a-digest"),
            ordinal: 0,
            pageBounds: bounds,
            now: .now
        ))
    }

    func testLocalStoreRejectsMissingAndNonImageElementAssets() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesCanvasAssetValidation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalNotebookStore(overrideRoot: root)
        let notebook = try await store.createNotebook(
            title: "Assets",
            kind: .notebook,
            template: .blank
        )
        let page = try XCTUnwrap(notebook.pages.first)
        let bounds = CanvasRect(x: 0, y: 0, width: page.width, height: page.height)
        let missing = try XCTUnwrap(CanvasElementFactory.make(
            .image,
            assetID: AssetID(String(repeating: "b", count: 64)),
            ordinal: 0,
            pageBounds: bounds,
            now: .now
        ))

        do {
            try await store.saveElements([missing], notebookID: notebook.id, pageID: page.id)
            XCTFail("A missing image asset must not be persisted.")
        } catch LocalNotebookStore.StoreError.invalidAssetPath {
            // Expected.
        }

        let repository = try FileNotebookRepository(
            rootURL: root.appendingPathComponent("Notes", isDirectory: true)
        )
        let nonImageAsset = try await repository.importAsset(
            Data("not an image".utf8),
            notebookID: NotebookID(notebook.id),
            mediaType: "application/pdf",
            originalFilename: "reference.pdf"
        )
        let nonImage = try XCTUnwrap(CanvasElementFactory.make(
            .sticker,
            assetID: nonImageAsset.id,
            ordinal: 0,
            pageBounds: bounds,
            now: .now
        ))

        do {
            try await store.saveElements([nonImage], notebookID: notebook.id, pageID: page.id)
            XCTFail("A non-image asset must not be persisted as a sticker.")
        } catch LocalNotebookStore.StoreError.invalidAssetPath {
            // Expected.
        }
    }

    func testLinkValidationAcceptsOnlyCompleteHTTPAndHTTPSURLs() {
        XCTAssertNotNil(CanvasElementFactory.validatedLinkURL("https://example.com/path"))
        XCTAssertNotNil(CanvasElementFactory.validatedLinkURL("http://example.com"))
        XCTAssertNil(CanvasElementFactory.validatedLinkURL("example.com"))
        XCTAssertNil(CanvasElementFactory.validatedLinkURL("file:///private/note"))
        XCTAssertNil(CanvasElementFactory.validatedLinkURL("javascript:alert(1)"))
        XCTAssertNil(CanvasElementFactory.validatedLinkURL("https://"))
    }

    func testWorkspacePreservesPageAspectRatioAndInsetsItFromContainerEdges() {
        let frame = CanvasElementWorkspaceLayout.fittedFrame(
            pageSize: CGSize(width: 768, height: 1_024),
            containerSize: CGSize(width: 1_200, height: 900)
        )

        XCTAssertEqual(frame.width / frame.height, 768.0 / 1_024.0, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(frame.minX, 24)
        XCTAssertGreaterThanOrEqual(frame.minY, 24)
        XCTAssertLessThanOrEqual(frame.maxX, 1_176)
        XCTAssertLessThanOrEqual(frame.maxY, 876)
    }

    func testAssetCacheQuantizesResizeRequestsWithoutExceedingTheRequestedBound() {
        XCTAssertEqual(CanvasElementAssetCachePolicy.pixelBucket(for: 1), 1)
        XCTAssertEqual(CanvasElementAssetCachePolicy.pixelBucket(for: 301), 256)
        XCTAssertEqual(CanvasElementAssetCachePolicy.pixelBucket(for: 2_049), 2_048)
        XCTAssertEqual(CanvasElementAssetCachePolicy.pixelBucket(for: 10_000), 4_096)
    }
}
