# Before reconnecting the QC

## What is established

- CorOS 4.1.1 direct USB reads and representative writes worked.
- File CREATE saved a changed preset and same-slot recall recovered that change.
- RecallPreset SAVE caused two observed error/restarts. It remains unsupported;
  the old reproduction scripts are disabled.
- The iPhone app installed wirelessly. Pairing, per-connection approval, and
  initial simulated snapshot transfer were observed on the physical phone.
- The user reports changing gain and saving the simulated preset successfully.
  This confirms the interactive BLE loop, not durability across a helper restart.

## Work completed offline

- BLE command completion waits for both the result and final ATT acknowledgment,
  in either arrival order. This prevents an old acknowledgment from advancing a
  newer command's chunks.
- Responses must match the pending request and connection. Disconnect discards
  partial messages and pending edits; stale Core Bluetooth callbacks are ignored.
- The bridge rejects duplicate command IDs and unsupported protocol versions.
  Request-ID tracking is bounded to 4096 commands per connection; reconnect to
  obtain a fresh session after that limit. There is no automatic command retry.
- The phone model is transport-injectable and tested without Bluetooth. Malformed,
  stale, missing, or uncertain state cannot become confirmed editor state.
- USB preflight includes a hash of the full preset, catching routing and other
  changes that the current parameter-only UI does not display. Missing scene
  values stay absent instead of borrowing another scene's data.
- The generic editor coordinator loads capabilities and relevant catalog subsets,
  caches by catalog/model identity, polls only when idle, and clears uncertain
  edits on failure. Offline tests include helper restart and stale callbacks.
  This data layer is compiled into the app but not yet wired to the existing screen.
- Catalog option labels and symbolic ranges remain intact. Unsupported firmware,
  unknown controls, scene assignments, and expression assignments fail closed.

Run `tools/check_offline.sh` for Python, Swift and the simulated process/bridge
round trip. It never connects to hardware or starts BLE advertising.

The read-only policy and packaged captured-state coordinator path now have offline
coverage, including removal, crash, timeout, and preset-change recovery. See
[read-only QC mode](READ_ONLY_QC.md). The packaged launcher remains offline-only;
activating real USB and connecting the designed screen remain explicit steps.

Run the [offline preflight](PREFLIGHT.md) after rebuilding and before the next
hardware session. Its report distinguishes software checks from the still-untested
physical QC and Bluetooth behaviors; passing does not activate live USB.

## Next session, with the QC still unplugged

1. Install the new iPhone build and restart the Mac demo when the user is ready.
   The previously installed app was deliberately not replaced while they were away.
2. Repeat gain edit, save, scene A/B, and refresh over BLE.
3. Background the app, reopen, and reconnect. Approve the new token. Verify that
   unsent/late edits do not replay and the full snapshot reloads.
4. Stop the Mac helper during an edit. Confirm a visible error, then restart and
   reauthorize. Do not replay the failed edit automatically.
5. Exercise Bluetooth off/on and an expired pairing/approval path once.

## Software gate before real QC edits from the phone

The phone is still intentionally a **simulation-only editor** (`amp-1`, gain 0–10).
The Mac BLE demo still launches only the simulated adapter. Do not merely change
that launch flag: the real USB snapshot uses different block IDs and normalized
values and exposes a narrower capability set.

The metadata normalizer and generic editor data model are implemented and tested
against captured evidence (see METADATA_AND_EDITOR_MODEL.md). Connect them to a
capability-driven, initially read-only QC overview and selected parameter editor. Only explicit numeric ranges and verified
conversions should become display controls. Unknown skew/ranges remain read-only;
never reuse the simulator's 0–10 range for a real parameter. Verify this layer
against the captured preset/catalog fixtures before deploying it.

Then reconnect the QC with the user present, Cortex Control closed and the
existing disposable preset backed up. Start read-only, compare the phone's
block/scene/value against the hardware, perform one reversible edit, confirm
physical-change readback, and finally test File CREATE save/reload. Physical USB
removal/reconnection and scene-specific parameter edits remain separate tests.

The new whole-preset hash and lifecycle fixes have offline coverage but have not
been revalidated on real USB/BLE hardware. An atomic read/write transaction is not
available; simultaneous physical edits still require conservative handling.
