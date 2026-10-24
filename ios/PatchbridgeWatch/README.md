# Patchbridge for Apple Watch

A native watchOS 10+ companion, embedded in the iPhone app. Choose the
`PatchbridgeWatch` scheme in `ios/Patchbridge.xcodeproj` and a paired Apple Watch.
Regenerate the project with `xcodegen generate --spec ios/project.yml`.

Swipe between Now Playing, Tuner, and Quick Adjust:

- **Now Playing:** confirmed preset and scene, connection state, unsaved changes,
  scene selection and a preset browser. Loading a preset requires confirmation;
  resolve unsaved edits on iPhone first. The watch lists the first 32 named slots;
  use iPhone for the complete list.
- **Tuner:** QC pitch (not the watch microphone), cents, a tuning scale, and
  confirmed output mute. Only a visible, active tuner requests readings. Its
  three-second lease expires if the watch stops checking in, without closing a
  tuner that the phone itself has open. Entering the tuner never requests mute.
- **Quick Adjust:** tap the block name to choose a numeric control, tap Adjust,
  turn the Digital Crown, then Apply. Drafts are explicitly marked. The last
  chosen control is remembered per preset. The watch exposes up to 64 supported
  numeric controls; unsupported, expression-controlled and read-only controls
  are excluded. Category colors match the phone's Stage gauge palette.

## Connection and safety

Keep Patchbridge **open and active on the paired iPhone**, connected to its Mac
bridge. iPad alone cannot host this watch session. Locked-phone/background
operation is not supported in this version: the existing coordinator pauses
background tuner traffic. Both the watch and phone reject actions when the host
is inactive. No account or additional Mac authorization is introduced.

Watch Connectivity uses immediate request/reply data only, never queued background
commands. The watch polls at 2 Hz while active, allows one message at a time,
marks state unavailable after three seconds without a reply, and times out after
four seconds. A late reply is ignored. Commands are never retried automatically.
The phone rejects expired, replayed, or changed-context commands, checks current
capabilities and ranges, then uses the existing confirmed-state coordinator.
A successful delivery is not presented as QC confirmation. On an uncertain
outcome, inspect the QC before trying again. Preset saving stays on iPhone.

## Verification

The Debug-only `--demo` launch argument supplies local, labeled sample data.
Add `--tuner` or `--adjust` to open those pages directly. Demo edits never reach
Watch Connectivity, Bluetooth, or USB.

Build the iOS scheme using `-destination 'generic/platform=iOS Simulator'`
without a global `-sdk iphonesimulator` override: each embedded target needs
its own platform SDK. The Watch scheme also builds with
`-destination 'generic/platform=watchOS Simulator'`.

`WatchCompanionTests` covers protocol round trips, command expiry, duplicate
commands, and invalidation when the preset context changes. Before release,
verify a paired physical watch/iPhone/Mac/QC session, including scene and preset
changes, confirmed/adjusted writes, mute transitions, phone locking, loss of
reachability, Crown and VoiceOver interaction, and both small and large watches.
The development Mac currently lacks a watchOS simulator runtime, so rendered
watch UI and end-to-end pairing have not yet been validated.
