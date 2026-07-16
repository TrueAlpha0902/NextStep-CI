import CryptoKit
import Foundation
import NextStepDomain
import NextStepPlanning

enum NextStepBetaQuizError: Error, LocalizedError, Equatable {
    case ungroundedExtract
    case unsupportedQuestionType
    case actionNotInProgress
    case incompleteAnswers
    case unknownQuestion
    case unknownOption
    case invalidSelection
    case passingAttemptRequired

    var errorDescription: String? {
        switch self {
        case .ungroundedExtract:
            "來源節錄尚未通過可回溯驗證，因此不建立測驗。"
        case .unsupportedQuestionType:
            "這個測驗包含首版尚未支援的題型。"
        case .actionNotInProgress:
            "請先開始任務，再提交來源核對測驗。"
        case .incompleteAnswers:
            "請先回答所有來源核對題。"
        case .unknownQuestion:
            "測驗題目已更新，請重新開啟任務。"
        case .unknownOption:
            "測驗選項已更新，請重新選擇答案。"
        case .invalidSelection:
            "單選題只能選擇一個答案。"
        case .passingAttemptRequired:
            "請先通過來源核對測驗，再建立最終完成證據。"
        }
    }
}

struct NextStepBetaGroundedQuizBuild: Sendable {
    let quiz: Quiz
    let evidenceLinks: [EvidenceLink]
}

struct NextStepBetaGroundedQuizBuilder {
    private static let maximumExcerptCount = 3
    private static let maximumExcerptCharacters = 240

    func makeQuiz(
        exactExtract: String,
        usedVisionOCR: Bool,
        document: SourceDocument,
        anchor: SourceAnchor,
        objective: LearningObjective,
        originDeviceID: DeviceID,
        now: Date
    ) throws -> NextStepBetaGroundedQuizBuild? {
        // Content hashes make native PDF text reproducible. Vision OCR still
        // needs a user-confirmation state before it can be called grounded.
        guard usedVisionOCR == false else { return nil }

        let normalizedExtract = exactExtract.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedExtract.isEmpty == false,
              document.verificationState == .contentHashVerified,
              anchor.verificationState == .contentHashVerified,
              anchor.sourceDocumentID == document.metadata.id,
              anchor.locator.betaTextQuote == normalizedExtract,
              anchor.quotedTextSHA256 == Self.sha256(normalizedExtract) else {
            throw NextStepBetaQuizError.ungroundedExtract
        }

        let excerpts = Self.groundedExcerpts(from: normalizedExtract)
        guard let firstExcerpt = excerpts.first else {
            throw NextStepBetaQuizError.ungroundedExtract
        }

        let quizID = QuizID()
        var items: [QuizItem] = []
        var links: [EvidenceLink] = []

        if excerpts.count == 1 {
            let itemID = QuizItemID()
            let correct = try QuizOption(text: firstExcerpt)
            let unavailable = try QuizOption(text: "這個來源沒有保存任何可核對文字。")
            let link = try makeEvidenceLink(
                itemID: itemID,
                anchorID: anchor.metadata.id,
                documentID: document.metadata.id,
                originDeviceID: originDeviceID,
                now: now
            )
            let item = try QuizItem(
                id: itemID,
                kind: .multipleChoice,
                prompt: "下列哪個選項是目前保存的原文片段？",
                options: [correct, unavailable],
                correctOptionIDs: [correct.id],
                answerExplanation: "正確答案逐字出現在已保存的來源節錄中，可由原始檔與來源錨點核對。",
                objectiveID: objective.id,
                evidenceLinkIDs: [link.metadata.id]
            )
            items.append(item)
            links.append(link)
        } else {
            for (index, excerpt) in excerpts.enumerated() {
                let itemID = QuizItemID()
                let options = try excerpts.map { try QuizOption(text: $0) }
                let link = try makeEvidenceLink(
                    itemID: itemID,
                    anchorID: anchor.metadata.id,
                    documentID: document.metadata.id,
                    originDeviceID: originDeviceID,
                    now: now
                )
                let item = try QuizItem(
                    id: itemID,
                    kind: .multipleChoice,
                    prompt: "保存節錄的第 \(index + 1) 個原文片段是哪一個？",
                    options: options,
                    correctOptionIDs: [options[index].id],
                    answerExplanation: "答案是保存節錄中的第 \(index + 1) 個原文片段，可由原始檔與來源錨點核對。",
                    objectiveID: objective.id,
                    evidenceLinkIDs: [link.metadata.id]
                )
                items.append(item)
                links.append(link)
            }
        }

        let quiz = try Quiz(
            metadata: RecordMetadata(
                id: quizID,
                createdAt: now,
                originDeviceID: originDeviceID,
                provenance: Provenance(
                    kind: .deterministicEngine,
                    sourceDocumentIDs: [document.metadata.id]
                )
            ),
            learningObjectiveIDs: [objective.id],
            items: items,
            passingFraction: 1,
            evaluationPolicy: .groundedDeterministicSingleChoiceV1
        )
        return NextStepBetaGroundedQuizBuild(quiz: quiz, evidenceLinks: links)
    }

    private func makeEvidenceLink(
        itemID: QuizItemID,
        anchorID: SourceAnchorID,
        documentID: SourceDocumentID,
        originDeviceID: DeviceID,
        now: Date
    ) throws -> EvidenceLink {
        try EvidenceLink(
            metadata: RecordMetadata(
                id: EvidenceLinkID(),
                createdAt: now,
                originDeviceID: originDeviceID,
                provenance: Provenance(
                    kind: .deterministicEngine,
                    sourceDocumentIDs: [documentID]
                )
            ),
            anchorID: anchorID,
            relation: .supports,
            subjectType: "QuizItem",
            subjectID: itemID.rawValue,
            verificationMethod: "Exact native extract with SHA-256 source anchor",
            verifiedBy: .deterministicEngine
        )
    }

    static func groundedExcerpts(from exactExtract: String) -> [String] {
        let normalized = exactExtract
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates = normalized
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        if candidates.count == 1, let only = candidates.first {
            let sentenceCandidates = splitSentences(only)
            if sentenceCandidates.count > 1 { candidates = sentenceCandidates }
        }

        var seen: Set<String> = []
        var result: [String] = []
        for candidate in candidates {
            let excerpt = String(candidate.prefix(maximumExcerptCharacters))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard excerpt.isEmpty == false, seen.insert(excerpt).inserted else { continue }
            result.append(excerpt)
            if result.count == maximumExcerptCount { break }
        }
        return result
    }

    private static func splitSentences(_ value: String) -> [String] {
        let terminators = CharacterSet(charactersIn: "。！？.!?")
        var result: [String] = []
        var current = ""
        for scalar in value.unicodeScalars {
            current.unicodeScalars.append(scalar)
            if terminators.contains(scalar) {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if sentence.isEmpty == false { result.append(sentence) }
                current = ""
            }
        }
        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.isEmpty == false { result.append(remainder) }
        return result
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

public struct NextStepBetaQuizAttemptSummary: Equatable, Sendable {
    let attemptID: UUID
    let quizID: QuizID
    let packageVersion: Int
    let correctCount: Int
    let totalCount: Int
    let scoreFraction: Double
    let passed: Bool
    let responses: [UserResponse]
}

public enum NextStepBetaQuizSubmissionState: Equatable, Sendable {
    case idle
    case submitting
    case result(NextStepBetaQuizAttemptSummary)
}

struct NextStepBetaQuizGrader {
    func grade(
        package: GuidedLearningPackage,
        selections: [QuizItemID: Set<UUID>],
        attemptID: UUID,
        now: Date,
        deviceID: DeviceID
    ) throws -> NextStepBetaQuizAttemptSummary {
        guard let quiz = package.quiz else { throw NextStepBetaQuizError.unknownQuestion }
        let itemIDs = Set(quiz.items.map(\.id))
        guard Set(selections.keys) == itemIDs else {
            throw NextStepBetaQuizError.incompleteAnswers
        }

        var responses: [UserResponse] = []
        var correctCount = 0
        for item in quiz.items {
            guard item.kind == .multipleChoice else {
                throw NextStepBetaQuizError.unsupportedQuestionType
            }
            guard let selected = selections[item.id], selected.isEmpty == false else {
                throw NextStepBetaQuizError.incompleteAnswers
            }
            if selected.count != 1 {
                throw NextStepBetaQuizError.invalidSelection
            }
            let optionIDs = Set(item.options.map(\.id))
            guard selected.isSubset(of: optionIDs) else {
                throw NextStepBetaQuizError.unknownOption
            }

            guard let selectedOptionID = selected.first else {
                throw NextStepBetaQuizError.incompleteAnswers
            }
            let response = try QuizEvaluator().makeResponse(
                metadata: RecordMetadata(
                    id: UserResponseID(),
                    createdAt: now,
                    originDeviceID: deviceID,
                    provenance: .user
                ),
                attemptID: attemptID,
                quiz: quiz,
                quizItemID: item.id,
                packageVersion: package.version,
                selectedOptionID: selectedOptionID,
                attemptedAt: now
            )
            if response.scoreFraction == 1 { correctCount += 1 }
            responses.append(response)
        }

        let total = quiz.items.count
        let score = total == 0 ? 0 : Double(correctCount) / Double(total)
        return NextStepBetaQuizAttemptSummary(
            attemptID: attemptID,
            quizID: quiz.metadata.id,
            packageVersion: package.version,
            correctCount: correctCount,
            totalCount: total,
            scoreFraction: score,
            passed: score >= quiz.passingFraction,
            responses: responses
        )
    }
}

private extension SourceLocator {
    var betaTextQuote: String? {
        switch self {
        case .pdf(_, _, let textQuote), .image(_, _, let textQuote):
            textQuote?.trimmingCharacters(in: .whitespacesAndNewlines)
        case .web(_, _, _, _, let textQuote):
            textQuote.trimmingCharacters(in: .whitespacesAndNewlines)
        case .note, .ink, .media:
            nil
        }
    }
}
