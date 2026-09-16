#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$(xcrun --show-sdk-path)"
APP="$ROOT/dist/Sino.app"
BIN="$APP/Contents/MacOS/Sino"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -parse-as-library -O -module-name Sino \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK" \
  -import-objc-header "$ROOT/Sources/Bridging.h" \
  -framework SwiftUI -framework AppKit -framework IOKit -framework Combine -framework ServiceManagement -framework SystemConfiguration -framework CoreWLAN -framework CoreLocation -framework UserNotifications -framework Carbon \
  -o "$BIN" \
  "$ROOT/Sources/SMC.c" "$ROOT/Sources/Sampler.swift" "$ROOT/Sources/SinoApp.swift" "$ROOT/Sources/Settings.swift"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
echo -n 'APPL????' > "$APP/Contents/PkgInfo"
find "$APP" -exec xattr -c {} + 2>/dev/null || true
codesign -s - --force --deep "$APP" >/dev/null
ROOTAPP="/Applications/Sino.app"
rm -rf "$ROOT/Pulse.app" "$ROOT/dist/Pulse.app" "$ROOT/Sino.app"
mkdir -p "$ROOTAPP/Contents/MacOS" "$ROOTAPP/Contents/Resources"
cp "$BIN" "$ROOTAPP/Contents/MacOS/Sino"
cp "$ROOT/Info.plist" "$ROOTAPP/Contents/Info.plist"
cp "$ROOT/Assets/AppIcon.icns" "$ROOTAPP/Contents/Resources/AppIcon.icns"
echo -n 'APPL????' > "$ROOTAPP/Contents/PkgInfo"
find "$ROOTAPP" -exec xattr -c {} + 2>/dev/null || true
codesign -s - --force --deep "$ROOTAPP" >/dev/null
echo "built $APP and installed to $ROOTAPP"
