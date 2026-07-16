import Foundation
@preconcurrency import PDFKit
@preconcurrency import UIKit

public enum PDFTextExtractionError: LocalizedError, Equatable, Sendable {
    case invalidDocument
    case emptyDocument
    case documentTooLarge
    case invalidPageIndex
    case invalidRenderSize
    case tooManyConcurrentOperations

    public var errorDescription: String? {
        switch self {
        case .invalidDocument: "The PDF could not be opened."
        case .emptyDocument: "The PDF does not contain selectable text."
        case .documentTooLarge: "The PDF is too large to process safely on this device."
        case .invalidPageIndex: "The requested PDF page does not exist."
        case .invalidRenderSize: "The requested PDF preview size is invalid."
        case .tooManyConcurrentOperations: "Too many PDF operations are running at once."
        }
    }
}

public struct PDFTextExtractionLimits: Hashable, Sendable {
    public var maximumEncodedBytes: Int
    public var maximumPageCount: Int
    public var maximumCharactersPerPage: Int
    public var maximumTotalCharacters: Int
    public var maximumRenderDimension: CGFloat
    public var maximumConcurrentOperations: Int

    public init(
        maximumEncodedBytes: Int = 512 * 1_024 * 1_024,
        maximumPageCount: Int = 20_000,
        maximumCharactersPerPage: Int = 5_000_000,
        maximumTotalCharacters: Int = 100_000_000,
        maximumRenderDimension: CGFloat = 8_192,
        maximumConcurrentOperations: Int = 2
    ) {
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumPageCount = maximumPageCount
        self.maximumCharactersPerPage = maximumCharactersPerPage
        self.maximumTotalCharacters = maximumTotalCharacters
        self.maximumRenderDimension = maximumRenderDimension
        self.maximumConcurrentOperations = maximumConcurrentOperations
    }
}

public actor PDFTextExtractor {
    private let limits: PDFTextExtractionLimits
    private var activeOperations = 0

    public init(limits: PDFTextExtractionLimits = PDFTextExtractionLimits()) {
        self.limits = limits
    }

    public func extract(data: Data, pageIDs: [UUID] = []) async throws -> [RecognizedTextSegment] {
        try validateInput(data)
        try beginOperation()
        defer { activeOperations -= 1 }
        let limits = self.limits
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard let document = PDFDocument(data: data) else {
                throw PDFTextExtractionError.invalidDocument
            }
            try Self.validatePageCount(document.pageCount, limits: limits)

            var segments: [RecognizedTextSegment] = []
            var totalCharacters = 0
            for pageIndex in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let text = document.page(at: pageIndex)?.string?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { continue }
                guard text.count <= limits.maximumCharactersPerPage else {
                    throw PDFTextExtractionError.documentTooLarge
                }
                let (sum, overflow) = totalCharacters.addingReportingOverflow(text.count)
                guard !overflow, sum <= limits.maximumTotalCharacters else {
                    throw PDFTextExtractionError.documentTooLarge
                }
                totalCharacters = sum
                segments.append(
                    RecognizedTextSegment(
                        text: text,
                        pageID: pageIDs.indices.contains(pageIndex) ? pageIDs[pageIndex] : nil,
                        source: .pdfText
                    )
                )
            }
            guard !segments.isEmpty else { throw PDFTextExtractionError.emptyDocument }
            return segments
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public func extract(
        data: Data,
        pageIndex: Int,
        pageID: UUID? = nil
    ) async throws -> RecognizedTextSegment {
        try validateInput(data)
        guard pageIndex >= 0 else { throw PDFTextExtractionError.invalidPageIndex }
        try beginOperation()
        defer { activeOperations -= 1 }
        let limits = self.limits
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard let document = PDFDocument(data: data) else {
                throw PDFTextExtractionError.invalidDocument
            }
            try Self.validatePageCount(document.pageCount, limits: limits)
            guard pageIndex < document.pageCount else { throw PDFTextExtractionError.invalidPageIndex }
            guard let text = document.page(at: pageIndex)?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                throw PDFTextExtractionError.emptyDocument
            }
            guard text.count <= limits.maximumCharactersPerPage else {
                throw PDFTextExtractionError.documentTooLarge
            }
            try Task.checkCancellation()
            return RecognizedTextSegment(text: text, pageID: pageID, source: .pdfText)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public func renderPageImage(
        data: Data,
        pageIndex: Int,
        maximumDimension: CGFloat = 2_048
    ) async throws -> Data {
        try validateInput(data)
        guard pageIndex >= 0 else { throw PDFTextExtractionError.invalidPageIndex }
        guard maximumDimension.isFinite,
              maximumDimension > 0,
              maximumDimension <= limits.maximumRenderDimension else {
            throw PDFTextExtractionError.invalidRenderSize
        }
        try beginOperation()
        defer { activeOperations -= 1 }
        let limits = self.limits
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            guard let document = PDFDocument(data: data) else {
                throw PDFTextExtractionError.invalidDocument
            }
            try Self.validatePageCount(document.pageCount, limits: limits)
            guard pageIndex < document.pageCount,
                  let page = document.page(at: pageIndex) else {
                throw PDFTextExtractionError.invalidPageIndex
            }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width.isFinite,
                  bounds.height.isFinite,
                  bounds.width > 0,
                  bounds.height > 0 else {
                throw PDFTextExtractionError.invalidDocument
            }
            let scale = maximumDimension / max(bounds.width, bounds.height)
            let size = CGSize(
                width: max(1, bounds.width * scale),
                height: max(1, bounds.height * scale)
            )
            try Task.checkCancellation()
            guard let png = page.thumbnail(of: size, for: .mediaBox).pngData() else {
                throw PDFTextExtractionError.invalidDocument
            }
            try Task.checkCancellation()
            return png
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func validateInput(_ data: Data) throws {
        guard limits.maximumEncodedBytes > 0,
              limits.maximumPageCount > 0,
              limits.maximumCharactersPerPage > 0,
              limits.maximumTotalCharacters > 0,
              limits.maximumRenderDimension > 0,
              limits.maximumConcurrentOperations > 0 else {
            throw PDFTextExtractionError.documentTooLarge
        }
        guard !data.isEmpty else { throw PDFTextExtractionError.invalidDocument }
        guard data.count <= limits.maximumEncodedBytes else {
            throw PDFTextExtractionError.documentTooLarge
        }
    }

    private func beginOperation() throws {
        guard activeOperations < limits.maximumConcurrentOperations else {
            throw PDFTextExtractionError.tooManyConcurrentOperations
        }
        activeOperations += 1
    }

    private static func validatePageCount(
        _ pageCount: Int,
        limits: PDFTextExtractionLimits
    ) throws {
        guard pageCount > 0 else { throw PDFTextExtractionError.invalidDocument }
        guard pageCount <= limits.maximumPageCount else {
            throw PDFTextExtractionError.documentTooLarge
        }
    }
}
