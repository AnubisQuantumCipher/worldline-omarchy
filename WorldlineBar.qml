import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "khephri.worldline"

  readonly property var worldlineService: bar?.shell?.firstPartyServiceFor("khephri.worldline")
  property var status: null
  property var lastGoodStatus: null
  property double nowMs: Date.now()
  property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR")
  readonly property bool motionEnabled: setting("motionEnabled", true) === true
  readonly property bool worldTintEnabled: setting("worldTintEnabled", true) === true
  readonly property bool stale: {
    if (!lastGoodStatus || !lastGoodStatus.daemon || !lastGoodStatus.daemon.publishedAt) return true
    var stamp = Date.parse(lastGoodStatus.daemon.publishedAt)
    return !isFinite(stamp) || nowMs - stamp > 10000
  }
  readonly property bool initialized: lastGoodStatus !== null && lastGoodStatus.prime !== null
  readonly property var activeSummary: findActive()
  readonly property string compactText: {
    if (!initialized) return "No PRIME — run worldline init /path/to/work"
    var world = activeSummary
    var alias = world ? String(world.alias || lastGoodStatus.activeWorld || "PRIME") : String(lastGoodStatus.activeWorld || "PRIME")
    var agent = world ? String(world.agent || "WORLDLINE") : "WORLDLINE"
    var delta = world && world.delta ? world.delta : {}
    var files = Array.isArray(delta.files) ? delta.files.length : Number(delta.files || 0)
    var proof = proofState(world)
    return "◉ WORLDLINE  " + alias + " / " + agent + "  +" + files + "  PROOF " + proof
  }
  readonly property color stateColor: {
    if (stale || !initialized) return Color.muted
    var proof = proofState(activeSummary)
    return proof === "PASS" ? barForeground : (proof === "FAIL" ? Color.urgent : Color.muted)
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function findActive() {
    if (!lastGoodStatus) return null
    var active = String(lastGoodStatus.activeWorld || "PRIME")
    if (active === "PRIME" && lastGoodStatus.prime) {
      for (var p = 0; p < lastGoodStatus.worlds.length; p++)
        if (lastGoodStatus.worlds[p].instanceId === lastGoodStatus.prime.instanceId) return lastGoodStatus.worlds[p]
      return { alias: "PRIME", agent: "WORLDLINE", delta: { files: [] }, proofs: [] }
    }
    for (var i = 0; i < lastGoodStatus.worlds.length; i++)
      if (lastGoodStatus.worlds[i].alias === active) return lastGoodStatus.worlds[i]
    return null
  }

  function proofState(world) {
    if (stale) return "STALE"
    if (!world || !Array.isArray(world.proofs) || world.proofs.length === 0) return "UNASSESSED"
    for (var i = 0; i < world.proofs.length; i++)
      if (world.proofs[i].status !== "PASS") return "FAIL"
    return "PASS"
  }

  function applyStatus(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (parsed.schemaVersion !== 1 || parsed.activeWorld === undefined || !Array.isArray(parsed.worlds)) return
      status = parsed
      lastGoodStatus = parsed
    } catch (error) {
      // Atomic replacement plus last-known-good keeps a transient read neutral.
    }
  }

  function syncServiceSettings() {
    if (!worldlineService) return
    worldlineService.motionEnabled = motionEnabled
    worldlineService.worldTintEnabled = worldTintEnabled
  }

  onMotionEnabledChanged: syncServiceSettings()
  onWorldTintEnabledChanged: syncServiceSettings()
  onWorldlineServiceChanged: syncServiceSettings()
  Component.onCompleted: syncServiceSettings()

  implicitWidth: button.implicitWidth
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

  Timer {
    interval: 1000
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
    interval: 100
    repeat: false
    onTriggered: root.applyStatus(statusFile.text())
  }

  // Rendered exactly like the native bar icons: a globe in the bar's icon slot,
  // colored by proof state, with the full detail in its hover tooltip.
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""   // nf-fa-globe
    slotSize: Style.bar.iconSlot
    fontSize: Style.bar.iconFont
    foreground: root.stateColor
    tooltipText: root.compactText
    onPressed: function(buttonCode) {
      if (root.bar?.shell) root.bar.shell.summon("khephri.worldline", JSON.stringify({ mode: "multiverse" }))
    }
  }
}
