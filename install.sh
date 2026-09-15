#!/bin/bash
set -euo pipefail
# Sino — Apple Silicon, macOS 14+, Command Line Tools
if ! xcode-select -p >/dev/null 2>&1; then
  echo "install CLT first: xcode-select --install"
  exit 1
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL https://github.com/Aduersarius/sino/archive/refs/heads/main.tar.gz | tar -xz -C "$TMP"
cd "$TMP"/sino-main
chmod +x build.sh
./build.sh
DEST="/Applications/Sino.app"
rm -rf "$DEST"
cp -R Sino.app "$DEST"
xattr -cr "$DEST" 2>/dev/null || true
open "$DEST"
echo "installed $DEST"
