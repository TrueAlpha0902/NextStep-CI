# 05 — Domain and Data Model

## Model conventions

Canonical records are Swift `Codable`, `Sendable`, value types with typed UUID wrappers. Relationships store IDs, not nested mutable copies.

```swift
struct RecordMetadata<ID: Codable & Sendable>: Codable, Sendable {
    let id: ID
    let schemaVersion: Int
    let revision: Int64
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
    let originDeviceID: DeviceID
    let lastOperationID: OperationID
    let provenance: Provenance
}

struct FactValue<Value: Codable & Sendable>: Codable, Sendable {
    let value: Value
    let authority: FactAuthority       // sourceVerified, userConfirmed, aiProposed, inferred
    let mutability: FactMutability     // immutable, confirmationRequired, flexible
    let evidenceLinkIDs: [EvidenceLinkID]
    let confidence: Double?            // 0...1 only for proposals/inference
    let confirmedAt: Date?
}
```

Dates are ISO-8601 UTC instants plus an explicit IANA time-zone identifier when local calendar meaning matters. `revision` increases exactly once per committed mutation. Deletion is a tombstone until all known devices acknowledge it; purge is a separate operation.

## Core records and relations

### Identity and goals

- `UserProfile`: locale, time zone, preferred working blocks, accessibility/learning preferences and onboarding state. It contains no NextStep account credential.
- `UltimateGoal`: title, definition of done, target date/flexibility, status, priority and evidence.
- `Goal`: parent UltimateGoal, outcome, target date, priority and status.
- `Milestone`: Goal, outcome, dependency IDs, target date, completion criteria and progress rule.
- `WeeklyOutcome`: Milestone, ISO week, required artifact/measure, planned effort and status.
- `DailyAction`: primary Milestone, optional related Goals/concepts/sources, scheduled window, effort, difficulty, reason codes, required output, criteria, flexibility/lock state and package ID.

An action has exactly one primary milestone for progress accounting; related goals may explain reuse without double-counting.

### Learning and execution

- `GuidedLearningPackage`: immutable versioned preparation attached to one DailyAction; sections are defined in document 07.
- `RequiredOutput`: kind (`note`, `answer`, `draft`, `artifact`, `decision`, `practice`, `externalConfirmation`), location and validation rule.
- `CompletionCriterion`: typed predicate, threshold, required evidence and user-confirmation policy.
- `CompletionEvidence`: action/package version, artifact reference, quiz result or attestation, captured time and provenance.
- `Quiz`: learning objectives, ordered items, pass threshold and evidence links.
- `UserResponse`: quiz/item version, answer, score, feedback and attempt.
- `RemediationPlan`: failed objectives, next review interval and proposed action.
- `KnowledgeConcept`: canonical label, aliases, definition status and mastery estimate.
- `KnowledgeLink`: typed relation (`requires`, `supports`, `contradicts`, `applies`, `exampleOf`, `sameAs`) with evidence.

### Courses and workspaces

- Existing `Course` and `CourseSession` retain identifiers and are related to Goals/Milestones through join records.
- `Note` is a domain reference to the existing NotesCore notebook, not a duplicate notebook schema.
- `Thesis`: ultimate/goal IDs, question candidates, confirmed question, scope, phase, literature matrix and artifact IDs.
- `Project`: goal, problem evidence, phase, requirements and artifact IDs.
- `JobTarget`: role/company, requirement source, verified requirement IDs and gap IDs.
- `JobApplication`: JobTarget, submitted artifact versions, state, confirmed dates and events.
- `CalendarConstraint`: busy/available/preferred block, recurrence, source and hard/soft status.

### Planning and progress

- `PlanningDecision`: engine version, input snapshot hash, planning horizon, accepted action IDs, rejected alternatives, reason codes, author and timestamp.
- `ReplanEvent`: typed trigger, before snapshot, immutable/flexible affected records and resolution.
- `PlanProposal`: additions/removals/moves/splits, risk changes and confirmation requirements; proposals never mutate canonical state.
- `ProgressSnapshot`: goal/milestone/action aggregates at a plan revision; derived and reproducible.

## Source and evidence graph

- `SourceDocument`: type, display title, MIME/UTType, byte length/content hash, rights/access state, imported file/blob reference or canonical URL, parser/version, retrieved/accessed dates and verification state.
- `PaperSource`: SourceDocument ID, complete title, ordered authors, publication year, journal/conference/publisher, DOI, official publication page, user-file/legal full-text/arXiv/SSRN/PubMed/institutional links, access date, source type, peer-review/preprint states, recommendation reason, related goal IDs and required-reading anchor IDs. Unknown data is explicit; it is never synthesized to fill a field.
- `Citation`: citation style-independent bibliographic snapshot, cited claim/context, access date and SourceAnchor IDs. Rendered APA/other text is derived.
- `SourceAnchor`: source ID, locator variant, quoted-text hash, source revision, captured time and stale/re-resolution state.
- `Highlight`: anchor, semantic category, exact original text, AI explanation proposal, objective/concept IDs, understood/review state and author.
- `ExtractedClaim`: normalized claim, claim type, author (`extractive`, `aiProposed`, `user`), verification status and evidence links.
- `EvidenceLink`: claim/fact/criterion reference, anchor, relation (`supports`, `contradicts`, `defines`, `limits`, `measures`), verification method, verifier and verification time.

Locator variants are formal:

```swift
enum SourceLocator: Codable, Sendable {
    case note(noteID: NotebookID, pageID: PageID, blockID: TextBlockID?,
              utf16Range: Range<Int>?, revision: Int64)
    case pdf(pageIndex: Int, normalizedRects: [NormalizedRect], textQuote: String?)
    case web(canonicalURL: URL, textPosition: Range<Int>?, selector: String?, textQuote: String)
    case ink(inkDocumentID: InkDocumentID, pageID: InkPageID,
             strokeIDs: [InkStrokeID], bounds: NormalizedRect, revision: Int64)
    case media(startMilliseconds: Int64, endMilliseconds: Int64)
}
```

Anchors include source content hash and fail as `stale` after source mutation until re-resolved.

## Ink domain

- `InkDocument`: owner source/note, page order, native payload version and metadata.
- `InkPage`: size/template/source-page anchor/layer order.
- `InkLayer`: type (`source`, `userInk`, `highlight`, `shape`, `aiSuggestion`, `recognizedText`, `feedback`), visibility, lock and export policy.
- `InkStroke`: page/layer/brush IDs, points, native payload slice reference, resolved color/width/opacity/blend mode, bounds, author, created/updated times, revision and tombstone. Resolved style fields remain on the stroke even if its preset later changes.
- `StrokePoint`: x/y, timestamp, pressure, altitude/tilt, azimuth, velocity and estimated/updated flags.
- `BrushPreset`/`BrushStyle`: tool kind, width, RGBA, opacity, pressure/tilt/stabilization and supported parameters only.
- `InkSelection`, `InkGroup`, `InkShape`, `InkAttachment`, `InkAnchor`, `InkHighlight`, `InkRevision`, `InkExportConfiguration`.
- `RecognitionResult`: page/stroke IDs, bounds, text, language, confidence, engine/version and alternatives.
- `RecognitionCorrection`: result version, corrected text and user/time.
- `InkToTaskCandidate`: selection anchor, recognition IDs, classification/confidence, proposed action/deadline/goal and review state.

PencilKit data remains the lossless native rendering authority in v1. Framework-neutral point metadata is captured for new strokes where APIs permit and is derived for legacy ink; failure to derive never deletes or rewrites the native payload.

## Sync records

```swift
struct SyncChange: Codable, Sendable {
    let operationID: OperationID
    let libraryID: LibraryID
    let deviceID: DeviceID
    let hybridLogicalClock: HLC
    let entityType: EntityType
    let entityID: UUID
    let baseRevision: Int64?
    let operation: SyncOperation       // create, replace, tombstone, assetReference
    let payloadSHA256: String
    let payload: Data
}
```

- Each device has a local SQLite projection and applied-operation ledger.
- Immutable change files are the cross-device authority; content-addressed blobs are separate.
- Scalar flexible fields merge by HLC then device ID. Sets use add/remove operation IDs. Confirmed immutable facts and concurrent edits to the same protected record create `SyncConflict`; they never use last-writer-wins.
- Stroke IDs make distinct strokes additive; edits/deletes to the same stroke revision create a reviewable conflict.

## Storage tables

Use normalized SQLite tables for records, joins, facts, sources/anchors/evidence, plan events, sync ledger/conflicts and FTS5 search. Store large PDF/image/audio/native-ink payloads outside SQLite by SHA-256. Foreign keys are enabled; migrations are transactional, idempotent and recorded in `schema_migrations`.
