# CodexTPS

macOS menu bar app that shows live output tokens per second for the Codex desktop app and CLI, broken down by model, reasoning effort and fast mode (`service_tier = priority`).

- Menu bar: TPS of the latest model response.
- Popover: per model × effort × fast table for the last minute and a chart for 30m / 2h / 5h / 10h.

## How it works

Codex hooks fire once per turn and carry no token counts, so the app tails the rollout logs in `~/.codex/sessions/**/rollout-*.jsonl` instead. For every `token_usage_record` it takes `output_tokens` and divides by the time since the request was sent (turn start, tool output or user message), so TPS includes time to first token. Model, effort and tier come from `thread_settings_applied` / `turn_context`.

Files are polled once per second; FSEvents does not fire for the way Codex appends to rollouts.

## Build

Requires macOS 14+ and a Swift 6 toolchain.

```sh
./build.sh
open build/CodexTPS.app
```

`CodexTPS --snapshot out.png [dark] [hover] [m30|h2|h5|h10]` renders the popover to a PNG and exits.
