import CryptoKit
import Foundation
import NotesCore
import NotesServices

/// Builds one namespaced, derived navigation-search document per page. Keeping
/// outline and bookmark metadata together makes every field-scoped metadata
/// update replace the page's complete searchable navigation state.
enum PageNavigationSearchBuilder {
    private static let documentNamespace =
        "com.speci.localnotes.search.page-navigation.v1"
    private static let outlineSegmentNamespace =
        "com.speci.localnotes.search.page-navigation.outline.v1"
    private static let bookmarkSegmentNamespace =
        "com.speci.localnotes.search.page-navigation.bookmark.v1"
    private static let fingerprintNamespace =
        "com.speci.localnotes.search.page-navigation-fingerprint.v1"

    static func documentID(notebookID: UUID, pageID: UUID) -> UUID {
        derivedID(
            namespace: documentNamespace,
            notebookID: notebookID,
            pageID: pageID
        )
    }

    static func outlineSegmentID(notebookID: UUID, pageID: UUID) -> UUID {
        derivedID(
            namespace: outlineSegmentNamespace,
            notebookID: notebookID,
            pageID: pageID
        )
    }

    static func bookmarkSegmentID(notebookID: UUID, pageID: UUID) -> UUID {
        derivedID(
            namespace: bookmarkSegmentNamespace,
            notebookID: notebookID,
            pageID: pageID
        )
    }

    static func segments(
        for page: EditorPage,
        notebookID: UUID
    ) -> [RecognizedTextSegment] {
        var segments: [RecognizedTextSegment] = []
        if let outlineTitle = page.outlineTitle.flatMap(
            PageNavigationMetadataPolicy.canonicalOutlineTitle
        ) {
            segments.append(RecognizedTextSegment(
                id: outlineSegmentID(
                    notebookID: notebookID,
                    pageID: page.id
                ),
                text: outlineTitle,
                pageID: page.id,
                source: .outline
            ))
        }
        if page.isBookmarked {
            segments.append(RecognizedTextSegment(
                id: bookmarkSegmentID(
                    notebookID: notebookID,
                    pageID: page.id
                ),
                text: PageNavigationSearchQueryPolicy.bookmarkSegmentText,
                pageID: page.id,
                source: .bookmark
            ))
        }
        return segments
    }

    static func sourceFingerprint(
        for segments: [RecognizedTextSegment]
    ) -> String {
        var material = Data(fingerprintNamespace.utf8)
        for segment in segments {
            append(segment.id, to: &material)
            append(segment.source.rawValue, to: &material)
            append(segment.text, to: &material)
        }
        return SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func document(
        for page: EditorPage,
        notebookID: UUID,
        notebookTitle: String,
        revision: Int
    ) -> SearchIndexDocument? {
        let segments = segments(for: page, notebookID: notebookID)
        guard !segments.isEmpty else { return nil }
        return SearchIndexDocument(
            id: documentID(notebookID: notebookID, pageID: page.id),
            notebookID: notebookID,
            pageID: page.id,
            title: notebookTitle,
            revision: revision,
            sourceFingerprint: sourceFingerprint(for: segments),
            segments: segments,
            modifiedAt: page.modifiedAt
        )
    }

    private static func derivedID(
        namespace: String,
        notebookID: UUID,
        pageID: UUID
    ) -> UUID {
        var material = Data(namespace.utf8)
        append(notebookID, to: &material)
        append(pageID, to: &material)
        var bytes = Array(SHA256.hash(data: material).prefix(16))
        // UUID version 8 denotes an application-defined, name-derived UUID.
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func append(_ value: UUID, to data: inout Data) {
        Swift.withUnsafeBytes(of: value.uuid) {
            data.append(contentsOf: $0)
        }
    }

    private static func append(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        Swift.withUnsafeBytes(of: &length) {
            data.append(contentsOf: $0)
        }
        data.append(bytes)
    }
}

enum PageNavigatorFilter: String, CaseIterable, Hashable, Identifiable, Sendable {
    case all
    case bookmarks
    case outline

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .bookmarks: "Bookmarks"
        case .outline: "Outline"
        }
    }
}

struct PageNavigatorEntry: Equatable, Identifiable, Sendable {
    let page: EditorPage
    let pageNumber: Int

    var id: UUID { page.id }
}

enum PageNavigatorPolicy {
    static func entries(
        in pages: [EditorPage],
        filter: PageNavigatorFilter
    ) -> [PageNavigatorEntry] {
        pages.enumerated().compactMap { index, page in
            let isIncluded = switch filter {
            case .all:
                true
            case .bookmarks:
                page.isBookmarked
            case .outline:
                page.outlineTitle != nil
            }
            return isIncluded
                ? PageNavigatorEntry(page: page, pageNumber: index + 1)
                : nil
        }
    }
}

enum PageNavigationMetadataPolicy {
    static let maximumOutlineTitleCharacters =
        PageDescriptor.maximumOutlineTitleCharacters
    static let maximumOutlineTitleUTF8Bytes =
        PageDescriptor.maximumOutlineTitleUTF8Bytes

    /// Produces the only representation sent to NotesCore: trimmed,
    /// single-line text with whitespace runs collapsed and a grapheme-safe
    /// 120-character ceiling. Empty input clears the outline entry.
    static func canonicalOutlineTitle(_ rawValue: String) -> String? {
        let singleLine = rawValue.unicodeScalars.map { scalar -> String in
            if PageDescriptor.isDisallowedOutlineScalar(scalar) {
                return " "
            }
            return String(scalar)
        }.joined()
        let collapsed = singleLine
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        let limited = graphemeSafePrefix(collapsed)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PageDescriptor.isValidOutlineTitle(limited) ? limited : nil
    }

    /// Keeps pasted text safe for a one-line TextField while preserving
    /// in-progress leading/trailing spaces until the user commits.
    static func limitedOutlineInput(_ rawValue: String) -> String {
        let singleLine = rawValue.unicodeScalars.map { scalar -> String in
            if PageDescriptor.isDisallowedOutlineScalar(scalar) {
                return " "
            }
            return String(scalar)
        }.joined()
        return graphemeSafePrefix(singleLine)
    }

    /// A duplicate is content-equivalent but intentionally starts outside the
    /// source page's personal navigation organization.
    static func duplicatePage(from page: EditorPage, modifiedAt: Date) -> EditorPage {
        EditorPage(
            kind: page.kind,
            modifiedAt: modifiedAt,
            background: page.background,
            width: page.width,
            height: page.height,
            isBookmarked: false,
            outlineTitle: nil
        )
    }

    static func isSatisfied(
        _ update: PageNavigationMetadataUpdate,
        by page: EditorPage
    ) -> Bool {
        switch update {
        case .bookmark(let isBookmarked):
            page.isBookmarked == isBookmarked
        case .outlineTitle(let outlineTitle):
            page.outlineTitle == outlineTitle
        }
    }

    private static func graphemeSafePrefix(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(maximumOutlineTitleCharacters)
        var characterCount = 0
        var utf8ByteCount = 0
        for character in value {
            let fragment = String(character)
            let fragmentByteCount = fragment.utf8.count
            guard characterCount < maximumOutlineTitleCharacters,
                  utf8ByteCount + fragmentByteCount
                    <= maximumOutlineTitleUTF8Bytes else {
                break
            }
            result.append(character)
            characterCount += 1
            utf8ByteCount += fragmentByteCount
        }
        return result
    }
}

enum PageNavigationMutationInterlockPolicy {
    static func canNavigate(
        isReplayMutationLocked: Bool,
        activeStructuralMutationCount: Int,
        isMetadataMutationInFlight: Bool
    ) -> Bool {
        !isReplayMutationLocked
            && activeStructuralMutationCount == 0
            && !isMetadataMutationInFlight
    }

    static func canBeginMetadataMutation(
        isReplayMutationLocked: Bool,
        activeStructuralMutationCount: Int,
        hasStructuralMutationTask: Bool,
        isMetadataMutationInFlight: Bool,
        hasPDFExportTask: Bool
    ) -> Bool {
        !isReplayMutationLocked
            && activeStructuralMutationCount == 0
            && !hasStructuralMutationTask
            && !isMetadataMutationInFlight
            && !hasPDFExportTask
    }

    static func canBeginStructuralMutation(
        isReplayMutationLocked: Bool,
        isAudioStructureMutationLocked: Bool,
        activeStructuralMutationCount: Int,
        hasStructuralMutationTask: Bool,
        isMetadataMutationInFlight: Bool
    ) -> Bool {
        !isReplayMutationLocked
            && !isAudioStructureMutationLocked
            && activeStructuralMutationCount == 0
            && !hasStructuralMutationTask
            && !isMetadataMutationInFlight
    }
}

enum PageNavigationMetadataSummaryPolicy {
    /// Navigation metadata cannot change any library-facing field except the
    /// notebook modification time. Preserve concurrent rename, favorite,
    /// trash, cover, kind, and page-count publications while keeping the
    /// timestamp monotonic when ink or element saves finish out of order.
    static func merging(
        persistedNavigationSummary: LibraryNotebook,
        into currentSummary: LibraryNotebook?
    ) -> LibraryNotebook? {
        guard let currentSummary else {
            // An editor-originated metadata write must never recreate a row
            // that a concurrent permanent deletion already removed.
            return nil
        }
        var merged = currentSummary
        merged.modifiedAt = max(
            currentSummary.modifiedAt,
            persistedNavigationSummary.modifiedAt
        )
        return merged
    }
}

struct PageNavigationMetadataPublicationAuthority: Equatable, Sendable {
    let mutationID: UUID
    let notebookSnapshot: EditorNotebook
    let selectedPageID: UUID

    static func canPublish(
        _ persistedNotebook: EditorNotebook,
        authority: Self,
        currentMutationID: UUID,
        currentNotebook: EditorNotebook?,
        currentSelectedPageID: UUID?,
        isReplayMutationLocked: Bool
    ) -> Bool {
        guard !isReplayMutationLocked,
              authority.mutationID == currentMutationID,
              authority.notebookSnapshot == currentNotebook,
              authority.selectedPageID == currentSelectedPageID,
              persistedNotebook.id == authority.notebookSnapshot.id,
              persistedNotebook.pages.contains(where: {
                  $0.id == authority.selectedPageID
              }) else {
            return false
        }
        return true
    }
}
