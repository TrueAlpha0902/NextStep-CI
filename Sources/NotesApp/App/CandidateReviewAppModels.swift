import NextStepAcademic

/// Effect-based result for one exact `CaptureReviewMutation`.
///
/// `applied` includes a write whose durable post-image was proven after an
/// ambiguous backing error. `alreadyApplied` is reserved for a post-image
/// found before this call performs any write.
enum CandidateReviewSaveOutcome: Equatable, Sendable {
    case applied(CaptureItem)
    case alreadyApplied(CaptureItem)
    case revisionConflict(CaptureItem)
    case missing
    case invalid(String)
    case notReady
}
