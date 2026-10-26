#!/bin/bash
set -euo pipefail
# Host-only tests. No FlightDeck installation, lease, signing, or simulator needed.
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
export PYTHONDONTWRITEBYTECODE=1
out="${FLIGHTDECK_ARTIFACTS_DIR:-}"
if [ -z "$out" ]; then out="$(mktemp -d "${TMPDIR:-/tmp}/flightdeck-fast.XXXXXX")"; fi
mkdir -p "$out"
export CLANG_MODULE_CACHE_PATH="$out/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$out/swift-cache"
printf 'Test artifacts: %s\n' "$out"
swift test --package-path swift --scratch-path "$out/SwiftBuild"
PYTHONPATH="$root/src${PYTHONPATH:+:$PYTHONPATH}" python3 -m unittest discover -s tests
printf 'Host tests complete\n'
