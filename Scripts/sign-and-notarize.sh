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

# Sign with a hardened runtime (required for notarization). The nested
# SwiftPM resource bundles carry only data (no Mach-O), so they aren't signed
# separately — the app signature seals them as resources.
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# Notarize a zip of the app (notarytool accepts zip or dmg; the app is what we
# staple so it validates wherever it's copied).
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" \
    --key "$AC_API_KEY_PATH" \
    --key-id "$AC_API_KEY_ID" \
    --issuer "$AC_API_ISSUER_ID" \
    --wait
rm -f "$ZIP"

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# Package the stapled app into a drag-to-Applications DMG, then staple the DMG
# too so a downloaded .dmg passes Gatekeeper offline.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Continuo" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
xcrun stapler staple "$DMG"

echo "Done: $DMG"
