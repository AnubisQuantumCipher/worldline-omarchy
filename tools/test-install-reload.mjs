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
// This RUNS the installer; there is no static reading of it.
// Fixture:
//   * a throwaway repository built from `git archive HEAD` of this repository, with the installer
//     under test in place of install.sh;
//   * a scratch HOME;
//   * `env -i`, with dummy session variables (WAYLAND_DISPLAY, XDG_RUNTIME_DIR,
//     HYPRLAND_INSTANCE_SIGNATURE, OMARCHY_PATH) that point at scratch paths; they are not a
//     real session;
//   * a PATH made of recording shims for omarchy-restart-shell, omarchy-shell and
//     omarchy-plugin-validate, shims that record any call as unexpected for qs, quickshell,
//     hyprctl and the other omarchy commands that can reload plugins (omarchy, omarchy-plugin-*,
//     omarchy-shell-config, omarchy-launch-shell), and symlinks to basic tools. The host's omarchy
//     tools are not on that PATH.
// Each environment is run twice: a first install (clone), then, after a new commit, an upgrade
// (fast-forward). The environments are WORLDLINE_NO_SHELL_RESTART 0/1, times the restart command
// absent, succeeding, refusing before any kill (exit 1), failing after restarting with the lock
// not re-secured (exit 1), or a not-ready stand-in that exits 7 (the real command exits 1 there;
// 7 makes the printed code testable), times omarchy-shell absent or present.
// Each run is checked for the shim calls it made, its exit status and what it said. A restart
// environment may make no omarchy-shell call at all; a rescan environment makes exactly one, the
// rescan. The upgrade must really move the checkout to the fixture's new commit.
//
// What this observes, and what it does not:
//   * It observes calls through PATH to the shims, made before the installer exits or within one
//     second after.
//   * It does not observe a call by absolute path, a command after the installer reassigns PATH,
//     a process that outlives that second, or a real session's sockets.
//   * It does not check the pause before the restart.
//   * It covers only the environments listed above.
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync, existsSync, copyFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = join(dirname(fileURLToPath(import.meta.url)), "..");
const installer = process.argv[2] ?? join(repo, "install.sh");
const TOOLS = ["bash", "sh", "env", "git", "python3", "sleep", "mkdir", "dirname", "basename", "cat", "rm", "sed", "grep", "date", "cp", "mv", "ls", "tr", "head", "tail", "cut", "wc", "sort", "uname", "tar"];
const UNEXPECTED = ["qs", "quickshell", "hyprctl", "omarchy", "omarchy-plugin-update", "omarchy-plugin-add",
  "omarchy-plugin-enable", "omarchy-plugin-disable", "omarchy-plugin-clone", "omarchy-plugin-remove",
  "omarchy-shell-config", "omarchy-launch-shell"];

const base = mkdtempSync(join(tmpdir(), "worldline-install-reload-"));
const failures = [];
const sh = (cmd, cwd) => spawnSync("bash", ["-c", cmd], { cwd, encoding: "utf8" });
const settle = () => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1000);
try {
  const bin = join(base, "bin");
  mkdirSync(bin);
  for (const tool of TOOLS) {
    const found = sh(`command -v ${tool}`).stdout.trim();
    if (found.startsWith("/")) symlinkSync(found, join(bin, tool));
  }

  const RESTART = {
    absent: null,
    ok: { rc: 0, message: "", says: "shell restarted" },
    refused: { rc: 1, message: "Refusing to restart Omarchy shell while the session is locked.", says: "was not restarted" },
    relock: { rc: 1, message: "Omarchy shell restarted, but the session lock was not re-secured.", says: "lock the session now" },
    notready: { rc: 7, message: "Omarchy shell did not become ready after restart.", says: "may be down" },
  };
  let run = 0;
  for (const nsr of ["0", "1"]) {
    for (const [restartKind, restart] of Object.entries(RESTART)) {
      for (const shellPresent of [false, true]) {
        run += 1;
        const name = `NSR=${nsr} restart=${restartKind} omarchy-shell=${shellPresent ? "present" : "absent"}`;
        // The source repository the installer clones from is the directory it lives in.
        const src = join(base, `src-${run}`);
        mkdirSync(src);
        const archive = sh(`git -C '${repo}' archive HEAD | tar -x -C '${src}'`);
        if (archive.status !== 0) throw new Error(`git archive: ${archive.stderr}`);
        copyFileSync(installer, join(src, "install.sh"));
        chmodSync(join(src, "install.sh"), 0o755);
        const init = sh("git init -q && git symbolic-ref HEAD refs/heads/main && git add -A && "
          + "git -c user.email=t@t -c user.name=t commit -q -m fixture", src);
        if (init.status !== 0) throw new Error(`fixture repository: ${init.stderr}`);

        const home = join(base, `home-${run}`);
        const runtime = join(base, `runtime-${run}`);
        const path = join(base, `path-${run}`);
        const calls = join(base, `calls-${run}.log`);
        mkdirSync(join(home, ".config/omarchy/plugins"), { recursive: true });
        mkdirSync(join(home, ".config/hypr"), { recursive: true });
        mkdirSync(runtime, { recursive: true });
        writeFileSync(join(home, ".config/omarchy/shell.json"), '{"bar": {"layout": {"right": []}}}\n');
        writeFileSync(join(home, ".config/hypr/bindings.lua"), "-- bindings\n");
        mkdirSync(path);
        const shim = (tool, body) => { writeFileSync(join(path, tool), `#!/bin/sh\n${body}`); chmodSync(join(path, tool), 0o755); };
        if (restart) {
          shim("omarchy-restart-shell", `echo "omarchy-restart-shell $*" >> "${calls}"\n`
            + (restart.message ? `echo "${restart.message}" >&2\n` : "") + `exit ${restart.rc}\n`);
        }
        if (shellPresent) shim("omarchy-shell", `echo "omarchy-shell $*" >> "${calls}"\nexit 0\n`);
        shim("omarchy-plugin-validate", "exit 0\n");
        for (const tool of UNEXPECTED) shim(tool, `echo "UNEXPECTED ${tool} $*" >> "${calls}"\nexit 0\n`);

        const env = ["-i", `HOME=${home}`, `PATH=${path}:${bin}`, `WORLDLINE_NO_SHELL_RESTART=${nsr}`,
          `XDG_RUNTIME_DIR=${runtime}`, "WAYLAND_DISPLAY=wayland-test", "HYPRLAND_INSTANCE_SIGNATURE=test",
          `OMARCHY_PATH=${join(runtime, "omarchy")}`];
        const problems = [];
        for (const phase of ["install", "upgrade"]) {
          if (phase === "upgrade") {
            writeFileSync(join(src, "WORLDLINE-FIXTURE-UPGRADE"), "second commit\n");
            const upgrade = sh("git add WORLDLINE-FIXTURE-UPGRADE && git -c user.email=t@t -c user.name=t commit -q -m upgrade", src);
            if (upgrade.status !== 0) throw new Error(`fixture upgrade commit: ${upgrade.stderr}`);
          }
          writeFileSync(calls, "");
          const result = spawnSync("env", [...env, "bash", join(src, "install.sh")], { encoding: "utf8", timeout: 60000 });
          settle();
          const output = `${result.stdout}${result.stderr}`;
          const log = readFileSync(calls, "utf8").split("\n").filter(Boolean);
          const restarts = log.filter((line) => line.startsWith("omarchy-restart-shell"));
          const shellCalls = log.filter((line) => line.startsWith("omarchy-shell"));
          const rescans = log.filter((line) => line.includes("rescanPlugins"));
          const unexpected = log.filter((line) => line.startsWith("UNEXPECTED"));
          const say = (text) => problems.push(`${phase}: ${text}`);

          if (restarts.length > 0 && rescans.length > 0) say(`both a restart and a rescan: ${log.join(" | ")}`);
          if (unexpected.length > 0) say(`unexpected calls: ${unexpected.join(" | ")}`);
          if (phase === "install" && !output.includes("cloned")) say("the first run must clone");
          if (phase === "upgrade" && !output.includes("fast-forwarded")) say("the second run must fast-forward");
          const deployed = sh(`git -C '${join(home, ".config/omarchy/plugins/khephri.worldline")}' rev-parse HEAD`).stdout.trim();
          const fixture = sh("git rev-parse HEAD", src).stdout.trim();
          if (deployed !== fixture) say(`the checkout is at ${deployed.slice(0, 12)}, not the fixture's ${fixture.slice(0, 12)}`);
          const restartExpected = nsr === "0" && restart !== null;
          if (restartExpected) {
            if (restarts.length !== 1) say(`expected exactly one restart, saw ${restarts.length}`);
            if (shellCalls.length !== 0) say(`a restart environment may make no omarchy-shell call: ${shellCalls.join(" | ")}`);
            if (!output.includes(restart.says)) say(`must say "${restart.says}"`);
            if (restart.rc === 0) {
              if (result.status !== 0) say(`a successful restart must exit 0, got ${result.status}`);
            } else {
              if (result.status !== 4) say(`a failed restart must exit 4, got ${result.status}`);
              if (!output.includes(`exited ${restart.rc}`)) say(`a failed restart must print its exit code ${restart.rc}`);
              if (!output.includes(restart.message)) say("the restart's own message must reach the operator");
              if (!output.includes("but the shell restart reported failure.")) say("the last line must say the restart reported failure");
              if (/^\s*shell restarted\b/m.test(output)) say("a failed restart must not be reported as a success");
            }
          } else {
            if (restarts.length !== 0) say("no restart may run when it is disabled or absent");
            if (result.status !== 0) say(`expected exit 0, got ${result.status}`);
            if (shellPresent) {
              if (rescans.length !== 1) say(`expected exactly one rescan, saw ${rescans.length}`);
              if (shellCalls.length !== 1 || shellCalls[0] !== "omarchy-shell -q shell rescanPlugins") say(`a rescan environment makes exactly one omarchy-shell call, the rescan: ${shellCalls.join(" | ")}`);
              if (restart === null && output.includes("Run omarchy-restart-shell")) say("must not advise running an omarchy-restart-shell that is not there");
              if (!output.includes("kept loaded")) say("a rescan-only reload must say a kept service keeps the previous code");
            } else {
              if (rescans.length !== 0) say("no rescan without omarchy-shell");
              const reason = nsr === "1" ? "WORLDLINE_NO_SHELL_RESTART=1" : "neither omarchy-restart-shell nor omarchy-shell";
              if (!output.includes(reason)) say(`the not-reloaded message must name the reason (${reason})`);
            }
          }
          if (!existsSync(join(home, ".config/omarchy/plugins/khephri.worldline/.git"))) say("the plugin checkout is missing");
          if (problems.length > 0 && phase === "install") problems.push(`  output:\n${output.replace(/^/gm, "    ")}`);
        }
        if (problems.length > 0) {
          failures.push(name);
          console.error(`FAIL ${name}\n  - ${problems.join("\n  - ")}`);
        } else {
          console.log(`ok   ${name} (install, then upgrade)`);
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
console.log("test-install-reload: in every environment, on install and on upgrade, the installer restarted or rescanned through PATH, never both, and reported what it did");
