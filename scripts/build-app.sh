#!/usr/bin/env bash
# Builds dist/ApolloKit.app from the SwiftPM executable and ad-hoc signs it.
# Usage: scripts/build-app.sh [release|debug]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-release}"
APP="$ROOT/dist/ApolloKit.app"

cd "$ROOT"
swift build -c "$CONFIGURATION" --product ApolloKit
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ApolloKit" "$APP/Contents/MacOS/ApolloKit"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"

# Ad-hoc signature gives the bundle a stable identity for the Full Disk Access grant on this machine.
codesign --force --sign - "$APP"

echo "Built $APP"
