import Foundation

public struct BackupSnapshot: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var folderName: String
    public var notebookNames: [String]

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        folderName: String,
        notebookNames: [String]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.folderName = folderName
        self.notebookNames = notebookNames
    }
}

public struct BackupDestination: Codable, Hashable, Sendable {
    public var bookmarkData: Data

    public init(url: URL) throws {
        bookmarkData = try url.bookmarkData(
            options: [.minimalBookmark],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    public init(bookmarkData: Data) {
        self.bookmarkData = bookmarkData
    }

    public func resolve() throws -> URL {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale else { throw FileBackupError.staleBookmark }
        return url.standardizedFileURL
    }
}

public enum FileBackupError: LocalizedError, Equatable, Sendable {
    case noNotebooks
    case invalidSnapshot
    case staleBookmark
    case unsafeItem(String)
    case backupTooLarge
    case destinationConflict(String)
    case restoreIncomplete

    public var errorDescription: String? {
        switch self {
        case .noNotebooks: "There are no notebook packages to back up."
        case .invalidSnapshot: "The selected backup is invalid."
        case .staleBookmark: "The backup folder permission has expired. Please choose it again."
        case .unsafeItem(let name): "The backup contains an unsafe item: \(name)"
        case .backupTooLarge: "The backup exceeds the configured safety limits."
        case .destinationConflict(let name):
            "A notebook with the same identity already exists in the library: \(name)"
        case .restoreIncomplete: "The restore could not be completed and was rolled back."
        }
    }
}

public struct FileBackupLimits: Hashable, Sendable {
    public var maximumNotebookCount: Int
    public var maximumItemCount: Int
    public var maximumTotalBytes: Int64
    public var freeSpaceReserveBytes: Int64

    public init(
        maximumNotebookCount: Int = 10_000,
        maximumItemCount: Int = 1_000_000,
        maximumTotalBytes: Int64 = 1_024 * 1_024 * 1_024 * 1_024,
        freeSpaceReserveBytes: Int64 = 256 * 1_024 * 1_024
    ) {
        self.maximumNotebookCount = maximumNotebookCount
        self.maximumItemCount = maximumItemCount
        self.maximumTotalBytes = maximumTotalBytes
        self.freeSpaceReserveBytes = freeSpaceReserveBytes
    }
}

public actor FileBackupService {
    private struct Manifest: Codable, Sendable {
        var schemaVersion = 1
        var snapshot: BackupSnapshot
    }

    private struct TreeMetrics: Sendable {
        var itemCount = 0
        var totalBytes: Int64 = 0

        mutating func addFile(bytes: Int64, limits: FileBackupLimits) throws {
            itemCount += 1
            guard itemCount <= limits.maximumItemCount, bytes >= 0 else {
                throw FileBackupError.backupTooLarge
            }
            let (sum, overflow) = totalBytes.addingReportingOverflow(bytes)
            guard !overflow, sum <= limits.maximumTotalBytes else {
                throw FileBackupError.backupTooLarge
            }
            totalBytes = sum
        }
    }

    private static let manifestName = "backup.json"
    private static let maximumManifestBytes = 4 * 1_024 * 1_024

    private let fileManager: FileManager
    private let limits: FileBackupLimits

    public init(
        fileManager: FileManager = .default,
        limits: FileBackupLimits = FileBackupLimits()
    ) {
        self.fileManager = fileManager
        self.limits = limits
    }

    public func createSnapshot(
        notebookURLs: [URL],
        at destination: BackupDestination,
        keepLatest: Int = 10
    ) throws -> BackupSnapshot {
        guard !notebookURLs.isEmpty else { throw FileBackupError.noNotebooks }
        try validateLimits()
        guard notebookURLs.count <= limits.maximumNotebookCount else {
            throw FileBackupError.backupTooLarge
        }

        let destinationURL = try destination.resolve()
        let didAccess = destinationURL.startAccessingSecurityScopedResource()
        defer { if didAccess { destinationURL.stopAccessingSecurityScopedResource() } }
        try prepareDirectory(destinationURL)

        var metrics = TreeMetrics()
        var canonicalNames = Set<String>()
        for source in notebookURLs {
            let name = try validateNotebookPackage(source, metrics: &metrics)
            guard canonicalNames.insert(Self.canonicalName(name)).inserted else {
                throw FileBackupError.unsafeItem(name)
            }
            guard !Self.isSameOrDescendant(destinationURL, of: source) else {
                throw FileBackupError.unsafeItem(name)
            }
        }
        try ensureCapacity(requiredBytes: metrics.totalBytes, at: destinationURL)

        let id = UUID()
        let folderName = "NextStep Backup \(Self.timestampString(for: .now))-\(id.uuidString.prefix(8))"
        let staging = try safeChild(named: ".\(folderName)", in: destinationURL, isDirectory: true)
        let final = try safeChild(named: folderName, in: destinationURL, isDirectory: true)
        guard !fileManager.fileExists(atPath: staging.path),
              !fileManager.fileExists(atPath: final.path) else {
            throw FileBackupError.invalidSnapshot
        }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)

        do {
            let names = notebookURLs.map(\.lastPathComponent).sorted()
            for source in notebookURLs {
                try fileManager.copyItem(
                    at: source,
                    to: try safeChild(named: source.lastPathComponent, in: staging, isDirectory: true)
                )
            }
            // Validate the copied tree, not only its source, to close symlink and mutation races.
            var copiedMetrics = TreeMetrics()
            for name in names {
                _ = try validateNotebookPackage(
                    try safeChild(named: name, in: staging, isDirectory: true),
                    metrics: &copiedMetrics
                )
            }

            let snapshot = BackupSnapshot(
                id: id,
                createdAt: .now,
                folderName: folderName,
                notebookNames: names
            )
            let data = try Self.encoder.encode(Manifest(snapshot: snapshot))
            guard data.count <= Self.maximumManifestBytes else { throw FileBackupError.backupTooLarge }
            try data.write(
                to: staging.appendingPathComponent(Self.manifestName),
                options: [.atomic, .completeFileProtection]
            )
            try fileManager.moveItem(at: staging, to: final)
            // Retention failure must not make a successfully committed snapshot look unsuccessful.
            try? prune(destinationURL: destinationURL, keeping: max(1, keepLatest))
            return snapshot
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    public func snapshots(at destination: BackupDestination) throws -> [BackupSnapshot] {
        let destinationURL = try destination.resolve()
        let didAccess = destinationURL.startAccessingSecurityScopedResource()
        defer { if didAccess { destinationURL.stopAccessingSecurityScopedResource() } }
        guard fileManager.fileExists(atPath: destinationURL.path) else { return [] }
        try rejectSymbolicLink(at: destinationURL)
        return try snapshotsInResolvedDirectory(destinationURL)
    }

    public func restore(
        _ snapshot: BackupSnapshot,
        from destination: BackupDestination,
        into libraryDirectory: URL
    ) throws -> [URL] {
        try validateLimits()
        let destinationURL = try destination.resolve()
        let didAccess = destinationURL.startAccessingSecurityScopedResource()
        defer { if didAccess { destinationURL.stopAccessingSecurityScopedResource() } }

        let snapshotURL = try safeChild(named: snapshot.folderName, in: destinationURL, isDirectory: true)
        try rejectSymbolicLink(at: snapshotURL)
        let authoritative = try readManifest(in: snapshotURL)
        guard authoritative.id == snapshot.id,
              authoritative.folderName == snapshot.folderName else {
            throw FileBackupError.invalidSnapshot
        }
        try validateSnapshot(authoritative, folderURL: snapshotURL)
        guard !Self.isSameOrDescendant(libraryDirectory, of: snapshotURL) else {
            throw FileBackupError.unsafeItem(libraryDirectory.lastPathComponent)
        }
        try prepareDirectory(libraryDirectory)

        let staging = try safeChild(
            named: ".restore-\(UUID().uuidString)",
            in: libraryDirectory,
            isDirectory: true
        )
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        var committed: [URL] = []
        do {
            var metrics = TreeMetrics()
            for name in authoritative.notebookNames {
                let source = try safeChild(named: name, in: snapshotURL, isDirectory: true)
                _ = try validateNotebookPackage(source, metrics: &metrics)
            }
            try ensureCapacity(requiredBytes: metrics.totalBytes, at: libraryDirectory)
            for name in authoritative.notebookNames {
                let source = try safeChild(named: name, in: snapshotURL, isDirectory: true)
                try fileManager.copyItem(
                    at: source,
                    to: try safeChild(named: name, in: staging, isDirectory: true)
                )
            }

            let occupiedNames = try Set(
                fileManager.contentsOfDirectory(
                    at: libraryDirectory,
                    includingPropertiesForKeys: nil,
                    options: []
                ).map { Self.canonicalName($0.lastPathComponent) }
            )
            let destinations = try authoritative.notebookNames.map { name in
                guard !occupiedNames.contains(Self.canonicalName(name)) else {
                    throw FileBackupError.destinationConflict(name)
                }
                return try safeChild(named: name, in: libraryDirectory, isDirectory: true)
            }
            for (name, target) in zip(authoritative.notebookNames, destinations) {
                let staged = try safeChild(named: name, in: staging, isDirectory: true)
                var copiedMetrics = TreeMetrics()
                _ = try validateNotebookPackage(staged, metrics: &copiedMetrics)
                try fileManager.moveItem(at: staged, to: target)
                committed.append(target)
            }
            try fileManager.removeItem(at: staging)
            return committed
        } catch {
            var rollbackSucceeded = true
            for url in committed.reversed() {
                do { try fileManager.removeItem(at: url) } catch { rollbackSucceeded = false }
            }
            try? fileManager.removeItem(at: staging)
            if !rollbackSucceeded { throw FileBackupError.restoreIncomplete }
            throw error
        }
    }

    private func validateLimits() throws {
        guard limits.maximumNotebookCount > 0,
              limits.maximumItemCount > 0,
              limits.maximumTotalBytes > 0,
              limits.freeSpaceReserveBytes >= 0 else {
            throw FileBackupError.backupTooLarge
        }
    }

    private func prepareDirectory(_ directory: URL) throws {
        guard directory.isFileURL else { throw FileBackupError.unsafeItem(directory.absoluteString) }
        if fileManager.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw FileBackupError.unsafeItem(directory.lastPathComponent)
            }
        } else {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func validateNotebookPackage(_ url: URL, metrics: inout TreeMetrics) throws -> String {
        guard url.isFileURL else { throw FileBackupError.unsafeItem(url.absoluteString) }
        let name = url.lastPathComponent
        guard url.pathExtension.caseInsensitiveCompare("notepkg") == .orderedSame else {
            throw FileBackupError.unsafeItem(name)
        }
        guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else {
            throw FileBackupError.unsafeItem(name)
        }
        _ = try safeName(name)
        let rootValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw FileBackupError.unsafeItem(name)
        }

        let enumerationError = BackupEnumerationErrorBox()
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [],
            errorHandler: { _, error in
                enumerationError.record(error)
                return false
            }
        ) else {
            throw FileBackupError.unsafeItem(name)
        }
        while let item = enumerator.nextObject() as? URL {
            let values = try item.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard values.isSymbolicLink != true else {
                throw FileBackupError.unsafeItem(item.lastPathComponent)
            }
            if values.isDirectory == true {
                try metrics.addFile(bytes: 0, limits: limits)
            } else if values.isRegularFile == true {
                try metrics.addFile(bytes: Int64(values.fileSize ?? 0), limits: limits)
            } else {
                throw FileBackupError.unsafeItem(item.lastPathComponent)
            }
        }
        if let error = enumerationError.value { throw error }
        return name
    }

    private func validateSnapshot(_ snapshot: BackupSnapshot, folderURL: URL) throws {
        guard !snapshot.notebookNames.isEmpty,
              snapshot.notebookNames.count <= limits.maximumNotebookCount else {
            throw FileBackupError.invalidSnapshot
        }
        var names = Set<String>()
        for name in snapshot.notebookNames {
            _ = try safeName(name)
            let nameURL = URL(fileURLWithPath: name)
            guard nameURL.pathExtension.caseInsensitiveCompare("notepkg") == .orderedSame,
                  UUID(uuidString: nameURL.deletingPathExtension().lastPathComponent) != nil,
                  names.insert(Self.canonicalName(name)).inserted else {
                throw FileBackupError.invalidSnapshot
            }
            let package = try safeChild(named: name, in: folderURL, isDirectory: true)
            guard fileManager.fileExists(atPath: package.path) else { throw FileBackupError.invalidSnapshot }
        }
    }

    private func prune(destinationURL: URL, keeping count: Int) throws {
        let snapshots = try snapshotsInResolvedDirectory(destinationURL)
        for old in snapshots.dropFirst(count) {
            let folder = try safeChild(named: old.folderName, in: destinationURL, isDirectory: true)
            try rejectSymbolicLink(at: folder)
            try fileManager.removeItem(at: folder)
        }
    }

    private func snapshotsInResolvedDirectory(_ destinationURL: URL) throws -> [BackupSnapshot] {
        let contents = try fileManager.contentsOfDirectory(
            at: destinationURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var snapshots: [BackupSnapshot] = []
        for folder in contents {
            guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let snapshot = try? readManifest(in: folder),
                  snapshot.folderName == folder.lastPathComponent,
                  (try? validateSnapshot(snapshot, folderURL: folder)) != nil else { continue }
            snapshots.append(snapshot)
        }
        return snapshots.sorted { $0.createdAt > $1.createdAt }
    }

    private func readManifest(in folder: URL) throws -> BackupSnapshot {
        let manifestURL = try safeChild(named: Self.manifestName, in: folder, isDirectory: false)
        let values = try manifestURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= Self.maximumManifestBytes else {
            throw FileBackupError.invalidSnapshot
        }
        let data = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        let manifest = try Self.decoder.decode(Manifest.self, from: data)
        guard manifest.schemaVersion == 1 else { throw FileBackupError.invalidSnapshot }
        return manifest.snapshot
    }

    private func safeName(_ name: String) throws -> String {
        guard !name.isEmpty,
              name.utf8.count <= 255,
              name != ".",
              name != "..",
              name == URL(fileURLWithPath: name).lastPathComponent,
              !name.contains("/"),
              !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FileBackupError.unsafeItem(name)
        }
        return name
    }

    private func safeChild(named name: String, in directory: URL, isDirectory: Bool) throws -> URL {
        _ = try safeName(name)
        let child = directory.appendingPathComponent(name, isDirectory: isDirectory).standardizedFileURL
        guard Self.isDescendant(child, of: directory) else { throw FileBackupError.unsafeItem(name) }
        return child
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentComponents = parent.standardizedFileURL.pathComponents
        let childComponents = child.standardizedFileURL.pathComponents
        return childComponents.count > parentComponents.count
            && childComponents.prefix(parentComponents.count).elementsEqual(parentComponents)
    }

    private static func isSameOrDescendant(_ child: URL, of parent: URL) -> Bool {
        let parentComponents = parent.standardizedFileURL.pathComponents
        let childComponents = child.standardizedFileURL.pathComponents
        return childComponents.count >= parentComponents.count
            && childComponents.prefix(parentComponents.count).elementsEqual(parentComponents)
    }

    private static func canonicalName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func rejectSymbolicLink(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw FileBackupError.unsafeItem(url.lastPathComponent) }
    }

    private func ensureCapacity(requiredBytes: Int64, at directory: URL) throws {
        let (required, overflow) = requiredBytes.addingReportingOverflow(limits.freeSpaceReserveBytes)
        guard !overflow else { throw FileBackupError.backupTooLarge }
        let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return }
        guard Int64(available) >= required else { throw FileBackupError.backupTooLarge }
    }

    private static func timestampString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private final class BackupEnumerationErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?

    var value: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func record(_ error: Error) {
        lock.lock()
        if storedError == nil { storedError = error }
        lock.unlock()
    }
}
