# 00 — Repository Current-State Audit

Audit date: 2026-07-15
Audited revision: `f73ed09` on `codex/notes-foundation`
Evidence rule: a source file or test target proves implementation exists; only an observed successful run proves it passed. This document does not treat the current GitHub check as green.

## Executive finding

The repository is a substantial iPad-first, local-first note and classroom-capture application. It is **not yet** the promised AI personal goal execution and guided-learning product. Its safest path is an additive migration: preserve the mature notebook, ink, OCR, search, audio, replay and academic-capture code, introduce a new goal/planning/source domain, and move the product entry point from Courses/Documents to Today.

## Existing product and screens

The current `NavigationSplitView` exposes Courses, Documents, Favorites, Trash and Settings. Existing screens include:

- Course list/detail, schedule editor, session workspace, capture review, end-session and wrap-up.
- Notebook library, new notebook, Quick Note, editor, page navigator/search/tools.
- PencilKit canvas, handwriting review, text document, study set and whiteboard.
- Audio panel, transcript search, Note Replay and backup/settings flows.

The workflow exports 23 named iPad screenshot states. This proves screenshot automation is configured, not that the latest run succeeded.

## Existing data and file formats

| Area | Current authority | Evidence and boundary |
| --- | --- | --- |
| Notebook | `.notepkg` directory | `manifest.json`, page descriptors, `ink.data`, elements, assets, audio, derived data and write-ahead journals |
| Academic | one schema-v1 JSON workspace | Course, CourseSession, links, Capture, audit and WrapUp; hard limit 16 MiB |
| Search | derived local JSON snapshot/cache | Titles, typed text, canvas, OCR, accepted handwriting and transcript segments |
| UI library metadata | root sidecar | trash, kind and cover hue; not part of complete notebook backup |
| Imported assets | SHA-256 content addressed | PDF/images are validated and referenced by pages |

`.notepkg` already has revision checks, transaction journals, validation/recovery and safe snapshots. The academic workspace has CAS-like versioning and backups, but a single bounded JSON document is unsuitable for goals, evidence graphs, planning decisions or multi-device merge.

## Existing domain models

- NotesCore: stable typed IDs, notebook/page/content/asset/audio/replay/search/AI-artifact and handwriting-review models.
- NextStepAcademic: Course, schedule rule, CourseSession, SessionNoteLink, seven capture kinds, block-level SourceAnchor, audit entries and SessionWrapUp.
- NotesServices: extractive intelligence contracts, citations/quiz primitives, OCR, search, audio, speech, study scheduling and model package management.
- NotesApp: library/editor presentation models and app-level orchestration.

Missing canonical entities include UserProfile, UltimateGoal, Goal, Milestone, WeeklyOutcome, DailyAction, GuidedLearningPackage, PaperSource, Citation/EvidenceLink, KnowledgeConcept, Thesis, Project, Career and Planning/Replan records.

## Existing AI and automation

Implemented:

- Vision OCR for images/scanned PDF pages and bounded ink-only handwriting suggestions.
- Human review before handwriting becomes searchable.
- Extractive/rule-based summary, cleanup, outline, quiz, Q&A and explanation.
- Deterministic math and spaced-repetition primitives.
- On-device speech transcription where Apple supports the language.

Not implemented:

- Generative LLM runtime, embeddings/RAG, verified paper discovery, claim grounding or structured learning-package generation.
- Goal-aware planning/replanning, knowledge graph or transparent AI invocation/provenance ledger.
- Foundation Models integration; it must remain an optional iOS/iPadOS 26+ enhancement.

## Existing handwriting system

PencilKit provides pen, marker, eraser, lasso, colors, three widths, pan/zoom and undo/redo. Ink autosave, page switching fences, PDF/image backgrounds, OCR review and search are useful foundations. The app stores opaque `PKDrawing` data rather than a framework-neutral per-stroke domain. Pixel versus stroke eraser semantics, technical pen/pencil presets, semantic highlights, formal layers, stroke anchors and selected-ink-to-task candidates are absent.

## Existing engineering state

- Swift 6 strict concurrency, XcodeGen and iOS deployment target 18.0.
- `TARGETED_DEVICE_FAMILY` is currently `2`: iPad only. iPhone is not enabled.
- Five test targets are configured. Static counting finds 70 test files and 865 `func test`/`@Test` declarations; this is not a pass count.
- CI targets `macos-26`/Xcode 26, an iPad simulator, generic-device build, screenshots and unsigned IPA.
- The local worktree was clean at audit start. Remote ownership and CI status are operational concerns and must be rechecked immediately before transfer or release.

At audit time `origin` still belonged to the former private-repository owner, while `TrueAlpha0902` was authenticated but not active; repository transfer had not yet been performed. Draft PR #1's then-current check did not start because GitHub reported an account billing/spending-limit condition. The README's earlier green-run reference is historical evidence only and is not evidence that `f73ed09` or a later transfer/mirror is green.

## Reuse, refactor and new modules

Retain:

- `FileNotebookRepository`, `.notepkg`, transaction/recovery, content-addressed assets and import/export.
- PencilKit bridge, OCR, accepted-only handwriting indexing, search, audio/replay and study scheduler.
- Course/session/capture/wrap-up behavior and its tests.

Refactor behind stable protocols:

- `AppModel` and `LibraryView`: replace product-root ownership with a Today-first shell; keep the notebook library as Sources/Learning.
- Academic monolithic JSON: migrate to per-entity local SQLite projection plus immutable sync changes.
- `SourceAnchor`: generalize beyond notebook blocks to PDF, web, ink strokes and source text ranges.
- Opaque ink persistence: preserve it for compatibility, then add a framework-neutral envelope and derived stroke metadata.

Add:

- `NextStepDomain`, `NextStepPersistence`, `NextStepPlanning`, `NextStepGrounding`, `NextStepSync`, `NextStepInk` and `NextStepDesignSystem` boundaries.
- Today/Goals/Plan/Learning/Workspaces/Papers/Sources/Calendar/Progress feature slices.
- Strict JSON Schema validation and an AI provenance/evidence ledger.

## Highest risks

1. iCloud Drive is transport, not a conflict-free database. Never open the same live SQLite file on two devices; sync immutable change packs into a local projection.
2. Source hallucination could corrupt academic work. Unverified facts must not become confirmed deadlines, citations or completion evidence.
3. Goal promises may imply guaranteed outcomes. UI must show feasible plans and risk, not guarantee graduation/employment.
4. The current iPad-only layout will collapse on iPhone without navigation and workspace recomposition.
5. PencilKit opacity and framework coupling limit stroke-level sync/anchors; migration must be non-destructive.
6. Windows cannot run Apple's iOS Simulator; any browser preview is a product-flow approximation, not native verification.
