# Diagnostics and troubleshooting export

The shared Swift `Diagnostics` service stores structured events in memory. The
Mac helper client records starts/stops, request outcomes, safe error codes, and
request durations. The bridge records approvals, revocations, authorization
rejections, and blocked writes. The generic coordinator records session lifecycle
and failure events. It does not store received status/error text or device state.

## Export

In the offline Mac host, choose **Export Troubleshooting Report…** from the app
menu (Command-E). A standard save panel describes the exclusions and lets the user
choose the destination. Cancel writes nothing. Save failures show an error without
exposing the destination path in diagnostics. No upload or network request occurs.

For automated offline verification:

```sh
"dist/Patchbridge.app/Contents/MacOS/Patchbridge" --export-report /tmp/Patchbridge-Troubleshooting.json
```

This starts a fresh simulation self-test, stops its helper, and exports that run's
events. It also exports failure diagnostics if the helper cannot start. It does
not collect another running instance's logs or enable Bluetooth/USB. A sample from
a successful offline run is at `dist/Patchbridge-Troubleshooting.json`.

Future screens can inject a shared `Diagnostics` instance into `HelperClient` and
`EditorCoordinator`, use `reportData()` for a preview, call `export(to:)` following
an explicit save action, or call `clear()` to discard the retained events.
`BridgeSession` uses its helper client's instance. No report is written by default.

## Contents and limits

JSON schema version 1 includes app/protocol versions, OS family/version, the buffer
capacity, dropped-event count, and ordered events with relative elapsed time.
Events use fixed enum names and allowlisted operation/error codes. Unknown strings
become `unknown`; raw error descriptions never enter the log. Request durations
are bounded integer milliseconds. Sequence numbers are local counters, not request
or session identifiers.

The default buffer holds 256 events; configurable capacity is clamped to 1–1024.
Oldest events are dropped with a count when full. Writes and report snapshots are
lock-protected. Export creates a private temporary file (0600), writes a complete
snapshot, and atomically replaces the destination. Temporary files are cleaned up.
Reports persist only where the user explicitly exports them. Memory logs are lost
when the whole host exits/crashes; helper failures remain available while the host
is running. This first version does not collect previous-run crash logs.

Excluded in all current exports:

- Preset names, contents, block/model IDs, parameter values, and snapshots/catalogs.
- Raw commands/responses, error descriptions, Python stderr/tracebacks, and fixtures.
- File paths, environment variables, usernames/hostnames, device identifiers,
  approval tokens, connection/session IDs, and request IDs.

There is no option to include preset contents in this version. The build manifest
is not copied into reports. Existing development stderr output is separate from
the diagnostic buffer and is never included in exported reports.

## Offline verification

```sh
/opt/homebrew/bin/python3 tools/package_mac.py
/opt/homebrew/bin/python3 tools/check_mac_package.py
PATCHBRIDGE_TEST_BUNDLE=1 tools/check_offline.sh
```

Tests cover bounded retention, concurrent recording, unknown-string filtering,
private atomic replacement, write failures, captured-fixture privacy, denied
writes, and a timed-out helper request with cleanup. Package checks export from a
relocated app with no Python on PATH, then remove its helper and confirm failure
export still works. The privacy checks seed known private strings/IDs and inspect
the actual JSON. The shared source also passes unsigned generic iOS compilation.
The native save panel is implemented but its manual interaction was not exercised.
