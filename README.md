# CodexTPS

macOS menu bar app that shows live output tokens per second for the Codex desktop app and CLI, broken down by model, reasoning effort and service tier: `–` default, `⚡` Fast (`fast` / `priority`), `⚡⚡` Ultrafast (`ultrafast`); any other tier is shown by name.

- Menu bar: TPS of the latest model response.
- Popover: per model × effort × tier table for the last minute and a chart for 30m / 2h / 5h / 10h.

<p>
  <img src="docs/popover-light.png" width="49%" alt="Popover in light mode: last-minute table and 30-minute TPS chart">
  <img src="docs/popover-dark.png" width="49%" alt="Popover in dark mode: 2-hour chart with hover tooltip">
</p>

## How it works

Codex hooks fire once per turn and carry no token counts, so the app tails the rollout logs in `~/.codex/sessions/**/rollout-*.jsonl` instead. For every `token_usage_record` it takes `output_tokens` and divides by the time since the request was sent (turn start, tool output or user message), so TPS includes time to first token. Model, effort and tier come from `thread_settings_applied` / `turn_context`.

Files are polled once per second; FSEvents does not fire for the way Codex appends to rollouts.

## Install

Download `CodexTPS-<version>-macos-arm64.zip` from [Releases](https://github.com/strobil/CodexTPS/releases), unzip and move `CodexTPS.app` to `/Applications`. The app is ad-hoc signed, not notarized, so clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/CodexTPS.app
```

## Build

Requires macOS 14+ and a Swift 6 toolchain.

```sh
./build.sh
open build/CodexTPS.app
```

`CodexTPS --snapshot out.png [dark] [hover] [m30|h2|h5|h10]` renders the popover to a PNG and exits. `CODEX_SESSIONS_DIR` points the app at another sessions directory, e.g. synthetic test logs.

## Releases

[release-please](https://github.com/googleapis/release-please) keeps a release PR open on `main` based on [Conventional Commits](https://www.conventionalcommits.org/) (`feat:` → minor, `fix:` → patch). Merging it tags the version, publishes a GitHub Release and attaches the built app zip with its SHA-256.
