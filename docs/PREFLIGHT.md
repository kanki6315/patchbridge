# Offline preflight before the next QC session

Build the current app, then run the offline preflight:

```sh
/opt/homebrew/bin/python3 tools/package_mac.py
/opt/homebrew/bin/python3 tools/preflight.py
```

The generated `dist/Preflight.json` records passed, failed, or not-run checks.
Exit status is zero only when every gate passes. `--report <file>` selects another
local destination. A successful result is **offline_checks_passed**, never a claim
that hardware is validated or permission to enable USB. The app remains offline.
This is a developer check, independent of the unfinished screen designs.

## Gates

1. **Package provenance and pinned dependencies:** verify qc-mcp commit and protobuf
   version, live-USB-disabled policy, and source fingerprints captured at build time.
   Changed or missing inputs require a rebuild; stale packages cannot pass silently.
2. **App signature:** verify the nested ad-hoc signatures and sealed resources.
3. **Relocated runtime, schemas, read-only policy, and private export:** move the
   bundle to a temporary folder, remove Python from PATH, run simulation and nine
   captured USB checks, reject live USB startup, test missing schema/helper failure,
   and inspect the actual diagnostic report for excluded data and private permissions.
4. **Fixture matrix and process recovery:** run the Python/Swift suite, explicitly
   enabling the packaged-runtime integration test, then the chunked bridge self-test.
   This includes timeout, crash, simulated removal, reconnect, and stale callbacks.

If provenance or signature fails, executable-dependent gates are marked not_run.
Independent prerequisites still report their own results. Each subprocess has a
deadline; timeout terminates its process group. The runner invokes only offline
commands, never the live adapter, Core Bluetooth advertising, or network tools.

Reports include check names, outcomes, bounded-category reason codes, and elapsed
milliseconds. No raw output, exception descriptions, paths, fixture/preset contents,
or identifiers are copied into them. They are written atomically with mode 0600.
Temporary command output is discarded. To investigate a failed gate, run its
underlying command from the steps above or `tools/check_mac_package.py` /
`PATCHBRIDGE_TEST_BUNDLE=1 tools/check_offline.sh` in the development workspace.

The report explicitly leaves these untested: physical USB/firmware identification,
comparison with the QC display, real unplug/Bluetooth recovery, display calibration
and hardware writes, designed screen integration, and distribution signing.

## Broadened fixture coverage

The original captured files remain unchanged. Tests derive synthetic edge cases
from them; these variants are software tests, not new hardware evidence.

- All eight scene-assigned values remain distinct and read-only; missing scene
  values are never borrowed from another scene.
- Unknown models, string values, missing scene data, missing permissions, boolean
  and null values remain visible where supported but cannot enable numeric writes.
- Malformed scenes, out-of-grid positions, duplicate IDs/positions, empty model IDs,
  and unknown scene keys fail structural validation on load and refresh.
- Invalid normalized enum options (out-of-range values, duplicates, missing labels,
  single-option definitions) cannot enable writes.
- Existing unsupported mappings, catalog changes, missing schemas, context conflicts,
  File CREATE confirmation, read-only enforcement, and recovery checks still run.

The added validation applies to GenericEditor loading, refresh, and confirmation;
a rejected refresh preserves the last confirmed state, while coordinator errors
invalidate the connection. The grid bounds are the QC's four rows/eight columns.
The latest full suite has 40 Python tests and 49 Swift tests, plus nine packaged
USB fixture checks and the independent relocation/export checks.
