# Swift helper client and BLE simulation

The Swift package builds a macOS command-line peripheral and a shared central
transport usable by a foreground iOS app. Both use simulated QC state only.
The installable iPhone test app is in `ios/Patchbridge.xcodeproj`. See
`ios/README.md` for installation and the hardware test record.

## Build and test

From the repository root, with Swift/Xcode and Python 3 installed:

```sh
swift test --package-path swift
swift run --package-path swift bridge-demo /opt/homebrew/bin/python3 "$PWD/src" --self-test
swift run --package-path swift bridge-demo /opt/homebrew/bin/python3 "$PWD/src" --ble
```

Replace the Python path for your machine. Tests currently use the Homebrew
Python path on the development Mac. For restricted build environments, set
`CLANG_MODULE_CACHE_PATH` and `SWIFT_MODULECACHE_PATH` to writable paths and
use `--scratch-path` with SwiftPM. Nested sandbox environments may require
SwiftPM's `--disable-sandbox` option.

The self-test launches Python, connects, chunks and reassembles an edit,
checks authorization, and receives a confirmed result. It does not use the radio.
The BLE mode advertises a custom service and waits for a central to subscribe.
Approve the exact connection token printed in the Mac terminal with
`approve TOKEN`. Type `quit` to stop. Discovery/subscription alone never authorizes
commands. No old edits are replayed after a disconnect or helper failure.

The executable embeds a Bluetooth usage description. macOS Bluetooth permission,
encrypted characteristic behavior and over-the-air throughput still need device
validation. The permission dialog may be attributed to the launching terminal.
A future iPhone host must also declare `NSBluetoothAlwaysUsageDescription`.

## BLE v1 development wire format

UUID prefix: `79A9`, suffix: `-6E15-4C9F-AC53-147F7E639B01`.

| Attribute | UUID first group | Behavior |
| --- | --- | --- |
| Service | 79A90001 | Advertised by Mac |
| Command | 79A90002 | Encrypted write with response |
| Result | 79A90003 | Encrypted notifications |

Each chunk has an 8-byte header: protocol byte `1`, unsigned transfer ID (4 bytes,
big endian), sequence (2 bytes, big endian, starting at zero), final flag (0 or 1).
Payload is part of a UTF-8 JSON object. Use the platform's negotiated maximum
write/notification length, capped at 512 bytes here. One transfer per direction;
maximum message 1 MiB, assembly lifetime 5 seconds. Missing, reordered, expired,
or oversized transfers fail. New connections discard all partial transfers.
A phone that sends `"compression": ["deflate"]` in its `hello` may get replies with
protocol byte `2`: the reassembled payload is raw DEFLATE of the JSON, and the 1 MiB
limit applies after inflating. Replies under 512 bytes, or that don't shrink, stay `1`.

Phone flow:

1. Discover, connect, subscribe to results.
2. Send `{"version":1,"id":"hello","operation":"hello"}`.
3. Retain the returned `connection_id`; obtain explicit approval on the Mac.
4. Send `connect` with that connection ID. Retain the helper session and snapshot.
5. Send process-protocol operations with connection ID and the required helper
   context. Responses preserve the phone's request ID.

`BLECentral` performs discovery, subscription, chunked writes, reassembly and
command timeouts. Its owner supplies JSON requests and consumes callbacks on the
main queue. It permits only one outstanding command; slider coalescing and
optimistic editor state belong in the future editor layer. Call `reconnect()`
after disconnect, repeat hello/approval/connect, and reload state.

The Mac bounds output to one message and respects Core Bluetooth's
`updateValue == false` signal; it resumes on the ready callback. More commands
are rejected while output remains queued. The process client serializes helper
requests, bounds stdout buffering, correlates responses, and terminates the
helper on timeout or invalid protocol. Helper stderr goes to the terminal.

## Current limits

The SwiftUI test app has verified initial BLE connection and state transfer on
a physical iPhone. The iOS app preserves connections across app switches using
Bluetooth background mode; this still needs physical-device validation. No
comprehensive BLE hardware validation, multi-phone support,
slider coalescing, transfer priority scheduler, or asynchronous device-event
forwarding yet. Use explicit snapshot requests for state refresh. A helper crash
requires restarting the demo. The simulator supports more operations than the
real USB adapter; this demo intentionally cannot launch USB mode.
