import Foundation
import Testing
import UIKit
@testable import NotesServices

@Test("Vision rejects encoded image bombs before recognition")
func visionRejectsOversizedInput() async throws {
    let service = VisionTextRecognitionService(
        limits: TextRecognitionLimits(
            maximumEncodedBytes: 4,
            maximumPixels: 100,
            maximumLanguages: 2,
            maximumSegments: 10
        )
    )
    await #expect(throws: TextRecognitionError.imageTooLarge) {
        try await service.recognize(imageData: Data(repeating: 0, count: 5))
    }
}

@Test("Vision validates BCP-47 language identifiers")
@MainActor
func visionRejectsInvalidLanguages() async throws {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2))
    let data = renderer.image { context in
        UIColor.white.setFill()
        context.cgContext.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
    }.pngData()!
    let service = VisionTextRecognitionService()
    await #expect(throws: TextRecognitionError.invalidLanguages) {
        try await service.recognize(imageData: data, languages: ["../../bad"])
    }
}

@Test("PDF operations reject unsafe sizes and page indices deterministically")
@MainActor
func pdfValidationIsDeterministic() async throws {
    let smallLimit = PDFTextExtractor(
        limits: PDFTextExtractionLimits(maximumEncodedBytes: 4)
    )
    await #expect(throws: PDFTextExtractionError.documentTooLarge) {
        try await smallLimit.extract(data: Data(repeating: 0, count: 5))
    }

    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
    let validPDF = renderer.pdfData { context in
        context.beginPage()
        "Notes".draw(at: CGPoint(x: 10, y: 10), withAttributes: nil)
    }
    let extractor = PDFTextExtractor()
    await #expect(throws: PDFTextExtractionError.invalidPageIndex) {
        try await extractor.extract(data: validPDF, pageIndex: -1)
    }
    await #expect(throws: PDFTextExtractionError.invalidRenderSize) {
        try await extractor.renderPageImage(data: validPDF, pageIndex: 0, maximumDimension: .infinity)
    }
}

@Test("Speech validates its file before asking for private permissions")
func speechRejectsMissingAudioBeforeAuthorization() async throws {
    let service = OnDeviceSpeechTranscriber()
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("missing-\(UUID().uuidString).m4a")
    await #expect(throws: SpeechTranscriptionError.invalidAudioFile) {
        try await service.transcribe(fileURL: missing)
    }
}

@Test("Audio recording validates destinations before asking for microphone access")
func audioRejectsInvalidDestinationBeforeAuthorization() async throws {
    let service = AudioTimelineRecorder()
    let invalid = FileManager.default.temporaryDirectory
        .appendingPathComponent("recording-\(UUID().uuidString).txt")
    await #expect(throws: AudioTimelineError.invalidDestination) {
        try await service.startRecording(to: invalid)
    }
}
