# Changelog

## [0.2.0](https://github.com/strobil/CodexTPS/compare/CodexTPS-v0.1.0...CodexTPS-v0.2.0) (2026-10-06)


### ⚠ BREAKING CHANGES

* the [otel] logs exporter in ~/.codex/config.toml is now required; responses made while the app is not running are not recorded.

### Features

* add a launch at login option ([6c336ac](https://github.com/strobil/CodexTPS/commit/6c336ac1fbf519d15d7431e1415c5a1364b8b3a9))
* choose what the menu bar number shows ([00fecc9](https://github.com/strobil/CodexTPS/commit/00fecc96c7b26f5163248e58c6f403733e01d89f))
* decode speed and TTFT from Codex telemetry ([656a1ed](https://github.com/strobil/CodexTPS/commit/656a1edaf594671d91320aad96454796e2dbaed8))
* Grafana-style ranges from 5m to 90d ([9896566](https://github.com/strobil/CodexTPS/commit/9896566ac04a87d56557231c461670f70b1a299c))
* group series by model and tier, with an option to split by effort ([9476af8](https://github.com/strobil/CodexTPS/commit/9476af84609500b6ec94ce52ad4d45a81d533de0))
* offer to configure Codex telemetry and restart Codex ([4f399fd](https://github.com/strobil/CodexTPS/commit/4f399fd88ecdaa82d5ef72f1a8b3235190a5a79a))
* record responses from telemetry only ([e215a70](https://github.com/strobil/CodexTPS/commit/e215a70ff854a0fd290926d2cdf5a4323149257c))
* redesign the popover as Now and Compare tabs ([0a17e33](https://github.com/strobil/CodexTPS/commit/0a17e3310fce5eee9bad5a64bf8084d5598d494f))


### Bug Fixes

* keep popover height constant across ranges and idle series ([42afabe](https://github.com/strobil/CodexTPS/commit/42afabe69b83400bd615eee89861dda920094f9a))
* keep series figures during pauses and render snapshots like the real popover ([841d486](https://github.com/strobil/CodexTPS/commit/841d486229510826c6203b6200fc63629ea0f7e3))
* show hover values in the legend instead of a tooltip over the chart ([76e04d2](https://github.com/strobil/CodexTPS/commit/76e04d2922c1d747fdd4e247ce9c0d137ad11938))
* size the popover window to its content ([1c53e7b](https://github.com/strobil/CodexTPS/commit/1c53e7b74221997327791abb508acc3252ef66d0))
* stop the range picker and legend from reflowing on hover ([f890985](https://github.com/strobil/CodexTPS/commit/f89098555d1d135fdfa51b84608c5e0e179bbfa9))

## 0.1.0 (2026-10-05)


### Features

* group by raw service tier and recognise Ultrafast ([84615cf](https://github.com/strobil/CodexTPS/commit/84615cfdc22873b1992cdd0e30bea794c7f1ba30))


### Bug Fixes

* draw range picker and quit button with SwiftUI controls ([91dc2e4](https://github.com/strobil/CodexTPS/commit/91dc2e495e6a01f7fc2930e2fe04156e4285d036))
* treat service_tier "fast" as Fast and match "ultrafast" exactly ([126f089](https://github.com/strobil/CodexTPS/commit/126f0892c89888edabd2321217955dae782cba9d))


### Continuous Integration

* add release-please and attach app zip to releases ([49ad2bf](https://github.com/strobil/CodexTPS/commit/49ad2bfa47120071cd833db5dffe4b39143e1575))
