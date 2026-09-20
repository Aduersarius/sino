#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --show-sdk-path)"
APP="$ROOT/dist/Sino.app"
BIN="$APP/Contents/MacOS/Sino"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cc -O2 -o /tmp/sino-smcwrite "$ROOT/Sources/smcwrite.c" \
  -isysroot "$SDK" -target arm64-apple-macos14.0 \
  -framework IOKit -framework CoreFoundation
cp /tmp/sino-smcwrite "$APP/Contents/Resources/sino-smcwrite"
mkdir -p /tmp/sino_build
rm -rf /tmp/sino_build/*
cp -R "$ROOT/Sources" /tmp/sino_build/
swiftc -parse-as-library -O -module-name Sino \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK" \
  -import-objc-header "/tmp/sino_build/Sources/Bridging.h" \
  -framework SwiftUI -framework AppKit -framework IOKit -framework Combine -framework ServiceManagement -framework SystemConfiguration -framework CoreWLAN -framework CoreLocation -framework UserNotifications -framework Carbon \
  -o /tmp/sino_bin \
  "/tmp/sino_build/Sources/SMC.c" "/tmp/sino_build/Sources/Sampler.swift" "/tmp/sino_build/Sources/SinoApp.swift" "/tmp/sino_build/Sources/Settings.swift"
mkdir -p "$APP/Contents/MacOS"
cp /tmp/sino_bin "$BIN"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
echo -n 'APPL????' > "$APP/Contents/PkgInfo"
find "$APP" -exec xattr -c {} + 2>/dev/null || true
codesign -s - --force --deep "$APP" >/dev/null
ROOTAPP="/Applications/Sino.app"
rm -rf "$ROOT/Pulse.app" "$ROOT/dist/Pulse.app" "$ROOT/Sino.app"
mkdir -p "$ROOTAPP/Contents/MacOS" "$ROOTAPP/Contents/Resources"
cp "$BIN" "$ROOTAPP/Contents/MacOS/Sino"
cp /tmp/sino-smcwrite "$ROOTAPP/Contents/Resources/sino-smcwrite"
cp "$ROOT/Info.plist" "$ROOTAPP/Contents/Info.plist"
cp "$ROOT/Assets/AppIcon.icns" "$ROOTAPP/Contents/Resources/AppIcon.icns"
echo -n 'APPL????' > "$ROOTAPP/Contents/PkgInfo"
find "$ROOTAPP" -exec xattr -c {} + 2>/dev/null || true
codesign -s - --force --deep "$ROOTAPP" >/dev/null
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREG" -u "$APP" >/dev/null 2>&1 || true
"$LSREG" -f "$ROOTAPP" >/dev/null 2>&1 || true
rm -rf "$APP"
echo "built and installed to $ROOTAPP"
