#!/usr/bin/env node
// Behavioural control for install.sh's shell reload, runnable without Omarchy, Qt or a desktop:
//   node tools/test-install-reload.mjs              run the repository's install.sh
//   node tools/test-install-reload.mjs FILE         run another installer (used to prove it fails)
//
// The installer must restart the desktop shell OR ask it to rescan its plugins, never both. A
// rescan is still completing plugin objects when the restart kills the shell, and quickshell 0.3.1
// has already freed its IPC handler registry by then, so the shell segfaults instead of exiting
// (quickshell-mirror/quickshell#956).
//
// This RUNS the installer. There is no static reading of it. Each run gets:
//   * a throwaway source repository holding the installer;
//   * a scratch HOME;
//   * `env -i`;
//   * a PATH of basic tools plus recording shims for omarchy-restart-shell and omarchy-shell.
// Nothing on the host's PATH is reachable, so the real desktop shell can never be touched.
// Every combination is run: WORLDLINE_NO_SHELL_RESTART 0/1, the restart command absent, succeeding,
// refusing before any kill, or failing after restarting (lock not re-secured), and omarchy-shell
// absent or present. Each run is checked for the calls it made, its exit status and what it said.
// Non-claim: this covers the environments enumerated here. It says nothing about an installer
// that behaves differently in an environment it does not enumerate.
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = join(dirname(fileURLToPath(import.meta.url)), "..");
const installer = process.argv[2] ?? join(repo, "install.sh");
const TOOLS = ["bash", "sh", "env", "git", "python3", "sleep", "mkdir", "dirname", "basename", "cat", "rm", "sed", "grep", "date", "cp", "mv", "ls", "tr", "head", "tail", "cut", "wc", "sort", "uname"];

const base = mkdtempSync(join(tmpdir(), "worldline-install-reload-"));
const failures = [];
const sh = (cmd, cwd) => spawnSync("bash", ["-c", cmd], { cwd, encoding: "utf8" });
try {
  // The source repository the installer clones from is the directory it lives in.
  const src = join(base, "src");
  mkdirSync(src);
  copyFileSync(installer, join(src, "install.sh"));
  chmodSync(join(src, "install.sh"), 0o755);
  writeFileSync(join(src, "README.md"), "fixture\n");
  const init = sh("git init -q && git symbolic-ref HEAD refs/heads/main && git add -A && "
    + "git -c user.email=t@t -c user.name=t commit -q -m fixture", src);
  if (init.status !== 0) throw new Error(`fixture repository: ${init.stderr}`);

  const bin = join(base, "bin");
  mkdirSync(bin);
  for (const tool of TOOLS) {
    const found = sh(`command -v ${tool}`).stdout.trim();
    if (found.startsWith("/")) symlinkSync(found, join(bin, tool));
  }

  const RESTART = {
    absent: null,
    ok: { rc: 0, message: "" },
    refused: { rc: 1, message: "Refusing to restart Omarchy shell while the session is locked." },
    relock: { rc: 1, message: "Omarchy shell restarted, but the session lock was not re-secured." },
  };
  let run = 0;
  for (const nsr of ["0", "1"]) {
    for (const [restartKind, restart] of Object.entries(RESTART)) {
      for (const shellPresent of [false, true]) {
        run += 1;
        const name = `NSR=${nsr} restart=${restartKind} omarchy-shell=${shellPresent ? "present" : "absent"}`;
        const home = join(base, `home-${run}`);
        const path = join(base, `path-${run}`);
        const calls = join(base, `calls-${run}.log`);
        mkdirSync(join(home, ".config/omarchy/plugins"), { recursive: true });
        mkdirSync(join(home, ".config/hypr"), { recursive: true });
        writeFileSync(join(home, ".config/omarchy/shell.json"), '{"bar": {"layout": {"right": []}}}\n');
        writeFileSync(join(home, ".config/hypr/bindings.lua"), "-- bindings\n");
        mkdirSync(path);
        writeFileSync(calls, "");
        if (restart) {
          writeFileSync(join(path, "omarchy-restart-shell"),
            `#!/bin/sh\necho "omarchy-restart-shell $*" >> "${calls}"\n`
            + (restart.message ? `echo "${restart.message}" >&2\n` : "") + `exit ${restart.rc}\n`);
          chmodSync(join(path, "omarchy-restart-shell"), 0o755);
        }
        if (shellPresent) {
          writeFileSync(join(path, "omarchy-shell"), `#!/bin/sh\necho "omarchy-shell $*" >> "${calls}"\nexit 0\n`);
          chmodSync(join(path, "omarchy-shell"), 0o755);
        }
        const result = spawnSync("env", ["-i", `HOME=${home}`, `PATH=${path}:${bin}`, `WORLDLINE_NO_SHELL_RESTART=${nsr}`,
          "bash", join(src, "install.sh")], { encoding: "utf8", timeout: 60000 });
        const output = `${result.stdout}${result.stderr}`;
        const log = readFileSync(calls, "utf8").split("\n").filter(Boolean);
        const restarts = log.filter((line) => line.startsWith("omarchy-restart-shell"));
        const rescans = log.filter((line) => line.includes("rescanPlugins"));
        const problems = [];

        if (restarts.length > 0 && rescans.length > 0) problems.push(`both a restart and a rescan: ${log.join(" | ")}`);
        const restartExpected = nsr === "0" && restart !== null;
        if (restartExpected) {
          if (restarts.length !== 1) problems.push(`expected exactly one restart, saw ${restarts.length}`);
          if (restart.rc === 0) {
            if (result.status !== 0) problems.push(`a successful restart must exit 0, got ${result.status}`);
            if (!output.includes("shell restarted")) problems.push("a successful restart must say so");
          } else {
            if (result.status !== 4) problems.push(`a failed restart must exit 4, got ${result.status}`);
            if (!output.includes(`exited ${restart.rc}`)) problems.push("a failed restart must print its exit code");
            if (!output.includes(restart.message)) problems.push("the restart's own message must reach the operator");
            if (output.includes("shell restarted\n")) problems.push("a failed restart must not be reported as a success");
          }
        } else {
          if (restarts.length !== 0) problems.push("no restart may run when it is disabled or absent");
          if (result.status !== 0) problems.push(`expected exit 0, got ${result.status}`);
          if (shellPresent) {
            if (rescans.length !== 1) problems.push(`expected exactly one rescan, saw ${rescans.length}`);
            if (!output.includes("kept loaded")) problems.push("a rescan-only reload must say the service keeps the previous code");
          } else {
            if (rescans.length !== 0) problems.push("no rescan without omarchy-shell");
            const reason = nsr === "1" ? "WORLDLINE_NO_SHELL_RESTART=1" : "neither omarchy-restart-shell nor omarchy-shell";
            if (!output.includes(reason)) problems.push(`the not-reloaded message must name the reason (${reason})`);
          }
        }
        if (!existsSync(join(home, ".config/omarchy/plugins/khephri.worldline/.git"))) problems.push("the plugin checkout was not created");

        if (problems.length > 0) {
          failures.push(name);
          console.error(`FAIL ${name}\n  - ${problems.join("\n  - ")}\n  output:\n${output.replace(/^/gm, "    ")}`);
        } else {
          console.log(`ok   ${name}`);
        }
      }
    }
  }
} finally {
  rmSync(base, { recursive: true, force: true });
}
if (failures.length > 0) {
  console.error(`test-install-reload: ${failures.length} environment(s) failed`);
  process.exit(1);
}
console.log("test-install-reload: every environment restarted or rescanned, never both, and reported what it did");
