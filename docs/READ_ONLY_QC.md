# Read-only QC mode and offline recovery

The policy is implemented at the helper/adapter boundary, independently of the
screen. A read-only session permits only connect, disconnect, identify,
capabilities, snapshot, catalog, and subscribe. It rejects parameter/bypass edits,
preset/scene selection, save, and save-as before calling the adapter. Unknown
operations are also rejected. Request payloads cannot promote a session to writable.
Capabilities expose `access_mode: read_only` and only the read operations; device
identity also labels its access mode. The generic editor consequently renders all
parameters read-only and refuses edit/save proposals.

`ReadOnlyAdapter(USBAdapter(...))` is the actual USB policy composition. The source
helper supports an explicit `usb-read-only` mode for a later authorized hardware
session. It was not launched against USB during this work. Existing explicit
`usb` development mode remains writable; the modes must not be confused.

The packaged launcher supports live writable USB through `--usb`. For offline tests it supports
`--captured-read-only <qc-editor.json>` mode using the same helper protocol and
captured QC state. This mode never imports the USB transport. The captured files
remain external test inputs and are not included in the app.

## Swift integration

Use `HelperClient(bundle: appBundle, capturedFixture: fixtureURL)` to start the
bundled captured session, then give that client to `DeviceSession`. The helper
client records the read-only launch policy, and the bridge independently rejects
non-read commands before forwarding them. No caller-supplied command field can
change this policy. Authorization and connection/session/revision guards remain.

The full offline path is exercised as:

`EditorCoordinator → chunked messages → DeviceSession → bundled HelperClient →
ReadOnlyAdapter(CapturedAdapter) → captured state`

The generic coordinator loads the real fixture's preset and relevant metadata,
then polls for changes. It requires fresh connect/authorization handling after a
failure and never replays mutations. The designed iPhone and Mac screens now consume the shared coordinator and bridge state.

## Reproducible checks

```sh
/opt/homebrew/bin/python3 tools/package_mac.py
/opt/homebrew/bin/python3 tools/check_mac_package.py
PATCHBRIDGE_TEST_BUNDLE=1 tools/check_offline.sh
```

The last environment flag enables the packaged-helper Swift integration test;
without it that single test is skipped so source-only development does not depend
on an old or missing generated app. Build first to test current sources.

The captured adapter rereads its JSON fixture for every snapshot/catalog request.
Tests modify a temporary copy to simulate physical preset and scene changes. A
local `offline_fault` field can select `disconnect`, `crash`, or `slow` (three
seconds). These are test inputs for this dedicated offline adapter, not remote
commands and not features of the live USB adapter. Crash uses a dedicated helper
subprocess; a slow reply tests bounded process timeout and cleanup.

Checks cover:

- All writes denied by the helper without reaching an adapter, including payloads
  attempting to override the policy; the wrapper also independently denies execute.
- Forged writes denied by the Swift bridge, even when bypassing the editor model.
- Loading 16 blocks and metadata from the captured fixture with no editable controls.
- Polling physical preset/scene changes and receiving authoritative updated state.
- Simulated removal, process crash, and timeout clearing confirmed/pending state;
  fresh helper/session reload succeeds and stale callbacks cannot replace it.
- The real packaged USB adapter, protobuf schemas, and transport injected with
  memory HID: reads work and the read-only policy sends no mutation reports.
- Existing writable simulation and File CREATE tests still pass; RecallPreset SAVE
  remains unsupported.

The full run passes 33 Python tests, 42 Swift tests (including the bundled test),
and nine packaged USB fixture checks. Relocation/signature/environment-isolation
checks pass separately. These tests validate policy and software recovery, not
physical IOKit/Bluetooth unplug/reconnect behavior. Hardware testing remains a
separate session with the user present, initially reading only.
