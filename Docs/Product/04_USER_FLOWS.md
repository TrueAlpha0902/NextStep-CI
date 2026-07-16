# 04 — User Flows

Every flow records an operation ID and can resume after termination. AI output enters a proposal state until the stated deterministic/user gate passes.

## 1. New user: graduation and career goals

Launch → explain local/iCloud storage → choose local-only or selected iCloud Drive folder → profile/time zone → add Ultimate Goal and hard date/source → add weekly capacity/calendar permission → add career target → preview milestones → confirm facts → Today empty/readiness state.

Failure: denied Calendar keeps manual availability. A goal without a verified hard date is valid but labeled user-estimated; it cannot masquerade as an institutional deadline.

## 2. Upload class notes

Sources → Import → PDF/image/`.notepkg`/supported file → hash and rights label → local parse/OCR → review metadata → link Course/Goal → accept → index → offer candidate concepts/actions.

Offline imports complete locally. Online metadata enrichment is queued.

## 3. Import syllabus and deadline

Import syllabus → deterministic text extraction/OCR → AI/heuristic date candidates with anchors → user compares original passage → mark date as confirmed/user-entered/rejected → create Course/Milestone/CalendarConstraint → planner impact preview → accept.

No deadline is committed directly from OCR/model output.

## 4. Generate long-term plan

Goals → Plan → validate deadline/dependencies/capacity → detect missing facts → create deterministic milestone skeleton → optionally generate decomposition proposals → user confirms protected changes → store PlanningDecision/input snapshot/version → publish week and Today.

If infeasible, publish risk and recovery alternatives; do not hide tasks to make the calendar appear feasible.

## 5. Execute a daily action

Today → select action → read Why Today/time/output/criteria → Start → sequential Guided Package → open anchored material → answer prompts/quiz → create required output → Complete → validate criteria → save evidence → progress snapshot → evaluate replan → return to next action.

## 6. Read highlighted paper and open original

Package/Papers → Paper detail → see title/authors/year/venue/DOI/access/review state → open Reader at required range → render semantic highlights → tap highlight for anchor, explanation and learning objective → Open Original → return with preserved position.

Unavailable full text leaves metadata/abstract visible, disables unsupported full-text claims and offers legal lookup—not a fabricated passage.

## 7. Quiz

Package → Quiz → answer one item at a time → deterministic scoring → inspect evidence-backed rationale → store UserResponse → pass or create remediation/review action. Generated question must reference verified concept/evidence IDs.

## 8. Thesis lifecycle

Workspace → Thesis → define scope → build keyword set → search connectors → deduplicate/screen papers → verify access → read/annotate → compare claims/methods/limits → propose gap → user validates → candidate research questions → method/data/analysis plan → chapter outputs → supervisor feedback import/confirmation → submission checklist.

Research-gap proposals remain hypotheses until the user confirms scope and evidence matrix.

## 9. Project lifecycle

Workspace → Project → problem/evidence → research → requirements → IA/flow/design → prototype → implementation/test → feedback/iteration → release → case study. Each stage creates artifacts, criteria and next actions rather than generic tasks.

## 10. Weekly current affairs

Learning → Current Affairs → select goal-linked topic → gather official + quality media sources → verify publication/event dates → build multi-viewpoint package → user studies/questions/application → choose follow-up event → next weekly recurrence.

Without verifiable sources, the package is `sourceUnavailable` and cannot present generated news as fact.

## 11. Missed action and replanning

Action → Delay/Not completed → reason + remaining effort → create ReplanEvent → recompute hard constraints → show moves, new risk and unchanged protected facts → user confirms protected-impact proposal → publish new plan revision. An in-progress action remains pinned unless explicitly stopped.

## 12. Add job target/application

Career → Add job URL/file/manual description → preserve original and date → extract requirement candidates → user verifies → compare evidence/skills → create capability gaps/milestones → prepare one resume/interview/application output → update plan. Submission status and interview dates require user confirmation.

## 13. Handwriting to action

Select ink with lasso → choose Create task candidate → preserve stroke IDs/bounds/page/source → local recognition → show transcription/type/confidence/goal/deadline proposal → user edits/confirms → create DailyAction candidate → planner schedules it. Original strokes never change.

## 14. iPhone/iPad sync

On device A choose iCloud folder → write device registration + immutable changes → iCloud transports files → on device B select the same folder once → verify library ID → download/validate/decrypt if enabled → merge into local projection → surface conflicts → acknowledge → continue. Offline changes receive device/HLC IDs and merge later; no live database file is shared.

## 15. Windows preview

Download CI contract-web-twin artifact → run local static server/open preview → operate fixture-backed Today/Goals/Guided/Reader/Replan responsive flows. The twin cannot exercise PencilKit, real iCloud Drive, security-scoped Files, Apple Intelligence, notifications or device performance. Native acceptance still requires CI simulators or an iPhone/iPad.
