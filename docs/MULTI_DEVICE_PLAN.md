# Multi-device bridge plan

Goal: one Mac bridge serves several approved devices at once (for example an iPhone
and an iPad), all editing the same QC over one USB connection. Bluetooth stays the
only transport. The QC adapter, the helper's process protocol and the editor's
editing model stay as they are.

## Today's single-device assumptions

| Where | Assumption |
| --- | --- |
| `BLEPeripheral` | One `central`, one `ChunkReceiver`, one outgoing queue and transfer counter. A second central's subscription is ignored and its writes get `.writeNotPermitted`. `resetConnection()` removes the service, which drops every central. `onMessage` runs synchronously inside `didReceiveWrite`. |
| `BridgeSession` | One connection token, approval code, phone name, `authorized` flag, trust tuple, request-ID set and recovery state. `revoke()` disconnects the helper session. |
| Helper (`helper.py`) | One session; a second `connect` fails with `already_connected`. |
| `LiveBridgeBackend` | One `approved` flag and phone; `phoneLeft()` revokes everything; a confirmed `disconnect` revokes the bridge. USB requests run synchronously on the Bluetooth worker queue. |
| `MacBridgePresentation` / `mac/main.swift` | One `phoneName`, `approvalCode` and `trustedPhone`; phases describe one phone. |
| `RecentBridgeEdit` | No record of which device made the edit. |

The helper is already the right shape for sharing: it executes one request at a
time, and every write carries the last confirmed `revision`, so a write based on old
state fails with `stale_context` before it reaches USB. The editor already treats
`stale_context` on an edit or save as "reject, show the message, re-read the
snapshot" (`EditorCoordinator.swift:218-223`). Conflict safety therefore needs no
new mechanism. The work is splitting per-device state from shared state, and
keeping one device's slow USB request from stalling the others.

## Decisions

1. **Control model: every approved device can edit.** Concurrent edits are settled
   by the existing revision guard: the first write wins, the other device is told
   its edit was not applied and reloads. Alternative (one editor, others watch,
   explicit handoff) is simpler to explain but adds a handoff flow on both apps;
   revisit only if hardware testing shows frequent conflicts.
2. **Device limit: 4 admitted devices.** The limit counts admitted device sessions,
   not Bluetooth subscriptions, so a device over the limit can still be told why
   (see phase 2). Tune after the hardware pass.
3. **Approval is per device.** Each device compares its own code. Approving one
   device never approves another.
4. **Trust is owned by the bridge, not the connection.** "Trusted until Patchbridge
   quits" survives Bluetooth loss, as it does today. Trusted devices that are not
   connected do not count toward the limit.
5. **Sync stays polling.** Each editor already re-reads the snapshot every 2 s, so
   another device's edit appears within about 2 s. No push events in this plan.
6. **One USB session, owned by the bridge.** It opens when the first approved
   device sends `connect` and closes when the last approved device leaves. Every
   device must explicitly adopt each new helper session; none is moved onto it
   silently.
7. **Bluetooth never waits on USB.** Writes are acknowledged and framed on the
   Bluetooth queue; session state and helper calls run on the host's worker queue.
   A request that would miss its client's deadline is refused before it reaches USB,
   never run late.

## Phase 1: split shared and per-device state (Mac core)

Split `BridgeSession` into three types:

- **`DeviceSession`** (one per admitted device, ends on Bluetooth loss or revoke):
  connection token, approval code, device name, `authorized`, request-ID set, the
  Bluetooth identifier it is bound to, and `adoptedGeneration` (below).
- **`SharedUSBSession`** (one per bridge): the `HelperClient`, the helper
  `session_id`, a `generation` counter incremented every time the helper session
  changes (first connect, recovery, reconnect after the last device left), recovery
  state (`recovering`, `retryAt`, `retryDelay`), the `onMutation` hook, and the set
  of joined devices.
- **`TrustRegistry`** (one per app, stored in the Keychain): entries
  of trust token and device name. Bounded (8 entries; oldest evicted). Independent
  of active connections and of the device limit.

### Message handling

| Operation | New behaviour |
| --- | --- |
| `hello` | Creates a `DeviceSession` if there is room, otherwise replies `bridge_full` (phase 2 explains how an unadmitted device reaches this). A `trust_token` is looked up in `TrustRegistry`; a match authorizes the new session and refreshes the stored device name. A `device_id` (the phone's stable ID) keeps one trust entry per phone: trusting it again, or reconnecting with a token, drops its older entries. |
| `connect` | First joiner forwards `connect` to the helper. Later joiners do **not** forward it (the helper would answer `already_connected`); the bridge forwards a `snapshot` and returns a connect-shaped reply with the shared `session_id`, current `revision` and state. Either way the device's `adoptedGeneration` is set to the current `generation`. If the device is trusted, the reply carries its trust token. |
| `disconnect` | Removes the device from the joined set. Forwards `disconnect` to the helper only when the set becomes empty. Trust is unaffected. |
| `recover` | While recovering, unchanged: `device_unavailable` until `retryAt`, then the first device's `recover` reconnects the helper and increments `generation`. If the shared session is already healthy and newer than the device's `adoptedGeneration`, the bridge returns a connect-shaped reply for the current session (via a `snapshot`, never a second helper `connect`) and updates `adoptedGeneration`. |
| Any read or mutation from an **outdated** device (`adoptedGeneration < generation`) | Not forwarded. Replies `device_unavailable` with `retry_after: 0`, which sends the editor through its existing recovery path to `recover`. Mutation replies also carry `applied: false`, since the bridge provably did not send them. |
| Mutations from a current device | Unchanged apart from per-device request-ID de-duplication; the revision guard does the arbitration. `onMutation` also receives the device name. |
| Reads from a current device | Unchanged. |

The outdated-device rule covers a device that was backgrounded, or between
requests, while another device detected USB loss and finished recovery: its next
request carries an old session, so instead of reaching the helper and failing with
`stale_session` (which the editor can only answer with a manual reconnect), it is
routed through recovery.

### Trust

- Approving with "Trust" adds a `TrustRegistry` entry and returns its token on the
  device's next `connect`, as today.
- Bluetooth loss ends the `DeviceSession` only; the trust entry stays, so the device
  reconnects without a code. Entries are kept in the Mac's Keychain, so they also
  survive Stop, Quit and helper failure; only Revoke Trust (or eviction) ends them.
- **Revoke Trust** removes one entry. It does not disconnect that device if it is
  connected; its next connection needs a code (today's behaviour).
- A trust entry never reserves a device slot. A trusted device that reconnects when
  4 others are admitted gets `bridge_full` like any other.

### Failure scope

- Helper transport failure or Stop/Quit ends every device session. `TrustRegistry`
  is kept.
- USB loss pauses every device and starts shared recovery.
- One device's Bluetooth loss, denial or revoke ends only that `DeviceSession`.

### Tests (`CoreTests`, `LiveBridgeBackendTests`)

- Two devices join one helper session; the second `connect` never reaches the helper.
- A stale write from device B after device A's write returns `stale_context`.
- The helper disconnects only after the last device leaves.
- Revoking A leaves B's requests working.
- Recovery reconnects the helper once and both devices resume.
- **B returns after A has already recovered:** B's first read gets
  `device_unavailable` with `retry_after: 0`, its `recover` adopts the current
  session without a helper `connect`, and B's mutation sent before recovering is
  not forwarded and is marked `applied: false`.
- **Trusted reconnect after the transport session is removed:** approve A with
  trust, drop A's Bluetooth session, reconnect with the token and skip the code.
  Revoke Trust for A, reconnect, and require a code. Trust entries survive a full
  device limit but don't take a slot.

## Phase 2: Bluetooth peripheral, threading and admission (done)

### Per-central state

`CentralRouter` (new, no CoreBluetooth dependency, so it is unit-tested directly)
owns every central's transport state; `BLEPeripheral` is a thin CoreBluetooth
adapter around it.

- Each central, keyed by `CBCentral.identifier`, has its own receiver, outgoing
  chunks, `maximumUpdateValueLength`, transfer counter and an epoch, so a reply that
  arrives after the device left and came back is dropped.
- `didUnsubscribeFrom` clears only that central's entry and reports which device left.
- The "outgoing must be empty" write guard is per central, and `drain()` loops over
  all centrals with pending chunks when `peripheralManagerIsReady` fires.
- `BridgePeripheral` callbacks carry a device identifier:
  `onMessage(deviceID, message) -> PeripheralReply` and `onDisconnect(deviceID)`.
  `PeripheralReply` also tells the router whether the device is now admitted or
  should be released.
- **Per-device revoke without dropping everyone.** CoreBluetooth has no call to
  disconnect one central from the peripheral side, and the old `resetConnection()`
  (remove and re-add the service) dropped all of them. Revoke now ends that device's
  `DeviceSession`, and its next request gets a `revoked` error, so the app
  disconnects itself. A fresh `hello` from that device starts over. An invalid
  transfer resets only the offending central's state; the service is reset only
  when no other device is connected.

### Admission

Every subscribing central gets a transport entry, in one of two states:

- **Unadmitted** (no `DeviceSession`): may only send `hello`. Its receiver accepts a
  message of at most 4 KB (instead of the admitted 1 MB). Any other operation gets
  `invalid_request`. At most 4 unadmitted entries exist at once; a device beyond
  that gets no entry, so its writes get `.writeNotPermitted`. An unadmitted entry is
  discarded after replying `bridge_full`, on unsubscribe, or after 10 s without
  being admitted.
- **Admitted**: has a `DeviceSession` (created by `hello` when there is room).

This gives a device over the limit a real request/response path for `hello`, so it
receives `bridge_full` instead of a bare Bluetooth write failure, without
allocating a device session or a large buffer.

**Interim limit:** `LiveBridgeBackend.deviceLimit` is 1 until phase 3, because the
Mac shell still presents and approves one device. A second device gets
`bridge_full` end to end. For the same reason the shell keeps one trusted phone:
trusting a new phone replaces the previous one, as before.

### Threading: separate Bluetooth acknowledgement from USB execution

Previously `didReceiveWrite` called `onMessage`, which called `helper.request`
synchronously on the Bluetooth worker queue. With one device that was harmless,
because the editor never has more than one request in flight. With several, a
slow USB request from A (up to the 40 s helper timeout) would block CoreBluetooth
from delivering B's writes at all. B's write wouldn't be answered within the 30 s
Bluetooth (ATT) transaction timeout, which can break B's link. And when B's request
did run, two back-to-back 40 s requests put it at about 80 s, past the editor's
60 s timeout.

Structure as built:

- **Bluetooth queue** (new, private to `BLEPeripheral`): CoreBluetooth callbacks,
  chunk framing, write acknowledgements, admission and per-device in-flight
  tracking. It never waits on the host's queue. Replies it can give without the
  session (`invalid_request` before `hello`, a second request in flight) are
  answered here immediately.
- **Host worker queue** (existing, `MacBridgeModel`'s): `LiveBridgeBackend`,
  `DeviceSession`, `SharedUSBSession`, `TrustRegistry` and `helper.request`. The
  Bluetooth queue hands each complete message over with its arrival time and gets
  the reply back asynchronously.
  This differs from the earlier draft (session state on the Bluetooth queue, a
  separate USB queue): keeping session state with the helper calls avoids splitting
  every operation, including multi-request joins, across two queues. `hello` can
  wait behind a slow USB request, but it doesn't hold up any Bluetooth write.
- **Bounded admission:** at most one request per device is queued or executing
  (the editor already sends one at a time; a second one gets `busy`). So the host
  queue never holds more than one request per connected device.
- **Deadline check before execution:** when the host queue reaches a request, it is
  refused if it has waited longer than 15 s (60 s editor timeout, minus the 40 s
  helper timeout, minus margin for Bluetooth transfer). It's answered `busy` with
  `retry_after` and, for mutations, `applied: false`. A refused request never
  reaches the helper, so the outcome is certain. `hello` is exempt, since it needs
  no USB. A request that has started always runs to completion.
- Ordering stays strict: the host queue is serial, and mutations from different
  devices are executed in arrival order.
- Locally generated replies echo the request's `connection_id`, so the editor
  matches them to its connection.

## Phase 3: Mac backend and UI (done)

`LiveBridgeBackend`:

- `deviceLimit` is 4. The one-trusted-phone rule is gone; trust is per device.
- Each admitted device has a state (waiting for approval, approving, connected), kept
  in admission order. The bridge's phase is derived from all of them: a waiting
  approval comes first, then USB recovery, then any connected device, then any device
  still verifying, otherwise running. An event's own wording (for example a trusted
  reconnect) is shown only while its phase is still the bridge's phase.
- Approval queue: one approval card at a time, earliest first. Other devices see their
  own code and wait on "Approve on Mac" until their card is answered.
- Disconnect and denial affect only that device. QC state (preset, scene, unsaved)
  stays bridge-wide and clears when no approved device remains.

`MacBridgePresentation` and `mac/main.swift`:

- `phoneName`/`approvalCode` now describe the device on the approval card (or the first
  connected device), plus `waiting` (devices behind the card), `devices` (with each
  one's trust entry) and `trusted` (from `TrustRegistry`, with whether it's connected).
  `trustedPhone` is gone.
- Titles: "iPhone connected", "iPhone and iPad connected", "3 devices connected".
- A Devices list: connected devices with **Disconnect** and, when trusted, **Revoke
  Trust**; then trusted devices that aren't connected, with **Revoke Trust**. The
  bottom "Disconnect iPhone" button is replaced by the per-device rows.
- The approval card names the device ("Approve only if iPad shows the same code") and
  shows "1 more device waiting".
- The diagram's device node reads "2 devices" when more than one is connected.
- `RecentBridgeEdit` carries the device name; window rows show it before the context.
- `tools/package_mac.py` lists the new source files (`DeviceSession`,
  `SharedUSBSession`, `CentralRouter`).

Offline simulation (`BundledOfflineBackend`): the simulated iPhone and an optional
simulated iPad share one helper session. **Simulate another device** sends the iPad
through the approval card; **Simulate edit from other device** makes the iPhone's next
edit fail with `stale_context` until it reloads. USB recovery brings both back.
**Simulate slow USB request** was dropped: `busy` is produced by `CentralRouter`,
which the simulation doesn't use, and the router's tests cover it directly.

## Phase 4: iOS app (done)

Small changes; the editing model already copes with shared state.

- `bridge_full` on `hello`: the editor fails with the bridge's message plus
  "Disconnect one on the Mac, then try again." `EditorCoordinator.failure` is
  `.bridgeFull`, and the connect screen titles it "Too many devices on your Mac".
- `revoked` on any request: the editor fails with "Disconnected on your Mac.
  Reconnect to ask for approval again." (`failure` is `.revoked`; title "Disconnected
  on your Mac"). The Live Activity ends instead of reporting a lost connection.
- `busy`: an edit or save is rejected as not applied ("The bridge was busy with
  another device; try again.") with the confirmed value unchanged; it was never sent,
  so no reload is needed. A busy poll or recovery retry waits for `retry_after`. A busy
  loading step (`connect`, `capabilities`, `catalog`, the reload after a rejection) is
  retried after `retry_after`.
- `applied: false` on `device_unavailable`: "Edit not applied" / "Save not applied.
  Editing resumes after the QC reconnects." instead of "outcome unknown".
- `changed_by`: the bridge records the revision and device of the latest confirmed
  write. A `snapshot` or `stale_context` reply to a different device carries
  `changed_by` (the writer's name) while the QC is still at that revision, so a later
  physical change on the QC is never misattributed. The editor then says "Changed on
  iPad" instead of "Changed on the QC", and a rejected edit says "Not applied. iPad
  changed it first." Old apps ignore the field. A new helper session clears the record.
- No change to trust storage: `TrustStore` is already keyed by Mac, and each device
  holds its own token.

## Phase 5: verification (done offline; hardware pass not run)

- Unit tests per phase (above), plus `tools/check_offline.sh` with two simulated
  devices.
- Threading tests with a fake helper whose requests take a controllable time:
  - A's slow request does not delay acknowledgement of B's writes.
  - Several slow requests from different devices: a job that waited past 15 s gets
    `busy` and never reaches the helper; no reply arrives after the client's 60 s
    deadline.
  - A second request from the same device while one is queued gets `busy`.
- Admission tests: a fifth device sends `hello` and receives `bridge_full`; an
  oversized message from an unadmitted device is rejected; idle unadmitted entries
  expire.
- Hardware pass added to `docs/HARDWARE_VALIDATION.md`: iPhone and iPad on one
  bridge; approve both; edit on each; edit both at once and confirm one is
  rejected and both converge; revoke one; pull USB, recover on one device while the
  other is backgrounded, then foreground it; trusted reconnect after Bluetooth
  loss; quit the app on one device mid-edit; repeat with AirPods and a keyboard
  connected to the Mac.
- Diagnostics: events carry `device`, the bridge's admission-order number for the
  device (not its name), and helper requests sent for a device carry it too. The
  bridge also records `bridge_full`, `revoked` and `busy` refusals. See
  [diagnostics](DIAGNOSTICS.md).
- The hardware pass is in [hardware validation](HARDWARE_VALIDATION.md#two-device-bridge-pass)
  and has not been run.

## Out of scope

- Socket or Wi-Fi transport.
- Push state events (`subscribe`).
- Editor-handoff or view-only roles.
- More than 4 admitted devices.

## Order and size

Phases 1 and 2 can be built and unit-tested independently, then joined in phase 3.
Phase 2's threading change is the riskiest piece and should land with its tests
before the Mac UI work. Phase 4 depends on the `revoked`, `bridge_full`, `busy`,
`applied` and `changed_by` additions from phases 1–3. Phase 1 is the largest;
phase 4 is the smallest.
