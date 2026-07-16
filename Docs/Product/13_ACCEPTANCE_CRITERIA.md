# 13 — Acceptance Criteria

## Product loop

- A user can complete Goal → verified import → week plan → Today → package → evidence → progress → replan without a free-form chat screen.
- 100% of ready Today actions have primary milestone, Why Today reason code, estimate, required output and completion criteria.
- A missed action produces a visible diff; protected facts/actions are unchanged until confirmation.

## Grounding

- 100% of confirmed deadlines, credits, grades, paper facts and ready factual claims resolve to current SourceAnchor/EvidenceLink or explicit user confirmation.
- Fabricated DOI, author, URL, page, anchor ID and mismatched source hash are rejected in automated tests.
- Abstract-only/metadata-only sources cannot support full-text page claims.
- Original/legal source is directly openable when recorded; unavailable state never displays invented content.

## Planner

- Identical canonical input, local date and engine version produce identical canonical output hash in 1,000 repeat/property runs.
- Cycles, negative capacity and invalid time zone fail before publication.
- Confirmed deadline never changes through planning/replanning.
- Planned work is ≤85% of available time unless a recorded one-time override exists.
- Today contains at most three must and one should action; infeasible overflow remains visible as risk.
- Replan diff accounts for every prior future action as retained, moved, split, removed or protected.

## Sync and data integrity

- Same library selected on iPhone/iPad converges to the same canonical entity and operation hashes after the provider reports all files downloaded/current and both apps process queues; local ingestion p95 ≤10 seconds after file availability.
- 24-hour offline edits on both devices merge without losing independent entities/strokes.
- Concurrent protected-field or same-stroke edits create a conflict; zero silent overwrites.
- Duplicate/reordered/truncated/malicious change packs are idempotently ignored or quarantined.
- Crash at every outbox/import transaction boundary yields either old or new committed state, never partial state.
- Academic JSON migration preserves entity counts/IDs/revisions and is idempotent; rollback restores the untouched backup.

## iPhone/iPad UX

- iPhone portrait uses tab/stack flow; no clipped persistent sidebar/inspector and no horizontally squeezed seven-column week.
- All core flows pass on the smallest supported iPhone simulator and 13-inch iPad, portrait/landscape, plus iPad 1/3 and 1/2 Split View.
- Touch targets ≥44×44 pt; Body through AX5 exposes all deadlines, criteria and primary actions without truncation.
- VoiceOver order and labels pass Today, Guided Package, Reader, Goal and Workspace flows; no status relies only on color.
- Light/Dark and Increase Contrast meet WCAG 2.2 AA for text and meaningful non-text UI.

## Ink

- App-added processing latency from PencilKit callback to committed UI update p95 ≤25 ms and p99 ≤50 ms on the oldest supported test device; native hardware latency is reported separately.
- 60-minute write soak: no crash, main-thread stall >100 ms caused by OCR/AI/sync, or loss of a stroke acknowledged as saved.
- 100 pages/50,000 strokes: page switch p95 ≤300 ms with lazy loading and bounded memory.
- Stroke end becomes durable locally within 2 seconds; background transition drains or records recoverable pending state.
- 100 undo/redo operations reproduce expected drawing hash; PDF normalized anchor round-trip error ≤1 point at rendered page scale.
- Raw ink hash is unchanged by OCR/AI; every recognized result/task candidate resolves to original stroke IDs/bounds.

## Performance and reliability

- Warm launch to interactive cached Today p95 ≤1.5 s; cold local launch p95 ≤3 s on the oldest supported physical baseline.
- Scrolling Today/Goal lists maintains 55 fps p95 on 60 Hz devices with fixture maximums.
- Background OCR/index/model tasks never run synchronous expensive work on MainActor.
- Offline launch, action completion, ink, local search and planning work without network.

## AI contracts/security

- Every AI envelope passes Draft 2020-12 and semantic validation before persistence; unknown fields and future versions fail closed.
- Fuzzed oversized strings/arrays, prompt injection, traversal, symlink, hash mismatch and zip-bomb fixtures are rejected.
- No raw content appears in default logs/diagnostic export.
- Foundation Models unavailable/restricted/unsupported paths complete using extractive/manual fallback.

## Windows preview and CI

- Browser preview runs locally on Windows and clearly labels itself non-native; its fixture states validate against the same schemas.
- It does not claim PencilKit, Files/iCloud, performance, signing or device acceptance.
- CI separately runs iPhone and iPad simulator tests/screenshots and generic-device compilation.
- A configured workflow is not called green unless the exact commit's check succeeds; artifacts record repository, commit/tree hash, workflow/run and SHA-256.
