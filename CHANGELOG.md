# Changelog

All notable changes to the WORLDLINE Omarchy plugin are documented here.
This project adheres to [Semantic Versioning](https://semver.org).

## [1.1.0] — 2026-08-29

Mission-control overlay.

### Added
- The full-screen overlay is now an information-rich cockpit: header chips for
  daemon state (goes `STALE` when the heartbeat is >10 s old), `PRIME`
  (+`DIRTY` flag), active world, and storage backend; a left rail with
  REALITY (managed roots), LAST COLLAPSE (receipt id, `renameat2` mechanism,
  invariant-preservation state and check count, non-claims count), CENSUS,
  JOBS, CAPABILITIES (each probe with its honest `UNAVAILABLE` reason), and
  ADAPTERS (live `worldline adapters --json` probe); and a right inspector
  with risk/complexity chips labeled as derived, delta breakdown with file
  paths, per-check evidence (or the honest `UNASSESSED` line), collapse
  gates (conflicts/contamination), and a live-ticking lifetime.
- Graph: generation guide lines, node radius scaled by delta size, a
  double ring on `PRIME`, selection halo, and a per-node evidence badge
  (filled `PASS` / red `FAIL` / hollow `UNASSESSED`).
- Keyboard: `F` opens the fork editor, `G` returns to the graph; footer shows
  the full keymap plus worlds/jobs/daemon-age status.
- Fork editor now targets the first three `AVAILABLE` adapters instead of a
  hardcoded trio, and states the ~3× race spend up front.

### Fixed
- `invariantPreservation` renders its state and check count instead of
  `[object Object]`.
- The graph legend wraps (`Flow`) so its minimum width can no longer push the
  inspector rail off-screen.

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
