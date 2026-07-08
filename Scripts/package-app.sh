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

echo "$APP_DIR"
