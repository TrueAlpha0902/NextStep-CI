import CryptoKit
import Foundation
import NextStepDomain
import NextStepGrounding
import NextStepPlanning

enum NextStepBetaArchiveError: Error, LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case goalAlreadyExists
    case goalMissing
    case sourceHasNoExtractableText
    case invalidDeadline
    case invalidDailyMinutes

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "不支援的 Beta 資料版本：\(version)。"
        case .goalAlreadyExists:
            "第一版 Beta 目前只建立一條完整目標路徑。"
        case .goalMissing:
            "請先建立最終目標，再匯入學習來源。"
        case .sourceHasNoExtractableText:
            "來源已保存，但第一頁找不到可讀文字，因此尚未建立引導任務。"
        case .invalidDeadline:
            "期限不得早於今天。"
        case .invalidDailyMinutes:
            "每日可用時間需介於 5 到 240 分鐘。"
        }
    }
}

struct NextStepBetaArchive: Codable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var deviceID: DeviceID
    var workspace: NextStepWorkspaceSnapshot
    var currentDecisionID: PlanningDecisionID?
    var grounding: NextStepBetaGroundingState

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case deviceID
        case workspace
        case currentDecisionID
        case grounding
    }

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        deviceID: DeviceID,
        workspace: NextStepWorkspaceSnapshot,
        currentDecisionID: PlanningDecisionID? = nil,
        grounding: NextStepBetaGroundingState = .empty
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw NextStepBetaArchiveError.unsupportedSchema(schemaVersion)
        }
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
        self.workspace = workspace
        self.currentDecisionID = currentDecisionID
        self.grounding = grounding
        try workspace.validateRelationships()
        try grounding.validate(in: workspace)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let migratedGrounding: NextStepBetaGroundingState
        switch decodedVersion {
        case 1:
            migratedGrounding = .empty
        case Self.currentSchemaVersion:
            migratedGrounding = try container.decode(
                NextStepBetaGroundingState.self,
                forKey: .grounding
            )
        default:
            throw NextStepBetaArchiveError.unsupportedSchema(decodedVersion)
        }
        try self.init(
            schemaVersion: Self.currentSchemaVersion,
            deviceID: container.decode(DeviceID.self, forKey: .deviceID),
            workspace: container.decode(NextStepWorkspaceSnapshot.self, forKey: .workspace),
            currentDecisionID: container.decodeIfPresent(
                PlanningDecisionID.self,
                forKey: .currentDecisionID
            ),
            grounding: migratedGrounding
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(workspace, forKey: .workspace)
        try container.encodeIfPresent(currentDecisionID, forKey: .currentDecisionID)
        try container.encode(grounding, forKey: .grounding)
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw NextStepBetaArchiveError.unsupportedSchema(schemaVersion)
        }
        try workspace.validateRelationships()
        try grounding.validate(in: workspace)
    }

    var currentDecision: PlanningDecision? {
        if let currentDecisionID,
           let matching = workspace.planningDecisions.last(where: {
               $0.metadata.id == currentDecisionID
           }) {
            return matching
        }
        return workspace.planningDecisions.last
    }
}

struct NextStepBetaWorkspaceFactory {
    func makeEmpty(
        now: Date,
        deviceID: DeviceID = DeviceID(),
        timeZoneIdentifier: String = TimeZone.current.identifier
    ) throws -> NextStepBetaArchive {
        let availability = try (1...7).map {
            try WeeklyAvailability(isoWeekday: $0, availableMinutes: 35)
        }
        let profile = try UserProfile(
            metadata: RecordMetadata(
                id: UserProfileID(),
                createdAt: now,
                originDeviceID: deviceID,
                provenance: .user
            ),
            localeIdentifier: "zh-Hant-TW",
            timeZoneIdentifier: timeZoneIdentifier,
            weeklyAvailability: availability,
            preferredSessionMinutes: 35,
            maximumDailyMinutes: 35,
            onboardingState: .goalsNeeded
        )
        let workspace = try NextStepWorkspaceSnapshot(savedAt: now, userProfile: profile)
        return try NextStepBetaArchive(deviceID: deviceID, workspace: workspace)
    }
}

struct NextStepBetaGoalBuilder {
    func addGoal(
        title rawTitle: String,
        deadline: LocalDay,
        dailyMinutes: Int,
        to archive: NextStepBetaArchive,
        now: Date
    ) throws -> NextStepBetaArchive {
        guard archive.workspace.ultimateGoals.isEmpty else {
            throw NextStepBetaArchiveError.goalAlreadyExists
        }
        guard (5...240).contains(dailyMinutes) else {
            throw NextStepBetaArchiveError.invalidDailyMinutes
        }
        let today = try LocalDay(
            date: now,
            timeZoneIdentifier: archive.workspace.userProfile.timeZoneIdentifier
        )
        guard deadline >= today else { throw NextStepBetaArchiveError.invalidDeadline }

        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let immutableDeadline = try FactValue(
            value: deadline,
            authority: .userConfirmed,
            mutability: .immutable,
            confirmedAt: now
        )
        let ultimateID = UltimateGoalID()
        let goalID = GoalID()
        let milestoneID = MilestoneID()
        let criterion = try CompletionCriterion(
            kind: .userAttestation,
            title: "已閱讀原始來源並留下可檢查的學習紀錄",
            requiresEvidence: true,
            requiresUserConfirmation: true
        )

        let ultimate = try UltimateGoal(
            metadata: RecordMetadata(
                id: ultimateID,
                createdAt: now,
                originDeviceID: archive.deviceID,
                provenance: .user
            ),
            title: title,
            definitionOfDone: "在硬期限前完成：\(title)",
            targetDay: immutableDeadline,
            status: .active,
            priority: .high
        )
        let goal = try Goal(
            metadata: RecordMetadata(
                id: goalID,
                createdAt: now,
                originDeviceID: archive.deviceID,
                provenance: .user
            ),
            ultimateGoalID: ultimateID,
            title: "建立第一個可驗證成果",
            outcome: "完成一個由原始來源支撐的學習成果",
            targetDay: immutableDeadline,
            status: .active,
            priority: .high
        )
        let milestone = try Milestone(
            metadata: RecordMetadata(
                id: milestoneID,
                createdAt: now,
                originDeviceID: archive.deviceID,
                provenance: .user
            ),
            goalID: goalID,
            title: "完成第一個引導式學習任務",
            outcome: "閱讀來源、核對原文並留下完成證據",
            targetDay: immutableDeadline,
            completionCriteria: [criterion]
        )

        var result = archive
        result.workspace.userProfile.weeklyAvailability = try (1...7).map {
            try WeeklyAvailability(isoWeekday: $0, availableMinutes: dailyMinutes)
        }
        result.workspace.userProfile.preferredSessionMinutes = dailyMinutes
        result.workspace.userProfile.maximumDailyMinutes = dailyMinutes
        result.workspace.userProfile.onboardingState = .ready
        result.workspace.ultimateGoals.append(ultimate)
        result.workspace.goals.append(goal)
        result.workspace.milestones.append(milestone)
        result.workspace.revision += 1
        result.workspace.savedAt = now
        try result.validate()
        return result
    }
}

struct NextStepBetaImportedSource: Sendable {
    let document: SourceDocument
    let exactExtract: String?
    let pageIndex: Int
    let usedVisionOCR: Bool
    let extractionNotice: String?
}

struct NextStepBetaSourceRecordBuilder {
    func makeDocument(
        id: SourceDocumentID,
        displayTitle: String,
        fileExtension: String,
        relativePath: String,
        contentSHA256: String,
        now: Date,
        deviceID: DeviceID,
        parserVersion: String?
    ) throws -> SourceDocument {
        let normalizedExtension = fileExtension.lowercased()
        let type: SourceDocumentType = normalizedExtension == "pdf" ? .pdf : .image
        return try SourceDocument(
            metadata: RecordMetadata(
                id: id,
                createdAt: now,
                originDeviceID: deviceID,
                provenance: Provenance(kind: .importedSource, sourceDocumentIDs: [id])
            ),
            type: type,
            displayTitle: displayTitle,
            contentSHA256: contentSHA256,
            rightsState: .unknown,
            accessState: .userProvidedFullText,
            localRelativePath: relativePath,
            parserVersion: parserVersion,
            accessedAt: now,
            verificationState: .contentHashVerified
        )
    }
}

struct NextStepBetaPackageBuilder {
    func addImportedSource(
        _ imported: NextStepBetaImportedSource,
        to archive: NextStepBetaArchive,
        now: Date
    ) throws -> NextStepBetaArchive {
        guard let ultimate = archive.workspace.ultimateGoals.first,
              let goal = archive.workspace.goals.first,
              let milestone = archive.workspace.milestones.first else {
            throw NextStepBetaArchiveError.goalMissing
        }

        var result = archive
        result.workspace.sourceDocuments.append(imported.document)

        guard let rawExtract = imported.exactExtract?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), rawExtract.isEmpty == false else {
            result.workspace.revision += 1
            result.workspace.savedAt = now
            try result.validate()
            return result
        }

        let exactExtract = String(rawExtract.prefix(4_000))
        let actionID = DailyActionID()
        let packageID = GuidedLearningPackageID()
        let anchorID = SourceAnchorID()
        let evidenceID = EvidenceLinkID()
        let output = try RequiredOutput(
            kind: .note,
            title: "寫下三個從原文直接確認的重點",
            destinationHint: "NextStep 完成證據",
            validationKind: .userConfirmation
        )
        let attestationCriterion = try CompletionCriterion(
            kind: .userAttestation,
            title: "已開啟原始檔、核對節錄並留下三個重點",
            requiresEvidence: true,
            requiresUserConfirmation: true
        )
        let locator: SourceLocator
        switch imported.document.type {
        case .image, .scan:
            locator = .image(
                pageIndex: imported.pageIndex,
                normalizedRegion: try NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                textQuote: exactExtract
            )
        default:
            locator = .pdf(
                pageIndex: imported.pageIndex,
                normalizedRects: [],
                textQuote: exactExtract
            )
        }
        let anchor = try SourceAnchor(
            metadata: RecordMetadata(
                id: anchorID,
                createdAt: now,
                originDeviceID: archive.deviceID,
                provenance: Provenance(
                    kind: .deterministicEngine,
                    sourceDocumentIDs: [imported.document.metadata.id]
                )
            ),
            sourceDocumentID: imported.document.metadata.id,
            locator: locator,
            quotedTextSHA256: SHA256.hash(data: Data(exactExtract.utf8))
                .map { String(format: "%02x", $0) }
                .joined(),
            sourceRevision: 0,
            capturedAt: now,
            verificationState: .contentHashVerified
        )
        let groundingBatch = try NextStepBetaGroundingBatchBuilder().makeBatch(
            imported: imported,
            exactExtract: exactExtract,
            anchor: anchor,
            target: NextStepBetaGroundingTarget(
                ultimateGoalID: ultimate.metadata.id,
                goalID: goal.metadata.id,
                milestoneID: milestone.metadata.id
            ),
            now: now
        )
        let evidence = try EvidenceLink(
            metadata: RecordMetadata(
                id: evidenceID,
                createdAt: now,
                originDeviceID: archive.deviceID,
                provenance: .deterministicEngine
            ),
            anchorID: anchorID,
            relation: .supports,
            subjectType: "DailyAction",
            subjectID: actionID.rawValue,
            verificationMethod: "Exact on-device extract with SHA-256 source anchor",
            verifiedBy: .deterministicEngine
        )
        let objective = try LearningObjective(
            statement: "閱讀並核對來源第一頁的原文節錄",
            successDescription: "能指出三個確實出現在原文中的重點"
        )
        let groundedQuiz = try NextStepBetaGroundedQuizBuilder().makeQuiz(
            exactExtract: exactExtract,
            usedVisionOCR: imported.usedVisionOCR,
            document: imported.document,
            anchor: anchor,
            objective: objective,
            originDeviceID: archive.deviceID,
            now: now
        )
        let quizCriterion = try groundedQuiz.map { quizBuild in
            try CompletionCriterion(
                kind: .quizScore,
                title: "通過來源核對測驗（全部答對）",
                threshold: quizBuild.quiz.passingFraction,
                requiresEvidence: true,
                requiresUserConfirmation: false
            )
        }
        let completionCriteria = [attestationCriterion] + [quizCriterion].compactMap { $0 }
        let reading = try SourceReading(
            sourceDocumentID: imported.document.metadata.id,
            anchorIDs: [anchorID],
            isRequired: true,
            rationale: "這是使用者匯入的原始來源；任務內容只引用此節錄。",
            accessState: .userProvidedFullText
        )
        let point = try GroundedPoint(text: exactExtract, evidenceLinkIDs: [evidenceID])
        let deadline = milestone.targetDay ?? goal.targetDay ?? ultimate.targetDay
        let today = try LocalDay(
            date: now,
            timeZoneIdentifier: result.workspace.userProfile.timeZoneIdentifier
        )
        let whyToday = "來源已準備完成；今天先核對第一頁原文，建立通往「\(milestone.title)」的第一個可驗證成果。"
        let action = try DailyAction(
            metadata: RecordMetadata(
                id: actionID,
                createdAt: now,
                originDeviceID: archive.deviceID,
                provenance: .deterministicEngine
            ),
            milestoneID: milestone.metadata.id,
            relatedGoalIDs: [goal.metadata.id],
            title: "核對「\(imported.document.displayTitle)」第一頁並寫下三個重點",
            whyToday: whyToday,
            estimatedMinutes: result.workspace.userProfile.preferredSessionMinutes,
            difficulty: .introductory,
            priority: .high,
            earliestDay: today,
            deadline: deadline,
            flexibility: .movable,
            reasonCodes: [.sourcePrepared, .weeklyOutcomeRequired],
            requiredOutput: output,
            completionCriteria: completionCriteria,
            packageID: packageID,
            sourceDocumentIDs: [imported.document.metadata.id],
            status: .ready
        )
        let package = try GuidedLearningPackage(
            metadata: RecordMetadata(
                id: packageID,
                createdAt: now,
                originDeviceID: archive.deviceID,
                provenance: Provenance(
                    kind: .deterministicEngine,
                    sourceDocumentIDs: [imported.document.metadata.id]
                )
            ),
            version: 1,
            dailyActionID: actionID,
            ultimateGoalID: ultimate.metadata.id,
            goalID: goal.metadata.id,
            milestoneID: milestone.metadata.id,
            title: action.title,
            whyToday: whyToday,
            estimatedMinutes: action.estimatedMinutes,
            difficulty: action.difficulty,
            learningObjectives: [objective],
            prerequisites: [],
            sourceReadings: [reading],
            summary: "AI 未使用。本頁只呈現從檔案直接擷取的原文節錄；請開啟原始來源核對。",
            highlightIDs: [],
            corePoints: [point],
            definitions: [],
            applications: [],
            limitationsAndRisks: [],
            knowledgeConceptIDs: [],
            guidedQuestions: [],
            quiz: groundedQuiz?.quiz,
            requiredOutput: output,
            completionCriteria: completionCriteria,
            nextStepTitle: "完成後由確定性規劃引擎重新安排下一步",
            generatedBy: .deterministicEngine,
            generatedAt: now
        )

        result.workspace.sourceAnchors.append(anchor)
        result.workspace.evidenceLinks.append(evidence)
        result.workspace.evidenceLinks.append(contentsOf: groundedQuiz?.evidenceLinks ?? [])
        result.workspace.dailyActions.append(action)
        result.workspace.guidedPackages.append(package)
        result.grounding.batches.append(groundingBatch)
        result.workspace.revision += 1
        result.workspace.savedAt = now
        try result.validate()
        return result
    }
}

struct NextStepBetaPlanningBridge {
    func replan(
        archive: NextStepBetaArchive,
        trigger: ReplanTrigger,
        now: Date
    ) throws -> NextStepBetaArchive {
        let today = try LocalDay(
            date: now,
            timeZoneIdentifier: archive.workspace.userProfile.timeZoneIdentifier
        )
        let horizonEnd = try today.adding(days: 30)
        let input = try PlanningInput(
            snapshot: archive.workspace,
            horizonStart: today,
            horizonEnd: horizonEnd,
            createdAt: now
        )
        let proposal = try PlanningEngine().replan(
            input,
            previous: archive.currentDecision,
            trigger: trigger,
            originDeviceID: archive.deviceID
        )
        var result = archive
        result.workspace = try ExecutionService().acceptReplan(
            proposal,
            in: result.workspace,
            eventID: ReplanEventID(),
            originDeviceID: result.deviceID,
            at: now
        )
        result.currentDecisionID = proposal.proposedDecision.metadata.id
        try result.validate()
        return result
    }
}
