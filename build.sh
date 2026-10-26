#!/bin/bash
# Builds RefreshRate.app into ~/Applications and (re)launches it.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/RefreshRate.app"
BUILD="$DIR/.build"
BIN="$BUILD/RefreshRate"

mkdir -p "$BUILD"
rm -rf "$APP"

echo "Compiling..."
swiftc -O -o "$BIN" "$DIR/main.swift"

echo "Assembling bundle..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RefreshRate"
cp "$DIR/Info.plist" "$APP/Contents/Info.plist"

echo "Signing (ad-hoc)..."
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "Restarting app..."
pkill -x RefreshRate >/dev/null 2>&1 || true
sleep 0.3
open "$APP"

echo "Done: $APP"
