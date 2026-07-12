#!/usr/bin/env bash
# Generates the signed Sparkle feed published beside each GitHub Release.
# CI reads SPARKLE_ED_PRIVATE_KEY from a repository secret. Local release
# testing falls back to the "continuo" key generated in the login Keychain.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:?usage: generate-appcast.sh vX.Y.Z [dmg-path] [output-path]}"
DMG="${2:-$ROOT/dist/Continuo.dmg}"
OUTPUT="${3:-$ROOT/dist/appcast.xml}"

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "error: release tag must look like vX.Y.Z: $TAG" >&2
    exit 1
}
[ -f "$DMG" ] || { echo "error: update archive not found: $DMG" >&2; exit 1; }

SPARKLE_BIN="$(find "$ROOT/.build/artifacts" -path '*/Sparkle/bin' -type d -print -quit)"
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
[ -x "$GENERATE_APPCAST" ] || {
    echo "error: Sparkle tools not found; run swift package resolve first" >&2
    exit 1
}

UPDATES="$(mktemp -d)"
trap 'rm -rf "$UPDATES"' EXIT
cp "$DMG" "$UPDATES/Continuo.dmg"

ARGS=(
    --download-url-prefix "https://github.com/yoavf/continuo/releases/download/$TAG/"
    --link "https://github.com/yoavf/continuo/releases/tag/$TAG"
    -o appcast.xml
)

if [ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]; then
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" |
        "$GENERATE_APPCAST" --ed-key-file - "${ARGS[@]}" "$UPDATES"
else
    "$GENERATE_APPCAST" --account continuo "${ARGS[@]}" "$UPDATES"
fi

mkdir -p "$(dirname "$OUTPUT")"
cp "$UPDATES/appcast.xml" "$OUTPUT"
xmllint --noout "$OUTPUT"
grep -q 'sparkle:edSignature=' "$OUTPUT"
grep -q "releases/download/$TAG/Continuo.dmg" "$OUTPUT"
echo "$OUTPUT"
