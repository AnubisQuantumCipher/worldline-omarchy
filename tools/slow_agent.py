#!/usr/bin/env python3
"""Fixture adapter that writes one file and then sleeps, so `worldline cancel` has something to stop."""
import json
import sys
import time
from pathlib import Path

workspace = Path(sys.argv[1])
(workspace / "partial.txt").write_text("partial work\n", encoding="utf-8")
print(json.dumps({"type": "tool-event", "tool": "write", "path": str(workspace / "partial.txt"), "line": 1, "reason": "partial work before cancel"}), flush=True)
time.sleep(600)
