# Component Inventory

Every component supports Dynamic Type, VoiceOver, keyboard focus where relevant, Light/Dark and explicit loading/error/offline semantics.

## Execution

### TodayActionCard

Shows priority label, title, time, deadline/risk, primary milestone, material readiness and one CTA. Default/pressed/selected use surface/border changes; completed moves to history; overdue uses warning icon + text; offline remains startable when assets are local; source unavailable replaces Start with Resolve source.

### GoalProgressHeader

Shows definition of done, measured progress, next milestone and risk. Never displays decorative percent without evidence. Estimated progress is labeled.

### MilestoneTimeline

Horizontal on wide iPad, vertical on iPhone/AX sizes. Nodes expose status text, date authority and evidence. Selected milestone opens detail; blocked shows reason.

### WhyTodayBlock

Renders deterministic reason codes in plain language, e.g. “Exam in 5 days; this unlocks Practice set.” AI may rewrite wording only when the original reason codes remain visible in disclosure.

### CompletionCriteriaBlock

Checklist of typed criteria, evidence state and override reason. Disabled until validation inputs exist; errors name the missing artifact/evidence.

### ReplanControl

Seven user intents: less time, too hard, already know, explanation, examples, delay, split/change method. Replan diff uses additions green +, moves blue arrow, removals strikeout/error-safe text and protected lock.

### LearningTimer

Optional elapsed/remaining display, Start/Pause/Stop. It never determines completion by itself and persists interruption state.

## Learning and sources

### GuidedLearningStep

Number/status, title, objective, estimated minutes and semantic content slots. Completed state preserves reopen; superseded is read-only.

### SourceCard

Title, type, access level, retrieved/access date, verified state and actions. Source unavailable preserves citation metadata and offers replacement/legal original.

### PaperCitationCard / OriginalFileLink

Citation card exposes authors/year/venue/DOI, peer review/preprint and access. Original link names destination and access level; never uses a bare “Read more”.

### HighlightedPassage / HighlightLegend

Passage uses semantic fill + 2 pt edge + category icon/label. Inspector exposes original location, AI explanation badge, objective, understood/review controls. Legend is always reachable in Reader.

### SourceConfidenceBadge

Uses labels: Verified, User confirmed, Unverified, Conflicting, Stale, Unavailable. Numeric confidence is reserved for proposals and never uses “verified”.

### AIGeneratedBadge / VerifiedSourceBadge

Small icon + text; never an unexplained sparkle/check color. Press reveals provenance/verification detail.

### QuizCard

One item, response control, confidence (optional), evidence-backed result and retry/remediation. Answer is not revealed until submission unless accessibility setting requests it.

### KnowledgeLink

Concept A—typed relation—Concept B with evidence count. Compact becomes two stacked labels and relation arrow.

### WeeklyCurrentAffairsCard

Event date, publication freshness, topic/goal, official/independent source count, uncertainty and follow-up. It cannot reach Ready without grounding policy.

## Ink

### InkToolbar

Docked/floating/minimized; current tool, color and width always visible. Wide mode shows presets; compact/iPhone shows current tool + eraser + undo and opens a detented palette. Left/right handed placement is configurable.

### BrushPresetButton

Tool-shaped sample, name, color/width; selected has 2 pt outline and VoiceOver state. Unsupported pressure/tilt is not shown as available.

### InkCandidateReview

Source thumbnail/strokes, recognized text, class/confidence, goal/date proposal and Confirm/Edit/Reject. AI never mutates source ink.

## State matrix

| State | Visual/action rule |
| --- | --- |
| default | base surface, actionable controls |
| pressed | subtle surface darken, no geometry jump |
| selected | 2 pt accent edge + selected accessibility trait |
| disabled | secondary text; reason remains readable |
| loading | fixed skeleton, accessibility “Loading” |
| completed | success icon/text; primary CTA becomes Review |
| overdue | warning/error icon + exact date text |
| error | inline recovery; raw technical details in disclosure |
| offline | cloud-slash + usable cached actions |
| AI uncertain | AI proposal label + evidence gap/action |
| source unavailable | metadata retained; source-dependent controls disabled |
