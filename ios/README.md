# Patchbridge iPhone and iPad app

Native SwiftUI implementation of the regular-iPhone PoC boards in
`docs/design/screens`, the iPhone Duo boards (`duo-*`) beside them and the iPad
boards in `docs/design/ipad`. The app supports iPhone portrait and landscape,
the Duo's inner and outer screens, and iPad in all orientations.

## Run

Open `Patchbridge.xcodeproj`, select a signing team and iPhone, then Run. The
project targets iOS 17 and later. iOS 26+ uses native Liquid Glass; older systems
use system materials, and Reduce Transparency uses solid surfaces.

Regenerate the project after changing its specification:

```sh
xcodegen generate --spec ios/project.yml
```

The development team in `project.yml` is the owner's existing Xcode team;
other developers should replace it.

## Connect or try the demo

Start the Mac BLE bridge as described in `docs/SWIFT_BLE_DEMO.md` from the repo
root. Choose Find my Mac, select the discovered bridge, approve the connection
on the Mac, then tap I've approved it. The phone and bridge terminal display the
same six-character code; the terminal approval command still takes the full
connection token. New connections require fresh approval. Switching apps keeps
the live Bluetooth session and approval, pauses preset polling, and requests a
fresh snapshot on return. Bluetooth background mode allows pending responses to
complete while away. Writes are never replayed; unanswered requests still time
out. Force-quitting, system termination, Bluetooth loss, or ending the Mac bridge
can require reconnecting and approving again.

On physical hardware, verify switching to Safari for several minutes and returning
without another approval, including changing the preset on the QC while away.
Also check a pending edit/save during an app switch and Bluetooth loss while away:
the app must report an uncertain outcome or disconnect without replaying a write.

The Get Patchbridge for Mac button, Share action and Copy action use
`https://patchbridge.arjunakankipati.com/appstorelink` without displaying the full
address as UI text.

Try the demo preset loads the bundled `demo-preset.json`: the captured
`qc-editor.json` fixture renamed Dirty Riffage, without its row 2 Volume utility
(`python3 tools/export_demo_fixture.py` regenerates it). Demo
edits and saves are local to that session and never reach Bluetooth or USB.
Leaving the demo discards them. The demo badge and save wording distinguish it
from a live connection.

## Live Activity and trust

Connection details › Lock Screen has **Show connection status** (iPhone only, off by
default) and **Alert if the connection drops** (off by default; asks for notification
permission when turned on). The activity (`PatchbridgeWidgets`, boards in
`docs/design/live`) starts when a session reaches the preset and mirrors it on the Lock
Screen and in the Dynamic Island: connected, QC/USB lost, connection lost, reconnecting,
approval needed, and a final Disconnected state after an intentional Disconnect, which
stays 15 minutes to show whether edits were left unsaved. Each state has at most one
button. Disconnect and Reconnect run in the app's process through Live Activity intents;
Open Patchbridge opens the app. The activity doesn't keep Bluetooth alive. Drops the user
didn't start alert through the activity, or as a notification when the activity is off.

On the Mac, approving with **Trust this iPhone** (on by default) issues a random trust
token with the connect reply. Both sides keep it in the Keychain: the phone per Mac, the
Mac per device (at most 8; the oldest is dropped). The phone offers it in `hello`; a match
skips the code, so Reconnect is one tap, including after the bridge stops or Patchbridge
quits and reopens. Only **Revoke Trust** in the Mac window ends it; the next Reconnect then
shows Approval needed. Revoking keeps the current connection.

Debug builds take `--activity connected|qcLost|lost|reconnecting|approval|ended` (plus
`--daylight`) to show a sample activity without a Mac.

## Bluetooth disconnects before approval

Bluetooth pairing and Patchbridge approval are separate. Patchbridge requires
fresh approval for each app session; the operating systems may retain a Bluetooth
bond from earlier testing. A Mac that appears in discovery but disconnects before
the approval code can have a pairing/encryption failure. The phone shows a short recovery message. The connection stage and Core Bluetooth
error code are recorded in system logs under the Patchbridge Bluetooth category.

Turn Bluetooth off and back on in Settings on both devices, restart the Mac
bridge, and reconnect. If the failure persists and the other device is listed in
Bluetooth Settings, forget that pairing and reconnect, accepting any system
pairing prompts before approving in Patchbridge. Do not disable the bridge's
required encryption to work around a pairing failure.

## Editing

- The portrait overview shows scene indicators, the four-by-eight grid map,
  and a selectable row's blocks. Landscape offers the full grid and an inspector.
- Open a block for its metadata-backed controls. The dial uses normalized knob
  travel, with 0.1 display-unit steps and hold-and-slide-out 0.05 fine steps;
  controls the QC shows as whole numbers (Transpose SEMITONES) move in whole steps only.
  Dragging sends only on release; tapping the number opens a signed numeric pad.
- Confirmed values remain authoritative. Pending edits are dashed; rejected,
  adjusted, externally changed and saved state are reported. A changed snapshot
  invalidates an in-progress gesture, typed entry or save confirmation.
- Unknown scales and unsupported parameters remain read-only. Scene state is an
  indicator; scene switching, preset browsing and Save As are not exposed in this
  PoC. Save is shown only when advertised by the bridge.
- The On/Off button in a block's header bypasses or re-enables it for the active
  scene, like the QC's own bypass button, and is shown only when the bridge
  advertises `set_bypass`. The readback decides what it shows. A block whose bypass
  isn't assigned to scenes shares one flag, so other scenes follow. The USB write
  uses qc-mcp's `set_block_bypass`; see [USB results](../docs/USB_RESULTS_2026-10-21.md).
- Connection details includes Stage/Daylight appearance and Match iPhone
  appearance. Scene colors remain the QC's reported ARGB values.

On iPad at regular width (`PadWorkspaceView.swift`), the grid, the selected
row's list and a persistent editor panel share one screen: tapping a block in
the grid or list retargets the panel. Grid cells show the block name, scenes
show their QC names, and the number pad, Save confirmation and Connection
details (with Appearance inside) are popovers. Notices sit in the top bar.
Portrait puts the row list beside the panel. Split View, Slide Over, windowed
apps at compact width and accessibility text sizes use the iPhone layout.

On the iPhone Duo (`DuoWorkspaceView.swift`), the layout follows the screen.
The Duo is recognised by its window size (inner 626 × 890 pt, outer
466 × 678 pt); no other iPhone is wider than 440 pt, so regular iPhones never
reach this code. The inner screen held upright splits at the hinge: the
header, scenes and named grid above, and below it a control deck holding the
row list with Save, or the open block's dial beside its tiles, or the number
pad beside the dial while typing. Nothing interactive sits within 14 pt of the
fold. The outer screen leads with the grid: in landscape a one-line header
holds status, name, scenes and Save, and tapping a block opens the block menu
(first four controls with − value + and Open editor) as a side panel; in
portrait the grid uses codes, scenes are a 4 × 2 set and the menu rises from
the bottom without dimming; the status bar runs down the trailing edge there,
and the tuner and connection buttons sit low in that column, level with Save. The row, selected block and open block menu or
deck editor carry across folding and rotating; a full editor opened from the
outer screen closes on unfolding, and the deck shows that block instead. iOS doesn't report hinge posture to apps, so the
half-folded view (scenes fold into the header strip, the grid grows, the
crease shadow fades in) isn't triggered yet and the inner screen stays flat;
Debug builds accept `--half-folded` to inspect it. The inner screen on its
side and accessibility text sizes keep the existing layouts.

The tuner (`TunerViews.swift`) opens from the tuning-fork button. On iPhone and
the Duo's folded screens the full tuner is a sheet; on iPad and the Duo's inner
screen it is a popover. Mute applies only while the full tuner is open. With
Live tuner on, pitch stays on screen after it closes: on iPhone a line under
the status bar, above the navigation stack so it persists into the block editor,
with ambient light rising around the Dynamic Island and a short highlight
that opens across the bar in tune, without a fitted ring. Both fade when quiet
(stationary feedback with Reduce Motion); on iPad a band in the top bar (its own row in portrait); on the
Duo's inner screen the crease itself, whose light spills into both halves; on
the outer screen in portrait a vertical scale in the status column (sharp up,
toward the camera), with light reaching along the top edge as the string
closes in and gathering at the camera in tune. The
readout publishes from its own object, so only the tuner redraws ten times a
second. Demo mode plays simulated strings. Debug builds accept `--live-tuner`
and `--tuner` with `--demo`.

Native navigation preserves swipe-back. Layout uses scrollable content and
Dynamic Type; numeric values use tabular figures. Buttons and the dial expose
VoiceOver labels and adjustment actions.

## Verification

Run the core and bridge tests from the repo root:

```sh
swift test --package-path swift
PYTHONPATH=src python3 -m pytest -q
```

`PatchbridgeUITests` exercises demo navigation, exact-value validation, editing,
save confirmation, appearance, Mac-link UI, read-only blocks and landscape on
an iPhone Simulator. On an iPad Simulator it runs `testPadWorkspace` instead of
the iPhone navigation test, covering the panel, popovers and both orientations.
On a Duo-sized screen it runs `testDuoWorkspace` instead, covering the deck on
the inner screen or the block menu in both orientations on the outer screen.
iPadOS windowed mode can open the app at compact width; use full-screen apps to
see the iPad layout. Its result bundle retains screenshots. Run it through
Xcode's Test action or `xcodebuild test` with an available iPhone destination.
Debug builds accept `--demo`, `--editor`, `--stage`, `--daylight` and
`--half-folded` launch arguments for reproducible visual inspection; these do not enable live writes.

For marketing captures, Debug builds also accept `--screenshots` instead of
`--demo`. This loads the same Dirty Riffage fixture used by the website boards,
shows the normal connected interface without demo labels, and keeps edits and
saves entirely local. Tuner captures use a stable A2 pitch at +2 cents.
`--duo-editor` opens Opto Comp in the Duo deck or folded block menu.
`--editor --exact-value` opens the native exact-value sheet, popover or inline
pad with −30.00 entered. `--save-confirmation` shows the native Save prompt
without saving anything. `--editor` uses the Duo deck when unfolded and the
full editor when folded; iPad keeps its persistent editor panel.
`--offline-bridge` connects the live coordinator to an in-process bridge
(`DebugBridge.swift`) serving the demo preset in My Presets 16 and eight other
slots, so listing, switching and Save and switch run without a Mac or QC.
`--dirty` makes its first poll find an edit made on the QC, and `--presets` opens
the preset browser.
These screenshot launch options are unavailable in Release builds.
`tools/capture_app_screenshots.py` captures the same seven features per layout:
overview, parameter editor, exact-value entry, full tuner, Daylight overview,
Save confirmation and preset with live tuner. It uses a 4:00 PM Eastern clock
and matching numbered filenames in `iphone/`, `ipad/`, `duo-folded/` and
`duo-unfolded/` subfolders. The Duo must be in the corresponding posture in
Device Hub: folded captures use the `primary` display at 1398 × 2034, unfolded
captures use `primary-1` at 2007 × 2853. Changing screen power alone does not
change posture. By default, capture iPhone, iPad and folded Duo, then unfold
the Duo and rerun with `--layouts duo-unfolded`. `--features 02 07` recaptures
only those feature numbers (plus any missing files).

```sh
python3 tools/capture_app_screenshots.py --iphone IPHONE_UDID --ipad IPAD_UDID \
  --duo DUO_UDID --app PATH_TO_DEBUG_SIMULATOR_APP --output output/app-screenshots
```

This implementation has been built and exercised in the iPhone Simulator.
Live Bluetooth pairing, hardware editing and fine-gesture feel still require
validation on a physical iPhone with the Mac bridge and QC.

## Privacy manifest

`Patchbridge/PrivacyInfo.xcprivacy` is bundled with the app. It declares no
tracking or collected data, app-local preferences (`CA92.1`) and elapsed-time
measurement (`35F9.1`). Bluetooth access uses the system permission prompt;
no additional app capabilities are required for the current foreground client.

## Release to TestFlight

The project includes the Patch Cable icon, explicitly targets iPhone, and supplies
supported orientations.


The repository-root `release_ios` adapts the Harbor/Cuekeeper/Telemetee release
workflow for the iPhone app. Create the app in App Store Connect with bundle ID
`com.arjunakankipati.patchbridge`, sign into Xcode with your developer account,
and have XcodeGen and Python 3 installed. The team and marketing version come
from `ios/project.yml`.

```sh
./release_ios                              # tests, archive, upload, local Git tag
./release_ios --no-upload                  # tests, archive, export IPA only
./release_ios --skip-tests --build 42       # use a known build number
./release_ios --no-upload --allow-dirty     # package uncommitted work; never tag
```

By default the script runs the Swift core tests, offline Python tests and iPhone
UI tests before signing. Set `TEST_DESTINATION` to an installed simulator if the
automatically selected compatible iPhone is unavailable. `--skip-tests` is for a revision whose tests
have already passed. No CloudKit or widget steps are included. The separate `./release_macos` script
uses the same flags and uploads the Mac app by default; see [Mac packaging](../docs/MAC_PACKAGING.md).

Copy `.release.env.example` to `.release.env` for optional overrides; it is
Git-ignored. The default uses your Apple ID in Xcode. The optional `ASC_KEY_ID`,
`ASC_ISSUER_ID`, and `ASC_KEY_PATH` variables enable API-key authentication using
the copied `asc_profile.py` helper and a local Apple Distribution certificate
with its private key. The helper can register the bundle ID and create/refresh
its App Store provisioning profile. It does not create the App Store Connect
app listing. Credentials are not copied from the example projects.

Outputs and logs go to `build/release/<version>-<build>/`. Automatic build numbers
use days since January 1, 2026 plus UTC hour and minute, within the 4/2/2 digit
format. Choose a different `--build` for another attempt in the same minute or
when the output directory already exists. Export options keep that build number
rather than letting Xcode change it.

A successful upload from a clean, unchanged checkout creates a local tag such
as `ios/v0.1-293.18.30`; the script does not push it. `--no-upload` avoids uploading
the app but still requires signing and may access Apple's provisioning service.
Release workflow tests stub build/signing tools so they never upload anything.


## App icon

The app icon is `Patchbridge/AppIcon.icon`, an editable Icon Composer document.
It uses the selected original “03 Patch Cable” design, rebuilt as SVG with both
segmented jack ends, chartreuse foreground, and a dark olive background. Open the
`.icon` document in Icon Composer to edit its appearance. The imported vector is
in `AppIcon.icon/Assets/patch-cable.svg`; its standalone design source and exported
default, dark, and tinted previews are in `../docs/design/brand/`. Keep the two
SVG copies in sync when changing the mark. `project.yml` sets `AppIcon` as the
primary icon and includes the document through the `Patchbridge` source folder.
Xcode compiles the layered icon and generates fallback PNGs for older iOS versions.

## App Store preview videos

Debug captures can play a shared native 28-second story with
`--screenshots --stage --preview-story`: overview, Opto Comp threshold editor,
exact entry of −30 dB, tuner, live tuning, Save confirmation, and saved preset.
The capture requests portrait orientation. All edits use the offline fixture;
the sequence and its view hooks are excluded from Release builds.

Build Debug for Simulator, then capture on booted simulators (the Duo must be
unfolded in Device Hub):

```sh
python3 tools/capture_ios_previews.py --app PATH_TO_DEBUG_SIMULATOR_APP \
  --iphone IPHONE_UDID --duo UNFOLDED_DUO_UDID --ipad IPAD_13_UDID \
  --output output/ios-app-previews/raw
python3 tools/render_ios_previews.py output/ios-app-previews
```

The renderer requires Pillow, ffmpeg and ffprobe; `FFMPEG` and `FFPROBE` can
select specific binaries. It exports matching 886 × 1920 iPhone/Duo and
1200 × 1600 iPad MP4s with shared captions. Native footage is fitted without
stretching or cropping controls. Each is 28 seconds at 30 fps, H.264 High
Level 4.0, with a silent stereo AAC track. No guitar sound is implied by the
simulated tuner. Sources, caption assets, sampled QA frames and technical
validation are retained alongside the videos. `--layouts duo` recaptures a
single family; add `--duo-display primary` for a folded Duo. Review all three videos before submitting in App Store Connect.

The revised silent editorial cut is generated by
`tools/render_ios_previews_v2.py output/ios-app-previews-v2`. Capture into that
folder's `raw/` directory first. The Debug story now exercises the native dial's
draft and commit path, then exact entry; its simulated tuner settles from flat
to A2 in tune. Static screenshot captures retain their fixed pitch.

The v2 renderer trims idle holds to 25 seconds, adds staggered Archivo headline
motion, and uses editorial control close-ups with short dissolves. It preserves
real-time interactions and exports the same App Store dimensions and codecs.
Pass `--font PATH_TO_ARCHIVO_EXTRABOLD_TTF` (converted from the site's existing
Archivo variable font) and optionally `--layouts iphone duo ipad`. Its default
font path is `build/ios-preview-design/Archivo-ExtraBold.ttf`. Original previews
remain in `output/ios-app-previews`; revised files and frame checks are separate.
