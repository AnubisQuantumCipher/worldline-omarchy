# Changelog

## 1.3.4 — 2026-09-30 · the installer restarts the shell or rescans it, never both

- **`install.sh` no longer asks the shell to rescan its plugins right before restarting it.**
  quickshell 0.3.1 segfaults if a rescan is still completing plugin objects when the restart's
  kill lands (quickshell-mirror/quickshell#956). The installer restarts the shell when
  `omarchy-restart-shell` exists and `WORLDLINE_NO_SHELL_RESTART` is not `1`. Otherwise it asks
  for a rescan. A restart re-reads every plugin on its own. This carries the fix from draft PR #1
  onto the current release; the engine carries the same fix in WORLDLINE 1.9.1.
- **Updating the checkout also wakes the shell's own plugin watcher.** It rescans after a 150 ms
  debounce, so the installer now pauses 2 s before the restart. Nothing signals that the rescan
  has finished, so this narrows the window rather than closing it. The README's rollback recipe
  now says the same: check out, wait, restart, never rescan.
- **A failed restart is reported, not printed as success.**
  - Before, the installer printed "shell restarted" and exited 0 whatever
    `omarchy-restart-shell` returned, and discarded its messages.
  - Its messages are now shown, and a failure prints the exit code and exits 4.
  - The failure text names all three outcomes:
    - it refused before stopping anything (a locked session, a missing shell config), so a
      WORLDLINE service the shell already had keeps running the previous code;
    - it restarted but could not re-secure the session lock, so lock the session now;
    - the shell may be down.
- **A reload that is not a restart says what it cannot do.** A WORLDLINE service the shell already
  had is kept loaded across a rescan and keeps running the previous code until the shell restarts. When nothing
  reloads, the message names the reason: `WORLDLINE_NO_SHELL_RESTART=1`, or neither command was
  found.
- **A reload that has no restart command does not advise one.** When `omarchy-restart-shell`
  is missing, the rescan message says "restart the shell" instead of naming the command.
- **`tools/test-install-reload.mjs`**, run by the checks and release workflows, runs the real
  installer in 20 environments, each twice: a first install, then an upgrade that must move the
  checkout to the fixture's new commit.
  - The environments cover `WORLDLINE_NO_SHELL_RESTART` 0 and 1; a restart command that is
    absent, succeeds, refuses, fails after restarting, or is a not-ready stand-in that exits 7;
    and `omarchy-shell` absent or present.
  - Each run uses a fixture built from the repository and a scratch HOME, under `env -i` with
    dummy session variables that point at scratch paths.
  - The PATH holds recording shims. Any call to `qs`, `quickshell`, `hyprctl`, `omarchy`, the
    `omarchy-plugin-*` commands, `omarchy-shell-config` or `omarchy-launch-shell` counts as
    unexpected. The host's omarchy tools are not on that PATH.
  - Each run checks that no restart and rescan both happen. A restart environment may make no
    `omarchy-shell` call, and a rescan environment makes exactly one, the rescan. It also checks
    the exit status and the text for each outcome.
  - The 1.3.3 installer fails it in 19 of the 20 environments. So do mutants modelled on the
    review's findings: a rescan after the fast-forward, rescans guarded on the session, a rescan
    in the background or through `qs`, a plugin update or enable call, and wrong or missing
    failure texts. The mutants are recorded in the review evidence, not in this repository.
  - Non-claims:
    - It observes calls through PATH made before the installer exits, or within a second after.
    - It does not observe a call by absolute path, a command after the installer reassigns PATH,
      a longer-lived background process, or a real session's sockets.
    - It does not check the pause before the restart.
    - It covers only the environments it lists.
  - An earlier draft of this release read the script statically instead. Two review rounds kept
    finding shapes it misjudged, so it was replaced by running the installer.

## 1.3.3 — 2026-09-29 · every command the plugin runs is bounded in bytes and in time

From the marketplace review of 1.3.2 (omarchy-plugin-marketplace#7900): `WlCall.qml` collected a
command's entire stdout and stderr with no byte limit and no deadline, and the log view fed it
`tail -n 60` of an agent's stderr, where one agent-written line can be any size. The output could
exhaust or hold the long-lived shell before any callback saw it.

- **`WlCall` bounds every call.** Each stream is measured as it arrives, one pipe read at a time,
  by its decoded length, and what a call delivers is checked in bytes when it exits: 1 MiB of
  stdout and 256 KiB of stderr by default (the largest real output measured: doctor 5.6 KB,
  adapters 3 KB, a transaction record 93 KB). A character is at most 3 bytes, so while a call
  runs the shell holds at most three times a limit plus one read. A call still running at its
  deadline is stopped. Either bound kills the process (SIGKILL), discards what it printed, and
  reports `CLI_OUTPUT_TOO_LARGE` or `CLI_DEADLINE` through the call's ordinary error path
  (exit 137). The probe reads the decoded length rather than the raw bytes because reading
  the bytes on every read keeps each superseded buffer alive until the garbage collector runs:
  1 MiB written in 256-byte pieces peaked 45 MB above idle that way, 8 MB this way.
- **Deadlines per action:** 60 s for adapters; 300 s for the doctor, fork, race, abort and the
  cockpit's actions; 30 minutes for collapse or return prepare and for commit; an hour for
  registering or removing a root, which moves the directory. A stopped CLI does not stop a
  request the engine already received, and the message says to check the status.
- **The agent log view reads bytes, not lines:** `tail -c 65536`, then the last 60 lines of that,
  each capped at 2,000 characters (`Model.logTail`). When the read filled its window, the first
  line is a fragment; it is dropped and the view says earlier output is not shown.
- **The "better future" notification process is bounded too:** notify-send prints only the chosen
  action's key, so more than 4 KiB, or a notification still waiting after 30 minutes, stops it.
- **Fixed while doing this:** a command that could not be started never called back (Quickshell
  reports only a running-state change), so its panel stayed loading; it now reports
  `CLI_UNAVAILABLE`. An incremental collector keeps its last value when the next call prints
  nothing, so each call now tracks whether its streams delivered anything.
- **tools/check-bounded-processes.mjs** fails, closed, when a `Process` has no id; when its
  stdout or stderr parser is not a `StdioCollector` with `waitForEnd: false` and an
  `onDataChanged` measurement; when `SplitParser` or `waitForEnd: true` appears anywhere; when no
  `data.byteLength` limit is compared; or when no `Timer` stops the process with `signal(9)`,
  directly or through a function. It runs in the checks and release workflows. On 1.3.2's tree it
  reports 13 problems; with the deadline Timer removed, or a `SplitParser` put back, it fails.
- **Measured in Quickshell 0.3.1** (a throwaway instance running this `WlCall.qml`):
  - `yes` was stopped just past the 1 MiB stdout limit in 6 ms, and a stderr flood past 64 KiB;
  - `sleep 30` was stopped at 2.0 s against a 2 s deadline;
  - a call that printed nothing after one that printed `hello` returned empty output;
  - a missing binary called back once with `CLI_UNAVAILABLE`;
  - 400,000 `é` (800,000 bytes) were delivered intact; 600,000 (1,200,000 bytes) were refused
    at exit by the byte check;
  - peak memory above an idle instance: +9 to +11 MB for a `yes` flood, +7 to +9 MB for 2 MB
    written in 256-byte pieces, both stopped at 1 MiB; 1.3.2 had no bound at all.
- **tools/test-model.mjs**: `logTail` (5 tests).

## 1.3.2 — 2026-09-28 · no engine string reaches a markup renderer, and CI checks it

From the marketplace security review of 1.3.1 (omarchy-plugin-marketplace#7900). Every `Text`
in 1.3.1 already set `textFormat: Text.PlainText` (since 1.1.1), including the three the review
cites and the shared `WlCard`, `WlChip` and `WlKV`; an audit of every other path a daemon,
adapter, project or agent string can take found three that did not.

- **The suggested world alias was drawn as AutoText.** The fork panel put the suggestion, built
  from an adapter name the daemon reports, in the alias field's `placeholderText`, and every
  stock Qt Quick Controls style draws placeholders with an AutoText `PlaceholderText`. An
  adapter named `x<img src="http://…">` made the shell fetch that URL (measured on Qt 6.11.2,
  Fusion and Basic styles). The suggestion is now a plain-text `Text` drawn where and when the
  placeholder would be.
- **The "better future" notification body carried the world alias or objective as markup.**
  The Omarchy shell advertises `body-markup` and renders the body as StyledText (it strips
  `<img>`, not links or formatting). The body is now entity-escaped (`Model.notificationBody`),
  so the shell shows it literally.
- **The mission editor states `textFormat: TextEdit.PlainText`** instead of relying on the
  `TextArea` default.
- **tools/check-plain-text.mjs** parses every QML file and fails, closed on anything it cannot
  parse, when a `Text`/`Label`/`TextEdit`/`TextArea` lacks the PlainText format; when any other
  text format, link handler or `Qt.openUrlExternally` appears; when a `placeholderText` or image
  `source` is not a constant; when a Qt Quick Controls `ToolTip` is used; when a string reaches
  an external component that has not been audited as plain text; or when a `notify-send`
  argument skips `Model.notificationBody`. The release workflow runs it, and a new `checks`
  workflow runs it with the Model.js tests on every push to `main` and every pull request.
- **tools/test-model.mjs**: notification escaping (12 tests).

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
