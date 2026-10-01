#!/usr/bin/env node
// Render tests for CollapsePanel.qml, headless, driven by synthetic CLI-shaped outputs:
//   node tools/test-collapse-panel.mjs          test this repository's panel
//   node tools/test-collapse-panel.mjs TREE     test the panel in another tree (a mutant, an older release)
//
// Stages the panel's own files (CollapsePanel.qml, WlCall.qml, the Wl* cards, Model.js) from TREE
// beside tools/qml-test/tst_collapse_panel.qml, writes the source-derived fixtures of tools/fixtures/cli
// into Recorded.js, and runs Qt 6's qmltestrunner offscreen with the stand-in modules in
// tools/qml-test/imports (qs.Commons, qs.Ui, Quickshell.Io). Nothing runs a real `worldline`
// command or touches a desktop session. A missing qmltestrunner is a failure, not a skip.
import { copyFileSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repo = join(dirname(fileURLToPath(import.meta.url)), "..");
const tree = resolve(process.argv[2] ?? repo);
const FILES = ["CollapsePanel.qml", "WlCall.qml", "WlCard.qml", "WlChip.qml", "WlKV.qml", "WlSectionTitle.qml", "Model.js"];

function findRunner() {
  const candidates = [process.env.QMLTESTRUNNER, "/usr/lib/qt6/bin/qmltestrunner",
    "/usr/lib/x86_64-linux-gnu/qt6/bin/qmltestrunner", "/usr/lib/aarch64-linux-gnu/qt6/bin/qmltestrunner"].filter(Boolean);
  for (const candidate of candidates) if (existsSync(candidate)) return candidate;
  for (const name of ["qmltestrunner6", "qmltestrunner-qt6"]) {
    const found = spawnSync("sh", ["-c", `command -v ${name}`], { encoding: "utf8" }).stdout.trim();
    if (found) return found;
  }
  return null;
}

const runner = findRunner();
if (!runner) {
  console.error("test-collapse-panel: no Qt 6 qmltestrunner found (set QMLTESTRUNNER); this is a failure, not a skip");
  process.exit(1);
}

const stage = mkdtempSync(join(tmpdir(), "worldline-panel-"));
let status = 1;
try {
  for (const file of FILES) copyFileSync(join(tree, file), join(stage, file));
  copyFileSync(join(repo, "tools/qml-test/tst_collapse_panel.qml"), join(stage, "tst_collapse_panel.qml"));
  const fixtures = {};
  const dir = join(repo, "tools/fixtures/cli");
  for (const name of readdirSync(dir).filter((f) => f.endsWith(".json")).sort())
    fixtures[name.replace(/\.json$/, "")] = JSON.parse(readFileSync(join(dir, name), "utf8"));
  const proof = JSON.parse(readFileSync(join(repo, "tools/fixtures/proof-status-verified-1.9.2.json"), "utf8"));
  writeFileSync(join(stage, "Recorded.js"), ".pragma library\nvar outputs = " + JSON.stringify(fixtures)
    + "\nvar verifiedProof = " + JSON.stringify(proof) + "\n");
  const home = join(stage, "home");
  mkdirSync(home);
  const result = spawnSync(runner, ["-import", join(repo, "tools/qml-test/imports"), "-input", join(stage, "tst_collapse_panel.qml")], {
    encoding: "utf8", timeout: 300000,
    env: { PATH: "/usr/bin:/bin", HOME: home, XDG_RUNTIME_DIR: home, QT_QPA_PLATFORM: "offscreen", LANG: "C.UTF-8" },
  });
  const output = `${result.stdout ?? ""}${result.stderr ?? ""}`;
  process.stdout.write(output);
  const totals = output.match(/Totals: (\d+) passed, (\d+) failed, (\d+) skipped/);
  if (result.status === 0 && totals && Number(totals[1]) > 0 && Number(totals[2]) === 0 && Number(totals[3]) === 0) {
    console.log(`test-collapse-panel: ${totals[1]} passed (${tree === repo ? "this repository" : tree})`);
    status = 0;
  } else {
    console.error(`test-collapse-panel: FAILED (${totals ? totals[0] : `runner exited ${result.status}${result.error ? ", " + result.error.message : ""}`})`);
  }
} finally {
  rmSync(stage, { recursive: true, force: true });
}
process.exit(status);
