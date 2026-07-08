#!/usr/bin/env bash
# Refreshes the bundled models.dev snapshot (MIT licensed, https://models.dev).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift run --package-path "$ROOT" AgentSyncCLI update-model-catalog \
  --output "$ROOT/Sources/AgentSyncCore/Resources/model-contexts.json"
