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

function firstLine(text) {
  var value = String(text || "").trim()
  var cut = value.indexOf("\n")
  return cut < 0 ? value : value.substring(0, cut)
}

function truncate(text, max) {
  var value = String(text || "")
  return value.length > max ? value.substring(0, max - 1) + "…" : value
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
