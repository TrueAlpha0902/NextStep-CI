# Mockup and Preview Matrix

The implementation must produce these high-fidelity native SwiftUI previews and CI screenshots. “High fidelity” means real tokens/components/fixtures and final responsive rules, not static marketing art.

| ID | Screen | Device/layout | Mode | Required visible proof |
| --- | --- | --- | --- | --- |
| `Today-iPad-Light` | Today | 11-inch, 3-column | Light | must/should, time, Why Today, risk, progress |
| `Today-iPhone-Dark` | Today | small iPhone portrait | Dark | tab, unclipped card, sticky CTA, sync |
| `Guided-iPad-Dark` | Guided Package | 13-inch, 3-column | Dark | step rail, source anchor, output/criteria |
| `Guided-iPhone-Light` | Guided Package | iPhone portrait | Light | sequential step, bottom Next, source state |
| `Reader-iPad-Light` | Paper Reader | 11-inch + inspector | Light | DOI/access, semantic highlight, anchor inspector |
| `Reader-iPhone-Dark` | Paper Reader | iPhone portrait | Dark | full reader, bottom tools, inspector affordance |
| `Goals-iPad-Dark` | Goal/Milestone | 13-inch | Dark | definition, timeline, date authority, evidence/risk |
| `Goals-iPhone-Light` | Goal/Milestone | small iPhone | Light | vertical milestones, no squeezed timeline |
| `Workspace-iPad-Light` | Thesis workspace | 11-inch | Light | phase, evidence/artifact, one Next Action |
| `Workspace-iPhone-Dark` | Career workspace | iPhone portrait | Dark | phase cards, gap/evidence, next action |

Additional acceptance captures:

- all five iPhone screens at AX5;
- Today and Reader in iPad 1/3 Split View;
- source unavailable, offline, AI uncertain, replan diff and sync conflict;
- Ink toolbar left-handed/right-handed and generic-stylus capability state in Phase 2.

Screenshot names use `NextStep-<platform>-<screen>-<mode>-<state>.png`. CI records fixture version, simulator model/OS, locale, content size category and commit SHA alongside files.

## Windows representation

The Beta 1 browser twin renders matching fixture IDs at 390×844 and 1024×1366 CSS viewports. It is allowed to prove responsive information hierarchy and contract behavior only. Every page displays a persistent non-native-preview banner; native screenshot IDs and browser-preview IDs are never interchangeable.
