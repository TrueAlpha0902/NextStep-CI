# 01 — Product Vision Gap Analysis

## Product shift

Current center: **capture, organize and revisit notes/courses**.
Required center: **decide and prepare the next trustworthy action that advances a user-owned long-term goal**.

Notes remain first-class evidence and learning workspaces, but are inputs rather than the home information architecture.

## Capability gap

| Promise | Current state | Required change | Migration disposition |
| --- | --- | --- | --- |
| Open the app and know what to do | Course/document library | Today with ordered must/should actions, time, rationale, prepared materials and risk | Replace root; embed old library under Sources |
| Daily action advances a final goal | Captures and study cards are not goal-linked | Mandatory goal→milestone→outcome→action lineage | New domain; migrate confirmed captures as candidates |
| Action is executable | Tasks can remain descriptive | Required output, completion criteria, prepared sources and guided steps | New GuidedLearningPackage schema |
| Plans adapt safely | No cross-domain planner | Deterministic hard/soft constraints, replanning diff and approval | New planning engine; AI proposes only |
| Sources are transparent | Block-level note anchors; extractive snippets | Document/Paper/Citation/Anchor/Claim/Evidence graph | Generalize, do not discard old anchors |
| Research lifecycle | Note reading only | Discovery through submission/defense | New Thesis workspace |
| Project/career execution | Absent | Artifact/project/job evidence and daily actions | New workspaces |
| Current affairs | Absent | Dated, multi-source weekly packages | Grounded connector pipeline |
| Handwriting becomes planning input | OCR review/search only | Stroke/source anchor→candidate→user confirmation→action | Add derivation records; preserve raw ink |
| iPhone usability | device family is iPad only | compact navigation, one-column task flow and phone reader | Enable iPhone; recompose, never scale down |
| Same-account sync | chosen Files/iCloud folder without merge | same Apple ID + same chosen folder; immutable change packs and local projection | Add sync engine; retain folder choice |

## Non-negotiable invariants

- A confirmed citation, hard deadline, graduation requirement or grade cannot originate solely from free-form model output.
- Every ready learning claim resolves to a legal source and exact anchor; otherwise it is visibly pending/unavailable.
- Raw note, file and ink data is immutable from the AI pipeline. AI writes derived proposals only.
- Every Today action has one primary milestone, a reason code, a time estimate, output and completion criteria.
- Replanning never silently edits hard facts or an in-progress/locked action.
- Core operation remains free: no subscription, advertisement, mandatory NextStep account or required paid API.
- iPhone screens use mobile navigation and staged disclosure, not a compressed iPad split view.

## Product and technical debt to retire

- Course-first and document-first navigation.
- A single academic JSON aggregate and assumptions of one writer/device.
- `IntelligenceResult` free-form presentation as a final product artifact.
- Block-only source anchor and untyped `AIArtifact` as sufficient provenance.
- iPad-only destination tests and screenshot matrix.
- Statements that configured tests/CI imply a current green run.

## Success gap closure

The first meaningful closure is not another screen. It is the complete loop:

```text
confirm one goal
→ import and verify one syllabus/source
→ create one feasible weekly plan
→ show one prepared Today action
→ complete and attach evidence
→ update milestone progress
→ deterministically replan
→ sync the result to a second Apple device
```

Only after this loop passes offline, conflict, accessibility and source-grounding tests should Thesis, Career, current affairs or advanced brushes expand.
