#!/usr/bin/env node
// Shell-reload check for install.sh, runnable without a shell or Qt:
//   node tools/check-shell-reload.mjs              check the repository's install.sh
//   node tools/check-shell-reload.mjs FILE         check another script (used to prove it fails)
//
// The installer must restart the desktop shell OR ask it to rescan its plugins, never both. A
// rescan is still completing plugin objects when the restart kills the shell, and quickshell 0.3.1
// has already freed its IPC handler registry by then, so the shell segfaults instead of exiting
// (quickshell-mirror/quickshell#956). A restart re-reads every plugin on its own.
//
// The script is read as shell structure, not as text:
//   * `\` continuations are joined and heredoc bodies are skipped, so neither can hide a line
//     or fake a keyword;
//   * the `if`/`elif`/`else`/`fi` blocks are parsed into branches, one-line `if ...; fi` included;
//   * the GATE is the first `if` whose condition names `omarchy-restart-shell`.
// Rules:
//   1. Every invocation of `omarchy-restart-shell` sits in ONE branch of the gate (any depth),
//      and there is at least one. `command -v`/`type`/`which` probes and quoted text are not
//      invocations.
//   2. Every mention of `rescanPlugins`, quoted or not, sits in a DIFFERENT branch of the gate.
//   3. What this reading cannot follow is refused rather than trusted: shell functions, `eval`,
//      `source`/`.`, `sh -c`/`bash -c`, and a gate inside a loop (whose branches could both run).
// Fails closed: a script with no gate, or no restart in it, is refused rather than reported clean.
// Non-claim: this reads install.sh's own text; it does not run it or follow the commands it calls.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const file = process.argv[2] ?? join(root, "install.sh");
const problems = [];

// 1. Logical lines: continuations joined, heredoc bodies dropped, comment lines dropped.
const raw = readFileSync(file, "utf8").split("\n");
const lines = [];
for (let i = 0; i < raw.length; i += 1) {
  const number = i + 1;
  let text = raw[i];
  while (/\\$/.test(text) && i + 1 < raw.length) { i += 1; text = text.slice(0, -1) + raw[i]; }
  const trimmed = text.trim();
  if (trimmed === "" || trimmed.startsWith("#")) continue;
  lines.push({ number, text: trimmed });
  const heredoc = /<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1/.exec(trimmed);
  if (heredoc) {
    const end = heredoc[2];
    while (i + 1 < raw.length && raw[i + 1].trim() !== end) i += 1;
    i += 1;  // the terminator line
  }
}

// Quoted text and trailing comments removed, for deciding what a line RUNS.
const unquoted = (text) => text.replace(/'[^']*'/g, "''").replace(/"(?:[^"\\]|\\.)*"/g, '""').replace(/\s#.*$/, "");
const runsRestart = (text) => /(^|[^\w.-])omarchy-restart-shell(?![\w.-])/.test(
  unquoted(text).replace(/\b(command\s+-v|type|which|hash)\s+omarchy-restart-shell\b/g, ""));
const mentionsRescan = (text) => text.includes("rescanPlugins");

// 2. Block structure.
const stack = [];   // frames: { gate: bool, branch }
let loops = 0;
let gate = null;    // { number, restartInCondition, restartBranches: Set, rescanBranches: [] }
const gateBranch = () => {
  const frame = stack.find((entry) => entry.gate);
  return frame ? frame.branch : null;
};
for (const line of lines) {
  const code = unquoted(line.text);
  if (/^(function\s+\w|[A-Za-z_][\w-]*\s*\(\)\s*(\{|$))/.test(code)) problems.push(`line ${line.number}: a shell function cannot be followed by this check`);
  if (/(^|[;&|]\s*|\s)(eval|source)\s/.test(code) || /(^|[;&|]\s*)\.\s+\S/.test(code)) problems.push(`line ${line.number}: eval/source cannot be followed by this check`);
  if (/\b(ba)?sh\s+-c\b/.test(code)) problems.push(`line ${line.number}: sh -c cannot be followed by this check`);

  const keyword = /^(if|elif|else|fi|for|while|until|done)\b/.exec(code)?.[1];
  const oneLineIf = keyword === "if" && /(^|;|\s)fi\s*(;|$)/.test(code);
  const opensIf = keyword === "if" && !oneLineIf;
  if (opensIf && gate === null && /omarchy-restart-shell/.test(code)) {
    // The gate. A restart run by its condition precedes every branch, so it conflicts with a
    // rescan anywhere in the gate.
    if (loops > 0) problems.push(`line ${line.number}: the restart gate is inside a loop, so both of its branches could run`);
    if (mentionsRescan(line.text)) problems.push(`line ${line.number}: rescanPlugins in the restart gate's condition`);
    gate = { number: line.number, restartInCondition: runsRestart(line.text), restartBranches: new Set(), rescanBranches: [] };
    stack.push({ gate: true, branch: 0 });
    continue;
  }
  // Any other line (an opening `if` included: its condition runs in the enclosing context).
  const branch = gateBranch();
  if (runsRestart(line.text)) {
    if (branch === null) problems.push(`line ${line.number}: omarchy-restart-shell runs outside the restart gate`);
    else gate.restartBranches.add(branch);
  }
  if (mentionsRescan(line.text)) {
    if (branch === null) problems.push(`line ${line.number}: rescanPlugins is outside the restart gate, so it can run before a restart`);
    else gate.rescanBranches.push({ branch, number: line.number });
  }
  if (opensIf) {
    stack.push({ gate: false, branch: 0 });
  } else if (keyword === "elif" || keyword === "else") {
    if (stack.length === 0) problems.push(`line ${line.number}: ${keyword} without an if`);
    else stack[stack.length - 1].branch += 1;
  } else if (keyword === "fi") {
    if (stack.length === 0) problems.push(`line ${line.number}: fi without an if`);
    else stack.pop();
  } else if (keyword === "for" || keyword === "while" || keyword === "until") {
    if (!/(^|;|\s)done\s*(;|$)/.test(code)) loops += 1;
  } else if (keyword === "done") {
    loops = Math.max(0, loops - 1);
  }
}
if (stack.length > 0) problems.push("an if block is never closed");

// 3. The rules.
if (gate === null) {
  problems.push("no `if` gates omarchy-restart-shell: the check has nothing to hold the rescan against");
} else {
  if (gate.restartBranches.size === 0 && !gate.restartInCondition) problems.push(`line ${gate.number}: the restart gate never runs omarchy-restart-shell`);
  if (gate.restartInCondition && gate.rescanBranches.length > 0) problems.push(`line ${gate.number}: the gate's condition restarts the shell and a branch rescans`);
  if (gate.restartBranches.size > 1) problems.push(`line ${gate.number}: omarchy-restart-shell runs in more than one branch of the gate`);
  const [restartBranch] = [...gate.restartBranches];
  for (const rescan of gate.rescanBranches) {
    if (rescan.branch === restartBranch) problems.push(`line ${rescan.number}: rescanPlugins shares a branch with the restart`);
  }
}

if (problems.length > 0) {
  for (const problem of problems) console.error(`check-shell-reload: ${file}: ${problem}`);
  process.exit(1);
}
console.log(`check-shell-reload: ${file}: the shell is restarted or rescanned, never both`);
