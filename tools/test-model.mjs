#!/usr/bin/env node
// Unit tests for Model.js (the plugin's pure functions), runnable without a shell:
//   node tools/test-model.mjs
// Loads Model.js as plain JS (drops the .pragma line) and checks the derivations the cockpit
// and the bar rely on: status parsing, signal/staleness, evidence vocabulary, default
// selection, sibling ranking, doctor rows, CLI error parsing, and (1.3.5) the commit outcome,
// the code table, the invariant label and engine compatibility.
//   node tools/test-model.mjs [MODEL_JS]   test another Model.js (a mutant, an older release)
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import assert from "node:assert/strict";

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(process.argv[2] ?? join(here, "..", "Model.js"), "utf8").replace(".pragma library", "");
const exportsList = [
  "parseStatus", "signal", "daemonAgeMs", "evidence", "evidenceLabel", "checkStatusLabel",
  "defaultSelection", "siblingComparison", "integrityRows", "openTransactions", "capabilityRows",
  "parseCliError", "deltaSummary", "deltaCount", "operationKind", "operationLabel",
  "canCollapse", "canReturnTo", "isPrimeGeneration", "widgetSetting", "runningJobCount",
  "activeJob", "stateCounts", "fmtDuration", "shortHash", "shortAlias", "displayAlias", "jobLabel", "fmtBytes",
  "notificationBody", "logTail",
  // 1.3.5
  "commitOutcome", "codeInfo", "refusalAdvice", "invariantLabel", "engineCompatibility", "isMutatingArgv",
  "commandRefusal", "postCommitWarnings", "parseRecord", "preparedAfterStop", "prepareOutcome", "wasStopped",
  "rootOutcome", "actionFailureText", "CODE_TABLE", "PLUGIN_CODES", "PLANNED_CODES", "SUPPORTED_CODE_SET_SHA256",
];
const M = {};
// A name an older Model.js lacks is exported as undefined, so each test that needs it fails on its
// own instead of the whole file failing to load.
new Function("exports", source + ";" + exportsList.map((n) => `exports.${n}=typeof ${n}==="undefined"?undefined:${n};`).join(""))(M);

let passed = 0;
function test(name, fn) {
  try { fn(); passed++; console.log(`  PASS  ${name}`); }
  catch (error) { console.log(`  FAIL  ${name}\n        ${error.message}`); process.exitCode = 1; }
}

const now = Date.parse("2026-09-20T12:00:00.000Z");
const fresh = new Date(now - 2000).toISOString();
const old = new Date(now - 60000).toISOString();
const base = {
  schemaVersion: 1,
  daemon: { state: "RUNNING", publishedAt: fresh, version: "1.1.0" },
  prime: { instanceId: "p1", id: "sha256:aa", dirty: false, roots: [] },
  activeWorld: "PRIME",
  worlds: [],
  jobs: [],
  capabilities: { systemd: { state: "UNAVAILABLE", reason: "starting" }, overlay: { state: "AVAILABLE", backend: "overlayfs+bubblewrap" } },
  lastReceipt: null,
  ghostRecommendation: null,
};
const world = (over) => ({ alias: "w", instanceId: "i", parent: "p1", state: "VALID", checks: [], delta: { added: 0, modified: 0, deleted: 0, files: [] }, born: fresh, risk: "MEDIUM", complexity: "MEDIUM", conflicts: [], contamination: [], ...over });

console.log("Model.js");
test("parseStatus accepts the nine-field document and rejects anything else", () => {
  assert.ok(M.parseStatus(JSON.stringify(base)));
  assert.equal(M.parseStatus("{"), null);
  assert.equal(M.parseStatus(JSON.stringify({ ...base, schemaVersion: 2 })), null);
  const { jobs, ...missing } = base;
  assert.equal(M.parseStatus(JSON.stringify(missing)), null);
  assert.equal(M.parseStatus(JSON.stringify({ ...base, worlds: "nope" })), null);
});
test("signal: live within 10 s, stale after, offline when STOPPED or absent", () => {
  assert.equal(M.signal(base, now), "live");
  assert.equal(M.signal({ ...base, daemon: { ...base.daemon, publishedAt: old } }, now), "stale");
  assert.equal(M.signal({ ...base, daemon: { ...base.daemon, state: "STOPPED" } }, now), "offline");
  assert.equal(M.signal(null, now), "offline");
});
test("evidence: required failure is FAIL, optional failure is a gap on PASS, no checks is UNASSESSED, stale wins", () => {
  const pass = M.evidence(world({ checks: [{ id: "a", required: true, status: "PASS" }, { id: "b", required: false, status: "FAIL" }] }), false);
  assert.equal(pass.state, "PASS"); assert.equal(pass.gaps, 1); assert.equal(M.evidenceLabel(pass), "PASS · 1 GAP");
  assert.equal(M.evidence(world({ checks: [{ id: "a", required: true, status: "FAIL" }] }), false).state, "FAIL");
  assert.equal(M.evidence(world({ checks: [{ id: "a", required: true, status: "UNAVAILABLE" }] }), false).state, "UNAVAILABLE");
  assert.equal(M.evidence(world({ checks: [{ id: "a", required: true, status: "UNASSESSED" }] }), false).state, "UNASSESSED");
  assert.equal(M.evidence(world({ checks: [] }), false).state, "UNASSESSED");
  assert.equal(M.evidence(world({ checks: [{ id: "a", required: true, status: "PASS" }] }), true).state, "STALE");
  assert.equal(M.checkStatusLabel({ status: "weird" }), "UNASSESSED");
});
test("defaultSelection prefers the active world, then newest VALID, then running, then PRIME", () => {
  const worlds = [world({ alias: "prime-x", instanceId: "p1", parent: null, state: "ARCHIVED" }), world({ alias: "old", instanceId: "o", born: old }), world({ alias: "new", instanceId: "n", born: fresh }), world({ alias: "run", instanceId: "r", state: "MUTABLE" })];
  assert.equal(M.defaultSelection({ ...base, worlds }), 2);
  assert.equal(M.defaultSelection({ ...base, worlds, activeWorld: "run" }), 3);
  assert.equal(M.defaultSelection({ ...base, worlds: [worlds[0]] }), 0);
  assert.equal(M.defaultSelection({ ...base, worlds: [] }), -1);
});
test("siblingComparison ranks like pick_candidate and refuses without evidence", () => {
  const sib = (alias, over) => world({ alias, instanceId: alias, ...over });
  const withChecks = [sib("a", { checks: [{ id: "t", required: true, status: "PASS" }], risk: "LOW" }), sib("b", { checks: [{ id: "t", required: true, status: "FAIL" }], state: "DEGRADED" }), sib("c", { checks: [{ id: "t", required: true, status: "PASS" }, { id: "o", required: false, status: "FAIL" }] })];
  const ranked = M.siblingComparison(withChecks, withChecks[0]);
  assert.equal(ranked.recommendation, "a");
  assert.equal(ranked.rows.find((r) => r.alias === "b").why, "not VALID");
  const noEvidence = [sib("a"), sib("b")];
  assert.equal(M.siblingComparison(noEvidence, noEvidence[0]).recommendation, null);
  assert.match(M.siblingComparison(noEvidence, noEvidence[0]).reason, /UNASSESSED/);
  assert.equal(M.siblingComparison([sib("a", { conflicts: [{}] })], sib("a", { conflicts: [{}] })).recommendation, null);
});
test("collapse and return gates follow the engine's rules", () => {
  assert.ok(M.canCollapse(world()));
  assert.ok(!M.canCollapse(world({ state: "DEGRADED" })));
  assert.ok(!M.canCollapse(world({ alias: "prime-abc" })));
  assert.ok(M.canReturnTo(world({ state: "ARCHIVED" })));
  assert.ok(!M.canReturnTo(world({ state: "DEAD" })));
});
test("integrityRows flags every DEGRADED/INCOMPLETE report and open transactions surface", () => {
  const doctor = { rootIntegrity: { state: "OK", roots: [{ state: "OK" }] }, storeIntegrity: { state: "DEGRADED", findings: [{ kind: "ORPHANED_GENERATION", originalPath: "/x" }] }, receiptCoverage: { state: "OK", committedWithoutReceipt: [] }, recovery: { state: "INCOMPLETE", quarantined: [{ transactionId: "t" }] }, unsupervisedWorlds: [], openTransactions: [{ transactionId: "t1", state: "PREPARED" }] };
  const rows = M.integrityRows(doctor);
  assert.deepEqual(rows.filter((r) => r.urgent).map((r) => r.name), ["store", "recovery"]);
  assert.match(rows.find((r) => r.name === "store").detail, /ORPHANED_GENERATION \(\/x\)/);
  assert.equal(M.openTransactions(doctor).length, 1);
  assert.equal(M.capabilityRows(base.capabilities).find((r) => r.name === "systemd").note, "starting");
});
test("parseCliError extracts code, message and the JSON details line", () => {
  const error = M.parseCliError("worldline: CONFLICT: collapse denied: CONFLICT\n{\"decision\": \"CONFLICT\", \"conflicts\": [{\"pathDisplay\": \"a.txt\"}]}", 1);
  assert.equal(error.code, "CONFLICT"); assert.equal(error.details.conflicts[0].pathDisplay, "a.txt");
  assert.equal(M.parseCliError("", 130).code, "INTERRUPTED");
  assert.equal(M.parseCliError("garbage", 1).code, "FAILED");
});
test("delta helpers count operations and label them without inventing paths", () => {
  const w = world({ delta: { added: 1, modified: 2, deleted: 0, files: [{ op: "ADD", pathDisplay: "a" }, { op: "MODIFY", pathDisplay: "b" }, { op: "MODIFY", pathDisplay: "c" }] } });
  assert.equal(M.deltaCount(w), 3);
  assert.deepEqual(M.deltaSummary(w), { added: 1, modified: 2, deleted: 0, files: 3 });
  assert.equal(M.operationKind({ op: "DELETE" }), "−");
  assert.equal(M.operationLabel({ pathDisplay: "x/y" }), "x/y");
  assert.equal(M.operationLabel({ weird: true }), '{"weird":true}');
});
test("job labels, truncated deltas, and the new diagnostics rows", () => {
  assert.equal(M.jobLabel({ state: "VALID" }), "FINISHED");
  assert.equal(M.jobLabel({ state: "TIMED_OUT" }), "TIMED OUT");
  assert.equal(M.jobLabel({ state: "RUNNING" }), "RUNNING");
  assert.equal(M.deltaCount(world({ delta: { added: 300, modified: 0, deleted: 0, files: new Array(200).fill({ op: "ADD", pathDisplay: "x" }), truncated: true, total: 300 } })), 300);
  assert.equal(M.fmtBytes(0), "0 B"); assert.equal(M.fmtBytes(1536), "1.5 KB"); assert.equal(M.fmtBytes(52428800), "50 MB");
  const doctor = { rootIntegrity: { state: "OK", roots: [] }, storeIntegrity: { state: "OK", findings: [] }, receiptCoverage: { state: "OK", committedWithoutReceipt: [] }, recovery: { state: "OK", quarantined: [] }, unsupervisedWorlds: [],
    anchor: { state: "OK", entries: 3, unanchoredReceipts: 0, attest: "VERIFIED", external: "MATCH" }, storeUsage: { bytes: { generations: 1048576, worlds: 0, transactions: 0, overlays: 0, logs: 0 }, total: 1048576 }, networkPolicy: { policy: "allowlist", allow: ["example.org"] }, limits: { defaultTimeoutSeconds: 900 } };
  const rows = M.integrityRows(doctor);
  const byName = Object.fromEntries(rows.map((r) => [r.name, r]));
  assert.equal(byName.anchor.state, "OK"); assert.match(byName.anchor.detail, /attest verified · external match/); assert.equal(byName.anchor.urgent, false);
  assert.equal(byName["store usage"].state, "1 MB"); assert.equal(byName.network.state, "ALLOWLIST"); assert.equal(byName.timeout.state, "900 s");
  const broken = M.integrityRows({ ...doctor, anchor: { state: "OK", entries: 3, attest: "VERIFIED", external: "ROLLED_BACK" } });
  assert.equal(broken.find((r) => r.name === "anchor").urgent, true);
});
test("jobs, counts, formatting and settings", () => {
  const jobs = [{ world: "i", state: "RUNNING" }, { world: "i", state: "DEGRADED" }, { world: "z", state: "STARTING" }];
  assert.equal(M.runningJobCount(jobs), 2);
  assert.equal(M.activeJob(jobs, "i").state, "RUNNING");
  assert.equal(M.activeJob(jobs, "none"), null);
  assert.deepEqual(M.stateCounts([world(), world({ state: "DEAD" }), world()]), [{ state: "VALID", count: 2 }, { state: "DEAD", count: 1 }]);
  assert.equal(M.fmtDuration(fresh, null, now), "2s");
  assert.equal(M.shortHash("sha256:" + "a".repeat(64)), "aaaaaaaaaaaa…");
  assert.equal(M.displayAlias(world({ instanceId: "p1" }), base, "PRIME′"), "PRIME′");
  assert.equal(M.widgetSetting({ layout: { right: [{ id: "khephri.worldline", motionEnabled: false }] } }, "khephri.worldline", "motionEnabled", true), false);
  assert.equal(M.widgetSetting(null, "khephri.worldline", "motionEnabled", true), true);
});
test("notification bodies carry daemon strings as literal text, not markup", () => {
  assert.equal(M.notificationBody('fix-<img src="http://127.0.0.1:9/b.png">'), 'fix-&lt;img src="http://127.0.0.1:9/b.png"&gt;');
  assert.equal(M.notificationBody("<a href='x'>a & b</a>"), "&lt;a href='x'&gt;a &amp; b&lt;/a&gt;");
  assert.equal(M.notificationBody("&lt;"), "&amp;lt;");
  assert.equal(M.notificationBody("claude-1"), "claude-1");
  assert.equal(M.notificationBody(null), "");
});

test("logTail: the last lines of a short log, unmarked", () => {
  assert.equal(M.logTail("a\nb\nc\n", false, 60, 2000), "a\nb\nc");
  assert.equal(M.logTail("only", false, 60, 2000), "only");
});

test("logTail: more lines than the view keeps are marked as not shown", () => {
  const text = Array.from({ length: 70 }, (_, i) => `line ${i}`).join("\n");
  const shown = M.logTail(text, false, 60, 2000).split("\n");
  assert.equal(shown[0], "… earlier output not shown");
  assert.equal(shown.length, 61);
  assert.equal(shown[1], "line 10");
  assert.equal(shown[60], "line 69");
});

test("logTail: a byte-cut tail drops its first (fragment) line and says so", () => {
  const shown = M.logTail("ment of a line\nwhole one\nwhole two\n", true, 60, 2000);
  assert.equal(shown, "… earlier output not shown\nwhole one\nwhole two");
});

test("logTail: a cut tail that is one fragment has no complete line to show", () => {
  assert.equal(M.logTail("x".repeat(65536), true, 60, 2000), "(no complete line in the last part of the log)");
});

test("logTail: each line is capped at maxChars", () => {
  const shown = M.logTail("short\n" + "y".repeat(5000), false, 60, 2000).split("\n");
  assert.equal(shown[0], "short");
  assert.equal(shown[1].length, 2000);
  assert.ok(shown[1].endsWith("…"));
});

// ------------------------------------------------------------------ 1.3.5: commit outcome
// OB-193 / OB-178 / OB-128: the plugin says "not committed" only when the engine reports the
// transaction ABORTED or DENIED (or still open and not exchanged), COMMITTED with the failure as a
// warning when the engine reports COMMITTED, and "outcome not confirmed" otherwise.
const TX = "7f3c1e2a-5b6d-4e8f-9a0b-1c2d3e4f5a6b";
const NOFILE = "No file under a managed root changed";
const cli = (name) => JSON.parse(readFileSync(join(here, "fixtures", "cli", `${name}.json`), "utf8"));
const failureOf = (name) => M.parseCliError(cli(name).stderr, cli(name).exitCode);
const recordOf = (name) => JSON.parse(cli(name).stdout);
const deadline = { code: "CLI_DEADLINE", message: "worldline transaction did not finish within 1800 s", details: null };

test("commitOutcome: COMMIT_DURABILITY_UNCERTAIN with details.state COMMITTED is committed with the warning", () => {
  const o = M.commitOutcome(failureOf("commit-durability-uncertain"), null, { transactionId: TX });
  assert.equal(o.kind, "committed");
  assert.ok(o.warning.includes("COMMIT_DURABILITY_UNCERTAIN"));
  assert.ok(!o.caption.includes(NOFILE));
});
test("commitOutcome: a post-commit error with the engine's record COMMITTED (1.9.1) is committed", () => {
  const o = M.commitOutcome(failureOf("commit-prime-watch-after-commit-1.9.1"), recordOf("show-committed-1.9.1"), { transactionId: TX });
  assert.equal(o.kind, "committed");
  assert.ok(o.warning.includes("PRIME_WATCH_UNAVAILABLE"));
});
test("commitOutcome: DENIED and ABORTED records are not committed, with the no-file caption", () => {
  for (const [failure, record] of [["commit-conflict-1.9.1", "show-denied-1.9.1"], ["commit-foreign-managed-write-1.9.1", "show-denied-fmw-1.9.1"]]) {
    const o = M.commitOutcome(failureOf(failure), recordOf(record), { transactionId: TX });
    assert.equal(o.kind, "not-committed", failure);
    assert.equal(o.title, "NOT COMMITTED");
    assert.ok(o.caption.includes(NOFILE));
  }
  const aborted = M.commitOutcome(deadline, recordOf("show-aborted-1.9.2"), { transactionId: TX, stopped: true });
  assert.equal(aborted.kind, "not-committed");
});
test("commitOutcome: details.state DENIED with exchanged false is not committed without a record", () => {
  const o = M.commitOutcome(failureOf("commit-prime-changed-1.9.2"), null, { transactionId: TX });
  assert.equal(o.kind, "not-committed");
});
test("commitOutcome: PREPARED with exchanged false after a refusal is an open transaction, not committed", () => {
  const o = M.commitOutcome(failureOf("commit-proof-unevaluable-1.9.2"), recordOf("show-prepared-1.9.2"), { transactionId: TX });
  assert.equal(o.kind, "open");
  assert.ok(o.title.startsWith("NOT COMMITTED — TRANSACTION STILL OPEN"));
  assert.ok(o.caption.includes(NOFILE));
});
test("commitOutcome: an engine that does not report exchanged (1.9.1) leaves PREPARED not confirmed", () => {
  const o = M.commitOutcome(failureOf("commit-internal-error"), recordOf("show-prepared-1.9.1"), { transactionId: TX });
  assert.equal(o.kind, "unknown");
  assert.ok(o.title.startsWith("OUTCOME NOT CONFIRMED"));
  assert.ok(!o.caption.includes(NOFILE));
});
test("commitOutcome: a failed show, or no record at all, is not confirmed", () => {
  for (const failure of [failureOf("commit-internal-error"), failureOf("commit-conflict-1.9.1"), { code: "SOMETHING_NEW", message: "?", details: null }]) {
    const o = M.commitOutcome(failure, null, { transactionId: TX, showFailure: failureOf("show-daemon-unavailable") });
    assert.equal(o.kind, "unknown", failure.code);
    assert.ok(!o.caption.includes(NOFILE));
  }
});
test("commitOutcome: a stopped commit whose transaction is not terminal is pending, then not confirmed", () => {
  const pending = M.commitOutcome(deadline, recordOf("show-authorized-1.9.2"), { transactionId: TX, stopped: true });
  assert.equal(pending.kind, "pending");
  assert.ok(pending.title.startsWith("OUTCOME UNKNOWN"));
  const last = M.commitOutcome(deadline, recordOf("show-authorized-1.9.2"), { transactionId: TX, stopped: true, final: true });
  assert.equal(last.kind, "unknown");
  const committed = M.commitOutcome(deadline, recordOf("show-committed-1.9.2"), { transactionId: TX, stopped: true });
  assert.equal(committed.kind, "committed");
});
test("commitOutcome: exchanged true on a transaction that is not COMMITTED is not confirmed", () => {
  const o = M.commitOutcome(failureOf("commit-internal-error"), recordOf("show-authorized-exchanged-quarantined-1.9.2"), { transactionId: TX });
  assert.equal(o.kind, "unknown");
  assert.ok(o.caption.includes("exchange"));
});
test("commitOutcome: a record for another transaction is not evidence about this one", () => {
  const other = { ...recordOf("show-denied-1.9.1"), transactionId: "another" };
  assert.equal(M.commitOutcome(failureOf("commit-internal-error"), other, { transactionId: TX }).kind, "unknown");
});
test("commitOutcome: missing identity and contradictory terminal exchange facts stay unknown", () => {
  const failure = failureOf("commit-internal-error");
  for (const record of [
    { state: "COMMITTED", exchanged: true },
    { state: "COMMITTED", transactionId: TX, exchanged: false },
    { state: "ABORTED", transactionId: TX, exchanged: true },
    { state: "DENIED", transactionId: TX, exchanged: true },
  ]) {
    const outcome = M.commitOutcome(failure, record, { transactionId: TX });
    assert.equal(outcome.kind, "unknown", JSON.stringify(record));
    assert.ok(!outcome.caption.includes(NOFILE));
  }
  for (const details of [
    { state: "COMMITTED", transactionId: "another" },
    { state: "COMMITTED", transactionId: TX, exchanged: false },
  ])
    assert.equal(M.commitOutcome({ ...failure, details }, null, { transactionId: TX }).kind, "unknown");
});
test("commitOutcome: only the not-committed classes carry the no-file caption", () => {
  const cases = [
    [failureOf("commit-durability-uncertain"), null, {}],
    [failureOf("commit-internal-error"), null, {}],
    [deadline, recordOf("show-authorized-1.9.2"), { stopped: true }],
    [failureOf("commit-conflict-1.9.1"), recordOf("show-denied-1.9.1"), {}],
    [failureOf("commit-proof-unevaluable-1.9.2"), recordOf("show-prepared-1.9.2"), {}],
    [failureOf("commit-internal-error"), recordOf("show-prepared-1.9.1"), {}],
  ];
  for (const [failure, record, options] of cases) {
    const o = M.commitOutcome(failure, record, { transactionId: TX, ...options });
    const says = `${o.title} ${o.caption} ${o.warning || ""}`.includes(NOFILE);
    assert.equal(says, o.kind === "not-committed" || o.kind === "open", `${o.kind}: ${o.caption}`);
  }
});
test("wasStopped: the plugin's own stops are CLI_DEADLINE and CLI_OUTPUT_TOO_LARGE", () => {
  assert.equal(M.wasStopped(deadline), true);
  assert.equal(M.wasStopped({ code: "CLI_OUTPUT_TOO_LARGE" }), true);
  assert.equal(M.wasStopped(failureOf("commit-conflict-1.9.1")), false);
});
test("postCommitWarnings: a committed result's postCommit entries become warnings", () => {
  const result = JSON.parse(cli("commit-committed-postcommit-1.9.2").stdout);
  const warnings = M.postCommitWarnings(result);
  assert.equal(warnings.length, 1);
  assert.ok(warnings[0].includes("PRIME_WATCH_UNAVAILABLE"));
  assert.deepEqual(M.postCommitWarnings(JSON.parse(cli("commit-committed-1.9.1").stdout)), []);
  assert.deepEqual(M.postCommitWarnings({ postCommit: { warnings: ["export failed"] } }), ["export failed"]);
});
test("parseRecord: a transaction record parses; anything else is null", () => {
  assert.equal(M.parseRecord(cli("show-committed-1.9.1").stdout).state, "COMMITTED");
  assert.equal(M.parseRecord("{"), null);
  assert.equal(M.parseRecord("[]"), null);
});
test("prepareOutcome: a prepare stopped at its deadline is resolved from the transaction list", () => {
  const listing = JSON.parse(cli("list-prepared-after-deadline-1.9.1").stdout);
  const world = { alias: "w1", instanceId: "3a9f0c1d-2b3e-4f50-8a1b-c2d3e4f5a6b7" };
  const found = M.preparedAfterStop(listing, world, "collapse", Date.parse("2026-09-30T11:00:00Z"));
  assert.equal(found.transactionId, TX);
  assert.equal(M.preparedAfterStop(listing, world, "return", Date.parse("2026-09-30T11:00:00Z")), null);
  assert.equal(M.preparedAfterStop(listing, { alias: "other", instanceId: "x" }, "collapse", 0), null);
  assert.equal(M.preparedAfterStop([{ ...listing[0], createdAt: "2020-01-01T00:00:00Z" }], world, "collapse", Date.parse("2026-09-30T11:00:00Z")), null);
  assert.equal(M.prepareOutcome(found, {}).kind, "prepared-unreviewed");
  assert.equal(M.prepareOutcome({ ...found, state: "DENIED" }, {}).kind, "denied");
  assert.equal(M.prepareOutcome(null, {}).kind, "pending");
  assert.equal(M.prepareOutcome(null, { final: true }).kind, "unknown");
});
test("rootOutcome: a stopped root add or remove is resolved from the root list", () => {
  const roots = [{ path: "/home/op/project", rootKey: "rk", kind: "repo", primary: true }];
  assert.equal(M.rootOutcome("add", "/home/op/project", roots), "done");
  assert.equal(M.rootOutcome("add", "/home/op/other", roots), "not-yet");
  assert.equal(M.rootOutcome("remove", "/home/op/other", roots), "done");
  assert.equal(M.rootOutcome("remove", "/home/op/project", roots), "not-yet");
  assert.equal(M.rootOutcome("add", "/x", null), "unknown");
});

// ------------------------------------------------------------------ 1.3.5: code table (OB-194)
const engineCodes = JSON.parse(readFileSync(join(here, "engine-codes.json"), "utf8"));
test("code table: every code of the paired engine has an outcome class and advice", () => {
  assert.ok(M.CODE_TABLE, "Model.CODE_TABLE exists");
  const missing = engineCodes.codes.filter((code) => !M.CODE_TABLE[code]);
  assert.deepEqual(missing, []);
  for (const code of engineCodes.codes) {
    const info = M.codeInfo(code);
    assert.ok(["refused", "committed", "unknown", "record"].includes(info.outcome), code);
    assert.ok(info.advice.trim().length >= 30, code);
  }
});
test("code table: FOREIGN_MANAGED_WRITE is refused, COMMIT_DURABILITY_UNCERTAIN is committed, CLI_DEADLINE is unknown", () => {
  assert.equal(M.codeInfo("FOREIGN_MANAGED_WRITE").outcome, "refused");
  assert.ok(M.refusalAdvice("FOREIGN_MANAGED_WRITE").includes("outside"));
  assert.equal(M.codeInfo("COMMIT_DURABILITY_UNCERTAIN").outcome, "committed");
  assert.equal(M.codeInfo("CLI_DEADLINE").outcome, "unknown");
  assert.equal(M.codeInfo("INTERNAL_ERROR").outcome, "unknown");
});
test("code table: an unknown code is named as unknown, not explained away", () => {
  const info = M.codeInfo("SOMETHING_NEW");
  assert.equal(info.known, false);
  assert.equal(info.outcome, "unknown");
  assert.ok(info.advice.includes("SOMETHING_NEW"));
});
test("code table: the plugin declares the paired engine's code-set digest", () => {
  assert.equal(M.SUPPORTED_CODE_SET_SHA256, engineCodes.codeSetSha256);
});

// ------------------------------------------------------------------ 1.3.5: invariants (OB-084)
const verifiedProof = () => JSON.parse(readFileSync(join(here, "fixtures", "proof-status-verified-1.9.2.json"), "utf8"));
test("invariantLabel: PROVED requires the engine's complete named verification roster", () => {
  const v191 = JSON.parse(cli("commit-committed-1.9.1").stdout).receipt.invariantPreservation;
  const old = M.invariantLabel(v191);
  assert.equal(old.proved, false);
  assert.ok(!old.text.startsWith("PROVED ·") && old.text.includes("1.9.1 rules"));
  const verified = M.invariantLabel(verifiedProof());
  assert.equal(verified.proved, true);
  assert.ok(verified.text.startsWith("PROVED"));
  for (const bad of [{ state: "PROVED", verification: { floor: "FAIL" } }, { state: "PROVED", verification: {} },
    { state: "PROVED", verification: { floor: "PASS" } }, { state: "PROVED", verification: [{ check: "floor", outcome: "PASS" }] }])
    assert.equal(M.invariantLabel(bad).proved, false, JSON.stringify(bad));
  for (const state of ["MANIFEST_ONLY", "TEST_LIBRARY", "UNVERIFIED", "SOMETHING"]) {
    const label = M.invariantLabel({ state, reason: "r" });
    assert.equal(label.proved, false, state);
    assert.ok(label.text.includes("not proved"), state);
  }
  assert.equal(M.invariantLabel(null).text, "—");
});
test("invariantLabel: missing, unknown, duplicate and non-passing proof checks never label PROVED", () => {
  for (const check of verifiedProof().verification.checks) {
    const missing = verifiedProof();
    missing.verification.checks = missing.verification.checks.filter((entry) => entry.name !== check.name);
    assert.equal(M.invariantLabel(missing).proved, false, `missing ${check.name}`);
    for (const value of [false, null, "PASS", "UNKNOWN", 1]) {
      const failed = verifiedProof();
      failed.verification.checks.find((entry) => entry.name === check.name).ok = value;
      assert.equal(M.invariantLabel(failed).proved, false, `${check.name}: ${value}`);
    }
  }
  const duplicate = verifiedProof();
  duplicate.verification.checks.push(duplicate.verification.checks[0]);
  assert.equal(M.invariantLabel(duplicate).proved, false);
  const unknown = verifiedProof();
  unknown.verification.checks.push({ name: "unknown-check", ok: true });
  assert.equal(M.invariantLabel(unknown).proved, false);
  for (const change of [{ evaluable: false }, { proofGate: "skipped" }, { checks: null }, { checks: "251" },
    { checks: 0 }, { checks: NaN }, { checks: Infinity }, { verification: { schema: "other", checks: verifiedProof().verification.checks } }])
    assert.equal(M.invariantLabel({ ...verifiedProof(), ...change }).proved, false);
});

// ------------------------------------------------------------------ 1.3.5: engine compatibility (OB-195)
const withDigest = (digest) => ({ ...base, daemon: { ...base.daemon, version: "1.9.2", codeSetSha256: digest } });
test("engineCompatibility: only an engine publishing this plugin's code-set digest is compatible", () => {
  assert.equal(M.engineCompatibility(withDigest(M.SUPPORTED_CODE_SET_SHA256)).compatible, true);
  const other = M.engineCompatibility(withDigest("sha256:" + "0".repeat(64)));
  assert.equal(other.compatible, false);
  assert.ok(other.reason.includes("code set"));
  const none = M.engineCompatibility(base);
  assert.equal(none.compatible, false);
  assert.ok(none.reason.includes("does not declare"));
  assert.equal(M.engineCompatibility(null).compatible, false);
});
test("isMutatingArgv: read-only commands pass; everything else counts as mutating", () => {
  for (const argv of [["worldline", "adapters", "--json"], ["worldline", "doctor", "--json"], ["worldline", "doctor", "--refresh", "--json"],
    ["worldline", "anchor", "--json"], ["worldline", "anchor", "pin", "--json"],
    ["worldline", "transaction", "show", TX, "--json"], ["worldline", "transaction", "list", "--json"], ["worldline", "root", "list", "--json"],
    ["worldline", "root", "add", "--dry-run", "--json", "--", "/p"], ["worldline", "root", "remove", "--dry-run", "--json", "--", "/p"],
    ["worldline", "init", "--dry-run", "--json", "--", "/p"], ["worldline", "status"], ["tail", "-c", "65536", "--", "/x"]])
    assert.equal(M.isMutatingArgv(argv), false, argv.join(" "));
  for (const argv of [["worldline", "collapse", "--prepare", "--json", "--", "w"], ["worldline", "return", "--prepare", "--json", "--", "w"],
    ["worldline", "anchor", "rotate", "--json"], ["worldline", "anchor", "future"], ["worldline", "root", "future", "--dry-run"],
    ["worldline", "transaction", "commit", TX, "--yes", "--json"], ["worldline", "transaction", "abort", TX, "--json"],
    ["worldline", "fork", "a", "--mission-text", "m", "--json", "--", "claude"], ["worldline", "race", "--detach", "--json"],
    ["worldline", "cancel", "--json", "--", "w"], ["worldline", "switch", "--json", "--", "w"], ["worldline", "inspect", "--json", "--", "w"],
    ["worldline", "root", "add", "--yes", "--json", "--", "/p"], ["worldline", "root", "remove", "--yes", "--json", "--", "/p"],
    ["worldline", "init", "--yes", "--json", "--", "/p"], ["worldline", "prune"], ["worldline", "something-new"]])
    assert.equal(M.isMutatingArgv(argv), true, argv.join(" "));
});
test("commandRefusal: an incompatible engine refuses every mutating command and no read", () => {
  const bad = M.engineCompatibility(base);
  assert.ok(M.commandRefusal(bad, ["worldline", "transaction", "commit", TX, "--yes", "--json"]).startsWith("worldline: ENGINE_INCOMPATIBLE: "));
  assert.equal(M.commandRefusal(bad, ["worldline", "transaction", "show", TX, "--json"]), "");
  const good = M.engineCompatibility(withDigest(M.SUPPORTED_CODE_SET_SHA256));
  assert.equal(M.commandRefusal(good, ["worldline", "transaction", "commit", TX, "--yes", "--json"]), "");
  for (const missing of [null, {}, { compatible: "true" }])
    assert.ok(M.commandRefusal(missing, ["worldline", "transaction", "commit", TX, "--yes", "--json"]).startsWith("worldline: ENGINE_INCOMPATIBLE: "));
});
test("actionFailureText: a failure whose outcome is not known says so instead of reading as a refusal", () => {
  assert.ok(M.actionFailureText("cancel w", deadline).includes("outcome unknown"));
  assert.ok(!M.actionFailureText("cancel w", { code: "NO_ACTIVE_JOB", message: "no job", details: null }).includes("outcome unknown"));
});

console.log(`${passed} passed${process.exitCode ? ", with failures" : ""}`);
