import CryptoKit
import Foundation
import NotesCore
import XCTest
@testable import NotesApp

final class NotebookAudioExporterTests: XCTestCase {
    @MainActor
    func testRecordingExportStreamsMultipleChunksAndVerifiesFTYPAndSHA256() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exportDirectory = root.appendingPathComponent("exports", isDirectory: true)
        let audio = makeM4A(byteCount: NotebookAudioExporter.chunkByteCount + 37)
        let harness = NotebookAudioExporterHarness(audioData: audio)
        let exporter = NotebookAudioExporter(
            dependencies: harness.dependencies(),
            exportDirectory: exportDirectory
        )

        let result = try await exporter.exportRecording(
            notebookID: harness.notebook.id,
            sessionID: harness.sessionID,
            identifier: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )

        let exported = try Data(contentsOf: result)
        XCTAssertEqual(exported, audio)
        XCTAssertEqual(Data(exported[4 ..< 8]), Data([0x66, 0x74, 0x79, 0x70]))
        XCTAssertEqual(sha256(exported), sha256(audio))
        XCTAssertEqual(result.pathExtension, "m4a")
        XCTAssertEqual(harness.beginCount, 1)
        XCTAssertEqual(harness.validationCount, 1)
        XCTAssertEqual(harness.endCount, 1)
        XCTAssertEqual(harness.descriptorRequestCount, 2)
        XCTAssertEqual(harness.chunkRequests.count, 2)
        XCTAssertEqual(harness.chunkRequests[0].offset, 0)
        XCTAssertEqual(
            harness.chunkRequests[0].maximumByteCount,
            NotebookAudioExporter.chunkByteCount
        )
        XCTAssertEqual(
            harness.chunkRequests[1].offset,
            Int64(NotebookAudioExporter.chunkByteCount)
        )
        XCTAssertEqual(harness.chunkRequests[1].maximumByteCount, 37)
        XCTAssertEqual(try exportEntries(in: exportDirectory), [result])
    }

    func testTranscriptRendererProducesGoldenTXTAndSRTWithLongHoursAndSanitizedText() throws {
        let sessionID = AudioSessionID()
        let transcript = AudioTranscriptDocument(
            audioSessionID: sessionID,
            localeIdentifier: "zh-Hant-TW",
            provenance: .speechTranscriber,
            segments: [
                AudioTranscriptSegment(
                    text: " First\r\n\r\nSecond\u{0000}\tLine\rThird ",
                    startTime: (25 * 60 * 60) + 1.2344,
                    duration: 0.0002,
                    confidence: 0.98
                ),
                AudioTranscriptSegment(
                    text: " \r\n\t ",
                    startTime: (25 * 60 * 60) + 2,
                    duration: 1,
                    confidence: 0.5
                ),
            ]
        )

        let plainText = try NotebookAudioTranscriptExportRenderer.data(
            for: transcript,
            format: .plainText
        )
        let subRip = try NotebookAudioTranscriptExportRenderer.data(
            for: transcript,
            format: .subRip
        )

        XCTAssertEqual(
            String(decoding: plainText, as: UTF8.self),
            "[25:00:01.234] First\n\nSecond\tLine\nThird\n\n"
        )
        XCTAssertEqual(
            String(decoding: subRip, as: UTF8.self),
            "1\r\n25:00:01,234 --> 25:00:01,235\r\n"
                + "First\r\nSecond\tLine\r\nThird\r\n\r\n"
        )
    }

    @MainActor
    func testTranscriptExporterPublishesTXTAndSRTAndEndsEachSessionExactlyOnce() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exportDirectory = root.appendingPathComponent("exports", isDirectory: true)
        let sessionID = AudioSessionID()
        let transcript = AudioTranscriptDocument(
            audioSessionID: sessionID,
            localeIdentifier: "en-US",
            provenance: .speechTranscriber,
            segments: [
                AudioTranscriptSegment(
                    text: "Hello",
                    startTime: 0,
                    duration: 1.25,
                    confidence: 1
                ),
            ]
        )
        let harness = NotebookAudioExporterHarness(
            audioData: makeM4A(byteCount: 12),
            sessionID: sessionID,
            transcript: transcript,
            hasTranscriptReference: true
        )
        let exporter = NotebookAudioExporter(
            dependencies: harness.dependencies(),
            exportDirectory: exportDirectory
        )

        let textURL = try await exporter.exportTranscript(
            notebookID: harness.notebook.id,
            sessionID: sessionID,
            format: .plainText,
            identifier: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        )
        let subRipURL = try await exporter.exportTranscript(
            notebookID: harness.notebook.id,
            sessionID: sessionID,
            format: .subRip,
            identifier: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        )

        XCTAssertEqual(textURL.pathExtension, "txt")
        XCTAssertEqual(subRipURL.pathExtension, "srt")
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: textURL), as: UTF8.self),
            "[00:00:00.000] Hello\n\n"
        )
        XCTAssertEqual(
            String(decoding: try Data(contentsOf: subRipURL), as: UTF8.self),
            "1\r\n00:00:00,000 --> 00:00:01,250\r\nHello\r\n\r\n"
        )
        XCTAssertEqual(harness.beginCount, 2)
        XCTAssertEqual(harness.validationCount, 2)
        XCTAssertEqual(harness.endCount, 2)
        XCTAssertEqual(harness.descriptorRequestCount, 4)
        XCTAssertEqual(try exportEntries(in: exportDirectory), [subRipURL, textURL].sorted {
            $0.lastPathComponent < $1.lastPathComponent
        })
    }

    @MainActor
    func testTranscriptExportRejectsNilTranscriptWithoutLeavingFilesAndEndsExactlyOnce() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exportDirectory = root.appendingPathComponent("exports", isDirectory: true)
        let harness = NotebookAudioExporterHarness(
            audioData: makeM4A(byteCount: 12),
            transcript: nil,
            hasTranscriptReference: true
        )
        let exporter = NotebookAudioExporter(
            dependencies: harness.dependencies(),
            exportDirectory: exportDirectory
        )

        do {
            _ = try await exporter.exportTranscript(
                notebookID: harness.notebook.id,
                sessionID: harness.sessionID,
                format: .plainText
            )
            XCTFail("Expected a missing transcript to be rejected.")
        } catch {
            XCTAssertEqual(error as? NotebookAudioExportError, .transcriptUnavailable)
        }

        XCTAssertEqual(harness.beginCount, 1)
        XCTAssertEqual(harness.endCount, 1)
        XCTAssertEqual(harness.validationCount, 0)
        XCTAssertTrue(try exportEntries(in: exportDirectory).isEmpty)
    }

    @MainActor
    func testRecordingDigestMismatchCleansAllFilesAndEndsExactlyOnce() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exportDirectory = root.appendingPathComponent("exports", isDirectory: true)
        let harness = NotebookAudioExporterHarness(
            audioData: makeM4A(byteCount: 12),
            expectedDigest: String(repeating: "0", count: 64)
        )
        let exporter = NotebookAudioExporter(
            dependencies: harness.dependencies(),
            exportDirectory: exportDirectory
        )

        do {
            _ = try await exporter.exportRecording(
                notebookID: harness.notebook.id,
                sessionID: harness.sessionID
            )
            XCTFail("Expected the recording digest mismatch to be rejected.")
        } catch {
            XCTAssertEqual(error as? NotebookAudioExportError, .recordingIntegrityMismatch)
        }

        XCTAssertEqual(harness.beginCount, 1)
        XCTAssertEqual(harness.endCount, 1)
        XCTAssertEqual(harness.validationCount, 0)
        XCTAssertTrue(try exportEntries(in: exportDirectory).isEmpty)
    }

    @MainActor
    func testShortAudioChunkCleansAllFilesAndEndsExactlyOnce() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exportDirectory = root.appendingPathComponent("exports", isDirectory: true)
        let harness = NotebookAudioExporterHarness(
            audioData: makeM4A(byteCount: 13),
            chunkMode: .shortFirstRead(byteCount: 12)
        )
        let exporter = NotebookAudioExporter(
            dependencies: harness.dependencies(),
            exportDirectory: exportDirectory
        )

        do {
            _ = try await exporter.exportRecording(
                notebookID: harness.notebook.id,
                sessionID: harness.sessionID
            )
            XCTFail("Expected an incomplete audio stream to be rejected.")
        } catch {
            XCTAssertEqual(error as? NotebookAudioExportError, .incompleteRecording)
        }

        XCTAssertEqual(harness.beginCount, 1)
        XCTAssertEqual(harness.endCount, 1)
        XCTAssertEqual(harness.chunkRequests.count, 2)
        XCTAssertTrue(try exportEntries(in: exportDirectory).isEmpty)
    }

    @MainActor
    func testFinalSessionValidationFailureCleansAllFilesAndEndsExactlyOnce() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exportDirectory = root.appendingPathComponent("exports", isDirectory: true)
        let harness = NotebookAudioExporterHarness(
            audioData: makeM4A(byteCount: 12),
            validationFailure: .finalValidation
        )
        let exporter = NotebookAudioExporter(
            dependencies: harness.dependencies(),
            exportDirectory: exportDirectory
        )

        do {
            _ = try await exporter.exportRecording(
                notebookID: harness.notebook.id,
                sessionID: harness.sessionID
            )
            XCTFail("Expected final export-session validation to fail.")
        } catch {
            XCTAssertEqual(error as? NotebookAudioExporterHarnessFailure, .finalValidation)
        }

        XCTAssertEqual(harness.beginCount, 1)
        XCTAssertEqual(harness.validationCount, 1)
        XCTAssertEqual(harness.endCount, 1)
        XCTAssertTrue(try exportEntries(in: exportDirectory).isEmpty)
    }

    @MainActor
    func testCancellationWhileEndSessionIsGatedRemovesPublishedFileAndEndsExactlyOnce() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let exportDirectory = root.appendingPathComponent("exports", isDirectory: true)
        let endGate = NotebookAudioExporterEndGate()
        let harness = NotebookAudioExporterHarness(
            audioData: makeM4A(byteCount: 12),
            endGate: endGate
        )
        let exporter = NotebookAudioExporter(
            dependencies: harness.dependencies(),
            exportDirectory: exportDirectory
        )
        let notebookID = harness.notebook.id
        let sessionID = harness.sessionID

        let task = Task {
            try await exporter.exportRecording(
                notebookID: notebookID,
                sessionID: sessionID
            )
        }
        await endGate.waitUntilEntered()
        XCTAssertEqual(try exportEntries(in: exportDirectory).count, 1)

        task.cancel()
        await endGate.release()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation after the export-session cleanup gate.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(harness.beginCount, 1)
        XCTAssertEqual(harness.validationCount, 1)
        XCTAssertEqual(harness.endCount, 1)
        XCTAssertTrue(try exportEntries(in: exportDirectory).isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "notes-audio-exporter-tests-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url
    }

    private func makeM4A(byteCount: Int) -> Data {
        precondition(byteCount >= 12)
        var data = Data(repeating: 0xA5, count: byteCount)
        data.replaceSubrange(
            0 ..< 12,
            with: Data([0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x4D, 0x34, 0x41, 0x20])
        )
        return data
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func exportEntries(in directory: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

@MainActor
private final class NotebookAudioExporterHarness {
    enum ChunkMode: Sendable {
        case normal
        case shortFirstRead(byteCount: Int)
    }

    let notebook: EditorNotebook
    let sessionID: AudioSessionID
    var beginCount = 0
    var validationCount = 0
    var endCount = 0
    var descriptorRequestCount = 0
    var chunkRequests = [(offset: Int64, maximumByteCount: Int)]()

    private let descriptor: AudioSessionDescriptor
    private let audioData: Data
    private let transcript: AudioTranscriptDocument?
    private let chunkMode: ChunkMode
    private let validationFailure: NotebookAudioExporterHarnessFailure?
    private let endGate: NotebookAudioExporterEndGate?

    init(
        audioData: Data,
        sessionID: AudioSessionID = AudioSessionID(),
        transcript: AudioTranscriptDocument? = nil,
        hasTranscriptReference: Bool = false,
        expectedDigest: String? = nil,
        chunkMode: ChunkMode = .normal,
        validationFailure: NotebookAudioExporterHarnessFailure? = nil,
        endGate: NotebookAudioExporterEndGate? = nil
    ) {
        let notebookID = UUID()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        self.notebook = EditorNotebook(
            id: notebookID,
            title: "Audio export test",
            kind: .notebook,
            createdAt: now,
            modifiedAt: now,
            isFavorite: false,
            deletedAt: nil,
            coverHue: 0.25,
            pages: []
        )
        self.sessionID = sessionID
        self.audioData = audioData
        self.transcript = transcript
        self.chunkMode = chunkMode
        self.validationFailure = validationFailure
        self.endGate = endGate
        self.descriptor = AudioSessionDescriptor(
            id: sessionID,
            createdAt: now,
            durationSeconds: 10,
            chunkFilenames: ["recording.m4a"],
            audioByteCount: Int64(audioData.count),
            audioSHA256: expectedDigest ?? Self.sha256(audioData),
            timelineFilename: "timeline.json",
            transcriptAssetID: hasTranscriptReference
                ? AssetID(String(repeating: "a", count: 64))
                : nil
        )
    }

    func dependencies() -> NotebookAudioExportDependencies {
        NotebookAudioExportDependencies(
            beginExportSession: { [self] notebookID in
                try beginExportSession(notebookID: notebookID)
            },
            validateExportSession: { [self] session in
                try validateExportSession(session)
            },
            endExportSession: { [self] session in
                await endExportSession(session)
            },
            descriptor: { [self] session, sessionID in
                try audioDescriptor(session: session, sessionID: sessionID)
            },
            loadAudioChunk: { [self] session, sessionID, offset, maximumByteCount in
                try loadAudioChunk(
                    session: session,
                    sessionID: sessionID,
                    offset: offset,
                    maximumByteCount: maximumByteCount
                )
            },
            loadTranscript: { [self] session, sessionID in
                try loadTranscript(session: session, sessionID: sessionID)
            }
        )
    }

    private func beginExportSession(notebookID: UUID) throws -> NotesAppNotebookExportSession {
        guard notebookID == notebook.id else {
            throw NotebookAudioExporterHarnessFailure.unexpectedRequest
        }
        beginCount += 1
        return NotesAppNotebookExportSession(
            token: NotebookExportSession(notebookID: NotebookID(notebook.id)),
            notebook: notebook
        )
    }

    private func validateExportSession(
        _ session: NotesAppNotebookExportSession
    ) throws -> EditorNotebook {
        guard session.notebook.id == notebook.id else {
            throw NotebookAudioExporterHarnessFailure.unexpectedRequest
        }
        validationCount += 1
        if let validationFailure {
            throw validationFailure
        }
        return notebook
    }

    private func endExportSession(_ session: NotesAppNotebookExportSession) async {
        guard session.notebook.id == notebook.id else { return }
        endCount += 1
        await endGate?.suspend()
    }

    private func audioDescriptor(
        session: NotesAppNotebookExportSession,
        sessionID: AudioSessionID
    ) throws -> AudioSessionDescriptor {
        guard session.notebook.id == notebook.id,
              sessionID == self.sessionID else {
            throw NotebookAudioExporterHarnessFailure.unexpectedRequest
        }
        descriptorRequestCount += 1
        return descriptor
    }

    private func loadAudioChunk(
        session: NotesAppNotebookExportSession,
        sessionID: AudioSessionID,
        offset: Int64,
        maximumByteCount: Int
    ) throws -> Data {
        guard session.notebook.id == notebook.id,
              sessionID == self.sessionID,
              offset >= 0,
              maximumByteCount > 0,
              offset <= Int64(Int.max) else {
            throw NotebookAudioExporterHarnessFailure.unexpectedRequest
        }
        chunkRequests.append((offset, maximumByteCount))
        let start = Int(offset)
        guard start < audioData.count else { return Data() }
        if case let .shortFirstRead(byteCount) = chunkMode {
            guard offset == 0 else { return Data() }
            return Data(audioData.prefix(max(0, min(byteCount, audioData.count))))
        }
        let end = min(audioData.count, start + maximumByteCount)
        return audioData.subdata(in: start ..< end)
    }

    private func loadTranscript(
        session: NotesAppNotebookExportSession,
        sessionID: AudioSessionID
    ) throws -> AudioTranscriptDocument? {
        guard session.notebook.id == notebook.id,
              sessionID == self.sessionID else {
            throw NotebookAudioExporterHarnessFailure.unexpectedRequest
        }
        return transcript
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private enum NotebookAudioExporterHarnessFailure: Error, Equatable, Sendable {
    case unexpectedRequest
    case finalValidation
}

private actor NotebookAudioExporterEndGate {
    private var entered = false
    private var released = false
    private var entryWaiters = [CheckedContinuation<Void, Never>]()
    private var releaseWaiters = [CheckedContinuation<Void, Never>]()

    func suspend() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
