import Foundation

/// Hard ceilings for one sealed, immutable Note Replay history. Callers may
/// request stricter read limits, but repository implementations must never
/// raise these caps.
public enum NoteReplayHistoryLimits {
    public static let maximumIndexBytes = 4 * 1_024 * 1_024
    public static let maximumEventCount = 20_000
    public static let maximumEventsPerPage = 10_000
    public static let maximumInkPayloadBytes = 1 * 1_024 * 1_024
    public static let maximumElementPayloadBytes = 4 * 1_024 * 1_024
    public static let maximumElementCountPerSnapshot = 2_000
    public static let maximumUniquePayloadCount = 20_000
    public static let maximumUniquePayloadBytes = 256 * 1_024 * 1_024

    // Descriptive aliases retained for repository and renderer call sites.
    public static let maximumElementsPayloadBytes = maximumElementPayloadBytes
    public static let maximumElementCount = maximumElementCountPerSnapshot
    public static let maximumAggregatePayloadBytes = maximumUniquePayloadBytes

    public static func clampedEventCount(_ requestedCount: Int) -> Int {
        min(max(requestedCount, 0), maximumEventCount)
    }

    public static func clampedInkByteCount(_ requestedByteCount: Int) -> Int {
        min(max(requestedByteCount, 0), maximumInkPayloadBytes)
    }

    public static func clampedElementByteCount(_ requestedByteCount: Int) -> Int {
        min(max(requestedByteCount, 0), maximumElementPayloadBytes)
    }

    public static func clampedElementCount(_ requestedCount: Int) -> Int {
        min(max(requestedCount, 0), maximumElementCountPerSnapshot)
    }
}

public struct NoteReplayEventID: RawRepresentable, Codable, Hashable, Sendable,
    CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) { self.rawValue = rawValue }
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
}

/// A content-addressed snapshot layer. The referenced asset's descriptor and
/// opened file must agree with both fields before the bytes can be returned.
public struct NoteReplayPayloadReference: Codable, Equatable, Hashable, Sendable {
    public var assetID: AssetID
    public var byteCount: Int

    public init(assetID: AssetID, byteCount: Int) {
        self.assetID = assetID
        self.byteCount = byteCount
    }
}

public enum NoteReplaySnapshotEventKind: String, Codable, Equatable, Sendable {
    case baseline
    case change
    case terminal
}

/// One complete page scene at a semantic boundary during a recording. Element
/// snapshots are always present; a nil ink reference represents an empty
/// PencilKit layer.
public struct NoteReplaySnapshotEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: NoteReplayEventID
    public var operationID: OperationID
    public var sequence: Int
    public var timeSeconds: TimeInterval
    public var pageID: PageID
    public var kind: NoteReplaySnapshotEventKind
    public var inkPayload: NoteReplayPayloadReference?
    public var elementsPayload: NoteReplayPayloadReference

    public init(
        id: NoteReplayEventID = NoteReplayEventID(),
        operationID: OperationID = OperationID(),
        sequence: Int,
        timeSeconds: TimeInterval,
        pageID: PageID,
        kind: NoteReplaySnapshotEventKind,
        inkPayload: NoteReplayPayloadReference?,
        elementsPayload: NoteReplayPayloadReference
    ) {
        self.id = id
        self.operationID = operationID
        self.sequence = sequence
        self.timeSeconds = timeSeconds
        self.pageID = pageID
        self.kind = kind
        self.inkPayload = inkPayload
        self.elementsPayload = elementsPayload
    }
}

/// Versioned contents of `audio/<session-id>.replay.json`.
public struct NoteReplayHistoryDocument: Codable, Equatable, Sendable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var audioSessionID: AudioSessionID
    public var sealedAt: Date
    public var events: [NoteReplaySnapshotEvent]

    public var id: AudioSessionID { audioSessionID }
    public var sessionID: AudioSessionID { audioSessionID }

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        audioSessionID: AudioSessionID,
        sealedAt: Date = Date(),
        events: [NoteReplaySnapshotEvent]
    ) {
        self.schemaVersion = schemaVersion
        self.audioSessionID = audioSessionID
        self.sealedAt = sealedAt
        self.events = events
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, audioSessionID, sealedAt, events
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let decodedSchemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        guard decodedSchemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: values,
                debugDescription: "Unsupported Note Replay history schema version \(decodedSchemaVersion)."
            )
        }
        let decodedSealedAt = try values.decode(Date.self, forKey: .sealedAt)
        guard decodedSealedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DecodingError.dataCorruptedError(
                forKey: .sealedAt,
                in: values,
                debugDescription: "A Note Replay history requires a finite seal date."
            )
        }

        var decodedEvents: [NoteReplaySnapshotEvent] = []
        var eventValues = try values.nestedUnkeyedContainer(forKey: .events)
        decodedEvents.reserveCapacity(min(
            eventValues.count ?? 0,
            NoteReplayHistoryLimits.maximumEventCount
        ))
        while !eventValues.isAtEnd {
            guard decodedEvents.count < NoteReplayHistoryLimits.maximumEventCount else {
                throw DecodingError.dataCorruptedError(
                    forKey: .events,
                    in: values,
                    debugDescription: "The Note Replay history contains too many events."
                )
            }
            decodedEvents.append(try eventValues.decode(NoteReplaySnapshotEvent.self))
        }

        schemaVersion = decodedSchemaVersion
        audioSessionID = try values.decode(AudioSessionID.self, forKey: .audioSessionID)
        sealedAt = decodedSealedAt
        events = decodedEvents
    }
}

/// An in-memory payload submitted with a capture bundle. Repository ingest
/// verifies the digest and byte count before adopting or writing the asset.
public struct NoteReplayPayloadBlob: Equatable, Sendable {
    public var reference: NoteReplayPayloadReference
    public var data: Data

    public init(reference: NoteReplayPayloadReference, data: Data) {
        self.reference = reference
        self.data = data
    }
}

/// The sealed index and all unique content-addressed payloads needed to make it
/// durable. Extra or missing blobs are rejected during repository ingest.
public struct NoteReplayCaptureBundle: Equatable, Sendable {
    public var document: NoteReplayHistoryDocument
    public var payloads: [NoteReplayPayloadBlob]

    public var history: NoteReplayHistoryDocument { document }
    public var blobs: [NoteReplayPayloadBlob] { payloads }

    public init(
        document: NoteReplayHistoryDocument,
        payloads: [NoteReplayPayloadBlob]
    ) {
        self.document = document
        self.payloads = payloads
    }
}

/// Deterministic JSON codec for content-addressed element snapshots.
public enum NoteReplayPayloadCodec {
    public static let inkMediaType = "application/vnd.notes.note-replay-ink"
    public static let elementsMediaType =
        "application/vnd.notes.note-replay-elements+json"

    public static func encodeElements(_ elements: [CanvasElement]) throws -> Data {
        try makeEncoder().encode(elements)
    }

    public static func decodeElements(_ data: Data) throws -> [CanvasElement] {
        try makeDecoder().decode([CanvasElement].self, from: data)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let interval = date.timeIntervalSinceReferenceDate
            guard interval.isFinite else {
                throw EncodingError.invalidValue(
                    date,
                    .init(
                        codingPath: encoder.codingPath,
                        debugDescription: "Dates must be finite."
                    )
                )
            }
            var container = encoder.singleValueContainer()
            try container.encode(
                "notes-date-v1:\(String(interval.bitPattern, radix: 16))"
            )
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: seconds)
            }
            let string = try container.decode(String.self)
            let exactPrefix = "notes-date-v1:"
            if string.hasPrefix(exactPrefix),
               let bits = UInt64(string.dropFirst(exactPrefix.count), radix: 16) {
                let interval = Double(bitPattern: bits)
                guard interval.isFinite else {
                    throw DecodingError.dataCorruptedError(
                        in: container,
                        debugDescription: "The exact date bit pattern is not finite."
                    )
                }
                return Date(timeIntervalSinceReferenceDate: interval)
            }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }
            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
            if let date = standard.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected seconds since 1970 or an ISO-8601 date."
            )
        }
        return decoder
    }
}
