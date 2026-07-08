# Continuo

Continuo (formerly Agent Sync) is a macOS menu-bar app for continuing a coding-agent session in a different agent: Claude Code, Codex, and OpenCode, in any direction.

Open the menu-bar picker, find a recent session from any tool, and click the target agent's icon on its row. Continuo converts that one transcript into the target's native session format and opens a Terminal window already resumed into it. Nothing syncs in the background; sessions are only converted when you ask.

OpenCode sessions are read from its `opencode.db` and written through the official `opencode import` command; models cross into OpenCode with their provider prefix (`anthropic/claude-…`, `openai/gpt-…`) and cross out by stripping it.

The core safety rule: native session files are read-only inputs. Continuo writes only bridge-owned mirror files recorded in `bridge-state.json`, refuses unowned overwrites, and never rewrites a mirror you have continued natively (a fresh mirror is created instead).

## Build

```sh
swift test
./Scripts/package-app.sh
```

The packaged app is written to `dist/Continuo.app`.

## Install and Setup

1. Build with `./Scripts/package-app.sh` and open `dist/Continuo.app`.
2. Click the menu-bar icon; recent sessions from `~/.claude` and `~/.codex` appear automatically.
3. Optionally use Settings to point at custom homes, choose target models, or install the app into /Applications.

Defaults:

- Claude Code home: `~/.claude`
- Codex home: `~/.codex`
- OpenCode data: `~/.local/share/opencode`
- Bridge state: `~/Library/Application Support/AgentSync`
- Picker window: newest 30 sessions per tool from the last 14 days

Click a session to open the continue panel: choose which of the other two agents to continue in, and how much history to carry — the full transcript when it fits the target model's context, or a handoff brief (structured summary plus the most recent exchanges, ending on your latest request, tool traffic dropped) when a full render would have to truncate. `⌥⌘S` opens the same picker as a floating panel from anywhere. Tool calls are translated into the target agent's vocabulary (Claude's `Bash` becomes Codex's `exec_command` and vice versa) so transplanted history reads naturally.

Model matching is conservative. The source model is preserved in the canonical metadata; the converted session gets a target-provider model from built-in family matches or the defaults in Settings. Hidden provider reasoning is not carried across — only the visible conversation, tool summaries, and safe metadata.

## CLI Harness

```sh
swift run AgentSyncCLI e2e --root /tmp/agent-sync-e2e
swift run AgentSyncCLI sync-once --claude-home PATH --codex-home PATH --state-dir PATH
```

The CLI keeps the bulk `sync-once`/`scan` commands for testing the conversion pipeline against isolated homes. Use `--max-sessions N` and `--lookback-days N` to widen or narrow scans. The app itself never bulk-syncs.

`migrate-state --state-dir PATH` upgrades a v1 monolithic bridge-state.json into the v2 layout (small state file + per-session event files). `prune-state --state-dir PATH` deduplicates event stores and removes runaway mirrors left behind by the old always-on sync loop.

## Model context data

Per-model context limits come from [models.dev](https://models.dev) (MIT licensed): a snapshot is bundled at build time (`Scripts/update-model-catalog.sh` refreshes it) and the app re-fetches weekly at runtime, falling back to the bundled data offline. Transfer budgets derive from the target model's real input limit.

## Releasing

CI runs on every push/PR (`swift test` + an unsigned package). Pushing a
`vX.Y.Z` tag triggers `.github/workflows/release.yml`, which signs the app with
your Developer ID, notarizes it with Apple, staples the ticket, and publishes a
`Continuo.dmg` to a GitHub release. Locally: `./Scripts/package-app.sh` then
`./Scripts/sign-and-notarize.sh` (needs the same env vars as the CI secrets).

Developer ID distribution needs no App ID registration or provisioning profile —
only a certificate and a notarization key. Add these repository secrets
(Settings → Secrets and variables → Actions):

| Secret | What it is | How to get it |
| --- | --- | --- |
| `DEVELOPER_ID_CERT_P12_BASE64` | Your "Developer ID Application" cert + key | Create it in Xcode → Settings → Accounts → Manage Certificates → **+ Developer ID Application**, then export from Keychain Access as a `.p12` with a password. Encode: `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_CERT_PASSWORD` | The `.p12` export password | You chose it during export |
| `AC_API_KEY_ID` | App Store Connect API **Key ID** | App Store Connect → Users and Access → Integrations → App Store Connect API → generate a key (Developer access) |
| `AC_API_ISSUER_ID` | The **Issuer ID** on that same page | — |
| `AC_API_KEY_P8_BASE64` | The `AuthKey_XXXX.p8` (downloadable once) | `base64 -i AuthKey_XXXX.p8 \| pbcopy` |

The signing identity and team are read from the imported certificate — no team
ID needs to be configured separately.

## License

MIT — see [LICENSE](LICENSE). Bundled model metadata is from [models.dev](https://models.dev), also MIT.
