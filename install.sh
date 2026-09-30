#!/usr/bin/env bash
# Install the WORLDLINE desktop plugin into Omarchy as a git checkout.
#
#   * clones this repository into ~/.config/omarchy/plugins/khephri.worldline (or fast-forwards
#     an existing checkout) — the deployed plugin is always a commit of this repository, never a
#     hand-edited copy, so `omarchy plugin update khephri.worldline` keeps working
#   * enables the bar widget in ~/.config/omarchy/shell.json (right section)
#   * writes the managed key-binding block in ~/.config/hypr/bindings.lua (same markers as the
#     engine's installer, so the two never stack two blocks)
#   * restarts the shell (the overlay and service are keepLoaded, which only a restart replaces)
#
# Idempotent. The engine (`worldline`/`worldlined`) is separate: without it the plugin renders
# NO SIGNAL and every consequential control stays disabled.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
ID="khephri.worldline"
DEST="$HOME/.config/omarchy/plugins/$ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
BINDINGS="$HOME/.config/hypr/bindings.lua"
REF="${WORLDLINE_PLUGIN_REF:-main}"

echo "WORLDLINE plugin → $DEST"
if [[ -d "$DEST/.git" ]]; then
  if ! git -C "$DEST" remote get-url origin >/dev/null 2>&1; then git -C "$DEST" remote add origin "$SRC_DIR"; fi
  git -C "$DEST" fetch --quiet origin "$REF"
  if git -C "$DEST" merge --ff-only FETCH_HEAD >/dev/null 2>&1; then
    echo "  fast-forwarded to $(git -C "$DEST" rev-parse --short HEAD)"
  else
    echo "  refusing: $DEST has local changes that are not in $SRC_DIR ($REF); inspect with git -C $DEST status" >&2
    exit 3
  fi
elif [[ -e "$DEST" ]]; then
  echo "  refusing: $DEST exists and is not a git checkout; move it aside first" >&2
  exit 3
else
  mkdir -p "$(dirname "$DEST")"
  git clone --quiet --branch "$REF" "$SRC_DIR" "$DEST"
  echo "  cloned $(git -C "$DEST" rev-parse --short HEAD)"
fi
command -v omarchy-plugin-validate >/dev/null 2>&1 && omarchy-plugin-validate "$DEST"

# 1. Enable the bar widget (insert into bar.layout.right if absent).
if [[ -f "$SHELL_JSON" ]]; then
  python3 - "$SHELL_JSON" "$ID" <<'PY'
import json, sys, os
path, wid = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
layout = cfg.setdefault("bar", {}).setdefault("layout", {})
if any(isinstance(e, dict) and e.get("id") == wid for section in layout.values() if isinstance(section, list) for e in section):
    print("  shell.json: already enabled"); raise SystemExit(0)
layout.setdefault("right", []).append({"id": wid})
tmp = path + ".new"
json.dump(cfg, open(tmp, "w"), indent=2); open(tmp, "a").write("\n"); os.replace(tmp, path)
print("  shell.json: added %s to bar.right" % wid)
PY
else
  echo "  shell.json not found — enable the widget manually in your bar config"
fi

# 2. Keybindings: one managed block, identical to the engine installer's (runtime/worldline/install_config.py).
if [[ -f "$BINDINGS" ]]; then
  python3 - "$BINDINGS" <<'PY'
import re, sys
from pathlib import Path
path = Path(sys.argv[1])
BEGIN = "-- BEGIN WORLDLINE (managed by install.sh)"
END = "-- END WORLDLINE (managed by install.sh)"
BLOCK = f'''{BEGIN}
-- SUPER + SHIFT + W displaced Omawrite.
hl.unbind("SUPER + SHIFT + W")
o.bind("SUPER + SHIFT + W", "WORLDLINE: fork reality", "omarchy-shell shell summon khephri.worldline '{{\\"mode\\":\\"fork\\"}}'")

-- SUPER + CTRL + W displaced Network.
hl.unbind("SUPER + CTRL + W")
o.bind("SUPER + CTRL + W", "WORLDLINE: multiverse", "omarchy-shell shell summon khephri.worldline '{{\\"mode\\":\\"multiverse\\"}}'")

-- SUPER + ALT + RIGHT displaced Move window to group on right.
hl.unbind("SUPER + ALT + RIGHT")
o.bind("SUPER + ALT + RIGHT", "WORLDLINE: next reality", "worldline switch --next")
{END}
'''
text = path.read_text(encoding="utf-8")
# Also retire the older plugin-only block variant so the two installers never stack.
for begin, end in ((BEGIN, END), ("-- BEGIN WORLDLINE (managed by worldline-omarchy install.sh)", "-- END WORLDLINE")):
    text = re.sub(re.escape(begin) + r".*?" + re.escape(end) + r"\n?", "", text, flags=re.DOTALL)
path.write_text(text.rstrip() + "\n\n" + BLOCK, encoding="utf-8")
print("  bindings.lua: WORLDLINE block written (SUPER+SHIFT+W fork, SUPER+CTRL+W multiverse, SUPER+ALT+RIGHT next)")
PY
else
  echo "  bindings.lua not found — bind the keys manually if you want them"
fi

# 3. Live reload. Restart the shell, or ask it to rescan, never both: a rescan is still
# completing plugin objects when the restart kills the shell, and quickshell 0.3.1 has already
# freed its IPC handler registry by then, so the shell segfaults instead of exiting
# (quickshell-mirror/quickshell#956). A restart re-reads every plugin on its own.
#
# Updating the checkout above also wakes the shell's own plugin watcher, which rescans after a
# 150 ms debounce. The pause below lets that rescan settle before the restart's kill. Nothing
# signals that it has finished, so the pause narrows that window; it does not close it.
RELOAD="none"
if [[ "${WORLDLINE_NO_SHELL_RESTART:-0}" != "1" ]] && command -v omarchy-restart-shell >/dev/null 2>&1; then
  sleep 2
  # omarchy-restart-shell's own messages are kept: they say which way it failed.
  if omarchy-restart-shell >/dev/null; then
    RELOAD="restarted"
    echo "  shell restarted"
  else
    rc=$?
    RELOAD="failed"
    echo "  shell restart reported failure (omarchy-restart-shell exited $rc; its message is above)." >&2
    echo "  If it refused before stopping the shell (a locked session, a missing shell config), the" >&2
    echo "  shell was not restarted, and a WORLDLINE service it already had keeps running the previous" >&2
    echo "  code. If it restarted the shell but could not re-secure the session lock, lock the session now." >&2
    echo "  Otherwise the shell may be down. Run omarchy-restart-shell to load this commit." >&2
  fi
elif command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell -q shell rescanPlugins || true
  RELOAD="rescanned"
  echo "  shell asked to rescan plugins. A WORLDLINE service the shell already had is kept loaded"
  echo "  across a rescan and keeps running the previous code until the shell restarts: run"
  echo "  omarchy-restart-shell."
elif [[ "${WORLDLINE_NO_SHELL_RESTART:-0}" == "1" ]]; then
  echo "  shell not reloaded (WORLDLINE_NO_SHELL_RESTART=1, and omarchy-shell was not found to rescan):"
  echo "  restart the shell to load this commit."
else
  echo "  shell not reloaded (neither omarchy-restart-shell nor omarchy-shell was found):"
  echo "  restart the shell to load this commit."
fi

if [[ "$RELOAD" == "failed" ]]; then
  echo "Installed $(git -C "$DEST" rev-parse --short HEAD), but the shell restart reported failure." >&2
  exit 4
fi
echo "Done. Click the globe in the bar, or press SUPER+CTRL+W."
echo "NOTE: the plugin renders the WORLDLINE engine's status; install the engine from"
echo "      ~/Projects/worldline (./install.sh) for it to show data and perform actions."
