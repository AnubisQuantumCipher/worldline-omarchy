#!/usr/bin/env node
// Controls for tools/check-shell-reload.mjs: installers it must refuse and installers it must pass.
// The refused shapes are the review's counterexamples (each one runs rescanPlugins and then
// omarchy-restart-shell, or cannot be followed); the passed shapes never run both.
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const check = join(dirname(fileURLToPath(import.meta.url)), "check-shell-reload.mjs");
const GATE = 'if [[ "${WORLDLINE_NO_SHELL_RESTART:-0}" != "1" ]] && command -v omarchy-restart-shell >/dev/null 2>&1; then';
const RESCAN = "  omarchy-shell -q shell rescanPlugins || true";

const refuse = {
  "1.3.3 shape: rescan, then the gate": ["omarchy-shell -q shell rescanPlugins || true", GATE, "  omarchy-restart-shell || true", "fi"],
  "rescan in the restart's own branch": [GATE, RESCAN, "  omarchy-restart-shell || true", "fi"],
  "rescan after the gate": [GATE, "  omarchy-restart-shell || true", "fi", RESCAN.trim()],
  "restart after the gate, rescan in its else": [GATE, '  echo "restart"', "else", RESCAN, "fi", "omarchy-restart-shell || true"],
  "a heredoc line spelling else: does not open a branch": [GATE, "  python3 - <<'PY'", "try:", "    pass", "except Exception:", "    pass", "else:", "    pass", "PY", RESCAN, "  omarchy-restart-shell || true", "fi"],
  "a continuation line does not hide the rescan": ["omarchy-shell -q shell rescan\\", "Plugins || true", GATE, "  omarchy-restart-shell || true", "fi"],
  "an echo is not a restart": [GATE, '  echo "run omarchy-restart-shell yourself"', "else", RESCAN, "fi"],
  "the gate's condition restarts and a branch rescans": ["if omarchy-restart-shell >/dev/null 2>&1; then", '  echo ok', "else", RESCAN, "fi"],
  "a gate inside a loop": ["for attempt in 1 2; do", GATE, "  omarchy-restart-shell || true", "else", RESCAN, "fi", "done"],
  "a function the check cannot follow": ["reload() {", "  omarchy-shell -q shell rescanPlugins", "}", GATE, "  reload", "  omarchy-restart-shell || true", "fi"],
  "no gate at all": ["echo hello"],
};

const pass = {
  "1.3.4 shape: restart, or rescan in the elif": [GATE, "  sleep 2", "  if omarchy-restart-shell >/dev/null 2>&1; then", '    echo "  shell restarted"', "  else", "    rc=$?", '    echo "  FAILED ($rc); run omarchy-restart-shell" >&2', "  fi", "elif command -v omarchy-shell >/dev/null 2>&1; then", RESCAN, "fi"],
  "a nested if inside the rescan branch": [GATE, "  omarchy-restart-shell || true", "elif command -v omarchy-shell >/dev/null 2>&1; then", '  if [[ -d "$DEST" ]]; then', "    omarchy-shell -q shell rescanPlugins || true", "  fi", "fi"],
  "a one-line if before the rescan": [GATE, "  omarchy-restart-shell || true", "elif command -v omarchy-shell >/dev/null 2>&1; then", '  if [[ -n "${QUIET:-}" ]]; then echo quiet; fi', RESCAN, "fi"],
  "an inverted gate": ['if [[ "${WORLDLINE_NO_SHELL_RESTART:-0}" == "1" ]] || ! command -v omarchy-restart-shell >/dev/null 2>&1; then', RESCAN, "else", "  omarchy-restart-shell || true", "fi"],
};

const dir = mkdtempSync(join(tmpdir(), "check-shell-reload-"));
let failures = 0;
const run = (name, body, expected) => {
  const file = join(dir, "install.sh");
  writeFileSync(file, ["#!/usr/bin/env bash", "set -euo pipefail", ...body, ""].join("\n"));
  const result = spawnSync(process.execPath, [check, file], { encoding: "utf8" });
  const ok = expected === "refuse" ? result.status === 1 : result.status === 0;
  if (!ok) {
    failures += 1;
    console.error(`FAIL ${expected} "${name}": exit ${result.status}\n${result.stdout}${result.stderr}`);
  } else {
    console.log(`ok   ${expected} "${name}"`);
  }
};
try {
  for (const [name, body] of Object.entries(refuse)) run(name, body, "refuse");
  for (const [name, body] of Object.entries(pass)) run(name, body, "pass");
} finally {
  rmSync(dir, { recursive: true, force: true });
}
if (failures > 0) process.exit(1);
console.log(`test-check-shell-reload: ${Object.keys(refuse).length} refused, ${Object.keys(pass).length} passed, as expected`);
