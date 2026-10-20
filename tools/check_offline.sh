#!/bin/sh
# No device access, installation, BLE advertising, or USB connection.
set -eu
cd "$(dirname "$0")/.."
TASK_ROOT=$(pwd)
PYTHON_BIN=${PYTHON_BIN:-/opt/homebrew/bin/python3}
export CLANG_MODULE_CACHE_PATH=${CLANG_MODULE_CACHE_PATH:-/private/tmp/patchbridge-clang-cache}
export SWIFT_MODULECACHE_PATH=${SWIFT_MODULECACHE_PATH:-/private/tmp/patchbridge-swift-cache}
PYTHONPATH=src "$PYTHON_BIN" -m unittest discover -s tests -v
swift test --disable-sandbox --package-path swift --scratch-path /private/tmp/patchbridge-swift-offline
swift run --disable-sandbox --package-path swift --scratch-path /private/tmp/patchbridge-swift-offline bridge-demo "$PYTHON_BIN" "$TASK_ROOT/src" --self-test
