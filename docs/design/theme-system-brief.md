# Design brief: theme system and Appearance screen

Status: confirmed and built (2026-10-25). Two changes during the build:
- High-contrast hairlines are strong gray (#9a9a94 dark, #6b6b66 light), not ink, because full-ink hairlines made empty slots as heavy as filled blocks.
- The iPad connection popover is 400pt wide, so its Appearance screen keeps three cards per row.

## 1. Feature summary

Appearance changes from a single Stage/Daylight choice into four independent preferences: a **theme** (accent and tint), a **mode** (Dark, Light, Auto), **block colors** (Patchbridge or QC Match) and **High contrast**. Every theme has a dark and a light version. The player picks a theme for how it feels and a mode for the room they're in, and never picks "the light version of Midnight" as a separate item.

## 2. Primary user action

Pick a theme and see the whole app take it on at once. Mode is the second most common change (moving from a dark studio to a bright room), so it sits right under the themes as one segmented control.

## 3. Design direction

- **Color strategy:** Restrained, unchanged. Each theme is a tinted neutral ground plus one accent at no more than about 10% of a screen (the One Signal Rule). The block colors carry the color; the theme only changes the ground tint and the accent.
- **Scene:** a player tuning in a dim rehearsal room picks Midnight because they like it, then at an outdoor soundcheck in the afternoon flips Mode to Light without losing their theme.
- **Anchors:** iOS Settings › Display & Brightness (Light/Dark/Automatic as its own control), Apple Watch face color pickers (one accent applied everywhere), the Apple Home app (calm dark surfaces).

## 4. Scope

iPhone and iPad Appearance screens, the theme token model in `Theme.swift`, and every view that reads `PhoneTheme`. Production quality. The Live Activity follows mode and accent. The watch keeps its fixed Stage palette for now (`WristTheme`); a later change can sync the accent.

## 5. Theme set and tokens

Six themes. Caution, danger and the scene dot rules depend on mode, not theme, and keep today's Stage/Daylight values.

| Theme | Dark ground / accent / accent ink | Light ground / accent / accent ink |
|---|---|---|
| Stage | `#0d0e0a` / `#d1e14a` / `#161802` | `#f7f7f5` / `#5c6400` / `#ffffff` (today's Daylight) |
| Ember | `#070505` / `#ff6a3d` / `#1a0602` | `#f8f6f5` / `#a8360f` / `#ffffff` |
| Midnight | `#080a12` / `#9fb4ff` / `#0a0f24` | `#f5f6f9` / `#3a4fb8` / `#ffffff` |
| Mint | `#06100c` / `#6ef2c0` / `#03190f` | `#f4f8f6` / `#00704e` / `#ffffff` |
| Lavender | `#0d0a12` / `#c9a6ff` / `#1a0c33` | `#f7f5f9` / `#6a3fb8` / `#ffffff` |
| Mono | `#0b0b0b` / `#f2f2f2` / `#0b0b0b` | `#f6f6f6` / `#111111` / `#ffffff` |

Each theme also defines surface, raised, ink, muted and hairline in both modes, tinted toward its accent's hue (values in the mockup). Measured contrast:
- Dark mode: ink is at least 13:1 against the ground, muted at least 6.2:1, the accent at least 7.1:1, and accent ink at least 6.9:1 on the accent.
- Light mode: ink is at least 16.7:1, muted at least 6.8:1, the accent at least 5.7:1 against the ground, and white ink at least 6.1:1 on the accent.

**High contrast** applies to any theme:
- Ground and surfaces become pure black (dark) or pure white (light).
- Muted text moves close to ink: `#d6d6d0` in dark, `#333333` in light.
- Hairlines become 2px in the ink color, and block cells and chips get a 2px ink outline.
- Glass becomes solid.
- In light mode the accent deepens to at least 7:1 (Stage `#4a5000`, Ember `#8f2e0c`, Mint `#005c40`; the others already reach 7:1). Dark accents are unchanged, since all are at least 7.4:1 on black.

**Block colors** swap only the category table: fills, ink choice, and the arc shades for each mode. QC Match colors must be sampled from a unit; the values in the mockup are placeholders.

**Change from the previous option:** Ember uses the standard block colors. The dimmed fills from the Red Light idea drop to 1.8–3.3:1 against the ground and flatten the lightness steps that color-blind players rely on. Now that Ember is a color preference rather than a night-vision tool, they don't earn their place.

## 6. Layout (Appearance screen)

Top to bottom:
1. **Theme:** six cards, three per row on iPhone, two at large Dynamic Type sizes, one at accessibility sizes, six in a row on iPad regular width. Each card is a miniature of the overview drawn in the *current* mode and block table, so the cards preview what you'll actually get. The selected card has a 2px accent outline and a checkmark.
2. **Mode:** segmented control with Dark, Light and Auto, with one line beneath it explaining the current choice. At accessibility sizes it becomes an inline list of three rows with checkmarks.
3. **High contrast:** a switch row with the subtitle "Always on when Increase Contrast is on".
4. **Block colors:** segmented control with Patchbridge and QC Match, followed by the existing category legend, which shows the chosen table.
5. Footnote: "Scene colors always come from your QC."

## 7. Key states

- **Auto mode:** the cards and the screen follow the system setting live. The note reads "Follows your iPhone's Light and Dark setting."
- **Increase Contrast on in iOS Settings:** High contrast is forced on. The row shows "On" with the subtitle "On while Increase Contrast is on in Settings" instead of a switch, because a locked switch is a disabled control.
- **Reduce Transparency:** unchanged. Glass gives way to solid raised surfaces in every theme.
- **First launch after upgrade:** stored settings migrate as follows:
  - `appearance = "Daylight"` becomes theme Stage with mode Light.
  - `matchSystem = true` becomes theme Stage with mode Auto.
  - Everything else becomes theme Stage with mode Dark.
  - The old keys are deleted after migrating.
- **Demo mode:** themes apply as normal.

## 8. Interaction model

Tapping a card or a segment applies it immediately to the whole app (the sheet included), with a selection haptic. The re-theme is a 0.25s crossfade, and instant under Reduce Motion. No Save button: appearance is a preference, not device state. VoiceOver:
- Each card reads "Midnight, theme, selected" (or "not selected").
- The mode control is a standard picker.
- The block legend stays hidden from VoiceOver, as today.

## 9. Implementation notes

- `PhoneTheme(daylight:)` becomes `PhoneTheme(theme: ThemeID, mode: resolved Light/Dark, highContrast: Bool, blocks: BlockPalette)`, with a static token table for each theme and mode. Keep `daylight` as a computed property so call sites that only branch on light vs dark (scene dot edges, arcs) don't change.
- `BlockCategory.arc(daylight:)` reads from the active `BlockPalette`.
- New `@AppStorage` keys: `theme`, `mode` (dark, light, auto), `blockColors`, `highContrast`. Read in `EditorView`, `PadWorkspaceView` (settings row label) and `ConnectionActivityController` (which needs the accent hex as well as `daylight` for the Live Activity).
- The settings row label becomes "Midnight · Auto" (theme · mode).
- `--stage` / `--daylight` launch arguments map to mode; add `--theme <name>` for UI tests and screenshots.
- Update DESIGN.md's Themes section once this ships.

## 10. Open questions

- QC Match needs real colors sampled from a Quad Cortex before it can ship. Until then it can sit behind a debug flag.
- Should the watch follow the theme accent in a later change?
