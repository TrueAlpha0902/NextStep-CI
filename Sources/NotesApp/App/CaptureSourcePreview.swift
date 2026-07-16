import Foundation

/// A read-only, exact view of the Notes content referenced by an academic
/// capture. Academic state never owns or rewrites this text.
enum CaptureSourcePreview: Equatable, Sendable {
    case exact(String)
    case changed(currentText: String)
    case missing
    case unverifiable(currentText: String)
    case unavailable
}
