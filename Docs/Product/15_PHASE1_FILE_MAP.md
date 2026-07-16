# 15 — Phase-1 Repository Change Map

This is the decision-complete change inventory for the first vertical slice. Exact symbols may be split only to satisfy the stated module boundaries; product behavior must not change implicitly.

## Add

### Domain and contracts

- `Sources/NextStepDomain/`: shared metadata/facts/IDs; Goal, Planning, Learning, Source/Evidence, Progress, Calendar and SyncConflict records.
- `Sources/NextStepPlanning/`: snapshot builder, DAG/capacity validator, deterministic scheduler, reason codes and replan diff.
- `Sources/NextStepPersistence/`: SQLite connection/migrations, repositories, unit-of-work, blob catalog, academic-v1 migrator.
- `Sources/NextStepGrounding/`: document job, generalized anchors, evidence validators, JSON Schema validator and extractive package builder.
- `Sources/NextStepSync/`: outbox/inbox ledger, canonical change codec, merge/conflict, iCloud folder transport and future `SyncTransport` boundary.
- `Sources/NextStepDesignSystem/`: tokens, adaptive metrics and Phase-1 shared components.
- `Schemas/AI/`: contracts created with this specification; add valid/invalid fixtures under `Tests/Fixtures/AI` during implementation.

### Feature UI

- `Sources/NotesApp/Features/AppShell/`: adaptive iPad sidebar + iPhone tab shell and route model.
- `Sources/NotesApp/Features/Onboarding/`, `Today/`, `Goals/`, `Plan/`, `GuidedLearning/`, `SourceReview/`, `Progress/`, `SyncStatus/`.
- `Sources/NotesApp/PreviewFixtures/`: synthetic slice data shared by SwiftUI previews/UI-test launch arguments.
- `Tests/NextStepDomainTests/`, `NextStepPlanningTests/`, `NextStepPersistenceTests/`, `NextStepGroundingTests/`, `NextStepSyncTests/`.

### Windows contract twin

- `PreviewWeb/`: static, no-backend responsive renderer of the same fixture JSON; banner and capability stubs are mandatory.
- It is a preview artifact, never imported by the iOS production target.

## Modify

- `project.yml`: enable device families `1,2`; add modules/tests; keep iOS 18, Swift 6 strict concurrency, bundle ID and existing technical names.
- `Sources/NotesApp/App/NotesApp.swift` and `AppComposition.swift`: compose new repositories/services/shell; keep one migration gate.
- `Sources/NotesApp/Views/LibraryView.swift`: remove product-root ownership; make existing library reusable under Sources.
- `Sources/NotesApp/App/AppModel.swift`: narrow toward notebook feature state; do not add goal/planning/sync state to the existing monolith.
- `Sources/NextStepAcademic/Persistence/*`: repository adapter and read-only migration export; preserve validation and identifiers.
- `Sources/NextStepAcademic/Capture/SourceAnchor.swift`: compatibility adapter to generalized anchor; no destructive schema rewrite.
- `Sources/NotesApp/Resources/Localizable.xcstrings`: new navigation/status/action/a11y strings.
- `Sources/NotesApp/Resources/PrivacyInfo.xcprivacy` and Info.plist only when declared APIs/permissions actually change.
- `.github/workflows/ios-ci.yml`: iPhone + iPad destinations, unit/UI suites, Light/Dark screenshots, schema fixtures, mirror provenance and generic universal device build.
- `scripts/validate-project.*`: require new modules/schemas/device family and forbid production dependency on `PreviewWeb`.
- Existing UI tests: preserve notebook/course regressions and add Phase-1 end-to-end routes.

## Retain unchanged unless a failing adapter test proves necessity

- `Sources/NotesCore/FileNotebookRepository.swift`, `NotebookRepository.swift`, models, `.notepkg` layout and recovery contracts.
- Existing PDF/image/`.notepkg` import, export snapshots, content-addressed assets and library-root safety.
- PencilKit bridge and ink autosave/recovery path for Phase 1; ink-domain expansion belongs to Phase 2.
- Vision OCR, local search, extractive intelligence, audio/transcript/replay and study scheduler services.
- Course/Session/Capture/WrapUp domain behavior and existing IDs/audit history.
- Bundle identifier `com.speci.localnotes`, App display name NextStep, technical project/target/scheme name Notes and legacy `Notes` data folder.

## Migration/rollback files

- Before migration: `academic-workspace-v1.backup.json` with SHA-256 and source revision.
- SQLite: `nextstep.sqlite`, WAL/SHM local only, `schema_migrations`, `migration_ledger`, `sync_applied_operations` and outbox.
- Migration is one-way for canonical writes but rollback may restore the untouched legacy backup before the cutover marker; after cutover, export a compatibility report instead of dual-writing V1 JSON.

## Phase-1 review gates

1. Domain/contracts and migration tests.
2. Planner determinism and source authority tests.
3. Adaptive shell/Today/Guided flow.
4. iCloud operation sync/conflict tests.
5. End-to-end iPhone/iPad, offline/accessibility and native CI.
