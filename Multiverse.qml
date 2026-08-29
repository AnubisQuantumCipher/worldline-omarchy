import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

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
  readonly property var serviceObject: shell && typeof shell.serviceFor === "function"
    ? shell.serviceFor("khephri.worldline") : undefined
  readonly property bool motionEnabled: serviceObject && serviceObject.motionEnabled !== undefined ? serviceObject.motionEnabled : true
  readonly property int motionDuration: motionEnabled ? 520 : 0
  readonly property bool initialized: lastGoodStatus.prime !== undefined && lastGoodStatus.prime !== null
  readonly property var worlds: Array.isArray(lastGoodStatus.worlds) ? lastGoodStatus.worlds : []
  readonly property var selectedWorld: worlds.length > 0 ? worlds[Math.max(0, Math.min(selectedIndex, worlds.length - 1))] : ({})
  readonly property bool hasSelection: selectedWorld && selectedWorld.instanceId !== undefined

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
      var receipt = parsed.lastReceipt
      if (receipt && receipt.receiptId && receipt.atomicCollapse
          && receipt.atomicCollapse.state === "COMMITTED") {
        if (!statusLoadedOnce) {
          lastCommittedReceipt = receipt.receiptId
          primeLabel = "PRIME′"
        } else if (receipt.receiptId !== lastCommittedReceipt) {
          lastCommittedReceipt = receipt.receiptId
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
  function selectedReceipt() {
    var currentStatus = root.lastGoodStatus
    var world = root.selectedWorld
    if (!currentStatus || !root.hasSelection || !currentStatus.lastReceipt) return ({})
    return currentStatus.lastReceipt.candidateWorld === world.id ? currentStatus.lastReceipt : ({})
  }
  function displayAlias(world) {
    if (root.lastGoodStatus && root.lastGoodStatus.prime
        && world.instanceId === root.lastGoodStatus.prime.instanceId)
      return root.primeLabel
    return String(world.alias)
  }
  // Compact label so long prime-UUID aliases don't overflow the panel or collide on the graph.
  function shortAlias(world) {
    var a = root.displayAlias(world)
    if (a.indexOf("prime-") === 0 && a.length > 16) return "prime-" + a.substring(6, 14)
    return a
  }
  function shortHash(h) {
    if (!h || h === "—") return "—"
    var s = String(h)
    return s.length > 30 ? s.substring(0, 20) + "…" + s.substring(s.length - 6) : s
  }
  // One glance tells the live line from the dead branches.
  function stateColor(state) {
    if (state === "VALID") return Color.accent
    if (state === "DEGRADED" || state === "DEAD") return Color.urgent
    if (state === "MUTABLE" || state === "FINALIZING") return Color.foreground
    return Color.muted   // ARCHIVED / COLLAPSED / unknown
  }
  function detailRows() {
    var world = root.selectedWorld
    if (!world || !world.instanceId) return []
    var delta = world.delta || {}
    var files = Array.isArray(delta.files) ? delta.files.length : Number(delta.files || 0)
    var checks = Array.isArray(world.checks) ? world.checks : []
    var proofs = Array.isArray(world.proofs) ? world.proofs : []
    var passedTests = 0
    var obligations = 0
    for (var i = 0; i < checks.length; i++)
      if (checks[i].kind === "tests" && checks[i].status === "PASS") passedTests++
    for (var p = 0; p < proofs.length; p++) obligations += Number(proofs[p].total || 0)
    return [
      ["Born", world.born || "—"],
      ["Parent", world.parent || "PRIME"],
      ["Cause", world.cause || "—"],
      ["Agent", world.agent || "—"],
      ["Duration", world.ended || "RUNNING"],
      ["Files", String(files)],
      ["Tests", String(passedTests)],
      ["Formal obligations", String(obligations)],
      ["Ancestor integrity", world.state || "—"],
      ["Hash", root.shortHash(world.hash)],
      ["Descendants", String(world.descendants || 0)]
    ]
  }




  function worldByInstance(instanceId) {
    for (var i = 0; i < worlds.length; i++) if (worlds[i].instanceId === instanceId) return worlds[i]
    return null
  }

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

  function runRace() {
    if (!initialized || missionText.trim() === "" || actionProcess.running) return
    actionError = ""
    actionProcess.command = [
      "worldline", "race", "--detach", "--mission-text", missionText,
      "--agent", "codex", "--agent", "claude", "--agent", "omp"
    ]
    actionProcess.running = true
  }

  function executeSelection() {
    if (!root.hasSelection || actionProcess.running) return
    actionError = ""
    if (actionKind === "return")
      actionProcess.command = ["worldline", "return", selectedWorld.alias, "--yes"]
    else
      actionProcess.command = ["worldline", "collapse", selectedWorld.alias, "--yes"]
    actionProcess.running = true
  }

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
          root.dismiss()
          event.accepted = true
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
        anchors.margins: Style.spacing.xl
        spacing: Style.spacing.lg

        RowLayout {
          Layout.fillWidth: true
          Text {
            text: "W O R L D L I N E"
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.displayLarge
            font.bold: true
            font.letterSpacing: Style.space(1)
          }
          Item { Layout.fillWidth: true }
          Text {
            text: root.initialized ? root.primeLabel : "NO PRIME"
            color: root.initialized ? Color.accent : Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Button { text: "×"; onClicked: root.dismiss() }
        }

        Rectangle { Layout.fillWidth: true; height: 1; color: Util.alpha(Color.muted, 0.5) }

        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true

          ColumnLayout {
            anchors.fill: parent
            visible: root.mode === "fork"
            spacing: Style.spacing.lg

            Text {
              Layout.alignment: Qt.AlignHCenter
              text: "CURRENT REALITY"
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              font.letterSpacing: Style.space(0.8)
            }
            Text {
              Layout.alignment: Qt.AlignHCenter
              text: root.initialized ? "●  PRIME" : "No PRIME — run worldline init /path/to/work"
              color: root.initialized ? Color.accent : Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.display
              font.bold: true
            }

            RowLayout {
              Layout.alignment: Qt.AlignHCenter
              spacing: Style.spacing.xl
              Repeater {
                model: [
                  { world: "WORLD α", agent: "CODEX" },
                  { world: "WORLD β", agent: "CLAUDE" },
                  { world: "WORLD γ", agent: "OMP" }
                ]
                delegate: ColumnLayout {
                  required property var modelData
                  spacing: Style.spacing.sm
                  Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: modelData.world
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }
                  Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: modelData.agent
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    font.letterSpacing: Style.space(0.5)
                  }
                }
              }
            }

            Text {
              text: "FORK REALITY"
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
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
                text: "Fork reality. Explore futures. Measure consequences. Collapse the best future."
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
              Button {
                text: "FORK REALITY"
                enabled: root.initialized && root.missionText.trim() !== "" && !actionProcess.running
                onClicked: root.runRace()
              }
            }
          }

          RowLayout {
            anchors.fill: parent
            visible: root.mode === "multiverse"
            spacing: Style.spacing.lg

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
                        x: (j + 1) * graphViewport.width / (row.length + 1),
                        y: Style.space(70) + Number(key) * Style.space(120)
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
                    var active = selected && item.world.instanceId === selected.instanceId
                    var pathActive = cone[item.world.instanceId]
                    context.globalAlpha = pathActive ? 1 : root.siblingOpacity * 0.48
                    context.fillStyle = active ? Color.accent : Color.background
                    context.strokeStyle = active ? Color.accent : root.stateColor(item.world.state)
                    context.lineWidth = active ? 3 : 1.5
                    context.beginPath()
                    context.arc(item.x, item.y, active ? Style.space(15) : Style.space(11), 0, Math.PI * 2)
                    context.fill()
                    context.stroke()
                    context.fillStyle = active ? Color.background : (pathActive ? Color.foreground : Color.muted)
                    context.font = Style.font.caption + "px " + Style.font.family
                    context.textAlign = "center"
                    context.fillText(root.shortAlias(item.world), item.x, item.y + Style.space(30))
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

            Rectangle {
              Layout.preferredWidth: Style.space(360)
              Layout.fillHeight: true
              clip: true
              color: Util.alpha(Color.foreground, 0.03)
              border.color: Util.alpha(Color.muted, 0.6)
              border.width: 1
              radius: Style.cornerRadius

              ColumnLayout {
                anchors.fill: parent
                anchors.margins: Style.spacing.lg
                spacing: Style.spacing.sm

                Text {
                  Layout.fillWidth: true
                  text: root.hasSelection ? "WORLD  " + root.shortAlias(root.selectedWorld) : "SELECT A WORLD"
                  color: Color.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.title
                  font.bold: true
                  elide: Text.ElideRight
                }
                Text {
                  visible: root.hasSelection && root.selectedWorld.state !== undefined
                  text: root.hasSelection ? String(root.selectedWorld.state || "") : ""
                  color: root.stateColor(root.hasSelection ? root.selectedWorld.state : "")
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.letterSpacing: Style.space(0.6)
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: Util.alpha(Color.muted, 0.35) }
                Repeater {
                  model: root.detailRows()
                  delegate: ColumnLayout {
                    required property var modelData
                    Layout.fillWidth: true
                    spacing: 1
                    Text { text: modelData ? String(modelData[0]).toUpperCase() : ""; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.caption }
                    Text { Layout.fillWidth: true; text: modelData ? String(modelData[1]) : ""; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.body; wrapMode: Text.WrapAnywhere; maximumLineCount: 2; elide: Text.ElideRight }
                  }
                }
                Item { Layout.fillHeight: true }
                RowLayout {
                  Layout.fillWidth: true
                  Button {
                    text: "RETURN"
                    enabled: root.hasSelection
                    onClicked: { root.actionKind = "return"; root.confirmationStep = 0; root.mode = "collapse" }
                  }
                  Button {
                    text: "COLLAPSE"
                    enabled: root.hasSelection && root.selectedWorld.state === "VALID"
                    onClicked: { root.actionKind = "collapse"; root.confirmationStep = 0; root.mode = "collapse" }
                  }
                }
              }
            }
          }

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

        Text {
          Layout.fillWidth: true
          visible: root.actionError !== ""
          text: root.actionError
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
