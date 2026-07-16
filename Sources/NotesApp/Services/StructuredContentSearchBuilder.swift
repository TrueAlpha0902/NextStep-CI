import Foundation
import NotesCore
import NotesServices

/// Converts structured pages into the single text segment used by the local
/// search index. Keeping this transformation pure makes rebuilding the derived
/// index deterministic and keeps presentation labels out of searchable text.
enum StructuredContentSearchBuilder {
    static func segment(
        for content: PageContent,
        pageID: UUID
    ) -> RecognizedTextSegment? {
        guard let text = plainText(for: content) else { return nil }
        return RecognizedTextSegment(
            id: pageID,
            text: text,
            pageID: pageID,
            source: .typedText
        )
    }

    static func plainText(for content: PageContent) -> String? {
        switch content {
        case .textDocument(let document):
            plainText(for: document)
        case .studySet(let studySet):
            plainText(for: studySet)
        }
    }

    static func plainText(for document: TextDocument) -> String? {
        normalizedText(
            document.blocks.compactMap { block in
                switch block.style {
                case .divider:
                    nil
                default:
                    nonempty(block.text)
                }
            }
        )
    }

    static func plainText(for studySet: StudySet) -> String? {
        normalizedText(
            studySet.cards.flatMap { card in
                [card.prompt, card.answer, card.hint]
                    .compactMap { $0 }
                    + card.tags
            }
        )
    }

    private static func normalizedText(_ fields: [String]) -> String? {
        let values = fields.compactMap(nonempty)
        return values.isEmpty ? nil : values.joined(separator: "\n")
    }

    private static func nonempty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
