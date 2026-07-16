import Foundation
@preconcurrency import Speech

public enum SpeechTranscriptionError: LocalizedError, Equatable, Sendable {
    case authorizationDenied
    case recognizerUnavailable
    case onDeviceRecognitionUnavailable
    case alreadyTranscribing
    case invalidAudioFile
    case invalidLocale
    case noTranscript

    public var errorDescription: String? {
        switch self {
        case .authorizationDenied: "Speech recognition permission is required."
        case .recognizerUnavailable: "Speech recognition is temporarily unavailable."
        case .onDeviceRecognitionUnavailable: "On-device recognition is unavailable for this language."
        case .alreadyTranscribing: "Another audio file is already being transcribed."
        case .invalidAudioFile: "The selected audio file is invalid or too large."
        case .invalidLocale: "The speech recognition language is invalid."
        case .noTranscript: "No speech could be transcribed."
        }
    }
}

public protocol SpeechTranscribing: Sendable {
    func requestAuthorization() async -> Bool
    func transcribe(fileURL: URL, localeIdentifier: String) async throws -> [TranscriptSegment]
}

public actor OnDeviceSpeechTranscriber: SpeechTranscribing {
    private let maximumAudioBytes: Int64
    private var activeOperationID: UUID?

    public init(maximumAudioBytes: Int64 = 8 * 1_024 * 1_024 * 1_024) {
        self.maximumAudioBytes = maximumAudioBytes
    }

    public func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
        }
    }

    public func transcribe(
        fileURL: URL,
        localeIdentifier: String = "zh-Hant-TW"
    ) async throws -> [TranscriptSegment] {
        guard activeOperationID == nil else { throw SpeechTranscriptionError.alreadyTranscribing }
        let operationID = UUID()
        activeOperationID = operationID
        defer {
            if activeOperationID == operationID { activeOperationID = nil }
        }

        try Task.checkCancellation()
        try validateAudioFile(fileURL)
        guard !localeIdentifier.isEmpty,
              localeIdentifier.utf8.count <= 128,
              !localeIdentifier.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SpeechTranscriptionError.invalidLocale
        }
        guard await requestAuthorization() else {
            try Task.checkCancellation()
            throw SpeechTranscriptionError.authorizationDenied
        }
        try Task.checkCancellation()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            throw SpeechTranscriptionError.invalidLocale
        }
        guard recognizer.isAvailable else {
            throw SpeechTranscriptionError.recognizerUnavailable
        }
        guard recognizer.supportsOnDeviceRecognition else {
            throw SpeechTranscriptionError.onDeviceRecognitionUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        let operation = SpeechRecognitionOperation()
        let segments = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.install(continuation)
                if Task.isCancelled {
                    operation.cancel()
                    return
                }
                let recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        operation.finish(.failure(error))
                        return
                    }
                    guard let result, result.isFinal else { return }
                    let segments = result.bestTranscription.segments.compactMap { segment -> TranscriptSegment? in
                        let start = segment.timestamp
                        let duration = segment.duration
                        let confidence = Double(segment.confidence)
                        guard start.isFinite,
                              duration.isFinite,
                              start >= 0,
                              duration >= 0 else { return nil }
                        return TranscriptSegment(
                            text: segment.substring,
                            startTime: start,
                            duration: duration,
                            confidence: confidence.isFinite ? min(max(confidence, 0), 1) : 0
                        )
                    }
                    if segments.isEmpty {
                        operation.finish(.failure(SpeechTranscriptionError.noTranscript))
                    } else {
                        operation.finish(.success(segments))
                    }
                }
                operation.setTask(recognitionTask)
            }
        } onCancel: {
            operation.cancel()
        }
        try Task.checkCancellation()
        return segments
    }

    private func validateAudioFile(_ url: URL) throws {
        guard url.isFileURL, maximumAudioBytes > 0 else {
            throw SpeechTranscriptionError.invalidAudioFile
        }
        do {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size > 0,
                  Int64(size) <= maximumAudioBytes else {
                throw SpeechTranscriptionError.invalidAudioFile
            }
        } catch is SpeechTranscriptionError {
            throw SpeechTranscriptionError.invalidAudioFile
        } catch {
            throw SpeechTranscriptionError.invalidAudioFile
        }
    }
}

private final class SpeechRecognitionOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[TranscriptSegment], Error>?
    private var task: SFSpeechRecognitionTask?
    private var isCancelled = false
    private var isFinished = false

    func install(_ continuation: CheckedContinuation<[TranscriptSegment], Error>) {
        var resumeCancellation = false
        lock.lock()
        if isCancelled || isFinished {
            isFinished = true
            resumeCancellation = true
        } else {
            self.continuation = continuation
        }
        lock.unlock()
        if resumeCancellation { continuation.resume(throwing: CancellationError()) }
    }

    func setTask(_ task: SFSpeechRecognitionTask) {
        var shouldCancel = false
        lock.lock()
        if isCancelled || isFinished {
            shouldCancel = true
        } else {
            self.task = task
        }
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func finish(_ result: Result<[TranscriptSegment], Error>) {
        let continuation: CheckedContinuation<[TranscriptSegment], Error>?
        lock.lock()
        if isFinished || isCancelled {
            continuation = nil
        } else {
            isFinished = true
            continuation = self.continuation
            self.continuation = nil
            task = nil
        }
        lock.unlock()
        continuation?.resume(with: result)
    }

    func cancel() {
        let continuation: CheckedContinuation<[TranscriptSegment], Error>?
        let task: SFSpeechRecognitionTask?
        lock.lock()
        if isFinished || isCancelled {
            continuation = nil
            task = nil
        } else {
            isCancelled = true
            continuation = self.continuation
            self.continuation = nil
            task = self.task
            self.task = nil
            if continuation != nil { isFinished = true }
        }
        lock.unlock()
        task?.cancel()
        continuation?.resume(throwing: CancellationError())
    }
}
