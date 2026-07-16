import Foundation

enum SyncStateReducer {
    static func snapshot(from operationsByID: [UUID: SyncOperation]) throws -> SyncSnapshot {
        let operations = operationsByID.values.sorted(by: operationPrecedes)
        let grouped = Dictionary(grouping: operations, by: \.entity)
        var entities: [SyncEntitySnapshot] = []
        var conflicts: [ConflictRecord] = []

        for (entityReference, entityOperations) in grouped {
            let tombstones = entityOperations.filter {
                if case .tombstone = $0.mutation { return true }
                return false
            }
            let latestTombstone = tombstones.max(by: operationPrecedes)

            var fieldOperations: [SyncKey: [SyncOperation]] = [:]
            var resolutions: [SyncConflictID: [SyncOperation]] = [:]
            for operation in entityOperations {
                switch operation.mutation {
                case .set(let field, _, _):
                    fieldOperations[field, default: []].append(operation)
                case .resolveConflict(let conflictID, _):
                    resolutions[conflictID, default: []].append(operation)
                case .tombstone:
                    break
                }
            }

            var fields: [SyncResolvedField] = []
            for field in fieldOperations.keys.sorted() {
                guard let fieldHistory = fieldOperations[field]?.sorted(by: operationPrecedes) else {
                    continue
                }
                let revisions = try fieldHistory.map(revision)
                guard let first = revisions.first else { continue }

                let policies = Set(revisions.map(\.policy))
                let values = Set(revisions.map(\.value))
                let hasProtectedValue = policies.contains(.confirmed) || policies.contains(.immutable)
                let conflictKind: SyncConflictKind?
                if policies.count > 1 {
                    conflictKind = .policyMismatch
                } else if hasProtectedValue, values.count > 1 {
                    conflictKind = .competingProtectedValues
                } else {
                    conflictKind = nil
                }

                if let conflictKind {
                    let conflictID = try makeConflictID(
                        entity: entityReference,
                        field: field,
                        contenders: revisions
                    )
                    let applicableResolutions = (resolutions[conflictID] ?? [])
                        .filter { operation in
                            guard case .resolveConflict(_, let chosenID) = operation.mutation else {
                                return false
                            }
                            return revisions.contains { $0.operationID == chosenID }
                        }
                        .sorted(by: operationPrecedes)
                    let latestResolution = applicableResolutions.last
                    let chosenID: UUID?
                    if let latestResolution,
                       case .resolveConflict(_, let selectedID) = latestResolution.mutation {
                        chosenID = selectedID
                    } else {
                        chosenID = nil
                    }
                    let winner = chosenID.flatMap { selected in
                        revisions.first { $0.operationID == selected }
                    } ?? protectedDefaultWinner(revisions)

                    fields.append(.init(
                        field: field,
                        value: winner.value,
                        winningOperationID: winner.operationID,
                        policy: winner.policy,
                        history: revisions
                    ))
                    conflicts.append(.init(
                        id: conflictID,
                        entity: entityReference,
                        field: field,
                        kind: conflictKind,
                        status: chosenID == nil ? .unresolved : .resolved,
                        contenders: revisions,
                        chosenOperationID: chosenID,
                        resolutionOperationID: latestResolution?.id
                    ))
                } else {
                    // All-flexible fields use deterministic HLC LWW. Protected fields
                    // with repeated identical values also choose the latest provenance.
                    let winner = revisions.last ?? first
                    fields.append(.init(
                        field: field,
                        value: winner.value,
                        winningOperationID: winner.operationID,
                        policy: winner.policy,
                        history: revisions
                    ))
                }
            }

            entities.append(.init(
                reference: entityReference,
                isDeleted: latestTombstone != nil,
                tombstoneOperationID: latestTombstone?.id,
                fields: fields.sorted { $0.field < $1.field }
            ))
        }

        return SyncSnapshot(entities: entities, conflicts: conflicts)
    }

    static func operationPrecedes(_ lhs: SyncOperation, _ rhs: SyncOperation) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.deviceID != rhs.deviceID { return lhs.deviceID < rhs.deviceID }
        if lhs.deviceSequence != rhs.deviceSequence {
            return lhs.deviceSequence < rhs.deviceSequence
        }
        return lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }

    private static func revision(_ operation: SyncOperation) throws -> SyncFieldRevision {
        guard case .set(_, let value, let policy) = operation.mutation else {
            throw NextStepSyncError.malformedDocument("A non-field operation entered field history.")
        }
        return .init(
            operationID: operation.id,
            timestamp: operation.timestamp,
            value: value,
            policy: policy
        )
    }

    private static func protectedDefaultWinner(_ revisions: [SyncFieldRevision]) -> SyncFieldRevision {
        let immutable = revisions.filter { $0.policy == .immutable }
        if let first = immutable.first { return first }
        let confirmed = revisions.filter { $0.policy == .confirmed }
        if let first = confirmed.first { return first }
        return revisions[0]
    }

    private static func makeConflictID(
        entity: SyncEntityReference,
        field: SyncKey,
        contenders: [SyncFieldRevision]
    ) throws -> SyncConflictID {
        struct Seed: Encodable {
            let entityKind: String
            let entityID: String
            let field: String
            let operationIDs: [String]
        }
        let seed = Seed(
            entityKind: entity.kind.rawValue,
            entityID: entity.id.uuidString.lowercased(),
            field: field.rawValue,
            operationIDs: contenders
                .map { $0.operationID.uuidString.lowercased() }
                .sorted()
        )
        return SyncConflictID(SyncDigest(data: try SyncCodec.encode(seed)))
    }
}
