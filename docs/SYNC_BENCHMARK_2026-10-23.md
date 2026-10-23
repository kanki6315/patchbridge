# Sync benchmark — October 23, 2026

Measured on the connected Quad Cortex, CorOS 4.1.1, with a 15-block preset.
Read-only: no parameter edits, preset/scene switches, saves, or tuner changes.
Patchbridge was temporarily quit to release USB and reopened afterward.
The installed app remains unchanged. The follow-up below was built and passed
package validation; installation was deferred at the user's request.

## Results

| Step | Baseline median | Wake-on-input median | Wake-on-input p95 |
|---|---:|---:|---:|
| Complete consistent snapshot | 120.2 ms | 56.5 ms | 75.4 ms |
| Setlist position, each of two reads | 13.1 ms | 2.1 ms | 3.5 ms |
| Scene, each of two reads | 13.0 ms | 2.0 ms | 3.1 ms |
| Full preset read | 49.9 ms | 40.7 ms | 59.8 ms |
| Dirty flag | 13.0 ms | 2.2 ms | 4.7 ms |
| State comparison | 0.12 ms | 0.07 ms | 0.18 ms |
| Snapshot JSON encode | 0.65 ms | 0.44 ms | 0.76 ms |
| Snapshot JSON decode | 0.43 ms | 0.28 ms | 0.51 ms |

Baseline: 40 snapshots with 10 ms reply polling. Additional 40-snapshot trials
at 5 ms and 1 ms produced medians of 83.3 and 61.7 ms. Returning to 10 ms gave
121.1 ms, supporting a real polling-delay effect rather than warmup alone.
Wake-on-input: 100 preliminary snapshots, then 200 with the final implementation
including preserved handshake delays. All completed; final run had zero state
changes, zero transport write errors, and seven pending messages at completion.
Per-snapshot process CPU time including comparison/serialization fell from
11.7 ms to 7.4 ms. This is process CPU time, not system-wide CPU utilization.

Other steps, sampled once in the baseline:

- Connect including catalog: 14.30 s. Open/handshake/version accounts for 4.22 s,
  including a 3.01 s Version request; ModelRepo accounts for 10.01 s.
- Catalog copy: 26 ms; complete catalog JSON encoding: 12 ms, 1,939,243 bytes.
  This is the full local catalog, not a measurement of filtered phone transfer.
- Optional My Presets directory listing: 11.28 s, 16 named slots.
- Snapshot payload: 22,460 bytes, excluding the helper response envelope.

The final connect still took 14.27 s. Startup is not improved by this change.
Version and ModelRepo durations closely match their request timeout budgets;
investigate fallback response matching before assuming these are transfer times.
Do not broadly accept mismatched request IDs: that could consume stale state.

## Implemented changes

The HID callback now signals a condition variable. Reads drain queued input
immediately or wait until input arrives, bounded by the existing timeout.
Handshake settling delays remain explicit. All six snapshot reads, context
consistency checks, and pre-write freshness checks remain intact.

The bridge's delay after a completed refresh is now 0.5 s instead of 2 s, checked
on a 0.25 s timer instead of 0.5 s. Cache freshness is capped at 1 s instead of
3 s. Multiple phones still share one USB snapshot. With a typical 56 ms read,
this predicts approximately 0.56–0.81 s between completed bridge refreshes,
depending on timer alignment and other queued work, versus roughly 2.12–2.62 s
before. This is a scheduling estimate, not a measured phone visibility bound.
The phone still polls at its existing one-second interval, plus BLE transfer and
rendering time. USB snapshots remain serialized with edits.

## Reproduce and next measurements

Quit apps owning QC USB, install the local USB dependencies/descriptors described
in README, then run:

```sh
PYTHONPATH=src:vendor/qc-mcp/src python3 tools/benchmark_sync.py \
  --samples 200 --poll-ms 10 --directory \
  --output hardware-results/sync.json
```

The tool stores aggregate timings, payload sizes, and counts; no preset contents
or device identifiers. Output is saved even after an exception and USB is closed.
Nested stage timings overlap totals and must not be added to them.
Startup and directory results are single observations, not statistical estimates.

This run excludes helper process IPC, Swift decoding, BLE chunk delivery,
phone rendering, actual edit/save timing, tuner contention, and physical-change
detection latency. The next hardware pass should timestamp a physical knob/scene
change through bridge refresh and phone presentation, then measure BLE catalog
and snapshot transfer separately. Longer mixed editing/tuner sessions should
validate the increased refresh frequency before release.

Local timing evidence: `hardware-results/2026-10-23/sync-baseline.json`,
`sync-event-wakeup.json`, and `sync-final.json` (ignored by Git).

## Follow-up: startup and preset listing

Wire tracing confirmed that complete Version and ModelRepo replies carry request
ID zero. The generic request path waited out its 3 s / 10 s deadlines before
returning them. The owned exclusive-session path now drains queued messages and
accepts complete unnumbered replies for these two metadata commands only. Version
ACKs without firmware and catalog replies without a payload cannot take this path.
Nonzero mismatched IDs, shared sessions, and mutable state cannot use it either.
The handshake no longer requests ModelRepo before the adapter requests it again.
All handshake settling delays remain unchanged.

A File READ specifying the My Presets folder returns one complete 256-slot table
and echoes the request ID. The adapter uses that request instead of streaming the
entire presets/IR/capture directory. It checks the ID, folder, type, and all 256
slots before accepting the result; no quiet-period heuristic or cached listing is
used. Full-directory reads remain available for other callers.

| Measurement | Original | Final |
|---|---:|---:|
| Adapter connect | 14.30 s | 2.81 s |
| Connect plus first consistent snapshot | 14.42 s | 2.82–2.90 s across 3 repeat runs |
| My Presets listing | 11.28 s | 29–45 ms across 15 repeat reads |

All 15 reads agreed on the 16 named entries. The first run compared the fast result
against a fresh full-directory read, including every named slot's ID, number, and
name, with exact equality. Subsequent runs checked repeated fast-read consistency.
These are adapter timings; app launch/Bluetooth approval are not included.

Added tests cover stale queued metadata, incomplete ACKs, mismatched nonzero IDs,
shared sessions, unchanged scene matching, and incomplete/stale/wrong-folder
directory replies. Python tests and the package's captured USB checks validate
the changes without hardware writes. Local evidence is in
`sync-startup-directory.json`, `sync-startup-final.json`, and
`fast-sync-repeated.json` under the same ignored results directory.
