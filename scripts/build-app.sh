#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Everything identity-related is a variable: the app is likely to be renamed, and
# will be signed by a different account than the one it was developed on.
APP_NAME="${APP_NAME:-portman}"
BUNDLE_ID="${BUNDLE_ID:-is.ian.portman}"
VERSION="${VERSION:-0.2.0}"
BUILD_NUMBER="${BUILD_NUMBER:-2}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"

# The feed is served straight from the repo. It's baked into every build's
# Info.plist and can't move afterwards without orphaning everyone on an older
# version, so it defaults here rather than being passed in per release.
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://raw.githubusercontent.com/iannuttall/portman/main/appcast.xml}"

# The updater still stays dormant until a public key is supplied — the app
# disables it entirely when it sees the REPLACE_ prefix.
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-REPLACE_WITH_PUBLIC_ED_KEY}"

BUILD_DIR="$ROOT/.build/release"
APP_DIR="$ROOT/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

cd "$ROOT"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

cp "$BUILD_DIR/portman" "$MACOS_DIR/$APP_NAME"

# Sparkle ships as a framework, so it has to be embedded and the binary told to
# look for it inside the bundle. SwiftPM links it but doesn't build app bundles.
SPARKLE_FRAMEWORK="$(find "$ROOT/.build/artifacts" -name "Sparkle.framework" -type d -path "*macos*" | head -1)"

# Hardened runtime enforces library validation, which requires every loaded
# framework to share the app's Team ID. Ad-hoc signatures have no Team ID, so
# enabling it on a local build makes the app refuse to load Sparkle at all. It's
# only needed for notarization, which requires a real identity anyway.
SIGN_FLAGS=(--force)
if [ "$SIGN_IDENTITY" != "-" ]; then
  SIGN_FLAGS+=(--options runtime --timestamp)
fi

sign () {
  codesign "${SIGN_FLAGS[@]}" --sign "$SIGN_IDENTITY" "$1"
}

if [ -n "$SPARKLE_FRAMEWORK" ]; then
  cp -R "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/"
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$APP_NAME"

  # Signed innermost first: the XPC services and helpers are code in their own
  # right, and signing the framework before them invalidates its seal.
  SPARKLE_VERSION_DIR="$FRAMEWORKS_DIR/Sparkle.framework/Versions/B"
  for xpc in "$SPARKLE_VERSION_DIR/XPCServices/"*.xpc; do
    [ -e "$xpc" ] && sign "$xpc"
  done
  [ -e "$SPARKLE_VERSION_DIR/Updater.app" ] && sign "$SPARKLE_VERSION_DIR/Updater.app"
  [ -e "$SPARKLE_VERSION_DIR/Autoupdate" ] && sign "$SPARKLE_VERSION_DIR/Autoupdate"
  sign "$FRAMEWORKS_DIR/Sparkle.framework"
else
  echo "warning: Sparkle.framework not found — the build will have no updater" >&2
fi

# Compiles Resources/AppIcon.icon (an Icon Composer document) with actool.
#
# actool emits both halves from that one source: Assets.car carries the layered
# icon that macOS 26 lights and masks itself, and a generated AppIcon.icns covers
# macOS 15 and earlier, which do neither. That's why there is no hand-drawn icon
# in this repo any more — one source, both eras.
ICON_ENTRY=""

if [ -d "$ROOT/Resources/AppIcon.icon" ]; then
  ACTOOL_OUT="$ROOT/.build/icon"
  mkdir -p "$ACTOOL_OUT"

  if xcrun actool "$ROOT/Resources/AppIcon.icon" \
      --compile "$ACTOOL_OUT" \
      --platform macosx \
      --minimum-deployment-target 15.0 \
      --app-icon AppIcon \
      --output-partial-info-plist "$ACTOOL_OUT/partial.plist" \
      --errors --warnings > "$ACTOOL_OUT/actool.log" 2>&1; then

    [ -f "$ACTOOL_OUT/Assets.car" ] && cp "$ACTOOL_OUT/Assets.car" "$RESOURCES_DIR/Assets.car"
    [ -f "$ACTOOL_OUT/AppIcon.icns" ] && cp "$ACTOOL_OUT/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

    # CFBundleIconName points at the asset catalog entry (macOS 26 uses this),
    # CFBundleIconFile at the .icns (everything older).
    ICON_ENTRY="  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>"
  else
    echo "warning: actool failed — see $ACTOOL_OUT/actool.log; building without an icon" >&2
  fi
fi

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
$ICON_ENTRY
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>$APP_NAME uses automation to focus the terminal tab a dev server is running in, and to restart dev servers in your terminal.</string>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>86400</integer>
</dict>
</plist>
PLIST

# actool's .icns stops at 256, so anything larger on macOS 15 and earlier gets
# upscaled from that and looks soft. The system can render the vector layers in
# Assets.car at any size, so the big renditions are taken from the built bundle and
# merged back in. Needs the bundle to exist, hence its position here.
if [ -f "$RESOURCES_DIR/AppIcon.icns" ] && [ -f "$RESOURCES_DIR/Assets.car" ]; then
  RENDER_TOOL="$ROOT/.build/icon/render-icon"

  if [ ! -x "$RENDER_TOOL" ] || [ "$ROOT/scripts/icon/render-icon.swift" -nt "$RENDER_TOOL" ]; then
    mkdir -p "$ROOT/.build/icon"
    swiftc -swift-version 6 -O "$ROOT/scripts/icon/render-icon.swift" -o "$RENDER_TOOL" 2>/dev/null || true
  fi

  if [ -x "$RENDER_TOOL" ]; then
    # A fresh temp dir each time: iconutil wants the target not to exist, and this
    # avoids deleting anything.
    ICON_WORK="$(mktemp -d)"
    ICONSET="$ICON_WORK/AppIcon.iconset"

    if iconutil -c iconset "$RESOURCES_DIR/AppIcon.icns" -o "$ICONSET" 2>/dev/null; then
      "$RENDER_TOOL" "$APP_DIR" 256 "$ICONSET/icon_256x256.png" >/dev/null 2>&1 || true
      "$RENDER_TOOL" "$APP_DIR" 512 "$ICONSET/icon_512x512.png" >/dev/null 2>&1 || true
      "$RENDER_TOOL" "$APP_DIR" 1024 "$ICONSET/icon_512x512@2x.png" >/dev/null 2>&1 || true

      if iconutil -c icns "$ICONSET" -o "$RESOURCES_DIR/AppIcon.icns" 2>/dev/null; then
        echo "  icon: added 256, 512 and 1024 renditions for older macOS"
      fi
    fi
  fi
fi

# The app signs last, once everything nested inside it is already signed.
sign "$APP_DIR"

echo "Built $APP_DIR"
echo "  version $VERSION ($BUILD_NUMBER), bundle $BUNDLE_ID, signed by ${SIGN_IDENTITY}"

if [ "$SPARKLE_FEED_URL" = "REPLACE_WITH_APPCAST_URL" ]; then
  echo "  updates: disabled (set SPARKLE_FEED_URL and SPARKLE_PUBLIC_KEY to enable)"
else
  echo "  updates: $SPARKLE_FEED_URL"
fi
