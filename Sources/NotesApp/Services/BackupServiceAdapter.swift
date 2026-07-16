import Foundation
import NotesServices

protocol NotesBackupServicing: Sendable {
    func createSnapshot(
        notebookURLs: [URL],
        at destination: BackupDestination,
        keepLatest: Int
    ) async throws -> BackupSnapshot
    func snapshots(at destination: BackupDestination) async throws -> [BackupSnapshot]
    func restore(
        _ snapshot: BackupSnapshot,
        from destination: BackupDestination,
        into libraryDirectory: URL
    ) async throws -> [URL]
}

extension FileBackupService: NotesBackupServicing {}
