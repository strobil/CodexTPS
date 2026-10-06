# CodexTPS

macOS menu bar app that shows live output tokens per second for the Codex desktop app and CLI, broken down by model, reasoning effort and service tier: `–` default, `⚡` Fast (`fast` / `priority`), `⚡⚡` Ultrafast (`ultrafast`); any other tier is shown by name.

- Menu bar: TPS of the latest response, or a 1m / 5m token-weighted average (default 1m), for all series or one pinned series. Click a table row to pin it. After a pause the last known value stays instead of blanking.
- Popover: per model × effort × tier table for the last minute and a chart with Grafana's quick ranges from 5m to 90d. The eight most recently active series get their own color; older ones fold into "Other".

<p>
  <img src="docs/popover-light.png" width="49%" alt="Popover in light mode: 10-hour chart, hovered interval values shown in the legend">
  <img src="docs/popover-dark.png" width="49%" alt="Popover in dark mode: last-minute table and 30-minute TPS chart">
</p>

## How it works

Codex hooks fire once per turn and carry no token counts, so the app tails the rollout logs in `~/.codex/sessions/**/rollout-*.jsonl` instead. For every `token_usage_record` it takes `output_tokens` and divides by the time since the request was sent (turn start, tool output or user message), so TPS includes time to first token. Model, effort and tier come from `thread_settings_applied` / `turn_context`.

Files modified in the last 30 minutes are polled once per second; FSEvents does not fire for the way Codex appends to rollouts. Only lines that carry settings or token usage are JSON-parsed. Read offsets, parser state and samples are cached in `~/Library/Caches/local.codex-tps`, so only the first launch scans the full 90 days of logs (about 15 s for 3 GB); later launches load in under a second.

## Install

Download `CodexTPS-<version>-macos-arm64.zip` from [Releases](https://github.com/strobil/CodexTPS/releases), unzip and move `CodexTPS.app` to `/Applications`. The app is ad-hoc signed, not notarized, so clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/CodexTPS.app
```

Turn on **Launch at login** at the bottom of the popover to start it with macOS (it shows up under System Settings → General → Login Items).

## Build

Requires macOS 14+ and a Swift 6 toolchain.

```sh
./build.sh
open build/CodexTPS.app
```

`CodexTPS --snapshot out.png [dark] [hover] [tray] [m5…d90]` renders the popover to a PNG and exits; `CodexTPS --bench [groups]` reports the log scan time and per-series totals. `CODEX_SESSIONS_DIR` points the app at another sessions directory, e.g. synthetic test logs.

## Releases

[release-please](https://github.com/googleapis/release-please) keeps a release PR open on `main` based on [Conventional Commits](https://www.conventionalcommits.org/) (`feat:` → minor, `fix:` → patch). Merging it tags the version, publishes a GitHub Release and attaches the built app zip with its SHA-256.
