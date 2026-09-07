#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
DIST="$ROOT/dist"
APP="$DIST/ChatGPT Terminal Relay.app"

rm -rf "$BUILD" "$DIST"
mkdir -p "$BUILD" "$APP/Contents/MacOS" "$APP/Contents/Resources"

clang -fobjc-arc -fblocks "$ROOT/src/Relay.m" \
  -o "$BUILD/ChatGPTTerminalRelay" \
  -framework Cocoa \
  -framework ApplicationServices

cp "$BUILD/ChatGPTTerminalRelay" \
  "$APP/Contents/MacOS/ChatGPTTerminalRelay"

cp "$ROOT/assets/Relay.icns" \
  "$APP/Contents/Resources/Relay.icns"

PLIST="$APP/Contents/Info.plist"
plutil -create xml1 "$PLIST"

/usr/libexec/PlistBuddy -c "Add :CFBundleName string ChatGPT Terminal Relay" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ChatGPT Terminal Relay" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.coyoter.chatgpt-terminal-relay" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ChatGPTTerminalRelay" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string 0.3.0" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.3.0" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string Relay.icns" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 13.0" "$PLIST"

codesign --force --deep --sign - "$APP"

ditto -c -k --sequesterRsrc --keepParent \
  "$APP" \
  "$DIST/ChatGPT-Terminal-Relay-v0.3.0-macOS.zip"

echo "BUILD_OK"
echo "$DIST/ChatGPT-Terminal-Relay-v0.3.0-macOS.zip"
