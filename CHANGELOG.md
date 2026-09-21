# Changelog

## 1.3.1 — 2026-09-21 · the inspector follows the active world; tall graphs fit

- **`worldline inspect ALIAS` now moves the cockpit's selection.** The selection made at first
  load stuck until the operator navigated; with twenty worlds the panel kept showing an old
  PRIME generation while the header said another world was active.
- **Auto-fit considers height.** A history eight generations deep put the newest lanes below
  the viewport; the fit now uses both axes (down to 35 %), and `0` still restores it.

## 1.3.0 — 2026-09-20 · engine 1.2.0 surfaces

- **Diagnostics card** gains four rows from `doctor`: **anchor** (signed receipt ledger: entries,
  unanchored count, the `attest` verdict, and whether the external copy matches; urgent on
  BROKEN, MISMATCH, ROLLED_BACK, or a failed attest), **store usage** (bytes by area, with the
  reminder that `worldline prune` reclaims finished worlds), **network** (the world egress
  policy: shared / allowlist / none), and **timeout** (the default limit).
- **Jobs card** says what happened to the job: a completed run reads FINISHED, a stopped one
  TIMED OUT or CANCELLED; before, a finished job showed the world word VALID.
- **Delta counts honour truncation**: the engine now caps a world's file list in the status
  document at 200 entries and reports the total; the cockpit shows the total.

## 1.2.1 — 2026-09-20 · dense generations, real-credential harness

- **Graph: a generation with many siblings overprinted its labels.** Eight worlds in one
  generation (a race plus forks — the private real-agent harness produced exactly this) were
  squeezed into the viewport until every label plate covered its neighbour's. Columns now keep
  a minimum pitch (the row grows past the viewport and pans) and adjacent labels in a dense row
  alternate between two bands.
- **tools/ui-harness.sh `start --real`**: private store, socket, and root, but the real `$HOME`,
  so the builtin adapters find their credentials; used to run claude, codex, omp, and pi for
  real, a real three-lane race, and a cockpit-driven real fork (`claude-1`, VALID).
- **tools/test-model.mjs**: node tests for the pure Model.js helpers (10).
- Adapter cards show the engine's `UNAVAILABLE` reason verbatim (pi: "no provider credentials
  … run `pi login`"), which the 1.1.1 engine now reports before any world is created.

All notable changes to the WORLDLINE Omarchy plugin are documented here.
This project adheres to [Semantic Versioning](https://semver.org).

## [1.2.0] — 2026-09-20

Mission control, rebuilt around the engine's prepared-transaction contract (engine ≥ 1.1.0).
Every screen was driven with real key input against a live daemon and an isolated harness
daemon and inspected as rendered; the shell log is clean of QML errors and binding loops.

### Fixed
- **Collapse and return used to run `--yes` after a confirmation step that reviewed nothing
  fresh.** The review panel showed retained world fields, and its "Conflicts" line read the
  receipt's non-existent `conflicts` key through a truthy empty object, so missing evidence
  rendered as `0`. The panel now runs `worldline collapse|return --prepare --json`, renders
  exactly what came back (kernel decision, transaction id, before/candidate/staged roots,
  managed roots, every operation, evaluated conflicts and contamination, dependency changes),
  asks for a second confirmation in the shell's native dialog, and commits **that transaction
  id** with `worldline transaction commit`. Escape, Cancel, or closing the cockpit aborts it.
  A change to PRIME between review and commit is refused by the daemon and shown as
  `PRIME_CHANGED_AFTER_PREPARE`; a conflict is shown as `DENIED — NOTHING WAS WRITTEN` with the
  diverged paths.
- **Typing in the mission editor could switch modes.** The key handler was a sibling of the UI
  tree, so a focused editor never handed it Escape, and mode keys were gated wrongly. The
  handler now owns the tree; editors intercept Escape and Ctrl+Enter themselves.
- **The bar tinted the globe by proof-kind checks only** while the cockpit judged all checks.
  Both now derive one evidence state in `Model.js`.
- Installed copies had drifted from source (the engine repository shipped a 1.0 snapshot that
  its installer copied over this plugin). The plugin is now deployed only as a git checkout.

### Added
- **Fork editor**: single fork with an explicit adapter (number keys 1–9 or click) and alias,
  or a deliberate three-adapter race with an optional lane prefix (`--name`). Each adapter shows
  its probe state and the reason it is unavailable. Spend is stated before launch.
- **Cancel** for a running world (`worldline cancel`), from the inspector or the JOBS card.
- **Diagnostics card** from `worldline doctor`: managed-root, store, receipt, recovery and
  supervision integrity, open transactions with an abort button, capabilities on demand.
- **Inspector**: evidence per check with the required flag and reason, full delta list, a
  sibling comparison ranked like `pick_candidate.py` (refuses to recommend without evidence),
  agent stderr tail, identities behind a disclosure, mission expander.
- **First run and managed roots** (`M`): guidance, registered roots with integrity, dry-run
  add/remove with the exact facts and a native confirmation.
- **Evidence vocabulary** distinct from lifecycle: `PASS` (with `· N GAP` when optional checks
  failed), `FAIL` (a required check failed), `UNASSESSED`, `UNAVAILABLE`, `STALE`. Lifecycle
  states are shown beside it, never instead of it.
- **States**: NO SIGNAL (daemon offline), SIGNAL STALE (heartbeat > 10 s, actions disabled),
  NO PRIME, running (dashed ring, pulse when motion is on, header count), refusal, recovery.
- **Test seams**: summon with `{"fixture": true, "statusPath": …}` to render any status
  document with every consequential action disabled, or `{"harness": {…}}` to point the
  status file *and* every CLI call at an isolated daemon (`tools/ui-harness.sh`).
- Keyboard: `← → ↑ ↓ / h j k l`, `⏎`, `C`, `R`, `X`, `I`, `S`, `L`, `F`, `M`, `D`, `0`, `?`.
- Bar: running-job count badge; tooltip carries alias / agent / delta / evidence / lifecycle.

### Changed
- Status polling: the bar reloads every 2 s and skips parsing unchanged bytes; the service
  every 5 s; the cockpit only while open.
- `manifest.json` 1.2.0; new files `Model.js`, `ForkPanel.qml`, `Wl*.qml`, `tools/`.

## [1.1.1] — 2026-09-02

Honest surfaces. Found by an adversarial audit of the plugin against the engine
it renders; every item was verified against the runtime source.

### Fixed
- **A world's agent could forge UI chrome on the collapse-authorization screen.**
  QML `Text` defaults to `AutoText`, so Qt's rich-text heuristic rendered
  engine-supplied strings — including filenames an in-world agent chooses — as
  markup, on the exact panel a human reads before approving an irreversible
  PRIME replacement. Every `Text` element now sets
  `textFormat: Text.PlainText`. No code execution was possible and no
  exfiltration channel could be constructed; this was display spoofing.
- **The review panel affirmed two gates it never evaluated.** "Foreign
  contamination: NONE" and "Conflicts: 0" fell through to world fields the
  runtime never writes (they are empty at construction and assigned nowhere);
  the real values exist only in the transaction record and receipt. Before a
  collapse they now read `UNEVALUATED — computed at collapse.prepare` and `—`.
- **Delta file lists were unreadable.** The label looked for `path`/`file`, but
  delta operations carry `pathDisplay`.
- **Job failures rendered as `[object Object]`.**
- **A world alias beginning with `-` retargeted `worldline return`.** `return`
  and `collapse` now pass `--` before the alias.
- **A check whose status was neither PASS nor FAIL** (e.g. `UNAVAILABLE`) was
  rounded up to a filled green PASS badge; it now reports `UNASSESSED`.

## [1.1.0] — 2026-08-29

Mission-control overlay: header chips, left rail (REALITY, LAST COLLAPSE, CENSUS, JOBS,
CAPABILITIES, ADAPTERS), right inspector, graph with generation guides and evidence badges,
keyboard navigation, fork editor targeting the first three AVAILABLE adapters.

## [1.0.0] — 2026-08-29

First public release: bar globe, multiverse overlay, fork editor (three-agent race),
two-step collapse/return panel, alternate-world tint, idempotent installer.
