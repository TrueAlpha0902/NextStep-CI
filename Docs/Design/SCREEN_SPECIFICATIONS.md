# Core Screen Specifications

## 1. Today

```text
iPad:   [Sidebar 250] [Today list ≤760] [Selected action 320]
iPhone: [Today header]
        [Must card]
        [Should cards]
        [Sync/replan status]
```

Priority: today outcome → must action → time/risk → CTA → rationale/materials → goal progress. iPhone cards omit long rationale until detail. Empty states distinguish setup incomplete, no scheduled work, all complete and infeasible plan. Offline cached actions can start; stale plan shows timestamp. VoiceOver reads action priority/title/time/deadline/risk/readiness before Start.

## 2. Guided Learning Package

```text
iPad:   [Step rail 220] [Reading/work 640–720] [Evidence 320]
iPhone: [Step title + progress]
        [one semantic step]
        [sticky Back / Next]
```

The top always shows action title, goal lineage, estimate and output. Source opens in place on iPad and full-screen on iPhone. Returning restores step and anchor. Error is localized to a step; source-unavailable disables unsupported claims but preserves user output. At AX sizes, all columns collapse into a stack.

## 3. Paper Reader and highlights

```text
iPad:   [page thumbnails optional] [Reader] [Highlight inspector 320]
iPhone: [Reader full screen]
        [bottom page/tool bar]
        [inspector sheet]
```

Header shows short title, page, access/verified state and Original. Tool selection never hides category meaning. Highlight tap selects exact anchor; inspector shows original quote/location, explanation and understanding/review. A legal source link failing retains metadata/anchor hash and offers retry/replacement. PDF rendering must not redraw during Pencil input.

## 4. Goal and milestone

```text
iPad:   [Goal list] [Header + timeline + outcomes] [Evidence/risk]
iPhone: [Goal header]
        [vertical milestone cards]
        [next evidence / actions]
```

Definition of done and next milestone precede percentage. Each date has authority badge. Blocked/infeasible states show missing evidence or capacity shortfall. Empty goal guides user to define an outcome rather than merely title a list.

## 5. Thesis / Project / Career Workspace

```text
iPad:   [Workspace/phase 240] [Artifacts & evidence] [Inspector 320]
iPhone: [Workspace picker] → [Phase list] → [Artifact detail]
```

Shared workspace shell; phase templates differ by domain. Every phase contains definition of done, required evidence/artifact, risk and one Next Action. Comparison tables on iPhone become stacked source cards with a separate full-screen comparison, not a compressed grid. Empty states seed the first evidence-backed decision.

## Light/Dark preview content

All five screens use identical fixture data in both modes so visual differences expose theming, not content changes. Each also has at least one offline/source-unavailable/AI-uncertain state in component previews. Exact preview IDs are in `MOCKUP_PREVIEW_MATRIX.md`.

## Device and safe-area behavior

- Respect sensor/home indicator and keyboard safe areas; sticky bars move above software keyboard.
- iPhone landscape Reader may show a narrow inspector only when ≥700 pt content remains.
- iPad pointer hover cannot be the only indication; Pencil hover is an optional preview.
- Sheets use medium/large detents; destructive confirmation is never a transient toast.
