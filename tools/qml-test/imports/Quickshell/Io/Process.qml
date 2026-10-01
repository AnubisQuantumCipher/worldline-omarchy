import QtQuick

// Test stand-in for Quickshell.Io Process, answered by FakeCli. Like Quickshell 0.3.1 it emits
// `exited` before `running` turns false, reports a process that cannot start only through
// `running` turning false, and a SIGKILL (signal(9)) ends a hung process.
Item {
  id: proc
  property var command: []
  property bool running: false
  property var environment: ({})
  property QtObject stdout: null
  property QtObject stderr: null
  property var _reply: null
  signal exited(int exitCode, int exitStatus)

  function utf8Length(text) { return unescape(encodeURIComponent(String(text))).length }

  onRunningChanged: {
    if (!proc.running) return
    proc._reply = FakeCli.take(proc.command)
    if (proc._reply.unavailable) { Qt.callLater(function() { proc.running = false }); return }
    if (proc._reply.hang) return
    finish.interval = proc._reply.delayMs || 1
    finish.restart()
  }

  Timer {
    id: finish
    repeat: false
    onTriggered: {
      if (!proc.running) return
      var reply = proc._reply
      if (proc.stdout && reply.stdout) { proc.stdout.text = reply.stdout; proc.stdout.data = { byteLength: proc.utf8Length(reply.stdout) } }
      if (proc.stderr && reply.stderr) { proc.stderr.text = reply.stderr; proc.stderr.data = { byteLength: proc.utf8Length(reply.stderr) } }
      proc.exited(reply.exitCode, 0)
      proc.running = false
    }
  }

  function signal(number) {
    if (!proc.running) return
    finish.stop()
    proc.exited(128 + number, 1)
    proc.running = false
  }
}
