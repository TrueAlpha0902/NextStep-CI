import Foundation
import XCTest
@testable import NotesCore

final class RepositoryDatePrecisionTests: XCTestCase {
    func testRepositoryDateCodingPreservesDatesExactlyAcrossEpochs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesDatePrecisionTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let repository = try FileNotebookRepository(rootURL: root)
        let page = PageDescriptor()
        let created = try await repository.createNotebook(title: "Date precision", initialPage: page)
        let exactDate = Date(timeIntervalSinceReferenceDate: 800_000_000.000_000_1)
        let element = CanvasElement(
            frame: CanvasRect(x: 0, y: 0, width: 10, height: 10),
            content: .text(TextElement(text: "Exact")),
            createdAt: exactDate,
            modifiedAt: exactDate
        )

        try await repository.saveElements([element], notebookID: created.id, pageID: page.id)
        let loaded = try await repository.loadElements(notebookID: created.id, pageID: page.id)

        XCTAssertEqual(loaded, [element])
        XCTAssertEqual(loaded.first?.createdAt.timeIntervalSinceReferenceDate.bitPattern,
                       exactDate.timeIntervalSinceReferenceDate.bitPattern)
    }
}
