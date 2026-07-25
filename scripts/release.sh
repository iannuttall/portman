#!/usr/bin/env bash
set -euo pipefail

# Builds, signs, notarizes and staples a release DMG, then updates the appcast.
#
# Everything identity-related comes from the environment, because the app is signed
# by a different account than the one it's developed on:
#
#   SIGN_IDENTITY      "Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE     name of a stored notarytool profile (see below)
#   SPARKLE_FEED_URL   where the appcast will be hosted
#   SPARKLE_PUBLIC_KEY the EdDSA public key printed by Sparkle's generate_keys
#   VERSION            e.g. 0.3.0
#   BUILD_NUMBER       monotonic integer
#
# Store notary credentials once:
#   xcrun notarytool store-credentials "portmanager" \
#     --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="${APP_NAME:-Port Manager}"
VERSION="${VERSION:?set VERSION, e.g. VERSION=0.3.0}"
BUILD_NUMBER="${BUILD_NUMBER:?set BUILD_NUMBER, e.g. BUILD_NUMBER=3}"
SIGN_IDENTITY="${SIGN_IDENTITY:?set SIGN_IDENTITY to a Developer ID Application identity}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

DIST="$ROOT/dist"
APP_DIR="$DIST/$APP_NAME.app"
DMG_NAME="$(echo "$APP_NAME" | tr ' ' '_')-$VERSION.dmg"
DMG_PATH="$DIST/$DMG_NAME"

echo "==> Building $APP_NAME $VERSION ($BUILD_NUMBER)"
APP_NAME="$APP_NAME" VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" \
  SIGN_IDENTITY="$SIGN_IDENTITY" ./scripts/build-app.sh

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=1 "$APP_DIR"
# Catches the hardened-runtime and library-validation problems that only show up
# at launch, before we spend minutes waiting on the notary.
spctl --assess --type execute --verbose=2 "$APP_DIR" || {
  echo "error: Gatekeeper assessment failed — notarization would be rejected" >&2
  exit 1
}

echo "==> Building DMG"
# SKIP_BUILD: the app is already built and signed above; rebuilding
# would discard that signature.
SKIP_BUILD=1 VERSION="$VERSION" APP_NAME="$APP_NAME" ./scripts/build-dmg.sh
codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG_PATH"

if [ -z "$NOTARY_PROFILE" ]; then
  echo "==> Skipping notarization (NOTARY_PROFILE not set)"
  echo "    Unnotarized builds are blocked by Gatekeeper on other people's Macs."
else
  echo "==> Notarizing (this takes a few minutes)"
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

  echo "==> Stapling"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

echo "==> Signing the update for Sparkle"
SIGN_UPDATE="$(find "$ROOT/.build/artifacts" -name "sign_update" -type f | head -1)"

if [ -n "$SIGN_UPDATE" ]; then
  # Reads the private key from the keychain — it is never written to the repo.
  "$SIGN_UPDATE" "$DMG_PATH" || {
    echo "warning: sign_update failed. Generate keys once with Sparkle's generate_keys." >&2
  }
else
  echo "warning: sign_update not found in Sparkle's artifacts" >&2
fi

SIZE="$(stat -f%z "$DMG_PATH")"

cat <<SUMMARY

==> Done: $DMG_PATH  (${SIZE} bytes)

Add an <item> to appcast.xml using the sparkle:edSignature printed above:

  <item>
    <title>$VERSION</title>
    <sparkle:version>$BUILD_NUMBER</sparkle:version>
    <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
    <enclosure
      url="https://github.com/OWNER/REPO/releases/download/v$VERSION/$DMG_NAME"
      length="$SIZE"
      type="application/octet-stream"
      sparkle:edSignature="PASTE_SIGNATURE" />
  </item>

SUMMARY
