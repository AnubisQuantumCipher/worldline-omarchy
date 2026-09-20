import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The authorization screen. It never shows a fact it did not just receive from the engine:
//
//   PREPARE  `worldline collapse|return --prepare --json -- <alias>` stages the transaction
//            and returns the facts (decision, before/candidate/staged roots, managed roots,
//            every delta operation, conflicts, contamination, dependency changes).
//   REVIEW   the operator reads those facts; a second, explicit confirmation follows.
//   COMMIT   `worldline transaction commit <id> --yes --json` commits THAT transaction id;
//            the daemon re-hashes PRIME against the prepared beforeRoot first, so anything
//            that changed since the review is refused (PRIME_CHANGED_AFTER_PREPARE).
//   ABORT    cancel / Escape / closing the cockpit aborts the prepared transaction so it does
//            not hold a staged payload or block root-set changes.
Item {
  id: root

  property var world: ({})
  property var status: ({})
  property string actionKind: "collapse"        // "collapse" | "return"
  property string signalState: "live"           // live | stale | offline
  property bool fixture: false                  // test seam: never execute
  property var cliEnvironment: ({})
  property string primeLabel: "PRIME"

  // phase: idle | preparing | review | committing | committed | denied | error | aborting
  property string phase: "idle"
  property var facts: null
  property var result: null
  property var failure: null
  property bool secondConfirmation: false
  property bool showDetails: false
  property bool leaveAfterPrepare: false

  readonly property string alias: String(root.world && root.world.alias ? root.world.alias : "")
  readonly property bool prepared: root.phase === "review" && root.facts !== null
  readonly property bool busy: prepareCall.busy || commitCall.busy || abortCall.busy
  readonly property bool canCommit: root.prepared && root.signalState === "live" && !root.fixture && !root.busy
  readonly property string commitBlockedReason: root.fixture ? "fixture data — execution disabled"
    : root.signalState !== "live" ? "daemon signal is " + root.signalState + " — commit disabled until it is live"
    : ""

  signal committed(var receipt)
  signal cancelled()
  signal requestFocus()

  function begin() {
    root.phase = "preparing"
    root.facts = null
    root.result = null
    root.failure = null
    root.secondConfirmation = false
    root.leaveAfterPrepare = false
    var argv = root.actionKind === "return"
      ? ["worldline", "return", "--prepare", "--json", "--", root.alias]
      : ["worldline", "collapse", "--prepare", "--json", "--", root.alias]
    if (root.fixture) {
      root.phase = "error"
      root.failure = { code: "FIXTURE", message: "fixture data: prepare is not run against the real daemon", details: null }
      return
    }
    prepareCall.run(argv, function(exitCode, stdout, stderr) {
      if (exitCode === 0) {
        try {
          root.facts = JSON.parse(stdout)
        } catch (error) {
          root.failure = { code: "INVALID_PREPARE_OUTPUT", message: "prepare returned unreadable JSON", details: null }
          root.phase = "error"
          return
        }
        if (root.leaveAfterPrepare) { root.phase = "review"; root.abort(); return }
        root.phase = "review"
      } else {
        root.failure = Model.parseCliError(stderr, exitCode)
        root.phase = (root.failure.code === "CONFLICT" || (root.failure.details && root.failure.details.decision)) ? "denied" : "error"
      }
      root.requestFocus()
    })
  }

  function confirm() {
    if (!root.prepared) return
    root.secondConfirmation = true
  }

  function execute() {
    if (!root.canCommit) return
    root.secondConfirmation = false
    root.phase = "committing"
    var id = String(root.facts.transaction_id)
    commitCall.run(["worldline", "transaction", "commit", id, "--yes", "--json"], function(exitCode, stdout, stderr) {
      if (exitCode === 0) {
        try { root.result = JSON.parse(stdout) } catch (error) { root.result = { state: "COMMITTED" } }
        root.phase = "committed"
        root.committed(root.result)
      } else {
        root.failure = Model.parseCliError(stderr, exitCode)
        root.phase = "error"
      }
      root.requestFocus()
    })
  }

  // Abort whatever is prepared and hand control back. Safe to call in any phase.
  function abort() {
    root.secondConfirmation = false
    if (root.phase === "preparing") { root.leaveAfterPrepare = true; return }
    if (root.prepared) {
      var id = String(root.facts.transaction_id)
      root.phase = "aborting"
      abortCall.run(["worldline", "transaction", "abort", id, "--json"], function(exitCode, stdout, stderr) {
        if (exitCode !== 0) {
          // The transaction may already be terminal (denied or committed); report, do not hide.
          root.failure = Model.parseCliError(stderr, exitCode)
        }
        root.phase = "idle"
        root.facts = null
        root.cancelled()
      })
      return
    }
    root.phase = "idle"
    root.facts = null
    root.cancelled()
  }

  function handleKey(event) {
    if (root.secondConfirmation) return secondConfirm.handleKey(event)
    if (event.key === Qt.Key_Escape) { root.abort(); return true }
    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && root.prepared && root.canCommit) { root.confirm(); return true }
    if (event.text === "d" || event.text === "D") { root.showDetails = !root.showDetails; return true }
    if ((event.text === "r" || event.text === "R") && (root.phase === "denied" || root.phase === "error")) { root.begin(); return true }
    return false
  }

  WlCall { id: prepareCall; environment: root.cliEnvironment }
  WlCall { id: commitCall; environment: root.cliEnvironment }
  WlCall { id: abortCall; environment: root.cliEnvironment }

  readonly property var operations: root.facts && root.facts.delta && Array.isArray(root.facts.delta.operations) ? root.facts.delta.operations : []
  readonly property var conflicts: root.facts && Array.isArray(root.facts.conflicts) ? root.facts.conflicts
    : (root.failure && root.failure.details && Array.isArray(root.failure.details.conflicts) ? root.failure.details.conflicts : [])
  readonly property var contamination: root.facts && Array.isArray(root.facts.contamination) ? root.facts.contamination
    : (root.failure && root.failure.details && Array.isArray(root.failure.details.contamination) ? root.failure.details.contamination : [])
  readonly property var managedRoots: root.facts && Array.isArray(root.facts.managedRoots) ? root.facts.managedRoots : []
  readonly property var dependencyChanges: root.facts && Array.isArray(root.facts.dependency_changes) ? root.facts.dependency_changes : []

  function stepTone(step) {
    var current = root.phase === "preparing" ? 1 : root.prepared ? 2 : (root.phase === "committing" || root.phase === "committed") ? 3 : 0
    if (root.phase === "committed") return "accent"
    return step === current ? "accent" : step < current ? "foreground" : "muted"
  }

  ColumnLayout {
    anchors.fill: parent
    spacing: Style.spacing.md

    // ------------------------------------------------------------ title
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.md
      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: root.actionKind === "return"
          ? "RETURN " + root.primeLabel + " TO " + root.alias
          : "COLLAPSE " + root.alias + " INTO " + root.primeLabel
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.heading
        font.bold: true
        font.letterSpacing: Style.spaceReal(0.6)
        elide: Text.ElideMiddle
      }
      WlChip { label: "1 PREPARE"; tone: root.stepTone(1); filled: root.phase === "preparing" }
      WlChip { label: "2 REVIEW"; tone: root.stepTone(2); filled: root.prepared }
      WlChip { label: "3 COMMIT"; tone: root.stepTone(3); filled: root.phase === "committed" }
    }

    Text {
      textFormat: Text.PlainText
      Layout.fillWidth: true
      text: root.actionKind === "return"
        ? "A return is a forward transaction: the selected checkpoint is re-materialized, staged, authorized by the kernel, and exchanged into PRIME in one renameat2 call. It gets its own receipt."
        : "The engine stages a three-way merge of this world onto the current PRIME, the proved kernel decides, and only an AUTHORIZED decision can be committed. Nothing below is remembered from an earlier screen."
      color: Color.muted
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    // ------------------------------------------------------------ body
    Flickable {
      Layout.fillWidth: true
      Layout.fillHeight: true
      contentHeight: body.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      ColumnLayout {
        id: body
        width: parent.width
        spacing: Style.spacing.md

        // preparing
        WlCard {
          visible: root.phase === "preparing" || root.phase === "aborting" || root.phase === "committing"
          title: root.phase === "preparing" ? "PREPARING" : root.phase === "aborting" ? "ABORTING" : "COMMITTING"
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: root.phase === "preparing"
              ? "Staging the candidate against the current PRIME and asking the kernel for a decision…"
              : root.phase === "aborting"
                ? "Releasing the prepared transaction and its staged payload…"
                : "Re-verifying PRIME against the reviewed state, then exchanging the live mapping…"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }
          Text {
            textFormat: Text.PlainText
            visible: root.phase === "preparing" && root.leaveAfterPrepare
            text: "Cancel requested — the transaction will be aborted as soon as it is prepared."
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // denied / error
        WlCard {
          visible: root.phase === "denied" || root.phase === "error"
          urgent: true
          title: root.phase === "denied" ? "DENIED — NOTHING WAS WRITTEN" : "NOT COMMITTED"
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: root.failure ? String(root.failure.code || "FAILED") : ""
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: root.failure ? String(root.failure.message || "") : ""
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            visible: root.failure && root.failure.details && root.failure.details.decision !== undefined
            text: root.failure && root.failure.details ? "kernel decision: " + String(root.failure.details.decision) : ""
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: {
              var code = root.failure ? String(root.failure.code) : ""
              if (code === "CONFLICT") return "PRIME diverged on paths this world also touched (listed below). Fork again from the current PRIME, or revert your local change and prepare again. Copying files out of the world would bypass the receipt and provenance — the engine refuses on purpose."
              if (code === "PRIME_CHANGED_AFTER_PREPARE") return "A managed root changed between review and commit. The prepared transaction is now DENIED and can never commit; press R to prepare a fresh review."
              if (code === "INVALID_CANDIDATE") return "Only a VALID world can collapse. Read its evidence in the inspector."
              if (code === "RECOVERY_INCOMPLETE") return "A previous transaction is quarantined; mutation stays refused until the diagnostics card shows recovery OK."
              if (code === "DAEMON_UNAVAILABLE") return "The daemon is not accepting requests. Check the signal chip and `systemctl --user status worldlined`."
              return "The engine refused; the code above names why. No file under a managed root changed."
            }
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // committed
        WlCard {
          visible: root.phase === "committed"
          title: "COMMITTED"
          accentColor: Color.accent
          WlKV { k: "RECEIPT"; v: root.result && root.result.receipt ? String(root.result.receipt.receiptId || "—") : "—"; vColor: Color.accent }
          WlKV { k: "AFTER ROOT"; v: root.result ? Model.shortHash(root.result.afterRoot) : "—" }
          WlKV {
            k: "INVARIANTS"
            v: {
              var ip = root.result && root.result.receipt ? root.result.receipt.invariantPreservation : null
              if (!ip) return "—"
              return String(ip.state || "?") + (ip.checks ? " · " + Number(ip.checks) + " proved checks" : "") + (ip.reason ? " · " + ip.reason : "")
            }
            vColor: root.result && root.result.receipt && root.result.receipt.invariantPreservation && root.result.receipt.invariantPreservation.state === "PROVED" ? Color.accent : Color.foreground
          }
          WlKV { k: "MECHANISM"; v: root.result && root.result.receipt && root.result.receipt.atomicCollapse ? String(root.result.receipt.atomicCollapse.mechanism || "—") : "—" }
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: "PRIME is the new reality. Run the project's own build and tests in the real tree — the receipt proves what was applied, not that you like it. `worldline return` restores the previous checkpoint through the same mechanism."
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }

        // review facts
        WlCard {
          visible: root.prepared
          title: "PREPARED TRANSACTION"
          hint: root.facts ? "prepared " + Model.fmtStamp(root.facts.prepared_at) : ""
          WlKV { k: "DECISION"; v: root.facts ? String(root.facts.decision || "?") : "—"; vColor: root.facts && root.facts.decision === "AUTHORIZED" ? Color.accent : Color.urgent }
          WlKV { k: "TRANSACTION"; v: root.facts ? String(root.facts.transaction_id || "") : "—" }
          WlKV { k: "CANDIDATE"; v: root.facts ? String(root.facts.candidate_alias || root.alias) + "  " + Model.shortHash(root.facts.candidate_content) : "—" }
          WlKV { k: "CURRENT PRIME"; v: root.facts ? Model.shortId(root.facts.current_prime, 8) + "  base " + Model.shortHash(root.facts.before_root) : "—" }
          WlKV { k: "CANDIDATE ROOT"; v: root.facts ? Model.shortHash(root.facts.candidate_root) : "—" }
          WlKV { k: "STAGED ROOT"; v: root.facts ? Model.shortHash(root.facts.staged_root) : "—" }
          RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            Button {
              text: root.showDetails ? "hide full hashes (D)" : "full hashes (D)"
              fontSize: Style.font.caption
              onClicked: root.showDetails = !root.showDetails
            }
          }
          ColumnLayout {
            visible: root.showDetails && root.prepared
            Layout.fillWidth: true
            spacing: Style.spacing.xxs
            WlKV { full: true; k: "before"; v: root.facts ? String(root.facts.before_root || "") : "" }
            WlKV { full: true; k: "candidate"; v: root.facts ? String(root.facts.candidate_root || "") : "" }
            WlKV { full: true; k: "staged"; v: root.facts ? String(root.facts.staged_root || "") : "" }
            WlKV { full: true; k: "content"; v: root.facts ? String(root.facts.candidate_content || "") : "" }
            WlKV { full: true; k: "prime"; v: root.facts ? String(root.facts.current_prime || "") : "" }
          }
        }

        WlCard {
          visible: root.prepared
          title: "MANAGED ROOTS — " + root.managedRoots.length
          Repeater {
            model: root.managedRoots
            delegate: RowLayout {
              required property var modelData
              Layout.fillWidth: true
              spacing: Style.spacing.sm
              Text { textFormat: Text.PlainText; text: modelData.primary ? "★" : "·"; color: Color.accent; font.family: Style.font.family; font.pixelSize: Style.font.caption }
              Text { textFormat: Text.PlainText; Layout.fillWidth: true; text: String(modelData.path || ""); color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideLeft }
              Text { textFormat: Text.PlainText; text: String(modelData.kind || ""); color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
              Text { textFormat: Text.PlainText; text: Model.shortId(modelData.rootKey, 8); color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
            }
          }
        }

        WlCard {
          visible: root.prepared
          title: "DELTA — " + root.operations.length + " OPERATION" + (root.operations.length === 1 ? "" : "S")
          hint: root.facts && root.facts.delta && root.facts.delta.summary
            ? "+" + Number(root.facts.delta.summary.added || 0) + " ~" + Number(root.facts.delta.summary.modified || 0) + " −" + Number(root.facts.delta.summary.deleted || 0)
            : ""
          Text {
            textFormat: Text.PlainText
            visible: root.operations.length === 0
            text: "No operations: the candidate is byte-identical to its base."
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Repeater {
            model: root.operations
            delegate: RowLayout {
              required property var modelData
              Layout.fillWidth: true
              spacing: Style.spacing.sm
              Text {
                textFormat: Text.PlainText
                text: Model.operationKind(modelData)
                color: modelData.op === "ADD" ? Color.accent : modelData.op === "DELETE" ? Color.urgent : Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                Layout.preferredWidth: Style.space(12)
              }
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: Model.operationLabel(modelData)
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                elide: Text.ElideLeft
              }
              Text {
                textFormat: Text.PlainText
                text: Model.shortId(modelData.rootKey, 8)
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        WlCard {
          visible: root.prepared || root.phase === "denied"
          urgent: root.conflicts.length > 0
          title: "CONFLICTS — " + (root.conflicts.length === 0 ? "NONE (evaluated)" : root.conflicts.length)
          Text {
            textFormat: Text.PlainText
            visible: root.conflicts.length === 0
            Layout.fillWidth: true
            text: "Every path this world touched still matches the fork base in the current PRIME."
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Repeater {
            model: root.conflicts
            delegate: Text {
              required property var modelData
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: "⚠ " + Model.operationLabel(modelData) + "  (" + String(modelData.op || "?") + ")"
              color: Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideLeft
            }
          }
        }

        WlCard {
          visible: root.prepared || root.phase === "denied"
          urgent: root.contamination.length > 0
          title: "FOREIGN CONTAMINATION — " + (root.contamination.length === 0 ? "NONE (evaluated)" : root.contamination.length)
          Text {
            textFormat: Text.PlainText
            visible: root.contamination.length === 0
            Layout.fillWidth: true
            text: "No write from outside this world reached managed state."
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
          Repeater {
            model: root.contamination
            delegate: Text {
              required property var modelData
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: "⚠ " + (typeof modelData === "object" ? JSON.stringify(modelData) : String(modelData))
              color: Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }

        WlCard {
          visible: root.prepared && root.dependencyChanges.length > 0
          title: "DEPENDENCY CHANGES — " + root.dependencyChanges.length
          Repeater {
            model: root.dependencyChanges
            delegate: Text {
              required property var modelData
              textFormat: Text.PlainText
              Layout.fillWidth: true
              text: String(modelData.change || "?") + "  " + String(modelData.name || "") + "  " + String(modelData.from === null || modelData.from === undefined ? "—" : modelData.from) + " → " + String(modelData.to === null || modelData.to === undefined ? "—" : modelData.to)
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }
      }
    }

    // ------------------------------------------------------------ warning + actions
    Rectangle {
      Layout.fillWidth: true
      implicitHeight: warningText.implicitHeight + Style.spacing.lg
      color: Util.alpha(root.prepared ? Color.urgent : Color.muted, root.prepared ? 0.12 : 0.08)
      border.color: Util.alpha(root.prepared ? Color.urgent : Color.muted, 0.4)
      border.width: 1
      radius: Style.cornerRadius
      Text {
        id: warningText
        textFormat: Text.PlainText
        anchors.fill: parent
        anchors.margins: Style.spacing.md
        wrapMode: Text.WordWrap
        text: root.commitBlockedReason !== "" && root.prepared
          ? root.commitBlockedReason
          : root.prepared
            ? "Review the facts above. Committing replaces the live mapping of every managed root in one atomic exchange; the daemon re-verifies PRIME against the reviewed base first."
            : root.phase === "committed"
              ? "Done. Press Escape or Back to return to the multiverse."
              : root.phase === "denied" || root.phase === "error"
                ? "Nothing changed. R prepares a fresh review, Escape goes back."
                : "Preparing…"
        color: root.prepared && root.commitBlockedReason === "" ? Color.foreground : Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.body
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.spacing.md
      Text {
        textFormat: Text.PlainText
        Layout.fillWidth: true
        text: root.prepared ? "Escape aborts the prepared transaction · Enter opens the final confirmation" : ""
        color: Color.muted
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
      Button {
        text: root.phase === "committed" ? "Back" : root.prepared ? "Abort" : "Back"
        bordered: true
        enabled: !root.busy
        onClicked: root.abort()
      }
      Button {
        visible: root.phase === "denied" || root.phase === "error"
        text: "Prepare again (R)"
        bordered: true
        enabled: !root.busy && !root.fixture
        onClicked: root.begin()
      }
      Button {
        visible: root.prepared
        text: root.actionKind === "return" ? "Reviewed — return to " + root.alias : "Reviewed — collapse " + root.alias
        opacity: enabled ? 1 : 0.4
        bordered: true
        selected: root.canCommit
        enabled: root.canCommit
        tooltipText: root.commitBlockedReason
        onClicked: root.confirm()
      }
    }
  }

  // The second, explicit confirmation, in the shell's native dialog so keyboard handling
  // (arrows, Enter, Escape) matches every other destructive confirmation on the desktop.
  ConfirmDialog {
    id: secondConfirm
    anchors.fill: parent
    opened: root.secondConfirmation
    message: root.actionKind === "return"
      ? "Atomically replace " + root.primeLabel + " with checkpoint " + root.alias + "? Transaction " + (root.facts ? Model.shortId(root.facts.transaction_id, 8) : "") + " will be committed as reviewed."
      : "Collapse " + root.alias + " into " + root.primeLabel + "? Transaction " + (root.facts ? Model.shortId(root.facts.transaction_id, 8) : "") + " will be committed exactly as reviewed."
    cancelText: "Keep reviewing"
    confirmText: root.actionKind === "return" ? "Return" : "Collapse"
    onCanceled: { root.secondConfirmation = false; root.requestFocus() }
    onConfirmed: root.execute()
  }
}
