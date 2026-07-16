# 07 — Guided Learning Package Schema

## Contract

A `GuidedLearningPackage` is a versioned, immutable preparation snapshot for exactly one `DailyAction`. Editing creates a new version; completion records the version used.

Required sections:

| Section | Typed content |
| --- | --- |
| Identity | package/action/version/status |
| Lineage | UltimateGoal, Goal, Milestone, WeeklyOutcome IDs |
| Why today | reason codes, human explanation, deadline/slack impact |
| Effort | estimate, difficulty and allowed session modes |
| Objective | measurable learning objectives and prerequisite concept IDs |
| Sources | verified SourceDocument/Paper IDs, access state and required anchors |
| Required reading | ordered anchor ranges and estimated minutes |
| Content | lawful excerpts, extractive summary and anchor-backed key points |
| Highlights | semantic Highlight IDs |
| Knowledge | definitions, formulae/methods, cases, limits and existing links |
| Guidance | ordered questions/hints and optional examples |
| Assessment | Quiz ID and pass/remediation rule |
| Output | RequiredOutput and CompletionCriteria |
| Continuation | next candidate action and review interval |
| Feedback | response options and resulting ReplanEvent types |

## Lifecycle

```text
draft → validating → ready → inProgress → completed
                  ↘ blocked / sourceUnavailable / superseded
```

- `ready` requires resolvable goal lineage, valid action revision, at least one prepared item or an explicit manual task, output and criteria.
- A learning/paper package requires verified source metadata and anchors for every factual key point.
- `sourceUnavailable` may preserve metadata and user annotations but disables unsupported reading/quiz claims.
- Starting pins the package/action version. Replanning may queue a replacement but cannot silently swap the active version.

## Step presentation

The package is not rendered as one Markdown blob. The client displays semantic steps:

1. Orient: Why Today, time, objective, output.
2. Prepare: prerequisites and five-minute concept bridge.
3. Read/observe: one anchored range at a time.
4. Connect: definitions, relationships, case and limits.
5. Practice: guided questions and quiz.
6. Produce: create the required artifact.
7. Verify: apply completion criteria and choose feedback.

On iPhone these are sequential screens with a sticky next control. On iPad they use a 640–720 pt reading workspace and optional 320 pt inspector. Progress is semantic step completion, not scroll percentage.

## Source rules

- Original text is stored only when user-provided or legally permitted; otherwise store necessary quotation, summary and locator.
- Every excerpt includes anchor ID and exact-source hash.
- Summary, key point, definition, formula, case and limitation each carry one or more EvidenceLink IDs.
- A model may propose an explanation but cannot change original text or citation fields.
- If a source offers only metadata/abstract, the package states that level and never names unseen pages.

## Completion

Criteria use deterministic predicates where possible:

- artifact exists and matches requested version/type;
- required fields/non-empty sections present;
- quiz score at or above threshold;
- all required reading steps acknowledged;
- explicit user confirmation for subjective writing quality or external completion.

The user may override a failed subjective criterion with a reason; this creates audited evidence and may reduce confidence/propose remediation. The system never auto-submits coursework, papers or job applications.

## Feedback mapping

| Feedback | Deterministic effect |
| --- | --- |
| insufficient time | update remaining effort; request split/replan |
| too difficult | add prerequisite/remediation action |
| already know | offer short assessment; skip only after pass/confirmation |
| more explanation | generate/extract one anchored explanation proposal |
| more examples | retrieve verified case/evidence |
| delay | create ReplanEvent with reason |
| change method | create a new package version, preserve old |

The machine contract is `Schemas/AI/guided-learning-package.schema.json`; semantic validation is defined in document 06.
