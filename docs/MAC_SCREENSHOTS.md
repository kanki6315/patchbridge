# macOS marketing previews

Run on an Apple silicon Mac with Xcode 26 or later, Node.js, and Google Chrome:

```sh
npm ci --ignore-scripts --prefix site
python3 tools/capture_mac_screenshots.py --output output/mac-screenshots
```

The command builds a separate DEBUG renderer in `build/mac-screenshots`, then exports four 2880 × 1800 PNG previews and their uncomposited native window captures in `native/`. A ZIP alongside the output folder contains the four previews and this guide. The composition follows `site/public/og.png` and `tools/render_og_image.mjs`: Archivo 800 headings, the original Patch Cable mark, the site tagline, and an olive radial background over Stage Black. A 600 × 890-point native window is enlarged about 1.9×; explanatory text is 44 pixels. The set uses Stage appearance and fictional device names. The four stories are USB connectivity, approval, multiple devices, and trusted reconnects.

These are native SwiftUI/AppKit view renders with offline presentation fixtures, not captures of a physical USB session. The ordinary connected UI is deliberately used without the simulation badge. Preset, scene, catalog and confirmed parameter values come from `tests/fixtures/demo-preset.json`, the same fixture used for website and iOS screenshots. Approval and trust fixtures use fictional identifiers and names. No helper, USB transport, Bluetooth peripheral, or real trust registry is constructed.

The renderer lives in `mac/ScreenshotPreview.swift`, wrapped entirely in `#if DEBUG`; its command-line entry in `mac/main.swift` has the same guard. Release builds cannot invoke it. A private temporary UserDefaults suite keeps screenshot settings separate from the installed app and is removed after rendering. The installed production app is not replaced or launched. Normal edit timestamps still default to the current date.

To change copy, device names, or the five states, edit `MacScreenshotPreview.render`. Composition lives in `tools/render_mac_previews.mjs`; it uses the existing site font package and brand SVG. To recompose already captured native windows, run `node tools/render_mac_previews.mjs output/mac-screenshots`. The output retains a manifest and standalone HTML layouts for inspection. Keep marketing copy outside the native window. If adding features, use states the real bridge supports and inspect all exported images for clipping. Do not publish the raw fixture state as evidence of a hardware test.

## 1080p video review cut

```sh
python3 tools/render_mac_preview_video.py output/mac-screenshots
```

Requires Google Chrome, Node.js, the site font dependency, FFmpeg with libx264, and ffprobe. Set `FFMPEG` and `FFPROBE` to explicit binary paths when using isolated tools. The command recomposes the five scenes at 1920 × 1080 (no stretched or cropped screenshot canvases), holds each for 5.6 seconds with 0.5-second dissolves, and exports a 26-second MP4. It preserves the approved Archivo/Patch Cable styling, fictional device names, and 4 PM times. The AAC stereo track is intentionally silent; all explanations are readable without sound.

Encoding: H.264 High Profile Level 4.0, progressive 30 fps, yuv420p, 11 Mbps target, stereo AAC at 48 kHz and a 256 kbps encoding target. Silent AAC compresses below that target. The script verifies resolution, codec/profile, frame rate, duration, video bitrate and file size, and saves ffprobe output plus a poster extracted at 5 seconds.

**This is a screenshot-based review cut, not submission-ready recorded footage.** Apple’s guideline 2.3.4 requires video screen captures of the app itself; the input here consists of native-view still renders. Before App Store submission, replace the static scenes with actual recorded app interactions and retain simple dissolves and explanatory overlays. Encoding compliance does not establish content approval. No video was uploaded or submitted.

Apple guidance checked October 21, 2026:
- [App preview specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications/): Mac 1920 × 1080 landscape, 15–30 seconds, maximum 30 fps, maximum 500 MB, H.264 target 10–12 Mbps.
- [App preview creative guidance](https://developer.apple.com/app-store/app-previews/): app footage, readable text, simple transitions, understandable with sound muted.
- [App Review Guidelines, 2.3.4](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata): video screen captures of the app; explanatory narration and overlays allowed.

## Record actual fixture-app clips

Prepare a separate DEBUG app:

```sh
python3 tools/capture_mac_screenshots.py --prepare-replay
```

Open `build/mac-screenshots/Patchbridge.app`. This app runs the real `BridgeWindow` with an offline backend and a private temporary preference suite. It is separate from `/Applications/Patchbridge.app`; quit the installed app first because both carry the production bundle identifier. No USB, Bluetooth, helper process, or real trust storage is used. All replay code is DEBUG-only.

Start a native screen recording cropped to the complete fixture window. Choose **Patchbridge → Play Recording Sequence** (Command-R). After a three-second lead-in it plays five consecutive 5.6-second flows: connected/save confirmation, approval/verification/connected, second device joining, parameter readbacks and save, then trusted-device reconnection. Stop after at least 32 seconds. These transitions are driven by fixture events in the running app, not baked into an image. The replay can be restarted from the menu.

The initial seconds should be trimmed so `--start` points to the first connected segment after the lead-in. Compose the recorded clips inside the same approved visual treatment:

```sh
python3 tools/render_mac_preview_video.py output/mac-screenshots \
  --recording /absolute/path/to/window-recording.mov --start 4.2
```

The start value is an example; measure it from the actual recording. Each segment is trimmed to 5.6 seconds and the original recording is scaled proportionally into the window area; the five segments are joined with 0.5-second dissolves. The result is `Patchbridge-Mac-Preview-Clips-1080p.mp4`. A window-only recording avoids capturing unrelated desktop content. Preserve fictional fixture provenance; this is not a physical USB validation run.

Use `--crop width:height:x:y` when the recording includes margins around the app window. The editor normalizes variable-frame-rate recordings before trimming so scene boundaries stay consistent. Use `--reuse-backgrounds` to reuse previously rendered 1080p layouts. Generated images, recordings, and videos remain local in `output/`; do not commit them.
