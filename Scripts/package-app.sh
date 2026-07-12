#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
APP_DIR="$ROOT/dist/Continuo.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

swift build -c "$CONFIGURATION" --product AgentSyncApp --package-path "$ROOT"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$CONTENTS_DIR/Resources" "$FRAMEWORKS_DIR"
cp "$ROOT/.build/$CONFIGURATION/AgentSyncApp" "$MACOS_DIR/AgentSyncApp"
# `swift build` links binary frameworks but does not add the app-bundle search
# path that Xcode normally supplies. Add it before signing so the standalone
# executable can find Contents/Frameworks after leaving `.build`.
install_name_tool -add_rpath '@executable_path/../Frameworks' "$MACOS_DIR/AgentSyncApp"
cp "$ROOT/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT/Packaging/Continuo.icns" "$CONTENTS_DIR/Resources/Continuo.icns"
/usr/bin/ditto "$ROOT/.build/$CONFIGURATION/Sparkle.framework" "$FRAMEWORKS_DIR/Sparkle.framework"
# Continuo is not sandboxed, so Sparkle's optional sandbox-only XPC services
# are unnecessary. Removing them keeps the app smaller and the signing surface
# limited to the updater components Continuo actually uses.
rm -rf \
    "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/XPCServices" \
    "$FRAMEWORKS_DIR/Sparkle.framework/XPCServices"
# SwiftPM resource bundles (bundled models.dev snapshot, MIT licensed)
cp -R "$ROOT/.build/$CONFIGURATION/agent-sync_AgentSyncCore.bundle" "$CONTENTS_DIR/Resources/" 2>/dev/null || true
cp -R "$ROOT/.build/$CONFIGURATION/agent-sync_AgentSyncApp.bundle" "$CONTENTS_DIR/Resources/" 2>/dev/null || true

# Swift signs the standalone executable while linking, before the finished app
# bundle and its resources exist. Re-sign the assembled bundle so even local
# and unsigned packages have a coherent resource seal. Release/preview signing
# replaces this ad-hoc signature with Developer ID afterwards.
codesign --force --deep --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

echo "$APP_DIR"
