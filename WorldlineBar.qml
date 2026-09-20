import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar entry: one globe in the native icon slot, tinted by the active reality's evidence
// state, plus a small count when agent jobs are running. The full line lives in the tooltip:
//   ◉ WORLDLINE  <alias> / <agent>  +<files>  EVIDENCE <PASS|FAIL|UNASSESSED|UNAVAILABLE|STALE>
// Evidence is derived from the world's checks exactly as the cockpit derives it; lifecycle
// state is reported separately so a running world never reads as "failed".
BarWidget {
  id: root
  moduleName: "khephri.worldline"

  property var status: null
  property var lastGoodStatus: null
  property double nowMs: Date.now()
  property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR")
  property string lastRaw: ""
  readonly property bool motionEnabled: setting("motionEnabled", true) === true
  readonly property bool worldTintEnabled: setting("worldTintEnabled", true) === true
  readonly property string signalState: Model.signal(lastGoodStatus, nowMs)
  readonly property bool stale: signalState !== "live"
  readonly property bool initialized: lastGoodStatus !== null && lastGoodStatus.prime !== null
  readonly property var activeSummary: findActive()
  readonly property int runningJobs: lastGoodStatus ? Model.runningJobCount(lastGoodStatus.jobs) : 0
  readonly property var evidence: Model.evidence(activeSummary, stale)
  readonly property string compactText: {
    if (signalState === "offline") return "◉ WORLDLINE  no signal — daemon not running (systemctl --user status worldlined)"
    if (!initialized) return "◉ WORLDLINE  no PRIME — run: worldline init /path/to/work"
    var world = activeSummary
    var alias = world ? Model.displayAlias(world, lastGoodStatus, "PRIME") : String(lastGoodStatus.activeWorld || "PRIME")
    var agent = world ? String(world.agent || "worldline") : "worldline"
    var files = Model.deltaCount(world)
    var line = "◉ WORLDLINE  " + alias + " / " + agent + "  +" + files + "  EVIDENCE " + evidence.state
    if (world && world.state) line += "  · " + world.state
    if (runningJobs > 0) line += "  · " + runningJobs + " job" + (runningJobs === 1 ? "" : "s") + " running"
    if (stale) line += "  · signal " + signalState
    return line
  }
  readonly property color barForeground: bar ? bar.barForeground : Color.foreground
  readonly property color stateColor: {
    if (stale || !initialized) return Color.muted
    if (evidence.state === "PASS") return barForeground
    if (evidence.state === "FAIL") return Color.urgent
    return Color.muted
  }

  function findActive() {
    if (!lastGoodStatus) return null
    var active = String(lastGoodStatus.activeWorld || "PRIME")
    if (active === "PRIME" && lastGoodStatus.prime) {
      var prime = Model.worldByInstance(lastGoodStatus.worlds, lastGoodStatus.prime.instanceId)
      return prime || { alias: "PRIME", agent: "worldline", delta: { files: [] }, checks: [], state: "VALID" }
    }
    var index = Model.worldIndexByAlias(lastGoodStatus.worlds, active)
    return index >= 0 ? lastGoodStatus.worlds[index] : null
  }

  function applyStatus(raw) {
    var text = String(raw || "")
    if (text === lastRaw) return
    var parsed = Model.parseStatus(text)
    if (!parsed) return
    lastRaw = text
    status = parsed
    lastGoodStatus = parsed
  }

  implicitWidth: button.implicitWidth + (badge.visible ? badge.width + Style.spacing.xxs : 0)
  implicitHeight: button.implicitHeight

  FileView {
    id: statusFile
    path: root.runtimeDir + "/worldline/status.json"
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyStatus(text())
    onFileChanged: statusApplyTimer.restart()
  }

  // Staleness clock every 2 s (no parse unless the bytes changed); the reload catches an
  // os.replace the watcher missed. Cheaper than the previous 1 s parse-everything loop.
  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: {
      root.nowMs = Date.now()
      statusFile.reload()
      statusApplyTimer.restart()
    }
  }

  Timer {
    id: statusApplyTimer
    interval: 120
    repeat: false
    onTriggered: root.applyStatus(statusFile.text())
  }

  Row {
    anchors.fill: parent
    spacing: Style.spacing.xxs

    BarIconButton {
      id: button
      bar: root.bar
      text: String.fromCodePoint(0xF0AC)   // nf-fa-globe; explicit so an editor cannot drop the private-use glyph
      slotSize: Style.bar.iconSlot
      fontSize: Style.bar.iconFont
      foreground: root.stateColor
      tooltipText: root.compactText
      onPressed: function(buttonCode) {
        if (root.bar?.shell) root.bar.shell.summon("khephri.worldline", JSON.stringify({ mode: "multiverse" }))
      }
    }

    // Running-job count, drawn in the bar's "active" tone so it reads at a glance.
    Rectangle {
      id: badge
      visible: root.runningJobs > 0 && !root.stale
      anchors.verticalCenter: parent.verticalCenter
      width: badgeText.implicitWidth + Style.spacing.sm * 2
      height: badgeText.implicitHeight + Style.spacing.xxs * 2
      radius: Style.cornerRadius > 0 ? height / 2 : 0
      color: Util.alpha(Color.bar.active, 0.18)
      border.color: Util.alpha(Color.bar.active, 0.7)
      border.width: 1
      Text {
        id: badgeText
        textFormat: Text.PlainText
        anchors.centerIn: parent
        text: String(root.runningJobs)
        color: Color.bar.active
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
  }
}
