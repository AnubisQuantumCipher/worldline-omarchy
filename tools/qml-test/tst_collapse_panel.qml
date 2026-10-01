import QtQuick
import QtTest
import Quickshell.Io
import "Model.js" as Model
import "Recorded.js" as Recorded

// Render tests for CollapsePanel.qml, driven by recorded CLI outputs (tools/fixtures/cli). The
// panel runs as shipped: its real WlCall.qml and Model.js, with the shell's modules and
// Quickshell.Io's Process replaced by stand-ins (tools/qml-test/imports). What is checked is what
// an operator would read: the text of every visible Text item in the panel.
//
// Run through tools/test-collapse-panel.mjs, which stages this file beside the panel's sources.
// The root is a visible Item: a TestCase is itself invisible, and so would be a panel inside it.
Item {
  id: stage
  width: 900
  height: 1400

  Component {
    id: panelComponent
    CollapsePanel { width: 900; height: 1400 }
  }

  Component {
    id: callComponent
    WlCall {}
  }

TestCase {
  id: testCase
  name: "CollapsePanel"
  when: windowShown

  function out(name) {
    var recorded = Recorded.outputs[name]
    if (!recorded) throw new Error("no recorded output " + name)
    return { exitCode: recorded.exitCode, stdout: recorded.stdout, stderr: recorded.stderr, delayMs: 20 }
  }
  function slow(name, ms) { var reply = out(name); reply.delayMs = ms; return reply }

  readonly property var prepareArgv: ["worldline", "collapse", "--prepare", "--json", "--", "w1"]
  readonly property var commitArgv: ["worldline", "transaction", "commit", "7f3c1e2a-5b6d-4e8f-9a0b-1c2d3e4f5a6b", "--yes", "--json"]
  readonly property var showArgv: ["worldline", "transaction", "show", "7f3c1e2a-5b6d-4e8f-9a0b-1c2d3e4f5a6b", "--json"]
  readonly property var listArgv: ["worldline", "transaction", "list", "--json"]

  // The status document a compatible engine publishes: the code-set digest this plugin declares.
  function statusFor(digest) {
    return { schemaVersion: 1, daemon: { state: "RUNNING", publishedAt: new Date().toISOString(), version: "1.9.2", codeSetSha256: digest },
             prime: { instanceId: "prime-0001" }, activeWorld: "PRIME", worlds: [], jobs: [], capabilities: {}, lastReceipt: null, ghostRecommendation: null }
  }
  function compatibleStatus() { return statusFor(Model.SUPPORTED_CODE_SET_SHA256) }

  function makePanel(status) {
    var panel = createTemporaryObject(panelComponent, stage, {
      world: { alias: "w1", instanceId: "3a9f0c1d-2b3e-4f50-8a1b-c2d3e4f5a6b7", state: "VALID" },
      status: status === undefined ? compatibleStatus() : status,
      signalState: "live", actionKind: "collapse", fixture: false
    })
    verify(panel !== null, "the panel was created")
    // A reduced deadline and a fast re-query, so a stopped command and its resolution fit a test.
    var objects = panel.data
    for (var i = 0; i < objects.length; i++)
      if (objects[i] && typeof objects[i].run === "function" && objects[i].seconds !== undefined) objects[i].seconds = 1
    if (panel.resolvePollMs !== undefined) panel.resolvePollMs = 60
    if (panel.resolvePolls !== undefined) panel.resolvePolls = 8
    return panel
  }

  function visibleTexts(item, list) {
    list = list || []
    if (!item || item.visible === false) return list
    if ("textFormat" in item && typeof item.text === "string" && item.text !== "") list.push(item.text)
    var children = item.children || []
    for (var i = 0; i < children.length; i++) visibleTexts(children[i], list)
    return list
  }
  function shown(panel) { return visibleTexts(panel, []) }
  function has(panel, exact) { return shown(panel).indexOf(exact) >= 0 }
  function any(panel, test) { return shown(panel).some(test) }
  function contains(panel, fragment) { return any(panel, function(t) { return t.indexOf(fragment) >= 0 }) }
  function startsWith(panel, prefix) { return any(panel, function(t) { return t.indexOf(prefix) === 0 }) }
  function dump(panel) { return JSON.stringify(shown(panel)) }

  function prepareThenCommit(panel) {
    panel.begin()
    tryVerify(function() { return panel.phase === "review" }, 3000, "prepare reached review")
    panel.execute()
  }

  function assertCommitted(panel) {
    tryVerify(function() { return has(panel, "COMMITTED") }, 5000, "renders COMMITTED: " + dump(panel))
    verify(!startsWith(panel, "NOT COMMITTED"), "never NOT COMMITTED for a commit that moved PRIME: " + dump(panel))
    verify(!contains(panel, "No file under a managed root changed"), "never 'no file changed' for a commit that moved PRIME: " + dump(panel))
  }

  function assertNotCommitted(panel) {
    tryVerify(function() { return has(panel, "NOT COMMITTED") }, 5000, "renders NOT COMMITTED: " + dump(panel))
    verify(contains(panel, "No file under a managed root changed"), "the not-committed caption: " + dump(panel))
    verify(!has(panel, "COMMITTED"), "no COMMITTED card: " + dump(panel))
  }

  function assertNotConfirmed(panel) {
    tryVerify(function() { return startsWith(panel, "OUTCOME NOT CONFIRMED") }, 5000, "renders OUTCOME NOT CONFIRMED: " + dump(panel))
    verify(!startsWith(panel, "NOT COMMITTED"), "an unconfirmed outcome is not NOT COMMITTED: " + dump(panel))
    verify(!has(panel, "COMMITTED"), "an unconfirmed outcome is not COMMITTED: " + dump(panel))
    verify(!contains(panel, "No file under a managed root changed"), "an unconfirmed outcome never says no file changed: " + dump(panel))
  }

  function test_01_durability_uncertain_renders_committed_with_the_warning() {
    FakeCli.reset([
      { argv: prepareArgv, reply: out("prepare-authorized") },
      { argv: commitArgv, reply: out("commit-durability-uncertain") },
      { argv: showArgv, reply: out("show-committed-1.9.1") },
    ])
    var panel = makePanel()
    prepareThenCommit(panel)
    assertCommitted(panel)
    verify(contains(panel, "COMMIT_DURABILITY_UNCERTAIN"), "the failure is shown as a warning: " + dump(panel))
  }

  function test_02_ghost_freeze_error_after_a_commit_renders_committed() {
    FakeCli.reset([
      { argv: prepareArgv, reply: out("prepare-authorized") },
      { argv: commitArgv, reply: out("commit-prime-watch-after-commit-1.9.1") },
      { argv: showArgv, reply: out("show-committed-1.9.1") },
    ])
    var panel = makePanel()
    prepareThenCommit(panel)
    assertCommitted(panel)
    verify(contains(panel, "PRIME_WATCH_UNAVAILABLE"), "the post-commit error is shown as a warning: " + dump(panel))
  }

  function test_03_post_commit_warnings_on_a_committed_result_are_shown() {
    FakeCli.reset([
      { argv: prepareArgv, reply: out("prepare-authorized") },
      { argv: commitArgv, reply: out("commit-committed-postcommit-1.9.2") },
    ])
    var panel = makePanel()
    prepareThenCommit(panel)
    assertCommitted(panel)
    tryVerify(function() { return contains(panel, "PRIME_WATCH_UNAVAILABLE") }, 3000, "the postCommit warning is shown: " + dump(panel))
  }

  function test_04_conflict_still_renders_not_committed() {
    FakeCli.reset([
      { argv: prepareArgv, reply: out("prepare-authorized") },
      { argv: commitArgv, reply: out("commit-conflict-1.9.1") },
      { argv: showArgv, reply: out("show-denied-1.9.1") },
    ])
    var panel = makePanel()
    prepareThenCommit(panel)
    assertNotCommitted(panel)
    verify(contains(panel, "CONFLICT"), "the code is named: " + dump(panel))
  }

  function test_05_foreign_managed_write_renders_refused_with_its_own_advice() {
    FakeCli.reset([
      { argv: prepareArgv, reply: out("prepare-authorized") },
      { argv: commitArgv, reply: out("commit-foreign-managed-write-1.9.1") },
      { argv: showArgv, reply: out("show-denied-fmw-1.9.1") },
    ])
    var panel = makePanel()
    prepareThenCommit(panel)
    assertNotCommitted(panel)
    verify(!contains(panel, "The engine refused; the code above names why"), "FOREIGN_MANAGED_WRITE has its own advice, not the generic fallback: " + dump(panel))
    verify(contains(panel, "outside"), "the advice says a write came from outside the world: " + dump(panel))
  }

  function test_06_a_commit_stopped_at_its_deadline_shows_outcome_unknown_then_the_engine_state() {
    FakeCli.reset([
      { argv: prepareArgv, reply: out("prepare-authorized") },
      { argv: commitArgv, reply: { hang: true } },
      { argv: showArgv, reply: slow("show-authorized-1.9.2", 250), times: 2 },
      { argv: showArgv, reply: slow("show-committed-1.9.2", 250) },
    ])
    var panel = makePanel()
    prepareThenCommit(panel)
    tryVerify(function() { return startsWith(panel, "OUTCOME UNKNOWN") }, 4000, "renders outcome unknown after the deadline: " + dump(panel))
    verify(!startsWith(panel, "NOT COMMITTED"), "a stopped commit is not NOT COMMITTED: " + dump(panel))
    assertCommitted(panel)
    verify(FakeCli.ran(showArgv) >= 3, "queried the engine until the transaction was terminal")
  }

  function test_07_a_stopped_commit_the_engine_aborted_renders_not_committed() {
    FakeCli.reset([
      { argv: prepareArgv, reply: out("prepare-authorized") },
      { argv: commitArgv, reply: { hang: true } },
      { argv: showArgv, reply: slow("show-aborted-1.9.2", 150) },
    ])
    var panel = makePanel()
    prepareThenCommit(panel)
    assertNotCommitted(panel)
  }

  function test_08_a_stopped_commit_on_an_engine_without_exchanged_is_not_confirmed() {
    FakeCli.reset([
      { argv: prepareArgv, reply: out("prepare-authorized") },
      { argv: commitArgv, reply: { hang: true } },
      { argv: showArgv, reply: out("show-prepared-1.9.1"), times: 20 },
    ])
    var panel = makePanel()
    prepareThenCommit(panel)
    assertNotConfirmed(panel)
  }

  function test_09_a_failed_show_is_not_confirmed() {
    FakeCli.reset([
      { argv: prepareArgv, reply: out("prepare-authorized") },
      { argv: commitArgv, reply: out("commit-internal-error") },
      { argv: showArgv, reply: out("show-daemon-unavailable"), times: 20 },
    ])
    var panel = makePanel()
    prepareThenCommit(panel)
    assertNotConfirmed(panel)
  }

  function test_10_a_refusal_that_leaves_the_transaction_prepared_says_it_is_still_open() {
    FakeCli.reset([
      { argv: prepareArgv, reply: out("prepare-authorized") },
      { argv: commitArgv, reply: out("commit-proof-unevaluable-1.9.2") },
      { argv: showArgv, reply: out("show-prepared-1.9.2") },
    ])
    var panel = makePanel()
    prepareThenCommit(panel)
    tryVerify(function() { return startsWith(panel, "NOT COMMITTED — TRANSACTION STILL OPEN") }, 5000, "renders the open transaction: " + dump(panel))
    verify(contains(panel, "No file under a managed root changed"), "the not-committed caption: " + dump(panel))
    verify(!has(panel, "COMMITTED"), "no COMMITTED card: " + dump(panel))
  }

  function test_11_an_incompatible_engine_is_shown_and_sent_no_commit() {
    FakeCli.reset([
      { argv: prepareArgv, reply: out("prepare-authorized") },
      { argv: commitArgv, reply: out("commit-committed-1.9.1") },
    ])
    var panel = makePanel(statusFor("sha256:" + "0".repeat(64)))
    panel.begin()
    wait(200)
    // Even with facts in hand (as if prepared before the engine changed), no commit is sent.
    panel.facts = JSON.parse(Recorded.outputs["prepare-authorized"].stdout)
    panel.phase = "review"
    panel.execute()
    wait(300)
    compare(FakeCli.ran(["worldline", "transaction", "commit"]), 0, "no commit was sent to an incompatible engine")
    compare(FakeCli.ran(["worldline", "collapse", "--prepare"]), 0, "no prepare was sent to an incompatible engine")
    verify(startsWith(panel, "INCOMPATIBLE ENGINE"), "says incompatible engine: " + dump(panel))
  }

  function test_12_an_engine_that_declares_no_code_set_is_incompatible() {
    FakeCli.reset([{ argv: prepareArgv, reply: out("prepare-authorized") }])
    var status = statusFor(undefined)
    delete status.daemon.codeSetSha256
    status.daemon.version = "1.9.1"
    var panel = makePanel(status)
    panel.begin()
    wait(200)
    compare(FakeCli.ran(["worldline", "collapse", "--prepare"]), 0, "no prepare was sent to an engine with no code set")
    verify(startsWith(panel, "INCOMPATIBLE ENGINE"), "says incompatible engine: " + dump(panel))
  }

  function test_13_proved_is_shown_only_for_a_verified_status() {
    FakeCli.reset([
      { argv: prepareArgv, reply: out("prepare-authorized") },
      { argv: commitArgv, reply: out("commit-committed-1.9.1") },
    ])
    var panel = makePanel()
    prepareThenCommit(panel)
    assertCommitted(panel)
    verify(!any(panel, function(t) { return /^PROVED( · |$)/.test(t) }), "a 1.9.1 receipt without a verification object is not labelled PROVED: " + dump(panel))
    verify(contains(panel, "1.9.1 rules"), "it is labelled as proved under 1.9.1 rules: " + dump(panel))
  }

  function test_14_a_prepare_stopped_at_its_deadline_is_resolved_from_the_transaction_list() {
    FakeCli.reset([
      { argv: prepareArgv, reply: { hang: true } },
      { argv: listArgv, reply: slow("list-prepared-after-deadline-1.9.1", 100) },
    ])
    var panel = makePanel()
    panel.begin()
    tryVerify(function() { return contains(panel, "7f3c1e2a") && contains(panel, "PREPARED") }, 5000, "shows the transaction the engine prepared: " + dump(panel))
    verify(!startsWith(panel, "NOT COMMITTED"), "a stopped prepare is not NOT COMMITTED: " + dump(panel))
    verify(!contains(panel, "No file under a managed root changed"), dump(panel))
  }

  function test_15_nothing_unexpected_was_run() {
    // Each test above checks its own calls; this one checks the fake itself refuses strangers.
    FakeCli.reset([])
    var panel = makePanel()
    panel.begin()
    tryVerify(function() { return FakeCli.unexpected.length === 1 }, 3000)
  }

  function test_16_wlcall_itself_refuses_a_mutating_command_to_an_incompatible_engine() {
    FakeCli.reset([{ argv: commitArgv, reply: out("commit-committed-1.9.1") }, { argv: showArgv, reply: out("show-committed-1.9.1") }])
    var call = createTemporaryObject(callComponent, stage, { engine: Model.engineCompatibility(statusFor("sha256:" + "0".repeat(64))) })
    var got = null
    verify(call.run(commitArgv, function(code, stdout, stderr) { got = { code: code, stderr: stderr } }), "run accepted the call")
    tryVerify(function() { return got !== null }, 2000, "the refusal was delivered")
    compare(got.code, 1)
    verify(got.stderr.indexOf("worldline: ENGINE_INCOMPATIBLE: ") === 0, got.stderr)
    compare(FakeCli.ran(["worldline", "transaction", "commit"]), 0, "nothing was started")
    // A read still runs.
    got = null
    verify(call.run(showArgv, function(code, stdout, stderr) { got = { code: code, stdout: stdout } }))
    tryVerify(function() { return got !== null }, 2000)
    compare(got.code, 0)
    compare(FakeCli.ran(["worldline", "transaction", "show"]), 1)
  }

  function test_17_a_wlcall_without_an_engine_refuses_mutating_commands() {
    FakeCli.reset([{ argv: commitArgv, reply: out("commit-committed-1.9.1") }])
    var call = createTemporaryObject(callComponent, stage, {})
    var got = null
    call.run(commitArgv, function(code, stdout, stderr) { got = { code: code, stderr: stderr } })
    tryVerify(function() { return got !== null }, 2000)
    verify(got.stderr.indexOf("worldline: ENGINE_INCOMPATIBLE: ") === 0, got.stderr)
    compare(FakeCli.ran(["worldline", "transaction", "commit"]), 0, "nothing was started")
  }

  function test_18_successful_exit_with_unconfirmed_content_data() {
    return [
      { tag: "unreadable", stdout: "{" },
      { tag: "null", stdout: "null" },
      { tag: "empty-object", stdout: "{}" },
      { tag: "missing-identity", stdout: JSON.stringify({ state: "COMMITTED" }) },
      { tag: "different-identity", stdout: JSON.stringify({ state: "COMMITTED", transactionId: "different" }) },
      { tag: "still-prepared", stdout: JSON.stringify({ state: "PREPARED", transactionId: commitArgv[3] }) },
      { tag: "exchange-disagrees", stdout: JSON.stringify({ state: "COMMITTED", transactionId: commitArgv[3], exchanged: false }) }
    ]
  }

  function test_18_successful_exit_with_unconfirmed_content(data) {
    FakeCli.reset([
      { argv: prepareArgv, reply: out("prepare-authorized") },
      { argv: commitArgv, reply: { exitCode: 0, stdout: data.stdout, stderr: "", delayMs: 20 } },
      { argv: showArgv, reply: out("show-denied-1.9.1") }
    ])
    var panel = makePanel()
    prepareThenCommit(panel)
    assertNotCommitted(panel)
    compare(FakeCli.ran(showArgv), 1, "exit success with incomplete content was resolved from the transaction record")
  }

  function test_19_verified_proof_label_data() {
    return [ { tag: "complete", failed: false }, { tag: "failed-nested-check", failed: true } ]
  }

  function test_19_verified_proof_label(data) {
    var result = JSON.parse(Recorded.outputs["commit-committed-1.9.1"].stdout)
    var proof = JSON.parse(JSON.stringify(Recorded.verifiedProof))
    if (data.failed) proof.verification.checks[0].ok = false
    result.receipt.invariantPreservation = proof
    FakeCli.reset([
      { argv: prepareArgv, reply: out("prepare-authorized") },
      { argv: commitArgv, reply: { exitCode: 0, stdout: JSON.stringify(result), stderr: "", delayMs: 20 } }
    ])
    var panel = makePanel()
    prepareThenCommit(panel)
    assertCommitted(panel)
    compare(any(panel, function(t) { return /^PROVED( · |$)/.test(t) }), !data.failed,
            "PROVED requires all nested verification checks to pass: " + dump(panel))
    if (data.failed) verify(contains(panel, "verification is incomplete"), dump(panel))
  }
}
}
