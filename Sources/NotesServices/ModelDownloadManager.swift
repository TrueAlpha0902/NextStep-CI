import CryptoKit
import Foundation

public enum ModelDownloadError: LocalizedError, Equatable, Sendable {
    case unsafePath(String)
    case invalidDescriptor(String)
    case unsupportedURL(String)
    case insufficientStorage(required: Int64, available: Int64)
    case invalidResponse
    case downloadTooLarge(path: String, maximum: Int64)
    case checksumMismatch(path: String)
    case installationInProgress(String)
    case modelNotInstalled

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path): "The model contains an unsafe path: \(path)"
        case .invalidDescriptor(let reason): "The model descriptor is invalid: \(reason)"
        case .unsupportedURL(let value): "The model artifact must use a secure HTTPS URL: \(value)"
        case .insufficientStorage(let required, let available):
            "The model needs \(required) bytes, but only \(available) bytes are available."
        case .invalidResponse: "The model server returned an invalid response."
        case .downloadTooLarge(let path, let maximum):
            "The downloaded artifact \(path) is larger than its \(maximum)-byte safety limit."
        case .checksumMismatch(let path): "Checksum verification failed for \(path)."
        case .installationInProgress(let id): "Model \(id) is already being installed."
        case .modelNotInstalled: "The selected model is not installed."
        }
    }
}

public struct ModelDownloadLimits: Hashable, Sendable {
    public var maximumArtifactCount: Int
    public var maximumArtifactBytes: Int64
    public var maximumModelBytes: Int64
    public var freeSpaceReserveBytes: Int64

    public init(
        maximumArtifactCount: Int = 256,
        maximumArtifactBytes: Int64 = 12 * 1_024 * 1_024 * 1_024,
        maximumModelBytes: Int64 = 16 * 1_024 * 1_024 * 1_024,
        freeSpaceReserveBytes: Int64 = 512 * 1_024 * 1_024
    ) {
        self.maximumArtifactCount = maximumArtifactCount
        self.maximumArtifactBytes = maximumArtifactBytes
        self.maximumModelBytes = maximumModelBytes
        self.freeSpaceReserveBytes = freeSpaceReserveBytes
    }
}

public struct InstalledModel: Identifiable, Codable, Hashable, Sendable {
    public var descriptor: ModelDescriptor
    public var directoryURL: URL
    public var installedAt: Date

    public var id: String { descriptor.id }

    public init(descriptor: ModelDescriptor, directoryURL: URL, installedAt: Date = .now) {
        self.descriptor = descriptor
        self.directoryURL = directoryURL
        self.installedAt = installedAt
    }
}

public protocol ModelManaging: Sendable {
    func install(_ descriptor: ModelDescriptor) async throws -> InstalledModel
    func installedModel(id: String) async throws -> InstalledModel?
    func installedModels() async throws -> [InstalledModel]
    func removeModel(id: String) async throws
}

public actor ModelDownloadManager: ModelManaging {
    private struct Manifest: Codable, Sendable {
        var schemaVersion = 1
        var descriptor: ModelDescriptor
        var installedAt: Date
    }

    private struct ValidatedDescriptor: Sendable {
        var maximumDownloadBytes: Int64
        var artifactLimits: [String: Int64]
    }

    private static let manifestName = "model.json"
    private static let maximumManifestBytes = 4 * 1_024 * 1_024

    private let rootDirectory: URL
    private let fileManager: FileManager
    private let session: URLSession
    private let limits: ModelDownloadLimits
    private var activeInstallations = Set<String>()

    public init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        session: URLSession = .shared,
        limits: ModelDownloadLimits = ModelDownloadLimits()
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.session = session
        self.limits = limits
    }

    public func install(_ descriptor: ModelDescriptor) async throws -> InstalledModel {
        try Task.checkCancellation()
        let validated = try validate(descriptor)
        guard activeInstallations.insert(descriptor.id).inserted else {
            throw ModelDownloadError.installationInProgress(descriptor.id)
        }
        defer { activeInstallations.remove(descriptor.id) }
        try ensureCapacity(requiredBytes: validated.maximumDownloadBytes)
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)

        let staging = rootDirectory.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            var downloadedBytes: Int64 = 0
            for artifact in descriptor.artifacts {
                try Task.checkCancellation()
                let destination = try safeURL(for: artifact.relativePath, under: staging)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw ModelDownloadError.invalidDescriptor("duplicate artifact path \(artifact.relativePath)")
                }

                let artifactLimit = validated.artifactLimits[artifact.relativePath] ?? limits.maximumArtifactBytes
                let remainingModelBytes = limits.maximumModelBytes - downloadedBytes
                guard remainingModelBytes > 0 else {
                    throw ModelDownloadError.downloadTooLarge(
                        path: artifact.relativePath,
                        maximum: limits.maximumModelBytes
                    )
                }
                let maximumBytes = min(artifactLimit, remainingModelBytes)
                let downloaded = try await download(
                    artifact,
                    to: destination,
                    maximumBytes: maximumBytes
                )
                downloadedBytes += downloaded
            }

            let final = try finalURL(for: descriptor.id)
            let installedAt = Date.now
            let manifest = Manifest(descriptor: descriptor, installedAt: installedAt)
            let manifestData = try Self.encoder.encode(manifest)
            guard manifestData.count <= Self.maximumManifestBytes else {
                throw ModelDownloadError.invalidDescriptor("manifest is too large")
            }
            try manifestData.write(
                to: staging.appendingPathComponent(Self.manifestName),
                options: [.atomic, .completeFileProtection]
            )

            try commit(staging: staging, replacing: final)
            return InstalledModel(descriptor: descriptor, directoryURL: final, installedAt: installedAt)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    public func installedModel(id: String) async throws -> InstalledModel? {
        let directory = try finalURL(for: id)
        guard fileManager.fileExists(atPath: directory.path) else { return nil }
        try rejectSymbolicLink(at: directory)
        let manifest = try readManifest(in: directory)
        guard manifest.descriptor.id == id else {
            throw ModelDownloadError.invalidDescriptor("manifest identifier does not match its directory")
        }
        _ = try validate(manifest.descriptor)
        try validateInstalledArtifacts(manifest.descriptor.artifacts, in: directory)
        return InstalledModel(
            descriptor: manifest.descriptor,
            directoryURL: directory,
            installedAt: manifest.installedAt
        )
    }

    public func installedModels() async throws -> [InstalledModel] {
        guard fileManager.fileExists(atPath: rootDirectory.path) else { return [] }
        let directories = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        var models: [InstalledModel] = []
        for directory in directories {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            guard let model = try? await installedModel(id: directory.lastPathComponent) else { continue }
            models.append(model)
        }
        return models.sorted { $0.installedAt > $1.installedAt }
    }

    public func removeModel(id: String) async throws {
        guard !activeInstallations.contains(id) else {
            throw ModelDownloadError.installationInProgress(id)
        }
        let modelURL = try finalURL(for: id)
        guard fileManager.fileExists(atPath: modelURL.path) else {
            throw ModelDownloadError.modelNotInstalled
        }
        try fileManager.removeItem(at: modelURL)
    }

    private func validate(_ descriptor: ModelDescriptor) throws -> ValidatedDescriptor {
        _ = try finalURL(for: descriptor.id)
        guard limits.maximumArtifactCount > 0,
              limits.maximumArtifactBytes > 0,
              limits.maximumModelBytes > 0,
              limits.freeSpaceReserveBytes >= 0 else {
            throw ModelDownloadError.invalidDescriptor("download limits are invalid")
        }
        try validateMetadata(descriptor.displayName, label: "display name", maximumBytes: 256)
        try validateMetadata(descriptor.version, label: "version", maximumBytes: 128)
        try validateMetadata(descriptor.licenseName, label: "license name", maximumBytes: 256)
        try validateHTTPSURL(descriptor.licenseURL)
        guard !descriptor.artifacts.isEmpty,
              descriptor.artifacts.count <= limits.maximumArtifactCount else {
            throw ModelDownloadError.invalidDescriptor("artifact count is outside the allowed range")
        }

        var declaredTotal: Int64 = 0
        var maximumDownloadTotal: Int64 = 0
        var canonicalPaths = Set<String>()
        var artifactLimits: [String: Int64] = [:]
        for artifact in descriptor.artifacts {
            try validateRelativePath(artifact.relativePath)
            let canonical = artifact.relativePath
                .precomposedStringWithCanonicalMapping
                .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard canonicalPaths.insert(canonical).inserted else {
                throw ModelDownloadError.invalidDescriptor("duplicate artifact path \(artifact.relativePath)")
            }
            guard artifact.approximateBytes > 0,
                  artifact.approximateBytes <= limits.maximumArtifactBytes else {
                throw ModelDownloadError.invalidDescriptor("invalid size for \(artifact.relativePath)")
            }
            let (nextTotal, overflow) = declaredTotal.addingReportingOverflow(artifact.approximateBytes)
            guard !overflow, nextTotal <= limits.maximumModelBytes else {
                throw ModelDownloadError.invalidDescriptor("model size exceeds the configured limit")
            }
            declaredTotal = nextTotal

            guard let checksum = artifact.sha256?.lowercased(),
                  checksum.count == 64,
                  checksum.utf8.allSatisfy({ byte in
                      (48...57).contains(byte) || (97...102).contains(byte)
                  }) else {
                throw ModelDownloadError.invalidDescriptor("\(artifact.relativePath) needs a 64-character SHA-256 checksum")
            }
            try validateHTTPSURL(artifact.remoteURL)
            let artifactLimit = try toleratedDownloadSize(for: artifact.approximateBytes)
            artifactLimits[artifact.relativePath] = artifactLimit
            let (maximumTotal, maximumOverflow) = maximumDownloadTotal.addingReportingOverflow(artifactLimit)
            maximumDownloadTotal = maximumOverflow
                ? limits.maximumModelBytes
                : min(maximumTotal, limits.maximumModelBytes)
        }
        return ValidatedDescriptor(
            maximumDownloadBytes: maximumDownloadTotal,
            artifactLimits: artifactLimits
        )
    }

    private func validateHTTPSURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              !Self.isLocalOrPrivateHost(host) else {
            throw ModelDownloadError.unsupportedURL(url.absoluteString)
        }
    }

    private func validateMetadata(
        _ value: String,
        label: String,
        maximumBytes: Int
    ) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ModelDownloadError.invalidDescriptor("\(label) is empty, unsafe, or too long")
        }
    }

    private static func isLocalOrPrivateHost(_ host: String) -> Bool {
        if host == "localhost"
            || host.hasSuffix(".localhost")
            || host.hasSuffix(".local")
            || host.hasSuffix(".internal") {
            return true
        }
        let ipv4 = host.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        if ipv4.count == 4 {
            switch (ipv4[0], ipv4[1]) {
            case (10, _), (127, _), (0, _): return true
            case (100, 64...127): return true
            case (169, 254): return true
            case (172, 16...31): return true
            case (192, 168), (192, 0): return true
            case (198, 18...19): return true
            case (224...255, _): return true
            default: break
            }
            if (ipv4[0], ipv4[1], ipv4[2]) == (192, 0, 2)
                || (ipv4[0], ipv4[1], ipv4[2]) == (198, 51, 100)
                || (ipv4[0], ipv4[1], ipv4[2]) == (203, 0, 113) {
                return true
            }
        }
        let ipv6 = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return ipv6 == "::1"
            || ipv6 == "::"
            || ipv6.hasPrefix("fe8")
            || ipv6.hasPrefix("fe9")
            || ipv6.hasPrefix("fea")
            || ipv6.hasPrefix("feb")
            || ipv6.hasPrefix("fc")
            || ipv6.hasPrefix("fd")
            || ipv6.hasPrefix("::ffff:")
            || ipv6.hasPrefix("2001:db8:")
    }

    private func validateRelativePath(_ relativePath: String) throws {
        guard !relativePath.isEmpty,
              relativePath.utf8.count <= 1_024,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ModelDownloadError.unsafePath(relativePath)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.count <= 32,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }),
              !(components.count == 1 && components[0].caseInsensitiveCompare(Self.manifestName) == .orderedSame) else {
            throw ModelDownloadError.unsafePath(relativePath)
        }
    }

    private func finalURL(for id: String) throws -> URL {
        guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil,
              id != ".",
              id != ".." else {
            throw ModelDownloadError.unsafePath(id)
        }
        return try childURL(named: id, under: rootDirectory, isDirectory: true)
    }

    private func safeURL(for relativePath: String, under base: URL) throws -> URL {
        try validateRelativePath(relativePath)
        let candidate = base.appendingPathComponent(relativePath).standardizedFileURL
        guard Self.isStrictDescendant(candidate, of: base) else {
            throw ModelDownloadError.unsafePath(relativePath)
        }
        return candidate
    }

    private func childURL(named name: String, under base: URL, isDirectory: Bool) throws -> URL {
        let candidate = base.appendingPathComponent(name, isDirectory: isDirectory).standardizedFileURL
        guard Self.isStrictDescendant(candidate, of: base) else {
            throw ModelDownloadError.unsafePath(name)
        }
        return candidate
    }

    private static func isStrictDescendant(_ candidate: URL, of base: URL) -> Bool {
        let baseComponents = base.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count > baseComponents.count
            && candidateComponents.prefix(baseComponents.count).elementsEqual(baseComponents)
    }

    private func toleratedDownloadSize(for declaredBytes: Int64) throws -> Int64 {
        let tolerance = max(64 * 1_024 * 1_024, declaredBytes / 10)
        let (sum, overflow) = declaredBytes.addingReportingOverflow(tolerance)
        return min(overflow ? Int64.max : sum, limits.maximumArtifactBytes)
    }

    private func download(
        _ artifact: ModelArtifact,
        to destination: URL,
        maximumBytes: Int64
    ) async throws -> Int64 {
        var request = URLRequest(url: artifact.remoteURL)
        request.timeoutInterval = 60 * 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let limiter = DownloadLimitDelegate(maximumBytes: maximumBytes)

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request, delegate: limiter)
        } catch {
            if limiter.didExceedLimit {
                throw ModelDownloadError.downloadTooLarge(path: artifact.relativePath, maximum: maximumBytes)
            }
            throw error
        }
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let responseURL = http.url else {
            throw ModelDownloadError.invalidResponse
        }
        try validateHTTPSURL(responseURL)
        if response.expectedContentLength > maximumBytes {
            throw ModelDownloadError.downloadTooLarge(path: artifact.relativePath, maximum: maximumBytes)
        }
        let size = try fileSize(of: temporaryURL)
        guard size > 0, size <= maximumBytes else {
            throw ModelDownloadError.downloadTooLarge(path: artifact.relativePath, maximum: maximumBytes)
        }
        let actual = try Self.sha256(of: temporaryURL)
        guard actual == artifact.sha256?.lowercased() else {
            throw ModelDownloadError.checksumMismatch(path: artifact.relativePath)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        return size
    }

    private func commit(staging: URL, replacing final: URL) throws {
        guard fileManager.fileExists(atPath: final.path) else {
            try fileManager.moveItem(at: staging, to: final)
            return
        }
        try rejectSymbolicLink(at: final)
        let backupName = ".rollback-\(UUID().uuidString)"
        let backup = rootDirectory.appendingPathComponent(backupName, isDirectory: true)
        do {
            _ = try fileManager.replaceItemAt(
                final,
                withItemAt: staging,
                backupItemName: backupName,
                options: [.usingNewMetadataOnly]
            )
            try? fileManager.removeItem(at: backup)
        } catch {
            if !fileManager.fileExists(atPath: final.path),
               fileManager.fileExists(atPath: backup.path) {
                try? fileManager.moveItem(at: backup, to: final)
            }
            throw error
        }
    }

    private func readManifest(in directory: URL) throws -> Manifest {
        let manifestURL = directory.appendingPathComponent(Self.manifestName)
        let size = try fileSize(of: manifestURL)
        guard size > 0, size <= Int64(Self.maximumManifestBytes) else {
            throw ModelDownloadError.invalidDescriptor("manifest is missing or too large")
        }
        let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        let manifest = try Self.decoder.decode(Manifest.self, from: data)
        guard manifest.schemaVersion == 1 else {
            throw ModelDownloadError.invalidDescriptor("unsupported manifest schema")
        }
        return manifest
    }

    private func validateInstalledArtifacts(_ artifacts: [ModelArtifact], in directory: URL) throws {
        for artifact in artifacts {
            let artifactURL = try safeURL(for: artifact.relativePath, under: directory)
            let values = try artifactURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw ModelDownloadError.invalidDescriptor("installed artifact is missing or unsafe: \(artifact.relativePath)")
            }
        }
    }

    private func rejectSymbolicLink(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw ModelDownloadError.unsafePath(url.lastPathComponent)
        }
    }

    private func fileSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize else {
            throw ModelDownloadError.invalidResponse
        }
        return Int64(size)
    }

    private func ensureCapacity(requiredBytes: Int64) throws {
        let (required, overflow) = requiredBytes.addingReportingOverflow(limits.freeSpaceReserveBytes)
        guard !overflow else {
            throw ModelDownloadError.invalidDescriptor("required storage overflows the supported range")
        }
        let probe = nearestExistingAncestor(of: rootDirectory)
        let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        if Int64(available) < required {
            throw ModelDownloadError.insufficientStorage(required: required, available: Int64(available))
        }
    }

    private func nearestExistingAncestor(of url: URL) -> URL {
        var candidate = url
        while !fileManager.fileExists(atPath: candidate.path),
              candidate.pathComponents.count > 1 {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 4 * 1_024 * 1_024),
                  !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private final class DownloadLimitDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int64
    private var exceeded = false

    var didExceedLimit: Bool {
        lock.notesWithLock { exceeded }
    }

    init(maximumBytes: Int64) {
        self.maximumBytes = maximumBytes
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten > maximumBytes
                || (totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite > maximumBytes) else { return }
        lock.notesWithLock { exceeded = true }
        downloadTask.cancel()
    }
}

private extension NSLock {
    func notesWithLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
