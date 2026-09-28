#!/usr/bin/env node
// Plain-text sink check for the plugin's QML, runnable without a shell or Qt:
//   node tools/check-plain-text.mjs            check every .qml file in the repository
//   node tools/check-plain-text.mjs --audit    also print every text sink it found
//   node tools/check-plain-text.mjs DIR        check another tree (used to prove it fails)
//
// Strings in this plugin come from the daemon, adapters, managed projects, and coding agents.
// Qt's default for Text and Label is AutoText, which promotes a string that looks like markup
// to rich text, and rich text can load resources (`<img src=…>`) inside the long-lived shell.
// The rules below keep every such string out of a markup renderer:
//
//   1. Every Text/Label declares `textFormat: Text.PlainText`, and every TextEdit/TextArea
//      declares `textFormat: TextEdit.PlainText`, whatever its text is today; a literal that
//      is edited into a binding later is covered before it exists.
//   2. No other text format appears anywhere: no RichText, StyledText, MarkdownText, or
//      AutoText, and no link handlers or Qt.openUrlExternally.
//   3. `placeholderText` is a constant string. Qt Quick Controls draws it with the style's
//      PlaceholderText, which is AutoText and cannot be changed from here (measured: Qt 6.11,
//      Basic and Fusion styles).
//   4. No Qt Quick Controls ToolTip. Its contentItem is an AutoText Text in every stock style.
//   5. An Image-family `source` is a constant.
//   6. A `text`/`tooltipText`/`message` binding on a type from outside this repository is
//      allowed only for the types audited below; a new external type has to be audited (and
//      added here) before it can receive a string.
//   7. A `notify-send` argv array passes every non-constant argument through
//      Model.notificationBody(): the Omarchy shell advertises body-markup and renders the
//      body as StyledText.
//
// The parser fails closed: anything it cannot read is an error, not a pass, and a tree with
// no QML files or no text elements is refused rather than reported clean.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { basename, dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const RICH_TYPES = new Set(["Text", "Label"]);                 // AutoText by default
const EDIT_TYPES = new Set(["TextEdit", "TextArea"]);          // take TextEdit.PlainText
const PLAIN_ONLY_TYPES = new Set(["TextInput", "TextField", "TextMetrics"]); // no markup path
// Omarchy shell (qs.Ui) components that receive strings from this plugin. Each renders the
// string it is given with `textFormat: Text.PlainText` (audited in try-omarchy-runtime 4.0.3:
// Button text/iconText/tooltipText, WidgetButton + BarIconButton text and the bar tooltip,
// OpticalGlyph, ConfirmDialog message and button labels).
const AUDITED_EXTERNAL = new Set(["Button", "BarIconButton", "WidgetButton", "ConfirmDialog"]);
const STRING_SINK_PROPS = new Set(["text", "tooltipText", "message", "iconText", "confirmText", "cancelText"]);
const IMAGE_TYPES = new Set(["Image", "AnimatedImage", "BorderImage", "IconImage", "AnimatedSprite"]);
const FORBIDDEN_IDENTIFIERS = new Set([
  "RichText", "StyledText", "AutoText", "MarkdownText",
  "linkActivated", "onLinkActivated", "linkHovered", "onLinkHovered", "hoveredLink",
  "openUrlExternally",
]);
const PLAIN_FORMAT = { rich: "Text.PlainText", edit: "TextEdit.PlainText" };

// ------------------------------------------------------------------ tokenizer
const CONTINUES_AFTER = new Set(["?", ":", "+", "-", "*", "/", "%", "&&", "||", "??", ".", "?.", ",", "===", "!==", "==", "!=", "<", ">", "<=", ">=", "=", "!", "(", "[", "=>"]);
const CONTINUES_BEFORE = new Set(["?", ":", "+", "-", "*", "/", "%", "&&", "||", "??", ".", "?.", "===", "!==", "==", "!=", "<", ">", "<=", ">=", ")", "]", "=>"]);
const REGEX_AFTER_WORDS = new Set(["return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else"]);
const OPERATORS = ["===", "!==", "=>", "==", "!=", "<=", ">=", "&&", "||", "??", "?.", "++", "--", "+=", "-=", "*=", "/="];

class ParseError extends Error {}

function tokenize(src, file) {
  const tokens = [];
  let i = 0, line = 1, nl = true;
  const err = (msg) => { throw new ParseError(`${file}:${line}: ${msg}`); };
  const push = (type, value, startLine) => { tokens.push({ type, value, line: startLine, nl }); nl = false; };
  const prevSignificant = () => tokens[tokens.length - 1];
  while (i < src.length) {
    const c = src[i];
    if (c === "\n") { line++; nl = true; i++; continue; }
    if (c === " " || c === "\t" || c === "\r" || c === "\f" || c === "\v" || c === "\uFEFF") { i++; continue; }
    if (c === "/" && src[i + 1] === "/") { while (i < src.length && src[i] !== "\n") i++; continue; }
    if (c === "/" && src[i + 1] === "*") {
      const end = src.indexOf("*/", i + 2);
      if (end < 0) err("unterminated block comment");
      for (let k = i; k < end; k++) if (src[k] === "\n") { line++; nl = true; }
      i = end + 2; continue;
    }
    const startLine = line;
    if (c === '"' || c === "'") {
      let j = i + 1, value = "";
      while (j < src.length && src[j] !== c) {
        if (src[j] === "\\") { value += src[j + 1]; if (src[j + 1] === "\n") line++; j += 2; continue; }
        if (src[j] === "\n") err("newline in string literal");
        value += src[j]; j++;
      }
      if (j >= src.length) err("unterminated string literal");
      push("string", value, startLine); i = j + 1; continue;
    }
    if (c === "`") {
      let j = i + 1, depth = 0;
      while (j < src.length) {
        if (src[j] === "\\") { j += 2; continue; }
        if (src[j] === "\n") line++;
        if (depth === 0 && src[j] === "`") break;
        if (src[j] === "$" && src[j + 1] === "{") { depth++; j += 2; continue; }
        if (depth > 0 && src[j] === "}") depth--;
        j++;
      }
      if (j >= src.length) err("unterminated template literal");
      push("template", src.slice(i + 1, j), startLine); i = j + 1; continue;
    }
    if (/[A-Za-z_$]/.test(c)) {
      let j = i + 1;
      while (j < src.length && /[A-Za-z0-9_$]/.test(src[j])) j++;
      push("ident", src.slice(i, j), startLine); i = j; continue;
    }
    if (/[0-9]/.test(c) || (c === "." && /[0-9]/.test(src[i + 1] || ""))) {
      let j = i + 1;
      while (j < src.length && /[0-9A-Za-z_.]/.test(src[j])) j++;
      push("number", src.slice(i, j), startLine); i = j; continue;
    }
    if (c === "/") {
      const prev = prevSignificant();
      const regexAllowed = !prev
        || (prev.type === "punct" && !/^[)\]}]$/.test(prev.value))
        || (prev.type === "ident" && REGEX_AFTER_WORDS.has(prev.value));
      if (regexAllowed) {
        let j = i + 1, inClass = false;
        while (j < src.length) {
          if (src[j] === "\\") { j += 2; continue; }
          if (src[j] === "\n") err("newline in regular expression literal");
          if (src[j] === "[") inClass = true;
          else if (src[j] === "]") inClass = false;
          else if (src[j] === "/" && !inClass) break;
          j++;
        }
        j++;
        while (j < src.length && /[a-z]/.test(src[j])) j++;
        push("regex", src.slice(i, j), startLine); i = j; continue;
      }
    }
    const op = OPERATORS.find((o) => src.startsWith(o, i) && !(o === "?." && /[0-9]/.test(src[i + 2] || "")));
    if (op) { push("punct", op, startLine); i += op.length; continue; }
    push("punct", c, startLine); i++;
  }
  return tokens;
}

// ------------------------------------------------------------------ parser
// A QML document is a tree of objects. Each object records its member bindings (name ->
// {line, tokens}); JavaScript blocks (handlers, functions) are skipped as balanced braces.
function isTypeName(name) { const last = name.split(".").pop(); return /^[A-Z]/.test(last); }

function parseDocument(tokens, file) {
  let p = 0;
  const objects = [];
  const peek = (k = 0) => tokens[p + k];
  const err = (msg, tok = peek()) => { throw new ParseError(`${file}:${tok ? tok.line : "EOF"}: ${msg}`); };
  const expect = (value) => { const t = peek(); if (!t || t.value !== value) err(`expected '${value}', found '${t ? t.value : "EOF"}'`); p++; return t; };

  function readChain() {           // ident(.ident)*
    const first = peek();
    if (!first || first.type !== "ident") err("expected an identifier");
    let name = first.value; p++;
    while (peek() && peek().value === "." && peek(1) && peek(1).type === "ident" && !peek(1).nl) { name += "." + peek(1).value; p += 2; }
    return { name, line: first.line };
  }
  function chainEndsAt(k) {        // index just past an ident(.ident)* chain starting at p+k
    if (!peek(k) || peek(k).type !== "ident") return -1;
    let j = k + 1;
    while (peek(j) && peek(j).value === "." && peek(j + 1) && peek(j + 1).type === "ident") j += 2;
    return j;
  }
  function skipBalanced(open, close) {
    expect(open);
    let depth = 1;
    while (depth > 0) {
      const t = peek(); if (!t) err(`unbalanced '${open}'`);
      if (t.type === "punct" && t.value === open) depth++;
      else if (t.type === "punct" && t.value === close) depth--;
      p++;
    }
  }
  // An object declaration at the cursor: `Type {` or `Type on prop {`.
  function objectStartAt(k = 0) {
    const end = chainEndsAt(k);
    if (end < 0) return false;
    const name = tokens.slice(p + k, p + end).map((t) => t.value).join("");
    if (!isTypeName(name)) return false;
    if (peek(end) && peek(end).value === "{") return true;
    return !!(peek(end) && peek(end).value === "on" && peek(end + 1) && peek(end + 1).type === "ident" && peek(end + 2) && peek(end + 2).value === "{");
  }

  function parseObject(parent) {
    const { name: type, line } = readChain();
    if (peek().value === "on") { p++; readChain(); }
    const object = { type, line, file, members: new Map(), parent };
    objects.push(object);
    expect("{");
    parseMembers(object, "");
    expect("}");
    return object;
  }

  function addMember(object, name, entry) {
    if (!object.members.has(name)) object.members.set(name, entry);
    else object.members.get(name).duplicate = true;
  }

  function parseMembers(object, prefix) {
    for (;;) {
      const t = peek();
      if (!t) err("unexpected end of file inside an object");
      if (t.value === "}") return;
      if (t.value === ";" || t.value === ",") { p++; continue; }
      if (t.type !== "ident") err(`unexpected '${t.value}' in an object body`);
      const declares = peek(1) && peek(1).value !== ":";  // `property: "x"` is a binding (NumberAnimation.property)
      if (["readonly", "required", "default", "property"].includes(t.value) && declares && prefix === "") { parseProperty(object); continue; }
      if (t.value === "signal" && declares) { p++; readChain(); if (peek() && peek().value === "(") skipBalanced("(", ")"); continue; }
      if (t.value === "function" && declares) { p++; readChain(); skipBalanced("(", ")"); if (peek().value === ":") { p++; readChain(); } skipBalanced("{", "}"); continue; }
      if (t.value === "enum" && declares) { p++; readChain(); skipBalanced("{", "}"); continue; }
      if (t.value === "component" && peek(1) && peek(1).type === "ident" && peek(2) && peek(2).value === ":") { p += 3; parseObject(object); continue; }
      if (objectStartAt()) { parseObject(object); continue; }
      const { name, line } = readChain();
      const full = prefix ? prefix + "." + name : name;
      if (peek() && peek().value === "{") { p++; parseMembers(object, full); expect("}"); continue; }  // grouped: anchors { … }
      expect(":");
      addMember(object, full, parseValue(object, line));
    }
  }

  function parseProperty(object) {
    while (["readonly", "required", "default"].includes(peek().value)) p++;
    if (peek().value !== "property") err("expected 'property'");
    p++;
    readChain();                                        // type
    if (peek().value === "<") { while (peek() && peek().value !== ">") p++; expect(">"); }
    const { name, line } = readChain();
    if (peek() && peek().value === ":") { p++; addMember(object, name, { ...parseValue(object, line), declared: true }); }
    else addMember(object, name, { line, tokens: [], declared: true, unset: true });
  }

  // A binding value: an object, a JS block, a list, or an expression that ends at a newline
  // (unless an operator continues it), a ';', or the enclosing '}'.
  function parseValue(object, line) {
    if (objectStartAt()) { const child = parseObject(object); return { line, tokens: [], object: child }; }
    const start = p;
    const open = [];                                     // stack of '(' '[' '{'
    const pairs = { ")": "(", "]": "[", "}": "{" };
    for (;;) {
      const t = peek();
      if (!t) { if (open.length === 0) break; err("unexpected end of file in a binding"); }
      if (open.length === 0 && p > start) {
        if (t.value === "}" || t.value === ";") break;
        const prev = tokens[p - 1];
        if (t.nl && !(prev.type === "punct" && CONTINUES_AFTER.has(prev.value)) && !(t.type === "punct" && CONTINUES_BEFORE.has(t.value))) break;
      }
      if (t.type === "punct" && (t.value === "(" || t.value === "[" || t.value === "{")) { open.push(t.value); p++; continue; }
      if (t.type === "punct" && (t.value === ")" || t.value === "]" || t.value === "}")) {
        if (open.length === 0) break;
        if (open.pop() !== pairs[t.value]) err(`mismatched '${t.value}' in a binding`);
        p++; continue;
      }
      // list bindings may hold objects: `states: [ State { … }, State { … } ]`
      if (open[open.length - 1] === "[" && ["[", ","].includes(tokens[p - 1].value) && objectStartAt()) { parseObject(object); continue; }
      p++;
    }
    if (p === start) err("empty binding");
    return { line, tokens: tokens.slice(start, p) };
  }

  if (peek() && peek().value === "pragma") { p++; readChain(); }
  while (peek() && peek().value === "import") {
    const importLine = peek().line;
    p++;
    while (peek() && peek().line === importLine) p++;
  }
  if (!objectStartAt()) err("expected the root object");
  const root = parseObject(null);
  if (peek()) err(`unexpected '${peek().value}' after the root object`);
  return { root, objects };
}

// ------------------------------------------------------------------ expression classes
// "constant": only string/number literals joined by `+`, possibly chosen by a ternary whose
// branches are themselves constant (the condition may be anything).
function isConstant(tokens) {
  let ts = tokens.slice();
  const stripParens = () => {
    while (ts.length >= 2 && ts[0].type === "punct" && ts[0].value === "(" && closesAtEnd(ts, 0)) ts = ts.slice(1, -1);
  };
  stripParens();
  if (ts.length === 0) return false;
  let depth = 0, q = -1;
  for (let k = 0; k < ts.length; k++) {
    const v = ts[k].type === "punct" ? ts[k].value : null;
    if (v === "(" || v === "[" || v === "{") depth++;
    else if (v === ")" || v === "]" || v === "}") depth--;
    else if (v === "?" && depth === 0 && q < 0) q = k;
  }
  if (q >= 0) {
    let nest = 0, colon = -1; depth = 0;
    for (let k = q + 1; k < ts.length; k++) {
      const v = ts[k].type === "punct" ? ts[k].value : null;
      if (v === "(" || v === "[" || v === "{") depth++;
      else if (v === ")" || v === "]" || v === "}") depth--;
      else if (depth === 0 && v === "?") nest++;
      else if (depth === 0 && v === ":") { if (nest === 0) { colon = k; break; } nest--; }
    }
    if (colon < 0) return false;
    return isConstant(ts.slice(q + 1, colon)) && isConstant(ts.slice(colon + 1));
  }
  for (let k = 0; k < ts.length; k++) {
    const expectOperand = k % 2 === 0;
    if (expectOperand && !(ts[k].type === "string" || ts[k].type === "number")) return false;
    if (!expectOperand && !(ts[k].type === "punct" && ts[k].value === "+")) return false;
  }
  return ts.length % 2 === 1;
}
function exprText(tokens) {
  let out = "";
  tokens.forEach((t, k) => {
    const v = t.type === "string" ? JSON.stringify(t.value) : t.type === "template" ? "`" + t.value + "`" : t.value;
    const prev = tokens[k - 1];
    const tight = !prev
      || (t.type === "punct" && [".", "?.", ",", ")", "]"].includes(t.value))
      || (prev.type === "punct" && [".", "?.", "(", "[", "!"].includes(prev.value))
      || (t.value === "(" && prev.type === "ident");
    out += (tight ? "" : " ") + v;
  });
  return out;
}

// ------------------------------------------------------------------ rules
// True when the '(' at tokens[open] is closed by the last token.
function closesAtEnd(tokens, open) {
  let depth = 0;
  for (let q = open; q < tokens.length; q++) {
    if (tokens[q].type !== "punct") continue;
    if (tokens[q].value === "(") depth++;
    else if (tokens[q].value === ")" && --depth === 0) return q === tokens.length - 1;
  }
  return false;
}

// `["notify-send", …]`: every element is a constant or exactly `Model.notificationBody(…)`.
function notifyProblems(tokens, rel) {
  const out = [];
  for (let k = 1; k < tokens.length; k++) {
    if (!(tokens[k].type === "string" && tokens[k].value === "notify-send" && tokens[k - 1].value === "[")) continue;
    const elements = [];
    let depth = 0, element = [], closed = false;
    for (let j = k; j < tokens.length; j++) {
      const t = tokens[j];
      const v = t.type === "punct" ? t.value : null;
      if (depth === 0 && (v === "," || v === "]")) { if (element.length) elements.push(element); element = []; if (v === "]") { closed = true; break; } continue; }
      if (v === "(" || v === "[" || v === "{") depth++;
      else if (v === ")" || v === "]" || v === "}") depth--;
      element.push(t);
    }
    if (!closed) { out.push(`${rel}:${tokens[k].line}: unterminated notify-send argv`); continue; }
    for (const e of elements) {
      const wrapped = e.length >= 5 && exprText(e.slice(0, 4)) === "Model.notificationBody(" && closesAtEnd(e, 3);
      if (!isConstant(e) && !wrapped)
        out.push(`${rel}:${e[0].line}: notify-send argument is not a constant and not Model.notificationBody(…) (the shell renders notification bodies as StyledText): ${exprText(e)}`);
    }
  }
  return out;
}

function listQml(dir) {
  const out = [];
  for (const name of readdirSync(dir).sort()) {
    if (name === ".git" || name === "node_modules" || name === "dist") continue;
    const path = join(dir, name);
    if (statSync(path).isDirectory()) out.push(...listQml(path));
    else if (name.endsWith(".qml")) out.push(path);
  }
  return out;
}

function check(dir) {
  const files = listQml(dir);
  const problems = [];
  const sinks = [];
  if (files.length === 0) return { files, problems: [`${dir}: no .qml files found — refusing to report a clean tree`], sinks };
  const localTypes = new Set(files.map((f) => basename(f, ".qml")));
  const docs = [];
  for (const file of files) {
    const rel = relative(dir, file) || basename(file);
    try {
      const tokens = tokenize(readFileSync(file, "utf8"), rel);
      for (const t of tokens) if (t.type === "ident" && FORBIDDEN_IDENTIFIERS.has(t.value))
        problems.push(`${rel}:${t.line}: '${t.value}' is not allowed (rich text or link handling)`);
      problems.push(...notifyProblems(tokens, rel));
      docs.push({ rel, ...parseDocument(tokens, rel) });
    } catch (error) {
      if (!(error instanceof ParseError)) throw error;
      problems.push(`parse error (fail closed): ${error.message}`);
    }
  }
  let textElements = 0;
  for (const { rel, objects } of docs) {
    for (const o of objects) {
      const type = o.type.split(".").pop();
      const at = `${rel}:${o.line}`;
      const fmt = o.members.get("textFormat");
      const fmtText = fmt ? exprText(fmt.tokens) : null;
      const text = o.members.get("text");
      const kind = RICH_TYPES.has(type) ? "rich" : EDIT_TYPES.has(type) ? "edit" : null;
      if (kind) {
        textElements++;
        if (!fmt) problems.push(`${at}: ${o.type} has no textFormat (needs textFormat: ${PLAIN_FORMAT[kind]})`);
        else if (fmtText !== PLAIN_FORMAT[kind]) problems.push(`${rel}:${fmt.line}: ${o.type} textFormat is '${fmtText}', must be ${PLAIN_FORMAT[kind]}`);
      } else if (fmt && fmtText !== PLAIN_FORMAT.rich && fmtText !== PLAIN_FORMAT.edit) {
        problems.push(`${rel}:${fmt.line}: ${o.type} textFormat is '${fmtText}', only PlainText is allowed`);
      }
      const placeholder = o.members.get("placeholderText");
      if (placeholder && !isConstant(placeholder.tokens))
        problems.push(`${rel}:${placeholder.line}: ${o.type}.placeholderText is not a constant string (the style's placeholder renders AutoText): ${exprText(placeholder.tokens)}`);
      if (type === "ToolTip") problems.push(`${at}: Qt Quick Controls ToolTip renders AutoText; use the shell Button's tooltipText`);
      const attached = [...o.members.keys()].filter((name) => name.startsWith("ToolTip."));
      if (attached.length) problems.push(`${rel}:${o.members.get(attached[0]).line}: attached ${attached.join(", ")}: the Qt Quick Controls ToolTip renders AutoText; use the shell Button's tooltipText`);
      if (IMAGE_TYPES.has(type)) {
        const source = o.members.get("source");
        if (source && !isConstant(source.tokens)) problems.push(`${rel}:${source.line}: ${o.type}.source is not a constant: ${exprText(source.tokens)}`);
      }
      const external = !kind && !PLAIN_ONLY_TYPES.has(type) && !localTypes.has(o.type);
      for (const [name, member] of o.members) {
        if (!STRING_SINK_PROPS.has(name) || member.declared || member.object) continue;
        if (external && !AUDITED_EXTERNAL.has(type))
          problems.push(`${rel}:${member.line}: ${o.type}.${name} receives a string but ${o.type} is not an audited plain-text component`);
      }
      const record = (prop, member, how) => sinks.push({
        at: `${rel}:${member.line}`, element: o.type, prop,
        value: member.tokens.length === 0 ? "(declared, no binding)" : isConstant(member.tokens) ? "constant" : "dynamic",
        how, expr: exprText(member.tokens),
      });
      if (kind) {
        if (text) record("text", text, fmt ? fmtText : "MISSING");
        else sinks.push({ at, element: o.type, prop: "text", value: "(none)", how: fmt ? fmtText : "MISSING", expr: "" });
      } else {
        for (const [name, member] of o.members) {
          if (member.declared || member.object) continue;
          if (STRING_SINK_PROPS.has(name) || name === "placeholderText" || (localTypes.has(o.type) && ["label", "glyph", "title", "hint", "k", "v"].includes(name))) {
            const how = localTypes.has(o.type) ? `local ${o.type} (checked in its own file)`
              : PLAIN_ONLY_TYPES.has(type) ? (name === "placeholderText" ? "style placeholder (constant required)" : "plain-only input")
              : AUDITED_EXTERNAL.has(type) ? "shell component, PlainText (audited)" : "UNAUDITED";
            record(name, member, how);
          }
        }
      }
    }
  }
  if (docs.length === files.length && textElements === 0) problems.push(`${dir}: no Text/Label/TextEdit/TextArea found — refusing to report a clean tree`);
  return { files, problems, sinks, textElements };
}

// ------------------------------------------------------------------ main
const args = process.argv.slice(2);
const audit = args.includes("--audit");
const target = args.find((a) => !a.startsWith("--")) || join(dirname(fileURLToPath(import.meta.url)), "..");
const { files, problems, sinks, textElements } = check(target);
if (audit) {
  for (const s of sinks) console.log(`${s.at}\t${s.element}.${s.prop}\t${s.value}\t${s.how}\t${s.expr.slice(0, 140)}`);
  console.log("");
}
console.log(`scanned ${files.length} QML file(s): ${files.map((f) => relative(target, f)).join(", ")}`);
console.log(`${textElements ?? 0} Text/Label/TextEdit/TextArea element(s), ${sinks.length} string sink(s)`);
if (problems.length) {
  for (const problem of problems) console.log(`  FAIL  ${problem}`);
  console.log(`${problems.length} problem(s)`);
  process.exitCode = 1;
} else {
  console.log("plain-text sinks: OK");
}
