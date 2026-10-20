# Product

## Register

product

## Users

Quad Cortex owners playing at home, in a studio, or at rehearsal and soundcheck. The floor unit is the device they know, but bending down to its touchscreen is awkward, especially with a guitar on. They reach for the phone to see and tweak the current preset from where they stand or sit. A Mac running the Patchbridge bridge is nearby, connected over USB.

The job: dial in a tone. Read the signal chain, open a block, adjust amp and effect parameters, switch scenes, and save on purpose. Mid-set edits between songs are not the target. Soundcheck tweaks are.

A secondary surface is the Mac bridge window. It's a small status and authorization window that the player glances at to confirm the QC is connected, which phone is authorized, and whether anything has gone wrong.

## Product Purpose

Patchbridge is a native iPhone editor for the Quad Cortex. It talks over Bluetooth to a macOS bridge app that owns the USB connection. It should feel like the QC the player already knows, made easier to reach.

Success means two things:

- **The player trusts the state.** They always know what the QC actually holds: confirmed values versus pending edits, unsaved changes, the active preset and scene, and connection health. Physical edits on the unit show up on the phone.
- **It beats bending over the floor unit.** Seeing the chain and changing a value is faster and more comfortable than using the touchscreen.

## Brand Personality

**Calm, fun, precise.**

- **Calm:** state is never alarming or ambiguous. Disconnects and errors are stated plainly, with what to do next. Nothing shouts.
- **Fun:** this is a tool for making music, so it should feel good to touch. Controls respond with satisfying, physical-feeling motion and haptics, and colorful signal-chain blocks bring the instrument-y joy of the QC. The fun lives in the feel, not in jokes or decoration.
- **Precise:** numbers, units, and ranges are exact. Exact numeric entry is always available beside the slider. The app never guesses a range or rounds a value away silently.

The visual direction is native iOS with Liquid Glass. The QC's mental model (grid signal chain, category-colored blocks, scenes, presets) is carried into a modern iOS idiom. It should be familiar to a QC owner without cloning the hardware UI.

## Anti-references

- **Skeuomorphic plugin UI.** No brushed metal, fake screws, photoreal amp faceplates, or knob renders lifted from DAW plugins.
- **Generic SaaS dashboard.** No card grids, stat tiles, or corporate settings-app blandness.
- **Toy or gamified app.** No bouncy or elastic animation, candy palettes, confetti, or cutesy copy. "Fun" never costs credibility.
- **Silent failure.** Values must never look applied when they aren't. Connection loss must never be hidden. Unsaved changes must never be ambiguous. This is the most important anti-reference.
- **A Quad Cortex clone.** Don't copy Neural DSP trade dress, logos, or screen layouts pixel for pixel. Echo the concepts, not the artwork.

## Design Principles

1. **The device is the truth.** The UI shows confirmed QC state first. Optimistic edits are visibly provisional until the bridge confirms them, and rejected or adjusted edits are surfaced, never swallowed.
2. **Familiar model, native feel.** A QC owner should recognize their preset at a glance, with the chain, blocks, scenes, and bypass. Interaction follows iOS conventions and Liquid Glass materials, not the floor unit's touchscreen quirks.
3. **Easier than reaching down.** Every common edit, such as opening a block, nudging a value, toggling bypass, or switching scene, is a short, one-handed path with generous targets.
4. **Precision on demand.** Gestures are quick and approximate, and exact entry is always one tap away. Units, ranges, and nonlinear scales are shown honestly.
5. **Saving is a deliberate act.** Live editing and saving are separate. Unsaved changes are always visible, and nothing persists to the device by accident.

## Accessibility & Inclusion

- WCAG 2.2 AA baseline: 4.5:1 for body text and 3:1 for large text and UI components.
- **Dim-room legibility.** The interface must be readable in a dark studio or under soundcheck lighting without glare. Contrast holds up over Liquid Glass materials, where translucency must never wash out text or values.
- **Color-blind safe.** Block category colors are hue-heavy, so state like bypass, pending, error, or unsaved is never shown by color alone. Pair color with shape, icon, label, or fill change.
- Support Dynamic Type, VoiceOver labels and values on every control, and Reduce Motion and Reduce Transparency fallbacks. Liquid Glass gives way to solid surfaces when Reduce Transparency is on.
