import Foundation
import NextStepDomain
import NextStepGrounding
import NextStepPlanning
import Observation

public enum NextStepBetaLoadState: Equatable, Sendable {
    case loading
    case ready
    case failed(String)
}

@MainActor
@Observable
public final class NextStepBetaModel {
    public private(set) var loadState: NextStepBetaLoadState = .loading
    public private(set) var isWorking = false
    public private(set) var isReplanning = false
    public private(set) var errorMessage: String?
    public private(set) var statusMessage: String?
    public private(set) var syncState: NextStepBetaSyncState = .notConfigured
    public private(set) var quizSubmissionStates: [QuizID: NextStepBetaQuizSubmissionState] = [:]
    private(set) var sourceFactReviewPreview: NextStepBetaSourceFactReviewPreview?

    private(set) var archive: NextStepBetaArchive?
    private let store: NextStepBetaStore
    private let importer: NextStepBetaSourceImporter
    private let syncCoordinator: NextStepBetaSyncCoordinator
    private let now: @Sendable () -> Date
    private let bootstrapArchive: NextStepBetaArchive?

    public convenience init() {
        do {
            let rootURL = try NextStepBetaStore.defaultRootURL()
            self.init(
                store: NextStepBetaStore(rootURL: rootURL),
                importer: NextStepBetaSourceImporter(applicationSupportRoot: rootURL),
                now: { Date() }
            )
        } catch {
            let fallback = FileManager.default.temporaryDirectory
                .appendingPathComponent("NextStep-Beta-Fallback", isDirectory: true)
            self.init(
                store: NextStepBetaStore(rootURL: fallback),
                importer: NextStepBetaSourceImporter(applicationSupportRoot: fallback),
                now: { Date() }
            )
            loadState = .failed(error.localizedDescription)
        }
    }

    init(
        store: NextStepBetaStore,
        importer: NextStepBetaSourceImporter,
        now: @escaping @Sendable () -> Date,
        bootstrapArchive: NextStepBetaArchive? = nil,
        initialLoadFailure: String? = nil
    ) {
        self.store = store
        self.importer = importer
        self.syncCoordinator = NextStepBetaSyncCoordinator(
            applicationSupportRoot: store.rootURL,
            store: store
        )
        self.now = now
        self.bootstrapArchive = bootstrapArchive
        if let initialLoadFailure {
            loadState = .failed(initialLoadFailure)
        } else {
            Task { await load() }
        }
    }

    var workspace: NextStepWorkspaceSnapshot? { archive?.workspace }
    var hasGoal: Bool { archive?.workspace.ultimateGoals.isEmpty == false }
    var sourceDocuments: [SourceDocument] { archive?.workspace.sourceDocuments ?? [] }
    var pendingSourceFacts: [NextStepBetaPendingSourceFact] {
        archive?.grounding.pendingFacts ?? []
    }
    var currentDecision: PlanningDecision? { archive?.currentDecision }
    var currentDate: Date { now() }

    var todayPlan: TodayPlan? {
        guard let archive, let decision = archive.currentDecision,
              let today = try? LocalDay(
                  date: now(),
                  timeZoneIdentifier: archive.workspace.userProfile.timeZoneIdentifier
              ) else {
            return nil
        }
        return try? TodayProjector().project(
            day: today,
            decision: decision,
            snapshot: archive.workspace
        )
    }

    func load() async {
        loadState = .loading
        do {
            if let loaded = try await store.load() {
                var refreshed = loaded
                let timestamp = now()
                let today = try LocalDay(
                    date: timestamp,
                    timeZoneIdentifier: loaded.workspace.userProfile.timeZoneIdentifier
                )
                let hasActiveAction = loaded.workspace.dailyActions.contains {
                    $0.status != .completed && $0.status != .cancelled
                }
                if hasActiveAction,
                   loaded.currentDecision?.horizonStart != today {
                    refreshed = try NextStepBetaPlanningBridge().replan(
                        archive: loaded,
                        trigger: .manualRequest,
                        now: timestamp
                    )
                    try await store.save(refreshed)
                }
                archive = refreshed
            } else {
                let created: NextStepBetaArchive
                if let bootstrapArchive {
                    created = bootstrapArchive
                } else {
                    created = try NextStepBetaWorkspaceFactory().makeEmpty(now: now())
                }
                try await store.save(created)
                archive = created
            }
            loadState = .ready
            if let archive {
                syncState = .restoring
                do {
                    if let result = try await syncCoordinator.restoreIfConfigured(
                        localArchive: archive,
                        now: now()
                    ) {
                        applySyncResult(result)
                    } else {
                        syncState = .notConfigured
                    }
                } catch {
                    syncState = NextStepBetaSyncFailureClassifier.state(
                        for: error,
                        lastSyncedAt: syncState.lastSyncedAt
                    )
                }
            }
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    @discardableResult
    func createGoal(title: String, deadline: Date, dailyMinutes: Int) async -> Bool {
        guard var archive else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let day = try LocalDay(
                date: deadline,
                timeZoneIdentifier: archive.workspace.userProfile.timeZoneIdentifier
            )
            archive = try NextStepBetaGoalBuilder().addGoal(
                title: title,
                deadline: day,
                dailyMinutes: dailyMinutes,
                to: archive,
                now: now()
            )
            try await persist(archive)
            statusMessage = "目標已建立。下一步請匯入 PDF 或圖片來源。"
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func importSources(_ urls: [URL]) async {
        guard var archive else { return }
        guard archive.workspace.ultimateGoals.isEmpty == false else {
            errorMessage = NextStepBetaArchiveError.goalMissing.localizedDescription
            return
        }
        isWorking = true
        defer { isWorking = false }
        var notices: [String] = []
        do {
            for url in urls {
                let timestamp = now()
                let imported = try await importer.importSource(
                    from: url,
                    now: timestamp,
                    deviceID: archive.deviceID
                )
                archive = try NextStepBetaPackageBuilder().addImportedSource(
                    imported,
                    to: archive,
                    now: timestamp
                )
                if imported.exactExtract != nil {
                    archive = try NextStepBetaPlanningBridge().replan(
                        archive: archive,
                        trigger: .sourceImported,
                        now: timestamp
                    )
                }
                if let notice = imported.extractionNotice { notices.append(notice) }
                try await store.save(archive)
            }
            self.archive = archive
            await synchronizeLocalArchiveIfConfigured()
            errorMessage = nil
            statusMessage = notices.isEmpty
                ? "來源已安全保存，Today 已由確定性規劃引擎更新。"
                : notices.joined(separator: "\n")
        } catch {
            self.archive = archive
            errorMessage = error.localizedDescription
        }
    }

    func startAction(_ actionID: DailyActionID) async {
        guard var archive else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            archive.workspace = try ExecutionService().startAction(
                actionID,
                in: archive.workspace,
                at: now()
            )
            try await persist(archive)
            statusMessage = "任務已開始；原始來源與完成標準都保持可見。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func submitQuiz(
        for actionID: DailyActionID,
        selections: [QuizItemID: Set<UUID>]
    ) async {
        guard isWorking == false else { return }
        guard var archive,
              let action = archive.workspace.dailyActions.first(where: {
                  $0.metadata.id == actionID
              }),
              action.status == .inProgress,
              let package = action.packageID.flatMap({ packageID in
                  archive.workspace.guidedPackages.first { $0.metadata.id == packageID }
              }),
              let quiz = package.quiz else {
            errorMessage = NextStepBetaQuizError.actionNotInProgress.localizedDescription
            return
        }
        guard hasPassingQuizEvidence(for: actionID) == false else {
            statusMessage = "來源核對測驗已通過，不會重複建立完成證據。"
            errorMessage = nil
            return
        }

        quizSubmissionStates[quiz.metadata.id] = .submitting
        isWorking = true
        defer { isWorking = false }
        do {
            let timestamp = now()
            let summary = try NextStepBetaQuizGrader().grade(
                package: package,
                selections: selections,
                attemptID: UUID(),
                now: timestamp,
                deviceID: archive.deviceID
            )
            archive.workspace.userResponses.append(contentsOf: summary.responses)

            if summary.passed {
                let criterionIDs = action.completionCriteria
                    .filter { $0.kind == .quizScore && $0.requiresEvidence }
                    .map(\.id)
                guard criterionIDs.isEmpty == false else {
                    throw NextStepBetaQuizError.passingAttemptRequired
                }
                let quizResult = try QuizEvaluator().evaluate(
                    quiz: quiz,
                    packageID: package.metadata.id,
                    packageVersion: package.version,
                    responses: summary.responses,
                    scoredAt: timestamp
                )
                guard quizResult.scoreFraction == summary.scoreFraction else {
                    throw NextStepBetaQuizError.passingAttemptRequired
                }
                let evidence = try CompletionEvidence(
                    metadata: RecordMetadata(
                        id: CompletionEvidenceID(),
                        createdAt: timestamp,
                        originDeviceID: archive.deviceID,
                        provenance: .deterministicEngine
                    ),
                    actionID: actionID,
                    packageID: package.metadata.id,
                    packageVersion: package.version,
                    quizResult: quizResult,
                    capturedAt: timestamp,
                    criterionIDs: criterionIDs
                )
                archive.workspace.completionEvidence.append(evidence)
            }

            archive.workspace.revision += 1
            archive.workspace.savedAt = timestamp
            try archive.validate()
            try await persist(archive)
            quizSubmissionStates[quiz.metadata.id] = .result(summary)
            statusMessage = summary.passed
                ? "來源核對測驗已通過，證據已保存。"
                : "尚未通過；請依每題回饋回到原始來源核對後再試。"
        } catch {
            quizSubmissionStates[quiz.metadata.id] = .idle
            errorMessage = error.localizedDescription
        }
    }

    func completeAction(_ actionID: DailyActionID, evidenceText: String) async {
        guard var archive,
              let action = archive.workspace.dailyActions.first(where: {
                  $0.metadata.id == actionID
              }) else { return }
        let normalizedEvidence = evidenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidencePoints = normalizedEvidence
            .split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        guard evidencePoints.count >= 3 else {
            errorMessage = "請先寫下至少三行從原文直接確認的重點。"
            return
        }
        isWorking = true
        isReplanning = true
        defer {
            isWorking = false
            isReplanning = false
        }
        do {
            let timestamp = now()
            let package = action.packageID.flatMap { packageID in
                archive.workspace.guidedPackages.first { $0.metadata.id == packageID }
            }
            if package?.quiz != nil, hasPassingQuizEvidence(for: actionID) == false {
                throw NextStepBetaQuizError.passingAttemptRequired
            }
            let criteria = action.completionCriteria
                .filter { $0.kind == .userAttestation && $0.requiresEvidence }
                .map(\.id)
            let evidence = try CompletionEvidence(
                metadata: RecordMetadata(
                    id: CompletionEvidenceID(),
                    createdAt: timestamp,
                    originDeviceID: archive.deviceID,
                    provenance: .user
                ),
                actionID: actionID,
                packageID: package?.metadata.id,
                packageVersion: package?.version,
                kind: .userAttestation,
                value: evidencePoints.joined(separator: "\n"),
                capturedAt: timestamp,
                criterionIDs: criteria
            )
            archive.workspace = try ExecutionService().completeAction(
                actionID,
                evidence: [evidence],
                in: archive.workspace,
                at: timestamp,
                progressSnapshotID: ProgressSnapshotID(),
                originDeviceID: archive.deviceID,
                currentDecision: archive.currentDecision
            )
            archive = try NextStepBetaPlanningBridge().replan(
                archive: archive,
                trigger: .actionCompleted,
                now: timestamp
            )
            try await persist(archive)
            statusMessage = "完成證據與進度已保存，後續計畫已重新評估。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deferAndReplan(_ actionID: DailyActionID) async {
        guard var archive else { return }
        isWorking = true
        isReplanning = true
        defer {
            isWorking = false
            isReplanning = false
        }
        do {
            let timestamp = now()
            archive.workspace = try ExecutionService().deferAction(
                actionID,
                in: archive.workspace,
                at: timestamp
            )
            let today = try LocalDay(
                date: timestamp,
                timeZoneIdentifier: archive.workspace.userProfile.timeZoneIdentifier
            )
            if let index = archive.workspace.dailyActions.firstIndex(where: {
                $0.metadata.id == actionID
            }) {
                archive.workspace.dailyActions[index].earliestDay = try today.adding(days: 1)
            }
            archive = try NextStepBetaPlanningBridge().replan(
                archive: archive,
                trigger: .actionDeferred,
                now: timestamp
            )
            try await persist(archive)
            statusMessage = "任務已交回規劃引擎；硬期限沒有被修改。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func manualReplan() async {
        guard var archive else { return }
        isReplanning = true
        defer { isReplanning = false }
        do {
            archive = try NextStepBetaPlanningBridge().replan(
                archive: archive,
                trigger: .manualRequest,
                now: now()
            )
            try await persist(archive)
            statusMessage = "重新規劃完成；所有使用者確認的硬期限均受保護。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func action(id: DailyActionID) -> DailyAction? {
        archive?.workspace.dailyActions.first { $0.metadata.id == id }
    }

    func package(for action: DailyAction) -> GuidedLearningPackage? {
        action.packageID.flatMap { id in
            archive?.workspace.guidedPackages.first { $0.metadata.id == id }
        }
    }

    func source(for action: DailyAction) -> SourceDocument? {
        guard let id = action.sourceDocumentIDs.first else { return nil }
        return archive?.workspace.sourceDocuments.first { $0.metadata.id == id }
    }

    func completionEvidence(for actionID: DailyActionID) -> [CompletionEvidence] {
        archive?.workspace.completionEvidence.filter { $0.actionID == actionID } ?? []
    }

    func quizSubmissionState(for quizID: QuizID) -> NextStepBetaQuizSubmissionState {
        quizSubmissionStates[quizID] ?? .idle
    }

    func latestQuizAttempt(for actionID: DailyActionID) -> NextStepBetaQuizAttemptSummary? {
        guard let archive,
              let action = archive.workspace.dailyActions.first(where: {
                  $0.metadata.id == actionID
              }),
              let package = action.packageID.flatMap({ packageID in
                  archive.workspace.guidedPackages.first { $0.metadata.id == packageID }
              }),
              let quiz = package.quiz else { return nil }

        let responses = archive.workspace.userResponses.filter {
            $0.quizID == quiz.metadata.id && $0.packageVersion == package.version
        }
        let expectedItemIDs = Set(quiz.items.map(\.id))
        let attempts = Dictionary(grouping: responses, by: \.attemptID).compactMap {
            attemptID, attemptResponses -> NextStepBetaQuizAttemptSummary? in
            let responseItemIDs = Set(attemptResponses.map(\.quizItemID))
            guard responseItemIDs == expectedItemIDs,
                  attemptResponses.count == quiz.items.count else { return nil }
            let correctCount = attemptResponses.filter { $0.scoreFraction == 1 }.count
            let score = Double(correctCount) / Double(quiz.items.count)
            return NextStepBetaQuizAttemptSummary(
                attemptID: attemptID,
                quizID: quiz.metadata.id,
                packageVersion: package.version,
                correctCount: correctCount,
                totalCount: quiz.items.count,
                scoreFraction: score,
                passed: score >= quiz.passingFraction,
                responses: attemptResponses
            )
        }
        return attempts.max { lhs, rhs in
            let lhsDate = lhs.responses.map(\.attemptedAt).max() ?? .distantPast
            let rhsDate = rhs.responses.map(\.attemptedAt).max() ?? .distantPast
            if lhsDate != rhsDate { return lhsDate < rhsDate }
            return lhs.attemptID.uuidString < rhs.attemptID.uuidString
        }
    }

    func latestQuizSelections(for actionID: DailyActionID) -> [QuizItemID: Set<UUID>] {
        guard let attempt = latestQuizAttempt(for: actionID) else { return [:] }
        return Dictionary(uniqueKeysWithValues: attempt.responses.map {
            ($0.quizItemID, Set($0.selectedOptionIDs))
        })
    }

    func hasPassingQuizEvidence(for actionID: DailyActionID) -> Bool {
        guard let archive,
              let action = archive.workspace.dailyActions.first(where: {
                  $0.metadata.id == actionID
              }),
              let package = action.packageID.flatMap({ packageID in
                  archive.workspace.guidedPackages.first { $0.metadata.id == packageID }
              }),
              let quiz = package.quiz else { return true }
        let quizCriterionIDs = Set(action.completionCriteria
            .filter { $0.kind == .quizScore && $0.requiresEvidence }
            .map(\.id))
        guard quizCriterionIDs.isEmpty == false else { return false }

        return archive.workspace.completionEvidence.contains { evidence in
            guard evidence.actionID == actionID,
                  evidence.packageID == package.metadata.id,
                  evidence.packageVersion == package.version,
                  evidence.kind == .quizResult,
                  quizCriterionIDs.isSubset(of: Set(evidence.criterionIDs)),
                  let result = evidence.quizResult,
                  result.quizID == quiz.metadata.id,
                  result.packageID == package.metadata.id,
                  result.packageVersion == package.version,
                  result.scoreFraction >= quiz.passingFraction,
                  Set(result.evidenceLinkIDs) == Set(quiz.items.flatMap(\.evidenceLinkIDs)) else {
                return false
            }

            let responseIDs = Set(result.responseIDs)
            let responses = archive.workspace.userResponses.filter {
                responseIDs.contains($0.metadata.id)
                    && $0.attemptID == result.attemptID
                    && $0.quizID == result.quizID
                    && $0.packageVersion == result.packageVersion
            }
            guard responses.count == quiz.items.count,
                  Set(responses.map(\.metadata.id)) == responseIDs,
                  Set(responses.map(\.quizItemID)) == Set(quiz.items.map(\.id)) else {
                return false
            }
            let correctCount = responses.filter { response in
                guard let item = quiz.items.first(where: { $0.id == response.quizItemID }) else {
                    return false
                }
                return Set(response.selectedOptionIDs) == Set(item.correctOptionIDs)
            }.count
            let score = Double(correctCount) / Double(quiz.items.count)
            return abs(score - result.scoreFraction) < 0.000_001
        }
    }

    func sourceURL(for document: SourceDocument) async -> URL? {
        guard let relativePath = document.localRelativePath else { return nil }
        return try? await store.resolveStoredSource(relativePath: relativePath)
    }

    func source(for pendingFact: NextStepBetaPendingSourceFact) -> SourceDocument? {
        archive?.workspace.sourceDocuments.first {
            $0.metadata.id == pendingFact.batch.parseResult.sourceDocumentID
        }
    }

    func pendingSourceFact(id: UUID) -> NextStepBetaPendingSourceFact? {
        archive?.grounding.pendingFact(id: id)
    }

    func prepareSourceFactReview(_ candidateID: UUID) async {
        guard let archive,
              let pending = archive.grounding.pendingFact(id: candidateID),
              let source = archive.workspace.sourceDocuments.first(where: {
                  $0.metadata.id == pending.batch.parseResult.sourceDocumentID
              }) else {
            errorMessage = NextStepBetaGroundingError.candidateNotFound.localizedDescription
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.verifyStoredSource(source)
            guard let currentArchive = self.archive else {
                throw NextStepBetaGroundingError.candidateNotFound
            }
            sourceFactReviewPreview = try NextStepBetaSourceFactReviewCoordinator().makePreview(
                candidateID: candidateID,
                archive: currentArchive,
                now: now()
            )
            errorMessage = nil
            statusMessage = "已產生核對預覽；期限與計畫尚未變更。"
        } catch {
            sourceFactReviewPreview = nil
            errorMessage = error.localizedDescription
        }
    }

    func acceptSourceFactReview(_ preview: NextStepBetaSourceFactReviewPreview) async {
        guard let archive else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            guard let source = archive.workspace.sourceDocuments.first(where: {
                $0.metadata.id == preview.sourceDocumentID
            }) else {
                throw NextStepBetaGroundingError.sourceUnavailable
            }
            try await store.verifyStoredSource(source)
            guard let currentArchive = self.archive else {
                throw NextStepBetaGroundingError.stalePreview
            }
            let updated = try NextStepBetaSourceFactReviewCoordinator().accept(
                preview,
                archive: currentArchive,
                now: now()
            )
            try await persist(updated)
            sourceFactReviewPreview = nil
            errorMessage = nil
            statusMessage = preview.diff.kind == .deadline
                ? "已確認來源期限並原子套用重新規劃。"
                : "已保存使用者確認且可回溯原文的日期事實。"
        } catch let groundingError as NextStepBetaGroundingError
            where groundingError == .stalePreview {
            do {
                guard let currentArchive = self.archive else {
                    throw NextStepBetaGroundingError.stalePreview
                }
                guard let currentSource = currentArchive.workspace.sourceDocuments.first(where: {
                    $0.metadata.id == preview.sourceDocumentID
                }) else {
                    throw NextStepBetaGroundingError.sourceUnavailable
                }
                try await store.verifyStoredSource(currentSource)
                sourceFactReviewPreview = try NextStepBetaSourceFactReviewCoordinator()
                    .makePreview(
                        candidateID: preview.id,
                        archive: currentArchive,
                        now: now()
                    )
                errorMessage = nil
                statusMessage = "核對預覽已過期，已依目前資料重新產生；請再次確認差異。"
            } catch {
                sourceFactReviewPreview = nil
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func rejectSourceFact(_ candidateID: UUID, reason: String) async {
        guard let archive else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let updated = try NextStepBetaSourceFactReviewCoordinator().reject(
                candidateID: candidateID,
                reason: reason,
                archive: archive,
                now: now()
            )
            try await persist(updated)
            if sourceFactReviewPreview?.id == candidateID {
                sourceFactReviewPreview = nil
            }
            errorMessage = nil
            statusMessage = "候選內容已拒絕；目標期限與計畫未變更。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearMessages() {
        errorMessage = nil
        statusMessage = nil
    }

    func connectSyncFolder(_ folderURL: URL) async {
        guard let archive else { return }
        syncState = .connecting
        do {
            let result = try await syncCoordinator.connectSelectedFolder(
                folderURL,
                localArchive: archive,
                now: now()
            )
            applySyncResult(result)
            statusMessage = result.state.review == nil
                ? "同步資料夾已連線；請在 iPhone 與 iPad 各自選取同一個 iCloud Drive 資料夾。"
                : "偵測到受保護資料差異，請先確認要採用哪一份。"
        } catch {
            syncState = NextStepBetaSyncFailureClassifier.state(
                for: error,
                lastSyncedAt: syncState.lastSyncedAt
            )
        }
    }

    func synchronizeNow() async {
        guard let archive else { return }
        let previousDate = syncState.lastSyncedAt
        syncState = .syncing(lastSyncedAt: previousDate)
        do {
            if let result = try await syncCoordinator.synchronizeNow(
                localArchive: archive,
                now: now()
            ) {
                applySyncResult(result)
                statusMessage = result.state.review == nil
                    ? "跨裝置同步完成。"
                    : "同步已暫停：受保護資料需要你的確認。"
            } else {
                syncState = .notConfigured
            }
        } catch {
            syncState = NextStepBetaSyncFailureClassifier.state(
                for: error,
                lastSyncedAt: previousDate
            )
        }
    }

    func resolveSyncReview(useSyncedArchive: Bool) async {
        let previousDate = syncState.lastSyncedAt
        syncState = .syncing(lastSyncedAt: previousDate)
        do {
            let result = try await syncCoordinator.resolvePendingReview(
                useSyncedArchive: useSyncedArchive,
                now: now()
            )
            applySyncResult(result)
            statusMessage = useSyncedArchive
                ? "已採用同步資料，並保存到這台裝置。"
                : "已保留這台裝置的資料，選擇結果已同步。"
        } catch {
            syncState = NextStepBetaSyncFailureClassifier.state(
                for: error,
                lastSyncedAt: previousDate
            )
        }
    }

    func disconnectSyncFolder() async {
        do {
            try await syncCoordinator.disconnect()
            syncState = .notConfigured
            statusMessage = "已停止使用同步資料夾；本機資料沒有被刪除。"
        } catch {
            syncState = .failed(error.localizedDescription)
        }
    }

    func reportSyncPickerError(_ error: Error) {
        syncState = .failed(error.localizedDescription)
    }

    private func persist(_ updatedArchive: NextStepBetaArchive) async throws {
        try await store.save(updatedArchive)
        archive = updatedArchive
        errorMessage = nil
        await synchronizeLocalArchiveIfConfigured()
    }

    private func synchronizeLocalArchiveIfConfigured() async {
        guard let archive else { return }
        switch syncState {
        case .ready, .offline, .syncing:
            break
        case .notConfigured, .restoring, .connecting, .reviewRequired, .failed:
            return
        }
        let previousDate = syncState.lastSyncedAt
        syncState = .syncing(lastSyncedAt: previousDate)
        do {
            if let result = try await syncCoordinator.publishLocalAndSynchronize(
                archive,
                now: now()
            ) {
                applySyncResult(result)
            }
        } catch {
            // The local atomic save has already succeeded. A transport failure
            // leaves immutable operations in the durable pending queue for retry.
            syncState = NextStepBetaSyncFailureClassifier.state(
                for: error,
                lastSyncedAt: previousDate
            )
        }
    }

    private func applySyncResult(_ result: NextStepBetaSyncCoordinatorResult) {
        archive = result.archive
        quizSubmissionStates.removeAll()
        syncState = result.state
    }
}

private extension NextStepBetaSyncState {
    var review: NextStepBetaSyncReview? {
        if case .reviewRequired(let value) = self { return value }
        return nil
    }
}
