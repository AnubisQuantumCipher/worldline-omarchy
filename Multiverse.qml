import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// WORLDLINE mission control — full-screen cockpit over the live status.json.
// Everything painted here is read straight from daemon state; derived labels
// (risk, complexity) are shown next to the inputs that produced them, and
// UNASSESSED/UNAVAILABLE are rendered as answers, never hidden.
Item {
  id: root

  property var shell: ({})
  property var manifest: ({})
  property var status: ({})
  property var lastGoodStatus: ({})
  property bool opened: false
  property string mode: "multiverse"
  property string missionText: ""
  property int selectedIndex: 0
  property int confirmationStep: 0
  property string actionKind: "collapse"
  property string actionError: ""
  property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR")
  property real graphZoom: 1.0
  property real graphPanX: 0
  property real graphPanY: 0
  property real branchScale: 1.0
  property real siblingOpacity: 1.0
  property string lastCommittedReceipt: ""
  property bool statusLoadedOnce: false
  property string primeLabel: "PRIME"
  property double nowMs: Date.now()
  property var adapters: []
  readonly property var serviceObject: shell && typeof shell.serviceFor === "function"
    ? shell.serviceFor("khephri.worldline") : undefined
  readonly property bool motionEnabled: serviceObject && serviceObject.motionEnabled !== undefined ? serviceObject.motionEnabled : true
  readonly property int motionDuration: motionEnabled ? 520 : 0
  readonly property bool initialized: lastGoodStatus.prime !== undefined && lastGoodStatus.prime !== null
  readonly property var worlds: Array.isArray(lastGoodStatus.worlds) ? lastGoodStatus.worlds : []
  readonly property var selectedWorld: worlds.length > 0 ? worlds[Math.max(0, Math.min(selectedIndex, worlds.length - 1))] : ({})
  readonly property bool hasSelection: selectedWorld && selectedWorld.instanceId !== undefined
  readonly property var daemonInfo: lastGoodStatus.daemon || ({})
  readonly property bool stale: {
    if (!daemonInfo.publishedAt) return true
    var stamp = Date.parse(daemonInfo.publishedAt)
    return !isFinite(stamp) || nowMs - stamp > 10000
  }
  readonly property var capabilities: lastGoodStatus.capabilities || ({})
  readonly property var jobs: Array.isArray(lastGoodStatus.jobs) ? lastGoodStatus.jobs : []
  readonly property var receipt: lastGoodStatus.lastReceipt || null

  // ------------------------------------------------------------ lifecycle

  function open(payloadJson) {
    var payload = {}
    try { payload = typeof payloadJson === "string" ? JSON.parse(payloadJson || "{}") : (payloadJson || {}) }
    catch (error) { payload = {} }
    var requested = String(payload.mode || "multiverse")
    mode = ["fork", "multiverse", "collapse"].indexOf(requested) >= 0 ? requested : "multiverse"
    opened = true
    confirmationStep = 0
    actionError = ""
    if (payload.select) selectAlias(String(payload.select))
    if (!adaptersProcess.running) adaptersProcess.running = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus(); graphCanvas.requestPaint() })
  }

  function dismiss() {
    opened = false
    confirmationStep = 0
    if (shell && typeof shell.hide === "function") shell.hide("khephri.worldline")
  }

  function selectAlias(alias) {
    for (var i = 0; i < worlds.length; i++) {
      if (worlds[i].alias === alias || worlds[i].instanceId === alias) {
        selectedIndex = i
        return
      }
    }
  }

  function applyStatus(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (parsed.schemaVersion !== 1 || !Array.isArray(parsed.worlds) || parsed.activeWorld === undefined) return
      status = parsed
      lastGoodStatus = parsed
      if (selectedIndex >= worlds.length) selectedIndex = Math.max(0, worlds.length - 1)
      var rec = parsed.lastReceipt
      if (rec && rec.receiptId && rec.atomicCollapse
          && rec.atomicCollapse.state === "COMMITTED") {
        if (!statusLoadedOnce) {
          lastCommittedReceipt = rec.receiptId
          primeLabel = "PRIME′"
        } else if (rec.receiptId !== lastCommittedReceipt) {
          lastCommittedReceipt = rec.receiptId
          primeLabel = "PRIME′"
          collapseAnimation.restart()
        }
      }
      statusLoadedOnce = true
      if (root.opened) graphCanvas.requestPaint()
    } catch (error) {
      // Keep the prior complete state while the atomic writer is replaced.
    }
  }

  // ------------------------------------------------------------ lookups

  function worldByInstance(instanceId) {
    for (var i = 0; i < worlds.length; i++) if (worlds[i].instanceId === instanceId) return worlds[i]
    return null
  }

  function worldById(id) {
    for (var i = 0; i < worlds.length; i++) if (worlds[i].id === id) return worlds[i]
    return null
  }

  function selectedReceipt() {
    if (!receipt || !hasSelection) return ({})
    return receipt.candidateWorld === selectedWorld.id ? receipt : ({})
  }

  function displayAlias(world) {
    if (lastGoodStatus && lastGoodStatus.prime
        && world.instanceId === lastGoodStatus.prime.instanceId)
      return primeLabel
    return String(world.alias)
  }

  function shortAlias(world) {
    var a = displayAlias(world)
    if (a.indexOf("prime-") === 0 && a.length > 16) return "prime-" + a.substring(6, 14)
    return a
  }

  function shortHash(h) {
    if (!h || h === "—") return "—"
    var s = String(h).replace("sha256:", "")
    return s.length > 16 ? s.substring(0, 12) + "…" : s
  }

  function stateColor(state) {
    if (state === "VALID") return Color.accent
    if (state === "DEGRADED" || state === "DEAD") return Color.urgent
    if (state === "MUTABLE" || state === "FINALIZING") return Color.foreground
    return Color.muted   // ARCHIVED / COLLAPSED / unknown
  }

  function checkColor(s) {
    if (s === "PASS") return Color.accent
    if (s === "FAIL") return Color.urgent
    return Color.muted
  }

  function riskColor(label) {
    if (label === "LOW") return Color.accent
    if (label === "HIGH" || label === "CRITICAL") return Color.urgent
    return Color.foreground
  }

  function proofState(world) {
    if (!world) return "UNASSESSED"
    var checks = Array.isArray(world.checks) ? world.checks : []
    var proofs = Array.isArray(world.proofs) ? world.proofs : []
    if (checks.length === 0 && proofs.length === 0) return "UNASSESSED"
    for (var i = 0; i < checks.length; i++) if (checks[i].status === "FAIL") return "FAIL"
    for (var p = 0; p < proofs.length; p++) if (proofs[p].status !== "PASS") return "FAIL"
    return "PASS"
  }

  function fmtStamp(iso) {
    if (!iso) return "—"
    var t = Date.parse(iso)
    if (!isFinite(t)) return String(iso)
    var d = new Date(t)
    function two(n) { return (n < 10 ? "0" : "") + n }
    return two(d.getHours()) + ":" + two(d.getMinutes()) + ":" + two(d.getSeconds())
  }

  function fmtDur(bornIso, endedIso) {
    var b = Date.parse(bornIso)
    if (!isFinite(b)) return "—"
    var e = endedIso ? Date.parse(endedIso) : nowMs
    if (!isFinite(e)) e = nowMs
    var s = Math.max(0, Math.round((e - b) / 1000))
    if (s < 60) return s + "s"
    if (s < 3600) return Math.floor(s / 60) + "m " + (s % 60) + "s"
    return Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m"
  }

  function daemonAge() {
    if (!daemonInfo.publishedAt) return "no signal"
    var t = Date.parse(daemonInfo.publishedAt)
    if (!isFinite(t)) return "no signal"
    var s = Math.max(0, Math.round((nowMs - t) / 1000))
    return s + "s ago"
  }

  readonly property var stateOrder: ["VALID", "MUTABLE", "FINALIZING", "DEGRADED", "DEAD", "ARCHIVED", "COLLAPSED"]

  function stateCounts() {
    var counts = ({})
    for (var i = 0; i < worlds.length; i++) {
      var s = String(worlds[i].state || "?")
      counts[s] = (counts[s] || 0) + 1
    }
    var out = []
    for (var j = 0; j < stateOrder.length; j++)
      if (counts[stateOrder[j]]) out.push({ state: stateOrder[j], count: counts[stateOrder[j]] })
    return out
  }

  function recentJobs() {
    var sorted = jobs.slice()
    sorted.sort(function(a, b) { return String(b.started || "").localeCompare(String(a.started || "")) })
    var out = []
    for (var i = 0; i < Math.min(5, sorted.length); i++) {
      var j = sorted[i]
      var w = worldByInstance(j.world)
      out.push({
        state: String(j.state || "?"),
        alias: w ? shortAlias(w) : String(j.world || "").substring(0, 8),
        dur: fmtDur(j.started, j.ended),
        error: j.error ? String(j.error) : ""
      })
    }
    return out
  }

  function runningJobs() {
    var n = 0
    for (var i = 0; i < jobs.length; i++)
      if (jobs[i].state === "RUNNING" || jobs[i].state === "PENDING") n++
    return n
  }

  readonly property var capOrder: ["atomicExchange", "overlay", "namespaces", "cgroups",
                                   "systemd", "git", "docker", "inotify", "hyprland",
                                   "btrfs", "criu", "systemRootCollapse"]

  function capRows() {
    var out = []
    for (var i = 0; i < capOrder.length; i++) {
      var k = capOrder[i]
      var c = capabilities[k]
      if (!c || typeof c !== "object") continue
      out.push({
        name: k,
        ok: c.state === "AVAILABLE",
        note: c.state === "AVAILABLE"
          ? String(c.version || c.backend || c.mechanism || c.serverVersion || "")
          : String(c.reason || "unavailable")
      })
    }
    return out
  }

  function availableAgents() {
    var preferred = ["codex", "claude", "omp"]
    if (adapters.length === 0) return preferred   // probe not back yet
    var avail = []
    for (var i = 0; i < adapters.length; i++)
      if (adapters[i].state === "AVAILABLE") avail.push(String(adapters[i].name))
    var pick = []
    for (var p = 0; p < preferred.length; p++)
      if (avail.indexOf(preferred[p]) >= 0) pick.push(preferred[p])
    for (var a = 0; a < avail.length && pick.length < 3; a++)
      if (pick.indexOf(avail[a]) < 0) pick.push(avail[a])
    return pick
  }

  function deltaFiles(world) {
    var d = world && world.delta ? world.delta : ({})
    return Array.isArray(d.files) ? d.files.length : Number(d.files || 0)
  }

  function fileLabel(f) {
    if (typeof f === "string") return f
    if (f && typeof f === "object") return String(f.path || f.file || JSON.stringify(f))
    return String(f)
  }

  // ------------------------------------------------------------ tree nav

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

  // ------------------------------------------------------------ actions

  function runRace() {
    if (!initialized || missionText.trim() === "" || actionProcess.running) return
    var agents = availableAgents()
    if (agents.length < 3) { actionError = "race needs three AVAILABLE adapters — found " + agents.length; return }
    actionError = ""
    actionProcess.command = [
      "worldline", "race", "--detach", "--mission-text", missionText,
      "--agent", agents[0], "--agent", agents[1], "--agent", agents[2]
    ]
    actionProcess.running = true
  }

  function executeSelection() {
    if (!hasSelection || actionProcess.running) return
    actionError = ""
    if (actionKind === "return")
      actionProcess.command = ["worldline", "return", selectedWorld.alias, "--yes"]
    else
      actionProcess.command = ["worldline", "collapse", selectedWorld.alias, "--yes"]
    actionProcess.running = true
  }

  // ------------------------------------------------------------ plumbing

  FileView {
    id: statusFile
    path: root.runtimeDir + "/worldline/status.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyStatus(text())
    onFileChanged: statusApplyTimer.restart()
  }

  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    onTriggered: {
      root.nowMs = Date.now()
      statusFile.reload()
      statusApplyTimer.restart()
    }
  }

  Timer {
    id: statusApplyTimer
    interval: 100
    repeat: false
    onTriggered: root.applyStatus(statusFile.text())
  }

  Process {
    id: adaptersProcess
    running: false
    command: ["worldline", "adapters", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(String(text || "[]"))
          if (Array.isArray(parsed)) root.adapters = parsed
        } catch (error) { /* keep prior list */ }
      }
    }
  }

  Process {
    id: actionProcess
    running: false
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector { id: actionStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.actionError = String(actionStderr.text || "WORLDLINE action failed").trim()
      else if (root.mode === "fork") root.mode = "multiverse"
    }
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
  onSelectedIndexChanged: if (root.opened) graphCanvas.requestPaint()

  // ------------------------------------------------------------ reusable bits

  component SectionTitle: Text {
    color: Color.muted
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
    font.letterSpacing: Style.space(0.8)
  }

  component Card: Rectangle {
    default property alias content: inner.data
    Layout.fillWidth: true
    implicitHeight: inner.implicitHeight + Style.spacing.md * 2
    color: Util.alpha(Color.foreground, 0.03)
    border.color: Util.alpha(Color.muted, 0.45)
    border.width: 1
    radius: Style.cornerRadius
    ColumnLayout {
      id: inner
      anchors.fill: parent
      anchors.margins: Style.spacing.md
      spacing: Style.spacing.xs
    }
  }

  component KV: RowLayout {
    property string k: ""
    property string v: ""
    property color vColor: Color.foreground
    Layout.fillWidth: true
    spacing: Style.spacing.sm
    Text { text: parent.k; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
    Item { Layout.fillWidth: true }
    Text {
      Layout.maximumWidth: Style.space(200)
      text: parent.v; color: parent.vColor
      font.family: Style.font.family; font.pixelSize: Style.font.caption
      elide: Text.ElideMiddle
      horizontalAlignment: Text.AlignRight
    }
  }

  component StateChip: Rectangle {
    property string label: ""
    property color tone: Color.muted
    implicitWidth: chipText.implicitWidth + Style.spacing.md * 2
    implicitHeight: chipText.implicitHeight + Style.spacing.xs * 2
    radius: height / 2
    color: Util.alpha(tone, 0.14)
    border.color: Util.alpha(tone, 0.6)
    border.width: 1
    Text {
      id: chipText
      anchors.centerIn: parent
      text: parent.label
      color: parent.tone
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

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

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.dismiss(); event.accepted = true
        } else if (event.key === Qt.Key_F && root.mode === "multiverse") {
          root.mode = "fork"; event.accepted = true
        } else if (event.key === Qt.Key_G && root.mode !== "collapse") {
          root.mode = "multiverse"; event.accepted = true
        } else if (root.mode === "multiverse" && event.key === Qt.Key_Left) {
          root.selectedIndex = root.parentIndex(root.selectedIndex); event.accepted = true
        } else if (root.mode === "multiverse" && event.key === Qt.Key_Right) {
          root.selectedIndex = root.childIndex(root.selectedIndex); event.accepted = true
        } else if (root.mode === "multiverse" && event.key === Qt.Key_Up) {
          root.selectedIndex = root.siblingIndex(root.selectedIndex, -1); event.accepted = true
        } else if (root.mode === "multiverse" && event.key === Qt.Key_Down) {
          root.selectedIndex = root.siblingIndex(root.selectedIndex, 1); event.accepted = true
        } else if (root.mode === "multiverse" && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
          root.mode = "collapse"; root.actionKind = "collapse"; root.confirmationStep = 0; event.accepted = true
        }
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
          Text {
            text: "W O R L D L I N E"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.display
            font.bold: true
            font.letterSpacing: Style.space(1)
          }
          Text {
            text: "MISSION CONTROL"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.letterSpacing: Style.space(1.2)
          }
          Item { Layout.fillWidth: true }
          StateChip {
            label: root.stale ? "DAEMON STALE · " + root.daemonAge()
                              : "DAEMON " + String(root.daemonInfo.state || "?") + " · v" + String(root.daemonInfo.version || "?")
            tone: root.stale ? Color.urgent : Color.accent
          }
          StateChip {
            label: root.initialized ? root.primeLabel + (root.lastGoodStatus.prime.dirty ? " · DIRTY" : "")
                                    : "NO PRIME"
            tone: root.initialized ? (root.lastGoodStatus.prime.dirty ? Color.urgent : Color.accent) : Color.urgent
          }
          StateChip {
            label: "ACTIVE " + String(root.lastGoodStatus.activeWorld || "PRIME")
            tone: String(root.lastGoodStatus.activeWorld || "PRIME") === "PRIME" ? Color.foreground : Color.accent
          }
          StateChip {
            label: "BACKEND " + String(root.capabilities.selectedBackend || "?")
            tone: Color.muted
          }
          Button { text: "×"; onClicked: root.dismiss() }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Util.alpha(Color.muted, 0.5) }

        // ---------------------------------------------------- body
        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          // ============ FORK MODE ============
          ColumnLayout {
            anchors.fill: parent
            visible: root.mode === "fork"
            spacing: Style.spacing.lg

            Text {
              Layout.alignment: Qt.AlignHCenter
              text: root.initialized ? "●  FORK FROM " + root.primeLabel : "No PRIME — run worldline init /path/to/work"
              color: root.initialized ? Color.accent : Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.display
              font.bold: true
            }

            RowLayout {
              Layout.alignment: Qt.AlignHCenter
              spacing: Style.spacing.xl
              Repeater {
                model: root.availableAgents()
                delegate: ColumnLayout {
                  required property var modelData
                  required property int index
                  spacing: Style.spacing.sm
                  Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "WORLD " + ["α", "β", "γ"][index]
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }
                  Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: String(modelData).toUpperCase()
                    color: Color.accent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: Style.space(0.5)
                  }
                }
              }
            }

            TextArea {
              id: missionEditor
              Layout.fillWidth: true
              Layout.fillHeight: true
              enabled: root.initialized
              placeholderText: "Describe one mission. Each agent receives the same frozen reality."
              text: root.missionText
              onTextChanged: root.missionText = text
              color: Color.foreground
              placeholderTextColor: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              wrapMode: TextEdit.Wrap
              background: Rectangle {
                color: Util.alpha(Color.foreground, 0.035)
                border.color: missionEditor.activeFocus ? Color.accent : Util.alpha(Color.muted, 0.5)
                border.width: 1
                radius: Style.cornerRadius
              }
            }
            RowLayout {
              Layout.fillWidth: true
              Text {
                Layout.fillWidth: true
                text: "A race runs three agents concurrently — roughly triple the model spend of a single fork."
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              Button { text: "BACK"; onClicked: root.mode = "multiverse" }
              Button {
                text: "FORK REALITY"
                enabled: root.initialized && root.missionText.trim() !== "" && !actionProcess.running
                onClicked: root.runRace()
              }
            }
          }

          // ============ MULTIVERSE MODE ============
          RowLayout {
            anchors.fill: parent
            visible: root.mode === "multiverse"
            spacing: Style.spacing.md

            // -------- left rail
            Flickable {
              Layout.preferredWidth: Style.space(300)
              Layout.fillHeight: true
              contentHeight: leftRail.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              ColumnLayout {
                id: leftRail
                width: parent.width
                spacing: Style.spacing.md

                Card {
                  SectionTitle { text: "REALITY" }
                  KV { k: "PRIME"; v: root.initialized ? root.shortHash(root.lastGoodStatus.prime.id) : "—" }
                  KV { k: "GENERATION"; v: root.initialized ? String(root.lastGoodStatus.prime.generation || "").substring(0, 8) : "—" }
                  KV {
                    k: "DIRTY"
                    v: root.initialized ? (root.lastGoodStatus.prime.dirty ? "YES" : "no") : "—"
                    vColor: root.initialized && root.lastGoodStatus.prime.dirty ? Color.urgent : Color.foreground
                  }
                  Repeater {
                    model: root.initialized && Array.isArray(root.lastGoodStatus.prime.roots)
                           ? root.lastGoodStatus.prime.roots : []
                    delegate: ColumnLayout {
                      required property var modelData
                      Layout.fillWidth: true
                      spacing: 0
                      Text {
                        Layout.fillWidth: true
                        text: (modelData.primary ? "★ " : "· ") + String(modelData.path || "")
                        color: Color.foreground
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideLeft
                      }
                      Text {
                        text: String(modelData.kind || "")
                        color: Color.muted
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }

                Card {
                  SectionTitle { text: "LAST COLLAPSE" }
                  visible: root.receipt !== null && root.receipt.receiptId !== undefined
                  KV { k: "RECEIPT"; v: root.receipt ? root.shortHash(root.receipt.receiptId) : "—" }
                  KV {
                    k: "STATE"
                    v: root.receipt && root.receipt.atomicCollapse ? String(root.receipt.atomicCollapse.state || "—") : "—"
                    vColor: root.receipt && root.receipt.atomicCollapse && root.receipt.atomicCollapse.state === "COMMITTED"
                            ? Color.accent : Color.foreground
                  }
                  KV {
                    k: "MECHANISM"
                    v: root.receipt && root.receipt.atomicCollapse ? String(root.receipt.atomicCollapse.mechanism || "—") : "—"
                  }
                  KV {
                    k: "INVARIANTS"
                    v: {
                      var ip = root.receipt ? root.receipt.invariantPreservation : null
                      if (!ip) return "—"
                      if (typeof ip === "string") return ip
                      return String(ip.state || "?") + " · " + Number(ip.checks || 0) + " checks"
                    }
                    vColor: {
                      var ip = root.receipt ? root.receipt.invariantPreservation : null
                      var s = ip ? (typeof ip === "string" ? ip : ip.state) : ""
                      return s === "PROVED" ? Color.accent : Color.foreground
                    }
                  }
                  KV {
                    k: "CANDIDATE"
                    v: {
                      if (!root.receipt) return "—"
                      var w = root.worldById(root.receipt.candidateWorld)
                      return w ? root.shortAlias(w) : root.shortHash(root.receipt.candidateWorld)
                    }
                  }
                  KV {
                    k: "NON-CLAIMS"
                    v: root.receipt && Array.isArray(root.receipt.nonClaims) ? String(root.receipt.nonClaims.length) + " stated" : "—"
                  }
                }

                Card {
                  SectionTitle { text: "CENSUS — " + root.worlds.length + " WORLDS" }
                  Repeater {
                    model: root.stateCounts()
                    delegate: RowLayout {
                      required property var modelData
                      Layout.fillWidth: true
                      spacing: Style.spacing.sm
                      Rectangle { width: Style.space(8); height: width; radius: width / 2; color: root.stateColor(modelData.state) }
                      Text { text: modelData.state; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                      Item { Layout.fillWidth: true }
                      Text { text: String(modelData.count); color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true }
                    }
                  }
                }

                Card {
                  SectionTitle { text: "JOBS — " + root.runningJobs() + " RUNNING" }
                  visible: root.jobs.length > 0
                  Repeater {
                    model: root.recentJobs()
                    delegate: ColumnLayout {
                      required property var modelData
                      Layout.fillWidth: true
                      spacing: 0
                      RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.spacing.sm
                        Text {
                          text: modelData.state
                          color: modelData.state === "RUNNING" ? Color.accent
                               : (modelData.state === "DEGRADED" || modelData.state === "FAILED" ? Color.urgent : Color.muted)
                          font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true
                        }
                        Text {
                          Layout.fillWidth: true
                          text: modelData.alias; color: Color.foreground
                          font.family: Style.font.family; font.pixelSize: Style.font.caption
                          elide: Text.ElideRight
                        }
                        Text { text: modelData.dur; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                      }
                      Text {
                        visible: modelData.error !== ""
                        Layout.fillWidth: true
                        text: modelData.error
                        color: Color.urgent
                        font.family: Style.font.family; font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }
                  }
                }

                Card {
                  SectionTitle { text: "CAPABILITIES" }
                  Repeater {
                    model: root.capRows()
                    delegate: RowLayout {
                      required property var modelData
                      Layout.fillWidth: true
                      spacing: Style.spacing.sm
                      Rectangle {
                        width: Style.space(7); height: width; radius: width / 2
                        color: modelData.ok ? Color.accent : "transparent"
                        border.color: modelData.ok ? Color.accent : Color.muted
                        border.width: 1
                      }
                      Text { text: modelData.name; color: modelData.ok ? Color.foreground : Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                      Item { Layout.fillWidth: true }
                      Text {
                        Layout.maximumWidth: Style.space(130)
                        text: modelData.note; color: Color.muted
                        font.family: Style.font.family; font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                        horizontalAlignment: Text.AlignRight
                      }
                    }
                  }
                }

                Card {
                  SectionTitle { text: "ADAPTERS" }
                  visible: root.adapters.length > 0
                  Repeater {
                    model: root.adapters
                    delegate: RowLayout {
                      required property var modelData
                      Layout.fillWidth: true
                      spacing: Style.spacing.sm
                      Rectangle {
                        width: Style.space(7); height: width; radius: width / 2
                        color: modelData.state === "AVAILABLE" ? Color.accent : "transparent"
                        border.color: modelData.state === "AVAILABLE" ? Color.accent : Color.muted
                        border.width: 1
                      }
                      Text {
                        text: String(modelData.name || "")
                        color: modelData.state === "AVAILABLE" ? Color.foreground : Color.muted
                        font.family: Style.font.family; font.pixelSize: Style.font.caption
                      }
                      Item { Layout.fillWidth: true }
                      Text {
                        text: String(modelData.state || "")
                        color: modelData.state === "AVAILABLE" ? Color.accent : Color.muted
                        font.family: Style.font.family; font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }
              }
            }

            // -------- center: the multiverse graph
            ColumnLayout {
              Layout.fillWidth: true
              Layout.fillHeight: true
              spacing: Style.spacing.sm

              Item {
                id: graphViewport
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                Canvas {
                  id: graphCanvas
                  anchors.fill: parent
                  property var layoutNodes: []

                  function computeLayout() {
                    var byDepth = ({})
                    var depths = ({})
                    function depth(world) {
                      if (!world || !world.parent) return 0
                      if (depths[world.instanceId] !== undefined) return depths[world.instanceId]
                      var parent = root.worldByInstance(world.parent)
                      depths[world.instanceId] = parent ? depth(parent) + 1 : 0
                      return depths[world.instanceId]
                    }
                    for (var i = 0; i < root.worlds.length; i++) {
                      var d = depth(root.worlds[i])
                      if (!byDepth[d]) byDepth[d] = []
                      byDepth[d].push(root.worlds[i])
                    }
                    var out = []
                    for (var key in byDepth) {
                      var row = byDepth[key]
                      for (var j = 0; j < row.length; j++) {
                        out.push({
                          world: row[j],
                          depth: Number(key),
                          x: (j + 1) * graphViewport.width / (row.length + 1),
                          y: Style.space(60) + Number(key) * Style.space(110)
                        })
                      }
                    }
                    layoutNodes = out
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
                      world = root.worldByInstance(world.parent)
                    }
                    return path
                  }

                  function nodeRadius(world) {
                    var files = root.deltaFiles(world)
                    return Style.space(10) + Math.min(Style.space(8), Math.log2(1 + files) * Style.space(2))
                  }

                  onPaint: {
                    if (!root.opened) return
                    computeLayout()
                    var context = getContext("2d")
                    if (!context) return
                    context.reset()
                    context.clearRect(0, 0, width, height)
                    context.save()
                    context.translate(root.graphPanX, root.graphPanY)
                    context.scale(root.graphZoom, root.graphZoom)

                    // generation guide lines
                    var maxDepth = 0
                    for (var g = 0; g < layoutNodes.length; g++) maxDepth = Math.max(maxDepth, layoutNodes[g].depth)
                    context.lineWidth = 1
                    for (var gd = 0; gd <= maxDepth; gd++) {
                      var gy = Style.space(60) + gd * Style.space(110)
                      context.globalAlpha = 0.10
                      context.strokeStyle = Color.muted
                      context.beginPath()
                      context.moveTo(Style.space(8), gy)
                      context.lineTo(width / root.graphZoom - Style.space(8), gy)
                      context.stroke()
                      context.globalAlpha = 0.35
                      context.fillStyle = Color.muted
                      context.font = Style.font.caption + "px " + Style.font.family
                      context.textAlign = "left"
                      context.fillText("g" + gd, Style.space(10), gy - Style.space(6))
                    }

                    var cone = selectedPath()
                    var selected = root.hasSelection ? root.selectedWorld : null
                    var selectedNode = selected ? node(selected.instanceId) : null

                    context.lineWidth = 1.5
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
                      var isPrime = root.lastGoodStatus.prime && world.instanceId === root.lastGoodStatus.prime.instanceId
                      var radius = nodeRadius(world)
                      context.globalAlpha = pathActive ? 1 : root.siblingOpacity * 0.48

                      // selection halo
                      if (active) {
                        context.fillStyle = Util.alpha(Color.accent, 0.15)
                        context.beginPath()
                        context.arc(item.x, item.y, radius + Style.space(8), 0, Math.PI * 2)
                        context.fill()
                      }

                      context.fillStyle = active ? Color.accent : Color.background
                      context.strokeStyle = active ? Color.accent : root.stateColor(world.state)
                      context.lineWidth = active ? 3 : 1.6
                      context.beginPath()
                      context.arc(item.x, item.y, radius, 0, Math.PI * 2)
                      context.fill()
                      context.stroke()

                      // PRIME double ring
                      if (isPrime) {
                        context.lineWidth = 1.2
                        context.strokeStyle = Color.accent
                        context.beginPath()
                        context.arc(item.x, item.y, radius + Style.space(4), 0, Math.PI * 2)
                        context.stroke()
                      }

                      // evidence badge: filled = PASS, urgent = FAIL, hollow = UNASSESSED
                      var proof = root.proofState(world)
                      var bx = item.x + radius * 0.85
                      var by = item.y - radius * 0.85
                      context.lineWidth = 1.4
                      context.beginPath()
                      context.arc(bx, by, Style.space(4), 0, Math.PI * 2)
                      if (proof === "PASS") { context.fillStyle = Color.accent; context.fill() }
                      else if (proof === "FAIL") { context.fillStyle = Color.urgent; context.fill() }
                      else { context.fillStyle = Color.background; context.fill(); context.strokeStyle = Color.muted; context.stroke() }

                      // labels: alias, then agent + delta
                      context.fillStyle = active ? Color.background : (pathActive ? Color.foreground : Color.muted)
                      context.font = Style.font.caption + "px " + Style.font.family
                      context.textAlign = "center"
                      context.fillStyle = pathActive ? Color.foreground : Color.muted
                      context.fillText(root.shortAlias(world), item.x, item.y + radius + Style.space(14))
                      context.fillStyle = Color.muted
                      var files = root.deltaFiles(world)
                      context.fillText(String(world.agent || "—") + (files > 0 ? "  +" + files : ""),
                                       item.x, item.y + radius + Style.space(27))
                    }
                    context.restore()
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  property real lastX: 0
                  property real lastY: 0
                  property bool moved: false
                  onPressed: function(mouse) { lastX = mouse.x; lastY = mouse.y; moved = false }
                  onPositionChanged: function(mouse) {
                    if (!(mouse.buttons & Qt.LeftButton)) return
                    var dx = mouse.x - lastX
                    var dy = mouse.y - lastY
                    if (Math.abs(dx) + Math.abs(dy) > 2) moved = true
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
                      if (dx * dx + dy * dy <= Style.space(24) * Style.space(24)) {
                        root.selectAlias(node.world.instanceId)
                        break
                      }
                    }
                  }
                  onWheel: function(wheel) {
                    var next = Math.max(0.5, Math.min(2.2, root.graphZoom + (wheel.angleDelta.y > 0 ? 0.1 : -0.1)))
                    root.graphZoom = next
                    graphCanvas.requestPaint()
                    wheel.accepted = true
                  }
                }
              }

              // graph legend + zoom — a Flow so its minimum width is one
              // item, never the sum: the inspector rail must keep its lane.
              Flow {
                Layout.fillWidth: true
                spacing: Style.spacing.md
                Repeater {
                  model: root.stateOrder
                  delegate: Row {
                    required property var modelData
                    spacing: Style.spacing.xs
                    Rectangle { width: Style.space(7); height: width; radius: width / 2; color: root.stateColor(modelData); anchors.verticalCenter: parent.verticalCenter }
                    Text { text: modelData; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                  }
                }
                Text {
                  text: "◈ PASS filled · FAIL red · hollow unassessed"
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Text {
                  text: "zoom " + Math.round(root.graphZoom * 100) + "%"
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Text {
                  text: "[reset]"
                  color: Color.accent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { root.graphZoom = 1; root.graphPanX = 0; root.graphPanY = 0; graphCanvas.requestPaint() }
                  }
                }
              }
            }

            // -------- right rail: inspector
            Flickable {
              Layout.preferredWidth: Style.space(340)
              Layout.fillHeight: true
              contentHeight: inspector.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              ColumnLayout {
                id: inspector
                width: parent.width
                spacing: Style.spacing.md

                Card {
                  SectionTitle { text: root.hasSelection ? "WORLD" : "INSPECTOR" }
                  Text {
                    Layout.fillWidth: true
                    text: root.hasSelection ? root.shortAlias(root.selectedWorld) : "Select a world"
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.title
                    font.bold: true
                    elide: Text.ElideRight
                  }
                  RowLayout {
                    visible: root.hasSelection
                    spacing: Style.spacing.sm
                    StateChip {
                      label: root.hasSelection ? String(root.selectedWorld.state || "?") : ""
                      tone: root.stateColor(root.hasSelection ? root.selectedWorld.state : "")
                    }
                    StateChip {
                      visible: root.hasSelection && root.selectedWorld.risk !== undefined
                      label: "RISK " + (root.hasSelection ? String(root.selectedWorld.risk || "") : "")
                      tone: root.riskColor(root.hasSelection ? root.selectedWorld.risk : "")
                    }
                    StateChip {
                      visible: root.hasSelection && root.selectedWorld.complexity !== undefined
                      label: "CPLX " + (root.hasSelection ? String(root.selectedWorld.complexity || "") : "")
                      tone: Color.muted
                    }
                  }
                  Text {
                    visible: root.hasSelection && (root.selectedWorld.risk !== undefined || root.selectedWorld.complexity !== undefined)
                    text: "derived labels — inputs below"
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                  KV { visible: root.hasSelection; k: "AGENT"; v: root.hasSelection ? String(root.selectedWorld.agent || "—") : "" }
                  KV { visible: root.hasSelection; k: "CAUSE"; v: root.hasSelection ? String(root.selectedWorld.cause || "—") : "" }
                  KV { visible: root.hasSelection; k: "BORN"; v: root.hasSelection ? root.fmtStamp(root.selectedWorld.born) : "" }
                  KV {
                    visible: root.hasSelection
                    k: root.hasSelection && root.selectedWorld.ended ? "LIFETIME" : "RUNNING"
                    v: root.hasSelection ? root.fmtDur(root.selectedWorld.born, root.selectedWorld.ended) : ""
                    vColor: root.hasSelection && !root.selectedWorld.ended ? Color.accent : Color.foreground
                  }
                  KV {
                    visible: root.hasSelection
                    k: "PARENT"
                    v: {
                      if (!root.hasSelection) return ""
                      var p = root.worldByInstance(root.selectedWorld.parent)
                      return p ? root.shortAlias(p) : "PRIME"
                    }
                  }
                  KV { visible: root.hasSelection; k: "DESCENDANTS"; v: root.hasSelection ? String(root.selectedWorld.descendants || 0) : "" }
                  KV { visible: root.hasSelection; k: "HASH"; v: root.hasSelection ? root.shortHash(root.selectedWorld.hash) : "" }
                }

                Card {
                  visible: root.hasSelection
                  SectionTitle { text: "DELTA" }
                  RowLayout {
                    Layout.fillWidth: true
                    spacing: Style.spacing.md
                    Text {
                      text: "+" + (root.hasSelection && root.selectedWorld.delta ? Number(root.selectedWorld.delta.added || 0) : 0)
                      color: Color.accent; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true
                    }
                    Text {
                      text: "~" + (root.hasSelection && root.selectedWorld.delta ? Number(root.selectedWorld.delta.modified || 0) : 0)
                      color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true
                    }
                    Text {
                      text: "−" + (root.hasSelection && root.selectedWorld.delta ? Number(root.selectedWorld.delta.deleted || 0) : 0)
                      color: Color.urgent; font.family: Style.font.family; font.pixelSize: Style.font.body; font.bold: true
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                      text: root.deltaFiles(root.hasSelection ? root.selectedWorld : null) + " files"
                      color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption
                    }
                  }
                  Repeater {
                    model: {
                      if (!root.hasSelection || !root.selectedWorld.delta) return []
                      var fs = root.selectedWorld.delta.files
                      return Array.isArray(fs) ? fs.slice(0, 6) : []
                    }
                    delegate: Text {
                      required property var modelData
                      Layout.fillWidth: true
                      text: "· " + root.fileLabel(modelData)
                      color: Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideLeft
                    }
                  }
                  Text {
                    visible: root.deltaFiles(root.hasSelection ? root.selectedWorld : null) > 6
                    text: "… and " + (root.deltaFiles(root.hasSelection ? root.selectedWorld : null) - 6) + " more"
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                  }
                }

                Card {
                  visible: root.hasSelection
                  SectionTitle { text: "EVIDENCE" }
                  Text {
                    visible: {
                      if (!root.hasSelection) return false
                      var c = root.selectedWorld.checks
                      var p = root.selectedWorld.proofs
                      return (!Array.isArray(c) || c.length === 0) && (!Array.isArray(p) || p.length === 0)
                    }
                    Layout.fillWidth: true
                    text: "UNASSESSED — no checks configured for this root; risk cannot drop below MEDIUM"
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                  Repeater {
                    model: root.hasSelection && Array.isArray(root.selectedWorld.checks) ? root.selectedWorld.checks : []
                    delegate: RowLayout {
                      required property var modelData
                      Layout.fillWidth: true
                      spacing: Style.spacing.sm
                      Rectangle { width: Style.space(7); height: width; radius: width / 2; color: root.checkColor(modelData.status) }
                      Text {
                        Layout.fillWidth: true
                        text: String(modelData.name || modelData.kind || "check") + (modelData.required ? "  [required]" : "")
                        color: Color.foreground
                        font.family: Style.font.family; font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                      Text {
                        text: String(modelData.status || "?")
                        color: root.checkColor(modelData.status)
                        font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true
                      }
                    }
                  }
                  Repeater {
                    model: root.hasSelection && Array.isArray(root.selectedWorld.proofs) ? root.selectedWorld.proofs : []
                    delegate: RowLayout {
                      required property var modelData
                      Layout.fillWidth: true
                      spacing: Style.spacing.sm
                      Rectangle { width: Style.space(7); height: width; radius: width / 2; color: root.checkColor(modelData.status) }
                      Text {
                        Layout.fillWidth: true
                        text: "formal · " + Number(modelData.total || 0) + " obligations"
                        color: Color.foreground
                        font.family: Style.font.family; font.pixelSize: Style.font.caption
                      }
                      Text {
                        text: String(modelData.status || "?")
                        color: root.checkColor(modelData.status)
                        font.family: Style.font.family; font.pixelSize: Style.font.caption; font.bold: true
                      }
                    }
                  }
                }

                Card {
                  visible: root.hasSelection
                  SectionTitle { text: "COLLAPSE GATES" }
                  KV {
                    k: "CONFLICTS"
                    v: root.hasSelection && Array.isArray(root.selectedWorld.conflicts) ? String(root.selectedWorld.conflicts.length) : "0"
                    vColor: root.hasSelection && Array.isArray(root.selectedWorld.conflicts) && root.selectedWorld.conflicts.length > 0 ? Color.urgent : Color.accent
                  }
                  KV {
                    k: "CONTAMINATION"
                    v: root.hasSelection && Array.isArray(root.selectedWorld.contamination) ? String(root.selectedWorld.contamination.length) : "0"
                    vColor: root.hasSelection && Array.isArray(root.selectedWorld.contamination) && root.selectedWorld.contamination.length > 0 ? Color.urgent : Color.accent
                  }
                  Repeater {
                    model: root.hasSelection && Array.isArray(root.selectedWorld.conflicts) ? root.selectedWorld.conflicts.slice(0, 4) : []
                    delegate: Text {
                      required property var modelData
                      Layout.fillWidth: true
                      text: "⚠ " + root.fileLabel(modelData)
                      color: Color.urgent
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideLeft
                    }
                  }
                }

                RowLayout {
                  Layout.fillWidth: true
                  spacing: Style.spacing.sm
                  Button {
                    Layout.fillWidth: true
                    text: "RETURN"
                    enabled: root.hasSelection
                    onClicked: { root.actionKind = "return"; root.confirmationStep = 0; root.mode = "collapse" }
                  }
                  Button {
                    Layout.fillWidth: true
                    text: "COLLAPSE"
                    enabled: root.hasSelection && root.selectedWorld.state === "VALID"
                    onClicked: { root.actionKind = "collapse"; root.confirmationStep = 0; root.mode = "collapse" }
                  }
                }
                Text {
                  visible: root.hasSelection && root.selectedWorld.state !== "VALID"
                  Layout.fillWidth: true
                  text: "only VALID worlds can collapse — this one is " + (root.hasSelection ? String(root.selectedWorld.state || "?") : "")
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }
            }
          }

          // ============ COLLAPSE MODE ============
          CollapsePanel {
            anchors.fill: parent
            visible: root.mode === "collapse"
            world: root.selectedWorld
            receipt: root.selectedReceipt()
            actionKind: root.actionKind
            confirmationStep: root.confirmationStep
            onRequestConfirm: root.confirmationStep = 1
            onRequestExecute: root.executeSelection()
            onRequestCancel: { root.mode = "multiverse"; root.confirmationStep = 0 }
          }
        }

        // ---------------------------------------------------- footer
        Rectangle { Layout.fillWidth: true; height: 1; color: Util.alpha(Color.muted, 0.5) }
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.md
          Text {
            text: root.worlds.length + " worlds · " + root.runningJobs() + " jobs running · daemon " + root.daemonAge()
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
          Text {
            visible: root.actionError !== ""
            Layout.fillWidth: true
            text: root.actionError
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
          Item { Layout.fillWidth: true; visible: root.actionError === "" }
          Text {
            text: "← → lineage · ↑ ↓ siblings · ⏎ collapse · F fork · G graph · esc close"
            color: Color.muted
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
