import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// WORLDLINE mission control — a full-screen cockpit over the daemon's atomically replaced
// status.json. Everything painted is read from daemon state or from the JSON a `worldline`
// command just returned. Derived labels (risk, complexity, evidence) sit next to the inputs
// that produced them. UNASSESSED, UNAVAILABLE, STALE, and OFFLINE are rendered as answers.
//
// Modes: multiverse (graph + rails + inspector) · fork (ForkPanel) · collapse (CollapsePanel,
// prepare→review→commit) · roots (first-run guidance and managed-root review).
//
// Test seam: summon with {"statusPath": "/some/status.json", "fixture": true} to render fixture
// data. A fixture never executes a consequential command; the banner says so.
Item {
  id: root

  property var shell: ({})
  property var manifest: ({})
  property bool opened: false
  property string mode: "multiverse"
  property var status: null
  property string lastRaw: ""
  property bool statusLoadedOnce: false
  property double nowMs: Date.now()
  property int selectedIndex: -1
  property string actionKind: "collapse"
  property var adapters: []
  property bool adaptersLoading: false
  property var doctor: null
  property bool doctorLoading: false
  property string doctorError: ""
  property string actionError: ""
  property string actionNotice: ""
  property string lastCommittedReceipt: ""
  property string primeLabel: "PRIME"
  property bool fixture: false
  // Isolated-daemon harness: {"harness": {"runtimeDir": …, "home": …, "dataHome": …, "stateHome": …, "configHome": …}}
  // routes the status file AND every CLI call at a private daemon, with actions enabled.
  property var harness: null
  readonly property bool harnessed: harness !== null
  readonly property var cliEnvironment: {
    if (!root.harnessed) return ({})
    var env = {}
    if (root.harness.home) env["HOME"] = String(root.harness.home)
    if (root.harness.dataHome) env["XDG_DATA_HOME"] = String(root.harness.dataHome)
    if (root.harness.stateHome) env["XDG_STATE_HOME"] = String(root.harness.stateHome)
    if (root.harness.configHome) env["XDG_CONFIG_HOME"] = String(root.harness.configHome)
    if (root.harness.runtimeDir) env["XDG_RUNTIME_DIR"] = String(root.harness.runtimeDir)
    return env
  }
  readonly property string defaultStatusPath: Quickshell.env("XDG_RUNTIME_DIR") + "/worldline/status.json"
  property string statusPath: defaultStatusPath
  property string logText: ""
  property string logWorld: ""
  property bool logLoading: false
  property bool showWorldDetails: false
  property bool showMission: false
  property bool showCapabilities: false
  property bool showHelp: false
  property bool pendingDismiss: false
  property real graphZoom: 1.0
  property real graphPanX: 0
  property real graphPanY: 0
  // Until the operator zooms or pans, a generation wider than the viewport is fitted (zoomed out
  // and centred) so nothing is born clipped; 0 returns to that automatic fit.
  property bool graphAutoFit: true
  property real branchScale: 1.0
  property real siblingOpacity: 1.0
  property real pulsePhase: 0
  property string rootsPath: ""
  property var rootsDryRun: null
  property var rootsPendingRemove: null
  property string rootsError: ""
  property bool rootsBusy: rootsCall.busy
  property string rootsConfirmKind: ""
  property bool rootsConfirmOpen: false

  readonly property var serviceObject: shell && typeof shell.serviceFor === "function" ? shell.serviceFor("khephri.worldline") : null
  readonly property bool motionEnabled: {
    if (serviceObject && serviceObject.motionEnabled !== undefined) return serviceObject.motionEnabled === true
    return Model.widgetSetting(shell ? shell.barConfig : null, "khephri.worldline", "motionEnabled", true) === true
  }
  readonly property int motionDuration: motionEnabled ? 520 : 0
  readonly property string signalState: Model.signal(status, nowMs)
  readonly property bool live: signalState === "live" && !fixture
  readonly property bool initialized: status !== null && status.prime !== null && status.prime !== undefined
  readonly property var worlds: status && Array.isArray(status.worlds) ? status.worlds : []
  readonly property var jobs: status && Array.isArray(status.jobs) ? status.jobs : []
  readonly property var capabilities: status && status.capabilities ? status.capabilities : ({})
  readonly property var receipt: status && status.lastReceipt ? status.lastReceipt : null
  readonly property var selectedWorld: selectedIndex >= 0 && selectedIndex < worlds.length ? worlds[selectedIndex] : null
  readonly property bool hasSelection: selectedWorld !== null && selectedWorld.instanceId !== undefined
  readonly property int runningJobs: Model.runningJobCount(jobs)
  readonly property var selectedJob: hasSelection ? Model.activeJob(jobs, selectedWorld.instanceId) : null
  readonly property var selectedEvidence: Model.evidence(selectedWorld, !live && !fixture)
  readonly property var comparison: Model.siblingComparison(worlds, selectedWorld)
  readonly property var integrity: Model.integrityRows(doctor)
  readonly property var openTransactions: Model.openTransactions(doctor)
  readonly property bool integrityUrgent: integrity.some(function(row) { return row.urgent }) || openTransactions.length > 0
  readonly property string stateHome: root.harnessed && root.harness.stateHome ? String(root.harness.stateHome) : (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
  readonly property bool editing: (mode === "fork" && forkPanel.editing) || (mode === "roots" && rootsPathField.activeFocus)

  // ------------------------------------------------------------ lifecycle

  function open(payloadJson) {
    var payload = {}
    try { payload = typeof payloadJson === "string" ? JSON.parse(payloadJson || "{}") : (payloadJson || {}) }
    catch (error) { payload = {} }
    var requested = String(payload.mode || "multiverse")
    root.mode = ["fork", "multiverse", "collapse", "roots"].indexOf(requested) >= 0 ? requested : "multiverse"
    if (root.mode === "collapse") root.mode = "multiverse"   // collapse is entered from a selection, never cold
    root.fixture = payload.fixture === true
    root.harness = payload.harness && typeof payload.harness === "object" && payload.harness.runtimeDir ? payload.harness : null
    var nextPath = root.fixture && typeof payload.statusPath === "string" && payload.statusPath !== "" ? String(payload.statusPath)
      : root.harnessed ? String(root.harness.runtimeDir) + "/worldline/status.json"
      : root.defaultStatusPath
    if (nextPath !== root.statusPath) {
      root.statusPath = nextPath; root.lastRaw = ""; root.status = null; root.statusLoadedOnce = false
      root.doctor = null; root.doctorError = ""; root.adapters = []; root.selectedIndex = -1; root.logText = ""
      forkPanel.reset()
    }
    root.opened = true
    root.actionError = ""
    root.actionNotice = ""
    root.pendingDismiss = false
    root.nowMs = Date.now()
    statusFile.reload()
    statusApplyTimer.restart()
    if (payload.select) Qt.callLater(function() { root.selectAlias(String(payload.select)) })
    else if (root.selectedIndex < 0) root.selectedIndex = Model.defaultSelection(root.status)
    if (!root.fixture) { root.refreshAdapters(false); root.refreshDoctor(false) }
    Qt.callLater(function() {
      if (root.mode === "fork") forkPanel.focusMission()
      else keyCatcher.forceActiveFocus()
      graphCanvas.requestPaint()
    })
  }

  function dismiss() {
    if (root.mode === "collapse" && (collapsePanel.prepared || collapsePanel.phase === "preparing")) {
      root.pendingDismiss = true
      collapsePanel.abort()
      return
    }
    finishDismiss()
  }

  function finishDismiss() {
    root.pendingDismiss = false
    root.opened = false
    root.mode = "multiverse"
    root.rootsConfirmOpen = false
    if (root.shell && typeof root.shell.hide === "function") root.shell.hide("khephri.worldline")
  }

  function selectAlias(alias) {
    var index = Model.worldIndexByAlias(root.worlds, alias)
    if (index >= 0) root.selectedIndex = index
  }

  function applyStatus(raw) {
    var text = String(raw || "")
    if (text === root.lastRaw) return
    var parsed = Model.parseStatus(text)
    if (!parsed) return
    var previousActive = root.status ? String(root.status.activeWorld || "PRIME") : null
    root.lastRaw = text
    root.status = parsed
    if (root.selectedIndex >= root.worlds.length) root.selectedIndex = Math.max(-1, root.worlds.length - 1)
    if (root.selectedIndex < 0) root.selectedIndex = Model.defaultSelection(parsed)
    // `worldline inspect ALIAS` (or `switch`) changes the active world; the inspector follows it
    // unless the operator is typing. Before, the selection made at first load stuck forever.
    var nowActive = String(parsed.activeWorld || "PRIME")
    if (previousActive !== null && nowActive !== previousActive && nowActive !== "PRIME" && !root.editing) {
      var activeIndex = Model.worldIndexByAlias(root.worlds, nowActive)
      if (activeIndex >= 0) root.selectedIndex = activeIndex
    }
    var rec = parsed.lastReceipt
    if (rec && rec.receiptId && rec.atomicCollapse && rec.atomicCollapse.state === "COMMITTED") {
      if (!root.statusLoadedOnce) {
        root.lastCommittedReceipt = rec.receiptId
        root.primeLabel = "PRIME′"
      } else if (rec.receiptId !== root.lastCommittedReceipt) {
        root.lastCommittedReceipt = rec.receiptId
        root.primeLabel = "PRIME′"
        collapseAnimation.restart()
      }
    }
    root.statusLoadedOnce = true
    if (root.opened) graphCanvas.requestPaint()
  }

  function refreshAdapters(force) {
    if (root.fixture) return
    if (adaptersCall.busy) return
    root.adaptersLoading = true
    adaptersCall.run(["worldline", "adapters", "--json"], function(exitCode, stdout, stderr) {
      root.adaptersLoading = false
      if (exitCode === 0) {
        try { var parsed = JSON.parse(stdout); if (Array.isArray(parsed)) root.adapters = parsed } catch (error) { /* keep prior list */ }
      } else {
        var failure = Model.parseCliError(stderr, exitCode)
        root.actionError = "adapters: " + failure.code + ": " + failure.message
      }
    })
  }

  function refreshDoctor(reprobe) {
    if (root.fixture) return
    if (doctorCall.busy) return
    root.doctorLoading = true
    root.doctorError = ""
    var argv = reprobe ? ["worldline", "doctor", "--refresh", "--json"] : ["worldline", "doctor", "--json"]
    doctorCall.run(argv, function(exitCode, stdout, stderr) {
      root.doctorLoading = false
      if (exitCode === 0) {
        try { root.doctor = JSON.parse(stdout) } catch (error) { root.doctorError = "doctor returned unreadable JSON" }
      } else {
        var failure = Model.parseCliError(stderr, exitCode)
        root.doctorError = failure.code + ": " + failure.message
      }
    })
  }

  function loadLog() {
    if (!root.hasSelection || logCall.busy) return
    var instance = String(root.selectedWorld.instanceId)
    var path = root.stateHome + "/worldline/logs/" + instance + ".agent.stderr"
    root.logWorld = instance
    root.logLoading = true
    logCall.run(["tail", "-n", "60", "--", path], function(exitCode, stdout, stderr) {
      root.logLoading = false
      if (exitCode === 0) root.logText = stdout.trim() === "" ? "(agent wrote nothing to stderr)" : stdout
      else root.logText = "no agent log for this world yet (" + Model.firstLine(stderr) + ")"
    })
  }

  function runAction(argv, label, onDone) {
    if (root.fixture) { root.actionError = "fixture data — " + label + " is disabled"; return }
    if (!root.live) { root.actionError = "daemon signal is " + root.signalState + " — " + label + " is disabled"; return }
    if (actionCall.busy) { root.actionError = "another action is still running"; return }
    root.actionError = ""
    root.actionNotice = label + "…"
    actionCall.run(argv, function(exitCode, stdout, stderr) {
      if (exitCode === 0) {
        root.actionNotice = label + " done"
        if (onDone) onDone(stdout)
      } else {
        var failure = Model.parseCliError(stderr, exitCode)
        root.actionNotice = ""
        root.actionError = label + ": " + failure.code + ": " + failure.message
      }
      keyCatcher.forceActiveFocus()
    })
  }

  function inspectSelected() {
    if (!root.hasSelection) return
    var alias = root.selectedWorld.instanceId === (root.status.prime ? root.status.prime.instanceId : "") ? "PRIME" : String(root.selectedWorld.alias)
    runAction(["worldline", "inspect", "--json", "--", alias], "inspect " + alias)
  }

  function switchSelected() {
    if (!root.hasSelection || Model.isPrimeGeneration(root.selectedWorld)) return
    var alias = String(root.selectedWorld.alias)
    runAction(["worldline", "switch", "--json", "--", alias], "switch to " + alias)
  }

  function cancelSelected() {
    if (!root.hasSelection || !Model.isRunning(root.selectedWorld)) return
    var alias = String(root.selectedWorld.alias)
    runAction(["worldline", "cancel", "--json", "--", alias], "cancel " + alias)
  }

  function cancelJobWorld(instanceId) {
    var world = Model.worldByInstance(root.worlds, instanceId)
    if (!world) return
    runAction(["worldline", "cancel", "--json", "--", String(world.alias)], "cancel " + String(world.alias))
  }

  function abortTransaction(transactionId) {
    runAction(["worldline", "transaction", "abort", "--json", "--", String(transactionId)], "abort " + Model.shortId(transactionId, 8), function() { root.refreshDoctor(false) })
  }

  function startCollapse(kind) {
    if (!root.hasSelection) return
    if (kind === "collapse" && !Model.canCollapse(root.selectedWorld)) { root.actionError = "only a VALID world can collapse — this one is " + String(root.selectedWorld.state); return }
    if (kind === "return" && !Model.canReturnTo(root.selectedWorld)) { root.actionError = "return needs an ARCHIVED, COLLAPSED, or VALID checkpoint — this one is " + String(root.selectedWorld.state); return }
    if (!root.live && !root.fixture) { root.actionError = "daemon signal is " + root.signalState + " — review is disabled"; return }
    root.actionKind = kind
    root.actionError = ""
    root.mode = "collapse"
    collapsePanel.begin()
    keyCatcher.forceActiveFocus()
  }

  // ------------------------------------------------------------ managed roots

  function rootsPreview() {
    var path = root.rootsPath.trim()
    if (path === "") { root.rootsError = "enter an absolute directory path"; return }
    root.rootsError = ""
    root.rootsDryRun = null
    var argv = root.initialized ? ["worldline", "root", "add", "--dry-run", "--json", "--", path] : ["worldline", "init", "--dry-run", "--json", "--", path]
    if (root.fixture) { root.rootsError = "fixture data — dry run disabled"; return }
    rootsCall.run(argv, function(exitCode, stdout, stderr) {
      if (exitCode === 0) {
        try { root.rootsDryRun = JSON.parse(stdout) } catch (error) { root.rootsError = "dry run returned unreadable JSON" }
      } else {
        var failure = Model.parseCliError(stderr, exitCode)
        root.rootsError = failure.code + ": " + failure.message
      }
      keyCatcher.forceActiveFocus()
    })
  }

  function rootsApply() {
    if (!root.rootsDryRun || !root.live) return
    var path = root.rootsPath.trim()
    var argv = root.initialized ? ["worldline", "root", "add", "--yes", "--json", "--", path] : ["worldline", "init", "--yes", "--json", "--", path]
    root.rootsConfirmOpen = false
    rootsCall.run(argv, function(exitCode, stdout, stderr) {
      if (exitCode === 0) {
        root.rootsDryRun = null
        root.rootsPath = ""
        root.actionNotice = "registered " + path
        root.refreshDoctor(false)
      } else {
        var failure = Model.parseCliError(stderr, exitCode)
        root.rootsError = failure.code + ": " + failure.message
      }
      keyCatcher.forceActiveFocus()
    })
  }

  function rootsPreviewRemove(path) {
    if (root.fixture) { root.rootsError = "fixture data — dry run disabled"; return }
    root.rootsError = ""
    root.rootsPendingRemove = null
    rootsCall.run(["worldline", "root", "remove", "--dry-run", "--json", "--", String(path)], function(exitCode, stdout, stderr) {
      if (exitCode === 0) {
        try { root.rootsPendingRemove = JSON.parse(stdout) } catch (error) { root.rootsError = "dry run returned unreadable JSON" }
      } else {
        var failure = Model.parseCliError(stderr, exitCode)
        root.rootsError = failure.code + ": " + failure.message
      }
      keyCatcher.forceActiveFocus()
    })
  }

  function rootsApplyRemove() {
    if (!root.rootsPendingRemove || !root.live) return
    var path = String(root.rootsPendingRemove.roots[0].path)
    root.rootsConfirmOpen = false
    rootsCall.run(["worldline", "root", "remove", "--yes", "--json", "--", path], function(exitCode, stdout, stderr) {
      if (exitCode === 0) {
        root.rootsPendingRemove = null
        root.actionNotice = "removed " + path + " (directory materialized back in place)"
        root.refreshDoctor(false)
      } else {
        var failure = Model.parseCliError(stderr, exitCode)
        root.rootsError = failure.code + ": " + failure.message
      }
      keyCatcher.forceActiveFocus()
    })
  }

  // ------------------------------------------------------------ tree navigation

  function parentIndex(index) {
    if (index < 0 || index >= worlds.length) return index
    var parent = worlds[index].parent
    for (var i = 0; i < worlds.length; i++) if (worlds[i].instanceId === parent) return i
    return index
  }

  function childIndex(index) {
    if (index < 0 || index >= worlds.length) return index
    var id = worlds[index].instanceId
    for (var i = 0; i < worlds.length; i++) if (worlds[i].parent === id) return i
    return index
  }

  function siblingIndex(index, delta) {
    if (index < 0 || index >= worlds.length) return index
    var parent = worlds[index].parent
    var siblings = []
    for (var i = 0; i < worlds.length; i++) if (worlds[i].parent === parent) siblings.push(i)
    var position = siblings.indexOf(index)
    return siblings[(position + delta + siblings.length) % siblings.length]
  }

  function toneColor(tone) {
    return tone === "accent" ? Color.accent : tone === "urgent" ? Color.urgent : tone === "foreground" ? Color.foreground : Color.muted
  }

  // ------------------------------------------------------------ plumbing

  WlCall { id: adaptersCall; environment: root.cliEnvironment }
  WlCall { id: doctorCall; environment: root.cliEnvironment }
  WlCall { id: actionCall; environment: root.cliEnvironment }
  WlCall { id: logCall; environment: root.cliEnvironment }
  WlCall { id: rootsCall; environment: root.cliEnvironment }

  FileView {
    id: statusFile
    path: root.statusPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyStatus(text())
    onFileChanged: statusApplyTimer.restart()
    onLoadFailed: { if (root.fixture) root.actionError = "fixture status file could not be read: " + root.statusPath }
  }

  // While open: tick the clock every second (staleness, lifetimes) and reload at 2 s so an
  // os.replace the watcher missed is still caught. Nothing runs while the cockpit is closed.
  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    property int ticks: 0
    onTriggered: {
      root.nowMs = Date.now()
      ticks += 1
      if (ticks % 2 === 0) { statusFile.reload(); statusApplyTimer.restart() }
      if (ticks % 15 === 0 && root.diagnosticsAuto) root.refreshDoctor(false)
    }
  }
  property bool diagnosticsAuto: true

  Timer {
    id: statusApplyTimer
    interval: 120
    repeat: false
    onTriggered: root.applyStatus(statusFile.text())
  }

  // Running-world pulse: only when motion is enabled and something is actually running.
  Timer {
    interval: 90
    running: root.opened && root.motionEnabled && root.runningJobs > 0 && root.mode === "multiverse"
    repeat: true
    onTriggered: { root.pulsePhase = (root.pulsePhase + 0.045) % 1; graphCanvas.requestPaint() }
  }

  SequentialAnimation {
    id: collapseAnimation
    running: false
    ParallelAnimation {
      NumberAnimation { target: root; property: "branchScale"; from: 1.0; to: 0.12; duration: root.motionDuration; easing.type: Easing.InOutCubic }
      NumberAnimation { target: root; property: "siblingOpacity"; from: 1.0; to: 0.12; duration: root.motionDuration; easing.type: Easing.InOutCubic }
    }
    PauseAnimation { duration: root.motionEnabled ? 180 : 0 }
    ScriptAction { script: { root.branchScale = 1.0; root.siblingOpacity = 1.0; graphCanvas.requestPaint() } }
  }

  onBranchScaleChanged: if (root.opened) graphCanvas.requestPaint()
  onSiblingOpacityChanged: if (root.opened) graphCanvas.requestPaint()
  onSelectedIndexChanged: { if (root.opened) graphCanvas.requestPaint(); root.logText = ""; root.logWorld = "" }
  onModeChanged: Qt.callLater(function() { keyCatcher.forceActiveFocus() })

  // ------------------------------------------------------------ the cockpit

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: Color.background
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "worldline-multiverse"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    readonly property int railWidth: Math.round(Math.max(Style.space(220), Math.min(Style.space(330), width * 0.24)))
    readonly property int inspectorWidth: Math.round(Math.max(Style.space(240), Math.min(Style.space(360), width * 0.26)))
    readonly property bool compact: width < Style.space(1100)

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (root.rootsConfirmOpen) { if (rootsConfirm.handleKey(event)) event.accepted = true; return }
        if (root.mode === "collapse") { if (collapsePanel.handleKey(event)) event.accepted = true; return }
        if (root.mode === "fork") { if (forkPanel.handleKey(event)) event.accepted = true; return }
        if (root.mode === "roots") {
          if (rootsPathField.activeFocus) {
            if (event.key === Qt.Key_Escape) { keyCatcher.forceActiveFocus(); event.accepted = true }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.rootsPreview(); event.accepted = true }
            return
          }
          if (event.key === Qt.Key_Escape) { root.mode = "multiverse"; event.accepted = true }
          return
        }
        // multiverse mode
        if (event.key === Qt.Key_Escape) { if (root.showHelp) root.showHelp = false; else root.dismiss(); event.accepted = true; return }
        if (event.text === "?" || event.key === Qt.Key_F1) { root.showHelp = !root.showHelp; event.accepted = true; return }
        if (event.key === Qt.Key_F || event.text === "f") { root.mode = "fork"; event.accepted = true; return }
        if (event.text === "d" || event.text === "D") { root.refreshDoctor(true); event.accepted = true; return }
        if (event.text === "l" || event.text === "L") { root.loadLog(); event.accepted = true; return }
        if (event.text === "c" || event.text === "C") { root.startCollapse("collapse"); event.accepted = true; return }
        if (event.text === "r" || event.text === "R") { root.startCollapse("return"); event.accepted = true; return }
        if (event.text === "x" || event.text === "X") { root.cancelSelected(); event.accepted = true; return }
        if (event.text === "i" || event.text === "I") { root.inspectSelected(); event.accepted = true; return }
        if (event.text === "s" || event.text === "S") { root.switchSelected(); event.accepted = true; return }
        if (event.text === "m" || event.text === "M") { root.mode = "roots"; event.accepted = true; return }
        if (event.text === "0") { root.graphAutoFit = true; root.graphZoom = 1; root.graphPanX = 0; root.graphPanY = 0; graphCanvas.requestPaint(); event.accepted = true; return }
        if (event.key === Qt.Key_Left || event.text === "h") { root.selectedIndex = root.parentIndex(root.selectedIndex); event.accepted = true; return }
        if (event.key === Qt.Key_Right || event.text === "l") { root.selectedIndex = root.childIndex(root.selectedIndex); event.accepted = true; return }
        if (event.key === Qt.Key_Up || event.text === "k") { root.selectedIndex = root.siblingIndex(root.selectedIndex, -1); event.accepted = true; return }
        if (event.key === Qt.Key_Down || event.text === "j") { root.selectedIndex = root.siblingIndex(root.selectedIndex, 1); event.accepted = true; return }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          if (root.hasSelection && Model.canCollapse(root.selectedWorld)) root.startCollapse("collapse")
          else root.inspectSelected()
          event.accepted = true
        }
      }

    Rectangle {
      anchors.fill: parent
      color: Color.background

      ColumnLayout {
        anchors.fill: parent
        anchors.margins: Style.spacing.lg
        spacing: Style.spacing.md

        // ---------------------------------------------------- header
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.md
          ColumnLayout {
            spacing: 0
            Text {
              textFormat: Text.PlainText
              text: "W O R L D L I N E"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.display
              font.bold: true
              font.letterSpacing: Style.spaceReal(1)
            }
            Text {
              textFormat: Text.PlainText
              text: "MISSION CONTROL · a world is a proposal, PRIME is the only reality"
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.letterSpacing: Style.spaceReal(1.0)
            }
          }
          Item { Layout.fillWidth: true }
          RowLayout {
            spacing: Style.spacing.sm
            WlChip {
              label: root.fixture ? "FIXTURE DATA" : root.harnessed && root.signalState === "live" ? "HARNESS LIVE" : (root.signalState === "live" ? "SIGNAL LIVE · v" + String(root.status.daemon.version || "?") : root.signalState === "stale" ? "SIGNAL STALE · " + Model.fmtAge(Model.daemonAgeMs(root.status, root.nowMs)) : "NO SIGNAL")
              glyph: root.fixture ? "⚗" : root.signalState === "live" ? "●" : root.signalState === "stale" ? "◐" : "○"
              tone: root.fixture ? "foreground" : root.signalState === "live" ? "accent" : "urgent"
              filled: root.signalState !== "live"
            }
            WlChip {
              label: root.initialized ? root.primeLabel + (root.status.prime.dirty ? " · DIRTY" : "") : "NO PRIME"
              glyph: root.initialized ? "◎" : "!"
              tone: root.initialized ? (root.status.prime.dirty ? "urgent" : "accent") : "urgent"
            }
            WlChip {
              visible: root.initialized
              label: "ACTIVE " + String(root.status ? root.status.activeWorld || "PRIME" : "PRIME")
              tone: String(root.status ? root.status.activeWorld || "PRIME" : "PRIME") === "PRIME" ? "foreground" : "accent"
            }
            WlChip {
              visible: root.runningJobs > 0
              label: root.runningJobs + " RUNNING"
              glyph: "▶"
              tone: "accent"
              filled: true
            }
            WlChip {
              visible: root.integrityUrgent
              label: "DIAGNOSTICS"
              glyph: "⚠"
              tone: "urgent"
              filled: true
            }
          }
          Button { text: "Fork (F)"; bordered: true; enabled: root.mode !== "collapse"; opacity: enabled ? 1 : 0.4; onClicked: root.mode = "fork" }
          Button { text: "Roots (M)"; bordered: true; enabled: root.mode !== "collapse"; opacity: enabled ? 1 : 0.4; onClicked: root.mode = "roots" }
          Button { text: "?"; bordered: true; onClicked: root.showHelp = !root.showHelp }
          Button { text: "×"; bordered: true; onClicked: root.dismiss() }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Util.alpha(Color.muted, 0.5) }

        // fixture / harness banner
        Rectangle {
          Layout.fillWidth: true
          visible: root.fixture || root.harnessed
          implicitHeight: fixtureText.implicitHeight + Style.spacing.md
          color: Util.alpha(root.fixture ? Color.urgent : Color.accent, 0.10)
          border.color: Util.alpha(root.fixture ? Color.urgent : Color.accent, 0.5)
          border.width: 1
          radius: Style.cornerRadius
          Text {
            id: fixtureText
            textFormat: Text.PlainText
            anchors.fill: parent
            anchors.margins: Style.spacing.sm
            text: root.fixture
              ? "FIXTURE DATA from " + root.statusPath + " — nothing here is live and every consequential action is disabled."
              : "ISOLATED HARNESS — status and every command address the private daemon at " + (root.harnessed ? String(root.harness.runtimeDir) : "") + ", not your real WORLDLINE."
            color: root.fixture ? Color.urgent : Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }
        }

        // ---------------------------------------------------- body
        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          // ============ FORK ============
          ForkPanel {
            id: forkPanel
            anchors.fill: parent
            visible: root.mode === "fork"
            adapters: root.adapters
            adaptersLoading: root.adaptersLoading
            worlds: root.worlds
            initialized: root.initialized
            signalState: root.signalState
            fixture: root.fixture
            primeLabel: root.primeLabel
            cliEnvironment: root.cliEnvironment
            onBack: root.mode = "multiverse"
            onRequestFocus: keyCatcher.forceActiveFocus()
            onRefreshAdapters: root.refreshAdapters(true)
            onLaunched: function(summary) {
              root.mode = "multiverse"
              root.actionNotice = summary.race ? "race launched: " + summary.aliases.join(" · ") : "fork launched: " + summary.aliases.join("")
              Qt.callLater(function() { statusFile.reload(); statusApplyTimer.restart() })
              if (summary.aliases.length > 0) Qt.callLater(function() { root.selectAlias(summary.aliases[0]) })
            }
          }

          // ============ COLLAPSE / RETURN ============
          CollapsePanel {
            id: collapsePanel
            anchors.fill: parent
            visible: root.mode === "collapse"
            world: root.selectedWorld || ({})
            status: root.status || ({})
            actionKind: root.actionKind
            signalState: root.signalState
            fixture: root.fixture
            primeLabel: root.primeLabel
            cliEnvironment: root.cliEnvironment
            onRequestFocus: keyCatcher.forceActiveFocus()
            onCancelled: {
              if (root.pendingDismiss) { root.finishDismiss(); return }
              root.mode = "multiverse"
              root.refreshDoctor(false)
            }
            onCommitted: function(result) {
              root.actionNotice = "committed · receipt " + (result && result.receipt ? Model.shortHash(result.receipt.receiptId) : "")
              statusFile.reload(); statusApplyTimer.restart()
              root.refreshDoctor(false)
            }
          }

          // ============ ROOTS ============
          Flickable {
            anchors.fill: parent
            visible: root.mode === "roots"
            contentHeight: rootsColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ColumnLayout {
              id: rootsColumn
              width: parent.width
              spacing: Style.spacing.md

              Text {
                textFormat: Text.PlainText
                text: root.initialized ? "MANAGED ROOTS" : "FIRST RUN — REGISTER A ROOT"
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.heading
                font.bold: true
                font.letterSpacing: Style.spaceReal(0.6)
              }
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "WORLDLINE captures the directories you nominate (that capture is PRIME), forks them into isolated worlds, and commits exactly one world back through a single atomic exchange the proved kernel authorized. Registration MOVES the directory into the managed store and leaves a symlink at the exact same path, so every tool keeps working; removal materializes the current bytes back in place. Both steps show a dry run first and require an explicit confirmation."
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              WlCard {
                title: "REGISTERED — " + (root.initialized ? root.status.prime.roots.length : 0)
                urgent: root.doctor && root.doctor.rootIntegrity && root.doctor.rootIntegrity.state !== "OK"
                Text {
                  textFormat: Text.PlainText
                  visible: !root.initialized
                  Layout.fillWidth: true
                  text: "Nothing is registered. The daemon is running and owns no directory — that is the healthy uninitialized state, not a fault."
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
                Repeater {
                  model: root.initialized && Array.isArray(root.status.prime.roots) ? root.status.prime.roots : []
                  delegate: RowLayout {
                    id: rootRow
                    required property var modelData
                    readonly property var integrityEntry: {
                      if (!root.doctor || !root.doctor.rootIntegrity) return null
                      var rows = root.doctor.rootIntegrity.roots || []
                      for (var i = 0; i < rows.length; i++) if (rows[i].rootKey === modelData.rootKey) return rows[i]
                      return null
                    }
                    Layout.fillWidth: true
                    spacing: Style.spacing.sm
                    Text { textFormat: Text.PlainText; text: modelData.primary ? "★" : "·"; color: Color.accent; font.family: Style.font.family; font.pixelSize: Style.font.body }
                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: 0
                      Text { textFormat: Text.PlainText; Layout.fillWidth: true; text: String(modelData.path || ""); color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; elide: Text.ElideLeft }
                      Text {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        text: String(modelData.kind || "") + (modelData.primary ? " · primary (agents run here, .worldline.json read here)" : "") + "  ·  key " + Model.shortId(modelData.rootKey, 12) + "  ·  manifest " + Model.shortHash(modelData.manifestRoot)
                        color: Color.muted
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }
                    WlChip {
                      label: rootRow.integrityEntry ? String(rootRow.integrityEntry.state) : (root.doctorLoading ? "PROBING" : "UNASSESSED")
                      glyph: rootRow.integrityEntry && rootRow.integrityEntry.state === "OK" ? "✓" : "○"
                      tone: rootRow.integrityEntry ? (rootRow.integrityEntry.state === "OK" ? "accent" : "urgent") : "muted"
                      tooltipText: rootRow.integrityEntry && rootRow.integrityEntry.reason ? String(rootRow.integrityEntry.reason) : ""
                    }
                    Button {
                      text: "Remove…"
                      fontSize: Style.font.caption
                      enabled: root.live && !root.rootsBusy
                      onClicked: root.rootsPreviewRemove(String(modelData.path))
                    }
                  }
                }
              }

              WlCard {
                visible: root.rootsPendingRemove !== null
                urgent: true
                title: "REMOVE — DRY RUN"
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: root.rootsPendingRemove ? String(root.rootsPendingRemove.effect || "") : ""
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                }
                Repeater {
                  model: root.rootsPendingRemove ? root.rootsPendingRemove.roots : []
                  delegate: Text { required property var modelData; textFormat: Text.PlainText; Layout.fillWidth: true; text: "  " + String(modelData.path) + "  [" + String(modelData.kind) + "]"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideLeft }
                }
                RowLayout {
                  Layout.fillWidth: true
                  Item { Layout.fillWidth: true }
                  Button { text: "Keep"; bordered: true; onClicked: root.rootsPendingRemove = null }
                  Button {
                    text: "Remove this root"
                    bordered: true
                    enabled: root.live && !root.rootsBusy
                    onClicked: { root.rootsConfirmKind = "remove"; root.rootsConfirmOpen = true }
                  }
                }
              }

              WlCard {
                title: root.initialized ? "ADD A ROOT" : "REGISTER THE FIRST ROOT"
                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.spacing.sm
                  TextField {
                    id: rootsPathField
                    Layout.fillWidth: true
                    Keys.priority: Keys.BeforeItem
                    Keys.onPressed: function(event) {
                      if (event.key === Qt.Key_Escape) { keyCatcher.forceActiveFocus(); event.accepted = true }
                      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.rootsPreview(); event.accepted = true }
                    }
                    placeholderText: "/home/you/Projects/your-project   (absolute path, a real directory, not a symlink)"
                    text: root.rootsPath
                    onTextEdited: { root.rootsPath = text; root.rootsDryRun = null }
                    enabled: !root.fixture
                  }
                  Button {
                    text: root.rootsBusy ? "…" : "Dry run"
                    bordered: true
                    enabled: root.live && !root.rootsBusy && root.rootsPath.trim() !== ""
                    onClicked: root.rootsPreview()
                  }
                }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: "Same as: worldline " + (root.initialized ? "root add" : "init") + " <path>. Refusals you may see: ROOT_IS_SYMLINK, OVERLAPPING_ROOT, CROSS_FILESYSTEM_ROOT (must share the data store's filesystem), WORLDLINE_SELF_CAPTURE, ROOT_SET_BUSY (a world is running or a transaction is open)."
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
                Text {
                  textFormat: Text.PlainText
                  visible: root.rootsError !== ""
                  Layout.fillWidth: true
                  text: root.rootsError
                  color: Color.urgent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              WlCard {
                visible: root.rootsDryRun !== null
                title: "DRY RUN — WHAT WOULD CHANGE"
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: root.rootsDryRun ? String(root.rootsDryRun.effect || "") : ""
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                }
                Repeater {
                  model: root.rootsDryRun ? root.rootsDryRun.roots : []
                  delegate: Text {
                    required property var modelData
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: "  " + String(modelData.path) + "  [" + String(modelData.kind) + "]" + (modelData.primary ? "  PRIMARY" : "")
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideLeft
                  }
                }
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: "Nothing has moved yet. Confirming runs the same command with --yes."
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                RowLayout {
                  Layout.fillWidth: true
                  Item { Layout.fillWidth: true }
                  Button { text: "Discard"; bordered: true; onClicked: root.rootsDryRun = null }
                  Button {
                    text: root.initialized ? "Add this root" : "Register and create PRIME"
                    bordered: true
                    selected: true
                    enabled: root.live && !root.rootsBusy
                    onClicked: { root.rootsConfirmKind = "add"; root.rootsConfirmOpen = true }
                  }
                }
              }

              WlCard {
                title: "NEXT"
                Text {
                  textFormat: Text.PlainText
                  Layout.fillWidth: true
                  text: "1. Register a root (above).\n2. Declare evidence in <primary-root>/.worldline.json — a required build and test check. Without it every candidate finalizes UNASSESSED and risk cannot drop below MEDIUM.\n3. Fork (F): one agent, or a deliberate three-agent race.\n4. Compare candidates in the inspector, then review and commit one prepared transaction (C).\n5. If you dislike the result, return (R) restores the previous checkpoint through the same atomic mechanism."
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }
              RowLayout { Layout.fillWidth: true; Item { Layout.fillWidth: true } Button { text: "Back to multiverse (Esc)"; bordered: true; onClicked: root.mode = "multiverse" } }
            }
          }

          // ============ MULTIVERSE ============
          RowLayout {
            anchors.fill: parent
            visible: root.mode === "multiverse"
            spacing: Style.spacing.md

            // -------- left rail
            Flickable {
              Layout.preferredWidth: panel.railWidth
              Layout.minimumWidth: Style.space(200)
              Layout.fillHeight: true
              contentHeight: leftRail.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              ColumnLayout {
                id: leftRail
                width: parent.width
                spacing: Style.spacing.md

                WlCard {
                  title: "REALITY"
                  hint: root.initialized ? Model.fmtAge(Model.daemonAgeMs(root.status, root.nowMs)).replace(" ago", " old") : ""
                  Text {
                    textFormat: Text.PlainText
                    visible: !root.initialized
                    Layout.fillWidth: true
                    text: root.signalState === "offline" ? "No daemon signal." : "No PRIME. Press M to register a root."
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                  WlKV { visible: root.initialized; k: root.primeLabel; v: root.initialized ? Model.shortHash(root.status.prime.id) : "—" }
                  WlKV { visible: root.initialized; k: "GENERATION"; v: root.initialized ? Model.shortId(root.status.prime.generation, 8) : "—" }
                  WlKV {
                    visible: root.initialized
                    k: "DIRTY"
                    v: root.initialized ? (root.status.prime.dirty ? "YES — recaptured before the next mutation" : "no") : "—"
                    vColor: root.initialized && root.status.prime.dirty ? Color.urgent : Color.foreground
                  }
                  Repeater {
                    model: root.initialized && Array.isArray(root.status.prime.roots) ? root.status.prime.roots : []
                    delegate: RowLayout {
                      required property var modelData
                      Layout.fillWidth: true
                      spacing: Style.spacing.xs
                      Text { textFormat: Text.PlainText; text: modelData.primary ? "★" : "·"; color: Color.accent; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                      Text { textFormat: Text.PlainText; Layout.fillWidth: true; text: String(modelData.path || ""); color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideLeft }
                      Text { textFormat: Text.PlainText; text: String(modelData.kind || ""); color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                    }
                  }
                  RowLayout {
                    Layout.fillWidth: true
                    Item { Layout.fillWidth: true }
                    Button { text: "manage roots (M)"; fontSize: Style.font.caption; onClicked: root.mode = "roots" }
                  }
                }

                WlCard {
                  title: "LAST COLLAPSE"
                  visible: root.receipt !== null && root.receipt.receiptId !== undefined
                  WlKV { k: "RECEIPT"; v: root.receipt ? Model.shortHash(root.receipt.receiptId) : "—"; vColor: Color.accent }
                  WlKV {
                    k: "STATE"
                    v: root.receipt && root.receipt.atomicCollapse ? String(root.receipt.atomicCollapse.state || "—") + " · " + String(root.receipt.atomicCollapse.mechanism || "") : "—"
                  }
                  WlKV {
                    k: "INVARIANTS"
                    v: {
                      var ip = root.receipt ? root.receipt.invariantPreservation : null
                      if (!ip) return "—"
                      if (typeof ip === "string") return ip
                      return String(ip.state || "?") + (ip.checks ? " · " + Number(ip.checks) + " checks" : "") + (ip.reason ? " · " + ip.reason : "")
                    }
                    vColor: root.receipt && root.receipt.invariantPreservation && root.receipt.invariantPreservation.state === "PROVED" ? Color.accent : Color.foreground
                  }
                  WlKV {
                    k: "CANDIDATE"
                    v: {
                      if (!root.receipt) return "—"
                      var w = Model.worldByContent(root.worlds, root.receipt.candidateWorld)
                      if (!w) return Model.shortHash(root.receipt.candidateWorld)
                      var isPrime = root.status && root.status.prime && w.instanceId === root.status.prime.instanceId
                      return String(w.alias) + (isPrime ? "  (now " + root.primeLabel + ")" : "")
                    }
                  }
                  WlKV { k: "MERGE SET"; v: root.receipt && root.receipt.mergeSet ? (root.receipt.mergeSet.files || []).length + " files · " + (root.receipt.mergeSet.generatedArtifacts || []).length + " generated · " + (root.receipt.mergeSet.dependencyChanges || []).length + " dep changes" : "—" }
                  WlKV { k: "NON-CLAIMS"; v: root.receipt && Array.isArray(root.receipt.nonClaims) ? root.receipt.nonClaims.length + " stated" : "—" }
                  Repeater {
                    model: root.showWorldDetails && root.receipt && Array.isArray(root.receipt.nonClaims) ? root.receipt.nonClaims : []
                    delegate: Text { required property var modelData; textFormat: Text.PlainText; Layout.fillWidth: true; text: "· " + String(modelData); color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption; wrapMode: Text.WordWrap }
                  }
                }

                WlCard {
                  title: "JOBS — " + root.runningJobs + " RUNNING"
                  visible: root.jobs.length > 0
                  Repeater {
                    model: {
                      var sorted = root.jobs.slice()
                      sorted.sort(function(a, b) { return String(b.started || "").localeCompare(String(a.started || "")) })
                      return sorted.slice(0, 6)
                    }
                    delegate: ColumnLayout {
                      id: jobRow
                      required property var modelData
                      readonly property var jobWorld: Model.worldByInstance(root.worlds, modelData.world)
                      readonly property bool active: modelData.state === "RUNNING" || modelData.state === "STARTING" || modelData.state === "FINALIZING"
                      Layout.fillWidth: true
                      spacing: 0
                      RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.spacing.sm
                        Text {
                          textFormat: Text.PlainText
                          text: Model.jobLabel(modelData)
                          color: jobRow.active ? Color.accent : (modelData.state === "DEGRADED" || modelData.state === "DEAD" || modelData.state === "TIMED_OUT" || modelData.state === "CANCELLED" ? Color.urgent : Color.muted)
                          font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true
                        }
                        Text {
                          textFormat: Text.PlainText
                          Layout.fillWidth: true
                          text: jobRow.jobWorld ? String(jobRow.jobWorld.alias) + (root.status && root.status.prime && jobRow.jobWorld.instanceId === root.status.prime.instanceId ? " ★" : "") : Model.shortId(modelData.world, 8)
                          color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideRight
                        }
                        Text { textFormat: Text.PlainText; text: Model.fmtDuration(modelData.started, modelData.ended, root.nowMs); color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                        Button {
                          visible: jobRow.active
                          text: "cancel"
                          fontSize: Style.font.caption
                          enabled: root.live
                          onClicked: root.cancelJobWorld(modelData.world)
                        }
                      }
                      Text {
                        textFormat: Text.PlainText
                        visible: Model.errorText(modelData.error) !== ""
                        Layout.fillWidth: true
                        text: Model.errorText(modelData.error)
                        color: Color.urgent
                        font.family: Style.font.family; font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }
                  }
                }

                WlCard {
                  title: "DIAGNOSTICS"
                  hint: root.doctorLoading ? "probing…" : (root.doctor ? "worldline doctor" : "")
                  urgent: root.integrityUrgent
                  Text {
                    textFormat: Text.PlainText
                    visible: root.doctorError !== ""
                    Layout.fillWidth: true
                    text: root.doctorError
                    color: Color.urgent
                    font.family: Style.font.family; font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                  Text {
                    textFormat: Text.PlainText
                    visible: !root.doctor && root.doctorError === ""
                    Layout.fillWidth: true
                    text: root.fixture ? "not probed for fixture data" : (root.doctorLoading ? "running worldline doctor…" : "no doctor report yet")
                    color: Color.muted
                    font.family: Style.font.family; font.pixelSize: Style.font.caption
                  }
                  Repeater {
                    model: root.integrity
                    delegate: ColumnLayout {
                      required property var modelData
                      Layout.fillWidth: true
                      spacing: 0
                      RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.spacing.sm
                        Text { textFormat: Text.PlainText; text: modelData.urgent ? "⚠" : "✓"; color: modelData.urgent ? Color.urgent : Color.accent; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
                        Text { textFormat: Text.PlainText; Layout.fillWidth: true; text: modelData.name; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                        Text { textFormat: Text.PlainText; text: modelData.state; color: modelData.urgent ? Color.urgent : Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
                      }
                      Text {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        text: modelData.detail
                        color: Color.muted
                        font.family: Style.font.family; font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                      }
                    }
                  }
                  Repeater {
                    model: root.openTransactions
                    delegate: RowLayout {
                      required property var modelData
                      Layout.fillWidth: true
                      spacing: Style.spacing.sm
                      Text { textFormat: Text.PlainText; text: "⚠"; color: Color.urgent; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
                      Text {
                        textFormat: Text.PlainText
                        Layout.fillWidth: true
                        text: "open " + String(modelData.kind) + " " + Model.shortId(modelData.transactionId, 8) + " for " + String(modelData.candidateAlias || "?") + " (" + String(modelData.state) + ") — blocks root-set changes"
                        color: Color.foreground
                        font.family: Style.font.family; font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                      }
                      Button { text: "abort"; fontSize: Style.font.caption; enabled: root.live; onClicked: root.abortTransaction(modelData.transactionId) }
                    }
                  }
                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.spacing.sm
                    Button { text: root.showCapabilities ? "hide capabilities" : "capabilities"; fontSize: Style.font.caption; onClicked: root.showCapabilities = !root.showCapabilities }
                    Item { Layout.fillWidth: true }
                    Button { text: "re-probe (D)"; fontSize: Style.font.caption; enabled: !root.doctorLoading && !root.fixture; onClicked: root.refreshDoctor(true) }
                  }
                  Repeater {
                    model: root.showCapabilities ? Model.capabilityRows(root.doctor || root.capabilities) : []
                    delegate: RowLayout {
                      required property var modelData
                      Layout.fillWidth: true
                      spacing: Style.spacing.sm
                      Text { textFormat: Text.PlainText; text: modelData.ok ? "✓" : "⊘"; color: modelData.ok ? Color.accent : Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                      Text { textFormat: Text.PlainText; text: modelData.name; color: modelData.ok ? Color.foreground : Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                      Item { Layout.fillWidth: true }
                      Text { textFormat: Text.PlainText; Layout.maximumWidth: Style.space(150); text: modelData.note; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideRight; horizontalAlignment: Text.AlignRight }
                    }
                  }
                }

                WlCard {
                  title: "ADAPTERS"
                  hint: root.adaptersLoading ? "probing…" : ""
                  visible: root.adapters.length > 0 || root.adaptersLoading
                  Repeater {
                    model: root.adapters
                    delegate: RowLayout {
                      required property var modelData
                      Layout.fillWidth: true
                      spacing: Style.spacing.sm
                      Text { textFormat: Text.PlainText; text: modelData.state === "AVAILABLE" ? "✓" : "⊘"; color: modelData.state === "AVAILABLE" ? Color.accent : Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                      Text { textFormat: Text.PlainText; text: String(modelData.name || ""); color: modelData.state === "AVAILABLE" ? Color.foreground : Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                      Item { Layout.fillWidth: true }
                      Text { textFormat: Text.PlainText; Layout.maximumWidth: Style.space(160); text: modelData.state === "AVAILABLE" ? "AVAILABLE" : String(modelData.reason || modelData.state || ""); color: modelData.state === "AVAILABLE" ? Color.accent : Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
                    }
                  }
                }
              }
            }

            // -------- center
            ColumnLayout {
              Layout.fillWidth: true
              Layout.fillHeight: true
              spacing: Style.spacing.sm

              Item {
                id: graphViewport
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                // empty states
                WlCard {
                  visible: root.signalState === "offline" && !root.fixture
                  anchors.centerIn: parent
                  width: Math.min(parent.width - Style.space(40), Style.space(520))
                  urgent: true
                  title: "NO SIGNAL"
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.status ? "The daemon wrote STOPPED or has not published for a long time." : "No status document has been read from " + root.statusPath + "."
                    color: Color.foreground
                    font.family: Style.font.family; font.pixelSize: Style.font.body
                    wrapMode: Text.WordWrap
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: "Check the daemon:\n  systemctl --user status worldlined.service\n  journalctl --user -u worldlined.service -n 50\nStart it with:\n  systemctl --user start worldlined.service\nRetained data below (if any) is not live and cannot authorize anything."
                    color: Color.muted
                    font.family: Style.font.family; font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }

                WlCard {
                  visible: root.signalState !== "offline" && !root.initialized
                  anchors.centerIn: parent
                  width: Math.min(parent.width - Style.space(40), Style.space(560))
                  title: "FIRST RUN"
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: "The daemon is running and owns nothing. Register the directory you want agents to work on; it is moved behind a symlink into the managed store at the exact same path, and that capture becomes PRIME."
                    color: Color.foreground
                    font.family: Style.font.family; font.pixelSize: Style.font.body
                    wrapMode: Text.WordWrap
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: "worldline init /path/to/project"
                    color: Color.accent
                    font.family: Style.font.family; font.pixelSize: Style.font.body
                    font.bold: true
                  }
                  RowLayout {
                    Layout.fillWidth: true
                    Item { Layout.fillWidth: true }
                    Button { text: "Register a root (M)"; bordered: true; selected: true; onClicked: root.mode = "roots" }
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  visible: root.initialized && root.worlds.length === 0
                  anchors.centerIn: parent
                  text: "PRIME exists but no world has been published yet."
                  color: Color.muted
                  font.family: Style.font.family; font.pixelSize: Style.font.body
                }

                Canvas {
                  id: graphCanvas
                  anchors.fill: parent
                  visible: root.initialized && root.worlds.length > 0
                  property var layoutNodes: []

                  function computeLayout() {
                    var byDepth = ({})
                    var depths = ({})
                    function depth(world) {
                      if (!world || !world.parent) return 0
                      if (depths[world.instanceId] !== undefined) return depths[world.instanceId]
                      var parent = Model.worldByInstance(root.worlds, world.parent)
                      depths[world.instanceId] = parent ? depth(parent) + 1 : 0
                      return depths[world.instanceId]
                    }
                    for (var i = 0; i < root.worlds.length; i++) {
                      var d = depth(root.worlds[i])
                      if (!byDepth[d]) byDepth[d] = []
                      byDepth[d].push(root.worlds[i])
                    }
                    var out = []
                    var rowGap = Style.space(130)
                    // A generation with many siblings (a race plus a few forks is eight) used to
                    // squeeze them into the viewport until their label plates overprinted each
                    // other. Columns now keep a minimum pitch (the row grows past the viewport and
                    // pans), and in a dense row adjacent labels alternate between two bands.
                    var minPitch = Style.space(112)
                    var denseBelow = Style.space(150)
                    var widest = 0
                    for (var key in byDepth) {
                      var row = byDepth[key]
                      var count = row.length
                      var pitch = Math.max(graphViewport.width / (count + 1), minPitch)
                      var dense = pitch < denseBelow
                      var startX = graphViewport.width / 2 - (count - 1) * pitch / 2
                      widest = Math.max(widest, (count - 1) * pitch + Style.space(150))
                      for (var j = 0; j < count; j++) {
                        out.push({
                          world: row[j],
                          depth: Number(key),
                          x: startX + j * pitch,
                          y: Style.space(64) + Number(key) * rowGap,
                          band: dense ? (j % 2) : 0
                        })
                      }
                    }
                    layoutNodes = out
                    if (root.graphAutoFit && graphViewport.width > 0 && graphViewport.height > 0) {
                      // Fit both axes: a deep history (many generations) is as common as a wide one.
                      var maxDepthRow = 0
                      for (var q = 0; q < out.length; q++) maxDepthRow = Math.max(maxDepthRow, out[q].depth)
                      var tallest = Style.space(64) + maxDepthRow * rowGap + Style.space(120)
                      var fit = Math.max(0.35, Math.min(1, graphViewport.width / Math.max(widest, 1), graphViewport.height / Math.max(tallest, 1)))
                      root.graphZoom = fit
                      root.graphPanX = Math.max(0, graphViewport.width * (1 - fit) / 2)
                      root.graphPanY = 0
                    }
                  }

                  function node(instanceId) {
                    for (var i = 0; i < layoutNodes.length; i++) if (layoutNodes[i].world.instanceId === instanceId) return layoutNodes[i]
                    return null
                  }

                  function selectedPath() {
                    var path = ({})
                    var world = root.hasSelection ? root.selectedWorld : null
                    while (world) {
                      path[world.instanceId] = true
                      world = Model.worldByInstance(root.worlds, world.parent)
                    }
                    return path
                  }

                  function nodeRadius(world) {
                    var files = Model.deltaCount(world)
                    return Style.space(10) + Math.min(Style.space(8), Math.log2(1 + files) * Style.space(2))
                  }

                  onPaint: {
                    if (!root.opened || !visible) return
                    computeLayout()
                    var context = getContext("2d")
                    if (!context) return
                    context.reset()
                    context.clearRect(0, 0, width, height)
                    context.save()
                    context.translate(root.graphPanX, root.graphPanY)
                    context.scale(root.graphZoom, root.graphZoom)

                    var maxDepth = 0
                    for (var g = 0; g < layoutNodes.length; g++) maxDepth = Math.max(maxDepth, layoutNodes[g].depth)
                    context.lineWidth = 1
                    for (var gd = 0; gd <= maxDepth; gd++) {
                      var gy = Style.space(64) + gd * Style.space(130)
                      context.globalAlpha = 0.10
                      context.strokeStyle = Color.muted
                      context.beginPath()
                      context.moveTo(Style.space(8), gy)
                      context.lineTo(width / root.graphZoom - Style.space(8), gy)
                      context.stroke()
                      context.globalAlpha = 0.4
                      context.fillStyle = Color.muted
                      context.font = Style.font.caption + "px " + Style.font.family
                      context.textAlign = "left"
                      context.fillText("generation " + gd, Style.space(10), gy - Style.space(6))
                    }

                    var cone = selectedPath()
                    var selected = root.hasSelection ? root.selectedWorld : null
                    var selectedNode = selected ? node(selected.instanceId) : null
                    var stale = !root.live && !root.fixture

                    for (var i = 0; i < layoutNodes.length; i++) {
                      var child = layoutNodes[i]
                      var parent = node(child.world.parent)
                      if (!parent) continue
                      var onCone = cone[child.world.instanceId] && cone[parent.world.instanceId]
                      context.globalAlpha = onCone ? 0.95 : 0.22 * root.siblingOpacity
                      context.strokeStyle = onCone ? Color.accent : Color.muted
                      context.lineWidth = onCone ? 2.5 : 1.2
                      context.beginPath()
                      context.moveTo(parent.x, parent.y)
                      var targetX = child.x
                      var targetY = child.y
                      if (onCone && selectedNode && root.branchScale < 1) {
                        targetX = parent.x + (child.x - parent.x) * root.branchScale
                        targetY = parent.y + (child.y - parent.y) * root.branchScale
                      }
                      context.lineTo(targetX, targetY)
                      context.stroke()
                    }

                    for (var n = 0; n < layoutNodes.length; n++) {
                      var item = layoutNodes[n]
                      var world = item.world
                      var active = selected && world.instanceId === selected.instanceId
                      var pathActive = cone[world.instanceId]
                      var isPrime = root.status.prime && world.instanceId === root.status.prime.instanceId
                      var running = Model.isRunning(world)
                      var radius = nodeRadius(world)
                      context.globalAlpha = pathActive ? 1 : root.siblingOpacity * 0.48

                      if (running && root.motionEnabled) {
                        var pulse = radius + Style.space(4) + root.pulsePhase * Style.space(10)
                        context.globalAlpha = (1 - root.pulsePhase) * 0.6
                        context.strokeStyle = Color.accent
                        context.lineWidth = 1.5
                        context.beginPath()
                        context.arc(item.x, item.y, pulse, 0, Math.PI * 2)
                        context.stroke()
                        context.globalAlpha = pathActive ? 1 : root.siblingOpacity * 0.48
                      }

                      if (active) {
                        context.fillStyle = Util.alpha(Color.accent, 0.15)
                        context.beginPath()
                        context.arc(item.x, item.y, radius + Style.space(8), 0, Math.PI * 2)
                        context.fill()
                      }

                      var stateColor = root.toneColor(Model.stateTone(world.state))
                      context.fillStyle = active ? Color.accent : Color.background
                      context.strokeStyle = active ? Color.accent : stateColor
                      context.lineWidth = active ? 3 : 1.6
                      if (running) context.setLineDash([Style.space(3), Style.space(3)])
                      context.beginPath()
                      context.arc(item.x, item.y, radius, 0, Math.PI * 2)
                      context.fill()
                      context.stroke()
                      context.setLineDash([])

                      if (isPrime) {
                        context.lineWidth = 1.2
                        context.strokeStyle = Color.accent
                        context.beginPath()
                        context.arc(item.x, item.y, radius + Style.space(4), 0, Math.PI * 2)
                        context.stroke()
                      }

                      // evidence badge: filled accent PASS, filled urgent FAIL, hollow otherwise; glyph beside it
                      var evidenceResult = Model.evidence(world, stale)
                      var evidence = evidenceResult.state
                      var bx = item.x + radius * 0.85
                      var by = item.y - radius * 0.85
                      context.lineWidth = 1.4
                      context.beginPath()
                      context.arc(bx, by, Style.space(4.5), 0, Math.PI * 2)
                      if (evidence === "PASS") { context.fillStyle = Color.accent; context.fill() }
                      else if (evidence === "FAIL") { context.fillStyle = Color.urgent; context.fill() }
                      else { context.fillStyle = Color.background; context.fill(); context.strokeStyle = Color.muted; context.stroke() }

                      // Labels sit on a translucent plate so the edges passing beneath a
                      // generation row never make them illegible.
                      context.font = Style.font.caption + "px " + Style.font.family
                      context.textAlign = "center"
                      var files = Model.deltaCount(world)
                      var first = Model.shortAlias(world, root.status, root.primeLabel)
                      var second = String(world.agent || "—") + (files > 0 ? "  +" + files : "")
                      if (running) second = "▶ " + second
                      var third = String(world.state || "") + " · " + Model.evidenceLabel(evidenceResult)
                      var plateWidth = Math.max(context.measureText(first).width, context.measureText(second).width, context.measureText(third).width) + Style.space(10)
                      var bandOffset = (item.band || 0) * Style.space(46)
                      var plateTop = item.y + radius + Style.space(4) + bandOffset
                      var plateHeight = Style.space(42)
                      context.fillStyle = Util.alpha(Color.background, 0.82)
                      context.fillRect(item.x - plateWidth / 2, plateTop, plateWidth, plateHeight)
                      context.fillStyle = pathActive ? Color.foreground : Color.muted
                      context.fillText(first, item.x, item.y + radius + Style.space(15) + bandOffset)
                      context.fillStyle = Color.muted
                      context.fillText(second, item.x, item.y + radius + Style.space(28) + bandOffset)
                      context.fillStyle = evidence === "PASS" ? Color.accent : evidence === "FAIL" ? Color.urgent : Color.muted
                      context.fillText(third, item.x, item.y + radius + Style.space(41) + bandOffset)
                    }
                    context.restore()
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  enabled: graphCanvas.visible
                  property real lastX: 0
                  property real lastY: 0
                  property bool moved: false
                  onPressed: function(mouse) { lastX = mouse.x; lastY = mouse.y; moved = false; keyCatcher.forceActiveFocus() }
                  onPositionChanged: function(mouse) {
                    if (!(mouse.buttons & Qt.LeftButton)) return
                    var dx = mouse.x - lastX
                    var dy = mouse.y - lastY
                    if (Math.abs(dx) + Math.abs(dy) > 2) { moved = true; root.graphAutoFit = false }
                    root.graphPanX += dx
                    root.graphPanY += dy
                    lastX = mouse.x
                    lastY = mouse.y
                    graphCanvas.requestPaint()
                  }
                  onClicked: function(mouse) {
                    if (moved) return
                    var x = (mouse.x - root.graphPanX) / root.graphZoom
                    var y = (mouse.y - root.graphPanY) / root.graphZoom
                    for (var i = 0; i < graphCanvas.layoutNodes.length; i++) {
                      var node = graphCanvas.layoutNodes[i]
                      var dx = x - node.x
                      var dy = y - node.y
                      if (dx * dx + dy * dy <= Style.space(26) * Style.space(26)) {
                        root.selectAlias(node.world.instanceId)
                        break
                      }
                    }
                  }
                  onDoubleClicked: function(mouse) { if (root.hasSelection) root.inspectSelected() }
                  onWheel: function(wheel) {
                    var next = Math.max(0.5, Math.min(2.2, root.graphZoom + (wheel.angleDelta.y > 0 ? 0.1 : -0.1)))
                    root.graphAutoFit = false
                    root.graphZoom = next
                    graphCanvas.requestPaint()
                    wheel.accepted = true
                  }
                }
              }

              Flow {
                Layout.fillWidth: true
                spacing: Style.spacing.md
                Repeater {
                  model: Model.STATE_ORDER
                  delegate: Row {
                    required property var modelData
                    spacing: Style.spacing.xs
                    Rectangle { width: Style.space(7); height: width; radius: width / 2; color: root.toneColor(Model.stateTone(modelData)); anchors.verticalCenter: parent.verticalCenter }
                    Text { textFormat: Text.PlainText; text: modelData; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                  }
                }
                Text { textFormat: Text.PlainText; text: "badge: ● PASS · ● FAIL (red) · ○ UNASSESSED/UNAVAILABLE/STALE · dashed ring = running · double ring = PRIME"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                Text { textFormat: Text.PlainText; text: "zoom " + Math.round(root.graphZoom * 100) + "% (0 resets)"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
              }
            }

            // -------- right rail: inspector
            Flickable {
              Layout.preferredWidth: panel.inspectorWidth
              Layout.minimumWidth: Style.space(220)
              Layout.fillHeight: true
              contentHeight: inspector.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              ColumnLayout {
                id: inspector
                width: parent.width
                spacing: Style.spacing.md

                WlCard {
                  title: root.hasSelection ? "WORLD" : "INSPECTOR"
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.hasSelection ? Model.displayAlias(root.selectedWorld, root.status, root.primeLabel) : "Select a world (click a node, or ← → ↑ ↓)"
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.title
                    font.bold: true
                    elide: Text.ElideMiddle
                  }
                  Flow {
                    visible: root.hasSelection
                    Layout.fillWidth: true
                    spacing: Style.spacing.xs
                    WlChip { label: root.hasSelection ? String(root.selectedWorld.state || "?") : ""; tone: Model.stateTone(root.hasSelection ? root.selectedWorld.state : ""); filled: true }
                    WlChip {
                      label: "EVIDENCE " + Model.evidenceLabel(root.selectedEvidence)
                      glyph: Model.evidenceGlyph(root.selectedEvidence.state)
                      tone: Model.evidenceTone(root.selectedEvidence.state)
                      tooltipText: root.selectedEvidence.detail
                    }
                    WlChip { visible: root.hasSelection && root.selectedWorld.risk !== undefined; label: "RISK " + (root.hasSelection ? String(root.selectedWorld.risk || "") : ""); tone: Model.riskTone(root.hasSelection ? root.selectedWorld.risk : "") }
                    WlChip { visible: root.hasSelection && root.selectedWorld.complexity !== undefined; label: "CPLX " + (root.hasSelection ? String(root.selectedWorld.complexity || "") : ""); tone: "muted" }
                    WlChip { visible: root.selectedJob !== null; label: "JOB " + (root.selectedJob ? String(root.selectedJob.state) : ""); glyph: "▶"; tone: "accent"; filled: true }
                  }
                  Text {
                    textFormat: Text.PlainText
                    visible: root.hasSelection
                    Layout.fillWidth: true
                    text: root.selectedEvidence.detail + " · risk and complexity are derived labels; the inputs are below"
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                  WlKV { visible: root.hasSelection; k: "AGENT"; v: root.hasSelection ? String(root.selectedWorld.agent || "—") : "" }
                  WlKV { visible: root.hasSelection; k: "BORN"; v: root.hasSelection ? Model.fmtStamp(root.selectedWorld.born) : "" }
                  WlKV {
                    visible: root.hasSelection
                    k: root.hasSelection && root.selectedWorld.ended ? "LIFETIME" : "RUNNING FOR"
                    v: root.hasSelection ? Model.fmtDuration(root.selectedWorld.born, root.selectedWorld.ended, root.nowMs) : ""
                    vColor: root.hasSelection && !root.selectedWorld.ended ? Color.accent : Color.foreground
                  }
                  WlKV {
                    visible: root.hasSelection
                    k: "PARENT"
                    v: {
                      if (!root.hasSelection) return ""
                      var p = Model.worldByInstance(root.worlds, root.selectedWorld.parent)
                      return p ? Model.shortAlias(p, root.status, root.primeLabel) : (root.selectedWorld.parent ? "(not in status)" : "—")
                    }
                  }
                  WlKV { visible: root.hasSelection; k: "DESCENDANTS"; v: root.hasSelection ? String(root.selectedWorld.descendants || 0) : "" }
                  ColumnLayout {
                    visible: root.hasSelection
                    Layout.fillWidth: true
                    spacing: 0
                    RowLayout {
                      Layout.fillWidth: true
                      Text { textFormat: Text.PlainText; text: "MISSION"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                      Item { Layout.fillWidth: true }
                      Button { text: root.showMission ? "less" : "more"; fontSize: Style.font.caption; onClicked: root.showMission = !root.showMission }
                    }
                    Text {
                      textFormat: Text.PlainText
                      Layout.fillWidth: true
                      text: root.hasSelection ? String(root.selectedWorld.cause || "—") : ""
                      color: Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WordWrap
                      maximumLineCount: root.showMission ? 60 : 3
                      elide: Text.ElideRight
                    }
                  }
                  RowLayout {
                    visible: root.hasSelection
                    Layout.fillWidth: true
                    Item { Layout.fillWidth: true }
                    Button { text: root.showWorldDetails ? "hide identities" : "identities & hashes"; fontSize: Style.font.caption; onClicked: root.showWorldDetails = !root.showWorldDetails }
                  }
                  ColumnLayout {
                    visible: root.hasSelection && root.showWorldDetails
                    Layout.fillWidth: true
                    spacing: Style.spacing.xxs
                    WlKV { full: true; k: "content"; v: root.hasSelection ? String(root.selectedWorld.id || root.selectedWorld.hash || "—") : "" }
                    WlKV { full: true; k: "instance"; v: root.hasSelection ? String(root.selectedWorld.instanceId || "") : "" }
                    WlKV { full: true; k: "parent id"; v: root.hasSelection ? String(root.selectedWorld.parentId || "") : "" }
                    WlKV { full: true; k: "base root"; v: root.hasSelection ? String(root.selectedWorld.baseRoot || "") : "" }
                    WlKV { full: true; k: "root set"; v: root.hasSelection ? String(root.selectedWorld.rootSetHash || "") : "" }
                    WlKV { k: "kind"; v: root.hasSelection ? String(root.selectedWorld.kind || "") : "" }
                  }
                }

                WlCard {
                  visible: root.hasSelection
                  title: "DELTA"
                  hint: root.hasSelection ? Model.deltaCount(root.selectedWorld) + " files" : ""
                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.spacing.md
                    Text { textFormat: Text.PlainText; text: "+" + (root.hasSelection ? Model.deltaSummary(root.selectedWorld).added : 0); color: Color.accent; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
                    Text { textFormat: Text.PlainText; text: "~" + (root.hasSelection ? Model.deltaSummary(root.selectedWorld).modified : 0); color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
                    Text { textFormat: Text.PlainText; text: "−" + (root.hasSelection ? Model.deltaSummary(root.selectedWorld).deleted : 0); color: Color.urgent; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true }
                    Item { Layout.fillWidth: true }
                    Text { textFormat: Text.PlainText; text: root.hasSelection && Model.isRunning(root.selectedWorld) ? "measured at finalize" : ""; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                  }
                  Flickable {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(deltaList.implicitHeight, Style.space(180))
                    contentHeight: deltaList.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    ColumnLayout {
                      id: deltaList
                      width: parent.width
                      spacing: 0
                      Repeater {
                        model: root.hasSelection && root.selectedWorld.delta && Array.isArray(root.selectedWorld.delta.files) ? root.selectedWorld.delta.files : []
                        delegate: RowLayout {
                          required property var modelData
                          Layout.fillWidth: true
                          spacing: Style.spacing.xs
                          Text { textFormat: Text.PlainText; Layout.preferredWidth: Style.space(10); text: Model.operationKind(modelData); color: modelData.op === "ADD" ? Color.accent : modelData.op === "DELETE" ? Color.urgent : Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
                          Text { textFormat: Text.PlainText; Layout.fillWidth: true; text: Model.operationLabel(modelData); color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideLeft }
                        }
                      }
                    }
                  }
                }

                WlCard {
                  visible: root.hasSelection
                  title: "EVIDENCE"
                  Text {
                    textFormat: Text.PlainText
                    visible: root.hasSelection && (!Array.isArray(root.selectedWorld.checks) || root.selectedWorld.checks.length === 0)
                    Layout.fillWidth: true
                    text: root.hasSelection && Model.isRunning(root.selectedWorld)
                      ? "UNASSESSED — checks run after the agent finishes"
                      : "UNASSESSED — no checks were recorded for this world. Declare checks in .worldline.json; without them risk cannot drop below MEDIUM."
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                  Repeater {
                    model: root.hasSelection && Array.isArray(root.selectedWorld.checks) ? root.selectedWorld.checks : []
                    delegate: ColumnLayout {
                      required property var modelData
                      Layout.fillWidth: true
                      spacing: 0
                      RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.spacing.sm
                        Text { textFormat: Text.PlainText; text: Model.evidenceGlyph(Model.checkStatusLabel(modelData)); color: root.toneColor(Model.evidenceTone(Model.checkStatusLabel(modelData))); font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
                        Text { textFormat: Text.PlainText; Layout.fillWidth: true; text: String(modelData.id || modelData.name || modelData.kind || "check") + (modelData.required ? "  [required]" : "  [optional]"); color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
                        Text { textFormat: Text.PlainText; text: Model.checkStatusLabel(modelData); color: root.toneColor(Model.evidenceTone(Model.checkStatusLabel(modelData))); font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
                      }
                      Text {
                        textFormat: Text.PlainText
                        visible: modelData.reason !== undefined && modelData.reason !== null && String(modelData.reason) !== ""
                        Layout.fillWidth: true
                        text: String(modelData.reason || "")
                        color: Color.muted
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WordWrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                      }
                      Text {
                        textFormat: Text.PlainText
                        visible: modelData.kind === "proofs" && modelData.total !== undefined
                        text: "formal · " + Number(modelData.total || 0) + " obligations · " + Number(modelData.unproved || 0) + " unproved"
                        color: Color.muted
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }

                WlCard {
                  visible: root.hasSelection
                  title: "COLLAPSE GATES"
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.hasSelection && Model.isTerminal(root.selectedWorld)
                      ? "Conflicts and foreign contamination are computed against the CURRENT PRIME when a transaction is prepared (C). The world record itself carries " + (Array.isArray(root.selectedWorld.conflicts) ? root.selectedWorld.conflicts.length : 0) + " conflict(s) and " + (Array.isArray(root.selectedWorld.contamination) ? root.selectedWorld.contamination.length : 0) + " contamination entr" + ((Array.isArray(root.selectedWorld.contamination) ? root.selectedWorld.contamination.length : 0) === 1 ? "y" : "ies") + " from its own finalization."
                      : "UNEVALUATED — the world is still running."
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }

                WlCard {
                  visible: root.hasSelection && root.comparison.rows.length > 1
                  title: "COMPARE — " + root.comparison.rows.length + " SIBLINGS"
                  Repeater {
                    model: root.comparison.rows
                    delegate: RowLayout {
                      required property var modelData
                      Layout.fillWidth: true
                      spacing: Style.spacing.xs
                      Text { textFormat: Text.PlainText; text: modelData.alias === root.comparison.recommendation ? "★" : (modelData.isSelected ? "▸" : "·"); color: modelData.alias === root.comparison.recommendation ? Color.accent : Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                      Text { textFormat: Text.PlainText; Layout.fillWidth: true; text: modelData.alias; color: modelData.isSelected ? Color.accent : Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: modelData.isSelected; elide: Text.ElideRight
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.selectAlias(modelData.alias) } }
                      Text { textFormat: Text.PlainText; text: modelData.state; color: root.toneColor(Model.stateTone(modelData.state)); font.family: Style.font.family; font.pixelSize: Style.font.caption }
                      Text { textFormat: Text.PlainText; text: Model.evidenceGlyph(modelData.evidence) + " " + modelData.evidence; color: root.toneColor(Model.evidenceTone(modelData.evidence)); font.family: Style.font.family; font.pixelSize: Style.font.caption }
                      Text { textFormat: Text.PlainText; text: "+" + modelData.delta.added + " ~" + modelData.delta.modified + " −" + modelData.delta.deleted; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                      Text { textFormat: Text.PlainText; text: modelData.risk; color: root.toneColor(Model.riskTone(modelData.risk)); font.family: Style.font.family; font.pixelSize: Style.font.caption }
                    }
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: root.comparison.recommendation
                      ? "★ " + root.comparison.recommendation + " — " + root.comparison.reason + ". A ranking, not a verdict: read the checks."
                      : "no recommendation: " + root.comparison.reason
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }

                WlCard {
                  visible: root.hasSelection && !Model.isPrimeGeneration(root.selectedWorld)
                  title: "AGENT LOG"
                  hint: root.logLoading ? "loading…" : ""
                  Text {
                    textFormat: Text.PlainText
                    visible: root.logText === "" || root.logWorld !== String(root.selectedWorld ? root.selectedWorld.instanceId : "")
                    Layout.fillWidth: true
                    text: "stderr tail from ~/.local/state/worldline/logs (L to load)"
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                  Flickable {
                    visible: root.logText !== "" && root.logWorld === String(root.selectedWorld ? root.selectedWorld.instanceId : "")
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(logBody.implicitHeight, Style.space(200))
                    contentHeight: logBody.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds
                    Text {
                      id: logBody
                      textFormat: Text.PlainText
                      width: parent.width
                      text: root.logText
                      color: Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      wrapMode: Text.WrapAnywhere
                    }
                  }
                  RowLayout {
                    Layout.fillWidth: true
                    Item { Layout.fillWidth: true }
                    Button { text: "load tail (L)"; fontSize: Style.font.caption; enabled: !root.logLoading; onClicked: root.loadLog() }
                  }
                }

                // actions
                WlCard {
                  visible: root.hasSelection
                  title: "ACTIONS"
                  Flow {
                    Layout.fillWidth: true
                    spacing: Style.spacing.sm
                    Button {
                      visible: root.hasSelection && Model.isRunning(root.selectedWorld)
                      text: "Cancel (X)"
                      opacity: enabled ? 1 : 0.4
                      bordered: true
                      enabled: root.live && root.selectedJob !== null
                      tooltipText: root.selectedJob === null ? "no active job to cancel" : "stops the agent's transient unit; partial work stays inspectable, world finalizes DEGRADED"
                      onClicked: root.cancelSelected()
                    }
                    Button {
                      text: "Inspect (I)"
                      opacity: enabled ? 1 : 0.4
                      bordered: true
                      enabled: root.live
                      tooltipText: "marks this world active for the bar and the alternate-world tint"
                      onClicked: root.inspectSelected()
                    }
                    Button {
                      visible: root.hasSelection && !Model.isPrimeGeneration(root.selectedWorld)
                      text: "Switch (S)"
                      opacity: enabled ? 1 : 0.4
                      bordered: true
                      enabled: root.live
                      tooltipText: "focuses the world's Hyprland workspace and opens a shell inside it"
                      onClicked: root.switchSelected()
                    }
                    Button {
                      text: "Return (R)"
                      opacity: enabled ? 1 : 0.4
                      bordered: true
                      enabled: root.hasSelection && Model.canReturnTo(root.selectedWorld) && (root.live || root.fixture)
                      tooltipText: root.hasSelection && !Model.canReturnTo(root.selectedWorld) ? "needs an ARCHIVED, COLLAPSED, or VALID checkpoint" : "prepare a return to this checkpoint (review first)"
                      onClicked: root.startCollapse("return")
                    }
                    Button {
                      text: "Collapse (C)"
                      opacity: enabled ? 1 : 0.4
                      bordered: true
                      selected: root.hasSelection && Model.canCollapse(root.selectedWorld)
                      enabled: root.hasSelection && Model.canCollapse(root.selectedWorld) && (root.live || root.fixture)
                      tooltipText: root.hasSelection && !Model.canCollapse(root.selectedWorld) ? "only a VALID world can collapse — this one is " + String(root.selectedWorld.state) : "prepare a collapse into PRIME (review first)"
                      onClicked: root.startCollapse("collapse")
                    }
                  }
                  Text {
                    textFormat: Text.PlainText
                    Layout.fillWidth: true
                    text: !root.live && !root.fixture
                      ? "actions disabled: daemon signal is " + root.signalState
                      : root.hasSelection && !Model.canCollapse(root.selectedWorld)
                        ? "only VALID worlds can collapse — this one is " + String(root.selectedWorld.state) + (Model.isPrimeGeneration(root.selectedWorld) ? " (a PRIME generation; return to it instead)" : "")
                        : "collapse opens a fresh prepared review; nothing is committed until the second confirmation"
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }
              }
            }
          }

          // help overlay
          Rectangle {
            anchors.fill: parent
            visible: root.showHelp && root.mode === "multiverse"
            color: Util.alpha(Color.background, 0.85)
            MouseArea { anchors.fill: parent; onClicked: root.showHelp = false }
            WlCard {
              anchors.centerIn: parent
              width: Math.min(parent.width - Style.space(40), Style.space(560))
              title: "KEYS"
              Text {
                textFormat: Text.PlainText
                Layout.fillWidth: true
                text: "← → / h l   lineage (parent / child)\n↑ ↓ / k j   siblings\n⏎           collapse review (VALID) or inspect\nC / R       prepare collapse / return of the selection\nX           cancel the selected running world\nI / S       inspect (bar + tint) / switch workspace + shell\nL           load the agent's stderr tail\nF           fork or race     M   managed roots\nD           re-probe diagnostics     0   reset zoom\n?           this help          Esc  close\n\nIn the fork editor: M focuses the mission, T toggles single/race, Ctrl+Enter launches.\nOn the review screen: Enter opens the final confirmation, D toggles full hashes, Esc aborts."
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }
        }

        // ---------------------------------------------------- footer
        Rectangle { Layout.fillWidth: true; height: 1; color: Util.alpha(Color.muted, 0.5) }
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.md
          Text {
            textFormat: Text.PlainText
            text: root.worlds.length + " worlds · " + root.runningJobs + " running · signal " + root.signalState + " " + Model.fmtAge(Model.daemonAgeMs(root.status, root.nowMs))
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Text {
            textFormat: Text.PlainText
            visible: root.actionError !== ""
            Layout.fillWidth: true
            text: root.actionError
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          Text {
            textFormat: Text.PlainText
            visible: root.actionError === "" && root.actionNotice !== ""
            Layout.fillWidth: true
            text: root.actionNotice
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          Item { Layout.fillWidth: true; visible: root.actionError === "" && root.actionNotice === "" }
          Text {
            textFormat: Text.PlainText
            text: root.mode === "multiverse" ? "← → ↑ ↓ navigate · ⏎ review · F fork · M roots · C/R collapse/return · X cancel · L log · ? keys · esc close"
              : root.mode === "fork" ? "M mission · T single/race · Ctrl+⏎ launch · esc back"
              : root.mode === "collapse" ? "⏎ final confirmation · D hashes · esc abort"
              : "⏎ dry run · esc back"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }

    ConfirmDialog {
      id: rootsConfirm
      anchors.fill: parent
      opened: root.rootsConfirmOpen
      message: root.rootsConfirmKind === "remove"
        ? "Remove " + (root.rootsPendingRemove ? String(root.rootsPendingRemove.roots[0].path) : "") + " from WORLDLINE? The current bytes are materialized back at that exact path and the live mapping is dropped."
        : "Register " + root.rootsPath.trim() + "? The directory is moved into the managed store and replaced by a symlink at the same path."
      cancelText: "Cancel"
      confirmText: root.rootsConfirmKind === "remove" ? "Remove" : "Register"
      onCanceled: { root.rootsConfirmOpen = false; keyCatcher.forceActiveFocus() }
      onConfirmed: { if (root.rootsConfirmKind === "remove") root.rootsApplyRemove(); else root.rootsApply() }
    }
    }
  }
}
