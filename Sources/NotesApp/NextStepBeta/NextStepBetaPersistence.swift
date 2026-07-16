import CryptoKit
import Foundation
import NextStepDomain
import NotesServices

enum NextStepBetaStoreError: Error, LocalizedError, Equatable {
    case applicationSupportUnavailable
    case missingArchiveAfterWrite
    case unsupportedFileType
    case fileTooLarge
    case emptyFile
    case unsafeStoredPath
    case sourceIntegrityMismatch
    case malformedSyncArchive

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "無法開啟 Application Support。"
        case .missingArchiveAfterWrite:
            "資料寫入後無法重新讀取。"
        case .unsupportedFileType:
            "首版只支援 PDF、PNG、JPG、JPEG 與 HEIC。"
        case .fileTooLarge:
            "首版單一來源上限為 50 MB。"
        case .emptyFile:
            "選取的檔案是空的。"
        case .unsafeStoredPath:
            "來源檔案路徑不安全，已停止開啟。"
        case .sourceIntegrityMismatch:
            "同步來源的內容雜湊不一致，已拒絕寫入。"
        case .malformedSyncArchive:
            "同步資料無法通過 NextStep Beta 結構驗證。"
        }
    }
}

actor NextStepBetaStore {
    static let archiveFilename = "nextstep-beta-v1.json"

    nonisolated let rootURL: URL
    private let fileManager: FileManager

    init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
        self.fileManager = FileManager()
    }

    static func defaultRootURL() throws -> URL {
        let fileManager = FileManager()
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw NextStepBetaStoreError.applicationSupportUnavailable
        }
        return applicationSupport
            .appendingPathComponent("NextStep", isDirectory: true)
            .appendingPathComponent("Beta", isDirectory: true)
    }

    func load() throws -> NextStepBetaArchive? {
        let url = archiveURL
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return try decodeArchiveForSync(data)
    }

    func save(_ archive: NextStepBetaArchive) throws {
        try archive.validate()
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let data = try encodeArchiveForSync(archive)

        // Data.write(.atomic) creates a sibling temporary file and performs a
        // rename, so a crash cannot leave a half-written JSON snapshot.
        try data.write(to: archiveURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        guard fileManager.fileExists(atPath: archiveURL.path) else {
            throw NextStepBetaStoreError.missingArchiveAfterWrite
        }
    }

    func resolveStoredSource(relativePath: String) throws -> URL {
        try safeStoredSourceURL(relativePath: relativePath)
    }

    /// Produces the canonical structured payload used by the folder-sync adapter.
    /// Imported source bytes remain separate content-addressed blobs.
    func encodeArchiveForSync(_ archive: NextStepBetaArchive) throws -> Data {
        try archive.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(archive)
    }

    /// Decodes untrusted bytes downloaded from the selected folder and validates
    /// every domain relationship before the snapshot can replace local state.
    func decodeArchiveForSync(_ data: Data) throws -> NextStepBetaArchive {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let archive = try decoder.decode(NextStepBetaArchive.self, from: data)
            try archive.validate()
            return archive
        } catch let error as NextStepBetaArchiveError {
            throw error
        } catch {
            throw NextStepBetaStoreError.malformedSyncArchive
        }
    }

    func storedSourceData(relativePath: String) throws -> Data {
        let url = try safeStoredSourceURL(relativePath: relativePath)
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw NextStepBetaStoreError.unsafeStoredPath
        }
        if let size = values.fileSize, size > NextStepBetaSourceImporter.maximumBytes {
            throw NextStepBetaStoreError.fileTooLarge
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.isEmpty == false else { throw NextStepBetaStoreError.emptyFile }
        guard data.count <= NextStepBetaSourceImporter.maximumBytes else {
            throw NextStepBetaStoreError.fileTooLarge
        }
        return data
    }

    func verifyStoredSource(_ document: SourceDocument) throws {
        guard let relativePath = document.localRelativePath,
              let expectedSHA256 = document.contentSHA256 else {
            throw NextStepBetaStoreError.sourceIntegrityMismatch
        }
        let data = try storedSourceData(relativePath: relativePath)
        let actualSHA256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualSHA256 == expectedSHA256.lowercased() else {
            throw NextStepBetaStoreError.sourceIntegrityMismatch
        }
    }

    /// Installs a verified source downloaded as a content-addressed sync blob.
    /// The archive is committed only after every referenced source is present.
    func installSyncedSource(
        _ data: Data,
        relativePath: String,
        expectedSHA256: String
    ) throws {
        guard data.isEmpty == false else { throw NextStepBetaStoreError.emptyFile }
        guard data.count <= NextStepBetaSourceImporter.maximumBytes else {
            throw NextStepBetaStoreError.fileTooLarge
        }
        let actualSHA256 = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualSHA256 == expectedSHA256.lowercased() else {
            throw NextStepBetaStoreError.sourceIntegrityMismatch
        }

        let destination = try safeStoredSourceURL(relativePath: relativePath)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        if fileManager.fileExists(atPath: destination.path),
           let existing = try? Data(contentsOf: destination, options: [.mappedIfSafe]),
           SHA256.hash(data: existing).map({ String(format: "%02x", $0) }).joined()
            == actualSHA256 {
            return
        }
        try data.write(
            to: destination,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func safeStoredSourceURL(relativePath: String) throws -> URL {
        guard relativePath.contains("\\") == false,
              relativePath.hasPrefix("/") == false else {
            throw NextStepBetaStoreError.unsafeStoredPath
        }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        guard components.count == 3,
              components[0] == "Sources",
              UUID(uuidString: components[1]) != nil,
              components[2].hasPrefix("original."),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw NextStepBetaStoreError.unsafeStoredPath
        }
        let fileExtension = String(components[2].dropFirst("original.".count)).lowercased()
        guard ["pdf", "png", "jpg", "jpeg", "heic"].contains(fileExtension) else {
            throw NextStepBetaStoreError.unsafeStoredPath
        }
        let candidate = components.reduce(rootURL) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }.standardizedFileURL
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw NextStepBetaStoreError.unsafeStoredPath
        }
        var cursor = rootURL
        for component in components {
            cursor.appendPathComponent(component)
            guard fileManager.fileExists(atPath: cursor.path) else { continue }
            let values = try cursor.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw NextStepBetaStoreError.unsafeStoredPath
            }
        }
        return candidate
    }

    private var archiveURL: URL {
        rootURL.appendingPathComponent(Self.archiveFilename, isDirectory: false)
    }
}

enum NextStepBetaExtractionKind: String, Sendable {
    case selectablePDFText
    case visionOCR
    case none
}

actor NextStepBetaSourceImporter {
    static let maximumBytes = 50 * 1_024 * 1_024

    private let applicationSupportRoot: URL
    private let fileManager: FileManager
    private let pdfExtractor: PDFTextExtractor
    private let visionRecognizer: VisionTextRecognitionService

    init(applicationSupportRoot: URL) {
        self.applicationSupportRoot = applicationSupportRoot.standardizedFileURL
        self.fileManager = FileManager()
        self.pdfExtractor = PDFTextExtractor(
            limits: PDFTextExtractionLimits(
                maximumEncodedBytes: Self.maximumBytes,
                maximumPageCount: 2_000,
                maximumCharactersPerPage: 50_000,
                maximumTotalCharacters: 100_000,
                maximumRenderDimension: 2_048,
                maximumConcurrentOperations: 1
            )
        )
        self.visionRecognizer = VisionTextRecognitionService(
            limits: TextRecognitionLimits(
                maximumEncodedBytes: Self.maximumBytes,
                maximumPixels: 40_000_000,
                maximumLanguages: 2,
                maximumSegments: 1_000
            )
        )
    }

    func importSource(
        from pickedURL: URL,
        now: Date,
        deviceID: DeviceID
    ) async throws -> NextStepBetaImportedSource {
        let fileExtension = pickedURL.pathExtension.lowercased()
        guard Self.allowedExtensions.contains(fileExtension) else {
            throw NextStepBetaStoreError.unsupportedFileType
        }

        let didAccessSecurityScope = pickedURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope { pickedURL.stopAccessingSecurityScopedResource() }
        }

        let sourceID = SourceDocumentID()
        let copied = try copyIntoApplicationSupport(
            sourceURL: pickedURL,
            sourceID: sourceID,
            fileExtension: fileExtension
        )
        let data = try Data(contentsOf: copied.absoluteURL, options: [.mappedIfSafe])
        guard data.isEmpty == false else { throw NextStepBetaStoreError.emptyFile }
        guard data.count <= Self.maximumBytes else { throw NextStepBetaStoreError.fileTooLarge }

        let extraction = await extractFirstPage(
            data: data,
            fileExtension: fileExtension
        )
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let parserVersion: String?
        switch extraction.kind {
        case .selectablePDFText: parserVersion = "pdfkit-first-page-v1"
        case .visionOCR: parserVersion = "vision-ocr-first-page-v1"
        case .none: parserVersion = nil
        }
        let document = try NextStepBetaSourceRecordBuilder().makeDocument(
            id: sourceID,
            displayTitle: pickedURL.lastPathComponent,
            fileExtension: fileExtension,
            relativePath: copied.relativePath,
            contentSHA256: hash,
            now: now,
            deviceID: deviceID,
            parserVersion: parserVersion
        )
        return NextStepBetaImportedSource(
            document: document,
            exactExtract: extraction.text,
            pageIndex: 0,
            usedVisionOCR: extraction.kind == .visionOCR,
            extractionNotice: extraction.notice
        )
    }

    private func copyIntoApplicationSupport(
        sourceURL: URL,
        sourceID: SourceDocumentID,
        fileExtension: String
    ) throws -> (absoluteURL: URL, relativePath: String) {
        if let fileSize = try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > Self.maximumBytes {
            throw NextStepBetaStoreError.fileTooLarge
        }
        let folderName = sourceID.description
        let folderURL = applicationSupportRoot
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(
            at: folderURL,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Never reuse a user-controlled filename as a path component.
        let storedFilename = "original.\(fileExtension)"
        let destination = folderURL.appendingPathComponent(storedFilename)
        let temporary = folderURL.appendingPathComponent(".partial-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: sourceURL, to: temporary)
        let copiedSize = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard copiedSize > 0 else { throw NextStepBetaStoreError.emptyFile }
        guard copiedSize <= Self.maximumBytes else { throw NextStepBetaStoreError.fileTooLarge }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporary, to: destination)
        let relativePath = "Sources/\(folderName)/\(storedFilename)"
        return (destination, relativePath)
    }

    private func extractFirstPage(
        data: Data,
        fileExtension: String
    ) async -> (kind: NextStepBetaExtractionKind, text: String?, notice: String?) {
        if fileExtension == "pdf" {
            do {
                let segment = try await pdfExtractor.extract(data: data, pageIndex: 0)
                let text = Self.boundedExtract(segment.text)
                return (.selectablePDFText, text, nil)
            } catch PDFTextExtractionError.emptyDocument {
                do {
                    let rendered = try await pdfExtractor.renderPageImage(
                        data: data,
                        pageIndex: 0,
                        maximumDimension: 2_048
                    )
                    let segments = try await visionRecognizer.recognize(imageData: rendered)
                    let text = Self.boundedExtract(segments.map(\.text).joined(separator: "\n"))
                    return (.visionOCR, text, nil)
                } catch {
                    return (.none, nil, "PDF 已保存，但第一頁 OCR 沒有取得可用文字：\(error.localizedDescription)")
                }
            } catch {
                return (.none, nil, "PDF 已保存，但第一頁文字抽取失敗：\(error.localizedDescription)")
            }
        }

        do {
            let segments = try await visionRecognizer.recognize(imageData: data)
            let text = Self.boundedExtract(segments.map(\.text).joined(separator: "\n"))
            return (.visionOCR, text, nil)
        } catch {
            return (.none, nil, "圖片已保存，但 OCR 沒有取得可用文字：\(error.localizedDescription)")
        }
    }

    private static func boundedExtract(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        return String(trimmed.prefix(4_000))
    }

    private static let allowedExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg", "heic"]
}
