import Foundation
@preconcurrency import ImageIO
@preconcurrency import Vision

public enum TextRecognitionError: LocalizedError, Equatable, Sendable {
    case noResults
    case invalidImage
    case imageTooLarge
    case invalidLanguages
    case alreadyRecognizing

    public var errorDescription: String? {
        switch self {
        case .noResults: "No readable text was found."
        case .invalidImage: "The selected image could not be decoded."
        case .imageTooLarge: "The selected image is too large to recognize safely."
        case .invalidLanguages: "One or more recognition languages are invalid."
        case .alreadyRecognizing: "Another image is already being recognized."
        }
    }
}

public struct TextRecognitionLimits: Hashable, Sendable {
    public var maximumEncodedBytes: Int
    public var maximumPixels: Int64
    public var maximumLanguages: Int
    public var maximumSegments: Int

    public init(
        maximumEncodedBytes: Int = 100 * 1_024 * 1_024,
        maximumPixels: Int64 = 100_000_000,
        maximumLanguages: Int = 8,
        maximumSegments: Int = 20_000
    ) {
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumPixels = maximumPixels
        self.maximumLanguages = maximumLanguages
        self.maximumSegments = maximumSegments
    }
}

public protocol TextRecognitionService: Sendable {
    func recognize(
        imageData: Data,
        orientation: CGImagePropertyOrientation,
        languages: [String],
        pageID: UUID?
    ) async throws -> [RecognizedTextSegment]
}

public actor VisionTextRecognitionService: TextRecognitionService {
    private let limits: TextRecognitionLimits
    private var isRecognizing = false

    public init(limits: TextRecognitionLimits = TextRecognitionLimits()) {
        self.limits = limits
    }

    public func recognize(
        imageData: Data,
        orientation: CGImagePropertyOrientation = .up,
        languages: [String] = ["zh-Hant", "en-US"],
        pageID: UUID? = nil
    ) async throws -> [RecognizedTextSegment] {
        try Task.checkCancellation()
        try Self.validateImage(imageData, limits: limits)
        let validatedLanguages = try Self.validate(languages: languages, limits: limits)
        guard !isRecognizing else { throw TextRecognitionError.alreadyRecognizing }
        isRecognizing = true
        defer { isRecognizing = false }

        let cancellation = VisionRequestCancellation()
        let segmentLimit = limits.maximumSegments
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let request = VNRecognizeTextRequest()
            cancellation.install(request)
            defer { cancellation.clear(request) }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.minimumTextHeight = 0.008
            request.recognitionLanguages = validatedLanguages

            let handler = VNImageRequestHandler(data: imageData, orientation: orientation)
            do {
                try handler.perform([request])
            } catch {
                try Task.checkCancellation()
                throw error
            }
            try Task.checkCancellation()

            let observations = (request.results ?? []).sorted { left, right in
                let yDifference = left.boundingBox.midY - right.boundingBox.midY
                if abs(yDifference) > 0.002 { return yDifference > 0 }
                return left.boundingBox.minX < right.boundingBox.minX
            }
            let segments = observations.prefix(segmentLimit).compactMap { observation -> RecognizedTextSegment? in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                let box = observation.boundingBox
                guard !text.isEmpty,
                      box.origin.x.isFinite,
                      box.origin.y.isFinite,
                      box.width.isFinite,
                      box.height.isFinite else { return nil }
                let confidence = Double(candidate.confidence)
                return RecognizedTextSegment(
                    text: text,
                    confidence: confidence.isFinite ? min(max(confidence, 0), 1) : 0,
                    bounds: NormalizedRect(
                        x: Double(min(max(box.origin.x, 0), 1)),
                        y: Double(min(max(box.origin.y, 0), 1)),
                        width: Double(min(max(box.width, 0), 1)),
                        height: Double(min(max(box.height, 0), 1))
                    ),
                    pageID: pageID,
                    source: .scannedImage,
                    localeIdentifier: validatedLanguages.first
                )
            }
            guard !segments.isEmpty else { throw TextRecognitionError.noResults }
            return segments
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            cancellation.cancel()
            worker.cancel()
        }
    }

    private static func validateImage(_ data: Data, limits: TextRecognitionLimits) throws {
        guard !data.isEmpty,
              limits.maximumEncodedBytes > 0,
              limits.maximumPixels > 0,
              limits.maximumSegments > 0,
              data.count <= limits.maximumEncodedBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              width > 0,
              height > 0 else {
            if data.count > limits.maximumEncodedBytes { throw TextRecognitionError.imageTooLarge }
            throw TextRecognitionError.invalidImage
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= limits.maximumPixels else { throw TextRecognitionError.imageTooLarge }
    }

    private static func validate(
        languages: [String],
        limits: TextRecognitionLimits
    ) throws -> [String] {
        guard limits.maximumLanguages > 0,
              !languages.isEmpty,
              languages.count <= limits.maximumLanguages else {
            throw TextRecognitionError.invalidLanguages
        }
        var seen = Set<String>()
        var result: [String] = []
        for language in languages {
            let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.range(
                of: #"^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8}){0,3}$"#,
                options: .regularExpression
            ) != nil else {
                throw TextRecognitionError.invalidLanguages
            }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted { result.append(trimmed) }
        }
        guard !result.isEmpty else { throw TextRecognitionError.invalidLanguages }
        return result
    }
}

private final class VisionRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var isCancelled = false

    func install(_ request: VNRequest) {
        var shouldCancel = false
        lock.lock()
        if isCancelled {
            shouldCancel = true
        } else {
            self.request = request
        }
        lock.unlock()
        if shouldCancel { request.cancel() }
    }

    func clear(_ request: VNRequest) {
        lock.lock()
        if self.request === request { self.request = nil }
        lock.unlock()
    }

    func cancel() {
        let request: VNRequest?
        lock.lock()
        isCancelled = true
        request = self.request
        self.request = nil
        lock.unlock()
        request?.cancel()
    }
}
