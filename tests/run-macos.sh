#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
clang -DRELAY_TESTING -fobjc-arc -fblocks -mmacosx-version-min=13.0 "$ROOT/tests/RelayTests.m" "$ROOT/src/RelayDelivery.m" "$ROOT/src/RelayDiagnostics.m" "$ROOT/src/RelayAuthorization.m" "$ROOT/src/RelayAutoPilot.m" \
  -framework Cocoa -framework ApplicationServices -o "$TEST_DIR/RelayTests"
RELAY_TEST_DATA_DIR="$TEST_DIR" "$TEST_DIR/RelayTests"
# Returning results must never use the shared clipboard or synthetic keyboard events.
if grep -E 'CGEventPost|CGEventCreateKeyboardEvent|NSPasteboard' "$ROOT/src/RelayDelivery.m"; then
  echo 'Unexpected global input dependency in delivery adapter' >&2
  exit 1
fi
clang -DRELAY_TESTING -fobjc-arc -fblocks -mmacosx-version-min=13.0 "$ROOT/tests/AXDiscoveryTests.m" "$ROOT/src/RelayDiagnostics.m" "$ROOT/src/RelayAuthorization.m" "$ROOT/src/RelayAutoPilot.m" \
  -framework Cocoa -framework ApplicationServices -o "$TEST_DIR/AXDiscoveryTests"
RELAY_TEST_DATA_DIR="$TEST_DIR" "$TEST_DIR/AXDiscoveryTests"
clang -DRELAY_TESTING -fobjc-arc -fblocks -mmacosx-version-min=13.0 "$ROOT/tests/AutoPilotTests.m" \
  "$ROOT/src/RelayAutoPilot.m" "$ROOT/src/RelayDelivery.m" "$ROOT/src/RelayDiagnostics.m" "$ROOT/src/RelayAuthorization.m" \
  -framework Cocoa -framework ApplicationServices -o "$TEST_DIR/AutoPilotTests"
RELAY_TEST_DATA_DIR="$TEST_DIR" "$TEST_DIR/AutoPilotTests"
