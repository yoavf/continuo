#!/usr/bin/env bash
# Signs dist/Continuo.app with Developer ID, notarizes it with Apple, staples
# the ticket, and produces a stapled dist/Continuo.dmg.
#
# Run Scripts/package-app.sh first. Required environment:
#   SIGNING_IDENTITY     "Developer ID Application: Name (TEAMID)"
#                        (optional — auto-detected from the keychain if unset)
#   AC_API_KEY_ID        App Store Connect API key id
#   AC_API_ISSUER_ID     App Store Connect API issuer id
#   AC_API_KEY_PATH      path to the AuthKey_XXXXXX.p8 file
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Continuo.app"
DMG="$ROOT/dist/Continuo.dmg"
ZIP="$ROOT/dist/Continuo.zip"

[ -d "$APP" ] || { echo "error: $APP not found — run Scripts/package-app.sh first" >&2; exit 1; }

if [ -z "${SIGNING_IDENTITY:-}" ]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')"
    [ -n "$SIGNING_IDENTITY" ] || { echo "error: no Developer ID Application identity in keychain" >&2; exit 1; }
fi
echo "Signing as: $SIGNING_IDENTITY"

notarize() {
    xcrun notarytool submit "$1" \
        --key "$AC_API_KEY_PATH" \
        --key-id "$AC_API_KEY_ID" \
        --issuer "$AC_API_ISSUER_ID" \
        --wait
}

# Sparkle contains nested updater executables. Because this repo packages the
# app without Xcode's Archive/Export flow, sign them from the inside out using
# Sparkle's documented order before sealing the framework and host app.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SPARKLE/Versions/B/Autoupdate"
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SPARKLE/Versions/B/Updater.app"
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$SPARKLE"
fi

# Sign the host with a hardened runtime (required for notarization). The
# SwiftPM resource bundles carry only data and are sealed as resources.
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# Notarize + staple the app so it validates wherever it's copied out to.
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
notarize "$ZIP"
rm -f "$ZIP"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# Package the stapled app into a drag-to-Applications DMG, then notarize and
# staple the DMG itself (a ticket is keyed to the DMG's own hash, so the
# download passes Gatekeeper offline).
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Continuo" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
notarize "$DMG"
xcrun stapler staple "$DMG"

echo "Done: $DMG"
