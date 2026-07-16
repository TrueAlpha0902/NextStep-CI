import Combine
import CryptoKit
import Darwin
import Foundation
import NotesServices

enum LocalModelPackageError: LocalizedError, Equatable, Sendable {
    case applicationSupportUnavailable
    case invalidPackage(String)
    case unsafePath(String)
    case packageTooLarge
    case artifactTooLarge(String)
    case checksumMismatch(String)
    case modelAlreadyInstalled(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            String(localized: "The local model folder is unavailable.")
        case .invalidPackage:
            String(localized: "The local model package is invalid.")
        case .unsafePath(let path):
            String(
                format: String(localized: "The local model contains an unsafe path: %@"),
                path
            )
        case .packageTooLarge:
            String(localized: "The local model exceeds the 16 GB safety limit.")
        case .artifactTooLarge(let path):
            String(
                format: String(localized: "The model file is larger than its declared safety limit: %@"),
                path
            )
        case .checksumMismatch(let path):
            String(
                format: String(localized: "SHA-256 verification failed for the model file: %@"),
                path
            )
        case .modelAlreadyInstalled(let id):
            String(
                format: String(localized: "A local model with this identifier is already installed: %@"),
                id
            )
        }
    }
}

protocol LocalModelLibraryManaging: Sendable {
    func importPackage(from sourceDirectory: URL) async throws -> InstalledModel
    func installedModels() async throws -> [InstalledModel]
    func removeModel(id: String) async throws
}

actor OnDeviceModelLibrary: LocalModelLibraryManaging {
    private struct OpenedRegularFile {
        let handle: FileHandle
        let size: Int64
    }

    private struct ArtifactPreflight {
        let totalBytes: Int64
        let sizesByPath: [String: Int64]
    }

    private enum RelativePathPurpose {
        case artifact
        case packageManifest
    }

    private struct PackageManifest: Codable, Sendable {
        var schemaVersion: Int
        var descriptor: ModelDescriptor
        var installedAt: Date?
    }

    private static let manifestName = "model.json"
    private static let maximumManifestBytes: Int64 = 4 * 1_024 * 1_024
    private static let copyBufferBytes = 4 * 1_024 * 1_024

    private let rootDirectory: URL
    private let fileManager: FileManager
    private let limits: ModelDownloadLimits
    private let manager: ModelDownloadManager

    init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        limits: ModelDownloadLimits = ModelDownloadLimits()
    ) {
        let root = rootDirectory.standardizedFileURL
        self.rootDirectory = root
        self.fileManager = fileManager
        self.limits = limits
        manager = ModelDownloadManager(
            rootDirectory: root,
            fileManager: FileManager(),
            limits: limits
        )
    }

    static func defaultRootDirectory(fileManager: FileManager = .default) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("Notes", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    func importPackage(from sourceDirectory: URL) async throws -> InstalledModel {
        try Task.checkCancellation()
        let didAccessSecurityScope = sourceDirectory.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                sourceDirectory.stopAccessingSecurityScopedResource()
            }
        }

        try prepareRootDirectory()
        let source = sourceDirectory.standardizedFileURL
        try validateSourceDirectory(source)
        let manifest = try readPackageManifest(from: source)
        try validateImportDescriptor(manifest.descriptor)
        try rejectExistingModelIdentifierCollision(manifest.descriptor.id)
        let final = try childURL(
            named: manifest.descriptor.id,
            under: rootDirectory,
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: final.path) else {
            throw LocalModelPackageError.modelAlreadyInstalled(manifest.descriptor.id)
        }

        let preflight = try preflightArtifacts(
            manifest.descriptor.artifacts,
            in: source
        )
        try ensureCapacity(requiredBytes: preflight.totalBytes)

        let validationRoot = try childURL(
            named: ".import-\(UUID().uuidString)",
            under: rootDirectory,
            isDirectory: true
        )
        let packageDirectory = try childURL(
            named: manifest.descriptor.id,
            under: validationRoot,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: packageDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        var committed = false
        defer {
            if !committed {
                try? fileManager.removeItem(at: validationRoot)
            }
        }

        var copiedBytes: Int64 = 0
        for artifact in manifest.descriptor.artifacts {
            try Task.checkCancellation()
            guard let preflightSize = preflight.sizesByPath[artifact.relativePath] else {
                throw LocalModelPackageError.invalidPackage("an artifact was not preflighted")
            }
            let maximumBytes = min(
                min(
                    try toleratedArtifactBytes(declaredBytes: artifact.approximateBytes),
                    limits.maximumModelBytes - copiedBytes
                ),
                preflightSize
            )
            guard maximumBytes > 0 else {
                throw LocalModelPackageError.packageTooLarge
            }
            let destinationURL = try safeURL(for: artifact.relativePath, under: packageDirectory)
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            copiedBytes += try copyAndVerify(
                sourceRoot: source,
                to: destinationURL,
                artifact: artifact,
                expectedBytes: preflightSize,
                maximumBytes: maximumBytes
            )
        }

        let installedAt = Date.now
        try writeManifest(
            PackageManifest(
                schemaVersion: 1,
                descriptor: manifest.descriptor,
                installedAt: installedAt
            ),
            to: packageDirectory
        )

        let validator = ModelDownloadManager(
            rootDirectory: validationRoot,
            fileManager: FileManager(),
            limits: limits
        )
        guard try await validator.installedModel(id: manifest.descriptor.id) != nil else {
            throw LocalModelPackageError.invalidPackage("the verified package could not be opened")
        }

        guard !fileManager.fileExists(atPath: final.path) else {
            throw LocalModelPackageError.modelAlreadyInstalled(manifest.descriptor.id)
        }
        try Task.checkCancellation()
        try fileManager.moveItem(at: packageDirectory, to: final)
        committed = true
        try? fileManager.removeItem(at: validationRoot)

        let installed: InstalledModel
        do {
            guard let reopened = try await manager.installedModel(id: manifest.descriptor.id) else {
                throw LocalModelPackageError.invalidPackage("the installed package could not be reopened")
            }
            installed = reopened
        } catch {
            try? fileManager.removeItem(at: final)
            throw error
        }
        return installed
    }

    func installedModels() async throws -> [InstalledModel] {
        try Task.checkCancellation()
        try prepareRootDirectory()
        let models = try await manager.installedModels()
        for model in models {
            try Task.checkCancellation()
            try verifyInstalledArtifacts(of: model)
        }
        return models
    }

    func removeModel(id: String) async throws {
        try Task.checkCancellation()
        try await manager.removeModel(id: id)
    }

    private func prepareRootDirectory() throws {
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        let values = try rootDirectory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LocalModelPackageError.unsafePath(rootDirectory.lastPathComponent)
        }
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: rootDirectory.path
        )
    }

    private func validateSourceDirectory(_ source: URL) throws {
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw LocalModelPackageError.invalidPackage("choose a regular folder containing model.json")
        }
        guard !Self.isSameOrDescendant(source, of: rootDirectory),
              !Self.isSameOrDescendant(rootDirectory, of: source) else {
            throw LocalModelPackageError.unsafePath(source.lastPathComponent)
        }
    }

    private func readPackageManifest(from source: URL) throws -> PackageManifest {
        let opened = try openRegularFile(
            relativePath: Self.manifestName,
            under: source,
            invalidReason: "model.json is missing or unsafe",
            purpose: .packageManifest
        )
        defer { try? opened.handle.close() }
        guard opened.size > 0,
              opened.size <= Self.maximumManifestBytes else {
            throw LocalModelPackageError.invalidPackage("model.json is missing or too large")
        }
        let data = try readBoundedData(
            from: opened,
            maximumBytes: Self.maximumManifestBytes,
            invalidReason: "model.json changed while it was being read"
        )
        let manifest: PackageManifest
        do {
            manifest = try Self.decoder.decode(PackageManifest.self, from: data)
        } catch {
            throw LocalModelPackageError.invalidPackage("model.json could not be decoded")
        }
        guard manifest.schemaVersion == 1 else {
            throw LocalModelPackageError.invalidPackage("model.json uses an unsupported schema")
        }
        return manifest
    }

    private func validateImportDescriptor(_ descriptor: ModelDescriptor) throws {
        let identifierBytes = descriptor.id.utf8
        guard !identifierBytes.isEmpty,
              identifierBytes.count <= 128,
              identifierBytes.first.map(Self.isASCIIAlphanumeric) == true,
              identifierBytes.allSatisfy(Self.isModelIdentifierByte) else {
            throw LocalModelPackageError.unsafePath(descriptor.id)
        }
        guard limits.maximumArtifactCount > 0,
              limits.maximumArtifactBytes > 0,
              limits.maximumModelBytes > 0,
              limits.freeSpaceReserveBytes >= 0,
              !descriptor.artifacts.isEmpty,
              descriptor.artifacts.count <= limits.maximumArtifactCount else {
            throw LocalModelPackageError.invalidPackage("the artifact count is outside the safety limit")
        }

        var canonicalPaths: [[String]] = []
        var declaredBytes: Int64 = 0
        for artifact in descriptor.artifacts {
            try validateRelativePath(artifact.relativePath)
            let canonical = artifact.relativePath
                .split(separator: "/")
                .map { Self.canonicalFilesystemName(String($0)) }
            guard !canonicalPaths.contains(where: {
                $0 == canonical || $0.starts(with: canonical) || canonical.starts(with: $0)
            }) else {
                throw LocalModelPackageError.invalidPackage(
                    "the manifest contains colliding artifact paths"
                )
            }
            canonicalPaths.append(canonical)
            guard artifact.approximateBytes > 0,
                  artifact.approximateBytes <= limits.maximumArtifactBytes else {
                throw LocalModelPackageError.artifactTooLarge(artifact.relativePath)
            }
            let (nextBytes, overflow) = declaredBytes.addingReportingOverflow(artifact.approximateBytes)
            guard !overflow, nextBytes <= limits.maximumModelBytes else {
                throw LocalModelPackageError.packageTooLarge
            }
            declaredBytes = nextBytes
            guard let checksum = artifact.sha256?.lowercased(),
                  checksum.count == 64,
                  checksum.utf8.allSatisfy({ byte in
                      (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
                  }) else {
                throw LocalModelPackageError.invalidPackage("every artifact needs a SHA-256 checksum")
            }
        }
    }

    private func preflightArtifacts(
        _ artifacts: [ModelArtifact],
        in source: URL
    ) throws -> ArtifactPreflight {
        var totalBytes: Int64 = 0
        var sizesByPath: [String: Int64] = [:]
        for artifact in artifacts {
            let opened = try openRegularFile(
                relativePath: artifact.relativePath,
                under: source,
                invalidReason: "a listed artifact is missing, linked, or is not a regular file"
            )
            let size = opened.size
            try? opened.handle.close()
            guard size > 0 else {
                throw LocalModelPackageError.invalidPackage("a listed artifact is empty")
            }
            guard size <= (try toleratedArtifactBytes(declaredBytes: artifact.approximateBytes)) else {
                throw LocalModelPackageError.artifactTooLarge(artifact.relativePath)
            }
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(size)
            guard !overflow, nextTotal <= limits.maximumModelBytes else {
                throw LocalModelPackageError.packageTooLarge
            }
            totalBytes = nextTotal
            sizesByPath[artifact.relativePath] = size
        }
        return ArtifactPreflight(totalBytes: totalBytes, sizesByPath: sizesByPath)
    }

    private func copyAndVerify(
        sourceRoot: URL,
        to destination: URL,
        artifact: ModelArtifact,
        expectedBytes: Int64,
        maximumBytes: Int64
    ) throws -> Int64 {
        let opened = try openRegularFile(
            relativePath: artifact.relativePath,
            under: sourceRoot,
            invalidReason: "a listed artifact is missing, linked, or is not a regular file"
        )
        guard opened.size == expectedBytes else {
            throw LocalModelPackageError.invalidPackage(
                "an artifact changed after its storage preflight"
            )
        }
        guard fileManager.createFile(
            atPath: destination.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.complete]
        ) else {
            throw LocalModelPackageError.invalidPackage("an artifact could not be staged")
        }
        let input = opened.handle
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }

        var hasher = SHA256()
        var byteCount: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: Self.copyBufferBytes),
                  !data.isEmpty else { break }
            let (nextCount, overflow) = byteCount.addingReportingOverflow(Int64(data.count))
            guard !overflow, nextCount <= maximumBytes else {
                throw LocalModelPackageError.artifactTooLarge(artifact.relativePath)
            }
            try output.write(contentsOf: data)
            hasher.update(data: data)
            byteCount = nextCount
        }
        guard byteCount > 0 else {
            throw LocalModelPackageError.invalidPackage("an artifact is empty")
        }
        guard byteCount == opened.size else {
            throw LocalModelPackageError.invalidPackage(
                "an artifact changed while it was being imported"
            )
        }
        try output.synchronize()
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == artifact.sha256?.lowercased() else {
            throw LocalModelPackageError.checksumMismatch(artifact.relativePath)
        }
        return byteCount
    }

    private func writeManifest(_ manifest: PackageManifest, to directory: URL) throws {
        let data = try Self.encoder.encode(manifest)
        guard data.count > 0, Int64(data.count) <= Self.maximumManifestBytes else {
            throw LocalModelPackageError.invalidPackage("the verified manifest is too large")
        }
        try data.write(
            to: directory.appendingPathComponent(Self.manifestName),
            options: [.atomic, .completeFileProtection]
        )
    }

    private func verifyInstalledArtifacts(of model: InstalledModel) throws {
        var totalBytes: Int64 = 0
        for artifact in model.descriptor.artifacts {
            try Task.checkCancellation()
            let opened = try openRegularFile(
                relativePath: artifact.relativePath,
                under: model.directoryURL,
                invalidReason: "an installed artifact is missing, linked, or unsafe"
            )
            let size = opened.size
            guard size > 0 else {
                throw LocalModelPackageError.invalidPackage("an installed artifact is missing or unsafe")
            }
            guard size <= (try toleratedArtifactBytes(declaredBytes: artifact.approximateBytes)) else {
                throw LocalModelPackageError.artifactTooLarge(artifact.relativePath)
            }
            let (nextTotal, overflow) = totalBytes.addingReportingOverflow(size)
            guard !overflow, nextTotal <= limits.maximumModelBytes else {
                throw LocalModelPackageError.packageTooLarge
            }
            totalBytes = nextTotal
            let digest = try sha256(
                of: opened,
                maximumBytes: try toleratedArtifactBytes(declaredBytes: artifact.approximateBytes)
            )
            guard digest == artifact.sha256?.lowercased() else {
                throw LocalModelPackageError.checksumMismatch(artifact.relativePath)
            }
        }
    }

    private func validateRelativePath(
        _ relativePath: String,
        purpose: RelativePathPurpose = .artifact
    ) throws {
        guard !relativePath.isEmpty,
              relativePath.utf8.count <= 1_024,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw LocalModelPackageError.unsafePath(relativePath)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.count <= 32,
              components.allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255
              }) else {
            throw LocalModelPackageError.unsafePath(relativePath)
        }
        switch purpose {
        case .artifact:
            guard !(components.count == 1
                && components[0].caseInsensitiveCompare(Self.manifestName) == .orderedSame) else {
                throw LocalModelPackageError.unsafePath(relativePath)
            }
        case .packageManifest:
            guard relativePath == Self.manifestName else {
                throw LocalModelPackageError.unsafePath(relativePath)
            }
        }
    }

    private func rejectExistingModelIdentifierCollision(_ id: String) throws {
        let requested = Self.canonicalFilesystemName(id)
        let existing = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        if existing.contains(where: {
            Self.canonicalFilesystemName($0.lastPathComponent) == requested
        }) {
            throw LocalModelPackageError.modelAlreadyInstalled(id)
        }
    }

    private func safeURL(for relativePath: String, under base: URL) throws -> URL {
        try validateRelativePath(relativePath)
        let candidate = base.appendingPathComponent(relativePath).standardizedFileURL
        guard Self.isStrictDescendant(candidate, of: base) else {
            throw LocalModelPackageError.unsafePath(relativePath)
        }
        return candidate
    }

    private func childURL(named name: String, under base: URL, isDirectory: Bool) throws -> URL {
        let candidate = base.appendingPathComponent(name, isDirectory: isDirectory).standardizedFileURL
        guard Self.isStrictDescendant(candidate, of: base) else {
            throw LocalModelPackageError.unsafePath(name)
        }
        return candidate
    }

    private func toleratedArtifactBytes(declaredBytes: Int64) throws -> Int64 {
        let tolerance = max(64 * 1_024 * 1_024, declaredBytes / 10)
        let (sum, overflow) = declaredBytes.addingReportingOverflow(tolerance)
        return min(overflow ? Int64.max : sum, limits.maximumArtifactBytes)
    }

    private func ensureCapacity(requiredBytes: Int64) throws {
        let (required, overflow) = requiredBytes.addingReportingOverflow(limits.freeSpaceReserveBytes)
        guard !overflow else { throw LocalModelPackageError.packageTooLarge }
        let probe = nearestExistingAncestor(of: rootDirectory)
        let values = try probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        guard Int64(available) >= required else {
            throw ModelDownloadError.insufficientStorage(
                required: required,
                available: Int64(available)
            )
        }
    }

    private func nearestExistingAncestor(of url: URL) -> URL {
        var candidate = url
        while !fileManager.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }

    private func sha256(
        of opened: OpenedRegularFile,
        maximumBytes: Int64
    ) throws -> String {
        defer { try? opened.handle.close() }
        var hasher = SHA256()
        var byteCount: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let data = try opened.handle.read(upToCount: Self.copyBufferBytes),
                  !data.isEmpty else { break }
            let (nextCount, overflow) = byteCount.addingReportingOverflow(Int64(data.count))
            guard !overflow, nextCount <= maximumBytes else {
                throw LocalModelPackageError.packageTooLarge
            }
            hasher.update(data: data)
            byteCount = nextCount
        }
        guard byteCount == opened.size else {
            throw LocalModelPackageError.invalidPackage(
                "an artifact changed while it was being verified"
            )
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func readBoundedData(
        from opened: OpenedRegularFile,
        maximumBytes: Int64,
        invalidReason: String
    ) throws -> Data {
        var result = Data()
        while true {
            try Task.checkCancellation()
            let remaining = maximumBytes - Int64(result.count)
            guard remaining >= 0 else {
                throw LocalModelPackageError.invalidPackage(invalidReason)
            }
            let requestBytes = Int(min(Int64(Self.copyBufferBytes), remaining + 1))
            guard let chunk = try opened.handle.read(upToCount: requestBytes),
                  !chunk.isEmpty else { break }
            result.append(chunk)
            guard Int64(result.count) <= maximumBytes else {
                throw LocalModelPackageError.invalidPackage(invalidReason)
            }
        }
        guard Int64(result.count) == opened.size else {
            throw LocalModelPackageError.invalidPackage(invalidReason)
        }
        return result
    }

    private func openRegularFile(
        relativePath: String,
        under base: URL,
        invalidReason: String,
        purpose: RelativePathPurpose = .artifact
    ) throws -> OpenedRegularFile {
        try validateRelativePath(relativePath, purpose: purpose)
        let components = relativePath.split(separator: "/").map(String.init)
        let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var directoryDescriptor = base.path.withCString {
            Darwin.open($0, directoryFlags)
        }
        guard directoryDescriptor >= 0 else {
            throw LocalModelPackageError.invalidPackage(invalidReason)
        }

        for component in components.dropLast() {
            let nextDescriptor = component.withCString {
                Darwin.openat(directoryDescriptor, $0, directoryFlags)
            }
            guard nextDescriptor >= 0 else {
                _ = Darwin.close(directoryDescriptor)
                throw LocalModelPackageError.invalidPackage(invalidReason)
            }
            _ = Darwin.close(directoryDescriptor)
            directoryDescriptor = nextDescriptor
        }

        guard let filename = components.last else {
            _ = Darwin.close(directoryDescriptor)
            throw LocalModelPackageError.invalidPackage(invalidReason)
        }
        let fileDescriptor = filename.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
            )
        }
        _ = Darwin.close(directoryDescriptor)
        guard fileDescriptor >= 0 else {
            throw LocalModelPackageError.invalidPackage(invalidReason)
        }

        var status = stat()
        guard Darwin.fstat(fileDescriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size >= 0 else {
            _ = Darwin.close(fileDescriptor)
            throw LocalModelPackageError.invalidPackage(invalidReason)
        }
        return OpenedRegularFile(
            handle: FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true),
            size: Int64(status.st_size)
        )
    }

    private static func isStrictDescendant(_ candidate: URL, of base: URL) -> Bool {
        let baseComponents = canonicalFilesystemComponents(of: base)
        let candidateComponents = canonicalFilesystemComponents(of: candidate)
        return candidateComponents.count > baseComponents.count
            && candidateComponents.prefix(baseComponents.count).elementsEqual(baseComponents)
    }

    private static func isSameOrDescendant(_ candidate: URL, of base: URL) -> Bool {
        let baseComponents = canonicalFilesystemComponents(of: base)
        let candidateComponents = canonicalFilesystemComponents(of: candidate)
        return candidateComponents.count >= baseComponents.count
            && candidateComponents.prefix(baseComponents.count).elementsEqual(baseComponents)
    }

    private static func canonicalFilesystemComponents(of url: URL) -> [String] {
        url.resolvingSymlinksInPath().standardizedFileURL.pathComponents.map(canonicalFilesystemName)
    }

    private static func canonicalFilesystemName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (48 ... 57).contains(byte)
            || (65 ... 90).contains(byte)
            || (97 ... 122).contains(byte)
    }

    private static func isModelIdentifierByte(_ byte: UInt8) -> Bool {
        isASCIIAlphanumeric(byte) || byte == 45 || byte == 46 || byte == 95
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

@MainActor
final class LocalModelLibrary: ObservableObject {
    enum Operation: Equatable {
        case idle
        case refreshing
        case importing
        case removing(String)
    }

    @Published private(set) var models: [InstalledModel] = []
    @Published private(set) var operation = Operation.idle
    @Published private(set) var lastVerifiedAt: Date?
    @Published var failureMessage: String?

    private let store: any LocalModelLibraryManaging

    init(store: (any LocalModelLibraryManaging)? = nil) {
        if let store {
            self.store = store
        } else {
            do {
                self.store = OnDeviceModelLibrary(
                    rootDirectory: try OnDeviceModelLibrary.defaultRootDirectory()
                )
            } catch {
                self.store = UnavailableLocalModelLibrary()
            }
        }
    }

    var isWorking: Bool { operation != .idle }

    func refresh() async {
        await perform(.refreshing) {
            try await self.store.installedModels()
        }
    }

    func importPackage(from directory: URL) async {
        await perform(.importing) {
            _ = try await self.store.importPackage(from: directory)
            return try await self.store.installedModels()
        }
    }

    func removeModel(id: String) async {
        await perform(.removing(id)) {
            try await self.store.removeModel(id: id)
            return try await self.store.installedModels()
        }
    }

    func clearFailure() {
        failureMessage = nil
    }

    private func perform(
        _ requestedOperation: Operation,
        work: () async throws -> [InstalledModel]
    ) async {
        guard operation == .idle else { return }
        operation = requestedOperation
        defer { operation = .idle }
        do {
            let installed = try await work()
            try Task.checkCancellation()
            models = installed
            lastVerifiedAt = .now
            failureMessage = nil
        } catch is CancellationError {
            // A view disappearing is expected to cancel long file verification.
        } catch {
            failureMessage = error.localizedDescription
        }
    }
}

private actor UnavailableLocalModelLibrary: LocalModelLibraryManaging {
    func importPackage(from sourceDirectory: URL) async throws -> InstalledModel {
        throw LocalModelPackageError.applicationSupportUnavailable
    }

    func installedModels() async throws -> [InstalledModel] {
        throw LocalModelPackageError.applicationSupportUnavailable
    }

    func removeModel(id: String) async throws {
        throw LocalModelPackageError.applicationSupportUnavailable
    }
}
