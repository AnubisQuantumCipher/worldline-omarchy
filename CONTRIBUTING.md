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
- Confirm the plugin still loads with no QML errors:
  `journalctl --user -n 60 | grep -iE 'Multiverse|WorldlineBar'` should be clean.
- Keep the plugin self-contained — no new runtime dependencies beyond the
  Omarchy shell and the `worldline` CLI.

By contributing you agree your work is licensed under the [MIT License](LICENSE).
