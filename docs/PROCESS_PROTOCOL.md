# Process protocol v1

This is the local stdin/stdout interface, not BLE framing. stdout contains only
UTF-8 JSON objects terminated by LF. Diagnostics use stderr. Requests are limited
to 65,536 bytes including LF. Malformed, oversized, and incomplete frames yield
`invalid_frame` with a null ID. Oversized frames are drained through their newline.

Requests contain `version: 1`, `type: "request"`, a nonempty string `id` (maximum
128 characters), `operation`, and an optional object `payload`. IDs correlate
responses; they are not idempotency keys. Do not automatically retry writes.

`connect` and `capabilities` do not require a session. Every other operation
requires the returned `session_id`. A second connect is rejected until disconnect.
Writes additionally require the last confirmed integer `revision`, string
`preset_id`, and `scene`. Send dependent writes sequentially using returned
context. Even saves and scene/preset selection require this context.

| Operation | Payload | Result |
| --- | --- | --- |
| connect | `{}` | device and full state; new session |
| disconnect | `{}` | cleared session |
| capabilities | `{}` | operations and confirmation/event support |
| identify | `{}` | device identity and compatibility |
| snapshot | `{}` | confirmed state |
| catalog | optional `model_ids` array | metadata with catalog identity, optionally limited to requested models |
| subscribe | `{}` | current state; enable subsequent state events |
| set_parameter | block_id, parameter_id, value | confirmed state |
| set_bypass | block_id, boolean value | confirmed state |
| select_scene | scene | confirmed state |
| select_preset | preset_id | confirmed state |
| save | `{}` | confirmed state |
| save_as | preset_id | confirmed state |

`catalog.payload.model_ids` accepts at most 128 nonempty strings of at most
128 characters each. Omission returns the full catalog; an empty list returns no
models. Unknown IDs are omitted, preserving the catalog ID and metadata version.
The Swift coordinator requests only models referenced by the current preset.

Example edit (replace context with the connect response):

```json
{"version":1,"type":"request","id":"2","operation":"set_parameter","session_id":"SESSION","revision":0,"preset_id":"1","scene":"A","payload":{"block_id":"amp-1","parameter_id":"gain","value":7}}
```

Responses contain `type: "response"`, the request ID, current session and revision,
and either `status: "confirmed"` with `result`, or `status: "error"` with
`error: {code, message}`. Confirmed means the adapter returned readback, not merely
that a USB write was transmitted. The simulator confirms its own in-memory state.

Every successful mutation increments revision. Snapshot readback increments it
when state changed. Subscribers receive `type: "event", event: "state"` with
session, revision, and full state after mutation/snapshot responses.

The simulator has no asynchronous physical-device events (capabilities explicitly
reports `device_events: false`). The Swift editor coordinator provides bounded snapshot polling through the same
serialized request path. Subscription alone
does not currently detect external changes.

Stale contexts and sessions fail before adapter writes. Disconnection or an
unexpected adapter failure invalidates the session; reconnect and fetch state.
The single synchronous consumer serializes operations and pipe backpressure
bounds buffering. There is no internal command queue or automatic replay.

Simulation metadata is fabricated, with two scenes, four preset slots, numeric,
boolean, enum, and logarithmic controls. Saved presets persist only for the
lifetime of the helper. Scene selection isolates parameter edits; switching
presets discards unsaved edits. These are simulation semantics awaiting hardware
validation.

Swift process lifecycle management, BLE framing/authorization, and bounded editor
polling are implemented. Remaining work includes UI integration, real-device event
delivery validation, and runtime bundling/signing.
The process protocol does not authorize a phone; that belongs in the Mac bridge.
