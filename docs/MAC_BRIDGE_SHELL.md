# Offline Mac bridge shell

Open `dist/Patchbridge Offline.app` for the compact native status window.
The bridge starts stopped. Bluetooth and USB stay off throughout this workflow;
no iPhone or QC is required. The iOS design work is unchanged.

## Local walkthrough

1. Choose **Start bridge** to launch the bundled simulation helper.
2. Choose **Simulate phone connection** to create a local approval request.
3. Choose **Deny** to return to the ready state, or **Approve connection** to
   connect and confirm a snapshot through the helper.
4. Use **Check connection** to request another confirmed snapshot, or
   **Disconnect phone** to revoke approval.
5. **Simulate helper failure** stops the process and exercises failure handling.
   **Restart bridge** starts a new session; another phone request needs approval.
6. **Stop bridge** clears approval and stops the helper, including when a request
   is awaiting approval. Closing the window or quitting also stops the helper.

The simulated phone uses the production `BridgeSession` approval path, with
`HelperClient(bundle:)` executing the packaged process. It does not use a radio.
Work runs on a serial worker queue; a generation token prevents a delayed
completion from restoring an obsolete UI state after stop. Failed operations
clean up the session without replaying mutations.

## Diagnostics

**Export report…** is available even while stopped or failed. Command-E also
opens the save sheet. Reports contain bounded structured lifecycle events and
error codes; preset contents, names, values, raw messages, paths, and device or
session identifiers are excluded. Reports are written only on explicit export.
See [diagnostics](DIAGNOSTICS.md) for the format and retention policy.

## Verification

Offline model tests cover real simulator approval/denial, disconnect, helper
failure and restart, stopping during launch, startup failure, and the packaged
helper approval path. The rebuilt app passed all four offline preflight gates,
including relocated package checks and the fixture/process test suite.

On 2026-10-20, UI checks verified start, deny, approve, confirmed snapshot,
connection check, simulated helper failure, restart with fresh approval, stop
with a pending request, and export through the native save sheet. Screenshots
confirmed readable approval, connected, and failure states. The exported report
was inspected and contained the expected structured events without preset data.
The app was left stopped.

This verifies local shell behavior, not physical BLE/USB compatibility.
The artifact remains ad-hoc signed for this Mac; live transport integration and
distribution signing are separate work.
