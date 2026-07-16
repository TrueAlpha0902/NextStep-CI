import CryptoKit
import Darwin
import Foundation
import NotesCore

enum NotebookAudioTranscriptExportFormat: String, CaseIterable, Identifiable, Sendable {
    case plainText
    case subRip

    var id: String { rawValue }

    var pathExtension: String {
        switch self {
        case .plainText: "txt"
        case .subRip: "srt"
        }
    }
}

enum NotebookAudioExportError: Error, Equatable, Sendable, LocalizedError {
    case invalidRecording
    case recordingTooLarge(maximumBytes: Int64)
    case incompleteRecording
    case recordingIntegrityMismatch
    case transcriptUnavailable
    case invalidTranscript
    case transcriptOutputTooLarge(maximumBytes: Int)
    case insufficientStorage
    case unsafeExportDirectory
    case unsafeExportFile

    var errorDescription: String? {
        switch self {
        case .invalidRecording:
            String(localized: "This recording cannot be exported because its saved metadata is invalid.")
        case .recordingTooLarge:
            String(localized: "This recording is too large to export safely.")
        case .incompleteRecording:
            String(localized: "The complete recording could not be read for export.")
        case .recordingIntegrityMismatch:
            String(localized: "The recording changed or failed its integrity check during export.")
        case .transcriptUnavailable:
            String(localized: "This recording does not have a saved transcript to export.")
        case .invalidTranscript:
            String(localized: "This saved transcript contains invalid timing data and cannot be exported.")
        case .transcriptOutputTooLarge:
            String(localized: "This transcript is too large to export safely.")
        case .insufficientStorage:
            String(localized: "There is not enough free space to create this export.")
        case .unsafeExportDirectory, .unsafeExportFile:
            String(localized: "A secure temporary export file could not be created.")
        }
    }
}

/// Main-actor closures preserve AppModel's library-operation fence while the
/// exporter actor performs bounded rendering and file I/O away from the UI.
struct NotebookAudioExportDependencies: Sendable {
    let beginExportSession:
        @MainActor @Sendable (UUID) async throws -> NotesAppNotebookExportSession
    let validateExportSession:
        @MainActor @Sendable (NotesAppNotebookExportSession) async throws -> EditorNotebook
    let endExportSession:
        @MainActor @Sendable (NotesAppNotebookExportSession) async -> Void
    let descriptor:
        @MainActor @Sendable (NotesAppNotebookExportSession, AudioSessionID) async throws
            -> AudioSessionDescriptor
    let loadAudioChunk:
        @MainActor @Sendable (
            NotesAppNotebookExportSession,
            AudioSessionID,
            Int64,
            Int
        ) async throws -> Data
    let loadTranscript:
        @MainActor @Sendable (NotesAppNotebookExportSession, AudioSessionID) async throws
            -> AudioTranscriptDocument?
}

enum NotebookAudioTranscriptExportRenderer {
    static let maximumPlainTextBytes = 8 * 1_024 * 1_024
    static let maximumSubRipBytes = 16 * 1_024 * 1_024
    static let maximumDurationSeconds: TimeInterval = 7 * 24 * 60 * 60

    static func data(
        for transcript: AudioTranscriptDocument,
        format: NotebookAudioTranscriptExportFormat
    ) throws -> Data {
        try Task.checkCancellation()
        let maximumBytes = format == .plainText
            ? maximumPlainTextBytes
            : maximumSubRipBytes
        var output = Data()
        output.reserveCapacity(min(maximumBytes, max(1_024, transcript.segments.count * 64)))
        var cueNumber = 0

        for (index, segment) in transcript.segments.enumerated() {
            if index.isMultiple(of: 128) {
                try Task.checkCancellation()
            }
            let text = sanitizedText(segment.text, for: format)
            guard !text.isEmpty else { continue }
            let segmentEnd = segment.startTime + segment.duration
            guard segment.startTime.isFinite,
                  segment.startTime >= 0,
                  segment.duration.isFinite,
                  segment.duration >= 0,
                  segmentEnd.isFinite,
                  segmentEnd <= maximumDurationSeconds + 0.001 else {
                throw NotebookAudioExportError.invalidTranscript
            }

            let block: String
            switch format {
            case .plainText:
                block = "[\(plainTimestamp(segment.startTime))] \(text)\n\n"
            case .subRip:
                cueNumber += 1
                let start = subRipTimestamp(segment.startTime, rounding: .down)
                let end = subRipTimestamp(
                    segmentEnd,
                    rounding: .up
                )
                block = "\(cueNumber)\r\n\(start) --> \(end)\r\n\(text)\r\n\r\n"
            }
            try append(block, to: &output, maximumBytes: maximumBytes)
        }

        try Task.checkCancellation()
        return output
    }

    private static func append(
        _ value: String,
        to output: inout Data,
        maximumBytes: Int
    ) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= maximumBytes - output.count else {
            throw NotebookAudioExportError.transcriptOutputTooLarge(
                maximumBytes: maximumBytes
            )
        }
        output.append(bytes)
    }

    private static func sanitizedText(
        _ original: String,
        for format: NotebookAudioTranscriptExportFormat
    ) -> String {
        let normalized = original
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let allowedControls = CharacterSet(charactersIn: "\t\n")
        let scalars = normalized.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                || allowedControls.contains(scalar)
        }
        let cleaned = String(String.UnicodeScalarView(scalars))

        switch format {
        case .plainText:
            return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        case .subRip:
            // Blank lines delimit SRT cues, so remove them from cue content.
            return cleaned
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\r\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private enum TimestampRounding: Equatable {
        case down
        case up
    }

    private static func plainTimestamp(_ time: TimeInterval) -> String {
        timestamp(milliseconds: milliseconds(time, rounding: .down), separator: ".")
    }

    private static func subRipTimestamp(
        _ time: TimeInterval,
        rounding: TimestampRounding
    ) -> String {
        timestamp(milliseconds: milliseconds(time, rounding: rounding), separator: ",")
    }

    private static func milliseconds(
        _ time: TimeInterval,
        rounding: TimestampRounding
    ) -> Int64 {
        guard time.isFinite, time > 0 else { return 0 }
        let value = time * 1_000
        let rounded = rounding == .down ? value.rounded(.down) : value.rounded(.up)
        return Int64(min(rounded, Double(Int64.max)))
    }

    private static func timestamp(milliseconds totalMilliseconds: Int64, separator: String) -> String {
        let milliseconds = totalMilliseconds % 1_000
        let totalSeconds = totalMilliseconds / 1_000
        let seconds = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60
        return String(
            format: "%02lld:%02lld:%02lld%@%03lld",
            hours,
            minutes,
            seconds,
            separator,
            milliseconds
        )
    }
}

actor NotebookAudioExporter {
    static let maximumRecordingBytes: Int64 = 512 * 1_024 * 1_024
    static let chunkByteCount = 1 * 1_024 * 1_024

    private let dependencies: NotebookAudioExportDependencies
    private let exportDirectory: URL
    private let fileManager: FileManager

    init(
        dependencies: NotebookAudioExportDependencies,
        exportDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesExports", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.dependencies = dependencies
        self.exportDirectory = exportDirectory.standardizedFileURL
        self.fileManager = fileManager
    }

    func exportRecording(
        notebookID: UUID,
        sessionID: AudioSessionID,
        identifier: UUID = UUID()
    ) async throws -> URL {
        let session = try await dependencies.beginExportSession(notebookID)
        let result: URL
        do {
            result = try await exportRecording(
                session: session,
                sessionID: sessionID,
                identifier: identifier
            )
        } catch {
            await dependencies.endExportSession(session)
            throw error
        }
        await dependencies.endExportSession(session)
        do {
            try Task.checkCancellation()
        } catch {
            removeOwnedExport(result)
            throw error
        }
        return result
    }

    func exportTranscript(
        notebookID: UUID,
        sessionID: AudioSessionID,
        format: NotebookAudioTranscriptExportFormat,
        identifier: UUID = UUID()
    ) async throws -> URL {
        let session = try await dependencies.beginExportSession(notebookID)
        let result: URL
        do {
            result = try await exportTranscript(
                session: session,
                sessionID: sessionID,
                format: format,
                identifier: identifier
            )
        } catch {
            await dependencies.endExportSession(session)
            throw error
        }
        await dependencies.endExportSession(session)
        do {
            try Task.checkCancellation()
        } catch {
            removeOwnedExport(result)
            throw error
        }
        return result
    }

    private func exportRecording(
        session: NotesAppNotebookExportSession,
        sessionID: AudioSessionID,
        identifier: UUID
    ) async throws -> URL {
        try Task.checkCancellation()
        let descriptor = try await dependencies.descriptor(session, sessionID)
        try validateRecordingDescriptor(descriptor, sessionID: sessionID)

        guard let expectedByteCount = descriptor.audioByteCount,
              let expectedDigest = descriptor.audioSHA256 else {
            throw NotebookAudioExportError.invalidRecording
        }
        try ensureAvailableCapacity(requiredBytes: expectedByteCount)
        let destination = try makeExclusiveExportFile(
            basename: "NextStep Recording-\(sessionID.description.prefix(8))-\(identifier.uuidString.lowercased())",
            pathExtension: "m4a"
        )
        var publishedURL: URL?
        defer {
            if publishedURL == nil {
                removeOwnedExport(destination.temporaryURL)
                removeOwnedExport(destination.finalURL)
            }
        }
        var hasher = SHA256()
        var offset: Int64 = 0
        do {
            while offset < expectedByteCount {
                try Task.checkCancellation()
                let remaining = expectedByteCount - offset
                let requested = min(Self.chunkByteCount, Int(remaining))
                let chunk = try await dependencies.loadAudioChunk(
                    session,
                    sessionID,
                    offset,
                    requested
                )
                try Task.checkCancellation()
                guard !chunk.isEmpty,
                      chunk.count <= requested,
                      Int64(chunk.count) <= remaining else {
                    throw NotebookAudioExportError.incompleteRecording
                }
                if offset == 0 {
                    guard chunk.count >= 12,
                          chunk[4] == 0x66,
                          chunk[5] == 0x74,
                          chunk[6] == 0x79,
                          chunk[7] == 0x70 else {
                        throw NotebookAudioExportError.invalidRecording
                    }
                }
                try destination.handle.write(contentsOf: chunk)
                hasher.update(data: chunk)
                offset += Int64(chunk.count)
            }
            try destination.handle.synchronize()
            try destination.handle.close()
        } catch {
            try? destination.handle.close()
            throw error
        }

        try validateTemporaryExport(destination, expectedByteCount: expectedByteCount)
        let actualDigest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actualDigest == expectedDigest else {
            throw NotebookAudioExportError.recordingIntegrityMismatch
        }

        _ = try await dependencies.validateExportSession(session)
        let finalDescriptor = try await dependencies.descriptor(session, sessionID)
        guard finalDescriptor == descriptor else {
            throw NotebookAudioExportError.recordingIntegrityMismatch
        }
        try Task.checkCancellation()
        let url = try publish(destination, expectedByteCount: expectedByteCount)
        publishedURL = url
        return url
    }

    private func exportTranscript(
        session: NotesAppNotebookExportSession,
        sessionID: AudioSessionID,
        format: NotebookAudioTranscriptExportFormat,
        identifier: UUID
    ) async throws -> URL {
        try Task.checkCancellation()
        let descriptor = try await dependencies.descriptor(session, sessionID)
        guard descriptor.id == sessionID,
              descriptor.transcriptAssetID != nil,
              let transcript = try await dependencies.loadTranscript(session, sessionID),
              transcript.audioSessionID == sessionID else {
            throw NotebookAudioExportError.transcriptUnavailable
        }
        let data = try NotebookAudioTranscriptExportRenderer.data(
            for: transcript,
            format: format
        )
        try ensureAvailableCapacity(requiredBytes: Int64(data.count))
        let destination = try makeExclusiveExportFile(
            basename: "NextStep Transcript-\(sessionID.description.prefix(8))-\(identifier.uuidString.lowercased())",
            pathExtension: format.pathExtension
        )
        var publishedURL: URL?
        defer {
            if publishedURL == nil {
                removeOwnedExport(destination.temporaryURL)
                removeOwnedExport(destination.finalURL)
            }
        }
        do {
            try destination.handle.write(contentsOf: data)
            try destination.handle.synchronize()
            try destination.handle.close()
        } catch {
            try? destination.handle.close()
            throw error
        }
        try validateTemporaryExport(destination, expectedByteCount: Int64(data.count))

        _ = try await dependencies.validateExportSession(session)
        let finalDescriptor = try await dependencies.descriptor(session, sessionID)
        guard finalDescriptor == descriptor else {
            throw NotebookAudioExportError.recordingIntegrityMismatch
        }
        try Task.checkCancellation()
        let url = try publish(destination, expectedByteCount: Int64(data.count))
        publishedURL = url
        return url
    }

    private func validateRecordingDescriptor(
        _ descriptor: AudioSessionDescriptor,
        sessionID: AudioSessionID
    ) throws {
        guard (2...AudioSessionDescriptor.currentSchemaVersion)
                .contains(descriptor.schemaVersion),
              descriptor.id == sessionID,
              descriptor.chunkFilenames.count == 1,
              isSafeM4AFilename(descriptor.chunkFilenames[0]),
              let byteCount = descriptor.audioByteCount,
              byteCount >= 12,
              let digest = descriptor.audioSHA256,
              digest.utf8.count == 64,
              digest == digest.lowercased(),
              digest.unicodeScalars.allSatisfy({
                  (48 ... 57).contains($0.value) || (97 ... 102).contains($0.value)
              }) else {
            throw NotebookAudioExportError.invalidRecording
        }
        guard byteCount <= Self.maximumRecordingBytes else {
            throw NotebookAudioExportError.recordingTooLarge(
                maximumBytes: Self.maximumRecordingBytes
            )
        }
    }

    private func isSafeM4AFilename(_ filename: String) -> Bool {
        guard !filename.isEmpty,
              filename.utf8.count <= 255,
              !filename.hasPrefix("."),
              !filename.contains("/"),
              !filename.contains("\\"),
              !filename.contains(":"),
              !filename.contains("\0") else { return false }
        return URL(fileURLWithPath: filename).lastPathComponent == filename
            && URL(fileURLWithPath: filename).pathExtension.lowercased() == "m4a"
    }

    private struct ExclusiveExportFile {
        let temporaryURL: URL
        let finalURL: URL
        let handle: FileHandle
        let device: dev_t
        let inode: ino_t
    }

    private func makeExclusiveExportFile(
        basename: String,
        pathExtension: String
    ) throws -> ExclusiveExportFile {
        guard exportDirectory.isFileURL,
              ["m4a", "txt", "srt"].contains(pathExtension.lowercased()) else {
            throw NotebookAudioExportError.unsafeExportDirectory
        }
        try fileManager.createDirectory(
            at: exportDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        try validateExportDirectory()

        let directoryDescriptor = exportDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard directoryDescriptor >= 0 else {
            throw NotebookAudioExportError.unsafeExportDirectory
        }
        defer { _ = Darwin.close(directoryDescriptor) }

        let finalFilename = "\(basename).\(pathExtension.lowercased())"
        let temporaryFilename = ".\(basename).partial.\(UUID().uuidString.lowercased()).\(pathExtension.lowercased())"
        guard [finalFilename, temporaryFilename].allSatisfy({ filename in
            filename.utf8.count <= 255
                && !filename.contains("/")
                && !filename.contains("\\")
                && !filename.contains("\0")
        }) else {
            throw NotebookAudioExportError.unsafeExportFile
        }
        let fileDescriptor = temporaryFilename.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard fileDescriptor >= 0 else {
            throw NotebookAudioExportError.unsafeExportFile
        }

        var metadata = stat()
        guard Darwin.fstat(fileDescriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1 else {
            _ = Darwin.close(fileDescriptor)
            _ = temporaryFilename.withCString {
                Darwin.unlinkat(directoryDescriptor, $0, 0)
            }
            throw NotebookAudioExportError.unsafeExportFile
        }
        let temporaryURL = exportDirectory.appendingPathComponent(
            temporaryFilename,
            isDirectory: false
        )
        let finalURL = exportDirectory.appendingPathComponent(finalFilename, isDirectory: false)
        do {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: temporaryURL.path
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableURL = temporaryURL
            try mutableURL.setResourceValues(values)
        } catch {
            _ = Darwin.close(fileDescriptor)
            _ = temporaryFilename.withCString {
                Darwin.unlinkat(directoryDescriptor, $0, 0)
            }
            throw NotebookAudioExportError.unsafeExportFile
        }
        return ExclusiveExportFile(
            temporaryURL: temporaryURL,
            finalURL: finalURL,
            handle: FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true),
            device: metadata.st_dev,
            inode: metadata.st_ino
        )
    }

    private func validateExportDirectory() throws {
        let directoryValues = try exportDirectory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        let trustedRoot = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedDirectory = exportDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let trustedPrefix = trustedRoot.path.hasSuffix("/")
            ? trustedRoot.path
            : trustedRoot.path + "/"
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true,
              resolvedDirectory.path.hasPrefix(trustedPrefix) else {
            throw NotebookAudioExportError.unsafeExportDirectory
        }
    }

    private func ensureAvailableCapacity(requiredBytes: Int64) throws {
        guard requiredBytes >= 0 else {
            throw NotebookAudioExportError.unsafeExportFile
        }
        let capacityURL = fileManager.fileExists(atPath: exportDirectory.path)
            ? exportDirectory
            : exportDirectory.deletingLastPathComponent()
        let values = try capacityURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        let reserve: Int64 = 16 * 1_024 * 1_024
        guard requiredBytes <= Int64.max - reserve,
              available >= requiredBytes + reserve else {
            throw NotebookAudioExportError.insufficientStorage
        }
    }

    private func validateTemporaryExport(
        _ file: ExclusiveExportFile,
        expectedByteCount: Int64
    ) throws {
        let directoryDescriptor = try openExportDirectory()
        defer { _ = Darwin.close(directoryDescriptor) }
        var metadata = stat()
        let result = file.temporaryURL.lastPathComponent.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_dev == file.device,
              metadata.st_ino == file.inode,
              metadata.st_size == off_t(expectedByteCount) else {
            throw NotebookAudioExportError.unsafeExportFile
        }
    }

    private func publish(
        _ file: ExclusiveExportFile,
        expectedByteCount: Int64
    ) throws -> URL {
        let directoryDescriptor = try openExportDirectory()
        defer { _ = Darwin.close(directoryDescriptor) }
        let temporaryName = file.temporaryURL.lastPathComponent
        let finalName = file.finalURL.lastPathComponent
        let linkResult = temporaryName.withCString { temporaryPointer in
            finalName.withCString { finalPointer in
                Darwin.linkat(
                    directoryDescriptor,
                    temporaryPointer,
                    directoryDescriptor,
                    finalPointer,
                    0
                )
            }
        }
        guard linkResult == 0 else {
            throw NotebookAudioExportError.unsafeExportFile
        }
        let unlinkResult = temporaryName.withCString {
            Darwin.unlinkat(directoryDescriptor, $0, 0)
        }
        guard unlinkResult == 0 else {
            _ = finalName.withCString { Darwin.unlinkat(directoryDescriptor, $0, 0) }
            throw NotebookAudioExportError.unsafeExportFile
        }

        var metadata = stat()
        let statResult = finalName.withCString {
            Darwin.fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
        }
        guard statResult == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1,
              metadata.st_dev == file.device,
              metadata.st_ino == file.inode,
              metadata.st_size == off_t(expectedByteCount) else {
            _ = finalName.withCString { Darwin.unlinkat(directoryDescriptor, $0, 0) }
            throw NotebookAudioExportError.unsafeExportFile
        }
        return file.finalURL
    }

    private func openExportDirectory() throws -> Int32 {
        try validateExportDirectory()
        let descriptor = exportDirectory.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            throw NotebookAudioExportError.unsafeExportDirectory
        }
        return descriptor
    }

    private func removeOwnedExport(_ url: URL) {
        guard url.standardizedFileURL.deletingLastPathComponent() == exportDirectory,
              ["m4a", "txt", "srt"].contains(url.pathExtension.lowercased()) else { return }
        guard let directoryDescriptor = try? openExportDirectory() else { return }
        defer { _ = Darwin.close(directoryDescriptor) }
        _ = url.lastPathComponent.withCString {
            Darwin.unlinkat(directoryDescriptor, $0, 0)
        }
    }
}
