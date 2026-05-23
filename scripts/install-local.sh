#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Port Manager"
SOURCE_APP="$ROOT/dist/$APP_NAME.app"
INSTALL_DIR="${INSTALL_DIR:-$HOME/Applications}"
INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"

"$ROOT/scripts/build-app.sh"

mkdir -p "$INSTALL_DIR"

pkill -f "$ROOT/dist/$APP_NAME.app/Contents/MacOS/$APP_NAME" || true
pkill -f "$INSTALLED_APP/Contents/MacOS/$APP_NAME" || true

rm -rf "$INSTALLED_APP"
ditto "$SOURCE_APP" "$INSTALLED_APP"

xattr -dr com.apple.quarantine "$INSTALLED_APP" 2>/dev/null || true
codesign --verify --deep --strict "$INSTALLED_APP"

open -n "$INSTALLED_APP"

echo "Installed $INSTALLED_APP"
