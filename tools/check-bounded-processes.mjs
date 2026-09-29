#!/usr/bin/env node
// Bounded-process check for the plugin's QML, runnable without a shell or Qt:
//   node tools/check-bounded-processes.mjs         check every .qml file in the repository
//   node tools/check-bounded-processes.mjs DIR     check another tree (used to prove it fails)
//
// The shell is long-lived, and a process this plugin starts can print text an agent controls
// (an agent's stderr, a mission, a path). Every Quickshell `Process` is therefore bounded in
// bytes and in time (omarchy-plugin-marketplace#7900):
//
//   1. A Process has an `id`.
//   2. Its stdout and stderr parsers are `StdioCollector`s with `waitForEnd: false` and an
//      `onDataChanged` handler, so every read is measured as it arrives. `SplitParser` is refused
//      anywhere (it buffers an unterminated line without limit), and so is `waitForEnd: true`
//      (nothing can measure a stream that is only seen once it has ended).
//   3. The file compares a collector's `data.byteLength` against a limit, and stops the process
//      with `<id>.signal(9)`.
//   4. A `Timer` stops it: some Timer's body contains `<id>.signal(9)`, or calls a function of
//      the same file whose body does.
//
// The check fails closed: a file whose braces do not balance is an error, and a tree with no
// Process at all is refused rather than reported clean.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

// Comments and string contents blanked (same length), so braces and names inside them count for nothing.
function blank(src) {
  let out = "";
  let i = 0;
  while (i < src.length) {
    const c = src[i];
    const next = src[i + 1];
    if (c === "/" && next === "/") {
      while (i < src.length && src[i] !== "\n") { out += " "; i++; }
    } else if (c === "/" && next === "*") {
      out += "  "; i += 2;
      while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) { out += src[i] === "\n" ? "\n" : " "; i++; }
      if (i >= src.length) throw new Error("unterminated block comment");
      out += "  "; i += 2;
    } else if (c === '"' || c === "'" || c === "`") {
      out += c; i++;
      while (i < src.length && src[i] !== c) {
        if (src[i] === "\\") { out += "  "; i += 2; continue; }
        if (src[i] === "\n" && c !== "`") throw new Error("unterminated string");
        out += src[i] === "\n" ? "\n" : " "; i++;
      }
      if (i >= src.length) throw new Error("unterminated string");
      out += c; i++;
    } else {
      out += c; i++;
    }
  }
  return out;
}

// The index of the brace closing the one at `open`.
function closing(text, open) {
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === "{") depth++;
    else if (text[i] === "}") { depth--; if (depth === 0) return i; }
  }
  throw new Error(`unbalanced braces from offset ${open}`);
}

// Every `Name {` object or `function name(...) {` body: [{ name, start, end, body }].
function blocks(text, pattern) {
  const found = [];
  for (const match of text.matchAll(pattern)) {
    const open = text.indexOf("{", match.index + match[0].length - 1);
    const end = closing(text, open);
    found.push({ name: match[1], start: open, end, body: text.slice(open + 1, end) });
  }
  return found;
}

// The text of a block at its own nesting level: children blanked except their own braces, so
// `stdout: StdioCollector {` still reads as one. Same length as the input, so offsets carry over.
function topLevel(body) {
  let out = "";
  let depth = 0;
  for (const c of body) {
    if (c === "{") { out += depth === 0 ? c : " "; depth++; continue; }
    if (c === "}") { depth--; out += depth === 0 ? c : " "; continue; }
    out += depth === 0 ? c : (c === "\n" ? "\n" : " ");
  }
  return out;
}

function lineOf(text, offset) { return text.slice(0, offset).split("\n").length; }

function listQml(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    if (entry.startsWith(".") || entry === "node_modules") continue;
    const path = join(dir, entry);
    const info = statSync(path);
    if (info.isDirectory()) out.push(...listQml(path));
    else if (entry.endsWith(".qml")) out.push(path);
  }
  return out.sort();
}

function check(dir) {
  const files = listQml(dir);
  const problems = [];
  const processes = [];
  let parsers = 0;
  if (files.length === 0) problems.push(`${dir}: no QML files — refusing to report a clean tree`);
  for (const file of files) {
    const rel = relative(dir, file);
    let text;
    try { text = blank(readFileSync(file, "utf8")); closing(`{${text}}`, 0); }
    catch (error) { problems.push(`${rel}: cannot parse (${error.message})`); continue; }
    if (/\bSplitParser\b/.test(text)) problems.push(`${rel}:${lineOf(text, text.search(/\bSplitParser\b/))}: SplitParser buffers an unterminated line without limit`);
    for (const m of text.matchAll(/\bwaitForEnd\s*:\s*true\b/g)) problems.push(`${rel}:${lineOf(text, m.index)}: waitForEnd: true cannot be measured before the stream ends`);
    const functions = new Map(blocks(text, /\bfunction\s+([A-Za-z_]\w*)\s*\([^)]*\)\s*\{/g).map((f) => [f.name, f.body]));
    const timers = blocks(text, /\b(Timer)\s*\{/g);
    const measured = /\.data\.byteLength\s*>/.test(text);
    for (const proc of blocks(text, /\b(Process)\s*\{/g)) {
      const at = `${rel}:${lineOf(text, proc.start)}`;
      const own = topLevel(proc.body);
      const id = (own.match(/(?:^|[\s;])id\s*:\s*([A-Za-z_]\w*)/) || [])[1];
      if (!id) { problems.push(`${at}: Process without an id`); continue; }
      processes.push(`${rel}:${id}`);
      for (const m of own.matchAll(/\b(stdout|stderr)\s*:\s*([A-Za-z_][\w.]*)\s*\{/g)) {
        const open = proc.start + 1 + m.index + m[0].length - 1;
        const parser = text.slice(open + 1, closing(text, open));
        const where = `${rel}:${lineOf(text, open)}`;
        parsers++;
        if (m[2] !== "StdioCollector") { problems.push(`${where}: ${id}.${m[1]} is a ${m[2]}; only a measured StdioCollector is allowed`); continue; }
        if (!/\bwaitForEnd\s*:\s*false\b/.test(parser)) problems.push(`${where}: ${id}.${m[1]} must set waitForEnd: false`);
        if (!/\bonDataChanged\s*:/.test(parser)) problems.push(`${where}: ${id}.${m[1]} has no onDataChanged measurement`);
      }
      if (/\b(stdout|stderr)\s*:/.test(own) && !measured) problems.push(`${at}: ${id}: no collector's data.byteLength is compared against a limit`);
      const stop = new RegExp(`\\b${id}\\.signal\\(\\s*9\\s*\\)`);
      if (!stop.test(text)) { problems.push(`${at}: ${id} is never stopped with ${id}.signal(9)`); continue; }
      const stoppers = new Set([...functions].filter(([, body]) => stop.test(body)).map(([name]) => name));
      const deadline = timers.some((timer) =>
        stop.test(timer.body) || [...timer.body.matchAll(/\b([A-Za-z_]\w*)\s*\(/g)].some((call) => stoppers.has(call[1])));
      if (!deadline) problems.push(`${at}: no Timer stops ${id} (a deadline must call ${id}.signal(9), directly or through a function)`);
    }
  }
  if (files.length && processes.length === 0 && problems.length === 0) problems.push(`${dir}: no Process found — refusing to report a clean tree`);
  return { files, problems, processes, parsers };
}

const args = process.argv.slice(2);
const target = args.find((a) => !a.startsWith("--")) || join(dirname(fileURLToPath(import.meta.url)), "..");
const { files, problems, processes, parsers } = check(target);
console.log(`scanned ${files.length} QML file(s)`);
console.log(`${processes.length} Process(es): ${processes.join(", ") || "none"}; ${parsers} output parser(s) checked`);
if (problems.length) {
  for (const problem of problems) console.log(`  FAIL  ${problem}`);
  console.log(`${problems.length} problem(s)`);
  process.exitCode = 1;
} else {
  console.log("bounded processes: OK");
}
