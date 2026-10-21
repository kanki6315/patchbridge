# Metadata and generic editor model

The view-independent model is in `swift/Sources/PatchbridgeCore/GenericEditor.swift`.
The existing simulation screen continues to use `EditorModel`; designs can evolve
without changing this new data layer. No radio or USB access is needed to test it.

## Versioned metadata

USB catalogs now include `metadata_version: 1`. Each model parameter retains all
raw firmware XML attributes and adds a `control` object. Snapshots carry the
matching `catalog_id` (SHA-256 of the live catalog). Reject mismatched catalogs
rather than reusing definitions from another firmware/catalog.

Control fields include name, unit, kind, encoding, editable, and either an
explicit mapping/options or a read-only reason. Unknown types stay visible as
unknown; strings are readable but not writable. Captured values keep their JSON
type (number, boolean, string, null).

| Firmware definition | Normalized behavior |
| --- | --- |
| float + finite ordered range + LIN_SKEW | Numeric control with explicit linear conversion |
| float + finite range + positive numeric skew | Numeric control with declared power conversion |
| float or fader + finite range + no skew | Linear (power exponent 1), from hardware calibration |
| Measured range constant (MIN/MAX_EQ_DB, _FXLOOP_OUT_GAIN_DB, _FXLOOP_IN_GAIN_DB) | Resolved to the value read on the QC; other constants stay read-only |
| float + finite range + LOG_SKEW | Power conversion with skew 0.3, from hardware calibration |
| float + finite range + xValues/yValues table | Numeric control interpolated linearly between the declared points |
| switch/rotarySwitch/toggleButton/comboBox + matching steps and stepNames | Named enumeration; normalized option values i/(count−1) |
| Two-step switch without stepNames | Off/On, from hardware calibration |
| Empty or unknown skew, symbolic/invalid range | Read-only; no guessed taper/range |
| Missing or inconsistent option labels | Read-only; never fabricate labels |
| toggleOn/toggleOff dependency | Read-only until dependency semantics are implemented |
| int | Read-only: in CorOS 4.1.1 every int is a device command (Neural Capture, ZenLink), a calibration setting or hidden |
| Unknown/meter/string type | Read-only |

Declared power mapping: `display = min + (max−min) * normalized^(1/skew)`;
inverse: `normalized = ((display−min)/(max−min))^skew`. This follows the candidate
adapter's explicit-skew convention, without its heuristic fallback. Definitions
are labeled `verification: not_hardware_calibrated`: numerical round-trip tests
verify our implementation, not every firmware control's physical display.

A lookup table must have the same number of x and y values, x running from 0 to 1,
both strictly increasing, and y ending at the declared min and max. Anything else is
read-only as an inconsistent table. Calibration confirmed straight lines between
the points, midpoints included. `toggleButton` controls (FREEZE, TRIGGER) share the
switch encoding: 1 is active and the value latches. The QC's button text is the action
it offers, so it reads FREEZE while released and RELEASE while frozen. A `min_string`
such as OFF is carried as `minimum_label`: the QC shows it instead of the minimum value.

Calibrated rules carry `mapping_source: hardware_calibration` rather than
`device_metadata`. Captured Myth Drive gain declares no skew, so it uses the
calibrated linear rule.
Opto Comp threshold declares LIN_SKEW and a −60…12 dB range. Dual Chorus MODE
has Chorus/Vibe labels; conditional rate/sync controls remain read-only.

## Model API for the new designs

- Decode `EditorCatalog` and `PresetSnapshot` from JSON.
- `load(snapshot:catalog:session:connection:revision:operations:)` installs a
  fresh confirmed context. Invalid loading clears the old session state.
- `control`, `value`, and `readOnlyReason` expose parameter presentation data.
  Editability is the intersection of adapter capabilities, snapshot permissions,
  metadata support, and a valid current scene value. Missing permissions are
  read-only. No assumed amp block or fixed parameter IDs.
- `wireValue(display:)` converts precise numeric entry; enum options already
  supply their raw wire values. The transport still sends normalized QC values.
- `propose` returns a correlated command plus pending edit data. Views may show
  the pending value separately; the confirmed snapshot never changes optimistically.
- `proposeSave` creates a separate save command when the adapter advertises it.
- `confirm` accepts a fresh, correctly scoped readback. Valid adjusted device
  values win. Saving must return clean state with unchanged block values.
- `reject` clears the matching pending edit and preserves confirmed state.
- `refresh` applies newer authoritative state and discards any pending edit;
  unchanged same-revision snapshots are harmless. A conflicting same-revision
  snapshot is rejected. The caller never automatically resends discarded edits.
- `disconnect` removes the session, metadata, pending command, and snapshot.

All model calls belong on one serialized owner (normally the main actor in the
future UI). This model does not own a radio, send requests, or enable USB mode.
Transport failures must call reject/disconnect as appropriate; thrown confirmation
errors must not be converted into success by the caller.

## Coordinator API for screens

`EditorCoordinator.swift` connects this model to `EditorTransport`. Own it and call
its API on the main queue; the default BLE transport already delivers there.
The existing simulation screen still uses its original `EditorModel` until the
new designs are integrated. The coordinator is included in the iOS build.

```swift
let coordinator = EditorCoordinator()
coordinator.onChange = { /* render phase, busy, error, and editor confirmed/pending state */ }
coordinator.start()
// After the user approves this connection on the Mac:
coordinator.authorize()
// Convert display input through the selected control before sending:
if let control = coordinator.editor.control(blockID: blockID, parameterID: parameterID),
   let value = control.wireValue(display: enteredValue) {
    try coordinator.edit(blockID: blockID, parameterID: parameterID, value: value)
}
try coordinator.save() // separate explicit action
// On backgrounding, preserve the session and pause polling; resume on return:
coordinator.setBackgrounded(true)
coordinator.setBackgrounded(false)
// When explicitly leaving the session:
coordinator.disconnect()
```

Loading follows hello → user authorization → connect → capabilities → relevant
catalog subset. Ready means the snapshot and versioned catalog agree. Missing
model definitions remain read-only. The cache holds one catalog subset, keyed by
catalog ID plus the requested model IDs (including known missing definitions).
A new catalog or previously unrequested model fetches a replacement subset;
matching reconnects reuse it. It never accumulates an unbounded catalog history.

Only one request can be outstanding. Polling starts two seconds after completion,
never overlaps a mutation or metadata load, and does not accumulate missed ticks.
Intervals are at least 0.5 seconds. A 15-second request deadline disconnects and
clears pending/confirmed state on an uncertain result. Polling stops on disconnect.
The injected clock and manual `tick()` support deterministic offline tests.

Explicit recoverable edit rejections trigger a snapshot before editing resumes.
Timeouts, malformed/stale replies, changed sessions, and transport/helper failure
require reconnect and fresh authorization. No mutations are retried. Old transport
callbacks are invalidated by a connection generation; replies also need the current
request ID, connection token, session, and revision. Physical edits appear through
snapshot polling; this coordinator does not subscribe to asynchronous events.

With several devices on one bridge, a few replies are handled without a reconnect.
`busy` means the bridge refused the request before it reached the QC: an edit or save
is shown as not applied, and a read or loading step is retried after `retry_after`.
`applied: false` on `device_unavailable` marks an edit the bridge never sent, so it is
shown as not applied rather than unknown. `changed_by` names the device whose edit a
snapshot or `stale_context` rejection reflects. `bridge_full` and `revoked` fail with
`failure` set, so the connect screen can explain them.

The simulator now provides metadata version 1 with `encoding: native` and
`mapping: identity` for its numeric values. Gain stays 0–10, preserving the installed
simulation screen's behavior. Boolean/string-enum simulation controls remain
read-only in the generic model. QC controls continue to use normalized values.

## Gap report and calibration

`tools/editor_gap_report.py` classifies every parameter in a captured catalog with
these rules and reports what is editable, why the rest is read-only, and which
categories and models have the largest gaps. Hidden parameters are counted
separately. `--model NAME` lists one model's parameters and `--json` prints data.
On the CorOS 4.1.1 capture, 3,118 of 3,888 visible parameters (80%) are editable,
up from 1,233 (32%) before calibration.

`tools/calibrate_qc_controls.py` answers that question on hardware. It picks
parameters from the loaded disposable preset in six groups: no declared taper,
LOG_SKEW, declared power, linear, lookup table and toggleButton. It writes a few
normalized values to each one, asks what the QC's screen shows, and restores the
original value. Results are saved after each parameter and compared with a linear
reading and with the declared mapping, within 2% of the range. `--plan` lists the
targets offline and names blocks to add for groups the preset doesn't cover.
`--analyze FILE` summarizes a saved run. `--models` limits targets to named blocks.
Neural Capture blocks are named after the capture rather than the catalog model.
Further groups gather evidence for types that aren't editable yet: comboBox,
fader, switches without option labels, and named range constants such as
`MIN_EQ_DB`, whose values come from the readings at 0 and 1.

### Calibration results, 2026-10-20

Saved in `hardware-results/2026-10-20/calibration-probe*.json`, all values restored:

| Question | Parameters | Result |
|---|---|---|
| Float with no skew | Capture BASS, Myth Drive GAIN, Adaptive Gate NOISE REDUCTION, EV101IIIS GAIN, Dual Delay MIX, Spring Reverb INPUT GAIN, Envelope Filter SENS | Linear, exact |
| Declared power skew | Opto Comp RATIO and ATTACK, Plate Tight PRE DELAY | Matches within 0.03% of range |
| LIN_SKEW | Opto Comp THRESHOLD, Transpose SEMITONES, Poly Octaver DRY | Linear, exact |
| LOG_SKEW | Envelope Filter FREQ and RESO | Power curve with skew 0.3 (fits better than log10 2) |
| Lookup table | Parametric-4 LO FREQ, 17 readings | Linear between points, exact |
| toggleButton | Vintage Digital FREEZE | 1 is active, latches; button text is the action |
| comboBox | US DLX 64 Vintage MODE, Tremolo WAVEFORM | Switch encoding, every option matched |
| fader | Graphic-9 65, 125, 250 and 500 Hz | Linear, exact |
| Unlabeled two-step switch | UK C30 BRIGHT, FX Loop 1 TRAILS, Parametric-8 1 and 2 BYPASS | 0 is Off, 1 is On |
| Range constants | Parametric-8 1 and 2 GAIN, FX Loop 1 SEND and RET LEV | EQ −12…12 dB, loop send −40…0 dB, return −40…12 dB, all linear; OFF shown at the minimum |

Three readings were mistyped at the prompt and corrected afterwards; each keeps
`corrected_from` and a note. `MIN_CABSIM_DB` (14 parameters) and `MIN_MIXER_DB` (8)
are still unmeasured.

## Captured fixtures and checks

`tools/export_editor_fixture.py` projects the captured preset and live catalog
into `tests/fixtures/qc-editor.json`: 16 blocks, 11 relevant models, eight scenes.
It reads local evidence only. Run with `PYTHONPATH=src python3 tools/export_editor_fixture.py`
after changing the normalization contract. Do not use it to acquire new hardware
state. The preset identity is labeled `captured:` to avoid implying a live slot.

Tests cover explicit range/skew conversion, named options, unsupported mappings,
real block/parameter addresses, capabilities, pending/confirmed separation,
adjusted readback, stale sessions, catalog mismatch, save confirmation, and
external-state invalidation. Run `tools/check_offline.sh`.

Still required before real phone edits: connect this generic model to the design,
display unsupported controls clearly,
add read-only USB mode to the bridge/phone deliberately, and calibrate selected
controls against the QC with the user present. The running BLE demo and installed
phone screen remain simulation-only.

Coordinator coverage includes captured-fixture loading, capability restrictions,
subset cache reuse/invalidation, physical scene changes, bounded polling,
authorization retry, uncertain pending edits, stale callbacks, malformed responses,
and a chunked real Python simulation edit/save/reconnect/helper-restart round trip.
These checks exercise process and protocol behavior, not physical Bluetooth or USB.
