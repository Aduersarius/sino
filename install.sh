#!/bin/bash
set -euo pipefail
# Sino — Apple Silicon, macOS 14+
DEST="/Applications/Sino.app"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ZIP="$TMP/Sino.app.zip"
if curl -fsSL -o "$ZIP" "https://github.com/Aduersarius/sino/releases/latest/download/Sino.app.zip"; then
  ditto -x -k "$ZIP" "$TMP"
  APP=$(find "$TMP" -maxdepth 2 -name 'Sino.app' | head -1)
else
  if ! xcode-select -p >/dev/null 2>&1; then
    echo "install CLT first: xcode-select --install"
    exit 1
  fi
  curl -fsSL https://github.com/Aduersarius/sino/archive/refs/heads/main.tar.gz | tar -xz -C "$TMP"
  cd "$TMP"/sino-main
  chmod +x build.sh
  ./build.sh
  APP="$TMP/sino-main/Sino.app"
fi
rm -rf "$DEST"
cp -R "$APP" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true
open "$DEST"
echo "installed $DEST"
