.pragma library

// Pure helpers for the WORLDLINE plugin. No QML state lives here: every function takes the
// engine's data and returns a value, so the surfaces stay a rendering of daemon facts.
//
// Vocabulary kept distinct on purpose:
//   world lifecycle  MUTABLE FINALIZING VALID DEGRADED DEAD ARCHIVED COLLAPSED  (engine)
//   evidence         PASS FAIL UNASSESSED UNAVAILABLE STALE                     (derived here)
// An evidence label never stands in for a lifecycle state and vice versa.

var STATE_ORDER = ["VALID", "MUTABLE", "FINALIZING", "DEGRADED", "DEAD", "ARCHIVED", "COLLAPSED"]
var STALE_AFTER_MS = 10000

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// ------------------------------------------------------------------ status

// The daemon publishes exactly nine top-level fields; anything else is not a status document.
function parseStatus(raw) {
  var parsed
  try { parsed = JSON.parse(String(raw || "")) } catch (error) { return null }
  if (!isObject(parsed) || parsed.schemaVersion !== 1) return null
  var required = ["daemon", "prime", "activeWorld", "worlds", "jobs", "capabilities", "lastReceipt", "ghostRecommendation"]
  for (var i = 0; i < required.length; i++) if (parsed[required[i]] === undefined) return null
  if (!Array.isArray(parsed.worlds) || !Array.isArray(parsed.jobs)) return null
  return parsed
}

function daemonAgeMs(status, nowMs) {
  if (!status || !status.daemon || !status.daemon.publishedAt) return Infinity
  var stamp = Date.parse(status.daemon.publishedAt)
  return isFinite(stamp) ? Math.max(0, nowMs - stamp) : Infinity
}

// "live" while the heartbeat is fresh; "stale" when it is older than STALE_AFTER_MS;
// "offline" when no document has ever been read or the daemon wrote STOPPED.
function signal(status, nowMs) {
  if (!status) return "offline"
  if (status.daemon && status.daemon.state === "STOPPED") return "offline"
  return daemonAgeMs(status, nowMs) > STALE_AFTER_MS ? "stale" : "live"
}

// ------------------------------------------------------------------ worlds

function worldByInstance(worlds, instanceId) {
  for (var i = 0; i < worlds.length; i++) if (worlds[i].instanceId === instanceId) return worlds[i]
  return null
}

function worldByContent(worlds, contentId) {
  for (var i = 0; i < worlds.length; i++) if (worlds[i].id === contentId) return worlds[i]
  return null
}

function worldIndexByAlias(worlds, aliasOrInstance) {
  for (var i = 0; i < worlds.length; i++)
    if (worlds[i].alias === aliasOrInstance || worlds[i].instanceId === aliasOrInstance) return i
  return -1
}

function isPrimeGeneration(world) {
  return !!world && String(world.alias || "").indexOf("prime-") === 0
}

function isRunning(world) {
  return !!world && (world.state === "MUTABLE" || world.state === "FINALIZING")
}

function isTerminal(world) {
  return !!world && !isRunning(world)
}

function canCollapse(world) {
  return !!world && world.state === "VALID" && !isPrimeGeneration(world)
}

// The engine's return.select accepts ARCHIVED, COLLAPSED, or VALID worlds.
function canReturnTo(world) {
  return !!world && (world.state === "ARCHIVED" || world.state === "COLLAPSED" || world.state === "VALID")
}

function displayAlias(world, status, primeLabel) {
  if (!world) return "—"
  if (status && status.prime && world.instanceId === status.prime.instanceId) return primeLabel || "PRIME"
  return String(world.alias || "—")
}

function shortAlias(world, status, primeLabel) {
  var alias = displayAlias(world, status, primeLabel)
  if (alias.indexOf("prime-") === 0 && alias.length > 16) return "prime-" + alias.substring(6, 14)
  if (alias.indexOf("return-") === 0 && alias.length > 24) return alias.substring(0, 22) + "…"
  return alias
}

function shortHash(value) {
  if (!value || value === "—") return "—"
  var text = String(value).replace("sha256:", "").replace("WL:", "")
  return text.length > 16 ? text.substring(0, 12) + "…" : text
}

function shortId(value, length) {
  var text = String(value || "")
  return text.length > (length || 8) ? text.substring(0, length || 8) : text
}

// Which world the cockpit should select when it opens: the active world if it is not PRIME,
// else the newest world that can still do something (VALID first, then running), else PRIME.
function defaultSelection(status) {
  if (!status || !Array.isArray(status.worlds) || status.worlds.length === 0) return -1
  var worlds = status.worlds
  var active = String(status.activeWorld || "PRIME")
  if (active !== "PRIME") {
    var index = worldIndexByAlias(worlds, active)
    if (index >= 0) return index
  }
  var best = -1
  var bestBorn = ""
  for (var i = 0; i < worlds.length; i++) {
    var world = worlds[i]
    if (isPrimeGeneration(world)) continue
    var rank = world.state === "VALID" ? 2 : (isRunning(world) ? 1 : 0)
    if (rank === 0) continue
    var born = String(world.born || "")
    if (best < 0 || rank > bestRank(worlds[best]) || (rank === bestRank(worlds[best]) && born > bestBorn)) {
      best = i
      bestBorn = born
    }
  }
  if (best >= 0) return best
  if (status.prime) {
    var primeIndex = worldIndexByAlias(worlds, status.prime.instanceId)
    if (primeIndex >= 0) return primeIndex
  }
  return 0
}

function bestRank(world) {
  return world.state === "VALID" ? 2 : (isRunning(world) ? 1 : 0)
}

// ---------------------------------------------------------------- evidence

// Evidence for one world, derived from its checks only. The lifecycle state is reported
// separately. `stale` wins because retained data must never read as live proof.
function evidence(world, stale) {
  if (stale) return { state: "STALE", detail: "daemon heartbeat is stale; retained data", gaps: 0 }
  if (!world) return { state: "UNASSESSED", detail: "no world", gaps: 0 }
  var checks = Array.isArray(world.checks) ? world.checks : []
  if (checks.length === 0) return { state: "UNASSESSED", detail: isRunning(world) ? "not finalized yet" : "no checks recorded", gaps: 0 }
  var required = 0, requiredFailed = 0, optionalFailed = 0, unavailable = 0, other = 0
  for (var i = 0; i < checks.length; i++) {
    var status = String(checks[i].status || "")
    if (checks[i].required) required++
    if (status === "PASS") continue
    if (status === "FAIL") { if (checks[i].required) requiredFailed++; else optionalFailed++ }
    else if (status === "UNAVAILABLE") unavailable++
    else other++
  }
  // FAIL means a REQUIRED check failed (the engine's own bar for VALID). An optional failure
  // is reported as a gap on a PASS, which is exactly what makes the engine's risk MEDIUM.
  if (requiredFailed > 0) return { state: "FAIL", detail: requiredFailed + " required check" + (requiredFailed === 1 ? "" : "s") + " failed" + (optionalFailed ? ", " + optionalFailed + " optional" : ""), gaps: optionalFailed }
  if (unavailable > 0) return { state: "UNAVAILABLE", detail: unavailable + " check(s) could not run", gaps: optionalFailed }
  if (other > 0) return { state: "UNASSESSED", detail: other + " check(s) not assessed", gaps: optionalFailed }
  var detail = (required ? required + " required" : "no required checks") + " passed"
  if (optionalFailed > 0) detail += " · " + optionalFailed + " optional check" + (optionalFailed === 1 ? "" : "s") + " failed (risk stays MEDIUM)"
  return { state: "PASS", detail: detail, gaps: optionalFailed }
}

function evidenceLabel(result) {
  if (!result) return "UNASSESSED"
  return result.state + (result.gaps > 0 && result.state === "PASS" ? " · " + result.gaps + " GAP" + (result.gaps === 1 ? "" : "S") : "")
}

function checkStatusLabel(check) {
  var status = String((check && check.status) || "")
  if (status === "PASS" || status === "FAIL" || status === "UNAVAILABLE") return status
  return "UNASSESSED"
}

function stateTone(state) {
  // Names the palette role; the QML side maps role -> Color.*
  if (state === "VALID") return "accent"
  if (state === "DEGRADED" || state === "DEAD") return "urgent"
  if (state === "MUTABLE" || state === "FINALIZING") return "foreground"
  return "muted"
}

function evidenceTone(state) {
  if (state === "PASS") return "accent"
  if (state === "FAIL") return "urgent"
  return "muted"
}

function evidenceGlyph(state) {
  // Text cue beside the color so the badge reads without color vision.
  if (state === "PASS") return "✓"
  if (state === "FAIL") return "✗"
  if (state === "STALE") return "⌛"
  if (state === "UNAVAILABLE") return "⊘"
  return "○"
}

function riskTone(label) {
  if (label === "LOW") return "accent"
  if (label === "HIGH") return "urgent"
  return "foreground"
}

// ------------------------------------------------------------------ delta

function deltaCount(world) {
  var delta = world && isObject(world.delta) ? world.delta : {}
  // The status document caps long file lists (engine 1.2.0) and says so; the count is the total.
  if (delta.truncated && isFinite(Number(delta.total))) return Number(delta.total)
  if (Array.isArray(delta.files)) return delta.files.length
  var files = Number(delta.files)
  return isFinite(files) ? files : 0
}

function deltaSummary(world) {
  var delta = world && isObject(world.delta) ? world.delta : {}
  return {
    added: Number(delta.added || 0),
    modified: Number(delta.modified || 0),
    deleted: Number(delta.deleted || 0),
    files: deltaCount(world)
  }
}

function operationLabel(operation) {
  if (typeof operation === "string") return operation
  if (!isObject(operation)) return String(operation)
  return String(operation.pathDisplay || operation.path || operation.file || JSON.stringify(operation))
}

function operationKind(operation) {
  if (!isObject(operation)) return "?"
  var op = String(operation.op || "").toUpperCase()
  return op === "ADD" ? "+" : op === "DELETE" ? "−" : op === "MODIFY" ? "~" : (op || "?")
}

// -------------------------------------------------------------------- jobs

function jobsForWorld(jobs, instanceId) {
  var out = []
  for (var i = 0; i < jobs.length; i++) if (jobs[i].world === instanceId) out.push(jobs[i])
  return out
}

function activeJob(jobs, instanceId) {
  var mine = jobsForWorld(jobs, instanceId)
  for (var i = mine.length - 1; i >= 0; i--)
    if (mine[i].state === "RUNNING" || mine[i].state === "STARTING" || mine[i].state === "FINALIZING") return mine[i]
  return null
}

// Job states use the world vocabulary for a finished run ("VALID" means the run completed and
// the world finalized VALID). Readers saw that as a world state, so the card says what happened
// to the JOB.
function jobLabel(job) {
  var state = String(job && job.state || "?")
  if (state === "VALID") return "FINISHED"
  if (state === "TIMED_OUT") return "TIMED OUT"
  return state
}

function runningJobCount(jobs) {
  var n = 0
  for (var i = 0; i < jobs.length; i++)
    if (jobs[i].state === "RUNNING" || jobs[i].state === "STARTING" || jobs[i].state === "FINALIZING") n++
  return n
}

function errorText(error) {
  if (!error) return ""
  if (typeof error === "string") return error
  if (isObject(error)) return String(error.message || error.code || JSON.stringify(error))
  return String(error)
}

// --------------------------------------------------------------- siblings

// Terminal siblings of the same parent, ranked the way pick_candidate.py ranks: only VALID can
// collapse; conflicts, contamination and a failed required check disqualify; then fewer unmet
// optional checks, lower risk, smaller canonical delta. Never recommends when nobody has
// evidence, because a comparison with no evidence is not a comparison.
function siblingComparison(worlds, selected) {
  if (!selected) return { rows: [], recommendation: null, reason: "no selection" }
  var rows = []
  for (var i = 0; i < worlds.length; i++) {
    var world = worlds[i]
    if (world.parent !== selected.parent || isPrimeGeneration(world)) continue
    var checks = Array.isArray(world.checks) ? world.checks : []
    var requiredFailed = 0, optionalGaps = 0
    for (var c = 0; c < checks.length; c++) {
      if (checks[c].status === "PASS") continue
      if (checks[c].required) requiredFailed++
      else optionalGaps++
    }
    var conflicts = Array.isArray(world.conflicts) ? world.conflicts.length : 0
    var contamination = Array.isArray(world.contamination) ? world.contamination.length : 0
    var eligible = world.state === "VALID" && requiredFailed === 0 && conflicts === 0 && contamination === 0
    var why = world.state !== "VALID" ? "not VALID"
      : requiredFailed > 0 ? requiredFailed + " required check(s) failed"
      : conflicts > 0 ? "conflicts"
      : contamination > 0 ? "contamination"
      : ""
    rows.push({
      world: world,
      alias: String(world.alias || ""),
      state: String(world.state || ""),
      evidence: evidence(world, false).state,
      checks: checks.length,
      requiredFailed: requiredFailed,
      optionalGaps: optionalGaps,
      risk: String(world.risk || "—"),
      complexity: String(world.complexity || "—"),
      delta: deltaSummary(world),
      deltaBytes: JSON.stringify(world.delta || {}).length,
      eligible: eligible,
      why: why,
      isSelected: world.instanceId === selected.instanceId
    })
  }
  var eligibleRows = rows.filter(function(row) { return row.eligible })
  var anyEvidence = rows.some(function(row) { return row.checks > 0 })
  var recommendation = null
  var reason = ""
  if (rows.length === 0) reason = "no siblings"
  else if (eligibleRows.length === 0) reason = "nothing eligible to collapse"
  else if (!anyEvidence) reason = "eligible but UNASSESSED — no checks configured, nothing to compare"
  else {
    eligibleRows.sort(function(a, b) {
      if (a.optionalGaps !== b.optionalGaps) return a.optionalGaps - b.optionalGaps
      var riskA = a.risk === "LOW" ? 0 : a.risk === "MEDIUM" ? 1 : 2
      var riskB = b.risk === "LOW" ? 0 : b.risk === "MEDIUM" ? 1 : 2
      if (riskA !== riskB) return riskA - riskB
      if (a.deltaBytes !== b.deltaBytes) return a.deltaBytes - b.deltaBytes
      return a.alias < b.alias ? -1 : a.alias > b.alias ? 1 : 0
    })
    recommendation = eligibleRows[0].alias
    reason = "fewest unmet optional checks, then lowest risk, then smallest delta"
  }
  rows.sort(function(a, b) { return a.alias < b.alias ? -1 : a.alias > b.alias ? 1 : 0 })
  return { rows: rows, recommendation: recommendation, reason: reason }
}

// ----------------------------------------------------------------- doctor

var CAPABILITY_ORDER = ["atomicExchange", "overlay", "namespaces", "cgroups", "systemd", "git",
                        "docker", "inotify", "hyprland", "btrfs", "criu", "systemRootCollapse"]

function capabilityRows(capabilities) {
  var out = []
  if (!isObject(capabilities)) return out
  for (var i = 0; i < CAPABILITY_ORDER.length; i++) {
    var key = CAPABILITY_ORDER[i]
    var entry = capabilities[key]
    if (!isObject(entry)) continue
    var ok = entry.state === "AVAILABLE"
    out.push({
      name: key,
      ok: ok,
      state: String(entry.state || "?"),
      note: ok
        ? String(entry.version || entry.backend || entry.operation || entry.serverVersion || entry.managerState || "")
        : String(entry.reason || "unavailable")
    })
  }
  return out
}

// Integrity findings the doctor reports beyond capabilities. Each row is one thing the
// operator might have to act on; an empty list means the doctor found nothing.
function integrityRows(doctor) {
  var rows = []
  if (!isObject(doctor)) return rows
  function push(name, state, detail, urgent) {
    rows.push({ name: name, state: state, detail: detail, urgent: !!urgent })
  }
  var root = doctor.rootIntegrity
  if (isObject(root)) {
    var broken = (root.roots || []).filter(function(r) { return r.state !== "OK" })
    push("managed roots", String(root.state || "?"),
         broken.length ? broken.map(function(r) { return r.path + ": " + (r.reason || r.state) }).join("; ") : (root.roots || []).length + " root(s) route through the live mapping",
         root.state !== "OK")
  }
  var store = doctor.storeIntegrity
  if (isObject(store)) {
    var findings = store.findings || []
    push("store", String(store.state || "?"),
         findings.length ? findings.map(function(f) { return f.kind + (f.originalPath ? " (" + f.originalPath + ")" : "") }).join("; ") : "no unreferenced payloads, mappings, or records",
         store.state !== "OK")
  }
  var receipts = doctor.receiptCoverage
  if (isObject(receipts)) {
    var missing = receipts.committedWithoutReceipt || []
    push("receipts", String(receipts.state || "?"),
         missing.length ? missing.length + " committed collapse(s) without a receipt" : "every committed collapse has a receipt",
         receipts.state !== "OK")
  }
  var recovery = doctor.recovery
  if (isObject(recovery)) {
    var quarantined = recovery.quarantined || []
    push("recovery", String(recovery.state || "?"),
         quarantined.length ? quarantined.length + " transaction(s) quarantined — mutation is refused until resolved" : "no quarantined transactions",
         recovery.state !== "OK")
  }
  var unsupervised = doctor.unsupervisedWorlds
  if (Array.isArray(unsupervised)) {
    push("supervision", unsupervised.length ? "DEGRADED" : "OK",
         unsupervised.length ? unsupervised.map(function(w) { return w.alias }).join(", ") + " nonterminal without a job" : "every running world has a job",
         unsupervised.length > 0)
  }
  var anchor = doctor.anchor
  if (isObject(anchor)) {
    var external = String(anchor.external || "UNCONFIGURED")
    var anchorBad = anchor.state === "BROKEN" || external === "MISMATCH" || external === "ROLLED_BACK" || anchor.attest === "FAILED"
    var detail = anchor.entries + " signed receipt(s)" +
      (anchor.unanchoredReceipts ? " · " + anchor.unanchoredReceipts + " unanchored" : "") +
      " · attest " + String(anchor.attest || "UNAVAILABLE").toLowerCase() +
      " · external " + external.toLowerCase().replace("_", " ")
    push("anchor", anchorBad ? "BROKEN" : String(anchor.state || "?"), detail, anchorBad)
  }
  var usage = doctor.storeUsage
  if (isObject(usage) && isObject(usage.bytes)) {
    var total = Number(usage.total || 0)
    var parts = ["generations", "worlds", "transactions"].map(function(k) { return k + " " + fmtBytes(usage.bytes[k]) })
    push("store usage", fmtBytes(total), parts.join(" · ") + " · `worldline prune` reclaims finished worlds", false)
  }
  var network = doctor.networkPolicy
  if (isObject(network)) {
    var policy = String(network.policy || "shared")
    push("network", policy.toUpperCase(),
         policy === "shared" ? "worlds share the host network; egress is not contained"
         : policy === "allowlist" ? "worlds reach only their provider hosts" + ((network.allow || []).length ? " + " + network.allow.length + " configured" : "") + "; refusals are recorded per world"
         : "worlds have no network at all",
         false)
  }
  var limits = doctor.limits
  if (isObject(limits)) {
    var seconds = limits.defaultTimeoutSeconds
    push("timeout", seconds ? seconds + " s" : "NONE", seconds ? "every world is stopped after this unless fork --timeout says otherwise" : "worlds run until they exit or are cancelled (limits.defaultTimeoutSeconds)", false)
  }
  return rows
}

function openTransactions(doctor) {
  return isObject(doctor) && Array.isArray(doctor.openTransactions) ? doctor.openTransactions : []
}

// ------------------------------------------------------------------ misc

function stateCounts(worlds) {
  var counts = {}
  for (var i = 0; i < worlds.length; i++) {
    var state = String(worlds[i].state || "?")
    counts[state] = (counts[state] || 0) + 1
  }
  var out = []
  for (var j = 0; j < STATE_ORDER.length; j++)
    if (counts[STATE_ORDER[j]]) out.push({ state: STATE_ORDER[j], count: counts[STATE_ORDER[j]] })
  return out
}

function two(n) { return (n < 10 ? "0" : "") + n }

function fmtStamp(iso) {
  if (!iso) return "—"
  var t = Date.parse(iso)
  if (!isFinite(t)) return String(iso)
  var d = new Date(t)
  return two(d.getHours()) + ":" + two(d.getMinutes()) + ":" + two(d.getSeconds())
}

function fmtBytes(value) {
  var n = Number(value || 0)
  if (!isFinite(n) || n < 1024) return Math.round(n) + " B"
  var units = ["KB", "MB", "GB", "TB"]
  var i = -1
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
  return (n >= 10 ? Math.round(n) : Math.round(n * 10) / 10) + " " + units[i]
}

function fmtDuration(bornIso, endedIso, nowMs) {
  var born = Date.parse(bornIso)
  if (!isFinite(born)) return "—"
  var end = endedIso ? Date.parse(endedIso) : nowMs
  if (!isFinite(end)) end = nowMs
  var s = Math.max(0, Math.round((end - born) / 1000))
  if (s < 60) return s + "s"
  if (s < 3600) return Math.floor(s / 60) + "m " + (s % 60) + "s"
  if (s < 86400) return Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m"
  return Math.floor(s / 86400) + "d " + Math.floor((s % 86400) / 3600) + "h"
}

function fmtAge(ms) {
  if (!isFinite(ms)) return "no signal"
  var s = Math.round(ms / 1000)
  if (s < 60) return s + "s ago"
  if (s < 3600) return Math.floor(s / 60) + "m ago"
  return Math.floor(s / 3600) + "h ago"
}

// A CLI failure prints `worldline: CODE: message` on stderr, optionally followed by a JSON
// details line. Turn that into something a card can show without inventing a cause.
function parseCliError(stderr, exitCode) {
  var text = String(stderr || "").trim()
  var result = { code: exitCode === 130 ? "INTERRUPTED" : "FAILED", message: text || ("worldline exited " + exitCode), details: null }
  var lines = text.split("\n")
  for (var i = 0; i < lines.length; i++) {
    var match = lines[i].match(/^worldline: ([A-Z0-9_]+): (.*)$/)
    if (match) { result.code = match[1]; result.message = match[2] }
  }
  for (var j = lines.length - 1; j >= 0; j--) {
    var candidate = lines[j].trim()
    if (candidate.charAt(0) === "{") {
      try { result.details = JSON.parse(candidate); break } catch (error) { /* not the details line */ }
    }
  }
  return result
}

// ============================================================ 1.3.5: what the engine reported

// ------------------------------------------------------------------ code table (OB-194)
//
// Every code the paired engine can report, with the outcome it implies and what to do about it.
// tools/check-code-table.mjs fails CI when a code of tools/engine-codes.json (generated from the
// paired engine commit by tools/engine-codes.py) has no entry here.
//
// Outcome classes:
//   refused    the engine refused the request before acting on it. For a commit the transaction's
//              own state still decides what the cockpit says (commitOutcome); the class alone
//              never produces "not committed".
//   committed  the transaction committed; the code is a warning about what followed.
//   unknown    the code does not say whether the request took effect.
//   record     a code the engine records on a job, world, transaction or watch (why it ended).
//
// The digest of the paired engine's code list. A running engine publishes its own in
// status.json (daemon.codeSetSha256); any other value, or none, is an incompatible engine and
// the plugin sends it no mutating command (OB-195). tools/check-code-table.mjs keeps this equal to
// tools/engine-codes.json.
var SUPPORTED_CODE_SET_SHA256 = "d43ce783d979844293b5dd8f8c1e47fcc3b06451e13675604a0390a5acee04d2"
var SUPPORTED_ENGINE = "WORLDLINE 1.9.2 candidate (release pairing pending)"

// Codes this plugin reports itself (WlCall and the panels), not the engine.
var PLUGIN_CODES = ["CLI_DEADLINE", "CLI_OUTPUT_TOO_LARGE", "CLI_UNAVAILABLE", "INTERRUPTED", "FAILED", "FIXTURE",
                    "INVALID_PREPARE_OUTPUT", "INVALID_COMMIT_OUTPUT", "ENGINE_INCOMPATIBLE"]
// Codes the paired engine release (WORLDLINE 1.9.2) adds, known from its design and its work in
// progress, so the table covers them before the list is regenerated from the release commit.
var PLANNED_CODES = ["ANCHOR_ALARM", "ANCHOR_COVERAGE_MISMATCH", "ANCHOR_KEY_MISMATCH", "ANCHOR_KEY_MISSING",
                     "ANCHOR_KEY_UNPINNED", "ANCHOR_ROTATION_INCOMPLETE", "ANCHOR_WITNESS_DISAGREES",
                     "ANCHOR_WITNESS_UNAVAILABLE", "CANONICAL_FILE_UNREADABLE", "CANONICAL_PATH_OUTSIDE_STORE",
                     "RESERVED_EVENT_CLAIM", "PROOF_STATUS_UNEVALUABLE", "TEST_LIBRARY_REFUSED",
                     "RECEIPT_CHAIN_TRUNCATED", "ANCHOR_APPEND_FAILED", "ANCHOR_START_FAILED", "COMMIT_INTERRUPTED"]

var _KERNEL = "The proved kernel denied this transaction: "
var _FIX_CONFIG = " Fix the configuration it names, then try again."
var _NEW_CANDIDATE = " Fork a new candidate from the current PRIME, or revalidate this one (`worldline revalidate`)."
var _PREPARE_AGAIN = " Press R to prepare a fresh review."
var _TOOL = " Install or repair it (the message names it); `worldline doctor` lists what is available."
var _STORE = " The store may need attention: run `worldline doctor` and `worldline log --verify` before anything else."
var _UNKNOWN = " The engine did not say whether the request took effect: read the multiverse (it shows the engine's state) before trying again."

var CODE_TABLE = {
  // ---- the kernel's collapse decisions (core/worldline_core.h), refused before any exchange
  "INVALID_CANDIDATE": ["refused", "Only a VALID world can collapse or be revalidated. Read its evidence in the inspector; fork a new candidate if it failed."],
  "PARENT_MISMATCH": ["refused", _KERNEL + "the world was forked from a PRIME that is not an ancestor of the current one." + _NEW_CANDIDATE],
  "OWNER_MISMATCH": ["refused", _KERNEL + "an owner mismatch (retired in 1.9.0; an engine that returns it is older than the plugin expects)."],
  "BASE_MISMATCH": ["refused", _KERNEL + "the candidate's base is not the checkpoint it names." + _NEW_CANDIDATE],
  "DELTA_MISMATCH": ["refused", _KERNEL + "the delta at commit is not the delta that was reviewed." + _PREPARE_AGAIN],
  "ROOT_SET_MISMATCH": ["refused", _KERNEL + "the managed root set changed since the world was forked." + _NEW_CANDIDATE],
  "STAGED_ROOT_MISMATCH": ["refused", _KERNEL + "the staged tree is not the one prepared for review." + _PREPARE_AGAIN],
  "CONFLICT": ["refused", "PRIME diverged on paths this world also touched (listed below). Fork again from the current PRIME, or revert your local change and prepare again. Copying files out of the world would bypass the receipt and provenance — the engine refuses on purpose."],
  "FOREIGN_MANAGED_WRITE": ["refused", _KERNEL + "a write from outside this world reached managed state (listed below) and nothing reported it. The engine recorded it and marked PRIME for reconciliation; prepare again once `worldline status` shows PRIME clean."],
  "VALIDATION_CONTEXT_MISMATCH": ["refused", _KERNEL + "the candidate's evidence was made under different requirements than PRIME imposes now." + _NEW_CANDIDATE],
  "STAGED_UNTESTED": ["refused", _KERNEL + "the merged tree that would go live was never tested (the merge differs from the tested candidate). Revalidate so the staged result is examined."],
  "EXECUTION_EVIDENCE_INCOMPLETE": ["refused", _KERNEL + "a required check did not complete, so no evidence speaks for these bytes. Read the inspector's checks, then revalidate."],
  "VERIFIER_EXECUTION_IDENTITY_MISMATCH": ["refused", _KERNEL + "a required check ran a different verifier than the policy declares. Revalidate with the declared verifier."],
  "CHECKPOINT_UNWITNESSED": ["refused", _KERNEL + "the checkpoint to return to has no witness that it is the one recorded. Choose a checkpoint the engine can verify."],
  "IDENTITY_ABSENT": ["refused", _KERNEL + "an identity the decision needs could not be established (the engine passed it as absent). `worldline doctor` shows which producer failed."],
  "MEASUREMENT_ABSENT": ["refused", _KERNEL + "a measurement the decision needs was never made (for example PRIME was not watched). `worldline doctor` shows why; fix it and prepare again."],
  "PRIME_CHANGED": ["refused", _KERNEL + "PRIME changed while the decision's inputs were read." + _PREPARE_AGAIN],
  "WATCH_INCOMPLETE": ["refused", _KERNEL + "not every managed root was being watched, so an unreported write cannot be ruled out. `worldline doctor` shows which root; fix the watch and prepare again."],
  "CHECKPOINT_MISMATCH": ["refused", _KERNEL + "the checkpoint's bytes are not the ones recorded for it. Choose another checkpoint; run `worldline log --verify`."],
  "EVIDENCE_SUBJECT_MISMATCH": ["refused", _KERNEL + "the evidence names different bytes than the ones that would go live." + _NEW_CANDIDATE],
  "INVALID_REQUEST": ["refused", "The engine refused a malformed request (the plugin and the engine may not match: see the engine version in DIAGNOSTICS)."],
  "CORE_INVALID_ARGUMENT": ["refused", "The proved kernel rejected an argument as invalid; nothing was decided. Report it with the message: this is an engine defect."],
  "CORE_IO": ["unknown", "The proved kernel reported an I/O error." + _STORE],
  "CORE_TOO_LARGE": ["refused", "An input exceeded the proved kernel's size bound; nothing was decided."],
  "CORE_INTERNAL": ["unknown", "The proved kernel reported an internal error." + _STORE],
  "CORE_UNAVAILABLE": ["refused", "The proved kernel library could not be loaded, so nothing can be decided. Reinstall WORLDLINE; `worldline doctor` names the library."],
  "CORE_DISAGREEMENT": ["unknown", "The proved kernel and the runtime disagree on a transaction transition; the engine stopped rather than guess." + _STORE],
  "CORE_INVALID_EVALUATION": ["refused", "The proved kernel rejected the evaluation facts it was given; nothing was admitted. Revalidate the world."],
  "INVALID_EVALUATION": ["refused", "The evaluation facts were malformed; nothing was admitted. Revalidate the world."],
  "REQUEST_VERSION": ["refused", "The runtime and the kernel library disagree on the request layout; nothing was decided. Reinstall WORLDLINE so the two match."],
  "ROSTER_TOO_LARGE": ["refused", "The policy declares more checks than the kernel accepts. Retain every required check. Use or implement kernel capacity for the full roster, with matching proof evidence, before promotion."],
  "REQUIREMENT_IDENTITY_UNAVAILABLE": ["refused", "The engine could not state the current requirement (the kernel library or the resource policy could not be identified), so nothing can be prepared or committed. `worldline doctor` shows which."],

  // ---- the commit path
  "PRIME_CHANGED_AFTER_PREPARE": ["refused", "A managed root changed between review and commit. The prepared transaction is now DENIED and can never commit; press R to prepare a fresh review."],
  "PRIME_CHANGED_DURING_CAPTURE": ["refused", "PRIME changed while the engine copied and hashed it. Wait for the writer to finish, then prepare again (or fork again)."],
  "CANDIDATE_CHANGED_AFTER_PREPARE": ["refused", "The candidate's payload changed after it was prepared, so it is not what you reviewed. The transaction is DENIED." + _PREPARE_AGAIN],
  "EVIDENCE_STALE": ["refused", "The requirements changed since the evidence was made, so it no longer applies." + _NEW_CANDIDATE],
  "CHECKPOINT_IDENTITY_TAKEN": ["refused", "The PRIME generation this commit would publish already belongs to another world (a declined return leaves its vehicle holding that identity). Nothing was changed; the message names the world."],
  "TRANSACTION_DENIED": ["refused", "A denied transaction can never commit." + _PREPARE_AGAIN],
  "TRANSACTION_ALREADY_COMMITTED": ["committed", "The engine's generation marker shows this transaction's exchange already happened: it is committed. Read LAST COLLAPSE for its receipt."],
  "INVALID_TRANSACTION_STATE": ["refused", "The transaction is not in a state that allows this (only a PREPARED transaction commits; only an open one aborts). Its current state is shown below."],
  "INVALID_TRANSACTION": ["refused", "The engine does not know this kind of transaction."],
  "TRANSACTION_RECORD_LEGACY": ["refused", "This transaction was prepared by an earlier runtime and is now DENIED; abort it and prepare again."],
  "TRANSACTION_RECORD_INVALID": ["unknown", "The prepared transaction's record does not match the database." + _STORE],
  "TRANSACTION_RECORD_FOREIGN": ["refused", "The transaction record names files outside this store (was the store copied without `worldline-relocate`?). Nothing was changed." + _STORE],
  "WRITERS_ACTIVE": ["refused", "WORLDLINE-owned writers are still running in the candidate. Cancel them (or wait), then prepare again."],
  "COLLAPSE_STOPPED_WRITER": ["record", "A writer in the candidate was stopped so the collapse could proceed (recorded on its job)."],
  "SYSTEM_ROOT_COLLAPSE_UNSUPPORTED": ["refused", "A system future on this backend can be inspected but not collapsed or returned to."],
  "GHOST_SELF_COLLAPSE_FORBIDDEN": ["refused", "A ghost world cannot collapse itself; review it here instead."],
  "ATOMIC_EXCHANGE_FAILED": ["unknown", "The atomic exchange (renameat2) failed. If it did not happen the engine records the transaction ABORTED; its state is read below." + _UNKNOWN],
  "RENAME_EXCHANGE_UNAVAILABLE": ["refused", "This kernel or filesystem does not support renameat2(RENAME_EXCHANGE), so nothing can be exchanged. `worldline doctor` shows atomicExchange."],
  "COMMIT_DURABILITY_UNCERTAIN": ["committed", "The commit happened and was recorded, but completing the exchange failed, so a crash before the storage recovers could still lose it. PRIME has changed. Check the disk, then run `worldline log --verify`."],
  "RECOVERY_INCOMPLETE": ["refused", "A previous transaction is quarantined; mutation stays refused until the diagnostics card shows recovery OK."],
  "RECOVERY_AMBIGUOUS": ["unknown", "Recovery found a generation marker that does not identify one commit state; the engine will not guess." + _STORE],
  "RECOVERY_STATE_MISMATCH": ["unknown", "Recovery found PRIME in a state that does not match the transaction's record." + _STORE],
  "RECOVERY_FAILED": ["record", "Recovery could not settle a transaction; it is quarantined and mutation is refused until it is resolved."],
  "RECOVERY_IO_FAILED": ["record", "Recovery hit an I/O error settling a transaction; it is quarantined and mutation is refused until it is resolved."],
  "RECOVERED_BEFORE_COMMIT": ["record", "Recovery found this transaction never exchanged and recorded it ABORTED; PRIME was not changed by it."],
  "USER_ABORTED": ["record", "The transaction was aborted on request; it never exchanged."],
  "UNREADABLE_ERROR": ["record", "The error recorded on this transaction could not be read back."],
  "PRUNE_BLOCKED": ["refused", "A prepared transaction is open; commit or abort it before pruning."],
  "CAPTURE_FAILED": ["record", "A capture of a managed root failed (the message names the path and errno)."],

  // ---- PRIME, roots, watching
  "PRIME_WATCH_UNAVAILABLE": ["unknown", "PRIME is not being watched (no registered root could be watched), so nothing may be forked or exchanged. After a commit this can also be a post-commit failure: the transaction's own state below decides. `worldline doctor` shows why."],
  "INOTIFY_UNAVAILABLE": ["refused", "inotify is not available (the message names the errno), so PRIME cannot be watched. Raise fs.inotify limits or close watchers, then restart worldlined."],
  "INOTIFY_WATCH_FAILED": ["refused", "A directory under a managed root could not be watched (the message names it and the errno). Raise fs.inotify.max_user_watches, then restart worldlined."],
  "RECAPTURE_FAILED": ["record", "Re-capturing PRIME after a reported write failed; PRIME is its last checkpoint until the cause (named in the message) is fixed."],
  "NO_PRIME": ["refused", "No PRIME is initialized. Register a root first (M opens Roots)."],
  "NO_ROOTS": ["refused", "At least one root is required. Register one (M opens Roots)."],
  "NO_PRIMARY_ROOT": ["refused", "No primary root is registered. Register one with --primary."],
  "INVALID_PRIMARY_ROOT": ["refused", "--primary must name one of the registered roots."],
  "INVALID_ROOT_KIND": ["refused", "Unsupported root kind; use repo, config or filesystem."],
  "ROOT_NOT_FOUND": ["refused", "That root does not exist. Check the path; nothing was registered."],
  "ROOT_IS_SYMLINK": ["refused", "Register the real directory, not a symlink to it."],
  "ROOT_CONFLICT": ["refused", "That root is already registered; nothing was changed."],
  "OVERLAPPING_ROOT": ["refused", "Managed roots may not overlap. Register the outer or the inner directory, not both."],
  "WORLDLINE_SELF_CAPTURE": ["refused", "That root overlaps WORLDLINE's own state, which it may never capture."],
  "CROSS_FILESYSTEM_ROOT": ["refused", "The root and the WORLDLINE store are on different filesystems; an atomic exchange needs both on one. Relocate the store to the required root's filesystem. If that layout cannot satisfy the required root set, promotion needs a supported atomic design."],
  "UNSUPPORTED_ROOT": ["refused", "A registered root is not a directory; only directories can be managed."],
  "ROOT_SET_BUSY": ["refused", "The root set cannot change while a world runs or a transaction is open. Finish or cancel them first."],
  "ROOT_CHANGED_DURING_REMOVAL": ["refused", "The root changed while it was being removed; nothing was removed. Remove it again."],
  "ROOT_REMOVAL_ROLLED_BACK": ["refused", "The root was not removed; the engine rolled it back. Whatever was written there meanwhile is kept where the message says."],
  "LIVE_MAPPING_BROKEN": ["unknown", "A managed root does not route through its live mapping any more." + _STORE],
  "NOT_A_GIT_ROOT": ["refused", "A repo root must be the top of a Git repository. Register the repository's top-level directory, or this one with kind filesystem."],
  "GIT_LINKED_WORKTREE_UNSUPPORTED": ["refused", "A linked Git worktree cannot be a repo root on this backend. Keep the required Git checks and use a complete repository layout; if the linked layout is required, implement support before promotion."],
  "GIT_ALTERNATES_OUTSIDE_ROOT": ["refused", "The repository borrows objects from outside itself, which the inspection sandbox cannot see. Repack it (git repack -a -d), then register it."],
  "GIT_UNAVAILABLE": ["refused", "Git is not available where the inspection sandbox can run it (/usr/bin or /bin)." + _TOOL],
  "GIT_SANDBOX_UNAVAILABLE": ["refused", "The repository inspection sandbox did not start." + _TOOL],
  "GIT_INSPECTION_FAILED": ["refused", "Git could not inspect the repository (the message says why)."],
  "EXTERNAL_HARDLINK": ["refused", "A hard-linked file under the root has links outside it, which cannot be captured faithfully. Break the link (copy the file), then retry."],
  "EXTERNAL_SYMLINK": ["refused", "A symlink under the root leaves it, which this backend cannot capture faithfully. Preserve the required content and link behavior in a supported layout, or implement support before promotion."],
  "UNSUPPORTED_SPECIAL_FILE": ["refused", "A device, socket or FIFO under the root cannot enter a world on this backend. If it is part of the required state, faithful capture and restoration support is needed before promotion."],
  "CROSS_DEVICE_ENTRY": ["refused", "An entry under the root is on another filesystem (a mount), which cannot be captured. Unmount it or register it separately."],
  "HARDLINK_GROUP_MIXED": ["refused", "The three-way merge would mix hard-link ownership at the named path; nothing was staged. Resolve it in the world or in PRIME."],
  "XATTR_UNAVAILABLE": ["refused", "The filesystem cannot enumerate extended attributes of the named path."],
  "XATTR_NOT_APPLICABLE": ["refused", "A file carries an extended attribute this account may not set, so it cannot be reproduced faithfully."],
  "UNSANDBOXABLE_ROOT": ["refused", "The root overlaps a read-only system directory the sandbox binds; it cannot be managed."],
  "STORE_NOT_RELOCATED": ["refused", "This store was copied without `worldline-relocate`; its records name the original's files, and starting on it would act on the original. Run worldline-relocate."],
  "RELOCATION_REFUSED": ["refused", "worldline-relocate refused (the message says why); nothing was moved."],

  // ---- worlds, forks, races, ghosts
  "INVALID_ALIAS": ["refused", "A world alias must be non-empty, trimmed, at most 64 characters, with no slash or NUL."],
  "RESERVED_ALIAS": ["refused", "PRIME and names beginning with prime- are reserved. Choose another alias."],
  "WORLD_CONFLICT": ["refused", "A world with that alias already exists. Choose another alias (or a lane prefix for a race)."],
  "INVALID_RACE": ["refused", "A race needs exactly three agents; pick three adapters in the fork editor."],
  "NO_MISSION": ["refused", "No mission was given. Write one in the fork editor."],
  "UNKNOWN_ADAPTER": ["refused", "That agent adapter is not configured. The fork editor lists the configured adapters."],
  "ADAPTER_UNAVAILABLE": ["refused", "The agent's executable is not installed (the message names it)."],
  "ADAPTER_AUTH_UNAVAILABLE": ["refused", "The agent's declared credential projection is missing (the message names it). Log the agent in, then retry."],
  "MISSING_AGENT_CONTEXT": ["refused", "The generic adapter's context is incomplete in the WORLDLINE config." + _FIX_CONFIG],
  "INVALID_AGENT_COMMAND": ["refused", "The agent command is not a valid argv." + _FIX_CONFIG],
  "NO_ACTIVE_JOB": ["refused", "That world has no running agent job to cancel."],
  "JOB_ALREADY_RUNNING": ["refused", "A background job for this world is already running."],
  "NO_INSPECTABLE_WORLDS": ["refused", "No alternate worlds exist yet, so there is nothing to inspect. Fork one (F)."],
  "INVALID_SWITCH": ["refused", "Switch needs --next, --previous or a world; nothing was switched."],
  "INVALID_WORLD_INSTANCE": ["refused", "That is not a WORLDLINE world instance id; nothing was done."],
  "INVALID_STATE": ["unknown", "The engine met a world state it does not know." + _STORE],
  "INVALID_TRANSITION": ["refused", "The world is not in a state that allows this (the message says which)."],
  "INCOMPLETE_WORLD": ["unknown", "A world's component roots are incomplete." + _STORE],
  "NOT_FOUND": ["refused", "The engine found no such world, transaction or record (the message names it). The multiverse may be stale for a moment; wait for the next status."],
  "PAYLOAD_PRUNED": ["refused", "That world was pruned; its payload no longer exists."],
  "PAYLOAD_EXISTS": ["refused", "A candidate payload already exists where the engine would write one." + _STORE],
  "PAYLOAD_INTEGRITY_FAILED": ["refused", "A candidate file changed after it was captured, so the world's evidence no longer names these bytes." + _NEW_CANDIDATE],
  "BASE_PAYLOAD_MISSING": ["refused", "The checkpoint this candidate was forked from no longer exists. Fork a new candidate."],
  "BASE_ROOT_MISMATCH": ["refused", "The candidate's checkpoint bytes differ from its claimed base." + _NEW_CANDIDATE],
  "BASE_CHECKPOINT_UNVERIFIED": ["refused", "The checkpoint this world was forked from could not be verified (the message names the root)." + _NEW_CANDIDATE],
  "GHOSTS_DISABLED": ["refused", "Ghosts are off. Enable them with `worldline ghost enable --agent AGENT` first."],
  "UNKNOWN_GHOST": ["refused", "No ghost mission has that objective; the configured objectives are in `worldline ghost status`."],
  "FINALIZATION_FAILED": ["record", "The world could not be finalized (the message says why); it is not VALID."],
  "RUN_FAILED": ["record", "The agent run failed (the message says why); the world is not VALID."],
  "TIMEOUT": ["record", "The run exceeded its time limit and was stopped."],
  "USER_CANCELLED": ["record", "The run was cancelled on request; the world keeps what it wrote until then."],
  "DAEMON_RESTART": ["record", "The job's owner disappeared when the daemon restarted; the world was not finished."],
  "NO_SUPERVISING_JOB": ["record", "The world was running with no supervising job (lost during a restart); it was marked DEAD."],
  "PROCESS_EXITED": ["refused", "The WORLDLINE-owned process exited before it could be checkpointed."],

  // ---- evidence, checks, private evaluation
  "EVIDENCE_CONTEXT_MISSING": ["refused", "The candidate's evidence carries no validation context. Run `worldline revalidate` or fork a new candidate."],
  "EVIDENCE_CONTEXT_INVALID": ["refused", "The candidate's validation context is malformed or does not hash to its recorded identity." + _NEW_CANDIDATE],
  "VERIFIER_MODIFIED_BY_CANDIDATE": ["refused", "The candidate changed a verifier its own evidence depends on, so that evidence cannot speak for it. Review the change; fork again without it."],
  "VERIFIER_EXECUTION_UNIDENTIFIED": ["refused", "A declared read-only mount for a check is missing, so the verifier that ran cannot be identified (the message names it)."],
  "REVALIDATION_INPUT_CHANGED": ["refused", "The tree under evaluation changed while the checks ran. Revalidate again when it is quiet."],
  "CANDIDATE_SNAPSHOT_CHANGED": ["refused", "The candidate's snapshot changed during checking. Revalidate again."],
  "CANDIDATE_SNAPSHOT_MISMATCH": ["refused", "A check result does not name this world's candidate snapshot. Revalidate."],
  "CANDIDATE_SNAPSHOT_MISSING": ["refused", "Evaluated results require a candidate snapshot, and there is none. Revalidate."],
  "CHECK_PROFILE_ORDER_INVALID": ["refused", "The project's checks are out of order: legacy preparation checks must precede private evaluator checks." + _FIX_CONFIG],
  "INVALID_CHECK_FORMAT": ["refused", "A check declares an unsupported format." + _FIX_CONFIG],
  "INVALID_CHECK_ID": ["refused", "A check id is not a safe single path component." + _FIX_CONFIG],
  "UNSAFE_CHECK_RUNTIME": ["refused", "The check runtime directory is not daemon-owned." + _STORE],
  "INVALID_PROJECT_CONFIG": ["refused", "The project's WORLDLINE config is invalid (the message names the field)." + _FIX_CONFIG],
  "INVALID_HEALTH_CHECK": ["refused", "A declared health check has an invalid argv." + _FIX_CONFIG],
  "PRIVATE_INPUT_UNBOUND": ["refused", "Private evaluation needs a frozen candidate and an identified verifier set; one is missing. Revalidate."],
  "PRIVATE_BOUNDARY_UNVERIFIED": ["refused", "The private evaluator's boundary or supervisor exit was not established, so its result is not admitted."],
  "PRIVATE_EVALUATOR_BOUNDARY_FAILED": ["refused", "The private evaluator's boundary failed; its result is not admitted."],
  "PRIVATE_EVALUATOR_FAILED": ["refused", "The private evaluator failed (the message says why); nothing was admitted."],
  "PRIVATE_EVALUATOR_INVALID": ["refused", "The private evaluator's plan or identity is invalid (the message says which); nothing was run."],
  "PRIVATE_EVALUATOR_OUTPUT_LIMIT": ["refused", "The private evaluator exceeded its output limit; nothing was admitted."],
  "PRIVATE_EVALUATOR_TIMEOUT": ["refused", "The private evaluator exceeded its time limit; nothing was admitted."],
  "PRIVATE_EVALUATOR_UNAVAILABLE": ["refused", "The private evaluator is not available on this host." + _TOOL],
  "PRIVATE_ROLE_INVALID": ["refused", "A private evaluation role is invalid." + _FIX_CONFIG],
  "PRIVATE_TREE_CHANGED": ["refused", "The tree given to the private evaluator changed; nothing was admitted. Revalidate."],
  "PRIVATE_TREE_LIMIT": ["refused", "The tree exceeds the private evaluator's limits."],
  "PRIVATE_TREE_UNSUPPORTED": ["refused", "The tree contains something the private evaluator cannot take."],
  "REPORT_BINDING_INVALID": ["refused", "The isolated report's binding does not match its invocation; it is not admitted."],
  "REPORT_CHANGED": ["refused", "The isolated report changed while it was collected; it is not admitted."],
  "REPORT_MISSING": ["refused", "The isolated examiner produced no report, so nothing was admitted."],
  "REPORT_PATH_INVALID": ["refused", "The isolated report path is invalid, so nothing was admitted."],
  "REPORT_READ_FAILED": ["refused", "The isolated report could not be read, so nothing was admitted."],
  "REPORT_TOO_LARGE": ["refused", "The isolated report exceeds its size limit, so nothing was admitted."],
  "SERVICE_HEALTH_FAILED": ["record", "A declared service failed its health check (recorded on the world)."],
  "SIMULATION_FAILED": ["refused", "The system future failed to run (the message has its stderr)."],
  "INVALID_SIMULATION_COMMAND": ["refused", "simulate needs an exact, non-empty command; nothing was run."],

  // ---- sandbox, supervision, resources, host tools
  "BUBBLEWRAP_UNAVAILABLE": ["refused", "bubblewrap (bwrap), prlimit or choom is missing, so no sandbox can start." + _TOOL],
  "SANDBOX_LAUNCH_FAILED": ["refused", "The sandbox could not be launched (the message says why)."],
  "INVALID_SANDBOX_CWD": ["refused", "The sandbox working directory is outside the managed roots."],
  "INVALID_SANDBOX_ENV": ["refused", "An environment entry for the sandbox is invalid." + _FIX_CONFIG],
  "INVALID_SANDBOX_TARGET": ["refused", "A sandbox path is not absolute." + _FIX_CONFIG],
  "INVALID_LOWERDIR": ["refused", "An overlay lower root is not a directory." + _STORE],
  "OVERLAY_DEVICE_MISMATCH": ["refused", "An overlay's upper and work directories are on different devices." + _STORE],
  "OVERLAY_NOT_EMPTY": ["refused", "An overlay directory that must start empty is not." + _STORE],
  "INVALID_CREDENTIAL_PROJECTION": ["refused", "A credential projection is invalid (the message names it)." + _FIX_CONFIG],
  "CREDENTIAL_PROJECTION_UNAVAILABLE": ["refused", "A declared read-only credential path is missing (the message names it)."],
  "INVALID_NETWORK_POLICY": ["refused", "Unknown sandbox network policy." + _FIX_CONFIG],
  "NETGUARD_UNAVAILABLE": ["refused", "The allowlist network policy needs the netguard forwarder and a live proxy socket, and one is missing."],
  "SYSTEMD_UNAVAILABLE": ["refused", "systemd-run or systemctl is not installed, so nothing can be supervised."],
  "SUPERVISION_UNAVAILABLE": ["refused", "The user service manager cannot be reached (the message says why); nothing can be supervised."],
  "SYSTEMD_LAUNCH_FAILED": ["refused", "systemd could not launch the unit (the message says why)."],
  "SYSTEMD_STOP_FAILED": ["unknown", "systemctl could not stop the unit; it may still be running. Check `systemctl --user list-units 'worldline-*'`."],
  "UNIT_LAUNCH_FAILED": ["refused", "The user manager never started the transient unit."],
  "FOREIGN_SYSTEMD_UNIT": ["refused", "The engine refuses to manage a unit that is not WORLDLINE's."],
  "INVALID_PRIORITY": ["refused", "The systemd Nice value is invalid." + _FIX_CONFIG],
  "INVALID_RESTART_POLICY": ["refused", "Unsupported restart policy for a declared service." + _FIX_CONFIG],
  "CGROUPS_UNAVAILABLE": ["refused", "Unified cgroup v2 is not mounted, so resources cannot be admitted."],
  "RESOURCES_UNAVAILABLE": ["refused", "Not enough memory or task capacity is free to admit this work now (the message has the arithmetic). Wait for a world to finish, or cancel one."],
  "RESOURCE_LIMIT_EXCEEDED": ["refused", "The request exceeds a configured resource limit (the message names it)."],
  "RESOURCE_POLICY_INVALID": ["refused", "The resource policy or a requested amount is invalid (the message says which)." + _FIX_CONFIG],
  "RESOURCE_STATE_UNKNOWN": ["refused", "The engine could not read the machine's resource state, so it admits nothing (fail closed). The message says what could not be read."],
  "HYPRLAND_UNAVAILABLE": ["refused", "hyprctl is not installed, so workspaces cannot be switched."],
  "HYPRLAND_QUERY_FAILED": ["refused", "A Hyprland query failed (the message has its output)."],
  "HYPRLAND_DISPATCH_FAILED": ["unknown", "A Hyprland dispatch failed; the workspace may or may not have moved."],
  "INVALID_HYPRLAND_QUERY": ["refused", "The engine asked Hyprland for a section it does not support; nothing was changed."],
  "INVALID_WORKSPACE": ["refused", "That is not a WORLDLINE workspace; the engine does not move it."],
  "TERMINAL_UNAVAILABLE": ["refused", "xdg-terminal-exec is not installed, so no world terminal can be opened."],
  "SHELL_UNAVAILABLE_TO_CLIENT": ["refused", "`worldline shell` needs the daemon's own account; this is a client of it."],
  "DOCKER_UNAVAILABLE": ["refused", "Docker is not installed or its daemon is unavailable."],
  "DOCKER_INSPECTION_FAILED": ["refused", "Docker could not inspect the world's containers (the message has its output)."],
  "DOCKER_MANIFEST_UNSUPPORTED": ["refused", "A container cannot be reconstructed from its manifest (image, command or mounts are unsupported)."],
  "DOCKER_RECREATE_FAILED": ["unknown", "Recreating a world's container failed partway (the message has Docker's output). Check `docker ps -a`."],
  "DOCKER_SCOPE_VIOLATION": ["refused", "A container is not owned by this world; the engine refuses to touch it."],
  "BTRFS_UNAVAILABLE": ["refused", "The store is not on Btrfs, or btrfs-progs is missing, so snapshots are unavailable."],
  "BTRFS_NOT_SUBVOLUME": ["refused", "The snapshot source is not a Btrfs subvolume."],
  "BTRFS_DESTINATION_EXISTS": ["refused", "The snapshot destination already exists." + _STORE],
  "BTRFS_SCOPE_VIOLATION": ["refused", "The snapshot destination is outside WORLDLINE's data; refused."],
  "BTRFS_SNAPSHOT_FAILED": ["refused", "The Btrfs snapshot failed (the message has its output)."],
  "CRIU_UNAVAILABLE": ["refused", "CRIU is not installed or its check failed, so process checkpoints are unavailable."],
  "CRIU_CHECKPOINT_FAILED": ["refused", "The CRIU checkpoint failed (the message has its output)."],
  "CRIU_RESTORE_FAILED": ["unknown", "The CRIU restore failed partway (the message has its output)."],
  "CRIU_SCOPE_VIOLATION": ["refused", "The process or destination is not WORLDLINE's; refused."],

  // ---- store, integrity, evidence chains
  "STORAGE_ERROR": ["unknown", "A storage operation failed (the message names the errno and path)." + _STORE],
  "DISK_FULL": ["unknown", "The disk is full. Free space (`worldline prune` reclaims finished worlds), then read the multiverse before retrying."],
  "SQLITE_WAL_UNAVAILABLE": ["refused", "SQLite could not use WAL journaling for the store; the daemon will not run without it."],
  "STORE_MISSING": ["refused", "A required store directory is missing." + _STORE],
  "UNSAFE_STORE": ["refused", "The store path is not a real directory owned by the daemon's account; the daemon refuses it."],
  "UNSUPPORTED_SCHEMA": ["refused", "The store's database is newer than this runtime. Upgrade WORLDLINE; never downgrade the store."],
  "INVALID_SCHEMA": ["refused", "A record's schemaVersion is not the one this runtime writes." + _STORE],
  "INVALID_MANIFEST": ["refused", "A manifest's schema or fields are invalid." + _STORE],
  "INVALID_GENERATION": ["unknown", "A PRIME generation id or payload is invalid." + _STORE],
  "INVALID_DELTA": ["refused", "The delta is invalid (a path occurs twice, or an operation is unknown)."],
  "INVALID_HASH": ["refused", "A value that must be a sha256 identity is not one; refused."],
  "INVALID_JSON": ["refused", "Input was not valid UTF-8 JSON; nothing was read from it."],
  "NON_CANONICAL_JSON": ["refused", "JSON that must be canonical was not; refused (records are hashed in canonical form)."],
  "INVALID_PATH_ENCODING": ["refused", "A recorded path was not canonical base64; refused."],
  "PATH_ESCAPE": ["refused", "A manifest path is absolute, contains NUL or is not normalized; refused."],
  "DESTINATION_EXISTS": ["refused", "The world view destination already exists; nothing was overwritten."],
  "DESTINATION_NOT_EMPTY": ["refused", "A staging or materialization destination is not empty." + _STORE],
  "COPY_VERIFICATION_FAILED": ["refused", "A copied or materialized tree does not match its source; nothing was used."],
  "MATERIALIZATION_FAILED": ["refused", "Materializing the tree failed (the message has the materializer's output)."],
  "RECEIPT_CHAIN_INVALID": ["refused", "The receipt chain is broken at the named receipt. Run `worldline log --verify`; do not collapse until it is explained."],
  "RECEIPT_PREDECESSOR_MISMATCH": ["refused", "A new receipt did not name the current chain head; it was not appended."],
  "INVALID_RECEIPT": ["refused", "A receipt's fields do not match the schema; it was not appended."],
  "CAUSAL_CHAIN_INVALID": ["refused", "The causal chain is broken at the named event. Run `worldline log --verify`."],
  "ANCHOR_FIELD_INVALID": ["refused", "An anchor entry field contains a tab or newline; refused."],
  "UNSAFE_ANCHOR_KEY": ["refused", "The anchor signing key is not owner-only; fix its mode (0600)."],
  "INVALID_LINE": ["refused", "why needs a positive line number (PATH:LINE)."],
  "INVALID_LOCATION": ["refused", "why needs a location written PATH:LINE."],

  // ---- configuration, installation, the daemon and its clients
  "INVALID_CONFIG": ["refused", "The global WORLDLINE config is invalid (the message names what)." + _FIX_CONFIG],
  "UNSAFE_CONFIG": ["refused", "The global config is not owner-only; fix its mode (0600)."],
  "INVALID_XDG_PATH": ["refused", "An XDG directory variable is not an absolute path; the engine refuses relative ones."],
  "INVALID_SHELL_CONFIG": ["refused", "The shell's bar configuration is not what the installer can edit."],
  "INVALID_HYPR_BINDINGS": ["refused", "The Hyprland bindings file could not be patched (the message says why)."],
  "INVALID_CLIENT_MODE": ["refused", "Client mode is misconfigured (the message names the group or account)."],
  "CLIENT_MODE_UNSAFE_CONTENT": ["refused", "Content a client can reach has unsafe ownership or permissions; client mode refuses it."],
  "OPERATION_NEEDS_DAEMON_ACCOUNT": ["refused", "This operation moves directories between the operator and the store, so a client of a dedicated-account daemon cannot request it. Run it as the daemon's account."],
  "CONFIRMATION_REQUIRED": ["refused", "The engine requires an explicit confirmation (--yes) for this change."],
  "DAEMON_UNAVAILABLE": ["refused", "The daemon is not accepting requests, so nothing was sent. Check the signal chip and `systemctl --user status worldlined`."],
  "DAEMON_ACCESS_DENIED": ["refused", "No permission to reach worldlined's socket (a dedicated-account daemon admits only its client group)."],
  "DAEMON_ALREADY_RUNNING": ["refused", "Another worldlined (or worldline-relocate) already holds this store."],
  "DAEMON_DISCONNECTED": ["unknown", "The daemon closed the connection before it answered." + _UNKNOWN],
  "DAEMON_ERROR": ["unknown", "The daemon reported an error without a code." + _UNKNOWN],
  "DAEMON_PEER_UNEXPECTED": ["refused", "The socket is served by an unexpected account; the CLI refused to talk to it. Check who runs worldlined."],
  "INVALID_DAEMON_RESPONSE": ["unknown", "The daemon's answer was malformed." + _UNKNOWN],
  "INTERNAL_ERROR": ["unknown", "The daemon failed while handling the request." + _UNKNOWN],
  "PEER_UID_MISMATCH": ["refused", "The daemon refused this account: it does not own the daemon."],
  "PEER_CREDENTIALS_UNAVAILABLE": ["refused", "The daemon could not read this connection's credentials, so it refused it."],
  "UNKNOWN_OPERATION": ["refused", "The daemon does not know this operation (the plugin and the engine may not match: see the engine version)."],
  "UNSAFE_SOCKET": ["refused", "The daemon refused to replace or use an unsafe socket path."],
  "NO_RETURN_POINT": ["refused", "No checkpoint precedes the current PRIME, so there is nothing to return to."],
  "INVALID_RETURN_POINT": ["refused", "That world cannot be returned to (only ARCHIVED, COLLAPSED or VALID)."],
  "RETURN_POINT_INCOMPLETE": ["refused", "That checkpoint predates a root registered since. Keep the required root set and choose a checkpoint covering it completely. An incomplete checkpoint cannot satisfy this return."],

  // ---- WORLDLINE 1.9.2 (anchor witness, key pin and rotation, confined chains, proof guard)
  "ANCHOR_WITNESS_UNAVAILABLE": ["refused", "No anchor witness out of this account's reach is configured, so nothing is prepared or committed (a collapse would leave no copy of its evidence elsewhere). Configure anchor.exportPath as the message says."],
  "ANCHOR_WITNESS_DISAGREES": ["refused", "The local anchor ledger disagrees with its witness; nothing is promoted until the operator resolves it. Run `worldline anchor` and read its state."],
  "ANCHOR_KEY_MISSING": ["refused", "The anchor signing key is missing and history already names one; no new key is minted over it. Restore the key, or record its retirement with a rotation."],
  "ANCHOR_KEY_MISMATCH": ["refused", "The anchor key is not the pinned key nor reached from it by a rotation; nothing was signed. Run `worldline anchor`."],
  "ANCHOR_KEY_UNPINNED": ["refused", "The anchor key is not pinned out of this account's reach. Write the pin `worldline anchor pin` prints to a file this account cannot write."],
  "ANCHOR_ROTATION_INCOMPLETE": ["refused", "A key rotation was left unfinished; finish it with `worldline anchor rotate` while the daemon is stopped."],
  "ANCHOR_COVERAGE_MISMATCH": ["refused", "The anchor does not cover the store's receipts and events exactly (a rewrite keeping the count). Run `worldline log --verify`; do not collapse until it is explained."],
  "ANCHOR_ALARM": ["refused", "The anchor raised an alarm at start (the message names it); promotion is refused until it is resolved."],
  "CANONICAL_PATH_OUTSIDE_STORE": ["refused", "A chain row names a file outside the store; verification refused to read it. Run `worldline log --verify`."],
  "CANONICAL_FILE_UNREADABLE": ["refused", "A chain row's canonical file could not be read; verification cannot vouch for it. Run `worldline log --verify`."],
  "RESERVED_EVENT_CLAIM": ["refused", "An agent claimed an actor or event kind only WORLDLINE may write; the claim was refused and recorded as the agent's."],
  "RECEIPT_CHAIN_TRUNCATED": ["refused", "The receipt chain is shorter than the anchored head: a receipt was deleted. Run `worldline log --verify`; do not collapse until it is explained."],
  "PROOF_STATUS_UNEVALUABLE": ["refused", "The proof manifest cannot be evaluated, so the engine refused before asking the kernel; the transaction stays open. Reinstall WORLDLINE (its proof manifest), then commit again or abort."],
  "ANCHOR_APPEND_FAILED": ["record", "A committed receipt could not be appended to the anchor (a warning on the commit, never its result). Run `worldline anchor` and `worldline log --verify`."],
  "ANCHOR_EXPORT_INCOMPLETE": ["record", "The receipt was anchored locally, but its external witness is not current. The commit may already have happened; read the transaction state and run `worldline anchor` before relying on the exported evidence."],
  "ANCHOR_START_FAILED": ["record", "The anchor check at daemon start failed; the anchor is in alarm and promotion is refused until it is resolved. Run `worldline anchor`."],
  "COMMIT_INTERRUPTED": ["unknown", "The commit stopped on an unexpected error. The engine reports the transaction's state with it; that state, not this code, says whether PRIME moved."],
  "TEST_LIBRARY_REFUSED": ["refused", "The runtime is using a kernel library chosen by WORLDLINE_CORE_LIB (a test build); an installed engine refuses to promote with it. Unset it and restart worldlined."],

  // ---- this plugin's own codes
  "CLI_DEADLINE": ["unknown", "The plugin stopped the CLI at its deadline. The engine may still finish the request, so its outcome is read from the engine rather than assumed."],
  "CLI_OUTPUT_TOO_LARGE": ["unknown", "The plugin stopped the CLI because it printed more than its limit. The engine may still finish the request, so its outcome is read from the engine rather than assumed."],
  "CLI_UNAVAILABLE": ["refused", "The worldline CLI could not be started, so nothing was sent. Is WORLDLINE installed and on PATH?"],
  "INTERRUPTED": ["unknown", "The CLI was interrupted." + _UNKNOWN],
  "FAILED": ["unknown", "The CLI failed without naming a code." + _UNKNOWN],
  "FIXTURE": ["refused", "Fixture data: nothing is run against a real daemon."],
  "INVALID_PREPARE_OUTPUT": ["unknown", "prepare returned output the plugin could not read; a transaction may have been prepared. The transaction list below is the engine's answer."],
  "INVALID_COMMIT_OUTPUT": ["unknown", "commit returned no matching COMMITTED transaction. Its exit status alone does not establish the outcome; the plugin reads the engine's transaction record."],
  "ENGINE_INCOMPATIBLE": ["refused", "The running engine is not the one this plugin was built for, so the plugin sent nothing. Install the WORLDLINE release this plugin pairs with."],
}

function codeInfo(code) {
  var name = String(code || "")
  var entry = Object.prototype.hasOwnProperty.call(CODE_TABLE, name) ? CODE_TABLE[name] : null
  if (!entry)
    return { code: name, known: false, outcome: "unknown",
             advice: "WORLDLINE reported " + (name || "an error") + ", which this plugin does not know; the engine's message above is all there is, and the outcome is not confirmed." }
  return { code: name, known: true, outcome: entry[0], advice: entry[1] }
}

function refusalAdvice(code) {
  return codeInfo(code).advice
}

// A failure of any cockpit action, stated without turning an unknown outcome into a refusal.
function actionFailureText(label, failure) {
  var info = codeInfo(failure && failure.code)
  var text = label + ": " + String(failure && failure.code || "FAILED") + ": " + String(failure && failure.message || "")
  if (info.outcome === "unknown" || info.outcome === "committed")
    text += " — outcome unknown: the engine may have acted; the multiverse shows its state"
  return text
}

// ------------------------------------------------------------------ engine compatibility (OB-195)

function engineCompatibility(status) {
  var daemon = status && isObject(status.daemon) ? status.daemon : null
  var engineDigest = daemon && typeof daemon.codeSetSha256 === "string" ? daemon.codeSetSha256 : ""
  var version = daemon ? String(daemon.version || "?") : "?"
  var result = { compatible: false, reason: "", engineDigest: engineDigest, pluginDigest: SUPPORTED_CODE_SET_SHA256, engineVersion: version }
  if (!daemon) { result.reason = "no engine status has been read"; return result }
  if (engineDigest === "") {
    result.reason = "WORLDLINE " + version + " does not declare its code set (status.json daemon.codeSetSha256); this plugin pairs with " + SUPPORTED_ENGINE
    return result
  }
  if (engineDigest !== SUPPORTED_CODE_SET_SHA256) {
    result.reason = "WORLDLINE " + version + " reports code set " + shortHash(engineDigest) + ", this plugin knows code set " + shortHash(SUPPORTED_CODE_SET_SHA256) + " (" + SUPPORTED_ENGINE + ")"
    return result
  }
  result.compatible = true
  return result
}

// Commands that only read. Everything else a `worldline` argv can say is treated as mutating,
// including a subcommand this plugin does not know (fail closed).
function isMutatingArgv(argv) {
  if (!Array.isArray(argv) || argv[0] !== "worldline") return false
  var words = argv.slice(1).filter(function(word) { return String(word).indexOf("--") !== 0 })
  var flags = argv.slice(1)
  var command = String(words[0] || "")
  var sub = String(words[1] || "")
  var dryRun = flags.indexOf("--dry-run") >= 0
  if (["status", "list", "show", "graph", "log", "why", "doctor", "adapters", "validation"].indexOf(command) >= 0) return false
  if (command === "anchor") return !(sub === "" || sub === "pin")
  if (command === "transaction") return !(sub === "show" || sub === "list")
  if (command === "root") return !(sub === "list" || ((sub === "add" || sub === "remove") && dryRun))
  if (command === "init") return !dryRun
  if (command === "ghost") return sub !== "status"
  return true
}

// The refusal WlCall reports instead of running a mutating command against an incompatible engine.
function commandRefusal(compatibility, argv) {
  if (!isMutatingArgv(argv) || (isObject(compatibility) && compatibility.compatible === true)) return ""
  var reason = isObject(compatibility) && typeof compatibility.reason === "string"
    ? compatibility.reason : "no engine compatibility was established"
  return "worldline: ENGINE_INCOMPATIBLE: " + argv.slice(0, 3).join(" ") + " was not sent: " + reason
}

// ------------------------------------------------------------------ commit outcome (OB-193, OB-178, OB-128)

var NO_FILE_CHANGED = "No file under a managed root changed"

function wasStopped(failure) {
  var code = failure && failure.code
  return code === "CLI_DEADLINE" || code === "CLI_OUTPUT_TOO_LARGE"
}

function parseRecord(stdout) {
  var parsed
  try { parsed = JSON.parse(String(stdout || "")) } catch (error) { return null }
  return isObject(parsed) && typeof parsed.state === "string" ? parsed : null
}

// A committed result's post-commit warnings (1.9.2: `postCommit`), as lines. Accepts a list of
// strings or {step, code, message} objects, or an object carrying such a list as `warnings`.
function postCommitWarnings(result) {
  if (!isObject(result)) return []
  var raw = result.postCommit
  if (isObject(raw)) raw = Array.isArray(raw.warnings) ? raw.warnings : [raw]
  if (!Array.isArray(raw)) return []
  return raw.map(function(item) {
    if (typeof item === "string") return item
    if (!isObject(item)) return String(item)
    var head = [item.step, item.code].filter(function(part) { return part }).join(" ")
    return (head ? head + ": " : "") + String(item.message || item.reason || JSON.stringify(item))
  })
}

// The code's advice ahead of a not-committed caption; a committed-class code's advice would
// contradict the engine's state there, so it is left out.
function _adviceBefore(code) {
  if (!code) return ""
  var info = codeInfo(code)
  return info.outcome === "committed" ? "" : info.advice + " "
}

function _failureLine(failure) {
  if (!failure) return ""
  return String(failure.code || "FAILED") + ": " + String(failure.message || "")
}

// What the cockpit says about a commit that did not report plain success. `failure` is the
// parsed CLI error; `record` is `worldline transaction show ID --json`, or null when it was not
// read or failed; options: transactionId (the committed id), stopped (the plugin stopped the
// CLI: the request may still be running), final (the re-query budget is spent), showFailure (the
// parsed error of a failed show). The engine's own record decides; then the error's details
// (1.9.2 names state and exchanged on every commit refusal); anything else is not confirmed.
//
// kind: committed | not-committed | open | pending | unknown. Only not-committed and open say
// that no file changed, and only because the engine reported the transaction ABORTED or DENIED,
// or still open and not exchanged.
function commitOutcome(failure, record, options) {
  options = options || {}
  var id = String(options.transactionId || (record && record.transactionId) || "")
  var shortTx = shortId(id, 8)
  var details = failure && isObject(failure.details) ? failure.details : {}
  var code = failure ? String(failure.code || "FAILED") : ""
  var stopped = !!options.stopped
  var info = codeInfo(code)
  if (record && (!isObject(record) || (id !== "" && record.transactionId !== id))) record = null

  function outcome(kind, title, caption, extra) {
    var value = { kind: kind, title: title, caption: caption, warning: "", state: "", exchanged: null, code: code, transactionId: id }
    for (var key in extra) value[key] = extra[key]
    return value
  }
  function committed(source) {
    return outcome("committed", "COMMITTED",
                   "PRIME has changed: the engine reports transaction " + shortTx + " COMMITTED (" + source + ")." +
                   (failure ? " What failed is shown as a warning above; the receipt below is the engine's." : ""),
                   { warning: failure ? _failureLine(failure) + (info.known ? " — " + info.advice : "") : "", state: "COMMITTED", exchanged: true })
  }
  function notCommitted(state, recordedCode) {
    var because = recordedCode ? " (" + recordedCode + ")" : ""
    return outcome("not-committed", "NOT COMMITTED",
                   _adviceBefore(code) + NO_FILE_CHANGED + ": the engine reports transaction " + shortTx + " " + state + because + ".",
                   { state: state, exchanged: false })
  }
  function open(state) {
    return outcome("open", "NOT COMMITTED — TRANSACTION STILL OPEN",
                   _adviceBefore(code) + NO_FILE_CHANGED + ": the engine reports transaction " + shortTx + " " + state +
                   " and not exchanged. It still holds its staged payload: Escape aborts it.",
                   { state: state, exchanged: false })
  }
  function pending(state) {
    return outcome("pending", "OUTCOME UNKNOWN — ASKING THE ENGINE",
                   "The plugin stopped the CLI (" + code + ") before the engine answered, and the request may still be running." +
                   (state ? " The engine reports transaction " + shortTx + " " + state + " so far;" : "") +
                   " its state is read again until it is COMMITTED, ABORTED or DENIED. Nothing is claimed before that.",
                   { state: state || "" })
  }
  function unknown(why, state, exchanged) {
    return outcome("unknown", "OUTCOME NOT CONFIRMED — PRIME MAY HAVE CHANGED; CHECK STATUS",
                   why + " Run `worldline transaction show " + id + "` or read LAST COLLAPSE in the multiverse before preparing again." +
                   (failure ? " The engine said " + _failureLine(failure) + "." : ""),
                   { state: state || "", exchanged: exchanged === undefined ? null : exchanged })
  }

  if (record) {
    var state = String(record.state || "")
    var exchanged = record.exchanged === true ? true : record.exchanged === false ? false : null
    var recordedCode = isObject(record.error) && record.error.code ? String(record.error.code) : ""
    if ((state === "COMMITTED" && exchanged === false) ||
        ((state === "ABORTED" || state === "DENIED") && exchanged === true))
      return unknown("The transaction state and exchange observation disagree; the engine's outcome is not confirmed.", state, exchanged)
    if (state === "COMMITTED") return committed("its transaction record")
    if (state === "ABORTED" || state === "DENIED") return notCommitted(state, recordedCode)
    if (state === "PREPARED" || state === "AUTHORIZED") {
      if (stopped && !options.final) return pending(state)
      if (exchanged === true)
        return unknown("The exchange happened, but the engine reports transaction " + shortTx + " " + state + (record.quarantined ? " and quarantined" : "") +
                       ", not COMMITTED; recovery settles it at the next daemon start.", state, true)
      if (exchanged === false && !stopped) return open(state)
      if (exchanged === false)
        return unknown("The engine still reports transaction " + shortTx + " " + state + " and not exchanged after the plugin stopped waiting; the request may still complete.", state, false)
      return unknown("The engine reports transaction " + shortTx + " " + state + " but does not say whether the exchange happened (WORLDLINE 1.9.1 and older do not).", state)
    }
    return unknown("The engine reports transaction " + shortTx + " in a state this plugin does not know (" + (state || "none") + ").", state)
  }

  var detailState = typeof details.state === "string" ? details.state : ""
  if (details.transactionId !== undefined && details.transactionId !== id)
    return unknown("The error names a different transaction; it does not establish this transaction's outcome.", "")
  if (detailState === "COMMITTED" && details.exchanged === false)
    return unknown("The error's transaction state and exchange observation disagree.", detailState, false)
  if (detailState === "COMMITTED") return committed("with the error itself")
  if ((detailState === "ABORTED" || detailState === "DENIED") && details.exchanged !== true) return notCommitted(detailState, "")
  if ((detailState === "PREPARED" || detailState === "AUTHORIZED") && details.exchanged === false && !stopped) return open(detailState)
  if (stopped && !options.final) return pending("")
  var showFailure = options.showFailure
  return unknown(showFailure ? "The engine's record of transaction " + shortTx + " could not be read (" + _failureLine(showFailure) + ")."
                             : "The engine did not report transaction " + shortTx + "'s state.", detailState)
}

// ------------------------------------------------------------------ prepare and roots after a stop (OB-178)

// The transaction a stopped prepare left, from `worldline transaction list --json`: the newest one
// for this world and kind created since the request started (2 s of slack for a clock that
// records whole seconds).
function preparedAfterStop(listing, world, kind, startedMs) {
  if (!Array.isArray(listing) || !world) return null
  var best = null
  for (var i = 0; i < listing.length; i++) {
    var row = listing[i]
    if (!isObject(row)) continue
    if (String(row.kind || "") !== String(kind || "collapse")) continue
    if (row.candidateAlias !== world.alias && row.candidateWorld !== world.instanceId) continue
    var created = Date.parse(row.createdAt)
    if (!isFinite(created) || created < Number(startedMs || 0) - 2000) continue
    if (!best || created > Date.parse(best.createdAt)) best = row
  }
  return best
}

function prepareOutcome(row, options) {
  options = options || {}
  if (!row) {
    if (!options.final)
      return { kind: "pending", title: "OUTCOME UNKNOWN — ASKING THE ENGINE",
               caption: "The plugin stopped the CLI before the engine answered; the prepare may still be running. The transaction list is read again until a transaction for this world appears." }
    return { kind: "unknown", title: "OUTCOME NOT CONFIRMED — CHECK THE TRANSACTION LIST",
             caption: "No transaction for this world appeared after the CLI was stopped; the prepare may still be running. Run `worldline transaction list` before preparing again." }
  }
  var id = String(row.transactionId || "")
  var state = String(row.state || "")
  if (state === "PREPARED" || state === "AUTHORIZED")
    return { kind: "prepared-unreviewed", title: "PREPARED AFTER THE CLI WAS STOPPED — NOT REVIEWED", transactionId: id, state: state,
             caption: "The engine prepared transaction " + id + " (" + state + ") after the plugin stopped waiting. Its facts were never shown to you, so it cannot be committed from here. Escape aborts it and releases its staged payload; R aborts it and prepares a fresh review." }
  if (state === "DENIED")
    return { kind: "denied", title: "DENIED — NOTHING WAS WRITTEN", transactionId: id, state: state,
             caption: "The engine denied transaction " + id + (isObject(row.error) && row.error.code ? " (" + row.error.code + ")" : "") + " after the plugin stopped waiting." }
  return { kind: "other", title: "PREPARE ENDED " + state, transactionId: id, state: state,
           caption: "The engine reports transaction " + id + " " + state + "." }
}

// Whether a stopped root add or remove took effect, from `worldline root list --json`.
function rootOutcome(kind, path, roots) {
  if (!Array.isArray(roots)) return "unknown"
  var present = roots.some(function(root) { return isObject(root) && (root.path === path || root.display_path === path) })
  if (kind === "add") return present ? "done" : "not-yet"
  return present ? "not-yet" : "done"
}

// ------------------------------------------------------------------ invariants (OB-084)

// What a receipt's invariantPreservation may be called. PROVED only when the engine says PROVED
// AND carries the 1.9.2 `verification` object with every check passed; a PROVED from an earlier
// engine was issued when the manifest merely matched the library, and says so.
// The roster belongs to worldline-proof-status-v2, as emitted by ProofStatus.inspect.
// Unknown shapes or omitted checks are not evidence that all of its checks passed.
var PROOF_VERIFICATION_CHECKS = [
  "library-selection", "manifest-readable", "proof-sources-present", "library-identity",
  "manifest", "contract-pins", "zero-exceptions", "floor", "summary-digest-recorded",
  "coverage", "source-hashes", "library-hash", "proof-gate", "summary"
]

function _verificationPassed(verification) {
  if (!isObject(verification) || verification.schema !== "worldline-proof-status-v2" ||
      !Array.isArray(verification.checks)) return false
  var entries = verification.checks
  var seen = {}
  for (var i = 0; i < entries.length; i++) {
    var entry = entries[i]
    if (!isObject(entry) || typeof entry.name !== "string" || entry.ok !== true ||
        PROOF_VERIFICATION_CHECKS.indexOf(entry.name) < 0 || seen[entry.name]) return false
    seen[entry.name] = true
  }
  return PROOF_VERIFICATION_CHECKS.every(function(name) { return seen[name] === true })
}

function invariantLabel(ip) {
  if (!isObject(ip)) return { text: "—", proved: false, tone: "muted" }
  var state = String(ip.state || "?")
  var validCount = typeof ip.checks === "number" && isFinite(ip.checks) && ip.checks > 0 && Math.floor(ip.checks) === ip.checks
  var checks = validCount ? " · " + ip.checks + " checks" : ""
  if (state === "PROVED") {
    if (ip.verification === undefined)
      return { text: "PROVED under 1.9.1 rules (manifest matches library only)" + checks, proved: false, tone: "foreground" }
    if (validCount && ip.evaluable === true && ip.proofGate === "ran" && _verificationPassed(ip.verification))
      return { text: "PROVED" + checks + " · manifest verified", proved: true, tone: "accent" }
    return { text: "PROVED claimed, but its verification is incomplete: not proved", proved: false, tone: "urgent" }
  }
  var names = { "MANIFEST_ONLY": "MANIFEST ONLY (the proof was skipped at install)", "TEST_LIBRARY": "TEST LIBRARY", "UNVERIFIED": "UNVERIFIED" }
  return { text: (names[state] || state) + " — not proved" + (ip.reason ? " · " + ip.reason : ""), proved: false, tone: "urgent" }
}

// What the log view shows of an agent's stderr: its last `maxLines` lines, each at most
// `maxChars` characters. The tail is read by bytes (`tail -c`), because one agent line can be any
// size; when the read filled its whole window (`cut`), the first line is probably a fragment, so
// it is dropped, and the view says that earlier output is not shown.
function logTail(text, cut, maxLines, maxChars) {
  var lines = String(text || "").split("\n")
  if (lines.length > 0 && lines[lines.length - 1] === "") lines.pop()
  if (cut && lines.length > 0) lines.shift()
  var earlier = !!cut || lines.length > maxLines
  lines = lines.slice(-maxLines).map(function(line) { return truncate(line, maxChars) })
  if (lines.length === 0) return "(no complete line in the last part of the log)"
  return (earlier ? "… earlier output not shown\n" : "") + lines.join("\n")
}

function firstLine(text) {
  var value = String(text || "").trim()
  var cut = value.indexOf("\n")
  return cut < 0 ? value : value.substring(0, cut)
}

function truncate(text, max) {
  var value = String(text || "")
  return value.length > max ? value.substring(0, max - 1) + "…" : value
}

// A desktop-notification body is markup to a server that advertises body-markup (the Omarchy
// shell renders it as StyledText), so a world alias or objective sent there as-is would be
// interpreted. Escaping the three markup characters makes the server show the literal text.
function notificationBody(text) {
  return String(text || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// Read a bar-widget setting for this plugin from the shell's detached bar config snapshot.
function widgetSetting(barConfig, id, name, fallback) {
  if (!isObject(barConfig) || !isObject(barConfig.layout)) return fallback
  var sections = ["left", "center", "right"]
  for (var s = 0; s < sections.length; s++) {
    var entries = barConfig.layout[sections[s]]
    if (!Array.isArray(entries)) continue
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (isObject(entry) && entry.id === id && entry[name] !== undefined && entry[name] !== null) return entry[name]
    }
  }
  return fallback
}
