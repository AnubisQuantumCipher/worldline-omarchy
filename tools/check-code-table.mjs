#!/usr/bin/env node
// Fails, closed, when the plugin's code table does not cover its paired engine:
//   node tools/check-code-table.mjs                          Model.js against tools/engine-codes.json
//   node tools/check-code-table.mjs --model FILE --codes FILE  another Model.js, or another engine's list
//   node tools/check-code-table.mjs --release                 also require an immutable engine source
//
// tools/engine-codes.json is the paired engine's code list, made by tools/engine-codes.py from an
// engine commit (every WorldlineError code, the daemon's and client's own codes, the codes recorded
// on transactions, jobs and worlds, and the kernel's decisions and error names). The check fails when:
//   * the list's digest is not the digest of its own codes;
//   * a code of the list has no entry in Model.CODE_TABLE;
//   * an entry has no outcome class (refused, committed, unknown, record) or no advice;
//   * an entry names a code that is neither the engine's, one the plugin reports itself
//     (Model.PLUGIN_CODES), nor one the paired engine release is known to add (Model.PLANNED_CODES);
//   * Model.SUPPORTED_CODE_SET_SHA256, the digest the plugin accepts from a running engine, is not
//     the list's digest.
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const option = (name, fallback) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : fallback; };
const modelPath = option("--model", join(here, "..", "Model.js"));
const codesPath = option("--codes", join(here, "engine-codes.json"));

const problems = [];
let M = {};
try {
  const source = readFileSync(modelPath, "utf8").replace(".pragma library", "");
  const names = ["CODE_TABLE", "PLUGIN_CODES", "PLANNED_CODES", "SUPPORTED_CODE_SET_SHA256", "codeInfo"];
  new Function("exports", source + ";" + names.map((n) => `exports.${n}=typeof ${n}==="undefined"?undefined:${n};`).join(""))(M);
} catch (error) {
  problems.push(`Model.js does not load: ${error.message}`);
}
const list = JSON.parse(readFileSync(codesPath, "utf8"));
const codes = Array.isArray(list.codes) ? list.codes : [];
const digest = createHash("sha256").update([...new Set(codes)].sort().map((c) => c + "\n").join(""), "utf8").digest("hex");
if (codes.length === 0) problems.push(`${codesPath} lists no codes`);
if (list.codeSetSha256 !== digest) problems.push(`${codesPath}: codeSetSha256 ${list.codeSetSha256} is not the digest of its codes (${digest})`);

const table = M.CODE_TABLE && typeof M.CODE_TABLE === "object" ? M.CODE_TABLE : null;
if (!table) problems.push("Model.js has no CODE_TABLE");
else {
  const missing = codes.filter((code) => !Object.prototype.hasOwnProperty.call(table, code));
  if (missing.length) problems.push(`${missing.length} engine code(s) missing from Model.CODE_TABLE: ${missing.join(", ")}`);
  const own = new Set([...(M.PLUGIN_CODES || []), ...(M.PLANNED_CODES || [])]);
  const known = new Set(codes);
  for (const [code, entry] of Object.entries(table)) {
    if (!Array.isArray(entry) || !["refused", "committed", "unknown", "record"].includes(entry[0])) problems.push(`${code}: no outcome class`);
    else if (typeof entry[1] !== "string" || entry[1].trim().length < 30) problems.push(`${code}: no advice`);
    if (!known.has(code) && !own.has(code)) problems.push(`${code}: in the table but neither the engine's, the plugin's own, nor a planned code (a typo?)`);
  }
}
if (M.SUPPORTED_CODE_SET_SHA256 !== list.codeSetSha256)
  problems.push(`Model.SUPPORTED_CODE_SET_SHA256 is ${M.SUPPORTED_CODE_SET_SHA256}, the paired engine's list says ${list.codeSetSha256}`);

const engine = list.engine || {};
if (args.includes("--release")) {
  if (engine.source !== "git archive of the commit" || !/^[0-9a-f]{40}$/.test(String(engine.commit || "")))
    problems.push("release pairing is unresolved: regenerate from the reviewed engine commit with tools/engine-codes.py ENGINE --rev COMMIT --write");
}
if (problems.length) {
  for (const problem of problems) console.error(`check-code-table: ${problem}`);
  console.error(`check-code-table: FAILED against engine ${engine.version} ${String(engine.commit || "").slice(0, 12)} (${codes.length} codes)`);
  process.exit(1);
}
console.log(`check-code-table: all ${codes.length} codes of engine ${engine.version} ${String(engine.commit || "").slice(0, 12)} have an outcome class and advice; the plugin accepts code set ${list.codeSetSha256} (${engine.source || "source unspecified"})`);
