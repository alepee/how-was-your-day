#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p build/tests
xcrun clang -std=c11 -g -fsanitize=address,undefined -I Sources/HWYDRealtime/include Sources/HWYDRealtime/HWYDRealtime.c Tests/HWYDRealtimeTests/RingTests.c -o build/tests/ring-tests
build/tests/ring-tests
