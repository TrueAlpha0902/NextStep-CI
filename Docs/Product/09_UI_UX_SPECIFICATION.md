# 09 — UI/UX Specification

## Direction

Japanese minimalism × fine lines × editorial draft feeling. Quiet space, readable hierarchy and real user ink carry the draft quality. Important deadlines, DOI, citations, source/AI status and completion criteria always use stable system typography and explicit labels.

No ornamental dashboards, faux notebook clutter, glow, heavy glass or status conveyed only by color.

## Responsive system

| Width/context | Navigation | Content behavior |
| --- | --- | --- |
| iPad ≥1024 pt | 3-column where useful | sidebar 224–288, reading 640–720, inspector 320 |
| iPad 744–1023 / half split | 2-column | inspector becomes sheet/popover |
| iPad ≤743 / one-third split | compact | same one-column composition as iPhone |
| iPhone portrait | 5-tab + stacks | progressive disclosure, sticky primary action |
| iPhone landscape | compact split only for reader when space permits | controls remain 44 pt and avoid content obstruction |

Layouts recompose by horizontal size and measured container; they do not branch on device model. Cards have max readable widths and do not stretch text across iPad.

## Core screens

### Today

Purpose: begin the correct action immediately. Priority: main outcome → must action → time/risk → Why Today/materials → optional action.

- iPad: goal progress header, action list and selected-action preview.
- iPhone: summary header and vertical cards; card tap opens full Guided Package.
- States: setup empty, no capacity, complete day, loading skeleton, offline/current plan, stale/replanning, conflict and error.

### Guided Learning Package

Purpose: remove preparation decisions and produce the required output.

- iPad: step rail, 640–720 pt content, optional evidence/definition inspector.
- iPhone: full-screen sequential steps and bottom Start/Next/Complete bar.
- Always expose goal lineage, time, output, criteria and source status; timer is optional and never required for completion.

### Paper Reader / highlights

Purpose: read exact required passages with trustworthy provenance.

- iPad: reader + 320 pt highlight/source inspector.
- iPhone: reader full-screen; page controls overlay minimally; inspector is a detented sheet.
- Highlight toolbar includes semantic text/icon labels. Original source link, DOI/access and unavailable state remain visible.

### Goal and milestone

Purpose: understand outcome, next evidence and risk—not decorative percentages.

- iPad: goal header, milestone timeline and selected milestone evidence/actions.
- iPhone: summary followed by collapsible milestone cards; timeline becomes vertical.
- Progress states distinguish measured, estimated, blocked and source/user-confirmed.

### Thesis / Project / Career workspace

Purpose: manage lifecycle artifacts and derive concrete action.

- iPad: phase sidebar, artifact/evidence workspace and inspector.
- iPhone: workspace picker → phase list → artifact detail. Tables become cards or horizontal comparison sheets, not squeezed columns.
- Each phase shows definition of done, missing evidence and one Next Action.

## Component states

TodayActionCard, GoalProgressHeader, MilestoneTimeline, GuidedLearningStep, SourceCard, PaperCitationCard, OriginalFileLink, HighlightedPassage, HighlightLegend, confidence/status badges, CompletionCriteriaBlock, WhyTodayBlock, ReplanControl, LearningTimer, QuizCard, KnowledgeLink and CurrentAffairsCard each support:

`default`, `pressed`, `selected`, `disabled`, `loading`, `completed`, `overdue`, `error`, `offline`, `aiUncertain`, `sourceUnavailable`.

Only semantically possible states render; e.g. a SourceCard adds verified/unverified, while a Timer does not claim source verification.

## System states

- Empty: state why it is empty and one concrete primary action.
- Loading: skeleton geometry matches final layout; never show a fake percentage.
- Offline: local actions remain operable; network-only controls show queued/unavailable.
- Source unavailable: metadata/annotations preserved, unsupported content disabled, legal replacement action offered.
- AI uncertainty: label proposal, confidence range and evidence gaps; confidence never substitutes for verification.
- Replanning: show trigger, protected facts, exact diff and confirmation need.
- Sync: local-only/uploading/current/conflict/paused/provider-unavailable with last successful time.

## Handwriting interaction specification

### Tool behavior and rollout

| Tool | Learning behavior | Phase |
| --- | --- | --- |
| ballpoint | crisp stable width; optional pressure; smoothing | V1 |
| pencil | grain/depth, pressure and Apple Pencil tilt shading when available | V1 |
| technical pen | very fine stable line for formulas/tables/diagrams | V1 |
| semantic highlighter | translucent, text-line/straight-line snap where supported, creates SourceAnchor | V1 |
| fountain pen | pressure/tilt/direction taper for headings | Phase 2 |
| marker | wide opaque classification/title stroke | Phase 2 |
| soft/brush pen | pressure/direction taper; secondary creative tool | Phase 2+ |

Ballpoint, pencil, technical pen and highlighter expose only applicable quick parameters: color, three common widths and opacity when meaningful. Advanced settings reveal pressure/tilt, smoothing/stabilizer, tip, edge, texture, start/end taper, velocity and blend only for tools that implement them. Recent/favorite presets and purpose sets (class, formula, PDF, highlight, sketch, diagram) avoid one overloaded control panel.

The semantic highlighter always exposes yellow conclusion, blue definition/formula/method/data, green case/application, orange limit/risk/controversy and purple knowledge/goal link. A visible legend/icon/name accompanies color.

### Toolbar and capability gates

The toolbar includes brush/preset, color, width, opacity, eraser, lasso, shape, ruler, undo/redo, zoom, page, layers and AI actions. V1 enables the scoped tools and clearly labels later unavailable tools; it does not ship dead controls in production. It supports docked/floating/minimized, left/right-handed placement, reorder, long-press settings, keyboard shortcuts and optional hover/double-tap/squeeze actions.

Apple Pencil features use runtime availability; a generic third-party stylus is treated as touch input and is never promised pressure, tilt, hover, double-tap or squeeze.

### Erase, select and transform

- V1 Pixel Eraser removes contact regions; Stroke Eraser removes entire strokes. Size is adjustable and Pencil double-tap may switch when available.
- Phase 2 adds Segment Eraser, highlighter-only erase and opt-in scratch-out with immediate Undo; destructive gestures never run without a reversible command.
- Free/rectangular lasso supports V1 move/scale and selection→task candidate. Later commands include rotate, copy/cut/paste/duplicate/delete, group, page/layer move, style change, image/text conversion and same-type selection.
- AI selection actions (recognize, explain, summarize, flashcard, action, learning gap, exam emphasis, goal link, paper search, practice/package) always show a preview and never alter source strokes.

### Shapes, templates and layers

Shape scope covers line/arrow/rectangle/circle/ellipse/triangle/polygon/axes/table/flow node/relation/bracket/divider. Recognition offers “keep hand drawn” or a reversible standard shape. Concept nodes can link to `KnowledgeConcept`; this is Phase 2 after the V1 ink-to-action loop.

Templates: blank, ruled, grid, dot, Cornell, class notes, formula, mind map, reading summary, paper reading, weekly review, interview practice and project sketch. V1 ships blank/ruled/grid/dot. Background, spacing, opacity, size, orientation, margins, header/footer are non-destructive template settings.

Layer types are source document, user ink, highlight, shapes/images, AI suggestion, recognized text and teacher/collaborator feedback. V1 persists the role even when advanced reorder UI is deferred. AI content never shares the user-ink layer.

## Accessibility

- 44×44 pt minimum targets; Pencil hover/squeeze/double-tap are optional shortcuts.
- Body supports Dynamic Type through AX5 without truncating deadlines/criteria; larger sizes become one column.
- VoiceOver order follows goal→action→reason→time→status→primary action. Canvas has page/tool state, alternative recognized text and accessible undo.
- Status combines icon, label and color. Highlight semantics are announced.
- Reduce Motion uses cross-fade/no parallax; Increase Contrast strengthens dividers/status outlines.
- iPad supports keyboard focus, shortcuts and pointer; iPhone remains fully touch/VoiceOver usable.

Detailed tokens, components, screen layouts and preview matrix are under `Docs/Design`.
