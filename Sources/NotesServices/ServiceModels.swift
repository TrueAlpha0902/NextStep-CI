import Foundation

public struct NormalizedRect: Codable, Hashable, Sendable {
    /// Unit-space coordinates. The vertical origin is defined by the owning
    /// payload rather than by this geometry type.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum RecognizedTextSource: String, Codable, Hashable, Sendable {
    case typedText
    case canvasElement
    case handwriting
    case pdfText
    case scannedImage
    case audioTranscript
    case outline
    case bookmark
}

public struct RecognizedTextSegment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var confidence: Double
    /// Optional source-space location. `.scannedImage` currently preserves
    /// Vision's lower-left origin, while `.handwriting` uses the note page's
    /// upper-left origin; other indexed sources generally omit bounds. Callers
    /// must branch on `source` until the shared search model is normalized.
    public var bounds: NormalizedRect?
    public var pageID: UUID?
    public var source: RecognizedTextSource
    public var localeIdentifier: String?
    public var startTime: TimeInterval?

    public init(
        id: UUID = UUID(),
        text: String,
        confidence: Double = 1,
        bounds: NormalizedRect? = nil,
        pageID: UUID? = nil,
        source: RecognizedTextSource,
        localeIdentifier: String? = nil,
        startTime: TimeInterval? = nil
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.bounds = bounds
        self.pageID = pageID
        self.source = source
        self.localeIdentifier = localeIdentifier
        self.startTime = startTime
    }
}

public struct SearchIndexDocument: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var notebookID: UUID
    public var pageID: UUID?
    public var title: String
    public var revision: Int
    /// Optional content-addressed identity of the durable source used to build
    /// this derived document. Older snapshots decode this as `nil` and rebuild.
    public var sourceFingerprint: String?
    public var segments: [RecognizedTextSegment]
    public var modifiedAt: Date

    public init(
        id: UUID = UUID(),
        notebookID: UUID,
        pageID: UUID? = nil,
        title: String,
        revision: Int,
        sourceFingerprint: String? = nil,
        segments: [RecognizedTextSegment],
        modifiedAt: Date = .now
    ) {
        self.id = id
        self.notebookID = notebookID
        self.pageID = pageID
        self.title = title
        self.revision = revision
        self.sourceFingerprint = sourceFingerprint
        self.segments = segments
        self.modifiedAt = modifiedAt
    }
}

public struct LocalSearchHit: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var documentID: UUID
    public var notebookID: UUID
    public var pageID: UUID?
    public var title: String
    public var snippet: String
    public var score: Double
    public var segment: RecognizedTextSegment?
    /// Content-addressed identity of the document snapshot that produced this
    /// hit. Older persisted/encoded hits decode this optional value as `nil`.
    public var sourceFingerprint: String?

    public init(
        id: UUID = UUID(),
        documentID: UUID,
        notebookID: UUID,
        pageID: UUID?,
        title: String,
        snippet: String,
        score: Double,
        segment: RecognizedTextSegment?,
        sourceFingerprint: String? = nil
    ) {
        self.id = id
        self.documentID = documentID
        self.notebookID = notebookID
        self.pageID = pageID
        self.title = title
        self.snippet = snippet
        self.score = score
        self.segment = segment
        self.sourceFingerprint = sourceFingerprint
    }
}

/// An ephemeral, independently navigable match used by in-document search.
/// Its compound identity remains unique even when two source documents reuse a
/// segment identifier, and a nonoptional page target is enforced by the type.
public struct LocalSearchSegmentHit: Identifiable, Hashable, Sendable {
    public struct ID: Hashable, Sendable {
        public let documentID: UUID
        public let segmentID: UUID

        public init(documentID: UUID, segmentID: UUID) {
            self.documentID = documentID
            self.segmentID = segmentID
        }
    }

    public let id: ID
    public let notebookID: UUID
    public let pageID: UUID
    public let title: String
    public let snippet: String
    public let score: Double
    public let segment: RecognizedTextSegment
    /// Content-addressed identity of the document snapshot that produced this
    /// ephemeral result, when the indexed document provides one.
    public let sourceFingerprint: String?

    public init(
        documentID: UUID,
        notebookID: UUID,
        pageID: UUID,
        title: String,
        snippet: String,
        score: Double,
        segment: RecognizedTextSegment,
        sourceFingerprint: String? = nil
    ) {
        id = ID(documentID: documentID, segmentID: segment.id)
        self.notebookID = notebookID
        self.pageID = pageID
        self.title = title
        self.snippet = snippet
        self.score = score
        self.segment = segment
        self.sourceFingerprint = sourceFingerprint
    }
}

public struct AudioTimelineMark: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var commandID: UUID
    public var pageID: UUID
    public var time: TimeInterval

    public init(id: UUID = UUID(), commandID: UUID, pageID: UUID, time: TimeInterval) {
        self.id = id
        self.commandID = commandID
        self.pageID = pageID
        self.time = time
    }
}

public struct AudioRecordingResult: Codable, Hashable, Sendable {
    public var id: UUID
    public var fileURL: URL
    public var duration: TimeInterval
    public var startedAt: Date
    public var marks: [AudioTimelineMark]

    public init(
        id: UUID,
        fileURL: URL,
        duration: TimeInterval,
        startedAt: Date,
        marks: [AudioTimelineMark]
    ) {
        self.id = id
        self.fileURL = fileURL
        self.duration = duration
        self.startedAt = startedAt
        self.marks = marks
    }
}

public enum AudioSessionUsage: String, Codable, Hashable, Sendable {
    case recording
    case playback
}

public struct AudioSessionCoordinatorState: Codable, Hashable, Sendable {
    public var ownerID: UUID?
    public var usage: AudioSessionUsage?

    public init(ownerID: UUID?, usage: AudioSessionUsage?) {
        self.ownerID = ownerID
        self.usage = usage
    }

    public static let idle = AudioSessionCoordinatorState(ownerID: nil, usage: nil)
}

public enum AudioPlaybackStatus: String, Codable, Hashable, Sendable {
    case stopped
    case playing
    case paused
    /// Playback reached the natural end of the loaded item.
    case finished
    /// The player terminated because decoding or playback failed.
    case failed
}

public struct AudioPlaybackState: Codable, Hashable, Sendable {
    public var status: AudioPlaybackStatus
    public var fileURL: URL?
    public var currentTime: TimeInterval
    public var duration: TimeInterval

    public init(
        status: AudioPlaybackStatus,
        fileURL: URL?,
        currentTime: TimeInterval,
        duration: TimeInterval
    ) {
        self.status = status
        self.fileURL = fileURL
        self.currentTime = currentTime
        self.duration = duration
    }

    public static let stopped = AudioPlaybackState(
        status: .stopped,
        fileURL: nil,
        currentTime: 0,
        duration: 0
    )
}

public struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var startTime: TimeInterval
    public var duration: TimeInterval
    public var confidence: Double

    public init(
        id: UUID = UUID(),
        text: String,
        startTime: TimeInterval,
        duration: TimeInterval,
        confidence: Double
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.duration = duration
        self.confidence = confidence
    }
}

public struct TranscriptTimelineMapping: Identifiable, Codable, Hashable, Sendable {
    public var segment: TranscriptSegment
    public var mark: AudioTimelineMark?

    public var id: UUID { segment.id }
    public var pageID: UUID? { mark?.pageID }

    public init(segment: TranscriptSegment, mark: AudioTimelineMark?) {
        self.segment = segment
        self.mark = mark
    }
}

public struct ModelArtifact: Codable, Hashable, Sendable {
    public var relativePath: String
    public var remoteURL: URL
    public var sha256: String?
    public var approximateBytes: Int64

    public init(relativePath: String, remoteURL: URL, sha256: String? = nil, approximateBytes: Int64) {
        self.relativePath = relativePath
        self.remoteURL = remoteURL
        self.sha256 = sha256
        self.approximateBytes = approximateBytes
    }
}

public struct ModelDescriptor: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var version: String
    public var licenseName: String
    public var licenseURL: URL
    public var artifacts: [ModelArtifact]

    public init(
        id: String,
        displayName: String,
        version: String,
        licenseName: String,
        licenseURL: URL,
        artifacts: [ModelArtifact]
    ) {
        self.id = id
        self.displayName = displayName
        self.version = version
        self.licenseName = licenseName
        self.licenseURL = licenseURL
        self.artifacts = artifacts
    }

    public var approximateBytes: Int64 {
        artifacts.reduce(0) { total, artifact in
            let (sum, overflow) = total.addingReportingOverflow(artifact.approximateBytes)
            return overflow ? Int64.max : sum
        }
    }
}

public enum IntelligenceAction: Codable, Hashable, Sendable {
    case summarize
    case rewrite
    case outline
    case meetingNotes
    case quiz(questionCount: Int)
    case ask(question: String)
    case explain
    case calculate(expression: String)
    case translate(targetLanguageIdentifier: String)
}

public struct IntelligenceCitation: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var pageID: UUID?
    public var label: String
    public var excerpt: String
    public var startTime: TimeInterval?

    public init(
        id: UUID = UUID(),
        pageID: UUID? = nil,
        label: String,
        excerpt: String,
        startTime: TimeInterval? = nil
    ) {
        self.id = id
        self.pageID = pageID
        self.label = label
        self.excerpt = excerpt
        self.startTime = startTime
    }
}

public struct QuizItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var question: String
    public var answer: String

    public init(id: UUID = UUID(), question: String, answer: String) {
        self.id = id
        self.question = question
        self.answer = answer
    }
}

public struct IntelligenceRequest: Codable, Hashable, Sendable {
    public var action: IntelligenceAction
    public var text: String
    public var localeIdentifier: String
    public var citations: [IntelligenceCitation]

    public init(
        action: IntelligenceAction,
        text: String,
        localeIdentifier: String = "zh-Hant",
        citations: [IntelligenceCitation] = []
    ) {
        self.action = action
        self.text = text
        self.localeIdentifier = localeIdentifier
        self.citations = citations
    }
}

public struct IntelligenceResult: Codable, Hashable, Sendable {
    public var text: String
    public var quizItems: [QuizItem]
    public var citations: [IntelligenceCitation]
    public var providerName: String
    public var isGenerative: Bool

    public init(
        text: String,
        quizItems: [QuizItem] = [],
        citations: [IntelligenceCitation] = [],
        providerName: String,
        isGenerative: Bool
    ) {
        self.text = text
        self.quizItems = quizItems
        self.citations = citations
        self.providerName = providerName
        self.isGenerative = isGenerative
    }
}
