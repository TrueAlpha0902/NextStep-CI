import CryptoKit
import Foundation
import NotesCore
import NotesServices

/// Converts durable freeform-canvas elements into a separate derived search
/// document. The document identity is namespaced so it cannot alias the raw
/// page UUID used by structured content and imported-page OCR.
enum CanvasElementSearchBuilder {
    private static let documentNamespace =
        "com.speci.localnotes.search.canvas-elements.v1"
    private static let fingerprintNamespace =
        "com.speci.localnotes.search.canvas-elements-fingerprint.v1"

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
        for elements: [CanvasElement],
        pageID: UUID
    ) -> [RecognizedTextSegment] {
        elements.compactMap { element in
            guard let text = searchableText(for: element.content) else {
                return nil
            }
            return RecognizedTextSegment(
                id: element.id.rawValue,
                text: text,
                pageID: pageID,
                source: .canvasElement
            )
        }
    }

    static func sourceFingerprint(
        for segments: [RecognizedTextSegment]
    ) -> String {
        var material = Data(fingerprintNamespace.utf8)
        for segment in segments {
            append(segment.id, to: &material)
            append(segment.source.rawValue, to: &material)
            append(segment.text, to: &material)
        }
        return SHA256.hash(data: material)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func searchableText(
        for content: CanvasElementContent
    ) -> String? {
        let candidate: String?
        switch content {
        case .text(let text):
            candidate = text.text
        case .stickyNote(let stickyNote):
            candidate = stickyNote.text
        case .link(let link):
            candidate = link.title
        case .image, .shape, .connector, .tape, .sticker:
            candidate = nil
        }
        guard let candidate else { return nil }
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func append(_ value: UUID, to data: inout Data) {
        Swift.withUnsafeBytes(of: value.uuid) {
            data.append(contentsOf: $0)
        }
    }

    private static func append(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        Swift.withUnsafeBytes(of: &length) {
            data.append(contentsOf: $0)
        }
        data.append(bytes)
    }
}
