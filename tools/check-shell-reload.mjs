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
// Rule, over the script's non-comment lines:
//   1. Some `if` line gates `omarchy-restart-shell`, and a later line runs it.
//   2. Every line that runs `rescanPlugins` sits in an `elif` or `else` branch of that same `if`,
//      so the two are exclusive. A rescan anywhere else is refused.
//
// The check fails closed: a script with no restart at all is refused rather than reported clean.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const file = process.argv[2] ?? join(root, "install.sh");
const lines = readFileSync(file, "utf8").split("\n").map((text, index) => ({ text: text.trim(), number: index + 1 }))
  .filter((line) => line.text !== "" && !line.text.startsWith("#"));

const problems = [];
const control = (line) => /^(if|elif|else|fi)\b/.exec(line.text)?.[1];

const gate = lines.findIndex((line) => control(line) === "if" && line.text.includes("omarchy-restart-shell"));
if (gate < 0) {
  problems.push("no `if` gates omarchy-restart-shell: the check has nothing to hold the rescan against");
} else if (!lines.slice(gate + 1).some((line) => control(line) === undefined && line.text.includes("omarchy-restart-shell"))) {
  problems.push(`line ${lines[gate].number}: the restart gate never runs omarchy-restart-shell`);
}

for (let index = 0; index < lines.length; index += 1) {
  if (!lines[index].text.includes("rescanPlugins")) continue;
  // Walk back to the branch this line is in, skipping nested if..fi blocks.
  let depth = 0;
  let branch = -1;
  for (let back = index - 1; back >= 0; back -= 1) {
    const keyword = control(lines[back]);
    if (keyword === "fi") depth += 1;
    else if (keyword === "if" && depth > 0) depth -= 1;
    else if (depth === 0 && keyword !== undefined) { branch = back; break; }
  }
  let owner = branch;
  if (branch >= 0 && control(lines[branch]) !== "if") {
    // The branch is an elif/else: find the `if` it belongs to.
    depth = 0;
    owner = -1;
    for (let back = branch - 1; back >= 0; back -= 1) {
      const keyword = control(lines[back]);
      if (keyword === "fi") depth += 1;
      else if (keyword === "if") { if (depth === 0) { owner = back; break; } depth -= 1; }
    }
  }
  const exclusive = branch >= 0 && control(lines[branch]) !== "if" && owner === gate && gate >= 0;
  if (!exclusive) {
    problems.push(`line ${lines[index].number}: rescanPlugins is not in an elif/else branch of the restart gate, so it can run before the restart`);
  }
}

if (problems.length > 0) {
  for (const problem of problems) console.error(`check-shell-reload: ${file}: ${problem}`);
  process.exit(1);
}
console.log(`check-shell-reload: ${file}: the shell is restarted or rescanned, never both`);
