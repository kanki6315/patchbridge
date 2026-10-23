# Mac bridge shell

Open `dist/Patchbridge.app`. It starts stopped, with live USB/Bluetooth selected.
The bundle ID is `com.arjunakankipati.patchbridge`; both apps share the Patch Cable icon.

## First run

The window opens on a short setup instead of the bridge controls, until it's finished once
(`bridge.setupComplete`). **Welcome** lists the three real steps (USB, close Cortex
Control, open the iPhone app) and offers **Try the simulation**. **Bluetooth** requests
access before the bridge first advertises; it's skipped when access is already granted, and
a denial offers System Settings and rechecks when the app is reactivated. **Ready** shows
the name iPhones will see and offers **Start bridge** or **Not now**. The bridge never
starts without that tap, and the menu-bar popover is unaffected. **Run setup again…** in
Settings shows it from the start; it's available while the bridge is stopped.

## Live connection

1. Connect a QC running verified CorOS 4.1.1 over USB and close Cortex Control.
2. Choose **Start bridge** and allow Bluetooth when macOS requests it.
3. On the iPhone, choose **Find my Mac**, select this Mac and compare the approval code.
4. Choose **Approve** on the Mac, then **I’ve approved it** on the phone.
5. The phone loads the QC snapshot and relevant catalog before allowing supported edits.
   Mac status reflects the actual phone commands and confirmed readback.
6. USB loss pauses editing and preserves approval only while the same phone and helper
   stay alive. The phone retries connect with capped backoff and reloads capabilities
   and state. Edits/saves are never replayed. Bluetooth loss, denial, Stop, Quit or helper
   death clears approval. Device and phone names retain bounded Mac/iPhone fallbacks.

Bluetooth denial/off/service errors and unsupported firmware appear in the existing
status layout. The Mac does not claim to detect Cortex Control itself: USB failure asks
users to check the cable and close it. No dedicated firmware design was provided;
firmware uses explanatory status text.

### More than one device

Up to four devices (for example an iPhone and an iPad) can connect at once and share
the one USB connection. A fifth is told the Mac is already connected to four devices.

- **Approval:** each device compares its own code. The approval card shows one device
  at a time, earliest first, with a count of devices waiting behind it. Approving one
  device never approves another.
- **Devices:** the window lists connected devices with **Disconnect** and, for trusted
  ones, **Revoke Trust**. Devices trusted to reconnect but not connected now are listed
  with **Revoke Trust**. Trust is kept in the Mac's Keychain, so it survives Stop and
  Quit; only Revoke Trust ends it. Disconnecting one device leaves the others editing; that device
  is told it was disconnected on the Mac at its next request.
- **Edits from two devices:** every device can edit. If two edit at once, the first wins
  and the other's edit is not applied; that device reloads before editing again.
- **Recovery:** USB loss pauses every device. Each one reconnects to the shared session
  on its own retry, including devices that were in the background meanwhile.

## Offline walkthrough

Enable **Use simulation** while stopped. This mode never opens USB or Bluetooth.

1. Choose **Start bridge** to launch the bundled simulation helper.
2. Choose **Simulate phone** to create a local approval request.
3. Choose **Deny** to return to the ready state, or **Approve connection** to
   connect and confirm a snapshot through the helper.
4. Use **Check connection** to request another confirmed snapshot, or
   **Disconnect** in the device list to revoke approval.
   **Simulate another device** adds a simulated iPad, which goes through the same
   approval card. With both connected, **Simulate edit from other device** changes the
   gain from the iPad, so the iPhone's next simulated edit is rejected until it reloads.
5. **Simulate helper failure** stops the process and exercises failure handling.
   **Restart bridge** starts a new session; another phone request needs approval.
6. **Stop bridge** clears approval and stops the helper, including when a request
   is awaiting approval. Quitting stops the helper. Closing the window keeps it running by default; Settings can disable that behavior.

The simulated phone uses the production `DeviceSession` approval path, with
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
The artifact remains ad-hoc signed for this Mac; physical end-to-end validation and
distribution signing remain separate work.

## Design implementation and recovery

The 480-point window and menu-bar popover share one model. Stage, Daylight and Match Mac
appearances and the keep-running preference persist. The app starts stopped. Login registration is opt-in and uses the macOS service status. Closing the window preserves approval when keep-running is enabled.
Reopen from the menu bar or Command-0. Settings is Command-comma; Quit is Command-Q.

Use Bridge actions → Simulate USB interruption after approval. The phone approval stays
valid, the last snapshot is marked stale, and the shell automatically reconnects the
simulator and loads a fresh snapshot for every connected simulated device. Bridge actions → Simulate helper failure instead
ends approval and requires a restart. These are offline tests, not hardware validation.

`DeviceSession(allowsRecovery: true)` reports `device_unavailable` for a device/session
failure returned by a still-running helper. `recover` retries only `connect` with capped
exponential backoff. Helper I/O failures still revoke authorization. The editor clears
pending and confirmed state while recovering and reloads capabilities/catalog before
allowing edits. A write with an uncertain outcome is never replayed or marked rejected.
The feature is opt-in so existing hosts retain their fail-closed behavior.

Hello exchanges bounded display names and a shared short code derived from the full
UUID. Names are not authorization credentials. The iPhone app offers an optional display
name; an empty name uses “iPhone”. Names are excluded from diagnostic events.

The packaged app now hosts live BLE/USB. Its actual connection and firmware errors use
the shared status layout; physical end-to-end behavior still needs hardware verification.

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

## Live-host integration validation

Main was merged with the iPhone designs, release configuration and shared icon, including
the subsequent posture-design and release fixes. 51 Python tests and 72 Swift tests
passed, including bundled helper tests. Both Mac and
unsigned iOS simulator builds passed. The relocated package checker passed with the new
bundle ID and icon. Live backend tests inject a simulated helper and peripheral to verify
approval gating, display-name fallbacks, edit outcomes, backoff/recovery without replay,
phone disconnect and helper death. Chunk deadlines now measure inactivity so a progressing
large snapshot can transfer for longer than five seconds. Helper I/O is bounded at 40 seconds
in the live host; the phone allows 60 seconds including Bluetooth transfer.

These are not physical BLE/USB tests. Native UI automation for the new bundle ID is blocked
by organization policy. The artifact is locally ad-hoc signed; distribution signing,
notarization and installed login/notification validation remain pending.
