# CorOS 4.1.1 compatibility gate

Status: **partially verified on CorOS 4.1.1**. See
[the dated results](USB_RESULTS_2026-10-20.md) for evidence, successful
File CREATE persistence, and the problematic RecallPreset SAVE experiments.
[Bypass writes and the qc-mcp request queue fix](USB_RESULTS_2026-10-21.md) follow.
The table below is the original procedure, not the current results ledger.

Use a disposable preset with Cortex Control closed. Record results from the
actual device before selecting or pinning a dependency. Do not interpret the
simulator tests as hardware evidence.

Record:

- Date, tester, Mac model/architecture and macOS version.
- QC model, hardware identity, firmware, and USB connection.
- Candidate repository URL, exact commit, license, dependency versions.
- Preset slot and backup; representative amp and effect models.

Run the following separately for each candidate from the plan:

| Test | Evidence to capture | Result |
| --- | --- | --- |
| Handshake | Device identity, firmware, session startup logs | Not run |
| Preset read | Compare block positions, scene, bypass, values with device | Not run |
| Catalog | Names, ranges, enum options, units and nonlinear scales | Not run |
| Writes | Numeric, switch, dropdown and nonlinear write/readback pairs | Not run |
| Scenes | Edit A, inspect B, return to A; check scene scope | Not run |
| Physical edits | Turn knob/touch control; capture event or polling latency | Not run |
| Persistence | Explicit save, switch away, reload and compare values | Not run |
| Reconnection | Remove USB during edits; reject stale writes after reconnect | Not run |
| Ownership | Close helper; verify QC can be opened again | Not run |

Separate transmission receipts from confirmed values. Document unsupported
operations, readback/polling requirements, timeout behavior and firmware mismatch
handling. Choose one library only after this evidence supports the first real
editing slice. Pin its commit and preserve its license notices when integrated.

## Two-device bridge pass

Status: **not run**. Offline tests cover the protocol, threading and UI logic for
several devices (see [the multi-device plan](MULTI_DEVICE_PLAN.md)); none of that is
evidence about real Bluetooth or USB. Run this on hardware before relying on more
than one device.

Use a disposable preset with Cortex Control closed. Before starting, quit and reopen
the Mac app, so the exported report covers only this pass.

Record:

- Date, tester, Mac model and macOS version, Patchbridge Mac and iOS versions.
- QC firmware and USB connection.
- Each device: model, iOS/iPadOS version, and the name it shows on the Mac.
- Other Bluetooth accessories connected to the Mac during the run.

| Test | Steps | Expected | Result |
| --- | --- | --- | --- |
| Approval queue | Open Patchbridge on the iPhone, then the iPad, before approving either | The Mac shows the iPhone's card with "1 more device waiting"; each device shows its own code. Approve the iPhone, then the iPad's card appears | Not run |
| Both connected | Approve both; let both load the preset | Mac title reads "iPhone and iPad connected"; both show the same values | Not run |
| Edits from each | Edit gain on the iPhone; wait 3 s; edit on the iPad | Each edit confirms; the other device shows "Changed on …" within about 2 s | Not run |
| Simultaneous edits | Edit the same control on both within about 1 s | One confirms; the other says "Not applied. … changed it first." and reloads; both converge on the confirmed value | Not run |
| Disconnect one | On the Mac, Disconnect the iPhone | The iPhone shows "Disconnected on your Mac"; the iPad keeps editing | Not run |
| Trusted reconnect | Approve the iPhone with Trust; quit and reopen its app; reconnect. Then quit and reopen Patchbridge on the Mac, start the bridge, and reconnect | No code either time; the Mac lists it as Trusted · connected. Revoke Trust; the next reconnect needs a code | Not run |
| USB loss, one backgrounded | Background the iPad; unplug USB on the Mac; wait; replug; foreground the iPad | The iPhone pauses and recovers; the iPad recovers on return without a manual reconnect; no edit is replayed | Not run |
| Quit mid-edit | Start an edit on the iPad and force-quit the app at once | The Mac drops the iPad; the iPhone is unaffected; the edit is either confirmed or absent, never applied later | Not run |
| Slow request | During a save on one device, edit repeatedly on the other | The other device's edits confirm or say the bridge was busy; no device disconnects; nothing confirms after its device gave up | Not run |
| Fifth device | With four devices connected, open Patchbridge on a fifth | The fifth shows "Too many devices on your Mac"; the others are unaffected | Not run |
| Radio load | Repeat Both connected, Edits from each and USB loss with AirPods and a Bluetooth keyboard connected to the Mac | Same results; note any extra latency or drops | Not run |

Afterwards, export a troubleshooting report from the Mac. Events carry a `device`
number (1 for the first device admitted, and so on), so check that approvals, requests
and rejections line up with the steps above. The report must contain no device
names, preset names or values.
