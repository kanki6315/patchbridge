# Mac bridge package

`dist/Patchbridge.app` is a standalone native Mac bridge with bundle ID
`com.arjunakankipati.patchbridge`. It uses the same Patch Cable Icon Composer asset
as the iPhone app. It starts stopped. **Start bridge** starts Bluetooth advertising
and the bundled USB helper; USB opens only after a phone is explicitly approved and
requests a connection. The iPhone must compare the code, then tap **I’ve approved it**.
Close Cortex Control and connect a QC running verified CorOS 4.1.1.

**Use simulation**, available while stopped, selects the offline walkthrough instead.
That mode never starts a radio or opens USB. Self-tests and report-export CLI checks
also remain simulated. No Homebrew or separately installed Python is needed at runtime.
See [Mac bridge shell](MAC_BRIDGE_SHELL.md) for controls and limitations.

## Build the runtime

The bundled CPython and protobuf are built from source so that every bundled binary
has a dSYM. Prebuilt runtimes such as Homebrew's discard their object files, so their
crashes can't be symbolicated. Build once, and again only when the pins change:

```sh
/opt/homebrew/bin/python3 tools/build_runtime.py
```

This is the only step that downloads anything. It fetches the pinned CPython 3.14.6
source and protobuf 7.36.2 sdist, plus the setuptools and wheel wheels used only to
build protobuf. Each is checked against the SHA-256 in the script and cached under
`build/runtime-src/downloads`. The build runs with a system-only `PATH` and no
pkg-config, so Homebrew libraries can't leak in. It targets arm64 and macOS 26.0. The
macOS 27 SDK declares `dup3` and `pipe2`, which macOS 26 lacks, so configure is told
they're unavailable. LTO and PGO are off so `dsymutil` can read the object files.
The output in `build/runtime` holds the framework, a dSYM for the Python library,
for each `lib-dynload` extension and for protobuf's `_message` extension, and
`runtime-manifest.json` with the source hashes and dSYM UUIDs.

## Build and check without downloads

From the repository root, with the runtime above and Xcode:

```sh
/opt/homebrew/bin/python3 tools/package_mac.py
/opt/homebrew/bin/python3 tools/check_mac_package.py
tools/check_offline.sh
```

The packager re-runs itself under the built runtime. It copies the matching dSYMs
into `dist/dSYMs` next to the helper launcher's, and fails if any bundled binary's
UUID has no matching dSYM. The QC transport comes from the qc-mcp copy vendored at
`f634ecd3dcf426090b90bc4cc176e4b500494b9e` in `vendor/qc-mcp`, with its local changes.
Its protocol descriptors aren't committed: generate them from Cortex Control as
[VENDORED.md](../vendor/qc-mcp/VENDORED.md) describes, and the builder checks them
against upstream's SHA-256. It verifies protobuf files against the RECORD of the
wheel it built from source. Missing inputs fail the build without fetching anything. Unrelated MCP-server,
bridge/FIFO, Windows, and audio modules/dependencies are not included. Protobuf's
extension is given a relocatable library ID before signing. Its wheel bytes are
verified before modification. Native audit
accepts only system libraries and the explicitly identified bundled library IDs.

The builder replaces only the fixed generated `dist/Patchbridge.app`.
It compiles a native Swift/AppKit host and C helper launcher, copies the local
CPython library, pure-Python standard library, and the native extension closure needed by simulation and the direct USB adapter.
It includes pinned qc-mcp transport/protocol/macOS HID modules and their binary
schemas, plus protobuf 7.36.2 with its native upb extension. Python, qc-mcp, and
protobuf licenses are included. No pip,
package manager, network, interpreter discovery, or downloads occur.

The current runtime is CPython 3.14.6, arm64, built for **macOS 26.0+**. The packager
reads that deployment floor from the actual runtime rather than claiming older
macOS support. The manifest inside
`Contents/Resources/build-manifest.json` records runtime/version/platform and
SHA-256 hashes of packaged files before the final app signature.

## Runtime isolation and lifecycle

- `Contents/MacOS/patchbridge-helper` embeds the bundled `Frameworks/Python` through
  a relative loader path. The build rejects non-system dynamic dependencies other
  than the exact bundled Python reference and protobuf extension self-identity.
- CPython uses isolated configuration and explicit bundle-only import paths.
  It ignores PYTHONHOME, PYTHONPATH, user site packages, and the working directory.
  Bytecode writes are disabled so launch cannot modify the signed bundle.
- The launcher accepts `--usb` for the live adapter. No arguments selects simulation.
  Offline options remain `--verify-usb-fixtures <fixture-root>` and
  `--captured-read-only <qc-editor.json>`. Arbitrary Python arguments are rejected.
  Constructing the USB adapter does not enumerate or open a device; a connect request does.
- The Swift bundle initializer never falls back to a system interpreter. Its
  environment is limited to system PATH and a UTF-8 locale. Explicit Python/source
  paths remain available only in the development initializer.
- The host owns the process on a worker queue. Stopping or quitting closes helper stdin;
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
when the bundled helper or schema is missing, and rejection of arbitrary launcher arguments. It also checks the bundle ID, compiled
icon and Bluetooth purpose string, and idle USB-helper EOF shutdown without a connect request.
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
"dist/Patchbridge.app/Contents/MacOS/patchbridge-helper" --verify-usb-fixtures "$PWD"
```

Expected failure scenarios emit diagnostic tracebacks on stderr; the final JSON
report on stdout records the checks that passed. Tests run without opening a window or radio.
The native window's simulated approval, denial, connection check, helper failure,
restart, stop, and report export were exercised through the UI on 2026-10-20.

## Distribution work remaining

The artifact is **ad-hoc signed**, not Developer ID signed or notarized. It is for
local use on this Mac, not a Gatekeeper-ready release. For distribution, complete live validation of the bundled USB adapter with the user present, add production
signing/hardened-runtime configuration and notarization, and test on a clean Mac.
These checks validate the packaged dependency/protocol path against recorded evidence.
The live host is wired, but physical iPhone-to-Mac-to-QC operation and cable recovery
still require end-to-end hardware validation. The new bundle's UI automation was blocked
by organization policy for its bundle ID; no policy workaround was used.
Optional stdlib OpenSSL, LZMA, and Zstd extensions are omitted; the QC catalog path
uses gzip/zlib, which is included and tested.

See [read-only mode and recovery](READ_ONLY_QC.md) for the packaged Swift integration
test and the explicit source USB read-only policy. The live app uses the writable USB
adapter; only supported, confirmed operations are exposed by the phone.

The host also offers **Export Troubleshooting Report…** (Command-E). See
[diagnostics](DIAGNOSTICS.md) for excluded data, retention, and offline export checks.

## Mac App Store / TestFlight release

Use `./release_macos` from the repository root. It accepts exactly the same flags as
`./release_ios` (the renamed iPhone release script):

```sh
./release_macos                           # test, archive, verify, upload, local tag
./release_macos --no-upload               # signed local installer; no upload or tag
./release_macos --skip-tests --build 42    # use previously completed tests
./release_macos --allow-dirty --no-upload  # local working changes; never tag
```

Upload is the default; there is no `--upload` option. Team, version and bundle ID come
from `ios/project.yml`, with the existing `DEVELOPMENT_TEAM` environment override.
Build numbering and validation match iOS. Output is retained under
`build/release-macos/<version>-<build>/`; an existing output directory is never replaced.
A successful clean upload creates `macos/v<version>-<build>` locally, without pushing.
Dirty releases require `--allow-dirty` and never create a tag.
Each release also saves its starting commit and dirty state in `release-source.json`.

The archive holds dSYMs for the host app, the helper launcher, the Python library,
every bundled standard-library extension and protobuf's extension. Before export the
release checks that each dSYM contains debug information and that every Mach-O in the
archived app has a dSYM with a matching UUID. A missing or empty one stops the
release. Symbol upload is on, so Apple receives symbols for crashes anywhere in the
app, including the bundled runtime.

The Mac pipeline first builds the isolated runtime using the local dependencies above,
then generates `mac/PatchbridgeMac.xcodeproj` from `mac/project.yml` and archives a native
Release app with dSYMs. Its helper inherits the host sandbox; the host requests USB,
Bluetooth and user-selected file access. Nested runtime binaries are signed with the
archive identity. The exported installer is signature-checked and expanded; bundle ID,
version/build, host/helper entitlements, provisioning-profile presence, and distribution
signatures for all bundled binaries are checked before upload. With explicit upload
credentials, altool uploads that exact package. With the Xcode account fallback, Xcode
exports and uploads the same archive after the local package passes verification.
`--skip-tests` skips regression tests, not package construction or distribution verification.

Use the same `.release.env` API key as iOS, with local Apple Distribution and Mac Installer
Distribution certificates/private keys. The shared `asc_profile.py --platform mac` manages
Mac App Store profiles. Without an API key, signing and upload use the Apple ID signed
into Xcode (Settings → Accounts), matching iOS. To override upload with altool, set both
`MAC_ASC_USERNAME` and `MAC_ASC_PASSWORD_KEYCHAIN`, referencing an app-specific password
already in Keychain. `--no-upload` does not require upload credentials. Add the macOS
platform to the app’s App Store Connect record before uploading.

Validation here uses stubbed signing/upload tools and a real unsigned archive. It does
not create profiles, sign with production credentials, upload, or prove App Store acceptance.
