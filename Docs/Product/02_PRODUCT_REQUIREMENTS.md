# 02 — Revised Product Requirements Document

## Definition

**One sentence:** NextStep is a private, local-first execution guide that turns verified goals, schedules, documents and learning evidence into the exact prepared action a person should complete next.

### Core user

The primary user is one student/researcher preparing for graduation and employment, using the same Apple ID on an iPhone and iPad. The design may later support App Store distribution and more users, but v1 optimizes for personal use without a paid service dependency.

### Problem and value

People possess notes, deadlines and ambitions yet must repeatedly decide what matters, locate materials and recover after delays. NextStep reduces that coordination burden while preserving source transparency and user authority.

### Product promise

When the plan is feasible, completing Today actions provides traceable progress toward confirmed goals. When it is not feasible, NextStep explicitly reports why and proposes recoveries. It does not guarantee graduation, publication, employment, grades or health outcomes.

## Goals and non-goals

Goals:

- Make Today the fastest route from launch to meaningful work.
- Connect every action to a milestone, evidence and completion standard.
- Prepare grounded learning material rather than produce vague todos.
- Preserve verifiable sources and exact locations.
- Safely replan after real-world change.
- Make handwriting a searchable, traceable planning input.
- Work offline; sync through the user's chosen iCloud Drive folder across their iPhone/iPad.

V1 non-goals:

- Real-time collaboration, social feeds, public profiles or a NextStep account.
- Guaranteed autonomous research conclusions or automatic submission/applications.
- Mandatory cloud LLM, paid vector database or paid OCR/search service.
- Full Goodnotes feature parity, desktop publishing or artistic brush simulation.
- Native Windows/iOS emulation. Beta 1 includes a browser-based interactive contract twin, but it does not execute Apple frameworks.

## Primary scenarios

1. Configure graduation and career goals, hard deadlines and weekly capacity.
2. Import a syllabus/PDF/note and confirm extracted dates/requirements.
3. Generate a goal-linked weekly plan and launch a prepared Today action.
4. Read an anchored paper passage, highlight, answer a quiz and submit an output.
5. Annotate a source with Pencil/stylus, convert a selection into a task candidate and confirm it.
6. Miss an action and approve a visible replan diff.
7. Continue on iPhone, then annotate on iPad without losing or silently overwriting either device's work.
8. On Windows, operate the same synthetic Today/Goal/Guided/Reader/Replan fixture through a local web twin while seeing its non-native limitations.

## Functional requirements

### Today and execution

- Launch destination is Today.
- Display primary outcome, must/should actions, total duration, deadline, Why Today, prepared material, milestone effect and risk.
- Each action supports start/pause/complete, insufficient time, too difficult, already know, explain, examples, delay, split and change method.
- Completion requires the configured artifact, quiz threshold or explicit user attestation; save `CompletionEvidence`.

### Goals and planning

- Support UltimateGoal→Goal→Milestone→WeeklyOutcome→DailyAction.
- Validate dependency DAG and capacity; preserve immutable confirmed deadlines.
- Replan on completion, delay, deadline/source/feedback/grade/job/calendar/capacity changes.
- Show proposed adds/removes/moves, reason codes, risk and deadline impact before confirmation when protected records change.

### Learning and sources

- Store GuidedLearningPackage as typed data, never only Markdown.
- Import notes, PDF, images/scans and v1-supported local document conversions; unsupported Word/PowerPoint must give an explicit conversion path rather than pretend to parse.
- Store PaperSource, SourceDocument, Citation, SourceAnchor, Highlight, ExtractedClaim and EvidenceLink.
- Directly open original/legal source when available; show metadata-only/abstract-only/source-unavailable states honestly.

### Workspaces

- Thesis: question, search/screen/read/compare, framework/gap/hypothesis/method/data/analysis/writing/feedback/submission.
- Project: problem through release/case study.
- Career: target role/company, job analysis, gap, documents, interview, applications and offers.
- Current affairs: event/publication dates, first-party and quality media sources, perspectives, uncertainty and follow-up.

### Ink

- V1: pen, pencil, technical pen, semantic highlighter, three widths, color, pixel/stroke eraser, lasso move/scale, undo/redo, zoom, four templates, PDF annotation, autosave/recovery, basic recognition and selection→task candidate.
- Apple Pencil capabilities are availability-gated; generic third-party stylus follows touch input without pressure/tilt promises.
- Raw ink is never overwritten by OCR/AI; all derived records resolve to page/stroke/bounds.

### Sync

- User selects the same iCloud Drive folder once on each device signed into the same Apple ID.
- Each device owns a local SQLite projection; a live SQLite file is never shared through iCloud Drive.
- Sync immutable bounded change packs and content-addressed assets; deterministic merge and user conflict review are required.
- Core work remains available offline. Sync status distinguishes local-only, uploading, current, conflict, paused and provider unavailable.

## Quality requirements

- iOS/iPadOS 18 minimum; iPhone and iPad are equal supported device families.
- Optional Apple Intelligence/Foundation Models integration requires iOS/iPadOS 26+, capability checks and a deterministic fallback.
- No necessary paid service, analytics SDK or advertising SDK.
- VoiceOver, Dynamic Type through AX5, Reduce Motion/Transparency and keyboard access on iPad.
- Source facts and deadlines fail closed; caches may fail open only for already verified, unexpired records.
- Performance and integrity thresholds are normative in `13_ACCEPTANCE_CRITERIA.md`.

## Success metrics

Private beta measures locally and shows the user a transparent diagnostics page; no telemetry leaves the device.

- ≥95% of opened Today actions have ready material, output and criteria.
- 100% of confirmed paper claims and hard deadlines resolve to verified evidence.
- ≥80% of started actions reach completion or an explicit replan outcome.
- Median launch→action start ≤20 seconds after setup.
- 0 silent sync overwrites and 0 accepted loss of durable ink in fault tests.
- Planner produces identical results for identical snapshots/version/date.
