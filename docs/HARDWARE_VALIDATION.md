# CorOS 4.1.1 compatibility gate

Status: **partially verified on CorOS 4.1.1**. See
[the dated results](USB_RESULTS_2026-10-20.md) for evidence, successful
File CREATE persistence, and the problematic RecallPreset SAVE experiments.
The table below is the original procedure, not the current results ledger.

Use a disposable preset with Cortex Control closed. Record results from the
actual device before selecting or pinning a dependency. Do not interpret the
simulator tests as hardware evidence.

Record:

- Date, tester, Mac model/architecture and macOS version.
- QC model, hardware identity, firmware, and USB connection.
- Candidate repository URL, exact commit, license, dependency versions.
- Preset slot and backup; representative amp and effect models.

Run the following separately for each candidate from the plan:

| Test | Evidence to capture | Result |
| --- | --- | --- |
| Handshake | Device identity, firmware, session startup logs | Not run |
| Preset read | Compare block positions, scene, bypass, values with device | Not run |
| Catalog | Names, ranges, enum options, units and nonlinear scales | Not run |
| Writes | Numeric, switch, dropdown and nonlinear write/readback pairs | Not run |
| Scenes | Edit A, inspect B, return to A; check scene scope | Not run |
| Physical edits | Turn knob/touch control; capture event or polling latency | Not run |
| Persistence | Explicit save, switch away, reload and compare values | Not run |
| Reconnection | Remove USB during edits; reject stale writes after reconnect | Not run |
| Ownership | Close helper; verify QC can be opened again | Not run |

Separate transmission receipts from confirmed values. Document unsupported
operations, readback/polling requirements, timeout behavior and firmware mismatch
handling. Choose one library only after this evidence supports the first real
editing slice. Pin its commit and preserve its license notices when integrated.
