# Patchbridge iPhone test app

Native SwiftUI app for testing the Mac BLE simulation. The app never connects to
USB or selects the real QC adapter. Supports discovery, explicit Mac approval,
confirmed gain editing, precise numeric entry, scenes A/B, snapshot refresh and
explicit simulated saving. It disconnects on backgrounding.

Open `Patchbridge.xcodeproj`, choose your signing team and iPhone, then Run.
The checked-in project was generated with `xcodegen generate --spec ios/project.yml`.
The development team in that spec is the project owner's existing Xcode team;
other developers should replace it. Device requires iOS 17 or later.

Start the Mac bridge using the instructions in `../docs/SWIFT_BLE_DEMO.md`.
Tap Find my Mac, accept the system pairing prompts if present, then approve the
printed connection token in the Mac terminal. Finally tap I've approved on Mac.
The terminal's `status` command prints the current connection/token. Every new
connection needs new approval. All simulation data is clearly labeled.

Installation and launch were verified over the existing Xcode Wi-Fi pairing.
On the physical iPhone, BLE discovery, system pairing, explicit bridge approval,
and initial simulated snapshot transfer were verified: Simulation 1, scene A,
gain 5.00, Confirmed by Mac. A device screenshot was visually inspected.
The user subsequently confirmed a gain edit and simulated save working over BLE.
Recovery/backgrounding tests remain. Later offline changes are built and tested
but have not yet been installed on the phone.

Pairing and app authorization are separate. If pairing interrupts the initial
connection, reconnect and use the new token from the Mac terminal. Do not reuse
an older connection token.
