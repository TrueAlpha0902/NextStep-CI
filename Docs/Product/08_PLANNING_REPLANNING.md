# 08 — Planning and Replanning Logic

## Ownership

The Swift constraint engine owns dates, dependencies, capacity, ordering and state transitions. AI may propose decompositions, estimates and explanations but cannot publish a plan.

## Inputs

- Confirmed goals/milestones/deadlines and dependency DAG.
- Weekly outcomes, existing actions and protected states.
- Calendar busy/available/preferred blocks in the profile time zone.
- User capacity, maximum load, rest blocks and focus preference.
- Effort/difficulty, measured completion speed and remaining effort.
- Review due dates, mastery/forgetting signals and learning gaps.
- Progress, delays, new sources, feedback, grades and application events.
- Input entity versions and a canonical SHA-256 snapshot hash.

## Fact classes

| Class | Examples | Planner permission |
| --- | --- | --- |
| immutable confirmed | institutional deadline, exam date, submitted application | never edit; only warn |
| user commitment/locked | promised work block, started action | change only by explicit confirmation |
| system inference | estimated effort, risk | recompute with reason and provenance |
| AI proposal | decomposition, wording | validate and require appropriate confirmation |
| flexible | unscheduled preparation action | may move within policy |

## Deterministic algorithm

1. Freeze one `PlanningSnapshot` and validate all versions.
2. Validate DAG; a cycle, missing protected fact or invalid time zone blocks publication.
3. Expand recurrence/review requirements for the horizon (today + six days; overview up to milestone deadline).
4. Compute working intervals by subtracting hard calendar constraints and required rest.
5. Reserve 15% of available time as buffer. Never plan more than 85% without an explicit one-time override.
6. Split work over 120 minutes into 15/25/35/45/60/90/120-minute actions; preserve an atomic artifact step when it cannot split.
7. Backward-schedule hard-deadline critical paths using earliest-deadline-first within topological constraints.
8. Order remaining eligible actions lexicographically by:
   - overdue/≤72-hour hard-deadline bucket;
   - lower slack;
   - larger number of blocked descendants;
   - user goal priority;
   - review overdue duration;
   - earlier creation HLC;
   - stable action UUID.
9. Place actions in the earliest compatible interval respecting prerequisite, difficulty/focus and locked windows.
10. Publish at most three `must` and one `should` Today actions. Overflow remains visible in Plan with risk, not hidden.
11. Produce reason codes, infeasibility/risk, input hash and engine version. A second run with the same snapshot/date/version must be byte-equivalent after canonical encoding.

No opaque weighted score decides deadline safety. Lexicographic rules make ordering explainable and testable.

## Progress calculation

- Action completion never directly sets goal percent.
- Each milestone defines measurable criteria/required artifacts and weights summing to 1.0.
- Progress is derived from accepted CompletionEvidence; related-goal links do not double-count.
- A `ProgressSnapshot` records the exact evidence and plan revision.

## Replan triggers

Completion, partial completion, delay, deadline change, new course/source, professor feedback, grade, job, calendar/capacity change, sync conflict resolution, failed quiz and material source unavailability.

Debounce non-urgent triggers for 30 seconds into one event. A newly confirmed hard deadline or current action failure evaluates immediately.

## Replan transaction

1. Append `ReplanEvent` with trigger and before-snapshot.
2. Complete current durable writes and freeze a new snapshot.
3. Re-run the deterministic engine.
4. Diff adds/removes/moves/splits, changed rationale, deadline risk and load.
5. Auto-apply only future, not-started flexible actions with no new risk/protected impact.
6. Require confirmation for locked/started/user-committed actions, hard-fact edits, goal priority changes or newly infeasible commitments.
7. Commit plan revision and `PlanningDecision` atomically; mark the proposal applied/superseded.

## User controls

- `Less time`: choose today's remaining minutes; recompute and show what moves.
- `Too hard`: preserve target; insert a prerequisite/remediation step.
- `Already know`: short evidence check or explicit user confirmation.
- `Delay`: capture reason and deadline impact.
- `Split`: deterministic allowed sizes and output boundary.
- `Change method`: new package version; plan identity remains.

## Edge cases

- Capacity cannot meet deadline: retain deadline, show `infeasible`, quantify shortfall and propose reduce scope/add time/renegotiate date; only the user can record a changed confirmed date.
- Time-zone travel/DST: regenerate local slots from canonical instants and IANA zone; preserve fixed event instants.
- Concurrent devices: only one accepted plan revision descends from the same base. Concurrent protected proposals enter conflict review.
- Offline: plan from local canonical data; label remote source freshness. Queued sync cannot alter an in-progress action.
- Source disappears: block unsupported package steps, keep annotations/evidence metadata and propose a legal replacement.
