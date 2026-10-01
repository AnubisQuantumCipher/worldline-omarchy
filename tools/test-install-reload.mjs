#!/usr/bin/env node
// Behavioural control for install.sh's shell reload, runnable without Omarchy, Qt or a desktop:
//   node tools/test-install-reload.mjs              run the repository's install.sh
//   node tools/test-install-reload.mjs FILE         run another installer (a mutant, an older release)
//   node tools/test-install-reload.mjs FILE --json  also print a JSON summary as the last line
//
// The installer must restart the desktop shell OR ask it to rescan its plugins, never both, by
// any route. A rescan is still completing plugin objects when the restart kills the shell, and
// quickshell 0.3.1 has already freed its IPC handler registry by then, so the shell segfaults
// instead of exiting (quickshell-mirror/quickshell#956).
//
// This RUNS the installer and observes every program it executes (1.3.5): tools/exec-trace.py
// follows the whole process tree by ptrace through every fork and execve, whatever path a program
// is named by, whatever PATH the installer sets, and waits for every descendant, including one
// the installer left running in the background after it exited.
//
// Fixture, per environment:
//   * a throwaway repository built from `git archive HEAD` of this repository, with the installer
//     under test in place of install.sh, a scratch HOME, and `env -i` with dummy session variables
//     (WAYLAND_DISPLAY, XDG_RUNTIME_DIR, HYPRLAND_INSTANCE_SIGNATURE, OMARCHY_PATH) that point at
//     scratch paths; they are not a real session;
//   * a PATH of: stand-ins for omarchy-restart-shell and omarchy-shell (present or absent per
//     environment) and a silent omarchy-plugin-validate; stand-ins for every other command in
//     tools/omarchy-commands.txt and for qs, quickshell, hyprctl, systemctl, pkill, killall,
//     loginctl and notify-send; and links to basic tools. The same stand-ins are also placed at
//     $OMARCHY_PATH/bin and ~/.local/share/omarchy/bin, where Omarchy keeps its commands, so a
//     call by those absolute paths runs a stand-in and is observed. The host's omarchy tools are
//     not on the PATH;
//   * exec-trace's allowlist: the basic tools, git's helpers and the fixture. Any other program
//     the installer executes (the host's /usr/share/omarchy/bin/omarchy-shell by absolute path, a
//     host pkill) is recorded and killed before it runs, so the check never reaches the operator's
//     desktop, and the run fails.
// Environments: WORLDLINE_NO_SHELL_RESTART 0/1, times the restart command absent, succeeding,
// refusing before any kill (exit 1), failing after restarting with the lock not re-secured
// (exit 1), or a not-ready stand-in that exits 7, times omarchy-shell absent or present. Each is
// run twice: a first install (clone), then, after a new commit, an upgrade (fast-forward).
//
// Each run is checked for:
//   * never both a restart and a rescan, by any route (a restart: omarchy-restart-shell,
//     omarchy-refresh-shell, omarchy-launch-shell, omarchy-update-restart, a qs/quickshell launch,
//     pkill/killall, systemctl restart/stop/kill, hyprctl dispatch; a rescan: any program run with
//     a rescanPlugins argument);
//   * no program outside the fixture, and no shell-facing command but the one reload;
//   * a restart environment: exactly one restart, by the fixture's omarchy-restart-shell, no
//     omarchy-shell call at all, and at least 1.9 s between the checkout's update and the
//     restart (the pause that lets the shell's own rescan settle); a rescan environment: exactly
//     one omarchy-shell call, `-q shell rescanPlugins`; otherwise neither;
//   * the exit status and the text for each outcome, and the checkout at the fixture's commit.
//
// What this does not observe: an execve that fails (a program that does not exist on the host
// cannot run: an absolute path to a host tool is observed only on a host that has it); work done
// inside a process without exec, such as a program opening the shell's IPC socket itself (the
// installer's own python3 could); anything in environments other than those listed.
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = join(dirname(fileURLToPath(import.meta.url)), "..");
const positional = process.argv.slice(2).filter((a) => !a.startsWith("--"));
const wantJson = process.argv.includes("--json");
const installer = positional[0] ?? join(repo, "install.sh");
const tracer = join(repo, "tools", "exec-trace.py");
const TOOLS = ["bash", "sh", "env", "git", "python3", "sleep", "mkdir", "dirname", "basename", "cat", "rm", "sed", "grep", "date", "cp", "mv", "ls", "tr", "head", "tail", "cut", "wc", "sort", "uname", "tar"];
const OMARCHY = readFileSync(join(repo, "tools", "omarchy-commands.txt"), "utf8").split("\n").map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
const EXTRA = ["qs", "quickshell", "hyprctl", "omarchy", "systemctl", "pkill", "killall", "loginctl", "notify-send"];
const RESTARTS = new Set(["omarchy-restart-shell", "omarchy-refresh-shell", "omarchy-launch-shell", "omarchy-update-restart"]);
const PER_ENV = new Set(["omarchy-restart-shell", "omarchy-shell", "omarchy-plugin-validate"]);
const CONCURRENCY = Number(process.env.RELOAD_CONCURRENCY || 4);
const PAUSE = 1.9;

const base = mkdtempSync(join(tmpdir(), "worldline-install-reload-"));
const sh = (cmd, cwd) => spawnSync("bash", ["-c", cmd], { cwd, encoding: "utf8" });

function tool(name) {
  for (const dir of ["/usr/bin", "/bin"]) if (existsSync(join(dir, name))) return join(dir, name);
  const found = sh(`command -v ${name}`).stdout.trim();
  return found.startsWith("/") ? found : null;
}

// A stand-in: prints the restart command's message and exits with its code, or just exits 0.
function standIn(dir, name, body) {
  writeFileSync(join(dir, name), `#!/bin/sh\n${body ?? "exit 0\n"}`);
  chmodSync(join(dir, name), 0o755);
}

// The names a traced exec answers to: the script an interpreter ran, the executable, argv[0].
function names(record) {
  const out = new Set();
  if (record.script) out.add(basename(record.script));
  if (record.exe) out.add(basename(record.exe));
  if (record.argv && record.argv[0]) out.add(basename(record.argv[0]));
  return out;
}
const isShellFacing = (name) => name === "omarchy" || name.startsWith("omarchy-") || EXTRA.includes(name);

function classify(record, fixtureShims) {
  const n = names(record);
  const argv = record.argv || [];
  const args = argv.slice(record.script ? 2 : 1);
  const has = (list) => [...n].some((x) => list.includes(x));
  const rescan = argv.some((a) => String(a).includes("rescanPlugins"));
  const restart = [...n].some((x) => RESTARTS.has(x))
    || (has(["qs", "quickshell"]) && !args.includes("ipc"))
    || has(["pkill", "killall"])
    || (has(["systemctl"]) && args.some((a) => ["restart", "stop", "kill", "try-restart", "reload-or-restart"].includes(a)))
    || (has(["hyprctl"]) && args.includes("dispatch"));
  const fixtureRestart = n.has("omarchy-restart-shell") && fixtureShims.has(record.script);
  const theRescan = n.has("omarchy-shell") && fixtureShims.has(record.script) && args.join(" ") === "-q shell rescanPlugins";
  const validate = n.has("omarchy-plugin-validate") && fixtureShims.has(record.script);
  const facing = [...n].some(isShellFacing) || rescan || restart;
  return { rescan, restart, fixtureRestart, theRescan, unexpected: facing && !fixtureRestart && !theRescan && !validate, omarchyShell: n.has("omarchy-shell") };
}

function runTraced(args, env) {
  return new Promise((resolve) => {
    const child = spawn("python3", args, { env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "", stderr = "";
    child.stdout.on("data", (d) => { stdout += d; });
    child.stderr.on("data", (d) => { stderr += d; });
    child.on("close", (status) => resolve({ status, stdout, stderr }));
  });
}

const RESTART = {
  absent: null,
  ok: { rc: 0, message: "", says: "shell restarted" },
  refused: { rc: 1, message: "Refusing to restart Omarchy shell while the session is locked.", says: "was not restarted" },
  relock: { rc: 1, message: "Omarchy shell restarted, but the session lock was not re-secured.", says: "lock the session now" },
  notready: { rc: 7, message: "Omarchy shell did not become ready after restart.", says: "may be down" },
};

const failures = [];
const reports = [];
try {
  // Tools, the tracer's allowlist, and the shared stand-ins for every other shell-facing command.
  const bin = join(base, "bin");
  const others = join(base, "others");
  mkdirSync(bin);
  mkdirSync(others);
  const allowExe = [];
  for (const name of TOOLS) {
    const found = tool(name);
    if (!found) continue;
    symlinkSync(found, join(bin, name));
    allowExe.push(realpathSync(found));
  }
  const gitExecPath = sh("git --exec-path").stdout.trim();
  for (const name of [...OMARCHY, ...EXTRA]) if (!PER_ENV.has(name)) standIn(others, name);

  const environments = [];
  for (const nsr of ["0", "1"])
    for (const [restartKind, restart] of Object.entries(RESTART))
      for (const shellPresent of [false, true]) environments.push({ nsr, restartKind, restart, shellPresent, run: environments.length + 1 });

  async function runEnvironment({ nsr, restartKind, restart, shellPresent, run }) {
    const name = `NSR=${nsr} restart=${restartKind} omarchy-shell=${shellPresent ? "present" : "absent"}`;
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
    const omarchyPath = join(runtime, "omarchy");
    const path = join(base, `path-${run}`);
    mkdirSync(join(home, ".config/omarchy/plugins"), { recursive: true });
    mkdirSync(join(home, ".config/hypr"), { recursive: true });
    mkdirSync(runtime, { recursive: true });
    writeFileSync(join(home, ".config/omarchy/shell.json"), '{"bar": {"layout": {"right": []}}}\n');
    writeFileSync(join(home, ".config/hypr/bindings.lua"), "-- bindings\n");
    // The per-environment stand-ins, on PATH and where Omarchy keeps its commands.
    const shimDirs = [path, join(omarchyPath, "bin"), join(home, ".local/share/omarchy/bin")];
    for (const dir of shimDirs) {
      mkdirSync(dir, { recursive: true });
      if (restart) standIn(dir, "omarchy-restart-shell", (restart.message ? `echo "${restart.message}" >&2\n` : "") + `exit ${restart.rc}\n`);
      if (shellPresent) standIn(dir, "omarchy-shell");
      standIn(dir, "omarchy-plugin-validate");
      if (dir !== path) for (const other of [...OMARCHY, ...EXTRA]) if (!PER_ENV.has(other)) standIn(dir, other);
    }
    const fixtureShims = new Set();
    for (const dir of [...shimDirs, others]) for (const n of [...OMARCHY, ...EXTRA]) fixtureShims.add(join(realpathSync(dir), n));

    const env = [`HOME=${home}`, `PATH=${path}:${others}:${bin}`, `WORLDLINE_NO_SHELL_RESTART=${nsr}`,
      `XDG_RUNTIME_DIR=${runtime}`, "WAYLAND_DISPLAY=wayland-test", "HYPRLAND_INSTANCE_SIGNATURE=test", `OMARCHY_PATH=${omarchyPath}`];
    const problems = [];
    for (const phase of ["install", "upgrade"]) {
      if (phase === "upgrade") {
        writeFileSync(join(src, "WORLDLINE-FIXTURE-UPGRADE"), "second commit\n");
        const upgrade = sh("git add WORLDLINE-FIXTURE-UPGRADE && git -c user.email=t@t -c user.name=t commit -q -m upgrade", src);
        if (upgrade.status !== 0) throw new Error(`fixture upgrade commit: ${upgrade.stderr}`);
      }
      const log = join(base, `trace-${run}-${phase}.jsonl`);
      writeFileSync(log, "");
      const traceArgs = [tracer, "--log", log, "--deadline", "90", ...allowExe.flatMap((e) => ["--allow-exe", e]),
        "--allow-prefix", gitExecPath, "--allow-prefix", base, "--", realpathSync(join(bin, "env")), "-i", ...env,
        realpathSync(join(bin, "bash")), join(src, "install.sh")];
      const result = await runTraced(traceArgs, { PATH: "/usr/bin:/bin" });
      const output = `${result.stdout}${result.stderr}`;
      const records = readFileSync(log, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
      const say = (text) => problems.push(`${phase}: ${text}`);
      const show = (r) => `${r.script || r.exe} ${(r.argv || []).slice(1).join(" ")}`.trim();

      if (result.status === 124 || result.status === 125) say(`the tracer stopped with ${result.status}: ${result.stderr.trim().split("\n").pop()}`);
      if (records.length === 0) say("the tracer recorded no exec at all");
      const classes = records.map((r) => ({ r, c: classify(r, fixtureShims) }));
      const restarts = classes.filter(({ c }) => c.restart);
      const rescans = classes.filter(({ c }) => c.rescan);
      const denied = records.filter((r) => r.denied);
      const unexpected = classes.filter(({ c }) => c.unexpected);
      const shellCalls = classes.filter(({ c }) => c.omarchyShell);
      if (restarts.length > 0 && rescans.length > 0) say(`both a restart and a rescan: ${[...restarts, ...rescans].map(({ r }) => show(r)).join(" | ")}`);
      if (denied.length > 0) say(`programs outside the fixture were executed (killed before they ran): ${denied.map(show).join(" | ")}`);
      if (unexpected.length > 0) say(`unexpected shell-facing calls: ${unexpected.map(({ r }) => show(r)).join(" | ")}`);
      if (phase === "install" && !output.includes("cloned")) say("the first run must clone");
      if (phase === "upgrade" && !output.includes("fast-forwarded")) say("the second run must fast-forward");
      const deployed = sh(`git -C '${join(home, ".config/omarchy/plugins/khephri.worldline")}' rev-parse HEAD`).stdout.trim();
      const fixture = sh("git rev-parse HEAD", src).stdout.trim();
      if (deployed !== fixture) say(`the checkout is at ${deployed.slice(0, 12)}, not the fixture's ${fixture.slice(0, 12)}`);
      const restartExpected = nsr === "0" && restart !== null;
      if (restartExpected) {
        const ours = restarts.filter(({ c }) => c.fixtureRestart);
        if (restarts.length !== 1 || ours.length !== 1) say(`expected exactly one restart, by the fixture's omarchy-restart-shell; saw ${restarts.length}`);
        if (shellCalls.length !== 0) say(`a restart environment may make no omarchy-shell call: ${shellCalls.map(({ r }) => show(r)).join(" | ")}`);
        const moved = records.filter((r) => names(r).has("git") && (r.argv || []).some((a) => a === "merge" || a === "clone"));
        if (ours.length === 1 && moved.length > 0) {
          const gap = ours[0].r.t - moved[moved.length - 1].t;
          if (!(gap >= PAUSE)) say(`the restart came ${gap.toFixed(2)} s after the checkout moved; the pause must be at least ${PAUSE} s`);
        }
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
        if (restarts.length !== 0) say(`no restart may run when it is disabled or absent: ${restarts.map(({ r }) => show(r)).join(" | ")}`);
        if (result.status !== 0) say(`expected exit 0, got ${result.status}`);
        if (shellPresent) {
          const ours = rescans.filter(({ c }) => c.theRescan);
          if (rescans.length !== 1 || ours.length !== 1) say(`expected exactly one rescan, the fixture's omarchy-shell -q shell rescanPlugins; saw ${rescans.length}`);
          if (shellCalls.length !== 1) say(`a rescan environment makes exactly one omarchy-shell call, the rescan: ${shellCalls.map(({ r }) => show(r)).join(" | ")}`);
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
    return { name, problems };
  }

  const queue = [...environments];
  const workers = Array.from({ length: Math.max(1, CONCURRENCY) }, async () => {
    while (queue.length > 0) {
      const next = queue.shift();
      reports[next.run - 1] = await runEnvironment(next);
    }
  });
  await Promise.all(workers);
  for (const { name, problems } of reports) {
    if (problems.length > 0) {
      failures.push(name);
      console.error(`FAIL ${name}\n  - ${problems.join("\n  - ")}`);
    } else {
      console.log(`ok   ${name} (install, then upgrade)`);
    }
  }
} finally {
  rmSync(base, { recursive: true, force: true });
}
if (wantJson) console.log(JSON.stringify({ environments: reports.length, failed: failures.length, failures }));
if (failures.length > 0) {
  console.error(`test-install-reload: ${failures.length} environment(s) failed`);
  process.exit(1);
}
console.log("test-install-reload: in every environment, on install and on upgrade, the installer restarted or rescanned, never both, by any exec route the tracer saw, and reported what it did");
