# Swift helper client and BLE simulation

The Swift package builds a macOS command-line peripheral and a shared central
transport usable by a foreground iOS app. Both use simulated QC state only.
The installable iPhone test app is in `ios/Patchbridge.xcodeproj`. See
`ios/README.md` for installation and the hardware test record.

## Build and test

From the repository root, with Swift/Xcode and Python 3 installed:

```sh
swift test --package-path swift
swift run --package-path swift bridge-demo /opt/homebrew/bin/python3 "$PWD/src" --self-test
swift run --package-path swift bridge-demo /opt/homebrew/bin/python3 "$PWD/src" --ble
```

Replace the Python path for your machine. Tests currently use the Homebrew
Python path on the development Mac. For restricted build environments, set
`CLANG_MODULE_CACHE_PATH` and `SWIFT_MODULECACHE_PATH` to writable paths and
use `--scratch-path` with SwiftPM. Nested sandbox environments may require
SwiftPM's `--disable-sandbox` option.

The self-test launches Python, connects, chunks and reassembles an edit,
checks authorization, and receives a confirmed result. It does not use the radio.
The BLE mode advertises a custom service and waits for a central to subscribe.
Approve the exact connection token printed in the Mac terminal with
`approve TOKEN`. Type `quit` to stop. Discovery/subscription alone never authorizes
commands. No old edits are replayed after a disconnect or helper failure.

The executable embeds a Bluetooth usage description. macOS Bluetooth permission,
encrypted characteristic behavior and over-the-air throughput still need device
validation. The permission dialog may be attributed to the launching terminal.
A future iPhone host must also declare `NSBluetoothAlwaysUsageDescription`.

## BLE v1 development wire format

UUID prefix: `79A9`, suffix: `-6E15-4C9F-AC53-147F7E639B01`.

| Attribute | UUID first group | Behavior |
| --- | --- | --- |
| Service | 79A90001 | Advertised by Mac |
| Command | 79A90002 | Encrypted write with response |
| Result | 79A90003 | Encrypted notifications |

Each chunk has an 8-byte header: protocol byte `1`, unsigned transfer ID (4 bytes,
big endian), sequence (2 bytes, big endian, starting at zero), final flag (0 or 1).
Payload is part of a UTF-8 JSON object. Use the platform's negotiated maximum
write/notification length, capped at 512 bytes here. One transfer per direction;
maximum message 1 MiB, assembly lifetime 5 seconds. Missing, reordered, expired,
or oversized transfers fail. New connections discard all partial transfers.
A phone that sends `"compression": ["deflate"]` in its `hello` may get replies with
protocol byte `2`: the reassembled payload is raw DEFLATE of the JSON, and the 1 MiB
limit applies after inflating. Replies under 512 bytes, or that don't shrink, stay `1`.

Phone flow:

1. Discover, connect, subscribe to results.
2. Send `{"version":1,"id":"hello","operation":"hello"}`.
3. Retain the returned `connection_id`; obtain explicit approval on the Mac.
4. Send `connect` with that connection ID. Retain the helper session and snapshot.
5. Send process-protocol operations with connection ID and the required helper
   context. Responses preserve the phone's request ID.

`BLECentral` performs discovery, subscription, chunked writes, reassembly and
command timeouts. Its owner supplies JSON requests and consumes callbacks on the
main queue. It permits only one outstanding command; slider coalescing and
optimistic editor state belong in the future editor layer. Call `reconnect()`
after disconnect, repeat hello/approval/connect, and reload state.

The Mac bounds output to one message and respects Core Bluetooth's
`updateValue == false` signal; it resumes on the ready callback. More commands
are rejected while output remains queued. The process client serializes helper
requests, bounds stdout buffering, correlates responses, and terminates the
helper on timeout or invalid protocol. Helper stderr goes to the terminal.

## Current limits

The SwiftUI test app has verified initial BLE connection and state transfer on
a physical iPhone. The iOS app preserves connections across app switches using
Bluetooth background mode; this still needs physical-device validation. No
comprehensive BLE hardware validation, multi-phone support,
slider coalescing, transfer priority scheduler, or asynchronous device-event
forwarding yet. Use explicit snapshot requests for state refresh. A helper crash
requires restarting the demo. The simulator supports more operations than the
real USB adapter; this demo intentionally cannot launch USB mode.


## Revision notifications

The live Mac bridge and editor negotiate push hints through
`"revision_notifications": true` in both the hello request and reply. If the
bridge does not advertise support, the editor retains its normal one-second
polling default. Older apps do not opt in and receive no unsolicited events.
Both the Mac bridge and iOS app must be rebuilt to enable this behavior.

After a confirmed snapshot changes revision, or a confirmed app edit changes
shared state, the bridge sends joined, opted-in apps a small event on the existing
result characteristic:

```json
{"version":1,"type":"event","event":"revision_changed","connection_id":"…","session_id":"…","revision":42}
```

An app whose response already carries the new state needs no hint. Unapproved,
unjoined, legacy, and disconnected devices are excluded. Unchanged refreshes do
not emit events. Events contain no preset contents.

Events use the same chunk framing and negotiated compression as replies. The
router finishes already queued messages and in-flight requests before sending a
pending event; multiple unsent hints collapse into the latest. Requests may arrive
while event chunks are being sent. Event handling on the central does not consume
a command response or clear its acknowledgment/timeout state.

The editor validates connection/session identity and ignores revisions it already
has. A new revision triggers a snapshot immediately when idle. During a request,
it retains the newest hint and fetches after that request completes; queued edits
retain their existing priority. Notifications never replay an edit. Backgrounded
apps defer fetching and refresh on return to the foreground.

With push negotiated, ordinary polling becomes a **30-second fallback**, scheduled
after the latest completed refresh or state-bearing operation. It recovers missed
hints and discovers session recovery when necessary. Reconnect and foreground
resync remain in place. USB detection still runs on the bridge's existing schedule;
notifications remove the extra app polling wait, not the QC read interval.

Tests cover autonomous bridge detection, peer edits, opt-in/admission filtering,
stale hints, duplicate/coalesced hints, saves in flight, fallback/foreground
behavior, and response/event chunk ordering under backpressure. These tests use
simulated transports and the real helper simulator; over-the-air delivery and
phone-visible latency still need verification with rebuilt apps.

### Host-owned tuner feed

The live Mac bridge starts the QC tuner in `live` mode after opening USB, even
with no clients connected. This streams pitch without opening the QC tuner or
muting output. The Mac samples the helper buffer on its own 100 ms schedule;
clients do not clock acquisition. Preset reads keep their separate schedule.
The helper pipe remains request/response; this does not add unsolicited helper I/O.

Clients negotiate `"tuner_notifications": true` in hello, then use `tuner` to
request `live`, `open`, or `off`. Approved, joined clients requesting live/open
receive `tuner_updated` events with `version`, `connection_id`, `session_id`, and
`tuner` (mode, muted, input, seq, and up to three recent readings). Updates with
no new sequence also establish silence. Clients reject stale connection/session
events and stop `tuner_read` polling when push is negotiated. Legacy clients and
bridges retain the request-based tuner path. The display retains a local timer
for demo animation and stale-note expiry.

Bluetooth coalesces tuner updates independently of revision notifications and
sends request responses first. Closing or disconnecting the last tuner client
returns the QC to live mode; stopping the bridge closes USB and turns tuning off.
Unsupported adapters skip the host tuner feed for that USB session.

### Host-owned editor resources

After USB connects, the Mac loads capabilities, the full model catalog, and the
My Presets directory without waiting for any client. Resource work runs one
request per host tick, on the same serialized worker as other USB operations.
Catalogs are retained for the current USB session and catalog ID; a new ID in a
snapshot triggers a reload. Client `catalog` requests filter this full cache by
`model_ids` without replacing it with the subset.

The preset directory refreshes every five seconds, including while no clients
are connected. Saves, Save As, preset switches, and observed preset ID/name
changes invalidate it for an earlier refresh. Fresh `list_presets` requests use
the shared cache; expired or missing data is fetched from the helper. A failed
listing clears the cached directory, and background retries are delayed five
seconds. Unsupported operations are skipped. USB recovery clears both caches
and reloads them on the new session. This synchronizes the directory and model
definitions, not the contents of every inactive preset; only the active preset
has a continuously refreshed full snapshot.

### Complete state push

Clients and bridges negotiate `"state_notifications": true` in hello. For these
clients, a changed revision sends one `state_updated` event containing `version`,
`connection_id`, `session_id`, `revision`, and the full `state` snapshot, plus
`changed_by` when another client made the edit. The bridge sends it as soon as
the snapshot is available, before any tuner/resource maintenance on that tick.
It skips an originating client whose response already contains the same state.

The client applies this snapshot directly, without sending `snapshot`. During
an in-flight request it retains only the newest pushed revision, and applies it
after the response; a push never confirms a pending edit. Connection/session
checks, stale revision checks, held-edit rejection, and missing-catalog loading
are shared with the ordinary snapshot path. A new model/catalog may still need
a metadata request; it does not need another snapshot request.

Events use the existing compressed Bluetooth framing. Pending state events
coalesce separately from tuner events. Older clients continue to receive
`revision_changed` hints, and older bridges retain their existing behavior. A
30-second fallback read and foreground refresh remain for resynchronization.
The change removes the client refresh round trip; it does not alter the QC USB
sampling interval or claim lower measured end-to-end hardware latency.
