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

These hardware results predate the live bridge and designed iPhone app below.
None of the live phone → Mac → USB path has run against the QC yet.

## Current software wiring

- **Mac bridge.** `dist/Patchbridge.app` opens stopped with live USB/Bluetooth
  selected. Start bridge advertises over BLE; USB opens only after a phone is
  approved and requests a connection. The bundled helper runs the pinned USB
  adapter (`--usb`), which exposes `set_parameter`, `set_bypass`, `select_scene`
  and File CREATE `save` only. `set_bypass` and the request queue fix were verified directly over
  USB on 2026-10-21, not yet through the bridge; see [USB results](USB_RESULTS_2026-10-21.md).
  **Use simulation** switches back to the bundled simulator with BLE and USB off.
  See [Mac bridge shell](MAC_BRIDGE_SHELL.md).
- **iPhone app.** The designed app drives `EditorCoordinator` over BLE. It loads
  capabilities, the snapshot, and the relevant catalog subset, then polls every 2 s
  while idle. USB loss retries connect with capped backoff and reloads state;
  edits and saves are never replayed. A local demo mode loads the captured fixture
  without a bridge. The old `amp-1` 0–10 simulation editor is no longer the phone UI.
- **Editable controls.** A parameter is editable only when the device marks it
  editable, it is not scene- or expression-assigned, and it has a declared conversion
  (explicit range with valid skew, or normalized enum steps). Everything else is
  shown read-only with a reason. The simulator's 0–10 range is never reused.

## Offline coverage

- BLE command completion waits for both the result and final ATT acknowledgment,
  in either arrival order. This prevents an old acknowledgment from advancing a
  newer command's chunks.
- Responses must match the pending request and connection. Disconnect discards
  partial messages and pending edits; stale Core Bluetooth callbacks are ignored.
- The bridge rejects duplicate command IDs and unsupported protocol versions.
  Request-ID tracking is bounded to 4096 commands per connection; reconnect to
  obtain a fresh session after that limit. There is no automatic command retry.
- USB preflight includes a hash of the full preset, catching routing and other
  changes that the parameter UI does not display. Missing scene values stay
  absent instead of borrowing another scene's data.
- Catalog option labels and symbolic ranges remain intact. Unsupported firmware,
  unknown controls, scene assignments, and expression assignments fail closed.
- Read-only captured sessions, helper crash, timeout, removal, and preset-change
  recovery pass through the packaged runtime. See [read-only QC mode](READ_ONLY_QC.md).

Run `tools/check_offline.sh` for Python, Swift and the simulated process/bridge
round trip. It never connects to hardware or starts BLE advertising. Then run the
[offline preflight](PREFLIGHT.md) after rebuilding; passing does not claim physical
QC or Bluetooth compatibility.

## Next session: first live end-to-end run

With the user present, Cortex Control closed, and the disposable preset
(`Tremonti w Mic`, My Presets 16) backed up:

1. Install the current iPhone build and a freshly packaged Mac app. Run the
   offline preflight first.
2. Start the bridge, connect from the phone, compare the approval code, approve.
3. **Read first.** Compare the phone's preset name, blocks, active scene, and a few
   values against the QC screen before touching anything. Note which parameters
   the phone offers as editable and which it shows read-only.
4. Make one reversible edit (Myth Drive gain), confirm readback on the QC, and
   restore it. Check that the Mac's recent-edits list matches.
5. Turn a knob on the QC and confirm the phone updates within a poll interval.
6. Save via File CREATE, switch away on the QC, recall the slot, and confirm the
   phone and QC both show the saved value.
7. Recovery, one at a time: background and reopen the phone; quit the helper
   during an edit; Bluetooth off/on; pull and reconnect the USB cable. Each must
   show a visible state and never replay an edit.
8. Record edit-to-confirmation latency and reconnection time as first baselines.
9. **Calibrate display curves.** Quit the Mac bridge first. Add a lookup-table
   block (Plugin Parametric-4), a LOG_SKEW block (Envelope Filter) and a
   toggleButton block (Vintage Digital reverb) to the disposable preset, or check
   `tools/calibrate_qc_controls.py --plan` for alternatives. Run the probe below
   and type what the QC shows for each value. Reload the preset without saving
   afterwards.

   ```sh
   PYTHONPATH=vendor/qc-mcp/src .venv-hardware/bin/python tools/calibrate_qc_controls.py
   ```

## Scene switching and settling (offline only so far)

- `select_scene` sends qc-mcp's `set_scene` (Scene UPDATE), waits up to 3 s for a Scene
  READ to report the new scene, then reads the preset back. A switch the QC never reports
  is `not_confirmed` (Outcome unknown), never Not applied, and is not retried.
- A snapshot that catches the QC mid-change (an unanswered read, or the preset or scene
  moving during the read) retries for 5 s, then answers `device_busy` with
  `retry_after`. The session survives and the phone polls again. Only 20 s with no
  settled read at all invalidates the session and starts recovery, as before.
- A write whose readback lands mid-change is `not_confirmed`: the session survives, the
  helper bumps its revision so no request builds on old state, and the phone reloads.

To check on hardware: tap scenes A–H from the phone and compare the QC; switch scenes and
presets on the QC itself during polling and during an edit, and confirm the phone keeps
its connection; confirm the QC's dirty flag doesn't change on a scene switch.

## Still unverified after that run

- Scene-specific parameter writes and amp-model controls.
- Display accuracy of nonlinear (skewed) conversions against the QC's own readout,
  until step 9 has run.
- Switching to another slot and back, preset selection, bypass, and Save As
  (not exposed by the USB adapter).
- Native asynchronous device events; the phone relies on polling.
- Simultaneous physical and remote edits. USB cannot make the read/write pair
  atomic, so the whole-preset hash check is the only guard.
