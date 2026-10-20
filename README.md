# Patchbridge

Edit a Neural DSP Quad Cortex from an iPhone or iPad. A Mac bridge app talks to the
QC over USB and serves it to the phone over Bluetooth, with no Wi-Fi network or
local server. See [the implementation plan](IMPLEMENTATION_PLAN.md) for milestones,
[the product brief](PRODUCT.md) and [the marketing site](site/README.md)
(patchbridge.arjunakankipati.com).

## Status

All the software is implemented and wired for live use. The first full
phone-to-Mac-to-QC run on hardware hasn't happened yet; see
[the next hardware session](docs/NEXT_HARDWARE_SESSION.md) and
[hardware validation](docs/HARDWARE_VALIDATION.md).

- **iPhone and iPad app.** SwiftUI editor for iPhone (portrait and landscape), the
  iPhone Duo's inner and outer screens, and iPad. It shows the signal chain,
  active scene and confirmed values, and generates controls from QC metadata.
  Parameters with a declared linear or power conversion are editable. Anything with
  missing or unsupported metadata is shown read-only rather than guessed. It also
  has a demo mode with a captured preset, a Live Activity for the bridge session,
  and trusted reconnect. See [the data-layer contract](docs/METADATA_AND_EDITOR_MODEL.md)
  and [iOS setup](ios/README.md).
- **Mac bridge.** Native app that bundles its own Python runtime and the pinned USB
  dependencies. It opens stopped. Start bridge advertises over Bluetooth, and USB
  opens only after you approve a phone on the Mac. Up to four phones or iPads can
  share one bridge. It shows recent edits, recovery state and diagnostics export.
  See [the bridge shell](docs/MAC_BRIDGE_SHELL.md),
  [multi-device support](docs/MULTI_DEVICE_PLAN.md) and [packaging](docs/MAC_PACKAGING.md).
- **Python helper.** Versioned process protocol with serialized, confirmed writes and
  explicit save. Adapters: simulated, captured read-only, and direct USB pinned to
  qc-mcp and verified on CorOS 4.1.1. See [USB results](docs/USB_RESULTS_2026-10-20.md)
  and [the process protocol](docs/PROCESS_PROTOCOL.md).
- **Safety.** Read-only policy is enforced at the helper and bridge boundaries.
  Diagnostics reports leave out preset contents and identifiers. An offline
  preflight checks the package before any hardware session. See
  [read-only mode](docs/READ_ONLY_QC.md), [diagnostics](docs/DIAGNOSTICS.md) and
  [preflight](docs/PREFLIGHT.md).

Not yet supported from the phone: Save As, bypass, scene and preset selection, and
scene-specific values. The real adapter doesn't expose them yet.

## Run locally

Python 3.11 or newer is needed for source development. The Mac app bundles its runtime.
The simulator has no external Python dependencies.

```sh
PYTHONPATH=src python3 -m patchbridge.helper --adapter simulated
```

Enter one JSON request per line:

```json
{"version":1,"type":"request","id":"1","operation":"connect"}
```

The response contains a fresh `session_id`, revision, device identity, and preset
snapshot. See [the process protocol](docs/PROCESS_PROTOCOL.md) for follow-up requests.
EOF stops the helper and releases the adapter.

```sh
PYTHONPATH=src python3 -m unittest discover -s tests -v
```

## Direct USB development

Install the optional pinned dependency into a virtual environment:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -e '.[usb]'
.venv/bin/python -m patchbridge.helper --adapter usb
```

Close Cortex Control first. The USB adapter accepts only verified CorOS 4.1.1.
It supports snapshots, live catalog reads, non-scene-assigned numeric/option
parameter writes, and saving an existing named My Presets slot using File CREATE.
RecallPreset SAVE is unsupported following two observed device restarts.

The helper exchanges parameter values in the QC's normalized 0–1 representation.
Its metadata keeps the raw device definitions, including symbolic ranges, skew,
option names and dependencies. Display conversion happens in the Swift editor model,
not in the helper. Unknown, scene-assigned and expression-controlled parameters are
not writable.
Capabilities advertise only implemented operations. Save As, bypass writes,
scene selection, and preset selection are not yet exposed by the real adapter.

The adapter refreshes state before edits to reject physical changes since the
client's last snapshot. USB cannot make that read/write pair atomic, so
simultaneous physical and remote editing still needs further hardware testing.
Saving checks the resulting dirty flag and state without switching presets;
durable reload behavior was verified separately during hardware investigation.
Errors invalidate the helper session and never trigger automatic write retries.

## Swift and BLE development

The `swift/` package holds the shared code: the helper process client, chunked
BLE protocol, Core Bluetooth central and peripheral, the Mac bridge backend, and the
editor coordinator and model. See [Swift/BLE demo instructions](docs/SWIFT_BLE_DEMO.md).
The iPhone and iPad app is in `ios/Patchbridge.xcodeproj` (see [iOS setup](ios/README.md)).
The Mac app's release project is generated from `mac/project.yml`.
Pairing, approval, snapshot transfer, and a simulated edit and save have passed
between the Mac and a physical iPhone.

## Build the Mac app

The bundled Python runtime is built once from pinned, hash-checked CPython and
protobuf sources, so every bundled binary has a dSYM for crash symbolication:

```sh
/opt/homebrew/bin/python3 tools/build_runtime.py
/opt/homebrew/bin/python3 tools/package_mac.py
```

See [Mac packaging](docs/MAC_PACKAGING.md) for local inputs and checks.

## Offline verification and next hardware session

Run `tools/check_offline.sh` without connecting any device. See
[the next-session plan](docs/NEXT_HARDWARE_SESSION.md) for verified behavior,
offline changes, and the remaining gate before real QC edits from the phone.

## Generic editor data layer

The [metadata and editor model contract](docs/METADATA_AND_EDITOR_MODEL.md)
describes normalized controls, declared conversions, unsupported metadata, and
the view-independent Swift API. It is tested against captured QC fixtures and
is consumed by the designed iPhone app.

## Repository contents and license

Source and documentation are licensed under [MIT](LICENSE). Third-party
dependencies retain their own licenses; the Mac packager includes their notices.

Build outputs, Python environments, signing material, Xcode user settings, and
raw `hardware-results/` captures are excluded from Git. The normalized editor
fixture in `tests/fixtures/` is included. Raw-capture snapshot tests skip when
their local input is missing. Full USB fixture checks, packaging, and preflight
require the local captured inputs and dependencies described in
[Mac packaging](docs/MAC_PACKAGING.md); a fresh clone alone cannot run those gates.

## Release scripts

Use `./release_ios` for iPhone TestFlight and `./release_macos` for Mac TestFlight.
Both upload by default and accept `--no-upload`, `--skip-tests`, `--build`, and
`--allow-dirty`. See [iOS release setup](ios/README.md) and [Mac release setup](docs/MAC_PACKAGING.md).
