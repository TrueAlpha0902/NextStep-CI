# 12 — Phased Implementation Roadmap

Every phase is a user-visible vertical capability. A phase is complete only after native simulator tests, error/offline/accessibility states and migration checks pass.

## Phase 0 — Ownership, truthful baseline and executable design

Value: one authoritative private repository, free public CI mirror, decision-complete product/design/contracts and iPhone/iPad preview matrix.

- Deliver: repository transfer/mirror, these 16 product documents, design system, strict schemas and fixture validation.
- UI: ten core Light/Dark native preview states plus phone/tablet responsive fixtures.
- Tests: project validator, JSON Schema metaschema/sample tests and mirror provenance.
- Acceptance: no private history/secret/user data in mirror; latest CI result reported accurately.
- Excludes: production feature implementation.

## Phase 1 — Private cross-device goal-to-action beta

Value: on iPad or iPhone, set one goal, import a syllabus/source, confirm facts, receive Today guidance, complete it, see progress/replan and continue on the other device.

- Domain: profile, goal hierarchy, source/anchor, action/package, evidence, planning/replan, sync change/conflict.
- UI: adaptive shell, onboarding, Today, Goal, week plan, source fact review, guided package and sync/conflict status.
- Windows: local interactive contract twin for the same synthetic Today→Guided→Replan fixture, always labeled non-native.
- Intelligence: deterministic parse/date candidates, extractive package fallback; strict schemas. No required generative model.
- Data: SQLite local projection, academic JSON migration, immutable iCloud Drive change packs/assets.
- Tests: complete loop, iPhone/iPad, offline, concurrent device, restore, source and planner determinism.
- Excludes: paper discovery automation, thesis/career workspaces and advanced ink domain.

## Phase 2 — Ink-to-action learning loop

Value: annotate notes/PDF, select ink, confirm recognized content and turn it into a scheduled action.

- Ink: pen/pencil/technical/highlighter presets, pixel/stroke eraser, lasso move/scale, templates, autosave/recovery and framework-neutral anchors.
- UI: adaptive ink toolbar, recognition/task candidate preview, PDF/source link.
- Tests: latency/stability, Apple Pencil capability gates, generic stylus fallback, conflict and anchor accuracy.
- Excludes: artistic brushes, formula/table recognition and live collaboration.

## Phase 3 — Grounded papers and guided study

Value: discover/verify a real paper, open legal original, read exact ranges, highlight, quiz and produce an evidence-backed output.

- Connectors: DOI/Crossref/OpenAlex/arXiv/PubMed/Unpaywall with caching/rate limits.
- UI: Paper detail/reader, highlight inspector, comparison and source-unavailable states.
- Tests: fabricated/mismatched metadata, abstract-only, retracted/unavailable source and citation traceability.

## Phase 4 — Thesis vertical lifecycle

Value: move from research question through evidence matrix to one finished, source-grounded chapter artifact.

- Includes screening, compare, gap proposal, question confirmation, method/data/analysis/writing/feedback phases.
- Excludes autonomous conclusions, journal submission and plagiarism/copyright-risk redistribution.

## Phase 5 — Project and Career execution

Value: turn a project brief or verified job description into artifacts, gap-closing actions, application evidence and interview preparation.

- Includes project lifecycle, requirement verification, resume/portfolio evidence and application tracking.
- Excludes automatic applications or scraping that violates source terms.

## Phase 6 — Weekly current affairs and calendar refinement

Value: receive one dated, multi-source, goal-relevant weekly package and track follow-up.

- Includes official + independent sources, perspectives, uncertainty and recurrence.
- EventKit reads user's system calendars; Google Calendar can sync through the user's iOS account without a paid NextStep connector.

## Phase 7 — Advanced ink, export and CloudKit-ready abstraction

Value: layers, shape/segment/formula/table workflows, richer search/export and durable large-library operation.

- CloudKit adapter remains a separate future decision; V1 transport protocol and merge semantics are preserved.
- Excludes real-time multi-user collaboration until identity/encryption/operations funding exists.

## Release gates

- Internal fixture preview → native CI preview → cross-device private beta → stable personal beta.
- Beta 1 is Phase 1, not “all planned features complete.”
- No App Store submission until privacy nutrition labels, entitlement/signing, support URL, data export/delete and external beta feedback are complete.
