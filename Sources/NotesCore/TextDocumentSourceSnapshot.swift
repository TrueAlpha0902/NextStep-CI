import Foundation

/// An exact point-in-time view of one persisted text-document block.
///
/// `textHash` is computed from the block's unmodified UTF-8 bytes. In
/// particular, whitespace, line endings, Unicode normalization, and invisible
/// scalars are significant. `noteRevision` is the authoritative manifest
/// revision that contained `pageID` when the block was read.
public struct TextDocumentSourceSnapshot: Equatable, Sendable {
    public let noteID: NotebookID
    public let pageID: PageID
    public let blockIndex: Int
    public let block: TextBlock
    public let noteRevision: Int64
    public let textHash: String

    public var blockID: TextBlockID { block.id }
    public var text: String { block.text }

    public init(
        noteID: NotebookID,
        pageID: PageID,
        blockIndex: Int,
        block: TextBlock,
        noteRevision: Int64
    ) {
        self.noteID = noteID
        self.pageID = pageID
        self.blockIndex = blockIndex
        self.block = block
        self.noteRevision = noteRevision
        self.textHash = ExactTextHash.sha256UTF8(block.text)
    }
}

/// Minimal read capability used by academic source anchors. Implementations
/// must return one authoritative snapshot or throw; partial or best-effort
/// values are not valid source anchors.
public protocol TextDocumentSourceSnapshotProviding: Sendable {
    func textDocumentSourceSnapshot(
        noteID: NotebookID,
        pageID: PageID,
        blockID: TextBlockID
    ) async throws -> TextDocumentSourceSnapshot
}

/// Exact hashing used by text-document source anchors.
public enum ExactTextHash {
    /// Returns the lowercase SHA-256 digest of `text`'s bytes in Swift's exact
    /// UTF-8 representation. No trimming, line-ending conversion, case folding,
    /// or Unicode normalization is performed.
    public static func sha256UTF8(_ text: String) -> String {
        SHA256.hexDigest(Data(text.utf8))
    }
}
