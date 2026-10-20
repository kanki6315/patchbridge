# Offline Mac helper package

`dist/Patchbridge Offline.app` is a local, standalone simulation host. Open it in
Finder to open the stopped bridge shell. Choose Start bridge, Simulate phone
connection, and Approve connection to read a snapshot from the bundled simulator.
Closing the window stops the helper. No terminal,
Homebrew, separately installed Python, Bluetooth advertising, or USB access is
needed at runtime. The existing installed phone app and BLE demo are unchanged.

The compact native shell uses `HelperClient(bundle: .main)` on its worker queue
and the serialized `BridgeSession` approval path. Phone requests are simulated
locally; real phone discovery and radio connections are not enabled.
See [Mac bridge shell](MAC_BRIDGE_SHELL.md) for controls and verification.

## Build and check without downloads

From the repository root, with the existing local arm64 CPython 3.14 and Xcode:

```sh
/opt/homebrew/bin/python3 tools/package_mac.py
/opt/homebrew/bin/python3 tools/check_mac_package.py
tools/check_offline.sh
```

Additional local build inputs are the already captured qc-mcp checkout at
`/private/tmp/patchbridge-qc-mcp` and protobuf in `.venv-hardware`. The builder reads
qc-mcp Git objects at `f634ecd3dcf426090b90bc4cc176e4b500494b9e`, never mutable working
files, and verifies protobuf files against the installed wheel's SHA-256 RECORD.
Missing inputs fail the build without fetching anything. Unrelated MCP-server,
bridge/FIFO, Windows, and audio modules/dependencies are not included. Protobuf's
universal extension is thinned to arm64 and given a relocatable library ID before
signing. Its original wheel bytes are verified before modification. Native audit
accepts only system libraries and the explicitly identified bundled library IDs.

The builder replaces only the fixed generated `dist/Patchbridge Offline.app`.
It compiles a native Swift/AppKit host and C helper launcher, copies the local
CPython library, pure-Python standard library, and the native extension closure needed by simulation and the direct USB adapter.
It includes pinned qc-mcp transport/protocol/macOS HID modules and their binary
schemas, plus protobuf 7.36.2 with its native upb extension. Python, qc-mcp, and
protobuf licenses are included. No pip,
package manager, network, interpreter discovery, or downloads occur.

The current runtime is CPython 3.14.6, arm64, built for **macOS 26.0+**. The builder
reads that deployment floor from the actual runtime rather than claiming older
macOS support. It is about 20 MB on disk. The manifest inside
`Contents/Resources/build-manifest.json` records runtime/version/platform and
SHA-256 hashes of packaged files before the final app signature.

## Runtime isolation and lifecycle

- `Contents/MacOS/patchbridge-helper` embeds the bundled `Frameworks/Python` through
  a relative loader path. The build rejects non-system dynamic dependencies other
  than the exact bundled Python reference and protobuf extension self-identity.
- CPython uses isolated configuration and explicit bundle-only import paths.
  It ignores PYTHONHOME, PYTHONPATH, user site packages, and the working directory.
  Bytecode writes are disabled so launch cannot modify the signed bundle.
- Normal startup always runs `patchbridge.helper --adapter simulated`. Additional offline launcher options are `--verify-usb-fixtures <fixture-root>`
  (fixed verification) and `--captured-read-only <qc-editor.json>` (read-only
  process host for coordinator/recovery tests). `--adapter usb` and arbitrary Python arguments are
  rejected. USB code/dependencies are present, but live USB startup is disabled.
- The Swift bundle initializer never falls back to a system interpreter. Its
  environment is limited to system PATH and a UTF-8 locale. Explicit Python/source
  paths remain available only in the development initializer.
- The host owns the process on a worker queue. Closing it closes helper stdin;
  existing bounded terminate/kill cleanup handles a helper that fails to exit.
  Startup/protocol failures are shown in the host window. No automatic mutation
  retries or background launch agents are installed.

## Verification performed

The package self-test starts the helper through the production bundle initializer,
connects, changes gain, saves, verifies clean readback with the changed gain, and
stops the process. The independent check copies the app to a directory containing
spaces, verifies its signature, and repeats the test with an empty PATH, temporary
HOME, invalid PYTHONHOME, and hostile PYTHONPATH/current-directory modules.
It also checks stdin EOF exit, absence of bytecode writes, explicit failure
when the bundled helper or schema is missing, and rejection of live USB arguments.
The relocated bundle runs nine additional checks with separately copied captured
inputs: actual protobuf decoding, snapshot/catalog agreement (16 blocks/11 models),
real Grid message serialization and edit readback, File CREATE save serialization,
physical scene/routing conflict rejection, unconfirmed save/edit invalidation,
read timeouts, and read-only enforcement before any HID mutation. The upstream transport writes only to an injected memory HID fake;
real transport construction/open paths and IOKit enumerate/open/write functions
are blocked by the checker. Importing the HID module resolves system libraries
but does not enumerate or open devices. RecallPreset SAVE remains unsupported.

The private captured preset/catalog files are supplied as test inputs, never
included in the app. Re-run just the bundle checker with:

```sh
"dist/Patchbridge Offline.app/Contents/MacOS/patchbridge-helper" --verify-usb-fixtures "$PWD"
```

Expected failure scenarios emit diagnostic tracebacks on stderr; the final JSON
report on stdout records the checks that passed. Tests run without opening a window or radio.
The native window's simulated approval, denial, connection check, helper failure,
restart, stop, and report export were exercised through the UI on 2026-10-20.

## Distribution work remaining

The artifact is **ad-hoc signed**, not Developer ID signed or notarized. It is for
local use on this Mac, not a Gatekeeper-ready release. For distribution, use a
controlled runtime build with the desired minimum macOS version/architectures,
complete live validation of the bundled USB adapter with the user present, add production
signing/hardened-runtime configuration and notarization, and test on a clean Mac.
Do not enable USB simply by changing the simulator flag: these tests validate the
packaged dependency/protocol path against recorded evidence, not real IOKit device
access or hardware behavior. Live USB activation remains separate authorized work.
Optional stdlib OpenSSL, LZMA, and Zstd extensions are omitted; the QC catalog path
uses gzip/zlib, which is included and tested.

See [read-only mode and recovery](READ_ONLY_QC.md) for the packaged Swift integration
test and the explicit source USB read-only policy. Live USB remains disabled in
the app launcher.

The host also offers **Export Troubleshooting Report…** (Command-E). See
[diagnostics](DIAGNOSTICS.md) for excluded data, retention, and offline export checks.
