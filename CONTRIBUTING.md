# Contributing to WORLDLINE for Omarchy

Thanks for your interest. This is the Omarchy **plugin** (the QML UI). The
WORLDLINE engine lives elsewhere; issues about fork/collapse *behaviour* belong
there, and issues about the *bar widget, overlay, graph, or inspector* belong
here.

## Dev loop

The plugin is pure QML — no build step.

```bash
# work on the deployed copy so the shell hot-reloads your edits
cd ~/.config/omarchy/plugins/khephri.worldline
$EDITOR Multiverse.qml
~/.local/share/omarchy/bin/omarchy-restart-shell   # picks up bar-widget changes
```

Editing files under `~/.config/omarchy/plugins/` triggers Omarchy's plugin
watcher, which hot-reloads the overlay/service. **Bar-widget** changes are
component-cached, so restart the shell to see them.

To view the overlay while iterating:

```bash
omarchy-shell shell summon khephri.worldline '{"mode":"multiverse"}'
grim /tmp/wl.png   # screenshot to check rendering
```

## Style

- **Never hard-code colors, fonts, or spacing.** Use the shared tokens —
  `Color.*` (`foreground`, `background`, `accent`, `muted`, `urgent`),
  `Style.font.*`, `Style.space(n)`, `Style.spacing.*`, `Style.bar.*`,
  `Util.alpha(...)`. This is what keeps the plugin theme-native.
- Render bar glyphs with `BarIconButton` and `Style.bar.iconSlot` / `iconFont`
  so they match the native bar icons.
- Constrain every `Text` that shows engine data: `Layout.fillWidth`, an `elide`
  mode, and a `maximumLineCount` where it can wrap — status values (hashes,
  UUIDs, causes) are arbitrary length and must never overflow.
- **Read state honestly.** Show the engine's real values; render unknowns as `—`.
  Never invent a count, a hash, or a proof state the status file didn't provide.

## Pull requests

- One focused change per PR; describe the before/after (a screenshot helps).
- Run `node tools/test-model.mjs` and `node tools/check-plain-text.mjs`; CI runs both.
  Strings here come from the engine, adapters, projects, and coding agents, so none may reach
  a markup renderer: every `Text`/`Label` sets `textFormat: Text.PlainText` (a
  `TextEdit`/`TextArea` sets `TextEdit.PlainText`), `placeholderText` is a constant, no
  Qt Quick Controls `ToolTip` (use the shell `Button`'s `tooltipText`), and a
  `notify-send` body goes through `Model.notificationBody()`.
- Run `node tools/check-code-table.mjs` and `node tools/test-collapse-panel.mjs`. The panel
  harness requires Qt 6's `qmltestrunner` and uses stand-ins for the shell and CLI; it never
  starts the real daemon. These checks also run in CI. Before pairing an engine release,
  regenerate the vocabulary with `python3 tools/engine-codes.py ENGINE --rev COMMIT --write`
  and verify that its raw `codeSetSha256` matches the engine's generated inventory.
  The release workflow runs `node tools/check-code-table.mjs --release`, which refuses a
  working-tree inventory until that immutable inventory source has been recorded. This
  provenance check alone does not establish the final release pair.
- Confirm the plugin still loads with no QML errors:
  `journalctl --user -n 60 | grep -iE 'Multiverse|WorldlineBar'` should be clean.
- Keep the plugin self-contained — no new runtime dependencies beyond the
  Omarchy shell and the `worldline` CLI.

## Release pair identities

`tools/engine-codes.json` records the **inventory source commit**. Its `engine.commit` is
the immutable source used to derive the vocabulary, not a claim that this is the final
engine release commit. The final engine's `plugin-compatibility.json` names the final
plugin commit and its canonical `git archive --format=tar` digest. The external engine
`release-manifest.json`, produced after both commits exist, binds the final engine
commit/tree and that plugin compatibility record. This avoids circular commit identities.

Before release, validate the source pair using explicit reviewed commit identities:

```bash
python3 tools/check-release-pair.py \
  --engine-repo ENGINE --engine-commit ENGINE_COMMIT \
  --plugin-repo PLUGIN --plugin-commit PLUGIN_COMMIT
```

After the engine release manifest is produced, run the same command with
`--manifest release-manifest.json`. It checks the final engine's freshly scanned and
generated vocabulary, the plugin's inventory and runtime digest, the earlier inventory
source, the pinned plugin archive, and the external final identities. Run
`python3 tools/test-release-pair.py -v` for its temporary repository fixtures.

The plugin release workflow resolves the declared engine version to an immutable commit
and validates that version's published engine manifest in a read-only job. The engine
release must therefore be published first; publication of the plugin waits for its
final pair binding. The publishing job accepts only that same workflow run's validation
artifact for the exact commits and attaches the binding evidence to the plugin release.

An unassigned pin or differing vocabulary/archive/identity keeps release blocked.
These checks do not replace the full assurance gates, proof, review, published-artifact
verification, or installation rehearsal. The canonical tar digest does not by itself
verify a downloaded compressed release archive. The present candidate is not released
or paired, and its remaining authority and isolation obligations stay open.

By contributing you agree your work is licensed under the [MIT License](LICENSE).
