# Changelog

All notable changes to the WORLDLINE Omarchy plugin are documented here.
This project adheres to [Semantic Versioning](https://semver.org).

## [1.0.0] — 2026-08-29

First public release.

### Added
- Bar widget: a single **globe** glyph rendered via `BarIconButton`, sized to the
  bar's native icon slot and colored by the active reality's proof state, with
  the full reality · agent · delta · proof line in the hover tooltip.
- Multiverse overlay: a pan/zoom/keyboard-navigable fork graph with
  **state-colored nodes** (green live/selected, red `DEGRADED`/`DEAD`, grey
  archived/collapsed) and a per-world inspector (parent, cause, agent, delta,
  checks, formal obligations, ancestor integrity, hash, descendants).
- Fork editor: write one mission and launch a three-agent race
  (`worldline race`) against a frozen reality.
- Collapse / return review: a two-step confirmation panel showing base,
  candidate delta, conflicts, contamination, and invariant-preservation state
  before anything touches `PRIME`.
- Alternate-world tint and "a better future was found" notifications.
- `install.sh`: idempotent installer (copies the plugin, enables the bar widget
  in `shell.json`, binds `SUPER+CTRL+W` / `SUPER+SHIFT+W`, restarts the shell).

### Notes
- The inspector title and hash now elide/shorten so long UUIDs and digests never
  overflow the panel; graph labels are shortened so they no longer collide.
- All colors, fonts, and spacing derive from Omarchy's shared theme tokens.
