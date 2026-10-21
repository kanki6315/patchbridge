# USB bypass and request queue — 2026-10-21

Candidate: qc-mcp commit `f634ecd3dcf426090b90bc4cc176e4b500494b9e`, as on 2026-10-20.
Host: macOS arm64, Python 3.14.6. Device: Quad Cortex, CorOS 4.1.1, direct USB,
Cortex Control and the Mac bridge closed. Disposable preset: `Tremonti w Mic`,
scene F. Raw evidence is in `hardware-results/2026-10-21/`.

## Verified

- `set_bypass` through `USBAdapter` on block `0:2` (Neural Capture, model 14000):
  off and back on, each confirmed by preset readback in about 1.4 s. The write is
  qc-mcp's `set_block_bypass`, one flag for the active scene.
- This block's bypass is assigned to scenes: only scene F's flag changed; A and B
  stayed bypassed and C–H on.
- Each bypass write draws three replies (`UndoRedo`, a `Grid` echo, `PresetDirty`);
  the stream is otherwise about 4 `GlobalTempo` a second.

## qc-mcp request queue doubling

The first adapter run confirmed the off-write, then hung reading back the on-write
and grew to about 8.6 GB in four minutes. The QC was not flooding: qc-mcp's
`request()` rebuilds its pending list as `keep + pending` when the reply arrives, and
its `is not` check against a new tuple never removes the reply. Every queued message
is copied on each read, so the list doubles per read; with three raw reports
outstanding the list held 64,179 copies of the same messages.

This affects every USB session, not only bypass: one snapshot is five reads and the
bridge polls every 2 s. Upstream has no later commit. qc-mcp is now vendored in
`vendor/qc-mcp` with `request()` fixed there (see its `VENDORED.md`), and `USBAdapter`
also drops streamed broadcasts after each read so long sessions don't accumulate them.
Through the vendored copy, the same run confirmed off and on again, with the queue
peaking at 50 messages and the process at 46 MB.

`tools/verify_qc_bypass.py` repeats the run with a queue monitor and a watchdog.
`tools/probe_qc_stream.py` is a read-only, bounded check of the stream and a block's
bypass flags.
