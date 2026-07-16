import Foundation
import Testing
@testable import NotesServices

@Test("Backup creation rejects symbolic links anywhere inside a notebook package")
func backupRejectsNestedSymbolicLinks() async throws {
    let root = try backupTestRoot("Symlink")
    defer { try? FileManager.default.removeItem(at: root) }
    let packageName = "\(UUID().uuidString).notepkg"
    let source = try makeNotebook(named: packageName, in: root)
    let outside = root.appendingPathComponent("outside.txt")
    try Data("private".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(
        at: source.appendingPathComponent("escape"),
        withDestinationURL: outside
    )
    let backupFolder = root.appendingPathComponent("Backups", isDirectory: true)
    try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
    let destination = try BackupDestination(url: backupFolder)
    let service = FileBackupService()

    do {
        _ = try await service.createSnapshot(notebookURLs: [source], at: destination)
        Issue.record("A notebook containing a symbolic link was backed up")
    } catch let error as FileBackupError {
        #expect(error == .unsafeItem("escape"))
    }
    #expect((try FileManager.default.contentsOfDirectory(atPath: backupFolder.path)).isEmpty)
}

@Test("Restore trusts the authoritative snapshot manifest, not caller-supplied file names")
func restoreIgnoresTamperedSnapshotNames() async throws {
    let root = try backupTestRoot("ManifestAuthority")
    defer { try? FileManager.default.removeItem(at: root) }
    let packageName = "\(UUID().uuidString).notepkg"
    let source = try makeNotebook(named: packageName, in: root)
    let backupFolder = root.appendingPathComponent("Backups", isDirectory: true)
    let library = root.appendingPathComponent("Restored", isDirectory: true)
    try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
    let destination = try BackupDestination(url: backupFolder)
    let service = FileBackupService()
    let snapshot = try await service.createSnapshot(notebookURLs: [source], at: destination)

    var tampered = snapshot
    tampered.notebookNames = ["../../outside.notepkg"]
    let restored = try await service.restore(tampered, from: destination, into: library)

    #expect(restored.count == 1)
    #expect(restored.first?.lastPathComponent == packageName)
    #expect(FileManager.default.fileExists(
        atPath: restored[0].appendingPathComponent("content.txt").path
    ))
}

@Test("A traversal snapshot folder is rejected before filesystem access")
func restoreRejectsSnapshotFolderTraversal() async throws {
    let root = try backupTestRoot("Traversal")
    defer { try? FileManager.default.removeItem(at: root) }
    let backupFolder = root.appendingPathComponent("Backups", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
    let destination = try BackupDestination(url: backupFolder)
    let service = FileBackupService()
    let malicious = BackupSnapshot(folderName: "../escape", notebookNames: ["x.notepkg"])

    do {
        _ = try await service.restore(malicious, from: destination, into: library)
        Issue.record("Snapshot folder traversal was accepted")
    } catch let error as FileBackupError {
        guard case .unsafeItem = error else { Issue.record("Unexpected error: \(error)"); return }
    }
    #expect(!FileManager.default.fileExists(atPath: library.path))
}

@Test("Corrupt manifests are excluded and cannot be restored")
func corruptBackupManifestIsRejected() async throws {
    let root = try backupTestRoot("CorruptManifest")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try makeNotebook(named: "\(UUID().uuidString).notepkg", in: root)
    let backupFolder = root.appendingPathComponent("Backups", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
    let destination = try BackupDestination(url: backupFolder)
    let service = FileBackupService()
    let snapshot = try await service.createSnapshot(notebookURLs: [source], at: destination)
    let manifest = backupFolder
        .appendingPathComponent(snapshot.folderName, isDirectory: true)
        .appendingPathComponent("backup.json")
    try Data("corrupt".utf8).write(to: manifest, options: .atomic)

    #expect(try await service.snapshots(at: destination).isEmpty)
    do {
        _ = try await service.restore(snapshot, from: destination, into: library)
        Issue.record("A corrupt snapshot was restored")
    } catch {
        #expect(!FileManager.default.fileExists(atPath: library.path))
    }
}

@Test("A restore failure rolls back every package already committed")
func restoreFailureRollsBackPartialResults() async throws {
    let root = try backupTestRoot("Rollback")
    defer { try? FileManager.default.removeItem(at: root) }
    let first = try makeNotebook(named: "\(UUID().uuidString).notepkg", in: root)
    let second = try makeNotebook(named: "\(UUID().uuidString).notepkg", in: root)
    let backupFolder = root.appendingPathComponent("Backups", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
    let destination = try BackupDestination(url: backupFolder)
    let snapshot = try await FileBackupService().createSnapshot(
        notebookURLs: [first, second],
        at: destination
    )
    let failingManager = FailingSecondRestoreMoveFileManager()
    let service = FileBackupService(fileManager: failingManager)

    do {
        _ = try await service.restore(snapshot, from: destination, into: library)
        Issue.record("The injected second move failure did not fail the restore")
    } catch {
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: library.path)
        #expect(leftovers.isEmpty)
    }
}

@Test("Restore rejects a notebook package replaced by a symbolic link after backup")
func restoreRejectsTamperedPackageSymbolicLink() async throws {
    let root = try backupTestRoot("RestoreSymlink")
    defer { try? FileManager.default.removeItem(at: root) }
    let packageName = "\(UUID().uuidString).notepkg"
    let source = try makeNotebook(named: packageName, in: root)
    let backupFolder = root.appendingPathComponent("Backups", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
    let destination = try BackupDestination(url: backupFolder)
    let service = FileBackupService()
    let snapshot = try await service.createSnapshot(notebookURLs: [source], at: destination)
    let copiedPackage = backupFolder
        .appendingPathComponent(snapshot.folderName, isDirectory: true)
        .appendingPathComponent(packageName, isDirectory: true)
    try FileManager.default.removeItem(at: copiedPackage)
    try FileManager.default.createSymbolicLink(at: copiedPackage, withDestinationURL: source)

    do {
        _ = try await service.restore(snapshot, from: destination, into: library)
        Issue.record("A symbolic-link notebook package was restored")
    } catch let error as FileBackupError {
        #expect(error == .unsafeItem(packageName))
    }
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: library.path)
    #expect(leftovers.isEmpty)
}

@Test("Restore reports a notebook identity conflict without renaming the package")
func restoreRejectsExistingNotebookIdentity() async throws {
    let root = try backupTestRoot("IdentityConflict")
    defer { try? FileManager.default.removeItem(at: root) }
    let packageName = "\(UUID().uuidString).notepkg"
    let source = try makeNotebook(named: packageName, in: root)
    let backupFolder = root.appendingPathComponent("Backups", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    try FileManager.default.createDirectory(at: backupFolder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    let existing = try makeNotebook(named: packageName, in: library)
    try Data("original library package".utf8).write(
        to: existing.appendingPathComponent("sentinel.txt")
    )
    let destination = try BackupDestination(url: backupFolder)
    let service = FileBackupService()
    let snapshot = try await service.createSnapshot(notebookURLs: [source], at: destination)

    await #expect(throws: FileBackupError.destinationConflict(packageName)) {
        try await service.restore(snapshot, from: destination, into: library)
    }
    #expect(FileManager.default.fileExists(atPath: existing.appendingPathComponent("sentinel.txt").path))
    #expect((try FileManager.default.contentsOfDirectory(atPath: library.path)).count == 1)
}

private func backupTestRoot(_ suffix: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NotesBackup\(suffix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func makeNotebook(named name: String, in root: URL) throws -> URL {
    let notebook = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: notebook, withIntermediateDirectories: true)
    try Data("notebook contents".utf8).write(to: notebook.appendingPathComponent("content.txt"))
    return notebook
}

private final class FailingSecondRestoreMoveFileManager: FileManager, @unchecked Sendable {
    private var restoreMoveCount = 0

    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        if srcURL.deletingLastPathComponent().lastPathComponent.hasPrefix(".restore-") {
            restoreMoveCount += 1
            if restoreMoveCount == 2 {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
