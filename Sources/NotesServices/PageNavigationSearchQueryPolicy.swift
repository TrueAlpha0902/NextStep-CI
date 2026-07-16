import Foundation

/// Defines the small, locale-bounded query vocabulary used to find page
/// bookmarks. A bookmark is boolean metadata rather than user-authored text,
/// so it must not participate in ordinary substring or token matching.
public enum PageNavigationSearchQueryPolicy {
    /// Stable, nonlocalized payload stored in `.bookmark` search segments.
    /// Presentation code must use the segment source for its localized label.
    public static let bookmarkSegmentText = "bookmark"

    /// Recognizes only complete bookmark aliases supported by the app's two
    /// localizations. Case, diacritics, width, and runs of whitespace are
    /// normalized, while partial words and unrelated concepts remain false.
    public static func isExactBookmarkQuery(_ text: String) -> Bool {
        bookmarkAliases.contains(normalizedAlias(text))
    }

    static func bookmarkSnippet(for text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let bookmarkAliases: Set<String> = [
        "bookmark",
        "bookmarked",
        "bookmarked page",
        "書籤",
        "已加書籤",
    ]

    private static func normalizedAlias(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .split { $0.isWhitespace }
        .joined(separator: " ")
    }
}
