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
| snapshot | optional `known_revision` | confirmed state, or `{"unchanged": true}` when the session is still at `known_revision` |
| catalog | optional `model_ids` array | metadata with catalog identity, optionally limited to requested models |
| subscribe | `{}` | current state; enable subsequent state events |
| set_parameter | block_id, parameter_id, value | confirmed state |
| set_bypass | block_id, boolean value | confirmed state |
| select_scene | scene | confirmed state |
| select_preset | preset_id | confirmed state |
| save | `{}` | confirmed state |
| save_as | preset_id | confirmed state |
| tuner | mode: off, live or open | tuner state |
| tuner_read | after: last reading number seen | tuner state with newer readings |
| set_tuner_mute | boolean value | tuner state, once the QC echoes it |

`catalog.payload.model_ids` accepts at most 128 nonempty strings of at most
128 characters each. Omission returns the full catalog; an empty list returns no
models. Unknown IDs are omitted, preserving the catalog ID and metadata version.
The Swift coordinator requests only models referenced by the current preset.

Each block in a state lists `editable_parameters`, and two optional fields that
say where a value lives. `scene_parameters` lists the parameters assigned to scenes:
each scene holds its own value, and `set_parameter` writes the active scene's only.
Every other parameter is global, so a write changes it in every scene. Readback of
a scene-assigned write must show the active scene changed and the other scenes
unchanged. `expression_parameters` maps a parameter to
`{pedal, heel, toe}`: the expression pedal (1 or 2) that drives it and its sweep,
in the same normalized units as its value. Expression parameters are never
editable. Older bridges omit both fields; treat their absence as unknown, not global.

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

## Tuner

The tuner doesn't touch the preset, so its requests need a session but no
revision, preset or scene context. Every tuner result is `{"tuner": {mode, muted,
input, seq}}`; `tuner_read` adds `readings`, each `{seq, hz, ms}`, newer than
`after` (at most 32). Readings carry increasing numbers so several readers can
share one stream. `hz` is the QC's detected pitch; 0 means it heard no note,
and it sends nothing at all while the strings are quiet.

- `open` shows the QC's tuner, so mute applies. The QC's own screen doesn't change.
- `live` streams pitch without showing the tuner, so it never mutes.
- `off` stops the stream.

The USB adapter sends Cortex Control's sequence, captured on CorOS 4.1.1:
ShowTuner with `show`, Tuner UPDATE `enable_meter`, then Tuner READ. Stopping
sends ShowTuner without `show` and clears `enable_meter`; ShowTuner alone left
pitch streaming. While the tuner is on, a reader thread collects pitch between
requests. `set_tuner_mute` requires `open` and is confirmed only by the QC's
echo; otherwise it fails with `not_confirmed`. Read-only sessions can start and
read the tuner but not change mute, which the QC keeps as a setting.
Disconnecting turns the tuner off. Verified on hardware: open and off, mute from
Cortex Control. Not yet verified: starting straight into `live`, and that `live`
stays unmuted when mute is on.

The Mac bridge gives the QC the strongest mode any device asks for (open, then
live, then off), so one device closing its tuner never stops another's. The live
Mac bridge also holds a baseline live request while running, even with no clients;
the final client leaving returns it to live instead of stopping acquisition.

Stale contexts and sessions fail before adapter writes. Disconnection or an
unexpected adapter failure invalidates the session; reconnect and fetch state.
The single synchronous consumer serializes operations and pipe backpressure
bounds buffering. There is no internal command queue or automatic replay.

Simulation metadata is fabricated, with two scenes, four preset slots, numeric,
boolean, enum, and logarithmic controls. Saved presets persist only for the
lifetime of the helper. Gain is scene-assigned and frequency is global; switching
presets discards unsaved edits. These are simulation semantics awaiting hardware
validation.

Swift process lifecycle management, BLE framing/authorization, and bounded editor
polling are implemented. Remaining work includes UI integration, real-device event
delivery validation, and runtime bundling/signing.
The process protocol does not authorize a phone; that belongs in the Mac bridge.
