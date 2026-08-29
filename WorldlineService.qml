import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

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

  function applyStatus(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (parsed.schemaVersion !== 1) return
      var required = ["daemon", "prime", "activeWorld", "worlds", "jobs", "capabilities", "lastReceipt", "ghostRecommendation"]
      for (var i = 0; i < required.length; i++) if (parsed[required[i]] === undefined) return
      root.status = parsed
      root.lastGoodStatus = parsed
      maybeNotify(parsed.ghostRecommendation)
    } catch (error) {
      // Keep the last complete atomic status rather than painting a partial file.
    }
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

  Timer {
    interval: 2000
    running: true
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
