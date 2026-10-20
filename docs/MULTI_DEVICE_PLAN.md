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
   Bluetooth queue; helper calls run on a separate USB queue. A request that would
   miss its client's deadline is refused before it reaches USB, never run late.

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
- **`TrustRegistry`** (one per bridge, cleared on Stop/Quit/helper failure): entries
  of trust token and device name. Bounded (8 entries; oldest evicted). Independent
  of active connections and of the device limit.

### Message handling

| Operation | New behaviour |
| --- | --- |
| `hello` | Creates a `DeviceSession` if there is room, otherwise replies `bridge_full` (phase 2 explains how an unadmitted device reaches this). A `trust_token` is looked up in `TrustRegistry`; a match authorizes the new session and refreshes the stored device name. |
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
  reconnects without a code until Patchbridge quits.
- **Revoke Trust** removes one entry. It does not disconnect that device if it is
  connected; its next connection needs a code (today's behaviour).
- A trust entry never reserves a device slot. A trusted device that reconnects when
  4 others are admitted gets `bridge_full` like any other.

### Failure scope

- Helper transport failure or Stop/Quit ends every device session and clears
  `TrustRegistry` (as today).
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

## Phase 2: Bluetooth peripheral, threading and admission

### Per-central state

In `BLEPeripheral`:

- Replace `central`, `receiver`, `outgoing`, `outgoingIndex` with a dictionary keyed
  by `CBCentral.identifier`, each entry holding its own receiver, outgoing chunks,
  `maximumUpdateValueLength` and transfer counter.
- `didUnsubscribeFrom` clears only that central's entry and reports which device left.
- Make the "outgoing must be empty" write guard per central, and `drain()` loop over
  all centrals with pending chunks when `peripheralManagerIsReady` fires.
- Change the `BridgePeripheral` callbacks to carry a device identifier, and make
  message handling asynchronous:
  `onMessage(deviceID, message, reply: ([String: Any]) -> Void)`,
  `onDisconnect(deviceID)`.
- **Per-device revoke without dropping everyone.** CoreBluetooth has no call to
  disconnect one central from the peripheral side, and `resetConnection()`'s
  remove-and-re-add drops all of them. Instead: invalidate that device's
  `DeviceSession` (its next request gets a new `revoked` error code), discard its
  receiver state, and let the app disconnect itself. Keep the service reset for
  protocol errors only when no other device is connected; otherwise reset just the
  offending central's state.

### Admission

Every subscribing central gets a transport entry, in one of two states:

- **Unadmitted** (no `DeviceSession`): may only send `hello`. Its receiver accepts a
  message of at most 4 KB (instead of the admitted 1 MB). Any other operation gets
  `invalid_request`. At most 4 unadmitted entries exist at once; beyond that, writes
  get `.insufficientResources` at the Bluetooth level. An unadmitted entry is
  discarded after replying `bridge_full`, on unsubscribe, or after 10 s without a
  `hello`.
- **Admitted**: has a `DeviceSession` (created by `hello` when there is room).

This gives a device over the limit a real request/response path for `hello`, so it
receives `bridge_full` instead of a bare Bluetooth write failure, without
allocating a device session or a large buffer.

### Threading: separate Bluetooth acknowledgement from USB execution

Today `didReceiveWrite` calls `onMessage`, which calls `helper.request`
synchronously on the Bluetooth worker queue. With one device that was harmless,
because the editor never has more than one request in flight. With several, a
slow USB request from A (up to the 40 s helper timeout) blocks CoreBluetooth from
delivering B's writes at all. B's write isn't answered within the 30 s Bluetooth
(ATT) transaction timeout, which can break B's link. And when B's request does run,
two back-to-back 40 s requests put it at about 80 s, past the editor's 60 s timeout.

New structure:

- **Bluetooth worker queue** (existing): CoreBluetooth callbacks, chunk framing,
  write acknowledgements, admission, and all `DeviceSession` / `SharedUSBSession` /
  `TrustRegistry` state. Nothing on this queue blocks on USB. Operations that need
  no helper call (`hello`, rejections, outdated-device replies, `busy`) are answered
  here immediately.
- **USB queue** (new, serial): only `helper.request`. The Bluetooth queue enqueues a
  job with the request and its enqueue time; the result hops back to the Bluetooth
  queue, which updates revision, session and generation state and then sends the
  reply chunks.
- **Bounded admission:** at most one request per device is queued or executing
  (the editor already sends one at a time; a second one gets `busy`). So the USB
  queue never holds more than 4 jobs.
- **Deadline check before execution:** when the USB queue reaches a job, it is
  refused if it has waited longer than 15 s (60 s editor timeout, minus the 40 s
  helper timeout, minus margin for Bluetooth transfer). It's answered `busy` with
  `retry_after` and, for mutations, `applied: false`. A refused job never reaches
  the helper, so the outcome is certain. A job that has started always runs to
  completion; it is never cancelled mid-request.
- Ordering stays strict: the USB queue is serial, and mutations from different
  devices are executed in arrival order.

`LiveBridgeBackend`'s doc comment ("Owns USB/session state on the same worker
queue as the Bluetooth peripheral") changes to describe this split: state stays on
the Bluetooth queue, helper I/O moves off it.

## Phase 3: Mac backend and UI

`LiveBridgeBackend`:

- Track connected devices as a list (name, approval state, trusted, last activity).
- Approval queue: one approval card at a time; a second device's `hello` waits
  (its app stays on "Approve on Mac") until the first card is answered.
- `phoneLeft(deviceID)` and `revoke(deviceID)` affect only that device. The
  connected/idle phase follows "at least one approved device".
- Shared `snapshot` and `catalog` caches for the status view stay bridge-wide.

`MacBridgePresentation` and `mac/main.swift`:

- Replace `phoneName`/`approvalCode`/`trustedPhone` with a `devices` array, a
  `pendingApproval` (name and code), and a `trusted` list from `TrustRegistry`.
- Status line: "iPhone and iPad connected", "2 devices connected", and similar.
- A device list with per-device **Disconnect**, and **Revoke Trust** for each
  trusted device whether or not it is connected.
- `RecentBridgeEdit` gains the device name; the recent-edits row shows it.
- Update copy that says "your iPhone" where it now means any device. Copy in
  `docs/MAC_BRIDGE_SHELL.md` changes to match.

Offline simulation (`BundledOfflineBackend`): **Simulate phone connection** becomes
able to add a second simulated device, plus **Simulate edit from other device**
(produces a `stale_context` for the first one) and **Simulate slow USB request**
(exercises `busy`).

## Phase 4: iOS app

Small changes; the editing model already copes with shared state.

- Handle `bridge_full` on `hello`: "This Mac is already connected to 4 devices."
- Handle `revoked` on any request: return to the Mac list with "Disconnected on
  the Mac."
- Handle `busy`: for an edit or save, treat it like the existing recoverable
  rejections (reject the pending edit as not applied, re-read the snapshot); for a
  read, schedule the next poll after `retry_after`.
- Honour `applied: false` on `device_unavailable`: show "Edit not applied" instead
  of "Last edit or save outcome unknown."
- Conflict copy: when a write fails with `stale_context` or a snapshot shows a
  change the device did not make, say "Changed on another device" instead of
  "Changed on the QC" when the bridge reports it. To support this, the bridge adds
  an optional `changed_by` (device name) to snapshot replies after another device's
  confirmed write. Old apps ignore the field.
- No change to trust storage: `TrustStore` is already keyed by Mac, and each device
  holds its own token.

## Phase 5: verification

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
- Diagnostics: tag events with a short per-session device index (not the name)
  so exported reports show which device did what.

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
