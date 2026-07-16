import Foundation
import CoreFoundation

public enum AcademicWorkspaceFileSlot: String, Equatable, Sendable {
    case primary
    case backup
}

public enum AcademicWorkspaceStoreOperation: String, Equatable, Sendable {
    case load
    case recover
    case commit
    case reset
    case finishRootTransition
}

/// Public store failures contain no backing URL, path, or underlying error text.
public enum AcademicWorkspaceStoreError: Error, Equatable, Sendable {
    case notLoaded
    case tokenConflict
    case backingConflict
    case backingUnavailable(operation: AcademicWorkspaceStoreOperation)
    case unsupportedSchema(slot: AcademicWorkspaceFileSlot, version: Int)
    case unrecoverableWorkspace
    case encodedWorkspaceTooLarge
    case invalidBackingSnapshot
    case workspaceRevisionOverflow
    case storageRevisionOverflow
    case operationInProgress
    case operationSuperseded
    case rootTransitionInProgress
    case invalidRootTransitionToken
}

extension AcademicWorkspaceStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notLoaded:
            "Load the academic workspace before mutating it."
        case .tokenConflict:
            "The academic workspace token is no longer current."
        case .backingConflict:
            "The academic workspace files changed before the operation completed."
        case let .backingUnavailable(operation):
            "The academic workspace backing is unavailable during \(operation.rawValue)."
        case let .unsupportedSchema(slot, version):
            "The \(slot.rawValue) academic workspace uses unsupported schema version \(version)."
        case .unrecoverableWorkspace:
            "Neither academic workspace copy can be recovered."
        case .encodedWorkspaceTooLarge:
            "The academic workspace exceeds its fixed encoded-size limit."
        case .invalidBackingSnapshot:
            "The academic workspace backing returned an invalid atomic snapshot."
        case .workspaceRevisionOverflow:
            "The academic workspace revision cannot advance."
        case .storageRevisionOverflow:
            "The academic workspace storage revision cannot advance."
        case .operationInProgress:
            "Another academic workspace operation is in progress."
        case .operationSuperseded:
            "The academic workspace operation was superseded."
        case .rootTransitionInProgress:
            "An academic workspace root transition is in progress."
        case .invalidRootTransitionToken:
            "The academic workspace root-transition token is invalid."
        }
    }
}

/// CAS token spanning both the decoded workspace and its atomic file snapshot.
public struct AcademicWorkspaceVersionToken: Equatable, Sendable {
    public let workspaceRevision: Int64
    public let storageRevision: Int64
    public let storageRootFingerprint: AcademicWorkspaceStorageFingerprint
    public let storageStateFingerprint: AcademicWorkspaceStateFingerprint
    fileprivate let rootTransitionIdentity: UUID

    fileprivate init(
        workspaceRevision: Int64,
        storageVersion: AcademicWorkspaceStorageVersion,
        rootTransitionIdentity: UUID
    ) {
        self.workspaceRevision = workspaceRevision
        storageRevision = storageVersion.storageRevision
        storageRootFingerprint = storageVersion.rootFingerprint
        storageStateFingerprint = storageVersion.stateFingerprint
        self.rootTransitionIdentity = rootTransitionIdentity
    }
}

public struct AcademicWorkspaceStoreSnapshot: Equatable, Sendable {
    public let workspace: AcademicWorkspace
    public let token: AcademicWorkspaceVersionToken

    fileprivate init(
        workspace: AcademicWorkspace,
        storageVersion: AcademicWorkspaceStorageVersion,
        rootTransitionIdentity: UUID
    ) {
        self.workspace = workspace
        token = AcademicWorkspaceVersionToken(
            workspaceRevision: workspace.revision,
            storageVersion: storageVersion,
            rootTransitionIdentity: rootTransitionIdentity
        )
    }
}

/// Single-writer, compare-and-swap store for the V1 academic sidecar.
public actor NextStepAcademicStore: AcademicWorkspaceRootTransitionGating {
    private struct CachedState {
        let snapshot: AcademicWorkspaceStoreSnapshot
        let storageVersion: AcademicWorkspaceStorageVersion
        /// Canonical bytes for the current primary, or nil for an in-memory empty root.
        let canonicalPrimaryData: Data?
    }

    private struct CanonicalWorkspace {
        let workspace: AcademicWorkspace
        let data: Data
    }

    private enum InspectedWorkspace {
        case current(CanonicalWorkspace)
        case unsupported(version: Int)
        case oversized
        case corrupt
    }

    private let backing: any AcademicWorkspaceFileBacking
    private var cachedState: CachedState?
    private var activeOperation = false
    private var operationGeneration: UInt64 = 0
    private var rootTransitionIdentity = UUID()
    private var rootTransitionToken: AcademicWorkspaceRootTransitionToken?

    public init(backing: any AcademicWorkspaceFileBacking) {
        self.backing = backing
    }

    /// Reads the backing's current primary. A corrupt or missing primary is
    /// restored from a valid current-schema backup using backing CAS.
    @discardableResult
    public func load() async throws -> AcademicWorkspaceStoreSnapshot {
        let generation = try beginOperation()
        cachedState = nil
        defer { finishOperation() }
        let fileSnapshot = try await readBacking(operation: .load)
        try requireCurrentOperation(generation)
        let resolved = try await resolve(
            fileSnapshot,
            generation: generation,
            recoveryOperation: .recover
        )
        try requireCurrentOperation(generation)
        cachedState = resolved
        return resolved.snapshot
    }

    /// Returns the last successfully loaded or committed state without I/O.
    public func currentSnapshot() throws -> AcademicWorkspaceStoreSnapshot {
        try requireUsableGate()
        guard !activeOperation else {
            throw AcademicWorkspaceStoreError.operationInProgress
        }
        guard let cachedState else {
            throw AcademicWorkspaceStoreError.notLoaded
        }
        return cachedState.snapshot
    }

    /// Commits validated content. The store, not the caller, advances the
    /// workspace revision by exactly one.
    @discardableResult
    public func commit(
        _ content: AcademicWorkspaceContent,
        expected token: AcademicWorkspaceVersionToken,
        savedAt: Date
    ) async throws -> AcademicWorkspaceStoreSnapshot {
        let current = try requireCachedState(matching: token)
        try AcademicValidation.requireChronology(
            earlier: current.snapshot.workspace.savedAt,
            later: savedAt,
            detail: "An academic workspace commit cannot move savedAt backwards."
        )
        let revision = try nextWorkspaceRevision(after: current.snapshot.workspace.revision)
        let candidate = try AcademicWorkspace(
            revision: revision,
            savedAt: savedAt,
            content: content
        )
        let canonical = try Self.canonicalRepresentation(of: candidate)
        let expectedVersion = current.storageVersion
        _ = try nextStorageRevision(after: expectedVersion.storageRevision)

        let generation = try beginOperation()
        defer { finishOperation() }
        let replacement = try await replaceBacking(
            primaryData: canonical.data,
            backupData: current.canonicalPrimaryData,
            expected: expectedVersion,
            operation: .commit
        )
        try requireCurrentOperation(generation)
        try validateReplacement(
            replacement,
            expected: expectedVersion,
            primaryData: canonical.data,
            backupData: current.canonicalPrimaryData
        )
        let next = CachedState(
            snapshot: AcademicWorkspaceStoreSnapshot(
                workspace: canonical.workspace,
                storageVersion: replacement.version,
                rootTransitionIdentity: rootTransitionIdentity
            ),
            storageVersion: replacement.version,
            canonicalPrimaryData: canonical.data
        )
        cachedState = next
        return next.snapshot
    }

    /// Convenience mutation that derives new content synchronously from the
    /// token's current workspace before performing the same CAS commit.
    @discardableResult
    public func mutate(
        expected token: AcademicWorkspaceVersionToken,
        savedAt: Date,
        _ transform: @Sendable (AcademicWorkspace) throws -> AcademicWorkspaceContent
    ) async throws -> AcademicWorkspaceStoreSnapshot {
        let current = try requireCachedState(matching: token)
        let content = try transform(current.snapshot.workspace)
        return try await commit(content, expected: token, savedAt: savedAt)
    }

    /// Atomically removes both primary and backup through the backing.
    @discardableResult
    public func reset(
        expected token: AcademicWorkspaceVersionToken
    ) async throws -> AcademicWorkspaceStoreSnapshot {
        let current = try requireCachedState(matching: token)
        let expectedVersion = current.storageVersion
        _ = try nextStorageRevision(after: expectedVersion.storageRevision)
        let generation = try beginOperation()
        defer { finishOperation() }

        let replacement: AcademicWorkspaceFileSnapshot
        do {
            replacement = try await backing.reset(expected: expectedVersion)
        } catch {
            try requireCurrentOperation(generation)
            throw mapBackingError(error, operation: .reset)
        }
        try requireCurrentOperation(generation)
        try validateReplacement(
            replacement,
            expected: expectedVersion,
            primaryData: nil,
            backupData: nil
        )
        let next = CachedState(
            snapshot: AcademicWorkspaceStoreSnapshot(
                workspace: .empty,
                storageVersion: replacement.version,
                rootTransitionIdentity: rootTransitionIdentity
            ),
            storageVersion: replacement.version,
            canonicalPrimaryData: nil
        )
        cachedState = next
        return next.snapshot
    }

    /// Closes the gate before the Notes layer changes its storage root.
    public func prepareForRootTransition() async throws
        -> AcademicWorkspaceRootTransitionToken {
        guard !activeOperation else {
            throw AcademicWorkspaceStoreError.operationInProgress
        }
        guard rootTransitionToken == nil else {
            throw AcademicWorkspaceStoreError.rootTransitionInProgress
        }
        advanceOperationGeneration()
        rootTransitionIdentity = UUID()
        cachedState = nil
        let token = AcademicWorkspaceRootTransitionToken()
        rootTransitionToken = token
        return token
    }

    /// Reopens the gate only after the new root has been loaded and validated.
    /// A failure leaves the gate closed so the coordinator can correct the root
    /// and retry with the same token.
    @discardableResult
    public func finishRootTransition(
        _ token: AcademicWorkspaceRootTransitionToken
    ) async throws -> AcademicWorkspaceStoreSnapshot {
        guard rootTransitionToken == token else {
            throw AcademicWorkspaceStoreError.invalidRootTransitionToken
        }
        guard !activeOperation else {
            throw AcademicWorkspaceStoreError.operationInProgress
        }
        let generation = beginTransitionOperation()
        defer { finishOperation() }

        let fileSnapshot = try await readBacking(operation: .finishRootTransition)
        try requireCurrentOperation(generation)
        let resolved = try await resolve(
            fileSnapshot,
            generation: generation,
            recoveryOperation: .finishRootTransition
        )
        try requireCurrentOperation(generation)
        cachedState = resolved
        rootTransitionToken = nil
        return resolved.snapshot
    }

    private func resolve(
        _ fileSnapshot: AcademicWorkspaceFileSnapshot,
        generation: UInt64,
        recoveryOperation: AcademicWorkspaceStoreOperation
    ) async throws -> CachedState {
        let primaryWasMissing: Bool
        switch fileSnapshot.primary {
        case let .data(primaryData):
            primaryWasMissing = false
            switch Self.inspect(primaryData) {
            case let .current(canonical):
                switch fileSnapshot.backup {
                case let .data(backupData):
                    switch Self.inspect(backupData) {
                    case let .unsupported(version):
                        throw AcademicWorkspaceStoreError.unsupportedSchema(
                            slot: .backup,
                            version: version
                        )
                    case let .current(backup):
                        guard (backup.workspace.revision < canonical.workspace.revision
                                && backup.workspace.savedAt <= canonical.workspace.savedAt)
                                || (backup.workspace.revision == canonical.workspace.revision
                                    && backup.data == canonical.data) else {
                            throw AcademicWorkspaceStoreError.invalidBackingSnapshot
                        }
                    case .corrupt:
                        break
                    case .oversized:
                        throw AcademicWorkspaceStoreError.encodedWorkspaceTooLarge
                    }
                case .oversized:
                    throw AcademicWorkspaceStoreError.encodedWorkspaceTooLarge
                case .missing:
                    break
                }
                return cached(
                    canonical,
                    storageVersion: fileSnapshot.version
                )
            case let .unsupported(version):
                throw AcademicWorkspaceStoreError.unsupportedSchema(
                    slot: .primary,
                    version: version
                )
            case .oversized:
                throw AcademicWorkspaceStoreError.encodedWorkspaceTooLarge
            case .corrupt:
                break
            }
        case .oversized:
            throw AcademicWorkspaceStoreError.encodedWorkspaceTooLarge
        case .missing:
            primaryWasMissing = true
        }

        let backupData: Data
        switch fileSnapshot.backup {
        case let .data(data):
            backupData = data
        case .oversized:
            throw AcademicWorkspaceStoreError.encodedWorkspaceTooLarge
        case .missing:
            if primaryWasMissing {
                return CachedState(
                    snapshot: AcademicWorkspaceStoreSnapshot(
                        workspace: .empty,
                        storageVersion: fileSnapshot.version,
                        rootTransitionIdentity: rootTransitionIdentity
                    ),
                    storageVersion: fileSnapshot.version,
                    canonicalPrimaryData: nil
                )
            }
            throw AcademicWorkspaceStoreError.unrecoverableWorkspace
        }

        let backup: CanonicalWorkspace
        switch Self.inspect(backupData) {
        case let .current(canonical):
            backup = canonical
        case let .unsupported(version):
            throw AcademicWorkspaceStoreError.unsupportedSchema(
                slot: .backup,
                version: version
            )
        case .oversized:
            throw AcademicWorkspaceStoreError.encodedWorkspaceTooLarge
        case .corrupt:
            throw AcademicWorkspaceStoreError.unrecoverableWorkspace
        }

        _ = try nextStorageRevision(after: fileSnapshot.version.storageRevision)
        let restored = try await replaceBacking(
            primaryData: backup.data,
            backupData: backup.data,
            expected: fileSnapshot.version,
            operation: recoveryOperation
        )
        try requireCurrentOperation(generation)
        try validateReplacement(
            restored,
            expected: fileSnapshot.version,
            primaryData: backup.data,
            backupData: backup.data
        )
        return cached(backup, storageVersion: restored.version)
    }

    private func cached(
        _ canonical: CanonicalWorkspace,
        storageVersion: AcademicWorkspaceStorageVersion
    ) -> CachedState {
        CachedState(
            snapshot: AcademicWorkspaceStoreSnapshot(
                workspace: canonical.workspace,
                storageVersion: storageVersion,
                rootTransitionIdentity: rootTransitionIdentity
            ),
            storageVersion: storageVersion,
            canonicalPrimaryData: canonical.data
        )
    }

    private func requireCachedState(
        matching token: AcademicWorkspaceVersionToken
    ) throws -> CachedState {
        try requireUsableGate()
        guard !activeOperation else {
            throw AcademicWorkspaceStoreError.operationInProgress
        }
        guard let cachedState else {
            throw AcademicWorkspaceStoreError.notLoaded
        }
        guard cachedState.snapshot.token == token else {
            throw AcademicWorkspaceStoreError.tokenConflict
        }
        return cachedState
    }

    private func requireUsableGate() throws {
        guard rootTransitionToken == nil else {
            throw AcademicWorkspaceStoreError.rootTransitionInProgress
        }
    }

    private func beginOperation() throws -> UInt64 {
        try requireUsableGate()
        guard !activeOperation else {
            throw AcademicWorkspaceStoreError.operationInProgress
        }
        activeOperation = true
        return advanceOperationGeneration()
    }

    private func beginTransitionOperation() -> UInt64 {
        activeOperation = true
        return advanceOperationGeneration()
    }

    @discardableResult
    private func advanceOperationGeneration() -> UInt64 {
        operationGeneration &+= 1
        return operationGeneration
    }

    private func requireCurrentOperation(_ generation: UInt64) throws {
        guard activeOperation, operationGeneration == generation else {
            throw AcademicWorkspaceStoreError.operationSuperseded
        }
    }

    private func finishOperation() {
        activeOperation = false
    }

    private func readBacking(
        operation: AcademicWorkspaceStoreOperation
    ) async throws -> AcademicWorkspaceFileSnapshot {
        do {
            return try await backing.read()
        } catch {
            throw mapBackingError(error, operation: operation)
        }
    }

    private func replaceBacking(
        primaryData: Data?,
        backupData: Data?,
        expected: AcademicWorkspaceStorageVersion,
        operation: AcademicWorkspaceStoreOperation
    ) async throws -> AcademicWorkspaceFileSnapshot {
        do {
            return try await backing.replace(
                primaryData: primaryData,
                backupData: backupData,
                expected: expected
            )
        } catch {
            throw mapBackingError(error, operation: operation)
        }
    }

    private func mapBackingError(
        _ error: Error,
        operation: AcademicWorkspaceStoreOperation
    ) -> AcademicWorkspaceStoreError {
        guard let backingError = error as? AcademicWorkspaceFileBackingError else {
            return .backingUnavailable(operation: operation)
        }
        switch backingError {
        case .conflict:
            return .backingConflict
        case .storageRevisionOverflow:
            return .storageRevisionOverflow
        case .unavailable, .invalidStorageRevision:
            return .backingUnavailable(operation: operation)
        }
    }

    private func validateReplacement(
        _ replacement: AcademicWorkspaceFileSnapshot,
        expected: AcademicWorkspaceStorageVersion,
        primaryData: Data?,
        backupData: Data?
    ) throws {
        let nextRevision = try nextStorageRevision(after: expected.storageRevision)
        guard replacement.version.rootFingerprint == expected.rootFingerprint,
              replacement.version.stateFingerprint != expected.stateFingerprint,
              replacement.version.storageRevision == nextRevision,
              replacement.primary == .bounded(primaryData),
              replacement.backup == .bounded(backupData) else {
            throw AcademicWorkspaceStoreError.invalidBackingSnapshot
        }
    }

    private func nextWorkspaceRevision(after revision: Int64) throws -> Int64 {
        let (next, overflow) = revision.addingReportingOverflow(1)
        guard revision >= 0, !overflow else {
            throw AcademicWorkspaceStoreError.workspaceRevisionOverflow
        }
        return next
    }

    private func nextStorageRevision(after revision: Int64) throws -> Int64 {
        let (next, overflow) = revision.addingReportingOverflow(1)
        guard revision >= 0, !overflow else {
            throw AcademicWorkspaceStoreError.storageRevisionOverflow
        }
        return next
    }

    private static func inspect(_ data: Data) -> InspectedWorkspace {
        guard data.count <= AcademicWorkspaceLimits.maximumEncodedBytes else {
            return .oversized
        }
        do {
            let object = try JSONSerialization.jsonObject(with: data)
            try AcademicWorkspaceSchemaPreflight.validate(object)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            let workspace = try decoder.decode(AcademicWorkspace.self, from: data)
            return .current(try canonicalRepresentation(of: workspace))
        } catch let error as AcademicWorkspaceSchemaPreflight.Error {
            switch error {
            case let .unsupported(version):
                return .unsupported(version: version)
            case .corrupt:
                return .corrupt
            }
        } catch AcademicWorkspaceStoreError.encodedWorkspaceTooLarge {
            return .oversized
        } catch {
            return .corrupt
        }
    }

    private static func canonicalRepresentation(
        of workspace: AcademicWorkspace
    ) throws -> CanonicalWorkspace {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try AcademicWorkspaceEncodingPreflight.fits(
            workspace,
            encoder: encoder
        ) else {
            throw AcademicWorkspaceStoreError.encodedWorkspaceTooLarge
        }
        let data = try encoder.encode(workspace)
        guard data.count <= AcademicWorkspaceLimits.maximumEncodedBytes else {
            throw AcademicWorkspaceStoreError.encodedWorkspaceTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let canonicalWorkspace = try decoder.decode(AcademicWorkspace.self, from: data)
        return CanonicalWorkspace(workspace: canonicalWorkspace, data: data)
    }
}

enum AcademicWorkspaceEncodingPreflight {
    static func fits(
        _ workspace: AcademicWorkspace,
        encoder: JSONEncoder
    ) throws -> Bool {
        guard textualUTF8Fits(workspace) else { return false }
        let emptyEnvelope = try AcademicWorkspace(
            revision: workspace.revision,
            savedAt: workspace.savedAt,
            content: .empty
        )
        var predictedBytes = try encoder.encode(emptyEnvelope).count
        guard predictedBytes <= AcademicWorkspaceLimits.maximumEncodedBytes else {
            return false
        }
        guard try addCollection(workspace.courses, encoder: encoder, to: &predictedBytes),
              try addCollection(workspace.sessions, encoder: encoder, to: &predictedBytes),
              try addCollection(
                  workspace.sessionNoteLinks,
                  encoder: encoder,
                  to: &predictedBytes
              ),
              try addCollection(workspace.captures, encoder: encoder, to: &predictedBytes),
              try addCollection(workspace.wrapUps, encoder: encoder, to: &predictedBytes) else {
            return false
        }
        return true
    }

    private static func addCollection<Element: Encodable>(
        _ elements: [Element],
        encoder: JSONEncoder,
        to total: inout Int
    ) throws -> Bool {
        if elements.count > 1,
           !add(elements.count - 1, to: &total) {
            return false
        }
        for element in elements {
            let encoded = try encoder.encode(element)
            guard add(encoded.count, to: &total) else { return false }
        }
        return true
    }

    private static func add(_ amount: Int, to total: inout Int) -> Bool {
        let (sum, overflow) = total.addingReportingOverflow(amount)
        guard !overflow, sum <= AcademicWorkspaceLimits.maximumEncodedBytes else {
            return false
        }
        total = sum
        return true
    }

    /// Prevents one deeply nested entity from allocating an oversized temporary
    /// before the element-by-element exact-size pass can reject the workspace.
    private static func textualUTF8Fits(_ workspace: AcademicWorkspace) -> Bool {
        var total = 0
        func include(_ value: String?) -> Bool {
            guard let value else { return true }
            let (sum, overflow) = total.addingReportingOverflow(value.utf8.count)
            guard !overflow, sum <= AcademicWorkspaceLimits.maximumEncodedBytes else {
                return false
            }
            total = sum
            return true
        }

        for course in workspace.courses {
            guard include(course.code),
                  include(course.name),
                  include(course.term),
                  include(course.instructor),
                  include(course.timeZoneIdentifier) else {
                return false
            }
            for rule in course.scheduleRules where !include(rule.timeZoneIdentifier) {
                return false
            }
        }
        for session in workspace.sessions {
            guard include(session.topic),
                  include(session.scheduledInterval?.timeZoneIdentifier) else {
                return false
            }
        }
        for capture in workspace.captures {
            guard include(capture.rawText),
                  include(capture.draftFields.title),
                  include(capture.draftFields.details),
                  include(capture.draftFields.scope) else {
                return false
            }
            if case let .noteAnchor(anchor) = capture.source,
               !include(anchor.textHash) {
                return false
            }
            if !include(capture.resolution?.reason) { return false }
            for audit in capture.auditTrail where !include(audit.reason) {
                return false
            }
        }
        for wrapUp in workspace.wrapUps where !include(wrapUp.oneLineSummary) {
            return false
        }
        return true
    }
}

private enum AcademicWorkspaceSchemaPreflight {
    enum Error: Swift.Error {
        case unsupported(version: Int)
        case corrupt
    }

    static func validate(_ object: Any) throws {
        guard let root = object as? [String: Any] else {
            throw Error.corrupt
        }
        try requireCurrentSchema(in: root, required: true)

        let courses = try objectArray(
            root["courses"],
            maximum: AcademicWorkspaceLimits.maximumCourses
        )
        for course in courses {
            try requireCurrentSchema(in: course, required: true)
            for rule in try objectArray(
                course["scheduleRules"],
                maximum: AcademicDomainLimits.maximumScheduleRulesPerCourse
            ) {
                try requireCurrentSchema(in: rule, required: true)
            }
        }

        for session in try objectArray(
            root["sessions"],
            maximum: AcademicWorkspaceLimits.maximumSessions
        ) {
            try requireCurrentSchema(in: session, required: true)
        }
        for link in try objectArray(
            root["sessionNoteLinks"],
            maximum: AcademicWorkspaceLimits.maximumSessionNoteLinks
        ) {
            try requireCurrentSchema(in: link, required: true)
        }

        let captures = try objectArray(
            root["captures"],
            maximum: AcademicWorkspaceLimits.maximumCaptures
        )
        for capture in captures {
            try requireCurrentSchema(in: capture, required: true)
            if let source = capture["source"] as? [String: Any],
               let anchorValue = source["anchor"] {
                guard let anchor = anchorValue as? [String: Any] else {
                    throw Error.corrupt
                }
                try requireCurrentSchema(in: anchor, required: true)
            }
            if let resolutionValue = capture["resolution"],
               !(resolutionValue is NSNull) {
                guard let resolution = resolutionValue as? [String: Any] else {
                    throw Error.corrupt
                }
                try requireCurrentSchema(in: resolution, required: true)
                for reference in try objectArray(
                    resolution["resolvedEntityRefs"],
                    maximum: CaptureResolution.maximumResolvedEntityReferences
                ) {
                    try requireCurrentSchema(in: reference, required: true)
                }
            }
            for audit in try objectArray(
                capture["auditTrail"],
                maximum: AcademicDomainLimits.maximumAuditEntriesPerCapture
            ) {
                try requireCurrentSchema(in: audit, required: true)
            }
        }

        for wrapUp in try objectArray(
            root["wrapUps"],
            maximum: AcademicWorkspaceLimits.maximumWrapUps
        ) {
            try requireCurrentSchema(in: wrapUp, required: true)
        }
    }

    private static func objectArray(
        _ value: Any?,
        maximum: Int
    ) throws -> [[String: Any]] {
        guard let array = value as? [Any], array.count <= maximum else {
            throw Error.corrupt
        }
        var result: [[String: Any]] = []
        result.reserveCapacity(array.count)
        for element in array {
            guard let object = element as? [String: Any] else {
                throw Error.corrupt
            }
            result.append(object)
        }
        return result
    }

    private static func requireCurrentSchema(
        in object: [String: Any],
        required: Bool
    ) throws {
        guard let rawVersion = object["schemaVersion"] else {
            if required { throw Error.corrupt }
            return
        }
        guard let number = rawVersion as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw Error.corrupt
        }
        let value = number.doubleValue
        guard value.isFinite,
              value.rounded(.towardZero) == value else {
            throw Error.corrupt
        }
        let version: Int
        if value >= Double(Int32.min), value <= Double(Int32.max) {
            version = Int(value)
        } else if let exact = Int(number.stringValue) {
            version = exact
        } else {
            throw Error.unsupported(version: value.sign == .minus ? Int.min : Int.max)
        }
        guard version == AcademicWorkspace.currentSchemaVersion else {
            throw Error.unsupported(version: version)
        }
    }
}
