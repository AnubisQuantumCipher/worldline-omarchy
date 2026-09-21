#!/usr/bin/env node
// Unit tests for Model.js (the plugin's pure functions), runnable without a shell:
//   node tools/test-model.mjs
// Loads Model.js as plain JS (drops the .pragma line) and checks the derivations the cockpit
// and the bar rely on: status parsing, signal/staleness, evidence vocabulary, default
// selection, sibling ranking, doctor rows, and CLI error parsing.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import assert from "node:assert/strict";

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, "..", "Model.js"), "utf8").replace(".pragma library", "");
const exportsList = [
  "parseStatus", "signal", "daemonAgeMs", "evidence", "evidenceLabel", "checkStatusLabel",
  "defaultSelection", "siblingComparison", "integrityRows", "openTransactions", "capabilityRows",
  "parseCliError", "deltaSummary", "deltaCount", "operationKind", "operationLabel",
  "canCollapse", "canReturnTo", "isPrimeGeneration", "widgetSetting", "runningJobCount",
  "activeJob", "stateCounts", "fmtDuration", "shortHash", "shortAlias", "displayAlias", "jobLabel", "fmtBytes",
];
const M = {};
new Function("exports", source + ";" + exportsList.map((n) => `exports.${n}=${n};`).join(""))(M);

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
console.log(`${passed} passed${process.exitCode ? ", with failures" : ""}`);
