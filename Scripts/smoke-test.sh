#!/usr/bin/env bash
# Launches the packaged app and asserts it stays running (i.e. didn't crash on
# launch). Guards against the class of bug where a packaged .app can't find its
# resources: it hides .build first so the Bundle.module build-path fallback
# can't mask a broken Contents/Resources layout — exactly what a downloaded app
# sees. Run Scripts/package-app.sh first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/dist/Continuo.app}"
EXE="AgentSyncApp"
CRASHDIR="$HOME/Library/Logs/DiagnosticReports"

[ -d "$APP" ] || { echo "error: $APP not found — run Scripts/package-app.sh first" >&2; exit 1; }

HIDDEN=""
restore() { [ -n "$HIDDEN" ] && [ -d "$HIDDEN" ] && mv "$HIDDEN" "$ROOT/.build" || true; }
trap restore EXIT
if [ -d "$ROOT/.build" ]; then
    HIDDEN="$ROOT/.build.smoke-hidden"
    rm -rf "$HIDDEN"
    mv "$ROOT/.build" "$HIDDEN"
fi

before="$(find "$CRASHDIR" -maxdepth 1 -name "*${EXE}*" 2>/dev/null | wc -l | tr -d " ")"
killall "$EXE" 2>/dev/null || true

open "$APP"
sleep 6

ok=1
if ! pgrep -x "$EXE" >/dev/null; then
    echo "FAIL: $EXE is not running — it crashed or exited on launch"
    ok=0
fi
after="$(find "$CRASHDIR" -maxdepth 1 -name "*${EXE}*" 2>/dev/null | wc -l | tr -d " ")"
if [ "$after" -gt "$before" ]; then
    echo "FAIL: a new crash report appeared for $EXE:"
    find "$CRASHDIR" -maxdepth 1 -name "*${EXE}*" | tail -1
    ok=0
fi

killall "$EXE" 2>/dev/null || true

if [ "$ok" -eq 1 ]; then
    echo "smoke test passed: the packaged app launched and stayed running with no .build present"
else
    exit 1
fi
