# NextStep Implementation Status

Status date: 2026-07-15. This file reports implementation evidence; the numbered handoff remains the normative target.

## Implemented in the current candidate

- The normal app root is Today, with distinct compact iPhone tab/stack navigation and regular iPad split navigation.
- A user can create one protected goal and deadline, import a PDF/image source, preserve a SHA-256-addressed local copy, create an exact source anchor, receive a deterministic Guided Task, record completion evidence, update progress and trigger replanning.
- The Beta path does not call a generative model or invent paper/news claims. Its summary is explicitly extractive and opens the original user file.
- Local work survives termination through atomic JSON archive replacement. Imported source blobs remain separate from structured state.
- A user may select the same iCloud Drive folder on each Apple device. The current transport restores bookmarks per device, verifies source hashes, queues offline work and stops on protected-deadline or immutable-source conflicts.
- The retained Notes/PencilKit/PDF/OCR/search/audio/replay/export features are reachable as a source library from NextStep and now have compact-width navigation adaptations.
- A local-only Windows contract twin exercises Today → Guided → completion → replan → Sources/Goals/Workspace and is permanently labeled as non-native.
- Native UI fixtures exercise the real Beta flow in Light/Dark on iPhone/iPad and export screenshots when macOS CI runs.

## Not yet sufficient to declare Phase 1 complete

- The Beta archive is an atomic JSON projection. The locked local SQLite schema, migration ledger and one-way academic-v1 migration are not implemented yet.
- Cross-device Beta sync currently publishes a validated structured snapshot plus immutable source blobs. The locked fine-grained immutable operation packs, transactional outbox/inbox ledger, acknowledgements, tombstone lifecycle and field-level merge model remain to be implemented.
- Source import does not yet extract a deadline candidate and require explicit user confirmation from an anchored syllabus passage.
- Guided Tasks do not yet include the locked deterministic quiz and quiz evidence gate.
- Native Xcode compile/UI results and a physical two-device iCloud Drive convergence test remain release gates until recorded as passing.
- Paper discovery, advanced ink-to-action, thesis, project, career and current-affairs verticals belong to later roadmap phases and are not complete.

No screenshot, browser preview or historical workflow run may be used to claim a missing release gate passed. Update this file only when the corresponding repository implementation and reproducible evidence both exist.
