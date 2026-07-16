import Foundation

public protocol IntelligenceProviding: Sendable {
    var providerName: String { get }
    func perform(_ request: IntelligenceRequest) async throws -> IntelligenceResult
}

public enum IntelligenceProviderError: LocalizedError, Equatable, Sendable {
    case emptyInput
    case generativeModelRequired

    public var errorDescription: String? {
        switch self {
        case .emptyInput: "Add some text before using this tool."
        case .generativeModelRequired: "This action requires an installed local language model."
        }
    }
}

public actor ExtractiveIntelligenceProvider: IntelligenceProviding {
    public nonisolated let providerName = "On-device extractive engine"

    public init() {}

    public func perform(_ request: IntelligenceRequest) async throws -> IntelligenceResult {
        let cleanText = request.text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        let usesTraditionalChinese = request.localeIdentifier.lowercased().hasPrefix("zh")
        let acceptsEmptyText: Bool
        if case .calculate(_) = request.action { acceptsEmptyText = true } else { acceptsEmptyText = false }
        guard acceptsEmptyText || !cleanText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IntelligenceProviderError.emptyInput
        }
        switch request.action {
        case .summarize:
            return IntelligenceResult(
                text: Self.summary(of: cleanText),
                citations: request.citations,
                providerName: providerName,
                isGenerative: false
            )
        case .rewrite:
            let paragraphs = Self.paragraphs(in: cleanText).map { paragraph in
                paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return IntelligenceResult(
                text: paragraphs.joined(separator: "\n\n"),
                citations: request.citations,
                providerName: providerName,
                isGenerative: false
            )
        case .outline:
            let lines = Self.paragraphs(in: cleanText).prefix(12).enumerated().map { index, paragraph in
                let title = String(Self.sentences(in: paragraph).first?.prefix(80) ?? paragraph.prefix(80))
                return "\(index + 1). \(title)"
            }
            return IntelligenceResult(
                text: lines.joined(separator: "\n"),
                citations: request.citations,
                providerName: providerName,
                isGenerative: false
            )
        case .meetingNotes:
            let sentences = Self.sentences(in: cleanText)
            let actionWords = ["需要", "請", "待辦", "follow up", "action", "todo", "決定", "deadline"]
            let actions = sentences.filter { sentence in
                let lower = sentence.lowercased()
                return actionWords.contains { lower.contains($0) }
            }
            let emptyAction = usesTraditionalChinese
                ? "- 尚未偵測到明確待辦事項"
                : "- No explicit action item was detected."
            let actionText = actions.isEmpty ? emptyAction : actions.map { "- \($0)" }.joined(separator: "\n")
            let summaryHeading = usesTraditionalChinese ? "重點" : "Highlights"
            let actionsHeading = usesTraditionalChinese ? "待辦事項" : "Action items"
            let result = "\(summaryHeading)\n\(Self.summary(of: cleanText))\n\n\(actionsHeading)\n\(actionText)"
            return IntelligenceResult(
                text: result,
                citations: request.citations,
                providerName: providerName,
                isGenerative: false
            )
        case .quiz(let questionCount):
            let items = Self.quiz(
                from: cleanText,
                count: max(1, min(questionCount, 20)),
                usesTraditionalChinese: usesTraditionalChinese
            )
            return IntelligenceResult(
                text: items.map { "Q: \($0.question)\nA: \($0.answer)" }.joined(separator: "\n\n"),
                quizItems: items,
                citations: request.citations,
                providerName: providerName,
                isGenerative: false
            )
        case .ask(let question):
            let matches = Self.bestMatches(for: question, in: cleanText, limit: 3)
            let citations = request.citations.isEmpty
                ? matches.enumerated().map { index, excerpt in
                    IntelligenceCitation(
                        label: "\(usesTraditionalChinese ? "摘錄" : "Excerpt") \(index + 1)",
                        excerpt: excerpt
                    )
                }
                : request.citations
            return IntelligenceResult(
                text: matches.isEmpty ? Self.summary(of: cleanText) : matches.joined(separator: "\n\n"),
                citations: citations,
                providerName: providerName,
                isGenerative: false
            )
        case .explain:
            return IntelligenceResult(
                text: "\(usesTraditionalChinese ? "重點說明" : "Explanation")\n\(Self.summary(of: cleanText))",
                citations: request.citations,
                providerName: providerName,
                isGenerative: false
            )
        case .calculate(let expression):
            let value = try MathExpressionEvaluator().evaluate(expression)
            return IntelligenceResult(
                text: Self.formatted(number: value),
                citations: request.citations,
                providerName: providerName,
                isGenerative: false
            )
        case .translate:
            throw IntelligenceProviderError.generativeModelRequired
        }
    }

    private static func summary(of text: String) -> String {
        let sentences = sentences(in: text)
        guard sentences.count > 3 else { return sentences.joined(separator: " ") }
        let frequencies = wordFrequencies(in: text)
        let ranked = sentences.enumerated().map { index, sentence -> (Int, String, Double) in
            let words = tokens(in: sentence)
            let score = words.reduce(0.0) { $0 + Double(frequencies[$1, default: 0]) } / Double(max(1, words.count))
            return (index, sentence, score)
        }
        let selected = ranked.sorted { $0.2 > $1.2 }.prefix(min(5, max(2, sentences.count / 4)))
        return selected.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
    }

    private static func quiz(
        from text: String,
        count: Int,
        usesTraditionalChinese: Bool
    ) -> [QuizItem] {
        let candidates = sentences(in: text).filter { $0.count >= 18 }
        return candidates.prefix(count).map { sentence in
            let tokens = sentence.split { $0.isWhitespace || $0.isPunctuation }.map(String.init)
            let answer = tokens.max(by: { $0.count < $1.count }) ?? String(sentence.prefix(12))
            let question = sentence.replacingOccurrences(of: answer, with: "＿＿＿", options: [.caseInsensitive])
            let prompt = usesTraditionalChinese ? "請填空：" : "Fill in the blank: "
            return QuizItem(question: "\(prompt)\(question)", answer: answer)
        }
    }

    private static func paragraphs(in text: String) -> [String] {
        var paragraphs: [String] = []
        var current: [Substring] = []

        for line in text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current.joined(separator: "\n"))
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty {
            paragraphs.append(current.joined(separator: "\n"))
        }
        return paragraphs
    }

    private static func sentences(in text: String) -> [String] {
        let terminators: Set<Character> = ["。", "！", "？", ".", "!", "?", "\n"]
        var sentences: [String] = []
        var current = ""

        for character in text {
            current.append(character)
            if terminators.contains(character) {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { sentences.append(sentence) }
                current.removeAll(keepingCapacity: true)
            }
        }
        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty { sentences.append(remainder) }
        return sentences
    }

    private static func tokens(in text: String) -> [String] {
        text.lowercased().split { $0.isWhitespace || $0.isPunctuation }.map(String.init).filter { $0.count > 1 }
    }

    private static func wordFrequencies(in text: String) -> [String: Int] {
        tokens(in: text).reduce(into: [:]) { result, token in result[token, default: 0] += 1 }
    }

    private static func bestMatches(for question: String, in text: String, limit: Int) -> [String] {
        let queryUnits = Set(searchUnits(in: question))
        guard !queryUnits.isEmpty else { return [] }
        return sentences(in: text)
            .map { sentence in
                let candidate = Set(searchUnits(in: sentence))
                return (sentence, candidate.intersection(queryUnits).count)
            }
            .filter { $0.1 > 0 }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 { return lhs.0.count < rhs.0.count }
                return lhs.1 > rhs.1
            }
            .prefix(limit)
            .map(\.0)
    }

    private static func searchUnits(in text: String) -> [String] {
        let normalized = String(text.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
        let characters = Array(normalized)
        guard characters.count > 1 else { return normalized.isEmpty ? [] : [normalized] }
        return (0..<(characters.count - 1)).map { String(characters[$0...$0 + 1]) }
    }

    private static func formatted(number: Double) -> String {
        if number.rounded() == number { return String(format: "%.0f", number) }
        return String(format: "%.10g", number)
    }
}
