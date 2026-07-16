# 14 — Recommended First Complete Vertical Slice

## Outcome

The private Beta 1 must prove one trustworthy loop **and same-Apple-ID continuation**:

> Set “pass one course” as a goal, import a syllabus PDF, confirm its exam date, receive and complete one anchored study action, see milestone progress/replan, then open the same state on the other Apple device.

## Included behavior

1. Onboarding creates UserProfile, weekly capacity and an UltimateGoal/Goal/Milestone.
2. Source importer reuses PDF/`.notepkg` infrastructure, hashes content and extracts text/OCR locally.
3. Date candidates include exact SourceAnchors; user confirms or rejects them.
4. Planner creates one WeeklyOutcome and prepared DailyActions under deterministic capacity/dependency rules.
5. Today is the launch root on both platforms.
6. Guided Package presents Why Today, required anchored passage, key points, three deterministic/extractive quiz items, output and criteria.
7. Completion stores output/quiz evidence and derives progress.
8. A missed/partial action shows and applies a replan diff.
9. Local SQLite/outbox exports immutable changes to the selected iCloud Drive folder; the second device imports and converges.
10. Conflict fixture demonstrates protected deadline review; no silent overwrite.

## Fixed sample fixture

- Goal: “Pass Corporate Finance”.
- Milestone: “Complete WACC exam review”.
- Verified exam date: supplied syllabus fixture passage.
- Weekly capacity: five 45-minute blocks.
- Today action: “Explain how debt changes WACC”, 35 minutes.
- Prepared material: one syllabus anchor and one user-provided/licensed reading fixture.
- Required output: a 120–250 word explanation.
- Criteria: include cost of debt, tax shield and risk trade-off; quiz ≥2/3; explicit user completion.

The test fixture is synthetic/licensed and cannot be mistaken for a real institution's requirement.

## UI paths

- iPad: sidebar Today → action list/detail → Guided Workspace with source inspector.
- iPhone: Today tab → action detail → sequential Guided steps → full-screen source → complete.
- Both expose offline/sync/current/conflict and source-unavailable states.

## Technical path

- Add domain and SQLite repositories alongside existing stores; do not rewrite NotesCore.
- Build generalized source anchors with an adapter for existing block anchors.
- Implement pure planner and strict schema validation before optional model adapters.
- Use extractive generation for the slice; optional iOS/iPadOS 26 Foundation Models may improve wording but must produce the same contract and pass the same gates.
- Implement iCloud Drive operation packs; never sync live SQLite.

## Definition of done

- All requirements in document 13 relevant to Phase 1 pass.
- Data survives termination at every save/sync boundary.
- Native iPhone/iPad screenshots and UI tests cover the complete loop in Light/Dark.
- A physical two-device smoke test or, when only one device is available, two isolated simulator/device stores plus provider fixture proves convergence; physical iCloud beta remains a release gate.
- Windows contract twin demonstrates the same synthetic flow but cannot satisfy the native gate.

## Explicitly excluded

Automated paper discovery, real news, Thesis/Project/Career full lifecycle, advanced handwriting conversion, CloudKit, remote/BYOK models, App Store submission and automatic external submissions.
