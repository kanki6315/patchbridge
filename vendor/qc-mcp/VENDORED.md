# Vendored qc-mcp

The USB transport Patchbridge uses to talk to the Quad Cortex, copied from
[qc-mcp](https://github.com/lexasoft123/qc-mcp) at commit
`f634ecd3dcf426090b90bc4cc176e4b500494b9e` under its MIT license (`LICENSE`).
The layout mirrors upstream so its paths keep working.

## What is here

- `src/qc_mcp/`: `transport`, `protocol`, `backend`, `iohid`, `preset`, `directory`
  (what the Mac app bundles) and `catalog` (used by hardware tools).
- `tools/build_descriptors.py` and `tools/extract_protos.py`, which generate the
  protocol descriptors.

Left out: the MCP server, daemon, leveling, audio, GUI and reverse-engineering
tools, Cortex Control bridge mode (`bridge`, `winbridge`) and Windows HID
(`winhid`). `backend` imports those only when asked for them.

## Not committed: Neural DSP material

This repository is public, so files derived from Neural DSP software stay out of
git (see `.gitignore`):

- `src/qc_mcp/descriptors/qc_descriptors-<version>.pb`, the QC's protocol
  schema, extracted from the Cortex Control app. Generate it locally from your
  own installed copy:

      PYTHONPATH=vendor/qc-mcp/src .venv-hardware/bin/python vendor/qc-mcp/tools/build_descriptors.py build 4.1

  Packaging copies it into the Mac app. Without it, `protocol` falls back to
  scanning the installed Cortex Control at runtime.
- `src/qc_mcp/ModelRepo.xml`, upstream's snapshot of the device catalog.
  `catalog` needs `load_from_bytes` with the live `ModelRepo` payload instead;
  the USB adapter reads the catalog from the device on every connect.

## Local changes

- `transport.QuadCortex.request()`: upstream rebuilt the queue as
  `keep + _pending` when the reply arrived, queuing every earlier message twice
  and keeping the reply, so the queue doubled on each read. Patchbridge keeps
  what follows the reply once. See `docs/USB_RESULTS_2026-10-21.md`.
- `transport.REPLY_POLL_S`: `request()` and `_read_preset_once()` poll every 10 ms
  instead of 100–150 ms. The HID backend sleeps the full poll interval, so upstream
  added that much latency to every read; a snapshot is six reads.
- `iohid.IOHIDTransport.read_reports()`: a condition variable now wakes reads on
  incoming reports and drains buffered reports immediately. The 10 ms interval is
  a maximum wait, not a mandatory sleep. Handshake calls explicitly retain their
  full settling delays via `_collect(wait_full=True)`. See
  `docs/SYNC_BENCHMARK_2026-10-23.md` for hardware measurements.
- Startup accepts complete zero-ID Version/ModelRepo replies only in an owned,
  exclusive session after draining queued messages. Other state retains its
  existing matching behavior. The handshake no longer requests ModelRepo twice.
- `list_directory(folder_key=...)` reads one preset folder and requires an echoed
  request ID, matching folder/type, and all 256 slots before returning. The adapter
  uses this for My Presets instead of streaming IR/capture/factory directories.
- `iohid.IOHIDTransport` registers an IOKit removal callback. Once the cable is
  pulled, `set_report()` and `read_reports()` raise at once (a waiting read is
  woken), so the adapter fails the session instead of treating unanswered reads
  as a QC that is mid scene change for 20 s.

When updating, copy the same files from the new commit, reapply the local
changes unless upstream fixed them, and update the commit here, in
`tools/package_mac.py` (`QC_COMMIT`) and in `tools/preflight.py`.
