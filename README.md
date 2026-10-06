# CodexTPS

macOS menu bar app that shows live output tokens per second for the Codex desktop app and CLI, broken down by model and service tier (optionally reasoning effort): `–` default, `⚡` Fast (`fast` / `priority`), `⚡⚡` Ultrafast (`ultrafast`); any other tier is shown by name.

- Menu bar: TPS of the latest response, or a 1m / 5m token-weighted average (default 1m), for all series or one pinned series. Click a table row to pin it. After a pause the last known value stays instead of blanking.
- Popover: per model × tier table for the last minute (tick **Split by effort** to also split by reasoning effort, which barely changes decode speed but does change TTFT) and a chart with Grafana's quick ranges from 5m to 90d. The eight most recently active series get their own color; older ones fold into "Other".

<p>
  <img src="docs/popover-light.png" width="49%" alt="Popover in light mode: 10-hour chart, hovered interval values shown in the legend">
  <img src="docs/popover-dark.png" width="49%" alt="Popover in dark mode: last-minute table and 30-minute TPS chart">
</p>

## Setup

The app gets its data from Codex's OpenTelemetry logs. Add to `~/.codex/config.toml` and fully restart Codex (⌘Q for the desktop app; its app server only reads the config at start):

```toml
[otel]
exporter = { otlp-http = { endpoint = "http://127.0.0.1:43180/v1/logs", protocol = "json" } }
```

Responses made while CodexTPS is not running are not recorded.

## How it works

CodexTPS listens for OTLP/HTTP JSON on `127.0.0.1:43180` only. It pairs each `codex.websocket_request` (request sent) with the next `codex.sse_event` `response.completed` of the same conversation, which carries `ttft_ms`, output and reasoning tokens, model, reasoning effort and service tier. Each response becomes one row in `~/Library/Application Support/CodexTPS/metrics.sqlite`.

- **E2E TPS** = output tokens / (request sent → response completed), including time to first token.
- **Decode TPS** = (output tokens − 1) / (duration − TTFT), the generation speed itself.
- **TTFT** = time to first token as measured by Codex.

Averages are token-weighted. The **Speed** switch picks E2E or Decode for the chart and the menu bar; the table shows E2E, Decode and TTFT for the last minute.

### Importing history

`scripts/import-rollouts.py` backfills the database from Codex rollout logs (`~/.codex/sessions` and `~/.codex/archived_sessions`), skipping responses already recorded. Logs only time a request from the event that handed control back to the model to its `token_usage_record`, so imported rows have E2E timing but no TTFT or decode speed. Codex writes `token_usage_record` since early September 2026; older logs yield nothing.

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

`CodexTPS --snapshot out.png [dark] [hover] [tray] [m5…d90]` renders the popover to a PNG and exits; `CodexTPS --bench [groups]` reports the load time and per-series totals.

## Releases

[release-please](https://github.com/googleapis/release-please) keeps a release PR open on `main` based on [Conventional Commits](https://www.conventionalcommits.org/) (`feat:` → minor, `fix:` → patch). Merging it tags the version, publishes a GitHub Release and attaches the built app zip with its SHA-256.
