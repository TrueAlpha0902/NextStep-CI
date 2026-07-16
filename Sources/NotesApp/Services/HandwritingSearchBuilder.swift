import CryptoKit
import Foundation
import NotesCore
import NotesServices

/// Converts only user-accepted handwriting suggestions into a separately
/// namespaced derived search document. Machine output that is pending or
/// rejected never enters the local search index.
enum HandwritingSearchBuilder {
    private static let documentNamespace =
        "com.speci.localnotes.search.handwriting.v1"
    private static let fingerprintNamespace =
        "com.speci.localnotes.search.handwriting-fingerprint.v1"

    static func documentID(notebookID: UUID, pageID: UUID) -> UUID {
        var material = Data(documentNamespace.utf8)
        append(notebookID, to: &material)
        append(pageID, to: &material)
        var bytes = Array(SHA256.hash(data: material).prefix(16))
        // UUID version 8 denotes an application-defined, name-derived UUID.
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func segments(
        for document: HandwritingRecognitionDocument,
        expectedPageID: PageID
    ) throws -> [RecognizedTextSegment] {
        try document.validate(expectedPageID: expectedPageID)
        let candidatesByID = Dictionary(
            uniqueKeysWithValues: document.machineCandidates.map { ($0.id, $0) }
        )
        return document.acceptedText.compactMap { reviewed in
            guard let candidate = candidatesByID[reviewed.id] else { return nil }
            let bounds = reviewed.normalizedPageBounds
            return RecognizedTextSegment(
                id: reviewed.id,
                text: reviewed.text,
                confidence: candidate.machineConfidence,
                bounds: NormalizedRect(
                    x: bounds.x,
                    y: bounds.y,
                    width: bounds.width,
                    height: bounds.height
                ),
                pageID: expectedPageID.rawValue,
                source: .handwriting,
                localeIdentifier: reviewed.localeIdentifier
            )
        }
    }

    /// Content-addresses all review-relevant durable state. A rejection also
    /// changes this value so a previously accepted segment is removed.
    static func sourceFingerprint(
        for document: HandwritingRecognitionDocument,
        expectedPageID: PageID
    ) throws -> String {
        try document.validate(expectedPageID: expectedPageID)
        var material = Data(fingerprintNamespace.utf8)
        append(document.runID, to: &material)
        append(document.sourceInkSHA256, to: &material)
        append(document.revision, to: &material)
        for candidate in document.machineCandidates {
            append(candidate.id, to: &material)
            append(candidate.machineText, to: &material)
            append(candidate.machineConfidence.bitPattern, to: &material)
            append(candidate.normalizedPageBounds.x.bitPattern, to: &material)
            append(candidate.normalizedPageBounds.y.bitPattern, to: &material)
            append(candidate.normalizedPageBounds.width.bitPattern, to: &material)
            append(candidate.normalizedPageBounds.height.bitPattern, to: &material)
            append(candidate.localeIdentifier ?? "", to: &material)
        }
        for review in document.reviews {
            append(review.candidateID, to: &material)
            append(review.decision.rawValue, to: &material)
            append(review.correctedText ?? "", to: &material)
        }
        return SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func append(_ value: UUID, to data: inout Data) {
        Swift.withUnsafeBytes(of: value.uuid) {
            data.append(contentsOf: $0)
        }
    }

    private static func append(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        append(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func append(_ value: Int64, to data: inout Data) {
        append(UInt64(bitPattern: value), to: &data)
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) {
            data.append(contentsOf: $0)
        }
    }
}
