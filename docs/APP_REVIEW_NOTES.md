# App Review notes

Paste each block into App Store Connect › App Review Information › Notes for its
platform. Each is under the 4,000-character limit. Replace the video link
placeholder before submitting.

## iOS and iPadOS

```text
Patchbridge is a remote editor for the Neural DSP Quad Cortex, a guitar amp/effects floor unit. The iPhone/iPad app never talks to the Quad Cortex directly: it connects over Bluetooth LE to the companion app "Patchbridge for Mac", which holds the USB connection to the Quad Cortex. No account, sign-in, Wi-Fi network or server is involved.

HOW TO REVIEW WITHOUT HARDWARE
You don't need a Quad Cortex or a Mac to see the full editor.
1. Launch the app. On the welcome screen, tap "Try the demo preset".
2. A bundled preset ("Dirty Riffage") opens with its signal chain. Tap any block to open it, drag a slider or type an exact value, and use the block's switch to turn it on or off.
3. Tap Save. The app confirms "Saved in demo only". Demo edits stay on the device and are discarded when you leave the demo; nothing is sent over Bluetooth or USB.
The demo works the same on iPhone (portrait and landscape) and iPad.

LIVE CONNECTION (requires a Mac and a Quad Cortex)
1. On the Mac, open Patchbridge for Mac, connect the Quad Cortex by USB and click Start bridge.
2. On the iPhone, tap "Find my Mac" and select the Mac.
3. Both screens show the same six-character code. Click Approve on the Mac, then tap "I've approved it" on the iPhone.
4. The current preset loads; edits are applied to the Quad Cortex and confirmed by reading them back.
A recording of this flow is here: [VIDEO LINK]

PERMISSIONS AND BACKGROUND MODES
- Bluetooth (NSBluetoothAlwaysUsageDescription): needed to find and talk to the user's Mac. It is requested only when the user taps "Find my Mac", not in demo mode.
- bluetooth-central background mode: keeps an in-progress request to the Mac alive while the user briefly switches apps, so an edit or save already sent can report its result. The app does not scan or connect in the background on its own.
- Live Activity: optional, off by default (Connection details › Lock Screen › Show connection status). It shows whether the Mac connection is live and offers one button (Disconnect, Reconnect or Open).
- Notifications: requested only if the user turns on "Alert if the connection drops", which is off by default.

OTHER NOTES
- "Get Patchbridge for Mac" links to the Mac app on the App Store.
- The app collects no personal data and has no analytics, ads or tracking.
- Patchbridge is an independent app and is not affiliated with or endorsed by Neural DSP. "Quad Cortex" is used only to describe compatibility.
```

## macOS

```text
Patchbridge for Mac is the bridge for the Patchbridge iPhone/iPad editor. It connects to a Neural DSP Quad Cortex (a guitar amp/effects floor unit) over USB and lets an approved iPhone or iPad edit it over Bluetooth LE. No account, sign-in, network connection or server is involved.

HOW TO REVIEW WITHOUT HARDWARE
The app has a built-in simulation that needs no Quad Cortex, iPhone or Bluetooth.
1. Launch the app. On the first-run Welcome screen, click "Try the simulation". (After setup, the same switch is "Use simulation" in the main window while the bridge is stopped.)
2. Click Start bridge. The status text confirms Bluetooth and USB are off in this mode.
3. Click Simulate phone. An approval request appears with a six-character code; click Approve.
4. The simulated preset, scene and save state appear. The "…" Simulation actions menu exercises edits, a second device, a rejected edit, USB interruption and helper failure; each shows in Recent edits and status.
5. Click Stop bridge to end the session. Export report… (Command-E) saves a diagnostics report to a location you choose.
Note: in simulation the Mac does not advertise over Bluetooth, so the iPhone app cannot connect to it. The iPhone app has its own demo ("Try the demo preset") for review.

LIVE CONNECTION (requires a Quad Cortex and the iPhone app)
1. Connect the Quad Cortex by USB and close Neural DSP's Cortex Control app.
2. Click Start bridge and allow Bluetooth when asked.
3. On the iPhone, tap "Find my Mac", then compare the code and click Approve on the Mac.
A recording of this flow is here: [VIDEO LINK]

ENTITLEMENTS AND BUNDLED CODE
- App Sandbox is on.
- com.apple.security.device.usb: talks to the Quad Cortex over USB. USB is opened only after the user approves a phone on the Mac, never in simulation.
- com.apple.security.device.bluetooth (NSBluetoothAlwaysUsageDescription): advertises the bridge so the user's iPhone or iPad can find it. The bridge never advertises until the user clicks Start bridge.
- com.apple.security.files.user-selected.read-write: saving the diagnostics report where the user picks in the save panel.
- The app bundles a signed Python runtime and helper inside the app bundle. It runs as a child process with an inherited sandbox (com.apple.security.inherit) and handles the USB protocol. It downloads or installs no code.

OTHER NOTES
- Up to four iPhones/iPads can connect at once; each must be approved on the Mac, and trust can be revoked from the device list.
- The app collects no personal data and has no analytics, ads or tracking. Diagnostics reports leave out preset contents and device identifiers and are only saved locally when the user chooses.
- Patchbridge is an independent app and is not affiliated with or endorsed by Neural DSP. "Quad Cortex" and "Cortex Control" are used only to describe compatibility.
```
