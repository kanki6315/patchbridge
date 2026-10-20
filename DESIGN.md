---
name: Patchbridge
description: A native iPhone and iPad editor for the Quad Cortex. It keeps the familiar grid, presents it in iOS Liquid Glass, and is honest about device state.
colors:
  signal: "#d1e14a"
  signal-ink: "#161802"
  ground: "#0d0e0a"
  surface: "#161612"
  surface-raised: "#24241f"
  glass-fill: "#24241f99"
  hairline: "#2e2e29"
  ink: "#f2f2ee"
  ink-muted: "#b1b2ab"
  caution: "#ffc469"
  cat-dynamics: "#49af7e"
  cat-dynamics-ink: "#08120c"
  cat-drive: "#f59926"
  cat-drive-ink: "#221202"
  cat-amp: "#d02c2a"
  cat-cab: "#81614f"
  cat-modulation: "#b249ac"
  cat-delay: "#46a6ef"
  cat-delay-ink: "#021322"
  cat-reverb: "#79d4e4"
  cat-reverb-ink: "#031a1e"
  cat-wah: "#007c84"
  cat-capture: "#e5848c"
  cat-capture-ink: "#221012"
  cat-pitch: "#735cc7"
  cat-utility: "#86877f"
  cat-utility-ink: "#0d0e09"
  cat-light-ink: "#ffffff"
  danger: "#ff9683"
  scrim: "#00000073"
  daylight-ground: "#f7f7f5"
  daylight-surface: "#ffffff"
  daylight-ink: "#161611"
  daylight-ink-muted: "#555650"
  daylight-hairline: "#d1d1cd"
  daylight-signal: "#5c6400"
  daylight-signal-ink: "#ffffff"
  daylight-caution: "#9d5300"
  daylight-danger: "#ba2c25"
typography:
  display:
    fontFamily: "-apple-system, 'SF Pro Display', system-ui, sans-serif"
    fontSize: "30px"
    fontWeight: 700
    lineHeight: 1.1
    letterSpacing: "-0.02em"
  headline:
    fontFamily: "-apple-system, 'SF Pro Display', system-ui, sans-serif"
    fontSize: "26px"
    fontWeight: 700
    lineHeight: 1.1
    letterSpacing: "-0.015em"
  value:
    fontFamily: "-apple-system, 'SF Pro Display', system-ui, sans-serif"
    fontSize: "62px"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "-0.02em"
    fontFeature: "'tnum'"
  title:
    fontFamily: "-apple-system, 'SF Pro Text', system-ui, sans-serif"
    fontSize: "17px"
    fontWeight: 600
    lineHeight: 1.3
  body:
    fontFamily: "-apple-system, 'SF Pro Text', system-ui, sans-serif"
    fontSize: "15px"
    fontWeight: 400
    lineHeight: 1.35
    fontFeature: "'tnum'"
  caption:
    fontFamily: "-apple-system, 'SF Pro Text', system-ui, sans-serif"
    fontSize: "13px"
    fontWeight: 400
    lineHeight: 1.3
  label:
    fontFamily: "-apple-system, 'SF Pro Text', system-ui, sans-serif"
    fontSize: "11px"
    fontWeight: 700
    lineHeight: 1
    letterSpacing: "0.02em"
rounded:
  cell: "9px"
  sm: "12px"
  md: "15px"
  lg: "18px"
  panel: "20px"
  sheet: "28px"
  sheet-floating: "34px"
  pill: "999px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "24px"
components:
  button-primary:
    backgroundColor: "{colors.signal}"
    textColor: "{colors.signal-ink}"
    typography: "{typography.title}"
    rounded: "{rounded.pill}"
    height: "50px"
    padding: "0 24px"
  button-glass:
    backgroundColor: "{colors.glass-fill}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.pill}"
    height: "44px"
    padding: "0 14px"
  scene-chip:
    backgroundColor: "{colors.glass-fill}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    height: "44px"
  scene-chip-active:
    backgroundColor: "{colors.signal}"
    textColor: "{colors.signal-ink}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    height: "44px"
  block-cell-amp:
    backgroundColor: "{colors.cat-amp}"
    textColor: "{colors.cat-light-ink}"
    typography: "{typography.label}"
    rounded: "{rounded.cell}"
    height: "38px"
  param-tile:
    backgroundColor: "{colors.glass-fill}"
    textColor: "{colors.ink}"
    typography: "{typography.title}"
    rounded: "{rounded.lg}"
    height: "62px"
    padding: "0 12px"
  switch-on:
    backgroundColor: "{colors.signal}"
    rounded: "{rounded.pill}"
    width: "51px"
    height: "31px"
  grid-panel:
    backgroundColor: "{colors.surface}"
    rounded: "{rounded.panel}"
    padding: "8px"
---

<!-- SEED: drawn from concept direction D and the "iPhone PoC" page of the "Patchbridge concept directions" canvas (2026-10-20), not from shipped code. Rendered boards and their source are in docs/design/ (iPhone in screens/, iPad in ipad/). Re-run /impeccable document once the SwiftUI screens exist to capture the real tokens and components. Unprefixed color tokens are the Stage theme; daylight-* tokens are the Daylight theme. -->

# Design System: Patchbridge

## 1. Overview

**Creative North Star: "The Pedalboard Under Glass"**

Patchbridge puts the Quad Cortex's grid in your hand. The signal chain stays the hero: colored blocks in four rows of eight, scenes like footswitches, bypass you can see at a glance. The interaction layer floats above it as native iOS Liquid Glass, with header pills, the scene bar, the save bar, the editor panel and the number pad. The content layer is flat and opaque so the chain reads instantly. The control layer is translucent so it feels like part of the phone. The aim is the calm of the Apple Home app: dark, quiet surfaces, one confident accent, and controls that feel good to touch.

Patchbridge is calm, fun and precise. Calm comes from a near-black ground and plain-spoken state. Fun comes from the colored blocks, the big tactile gauge, and haptics on every step, never from decoration. Precision comes from tabular numerals, honest ranges, and a value you can always tap to type. The system rejects skeuomorphic plugin UI (no brushed metal, screws or photoreal faceplates), generic SaaS dashboards (no stat tiles or card grids for their own sake), toy apps (no bounce, confetti or candy palettes), and above all silent failure. A value never looks applied when the QC hasn't confirmed it.

The layout adapts to size class instead of shrinking. In portrait on a phone, the grid works as a map: you tap a row, and the row's blocks are listed below with summaries and bypass switches. In landscape on a phone, the full grid appears at full touch size with a slim inspector beside it. On an iPad or unfolded foldable (regular width), the grid, the row list, all eight scenes and a persistent block editor share one screen, so you never leave the overview to edit.

**Key Characteristics:**
- Dark, near-neutral ground tinted toward the olive brand hue; dark mode is the identity, not an option.
- One signal accent (chartreuse) for actions, selection and edit state.
- Block categories carry color, always paired with a text code and a shape state.
- Liquid Glass only on the floating control layer; the chain and lists stay flat.
- Confirmed vs. provisional state is encoded by line style (solid vs. dashed), never by color alone.
- The QC's grid layout is preserved, adapted to iOS size classes.

## 2. Colors: The Stage-Dark Palette

A near-black olive ground, one electric chartreuse signal, and a fixed set of category colors that differ in lightness as well as hue.

### Primary
- **Signal Chartreuse** (#d1e14a, canonical oklch(0.87 0.17 115)): primary buttons (Save to 3B), the active scene, switches in the on position, selection outlines around the current block and row, the pending-edit dashed outline, and the unsaved-changes dot. Text on it is always **Signal Ink** (#161802).

### Secondary
- **Category colors.** Each block category has a fixed color that is used everywhere that category appears: grid cells, list swatches, the editor's block chip, the gauge arc, and the editor glow.
  - **Dynamics Green** (#49af7e) with dark ink.
  - **Drive Amber** (#f59926) with dark ink.
  - **Amp Red** (#d02c2a) with white ink.
  - **Cab Clay** (#81614f) with white ink.
  - **Modulation Orchid** (#b249ac) with white ink.
  - **Delay Blue** (#46a6ef) with dark ink.
  - **Reverb Ice** (#79d4e4) with dark ink.
  - **Wah Teal** (#007c84) with white ink.
  - **Capture Coral** (#e5848c) with dark ink.
  - **Pitch Violet** (#735cc7) with white ink.
  - **Utility Graphite** (#86877f) with dark ink.
  - Each category's ink was chosen for contrast. The lowest is Modulation with white ink at 4.7:1; Wah is 5.0:1 and Pitch 5.1:1, and every dark-ink pairing reaches at least 5.3:1.
  - Categories come from the catalog's `category` string, never from the model name. Cabsim variants map to Cab, Neural Capture to Capture, Guitar Overdrive to Drive, Compressor to Dynamics. A category the app doesn't know uses Utility Graphite and keeps its text code.
- **Scene colors.** Scene names and colors come from the Quad Cortex (`scene_labels` and `scene_colors`, ARGB) and are shown exactly as the player set them. They are user data, not theme tokens.

### Tertiary
- **Caution Amber** (#ffc469): used only for edits the QC rejected or adjusted, always alongside a triangle icon and a short reason ("Not applied · scene changed").

### Neutral
- **Stage Black** (#0d0e0a, oklch(0.16 0.008 110)): the app background on every screen.
- **Board Surface** (#161612): the grid panel and other flat content containers.
- **Raised Surface** (#24241f): the solid fallback for glass when Reduce Transparency is on, and the track behind sliders.
- **Glass Fill** (#24241f at 60%): the translucent fill for all Liquid Glass controls.
- **Hairline** (#2e2e29): borders for empty slots, list dividers and panel edges.
- **Ink** (#f2f2ee): primary text and values (17:1 on Stage Black).
- **Muted Ink** (#b1b2ab): secondary text, block summaries and range hints (9:1 on Stage Black). Nothing dimmer than this is allowed for text.
- **Danger** (#ff9683): destructive actions only, such as Disconnect. **Scrim** (black at 45%) dims the screen behind sheets.

### Themes
Patchbridge ships a small set of themes rather than free color pickers. A theme owns every color in the app except scene colors: ground, surfaces, glass, ink, the signal accent, caution, danger and the block category table. The PoC has two themes, with a toggle that follows the iPhone's Light and Dark setting.
- **Stage** (default): the palette above. Dark, for dim studios and stages.
- **Daylight**: for bright rooms. The ground is near-white **Daylight Ground** (#f7f7f5) with pure white surfaces and panels, **Daylight Ink** (#161611, 16.9:1) and **Daylight Muted** (#555650, 6.9:1), and a 1px **Daylight Hairline** (#d1d1cd). Glass is white at 66% with a soft drop shadow. Chartreuse can't carry text or outlines on white, so Daylight's signal is deep olive **Daylight Signal** (#5c6400, 6.0:1 as text, with white ink at 6.4:1). **Daylight Caution** is #9d5300 (5.3:1) and **Daylight Danger** is #ba2c25 (5.6:1). Category block fills stay the same; gauge arcs use the category's deeper shade (oklch L ≈ 0.55–0.58) instead of the L 0.74 shade Stage uses.
- **Planned, not designed:** a "QC Match" theme that recolors rig-view blocks to match the Quad Cortex's own colors. It only swaps the category table; scene handling doesn't change.

### Named Rules
**The Theme Owns Everything But Scenes Rule.** Every color comes from the active theme except scene colors, which always come from the QC. Never recolor a scene to fit a theme, and never let a scene color stand in for the signal accent.

**The Scene Dot Rule.** Scene colors only ever fill dots and outlines, never text or large areas. Several QC colors (yellow #ffd236, green #45f862) are about 1.3:1 on Daylight Ground, so in Daylight every dot gets a 1.5px dark edge. The scene letter always sits beside the dot, because names and colors repeat ("RHYTHM" on E and F; the same blue on B and G). A blank name falls back to the letter alone, never an invented name.

**The One Signal Rule.** Chartreuse is reserved for actions, selection and edit state. It never appears as decoration, as a background wash, or on inactive elements. If chartreuse covers more than about 10% of a screen, something is decorated that shouldn't be.

**The Category Owns the Editor Rule.** In the block editor, the block's category color tints the ground (oklch chroma ≤ 0.012 at L 0.16) and casts one soft radial glow behind the gauge (at most oklch L 0.30, C 0.07). The editor is never a full-bleed category fill; the glass needs a calm field to float over. The gauge arc uses the category color raised to oklch L 0.74 so it reads on the dark ground.

**The Shape-Plus-Color Rule.** No state is carried by hue alone. Bypassed blocks have a dashed outline, struck-through code and the word "Bypassed". Pending values have a dashed outline. Rejected values get a triangle and a sentence. Category colors differ in lightness so they stay distinguishable for colour-blind players.

## 3. Typography

**Display Font:** SF Pro Display (system; -apple-system fallback)
**Body Font:** SF Pro Text (system)
**Label/Mono Font:** none. Numerals use SF Pro's tabular figures, not a monospace face.

**Character:** One system family in a few weights. It feels native and gets out of the way, so the blocks and numbers carry the personality. Every value uses tabular figures so digits don't shift as a slider moves.

### Hierarchy
In SwiftUI, every role maps to a Dynamic Type style and scales with it. The sizes below are the default-size reference from the concepts.
- **Display** (700, 30px, 1.1, −0.02em): the preset name on the overview. Large Title, bold.
- **Headline** (700, 26px, 1.1, −0.015em): the block name in the editor. Title, bold.
- **Value** (700, 62px, 1.0, tabular): the hero number inside the gauge. Scaled from Large Title with `@ScaledMetric`, and capped so it never collides with the arc.
- **Title** (600, 17px, 1.3): row headings, block names in lists, and button labels. Headline.
- **Body** (400, 15px, 1.35, tabular): parameter names, tile values and scene names. Subheadline.
- **Caption** (400, 13px, 1.3): block summaries, range hints and status lines. Footnote.
- **Label** (700, 11px, +0.02em): block category codes (AMP, DLY) inside grid cells and swatches. Caption 2, bold. Never set in all-caps tracked type above a section.

### Named Rules
**The Tap-the-Number Rule.** Every numeric value is itself the button for exact entry. There is no separate "Type value" control. Tapping the number turns it into a field with a signal-colored cursor and raises the glass number pad, which shows Cancel, the valid range and Set.

**The Steady Digits Rule.** Values always use tabular figures. If a number shifts sideways while you drag, the digits are proportional.

**The No Helper Text Rule.** Text earns its place only if it reports state (the QC's value, an edit's outcome, the connection) or a consequence the player can't see. Instructions, reassurance, and labels that repeat what the layout already shows are cut. If the interface needs a sentence to explain how it works, fix the interface. The status line is empty when there's nothing to report. Errors get one short sentence of consequence, never a paragraph.

**The Step Shows Its Precision Rule.** Values display at the precision of their step: one decimal for the default 0.1 step ("15.0 ms", "100.0 %"), two decimals only while fine steps are active ("−30.05").

## 4. Elevation

Depth comes from two layers, not from shadows on content. The **content layer** is flat and opaque: Stage Black ground, Board Surface panels, and solid category blocks with only a faint 1px top highlight. The **control layer** is Liquid Glass: translucent Glass Fill, a background blur of 20–30px with saturation boosted 1.6–1.7×, a 1px inner top highlight (white at 14–18%), and a 1px inner edge (white at 6%). Only floating sheets and the iPad editor panel add a soft ambient shadow underneath.

### Shadow Vocabulary
- **Glass edge** (`box-shadow: inset 0 1px 0 rgba(255,255,255,0.16), inset 0 0 0 1px rgba(255,255,255,0.06)`): every glass control, including pills, chips, tiles and ± buttons.
- **Sheet lift** (`box-shadow: inset 0 1px 0 rgba(255,255,255,0.16), 0 -10px 30px rgba(0,0,0,0.4)`): the number pad and any bottom sheet.
- **Panel float** (`box-shadow: inset 0 1px 0 rgba(255,255,255,0.16), 0 20px 50px rgba(0,0,0,0.35)`): the persistent editor panel at regular width.
- **Block highlight** (`box-shadow: inset 0 1px 0 rgba(255,255,255,0.35)`): the faint top edge on solid category blocks. These are not glass.

### Named Rules
**The Glass Floats Rule.** Glass belongs only to things that float over content: navigation, scenes, save, the editor panel, the number pad and editor controls. Signal-chain blocks, list rows and the grid panel are never glass. If you can't say what a glass element floats above, make it solid.

**The Layer Order Rule.** Stacking is fixed. Content (grid, rows, tiles) never sets a z-index. Above it come the save bar (10), toasts (20), the sheet scrim (30), then sheets and the number pad (40). A sheet always covers everything beneath it; nothing in the content layer may poke through.

**The Reduce Transparency Rule.** With Reduce Transparency on, every glass surface becomes solid Raised Surface (#24241f) with the same edge highlight. Text contrast must pass over the solid fallback and over the worst-case glass backdrop.

## 5. Components

Controls feel tactile, confident and native. They are big enough to hit with a guitar strapped on, quiet until touched, and respond with haptics.

### Buttons
- **Shape:** pills (fully rounded, 999px).
- **Primary:** Signal Chartreuse fill, Signal Ink label in Title weight, 50px tall with 24px horizontal padding (54px tall in the portrait save bar). Use one per screen: Save, or Set on the number pad.
- **Glass:** Glass Fill with the glass edge, Ink label, 44px tall. Used for back navigation ("‹ Presets"), the bridge status pill and Save As….
- **Round step buttons:** 54px glass circles holding − and +, placed beside the gauge under the ends of its arc. Each tap steps by 0.1 in display units with a selection haptic. Unknown or read-only controls hide them.
- **Pressed / Focus:** pressed scales to 0.97 and brightens the fill (150ms, ease-out-quint). Focus uses a 2px signal-colored ring offset by 2px. Disabled drops to 40% opacity and is never the only signal that something is unavailable.

### Chips
- **Scene strip:** shows the QC's state; it isn't a control while the bridge can't switch scenes. A heading line shows the active scene's dot and title ("Scene F · RHYTHM"). Below it, eight 40px cells A–H each hold the scene's color dot and letter. The active cell gets a fill, a 1.5px ring in the scene's own color, a larger dot, and in Stage a soft glow. Landscape uses 28×36 cells beside the preset name. Once the bridge advertises `select_scene`, the same cells become buttons; no new layout is needed.
- **Device tag:** a small 10px label ("QC") on a white-14% fill, marking a value that was last changed on the hardware.

### Cards / Containers
- **Grid panel:** Board Surface, 20px corners, a 1px edge at 6% white, 8px inner padding. It holds the 4×8 chain grid. The selected row sits in a white-9% band, outlined in Signal on portrait.
- **Block cells:** solid category fill with the category code in Label type. Cells are 38px tall with 9px corners in portrait (a map, used through its row), 54×56 with 12px corners in landscape, and about 80×70 with 15px corners at regular width, where the code sits top-left and up to two lines of the block name sit bottom-left. Empty slots have a 1px Hairline outline. Bypassed blocks have a dashed category-colored outline, a struck-through code and "Bypassed". The selected block gets a 2.5px Signal outline offset by 2–3px.
- **Row list:** 60px rows, each with a 42px category swatch, the block name in Title, a one-line summary of real values in Caption, and a chevron. Blocks with no editable parameter add a lock and "Read-only" to the summary, but still open so the player can see their values. A 2px Hairline line joins the swatches to show signal flow. A bypass switch replaces the chevron only once the bridge supports bypass writes; until then a bypassed block is shown by its cell treatment alone.

### Inputs / Fields
- **Switches:** standard iOS switches, 51×31. On is Signal; off is white at 18%.
- **Value field (tap-to-type):** the hero number. At rest it has no border. While the QC hasn't confirmed a change it gets a 1.5px dashed Signal outline. While you're typing it shows a solid 2px Signal ring with a cursor. When the QC rejects a change it gets a Caution outline plus a status line.
- **Number pad:** a custom glass bottom sheet with 28px top corners, because the iOS decimal pad has no minus key and values like −34.2 dB need one. A toolbar holds Cancel and the range ("−60.0 to +12.0 dB"). Below it are 50px keys in a 4-column grid (1 2 3 ⌫ / 4 5 6 ± / 7 8 9 . / 0 Set), with Set as the Signal key. Nothing is sent until you tap Set. Out-of-range input is never clamped silently: the ring and the range turn Caution, and Set is unavailable.
- **Approval code:** the connection token is shown as a short 6-character code split 3·3 ("4F7·K2Q") in a glass panel. The same code must appear on the Mac. The bridge currently uses a full UUID; deriving a short display code from it is an engineering change.

### Navigation
- **Getting the Mac app:** an iPhone can't install Mac apps, so the flow's job is to move the link onto the Mac with the least effort. "No Patchbridge on your Mac yet?" appears on Welcome, and "Not installed on your Mac? Get the Mac app" appears while searching. Both open **Get Patchbridge for Mac**:
  - **Send to my Mac** (primary): opens the iOS share sheet with the Mac App Store link. AirDrop is recommended because the link opens straight in the App Store on the Mac.
  - **Copy link**: a fallback for Messages, Mail or Notes, which sync to the Mac.
  - **A short link to type on the Mac**: for players who prefer typing. The address is a placeholder until a domain exists.
  - There's no QR code, because Macs don't scan them conveniently.
  - After sharing, **Link sent to your Mac** lists the three real steps on the Mac (install, open and connect the QC, come back), with Find my Mac as the primary action.
- **Connect flow:** Welcome (the three-node iPhone → Mac → QC diagram, three real setup steps, Find my Mac, Try the demo preset) → Choose your Mac → Approve on your Mac (short code, "I've approved it") → Reading the QC (skeleton; nothing is sent) → overview. Recoverable failures get full-screen states with one sentence of consequence and one action: connection ended, no reply (outcome unknown), Bluetooth off. Reconnecting always reloads the QC's state and never replays edits.
- **Phone portrait:** the overview is the bridge status pill (opens Connection details), a Demo badge in demo mode, the Display-weight preset name with "My Presets · 16" and the unsaved dot, and the scene strip. Below sit the grid map and the row list, with a glass save bar holding one action, "Save to My Presets 16". Save asks for confirmation in a floating sheet, then shows "Saving on the QC…" and a "Saved on the QC" toast. Tapping a row in the list pushes the block editor. Preset browsing and Save As are hidden until the bridge supports them.
- **Connection details sheet:** bridge, firmware and connection facts; what works right now (supported operations, from capabilities); App → Appearance; Disconnect in Danger.
- **Appearance:** two theme cards with live miniature previews (Stage, Daylight), a "Match iPhone appearance" switch, the active theme's block-color legend, and a note that scene colors always come from the QC.
- **Phone landscape:** a single top bar holds the status button, name and unsaved state, the scene strip and Save. The full grid with row numbers sits beside an inspector panel with "Edit block".
- **Regular width (iPad):** a top bar holds the preset name with "My Presets · 16" and the unsaved state, then the bridge status pill and "Save to My Presets 16". In landscape, scenes, grid and row list sit on the left and the persistent glass editor panel (400pt, 28px corners, Panel float) runs full height on the right. In portrait, scenes and grid run full width and the row list sits beside the panel. Tapping a block in the grid or list retargets the panel; nothing is pushed. The scene strip has room for each scene's QC name under its dot and letter. The row list is two columns in landscape, with no chevrons because rows don't navigate. In landscape the dial and tiles grow one step (dial ×1.12, 68px tiles) to fill the taller panel.
- **Popovers at regular width:** the number pad, Save confirmation and Connection details become popovers anchored to the value, Save and the status pill, with an arrow and no scrim. Appearance pushes inside the Connection popover. Popovers use a 95%-opaque glass so keys and text never read over content beneath. Toasts sit in the top bar's free space between the name and the status pill. The connect flow is a centred 460pt column, and loading draws a skeleton of the split layout. Compact-width multitasking (Split View, Slide Over) uses the phone layout.

### Parameter Gauge (signature)
This is the heart of the editor, modelled on Apple Home's controls. It is a 270° arc 240px across with a 16px stroke on a white-13% track, filled in the category's arc color up to the QC's confirmed value. A pending change extends past that as a dashed segment up to the requested value, with a 3px tick marking where the QC currently sits. The thumb is a 26px white circle. The hero number sits in the middle, with its unit beside it and the status line below. The arc follows the QC's knob travel (the normalized value), not display units, so a non-linear control sits where the hardware knob would.
- **Steps:** dragging snaps to 0.1 in display units, with a selection haptic at every step and a rigid haptic at the ends of the range.
- **Fine steps (0.05):** touch and hold the thumb, then slide outward, away from the dial, as with iOS's fine scrubbing. The value never moves: it stays centred in the dial and gains a second decimal ("−30.05"). Three quiet cues confirm the mode. The thumb fills with Signal inside a soft Signal halo, a single line "Fine · 0.05 steps" appears under the number in Signal (only in this mode), and a rigid haptic fires as the mode engages. There's no ruler, badge or other extra overlay. Sliding back inside the ring returns to 0.1 steps. Release sends the final value; intermediate values are coalesced and only the last one is guaranteed to be sent.
- **Value layout:** the number and its unit form one group, centred together on the dial's centre point, horizontally and vertically. The number is 48px (40px in fine mode, so the second decimal still clears the arc); the unit sits on the same line, baseline-aligned, at 18px in Muted Ink ("−34.2 dB"). A read-only value's lock joins the group on the left. The typing ring and pending outline wrap the whole group. At those sizes the widest values ("−34.2 dB", "400.0 ms") stay clear of the arc and thumb. There's no helper text under the number: the number reads as tappable on its own, and the line under it is reserved for fine mode. A read-only control shows its knob position as a percentage with a lock ("50 %").
- **Read-only:** for a control the QC doesn't describe well enough to convert, the arc is drawn in muted graphite up to the knob position, the thumb is a hollow ring, and the value is replaced by a lock and the position ("50 %"). Steppers and typing are hidden, and the status line gives the short reason ("Read-only · scale unknown").
- **Options:** an enum parameter swaps the gauge for large option buttons (72px, category-tinted when selected, with a check). Choosing one sends it immediately.

### Parameter Tiles
Tiles sit in a 3-column grid of 62px Home-style glass tiles, each showing the parameter name in Caption and its value in Body or Title. The active tile has a category-colored 1.5px border and a 22% category fill. One tile vocabulary covers every parameter type: numbers ("6.4"), option lists ("Crunch"), switches ("Off", muted) and units ("−3.0 dB"). A read-only parameter is drawn without glass: a faint fill, a 1px edge, a lock before the name, and a short reason in place of the value ("Scale unknown", "Meter", "Depends on Sync"). It never looks like a normal tile that ignores taps. While an edit is pending, the active tile takes the dashed Signal outline.

### Motion
State changes take 150–250ms with an ease-out-quint curve. The dashed-to-solid change on confirmation is a 150ms crossfade. Sheets and the iPad editor slide in over 250ms. There's no bounce, no elastic, and no choreography on load. Direct manipulation of the gauge, sliders and steppers is never eased. With Reduce Motion on, every transition becomes a crossfade.

## 6. Do's and Don'ts

### Do:
- **Do** show the QC's confirmed value first, and draw any change the QC hasn't confirmed yet as a dashed outline or dashed arc segment, with the status "Sending…". The tick on the arc shows where the QC still is, so the text doesn't need to repeat it.
- **Do** say what happened when an edit fails, in Caution Amber with a triangle icon and a short reason: "Not applied · scene changed".
- **Do** keep the unsaved state visible on every screen: a Signal dot plus "Unsaved", and a Save button within reach of the thumb.
- **Do** keep the QC's 4×8 grid and its rows. Adapt the layout to size class: a map plus row list in portrait, the full grid in landscape, and grid plus persistent editor at regular width.
- **Do** make every numeric value tappable for exact entry (the Tap-the-Number Rule), and show the valid range and step while typing.
- **Do** pair every category color with its text code, and every state with a shape or a word (the Shape-Plus-Color Rule).
- **Do** use touch targets of at least 44pt for everything you act on. The portrait grid map is the one exception: its cells select a row, and the row list below carries the full-size targets.
- **Do** fall back to solid Raised Surface (#24241f) under Reduce Transparency, and to crossfades under Reduce Motion.
- **Do** show scene names and colors exactly as the QC reports them, in every theme (the Theme Owns Everything But Scenes Rule).
- **Do** show state the bridge can report but can't change yet (scenes, bypass) as indicators, and add the controls only when the bridge advertises the operation.
- **Do** step values by 0.1, and offer 0.05 only through hold-and-slide-out fine steps.

### Don't:
- **Don't** build skeuomorphic plugin UI: no brushed metal, fake screws, photoreal amp faceplates, or knob renders lifted from DAW plugins.
- **Don't** look like a generic SaaS dashboard: no card grids, stat tiles, or corporate settings-app blandness.
- **Don't** look like a toy or a game: no bouncy or elastic animation, candy palettes, confetti, or cutesy copy. "Fun" never costs credibility.
- **Don't** fail silently. Values must never look applied when they aren't, connection loss must never be hidden, and unsaved changes must never be ambiguous.
- **Don't** clone the Quad Cortex. Don't copy Neural DSP trade dress, logos, or screen layouts pixel for pixel. Echo the concepts, not the artwork.
- **Don't** fill the editor edge to edge with the category color. Tint the ground and cast one glow (the Category Owns the Editor Rule).
- **Don't** put glass on signal-chain blocks, list rows or the grid panel (the Glass Floats Rule).
- **Don't** use chartreuse decoratively or on inactive elements (the One Signal Rule).
- **Don't** add a separate "Type value" button. The number is the button.
- **Don't** use text dimmer than Muted Ink (#b1b2ab) on Stage Black, or any text under 4.5:1 over the worst-case glass backdrop.
- **Don't** put a colored side stripe on rows or callouts, gradient text, or tiny uppercase tracked eyebrows above sections.
- **Don't** offer free color customization. Themes are curated sets that pass contrast as a whole.
- **Don't** show buttons for operations the bridge doesn't support yet (scene switching, bypass writes, Save As, preset switching).
- **Don't** invent scene names, guess a control's scale, or fill a value the QC didn't report.
