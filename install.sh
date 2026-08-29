#!/usr/bin/env bash
# Install the WORLDLINE bar widget + multiverse overlay into Omarchy.
#
#   * copies the QML into ~/.config/omarchy/plugins/khephri.worldline
#   * enables the bar widget in ~/.config/omarchy/shell.json (right section)
#   * binds SUPER+CTRL+W (multiverse) and SUPER+SHIFT+W (fork) in
#     ~/.config/hypr/bindings.lua  (managed block; skipped if you decline)
#   * restarts the shell so the widget appears
#
# Idempotent: re-running only fills in what is missing.
set -uo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
ID="khephri.worldline"
DEST="$HOME/.config/omarchy/plugins/$ID"
SHELL_JSON="$HOME/.config/omarchy/shell.json"
BINDINGS="$HOME/.config/hypr/bindings.lua"

echo "WORLDLINE plugin → $DEST"
mkdir -p "$DEST"
cp -f "$SRC_DIR"/*.qml "$SRC_DIR"/manifest.json "$DEST"/
echo "  copied QML + manifest"

# 1. Enable the bar widget (insert into bar.layout.right if absent).
if [[ -f "$SHELL_JSON" ]]; then
  python3 - "$SHELL_JSON" "$ID" <<'PY'
import json, sys, os
path, wid = sys.argv[1], sys.argv[2]
cfg = json.load(open(path))
right = cfg.setdefault("bar", {}).setdefault("layout", {}).setdefault("right", [])
if any(isinstance(e, dict) and e.get("id") == wid for e in right):
    print("  shell.json: already enabled"); raise SystemExit(0)
right.append({"id": wid})
tmp = path + ".new"
json.dump(cfg, open(tmp, "w"), indent=2); open(tmp, "a").write("\n"); os.replace(tmp, path)
print("  shell.json: added %s to bar.right" % wid)
PY
else
  echo "  shell.json not found — enable the widget manually in your bar config"
fi

# 2. Keybindings (Lua-native Hyprland; managed block).
if [[ -f "$BINDINGS" ]]; then
  if grep -q "BEGIN WORLDLINE" "$BINDINGS"; then
    echo "  bindings.lua: WORLDLINE block already present"
  else
    cat >> "$BINDINGS" <<'LUA'

-- BEGIN WORLDLINE (managed by worldline-omarchy install.sh)
hl.unbind("SUPER + SHIFT + W")
o.bind("SUPER + SHIFT + W", "WORLDLINE: fork reality", "omarchy-shell shell summon khephri.worldline '{\"mode\":\"fork\"}'")
hl.unbind("SUPER + CTRL + W")
o.bind("SUPER + CTRL + W", "WORLDLINE: multiverse", "omarchy-shell shell summon khephri.worldline '{\"mode\":\"multiverse\"}'")
-- END WORLDLINE
LUA
    echo "  bindings.lua: bound SUPER+SHIFT+W (fork) and SUPER+CTRL+W (multiverse)"
  fi
else
  echo "  bindings.lua not found — bind the keys manually if you want them"
fi

# 3. Live reload.
command -v omarchy-shell >/dev/null 2>&1 && omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
if [[ -x "$HOME/.local/share/omarchy/bin/omarchy-restart-shell" ]]; then
  "$HOME/.local/share/omarchy/bin/omarchy-restart-shell" >/dev/null 2>&1 || true
  echo "  shell restarted"
fi

echo "Done. Click the globe in the bar, or press SUPER+CTRL+W."
echo "NOTE: the plugin renders the WORLDLINE engine's status; install the"
echo "      'worldline' / 'worldlined' engine separately for it to show data."
