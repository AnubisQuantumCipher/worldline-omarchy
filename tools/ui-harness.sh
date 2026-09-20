#!/usr/bin/env bash
# Isolated daemon for exercising the cockpit end to end without touching the operator's real
# WORLDLINE: private HOME/XDG tree, a deterministic fixture adapter (no model, no quota), one
# throwaway root, and one VALID candidate ready to review. Prints the summon payload; the
# cockpit's "harness" seam then routes its status file AND every `worldline` command at this
# daemon, with actions enabled and a banner saying so.
#
#   tools/ui-harness.sh start            # sets up, forks a VALID world, prints the payload
#   tools/ui-harness.sh summon [mode]    # summon the cockpit onto the harness
#   tools/ui-harness.sh slow             # fork a slow world (for cancel)
#   tools/ui-harness.sh status           # status --json of the harness daemon
#   tools/ui-harness.sh stop             # stop the daemon and delete the tree
#
# The tree lives at $WL_HARNESS (default /tmp/wl-ui-harness) so a second shell can drive it.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BASE="${WL_HARNESS:-/tmp/wl-ui-harness}"
WORLDLINE="${WORLDLINE_BIN:-$HOME/.local/bin/worldline}"
WORLDLINED="${WORLDLINED_BIN:-$HOME/.local/bin/worldlined}"
FIXTURE="$HERE/fixture_agent.py"
SLOW="$HERE/slow_agent.py"

harness_env() {
  export HOME="$BASE/home"
  export XDG_DATA_HOME="$BASE/data" XDG_STATE_HOME="$BASE/state"
  export XDG_CONFIG_HOME="$BASE/config" XDG_RUNTIME_DIR="$BASE/runtime"
  export PYTHONDONTWRITEBYTECODE=1
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"
}

payload() {
  local mode="${1:-multiverse}"
  printf '{"mode":"%s","harness":{"runtimeDir":"%s","home":"%s","dataHome":"%s","stateHome":"%s","configHome":"%s"}}' \
    "$mode" "$BASE/runtime" "$BASE/home" "$BASE/data" "$BASE/state" "$BASE/config"
}

case "${1:-}" in
  start)
    [[ -x $WORLDLINE && -x $WORLDLINED ]] || { echo "harness: engine not installed" >&2; exit 1; }
    [[ -d $BASE ]] && { echo "harness: $BASE exists; run 'stop' first" >&2; exit 1; }
    mkdir -p "$BASE"/{home,data,state,config/worldline,runtime,root}
    chmod 700 "$BASE/config/worldline"
    harness_env
    printf '{"schemaVersion":1,"readonlyHomePaths":["%s"],"agentCommands":{"fixture":{"argv":["/usr/bin/python3","%s","{workspace}"],"credentialMounts":[],"eventFormat":"jsonl"},"slow":{"argv":["/usr/bin/python3","%s","{workspace}"],"credentialMounts":[],"eventFormat":"jsonl"}},"ghosts":{"enabled":false,"agent":null}}\n' \
      "$HERE" "$FIXTURE" "$SLOW" > "$BASE/config/worldline/config.json"
    chmod 600 "$BASE/config/worldline/config.json"
    printf 'base line\n' > "$BASE/root/base.txt"
    printf 'second file\n' > "$BASE/root/notes.txt"
    printf '{"schemaVersion":1,"generated":[],"services":[],"checks":[{"id":"added-file","kind":"tests","argv":["/usr/bin/test","-f","fixture-added.txt"],"required":true,"format":"exit","covers":["*.txt"]},{"id":"optional-lint","kind":"build","argv":["/usr/bin/false"],"required":false,"format":"exit"}]}\n' > "$BASE/root/.worldline.json"
    nohup "$WORLDLINED" > "$BASE/daemon.log" 2>&1 &
    echo $! > "$BASE/daemon.pid"
    for _ in $(seq 1 100); do [[ -S $XDG_RUNTIME_DIR/worldline/worldlined.sock ]] && break; sleep 0.1; done
    "$WORLDLINE" init --yes "$BASE/root" > "$BASE/init.json" 2>&1 || { cat "$BASE/init.json"; exit 1; }
    "$WORLDLINE" fork candidate --mission-text 'harness: add a file and append to base' --wait -- fixture > "$BASE/fork.json" 2> "$BASE/fork.err" || { cat "$BASE/fork.err"; exit 1; }
    echo "harness ready at $BASE"
    echo "summon: omarchy-shell shell summon khephri.worldline '$(payload multiverse)'"
    ;;
  slow)
    harness_env
    "$WORLDLINE" fork "${2:-slowpoke}" --mission-text 'harness: sleep so it can be cancelled' --json -- slow
    ;;
  summon)
    omarchy-shell shell summon khephri.worldline "$(payload "${2:-multiverse}")"
    ;;
  payload)
    payload "${2:-multiverse}"
    ;;
  status)
    harness_env
    "$WORLDLINE" status --json
    ;;
  cli)
    harness_env
    shift
    "$WORLDLINE" "$@"
    ;;
  stop)
    if [[ -f $BASE/daemon.pid ]]; then
      kill "$(cat "$BASE/daemon.pid")" 2>/dev/null
      sleep 1
    fi
    harness_env
    for unit in $(systemctl --user list-units 'worldline-*' --all --plain --no-legend 2>/dev/null | awk '{print $1}'); do systemctl --user stop "$unit" 2>/dev/null; done
    if [[ -d $BASE ]]; then
      find "$BASE" -type d -name work -exec chmod u+rwx {} + 2>/dev/null
      chmod -R u+w "$BASE" 2>/dev/null
      rm -rf "$BASE"
    fi
    echo "harness stopped"
    ;;
  *)
    echo "usage: $0 start|summon [mode]|slow [alias]|status|cli …|stop" >&2
    exit 64
    ;;
esac
