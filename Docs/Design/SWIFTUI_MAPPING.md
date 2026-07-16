# SwiftUI Component Mapping

## Architecture

Feature views consume immutable presentation state and send typed intents. They never access SQLite, iCloud URLs or model providers directly.

```swift
struct TodayScreen: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let state: TodayPresentation
    let send: (TodayIntent) -> Void
}
```

Use `NavigationSplitView` for regular iPad and `TabView` + `NavigationStack` for compact composition. Navigation is derived from a shared typed `AppRoute`; do not maintain separate product state by device.

## Mapping

| Design component | SwiftUI implementation |
| --- | --- |
| TodayActionCard | `Button`/`NavigationLink` containing semantic VStack; custom `ButtonStyle` |
| GoalProgressHeader | `Layout` switching HStack/VStack; `ProgressView` only with evidence label |
| MilestoneTimeline | custom `Layout`; vertical `LazyVStack` in compact/AX |
| GuidedLearningStep | enum-backed `ViewBuilder`, not Markdown WebView |
| Reader | PDFKit/UIKit representable + SwiftUI chrome/inspector |
| HighlightedPassage | anchored overlay/canvas; label in inspector/accessibility |
| Status badge | `Label` with semantic token and bordered capsule |
| Replan diff | `List`/`ForEach` over typed `PlanPatch` |
| Ink toolbar | `safeAreaInset` or draggable overlay; UIKit Pencil adapter beneath |
| Compact inspector | `.sheet` with detents; regular inspector is split column |

## Adaptive rules

- `LayoutMode` is derived from actual container: `threeColumn`, `twoColumn`, `compact`; never from `UIDevice` model.
- Force compact when Dynamic Type is accessibility size or available content <744 pt.
- Use `ViewThatFits` only for local control groups, not entire screen information architecture.
- Apply readable `frame(maxWidth:)` to text; do not stretch iPad cards to full detail width.
- Toolbar items move to a `Menu`/sheet by priority, but Start/Complete/Undo remain direct.

## Token API

Expose `NextStepColor`, `NextStepSpacing`, `NextStepRadius`, `NextStepMetrics` and environment-resolved color assets. Production text uses semantic styles and `@ScaledMetric` for non-text dimensions. Raw hex values appear only in asset/token definitions.

## Preview contract

Each core screen defines previews for:

- iPhone smallest supported portrait Light and a current large iPhone Dark.
- 11-inch iPad Light and 13-inch iPad Dark.
- iPad 1/3 compact width.
- AX5, offline/source unavailable or replan as applicable.

Previews use deterministic fixture IDs/dates/time zone and no live repository/network. UI tests launch with the same fixture seed and attach named screenshots.

## UIKit boundaries

PencilKit/PDFKit controllers receive identity + revision tokens. Delegate callbacks are fenced against page/source changes. Coordinator publishes small typed events; large drawing/PDF bytes stay outside SwiftUI state. All optional Apple Pencil features use availability/capability checks with touch/generic-stylus fallback.
