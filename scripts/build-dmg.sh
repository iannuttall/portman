#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-portman}"
VERSION="${VERSION:-0.2.0}"
DIST_DIR="$ROOT/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
DMG_STAGING="$DIST_DIR/dmg"
DMG_PATH="$DIST_DIR/$(echo "$APP_NAME" | tr ' ' '_')-$VERSION.dmg"

if [ "${SKIP_BUILD:-0}" != "1" ]; then
  "$ROOT/scripts/build-app.sh"
fi

rm -rf "$DMG_STAGING" "$DMG_PATH"
mkdir -p "$DMG_STAGING"

ditto "$APP_DIR" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$DMG_STAGING"

echo "Built $DMG_PATH"
