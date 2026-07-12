#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
APP_DIR="$ROOT/dist/Continuo.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

swift build -c "$CONFIGURATION" --product AgentSyncApp --package-path "$ROOT"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$CONTENTS_DIR/Resources"
cp "$ROOT/.build/$CONFIGURATION/AgentSyncApp" "$MACOS_DIR/AgentSyncApp"
cp "$ROOT/Packaging/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT/Packaging/Continuo.icns" "$CONTENTS_DIR/Resources/Continuo.icns"
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
