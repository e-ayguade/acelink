#!/bin/bash
# Packages build/Ace Link.app into build/Ace.Link.<version>.dmg (drag to Applications).
# Run scripts/build-app.sh first.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build"
APP="$OUT/Ace Link.app"
VERSION="$(cat "$ROOT/VERSION")"
DMG="$OUT/Ace.Link.$VERSION.dmg"

[ -d "$APP" ] || { echo "Missing $APP, run scripts/build-app.sh first" >&2; exit 1; }

STAGE="$OUT/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -volname "Ace Link $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
echo "Built $DMG"
