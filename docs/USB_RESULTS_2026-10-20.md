# USB compatibility investigation — 2026-10-20

Candidate: qc-mcp commit `f634ecd3dcf426090b90bc4cc176e4b500494b9e`
from https://github.com/lexasoft123/qc-mcp (MIT).
Host: macOS 27.0.1 arm64, Python 3.14.6, protobuf 7.36.2.
Device: Quad Cortex, USB 152a:880a, reported CorOS 4.1.1.
Direct USB, Cortex Control closed. Disposable preset: `Tremonti w Mic`,
My Presets position 16 (wire index). Raw evidence is in
`hardware-results/2026-10-20/`.

## Verified

- Handshake and firmware-selected 4.1 schema.
- Full preset read and live ModelRepo payload; 633 catalog models parsed.
- Myth Drive numeric gain write/readback and restoration; one observed
  edit-to-readback time of 156 ms, not a performance guarantee.
- Volume curve switch, Dual Chorus sync-note selector and rate normalized-value
  write/readback, with original values restored. Display conversion accuracy
  for nonlinear values remains unverified.
- Scene selection F to G and back. Scene-specific parameter writes remain untested.
- User physical gain edit to 1.6 observed through preset polling.
- Repeated clean HID close/open sessions.
- `File CREATE` save: dirty cleared and reload recovered the saved value.
  A second test changed gain from 2.2 to 3.8 before saving, temporarily displaced
  the working value back to 2.2, and recalled the slot: 3.8 returned.
  User independently confirmed 3.8 and that the QC stayed running.

## RecallPreset SAVE investigation

The tested form is `RecallPreset {action: UPDATE, reason: SAVE}` with no preset
payload, sent by `QuadCortex.save_preset()`.

First attempt: dirty remained true, subsequent preset reads failed, reconnect
could not read firmware, and the user observed a restart. After recovery the
preset was readable with the previously stored gain (~3.578), rather than the
unsaved physical edit to 1.6.

Second attempt, explicitly requested by the user after confirming File CREATE:
changed gain from 3.8 to 3.9 and confirmed readback, then sent this save form once.
Dirty readback was false, but the subsequent full preset read returned no data.
No further preset writes were sent. The user confirmed an error followed by a
second restart and supplied a photograph showing the QC's “Rebooting!” screen.
Persistence after this second attempt was not confirmed.

Decision: mark RecallPreset SAVE unsupported and use File CREATE exclusively.
Both historical reproduction scripts are disabled to prevent accidental reruns.
The direct adapter dependency is pinned to the tested qc-mcp commit above.

Do not interpret a cleared dirty flag as proof of durable save. Use File CREATE
for the initial adapter. These results concern this exact command form and
firmware; they do not establish that every RecallPreset SAVE payload is invalid.

## Adapter integration requirements and remaining gaps

- Full snapshot block and parameter addresses come from array positions;
  embedded row/column/index fields can be zero.
- IOHID returns signed `-536850432`, equivalent to documented benign
  `0xe0005000`. Candidate comparison uses the unsigned constant and therefore
  incorrectly counts these as write errors. Normalize before classification;
  retain readback confirmation.
- Candidate catalog parser drops useful XML fields such as `stepNames`, `steps`,
  and toggle dependencies. Preserve these for metadata-driven controls.
- Cable-removal recovery, native asynchronous change events, scene-specific
  edits, amp-model controls, and switching to another slot and back remain
  unverified. Same-slot recall persistence was tested.
- Raw preset snapshots are local recovery evidence; avoid publishing them
  unintentionally.

Hardware scripts in `tools/` are scoped investigation probes for this specific
preset, not a production adapter. In particular, the original
`verify_qc_save.py` contains the failed low-level save experiment and should
not be used as the implementation of saving.
