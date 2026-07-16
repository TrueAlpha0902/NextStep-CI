import Foundation
import NotesCore

/// Portable, text-based exports for Notes' structured page types.
enum StructuredContentExportRenderer {
    static func markdown(from document: TextDocument) -> String {
        document.blocks.compactMap(markdownBlock).joined(separator: "\n\n")
    }

    static func csv(from studySet: StudySet) -> String {
        let header = ["Prompt", "Answer", "Hint", "Tags"]
        let rows = studySet.cards.map { card in
            [
                card.prompt,
                card.answer,
                card.hint ?? "",
                card.tags.joined(separator: ", "),
            ]
        }
        return ([header] + rows)
            .map { $0.map(csvField).joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
    }

    static func temporaryMarkdown(
        title: String,
        document: TextDocument,
        identifier: UUID = UUID()
    ) throws -> URL {
        try writeTemporaryExport(
            Data(markdown(from: document).utf8),
            title: title,
            fallbackTitle: "NextStep Document",
            identifier: identifier,
            pathExtension: "md"
        )
    }

    static func temporaryCSV(
        title: String,
        studySet: StudySet,
        identifier: UUID = UUID()
    ) throws -> URL {
        try writeTemporaryExport(
            Data(csv(from: studySet).utf8),
            title: title,
            fallbackTitle: "NextStep Study Set",
            identifier: identifier,
            pathExtension: "csv"
        )
    }

    private static func markdownBlock(_ block: TextBlock) -> String? {
        let indentation = String(repeating: "    ", count: max(0, block.indentationLevel))
        let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch block.style {
        case .divider:
            return "---"
        case .title:
            return prefixedLines(text, first: "# ", continuation: "  ")
        case .heading1:
            return prefixedLines(text, first: "## ", continuation: "  ")
        case .heading2:
            return prefixedLines(text, first: "### ", continuation: "  ")
        case .heading3:
            return prefixedLines(text, first: "#### ", continuation: "  ")
        case .body:
            return text.isEmpty ? nil : text
        case .bulletedList:
            return prefixedLines(text, first: "\(indentation)- ", continuation: "\(indentation)  ")
        case .numberedList:
            return prefixedLines(text, first: "\(indentation)1. ", continuation: "\(indentation)   ")
        case .checklist:
            let marker = block.isChecked == true ? "[x]" : "[ ]"
            return prefixedLines(
                text,
                first: "\(indentation)- \(marker) ",
                continuation: "\(indentation)      "
            )
        case .quote:
            return prefixedLines(
                text,
                first: "\(indentation)> ",
                continuation: "\(indentation)> "
            )
        case .code:
            guard !text.isEmpty else { return nil }
            let fence = codeFence(for: block.text)
            return "\(fence)\n\(block.text)\n\(fence)"
        }
    }

    private static func prefixedLines(
        _ text: String,
        first firstPrefix: String,
        continuation continuationPrefix: String
    ) -> String? {
        guard !text.isEmpty else { return nil }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return ([firstPrefix + lines[0]] + lines.dropFirst().map { continuationPrefix + $0 })
            .joined(separator: "\n")
    }

    private static func codeFence(for text: String) -> String {
        var currentRun = 0
        var longestRun = 0
        for character in text {
            if character == "`" {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        return String(repeating: "`", count: max(3, longestRun + 1))
    }

    private static func csvField(_ original: String) -> String {
        let normalized = original
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        let protected = formulaSafeCSVValue(normalized)
        guard requiresCSVQuotes(protected) else {
            return protected
        }
        return "\"\(protected.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func requiresCSVQuotes(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x0A, 0x0D, 0x22, 0x2C:
                true
            default:
                false
            }
        }
    }

    /// Spreadsheet applications may execute fields beginning with these
    /// characters. Prefixing an apostrophe preserves the visible value while
    /// forcing the cell to be interpreted as text.
    private static func formulaSafeCSVValue(_ value: String) -> String {
        guard let firstMeaningful = value.unicodeScalars.first(where: {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }) else { return value }
        let dangerous = CharacterSet(charactersIn: "=+-@")
        return dangerous.contains(firstMeaningful) ? "'" + value : value
    }

    private static func writeTemporaryExport(
        _ data: Data,
        title: String,
        fallbackTitle: String,
        identifier: UUID,
        pathExtension: String
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotesExports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let filename = safeFilename(title, fallback: fallbackTitle)
        let suffix = identifier.uuidString.lowercased().prefix(8)
        let url = directory
            .appendingPathComponent("\(filename)-\(suffix)", isDirectory: false)
            .appendingPathExtension(pathExtension)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    private static func safeFilename(_ title: String, fallback: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        let sanitized = title.unicodeScalars
            .map { allowed.contains($0) ? Character(String($0)) : " " }
        let compact = String(sanitized)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return compact.isEmpty ? fallback : String(compact.prefix(80))
    }
}
