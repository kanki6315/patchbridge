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
   is awaiting approval. Quitting stops the helper. Closing the window keeps it running by default; Settings can disable that behavior.

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

## Design implementation and recovery

The 480-point window and menu-bar popover share one model. Stage, Daylight and Match Mac
appearances and the keep-running preference persist. The app starts stopped. Login registration is opt-in and uses the macOS service status. Closing the window preserves approval when keep-running is enabled.
Reopen from the menu bar or Command-0. Settings is Command-comma; Quit is Command-Q.

Use Bridge actions → Simulate USB interruption after approval. The phone approval stays
valid, the last snapshot is marked stale, and the shell automatically reconnects the
simulator and loads a fresh snapshot. Bridge actions → Simulate helper failure instead
ends approval and requires a restart. These are offline tests, not hardware validation.

`BridgeSession(allowsRecovery: true)` reports `device_unavailable` for a device/session
failure returned by a still-running helper. `recover` retries only `connect` with capped
exponential backoff. Helper I/O failures still revoke authorization. The editor clears
pending and confirmed state while recovering and reloads capabilities/catalog before
allowing edits. A write with an uncertain outcome is never replayed or marked rejected.
The feature is opt-in so existing hosts retain their fail-closed behavior.

Hello exchanges bounded display names and a shared short code derived from the full
UUID. Names are not authorization credentials. The iPhone app offers an optional display
name; an empty name uses “iPhone”. Names are excluded from diagnostic events.

Not implemented: live BLE/USB hosting in the packaged app and live firmware/connection error UI.
The designs remain targets for those features, not claims about the offline package.

### Validation of this slice

40 Python tests and 57 Swift tests passed, including the bundled-runtime tests.
The unsigned iOS simulator build passed. Native Mac UI checks covered start,
approval, simulated USB interruption and automatic recovery, and Daylight settings.
The package checker passed relocation, isolation, diagnostic export and nine in-memory
USB/protobuf checks. No physical BLE or USB connection was opened.

The expanded bundled tests exposed an unbounded Foundation `Process.waitUntilExit`
call during cross-thread shutdown. Helper cleanup now uses bounded exit observation
after EOF, terminate and kill; Foundation remains responsible for reaping the child.

## Desktop features

- **Notifications:** off by default. Enabling asks macOS for alert permission (no sound).
  Approval requests, device recovery and helper failure generate one notification per
  transition. Notifications contain no preset contents or session tokens; their only
  action opens the current app state. Resolved alerts are removed, including late
  asynchronous deliveries. There is no notification action that grants authorization.
  Denied permission and delivery errors appear in Settings; the menu bar always works.
- **Open at login:** uses `SMAppService.mainApp`, never a hand-written LaunchAgent.
  Status is read from macOS on activation and after changes. Pending system approval,
  unavailable registration and errors have visible explanations. It is not enabled
  automatically. This local ad-hoc build currently reports registration unavailable;
  actual login launch still needs verification with the installed distribution build.
- **Show in Dock:** on by default; changes the activation policy immediately and persists.
  The status item is installed before applying the policy, so hiding the Dock never
  removes Open, Settings or Quit. The keep-running preference remains independent.
- **Recent edits:** an in-memory ring of 12 command outcomes, newest first, with the
  preset/scene and time. The popover shows three. Names come from the active catalog,
  values from confirmed readback; normalized values without display conversion are
  omitted. Rejections and unknown outcomes are distinct. History survives a helper
  failure/stop so uncertain results remain visible, and is cleared explicitly or at
  process exit. It is never persisted or included in exported diagnostics.

Bridge actions → Simulate gain edit sends a real simulator command; Simulate rejected
edit sends a deliberately stale revision. These controls exercise the same bridge
observer used by history, rather than inserting sample UI rows. They never access USB.

Missing-design defaults: empty history is inline text; long history scrolls with primary
actions fixed below; errors use an icon and explanatory text; settings use native controls.
Permission requests and login registration happen only through their explicit settings.

Desktop-feature validation: 40 Python tests and 65 Swift tests passed, including the
bundled-runtime tests. The rebuilt package passed relocation, isolation, diagnostics
and nine in-memory USB/protobuf checks. Native UI checks covered empty history,
confirmed and rejected edits, Settings, and hiding/restoring the Dock icon. Injectable
services verified notification permission races, deduplication, obsolete-alert removal,
delivery errors and actual login-status handling without changing OS permissions.
Real notification delivery and login launch remain to be tested on an installed build
with the relevant macOS permissions.
