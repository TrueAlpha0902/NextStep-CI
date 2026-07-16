import Darwin
import Foundation

public struct SyncRelativePath: Hashable, Sendable, Codable, CustomStringConvertible {
    public let components: [String]

    public init(components: [String]) throws {
        guard !components.isEmpty, components.count <= 32 else {
            throw NextStepSyncError.invalidRelativePath(components.joined(separator: "/"))
        }
        for component in components {
            try Self.validate(component)
        }
        self.components = components
    }

    public init(component: String) throws {
        try self.init(components: [component])
    }

    public init(_ rawValue: String) throws {
        guard !rawValue.hasPrefix("/"),
              !rawValue.hasPrefix("\\"),
              !rawValue.contains("\\") else {
            throw NextStepSyncError.invalidRelativePath(rawValue)
        }
        let pieces = rawValue.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        try self.init(components: pieces)
    }

    public var description: String { components.joined(separator: "/") }

    public func appending(_ component: String) throws -> Self {
        try Self(components: components + [component])
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    private static func validate(_ component: String) throws {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              component.utf8.count <= 255,
              !component.contains("/"),
              !component.contains("\\"),
              !component.unicodeScalars.contains(where: { $0.value == 0 }),
              !component.hasPrefix("~") else {
            throw NextStepSyncError.invalidRelativePath(component)
        }
    }
}

public struct SyncTransportEntry: Hashable, Sendable {
    public let name: String
    public let isDirectory: Bool
    public let byteCount: Int64?

    public init(name: String, isDirectory: Bool, byteCount: Int64?) {
        self.name = name
        self.isDirectory = isDirectory
        self.byteCount = byteCount
    }
}

/// A path/key based transport that can later be implemented by CloudKit without
/// changing the sync operation or conflict model.
public protocol SyncTransport: Sendable {
    func isAvailable() async -> Bool
    func list(_ path: SyncRelativePath) async throws -> [SyncTransportEntry]
    func read(_ path: SyncRelativePath, maximumBytes: Int) async throws -> Data
    func writeImmutable(_ data: Data, to path: SyncRelativePath) async throws
    func replaceAtomically(_ data: Data, at path: SyncRelativePath) async throws
}

/// Persist this value in Application Support or the Keychain after a user picks a
/// folder with UIDocumentPickerViewController. The bookmark restores access after
/// an app relaunch; callers must replace it whenever `resolve()` reports stale.
public struct SecurityScopedSyncFolderBookmark: Hashable, Sendable, Codable {
    public let data: Data

    public init(folderURL: URL) throws {
        self.data = try folderURL.bookmarkData(
            options: [.minimalBookmark],
            includingResourceValuesForKeys: [.isDirectoryKey],
            relativeTo: nil
        )
    }

    public init(data: Data) {
        self.data = data
    }

    public func resolve() throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: [.withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        return (url.standardizedFileURL, stale)
    }
}

/// A transport rooted in a user-selected Files/iCloud Drive folder. It does not
/// require CloudKit entitlements or a paid backend. Every operation is serialized
/// by the actor; each access balances the security-scoped resource lifetime.
public actor FileFolderSyncTransport: SyncTransport {
    public nonisolated let rootURL: URL
    private let requiresSecurityScopedAccess: Bool

    public init(
        rootURL: URL,
        requiresSecurityScopedAccess: Bool = true,
        createIfMissing: Bool = false
    ) throws {
        let standardizedRoot = rootURL.standardizedFileURL
        self.rootURL = standardizedRoot
        self.requiresSecurityScopedAccess = requiresSecurityScopedAccess

        let didStartAccess = requiresSecurityScopedAccess
            && standardizedRoot.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                standardizedRoot.stopAccessingSecurityScopedResource()
            }
        }
        try SecureSyncFolder.prepareRoot(standardizedRoot, createIfMissing: createIfMissing)
    }

    public func isAvailable() async -> Bool {
        do {
            return try withAccess {
                try SecureSyncFolder.prepareRoot(rootURL, createIfMissing: false)
                return true
            }
        } catch {
            return false
        }
    }

    public func list(_ path: SyncRelativePath) async throws -> [SyncTransportEntry] {
        try withAccess {
            do {
                return try SecureSyncFolder.list(rootURL: rootURL, path: path)
            } catch NextStepSyncError.notFound(_) {
                return []
            }
        }
    }

    public func read(_ path: SyncRelativePath, maximumBytes: Int) async throws -> Data {
        try withAccess {
            guard let data = try SecureSyncFolder.readIfPresent(
                rootURL: rootURL,
                path: path,
                maximumBytes: maximumBytes
            ) else {
                throw NextStepSyncError.notFound(path.description)
            }
            return data
        }
    }

    public func writeImmutable(_ data: Data, to path: SyncRelativePath) async throws {
        try withAccess {
            try SecureSyncFolder.writeImmutable(rootURL: rootURL, path: path, data: data)
        }
    }

    public func replaceAtomically(_ data: Data, at path: SyncRelativePath) async throws {
        try withAccess {
            try SecureSyncFolder.replaceAtomically(rootURL: rootURL, path: path, data: data)
        }
    }

    private func withAccess<T>(_ body: () throws -> T) throws -> T {
        // `false` can also mean the caller already holds the scope. Let the
        // descriptor operation determine actual availability in that case.
        let didStartAccess = requiresSecurityScopedAccess
            && rootURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                rootURL.stopAccessingSecurityScopedResource()
            }
        }
        do {
            return try body()
        } catch let error as NextStepSyncError {
            throw error
        } catch {
            throw NextStepSyncError.ioFailure(String(describing: error))
        }
    }
}

enum SecureSyncFolder {
    static func prepareRoot(_ rootURL: URL, createIfMissing: Bool) throws {
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) {
            guard createIfMissing else { throw NextStepSyncError.transportUnavailable }
            do {
                try FileManager.default.createDirectory(
                    at: rootURL,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw NextStepSyncError.transportUnavailable
            }
        } else if !isDirectory.boolValue {
            throw NextStepSyncError.nonRegularFile(rootURL.path)
        }

        let descriptor = rootURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else {
            if errno == ELOOP { throw NextStepSyncError.symlinkRejected(rootURL.path) }
            throw NextStepSyncError.transportUnavailable
        }
        _ = Darwin.close(descriptor)
    }

    static func readIfPresent(
        rootURL: URL,
        path: SyncRelativePath,
        maximumBytes: Int
    ) throws -> Data? {
        guard maximumBytes >= 0, maximumBytes < Int.max else {
            throw NextStepSyncError.sizeLimitExceeded(limit: max(0, maximumBytes))
        }
        let parentAndName: (descriptor: Int32, finalName: String)
        do {
            parentAndName = try openParent(
                rootURL: rootURL,
                path: path,
                createDirectories: false
            )
        } catch NextStepSyncError.notFound(_) {
            // A missing ancestor means the requested file is absent too. Keep
            // `readIfPresent` nil-returning for a fresh local store while still
            // allowing symlink and other integrity failures to fail closed.
            return nil
        }
        let (parent, finalName) = parentAndName
        defer { _ = Darwin.close(parent) }

        let descriptor = finalName.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            if errno == ELOOP { throw NextStepSyncError.symlinkRejected(path.description) }
            throw posixError(path.description)
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_size >= 0 else {
            throw NextStepSyncError.nonRegularFile(path.description)
        }
        guard metadata.st_size <= off_t(maximumBytes) else {
            throw NextStepSyncError.sizeLimitExceeded(limit: maximumBytes)
        }

        var result = Data()
        result.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            var current = stat()
            guard Darwin.fstat(descriptor, &current) == 0,
                  (current.st_mode & S_IFMT) == S_IFREG,
                  current.st_size >= 0,
                  current.st_size <= off_t(maximumBytes) else {
                throw NextStepSyncError.sizeLimitExceeded(limit: maximumBytes)
            }
            let remaining = maximumBytes - result.count
            let requestCount = min(buffer.count, remaining + 1)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, requestCount)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError(path.description)
            }
            if count == 0 { break }
            guard count <= remaining else {
                throw NextStepSyncError.sizeLimitExceeded(limit: maximumBytes)
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    static func writeImmutable(rootURL: URL, path: SyncRelativePath, data: Data) throws {
        let (parent, finalName) = try openParent(
            rootURL: rootURL,
            path: path,
            createDirectories: true
        )
        defer { _ = Darwin.close(parent) }

        let descriptor = finalName.withCString {
            Darwin.openat(
                parent,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            if errno == EEXIST {
                let existing = try readIfPresent(
                    rootURL: rootURL,
                    path: path,
                    maximumBytes: data.count
                )
                guard existing == data else {
                    throw NextStepSyncError.immutableFileCollision(path.description)
                }
                return
            }
            if errno == ELOOP { throw NextStepSyncError.symlinkRejected(path.description) }
            throw posixError(path.description)
        }

        var succeeded = false
        defer {
            _ = Darwin.close(descriptor)
            if !succeeded {
                finalName.withCString { _ = Darwin.unlinkat(parent, $0, 0) }
            }
        }
        try write(data, descriptor: descriptor, label: path.description)
        guard Darwin.fsync(descriptor) == 0 else { throw posixError(path.description) }
        succeeded = true
        _ = Darwin.fsync(parent)
    }

    static func replaceAtomically(rootURL: URL, path: SyncRelativePath, data: Data) throws {
        let (parent, finalName) = try openParent(
            rootURL: rootURL,
            path: path,
            createDirectories: true
        )
        defer { _ = Darwin.close(parent) }

        let temporaryName = ".nextstep-sync-\(UUID().uuidString.lowercased()).tmp"
        let descriptor = temporaryName.withCString {
            Darwin.openat(
                parent,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else { throw posixError(path.description) }

        var renamed = false
        defer {
            _ = Darwin.close(descriptor)
            if !renamed {
                temporaryName.withCString { _ = Darwin.unlinkat(parent, $0, 0) }
            }
        }

        try write(data, descriptor: descriptor, label: path.description)
        guard Darwin.fsync(descriptor) == 0 else { throw posixError(path.description) }
        let result = temporaryName.withCString { source in
            finalName.withCString { destination in
                Darwin.renameat(parent, source, parent, destination)
            }
        }
        guard result == 0 else { throw posixError(path.description) }
        renamed = true
        _ = Darwin.fsync(parent)
    }

    static func removeIfPresent(rootURL: URL, path: SyncRelativePath) throws {
        let (parent, finalName) = try openParent(
            rootURL: rootURL,
            path: path,
            createDirectories: false
        )
        defer { _ = Darwin.close(parent) }
        let result = finalName.withCString { Darwin.unlinkat(parent, $0, 0) }
        guard result == 0 || errno == ENOENT else { throw posixError(path.description) }
        _ = Darwin.fsync(parent)
    }

    static func list(rootURL: URL, path: SyncRelativePath) throws -> [SyncTransportEntry] {
        let descriptor = try openDirectory(rootURL: rootURL, components: path.components, create: false)
        let duplicate = Darwin.dup(descriptor)
        _ = Darwin.close(descriptor)
        guard duplicate >= 0, let directory = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            throw posixError(path.description)
        }
        defer { _ = Darwin.closedir(directory) }

        let directoryDescriptor = Darwin.dirfd(directory)
        var entries: [SyncTransportEntry] = []
        errno = 0
        while let pointer = Darwin.readdir(directory) {
            let name = withUnsafeBytes(of: pointer.pointee.d_name) { bytes -> String in
                guard let baseAddress = bytes.baseAddress else { return "" }
                return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
            }
            if name == "." || name == ".." { continue }
            _ = try SyncRelativePath(component: name)
            var metadata = stat()
            let status = name.withCString {
                Darwin.fstatat(directoryDescriptor, $0, &metadata, AT_SYMLINK_NOFOLLOW)
            }
            guard status == 0 else { throw posixError(path.description) }
            if (metadata.st_mode & S_IFMT) == S_IFLNK {
                throw NextStepSyncError.symlinkRejected(path.description + "/" + name)
            }
            let isDirectory = (metadata.st_mode & S_IFMT) == S_IFDIR
            let isRegular = (metadata.st_mode & S_IFMT) == S_IFREG
            if !isDirectory && !isRegular { continue }
            entries.append(.init(
                name: name,
                isDirectory: isDirectory,
                byteCount: isRegular ? Int64(metadata.st_size) : nil
            ))
            guard entries.count <= SyncLimits.maximumDirectoryEntries else {
                throw NextStepSyncError.operationLimitExceeded
            }
        }
        guard errno == 0 else { throw posixError(path.description) }
        return entries.sorted { $0.name < $1.name }
    }

    private static func openParent(
        rootURL: URL,
        path: SyncRelativePath,
        createDirectories: Bool
    ) throws -> (descriptor: Int32, finalName: String) {
        guard let finalName = path.components.last else {
            throw NextStepSyncError.invalidRelativePath(path.description)
        }
        let descriptor = try openDirectory(
            rootURL: rootURL,
            components: Array(path.components.dropLast()),
            create: createDirectories
        )
        return (descriptor, finalName)
    }

    private static func openDirectory(
        rootURL: URL,
        components: [String],
        create: Bool
    ) throws -> Int32 {
        var current = rootURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard current >= 0 else {
            if errno == ELOOP { throw NextStepSyncError.symlinkRejected(rootURL.path) }
            throw NextStepSyncError.transportUnavailable
        }

        do {
            for component in components {
                var next = component.withCString {
                    Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                }
                if next < 0, errno == ENOENT, create {
                    let made = component.withCString {
                        Darwin.mkdirat(current, $0, mode_t(S_IRWXU))
                    }
                    guard made == 0 || errno == EEXIST else {
                        throw posixError(component)
                    }
                    next = component.withCString {
                        Darwin.openat(current, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                    }
                }
                guard next >= 0 else {
                    if errno == ENOENT { throw NextStepSyncError.notFound(component) }
                    if errno == ELOOP || errno == ENOTDIR {
                        throw NextStepSyncError.symlinkRejected(component)
                    }
                    throw posixError(component)
                }
                _ = Darwin.close(current)
                current = next
            }
            return current
        } catch {
            _ = Darwin.close(current)
            throw error
        }
    }

    private static func write(_ data: Data, descriptor: Int32, label: String) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let base = bytes.baseAddress else { break }
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    min(64 * 1_024, bytes.count - offset)
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError(label)
                }
                guard count > 0 else { throw posixError(label) }
                offset += count
            }
        }
    }

    private static func posixError(_ label: String) -> NextStepSyncError {
        let message = String(cString: strerror(errno))
        return .ioFailure("\(label): \(message)")
    }
}
