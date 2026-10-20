# Patchbridge

Native iPhone-to-Mac QC editor PoC. See [the implementation plan](IMPLEMENTATION_PLAN.md).

The implementation includes a Python helper, deterministic simulator, and a
direct USB adapter pinned to the tested qc-mcp revision. CorOS 4.1.1 has partial
hardware validation; see [results](docs/USB_RESULTS_2026-10-20.md).
The designed SwiftUI iPhone app and native Mac USB/Bluetooth bridge are implemented.
The generic editor coordinator loads relevant metadata, polls confirmed state,
and handles edits/reconnects with offline fixture and process coverage; see
[the data-layer API](docs/METADATA_AND_EDITOR_MODEL.md).
The Mac app bundles an isolated Python runtime and the pinned USB/protobuf dependencies;
see [Mac packaging](docs/MAC_PACKAGING.md). It starts stopped and offers live Bluetooth-to-USB
operation with explicit phone approval, recovery and device-name fallbacks. Simulation
remains selectable. Both apps use `com.arjunakankipati.patchbridge` and the Patch Cable icon.
Physical end-to-end phone/QC validation and production Mac distribution remain pending.
[Read-only QC policy and recovery](docs/READ_ONLY_QC.md) now have captured-fixture
coverage through the packaged helper, Swift bridge, and generic coordinator.

Bounded in-memory diagnostics and an exportable JSON report are available from the
Mac app menu. Reports exclude preset contents and identifiers; see
[diagnostics and export](docs/DIAGNOSTICS.md).

Before a hardware session, run the [offline preflight](docs/PREFLIGHT.md) to check
package freshness, signatures, fixtures, and recovery. Passing does not enable USB
or claim physical hardware compatibility.

The [compact Mac bridge shell](docs/MAC_BRIDGE_SHELL.md) now provides start/stop,
phone approval, connection status, recovery, recent edits and report export.
It opens stopped; Start bridge begins live Bluetooth, with USB opened after phone approval.

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

USB parameter values currently use the QC's normalized 0–1 representation.
Metadata retains raw device definitions, including symbolic ranges, skew, option
names, and dependencies. Display conversion is not yet implemented; do not feed
this metadata directly into the simulator's control renderer. Unknown,
scene-assigned, and expression-controlled parameters are not writable.
Capabilities advertise only implemented operations. Save As, bypass writes,
scene selection, and preset selection are not yet exposed by the real adapter.

The adapter refreshes state before edits to reject physical changes since the
client's last snapshot. USB cannot make that read/write pair atomic, so
simultaneous physical and remote editing still needs further hardware testing.
Saving checks the resulting dirty flag and state without switching presets;
durable reload behavior was verified separately during hardware investigation.
Errors invalidate the helper session and never trigger automatic write retries.

## Swift and BLE development

The `swift/` package contains the native helper process client, shared chunk
protocol, a Core Bluetooth central transport, and a Mac peripheral demo using
simulated state. See [Swift/BLE demo instructions](docs/SWIFT_BLE_DEMO.md).
The native iPhone test host is in `ios/Patchbridge.xcodeproj`; see [installation instructions](ios/README.md). Wireless installation is verified; BLE testing is in progress.

Next: iPhone host and over-the-air BLE testing, additional USB hardware
coverage, and display-value conversion.

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
