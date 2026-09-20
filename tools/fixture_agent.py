#!/usr/bin/env python3
"""Deterministic WORLDLINE agent adapter for testing. Calls no model, spends no quota.

Registered as a generic adapter, e.g.:

    "agentCommands": {
      "fixture": {
        "argv": ["/usr/bin/python3",
                 "/home/sicarii/.claude/skills/worldline/scripts/fixture_agent.py",
                 "{workspace}"],
        "credentialMounts": [],
        "eventFormat": "jsonl"
      }
    }

Inside a world it writes one new file and appends to an existing one, then emits JSONL tool
events on stdout so the causal chain has something real to attribute. It runs entirely inside
the world's overlay, so on the host nothing changes until an authorized collapse.

The escape probe is deliberate: it attempts one write outside the managed roots and reports
whether the sandbox refused it. A successful write there would mean isolation is broken, which
is exactly what a health check should be able to state as an observation rather than an
assumption.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import sys


def emit(event: dict[str, object]) -> None:
    print(json.dumps(event, sort_keys=True), flush=True)


def main() -> int:
    if len(sys.argv) < 2:
        print("fixture_agent: expected the workspace path as argv[1]", file=sys.stderr)
        return 64
    workspace = Path(sys.argv[1])
    mission = sys.stdin.read() if not sys.stdin.isatty() else ""

    emit({"type": "mission", "workspace": str(workspace), "missionBytes": len(mission)})

    added = workspace / "fixture-added.txt"
    added.write_text("added by fixture agent\n", encoding="utf-8")
    emit({"type": "tool-event", "tool": "write", "path": str(added), "line": 1,
          "reason": "create a deterministic added file"})

    for existing in sorted(workspace.glob("*.txt")):
        if existing == added:
            continue
        with existing.open("a", encoding="utf-8") as handle:
            handle.write("modified by fixture agent\n")
        emit({"type": "tool-event", "tool": "append", "path": str(existing),
              "line": len(existing.read_text(encoding="utf-8").splitlines()),
              "reason": "prove a modify operation reaches the delta"})
        break

    # Write outside the managed roots. Inside a world this lands on the world's own tmpfs home,
    # so the agent cannot tell whether it escaped -- only the host can. The caller asserts the
    # host copy is absent; this event just records what the agent observed.
    probe = Path(os.environ.get("HOME", "/root")) / "fixture-escape-probe.txt"
    try:
        probe.write_text("escaped\n", encoding="utf-8")
        accepted = probe.exists()
    except OSError:
        accepted = False
    emit({"type": "isolation-probe", "path": str(probe), "writeAcceptedInsideWorld": accepted})

    emit({"type": "result", "status": "ok"})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
