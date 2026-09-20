import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import "Model.js" as Model

// Headless service: watches the daemon's atomically replaced status.json, raises the
// "a better future was found" notification for ghost recommendations, and paints the
// alternate-world tint while a non-PRIME world is the inspected one.
Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool motionEnabled: true
  property bool worldTintEnabled: true
  property var status: null
  property var lastGoodStatus: null
  property string recommendationId: ""
  property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR")
  property string lastRaw: ""

  function applyStatus(raw) {
    var text = String(raw || "")
    if (text === root.lastRaw) return
    var parsed = Model.parseStatus(text)
    if (!parsed) return    // mid-replacement or foreign file: keep the last complete document
    root.lastRaw = text
    root.status = parsed
    root.lastGoodStatus = parsed
    maybeNotify(parsed.ghostRecommendation)
  }

  function maybeNotify(recommendation) {
    if (!recommendation || !recommendation.instanceId) return
    var id = String(recommendation.instanceId) + ":" + String(recommendation.objective || "")
    if (id === recommendationId) return
    recommendationId = id
    if (notificationProcess.running) return
    notificationProcess.command = [
      "notify-send",
      "--app-name=WORLDLINE",
      "--action=inspect=Inspect",
      "WORLDLINE — A better future has been found",
      String(recommendation.world || recommendation.objective || "")
    ]
    notificationProcess.running = true
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

  // The daemon replaces the file with os.replace, which can drop a QFileSystemWatcher; a slow
  // reload keeps the tint honest without a per-second parse.
  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: { statusFile.reload(); statusApplyTimer.restart() }
  }

  Timer {
    id: statusApplyTimer
    interval: 120
    repeat: false
    onTriggered: root.applyStatus(statusFile.text())
  }

  Process {
    id: notificationProcess
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (String(text || "").trim() === "inspect" && root.shell)
          root.shell.summon("khephri.worldline", JSON.stringify({ mode: "multiverse", select: root.status?.ghostRecommendation?.world || "" }))
      }
    }
  }

  PanelWindow {
    id: tintWindow
    visible: root.worldTintEnabled
      && root.lastGoodStatus !== null
      && String(root.lastGoodStatus.activeWorld || "PRIME") !== "PRIME"
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "worldline-tint"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    mask: Region {}

    Rectangle {
      anchors.fill: parent
      color: Util.alpha(Color.accent, 0.035)
    }
  }
}
