# NextStep Design Tokens

Theme: **Japanese minimalism × fine lines × editorial draft feeling**. Tokens are semantic; feature code must not embed raw color/spacing values.

## Color

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `background.app` | `#F7F5EF` | `#151614` | root canvas |
| `surface.base` | `#FEFDF9` | `#1D1F1C` | cards/readers |
| `surface.elevated` | `#FFFFFF` | `#252824` | sheets/selected panel |
| `text.primary` | `#22231F` | `#F2F1EB` | body/title |
| `text.secondary` | `#62655E` | `#B8BBB3` | support/metadata |
| `divider` | `#D8D6CF` | `#41443E` | 1 pt rules |
| `accent.primary` | `#2E5E63` | `#8DB8BA` | primary control/focus |
| `status.success` | `#2F6B4F` | `#86C6A4` | completed |
| `status.warning` | `#8A5A16` | `#E8B96B` | risk/overdue warning |
| `status.error` | `#9C3D3D` | `#F09A98` | blocking error |
| `status.ai` | `#66558D` | `#B9A8E0` | AI proposal |
| `status.userConfirmed` | `#335F8A` | `#8EC0EA` | confirmed by user |
| `status.sourceVerified` | `#2F6B4F` | `#86C6A4` | verified source |
| `status.sourceUnverified` | `#7A6250` | `#D2B99E` | pending/unverified |

Highlight fills use a low-opacity background plus a dark/light semantic edge and an icon/label:

| Meaning | Light fill / edge | Dark fill / edge |
| --- | --- | --- |
| Core conclusion | `#F4DE78` / `#6E5A00` | `#6D5E20` / `#FFE68A` |
| Definition/formula/method/data | `#AFCDEB` / `#275477` | `#274A68` / `#A9D4F5` |
| Case/application | `#AFD9BE` / `#2C6240` | `#28543B` / `#A8E0BB` |
| Limit/risk/counterexample | `#F1BD83` / `#7A4215` | `#6B4524` / `#FFD0A0` |
| Knowledge/goal link | `#C9B6E4` / `#5C477A` | `#4D3E68` / `#D7C2FA` |

All foreground/background pairs must be measured in automated contrast tests. When Dynamic Type, Differentiate Without Color or Increase Contrast is active, labels and outlines remain explicit.

## Typography

Use `Font.system`/San Francisco and PingFang TC fallback. Citation may use New York/system serif; never bundle a paid font.

| Token | Style | Default |
| --- | --- | --- |
| `type.display` | system rounded, semibold | 34/41 |
| `type.pageTitle` | system, semibold | 28/34 |
| `type.sectionTitle` | system, semibold | 20/25 |
| `type.body` | system, regular | 17/24 |
| `type.supporting` | system, regular | 15/21 |
| `type.citation` | system serif, regular | 14/20 |
| `type.metadata` | system monospaced, medium | 12/16 |
| `type.annotation` | system rounded, medium | 13/18 |
| `type.button` | system, semibold | 17/22 |

All text uses semantic Dynamic Type styles. Explicit sizes above are design references, not fixed `Font.system(size:)` production values.

## Geometry

- Grid: 8 pt; micro spacing: 4 pt.
- Spacing: 4, 8, 12, 16, 24, 32, 48.
- Corner radii: 8 (small), 12 (card), 16 (sheet); no pill for general cards.
- Border: 1 pt; selected/Increase Contrast: 2 pt.
- Minimum control: 44×44 pt; Pencil primary target: 48×48 pt.
- iPad sidebar: 224–288 pt; inspector: 320 pt; reading column: 640–720 pt.
- iPhone horizontal margin: 16 pt; compact card gap: 12 pt.
- iPad content margin: 24–32 pt; max Today list: 760 pt.
- Motion: 180 ms state, 240 ms navigation; zero spring bounce for deadlines/source status. Reduce Motion uses opacity only.
- Shadow: elevated surface only, y=2/blur=12/black ≤8% light or 25% dark; borders remain authoritative.

Machine-readable values are in `tokens.json`.
