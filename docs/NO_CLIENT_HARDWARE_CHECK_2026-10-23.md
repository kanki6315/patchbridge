# No-client QC backend check — October 23, 2026

Verified against the connected physical Quad Cortex using the current workspace's
production `LiveBridgeBackend`, `SharedUSBSession`, and USB helper. The test
peripheral never advertises Bluetooth or accepts a client. The host was driven
through its ordinary `tick()` work on one thread, approximately every 100 ms
plus work duration. This verifies the backend against hardware, not the native
Mac window or the installed application's older binary.

The installed Patchbridge app was temporarily quit to release USB and reopened
after each run. It was not replaced. The probe started live tuner metering but
sent no preset edits, recalls, saves, or mute changes. Closing the helper stops
the tuner. The user manually played notes and changed scenes and presets during
the active run, and confirmed those preset changes afterward.

## Results

Both the initial 90-second steady-state capture and the subsequent 120-second
active capture completed without a backend stop, request rejection, or transport
failure. The same USB session survived each complete capture. There were zero
client sessions throughout.

| Check | Active capture result |
| --- | --- |
| Startup | Preset state, full catalog, preset directory, and tuner ready in 4.86 s |
| Preset state | 179 cached snapshot refreshes; median interval 0.660 s, p95 0.762 s |
| Physical changes | Observed scenes F → E → G → F → B → C → H → G and a preset-ID change |
| Full catalog | 633 model definitions cached; exact match against a fresh helper catalog read |
| Preset directory | 24 autonomous refreshes; median interval 5.152 s, p95 5.283 s; exact fresh-read match |
| Tuner | 418 distinct sampled sequence values and 526 distinct positive pitch readings observed |
| Settled preset state | Cached full snapshot exactly matched a fresh QC snapshot |
| Session and dirty state | USB session stable; dirty flag unchanged |
| Client connections | Zero; Bluetooth advertising disabled |

The tuner sequence advanced while the user played and stayed at the same value
across the final quiet samples. The probe keeps up to three readings per sample,
so the number of observed pitch readings can exceed the number of sampled
sequence values. It does not measure tuning accuracy against a reference tone,
audio muting, or UI silence rendering.

The maximum interval between cached snapshots was 2.706 s; individual snapshot
requests reached 2.152 s. Thus refreshes are near-real-time, not a guaranteed
half-second deadline during physical changes. Catalog retrieval happens once
automatically per session; the second catalog request in diagnostics is the
final independent comparison. The directory count similarly excludes its final
comparison request.

The active report's `preset_unchanged: false` is expected: the user confirmed
physically changing presets. The initial steady-state run kept the preset ID
unchanged. No directory rename/delete or catalog/firmware change was deliberately
performed; recurring directory reads and equality with fresh reads were verified.
Reconnect/cache invalidation remains covered by simulator tests, not a USB cable
unplug during this hardware run.

## Evidence and reproduction

Local reports (ignored hardware artifacts, not preset dumps):

- `hardware-results/2026-10-23/no-client-sync/no-client-sync.json`
- `hardware-results/2026-10-23/no-client-sync/no-client-active-sync.json`
- Each report has a corresponding `.diagnostics.json` file.

The reproducible probe is `tools/verify_host_sync.swift`. Compile it alongside
`swift/Sources/PatchbridgeCore/*.swift` using `swiftc -parse-as-library`, then run
it with four arguments: the hardware Python executable, the source import path
(`src:vendor/qc-mcp/src` as absolute paths), the report output path, and the number
of capture seconds. USB dependencies and generated protobuf descriptors must be
available. Quit other QC USB owners before starting and reopen them afterward.
The probe prints `CAPTURE READY` after all four resources are present; play and
change scenes then, and let controls settle before the final comparison.

The hardware-test support changes also passed 22 focused Swift regression tests.
