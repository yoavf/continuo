# Continuo

Continue a coding-agent session in a *different* agent. Continuo is a macOS menu-bar app that converts a recent Claude Code, Codex, or OpenCode session into another agent's native format and opens a terminal already resumed into it — in any direction, on demand.

Switched tools mid-task? Hitting a model's limits? Want a fresh agent with the same context? Open the picker, pick a session, click the agent you want to continue in.

## Install

Download the latest `Continuo.dmg` from [Releases](https://github.com/yoavf/continuo/releases), drag it to Applications, and launch it — it's signed and notarized.

Recent sessions from `~/.claude` and `~/.codex` show up automatically. Click the menu-bar icon, or press `⌥⌘S` from anywhere, to see them.

## Using it

- **Pick a session** from the menu-bar picker — the newest across all three tools, searchable.
- **Choose where to continue it.** Click a session to open the continue panel and pick one of the other two agents.
- **Choose how much to carry over** — the full transcript when it fits the target model's context, or a handoff brief (a structured summary plus your most recent exchanges) when it wouldn't.
- **It opens resumed.** Continuo writes the target's native session file and launches your terminal straight into it.

Settings lets you point at custom homes, pick target models per direction, choose your terminal, and toggle the hotkey.

## How it works

Native session files are read-only inputs. Continuo only ever writes its own mirror files, tracked in `bridge-state.json`; it refuses to overwrite anything it doesn't own, and never rewrites a mirror you've since continued natively (it makes a fresh one instead). Nothing runs in the background — sessions are converted only when you ask.

Converting a transcript means translating each tool call into the target agent's vocabulary (Claude's `Bash` ⇄ Codex's `exec_command`, and so on) so transplanted history reads naturally. Model matching is conservative: the source model is preserved in metadata, and the converted session gets a target-provider model from built-in family matches or your Settings defaults. Hidden provider reasoning is never carried across — only the visible conversation, tool summaries, and safe metadata.

OpenCode sessions are read from its `opencode.db` and written through the official `opencode import` command; models cross in with their provider prefix (`anthropic/claude-…`, `openai/gpt-…`) and cross out by stripping it.

Transfer budgets come from each model's real context limit, sourced from [models.dev](https://models.dev) (MIT licensed): a snapshot is bundled at build time and refreshed weekly at runtime, falling back to the bundle when offline.

## Build

```sh
swift test
./Scripts/package-app.sh   # → dist/Continuo.app
```

Signed, notarized release DMGs are built in CI — see [docs/RELEASING.md](docs/RELEASING.md).

## License

MIT — see [LICENSE](LICENSE). Bundled model metadata is from [models.dev](https://models.dev), also MIT.
