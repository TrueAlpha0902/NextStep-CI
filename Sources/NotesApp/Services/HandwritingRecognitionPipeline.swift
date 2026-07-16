import CryptoKit
import Foundation
import ImageIO
import NotesCore
import NotesServices
import UIKit

enum HandwritingRecognitionPipelineError: LocalizedError, Equatable {
    case invalidRaster
    case invalidRecognitionResult
    case tooManyCandidates(limit: Int)

    var errorDescription: String? {
        switch self {
        case .invalidRaster:
            String(localized: "The handwriting image could not be prepared.")
        case .invalidRecognitionResult:
            String(localized: "The handwriting recognition result was invalid.")
        case .tooManyCandidates(let limit):
            String(
                localized: "Handwriting recognition is limited to \(limit) suggestions per page."
            )
        }
    }
}

struct HandwritingRecognitionSnapshot: Equatable, Sendable {
    let document: HandwritingRecognitionDocument
    let isCurrentForInk: Bool
}

/// Bounded, local-only fallback recognition for PencilKit ink on iPadOS 18.
/// Machine output remains a suggestion document with no accepted reviews.
struct HandwritingRecognitionPipeline {
    static let engineIdentifier = "com.speci.notes.vision-handwriting-fallback"
    static let engineRevision = 1

    private let textRecognizer: any TextRecognitionService

    init(textRecognizer: (any TextRecognitionService)? = nil) {
        self.textRecognizer = textRecognizer ?? VisionTextRecognitionService(
            limits: TextRecognitionLimits(
                maximumEncodedBytes: 40 * 1_024 * 1_024,
                maximumPixels: 8_388_608,
                maximumLanguages: HandwritingRecognitionLimits.maximumLanguageCount,
                maximumSegments: HandwritingRecognitionLimits.maximumCandidateCount
            )
        )
    }

    @MainActor
    func recognize(
        drawingData: Data,
        pageSize: CGSize,
        pageID: PageID,
        languages: [String] = ["zh-Hant", "en-US"]
    ) async throws -> HandwritingRecognitionDocument {
        try Task.checkCancellation()
        let image = try PageExportRenderer.renderInkOnlyRecognitionImage(
            drawingData: drawingData,
            pageSize: pageSize
        )
        try Task.checkCancellation()
        guard let imageData = autoreleasepool(invoking: { image.pngData() }) else {
            throw HandwritingRecognitionPipelineError.invalidRaster
        }
        try Task.checkCancellation()
        let segments = try await textRecognizer.recognize(
            imageData: imageData,
            orientation: .up,
            languages: languages,
            pageID: pageID.rawValue
        )
        try Task.checkCancellation()
        return try Self.makeDocument(
            segments: segments,
            pageID: pageID,
            sourceInkSHA256: Self.sourceInkSHA256(for: drawingData),
            languages: languages
        )
    }

    static func makeDocument(
        segments: [RecognizedTextSegment],
        pageID: PageID,
        sourceInkSHA256: String,
        languages: [String],
        generatedAt: Date = .now,
        runID: UUID = UUID()
    ) throws -> HandwritingRecognitionDocument {
        guard !segments.isEmpty else { throw TextRecognitionError.noResults }
        guard segments.count <= HandwritingRecognitionLimits.maximumCandidateCount else {
            throw HandwritingRecognitionPipelineError.tooManyCandidates(
                limit: HandwritingRecognitionLimits.maximumCandidateCount
            )
        }
        let normalizedLanguages = normalizedLanguages(languages)
        var candidateIDs = Set<UUID>()
        let candidates = try segments.map { segment -> HandwritingMachineCandidate in
            guard segment.source == .scannedImage,
                  segment.pageID == pageID.rawValue,
                  candidateIDs.insert(segment.id).inserted,
                  segment.confidence.isFinite,
                  (0 ... 1).contains(segment.confidence),
                  let bounds = topLeftBounds(fromVision: segment.bounds) else {
                throw HandwritingRecognitionPipelineError.invalidRecognitionResult
            }
            return HandwritingMachineCandidate(
                id: segment.id,
                machineText: segment.text,
                machineConfidence: segment.confidence,
                normalizedPageBounds: bounds,
                localeIdentifier: segment.localeIdentifier
            )
        }
        let document = HandwritingRecognitionDocument(
            runID: runID,
            pageID: pageID,
            sourceInkSHA256: sourceInkSHA256,
            engineIdentifier: engineIdentifier,
            engineRevision: engineRevision,
            languages: normalizedLanguages,
            generatedAt: generatedAt,
            modifiedAt: generatedAt,
            machineCandidates: candidates
        )
        try document.validate(expectedPageID: pageID)
        return document
    }

    /// Vision uses a lower-left origin; durable review UI uses upper-left page
    /// coordinates. Clip the far edges instead of allowing independently
    /// clamped origin and size values to exceed the page.
    private static func topLeftBounds(
        fromVision bounds: NormalizedRect?
    ) -> HandwritingNormalizedBounds? {
        guard let bounds,
              bounds.x.isFinite,
              bounds.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite else { return nil }
        let minX = min(max(bounds.x, 0), 1)
        let minY = min(max(bounds.y, 0), 1)
        let maxX = min(max(bounds.x + bounds.width, minX), 1)
        let maxY = min(max(bounds.y + bounds.height, minY), 1)
        let width = maxX - minX
        let height = maxY - minY
        guard width > 0, height > 0 else { return nil }
        return HandwritingNormalizedBounds(
            x: minX,
            y: 1 - maxY,
            width: width,
            height: height
        )
    }

    private static func normalizedLanguages(_ languages: [String]) -> [String] {
        var seen = Set<String>()
        return languages.compactMap { language in
            let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, seen.insert(key).inserted else { return nil }
            return trimmed
        }
    }

    static func sourceInkSHA256(for data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
